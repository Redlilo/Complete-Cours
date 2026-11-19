import Foundation
import PDFKit
import Darwin

// Test du pipeline avec un faux moteur d'IA : vérifie surtout que les mots à compléter
// ne sont JAMAIS humanisés, et le comportement en cas d'erreur.
//   swiftc -O -swift-version 5 -target arm64-apple-macos26.0 Sources/Core/*.swift Tools/Tests/Pipeline/main.swift -o build/pipeline-test

final class FakeEngine: CompletionEngine {
    let displayName = "Faux moteur"
    var usesImages = false
    var maxConcurrentPages = 2
    var humanizeMode = "bon"                 // bon | chiffres-perdus | trop-long | erreur | vide
    var failPages: Set<Int> = []             // numéros de page (1 = première) qui échouent sans être fatals
    var failError: EngineError = .network("coupure réseau")
    var fatalOnPage: Int? = nil
    var delayMs = 0                          // lenteur simulée (annulable) de chaque appel à complete
    var humanizeDelayMs = 0
    var omitNumbers: Set<Int> = []           // numéros de zone pour lesquels l'IA « oublie » de répondre
    var failOnCancelWithEngineError = false  // à l'annulation, lève une EngineError (comme un moteur qui enveloppe URLError)
    private let lock = NSLock()
    private(set) var humanizedKinds: [ZoneKind] = []
    private(set) var humanizeCalls = 0
    private(set) var completeCalls: [(page: Int, numbers: [Int])] = []
    private(set) var cancelledCalls = 0
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var peakFootprint: UInt64 = 0

    func complete(_ r: PageRequest) async throws -> [ZoneAnswer] {
        lock.withLock {
            completeCalls.append((r.pageNumber, r.zones.map { $0.number }))
            inFlight += 1; maxInFlight = max(maxInFlight, inFlight)
            peakFootprint = max(peakFootprint, footprint())
        }
        defer { lock.withLock { inFlight -= 1 } }
        if delayMs > 0 {
            do { try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
            catch {
                lock.withLock { cancelledCalls += 1 }
                if failOnCancelWithEngineError { throw EngineError.network("requête interrompue") }
                throw error
            }
        }
        if let f = fatalOnPage, f == r.pageNumber { throw EngineError.auth("clé refusée") }
        if failPages.contains(r.pageNumber) { throw failError }
        return r.zones.filter { !omitNumbers.contains($0.number) }.map { z in
            if z.number % 5 == 0 { return ZoneAnswer(number: z.number, kind: .ignorer, text: "") }
            switch z.kind {
            case .mot: return ZoneAnswer(number: z.number, kind: .mot, text: "« alternatif. »")
            case .definition: return ZoneAnswer(number: z.number, kind: .definition,
                                                text: "Un onduleur transforme le courant continu en courant alternatif de 230 V.")
            default: return ZoneAnswer(number: z.number, kind: .question,
                                       text: "Il est important de noter que la tension du secteur est de 230 V.\nEn effet, c'est la norme.")
            }
        }
    }

    func humanize(_ items: [HumanizeItem]) async throws -> [Int: String] {
        lock.withLock { humanizedKinds.append(contentsOf: items.map { $0.kind }); humanizeCalls += 1 }
        if humanizeDelayMs > 0 { try await Task.sleep(nanoseconds: UInt64(humanizeDelayMs) * 1_000_000) }
        switch humanizeMode {
        case "erreur": throw EngineError.network("coupure pendant l'humanisation")
        case "vide": return [:]
        default: break
        }
        var out: [Int: String] = [:]
        for it in items {
            switch humanizeMode {
            case "chiffres-perdus": out[it.id] = "La tension du secteur est très élevée, c'est la norme."
            case "trop-long": out[it.id] = String(repeating: "Phrase très longue. ", count: 60)
            default:
                out[it.id] = it.kind == .definition
                    ? "Un onduleur change le courant continu en courant alternatif de 230 V."
                    : "La tension du secteur est de 230 V, c'est la norme."
            }
        }
        return out
    }
}

/// Empreinte mémoire physique du processus (octets).
func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

/// Recueille les appels de onUpdate (appelés depuis plusieurs threads).
final class UpdateLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var fractions: [Double] = []
    private(set) var labels: [String] = []
    private(set) var last: [Zone] = []
    func record(_ z: [Zone], _ f: Double, _ l: String) { lock.lock(); fractions.append(f); labels.append(l); last = z; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return fractions.count }
}

var failures = 0
func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if cond { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)  \(detail())") }
}

// --- PDF de test : 3 pages blanches (le pipeline n'a besoin que d'un PDF lisible)
let tmp = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let pdfURL = tmp.appendingPathComponent("pipeline-test.pdf")
do {
    let doc = PDFDocument()
    for i in 0..<3 { doc.insert(PDFPage(), at: i) }
    doc.write(to: pdfURL)
}

