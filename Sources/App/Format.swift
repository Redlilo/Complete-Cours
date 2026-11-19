import Foundation

/// Petits utilitaires de rédaction française (accords, listes, guillemets) pour que les messages soient sans faute.
enum Fr {
    static func plural(_ n: Int, _ one: String, _ many: String) -> String { n > 1 ? many : one }

    static func zones(_ n: Int) -> String { "\(n) \(plural(n, "zone", "zones"))" }
    static func pages(_ n: Int) -> String { "\(n) \(plural(n, "page", "pages"))" }
    static func answers(_ n: Int) -> String { "\(n) \(plural(n, "réponse", "réponses"))" }

    /// « 2 », « 2 et 5 », « 2, 5 et 7 ».
    static func list(_ values: [Int]) -> String {
        let items = values.map(String.init)
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " et " + items[items.count - 1]
        }
    }

    /// Ajoute un point final si la phrase n'en a pas (les explications des moteurs n'en ont pas toujours).
    static func sentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return t }
        return ".!?…".contains(last) ? t : t + "."
    }

    /// « texte » avec les espaces insécables de la typographie française.
    static func quote(_ text: String) -> String { "«\u{00A0}\(text)\u{00A0}»" }

    /// « 12 zones trouvées sur 3 pages », « 1 zone trouvée sur 1 page ».
    static func foundSummary(zones: Int, pages: Int) -> String {
        if zones == 0 { return "Aucune zone à remplir n'a été trouvée" }
        return "\(self.zones(zones)) \(plural(zones, "trouvée", "trouvées")) sur \(self.pages(pages))"
    }

    /// Message pour une liste de pages (index à partir de 0) : « la page 3 », « les pages 2 et 5 ».
    static func pageList(_ indexes: [Int]) -> String {
        let numbers = indexes.sorted().map { $0 + 1 }
        return numbers.count > 1 ? "les pages \(list(numbers))" : "la page \(list(numbers))"
    }
}
