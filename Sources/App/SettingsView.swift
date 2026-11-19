import SwiftUI
import AppKit

let consoleURL = URL(string: "https://console.anthropic.com")!

/// Coût indicatif par page, à côté de chaque modèle (le plus cher et le moins cher sont annoncés dans l'accueil).
func costNote(for modelID: String) -> String {
    switch modelID {
    case "claude-opus-5-5": return "jusqu'à environ 7 centimes par page"
    case "claude-haiku-5-5": return "à partir d'environ 0,2 centime par page"
    default: return "entre les deux"
    }
}

/// Réglages (⌘,) : moteur, écriture, profil de l'élève. Tout est dans UserDefaults sauf la clé (trousseau).
struct SettingsView: View {
    @AppStorage(Pref.settingsTab) private var tab = "moteur"

    var body: some View {
        TabView(selection: $tab) {
            EngineSettings()
                .tabItem { Label("Moteur", systemImage: "cpu") }
                .tag("moteur")
            WritingSettings()
                .tabItem { Label("Écriture", systemImage: "pencil.line") }
                .tag("ecriture")
            StudentSettings()
                .tabItem { Label("Élève", systemImage: "person.crop.circle") }
                .tag("eleve")
        }
        .frame(width: 560, height: 640)
    }
}

// MARK: - Moteur

struct EngineSettings: View {
    @EnvironmentObject var engines: EngineStatus
    @AppStorage(Pref.engine) private var engineRaw = Pref.defaultEngine.rawValue
    @AppStorage(Pref.claudeModel) private var modelID = ClaudeEngine.defaultModel

    private var kind: EngineKind { EngineKind(rawValue: engineRaw) ?? Pref.defaultEngine }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Moteur d'écriture", selection: $engineRaw) {
                    ForEach(EngineKind.pickable) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Moteur d'écriture")

