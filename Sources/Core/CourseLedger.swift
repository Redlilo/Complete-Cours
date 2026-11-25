import Foundation
import CryptoKit

// Journal persistant de l'app (un fichier JSON dans Application Support) :
//   1. chaque rangement (de, vers, date, origine) → permet d'annuler, même après un redémarrage ;
//   2. chaque complétion faite par l'app (original, copie « (complétée) », date, moteur) ;
//   3. le cache de l'analyse : résumé de chaque cours (clé = chemin + taille + date de modification)
//      et réponses de l'IA déjà obtenues (clé = empreinte de la demande).
// Le dossier est injectable pour les tests. Les écritures sont atomiques ; un fichier absent ou abîmé
// donne un journal vide (le fichier abîmé est mis de côté en « .corrompu », jamais supprimé).
// Aucun contenu de cours n'est gardé, hormis les 450 premiers caractères déjà envoyés à l'IA pour l'analyse.

struct MoveRecord: Codable, Identifiable, Equatable {
    enum Origin: String, Codable { case analyse, depot, originaux }
    var id: UUID
    var from: String            // chemin absolu d'origine
    var to: String              // chemin absolu où le fichier a été rangé
    var date: Date
    var origin: Origin

    var fromURL: URL { URL(fileURLWithPath: from) }
    var toURL: URL { URL(fileURLWithPath: to) }
}

struct CompletionRecord: Codable, Equatable {
    var original: String        // chemin absolu du cours d'origine
    var copy: String            // chemin absolu de la copie « (complétée) »
    var date: Date
    var engine: String
}

enum UndoOutcome: Equatable {
    case restored(URL)
    case refused(String)        // raison, en français ; rien n'a été touché
}

/// Données de l'app sur le disque : dossier lisible par l'utilisateur seul (0700), fichiers en 0600.
enum PrivateFiles {
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default, dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

final class CourseLedger: @unchecked Sendable {
    static let shared = CourseLedger(directory: CourseLedger.defaultDirectory)

