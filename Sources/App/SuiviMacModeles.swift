#if COMPTE_PERSO
import Foundation

// « Suivi MacBook IA » : suivi PAR MODÈLE (et non par site), prix du marché, bonnes affaires, changements depuis le
// relevé précédent, alertes et allègement de l'historique. Calculs purs, testables sans réseau ni disque.

/// Un modèle suivi : puce + écran + mémoire (+ stockage). Stockage vide = tous les stockages.
struct SuiviModele: Codable, Equatable, Identifiable, Hashable {
    var puce: String
    var ecran: Int
    var ram: Int
    var ssd: String

    var id: String { "\(puce)|\(ecran)|\(ram)|\(ssd)" }
    var nom: String { "\(puce) \(ecran == 0 ? "" : "\(ecran)\" ")\(ram) Go" + (ssd.isEmpty ? "" : " · \(ssd)") }

    func correspond(_ o: SuiviOffre) -> Bool {
        (puce == "Ultra" ? o.puce.hasSuffix("Ultra") : o.puce == puce) && (ecran == 0 || o.ecran == ecran) && o.ram == ram && (ssd.isEmpty || o.ssd == ssd)
    }

    /// Tes trois modèles (écran et stockage au choix) ; à changer dans l'écran « Mes 3 modèles ».
    static let parDefaut: [SuiviModele] = [
        SuiviModele(puce: "M4 Max", ecran: 0, ram: 48, ssd: ""),
        SuiviModele(puce: "M3 Max", ecran: 0, ram: 48, ssd: ""),
        SuiviModele(puce: "M2 Max", ecran: 0, ram: 64, ssd: ""),
    ]
}

enum SuiviBadge: Equatable {
    case nouvelle
    case baisse(Double)
    case hausse(Double)
}

struct SuiviChangements {
    var parCle: [String: SuiviBadge] = [:]
    var disparues: [SuiviOffre] = []
    var depuis: Date?
}

struct SuiviAffaire: Identifiable {
    var evaluation: SuiviEvaluation
    var reference: Double       // prix du marché : médiane des offres du même modèle dans le même état
    var nbReference: Int
    var ecart: Double           // en % : positif = moins cher que le marché
    var economieNeuf: Double?   // en % : écart avec la médiane des offres NEUVES du même modèle
    var suspect: Bool           // beaucoup trop bas pour être honnête
    var perfVoisins: Double?    // en % : bande passante de l'offre vs médiane des offres à ±10 % du même prix (tous modèles)
    var nbVoisins: Int = 0
    /// Note de rentabilité : moyenne de l'économie vs marché et de l'avantage de performance vs les offres au même prix.
    var note: Double { [ecart, perfVoisins].compactMap { $0 }.reduce(0, +) / Double([ecart, perfVoisins].compactMap { $0 }.count) }
    var id: String { evaluation.id }
    var offre: SuiviOffre { evaluation.offre }
}

struct SuiviAlerte { var titre: String; var texte: String }

struct SuiviSuiviModele: Identifiable {
    var modele: SuiviModele
    var offres: [SuiviEvaluation]          // moins chère d'abord
    var meilleur: SuiviEvaluation? { offres.first }
    var mediane: Double?
    var vendeurs: Int
    var minPrecedent: Double?
    var plusBasObserve: Double?
    var serieMin: [SuiviCalcul.Point]
    var serieMediane: [SuiviCalcul.Point]
    var id: String { modele.id }
}

enum SuiviModeles {
    // MARK: Outils

