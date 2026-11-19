import Foundation

// Bibliothèque : les PDF du dossier des cours, présentés comme ils sont rangés sur le disque
// (matière › sous-dossiers › fichiers). Logique pure, sans SwiftUI, pour pouvoir la tester (Tools/Tests/Library).

/// Ce que le nom du fichier laisse deviner de son contenu.
enum LibraryFileState: String, Hashable {
    case vierge     // à compléter
    case rempli     // « (complétée) », « complete », « rempli »…
    case corrige    // « corrigé »

    var label: String? {
        switch self {
        case .vierge: return nil
        case .rempli: return "Déjà rempli"
        case .corrige: return "Corrigé"
        }
    }
}

/// Un PDF de la bibliothèque.
struct LibraryFile: Identifiable, Hashable {
    let url: URL
    /// Dossiers entre la racine et le fichier, tels qu'ils sont sur le disque (vide : fichier à la racine).
    let folders: [String]
    let isEvaluation: Bool
    let state: LibraryFileState

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    /// Chemin relatif à la racine, unique : « Maths/Cours/Séquence 1.pdf ».
    var relativePath: String { (folders + [url.lastPathComponent]).joined(separator: "/") }
}

/// Un dossier de la bibliothèque (la racine a l'identifiant vide).
struct LibraryFolder: Identifiable {
    let id: String              // chemin relatif : « Maths/Cours »
    let name: String            // nom sur le disque
    var folders: [LibraryFolder]
    var files: [LibraryFile]

    static let empty = LibraryFolder(id: "", name: "", folders: [], files: [])

    /// Les dossiers de travail commencent par « _ » (ex. « _Originaux avant completion ») : on ne montre pas le « _ ».
    var displayName: String { name.hasPrefix("_") ? String(name.dropFirst()) : name }
    var isArchive: Bool { name.hasPrefix("_") }
    var isEvaluation: Bool { LibraryTree.looksLikeEvaluation(name) }
    /// Nombre de PDF dans ce dossier et ses sous-dossiers.
    var count: Int { files.count + folders.reduce(0) { $0 + $1.count } }
}

/// Une ligne de la liste affichée (déjà aplatie selon les dossiers dépliés).
struct LibraryRow: Identifiable {
    enum Content {
        case folder(LibraryFolder, expanded: Bool)
        case file(LibraryFile)
    }
    let id: String
    let depth: Int
    let content: Content
}

enum LibraryTree {
    // MARK: Lecture du disque

    /// Tous les PDF sous `root` (fichiers cachés ignorés). Ne lit jamais le contenu des fichiers.
    static func scan(_ root: URL) -> [LibraryFile] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [LibraryFile] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "pdf" {
            if let file = makeFile(root: root, url: url) { result.append(file) }
        }
        return result
    }

    /// Fiche d'un fichier situé sous `root` ; nil s'il n'y est pas.
    static func makeFile(root: URL, url: URL) -> LibraryFile? {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else { return nil }
        let folders = Array(parts.dropFirst(rootParts.count).dropLast())
        let name = url.deletingPathExtension().lastPathComponent
        return LibraryFile(url: url, folders: folders,
                           isEvaluation: folders.contains(where: looksLikeEvaluation) || looksLikeEvaluation(name),
                           state: state(forName: name))
    }

    // MARK: Reconnaissance par le nom

    /// Dossier ou fichier d'évaluation : « Eval », « Évaluations », « Contrôle fin de thème », « EVAL PSE », « evalphisyque »…
    static func looksLikeEvaluation(_ name: String) -> Bool {
        // par prudence, ces mots comptent n'importe où dans le nom (« Chap3 eval », « Seq 2 - Contrôle », « DS3 », « Mes Eval »)
        let n = folded(name)
        return n.range(of: "\\b(eval\\w*|controle\\w*|interro\\w*|examen\\w*)\\b|\\bds\\s*\\d", options: .regularExpression) != nil
            || n.hasPrefix("eval") || n.hasPrefix("controle") || n.contains("evaluation")
    }

    static func state(forName name: String) -> LibraryFileState {
        let n = folded(name)
        if n.contains("corrige") { return .corrige }
        if n.contains("complete") || n.contains("rempli") { return .rempli }
        return .vierge
    }

    private static func folded(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    // MARK: Arborescence

    /// Arbre des dossiers comme sur le disque : sous-dossiers d'abord, puis fichiers, dans l'ordre naturel du Finder
    /// (« Séance 2 » avant « Séance 10 »). Les dossiers de travail commençant par « _ » passent en dernier.
    static func build(_ files: [LibraryFile]) -> LibraryFolder {
        folder(id: "", name: "", files: files, depth: 0)
    }

    private static func folder(id: String, name: String, files: [LibraryFile], depth: Int) -> LibraryFolder {
        let direct = files.filter { $0.folders.count == depth }
        let nested = Dictionary(grouping: files.filter { $0.folders.count > depth }, by: { $0.folders[depth] })
        let subs = nested.map { child, group in
            folder(id: id.isEmpty ? child : id + "/" + child, name: child, files: group, depth: depth + 1)
        }
        return LibraryFolder(
            id: id, name: name,
            folders: subs.sorted { a, b in a.isArchive != b.isArchive ? !a.isArchive : natural(a.name, b.name) },
            files: direct.sorted { natural($0.name, $1.name) })
    }

    private static func natural(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }

    /// Identifiants de tous les dossiers (pour « Tout déplier »).
    static func folderIDs(_ folder: LibraryFolder) -> [String] {
        folder.folders.flatMap { [$0.id] + folderIDs($0) }
    }

    // MARK: Liste affichée

    /// Lignes à afficher. Avec une recherche, on garde les fichiers et dossiers qui correspondent (un dossier qui
    /// correspond garde tout son contenu) et tout est déplié ; sans recherche, seuls les dossiers de `expanded` le sont.
    static func rows(root: LibraryFolder, expanded: Set<String>, query: String) -> [LibraryRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tree = q.isEmpty ? root : (filter(root, query: q) ?? .empty)
        var out: [LibraryRow] = []
        func walk(_ folder: LibraryFolder, depth: Int) {
            for sub in folder.folders {
                let open = !q.isEmpty || expanded.contains(sub.id)
                out.append(LibraryRow(id: "d:" + sub.id, depth: depth, content: .folder(sub, expanded: open)))
                if open { walk(sub, depth: depth + 1) }
            }
            for file in folder.files {
                out.append(LibraryRow(id: "f:" + file.relativePath, depth: depth, content: .file(file)))
            }
        }
        walk(tree, depth: 0)
        return out
    }

    private static func filter(_ folder: LibraryFolder, query: String) -> LibraryFolder? {
        if !folder.id.isEmpty, folder.displayName.localizedStandardContains(query) { return folder }
        var kept = folder
        kept.files = folder.files.filter { $0.name.localizedStandardContains(query) }
        kept.folders = folder.folders.compactMap { filter($0, query: query) }
        if folder.id.isEmpty { return kept }
        return kept.files.isEmpty && kept.folders.isEmpty ? nil : kept
    }
}
