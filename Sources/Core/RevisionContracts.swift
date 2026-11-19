import Foundation

// Contrats du mode « Révision » : fiche de synthèse, questions d'entraînement avec correction,
// et corrigé d'une évaluation DÉJÀ RENDUE et corrigée par le professeur.
//
// Fichier de référence écrit par le chef de projet : GELÉ. L'agent « revision-core » l'implémente,
// l'agent « revision-ui » l'utilise. Les moteurs d'IA (ClaudeEngine, ClaudeCodeEngine) s'y conforment
// via `StructuredGenerator`.
//
// Principe : ce mode n'écrit JAMAIS dans le PDF d'origine. Tout ce qu'il produit s'affiche dans l'app
// ou s'exporte dans un NOUVEAU document. Il sert à apprendre et à réviser.

typealias RevisionProgress = @Sendable (Double, String) -> Void

// MARK: - Moteur

/// Moteur d'IA capable de renvoyer du JSON structuré (Claude par clé API, Claude par le compte).
/// Apple Intelligence n'est pas pris en charge pour la révision (contexte trop court).
protocol StructuredGenerator: AnyObject {
    var displayName: String { get }
    /// true : le moteur sait lire des images de pages.
    var supportsImages: Bool { get }
    /// `userText` : message ; `images` : JPEG de pages (ignorées si `supportsImages` est faux) ;
    /// `schema` : schéma JSON de la réponse. Renvoie le JSON de la réponse structurée, en texte.
    func generate(system: String, userText: String, images: [Data], schema: [String: Any]) async throws -> String
}

// MARK: - Document source

/// Une page du document, déjà lue.
struct RevisionPage {
    var index: Int                  // 0 = première page
    var text: String                // couche texte (vide pour un scan sans texte)
    var imageJPEG: Data?            // rendu de la page, sans marqueurs (seulement si demandé)
}

struct RevisionSource {
    var url: URL
    var documentName: String
    var pages: [RevisionPage]
    var pageCount: Int { pages.count }
}

// MARK: - Questions d'entraînement

enum QuestionStyle: String, Codable, CaseIterable, Identifiable {
    case qcm            // 3 ou 4 choix, un seul correct
    case vraiFaux
    case courte         // réponse en une ou deux phrases
    case definition     // « Définis… »
    case calcul         // petit calcul avec unités

    var id: String { rawValue }
    var label: String {
        switch self {
        case .qcm: return "QCM"
        case .vraiFaux: return "Vrai ou faux"
        case .courte: return "Réponse courte"
        case .definition: return "Définition"
        case .calcul: return "Calcul"
        }
    }
}

struct QuizOptions {
    var count = 10
    var styles: Set<QuestionStyle> = [.qcm, .courte, .definition]
}

struct RevisionQuestion: Identifiable, Codable, Equatable {
    var id: Int
    var style: QuestionStyle
    var question: String
    var choices: [String]           // vide sauf pour un QCM et un vrai/faux
    var expected: String            // réponse attendue (QCM : le texte du bon choix)
    var explanation: String         // explication courte, affichée après la correction
    var page: Int?                  // page du cours concernée (1 = première), si connue
}

enum Verdict: String, Codable {
    case juste
    case partiel
    case faux
}

struct GradedAnswer: Equatable {
    var questionID: Int
    var verdict: Verdict
    var feedback: String            // ce qui est bon, ce qui manque, en 1 à 3 phrases simples
    var expected: String
}

// MARK: - Fiche de synthèse

struct RevisionTerm: Codable, Equatable {
    var term: String
    var definition: String
}

struct RevisionSummary: Codable, Equatable {
    var title: String
    var keyPoints: [String]         // l'essentiel du cours, dans l'ordre
    var vocabulary: [RevisionTerm]
    var formulas: [String]          // ex. « U = R × I (tension en volts, résistance en ohms…) »
    var tips: [String]              // pièges et conseils pour retenir
}

// MARK: - Corrigé d'une évaluation déjà rendue

struct CorrigeItem: Identifiable, Codable, Equatable {
    var id: Int
    var page: Int                   // 1 = première page
    var number: String              // numéro de la question tel qu'écrit sur la feuille (« 3.b »)
    var instruction: String         // la consigne
    var studentAnswer: String       // ce que l'élève avait écrit (« » si vide ou illisible)
    var teacherRemark: String       // remarque ou correction du professeur (« » s'il n'y en a pas)
    var correctAnswer: String       // la bonne réponse
    var explanation: String         // pourquoi, en 2 ou 3 phrases simples
    var toRemember: String          // l'idée à retenir
    var status: Verdict?            // si le professeur a marqué juste / faux, sinon nil
}

// MARK: - Service (implémenté par l'agent « revision-core », utilisé par l'interface)

protocol RevisionProviding: AnyObject {
    /// Lit le document : texte de chaque page et, si `withImages`, un rendu JPEG de chaque page.
    func loadSource(url: URL, withImages: Bool, progress: @escaping RevisionProgress) async throws -> RevisionSource
    func makeSummary(_ source: RevisionSource, progress: @escaping RevisionProgress) async throws -> RevisionSummary
    func makeQuiz(_ source: RevisionSource, options: QuizOptions, progress: @escaping RevisionProgress) async throws -> [RevisionQuestion]
    /// Corrige un lot de réponses de l'élève ; renvoie un verdict par question, dans le même ordre.
    func grade(_ answers: [(question: RevisionQuestion, answer: String)]) async throws -> [GradedAnswer]
    /// À partir d'une évaluation déjà rendue (réponses de l'élève et remarques du professeur visibles sur les pages).
    func makeCorrige(_ source: RevisionSource, progress: @escaping RevisionProgress) async throws -> [CorrigeItem]
}

// Les exports vers de NOUVEAUX PDF sont fournis par l'agent « revision-core » dans RevisionExport.swift,
// avec exactement ces signatures :
//
//   enum RevisionExport {
//       static func summaryPDF(_ summary: RevisionSummary, documentName: String) throws -> Data
//       static func quizPDF(_ questions: [RevisionQuestion], documentName: String, withAnswers: Bool) throws -> Data
//       static func corrigePDF(_ items: [CorrigeItem], documentName: String) throws -> Data
//   }
