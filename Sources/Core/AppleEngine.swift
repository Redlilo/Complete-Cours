import Foundation
import FoundationModels
import AppKit

// Moteur Apple Intelligence : le modèle de langage local d'Apple (framework FoundationModels), texte seul.
// - une session neuve par requête : la fenêtre de contexte est petite (environ 4096 jetons, entrée + sortie) ;
// - réponses en texte libre (la macro @Generable n'est pas disponible sans Xcode) ;
// - échantillonnage « greedy » (température nulle) : mêmes entrées, mêmes réponses.
// Les signatures publiques de AppleEngine sont un contrat (voir Engine.swift) ; le reste est interne
// pour que les outils de test (Tools/Tests/Apple) puissent mesurer chaque étape.

final class AppleEngine: CompletionEngine {
    let displayName = "Apple Intelligence (sur le Mac)"
    let usesImages = false
    let maxConcurrentPages = 1

    init() {}

    // MARK: - Disponibilité

    /// nil si l'IA d'Apple est utilisable, sinon une explication en français (pas activée, Mac non compatible…).
    static func unavailabilityReason() -> String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            if !model.supportsLocale(Locale(identifier: "fr_FR")) {
                return "Apple Intelligence ne gère pas le français sur ce Mac. Dans Réglages Système > Apple Intelligence et Siri, choisis le français comme langue, ou utilise le moteur Claude."
            }
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "Ce Mac n'est pas compatible avec Apple Intelligence : il faut un Mac à puce Apple Silicon (M1 ou plus récent) sous macOS 26. Utilise plutôt le moteur Claude dans les réglages de l'application."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence n'est pas activé sur ce Mac. Ouvre Réglages Système > Apple Intelligence et Siri, active Apple Intelligence, attends la fin du téléchargement, puis recommence."
            case .modelNotReady:
                return "Le modèle d'Apple Intelligence n'est pas encore prêt : macOS est en train de le télécharger ou de l'installer. Garde le Mac connecté à Internet et branché, attends quelques minutes (l'avancement est visible dans Réglages Système > Apple Intelligence et Siri), puis recommence."
            @unknown default:
                return "Apple Intelligence n'est pas disponible sur ce Mac. Vérifie Réglages Système > Apple Intelligence et Siri, ou utilise le moteur Claude."
            }
        @unknown default:
            return "Apple Intelligence n'est pas disponible sur ce Mac. Vérifie Réglages Système > Apple Intelligence et Siri, ou utilise le moteur Claude."
        }
    }

    // MARK: - Complétion

    func complete(_ request: PageRequest) async throws -> [ZoneAnswer] {
        if let why = Self.unavailabilityReason() { throw EngineError.unavailable(why) }
        var out: [ZoneAnswer] = []
        for zone in request.zones {
            try Task.checkCancellation()
            do {
                if let a = try await answer(zone, in: request) { out.append(a) }
            } catch let e as EngineError where e.isFatal {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // erreur propre à cette zone : pas de réponse, la page continue
                if Task.isCancelled { throw CancellationError() }
            }
        }
        return out
    }

    /// Réponse pour une zone, ou nil si le modèle n'a rien pu écrire (la zone reste alors à remplir à la main).
    private func answer(_ zone: Zone, in request: PageRequest) async throws -> ZoneAnswer? {
        let input = AppleZoneInput(zone: zone, request: request)
        func reply(_ kind: ZoneKind, _ text: String) -> ZoneAnswer { ZoneAnswer(number: zone.number, kind: kind, text: text) }

        // 1. règles sans modèle : identité, date, zones à ne pas remplir, calculs, conversions
        if let r = AppleRules.field(before: zone.contextBefore, student: request.student, todayText: request.todayText) {
            switch r {
            case .text(let t): return reply(.mot, t)
            case .ignore: return reply(.ignorer, "")
            }
        }
        if AppleRules.isNotACourseAnswer(before: zone.contextBefore, after: zone.contextAfter) { return reply(.ignorer, "") }
        if zone.kind != .definition,
           let r = AppleMath.calculation(before: zone.contextBefore) ?? AppleMath.conversion(before: zone.contextBefore, after: zone.contextAfter) {
            return reply(.mot, r)
        }
        // 2. étiquette ou question : le modèle écarte les zones personnelles (stage, avis, signature…)
        if AppleText.endsLikeALabel(input.before), try await Self.isCourseAnswer(input) == false { return reply(.ignorer, "") }

        // 3. le modèle écrit la réponse
        switch zone.kind {
        case .ignorer, .schema:
            // une zone schéma n'est jamais envoyée à un moteur de texte (le pipeline l'exclut) : par prudence, rien n'est écrit
            return reply(.ignorer, "")
        case .mot:
            guard let w = try await Self.fillWord(input) else { return nil }
            return reply(.mot, w)
        case .definition, .question:
            guard let t = try await Self.writeAnswer(input, kind: zone.kind) else { return nil }
            return reply(zone.kind, t)
        }
    }

    // MARK: - Humanisation

    func humanize(_ items: [HumanizeItem]) async throws -> [Int: String] {
        if let why = Self.unavailabilityReason() { throw EngineError.unavailable(why) }
        var out: [Int: String] = [:]
        for item in items {
            try Task.checkCancellation()
            do {
                if let t = try await Self.rewrite(item) { out[item.id] = t }
            } catch let e as EngineError where e.isFatal {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
            }
        }
        return out
    }
}

