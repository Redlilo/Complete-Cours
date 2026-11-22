#if COMPTE_PERSO
import Foundation

// « Suivi MacBook IA » (variante personnelle seulement) : modèles de données.
// Un MacBook Pro à puce Max, 36 ou 48 Go de mémoire, vu chez un vendeur à un instant donné.

/// Le vendeur livre-t-il en France ?
enum SuiviLivraison: String, Codable {
    case oui, non, aVerifier

    var libelle: String {
        switch self {
        case .oui: return "Livré en France"
        case .non: return "Pas de livraison en France"
        case .aVerifier: return "Livraison à vérifier"
        }
    }
}

enum SuiviEtat: String, Codable {
    case neuf, reconditionneApple, reconditionneTiers, occasion

    var libelle: String {
        switch self {
        case .neuf: return "Neuf"
        case .reconditionneApple: return "Reconditionné Apple"
        case .reconditionneTiers: return "Reconditionné / occasion"
        case .occasion: return "Occasion (annonce)"
        }
    }
}

struct SuiviOffre: Codable, Identifiable, Hashable {
    var key: String              // identifiant stable chez le vendeur (référence produit)
    var source: String           // « Apple reconditionné », « LDLC »…
    var pays: String             // code pays du vendeur : FR, DE, NL…
    var etat: SuiviEtat
    var titre: String
    var puce: String             // « M5 Max »
    var ecran: Int               // 14 ou 16
    var gpu: Int?                // cœurs GPU, d'où la bande passante
    var ram: Int                 // Go
    var ssd: String              // « 2 To »
    var affichage: String        // « standard », « nano-texturé », « PROLED »
    var couleur: String
    var clavier: String          // AZERTY, QWERTZ, QWERTY…
    var prix: Double             // en euros, TTC, tel qu'affiché
    var prixOriginal: Double?
    var stock: String
    var url: String
    var livraison: SuiviLivraison
    var remarque: String
    var manuelle: Bool
    var ajoutee: Date?
    var grade: String? = nil     // état esthétique annoncé pour un reconditionné : Excellent, Bon, Moyen
    var ville: String? = nil     // annonce locale (Leboncoin) : ville du vendeur
    var distanceKm: Double? = nil // distance à Paris (Leboncoin)
    var vendeurPro: Bool? = nil  // annonce de professionnel (true) ou de particulier (false)

    var id: String { key }
}

/// Un passage de relevé : toutes les offres vues ce jour-là.
struct SuiviReleve: Codable {
    var date: Date
    var offres: [SuiviOffre]
    var erreurs: [String: String]    // source -> message
    var comptes: [String: Int]       // source -> nombre d'offres lues
}

struct SuiviHistorique: Codable {
    var releves: [SuiviReleve] = []
    var manuelles: [SuiviOffre] = []
}

struct SuiviFiltres: Codable, Equatable {
    var livrablesSeulement = true     // masque les offres que le vendeur ne livre pas en France
    var azertySeulement = false
    var memoire = 0                   // 0 = toutes ; sinon 36 ou 48 (Go)
    var parTranche = true             // true : offres comprises entre deux paliers ; false : tout ce qui coûte jusqu'au palier
}
#endif
