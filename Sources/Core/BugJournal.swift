import Foundation

// Historique des bugs du « back » (moteur IA, dépôt automatique, écoute, suivi des prix, indexation…).
// Garde seulement le TEXTE des erreurs (jamais le contenu d'un cours ni d'un document), sur ton Mac, dans
// Application Support/<identifiant de l'app>/historique-bugs.json. Les 300 derniers sont conservés.

struct BugEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date          // première apparition
    var derniere: Date      // dernière apparition (une même erreur répétée n'ajoute qu'une ligne)
    var source: String      // « Moteur IA », « Dépôt automatique »…
    var message: String
    var fois: Int = 1
}

final class BugJournal: @unchecked Sendable {
    static let shared = BugJournal()
    static let changed = Notification.Name("BugJournalChanged")

    private let verrou = NSLock()
    private let url: URL
    private static let maximum = 300

    init(url: URL? = nil) {
        if let url { self.url = url; return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.url = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "fr.complete-cours.app", isDirectory: true)
            .appendingPathComponent("historique-bugs.json")
    }

    /// Texte propre : sans retours à la ligne, sans le nom de ton dossier personnel, au plus 300 caractères.
    static func nettoyer(_ s: String) -> String {
        var t = s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        t = t.replacingOccurrences(of: #"sk-[A-Za-z0-9_\-]{6,}"#, with: "…", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[A-Za-z0-9_\-]{32,}"#, with: "…", options: .regularExpression)
        t = t.replacingOccurrences(of: #"/Users/[^\s/]+"#, with: "/Users/…", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[^\s"«»]*\.pdf"#, with: "<fichier>", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 300 ? String(t.prefix(300)) + "…" : t
    }

    func noter(_ source: String, _ message: String, maintenant: Date = Date()) {
        let m = Self.nettoyer(message)
        guard !m.isEmpty else { return }
        verrou.lock()
        var liste = lireSansVerrou()
        if let i = liste.firstIndex(where: { $0.source == source && $0.message == m && maintenant.timeIntervalSince($0.derniere) < 3600 }) {
            liste[i].fois += 1
            liste[i].derniere = maintenant
        } else {
            liste.insert(BugEntry(date: maintenant, derniere: maintenant, source: source, message: m), at: 0)
        }
        if liste.count > Self.maximum { liste.removeLast(liste.count - Self.maximum) }
        ecrireSansVerrou(liste)
        verrou.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    func toutes() -> [BugEntry] {
        verrou.lock(); defer { verrou.unlock() }
        return lireSansVerrou().sorted { $0.derniere > $1.derniere }
    }

    func effacer() {
        verrou.lock(); ecrireSansVerrou([]); verrou.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    private func lireSansVerrou() -> [BugEntry] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let l = try? dec.decode([BugEntry].self, from: d) { return l }
        // fichier corrompu : mis de côté (jamais écrasé en silence) pour que l'historique puisse être récupéré
        if !d.isEmpty { try? FileManager.default.removeItem(at: url.appendingPathExtension("corrompu")); try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrompu")) }
        return []
    }

    private func ecrireSansVerrou(_ l: [BugEntry]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(l) else { return }
        try? PrivateFiles.write(d, to: url)
    }

    // MARK: Conseil automatique selon le message (diagnostic d'un bug)

    /// Cause probable et remède, d'après le texte de l'erreur. nil si rien de précis à dire.
    static func conseil(pour message: String) -> String? {
        let m = message.lowercased()
        let regles: [([String], String)] = [
            (["limite", "quota", "429", "usage limit", "surcharg", "overloaded"],
             "Limite d'utilisation de l'IA atteinte : attends le renouvellement (quelques heures) ou choisis un moteur plus léger dans les Réglages."),
            (["timed out", "timeout", "délai", "pas répondu", "hors connexion", "offline", "not connected", "connexion"],
             "Pas de réseau ou site trop lent : vérifie ta connexion, puis relance. Un 2ᵉ essai automatique est déjà fait."),
            (["robot", "captcha", "403", "accès refusé", "access denied"],
             "Le site bloque les lectures automatiques : l'app réessaie avec WebKit ; sinon saisis l'offre à la main."),
            (["autoris", "permission", "not permitted", "confidentialité", "tcc"],
             "macOS bloque l'accès : Réglages Système › Confidentialité et sécurité, puis autorise l'app (Fichiers et dossiers, Micro)."),
            (["micro"],
             "Problème de micro : vérifie l'autorisation (Réglages Système › Confidentialité › Micro) et le volume d'entrée."),
            (["dictée", "langue", "locale", "speech", "transcription"],
             "La dictée en français n'est pas prête : Réglages Système › Clavier › Dictée, ajoute le français et attends le téléchargement."),
            (["claude", "not logged", "connect", "log in", "login", "authentic"],
             "Le compte Claude n'est pas connecté : Réglages › Moteur › Claude (mon compte) › Me connecter."),
            (["clé", "api key", "401", "invalid x-api-key", "unauthorized"],
             "Clé API absente ou refusée : recolle-la dans Réglages › Moteur."),
            (["dossier", "introuvable", "no such file", "n'existe pas"],
             "Un dossier ou un fichier a bougé : choisis de nouveau le dossier de tes cours dans la Bibliothèque."),
            (["disque", "espace", "no space"],
             "Le disque est plein : libère de la place (au moins 2 Go)."),
            (["illisible", "décod", "json", "format"],
             "Réponse de l'IA illisible : relance, c'est souvent passager. Si ça se répète, essaie un autre modèle."),
        ]
        return regles.first { r in r.0.contains { m.contains($0) } }?.1
    }
}