func makeZones() -> ([PageAnalysis], [Zone]) {
    var zones: [Zone] = []
    var analyses: [PageAnalysis] = []
    var id = 1
    for p in 0..<3 {
        // page 0 : 7 zones ; page 1 : 4 zones ; page 2 : 70 zones (pour tester le découpage en lots)
        let count = [7, 4, 70][p]
        var pageZones: [Zone] = []
        for n in 1...count {
            var z = Zone(id: id, page: p, number: n, source: .texte)
            z.lines = [WritingLine(x0: 50, x1: 300, y: 700 - CGFloat(n) * 8)]
            z.kind = [ZoneKind.mot, .definition, .question][n % 3]
            z.contextBefore = "Question \(n) : définis la notion."
            pageZones.append(z); id += 1
        }
        zones += pageZones
        analyses.append(PageAnalysis(pageIndex: p, zones: pageZones, transcript: "", hasTextLayer: true,
                                     rotationUnsupported: false, fontSize: 10))
    }
    return (analyses, zones)
}

func run(_ engine: FakeEngine, humanize: Bool,
         only: Set<Int>? = nil, zones inZones: [Zone]? = nil) async throws -> [Zone] {
    let (analyses, zones) = makeZones()
    return try await CoursPipeline.complete(url: pdfURL, documentName: "test", analyses: analyses, zones: inZones ?? zones,
                                            engine: engine, settings: CompletionSettings(humanize: humanize, student: StudentProfile()),
                                            onlyZoneIDs: only) { _, _, _ in }
}

// 1. flux normal avec humanisation
do {
    let e = FakeEngine()
    let zones = try await run(e, humanize: true)
    check(zones.count == 81, "toutes les zones sont conservées", "\(zones.count)")
    let mots = zones.filter { $0.kind == .mot && $0.enabled }
    check(!mots.isEmpty && mots.allSatisfy { $0.answer == "alternatif" && !$0.humanized },
          "mots à compléter : nettoyés (guillemets, point) et jamais humanisés")
    check(!e.humanizedKinds.isEmpty && e.humanizedKinds.allSatisfy { $0 == .question },
          "seules les questions ouvertes sont envoyées à l'humanisation", "\(Set(e.humanizedKinds))")
    let defs = zones.filter { $0.kind == .definition && $0.enabled }
    check(!defs.isEmpty && defs.allSatisfy { !$0.humanized && $0.answer == $0.rawAnswer && $0.answer.hasPrefix("Un onduleur transforme") },
          "définitions laissées exactes avec le texte d'origine")
    let questions = zones.filter { $0.kind == .question && $0.enabled }
    check(!questions.isEmpty && questions.allSatisfy { $0.humanized && $0.answer.hasPrefix("La tension du secteur") },
          "questions ouvertes humanisées")
    let ignored = zones.filter { $0.number % 5 == 0 }
    check(ignored.allSatisfy { !$0.enabled && $0.answer.isEmpty && $0.kind == .ignorer }, "zones « ignorer » désactivées")
    check(zones.allSatisfy { $0.error == nil }, "aucune erreur en flux normal")
    let chunked = e.completeCalls.filter { $0.page == 3 }
    check(chunked.count >= 3 && chunked.allSatisfy { $0.numbers.count <= 30 }, "page de 70 zones découpée en lots de 30 au plus", "\(chunked.map { $0.numbers.count })")
} catch { check(false, "flux normal", "\(error)") }

// 2. sans humanisation
do {
    let e = FakeEngine()
    let zones = try await run(e, humanize: false)
    check(e.humanizedKinds.isEmpty && zones.allSatisfy { !$0.humanized }, "humanisation désactivée : rien n'est réécrit")
    check(zones.filter { $0.kind == .question && $0.enabled }.allSatisfy { !$0.answer.contains("\n") }, "retours à la ligne aplatis")
} catch { check(false, "sans humanisation", "\(error)") }

// 3. garde-fou : chiffres perdus, texte trop long, humanisation en erreur, réponse vide
for mode in ["chiffres-perdus", "trop-long", "erreur", "vide"] {
    do {
        let e = FakeEngine(); e.humanizeMode = mode
        let zones = try await run(e, humanize: true)
        let humanizable = zones.filter { $0.kind == .question && $0.enabled }
        check(!humanizable.isEmpty && humanizable.allSatisfy { !$0.humanized && $0.answer == $0.rawAnswer },
              "garde-fou (\(mode)) : on garde la réponse d'origine")
    } catch { check(false, "garde-fou \(mode)", "\(error)") }
}