    static func mediane(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private static func cleModele(_ o: SuiviOffre) -> String { "\(o.puce)|\(o.ecran)|\(o.ram)|\(o.ssd)" }

    /// 0 = neuf, 1 = reconditionné (Apple ou autre), 2 = occasion de particulier.
    private static func classe(_ o: SuiviOffre) -> Int {
        switch o.etat { case .neuf: return 0; case .reconditionneApple, .reconditionneTiers: return 1; case .occasion: return 2 }
    }

    private static func livrables(_ offres: [SuiviOffre]) -> [SuiviOffre] {
        SuiviCalcul.regrouper(offres).filter { $0.livraison != .non && $0.ecran > 0 }
    }

    // MARK: Prix du marché et bonnes affaires

    /// Pour chaque offre : écart avec la médiane du marché (même modèle, même état, au moins 3 offres de 2 vendeurs).
    static func affaires(_ evals: [SuiviEvaluation], marche offres: [SuiviOffre]) -> [SuiviAffaire] {
        let base = livrables(offres)
        var parGroupe: [String: [SuiviOffre]] = [:]
        var neufs: [String: [Double]] = [:]
        for o in base {
            parGroupe["\(cleModele(o))|\(classe(o))", default: []].append(o)
            if classe(o) == 0 { neufs[cleModele(o), default: []].append(o.prix) }
        }
        // Offres « autour de ce prix » : toutes les offres livrables classables, tous modèles confondus.
        let classables = evals.filter { $0.bande != nil && $0.offre.livraison != .non }
        var res: [SuiviAffaire] = []
        for e in evals {
            let o = e.offre
            guard let g = parGroupe["\(cleModele(o))|\(classe(o))"], g.count >= 3, Set(g.map(\.source)).count >= 2,
                  let ref = mediane(g.map(\.prix)), ref > 0 else { continue }
            let ecart = (ref - o.prix) / ref * 100
            var neuf: Double?
            if classe(o) != 0, let n = neufs[cleModele(o)], n.count >= 2, let m = mediane(n), m > 0 { neuf = (m - o.prix) / m * 100 }
            var perf: Double?
            let voisins = classables.filter { $0.id != e.id && abs($0.offre.prix - o.prix) <= o.prix * 0.10 }.compactMap { $0.bande.map(Double.init) }
            if let b = e.bande, voisins.count >= 4, let m = mediane(voisins), m > 0 { perf = (Double(b) - m) / m * 100 }
            res.append(SuiviAffaire(evaluation: e, reference: ref, nbReference: g.count, ecart: ecart, economieNeuf: neuf,
                                    suspect: ecart >= 30, perfVoisins: perf, nbVoisins: voisins.count))
        }
        // Les prix suspects en dernier ; le reste par note de rentabilité décroissante.
        return res.sorted { ($0.suspect ? 1 : 0, -$0.note) < ($1.suspect ? 1 : 0, -$1.note) }
    }

    // MARK: Suivi d'un modèle

    static func suivi(_ m: SuiviModele, releves: [SuiviReleve], manuelles: [SuiviOffre], filtres: SuiviFiltres) -> SuiviSuiviModele {
        func offres(_ r: SuiviReleve?) -> [SuiviOffre] {
            guard let r else { return [] }
            let evals = (SuiviCalcul.regrouper(r.offres) + manuelles.filter { ($0.ajoutee ?? .distantPast) <= r.date }).map { SuiviCalcul.evaluer($0) }
            return SuiviCalcul.filtrer(evals, filtres).map(\.offre).filter { m.correspond($0) }
        }
        var smin: [SuiviCalcul.Point] = [], smed: [SuiviCalcul.Point] = []
        for r in releves {
            let p = offres(r).map(\.prix)
            if let mn = p.min() { smin.append(.init(date: r.date, valeur: mn)) }
            if let md = mediane(p) { smed.append(.init(date: r.date, valeur: md)) }
        }
        let actuelles = SuiviCalcul.filtrer((SuiviCalcul.regrouper(releves.last?.offres ?? []) + manuelles).map { SuiviCalcul.evaluer($0) }, filtres)
            .filter { m.correspond($0.offre) }.sorted { $0.offre.prix < $1.offre.prix }
        let avant = releves.count > 1 ? offres(releves[releves.count - 2]).map(\.prix).min() : nil
        return SuiviSuiviModele(modele: m, offres: actuelles, mediane: mediane(actuelles.map(\.offre.prix)),
                                vendeurs: Set(actuelles.map(\.offre.source)).count, minPrecedent: avant,
                                plusBasObserve: smin.map(\.valeur).min(), serieMin: smin, serieMediane: smed)
    }

    // MARK: Changements depuis le relevé précédent (jour précédent si possible)

    static func changements(_ releves: [SuiviReleve]) -> SuiviChangements {
        guard let dernier = releves.last, releves.count > 1 else { return SuiviChangements() }
        let cal = Calendar.current
        let ancien = releves.dropLast().last { !cal.isDate($0.date, inSameDayAs: dernier.date) } ?? releves[releves.count - 2]
        let avant = Dictionary(SuiviCalcul.regrouper(ancien.offres).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var res = SuiviChangements(depuis: ancien.date)
        var vus = Set<String>()
        for o in SuiviCalcul.regrouper(dernier.offres) {
            vus.insert(o.key)
            if let q = avant[o.key] {
                if o.prix < q.prix { res.parCle[o.key] = .baisse(q.prix - o.prix) }
                else if o.prix > q.prix { res.parCle[o.key] = .hausse(o.prix - q.prix) }
            } else { res.parCle[o.key] = .nouvelle }
        }
        res.disparues = avant.values.filter { !vus.contains($0.key) && $0.livraison != .non }.sorted { $0.prix < $1.prix }
        return res
    }

    // MARK: Alertes (après un relevé)

    static func alertes(releves: [SuiviReleve], manuelles: [SuiviOffre], favoris: [SuiviModele], filtres: SuiviFiltres,
                        seuilBaisse: Double) -> [SuiviAlerte] {
        guard releves.count > 1, let nouveau = releves.last else { return [] }
        let ancien = releves[releves.count - 2]
        let eur: (Double) -> String = { $0.formatted(.currency(code: "EUR").precision(.fractionLength(0)).locale(Locale(identifier: "fr_FR"))) }
        var out: [SuiviAlerte] = []

        // 1. Un de mes modèles atteint un nouveau prix bas
        for m in favoris {
            let s = suivi(m, releves: [ancien, nouveau], manuelles: manuelles, filtres: filtres)
            if let b = s.meilleur, let p = s.minPrecedent, b.offre.prix < p {
                out.append(SuiviAlerte(titre: "Prix en baisse : \(m.nom)", texte: "\(eur(b.offre.prix)) chez \(b.offre.source) (avant : \(eur(p)))"))
            }
        }
        // 1 bis. Une puce Ultra apparaît sur un MacBook Pro (elle n'existe pas encore : aujourd'hui, seulement Mac Studio / Mac Pro)
        let ultraAvant = Set(ancien.offres.filter { $0.puce.hasSuffix("Ultra") }.map(\.key))
        if let u = SuiviCalcul.regrouper(nouveau.offres).first(where: { $0.puce.hasSuffix("Ultra") && !ultraAvant.contains($0.key) }) {
            out.append(SuiviAlerte(titre: "Une puce Ultra est apparue sur MacBook Pro !", texte: "\(SuiviCalcul.nomCourt(u)) chez \(u.source) : \(eur(u.prix))"))
        }
        // 2. Nouvelle meilleure offre dans une tranche
        func evals(_ r: SuiviReleve) -> [SuiviEvaluation] {
            SuiviCalcul.filtrer((SuiviCalcul.regrouper(r.offres) + manuelles).map { SuiviCalcul.evaluer($0) }, filtres)
        }
        let eAvant = evals(ancien), eApres = evals(nouveau)
        for n in SuiviCalcul.paliers.indices {
            let b = SuiviCalcul.bornes(n, parTranche: true)
            for ram in [36, 48] {
                guard let a = SuiviCalcul.meilleurSousBudget(eApres, budget: b.maximum, ram: ram, minimum: b.minimum), let ab = a.bande else { continue }
                let o = SuiviCalcul.meilleurSousBudget(eAvant, budget: b.maximum, ram: ram, minimum: b.minimum)
                let mieux = o == nil || (o?.bande ?? 0) < ab || ((o?.bande ?? 0) == ab && a.offre.prix < (o?.offre.prix ?? .infinity))
                if mieux, o != nil {
                    out.append(SuiviAlerte(titre: "Nouvelle meilleure offre \(ram) Go (\(eur(b.minimum))–\(eur(b.maximum)))",
                                           texte: "\(SuiviCalcul.nomCourt(a.offre)) : \(eur(a.offre.prix)) chez \(a.offre.source)"))
                }
            }
        }
        // 3. Grosses baisses de prix
        let avant = Dictionary(SuiviCalcul.regrouper(ancien.offres).map { ($0.key, $0.prix) }, uniquingKeysWith: { a, _ in a })
        var baisses: [(Double, SuiviOffre, Double)] = []
        for o in SuiviCalcul.regrouper(nouveau.offres) where o.livraison != .non {
            if let q = avant[o.key], q - o.prix >= 100, (q - o.prix) / q * 100 >= seuilBaisse { baisses.append(((q - o.prix) / q, o, q)) }
        }
        for (_, o, q) in baisses.sorted(by: { $0.0 > $1.0 }).prefix(2) {
            out.append(SuiviAlerte(titre: "Baisse de \(Int(((q - o.prix) / q * 100).rounded())) %",
                                   texte: "\(SuiviCalcul.nomCourt(o)) chez \(o.source) : \(eur(o.prix)) (avant : \(eur(q)))"))
        }
        // 4. Nouvelle bonne affaire par rapport au marché
        let anciennes = Set(SuiviCalcul.regrouper(ancien.offres).map(\.key))
        let offresAffaires = affaires(eApres, marche: nouveau.offres).filter { !$0.suspect && $0.ecart >= 15 && !anciennes.contains($0.offre.key) }
        if let a = offresAffaires.first {
            out.append(SuiviAlerte(titre: "Bonne affaire : \(Int(a.ecart.rounded())) % sous le marché",
                                   texte: "\(SuiviCalcul.nomCourt(a.offre)) chez \(a.offre.source) : \(eur(a.offre.prix)) (marché : \(eur(a.reference)))"))
        }
        // 5. Un saut devient « très rentable » : rajouter un peu d'argent rapporte beaucoup de performance
        func fiable(_ evs: [SuiviEvaluation]) -> [SuiviEvaluation] { evs.filter { !$0.offre.annonceParticulier } }
        let avantTresRentables = Set(echelle(fiable(eAvant)).echelons.filter { $0.verdict.niveau == 3 }.map(\.vers.id))
        if let saut = echelle(fiable(eApres)).echelons.first(where: { $0.verdict.niveau == 3 && $0.deltaPourcent >= 8 && !avantTresRentables.contains($0.vers.id) }) {
            out.append(SuiviAlerte(titre: "Saut très rentable : +\(eur(saut.deltaPrix)) pour +\(Int(saut.deltaPourcent.rounded())) % de performance",
                                   texte: "\(SuiviCalcul.nomCourt(saut.de.offre)) (\(eur(saut.de.offre.prix))) → \(SuiviCalcul.nomCourt(saut.vers.offre)) chez \(saut.vers.offre.source) (\(eur(saut.vers.offre.prix)))"))
        }
        return out
    }

    // MARK: Historique : un relevé par jour, fichier plus léger

    private static func lettres(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Fusionne deux relevés du même jour : le nouveau gagne, sauf pour les sites qui n'ont pas répondu dans le nouveau
    /// (on garde alors leurs offres de l'ancien, sinon un relevé raté « effacerait » des offres).
    static func fusionner(ancien: SuiviReleve, nouveau: SuiviReleve) -> SuiviReleve {
        let ratees = Set(nouveau.erreurs.keys).union(nouveau.comptes.filter { $0.value == 0 }.keys).map(lettres)
        var offres = nouveau.offres
        let cles = Set(offres.map(\.key))
        for o in ancien.offres where !cles.contains(o.key) {
            let prefixe = lettres(String(o.key.split(separator: "|").first ?? ""))
            if !prefixe.isEmpty, ratees.contains(where: { $0.hasPrefix(prefixe) || prefixe.hasPrefix($0) }) { offres.append(o) }
        }
        var comptes = nouveau.comptes
        for (k, v) in ancien.comptes where comptes[k] == nil || comptes[k] == 0 { comptes[k] = v }
        let erreurs = nouveau.erreurs.filter { ancien.comptes[$0.key] ?? 0 == 0 }
        return SuiviReleve(date: nouveau.date, offres: offres, erreurs: erreurs, comptes: comptes)
    }

    /// Ajoute un relevé : s'il y en a déjà un aujourd'hui, ils sont fusionnés. Au-delà de 90 jours, une semaine = un relevé.
    static func ajouter(_ r: SuiviReleve, a releves: [SuiviReleve]) -> [SuiviReleve] {
        let cal = Calendar.current
        var liste = releves
        if let i = liste.lastIndex(where: { cal.isDate($0.date, inSameDayAs: r.date) }) {
            liste[i] = fusionner(ancien: liste[i], nouveau: r)
        } else {
            liste.append(r)
        }
        return alleger(liste)
    }

    /// Un seul relevé par jour (le dernier, fusionné) ; plus de 90 jours : un par semaine.
    static func alleger(_ releves: [SuiviReleve], maintenant: Date = Date()) -> [SuiviReleve] {
        let cal = Calendar.current
        var parJour: [SuiviReleve] = []
        for r in releves.sorted(by: { $0.date < $1.date }) {
            if let l = parJour.last, cal.isDate(l.date, inSameDayAs: r.date) { parJour[parJour.count - 1] = fusionner(ancien: l, nouveau: r) }
            else { parJour.append(r) }
        }
        var vues = Set<Int>()
        return parJour.reversed().filter { r in
            guard let age = cal.dateComponents([.day], from: r.date, to: maintenant).day, age > 90 else { return true }
            let semaine = cal.component(.weekOfYear, from: r.date) + 100 * cal.component(.yearForWeekOfYear, from: r.date)
            return vues.insert(semaine).inserted
        }.reversed()
    }

    // MARK: Export CSV

    static func csv(_ evals: [SuiviEvaluation]) -> String {
        func c(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var l = ["Machine;Vendeur;Pays;État;Prix (€);Go/s;€ par Go/s;Livraison;Clavier;Lien"]
        for e in evals {
            let o = e.offre
            l.append([c(SuiviCalcul.nomCourt(o)), c(o.source), o.pays, c(o.etat.libelle), String(Int(o.prix.isFinite ? max(-1e9, min(1e9, o.prix)) : 0)), e.bande.map(String.init) ?? "",
                      e.score.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") } ?? "",
                      c(o.livraison.libelle), c(o.clavier), c(o.url)].joined(separator: ";"))
        }
        return l.joined(separator: "\n")
    }
}

// MARK: - Échelle de performance : que coûte le gain quand on rajoute un peu ?

/// Un échelon entre deux offres voisines de la « frontière » (chaque offre est plus chère ET plus rapide que la précédente).
struct SuiviEchelon: Identifiable {
    var de: SuiviEvaluation
    var vers: SuiviEvaluation
    var deltaPrix: Double
    var deltaBande: Int
    var deltaPourcent: Double          // gain de bande passante en %
    var euroParGoS: Double             // coût de chaque Go/s en plus
    var rapport: Double                // euroParGoS ÷ prix actuel par Go/s de l'offre de départ (< 1 : le saut est plus rentable que ce que tu paies déjà)
    var id: String { de.id + ">" + vers.id }

    var verdict: (texte: String, niveau: Int) {   // niveau : 3 très rentable, 2 rentable, 1 correct, 0 cher
        if rapport < 0.75 { return ("Très rentable", 3) }
        if rapport < 1.0 { return ("Rentable", 2) }
        if rapport < 1.5 { return ("Correct", 1) }
        return ("Cher pour le gain", 0)
    }
}

struct SuiviEchelle {
    var echelons: [SuiviEchelon]
    /// Dernière offre qu'il vaut le coup d'atteindre (voir `echelle`).
    var optimum: SuiviEvaluation?
    var meilleurSaut: SuiviEchelon?
}

extension SuiviModeles {
    /// `evals` : offres déjà filtrées (livrables…). `exclus` : identifiants à ignorer (prix suspects).
    static func echelle(_ evals: [SuiviEvaluation], exclus: Set<String> = []) -> SuiviEchelle {
        let candidates = evals.filter { $0.bande != nil && $0.offre.livraison != .non && !exclus.contains($0.id) }
            .sorted { ($0.offre.prix, -($0.bande ?? 0)) < ($1.offre.prix, -($1.bande ?? 0)) }
        var frontiere: [SuiviEvaluation] = []
        for e in candidates {
            if let d = frontiere.last, let db = d.bande, let eb = e.bande, eb <= db { continue }   // moins cher déjà aussi rapide
            frontiere.append(e)
        }
        var echelons: [SuiviEchelon] = []
        for (a, b) in zip(frontiere, frontiere.dropFirst()) {
            guard let ba = a.bande, let bb = b.bande, let sa = a.score else { continue }
            let dp = b.offre.prix - a.offre.prix, db = bb - ba
            guard dp > 0, db > 0 else { continue }
            let marginal = dp / Double(db)
            echelons.append(SuiviEchelon(de: a, vers: b, deltaPrix: dp, deltaBande: db, deltaPourcent: Double(db) / Double(ba) * 100,
                                         euroParGoS: marginal, rapport: marginal / sa))
        }
        // Point d'arrêt : depuis une offre, on saute vers la plus lointaine dont le coût par Go/s EN PLUS reste au plus égal à ce qu'on
        // paie déjà par Go/s (on regarde plus loin que le saut suivant : un saut cher peut être suivi d'un très bon).
        var optimum = frontiere.first
        var i = 0
        while i < frontiere.count - 1 {
            guard let bi = frontiere[i].bande, let si = frontiere[i].score else { break }
            var suivant: Int?
            for j in stride(from: frontiere.count - 1, to: i, by: -1) {
                guard let bj = frontiere[j].bande, bj > bi else { continue }
                if (frontiere[j].offre.prix - frontiere[i].offre.prix) / Double(bj - bi) <= si { suivant = j; break }
            }
            guard let j = suivant else { break }
            i = j; optimum = frontiere[j]
        }
        return SuiviEchelle(echelons: echelons, optimum: optimum, meilleurSaut: echelons.min { $0.euroParGoS < $1.euroParGoS })
    }
}

/// Un point de la courbe de l'échelle : à chaque relevé, le meilleur saut et le prix du point d'arrêt conseillé.
struct SuiviPointEchelle: Identifiable {
    var date: Date
    var euroParGoS: Double?       // coût du meilleur saut (€ par Go/s en plus)
    var prixOptimum: Double?      // prix de l'offre jusqu'où il vaut le coup de monter
    var id: Date { date }
}

extension SuiviModeles {

    /// L'échelle à chaque relevé (annonces de particuliers exclues), pour une mémoire donnée (0 = toutes).
    static func historiqueEchelle(_ releves: [SuiviReleve], manuelles: [SuiviOffre], filtres: SuiviFiltres, ram: Int) -> [SuiviPointEchelle] {
        releves.compactMap { r in
            let offres = SuiviCalcul.regrouper(r.offres) + manuelles.filter { ($0.ajoutee ?? .distantPast) <= r.date }
            let evs = SuiviCalcul.filtrer(offres.map { SuiviCalcul.evaluer($0) }, filtres)
                .filter { !$0.offre.annonceParticulier && (ram == 0 || $0.offre.ram == ram) }
            let e = echelle(evs)
            guard e.meilleurSaut != nil || e.optimum != nil else { return nil }
            return SuiviPointEchelle(date: r.date, euroParGoS: e.meilleurSaut?.euroParGoS, prixOptimum: e.optimum?.offre.prix)
        }
    }
}

// MARK: - Vitesse d'une IA locale : mesures publiques + taille du modèle visé

/// Précision des poids : 4 bits (léger, un peu moins précis) ou 8 bits (plus précis, environ deux fois plus gros et plus lent).
enum SuiviQuant: String, CaseIterable, Identifiable {
    case q4 = "4 bits", q8 = "8 bits"
    var id: String { rawValue }
    /// Go de mémoire par milliard de paramètres (Q4_K_M ≈ 0,61 ; Q8_0 ≈ 1,06).
    var gigaParMilliard: Double { self == .q4 ? 0.61 : 1.06 }
}

/// Un modèle d'IA visé. Un modèle « mixture d'experts » (MoE) occupe toute sa taille en mémoire mais ne lit, pour chaque mot produit,
/// que ses paramètres actifs : il est bien plus rapide qu'un modèle classique de même taille.
struct SuiviModeleIA: Identifiable, Hashable {
    var nom: String
    var milliardsTotal: Double
    var milliardsActifs: Double
    var id: String { nom }
    var moe: Bool { milliardsActifs < milliardsTotal }

    /// Place prise en mémoire.
    func tailleGo(_ q: SuiviQuant) -> Double { milliardsTotal * q.gigaParMilliard }
    /// Quantité lue à chaque mot produit (c'est elle qui fixe la vitesse).
    func lectureGo(_ q: SuiviQuant) -> Double { milliardsActifs * q.gigaParMilliard }

    static let tous = [
        SuiviModeleIA(nom: "8B", milliardsTotal: 8, milliardsActifs: 8),
        SuiviModeleIA(nom: "14B", milliardsTotal: 14, milliardsActifs: 14),
        SuiviModeleIA(nom: "32B", milliardsTotal: 32, milliardsActifs: 32),
        SuiviModeleIA(nom: "70B", milliardsTotal: 70, milliardsActifs: 70),
        SuiviModeleIA(nom: "30B-A3B (MoE)", milliardsTotal: 30, milliardsActifs: 3),
        SuiviModeleIA(nom: "120B-A5B (MoE)", milliardsTotal: 120, milliardsActifs: 5),
    ]
    static let parDefaut = tous[2]
}

enum SuiviTient { case oui, juste, non }

enum SuiviVitesse {
    /// Mesures publiques llama.cpp (discussion n° 4167 : Llama 7B quantifié Q4_0, génération « tg128 »), en tokens/s.
    /// Clé : puce|cœurs GPU. Sources secondaires : à prendre comme des ordres de grandeur.
    static let mesures: [String: Double] = ["M2 Max|38": 65.95, "M3 Max|40": 66.31, "M4 Max|32": 69.95, "M4 Max|40": 83.06]
    /// Taille du modèle de référence de ces mesures (Llama 7B Q4_0).
    static let tailleReference = 3.83
    /// Un modèle MoE perd un peu de vitesse (choix des experts à chaque mot) : facteur appliqué à la vitesse.
    static let facteurMoE = 0.8

    /// Part de la bande passante réellement utilisée, déduite de ces mesures (≈ 0,63 jusqu'à 410 Go/s, ≈ 0,58 vers 546 Go/s).
    static func rendement(bande: Int) -> Double { bande >= 500 ? 0.58 : 0.63 }

    /// `mesure` vrai : la valeur vient d'une mesure publique de cette puce, ramenée à ce qui est lu par mot ; sinon c'est une estimation.
    static func tokensParSeconde(puce: String, gpu: Int?, bande: Int, modele: SuiviModeleIA, quant: SuiviQuant = .q4) -> (valeur: Double, mesure: Bool) {
        let lecture = modele.lectureGo(quant), f = modele.moe ? facteurMoE : 1
        if let g = gpu, let m = mesures["\(puce)|\(g)"] { return (m * tailleReference / lecture * f, true) }
        return (rendement(bande: bande) * Double(bande) / lecture * f, false)
    }

    /// Le modèle tient-il dans la mémoire ? macOS laisse environ 75 % de la mémoire au GPU ; il faut aussi la place du contexte (≈ 3 Go).
    static func tient(ram: Int, modele: SuiviModeleIA, quant: SuiviQuant = .q4) -> SuiviTient {
        let besoin = modele.tailleGo(quant) * 1.03 + 3
        let dispo = Double(ram) * 0.75
        if besoin > dispo { return .non }
        return besoin > dispo * 0.9 ? .juste : .oui
    }
}

extension SuiviModeles {
    /// Ancienne estimation simple (modèle de 20 Go), gardée pour les tests et les alertes.
    static func tokensParSeconde(bande: Int) -> Double { SuiviVitesse.rendement(bande: bande) * Double(bande) / 20 }
}
#endif
