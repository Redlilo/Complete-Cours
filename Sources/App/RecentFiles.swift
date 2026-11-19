import AppKit

/// Documents récents : les chemins sont gardés dans les préférences de l'app (rien d'autre) et signalés
/// aussi au système, qui les propose dans le menu du Dock.
enum RecentFiles {
    static let maxCount = 8

    /// Fichiers récents qui existent encore, du plus récent au plus ancien.
    static func load(_ defaults: UserDefaults = .standard) -> [URL] {
        let paths = defaults.stringArray(forKey: Pref.recentFiles) ?? []
        return paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    @discardableResult
    static func note(_ url: URL, defaults: UserDefaults = .standard) -> [URL] {
        var paths = defaults.stringArray(forKey: Pref.recentFiles) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        defaults.set(Array(paths.prefix(maxCount)), forKey: Pref.recentFiles)
        // le système n'est prévenu que pour les vrais réglages de l'app (pas pour les essais)
        if defaults === UserDefaults.standard { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        return load(defaults)
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Pref.recentFiles)
        if defaults === UserDefaults.standard { NSDocumentController.shared.clearRecentDocuments(nil) }
    }
}
