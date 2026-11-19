import SwiftUI
import AppKit

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

// MARK: - Vue

struct LibraryView: View {
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var intake = IntakeModel.shared
    @State private var search = ""
    @State private var showAnalysis = false
    @State private var dropTargeted = false

    private var rows: [LibraryRow] {
        LibraryTree.rows(root: library.tree, expanded: library.expanded, query: search)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice = intake.notice { intakeBanner(notice) }
            if let problem = library.problem, library.files.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(problem).multilineTextAlignment(.center)
                    Button("Choisir le dossier des cours…") { library.chooseRoot() }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty && !library.isScanning {
                ContentUnavailableView.search(text: search)
            } else {
                List {
                    ForEach(rows) { row in
                        switch row.content {
                        case .folder(let folder, let expanded):
                            FolderRowView(folder: folder, depth: row.depth, expanded: expanded)
                        case .file(let file):
                            FileRowView(file: file, depth: row.depth)
                        }
                    }
                }
                .listStyle(.inset)
                .overlay { if library.isScanning && library.files.isEmpty { ProgressView("Recherche des cours…") } }
            }
        }
        .onAppear { if library.files.isEmpty { library.refresh() } }
        .sheet(isPresented: $showAnalysis) { AnalysisSheet() }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6])).padding(6).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            DropLoader.urls(from: providers) { urls in IntakeModel.shared.handle(urls) }
            return true
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
        .padding(10).background(Color.accentColor.opacity(0.1))
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bibliothèque").font(.title2.weight(.semibold))
                Text("\(library.files.count) PDF · \((library.root.path as NSString).abbreviatingWithTildeInPath)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            TextField("Chercher un cours", text: $search)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
            Button { intake.chooseFiles() } label: { Label("Ajouter un cours", systemImage: "plus.circle") }
                .help("Ajouter un nouveau cours : il est lu puis rangé automatiquement (tu peux aussi le déposer ici)")
            Button { showAnalysis = true } label: { Label("Analyser les cours", systemImage: "sparkle.magnifyingglass") }
                .help("Lire tous les cours pour proposer de les réorganiser ou de les compléter")
            Button { withAnimation(.snappy(duration: 0.15)) { library.expandAll() } } label: {
                Label("Tout déplier", systemImage: "chevron.down.square")
            }
            .labelStyle(.iconOnly).help("Déplier tous les dossiers").disabled(!search.isEmpty)
            Button { withAnimation(.snappy(duration: 0.15)) { library.collapseAll() } } label: {
                Label("Tout replier", systemImage: "chevron.up.square")
            }
            .labelStyle(.iconOnly).help("Replier tous les dossiers").disabled(!search.isEmpty)
            Button { library.refresh() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                .labelStyle(.iconOnly).help("Relire le dossier des cours")
            Button { library.chooseRoot() } label: { Label("Dossier", systemImage: "folder") }
                .labelStyle(.iconOnly).help("Changer le dossier des cours")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

/// Un dossier : un clic le déplie ou le replie.
private struct FolderRowView: View {
    let folder: LibraryFolder
    let depth: Int
    let expanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { LibraryModel.shared.toggle(folder.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
                Image(systemName: icon).foregroundStyle(tint).frame(width: 20)
                Text(folder.displayName)
                    .font(depth == 0 ? .headline : .body).lineLimit(1)
                Spacer()
                Text("\(folder.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.leading, CGFloat(depth) * 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityLabel("\(folder.displayName), \(folder.count) PDF")
        .accessibilityValue(expanded ? "déplié" : "replié")
    }

    private var icon: String {
        if folder.isArchive { return "archivebox" }
        if folder.isEvaluation { return "checkmark.seal" }
        return expanded ? "folder.fill" : "folder"
    }

    private var tint: Color {
        if folder.isEvaluation { return .orange }
        return folder.isArchive ? .secondary : .accentColor
    }
}

/// Un PDF, avec les actions possibles selon ce qu'il est (cours vierge, déjà rempli, évaluation).
private struct FileRowView: View {
    let file: LibraryFile
    let depth: Int
    @EnvironmentObject var navigator: Navigator

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: file.isEvaluation ? "checkmark.seal" : "doc.text")
                .foregroundStyle(file.isEvaluation ? Color.orange : Color.secondary)
                .frame(width: 20)
            Text(file.name).lineLimit(1)
            if file.isEvaluation { Tag(text: "Évaluation", color: .orange) }
            if let label = file.state.label { Tag(text: label, color: .secondary) }
            Spacer()
            if file.isEvaluation {
                Button("Corriger") { navigator.correct(file.url) }
                    .help("Corrigé de cette évaluation (une fois rendue et notée)")
            } else {
                if file.state == .vierge {
                    Button("Compléter") { navigator.complete(file.url) }
                }
                Button("Fiche") { navigator.makeSheet(file.url) }
                    .help("Fiche de révision et entraînement")
            }
        }
        .controlSize(.small)
        .padding(.leading, CGFloat(depth) * 20 + 20)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openByDefault() }
        .contextMenu {
            if !file.isEvaluation { Button("Compléter le cours") { navigator.complete(file.url) } }
            Button("Fiche de révision") { navigator.makeSheet(file.url) }
            Button("Corrigé d'évaluation (après la note)") { navigator.correct(file.url) }
            Divider()
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        }
    }

    private func openByDefault() {
        if file.isEvaluation { navigator.correct(file.url) }
        else if file.state == .vierge { navigator.complete(file.url) }
        else { navigator.makeSheet(file.url) }
    }
}

private struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }
}
