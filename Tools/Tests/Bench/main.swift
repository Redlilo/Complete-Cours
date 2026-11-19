import Foundation
import PDFKit
import AppKit
import CoreText

// Tests de PageDiff (Sources/Core/PageDiff.swift) et de l'état à trois valeurs (CompletionStatus), sur des PDF fabriqués :
// vierge + complété par annotations, par texte dessiné (aplati), décalé de 2 px, avec de l'encre hors zone.

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("ÉCHEC (ligne \(line)) : \(what)") }
}

let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
func drawText(_ ctx: CGContext, _ s: String, at p: CGPoint) {
    ctx.textPosition = p
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font])), ctx)
}

/// Page de 5 phrases à trous. `offset` décale tout le contenu ; `answers` : texte dessiné au-dessus de chaque trou
/// (zones de la vierge) ; `extra` : encre ajoutée loin de tout trou ; `size` : format de la page.
func makePDF(at url: URL, blanks: Int = 5, offset: CGPoint = .zero, answers: [Zone] = [], answerCount: Int = 99,
             extra: Bool = false, size: CGSize = CGSize(width: 595, height: 842)) {
    var box = CGRect(origin: .zero, size: size)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    ctx.beginPDFPage(nil)
    for i in 0..<blanks {
        drawText(ctx, "Question \(i + 1) : l'atome est composé d'un noyau et d'électrons, donc ............................................." , at: CGPoint(x: 50 + offset.x, y: 760 - CGFloat(i) * 50 + offset.y))
    }
    for z in answers.prefix(answerCount) { drawText(ctx, "des protons", at: CGPoint(x: z.rect.minX + 6 + offset.x, y: z.rect.minY + 3 + offset.y)) }
    if extra { drawText(ctx, "Remarque ajoutée par l'élève dans la marge du bas, loin de tout trou.", at: CGPoint(x: 60, y: 300)) }
    ctx.endPDFPage(); ctx.closePDF()
}

