import Foundation
import AppKit
import PDFKit

// Tests de BatchCompleter (le chemin commun du bouton « Compléter la sélection » et de --selftest), avec un faux moteur :
// copie correcte, jamais d'écrasement, jamais d'évaluation, erreur fatale, journal. Aucun réseau.

var passed = 0, failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passed += 1 } else { failed += 1; print("  ECHEC (ligne \(line)) : \(what)") }
}
func section(_ t: String) { print("== \(t)") }

final class FakeEngine: CompletionEngine, @unchecked Sendable {
    let displayName = "Moteur de test", usesImages = true, maxConcurrentPages = 1
    var mode = "ok"      // ok | auth | reseau
    func complete(_ request: PageRequest) async throws -> [ZoneAnswer] {
        if mode == "auth" { throw EngineError.auth("La clé API a été refusée (clé de test).") }
        if mode == "reseau" { throw EngineError.network("Panne de réseau simulée.") }
        return request.zones.map { ZoneAnswer(number: $0.number, kind: $0.kind == .ignorer ? .question : $0.kind, text: "réponse \($0.number)") }
    }
    func humanize(_ items: [HumanizeItem]) async throws -> [Int: String] { [:] }
}

func makePDF(_ url: URL, withHoles: Bool) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    func text(_ s: String, _ y: CGFloat) {
        (s as NSString).draw(at: NSPoint(x: 50, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
    }
    text("Les énergies renouvelables", 780)
    if withHoles {
        text("Le soleil est une énergie \(String(repeating: "…", count: 22)) car elle se renouvelle.", 730)
        text("Un panneau transforme la lumière en \(String(repeating: ".", count: 40)) électrique.", 700)
        text("Question : pourquoi faut-il économiser l'énergie ?", 570)
        text(String(repeating: "_", count: 70), 548)
        text(String(repeating: "_", count: 70), 528)
    } else { text("Une page sans aucun trou à remplir.", 740) }
    NSGraphicsContext.restoreGraphicsState(); ctx.endPDFPage(); ctx.closePDF()
}

func listing(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

@MainActor
func runAll() async {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("batch-tests-\(getpid())")
    try? fm.removeItem(at: base)
    defer { try? fm.removeItem(at: base) }
    let root = base.appendingPathComponent("Cours")
    let src = root.appendingPathComponent("Sciences/Cours/energie.pdf")
    makePDF(src, withHoles: true)
    let original = try! Data(contentsOf: src)
    var settings = RunSettings.current()
    settings.engine = .claude; settings.humanize = false
    let engine = FakeEngine()
    let factory: (RunSettings) throws -> CompletionEngine = { _ in engine }
    let ledger = CourseLedger(directory: base.appendingPathComponent("support"))

    section("Copie complétée")
    var r = await BatchCompleter.complete(url: src, root: root, settings: settings, engineFactory: factory, ledger: ledger)
    let copy = root.appendingPathComponent("Sciences/Cours/energie (complétée).pdf")
    check(r.ok && r.written, "la copie est écrite (\(r.problems))")
    check(r.output.standardizedFileURL == copy.standardizedFileURL, "nom « (complétée) »")
    check(r.zones >= 3 && r.answered == r.zones, "toutes les zones répondues (\(r.answered)/\(r.zones))")
    check(PDFDocument(url: copy)?.pageCount == r.pages && r.pages == 1, "la copie s'ouvre, même nombre de pages")
    check(try! Data(contentsOf: src) == original, "l'original n'est pas modifié")
    check(listing(src.deletingLastPathComponent()) == ["energie (complétée).pdf", "energie.pdf"], "aucun fichier temporaire : \(listing(src.deletingLastPathComponent()))")
    check(ledger.isAppCopy(copy) && ledger.isCompletedByApp(src) && ledger.completions.first?.engine == settings.engineDisplayName, "complétion inscrite au journal")

    section("Jamais d'écrasement")
    let before = try! Data(contentsOf: copy)
    r = await BatchCompleter.complete(url: src, output: copy, root: root, settings: settings, engineFactory: factory)
    check(!r.written && !r.problems.isEmpty && r.problems[0].contains("existe déjà"), "sortie existante refusée : \(r.problems)")
    check(try! Data(contentsOf: copy) == before, "le fichier existant est intact")
    check(BatchCompleter.copyURL(for: src).lastPathComponent == "energie (complétée 2).pdf", "le nom suivant est libre")
    r = await BatchCompleter.complete(url: src, root: root, settings: settings, engineFactory: factory, ledger: ledger)
    check(r.ok && r.output.lastPathComponent == "energie (complétée 2).pdf" && fm.fileExists(atPath: copy.path), "deuxième lot : « (complétée 2) », la première copie reste")
    // sortie explicite : autorisée à remplacer seulement avec allowOverwrite (--selftest)
    let explicit = base.appendingPathComponent("sortie.pdf")
    try! Data("ancien".utf8).write(to: explicit)
    r = await BatchCompleter.complete(url: src, output: explicit, settings: settings, engineFactory: factory, allowOverwrite: true, keepOnProblems: true)
    check(r.ok && PDFDocument(url: explicit) != nil, "--selftest : la sortie choisie est remplacée")
    r = await BatchCompleter.complete(url: src, output: src, settings: settings, engineFactory: factory, allowOverwrite: true)
    check(!r.written && (try! Data(contentsOf: src)) == original, "sortie = entrée refusée")

    section("Évaluations")
    let evalFile = root.appendingPathComponent("Maths/Évaluations/Chapitre 2.pdf")
    makePDF(evalFile, withHoles: true)
    let evalByName = root.appendingPathComponent("Maths/Cours/Contrôle 1.pdf")
    makePDF(evalByName, withHoles: true)
    for f in [evalFile, evalByName] {
        let n = listing(f.deletingLastPathComponent())
        r = await BatchCompleter.complete(url: f, root: root, settings: settings, engineFactory: factory, ledger: ledger)
        check(!r.written && r.hardProblems.first?.contains("évaluation") == true, "refusée : \(f.lastPathComponent)")
        check(listing(f.deletingLastPathComponent()) == n, "aucun fichier créé à côté de \(f.lastPathComponent)")
    }
    check(engine.mode == "ok", "(moteur non appelé pour une évaluation)")

    section("Erreurs")
    engine.mode = "auth"
    let n0 = listing(src.deletingLastPathComponent())
    r = await BatchCompleter.complete(url: src, root: root, settings: settings, engineFactory: factory, ledger: ledger)
    check(r.fatal && !r.written, "clé refusée : erreur fatale, rien écrit (\(r.hardProblems))")
    check(listing(src.deletingLastPathComponent()) == n0, "aucun fichier créé ni temporaire laissé")
    engine.mode = "reseau"
    r = await BatchCompleter.complete(url: src, root: root, settings: settings, engineFactory: factory, ledger: ledger)
    check(!r.fatal && !r.ok, "panne de réseau : pas fatale, signalée (\(r.problems))")
    engine.mode = "ok"
    let before2 = ledger.completions.count
    let vide = root.appendingPathComponent("Sciences/Cours/vide.pdf"); makePDF(vide, withHoles: false)
    r = await BatchCompleter.complete(url: vide, root: root, settings: settings, engineFactory: factory, ledger: ledger)
    check(!r.written && r.hardProblems.first?.contains("Aucun trou") == true, "PDF sans trou : pas de copie inutile")
    r = await BatchCompleter.complete(url: root.appendingPathComponent("absent.pdf"), root: root, settings: settings, engineFactory: factory)
    check(!r.written && !r.problems.isEmpty, "fichier absent : refusé")
    let junk = root.appendingPathComponent("Sciences/Cours/abime.pdf"); try! Data("pas un pdf".utf8).write(to: junk)
    r = await BatchCompleter.complete(url: junk, root: root, settings: settings, engineFactory: factory)
    check(!r.written && !r.problems.isEmpty, "PDF abîmé : refusé (\(r.problems))")
    check(ledger.completions.count == before2, "les échecs ne sont pas inscrits au journal")
    let throwing: (RunSettings) throws -> CompletionEngine = { _ in throw EngineError.unavailable("Moteur absent.") }
    r = await BatchCompleter.complete(url: src, root: root, settings: settings, engineFactory: throwing)
    check(r.fatal && !r.written, "moteur indisponible : fatal")
}

_ = NSApplication.shared
Task { @MainActor in
    await runAll()
    print("\nRésultat : \(passed) réussis, \(failed) échec(s)")
    exit(failed == 0 ? 0 : 1)
}
dispatchMain()
