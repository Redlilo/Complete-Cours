import Foundation
import CoreGraphics
import CoreText

// Symboles normalisés (NF EN 60617, usage des manuels français) dessinés en vectoriel.
// Repère LOCAL d'un symbole : unités de grille, centre = (0,0), x vers la droite, y vers le BAS.
// Un symbole tient dans 2 unités de large × 3 de haut (sauf les 3 pôles, un peu plus larges à cause des lames).

// MARK: - Texte

/// Texte dessiné avec CoreText, toujours à l'endroit, quel que soit le sens de l'axe y du contexte.
enum SchemaPolice {
    enum Ancre { case gauche, centre, droite }

    /// Les polices minuscules (0,5 unité) sont instables : on travaille à taille ×100 puis on réduit.
    private static let agrandissement: CGFloat = 100

    private static func ligne(_ texte: String, taille: CGFloat) -> (CTLine, CTFont) {
        let police = CTFontCreateUIFontForLanguage(.system, taille * agrandissement, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, taille * agrandissement, nil)
        let attributs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): police,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return (CTLineCreateWithAttributedString(NSAttributedString(string: texte, attributes: attributs)), police)
    }

    /// Largeur du texte dans la même unité que `taille`.
    static func largeur(_ texte: String, taille: CGFloat) -> CGFloat {
        guard !texte.isEmpty, taille.isFinite, taille > 0 else { return 0 }
        let (l, _) = ligne(texte, taille: taille)
        return CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) / agrandissement
    }

    /// Dessine `texte` centré verticalement sur `y`, avec la couleur de REMPLISSAGE courante.
    static func dessiner(_ texte: String, ctx: CGContext, x: CGFloat, y: CGFloat, taille: CGFloat, ancre: Ancre = .gauche) {
        guard !texte.isEmpty, x.isFinite, y.isFinite, taille.isFinite, taille > 0 else { return }
        let (l, police) = ligne(texte, taille: taille)
        let w = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
        let dx: CGFloat = ancre == .gauche ? 0 : (ancre == .centre ? -w / 2 : -w)
        let hauteurCapitale = CTFontGetCapHeight(police)
        let t = ctx.ctm
        let retourne = (t.a * t.d - t.b * t.c) < 0
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        ctx.scaleBy(x: 1 / agrandissement, y: (retourne ? -1 : 1) / agrandissement)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: dx, y: -hauteurCapitale / 2)
        CTLineDraw(l, ctx)
        ctx.restoreGState()
    }
}

// MARK: - Noms, bornes

extension SchemaSymbolType {

    var nomFrancais: String {
        switch self {
        case .phase: return "Repère de phase (L)"
        case .neutre: return "Repère de neutre (N)"
        case .terre: return "Terre (PE)"
        case .sectionneur: return "Sectionneur"
        case .interrupteurSectionneur: return "Interrupteur-sectionneur"
        case .disjoncteur: return "Disjoncteur"
        case .disjoncteurDifferentiel: return "Disjoncteur différentiel"
        case .fusible: return "Fusible"
        case .relaisThermique: return "Relais thermique (3 pôles)"
        case .interrupteur: return "Interrupteur"
        case .vaEtVient: return "Interrupteur va-et-vient"
        case .boutonPoussoirNO: return "Bouton poussoir à fermeture (NO)"
        case .boutonPoussoirNF: return "Bouton poussoir à ouverture (NF)"
        case .arretUrgence: return "Arrêt d'urgence (coup de poing)"
        case .lampe: return "Lampe, luminaire"
        case .voyant: return "Voyant lumineux"
        case .sonnerie: return "Sonnerie"
        case .priseCourant: return "Prise de courant 2P+T"
        case .detecteurPresence: return "Détecteur de présence"
        case .minuterie: return "Minuterie"
        case .telerupteur: return "Télérupteur"
        case .contacteurBobine: return "Bobine de contacteur"
        case .contactNO: return "Contact à fermeture (NO)"
        case .contactNF: return "Contact à ouverture (NF)"
        case .contactPuissance: return "Contacts de puissance (3 pôles)"
        case .moteurMono: return "Moteur monophasé"
        case .moteurTri: return "Moteur triphasé"
        case .transformateur: return "Transformateur"
        case .resistance: return "Résistance"
        case .condensateur: return "Condensateur"
        case .diode: return "Diode"
        case .del: return "Diode électroluminescente (DEL)"
        case .ampermetre: return "Ampèremètre"
        case .voltmetre: return "Voltmètre"
        case .compteurEnergie: return "Compteur d'énergie (kWh)"
        case .jonction: return "Jonction (point de connexion)"
        case .borne: return "Borne"
        }
    }

    /// Écart entre deux pôles des symboles triphasés (contacts de puissance, relais thermique, moteur).
    static let ecartPoles: CGFloat = 0.8

