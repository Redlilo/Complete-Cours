import Foundation
import CoreGraphics
import PDFKit

/// Type de réponse attendue dans un trou.
/// Seuls `.definition` et `.question` sont humanisés : les mots à compléter restent exacts.
enum ZoneKind: String, Codable, CaseIterable, Identifiable {
    case mot
    case definition
    case question
    case ignorer
    /// Zone marquée par l'élève : un schéma électrique dessiné par Claude Opus 5.5 (jamais du texte, jamais deviné par l'IA).
    case schema

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mot: return "Mot à compléter"
        case .definition: return "Définition"
        case .question: return "Question ouverte"
        case .ignorer: return "Ignorer"
        case .schema: return "Schéma électrique"
        }
    }

    /// Pictogramme SF Symbols du type, s'il en a un.
    var symbolName: String? { self == .schema ? "bolt.horizontal" : nil }

    var isHumanizable: Bool { self == .question }
}

/// D'où vient la zone détectée.
enum ZoneSource: String {
    case formulaire   // champ de formulaire PDF
    case texte        // pointillés / underscores dans le texte du PDF
    case ligne        // ligne ou pointillé repéré dans l'image de la page
    case cadre        // cadre ou case de tableau vide repéré dans l'image
    case manuel       // dessiné à la main par l'utilisateur
}

/// Une ligne sur laquelle écrire (espace page PDF, origine en bas à gauche, en points).
/// `y` est la hauteur de la ligne à gauche (x0) ; `yEnd` à droite (x1) : elles diffèrent
/// quand le scan est légèrement penché, l'écriture doit alors suivre la pente.
struct WritingLine: Hashable {
    var x0: CGFloat
    var x1: CGFloat
    var y: CGFloat
    var yEnd: CGFloat

    init(x0: CGFloat, x1: CGFloat, y: CGFloat, yEnd: CGFloat? = nil) {
        self.x0 = x0; self.x1 = x1; self.y = y; self.yEnd = yEnd ?? y
    }

    var width: CGFloat { x1 - x0 }
    /// Pente (dy/dx) de la ligne ; 0 pour une ligne horizontale.
    var slope: CGFloat { width > 1 ? (yEnd - y) / width : 0 }
    func y(atX x: CGFloat) -> CGFloat { y + slope * (x - x0) }
}

struct Zone: Identifiable {
    var id: Int
    var page: Int                       // index de page (0 = première)
    var number: Int                     // numéro affiché sur la page (1...n)
    var source: ZoneSource
    var lines: [WritingLine] = []       // zones « lignes »
    var box: CGRect? = nil              // zones « cadre » ou champ de formulaire
    var widget: PDFAnnotation? = nil
    var contextBefore = ""
    var contextAfter = ""
    var kind: ZoneKind = .question
    var answer = ""
    var rawAnswer = ""                  // réponse avant humanisation
    var humanized = false
    var enabled = true
    var overflow = false                // le texte ne rentre pas entièrement
    var error: String? = nil            // message d'erreur propre à cette zone (affiché dans la liste)
    /// Schéma dessiné (seulement pour `kind == .schema`) : symboles normalisés placés sur une grille, rendus en vectoriel.
    var schema: SchemaElectrique? = nil
    var textHeight: CGFloat = 11        // corps du texte voisin (pour choisir la taille d'écriture)
    /// À quel point on est sûr que c'est un vrai trou à remplir (0 : douteux, 1 : sûr). Rempli par le détecteur.
    var confidence: Double = 1
    /// Raisons lisibles de la confiance (« pointillés dans le texte », « ligne dessinée en marge »…), pour l'affichage.
    var signals: [String] = []

    /// Rectangle englobant (espace page PDF).
    var rect: CGRect {
        if let box { return box }
        guard let first = lines.first else { return .zero }
        var r = CGRect(x: first.x0, y: first.y, width: first.width, height: 0)
        for l in lines.dropFirst() { r = r.union(CGRect(x: l.x0, y: l.y, width: l.width, height: 0)) }
        let h = max(textHeight, 10)
        return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height + h)
    }

    /// Nombre de caractères approximatif qui tiennent dans la zone à ~9 pt.
    var capacity: Int {
        let cw: CGFloat = 4.4
        if lines.isEmpty == false {
            return max(4, Int(lines.reduce(0) { $0 + max(0, $1.width - 4) } / cw))
        }
        guard let b = box else { return 20 }
        let rows = max(1, Int((b.height - 3) / 11))
        return max(2, rows * Int(max(0, b.width - 4) / cw))
    }

    /// La zone est-elle déjà remplie ? (une réponse écrite, ou un schéma dessiné pour une zone schéma)
    var isFilled: Bool { kind == .schema ? schema != nil : !answer.isEmpty }

    /// Phrase de contexte pour l'affichage dans la liste.
    var shortContext: String {
        let t = contextBefore
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "(sans texte voisin)" }
        return t.count > 90 ? "…" + t.suffix(90) : t
    }
}

/// Réglages de l'écriture des réponses sur le PDF.
struct WritingStyle: Equatable {
    var fontName: String
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var maxSize: CGFloat

    static let bleuImprime = WritingStyle(fontName: "Helvetica", red: 0.05, green: 0.15, blue: 0.75, maxSize: 11)
    static let noirImprime = WritingStyle(fontName: "Helvetica", red: 0.05, green: 0.05, blue: 0.08, maxSize: 11)
    static let manuscrit = WritingStyle(fontName: "Bradley Hand", red: 0.08, green: 0.12, blue: 0.55, maxSize: 13)

    static func named(_ key: String) -> WritingStyle {
        switch key {
        case "noir": return .noirImprime
        case "manuscrit": return .manuscrit
        default: return .bleuImprime
        }
    }
}

enum CoursError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}
