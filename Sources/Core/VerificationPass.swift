#if COMPTE_PERSO

import Foundation
import PDFKit

// Passage de vérification (version personnelle seulement : tout ce fichier est sous « #if COMPTE_PERSO »).
// Après la complétion, un modèle plus lourd (Opus, via l'abonnement Claude de l'élève) relit chaque page remplie avec
// ses réponses et signale : les zones qui devraient avoir une réponse et qui sont vides ; les réponses incohérentes
// (hors sujet, qui ne répondent pas à la consigne, qui contredisent le cours, mot, nombre ou unité faux).
// Il ne réécrit JAMAIS une zone qui va bien : seules les zones signalées reçoivent une proposition.
// Rien n'est écrit dans le PDF ici, et les définitions ou questions ouvertes ne sont pas reformulées.

/// Ce qu'il faut pour demander une réponse structurée à un modèle. `ClaudeCodeEngine` le fournit déjà.
protocol VerificationGenerator: AnyObject {
    func generate(system: String, content: [[String: Any]], schema: [String: Any], timeout: TimeInterval?) async throws -> String
}

extension ClaudeCodeEngine: VerificationGenerator {}

/// Un problème signalé dans une zone.
struct VerificationProblem: Equatable {
    enum Kind: String { case vide, incoherent }
    enum Action: String { case corriger, ignorer }

    var pageIndex: Int            // index de page (0 = première)
    var zoneID: Int               // Zone.id
    var zoneNumber: Int           // numéro affiché sur la page
    var kind: Kind                // déduit de l'état réel de la zone : vide, ou remplie mais fausse
    var action: Action            // .ignorer : ce n'est pas un trou à remplir (signature, case…)
    var explanation: String       // courte, en français
    var proposal: String          // réponse proposée ; vide si .ignorer
    var current: String           // réponse actuelle
}

struct VerificationPageError: Equatable {
    var pageIndex: Int
    var message: String
}

struct VerificationReport {
    var problems: [VerificationProblem] = []
    var pagesChecked: [Int] = []                    // index des pages vérifiées sans erreur
    var pageErrors: [VerificationPageError] = []    // pages (ou lots) qu'on n'a pas pu vérifier
}

enum VerificationPass {

    /// Modèle de relecture : toujours le plus lourd, quel que soit le modèle qui a rempli les zones.
    static let model = "opus"
    /// Délai maximal d'un appel (une page avec son image peut être longue).
    static let timeout: TimeInterval = 420
    /// Au plus 30 zones par requête : les pages très chargées sont découpées en lots.
    static let maxZonesPerRequest = 30
    /// Bornes de sortie gardées par le code (la sortie demandée reste courte : 4 000 jetons par page au plus).
    static let maxProblemsPerRequest = 40
    static let maxExplanationChars = 400
    static let maxProposalChars = 600

    static let badFormatMessage = "La vérification d'une page a renvoyé une réponse coupée ou mal formée. Cette page n'a pas été vérifiée : relance la vérification."

    static let systemPrompt = """
    Tu relis une page de cours à trous qu'un élève de Seconde (lycée professionnel) a déjà complétée. Tu es un correcteur attentif et mesuré.
    Tu reçois : l'image de la page avec le numéro de chaque zone dessiné, le texte de la page où ⟦n⟧ marque la zone n, et pour chaque zone le texte qui l'entoure et sa réponse actuelle (ou « (vide) »).

    Tu signales seulement :
    - une zone qui devrait avoir une réponse (trou visible, consigne claire) et qui est vide : tu proposes la réponse ;
    - une réponse incohérente : hors sujet, qui ne répond pas à la consigne, qui contredit le cours écrit sur la page, un mot qui ne correspond pas à la phrase, un nombre ou une unité faux : tu proposes la réponse corrigée.

    Règles :
    - Une zone qui va bien n'apparaît PAS dans ta réponse. Ne réécris jamais une réponse correcte, même pour la rendre plus jolie ou plus complète.
    - Un mot à compléter n'est corrigé que si la réponse est visiblement fausse.
    - Une définition ou une question ouverte n'est corrigée que si elle est fausse ou hors sujet ; jamais reformulée pour le style.
    - Si la zone n'est pas un trou à remplir (signature, case réservée à l'élève, élément décoratif), mets « action » à « ignorer » et « proposition » vide.
    - Sinon, « action » vaut « corriger ».
    - « explication » : en français, une ou deux phrases courtes, 300 caractères au plus.
    - « proposition » : courte, en français, au niveau du cours. Pas de guillemets autour, pas de puces, pas de repère ⟦n⟧, pas de phrase d'introduction.
    - Reste bref : ta réponse ne dépasse pas 4 000 jetons. Sans problème, renvoie une liste vide.
    - Réponds uniquement avec le JSON demandé.
    """

