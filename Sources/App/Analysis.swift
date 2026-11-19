import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Moteur d'IA capable de renvoyer du JSON (Claude par clé ou par le compte) ; sinon une erreur lisible.
@MainActor
enum AnalysisEngine {
    static func generator() throws -> StructuredGenerator {
        let engine: CompletionEngine
        do { engine = try EngineFactory.make(RunSettings.current()) }
        catch { throw CoursError.message(Fr.sentence(error.localizedDescription)) }
        guard let g = engine as? StructuredGenerator else {
            throw CoursError.message("Pour proposer un rangement, choisis Claude (clé ou compte) dans les Réglages : Apple Intelligence ne sait pas faire cette analyse.")
        }
        return g
    }
}

/// Historique des rangements (journal persistant) : annulation d'un fichier ou de tout, même après un redémarrage.
@MainActor
final class MoveHistory: ObservableObject {
    static let shared = MoveHistory(ledger: .shared)

    let ledger: CourseLedger
    @Published private(set) var moves: [MoveRecord]
    /// Bandeau « N fichiers rangés — Annuler » : les rangements qui viennent d'être faits.
    @Published private(set) var banner: (count: Int, ids: [UUID])?
    @Published var message: String?

    init(ledger: CourseLedger) { self.ledger = ledger; moves = ledger.moves }

    func reload() { moves = ledger.moves }

    func didMove(_ ids: [UUID]) {
        reload()
        if !ids.isEmpty { banner = (ids.count, ids) }
    }

    func dismissBanner() { banner = nil }

    func undo(_ id: UUID) {
        let name = moves.first { $0.id == id }?.toURL.lastPathComponent ?? "le fichier"
        switch ledger.undo(id) {
        case .restored(let url): message = "« \(url.lastPathComponent) » est revenu où il était."
        case .refused(let why): message = "Annulation impossible pour « \(name) » : \(why)"
        }
        finish()
    }

    func undoBanner() {
        guard let b = banner else { return }
        report(b.ids.reversed().compactMap { id in moves.first { $0.id == id } }.map { ($0, ledger.undo($0.id)) })
        banner = nil
        finish()
    }

    func undoAll() {
        let alert = NSAlert()
        alert.messageText = "Remettre \(moves.count) fichier\(moves.count > 1 ? "s" : "") à leur place d'origine ?"
        alert.informativeText = "Tous les rangements de l'historique sont annulés, même les plus anciens. Un fichier dont l'emplacement d'origine est pris reste où il est."
        alert.addButton(withTitle: "Tout annuler"); alert.addButton(withTitle: "Garder le rangement")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        report(ledger.undoAll())
        banner = nil
        finish()
    }

    func forget(_ id: UUID) { ledger.forgetMove(id); finish() }

    private func report(_ results: [(MoveRecord, UndoOutcome)]) {
        var ok = 0, refused: [String] = []
        for (r, outcome) in results {
            switch outcome {
            case .restored: ok += 1
            case .refused(let why): refused.append("« \(r.toURL.lastPathComponent) » : \(why)")
            }
        }
        var text = ok > 0 ? "\(ok) \(Fr.plural(ok, "fichier remis", "fichiers remis")) à sa place." : ""
        if !refused.isEmpty { text += (text.isEmpty ? "" : " ") + "\(refused.count) non annulé(s), rien n'a été écrasé :\n" + refused.joined(separator: "\n") }
        message = text.isEmpty ? "Rien à annuler." : text
    }

    private func finish() {
        reload()
        if let b = banner, !b.ids.contains(where: { id in moves.contains { $0.id == id } }) { banner = nil }
        LibraryModel.shared.refresh()
        AnalysisModel.shared.movesChanged()
    }
}

/// « Analyser les cours » : lit tous les cours, propose de les réorganiser et de compléter ceux qui ne le sont pas.
@MainActor
final class AnalysisModel: ObservableObject {
    static let shared = AnalysisModel()

    enum Phase: Equatable { case idle, reading(Double), asking(Double), ready, failed(String) }

