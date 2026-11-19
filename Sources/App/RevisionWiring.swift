import SwiftUI

// Seul fichier de l'interface Révision qui touche au vrai service (RevisionService) et aux exports (RevisionExport).

struct LiveRevisionExporter: RevisionExporting {
    func summaryPDF(_ summary: RevisionSummary, documentName: String) throws -> Data {
        try RevisionExport.summaryPDF(summary, documentName: documentName)
    }
    func quizPDF(_ questions: [RevisionQuestion], documentName: String, withAnswers: Bool) throws -> Data {
        try RevisionExport.quizPDF(questions, documentName: documentName, withAnswers: withAnswers)
    }
    func corrigePDF(_ items: [CorrigeItem], documentName: String) throws -> Data {
        try RevisionExport.corrigePDF(items, documentName: documentName)
    }
    func cardsPDF(_ cards: [RevisionCard], documentName: String) throws -> Data {
        try RevisionExport.cardsPDF(cards, documentName: documentName)
    }
}

extension RevisionModel {
    /// Modèle de la fenêtre « Révision » : moteur courant des Réglages, vrai service, vrais dialogues.
    static let live = RevisionModel(
        engineStatus: { RevisionWiring.status() },
        makeService: { try RevisionWiring.makeService() },
        exporter: LiveRevisionExporter(),
        dialogs: AppKitRevisionDialogs())
}

@MainActor
enum RevisionWiring {
    /// État du moteur choisi dans les Réglages, sans le construire (aucun accès au contenu du trousseau).
    static func status() -> RevisionEngineStatus {
        let settings = RunSettings.current()
        switch settings.engine {
        case .apple:
            return RevisionEngineStatus(name: settings.engineDisplayName, usable: false, supportsImages: false,
                                        issue: RevisionEngineStatus.message, needsSettings: true)
        case .claudeCode:
            #if COMPTE_PERSO
            // « Claude (mon compte) » : le programme `claude` est lancé à la demande ; son état se voit dans les Réglages.
            guard ClaudeCodeEngine.locateCLI(override: settings.claudeCodePath) != nil else {
                return RevisionEngineStatus(
                    name: settings.engineDisplayName, usable: false, supportsImages: true,
                    issue: RevisionIssue(title: "Claude (mon compte) est introuvable",
                                         what: Fr.sentence(ClaudeCodeEngine.missingMessage),
                                         todo: "Vérifie le moteur dans les Réglages."),
                    needsSettings: true)
            }
            return RevisionEngineStatus(name: settings.engineDisplayName, usable: true, supportsImages: true,
                                        issue: nil, needsSettings: false)
            #else
            return RevisionEngineStatus(name: settings.engineDisplayName, usable: false, supportsImages: false,
                                        issue: RevisionEngineStatus.message, needsSettings: true)
            #endif
        case .claude:
            let engines = EngineStatus.shared
            engines.refresh()
            if let problem = engines.problem(for: .claude) {
                return RevisionEngineStatus(
                    name: settings.engineDisplayName, usable: false, supportsImages: true,
                    issue: RevisionIssue(title: problem.title, what: problem.title + ".", todo: problem.message),
                    needsSettings: true)
            }
            return RevisionEngineStatus(name: settings.engineDisplayName, usable: true, supportsImages: true,
                                        issue: nil, needsSettings: false)
        }
    }

    /// Construit le service ; lève une erreur lisible si le moteur ne sait pas faire de JSON structuré.
    static func makeService() throws -> RevisionProviding {
        let engine: CompletionEngine
        do { engine = try EngineFactory.make(RunSettings.current()) }
        catch {
            throw RevisionIssueError(issue: RevisionIssue(
                title: "Le moteur n'est pas utilisable", what: Fr.sentence(error.localizedDescription),
                todo: "Vérifie ton moteur dans les Réglages."))
        }
        guard let generator = engine as? StructuredGenerator else { throw RevisionIssueError(issue: RevisionEngineStatus.message) }
        return RevisionService(generator: generator)
    }
}

/// Contenu de la fenêtre « Révision » (scène déclarée dans App.swift).
struct RevisionWindow: View {
    @ObservedObject private var model = RevisionModel.live
    var body: some View { RevisionRootView(model: model) }
}
