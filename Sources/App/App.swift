import SwiftUI
import AppKit

/// Point d'entrée : le mode --selftest tourne sans fenêtre, tout le reste lance l'application normale.
@main
enum Launcher {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit(CommandLine.arguments)
        }
        CompleteCoursApp.main()
    }
}

struct CompleteCoursApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = CoursModel.shared
    @StateObject private var engines = EngineStatus.shared

    init() {
        Pref.registerDefaults()
    }

    var body: some Scene {
        Window("Complète-Cours", id: "main") {
            MainShell()
                .environmentObject(model)
                .environmentObject(engines)
                .environmentObject(Navigator.shared)
                .frame(minWidth: 980, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 800)
        .commands { AppCommands(model: model, engines: engines) }

        Settings {
            SettingsView()
                .environmentObject(engines)
        }
    }
}

/// Ouverture depuis le Finder, fermeture de la dernière fenêtre, demande avant de quitter.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        Navigator.shared.mode = .completer
        CoursModel.shared.handleDrop(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        CoursModel.shared.confirmLeavingCurrentWork(action: "quittes l'application") ? .terminateNow : .terminateCancel
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // l'élève revient peut-être des Réglages Système (Apple Intelligence) ou du trousseau
        EngineStatus.shared.refresh()
    }
}

// MARK: - Menus

struct AppCommands: Commands {
    @ObservedObject var model: CoursModel
    @ObservedObject var engines: EngineStatus
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Ouvrir…") {
                switch Navigator.shared.mode {
                case .fiches, .evaluations: RevisionModel.live.chooseDocument()
                case .bibliotheque, .completer:
                    Navigator.shared.mode = .completer
                    model.presentOpenPanel()
                }
            }
                .keyboardShortcut("o")
            Menu("Ouvrir récent") {
                ForEach(model.recents, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { model.open(url) }
                }
                if !model.recents.isEmpty { Divider() }
                Button("Effacer le menu") { model.clearRecents() }
                    .disabled(model.recents.isEmpty)
            }
            .disabled(model.recents.isEmpty)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Fermer") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
            Button("Enregistrer le PDF complété…") { model.savePDF() }
                .keyboardShortcut("s")
                .disabled(!model.canSave)
        }

        CommandMenu("Cours") {
            Button("Compléter le cours") {
                Actions.complete(model: model, engines: engines) { openSettings() }
            }
            .keyboardShortcut("r")
            .disabled(!model.canComplete)
            Button("Annuler le traitement") { model.cancelRun() }
                .keyboardShortcut(".")
                .disabled(!model.isRunning)
            Divider()
            ForEach(AppMode.allCases) { mode in
                Button(mode.title) { Navigator.shared.mode = mode }
                    .keyboardShortcut(mode.shortcut)
            }
            Button("Ajouter une zone à la main") { model.beginDrawingZone() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.canDrawZone)
        }

        CommandGroup(before: .toolbar) {
            Button("Zoom avant") { model.zoomIn() }
                .keyboardShortcut("+")
                .disabled(model.document == nil)
            Button("Zoom arrière") { model.zoomOut() }
                .keyboardShortcut("-")
                .disabled(model.document == nil)
            Button("Ajuster à la fenêtre") { model.zoomToFit() }
                .keyboardShortcut("0")
                .disabled(model.document == nil)
            Divider()
        }
    }
}