// MARK: - Données d'entrée

/// Ce que le moteur sait d'une zone, nettoyé pour être mis dans un prompt court.
struct AppleZoneInput {
    var document: String
    var before: String
    var after: String
    var capacity: Int

    init(document: String, before: String, after: String, capacity: Int) {
        self.document = document
        self.before = AppleText.tidy(before)
        self.after = AppleText.tidy(after)
        self.capacity = capacity
    }

    init(zone: Zone, request: PageRequest) {
        self.init(document: request.documentName, before: zone.contextBefore, after: zone.contextAfter, capacity: zone.capacity)
    }
}

// MARK: - Appels au modèle

extension AppleEngine {
    /// Description d'une requête ; `level` croît quand le contexte est trop gros (0 = complet).
    struct PromptSpec {
        var instructions: String
        var shots: [(String, String)] = []
        var prompt: String
        var maxTokens: Int
        var temperature: Double? = nil
    }

    static let standardModel = SystemLanguageModel.default
    /// Garde-fous assouplis pour la transformation de texte : évite des faux positifs sur du vocabulaire de cours.
    static let permissiveModel = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    static func options(maxTokens: Int, temperature: Double? = nil) -> GenerationOptions {
        if let t = temperature {
            return GenerationOptions(sampling: .random(top: 40, seed: 7), temperature: t, maximumResponseTokens: maxTokens)
        }
        return GenerationOptions(sampling: .greedy, temperature: nil, maximumResponseTokens: maxTokens)
    }

    private static func transcript(instructions: String, shots: [(String, String)]) -> Transcript {
        var entries: [Transcript.Entry] = []
        entries.append(.instructions(Transcript.Instructions(segments: [.text(.init(content: instructions))], toolDefinitions: [])))
        for (q, a) in shots {
            entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: q))])))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: a))])))
        }
        return Transcript(entries: entries)
    }

    /// Une requête, une session neuve. Renvoie nil quand le modèle ne peut pas répondre à cette zone
    /// (garde-fou, langue non gérée…) ; lève une erreur seulement pour les cas fatals ou l'annulation.
    /// `spec(level)` fournit des versions de plus en plus courtes du prompt si le contexte est trop grand.
    static func ask(levels: Int = 3, _ spec: (Int) -> PromptSpec) async throws -> String? {
        var level = 0
        var permissive = false
        var rateRetries = 0
        while true {
            try Task.checkCancellation()
            let s = spec(level)
            let model = permissive ? permissiveModel : standardModel
            let session: LanguageModelSession
            if s.shots.isEmpty {
                session = LanguageModelSession(model: model, instructions: s.instructions)
            } else {
                session = LanguageModelSession(model: model, tools: [], transcript: transcript(instructions: s.instructions, shots: s.shots))
            }
            do {
                let r = try await session.respond(to: s.prompt, options: options(maxTokens: s.maxTokens, temperature: s.temperature))
                return r.content
            } catch let e as LanguageModelSession.GenerationError {
                switch e {
                case .exceededContextWindowSize:
                    if level >= levels { return nil }
                    level += 1
                case .guardrailViolation, .refusal:
                    if permissive { return nil }
                    permissive = true
                case .assetsUnavailable:
                    throw EngineError.unavailable("Le modèle d'Apple Intelligence n'est pas disponible pour le moment (il est peut-être en cours de téléchargement). Vérifie Réglages Système > Apple Intelligence et Siri, attends quelques minutes puis recommence.")
                case .rateLimited, .concurrentRequests:
                    rateRetries += 1
                    if rateRetries > 4 { throw EngineError.rateLimited("Apple Intelligence est trop sollicité en ce moment. Attends un moment puis recommence.") }
                    try await Task.sleep(nanoseconds: UInt64(rateRetries) * 1_000_000_000)
                case .unsupportedLanguageOrLocale, .unsupportedGuide, .decodingFailure:
                    return nil
                @unknown default:
                    return nil
                }
            } catch is CancellationError {
                throw CancellationError()
            }
        }
    }
}

// MARK: - Zone à remplir ou non

extension AppleEngine {
    static let gateInstructions = "Tu aides un élève de seconde professionnelle à remplir ses fiches de cours. On te montre le texte qui précède une zone vide de la fiche. Tu dis si l'élève doit y écrire une réponse de cours (OUI) ou non (NON). C'est NON pour : une signature, une note, l'appréciation du professeur, une information personnelle (entreprise de stage, avis personnel, objectif, ressenti), un titre ou un en-tête, un dessin ou un schéma à faire. Réponds seulement par OUI ou NON."

    private static func gatePrompt(_ before: String, _ after: String) -> String {
        "Texte avant la zone : « \(before) »\nTexte après la zone : « \(after.isEmpty ? "(rien)" : after) »\nL'élève doit-il écrire une réponse de cours dans cette zone ?"
    }

    private static let gateShots: [(String, String)] = [
        (gatePrompt("Le courant électrique est un déplacement de", "dans un conducteur."), "OUI"),
        (gatePrompt("Signature du professeur :", ""), "NON"),
        (gatePrompt("3. Pourquoi faut-il protéger ses données personnelles ?", ""), "OUI"),
        (gatePrompt("Dans quelle entreprise as-tu fait ton stage ? Raconte ta première semaine.", ""), "NON"),
        (gatePrompt("CHAPITRE 3 : LES RÉSEAUX", "I. Les réseaux locaux"), "NON"),
    ]

