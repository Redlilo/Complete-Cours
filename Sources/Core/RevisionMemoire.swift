import Foundation
import CryptoKit

/// Ce que l'IA a déjà produit pour un PDF (fiche, questions, cartes, corrigé) : repris quand on rouvre ce PDF,
/// sans nouvel appel à l'IA. Rien d'autre n'est gardé (ni les réponses de l'élève, ni le texte du cours).
struct RevisionMemoire: Codable, Equatable {
    var summary: RevisionSummary?
    var questions: [RevisionQuestion] = []
    var cards: [RevisionCard] = []
    var corrige: [CorrigeItem] = []
    /// Taille et date du PDF au moment de l'enregistrement : si le fichier a changé, la mémoire ne vaut plus.
    var tailleDuPDF: Int = 0
    var dateDuPDF: Date?

    var estVide: Bool { summary == nil && questions.isEmpty && cards.isEmpty && corrige.isEmpty }
}

/// Un petit fichier JSON par PDF, dans Application Support (nom = empreinte du chemin, jamais le nom du cours).
final class RevisionMemoireStore: @unchecked Sendable {
    let dossier: URL

    init(dossier: URL? = nil) {
        if let dossier { self.dossier = dossier } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.dossier = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Complete-Cours", isDirectory: true)
                .appendingPathComponent("Revision", isDirectory: true)
        }
    }

    private func fichier(pour pdf: URL) -> URL {
        let chemin = pdf.standardizedFileURL.resolvingSymlinksInPath().path
        let empreinte = SHA256.hash(data: Data(chemin.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return dossier.appendingPathComponent("\(empreinte).json")
    }

    private static func signature(_ pdf: URL) -> (taille: Int, date: Date?) {
        let v = try? pdf.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (v?.fileSize ?? 0, v?.contentModificationDate)
    }

    /// La mémoire de ce PDF, si elle existe et que le fichier n'a pas changé depuis.
    func charger(_ pdf: URL) -> RevisionMemoire? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fichier(pour: pdf)),
              let m = try? dec.decode(RevisionMemoire.self, from: data), !m.estVide else { return nil }
        let s = Self.signature(pdf)
        guard m.tailleDuPDF == s.taille,
              abs((m.dateDuPDF ?? .distantPast).timeIntervalSince(s.date ?? .distantPast)) < 1 else { return nil }
        return m
    }

    func sauver(_ memoire: RevisionMemoire, pour pdf: URL) {
        var m = memoire
        let s = Self.signature(pdf)
        m.tailleDuPDF = s.taille; m.dateDuPDF = s.date
        let url = fichier(pour: pdf)
        if m.estVide { try? FileManager.default.removeItem(at: url); return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        if let data = try? enc.encode(m) { try? data.write(to: url, options: .atomic) }
    }
}
