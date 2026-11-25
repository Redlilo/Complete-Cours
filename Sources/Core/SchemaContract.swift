import Foundation
import CoreGraphics

// « Schémas électriques » : CONTRAT partagé (types seulement, aucune logique).
// - SchemaSymbols.swift / SchemaRenderer.swift : dessin des symboles normalisés dans le PDF (agent « dessin »)
// - SchemaEngine.swift : appel à Claude Opus 5.5 UNIQUEMENT, qui renvoie un `SchemaElectrique` (agent « moteur »)
// - Zone.schema, ZoneKind.schema, interface, modèles d'exemple : intégration dans Complète-Cours (agent « intégration »)
//
// Principe : Opus ne dessine pas de pixels. Il choisit des symboles normalisés (NF EN 60617, programme de Seconde MTNE),
// les place sur une GRILLE (unités de grille, origine en haut à gauche de la zone, x vers la droite, y vers le bas)
// et décrit les liaisons. L'app dessine le tout en vectoriel : les symboles sont toujours justes.

/// Symboles disponibles (Seconde MTNE : habitat, tableau électrique, commande de moteur, électronique de base).
/// La valeur brute est ce qu'Opus écrit dans le JSON.
enum SchemaSymbolType: String, Codable, CaseIterable, Identifiable {
    // repères d'alimentation
    case phase, neutre, terre
    // protection et sectionnement
    case sectionneur, interrupteurSectionneur, disjoncteur, disjoncteurDifferentiel, fusible, relaisThermique
    // commande
    case interrupteur, vaEtVient, boutonPoussoirNO, boutonPoussoirNF, arretUrgence
    // récepteurs et signalisation
    case lampe, voyant, sonnerie, priseCourant
    // automatismes d'habitat
    case detecteurPresence, minuterie, telerupteur
    // commande de moteur
    case contacteurBobine, contactNO, contactNF, contactPuissance
    case moteurMono, moteurTri
    // composants
    case transformateur, resistance, condensateur, diode, del
    // mesure
    case ampermetre, voltmetre, compteurEnergie
    // connexions
    case jonction, borne

    var id: String { rawValue }
}

/// Un symbole placé sur la grille. `x`, `y` : CENTRE du symbole en unités de grille. `rotation` : 0, 90, 180 ou 270 degrés
/// (sens horaire ; 0 = symbole vertical, bornes en haut et en bas pour un dipôle).
/// `label` : repère écrit à côté (« Q1 », « KM1 », « L1 », « 230 V »…), vide si aucun.
struct SchemaSymbole: Codable, Hashable, Identifiable {
    var id: String
    var type: SchemaSymbolType
    var x: Double
    var y: Double
    var rotation: Int = 0
    var label: String = ""
}

/// Une liaison (fil). `de` et `vers` : une borne « id.borne » (ex. « Q1.b », « KM1.A1 ») ou un point de grille « x,y »
/// (ex. « 3.5,2 »). `via` : points de passage intermédiaires [x, y] ; les segments sont dessinés à l'horizontale ou à la
/// verticale (un coude est ajouté si deux points consécutifs ne sont pas alignés).
struct SchemaFil: Codable, Hashable {
    var de: String
    var vers: String
    var via: [[Double]] = []
}

/// Un texte libre sur la grille (repère de ligne « L1 », valeur « 16 A », titre…). `x`, `y` : début du texte.
struct SchemaTexte: Codable, Hashable {
    var texte: String
    var x: Double
    var y: Double
}

/// Ce qu'Opus renvoie pour UNE zone « schéma » : seulement ce qu'il faut AJOUTER à ce que la page montre déjà.
/// `largeurGrille` × `hauteurGrille` : taille de la zone en unités de grille (donnée dans la demande, à ne pas changer).
struct SchemaElectrique: Codable, Hashable {
    var largeurGrille: Double
    var hauteurGrille: Double
    var symboles: [SchemaSymbole] = []
    var fils: [SchemaFil] = []
    var textes: [SchemaTexte] = []
    /// Une phrase de l'IA : ce qu'elle a dessiné et ce qu'elle n'est pas sûre (affichée dans la liste des zones).
    var remarque: String = ""
}

/// Un exemple déjà rempli montré à Opus (une page de cours avec un schéma juste), pour imiter le style et les bons symboles.
struct SchemaExemple: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var titre: String                // ex. « Va-et-vient – cours chap. 3 »
    var note: String = ""            // précisions de l'élève (« ici le neutre est en bleu »)
    var fichierImage: String         // nom du JPEG dans le dossier des exemples
}

/// Une demande de schéma pour une zone. Construite par l'intégration, consommée par `SchemaEngine`.
struct SchemaDemande {
    var nomDocument: String
    var numeroPage: Int                  // 1 = première page
    var numeroZone: Int                  // numéro affiché sur la page
    /// Image JPEG de la page ENTIÈRE avec les numéros de zones (contexte : consigne, partie déjà dessinée).
    var pageJPEG: Data
    /// Image JPEG du CADRE de la zone seul (un peu agrandi), avec une grille numérotée par-dessus (unités de grille).
    var cadreGrilleJPEG: Data
    var largeurGrille: Double
    var hauteurGrille: Double
    /// Texte voisin de la zone (consigne de l'exercice).
    var consigne: String
    /// Exemples déjà remplis (images JPEG + titre + note), au plus 3.
    var exemples: [(exemple: SchemaExemple, jpeg: Data)]
}

enum SchemaErreur: LocalizedError {
    case indisponible(String)       // pas de clé API ni de compte : Opus 5.5 est le seul moteur permis pour les schémas
    case refuse(String)
    case illisible(String)
    case autre(String)

    var errorDescription: String? {
        switch self {
        case .indisponible(let m), .refuse(let m), .illisible(let m), .autre(let m): return m
        }
    }
}
