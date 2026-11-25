import Foundation
import AVFoundation
import Speech
import CoreMedia

// « Écouter un cours » : le micro (par morceaux) et la transcription sur le Mac (moteur de dictée de macOS 26).
// Aucun audio ne quitte le Mac, et chaque morceau est effacé dès que son texte existe (c'est LectureModel qui l'efface).

// MARK: - Enregistreur

final class LectureRecorder {
    /// Niveau sonore (0…1, valeur efficace), environ 10 fois par seconde. Appelé hors du fil principal.
    var onNiveau: ((Float) -> Void)?
    /// Un morceau est fini et fermé : fichier, décalage en secondes depuis le début de l'enregistrement. Hors du fil principal.
    var onMorceau: ((URL, Double) -> Void)?
    /// Chaque morceau de son reçu du micro, seulement pendant l'écoute (pas en pause). Hors du fil principal.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Le micro a changé ou s'est coupé pendant le cours : (message, reprise réussie ?). Hors du fil principal.
    var onMicro: ((String, Bool) -> Void)?

    private let engine = AVAudioEngine()
    private let file_q = DispatchQueue(label: "fr.complete-cours.lecture.recorder")
    private var fichier: AVAudioFile?
    private var dossier = URL(fileURLWithPath: NSTemporaryDirectory())
    private var numero = 0
    private var framesEcrites: Int64 = 0
    private var decalageMorceau = 0.0
    private var debutMorceau = Date()
    private var secondesParMorceau = 600.0
    private var enPause = false
    private var actif = false
    private var format: AVAudioFormat?

    /// Demande le micro (la première fois, macOS affiche sa fenêtre d'autorisation) puis démarre.
    func demarrer(dossier: URL, secondesParMorceau: Double) async throws {
        let ok = await AVCaptureDevice.requestAccess(for: .audio)
        guard ok else { throw LectureErreur.micRefuse }
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dossier.path)
        let fmt = engine.inputNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { throw LectureErreur.transcription("aucun micro n'est disponible") }
        file_q.sync {
            self.dossier = dossier; self.secondesParMorceau = secondesParMorceau
            numero = 0; framesEcrites = 0; enPause = false; fichier = nil; format = fmt; actif = true
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self else { return }
            var s: Float = 0
            let n = Int(buf.frameLength)
            if let ch = buf.floatChannelData?[0], n > 0 {
                for i in 0..<n { s += ch[i] * ch[i] }
                self.onNiveau?((s / Float(n)).squareRoot())
            }
            self.file_q.async { self.ecrire(buf) }
        }
        try engine.start()
        observateur.map { NotificationCenter.default.removeObserver($0) }
        // Casque débranché, AirPods qui se coupent, changement de micro : le moteur s'arrête seul. On le relance sur le nouveau micro.
        observateur = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.reprendreApresChangement()
        }
    }

    private var observateur: NSObjectProtocol?
    private var tentativesMicro = 0

    private func reprendreApresChangement() {
        let etat: (actif: Bool, pause: Bool) = file_q.sync { (self.actif, self.enPause) }
        guard etat.actif else { return }
        let fmt = engine.inputNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            onMicro?("Le micro a été coupé : branche-le, l'écoute reprendra toute seule.", false)
            // le moteur est arrêté ; un nouvel essai dans 2 s (le micro revient parfois tout de suite)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.reprendreApresChangement() }
            return
        }
        // nouveau format : le morceau en cours est fermé (un fichier a un seul format), le suivant s'ouvre avec le nouveau
        file_q.sync { fermerMorceau(); format = fmt }
        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self else { return }
            var s: Float = 0
            let n = Int(buf.frameLength)
            if let ch = buf.floatChannelData?[0], n > 0 {
                for i in 0..<n { s += ch[i] * ch[i] }
                self.onNiveau?((s / Float(n)).squareRoot())
            }
            self.file_q.async { self.ecrire(buf) }
        }
        do {
            if !engine.isRunning { try engine.start() }
            tentativesMicro = 0
            onMicro?(etat.pause ? "Le micro a changé." : "Le micro a changé : l'écoute continue sur le nouveau micro.", true)
        } catch {
            tentativesMicro += 1
            if tentativesMicro < 5 {
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.reprendreApresChangement() }
            } else {
                onMicro?("Le micro ne repart pas (\(error.localizedDescription)) : termine le cours ou relance l'écoute.", false)
            }
        }
    }

    func pause() { file_q.sync { enPause = true; fermerMorceau() } }
    func reprendre() { file_q.sync { enPause = false } }

    /// Ferme le morceau en cours (il est livré par `onMorceau`) et coupe le micro.
    func arreter() {
        observateur.map { NotificationCenter.default.removeObserver($0) }; observateur = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file_q.sync { actif = false; fermerMorceau() }
    }

    // appelées sur file_q
    private func ecrire(_ buf: AVAudioPCMBuffer) {
        guard actif, !enPause, let format else { return }
        onBuffer?(buf)
        if fichier == nil {
            numero += 1
            let url = dossier.appendingPathComponent(String(format: "morceau_%04d.caf", numero))
            fichier = try? AVAudioFile(forWriting: url, settings: format.settings)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            decalageMorceau = Double(framesEcrites) / format.sampleRate
            debutMorceau = Date()
        }
        try? fichier?.write(from: buf)
        framesEcrites += Int64(buf.frameLength)
        if Date().timeIntervalSince(debutMorceau) >= secondesParMorceau { fermerMorceau() }
    }

    private func fermerMorceau() {
        guard let url = fichier?.url else { return }
        fichier = nil  // dernier lien : le fichier est écrit et fermé ici
        onMorceau?(url, decalageMorceau)
    }
}