func zones(_ url: URL) -> [Zone] {
    ((try? CoursPipeline.analyzeChecked(url: url, needText: false, progress: { _, _ in })) ?? []).flatMap { $0.zones }
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bench-tests-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

let blank = dir.appendingPathComponent("vierge.pdf")
makePDF(at: blank)
let z = zones(blank)
check(z.count == 5, "5 trous détectés dans la vierge (\(z.count))")
guard let blankDoc = PDFDocument(url: blank) else { print("vierge illisible"); exit(1) }

func diff(_ completed: URL, zones zs: [Zone] = z) -> PageDiffResult {
    guard let c = PDFDocument(url: completed) else { return PageDiffResult() }
    return PageDiff.compare(blank: blankDoc, completed: c, zones: zs)
}
func filledCount(_ r: PageDiffResult) -> Int { r.zones.values.filter { $0.filled }.count }

// 1. identique : rien d'ajouté, aucune encre hors zone
do {
    let r = diff(blank)
    check(r.pagesCompared == 1 && r.pagesSkipped.isEmpty, "page comparée")
    check(filledCount(r) == 0, "vierge contre elle-même : aucune zone remplie (\(filledCount(r)))")
    check(r.blobs.isEmpty && r.addedTotal == 0, "vierge contre elle-même : rien hors zone (\(r.blobs.count), \(r.addedTotal) px)")
}

// 2. réponses en annotations de texte (FreeText)
let withNotes = dir.appendingPathComponent("annotations.pdf")
if let doc = PDFDocument(url: blank), let page = doc.page(at: 0) {
    for a in z.prefix(3) {
        let note = PDFAnnotation(bounds: a.rect.insetBy(dx: 0, dy: -3), forType: .freeText, withProperties: nil)
        note.contents = "des protons"; note.font = NSFont.systemFont(ofSize: 10); note.fontColor = .black
        note.color = .clear
        page.addAnnotation(note)
    }
    doc.write(to: withNotes)
}
do {
    let r = diff(withNotes)
    check(filledCount(r) == 3, "annotations : 3 zones remplies (\(filledCount(r)))")
    check(z.prefix(3).allSatisfy { r.zones[$0.id]?.filled == true } && z.suffix(2).allSatisfy { r.zones[$0.id]?.filled == false }, "annotations : ce sont les 3 premières")
}

// 3. réponses dessinées puis aplaties dans la page
let flat = dir.appendingPathComponent("aplati.pdf")
makePDF(at: flat, answers: z)
do {
    let r = diff(flat)
    check(filledCount(r) == 5, "texte aplati : 5 zones remplies (\(filledCount(r)))")
    check(r.blobs.isEmpty, "texte aplati : pas d'encre hors zone (\(r.blobs.count))")
}
let flat2 = dir.appendingPathComponent("aplati-2.pdf")
makePDF(at: flat2, answers: z, answerCount: 2)
check(filledCount(diff(flat2)) == 2, "texte aplati sur 2 trous : 2 zones remplies (\(filledCount(diff(flat2))))")

// 4. décalage de 2 px (≈ 1 pt) de tout le contenu : pas de faux ajout, les réponses sont vues
let shiftedBlank = dir.appendingPathComponent("decale-vide.pdf")
makePDF(at: shiftedBlank, offset: CGPoint(x: 1, y: -1))
do {
    let r = diff(shiftedBlank)
    check(filledCount(r) == 0, "décalage seul : aucune zone remplie (\(filledCount(r)))")
    check(r.blobs.isEmpty, "décalage seul : pas d'encre hors zone (\(r.blobs.count))")
}
let shiftedFilled = dir.appendingPathComponent("decale-rempli.pdf")
makePDF(at: shiftedFilled, offset: CGPoint(x: 1, y: -1), answers: z)
check(filledCount(diff(shiftedFilled)) == 5, "décalage + réponses : 5 zones remplies (\(filledCount(diff(shiftedFilled))))")
// décalage plus fort (≈ 8 px) : compensé par l'estimation du décalage
let shifted8 = dir.appendingPathComponent("decale-8.pdf")
makePDF(at: shifted8, offset: CGPoint(x: 3.5, y: -3.5))
do {
    let r = diff(shifted8)
    check(filledCount(r) == 0 && r.blobs.isEmpty, "décalage de ≈ 8 px compensé (\(filledCount(r)) zones, \(r.blobs.count) amas)")
}

// 5. encre hors de toute zone
let extra = dir.appendingPathComponent("hors-zone.pdf")
makePDF(at: extra, answers: z, answerCount: 1, extra: true)
do {
    let r = diff(extra)
    check(filledCount(r) == 1, "hors zone : seule la zone répondue est remplie (\(filledCount(r)))")
    check(r.blobs.count == 1, "hors zone : un amas d'encre repéré (\(r.blobs.count))")
    if let b = r.blobs.first {
        check(b.page == 0 && b.rect.minY > 280 && b.rect.maxY < 330 && b.rect.minX > 50, "hors zone : position de l'amas \(b.rect.integral)")
    }
    check(PageDiff.unexpectedInk(blank: blankDoc, completed: PDFDocument(url: extra)!, zones: z).count == 1, "API unexpectedInk")
    check(PageDiff.answeredZones(blank: blankDoc, completed: PDFDocument(url: extra)!, zones: z).values.filter { $0.filled }.count == 1, "API answeredZones")
}

// 6. format de page différent : pas de conclusion
let other = dir.appendingPathComponent("autre-format.pdf")
makePDF(at: other, answers: z, size: CGSize(width: 842, height: 595))
do {
    let r = diff(other)
    check(r.pagesSkipped == [0] && filledCount(r) == 0 && r.zones.values.allSatisfy { !$0.comparable }, "format différent : page non comparable")
}

// 7. PDF complété plus court : page absente
do {
    let r = PageDiff.compare(blank: blankDoc, completed: PDFDocument(), zones: z)
    check(r.pagesSkipped == [0] && r.zones.count == 5, "complété sans page : zones non comparables")
}

// 8. état à trois valeurs, avec l'original vide
func state(_ completed: URL) -> CompletionReport? { CompletionStatus.report(url: completed, blankOriginal: blank) }
if let r = state(blank) { check(r.usedBlank && r.zones == 5 && r.answered == 0 && r.state == .vide, "vierge : vide (\(r.zones)/\(r.answered) \(r.state))") } else { check(false, "rapport vierge") }
if let r = state(flat2) { check(r.answered == 2 && r.state == .partiel, "2 sur 5 : partiel (\(r.answered) \(r.state))") } else { check(false, "rapport 2/5") }
if let r = state(flat) { check(r.answered == 5 && r.state == .complet && !r.isIncomplete, "5 sur 5 : complet (\(r.answered) \(r.state))") } else { check(false, "rapport 5/5") }
if let r = state(shiftedFilled) { check(r.state == .complet, "5 sur 5 décalé : complet (\(r.state))") } else { check(false, "rapport décalé") }
if let r = state(extra) { check(r.unexpectedInk == 1 && r.state == .partiel, "encre hors zone comptée (\(r.unexpectedInk)) ; 1 sur 5 : partiel (\(r.state))") } else { check(false, "rapport hors zone") }
if let r = CompletionStatus.report(url: withNotes, blankOriginal: blank) { check(r.answered == 3 && r.state == .partiel, "annotations 3/5 : partiel (\(r.answered) \(r.state))") } else { check(false, "rapport annotations") }
// original illisible : retombe sur l'estimation sans original
if let r = CompletionStatus.report(url: flat, blankOriginal: dir.appendingPathComponent("absent.pdf")) { check(!r.usedBlank, "original absent : estimation seule") } else { check(false, "rapport sans original") }
// sans original : l'API d'avant reste identique
if let r = CompletionStatus.report(url: blank) { check(!r.usedBlank && r.state == .vide && r.isIncomplete, "sans original : feuille vierge vide et incomplète (\(r.state))") } else { check(false, "rapport sans original (vierge)") }

// 9. règles de l'état, valeurs limites
func st(_ zones: Int, _ answered: Int, blank: Bool) -> CompletionState { CompletionReport(zones: zones, answered: answered, pages: 1, usedBlank: blank).state }
check(st(0, 0, blank: false) == .complet && st(0, 0, blank: true) == .complet, "aucune zone : complet")
check(st(10, 10, blank: true) == .complet && st(10, 9, blank: true) == .partiel, "avec original : complet seulement à 0 restant")
check(st(10, 9, blank: false) == .complet, "sans original : un trou isolé est toléré")
check(st(10, 1, blank: true) == .vide && st(10, 2, blank: true) == .partiel, "vide jusqu'à 10 % de zones remplies")
check(st(10, 0, blank: false) == .vide && st(1, 0, blank: true) == .vide, "rien de rempli : vide")
check(CompletionReport(zones: 5, answered: 0, pages: 1).isIncomplete, "isIncomplete conservé")

if failures == 0 { print("Bench : tout est bon.") } else { print("Bench : \(failures) échec(s)."); exit(1) }