// 4. erreur non fatale sur une page
do {
    let e = FakeEngine(); e.failPages = [2]
    let zones = try await run(e, humanize: false)
    let p2 = zones.filter { $0.page == 1 }
    check(p2.allSatisfy { $0.error != nil && $0.answer.isEmpty }, "page en erreur : message sur chaque zone, pas de réponse")
    check(zones.filter { $0.page != 1 && $0.enabled }.allSatisfy { !$0.answer.isEmpty }, "les autres pages sont traitées normalement")
} catch { check(false, "erreur non fatale", "\(error)") }

// 5. erreur fatale (clé refusée) : le pipeline lève l'erreur
do {
    let e = FakeEngine(); e.fatalOnPage = 1; e.maxConcurrentPages = 1
    _ = try await run(e, humanize: true)
    check(false, "erreur fatale", "aucune erreur levée")
} catch let err as EngineError {
    if case .auth = err { check(true, "erreur fatale (clé refusée) propagée") } else { check(false, "erreur fatale", "\(err)") }
} catch { check(false, "erreur fatale", "\(error)") }

// 6. régénération d'une seule zone
do {
    let (_, base) = makeZones()
    let first = try await run(FakeEngine(), humanize: false)
    let target = first.first { $0.page == 0 && $0.number == 2 }!
    var modified = first
    for i in modified.indices where modified[i].id == target.id { modified[i].answer = "MODIFIÉE PAR L'ÉLÈVE"; modified[i].rawAnswer = "MODIFIÉE PAR L'ÉLÈVE" }
    let e = FakeEngine()
    let again = try await run(e, humanize: false, only: [target.id], zones: modified)
    check(again.first { $0.id == target.id }!.answer != "MODIFIÉE PAR L'ÉLÈVE", "régénération : la zone ciblée est recalculée")
    let other = again.first { $0.page == 0 && $0.number == 3 }!
    check(other.answer == modified.first { $0.id == other.id }!.answer, "régénération : les autres zones ne bougent pas")
    check(e.completeCalls.count == 1 && e.completeCalls[0].numbers == [2], "régénération : une seule requête, une seule zone", "\(e.completeCalls)")
    _ = base
} catch { check(false, "régénération", "\(error)") }

// 7. garde-fous unitaires
check(HumanizeGuard.accept(original: "La tension est de 230 V.", candidate: "On a 230 V sur le secteur.", maxChars: 80) != nil, "garde-fou : nombre conservé -> accepté")
check(HumanizeGuard.accept(original: "La tension est de 230 V.", candidate: "La tension est élevée.", maxChars: 80) == nil, "garde-fou : nombre perdu -> refusé")
check(HumanizeGuard.accept(original: "Courte.", candidate: String(repeating: "x", count: 400), maxChars: 50) == nil, "garde-fou : trop long -> refusé")
check(HumanizeGuard.accept(original: "Réponse correcte et assez longue pour tester le seuil.", candidate: "OK", maxChars: 100) == nil, "garde-fou : réponse écrasée -> refusée")
check(AnswerCleaner.clean("«\u{00A0}Volt\u{00A0}».", kind: .mot) == "Volt" || AnswerCleaner.clean("« Volt ».", kind: .mot) == "Volt", "nettoyage d'un mot")
check(!AnswerCleaner.clean("Texte ⟦3⟧ propre", kind: .question).contains("⟦"), "nettoyage : repères ⟦n⟧ retirés")


// ============ Nouveaux tests de robustesse ============
func makeBig(pages: Int, zonesPerPage: Int) -> ([PageAnalysis], [Zone]) {
    var zones: [Zone] = []; var analyses: [PageAnalysis] = []; var id = 1
    for p in 0..<pages {
        var pz: [Zone] = []
        for n in 1...zonesPerPage {
            var z = Zone(id: id, page: p, number: n, source: .texte)
            z.lines = [WritingLine(x0: 50, x1: 300, y: 700 - CGFloat(n) * 20)]
            z.kind = [ZoneKind.mot, .definition, .question][n % 3]
            pz.append(z); id += 1
        }
        zones += pz
        analyses.append(PageAnalysis(pageIndex: p, zones: pz, transcript: "", hasTextLayer: true, rotationUnsupported: false, fontSize: 10))
    }
    return (analyses, zones)
}

func runLogged(_ engine: FakeEngine, humanize: Bool, only: Set<Int>? = nil, zones inZones: [Zone]? = nil,
                analyses inAn: [PageAnalysis]? = nil, url: URL? = nil, log: UpdateLog = UpdateLog()) async throws -> [Zone] {
    let (analyses, zones) = makeZones()
    return try await CoursPipeline.complete(url: url ?? pdfURL, documentName: "test", analyses: inAn ?? analyses, zones: inZones ?? zones,
                                            engine: engine, settings: CompletionSettings(humanize: humanize, student: StudentProfile()),
                                            onlyZoneIDs: only) { log.record($0, $1, $2) }
}

