import Foundation

// Moteur Claude : API Messages d'Anthropic, en HTTP direct (il n'existe pas de SDK Swift officiel).
//
// Une requête de page :
//  - POST {baseURL}/v1/messages, avec les en-têtes content-type, x-api-key et anthropic-version ;
//  - un seul message utilisateur : [image JPEG de la page avec les numéros, texte des zones] ;
//  - la réponse est imposée en JSON par output_config.format (l'effort « medium » est dans le même objet :
//    la documentation prévoit les deux ensemble) ;
//  - jamais temperature / top_p / top_k, thinking, prefill ni tool_choice forcé : ces modèles les refusent (400) ;
//  - Opus et Sonnet reçoivent `fallbacks: "default"` (reprise côté serveur après un refus de sécurité) avec l'en-tête
//    bêta correspondant ; Haiku jamais (400).
// Rien n'est écrit dans un journal : ni la clé, ni les images, ni les réponses.
// Tests (faux serveur local, aucun appel réseau réel) : Tools/Tests/Claude/run.sh

final class ClaudeEngine: CompletionEngine {
    struct ModelChoice: Identifiable {
        let id: String
        let label: String
        let hint: String
        /// Libellé court en un mot (« Précis », « Équilibré », « Économique »).
        var tier: String = ""
        /// Prix en dollars par million de jetons (documentation Anthropic ; Haiku : jusqu'à 100 000 jetons par requête).
        var inputPricePerMillion: Double = 0
        var outputPricePerMillion: Double = 0

        /// Coût estimé d'une page : requête typique de ~3 000 jetons en entrée et ~1 500 en sortie (réflexion comprise).
        var estimatedPageCostUSD: Double {
            (3000 * inputPricePerMillion + 1500 * outputPricePerMillion) / 1_000_000
        }

        /// Ex. « environ 0,04 $ par page » (« moins de 0,01 $ » sous le centime).
        var costNote: String {
            let c = estimatedPageCostUSD
            if c < 0.01 { return "moins de 0,01 $ par page" }
            return "environ " + String(format: "%.2f", c).replacingOccurrences(of: ".", with: ",") + " $ par page"
        }
    }

    static let models: [ModelChoice] = [
        ModelChoice(id: "claude-opus-5-5", label: "Claude Opus 5.5", hint: "le plus précis",
                    tier: "Précis", inputPricePerMillion: 4, outputPricePerMillion: 20),
        ModelChoice(id: "claude-sonnet-5-5", label: "Claude Sonnet 5.5", hint: "très bon, environ 2 fois moins cher",
                    tier: "Équilibré", inputPricePerMillion: 2, outputPricePerMillion: 10),
        ModelChoice(id: "claude-haiku-5-5", label: "Claude Haiku 5.5", hint: "le moins cher, moins précis",
                    tier: "Économique", inputPricePerMillion: 0.10, outputPricePerMillion: 0.50),
    ]
    static let defaultModel = "claude-opus-5-5"
    static let defaultBaseURL = URL(string: "https://api.anthropic.com")!

    let displayName: String
    let usesImages = true
    let maxConcurrentPages = 3
    private let apiKey: String
    private let model: String
    private let baseURL: URL

    /// Délais et attentes. Les valeurs par défaut sont celles de l'application ; seuls les tests les raccourcissent.
    struct Tuning {
        var requestTimeout: TimeInterval = 180   // délai d'une requête de page
        var generateTimeout: TimeInterval = 420  // délai d'une requête de révision (fiche, questions : sortie plus longue)
        var checkTimeout: TimeInterval = 30      // délai de la vérification de la clé
        var backoffBase: TimeInterval = 1        // 408 / 5xx / 529 : 1 s puis 2 s
        var rateLimitBase: TimeInterval = 2      // 429 sans en-tête retry-after : 2 s puis 4 s
        var maxWait: TimeInterval = 30           // plafond de toute attente avant un nouvel essai
    }
    var tuning = Tuning()

    // MARK: - Constantes de l'API

