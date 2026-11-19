import Foundation
import Combine

/// « Reprendre où tu étais » : les derniers cours ouverts (sélectionnés, complétés, fiche, correction).
/// Mémorisés par chemin dans UserDefaults ; les fichiers disparus sont ignorés. Les évaluations y figurent aussi
/// (ce sont des cours ouverts) mais leur contenu n'est jamais lu ici.
@MainActor
final class Recents: ObservableObject {
    static let shared = Recents()
    nonisolated static let key = "recentCourses"
    static let shownLimit = 6
    private static let storedLimit = 20

    @Published private(set) var paths: [String]
    private let defaults: UserDefaults
    private let storeKey: String

    init(defaults: UserDefaults = .standard, key: String = Recents.key) {
        self.defaults = defaults
        self.storeKey = key
        paths = defaults.stringArray(forKey: key) ?? []
    }

    func touch(_ url: URL) {
        let p = url.standardizedFileURL.path
        var list = paths.filter { $0 != p }
        list.insert(p, at: 0)
        paths = Array(list.prefix(Self.storedLimit))
        defaults.set(paths, forKey: storeKey)
    }

    func clear() {
        paths = []
        defaults.removeObject(forKey: storeKey)
    }

    /// Les cours à afficher : 6 au plus, sans les fichiers disparus.
    func visible(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [URL] {
        paths.filter(exists).prefix(Self.shownLimit).map { URL(fileURLWithPath: $0) }
    }
}