/// Lance complete dans une Task, l'annule après `ms`, et renvoie (erreur, durée).
func runThenCancel(_ engine: FakeEngine, humanize: Bool, afterMs ms: Int, log: UpdateLog) async -> (Error?, Double) {
    let t0 = Date()
    let task = Task { try await runLogged(engine, humanize: humanize, log: log) }
    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    task.cancel()
    let r = await task.result
    if case .failure(let e) = r { return (e, Date().timeIntervalSince(t0)) }
    return (nil, Date().timeIntervalSince(t0))
}

// 8. annulation pendant les requêtes
do {
    let e = FakeEngine(); e.delayMs = 400; e.maxConcurrentPages = 2
    let log = UpdateLog()
    let (err, dt) = await runThenCancel(e, humanize: true, afterMs: 120, log: log)
    check(err is CancellationError, "annulation : CancellationError levée", "\(String(describing: err))")
    check(dt < 0.35, "annulation : retour immédiat (requêtes en cours annulées)", "\(dt) s")
    check(e.completeCalls.count == 2, "annulation : plus aucune requête lancée après l'annulation", "\(e.completeCalls.count)")
    check(e.cancelledCalls == 2, "annulation : les requêtes en cours sont annulées", "\(e.cancelledCalls)")
    check(log.last.allSatisfy { $0.error == nil }, "annulation : aucune zone marquée en erreur")
    check(e.humanizeCalls == 0, "annulation : pas d'humanisation")
}
// 8b. moteur qui enveloppe l'annulation dans une EngineError : toujours une annulation, pas une erreur de page
do {
    let e = FakeEngine(); e.delayMs = 400; e.failOnCancelWithEngineError = true
    let log = UpdateLog()
    let (err, _) = await runThenCancel(e, humanize: false, afterMs: 100, log: log)
    check(err is CancellationError, "annulation (EngineError à l'annulation) : CancellationError", "\(String(describing: err))")
    check(log.last.allSatisfy { $0.error == nil }, "annulation (EngineError à l'annulation) : zones sans erreur")
}
// 8c. Task déjà annulée avant le départ
do {
    let e = FakeEngine()
    let task = Task { () -> [Zone] in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await runLogged(e, humanize: true)
    }
    let r = await task.result
    var isCancel = false
    if case .failure(let err) = r { isCancel = err is CancellationError }
    check(isCancel && e.completeCalls.isEmpty, "annulation avant le départ : aucune requête", "\(e.completeCalls.count)")
}
// 8d. annulation pendant l'humanisation : réponses déjà obtenues livrées, erreur d'annulation
do {
    let e = FakeEngine(); e.humanizeDelayMs = 400
    let log = UpdateLog()
    let (err, dt) = await runThenCancel(e, humanize: true, afterMs: 250, log: log)
    check(err is CancellationError, "annulation pendant l'humanisation : CancellationError", "\(String(describing: err))")
    check(dt < 0.5, "annulation pendant l'humanisation : retour immédiat", "\(dt) s")
    check(e.humanizeCalls == 1, "annulation pendant l'humanisation : pas de lot suivant", "\(e.humanizeCalls)")
    check(log.last.filter { $0.enabled && $0.kind != .ignorer }.allSatisfy { !$0.answer.isEmpty && $0.error == nil },
          "annulation pendant l'humanisation : les réponses brutes sont livrées")
}

// 9. erreur fatale avec requêtes en parallèle : l'erreur fatale est levée (pas CancellationError), les pages interrompues ne sont pas en erreur
do {
    let e = FakeEngine(); e.fatalOnPage = 1; e.maxConcurrentPages = 3; e.delayMs = 50
    let log = UpdateLog()
    do { _ = try await runLogged(e, humanize: true, log: log); check(false, "fatale en parallèle", "pas d'erreur") }
    catch let err as EngineError { if case .auth = err { check(true, "fatale en parallèle : .auth levée") } else { check(false, "fatale en parallèle", "\(err)") } }
    catch { check(false, "fatale en parallèle", "\(error)") }
    check(e.humanizeCalls == 0, "fatale : pas d'humanisation")
    let othersWithError = log.last.filter { $0.page != 0 && $0.error != nil }
    check(othersWithError.isEmpty, "fatale : les pages interrompues ne sont pas marquées en erreur", "\(othersWithError.count)")
}