    /// Bornes dans le repère local (centre = 0,0 ; x vers la droite ; y vers le bas).
    var terminaux: [String: CGPoint] {
        let h: CGFloat = 1.5
        let e = SchemaSymbolType.ecartPoles
        switch self {
        case .phase, .neutre: return ["a": CGPoint(x: 0, y: 1)]
        case .terre: return ["a": CGPoint(x: 0, y: -1)]
        case .jonction, .borne: return ["a": .zero]
        case .contactPuissance, .relaisThermique:
            return ["1": CGPoint(x: -e, y: -h), "3": CGPoint(x: 0, y: -h), "5": CGPoint(x: e, y: -h),
                    "2": CGPoint(x: -e, y: h), "4": CGPoint(x: 0, y: h), "6": CGPoint(x: e, y: h)]
        case .contacteurBobine: return ["A1": CGPoint(x: 0, y: -h), "A2": CGPoint(x: 0, y: h)]
        case .vaEtVient: return ["c": CGPoint(x: 0, y: -h), "1": CGPoint(x: -0.7, y: h), "2": CGPoint(x: 0.7, y: h)]
        case .priseCourant: return ["L": CGPoint(x: -0.4, y: -h), "N": CGPoint(x: 0.4, y: -h), "PE": CGPoint(x: 0, y: h)]
        case .transformateur:
            return ["a1": CGPoint(x: -0.4, y: -h), "a2": CGPoint(x: -0.4, y: h),
                    "b1": CGPoint(x: 0.4, y: -h), "b2": CGPoint(x: 0.4, y: h)]
        case .moteurMono: return ["L": CGPoint(x: -0.45, y: -h), "N": CGPoint(x: 0.45, y: -h)]
        case .moteurTri: return ["U": CGPoint(x: -e, y: -h), "V": CGPoint(x: 0, y: -h), "W": CGPoint(x: e, y: -h)]
        case .detecteurPresence: return ["L": CGPoint(x: -0.5, y: -h), "N": CGPoint(x: 0.5, y: -h), "S": CGPoint(x: 0, y: h)]
        case .minuterie:
            return ["L": CGPoint(x: -0.5, y: -h), "N": CGPoint(x: 0.5, y: -h),
                    "P": CGPoint(x: -0.5, y: h), "S": CGPoint(x: 0.5, y: h)]
        case .telerupteur:
            return ["A1": CGPoint(x: -0.5, y: -h), "A2": CGPoint(x: -0.5, y: h),
                    "1": CGPoint(x: 0.5, y: -h), "2": CGPoint(x: 0.5, y: h)]
        default: return ["a": CGPoint(x: 0, y: -h), "b": CGPoint(x: 0, y: h)]
        }
    }

    /// Cherche une borne par son nom (insensible à la casse ; quelques synonymes pour les dipôles :
    /// « 1 », « A1 », « 13 »… = a ; « 2 », « A2 », « 14 », « k » (cathode)… = b).
    /// Renvoie le nom officiel et la position locale.
    func borne(_ nom: String) -> (nom: String, point: CGPoint)? {
        let t = terminaux
        let n = nom.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return nil }
        if let p = t[n] { return (n, p) }
        if let e = t.first(where: { $0.key.lowercased() == n.lowercased() }) { return (e.key, e.value) }
        if Set(t.keys) == ["a", "b"] {
            let m = n.lowercased()
            if ["1", "11", "13", "21", "95", "97", "a1", "+", "anode", "entree", "entrée", "in"].contains(m), let p = t["a"] { return ("a", p) }
            if ["2", "12", "14", "22", "96", "98", "a2", "-", "k", "cathode", "sortie", "out"].contains(m), let p = t["b"] { return ("b", p) }
        }
        return nil
    }

    /// Rectangle local du CORPS du symbole (sans les fils de bornes) : sert à placer le repère (label) à côté.
    var corpsLocal: CGRect {
        switch self {
        case .phase, .neutre: return CGRect(x: -0.7, y: -1.2, width: 1.4, height: 1.2)
        case .terre: return CGRect(x: -0.6, y: -0.1, width: 1.2, height: 0.7)
        case .jonction, .borne: return CGRect(x: -0.15, y: -0.15, width: 0.3, height: 0.3)
        case .interrupteur, .boutonPoussoirNO, .boutonPoussoirNF, .arretUrgence:
            return CGRect(x: -1.0, y: -0.7, width: 1.15, height: 1.4)
        case .sectionneur, .interrupteurSectionneur, .disjoncteur:
            return CGRect(x: -0.6, y: -0.7, width: 0.8, height: 1.4)
        case .disjoncteurDifferentiel:
            return CGRect(x: -0.6, y: -0.7, width: 1.6, height: 1.9)
        case .contactNO, .contactNF: return CGRect(x: -0.5, y: -0.7, width: 0.65, height: 1.4)
        case .vaEtVient: return CGRect(x: -0.8, y: -0.8, width: 1.6, height: 1.4)
        case .contactPuissance: return CGRect(x: -1.3, y: -0.7, width: 2.2, height: 1.4)
        case .relaisThermique: return CGRect(x: -1.0, y: -0.7, width: 2.5, height: 1.4)
        case .fusible: return CGRect(x: -0.25, y: -0.55, width: 0.5, height: 1.1)
        case .resistance: return CGRect(x: -0.3, y: -0.6, width: 0.6, height: 1.2)
        case .condensateur: return CGRect(x: -0.5, y: -0.2, width: 1.0, height: 0.4)
        case .diode: return CGRect(x: -0.45, y: -0.45, width: 0.9, height: 0.9)
        case .del: return CGRect(x: -0.45, y: -0.6, width: 1.7, height: 1.05)
        case .lampe, .ampermetre, .voltmetre: return CGRect(x: -0.7, y: -0.7, width: 1.4, height: 1.4)
        case .voyant: return CGRect(x: -0.7, y: -0.7, width: 1.7, height: 1.4)
        case .sonnerie: return CGRect(x: -0.65, y: -0.3, width: 1.3, height: 0.7)
        case .priseCourant: return CGRect(x: -0.8, y: -0.4, width: 1.6, height: 1.4)
        case .detecteurPresence: return CGRect(x: -0.8, y: -0.6, width: 1.6, height: 1.2)
        case .minuterie: return CGRect(x: -0.85, y: -0.6, width: 1.7, height: 1.2)
        case .telerupteur: return CGRect(x: -0.95, y: -0.9, width: 1.9, height: 1.8)
        case .contacteurBobine: return CGRect(x: -0.5, y: -0.45, width: 1.0, height: 0.9)
        case .moteurMono, .moteurTri: return CGRect(x: -1.0, y: -0.7, width: 2.0, height: 2.0)
        case .transformateur: return CGRect(x: -1.0, y: -0.6, width: 2.0, height: 1.2)
        case .compteurEnergie: return CGRect(x: -0.8, y: -0.5, width: 1.6, height: 1.0)
        }
    }
}

