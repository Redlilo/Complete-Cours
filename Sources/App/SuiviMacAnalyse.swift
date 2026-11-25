#if COMPTE_PERSO
import Foundation

// « Suivi MacBook IA » : calculs purs (bande passante, score, tranches de prix, statistiques).
// Aucun accès réseau ni disque ici : tout est testable avec des offres fabriquées.

enum SuiviReference {
    /// Bande passante mémoire (Go/s) d'après les fiches techniques Apple.
    static func bandePassante(puce: String, gpu: Int?) -> Int? {
        switch (puce, gpu) {
        case ("M2 Max", 30?), ("M2 Max", 38?): return 400
        case ("M2 Ultra", _): return 800
        case ("M3 Ultra", _): return 819
        case ("M3 Max", 30?): return 300
        case ("M3 Max", 40?): return 400
        case ("M4 Max", 32?): return 410
        case ("M4 Max", 40?): return 546
        case ("M5 Max", 32?): return 460
        case ("M5 Max", 40?): return 614
        default: return nil
        }
    }

    /// Quand le vendeur n'indique pas le GPU : déduit de la puce et de la mémoire (même combinaisons qu'Apple).
    static func gpuProbable(puce: String, ram: Int) -> Int? {
        switch (puce, ram) {
        case ("M2 Max", 64): return 38
        case ("M3 Max", 36): return 30
        case ("M3 Max", 48), ("M3 Max", 64), ("M3 Max", 128): return 40
        case ("M4 Max", 36): return 32
        case ("M4 Max", 48), ("M4 Max", 64), ("M4 Max", 128): return 40
        case ("M5 Max", 36): return 32
        case ("M5 Max", 48), ("M5 Max", 64), ("M5 Max", 128): return 40
        default: return nil
        }
    }

    static let claviersParPays: [String: String] = [
        "FR": "AZERTY", "BE": "AZERTY", "DE": "QWERTZ", "AT": "QWERTZ", "CH": "QWERTZ",
        "IT": "QWERTY (italien)", "ES": "QWERTY (espagnol)", "NL": "QWERTY", "IE": "QWERTY (irlandais)",
    ]
}

struct SuiviEvaluation: Identifiable {
    var offre: SuiviOffre
    var bande: Int?
    var score: Double?      // prix ÷ bande passante (€ par Go/s) : plus bas = plus rentable
    var id: String { offre.key }
}

enum SuiviCalcul {
    static func evaluer(_ o: SuiviOffre) -> SuiviEvaluation {
        let bande = SuiviReference.bandePassante(puce: o.puce, gpu: o.gpu)
        return SuiviEvaluation(offre: o, bande: bande, score: bande.map { o.prix / Double($0) })
    }