    private static let apiVersion = "2026-10-21"
    private static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// Modèles qui acceptent `fallbacks` ; Haiku répond 400 si on le lui envoie.
    private static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-sonnet-5-5"]
    /// max_tokens d'une page : 8000, puis 16000 si la réponse est coupée.
    private static let pageLimits = Limits(first: 8000, largest: 16000, truncated:
        "La réponse de Claude a été coupée avant la fin (la page contient trop de zones "
        + "ou de texte). Réessaie ; si le problème continue, désactive quelques zones de cette page et recommence.")
    /// max_tokens d'une révision : 12000, puis 16000 (la documentation demande de passer en streaming au-delà de ~16 000).
    private static let revisionLimits = Limits(first: 12000, largest: 16000, truncated:
        "La réponse de Claude a été coupée avant la fin (le document est trop long pour une seule demande). "
        + "Réessaie avec un document plus court ou moins de pages à la fois.")

    private struct Limits {
        let first: Int
        let largest: Int
        let truncated: String
    }
    /// 429 : trois essais au total. 408 / 5xx / 529 : deux réessais.
    private static let rateLimitAttempts = 3
    private static let transientRetries = 2

    // MARK: - État partagé entre les pages traitées en parallèle

    /// Retient (avec un verrou) que le serveur n'accepte pas `fallbacks` : les pages suivantes ne le renvoient plus.
    private final class Memory {
        private let lock = NSLock()
        private var fallbacksRefused = false
        var refusesFallbacks: Bool { lock.lock(); defer { lock.unlock() }; return fallbacksRefused }
        func refuseFallbacks() { lock.lock(); fallbacksRefused = true; lock.unlock() }
    }
    private let memory = Memory()

    /// Refuse toute redirection : la clé ne doit jamais partir vers une autre adresse que celle choisie.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private let session: URLSession

