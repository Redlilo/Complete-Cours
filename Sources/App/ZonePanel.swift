import SwiftUI
import AppKit

/// Panneau de droite : état du traitement, messages, liste des zones par page, boutons principaux.
struct ZonePanel: View {
    @EnvironmentObject var model: CoursModel
    @EnvironmentObject var engines: EngineStatus
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Pref.engine) private var engineRaw = Pref.defaultEngine.rawValue

    private var engineKind: EngineKind { EngineKind(rawValue: engineRaw) ?? Pref.defaultEngine }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        messages
                        zoneList
                    }
                    .padding(12)
                }
                .onChange(of: model.revealRequest) { _, request in
                    // un clic dans l'aperçu (ou une zone qui vient d'être tracée) fait défiler la liste jusqu'à la zone
                    guard let request, request.source != .list else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(request.zoneID, anchor: .center) }
                }
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Zones à remplir").font(.headline)
                Spacer()
                if model.isReady, model.zonesToFill > 0 {
                    Text("\(model.answeredCount) sur \(model.zonesToFill) remplies")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityLabel("\(Fr.answers(model.answeredCount)) sur \(model.zonesToFill)")
                }
            }
            Label {
                Text("Les textes à trous et les définitions restent exacts. Seules les questions ouvertes peuvent être humanisées.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: Messages (moteur, progression, erreurs)

    @ViewBuilder private var messages: some View {
        if let problem = engines.problem(for: engineKind), model.isReady, !model.isRunning,
           model.runProblem?.needsSettings != true {
            Banner(style: .warning, title: problem.title, text: problem.message) {
                Button("Ouvrir les Réglages") { openSettings() }
            }
        }
        if case .running(let progress, let zoneID) = model.run, zoneID == nil {
            RunProgressCard(progress: progress) { model.cancelRun() }
        }
        if let problem = model.runProblem {
            Banner(style: .error, title: "Le traitement s'est arrêté", text: problem.message,
                   dismiss: { model.dismissRunProblem() }) {
                if problem.needsSettings { Button("Ouvrir les Réglages") { openSettings() } }
            }
        }
        if let notice = model.notice {
            Banner(style: notice.style == .success ? .success : (notice.style == .warning ? .warning : .info),
                   title: nil, text: notice.text, dismiss: { model.dismissNotice() }) {
                if let url = notice.revealURL {
                    Button("Afficher dans le Finder") { model.revealInFinder(url) }
                }
                if notice.offersRetry, model.failedZoneCount > 0 {
                    Button("Réessayer les zones en erreur") { model.retryFailedZones() }
                        .disabled(model.isBusy)
                }
            }
        }
        if let skipped = model.skippedPagesMessage {
            Banner(style: .warning, title: nil, text: skipped)
        }
    }

    // MARK: Liste

    private var pages: [Int] { Array(Set(model.zones.map { $0.page })).sorted() }

    @ViewBuilder private var zoneList: some View {
        if model.isAnalyzing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Recherche des zones à remplir…").foregroundStyle(.secondary)
            }
            .padding(.vertical, 20)
        } else if model.zones.isEmpty {
            EmptyZonesView()
        } else {
            ForEach(pages, id: \.self) { page in
                Text("Page \(page + 1) sur \(model.pageCount)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .accessibilityAddTraits(.isHeader)
                ForEach(model.zones.filter { $0.page == page }) { zone in
                    ZoneRow(zone: zone).id(zone.id)
                }
            }
        }
    }

    // MARK: Pied : boutons principaux

    private var footer: some View {
        VStack(spacing: 8) {
            if model.isRunning {
                Button(role: .cancel) { model.cancelRun() } label: {
                    Label("Annuler le traitement", systemImage: "stop.circle").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            } else {
                Button {
                    Actions.complete(model: model, engines: engines) { openSettings() }
                } label: {
                    Label("Compléter le cours", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canComplete)
                .help("Écrire les réponses avec \(RunSettings.current().engineDisplayName)")
            }
            HStack {
                Button {
                    if model.isDrawingZone { model.cancelDrawingZone() } else { model.beginDrawingZone() }
                } label: {
                    Label(model.isDrawingZone ? "Annuler le tracé" : "Ajouter une zone", systemImage: "rectangle.dashed")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.canDrawZone && !model.isDrawingZone)
                Button { model.savePDF() } label: {
                    Label("Enregistrer le PDF complété…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.canSave)
            }
        }
        .padding(12)
    }
}

// MARK: - Éléments

struct EmptyZonesView: View {
    @EnvironmentObject var model: CoursModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.analysisSummary)
                .font(.headline)
            if model.canDrawZone {
                Text("Ce PDF n'a pas de trou que Complète-Cours reconnaît. Tu peux ajouter une zone à la main : clique sur « Ajouter une zone », puis tire un rectangle autour de l'endroit à remplir.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28).padding(.horizontal, 8)
    }
}

struct RunProgressCard: View {
    let progress: RunProgress
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progress.label).font(.callout.weight(.medium))
            ProgressView(value: min(max(progress.fraction, 0), 1))
            HStack {
                Text("\(Int((progress.fraction * 100).rounded())) %")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Annuler", action: cancel)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Traitement en cours : \(progress.label)")
    }
}

/// Encadré d'information, d'avertissement ou d'erreur, avec boutons facultatifs.
struct Banner<Actions: View>: View {
    enum Style { case info, success, warning, error }
    let style: Style
    let title: String?
    let text: String
    var dismiss: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions

    init(style: Style, title: String?, text: String, dismiss: (() -> Void)? = nil,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.style = style; self.title = title; self.text = text; self.dismiss = dismiss; self.actions = actions
    }

    private var color: Color {
        switch style {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
    private var symbol: String {
        switch style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                if let title { Text(title).font(.callout.weight(.semibold)) }
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                actions().controlSize(.small)
            }
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Fermer ce message")
            }
        }
        .padding(12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

extension Banner where Actions == EmptyView {
    init(style: Style, title: String?, text: String, dismiss: (() -> Void)? = nil) {
        self.init(style: style, title: title, text: text, dismiss: dismiss) { EmptyView() }
    }
}
