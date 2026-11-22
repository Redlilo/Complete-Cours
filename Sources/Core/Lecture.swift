import Foundation

// « Écouter un cours » (ex-application Écoute-Cours) : modèles, nettoyage du texte, tri et fiche par l'IA, stockage.
// Rien ici ne touche l'interface ni le micro : tout est testable (Tools/Tests/Lecture).
// L'IA est celle choisie dans les Réglages (StructuredGenerator) : aucune clé ni réglage de plus.

// MARK: - Modèles

struct LecturePhrase: Codable, Identifiable, Hashable {
    var id = UUID()
    var debut: Double          // secondes depuis le début du cours
    var fin: Double
    var texte: String
    var garder = true          // décoché à la relecture : ne part jamais chez l'IA
    var qui: LectureQui?       // voix reconnue : prof, élève ? ou incertain (nil : pas de reconnaissance de voix)
    var score: Float?
}

struct LectureDevoir: Codable, Hashable { var quoi: String; var pour: String; var date: Date? = nil }
struct LectureDefinition: Codable, Hashable { var terme: String; var definition: String }
struct LectureFormule: Codable, Hashable { var formule: String; var unite: String }

struct LectureFiche: Codable, Hashable {
    var titre: String
    var resume: String
    var devoirs: [LectureDevoir]
    var definitions: [LectureDefinition]
    var formules: [LectureFormule]
    var aVerifier: [String]

