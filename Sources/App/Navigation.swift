import SwiftUI
import AppKit

/// Les grandes parties de l'application, dans l'ordre de la barre latérale.
enum AppMode: String, CaseIterable, Identifiable {
    case bibliotheque, completer, fiches, evaluations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bibliotheque: return "Bibliothèque"
        case .completer: return "Compléter un cours"
        case .fiches: return "Fiches de révision"
        case .evaluations: return "Évaluations"
        }
    }

    /// Phrase courte affichée sous le titre dans la barre latérale.
    var subtitle: String {
        switch self {
        case .bibliotheque: return "Tous tes cours"
        case .completer: return "Remplit les trous et questions"
        case .fiches: return "Fiche, quiz, entraînement"
        case .evaluations: return "Corrigé d'une éval déjà notée"
        }
    }

    var symbol: String {
        switch self {
        case .bibliotheque: return "books.vertical"
        case .completer: return "wand.and.stars"
        case .fiches: return "graduationcap"
        case .evaluations: return "checkmark.seal"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .bibliotheque: return "1"
        case .completer: return "2"
        case .fiches: return "3"
        case .evaluations: return "4"
        }
    }
}

/// Mode affiché + passerelles « ouvrir ce PDF dans tel mode » utilisées par la bibliothèque et les menus.
@MainActor
final class Navigator: ObservableObject {
    static let shared = Navigator()

    @Published var mode: AppMode = .bibliotheque
    /// Demande venue du menu « Cours » : ouvrir l'écran « Ranger les originaux vides ».
    @Published var showArchive = false

    func complete(_ url: URL) {
        mode = .completer
        CoursModel.shared.open(url)
    }

    func makeSheet(_ url: URL) {
        mode = .fiches
        let revision = RevisionModel.live
        revision.open(url)
        revision.tab = .fiche
    }

    func correct(_ url: URL) {
        mode = .evaluations
        let revision = RevisionModel.live
        revision.open(url)
        revision.tab = .apres
    }
}
