import Foundation
import PDFKit

// « Ne garder que les versions complétées » : le PDF vide d'un cours déjà complété est rangé dans
// « _Originaux avant completion », avec la même arborescence que dans le dossier des cours.
// Rien n'est jamais supprimé ni écrasé ; chaque déplacement est inscrit au journal (annulable).

struct ArchivePlan: Identifiable, Equatable {
    let original: URL        // le PDF vide, à ranger
    let completed: URL       // la version complétée, qui reste en place
    let destination: URL     // où l'original ira
    var id: URL { original }
}

enum OriginalsArchive {
    static let folderName = "_Originaux avant completion"

    // MARK: Reconnaissance des paires

    static func normalized(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Si le nom (sans extension) est celui d'une version complétée (« X (complétée) », « X - rempli », « X_complete »,
    /// « X corrigé »…), renvoie le nom de base normalisé « x ».
    static func completedBase(_ name: String) -> String? {
        let n = normalized(name)
        let pattern = "^(.+?)\\s*[-–—(\\[]*\\s*(?:completee?|remplie?|corrigee?)\\s*\\d*\\s*[)\\]]?$"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
              let r = Range(m.range(at: 1), in: n) else { return nil }
        let base = n[r].trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? nil : base
    }

    /// Les originaux vides qui ont une version complétée à côté (même dossier, nom de base identique) ou une
    /// complétion inscrite au journal. Les évaluations et ce qui est déjà dans le dossier des originaux sont ignorés.
    static func plan(files: [LibraryFile], root: URL, completions: [CompletionRecord] = []) -> [ArchivePlan] {
        let pool = files.filter { $0.folders.first?.hasPrefix("_") != true }
        var out: [ArchivePlan] = []
        var seen = Set<URL>()
        func add(_ original: URL, _ completed: URL) {
            guard seen.insert(original.standardizedFileURL).inserted, original.standardizedFileURL != completed.standardizedFileURL,
                  let dest = destination(for: original, root: root) else { return }
            out.append(ArchivePlan(original: original, completed: completed, destination: dest))
        }
        let byFolder = Dictionary(grouping: pool, by: { $0.folders })
        for (_, group) in byFolder {
            for c in group {
                guard let base = completedBase(c.name) else { continue }
                for o in group where o.url != c.url && !o.isEvaluation && o.state == .vierge && normalized(o.name) == base {
                    add(o.url, c.url)
                }
            }
        }
        let fm = FileManager.default
        for rec in completions {
            let o = rec.original, c = rec.copy
            guard let file = pool.first(where: { $0.url.standardizedFileURL.path == o }), !file.isEvaluation,
                  fm.fileExists(atPath: c) else { continue }
            add(file.url, URL(fileURLWithPath: c))
        }
        return out.sorted { $0.original.path.localizedStandardCompare($1.original.path) == .orderedAscending }
    }

    /// Emplacement dans le dossier des originaux (même sous-dossiers), sans jamais viser un fichier qui existe déjà.
    static func destination(for original: URL, root: URL) -> URL? {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = original.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else { return nil }
        let rel = Array(parts.dropFirst(rootParts.count))
        guard rel.first?.hasPrefix("_") != true else { return nil }
        let dir = rel.dropLast().reduce(root.appendingPathComponent(folderName)) { $0.appendingPathComponent($1) }
        let base = original.deletingPathExtension().lastPathComponent, ext = original.pathExtension
        var target = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext); n += 1
        }
        return target
    }

    /// Garde-fou avant de ranger : la version complétée s'ouvre et a au moins autant de pages que l'original
    /// (on ne range jamais l'original d'une copie abîmée ou tronquée).
    static func completedLooksSound(_ plan: ArchivePlan) -> Bool {
        guard let done = PDFDocument(url: plan.completed), !done.isLocked, done.pageCount > 0 else { return false }
        guard let orig = PDFDocument(url: plan.original) else { return true }
        return done.pageCount >= orig.pageCount
    }

    // MARK: Déplacement

    enum ArchiveError: LocalizedError {
        case originalMissing(String), completedMissing(String)
        var errorDescription: String? {
            switch self {
            case .originalMissing(let n): return "« \(n) » n'existe plus : rien n'a été rangé."
            case .completedMissing(let n): return "La version complétée « \(n) » a disparu : l'original reste où il est."
            }
        }
    }

    /// Range un original vide. Refuse si la version complétée n'existe plus (on ne retire jamais la seule copie utile).
    @discardableResult
    static func archive(_ plan: ArchivePlan, ledger: CourseLedger) throws -> MoveRecord {
        let fm = FileManager.default
        guard fm.fileExists(atPath: plan.original.path) else { throw ArchiveError.originalMissing(plan.original.lastPathComponent) }
        guard fm.fileExists(atPath: plan.completed.path) else { throw ArchiveError.completedMissing(plan.completed.lastPathComponent) }
        var dest = plan.destination
        var n = 2
        let base = dest.deletingPathExtension().lastPathComponent
        while fm.fileExists(atPath: dest.path) {
            dest = dest.deletingLastPathComponent().appendingPathComponent("\(base) (\(n))").appendingPathExtension(plan.original.pathExtension); n += 1
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: plan.original, to: dest)
        return ledger.recordMove(from: plan.original, to: dest, origin: .originaux)
    }

    /// Après une complétion réussie : range l'original, ou renvoie nil si ce n'est pas possible.
    @discardableResult
    static func archiveAfterCompletion(original: URL, copy: URL, root: URL, ledger: CourseLedger) -> MoveRecord? {
        guard let dest = destination(for: original, root: root) else { return nil }
        return try? archive(ArchivePlan(original: original, completed: copy, destination: dest), ledger: ledger)
    }
}
