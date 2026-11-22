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
                ScreenHeader(title: "Compléter un cours",
                             subtitle: "Dépose un PDF : les trous et les questions sont remplis pour toi.")
                    .frame(maxWidth: 760)
                VStack(spacing: 18) {
                    dropArea
                    if let error = model.openError { errorCard(error) }
                    if engineRaw == EngineKind.claude.rawValue, !engines.claudeKeyPresent { keyHint }
                    if !model.recents.isEmpty { recents }
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 760)
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, minHeight: 480, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Carte de dépôt

    private var dropArea: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(dropTargeted ? 0.22 : 0.12)).frame(width: 96, height: 96)
                Image(systemName: dropTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)
            Text(dropTargeted ? "Lâche le PDF ici" : "Glisse un PDF de cours ici")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Fiche à trous, questions, définitions, tableau ou formulaire : \(AppIdentity.nom) trouve les zones à remplir et écrit les réponses.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            HStack(spacing: 12) {
                Button { model.presentOpenPanel() } label: {
                    Label("Choisir un PDF…", systemImage: "folder").padding(.horizontal, 6)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .help("Ouvrir un PDF (⌘O)")
                Button { Navigator.shared.mode = .bibliotheque } label: {
                    Label("Mes cours", systemImage: "books.vertical").padding(.horizontal, 6)
                }
                .controlSize(.large)
                .help("Choisir un PDF dans ta bibliothèque de cours (⌘1)")
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 34).padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(dropTargeted ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: dropTargeted ? 3 : 1.5, dash: [9, 6]))
        )
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .accessibilityElement(children: .contain)
    }

    // MARK: Cartes colorées

    private func errorCard(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ce PDF n'a pas pu être ouvert").font(.callout.weight(.semibold))
                Text(error).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.4)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Problème : \(error)")
    }

    private var keyHint: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill").font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Il te faut une clé Claude").font(.callout.weight(.semibold))
                Text("Pour écrire les réponses, l'app a besoin d'une clé API. On t'explique comment l'obtenir.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Voir comment faire", action: showWelcome)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.blue.opacity(0.3)))
        .accessibilityElement(children: .contain)
    }

    // MARK: Récents

    private var recents: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Récents").font(.headline)
                Spacer()
                Button("Effacer") { model.clearRecents() }
                    .buttonStyle(.link).font(.callout)
                    .accessibilityLabel("Effacer la liste des fichiers récents")
            }
            let items = Array(model.recents.prefix(6))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 12)], spacing: 12) {
                ForEach(items, id: \.self) { url in recentCard(url) }
            }
        }
    }

    private func recentCard(_ url: URL) -> some View {
        let name = url.deletingPathExtension().lastPathComponent
        return Button { model.open(url) } label: {
            HStack(spacing: 10) {
                ThumbnailView(url: url, size: CGSize(width: 44, height: 58))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(url.deletingLastPathComponent().lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .card(padding: 10)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(url.path)
        .accessibilityLabel("Ouvrir \(name)")
    }
}
