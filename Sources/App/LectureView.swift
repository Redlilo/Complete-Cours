import SwiftUI
import AppKit

/// Partie « Écouter un cours » : écouter, relire avant l'envoi, fiches, devoirs.
struct LectureView: View {
    @ObservedObject private var model = LectureModel.shared
    @Environment(\.openSettings) private var openSettings
    @AppStorage("lecture.matiere") private var matiere = ""
    @AppStorage("lecture.prof") private var prof = ""
    @State private var recherche = ""
    @State private var feuille: Feuille?
    /// Cours à supprimer, en attente de confirmation (tout son texte est perdu).
    @State private var aSupprimer: LectureCours?

    enum Feuille: Identifiable {
        case relecture(UUID), fiche(UUID), reglages, importer
        var id: String {
            switch self {
            case .relecture(let i): return "r\(i)"
            case .fiche(let i): return "f\(i)"
            case .reglages: return "reglages"
            case .importer: return "importer"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Écouter un cours", subtitle: "Enregistre le cours, retire les remarques aux élèves, fait la fiche") {
                HStack {
                    Button("Importer un texte") { feuille = .importer }
                    Button("Réglages de l'écoute") { feuille = .reglages }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let m = model.message { bandeau(m, couleur: .blue) { model.message = nil } }
                    moteur
                    carteEcoute
                    carteARelire
                    carteTraitement
                    carteDevoirs
                    carteFiches
                }
                .padding(20)
            }
        }
        .sheet(item: $feuille) { f in
            switch f {
            case .relecture(let id): LectureRelectureView(id: id)
            case .fiche(let id): LectureFicheView(id: id)
            case .reglages: LectureReglagesView()
            case .importer: LectureImportView()
            }
        }
        .onAppear {
            if matiere.isEmpty || !model.reglages.matieres.contains(matiere) { matiere = model.reglages.matieres.first ?? "" }
            if prof.isEmpty { prof = model.reglages.profs.first?.nom ?? "" }
            model.relancerEnAttente()
            ouvrirSiBesoin()
        }
        .onChange(of: model.aOuvrir) { _, _ in ouvrirSiBesoin() }
        .confirmationDialog("Supprimer « \(aSupprimer?.titre ?? "") » ?",
                            isPresented: Binding(get: { aSupprimer != nil }, set: { if !$0 { aSupprimer = nil } }),
                            presenting: aSupprimer) { c in
            Button("Supprimer", role: .destructive) { model.supprimer([c.id]); aSupprimer = nil }
            Button("Annuler", role: .cancel) { aSupprimer = nil }
        } message: { c in
            Text(c.phrases.isEmpty ? "Ce cours sera supprimé." : "Le texte de ce cours (\(c.phrases.count) phrases) sera perdu : il ne peut pas être récupéré.")
        }
    }

    /// À la fin du cours la relecture s'ouvre toute seule ; quand la fiche est prête, elle aussi.
    private func ouvrirSiBesoin() {
        guard let o = model.aOuvrir, feuille == nil else { return }
        switch o {
        case .relecture(let id): feuille = .relecture(id)
        case .fiche(let id): feuille = .fiche(id)
        }
        model.aOuvrir = nil
    }

    // MARK: Cartes

    private func bandeau(_ texte: String, couleur: Color, fermer: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top) {
            Text(texte).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            if let fermer { Button("OK", action: fermer).buttonStyle(.borderless) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(couleur.opacity(0.12)))
    }

    @ViewBuilder private var moteur: some View {
        let e = model.etatMoteur
        if !e.usable, let issue = e.issue {
            VStack(alignment: .leading, spacing: 6) {
                Text(issue.title).font(.headline)
                Text(issue.what + " " + issue.todo).font(.callout)
                Button("Ouvrir les Réglages") { openSettings() }
            }
            .card()
        }
    }