// 10. erreurs non fatales : état des champs, puis reprise ciblée
do {
    let e = FakeEngine(); e.failPages = [2]; e.failError = .rateLimited("trop de requêtes")
    let zones = try await run(e, humanize: true)
    let bad = zones.filter { $0.page == 1 }
    check(bad.allSatisfy { $0.error == "trop de requêtes" && $0.answer.isEmpty && $0.rawAnswer.isEmpty && !$0.humanized && $0.enabled },
          "page en erreur : error posée, answer/rawAnswer vides, humanized faux, enabled inchangé")
    check(zones.filter { $0.page != 1 && $0.error != nil }.isEmpty, "page en erreur : les autres zones sans erreur")
    check(!e.humanizedKinds.isEmpty && zones.filter { $0.page == 1 }.allSatisfy { !$0.humanized }, "page en erreur : jamais humanisée")
    let ids = CoursPipeline.zoneIDsInError(zones)
    check(ids.count == 4 && ids == Set(bad.map { $0.id }), "zoneIDsInError : les 4 zones de la page 2", "\(ids.count)")
    // reprise ciblée avec un moteur qui fonctionne
    let e2 = FakeEngine()
    let (analyses, _) = makeZones()
    let again = try await runLogged(e2, humanize: true, only: ids, zones: zones, analyses: analyses)
    check(e2.completeCalls.count == 1 && e2.completeCalls[0].page == 2 && e2.completeCalls[0].numbers.count == 4,
          "reprise ciblée : une seule requête, la page 2", "\(e2.completeCalls)")
    check(again.filter { $0.page == 1 }.allSatisfy { $0.error == nil }, "reprise : erreurs effacées")
    check(again.filter { $0.page == 1 && $0.enabled }.allSatisfy { !$0.answer.isEmpty && $0.rawAnswer != "" }, "reprise : réponses présentes")
    check(zip(again, zones).filter { $0.0.page != 1 }.allSatisfy { $0.0.answer == $0.1.answer && $0.0.humanized == $0.1.humanized },
          "reprise : les autres pages ne bougent pas")
    check(e2.humanizedKinds.count <= 4, "reprise : on n'humanise que les zones reprises", "\(e2.humanizedKinds.count)")
}
// 10b. régénération qui échoue : la réponse précédente est conservée, error posée
do {
    let first = try await run(FakeEngine(), humanize: true)
    let target = first.first { $0.page == 0 && $0.kind == .question && $0.enabled }!
    let e = FakeEngine(); e.failPages = [1]
    let again = try await run(e, humanize: true, only: [target.id], zones: first)
    let z = again.first { $0.id == target.id }!
    check(z.error != nil && z.answer == target.answer && z.rawAnswer == target.rawAnswer && z.humanized == target.humanized && z.enabled,
          "régénération en échec : ancienne réponse conservée, état cohérent")
    check(e.humanizeCalls == 0, "régénération en échec : pas d'humanisation de la zone en erreur")
}
// 10c. l'IA oublie une zone
do {
    let e = FakeEngine(); e.omitNumbers = [2]
    let zones = try await run(e, humanize: true)
    let omitted = zones.filter { $0.number == 2 }
    check(omitted.allSatisfy { $0.error == "L'IA n'a pas répondu pour cette zone." && $0.answer.isEmpty && !$0.humanized }, "zone oubliée : message sur cette zone seulement")
    check(zones.filter { $0.number != 2 && $0.error != nil }.isEmpty, "zone oubliée : les autres zones sont correctes")
}
// 10d. erreur fatale dans l'humanisation
do {
    final class FatalHumanize: CompletionEngine {
        let displayName = "x"; let usesImages = false; let maxConcurrentPages = 1
        let inner = FakeEngine()
        func complete(_ r: PageRequest) async throws -> [ZoneAnswer] { try await inner.complete(r) }
        func humanize(_ items: [HumanizeItem]) async throws -> [Int: String] { throw EngineError.auth("clé révoquée") }
    }
    do { _ = try await CoursPipeline.complete(url: pdfURL, documentName: "t", analyses: makeZones().0, zones: makeZones().1,
                                              engine: FatalHumanize(), settings: CompletionSettings(humanize: true, student: StudentProfile()),
                                              onlyZoneIDs: nil) { _, _, _ in }
         check(false, "fatale pendant l'humanisation", "pas d'erreur") }
    catch let err as EngineError { if case .auth = err { check(true, "fatale pendant l'humanisation : levée") } else { check(false, "fatale humanisation", "\(err)") } }
    catch { check(false, "fatale humanisation", "\(error)") }
}
// 10e. l'humanisation en panne s'arrête après 2 échecs de suite
do {
    let e = FakeEngine(); e.humanizeMode = "erreur"
    let log = UpdateLog()
    let zones = try await run2(e, log)
    check(e.humanizeCalls == 2, "humanisation en panne : 2 lots essayés puis arrêt", "\(e.humanizeCalls)")
    check(log.labels.contains { $0.hasPrefix("Humanisation impossible") }, "humanisation en panne : avertissement envoyé")
    check(zones.filter { $0.enabled && $0.kind == .question }.allSatisfy { $0.answer == $0.rawAnswer && !$0.answer.isEmpty }, "humanisation en panne : réponses d'origine gardées")
}
func run2(_ e: FakeEngine, _ log: UpdateLog) async throws -> [Zone] { try await runLogged(e, humanize: true, log: log) }