// MARK: - Transcription

enum LectureTranscripteur {
    /// Transcrit un fichier audio en français, sur le Mac. Renvoie les mots avec leur heure dans le fichier.
    /// `vocabulaire` : termes du cours donnés au moteur pour qu'il les reconnaisse mieux (rien ne quitte le Mac).
    static func transcrire(_ url: URL, vocabulaire: [String] = []) async throws -> [LectureMot] {
        guard SpeechTranscriber.isAvailable else { throw LectureErreur.transcription("le moteur de dictée de ce Mac n'est pas disponible") }
        let installees = await SpeechTranscriber.installedLocales
        guard installees.contains(where: { $0.identifier.hasPrefix("fr") }) else { throw LectureErreur.langueAbsente }
        let fichier: AVAudioFile
        do { fichier = try AVAudioFile(forReading: url) } catch { throw LectureErreur.transcription("fichier audio illisible") }
        let transcripteur = SpeechTranscriber(locale: Locale(identifier: "fr_FR"), transcriptionOptions: [], reportingOptions: [],
                                              attributeOptions: [.audioTimeRange])
        let analyseur = SpeechAnalyzer(modules: [transcripteur])
        await appliquerVocabulaire(vocabulaire, a: analyseur)
        let collecte = Task { () -> [LectureMot] in
            var mots: [LectureMot] = []
            do {
                for try await r in transcripteur.results {
                    for run in r.text.runs {
                        let t = String(r.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        if t.isEmpty { continue }
                        let tr = run.audioTimeRange
                        mots.append(LectureMot(texte: t, debut: tr?.start.seconds ?? 0, duree: tr?.duration.seconds ?? 0))
                    }
                }
            } catch {}
            return mots
        }
        do {
            if let derniere = try await analyseur.analyzeSequence(from: fichier) {
                try await analyseur.finalizeAndFinish(through: derniere)
            } else {
                await analyseur.cancelAndFinishNow()
            }
        } catch {
            collecte.cancel()
            throw LectureErreur.transcription(error.localizedDescription)
        }
        return await collecte.value
    }

    /// Donne la liste de mots du cours au moteur (contextualStrings). Un échec n'est pas grave : la transcription marche sans.
    static func appliquerVocabulaire(_ termes: [String], a analyseur: SpeechAnalyzer) async {
        guard !termes.isEmpty else { return }
        let contexte = AnalysisContext()
        contexte.contextualStrings[.general] = termes
        try? await analyseur.setContext(contexte)
    }
}