    private var carteEcoute: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.etat == .repos {
                Text("Appuie, le cours s'écrit tout seul").font(.title3.bold())
                HStack {
                    Picker("Matière", selection: $matiere) { ForEach(model.reglages.matieres, id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().frame(maxWidth: 180)
                    if model.reglages.profs.isEmpty {
                        TextField("Nom du prof", text: $prof).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    } else {
                        Picker("Prof", selection: $prof) {
                            ForEach(model.reglages.profs) { Text($0.nom).tag($0.nom) }
                            if !prof.isEmpty, !model.reglages.profs.contains(where: { $0.nom == prof }) { Text(prof).tag(prof) }
                        }.labelsHidden().frame(maxWidth: 200)
                        Button { prof = ""; model.message = "Écris le nom du nouveau prof dans la case « Nom du prof »." } label: { Image(systemName: "plus") }
                            .help("Ajouter un prof")
                            .accessibilityLabel("Ajouter un prof")
                    }
                    Spacer()
                }
                let accord = model.reglages.profs.first { $0.nom == prof }?.accord ?? false
                Toggle("Le prof est d'accord pour que j'enregistre son cours et que je reconnaisse sa voix", isOn: Binding(
                    get: { accord }, set: { model.accorder(prof, $0) }))
                    .disabled(prof.trimmingCharacters(in: .whitespaces).isEmpty)
                let voix = model.etatVoix(prof)
                Text(voix.texte).font(.caption).foregroundStyle(voix.couleur)
                Button { model.demarrer(matiere: matiere, prof: prof, titre: "") } label: {
                    Label("Commencer le cours", systemImage: "record.circle").font(.title3.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                .disabled(!accord)
                Text("Seulement quand tu appuies. L'audio reste sur ton Mac et s'efface dès que le texte est prêt. À la fin, tu relis en un coup d'œil puis l'IA fait la fiche.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 12, height: 12).opacity(model.etat == .ecoute ? 1 : 0.35)
                    Text(model.etat == .ecoute ? "Écoute en cours" : model.etat == .pause ? "En pause" : "Transcription en cours…")
                        .font(.headline)
                    Spacer()
                    Text(Self.chrono(model.duree)).font(.title3.monospacedDigit())
                }
                if model.enregistre {
                    ProgressView(value: min(1, Double(model.niveau) * 6)).tint(model.libelleNiveau.couleur)
                        .accessibilityLabel("Niveau sonore")
                        .accessibilityValue(model.libelleNiveau.texte)
                    Text(model.libelleNiveau.texte).font(.caption).foregroundStyle(model.libelleNiveau.couleur)
                    HStack {
                        Button(model.etat == .pause ? "Reprendre" : "Pause") { model.pause() }
                        Button("Fin du cours") { model.terminer() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                Divider()
                panneauDirect
            }
        }
        .card()
    }

    // MARK: En direct

    private var panneauDirect: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("En direct").font(.headline)
                Spacer()
                Toggle("Analyse en direct par l'IA", isOn: $model.analyseDirecteActive)
                    .toggleStyle(.switch)
                    .accessibilityLabel("Analyse en direct par l'IA")
                Button("Analyser maintenant") { model.analyserMaintenant() }
                    .disabled(model.analyseDirectEnCours || model.directFinal.isEmpty)
                    .accessibilityLabel("Analyser le cours maintenant")
            }
            Text("L'analyse en direct utilise un modèle léger (Haiku) de l'IA choisie ; la fiche finale garde ton réglage.")
                .font(.caption).foregroundStyle(.secondary)
            if let e = model.erreurDirect {
                Text(e).font(.caption).foregroundStyle(.orange)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    transcriptionDirect.frame(maxWidth: .infinity)
                    analyseDirecte.frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 14) {
                    transcriptionDirect
                    analyseDirecte
                }
            }
        }
    }

    private var transcriptionDirect: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if model.directFinal.isEmpty && model.directProvisoire.isEmpty {
                        Text("J'écoute…").foregroundStyle(.secondary).italic()
                    }
                    ForEach(Array(model.directFinal.enumerated()), id: \.offset) { _, s in
                        Text(s).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !model.directProvisoire.isEmpty {
                        Text(model.directProvisoire).italic().foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bas")
                }
                .textSelection(.enabled)
                .padding(8)
            }
            .frame(height: 260)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .accessibilityLabel("Transcription en direct du cours")
            .onChange(of: model.directFinal.count) { _, _ in proxy.scrollTo("bas", anchor: .bottom) }
            .onChange(of: model.directProvisoire) { _, _ in proxy.scrollTo("bas", anchor: .bottom) }
        }
    }

    private var analyseDirecte: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if model.analyseDirectEnCours {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Analyse en cours…").font(.caption).foregroundStyle(.secondary) }
                }
                if let a = model.analyseDirect {
                    if !a.resume.isEmpty { Text(a.resume) }
                    if !a.points.isEmpty {
                        blocDirect("À retenir") { ForEach(a.points, id: \.self) { Text("• \($0)") } }
                    }
                    if !a.termes.isEmpty {
                        blocDirect("Vocabulaire") { ForEach(a.termes, id: \.self) { Text("**\($0.terme)** : \($0.definition)") } }
                    }
                    if !a.devoirs.isEmpty {
                        blocDirect("Devoirs annoncés") { ForEach(a.devoirs, id: \.self) { Text("• \($0)").foregroundStyle(.orange) } }
                    }
                    if !a.doutes.isEmpty {
                        blocDirect("À vérifier") { ForEach(a.doutes, id: \.self) { Text("• \($0)") } }
                    }
                    Text("Mis à jour à \(a.date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("L'analyse arrive toutes les 2 minutes environ.").foregroundStyle(.secondary).italic()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(8)
        }
        .frame(height: 260)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .accessibilityLabel("Analyse en direct du cours")
    }

    private func blocDirect<C: View>(_ titre: String, @ViewBuilder _ contenu: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(titre).font(.subheadline.weight(.semibold))
            contenu()
        }
    }

    private var carteARelire: some View {
        let l = model.cours.filter { $0.statut == .aRelire }
        return Group {
            if !l.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("À relire avant l'envoi").font(.headline)
                    ForEach(l) { c in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(c.titre).font(.body.weight(.medium))
                                Text("\(c.matiere) · \(c.phrases.count) phrases").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Relire et envoyer") { feuille = .relecture(c.id) }.buttonStyle(.borderedProminent)
                            Button(role: .destructive) { aSupprimer = c } label: { Image(systemName: "trash") }
                                .help("Supprimer ce cours")
                                .accessibilityLabel("Supprimer ce cours")
                        }
                    }
                }
                .card()
            }
        }
    }

    private var carteTraitement: some View {
        let l = model.cours.filter { [.enAttente, .traitement, .erreur].contains($0.statut) }
        return Group {
            if !l.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("En cours ou à régler").font(.headline)
                    ForEach(l) { c in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { Text(c.titre).font(.body.weight(.medium))
                                    Tag(text: c.statut.libelle, color: c.statut == .erreur ? .red : .orange) }
                                if let e = c.erreur { Text(e).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if c.statut != .traitement, !c.phrases.isEmpty { Button("Réessayer") { model.envoyer(c.id) } }
                            if c.statut != .traitement { Button(role: .destructive) { aSupprimer = c } label: { Image(systemName: "trash") }.help("Supprimer ce cours").accessibilityLabel("Supprimer ce cours") }
                            if c.statut == .traitement { ProgressView().controlSize(.small) }
                        }
                    }
                }
                .card()
            }
        }
    }

    private var carteDevoirs: some View {
        let a = LectureTexte.agenda(model.cours)
        return Group {
            if !a.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Devoirs et contrôles").font(.headline)
                    Text("Repérés dans tes cours : à vérifier sur Pronote.").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(a.prefix(8).enumerated()), id: \.offset) { _, x in
                        HStack { Text(x.devoir.quoi).fontWeight(.medium); Spacer(); Text(Self.jourDuDevoir(x.devoir)).foregroundStyle(.secondary)
                            Tag(text: x.cours.matiere, color: SubjectStyle.color(x.cours.matiere)) }
                    }
                }
                .card()
            }
        }
    }

    private var carteFiches: some View {
        let l = model.cours.filter { c in
            c.statut == .pret && (recherche.isEmpty || [c.titre, c.matiere, c.fiche?.resume ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(recherche))
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Mes fiches").font(.headline)
                Spacer()
                TextField("Chercher un mot", text: $recherche).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            }
            if l.isEmpty { Text("Aucune fiche pour l'instant.").foregroundStyle(.secondary) }
            ForEach(l) { c in
                Button { feuille = .fiche(c.id) } label: {
                    HStack {
                        Image(systemName: SubjectStyle.symbol(c.matiere)).foregroundStyle(SubjectStyle.color(c.matiere))
                        VStack(alignment: .leading) {
                            Text(c.titre).font(.body.weight(.medium))
                            Text("\(c.matiere) · \(c.date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }

    /// « mar. 25 nov. (mardi) » quand la date a pu être calculée, sinon les mots du prof.
    static func jourDuDevoir(_ d: LectureDevoir) -> String {
        guard let date = d.date else { return d.pour }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + (d.pour.isEmpty ? "" : " (\(d.pour))")
    }

    static func chrono(_ s: TimeInterval) -> String {
        let n = Int(s)
        return String(format: "%02d:%02d:%02d", n / 3600, n % 3600 / 60, n % 60)
    }
}

// MARK: - Relecture avant l'envoi

struct LectureRelectureView: View {
    let id: UUID
    @ObservedObject private var model = LectureModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var edition: UUID?
    @State private var brouillon = ""

    var body: some View {
        let c = model.cours(id)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Relire avant l'envoi : \(c?.titre ?? "")").font(.title3.bold())
                Spacer()
                let e = model.etatMoteur
                Button(e.usable ? "Envoyer à l'IA" : "Moteur à régler dans les Réglages") { model.envoyer(id); dismiss() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!e.usable)
            }
            Text("Si tout va bien, appuie sur « Envoyer ». Sinon décoche ce qui ne doit pas partir (remarque perso, passage d'un élève). Les prénoms de ta liste sont déjà remplacés par « un élève ».\(c?.phrases.contains(where: { $0.qui != nil }) == true ? " Les passages qui ne sont pas la voix du prof (« élève ? ») sont déjà décochés ; ceux « incertain » sont à vérifier." : "")")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Tout décocher") { model.tout(false, dans: id) }
                Button("Tout cocher") { model.tout(true, dans: id) }
                Spacer()
                Text("\(c?.phrases.filter(\.garder).count ?? 0) / \(c?.phrases.count ?? 0) phrases gardées").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(c?.phrases ?? []) { p in
                      HStack(alignment: .top) {
                        if edition == p.id {
                            TextField("Phrase", text: $brouillon).textFieldStyle(.roundedBorder)
                                .onSubmit { model.modifierPhrase(p.id, dans: id, texte: brouillon); edition = nil }
                            Button("OK") { model.modifierPhrase(p.id, dans: id, texte: brouillon); edition = nil }
                            Button("Annuler") { edition = nil }
                        } else {
                        Toggle(isOn: Binding(get: { p.garder }, set: { _ in model.basculer(p.id, dans: id) })) {
                            HStack(alignment: .top) {
                                Text(Self.minutes(p.debut)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                                if let q = p.qui { Tag(text: q.libelle, color: q == .prof ? .green : (q == .autre ? .red : .orange)).frame(width: 64) }
                                Text(LectureTexte.retirerPrenoms(p.texte, prenoms: model.reglages.prenoms))
                                    .strikethrough(!p.garder).foregroundStyle(p.garder ? .primary : .secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: 4)
                        Button { brouillon = p.texte; edition = p.id } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).help("Corriger cette phrase : les mots changés sont retenus pour les prochains cours")
                            .accessibilityLabel("Corriger cette phrase")
                        }
                      }
                    }
                }
            }
            .frame(minHeight: 300)
            HStack { Button("Plus tard") { dismiss() }; Spacer() }
        }
        .padding(20).frame(minWidth: 640, minHeight: 520)
    }

    static func minutes(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

// MARK: - Fiche

struct LectureFicheView: View {
    let id: UUID
    @ObservedObject private var model = LectureModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmer = false

    var body: some View {
        if let c = model.cours(id), let f = c.fiche {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button("Fermer") { dismiss() }
                    Spacer()
                    Button("Copier la fiche") { model.copierLaFiche(c) }
                    Button("Enregistrer en PDF…") { model.enregistrerLaFiche(c) }
                    Button("Supprimer", role: .destructive) { confirmer = true }
                }
                .padding(14)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(f.titre).font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("\(c.matiere) · \(c.prof) · \(c.date.formatted(date: .long, time: .omitted))").foregroundStyle(.secondary)
                        if f.aVerifier.count > 2 { Tag(text: "À vérifier avec ton cahier", color: .orange) }
                        if !f.devoirs.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Devoirs et dates (à vérifier sur Pronote)").font(.headline)
                                ForEach(f.devoirs, id: \.self) { d in HStack { Text(d.quoi).fontWeight(.medium); Spacer(); Text(LectureView.jourDuDevoir(d)) } }
                            }.card()
                        }
                        if !f.definitions.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Définitions").font(.headline)
                                ForEach(f.definitions, id: \.self) { d in Text("**\(d.terme)** : \(d.definition)") }
                            }.card()
                        }
                        if !f.formules.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Formules").font(.headline)
                                ForEach(f.formules, id: \.self) { d in Text("**\(d.formule)**  \(d.unite)") }
                            }.card()
                        }
                        MarkdownLite(texte: f.resume)
                        if !f.aVerifier.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("À vérifier").font(.headline)
                                ForEach(f.aVerifier, id: \.self) { Text("• \($0)") }
                            }.card()
                        }
                        if !c.retire.isEmpty {
                            DisclosureGroup("Ce qui a été retiré (\(c.retire.count))") {
                                VStack(alignment: .leading, spacing: 3) { ForEach(c.retire, id: \.self) { Text("• \($0)").font(.callout) } }
                            }.card()
                        }
                    }
                    .padding(20)
                }
            }
            .frame(minWidth: 640, minHeight: 560)
            .confirmationDialog("Supprimer cette fiche ?", isPresented: $confirmer) {
                Button("Supprimer", role: .destructive) { model.supprimer([id]); dismiss() }
            }
        } else {
            Text("Cette fiche n'existe plus.").padding(40)
        }
    }
}