    private static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral      // ni cache, ni cookies, rien sur le disque
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.waitsForConnectivity = false                 // hors ligne : l'erreur arrive tout de suite
        c.timeoutIntervalForRequest = 180
        c.timeoutIntervalForResource = 600
        c.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
    }

    // MARK: - Initialisation

    init(apiKey: String, model: String, baseURL: URL = ClaudeEngine.defaultBaseURL) {
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = cleanModel
        self.baseURL = baseURL
        self.displayName = ClaudeEngine.models.first { $0.id == cleanModel }?.label ?? cleanModel
        self.session = ClaudeEngine.makeSession()
    }

    deinit { session.finishTasksAndInvalidate() }

    // MARK: - Contrat CompletionEngine

    func complete(_ request: PageRequest) async throws -> [ZoneAnswer] {
        if request.zones.isEmpty { return [] }
        var content: [[String: Any]] = []
        if let jpeg = request.markedImageJPEG, !jpeg.isEmpty {
            let source: [String: Any] = ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]
            content.append(["type": "image", "source": source])
        }
        content.append(["type": "text", "text": Prompts.completionUserText(request)])
        let text = try await structuredReply(system: Prompts.completionSystem, content: content,
                                             schema: Prompts.completionSchema)
        return try Self.decodeCompletion(text, expected: Set(request.zones.map { $0.number }))
    }

    func humanize(_ items: [HumanizeItem]) async throws -> [Int: String] {
        guard !items.isEmpty else { return [:] }
        let content: [[String: Any]] = [["type": "text", "text": Prompts.humanizeUserText(items)]]
        let text = try await structuredReply(system: Prompts.humanizeSystem, content: content,
                                             schema: Prompts.humanizeSchema)
        return try Self.decodeHumanization(text, expected: Set(items.map { $0.id }))
    }

    /// Vérifie la clé avec une très petite requête. nil = OK, sinon message d'erreur en français.
    static func checkKey(apiKey: String, model: String, baseURL: URL = ClaudeEngine.defaultBaseURL) async -> String? {
        let engine = ClaudeEngine(apiKey: apiKey, model: model, baseURL: baseURL)
        return await engine.ping()
    }

    private func ping() async -> String? {
        do {
            try validateConfiguration()
            let message: [String: Any] = ["role": "user", "content": "Réponds seulement : ok"]
            let body = try Self.encode(["model": model, "max_tokens": 16, "messages": [message]] as [String: Any])
            let reply = try await send(body, fallbackBeta: false, retry: false,
                                       timeout: min(tuning.checkTimeout, tuning.requestTimeout))
            return reply.status == 200 ? nil : httpError(reply).errorDescription
        } catch let e as EngineError {
            return e.errorDescription
        } catch is CancellationError {
            return "La vérification de la clé a été interrompue."
        } catch {
            return "La vérification de la clé a échoué. Vérifie ta connexion puis réessaie."
        }
    }

    // MARK: - Une requête structurée (complétion ou humanisation)

    /// Envoie un message utilisateur et renvoie le texte JSON de la réponse.
    /// Gère : refus de sécurité, réponse coupée (max_tokens doublé une fois) et refus du champ `fallbacks`.
    private func structuredReply(system: String, content: [[String: Any]], schema: [String: Any],
                                 limits: Limits? = nil, timeout: TimeInterval? = nil) async throws -> String {
        try validateConfiguration()
        let limits = limits ?? Self.pageLimits
        let timeout = timeout ?? tuning.requestTimeout
        var maxTokens = limits.first
        var useFallbacks = Self.fallbackModels.contains(model) && !memory.refusesFallbacks
        var droppedFallbacks = false    // `fallbacks` vient d'être retiré à cause d'un 400
        var doubled = false             // la relance avec plus de place a déjà eu lieu
        while true {
            try Task.checkCancellation()
            let body = try structuredBody(system: system, content: content, schema: schema,
                                          maxTokens: maxTokens, fallbacks: useFallbacks)
            let reply = try await send(body, fallbackBeta: useFallbacks, retry: true, timeout: timeout)

            if reply.status == 200 {
                // La requête passe sans `fallbacks` : c'était bien lui le problème, inutile de le renvoyer ensuite.
                if droppedFallbacks { memory.refuseFallbacks() }
                let answer = try Self.parseSuccess(reply.data)
                switch answer.stopReason {
                case "refusal":
                    throw EngineError.refused("Claude a refusé de répondre pour cette page (filtre de sécurité d'Anthropic, "
                        + "qui se trompe parfois sur un simple cours). Réessaie, choisis un autre modèle dans les réglages, "
                        + "ou remplis cette page à la main.")
                case "max_tokens":
                    if !doubled && maxTokens < limits.largest {
                        maxTokens = min(maxTokens * 2, limits.largest)
                        doubled = true
                        continue
                    }
                    throw EngineError.invalidResponse(limits.truncated)
                case "model_context_window_exceeded":
                    throw EngineError.invalidResponse("Ce contenu contient trop de texte pour être traité en une fois par Claude. "
                        + "Réduis le nombre de pages ou de zones, puis recommence.")
                default:
                    return answer.text
                }
            }

            // Le serveur n'accepte pas `fallbacks` ou son en-tête bêta : une seule nouvelle tentative sans les deux.
            if reply.status == 400, useFallbacks,
               let detail = Self.apiMessage(from: reply.data)?.lowercased(),
               detail.contains("fallback") || detail.contains("beta") {
                useFallbacks = false
                droppedFallbacks = true
                continue
            }
            throw httpError(reply)
        }
    }

    private func structuredBody(system: String, content: [[String: Any]], schema: [String: Any],
                                maxTokens: Int, fallbacks: Bool) throws -> Data {
        let format: [String: Any] = ["type": "json_schema", "schema": schema]
        let message: [String: Any] = ["role": "user", "content": content]
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [message],
            "output_config": ["effort": "medium", "format": format] as [String: Any],
        ]
        if fallbacks { body["fallbacks"] = "default" }
        return try Self.encode(body)
    }

    /// JSON à clés triées : deux requêtes identiques donnent exactement les mêmes octets (le schéma imposé est
    /// ainsi reconnu d'une requête à l'autre).
    private static func encode(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys])
        } catch {
            throw EngineError.other("Impossible de préparer la requête pour Claude.")
        }
    }

    // MARK: - Configuration

    private func validateConfiguration() throws {
        if apiKey.isEmpty {
            throw EngineError.unavailable("Aucune clé API Anthropic n'est enregistrée. Ouvre les réglages, colle ta clé puis recommence.")
        }
        // Une clé collée avec un guillemet, une espace ou un retour à la ligne ne peut pas servir d'en-tête HTTP.
        if apiKey.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value > 0x7E }) {
            throw EngineError.auth("La clé API contient un caractère inattendu (espace, guillemet ou retour à la ligne collé par erreur). "
                + "Copie-la de nouveau depuis la console Anthropic.")
        }
        if model.isEmpty {
            throw EngineError.unavailable("Aucun modèle Claude n'est choisi. Choisis un modèle dans les réglages.")
        }
        if !Self.isAllowedBaseURL(baseURL) {
            throw EngineError.unavailable("L'adresse du service Claude n'est pas valide : elle doit commencer par https:// "
                + "(http:// n'est accepté que pour un test en local).")
        }
    }

    /// https partout ; http seulement vers 127.0.0.1 ou localhost (tests).
    static func isAllowedBaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && (host == "127.0.0.1" || host == "localhost")
    }

    private var endpoint: URL {
        baseURL.appendingPathComponent("v1").appendingPathComponent("messages")
    }

    // MARK: - Transport

    private struct Reply {
        let status: Int
        let data: Data
        let requestID: String?
        let retryAfter: String?
    }

    /// Envoie la requête. Avec `retry`, réessaie seul : 429 (3 essais au total), 408 / 5xx / 529 et connexion coupée
    /// (2 réessais, attente exponentielle) ; `retry-after` est respecté quand le serveur l'envoie. Renvoie la dernière
    /// réponse HTTP, quel que soit son statut ; seules les erreurs réseau et l'annulation sont des exceptions.
    private func send(_ body: Data, fallbackBeta: Bool, retry: Bool, timeout: TimeInterval) async throws -> Reply {
        var rateLimited = 0     // réponses 429 déjà reçues
        var transient = 0       // réessais déjà faits (408, 5xx, 529, connexion coupée)
        while true {
            try Task.checkCancellation()
            var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
            if fallbackBeta { req.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
            req.httpBody = body

            let http: HTTPURLResponse
            let data: Data
            do {
                let (d, r) = try await session.data(for: req)
                guard let h = r as? HTTPURLResponse else {
                    throw EngineError.invalidResponse("Réponse inattendue du serveur. Réessaie dans un instant.")
                }
                http = h
                data = d
            } catch let e as URLError {
                if Task.isCancelled { throw CancellationError() }
                if retry, e.code == .networkConnectionLost, transient < Self.transientRetries {
                    transient += 1
                    try await pause(waitAfter(nil, retryNumber: transient, rateLimited: false))
                    continue
                }
                throw Self.networkError(e, timeout: timeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as EngineError {
                throw e
            } catch {
                throw EngineError.network("Erreur réseau inattendue. Vérifie ta connexion puis recommence.")
            }

            let reply = Reply(status: http.statusCode, data: data, requestID: http.value(forHTTPHeaderField: "request-id"),
                              retryAfter: http.value(forHTTPHeaderField: "retry-after"))
            guard retry else { return reply }
            if reply.status == 429 {
                rateLimited += 1
                if rateLimited < Self.rateLimitAttempts {
                    try await pause(waitAfter(reply.retryAfter, retryNumber: rateLimited, rateLimited: true))
                    continue
                }
            } else if reply.status == 408 || reply.status == 529 || reply.status >= 500 {
                if transient < Self.transientRetries {
                    transient += 1
                    try await pause(waitAfter(reply.retryAfter, retryNumber: transient, rateLimited: false))
                    continue
                }
            }
            return reply
        }
    }

    private func waitAfter(_ retryAfter: String?, retryNumber: Int, rateLimited: Bool) -> TimeInterval {
        Self.waitTime(retryAfter: retryAfter, retryNumber: retryNumber, rateLimited: rateLimited,
                      tuning: tuning, jitter: Double.random(in: 1.0...1.15))
    }

    private func pause(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    }

    /// Durée d'attente avant le prochain essai : retry-after du serveur s'il existe, sinon attente exponentielle.
    /// Toujours plafonnée à `tuning.maxWait`.
    static func waitTime(retryAfter: String?, retryNumber: Int, rateLimited: Bool, tuning: Tuning,
                         jitter: Double = 1) -> TimeInterval {
        if let header = retryAfter, let seconds = parseRetryAfter(header) {
            return min(tuning.maxWait, max(0.25, seconds) * jitter)
        }
        let base = rateLimited ? tuning.rateLimitBase : tuning.backoffBase
        return min(tuning.maxWait, base * pow(2, Double(max(retryNumber, 1) - 1)) * jitter)
    }

    /// `retry-after` : un nombre de secondes, ou (rarement) une date HTTP.
    private static func parseRetryAfter(_ value: String) -> TimeInterval? {
        let v = value.trimmingCharacters(in: .whitespaces)
        if let s = Double(v), s.isFinite { return max(0, s) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = f.date(from: v) { return max(0, date.timeIntervalSinceNow) }
        return nil
    }

    // MARK: - Lecture de la réponse

    private static let badFormatMessage = "La réponse de Claude n'est pas dans le format attendu. "
        + "Réessaie ; si le problème continue, choisis un autre modèle dans les réglages."

    /// Texte (blocs `text` concaténés) et raison d'arrêt d'une réponse 200. Les autres blocs (thinking, fallback…) sont ignorés.
    private static func parseSuccess(_ data: Data) throws -> (stopReason: String?, text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.invalidResponse("Le serveur n'a pas renvoyé une réponse de Claude lisible (un portail Wi-Fi, "
                + "un proxy ou un filtre réseau peut en être la cause). Vérifie ta connexion puis réessaie.")
        }
        let blocks = obj["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
        return (obj["stop_reason"] as? String, text)
    }

    /// Objet JSON de la réponse (tolère un bloc de code Markdown autour, que le format imposé ne devrait pas produire).
    private static func jsonObject(from raw: String) -> [String: Any]? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "^```[A-Za-z]*\\s*", with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\s*```$", with: "", options: .regularExpression)
        }
        guard let d = t.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func intValue(_ v: Any?) -> Int? {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return (d == d.rounded() && abs(d) < 1e9) ? Int(d) : nil
        }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func zoneKind(_ raw: String) -> ZoneKind {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return ZoneKind(rawValue: key) ?? .question
    }

    /// Décode {"zones":[{"numero","type","texte"}]}. Ignore les numéros absents de la requête, garde la première
    /// réponse d'un numéro en double, traite un type inconnu comme une question ouverte.
    static func decodeCompletion(_ raw: String, expected: Set<Int>) throws -> [ZoneAnswer] {
        guard let root = jsonObject(from: raw), let rows = root["zones"] as? [Any] else {
            throw EngineError.invalidResponse(badFormatMessage)
        }
        var seen = Set<Int>()
        var answers: [ZoneAnswer] = []
        for case let row as [String: Any] in rows {
            guard let number = intValue(row["numero"]), expected.contains(number), !seen.contains(number) else { continue }
            seen.insert(number)
            let kind = zoneKind(row["type"] as? String ?? "")
            let text = kind == .ignorer ? "" : (row["texte"] as? String ?? "")
            answers.append(ZoneAnswer(number: number, kind: kind, text: text))
        }
        if answers.isEmpty && !expected.isEmpty {
            throw EngineError.invalidResponse("Claude n'a donné de réponse pour aucune des zones de cette page. "
                + "Réessaie ; si le problème continue, choisis un autre modèle dans les réglages.")
        }
        return answers.sorted { $0.number < $1.number }
    }

    /// Décode {"reponses":[{"id","texte"}]} en [id: texte]. Ignore les id inconnus et les textes vides
    /// (une entrée manquante signifie « garder la réponse d'origine »).
    static func decodeHumanization(_ raw: String, expected: Set<Int>) throws -> [Int: String] {
        guard let root = jsonObject(from: raw), let rows = root["reponses"] as? [Any] else {
            throw EngineError.invalidResponse(badFormatMessage)
        }
        var seen = Set<Int>()
        var out: [Int: String] = [:]
        for case let row as [String: Any] in rows {
            guard let id = intValue(row["id"]), expected.contains(id), !seen.contains(id) else { continue }
            seen.insert(id)
            if let text = row["texte"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out[id] = text
            }
        }
        if seen.isEmpty && !expected.isEmpty {
            throw EngineError.invalidResponse("Claude n'a réécrit aucune des réponses envoyées. "
                + "Les réponses d'origine sont conservées ; tu peux réessayer.")
        }
        return out
    }

    // MARK: - Erreurs

    /// Message d'erreur de l'API (`error.message`), sur une ligne et raccourci.
    private static func apiMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any], let m = err["message"] as? String else { return nil }
        let flat = m.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.isEmpty { return nil }
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }

    /// Retire d'un texte venu du réseau la clé API (et tout ce qui y ressemble) avant de l'afficher.
    private func redacted(_ text: String) -> String {
        var t = text
        if !apiKey.isEmpty { t = t.replacingOccurrences(of: apiKey, with: "…") }
        return t.replacingOccurrences(of: "sk-ant-[A-Za-z0-9_\\-]{4,}", with: "…", options: .regularExpression)
    }

    private func httpError(_ r: Reply) -> EngineError {
        let detail = Self.apiMessage(from: r.data).map(redacted)
        let ref = r.requestID.map { " (référence : \($0))" } ?? ""
        let billing = "Le compte Anthropic n'a plus de crédit ou a un problème de facturation. "
            + "Vérifie la facturation dans la console Anthropic, puis recommence."
        switch r.status {
        case 401:
            return .auth("Anthropic a refusé la clé API (clé invalide, supprimée ou mal copiée). "
                + "Vérifie la clé dans les réglages ou crée-en une nouvelle dans la console Anthropic, puis recommence.")
        case 403:
            return .auth("Anthropic refuse l'accès avec cette clé (droits insuffisants pour ce modèle ou pour ce compte, "
                + "ou vérification demandée par Anthropic). Vérifie ton compte dans la console Anthropic ou choisis un autre modèle "
                + "dans les réglages." + (detail.map { " Message d'Anthropic : « \($0) »" } ?? ""))
        case 402:
            return .unavailable(billing)
        case 404:
            return .other("Le modèle « \(model) » est introuvable ou n'est pas accessible avec cette clé. "
                + "Choisis un autre modèle dans les réglages.")
        case 413:
            return .other("La page est trop volumineuse pour être envoyée à Claude. Désactive quelques zones ou essaie une autre page.\(ref)")
        case 429:
            return .rateLimited("Anthropic limite le nombre de demandes (trop de requêtes en peu de temps). "
                + "Attends une minute puis recommence.")
        case 529:
            return .network("Les serveurs d'Anthropic sont surchargés en ce moment (erreur 529). Réessaie dans quelques minutes.\(ref)")
        case 408:
            return .network("Anthropic n'a pas répondu à temps (erreur 408). Réessaie dans un instant.\(ref)")
        case 500...599:
            return .network("Les serveurs d'Anthropic rencontrent un problème (erreur \(r.status)). Réessaie dans quelques minutes.\(ref)")
        case 400:
            // Crédit épuisé : Anthropic le signale parfois par un 400 plutôt que par un 402. Tout échouera de la même façon.
            if detail?.lowercased().contains("credit balance") == true { return .unavailable(billing) }
            return .other("Anthropic a refusé la demande : « \(detail ?? "requête invalide") ». "
                + "Réessaie ; si le problème continue, essaie une autre page ou un autre modèle dans les réglages.\(ref)")
        case 300...399:
            return .other("Réponse inattendue du serveur (redirection, code \(r.status)). Vérifie l'adresse du service dans les réglages.")
        default:
            let more = detail.map { " : « \($0) »" } ?? ""
            return .other("Réponse inattendue d'Anthropic (erreur \(r.status))\(more).\(ref)")
        }
    }

    static func networkError(_ e: URLError, timeout: TimeInterval) -> EngineError {
        switch e.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return .network("Pas de connexion à Internet. Vérifie le Wi-Fi ou le câble réseau, puis recommence.")
        case .timedOut:
            return .network("Claude n'a pas répondu dans le délai prévu (\(Int(timeout)) secondes). "
                + "Vérifie ta connexion puis recommence ; si la page est très chargée, réessaie un peu plus tard.")
        case .networkConnectionLost:
            return .network("La connexion avec Anthropic a été coupée en cours de route. Vérifie ta connexion puis recommence.")
        case .cannotFindHost, .dnsLookupFailed:
            return .network("Impossible de trouver le serveur d'Anthropic (problème de connexion ou de DNS). Vérifie ta connexion puis recommence.")
        case .cannotConnectToHost:
            return .network("Impossible de joindre le serveur d'Anthropic. Vérifie ta connexion (un VPN ou un pare-feu peut la bloquer) puis recommence.")
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .network("La connexion sécurisée (TLS) avec Anthropic a échoué. Un VPN, un proxy ou un filtre du réseau peut en être la cause ; "
                + "vérifie aussi que la date et l'heure du Mac sont justes.")
        case .cancelled:
            return .network("La demande envoyée à Claude a été interrompue. Recommence quand tu veux.")
        default:
            return .network("Erreur réseau inattendue (code \(e.code.rawValue)). Vérifie ta connexion puis recommence.")
        }
    }
}

// MARK: - Mode « Révision » : sorties structurées génériques

extension ClaudeEngine: StructuredGenerator {
    var supportsImages: Bool { true }

    /// Envoie `userText` (précédé des images de pages, en JPEG base64) et renvoie le JSON de la réponse structurée.
    /// Mêmes réessais, mêmes erreurs en français et même sécurité que `complete`.
    func generate(system: String, userText: String, images: [Data], schema: [String: Any]) async throws -> String {
        var content: [[String: Any]] = []
        for jpeg in images where !jpeg.isEmpty {
            let source: [String: Any] = ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]
            content.append(["type": "image", "source": source])
        }
        content.append(["type": "text", "text": userText])
        return try await structuredReply(system: system, content: content, schema: Self.supportedSchema(schema),
                                         limits: Self.revisionLimits, timeout: tuning.generateTimeout)
    }

    /// Retire d'un schéma ce que les sorties structurées n'acceptent pas (bornes numériques, longueurs de chaînes,
    /// contraintes de tableau complexes : la documentation précise que les SDK le font aussi) et impose
    /// `additionalProperties: false` à chaque objet.
    static func supportedSchema(_ schema: [String: Any]) -> [String: Any] {
        let unsupported: Set<String> = ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
                                        "minLength", "maxLength", "maxItems", "uniqueItems", "minContains", "maxContains"]
        func clean(_ node: Any) -> Any {
            if let array = node as? [Any] { return array.map(clean) }
            guard var dict = node as? [String: Any] else { return node }
            for key in unsupported { dict.removeValue(forKey: key) }
            if let n = (dict["minItems"] as? NSNumber)?.intValue, n > 1 { dict.removeValue(forKey: "minItems") }
            if let props = dict["properties"] as? [String: Any] {
                dict["properties"] = props.mapValues(clean)       // les clés sont des noms de champs, pas des mots-clés
            }
            for key in ["items", "anyOf", "allOf", "$defs", "definitions"] {
                if let v = dict[key] {
                    if (key == "$defs" || key == "definitions"), let defs = v as? [String: Any] {
                        dict[key] = defs.mapValues(clean)
                    } else {
                        dict[key] = clean(v)
                    }
                }
            }
            if (dict["type"] as? String) == "object" || dict["properties"] != nil { dict["additionalProperties"] = false }
            return dict
        }
        return (clean(schema) as? [String: Any]) ?? schema
    }
}
