import SwiftUI
import AppKit
import AVFoundation
import Speech

// Réglages › Diagnostic : vérifie le « back » de l'app (moteur IA, dossiers, dictée, micro, dépôt automatique, disque…)
// et montre l'historique des bugs notés par l'app, avec la cause probable et le remède de chacun.

struct DiagnosticCheck: Identifiable {
    enum Niveau { case ok, attention, probleme }
    let id = UUID()
    var titre: String
    var niveau: Niveau
    var detail: String

    var icone: String {
        switch niveau { case .ok: return "checkmark.circle.fill"; case .attention: return "exclamationmark.triangle.fill"; case .probleme: return "xmark.octagon.fill" }
    }
    var couleur: Color {
        switch niveau { case .ok: return .green; case .attention: return .orange; case .probleme: return .red }
    }
}

@MainActor
enum BackendDiagnostic {
    static func lancer() async -> [DiagnosticCheck] {
        var r: [DiagnosticCheck] = []
        func ajouter(_ t: String, _ n: DiagnosticCheck.Niveau, _ d: String) { r.append(DiagnosticCheck(titre: t, niveau: n, detail: d)) }

        // Dossier des cours
        let library = LibraryModel.shared
        var estDossier: ObjCBool = false
        if FileManager.default.fileExists(atPath: library.root.path, isDirectory: &estDossier), estDossier.boolValue {
            ajouter("Dossier des cours", .ok, "\(library.files.count) PDF trouvés")
        } else {
            ajouter("Dossier des cours", .probleme, "Le dossier est introuvable : choisis-le de nouveau dans la Bibliothèque.")
        }

        // Moteur IA (sans appel réseau : seulement la configuration)
        let reglages = RunSettings.current()
        do {
            _ = try EngineFactory.make(reglages)
            ajouter("Moteur IA", .ok, "Prêt : \(reglages.engine.rawValue)")
        } catch {
            ajouter("Moteur IA", .probleme, "\(Fr.sentence(error.localizedDescription)) Ouvre les Réglages pour choisir ou réparer le moteur d'IA.")
        }

        // Dictée française et micro (écouter un cours)
        if SpeechTranscriber.isAvailable {
            let installees = await SpeechTranscriber.installedLocales
            if installees.contains(where: { $0.identifier.hasPrefix("fr") }) {
                ajouter("Dictée en français", .ok, "Installée sur ce Mac.")
            } else {
                ajouter("Dictée en français", .probleme, "Pas installée : Réglages Système › Clavier › Dictée, ajoute le français.")
            }
        } else {
            ajouter("Dictée en français", .probleme, "Le moteur de dictée de ce Mac n'est pas disponible.")
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: ajouter("Micro", .ok, "Autorisé.")
        case .notDetermined: ajouter("Micro", .attention, "Pas encore demandé : macOS le demandera au premier « Commencer le cours ».")
        default: ajouter("Micro", .probleme, "Refusé : Réglages Système › Confidentialité et sécurité › Micro, autorise l'app.")
        }

        // Dépôt automatique
        let depot = AutoIntake.shared
        if let p = depot.problem { ajouter("Dépôt automatique", .probleme, p) }
        else if depot.enabled { ajouter("Dépôt automatique", .ok, "Actif sur « \(depot.folderLabel) »" + (depot.waiting > 0 ? " · \(depot.waiting) PDF en attente" : "")) }
        else { ajouter("Dépôt automatique", .ok, "Désactivé (réglage choisi).") }

        // Indexation du contenu
        if let p = library.indexProgress { ajouter("Index du contenu", .attention, "Lecture en cours : \(p.done) cours sur \(p.total).") }
        else { ajouter("Index du contenu", .ok, "À jour.") }

        // Journal et dossier de données
        let donnees = CourseLedger.defaultDirectory
        try? FileManager.default.createDirectory(at: donnees, withIntermediateDirectories: true)
        if FileManager.default.isWritableFile(atPath: donnees.path) { ajouter("Données de l'app", .ok, "Dossier en écriture : journal des rangements et historiques.") }
        else { ajouter("Données de l'app", .probleme, "Impossible d'écrire dans le dossier de données de l'app.") }

        // Disque
        let libre = (try? library.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        if let libre {
            let go = Double(libre) / 1_000_000_000
            let t = String(format: "%.0f Go libres", go)
            ajouter("Espace disque", go < 1 ? .probleme : (go < 5 ? .attention : .ok), t)
        }

        #if COMPTE_PERSO
        r += await diagnosticSuivi()
        #endif

        // Bugs des dernières 24 heures
        let recents = BugJournal.shared.toutes().filter { Date().timeIntervalSince($0.derniere) < 86_400 }
        if recents.isEmpty { ajouter("Bugs des dernières 24 h", .ok, "Aucun.") }
        else { ajouter("Bugs des dernières 24 h", .attention, "\(recents.count) type(s) d'erreur : voir l'historique ci-dessous.") }
        return r
    }

    #if COMPTE_PERSO
    private static func diagnosticSuivi() async -> [DiagnosticCheck] {
        var r: [DiagnosticCheck] = []
        let h = SuiviMacDisque.charger()
        if let dernier = h.releves.last {
            let heures = Int(Date().timeIntervalSince(dernier.date) / 3600)
            r.append(DiagnosticCheck(titre: "Suivi MacBook : dernier relevé", niveau: heures > 30 ? .attention : .ok,
                                     detail: "Il y a \(heures) h · \(h.releves.count) relevé(s) · \(dernier.offres.count) offres"
                                     + (heures > 30 ? " — celui de 9 h n'a pas eu lieu (Mac éteint ou en veille ?)." : "")))
            let vides = dernier.comptes.filter { $0.value == 0 }.keys.sorted()
            if !dernier.erreurs.isEmpty || !vides.isEmpty {
                let t = (dernier.erreurs.keys.sorted().map { "\($0) (erreur)" } + vides.map { "\($0) (0 offre)" }).joined(separator: ", ")
                r.append(DiagnosticCheck(titre: "Suivi MacBook : sites", niveau: .attention, detail: t))
            } else {
                r.append(DiagnosticCheck(titre: "Suivi MacBook : sites", niveau: .ok, detail: "Tous les sites ont répondu au dernier relevé."))
            }
        } else {
            r.append(DiagnosticCheck(titre: "Suivi MacBook : dernier relevé", niveau: .attention, detail: "Aucun relevé enregistré."))
        }
        let charge = await Task.detached { () -> Bool in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["list", "fr.suivi-macbook-ia"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
        }.value
        r.append(DiagnosticCheck(titre: "Suivi MacBook : tâche de 9 h", niveau: charge ? .ok : .attention,
                                 detail: charge ? "La tâche quotidienne est installée." : "La tâche quotidienne n'est pas chargée : le relevé automatique de 9 h ne se fera pas."))
        return r
    }
    #endif

    /// Rapport texte (copiable) : vérifications + historique des bugs.
    static func rapport(_ checks: [DiagnosticCheck], _ bugs: [BugEntry]) -> String {
        let f = Date.FormatStyle.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "fr_FR"))
        var s = "DIAGNOSTIC — \(AppIdentity.nom) — \(Date().formatted(f))\n\n"
        for c in checks { s += "[\(c.niveau == .ok ? "OK" : c.niveau == .attention ? "ATTENTION" : "PROBLÈME")] \(c.titre) : \(c.detail)\n" }
        s += "\nHISTORIQUE DES BUGS (\(bugs.count))\n"
        for b in bugs.prefix(50) {
            s += "- \(b.derniere.formatted(f)) · \(b.source)\(b.fois > 1 ? " ×\(b.fois)" : "") : \(b.message)\n"
            if let c = BugJournal.conseil(pour: b.message) { s += "    → \(c)\n" }
        }
        return s
    }
}