// MARK: - Catalogue pour le prompt

extension SchemaSymbolType {

    /// (dessin, bornes en clair, usage typique)
    private var fiche: (dessin: String, bornes: String, usage: String) {
        switch self {
        case .phase:
            return ("Barre horizontale avec la lettre L au-dessus, un trait part vers le bas.",
                    "a = départ du fil, sous la barre.", "Début d'une ligne de phase en haut d'un schéma ; le symbole écrit déjà L lui-même : label VIDE (sinon doublon).")
        case .neutre:
            return ("Barre horizontale avec la lettre N au-dessus, un trait part vers le bas.",
                    "a = départ du fil, sous la barre.", "Début de la ligne de neutre (le symbole écrit déjà N lui-même : label VIDE, sinon doublon) ; en rotation 180 il se place en bas d'un montage (le fil arrive d'en haut).")
        case .terre:
            return ("Trait vertical terminé par trois barres de plus en plus courtes (symbole de terre).",
                    "a = en haut, côté fil.", "Fin du conducteur de protection PE (prise, masse métallique).")
        case .sectionneur:
            return ("Contact ouvert (lame penchée) avec une petite barre en travers au bout de la lame ; une phase.",
                    "a = haut, b = bas.", "Séparer un circuit de l'alimentation pour travailler dessus, sans pouvoir couper en charge. Pour 3 phases : 3 symboles espacés de 0,8 en x.")
        case .interrupteurSectionneur:
            return ("Comme le sectionneur, avec en plus un petit cercle sur la lame (coupe en charge).",
                    "a = haut, b = bas.", "Coupure générale en charge d'un tableau ou d'un départ moteur.")
        case .disjoncteur:
            return ("Contact ouvert avec une croix (x) au bout de la lame : protège contre surcharge et court-circuit ; une phase.",
                    "a = haut (amont), b = bas (aval).", "Protection d'un circuit (Q1 16 A éclairage…). Pour 3 phases : 3 symboles espacés de 0,8 en x.")
        case .disjoncteurDifferentiel:
            return ("Disjoncteur (croix) avec un anneau autour du fil du bas et le repère IΔ : protège aussi les personnes.",
                    "a = haut (amont), b = bas (aval).", "Protection différentielle 30 mA d'un circuit de prises ou d'un tableau.")
        case .fusible:
            return ("Petit rectangle traversé par le fil.",
                    "a = haut, b = bas.", "Protection contre les courts-circuits d'un circuit de commande ou d'un moteur.")
        case .relaisThermique:
            return ("Trois boucles carrées (bilames) reliées par un trait pointillé : protection contre la surcharge du moteur.",
                    "1, 3, 5 = haut (x = -0,8 ; 0 ; 0,8) ; 2, 4, 6 = bas.", "Placé entre le contacteur et le moteur (F1). Son contact de signalisation se dessine à part avec un contactNF repéré « F1 ».")
        case .interrupteur:
            return ("Contact ouvert avec une commande manuelle en pointillé à gauche.",
                    "a = haut, b = bas.", "Allumage simple d'une lampe depuis un seul endroit.")
        case .vaEtVient:
            return ("Un fil commun en haut, une lame qui peut se poser sur l'un des deux contacts du bas.",
                    "c = commun en haut (0 ; -1,5) ; 1 = bas gauche (-0,7 ; 1,5) ; 2 = bas droite (0,7 ; 1,5).", "Allumer depuis deux endroits : deux va-et-vient reliés par deux fils (les navettes), le second en rotation 180.")
        case .boutonPoussoirNO:
            return ("Contact ouvert (lame penchée) avec une commande poussoir en pointillé : il ferme tant qu'on appuie.",
                    "a = haut, b = bas.", "Bouton marche (S2) d'une commande de moteur ; bouton de sonnette ou de minuterie.")
        case .boutonPoussoirNF:
            return ("Contact fermé (lame appuyée contre le contact) avec commande poussoir en pointillé : il ouvre quand on appuie.",
                    "a = haut, b = bas.", "Bouton arrêt (S1) d'une commande de moteur.")
        case .arretUrgence:
            return ("Contact fermé avec une commande en pointillé terminée par un champignon (coup de poing).",
                    "a = haut, b = bas.", "Arrêt d'urgence en série dans le circuit de commande.")
        case .lampe:
            return ("Cercle traversé par une croix.", "a = haut, b = bas.", "Lampe ou luminaire (E1, H1).")
        case .voyant:
            return ("Cercle avec croix et trois petits rayons à l'extérieur.", "a = haut, b = bas.", "Voyant de signalisation (H1 marche, H2 défaut).")
        case .sonnerie:
            return ("Demi-disque (cloche) posé sur une base plate.", "a = haut, b = bas.", "Sonnerie ou avertisseur sonore (HA1).")
        case .priseCourant:
            return ("Demi-cercle avec la barre de terre dessous ; les deux fils L et N arrivent par le haut, le fil de terre par le bas.",
                    "L = haut gauche (-0,4 ; -1,5) ; N = haut droite (0,4 ; -1,5) ; PE = bas (0 ; 1,5).", "Prise 2P+T 16 A d'un circuit prises ; PE se relie à un symbole terre.")
        case .detecteurPresence:
            return ("Boîtier rectangulaire avec un point et trois arcs (ondes de détection).",
                    "L = haut gauche (-0,5 ; -1,5), N = haut droite (0,5 ; -1,5), S = bas (0 ; 1,5) : phase commutée vers la lampe.", "Éclairage automatique d'un couloir ou d'un garage.")
        case .minuterie:
            return ("Boîtier rectangulaire avec une horloge (cercle et aiguilles).",
                    "L = haut gauche (-0,5 ; -1,5), N = haut droite (0,5 ; -1,5), P = bas gauche (-0,5 ; 1,5) : retour des boutons poussoirs, S = bas droite (0,5 ; 1,5) : sortie vers les lampes.", "Éclairage d'escalier : s'éteint tout seul après un temps réglé.")
        case .telerupteur:
            return ("Boîtier pointillé contenant une bobine (à gauche) et un contact (à droite).",
                    "A1 = haut gauche (-0,5 ; -1,5), A2 = bas gauche (-0,5 ; 1,5) : bobine ; 1 = haut droite (0,5 ; -1,5), 2 = bas droite (0,5 ; 1,5) : contact de puissance.", "Allumer ou éteindre depuis plusieurs boutons poussoirs en parallèle.")
        case .contacteurBobine:
            return ("Rectangle (la bobine).", "A1 = haut, A2 = bas.", "Bobine du contacteur KM1, dans le circuit de commande ; A2 va au neutre.")
        case .contactNO:
            return ("Contact ouvert au repos (lame penchée qui ne touche pas).", "a = haut, b = bas.",
                    "Contact auxiliaire d'un contacteur (auto-maintien KM1 en parallèle du bouton marche).")
        case .contactNF:
            return ("Contact fermé au repos (lame appuyée contre un petit crochet).", "a = haut, b = bas.",
                    "Contact de signalisation du relais thermique F1 (95-96) en série avec la bobine.")
        case .contactPuissance:
            return ("Trois contacts ouverts côte à côte reliés par un trait pointillé.",
                    "1, 3, 5 = haut (x = -0,8 ; 0 ; 0,8) ; 2, 4, 6 = bas aux mêmes x.", "Contacts de puissance de KM1 sur L1, L2, L3, entre le disjoncteur et le relais thermique.")
        case .moteurMono:
            return ("Cercle avec la lettre M et le signe ~ (courant alternatif).", "L = haut gauche (-0,45 ; -1,5), N = haut droite (0,45 ; -1,5).", "Moteur monophasé (ventilateur, pompe).")
        case .moteurTri:
            return ("Cercle avec la lettre M et « 3~ » (alternatif triphasé).", "U, V, W = haut (x = -0,8 ; 0 ; 0,8), même écartement que 1-3-5 du contacteur.", "Moteur asynchrone triphasé M1.")
        case .transformateur:
            return ("Deux cercles qui se chevauchent : primaire à gauche, secondaire à droite.",
                    "a1 = haut gauche, a2 = bas gauche (x = -0,4) : primaire ; b1 = haut droite, b2 = bas droite (x = 0,4) : secondaire.", "Transformateur 230 V / 12 V (sonnette, éclairage TBT).")
        case .resistance:
            return ("Rectangle étroit (la norme européenne), fil aux deux bouts.", "a = haut, b = bas.", "Résistance, conducteur ohmique (R1 330 Ω).")
        case .condensateur:
            return ("Deux plaques parallèles horizontales.", "a = haut, b = bas.", "Condensateur (C1 100 µF).")
        case .diode:
            return ("Triangle pointe vers le bas contre une barre : le courant passe de a vers b.", "a = anode (haut), b = cathode (bas, côté barre).", "Redressement, protection ; 'k' est aussi accepté pour la cathode.")
        case .del:
            return ("Diode avec deux flèches qui sortent (elle émet de la lumière).", "a = anode (haut), b = cathode (bas).", "DEL de signalisation, en série avec une résistance de protection.")
        case .ampermetre:
            return ("Cercle avec la lettre A, monté en série.", "a = haut, b = bas.", "Mesure d'un courant en ampères.")
        case .voltmetre:
            return ("Cercle avec la lettre V, monté en dérivation.", "a = haut, b = bas.", "Mesure d'une tension en volts.")
        case .compteurEnergie:
            return ("Rectangle avec « kWh ».", "a = haut (entrée), b = bas (sortie).", "Compteur d'énergie électrique placé en tête d'installation.")
        case .jonction:
            return ("Petit point plein.", "a = le point lui-même (0 ; 0).", "À mettre soi-même (jamais ajouté tout seul) là où deux fils se rejoignent vraiment ; deux fils qui se croisent sans point ne sont PAS reliés.")
        case .borne:
            return ("Petit rond vide.", "a = le rond lui-même (0 ; 0).", "Borne d'entrée ou de sortie d'un montage (repère dans label).")
        }
    }

