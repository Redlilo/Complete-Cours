import Foundation
import CryptoKit
import PDFKit

// « Supprimer les doublons » : lit tous les PDF de cours et compare.
//  1. identiques : mêmes octets (empreinte SHA-256) ;
//  2. très semblables : même texte à quelques mots près (le texte de TOUTES les pages est lu et comparé).
// Les évaluations ne sont jamais lues ni comparées. Une version vide et sa version complétée ne sont pas des doublons.
// Ce module ne supprime rien : il propose des groupes, l'écran met à la Corbeille ce que l'élève valide.

struct DuplicateCandidate: Identifiable, Hashable {
    let url: URL
    let relativePath: String
    let size: Int64
    let modified: Date
    let pages: Int
    let inArchive: Bool
    var id: URL { url }
}

struct DuplicateGroup: Identifiable {
    enum Kind: Equatable {
        case identiques
        case tresSemblables(percent: Int)
    }
    let id = UUID()
    let kind: Kind
    var files: [DuplicateCandidate]
    /// Le fichier conseillé à garder : jamais celui du dossier des originaux, sans « (2) » ni « copie » dans le nom, le plus ancien.
    var keep: URL
}

enum DuplicateFinder {
    static let similarityThreshold = 0.90
    static let minimumWords = 120

    typealias Progress = (Double, String) -> Void

    // MARK: Recherche

