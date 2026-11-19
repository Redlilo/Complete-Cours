import SwiftUI
import UniformTypeIdentifiers

// Interface des modes « Fiches de révision » et « Évaluations ». Pas de dépendance vers les autres vues de l'app
// (seulement le style commun de Style.swift). Les cartes mémoire sont dans RevisionCardsView.swift.

struct RevisionRootView: View {
    @ObservedObject var model: RevisionModel
    /// Parties proposées ; un seul onglet = pas de sélecteur (mode « Évaluations »).
    var tabs: [RevisionTab] = RevisionTab.allCases
    @Environment(\.openSettings) private var openSettings
    @State private var dropTargeted = false

    private var evaluationsOnly: Bool { tabs == [.apres] }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: evaluationsOnly ? "Évaluations" : "Fiches de révision", subtitle: headerSubtitle) {
                HStack(spacing: 8) {
                    Tag(text: model.engine.name, color: model.engine.usable ? .green : .orange)
                    if model.hasDocument {
                        Button("Changer de PDF…") { model.chooseDocument() }.disabled(model.isBusy)
                    }
                }
            }
            if let issue = model.issue { IssueBanner(issue: issue) { model.issue = nil } }
            if !model.engine.usable { engineBanner }
            if model.hasDocument {
                if tabs.count > 1 {
                    TabPills(tabs: tabs, selection: $model.tab)
                        .padding(.horizontal, 20).padding(.bottom, 10)
                }
                Divider()
                if let activity = model.activity { ActivityBar(activity: activity) { model.cancel() } }
                Group {
                    switch model.tab {
                    case .fiche: SummaryTab(model: model)
                    case .entrainement: QuizTab(model: model)
                    case .cartes: CardsTab(model: model)
                    case .apres: CorrigeTab(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DropZone(model: model, evaluationsOnly: evaluationsOnly, targeted: dropTargeted)
            }
            if let notice = model.notice {
                Divider()
                Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(notice)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3).padding(4).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.handleDrop([url]) } }
                }
            }
            return true
        }
        .onAppear {
            model.refreshEngine()
            if !tabs.contains(model.tab), let first = tabs.first { model.tab = first }
        }
        // l'élève change de moteur ou ajoute sa clé dans les Réglages : les boutons se débloquent sans rouvrir le cours
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshEngine() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in model.refreshEngine() }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var headerSubtitle: String {
        let engine = "Moteur : \(model.engine.name)"
        return model.hasDocument ? "\(model.documentName) · \(Fr.pages(model.pageCount)) · \(engine)" : engine
    }

    private var engineBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.engine.issue?.what ?? RevisionEngineStatus.message.what).fontWeight(.semibold)
                Text(model.engine.issue?.todo ?? RevisionEngineStatus.message.todo).foregroundStyle(.secondary)
            }
            Spacer()
            if model.engine.needsSettings {
                Button("Ouvrir les Réglages") { openSettings() }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Onglets

/// Onglets en pastilles : pictogramme et titre, l'onglet choisi est en couleur.
struct TabPills: View {
    let tabs: [RevisionTab]
    @Binding var selection: RevisionTab
    var body: some View {
        HStack(spacing: 8) {
            ForEach(tabs) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Partie de la révision")
    }
}

// MARK: - Zone de dépôt

struct DropZone: View {
    @ObservedObject var model: RevisionModel
    let evaluationsOnly: Bool
    let targeted: Bool

    private var steps: [(String, String)] {
        evaluationsOnly
        ? [("doc.richtext", "Ouvre ta copie rendue et corrigée"), ("sparkles", "L'app lit tes réponses et les remarques"), ("lightbulb", "Tu comprends tes erreurs")]
        : [("doc.richtext", "Choisis ton cours en PDF"), ("sparkles", "Fiche, questions ou cartes mémoire"), ("graduationcap", "Révise, puis enregistre en PDF")]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 92, height: 92)
                    Image(systemName: targeted ? "arrow.down.doc.fill" : (evaluationsOnly ? "checkmark.seal" : "tray.and.arrow.down"))
                        .font(.system(size: 38, weight: .light)).foregroundStyle(Color.accentColor)
                }
                .accessibilityHidden(true)
                Text(evaluationsOnly ? "Comprends ton évaluation" : "Révise un cours")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(evaluationsOnly
                     ? "Dépose ici une évaluation DÉJÀ rendue et corrigée par ton professeur : l'app prépare un corrigé expliqué. Ton PDF n'est jamais modifié."
                     : "Dépose ici le PDF d'un cours. L'app te prépare une fiche de synthèse, des questions d'entraînement et des cartes mémoire. Ton PDF n'est jamais modifié.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        VStack(spacing: 6) {
                            Image(systemName: step.0).font(.title3).foregroundStyle(Color.accentColor)
                            Text(step.1).font(.caption).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity).card(padding: 10)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Étape \(i + 1) : \(step.1)")
                    }
                }
                .frame(maxWidth: 520)
                Button { model.chooseDocument() } label: {
                    Label(evaluationsOnly ? "Choisir mon évaluation…" : "Choisir un PDF…", systemImage: "folder").padding(.horizontal, 8)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                Text("ou glisse-le sur cette fenêtre").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(32)
            .frame(maxWidth: 600)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.accentColor.opacity(targeted ? 0.08 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 20)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Bandeaux et chargement

struct IssueBanner: View {
    let issue: RevisionIssue
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).fontWeight(.semibold)
                Text(issue.what)
                Text(issue.todo).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            Spacer()
            Button("Fermer", action: dismiss)
        }
        .padding(12)
        .background(Color.red.opacity(0.10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Problème : \(issue.title). \(issue.what) \(issue.todo)")
    }
}