    private static func nombre(_ v: CGFloat) -> String {
        String(format: "%g", Double(v)).replacingOccurrences(of: ".", with: ",")
    }

    /// Texte en français pour Opus : conventions puis un paragraphe par symbole.
    static var catalogueDuPrompt: String {
        var t = """
        CONVENTIONS DE DESSIN (à respecter strictement)
        - Grille : les positions sont en unités de grille. L'origine est en haut à gauche de la zone, x va vers la droite, y vers le BAS. Écris les nombres avec un point décimal (3.5).
        - Un symbole est placé par son CENTRE (x, y). Il occupe au plus 2 unités de large sur 3 de haut (les symboles à 3 pôles sont un peu plus larges). Garde au moins 3 unités entre deux centres alignés verticalement (un dipôle a ses bornes à ±1,5 : deux dipôles en série à 3 unités l'un de l'autre se touchent bornes contre bornes) et 2 unités en largeur.
        - rotation : 0, 90, 180 ou 270 degrés, dans le sens horaire. À 0 un dipôle est vertical, borne « a » en haut et « b » en bas. À 90 : « a » est à droite (x + 1,5) et « b » à gauche. À 180 : « a » en bas. À 270 : « a » à gauche. Les repères de phase et de neutre tournent de la même façon.
        - Bornes : positions données ci-dessous dans le repère du symbole (centre = 0 ; 0, x vers la droite, y vers le bas, avant rotation). Dans un fil on écrit « idDuSymbole.borne », par exemple « Q1.b » ou « KM1.A1 », ou bien un point libre de la grille « x,y » (par exemple « 3.5,2 »). Les noms de bornes sont sensibles à l'orthographe indiquée ; pour les dipôles « 1 » et « 2 » sont acceptés à la place de « a » et « b ».
        - Fils : uniquement horizontaux ou verticaux. Si deux points consécutifs ne sont pas alignés, l'application ajoute un coude. « via » donne des points de passage [x, y] pour contourner un symbole. Deux fils qui se croisent ne sont reliés que s'il y a un symbole « jonction » à l'intersection (à placer toi-même).
        - Un repère (label) comme « Q1 », « KM1 », « 230 V » est écrit à droite du symbole (au-dessus s'il est tourné de 90 ou 270).
        - Légende des conducteurs : ligne de phase L (marron ou noir), neutre N (bleu), terre PE (vert-jaune). Le dessin est monochrome : repère les lignes avec des textes (« L1 », « N », « PE »).
        - Un symbole inutile ne se dessine pas ; ne dessine que ce qu'il faut ajouter à la page.

        SYMBOLES DISPONIBLES (valeur brute à écrire dans « type », nom, dessin, bornes, usage)

        """
        for type in SchemaSymbolType.allCases {
            let f = type.fiche
            let positions = type.terminaux.sorted { ($0.value.y, $0.value.x, $0.key) < ($1.value.y, $1.value.x, $1.key) }
                .map { "\($0.key) (\(nombre($0.value.x)) ; \(nombre($0.value.y)))" }.joined(separator: ", ")
            t += "- \(type.rawValue) : \(type.nomFrancais). Dessin : \(f.dessin) Bornes : \(f.bornes) Positions : \(positions). Usage : \(f.usage)\n"
        }
        return t
    }
}