// 11. analyze : erreurs signalées
do {
    let dir = tmp.appendingPathComponent("analyze-cases"); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func message(_ url: URL) -> String? {
        do { _ = try CoursPipeline.analyzeChecked(url: url, needText: false) { _, _ in }; return nil }
        catch { return error.localizedDescription }
    }
    let ok = (try? CoursPipeline.analyzeChecked(url: pdfURL, needText: false) { _, _ in }) ?? []
    check(ok.count == 3, "analyzeChecked : PDF valide, 3 pages", "\(ok.count)")
    check(message(dir.appendingPathComponent("absent.pdf"))?.contains("introuvable") == true, "analyzeChecked : fichier absent")
    let garbage = dir.appendingPathComponent("garbage.pdf"); try? Data("ceci n'est pas un pdf".utf8).write(to: garbage)
    check(message(garbage)?.contains("pas un PDF lisible") == true, "analyzeChecked : fichier qui n'est pas un PDF", "\(message(garbage) ?? "nil")")
    check(CoursPipeline.analyze(url: garbage, needText: false, progress: { _, _ in }).isEmpty, "analyze (ancienne) : toujours [] sans lever d'erreur")
    let enc = dir.appendingPathComponent("protege.pdf")
    let d = PDFDocument(); d.insert(PDFPage(), at: 0)
    d.write(to: enc, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "secret2"])
    check(message(enc)?.contains("mot de passe") == true, "analyzeChecked : PDF protégé par mot de passe", "\(message(enc) ?? "nil")")
    let trunc = dir.appendingPathComponent("tronque.pdf")
    if let full = try? Data(contentsOf: pdfURL) { try? full.prefix(full.count / 3).write(to: trunc) }
    let tm = message(trunc)
    check(tm == nil || tm!.contains("PDF") || tm!.contains("page"), "analyzeChecked : PDF tronqué -> pages ou message en français", "\(tm ?? "ouvert")")
    let zero = dir.appendingPathComponent("zero.pdf")
    let zpdf = "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj\ntrailer<</Root 1 0 R/Size 3>>\n%%EOF\n"
    try? Data(zpdf.utf8).write(to: zero)
    let zm = message(zero)
    check(zm != nil && (zm!.contains("aucune page") || zm!.contains("pas un PDF lisible")), "analyzeChecked : PDF sans page", "\(zm ?? "nil")")
    // complete signale aussi un PDF illisible
    do { _ = try await runLogged(FakeEngine(), humanize: false, url: garbage); check(false, "complete sur PDF illisible", "pas d'erreur") }
    catch { check(error.localizedDescription.contains("pas un PDF lisible"), "complete : PDF illisible signalé en français", "\(error)") }
    // annulation de analyzeChecked
    let t = Task.detached { () -> Bool in
        withUnsafeCurrentTask { $0?.cancel() }
        do { _ = try CoursPipeline.analyzeChecked(url: pdfURL, needText: false) { _, _ in }; return false } catch { return error is CancellationError }
    }
    check(await t.value, "analyzeChecked : Task annulée -> CancellationError")
}

// 12. 100 pages, concurrence 3, images : mémoire, progression, rafales
do {
    let big = tmp.appendingPathComponent("big.pdf")
    let d = PDFDocument(); for i in 0..<100 { d.insert(PDFPage(), at: i) }
    d.write(to: big)
    let (analyses, zones) = makeBig(pages: 100, zonesPerPage: 3)
    let e = FakeEngine(); e.maxConcurrentPages = 3; e.usesImages = true
    let log = UpdateLog()
    let before = footprint()
    let t0 = Date()
    let out = try await CoursPipeline.complete(url: big, documentName: "gros", analyses: analyses, zones: zones, engine: e,
                                               settings: CompletionSettings(humanize: true, student: StudentProfile()),
                                               onlyZoneIDs: nil) { log.record($0, $1, $2) }
    let dt = Date().timeIntervalSince(t0)
    let after = footprint()
    let growthMB = Double(Int64(after) - Int64(before)) / 1_048_576
    let peakMB = Double(Int64(e.peakFootprint) - Int64(before)) / 1_048_576
    print(String(format: "      (100 pages : %.1f s, mémoire +%.0f Mo en fin, pic +%.0f Mo, %d mises à jour)", dt, growthMB, peakMB, log.count))
    check(out.count == 300 && out.filter { $0.enabled && $0.kind != .ignorer }.allSatisfy { !$0.answer.isEmpty && $0.error == nil }, "100 pages : toutes les zones traitées")
    check(e.completeCalls.count == 100 && e.maxInFlight <= 3, "100 pages : jamais plus de 3 requêtes en parallèle", "\(e.maxInFlight)")
    check(growthMB < 150 && peakMB < 250, "100 pages : pas d'accumulation mémoire", "fin +\(growthMB) Mo, pic +\(peakMB) Mo")
    let f = log.fractions
    check(zip(f, f.dropFirst()).allSatisfy { $0 <= $1 } && f.last == 1 && f.first == 0, "100 pages : progression croissante de 0 à 1")
    check(log.count < 60, "100 pages : mises à jour espacées (pas une par page)", "\(log.count)")
}
// 12b. aucune mise à jour limitée quand l'intervalle est nul
do {
    CoursPipeline.minUpdateInterval = 0
    let log = UpdateLog()
    _ = try await runLogged(FakeEngine(), humanize: false, log: log)
    check(log.count >= 5, "intervalle nul : une mise à jour par page", "\(log.count)")
    CoursPipeline.minUpdateInterval = 0.1
}