    /// true : l'élève doit écrire une réponse de cours ; false : zone à laisser vide ; nil : le modèle ne sait pas.
    /// À n'utiliser que pour un texte qui se termine comme une étiquette ou une question : au milieu d'une phrase
    /// à trous le petit modèle écarte trop souvent de vrais trous.
    static func isCourseAnswer(_ input: AppleZoneInput) async throws -> Bool? {
        let raw = try await ask(levels: 2) { level in
            let b = AppleText.tail(input.before, [260, 160, 80][min(level, 2)])
            let a = AppleText.head(input.after, [80, 50, 30][min(level, 2)])
            return PromptSpec(instructions: gateInstructions, shots: gateShots, prompt: gatePrompt(b, a), maxTokens: 4)
        }
        guard let raw else { return nil }
        let t = AppleText.fold(raw)
        if t.hasPrefix("oui") { return true }
        if t.hasPrefix("non") { return false }
        return nil
    }
}

// MARK: - Mots à compléter

extension AppleEngine {
    static let motInstructions = "Tu aides un élève de seconde professionnelle à compléter une fiche de cours à trous. Tu connais le programme du lycée professionnel. Réponds uniquement par le ou les mots qui manquent, accordés avec la phrase. Pas de phrase, pas d'explication."

    static let motShots: [(String, String)] = [
        ("Cours : « Les plantes »\nTexte : « Pour fabriquer leur matière, les plantes absorbent le [TROU] de l'air. »\nMot manquant :", "dioxyde de carbone"),
        ("Cours : « Grammaire »\nTexte : « Chaque matin, Léa [TROU] (prendre) le bus pour aller au lycée. »\nMot manquant :", "prend"),
        ("Cours : « Le temps »\nTexte : « Il y a [TROU] minutes dans une heure. »\nMot manquant :", "60"),
        ("Cours : « Informatique »\nTexte : « Le logiciel qui permet de consulter les sites web est un [TROU]. »\nMot manquant :", "navigateur"),
        ("Cours : « Les jardins »\nTexte : « Les fleurs du jardin sont très [TROU] (beau). »\nMot manquant :", "belles"),
    ]

    /// Variante « directe » : exemples puis « Mot manquant : ».
    static func motDirect(_ input: AppleZoneInput) async throws -> String? {
        let sizes = [(420, 200), (260, 120), (140, 60), (70, 30)]
        let raw = try await ask { level in
            let s = sizes[min(level, sizes.count - 1)]
            let text = AppleText.cloze(before: AppleText.tail(input.before, s.0), after: AppleText.head(input.after, s.1))
            return PromptSpec(instructions: motInstructions, shots: motShots,
                              prompt: "Cours : « \(input.document) »\nTexte : « \(text) »\nMot manquant :", maxTokens: 24)
        }
        guard let raw else { return nil }
        let w = AppleText.cleanWord(raw, before: input.before)
        return w.isEmpty ? nil : w
    }

    static let phraseInstructions = "Tu aides un élève de seconde professionnelle à compléter une fiche de cours à trous. Tu connais le programme du lycée professionnel. Tu recopies la phrase en entier en remplaçant [TROU] par le ou les mots exacts qui manquent. Tu ne changes rien d'autre."

    /// Variante « phrase » : le modèle recopie la phrase complétée, on en extrait le mot.
    static func motPhrase(_ input: AppleZoneInput) async throws -> String? {
        let (b, a) = AppleText.sentenceWindow(before: input.before, after: input.after)
        let raw = try await ask(levels: 1) { level in
            let text = AppleText.cloze(before: level == 0 ? b : AppleText.tail(b, 100), after: level == 0 ? a : AppleText.head(a, 50))
            return PromptSpec(instructions: phraseInstructions,
                              prompt: "Cours : « \(input.document) »\nPhrase : « \(text) »\nPhrase complète :", maxTokens: 120)
        }
        guard let raw, let w = AppleText.extractGap(from: raw, before: b, after: a) else { return nil }
        let c = AppleText.cleanWord(w, before: b)
        return c.isEmpty ? nil : c
    }

    static let explainInstructions = "Tu aides un élève de seconde professionnelle à compléter une fiche de cours à trous. Tu connais le programme du lycée professionnel. Tu écris d'abord une phrase d'explication, puis le mot manquant, accordé avec la phrase."

    private static func explainPrompt(_ doc: String, _ text: String) -> String {
        "Cours : « \(doc) »\nPhrase à compléter : « \(text) »\nÉtape 1 : en une phrase, explique de quoi parle cette phrase de cours.\nÉtape 2 : donne le ou les mots qui manquent à la place de [TROU], sous la forme « Mot : ... »."
    }

    private static let explainShots: [(String, String)] = [
        (explainPrompt("Les plantes", "Pour fabriquer leur matière, les plantes absorbent le [TROU] de l'air."),
         "La phrase explique quel gaz de l'air les plantes utilisent pour fabriquer leur matière.\nMot : dioxyde de carbone"),
        (explainPrompt("Grammaire", "Chaque matin, Léa [TROU] (prendre) le bus pour aller au lycée."),
         "La phrase décrit une habitude de Léa, donc le verbe est au présent avec Léa.\nMot : prend"),
    ]