// MARK: - Dessin

/// Petite boîte à outils de traits dans le repère local (unités de grille).
private struct Plume {
    let c: CGContext

    func ligne(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
        c.move(to: CGPoint(x: x1, y: y1)); c.addLine(to: CGPoint(x: x2, y: y2)); c.strokePath()
    }
    func tirets(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
        c.saveGState()
        c.setLineDash(phase: 0, lengths: [0.12, 0.1])
        ligne(x1, y1, x2, y2)
        c.restoreGState()
    }
    func rect(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat, tirets t: Bool = false) {
        c.saveGState()
        if t { c.setLineDash(phase: 0, lengths: [0.12, 0.1]) }
        c.stroke(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
        c.restoreGState()
    }
    func cercle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, plein: Bool = false) {
        let r2 = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
        if plein { c.fillEllipse(in: r2) } else { c.strokeEllipse(in: r2) }
    }
    /// Arc par segments ; angles en degrés dans le repère y vers le bas (90 = vers le bas).
    func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ de: CGFloat, _ a: CGFloat) {
        let n = max(2, Int(abs(a - de) / 8))
        for i in 0...n {
            let ang = (de + (a - de) * CGFloat(i) / CGFloat(n)) * .pi / 180
            let p = CGPoint(x: cx + r * cos(ang), y: cy + r * sin(ang))
            if i == 0 { c.move(to: p) } else { c.addLine(to: p) }
        }
        c.strokePath()
    }
    func triangle(_ pts: [CGPoint], plein: Bool) {
        c.beginPath(); c.move(to: pts[0]); pts.dropFirst().forEach { c.addLine(to: $0) }; c.closePath()
        c.drawPath(using: plein ? .fillStroke : .stroke)
    }
    func croix(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        ligne(cx - r, cy - r, cx + r, cy + r); ligne(cx - r, cy + r, cx + r, cy - r)
    }
    func fleche(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
        ligne(x1, y1, x2, y2)
        let a = atan2(y2 - y1, x2 - x1), t: CGFloat = 0.2
        for d in [CGFloat.pi * 0.8, -CGFloat.pi * 0.8] {
            ligne(x2, y2, x2 + t * cos(a + d), y2 + t * sin(a + d))
        }
    }
    func texte(_ s: String, _ x: CGFloat, _ y: CGFloat, _ taille: CGFloat, _ ancre: SchemaPolice.Ancre = .centre) {
        SchemaPolice.dessiner(s, ctx: c, x: x, y: y, taille: taille, ancre: ancre)
    }

    // Contacts : la lame part du bas (pivot) et monte vers le haut à gauche.
    /// Contact à fermeture : lame ouverte. Renvoie le bout de la lame.
    @discardableResult
    func lameNO(_ x: CGFloat, dx: CGFloat = -0.4) -> CGPoint {
        ligne(x, -1.5, x, -0.5); ligne(x, 1.5, x, 0.5); ligne(x, 0.5, x + dx, -0.45)
        return CGPoint(x: x + dx, y: -0.45)
    }
    /// Contact à ouverture : la lame est appuyée contre un petit crochet.
    func lameNF(_ x: CGFloat, dx: CGFloat = -0.3) {
        ligne(x, -1.5, x, -0.5); ligne(x, -0.5, x + dx, -0.5)
        ligne(x, 1.5, x, 0.5); ligne(x, 0.5, x + dx, -0.5)
    }
    /// Petite barre perpendiculaire à la lame, à son bout (sectionneur).
    func barreAuBout(_ bout: CGPoint, x: CGFloat) {
        let dx = bout.x - x, dy = bout.y - 0.5
        let n = max(hypot(dx, dy), 0.001)
        let px = -dy / n * 0.2, py = dx / n * 0.2
        ligne(bout.x - px, bout.y - py, bout.x + px, bout.y + py)
    }
}

