import Foundation
import AppKit
import PDFKit

// Mode « Révision » : état de la fenêtre. Aucune dépendance vers CoursModel ni vers le service réel
// (voir RevisionWiring.swift) : le modèle parle seulement à RevisionProviding, à un exporteur et à des dialogues.

// MARK: - Erreurs lisibles

/// Une erreur expliquée à l'élève : ce qui s'est passé, puis quoi faire.
struct RevisionIssue: Equatable {
    var title: String
    var what: String
    var todo: String
}

struct RevisionIssueError: LocalizedError {
    var issue: RevisionIssue
    var errorDescription: String? { issue.what }
}

// MARK: - Dépendances

/// Ce que l'interface sait du moteur choisi dans les Réglages, sans le construire (pas d'accès au trousseau).
struct RevisionEngineStatus: Equatable {
    var name: String
    var usable: Bool
    var supportsImages: Bool
    /// Renseigné quand `usable` est faux.
    var issue: RevisionIssue?
    /// Le bouton « Ouvrir les Réglages » est utile.
    var needsSettings: Bool

    static let message = RevisionIssue(
        title: "La révision demande Claude",
        what: "La révision demande Claude (clé API ou ton compte).",
        todo: "Change de moteur dans les Réglages.")
}

protocol RevisionExporting: Sendable {
    func summaryPDF(_ summary: RevisionSummary, documentName: String) throws -> Data
    func quizPDF(_ questions: [RevisionQuestion], documentName: String, withAnswers: Bool) throws -> Data
    func corrigePDF(_ items: [CorrigeItem], documentName: String) throws -> Data
    func cardsPDF(_ cards: [RevisionCard], documentName: String) throws -> Data
}

@MainActor
protocol RevisionDialogs: AnyObject {
    func chooseOpenURL() -> URL?
    func chooseSaveURL(suggestedName: String, directory: URL?) -> URL?
    func inform(title: String, message: String)
    func reveal(_ url: URL)
}

@MainActor
final class AppKitRevisionDialogs: RevisionDialogs {
    func chooseOpenURL() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choisir un cours"
        panel.prompt = "Ouvrir"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseSaveURL(suggestedName: String, directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Enregistrer en PDF"
        panel.prompt = "Enregistrer"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        if let directory { panel.directoryURL = directory }
        return panel.runModal() == .OK ? panel.url : nil
    }

    func inform(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

// MARK: - Modèle

enum RevisionTab: String, CaseIterable, Identifiable {
    case fiche, entrainement, cartes, apres
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fiche: return "Fiche de synthèse"
        case .entrainement: return "Entraînement"
        case .cartes: return "Cartes mémoire"
        case .apres: return "Après l'évaluation"
        }
    }
    var icon: String {
        switch self {
        case .fiche: return "doc.text"
        case .entrainement: return "checklist"
        case .cartes: return "rectangle.on.rectangle.angled"
        case .apres: return "graduationcap"
        }
    }
}

/// Où s'applique une consigne libre.
enum InstructionTarget { case summary, quiz }

/// Pastille de raccourci : ajoute (ou retire) une phrase dans la consigne.
struct InstructionShortcut: Identifiable, Equatable {
    var label: String
    var phrase: String
    var id: String { label }

    static let all: [InstructionShortcut] = [
        InstructionShortcut(label: "Très court", phrase: "Très court : seulement l'essentiel."),
        InstructionShortcut(label: "Seulement les formules", phrase: "Seulement les formules."),
        InstructionShortcut(label: "Vocabulaire à connaître", phrase: "Insiste sur le vocabulaire à connaître."),
        InstructionShortcut(label: "Pour l'oral", phrase: "Présenté pour être appris et récité à l'oral."),
        InstructionShortcut(label: "Plus détaillé", phrase: "Plus détaillé, avec des exemples du cours."),
    ]
}

@MainActor
final class RevisionModel: ObservableObject {
    struct Activity: Equatable {
        var label: String
        var fraction: Double
    }

    static let corrigeWelcome = "À utiliser une fois ton évaluation rendue et corrigée par ton professeur : l'app prépare un corrigé pour t'aider à comprendre tes erreurs. Rien n'est écrit sur ta feuille."