    /// Variante « explication » : une phrase d'explication puis « Mot : … ».
    static func motExplain(_ input: AppleZoneInput) async throws -> String? {
        let (b, a) = AppleText.sentenceWindow(before: input.before, after: input.after)
        let raw = try await ask(levels: 1) { level in
            let text = AppleText.cloze(before: level == 0 ? b : AppleText.tail(b, 100), after: level == 0 ? a : AppleText.head(a, 50))
            return PromptSpec(instructions: explainInstructions, shots: explainShots, prompt: explainPrompt(input.document, text), maxTokens: 120)
        }
        guard let raw else { return nil }
        let c = AppleText.cleanWord(AppleText.afterMotLabel(raw), before: b)
        return c.isEmpty ? nil : c
    }

    /// Le ou les mots à écrire dans le trou ; nil si le modèle n'a rien proposé.
    /// Trois formulations différentes : si deux sont d'accord on garde leur réponse, sinon la troisième départage.
    static func fillWord(_ input: AppleZoneInput) async throws -> String? {
        let a = try await motDirect(input)
        let b = try await motPhrase(input)
        var chosen: String?
        if let a, let b, AppleText.fold(a) == AppleText.fold(b) {
            chosen = a
        } else {
            let c = try await motExplain(input)
            let votes = [a, b, c].compactMap { $0 }
            var best: (String, Int)?
            for v in votes {
                let n = votes.filter { AppleText.fold($0) == AppleText.fold(v) }.count
                if best == nil || n > best!.1 { best = (v, n) }
            }
            // sans majorité, la variante avec explication est la plus fiable seule
            chosen = (best?.1 ?? 0) >= 2 ? best?.0 : (c ?? a ?? b)
        }
        guard let word = chosen else { return nil }
        return await Spelling.correct(word, context: input.before + " " + input.after)
    }
}

// MARK: - Définitions et questions ouvertes

extension AppleEngine {
    static let redacInstructions = "Tu es professeur en lycée professionnel et tu rédiges le corrigé d'une fiche de cours pour un élève de seconde (filière MTNE : métiers des transitions numériques et énergétiques). Tu réponds à la dernière question ou consigne du texte, en français correct, avec des phrases simples et justes, de la longueur demandée. Tu écris seulement la réponse : pas de titre, pas de liste, pas de mise en forme, pas de formule d'introduction."

    private static func redacPrompt(_ doc: String, _ before: String, _ budget: String) -> String {
        "Cours : « \(doc) »\nTexte de la fiche juste avant la zone à remplir : « \(before) »\n\(budget)\nRéponse :"
    }

    private static let redacShots: [(String, String)] = [
        (redacPrompt("Sécurité sur un chantier", "2. Pourquoi porte-t-on un casque sur un chantier ?", "Réponds en une phrase courte (20 mots au maximum)."),
         "Pour protéger sa tête contre les chutes d'objets et les chocs."),
        (redacPrompt("Développement durable", "Définis le mot « recyclage ».", "Réponds en une ou deux phrases (35 mots au maximum)."),
         "Le recyclage consiste à réutiliser des matériaux déjà utilisés pour fabriquer de nouveaux objets. Cela permet de produire moins de déchets."),
    ]

    /// Consigne de longueur : environ 6 caractères par mot.
    static func budget(capacity: Int, kind: ZoneKind) -> String {
        let words = max(4, capacity / 6)
        if words <= 10 { return "Réponds en quelques mots (\(words) mots au maximum)." }
        if words <= 22 || (kind == .question && words <= 28) { return "Réponds en une phrase courte (\(words) mots au maximum)." }
        return kind == .definition ? "Réponds en une ou deux phrases (\(words) mots au maximum)."
                                   : "Réponds en une à trois phrases (\(words) mots au maximum)."
    }

    static func writeAnswer(_ input: AppleZoneInput, kind: ZoneKind) async throws -> String? {
        let sizes = [650, 420, 240, 120]
        let capacity = max(input.capacity, 20)
        let raw = try await ask { level in
            let before = AppleText.tail(input.before, sizes[min(level, sizes.count - 1)])
            return PromptSpec(instructions: redacInstructions, shots: redacShots,
                              prompt: redacPrompt(input.document, before, budget(capacity: capacity, kind: kind)),
                              maxTokens: min(max(capacity / 2 + 12, 30), 240))
        }
        guard var text = raw.map(AppleText.cleanSentence), !text.isEmpty else { return nil }
        // trop long pour la place disponible : on demande une version plus courte, sinon on coupe proprement
        if text.count > Int(Double(capacity) * 1.08) {
            let long = text
            let shorter = try await ask(levels: 0) { _ in
                PromptSpec(instructions: redacInstructions,
                           prompt: "Texte à raccourcir : « \(long) »\nRaccourcis ce texte pour qu'il fasse \(capacity) caractères au maximum, sans changer le sens ni les mots importants.\nTexte raccourci :",
                           maxTokens: min(max(capacity / 2 + 12, 30), 240))
            }
            if let s2 = shorter.map(AppleText.cleanSentence), !s2.isEmpty, s2.count < text.count { text = s2 }
        }
        text = AppleText.fit(text, capacity: capacity)
        return text.isEmpty ? nil : await Spelling.correct(text, context: input.before)
    }
}

// MARK: - Humanisation

