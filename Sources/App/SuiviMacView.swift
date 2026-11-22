#if COMPTE_PERSO
import SwiftUI
import AppKit
import Charts

// « Suivi MacBook IA » (variante personnelle) : relevé des prix à la demande, classement pour l'IA locale,
// statistiques et graphiques, offres saisies à la main, analyse par l'IA des Réglages.

private func eur(_ v: Double?) -> String {
    guard let v else { return "—" }
    return v.formatted(.currency(code: "EUR").precision(.fractionLength(0)).locale(Locale(identifier: "fr_FR")))
}
private func eur2(_ v: Double?) -> String {
    guard let v else { return "—" }
    return v.formatted(.currency(code: "EUR").precision(.fractionLength(2)).locale(Locale(identifier: "fr_FR")))
}
private func jour(_ d: Date?) -> String {
    guard let d else { return "—" }
    return d.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "fr_FR")))
}
private func heure(_ d: Date) -> String {
    d.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "fr_FR")))
}

struct SuiviMacView: View {
    @ObservedObject private var store = SuiviMacStore.shared
    enum Vue: String, CaseIterable, Identifiable {
        case ensemble = "Vue d'ensemble", modeles = "Mes 3 modèles", affaires = "Bonnes affaires"
        var id: String { rawValue }
    }
    @State private var vue = Vue.ensemble
    @State private var serieChoisie = "__toutes"
    @State private var ajoutOuvert = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Suivi MacBook IA",
                         subtitle: "MacBook Pro puce Max, 36 et 48 Go — prix, évolution et meilleure offre pour l'IA locale") {
                if store.enCours { ProgressView().controlSize(.small) }
                Button { Task { await store.relever() } } label: {
                    Label("Vérifier les prix maintenant", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.enCours)
                .accessibilityHint("Lit les prix chez les vendeurs et enregistre un relevé")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    barreStatut
                    Picker("Vue", selection: $vue) { ForEach(Vue.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
                    switch vue {
                    case .ensemble:
                        tranches
                        filtres
                        grilleStats
                        classement
                        evolution
                        offresManuelles
                        sectionIA
                    case .modeles:
                        filtres
                        sectionModeles
                    case .affaires:
                        filtres
                        sectionAffaires
                    }
                }
                .padding(20)
                .frame(maxWidth: 1300, alignment: .leading)
            }
        }
        .navigationTitle("Suivi MacBook IA")
        .onAppear { store.releverSiNecessaire() }
        .sheet(isPresented: $ajoutOuvert) { SuiviAjoutSheet(store: store) }
    }

    // MARK: Statut

    private var barreStatut: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let d = store.dernierReleve?.date {
                Text("Dernier relevé : \(heure(d)) — \(store.historique.releves.count) relevé(s) enregistré(s)")
            } else {
                Text("Aucun relevé pour l'instant : clique sur « Vérifier les prix maintenant ».")
            }
            if !store.statut.isEmpty { Text(store.statut).foregroundStyle(.secondary) }
            if let d = store.dernierReleve?.date, Date().timeIntervalSince(d) > 30 * 3600, !store.enCours {
                Text("Aucun relevé depuis \(Int(Date().timeIntervalSince(d) / 3600)) h : celui de 9 h n'a pas eu lieu (Mac éteint ou en veille ?). Clique « Vérifier les prix maintenant ».")
                    .foregroundStyle(.red)
            }
            let erreurs = store.erreurs.isEmpty ? (store.dernierReleve?.erreurs ?? [:]) : store.erreurs
            if !erreurs.isEmpty {
                Text("Sites qui n'ont pas répondu : " + erreurs.sorted { $0.key < $1.key }
                    .map { "\($0.key) (\($0.value))" }.joined(separator: " ; "))
                    .foregroundStyle(.orange)
            }
            let vides = (store.dernierReleve?.comptes ?? [:]).filter { $0.value == 0 }.keys.sorted()
            if !vides.isEmpty {
                Text("Sites lus mais sans aucune offre (page changée ?) : " + vides.joined(separator: ", ")).foregroundStyle(.orange)
            }
            Toggle("Faire un relevé automatiquement à l'ouverture (une fois par jour)", isOn: $store.releveAuLancement)
                .toggleStyle(.checkbox).font(.callout)
            HStack(spacing: 14) {
                Toggle("Me prévenir par notification (prix en baisse sur mes modèles, nouvelle meilleure offre, bonne affaire)", isOn: $store.alertesActives)
                    .toggleStyle(.checkbox)
                if store.alertesActives {
                    Stepper("Baisse d'au moins \(Int(store.seuilBaisse)) %", value: $store.seuilBaisse, in: 2...30, step: 1).fixedSize()
                }
            }
            .font(.callout)
        }
        .font(.callout)
    }

    private func couleurLivraison(_ l: SuiviLivraison) -> Color {
        switch l { case .oui: return .green; case .non: return .red; case .aVerifier: return .orange }
    }

    // MARK: Filtres

    private var filtres: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Filtres").font(.headline)
            HStack(spacing: 18) {
                Toggle("Livrables en France seulement", isOn: $store.filtres.livrablesSeulement)
                Toggle("Clavier AZERTY seulement", isOn: $store.filtres.azertySeulement)
                HStack(spacing: 6) {
                    Text("Mémoire").fixedSize()
                    Picker("Mémoire", selection: $store.filtres.memoire) {
                        Text("Toutes").tag(0); Text("36 Go").tag(36); Text("48 Go").tag(48); Text("64 Go").tag(64)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 260)
                }
            }
            .toggleStyle(.checkbox)
            let masquees = store.toutesLesEvaluations.count - store.classement.count
            if masquees > 0 {
                Text("\(masquees) offre(s) masquée(s) par ces filtres.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Meilleure offre par tranche de prix (le but n° 1 de l'écran)

    private var tranches: some View {
        let colonnes = store.filtres.memoire == 0 ? [36, 48] : [store.filtres.memoire]
        return VStack(alignment: .leading, spacing: 12) {
            Text("Meilleure offre par tranche de prix").font(.title2.weight(.bold))
            Text("Pour chaque tranche : les plus hautes performances pour l'IA (bande passante), et le meilleur rapport qualité/prix de la tranche s'il est différent.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Picker("Tranches", selection: $store.filtres.parTranche) {
                    Text("Entre deux paliers").tag(true)
                    Text("Tout jusqu'au palier").tag(false)
                }
                .pickerStyle(.segmented).frame(width: 320)
            }
            ForEach(SuiviCalcul.paliers.indices, id: \.self) { n in
                let b = SuiviCalcul.bornes(n, parTranche: store.filtres.parTranche)
                VStack(alignment: .leading, spacing: 8) {
                    Text(titreTranche(b.minimum, b.maximum)).font(.headline).monospacedDigit()
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(colonnes, id: \.self) { ram in
                            carteTranche(ram: ram, haute: store.meilleur(tranche: n, ram: ram), rapport: store.meilleurRapport(tranche: n, ram: ram))
                        }
                    }
                }
                .card(padding: 14)
            }
            Text("Prix du Mac seul, tel qu'affiché par le vendeur. Une tranche peut être vide : aucune offre relevée à ce prix. Filtres ci-dessous.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func titreTranche(_ minimum: Double, _ maximum: Double) -> String {
        minimum == 0 ? "Jusqu'à \(eur(maximum))" : "De \(eur(minimum)) à \(eur(maximum))"
    }

    private func carteTranche(ram: Int, haute: SuiviEvaluation?, rapport: SuiviEvaluation?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(ram) Go").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let h = haute {
                ligneOffre(h, etiquette: "Meilleures performances", couleur: .green)
                if let r = rapport, r.id != h.id { ligneOffre(r, etiquette: "Meilleur rapport qualité/prix", couleur: .blue) }
            } else {
                Text("aucune offre dans cette tranche").foregroundStyle(.secondary).font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ligneOffre(_ e: SuiviEvaluation, etiquette: String, couleur: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(etiquette).font(.caption.weight(.semibold)).foregroundStyle(couleur)
            HStack(spacing: 6) {
                if let u = URL(string: e.offre.url), !e.offre.url.isEmpty {
                    LienArrierePlan(titre: SuiviCalcul.nomCourt(e.offre), url: u).font(.callout.weight(.semibold))
                } else {
                    Text(SuiviCalcul.nomCourt(e.offre)).font(.callout.weight(.semibold))
                }
            }
            Text("\(e.offre.source) · \(eur(e.offre.prix)) · \(e.bande ?? 0) Go/s · \(eur2(e.score)) par Go/s")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Tag(text: e.offre.etat.libelle, color: .blue)
                if let v = e.offre.ville, !v.isEmpty {
                    Tag(text: (e.offre.vendeurPro == true ? "Pro" : "Particulier") + " · \(v)" + (e.offre.distanceKm.map { " · \(Int($0.rounded())) km" } ?? ""), color: .purple)
                } else {
                    Tag(text: e.offre.livraison.libelle, color: couleurLivraison(e.offre.livraison))
                }
                Tag(text: e.offre.clavier, color: e.offre.clavier == "AZERTY" ? .green : .orange)
                if let g = e.offre.grade, !g.isEmpty { Tag(text: g, color: .teal) }
            }
        }
        .help(e.offre.remarque)
    }

    // MARK: Statistiques

    private var grilleStats: some View {
        let s = store.statistiques
        var cartes: [(String, String)] = [("Relevés", "\(s.releves)")]
        if s.releves > 0 { cartes.append(("Premier relevé", jour(s.premier))) }
        if let m = s.moinsCherAujourdhui { cartes.append(("Moins cher aujourd'hui", eur(m))) }
        if let v = s.variationTotale {
            cartes.append(("Moins cher : variation totale", (v > 0 ? "+" : "") + eur(v)))
            cartes.append(("Plus bas / plus haut observé", "\(eur(s.plusBas)) / \(eur(s.plusHaut))"))
            cartes.append(("Moyenne du moins cher", eur(s.moyenne)))
        }
        if s.aPrecedent {
            cartes.append(("Depuis le relevé précédent", "\(s.baisses) baisse(s), \(s.hausses) hausse(s)"))
            cartes.append(("Annonces nouvelles / disparues", "\(s.nouvelles) / \(s.disparues)"))
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Statistiques").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                ForEach(cartes, id: \.0) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.1).font(.title3.weight(.semibold).monospacedDigit())
                        Text(c.0).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).card()
                }
            }
            if s.releves < 2 {
                Text("Les tendances apparaissent à partir de deux relevés : relance la vérification de temps en temps (une fois par jour suffit).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Classement

    private var classement: some View {
        let liste = store.classement
        let ch = store.changements
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Classement des offres actuelles").font(.headline)
                Spacer()
                Button { exporterCSV(liste) } label: { Label("Exporter en CSV", systemImage: "square.and.arrow.up") }
                    .disabled(liste.isEmpty)
            }
            if liste.isEmpty {
                Text("Aucune offre à afficher : lance un relevé, ou assouplis les filtres.").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                        GridRow {
                            ForEach(["#", "Machine et vendeur", "Prix", "Go/s", "€ par Go/s", "Livraison, clavier, état"], id: \.self) {
                                Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(Array(liste.enumerated()), id: \.element.id) { i, e in ligne(i, e, ch) }
                    }
                    .padding(.vertical, 4)
                }
            }
            if !ch.disparues.isEmpty, let depuis = ch.depuis {
                DisclosureGroup("Disparues depuis le \(jour(depuis)) (\(ch.disparues.count))") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(ch.disparues.prefix(30)) { o in
                            Text("\(SuiviCalcul.nomCourt(o)) — \(o.source) — \(eur(o.prix))").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.font(.callout)
            }
            Text("Score = prix ÷ bande passante en Go/s : plus il est bas, plus l'offre est rentable pour l'IA locale. Bande passante d'après les fiches techniques Apple.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func exporterCSV(_ liste: [SuiviEvaluation]) {
        let panneau = NSSavePanel()
        panneau.nameFieldStringValue = "suivi-macbook-ia.csv"
        panneau.allowedContentTypes = [.commaSeparatedText]
        if panneau.runModal() == .OK, let u = panneau.url {
            try? SuiviModeles.csv(liste).write(to: u, atomically: true, encoding: .utf8)
        }
    }

    private func ligne(_ i: Int, _ e: SuiviEvaluation, _ ch: SuiviChangements) -> some View {
        let o = e.offre
        let precedent = o.manuelle ? nil : SuiviCalcul.prixPrecedent(o.key, store.historique.releves)
        return GridRow {
            Text(e.score == nil ? "–" : "\(i + 1)").foregroundStyle(i == 0 && e.score != nil ? .green : .primary)
            VStack(alignment: .leading, spacing: 2) {
                if let u = URL(string: o.url), !o.url.isEmpty {
                    LienArrierePlan(titre: SuiviCalcul.nomCourt(o), url: u).font(.callout.weight(.medium))
                } else {
                    Text(SuiviCalcul.nomCourt(o)).font(.callout.weight(.medium))
                }
                Text("\(o.source) · \(o.pays) · \(o.etat.libelle)").font(.caption).foregroundStyle(.secondary)
                if ch.parCle[o.key] == .nouvelle { Tag(text: "Nouvelle", color: .green) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(eur(o.prix)).monospacedDigit()
                if let p = precedent, p != o.prix {
                    Text("\(o.prix < p ? "▼" : "▲") \(eur(abs(o.prix - p)))").font(.caption)
                        .foregroundStyle(o.prix < p ? .green : .red)
                }
            }
            Text(e.bande.map(String.init) ?? "?").monospacedDigit()
            Text(eur2(e.score)).monospacedDigit().fontWeight(i == 0 && e.score != nil ? .bold : .regular)
            VStack(alignment: .leading, spacing: 3) {
                if let v = o.ville, !v.isEmpty {
                    Tag(text: (o.vendeurPro == true ? "Pro" : "Particulier") + " · \(v)" + (o.distanceKm.map { " · \(Int($0.rounded())) km" } ?? ""), color: .purple)
                } else {
                    Tag(text: o.livraison.libelle, color: couleurLivraison(o.livraison))
                }
                HStack(spacing: 4) {
                    Tag(text: o.clavier, color: o.clavier == "AZERTY" ? .green : .orange)
                    if let g = o.grade, !g.isEmpty { Tag(text: g, color: .teal) }
                }
            }
            .help(o.remarque)
        }
    }

    // MARK: Mes 3 modèles (suivi par modèle, pas par site)

    private static let ssds = ["", "512 Go", "1 To", "2 To", "4 To", "8 To"]

    private var sectionModeles: some View {
        let suivis = store.suivisModeles
        let notes = Dictionary(store.affaires.map { ($0.id, $0.note) }, uniquingKeysWith: { a, _ in a })
        return VStack(alignment: .leading, spacing: 14) {
            Text("Mes 3 modèles préférés").font(.title2.weight(.bold))
            Text("Pour chacun : le meilleur prix du moment tous sites confondus, le prix du marché (médiane des vendeurs) et l'évolution. Les offres de chaque modèle sont classées par rentabilité (marché + offres au même prix). Change le modèle avec les menus, ou vise « Bonnes affaires » pour tous les modèles.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(Array(suivis.enumerated()), id: \.element.id) { i, sm in carteModele(i, sm, notes) }
        }
    }

    private func carteModele(_ i: Int, _ sm: SuiviSuiviModele, _ notes: [String: Double]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Puce", selection: $store.favoris[i].puce) { ForEach(["M2 Max", "M3 Max", "M4 Max", "M5 Max", "Ultra"], id: \.self) { Text($0).tag($0) } }.fixedSize()
                Picker("Écran", selection: $store.favoris[i].ecran) { Text("Tous écrans").tag(0); Text("14\"").tag(14); Text("16\"").tag(16) }.fixedSize()
                Picker("Mémoire", selection: $store.favoris[i].ram) { Text("36 Go").tag(36); Text("48 Go").tag(48); Text("64 Go").tag(64) }.fixedSize()
                Picker("Stockage", selection: $store.favoris[i].ssd) {
                    ForEach(Self.ssds, id: \.self) { Text($0.isEmpty ? "Tous stockages" : $0).tag($0) }
                }.fixedSize()
            }
            .labelsHidden()
            if let b = sm.meilleur {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(eur(b.offre.prix)).font(.title.weight(.bold).monospacedDigit())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("meilleur prix : \(b.offre.source) · \(b.offre.etat.libelle)").font(.callout)
                        if let p = sm.minPrecedent, p != b.offre.prix {
                            Text("\(b.offre.prix < p ? "▼" : "▲") \(eur(abs(b.offre.prix - p))) depuis le relevé précédent")
                                .font(.caption).foregroundStyle(b.offre.prix < p ? .green : .red)
                        }
                    }
                }
                Text("Marché : médiane \(eur(sm.mediane)) sur \(sm.offres.count) offre(s) de \(sm.vendeurs) vendeur(s)"
                     + (sm.plusBasObserve.map { " · plus bas observé \(eur($0))" } ?? ""))
                    .font(.callout).foregroundStyle(.secondary)
                if sm.serieMin.count > 1 {
                    Chart {
                        ForEach(sm.serieMin) { p in
                            LineMark(x: .value("Date", p.date), y: .value("Prix", p.valeur), series: .value("Courbe", "Meilleur prix"))
                                .foregroundStyle(by: .value("Courbe", "Meilleur prix"))
                        }
                        ForEach(sm.serieMediane) { p in
                            LineMark(x: .value("Date", p.date), y: .value("Prix", p.valeur), series: .value("Courbe", "Prix du marché (médiane)"))
                                .foregroundStyle(by: .value("Courbe", "Prix du marché (médiane)"))
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 150)
                } else {
                    Text("La courbe apparaît à partir de deux relevés.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(sm.offres.sorted { (notes[$0.id] ?? -999) > (notes[$1.id] ?? -999) }.prefix(3)) { e in
                    HStack {
                        if let u = URL(string: e.offre.url), !e.offre.url.isEmpty {
                            LienArrierePlan(titre: "\(e.offre.source)", url: u).font(.callout)
                        } else { Text(e.offre.source).font(.callout) }
                        Text("\(eur(e.offre.prix)) · \(e.offre.etat.libelle) · \(e.offre.clavier)" + (notes[e.id].map { String(format: " · note %+.0f", $0) } ?? "")).font(.caption).foregroundStyle(.secondary)
                        Tag(text: e.offre.livraison.libelle, color: couleurLivraison(e.offre.livraison))
                    }
                }
            } else {
                Text("Aucune offre pour ce modèle dans le dernier relevé (ou masquée par les filtres).").foregroundStyle(.secondary)
            }
        }
        .card(padding: 14)
    }

    // MARK: Bonnes affaires : écart avec le prix du marché

    private var sectionAffaires: some View {
        let liste = store.affaires
        return VStack(alignment: .leading, spacing: 10) {
            Text("Les plus rentables par rapport au prix du marché").font(.title2.weight(.bold))
            Text("Prix du marché = médiane des offres du même modèle (puce, écran, mémoire, stockage) dans le même état (neuf, reconditionné, occasion), au moins 3 offres de 2 vendeurs. Classement par note de rentabilité = moyenne de deux écarts : le prix face au marché de son modèle, et la performance (Go/s) face aux offres vendues à ±10 % du même prix, tous modèles confondus. Pas de modèle favori imposé. « ≈ tokens/s » = vitesse estimée d'une IA locale de 20 Go : c'est la bande passante qui la fixe.")
                .font(.callout).foregroundStyle(.secondary)
            if liste.isEmpty {
                Text("Pas assez d'offres comparables : lance un relevé ou assouplis les filtres.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    GridRow {
                        ForEach(["Machine et vendeur", "Prix", "Marché", "Sous le marché", "≈ tokens/s", "Perf. vs même prix", "Sous le neuf", "Note", "Remarques"], id: \.self) {
                            Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(liste.prefix(40)) { a in
                        GridRow {
                            VStack(alignment: .leading, spacing: 2) {
                                if let u = URL(string: a.offre.url), !a.offre.url.isEmpty {
                                    LienArrierePlan(titre: SuiviCalcul.nomCourt(a.offre), url: u).font(.callout.weight(.medium))
                                } else { Text(SuiviCalcul.nomCourt(a.offre)).font(.callout.weight(.medium)) }
                                Text("\(a.offre.source) · \(a.offre.pays) · \(a.offre.etat.libelle)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(eur(a.offre.prix)).monospacedDigit()
                            Text("\(eur(a.reference))").monospacedDigit().foregroundStyle(.secondary)
                            Text("\(a.ecart >= 0 ? "−" : "+")\(Int(abs(a.ecart).rounded())) %").monospacedDigit()
                                .fontWeight(.bold).foregroundStyle(a.suspect ? .orange : (a.ecart >= 8 ? .green : .primary))
                            Text(a.evaluation.bande.map { "\(Int((Double($0) * 0.65 / 20).rounded()))" } ?? "–").monospacedDigit().fontWeight(.semibold)
                                .help("Estimation : débit de génération d'un modèle de 20 Go (32 milliards de paramètres, quantifié 4 bits) ≈ 65 % de la bande passante ÷ 20 Go. Un ordre de grandeur, pas une mesure.")
                            Text(a.perfVoisins.map { "\($0 >= 0 ? "+" : "−")\(Int(abs($0).rounded())) %" } ?? "–").monospacedDigit()
                                .foregroundStyle((a.perfVoisins ?? 0) > 0 ? .green : .primary)
                                .help("Bande passante (Go/s) comparée à la médiane de \(a.nbVoisins) offres vendues à ±10 % du même prix, tous modèles confondus")
                            Text(a.economieNeuf.map { "\($0 >= 0 ? "−" : "+")\(Int(abs($0).rounded())) %" } ?? "–").monospacedDigit()
                            Text(String(format: "%+.0f", a.note)).font(.callout.weight(.bold)).monospacedDigit()
                            VStack(alignment: .leading, spacing: 3) {
                                if a.suspect {
                                    Tag(text: a.offre.source.hasPrefix("Leboncoin") ? "Prix suspect : méfie-toi" : "Prix anormalement bas", color: .orange)
                                }
                                Tag(text: a.offre.livraison.libelle, color: couleurLivraison(a.offre.livraison))
                                Tag(text: a.offre.clavier, color: a.offre.clavier == "AZERTY" ? .green : .orange)
                            }
                        }
                    }
                }
                if liste.contains(where: { $0.suspect }) || liste.contains(where: { $0.offre.source.hasPrefix("Leboncoin") }) {
                    Text("Avant d'acheter une occasion (surtout Leboncoin) : une offre très en dessous du marché est souvent une arnaque. Demande la facture d'origine et le numéro de série (vérifiable sur checkcoverage.apple.com), vérifie la batterie (cycles) et que le Mac n'est pas verrouillé iCloud ou par un MDM, et paie en main propre ou avec une protection (pas de virement à un inconnu).")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Évolution

    private var evolution: some View {
        let toutes = store.series
        let affichees = serieChoisie == "__toutes" ? toutes : toutes.filter { $0.id == serieChoisie }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Évolution du prix").font(.headline)
            Picker("Offre suivie", selection: $serieChoisie) {
                Text("Toutes les offres").tag("__toutes")
                ForEach(toutes) { Text($0.nom).tag($0.id) }
            }
            .frame(maxWidth: 520)
            if affichees.isEmpty {
                Text("Pas encore de données.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(affichees) { s in
                        ForEach(s.points) { p in
                            LineMark(x: .value("Date", p.date), y: .value("Prix (€)", p.valeur), series: .value("Offre", s.nom))
                                .foregroundStyle(by: .value("Offre", s.nom))
                            PointMark(x: .value("Date", p.date), y: .value("Prix (€)", p.valeur))
                                .foregroundStyle(by: .value("Offre", s.nom))
                        }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartLegend(affichees.count > 6 ? .hidden : .visible)
                .frame(height: 280)
                .accessibilityLabel("Courbes du prix de chaque offre au fil des relevés")
                if affichees.count > 6 {
                    Text("Choisis une offre dans la liste pour voir sa courbe seule.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Meilleur score au fil du temps (prix par Go/s)").font(.headline).padding(.top, 8)
            let pts = store.scoreAuFilDuTemps
            if pts.isEmpty {
                Text("Pas encore de données.").foregroundStyle(.secondary)
            } else {
                Chart(pts) { p in
                    LineMark(x: .value("Date", p.date), y: .value("€ par Go/s", p.valeur))
                    PointMark(x: .value("Date", p.date), y: .value("€ par Go/s", p.valeur))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 200)
                .accessibilityLabel("Courbe du meilleur score (prix par Go/s) au fil des relevés")
            }
        }
    }

    // MARK: Offres à la main

    private var offresManuelles: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Offres d'occasion saisies à la main").font(.headline)
                Spacer()
                Button("Ajouter une offre…") { ajoutOuvert = true }
            }
            Text("Une offre vue sur un site que l'app ne lit pas (Leboncoin, un particulier…) : saisis-la ici pour la classer avec les autres.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(store.historique.manuelles) { o in
                HStack {
                    Text("\(SuiviCalcul.nomCourt(o)) — \(o.source) (\(o.pays)) — \(eur(o.prix))").font(.callout)
                    Spacer()
                    Button("Supprimer", role: .destructive) { store.supprimerManuelle(o.key) }.buttonStyle(.borderless)
                }
                .card(padding: 8)
            }
        }
    }

    // MARK: IA

    private var sectionIA: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Analyse par l'IA").font(.headline)
            Text("Utilise l'IA choisie dans les Réglages. Elle reçoit seulement les prix et les calculs ci-dessus, rien de personnel.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { Task { await store.analyser() } } label: { Label("Analyser avec l'IA", systemImage: "sparkles") }
                    .disabled(store.analyseEnCours || store.classement.isEmpty)
                if store.analyseEnCours { ProgressView().controlSize(.small) }
            }
            if let t = store.analyse {
                Text(t).textSelection(.enabled).card(padding: 12)
            }
            if let e = store.erreurAnalyse { Text(e).foregroundStyle(.red).font(.callout) }
        }
    }
}

// MARK: - Ajout d'une offre à la main

private struct SuiviAjoutSheet: View {
    @ObservedObject var store: SuiviMacStore
    @Environment(\.dismiss) private var dismiss
    @State private var vendeur = "Back Market"
    @State private var pays = "FR"
    @State private var puce = "M4 Max"
    @State private var ecran = 16
    @State private var ram = 48
    @State private var gpu = 40
    @State private var ssd = "1 To"
    @State private var clavier = "AZERTY"
    @State private var prix: Double?
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ajouter une offre d'occasion").font(.title3.weight(.semibold))
            Form {
                TextField("Vendeur", text: $vendeur)
                Picker("Pays du vendeur", selection: $pays) { ForEach(["FR", "BE", "DE", "NL", "IT", "ES", "AT", "IE"], id: \.self) { Text($0).tag($0) } }
                Picker("Puce", selection: $puce) { ForEach(["M2 Max", "M3 Max", "M4 Max", "M5 Max"], id: \.self) { Text($0).tag($0) } }
                Picker("Écran", selection: $ecran) { Text("14\"").tag(14); Text("16\"").tag(16) }
                Picker("Mémoire", selection: $ram) { Text("36 Go").tag(36); Text("48 Go").tag(48) }
                Picker("GPU (cœurs)", selection: $gpu) { ForEach([30, 32, 40], id: \.self) { Text("\($0)").tag($0) } }
                TextField("Stockage (ex. 1 To)", text: $ssd)
                Picker("Clavier", selection: $clavier) { ForEach(["AZERTY", "QWERTZ", "QWERTY"], id: \.self) { Text($0).tag($0) } }
                TextField("Prix (€)", value: $prix, format: .number)
                TextField("Lien (facultatif)", text: $url)
            }
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Ajouter") {
                    if let p = prix, p > 0 {
                        store.ajouterManuelle(vendeur: vendeur, pays: pays, puce: puce, ecran: ecran, ram: ram, gpu: gpu, ssd: ssd,
                                              clavier: clavier, prix: p, url: url)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((prix ?? 0) <= 0)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Lien qui s'ouvre dans le navigateur SANS passer devant l'app : on peut cliquer plusieurs offres à la suite
/// et les retrouver dans les onglets du navigateur.
private struct LienArrierePlan: View {
    let titre: String
    let url: URL

    var body: some View {
        Button(titre) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.open(url, configuration: config, completionHandler: nil)
        }
        .buttonStyle(.link)
        .help("S'ouvre dans le navigateur, en arrière-plan : \(url.host ?? "")")
    }
}
#endif
