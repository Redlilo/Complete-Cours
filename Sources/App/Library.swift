import SwiftUI
import AppKit
import PDFKit

/// Lit le dossier des cours (par défaut ~/Desktop/Cours) et garde l'arborescence + les dossiers dépliés.
@MainActor
final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()
    static let rootKey = "libraryRoot"
    static let expandedKey = "libraryExpanded"

    @Published private(set) var files: [LibraryFile] = []
    @Published private(set) var tree = LibraryFolder.empty
    @Published private(set) var expanded: Set<String>
    @Published private(set) var isScanning = false
    @Published private(set) var problem: String?
    @Published var selected: LibraryFile?
    @Published var root: URL

    private init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: Self.rootKey) {
            root = URL(fileURLWithPath: path)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Cours")
        }
        expanded = Set(defaults.stringArray(forKey: Self.expandedKey) ?? [])
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = "Choisir"
        panel.message = "Choisis le dossier qui contient tous tes cours."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = url
        UserDefaults.standard.set(url.path, forKey: Self.rootKey)
        expanded = []
        saveExpanded()
        refresh()
    }

    func refresh() {
        let root = self.root
        isScanning = true
        problem = nil
        Task {
            let found = await Task.detached(priority: .userInitiated) { LibraryTree.scan(root) }.value
            files = found
            tree = LibraryTree.build(found)
            isScanning = false
            if !FileManager.default.fileExists(atPath: root.path) {
                problem = "Le dossier « \(root.lastPathComponent) » est introuvable. Choisis le dossier de tes cours."
            } else if found.isEmpty {
                problem = "Aucun PDF trouvé dans « \(root.lastPathComponent) »."
            }
        }
    }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        saveExpanded()
    }

    func expandAll() { expanded = Set(LibraryTree.folderIDs(tree)); saveExpanded() }
    func collapseAll() { expanded = []; saveExpanded() }

    private func saveExpanded() {
        UserDefaults.standard.set(Array(expanded).sorted(), forKey: Self.expandedKey)
    }
}

// MARK: - Vignettes et aperçu

/// Première page de chaque PDF, calculée hors de l'écran puis gardée en mémoire.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let img = await Task.detached(priority: .utility) {
            PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: CGSize(width: 150, height: 200), for: .cropBox)
        }.value
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }
}

struct ThumbnailView: View {
    let url: URL
    var size = CGSize(width: 36, height: 48)
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(.quaternary).overlay(Image(systemName: "doc.text").foregroundStyle(.secondary)) }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .task(id: url) { image = await Thumbnails.shared.image(for: url) }
    }
}

/// Le PDF en entier, défilant, pour l'aperçu.
struct PDFKitView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true; v.displayMode = .singlePageContinuous; v.displaysPageBreaks = true
        v.backgroundColor = .underPageBackgroundColor
        v.document = PDFDocument(url: url)
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url { v.document = PDFDocument(url: url) }
    }
}

// MARK: - Vue

struct LibraryView: View {
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var intake = IntakeModel.shared
    @State private var search = ""
    @State private var showArchive = false
    @AppStorage("archiveOriginals") private var archiveAuto = true
    @State private var showAnalysis = false
    @State private var showHistory = false
    @ObservedObject private var history = MoveHistory.shared
    @State private var dropTargeted = false