extension AppleEngine {
    static func rewrite(_ item: HumanizeItem) async throws -> String? {
        let kind = item.kind == .definition ? "définition" : "question ouverte"
        let question = AppleText.tail(AppleText.tidy(item.question), 220)
        let prompt = "\(Prompts.toneInstruction(item.tone))\nType : \(kind)\nConsigne : « \(question) »\nRéponse à réécrire : « \(item.answer) »\nmax_caracteres : \(item.maxChars)\nRéponse réécrite :"
        let raw = try await ask(levels: 1) { _ in
            PromptSpec(instructions: Prompts.humanizeSystem, prompt: prompt, maxTokens: min(max(item.maxChars / 2 + 20, 40), 260))
        }
        guard let raw else { return nil }
        let t = AppleText.cleanSentence(raw)
        return HumanizeGuard.accept(original: item.answer, candidate: t, maxChars: item.maxChars)
    }
}

// MARK: - Texte

enum AppleText {
    /// Texte du document remis à plat pour un prompt : une seule ligne, les autres trous deviennent « … ».
    static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{00AD}", with: "")
        t = t.replacingOccurrences(of: "⟦[0-9]+⟧", with: "…", options: .regularExpression)
        t = t.replacingOccurrences(of: "(…\\s*){2,}", with: "… ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fin du texte (au plus `n` caractères), sans mot coupé au début.
    static func tail(_ s: String, _ n: Int) -> String {
        if s.count <= n { return s }
        var t = String(s.suffix(n))
        if let sp = t.firstIndex(of: " "), t.distance(from: t.startIndex, to: sp) < 14 { t = String(t[t.index(after: sp)...]) }
        return "… " + t
    }

    /// Début du texte (au plus `n` caractères), sans mot coupé à la fin.
    static func head(_ s: String, _ n: Int) -> String {
        if s.count <= n { return s }
        var t = String(s.prefix(n))
        if let sp = t.lastIndex(of: " "), t.distance(from: sp, to: t.endIndex) < 14 { t = String(t[..<sp]) }
        return t + " …"
    }

    /// Le texte avant la zone se termine comme une étiquette ou une question (« Signature : », « Pourquoi ? »),
    /// pas au milieu d'une phrase à trous.
    static func endsLikeALabel(_ before: String) -> Bool {
        let t = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let l = t.last else { return true }
        return ":?.…!_".contains(l)
    }

    /// Phrase à trou : le trou est marqué [TROU].
    static func cloze(before: String, after: String, marker: String = "[TROU]") -> String {
        var s = before.trimmingCharacters(in: .whitespacesAndNewlines)
        if let l = s.last, l == "'" || l == "’" { s += marker } else { s += s.isEmpty ? marker : " " + marker }
        let a = after.trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = a.first {
            s += ".,;:?!)".contains(f) ? a : " " + a
        }
        return s
    }

    /// Phrase qui contient le trou : début de la phrase dans `before`, fin de la phrase dans `after`.
    static func sentenceWindow(before: String, after: String) -> (String, String) {
        var b = before
        if let r = b.range(of: "[.?!…]\\s+(?=[A-ZÀÂÉÈÊÎÔÛÇ0-9«])", options: [.regularExpression, .backwards]) {
            b = String(b[r.upperBound...])
        }
        b = tail(b, 300)
        var a = after
        if let r = a.range(of: "[.?!]\\s", options: .regularExpression) {
            a = String(a[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        a = head(a, 140)
        return (b, a)
    }

    /// Texte entre la fin de `before` et le début de `after` dans une phrase recopiée par le modèle.
    static func extractGap(from sentence: String, before: String, after: String) -> String? {
        let text = stripFormatting(sentence)
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var start = text.startIndex
        let anchorB = before.replacingOccurrences(of: "… ", with: "").split(separator: " ").suffix(3).joined(separator: " ")
        if !anchorB.isEmpty {
            guard let r = text.range(of: anchorB, options: opts) else { return nil }
            start = r.upperBound
        }
        var end = text.endIndex
        let anchorA = after.replacingOccurrences(of: " …", with: "").split(separator: " ").prefix(3).joined(separator: " ")
        if !anchorA.isEmpty {
            guard let r = text.range(of: anchorA, options: opts, range: start..<text.endIndex) else { return nil }
            end = r.lowerBound
        }
        let gap = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
        // un trou fait quelques mots : au-delà, le modèle a réécrit la phrase
        return gap.split(separator: " ").count <= 6 ? gap : nil
    }

    /// Texte qui suit la dernière étiquette « Mot : » ; à défaut, la dernière ligne.
    static func afterMotLabel(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "**", with: "")
        if let r = flat.range(of: "Mot\\s*(manquant|s manquants)?\\s*:", options: [.regularExpression, .caseInsensitive, .backwards]) {
            return String(flat[r.upperBound...])
        }
        return flat.split(separator: "\n").last.map(String.init) ?? flat
    }

    static func stripFormatting(_ raw: String) -> String {
        var t = raw
        t = t.replacingOccurrences(of: "\\*\\*|__|`", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "^\\s*#+\\s*", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "⟦[0-9]+⟧", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [("\"", "\""), ("«", "»"), ("“", "”"), ("'", "'")]
        for (o, c) in pairs where t.count >= 2 && t.first == o && t.last == c {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    /// Mot(s) à écrire dans un trou : sans préfixe « Réponse : », sans ponctuation finale, sans article répété.
    static func cleanWord(_ raw: String, before: String) -> String {
        var t = stripFormatting(raw)
        t = t.replacingOccurrences(of: "^(?i)(réponse|mot manquant|mots manquants|mot|mots|le mot manquant est|les mots manquants sont)\\s*:?\\s*", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[?TROU\\]?", with: "", options: .regularExpression)
        t = stripFormatting(t)
        while let l = t.last, ".;,:!".contains(l) { t.removeLast() }
        let b = before.trimmingCharacters(in: .whitespaces).lowercased()
        for art in ["l'", "l’", "d'", "d’", "qu'", "qu’"] where b.hasSuffix(art) && t.lowercased().hasPrefix(art) {
            t = String(t.dropFirst(art.count))
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Réponse rédigée : une seule ligne, sans préfixe ni mise en forme.
    static func cleanSentence(_ raw: String) -> String {
        var t = stripFormatting(raw)
        t = t.replacingOccurrences(of: "^(?i)(réponse( attendue| réécrite)?|définition|corrigé|texte raccourci|voici[^:]{0,40})\\s*:\\s*", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "^[-•*]\\s+", with: "", options: .regularExpression)
        return stripFormatting(t)
    }

    /// Réduit un texte à `capacity` caractères en gardant des phrases entières quand c'est possible.
    static func fit(_ text: String, capacity: Int) -> String {
        let limit = Int(Double(capacity) * 1.08)
        if text.count <= limit { return text }
        var out = ""
        for sent in splitSentences(text) {
            let candidate = out.isEmpty ? sent : out + " " + sent
            if candidate.count > limit { break }
            out = candidate
        }
        if !out.isEmpty { return out }
        // une seule phrase trop longue : coupe à la dernière virgule ou au dernier mot qui tient
        var cut = String(text.prefix(limit))
        if let r = cut.range(of: "[,;:]\\s", options: [.regularExpression, .backwards]), cut.distance(from: cut.startIndex, to: r.lowerBound) > limit / 2 {
            cut = String(cut[..<r.lowerBound])
        } else if let sp = cut.lastIndex(of: " ") {
            cut = String(cut[..<sp])
        }
        let dangling: Set<String> = ["de", "du", "des", "la", "le", "les", "un", "une", "et", "ou", "à", "en", "que", "qui", "pour", "par",
                                     "dans", "sur", "avec", "d'", "l'", "au", "aux", "son", "sa", "ses", "leur", "leurs"]
        var words = cut.split(separator: " ").map(String.init)
        while let last = words.last, dangling.contains(last.lowercased()) { words.removeLast() }
        var result = words.joined(separator: " ")
        if let l = result.last, !".!?".contains(l) { result += "." }
        return result
    }

    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            current.append(c)
            if ".!?".contains(c), i + 1 >= chars.count || chars[i + 1] == " " {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                current = ""
            }
        }
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        return out
    }

    /// Minuscules sans accents ni ponctuation (comparaisons tolérantes).
    static func fold(_ s: String) -> String {
        let f = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_FR"))
        var out = ""
        var lastSpace = true
        for ch in f {
            if ch.isLetter || ch.isNumber { out.append(ch); lastSpace = false }
            else if !lastSpace { out.append(" "); lastSpace = true }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Orthographe

/// Corrige les fautes d'orthographe typiques du petit modèle (« amperomètre » → « ampèremètre »)
/// avec le correcteur de macOS, seulement quand la correction est évidente : un accent, ou une seule lettre.
@MainActor
enum Spelling {
    private static var cache: [String: String] = [:]

    /// `context` : texte du document ; un mot qui y figure tel quel n'est jamais « corrigé ».
    static func correct(_ text: String, context: String = "") -> String {
        guard let re = try? NSRegularExpression(pattern: "[\\p{L}]+(?:[’'-][\\p{L}]+)*") else { return text }
        let ns = text as NSString
        let known = context.lowercased()
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let w = ns.substring(with: m.range)
            guard !known.contains(w.lowercased()), let fixed = fix(w), fixed != w, let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: fixed)
        }
        return out
    }

    private static func fix(_ word: String) -> String? {
        if word.count < 6 || word == word.uppercased() { return nil }
        if let c = cache[word] { return c == word ? nil : c }
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        let bad = checker.checkSpelling(of: word, startingAt: 0, language: "fr", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        var result = word
        if bad.location != NSNotFound {
            let guesses = checker.guesses(forWordRange: range, in: word, language: "fr", inSpellDocumentWithTag: 0) ?? []
            let f = AppleText.fold(word)
            if let g = guesses.first(where: { AppleText.fold($0) == f && $0 != word }) {
                result = matchCase(g, like: word)
            } else if let g = guesses.first, !g.contains(" "), editDistance(AppleText.fold(g), f) <= 1 {
                result = matchCase(g, like: word)
            }
        }
        cache[word] = result
        return result == word ? nil : result
    }

    private static func matchCase(_ g: String, like w: String) -> String {
        if let f = w.first, f.isUppercase, let gf = g.first, gf.isLowercase { return g.prefix(1).uppercased() + g.dropFirst() }
        if let f = w.first, f.isLowercase, let gf = g.first, gf.isUppercase { return g.prefix(1).lowercased() + g.dropFirst() }
        return g
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}

// MARK: - Règles sans modèle (champs d'identité, dates, zones à ne pas remplir)

/// Ce que les règles savent écrire sans interroger le modèle.
enum AppleRuleResult: Equatable {
    case text(String)       // réponse exacte
    case ignore             // la zone ne doit pas être remplie (information personnelle, signature…)
}

enum AppleRules {
    /// Dernière ligne non vide du texte qui précède la zone.
    private static func lastLine(_ before: String) -> String {
        let cleaned = before.replacingOccurrences(of: "⟦[0-9]+⟧", with: " ", options: .regularExpression)
        let lines = cleaned.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.last ?? ""
    }

    /// Date du jour au format JJ/MM/AAAA, prise dans le texte de la requête (« mardi 17 novembre 2026 (17/11/2026) »).
    static func todayNumeric(_ todayText: String) -> String {
        if let r = todayText.range(of: "[0-9]{2}/[0-9]{2}/[0-9]{4}", options: .regularExpression) { return String(todayText[r]) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "dd/MM/yyyy"
        return f.string(from: Date())
    }

    /// Champs « Nom », « Prénom », « Classe », « Date » : rempli avec le profil, ou ignoré si le profil est vide.
    static func field(before: String, student: StudentProfile, todayText: String) -> AppleRuleResult? {
        var line = lastLine(before)
        let endsWithColon = line.hasSuffix(":") || line.hasSuffix("…") || line.hasSuffix(".") || line.hasSuffix("_")
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: " :.…_-–—"))
        guard !line.isEmpty, endsWithColon || line.count <= 40 else { return nil }
        let f = AppleText.fold(line)
        func has(_ pattern: String) -> Bool { f.range(of: pattern, options: .regularExpression) != nil }

        let nom = student.nom.trimmingCharacters(in: .whitespaces)
        let prenom = student.prenom.trimmingCharacters(in: .whitespaces)
        let classe = student.classe.trimmingCharacters(in: .whitespaces)

        if has("(^|\\s)(nom|prenom)( de famille| de l eleve| de l etudiant| de l apprenant| de naissance)? ?(et|,|/|-)? ?(prenom|nom)( de l eleve)?$")
            && !has("(entreprise|professeur|tuteur|enseignant|societe|fichier|lycee|etablissement|maitre|stage|famille d)") {
            let both = [prenom, nom].filter { !$0.isEmpty }.joined(separator: " ")
            return both.isEmpty ? .ignore : .text(both)
        }
        if has("(^|\\s)prenom( de l eleve| de l etudiant)?$") { return prenom.isEmpty ? .ignore : .text(prenom) }
        if has("(^|\\s)nom( de famille| de l eleve| de l etudiant| de l apprenant)?$") { return nom.isEmpty ? .ignore : .text(nom) }
        if has("(^|\\s)classe( de l eleve)?$") { return classe.isEmpty ? .ignore : .text(classe) }
        if has("(^|\\s)(date|date du jour|date de la seance|date d aujourd hui)$") || has("(^|\\s)fait (a|le)\\b.*(,| )le$") || f == "le" {
            return .text(todayNumeric(todayText))
        }
        if has("(entreprise|tuteur|maitre de stage|lieu de stage|etablissement d accueil|organisme d accueil|enseignant|professeur|prof|signature|visa|cachet|paraphe|appreciation|commentaire|observations? (du|de la|des))")
            && endsWithColon && f.count < 70 {
            return .ignore
        }
        return nil
    }

    /// Zones qu'un élève ne remplit pas avec une réponse de cours : signature, note, appréciation du professeur,
    /// information personnelle (stage), dessin ou schéma à faire. Liste volontairement courte et sûre :
    /// le modèle (isCourseAnswer) complète pour les formulations plus libres.
    static func isNotACourseAnswer(before: String, after: String) -> Bool {
        let line = AppleText.fold(lastLine(before))
        let next = String(after.prefix(30)).trimmingCharacters(in: .whitespaces).lowercased()
        func has(_ pattern: String, in s: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
        if has("(^| )(signature|visa|cachet|paraphe)s?( |$)", in: line) && line.count < 60 { return true }
        if has("(appreciation|observations?|commentaires?|remarques?|avis) (du|de la|des) (professeur|prof|enseignant|enseignants|formateur|tuteur|jury)", in: line) { return true }
        if has("^(note|resultat|total|points?)( obtenue?s?)?$", in: line) && has("^(/ ?[0-9]+|sur [0-9]+)", in: next) { return true }
        if has("(entreprise d accueil|nom de l entreprise|nom du tuteur|maitre de stage|lieu de stage|lieu de la pfmp|periode de formation)", in: line) { return true }
        if has("(dessine|dessinez|schematise|schematisez|colorie|coloriez|realise le schema|trace le|tracez le)", in: line) { return true }
        return false
    }
}

// MARK: - Calculs et conversions

enum AppleMath {
    // MARK: Évaluation d'une expression

    private struct Parser {
        var chars: [Character]
        var pos = 0
        init(_ s: String) { chars = Array(s.filter { $0 != " " && $0 != "\u{00A0}" && $0 != "\u{202F}" }) }

        func peek() -> Character? { pos < chars.count ? chars[pos] : nil }

        /// Le texte entier est un nombre (« 2 500 », « 0,25 »).
        func wholeNumber() -> Double? {
            var p = self
            guard let v = p.number(), p.pos == p.chars.count else { return nil }
            return v
        }
        mutating func number() -> Double? {
            var s = ""
            while let c = peek(), c.isNumber || c == "," || c == "." { s.append(c); pos += 1 }
            return s.isEmpty ? nil : Double(s.replacingOccurrences(of: ",", with: "."))
        }
        mutating func factor() -> Double? {
            if peek() == "(" {
                pos += 1
                guard let v = expression(), peek() == ")" else { return nil }
                pos += 1
                return v
            }
            if peek() == "-" || peek() == "−" { pos += 1; return factor().map { -$0 } }
            return number()
        }
        mutating func term() -> Double? {
            guard var v = factor() else { return nil }
            while let c = peek(), "×*÷/".contains(c) {
                pos += 1
                guard let r = factor() else { return nil }
                if c == "÷" || c == "/" { if r == 0 { return nil }; v /= r } else { v *= r }
            }
            return v
        }
        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), "+-−".contains(c) {
                pos += 1
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }
    }

    /// Nombre à la française : espace insécable pour les milliers, virgule décimale, deux décimales si le résultat n'est pas exact.
    static func format(_ v: Double) -> String? {
        guard v.isFinite, abs(v) < 1e15 else { return nil }
        var r = (v * 1e6).rounded() / 1e6
        if abs(r * 1000 - (r * 1000).rounded()) > 1e-6 { r = (v * 100).rounded() / 100 }
        var s = String(format: "%.6f", abs(r))
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        var intPart = String(parts[0])
        if intPart.count >= 4 {
            var grouped = ""
            for (i, ch) in intPart.reversed().enumerated() {
                if i > 0 && i % 3 == 0 { grouped.append("\u{00A0}") }
                grouped.append(ch)
            }
            intPart = String(grouped.reversed())
        }
        let out = parts.count > 1 ? intPart + "," + parts[1] : intPart
        return r < 0 ? "-" + out : out
    }

    private static let numberPattern = "[0-9]+(?:[ \u{00A0}\u{202F}][0-9]{3})*(?:[,.][0-9]+)?"

    /// Groupes capturés par une expression régulière.
    private static func captures(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }

    /// Texte avant le trou, sur une ligne, quand il se termine par « = ».
    private static func equationBody(_ before: String) -> String? {
        var t = before.replacingOccurrences(of: "⟦[0-9]+⟧", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix("=") else { return nil }
        return String(t.dropLast()).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Calcul écrit avant le trou

    /// « 100 × 0,2 = ▢ » → « 20 » ; « 25 % de 200 = ▢ » → « 50 ».
    static func calculation(before: String) -> String? {
        guard var body = equationBody(before) else { return nil }
        if let g = captures("(\(numberPattern))\\s*%\\s*de\\s*(\(numberPattern))$", in: body), g.count == 2,
           let p = Parser(g[0]).wholeNumber(), let n = Parser(g[1]).wholeNumber() {
            return format(p * n / 100)
        }
        body = body.replacingOccurrences(of: "(?<=[0-9)])\\s*x\\s*(?=[0-9(])", with: " × ", options: .regularExpression)
        let allowed = Set("0123456789 ,.+-−×*÷/()\u{00A0}\u{202F}")
        let chars = Array(body)
        var i = chars.count
        while i > 0 && allowed.contains(chars[i - 1]) { i -= 1 }
        let expr = String(chars[i...]).trimmingCharacters(in: .whitespaces)
        guard expr.contains(where: { "+−×*÷/".contains($0) }) || expr.dropFirst().contains("-") else { return nil }
        var p = Parser(expr)
        guard let v = p.expression(), p.pos == p.chars.count else { return nil }
        return format(v)
    }

    // MARK: Conversions d'unités

    private static let prefixes: [String: Double] = ["k": 1e3, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "m": 1e-3, "µ": 1e-6, "μ": 1e-6,
                                                     "c": 1e-2, "d": 1e-1, "h": 1e2, "da": 1e1]
    private static let bases = ["Wh", "Ω", "Hz", "W", "V", "A", "m", "g", "L", "l", "s", "J", "o", "B"]

    /// Grandeur (clé) et facteur vers l'unité de base ; nil si l'unité est inconnue.
    private static func parseUnit(_ u: String) -> (kind: String, factor: Double)? {
        switch u {
        case "min": return ("temps", 60)
        case "h": return ("temps", 3600)
        case "j": return ("temps", 86400)
        case "t": return ("g", 1e6)
        default: break
        }
        for b in bases.sorted(by: { $0.count > $1.count }) where u.hasSuffix(b) {
            let p = String(u.dropLast(b.count))
            let kind = b == "s" ? "temps" : (b == "l" ? "L" : (b == "B" ? "o" : b))
            if p.isEmpty { return (kind, 1) }
            if let f = prefixes[p] { return (kind, f) }
        }
        return nil
    }

    /// « 2,5 kW = ▢ W » → « 2 500 ».
    static func conversion(before: String, after: String) -> String? {
        guard let body = equationBody(before),
              let g = captures("(?:^|[^0-9,.])(\(numberPattern))\\s*([A-Za-zΩµμ]{1,5})$", in: body), g.count == 2,
              let value = Parser(g[0]).wholeNumber(),
              let t = captures("^([A-Za-zΩµμ]{1,5})(?![\\p{L}0-9²³])", in: after.trimmingCharacters(in: .whitespaces)),
              let from = parseUnit(g[1]), let to = parseUnit(t[0]), from.kind == to.kind else { return nil }
        return format(value * from.factor / to.factor)
    }
}