extension SchemaSymbolType {

    /// Dessine le symbole CENTRÉ sur l'origine du contexte, 1 unité de grille = `echelle` points (ou pixels).
    /// Convention : le contexte peut être en y vers le haut (PDF, CGBitmapContext) OU en y vers le bas (vue retournée) :
    /// on lit le signe du déterminant de la matrice courante et on retourne l'axe y au besoin. Le symbole est ensuite
    /// dessiné en y vers le BAS. L'appelant règle d'avance la couleur de TRACÉ et la couleur de REMPLISSAGE (identiques),
    /// la rotation éventuelle se fait avec `rotate(by:)` avant l'appel (angle positif = sens horaire à l'écran).
    func dessiner(dans ctx: CGContext, echelle: CGFloat) {
        guard echelle.isFinite, echelle > 0 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let t = ctx.ctm
        let yVersHaut = (t.a * t.d - t.b * t.c) > 0
        ctx.scaleBy(x: echelle, y: yVersHaut ? -echelle : echelle)
        ctx.setLineWidth(max(0.07, 0.6 / echelle))   // ≈ 0,07 unité, jamais sous 0,6 point
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineDash(phase: 0, lengths: [])
        let p = Plume(c: ctx)
        let e = SchemaSymbolType.ecartPoles

        switch self {
        case .phase, .neutre:
            p.ligne(-0.7, -0.4, 0.7, -0.4); p.ligne(0, -0.4, 0, 1)
            p.texte(self == .phase ? "L" : "N", 0, -0.85, 0.55)
        case .terre:
            p.ligne(0, -1, 0, 0)
            p.ligne(-0.6, 0, 0.6, 0); p.ligne(-0.4, 0.2, 0.4, 0.2); p.ligne(-0.2, 0.4, 0.2, 0.4)

        case .sectionneur:
            let b = p.lameNO(0); p.barreAuBout(b, x: 0)
        case .interrupteurSectionneur:
            let b = p.lameNO(0); p.barreAuBout(b, x: 0)
            p.cercle(-0.14, 0.12, 0.1)
        case .disjoncteur:
            let b = p.lameNO(0); p.croix(b.x, b.y, 0.17)
        case .disjoncteurDifferentiel:
            let b = p.lameNO(0); p.croix(b.x, b.y, 0.17)
            p.cercle(0, 1.0, 0.24)
            p.texte("IΔ", 0.38, 1.0, 0.42, .gauche)
        case .fusible:
            p.ligne(0, -1.5, 0, 1.5); p.rect(0, 0, 0.44, 1.0)
        case .relaisThermique:
            for x in [-e, 0, e] {
                p.ligne(x, -1.5, x, -0.45); p.ligne(x, -0.45, x + 0.24, -0.45)
                p.ligne(x + 0.24, -0.45, x + 0.24, 0.45); p.ligne(x + 0.24, 0.45, x, 0.45); p.ligne(x, 0.45, x, 1.5)
            }
            p.tirets(-e + 0.24, 0, 1.4, 0); p.ligne(1.4, -0.2, 1.4, 0.2)

        case .interrupteur:
            p.lameNO(0)
            p.tirets(-0.2, 0.03, -0.9, 0.03)
            p.ligne(-0.9, -0.2, -0.9, 0.26)
            p.ligne(-0.9, -0.2, -0.76, -0.2); p.ligne(-0.9, 0.26, -0.76, 0.26)
        case .vaEtVient:
            p.ligne(0, -1.5, 0, -0.7)
            p.ligne(0, -0.7, -0.7, 0.5)
            p.ligne(-0.7, 0.5, -0.7, 1.5); p.ligne(0.7, 0.5, 0.7, 1.5)
            p.cercle(0, -0.7, 0.07, plein: true)
        case .boutonPoussoirNO:
            p.lameNO(0)
            p.tirets(-0.2, 0.03, -0.75, 0.03); p.ligne(-0.75, -0.22, -0.75, 0.28)
        case .boutonPoussoirNF:
            p.lameNF(0)
            p.tirets(-0.15, 0.0, -0.75, 0.0); p.ligne(-0.75, -0.25, -0.75, 0.25)
        case .arretUrgence:
            p.lameNF(0)
            p.tirets(-0.15, 0.0, -0.62, 0.0)
            p.ligne(-0.62, -0.3, -0.62, 0.3); p.arc(-0.62, 0, 0.3, 90, 270)

        case .lampe, .voyant:
            p.cercle(0, 0, 0.6)
            p.ligne(0, -1.5, 0, -0.6); p.ligne(0, 0.6, 0, 1.5)
            p.croix(0, 0, 0.424)
            if self == .voyant {
                for a in [-15, -45, -75] as [CGFloat] {
                    let r = a * .pi / 180
                    p.ligne(0.72 * cos(r), 0.72 * sin(r), 0.98 * cos(r), 0.98 * sin(r))
                }
            }
        case .sonnerie:
            p.arc(0, 0.35, 0.65, 180, 360); p.ligne(-0.65, 0.35, 0.65, 0.35)
            p.ligne(0, -1.5, 0, -0.3); p.ligne(0, 0.35, 0, 1.5)
        case .priseCourant:
            p.arc(0, 0.4, 0.75, 180, 360); p.ligne(-0.75, 0.4, 0.75, 0.4)
            let yArc = 0.4 - sqrt(0.75 * 0.75 - 0.4 * 0.4)
            p.ligne(-0.4, -1.5, -0.4, yArc); p.ligne(0.4, -1.5, 0.4, yArc)
            p.ligne(0, 1.5, 0, 0.4); p.ligne(-0.3, 0.95, 0.3, 0.95)

        case .detecteurPresence:
            p.rect(0, 0, 1.6, 1.2)
            p.ligne(-0.5, -1.5, -0.5, -0.6); p.ligne(0.5, -1.5, 0.5, -0.6); p.ligne(0, 0.6, 0, 1.5)
            p.cercle(-0.45, 0, 0.06, plein: true)
            for r in [0.3, 0.5, 0.7] as [CGFloat] { p.arc(-0.45, 0, r, -40, 40) }
        case .minuterie:
            p.rect(0, 0, 1.7, 1.2)
            p.ligne(-0.5, -1.5, -0.5, -0.6); p.ligne(0.5, -1.5, 0.5, -0.6)
            p.ligne(-0.5, 0.6, -0.5, 1.5); p.ligne(0.5, 0.6, 0.5, 1.5)
            p.cercle(0, 0, 0.36); p.ligne(0, 0, 0, -0.25); p.ligne(0, 0, 0.17, 0.1)
        case .telerupteur:
            p.rect(0, 0, 1.9, 1.8, tirets: true)
            p.rect(-0.5, 0, 0.5, 0.9)
            p.ligne(-0.5, -1.5, -0.5, -0.45); p.ligne(-0.5, 0.45, -0.5, 1.5)
            p.ligne(0.5, -1.5, 0.5, -0.45); p.ligne(0.5, 1.5, 0.5, 0.45); p.ligne(0.5, 0.45, 0.2, -0.4)

        case .contacteurBobine:
            p.rect(0, 0, 1.0, 0.9)
            p.ligne(0, -1.5, 0, -0.45); p.ligne(0, 0.45, 0, 1.5)
        case .contactNO:
            p.lameNO(0)
        case .contactNF:
            p.lameNF(0)
        case .contactPuissance:
            for x in [-e, 0, e] { p.lameNO(x, dx: -0.35) }
            p.tirets(-e - 0.175, 0.03, e - 0.175, 0.03)

        case .moteurMono, .moteurTri:
            p.cercle(0, 0.3, 1.0)
            let xs: [CGFloat] = self == .moteurTri ? [-e, 0, e] : [-0.45, 0.45]
            for x in xs { p.ligne(x, -1.5, x, 0.3 - sqrt(1 - x * x)) }
            p.texte("M", 0, 0.05, 0.75)
            p.texte(self == .moteurTri ? "3~" : "~", 0, 0.65, 0.5)

        case .transformateur:
            p.cercle(-0.4, 0, 0.6); p.cercle(0.4, 0, 0.6)
            for x in [-0.4, 0.4] as [CGFloat] { p.ligne(x, -1.5, x, -0.6); p.ligne(x, 0.6, x, 1.5) }
        case .resistance:
            p.rect(0, 0, 0.5, 1.1)
            p.ligne(0, -1.5, 0, -0.55); p.ligne(0, 0.55, 0, 1.5)
        case .condensateur:
            p.ligne(-0.5, -0.15, 0.5, -0.15); p.ligne(-0.5, 0.15, 0.5, 0.15)
            p.ligne(0, -1.5, 0, -0.15); p.ligne(0, 0.15, 0, 1.5)
        case .diode, .del:
            p.triangle([CGPoint(x: -0.4, y: -0.4), CGPoint(x: 0.4, y: -0.4), CGPoint(x: 0, y: 0.35)], plein: true)
            p.ligne(-0.4, 0.35, 0.4, 0.35)
            p.ligne(0, -1.5, 0, -0.4); p.ligne(0, 0.35, 0, 1.5)
            if self == .del {
                p.fleche(0.5, -0.05, 0.95, -0.5)
                p.fleche(0.7, 0.22, 1.15, -0.23)
            }

        case .ampermetre, .voltmetre:
            p.cercle(0, 0, 0.7)
            p.ligne(0, -1.5, 0, -0.7); p.ligne(0, 0.7, 0, 1.5)
            p.texte(self == .ampermetre ? "A" : "V", 0, 0, 0.85)
        case .compteurEnergie:
            p.rect(0, 0, 1.6, 1.0)
            p.ligne(0, -1.5, 0, -0.5); p.ligne(0, 0.5, 0, 1.5)
            p.texte("kWh", 0, 0, 0.42)

        case .jonction: p.cercle(0, 0, 0.12, plein: true)
        case .borne: p.cercle(0, 0, 0.12)
        }
    }
}
