import Foundation
import CoreGraphics
import CoreText

// Tests du dépôt automatique (Sources/Core/FolderWatcher.swift) : dossiers temporaires, faux classeur d'IA, aucun réseau,
// aucun vrai cours.

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("ÉCHEC (ligne \(line)) : \(what)") }
}

let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("watcher-tests-\(UUID().uuidString)")
try fm.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: base) }

func freshDir(_ name: String) -> URL {
    let d = base.appendingPathComponent(name + "-" + UUID().uuidString.prefix(6))
    try? fm.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

let minimalPDF = Data("%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n".utf8)
func writePDF(_ url: URL) { try? minimalPDF.write(to: url) }

/// Vrai PDF d'une page avec du texte (pour le test de rangement).
func makeTextPDF(_ url: URL, text: String) {
    var box = CGRect(x: 0, y: 0, width: 400, height: 400)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    ctx.beginPDFPage(nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)]))
    ctx.textPosition = CGPoint(x: 20, y: 300)
    CTLineDraw(line, ctx)
    ctx.endPDFPage(); ctx.closePDF()
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var outcome: IntakeOutcome = .filed
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func count(_ s: String) -> Int { all.filter { $0 == s }.count }
}

func waitUntil(_ seconds: Double = 8, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
    return cond()
}
func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

func makeWatcher(_ folder: URL, state: URL?, rec: Recorder, stable: Double = 0.4) -> FolderWatcher {
    FolderWatcher(folder: folder, stateURL: state, stableSeconds: stable, pollInterval: 0.1) { url in
        rec.add(url.lastPathComponent); return rec.outcome
    }
}

// MARK: détection, fichier non PDF, sous-dossier, caché, lien, téléchargement en cours

do {
    let dir = freshDir("detect"), rec = Recorder()
    let w = makeWatcher(dir, state: nil, rec: rec)
    w.start(freshActivation: true)
    check(w.isRunning, "actif après start")
    writePDF(dir.appendingPathComponent("Cours Maths.pdf"))
    check(await waitUntil { rec.count("Cours Maths.pdf") == 1 }, "un nouveau PDF est détecté")

    try? Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
    try? Data("x".utf8).write(to: dir.appendingPathComponent("devoir.docx"))
    try? fm.createDirectory(at: dir.appendingPathComponent("sous"), withIntermediateDirectories: true)
    writePDF(dir.appendingPathComponent("sous/Autre.pdf"))
    writePDF(dir.appendingPathComponent(".cache.pdf"))
    try? fm.createDirectory(at: dir.appendingPathComponent("Dossier.pdf"), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(at: dir.appendingPathComponent("Lien.pdf"), withDestinationURL: dir.appendingPathComponent("Cours Maths.pdf"))
    try? Data("%PDF-1.4 coupé".utf8).write(to: dir.appendingPathComponent("Coupé.pdf"))   // pas de %%EOF
    await pause(1.5)
    check(rec.all == ["Cours Maths.pdf"], "non-PDF, sous-dossier, caché, dossier, alias, PDF coupé ignorés : \(rec.all)")

    // téléchargements en cours
    try? minimalPDF.write(to: dir.appendingPathComponent("A.pdf.crdownload"))
    try? minimalPDF.write(to: dir.appendingPathComponent("B.pdf.download"))
    try? minimalPDF.write(to: dir.appendingPathComponent("C.pdf.part"))
    await pause(1.2)
    check(rec.all == ["Cours Maths.pdf"], "téléchargement en cours ignoré : \(rec.all)")
    // fin du téléchargement : renommage en .pdf
    try? fm.moveItem(at: dir.appendingPathComponent("A.pdf.crdownload"), to: dir.appendingPathComponent("A.pdf"))
    check(await waitUntil { rec.count("A.pdf") == 1 }, "le PDF est pris dès que le téléchargement est fini")
    check(rec.all.count == 2, "seulement 2 fichiers traités : \(rec.all)")
    w.stop()
}

// MARK: fichier qui grandit : pas traité avant d'être stable

do {
    let dir = freshDir("grow"), rec = Recorder()
    let w = makeWatcher(dir, state: nil, rec: rec, stable: 0.8)
    w.start(freshActivation: true)
    let url = dir.appendingPathComponent("Gros.pdf")
    try? Data("%PDF-1.4\n".utf8).write(to: url)
    for _ in 0..<6 {
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(String(repeating: "x", count: 500).utf8)); try? h.close() }
        await pause(0.25)
    }
    check(rec.all.isEmpty, "un fichier qui grandit n'est pas traité : \(rec.all)")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data("\n%%EOF\n".utf8)); try? h.close() }
    check(await waitUntil { rec.count("Gros.pdf") == 1 }, "traité une fois stable et terminé")
    w.stop()
}

