import Foundation

// « Écouter un cours » : vocabulaire de cours (bac pro MTNE : électricité, réseaux, maths, physique-chimie) pour
//  1. aider le moteur de dictée AVANT la transcription (contextualStrings, sur le Mac) ;
//  2. corriger APRÈS la transcription les fautes classiques (« télé rupteur », « 3 kilo watts », « ampaire »…).
// Rien ici ne touche le micro ni le réseau : tout est testable (Tools/Tests/Lecture).

enum LectureVocabulaire {
    /// Termes de base, utiles dans toutes les matières techniques de la classe (écriture correcte, avec accents).
    static let electricite = [
        "télérupteur", "disjoncteur", "disjoncteur différentiel", "interrupteur différentiel", "sectionneur", "contacteur",
        "relais thermique", "fusible", "porte-fusible", "va-et-vient", "permutateur", "minuterie", "détecteur de présence",
        "prise de courant", "douille", "luminaire", "tableau électrique", "gaine ICTA", "conduit", "goulotte", "chemin de câbles",
        "conducteur", "phase", "neutre", "terre", "conducteur de protection", "section", "borne", "domino", "bornier",
        "schéma développé", "schéma unifilaire", "schéma multifilaire", "schéma de câblage", "plan de masse",
        "courant alternatif", "courant continu", "monophasé", "triphasé", "tension", "intensité", "résistance", "puissance",
        "énergie", "fréquence", "déphasage", "facteur de puissance", "impédance", "réactance",
        "loi d'Ohm", "loi de Joule", "effet Joule", "ampère", "ampèremètre", "voltmètre", "ohmmètre", "wattmètre", "multimètre",
        "kilowattheure", "kilowatt", "kilovolt", "milliampère", "mégohm", "kilohm", "volt-ampère",
        "TBTS", "TBTP", "TT", "TN", "IT", "schéma de liaison à la terre", "IP2X", "IK", "classe I", "classe II",
        "NF C 15-100", "habilitation électrique", "B0", "H0", "BR", "BC", "consignation", "EPI", "VAT",
        "transformateur", "moteur asynchrone", "démarrage étoile-triangle", "variateur de vitesse", "automate programmable",
        "capteur", "actionneur", "préactionneur", "détecteur inductif", "détecteur capacitif", "cellule photoélectrique",
        "diode", "transistor", "condensateur", "bobine", "résistor", "LED", "DEL", "photovoltaïque", "onduleur", "alimentation",
        "domotique", "KNX", "interphone", "visiophone", "vidéophone", "parlophone", "antenne", "TV", "VDI",
    ]

    static let reseau = [
        "VLAN", "RJ45", "switch", "routeur", "pare-feu", "passerelle", "adresse IP", "adresse MAC", "masque de sous-réseau",
        "sous-réseau", "DHCP", "DNS", "TCP", "UDP", "Ethernet", "Wi-Fi", "fibre optique", "câble à paires torsadées",
        "baie de brassage", "panneau de brassage", "câble droit", "câble croisé", "ping", "protocole", "paquet", "trame",
        "modèle OSI", "couche", "bande passante", "débit", "latence", "serveur", "client", "box", "ONT", "PTO",
        "Packet Tracer", "IPv4", "IPv6", "CIDR", "passerelle par défaut", "port", "hub", "concentrateur",
    ]

    static let maths = [
        "pourcentage", "proportionnalité", "coefficient directeur", "fonction affine", "fonction linéaire", "équation",
        "inconnue", "identité remarquable", "développer", "factoriser", "théorème de Pythagore", "hypoténuse",
        "théorème de Thalès", "trigonométrie", "sinus", "cosinus", "tangente", "périmètre", "aire", "volume", "diamètre",
        "rayon", "cercle", "triangle rectangle", "parallélogramme", "médiane", "moyenne", "écart-type", "fréquence",
        "statistiques", "probabilité", "arrondi", "chiffres significatifs", "notation scientifique", "puissance de dix",
        "racine carrée", "ordonnée à l'origine", "abscisse", "ordonnée", "repère", "vecteur", "symétrie", "homothétie",
    ]