    /// Application Support/<identifiant de l'app>/ (la variante personnelle et la version distribuée ont chacune le leur).
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "fr.complete-cours.app", isDirectory: true)
    }

    // MARK: Contenu du fichier

    struct DigestEntry: Codable {
        var size: Int64
        var mtime: Double
        var version: Int
        var isEvaluation: Bool
        var excerpt: String
        var zones: Int
        var remaining: Int
        var isIncomplete: Bool
        // ajoutés ensuite : optionnels pour relire les anciens journaux (état déduit à la lecture)
        var state: String?
        var usedBlank: Bool?
        var blank: String?          // original vide utilisé (chemin absolu)
        var blankMtime: Double?
    }

    struct AIEntry: Codable { var key: String; var json: String; var date: Date }

    private struct Store: Codable {
        var version = 1
        var moves: [MoveRecord] = []
        var completions: [CompletionRecord] = []
        var digests: [String: DigestEntry] = [:]     // clé : chemin absolu
        var ai: [AIEntry] = []
    }

    /// À augmenter quand la lecture d'un cours change (les anciens résumés sont alors relus).
    static let digestVersion = 1
    static let maxMoves = 300
    static let maxAI = 60

    let fileURL: URL
    private let lock = NSLock()
    private var store = Store()
    /// Écriture impossible (disque en lecture seule…) : le journal reste en mémoire.
    private(set) var lastSaveError: String?
    private(set) var wasCorrupt = false

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("journal.json")
        load()
    }

    private var readOnly = false

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            // le fichier existe mais n'est pas lisible (droits…) : on ne l'écrase pas avec un journal vide
            if FileManager.default.fileExists(atPath: fileURL.path) { readOnly = true }
            return
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let s = try? decoder.decode(Store.self, from: data) { store = s; return }
        wasCorrupt = true
        let aside = fileURL.deletingLastPathComponent().appendingPathComponent("journal.json.corrompu")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: fileURL, to: aside)
    }

    /// À appeler avec le verrou pris.
    private func save() {
        if readOnly { lastSaveError = "Le journal existe mais n'est pas lisible : il n'est pas modifié."; return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        do {
            try PrivateFiles.write(try encoder.encode(store), to: fileURL)
            lastSaveError = nil
        } catch { lastSaveError = error.localizedDescription }
    }

    // MARK: Rangements

    /// Rangements pas encore annulés, du plus récent au plus ancien.
    var moves: [MoveRecord] { lock.lock(); defer { lock.unlock() }; return store.moves.reversed() }

    @discardableResult
    func recordMove(from: URL, to: URL, origin: MoveRecord.Origin, date: Date = Date()) -> MoveRecord {
        lock.lock(); defer { lock.unlock() }
        let r = MoveRecord(id: UUID(), from: from.standardizedFileURL.path, to: to.standardizedFileURL.path, date: date, origin: origin)
        store.moves.append(r)
        if store.moves.count > Self.maxMoves { store.moves.removeFirst(store.moves.count - Self.maxMoves) }
        relocate(from: r.from, to: r.to)
        save()
        return r
    }

    /// Un fichier a changé d'emplacement : les complétions et le cache de lecture le suivent.
    private func relocate(from: String, to: String) {
        for i in store.completions.indices {
            if store.completions[i].original == from { store.completions[i].original = to }
            if store.completions[i].copy == from { store.completions[i].copy = to }
        }
        if let d = store.digests.removeValue(forKey: from) { store.digests[to] = d }
    }

    /// Remet le fichier là où il était. Ne remplace jamais rien : refuse si l'emplacement d'origine est pris,
    /// si le fichier a disparu ou si le dossier d'origine n'existe plus.
    @discardableResult
    func undo(_ id: UUID) -> UndoOutcome {
        lock.lock(); defer { lock.unlock() }
        guard let i = store.moves.firstIndex(where: { $0.id == id }) else { return .refused("Ce rangement n'est plus dans l'historique.") }
        let r = store.moves[i]
        let fm = FileManager.default
        let name = r.fromURL.lastPathComponent
        guard fm.fileExists(atPath: r.to) else {
            return .refused("« \(r.toURL.lastPathComponent) » n'est plus là où il avait été rangé (déplacé ou supprimé).")
        }
        guard fm.fileExists(atPath: r.fromURL.deletingLastPathComponent().path) else {
            return .refused("Le dossier d'origine de « \(name) » n'existe plus.")
        }
        guard !fm.fileExists(atPath: r.from) else {
            return .refused("L'emplacement d'origine est déjà pris par un autre fichier « \(name) » : rien n'a été remplacé.")
        }
        do { try fm.moveItem(at: r.toURL, to: r.fromURL) }
        catch { return .refused("Impossible de remettre « \(name) » en place : \(error.localizedDescription)") }
        store.moves.remove(at: i)
        relocate(from: r.to, to: r.from)
        save()
        return .restored(r.fromURL)
    }

    /// Annule tout, du plus récent au plus ancien (un fichier rangé deux fois revient d'abord à sa position intermédiaire).
    func undoAll() -> [(MoveRecord, UndoOutcome)] {
        moves.map { ($0, undo($0.id)) }
    }

    /// Retire une ligne de l'historique sans toucher aux fichiers (utile quand elle ne peut plus être annulée).
    func forgetMove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        store.moves.removeAll { $0.id == id }
        save()
    }

    // MARK: Complétions

    var completions: [CompletionRecord] { lock.lock(); defer { lock.unlock() }; return store.completions }

    func recordCompletion(original: URL, copy: URL, engine: String, date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        store.completions.append(CompletionRecord(original: original.standardizedFileURL.path, copy: copy.standardizedFileURL.path,
                                                  date: date, engine: engine))
        save()
    }

    /// Cette copie a été fabriquée par l'app.
    func isAppCopy(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        return store.completions.contains { $0.copy == p }
    }

    /// Ce cours a déjà été complété par l'app (il s'agit de l'original) ou est une de ses copies.
    func isCompletedByApp(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        return store.completions.contains { $0.original == p || $0.copy == p }
    }

    // MARK: Cache de lecture

    private static func stamp(_ url: URL) -> (size: Int64, mtime: Double)? {
        // attributesOfItem : pas de valeurs gardées en mémoire par l'URL (resourceValues renverrait un ancien état)
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (a[.size] as? NSNumber)?.int64Value, let date = a[.modificationDate] as? Date else { return nil }
        return (size, date.timeIntervalSince1970)
    }

    /// Résumé gardé pour ce fichier, seulement s'il n'a changé ni de taille ni de date de modification, et s'il a été
    /// fait avec le même original vide (`blank`, nil : aucun) dans le même état.
    func cachedDigest(for url: URL, relativePath: String, blank: URL? = nil) -> CourseDigest? {
        lookup(url, relativePath: relativePath, checkBlank: true, blank: blank)
    }

    /// Comme `cachedDigest`, sans exiger que l'original vide soit celui du moment (pour les étiquettes de la
    /// bibliothèque : on montre ce que la dernière analyse a conclu).
    func cachedState(for url: URL, relativePath: String) -> CourseDigest? {
        lookup(url, relativePath: relativePath, checkBlank: false, blank: nil)
    }

    private func lookup(_ url: URL, relativePath: String, checkBlank: Bool, blank: URL?) -> CourseDigest? {
        guard let s = Self.stamp(url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let e = store.digests[url.standardizedFileURL.path], e.version == Self.digestVersion,
              e.size == s.size, abs(e.mtime - s.mtime) < 0.001 else { return nil }
        if checkBlank {
            guard e.blank == blank?.standardizedFileURL.path else { return nil }
            if let b = blank {
                guard let bs = Self.stamp(b), let m = e.blankMtime, abs(m - bs.mtime) < 0.001 else { return nil }
            }
        }
        return CourseDigest(path: relativePath, isEvaluation: e.isEvaluation, excerpt: e.excerpt,
                            zones: e.zones, remaining: e.remaining, isIncomplete: e.isIncomplete,
                            state: e.state.flatMap { CompletionState(rawValue: $0) },
                            usedBlank: e.usedBlank ?? false, blankPath: e.blank)
    }

    /// États gardés de plusieurs cours d'un coup (une seule prise du verrou).
    func cachedStates(for files: [LibraryFile]) -> [URL: CourseDigest] {
        var out: [URL: CourseDigest] = [:]
        for f in files where !f.isEvaluation {
            if let d = cachedState(for: f.url, relativePath: f.relativePath) { out[f.url] = d }
        }
        return out
    }

    /// Remplace tout le cache de lecture par ces résumés (les fichiers disparus en sortent).
    func replaceDigests(_ items: [(url: URL, digest: CourseDigest)]) {
        var map: [String: DigestEntry] = [:]
        for (url, d) in items {
            guard let s = Self.stamp(url) else { continue }
            let blankStamp = d.blankPath.flatMap { Self.stamp(URL(fileURLWithPath: $0)) }
            map[url.standardizedFileURL.path] = DigestEntry(size: s.size, mtime: s.mtime, version: Self.digestVersion,
                                                            isEvaluation: d.isEvaluation, excerpt: d.excerpt, zones: d.zones,
                                                            remaining: d.remaining, isIncomplete: d.isIncomplete,
                                                            state: d.state.rawValue, usedBlank: d.usedBlank,
                                                            blank: blankStamp == nil ? nil : d.blankPath, blankMtime: blankStamp?.mtime)
        }
        lock.lock(); defer { lock.unlock() }
        store.digests = map
        save()
    }

    func clearDigests() {
        lock.lock(); defer { lock.unlock() }
        store.digests = [:]; store.ai = []
        save()
    }

    var digestCount: Int { lock.lock(); defer { lock.unlock() }; return store.digests.count }

    // MARK: Cache des réponses de l'IA

    /// Empreinte d'une demande (texte système + texte envoyé : extraits et liste des dossiers).
    static func fingerprint(_ parts: String...) -> String {
        var h = SHA256()
        for p in parts { h.update(data: Data(p.utf8)); h.update(data: Data([0])) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func cachedAI(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store.ai.first { $0.key == key }?.json
    }

    func storeAI(_ key: String, json: String, date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        store.ai.removeAll { $0.key == key }
        store.ai.append(AIEntry(key: key, json: json, date: date))
        if store.ai.count > Self.maxAI { store.ai.removeFirst(store.ai.count - Self.maxAI) }
        save()
    }
}
