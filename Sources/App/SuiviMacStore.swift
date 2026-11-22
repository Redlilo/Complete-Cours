#if COMPTE_PERSO
import Foundation
import SwiftUI
import AppKit

// « Suivi MacBook IA » : historique sur disque, relevé à la demande, réglages et analyse par l'IA des Réglages.

/// Historique dans Application Support/<identifiant de l'app>/SuiviMac/historique.json (même dossier que le journal de l'app).
enum SuiviMacDisque {
    private static let verrou = NSLock()

    static var fichier: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "fr.complete-cours.app", isDirectory: true)
            .appendingPathComponent("SuiviMac", isDirectory: true)
            .appendingPathComponent("historique.json")
    }

    private static func lireSansVerrou() -> SuiviHistorique {
        guard let d = try? Data(contentsOf: fichier) else { return SuiviHistorique() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if var h = try? dec.decode(SuiviHistorique.self, from: d) {
            let allege = SuiviModeles.alleger(h.releves)
            if allege.count != h.releves.count {
                let copie = fichier.deletingLastPathComponent().appendingPathComponent("historique-avant-allegement.json")
                if !FileManager.default.fileExists(atPath: copie.path) { try? FileManager.default.copyItem(at: fichier, to: copie) }
                h.releves = allege
                ecrireSansVerrou(h)
            }
            return h
        }
        // Fichier illisible : on le met de côté au lieu de l'écraser.
        let copie = fichier.deletingLastPathComponent().appendingPathComponent("historique-illisible-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: fichier, to: copie)
        return SuiviHistorique()
    }

    private static func ecrireSansVerrou(_ h: SuiviHistorique) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        guard let d = try? enc.encode(h) else { return }
        try? FileManager.default.createDirectory(at: fichier.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: fichier, options: .atomic)
    }

    static func charger() -> SuiviHistorique { verrou.lock(); defer { verrou.unlock() }; return lireSansVerrou() }

    /// Relit le fichier, modifie, réécrit : sûr même si l'app et le relevé automatique tournent en même temps.
    @discardableResult
    static func modifier(_ f: (inout SuiviHistorique) -> Void) -> SuiviHistorique {
        verrou.lock(); defer { verrou.unlock() }
        var h = lireSansVerrou()
        f(&h)
        ecrireSansVerrou(h)
        return h
    }
}

/// Relevé sans fenêtre (tâche quotidienne) : `App Perso --suivi-releve`.
/// WebKit a besoin d'une boucle d'application : on en démarre une, invisible (pas d'icône dans le Dock).
enum SuiviMacCLI {
    @MainActor
    static func runAndExit() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let r = await SuiviReleveur.releverTout()
            let date = ISO8601DateFormatter().string(from: r.date)
            if r.offres.isEmpty && !r.erreurs.isEmpty {
                print("\(date) aucun relevé enregistré, erreurs : \(r.erreurs)")
                exit(1)
            }
            let h = SuiviMacDisque.modifier { $0.releves = SuiviModeles.ajouter(r, a: $0.releves) }
            SuiviAlertesMac.envoyerSiBesoin(h)
            print("\(date) relevé \(h.releves.count) enregistré : \(r.offres.count) offre(s), lues \(r.comptes), erreurs \(r.erreurs.isEmpty ? "aucune" : "\(r.erreurs)")")
            exit(0)
        }
        app.run()
        exit(0)
    }
}

/// Notifications du Mac après un relevé (aussi celui de 9 h, sans fenêtre) : via `osascript`, qui marche sans l'app ouverte.
enum SuiviAlertesMac {
    static let cleActives = "suiviMac.alertes"
    static let cleSeuil = "suiviMac.seuilBaisse"

    static func envoyerSiBesoin(_ h: SuiviHistorique) {
        let d = UserDefaults.standard
        guard d.object(forKey: cleActives) as? Bool ?? true else { return }
        let f = d.data(forKey: "suiviMac.favoris").flatMap { try? JSONDecoder().decode([SuiviModele].self, from: $0) }
        let filtres = d.data(forKey: "suiviMac.filtres").flatMap { try? JSONDecoder().decode(SuiviFiltres.self, from: $0) } ?? SuiviFiltres()
        let a = SuiviModeles.alertes(releves: h.releves, manuelles: h.manuelles, favoris: (f?.count == 3) ? f! : SuiviModele.parDefaut,
                                     filtres: filtres, seuilBaisse: d.object(forKey: cleSeuil) as? Double ?? 5)
        guard let premiere = a.first else { return }
        let reste = a.count > 1 ? " (+ \(a.count - 1) autre(s) dans l'app)" : ""
        notifier(titre: premiere.titre, texte: premiere.texte + reste)
    }

