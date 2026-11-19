import Foundation

/// Clés des réglages (UserDefaults) et valeurs par défaut.
/// La clé API Claude n'apparaît jamais ici : elle vit uniquement dans le trousseau (voir Keychain.swift).
enum Pref {
    static let engine = "engine"
    static let claudeModel = "claudeModel"
    static let humanize = "humanize"
    /// Après une complétion en lot, l'original vide est rangé dans « _Originaux avant completion ».
    static let archiveOriginals = "archiveOriginals"
    static let humanizeTone = "humanizeTone"
    /// Option (désactivée par défaut) : l'IA contrôle « vrai trou / pas un trou » pour les zones douteuses seulement.
    static let verifyDoubtfulHoles = "verifyDoubtfulHoles"
    static let writingStyle = "writingStyle"
    static let flatten = "flattenOnExport"
    static let studentName = "studentName"
    static let studentFirstName = "studentFirstName"
    static let studentClass = "studentClass"
    static let settingsTab = "settingsTab"
    static let recentFiles = "recentFiles"
    /// L'écran d'accueil (comment obtenir une clé Claude) a déjà été montré ou fermé.
    static let welcomeSeen = "welcomeSeen"
    /// Moteur « Claude (mon compte) » : modèle, effort et chemin du programme (ignorés par les autres moteurs).
    static let claudeCodeModel = "claudeCodeModel"
    static let claudeCodeEffort = "claudeCodeEffort"
    static let claudeCodePath = "claudeCodePath"
    #if COMPTE_PERSO
    /// Après la complétion, Opus relit les pages remplies (version personnelle seulement ; consomme plus de quota).
    static let verifyAfterCompletion = "verifyAfterCompletion"
    static func verifyEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: verifyAfterCompletion) as? Bool ?? false
    }
    #endif

    static let defaultHumanize = true
    static let defaultStyle = "bleu"
    static let defaultFlatten = true

    /// Moteur proposé tant que l'élève n'a rien choisi : Claude (le plus précis). Apple Intelligence reste
    /// disponible dans les Réglages comme moteur de secours (gratuit, hors ligne, moins précis).
    static var defaultEngine: EngineKind { .claude }

    /// À appeler au lancement, avant l'affichage de la moindre vue.
    static func registerDefaults() {
        var defaults: [String: Any] = [
            engine: defaultEngine.rawValue,
            claudeModel: ClaudeEngine.defaultModel,
            humanize: defaultHumanize,
            humanizeTone: HumanizeTone.eleve.rawValue,
            writingStyle: defaultStyle,
            flatten: defaultFlatten,
            claudeCodeModel: "",
            claudeCodeEffort: "medium",
            claudeCodePath: "",
        ]
        #if COMPTE_PERSO
        defaults[claudeCodeModel] = ClaudeCodeEngine.defaultModel
        defaults[verifyAfterCompletion] = false
        #endif
        UserDefaults.standard.register(defaults: defaults)
    }
}

/// Moteur d'écriture choisi dans les Réglages.
enum EngineKind: String, CaseIterable, Identifiable {
    case claude
    case apple
    /// « Claude (mon compte) » : n'existe que dans la version personnelle (#if COMPTE_PERSO). Le cas est toujours
    /// déclaré pour que les `switch` restent exhaustifs.
    case claudeCode

    var id: String { rawValue }

    /// Les moteurs proposés dans le sélecteur : « Claude (mon compte) » seulement dans la version personnelle.
    static var pickable: [EngineKind] {
        #if COMPTE_PERSO
        return allCases
        #else
        return allCases.filter { $0 != .claudeCode }
        #endif
    }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .apple: return "Apple Intelligence"
        case .claudeCode: return "Claude (mon compte)"
        }
    }

    /// Ce que le moteur lit : Claude reçoit l'image des pages, Apple Intelligence seulement le texte
    /// (voir `CompletionEngine.usesImages`). Sert à décider si l'analyse doit lire les scans par OCR.
    var needsPageText: Bool { self == .apple }
}

/// Styles d'écriture proposés dans les Réglages (clés de `WritingStyle.named`).
enum StyleChoice: String, CaseIterable, Identifiable {
    case bleu
    case noir
    case manuscrit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bleu: return "Bleu (imprimé)"
        case .noir: return "Noir (imprimé)"
        case .manuscrit: return "Manuscrit"
        }
    }
}

/// Instantané des réglages au moment où l'on lance un traitement.
struct RunSettings {
    var engine: EngineKind
    var claudeModel: String
    var humanize: Bool
    var humanizeTone: HumanizeTone = .eleve
    var styleKey: String
    var flatten: Bool
    var student: StudentProfile
    /// Réglages du moteur « Claude (mon compte) » (ignorés par les autres moteurs).
    var claudeCodeModel: String = ""
    var claudeCodeEffort: String = "medium"
    var claudeCodePath: String = ""

    var style: WritingStyle { WritingStyle.named(styleKey) }

    /// Nom du moteur tel qu'on l'affiche à l'élève (« Claude Opus 5.5 », « Apple Intelligence »).
    var engineDisplayName: String {
        switch engine {
        case .apple: return "Apple Intelligence"
        case .claude: return ClaudeEngine.models.first { $0.id == claudeModel }?.label ?? claudeModel
        case .claudeCode: return EngineKind.claudeCode.title
        }
    }

