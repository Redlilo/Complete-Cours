import Foundation
import CoreGraphics

// Règles locales (sans IA) qui proposent le type d'une zone : mot, définition ou question ouverte.
// Elles sont déterministes : même zone, même contexte, même type. Le pipeline applique la règle quand elle est
// sûre ; l'IA ne tranche que les cas ambigus, avec le type proposé comme indication.

/// Résultat d'une règle : un type, un niveau de certitude (0 à 1) et la raison (pour les tests et les infobulles).
struct KindDecision: Equatable {
    var kind: ZoneKind
    var certainty: Double
    var reason: String
    /// La règle est assez sûre pour s'imposer sans consulter l'IA.
    var isSure: Bool { certainty >= ZoneKindRules.sureThreshold }
}

enum ZoneKindRules {
    /// Certitude minimale pour qu'une règle s'impose à l'IA.
    static let sureThreshold = 0.8

    // MARK: Texte

    /// Minuscules, sans accents, apostrophes droites, espaces simples : sert uniquement à repérer des mots-clés.
    static func fold(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        t = t.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "\u{00A0}", with: " ")
        return t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    }

    private static let definitionCue = "\\bdefini(s|r|ssez|tion|tions)?\\b|qu'est[- ]ce (que|qu')|\\bc'est quoi\\b|que (signifie|veut dire)|\\bsignification\\b|\\bdonne(r|z)? (la|une) definition"
    private static let openCue = "\\bexplique(z|r)?\\b|\\bpourquoi\\b|\\bjustifie(z|r)?\\b|\\bcite(z|r)?\\b|\\bdecri(s|vez|re)\\b|\\bcomment\\b|\\bdonne(r|z)? (un|une|des|deux|trois|quelques)\\b|\\bnomme(z|r)?\\b|\\bpropose(z|r)?\\b|\\bselon toi\\b|\\bdans quel cas\\b|\\ben quoi\\b|\\bque penses|\\bquel(le)?s? (est|sont|sera|seraient) (l'|le|la|les) (role|interet|avantage|inconvenient|importance|consequence)"
    private static let calcCue = "\\bcalcule(z|r)?\\b|\\bdetermine(z|r)?\\b|\\bdeduis\\b|\\bdeduire\\b|\\bconvertis\\b|\\bconvertir\\b|\\bapplication numerique\\b|\\bresultat\\b"

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: Proposition

    static func propose(_ z: Zone) -> KindDecision {
        let before = fold(z.contextBefore)
        let lines = before.split(whereSeparator: { $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let lastLine = lines.last ?? ""
        // la consigne est la dernière ligne ; on regarde aussi la fin du texte (consigne sur la ligne d'avant)
        let tail = String(before.suffix(160)).replacingOccurrences(of: "\n", with: " ")
        let scope = lastLine.count >= 12 ? lastLine : tail
        let afterSame = z.contextAfter.prefix(while: { $0 != "\n" }).trimmingCharacters(in: .whitespaces)
        let width = z.rect.width
        let lineCount = z.lines.count
        let bigBox = z.box.map { $0.height > 40 && $0.width * $0.height > 9000 } ?? false
        let multi = lineCount >= 2 || bigBox
        let inline = afterSame.count >= 2 && !multi

        let isDef = matches(definitionCue, scope)
        let isOpen = matches(openCue, scope)
        let isCalc = matches(calcCue, scope)
        let endsWithQuestion = scope.hasSuffix("?") || scope.hasSuffix("? :") || scope.hasSuffix("?:")

        // Case à cocher ou cellule minuscule : un symbole ou un mot.
        if z.source == .cadre || z.source == .formulaire, let b = z.box, !multi {
            if b.width < 24 && b.height < 24 { return KindDecision(kind: .mot, certainty: 0.95, reason: "case minuscule") }
            if b.width < 150 && b.height < 40 && !isDef {
                return KindDecision(kind: .mot, certainty: 0.85, reason: "petite case")
            }
        }

        if multi {
            if isDef && lineCount <= 2 { return KindDecision(kind: .definition, certainty: 0.9, reason: "« définis » et 1 à 2 lignes") }
            if isDef { return KindDecision(kind: .definition, certainty: 0.6, reason: "« définis » mais beaucoup de lignes") }
            if isCalc && !isOpen && lineCount <= 2 { return KindDecision(kind: .question, certainty: 0.6, reason: "calcul rédigé sur plusieurs lignes") }
            return KindDecision(kind: .question, certainty: 0.85, reason: "plusieurs lignes à rédiger")
        }
        if inline && width < 230 {
            return KindDecision(kind: .mot, certainty: isOpen ? 0.75 : 0.95, reason: "trou isolé dans une phrase")
        }
        if isDef {
            if width >= 120 { return KindDecision(kind: .definition, certainty: 0.9, reason: "« définis » ou « qu'est-ce que » avant une ligne large") }
            return KindDecision(kind: .mot, certainty: 0.6, reason: "consigne de définition mais trou étroit")
        }
        if inline {
            if width < 230 {
                return KindDecision(kind: .mot, certainty: isOpen ? 0.75 : 0.95, reason: "trou isolé dans une phrase")
            }
        }
        if endsWithQuestion {
            return width >= 150
                ? KindDecision(kind: .question, certainty: 0.85, reason: "consigne terminée par « ? » et ligne large")
                : KindDecision(kind: .mot, certainty: 0.8, reason: "question courte, trou étroit")
        }
        if isOpen {
            if width >= 230 { return KindDecision(kind: .question, certainty: 0.9, reason: "« explique », « pourquoi », « cite »… et ligne large") }
            if width >= 150 { return KindDecision(kind: .question, certainty: 0.7, reason: "consigne ouverte, ligne moyenne") }
            return KindDecision(kind: .mot, certainty: 0.6, reason: "consigne ouverte mais trou étroit")
        }
        if isCalc {
            return width < 230
                ? KindDecision(kind: .mot, certainty: 0.85, reason: "calcul : un résultat")
                : KindDecision(kind: .question, certainty: 0.6, reason: "calcul sur une ligne large")
        }
        if width < 150 { return KindDecision(kind: .mot, certainty: 0.85, reason: "trou étroit sans consigne ouverte") }
        if width < 230 { return KindDecision(kind: .mot, certainty: 0.6, reason: "trou moyen sans consigne") }
        return KindDecision(kind: .question, certainty: 0.6, reason: "ligne large sans consigne claire")
    }

    // MARK: Type retenu pour une complétion

    /// Type à utiliser pour une zone avant de consulter l'IA.
    /// - Le choix de l'élève (`userDecided`) l'emporte toujours et n'est jamais changé.
    /// - Une règle sûre s'impose (`locked`).
    /// - Sinon le type sert d'indication : celui d'une précédente réponse s'il y en a une (stabilité), sinon la règle.
    static func retained(for z: Zone, userDecided: Bool) -> (kind: ZoneKind, locked: Bool) {
        if userDecided { return (z.kind, true) }
        let d = propose(z)
        if d.isSure { return (d.kind, true) }
        if z.kind != .ignorer, !z.rawAnswer.isEmpty { return (z.kind, false) }
        return (d.kind, false)
    }
}

// MARK: - Confiance dans le trou

/// Un trou est « douteux » quand le détecteur n'est pas sûr que c'est un vrai trou.
enum ZoneTrust {
    static let threshold = 0.7

    static func isDoubtful(_ z: Zone) -> Bool { z.confidence < threshold }

    /// Zones douteuses encore actives (ni ignorées ni désactivées).
    static func doubtfulCount(_ zones: [Zone]) -> Int { zones.filter { isDoubtful($0) && $0.kind != .ignorer }.count }

    /// Les douteuses d'abord (l'ordre d'origine est gardé à l'intérieur de chaque groupe).
    static func doubtfulFirst(_ zones: [Zone]) -> [Zone] {
        zones.filter { isDoubtful($0) } + zones.filter { !isDoubtful($0) }
    }

    /// Infobulle : les raisons de la confiance renseignées par le détecteur.
    static func tooltip(_ z: Zone) -> String {
        let pct = Int((z.confidence * 100).rounded())
        let head = isDoubtful(z) ? "À vérifier (confiance \(pct) %)" : "Trou sûr (confiance \(pct) %)"
        if z.signals.isEmpty { return head }
        return head + " : " + z.signals.joined(separator: " · ")
    }
}

// MARK: - Contrôle facultatif des zones douteuses par l'IA

/// Moteur capable de répondre « vrai trou / pas un trou » de façon dédiée (facultatif).
/// Sans cela, `checkHoles` passe par `complete` : une zone que l'IA classe « ignorer » n'est pas un trou.
protocol HoleJudging: CompletionEngine {
    /// Zone (par `Zone.number`) → vrai si c'est un vrai trou. Une zone absente est considérée comme un vrai trou.
    func judgeHoles(_ request: PageRequest) async throws -> [Int: Bool]
}

extension CompletionEngine {
    /// Contrôle des zones douteuses d'une page (la requête ne contient que ces zones).
    func checkHoles(_ request: PageRequest) async throws -> [Int: Bool] {
        if let judge = self as? HoleJudging { return try await judge.judgeHoles(request) }
        var r = request
        r.holeCheckOnly = true
        let answers = try await complete(r)
        var out: [Int: Bool] = [:]
        for a in answers { out[a.number] = a.kind != .ignorer }
        return out
    }
}

/// Verdicts déjà obtenus, par signature de zone (indépendante du document) : une même zone n'est jamais redemandée.
final class HoleCheckCache: @unchecked Sendable {
    static let shared = HoleCheckCache()
    private let lock = NSLock()
    private var verdicts: [String: Bool] = [:]

    func verdict(for signature: String) -> Bool? { lock.lock(); defer { lock.unlock() }; return verdicts[signature] }
    func store(_ isHole: Bool, for signature: String) { lock.lock(); verdicts[signature] = isHole; lock.unlock() }
    func removeAll() { lock.lock(); verdicts.removeAll(); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return verdicts.count }
}