    static func notifier(titre: String, texte: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "'") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(texte))\" with title \"Suivi MacBook IA\" subtitle \"\(esc(titre))\""]
        try? p.run()
    }
}

@MainActor
final class SuiviMacStore: ObservableObject {
    static let shared = SuiviMacStore()

    @Published private(set) var historique: SuiviHistorique
    @Published var enCours = false
    @Published var statut = ""
    @Published var erreurs: [String: String] = [:]
    @Published var filtres: SuiviFiltres { didSet { sauverReglages() } }
    @Published var releveAuLancement: Bool { didSet { UserDefaults.standard.set(releveAuLancement, forKey: Self.cleAuto) } }
    @Published var favoris: [SuiviModele] { didSet { UserDefaults.standard.set(try? JSONEncoder().encode(favoris), forKey: Self.cleFavoris) } }
    @Published var alertesActives: Bool { didSet { UserDefaults.standard.set(alertesActives, forKey: SuiviAlertesMac.cleActives) } }
    @Published var seuilBaisse: Double { didSet { UserDefaults.standard.set(seuilBaisse, forKey: SuiviAlertesMac.cleSeuil) } }
    @Published var analyse: String?
    @Published var analyseEnCours = false
    @Published var erreurAnalyse: String?

    private static let cleFiltres = "suiviMac.filtres"
    private static let cleAuto = "suiviMac.releveAuLancement"
    private static let cleFavoris = "suiviMac.favoris"
    private var dejaVerifieAuLancement = false

    private init() {
        historique = SuiviMacDisque.charger()
        let d = UserDefaults.standard
        filtres = (d.data(forKey: Self.cleFiltres).flatMap { try? JSONDecoder().decode(SuiviFiltres.self, from: $0) }) ?? SuiviFiltres()
        releveAuLancement = d.object(forKey: Self.cleAuto) as? Bool ?? true
        let f = d.data(forKey: Self.cleFavoris).flatMap { try? JSONDecoder().decode([SuiviModele].self, from: $0) }
        favoris = (f?.count == 3) ? f! : SuiviModele.parDefaut
        alertesActives = d.object(forKey: SuiviAlertesMac.cleActives) as? Bool ?? true
        seuilBaisse = d.object(forKey: SuiviAlertesMac.cleSeuil) as? Double ?? 5
    }

