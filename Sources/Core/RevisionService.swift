import Foundation
import PDFKit

// Mode « Révision » : lecture du document, fiche, questions, correction et corrigé, par un `StructuredGenerator`.
// Ce service n'écrit jamais dans le PDF d'origine.

// MARK: - Outils internes

/// Réponse de l'IA inutilisable (JSON invalide ou incomplet) : provoque une nouvelle tentative.
struct RevBadFormat: Error { var detail: String }

/// Progression qui ne recule jamais et reste entre 0 et 1.
final class RevMonotone: @unchecked Sendable {
    private let base: RevisionProgress
    private let lock = NSLock()
    private var last = 0.0
    init(_ base: @escaping RevisionProgress) { self.base = base }
    func callAsFunction(_ value: Double, _ message: String) {
        lock.lock()
        last = max(last, min(1, max(0, value)))
        let v = last
        lock.unlock()
        base(v, message)
    }
}

/// Lecture tolérante du JSON renvoyé par l'IA.
enum RevJSON {
    static func parse(_ raw: String) throws -> Any {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("```") {
            // barrières de code : on garde ce qui est entre la première et la dernière
            var lines = t.components(separatedBy: "\n")
            if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
                lines.removeSubrange(0...i)
                if let j = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
                    lines.removeSubrange(j...)
                }
                t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        func decode(_ s: String) -> Any? {
            guard let d = s.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: d, options: [])
        }
        if let v = decode(t), v is [String: Any] || v is [Any] { return v }
        if let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a < b,
           let v = decode(String(t[a...b])) as? [String: Any] { return v }
        if let a = t.firstIndex(of: "["), let b = t.lastIndex(of: "]"), a < b,
           let v = decode(String(t[a...b])) as? [Any] { return v }
        throw RevBadFormat(detail: "JSON illisible")
    }

    static func str(_ v: Any?) -> String {
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }
    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
    static func strings(_ v: Any?) -> [String] {
        ((v as? [Any]) ?? []).map { str($0) }.filter { !$0.isEmpty }
    }
    static func dicts(_ v: Any?) -> [[String: Any]] {
        ((v as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
    }
    /// Liste située sous `key` dans un objet, ou le tableau racine lui-même.
    static func list(_ root: Any, _ key: String) -> [[String: Any]] {
        if let d = root as? [String: Any] { return dicts(d[key]) }
        return dicts(root)
    }
}

// MARK: - Service

final class RevisionService: RevisionProviding, @unchecked Sendable {
    private let generator: StructuredGenerator
    /// Mélange l'ordre des choix d'un QCM (les IA placent souvent le bon choix au même endroit).
    var shuffleChoices = true

    private let lock = NSLock()
    private var warnings: [String] = []
    /// Avertissements du dernier traitement (par exemple pages non traitées après une erreur sur un lot).
    var lastWarnings: [String] { lock.lock(); defer { lock.unlock() }; return warnings }

    init(generator: StructuredGenerator) { self.generator = generator }

    private func resetWarnings() { lock.lock(); warnings = []; lock.unlock() }
    private func addWarning(_ w: String) { lock.lock(); warnings.append(w); lock.unlock() }

    // MARK: - Lecture du document

    func loadSource(url: URL, withImages: Bool, progress: @escaping RevisionProgress) async throws -> RevisionSource {
        let p = RevMonotone(progress)
        try Task.checkCancellation()
        guard let doc = PDFDocument(url: url) else {
            throw CoursError.message("Impossible de lire ce fichier : il est abîmé ou ce n'est pas un PDF. Essaie d'ouvrir un autre fichier.")
        }
        if doc.isLocked && !doc.unlock(withPassword: "") {
            throw CoursError.message("Ce PDF est protégé par un mot de passe. Retire la protection, puis recommence.")
        }
        let n = doc.pageCount
        guard n > 0 else { throw CoursError.message("Ce PDF ne contient aucune page.") }
        p(0.0, "Je lis le document…")

        var pages: [RevisionPage] = []
        for i in 0..<n {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else {
                pages.append(RevisionPage(index: i, text: "", imageJPEG: nil))
                continue
            }
            let item: RevisionPage = autoreleasepool {
                var text = Self.cleanText(page.string ?? "")
                if Self.meaningfulCount(text) < 20 && !withImages {
                    // scan sans couche texte : reconnaissance du texte (OCR) en français
                    if let (img, geo) = PageImaging.render(page: page, longEdge: 2000) {
                        let ocr = OCR.layout(image: img, geometry: geo)
                        text = Self.cleanText(ocr.lines.map { $0.text }.joined(separator: "\n"))
                    }
                }
                let jpeg = withImages ? Self.jpegUnderLimit(page) : nil
                return RevisionPage(index: i, text: text, imageJPEG: jpeg)
            }
            pages.append(item)
            p(Double(i + 1) / Double(n), "Lecture de la page \(i + 1) sur \(n)…")
        }
        let name = url.deletingPathExtension().lastPathComponent
        return RevisionSource(url: url, documentName: name, pages: pages)
    }

    static func cleanText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func meaningfulCount(_ s: String) -> Int {
        s.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
    }

    /// Rendu JPEG d'une page : côté long ≤ 1568 px, qualité environ 0,8, moins de 800 Ko.
    static func jpegUnderLimit(_ page: PDFPage) -> Data? {
        var edge: CGFloat = 1568
        for _ in 0..<4 {
            guard let r = PageImaging.render(page: page, longEdge: edge) else { return nil }
            for q in [0.8, 0.65, 0.5] as [CGFloat] {
                if let d = PageImaging.jpegData(r.0, quality: q), d.count < 800_000 { return d }
            }
            edge *= 0.8
        }
        return nil
    }

    // MARK: - Fiche de synthèse

    func makeSummary(_ source: RevisionSource, instruction: String, progress: @escaping RevisionProgress) async throws -> RevisionSummary {
        let p = RevMonotone(progress)
        resetWarnings()
        try ensureReadable(source)
        let batches = makeBatches(source.pages, maxCost: 24_000, maxPages: 12)
        p(0.02, "Je lis le cours…")

        if batches.count == 1 {
            p(0.1, "Je fabrique la fiche de synthèse…")
            let s = try await summarize(source, batches[0], part: nil, instruction: instruction)
            p(1, "Fiche terminée.")
            return Self.limited(s, fallbackTitle: source.documentName)
        }

        let partials = try await processBatches(batches, progress: p, from: 0.05, to: 0.8,
                                                message: { i, n, b in "Je résume les pages \(Self.range(b)) (lot \(i) sur \(n))…" }) { i, b in
            try await self.summarize(source, b, part: (i, batches.count), instruction: instruction)
        }
        p(0.85, "Je fusionne les fiches partielles…")
        let merged: RevisionSummary
        if partials.count == 1 {
            merged = partials[0]
        } else {
            merged = try await mergeOrFallback(source, partials, instruction: instruction)
        }
        p(1, "Fiche terminée.")
        return Self.limited(merged, fallbackTitle: source.documentName)
    }

    private func summarize(_ source: RevisionSource, _ pages: [RevisionPage], part: (Int, Int)?, instruction: String) async throws -> RevisionSummary {
        let (images, numbers) = imagePlan(pages, all: false)
        let user = RevisionPrompts.summaryUser(documentName: source.documentName, pages: pages, imageNumbers: numbers, part: part, instruction: instruction)
        return try await ask(system: RevisionPrompts.summarySystem, user: user, images: images,
                             schema: RevisionPrompts.summarySchema) { try Self.parseSummary($0, fallbackTitle: source.documentName) }
    }

    /// Fusion en un appel ; si l'appel échoue sans être fatal, fusion locale. Une erreur fatale ou une annulation remonte.
    private func mergeOrFallback(_ source: RevisionSource, _ partials: [RevisionSummary], instruction: String) async throws -> RevisionSummary {
        let enc = JSONEncoder()
        let texts = partials.compactMap { (try? enc.encode($0)).flatMap { String(data: $0, encoding: .utf8) } }
        do {
            return try await ask(system: RevisionPrompts.mergeSystem,
                                 user: RevisionPrompts.mergeUser(documentName: source.documentName, partials: texts, instruction: instruction),
                                 images: [], schema: RevisionPrompts.summarySchema) { try Self.parseSummary($0, fallbackTitle: source.documentName) }
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            if Self.isFatal(error) { throw error }
            // Fusion impossible : on colle les fiches partielles (sans doublons).
            return Self.mergeLocally(partials, title: source.documentName)
        }
    }

    static func parseSummary(_ root: Any, fallbackTitle: String) throws -> RevisionSummary {
        guard let d = root as? [String: Any] else { throw RevBadFormat(detail: "objet attendu") }
        let vocab = RevJSON.dicts(d["vocabulaire"]).compactMap { e -> RevisionTerm? in
            let t = RevJSON.str(e["terme"]), def = RevJSON.str(e["definition"])
            return t.isEmpty ? nil : RevisionTerm(term: t, definition: def)
        }
        let s = RevisionSummary(title: RevJSON.str(d["titre"]).isEmpty ? fallbackTitle : RevJSON.str(d["titre"]),
                                keyPoints: RevJSON.strings(d["points"]), vocabulary: vocab,
                                formulas: RevJSON.strings(d["formules"]), tips: RevJSON.strings(d["conseils"]))
        if s.keyPoints.isEmpty && s.vocabulary.isEmpty && s.formulas.isEmpty { throw RevBadFormat(detail: "fiche vide") }
        return s
    }

    static func mergeLocally(_ parts: [RevisionSummary], title: String) -> RevisionSummary {
        func uniq<T>(_ items: [T], key: (T) -> String) -> [T] {
            var seen = Set<String>(), out: [T] = []
            for it in items where seen.insert(normalize(key(it))).inserted { out.append(it) }
            return out
        }
        return RevisionSummary(
            title: parts.first?.title ?? title,
            keyPoints: uniq(parts.flatMap { $0.keyPoints }) { $0 },
            vocabulary: uniq(parts.flatMap { $0.vocabulary }) { $0.term },
            formulas: uniq(parts.flatMap { $0.formulas }) { $0 },
            tips: uniq(parts.flatMap { $0.tips }) { $0 })
    }

    /// Respecte les limites de la fiche : 12 points, 15 mots, 10 formules, 6 conseils.
    static func limited(_ s: RevisionSummary, fallbackTitle: String) -> RevisionSummary {
        RevisionSummary(title: s.title.isEmpty ? fallbackTitle : s.title,
                        keyPoints: Array(s.keyPoints.prefix(12)), vocabulary: Array(s.vocabulary.prefix(15)),
                        formulas: Array(s.formulas.prefix(10)), tips: Array(s.tips.prefix(6)))
    }

    // MARK: - Questions d'entraînement

    func makeQuiz(_ source: RevisionSource, options: QuizOptions, progress: @escaping RevisionProgress) async throws -> [RevisionQuestion] {
        let p = RevMonotone(progress)
        resetWarnings()
        try ensureReadable(source)
        let count = max(1, options.count)
        let styles = QuestionStyle.allCases.filter { options.styles.contains($0) }
        let usable = styles.isEmpty ? [QuestionStyle.qcm] : styles
        // suite de styles répartis à tour de rôle, puis découpée entre les lots
        let sequence = (0..<count).map { usable[$0 % usable.count] }

        let batchesAll = makeBatches(source.pages, maxCost: 24_000, maxPages: 12)
        // pas plus de lots que de questions
        let merged = batchesAll.count > count ? regroup(batchesAll, into: count) : batchesAll
        p(0.02, "Je prépare les questions…")

        let results = try await processBatches(merged, progress: p, from: 0.05, to: 0.97,
                                               message: { i, n, b in
            n == 1 ? "Je fabrique les questions…" : "Je fabrique les questions des pages \(Self.range(b)) (lot \(i) sur \(n))…"
        }) { i, b in
            // la part de ce lot : les questions d'indice i-1, i-1+n, …
            let n = merged.count
            let mine = stride(from: i - 1, to: count, by: n).map { sequence[$0] }
            let plan = usable.map { st in (st, mine.filter { $0 == st }.count) }.filter { $0.1 > 0 }
            return try await self.quizBatch(source, b, plan: plan, wanted: mine.count, instruction: options.instruction)
        }

        var all = results.flatMap { $0 }
        if all.count > count { all = Array(all.prefix(count)) }
        guard !all.isEmpty else {
            throw EngineError.invalidResponse("L'IA n'a pas pu fabriquer de questions exploitables avec ce document. Réessaie, ou choisis d'autres styles de questions.")
        }
        for i in all.indices { all[i].id = i + 1 }
        p(1, "Questions prêtes.")
        return all
    }

    private func regroup(_ batches: [[RevisionPage]], into n: Int) -> [[RevisionPage]] {
        let pages = batches.flatMap { $0 }
        let size = Int((Double(pages.count) / Double(n)).rounded(.up))
        return stride(from: 0, to: pages.count, by: max(1, size)).map { Array(pages[$0..<min(pages.count, $0 + size)]) }
    }

    private func quizBatch(_ source: RevisionSource, _ pages: [RevisionPage], plan: [(QuestionStyle, Int)], wanted: Int, instruction: String) async throws -> [RevisionQuestion] {
        let (images, numbers) = imagePlan(pages, all: false)
        let user = RevisionPrompts.quizUser(documentName: source.documentName, pages: pages, imageNumbers: numbers, plan: plan, instruction: instruction)
        let pageCount = source.pageCount
        let shuffle = shuffleChoices
        return try await ask(system: RevisionPrompts.quizSystem, user: user, images: images,
                             schema: RevisionPrompts.quizSchema) { root in
            let qs = RevJSON.list(root, "questions").compactMap { Self.parseQuestion($0, pageCount: pageCount, shuffle: shuffle) }
            if qs.isEmpty { throw RevBadFormat(detail: "aucune question valide") }
            return Array(qs.prefix(wanted))
        }
    }

    static func styleFrom(_ s: String) -> QuestionStyle? {
        let k = normalize(s).replacingOccurrences(of: " ", with: "")
        switch k {
        case "qcm": return .qcm
        case "vraifaux", "vraioufaux": return .vraiFaux
        case "courte", "reponsecourte": return .courte
        case "definition": return .definition
        case "calcul": return .calcul
        default: return nil
        }
    }

    /// Valide et normalise une question ; nil si elle est inutilisable (par exemple QCM sans bon choix identifiable).
    static func parseQuestion(_ d: [String: Any], pageCount: Int, shuffle: Bool) -> RevisionQuestion? {
        guard let style = styleFrom(RevJSON.str(d["style"])) else { return nil }
        let question = RevJSON.str(d["question"])
        guard !question.isEmpty else { return nil }
        let explanation = RevJSON.str(d["explication"])
        let pg = RevJSON.int(d["page"]).flatMap { $0 >= 1 && $0 <= pageCount ? $0 : nil }
        var expected = RevJSON.str(d["reponse"])
        var choices: [String] = []

        switch style {
        case .qcm:
            var seen = Set<String>()
            choices = RevJSON.strings(d["choix"]).map(stripChoiceLetter).filter { seen.insert(normalize($0)).inserted }
            guard choices.count >= 3, let idx = matchChoice(expected, choices) else { return nil }
            var good = choices[idx]
            if choices.count > 4 {
                var others = choices.enumerated().filter { $0.offset != idx }.map { $0.element }
                others = Array(others.prefix(3))
                choices = others + [good]
                if shuffle { choices.shuffle() }
            } else if shuffle {
                choices.shuffle()
            }
            good = choices.first(where: { normalize($0) == normalize(good) }) ?? good
            expected = good
        case .vraiFaux:
            guard let tf = trueFalse(expected) else { return nil }
            choices = ["Vrai", "Faux"]
            expected = tf ? "Vrai" : "Faux"
        case .courte, .definition, .calcul:
            guard !expected.isEmpty else { return nil }
        }
        return RevisionQuestion(id: 0, style: style, question: question, choices: choices,
                                expected: expected, explanation: explanation, page: pg)
    }

    // MARK: - Cartes mémoire

    func makeCards(_ source: RevisionSource, count requested: Int, progress: @escaping RevisionProgress) async throws -> [RevisionCard] {
        let p = RevMonotone(progress)
        resetWarnings()
        try ensureReadable(source)
        let count = min(CardLimits.range.upperBound, max(CardLimits.range.lowerBound, requested))
        let batchesAll = makeBatches(source.pages, maxCost: 24_000, maxPages: 12)
        // pas plus de lots que de cartes demandées
        let batches = batchesAll.count > count ? regroup(batchesAll, into: count) : batchesAll
        let n = batches.count
        // part de chaque lot : le reste est réparti sur les premiers lots
        let shares = (0..<n).map { count / n + ($0 < count % n ? 1 : 0) }
        p(0.02, "Je prépare les cartes…")

        let results = try await processBatches(batches, progress: p, from: 0.05, to: 0.97,
                                               message: { i, n, b in
            n == 1 ? "Je fabrique les cartes…" : "Je fabrique les cartes des pages \(Self.range(b)) (lot \(i) sur \(n))…"
        }) { i, b in
            try await self.cardsBatch(source, b, wanted: shares[i - 1])
        }

        // sans doublons (même recto), dans l'ordre du cours, au plus `count`
        var seen = Set<String>(), all: [RevisionCard] = []
        for c in results.flatMap({ $0 }) where seen.insert(Self.normalize(c.front)).inserted { all.append(c) }
        if all.count > count { all = Array(all.prefix(count)) }
        guard !all.isEmpty else {
            throw EngineError.invalidResponse("L'IA n'a pas pu fabriquer de cartes exploitables avec ce document. Réessaie dans un instant.")
        }
        for i in all.indices { all[i].id = i + 1 }
        p(1, "Cartes prêtes.")
        return all
    }

    private func cardsBatch(_ source: RevisionSource, _ pages: [RevisionPage], wanted: Int) async throws -> [RevisionCard] {
        let (images, numbers) = imagePlan(pages, all: false)
        let user = RevisionPrompts.cardsUser(documentName: source.documentName, pages: pages, imageNumbers: numbers, wanted: wanted)
        let pageCount = source.pageCount
        return try await ask(system: RevisionPrompts.cardsSystem, user: user, images: images,
                             schema: RevisionPrompts.cardsSchema) { root in
            if let d = root as? [String: Any], d["cartes"] == nil { throw RevBadFormat(detail: "champ cartes absent") }
            let cards = RevJSON.list(root, "cartes").compactMap { Self.parseCard($0, pageCount: pageCount) }
            if cards.isEmpty { throw RevBadFormat(detail: "aucune carte valide") }
            return Array(cards.prefix(wanted))
        }
    }

    /// Valide une carte : recto et verso non vides (sinon nil) ; textes limités en longueur.
    static func parseCard(_ d: [String: Any], pageCount: Int) -> RevisionCard? {
        let front = String(RevJSON.str(d["recto"]).prefix(300)), back = String(RevJSON.str(d["verso"]).prefix(600))
        guard !front.isEmpty, !back.isEmpty, normalize(front) != normalize(back) else { return nil }
        let pg = RevJSON.int(d["page"]).flatMap { $0 >= 1 && $0 <= pageCount ? $0 : nil }
        return RevisionCard(id: 0, front: front, back: back, page: pg)
    }

    // MARK: - Correction des réponses de l'élève

    func grade(_ answers: [(question: RevisionQuestion, answer: String)]) async throws -> [GradedAnswer] {
        try Task.checkCancellation()
        var out = [GradedAnswer?](repeating: nil, count: answers.count)
        var open: [Int] = []   // indices à envoyer à l'IA

        for (i, a) in answers.enumerated() {
            let q = a.question
            let given = a.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if given.isEmpty {
                out[i] = GradedAnswer(questionID: q.id, verdict: .faux,
                                      feedback: "Tu n'as pas répondu. La bonne réponse est : \(q.expected)", expected: q.expected)
            } else if q.style == .qcm || q.style == .vraiFaux {
                out[i] = Self.gradeLocally(q, given)
            } else {
                open.append(i)
            }
        }

        let groups = stride(from: 0, to: open.count, by: 10).map { Array(open[$0..<min(open.count, $0 + 10)]) }
        for g in groups {
            try Task.checkCancellation()
            let items = g.enumerated().map { k, i in
                RevisionPrompts.GradeItem(number: k + 1, question: answers[i].question.question, expected: answers[i].question.expected,
                                          answer: answers[i].answer, style: answers[i].question.style)
            }
            let count = g.count
            let verdicts: [Int: (Verdict, String)] = try await ask(
                system: RevisionPrompts.gradeSystem, user: RevisionPrompts.gradeUser(items), images: [],
                schema: RevisionPrompts.gradeSchema) { root in
                var m: [Int: (Verdict, String)] = [:]
                for e in RevJSON.list(root, "resultats") {
                    guard let n = RevJSON.int(e["numero"]), n >= 1, n <= count, let v = Self.verdict(RevJSON.str(e["verdict"])) else { continue }
                    m[n] = (v, RevJSON.str(e["commentaire"]))
                }
                if m.count < count { throw RevBadFormat(detail: "verdicts manquants") }
                return m
            }
            for (k, i) in g.enumerated() {
                let q = answers[i].question
                let (v, f) = verdicts[k + 1]!
                let fb = f.isEmpty ? Self.defaultFeedback(v, expected: q.expected) : f
                out[i] = GradedAnswer(questionID: q.id, verdict: v, feedback: fb, expected: q.expected)
            }
        }
        return out.compactMap { $0 }
    }

    static func defaultFeedback(_ v: Verdict, expected: String) -> String {
        switch v {
        case .juste: return "Bravo, c'est une bonne réponse."
        case .partiel: return "Tu es sur la bonne voie, mais il manque quelque chose. La réponse attendue : \(expected)"
        case .faux: return "Ce n'est pas ça. La bonne réponse est : \(expected)"
        }
    }

    static func verdict(_ s: String) -> Verdict? {
        let n = normalize(s)
        if n.hasPrefix("part") { return .partiel }
        if n.hasPrefix("jus") || n.hasPrefix("corr") || n == "vrai" { return .juste }
        if n.hasPrefix("faux") || n.hasPrefix("inc") { return .faux }
        return nil
    }

    /// QCM et vrai/faux : correction sans IA.
    static func gradeLocally(_ q: RevisionQuestion, _ answer: String) -> GradedAnswer {
        var correct = false
        var recognised = true
        if q.style == .vraiFaux {
            let given = trueFalse(answer) ?? matchChoice(answer, q.choices).map { $0 == 0 }
            let want = trueFalse(q.expected) ?? true
            if let g = given { correct = (g == want) } else { recognised = false }
        } else {
            let want = matchChoice(q.expected, q.choices)
            if let g = matchChoice(answer, q.choices) {
                correct = (g == want)
            } else {
                // réponse recopiée avec d'autres mots autour : juste si elle contient le bon choix et aucun autre
                let a = " " + normalize(answer) + " "
                let hits = q.choices.indices.filter { !normalize(q.choices[$0]).isEmpty && a.contains(" " + normalize(q.choices[$0]) + " ") }
                if hits.count == 1 { correct = (hits[0] == want) } else { recognised = false }
            }
        }
        let tail = q.explanation.isEmpty ? "" : " " + q.explanation
        if correct {
            return GradedAnswer(questionID: q.id, verdict: .juste, feedback: "Bravo, c'est la bonne réponse." + tail, expected: q.expected)
        }
        let lead = recognised ? "Ce n'est pas la bonne réponse." : "Je n'ai pas reconnu ta réponse parmi les choix."
        return GradedAnswer(questionID: q.id, verdict: .faux, feedback: "\(lead) La bonne réponse est : \(q.expected)." + tail, expected: q.expected)
    }

    // MARK: - Corrigé d'une évaluation rendue

    func makeCorrige(_ source: RevisionSource, progress: @escaping RevisionProgress) async throws -> [CorrigeItem] {
        let p = RevMonotone(progress)
        resetWarnings()
        try ensureReadable(source)
        let perCall = generator.supportsImages && source.pages.contains(where: { $0.imageJPEG != nil }) ? 2 : 3
        let batches = stride(from: 0, to: source.pages.count, by: perCall).map { Array(source.pages[$0..<min(source.pages.count, $0 + perCall)]) }
        p(0.02, "Je lis la copie…")

        let results = try await processBatches(batches, progress: p, from: 0.05, to: 0.97,
                                               message: { i, n, b in "Je corrige les pages \(Self.range(b)) (lot \(i) sur \(n))…" }) { _, b in
            try await self.corrigeBatch(source, b)
        }
        var items = results.flatMap { $0 }
        guard !items.isEmpty else {
            throw EngineError.invalidResponse("Je n'ai trouvé aucune question dans ce document. Vérifie que c'est bien une évaluation déjà corrigée.")
        }
        for i in items.indices { items[i].id = i + 1 }
        p(1, "Corrigé terminé.")
        return items
    }

    private func corrigeBatch(_ source: RevisionSource, _ pages: [RevisionPage]) async throws -> [CorrigeItem] {
        let (images, numbers) = imagePlan(pages, all: true)
        let user = RevisionPrompts.corrigeUser(documentName: source.documentName, pages: pages, imageNumbers: numbers)
        let lo = (pages.first?.index ?? 0) + 1, hi = (pages.last?.index ?? 0) + 1
        return try await ask(system: RevisionPrompts.corrigeSystem, user: user, images: images,
                             schema: RevisionPrompts.corrigeSchema) { root in
            if let d = root as? [String: Any], d["questions"] == nil { throw RevBadFormat(detail: "champ questions absent") }
            return RevJSON.list(root, "questions").compactMap { Self.parseCorrigeItem($0, pageRange: lo...hi) }
        }
    }

    static func parseCorrigeItem(_ d: [String: Any], pageRange: ClosedRange<Int>) -> CorrigeItem? {
        let instruction = RevJSON.str(d["consigne"]), correct = RevJSON.str(d["bonne_reponse"])
        if instruction.isEmpty && correct.isEmpty { return nil }
        let page = min(max(RevJSON.int(d["page"]) ?? pageRange.lowerBound, pageRange.lowerBound), pageRange.upperBound)
        let status: Verdict?
        switch normalize(RevJSON.str(d["statut"])) {
        case "juste": status = .juste
        case "partiel": status = .partiel
        case "faux": status = .faux
        default: status = nil
        }
        return CorrigeItem(id: 0, page: page, number: RevJSON.str(d["numero"]), instruction: instruction,
                           studentAnswer: RevJSON.str(d["reponse_eleve"]), teacherRemark: RevJSON.str(d["remarque_prof"]),
                           correctAnswer: correct, explanation: RevJSON.str(d["explication"]),
                           toRemember: RevJSON.str(d["a_retenir"]), status: status)
    }

    // MARK: - Appel du moteur

    /// Un appel avec une nouvelle tentative si la réponse n'est pas exploitable. Annulation et erreurs fatales remontent.
    private func ask<T>(system: String, user: String, images: [Data], schema: [String: Any],
                        parse: (Any) throws -> T) async throws -> T {
        var lastDetail = ""
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let text = attempt == 0 ? user : user + "\n\n" + RevisionPrompts.retryReminder
            let raw: String
            do {
                raw = try await generator.generate(system: system, userText: text, images: images, schema: schema)
            } catch {
                if Self.isCancellation(error) { throw CancellationError() }
                if let ee = error as? EngineError, case .invalidResponse = ee, attempt == 0 { lastDetail = "réponse invalide"; continue }
                throw error
            }
            try Task.checkCancellation()
            do {
                return try parse(try RevJSON.parse(raw))
            } catch let e as RevBadFormat {
                lastDetail = e.detail
            }
        }
        throw EngineError.invalidResponse("L'IA n'a pas renvoyé une réponse exploitable (\(lastDetail)). Réessaie dans un instant.")
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let u = error as? URLError, u.code == .cancelled { return true }
        return false
    }

    /// Erreur qui arrête tout : clé refusée, crédit épuisé, moteur indisponible, limite atteinte.
    static func isFatal(_ error: Error) -> Bool {
        guard let e = error as? EngineError else { return false }
        if e.isFatal { return true }
        if case .rateLimited = e { return true }
        return false
    }

    /// Traite les lots l'un après l'autre. Une erreur ponctuelle sur un lot est notée (avertissement) sans effacer les autres ;
    /// une erreur fatale ou une annulation interrompt tout. Si tous les lots échouent, l'erreur est levée.
    private func processBatches<R>(_ batches: [[RevisionPage]], progress p: RevMonotone, from: Double, to: Double,
                                   message: (Int, Int, [RevisionPage]) -> String,
                                   work: (Int, [RevisionPage]) async throws -> R) async throws -> [R] {
        var results: [R] = []
        var failed: [[RevisionPage]] = []
        var firstError: Error?
        let n = batches.count
        for (k, b) in batches.enumerated() {
            try Task.checkCancellation()
            p(from + (to - from) * Double(k) / Double(n), message(k + 1, n, b))
            do {
                results.append(try await work(k + 1, b))
            } catch {
                if Self.isCancellation(error) { throw CancellationError() }
                if Self.isFatal(error) { throw error }
                failed.append(b)
                if firstError == nil { firstError = error }
            }
        }
        if results.isEmpty, let e = firstError {
            if n == 1 { throw e }
            throw CoursError.message("Aucun lot de pages n'a pu être traité (pages \(Self.range(batches.flatMap { $0 }))). \(e.localizedDescription)")
        }
        if !failed.isEmpty {
            let list = Self.range(failed.flatMap { $0 })
            addWarning("Pages non traitées : \(list). Le reste du résultat est complet ; tu peux recommencer pour les pages manquantes.")
            p(to, "Terminé, mais les pages \(list) n'ont pas pu être traitées.")
        }
        return results
    }

    // MARK: - Aides

    private func ensureReadable(_ source: RevisionSource) throws {
        guard !source.pages.isEmpty else { throw CoursError.message("Ce PDF ne contient aucune page.") }
        let ok = source.pages.contains { Self.meaningfulCount($0.text) > 0 || ($0.imageJPEG != nil && generator.supportsImages) }
        if !ok {
            throw CoursError.message("Ce document ne contient aucun texte lisible. S'il s'agit d'un scan, utilise un moteur qui sait lire les images.")
        }
    }

    /// Images à joindre : les pages sans texte (ou toutes) dont le rendu existe, si le moteur lit les images.
    private func imagePlan(_ pages: [RevisionPage], all: Bool) -> ([Data], [Int: Int]) {
        guard generator.supportsImages else { return ([], [:]) }
        var images: [Data] = [], numbers: [Int: Int] = [:]
        for p in pages {
            guard let img = p.imageJPEG, all || Self.meaningfulCount(p.text) < 40 else { continue }
            images.append(img)
            numbers[p.index] = images.count
        }
        return (images, numbers)
    }

    /// Découpe en lots de pages consécutives : coût en caractères (une page-image compte 4 000) et nombre de pages bornés.
    private func makeBatches(_ pages: [RevisionPage], maxCost: Int, maxPages: Int) -> [[RevisionPage]] {
        var out: [[RevisionPage]] = [], cur: [RevisionPage] = [], cost = 0
        for p in pages {
            let c = min(RevisionPrompts.maxCharsPerPage, p.text.count) + (generator.supportsImages && p.imageJPEG != nil && Self.meaningfulCount(p.text) < 40 ? 4_000 : 0)
            if !cur.isEmpty && (cost + c > maxCost || cur.count >= maxPages) {
                out.append(cur); cur = []; cost = 0
            }
            cur.append(p); cost += c
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// « 3 à 5, 8 » pour des pages d'un lot (numérotées à partir de 1).
    static func range(_ pages: [RevisionPage]) -> String {
        let nums = pages.map { $0.index + 1 }.sorted()
        var parts: [String] = [], i = 0
        while i < nums.count {
            var j = i
            while j + 1 < nums.count && nums[j + 1] == nums[j] + 1 { j += 1 }
            parts.append(i == j ? "\(nums[i])" : (j == i + 1 ? "\(nums[i]) et \(nums[j])" : "\(nums[i]) à \(nums[j])"))
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Comparaison de réponses

    /// Minuscules, sans accents, sans ponctuation, espaces simples.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_FR"))
        var out = ""
        for u in folded.unicodeScalars {
            out.unicodeScalars.append(CharacterSet.alphanumerics.contains(u) ? u : " ")
        }
        return out.split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    /// Retire « A) », « B. » ou « c - » au début d'un choix.
    static func stripChoiceLetter(_ s: String) -> String {
        let r = s.replacingOccurrences(of: "^\\s*\\(?[A-Da-d][\\)\\.:]\\s+", with: "", options: .regularExpression)
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Indice du choix désigné par `answer` : lettre (« B », « b) », « réponse B ») ou texte du choix ; nil sinon.
    static func matchChoice(_ answer: String, _ choices: [String]) -> Int? {
        let n = normalize(answer)
        guard !n.isEmpty else { return nil }
        let normChoices = choices.map { normalize($0) }
        if let i = normChoices.firstIndex(of: n) { return i }
        let letters = ["a", "b", "c", "d", "e"]
        var token = n
        for pre in ["reponse ", "choix ", "la reponse ", "le choix "] where token.hasPrefix(pre) { token = String(token.dropFirst(pre.count)) }
        if letters.contains(token), let i = letters.firstIndex(of: token), i < choices.count { return i }
        // « B Ohm » ou « B. Ohm » : lettre suivie du texte du choix
        let parts = n.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, letters.contains(parts[0]), let i = normChoices.firstIndex(of: parts[1]) { return i }
        return nil
    }

    static func trueFalse(_ s: String) -> Bool? {
        switch normalize(s) {
        case "vrai", "v", "true", "vraie", "affirmation vraie": return true
        case "faux", "f", "false", "fausse", "affirmation fausse": return false
        default: return nil
        }
    }
}