    /// Classe : score croissant ; les offres sans score à la fin.
    static func classer(_ liste: [SuiviEvaluation]) -> [SuiviEvaluation] {
        liste.sorted { a, b in
            switch (a.score, b.score) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offre.prix < b.offre.prix
            }
        }
    }

    /// Un prix exploitable : fini, strictement positif et plausible (un « 0 € » ou un -5 lu par erreur serait « la meilleure offre »).
    static func prixValide(_ p: Double) -> Bool { p.isFinite && p > 0 && p < 1_000_000 }

    static func filtrer(_ liste: [SuiviEvaluation], _ f: SuiviFiltres) -> [SuiviEvaluation] {
        liste.filter { e in
            if !prixValide(e.offre.prix) { return false }
            if f.livrablesSeulement && e.offre.livraison == .non { return false }
            if f.azertySeulement && e.offre.clavier != "AZERTY" { return false }
            if f.memoire != 0 && e.offre.ram != f.memoire { return false }
            return true
        }
    }

    // MARK: Meilleure offre par budget

    /// Paliers de budget suivis (€).
    static let paliers: [Double] = [2500, 3000, 3500, 4000, 4500]

    /// `minimum` : exclut ce qui coûte ce montant ou moins (tranche entre deux paliers) ; 0 = tout jusqu'au budget.
    /// Les plus hautes performances pour l'IA sous le budget : le plus de bande passante ; à égalité, le moins cher.
    static func meilleurSousBudget(_ liste: [SuiviEvaluation], budget: Double, ram: Int?, minimum: Double = 0) -> SuiviEvaluation? {
        var meilleure: SuiviEvaluation?
        for e in liste {
            guard let bande = e.bande, e.offre.prix <= budget, e.offre.prix > minimum,
                  ram == nil || e.offre.ram == ram else { continue }
            if let m = meilleure, let mb = m.bande {
                if bande > mb || (bande == mb && e.offre.prix < m.offre.prix) { meilleure = e }
            } else {
                meilleure = e
            }
        }
        return meilleure
    }

    /// Dans la même tranche : l'offre au meilleur rapport (prix par Go/s le plus bas).
    static func meilleurRapportSousBudget(_ liste: [SuiviEvaluation], budget: Double, ram: Int?, minimum: Double = 0) -> SuiviEvaluation? {
        liste.filter { e in
            e.score != nil && e.offre.prix <= budget && e.offre.prix > minimum && (ram == nil || e.offre.ram == ram)
        }.min { ($0.score ?? .infinity) < ($1.score ?? .infinity) }
    }

    /// Bornes de la tranche n : (palier précédent, palier] ; la première va de 0 au premier palier.
    static func bornes(_ index: Int, parTranche: Bool) -> (minimum: Double, maximum: Double) {
        (parTranche && index > 0 ? paliers[index - 1] : 0, paliers[index])
    }

    // MARK: Regroupement (coloris identiques au même prix)

    static func cle(_ o: SuiviOffre) -> String {
        [o.source, o.pays, o.etat.rawValue, o.puce, String(o.ecran), String(o.ram), o.ssd, o.affichage, o.clavier]
            .joined(separator: "|")
    }

    /// Une ligne par modèle et par vendeur : la moins chère, avec les coloris vendus à ce prix.
    static func regrouper(_ offres: [SuiviOffre]) -> [SuiviOffre] {
        var par: [String: SuiviOffre] = [:]
        var couleurs: [String: [String]] = [:]
        for o in offres where prixValide(o.prix) {
            let k = cle(o)
            if let c = par[k] {
                if o.prix < c.prix { par[k] = o; couleurs[k] = [o.couleur].filter { !$0.isEmpty } }
                else if o.prix == c.prix, !o.couleur.isEmpty, !(couleurs[k] ?? []).contains(o.couleur) { couleurs[k, default: []].append(o.couleur) }
            } else {
                par[k] = o
                couleurs[k] = [o.couleur].filter { !$0.isEmpty }
            }
        }
        return par.map { k, o in
            var o = o
            o.key = k
            o.couleur = (couleurs[k] ?? []).joined(separator: " / ")
            return o
        }
    }

    static func nomCourt(_ o: SuiviOffre) -> String {
        var s = "\(o.puce) \(o.ecran == 0 ? "?" : "\(o.ecran)\"") \(o.ram) Go/\(o.ssd)"
        if o.affichage != "standard" { s += " \(o.affichage)" }
        if !o.couleur.isEmpty { s += " \(o.couleur)" }
        return s
    }

    // MARK: Séries et statistiques

    struct Point: Identifiable { var date: Date; var valeur: Double; var id: Date { date } }
    struct Serie: Identifiable { var id: String; var nom: String; var points: [Point] }

    /// Évolution du prix de chaque offre (regroupée) au fil des relevés.
    static func series(_ releves: [SuiviReleve]) -> [Serie] {
        var noms: [String: String] = [:]
        var pts: [String: [Point]] = [:]
        for r in releves {
            for o in regrouper(r.offres) {
                noms[o.key] = "\(nomCourt(o)) — \(o.source)"
                pts[o.key, default: []].append(Point(date: r.date, valeur: o.prix))
            }
        }
        return pts.map { Serie(id: $0.key, nom: noms[$0.key] ?? $0.key, points: $0.value) }
            .sorted { $0.nom < $1.nom }
    }

    /// Meilleur score (prix par Go/s) à chaque relevé, avec les filtres en cours.
    static func meilleurScoreParReleve(_ releves: [SuiviReleve], _ manuelles: [SuiviOffre], _ f: SuiviFiltres) -> [Point] {
        releves.compactMap { r in
            let offres = regrouper(r.offres) + manuelles.filter { ($0.ajoutee ?? .distantPast) <= r.date }
            let evals = filtrer(offres.map { evaluer($0) }, f).compactMap { $0.score }
            guard let m = evals.min() else { return nil }
            return Point(date: r.date, valeur: m)
        }
    }

    struct Stats {
        var releves = 0
        var premier: Date?
        var dernier: Date?
        var moinsCherAujourdhui: Double?
        var variationTotale: Double?
        var plusBas: Double?
        var plusHaut: Double?
        var moyenne: Double?
        var baisses = 0
        var hausses = 0
        var nouvelles = 0
        var disparues = 0
        var aPrecedent = false
    }

    static func stats(_ releves: [SuiviReleve], _ f: SuiviFiltres) -> Stats {
        var s = Stats()
        s.releves = releves.count
        s.premier = releves.first?.date
        s.dernier = releves.last?.date
        func moins(_ r: SuiviReleve) -> Double? {
            r.offres.filter { !(f.livrablesSeulement && $0.livraison == .non) && !(f.azertySeulement && $0.clavier != "AZERTY")
                && (f.memoire == 0 || $0.ram == f.memoire) }
                .map(\.prix).min()
        }
        let mins = releves.compactMap(moins)
        s.moinsCherAujourdhui = releves.last.flatMap(moins)
        if mins.count > 1 {
            s.variationTotale = mins.last! - mins.first!
            s.plusBas = mins.min(); s.plusHaut = mins.max()
            s.moyenne = mins.reduce(0, +) / Double(mins.count)
        }
        if releves.count > 1, let dernier = releves.last {
            let avant = Dictionary(uniqueKeysWithValues: regrouper(releves[releves.count - 2].offres).map { ($0.key, $0.prix) })
            let apres = Dictionary(uniqueKeysWithValues: regrouper(dernier.offres).map { ($0.key, $0.prix) })
            for (k, p) in apres {
                if let q = avant[k] { if p < q { s.baisses += 1 } else if p > q { s.hausses += 1 } } else { s.nouvelles += 1 }
            }
            s.disparues = avant.keys.filter { apres[$0] == nil }.count
            s.aPrecedent = true
        }
        return s
    }

    /// Prix de l'offre au relevé précédent (pour la colonne « variation »).
    static func prixPrecedent(_ cle: String, _ releves: [SuiviReleve]) -> Double? {
        guard releves.count > 1 else { return nil }
        for r in releves.dropLast().reversed() {
            if let o = regrouper(r.offres).first(where: { $0.key == cle }) { return o.prix }
        }
        return nil
    }
}
#endif