    static let physique = [
        "mètre", "kilogramme", "seconde", "newton", "joule", "pascal", "hertz", "watt", "kelvin", "degré Celsius", "coulomb",
        "mole", "concentration", "masse volumique", "vitesse", "accélération", "force", "poids", "pesanteur", "énergie cinétique",
        "énergie potentielle", "énergie thermique", "énergie renouvelable", "rendement", "conversion d'énergie", "chaîne d'énergie",
        "atome", "molécule", "ion", "électron", "proton", "neutron", "réaction chimique", "acide", "base", "pH", "solution",
        "mélange", "corps pur", "lumière", "onde", "longueur d'onde", "son", "décibel", "réfraction", "réflexion",
    ]

    static func parMatiere(_ matiere: String) -> [String] {
        let m = matiere.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var l: [String] = []
        if m.contains("elec") || m.contains("mtne") || m.contains("metier") { l += electricite }
        if m.contains("res") || m.contains("info") || m.contains("num") { l += reseau }
        if m.contains("math") { l += maths }
        if m.contains("phys") || m.contains("chim") || m.contains("scien") { l += physique }
        return l
    }

    /// Tous les termes connus (sert à ne jamais « corriger » un mot juste vers un autre mot du cours).
    static var tous: [String] { electricite + reseau + maths + physique }

    /// Les termes du vocabulaire écrits en un seul mot (pour reconnaître un mot proche mal écrit).
    static let motsSeuls: [String] = Array(Set(tous.filter { !$0.contains(" ") && !$0.contains("-") && $0.count >= 5 }))

    // MARK: Avant la transcription

    /// Chaînes données au moteur de dictée (contextualStrings) : lexique de l'élève d'abord, puis ceux de la matière du cours,
    /// puis le noyau MTNE, puis prénoms et nom du prof (le moteur les écrit mieux ; ils sont retirés plus tard du texte envoyé à l'IA).
    /// Sans doublon, 400 au plus (le moteur reste rapide).
    static func contextualStrings(reglages: LectureReglages, matiere: String, prof: String = "") -> [String] {
        var vus = Set<String>(), sortie: [String] = []
        func ajouter(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, t.count <= 60, vus.insert(t.lowercased()).inserted else { return }
            sortie.append(t)
        }
        reglages.lexique.forEach(ajouter)
        for ligne in reglages.corrections {          // la partie « juste » de « faux=juste » est un bon terme
            let p = ligne.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { ajouter(p[1]) }
        }
        parMatiere(matiere).forEach(ajouter)
        electricite.forEach(ajouter)
        reseau.forEach(ajouter)
        for n in reglages.prenoms { ajouter(n) }
        for part in LectureTexte.motsDuNomDeProf(prof) { ajouter(part) }
        return Array(sortie.prefix(400))
    }

    // MARK: Après la transcription

