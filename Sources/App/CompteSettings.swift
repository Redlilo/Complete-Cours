#if COMPTE_PERSO

import SwiftUI
import AppKit

/// Section « Claude (mon compte) » des Réglages : état du compte, connexion, modèle, effort et programme.
/// Usage personnel uniquement. Tout le fichier est dans « #if COMPTE_PERSO » (voir ClaudeCodeEngine.swift).
struct CompteSettings: View {
    @AppStorage(Pref.claudeCodeModel) private var modelID = ClaudeCodeEngine.defaultModel
    @AppStorage(Pref.claudeCodeEffort) private var effort = ClaudeCodeEngine.defaultEffort
    @AppStorage(Pref.claudeCodePath) private var cliPath = ""
    @AppStorage(Pref.verifyAfterCompletion) private var verifyAfter = false

    /// nil tant que l'état du compte n'a pas été vérifié.
    @State private var status: ClaudeCodeEngine.Status?
    @State private var checking = false
    @State private var loginTask: Task<Void, Never>?
    @State private var loginError: String?

    private var loggingIn: Bool { loginTask != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(ClaudeCodeEngine.personalUseWarning)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            GroupBox("Compte") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Label(statusText, systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(isReady ? Color.green : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if checking { ProgressView().controlSize(.small) }
                        Spacer(minLength: 0)
                        Button("Actualiser") { Task { await refreshStatus() } }
                            .disabled(checking || loggingIn)
                    }
                    HStack(spacing: 10) {
                        Button(ClaudeCodeEngine.loginButtonTitle) { startLogin() }
                            .disabled(checking || loggingIn)
                        if loggingIn {
                            ProgressView().controlSize(.small)
                            Text("Attente de la connexion dans ton navigateur…")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Annuler") { loginTask?.cancel() }
                        }
                    }
                    if let loginError {
                        Label(loginError, systemImage: "xmark.octagon.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Modèle") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Modèle", selection: $modelID) {
                        ForEach(ClaudeCodeEngine.models) { Text($0.label).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Modèle Claude (mon compte)")
                    .frame(maxWidth: 260, alignment: .leading)
                    Text(sentenceCase(hint(for: modelID, in: ClaudeCodeEngine.models)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Effort") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Effort", selection: $effort) {
                        ForEach(ClaudeCodeEngine.efforts) { Text($0.label).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Effort de réflexion")
                    Text(sentenceCase(hint(for: effort, in: ClaudeCodeEngine.efforts)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Vérification") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Vérifier les réponses avec Opus (consomme plus de quota)", isOn: $verifyAfter)
                    Text("Relit chaque page : une page remplie ne coûte pas la même chose qu'une page vide. "
                         + "Estimation : environ une fois et demie à deux fois le coût d'une page (c'est une estimation, pas une mesure).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Programme « claude »") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Vide = recherche automatique", text: $cliPath)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await refreshStatus() } }
                            .accessibilityLabel("Chemin du programme claude")
                        Button("Choisir…") { choosePath() }
                    }
                    Text("Laisse vide : l'app trouve Claude Code toute seule. Indique un chemin seulement si la recherche échoue.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await refreshStatus() }
    }

    // MARK: - Affichage

    private var isReady: Bool { status?.isReady ?? false }

    private var statusText: String {
        if let status { return status.summary }
        return checking ? "Vérification en cours…" : "Pas encore vérifié"
    }

    private func hint(for id: String, in choices: [ClaudeCodeEngine.Choice]) -> String {
        choices.first { $0.id == id }?.hint ?? ""
    }

    private func sentenceCase(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: - Actions

    /// Trouve le programme et lit l'état du compte. `auth status` ne contacte pas le réseau.
    private func refreshStatus() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        guard let found = await ClaudeCodeEngine.locateWorkingCLI(override: cliPath) else {
            status = .absent
            return
        }
        status = await ClaudeCodeEngine.status(cli: found.url)
    }

    /// Lance la connexion (le navigateur s'ouvre, l'élève valide lui-même). Annulable ; l'erreur s'affiche telle quelle.
    private func startLogin() {
        loginError = nil
        let path = cliPath
        loginTask = Task {
            defer { loginTask = nil }
            do {
                guard let found = await ClaudeCodeEngine.locateWorkingCLI(override: path) else {
                    throw EngineError.unavailable(ClaudeCodeEngine.missingMessage)
                }
                try await ClaudeCodeEngine.login(cli: found.url)
            } catch is CancellationError {
                // Annulé par l'élève : rien à afficher.
            } catch {
                loginError = error.localizedDescription
            }
            await refreshStatus()
        }
    }

    /// Ouvre le sélecteur de fichiers : le programme « claude » ou le dossier Claude.app.
    private func choosePath() {
        let panel = NSOpenPanel()
        panel.title = "Programme « claude »"
        panel.message = "Choisis le programme claude, ou le dossier Claude.app."
        panel.prompt = "Choisir"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        cliPath = url.path
        Task { await refreshStatus() }
    }
}

#endif
