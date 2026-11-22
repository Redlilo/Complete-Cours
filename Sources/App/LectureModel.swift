import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// « Écouter un cours » : état de l'écoute, des cours enregistrés et du traitement par l'IA.
/// Une seule instance (comme CoursModel) pour que l'écoute continue quand on change de partie.
@MainActor
final class LectureModel: ObservableObject {
    static let shared = LectureModel()

    enum Etat { case repos, ecoute, pause, termine }
    enum Installation: Equatable { case repos, enCours, ok, erreur(String) }
    /// Écran à ouvrir tout seul : la relecture à la fin du cours, la fiche quand elle est prête.
    enum Ouverture: Equatable { case relecture(UUID), fiche(UUID) }

    @Published private(set) var base: LectureBase
    @Published private(set) var etat: Etat = .repos
    @Published private(set) var niveau: Float = 0
    @Published private(set) var duree: TimeInterval = 0
    /// Message à montrer en haut de l'écran (erreur ou information).
    @Published var message: String?
    @Published var aOuvrir: Ouverture?
    /// Installation de la reconnaissance de la voix (téléchargement lancé seulement par un clic de l'élève).
    @Published private(set) var installationVoix: Installation = .repos
    @Published private(set) var journalInstallation = ""

    private let store: LectureStore
    private let enregistreur = LectureRecorder()
    private var coursEnCours: UUID?
    private var dossierAudio: URL?
    private var chrono: Timer?
    private var dernierSon = Date()
    private var niveauMax: Float = 0
    private var morceauxEnCours = 0
    private var enTraitement: Set<UUID> = []
    private var limiteJusqua = Date.distantPast
    /// Réessai automatique des cours en attente (limite atteinte ou pas de connexion).
    private var relance: Task<Void, Never>?
    /// Empreintes des phrases du cours en cours (en mémoire seulement : jamais écrites sur le disque, jamais celles d'élèves gardées).
    private var candidatsVoix: [UUID: [UUID: [Float]]] = [:]

    init(store: LectureStore = LectureStore()) {
        self.store = store
        var b = store.charger()
        LectureStore.nettoyer(&b)
        base = b
        store.sauver(b)
        enregistreur.onNiveau = { [weak self] n in Task { @MainActor in self?.recevoirNiveau(n) } }
        enregistreur.onMorceau = { [weak self] url, decalage in Task { @MainActor in self?.recevoirMorceau(url, decalage: decalage) } }
    }

    var reglages: LectureReglages {
        get { base.reglages }
        set { base.reglages = newValue; sauver() }
    }
    var cours: [LectureCours] { base.cours.sorted { $0.date > $1.date } }
    var enregistre: Bool { etat == .ecoute || etat == .pause }

    /// Phrase qui dit si on t'entend bien (d'après les dernières secondes).
    var libelleNiveau: (texte: String, couleur: Color) {
        if niveau < 0.015 { return ("Presque rien entendu : rapproche-toi du Mac ou monte le volume d'entrée.", .red) }
        if niveau < 0.04 { return ("Niveau faible : la transcription risque d'être moins bonne.", .orange) }
        return ("Bon niveau : on t'entend bien.", .green)
    }

    private func sauver() { store.sauver(base) }

    private func modifier(_ id: UUID, _ f: (inout LectureCours) -> Void) {
        guard let i = base.cours.firstIndex(where: { $0.id == id }) else { return }
        f(&base.cours[i])
        sauver()
    }

    func cours(_ id: UUID?) -> LectureCours? { id.flatMap { i in base.cours.first { $0.id == i } } }

    /// Note (ou retire) l'accord d'un prof ; crée le prof s'il n'existe pas encore.
    func accorder(_ nom: String, _ ok: Bool) {
        let n = nom.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let date = ok ? Date().formatted(date: .numeric, time: .omitted) : ""
        if let i = base.reglages.profs.firstIndex(where: { $0.nom == n }) {
            base.reglages.profs[i].accord = ok; base.reglages.profs[i].dateAccord = date
        } else {
            base.reglages.profs.append(LectureProf(nom: n, accord: ok, dateAccord: date))
        }
        sauver()
    }

    // MARK: Écoute

