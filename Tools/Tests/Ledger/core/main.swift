import Foundation
import AppKit
import PDFKit

// Tests du journal : écriture/relecture, fichier abîmé, annulation après redémarrage, refus sans écrasement,
// cache de lecture (taille/date), cache des réponses de l'IA, lecture réelle d'un PDF avec le cache.

var passed = 0, failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passed += 1 } else { failed += 1; print("  ECHEC (ligne \(line)) : \(what)") }
}
func section(_ t: String) { print("== \(t)") }

let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("ledger-tests-\(getpid())")
try? fm.removeItem(at: base)
try! fm.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: base) }
var counter = 0
func fresh() -> URL { counter += 1; let d = base.appendingPathComponent("t\(counter)"); try! fm.createDirectory(at: d, withIntermediateDirectories: true); return d }
func write(_ url: URL, _ text: String) { try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try! text.write(to: url, atomically: true, encoding: .utf8) }
func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

// 1. écriture / relecture
section("Écriture et relecture")
do {
    let dir = fresh(), files = fresh()
    let a = files.appendingPathComponent("Maths/a.pdf"), b = files.appendingPathComponent("Sciences/a.pdf")
    let l = CourseLedger(directory: dir)
    check(l.moves.isEmpty && l.completions.isEmpty, "journal neuf vide")
    l.recordCompletion(original: a, copy: files.appendingPathComponent("a (complétée).pdf"), engine: "Moteur de test")
    l.recordMove(from: a, to: b, origin: .analyse)
    l.storeAI("k1", json: "{\"propositions\":[]}")
    check(fm.fileExists(atPath: l.fileURL.path), "le fichier JSON existe")
    let l2 = CourseLedger(directory: dir)
    check(l2.moves.count == 1 && l2.moves[0].from == a.standardizedFileURL.path && l2.moves[0].to == b.standardizedFileURL.path, "rangement relu")
    check(l2.moves[0].origin == .analyse, "origine relue")
    check(l2.completions.count == 1 && l2.completions[0].engine == "Moteur de test", "complétion relue")
    check(l2.cachedAI("k1") == "{\"propositions\":[]}", "réponse IA relue")
    check(l2.isAppCopy(files.appendingPathComponent("a (complétée).pdf")), "copie reconnue")
    // la complétion a suivi le fichier déplacé (original a → b)
    check(l2.isCompletedByApp(b) && !l2.isAppCopy(b), "l'original déplacé reste reconnu comme déjà complété")
    check(l.lastSaveError == nil, "pas d'erreur d'écriture")
    check(!fm.contents(atPath: l.fileURL.path)!.isEmpty && (try? JSONSerialization.jsonObject(with: Data(contentsOf: l.fileURL))) != nil, "JSON valide")
    let leftovers = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
    check(leftovers == ["journal.json"], "écriture atomique : aucun fichier temporaire (\(leftovers))")
}

// 2. absent / corrompu
section("Fichier absent ou corrompu")
do {
    let dir = fresh().appendingPathComponent("pas/encore/cree")
    let l = CourseLedger(directory: dir)
    check(l.moves.isEmpty && !l.wasCorrupt, "dossier inexistant : journal vide")
    l.recordCompletion(original: dir.appendingPathComponent("x.pdf"), copy: dir.appendingPathComponent("y.pdf"), engine: "e")
    check(fm.fileExists(atPath: l.fileURL.path), "le dossier est créé à la première écriture")

    for (i, junk) in ["", "pas du json {{{", "{\"version\":1,\"moves\":\"oups\"}", "[1,2,3]"].enumerated() {
        let d = fresh()
        write(d.appendingPathComponent("journal.json"), junk)
        let c = CourseLedger(directory: d)
        check(c.moves.isEmpty && c.completions.isEmpty && c.digestCount == 0, "contenu abîmé n°\(i) : repart à vide sans planter")
        check(c.wasCorrupt, "contenu abîmé n°\(i) signalé")
        check(read(d.appendingPathComponent("journal.json.corrompu")) == junk, "contenu abîmé n°\(i) conservé à côté")
        c.recordMove(from: d.appendingPathComponent("a.pdf"), to: d.appendingPathComponent("b.pdf"), origin: .depot)
        check(CourseLedger(directory: d).moves.count == 1, "après un fichier abîmé, le journal fonctionne à nouveau")
    }
}