    // Document
    @Published private(set) var documentURL: URL?
    @Published private(set) var documentName = ""
    @Published private(set) var pageCount = 0
    // Moteur
    @Published private(set) var engine: RevisionEngineStatus
    // Navigation et activité
    @Published var tab: RevisionTab = .fiche
    @Published private(set) var activity: Activity?
    @Published var issue: RevisionIssue?
    @Published private(set) var notice: String?
    /// Dernier PDF enregistré (bouton « Afficher dans le Finder » du message).
    @Published private(set) var lastSaved: URL?
    // Fiche
    @Published private(set) var summary: RevisionSummary?
    // Entraînement
    @Published var quizOptions = QuizOptions()
    @Published private(set) var questions: [RevisionQuestion] = []
    @Published var currentIndex = 0
    @Published private(set) var answers: [Int: String] = [:]
    @Published private(set) var graded: [Int: GradedAnswer] = [:]
    @Published private(set) var showingResults = false
    @Published private(set) var round = 1
    // Consigne libre de la fiche (celle de l'entraînement est dans `quizOptions.instruction`)
    @Published var summaryInstruction = ""
    // Cartes mémoire
    @Published var cardCount = CardLimits.defaultCount
    @Published private(set) var cards: [RevisionCard] = []
    /// Cartes de la série en cours (toutes, ou seulement celles à revoir).
    @Published private(set) var deck: [RevisionCard] = []
    @Published private(set) var cardIndex = 0
    @Published private(set) var cardFlipped = false
    @Published private(set) var cardKnown: Set<Int> = []
    @Published private(set) var cardToReview: Set<Int> = []
    @Published private(set) var cardsFinished = false
    @Published private(set) var cardRound = 1
    // Corrigé
    @Published var corrigeConfirmed = false
    @Published private(set) var corrigeItems: [CorrigeItem] = []

    private let engineStatus: () -> RevisionEngineStatus
    private let makeService: () throws -> RevisionProviding
    private let exporter: RevisionExporting
    private let dialogs: RevisionDialogs
    private let memoire: RevisionMemoireStore?
    private var source: RevisionSource?
    private var sourceHasImages = false
    private var token = UUID()
    private var task: Task<Void, Never>?

    init(engineStatus: @escaping () -> RevisionEngineStatus,
         makeService: @escaping () throws -> RevisionProviding,
         exporter: RevisionExporting,
         dialogs: RevisionDialogs,
         memoire: RevisionMemoireStore? = nil) {
        self.engineStatus = engineStatus
        self.makeService = makeService
        self.exporter = exporter
        self.dialogs = dialogs
        self.memoire = memoire
        self.engine = engineStatus()
    }

    // MARK: Moteur et estimation

    func refreshEngine() { engine = engineStatus() }

    var isBusy: Bool { activity != nil }
    var hasDocument: Bool { documentURL != nil }
    /// Les boutons « Créer » et « Générer » sont utilisables.
    var canStart: Bool { hasDocument && engine.usable && !isBusy }

    /// Estimation très grossière de ce que l'IA lira (environ 1 500 jetons par page, plus si elle voit les pages).
    var estimate: String? {
        guard pageCount > 0, engine.usable else { return nil }
        let perPage = engine.supportsImages ? 2_500 : 1_500
        let tokens = Int((Double(pageCount * perPage) / 1_000).rounded()) * 1_000
        let formatted = tokens.formatted(.number.locale(Locale(identifier: "fr_FR")))
        return "Estimation grossière : environ \(formatted) jetons lus par l'IA à chaque création."
    }

    // MARK: Document

    func chooseDocument() {
        guard !isBusy else { return }
        if let url = dialogs.chooseOpenURL() { open(url) }
    }

    func handleDrop(_ urls: [URL]) {
        guard !isBusy else { return }
        guard let pdf = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else {
            if !urls.isEmpty {
                issue = RevisionIssue(title: "Ce fichier n'est pas un PDF",
                                      what: "Seuls les documents PDF peuvent être ouverts.",
                                      todo: "Dépose un cours au format PDF.")
            }
            return
        }
        open(pdf)
    }

    func open(_ url: URL) {
        cancel(silently: true)
        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else {
            issue = RevisionIssue(title: "Ce PDF ne s'ouvre pas",
                                  what: "Le fichier est abîmé, protégé par un mot de passe ou vide.",
                                  todo: "Essaie avec un autre PDF, ou redemande le cours à ton professeur.")
            return
        }
        documentURL = url
        documentName = url.deletingPathExtension().lastPathComponent
        pageCount = doc.pageCount
        source = nil
        sourceHasImages = false
        summary = nil
        resetQuiz()
        resetCards()
        corrigeItems = []
        corrigeConfirmed = false
        issue = nil
        notice = nil
        lastSaved = nil
        refreshEngine()
        restaurer(url)
    }

