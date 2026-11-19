import Foundation

/// Lance le traitement : si le moteur choisi n'est pas utilisable, on ouvre les Réglages au lieu de lancer
/// (le panneau explique pourquoi).
@MainActor
enum Actions {
    static func complete(model: CoursModel, engines: EngineStatus, openSettings: () -> Void) {
        engines.refresh()
        if engines.problem(for: RunSettings.current().engine) != nil {
            openSettings()
            return
        }
        model.startCompletion()
    }
}
