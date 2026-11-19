import SwiftUI

/// Écran d'accueil : aucun PDF n'est ouvert.
struct EmptyStateView: View {
    @EnvironmentObject var model: CoursModel
    @EnvironmentObject var engines: EngineStatus
    let dropTargeted: Bool
    let showWelcome: () -> Void
    @AppStorage(Pref.engine) private var engineRaw = Pref.defaultEngine.rawValue

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                dropArea
                Button { Navigator.shared.mode = .fiches } label: {
                    Label("Fiches de révision", systemImage: "graduationcap")
                }
                .controlSize(.large)
                .help("Fiche de synthèse, questions d'entraînement et corrigé d'une évaluation rendue (⇧⌘R)")
                if let error = model.openError {
                    Label {
                        Text(error).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .padding(12)
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Problème : \(error)")
                }
                if engineRaw == EngineKind.claude.rawValue, !engines.claudeKeyPresent {
                    keyHint
                }
                if !model.recents.isEmpty { recents }
            }
            .padding(32)
            .frame(maxWidth: .infinity, minHeight: 480)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var dropArea: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Complète tes cours en un clic")
                .font(.title.weight(.semibold))
            Text("Dépose ici un PDF de cours à trous (fiche, questions, définitions, tableau, formulaire). Complète-Cours trouve les zones à remplir et écrit les réponses.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button { model.presentOpenPanel() } label: {
                Label("Choisir un PDF…", systemImage: "folder")
                    .padding(.horizontal, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Text("ou glisse-le sur cette fenêtre")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 34).padding(.horizontal, 40)
        .frame(maxWidth: 580)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(dropTargeted ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: dropTargeted ? 3 : 1.5, dash: [9, 6]))
        )
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .accessibilityElement(children: .contain)
    }

    private var keyHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(.secondary)
            Text("Pour écrire les réponses, il faudra une clé Claude.")
                .font(.callout)
            Button("Voir comment faire", action: showWelcome)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color.secondary.opacity(0.09), in: Capsule())
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Récents").font(.headline)
                Spacer()
                Button("Effacer") { model.clearRecents() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            ForEach(model.recents.prefix(5), id: \.self) { url in
                Button { model.open(url) } label: {
                    HStack {
                        Image(systemName: "doc.richtext").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.deletingPathExtension().lastPathComponent)
                                .lineLimit(1)
                            Text(url.deletingLastPathComponent().lastPathComponent)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
                .accessibilityLabel("Ouvrir \(url.deletingPathExtension().lastPathComponent)")
            }
        }
        .frame(maxWidth: 420)
    }
}
