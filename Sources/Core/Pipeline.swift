import Foundation
import PDFKit

struct CompletionSettings {
    var humanize: Bool
    var student: StudentProfile
    var humanizeTone: HumanizeTone = .eleve
}

/// Nettoyage des réponses brutes d'une IA.
enum AnswerCleaner {
    /// Abréviations dont le point final fait partie du mot (on ne l'enlève pas d'un mot à compléter).
    private static let keepFinalDot = ["etc.", "env.", "cf.", "c.-à-d.", "j.-c."]

    private static let quotePairs: [(Character, Character)] = [
        ("\"", "\""), ("«", "»"), ("“", "”"), ("„", "“"), ("‘", "’"), ("'", "'"),
    ]

    private static func trailingDotIsPartOfWord(_ t: String) -> Bool {
        let low = t.lowercased()
        for a in keepFinalDot where low.hasSuffix(a) {
            let before = low.dropLast(a.count).last
            if before == nil || !(before!.isLetter) { return true }
        }
        // sigles écrits avec des points : « S.I. », « C.C. »
        return t.range(of: "(?:^|[\\s(])(?:\\p{L}\\.){2,}$", options: .regularExpression) != nil
    }

    static func clean(_ raw: String, kind: ZoneKind) -> String {
        var t = raw
        for z in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{2060}"] { t = t.replacingOccurrences(of: z, with: "") }
        t = t.replacingOccurrences(of: "⟦[0-9]+⟧", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        t = t.replacingOccurrences(of: "[\\u202F\\u2009]", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[\\r\\n\\u2028\\u2029]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // puce en tête (« - volt », « • volt »), mais pas un nombre négatif
        t = t.replacingOccurrences(of: "^[-–•*]\\s+", with: "", options: .regularExpression)

        for _ in 0..<4 {
            let before = t
            // guillemets qui entourent toute la réponse (jamais « "a" et "b" » : alors ils ne l'entourent pas)
            for (o, c) in quotePairs where t.count >= 2 && t.first == o && t.last == c {
                let inner = String(t.dropFirst().dropLast())
                if !inner.contains(o) && !inner.contains(c) {
                    t = inner.trimmingCharacters(in: .whitespaces)
                }
            }
            // guillemet isolé (ouvrant sans fermant, ou l'inverse)
            if t.first == "«", !t.contains("»") { t.removeFirst() }
            if t.last == "»", !t.contains("«") { t.removeLast() }
            if t.first == "\"", t.filter({ $0 == "\"" }).count == 1 { t.removeFirst() }
            if t.last == "\"", t.filter({ $0 == "\"" }).count == 1 { t.removeLast() }
            t = t.trimmingCharacters(in: .whitespaces)
            // ponctuation finale d'un mot à compléter (mais « etc. » reste « etc. »)
            if kind == .mot {
                while let l = t.last, ".;,:…".contains(l), !(l == "." && trailingDotIsPartOfWord(t)) { t.removeLast() }
                t = t.trimmingCharacters(in: .whitespaces)
            }
            if t == before { break }
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // rien d'exploitable (que des guillemets ou de la ponctuation) : réponse vide
        if !t.contains(where: { $0.isLetter || $0.isNumber }) { return "" }
        return t
    }
}

/// Garde-fou de l'humanisation : refuse une réécriture qui change les faits, le sens ou la longueur.
enum HumanizeGuard {

    // MARK: nombres

    private static let numberRegex = try! NSRegularExpression(
        pattern: "\\d{1,3}(?: \\d{3})+(?:[.,]\\d+)?|\\d+(?:[.,]\\d{3})+(?!\\d)|\\d+(?:[.,]\\d+)?")

    /// Forme canonique : virgule ou point décimal égaux, zéros inutiles retirés (« 3,50 » = « 3.5 », « 230,0 » = « 230 »).
    private static func canon(_ s: String) -> String {
        let parts = s.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var int = parts.first ?? ""
        while int.count > 1, int.hasPrefix("0") { int.removeFirst() }
        var frac = parts.count > 1 ? parts[1] : ""
        while frac.hasSuffix("0") { frac.removeLast() }
        return frac.isEmpty ? int : int + "." + frac
    }

    private static func normalizeSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: "[\\u00A0\\u202F\\u2009\\u2007]", with: " ", options: .regularExpression)
    }

    /// Chaque nombre du texte, avec ses lectures possibles : « 1 000 » = [1000] ou [1, 000] ; « 3,500 » = 3,5 ou 3500.
    /// Une lecture est une liste de formes canoniques qui doivent toutes se retrouver dans la réécriture.
    private static func numberReadings(_ text: String) -> [[[String]]] {
        let s = normalizeSpaces(text)
        let ns = s as NSString
        var out: [[[String]]] = []
        for m in numberRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let tok = ns.substring(with: m.range)
            if tok.contains(" ") {
                let groups = tok.split(separator: " ").map(String.init)
                out.append([[canon(groups.joined())], groups.map(canon)])
            } else if tok.range(of: "^\\d+(?:[.,]\\d{3})+$", options: .regularExpression) != nil {
                let seps = tok.filter { $0 == "." || $0 == "," }.count
                let integer = canon(tok.replacingOccurrences(of: "[.,]", with: "", options: .regularExpression))
                out.append(seps == 1 ? [[canon(tok)], [integer]] : [[integer]])
            } else {
                out.append([[canon(tok)]])
            }
        }
        return out
    }

