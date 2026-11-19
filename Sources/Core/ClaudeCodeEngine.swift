// ============================================================================
// Moteur « Claude (mon compte) » — USAGE PERSONNEL de l'élève, sur son propre Mac.
//
// Ce moteur utilise l'abonnement Claude de l'élève (pas de clé API) en lançant le programme officiel
// Claude Code, sans le modifier, en mode non interactif (`claude -p`). L'élève s'y connecte lui-même
// (`claude auth login`) ; l'app ne lit, ne copie et ne stocke jamais ni jeton ni identifiant.
//
// Les règles d'Anthropic interdisent à une app distribuée à d'autres personnes de faire passer leurs
// requêtes par un abonnement personnel : TOUT ce fichier est donc dans « #if COMPTE_PERSO ».
// Le build à distribuer ne définit pas ce symbole (le fichier est alors vide) ; la version personnelle
// et les tests se compilent avec « -D COMPTE_PERSO ».
//
// Rien n'est jamais journalisé : ni la sortie du programme, ni le contenu des pages, ni les réponses.
// Tests (faux programme `claude`, aucun appel réseau, aucun quota) : Tools/Tests/ClaudeCode/run.sh
// ============================================================================

#if COMPTE_PERSO

import Foundation
import Darwin

final class ClaudeCodeEngine: CompletionEngine {

    // MARK: - Choix proposés dans les réglages

    struct Choice: Identifiable, Hashable {
        let id: String
        let label: String
        let hint: String
    }
    typealias ModelChoice = Choice

    /// `id` = valeur de `--model` ; vide = le modèle par défaut du compte (aucune option transmise).
    static let models: [Choice] = [
        Choice(id: "", label: "Défaut du compte", hint: "le modèle que Claude Code choisit pour ton abonnement"),
        Choice(id: "opus", label: "Opus", hint: "précis, consomme plus de quota"),
        Choice(id: "sonnet", label: "Sonnet", hint: "équilibré"),
        Choice(id: "haiku", label: "Haiku", hint: "rapide, léger"),
    ]
    static let defaultModel = ""

    /// `id` = valeur de `--effort`.
    static let efforts: [Choice] = [
        Choice(id: "low", label: "Rapide", hint: "réfléchit peu, économise ton quota"),
        Choice(id: "medium", label: "Normal", hint: "le bon compromis (conseillé)"),
        Choice(id: "high", label: "Approfondi", hint: "réfléchit plus, plus lent, consomme plus de quota"),
    ]
    static let defaultEffort = "medium"

    static let engineName = "Claude (mon compte)"
    /// Texte du bouton de connexion : les messages d'erreur y renvoient, l'interface doit utiliser la même chaîne.
    static let loginButtonTitle = "Me connecter"
    /// Mise en garde à afficher sous le choix du moteur.
    static let personalUseWarning = "Usage personnel uniquement : ce moteur utilise ton propre abonnement Claude. "
        + "Il consomme ton quota d'abonnement et il est plus lent que les autres moteurs. Ne le partage pas avec d'autres personnes."

    // MARK: - Délais et attentes (seuls les tests les raccourcissent)

    struct Tuning {
        var callTimeout: TimeInterval = 300         // délai maximal d'un appel `claude -p` (complétion, humanisation)
        var generateTimeout: TimeInterval = 600     // mode Révision (StructuredGenerator) : documents entiers, réponses longues
        var statusTimeout: TimeInterval = 20        // `--version`, `auth status`
        var loginTimeout: TimeInterval = 600        // `auth login` : l'élève valide dans son navigateur
        var retryDelays: [TimeInterval] = [2, 6]    // attente avant chaque relance : au plus 2 relances (3 appels)
        var killGrace: TimeInterval = 2             // SIGTERM, puis SIGKILL après ce délai
        var pipeGrace: TimeInterval = 1             // après la fin du programme, attente de la fin des tubes
        var maxOutputBytes = 32 * 1024 * 1024       // au-delà, la sortie est lue mais jetée
        var chunkSize = 15                          // réponses réécrites par appel (humanize)
        var workRoot: URL? = nil                    // parent des dossiers de travail (défaut : dossier temporaire)
        var environment: [String: String]? = nil    // environnement de départ (défaut : celui de l'app)
    }

    // MARK: - État du compte

    enum Status: Equatable {
        case ready(account: String?)    // connecté ; e-mail et abonnement s'ils sont connus
        case notLoggedIn
        case absent                     // programme introuvable ou impossible à lancer
        case problem(String)            // le programme répond, mais l'état n'est pas utilisable (message français)

        var isReady: Bool { if case .ready = self { return true } else { return false } }

        /// Phrase courte pour la section Réglages.
        var summary: String {
            switch self {
            case .ready(let account): return account.map { "Connecté — \($0)" } ?? "Connecté"
            case .notLoggedIn: return "Pas connecté"
            case .absent: return "Claude Code est introuvable"
            case .problem(let m): return m
            }
        }
    }

    // MARK: - Moteur

    let displayName = ClaudeCodeEngine.engineName
    let usesImages = true
    let maxConcurrentPages = 2

    let cli: URL
    let model: String
    let effort: String
    let tuning: Tuning

    /// `cli` : le programme `claude` (voir `locateCLI`). `model` : alias (opus, sonnet, haiku) ou vide.
    init(cli: URL, model: String = ClaudeCodeEngine.defaultModel, effort: String = ClaudeCodeEngine.defaultEffort,
         tuning: Tuning = Tuning()) {
        self.cli = cli
        self.model = Self.cleanOption(model)
        self.effort = Self.cleanOption(effort)
        self.tuning = tuning
    }