// MARK: - Écran (onglet des Réglages)

struct DiagnosticSettings: View {
    @State private var checks: [DiagnosticCheck] = []
    @State private var bugs: [BugEntry] = []
    @State private var enCours = false
    @State private var copie = false
    @State private var confirmerVidage = false

    private static let format = Date.FormatStyle.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "fr_FR"))

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Diagnostic du back").font(.title3.weight(.semibold))
                    Spacer()
                    if enCours { ProgressView().controlSize(.small) }
                    Button("Relancer") { Task { await lancer() } }.disabled(enCours)
                    Button(copie ? "Copié" : "Copier le rapport") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(BackendDiagnostic.rapport(checks, bugs), forType: .string)
                        copie = true
                        Task { try? await Task.sleep(for: .seconds(2)); copie = false }
                    }.disabled(checks.isEmpty)
                }
                GroupBox("Vérifications") {
                    VStack(alignment: .leading, spacing: 8) {
                        if checks.isEmpty { Text("Vérification en cours…").foregroundStyle(.secondary) }
                        ForEach(checks) { c in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: c.icone).foregroundStyle(c.couleur).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.titre).font(.callout.weight(.semibold))
                                    Text(c.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        if bugs.isEmpty { Text("Aucun bug noté pour l'instant.").foregroundStyle(.secondary) }
                        ForEach(bugs.prefix(40)) { b in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(b.source).font(.caption.weight(.semibold))
                                    Text(b.derniere.formatted(Self.format)).font(.caption).foregroundStyle(.secondary)
                                    if b.fois > 1 { Text("×\(b.fois)").font(.caption.weight(.bold)).foregroundStyle(.orange) }
                                }
                                Text(b.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if let c = BugJournal.conseil(pour: b.message) {
                                    Label(c, systemImage: "lightbulb").font(.caption).foregroundStyle(.blue).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Divider()
                        }
                        if !bugs.isEmpty { Button("Vider l'historique", role: .destructive) { confirmerVidage = true } }
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("Historique des bugs") }
                Text("L'app note seulement le texte des erreurs (jamais le contenu de tes cours), sur ton Mac. Les 300 dernières sont gardées.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .confirmationDialog("Vider l'historique des bugs ?", isPresented: $confirmerVidage, titleVisibility: .visible) {
            Button("Vider l'historique", role: .destructive) { BugJournal.shared.effacer() }
            Button("Annuler", role: .cancel) {}
        } message: { Text("Les erreurs notées seront effacées de ton Mac.") }
        .task { bugs = BugJournal.shared.toutes(); await lancer() }
        .onReceive(NotificationCenter.default.publisher(for: BugJournal.changed)) { _ in bugs = BugJournal.shared.toutes() }
    }

    private func lancer() async {
        enCours = true
        checks = await BackendDiagnostic.lancer()
        bugs = BugJournal.shared.toutes()
        enCours = false
    }
}
