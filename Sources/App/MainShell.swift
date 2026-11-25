import SwiftUI

/// Fenêtre principale : barre latérale (4 parties + Réglages) et contenu de la partie choisie.
struct MainShell: View {
    @ObservedObject private var navigator = Navigator.shared
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var engines = EngineStatus.shared
    @AppStorage(Pref.engine) private var engineRaw = Pref.defaultEngine.rawValue
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { navigator.mode }, set: { if let m = $0 { navigator.mode = m } })) {
                Section("Mes cours") {
                    row(.bibliotheque, badge: library.files.count)
                }
                Section("Ce que je veux faire") {
                    row(.completer)
                    row(.fiches)
                    row(.evaluations)
                    row(.ecouter)
                }
                #if COMPTE_PERSO
                Section("Perso") {
                    row(.suiviMac)
                    row(.atlas)
                }
                #endif
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 290)
            .safeAreaInset(edge: .bottom) { engineChip }
        } detail: {
            Group {
                switch navigator.mode {
                case .bibliotheque: LibraryView()
                case .completer: ContentView()
                case .fiches: RevisionRootView(model: RevisionModel.live, tabs: [.fiche, .cartes, .entrainement])
                case .evaluations: EvaluationsView()
                case .ecouter: LectureView()
                #if COMPTE_PERSO
                case .suiviMac: SuiviMacView()
                case .atlas: AtlasView()
                #endif
                }
            }
            .transition(.opacity)
            .safeAreaInset(edge: .top, spacing: 0) { AutoIntakeBanner() }
        }
        .animation(.easeInOut(duration: 0.15), value: navigator.mode)
    }

    // MARK: Rangée

    private func tint(_ mode: AppMode) -> Color {
        switch mode {
        case .bibliotheque: return .blue
        case .completer: return .purple
        case .fiches: return .green
        case .evaluations: return .orange
        case .ecouter: return .red
        #if COMPTE_PERSO
        case .suiviMac: return .teal
        case .atlas: return .indigo
        #endif
        }
    }

    private func row(_ mode: AppMode, badge: Int = 0) -> some View {
        HStack(spacing: 10) {
            Image(systemName: mode.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(tint(mode).gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(mode.title).font(.body.weight(.medium)).lineLimit(1)
                Text(mode.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if badge > 0 {
                Text("\(badge)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .accessibilityLabel("\(badge) PDF")
            }
        }
        .tag(mode)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mode.title). \(mode.subtitle)\(badge > 0 ? ". \(badge) PDF" : "")")
    }

    // MARK: Puce du moteur d'IA

    private var engineChip: some View {
        let kind = EngineKind(rawValue: engineRaw) ?? Pref.defaultEngine
        let name = RunSettings.current().engineDisplayName
        let problem = engines.problem(for: kind)
        let ok = problem == nil
        return Button { openSettings() } label: {
            HStack(spacing: 8) {
                Circle().fill(ok ? Color.green : Color.orange).frame(width: 9, height: 9)
                    .accessibilityLabel(ok ? "Moteur prêt" : "Moteur à régler")
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(ok ? "Prêt à écrire les réponses" : (problem?.title ?? "À régler"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(10)
        .help("Moteur d'IA : \(name). Clique pour ouvrir les Réglages.")
        .accessibilityLabel("Moteur d'IA : \(name), \(ok ? "prêt" : "à régler"). Ouvrir les Réglages")
    }
}