// 13. HumanizeGuard : nombres
func acc(_ o: String, _ c: String, max: Int = 200) -> Bool { HumanizeGuard.accept(original: o, candidate: c, maxChars: max) != nil }
check(acc("Le courant vaut 3,5 A dans le circuit.", "Dans le circuit, le courant est de 3,5 A."), "nombres : 3,5 conservé -> accepté")
check(acc("Le courant vaut 3,5 A dans le circuit.", "Dans le circuit, le courant est de 3.5 A."), "nombres : 3,5 -> 3.5 (point décimal) accepté")
check(!acc("Le courant vaut 3,5 A dans le circuit.", "Dans le circuit, le courant est de 3 A ou 5 A."), "nombres : 3,5 éclaté en 3 et 5 -> refusé")
check(!acc("Le courant vaut 3,5 A dans le circuit.", "Dans le circuit, le courant est de 35 A."), "nombres : 3,5 -> 35 refusé")
check(!acc("Le courant vaut 3,5 A dans le circuit.", "Dans le circuit, le courant est de 5 A."), "nombres : 3,5 -> 5 refusé")
check(acc("La puissance est de 2,50 kW au maximum.", "Au maximum, la puissance atteint 2,5 kW."), "nombres : 2,50 = 2,5")
check(acc("Il y a 1 000 W de puissance.", "La puissance est de 1000 W."), "nombres : 1 000 = 1000")
check(acc("Il y a 1\u{00A0}000 W de puissance.", "La puissance est de 1 000 W."), "nombres : espace insécable")
check(acc("Il y a 1\u{202F}000 W de puissance.", "La puissance est de 1000 W."), "nombres : espace fine insécable")
check(acc("La tension est de 230V en France.", "En France, la tension vaut 230 V."), "unités collées : 230V = 230 V")
check(acc("La tension est de 230 V en France.", "En France, la tension vaut 230V."), "unités : 230 V = 230V")
check(acc("La tension est de 230 V en France.", "En France, la tension est de 230 volts."), "unités : V = volts")
check(!acc("La tension est de 230 V en France.", "En France, la tension est de 230 A."), "unités : V -> A refusé")
check(!acc("La tension est de 230 V en France.", "En France, la tension est de 23 V."), "nombres : 230 -> 23 refusé")
check(acc("Le rendement est de 85 % environ.", "Le rendement vaut environ 85 %."), "pourcentage conservé")
check(acc("Le rendement est de 85 % environ.", "Le rendement vaut environ 85 pour cent."), "pourcentage : « pour cent »")
check(!acc("Le rendement est de 85 % environ.", "Le rendement est très élevé, environ 85."), "pourcentage perdu -> refusé")
check(acc("Le câble fait 2,5 mm² de section.", "La section du câble est de 2,5 mm²."), "nombres : mm²")
check(acc("Il y a 1.000 W de puissance.", "La puissance est de 1 000 W."), "nombres : 1.000 (milliers) = 1 000")
check(acc("Un disjoncteur de 16 A protège le circuit R1 de 100 Ω.", "Le circuit R1 de 100 Ω est protégé par un disjoncteur de 16 A."), "nombres : identifiants (R1) et unités")
check(acc("Le courant est de 3,5 A.", "Le courant est de 3,5 A.", max: 30), "nombres : texte identique accepté")