// 3. annulation après redémarrage
section("Annulation (y compris après redémarrage)")
do {
    let dir = fresh(), root = fresh()
    let from = root.appendingPathComponent("Maths/Cours/Séquence 1.pdf"), to = root.appendingPathComponent("Sciences/Cours/Seq 1.pdf")
    write(from, "contenu A")
    try! fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! fm.moveItem(at: from, to: to)
    CourseLedger(directory: dir).recordMove(from: from, to: to, origin: .analyse)
    // « redémarrage » : nouvelle instance qui relit le disque
    let l = CourseLedger(directory: dir)
    check(l.moves.count == 1, "le rangement survit au redémarrage")
    let outcome = l.undo(l.moves[0].id)
    check(outcome == .restored(from.standardizedFileURL) || outcome == .restored(from), "annulation : \(outcome)")
    check(read(from) == "contenu A" && !fm.fileExists(atPath: to.path), "le fichier est revenu")
    check(l.moves.isEmpty && CourseLedger(directory: dir).moves.isEmpty, "l'entrée annulée disparaît, aussi après redémarrage")
    if case .refused = l.undo(UUID()) {} else { check(false, "un identifiant inconnu est refusé") }
}

section("Refus d'annuler : rien n'est écrasé")
do {
    let dir = fresh(), root = fresh()
    let l = CourseLedger(directory: dir)
    // emplacement d'origine pris par un autre fichier
    let from = root.appendingPathComponent("A/x.pdf"), to = root.appendingPathComponent("B/x.pdf")
    write(to, "arrivé"); write(from, "autre fichier arrivé depuis")
    let r1 = l.recordMove(from: from, to: to, origin: .analyse)
    if case .refused(let why) = l.undo(r1.id) { check(why.contains("déjà pris"), "message : \(why)") } else { check(false, "origine prise → refus") }
    check(read(from) == "autre fichier arrivé depuis" && read(to) == "arrivé", "aucun des deux fichiers n'a changé")
    check(l.moves.count == 1, "l'entrée reste dans l'historique")
    // fichier disparu
    let from2 = root.appendingPathComponent("A/y.pdf"), to2 = root.appendingPathComponent("B/y.pdf")
    try! fm.createDirectory(at: root.appendingPathComponent("B"), withIntermediateDirectories: true)
    let r2 = l.recordMove(from: from2, to: to2, origin: .depot)
    if case .refused(let why) = l.undo(r2.id) { check(why.contains("n'est plus là"), "message : \(why)") } else { check(false, "fichier disparu → refus") }
    // dossier d'origine disparu
    let from3 = root.appendingPathComponent("Disparu/z.pdf"), to3 = root.appendingPathComponent("B/z.pdf")
    write(to3, "z")
    let r3 = l.recordMove(from: from3, to: to3, origin: .analyse)
    if case .refused(let why) = l.undo(r3.id) { check(why.contains("dossier d'origine"), "message : \(why)") } else { check(false, "dossier d'origine absent → refus") }
    check(read(to3) == "z" && !fm.fileExists(atPath: from3.deletingLastPathComponent().path), "rien n'a été créé ni déplacé")
    // tout annuler : 3 refus, rien de touché ; puis un cas qui marche
    let from4 = root.appendingPathComponent("A/w.pdf"), to4 = root.appendingPathComponent("B/w.pdf")
    write(to4, "w"); l.recordMove(from: from4, to: to4, origin: .analyse)
    let results = l.undoAll()
    let ok = results.filter { if case .restored = $0.1 { return true }; return false }.count
    check(results.count == 4 && ok == 1, "tout annuler : 1 réussi sur 4 (\(ok))")
    check(read(from4) == "w", "le cas réussi est revenu")
    check(l.moves.count == 3, "les 3 refusés restent listés")
    l.forgetMove(l.moves[0].id)
    check(l.moves.count == 2, "« oublier » retire une ligne")
    // ordre : un fichier rangé deux fois revient en deux temps
    let p0 = root.appendingPathComponent("P/f.pdf"), p1 = root.appendingPathComponent("Q/f.pdf"), p2 = root.appendingPathComponent("R/f.pdf")
    write(p0, "f"); try! fm.createDirectory(at: p1.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! fm.createDirectory(at: p2.deletingLastPathComponent(), withIntermediateDirectories: true)
    let l2 = CourseLedger(directory: fresh())
    try! fm.moveItem(at: p0, to: p1); l2.recordMove(from: p0, to: p1, origin: .analyse)
    try! fm.moveItem(at: p1, to: p2); l2.recordMove(from: p1, to: p2, origin: .analyse)
    let res = l2.undoAll()
    check(res.allSatisfy { if case .restored = $0.1 { return true }; return false } && read(p0) == "f", "double rangement : tout annuler le ramène au départ")
}

// 4. cache de lecture
section("Cache de lecture (chemin + taille + date)")
do {
    let dir = fresh(), root = fresh()
    let f = root.appendingPathComponent("Maths/a.pdf")
    write(f, "version 1")
    let digest = CourseDigest(path: "Maths/a.pdf", isEvaluation: false, excerpt: "début", zones: 5, remaining: 3, isIncomplete: true)
    let l = CourseLedger(directory: dir)
    check(l.cachedDigest(for: f, relativePath: "Maths/a.pdf") == nil, "rien en cache au départ")
    l.replaceDigests([(f, digest)])
    check(l.cachedDigest(for: f, relativePath: "Maths/a.pdf") == digest, "relu tel quel")
    check(CourseLedger(directory: dir).cachedDigest(for: f, relativePath: "Maths/a.pdf") == digest, "relu après redémarrage")
    check(l.cachedDigest(for: f, relativePath: "Autre/a.pdf")?.path == "Autre/a.pdf", "le chemin affiché est celui du moment")
    let old = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
    // la date change, pas la taille
    try! fm.setAttributes([.modificationDate: old.addingTimeInterval(120)], ofItemAtPath: f.path)
    check(l.cachedDigest(for: f, relativePath: "Maths/a.pdf") == nil, "date modifiée → à relire")
    try! fm.setAttributes([.modificationDate: old], ofItemAtPath: f.path)
    check(l.cachedDigest(for: f, relativePath: "Maths/a.pdf") == digest, "date rétablie → de nouveau valide")
    // la taille change, pas la date
    write(f, "version 1, plus longue"); try! fm.setAttributes([.modificationDate: old], ofItemAtPath: f.path)
    check(l.cachedDigest(for: f, relativePath: "Maths/a.pdf") == nil, "taille modifiée → à relire")
    // fichier supprimé
    try! fm.removeItem(at: f)
    check(l.cachedDigest(for: f, relativePath: "Maths/a.pdf") == nil, "fichier supprimé → pas de cache")
    // replaceDigests retire ce qui a disparu
    let g = root.appendingPathComponent("g.pdf"); write(g, "g")
    l.replaceDigests([(g, digest)])
    check(l.digestCount == 1, "les fichiers disparus sortent du cache")
    // le cache suit un fichier déplacé (rangement) puis annulé
    let h = root.appendingPathComponent("Z/g.pdf")
    try! fm.createDirectory(at: h.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! fm.moveItem(at: g, to: h); l.recordMove(from: g, to: h, origin: .analyse)
    check(l.cachedDigest(for: h, relativePath: "Z/g.pdf") != nil, "un fichier rangé n'est pas relu")
    _ = l.undoAll()
    check(l.cachedDigest(for: g, relativePath: "g.pdf") != nil, "…ni après l'annulation")
    l.clearDigests()
    check(l.digestCount == 0 && l.cachedDigest(for: g, relativePath: "g.pdf") == nil, "« Tout relire » vide le cache")
}

// 5. cache des réponses de l'IA
section("Cache des réponses de l'IA")
do {
    let k1 = CourseLedger.fingerprint("sys", "extraits A\ndossiers X")
    let k2 = CourseLedger.fingerprint("sys", "extraits A\ndossiers Y")
    let k3 = CourseLedger.fingerprint("sys2", "extraits A\ndossiers X")
    check(k1.count == 64 && k1 != k2 && k1 != k3 && k1 == CourseLedger.fingerprint("sys", "extraits A\ndossiers X"), "empreinte stable, sensible aux dossiers et au prompt")
    check(CourseLedger.fingerprint("ab", "c") != CourseLedger.fingerprint("a", "bc"), "empreinte : pas de collage ambigu")
    let l = CourseLedger(directory: fresh())
    for i in 0..<(CourseLedger.maxAI + 10) { l.storeAI("k\(i)", json: "{\(i)}") }
    check(l.cachedAI("k0") == nil && l.cachedAI("k\(CourseLedger.maxAI + 9)") != nil, "le cache est borné, les plus anciens partent")
}

final class CountingGenerator: StructuredGenerator {
    var calls = 0
    var reply = "{\"propositions\":[{\"chemin\":\"Maths/a.pdf\",\"dossier\":\"Sciences\",\"nouveauNom\":\"\",\"raison\":\"test\"}]}"
    let displayName = "faux", supportsImages = false
    func generate(system: String, userText: String, images: [Data], schema: [String: Any]) async throws -> String { calls += 1; return reply }
}

// 6. CourseAnalysis.suggest avec le cache
section("Réponse de l'IA mise en cache")
do {
    let l = CourseLedger(directory: fresh())
    let digests = [CourseDigest(path: "Maths/a.pdf", isEvaluation: false, excerpt: "Les forces et le mouvement")]
    let folders = ["Maths", "Sciences"]
    let g = CountingGenerator()
    var out = try await CourseAnalysis.suggest(digests: digests, folders: folders, generator: g, ledger: l) { _ in }
    check(g.calls == 1 && out.count == 1 && out[0].folder == "Sciences", "première demande : appel à l'IA")
    out = try await CourseAnalysis.suggest(digests: digests, folders: folders, generator: g, ledger: l) { _ in }
    check(g.calls == 1 && out.count == 1, "même demande : aucun nouvel appel (\(g.calls))")
    out = try await CourseAnalysis.suggest(digests: digests, folders: ["Maths", "Sciences", "Histoire"], generator: g, ledger: l) { _ in }
    check(g.calls == 2, "dossiers différents : nouvel appel")
    var d2 = digests; d2[0].excerpt = "Autre texte"
    _ = try await CourseAnalysis.suggest(digests: d2, folders: folders, generator: g, ledger: l) { _ in }
    check(g.calls == 3, "extrait différent : nouvel appel")
    _ = try await CourseAnalysis.suggest(digests: digests, folders: folders, generator: g, ledger: l, useCache: false) { _ in }
    check(g.calls == 4, "« Tout relire » (useCache faux) : nouvel appel")
    let again = CourseLedger(directory: l.fileURL.deletingLastPathComponent())
    let g2 = CountingGenerator()
    _ = try await CourseAnalysis.suggest(digests: digests, folders: folders, generator: g2, ledger: again) { _ in }
    check(g2.calls == 0, "le cache de l'IA survit au redémarrage")
    g2.reply = "pas du json"
    let l3 = CourseLedger(directory: fresh())
    do { _ = try await CourseAnalysis.suggest(digests: digests, folders: folders, generator: g2, ledger: l3) { _ in }; check(false, "réponse illisible → erreur") }
    catch { check(l3.cachedAI(CourseLedger.fingerprint(CourseAnalysis.system, CourseAnalysis.userText(digests: digests, folders: folders))) == nil, "une réponse illisible n'est pas mise en cache") }
}

// 7. lecture réelle d'un PDF avec le cache
section("CourseAnalysis.digest avec le cache")
do {
    let root = fresh()
    let pdf = root.appendingPathComponent("Sciences/Cours/forces.pdf")
    try! fm.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ("La force est une action mécanique. Une force se mesure en \(String(repeating: ".", count: 40)) avec un dynamomètre." as NSString)
        .draw(at: NSPoint(x: 50, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState(); ctx.endPDFPage(); ctx.closePDF()
    let file = LibraryTree.makeFile(root: root, url: pdf)!
    let l = CourseLedger(directory: fresh())
    var t0 = Date()
    let first = CourseAnalysis.digest(file, ledger: l, force: false)
    let t1 = Date().timeIntervalSince(t0)
    check(!first.fromCache && first.digest.excerpt.contains("La force"), "première lecture : relue (extrait « \(first.digest.excerpt.prefix(30)) »)")
    l.replaceDigests([(pdf, first.digest)])
    t0 = Date()
    let second = CourseAnalysis.digest(file, ledger: l, force: false)
    let t2 = Date().timeIntervalSince(t0)
    check(second.fromCache && second.digest == first.digest, "deuxième lecture : tirée du cache, identique")
    check(t2 < 0.05, "lecture en cache quasi instantanée (\(Int(t2 * 1000)) ms contre \(Int(t1 * 1000)) ms)")
    check(!CourseAnalysis.digest(file, ledger: l, force: true).fromCache, "« Tout relire » : relue")
    // modification : le PDF change de taille → relu
    var data = try! Data(contentsOf: pdf); data.append(Data("\n%commentaire\n".utf8)); try! data.write(to: pdf)
    check(!CourseAnalysis.digest(file, ledger: l, force: false).fromCache, "PDF modifié : relu")
    check(CourseAnalysis.digest(file, ledger: nil).fromCache == false, "sans journal : toujours relu")
}

// 8. trois états : anciens journaux, nouveaux champs, original vide
section("États de complétion dans le journal")
do {
    let files = fresh(), dir = fresh()
    let f = files.appendingPathComponent("Maths/a.pdf"), g = files.appendingPathComponent("Maths/b.pdf")
    write(f, "pdf-a"); write(g, "pdf-b")
    func stamp(_ u: URL) -> (Int, Double) {
        let a = try! fm.attributesOfItem(atPath: u.path)
        return ((a[.size] as! NSNumber).intValue, (a[.modificationDate] as! Date).timeIntervalSince1970)
    }
    // un ancien journal : aucune des clés « state », « usedBlank », « blank »
    func oldEntry(_ u: URL, zones: Int, remaining: Int, inc: Bool) -> String {
        let (sz, mt) = stamp(u)
        return "\"\(u.standardizedFileURL.path)\":{\"size\":\(sz),\"mtime\":\(mt),\"version\":1,\"isEvaluation\":false,\"excerpt\":\"x\",\"zones\":\(zones),\"remaining\":\(remaining),\"isIncomplete\":\(inc)}"
    }
    write(dir.appendingPathComponent("journal.json"),
          "{\"version\":1,\"moves\":[],\"completions\":[],\"ai\":[],\"digests\":{\(oldEntry(f, zones: 12, remaining: 12, inc: true)),\(oldEntry(g, zones: 12, remaining: 5, inc: true))}}")
    let l = CourseLedger(directory: dir)
    check(!l.wasCorrupt && l.digestCount == 2, "ancien journal relu sans erreur")
    let a = l.cachedDigest(for: f, relativePath: "Maths/a.pdf"), b = l.cachedDigest(for: g, relativePath: "Maths/b.pdf")
    check(a?.state == .vide && b?.state == .partiel, "état déduit des anciens champs (12/12 → vide, 5/12 → partiel) : \(String(describing: a?.state)) \(String(describing: b?.state))")
    check(a?.usedBlank == false && a?.blankPath == nil, "ancien résumé : pas d'original vide")
    // réécriture : les nouveaux champs sont gardés et relus
    var d = CourseDigest(path: "Maths/a.pdf", isEvaluation: false, excerpt: "x", zones: 12, remaining: 3, isIncomplete: true, state: .partiel, usedBlank: false)
    l.replaceDigests([(f, d)])
    check(CourseLedger(directory: dir).cachedDigest(for: f, relativePath: "Maths/a.pdf")?.state == .partiel, "état relu après redémarrage")
    check(CourseLedger(directory: dir).cachedStates(for: [LibraryTree.makeFile(root: files, url: f)!])[f]?.remaining == 3, "cachedStates")
    // original vide : le résumé n'est valable qu'avec le même original, non modifié
    let blank = files.appendingPathComponent("_Originaux avant completion/Maths/a.pdf"); write(blank, "blank-v1")
    d.usedBlank = true; d.state = .complet; d.remaining = 0; d.isIncomplete = false; d.blankPath = blank.standardizedFileURL.path
    l.replaceDigests([(f, d)])
    check(l.cachedDigest(for: f, relativePath: "Maths/a.pdf", blank: blank)?.state == .complet, "même original vide : cache valable")
    check(l.cachedDigest(for: f, relativePath: "Maths/a.pdf") == nil, "original vide devenu inconnu : relu")
    check(l.cachedDigest(for: f, relativePath: "Maths/a.pdf", blank: files.appendingPathComponent("autre.pdf")) == nil, "autre original vide : relu")
    check(l.cachedState(for: f, relativePath: "Maths/a.pdf")?.usedBlank == true, "cachedState ignore l'original vide courant")
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -5000)], ofItemAtPath: blank.path)
    check(l.cachedDigest(for: f, relativePath: "Maths/a.pdf", blank: blank) == nil, "original vide modifié : relu")
    // état explicite : rien n'est « corrigé » par la dérivation
    check(CourseDigest(path: "p", isEvaluation: false, excerpt: "").state == .complet, "digest sans trou : complet")
    check(CourseDigest(path: "p", isEvaluation: false, excerpt: "", zones: 4, remaining: 4, isIncomplete: true).state == .vide, "4/4 restants : vide")
    check(CourseDigest(path: "p", isEvaluation: false, excerpt: "", zones: 4, remaining: 1, isIncomplete: false).state == .complet, "1 trou isolé non incomplet : complet")
}

print("\nRésultat : \(passed) réussis, \(failed) échec(s)")
exit(failed == 0 ? 0 : 1)