    /// Lit la réponse JSON de l'IA ; tolère les champs absents ou mal typés.
    static func depuis(json: String, titreParDefaut: String) -> LectureFiche {
        guard let racine = LectureTexte.objetJSON(json) else {
            return LectureFiche(titre: titreParDefaut, resume: json, devoirs: [], definitions: [], formules: [],
                                aVerifier: ["La réponse de l'IA n'était pas au bon format : relis bien la fiche."])
        }
        func texte(_ v: Any?) -> String { (v as? String) ?? "" }
        func liste(_ v: Any?) -> [[String: Any]] { (v as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
        return LectureFiche(
            titre: texte(racine["titre"]).isEmpty ? titreParDefaut : texte(racine["titre"]),
            resume: texte(racine["resume"]),
            devoirs: liste(racine["devoirs"]).map { LectureDevoir(quoi: texte($0["quoi"]), pour: texte($0["pour"])) },
            definitions: liste(racine["definitions"]).map { LectureDefinition(terme: texte($0["terme"]), definition: texte($0["def"])) },
            formules: liste(racine["formules"]).map { LectureFormule(formule: texte($0["formule"]), unite: texte($0["unite"])) },
            aVerifier: ((racine["a_verifier"] as? [Any]) ?? []).compactMap { $0 as? String })
    }
}

enum LectureStatut: String, Codable {
    case enregistrement, aRelire, enAttente, traitement, pret, erreur
    var libelle: String {
        switch self {
        case .enregistrement: return "Enregistrement"
        case .aRelire: return "À relire"
        case .enAttente: return "En attente"
        case .traitement: return "En traitement"
        case .pret: return "Prête"
        case .erreur: return "Problème"
        }
    }
}

struct LectureCours: Codable, Identifiable, Hashable {
    var id = UUID()
    var titre: String
    var matiere: String
    var prof: String
    var date = Date()
    var statut: LectureStatut = .aRelire
    var phrases: [LecturePhrase] = []
    var fiche: LectureFiche?
    var retire: [String] = []
    var erreur: String?
    var traiteLe: Date?
    var niveauMax: Float?
}

struct LectureProf: Codable, Hashable, Identifiable {
    var nom: String
    var accord = false
    var dateAccord: String = ""
    var id: String { nom }
}

struct LectureReglages: Codable, Equatable {
    var matieres = ["Réseau", "Électricité", "Maths", "Français", "Anglais", "Histoire-Géo", "Autre"]
    var profs: [LectureProf] = []
    var prenoms: [String] = []
    var lexique = ["VLAN", "RJ45", "switch", "adresse IP", "masque de sous-réseau", "disjoncteur différentiel",
                   "sectionneur", "contacteur", "loi d'Ohm", "ampère", "volt", "ohm", "watt"]
    var corrections = ["loi d'homme=loi d'Ohm", "loi dôme=loi d'Ohm", "loi d' homme=loi d'Ohm", "l'emper=l'ampère", "empère=ampère"]
    var minutesParMorceau = 10
    var minutesSilenceAvantArret = 10
    var minutesMaximum = 120
    var joursAvantEffacementDuTexte = 7
    /// nil ou false : une seconde passe vérifie que chaque définition, formule et devoir de la fiche est bien dans le cours.
    var verificationDesactivee: Bool? = nil
}

struct LectureBase: Codable {
    var cours: [LectureCours] = []
    var reglages = LectureReglages()
    /// Voix mémorisées des profs (par nom de prof). Jamais d'empreinte d'élève.
    var voix: [String: LectureEmpreinte]? = nil
}

// MARK: - Texte

enum LectureTexte {
    /// Premier objet JSON `{ … }` d'une réponse (l'IA ajoute parfois du texte autour).
    static func objetJSON(_ s: String) -> [String: Any]? {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        guard let d = String(s[a...b]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Remplace les prénoms de la classe par « un élève » (mot entier, sans tenir compte des majuscules).
    static func retirerPrenoms(_ texte: String, prenoms: [String]) -> String {
        var t = texte
        for n in Set(prenoms.map { $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            let motif = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: n) + "(?![\\p{L}\\p{N}])"
            if let re = try? NSRegularExpression(pattern: motif, options: [.caseInsensitive]) {
                t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "un élève")
            }
        }
        return t
    }

    /// Corrige les erreurs de transcription : liste « faux=juste », puis mots très proches du lexique.
    static func corriger(_ texte: String, reglages: LectureReglages) -> String {
        var t = texte
        for ligne in reglages.corrections {
            let parts = ligne.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[0].trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let faux = parts[0].trimmingCharacters(in: .whitespaces)
            let motif = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: faux) + "(?!\\w)"
            if let re = try? NSRegularExpression(pattern: motif, options: [.caseInsensitive]) {
                t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t),
                                                withTemplate: NSRegularExpression.escapedTemplate(for: parts[1].trimmingCharacters(in: .whitespaces)))
            }
        }
        let mots = reglages.lexique.filter { !$0.contains(" ") && $0.count >= 5 }
        guard !mots.isEmpty, let re = try? NSRegularExpression(pattern: "\\w+") else { return t }
        var sortie = ""
        var fin = t.startIndex
        for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let r = Range(m.range, in: t) else { continue }
            sortie += t[fin..<r.lowerBound]
            let mot = String(t[r])
            sortie += meilleur(mot, parmi: mots) ?? mot
            fin = r.upperBound
        }
        return sortie + t[fin...]
    }

    private static func meilleur(_ mot: String, parmi mots: [String]) -> String? {
        guard mot.count >= 5 else { return nil }
        let bas = mot.lowercased()
        if mots.contains(where: { $0.lowercased() == bas }) { return nil }
        var best: (String, Double)?
        for c in mots {
            let s = ressemblance(bas, c.lowercased())
            if s >= 0.8, s > (best?.1 ?? 0) { best = (c, s) }
        }
        return best?.0
    }

    /// 1 = identiques, 0 = rien en commun (distance de Levenshtein ramenée à la longueur).
    static func ressemblance(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return x.count == y.count ? 1 : 0 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Découpe un long texte en morceaux (aux fins de phrases) pour que chaque appel à l'IA reste court.
    static func decouper(_ texte: String, taille: Int = 14000) -> [String] {
        var morceaux: [String] = [], courant = ""
        var phrase = ""
        func vider() {
            if courant.count + phrase.count > taille, !courant.isEmpty { morceaux.append(courant); courant = "" }
            courant += phrase; phrase = ""
        }
        for c in texte {
            phrase.append(c)
            if ".!?\n".contains(c) { vider() }
        }
        vider()
        if !courant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { morceaux.append(courant) }
        return morceaux
    }

    /// Regroupe des mots horodatés en phrases (une pause de plus de 0,9 s coupe la phrase).
    static func phrases(depuis mots: [LectureMot], decalage: Double) -> [LecturePhrase] {
        var sortie: [LecturePhrase] = []
        var cur: [String] = [], debut = 0.0, finPrec = 0.0
        func fermer() {
            if !cur.isEmpty { sortie.append(LecturePhrase(debut: decalage + debut, fin: decalage + finPrec, texte: cur.joined(separator: " "))) }
            cur = []
        }
        for m in mots {
            if !cur.isEmpty, m.debut - finPrec > 0.9 { fermer() }
            if cur.isEmpty { debut = m.debut }
            cur.append(m.texte)
            finPrec = m.debut + m.duree
        }
        fermer()
        return sortie
    }

    /// Qui parle, d'après ce qui est dit : 0 = très probablement un élève, 1 = très probablement le prof, 0,5 = on ne sait pas.
    /// Le prof donne des consignes, explique, emploie le vocabulaire du cours, fait des phrases longues ; l'élève fait des phrases
    /// courtes, interpelle (« madame »), demande (« je peux… »), hésite (« euh »).
    static func indiceProf(_ texte: String, lexique: [String] = []) -> Float {
        let t = " " + texte.lowercased() + " "
        let mots = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }).map(String.init)
        guard !mots.isEmpty else { return 0.5 }
        func contient(_ l: [String]) -> Int { l.filter { t.contains($0) }.count }
        var s: Float = 0.5
        // signes d'un élève
        if contient([" madame", " monsieur", " m'sieur", " msieur"]) > 0 { s -= 0.3 }
        if contient([" je peux", " je sais pas", " je comprends pas", " j'ai pas", " j'ai oublié", " on peut", " c'est quoi", " on fait quoi",
                     " je suis pas", " j'arrive pas", " toilettes", " j'ai compris"]) > 0 { s -= 0.2 }
        if contient([" euh", " hum ", " ben ", " bah ", " genre ", " ouais"]) > 0 { s -= 0.1 }
        if mots.count <= 4 { s -= 0.2 }
        if t.contains("?"), mots.count <= 9 { s -= 0.1 }
        // signes du prof
        let consignes = contient([" notez", " écrivez", " regardez", " ouvrez", " sortez", " prenez", " copiez", " faites", " retenez", " souvenez",
                                  " rangez", " relisez", " apprenez", " exercice", " contrôle", " évaluation", " chapitre", " séance", " cahier"])
        s += min(0.3, 0.15 * Float(consignes))
        if contient([" pour lundi", " pour mardi", " pour mercredi", " pour jeudi", " pour vendredi", " pour la prochaine"]) > 0 { s += 0.2 }
        if contient([" on appelle", " c'est-à-dire", " par exemple", " nous allons", " on va ", " vous ", " reprenons", " rappel", " définition",
                     " donc ", " alors "]) > 0 { s += 0.15 }
        if lexique.contains(where: { $0.count >= 3 && t.contains($0.lowercased()) }) { s += 0.15 }
        if mots.count >= 10 { s += 0.15 }
        if mots.count >= 18 { s += 0.1 }
        return min(1, max(0, s))
    }

    /// Les devoirs de toutes les fiches prêtes : d'abord ceux qui ont une date à venir (le plus proche en premier), puis les autres.
    static func agenda(_ cours: [LectureCours], aujourdhui: Date = Date()) -> [(devoir: LectureDevoir, cours: LectureCours)] {
        let tous = cours.filter { $0.statut == .pret }.sorted { $0.date > $1.date }
            .flatMap { c in (c.fiche?.devoirs ?? []).filter { !$0.quoi.isEmpty }.map { (devoir: $0, cours: c) } }
        let debut = Calendar.current.startOfDay(for: aujourdhui)
        let avenir = tous.filter { ($0.devoir.date ?? .distantPast) >= debut }.sorted { $0.devoir.date! < $1.devoir.date! }
        let reste = tous.filter { ($0.devoir.date ?? .distantPast) < debut }
        return avenir + reste
    }

    /// La vraie date d'un devoir d'après ce que dit le prof (« pour mardi », « demain », « dans 3 jours »), à partir du jour du cours.
    static func dateDuDevoir(_ pour: String, depuis jour: Date, calendrier: Calendar = .current) -> Date? {
        let t = pour.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let debut = calendrier.startOfDay(for: jour)
        func plus(_ n: Int) -> Date? { calendrier.date(byAdding: .day, value: n, to: debut) }
        if t.contains("apres-demain") || t.contains("apres demain") { return plus(2) }
        if t.contains("demain") { return plus(1) }
        if let re = try? NSRegularExpression(pattern: "dans (\\d+) jour"), let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let r = Range(m.range(at: 1), in: t), let n = Int(t[r]) { return plus(n) }
        let jours = ["dimanche": 1, "lundi": 2, "mardi": 3, "mercredi": 4, "jeudi": 5, "vendredi": 6, "samedi": 7]
        guard let num = jours.first(where: { t.contains($0.key) })?.value else { return nil }
        var d = 1
        while let c = plus(d), calendrier.component(.weekday, from: c) != num { d += 1; if d > 8 { return nil } }
        return plus(d)
    }

    /// Les corrections à retenir quand l'élève change des mots d'une phrase (même nombre de mots : « empère=ampère »).
    static func corrections(entre ancien: String, et nouveau: String) -> [String] {
        let a = ancien.split(separator: " ").map(String.init), b = nouveau.split(separator: " ").map(String.init)
        guard a.count == b.count, !a.isEmpty else { return [] }
        // plus de 40 % de mots changés : c'est une réécriture de la phrase, pas une correction de mots mal entendus
        guard zip(a, b).filter({ $0 != $1 }).count <= max(1, Int(Double(a.count) * 0.4)) else { return [] }
        func net(_ m: String) -> String { m.trimmingCharacters(in: CharacterSet.letters.union(.decimalDigits).inverted) }
        var sortie: [String] = []
        for (x, y) in zip(a, b) where x != y {
            let cx = net(x), cy = net(y)
            if cx.count >= 3, !cy.isEmpty, cx.lowercased() != cy.lowercased() { sortie.append("\(cx)=\(cy)") }
        }
        return sortie.count <= 3 ? sortie : []   // trop de changements : c'est une réécriture, pas une correction de mots
    }

    /// Les numéros de phrases que l'IA veut retirer, avec le motif (réponse JSON {"retirer":[{"n":3,"motif":"…"}]}).
    static func retraits(json: String) -> [(n: Int, motif: String)] {
        guard let o = objetJSON(json), let l = o["retirer"] as? [Any] else { return [] }
        return l.compactMap { x in
            guard let d = x as? [String: Any] else { return nil }
            let n = (d["n"] as? Int) ?? Int((d["n"] as? String) ?? "") ?? (d["n"] as? Double).map { Int($0) }
            return n.map { (n: $0, motif: (d["motif"] as? String) ?? "") }
        }
    }
}

