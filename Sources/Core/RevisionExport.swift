import Foundation
import AppKit
import CoreText
import CoreGraphics

// Export du mode « Révision » vers de NOUVEAUX PDF A4 (CoreText + CoreGraphics, texte sélectionnable).

enum RevisionExport {

    static func summaryPDF(_ summary: RevisionSummary, documentName: String) throws -> Data {
        try twoPass(title: summary.title.isEmpty ? documentName : summary.title, footer: "\(documentName) — fiche de révision") { c in
            c.title(summary.title.isEmpty ? documentName : summary.title,
                    subtitle: summary.title == documentName ? "Fiche de révision" : "Fiche de révision · \(documentName)")
            if !summary.keyPoints.isEmpty {
                c.heading("L'essentiel à retenir")
                for p in summary.keyPoints { c.bullet(p) }
            }
            if !summary.vocabulary.isEmpty {
                c.heading("Vocabulaire")
                c.table(header: ("Mot", "Définition"), rows: summary.vocabulary.map { ($0.term, $0.definition) })
            }
            if !summary.formulas.isEmpty {
                c.heading("Formules à connaître")
                for f in summary.formulas { c.formula(f) }
            }
            if !summary.tips.isEmpty {
                c.heading("Pièges et conseils")
                for t in summary.tips { c.bullet(t) }
            }
        }
    }

    static func quizPDF(_ questions: [RevisionQuestion], documentName: String, withAnswers: Bool) throws -> Data {
        guard !questions.isEmpty else { throw CoursError.message("Il n'y a aucune question à exporter.") }
        let kind = withAnswers ? "questions d'entraînement et réponses" : "questions d'entraînement"
        return try twoPass(title: "Questions d'entraînement — \(documentName)", footer: "\(documentName) — \(kind)") { c in
            c.title("Questions d'entraînement", subtitle: documentName)
            for (i, q) in questions.enumerated() { c.question(q, number: i + 1) }
            if withAnswers {
                c.newPage()
                c.title("Réponses", subtitle: "Compare avec tes réponses, puis relis l'explication quand tu t'es trompé.")
                for (i, q) in questions.enumerated() { c.answerLine(q, number: i + 1) }
            }
        }
    }

    static func corrigePDF(_ items: [CorrigeItem], documentName: String) throws -> Data {
        guard !items.isEmpty else { throw CoursError.message("Il n'y a aucune question à exporter.") }
        return try twoPass(title: "Corrigé — \(documentName)", footer: "\(documentName) — corrigé de l'évaluation") { c in
            c.title("Corrigé de l'évaluation", subtitle: documentName)
            let ok = items.filter { $0.status == .juste }.count
            let redo = items.filter { $0.status == .faux || $0.status == .partiel }.count
            let other = items.count - ok - redo
            var bilan = "\(items.count) question\(items.count > 1 ? "s" : "") : \(ok) juste\(ok > 1 ? "s" : ""), \(redo) à revoir"
            if other > 0 { bilan += ", \(other) sans marque du professeur" }
            c.note(bilan)
            for (i, it) in items.enumerated() { c.corrige(it, fallbackNumber: i + 1) }
        }
    }

    /// Première passe : compte les pages ; seconde passe : écrit « Page i / N » dans le pied de page.
    private static func twoPass(title: String, footer: String, _ build: (PDFComposer) -> Void) throws -> Data {
        let first = try PDFComposer(title: title, footer: footer, totalPages: nil)
        build(first)
        let n = first.finish().pages
        let second = try PDFComposer(title: title, footer: footer, totalPages: n)
        build(second)
        return second.finish().data
    }
}

// MARK: - Mise en page

