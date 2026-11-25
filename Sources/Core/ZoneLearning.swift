import Foundation
import CoreGraphics

// Mémoire locale des corrections de l'élève : zone ignorée, zone ajoutée à la main, type changé.
// Au chargement d'un cours, les zones de signature équivalente reçoivent la même correction.
// Vie privée : on ne garde que la forme du trou, un texte voisin tronqué (32 caractères, sans chiffres) et le nom du
// modèle de document sans numéro. Jamais de réponse, jamais de contenu au-delà de ça, jamais d'évaluation.

// MARK: - Signature

/// Empreinte d'une zone, indépendante du document : « source | largeur arrondie | texte voisin | modèle de document ».
struct ZoneSignature: Equatable, Codable {
    var source: String
    var widthBucket: Int
    var neighbor: String
    var model: String

    var key: String { "\(source)|\(widthBucket)|\(neighbor)|\(model)" }

    /// Il faut un texte voisin pour reconnaître une zone d'un document à l'autre.
    var isLearnable: Bool { neighbor.replacingOccurrences(of: "→", with: "").count >= 10 }

    /// Même zone à une largeur près (le scan et la mise en page bougent un peu d'un fichier à l'autre).
    func matches(_ other: ZoneSignature) -> Bool {
        source == other.source && model == other.model && neighbor == other.neighbor
            && abs(widthBucket - other.widthBucket) <= 1
    }

    static let widthStep: CGFloat = 10
    static let neighborLength = 32

    init(source: String, widthBucket: Int, neighbor: String, model: String) {
        self.source = source; self.widthBucket = widthBucket; self.neighbor = neighbor; self.model = model
    }

    init(zone z: Zone, documentName: String) {
        source = z.source.rawValue
        let w = z.rect.width / ZoneSignature.widthStep
        widthBucket = w.isFinite ? Int(max(-1e6, min(1e6, w)).rounded()) : 0      // Int(NaN) ou Int(1e300) planterait
        neighbor = ZoneSignature.neighborText(before: z.contextBefore, after: z.contextAfter)
        model = ZoneSignature.modelName(documentName)
    }