/// Affichage simple d'un texte Markdown : titres #, listes -, gras et italique.
struct MarkdownLite: View {
    let texte: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(texte.components(separatedBy: "\n").enumerated()), id: \.offset) { _, l in ligne(l) }
        }
    }

    @ViewBuilder private func ligne(_ l: String) -> some View {
        let t = l.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") {
            Text(t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)).font(.headline).padding(.top, 6)
        } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) { Text("•"); Text(inline(String(t.dropFirst(2)))) }
        } else if t.isEmpty {
            Color.clear.frame(height: 2)
        } else {
            Text(inline(t))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

// MARK: - Importer un texte

struct LectureImportView: View {
    @ObservedObject private var model = LectureModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var texte = ""
    @State private var titre = ""
    @State private var matiere = ""
    @State private var prof = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Importer un texte").font(.title3.bold())
            Text("Colle la transcription d'un cours (Notes, Dictaphone…). Tu la relis avant l'envoi.").foregroundStyle(.secondary)
            HStack {
                Picker("Matière", selection: $matiere) { ForEach(model.reglages.matieres, id: \.self) { Text($0).tag($0) } }
                Picker("Prof", selection: $prof) {
                    Text("(aucun)").tag("")
                    ForEach(model.reglages.profs) { Text($0.nom).tag($0.nom) }
                }
                TextField("Titre", text: $titre)
            }
            TextEditor(text: $texte).font(.body).frame(minHeight: 260).border(Color.primary.opacity(0.2))
            HStack {
                Button("Annuler") { dismiss() }
                Spacer()
                Button("Préparer la relecture") {
                    model.importer(texte: texte, matiere: matiere, prof: prof, titre: titre)
                    if model.message == nil { dismiss() }
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(minWidth: 620, minHeight: 440)
        .onAppear { matiere = model.reglages.matieres.first ?? "" }
    }
}

// MARK: - Réglages de l'écoute

struct LectureReglagesView: View {
    @ObservedObject private var model = LectureModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var r = LectureReglages()
    @State private var nouveauProf = ""
    @State private var effacer: String?
    @State private var confirmerInstallation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("Réglages de l'écoute").font(.title3.bold()); Spacer(); Button("Terminé") { fermer() }.buttonStyle(.borderedProminent) }

                GroupBox("Profs et accord") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("« Commencer » reste grisé tant que le prof n'a pas donné son accord (vérifie aussi le règlement du lycée). Les fiches sont pour toi seule : ne les partage pas.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach($r.profs) { $p in
                            HStack {
                                Text(p.nom).frame(minWidth: 120, alignment: .leading)
                                Toggle("J'ai l'accord de ce prof", isOn: $p.accord)
                                    .onChange(of: p.accord) { _, ok in
                                        p.dateAccord = ok ? Date().formatted(date: .numeric, time: .omitted) : ""
                                    }
                                Spacer()
                                Button("Retirer") { r.profs.removeAll { $0.nom == p.nom } }
                                Button("Tout effacer", role: .destructive) { effacer = p.nom }
                            }
                        }
                        HStack {
                            TextField("Nom du prof (ex. M. Durand)", text: $nouveauProf)
                            Button("Ajouter") {
                                let n = nouveauProf.trimmingCharacters(in: .whitespaces)
                                if !n.isEmpty, !r.profs.contains(where: { $0.nom == n }) { r.profs.append(LectureProf(nom: n)) }
                                nouveauProf = ""
                            }
                        }
                        Text("Message pour demander l'accord : « Bonjour, je souhaiterais enregistrer votre cours uniquement pour mes révisions personnelles. L'audio est transcrit sur mon ordinateur puis effacé ; je ne garde pas la voix des élèves, je ne partage ni ne publie rien, et je m'arrête tout de suite si vous me le demandez. Êtes-vous d'accord ? »")
                            .font(.caption).textSelection(.enabled)
                    }.padding(6)
                }

                GroupBox("Voix des profs") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("La voix d'un prof est retenue automatiquement pendant ses premiers cours (celle qui parle le plus), puis les élèves sont repérés tout seuls. Seule la voix du prof est gardée, sur ton Mac, sous forme de chiffres (pas d'audio). Jamais de voix d'élève.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !LectureVoix.disponible || model.installationVoix != .repos {
                            installationVoix
                        }
                        if r.profs.isEmpty { Text("Aucun prof pour l'instant.").foregroundStyle(.secondary) }
                        ForEach(r.profs) { p in
                            HStack {
                                Text(p.nom).frame(minWidth: 120, alignment: .leading)
                                let v = model.etatVoix(p.nom)
                                Text(v.texte).font(.caption).foregroundStyle(v.couleur).lineLimit(2)
                                Spacer()
                                if model.base.voix?[p.nom] != nil { Button("Oublier cette voix") { model.oublierLaVoix(p.nom) } }
                            }
                        }
                    }.padding(6)
                }

                liste("Prénoms de la classe", "Un par ligne. Ils sont remplacés par « un élève » avant tout envoi à l'IA.",
                      Binding(get: { r.prenoms.joined(separator: "\n") }, set: { r.prenoms = $0.components(separatedBy: "\n") }))
                liste("Lexique technique (MTNE)", "Un mot par ligne : l'IA s'en sert pour corriger les mots mal transcrits, et les mots très proches sont corrigés tout seuls.",
                      Binding(get: { r.lexique.joined(separator: "\n") }, set: { r.lexique = $0.components(separatedBy: "\n") }))
                liste("Corrections de transcription", "Une par ligne, sous la forme faux=juste (ex. loi dôme=loi d'Ohm).",
                      Binding(get: { r.corrections.joined(separator: "\n") }, set: { r.corrections = $0.components(separatedBy: "\n") }))
                liste("Matières", "Une par ligne.",
                      Binding(get: { r.matieres.joined(separator: "\n") }, set: { r.matieres = $0.components(separatedBy: "\n") }))

                GroupBox("Rythme") {
                    VStack(alignment: .leading, spacing: 6) {
                        Stepper("Morceaux de \(r.minutesParMorceau) min", value: $r.minutesParMorceau, in: 2...30)
                        Stepper("Arrêt après \(r.minutesSilenceAvantArret) min de silence", value: $r.minutesSilenceAvantArret, in: 2...60)
                        Stepper("Durée maximale \(r.minutesMaximum) min", value: $r.minutesMaximum, in: 10...300, step: 10)
                        Stepper("Texte brut effacé après \(r.joursAvantEffacementDuTexte) jours (la fiche reste)", value: $r.joursAvantEffacementDuTexte, in: 1...60)
                    }.padding(6)
                }
                Text("L'IA utilisée est celle choisie dans les Réglages de \(AppIdentity.nom). L'audio est effacé dès que le texte est prêt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 680, minHeight: 600)
        .onAppear { r = model.reglages }
        .onChange(of: r) { _, nouveau in model.reglages = nouveau }
        .confirmationDialog("Effacer toutes les fiches de ce prof ?", isPresented: Binding(get: { effacer != nil }, set: { if !$0 { effacer = nil } })) {
            Button("Tout effacer", role: .destructive) { if let n = effacer { model.effacerProf(n) }; effacer = nil }
        }
    }

    @ViewBuilder private var installationVoix: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.installationVoix {
            case .enCours:
                HStack { ProgressView().controlSize(.small); Text("Installation en cours… (quelques minutes, ne ferme pas l'app)") }
                Text(model.journalInstallation).font(.caption.monospaced()).foregroundStyle(.secondary)
            case .ok:
                Text("Reconnaissance de la voix installée.").foregroundStyle(.green)
            default:
                Text("La reconnaissance de la voix n'est pas installée. Elle télécharge environ 250 Mo depuis internet et occupe environ 1,1 Go sur ton Mac. Sans elle, les élèves sont repérés seulement d'après ce qui est dit.")
                    .font(.callout)
                if case .erreur(let m) = model.installationVoix { Text(m).font(.caption).foregroundStyle(.red) }
                Button(confirmerInstallation ? "Confirmer : télécharger et installer (1,1 Go)" : "Installer la reconnaissance de la voix") {
                    if confirmerInstallation { confirmerInstallation = false; model.installerLaVoix() } else { confirmerInstallation = true }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func liste(_ titre: String, _ aide: String, _ texte: Binding<String>) -> some View {
        GroupBox(titre) {
            VStack(alignment: .leading, spacing: 4) {
                Text(aide).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: texte).font(.body).frame(height: 90).border(Color.primary.opacity(0.2))
            }.padding(6)
        }
    }

    private func fermer() {
        func net(_ l: [String]) -> [String] { l.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        r.prenoms = net(r.prenoms); r.lexique = net(r.lexique); r.corrections = net(r.corrections); r.matieres = net(r.matieres)
        model.reglages = r
        dismiss()
    }
}
