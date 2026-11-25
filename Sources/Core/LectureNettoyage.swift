import Foundation

// « Écouter un cours » : nettoyage du texte reconnu, avant le tri et la fiche.
//  - recoller les phrases coupées par une pause en plein milieu (entre mots, ou entre deux morceaux de 10 minutes) ;
//  - retirer les répétitions du moteur (« le le le le », boucle d'une même phrase) et ses phrases inventées dans le silence
//    (« Sous-titrage… », « Merci d'avoir regardé… ») ;
//  - protéger les noms : prof et « Madame/Monsieur + Nom » deviennent « le prof ».
// Logique pure (aucun micro, aucun réseau) : testée dans Tools/Tests/Lecture.

extension LectureTexte {
    // MARK: Aide : textes

    private static func plier(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// Même nombre de caractères que l'original, sans accent ni majuscule : les positions trouvées dans le texte plié valent aussi dans l'original.
    private static func plierEgal(_ s: String) -> String {
        var sortie = ""
        sortie.reserveCapacity(s.utf8.count)
        for c in s {
            let f = plier(String(c))
            sortie += f.count == 1 ? f : String(c)
        }
        return sortie
    }

    private static func motsNormalises(_ s: String) -> [String] {
        plier(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    // MARK: Noms (prof, élèves)

    private static let titres: Set<String> = ["m", "mr", "mme", "mlle", "madame", "monsieur", "mademoiselle", "prof", "professeur", "professeure", "maitre", "maitresse"]

    /// Les mots du nom d'un prof saisi (« M. Dupont » → ["Dupont"]), sans les titres ni les mots trop courts.
    static func motsDuNomDeProf(_ prof: String) -> [String] {
        prof.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "," })
            .map(String.init)
            .filter { $0.count >= 3 && !titres.contains(plier($0)) }
    }

    /// Mots qui suivent « Madame/Monsieur » avec une majuscule sans être un nom (début de phrase) : « Madame Je ne comprends pas ».
    private static let motsNonNoms: Set<String> = ["je", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles", "ce", "ca", "cela", "est", "pouvez",
                                                   "peut", "peux", "pourquoi", "comment", "quand", "ou", "et", "mais", "donc", "alors", "si", "oui", "non",
                                                   "le", "la", "les", "un", "une", "des", "mon", "ma", "mes", "j", "c", "d", "l", "qu", "est-ce", "que", "qui", "quoi",
                                                   "attention", "regardez", "excusez", "pardon", "merci", "bonjour", "bonsoir", "s"]

    /// Remplace partout les prénoms par « un élève » (sans tenir compte des majuscules ni des accents : « Léa », « lea »,
    /// « LÉA »), puis le nom du prof, et toute formule « Madame/Monsieur/M./Mme + Nom », par « le prof ».
    static func retirerPrenoms(_ texte: String, prenoms: [String], prof: String = "") -> String {
        var t = texte
        // 1. « Madame Dupont », « M. Martin » : un nom propre après un titre est celui d'un prof, même s'il n'est pas dans les réglages
        t = remplacerNomsApresTitre(t)
        // 2. le nom saisi du prof, seul (« Dupont a dit… ») : mot entier, avec une majuscule (pour ne pas toucher « petit » si le prof s'appelle Petit)
        for mot in motsDuNomDeProf(prof).sorted(by: { $0.count > $1.count }) {
            t = remplacerMotEntier(t, mot: mot, par: "le prof", exigerMajuscule: true)
        }
        // 3. les prénoms de la classe
        for n in Set(prenoms.map { $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            t = remplacerMotEntier(t, mot: n, par: "un élève", exigerMajuscule: false)
        }
        return t
    }

    /// Remplace chaque occurrence du mot (mot entier ; lettres, chiffres ; accents et majuscules ignorés).
    private static func remplacerMotEntier(_ t: String, mot: String, par remplacement: String, exigerMajuscule: Bool) -> String {
        let motif = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: plierEgal(mot)) + "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: motif) else { return t }
        let plie = plierEgal(t)
        guard plie.count == t.count else { return t }          // garde-fou : positions non transposables
        var sortie = t
        for m in re.matches(in: plie, range: NSRange(plie.startIndex..., in: plie)).reversed() {
            guard let rp = Range(m.range, in: plie) else { continue }
            let a = plie.distance(from: plie.startIndex, to: rp.lowerBound), b = plie.distance(from: plie.startIndex, to: rp.upperBound)
            let debut = sortie.index(sortie.startIndex, offsetBy: a), fin = sortie.index(sortie.startIndex, offsetBy: b)
            if exigerMajuscule, !(sortie[debut].isUppercase) { continue }
            sortie.replaceSubrange(debut..<fin, with: remplacement)
        }
        return sortie
    }

    private static let reTitreNom = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}])(?i:madame|monsieur|mademoiselle|mme|mlle|mr|m\\.?)(?:[ \\u00A0]+)(\\p{Lu}[\\p{L}'’]*(?:-\\p{Lu}[\\p{L}']*)*)")

    private static func remplacerNomsApresTitre(_ t: String) -> String {
        guard let re = reTitreNom else { return t }
        var sortie = t
        for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
            guard let r = Range(m.range, in: sortie), let nom = Range(m.range(at: 1), in: sortie) else { continue }
            let mot = plier(String(sortie[nom]))
            if motsNonNoms.contains(mot) || mot.count < 2 { continue }
            sortie.replaceSubrange(r, with: "le prof")
        }
        return sortie
    }

    // MARK: Répétitions et phrases inventées

    /// Phrases que le moteur invente quand il n'entend que du bruit ou du silence (sous-titres, fin de vidéo…).
    private static let phrasesInventees = ["sous-titrage", "sous-titres realises", "sous-titres par", "amara.org", "merci d'avoir regarde",
                                           "merci de votre attention", "abonnez-vous", "n'oubliez pas de vous abonner", "a bientot pour une nouvelle",
                                           "sous-titrage st", "transcrit par", "copyright", "les sous-titres"]

    /// Vrai si le texte entier est du bruit : pas de lettre, ou une phrase inventée par le moteur.
    static func estBruit(_ texte: String) -> Bool {
        let p = plier(texte).lowercased().replacingOccurrences(of: "’", with: "'")
        if !p.contains(where: { $0.isLetter || $0.isNumber }) { return true }
        return phrasesInventees.contains(where: { p.contains($0) }) && motsNormalises(p).count <= 14
    }

    /// Un mot répété 3 fois ou plus de suite (« le le le le ») et un groupe de 2 à 6 mots répété 3 fois ou plus (« on va voir on va voir on va voir »)
    /// est ramené à une seule fois. Deux fois de suite ne change jamais (« très très », « c'est c'est » restent : l'élève l'a peut-être dit).
    static func retirerRepetitions(_ texte: String) -> String {
        var mots = texte.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard mots.count >= 3 else { return texte }
        func cle(_ s: String) -> String { plier(s).trimmingCharacters(in: CharacterSet.letters.union(.decimalDigits).inverted).lowercased() }
        var changement = true
        while changement {
            changement = false
            for taille in 1...6 where mots.count >= taille * 3 {
                var i = 0
                while i + taille * 3 <= mots.count {
                    let base = mots[i..<(i + taille)].map(cle)
                    if base.contains(where: { $0.isEmpty }) { i += 1; continue }
                    var repetitions = 1
                    while i + (repetitions + 1) * taille <= mots.count,
                          Array(mots[(i + repetitions * taille)..<(i + (repetitions + 1) * taille)].map(cle)) == base { repetitions += 1 }
                    if repetitions >= 3 {
                        mots.removeSubrange((i + taille)..<(i + repetitions * taille)); changement = true
                    } else { i += 1 }
                }
            }
        }
        return mots.joined(separator: " ")
    }

    /// Nettoie des phrases : répétitions retirées, bruit supprimé, phrase longue répétée deux fois de suite gardée une fois.
    static func nettoyer(_ phrases: [LecturePhrase]) -> [LecturePhrase] {
        var sortie: [LecturePhrase] = []
        for var p in phrases {
            p.texte = retirerRepetitions(p.texte).trimmingCharacters(in: .whitespacesAndNewlines)
            if p.texte.isEmpty || estBruit(p.texte) { continue }
            if let d = sortie.last, motsNormalises(d.texte).count >= 4, motsNormalises(d.texte) == motsNormalises(p.texte), p.debut - d.fin < 10 {
                sortie[sortie.count - 1].fin = max(d.fin, p.fin); continue     // même phrase redite par le moteur : une fois suffit
            }
            sortie.append(p)
        }
        return sortie
    }

    /// Pour le texte du direct : vide si ce n'est que du bruit.
    static func nettoyerTexte(_ texte: String) -> String {
        let t = retirerRepetitions(texte).trimmingCharacters(in: .whitespacesAndNewlines)
        return estBruit(t) ? "" : t
    }

    // MARK: Recoller les phrases coupées

    private static let motsQuiAppellentLaSuite: Set<String> = ["de", "du", "des", "la", "le", "les", "un", "une", "et", "ou", "que", "qui", "a", "au", "aux",
                                                                "pour", "dans", "avec", "mais", "donc", "car", "en", "sur", "par", "sans", "sous", "ce", "se",
                                                                "ne", "n", "d", "l", "qu", "est", "sont", "on", "je", "tu", "il", "elle", "nous", "vous", "ils", "plus", "tres"]

    /// Faux si la phrase se termine « pour de vrai » (point, point d'interrogation ou d'exclamation, deux-points).
    private static func phraseTerminee(_ t: String) -> Bool {
        guard let c = t.trimmingCharacters(in: .whitespacesAndNewlines).last else { return true }
        return ".?!…:;".contains(c)
    }

    private static func commenceParMinuscule(_ t: String) -> Bool {
        guard let c = t.first(where: { $0.isLetter || $0.isNumber }) else { return false }
        return c.isLowercase || c.isNumber
    }

    private static func appelleLaSuite(_ t: String) -> Bool {
        guard let dernier = motsNormalises(t).last else { return false }
        return motsQuiAppellentLaSuite.contains(dernier) || t.hasSuffix(",") || t.hasSuffix("'") || t.hasSuffix("’")
    }

    /// Faut-il joindre `b` à la suite de `a` ? Une pause courte, une phrase de `a` pas finie, et `b` qui continue (minuscule, ou `a` finit sur « de », « et »…).
    static func sontAColler(_ a: LecturePhrase, _ b: LecturePhrase, pauseMax: Double = 1.5, taille: Int = 500) -> Bool {
        let pause = b.debut - a.fin
        guard pause <= pauseMax, pause >= -0.5, !phraseTerminee(a.texte), a.texte.count + b.texte.count < taille else { return false }
        if let x = a.qui, let y = b.qui, x != y { return false }        // deux voix différentes : jamais dans la même phrase
        return commenceParMinuscule(b.texte) || appelleLaSuite(a.texte)
    }

    /// Recolle les phrases voisines coupées par une pause (le moteur coupe à 0,9 s ; un prof qui réfléchit coupe sa phrase en deux).
    /// Garde l'identifiant et les réglages de la première ; sans effet si les phrases sont déjà complètes. Idempotent.
    static func recoller(_ phrases: [LecturePhrase], pauseMax: Double = 1.5) -> [LecturePhrase] {
        var sortie: [LecturePhrase] = []
        for p in phrases {
            if var a = sortie.last, sontAColler(a, p, pauseMax: pauseMax) {
                let colle = a.texte.hasSuffix("'") || a.texte.hasSuffix("’") ? "" : " "
                a.texte += colle + p.texte.trimmingCharacters(in: .whitespacesAndNewlines)
                a.fin = max(a.fin, p.fin)
                if a.qui == nil { a.qui = p.qui; a.score = p.score }
                a.garder = a.garder && p.garder
                sortie[sortie.count - 1] = a
            } else { sortie.append(p) }
        }
        return sortie
    }

    /// Ajoute les phrases d'un morceau au cours, dans l'ordre du temps (deux morceaux peuvent finir dans le désordre),
    /// en recollant la phrase coupée entre la fin d'un morceau et le début du suivant.
    static func inserer(_ nouvelles: [LecturePhrase], dans existantes: [LecturePhrase]) -> [LecturePhrase] {
        guard !nouvelles.isEmpty else { return existantes }
        let tout = (existantes + nouvelles).enumerated().sorted { ($0.element.debut, $0.offset) < ($1.element.debut, $1.offset) }.map(\.element)
        return recoller(tout)
    }
}
