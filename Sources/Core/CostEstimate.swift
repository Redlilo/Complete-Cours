import Foundation
import PDFKit

/// Estimation du coût d'un lot de complétion. Fonctions pures (testées par Tools/Tests/Cost) :
/// c'est une estimation d'ordre de grandeur, jamais une mesure.
enum CostEngine: Equatable {
    /// Claude par clé API : prix en dollars par million de jetons.
    case claudeAPI(label: String, inputPerMillion: Double, outputPerMillion: Double)
    /// Claude (mon compte) : pas de prix par page ; `equivalent` donne le coût API équivalent s'il est connu.
    case claudeAccount(label: String, inputPerMillion: Double?, outputPerMillion: Double?)
    case apple
    case unknown
}

/// Un cours du lot : chemin relatif (ou nom) et nombre de pages (nil = illisible).
struct CostItem: Equatable {
    var path: String
    var pages: Int?
    var isEvaluation: Bool = false
}

struct CostEstimate: Equatable {
    var engine: CostEngine
    var courses: Int
    var pages: Int
    /// Évaluations écartées (jamais comptées, jamais complétées).
    var skippedEvaluations: Int
    /// PDF dont on n'a pas pu compter les pages (comptés pour 1 page dans l'estimation basse, 0 pour le total affiché).
    var unreadable: Int
    var lowUSD: Double?
    var highUSD: Double?
    var lowSeconds: Double?
    var highSeconds: Double?

    // Hypothèses par page (recalées sur l'ordre de grandeur historique : 4 ¢ en Opus 5.5, 2 ¢ Sonnet, 0,1 ¢ Haiku).
    static let inputTokensLow = 1600 + 1500, outputTokensLow = 400          // cas favorable : image + texte, peu de sortie
    static let inputTokensHigh = 3000, outputTokensHigh = 1500              // cas chargé : réflexion comprise
    static let secondsPerPageLow = 10.0, secondsPerPageHigh = 20.0
    /// Taux indicatif dollar → euro, affiché comme tel (« environ »).
    static let euroPerDollar = 0.92

    static func isEvaluationPath(_ path: String) -> Bool {
        LibraryTree.isEvaluationPath(path.split(separator: "/").map(String.init))
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    static func compute(items: [CostItem], engine: CostEngine) -> CostEstimate {
        let kept = items.filter { !$0.isEvaluation && !isEvaluationPath($0.path) }
        let pages = kept.reduce(0) { $0 + max($1.pages ?? 0, 0) }
        var est = CostEstimate(engine: engine, courses: kept.count, pages: pages,
                               skippedEvaluations: items.count - kept.count,
                               unreadable: kept.filter { $0.pages == nil }.count)
        guard pages > 0 else { return est }
        let p = Double(pages)
        func usd(_ inPrice: Double, _ outPrice: Double) {
            est.lowUSD = p * (Double(inputTokensLow) * inPrice + Double(outputTokensLow) * outPrice) / 1_000_000
            est.highUSD = p * (Double(inputTokensHigh) * inPrice + Double(outputTokensHigh) * outPrice) / 1_000_000
        }
        switch engine {
        case .claudeAPI(_, let i, let o): usd(i, o)
        case .claudeAccount(_, let i, let o):
            if let i, let o { usd(i, o) }
            est.lowSeconds = p * secondsPerPageLow; est.highSeconds = p * secondsPerPageHigh
        case .apple, .unknown: break
        }
        return est
    }

    // MARK: Texte

    static func dollars(_ v: Double) -> String {
        if v < 0.01 { return "moins de 0,01 $" }
        return String(format: v < 1 ? "%.2f $" : "%.1f $", v).replacingOccurrences(of: ".", with: ",")
    }

    static func euros(_ v: Double) -> String {
        let e = v * euroPerDollar
        if e < 0.01 { return "moins de 0,01 €" }
        return String(format: e < 1 ? "%.2f €" : "%.1f €", e).replacingOccurrences(of: ".", with: ",")
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 90 { return "\(s) s" }
        let m = Int((Double(s) / 60).rounded())
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h \(String(format: "%02d", m % 60))"
    }

    /// Fourchette « de X à Y » (en dollars, avec l'équivalent en euros).
    var priceRange: String? {
        guard let lo = lowUSD, let hi = highUSD else { return nil }
        return "de \(Self.dollars(lo)) à \(Self.dollars(hi)) (environ \(Self.euros(lo)) à \(Self.euros(hi)))"
    }

    var durationRange: String? {
        guard let lo = lowSeconds, let hi = highSeconds else { return nil }
        return "de \(Self.duration(lo)) à \(Self.duration(hi))"
    }

    /// Lignes du récapitulatif, en français, prêtes à afficher.
    var lines: [String] {
        var out = ["\(courses) cours, \(pages) \(pages > 1 ? "pages" : "page") au total."]
        if pages == 0 {
            out.append(courses == 0 ? "Rien à compléter dans cette sélection." : "Aucune page n'a pu être comptée : impossible d'estimer le coût.")
        } else {
            switch engine {
            case .claudeAPI(let label, _, _):
                out.append("Estimation avec \(label) : \(priceRange ?? "indisponible"), facturés sur ta clé API.")
            case .claudeAccount:
                out.append("Durée approximative : \(durationRange ?? "?") (environ 10 à 20 secondes par page).")
                out.append("Pas de facture par page : cela consomme ton forfait Claude." + (priceRange.map { " Équivalent en coût API : \($0)." } ?? ""))
            case .apple:
                out.append("Apple Intelligence : gratuit, mais plus lent et de qualité moindre que Claude.")
            case .unknown:
                out.append("Le coût de ce moteur n'est pas connu.")
            }
        }
        if unreadable > 0 { out.append("\(unreadable) PDF illisible(s) : leurs pages ne sont pas comptées.") }
        if skippedEvaluations > 0 { out.append("\(skippedEvaluations) évaluation(s) écartée(s) : elles ne sont jamais complétées ni lues.") }
        out.append("Ce sont des estimations, pas des mesures : le coût réel peut être différent.")
        return out
    }

    var summary: String { lines.joined(separator: "\n") }
}

/// Compte les pages d'un PDF, sauf pour une évaluation (le fichier n'est alors jamais ouvert).
enum PageCounter {
    static func pages(of url: URL, relativePath: String? = nil) -> Int? {
        if CostEstimate.isEvaluationPath(relativePath ?? url.lastPathComponent) || CostEstimate.isEvaluationPath(url.lastPathComponent) { return nil }
        return PDFDocument(url: url)?.pageCount
    }
}
