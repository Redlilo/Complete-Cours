import SwiftUI

/// Écran d'accueil du premier lancement (Claude choisi, aucune clé) : comment obtenir une clé et la coller.
struct WelcomeView: View {
    @EnvironmentObject var engines: EngineStatus
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.engine) private var engineRaw = Pref.defaultEngine.rawValue
    @State private var entry = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bienvenue dans Complète-Cours").font(.title2.weight(.semibold))
                    Text("Pour écrire les réponses, l'app utilise Claude. Il te faut une clé API : 3 petites étapes.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                step(1) {
                    HStack(spacing: 4) {
                        Text("Va sur")
                        Link("console.anthropic.com", destination: consoleURL)
                        Text("et crée un compte.")
                    }
                }
                step(2) { Text("Ajoute un peu de crédit : c'est du paiement à l'usage, environ 0,2 à 7 centimes par page selon le modèle.") }
                step(3) { Text("Crée une clé API, copie-la, puis colle-la ici.") }
            }

            HStack {
                SecureField("Colle ta clé API ici", text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                    .accessibilityLabel("Clé API Claude")
                Button("Coller") { paste() }
                    .help("Coller le contenu du presse-papiers")
                Button("Enregistrer") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let problem {
                Label(problem, systemImage: "xmark.octagon.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Un abonnement Claude (Pro, Max…) ne donne pas de clé API : la clé vient de la console, qui est facturée à part.",
                      systemImage: "key.fill")
                Label("La clé reste dans le trousseau de ton Mac. Les pages du PDF sont envoyées à Anthropic quand tu complètes un cours.",
                      systemImage: "lock.shield")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                if engines.appleReason == nil {
                    Button("Utiliser Apple Intelligence (gratuit, moins précis)") {
                        engineRaw = EngineKind.apple.rawValue
                        dismiss()
                    }
                }
                Spacer()
                Button("Plus tard") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private func step<Content: View>(_ n: Int, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)
            content().fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Étape \(n)")
    }

    private func paste() {
        if let text = NSPasteboard.general.string(forType: .string) {
            entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func save() {
        let key = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if key.contains(where: { $0.isWhitespace }) {
            problem = "La clé contient des espaces : colle-la en entier, sans rien d'autre."
            return
        }
        do {
            try Keychain.save(key)
            engineRaw = EngineKind.claude.rawValue
            engines.refresh()
            dismiss()
        } catch {
            problem = Fr.sentence(error.localizedDescription)
        }
    }
}