    // MARK: Mémoire (ce que l'IA a déjà fait pour ce PDF)

    /// Reprend la fiche, les questions, les cartes et le corrigé du dernier passage : aucun nouvel appel à l'IA.
    private func restaurer(_ url: URL) {
        guard let m = memoire?.charger(url) else { return }
        summary = m.summary
        if !m.questions.isEmpty { beginQuiz(m.questions) }
        if !m.cards.isEmpty { cards = m.cards; beginDeck(m.cards) }
        if !m.corrige.isEmpty { corrigeItems = m.corrige; corrigeConfirmed = true }
        var repris: [String] = []
        if m.summary != nil { repris.append("la fiche") }
        if !m.questions.isEmpty { repris.append("les questions") }
        if !m.cards.isEmpty { repris.append("les cartes") }
        if !m.corrige.isEmpty { repris.append("le corrigé") }
        notice = "Repris de ton dernier passage, sans nouvel appel à l'IA : \(Fr.list(repris))."
    }

    /// Garde ce qui vient d'être créé, pour le reprendre la prochaine fois que ce PDF est ouvert.
    private func memoriser() {
        guard let memoire, let url = documentURL else { return }
        let m = RevisionMemoire(summary: summary, questions: memorisedQuestions, cards: cards, corrige: corrigeItems)
        Task.detached(priority: .utility) { memoire.sauver(m, pour: url) }
    }

    /// Questions de la dernière création (pas la série « ratées » en cours, qui n'en est qu'une partie).
    private var memorisedQuestions: [RevisionQuestion] = []

    func closeDocument() {
        cancel(silently: true)
        documentURL = nil; documentName = ""; pageCount = 0
        source = nil; summary = nil; corrigeItems = []; corrigeConfirmed = false
        resetQuiz()
        resetCards()
        issue = nil; notice = nil
    }

    // MARK: Exécution des tâches

    private func isCurrent(_ t: UUID) -> Bool { token == t && !Task.isCancelled }

    private func progressHandler(_ t: UUID, scale: ClosedRange<Double> = 0...1) -> RevisionProgress {
        return { [weak self] fraction, label in
            let f = scale.lowerBound + (scale.upperBound - scale.lowerBound) * min(max(fraction, 0), 1)
            Task { @MainActor in self?.report(t, f, label) }
        }
    }

    private func report(_ t: UUID, _ fraction: Double, _ label: String) {
        guard token == t, activity != nil else { return }
        activity = Activity(label: label, fraction: fraction)
    }

    /// Lance une tâche à la fois. `failure` : « La fiche n'a pas pu être créée ».
    private func start(_ label: String, failure: String, _ body: @escaping (UUID) async throws -> Void) {
        guard !isBusy else { return }
        issue = nil
        notice = nil
        let t = UUID()
        token = t
        activity = Activity(label: label, fraction: 0)
        task = Task { [weak self] in
            do {
                try await body(t)
            } catch {
                guard let self, self.token == t else { return }
                if let found = Self.issue(for: error, failure: failure) { self.issue = found }
            }
            guard let self, self.token == t else { return }
            self.activity = nil
            self.task = nil
        }
    }

    /// Annule proprement : rien de ce que la tâche rendrait ensuite n'est gardé.
    func cancel(silently: Bool = false) {
        guard activity != nil || task != nil else { return }
        task?.cancel()
        task = nil
        token = UUID()
        activity = nil
        if !silently { notice = "Opération annulée." }
    }

    /// Pour les tests : attend la fin de la tâche en cours.
    func waitUntilIdle() async {
        while let t = task { await t.value }
    }

    private func service() throws -> RevisionProviding {
        refreshEngine()
        guard engine.usable else { throw RevisionIssueError(issue: engine.issue ?? RevisionEngineStatus.message) }
        return try makeService()
    }

    private func loadSource(_ service: RevisionProviding, withImages: Bool, _ t: UUID) async throws -> RevisionSource {
        if let source, sourceHasImages || !withImages { return source }
        guard let url = documentURL else { throw CancellationError() }
        let loaded = try await service.loadSource(url: url, withImages: withImages, progress: progressHandler(t, scale: 0...0.2))
        guard isCurrent(t) else { throw CancellationError() }
        source = loaded
        sourceHasImages = withImages
        return loaded
    }

