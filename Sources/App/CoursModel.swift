import Foundation
import PDFKit
import AppKit

// MARK: - États affichés par l'interface

/// Ce que l'élève voit pendant la recherche des zones.
enum AnalysisState: Equatable {
    case idle
    case running(fraction: Double, label: String)
    case done
}

struct RunProgress: Equatable {
    var fraction: Double
    var label: String
}

/// `zoneID` : renseigné quand le traitement ne concerne qu'une seule zone (« Régénérer »).
enum RunState: Equatable {
    case idle
    case running(RunProgress, zoneID: Int?)
}

/// Un traitement qui n'a pas pu se faire (clé refusée, moteur indisponible…).
struct RunProblem: Equatable {
    var message: String
    /// Le remède se trouve dans les Réglages : l'interface propose alors le bouton qui les ouvre.
    var needsSettings: Bool

    init(message: String, needsSettings: Bool) {
        self.message = message
        self.needsSettings = needsSettings
    }

    init(_ error: Error) {
        if let e = error as? EngineError {
            self.init(message: Fr.sentence(e.localizedDescription), needsSettings: e.isFatal)
        } else if let e = error as? SchemaErreur, case .indisponible = e {
            self.init(message: Fr.sentence(e.localizedDescription), needsSettings: true)
        } else {
            self.init(message: Fr.sentence(error.localizedDescription), needsSettings: false)
        }
    }
}

/// Message d'information qui reste affiché jusqu'à ce que l'élève le ferme.
struct Notice: Equatable, Identifiable {
    enum Style { case info, success, warning }
    let id = UUID()
    var style: Style
    var text: String
    var revealURL: URL? = nil
    /// Propose « Faire la fiche de ce cours » (après l'enregistrement du PDF complété).
    var sheetURL: URL? = nil
    /// Propose le bouton « Réessayer les zones en erreur ».
    var offersRetry = false
}

enum SelectionSource { case list, preview, program }

/// Demande de défilement : un numéro de série fait qu'un second clic sur la même zone défile à nouveau.
struct RevealRequest: Equatable {
    var serial: Int
    var zoneID: Int
    var source: SelectionSource
}

/// Une zone dessinée à la main, à recréer si l'on relit le PDF.
private struct ManualSpec {
    var page: Int
    var rect: CGRect
}

// MARK: - Modèle

/// État de l'unique fenêtre : le PDF ouvert, ses zones, le traitement en cours.
/// Tout se passe sur le thread principal ; les calculs lourds (analyse, complétion, export) tournent
/// dans des tâches à part et ne rendent la main qu'avec leurs résultats.
@MainActor
final class CoursModel: ObservableObject {
    static let shared = CoursModel()

    // Document
    @Published private(set) var fileURL: URL?
    @Published private(set) var document: PDFDocument?
    @Published private(set) var pageCount = 0
    /// Pourquoi le dernier PDF n'a pas pu être ouvert (affiché dans l'écran d'accueil).
    @Published private(set) var openError: String?
    @Published private(set) var recents: [URL]

    // Analyse
    @Published private(set) var analysis: AnalysisState = .idle
    @Published private(set) var zones: [Zone] = []
    @Published private(set) var skippedPages: [Int] = []

    // Traitement
    @Published private(set) var run: RunState = .idle
    @Published private(set) var runProblem: RunProblem?
    @Published private(set) var isSaving = false
    @Published private(set) var isAddingZone = false
    @Published private(set) var notice: Notice?
    @Published private(set) var hasUnsavedChanges = false

    // Mémoire des corrections
    /// Explication affichée dans la liste pour les zones réglées d'après les corrections passées (« Ignorée comme d'habitude »).
    @Published private(set) var learnedNotes: [Int: String] = [:]
    /// Nombre de corrections mémorisées (pour « Oublier mes corrections »).
    @Published private(set) var learnedCount = 0

    // Sélection et dessin d'une zone
    @Published private(set) var selectedZoneID: Int?
    @Published private(set) var revealRequest: RevealRequest?
    @Published private(set) var isDrawingZone = false

    /// L'aperçu, pour le rafraîchir et le zoomer (référence faible : c'est la vue qui le possède).
    weak var previewView: PDFView?
    /// Appelé à chaque avancement du traitement (utilisé par --selftest).
    var progressObserver: ((Double, String) -> Void)?

    private let settingsProvider: () -> RunSettings
    private let engineFactory: (RunSettings) throws -> CompletionEngine
    private let dialogs: Dialogs
    private let defaults: UserDefaults
    private let learning: ZoneLearning
    /// Exemples déjà remplis montrés à Opus 5.5 pour les schémas (et ajout de la page ouverte comme exemple).
    let schemaExemples: SchemaExemples
    /// Remplace le moteur des schémas (tests) ; sinon : clé API du trousseau, ou compte Claude (version personnelle).
    private let schemaGeneratorOverride: SchemaService.Generateur?
    /// Zones dont le type a été décidé par l'élève (ou par sa mémoire) : le traitement ne le change jamais.
    private var userKindIDs = Set<Int>()

    private var loadTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var analysisTask: Task<[PageAnalysis], Error>?
    private var documentGeneration = 0
    private var runToken = 0
    private var revealSerial = 0
    private var analyses: [PageAnalysis] = []
    private var analysisUsedText = false
    private var renderResult = RenderResult()
    private var lastStyleKey: String
    nonisolated(unsafe) private var defaultsObserver: NSObjectProtocol?