    private static func numbersPreserved(original: String, candidate: String) -> Bool {
        let wanted = numberReadings(original)
        if wanted.isEmpty { return true }
        var have = Set<String>()
        for n in numberReadings(candidate) { for alt in n { for f in alt { have.insert(f) } } }
        for n in wanted where !n.contains(where: { alt in alt.allSatisfy { have.contains($0) } }) { return false }
        return true
    }

    // MARK: pourcentages et unités

    private static let unitRegex = try! NSRegularExpression(
        pattern: "(?<=\\d)[ ]?(kVA|VA|kWh|Wh|kHz|MHz|Hz|kV|mV|V|kA|mA|A|kW|W|kΩ|MΩ|Ω)(?![\\p{L}\\d])")
    private static let spelled: [String: [String]] = [
        "V": ["volt"], "A": ["ampère", "ampere"], "W": ["watt"], "Hz": ["hertz"], "Ω": ["ohm"],
        "VA": ["voltampère", "volt-ampère", "volt ampère"], "Wh": ["wattheure", "watt-heure", "watt heure"],
    ]

    private static func unitsPreserved(original: String, candidate: String) -> Bool {
        let o = normalizeSpaces(original), c = normalizeSpaces(candidate)
        let low = c.lowercased()
        if o.contains("%") && !c.contains("%") && !low.contains("pour cent") && !low.contains("pourcent") { return false }
        let ns = o as NSString
        for m in unitRegex.matches(in: o, range: NSRange(location: 0, length: ns.length)) {
            let u = ns.substring(with: m.range(at: 1))
            let escaped = NSRegularExpression.escapedPattern(for: u)
            if c.range(of: "(?<![\\p{L}])\(escaped)(?![\\p{L}])", options: .regularExpression) != nil { continue }
            var base = u
            if spelled[base] == nil, u.count > 1, "kmMK".contains(u.first!) { base = String(u.dropFirst()) }
            if let names = spelled[base], names.contains(where: { low.contains($0) }) { continue }
            return false
        }
        return true
    }

    // MARK: négations

    private static let negPartners: Set<String> = ["pas", "jamais", "aucun", "aucune", "aucuns", "aucunes", "rien", "ni", "plus", "guère", "guere"]