    @Published var phase: Phase = .idle
    @Published var suggestions: [AnalysisSuggestion] = []
    @Published var incomplete: [CourseDigest] = []
    @Published var moveChoice = Set<String>()
    @Published var completeChoice = Set<String>()
    @Published var note: String?
    @Published var batch: (done: Int, total: Int, current: String)?
    @Published var batchFraction = 0.0
    @Published var batchReport: String?
    @Published var checkedCount = 0
    @Published var rereadCount = 0
    @Published var unchangedCount = 0
    /// Récapitulatif du coût pour la sélection « À compléter » (mis à jour quand on coche ou décoche).
    @Published var cost: CostEstimate?
    @Published private(set) var preparing = false
    private var pageCache: [String: Int] = [:]      // chemin relatif -> pages (-1 : illisible)
    private var costTask: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private let ledger = CourseLedger.shared
    let history = MoveHistory.shared

    /// Vrai dès qu'une analyse a été lancée : permet d'afficher « Analyse arrêtée » au lieu d'un spinner sans fin.
    @Published var hasRun = false

    var isBusy: Bool { if preparing { return true }; if case .reading = phase { return true }; if case .asking = phase { return true }; return batch != nil }

    /// `force` : relit tous les cours et redemande à l'IA, sans utiliser ce que le journal a gardé.
    func run(force: Bool = false) {
        guard !isBusy else { return }
        hasRun = true
        let library = LibraryModel.shared
        let root = library.root, files = library.files.filter { $0.folders.first?.hasPrefix("_") != true }
        suggestions = []; incomplete = []; note = nil; batchReport = nil; pageCache = [:]
        rereadCount = 0; unchangedCount = 0
        phase = .reading(0)
        let ledger = self.ledger
        task = Task {
            var digests: [CourseDigest] = []
            var pairs: [(url: URL, digest: CourseDigest)] = []
            for (i, f) in files.enumerated() {
                if Task.isCancelled { phase = .idle; return }
                let (d, cached) = await Task.detached(priority: .userInitiated) { CourseAnalysis.digest(f, ledger: ledger, force: force) }.value
                digests.append(d); pairs.append((f.url, d))
                if cached { unchangedCount += 1 } else { rereadCount += 1 }
                phase = .reading(Double(i + 1) / Double(max(files.count, 1)))
            }
            ledger.replaceDigests(pairs)
            checkedCount = digests.count
            // un cours déjà complété par l'app (ou sa copie) n'est plus proposé
            incomplete = digests.filter { $0.isIncomplete && !ledger.isCompletedByApp(root.appendingPathComponent($0.path)) }
            completeChoice = Set(incomplete.map(\.path))
            do {
                let generator = try AnalysisEngine.generator()
                phase = .asking(0)
                let folders = await Task.detached { CourseAnalysis.folderCatalog(root: root) }.value
                suggestions = try await CourseAnalysis.suggest(digests: digests, folders: folders, generator: generator,
                                                               ledger: ledger, useCache: !force) { [weak self] p in
                    Task { @MainActor in self?.phase = .asking(p) }
                }
                moveChoice = Set(suggestions.map(\.path))
                phase = .ready
            } catch is CancellationError {
                phase = .idle
            } catch {
                note = Fr.sentence(error.localizedDescription)
                phase = .ready
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Un rangement a été annulé : la liste « à ranger » n'est plus à jour ; on invite à relancer l'analyse.
    func movesChanged() {
        if phase == .ready { note = "Des fichiers ont changé de place : relance l'analyse pour mettre la liste à jour." }
    }

    // MARK: Réorganiser

    func applyMoves() {
        let root = LibraryModel.shared.root
        var ids: [UUID] = [], moved = Set<String>()
        note = nil
        for s in suggestions where moveChoice.contains(s.path) {
            let from = root.appendingPathComponent(s.path)
            do {
                let to = try CourseAnalysis.move(s, root: root)
                ids.append(ledger.recordMove(from: from, to: to, origin: .analyse).id)
                moved.insert(from.path)
            } catch { note = Fr.sentence(error.localizedDescription) }
        }
        suggestions.removeAll { moved.contains(root.appendingPathComponent($0.path).path) }
        incomplete.removeAll { moved.contains(root.appendingPathComponent($0.path).path) }
        moveChoice = Set(suggestions.map(\.path))
        history.didMove(ids)
        LibraryModel.shared.refresh()
    }

    // MARK: Compléter

    /// Les cours cochés, sans jamais une évaluation.
    private var selectedItems: [CourseDigest] {
        incomplete.filter { completeChoice.contains($0.path) && !$0.isEvaluation && !CostEstimate.isEvaluationPath($0.path) }
    }

    static func costEngine(_ settings: RunSettings) -> CostEngine {
        func prices(_ id: String) -> (Double, Double)? {
            ClaudeEngine.models.first { $0.id == id }.map { ($0.inputPricePerMillion, $0.outputPricePerMillion) }
        }
        switch settings.engine {
        case .apple: return .apple
        case .claude:
            guard let m = ClaudeEngine.models.first(where: { $0.id == settings.claudeModel }) else { return .unknown }
            return .claudeAPI(label: m.label, inputPerMillion: m.inputPricePerMillion, outputPerMillion: m.outputPricePerMillion)
        case .claudeCode:
            let name = settings.claudeCodeModel.lowercased()
            let p = ["opus", "sonnet", "haiku"].first { name.contains($0) }.flatMap { k in
                ClaudeEngine.models.first { $0.id.contains(k) }.map { ($0.inputPricePerMillion, $0.outputPricePerMillion) }
            }
            return .claudeAccount(label: EngineKind.claudeCode.title, inputPerMillion: p?.0, outputPerMillion: p?.1)
        }
    }

    /// Ouvre chaque PDF coché (jamais une évaluation) pour compter ses pages, puis calcule l'estimation.
    private func estimate(for items: [CourseDigest]) async -> CostEstimate {
        let root = LibraryModel.shared.root
        let missing = items.map(\.path).filter { pageCache[$0] == nil }
        if !missing.isEmpty {
            let counted = await Task.detached(priority: .userInitiated) { () -> [String: Int] in
                var out: [String: Int] = [:]
                for path in missing { out[path] = PageCounter.pages(of: root.appendingPathComponent(path), relativePath: path) ?? -1 }
                return out
            }.value
            pageCache.merge(counted) { $1 }
        }
        let list = items.map { d -> CostItem in
            let n = pageCache[d.path] ?? -1
            return CostItem(path: d.path, pages: n >= 0 ? n : nil, isEvaluation: d.isEvaluation)
        }
        return CostEstimate.compute(items: list, engine: Self.costEngine(RunSettings.current()))
    }

    /// Recalcule le récapitulatif affiché dans la feuille d'analyse.
    func refreshCost() {
        costTask?.cancel()
        let items = selectedItems
        guard !items.isEmpty else { cost = nil; return }
        costTask = Task {
            let e = await estimate(for: items)
            if !Task.isCancelled { cost = e }
        }
    }

    func completeSelected() {
        let items = selectedItems
        guard !items.isEmpty, !isBusy else { return }
        preparing = true
        Task {
            let estimate = await estimate(for: items)
            preparing = false
            let engine = RunSettings.current().engineDisplayName
            let alert = NSAlert()
            alert.messageText = "Compléter \(items.count) \(Fr.plural(items.count, "cours", "cours")) avec \(engine) ?"
            alert.informativeText = estimate.summary + "\n\nLes originaux ne sont pas modifiés : une copie « (complétée) » est créée à côté de chacun, sans jamais remplacer un fichier existant. Les évaluations ne sont jamais complétées. Si le moteur tombe en panne ou si ta limite est atteinte, le lot s'arrête."
            alert.addButton(withTitle: "Compléter"); alert.addButton(withTitle: "Annuler")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            startBatch(items)
        }
    }

    private func startBatch(_ items: [CourseDigest]) {
        let root = LibraryModel.shared.root
        batchReport = nil
        let ledger = self.ledger
        task = Task {
            var ok: [String] = [], partial: [String] = [], failed: [String] = [], stoppedBy: String?
            var untreated = 0
            for (i, d) in items.enumerated() {
                if Task.isCancelled { untreated = items.count - i; break }
                let name = (d.path as NSString).lastPathComponent
                batch = (i, items.count, name); batchFraction = 0
                let r = await BatchCompleter.complete(url: root.appendingPathComponent(d.path), root: root,
                                                      settings: RunSettings.current(), ledger: ledger,
                                                      progress: { [weak self] f, _ in self?.batchFraction = f })
                if r.written && r.hardProblems.isEmpty {
                    if r.zoneProblems.isEmpty { ok.append(name) } else { partial.append("\(name) : \(r.zoneProblems.joined(separator: " "))") }
                    incomplete.removeAll { $0.path == d.path }
                    // « ne garder que les versions complétées » : l'original vide part dans le dossier des originaux
                    if r.zoneProblems.isEmpty, UserDefaults.standard.object(forKey: Pref.archiveOriginals) as? Bool ?? true,
                       let rec = OriginalsArchive.archiveAfterCompletion(original: r.input, copy: r.output, root: root, ledger: ledger) {
                        MoveHistory.shared.didMove([rec.id])
                    }
                } else {
                    failed.append("\(name) : \(r.hardProblems.joined(separator: " "))")
                    if r.fatal { stoppedBy = r.hardProblems.first; untreated = items.count - i - 1; break }
                }
            }
            batch = nil
            var lines = ["\(ok.count) \(Fr.plural(ok.count, "cours complété", "cours complétés"))."]
            if !partial.isEmpty { lines.append("\(partial.count) \(Fr.plural(partial.count, "copie incomplète", "copies incomplètes")) (relis-les) :\n" + partial.joined(separator: "\n")) }
            if !failed.isEmpty { lines.append("\(failed.count) en échec (aucun fichier créé) :\n" + failed.joined(separator: "\n")) }
            if let why = stoppedBy { lines.append("Le lot s'est arrêté : \(why) \(untreated) \(Fr.plural(untreated, "cours n'a", "cours n'ont")) pas été traité(s).") }
            else if untreated > 0 { lines.append("Arrêté à ta demande : \(untreated) \(Fr.plural(untreated, "cours n'a", "cours n'ont")) pas été traité(s).") }
            batchReport = lines.joined(separator: "\n")
            LibraryModel.shared.refresh()
        }
    }
}

// MARK: - Dépôt d'un nouveau cours

/// Un PDF déposé : l'app le lit, l'IA choisit le dossier, il est rangé tout de suite (annulable).
@MainActor
final class IntakeModel: ObservableObject {
    static let shared = IntakeModel()
    @Published var notice: String?
    @Published var busy = false
    @Published private(set) var lastMove: UUID?

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        panel.message = "Choisis les nouveaux cours à ranger."
        if panel.runModal() == .OK { handle(panel.urls) }
    }

    func handle(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        lastMove = nil
        guard !pdfs.isEmpty else { notice = "Dépose un PDF : les autres formats ne sont pas encore pris en charge."; return }
        Task { for url in pdfs { await file(url) } }
    }

    func undo() {
        guard let id = lastMove else { return }
        let history = MoveHistory.shared
        history.undo(id)
        lastMove = nil
        notice = history.message
        history.message = nil
    }

    private func file(_ url: URL) async {
        busy = true; defer { busy = false }
        lastMove = nil
        let root = LibraryModel.shared.root
        let name = url.deletingPathExtension().lastPathComponent
        notice = "Lecture de « \(name) »…"
        var isEval = LibraryTree.looksLikeEvaluation(name)
        var excerpt = isEval ? "" : await Task.detached { CourseAnalysis.firstPageText(url) }.value
        // une évaluation au nom neutre se reconnaît à son en-tête : son contenu ne part pas vers l'IA
        if !isEval, LibraryTree.headerLooksLikeEvaluation(excerpt) { isEval = true; excerpt = "" }
        let folders = await Task.detached { CourseAnalysis.folderCatalog(root: root) }.value
        let digest = CourseDigest(path: "À ranger/\(url.lastPathComponent)", isEvaluation: isEval, excerpt: excerpt)
        var suggestion = AnalysisSuggestion(path: digest.path, folder: "À classer", newName: "", reason: "")
        var how = "IA indisponible : rangé dans « À classer »."
        if let generator = try? AnalysisEngine.generator(),
           let raw = try? await generator.generate(system: CourseAnalysis.system + "\nC'est un NOUVEAU fichier à ranger : propose toujours un dossier.",
                                                   userText: CourseAnalysis.userText(digests: [digest], folders: folders),
                                                   images: [], schema: CourseAnalysis.schema),
           let parsed = try? RevJSON.parse(raw),
           let s = CourseAnalysis.parse(parsed, knownPaths: [digest.path], folders: folders, evaluationPaths: isEval ? [digest.path] : []).first {
            suggestion = s; how = s.reason
        }
        // un nom de scan (« Scan2026… », « IMG_… ») est remplacé ; un nom choisi par l'élève est gardé
        let junk = name.range(of: "^(scan|img|image|document|sans titre|untitled)[ _-]*\\d", options: [.regularExpression, .caseInsensitive]) != nil
        if !junk { suggestion.newName = "" }
        do {
            let to = try CourseAnalysis.move(suggestion, root: root, source: url, sourceIsEvaluation: isEval)
            let record = CourseLedger.shared.recordMove(from: url, to: to, origin: .depot)
            lastMove = record.id
            MoveHistory.shared.reload()
            notice = "« \(to.lastPathComponent) » rangé dans \(suggestion.folder.replacingOccurrences(of: "/", with: " › ")). \(how)"
            let library = LibraryModel.shared
            library.refresh()
        } catch { notice = "Impossible de ranger « \(name) » : \(Fr.sentence(error.localizedDescription))" }
    }
}

// MARK: - Fenêtre d'analyse

struct AnalysisSheet: View {
    @ObservedObject var model = AnalysisModel.shared
    @ObservedObject private var history = MoveHistory.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Analyse des cours").font(.title2.weight(.semibold))
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            content
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear { if model.phase == .idle, !model.hasRun { model.run() }; model.refreshCost() }
        .onChange(of: model.completeChoice) { _, _ in model.refreshCost() }
        .onChange(of: model.incomplete) { _, _ in model.refreshCost() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            if model.hasRun {
                VStack(spacing: 10) {
                    Text("Analyse arrêtée").font(.headline)
                    Text("Tu peux la relancer quand tu veux : les cours déjà lus ne sont pas relus.").font(.callout).foregroundStyle(.secondary)
                    Button("Relancer l'analyse") { model.run() }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        case .reading(let p): progress("Lecture des cours… (\(model.rereadCount) relus, \(model.unchangedCount) inchangés)", p)
        case .asking(let p): progress("L'IA compare le contenu et l'emplacement…", p)
        case .failed(let m): Text(m).padding(20)
        case .ready: results
        }
    }

    private func progress(_ text: String, _ p: Double) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: p).frame(maxWidth: 360)
            Text(text).foregroundStyle(.secondary)
            Button("Arrêter") { model.cancel() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        List {
            if let b = history.banner { Section { MoveBanner(count: b.count) } }
            if let note = model.note { Section { Text(note).font(.callout) } }
            if let m = history.message { Section { Text(m).font(.callout) } }
            Section {
                HStack {
                    Text(model.rereadCount == 0 && model.unchangedCount == 0 ? "\(model.checkedCount) cours vérifiés"
                         : "\(model.rereadCount) \(Fr.plural(model.rereadCount, "cours relu", "cours relus")), \(model.unchangedCount) \(Fr.plural(model.unchangedCount, "inchangé", "inchangés"))")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Tout relire") { model.run(force: true) }.disabled(model.isBusy)
                        .help("Ignore la mémoire de l'analyse : relit tous les cours et redemande à l'IA")
                }
            }
            Section("À ranger ou renommer (\(model.suggestions.count))") {
                if model.suggestions.isEmpty { Text("Tous les cours analysés sont bien rangés.").foregroundStyle(.secondary) }
                ForEach(model.suggestions) { s in
                    Toggle(isOn: Binding(get: { model.moveChoice.contains(s.path) },
                                         set: { if $0 { model.moveChoice.insert(s.path) } else { model.moveChoice.remove(s.path) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((s.path as NSString).lastPathComponent + (s.newName.isEmpty ? "" : "  →  " + s.newName)).font(.body.weight(.medium))
                            Text("\((s.path as NSString).deletingLastPathComponent) › \(s.folder)").font(.caption).foregroundStyle(.secondary)
                            if !s.reason.isEmpty { Text(s.reason).font(.caption) }
                        }
                    }
                }
                Button("Appliquer le rangement") { model.applyMoves() }
                    .disabled(model.moveChoice.isEmpty || model.suggestions.isEmpty)
            }
            Section("Historique des rangements (\(history.moves.count))") { MoveHistoryRows() }
            Section("À compléter (\(model.incomplete.count))") {
                if model.incomplete.isEmpty { Text("Aucun cours avec des trous restants.").foregroundStyle(.secondary) }
                ForEach(model.incomplete, id: \.path) { d in
                    Toggle(isOn: Binding(get: { model.completeChoice.contains(d.path) },
                                         set: { if $0 { model.completeChoice.insert(d.path) } else { model.completeChoice.remove(d.path) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((d.path as NSString).lastPathComponent).font(.body.weight(.medium))
                            Text("\(d.remaining) trou(s) sans réponse sur \(d.zones) · \((d.path as NSString).deletingLastPathComponent)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let b = model.batch {
                    ProgressView(value: min(Double(b.done) + model.batchFraction, Double(b.total)), total: Double(b.total)) {
                        Text("« \(b.current) » (\(b.done + 1)/\(b.total))")
                    }
                    Button("Arrêter après ce cours") { model.cancel() }
                } else {
                    CostSummaryView(cost: model.cost, preparing: model.preparing)
                    Button("Compléter la sélection…") { model.completeSelected() }.disabled(model.completeChoice.isEmpty)
                }
                if let r = model.batchReport { Text(r).font(.callout).textSelection(.enabled) }
                Text("Détection locale : un cours déjà rempli peut parfois apparaître ici, vérifie la liste avant de lancer. Les cours déjà complétés par l'app n'y figurent plus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Récapitulatif du coût d'un lot (pages, estimation selon le moteur) : estimation, pas une mesure.
struct CostSummaryView: View {
    let cost: CostEstimate?
    let preparing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let cost {
                ForEach(Array(cost.lines.enumerated()), id: \.offset) { i, line in
                    Text(line).font(i == cost.lines.count - 1 ? .caption : .callout)
                        .foregroundStyle(i == cost.lines.count - 1 ? .secondary : .primary)
                }
            } else {
                Text(preparing ? "Comptage des pages…" : "Coche des cours pour voir une estimation du coût.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Historique et bandeau d'annulation

/// « N fichiers rangés — Annuler » : bien visible juste après « Appliquer le rangement ».
struct MoveBanner: View {
    let count: Int
    @ObservedObject private var history = MoveHistory.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.white)
            Text("\(count) \(Fr.plural(count, "fichier rangé", "fichiers rangés"))").font(.headline).foregroundStyle(.white)
            Text("—").foregroundStyle(.white.opacity(0.8))
            Button("Annuler") { history.undoBanner() }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.blue).controlSize(.regular)
            Spacer()
            Button { history.dismissBanner() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.white)
                .help("Masquer (l'historique garde les rangements)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Lignes de l'historique : un « Annuler » par rangement et « Tout annuler ». Fonctionne après un redémarrage.
struct MoveHistoryRows: View {
    @ObservedObject private var history = MoveHistory.shared
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    var body: some View {
        if history.moves.isEmpty {
            Text("Aucun rangement à annuler.").foregroundStyle(.secondary)
        } else {
            ForEach(history.moves) { m in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.toURL.lastPathComponent).font(.body.weight(.medium)).lineLimit(2)
                        Text("\((m.from as NSString).abbreviatingWithTildeInPath) → \((m.to as NSString).abbreviatingWithTildeInPath)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        Text("\(Self.formatter.string(from: m.date)) · \(m.origin == .depot ? "cours déposé" : (m.origin == .originaux ? "original vide rangé" : "analyse"))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Button("Annuler") { history.undo(m.id) }.controlSize(.small)
                    Button { history.forget(m.id) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Retirer de l'historique sans déplacer le fichier")
                }
            }
            Button("Tout annuler") { history.undoAll() }
        }
    }
}

/// Fenêtre « Historique des rangements » du menu « … » de la Bibliothèque.
struct MoveHistorySheet: View {
    @ObservedObject private var history = MoveHistory.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Historique des rangements").font(.title2.weight(.semibold))
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            List {
                if let m = history.message { Section { Text(m).font(.callout) } }
                Section { MoveHistoryRows() }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .onAppear { history.reload(); history.message = nil }
    }
}