/// Un mot reconnu avec son horodatage (secondes depuis le début de l'enregistrement).
struct LectureMot: Hashable { var texte: String; var debut: Double; var duree: Double }

// MARK: - Tri et fiche par l'IA

enum LecturePrompts {
    static let system = """
    Tu aides une élève de Seconde (bac pro MTNE) à réviser. Tu nettoies des transcriptions de cours et tu écris \
    des fiches claires. Tu n'inventes rien : tout vient du texte. Réponds uniquement avec le JSON demandé, en français simple.
    """

    /// Le tri ne récrit rien : l'IA ne renvoie que les numéros des phrases à retirer (le texte du prof reste exactement celui dit).
    static func triNumerote(_ lignes: String, lexique: [String]) -> String {
        """
        Voici des phrases numérotées d'un cours (surtout la voix du prof, avec parfois des phrases d'élèves ou des remarques). \
        Certaines portent un avis automatique sur la voix : ⟨voix : élève ?⟩ ou ⟨voix incertaine⟩. C'est un indice, pas une certitude : \
        décide d'après le sens.
        Donne les numéros des phrases à RETIRER : remarques ou questions adressées à un élève précis (discipline, retard, téléphone, \
        « assieds-toi »…), l'appel, les blagues, le bavardage, la logistique sans intérêt, les phrases d'élèves sans rapport avec le cours.
        NE RETIRE JAMAIS : explications, définitions, exemples, formules, consignes pour toute la classe (devoirs, dates de contrôle, \
        documents à apporter), réponses du prof à une question d'élève. En cas de doute, ne retire pas.
        Mots techniques possibles du cours : \(lexique.joined(separator: ", ")). Ne récris rien, ne corrige rien.

        PHRASES :
        \(lignes)
        """
    }