                if kind == .claude {
                    claudeSection
                } else if kind == .claudeCode {
                    claudeCodeSection
                } else {
                    appleSection
                }
            }
            .padding(20)
        }
    }

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claude lit chaque page du cours en image et écrit les réponses : c'est le moteur le plus précis. Il utilise ta propre clé API, payée à l'usage (pas d'abonnement).")
                .fixedSize(horizontal: false, vertical: true)

            Label {
                Text("Confidentialité : avec Claude, les pages de ton PDF (image et texte) sont envoyées à Anthropic pour être complétées. Ne l'utilise pas pour un document personnel ou confidentiel. Rien n'est envoyé tant que tu ne demandes pas de réponses.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "paperplane.fill").foregroundStyle(.orange)
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            GroupBox("Clé API") {
                APIKeyField(modelID: modelID)
                    .padding(6)
            }

            GroupBox("Modèle") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ClaudeEngine.models) { m in
                        Button { modelID = m.id } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: modelID == m.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(modelID == m.id ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.label).fontWeight(.medium)
                                    Text("\(m.hint.prefix(1).uppercased() + m.hint.dropFirst()) · \(costNote(for: m.id))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(m.label), \(m.hint), \(costNote(for: m.id))")
                        .accessibilityAddTraits(modelID == m.id ? .isSelected : [])
                    }
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Où trouver une clé ? Crée un compte sur console.anthropic.com, ajoute un peu de crédit, puis crée une clé API. Un abonnement Claude (Pro, Max…) ne donne pas de clé : la console est un compte à part, facturé à l'usage.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                }
                Link("Ouvrir console.anthropic.com", destination: consoleURL)
                Label {
                    Text("Chacun sa clé : si tu partages la tienne avec un ami, vous payez la même facture.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "person.2.fill").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    /// Section « Claude (mon compte) » : tout son contenu n'existe que dans la version personnelle (CompteSettings.swift).
    private var claudeCodeSection: some View {
        #if COMPTE_PERSO
        CompteSettings()
        #else
        EmptyView()
        #endif
    }

    private var appleSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gratuit, hors ligne, mais moins précis : Apple Intelligence tourne sur ton Mac, rien n'est envoyé sur Internet, mais il ne voit que le texte de la page, pas l'image.")
                .fixedSize(horizontal: false, vertical: true)
            if let reason = engines.appleReason {
                Label {
                    Text(Fr.sentence(reason)).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .padding(12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                Button("Vérifier à nouveau") { engines.refresh() }
            } else {
                Label("Apple Intelligence est prêt sur ce Mac.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

/// Champ de la clé API : enregistrement dans le trousseau, test et suppression. La clé n'est jamais affichée.
struct APIKeyField: View {
    @EnvironmentObject var engines: EngineStatus
    let modelID: String
    @State private var entry = ""
    @State private var feedback: Feedback?
    @State private var testing = false

    struct Feedback {
        enum Kind { case ok, problem, info }
        var kind: Kind
        var text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SecureField(engines.claudeKeyPresent ? "Une clé est enregistrée (colle-en une autre pour la remplacer)" : "Colle ta clé API ici",
                            text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                    .accessibilityLabel("Clé API Claude")
                Button("Enregistrer") { save() }
                    .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 10) {
                Button { Task { await test() } } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text("Tester la clé") }
                }
                .disabled(testing || (!engines.claudeKeyPresent && entry.isEmpty))
                if engines.claudeKeyPresent {
                    Button("Supprimer la clé", role: .destructive) { remove() }
                }
                Spacer()
                Label(engines.claudeKeyPresent ? "Clé dans le trousseau du Mac" : "Aucune clé enregistrée",
                      systemImage: engines.claudeKeyPresent ? "lock.shield.fill" : "lock.open")
                    .font(.caption)
                    .foregroundStyle(engines.claudeKeyPresent ? Color.green : Color.secondary)
            }
            if let feedback {
                Label(feedback.text, systemImage: icon(feedback.kind))
                    .font(.callout)
                    .foregroundStyle(color(feedback.kind))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func icon(_ k: Feedback.Kind) -> String {
        switch k { case .ok: return "checkmark.circle.fill"; case .problem: return "xmark.octagon.fill"; case .info: return "info.circle.fill" }
    }
    private func color(_ k: Feedback.Kind) -> Color {
        switch k { case .ok: return .green; case .problem: return .red; case .info: return .secondary }
    }

    private func save() {
        let key = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if key.contains(where: { $0.isWhitespace }) {
            feedback = Feedback(kind: .problem, text: "La clé contient des espaces : colle-la en entier, sans rien d'autre.")
            return
        }
        do {
            try Keychain.save(key)
            entry = ""
            engines.refresh()
            feedback = Feedback(kind: .ok, text: "Clé enregistrée dans le trousseau de ton Mac. Clique sur « Tester la clé » pour vérifier qu'elle marche.")
        } catch {
            feedback = Feedback(kind: .problem, text: Fr.sentence(error.localizedDescription))
        }
    }

    private func remove() {
        do {
            try Keychain.delete()
            engines.refresh()
            feedback = Feedback(kind: .info, text: "La clé a été supprimée du trousseau.")
        } catch {
            feedback = Feedback(kind: .problem, text: Fr.sentence(error.localizedDescription))
        }
    }

    private func test() async {
        var key = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            do { key = try Keychain.read() ?? "" } catch {
                feedback = Feedback(kind: .problem, text: Fr.sentence(error.localizedDescription))
                return
            }
        }
        guard !key.isEmpty else {
            feedback = Feedback(kind: .problem, text: "Aucune clé à tester : colle d'abord ta clé.")
            return
        }
        testing = true
        feedback = Feedback(kind: .info, text: "Vérification de la clé auprès d'Anthropic…")
        let problem = await ClaudeEngine.checkKey(apiKey: key, model: modelID)
        testing = false
        if let problem {
            feedback = Feedback(kind: .problem, text: Fr.sentence(problem))
        } else {
            feedback = Feedback(kind: .ok, text: "La clé fonctionne.")
        }
    }
}

// MARK: - Écriture

struct WritingSettings: View {
    @AppStorage(Pref.humanize) private var humanize = Pref.defaultHumanize
    @AppStorage(Pref.writingStyle) private var styleKey = Pref.defaultStyle
    @AppStorage(Pref.flatten) private var flatten = Pref.defaultFlatten

    var body: some View {
        Form {
            Section {
                Toggle("Humaniser les réponses aux questions ouvertes", isOn: $humanize)
                Text("Les réponses aux questions ouvertes sont réécrites pour sonner comme un élève, sans changer le sens ni les nombres. Les textes à trous et les définitions restent exacts.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Style d'écriture") {
                Picker("Style", selection: $styleKey) {
                    ForEach(StyleChoice.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
                StylePreview(styleKey: styleKey)
            }
            Section {
                Toggle("Aplatir le PDF à l'export", isOn: $flatten)
                Text("Le texte écrit fait alors partie de la page : il ne peut plus être modifié ni effacé dans un autre logiciel. Sans cette option, les réponses restent des annotations modifiables dans Aperçu.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Exemple de l'écriture choisie.
struct StylePreview: View {
    let styleKey: String

    var body: some View {
        let style = WritingStyle.named(styleKey)
        let font = NSFont(name: style.fontName, size: style.maxSize + 3) ?? .systemFont(ofSize: style.maxSize + 3)
        Text("Le soleil est une énergie renouvelable.")
            .font(Font(font))
            .foregroundColor(Color(red: style.red, green: style.green, blue: style.blue))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            .accessibilityLabel("Exemple d'écriture")
    }
}

// MARK: - Élève

struct StudentSettings: View {
    @AppStorage(Pref.studentName) private var nom = ""
    @AppStorage(Pref.studentFirstName) private var prenom = ""
    @AppStorage(Pref.studentClass) private var classe = ""

    var body: some View {
        Form {
            Section {
                TextField("Nom", text: $nom)
                TextField("Prénom", text: $prenom)
                TextField("Classe", text: $classe, prompt: Text("par exemple 2de MTNE"))
            }
            Section {
                Text("Ces informations servent uniquement à remplir les champs « Nom », « Prénom » et « Classe » des fiches. Elles restent sur ton Mac, sauf si le cours contient un champ d'identité : elles sont alors transmises avec la page au moteur choisi (à Anthropic si c'est Claude).")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