    static func issue(for error: Error, failure: String) -> RevisionIssue? {
        if error is CancellationError { return nil }
        if let e = error as? URLError, e.code == .cancelled { return nil }
        if let e = error as? RevisionIssueError { return e.issue }
        if let e = error as? EngineError {
            switch e {
            case .unavailable(let m):
                return RevisionIssue(title: failure, what: Fr.sentence(m), todo: "Vérifie ton moteur dans les Réglages, puis réessaie.")
            case .auth(let m):
                return RevisionIssue(title: failure, what: "Claude a refusé ta clé. " + Fr.sentence(m), todo: "Vérifie ta clé dans les Réglages.")
            case .rateLimited:
                return RevisionIssue(title: failure, what: "Claude reçoit trop de demandes en ce moment.", todo: "Attends une minute, puis réessaie.")
            case .network:
                return RevisionIssue(title: failure, what: "La connexion à Claude a échoué.", todo: "Vérifie ta connexion Internet, puis réessaie.")
            case .refused(let m):
                return RevisionIssue(title: failure, what: "L'IA n'a pas voulu répondre. " + Fr.sentence(m), todo: "Réessaie, ou essaie avec un autre cours.")
            case .invalidResponse:
                return RevisionIssue(title: failure, what: "La réponse de l'IA était incomplète ou illisible.", todo: "Réessaie. Si ça recommence, essaie avec un cours plus court.")
            case .other(let m):
                return RevisionIssue(title: failure, what: Fr.sentence(m), todo: "Réessaie dans un moment.")
            }
        }
        if let e = error as? URLError {
            return RevisionIssue(title: failure, what: "Problème de connexion (\(e.localizedDescription)).", todo: "Vérifie ta connexion Internet, puis réessaie.")
        }
        return RevisionIssue(title: failure, what: Fr.sentence(error.localizedDescription), todo: "Réessaie. Si ça recommence, relance l'app.")
    }

    // MARK: Consigne libre

    func instruction(for target: InstructionTarget) -> String {
        switch target { case .summary: return summaryInstruction; case .quiz: return quizOptions.instruction }
    }

    func setInstruction(_ text: String, for target: InstructionTarget) {
        switch target { case .summary: summaryInstruction = text; case .quiz: quizOptions.instruction = text }
    }

    func isActive(_ shortcut: InstructionShortcut, for target: InstructionTarget) -> Bool {
        instruction(for: target).contains(shortcut.phrase)
    }

    /// Un clic sur une pastille ajoute sa phrase à la consigne ; un second clic la retire.
    func toggleShortcut(_ shortcut: InstructionShortcut, for target: InstructionTarget) {
        var text = instruction(for: target)
        if text.contains(shortcut.phrase) {
            text = text.replacingOccurrences(of: shortcut.phrase, with: "")
                .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = (text.trimmingCharacters(in: .whitespacesAndNewlines) + " " + shortcut.phrase).trimmingCharacters(in: .whitespaces)
        }
        setInstruction(text, for: target)
    }

    // MARK: Fiche

    /// Pas de fiche ni de cartes ni de questions à partir d'une évaluation : le corrigé après la note est dans l'onglet Évaluations.
    private func evaluationBlocksGeneration() -> Bool {
        guard let url = documentURL else { return false }
        let parts = Array(url.pathComponents.suffix(4))
        guard LibraryTree.isEvaluationPath(parts) else { return false }
        issue = RevisionIssue(title: "C'est une évaluation",
                              what: "Les fiches, cartes mémoire et questions d'entraînement se font à partir des cours, pas d'une évaluation.",
                              todo: "Une fois l'évaluation rendue et notée, utilise la partie « Évaluations » pour comprendre tes erreurs.")
        return true
    }

    func makeSummary() {
        guard canStart, !evaluationBlocksGeneration() else { return }
        let instruction = RevisionPrompts.cleanInstruction(summaryInstruction)
        start("Lecture du cours…", failure: "La fiche n'a pas pu être créée") { [weak self] t in
            guard let self else { return }
            let service = try self.service()
            let source = try await self.loadSource(service, withImages: false, t)
            self.report(t, 0.2, "Création de la fiche…")
            let result = try await service.makeSummary(source, instruction: instruction, progress: self.progressHandler(t, scale: 0.2...1))
            guard self.isCurrent(t) else { throw CancellationError() }
            self.summary = result
            self.memoriser()
        }
    }

