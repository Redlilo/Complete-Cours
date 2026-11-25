import Foundation
import AVFoundation
import Speech

// « Écouter un cours » en direct : transcription au fil de l'eau (moteur de dictée de macOS 26, sur le Mac) et analyse
// régulière par l'IA choisie dans les Réglages. Ce flux sert à l'AFFICHAGE : le texte définitif du cours (avec le tri des
// voix et la fiche) reste celui des morceaux enregistrés. Aucun audio n'est gardé par ce flux.

// MARK: - Transcription en direct

final class LectureDirect: @unchecked Sendable {
    /// (texte, définitif ?) : un texte provisoire est remplacé par le suivant ; un texte définitif est à garder. Hors du fil principal.
    var onTexte: ((String, Bool) -> Void)?
    var onErreur: ((String) -> Void)?

    private var analyseur: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var convertisseur: AVAudioConverter?
    private var formatCible: AVAudioFormat?
    private var collecte: Task<Void, Never>?
    private let verrou = NSLock()
    private var actif = false
    private var erreurConversionSignalee = false
    /// File propre au direct : la conversion ne ralentit jamais l'écriture du fichier du cours.
    private let file = DispatchQueue(label: "fr.complete-cours.lecture.direct", qos: .userInitiated)
    private var enAttente = 0
    /// Tampons reçus avant que le moteur soit prêt (≈ 10 s au plus) : envoyés dès qu'il l'est, pour ne pas perdre le début.
    private var avant: [AVAudioPCMBuffer] = []
    private var arrete = false

    // Petits accès au verrou, hors des fonctions async (NSLock y est déconseillé).
    private func verrouille<T>(_ f: () -> T) -> T { verrou.lock(); defer { verrou.unlock() }; return f() }

    func demarrer(vocabulaire: [String] = []) async throws {
        guard SpeechTranscriber.isAvailable else { throw LectureErreur.transcription("le moteur de dictée de ce Mac n'est pas disponible") }
        let installees = await SpeechTranscriber.installedLocales
        guard installees.contains(where: { $0.identifier.hasPrefix("fr") }) else { throw LectureErreur.langueAbsente }
        let t = SpeechTranscriber(locale: Locale(identifier: "fr_FR"), transcriptionOptions: [],
                                  reportingOptions: [.volatileResults], attributeOptions: [])
        let a = SpeechAnalyzer(modules: [t])
        await LectureTranscripteur.appliquerVocabulaire(vocabulaire, a: a)
        let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
        let (flux, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let tache = Task { [weak self] in
            do {
                for try await r in t.results {
                    let texte = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !texte.isEmpty { self?.onTexte?(texte, r.isFinal) }
                }
            } catch {
                if !Task.isCancelled && !(error is CancellationError) { self?.onErreur?(error.localizedDescription) }
            }
        }
        let enRetard = verrouille { () -> [AVAudioPCMBuffer] in
            analyseur = a; continuation = cont; formatCible = fmt; convertisseur = nil
            collecte = tache; erreurConversionSignalee = false; actif = true
            let r = avant; avant = []; return r
        }
        for b in enRetard { file.async { [self] in convertir(b) } }
        do {
            try await a.start(inputSequence: flux)
        } catch {
            nettoyer()          // démarrage raté : on ne laisse ni flux ouvert ni tâche en attente
            cont.finish(); tache.cancel()
            throw error
        }
    }

    private func nettoyer() {
        verrouille { actif = false; continuation = nil; analyseur = nil; convertisseur = nil; formatCible = nil }
    }

    /// Reçoit un morceau du micro (fil d'écriture du cours). On copie le tampon et on le traite sur la file du direct :
    /// si le direct prend du retard, ses tampons sont abandonnés, jamais ceux de l'enregistrement.
    func ajouter(_ buf: AVAudioPCMBuffer) {
        let (ok, plein, attend) = verrouille { (actif, enAttente >= 40, !actif && !arrete && avant.count < 120) }
        if attend, let copie = Self.copier(buf) { verrouille { if !actif && !arrete { avant.append(copie) } }; return }
        guard ok, !plein, let copie = Self.copier(buf) else { return }
        verrouille { enAttente += 1 }
        file.async { [self] in
            convertir(copie)
            verrouille { enAttente -= 1 }
        }
    }

    private static func copier(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength) else { return nil }
        c.frameLength = buf.frameLength
        let src = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(c.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            if let d = dst[i].mData, let s = src[i].mData { memcpy(d, s, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize))) }
        }
        return c
    }

    private func convertir(_ buf: AVAudioPCMBuffer) {
        let (cont, cible, existant) = verrouille { (continuation, formatCible, convertisseur) }
        guard let cont else { return }
        guard let cible, cible != buf.format else { cont.yield(AnalyzerInput(buffer: buf)); return }   // déjà au bon format
        var conv = existant
        if let e = conv, e.inputFormat != buf.format { conv = nil }      // micro changé en cours de route : nouveau convertisseur
        if conv == nil {
            conv = AVAudioConverter(from: buf.format, to: cible)
            verrouille { convertisseur = conv }
        }
        guard let conv else { signaler("conversion audio impossible pour le direct"); return }       // jamais de tampon au mauvais format
        let capacite = AVAudioFrameCount(Double(buf.frameLength) * cible.sampleRate / buf.format.sampleRate) + 256
        guard let sortie = AVAudioPCMBuffer(pcmFormat: cible, frameCapacity: capacite) else { return }
        var fourni = false
        var erreur: NSError?
        let statut = conv.convert(to: sortie, error: &erreur) { _, st in
            if fourni { st.pointee = .noDataNow; return nil }
            fourni = true; st.pointee = .haveData; return buf
        }
        if statut == .error || erreur != nil { signaler("conversion audio du direct en échec"); return }
        if sortie.frameLength > 0 { cont.yield(AnalyzerInput(buffer: sortie)) }
    }

    private func signaler(_ message: String) {
        let premiere = verrouille { () -> Bool in let p = !erreurConversionSignalee; erreurConversionSignalee = true; return p }
        if premiere { onErreur?(message) }
    }

    /// Fin du cours : le moteur termine ce qu'il a entendu ; on attend ses derniers résultats (5 s au plus). Sans danger si appelé deux fois.
    func arreter() async {
        let (cont, a, tache) = verrouille { () -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?, Task<Void, Never>?) in
            actif = false; arrete = true; avant = []; let r = (continuation, analyseur, collecte); continuation = nil; analyseur = nil; collecte = nil; return r
        }
        guard let cont else { return }
        file.sync { }                       // les tampons déjà en route sont envoyés avant la fin du flux
        cont.finish()
        try? await a?.finalizeAndFinishThroughEndOfInput()
        if let tache {
            await withTaskGroup(of: Void.self) { g in
                // L'attente d'une Task n'est pas annulée avec le groupe : on relaie l'annulation, sinon les 5 s ne servent à rien.
                g.addTask { await withTaskCancellationHandler { await tache.value } onCancel: { tache.cancel() } }
                g.addTask { try? await Task.sleep(for: .seconds(5)) }
                await g.next(); g.cancelAll()
            }
            tache.cancel()
        }
        nettoyer()
    }
}