    /// Fautes classiques du moteur de dictée en français sur ce vocabulaire (« faux » → « juste »). Insensible à la casse,
    /// mot entier ; toutes ces formes sont de vraies erreurs (aucune n'est une expression correcte à ne pas toucher).
    static let correctionsDeBase: [(String, String)] = [
        ("télé rupteur", "télérupteur"), ("télé-rupteur", "télérupteur"), ("telerupteur", "télérupteur"), ("télé rupteurs", "télérupteurs"),
        ("disjoncteur différentielle", "disjoncteur différentiel"), ("disjoncteurs différentielle", "disjoncteurs différentiels"),
        ("disjoncteur diférentiel", "disjoncteur différentiel"), ("dis joncteur", "disjoncteur"), ("disjonteur", "disjoncteur"),
        ("section heure", "sectionneur"), ("contact heure", "contacteur"), ("contact eur", "contacteur"),
        ("va et vient", "va-et-vient"), ("vas et viens", "va-et-vient"), ("va et viens", "va-et-vient"),
        ("mono phasé", "monophasé"), ("mono-phasé", "monophasé"), ("tri phasé", "triphasé"), ("tri-phasé", "triphasé"),
        ("loi d'homme", "loi d'Ohm"), ("loi dôme", "loi d'Ohm"), ("loi d'ome", "loi d'Ohm"), ("loi d'hommes", "loi d'Ohm"),
        ("loi de ohm", "loi d'Ohm"),
        ("effet jaoule", "effet Joule"), ("effet de joule", "effet Joule"),
        ("ampaire", "ampère"), ("ampère mètre", "ampèremètre"), ("ampère-mètre", "ampèremètre"), ("volt mètre", "voltmètre"),
        ("volt-mètre", "voltmètre"), ("ohm mètre", "ohmmètre"), ("watt mètre", "wattmètre"), ("multi mètre", "multimètre"),
        ("kilo watt heure", "kilowattheure"), ("kilo watts heure", "kilowattheure"), ("kilo watt heures", "kilowattheures"), ("kilo watts heures", "kilowattheures"), ("kilowatts heures", "kilowattheures"), ("kilowatt heure", "kilowattheure"), ("kilowatts heure", "kilowattheure"),
        ("kilo watt", "kilowatt"), ("kilo watts", "kilowatts"), ("kilo volt", "kilovolt"), ("kilo volts", "kilovolts"),
        ("milli ampère", "milliampère"), ("milli ampères", "milliampères"), ("méga ohm", "mégohm"), ("kilo ohm", "kilohm"), ("kilo ohms", "kilohms"),
        ("pare feu", "pare-feu"), ("parfeu", "pare-feu"), ("v lan", "VLAN"), ("v-lan", "VLAN"), ("vélan", "VLAN"),
        ("rj 45", "RJ45"), ("rj-45", "RJ45"), ("r j 45", "RJ45"), ("d h c p", "DHCP"), ("dhcp", "DHCP"), ("d n s", "DNS"),
        ("wifi", "Wi-Fi"), ("wi fi", "Wi-Fi"), ("ip v 4", "IPv4"), ("ipv quatre", "IPv4"), ("ip v4", "IPv4"),
        ("pythagore", "Pythagore"), ("pitagore", "Pythagore"), ("pythagor", "Pythagore"), ("hypotenuse", "hypoténuse"),
        ("talès", "Thalès"), ("racine carré", "racine carrée"),
        ("c i c t a", "ICTA"), ("icta", "ICTA"), ("n f c 15 100", "NF C 15-100"), ("nfc 15-100", "NF C 15-100"), ("nf c 15100", "NF C 15-100"),
        ("t b t s", "TBTS"), ("tbts", "TBTS"), ("tbtp", "TBTP"), ("photo voltaïque", "photovoltaïque"), ("photo-voltaïque", "photovoltaïque"),
        ("trans formateur", "transformateur"),
    ]

    private static let reCorrectionsDeBase: [(NSRegularExpression, String)] = {
        var vu = Set<String>(), l: [(NSRegularExpression, String)] = []
        // les formes longues d'abord (« kilo watt heure » avant « kilo watt »)
        for (faux, juste) in correctionsDeBase.sorted(by: { $0.0.count > $1.0.count }) where faux != juste && vu.insert(faux.lowercased()).inserted {
            let motif = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: faux).replacingOccurrences(of: " ", with: "[ \\u00A0]+") + "(?![\\p{L}\\p{N}])"
            if let re = try? NSRegularExpression(pattern: motif, options: [.caseInsensitive]) { l.append((re, NSRegularExpression.escapedTemplate(for: juste))) }
        }
        return l
    }()

    /// Applique les corrections de base du cours (appelé par LectureTexte.corriger, avant celles de l'élève).
    static func corrigerDeBase(_ texte: String) -> String {
        var t = texte
        for (re, modele) in reCorrectionsDeBase {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: modele)
        }
        return t
    }
}