    static func fiche(_ garde: String, matiere: String, prof: String, jour: String) -> String {
        """
        Voici le contenu nettoyé d'un cours de \(matiere.isEmpty ? "lycée" : matiere) (\(prof.isEmpty ? "prof" : prof)) du \(jour), niveau Seconde bac pro.
        Écris une fiche de révision claire, en français simple. N'invente aucune information absente du texte : pas de définition, \
        d'unité ni de formule que le prof n'a pas dites.
        « resume » : du Markdown avec des titres ## et des listes. « devoirs » : ce que le prof demande ; « pour » = les mots exacts du prof \
        (« mardi », « demain »…), sans calculer de date. « a_verifier » : passages douteux ou mots techniques incertains.

        COURS :
        \(garde)
        """
    }

    /// Seconde passe : chaque définition, formule et devoir de la fiche est-il bien dans le cours ?
    static func verification(cours: String, fiche: LectureFiche) -> String {
        var l = "DÉFINITIONS :\n" + fiche.definitions.enumerated().map { "\($0.offset + 1). \($0.element.terme) : \($0.element.definition)" }.joined(separator: "\n")
        l += "\nFORMULES :\n" + fiche.formules.enumerated().map { "\($0.offset + 1). \($0.element.formule) \($0.element.unite)" }.joined(separator: "\n")
        l += "\nDEVOIRS :\n" + fiche.devoirs.enumerated().map { "\($0.offset + 1). \($0.element.quoi) — \($0.element.pour)" }.joined(separator: "\n")
        return """
        Voici un cours (texte du prof) puis des éléments d'une fiche de révision. Pour chacun, dis s'il est dit CLAIREMENT dans le cours. \
        Un élément absent du cours, ou dont un détail (unité, valeur, date) a été ajouté, est « non soutenu ». Ne juge pas la qualité.
        Réponds avec la liste des seuls éléments non soutenus : type (« definition », « formule » ou « devoir »), numero (celui de la liste) et raison courte.

        COURS :
        \(cours)

        \(l)
        """
    }