    func saveSummaryPDF() {
        guard let summary else { return }
        let exporter = exporter, name = documentName
        save(suggested: "Fiche – \(name).pdf", failure: "La fiche n'a pas pu être enregistrée") {
            try exporter.summaryPDF(summary, documentName: name)
        }
    }

    // MARK: Entraînement

    var current: RevisionQuestion? { questions.indices.contains(currentIndex) ? questions[currentIndex] : nil }
    var allGraded: Bool { !questions.isEmpty && questions.allSatisfy { graded[$0.id] != nil } }
    var missedQuestions: [RevisionQuestion] { questions.filter { graded[$0.id]?.verdict != .juste } }

    /// Juste = 1 point, partiel = ½ point.
    var score: Double {
        questions.reduce(0) { total, q in
            switch graded[q.id]?.verdict { case .juste: return total + 1; case .partiel: return total + 0.5; default: return total }
        }
    }

    var scoreText: String {
        let s = score
        let value = s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s).replacingOccurrences(of: ".", with: ",")
        return "\(value) sur \(questions.count)"
    }

    func toggleStyle(_ style: QuestionStyle) {
        if quizOptions.styles.contains(style) {
            if quizOptions.styles.count > 1 { quizOptions.styles.remove(style) }
        } else {
            quizOptions.styles.insert(style)
        }
    }

    func makeQuiz() {
        guard canStart, !quizOptions.styles.isEmpty, !evaluationBlocksGeneration() else { return }
        var options = quizOptions
        options.instruction = RevisionPrompts.cleanInstruction(options.instruction)
        start("Lecture du cours…", failure: "Les questions n'ont pas pu être créées") { [weak self] t in
            guard let self else { return }
            let service = try self.service()
            let source = try await self.loadSource(service, withImages: false, t)
            self.report(t, 0.2, "Création des questions…")
            let result = try await service.makeQuiz(source, options: options, progress: self.progressHandler(t, scale: 0.2...1))
            guard self.isCurrent(t) else { throw CancellationError() }
            guard !result.isEmpty else {
                throw RevisionIssueError(issue: RevisionIssue(
                    title: "Les questions n'ont pas pu être créées",
                    what: "L'IA n'a proposé aucune question pour ce cours.",
                    todo: "Réessaie, ou choisis d'autres types de questions."))
            }
            self.beginQuiz(result)
            self.round = 1
            self.memorisedQuestions = result
            self.memoriser()
        }
    }

    private func beginQuiz(_ list: [RevisionQuestion]) {
        if round == 1 { memorisedQuestions = list }
        questions = list
        answers = [:]
        graded = [:]
        currentIndex = 0
        showingResults = false
    }

    private func resetQuiz() {
        questions = []; answers = [:]; graded = [:]; currentIndex = 0; showingResults = false; round = 1
    }

    /// Retour aux options (nouvelles questions).
    func newQuiz() { guard !isBusy else { return }; resetQuiz() }

    func answer(for q: RevisionQuestion) -> String { answers[q.id] ?? "" }

    func setAnswer(_ text: String, for q: RevisionQuestion) {
        guard graded[q.id] == nil else { return }
        answers[q.id] = text
    }

    func canGrade(_ q: RevisionQuestion) -> Bool {
        !isBusy && graded[q.id] == nil && !answer(for: q).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func goTo(_ index: Int) {
        guard questions.indices.contains(index) else { return }
        currentIndex = index
    }

    static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    /// Corrige la question affichée. QCM et vrai/faux : correction locale (pas d'appel à l'IA).
    func gradeCurrent() {
        guard let q = current, canGrade(q) else { return }
        let given = answer(for: q)
        if q.style == .qcm || q.style == .vraiFaux {
            let ok = Self.normalized(given) == Self.normalized(q.expected)
            graded[q.id] = GradedAnswer(
                questionID: q.id, verdict: ok ? .juste : .faux,
                feedback: ok ? "Bonne réponse." : "Ce n'est pas la bonne réponse.",
                expected: q.expected)
            return
        }
        start("Correction de ta réponse…", failure: "La réponse n'a pas pu être corrigée") { [weak self] t in
            guard let self else { return }
            let service = try self.service()
            let result = try await service.grade([(question: q, answer: given)])
            guard self.isCurrent(t) else { throw CancellationError() }
            guard let first = result.first else {
                throw RevisionIssueError(issue: RevisionIssue(
                    title: "La réponse n'a pas pu être corrigée",
                    what: "L'IA n'a rien renvoyé pour cette question.",
                    todo: "Appuie de nouveau sur « Corriger »."))
            }
            var g = first
            g.questionID = q.id
            self.graded[q.id] = g
        }
    }

    func next() {
        if currentIndex + 1 < questions.count { currentIndex += 1 }
        else if allGraded { showingResults = true }
    }

    func previous() { if currentIndex > 0 { currentIndex -= 1 } }
    func showResults() { if allGraded { showingResults = true } }
    func backToQuestions() { showingResults = false }

    func retryMissed() {
        let missed = missedQuestions
        guard !missed.isEmpty, !isBusy else { return }
        beginQuiz(missed)
        round += 1
    }

    func exportQuizPDF(withAnswers: Bool) {
        guard !questions.isEmpty else { return }
        let exporter = exporter, name = documentName, list = questions
        save(suggested: "Questions – \(name)\(withAnswers ? " (corrigé)" : "").pdf",
             failure: "Les questions n'ont pas pu être enregistrées") {
            try exporter.quizPDF(list, documentName: name, withAnswers: withAnswers)
        }
    }

    // MARK: Cartes mémoire

    var currentCard: RevisionCard? { deck.indices.contains(cardIndex) ? deck[cardIndex] : nil }
    var cardsToReview: [RevisionCard] { deck.filter { cardToReview.contains($0.id) } }
    var cardsAnswered: Int { cardKnown.count + cardToReview.count }
    var cardsScoreText: String { "\(cardKnown.count) sur \(deck.count)" }
    /// Les boutons « Je savais » et « À revoir » ne marchent qu'une fois la carte retournée.
    var canMarkCard: Bool { currentCard != nil && cardFlipped && !cardsFinished }

    func setCardCount(_ n: Int) { cardCount = min(CardLimits.range.upperBound, max(CardLimits.range.lowerBound, n)) }

    func makeCards() {
        guard canStart, !evaluationBlocksGeneration() else { return }
        let count = min(CardLimits.range.upperBound, max(CardLimits.range.lowerBound, cardCount))
        start("Lecture du cours…", failure: "Les cartes n'ont pas pu être créées") { [weak self] t in
            guard let self else { return }
            let service = try self.service()
            let source = try await self.loadSource(service, withImages: false, t)
            self.report(t, 0.2, "Création des cartes…")
            let result = try await service.makeCards(source, count: count, progress: self.progressHandler(t, scale: 0.2...1))
            guard self.isCurrent(t) else { throw CancellationError() }
            guard !result.isEmpty else {
                throw RevisionIssueError(issue: RevisionIssue(
                    title: "Les cartes n'ont pas pu être créées",
                    what: "L'IA n'a proposé aucune carte pour ce cours.",
                    todo: "Réessaie dans un instant."))
            }
            self.cards = result
            self.beginDeck(result)
            self.cardRound = 1
            self.memoriser()
        }
    }

    private func beginDeck(_ list: [RevisionCard]) {
        deck = list
        cardIndex = 0
        cardFlipped = false
        cardKnown = []
        cardToReview = []
        cardsFinished = false
    }

    private func resetCards() {
        cards = []; deck = []; cardIndex = 0; cardFlipped = false
        cardKnown = []; cardToReview = []; cardsFinished = false; cardRound = 1
    }

    func flipCard() {
        guard currentCard != nil, !cardsFinished else { return }
        cardFlipped.toggle()
    }

    /// « Je savais » (`known`) ou « À revoir » ; passe à la carte suivante, ou termine la série.
    func markCard(known: Bool) {
        guard canMarkCard, let card = currentCard else { return }
        if known { cardKnown.insert(card.id); cardToReview.remove(card.id) }
        else { cardToReview.insert(card.id); cardKnown.remove(card.id) }
        if cardIndex + 1 < deck.count {
            cardIndex += 1
            cardFlipped = false
        } else {
            cardsFinished = true
            cardFlipped = false
        }
    }

    /// Rejoue seulement les cartes à revoir.
    func replayCardsToReview() {
        let list = cardsToReview
        guard !list.isEmpty else { return }
        beginDeck(list.shuffled())       // un autre ordre à chaque série : on retient la réponse, pas sa place
        cardRound += 1
    }

    /// Rejoue tout le paquet depuis le début.
    func restartCards() {
        guard !cards.isEmpty else { return }
        beginDeck(cards.shuffled())
        cardRound = 1
    }

    /// Retour au réglage du nombre de cartes (nouvelles cartes).
    func newCards() { guard !isBusy else { return }; resetCards() }

    func exportCardsPDF() {
        guard !cards.isEmpty else { return }
        let exporter = exporter, name = documentName, list = cards
        save(suggested: "Cartes – \(name).pdf", failure: "Les cartes n'ont pas pu être enregistrées") {
            try exporter.cardsPDF(list, documentName: name)
        }
    }

    // MARK: Après l'évaluation

    var canMakeCorrige: Bool { canStart && corrigeConfirmed }

    func makeCorrige() {
        guard canMakeCorrige else { return }
        start("Lecture de l'évaluation…", failure: "Le corrigé n'a pas pu être créé") { [weak self] t in
            guard let self else { return }
            let service = try self.service()
            let source = try await self.loadSource(service, withImages: self.engine.supportsImages, t)
            self.report(t, 0.2, "Préparation du corrigé…")
            let result = try await service.makeCorrige(source, progress: self.progressHandler(t, scale: 0.2...1))
            guard self.isCurrent(t) else { throw CancellationError() }
            self.corrigeItems = result
            self.memoriser()
            if result.isEmpty {
                throw RevisionIssueError(issue: RevisionIssue(
                    title: "Le corrigé est vide",
                    what: "L'IA n'a trouvé aucune question dans ce document.",
                    todo: "Vérifie que c'est bien ton évaluation rendue, avec tes réponses visibles."))
            }
        }
    }

    /// Le corrigé trié pour l'écran : les questions fausses d'abord, puis les partielles, puis le reste (ordre de la feuille).
    var sortedCorrigeItems: [CorrigeItem] {
        func rang(_ v: Verdict?) -> Int { v == .faux ? 0 : (v == .partiel ? 1 : 2) }
        return corrigeItems.enumerated().sorted { (rang($0.element.status), $0.offset) < (rang($1.element.status), $1.offset) }.map(\.element)
    }

    /// Questions à retravailler : fausses ou partielles, et celles que le professeur n'a pas marquées.
    var corrigeMistakes: [CorrigeItem] { corrigeItems.filter { $0.status != .juste } }

    /// « Cartes à partir de mes erreurs » : fabriquées sur le Mac à partir du corrigé, sans appel à l'IA.
    func cardsFromCorrige() {
        guard !isBusy, !corrigeMistakes.isEmpty else { return }
        let list = corrigeMistakes.enumerated().map { i, item in
            RevisionCard(id: i + 1, front: item.instruction,
                         back: item.toRemember.isEmpty ? item.correctAnswer : "\(item.correctAnswer)\n\nÀ retenir : \(item.toRemember)",
                         page: item.page)
        }
        cards = list
        beginDeck(list)
        cardRound = 1
        tab = .cartes
        memoriser()
    }

    func saveCorrigePDF() {
        guard !corrigeItems.isEmpty else { return }
        let exporter = exporter, name = documentName, items = corrigeItems
        save(suggested: "Corrigé – \(name).pdf", failure: "Le corrigé n'a pas pu être enregistré") {
            try exporter.corrigePDF(items, documentName: name)
        }
    }

    // MARK: Enregistrement (nouveau PDF, jamais l'original)

    func revealLastSaved() { if let lastSaved { dialogs.reveal(lastSaved) } }

    private func save(suggested: String, failure: String, _ make: @escaping @Sendable () throws -> Data) {
        guard !isBusy, let target = dialogs.chooseSaveURL(suggestedName: suggested,
                                                          directory: documentURL?.deletingLastPathComponent()) else { return }
        if let original = documentURL, target.standardizedFileURL == original.standardizedFileURL {
            dialogs.inform(title: "Ton cours d'origine est protégé",
                           message: "Choisis un autre nom : l'original n'est jamais modifié.")
            return
        }
        start("Création du PDF…", failure: failure) { [weak self] t in
            let data = try await Task.detached { try make() }.value
            try data.write(to: target, options: .atomic)
            guard let self, self.isCurrent(t) else { return }
            self.notice = "Enregistré : \(target.lastPathComponent)."
            self.lastSaved = target
        }
    }
}