// MARK: doublon : jamais deux fois, même après redémarrage

do {
    let dir = freshDir("dup"), state = freshDir("dup-state").appendingPathComponent("etat.json"), rec = Recorder()
    let w = makeWatcher(dir, state: state, rec: rec)
    w.start(freshActivation: true)
    writePDF(dir.appendingPathComponent("Une fois.pdf"))
    check(await waitUntil { rec.count("Une fois.pdf") == 1 }, "traité")
    await pause(1.5)
    check(rec.count("Une fois.pdf") == 1, "pas traité deux fois pendant la surveillance")
    w.stop()
    let rec2 = Recorder()
    let w2 = makeWatcher(dir, state: state, rec: rec2)
    w2.start(freshActivation: false)
    await pause(1.5)
    check(rec2.all.isEmpty, "mémorisé : pas retraité après relance : \(rec2.all)")
    w2.stop()
}

// MARK: activation / désactivation / rattrapage

do {
    let dir = freshDir("onoff"), state = freshDir("onoff-state").appendingPathComponent("etat.json"), rec = Recorder()
    writePDF(dir.appendingPathComponent("Ancien.pdf"))               // avant l'activation
    await pause(1.1)
    let w = makeWatcher(dir, state: state, rec: rec)
    check(!w.isRunning, "désactivé au départ")
    w.start(freshActivation: true)
    await pause(1.2)
    check(rec.all.isEmpty, "un PDF antérieur à l'activation n'est pas traité : \(rec.all)")
    writePDF(dir.appendingPathComponent("Pendant.pdf"))
    check(await waitUntil { rec.count("Pendant.pdf") == 1 }, "apparu depuis l'activation : traité")
    w.stop()
    check(!w.isRunning, "arrêté après stop")

    // rattrapage : un PDF apparaît pendant que la surveillance est arrêtée (app fermée), puis relance sans « fraîche »
    writePDF(dir.appendingPathComponent("Rattrapage.pdf"))
    await pause(0.3)
    check(rec.count("Rattrapage.pdf") == 0, "rien tant que c'est désactivé")
    let w2 = makeWatcher(dir, state: state, rec: rec)
    w2.start(freshActivation: false)
    check(await waitUntil { rec.count("Rattrapage.pdf") == 1 }, "balayage de rattrapage au démarrage")
    check(rec.count("Ancien.pdf") == 0 && rec.count("Pendant.pdf") == 1, "rattrapage limité aux fichiers apparus depuis l'activation : \(rec.all)")
    w2.stop()

    // nouvelle activation : repart de zéro, ce qui est apparu pendant la pause est ignoré
    writePDF(dir.appendingPathComponent("Pause.pdf"))
    await pause(0.3)
    let w3 = makeWatcher(dir, state: state, rec: rec)
    w3.start(freshActivation: true)
    await pause(1.5)
    check(rec.count("Pause.pdf") == 0, "réactivation : l'ancien contenu n'est pas traité : \(rec.all)")
    w3.stop()
}

// MARK: IA indisponible : le fichier attend, sans boucle

do {
    let dir = freshDir("wait"), rec = Recorder()
    rec.outcome = .unavailable
    let w = makeWatcher(dir, state: nil, rec: rec)
    w.start(freshActivation: true)
    writePDF(dir.appendingPathComponent("Attend.pdf"))
    check(await waitUntil { w.deferredCount == 1 }, "un fichier en attente est compté")
    await pause(1.2)
    check(rec.count("Attend.pdf") == 1, "pas de boucle de nouvelles tentatives : \(rec.all)")
    rec.outcome = .filed
    w.retryDeferred()
    check(await waitUntil { rec.count("Attend.pdf") == 2 }, "retenté après retryDeferred")
    w.stop()
}

// MARK: rangement (faux classeur d'IA)

