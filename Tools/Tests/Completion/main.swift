import Foundation
import PDFKit
import AppKit
import CoreText

// Tests de l'état de complétion (Sources/Core/CompletionStatus.swift).
//   build/tests/Completion-tests                       vérifications sur des PDF fabriqués
//   build/tests/Completion-tests scan <dossier>        tableau par PDF d'un vrai dossier de cours (évaluations ignorées)

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("ÉCHEC (ligne \(line)) : \(what)") }
}

/// PDF d'une page : quelques phrases avec des trous en pointillés (couche texte réelle).
func makePDF(at url: URL, blanks: Int) {
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    ctx.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    for i in 0..<blanks {
        let s = "Question \(i + 1) : l'atome est composé d'un noyau et d'électrons, donc ............................................."
        let attr = NSAttributedString(string: s, attributes: [.font: font])
        ctx.textPosition = CGPoint(x: 50, y: 760 - CGFloat(i) * 50)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
    }
    ctx.endPDFPage(); ctx.closePDF()
}

func analyses(_ url: URL) -> [PageAnalysis] {
    (try? CoursPipeline.analyzeChecked(url: url, needText: false, progress: { _, _ in })) ?? []
}

let args = CommandLine.arguments
if args.count >= 3, args[1] == "scan" {
    let root = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
    let files = LibraryTree.scan(root).filter { !$0.isEvaluation && $0.url.pathExtension.lowercased() == "pdf" }
        .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    for f in files {
        guard let r = CompletionStatus.report(url: f.url) else { print("illisible  \(f.relativePath)"); continue }
        let flag = r.isIncomplete ? "À COMPLÉTER" : "ok         "
        print(String(format: "%@  %3d zones, %3d répondues, %3d restantes   %@", flag, r.zones, r.answered, r.remaining, f.relativePath))
    }
    exit(0)
}


if args.count >= 3, args[1] == "debug" {
    let url = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
    guard let doc = PDFDocument(url: url) else { exit(1) }
    for a in analyses(url) where !a.zones.isEmpty {
        guard let page = doc.page(at: a.pageIndex) else { continue }
        let notes = CompletionStatus.textAnnotationRects(page)
        let ink = CompletionStatus.inkProbe(page)
        print("--- page \(a.pageIndex + 1) : crop \(page.bounds(for: .cropBox)) ; \(notes.count) annotation(s) texte")
        for n in notes { print("   note \(n.integral)") }
        for z in a.zones {
            let strip = z.lines.first.map { CGRect(x: $0.x0 + 2, y: $0.y + 2, width: max(4, $0.width - 4), height: max(5, 0.95 * max(z.textHeight, 9))) }
            let r = strip.flatMap { ink?.darkRatio(in: $0) } ?? -1
            print("   zone #\(z.number) \(z.source) rect \(z.rect.integral) h=\(Int(z.textHeight)) encre=\(String(format: "%.3f", r)) répondue=\(CompletionStatus.isAnswered(z, notes: notes, ink: ink))")
        }
    }
    exit(0)
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("completion-tests-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

// 1. feuille vierge : toutes les zones restent à remplir
let blank = dir.appendingPathComponent("vierge.pdf")
makePDF(at: blank, blanks: 5)
let blankReport = CompletionStatus.report(url: blank)
check(blankReport != nil, "le PDF fabriqué s'analyse")
if let r = blankReport {
    check(r.zones == 5, "5 trous détectés (\(r.zones))")
    check(r.answered == 0, "aucune réponse sur une feuille vierge (\(r.answered))")
    check(r.isIncomplete, "une feuille vierge est incomplète")
}

// 2. mêmes trous, réponses écrites en annotations de texte : plus rien à compléter
let filled = dir.appendingPathComponent("rempli.pdf")
if let doc = PDFDocument(url: blank), let page = doc.page(at: 0) {
    for a in analyses(blank).first?.zones ?? [] {
        let note = PDFAnnotation(bounds: a.rect, forType: .freeText, withProperties: nil)
        note.contents = "des protons"
        page.addAnnotation(note)
    }
    doc.write(to: filled)
}
if let r = CompletionStatus.report(url: filled) {
    check(r.zones == 5, "toujours 5 trous (\(r.zones))")
    check(r.answered == 5, "5 réponses reconnues (\(r.answered))")
    check(!r.isIncomplete, "un cours rempli n'est pas incomplet")
} else { check(false, "le PDF rempli s'analyse") }

// 3. à moitié rempli : 2 sur 5 → incomplet, 3 restantes
let half = dir.appendingPathComponent("moitie.pdf")
if let doc = PDFDocument(url: blank), let page = doc.page(at: 0) {
    for a in (analyses(blank).first?.zones ?? []).prefix(2) {
        let note = PDFAnnotation(bounds: a.rect, forType: .freeText, withProperties: nil)
        note.contents = "électrons"
        page.addAnnotation(note)
    }
    doc.write(to: half)
}
if let r = CompletionStatus.report(url: half) {
    check(r.remaining == 3, "3 trous restent (\(r.remaining))")
    check(r.isIncomplete, "à moitié rempli = incomplet")
} else { check(false, "le PDF à moitié rempli s'analyse") }

// 3b. un simple trait de pied de page n'est pas un trou
let footer = dir.appendingPathComponent("pied.pdf")
do {
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    if let ctx = CGContext(footer as CFURL, mediaBox: &box, nil) {
        ctx.beginPDFPage(nil)
        ctx.setLineWidth(1); ctx.move(to: CGPoint(x: 34, y: 63)); ctx.addLine(to: CGPoint(x: 561, y: 63)); ctx.strokePath()
        let attr = NSAttributedString(string: "1 | Page", attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 10, nil)])
        ctx.textPosition = CGPoint(x: 500, y: 45); CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        ctx.endPDFPage(); ctx.closePDF()
    }
}
if let r = CompletionStatus.report(url: footer) { check(r.zones == 0 && !r.isIncomplete, "le trait de pied de page est ignoré (\(r.zones) zone(s))") }

// 4. une annotation vide (pas de texte) ne compte pas comme une réponse
let empty = dir.appendingPathComponent("annotation-vide.pdf")
if let doc = PDFDocument(url: blank), let page = doc.page(at: 0) {
    for a in analyses(blank).first?.zones ?? [] {
        let note = PDFAnnotation(bounds: a.rect, forType: .freeText, withProperties: nil)
        note.contents = "  "
        page.addAnnotation(note)
    }
    doc.write(to: empty)
}
if let r = CompletionStatus.report(url: empty) { check(r.answered == 0, "annotation vide ignorée (\(r.answered))") }

if failures == 0 { print("Completion : tout est bon.") } else { print("Completion : \(failures) échec(s)."); exit(1) }