    static func current(_ defaults: UserDefaults = .standard) -> RunSettings {
        RunSettings(
            engine: EngineKind(rawValue: defaults.string(forKey: Pref.engine) ?? "") ?? Pref.defaultEngine,
            claudeModel: defaults.string(forKey: Pref.claudeModel) ?? ClaudeEngine.defaultModel,
            humanize: defaults.object(forKey: Pref.humanize) as? Bool ?? Pref.defaultHumanize,
            humanizeTone: HumanizeTone(rawValue: defaults.string(forKey: Pref.humanizeTone) ?? "") ?? .eleve,
            styleKey: defaults.string(forKey: Pref.writingStyle) ?? Pref.defaultStyle,
            flatten: defaults.object(forKey: Pref.flatten) as? Bool ?? Pref.defaultFlatten,
            student: StudentProfile(
                nom: defaults.string(forKey: Pref.studentName) ?? "",
                prenom: defaults.string(forKey: Pref.studentFirstName) ?? "",
                classe: defaults.string(forKey: Pref.studentClass) ?? ""
            ),
            claudeCodeModel: defaults.string(forKey: Pref.claudeCodeModel) ?? "",
            claudeCodeEffort: defaults.string(forKey: Pref.claudeCodeEffort) ?? "medium",
            claudeCodePath: defaults.string(forKey: Pref.claudeCodePath) ?? ""
        )
    }
}

// MARK: - Moteur prêt ou non

/// Ce qui empêche d'utiliser le moteur choisi, en phrases françaises pour l'élève.
struct EngineProblem: Equatable {
    var title: String
    var message: String
}

/// État des moteurs, partagé entre le panneau et les Réglages. La clé n'est jamais lue ici
/// (seulement sa présence), donc aucune demande d'autorisation du trousseau.
@MainActor
final class EngineStatus: ObservableObject {
    static let shared = EngineStatus()

    @Published private(set) var claudeKeyPresent: Bool
    @Published private(set) var appleReason: String?

    init() {
        claudeKeyPresent = Keychain.exists()
        appleReason = AppleEngine.unavailabilityReason()
    }

    /// À rappeler quand quelque chose a pu changer (clé ajoutée, retour dans l'app après les Réglages Système).
    func refresh() {
        claudeKeyPresent = Keychain.exists()
        appleReason = AppleEngine.unavailabilityReason()
    }

    func problem(for kind: EngineKind) -> EngineProblem? {
        switch kind {
        case .claude:
            guard !claudeKeyPresent else { return nil }
            return EngineProblem(
                title: "Il manque ta clé Claude",
                message: "Ajoute ta clé API dans les Réglages pour utiliser Claude (elle reste dans le trousseau de ton Mac), ou choisis Apple Intelligence, gratuit et hors ligne.")
        case .apple:
            guard let reason = appleReason else { return nil }
            return EngineProblem(
                title: "Apple Intelligence n'est pas disponible",
                message: Fr.sentence(reason) + " Tu peux aussi choisir Claude dans les Réglages.")
        case .claudeCode:
            #if COMPTE_PERSO
            // L'état du compte se vérifie en lançant le programme (opération lente) : il est montré dans les Réglages.
            return nil
            #else
            return EngineProblem(
                title: "Moteur indisponible",
                message: "Ce moteur n'existe pas dans cette version de l'app. Choisis Claude ou Apple Intelligence dans les Réglages.")
            #endif
        }
    }
}

// MARK: - Fabrique de moteur

enum EngineFactory {
    /// Construit le moteur choisi. Lève `EngineError.unavailable` avec un message français quand on ne peut pas
    /// l'utiliser (pas de clé, Apple Intelligence indisponible, trousseau verrouillé).
    /// `claudeKey` et `claudeBaseURL` servent au mode de test (clé venue de l'environnement, serveur local).
    static func make(_ settings: RunSettings, claudeKey: String? = nil, claudeBaseURL: URL? = nil) throws -> CompletionEngine {
        switch settings.engine {
        case .apple:
            if let reason = AppleEngine.unavailabilityReason() {
                throw EngineError.unavailable(Fr.sentence(reason))
            }
            return AppleEngine()
        case .claude:
            var key = claudeKey ?? ""
            if claudeKey == nil {
                do { key = try Keychain.read() ?? "" } catch { throw EngineError.unavailable(error.localizedDescription) }
            }
            key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                throw EngineError.unavailable("Aucune clé API Claude n'est enregistrée. Ajoute-la dans les Réglages, onglet Moteur.")
            }
            return ClaudeEngine(apiKey: key, model: settings.claudeModel, baseURL: claudeBaseURL ?? ClaudeEngine.defaultBaseURL)
        case .claudeCode:
            #if COMPTE_PERSO
            guard let cli = ClaudeCodeEngine.locateCLI(override: settings.claudeCodePath) else {
                throw EngineError.unavailable(ClaudeCodeEngine.missingMessage)
            }
            return ClaudeCodeEngine(cli: cli, model: settings.claudeCodeModel, effort: settings.claudeCodeEffort)
            #else
            throw EngineError.unavailable("Ce moteur n'existe pas dans cette version de l'app.")
            #endif
        }
    }
}