final class FakeAI: StructuredGenerator, @unchecked Sendable {
    var displayName: String { "Faux classeur" }
    var supportsImages: Bool { false }
    var reply: String
    var fail = false
    private(set) var seen: [String] = []
    init(_ reply: String) { self.reply = reply }
    func generate(system: String, userText: String, images: [Data], schema: [String: Any]) async throws -> String {
        seen.append(userText)
        if fail { throw CoursError.message("IA en panne") }
        return reply
    }
}
func course(_ folder: String) -> String {
    #"{"estUnCours": true, "propositions": [{"chemin": "À ranger/CHEMIN", "dossier": "\#(folder)", "nouveauNom": "", "raison": "Maths."}]}"#
}
func reply(_ folder: String, file: String) -> String { course(folder).replacingOccurrences(of: "CHEMIN", with: file) }

do {
    let downloads = freshDir("dl"), root = freshDir("cours"), ledgerDir = freshDir("journal")
    try fm.createDirectory(at: root.appendingPathComponent("Maths/Cours"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("Maths/Évaluations"), withIntermediateDirectories: true)
    let ledger = CourseLedger(directory: ledgerDir)

    // un cours : rangé, journalisé, annulable
    let pdf = downloads.appendingPathComponent("Suites numériques.pdf")
    makeTextPDF(pdf, text: "MOTSECRETDUCOURS suites arithmetiques")
    let ai = FakeAI(reply("Maths/Cours", file: "Suites numériques.pdf"))
    let r = await AutoIntakeProcessor.process(pdf, watchedFolder: downloads, root: root, ledger: ledger, generator: ai)
    if case .filed(let rec, let folder, let name) = r {
        check(folder == "Maths/Cours" && name == "Suites numériques.pdf", "dossier et nom : \(folder) \(name)")
        check(rec.origin == .depot, "journal : origine dépôt")
        check(fm.fileExists(atPath: root.appendingPathComponent("Maths/Cours/Suites numériques.pdf").path) && !fm.fileExists(atPath: pdf.path), "fichier déplacé")
        check(ledger.moves.contains { $0.id == rec.id }, "mouvement dans le journal")
        check(ai.seen.first?.contains("MOTSECRETDUCOURS") == true, "extrait de la première page envoyé pour un cours")
        if case .restored = ledger.undo(rec.id) { check(fm.fileExists(atPath: pdf.path), "annulation : revenu dans Téléchargements") }
        else { check(false, "annulation refusée") }
    } else { check(false, "attendu .filed, obtenu \(r)") }

    // jamais d'écrasement
    try? Data("EXISTANT".utf8).write(to: root.appendingPathComponent("Maths/Cours/Suites numériques.pdf"))
    let r2 = await AutoIntakeProcessor.process(pdf, watchedFolder: downloads, root: root, ledger: ledger, generator: ai)
    if case .filed(_, _, let name) = r2 {
        check(name == "Suites numériques (2).pdf", "pas d'écrasement : \(name)")
        check(String(data: (try? Data(contentsOf: root.appendingPathComponent("Maths/Cours/Suites numériques.pdf"))) ?? Data(), encoding: .utf8) == "EXISTANT", "fichier existant intact")
    } else { check(false, "attendu .filed (2), obtenu \(r2)") }

    // pas un cours : reste en place, rien de déplacé ni de journalisé
    let facture = downloads.appendingPathComponent("Facture EDF.pdf")
    makeTextPDF(facture, text: "Facture numero 123")
    let movesBefore = ledger.moves.count
    let notCourse = FakeAI(#"{"estUnCours": false, "propositions": []}"#)
    let r3 = await AutoIntakeProcessor.process(facture, watchedFolder: downloads, root: root, ledger: ledger, generator: notCourse)
    check(r3 == .notACourse && fm.fileExists(atPath: facture.path) && ledger.moves.count == movesBefore, "facture : reste où elle est")

    // évaluation par le nom : contenu jamais lu ni envoyé, rangée d'après son nom
    let ctrl = downloads.appendingPathComponent("Contrôle 3 suites.pdf")
    makeTextPDF(ctrl, text: "SECRETEVALUATION question 1")
    let aiEval = FakeAI(reply("Maths/Évaluations", file: "Contrôle 3 suites.pdf"))
    let r4 = await AutoIntakeProcessor.process(ctrl, watchedFolder: downloads, root: root, ledger: ledger, generator: aiEval)
    check({ if case .filed = r4 { return true }; return false }(), "évaluation rangée : \(r4)")
    check(aiEval.seen.count == 1 && !aiEval.seen[0].contains("SECRETEVALUATION"), "contenu d'une évaluation jamais envoyé (nom)")
    check(fm.fileExists(atPath: root.appendingPathComponent("Maths/Évaluations/Contrôle 3 suites.pdf").path), "évaluation dans Évaluations")

    // évaluation reconnue par l'en-tête : l'extrait lu en local n'est pas envoyé
    let hdr = downloads.appendingPathComponent("Sujet.pdf")
    makeTextPDF(hdr, text: "Evaluation de maths SECRETENTETE")
    let aiHdr = FakeAI(reply("Maths/Évaluations", file: "Sujet.pdf"))
    _ = await AutoIntakeProcessor.process(hdr, watchedFolder: downloads, root: root, ledger: ledger, generator: aiHdr)
    check(aiHdr.seen.count == 1 && !aiHdr.seen[0].contains("SECRETENTETE") && aiHdr.seen[0].contains("contenu non lu"), "évaluation par en-tête : rien d'envoyé")

    // IA indisponible : rien déplacé
    let a = downloads.appendingPathComponent("Attente.pdf"); makeTextPDF(a, text: "Cours de physique")
    let r5 = await AutoIntakeProcessor.process(a, watchedFolder: downloads, root: root, ledger: ledger, generator: nil)
    check(r5 == .unavailable && fm.fileExists(atPath: a.path), "sans IA : rien déplacé")
    let broken = FakeAI(""); broken.fail = true
    let r6 = await AutoIntakeProcessor.process(a, watchedFolder: downloads, root: root, ledger: ledger, generator: broken)
    check(r6 == .unavailable && fm.fileExists(atPath: a.path), "IA en panne : rien déplacé")

    // réponse illisible ou sans « estUnCours » : rien déplacé
    let junk = FakeAI(#"{"propositions": []}"#)
    let r7 = await AutoIntakeProcessor.process(a, watchedFolder: downloads, root: root, ledger: ledger, generator: junk)
    check({ if case .failed = r7 { return true }; return false }() && fm.fileExists(atPath: a.path), "réponse sans estUnCours : rien déplacé")

    // un cours sans proposition : il reste où il est (jamais de nouvelle matière inventée)
    let noProp = FakeAI(#"{"estUnCours": true, "propositions": []}"#)
    let r8 = await AutoIntakeProcessor.process(a, watchedFolder: downloads, root: root, ledger: ledger, generator: noProp)
    check(r8 == .unavailable && fm.fileExists(atPath: a.path), "sans proposition : le fichier reste en attente")

    // garde-fou : fichier hors du dossier surveillé
    let outside = freshDir("dehors").appendingPathComponent("Hors.pdf"); makeTextPDF(outside, text: "x")
    let r9 = await AutoIntakeProcessor.process(outside, watchedFolder: downloads, root: root, ledger: ledger, generator: ai)
    check({ if case .failed = r9 { return true }; return false }() && fm.fileExists(atPath: outside.path), "hors du dossier surveillé : refusé")
}

// MARK: ensemble : surveillant + rangement

do {
    let downloads = freshDir("e2e-dl"), root = freshDir("e2e-cours"), ledger = CourseLedger(directory: freshDir("e2e-journal"))
    try fm.createDirectory(at: root.appendingPathComponent("Maths/Cours"), withIntermediateDirectories: true)
    let ai = FakeAI(reply("Maths/Cours", file: "Fiche.pdf"))
    let w = FolderWatcher(folder: downloads, stateURL: nil, stableSeconds: 0.4, pollInterval: 0.1) { url in
        await AutoIntakeProcessor.process(url, watchedFolder: downloads, root: root, ledger: ledger, generator: ai).outcome
    }
    w.start(freshActivation: true)
    makeTextPDF(downloads.appendingPathComponent("Fiche.pdf"), text: "Fiche de maths")
    check(await waitUntil { fm.fileExists(atPath: root.appendingPathComponent("Maths/Cours/Fiche.pdf").path) }, "de bout en bout : rangé")
    check(ledger.moves.count == 1 && ledger.moves[0].origin == .depot, "de bout en bout : un seul mouvement journalisé")
    await pause(1)
    check(ai.seen.count == 1, "l'IA n'est appelée qu'une fois")
    w.stop()
}

if failures == 0 { print("Watcher : tout est vert."); exit(0) }
print("Watcher : \(failures) échec(s)."); exit(1)