    /// Lettres seules (sans accents ni majuscules ni chiffres), espaces simples.
    static func letters(_ s: String) -> String {
        let f = ZoneKindRules.fold(s)
        let kept = f.unicodeScalars.map { CharacterSet.letters.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Les derniers caractères du texte avant la zone (la consigne) ; à défaut, le début du texte après.
    static func neighborText(before: String, after: String) -> String {
        let b = letters(before)
        if !b.isEmpty { return String(b.suffix(neighborLength)).trimmingCharacters(in: .whitespaces) }
        let a = letters(after)
        if a.isEmpty { return "" }
        return "→" + String(a.prefix(neighborLength)).trimmingCharacters(in: .whitespaces)
    }

    /// Nom du modèle de document : « Fiche TP 04 – Onduleur (complétée).pdf » → « fiche tp onduleur ».
    static func modelName(_ documentName: String) -> String {
        var n = (documentName as NSString).deletingPathExtension
        n = n.replacingOccurrences(of: "\\((?:[^)]*)\\)|\\[(?:[^\\]]*)\\]", with: " ", options: .regularExpression)
        n = n.replacingOccurrences(of: "[-_ ]+(?:rempli|complete|completee|corrige|corrigee)\\b", with: " ",
                                   options: [.regularExpression, .caseInsensitive])
        let l = letters(n)
        return String(l.prefix(40)).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Mémoire

final class ZoneLearning: @unchecked Sendable {
    /// Ce que l'élève a décidé pour ce genre de zone.
    enum Action: Equatable {
        case ignore
        case kind(ZoneKind)
        /// Vrai trou (zone ajoutée à la main, ou zone ignorée puis rétablie).
        case confirm

        var raw: String {
            switch self {
            case .ignore: return "ignore"
            case .kind(let k): return "kind:" + k.rawValue
            case .confirm: return "confirm"
            }
        }
        init?(raw: String) {
            if raw == "ignore" { self = .ignore }
            else if raw == "confirm" { self = .confirm }
            else if raw.hasPrefix("kind:"), let k = ZoneKind(rawValue: String(raw.dropFirst(5))), k != .ignorer, k != .schema { self = .kind(k) }
            else { return nil }
        }
    }

    struct Entry: Codable, Equatable {
        var signature: ZoneSignature
        var action: String
        var updated: Date
        var uses: Int
    }

    /// Correction appliquée à une zone au chargement d'un cours.
    struct Applied: Equatable {
        var zoneID: Int
        var action: Action
        /// Texte affiché dans la liste (« Ignorée comme d'habitude »).
        var trace: String
    }

    static let shared = ZoneLearning(directory: CourseLedger.defaultDirectory)
    static let fileName = "ZoneLearning.json"
    static let maxEntries = 400

    let fileURL: URL
    private let lock = NSLock()
    private var entries: [Entry] = []
    /// Le fichier existant était illisible : il a été mis de côté (« ….corrompu ») et la mémoire repart de zéro.
    private(set) var recoveredFromCorruption = false
    private var unreadable = false

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(ZoneLearning.fileName)
        load()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    var allEntries: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }

    /// Jamais de mémoire pour une évaluation (par le nom du document ou l'un des dossiers du chemin).
    static func isAllowed(documentName: String, path: [String] = []) -> Bool {
        if LibraryTree.looksLikeEvaluation(documentName) { return false }
        return !LibraryTree.isEvaluationPath(path)
    }

    // MARK: Enregistrer

    @discardableResult
    func record(_ action: Action, for z: Zone, documentName: String, path: [String] = []) -> Bool {
        guard ZoneLearning.isAllowed(documentName: documentName, path: path) else { return false }
        if case .kind(let k) = action, k == .schema { return false }      // jamais mémorisé : seul l'élève marque un schéma
        let sig = ZoneSignature(zone: z, documentName: documentName)
        guard sig.isLearnable else { return false }
        lock.lock()
        entries.removeAll { $0.signature.matches(sig) && $0.signature.widthBucket == sig.widthBucket }
        entries.append(Entry(signature: sig, action: action.raw, updated: Date(), uses: 0))
        if entries.count > ZoneLearning.maxEntries {
            entries.sort { $0.updated > $1.updated }
            entries = Array(entries.prefix(ZoneLearning.maxEntries))
        }
        lock.unlock()
        save()
        return true
    }

    func recordIgnored(_ z: Zone, documentName: String, path: [String] = []) {
        record(.ignore, for: z, documentName: documentName, path: path)
    }
    /// Zone ajoutée à la main, ou zone ignorée puis rétablie : c'est un vrai trou.
    func recordConfirmed(_ z: Zone, documentName: String, path: [String] = []) {
        record(.confirm, for: z, documentName: documentName, path: path)
    }
    func recordKind(_ kind: ZoneKind, for z: Zone, documentName: String, path: [String] = []) {
        // « schéma » n'est jamais mémorisé : seul l'élève marque une zone ainsi, zone par zone
        if kind == .schema { return }
        record(kind == .ignorer ? .ignore : .kind(kind), for: z, documentName: documentName, path: path)
    }

    /// Oublie tout (fichier effacé).
    func forgetAll() {
        lock.lock(); entries = []; lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Appliquer

    /// Cherche l'entrée qui correspond à une zone : largeur exacte d'abord, puis la plus récente.
    func lookup(_ z: Zone, documentName: String) -> Entry? {
        let sig = ZoneSignature(zone: z, documentName: documentName)
        guard sig.isLearnable else { return nil }
        lock.lock(); defer { lock.unlock() }
        let candidates = entries.filter { $0.signature.matches(sig) }
        return candidates.sorted {
            let e0 = $0.signature.widthBucket == sig.widthBucket, e1 = $1.signature.widthBucket == sig.widthBucket
            if e0 != e1 { return e0 }
            return $0.updated > $1.updated
        }.first
    }

    /// Applique la mémoire aux zones d'un document qui vient d'être analysé. Les zones dessinées à la main sont laissées.
    @discardableResult
    func apply(to zones: inout [Zone], documentName: String, path: [String] = []) -> [Applied] {
        guard ZoneLearning.isAllowed(documentName: documentName, path: path), count > 0 else { return [] }
        var out: [Applied] = []
        var used = Set<String>()
        for i in zones.indices where zones[i].source != .manuel {
            guard let e = lookup(zones[i], documentName: documentName), let action = Action(raw: e.action) else { continue }
            switch action {
            case .ignore:
                zones[i].kind = .ignorer
                zones[i].enabled = false
                zones[i].answer = ""
                zones[i].rawAnswer = ""
                out.append(Applied(zoneID: zones[i].id, action: action, trace: "Ignorée comme d'habitude"))
            case .kind(let k):
                zones[i].kind = k
                out.append(Applied(zoneID: zones[i].id, action: action, trace: "Type « \(k.label) » retenu comme d'habitude"))
            case .confirm:
                zones[i].confidence = max(zones[i].confidence, 0.9)
                zones[i].signals.append("tu as déjà gardé ce genre de zone")
                out.append(Applied(zoneID: zones[i].id, action: action, trace: "Gardée comme d'habitude"))
            }
            used.insert(e.signature.key)
        }
        if !used.isEmpty {
            lock.lock()
            for j in entries.indices where used.contains(entries[j].signature.key) { entries[j].uses += 1 }
            lock.unlock()
            save()
        }
        return out
    }

    // MARK: Fichier

    private struct FileContent: Codable {
        var version = 1
        var entries: [Entry]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            // fichier présent mais illisible : on ne l'écrase pas avec une mémoire vide
            if FileManager.default.fileExists(atPath: fileURL.path) { unreadable = true }
            return
        }
        // lecture tolérante : une entrée abîmée est sautée, un fichier illisible est mis de côté
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["entries"] as? [Any] else {
            quarantine()
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [Entry] = []
        for item in raw {
            guard JSONSerialization.isValidJSONObject(item),
                  let d = try? JSONSerialization.data(withJSONObject: item),
                  let e = try? decoder.decode(Entry.self, from: d),
                  Action(raw: e.action) != nil else { continue }
            loaded.append(e)
        }
        entries = Array(loaded.suffix(ZoneLearning.maxEntries))
    }

    private func quarantine() {
        recoveredFromCorruption = true
        let side = fileURL.appendingPathExtension("corrompu")
        try? FileManager.default.removeItem(at: side)
        try? FileManager.default.moveItem(at: fileURL, to: side)
    }

    private let saveLock = NSLock()

    private func save() {
        // une écriture à la fois, et la photo de la mémoire est prise DANS le verrou : la dernière écriture est la plus récente
        saveLock.lock(); defer { saveLock.unlock() }
        if unreadable { return }
        lock.lock()
        let snapshot = entries
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(FileContent(entries: snapshot)) else { return }
        try? PrivateFiles.write(data, to: fileURL)
    }
}
