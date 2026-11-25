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
        if CommandLine.arguments.contains("--archive-originals") {
            ArchiveCLI.runAndExit(CommandLine.arguments)
        }
        #if COMPTE_PERSO
        // Relevé de prix quotidien sans fenêtre (tâche macOS) : « App Perso --suivi-releve ».
        if CommandLine.arguments.contains("--suivi-releve") {
            SuiviMacCLI.runAndExit()
        }
        #endif
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
        Window(AppIdentity.nom, id: "main") {
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
        guard CoursModel.shared.confirmLeavingCurrentWork(action: "quittes l'application") else { return .terminateCancel }
        let lecture = LectureModel.shared
        guard lecture.occupe else { return .terminateNow }
        // Un cours est écouté (ou sa transcription se termine) : on ne le perd pas en quittant.
        let alert = NSAlert()
        alert.messageText = "Un cours est en train d'être écouté"
        alert.informativeText = "Si tu quittes, l'app arrête l'écoute, finit d'écrire le texte de ce qui a été enregistré (jusqu'à une minute), puis se ferme. Le cours t'attendra dans « À relire »."
        alert.addButton(withTitle: "Continuer l'écoute")
        alert.addButton(withTitle: "Arrêter et quitter")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        lecture.terminer()
        Task { @MainActor in
            let limite = Date().addingTimeInterval(60)
            while lecture.occupe, Date() < limite { try? await Task.sleep(for: .milliseconds(300)) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AutoIntake.shared.resumeIfEnabled()
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
    @ObservedObject private var navigator = Navigator.shared

    /// Les commandes de l'écran Compléter ne servent que dans cette partie de l'app.
    private var inCompleter: Bool { navigator.mode == .completer }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Ouvrir…") {
                switch Navigator.shared.mode {
                case .fiches: RevisionModel.live.chooseDocument()
                case .evaluations: RevisionModel.evaluations.chooseDocument()
                case .ecouter: break
                #if COMPTE_PERSO
                case .suiviMac, .atlas: break
                #endif
                case .bibliotheque, .completer:
                    Navigator.shared.mode = .completer
                    model.presentOpenPanel()
                }
            }
                .keyboardShortcut("o")
            Menu("Ouvrir récent") {
                ForEach(model.recents, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { Navigator.shared.mode = .completer; model.open(url) }
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
                .disabled(!model.canSave || !inCompleter)
        }

        CommandMenu("Cours") {
            Button("Compléter le cours") {
                Actions.complete(model: model, engines: engines) { openSettings() }
            }
            .keyboardShortcut("r")
            .disabled(!model.canComplete || !inCompleter)
            Button("Annuler le traitement") { model.cancelRun() }
                .keyboardShortcut(".")
                .disabled(!model.isRunning)
            Button("Ranger les originaux vides…") {
                Navigator.shared.mode = .bibliotheque
                Navigator.shared.showArchive = true
            }
            Divider()
            ForEach(AppMode.allCases) { mode in
                Button(mode.title) { Navigator.shared.mode = mode }
                    .keyboardShortcut(mode.shortcut)
            }
            Button("Ajouter une zone à la main") { model.beginDrawingZone() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.canDrawZone || !inCompleter)
        }

        CommandGroup(before: .toolbar) {
            Button("Zoom avant") { model.zoomIn() }
                .keyboardShortcut("+")
                .disabled(model.document == nil || !inCompleter)
            Button("Zoom arrière") { model.zoomOut() }
                .keyboardShortcut("-")
                .disabled(model.document == nil || !inCompleter)
            Button("Ajuster à la fenêtre") { model.zoomToFit() }
                .keyboardShortcut("0")
                .disabled(model.document == nil || !inCompleter)
            Divider()
        }
    }
}