    static let triSchema: [String: Any] = [
        "type": "object",
        "properties": ["retirer": ["type": "array", "items": ["type": "object",
            "properties": ["n": ["type": "integer"], "motif": ["type": "string"]], "required": ["n", "motif"], "additionalProperties": false]]],
        "required": ["retirer"], "additionalProperties": false,
    ]

    static let verificationSchema: [String: Any] = [
        "type": "object",
        "properties": ["non_soutenus": ["type": "array", "items": ["type": "object",
            "properties": ["type": ["type": "string"], "numero": ["type": "integer"], "raison": ["type": "string"]],
            "required": ["type", "numero", "raison"], "additionalProperties": false]]],
        "required": ["non_soutenus"], "additionalProperties": false,
    ]

    static let ficheSchema: [String: Any] = {
        func obj(_ p: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": p, "required": p.keys.sorted(), "additionalProperties": false]
        }
        let s: [String: Any] = ["type": "string"]
        func arr(_ i: [String: Any]) -> [String: Any] { ["type": "array", "items": i] }
        return obj(["titre": s, "resume": s,
                    "devoirs": arr(obj(["quoi": s, "pour": s])),
                    "definitions": arr(obj(["terme": s, "def": s])),
                    "formules": arr(obj(["formule": s, "unite": s])),
                    "a_verifier": arr(s)])
    }()
}