private enum Look {
    static let accent = NSColor(srgbRed: 0.10, green: 0.31, blue: 0.62, alpha: 1)
    static let ink = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1)
    static let gray = NSColor(srgbRed: 0.38, green: 0.40, blue: 0.44, alpha: 1)
    static let green = NSColor(srgbRed: 0.09, green: 0.46, blue: 0.22, alpha: 1)
    static let orange = NSColor(srgbRed: 0.72, green: 0.40, blue: 0.00, alpha: 1)
    static let red = NSColor(srgbRed: 0.74, green: 0.14, blue: 0.12, alpha: 1)
    static let tint = NSColor(srgbRed: 0.92, green: 0.95, blue: 0.99, alpha: 1)
    static let zebra = NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1)
    static let rule = NSColor(srgbRed: 0.80, green: 0.82, blue: 0.85, alpha: 1)

    static func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        var f = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        if italic, let d = Optional(f.fontDescriptor.withSymbolicTraits(.italic)), let g = NSFont(descriptor: d, size: size) { f = g }
        return f
    }

    static func para(spacing: CGFloat = 2, head: CGFloat = 0, first: CGFloat = 0, tab: CGFloat? = nil) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = spacing
        p.headIndent = head
        p.firstLineHeadIndent = first
        p.lineBreakMode = .byWordWrapping
        if let tab { p.tabStops = [NSTextTab(textAlignment: .left, location: tab)] }
        return p
    }

    static func attr(_ s: String, size: CGFloat = 11, bold: Bool = false, italic: Bool = false,
                     color: NSColor = ink, style: NSParagraphStyle? = nil) -> NSMutableAttributedString {
        NSMutableAttributedString(string: s, attributes: [
            .font: font(size, bold: bold, italic: italic), .foregroundColor: color, .paragraphStyle: style ?? para(),
        ])
    }

    static func statusColor(_ v: Verdict?) -> NSColor {
        switch v { case .juste?: return green; case .partiel?: return orange; case .faux?: return red; case nil: return gray }
    }
    static func statusWord(_ v: Verdict?) -> String {
        switch v { case .juste?: return "Juste"; case .partiel?: return "En partie juste, à revoir"; case .faux?: return "À revoir"; case nil: return "À vérifier" }
    }
}

private final class PDFComposer {
    static let pageW: CGFloat = 595.28, pageH: CGFloat = 841.89
    let margin: CGFloat = 54
    private let footerText: String
    private let totalPages: Int?
    private let data = NSMutableData()
    private var ctx: CGContext
    private(set) var pageNumber = 0
    private(set) var y: CGFloat = 0           // distance depuis le haut de la page
    private var closed = false

    var contentWidth: CGFloat { Self.pageW - 2 * margin }
    var bottom: CGFloat { Self.pageH - margin - 8 }
    var pageHeight: CGFloat { bottom - margin }

    init(title: String, footer: String, totalPages: Int?) throws {
        footerText = footer
        self.totalPages = totalPages
        var box = CGRect(x: 0, y: 0, width: Self.pageW, height: Self.pageH)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Complète-Cours"]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let c = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary)
        else { throw CoursError.message("Impossible de créer le PDF. Réessaie, ou choisis un autre dossier d'export.") }
        ctx = c
        newPage()
    }

    // MARK: Pages

    func newPage() {
        if pageNumber > 0 { drawFooter(); ctx.endPDFPage() }
        ctx.beginPDFPage(nil)
        pageNumber += 1
        y = margin
    }

    func finish() -> (data: Data, pages: Int) {
        if !closed {
            drawFooter()
            ctx.endPDFPage()
            ctx.closePDF()
            closed = true
        }
        return (data as Data, pageNumber)
    }

