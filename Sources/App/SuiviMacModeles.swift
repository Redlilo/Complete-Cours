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
            l.append([c(SuiviCalcul.nomCourt(o)), c(o.source), o.pays, c(o.etat.libelle), String(Int(o.prix)), e.bande.map(String.init) ?? "",
                      e.score.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") } ?? "",
                      c(o.livraison.libelle), c(o.clavier), c(o.url)].joined(separator: ";"))
        }
        return l.joined(separator: "\n")
    }
}
#endif
