import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Fenêtre unique : écran d'accueil sans PDF, sinon aperçu à gauche et liste des zones à droite.
struct ContentView: View {
    @EnvironmentObject var model: CoursModel
    @EnvironmentObject var engines: EngineStatus
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Pref.welcomeSeen) private var welcomeSeen = false
    @State private var showWelcome = false
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if model.document == nil {
                EmptyStateView(dropTargeted: dropTargeted, showWelcome: { showWelcome = true })
            } else {
                HSplitView {
                    PreviewPane()
                        .frame(minWidth: 380, idealWidth: 700)
                    ZonePanel()
                        .frame(minWidth: 340, idealWidth: 400, maxWidth: 460)
                }
            }
        }
        .navigationTitle(model.documentName.isEmpty ? "Complète-Cours" : model.documentName)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .overlay { if dropTargeted && model.document != nil { DropHighlight() } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            DropLoader.urls(from: providers) { urls in model.handleDrop(urls) }
            return true
        }
        .sheet(isPresented: $showWelcome, onDismiss: { welcomeSeen = true }) {
            WelcomeView()
                .environmentObject(engines)
        }
        .onAppear {
            engines.refresh()
            // premier lancement avec Claude et sans clé : on explique comment en obtenir une
            if !welcomeSeen, RunSettings.current().engine == .claude, !engines.claudeKeyPresent {
                showWelcome = true
            }
        }
    }

    private var subtitle: String {
        guard model.document != nil else { return "" }
        if model.isAnalyzing { return "Recherche des zones…" }
        return model.analysisSummary
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.presentOpenPanel() } label: { Label("Ouvrir", systemImage: "folder") }
                .help("Ouvrir un PDF (⌘O)")
        }
        ToolbarItemGroup(placement: .automatic) {
            Button { model.zoomOut() } label: { Label("Zoom arrière", systemImage: "minus.magnifyingglass") }
                .help("Zoom arrière (⌘-)")
                .disabled(model.document == nil)
            Button { model.zoomToFit() } label: { Label("Ajuster", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Ajuster à la fenêtre (⌘0)")
                .disabled(model.document == nil)
            Button { model.zoomIn() } label: { Label("Zoom avant", systemImage: "plus.magnifyingglass") }
                .help("Zoom avant (⌘+)")
                .disabled(model.document == nil)
        }
        ToolbarItem(placement: .automatic) {
            Button {
                if model.isDrawingZone { model.cancelDrawingZone() } else { model.beginDrawingZone() }
            } label: {
                Label(model.isDrawingZone ? "Annuler le tracé" : "Ajouter une zone",
                      systemImage: model.isDrawingZone ? "xmark.rectangle" : "rectangle.dashed.badge.record")
            }
            .help("Ajouter une zone à la main : tire un rectangle sur la page (⇧⌘N)")
            .disabled(!model.canDrawZone && !model.isDrawingZone)
        }
        ToolbarItem(placement: .automatic) {
            Button { model.savePDF() } label: { Label("Enregistrer", systemImage: "square.and.arrow.down") }
                .help("Enregistrer le PDF complété (⌘S)")
                .disabled(!model.canSave)
        }
        ToolbarItem(placement: .primaryAction) {
            if model.isRunning {
                Button(role: .cancel) { model.cancelRun() } label: { Label("Annuler", systemImage: "stop.circle") }
                    .help("Arrêter le traitement (⌘.)")
            } else {
                Button {
                    Actions.complete(model: model, engines: engines) { openSettings() }
                } label: { Label("Compléter le cours", systemImage: "wand.and.stars") }
                    .help("Compléter le cours avec \(RunSettings.current().engineDisplayName) (⌘R)")
                    .disabled(!model.canComplete)
            }
        }
    }
}

/// Cadre qui s'affiche quand on survole la fenêtre avec un fichier.
struct DropHighlight: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .padding(8)
            Label("Dépose le PDF pour l'ouvrir", systemImage: "arrow.down.doc")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        }
        .allowsHitTesting(false)
    }
}

/// Récupère les fichiers d'un glisser-déposer.
enum DropLoader {
    @MainActor
    static func urls(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); found.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(found) }
        }
    }
}

// MARK: - Aperçu

struct PreviewPane: View {
    @EnvironmentObject var model: CoursModel

    var body: some View {
        ZStack(alignment: .top) {
            PDFPreview()
            if model.isDrawingZone {
                DrawingBanner()
                    .padding(.top, 12)
            }
            if case .running(let fraction, let label) = model.analysis {
                AnalysisOverlay(fraction: fraction, label: label)
            }
        }
    }
}

struct DrawingBanner: View {
    @EnvironmentObject var model: CoursModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
            Text("Tire un rectangle sur la page, autour de l'endroit à remplir.")
                .font(.callout.weight(.medium))
            Button("Annuler") { model.cancelDrawingZone() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.6), lineWidth: 1))
        .shadow(radius: 4, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mode ajout de zone : tire un rectangle sur la page")
    }
}

struct AnalysisOverlay: View {
    let fraction: Double
    let label: String

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 12) {
                ProgressView(value: min(max(fraction, 0), 1))
                    .frame(width: 260)
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Analyse en cours : \(label)")
    }
}
