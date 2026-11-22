import SwiftUI
import AppKit

/// Les grandes parties de l'application, dans l'ordre de la barre latérale.
enum AppMode: String, CaseIterable, Identifiable {
    case bibliotheque, completer, fiches, evaluations, ecouter
    #if COMPTE_PERSO
    case suiviMac   // « Suivi MacBook IA » : variante personnelle seulement
    #endif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bibliotheque: return "Bibliothèque"
        case .completer: return "Compléter un cours"
        case .fiches: return "Fiches de révision"
        case .evaluations: return "Évaluations"
        case .ecouter: return "Écouter un cours"
        #if COMPTE_PERSO
        case .suiviMac: return "Suivi MacBook IA"
        #endif
        }
    }

    /// Phrase courte affichée sous le titre dans la barre latérale.
    var subtitle: String {
        switch self {
        case .bibliotheque: return "Tous tes cours"
        case .completer: return "Remplit les trous et questions"
        case .fiches: return "Fiche, quiz, entraînement"
        case .evaluations: return "Corrigé d'une éval déjà notée"
        case .ecouter: return "Appuie, parle, la fiche arrive"
        #if COMPTE_PERSO
        case .suiviMac: return "Prix et meilleure offre pour l'IA"
        #endif
        }
    }

    var symbol: String {
        switch self {
        case .bibliotheque: return "books.vertical"
        case .completer: return "wand.and.stars"
        case .fiches: return "graduationcap"
        case .evaluations: return "checkmark.seal"
        case .ecouter: return "waveform"
        #if COMPTE_PERSO
        case .suiviMac: return "laptopcomputer"
        #endif
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .bibliotheque: return "1"
        case .completer: return "2"
        case .fiches: return "3"
        case .evaluations: return "4"
        case .ecouter: return "5"
        #if COMPTE_PERSO
        case .suiviMac: return "6"
        #endif
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
        // même cours : on garde la fiche, les cartes et les questions déjà créées (elles ont consommé l'IA)
        if revision.documentURL?.standardizedFileURL != url.standardizedFileURL { revision.open(url) }
        revision.tab = .fiche
    }

    func correct(_ url: URL) {
        mode = .evaluations
        let revision = RevisionModel.evaluations
        if revision.documentURL?.standardizedFileURL != url.standardizedFileURL { revision.open(url) }
        revision.tab = .apres
    }
}