    func demarrer(matiere: String, prof: String, titre: String) {
        guard etat == .repos else { return }
        guard let p = base.reglages.profs.first(where: { $0.nom == prof }), p.accord else {
            message = "Coche d'abord « J'ai l'accord de ce prof » dans les Réglages de cette partie."
            return
        }
        let id = UUID()
        let t = titre.trimmingCharacters(in: .whitespaces)
        let dossier = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ecoute-\(id.uuidString)", isDirectory: true)
        message = nil
        Task {
            do {
                try await enregistreur.demarrer(dossier: dossier, secondesParMorceau: Double(base.reglages.minutesParMorceau) * 60)
            } catch {
                message = error.localizedDescription
                return
            }
            let jour = Date().formatted(.dateTime.day().month(.twoDigits))
            base.cours.append(LectureCours(id: id, titre: t.isEmpty ? "\(matiere) du \(jour)" : t, matiere: matiere, prof: prof,
                                           statut: .enregistrement))
            sauver()
            coursEnCours = id; dossierAudio = dossier
            niveauMax = 0; duree = 0; dernierSon = Date(); etat = .ecoute
            chrono = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tic() }
            }
        }
    }

    func pause() {
        switch etat {
        case .ecoute: enregistreur.pause(); etat = .pause
        case .pause: enregistreur.reprendre(); dernierSon = Date(); etat = .ecoute
        default: break
        }
    }

    func terminer() {
        guard enregistre else { return }
        chrono?.invalidate(); chrono = nil
        etat = .termine
        enregistreur.arreter()
        Task { try? await Task.sleep(for: .milliseconds(600)); finaliserSiPret() }
    }

    private func tic() {
        guard etat == .ecoute else { return }
        duree += 1
        let r = base.reglages
        if Date().timeIntervalSince(dernierSon) > Double(r.minutesSilenceAvantArret) * 60 || duree > Double(r.minutesMaximum) * 60 {
            message = "L'écoute s'est arrêtée toute seule (silence prolongé ou durée maximale)."
            terminer()
        }
    }

    private func recevoirNiveau(_ n: Float) {
        niveau = niveau * 0.7 + n * 0.3
        niveauMax = max(niveauMax, n)
        if n > 0.01 { dernierSon = Date() }
    }

    private func recevoirMorceau(_ url: URL, decalage: Double) {
        guard let id = coursEnCours else { try? FileManager.default.removeItem(at: url); return }
        morceauxEnCours += 1
        Task {
            do {
                let mots = try await LectureTranscripteur.transcrire(url)
                let r = base.reglages
                var phrases = LectureTexte.phrases(depuis: mots, decalage: decalage)
                for i in phrases.indices { phrases[i].texte = LectureTexte.corriger(phrases[i].texte, reglages: r) }
                await reconnaitreLesVoix(&phrases, audio: url, decalage: decalage, cours: id)
                modifier(id) { $0.phrases += phrases }
            } catch {
                modifier(id) { $0.erreur = error.localizedDescription }
            }
            try? FileManager.default.removeItem(at: url)   // l'audio est effacé dès que le texte existe
            morceauxEnCours -= 1
            finaliserSiPret()
        }
    }

    /// Calcule l'empreinte de chaque phrase (le temps de ce morceau) et, si la voix du prof est déjà connue, dit qui parle.
    private func reconnaitreLesVoix(_ phrases: inout [LecturePhrase], audio: URL, decalage: Double, cours id: UUID) async {
        guard LectureVoix.disponible, !phrases.isEmpty, let prof = cours(id)?.prof else { return }
        let segments = phrases.map { (debut: max(0, $0.debut - decalage), fin: max(0, $0.fin - decalage)) }
        do {
            let emb = try await Task.detached(priority: .userInitiated) { () -> [[Float]?] in
                let wav = try LectureVoix.convertirEn16k(audio)
                defer { try? FileManager.default.removeItem(at: wav) }
                return try LectureVoix.empreintes(wav: wav, segments: segments)
            }.value
            let profil = base.voix?[prof], lex = base.reglages.lexique
            for (i, e) in emb.enumerated() {
                if let e { candidatsVoix[id, default: [:]][phrases[i].id] = e }
                if let profil { etiqueter(&phrases[i], e, profil, lexique: lex) }
            }
        } catch {
            modifier(id) { $0.erreur = error.localizedDescription }
        }
    }

    /// Voix (si elle est mesurable) et contenu de la phrase décident ensemble : prof, élève ? ou incertain.
    private func etiqueter(_ p: inout LecturePhrase, _ e: [Float]?, _ profil: LectureEmpreinte?, lexique: [String]) {
        let s = (e != nil && profil != nil) ? LectureVoix.cosinus(e!, profil!.vecteur) : nil
        let q = LectureVoix.decider(score: s, indice: LectureTexte.indiceProf(p.texte, lexique: lexique))
        p.score = s; p.qui = q; p.garder = q != .autre
    }

    /// Fin du cours : au début (premières écoutes), retient la voix qui parle le plus ; puis étiquette tout le cours,
    /// avec la voix si elle est connue, sinon d'après ce qui est dit.
    private func apprendreLaVoix(_ id: UUID) {
        defer { candidatsVoix[id] = nil }
        guard let c = cours(id) else { return }
        let lex = base.reglages.lexique
        let emb = candidatsVoix[id] ?? [:]
        var profil = base.voix?[c.prof]
        let premiere = profil == nil
        if (profil?.secondes ?? 0) < LectureVoix.secondesPourApprendre, !emb.isEmpty {
            let cands = c.phrases.compactMap { p in
                emb[p.id].map { LectureVoix.Candidat(vecteur: $0, duree: max(0, p.fin - p.debut), indice: LectureTexte.indiceProf(p.texte, lexique: lex)) }
            }
            if let appris = LectureVoix.apprendre(candidats: cands, existante: profil) {
                profil = appris
                var v = base.voix ?? [:]; v[c.prof] = appris; base.voix = v; sauver()
                if premiere {
                    message = "J'ai retenu la voix de \(c.prof) (celle qui parle le plus). Les élèves sont maintenant repérés tout seuls ; tu peux oublier cette voix dans les réglages."
                }
            } else if premiere {
                message = "Pas assez de voix pour retenir celle de \(c.prof) : ce sera pour le prochain cours. En attendant, je repère les élèves d'après ce qui est dit."
            }
        }
        let p0 = profil
        modifier(id) { cours in
            for i in cours.phrases.indices { etiqueter(&cours.phrases[i], emb[cours.phrases[i].id], p0, lexique: lex) }
        }
    }

    /// Installe la reconnaissance de la voix dans le dossier de l'app (environ 250 Mo téléchargés, 1,1 Go sur le disque).
    func installerLaVoix() {
        guard installationVoix != .enCours else { return }
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("Voix/installer.sh"),
              FileManager.default.fileExists(atPath: script.path) else {
            installationVoix = .erreur("L'installateur est introuvable dans l'app : reconstruis-la avec build.sh.")
            return
        }
        installationVoix = .enCours
        journalInstallation = ""
        let destination = LectureVoix.dossierInstallation
        Task.detached {
            let p = Process(), tuyau = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, destination.path]
            p.standardOutput = tuyau; p.standardError = tuyau
            tuyau.fileHandleForReading.readabilityHandler = { h in
                if let t = String(data: h.availableData, encoding: .utf8), !t.isEmpty {
                    Task { @MainActor in LectureModel.shared.ajouterAuJournal(t) }
                }
            }
            var echec = ""
            do { try p.run(); p.waitUntilExit() } catch { echec = error.localizedDescription }
            tuyau.fileHandleForReading.readabilityHandler = nil
            let raison = echec, ok = echec.isEmpty && p.terminationStatus == 0 && LectureVoix.disponible
            await MainActor.run { LectureModel.shared.finInstallation(ok: ok, raison: raison) }
        }
    }

    private func finInstallation(ok: Bool, raison: String) {
        if ok {
            installationVoix = .ok
            message = "La reconnaissance de la voix est installée : elle sera utilisée dès ton prochain cours."
        } else {
            let fin = journalInstallation.split(separator: "\n").last.map(String.init) ?? raison
            installationVoix = .erreur(fin.isEmpty ? "L'installation a échoué." : fin)
        }
    }

    private func ajouterAuJournal(_ texte: String) {
        let lignes = (journalInstallation + texte).split(separator: "\n").suffix(5)
        journalInstallation = lignes.joined(separator: "\n")
    }

    func oublierLaVoix(_ nom: String) {
        var voix = base.voix ?? [:]; voix[nom] = nil; base.voix = voix; sauver()
    }

    /// Phrase qui dit où en est la reconnaissance de la voix de ce prof.
    func etatVoix(_ prof: String) -> (texte: String, couleur: Color) {
        if !LectureVoix.disponible { return ("Reconnaissance de la voix pas installée (réglages de l'écoute) : les élèves sont repérés d'après ce qui est dit.", .secondary) }
        if let e = base.voix?[prof] {
            return e.secondes >= LectureVoix.secondesPourApprendre
                ? ("Voix du prof apprise : les élèves sont repérés tout seuls.", .green)
                : ("Voix du prof en cours d'apprentissage (\(Int(e.secondes / 60)) min sur \(Int(LectureVoix.secondesPourApprendre / 60))).", .green)
        }
        return ("Voix du prof pas encore apprise : elle sera retenue pendant ce premier cours.", .secondary)
    }

    private func finaliserSiPret() {
        guard etat == .termine, morceauxEnCours == 0, let id = coursEnCours else { return }
        apprendreLaVoix(id)
        let max = niveauMax
        modifier(id) { c in
            c.niveauMax = max
            if c.phrases.isEmpty {
                c.statut = .erreur
                c.erreur = c.erreur ?? String(format: "Aucun texte reconnu. Niveau le plus fort du micro : %.3f (une voix normale à 50 cm donne environ 0,05 à 0,3).", max)
            } else { c.statut = .aRelire; c.erreur = nil }
        }
        if cours(id)?.statut == .aRelire { aOuvrir = .relecture(id) }
        if let d = dossierAudio { try? FileManager.default.removeItem(at: d) }
        coursEnCours = nil; dossierAudio = nil; etat = .repos; niveau = 0
    }

    // MARK: Cours

    func importer(texte: String, matiere: String, prof: String, titre: String) {
        let phrases = texte.components(separatedBy: CharacterSet(charactersIn: "\n"))
            .flatMap { $0.split(omittingEmptySubsequences: true, whereSeparator: { ".!?".contains($0) }) .map { String($0).trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
            .map { LecturePhrase(debut: 0, fin: 0, texte: $0) }
        guard !phrases.isEmpty else { message = "Colle d'abord un texte."; return }
        base.cours.append(LectureCours(titre: titre.isEmpty ? "Cours importé" : titre, matiere: matiere, prof: prof, phrases: phrases))
        sauver()
    }

    func basculer(_ phrase: UUID, dans id: UUID) {
        modifier(id) { c in if let i = c.phrases.firstIndex(where: { $0.id == phrase }) { c.phrases[i].garder.toggle() } }
    }

    /// L'élève corrige une phrase à la relecture : les mots changés sont retenus pour les prochains cours (« empère=ampère »).
    func modifierPhrase(_ phrase: UUID, dans id: UUID, texte: String) {
        let nouveau = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nouveau.isEmpty, let ancien = cours(id)?.phrases.first(where: { $0.id == phrase })?.texte, ancien != nouveau else { return }
        modifier(id) { c in if let i = c.phrases.firstIndex(where: { $0.id == phrase }) { c.phrases[i].texte = nouveau } }
        let apprises = LectureTexte.corrections(entre: ancien, et: nouveau).filter { !base.reglages.corrections.contains($0) }
        if !apprises.isEmpty {
            base.reglages.corrections += apprises
            sauver()
            message = "Retenu pour les prochains cours : " + apprises.joined(separator: ", ")
        }
    }

    func tout(_ garder: Bool, dans id: UUID) {
        modifier(id) { c in for i in c.phrases.indices { c.phrases[i].garder = garder } }
    }

    func supprimer(_ ids: Set<UUID>) {
        base.cours.removeAll { ids.contains($0.id) && $0.id != coursEnCours }
        sauver()
    }

    func effacerProf(_ nom: String) {
        base.cours.removeAll { $0.prof == nom && $0.id != coursEnCours }
        oublierLaVoix(nom)
        sauver()
    }

    // MARK: IA (le moteur choisi dans les Réglages de Complète-Cours)

    var etatMoteur: RevisionEngineStatus { RevisionWiring.status() }

    func envoyer(_ id: UUID) {
        modifier(id) { $0.statut = .enAttente; $0.erreur = nil }
        traiter(id)
    }

    /// Relance les cours restés en attente (hors ligne ou limite atteinte), au plus tôt à la fin de la pause demandée.
    func relancerEnAttente() {
        guard Date() >= limiteJusqua else { planifierRelance(); return }
        for c in base.cours where c.statut == .enAttente { traiter(c.id) }
    }

    /// Le réessai promis a lieu même si l'élève ne revient pas sur cet écran.
    private func planifierRelance() {
        relance?.cancel()
        let attente = max(1, limiteJusqua.timeIntervalSinceNow)
        relance = Task { [weak self] in
            try? await Task.sleep(for: .seconds(attente))
            guard !Task.isCancelled else { return }
            self?.relancerEnAttente()
        }
    }

    /// Écoute en cours, ou fin de transcription pas encore terminée.
    var occupe: Bool { etat != .repos }

    private func traiter(_ id: UUID) {
        guard !enTraitement.contains(id), let c = cours(id) else { return }
        enTraitement.insert(id)
        modifier(id) { $0.statut = .traitement }
        let r = base.reglages
        Task {
            defer { enTraitement.remove(id) }
            do {
                let moteur = try EngineFactory.make(RunSettings.current())
                guard let g = moteur as? StructuredGenerator else {
                    throw LectureErreur.transcription("ce moteur ne sait pas écrire de fiche : choisis-en un autre dans les Réglages")
                }
                let res = try await LecturePipeline.traiter(c, reglages: r, generator: g)
                modifier(id) { $0.fiche = res.fiche; $0.retire = res.retire; $0.statut = .pret; $0.traiteLe = Date(); $0.erreur = nil
                    $0.titre = res.fiche.titre }
                aOuvrir = .fiche(id)
            } catch {
                let m = error.localizedDescription
                let basLimite = m.lowercased()
                if error is URLError || ["limite", "limit", "quota", "429", "surcharg", "overloaded"].contains(where: basLimite.contains) {
                    limiteJusqua = Date().addingTimeInterval(600)
                    modifier(id) { $0.statut = .enAttente; $0.erreur = "Pas possible pour le moment (limite atteinte ou pas de connexion) : réessai automatique dans 10 minutes." }
                    planifierRelance()
                } else {
                    modifier(id) { $0.statut = .erreur; $0.erreur = m }
                }
            }
        }
    }

    // MARK: Texte de la fiche

    static func texteDeLaFiche(_ c: LectureCours) -> String {
        guard let f = c.fiche else { return "" }
        var s = "# \(f.titre)\n\(c.matiere) · \(c.prof) · \(c.date.formatted(date: .numeric, time: .omitted))\n\n"
        if !f.devoirs.isEmpty { s += "## Devoirs et dates (à vérifier sur Pronote)\n" + f.devoirs.map { "- \($0.quoi) — \($0.pour)" }.joined(separator: "\n") + "\n\n" }
        if !f.definitions.isEmpty { s += "## Définitions\n" + f.definitions.map { "- \($0.terme) : \($0.definition)" }.joined(separator: "\n") + "\n\n" }
        if !f.formules.isEmpty { s += "## Formules\n" + f.formules.map { "- \($0.formule) \($0.unite)" }.joined(separator: "\n") + "\n\n" }
        return s + f.resume + "\n"
    }

    /// La fiche d'un cours écouté, présentée comme les fiches de révision (même PDF).
    static func ficheDeRevision(_ c: LectureCours) -> RevisionSummary? {
        guard let f = c.fiche else { return nil }
        var points = f.devoirs.map { "À faire : \($0.quoi) — \($0.pour) (à vérifier sur Pronote)" }
        for ligne in f.resume.components(separatedBy: "\n") {
            var t = ligne.trimmingCharacters(in: .whitespaces)
            while let premier = t.first, "#-*•".contains(premier) { t.removeFirst() }
            t = t.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { points.append(t) }
        }
        return RevisionSummary(title: f.titre, keyPoints: points,
                               vocabulary: f.definitions.map { RevisionTerm(term: $0.terme, definition: $0.definition) },
                               formulas: f.formules.map { [$0.formule, $0.unite].filter { !$0.isEmpty }.joined(separator: " ") },
                               tips: f.aVerifier.map { "À vérifier : \($0)" })
    }

    /// « Enregistrer en PDF… » : proposé dans le dossier de la matière, s'il existe dans « Mes cours ».
    func enregistrerLaFiche(_ c: LectureCours) {
        guard let fiche = Self.ficheDeRevision(c) else { return }
        let panel = NSSavePanel()
        panel.title = "Enregistrer la fiche en PDF"
        panel.prompt = "Enregistrer"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Fiche – \(fiche.title).pdf"
        let dossier = LibraryModel.shared.root.appendingPathComponent(c.matiere, isDirectory: true)
        if !c.matiere.isEmpty, FileManager.default.fileExists(atPath: dossier.path) { panel.directoryURL = dossier }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let nom = "\(c.matiere) · \(c.date.formatted(date: .numeric, time: .omitted))"
            try RevisionExport.summaryPDF(fiche, documentName: nom).write(to: url, options: .atomic)
            message = "Fiche enregistrée : \(url.lastPathComponent)."
        } catch {
            message = "La fiche n'a pas pu être enregistrée : \(error.localizedDescription)"
        }
    }

    func copierLaFiche(_ c: LectureCours) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.texteDeLaFiche(c), forType: .string)
        message = "Fiche copiée."
    }
}