/// Carte de progression : roue, barre, ce que fait l'app, bouton « Annuler ».
struct ActivityBar: View {
    let activity: RevisionModel.Activity
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.label).font(.callout.weight(.medium)).lineLimit(1)
                ProgressView(value: activity.fraction)
                    .accessibilityLabel("Progression")
                    .accessibilityValue("\(Int(activity.fraction * 100)) pour cent")
            }
            Button("Annuler", action: cancel).keyboardShortcut(.cancelAction)
        }
        .card(selected: true, padding: 12)
        .padding(.horizontal, 20).padding(.top, 10)
    }
}

/// Faux contenu qui pulse pendant le chargement (ne montre rien d'inventé : seulement des barres grises).
struct SkeletonCard: View {
    var lines = 4
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<lines, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(pulse ? 0.12 : 0.05))
                    .frame(height: 12)
                    .frame(maxWidth: i == lines - 1 ? 180 : .infinity, alignment: .leading)
            }
        }
        .card()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityHidden(true)
    }
}

/// Grande carte d'accueil d'un onglet (pictogramme, titre, explication).
struct HeroCard: View {
    let icon: String, title: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.14)).frame(width: 52, height: 52)
                Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 20, weight: .bold, design: .rounded)).accessibilityAddTraits(.isHeader)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 16)
    }
}

struct EstimateNote: View {
    @ObservedObject var model: RevisionModel
    var body: some View {
        if let e = model.estimate { Text(e).font(.caption).foregroundStyle(.tertiary) }
    }
}

/// Disposition qui passe à la ligne : pour les pastilles.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

/// Pastille cliquable (choisie = en couleur, avec une coche).
struct Chip: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                Text(label).font(.callout)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Consigne libre

/// « Ta consigne (facultatif) » avec des pastilles de raccourci. La consigne règle seulement la mise en forme.
struct InstructionField: View {
    @ObservedObject var model: RevisionModel
    let target: InstructionTarget

