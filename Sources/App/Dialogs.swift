import AppKit
import UniformTypeIdentifiers

/// Tout ce que le modèle demande à l'utilisateur ou au Finder. Une interface à part pour pouvoir
/// tester le modèle sans fenêtre (voir Tools/Tests/App) et pour le mode --selftest, qui ne pose aucune question.
@MainActor
protocol Dialogs: AnyObject {
    /// Question à deux réponses. `destructive` : le bouton par défaut est « annuler » (action risquée).
    func confirm(title: String, message: String, accept: String, cancel: String, destructive: Bool) -> Bool
    /// Question à plusieurs réponses : renvoie l'index du bouton choisi (le premier est le bouton par défaut).
    func choose(title: String, message: String, buttons: [String]) -> Int
    func inform(title: String, message: String)
    func chooseOpenURL() -> URL?
    func chooseSaveURL(suggestedName: String, directory: URL?) -> URL?
    func reveal(_ url: URL)
}

@MainActor
final class AppKitDialogs: Dialogs {
    func confirm(title: String, message: String, accept: String, cancel: String, destructive: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .warning : .informational
        if destructive {
            alert.addButton(withTitle: cancel)           // bouton par défaut = le plus prudent
            alert.addButton(withTitle: accept)
            return alert.runModal() == .alertSecondButtonReturn
        }
        alert.addButton(withTitle: accept)
        alert.addButton(withTitle: cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func choose(title: String, message: String, buttons: [String]) -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        for b in buttons { alert.addButton(withTitle: b) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    func inform(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func chooseOpenURL() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choisir un PDF"
        panel.prompt = "Ouvrir"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseSaveURL(suggestedName: String, directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Enregistrer le résultat"
        panel.prompt = "Enregistrer"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        if let directory { panel.directoryURL = directory }
        return panel.runModal() == .OK ? panel.url : nil
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Aucune question, aucune fenêtre : pour --selftest. Les confirmations sont acceptées.
@MainActor
final class SilentDialogs: Dialogs {
    func confirm(title: String, message: String, accept: String, cancel: String, destructive: Bool) -> Bool { true }
    func choose(title: String, message: String, buttons: [String]) -> Int { 0 }
    func inform(title: String, message: String) {}
    func chooseOpenURL() -> URL? { nil }
    func chooseSaveURL(suggestedName: String, directory: URL?) -> URL? { nil }
    func reveal(_ url: URL) {}
}
