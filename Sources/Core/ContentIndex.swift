import Foundation
import PDFKit
import Vision

// Index de recherche dans le contenu des cours — 100 % local (aucun réseau, aucune IA).
//  - texte de chaque page (couche texte PDFKit) ; scan sans texte : OCR Vision des 4 premières pages seulement ;
//  - cache persistant (clé : chemin + taille + date de modification), écritures atomiques, fichier abîmé = index vide ;
//  - JAMAIS le contenu des évaluations : elles sont ignorées (et retirées du cache si elles y étaient).
// Testé par Tools/Tests/Index.

/// Un résultat : un cours, la page la plus pertinente et un court extrait.
struct ContentHit: Identifiable, Equatable {
    let url: URL
    /// Numéro de page affiché (1 pour la première).
    let page: Int
    let snippet: String
    /// Nombre total d'occurrences des mots cherchés dans le cours.
    let count: Int
    var id: URL { url }
}

final class ContentIndex: @unchecked Sendable {
    /// Nombre de pages lues par OCR pour un scan sans couche texte.
    static let ocrPageLimit = 4
    /// Un PDF dont tout le texte fait moins de caractères que ça est considéré comme un scan.
    static let scanThreshold = 20
    static let maxCharsPerPage = 20_000
    static let version = 1

    struct Entry: Codable, Equatable {
        var size: Int64
        var mtime: Double
        var pages: [String]
        var ocr: Bool
    }
    private struct Store: Codable { var version: Int; var entries: [String: Entry] }