    /// Schéma strict : aucun champ en plus, tous les champs requis, aucune borne de longueur (les bornes sont gardées par le code).
    static let schema: [String: Any] = {
        let zone: [String: Any] = ["type": "integer"]
        let action: [String: Any] = ["type": "string", "enum": ["corriger", "ignorer"]]
        let text: [String: Any] = ["type": "string"]
        let item: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["zone", "action", "explication", "proposition"],
            "properties": ["zone": zone, "action": action, "explication": text, "proposition": text],
        ]
        let list: [String: Any] = ["type": "array", "items": item]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["problemes"],
            "properties": ["problemes": list],
        ]
    }()

    // MARK: - Point d'entrée

    /// Relit les pages remplies. `zones` : les zones après complétion (réponses actuelles). Une page par requête
    /// (lots de 30 zones au plus). Une zone « ignorer » n'est jamais relue.
    /// - Annulation : `CancellationError`, plus aucune requête n'est lancée.
    /// - Erreur fatale (non connecté, limite de l'abonnement : `EngineError.isFatal`) : tout s'arrête et l'erreur est levée.
    /// - Autre erreur (réponse coupée, délai dépassé, réponse mal formée) : la page est notée dans `pageErrors`, les autres continuent.
    static func run(url: URL, analyses: [PageAnalysis], zones: [Zone], generator: VerificationGenerator,
                    onUpdate: ((Double, String) -> Void)? = nil) async throws -> VerificationReport {
        try Task.checkCancellation()
        let doc = try CoursPipeline.openDocument(url)
        let pageCount = doc.pageCount

        var jobs: [(analysis: PageAnalysis, zones: [Zone])] = []
        for a in analyses.sorted(by: { $0.pageIndex < $1.pageIndex }) {
            let pz = zones
                .filter { $0.page == a.pageIndex && $0.kind != .ignorer && $0.kind != .schema }
                .sorted { $0.number < $1.number }
            var i = 0
            while i < pz.count {
                jobs.append((a, Array(pz[i..<min(i + maxZonesPerRequest, pz.count)])))
                i += maxZonesPerRequest
            }
        }

        var report = VerificationReport()
        for (n, job) in jobs.enumerated() {
            try Task.checkCancellation()
            onUpdate?(Double(n) / Double(jobs.count), "Vérification — page \(job.analysis.pageIndex + 1) sur \(pageCount)")
            do {
                let found = try await verifyPage(job.analysis, zones: job.zones, pageCount: pageCount,
                                                 doc: doc, generator: generator)
                report.problems += found
                if !report.pagesChecked.contains(job.analysis.pageIndex) {
                    report.pagesChecked.append(job.analysis.pageIndex)
                }
            } catch let e as EngineError where e.isFatal {
                throw e                                  // inutile d'essayer les autres pages
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                let message = (error as? EngineError)?.localizedDescription ?? error.localizedDescription
                report.pageErrors.append(VerificationPageError(pageIndex: job.analysis.pageIndex, message: message))
            }
        }
        try Task.checkCancellation()
        onUpdate?(1, "Vérification terminée")
        report.problems.sort { ($0.pageIndex, $0.zoneNumber) < ($1.pageIndex, $1.zoneNumber) }
        return report
    }

    // MARK: - Une page

    private static func verifyPage(_ a: PageAnalysis, zones: [Zone], pageCount: Int, doc: PDFDocument,
                                   generator: VerificationGenerator) async throws -> [VerificationProblem] {
        var content: [[String: Any]] = []
        // image de la page, zones numérotées (comme pour la complétion) ; sans image, la relecture se fait sur le texte
        let jpeg = autoreleasepool { () -> Data? in
            guard let page = doc.page(at: a.pageIndex) else { return nil }
            return MarkedImage.make(page: page, zones: zones)
        }
        if let jpeg, !jpeg.isEmpty {
            let source: [String: Any] = ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]
            content.append(["type": "image", "source": source])
        }
        content.append(["type": "text", "text": userText(a, zones: zones, pageCount: pageCount)])

        let json = try await generator.generate(system: systemPrompt, content: content, schema: schema, timeout: timeout)
        let items = try decode(json)

        let byNumber = Dictionary(zones.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [VerificationProblem] = []
        var seen = Set<Int>()
        for item in items.prefix(maxProblemsPerRequest) {
            // un numéro inconnu sur cette page est ignoré ; une zone n'est signalée qu'une fois
            guard let z = byNumber[item.zone], !seen.contains(item.zone) else { continue }
            seen.insert(item.zone)
            if let p = problem(from: item, zone: z, pageIndex: a.pageIndex) { out.append(p) }
        }
        return out
    }

    /// Transforme la réponse brute d'une zone en problème, ou renvoie nil si rien à signaler.
    private static func problem(from item: RawItem, zone z: Zone, pageIndex: Int) -> VerificationProblem? {
        let current = z.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // le type suit l'état réel de la zone : vide, ou remplie mais fausse
        let kind: VerificationProblem.Kind = current.isEmpty ? .vide : .incoherent
        let explanation = clip(item.explanation, maxExplanationChars)

        if item.action == "ignorer" {
            return VerificationProblem(pageIndex: pageIndex, zoneID: z.id, zoneNumber: z.number, kind: kind,
                                       action: .ignorer, explanation: explanation, proposal: "", current: current)
        }
        // la proposition passe par le même nettoyage que les réponses de la complétion
        let proposal = AnswerCleaner.clean(clip(item.proposition, maxProposalChars), kind: z.kind)
        // une proposition identique à la réponse actuelle n'apporte rien : la zone va bien
        if proposal.isEmpty || proposal == current { return nil }
        // un mot à compléter déjà rempli n'est corrigé que si la réponse est fausse : ni simple réécriture
        // de forme (casse, accents, ponctuation), ni phrase à la place d'un mot
        if z.kind == .mot && !current.isEmpty {
            if key(proposal) == key(current) { return nil }
            if wordCount(proposal) > wordCount(current) + 2 { return nil }
        }
        return VerificationProblem(pageIndex: pageIndex, zoneID: z.id, zoneNumber: z.number, kind: kind,
                                   action: .corriger, explanation: explanation, proposal: proposal, current: current)
    }

    // MARK: - Texte envoyé et réponse reçue

    static func userText(_ a: PageAnalysis, zones: [Zone], pageCount: Int) -> String {
        var s = "Page \(a.pageIndex + 1) sur \(pageCount).\n\nTexte de la page (⟦n⟧ = emplacement de la zone n) :\n"
        let texte = a.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        s += texte.isEmpty ? "(texte non disponible : appuie-toi sur l'image)" : texte
        s += "\n\nZones à relire :\n"
        for z in zones {
            let answer = z.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = answer.isEmpty ? "(vide)" : answer
            s += "- Zone \(z.number) (\(z.kind.label)) — texte avant : « \(oneLine(z.contextBefore)) » — "
            s += "texte après : « \(oneLine(z.contextAfter)) » — réponse actuelle : « \(shown) »\n"
        }
        return s
    }

    struct RawItem: Equatable {
        var zone: Int
        var action: String
        var explanation: String
        var proposition: String
    }

    /// Lit le JSON de la réponse. Un JSON coupé ou mal formé lève `invalidResponse` (erreur de la seule page).
    static func decode(_ json: String) throws -> [RawItem] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["problemes"] as? [[String: Any]] else {
            throw EngineError.invalidResponse(badFormatMessage)
        }
        return items.compactMap { it -> RawItem? in
            guard let zone = it["zone"] as? Int else { return nil }
            return RawItem(zone: zone,
                           action: it["action"] as? String ?? "corriger",
                           explanation: it["explication"] as? String ?? "",
                           proposition: it["proposition"] as? String ?? "")
        }
    }

    // MARK: - Petites aides

    private static func clip(_ s: String, _ limit: Int) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Clé de comparaison : lettres et chiffres seulement, sans casse ni accents.
    private static func key(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " }).count
    }
}

#endif