// MARK: - Analyse en direct

struct LectureAnalyseDirect: Hashable {
    var resume: String = ""
    var points: [String] = []
    var termes: [LectureDefinition] = []
    var devoirs: [String] = []
    var doutes: [String] = []
    var date = Date()

    static func depuis(json: String) -> LectureAnalyseDirect? {
        guard let o = LectureTexte.objetJSON(json) else { return nil }
        func liste(_ k: String) -> [String] { (o[k] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? [] }
        let termes = (o["termes"] as? [Any])?.compactMap { $0 as? [String: Any] }.compactMap { d -> LectureDefinition? in
            guard let t = d["terme"] as? String, let df = d["definition"] as? String, !t.isEmpty else { return nil }
            return LectureDefinition(terme: t, definition: df)
        } ?? []
        return LectureAnalyseDirect(resume: (o["resume"] as? String) ?? "", points: liste("points"), termes: termes,
                                    devoirs: liste("devoirs"), doutes: liste("doutes"))
    }
}

enum LectureAnalyseDirectPrompts {
    static let systeme = """
    Tu aides un lycéen qui suit un cours EN DIRECT. Tu reçois la transcription automatique du début du cours jusqu'à maintenant \
    (elle contient des erreurs de reconnaissance et parfois des paroles d'élèves) et, si elle existe, ton analyse précédente. \
    Mets l'analyse à jour, en français simple et sans inventer : n'écris que ce qui est dit dans la transcription. \
    « resume » : 2 à 4 phrases sur où en est le cours et son sujet. « points » : au plus 8 idées à retenir, courtes. \
    « termes » : mots de vocabulaire ou notions définis par le prof, avec leur définition telle qu'elle est dite (au plus 8). \
    « devoirs » : travail à faire, contrôles ou dates annoncés (liste vide si rien). \
    « doutes » : au plus 3 passages incertains (mot mal reconnu, chiffre douteux) à vérifier plus tard. N'écris aucun prénom.
    """

    static var schema: [String: Any] {
        let chaine: [String: Any] = ["type": "string"]
        let liste: [String: Any] = ["type": "array", "items": chaine]
        let terme: [String: Any] = ["type": "object",
                                    "properties": ["terme": chaine, "definition": chaine],
                                    "required": ["terme", "definition"], "additionalProperties": false]
        return ["type": "object",
                "properties": ["resume": chaine, "points": liste, "termes": ["type": "array", "items": terme],
                               "devoirs": liste, "doutes": liste],
                "required": ["resume", "points", "termes", "devoirs", "doutes"], "additionalProperties": false]
    }

    static func message(transcription: String, precedente: LectureAnalyseDirect?) -> String {
        var s = "TRANSCRIPTION (la fin du cours est en bas) :\n\(transcription)"
        if let p = precedente {
            s += "\n\nANALYSE PRÉCÉDENTE (à mettre à jour) :\nrésumé : \(p.resume)\npoints : \(p.points.joined(separator: " | "))"
        }
        return s
    }
}