    /// Une valeur d'option n'est transmise que si elle ressemble à un nom de modèle / d'effort
    /// (jamais une chaîne qui commence par « - » : elle serait prise pour une autre option).
    static func cleanOption(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,63}$"#, options: .regularExpression) != nil else { return "" }
        return t
    }

    // MARK: - Contrat CompletionEngine

    func complete(_ request: PageRequest) async throws -> [ZoneAnswer] {
        if request.zones.isEmpty { return [] }
        var content: [[String: Any]] = []
        if let jpeg = request.markedImageJPEG, !jpeg.isEmpty {
            let source: [String: Any] = ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]
            content.append(["type": "image", "source": source])
        }
        content.append(["type": "text", "text": Prompts.completionUserText(request)])
        let json = try await generate(system: Prompts.completionSystem, content: content, schema: Prompts.completionSchema)
        return try ClaudeEngine.decodeCompletion(json, expected: Set(request.zones.map { $0.number }))
    }

    /// Les réponses sont réécrites par paquets : un appel de ce moteur coûte du temps et du quota.
    /// Un paquet qui échoue (erreur non fatale) laisse ses réponses d'origine ; si tous échouent, l'erreur est levée.
    func humanize(_ items: [HumanizeItem]) async throws -> [Int: String] {
        guard !items.isEmpty else { return [:] }
        let size = max(1, tuning.chunkSize)
        var result: [Int: String] = [:]
        var succeeded = false
        var lastError: EngineError?
        var start = 0
        while start < items.count {
            let chunk = Array(items[start..<min(start + size, items.count)])
            start += size
            try Task.checkCancellation()
            do {
                let content: [[String: Any]] = [["type": "text", "text": Prompts.humanizeUserText(chunk)]]
                let json = try await generate(system: Prompts.humanizeSystem, content: content, schema: Prompts.humanizeSchema)
                let part = try ClaudeEngine.decodeHumanization(json, expected: Set(chunk.map { $0.id }))
                result.merge(part) { first, _ in first }
                succeeded = true
            } catch let e as EngineError {
                if e.isFatal { throw e }
                lastError = e
            }
        }
        if !succeeded, let e = lastError { throw e }
        return result
    }

    /// Appel générique : envoie `content` (blocs au format de l'API Messages : texte, image base64) avec le prompt
    /// système et le schéma JSON, et renvoie le texte JSON de la réponse structurée. Mêmes garde-fous que `complete` :
    /// environnement assaini, dossier de travail vide, délai maximal, annulation, relances sur panne passagère.
    /// `timeout` : délai maximal d'un essai (par défaut `tuning.callTimeout`).
    func generate(system: String, content: [[String: Any]], schema: [String: Any], timeout: TimeInterval? = nil) async throws -> String {
        let arguments = try makeArguments(system: system, schema: schema)
        let input = try Self.encodeUserMessage(content)
        let limit = timeout ?? tuning.callTimeout
        var retries = 0
        while true {
            try Task.checkCancellation()
            switch try await attempt(arguments: arguments, input: input, timeout: limit) {
            case .success(let json):
                return json
            case .failure(let error, let retry):
                guard retry, retries < tuning.retryDelays.count else { throw error }
                let wait = max(0, tuning.retryDelays[retries])
                retries += 1
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    // MARK: - Un appel du programme

    private enum Attempt {
        case success(String)
        case failure(EngineError, retry: Bool)
    }

    /// Options du programme. Ordre et valeurs sont vérifiés par le faux programme des tests.
    func makeArguments(system: String, schema: [String: Any]) throws -> [String] {
        guard JSONSerialization.isValidJSONObject(schema),
              let schemaData = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys, .withoutEscapingSlashes]),
              let schemaText = String(data: schemaData, encoding: .utf8) else {
            throw EngineError.other("Le format de réponse demandé à Claude est invalide (erreur interne de l'application).")
        }
        var a = ["-p",
                 "--safe-mode",                      // ni CLAUDE.md, ni plugins, ni hooks, ni MCP
                 "--tools", "",                      // aucun outil : Claude ne fait que répondre
                 "--disable-slash-commands",
                 "--no-session-persistence",         // rien n'est enregistré sur le disque
                 "--permission-prompts", "none",     // jamais de question en attente
                 "--input-format", "stream-json",
                 "--output-format", "stream-json",
                 "--verbose",                        // exigé par stream-json
                 "--system-prompt", system,
                 "--json-schema", schemaText]
        if !model.isEmpty { a += ["--model", model] }
        // Haiku n'a pas de réglage d'effort : on ne le lui envoie pas.
        if !effort.isEmpty, model != "haiku" { a += ["--effort", effort] }
        return a
    }

    /// Une ligne JSON {"type":"user","message":{…}} suivie d'un saut de ligne, puis stdin est fermé.
    static func encodeUserMessage(_ content: [[String: Any]]) throws -> Data {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content] as [String: Any]]
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
            throw EngineError.other("Le message envoyé à Claude n'a pas pu être préparé (erreur interne de l'application).")
        }
        data.append(0x0A)
        return data
    }

    private func attempt(arguments: [String], input: Data, timeout: TimeInterval) async throws -> Attempt {
        let folder = try Self.makeWorkFolder(root: tuning.workRoot)
        defer { try? FileManager.default.removeItem(at: folder) }
        let env = Self.sanitizedEnvironment(base: tuning.environment ?? ProcessInfo.processInfo.environment, cli: cli)
        let raw: ProcessOutput
        do {
            raw = try await Self.run(cli, arguments: arguments, stdin: input, timeout: timeout,
                                     directory: folder, environment: env, tuning: tuning)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(.unavailable(Self.cannotRunMessage), retry: false)
        }
        return interpret(raw, timeout: timeout)
    }

    private func interpret(_ raw: ProcessOutput, timeout: TimeInterval) -> Attempt {
        if raw.timedOut { return .failure(.network(Self.timeoutMessage(timeout)), retry: false) }
        let parsed = Self.parseStream(raw.stdout)
        if let r = parsed.result {
            if !r.isError {
                if let json = Self.structuredText(from: r) { return .success(json) }
                if r.stopReason == "refusal" || r.terminalReason == "refusal" || r.safetyStops > 0 {
                    return .failure(.refused(Self.refusedMessage), retry: false)
                }
                return .failure(.invalidResponse(Self.badFormatMessage), retry: false)
            }
            if let hit = Self.classify(text: r.text, assistantError: parsed.assistantError, apiStatus: r.apiStatus,
                                       subtype: r.subtype, stopReason: r.stopReason ?? r.terminalReason) {
                return .failure(hit.error, retry: hit.retry)
            }
            return .failure(.other(Self.genericMessage(r.text)), retry: false)
        }
        // Pas de ligne « result » : sortie vide, coupée, programme planté ou erreur écrite à côté.
        let stderrText = String(decoding: raw.stderr.prefix(8000), as: UTF8.self)
        let combined = parsed.plainText + "\n" + stderrText
        if let hit = Self.classify(text: combined, assistantError: parsed.assistantError, apiStatus: nil, subtype: "", stopReason: nil) {
            return .failure(hit.error, retry: hit.retry)
        }
        if !raw.uncaughtSignal, raw.exitCode == 126 || raw.exitCode == 127 {
            return .failure(.unavailable(Self.cannotRunMessage), retry: false)
        }
        return .failure(.network(Self.noAnswerMessage), retry: true)
    }

    // MARK: - Lecture de la sortie (lignes JSON)

    struct StreamResult {
        var isError = false
        var subtype = ""
        var text = ""
        var structured: Any?
        var apiStatus: Int?
        var stopReason: String?
        var terminalReason: String?
        var safetyStops = 0
    }

    struct ParsedStream {
        var result: StreamResult?
        var assistantError: String?
        /// Les lignes qui ne sont pas du JSON (un message d'erreur écrit tel quel, une ligne coupée).
        var plainText = ""
    }

    /// Tolérant : types de messages inconnus ignorés, lignes vides ou coupées ignorées, dernière ligne `result` retenue.
    static func parseStream(_ data: Data) -> ParsedStream {
        var parsed = ParsedStream()
        let text = String(decoding: data, as: UTF8.self)
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.hasPrefix("{"), let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                if parsed.plainText.count < 4000 { parsed.plainText += line + "\n" }
                continue
            }
            switch obj["type"] as? String {
            case "result":
                var r = StreamResult()
                r.isError = boolValue(obj["is_error"])
                r.subtype = obj["subtype"] as? String ?? ""
                r.text = obj["result"] as? String ?? ""
                if let s = obj["structured_output"], !(s is NSNull) { r.structured = s }
                r.apiStatus = intValue(obj["api_error_status"])
                r.stopReason = obj["stop_reason"] as? String
                r.terminalReason = obj["terminal_reason"] as? String
                r.safetyStops = intValue(obj["safety_stops"]) ?? 0
                parsed.result = r
            case "assistant":
                if let e = obj["error"] as? String, !e.isEmpty { parsed.assistantError = e }
            default:
                break
            }
        }
        return parsed
    }

    private static func boolValue(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return s.lowercased() == "true" }
        return false
    }

    private static func intValue(_ v: Any?) -> Int? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.intValue }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Texte JSON de la réponse : `structured_output` d'abord, à défaut le champ `result` lu comme du JSON.
    static func structuredText(from r: StreamResult) -> String? {
        if let s = r.structured {
            if let str = s as? String, let json = jsonText(from: str) { return json }
            if (s is [String: Any] || s is [Any]), JSONSerialization.isValidJSONObject(s),
               let d = try? JSONSerialization.data(withJSONObject: s, options: [.withoutEscapingSlashes]),
               let str = String(data: d, encoding: .utf8) { return str }
        }
        return jsonText(from: r.text)
    }

    /// Extrait un objet ou un tableau JSON d'un texte : tel quel, sans barrières ```, ou entre la première
    /// accolade et la dernière. nil si rien ne se lit comme du JSON.
    static func jsonText(from raw: String) -> String? {
        func parses(_ s: String) -> Bool {
            guard let d = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) else { return false }
            return obj is [String: Any] || obj is [Any]
        }
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if parses(t) { return t }
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: #"^```[A-Za-z]*\s*"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"\s*```\s*$"#, with: "", options: .regularExpression)
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if parses(t) { return t }
        }
        if let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a < b {
            let inner = String(t[a...b])
            if parses(inner) { return inner }
        }
        return nil
    }

    // MARK: - Erreurs

    static let notLoggedInMessage = "Tu n'es pas connecté à ton compte Claude. Ouvre les réglages, choisis « \(engineName) » "
        + "puis clique sur « \(loginButtonTitle) » : une page s'ouvre dans ton navigateur pour valider la connexion."
    static let cannotRunMessage = "Claude Code ne peut pas être lancé sur ce Mac. Vérifie le chemin du programme dans les réglages, "
        + "ou ouvre l'app Claude pour qu'elle le réinstalle."
    static let missingMessage = "Claude Code est introuvable sur ce Mac. Installe l'app Claude (claude.ai/download) et ouvre-la une fois, "
        + "ou indique dans les réglages le chemin du programme « claude »."
    static let badFormatMessage = "Claude n'a pas réussi à répondre dans le format demandé. "
        + "Réessaie ; si le problème continue, choisis un autre modèle dans les réglages."
    static let refusedMessage = "Claude a refusé de traiter cette page. Tu peux la remplir à la main, "
        + "ou réessayer avec un autre modèle choisi dans les réglages."
    static let tooBigMessage = "Cette page est trop volumineuse pour Claude (texte ou image trop lourds). "
        + "Essaie avec un autre moteur, ou remplis cette page à la main."
    static let noAnswerMessage = "Claude Code s'est arrêté sans donner de réponse (programme interrompu ou connexion coupée). "
        + "Vérifie ta connexion Internet puis réessaie dans un instant."
    static let networkMessage = "Claude est surchargé ou injoignable pour le moment. "
        + "Vérifie ta connexion Internet puis réessaie dans quelques instants."
    static let billingMessage = "Ton compte Claude signale un problème d'abonnement ou de paiement. "
        + "Vérifie ton abonnement sur claude.ai, ou choisis un autre moteur dans les réglages."

    static func timeoutMessage(_ seconds: TimeInterval) -> String {
        let d = seconds >= 90 ? "\(Int((seconds / 60).rounded())) minutes" : "\(Int(seconds.rounded())) s"
        return "Claude Code n'a pas répondu dans le délai prévu (\(d)) : l'appel a été arrêté. "
            + "Vérifie ta connexion Internet puis réessaie."
    }

    static func tooOldMessage(option: String) -> String {
        "La version de Claude Code installée sur ce Mac ne connaît pas l'option « \(option) » dont l'app a besoin. "
            + "Mets à jour l'app Claude, puis réessaie."
    }

    static func usageLimitMessage(resetPhrase: String?) -> String {
        var s = "Tu as atteint la limite de ton abonnement Claude."
        s += resetPhrase.map { " Elle se renouvelle \($0)." } ?? " Elle se renouvelle d'ici quelques heures."
        return s + " Réessaie à ce moment-là, ou choisis un autre moteur dans les réglages."
    }

    static func genericMessage(_ text: String) -> String {
        let s = scrub(text)
        return s.isEmpty ? "Claude Code a signalé une erreur sans donner de détail. Réessaie ; si le problème continue, choisis un autre moteur."
            : "Claude Code a signalé une erreur : « \(s) ». Réessaie ; si le problème continue, choisis un autre moteur."
    }

    /// Texte d'erreur sur une ligne, raccourci, sans clé ni nom d'utilisateur : il peut être affiché à l'élève.
    static func scrub(_ text: String, limit: Int = 200) -> String {
        var s = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"sk-[A-Za-z0-9_\-]{6,}"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[A-Za-z0-9_\-]{32,}"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"/Users/[^\s/]+"#, with: "/Users/…", options: .regularExpression)
        return s.count > limit ? String(s.prefix(limit)) + "…" : s
    }

    // MARK: Reconnaissance des erreurs

    static func isNotLoggedIn(_ low: String) -> Bool {
        ["not logged in", "run /login", "please log in", "invalid api key", "authentication_error", "authentication failed",
         "oauth token has expired", "oauth token has been revoked", "token has expired", "login required", "auth login"]
            .contains { low.contains($0) }
    }

    static func isUsageLimit(_ low: String) -> Bool {
        if low.contains("context limit") || low.contains("context window") { return false }
        guard low.contains("limit") || low.contains("quota") else { return false }
        return ["usage", "reached", "hit your", "reset", "exceeded", "weekly", "session", "5-hour", "rate"].contains { low.contains($0) }
    }

    static func unknownOption(in text: String) -> String? {
        guard let m = matches(#"unknown option '([^']+)'"#, in: text), let o = m[1] else { return nil }
        return o
    }

    /// Cherche d'abord les causes qu'on ne peut pas résoudre en réessayant (connexion, limite, version), puis les pannes passagères.
    static func classify(text: String, assistantError: String?, apiStatus: Int?, subtype: String,
                         stopReason: String?) -> (error: EngineError, retry: Bool)? {
        let low = text.lowercased()
        let code = assistantError ?? ""
        if code == "authentication_failed" || apiStatus == 401 || isNotLoggedIn(low) {
            return (.unavailable(notLoggedInMessage), false)
        }
        if let option = unknownOption(in: text) { return (.unavailable(tooOldMessage(option: option)), false) }
        if code == "billing_error" || low.contains("credit balance is too low") {
            return (.unavailable(billingMessage), false)
        }
        if low.contains("prompt is too long") || low.contains("context limit") || low.contains("context window") || apiStatus == 413
            || low.contains("image exceeds") || low.contains("image dimensions exceed") {
            return (.invalidResponse(tooBigMessage), false)
        }
        if isUsageLimit(low) || code == "rate_limit" || apiStatus == 429 {
            return (.unavailable(usageLimitMessage(resetPhrase: resetPhrase(from: text))), false)
        }
        if subtype.contains("structured_output") || low.contains("structured output") {
            return (.invalidResponse(badFormatMessage), false)
        }
        if stopReason == "refusal" || low.contains("refus") {
            return (.refused(refusedMessage), false)
        }
        let network = ["overloaded", "internal server error", "bad gateway", "service unavailable", "gateway timeout", "timed out",
                       "timeout", "econnreset", "econnrefused", "enotfound", "etimedout", "socket hang up", "connection error",
                       "unable to connect", "fetch failed", "network error", "temporarily unavailable"]
        if code == "server_error" || (apiStatus ?? 0) >= 500 || apiStatus == 408 || network.contains(where: { low.contains($0) }) {
            return (.network(networkMessage), true)
        }
        return nil
    }

    // MARK: Heure de remise à zéro de la limite

    private static func matches(_ pattern: String, in text: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// « vers 15:00 », « demain vers 09:30 » ou « le 9 octobre vers 12:00 », si le message donne l'heure de remise à zéro.
    /// Formes reconnues : « …|1760000000 », « resets 3pm (Europe/Paris) », « resets Oct 9, 12pm », « reset at 15:30 », « resets in 2h 30m ».
    /// L'heure est donnée dans le fuseau `timeZone` (celui du Mac par défaut).
    static func resetPhrase(from text: String, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone

        if let m = matches(#"\|\s*(\d{10})\b"#, in: text), let s = m[1], let secs = TimeInterval(s) {
            return phrase(for: Date(timeIntervalSince1970: secs), now: now, calendar: local)
        }
        if let m = matches(#"resets?\s+in\s+(?:(\d+)\s*h(?:ours?|rs?)?)?\s*(?:(\d+)\s*m(?:in(?:ute)?s?)?)?"#, in: text) {
            let h = Int(m[1] ?? "") ?? 0, mn = Int(m[2] ?? "") ?? 0
            if h > 0 || mn > 0 { return phrase(for: now.addingTimeInterval(TimeInterval(h * 3600 + mn * 60)), now: now, calendar: local) }
        }
        let pattern = #"resets?\s+(?:at\s+)?(?:([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*([AaPp]\.?[Mm]\.?)?(?:\s*\(([^)]{1,40})\))?"#
        guard let m = matches(pattern, in: text), let hs = m[3], var hour = Int(hs) else { return nil }
        let minute = Int(m[4] ?? "") ?? 0
        let ampm = m[5]?.lowercased().replacingOccurrences(of: ".", with: "")
        guard ampm != nil || m[4] != nil else { return nil }
        if let ap = ampm {
            guard (1...12).contains(hour) else { return nil }
            if ap == "pm" && hour < 12 { hour += 12 }
            if ap == "am" && hour == 12 { hour = 0 }
        }
        guard hour < 24, minute < 60 else { return nil }

        var zoned = Calendar(identifier: .gregorian)
        zoned.timeZone = m[6].flatMap { TimeZone(identifier: $0.trimmingCharacters(in: .whitespaces)) } ?? timeZone
        var comps = zoned.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        var target: Date?
        if let mon = m[1], let dayText = m[2], let day = Int(dayText),
           let index = monthNames.firstIndex(of: String(mon.lowercased().prefix(3))) {
            comps.month = index + 1
            comps.day = day
            target = zoned.date(from: comps)
            if let t = target, t < now.addingTimeInterval(-86_400) {
                comps.year = (comps.year ?? 0) + 1
                target = zoned.date(from: comps)
            }
        } else if let t = zoned.date(from: comps) {
            target = t <= now ? zoned.date(byAdding: .day, value: 1, to: t) : t
        }
        guard let date = target else { return nil }
        return phrase(for: date, now: now, calendar: local)
    }

    private static func phrase(for date: Date, now: Date, calendar: Calendar) -> String? {
        guard date > now else { return nil }
        let hm = DateFormatter()
        hm.locale = Locale(identifier: "fr_FR")
        hm.timeZone = calendar.timeZone
        hm.dateFormat = "HH:mm"
        let time = hm.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "vers \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "demain vers \(time)"
        }
        let dm = DateFormatter()
        dm.locale = Locale(identifier: "fr_FR")
        dm.timeZone = calendar.timeZone
        dm.dateFormat = "d MMMM"
        return "le \(dm.string(from: date)) vers \(time)"
    }

    // MARK: - Environnement et dossier de travail

    /// Seules quelques variables sont transmises. Surtout pas ANTHROPIC_* (une clé API ferait facturer l'API au lieu de
    /// l'abonnement) ni CLAUDE_CODE_* / CLAUDECODE (le programme se croirait lancé par une autre session de Claude Code).
    /// Les variables de proxy et de certificats sont gardées : sur un réseau d'école, sans elles, rien ne passe.
    static func sanitizedEnvironment(base: [String: String], cli: URL) -> [String: String] {
        let keep = ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "__CF_USER_TEXT_ENCODING", "CLAUDE_CONFIG_DIR",
                    "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "all_proxy", "no_proxy",
                    "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"]
        var env: [String: String] = [:]
        for key in keep { if let v = base[key], !v.isEmpty { env[key] = v } }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["USER"] == nil { env["USER"] = NSUserName() }
        if env["TMPDIR"] == nil { env["TMPDIR"] = NSTemporaryDirectory() }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["PATH"] = safePath(for: cli)
        for key in Array(env.keys) where isForbiddenVariable(key) { env.removeValue(forKey: key) }
        return env
    }

    static func isForbiddenVariable(_ key: String) -> Bool {
        let k = key.uppercased()
        return k.hasPrefix("ANTHROPIC_") || k.hasPrefix("CLAUDE_CODE_") || k == "CLAUDECODE" || k.hasPrefix("CLAUDE_AGENT_")
    }

    /// Dossiers système, plus celui du programme (un `claude` installé avec npm a besoin de `node` à côté de lui).
    static func safePath(for cli: URL) -> String {
        var dirs = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for extra in [cli.deletingLastPathComponent().path, cli.resolvingSymlinksInPath().deletingLastPathComponent().path]
        where !dirs.contains(extra) { dirs.append(extra) }
        return dirs.joined(separator: ":")
    }

    /// Dossier vide, privé, créé pour un appel et supprimé juste après (le programme n'a aucune raison de voir autre chose).
    static func makeWorkFolder(root: URL?) throws -> URL {
        let base = root ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("CompleteCours-ClaudeCode-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw EngineError.other("Impossible de préparer un dossier de travail temporaire pour Claude Code. "
                + "Vérifie qu'il reste de la place sur le disque, puis réessaie.")
        }
        return dir
    }

    // MARK: - Trouver le programme

    /// Nombre par nombre : 2.1.325 est plus récent que 2.1.9.
    static func parseVersion(_ text: String) -> [Int]? {
        guard let m = matches(#"^v?(\d+(?:\.\d+)*)"#, in: text.trimmingCharacters(in: .whitespacesAndNewlines)), let v = m[1] else { return nil }
        return v.split(separator: ".").compactMap { Int($0) }
    }

    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func isExecutableFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Programmes possibles, du préféré au dernier : l'app Claude (version la plus haute d'abord), puis les installations courantes.
    static func candidateCLIs(home: URL, systemBinDirs: [String]) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true)
        let versions = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .compactMap { name in parseVersion(name).map { (name, $0) } }
            .sorted { isNewer($0.1, than: $1.1) }
        for (name, _) in versions {
            let versionDir = root.appendingPathComponent(name, isDirectory: true)
            let hashes = ((try? fm.contentsOfDirectory(atPath: versionDir.path)) ?? []).sorted { a, b in
                let da = (try? fm.attributesOfItem(atPath: versionDir.appendingPathComponent(a).path)[.modificationDate]) as? Date
                let db = (try? fm.attributesOfItem(atPath: versionDir.appendingPathComponent(b).path)[.modificationDate]) as? Date
                return (da ?? .distantPast) > (db ?? .distantPast)
            }
            for h in hashes {
                let exe = versionDir.appendingPathComponent(h).appendingPathComponent("claude.app/Contents/MacOS/claude")
                if isExecutableFile(exe) { found.append(exe) }
            }
        }
        var others = [home.appendingPathComponent(".local/bin/claude")]
        others += systemBinDirs.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
        others.append(home.appendingPathComponent(".claude/local/claude"))
        found += others.filter { isExecutableFile($0) }
        return found
    }

    /// Chemin imposé par l'élève : « ~ » accepté, guillemets collés ignorés, dossier « Claude.app » ou dossier contenant `claude` admis.
    private static func resolveOverride(_ raw: String, home: URL) -> URL? {
        var p = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\t"))
        if p.hasPrefix("file://"), let u = URL(string: p) { p = u.path }
        if p == "~" || p.hasPrefix("~/") { p = home.path + p.dropFirst() }
        let url = URL(fileURLWithPath: p)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { return isExecutableFile(url) ? url : nil }
        for inner in ["Contents/MacOS/claude", "claude"] {
            let u = url.appendingPathComponent(inner)
            if isExecutableFile(u) { return u }
        }
        return nil
    }

    /// Le programme à utiliser, sans le lancer : le chemin imposé s'il y en a un (et seulement lui), sinon le meilleur candidat.
    static func locateCLI(override: String?, home: URL? = nil, systemBinDirs: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) -> URL? {
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser
        if let o = override?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty { return resolveOverride(o, home: home) }
        return candidateCLIs(home: home, systemBinDirs: systemBinDirs).first
    }

    /// Comme `locateCLI`, mais le programme doit répondre à `--version` ; un candidat muet est écarté au profit du suivant.
    static func locateWorkingCLI(override: String?, home: URL? = nil, systemBinDirs: [String] = ["/opt/homebrew/bin", "/usr/local/bin"],
                                 tuning: Tuning = Tuning()) async -> (url: URL, version: String)? {
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL]
        if let o = override?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
            candidates = resolveOverride(o, home: home).map { [$0] } ?? []
        } else {
            candidates = candidateCLIs(home: home, systemBinDirs: systemBinDirs)
        }
        for url in candidates {
            if let v = await version(of: url, tuning: tuning) { return (url, v) }
        }
        return nil
    }

    /// Numéro de version affiché par `--version` (« 2.1.325 »), nil si le programme ne répond pas comme Claude Code.
    static func version(of cli: URL, tuning: Tuning = Tuning()) async -> String? {
        guard let out = await runSimple(cli, ["--version"], timeout: tuning.statusTimeout, tuning: tuning), !out.timedOut, out.exitCode == 0 else { return nil }
        let text = String(decoding: out.stdout.prefix(2000), as: UTF8.self)
        guard let m = matches(#"(\d+\.\d+\.\d+\S*)"#, in: text) else { return nil }
        return m[1]
    }

    // MARK: - État du compte et connexion

    /// `claude auth status` (JSON). Ne contacte pas le réseau et n'affiche aucun jeton.
    static func status(cli: URL, tuning: Tuning = Tuning()) async -> Status {
        guard let out = await runSimple(cli, ["auth", "status"], timeout: tuning.statusTimeout, tuning: tuning) else { return .absent }
        if out.timedOut { return .problem("Claude Code ne répond pas (vérification du compte trop longue). Réessaie dans un instant.") }
        return parseStatus(stdout: out.stdout, exitCode: out.exitCode)
    }

    static func parseStatus(stdout: Data, exitCode: Int32) -> Status {
        let text = String(decoding: stdout.prefix(20_000), as: UTF8.self)
        var obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        if obj == nil, let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b {
            obj = (try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8))) as? [String: Any]
        }
        if let obj, let logged = obj["loggedIn"] as? Bool {
            guard logged else { return .notLoggedIn }
            let method = (obj["authMethod"] as? String ?? "").lowercased()
            if method.contains("api") || method.contains("console") {
                return .problem("Claude Code est connecté avec une clé API (facturation à l'usage), pas avec ton abonnement. "
                    + "Déconnecte-le puis clique sur « \(loginButtonTitle) » pour te connecter avec ton abonnement.")
            }
            return .ready(account: accountText(obj))
        }
        let low = text.lowercased()
        if low.contains("not logged in") { return .notLoggedIn }
        return .problem("Claude Code a répondu, mais l'état de ta connexion est illisible. Réessaie ; si le problème continue, "
            + "mets à jour l'app Claude.")
    }

    private static func accountText(_ obj: [String: Any]) -> String? {
        let email = (obj["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var plan: String?
        if let raw = (obj["subscriptionType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            switch raw.lowercased() {
            case "enterprise": plan = "Entreprise"
            case "free": plan = "gratuit"
            default: plan = raw.prefix(1).uppercased() + raw.dropFirst()
            }
        }
        switch (email?.isEmpty == false ? email : nil, plan) {
        case let (e?, p?): return "\(e) (abonnement \(p))"
        case let (e?, nil): return e
        case let (nil, p?): return "abonnement \(p)"
        default: return nil
        }
    }

    /// Lance `claude auth login --claudeai` et attend la fin : le navigateur s'ouvre, l'élève valide lui-même. Rien de ce que le
    /// programme écrit n'est lu ni gardé. La réussite est confirmée par `auth status`.
    static func login(cli: URL, tuning: Tuning = Tuning()) async throws {
        let folder = try makeWorkFolder(root: tuning.workRoot)
        defer { try? FileManager.default.removeItem(at: folder) }
        let env = sanitizedEnvironment(base: tuning.environment ?? ProcessInfo.processInfo.environment, cli: cli)
        let out: ProcessOutput
        do {
            out = try await run(cli, arguments: ["auth", "login", "--claudeai"], stdin: Data(), timeout: tuning.loginTimeout,
                                directory: folder, environment: env, tuning: tuning)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EngineError.unavailable(cannotRunMessage)
        }
        let command = terminalLoginCommand(cli: cli)
        if out.timedOut {
            throw EngineError.unavailable("La connexion n'a pas été validée à temps. Clique de nouveau sur « \(loginButtonTitle) » et "
                + "termine la connexion dans ton navigateur, ou lance cette commande dans le Terminal : \(command)")
        }
        if out.exitCode != 0 {
            throw EngineError.unavailable("La connexion à ton compte Claude n'a pas abouti. Réessaie ; si la page de connexion ne s'ouvre "
                + "pas, lance cette commande dans le Terminal : \(command)")
        }
        switch await status(cli: cli, tuning: tuning) {
        case .ready: return
        case .problem(let m): throw EngineError.unavailable(m)
        case .absent: throw EngineError.unavailable(cannotRunMessage)
        case .notLoggedIn:
            throw EngineError.unavailable("La connexion n'est pas terminée : valide-la dans ton navigateur, puis clique de nouveau sur "
                + "« \(loginButtonTitle) ». Sinon, lance cette commande dans le Terminal : \(command)")
        }
    }

    /// La commande à copier dans le Terminal si la connexion depuis l'app ne marche pas.
    static func terminalLoginCommand(cli: URL) -> String {
        "'" + cli.path.replacingOccurrences(of: "'", with: "'\\''") + "' auth login"
    }

    /// Message prêt à afficher si le moteur est inutilisable (programme absent, pas connecté…), nil s'il est prêt.
    static func unavailabilityReason(cliOverride: String?, home: URL? = nil, systemBinDirs: [String] = ["/opt/homebrew/bin", "/usr/local/bin"],
                                     tuning: Tuning = Tuning()) async -> String? {
        guard let found = await locateWorkingCLI(override: cliOverride, home: home, systemBinDirs: systemBinDirs, tuning: tuning) else {
            if let o = cliOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
                return "Le programme indiqué dans les réglages (« \(scrub(o, limit: 80)) ») ne répond pas comme Claude Code. "
                    + "Vérifie le chemin, ou efface-le pour que l'app cherche toute seule."
            }
            return missingMessage
        }
        switch await status(cli: found.url, tuning: tuning) {
        case .ready: return nil
        case .notLoggedIn: return "Tu n'es pas connecté : clique sur « \(loginButtonTitle) » dans les réglages, puis valide la connexion dans ton navigateur."
        case .absent: return cannotRunMessage
        case .problem(let m): return m
        }
    }

    // MARK: - Lancement du processus

    struct ProcessOutput {
        var stdout: Data
        var stderr: Data
        var exitCode: Int32
        var uncaughtSignal: Bool       // terminé par un signal (planté, tué) : exitCode est alors le numéro du signal
        var timedOut: Bool
    }

    /// Lance le programme et attend sa fin. Lève `CancellationError` si la Task est annulée (le programme est alors arrêté :
    /// SIGTERM, puis SIGKILL après `killGrace`, ainsi que ses éventuels sous-processus).
    static func run(_ cli: URL, arguments: [String], stdin: Data, timeout: TimeInterval, directory: URL,
                    environment: [String: String], tuning: Tuning) async throws -> ProcessOutput {
        let job = ProgramRun(cli: cli, arguments: arguments, stdin: stdin, timeout: timeout, directory: directory,
                             environment: environment, killGrace: tuning.killGrace, pipeGrace: tuning.pipeGrace,
                             maxOutput: tuning.maxOutputBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessOutput, Error>) in job.start(cont) }
        } onCancel: {
            job.cancel()
        }
    }

    /// Petit appel (`--version`, `auth status`) dans un dossier vide ; nil si le programme ne se lance pas.
    private static func runSimple(_ cli: URL, _ arguments: [String], timeout: TimeInterval, tuning: Tuning) async -> ProcessOutput? {
        guard let folder = try? makeWorkFolder(root: tuning.workRoot) else { return nil }
        defer { try? FileManager.default.removeItem(at: folder) }
        let env = sanitizedEnvironment(base: tuning.environment ?? ProcessInfo.processInfo.environment, cli: cli)
        return try? await run(cli, arguments: arguments, stdin: Data(), timeout: timeout, directory: folder, environment: env, tuning: tuning)
    }
}

