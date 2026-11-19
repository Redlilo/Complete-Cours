import Foundation
import Security

/// Accès au trousseau macOS pour la clé API Claude. La clé n'est jamais écrite ailleurs
/// (ni UserDefaults, ni fichier, ni journal).
enum Keychain {
    static let service = "fr.complete-cours.app"
    static let claudeAccount = "claude-api-key"

    /// Erreur du trousseau, avec une phrase française utile.
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            switch status {
            case errSecUserCanceled:
                return "L'accès au trousseau a été refusé. Autorise Complète-Cours à utiliser la clé, puis réessaie."
            case errSecAuthFailed, errSecInteractionNotAllowed:
                return "Le trousseau est verrouillé. Déverrouille-le (ouvre une session ou saisis ton mot de passe), puis réessaie."
            case errSecMissingEntitlement:
                return "Le trousseau refuse l'accès à cette application (signature manquante)."
            default:
                return "Le trousseau du Mac a renvoyé une erreur (code \(status))."
            }
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Y a-t-il une entrée ? Ne lit pas le secret : aucune demande d'autorisation.
    static func exists(service: String = Keychain.service, account: String = claudeAccount) -> Bool {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Lit le secret. Renvoie nil s'il n'y en a pas ; lève une erreur si le trousseau refuse l'accès.
    static func read(service: String = Keychain.service, account: String = claudeAccount) throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Enregistre (ou remplace) le secret.
    static func save(_ secret: String, service: String = Keychain.service, account: String = claudeAccount) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(service: service, account: account)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure(status: update) }
        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    /// Supprime le secret (sans erreur s'il n'y en avait pas).
    static func delete(service: String = Keychain.service, account: String = claudeAccount) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