    var body: some View {
        let text = Binding(get: { model.instruction(for: target) }, set: { model.setInstruction($0, for: target) })
        let length = model.instruction(for: target).count
        VStack(alignment: .leading, spacing: 10) {
            Label("Ta consigne (facultatif)", systemImage: "text.cursor").font(.headline)
            TextField("Par exemple : très court, avec seulement les formules", text: text, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isBusy)
                .accessibilityLabel("Ta consigne")
            FlowLayout(spacing: 8) {
                ForEach(InstructionShortcut.all) { shortcut in
                    Chip(label: shortcut.label, selected: model.isActive(shortcut, for: target)) {
                        model.toggleShortcut(shortcut, for: target)
                    }
                    .disabled(model.isBusy)
                }
            }
            Text(length > RevisionPrompts.maxInstructionChars
                 ? "Ta consigne est trop longue : seuls les \(RevisionPrompts.maxInstructionChars) premiers caractères seront utilisés."
                 : "La consigne règle seulement la longueur et la présentation. L'app reste sur ton cours.")
                .font(.caption).foregroundStyle(length > RevisionPrompts.maxInstructionChars ? Color.orange : Color.secondary)
        }
        .card()
    }
}

// MARK: - Fiche de synthèse

struct SummaryTab: View {
    @ObservedObject var model: RevisionModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let s = model.summary {
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.title).font(.system(size: 22, weight: .bold, design: .rounded)).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Enregistrer en PDF…") { model.saveSummaryPDF() }
                            .buttonStyle(.borderedProminent).disabled(model.isBusy)
                    }
                    if !s.keyPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "L'essentiel", icon: "list.number")
                            ForEach(Array(s.keyPoints.enumerated()), id: \.offset) { i, item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(i + 1)").font(.callout.weight(.bold)).foregroundStyle(Color.accentColor).frame(width: 20, alignment: .trailing)
                                    Text(item).textSelection(.enabled)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).card()
                    }
                    if !s.vocabulary.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Vocabulaire", icon: "character.book.closed")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                                ForEach(Array(s.vocabulary.enumerated()), id: \.offset) { _, t in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.term).fontWeight(.semibold).foregroundStyle(Color.accentColor)
                                        Text(t.definition).font(.callout)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .card(padding: 10)
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !s.formulas.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Formules", icon: "function")
                            ForEach(Array(s.formulas.enumerated()), id: \.offset) { _, f in
                                Text(f).font(.system(.body, design: .rounded).weight(.semibold)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.16)))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)))
                            }
                        }
                    }
                    if !s.tips.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Pièges et conseils", icon: "lightbulb")
                            ForEach(Array(s.tips.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "lightbulb.fill").font(.caption).foregroundStyle(.yellow).accessibilityHidden(true)
                                    Text(item).textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).card()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Envie d'une autre version ?").font(.headline)
                        InstructionField(model: model, target: .summary)
                        HStack {
                            Button("Refaire la fiche") { model.makeSummary() }.disabled(!model.canStart)
                            EstimateNote(model: model)
                        }
                    }
                } else {
                    HeroCard(icon: "doc.text", title: "Fiche de synthèse",
                             text: "L'app résume ton cours : l'essentiel, le vocabulaire, les formules et des conseils pour retenir.")
                    InstructionField(model: model, target: .summary)
                    HStack(spacing: 12) {
                        Button("Créer la fiche") { model.makeSummary() }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canStart)
                        EstimateNote(model: model)
                    }
                    if model.isBusy { SkeletonCard(lines: 5); SkeletonCard(lines: 3) }
                }
            }
            .padding(20).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String
    var body: some View {
        Label(title, systemImage: icon).font(.headline).foregroundStyle(Color.accentColor)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Verdicts (icône ET texte)

extension Verdict {
    var title: String { switch self { case .juste: return "Juste"; case .partiel: return "Partiel"; case .faux: return "Faux" } }
    var icon: String {
        switch self { case .juste: return "checkmark.circle.fill"; case .partiel: return "circle.lefthalf.filled"; case .faux: return "xmark.circle.fill" }
    }
    var color: Color { switch self { case .juste: return .green; case .partiel: return .orange; case .faux: return .red } }
}

struct VerdictBadge: View {
    let verdict: Verdict
    var body: some View {
        Label(verdict.title, systemImage: verdict.icon)
            .font(.headline).foregroundStyle(verdict.color)
            .accessibilityLabel("Résultat : \(verdict.title)")
    }
}

// MARK: - Entraînement

struct QuizTab: View {
    @ObservedObject var model: RevisionModel
    var body: some View {
        if model.questions.isEmpty {
            setup
        } else if model.showingResults {
            QuizResults(model: model)
        } else if let q = model.current {
            QuestionView(model: model, question: q)
        }
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HeroCard(icon: "checklist", title: "Entraînement",
                         text: "L'app te pose des questions sur ton cours et corrige tes réponses une par une.")
                VStack(alignment: .leading, spacing: 12) {
                    Stepper(value: $model.quizOptions.count, in: 3...20) {
                        Text("Nombre de questions : \(model.quizOptions.count)").font(.headline)
                    }
                    .accessibilityValue("\(model.quizOptions.count)")
                    Text("Types de questions").font(.headline)
                    FlowLayout(spacing: 8) {
                        ForEach(QuestionStyle.allCases) { style in
                            Chip(label: style.label, selected: model.quizOptions.styles.contains(style)) { model.toggleStyle(style) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).card()
                InstructionField(model: model, target: .quiz)
                HStack(spacing: 12) {
                    Button("Générer les questions") { model.makeQuiz() }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canStart)
                    EstimateNote(model: model)
                }
                if model.isBusy { SkeletonCard(lines: 3); SkeletonCard(lines: 3) }
            }
            .padding(20).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

struct QuestionView: View {
    @ObservedObject var model: RevisionModel
    let question: RevisionQuestion

    var body: some View {
        let result = model.graded[question.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Question \(model.currentIndex + 1) sur \(model.questions.count)")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if model.round > 1 { Text("· série \(model.round)").font(.subheadline).foregroundStyle(.secondary) }
                    Spacer()
                    Tag(text: question.style.label, color: .accentColor)
                }
                ProgressView(value: Double(model.currentIndex + 1), total: Double(model.questions.count)).accessibilityHidden(true)
                Text(question.question).font(.title3.weight(.semibold)).textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading).card(padding: 16)
                answerArea(result)
                if let r = result { feedback(r) }
                buttons(result)
            }
            .padding(20).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func answerArea(_ result: GradedAnswer?) -> some View {
        if !question.choices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(question.choices, id: \.self) { choice in
                    let selected = RevisionModel.normalized(model.answer(for: question)) == RevisionModel.normalized(choice)
                    Button { model.setAnswer(choice, for: question) } label: {
                        HStack {
                            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            Text(choice).multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(selected: selected, padding: 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(result != nil)
                    .accessibilityLabel(choice)
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                }
            }
        } else {
            TextField("Écris ta réponse", text: Binding(get: { model.answer(for: question) }, set: { model.setAnswer($0, for: question) }), axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .disabled(result != nil)
                .accessibilityLabel("Ta réponse")
        }
    }

    private func feedback(_ r: GradedAnswer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VerdictBadge(verdict: r.verdict)
            Text(r.feedback).textSelection(.enabled)
            if r.verdict != .juste {
                labeled("Bonne réponse : ", question.expected).textSelection(.enabled)
            }
            if !question.explanation.isEmpty {
                labeled("Explication : ", question.explanation).textSelection(.enabled)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(r.verdict.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(r.verdict.color.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }

    private func buttons(_ result: GradedAnswer?) -> some View {
        HStack {
            Button("Précédente") { model.previous() }.disabled(model.currentIndex == 0)
            Spacer()
            if result == nil {
                Button("Corriger") { model.gradeCurrent() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canGrade(question))
            } else if model.currentIndex + 1 < model.questions.count {
                Button("Question suivante") { model.next() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button("Voir mon score") { model.next() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!model.allGraded)
            }
        }
    }
}

struct QuizResults: View {
    @ObservedObject var model: RevisionModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ton score : \(model.scoreText)").font(.system(size: 26, weight: .bold, design: .rounded)).accessibilityAddTraits(.isHeader)
                    Text("Juste = 1 point, partiel = ½ point.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).card(selected: true, padding: 16)
                ForEach(model.questions) { q in
                    let g = model.graded[q.id]
                    HStack(alignment: .top, spacing: 10) {
                        if let g { VerdictBadge(verdict: g.verdict).frame(width: 90, alignment: .leading) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q.question).fontWeight(.medium)
                            if g?.verdict != .juste { Text("Bonne réponse : \(q.expected)").font(.callout).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    .card(padding: 10)
                    .accessibilityElement(children: .combine)
                    .onTapGesture { model.goTo(model.questions.firstIndex(of: q) ?? 0); model.backToQuestions() }
                }
                HStack {
                    Button("Refaire les questions ratées") { model.retryMissed() }
                        .buttonStyle(.borderedProminent).disabled(model.missedQuestions.isEmpty)
                    Button("Nouvelles questions") { model.newQuiz() }
                    Spacer()
                    Menu("Enregistrer en PDF…") {
                        Button("Sans les réponses") { model.exportQuizPDF(withAnswers: false) }
                        Button("Avec les réponses") { model.exportQuizPDF(withAnswers: true) }
                    }
                    .fixedSize()
                    .disabled(model.isBusy)
                }
            }
            .padding(20).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Après l'évaluation (évaluation DÉJÀ rendue et notée)

struct CorrigeTab: View {
    @ObservedObject var model: RevisionModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HeroCard(icon: "graduationcap", title: "Après l'évaluation", text: RevisionModel.corrigeWelcome)
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Cette évaluation m'a déjà été rendue et corrigée", isOn: $model.corrigeConfirmed)
                        .disabled(model.isBusy)
                    HStack {
                        Button(model.corrigeItems.isEmpty ? "Préparer mon corrigé" : "Refaire le corrigé") { model.makeCorrige() }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canMakeCorrige)
                        if !model.corrigeItems.isEmpty {
                            Button("Enregistrer le corrigé en PDF…") { model.saveCorrigePDF() }.disabled(model.isBusy)
                        }
                        EstimateNote(model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).card()
                if model.isBusy && model.corrigeItems.isEmpty { SkeletonCard(lines: 4); SkeletonCard(lines: 4) }
                ForEach(model.corrigeItems) { item in CorrigeCard(item: item) }
            }
            .padding(20).frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

struct CorrigeCard: View {
    let item: CorrigeItem
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Question \(item.number)").font(.headline)
                Text("· page \(item.page)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let s = item.status { VerdictBadge(verdict: s) }
            }
            Text(item.instruction).textSelection(.enabled)
            line("Ta réponse", item.studentAnswer.isEmpty ? "(vide ou illisible)" : item.studentAnswer)
            if !item.teacherRemark.isEmpty { line("Remarque du professeur", item.teacherRemark) }
            line("Bonne réponse", item.correctAnswer)
            line("Explication", item.explanation)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lightbulb.fill").foregroundStyle(.yellow).accessibilityHidden(true)
                labeled("À retenir : ", item.toRemember).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }

    private func line(_ label: String, _ value: String) -> some View {
        labeled("\(label) : ", value).textSelection(.enabled)
    }
}

/// Texte « Étiquette en gras » suivi de sa valeur.
func labeled(_ label: String, _ value: String) -> Text {
    Text("\(Text(label).fontWeight(.semibold))\(value)")
}