// MARK: - Mode « Révision » : sorties structurées génériques

extension ClaudeCodeEngine: StructuredGenerator {
    var supportsImages: Bool { true }

    /// Envoie `userText` (précédé des images de pages, en JPEG base64) et renvoie le JSON de la réponse structurée.
    /// Mêmes garde-fous que `complete` (environnement assaini, délai, annulation, relances), avec le délai `tuning.generateTimeout`.
    func generate(system: String, userText: String, images: [Data], schema: [String: Any]) async throws -> String {
        var content: [[String: Any]] = []
        for jpeg in images where !jpeg.isEmpty {
            let source: [String: Any] = ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]
            content.append(["type": "image", "source": source])
        }
        content.append(["type": "text", "text": userText])
        return try await generate(system: system, content: content, schema: schema, timeout: tuning.generateTimeout)
    }
}

// MARK: - Mécanique du processus (privé à ce fichier)

fileprivate final class StopFlag {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Un sous-processus repéré avec son heure de démarrage : on ne lui envoie un signal que s'il s'agit toujours du même.
fileprivate struct TrackedProcess: Equatable {
    let pid: pid_t
    let startSec: UInt64
    let startUsec: UInt64
    func send(_ signal: Int32) {
        guard let t = ProcessTree.startTime(of: pid), t.0 == startSec, t.1 == startUsec else { return }
        kill(pid, signal)
    }
}

fileprivate enum ProcessTree {
    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 512)
        let n = buffer.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return [] }
        return buffer.prefix(min(Int(n), buffer.count)).filter { $0 > 0 }
    }

    static func startTime(of pid: pid_t) -> (UInt64, UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (info.pbi_start_tvsec, info.pbi_start_tvusec)
    }

    /// Tous les descendants (enfants, petits-enfants…) du processus `root`, sans lui.
    static func descendants(of root: pid_t) -> [TrackedProcess] {
        var found: [TrackedProcess] = []
        var level: [pid_t] = [root]
        var seen: Set<pid_t> = [root]
        var depth = 0
        while !level.isEmpty, depth < 8, found.count < 256 {
            var next: [pid_t] = []
            for p in level {
                for c in children(of: p) where !seen.contains(c) {
                    seen.insert(c)
                    next.append(c)
                    if let t = startTime(of: c) { found.append(TrackedProcess(pid: c, startSec: t.0, startUsec: t.1)) }
                }
            }
            level = next
            depth += 1
        }
        return found
    }
}