    /// Emplacement par défaut : Application Support/Complete-Cours/ContentIndex.json
    static var defaultCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Complete-Cours", isDirectory: true).appendingPathComponent("ContentIndex.json")
    }

    static let shared = ContentIndex(cacheURL: defaultCacheURL)

    private let cacheURL: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var folded: [String: [String]] = [:]
    /// Lecture OCR d'une page (remplaçable dans les tests).
    nonisolated(unsafe) var ocrPage: (PDFPage) -> String = ContentIndex.visionOCR

    init(cacheURL: URL) {
        self.cacheURL = cacheURL
        load()
    }

    // MARK: Cache

    private func load() {
        guard let data = try? Data(contentsOf: cacheURL),
              let store = try? JSONDecoder().decode(Store.self, from: data),
              store.version == Self.version else { return }
        lock.lock(); defer { lock.unlock() }
        entries = store.entries
        folded = store.entries.mapValues { $0.pages.map(Self.fold) }
    }

    private func save() {
        lock.lock()
        let store = Store(version: Self.version, entries: entries)
        lock.unlock()
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    var documentCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    func entry(for url: URL) -> Entry? { lock.lock(); defer { lock.unlock() }; return entries[url.path] }

    // MARK: Mise à jour

    private static func key(of url: URL) -> (size: Int64, mtime: Double)? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = v.fileSize, let date = v.contentModificationDate else { return nil }
        return (Int64(size), date.timeIntervalSince1970)
    }

    /// Cours à (re)lire : nouveaux ou modifiés, évaluations exclues.
    func pending(_ files: [LibraryFile]) -> [LibraryFile] {
        lock.lock(); defer { lock.unlock() }
        return files.filter { f in
            guard !f.isEvaluation, let k = Self.key(of: f.url) else { return false }
            guard let e = entries[f.url.path] else { return true }
            return e.size != k.size || e.mtime != k.mtime
        }
    }

    /// Met l'index à jour (bloquant : à lancer hors du fil principal). `progress(fait, total)` compte les cours relus.
    func update(files: [LibraryFile], isCancelled: () -> Bool = { false }, progress: ((Int, Int) -> Void)? = nil) {
        let eligible = Set(files.filter { !$0.isEvaluation }.map { $0.url.path })
        var changed = false
        lock.lock()
        // retire ce qui a disparu (si la bibliothèque n'est pas vide) et toute évaluation
        if !files.isEmpty {
            for p in entries.keys where !eligible.contains(p) { entries[p] = nil; folded[p] = nil; changed = true }
        }
        lock.unlock()

        let todo = pending(files)
        let total = todo.count
        if total > 0 { progress?(0, total) }
        for (i, file) in todo.enumerated() {
            if isCancelled() { break }
            guard let k = Self.key(of: file.url) else { continue }
            let (pages, ocr) = readPages(file.url)
            let entry = Entry(size: k.size, mtime: k.mtime, pages: pages, ocr: ocr)
            lock.lock()
            entries[file.url.path] = entry
            folded[file.url.path] = pages.map(Self.fold)
            lock.unlock()
            changed = true
            progress?(i + 1, total)
            if (i + 1) % 20 == 0 { save() }
        }
        if changed { save() }
    }

    /// Texte de chaque page ; pour un scan, OCR des premières pages seulement.
    private func readPages(_ url: URL) -> ([String], Bool) {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return ([], false) }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            let raw = doc.page(at: i)?.string ?? ""
            pages.append(String(Self.normalize(raw).prefix(Self.maxCharsPerPage)))
        }
        // une évaluation au nom neutre se reconnaît à son en-tête : jamais indexée
        if LibraryTree.headerLooksLikeEvaluation(pages.first ?? "") { return ([], false) }
        let letters = pages.reduce(0) { $0 + $1.filter { !$0.isWhitespace }.count }
        guard letters < Self.scanThreshold, doc.pageCount > 0 else { return (pages, false) }
        for i in 0..<min(Self.ocrPageLimit, doc.pageCount) {
            autoreleasepool {   // l'OCR de nombreux scans ne doit pas faire monter la mémoire
                if let page = doc.page(at: i) { pages[i] = String(Self.normalize(ocrPage(page)).prefix(Self.maxCharsPerPage)) }
            }
        }
        return (pages, true)
    }

    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    static func visionOCR(_ page: PDFPage) -> String {
        guard let (image, _) = PageImaging.render(page: page, longEdge: 1800) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR"]
        request.usesLanguageCorrection = true
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return "" }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    // MARK: Recherche

    /// Mots de la requête, sans accents ni casse.
    static func terms(_ query: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for w in fold(query).split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            let s = String(w)
            if seen.insert(s).inserted { out.append(s) }
        }
        return out
    }

    /// Nombre d'occurrences de `term` au début d'un mot (« ph » trouve « pH » et « phosphore », pas « graphique »).
    static func occurrences(of term: String, in text: String) -> Int {
        guard !term.isEmpty else { return 0 }
        var count = 0
        var from = text.startIndex
        while let r = text.range(of: term, options: .literal, range: from..<text.endIndex) {
            if r.lowerBound == text.startIndex || !(text[text.index(before: r.lowerBound)].isLetter || text[text.index(before: r.lowerBound)].isNumber) {
                count += 1
            }
            from = r.upperBound
        }
        return count
    }

    /// Cours contenant TOUS les mots, classés par nombre d'occurrences (puis par nom).
    func search(_ query: String, limit: Int = 50) -> [ContentHit] {
        let terms = Self.terms(query)
        guard !terms.isEmpty else { return [] }
        lock.lock()
        let snapshot = folded
        let originals = entries
        lock.unlock()

        var hits: [(hit: ContentHit, name: String)] = []
        for (path, pages) in snapshot {
            var total = 0
            var perTerm = [Int](repeating: 0, count: terms.count)
            var best = (page: -1, distinct: 0, count: 0)
            for (pi, text) in pages.enumerated() where !text.isEmpty {
                var distinct = 0, sum = 0
                for (ti, t) in terms.enumerated() {
                    let c = Self.occurrences(of: t, in: text)
                    if c > 0 { distinct += 1; sum += c; perTerm[ti] += c }
                }
                total += sum
                if distinct > best.distinct || (distinct == best.distinct && sum > best.count) { best = (pi, distinct, sum) }
            }
            guard best.page >= 0, !perTerm.contains(0), let entry = originals[path] else { continue }
            let url = URL(fileURLWithPath: path)
            let snippet = Self.snippet(entry.pages[best.page], terms: terms)
            hits.append((ContentHit(url: url, page: best.page + 1, snippet: snippet, count: total), url.lastPathComponent))
        }
        hits.sort { a, b in
            a.hit.count != b.hit.count ? a.hit.count > b.hit.count
                : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return Array(hits.prefix(limit).map(\.hit))
    }

    /// Court extrait autour du premier mot trouvé.
    static func snippet(_ text: String, terms: [String], radius: Int = 60) -> String {
        var found: Range<String.Index>?
        for t in terms {
            var from = text.startIndex
            while let r = text.range(of: t, options: [.diacriticInsensitive, .caseInsensitive], range: from..<text.endIndex) {
                if r.lowerBound == text.startIndex || !(text[text.index(before: r.lowerBound)].isLetter || text[text.index(before: r.lowerBound)].isNumber) {
                    if found == nil || r.lowerBound < found!.lowerBound { found = r }
                    break
                }
                from = r.upperBound
            }
        }
        guard let hit = found else { return String(text.prefix(radius * 2)) }
        var lo = text.index(hit.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        var hi = text.index(hit.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        // ne pas couper un mot
        while lo > text.startIndex, lo < hit.lowerBound, !text[lo].isWhitespace { lo = text.index(after: lo) }
        while hi < text.endIndex, hi > hit.upperBound, !text[hi].isWhitespace { hi = text.index(before: hi) }
        var s = String(text[lo..<hi]).trimmingCharacters(in: .whitespaces)
        if lo > text.startIndex { s = "… " + s }
        if hi < text.endIndex { s += " …" }
        return s
    }

    /// Positions des mots cherchés dans un extrait (pour les mettre en gras).
    static func highlightRanges(in snippet: String, terms: [String]) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for t in terms {
            var from = snippet.startIndex
            while let r = snippet.range(of: t, options: [.diacriticInsensitive, .caseInsensitive], range: from..<snippet.endIndex) {
                if r.lowerBound == snippet.startIndex || !(snippet[snippet.index(before: r.lowerBound)].isLetter || snippet[snippet.index(before: r.lowerBound)].isNumber) {
                    out.append(r)
                }
                from = r.upperBound
            }
        }
        return out
    }
}
