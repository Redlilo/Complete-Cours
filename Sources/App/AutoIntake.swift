import SwiftUI
import AppKit
import UserNotifications

// Dépôt automatique : l'app surveille un dossier (par défaut Téléchargements) et range toute seule les nouveaux PDF de cours.
// Désactivé par défaut. La logique (surveillance, rangement) est dans Sources/Core/FolderWatcher.swift.
//
// Branchement (à faire dans l'app, hors de ce fichier) :
//   - au lancement : AutoIntake.shared.resumeIfEnabled()   (relance la surveillance et rattrape les PDF arrivés pendant la fermeture)
//   - menu « Dépôt automatique… » : .sheet(isPresented:) { AutoIntakeSheet() }
//   - bandeau de repli (si les notifications sont refusées) : AutoIntakeBanner() en haut de la fenêtre principale

@MainActor
final class AutoIntake: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AutoIntake()

    static let enabledKey = "autoIntakeEnabled"
    static let folderKey = "autoIntakeFolder"
    static let recentKey = "autoIntakeRecent"
    nonisolated static let categoryID = "DEPOT_RANGE", undoActionID = "ANNULER"

    @Published private(set) var enabled: Bool
    @Published private(set) var folder: URL
    @Published private(set) var status = ""
    @Published private(set) var waiting = 0
    @Published private(set) var lastActivity: Date?
    @Published private(set) var notificationsAllowed = false
    /// Repli quand les notifications sont refusées ou indisponibles : texte + rangement à annuler.
    @Published private(set) var banner: (text: String, moveID: UUID?)?
    /// Ex. refus d'accès au dossier : explication en français.
    @Published private(set) var problem: String?

    private var watcher: FolderWatcher?
    private let defaults = UserDefaults.standard

    var stateURL: URL { CourseLedger.defaultDirectory.appendingPathComponent("depot-automatique.json") }
    var folderLabel: String { (folder.path as NSString).abbreviatingWithTildeInPath }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    override init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if let p = UserDefaults.standard.string(forKey: Self.folderKey), !p.isEmpty { folder = URL(fileURLWithPath: p, isDirectory: true) }
        else { folder = Self.defaultFolder }
        super.init()
        lastActivity = recentMoves(limit: 1).first?.date
        refreshStatus()
    }

    // MARK: Activation

    /// À appeler au lancement : relance la surveillance si l'élève l'avait activée.
    func resumeIfEnabled() {
        guard enabled, watcher == nil else { return }
        registerNotificationCategory()
        Task { notificationsAllowed = await requestAuthorization() }
        start(fresh: false)
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled || (on && watcher == nil) else { return }
        if on {
            guard canAccessFolder() else { enabled = false; defaults.set(false, forKey: Self.enabledKey); refreshStatus(); return }
            enabled = true; defaults.set(true, forKey: Self.enabledKey)
            registerNotificationCategory()
            Task { notificationsAllowed = await requestAuthorization() }
            start(fresh: true)
        } else {
            enabled = false; defaults.set(false, forKey: Self.enabledKey)
            watcher?.stop(); watcher = nil
            waiting = 0
        }
        refreshStatus()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.message = "Choisis le dossier où arrivent tes PDF (en général Téléchargements)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
    }

    func setFolder(_ url: URL) {
        folder = url.standardizedFileURL
        defaults.set(folder.path, forKey: Self.folderKey)
        guard enabled else { refreshStatus(); return }
        watcher?.stop(); watcher = nil
        if canAccessFolder() { start(fresh: true) } else { enabled = false; defaults.set(false, forKey: Self.enabledKey) }
        refreshStatus()
    }

    func retryWaiting() { watcher?.retryDeferred(); waiting = 0; refreshStatus() }

    private func canAccessFolder() -> Bool {
        // la première lecture déclenche la demande d'autorisation de macOS pour Téléchargements
        do { _ = try FileManager.default.contentsOfDirectory(atPath: folder.path); problem = nil; return true }
        catch {
            problem = "macOS n'a pas autorisé l'accès au dossier « \(folder.lastPathComponent) ». Ouvre Réglages Système › Confidentialité et sécurité › Fichiers et dossiers (ou Accès complet au disque), puis autorise \(AppIdentity.nom) pour ce dossier."
            return false
        }
    }

    private func start(fresh: Bool) {
        watcher?.stop()
        let w = FolderWatcher(folder: folder, stateURL: stateURL) { [weak self] url in
            await self?.handle(url) ?? .unavailable
        }
        watcher = w
        w.start(freshActivation: fresh)
    }

    // MARK: Un PDF arrive

    private func handle(_ url: URL) async -> IntakeOutcome {
        let generator = try? AnalysisEngine.generator()
        let result = await AutoIntakeProcessor.process(url, watchedFolder: folder, root: LibraryModel.shared.root,
                                                       ledger: .shared, generator: generator)
        switch result {
        case .filed(let record, let target, let name):
            remember(record.id)
            lastActivity = record.date
            MoveHistory.shared.reload()
            LibraryModel.shared.refresh()
            announce("« \(name) » rangé dans \(target.replacingOccurrences(of: "/", with: " › "))", moveID: record.id)
        case .unavailable:
            waiting = (watcher?.deferredCount ?? 0) + 1      // le fichier courant n'est pas encore compté par le surveillant
            let n = waiting
            announce("\(n) \(Fr.plural(n, "PDF attend", "PDF attendent")) d'être rangé\(n > 1 ? "s" : ""). Vérifie ton moteur d'IA dans les Réglages.", moveID: nil)
        case .notACourse, .failed: break
        }
        refreshStatus()
        return result.outcome
    }

    // MARK: Notifications

    private var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private func center() -> UNUserNotificationCenter? {
        guard canNotify else { return nil }
        return UNUserNotificationCenter.current()
    }

    private func registerNotificationCategory() {
        guard let c = center() else { return }
        c.delegate = self
        let undo = UNNotificationAction(identifier: Self.undoActionID, title: "Annuler le rangement", options: [])
        c.setNotificationCategories([UNNotificationCategory(identifier: Self.categoryID, actions: [undo], intentIdentifiers: [])])
    }

    private func requestAuthorization() async -> Bool {
        guard let c = center() else { return false }
        return (try? await c.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Notification (nom du fichier et dossier seulement), ou bandeau dans l'app si elle n'est pas possible.
    private func announce(_ text: String, moveID: UUID?) {
        if let c = center(), notificationsAllowed {
            let content = UNMutableNotificationContent()
            content.title = "Dépôt automatique"
            content.body = text
            content.sound = .default
            if let moveID { content.categoryIdentifier = Self.categoryID; content.userInfo = ["moveID": moveID.uuidString] }
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in }
        } else {
            banner = (text, moveID)
        }
    }

    func dismissBanner() { banner = nil }

    func undoBanner() {
        guard let id = banner?.moveID else { return }
        undo(id)
        banner = nil
    }

    func undo(_ id: UUID) { MoveHistory.shared.undo(id); refreshStatus() }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let isUndo = response.actionIdentifier == AutoIntake.undoActionID
        let raw = response.notification.request.content.userInfo["moveID"] as? String
        Task { @MainActor in
            if isUndo, let raw, let id = UUID(uuidString: raw) { AutoIntake.shared.undo(id) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    // MARK: Récents et état

    private var recentIDs: [UUID] { (defaults.stringArray(forKey: Self.recentKey) ?? []).compactMap(UUID.init(uuidString:)) }

    private func remember(_ id: UUID) {
        var ids = (defaults.stringArray(forKey: Self.recentKey) ?? [])
        ids.append(id.uuidString)
        defaults.set(Array(ids.suffix(50)), forKey: Self.recentKey)
    }

    /// Les derniers rangements faits par le dépôt automatique et encore annulables (les annulés disparaissent du journal).
    func recentMoves(limit: Int = 10) -> [MoveRecord] {
        let ids = Set(recentIDs)
        return Array(MoveHistory.shared.ledger.moves.filter { ids.contains($0.id) }.prefix(limit))
    }

    func refreshStatus() {
        if let problem, !enabled { status = problem; return }
        guard enabled else { status = "En pause : le dépôt automatique est désactivé."; return }
        var s = "Surveillance active sur « \(folderLabel) »."
        if let d = lastActivity {
            let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "fr_FR"); f.unitsStyle = .full
            s += " Dernière activité : \(f.localizedString(for: d, relativeTo: Date()))."
        } else { s += " Aucune activité pour l'instant." }
        status = s
    }
}

// MARK: - Fenêtre « Dépôt automatique »

struct AutoIntakeSheet: View {
    @ObservedObject private var intake = AutoIntake.shared
    @ObservedObject private var history = MoveHistory.shared
    @Environment(\.dismiss) private var dismiss

    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Dépôt automatique").font(.title2.weight(.semibold))
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            List {
                Section {
                    Toggle("Ranger automatiquement mes nouveaux cours", isOn: Binding(get: { intake.enabled }, set: { intake.setEnabled($0) }))
                        .toggleStyle(.switch)
                    HStack {
                        Text("Dossier surveillé").foregroundStyle(.secondary)
                        Text(intake.folderLabel).font(.body.weight(.medium))
                        Spacer()
                        Button("Choisir…") { intake.chooseFolder() }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: intake.enabled ? "eye.fill" : "pause.circle").foregroundStyle(intake.enabled ? .green : .secondary)
                        Text(intake.status).font(.callout)
                    }
                    if let p = intake.problem { Text(p).font(.callout).foregroundStyle(.orange) }
                    if intake.waiting > 0 {
                        HStack {
                            Text("\(intake.waiting) \(Fr.plural(intake.waiting, "PDF attend", "PDF attendent")) d'être rangé\(intake.waiting > 1 ? "s" : "") (IA indisponible).")
                                .font(.callout)
                            Spacer()
                            Button("Réessayer") { intake.retryWaiting() }
                        }
                    }
                }
                Section("Comment ça marche") {
                    Text("Quand un nouveau PDF apparaît dans ce dossier, l'app lit sa première page, demande à l'IA s'il s'agit d'un cours et dans quel dossier le ranger, puis le déplace. Un PDF qui n'est pas un cours (facture, billet…) reste où il est. Rien n'est jamais écrasé et chaque rangement peut être annulé. Seuls les PDF arrivés après l'activation sont rangés.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("macOS peut te demander d'autoriser l'accès au dossier Téléchargements : accepte pour que le dépôt automatique fonctionne. Les notifications sont aussi à autoriser ; sinon, un bandeau s'affiche dans l'app.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Derniers PDF rangés") {
                    let rows = recent
                    if rows.isEmpty { Text("Aucun PDF rangé automatiquement pour l'instant.").foregroundStyle(.secondary) }
                    ForEach(rows) { m in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.toURL.lastPathComponent).font(.body.weight(.medium)).lineLimit(2)
                                Text("→ " + (m.toURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Text(Self.formatter.string(from: m.date)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 8)
                            Button("Annuler ce rangement") { intake.undo(m.id) }.controlSize(.small)
                        }
                    }
                    if let msg = history.message { Text(msg).font(.callout) }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .onAppear { history.reload(); history.message = nil; intake.refreshStatus() }
    }

    private var recent: [MoveRecord] {
        let ids = Set(intake.recentMoves(limit: 50).map(\.id))
        return Array(history.moves.filter { ids.contains($0.id) }.prefix(10))
    }
}

/// Bandeau de repli : un PDF vient d'être rangé (ou attend) et les notifications ne sont pas disponibles.
struct AutoIntakeBanner: View {
    @ObservedObject private var intake = AutoIntake.shared

    var body: some View {
        if let b = intake.banner {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(.white)
                Text(b.text).font(.callout.weight(.medium)).foregroundStyle(.white).lineLimit(2)
                Spacer()
                if b.moveID != nil {
                    Button("Annuler le rangement") { intake.undoBanner() }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.blue)
                }
                Button { intake.dismissBanner() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.white)
                    .help("Masquer")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16).padding(.top, 8)
        }
    }
}