    /// La phrase contient-elle une négation (ne…pas, jamais, aucun, sans, plus, rien…) ?
    static func hasNegation(_ text: String) -> Bool {
        var s = text.lowercased().replacingOccurrences(of: "’", with: "'")
        s = s.replacingOccurrences(of: "sans doute", with: " ")
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "'"))
        let words = s.components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
        if words.contains("sans") { return true }
        if words.contains(where: { ["pas", "jamais", "aucun", "aucune", "aucuns", "aucunes"].contains($0) }) { return true }
        let hasNe = words.contains("ne") || words.contains { $0.hasPrefix("n'") && $0.count > 2 && !$0.hasPrefix("n'importe") }
        if hasNe && words.contains(where: { negPartners.contains($0) }) { return true }
        return false
    }

    // MARK: décision

    /// Renvoie le texte nettoyé s'il est acceptable, sinon nil (on garde alors la réponse d'origine).
    static func accept(original: String, candidate: String, maxChars: Int) -> String? {
        // jamais de repère ⟦n⟧, de balisage, de liste à puces ni de phrase d'introduction
        if candidate.contains("⟦") || candidate.contains("**") { return nil }
        let bullet = "(^|\\n)\\s*[-•*]\\s+"
        if candidate.range(of: bullet, options: .regularExpression) != nil,
           original.range(of: bullet, options: .regularExpression) == nil { return nil }
        let c = AnswerCleaner.clean(candidate, kind: .question)
        if c.isEmpty { return nil }
        let lowC = c.lowercased()
        for intro in ["voici ", "bien sûr", "d'accord", "réponse :", "réponse:", "version réécrite", "réécriture"] where lowC.hasPrefix(intro) { return nil }

        let o = original.count
        if c.count > max(maxChars, Int(Double(o) * 1.2)) { return nil }
        if Double(c.count) < Double(o) * 0.35 && o > 40 { return nil }
        if !numbersPreserved(original: original, candidate: c) { return nil }
        if !unitsPreserved(original: original, candidate: c) { return nil }
        if hasNegation(original) != hasNegation(c) { return nil }
        return c
    }
}

enum CoursPipeline {

    // MARK: - Ouverture du PDF

