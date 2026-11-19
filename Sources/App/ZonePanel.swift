import SwiftUI
import AppKit

/// Panneau de droite : état du traitement, messages, liste des zones par page, boutons principaux.
struct ZonePanel: View {
    @EnvironmentObject var model: CoursModel
    @EnvironmentObject var engines: EngineStatus
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Pref.engine) private var engineRaw = Pref.defaultEngine.rawValue
    @AppStorage(Pref.humanize) private var humanize = Pref.defaultHumanize
    @AppStorage(Pref.humanizeTone) private var toneRaw = HumanizeTone.eleve.rawValue
    @AppStorage(Pref.verifyDoubtfulHoles) private var verifyDoubtful = false
    @State private var doubtfulFirst = false

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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Zones à remplir").font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                if model.isReady, model.zonesToFill > 0 {
                    Text("\(model.answeredCount) / \(model.zonesToFill)")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(model.answeredCount == model.zonesToFill ? Color.green : Color.accentColor)
                        .padding(.horizontal, 9).padding(.vertical, 2)
                        .background((model.answeredCount == model.zonesToFill ? Color.green : Color.accentColor).opacity(0.14), in: Capsule())
                        .accessibilityLabel("\(Fr.answers(model.answeredCount)) sur \(model.zonesToFill)")
                }
            }
            if model.isReady, model.zonesToFill > 0 {
                ProgressView(value: Double(model.answeredCount), total: Double(max(model.zonesToFill, 1)))
                    .tint(model.answeredCount == model.zonesToFill ? .green : .accentColor)
                    .accessibilityHidden(true)
                Text(model.answeredCount == model.zonesToFill
                     ? "Tout est rempli : relis, puis enregistre le PDF."
                     : "\(model.zonesToFill - model.answeredCount) zone(s) encore vide(s).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            humanizeCard
            if model.isReady { reliabilityCard }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(LinearGradient(colors: [Color.accentColor.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    /// Option visible : humaniser les réponses aux questions (jamais les définitions ni les mots à compléter) et son ton.
    private var humanizeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $humanize) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Humaniser les réponses aux questions").font(.subheadline.weight(.semibold))
                    Text("Définitions et mots à compléter : toujours exacts, jamais réécrits.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(model.isRunning)
            if humanize {
                Picker("Ton", selection: $toneRaw) {
                    ForEach(HumanizeTone.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(model.isRunning)
                .accessibilityLabel("Ton des réponses humanisées")
                Text((HumanizeTone(rawValue: toneRaw) ?? .eleve).detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(padding: 10)
    }

    /// Fiabilité des zones : douteuses d'abord, ignorer les douteuses, contrôle facultatif par l'IA, mémoire des corrections.
    @ViewBuilder private var reliabilityCard: some View {
        let doubtful = model.doubtfulCount
        if doubtful > 0 || model.learnedCount > 0 || verifyDoubtful {
            VStack(alignment: .leading, spacing: 8) {
                if doubtful > 0 {
                    Label("\(Fr.zones(doubtful)) à vérifier", systemImage: "questionmark.circle")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    Text("Le détecteur n'est pas sûr que ce soient de vrais trous (trait de pied de page, soulignement de titre…).")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Toggle("Douteuses d'abord", isOn: $doubtfulFirst).toggleStyle(.checkbox).font(.caption)
                        Spacer(minLength: 4)
                        Button("Ignorer les douteuses") { model.ignoreDoubtfulZones() }
                            .controlSize(.small)
                            .disabled(model.isBusy)
                            .help("Ignore toutes les zones à vérifier ; tu peux en remettre une en changeant son type")
                    }
                }
                Toggle(isOn: $verifyDoubtful) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Faire contrôler les zones douteuses par l'IA").font(.caption.weight(.medium))
                        Text("Facultatif : une requête de plus, seulement pour les pages qui ont des zones à vérifier.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(model.isRunning)
                if model.learnedCount > 0 {
                    HStack {
                        Text("\(model.learnedCount) correction\(model.learnedCount > 1 ? "s" : "") retenue\(model.learnedCount > 1 ? "s" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Oublier mes corrections") { model.forgetLearning() }
                            .controlSize(.small)
                            .disabled(model.isBusy)
                    }
                }
            }
            .card(padding: 10)
        }
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

    private func pageZones(_ page: Int) -> [Zone] {
        let list = model.zones.filter { $0.page == page }
        return doubtfulFirst ? ZoneTrust.doubtfulFirst(list) : list
    }

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
                    .padding(.top, 8).padding(.leading, 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(pageZones(page)) { zone in
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
                .font(.headline)
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
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.12)).frame(width: 72, height: 72)
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            Text(model.analysisSummary)
                .font(.headline)
                .multilineTextAlignment(.center)
            if model.canDrawZone {
                Text("Ce PDF n'a pas de trou que Complète-Cours reconnaît. Tu peux ajouter une zone à la main : clique sur « Ajouter une zone », puis tire un rectangle autour de l'endroit à remplir.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.beginDrawingZone() } label: {
                    Label("Ajouter une zone", systemImage: "rectangle.dashed.badge.record")
                }
                .buttonStyle(.bordered)
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
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.35)))
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
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }
}

extension Banner where Actions == EmptyView {
    init(style: Style, title: String?, text: String, dismiss: (() -> Void)? = nil) {
        self.init(style: style, title: title, text: text, dismiss: dismiss) { EmptyView() }
    }
}
