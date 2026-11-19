import SwiftUI
import UniformTypeIdentifiers

// Interface du mode « Révision » (fenêtre séparée). Pas de dépendance vers les autres vues de l'app.

struct RevisionRootView: View {
    @ObservedObject var model: RevisionModel
    @Environment(\.openSettings) private var openSettings
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let issue = model.issue { IssueBanner(issue: issue) { model.issue = nil } }
            if !model.engine.usable { engineBanner }
            if let activity = model.activity { ActivityBar(activity: activity) { model.cancel() } }
            if model.hasDocument {
                Picker("Partie", selection: $model.tab) {
                    ForEach(RevisionTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Partie de la révision")
                .padding(.horizontal, 20).padding(.vertical, 10)
                Divider()
                Group {
                    switch model.tab {
                    case .fiche: SummaryTab(model: model)
                    case .entrainement: QuizTab(model: model)
                    case .apres: CorrigeTab(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                dropArea
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
        .onAppear { model.refreshEngine() }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "graduationcap").font(.title2).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.hasDocument ? model.documentName : "Révision").font(.headline).lineLimit(1)
                Text(headerDetail).font(.caption).foregroundStyle(.secondary)
                if let e = model.estimate { Text(e).font(.caption2).foregroundStyle(.tertiary) }
            }
            Spacer()
            Button(model.hasDocument ? "Changer de PDF…" : "Ouvrir…") { model.chooseDocument() }
                .disabled(model.isBusy)
                .keyboardShortcut("o")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private var headerDetail: String {
        let engine = "Moteur : \(model.engine.name)"
        return model.hasDocument ? "\(Fr.pages(model.pageCount)) · \(engine)" : engine
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

    private var dropArea: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 52, weight: .light))
                .foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text("Révise un cours").font(.title.weight(.semibold))
            Text("Dépose ici un PDF de cours, ou une évaluation déjà rendue et corrigée. L'app te prépare une fiche, des questions d'entraînement et un corrigé expliqué. Ton PDF n'est jamais modifié.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            Button { model.chooseDocument() } label: { Label("Choisir un PDF…", systemImage: "folder").padding(.horizontal, 8) }
                .controlSize(.large).buttonStyle(.borderedProminent)
            Text("ou glisse-le sur cette fenêtre").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Bandeaux

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

struct ActivityBar: View {
    let activity: RevisionModel.Activity
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: activity.fraction).frame(maxWidth: 220)
                .accessibilityLabel("Progression")
                .accessibilityValue("\(Int(activity.fraction * 100)) pour cent")
            Text(activity.label).font(.callout).lineLimit(1)
            Spacer()
            Button("Annuler", action: cancel).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }
}

// MARK: - Fiche de synthèse

struct SummaryTab: View {
    @ObservedObject var model: RevisionModel
    var body: some View {
        if let s = model.summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(s.title).font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Refaire la fiche") { model.makeSummary() }.disabled(!model.canStart)
                        Button("Enregistrer en PDF…") { model.saveSummaryPDF() }.disabled(model.isBusy)
                    }
                    section("L'essentiel", icon: "list.bullet", items: s.keyPoints)
                    if !s.vocabulary.isEmpty {
                        SectionHeader(title: "Vocabulaire", icon: "character.book.closed")
                        ForEach(Array(s.vocabulary.enumerated()), id: \.offset) { _, t in
                            labeled(t.term + " : ", t.definition)
                                .textSelection(.enabled)
                                .accessibilityElement(children: .combine)
                        }
                    }
                    section("Formules", icon: "function", items: s.formulas)
                    section("Pièges et conseils", icon: "lightbulb", items: s.tips)
                }
                .padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            }
        } else {
            EmptyPrompt(icon: "doc.text", title: "Fiche de synthèse",
                        text: "L'app résume ton cours : l'essentiel, le vocabulaire, les formules et des conseils pour retenir.",
                        button: "Créer la fiche", enabled: model.canStart) { model.makeSummary() }
        }
    }

    @ViewBuilder private func section(_ title: String, icon: String, items: [String]) -> some View {
        if !items.isEmpty {
            SectionHeader(title: title, icon: icon)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").accessibilityHidden(true)
                    Text(item).textSelection(.enabled)
                }
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String
    var body: some View {
        Label(title, systemImage: icon).font(.headline).foregroundStyle(Color.accentColor)
            .padding(.top, 4).accessibilityAddTraits(.isHeader)
    }
}

struct EmptyPrompt: View {
    let icon: String, title: String, text: String, button: String
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button(button, action: action).buttonStyle(.borderedProminent).controlSize(.large).disabled(!enabled)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
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
            VStack(alignment: .leading, spacing: 16) {
                Text("Entraînement").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                Text("L'app te pose des questions sur ton cours et corrige tes réponses une par une.").foregroundStyle(.secondary)
                Stepper(value: $model.quizOptions.count, in: 3...20) {
                    Text("Nombre de questions : \(model.quizOptions.count)")
                }
                .accessibilityValue("\(model.quizOptions.count)")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Types de questions").font(.headline)
                    ForEach(QuestionStyle.allCases) { style in
                        Toggle(style.label, isOn: Binding(
                            get: { model.quizOptions.styles.contains(style) },
                            set: { _ in model.toggleStyle(style) }))
                    }
                }
                Button("Générer les questions") { model.makeQuiz() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canStart)
            }
            .padding(20).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

struct QuestionView: View {
    @ObservedObject var model: RevisionModel
    let question: RevisionQuestion

    var body: some View {
        let result = model.graded[question.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Question \(model.currentIndex + 1) sur \(model.questions.count)")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if model.round > 1 { Text("· série \(model.round)").font(.subheadline).foregroundStyle(.secondary) }
                    Spacer()
                    Text(question.style.label).font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                ProgressView(value: Double(model.currentIndex + 1), total: Double(model.questions.count)).accessibilityHidden(true)
                Text(question.question).font(.title3.weight(.semibold)).textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
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
                        .padding(10).contentShape(Rectangle())
                        .background(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
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
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(r.verdict.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
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
            VStack(alignment: .leading, spacing: 14) {
                Text("Ton score : \(model.scoreText)").font(.title.weight(.bold)).accessibilityAddTraits(.isHeader)
                Text("Juste = 1 point, partiel = ½ point.").font(.caption).foregroundStyle(.secondary)
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
                    .padding(8).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
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

// MARK: - Après l'évaluation

struct CorrigeTab: View {
    @ObservedObject var model: RevisionModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Après l'évaluation").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                Text(RevisionModel.corrigeWelcome).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Cette évaluation m'a déjà été rendue et corrigée", isOn: $model.corrigeConfirmed)
                    .disabled(model.isBusy)
                HStack {
                    Button(model.corrigeItems.isEmpty ? "Préparer mon corrigé" : "Refaire le corrigé") { model.makeCorrige() }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canMakeCorrige)
                    if !model.corrigeItems.isEmpty {
                        Button("Enregistrer le corrigé en PDF…") { model.saveCorrigePDF() }.disabled(model.isBusy)
                    }
                }
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
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
