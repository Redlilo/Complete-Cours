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

    /// Retire les entrées inutilisables (recto ou verso vide, question vide) et renumérote : ids uniques, à partir de 1.
    mutating func assainir() {
        func vide(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        cards = cards.filter { !vide($0.front) && !vide($0.back) }
        for i in cards.indices { cards[i].id = i + 1 }
        questions = questions.filter { q in
            guard !vide(q.question), !vide(q.expected) else { return false }
            return !(q.style == .qcm && q.choices.count < 2)
        }
        for i in questions.indices { questions[i].id = i + 1 }
        corrige = corrige.filter { !vide($0.instruction) || !vide($0.correctAnswer) }
        for i in corrige.indices { corrige[i].id = i + 1 }
        if let s = summary, s.keyPoints.isEmpty, s.vocabulary.isEmpty, s.formulas.isEmpty { summary = nil }
    }

    var estVide: Bool { summary == nil && questions.isEmpty && cards.isEmpty && corrige.isEmpty }
}

extension RevisionMemoire {
    /// Lecture tolérante : un champ absent (fichier d'une ancienne version) ne fait pas perdre le reste.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        summary = try? c.decodeIfPresent(RevisionSummary.self, forKey: .summary)
        questions = (try? c.decodeIfPresent([RevisionQuestion].self, forKey: .questions)) ?? []
        cards = (try? c.decodeIfPresent([RevisionCard].self, forKey: .cards)) ?? []
        corrige = (try? c.decodeIfPresent([CorrigeItem].self, forKey: .corrige)) ?? []
        tailleDuPDF = (try? c.decodeIfPresent(Int.self, forKey: .tailleDuPDF)) ?? 0
        dateDuPDF = try? c.decodeIfPresent(Date.self, forKey: .dateDuPDF)
    }
    private enum Keys: String, CodingKey { case summary, questions, cards, corrige, tailleDuPDF, dateDuPDF }
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
              var m = try? dec.decode(RevisionMemoire.self, from: data) else { return nil }
        m.assainir()
        guard !m.estVide else { return nil }
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