    private var rows: [LibraryRow] {
        LibraryTree.rows(root: library.tree, expanded: library.expanded, query: search)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let b = history.banner { MoveBanner(count: b.count).padding(.horizontal, 20).padding(.bottom, 8) }
            if let notice = intake.notice { intakeBanner(notice) }
            if let problem = library.problem, library.files.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(problem).multilineTextAlignment(.center)
                    Button("Choisir le dossier des cours…") { library.chooseRoot() }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    listPane.frame(minWidth: 380, idealWidth: 520)
                    previewPane.frame(minWidth: 300, idealWidth: 400)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if library.files.isEmpty { library.refresh() } }
        .sheet(isPresented: $showAnalysis) { AnalysisSheet() }
        .sheet(isPresented: $showHistory) { MoveHistorySheet() }
        .sheet(isPresented: $showArchive) { ArchiveSheet() }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6])).padding(6).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            DropLoader.urls(from: providers) { urls in IntakeModel.shared.handle(urls) }
            return true
        }
    }

    private var listPane: some View {
        Group {
            if rows.isEmpty && !library.isScanning {
                ContentUnavailableView.search(text: search)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(rows) { row in
                            switch row.content {
                            case .folder(let folder, let expanded): FolderRowView(folder: folder, depth: row.depth, expanded: expanded)
                            case .file(let file): FileRowView(file: file, depth: row.depth)
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .overlay { if library.isScanning && library.files.isEmpty { ProgressView("Recherche des cours…") } }
            }
        }
    }

    private var previewPane: some View {
        Group {
            if let file = library.selected, FileManager.default.fileExists(atPath: file.url.path) {
                DocumentPreview(file: file)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                    Text("Choisis un cours pour le voir ici").foregroundStyle(.secondary)
                    Text("Glisse un PDF sur la fenêtre pour l'ajouter et le ranger.").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
    }

    private func intakeBanner(_ text: String) -> some View {
        HStack {
            if intake.busy { ProgressView().controlSize(.small) } else { Image(systemName: "tray.and.arrow.down") }
            Text(text).font(.callout).lineLimit(3)
            Spacer()
            if !intake.busy { Button("Annuler le rangement") { intake.undo() } }
            Button { intake.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(10).background(Color.accentColor.opacity(0.12))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mes cours").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("\(library.files.count) PDF · \((library.root.path as NSString).abbreviatingWithTildeInPath)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Chercher", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary, in: Capsule()).frame(maxWidth: 190)
            Button { intake.chooseFiles() } label: { Label("Ajouter", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .help("Ajouter un nouveau cours : il est lu puis rangé automatiquement (tu peux aussi le déposer ici)")
            Button { showAnalysis = true } label: { Label("Analyser", systemImage: "sparkle.magnifyingglass") }
                .buttonStyle(.bordered).controlSize(.large)
                .help("Lire tous les cours pour proposer de les réorganiser ou de les compléter")
            Menu {
                Button("Tout déplier") { withAnimation(.snappy(duration: 0.15)) { library.expandAll() } }.disabled(!search.isEmpty)
                Button("Tout replier") { withAnimation(.snappy(duration: 0.15)) { library.collapseAll() } }.disabled(!search.isEmpty)
                Divider()
                Button("Ranger les originaux vides…") { showArchive = true }
                Toggle("Ranger l'original après chaque complétion", isOn: $archiveAuto)
                Button("Historique des rangements…") { showHistory = true }
                Button("Actualiser") { library.refresh() }
                Button("Changer le dossier des cours…") { library.chooseRoot() }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().controlSize(.large)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// Un dossier : une carte colorée pour les matières, une ligne simple pour les sous-dossiers.
private struct FolderRowView: View {
    let folder: LibraryFolder
    let depth: Int
    let expanded: Bool
    @State private var hover = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { LibraryModel.shared.toggle(folder.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
                if depth == 0 {
                    Image(systemName: SubjectStyle.symbol(folder.name))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(SubjectStyle.color(folder.name).gradient, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: folder.isEvaluation ? "checkmark.seal" : (expanded ? "folder.fill" : "folder"))
                        .foregroundStyle(folder.isEvaluation ? Color.orange : Color.secondary).frame(width: 22)
                }
                Text(folder.displayName).font(depth == 0 ? .headline : .subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                Text("\(folder.count)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(.quaternary, in: Capsule())
            }
            .padding(.leading, CGFloat(depth) * 22)
            .padding(.horizontal, 10).padding(.vertical, depth == 0 ? 8 : 5)
            .background(RoundedRectangle(cornerRadius: 10).fill(depth == 0 ? Color.primary.opacity(hover ? 0.09 : 0.05) : (hover ? Color.primary.opacity(0.05) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("\(folder.displayName), \(folder.count) PDF")
        .accessibilityValue(expanded ? "déplié" : "replié")
    }
}

/// Étiquettes d'état : « Évaluation », « Complété par l'app » (copie faite par l'app, d'après le journal) ou l'état lu dans le nom.
private struct StateTags: View {
    let file: LibraryFile
    var body: some View {
        if file.isEvaluation { Tag(text: "Évaluation", color: .orange) }
        if CourseLedger.shared.isAppCopy(file.url) { Tag(text: "Complété par l'app", color: .green) }
        else if let label = file.state.label { Tag(text: label, color: .secondary) }
    }
}

/// Un PDF : vignette, nom, étiquettes ; les actions apparaissent au survol ou à la sélection.
private struct FileRowView: View {
    let file: LibraryFile
    let depth: Int
    @EnvironmentObject var navigator: Navigator
    @ObservedObject private var library = LibraryModel.shared
    @State private var hover = false

    private var isSelected: Bool { library.selected?.id == file.id }

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(url: file.url)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.subheadline).lineLimit(2)
                HStack(spacing: 5) {
                    StateTags(file: file)
                }
            }
            Spacer(minLength: 4)
            if hover || isSelected { actions.transition(.opacity) }
        }
        .padding(.leading, CGFloat(depth) * 22 + 22)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.18) : (hover ? Color.primary.opacity(0.05) : .clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { openByDefault() }
        .onTapGesture { library.selected = file }
        .contextMenu {
            if !file.isEvaluation { Button("Compléter le cours") { navigator.complete(file.url) } }
            Button("Fiche de révision") { navigator.makeSheet(file.url) }
            Button("Corrigé d'évaluation (après la note)") { navigator.correct(file.url) }
            Divider()
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            if file.isEvaluation {
                Button("Corriger") { navigator.correct(file.url) }.buttonStyle(.borderedProminent)
            } else {
                if file.state == .vierge { Button("Compléter") { navigator.complete(file.url) }.buttonStyle(.borderedProminent) }
                Button("Fiche") { navigator.makeSheet(file.url) }.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }

    private func openByDefault() {
        if file.isEvaluation { navigator.correct(file.url) }
        else if file.state == .vierge { navigator.complete(file.url) }
        else { navigator.makeSheet(file.url) }
    }
}

/// Volet de droite : le document en grand, avec ses actions.
private struct DocumentPreview: View {
    let file: LibraryFile
    @EnvironmentObject var navigator: Navigator

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(file.name).font(.headline).lineLimit(2)
                Text(file.folders.joined(separator: " › ")).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    StateTags(file: file)
                    Spacer()
                    if file.isEvaluation {
                        Button("Corriger") { navigator.correct(file.url) }.buttonStyle(.borderedProminent)
                    } else {
                        if file.state == .vierge { Button("Compléter") { navigator.complete(file.url) }.buttonStyle(.borderedProminent) }
                        Button("Fiche") { navigator.makeSheet(file.url) }.buttonStyle(.bordered)
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "folder") }
                        .help("Afficher dans le Finder")
                }
                .controlSize(.regular)
            }
            .padding(14)
            Divider()
            PDFKitView(url: file.url).id(file.url)
        }
    }
}