    static func find(files: [LibraryFile], root: URL, completions: [CompletionRecord] = [],
                     isCancelled: () -> Bool = { false }, progress: Progress = { _, _ in }) -> [DuplicateGroup] {
        let pool = files.filter { !$0.isEvaluation && $0.url.pathExtension.lowercased() == "pdf" }
        var candidates: [DuplicateCandidate] = []
        for f in pool {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.url.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { continue }
            candidates.append(DuplicateCandidate(url: f.url, relativePath: f.relativePath, size: size,
                                                 modified: (attrs[.modificationDate] as? Date) ?? .distantPast,
                                                 pages: 0, inArchive: f.folders.first?.hasPrefix("_") == true))
        }
        var groups: [DuplicateGroup] = []

        // 1. identiques : on ne calcule l'empreinte que des fichiers de même taille
        progress(0, "Comparaison des fichiers…")
        var identicalMembers = Set<URL>()
        let bySize = Dictionary(grouping: candidates, by: \.size).filter { $0.value.count > 1 && $0.key > 0 }
        for (i, (_, same)) in bySize.enumerated() {
            if isCancelled() { return [] }
            progress(0.3 * Double(i) / Double(max(bySize.count, 1)), "Comparaison des fichiers…")
            let byHash = Dictionary(grouping: same) { sha256($0.url) }.filter { $0.key != nil && $0.value.count > 1 }
            for (_, dup) in byHash {
                let withPages = dup.map { withPageCount($0) }
                groups.append(DuplicateGroup(kind: .identiques, files: withPages, keep: suggestedKeep(withPages).url))
                dup.forEach { identicalMembers.insert($0.url) }
            }
        }

        // 2. très semblables : texte de toutes les pages, un seul représentant par groupe d'identiques
        var fingerprints: [(DuplicateCandidate, Set<Int>, Int)] = []
        let rest = candidates.filter { !identicalMembers.contains($0.url) }
        for (i, c) in rest.enumerated() {
            if isCancelled() { return [] }
            progress(0.3 + 0.6 * Double(i) / Double(max(rest.count, 1)), "Lecture de « \(c.url.deletingPathExtension().lastPathComponent) »")
            if let fp = fingerprint(c.url) { fingerprints.append((withPageCount(c, pages: fp.pages), fp.shingles, fp.words)) }
        }
        progress(0.92, "Comparaison du texte…")
        var parent = Array(fingerprints.indices)
        func root(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        var bestSimilarity: [Int: Double] = [:]
        for a in fingerprints.indices {
            for b in fingerprints.indices where b > a {
                let (ca, sa, wa) = fingerprints[a], (cb, sb, wb) = fingerprints[b]
                guard ca.pages == cb.pages, Double(min(wa, wb)) >= 0.7 * Double(max(wa, wb)) else { continue }
                if intendedPair(ca, cb, completions: completions) { continue }
                let sim = jaccard(sa, sb)
                if sim >= similarityThreshold {
                    parent[root(a)] = root(b)
                    let r = root(b)
                    bestSimilarity[r] = min(bestSimilarity[r] ?? 1, sim)
                }
            }
        }
        var clusters: [Int: [Int]] = [:]
        for i in fingerprints.indices { clusters[root(i), default: []].append(i) }
        for (r, members) in clusters where members.count > 1 {
            let files = members.map { fingerprints[$0].0 }
            let percent = Int(((bestSimilarity[r] ?? similarityThreshold) * 100).rounded(.down))
            groups.append(DuplicateGroup(kind: .tresSemblables(percent: percent), files: files, keep: suggestedKeep(files).url))
        }
        progress(1, "Terminé")
        return groups.sorted { $0.files[0].relativePath.localizedStandardCompare($1.files[0].relativePath) == .orderedAscending }
    }

    // MARK: Éléments

    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { try? handle.read(upToCount: 1 << 20) }
            guard let data = chunk, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func withPageCount(_ c: DuplicateCandidate, pages: Int? = nil) -> DuplicateCandidate {
        let n = pages ?? PDFDocument(url: c.url)?.pageCount ?? 0
        return DuplicateCandidate(url: c.url, relativePath: c.relativePath, size: c.size, modified: c.modified, pages: n, inArchive: c.inArchive)
    }

    /// Mots du texte de toutes les pages, sans accents ni ponctuation ; empreinte par suites de 4 mots.
    static func fingerprint(_ url: URL) -> (shingles: Set<Int>, words: Int, pages: Int)? {
        guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else { return nil }
        var words: [String] = []
        for i in 0..<doc.pageCount {
            autoreleasepool {
                let text = doc.page(at: i)?.string ?? ""
                words += tokens(text)
            }
        }
        guard words.count >= minimumWords else { return nil }
        var set = Set<Int>()
        for i in 0...(words.count - 4) {
            var h = Hasher()
            h.combine(words[i]); h.combine(words[i + 1]); h.combine(words[i + 2]); h.combine(words[i + 3])
            set.insert(h.finalize())
        }
        return (set, words.count, doc.pageCount)
    }

    static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func jaccard(_ a: Set<Int>, _ b: Set<Int>) -> Double {
        let inter = a.intersection(b).count
        let union = a.count + b.count - inter
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    /// Une version vide et sa version complétée (par le nom, le dossier des originaux ou le journal) ne sont pas des doublons.
    static func intendedPair(_ a: DuplicateCandidate, _ b: DuplicateCandidate, completions: [CompletionRecord]) -> Bool {
        func stem(_ c: DuplicateCandidate) -> String { OriginalsArchive.normalized(c.url.deletingPathExtension().lastPathComponent) }
        if let base = OriginalsArchive.completedBase(a.url.deletingPathExtension().lastPathComponent), base == stem(b) { return true }
        if let base = OriginalsArchive.completedBase(b.url.deletingPathExtension().lastPathComponent), base == stem(a) { return true }
        for r in completions {
            let o = r.original, c = r.copy
            if (a.url.standardizedFileURL.path == o && b.url.standardizedFileURL.path == c) ||
               (b.url.standardizedFileURL.path == o && a.url.standardizedFileURL.path == c) { return true }
        }
        return false
    }

    /// Le fichier conseillé : hors dossier des originaux, sans suffixe « (2) » / « copie », le plus ancien.
    static func suggestedKeep(_ files: [DuplicateCandidate]) -> DuplicateCandidate {
        func looksLikeCopy(_ c: DuplicateCandidate) -> Bool {
            let n = OriginalsArchive.normalized(c.url.deletingPathExtension().lastPathComponent)
            return n.range(of: "\\(\\d+\\)$|\\bcopie\\b|\\bcopy\\b", options: .regularExpression) != nil
        }
        return files.sorted { a, b in
            if a.inArchive != b.inArchive { return !a.inArchive }
            if looksLikeCopy(a) != looksLikeCopy(b) { return !looksLikeCopy(a) }
            if a.modified != b.modified { return a.modified < b.modified }
            return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
        }[0]
    }

    // MARK: Corbeille

    /// Met à la Corbeille (récupérable avec « Remettre » dans le Finder) ; jamais de suppression définitive.
    /// Refuse de toucher un fichier qui a changé depuis l'analyse, et ne retire jamais le fichier gardé.
    static func trash(_ group: DuplicateGroup, removing urls: Set<URL>) -> (trashed: [URL], refused: [String]) {
        var trashed: [URL] = [], refused: [String] = []
        let fm = FileManager.default
        guard fm.fileExists(atPath: group.keep.path) else { return ([], ["Le fichier à garder n'existe plus : rien n'a été retiré."]) }
        for c in group.files where urls.contains(c.url) {
            guard c.url != group.keep else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: c.url.path),
                  (attrs[.size] as? NSNumber)?.int64Value == c.size,
                  (attrs[.modificationDate] as? Date) == c.modified else {
                refused.append("« \(c.url.lastPathComponent) » a changé depuis l'analyse : laissé en place."); continue
            }
            do { try fm.trashItem(at: c.url, resultingItemURL: nil); trashed.append(c.url) }
            catch { refused.append("« \(c.url.lastPathComponent) » n'a pas pu être mis à la Corbeille : \(error.localizedDescription)") }
        }
        return (trashed, refused)
    }
}