    init(settings: @escaping () -> RunSettings = { RunSettings.current() },
         engineFactory: @escaping (RunSettings) throws -> CompletionEngine = { try EngineFactory.make($0) },
         dialogs: Dialogs? = nil,
         defaults: UserDefaults = .standard,
         learning: ZoneLearning = .shared,
         schemaExemples: SchemaExemples = .shared,
         schemaGenerator: SchemaService.Generateur? = nil) {
        self.learning = learning
        self.schemaExemples = schemaExemples
        self.schemaGeneratorOverride = schemaGenerator
        self.learnedCount = learning.count
        self.settingsProvider = settings
        self.engineFactory = engineFactory
        self.dialogs = dialogs ?? AppKitDialogs()
        self.defaults = defaults
        self.recents = RecentFiles.load(defaults)
        self.lastStyleKey = settings().styleKey
        // Pas de `queue: .main` : la notification est envoyée au moment même où l'on écrit un réglage (sur le thread
        // principal aussi), et l'attendre dans la file principale bloquerait l'app. On rend la main puis on réagit.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.defaultsDidChange() }
        }
    }

    deinit {
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Résumés pour l'interface

    var documentName: String { fileURL?.deletingPathExtension().lastPathComponent ?? "" }
    var isRunning: Bool { if case .running = run { return true } else { return false } }
    var isAnalyzing: Bool { if case .running = analysis { return true } else { return false } }
    var isBusy: Bool { isRunning || isAnalyzing || isSaving || isAddingZone }
    var isReady: Bool { document != nil && analysis == .done }

    var zonePageCount: Int { Set(zones.map { $0.page }).count }
    var answeredCount: Int { zones.filter { $0.enabled && $0.kind != .ignorer && $0.isFilled }.count }
    var zonesToFill: Int { zones.filter { $0.enabled && $0.kind != .ignorer }.count }
    /// Zones schéma actives (dessinées par Opus 5.5, pas par le moteur de texte).
    var schemaZoneCount: Int { zones.filter { $0.kind == .schema && $0.enabled }.count }
    /// Y a-t-il des zones à faire écrire par le moteur de texte ? (sinon, des schémas seulement : aucun moteur de texte n'est utile)
    var needsTextEngine: Bool { zones.contains { $0.enabled && $0.kind != .ignorer && $0.kind != .schema } }
    var canComplete: Bool { isReady && !isBusy && zonesToFill > 0 }
    var canSave: Bool { isReady && !isBusy }
    var canDrawZone: Bool { isReady && !isBusy && skippedPages.count < pageCount }

    var analysisSummary: String { Fr.foundSummary(zones: zones.count, pages: zonePageCount) }

    /// Explication quand des pages n'ont pas été analysées parce qu'elles sont tournées.
    var skippedPagesMessage: String? {
        guard !skippedPages.isEmpty else { return nil }
        if skippedPages.count >= pageCount {
            return "Les pages de ce PDF sont tournées : \(AppIdentity.nom) ne sait pas encore les analyser. Dans Aperçu, remets-les à l'endroit (Outils > Pivoter), enregistre, puis rouvre le PDF."
        }
        let which = Fr.pageList(skippedPages)
        let verb = skippedPages.count > 1 ? "sont tournées" : "est tournée"
        let pronoun = skippedPages.count > 1 ? "elles ne sont pas analysées" : "elle n'est pas analysée"
        return "\(which.prefix(1).uppercased() + which.dropFirst()) \(verb) : \(pronoun) pour l'instant. Les autres pages sont traitées normalement."
    }

    func zone(_ id: Int) -> Zone? { zones.first { $0.id == id } }

    // MARK: - Ouverture

    func presentOpenPanel() {
        guard let url = dialogs.chooseOpenURL() else { return }
        open(url)
    }

    /// Ouvre un PDF (⌘O, glisser-déposer, Finder…). Demande d'abord si du travail non enregistré risque d'être perdu.
    func open(_ url: URL) {
        guard confirmLeavingCurrentWork(action: "ouvres un autre PDF") else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load(url) }
    }

    /// Fichiers déposés sur la fenêtre. Renvoie vrai si un PDF a été pris en compte.
    @discardableResult
    func handleDrop(_ urls: [URL]) -> Bool {
        let pdfs = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
        guard let first = pdfs.first else {
            showProblemMessage("Ce fichier n'est pas un PDF. Dépose un PDF de cours (fichier terminé par .pdf).")
            return false
        }
        open(first)
        if pdfs.count > 1 {
            showProblemMessage("\(AppIdentity.nom) ouvre un seul PDF à la fois : le premier a été ouvert.")
        }
        return true
    }

    func clearRecents() {
        RecentFiles.clear(defaults)
        recents = []
    }

    /// Charge le PDF et lance la recherche des zones ; ne rend la main qu'une fois l'analyse terminée.
    func load(_ url: URL) async {
        documentGeneration += 1
        let generation = documentGeneration
        cancelWork()
        resetDocumentState()

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            failOpening("Le fichier « \(url.lastPathComponent) » est introuvable ou illisible. Vérifie qu'il n'a pas été déplacé ou supprimé.")
            return
        }
        guard let doc = PDFDocument(url: url) else {
            failOpening("« \(url.lastPathComponent) » n'est pas un PDF valide, ou il est abîmé. Essaie de l'ouvrir dans Aperçu pour vérifier.")
            return
        }
        if doc.isLocked, !doc.unlock(withPassword: "") {
            failOpening("« \(url.lastPathComponent) » est protégé par un mot de passe : \(AppIdentity.nom) ne peut pas le lire. Ouvre-le dans Aperçu, exporte une copie sans mot de passe (Fichier > Exporter…), puis ouvre cette copie.")
            return
        }
        guard doc.pageCount > 0 else {
            failOpening("« \(url.lastPathComponent) » ne contient aucune page.")
            return
        }
        fileURL = url
        document = doc
        pageCount = doc.pageCount
        recents = RecentFiles.note(url, defaults: defaults)
        await analyzeDocument(generation: generation, needText: settingsProvider().engine.needsPageText, manual: [])
    }

    private func failOpening(_ message: String) {
        openError = message
    }

    private func resetDocumentState() {
        fileURL = nil
        document = nil
        pageCount = 0
        openError = nil
        analysis = .idle
        zones = []
        analyses = []
        skippedPages = []
        run = .idle
        runProblem = nil
        notice = nil
        isSaving = false
        isAddingZone = false
        hasUnsavedChanges = false
        selectedZoneID = nil
        revealRequest = nil
        isDrawingZone = false
        renderResult = RenderResult()
        userKindIDs = []
        learnedNotes = [:]
    }

    private func cancelWork() {
        runToken += 1
        runTask?.cancel()
        renderTask?.cancel()
        analysisTask?.cancel()
        analysisTask = nil
    }

    /// Faut-il demander confirmation avant de quitter le PDF courant ?
    func confirmLeavingCurrentWork(action: String) -> Bool {
        guard document != nil, isRunning || hasUnsavedChanges else { return true }
        return dialogs.confirm(
            title: "Tu n'as pas enregistré le PDF complété",
            message: "Si tu \(action), les réponses non enregistrées seront perdues.",
            accept: "Continuer sans enregistrer", cancel: "Annuler", destructive: true)
    }

    // MARK: - Analyse

    private func analyzeDocument(generation: Int, needText: Bool, manual: [ManualSpec]) async {
        guard let url = fileURL else { return }
        analysis = .running(fraction: 0, label: "Recherche des zones à remplir…")
        let work = Task.detached(priority: .userInitiated) { [weak self] () throws -> [PageAnalysis] in
            var all = try CoursPipeline.analyzeChecked(url: url, needText: needText) { fraction, label in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.analysisProgress(fraction, label, generation: generation) }
                }
            }
            // zones dessinées à la main avant une relecture : on les remet
            if !manual.isEmpty, let doc = PDFDocument(url: url) {
                var nextID = (all.flatMap { $0.zones }.map { $0.id }.max() ?? 0) + 1
                for m in manual {
                    guard let page = doc.page(at: m.page), let ai = all.firstIndex(where: { $0.pageIndex == m.page }) else { continue }
                    let number = (all[ai].zones.map { $0.number }.max() ?? 0) + 1
                    all[ai].zones.append(ZoneDetector.manualZone(page: page, index: m.page, id: nextID, number: number,
                                                                 rect: m.rect, useOCR: needText))
                    nextID += 1
                }
            }
            return all
        }
        analysisTask = work
        // Si l'on ouvre un autre PDF pendant la recherche, la tâche en cours s'arrête au lieu de finir pour rien.
        let outcome: Result<[PageAnalysis], Error> = await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            work.cancel()
        }
        guard generation == documentGeneration else { return }
        analysisTask = nil

        var results: [PageAnalysis] = []
        var failure: String?
        switch outcome {
        case .success(let found): results = found
        case .failure(let error):
            failure = error is CancellationError ? "La recherche des zones a été interrompue." : Fr.sentence(error.localizedDescription)
        }
        analyses = results
        zones = results.flatMap { $0.zones }.sorted { ($0.page, $0.number) < ($1.page, $1.number) }
        skippedPages = results.filter { $0.rotationUnsupported }.map { $0.pageIndex }
        analysisUsedText = needText
        let learned = applyLearning()
        analysis = .done
        if let failure {
            showNotice(.warning, "Les zones n'ont pas pu être cherchées : \(failure) Rouvre le PDF, ou essaie un autre fichier.")
        } else if learned > 0 {
            showNotice(.info, "\(Fr.zones(learned)) \(Fr.plural(learned, "réglée", "réglées")) comme d'habitude, d'après tes corrections précédentes. Tu peux les changer : c'est toi qui décides.")
        }
    }

    // MARK: - Mémoire des corrections

    /// Dossiers du chemin du PDF (pour ne jamais retenir quoi que ce soit d'une évaluation).
    private var learningPath: [String] { fileURL?.pathComponents.filter { $0 != "/" } ?? [] }

    /// Applique ce que l'élève a déjà corrigé sur des zones équivalentes. Renvoie le nombre de zones réglées.
    @discardableResult
    private func applyLearning() -> Int {
        var updated = zones
        let applied = learning.apply(to: &updated, documentName: documentName, path: learningPath)
        learnedCount = learning.count
        guard !applied.isEmpty else { return 0 }
        zones = updated
        for a in applied {
            learnedNotes[a.zoneID] = a.trace
            switch a.action {
            case .ignore, .kind: userKindIDs.insert(a.zoneID)
            case .confirm: break
            }
        }
        return applied.count
    }

    /// Retient une correction de l'élève (sans effet pour une évaluation ou une zone sans texte voisin).
    private func remember(_ zone: Zone, _ action: ZoneLearning.Action) {
        if case .kind(let k) = action, k == .schema { return }     // « schéma » n'est jamais mémorisé
        guard zone.source != .manuel else { return }     // une zone dessinée à la main n'a pas de signature réutilisable
        learning.record(action, for: zone, documentName: documentName, path: learningPath)
        learnedCount = learning.count
    }

    /// « Ignorer les zones comme celle-ci » : toutes les zones du document de même signature sont ignorées,
    /// et la correction est mémorisée pour les prochains cours du même modèle.
    func ignoreSimilarZones(like id: Int) {
        guard let base = zone(id), !isBusy else { return }
        let sig = ZoneSignature(zone: base, documentName: documentName)
        var ids: [Int] = []
        var updated = zones
        for i in updated.indices {
            let z = updated[i]
            let same = z.id == id || (z.source != .manuel && ZoneSignature(zone: z, documentName: documentName).matches(sig))
            guard same, z.kind != .ignorer else { continue }
            updated[i].kind = .ignorer
            updated[i].enabled = false
            updated[i].answer = ""
            updated[i].rawAnswer = ""
            updated[i].humanized = false
            updated[i].error = nil
            ids.append(z.id)
        }
        guard !ids.isEmpty else { return }
        zones = updated
        for i in ids { userKindIDs.insert(i); learnedNotes[i] = "Ignorée : même genre de zone que la n° \(base.number)" }
        let memorized = sig.isLearnable && ZoneLearning.isAllowed(documentName: documentName, path: learningPath)
        if memorized { remember(base, .ignore) }
        hasUnsavedChanges = true
        renderTask?.cancel()
        renderAnswers()
        let n = ids.count
        showNotice(.info, "\(Fr.zones(n)) \(Fr.plural(n, "ignorée", "ignorées"))" + (memorized
                   ? ", et je m'en souviendrai pour les prochains cours de ce modèle."
                   : ". Cette correction ne peut pas être mémorisée (pas de texte voisin à reconnaître)."))
    }

    /// Zones douteuses encore actives.
    var doubtfulCount: Int { ZoneTrust.doubtfulCount(zones) }

    /// « Ignorer les douteuses » : le détecteur n'est pas sûr de ces zones. Pas mémorisé (c'est un tri, pas une correction ciblée).
    func ignoreDoubtfulZones() {
        guard !isBusy else { return }
        var updated = zones
        var count = 0
        for i in updated.indices where ZoneTrust.isDoubtful(updated[i]) && updated[i].kind != .ignorer && updated[i].kind != .schema {
            updated[i].kind = .ignorer
            updated[i].enabled = false
            updated[i].answer = ""
            updated[i].rawAnswer = ""
            updated[i].humanized = false
            updated[i].error = nil
            userKindIDs.insert(updated[i].id)
            count += 1
        }
        guard count > 0 else { return }
        zones = updated
        hasUnsavedChanges = true
        renderTask?.cancel()
        renderAnswers()
        showNotice(.info, "\(Fr.zones(count)) douteuse\(count > 1 ? "s" : "") \(Fr.plural(count, "ignorée", "ignorées")). Change le type d'une zone pour la remettre.")
    }

    /// « Oublier mes corrections » : efface la mémoire (les zones du cours ouvert ne changent pas).
    func forgetLearning() {
        guard learnedCount > 0 else {
            showNotice(.info, "Je n'ai encore retenu aucune correction.")
            return
        }
        let ok = dialogs.confirm(
            title: "Oublier tes corrections ?",
            message: "Les prochains cours ne seront plus réglés d'après tes corrections passées. Le cours ouvert ne change pas.",
            accept: "Tout oublier", cancel: "Garder", destructive: true)
        guard ok else { return }
        learning.forgetAll()
        learnedCount = 0
        learnedNotes = [:]
        showNotice(.success, "J'ai oublié tes corrections.")
    }

    private func analysisProgress(_ fraction: Double, _ label: String, generation: Int) {
        guard generation == documentGeneration, case .running(let current, _) = analysis, fraction >= current else { return }
        analysis = .running(fraction: fraction, label: label)
    }

    // MARK: - Compléter

    /// Bouton « Compléter le cours » (⌘R).
    func startCompletion() {
        guard document != nil, !isBusy else { return }
        let toFill = zones.filter { $0.enabled && $0.kind != .ignorer }
        let empty = Set(toFill.filter { !$0.isFilled }.map { $0.id })
        if !empty.isEmpty, empty.count < toFill.count {
            // déjà des réponses (peut-être corrigées) : par défaut, on ne remplit que les trous restants
            let n = empty.count
            let choice = dialogs.choose(
                title: "\(Fr.zones(n)) \(Fr.plural(n, "est encore vide", "sont encore vides"))",
                message: "Tu peux compléter seulement \(Fr.plural(n, "cette zone", "ces zones")) : tes réponses actuelles, y compris celles que tu as corrigées, sont gardées. « Tout refaire » remplace toutes les réponses.",
                buttons: ["Seulement \(Fr.plural(n, "la zone vide", "les zones vides"))", "Tout refaire", "Annuler"])
            switch choice {
            case 0: runTask = Task { [weak self] in await self?.complete(only: empty) }; return
            case 1: break
            default: return
            }
        } else if empty.isEmpty, !toFill.isEmpty {
            // tout est déjà rempli : on confirme avant de tout remplacer
            let ok = dialogs.confirm(
                title: "Refaire tout le cours ?",
                message: "Les réponses actuelles, y compris celles que tu as corrigées, seront remplacées.",
                accept: "Remplacer les réponses", cancel: "Annuler", destructive: true)
            if !ok { return }
        }
        runTask = Task { [weak self] in await self?.complete() }
    }

    /// Régénère une seule zone (bouton « Régénérer », « Réessayer » ou « Compléter cette zone »).
    func regenerate(_ id: Int) {
        guard document != nil, !isBusy, zone(id) != nil else { return }
        runTask = Task { [weak self] in await self?.complete(only: [id]) }
    }

    /// Zones restées en erreur après un traitement (réseau coupé sur une page, par exemple).
    var failedZoneCount: Int { CoursPipeline.zoneIDsInError(zones).count }

    /// Bouton « Réessayer les zones en erreur » : ne redemande que ces zones.
    func retryFailedZones() {
        let ids = CoursPipeline.zoneIDsInError(zones)
        guard document != nil, !isBusy, !ids.isEmpty else { return }
        runTask = Task { [weak self] in await self?.complete(only: ids) }
    }

    /// Annule le traitement : les réponses déjà arrivées sont gardées.
    func cancelRun() {
        guard isRunning else { return }
        runToken += 1
        runTask?.cancel()
        run = .idle
        showNotice(.info, "Traitement annulé. Les réponses déjà obtenues sont conservées.")
        requestRender(after: 0)
    }

    /// Complète tout le document (`only` = nil) ou seulement certaines zones. Ne rend la main qu'à la fin.
    func complete(only ids: Set<Int>? = nil) async {
        guard let url = fileURL, document != nil, !isBusy else { return }
        runProblem = nil
        notice = nil
        let generation = documentGeneration
        runToken += 1
        let token = runToken
        let singleZone: Int? = (ids?.count == 1) ? ids?.first : nil
        run = .running(RunProgress(fraction: 0, label: "Préparation…"), zoneID: singleZone)

        let settings = settingsProvider()
        let requested: Set<Int> = ids ?? Set(zones.filter { $0.enabled }.map { $0.id })
        // Les zones schéma sont dessinées à part, par Opus 5.5 seulement : le moteur de texte ne les voit jamais.
        let schemaIDs = Set(zones.filter { $0.kind == .schema && requested.contains($0.id) }.map { $0.id })
        let textPending = zones.contains {
            requested.contains($0.id) && $0.kind != .schema && !($0.kind == .ignorer && userKindIDs.contains($0.id))
        }
        var engine: CompletionEngine?
        if textPending || schemaIDs.isEmpty {
            do {
                engine = try engineFactory(settings)
            } catch {
                endRun(token: token, problem: RunProblem(error))
                return
            }
        }

        // Un moteur sans vision a besoin du texte des pages scannées : on le lit si l'analyse ne l'a pas fait.
        if let e = engine, !e.usesImages, !analysisUsedText, analyses.contains(where: { !$0.hasTextLayer && !$0.rotationUnsupported }) {
            run = .running(RunProgress(fraction: 0, label: "Lecture des pages scannées…"), zoneID: singleZone)
            let manual = zones.filter { $0.source == .manuel }.map { ManualSpec(page: $0.page, rect: $0.rect) }
            await analyzeDocument(generation: generation, needText: true, manual: manual)
            guard token == runToken, generation == documentGeneration else { return }
        }

        let completion = CompletionSettings(humanize: settings.humanize, student: settings.student, humanizeTone: settings.humanizeTone,
                                            userKindZoneIDs: userKindIDs,
                                            verifyDoubtfulHoles: defaults.bool(forKey: Pref.verifyDoubtfulHoles))
        let name = documentName
        var humanizeWarning: String?
        var schemaProblem: RunProblem?

        do {
            if let engine {
                let final = try await CoursPipeline.complete(
                    url: url, documentName: name, analyses: analyses, zones: zones, engine: engine,
                    settings: completion, onlyZoneIDs: ids
                ) { [weak self] updated, fraction, label in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.receive(updated, fraction, label, token: token, requested: requested, singleZone: singleZone)
                        }
                    }
                }
                guard token == runToken, generation == documentGeneration else { return }
                merge(final, requested: requested)
                humanizeWarning = pendingHumanizeWarning
                pendingHumanizeWarning = nil
            }
            // Schémas : une zone après l'autre, avec Opus 5.5 seulement.
            if !schemaIDs.isEmpty {
                do {
                    try await drawSchemas(ids: schemaIDs, url: url, name: name, token: token, generation: generation, settings: settings)
                } catch let e as SchemaErreur {
                    guard case .indisponible = e else { throw e }
                    schemaProblem = RunProblem(e)
                }
                guard token == runToken, generation == documentGeneration else { return }
            }
            finishRun(requested: requested, single: singleZone != nil, humanizeWarning: humanizeWarning)
            if let schemaProblem { runProblem = schemaProblem; BugJournal.shared.noter("Schémas", schemaProblem.message) }
            #if COMPTE_PERSO
            if let engine, Pref.verifyEnabled(), token == runToken, generation == documentGeneration {
                showNotice(.success, "Vérification avec Opus en cours…", offersRetry: false)
                do {
                    if let report = try await CoursPipeline.verifyAfterCompletion(
                        url: url, analyses: analyses, zones: self.zones, engine: engine, enabled: true) {
                        let n = report.problems.count
                        showNotice(n > 0 ? .warning : .success,
                                   n > 0 ? "Vérification : \(n) zone(s) à revoir." : "Vérification : rien à signaler.",
                                   offersRetry: false)
                    }
                } catch {
                    showNotice(.warning, "Vérification impossible : \(Fr.sentence(error.localizedDescription)) Tu peux enregistrer le PDF quand même.", offersRetry: false)
                }
            }
            #endif
        } catch is CancellationError {
            // annulé par un autre chemin que le bouton « Annuler » (qui a déjà tout remis en ordre)
            guard token == runToken, generation == documentGeneration else { return }
            pendingHumanizeWarning = nil
            run = .idle
            requestRender(after: 0)
        } catch {
            guard token == runToken, generation == documentGeneration else { return }
            pendingHumanizeWarning = nil
            let problem = RunProblem(error)
            // Une panne qui arrête tout (clé refusée…) est expliquée une fois dans le panneau : on n'en répète pas
            // le message sur chaque zone.
            if problem.needsSettings { clearErrors(of: requested) }
            endRun(token: token, problem: problem)
        }
    }

    // MARK: - Schémas électriques (Opus 5.5 uniquement)

    /// Bouton « Dessiner le schéma » d'une zone schéma (ou « Redessiner »).
    func drawSchema(_ id: Int) {
        guard document != nil, !isBusy, let z = zone(id), z.kind == .schema else { return }
        guard z.box != nil else {
            updateZone(id) { $0.error = SchemaService.messageSansCadre }
            return
        }
        runTask = Task { [weak self] in await self?.complete(only: [id]) }
    }

    /// Bouton « Dessiner tous les schémas » : toutes les zones schéma actives, une après l'autre.
    func drawAllSchemas() {
        let ids = Set(zones.filter { $0.kind == .schema && $0.enabled }.map { $0.id })
        guard document != nil, !isBusy, !ids.isEmpty else { return }
        runTask = Task { [weak self] in await self?.complete(only: ids) }
    }

    /// L'accès à Opus 5.5 : clé API du trousseau d'abord ; sinon (version personnelle) le compte Claude avec l'effort choisi dans les Réglages (« medium » par défaut) ;
    /// sinon `SchemaErreur.indisponible`. Aucun autre moteur n'est jamais utilisé pour les schémas.
    private func schemaGenerator(settings: RunSettings) throws -> SchemaService.Generateur {
        if let schemaGeneratorOverride { return schemaGeneratorOverride }
        var cle: String?
        do { cle = try Keychain.read() } catch { throw SchemaErreur.indisponible("\(Fr.sentence(error.localizedDescription)) Vérifie ta clé dans les Réglages.") }
        var cli: URL?
        #if COMPTE_PERSO
        cli = ClaudeCodeEngine.locateCLI(override: settings.claudeCodePath)
        #endif
        if let motif = SchemaEngine.motifIndisponible(cleAPI: cle, compteDispo: cli != nil) { throw SchemaErreur.indisponible(motif) }
        let propre = (cle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !propre.isEmpty { return SchemaService.generateur(acces: .cleAPI(propre)) }
        #if COMPTE_PERSO
        if let cli { return SchemaService.generateur(acces: .compte(cli: cli, effort: settings.claudeCodeEffort)) }
        #endif
        throw SchemaErreur.indisponible(SchemaEngine.messageIndisponible)
    }

    /// Dessine les schémas demandés (une zone après l'autre) et reporte le résultat dans les zones du modèle.
    private func drawSchemas(ids: Set<Int>, url: URL, name: String, token: Int, generation: Int, settings: RunSettings) async throws {
        let generateur = try schemaGenerator(settings: settings)
        let exemples = schemaExemples.pourDemande(nomDocument: name)
        let single: Int? = ids.count == 1 ? ids.first : nil
        let produced = try await SchemaService.dessiner(
            url: url, documentName: name, zones: zones, ids: ids, exemples: exemples, generateur: generateur
        ) { [weak self] updated, fraction, label in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, token == self.runToken, generation == self.documentGeneration, self.isRunning else { return }
                    self.mergeSchemas(updated, ids: ids)
                    self.run = .running(RunProgress(fraction: min(max(fraction, 0), 1), label: label), zoneID: single)
                    self.progressObserver?(fraction, label)
                    self.requestRender(after: 0)
                }
            }
        }
        guard token == runToken, generation == documentGeneration else { return }
        mergeSchemas(produced, ids: ids)
    }

    /// Reprend le schéma et l'erreur des zones schéma demandées (rien d'autre : le texte n'est jamais touché).
    private func mergeSchemas(_ produced: [Zone], ids: Set<Int>) {
        var byID: [Int: Zone] = [:]
        for z in produced { byID[z.id] = byID[z.id] ?? z }
        var updated = zones
        for i in updated.indices where ids.contains(updated[i].id) && updated[i].kind == .schema {
            guard let p = byID[updated[i].id] else { continue }
            updated[i].schema = p.schema
            updated[i].error = p.error
        }
        zones = updated
    }

    /// « Prendre cette page comme exemple de schéma » : la page affichée (relue dans le fichier d'origine, sans nos réponses).
    var canAddSchemaExample: Bool { document != nil && !isBusy && !schemaExemples.estPlein }

    func addCurrentPageAsSchemaExample() {
        guard let url = fileURL, let doc = document, !isBusy else { return }
        let index = previewView?.currentPage.flatMap { doc.index(for: $0) } ?? 0
        do {
            let example = try schemaExemples.ajouter(pdf: url, numeroPage: index + 1)
            showNotice(.success, "La page \(index + 1) est maintenant un exemple de schéma (« \(example.titre) »). Tu peux le renommer dans les Réglages, onglet Schémas.")
        } catch {
            showNotice(.warning, Fr.sentence(error.localizedDescription))
        }
    }

    private func clearErrors(of ids: Set<Int>) {
        var updated = zones
        for i in updated.indices where ids.contains(updated[i].id) { updated[i].error = nil }
        zones = updated
    }

    private var pendingHumanizeWarning: String?

    private func receive(_ updated: [Zone], _ fraction: Double, _ label: String,
                         token: Int, requested: Set<Int>, singleZone: Int?) {
        guard token == runToken, isRunning else { return }
        merge(updated, requested: requested)
        if label.hasPrefix("Humanisation impossible") { pendingHumanizeWarning = label }
        let progress = RunProgress(fraction: min(max(fraction, 0), 1), label: friendlyLabel(label, single: singleZone))
        run = .running(progress, zoneID: singleZone)
        progressObserver?(fraction, label)
        requestRender(after: 0)
    }

    /// Reprend dans les zones du modèle ce que le traitement a produit, pour les zones demandées seulement.
    private func merge(_ produced: [Zone], requested: Set<Int>) {
        var byID: [Int: Zone] = [:]
        for z in produced { byID[z.id] = byID[z.id] ?? z }
        var updated = zones
        for i in updated.indices where requested.contains(updated[i].id) {
            guard let p = byID[updated[i].id] else { continue }
            updated[i].kind = p.kind
            updated[i].answer = p.answer
            updated[i].rawAnswer = p.rawAnswer
            updated[i].humanized = p.humanized
            updated[i].enabled = p.enabled
            updated[i].error = p.error
            updated[i].confidence = p.confidence      // le contrôle facultatif des zones douteuses peut les changer
            updated[i].signals = p.signals
        }
        zones = updated
    }

    private func friendlyLabel(_ raw: String, single: Int?) -> String {
        if let single, let z = zone(single), !raw.hasPrefix("Humanisation") {
            return "Complétion de la zone \(z.number) (page \(z.page + 1))…"
        }
        if let range = raw.range(of: "^Page [0-9]+ complétée$", options: .regularExpression) {
            let digits = raw[range].dropFirst(5).prefix { $0.isNumber }
            return "Complétion — page \(digits) sur \(pageCount)"
        }
        if raw.hasPrefix("Humanisation des réponses") { return "Humanisation…" }
        return raw
    }

    private func finishRun(requested: Set<Int>, single: Bool, humanizeWarning: String?) {
        run = .idle
        renderTask?.cancel()
        renderAnswers()
        let done = zones.filter { requested.contains($0.id) }
        let answered = done.filter { $0.enabled && $0.kind != .ignorer && $0.isFilled }.count
        let failed = done.filter { $0.error != nil }.count
        if answered > 0 { hasUnsavedChanges = true }
        if single {
            if failed == 0 { notice = nil }
            return
        }
        var text: String
        if answered == 0 {
            text = "Aucune réponse n'a été écrite."
        } else {
            text = "C'est fait : \(Fr.answers(answered)) \(Fr.plural(answered, "écrite", "écrites"))."
        }
        if failed > 0 {
            text += " \(Fr.zones(failed)) \(Fr.plural(failed, "n'a pas pu être complétée", "n'ont pas pu être complétées")) : utilise « Réessayer »."
        } else if answered > 0 {
            text += " Relis-les, corrige si besoin, puis enregistre le PDF."
        }
        if humanizeWarning != nil {
            text += " L'humanisation n'a pas pu être faite pour certaines réponses : leur texte d'origine est gardé."
        }
        showNotice(failed > 0 || humanizeWarning != nil ? .warning : .success, text, offersRetry: failed > 0)
    }

    private func endRun(token: Int, problem: RunProblem) {
        guard token == runToken else { return }
        run = .idle
        runProblem = problem
        BugJournal.shared.noter("Complétion", problem.message)
        requestRender(after: 0)
    }

    // MARK: - Modifications faites par l'élève

    private func updateZone(_ id: Int, _ change: (inout Zone) -> Void) {
        guard let i = zones.firstIndex(where: { $0.id == id }) else { return }
        var z = zones[i]
        change(&z)
        zones[i] = z
    }

    /// Réponse tapée à la main : elle devient la référence (plus « humanisée »), et l'aperçu suit après une courte pause.
    func setAnswer(_ text: String, for id: Int) {
        guard let current = zone(id), current.answer != text else { return }
        updateZone(id) { z in
            let wasEmpty = z.answer.isEmpty
            z.answer = text
            z.rawAnswer = text
            z.humanized = false
            z.error = nil
            if wasEmpty && !text.isEmpty && z.kind != .ignorer { z.enabled = true }
        }
        hasUnsavedChanges = true
        requestRender(after: 0.4)
    }

    func setKind(_ kind: ZoneKind, for id: Int) {
        guard let current = zone(id), current.kind != kind else { return }
        if kind == .schema, current.box == nil {
            showNotice(.warning, SchemaService.messageSansCadre)
            return
        }
        userKindIDs.insert(id)           // choix de l'élève : jamais changé par un traitement
        learnedNotes[id] = nil
        defer { if let changed = zone(id) { remember(changed, kind == .ignorer ? .ignore : .kind(kind)) } }
        updateZone(id) { z in
            let wasIgnored = z.kind == .ignorer
            z.kind = kind
            if kind == .schema {                      // un schéma n'est pas du texte : plus de réponse écrite dans cette zone
                z.answer = ""; z.rawAnswer = ""; z.humanized = false; z.error = nil
            }
            if kind == .ignorer { z.enabled = false } else if wasIgnored { z.enabled = true }
            // Seules les questions ouvertes sont réécrites : pour une définition, un mot ou une zone ignorée, on remet le texte d'origine.
            if !kind.isHumanizable && z.humanized {
                z.answer = z.rawAnswer
                z.humanized = false
            }
        }
        hasUnsavedChanges = true
        requestRender(after: 0)
    }

    func setEnabled(_ enabled: Bool, for id: Int) {
        guard let current = zone(id), current.enabled != enabled, current.kind != .ignorer else { return }
        updateZone(id) { $0.enabled = enabled }
        hasUnsavedChanges = true
        requestRender(after: 0)
    }

    /// « Voir le texte d'origine » puis « Utiliser ce texte » : on abandonne la version humanisée.
    func useOriginalText(for id: Int) {
        guard let current = zone(id), current.humanized else { return }
        updateZone(id) { z in
            z.answer = z.rawAnswer
            z.humanized = false
        }
        hasUnsavedChanges = true
        requestRender(after: 0)
    }

    /// Supprime une zone ajoutée à la main (les zones trouvées par l'analyse restent : on peut les ignorer).
    func deleteManualZone(_ id: Int) {
        guard let z = zone(id), z.source == .manuel, !isBusy else { return }
        zones.removeAll { $0.id == id }
        if selectedZoneID == id { selectedZoneID = nil }
        renderTask?.cancel()
        renderAnswers()
        showNotice(.info, "La zone \(z.number) de la page \(z.page + 1) a été supprimée.")
    }

    // MARK: - Sélection

    func select(_ id: Int?, from source: SelectionSource) {
        selectedZoneID = id
        guard let id else { return }
        revealSerial += 1
        revealRequest = RevealRequest(serial: revealSerial, zoneID: id, source: source)
    }

    // MARK: - Ajouter une zone à la main

    func beginDrawingZone() {
        guard canDrawZone else { return }
        isDrawingZone = true
    }

    func cancelDrawingZone() {
        isDrawingZone = false
    }

    /// Un rectangle a été tiré sur la page `pageIndex` (espace page PDF).
    func zoneDrawn(pageIndex: Int, rect: CGRect) {
        isDrawingZone = false
        Task { [weak self] in await self?.addManualZone(pageIndex: pageIndex, rect: rect) }
    }

    func addManualZone(pageIndex: Int, rect: CGRect) async {
        guard let url = fileURL, let doc = document, doc.page(at: pageIndex) != nil, !isBusy else { return }
        let generation = documentGeneration
        isAddingZone = true
        defer { isAddingZone = false }
        let id = (zones.map { $0.id }.max() ?? 0) + 1
        let number = (zones.filter { $0.page == pageIndex }.map { $0.number }.max() ?? 0) + 1
        let ocr = settingsProvider().engine.needsPageText
        let created = await Task.detached(priority: .userInitiated) { () -> Zone? in
            guard let copy = PDFDocument(url: url) else { return nil }
            if copy.isLocked { _ = copy.unlock(withPassword: "") }
            guard let p = copy.page(at: pageIndex) else { return nil }
            return ZoneDetector.manualZone(page: p, index: pageIndex, id: id, number: number, rect: rect, useOCR: ocr)
        }.value
        guard generation == documentGeneration else { return }
        guard var zone = created else {
            showNotice(.warning, "La zone n'a pas pu être ajoutée : le PDF n'a pas pu être relu.")
            return
        }
        zone.kind = ZoneKindRules.propose(zone).kind
        zones = (zones + [zone]).sorted { ($0.page, $0.number) < ($1.page, $1.number) }
        remember(zone, .confirm)         // une zone ajoutée à la main est un vrai trou que le détecteur avait raté
        select(zone.id, from: .program)
    }

    // MARK: - Aperçu : écriture des réponses sur le document affiché

    /// Remet à jour les réponses écrites sur le document affiché : on retire ce qui avait été écrit, puis on réécrit.
    func renderAnswers() {
        guard let doc = document else { return }
        let settings = settingsProvider()
        lastStyleKey = settings.styleKey
        let pagesBefore = Set(zones.map { $0.page })
        AnswerRenderer.remove(renderResult, from: doc)
        renderResult = AnswerRenderer.apply(zones: zones, to: doc, style: settings.style)
        // l'indicateur « ça ne rentre pas » vient du rendu
        var changed = false
        var updated = zones
        for i in updated.indices {
            let overflow = renderResult.overflowIDs.contains(updated[i].id)
            if updated[i].overflow != overflow {
                updated[i].overflow = overflow
                changed = true
            }
        }
        if changed { zones = updated }
        refreshPreview(pages: pagesBefore.union(zones.map { $0.page }))
    }

    /// Réécriture différée : on regroupe les demandes rapprochées (frappe au clavier, mises à jour du traitement).
    func requestRender(after delay: TimeInterval) {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.renderAnswers()
        }
    }

    private func refreshPreview(pages: Set<Int>) {
        guard let view = previewView, let doc = document else { return }
        for index in pages {
            if let page = doc.page(at: index) { view.annotationsChanged(on: page) }
        }
    }

    private func defaultsDidChange() {
        let style = settingsProvider().styleKey
        guard style != lastStyleKey else { return }
        lastStyleKey = style
        if document != nil { requestRender(after: 0.05) }
    }

    // MARK: - Enregistrer

    /// Avertissements avant l'enregistrement : zones qui débordent ou en erreur (on n'empêche pas d'enregistrer).
    func saveWarning() -> String? {
        func describe(_ list: [Zone]) -> String {
            list.map { "n° \($0.number) (page \($0.page + 1))" }.joined(separator: ", ")
        }
        let overflow = zones.filter { $0.enabled && $0.kind != .ignorer && $0.overflow }
        let errors = zones.filter { $0.error != nil }
        var parts: [String] = []
        if !overflow.isEmpty {
            parts.append("\(Fr.answers(overflow.count)) \(Fr.plural(overflow.count, "ne rentre pas", "ne rentrent pas")) dans \(Fr.plural(overflow.count, "sa zone", "leur zone")) : zone \(describe(overflow)). Le texte sera coupé ou trop petit : raccourcis-\(Fr.plural(overflow.count, "la", "les")).")
        }
        if !errors.isEmpty {
            parts.append("\(Fr.zones(errors.count)) \(Fr.plural(errors.count, "est restée", "sont restées")) sans réponse à cause d'une erreur : zone \(describe(errors)).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Bouton « Enregistrer le PDF complété… » (⌘S).
    func savePDF() {
        guard canSave, let source = fileURL else { return }
        if answeredCount == 0 {
            dialogs.inform(title: "Rien à enregistrer pour l'instant",
                           message: "Aucune réponse n'est écrite dans le PDF. Lance d'abord « Compléter le cours », ou écris une réponse dans la liste.")
            return
        }
        if let warning = saveWarning() {
            let ok = dialogs.confirm(title: "Certaines zones posent problème", message: warning + "\n\nTu peux enregistrer quand même, ou revenir à la liste pour les corriger.",
                                     accept: "Enregistrer quand même", cancel: "Revenir à la liste", destructive: false)
            if !ok { return }
        }
        let suggested = "\(documentName) (complétée).pdf"
        var destination = dialogs.chooseSaveURL(suggestedName: suggested, directory: source.deletingLastPathComponent())
        // Le PDF d'origine ne doit jamais être écrasé.
        while let chosen = destination, chosen.standardizedFileURL.resolvingSymlinksInPath() == source.standardizedFileURL.resolvingSymlinksInPath() {
            dialogs.inform(title: "Choisis un autre nom",
                           message: "Ce fichier est le PDF d'origine : il ne doit pas être remplacé. Ajoute par exemple « (complétée) » à la fin du nom.")
            destination = dialogs.chooseSaveURL(suggestedName: suggested, directory: source.deletingLastPathComponent())
        }
        guard let destination else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.export(to: destination)
                self.showNotice(.success, "PDF enregistré : \(destination.lastPathComponent).", revealURL: destination)
                self.notice?.sheetURL = destination
            } catch {
                self.dialogs.inform(title: "L'enregistrement a échoué", message: Fr.sentence(error.localizedDescription))
            }
        }
    }

    /// Écrit le PDF complété (repart du fichier d'origine, avec l'option « aplatir » des Réglages).
    func export(to destination: URL) async throws {
        guard let source = fileURL else { throw CoursError.message("Aucun PDF n'est ouvert.") }
        let settings = settingsProvider()
        let snapshot = zones
        isSaving = true
        defer { isSaving = false }
        try await Task.detached(priority: .userInitiated) {
            try AnswerRenderer.export(sourceURL: source, zones: snapshot, style: settings.style,
                                      flatten: settings.flatten, to: destination)
        }.value
        hasUnsavedChanges = false
        // une copie enregistrée à côté de l'original est une complétion faite par l'app : on s'en souvient
        if destination.deletingLastPathComponent().standardizedFileURL == source.deletingLastPathComponent().standardizedFileURL {
            CourseLedger.shared.recordCompletion(original: source, copy: destination, engine: settings.engineDisplayName)
            NotificationCenter.default.post(name: .courseCopySaved, object: nil)   // « Mes cours » se met à jour
        }
    }

    // MARK: - Messages

    func showNotice(_ style: Notice.Style, _ text: String, revealURL: URL? = nil, offersRetry: Bool = false) {
        notice = Notice(style: style, text: text, revealURL: revealURL, offersRetry: offersRetry)
    }

    func dismissNotice() { notice = nil }
    func dismissRunProblem() { runProblem = nil }

    /// Message sur un fichier refusé : dans l'écran d'accueil s'il n'y a pas de PDF, sinon dans le panneau.
    private func showProblemMessage(_ text: String) {
        if document == nil { openError = text } else { showNotice(.warning, text) }
    }

    func revealInFinder(_ url: URL) { dialogs.reveal(url) }

    // MARK: - Aperçu : zoom

    func zoomIn() { previewView?.zoomIn(nil) }
    func zoomOut() { previewView?.zoomOut(nil) }
    func zoomToFit() { previewView?.autoScales = true }
}

extension Notification.Name {
    /// Une copie complétée vient d'être enregistrée à côté de son original.
    static let courseCopySaved = Notification.Name("fr.complete-cours.courseCopySaved")
}