// 14. HumanizeGuard : inversion de sens
check(!acc("Le courant ne passe pas dans un isolant.", "Le courant passe dans un isolant."), "négation perdue -> refusé")
check(!acc("Un isolant laisse passer le courant.", "Un isolant ne laisse pas passer le courant."), "négation ajoutée -> refusé")
check(!acc("Il ne faut jamais toucher un fil dénudé.", "Il faut toucher un fil dénudé."), "« jamais » perdu -> refusé")
check(acc("Le courant ne passe pas dans un isolant.", "Un isolant ne laisse pas circuler le courant."), "négation conservée (paraphrase) -> accepté")
check(acc("Un circuit sans fusible n'est pas protégé.", "Quand il n'y a pas de fusible, le circuit n'est pas protégé."), "sans -> n'y a pas : accepté")
check(acc("Le courant ne passe plus dans le circuit.", "Le courant ne circule plus dans le circuit."), "ne…plus conservé")
check(acc("Un onduleur est plus efficace qu'un transformateur.", "Un onduleur est plus performant qu'un transformateur."), "« plus » comparatif n'est pas une négation")
check(acc("Il n'y a que 12 V dans ce circuit.", "Ce circuit ne reçoit que 12 V."), "ne…que n'est pas une négation")
check(acc("Il est sans doute dangereux de toucher ce fil.", "Toucher ce fil est probablement dangereux."), "« sans doute » n'est pas une négation")
check(!acc("Il y a aucun risque ici.", "Il y a un risque ici."), "« aucun » perdu -> refusé")
check(acc("La résistance mesure la difficulté du passage du courant.", "La résistance indique à quel point le courant a du mal à passer."), "paraphrase normale acceptée")
// 14b. présentation
check(!acc("Un fusible protège le circuit.", "Voici la réponse réécrite : un fusible protège le circuit."), "phrase d'introduction -> refusée")
check(!acc("Un fusible protège le circuit.", "- Un fusible protège\n- le circuit."), "liste à puces -> refusée")
check(!acc("Un fusible protège le circuit.", "Un **fusible** protège le circuit."), "balisage gras -> refusé")
check(!acc("Un fusible protège le circuit.", "Un fusible ⟦2⟧ protège le circuit."), "repère ⟦n⟧ -> refusé")

// 15. AnswerCleaner : cas limites
func cl(_ s: String, _ k: ZoneKind = .mot) -> String { AnswerCleaner.clean(s, kind: k) }
check(cl("") == "" && cl("   \n ") == "", "nettoyage : réponse vide")
check(cl("\"\"") == "" && cl("«»") == "" && cl("« »") == "" && cl("\"") == "" && cl("“”") == "", "nettoyage : que des guillemets -> vide")
check(cl("...") == "" && cl("⟦3⟧") == "" && cl(" . ; ") == "", "nettoyage : que de la ponctuation / un repère -> vide")
check(cl("Volt\n") == "Volt" && cl("\nVolt\n\n") == "Volt", "nettoyage : retours à la ligne autour")
check(cl("Volt\nAmpère") == "Volt Ampère", "nettoyage : retour à la ligne au milieu")
check(cl("etc.") == "etc." && cl("« etc. »") == "etc." && cl("Etc.") == "Etc.", "nettoyage : « etc. » garde son point")
check(cl("résistances, etc.") == "résistances, etc." && cl("résistances, etc..") == "résistances, etc." , "nettoyage : etc. en fin de liste", cl("résistances, etc.."))
check(cl("arc-en-ciel.") == "arc-en-ciel" && cl("porte-clés") == "porte-clés" && cl("c'est-à-dire") == "c'est-à-dire", "nettoyage : mots composés")
check(cl("3,5.") == "3,5" && cl("« 3,5. »") == "3,5" && cl("3,5") == "3,5" && cl("230 V.") == "230 V", "nettoyage : nombre avec point final")
check(cl("S.I.") == "S.I." && cl("env.") == "env.", "nettoyage : sigles et abréviations gardent leur point")
check(cl("\"Volt\".") == "Volt" && cl("« Volt. »") == "Volt" && cl("« “Volt” »") == "Volt", "nettoyage : guillemets imbriqués / ponctuation dans les guillemets")
check(cl("'volt'") == "volt" && cl("« Volt") == "Volt" && cl("Volt »") == "Volt", "nettoyage : guillemets simples ou isolés")
check(cl("\"a\" et \"b\"", .question) == "\"a\" et \"b\"", "nettoyage : deux citations ne sont pas « entourées »")
check(cl("**Volt**") == "Volt" && cl("`Volt`") == "Volt" && cl("- Volt") == "Volt" && cl("-5") == "-5", "nettoyage : gras, code, puce ; nombre négatif intact")
check(cl("Il fait 3,5.", .question) == "Il fait 3,5.", "nettoyage : phrase (question) garde son point final")
check(cl("Volt\u{200B}") == "Volt" && cl("Le  courant   passe", .question) == "Le courant passe", "nettoyage : espaces et caractères invisibles")
check(["«\u{00A0}Volt\u{00A0}».", "etc.", "\"a\" et \"b\"", "3,5.", "résistances, etc.."].allSatisfy { cl(cl($0)) == cl($0) }, "nettoyage : idempotent")

print(failures == 0 ? "\nTOUT PASSE" : "\n\(failures) ÉCHEC(S)")
exit(failures == 0 ? 0 : 1)