enum LecturePipeline {
    /// Les phrases retirées pour un morceau, après garde-fous : numéros hors du morceau ignorés ; une consigne claire du prof n'est
    /// jamais retirée ; si l'IA veut retirer presque tout le morceau, elle s'est trompée : on ignore son tri et on le signale.
    static func appliquerRetraits(textes: [String], retraits: [(n: Int, motif: String)], morceau: [Int],
                                  lexique: [String]) -> (retires: [Int: String], alerte: String?) {
        let valides = retraits.filter { morceau.contains($0.n) }
        if morceau.count >= 5, Double(Set(valides.map(\.n)).count) > 0.7 * Double(morceau.count) {
            return ([:], "Le tri voulait retirer presque tout un morceau du cours : il a été ignoré, relis bien ce passage.")
        }
        var r: [Int: String] = [:]
        for v in valides where LectureTexte.indiceProf(textes[v.n], lexique: lexique) < 0.9 { r[v.n] = v.motif }
        return (r, nil)
    }

    /// Tri par numéros (3 appels à la fois au plus), fiche, puis vérification de la fiche. Lève l'erreur du moteur telle quelle.
    static func traiter(_ cours: LectureCours, reglages: LectureReglages, generator: StructuredGenerator) async throws
        -> (fiche: LectureFiche, retire: [String]) {
        let gardees = cours.phrases.filter(\.garder).map { (texte: retirerPrenomsEtCorriger($0.texte, reglages), qui: $0.qui) }
            .filter { !$0.texte.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !gardees.isEmpty else { throw LectureErreur.vide }
        let textes = gardees.map(\.texte)

        var morceaux: [[Int]] = [], courant: [Int] = [], taille = 0
        for (i, g) in gardees.enumerated() {
            if taille + g.texte.count > 12000, !courant.isEmpty { morceaux.append(courant); courant = []; taille = 0 }
            courant.append(i); taille += g.texte.count + 8
        }
        if !courant.isEmpty { morceaux.append(courant) }

        var reponses = [[(n: Int, motif: String)]](repeating: [], count: morceaux.count)
        var suivant = 0
        try await withThrowingTaskGroup(of: (Int, [(n: Int, motif: String)]).self) { groupe in
            func lancer() {
                guard suivant < morceaux.count else { return }
                let k = suivant; suivant += 1
                let lignes = morceaux[k].map { i -> String in
                    let avis = gardees[i].qui == .autre ? " ⟨voix : élève ?⟩" : (gardees[i].qui == .incertain ? " ⟨voix incertaine⟩" : "")
                    return "[\(i)] \(gardees[i].texte)\(avis)"
                }.joined(separator: "\n")
                groupe.addTask {
                    let json = try await generator.generate(system: LecturePrompts.system,
                                                            userText: LecturePrompts.triNumerote(lignes, lexique: reglages.lexique),
                                                            images: [], schema: LecturePrompts.triSchema)
                    return (k, LectureTexte.retraits(json: json))
                }
            }
            for _ in 0..<min(3, morceaux.count) { lancer() }
            while let (k, r) = try await groupe.next() { reponses[k] = r; lancer() }
        }

        var retires: [Int: String] = [:], alertes: [String] = []
        for (k, m) in morceaux.enumerated() {
            let res = appliquerRetraits(textes: textes, retraits: reponses[k], morceau: m, lexique: reglages.lexique)
            retires.merge(res.retires) { a, _ in a }
            if let a = res.alerte { alertes.append(a) }
        }
        let garde = textes.enumerated().filter { retires[$0.offset] == nil }.map(\.element).joined(separator: "\n")
        guard !garde.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LectureErreur.vide }
        let retire = retires.keys.sorted().map { retires[$0]!.isEmpty ? textes[$0] : "\(textes[$0]) — \(retires[$0]!)" }

        let jour = cours.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let json = try await generator.generate(system: LecturePrompts.system,
                                                userText: LecturePrompts.fiche(garde, matiere: cours.matiere, prof: cours.prof, jour: jour),
                                                images: [], schema: LecturePrompts.ficheSchema)
        var fiche = LectureFiche.depuis(json: json, titreParDefaut: cours.titre)
        fiche.devoirs = fiche.devoirs.map { var d = $0; d.date = LectureTexte.dateDuDevoir(d.pour, depuis: cours.date); return d }
        fiche.aVerifier += alertes
        if reglages.verificationDesactivee != true {
            do {
                let v = try await generator.generate(system: LecturePrompts.system, userText: LecturePrompts.verification(cours: garde, fiche: fiche),
                                                     images: [], schema: LecturePrompts.verificationSchema)
                fiche.aVerifier += notesDeVerification(v, fiche: fiche)
            } catch {
                fiche.aVerifier.append("La vérification automatique de la fiche n'a pas pu se faire : relis bien les définitions et les formules.")
            }
        }
        return (fiche, retire)
    }