    /// Ouvre le PDF ou explique pourquoi c'est impossible (message en français).
    static func openDocument(_ url: URL) throws -> PDFDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CoursError.message("Le fichier est introuvable. Il a peut-être été déplacé ou supprimé.")
        }
        guard let doc = PDFDocument(url: url) else {
            throw CoursError.message("Ce fichier n'est pas un PDF lisible : il est peut-être abîmé. Essaie de le rouvrir ou de l'exporter à nouveau.")
        }
        if doc.isLocked && !doc.unlock(withPassword: "") {
            throw CoursError.message("Ce PDF est protégé par un mot de passe. Enlève la protection (dans Aperçu : Fichier > Exporter) puis rouvre-le.")
        }
        if doc.pageCount == 0 {
            throw CoursError.message("Ce PDF ne contient aucune page.")
        }
        if doc.page(at: 0) == nil {
            throw CoursError.message("Les pages de ce PDF sont illisibles : le fichier est abîmé.")
        }
        return doc
    }

    // MARK: - Étape 1 : trouver les trous (local, sans IA)

    /// Analyse toutes les pages. Ouvre sa propre copie du PDF : à appeler hors du thread principal.
    /// Renvoie [] si le PDF n'est pas utilisable, sans dire pourquoi : préférer `analyzeChecked`.
    static func analyze(url: URL, needText: Bool, progress: (Double, String) -> Void) -> [PageAnalysis] {
        (try? analyzeChecked(url: url, needText: needText, progress: progress)) ?? []
    }

    /// Comme `analyze`, mais signale le problème : PDF introuvable, abîmé, protégé par mot de passe, sans page
    /// (`CoursError.message` en français), ou `CancellationError` si la Task qui l'appelle est annulée.
    static func analyzeChecked(url: URL, needText: Bool, progress: (Double, String) -> Void) throws -> [PageAnalysis] {
        let doc = try openDocument(url)
        var out: [PageAnalysis] = []
        var nextID = 1
        let count = doc.pageCount
        let n = max(count, 1)
        for i in 0..<count {
            try Task.checkCancellation()
            progress(Double(i) / Double(n), "Recherche des zones à remplir — page \(i + 1) sur \(count)")
            autoreleasepool {
                guard let page = doc.page(at: i) else { return }
                let a = ZoneDetector.analyze(page: page, index: i, firstID: nextID, needText: needText)
                nextID += a.zones.count
                out.append(a)
            }
        }
        if out.isEmpty { throw CoursError.message("Les pages de ce PDF sont illisibles : le fichier est abîmé.") }
        progress(1, "Zones trouvées")
        return out
    }

    /// Identifiants des zones qui ont une erreur : à passer en `onlyZoneIDs` pour une reprise ciblée.
    static func zoneIDsInError(_ zones: [Zone]) -> Set<Int> {
        Set(zones.filter { $0.error != nil }.map { $0.id })
    }

    // MARK: - Étapes 2 et 3 : complétion puis humanisation

    private struct PageResult {
        var pageIndex: Int
        var numbers: [Int]
        var answers: [ZoneAnswer]?
        var error: EngineError?
        /// La requête a été interrompue parce que la Task est annulée : ni réponse, ni erreur à retenir.
        var cancelled = false
    }

    /// Intervalle minimal entre deux appels de `onUpdate` pendant le travail (les débuts et fins de phase passent toujours).
    static var minUpdateInterval: TimeInterval = 0.1

    /// Remplit les zones avec l'IA, puis (si demandé) humanise les questions ouvertes.
    /// `onlyZoneIDs` limite le travail à certaines zones (régénération). Renvoie les zones mises à jour.
    ///
    /// - Annulation de la Task : plus aucune requête n'est lancée, celles en cours sont annulées, l'humanisation n'a
    ///   pas lieu, un dernier `onUpdate` livre ce qui est déjà arrivé, puis `CancellationError` est levée.
    /// - Erreur non fatale d'une page : les zones de cette page gardent un message (`error`), le reste continue.
    ///   Une zone en erreur garde sa réponse précédente (régénération) ; `zoneIDsInError` donne les zones à reprendre.
    /// - Erreur fatale (clé refusée, moteur indisponible) : tout s'arrête et l'erreur est levée.
    static func complete(url: URL, documentName: String, analyses: [PageAnalysis], zones inputZones: [Zone],
                         engine: CompletionEngine, settings: CompletionSettings,
                         onlyZoneIDs: Set<Int>? = nil,
                         onUpdate: @escaping @Sendable ([Zone], Double, String) -> Void) async throws -> [Zone] {
        try Task.checkCancellation()
        let doc = try openDocument(url)
        var zones = inputZones
        let pageCount = doc.pageCount
        let today = Prompts.todayText()

        func requested(_ z: Zone) -> Bool {
            if let only = onlyZoneIDs { return only.contains(z.id) }
            return z.enabled
        }

        // lots à traiter : une page, ou plusieurs lots de 30 zones au plus pour les pages très chargées
        let maxZonesPerRequest = 30
        var work: [(analysis: PageAnalysis, numbers: Set<Int>)] = []
        var zonesByPage: [Int: [Zone]] = [:]
        for z in zones where requested(z) { zonesByPage[z.page, default: []].append(z) }
        for a in analyses {
            let nums = (zonesByPage[a.pageIndex] ?? []).map { $0.number }.sorted()
            var i = 0
            while i < nums.count {
                work.append((a, Set(nums[i..<min(i + maxZonesPerRequest, nums.count)])))
                i += maxZonesPerRequest
            }
        }
        let totalSteps = Double(max(work.count, 1)) + (settings.humanize ? 1 : 0)
        var done = 0.0

        // avancement : toujours croissant, et pas plus d'une mise à jour par `minUpdateInterval` hors étapes clés
        var lastEmit = Date.distantPast
        var peak = 0.0
        func emit(_ fraction: Double, _ label: String, force: Bool = false) {
            peak = max(peak, min(max(fraction, 0), 1))
            let now = Date()
            if !force && now.timeIntervalSince(lastEmit) < minUpdateInterval { return }
            lastEmit = now
            onUpdate(zones, peak, label)
        }
        emit(0, work.isEmpty ? "Aucune zone à remplir" : "Démarrage de \(engine.displayName)…", force: true)

        func makeRequest(_ a: PageAnalysis, _ numbers: Set<Int>) -> PageRequest? {
            let pz = (zonesByPage[a.pageIndex] ?? []).compactMap { z in
                numbers.contains(z.number) ? zones.first(where: { $0.id == z.id }) : nil
            }
            if pz.isEmpty { return nil }
            var jpeg: Data? = nil
            if engine.usesImages {
                // le rendu de la page et l'image annotée sont gros : on les libère tout de suite après le JPEG
                jpeg = autoreleasepool { () -> Data? in
                    guard let page = doc.page(at: a.pageIndex) else { return nil }
                    return MarkedImage.make(page: page, zones: pz)
                }
            }
            return PageRequest(documentName: documentName,
                               pageNumber: a.pageIndex + 1, pageCount: pageCount,
                               transcript: a.transcript, hasTextLayer: a.hasTextLayer, zones: pz,
                               markedImageJPEG: jpeg, student: settings.student, todayText: today)
        }

        var completedIDs = Set<Int>()      // zones remplies avec succès pendant CET appel (seules candidates à l'humanisation)

        func apply(_ r: PageResult) {
            for z in zones.indices where zones[z].page == r.pageIndex && r.numbers.contains(zones[z].number) {
                if let err = r.error {
                    zones[z].error = err.localizedDescription
                    continue
                }
                guard let a = r.answers?.first(where: { $0.number == zones[z].number }) else {
                    zones[z].error = "L'IA n'a pas répondu pour cette zone."
                    continue
                }
                zones[z].error = nil
                zones[z].humanized = false
                if a.kind == .ignorer {
                    zones[z].kind = .ignorer
                    zones[z].enabled = false
                    zones[z].answer = ""
                    zones[z].rawAnswer = ""
                } else {
                    let text = AnswerCleaner.clean(a.text, kind: a.kind)
                    zones[z].kind = a.kind
                    zones[z].enabled = !text.isEmpty
                    zones[z].answer = text
                    zones[z].rawAnswer = text
                    if !text.isEmpty { completedIDs.insert(zones[z].id) }
                }
            }
        }

        var fatal: EngineError?
        var iterator = work.makeIterator()
        await withTaskGroup(of: PageResult.self) { group in
            func addNext() -> Bool {
                while let job = iterator.next() {
                    if Task.isCancelled { return false }
                    let a = job.analysis
                    guard let req = makeRequest(a, job.numbers) else { continue }
                    let numbers = req.zones.map { $0.number }
                    group.addTask {
                        do {
                            let ans = try await engine.complete(req)
                            return PageResult(pageIndex: a.pageIndex, numbers: numbers, answers: ans, error: nil)
                        } catch {
                            // annulée (Task annulée ou arrêt après une erreur fatale) : pas une erreur de la page
                            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                                return PageResult(pageIndex: a.pageIndex, numbers: numbers, answers: nil, error: nil, cancelled: true)
                            }
                            let e = (error as? EngineError) ?? .other(error.localizedDescription)
                            return PageResult(pageIndex: a.pageIndex, numbers: numbers, answers: nil, error: e)
                        }
                    }
                    return true
                }
                return false
            }
            for _ in 0..<max(1, engine.maxConcurrentPages) { if !addNext() { break } }
            while let r = await group.next() {
                if r.cancelled { continue }
                apply(r)
                done += 1
                if let e = r.error, e.isFatal, fatal == nil { fatal = e; group.cancelAll() }
                if Task.isCancelled { group.cancelAll() }
                emit(done / totalSteps, "Page \(r.pageIndex + 1) complétée")
                if fatal == nil && !Task.isCancelled { _ = addNext() }
            }
        }
        if let f = fatal {
            emit(done / totalSteps, "Arrêt : \(f.localizedDescription)", force: true)
            throw f
        }
        if Task.isCancelled {
            emit(done / totalSteps, "Annulé", force: true)
            throw CancellationError()
        }

        // Seules les questions ouvertes sont humanisées : les définitions et textes à trous restent exacts.
        if settings.humanize {
            let candidates = zones.indices.filter {
                completedIDs.contains(zones[$0].id) && zones[$0].error == nil && zones[$0].enabled &&
                zones[$0].kind.isHumanizable && !zones[$0].answer.isEmpty && !zones[$0].humanized
            }
            emit(done / totalSteps, candidates.isEmpty ? "Rien à humaniser" : "Humanisation des réponses…", force: true)
            let batchSize = 10
            var start = 0
            var consecutiveFailures = 0
            while start < candidates.count {
                if Task.isCancelled {
                    emit(done / totalSteps, "Annulé", force: true)
                    throw CancellationError()
                }
                let batch = Array(candidates[start..<min(start + batchSize, candidates.count)])
                start += batchSize
                let items = batch.map { i in
                    HumanizeItem(id: zones[i].id, kind: zones[i].kind, question: zones[i].contextBefore,
                                 answer: zones[i].rawAnswer, maxChars: max(zones[i].capacity, zones[i].rawAnswer.count),
                                 tone: settings.humanizeTone)
                }
                do {
                    let result = try await engine.humanize(items)
                    consecutiveFailures = 0
                    for i in batch {
                        guard let cand = result[zones[i].id] else { continue }
                        if let ok = HumanizeGuard.accept(original: zones[i].rawAnswer, candidate: cand,
                                                         maxChars: max(zones[i].capacity, zones[i].rawAnswer.count)) {
                            zones[i].answer = ok
                            zones[i].humanized = true
                        }
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                        emit(done / totalSteps, "Annulé", force: true)
                        throw CancellationError()
                    }
                    if let e = error as? EngineError, e.isFatal { throw e }
                    emit(done / totalSteps, "Humanisation impossible : \(error.localizedDescription)", force: true)
                    consecutiveFailures += 1
                    // le service ne répond plus : inutile d'attendre un délai par lot, on garde les réponses d'origine
                    if consecutiveFailures >= 2 { break }
                }
                let inner = Double(min(start, candidates.count)) / Double(max(candidates.count, 1))
                emit(min(0.99, (done + inner) / totalSteps), "Humanisation des réponses…")
            }
        }
        emit(1, "Terminé", force: true)
        return zones
    }
}

#if COMPTE_PERSO
/// Point d'entrée après la complétion (version personnelle seulement). Ne fait AUCUN appel si `enabled` est faux
/// (réglage « Vérifier les réponses avec Opus ») ou si le moteur n'est pas « Claude (mon compte) ».
/// Le passage utilise Opus avec le même programme `claude` et le même effort que le moteur de complétion.
extension CoursPipeline {
    static func verifyAfterCompletion(url: URL, analyses: [PageAnalysis], zones: [Zone], engine: CompletionEngine,
                                      enabled: Bool,
                                      onUpdate: ((Double, String) -> Void)? = nil) async throws -> VerificationReport? {
        guard enabled, let base = engine as? ClaudeCodeEngine else { return nil }
        let opus = ClaudeCodeEngine(cli: base.cli, model: VerificationPass.model, effort: base.effort, tuning: base.tuning)
        return try await VerificationPass.run(url: url, analyses: analyses, zones: zones, generator: opus, onUpdate: onUpdate)
    }
}
#endif