    private func drawFooter() {
        var name = footerText
        if name.count > 78 { name = String(name.prefix(76)) + "…" }
        ctx.setStrokeColor(Look.rule.cgColor)
        ctx.setLineWidth(0.5)
        let ly = margin - 10
        ctx.move(to: CGPoint(x: margin, y: ly)); ctx.addLine(to: CGPoint(x: Self.pageW - margin, y: ly)); ctx.strokePath()
        drawLine(Look.attr(name, size: 8.5, color: Look.gray), x: margin, baseline: ly - 13)
        let right = Look.attr(totalPages.map { "Page \(pageNumber) / \($0)" } ?? "Page \(pageNumber)", size: 8.5, color: Look.gray)
        let w = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(right), nil, nil, nil)
        drawLine(right, x: Self.pageW - margin - CGFloat(w), baseline: ly - 13)
    }

    private func drawLine(_ s: NSAttributedString, x: CGFloat, baseline: CGFloat) {
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
    }

    // MARK: Primitives

    func measure(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
        let fs = CTFramesetterCreateWithAttributedString(s)
        let r = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                             CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return ceil(r.height)
    }

    /// Saute à la page suivante si `h` ne tient pas dans la place restante (et si la page n'est pas déjà vide).
    func ensure(_ h: CGFloat) {
        if y + h > bottom && y > margin + 1 { newPage() }
    }

    func fill(x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat, color: NSColor, radius: CGFloat = 0) {
        let r = CGRect(x: x, y: Self.pageH - top - h, width: w, height: h)
        ctx.setFillColor(color.cgColor)
        if radius > 0 { ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.fillPath() }
        else { ctx.fill(r) }
    }

    func hline(top: CGFloat, x0: CGFloat, x1: CGFloat, color: NSColor, width: CGFloat = 0.5) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.move(to: CGPoint(x: x0, y: Self.pageH - top)); ctx.addLine(to: CGPoint(x: x1, y: Self.pageH - top)); ctx.strokePath()
    }

    func square(x: CGFloat, top: CGFloat, size: CGFloat) {
        ctx.setStrokeColor(Look.gray.cgColor)
        ctx.setLineWidth(0.9)
        ctx.stroke(CGRect(x: x, y: Self.pageH - top - size, width: size, height: size))
    }

    /// Dessine un texte dans un rectangle fixe (cellule).
    func drawBox(_ s: NSAttributedString, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) {
        let fs = CTFramesetterCreateWithAttributedString(s)
        let path = CGPath(rect: CGRect(x: x, y: Self.pageH - top - height - 2, width: width, height: height + 2), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil), ctx)
    }

    /// Écrit un texte à la suite, en changeant de page si besoin. Renvoie la position (y) de sa première ligne.
    @discardableResult
    func text(_ s: NSAttributedString, indent: CGFloat = 0, rightInset: CGFloat = 0, bar: NSColor? = nil, after: CGFloat = 0) -> CGFloat {
        let fs = CTFramesetterCreateWithAttributedString(s)
        let width = contentWidth - indent - rightInset
        var loc = 0
        var firstY: CGFloat?
        while loc < s.length {
            if bottom - y < 16 && y > margin + 1 { newPage() }
            let avail = bottom - y
            var fit = CFRange()
            let size = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: loc, length: 0), nil,
                                                                    CGSize(width: width, height: avail), &fit)
            if fit.length == 0 {
                if y > margin + 1 { newPage(); continue }
                fit.length = s.length - loc   // ligne plus haute que la page : on l'écrit quand même
            }
            let h = ceil(size.height)
            if firstY == nil { firstY = y }
            let path = CGPath(rect: CGRect(x: margin + indent, y: Self.pageH - y - h - 2, width: width, height: h + 2), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: loc, length: fit.length), path, nil), ctx)
            if let bar { fill(x: margin + indent - 9, top: y, w: 3, h: h + after, color: bar) }
            y += h
            loc += fit.length
            if loc < s.length { newPage() }
        }
        y += after
        return firstY ?? y
    }

    // MARK: Éléments communs

    func title(_ t: String, subtitle: String) {
        text(Look.attr(t, size: 22, bold: true, color: Look.accent, style: Look.para(spacing: 2)), after: 4)
        text(Look.attr(subtitle, size: 10.5, color: Look.gray), after: 8)
        hline(top: y, x0: margin, x1: Self.pageW - margin, color: Look.accent, width: 1.5)
        y += 14
    }

    func note(_ t: String) { text(Look.attr(t, size: 11, color: Look.gray), after: 14) }

    func heading(_ t: String) {
        let a = Look.attr(t, size: 14, bold: true, color: Look.accent)
        ensure(measure(a, width: contentWidth) + 50)
        y += 6
        text(a, after: 6)
    }

    func bullet(_ t: String) {
        let a = Look.attr("•\t" + t, size: 11.5, style: Look.para(spacing: 2, head: 16, first: 0, tab: 16))
        ensure(min(measure(a, width: contentWidth), 60))
        text(a, after: 5)
    }

    func formula(_ t: String) {
        let a = Look.attr(t, size: 12, bold: true, color: Look.ink, style: Look.para(spacing: 3))
        let w = contentWidth - 24
        let h = measure(a, width: w)
        ensure(h + 20)
        if h + 20 <= pageHeight {
            fill(x: margin, top: y, w: contentWidth, h: h + 16, color: Look.tint, radius: 4)
            fill(x: margin, top: y, w: 3, h: h + 16, color: Look.accent)
            y += 8
            text(a, indent: 14, rightInset: 10, after: 14)
        } else {
            text(a, after: 10)
        }
    }

    func table(header: (String, String), rows: [(String, String)]) {
        let w1: CGFloat = 150, pad: CGFloat = 6
        let w2 = contentWidth - w1
        func row(_ l: String, _ r: String, head: Bool, shade: Bool) {
            let a = Look.attr(l, size: 11, bold: true, color: head ? .white : Look.ink)
            let b = Look.attr(r, size: 11, bold: head, color: head ? .white : Look.ink)
            let h = max(measure(a, width: w1 - 2 * pad), measure(b, width: w2 - 2 * pad)) + 2 * pad
            ensure(h)
            if head { fill(x: margin, top: y, w: contentWidth, h: h, color: Look.accent) }
            else if shade { fill(x: margin, top: y, w: contentWidth, h: h, color: Look.zebra) }
            drawBox(a, x: margin + pad, top: y + pad, width: w1 - 2 * pad, height: h - 2 * pad)
            drawBox(b, x: margin + w1 + pad, top: y + pad, width: w2 - 2 * pad, height: h - 2 * pad)
            y += h
            if !head { hline(top: y, x0: margin, x1: Self.pageW - margin, color: Look.rule) }
        }
        row(header.0, header.1, head: true, shade: false)
        for (i, r) in rows.enumerated() { row(r.0, r.1, head: false, shade: i % 2 == 1) }
        y += 10
    }

    // MARK: Questions

    private func letter(_ i: Int) -> String { String(UnicodeScalar(UInt8(65 + min(i, 25)))) }

    func question(_ q: RevisionQuestion, number: Int) {
        var head = "Question \(number) · \(q.style.label)"
        if let p = q.page { head += " · page \(p) du cours" }
        let h = Look.attr(head, size: 10.5, bold: true, color: Look.accent)
        let body = Look.attr(q.question, size: 12, style: Look.para(spacing: 3))
        let choiceStyle = Look.para(spacing: 2, head: 0)
        let choiceAttrs: [NSAttributedString] = q.choices.enumerated().map { i, c in
            Look.attr(q.style == .qcm ? "\(letter(i)). \(c)" : c, size: 11.5, style: choiceStyle)
        }
        let lines = (q.choices.isEmpty ? (q.style == .calcul ? 3 : 2) : 0)
        var total = measure(h, width: contentWidth) + 3 + measure(body, width: contentWidth) + 8
        for c in choiceAttrs { total += measure(c, width: contentWidth - 22) + 5 }
        total += CGFloat(lines) * 24 + 16
        ensure(min(total, pageHeight))

        text(h, after: 3)
        text(body, after: 8)
        for c in choiceAttrs {
            let top = text(c, indent: 22, after: 5)
            square(x: margin + 4, top: top + 2.5, size: 10)
        }
        for _ in 0..<lines {
            y += 24
            ensure(2)
            hline(top: y, x0: margin, x1: Self.pageW - margin, color: Look.rule)
        }
        y += 16
    }

    func answerLine(_ q: RevisionQuestion, number: Int) {
        var expected = q.expected
        if q.style == .qcm, let i = q.choices.firstIndex(of: q.expected) { expected = "\(letter(i)). \(q.expected)" }
        let a = NSMutableAttributedString()
        a.append(Look.attr("\(number). ", size: 11.5, bold: true, color: Look.accent))
        a.append(Look.attr(expected, size: 11.5, bold: true, color: Look.green))
        if !q.explanation.isEmpty { a.append(Look.attr("\n" + q.explanation, size: 10.5, color: Look.gray)) }
        let para = Look.para(spacing: 2)
        a.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: a.length))
        ensure(min(measure(a, width: contentWidth), 80))
        text(a, after: 9)
    }

    // MARK: Corrigé

    func corrige(_ it: CorrigeItem, fallbackNumber: Int) {
        let color = Look.statusColor(it.status)
        var head = "Question \(it.number.isEmpty ? String(fallbackNumber) : it.number)"
        head += " · page \(it.page)"
        let headA = Look.attr(head, size: 12, bold: true, color: Look.ink)
        let pill = Look.attr(Look.statusWord(it.status), size: 10, bold: true, color: color)
        let pillW = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(pill), nil, nil, nil)) + 20

        func field(_ label: String, _ value: String, color: NSColor = Look.ink, bold: Bool = false, italic: Bool = false) -> NSAttributedString {
            let a = Look.attr(label.uppercased() + "\n", size: 8.5, bold: true, color: Look.gray, style: Look.para(spacing: 1))
            a.append(Look.attr(value, size: 11, bold: bold, italic: italic, color: color, style: Look.para(spacing: 2.5)))
            return a
        }
        var fields: [NSAttributedString] = []
        if !it.instruction.isEmpty { fields.append(field("Consigne", it.instruction)) }
        fields.append(it.studentAnswer.isEmpty ? field("Ta réponse", "(rien d'écrit, ou illisible)", color: Look.gray, italic: true)
                                               : field("Ta réponse", it.studentAnswer))
        if !it.teacherRemark.isEmpty { fields.append(field("Remarque du professeur", it.teacherRemark, color: Look.orange)) }
        if !it.correctAnswer.isEmpty { fields.append(field("Bonne réponse", it.correctAnswer, color: Look.green, bold: true)) }
        if !it.explanation.isEmpty { fields.append(field("Explication", it.explanation)) }
        if !it.toRemember.isEmpty { fields.append(field("À retenir", it.toRemember, color: Look.accent, bold: true)) }

        let inner: CGFloat = 12
        let w = contentWidth - inner
        var total: CGFloat = 26
        for f in fields { total += measure(f, width: w) + 8 }
        ensure(total <= pageHeight ? total : 26 + (fields.first.map { measure($0, width: w) } ?? 0))

        // en-tête : mot de statut dans une pastille teintée
        let top = y
        fill(x: Self.pageW - margin - pillW, top: top, w: pillW, h: 20, color: color.withAlphaComponent(0.12), radius: 10)
        drawBox(pill, x: Self.pageW - margin - pillW + 10, top: top + 4, width: pillW - 10, height: 14)
        text(headA, indent: inner, rightInset: pillW + 8, bar: color, after: 8)
        for (i, f) in fields.enumerated() {
            text(f, indent: inner, bar: color, after: i == fields.count - 1 ? 0 : 8)
        }
        y += 6
        hline(top: y, x0: margin, x1: Self.pageW - margin, color: Look.rule)
        y += 14
    }
}
