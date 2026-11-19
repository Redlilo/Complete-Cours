import SwiftUI

/// Fenêtre principale : barre latérale (4 parties + Réglages) et contenu de la partie choisie.
struct MainShell: View {
    @ObservedObject private var navigator = Navigator.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { navigator.mode }, set: { if let m = $0 { navigator.mode = m } })) {
                Section("Mes cours") {
                    row(.bibliotheque)
                }
                Section("Ce que je veux faire") {
                    row(.completer)
                    row(.fiches)
                    row(.evaluations)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 280)
            .safeAreaInset(edge: .bottom) {
                Button { openSettings() } label: { Label("Réglages et moteur d'IA", systemImage: "gearshape") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            switch navigator.mode {
            case .bibliotheque: LibraryView()
            case .completer: ContentView()
            case .fiches: RevisionRootView(model: RevisionModel.live, tabs: [.fiche, .entrainement])
            case .evaluations: RevisionRootView(model: RevisionModel.live, tabs: [.apres])
            }
        }
    }

    private func row(_ mode: AppMode) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(mode.title)
                Text(mode.subtitle).font(.caption).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: mode.symbol) }
        .tag(mode)
        .padding(.vertical, 2)
    }
}
