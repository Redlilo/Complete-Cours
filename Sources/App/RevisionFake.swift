import Foundation

/// Service factice : données plausibles, délais courts, aucun réseau. Sert aux tests (Tools/Tests/RevisionApp)
/// et aux essais de l'interface.
final class FakeRevisionService: RevisionProviding {
    var delayNanos: UInt64 = 15_000_000
    /// Erreur renvoyée par le prochain appel (puis remise à nil).
    var failNext: Error?
    private(set) var calls: [String] = []
    private(set) var lastLoadWithImages: Bool?
    /// Dernière consigne reçue pour la fiche, dernier nombre de cartes demandé.
    private(set) var lastSummaryInstruction: String?
    private(set) var lastQuizInstruction: String?
    private(set) var lastCardCount: Int?

    private func step(_ name: String, _ progress: RevisionProgress?, _ label: String) async throws {
        calls.append(name)
        if let e = failNext { failNext = nil; throw e }
        for i in 1...3 {
            try await Task.sleep(nanoseconds: delayNanos)
            progress?(Double(i) / 3, label)
        }
    }

    func loadSource(url: URL, withImages: Bool, progress: @escaping RevisionProgress) async throws -> RevisionSource {
        lastLoadWithImages = withImages
        try await step("loadSource", progress, "Lecture des pages…")
        let pages = (0..<3).map { RevisionPage(index: $0, text: "Texte de la page \($0 + 1) sur la loi d'Ohm.", imageJPEG: nil) }
        return RevisionSource(url: url, documentName: url.deletingPathExtension().lastPathComponent, pages: pages)
    }

    func makeSummary(_ source: RevisionSource, instruction: String, progress: @escaping RevisionProgress) async throws -> RevisionSummary {
        lastSummaryInstruction = instruction
        try await step("makeSummary", progress, "Création de la fiche…")
        return RevisionSummary(
            title: "La loi d'Ohm",
            keyPoints: ["La tension aux bornes d'un conducteur est proportionnelle à l'intensité.", "La résistance s'exprime en ohms."],
            vocabulary: [RevisionTerm(term: "Résistance", definition: "Opposition d'un composant au passage du courant.")],
            formulas: ["U = R × I (tension en volts, résistance en ohms, intensité en ampères)"],
            tips: ["Toujours vérifier les unités avant de calculer."])
    }

    static let questions: [RevisionQuestion] = [
        RevisionQuestion(id: 1, style: .qcm, question: "Quelle est l'unité de la résistance ?", choices: ["Le volt", "L'ohm", "L'ampère"],
                         expected: "L'ohm", explanation: "La résistance se mesure en ohms (Ω).", page: 1),
        RevisionQuestion(id: 2, style: .vraiFaux, question: "L'intensité se mesure en volts.", choices: ["Vrai", "Faux"],
                         expected: "Faux", explanation: "L'intensité se mesure en ampères.", page: 1),
        RevisionQuestion(id: 3, style: .definition, question: "Définis la tension.", choices: [],
                         expected: "Différence de potentiel entre deux points, en volts.", explanation: "On la mesure avec un voltmètre en dérivation.", page: 2),
        RevisionQuestion(id: 4, style: .calcul, question: "Calcule U pour R = 10 Ω et I = 2 A.", choices: [],
                         expected: "U = 20 V", explanation: "U = R × I = 10 × 2 = 20 V.", page: 3),
    ]

    func makeQuiz(_ source: RevisionSource, options: QuizOptions, progress: @escaping RevisionProgress) async throws -> [RevisionQuestion] {
        lastQuizInstruction = options.instruction
        try await step("makeQuiz", progress, "Création des questions…")
        return Array(Self.questions.filter { options.styles.contains($0.style) }.prefix(options.count))
    }

    static let cards: [RevisionCard] = [
        RevisionCard(id: 1, front: "Unité de la résistance ?", back: "L'ohm (Ω).", page: 1),
        RevisionCard(id: 2, front: "Loi d'Ohm", back: "U = R × I (U en volts, R en ohms, I en ampères).", page: 2),
        RevisionCard(id: 3, front: "Quel appareil mesure la tension ?", back: "Le voltmètre, branché en dérivation.", page: 2),
        RevisionCard(id: 4, front: "Unité de l'intensité ?", back: "L'ampère (A).", page: 3),
        RevisionCard(id: 5, front: "Que mesure un ampèremètre ?", back: "L'intensité du courant, branché en série.", page: 3),
    ]

    func makeCards(_ source: RevisionSource, count: Int, progress: @escaping RevisionProgress) async throws -> [RevisionCard] {
        lastCardCount = count
        try await step("makeCards", progress, "Création des cartes…")
        return Array(Self.cards.prefix(count))
    }

    /// Juste si la réponse contient le premier mot de la bonne réponse, partielle si elle n'est pas vide mais fausse
    /// et contient « volt », faux sinon.
    func grade(_ answers: [(question: RevisionQuestion, answer: String)]) async throws -> [GradedAnswer] {
        try await step("grade", nil, "")
        return answers.map { pair in
            let key = pair.question.expected.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
            let given = pair.answer.lowercased()
            let verdict: Verdict = given.contains(key) ? .juste : (given.contains("volt") ? .partiel : .faux)
            return GradedAnswer(questionID: pair.question.id, verdict: verdict,
                                feedback: verdict == .juste ? "C'est bon." : "Il manque l'idée principale.",
                                expected: pair.question.expected)
        }
    }

    func makeCorrige(_ source: RevisionSource, progress: @escaping RevisionProgress) async throws -> [CorrigeItem] {
        try await step("makeCorrige", progress, "Préparation du corrigé…")
        return [
            CorrigeItem(id: 1, page: 1, number: "1", instruction: "Donne l'unité de la résistance.", studentAnswer: "le volt",
                        teacherRemark: "Non : c'est l'ohm.", correctAnswer: "L'ohm (Ω)",
                        explanation: "Le volt mesure la tension. La résistance se mesure en ohms.", toRemember: "R en ohms, U en volts, I en ampères.", status: .faux),
            CorrigeItem(id: 2, page: 2, number: "3.b", instruction: "Calcule I pour U = 12 V et R = 4 Ω.", studentAnswer: "I = 3 A",
                        teacherRemark: "", correctAnswer: "I = U / R = 3 A",
                        explanation: "On divise la tension par la résistance.", toRemember: "I = U / R", status: .juste),
        ]
    }
}

/// Exporteur factice : écrit un faux contenu reconnaissable.
struct FakeRevisionExporter: Sendable {
    var fail = false
    private func data(_ s: String) throws -> Data {
        if fail { throw CocoaError(.fileWriteUnknown) }
        return Data("%PDF-fake \(s)".utf8)
    }
}

extension FakeRevisionExporter: RevisionExporting {
    func summaryPDF(_ summary: RevisionSummary, documentName: String) throws -> Data { try data("summary \(documentName)") }
    func quizPDF(_ questions: [RevisionQuestion], documentName: String, withAnswers: Bool) throws -> Data {
        try data("quiz \(questions.count) \(withAnswers ? "avec" : "sans")")
    }
    func corrigePDF(_ items: [CorrigeItem], documentName: String) throws -> Data { try data("corrige \(items.count)") }
    func cardsPDF(_ cards: [RevisionCard], documentName: String) throws -> Data { try data("cartes \(cards.count)") }
}