    /// Transforme la réponse de la seconde passe en notes « à vérifier » lisibles.
    static func notesDeVerification(_ json: String, fiche: LectureFiche) -> [String] {
        guard let o = LectureTexte.objetJSON(json), let l = o["non_soutenus"] as? [Any] else { return [] }
        return l.compactMap { x in
            guard let d = x as? [String: Any], let n = d["numero"] as? Int, n >= 1 else { return nil }
            let t = ((d["type"] as? String) ?? "").lowercased(), raison = (d["raison"] as? String) ?? "pas dit clairement dans le cours"
            if t.hasPrefix("def"), n <= fiche.definitions.count { return "Définition « \(fiche.definitions[n - 1].terme) » : \(raison)" }
            if t.hasPrefix("form"), n <= fiche.formules.count { return "Formule « \(fiche.formules[n - 1].formule) » : \(raison)" }
            if t.hasPrefix("dev"), n <= fiche.devoirs.count { return "Devoir « \(fiche.devoirs[n - 1].quoi) » : \(raison)" }
            return nil
        }
    }

    static func retirerPrenomsEtCorriger(_ texte: String, _ r: LectureReglages) -> String {
        LectureTexte.retirerPrenoms(LectureTexte.corriger(texte, reglages: r), prenoms: r.prenoms)
    }
}

enum LectureErreur: LocalizedError {
    case vide, micRefuse, langueAbsente, transcription(String)
    var errorDescription: String? {
        switch self {
        case .vide: return "Il n'y a aucun texte à envoyer : tout est décoché ou rien n'a été reconnu."
        case .micRefuse: return "Le Mac a refusé le micro. Autorise Complète-Cours dans Réglages Système > Confidentialité et sécurité > Micro."
        case .langueAbsente: return "Le français n'est pas installé pour la dictée. Ajoute-le dans Réglages Système > Clavier > Dictée."
        case .transcription(let m): return "La transcription a échoué : \(m)"
        }
    }
}

// MARK: - Stockage (un fichier JSON dans Application Support)

final class LectureStore {
    let url: URL
    init(url: URL? = nil) {
        if let url { self.url = url; return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dossier = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Complete-Cours", isDirectory: true)
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        self.url = dossier.appendingPathComponent("Lecture.json")
    }

    func charger() -> LectureBase {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: url), var b = try? dec.decode(LectureBase.self, from: d) else { return LectureBase() }
        // un cours resté « en enregistrement » ou « en traitement » (app fermée) redevient à relire / en attente
        for i in b.cours.indices {
            if b.cours[i].statut == .enregistrement { b.cours[i].statut = b.cours[i].phrases.isEmpty ? .erreur : .aRelire
                b.cours[i].erreur = b.cours[i].phrases.isEmpty ? "L'enregistrement a été interrompu." : nil }
            if b.cours[i].statut == .traitement { b.cours[i].statut = .enAttente }
        }
        return b
    }

    func sauver(_ base: LectureBase) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(base) { try? d.write(to: url, options: .atomic) }
    }

    /// Efface le texte brut des fiches prêtes depuis plus de N jours (la fiche reste).
    static func nettoyer(_ base: inout LectureBase, maintenant: Date = Date()) {
        let limite = maintenant.addingTimeInterval(-Double(base.reglages.joursAvantEffacementDuTexte) * 86400)
        for i in base.cours.indices where base.cours[i].statut == .pret && (base.cours[i].traiteLe ?? .distantFuture) < limite {
            base.cours[i].phrases = []
        }
    }
}
