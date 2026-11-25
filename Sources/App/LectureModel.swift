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

    // Direct : affichage seulement, rien n'est écrit sur le disque ni dans la base.
    @Published private(set) var directFinal: [String] = []
    @Published private(set) var directProvisoire: String = ""
    @Published private(set) var analyseDirect: LectureAnalyseDirect?
    @Published private(set) var analyseDirectEnCours = false
    @Published private(set) var erreurDirect: String? { didSet { if let e = erreurDirect { BugJournal.shared.noter("Écoute en direct", e) } } }
    @Published var analyseDirecteActive: Bool = (UserDefaults.standard.object(forKey: "lecture.analyseDirecte") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(analyseDirecteActive, forKey: "lecture.analyseDirecte") }
    }
    private var direct = LectureDirect()
    private var derniereAnalyse = Date()
    private var caracteresAnalyses = 0

    private let store: LectureStore
    private let enregistreur = LectureRecorder()
    private var coursEnCours: UUID?
    private var dossierAudio: URL?
    private var chrono: Timer?
    private var dernierSon = Date()
    private var niveauMax: Float = 0
    /// Morceaux en cours de transcription, par cours (un morceau en retard ne se mélange jamais à un autre cours).
    private let attente = LectureAttente()
    private var analyseSerie: LectureAnalyseSerie?
    private var dossiersEnSursis: [UUID: URL] = [:]
    private var finEnCours: Task<Void, Never>?
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
        enregistreur.onMicro = { [weak self] m, _ in Task { @MainActor in self?.message = m } }
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
        let avant = base.cours[i].erreur
        f(&base.cours[i])
        if let e = base.cours[i].erreur, e != avant { BugJournal.shared.noter("Écoute (cours)", e) }
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
        guard etat == .repos, !demarrageEnCours else { return }
        guard let p = base.reglages.profs.first(where: { $0.nom == prof }), p.accord else {
            message = "Coche d'abord « J'ai l'accord de ce prof » dans les Réglages de cette partie."
            return
        }
        let id = UUID()
        let t = titre.trimmingCharacters(in: .whitespaces)
        let dossier = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ecoute-\(id.uuidString)", isDirectory: true)
        message = nil
        demarrageEnCours = true
        Task {
            defer { demarrageEnCours = false }
            do {
                try await enregistreur.demarrer(dossier: dossier, secondesParMorceau: Double(base.reglages.minutesParMorceau) * 60)
            } catch {
                message = error.localizedDescription
                BugJournal.shared.noter("Écoute", error.localizedDescription)
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
            demarrerLeDirect()
        }
    }

    private var generationDirect = 0
    /// Évite deux démarrages d'écoute si on clique deux fois avant que le micro soit prêt.
    private var demarrageEnCours = false

    private func demarrerLeDirect() {
        directFinal = []; directProvisoire = ""; analyseDirect = nil; analyseDirectEnCours = false; erreurDirect = nil
        derniereAnalyse = Date(); caracteresAnalyses = 0
        generationDirect += 1
        let generation = generationDirect
        analyseSerie?.reinitialiser()
        analyseSerie = LectureAnalyseSerie(
            aAnalyser: { [weak self] in
                guard let self, generation == self.generationDirect else { return false }
                return !self.directFinal.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            },
            executer: { [weak self] in await self?.analyserDirect(generation: generation) })
        let d = LectureDirect()
        direct = d
        enregistreur.onBuffer = { [weak d] buf in d?.ajouter(buf) }   // le début est gardé en mémoire jusqu'à ce que le moteur soit prêt
        d.onTexte = { [weak self, weak d] texte, definitif in
            Task { @MainActor in
                guard let self, let d, self.direct === d else { return }
                if definitif {
                    let t = LectureTexte.nettoyerTexte(LectureTexte.corriger(texte, reglages: self.base.reglages))
                    if !t.isEmpty { self.directFinal.append(t) }
                    self.directProvisoire = ""
                } else {
                    self.directProvisoire = texte
                }
            }
        }
        d.onErreur = { [weak self, weak d] m in
            Task { @MainActor in
                guard let self, let d, self.direct === d else { return }
                self.erreurDirect = m
            }
        }
        Task {
            do {
                try await d.demarrer(vocabulaire: vocabulaireDuCours())
                // Cours déjà terminé (ou autre cours lancé) pendant le démarrage : on referme ce direct, sinon il resterait ouvert.
                guard direct === d, enregistre else { await d.arreter(); return }
                enregistreur.onBuffer = { [weak d] buf in d?.ajouter(buf) }
            } catch {
                if direct === d { erreurDirect = error.localizedDescription }
            }
        }
    }

    // MARK: Analyse en direct

    /// Termes du cours (lexique, matière, prénoms, prof) donnés au moteur de dictée pour mieux reconnaître le vocabulaire.
    private func vocabulaireDuCours() -> [String] {
        let c = coursEnCours.flatMap { cours($0) }
        return LectureVocabulaire.contextualStrings(reglages: base.reglages, matiere: c?.matiere ?? "", prof: c?.prof ?? "")
    }

    private var texteDirectPourIA: String {
        let prof = coursEnCours.flatMap { cours($0)?.prof } ?? ""
        let t = LecturePipeline.retirerPrenomsEtCorriger(directFinal.joined(separator: " "), base.reglages, prof: prof)
        return String(t.suffix(14000))
    }

    /// Lance une analyse tout de suite (ignorée si déjà en cours ou rien à analyser).
    func analyserMaintenant() { analyseSerie?.demander() }

    /// Corps d'une analyse (lancé par `analyseSerie`, une à la fois) : un résultat qui arrive après le début d'un autre cours est ignoré.
    private func analyserDirect(generation: Int) async {
        guard generation == generationDirect else { return }
        let brut = directFinal.joined(separator: " ")
        let texte = texteDirectPourIA
        let precedente = analyseDirect
        analyseDirectEnCours = true
        derniereAnalyse = Date()
        caracteresAnalyses = brut.count
        defer { if generation == generationDirect { analyseDirectEnCours = false } }
        do {
                // Modèle léger pour l'analyse en direct (appels fréquents) ; la fiche finale garde le modèle de tes Réglages.
                var reglagesIA = RunSettings.current()
                if reglagesIA.engine == .claudeCode { reglagesIA.claudeCodeModel = "haiku"; reglagesIA.claudeCodeEffort = "low" }
                else if reglagesIA.engine == .claude { reglagesIA.claudeModel = "claude-haiku-5-5" }
                let moteur = try EngineFactory.make(reglagesIA)
                guard let g = moteur as? StructuredGenerator else {
                    throw LectureErreur.transcription("ce moteur ne sait pas analyser en direct : choisis-en un autre dans les Réglages")
                }
                let json = try await g.generate(system: LectureAnalyseDirectPrompts.systeme,
                                                userText: LectureAnalyseDirectPrompts.message(transcription: texte, precedente: precedente),
                                                images: [], schema: LectureAnalyseDirectPrompts.schema)
                guard generation == generationDirect else { return }
                if let a = LectureAnalyseDirect.depuis(json: json) { analyseDirect = a; erreurDirect = nil }
                else { erreurDirect = "L'analyse en direct n'a pas pu être lue : nouvel essai bientôt." }
        } catch {
            if generation == generationDirect { erreurDirect = error.localizedDescription }
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
        enregistreur.arreter()          // livre le dernier morceau (onMorceau) avant de rendre la main
        enregistreur.onBuffer = nil
        let d = direct
        let serie = analyseSerie
        guard let id = coursEnCours else { return }
        finEnCours?.cancel()
        finEnCours = Task {
            await d.arreter()
            try? await Task.sleep(for: .milliseconds(250))   // laisse arriver les derniers textes définitifs et le dernier morceau
            directProvisoire = ""
            // Analyse finale : si une analyse tourne déjà, elle repart juste après au lieu d'être sautée.
            if analyseDirecteActive { serie?.demanderFinale() }
            // Les derniers morceaux déjà enregistrés sont transcrits avant de clore le cours (délai maximal : on ne bloque jamais).
            let fini = await attente.attendreFin(id, delaiMax: LectureFin.delaiMaxMorceaux)
            if !fini {
                message = "Certains morceaux d'audio sont encore en cours de transcription : le texte sera complété tout seul à leur arrivée."
            }
            finaliserSiPret(force: !fini)
        }
    }

    private func tic() {
        guard etat == .ecoute else { return }
        duree += 1
        if analyseDirecteActive, !analyseDirectEnCours, Date().timeIntervalSince(derniereAnalyse) >= 120,
           directFinal.joined(separator: " ").count - caracteresAnalyses >= 350 {
            analyseSerie?.demander()
        }
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
        // Le morceau appartient au cours de son dossier, même s'il arrive après la fin du cours : il est transcrit, jamais jeté.
        guard let id = LectureFin.cours(deMorceau: url) ?? coursEnCours, cours(id) != nil else {
            try? FileManager.default.removeItem(at: url); return
        }
        attente.suivre(id, { [self] in
            do {
                let c0 = cours(id)
                let mots = try await LectureTranscripteur.transcrire(url, vocabulaire: LectureVocabulaire.contextualStrings(
                    reglages: base.reglages, matiere: c0?.matiere ?? "", prof: c0?.prof ?? ""))
                let r = base.reglages
                // phrases coupées par une pause recollées, répétitions et phrases inventées retirées, puis fautes de vocabulaire corrigées
                var phrases = LectureTexte.nettoyer(LectureTexte.recoller(LectureTexte.phrases(depuis: mots, decalage: decalage)))
                for i in phrases.indices { phrases[i].texte = LectureTexte.corriger(phrases[i].texte, reglages: r) }
                await reconnaitreLesVoix(&phrases, audio: url, decalage: decalage, cours: id)
                modifier(id) { $0.phrases = LectureTexte.inserer(phrases, dans: $0.phrases) }   // dans l'ordre du temps, phrase coupée entre deux morceaux recollée
            } catch {
                modifier(id) { $0.erreur = error.localizedDescription }
            }
            try? FileManager.default.removeItem(at: url)   // l'audio est effacé dès que le texte existe
        }, apres: { [self] in
            if coursEnCours == id { finaliserSiPret() } else { rattraperCours(id) }
        })
    }

    /// Un morceau est arrivé après la fin du cours (délai dépassé) : le texte est ajouté à la fiche à relire, puis le dossier audio est effacé.
    private func rattraperCours(_ id: UUID) {
        guard attente.nombre(id) == 0 else { return }
        modifier(id) { c in
            if !c.phrases.isEmpty, c.statut == .erreur { c.statut = .aRelire; c.erreur = nil }
        }
        if let d = dossiersEnSursis.removeValue(forKey: id) { try? FileManager.default.removeItem(at: d) }
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
            for (i, e) in emb.enumerated() where i < phrases.count {
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

    /// `force` : le délai d'attente est dépassé, on clôt avec ce qui est transcrit (les morceaux en retard seront ajoutés ensuite).
    private func finaliserSiPret(force: Bool = false) {
        guard etat == .termine, let id = coursEnCours, force || attente.nombre(id) == 0 else { return }
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
        if let d = dossierAudio {
            if attente.nombre(id) == 0 { try? FileManager.default.removeItem(at: d) } else { dossiersEnSursis[id] = d }
        }
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