    private func sauverReglages() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(filtres), forKey: Self.cleFiltres)
    }

    // MARK: Lecture

    var dernierReleve: SuiviReleve? { historique.releves.last }

    /// Offres actuelles (dernier relevé regroupé + offres saisies à la main), évaluées, avant filtres.
    var toutesLesEvaluations: [SuiviEvaluation] {
        let offres = SuiviCalcul.regrouper(dernierReleve?.offres ?? []) + historique.manuelles
        return SuiviCalcul.classer(offres.map { SuiviCalcul.evaluer($0) })
    }

    var classement: [SuiviEvaluation] { SuiviCalcul.filtrer(toutesLesEvaluations, filtres) }
    /// Meilleure offre sous un budget (pour une mémoire donnée ou toutes), avec les filtres en cours.
    /// Les plus hautes performances de la tranche n (selon le réglage « tranche » ou « jusqu'au budget »).
    func meilleur(tranche n: Int, ram: Int?) -> SuiviEvaluation? {
        let b = SuiviCalcul.bornes(n, parTranche: filtres.parTranche)
        return SuiviCalcul.meilleurSousBudget(classement, budget: b.maximum, ram: ram, minimum: b.minimum)
    }
    /// Le meilleur rapport (€ par Go/s) de la même tranche.
    func meilleurRapport(tranche n: Int, ram: Int?) -> SuiviEvaluation? {
        let b = SuiviCalcul.bornes(n, parTranche: filtres.parTranche)
        return SuiviCalcul.meilleurRapportSousBudget(classement, budget: b.maximum, ram: ram, minimum: b.minimum)
    }
    var changements: SuiviChangements { SuiviModeles.changements(historique.releves) }
    var suivisModeles: [SuiviSuiviModele] {
        favoris.map { SuiviModeles.suivi($0, releves: historique.releves, manuelles: historique.manuelles, filtres: filtres) }
    }
    /// Bonnes affaires : écart avec le prix du marché (médiane du même modèle dans le même état), filtres appliqués.
    var affaires: [SuiviAffaire] {
        SuiviModeles.affaires(classement, marche: (dernierReleve?.offres ?? []) + historique.manuelles)
    }
    var champion: SuiviEvaluation? { classement.first { $0.score != nil } }
    var statistiques: SuiviCalcul.Stats { SuiviCalcul.stats(historique.releves, filtres) }
    var series: [SuiviCalcul.Serie] { SuiviCalcul.series(historique.releves) }
    var scoreAuFilDuTemps: [SuiviCalcul.Point] {
        SuiviCalcul.meilleurScoreParReleve(historique.releves, historique.manuelles, filtres)
    }

    // MARK: Relevé

    func relever() async {
        guard !enCours else { return }
        enCours = true
        statut = "Relevé en cours : \(SuiviSource.toutes.count) sources, environ 3 minutes…"
        let r = await SuiviReleveur.releverTout()
        erreurs = r.erreurs
        if r.offres.isEmpty && !r.erreurs.isEmpty {
            statut = "Aucun site n'a répondu : relevé non enregistré. Vérifie ta connexion."
        } else {
            historique = SuiviMacDisque.modifier { $0.releves = SuiviModeles.ajouter(r, a: $0.releves) }
            if alertesActives { SuiviAlertesMac.envoyerSiBesoin(historique) }
            let lus = r.comptes.values.reduce(0, +)
            statut = "Relevé enregistré : \(lus) offre(s) lues sur \(r.comptes.count) site(s)."
        }
        enCours = false
    }

    /// Au premier affichage de la journée : un relevé automatique si le dernier a plus de 20 heures.
    func releverSiNecessaire() {
        guard !dejaVerifieAuLancement else { return }
        dejaVerifieAuLancement = true
        historique = SuiviMacDisque.charger()   // la tâche quotidienne a pu ajouter un relevé
        guard releveAuLancement else { return }
        if let d = dernierReleve?.date, Date().timeIntervalSince(d) < 20 * 3600 { return }
        Task { await relever() }
    }

    func recharger() { historique = SuiviMacDisque.charger() }

    // MARK: Offres saisies à la main

    func ajouterManuelle(vendeur: String, pays: String, puce: String, ecran: Int, ram: Int, gpu: Int, ssd: String,
                         clavier: String, prix: Double, url: String) {
        let o = SuiviOffre(key: "manuel|\(UUID().uuidString)", source: vendeur.isEmpty ? "Manuel" : vendeur, pays: pays,
                           etat: .reconditionneTiers, titre: "\(puce) \(ecran)\" \(ram) Go/\(ssd)", puce: puce, ecran: ecran,
                           gpu: gpu, ram: ram, ssd: ssd, affichage: "standard", couleur: "", clavier: clavier, prix: prix,
                           prixOriginal: nil, stock: "", url: url, livraison: pays == "FR" ? .oui : .aVerifier,
                           remarque: "Offre saisie à la main.", manuelle: true, ajoutee: Date())
        historique = SuiviMacDisque.modifier { $0.manuelles.append(o) }
    }

    func supprimerManuelle(_ cle: String) {
        historique = SuiviMacDisque.modifier { $0.manuelles.removeAll { $0.key == cle } }
    }

    // MARK: Analyse par l'IA des Réglages (facultative)

    func analyser() async {
        guard !analyseEnCours else { return }
        analyseEnCours = true; analyse = nil; erreurAnalyse = nil
        defer { analyseEnCours = false }
        do {
            let moteur = try EngineFactory.make(RunSettings.current())
            guard let g = moteur as? StructuredGenerator else {
                erreurAnalyse = "Ce moteur d'IA ne sait pas écrire d'analyse : choisis-en un autre dans les Réglages."
                return
            }
            let schema: [String: Any] = ["type": "object",
                                          "properties": ["analyse": ["type": "string"]],
                                          "required": ["analyse"], "additionalProperties": false]
            let brut = try await g.generate(system: Self.consigne, userText: resume(), images: [], schema: schema)
            if let d = brut.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let t = j["analyse"] as? String { analyse = t } else { analyse = brut }
        } catch {
            erreurAnalyse = error.localizedDescription
        }
    }

    private static let consigne = """
    Tu aides un lycéen à choisir un MacBook Pro à puce Max (36 ou 48 Go), le plus souvent reconditionné, pour faire tourner \
    des modèles d'IA en local. Réponds en français, en 8 à 12 lignes : 1) POUR CHAQUE TRANCHE DE PRIX (2 500, 3 000, 3 500, \
    4 000, 4 500 €) l'offre aux meilleures performances IA (bande passante), en 36 Go et en 48 Go, et si une offre d'une autre \
    tranche vaut mieux le coup (prix par Go/s), puis l'état de MES 3 MODÈLES (prix actuel vs médiane du marché) et les meilleures \
    affaires par rapport au prix du marché ; 2) ce que dit l'évolution des prix (acheter maintenant ou attendre), en disant \
    clairement si les relevés sont trop peu nombreux pour conclure ; 3) les risques (état esthétique d'un reconditionné, achat \
    hors de France, livraison, clavier, garantie du vendeur). N'invente aucun chiffre absent des données.
    """

    private func resume() -> String {
        let f = ISO8601DateFormatter()
        let top = classement.filter { $0.score != nil }.prefix(8).map { e -> [String: Any] in
            ["machine": SuiviCalcul.nomCourt(e.offre), "vendeur": e.offre.source, "pays": e.offre.pays,
             "etat": e.offre.etat.libelle, "grade": e.offre.grade ?? "", "clavier": e.offre.clavier,
             "livraison_france": e.offre.livraison.libelle, "prix": Int(e.offre.prix), "go_par_s": e.bande ?? 0,
             "euro_par_go_s": ((e.score ?? 0) * 100).rounded() / 100]
        }
        let evol = series.map { s -> [String: Any] in
            ["offre": s.nom, "releves": s.points.count, "premier": Int(s.points.first?.valeur ?? 0),
             "dernier": Int(s.points.last?.valeur ?? 0), "min": Int(s.points.map(\.valeur).min() ?? 0),
             "max": Int(s.points.map(\.valeur).max() ?? 0)]
        }
        let tranches = SuiviCalcul.paliers.indices.map { n -> [String: Any] in
            let b = SuiviCalcul.bornes(n, parTranche: filtres.parTranche)
            var ligne: [String: Any] = ["tranche": filtres.parTranche ? "\(Int(b.minimum)) à \(Int(b.maximum)) €" : "jusqu'à \(Int(b.maximum)) €"]
            for ram in [36, 48] {
                if let e = meilleur(tranche: n, ram: ram) {
                    ligne["\(ram)_go"] = ["machine": SuiviCalcul.nomCourt(e.offre), "vendeur": e.offre.source, "go_par_s": e.bande ?? 0,
                                          "prix": Int(e.offre.prix)]
                } else { ligne["\(ram)_go"] = "aucune offre" }
            }
            return ligne
        }
        let modeles = suivisModeles.map { m -> [String: Any] in
            ["modele": m.modele.nom, "meilleur_prix": Int(m.meilleur?.offre.prix ?? 0), "vendeur": m.meilleur?.offre.source ?? "aucun",
             "mediane_marche": Int(m.mediane ?? 0), "plus_bas_observe": Int(m.plusBasObserve ?? 0), "offres": m.offres.count]
        }
        let affaires = self.affaires.filter { !$0.suspect }.prefix(6).map { a -> [String: Any] in
            ["machine": SuiviCalcul.nomCourt(a.offre), "vendeur": a.offre.source, "prix": Int(a.offre.prix),
             "marche": Int(a.reference), "sous_le_marche_pct": Int(a.ecart.rounded())]
        }
        let obj: [String: Any] = ["date": f.string(from: Date()), "nombre_de_releves": historique.releves.count,
                                  "meilleure_performance_par_tranche": tranches, "classement": top, "evolution": evol,
                                  "mes_3_modeles": modeles, "meilleures_affaires_vs_marche": affaires]
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }
}
#endif