/// Lit un tube en continu (jamais d'inter-blocage au-delà de la taille du tube) et note la fin de fichier.
fileprivate final class PipeCollector {
    private let fd: Int32
    private let cap: Int
    private let source: DispatchSourceRead
    private let onEOF: () -> Void
    private(set) var data = Data()
    private(set) var reachedEOF = false

    init(fd: Int32, queue: DispatchQueue, cap: Int, onEOF: @escaping () -> Void) {
        self.fd = fd
        self.cap = cap
        self.onEOF = onEOF
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in drain() }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    func cancel() { source.cancel() }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                let room = cap - data.count
                if room > 0 { data.append(contentsOf: buffer[0..<min(n, room)]) }
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            markEOF()
            return
        }
    }

    private func markEOF() {
        guard !reachedEOF else { return }
        reachedEOF = true
        source.cancel()
        onEOF()
    }
}

fileprivate enum ProgramError: Error { case cannotLaunch }

/// Un lancement : tubes, écriture de stdin dans une tâche à part, lecture continue de stdout et stderr, délai maximal,
/// arrêt (SIGTERM puis SIGKILL, sous-processus compris). Tout l'état est touché depuis la seule file `queue`.
fileprivate final class ProgramRun {
    private static let launchLock = NSLock()      // un seul lancement à la fois : les tubes d'un appel ne passent pas dans l'enfant d'un autre

    private let queue = DispatchQueue(label: "ClaudeCodeEngine.programme")
    private let process = Process()
    private let cli: URL
    private let arguments: [String]
    private let stdinData: Data
    private let timeout: TimeInterval
    private let directory: URL
    private let environment: [String: String]
    private let killGrace: TimeInterval
    private let pipeGrace: TimeInterval
    private let maxOutput: Int
    private let stopWriting = StopFlag()

    private var continuation: CheckedContinuation<ClaudeCodeEngine.ProcessOutput, Error>?
    private var out: PipeCollector?
    private var err: PipeCollector?
    private var pid: pid_t = 0
    private var cancelRequested = false
    private var started = false
    private var launched = false
    private var done = false
    private var exited = false
    private var exitCode: Int32 = 0
    private var uncaughtSignal = false
    private var timedOut = false
    private var killStarted = false
    private var timeoutItem: DispatchWorkItem?
    private var graceItem: DispatchWorkItem?
    private var seen: [TrackedProcess] = []      // sous-processus aperçus pendant l'appel

    init(cli: URL, arguments: [String], stdin: Data, timeout: TimeInterval, directory: URL, environment: [String: String],
         killGrace: TimeInterval, pipeGrace: TimeInterval, maxOutput: Int) {
        self.cli = cli
        self.arguments = arguments
        self.stdinData = stdin
        self.timeout = timeout
        self.directory = directory
        self.environment = environment
        self.killGrace = killGrace
        self.pipeGrace = pipeGrace
        self.maxOutput = maxOutput
    }

    func start(_ cont: CheckedContinuation<ClaudeCodeEngine.ProcessOutput, Error>) {
        queue.async { self.launch(cont) }
    }

    func cancel() {
        queue.async {
            self.cancelRequested = true
            if self.started { self.beginKill() }
        }
    }

    // MARK: Lancement

    private static func makePipe() -> (read: Int32, write: Int32)? {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        return (fds[0], fds[1])
    }

    private func launch(_ cont: CheckedContinuation<ClaudeCodeEngine.ProcessOutput, Error>) {
        if cancelRequested { cont.resume(throwing: CancellationError()); return }
        started = true
        continuation = cont

        ProgramRun.launchLock.lock()
        defer { ProgramRun.launchLock.unlock() }

        var made: [(read: Int32, write: Int32)] = []
        for _ in 0..<3 { if let p = ProgramRun.makePipe() { made.append(p) } }
        guard made.count == 3 else {
            for p in made { close(p.read); close(p.write) }
            failToLaunch()
            return
        }
        let (inPipe, outPipe, errPipe) = (made[0], made[1], made[2])
        _ = fcntl(inPipe.write, F_SETNOSIGPIPE, 1)    // écrire dans un programme déjà parti renvoie EPIPE au lieu de tuer l'app

        process.executableURL = cli
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle(fileDescriptor: inPipe.read, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: outPipe.write, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: errPipe.write, closeOnDealloc: false)
        process.terminationHandler = { [self] p in
            let status = p.terminationStatus, bySignal = p.terminationReason == .uncaughtSignal
            queue.async { self.processExited(status: status, bySignal: bySignal) }
        }
        do {
            try process.run()
        } catch {
            for p in made { close(p.read); close(p.write) }
            process.terminationHandler = nil
            failToLaunch()
            return
        }
        launched = true
        pid = process.processIdentifier
        // Côté « programme » des tubes : fermé ici, sinon la fin de fichier n'arriverait jamais.
        close(inPipe.read)
        close(outPipe.write)
        close(errPipe.write)

        out = PipeCollector(fd: outPipe.read, queue: queue, cap: maxOutput) { [self] in evaluate() }
        err = PipeCollector(fd: errPipe.read, queue: queue, cap: maxOutput) { [self] in evaluate() }
        watchDescendants()

        let payload = stdinData, writeFD = inPipe.write, stop = stopWriting
        DispatchQueue.global(qos: .userInitiated).async { ProgramRun.writeAll(payload, to: writeFD, stop: stop) }

        let item = DispatchWorkItem { [self] in
            guard !done else { return }
            timedOut = true
            beginKill()
        }
        timeoutItem = item
        queue.asyncAfter(deadline: .now() + max(0.05, timeout), execute: item)
    }

    private func failToLaunch() {
        done = true
        let cont = continuation
        continuation = nil
        cont?.resume(throwing: ProgramError.cannotLaunch)
    }

    /// Écrit tout stdin (sans jamais bloquer pour toujours), puis le ferme. Si le programme ne lit plus, on s'arrête.
    private static func writeAll(_ data: Data, to fd: Int32, stop: StopFlag) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count, !stop.isSet {
                let n = write(fd, base + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&p, 1, 100)
                    continue
                }
                break      // EPIPE ou autre : le programme n'écoute plus
            }
        }
        close(fd)
    }

    // MARK: Fin du programme

    private func processExited(status: Int32, bySignal: Bool) {
        exited = true
        exitCode = status
        uncaughtSignal = bySignal
        // Un sous-processus resté vivant peut garder les tubes ouverts : on n'attend pas leur fin indéfiniment.
        let item = DispatchWorkItem { [self] in
            guard !done else { return }
            finish()
        }
        graceItem = item
        queue.asyncAfter(deadline: .now() + max(0.05, pipeGrace), execute: item)
        evaluate()
    }

    private func evaluate() {
        guard !done, exited, out?.reachedEOF == true, err?.reachedEOF == true else { return }
        finish()
    }

    private func finish() {
        guard !done else { return }
        done = true
        timeoutItem?.cancel()
        graceItem?.cancel()
        stopWriting.set()
        out?.cancel()
        err?.cancel()
        process.terminationHandler = nil
        for p in seen { p.send(SIGKILL) }       // un sous-processus resté vivant après l'appel serait un orphelin : on l'arrête
        let result = ClaudeCodeEngine.ProcessOutput(stdout: out?.data ?? Data(), stderr: err?.data ?? Data(), exitCode: exitCode,
                                                    uncaughtSignal: uncaughtSignal, timedOut: timedOut)
        let cont = continuation
        continuation = nil
        if cancelRequested { cont?.resume(throwing: CancellationError()) } else { cont?.resume(returning: result) }
    }

    // MARK: Arrêt

    /// Note les sous-processus pendant que le programme tourne : une fois le parent parti, on ne pourrait plus les retrouver.
    private func watchDescendants() {
        guard launched, !done else { return }
        for p in ProcessTree.descendants(of: pid) where !seen.contains(p) { seen.append(p) }
        if seen.count > 512 { seen.removeFirst(seen.count - 512) }
        queue.asyncAfter(deadline: .now() + 0.25) { [self] in watchDescendants() }
    }

    /// Annulation ou délai dépassé : SIGTERM au programme et à ses sous-processus, puis SIGKILL s'ils sont encore là après `killGrace`.
    private func beginKill() {
        guard launched, !killStarted, !done else { return }
        killStarted = true
        var tree = ProcessTree.descendants(of: pid)       // relevé AVANT l'arrêt : ensuite ils n'auraient plus de parent
        for p in seen where !tree.contains(p) { tree.append(p) }
        let victim = pid
        if !exited { kill(victim, SIGTERM) }
        for p in tree { p.send(SIGTERM) }
        queue.asyncAfter(deadline: .now() + max(0.05, killGrace)) { [self] in
            if !exited { kill(victim, SIGKILL) }
            for p in tree { p.send(SIGKILL) }
        }
    }
}

#endif
