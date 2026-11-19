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
    @Published var undoLog: [(from: URL, to: URL)] = []
    @Published var batch: (done: Int, total: Int, current: String)?
    @Published var batchReport: String?
    @Published var checkedCount = 0
    private var task: Task<Void, Never>?

    var isBusy: Bool { if case .reading = phase { return true }; if case .asking = phase { return true }; return batch != nil }

    func run() {
        guard !isBusy else { return }
        let library = LibraryModel.shared
        let root = library.root, files = library.files
        suggestions = []; incomplete = []; note = nil; batchReport = nil; undoLog = []
        phase = .reading(0)
        task = Task {
            var digests: [CourseDigest] = []
            for (i, f) in files.enumerated() {
                if Task.isCancelled { phase = .idle; return }
                digests.append(await Task.detached(priority: .userInitiated) { CourseAnalysis.digest(f) }.value)
                phase = .reading(Double(i + 1) / Double(max(files.count, 1)))
            }
            checkedCount = digests.count
            incomplete = digests.filter(\.isIncomplete)
            completeChoice = Set(incomplete.map(\.path))
            do {
                let generator = try AnalysisEngine.generator()
                phase = .asking(0)
                let folders = await Task.detached { CourseAnalysis.folderCatalog(root: root) }.value
                suggestions = try await CourseAnalysis.suggest(digests: digests, folders: folders, generator: generator) { [weak self] p in
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

    // MARK: Réorganiser

    func applyMoves() {
        let root = LibraryModel.shared.root
        var done = 0
        for s in suggestions where moveChoice.contains(s.path) {
            do { let to = try CourseAnalysis.move(s, root: root); undoLog.append((root.appendingPathComponent(s.path), to)); done += 1 }
            catch { note = Fr.sentence(error.localizedDescription) }
        }
        let moved = Set(undoLog.map { $0.from.path })
        suggestions.removeAll { moved.contains(root.appendingPathComponent($0.path).path) }
        incomplete.removeAll { moved.contains(root.appendingPathComponent($0.path).path) }
        moveChoice = Set(suggestions.map(\.path))
        if done > 0 { note = "\(done) fichier(s) rangé(s). Tu peux annuler." }
        LibraryModel.shared.refresh()
    }

    func undoMoves() {
        for (from, to) in undoLog.reversed() { try? FileManager.default.moveItem(at: to, to: from) }
        undoLog = []; note = "Rangement annulé."
        LibraryModel.shared.refresh()
    }

    // MARK: Compléter

    func completeSelected() {
        let root = LibraryModel.shared.root
        let items = incomplete.filter { completeChoice.contains($0.path) && !$0.isEvaluation }
        guard !items.isEmpty, !isBusy else { return }
        let engine = RunSettings.current().engineDisplayName
        let alert = NSAlert()
        alert.messageText = "Compléter \(items.count) cours avec \(engine) ?"
        alert.informativeText = "Les originaux ne sont pas modifiés : une copie « (complétée) » est créée à côté de chacun. Cela peut prendre plusieurs minutes et consomme ton moteur d'IA. Les évaluations ne sont jamais complétées."
        alert.addButton(withTitle: "Compléter"); alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        batchReport = nil
        task = Task {
            var ok = 0, failed: [String] = []
            for (i, d) in items.enumerated() {
                if Task.isCancelled { break }
                batch = (i, items.count, (d.path as NSString).lastPathComponent)
                do { try await Self.completeOne(root.appendingPathComponent(d.path)); ok += 1 }
                catch {
                    failed.append("\((d.path as NSString).lastPathComponent) : \(Fr.sentence(error.localizedDescription))")
                    if let e = error as? EngineError, e.isFatal { break }
                }
            }
            batch = nil
            batchReport = "\(ok) cours complété(s)" + (failed.isEmpty ? "." : ", \(failed.count) en échec :\n" + failed.joined(separator: "\n"))
            LibraryModel.shared.refresh()
        }
    }

    private static func completeOne(_ url: URL) async throws {
        var settings = RunSettings.current(); settings.flatten = true
        let snapshot = settings
        let defaults = UserDefaults(suiteName: "fr.complete-cours.batch") ?? .standard
        defaults.removePersistentDomain(forName: "fr.complete-cours.batch")
        let model = CoursModel(settings: { snapshot }, engineFactory: { try EngineFactory.make($0) },
                               dialogs: SilentDialogs(), defaults: defaults)
        await model.load(url)
        guard model.document != nil else { throw CoursError.message(model.openError ?? "Le PDF n'a pas pu être ouvert.") }
        await model.complete()
        if let problem = model.runProblem { throw CoursError.message(problem.message) }
        model.renderAnswers()
        let base = url.deletingPathExtension()
        var out = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + " (complétée).pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent) (complétée \(n)).pdf"); n += 1
        }
        try await model.export(to: out)
    }
}

// MARK: - Dépôt d'un nouveau cours

/// Un PDF déposé : l'app le lit, l'IA choisit le dossier, il est rangé tout de suite (annulable).
@MainActor
final class IntakeModel: ObservableObject {
    static let shared = IntakeModel()
    @Published var notice: String?
    @Published var busy = false
    private var last: (from: URL, to: URL)?

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        panel.message = "Choisis les nouveaux cours à ranger."
        if panel.runModal() == .OK { handle(panel.urls) }
    }

    func handle(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { notice = "Dépose un PDF : les autres formats ne sont pas encore pris en charge."; return }
        Task { for url in pdfs { await file(url) } }
    }

    func undo() {
        guard let (from, to) = last else { return }
        try? FileManager.default.moveItem(at: to, to: from)
        last = nil; notice = "Rangement annulé : « \(from.lastPathComponent) » est revenu où il était."
        LibraryModel.shared.refresh()
    }

    private func file(_ url: URL) async {
        busy = true; defer { busy = false }
        let root = LibraryModel.shared.root
        let name = url.deletingPathExtension().lastPathComponent
        notice = "Lecture de « \(name) »…"
        let isEval = LibraryTree.looksLikeEvaluation(name)
        let excerpt = isEval ? "" : await Task.detached { CourseAnalysis.firstPageText(url) }.value
        let folders = await Task.detached { CourseAnalysis.folderCatalog(root: root) }.value
        let digest = CourseDigest(path: "À ranger/\(url.lastPathComponent)", isEvaluation: isEval, excerpt: excerpt)
        var suggestion = AnalysisSuggestion(path: digest.path, folder: "À classer", newName: "", reason: "")
        var how = "IA indisponible : rangé dans « À classer »."
        if let generator = try? AnalysisEngine.generator(),
           let raw = try? await generator.generate(system: CourseAnalysis.system + "\nC'est un NOUVEAU fichier à ranger : propose toujours un dossier.",
                                                   userText: CourseAnalysis.userText(digests: [digest], folders: folders),
                                                   images: [], schema: CourseAnalysis.schema),
           let parsed = try? RevJSON.parse(raw),
           let s = CourseAnalysis.parse(parsed, knownPaths: [digest.path], folders: folders).first {
            suggestion = s; how = s.reason
        }
        // un nom de scan (« Scan2026… », « IMG_… ») est remplacé ; un nom choisi par l'élève est gardé
        let junk = name.range(of: "^(scan|img|image|document|sans titre|untitled)[ _-]*\\d", options: [.regularExpression, .caseInsensitive]) != nil
        if !junk { suggestion.newName = "" }
        do {
            let to = try CourseAnalysis.move(suggestion, root: root, source: url)
            last = (url, to)
            notice = "« \(to.lastPathComponent) » rangé dans \(suggestion.folder.replacingOccurrences(of: "/", with: " › ")). \(how)"
            let library = LibraryModel.shared
            library.refresh()
        } catch { notice = "Impossible de ranger « \(name) » : \(Fr.sentence(error.localizedDescription))" }
    }
}

// MARK: - Fenêtre d'analyse

struct AnalysisSheet: View {
    @ObservedObject var model = AnalysisModel.shared
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
        .onAppear { if model.phase == .idle { model.run() } }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .reading(let p): progress("Lecture des cours…", p)
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
            if let note = model.note { Section { Text(note).font(.callout) } }
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
                HStack {
                    Button("Appliquer le rangement") { model.applyMoves() }
                        .disabled(model.moveChoice.isEmpty || model.suggestions.isEmpty)
                    if !model.undoLog.isEmpty { Button("Annuler le rangement") { model.undoMoves() } }
                }
            }
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
                    ProgressView(value: Double(b.done), total: Double(b.total)) { Text("« \(b.current) » (\(b.done + 1)/\(b.total))") }
                } else {
                    Button("Compléter la sélection…") { model.completeSelected() }.disabled(model.completeChoice.isEmpty)
                }
                if let r = model.batchReport { Text(r).font(.callout) }
                Text("Détection locale : un cours déjà rempli peut parfois apparaître ici, vérifie la liste avant de lancer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
