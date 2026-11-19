import Foundation
import PDFKit

// Contrats entre le pipeline, les moteurs d'IA, le rendu PDF et l'interface.
// Ce fichier est la référence : les moteurs (ClaudeEngine, AppleEngine) et AnswerRenderer
// doivent respecter ces signatures exactement.

/// Identité de l'élève, utilisée uniquement pour remplir les champs « Nom », « Prénom », « Classe ».
struct StudentProfile: Codable, Equatable {
    var nom = ""
    var prenom = ""
    var classe = ""
    var isEmpty: Bool {
        [nom, prenom, classe].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Une page à compléter, telle que la voit un moteur d'IA.
struct PageRequest {
    var documentName: String
    var pageNumber: Int              // 1 = première page
    var pageCount: Int
    /// Texte de la page, avec ⟦n⟧ à l'emplacement des zones. Vide pour un scan lu sans OCR.
    var transcript: String
    var hasTextLayer: Bool
    /// Zones à remplir. `Zone.number` est le repère ⟦n⟧ du texte et le numéro dessiné sur l'image.
    var zones: [Zone]
    /// Image JPEG de la page avec les numéros des zones dessinés (seulement si `usesImages`).
    var markedImageJPEG: Data?
    var student: StudentProfile
    var todayText: String            // ex. « mardi 17 novembre 2026 »
}

struct ZoneAnswer {
    var number: Int                  // numéro de la zone sur la page (Zone.number)
    var kind: ZoneKind               // .ignorer = ce n'est pas un trou à remplir
    var text: String
}

/// Une réponse à réécrire dans un style plus naturel (étape « humanisation »).
/// Seules les zones `.definition` et `.question` passent par là : jamais les mots à compléter.
struct HumanizeItem {
    var id: Int                      // identifiant de zone (Zone.id)
    var kind: ZoneKind
    var question: String             // texte voisin (la consigne)
    var answer: String               // réponse à réécrire
    var maxChars: Int                // longueur maximale du résultat
}

enum EngineError: LocalizedError {
    case unavailable(String)         // moteur inutilisable (pas de clé, Apple Intelligence désactivé…)
    case auth(String)                // clé API refusée
    case rateLimited(String)
    case network(String)
    case refused(String)             // l'IA a refusé de répondre
    case invalidResponse(String)
    case other(String)

    /// Une erreur fatale arrête tout le traitement (inutile d'essayer les autres pages).
    var isFatal: Bool {
        switch self {
        case .unavailable, .auth: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .unavailable(let m), .auth(let m), .rateLimited(let m), .network(let m),
             .refused(let m), .invalidResponse(let m), .other(let m):
            return m
        }
    }
}

protocol CompletionEngine: AnyObject {
    var displayName: String { get }
    /// true : le moteur reçoit l'image de la page avec les numéros ; false : texte seulement.
    var usesImages: Bool { get }
    /// Nombre de pages traitées en parallèle (1 pour l'IA locale).
    var maxConcurrentPages: Int { get }
    /// Remplit les zones d'une page. Doit renvoyer une réponse par zone connue (numéro = Zone.number).
    func complete(_ request: PageRequest) async throws -> [ZoneAnswer]
    /// Réécrit des réponses de façon plus naturelle. Le dictionnaire est indexé par `HumanizeItem.id` ;
    /// une entrée manquante signifie « garder la réponse d'origine ».
    func humanize(_ items: [HumanizeItem]) async throws -> [Int: String]
}
