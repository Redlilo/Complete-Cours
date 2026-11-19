import Foundation
import AppKit
import CoreText
import CoreGraphics

// Export du mode « Révision » vers de NOUVEAUX PDF A4 (CoreText + CoreGraphics, texte sélectionnable).

enum RevisionExport {

    static func summaryPDF(_ summary: RevisionSummary, documentName: String) throws -> Data {
        let title = summary.title.isEmpty ? documentName : summary.title
        let accent = Look.courseColor(documentName)
        return try twoPass(title: title, footer: "\(documentName) — fiche de révision", accent: accent) { c in
            c.banner(kicker: "FICHE DE RÉVISION", title: title, subtitle: "Cours : \(documentName)")
            if !summary.keyPoints.isEmpty {
                let rows = summary.keyPoints.enumerated().map { i, p in Look.numbered(i + 1, p, color: accent) }
                c.boxed(title: "L'essentiel à retenir", color: accent, tint: Look.softTint(accent), rows: rows)
            }
            if !summary.vocabulary.isEmpty {
                c.heading("Vocabulaire")
                c.termGrid(summary.vocabulary.map { ($0.term, $0.definition) })
            }
            if !summary.formulas.isEmpty {
                c.heading("Formules à connaître")
                for f in summary.formulas { c.formula(f) }
            }
            if !summary.tips.isEmpty {
                let rows = summary.tips.map { Look.attr("›\t" + $0, size: 11.5, style: Look.para(spacing: 2, head: 16, first: 0, tab: 16)) }
                c.boxed(title: "Pièges et conseils", color: Look.green, tint: Look.greenTint, rows: rows)
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

    /// Cartes mémoire à imprimer et découper : par feuille, une page de rectos (2 × 4 cartes) puis une page de versos
    /// (colonnes inversées, pour une impression recto verso qui retourne la feuille sur le bord long).
    static func cardsPDF(_ cards: [RevisionCard], documentName: String) throws -> Data {
        guard !cards.isEmpty else { throw CoursError.message("Il n'y a aucune carte à exporter.") }
        let accent = Look.courseColor(documentName)
        return try twoPass(title: "Cartes mémoire — \(documentName)", footer: "\(documentName) — cartes mémoire", accent: accent, strip: false) { c in
            c.cardSheets(cards)
        }
    }

    /// Première passe : compte les pages ; seconde passe : écrit « Page i / N » dans le pied de page.
    private static func twoPass(title: String, footer: String, accent: NSColor = Look.accent, strip: Bool = true,
                                _ build: (PDFComposer) -> Void) throws -> Data {
        let first = try PDFComposer(title: title, footer: footer, totalPages: nil, accent: accent, strip: strip)
        build(first)
        let n = first.finish().pages
        let second = try PDFComposer(title: title, footer: footer, totalPages: n, accent: accent, strip: strip)
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

    static let greenTint = NSColor(srgbRed: 0.92, green: 0.97, blue: 0.93, alpha: 1)
    static let amber = NSColor(srgbRed: 0.80, green: 0.50, blue: 0.00, alpha: 1)
    static let amberTint = NSColor(srgbRed: 1.00, green: 0.96, blue: 0.84, alpha: 1)

    /// Couleur d'en-tête d'une fiche, choisie d'après le nom du cours (assez foncée pour du texte blanc).
    static func courseColor(_ name: String) -> NSColor {
        let palette: [NSColor] = [
            NSColor(srgbRed: 0.10, green: 0.31, blue: 0.62, alpha: 1), NSColor(srgbRed: 0.69, green: 0.33, blue: 0.05, alpha: 1),
            NSColor(srgbRed: 0.10, green: 0.45, blue: 0.27, alpha: 1), NSColor(srgbRed: 0.44, green: 0.25, blue: 0.66, alpha: 1),
            NSColor(srgbRed: 0.05, green: 0.46, blue: 0.50, alpha: 1), NSColor(srgbRed: 0.28, green: 0.30, blue: 0.68, alpha: 1),
        ]
        let h = name.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return palette[abs(h) % palette.count]
    }

    /// Fond très clair de la couleur donnée.
    static func softTint(_ c: NSColor) -> NSColor { c.blended(withFraction: 0.92, of: .white) ?? tint }

    static func rounded(_ size: CGFloat, bold: Bool = true) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .semibold)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    /// « 3   Texte » : numéro en couleur, puis le texte avec retrait.
    static func numbered(_ n: Int, _ text: String, color: NSColor) -> NSAttributedString {
        let st = para(spacing: 2, head: 22, first: 0, tab: 22)
        let a = attr("\(n)", size: 11.5, bold: true, color: color, style: st)
        a.append(attr("\t" + text, size: 11.5, style: st))
        return a
    }

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
    let accent: NSColor
    private let strip: Bool
    private let data = NSMutableData()
    private var ctx: CGContext
    private(set) var pageNumber = 0
    private(set) var y: CGFloat = 0           // distance depuis le haut de la page
    private var closed = false

    var contentWidth: CGFloat { Self.pageW - 2 * margin }
    var bottom: CGFloat { Self.pageH - margin - 8 }
    var pageHeight: CGFloat { bottom - margin }

    init(title: String, footer: String, totalPages: Int?, accent: NSColor = Look.accent, strip: Bool = true) throws {
        footerText = footer
        self.totalPages = totalPages
        self.accent = accent
        self.strip = strip
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
        if strip { fill(x: 0, top: 0, w: Self.pageW, h: 6, color: accent) }
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
        text(NSAttributedString(string: t, attributes: [.font: Look.rounded(22), .foregroundColor: accent, .paragraphStyle: Look.para(spacing: 2)]), after: 4)
        text(Look.attr(subtitle, size: 10.5, color: Look.gray), after: 8)
        hline(top: y, x0: margin, x1: Self.pageW - margin, color: accent, width: 1.5)
        y += 14
    }

    func note(_ t: String) { text(Look.attr(t, size: 11, color: Look.gray), after: 14) }

    func heading(_ t: String) {
        let a = NSMutableAttributedString(string: t, attributes: [.font: Look.rounded(14), .foregroundColor: accent, .paragraphStyle: Look.para()])
        ensure(measure(a, width: contentWidth) + 70)
        y += 8
        fill(x: margin, top: y + 1, w: 4, h: 15, color: accent, radius: 2)
        text(a, indent: 12, after: 8)
    }

    func bullet(_ t: String) {
        let a = Look.attr("•\t" + t, size: 11.5, style: Look.para(spacing: 2, head: 16, first: 0, tab: 16))
        ensure(min(measure(a, width: contentWidth), 60))
        text(a, after: 5)
    }

    /// Formule mise en évidence : l'équation en grand, le sens des lettres en dessous.
    func formula(_ t: String) {
        var main = t, legend = ""
        if let r = t.range(of: " ("), t.hasSuffix(")") {
            main = String(t[..<r.lowerBound])
            legend = String(t[r.upperBound...].dropLast())
        }
        let inner: CGFloat = 16
        let w = contentWidth - 2 * inner
        let big = Look.attr(main, size: 15, bold: true, style: Look.para(spacing: 3))
        let small = legend.isEmpty ? nil : Look.attr(legend, size: 10.5, color: Look.gray, style: Look.para(spacing: 2))
        let hBig = measure(big, width: w), hSmall = small.map { measure($0, width: w) + 4 } ?? 0
        let h = hBig + hSmall + 20
        ensure(min(h, pageHeight))
        fill(x: margin, top: y, w: contentWidth, h: h, color: Look.amberTint, radius: 6)
        fill(x: margin, top: y + 5, w: 4, h: h - 10, color: Look.amber, radius: 2)
        drawBox(big, x: margin + inner, top: y + 10, width: w, height: hBig)
        if let small { drawBox(small, x: margin + inner, top: y + 10 + hBig + 4, width: w, height: hSmall) }
        y += h + 9
    }

    /// Bandeau d'en-tête coloré de la première page.
    func banner(kicker: String, title: String, subtitle: String) {
        let k = NSMutableAttributedString(string: kicker, attributes: [
            .font: Look.font(9, bold: true), .foregroundColor: NSColor.white.withAlphaComponent(0.8), .paragraphStyle: Look.para()])
        let t = NSMutableAttributedString(string: title, attributes: [
            .font: Look.rounded(25), .foregroundColor: NSColor.white, .paragraphStyle: Look.para(spacing: 2)])
        let sub = Look.attr(subtitle, size: 11.5, color: NSColor.white.withAlphaComponent(0.88))
        let hK = measure(k, width: contentWidth), hT = measure(t, width: contentWidth), hS = measure(sub, width: contentWidth)
        let h = 26 + hK + 6 + hT + 6 + hS + 24
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: Self.pageH - h, width: Self.pageW, height: h))
        fill(x: 0, top: 0, w: Self.pageW, h: h, color: accent)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.fillEllipse(in: CGRect(x: Self.pageW - 190, y: Self.pageH - h - 40, width: 260, height: 260))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.07).cgColor)
        ctx.fillEllipse(in: CGRect(x: Self.pageW - 330, y: Self.pageH - h - 90, width: 200, height: 200))
        ctx.restoreGState()
        y = 26
        text(k, after: 6)
        text(t, after: 6)
        text(sub)
        y = h + 22
    }

    /// Cadre coloré avec titre et lignes ; si les lignes ne tiennent pas sur la page, le cadre continue sur la suivante
    /// (« suite ») sans jamais couper une ligne en deux.
    func boxed(title: String, color: NSColor, tint: NSColor, rows: [NSAttributedString]) {
        let pad: CGFloat = 13, headH: CGFloat = 30, gap: CGFloat = 7, bottomPad: CGFloat = 12
        let w = contentWidth - 2 * pad
        let heights = rows.map { min(measure($0, width: w), pageHeight - headH - 40) }
        var i = 0, chunk = 0
        while i < rows.count {
            let avail = bottom - y - headH - 8 - bottomPad
            if avail < heights[i] && y > margin + 1 { newPage(); continue }
            var j = i, used: CGFloat = 0
            while j < rows.count {
                let add = heights[j] + (j > i ? gap : 0)
                if used + add > avail { break }
                used += add; j += 1
            }
            if j == i { used = heights[i]; j = i + 1 }
            let boxH = headH + 8 + used + bottomPad
            let rect = CGRect(x: margin, y: Self.pageH - y - boxH, width: contentWidth, height: boxH)
            let path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            ctx.setFillColor(tint.cgColor); ctx.fill(rect)
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: margin, y: Self.pageH - y - headH, width: contentWidth, height: headH))
            ctx.restoreGState()
            ctx.setStrokeColor(color.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(0.8)
            ctx.addPath(path); ctx.strokePath()
            let head = NSMutableAttributedString(string: chunk == 0 ? title : title + " (suite)", attributes: [
                .font: Look.rounded(12.5), .foregroundColor: NSColor.white, .paragraphStyle: Look.para()])
            drawBox(head, x: margin + pad, top: y + 8, width: w, height: 16)
            var yy = y + headH + 8
            for k in i..<j {
                drawBox(rows[k], x: margin + pad, top: yy, width: w, height: heights[k])
                yy += heights[k] + gap
            }
            y += boxH + 14
            i = j; chunk += 1
        }
    }

    /// Vocabulaire en deux colonnes de petites cartes ; une rangée n'est jamais coupée entre deux pages.
    func termGrid(_ items: [(String, String)]) {
        let gapX: CGFloat = 10, pad: CGFloat = 10
        let cw = (contentWidth - gapX) / 2
        func cell(_ t: String, _ d: String) -> NSAttributedString {
            let a = Look.attr(t, size: 11.5, bold: true, color: accent, style: Look.para(spacing: 1))
            a.append(Look.attr("\n" + d, size: 10.5, style: Look.para(spacing: 2)))
            return a
        }
        var i = 0
        while i < items.count {
            let left = cell(items[i].0, items[i].1)
            let right = i + 1 < items.count ? cell(items[i + 1].0, items[i + 1].1) : nil
            let inner = cw - 2 * pad - 4
            let h = max(measure(left, width: inner), right.map { measure($0, width: inner) } ?? 0) + 2 * pad
            ensure(min(h, pageHeight))
            for (k, a) in ([left, right] as [NSAttributedString?]).enumerated() {
                guard let a else { continue }
                let x = margin + CGFloat(k) * (cw + gapX)
                fill(x: x, top: y, w: cw, h: h, color: Look.softTint(accent), radius: 6)
                fill(x: x, top: y + 5, w: 3, h: h - 10, color: accent, radius: 1.5)
                drawBox(a, x: x + pad + 4, top: y + pad, width: inner, height: h - 2 * pad)
            }
            y += h + 8
            i += 2
        }
        y += 8
    }

    // MARK: Cartes mémoire (planches à découper)

    func cardSheets(_ cards: [RevisionCard]) {
        let per = CardLimits.perSheet
        let sheets = stride(from: 0, to: cards.count, by: per).map { Array(cards[$0..<min(cards.count, $0 + per)]) }
        let gx: CGFloat = 36, top0: CGFloat = 34
        let cw = (Self.pageW - 2 * gx) / 2, ch: CGFloat = 188
        for (n, sheet) in sheets.enumerated() {
            for side in 0..<2 {
                if n > 0 || side == 1 { newPage() }
                let label = side == 0 ? "RECTO" : "VERSO"
                let cap = Look.attr("\(label) · feuille \(n + 1) sur \(sheets.count) · découpe le long des pointillés" + (side == 0 ? ". Imprime en recto verso, retournement sur le bord long." : "."),
                                    size: 8, color: Look.gray)
                drawBox(cap, x: gx, top: 14, width: Self.pageW - 2 * gx, height: 12)
                for (k, card) in sheet.enumerated() {
                    let row = k / 2, col = k % 2
                    let c = side == 0 ? col : 1 - col      // versos inversés pour tomber derrière leur recto
                    drawCard(card, front: side == 0, x: gx + CGFloat(c) * cw, top: top0 + CGFloat(row) * ch, w: cw, h: ch)
                }
                // pointillés de découpe
                ctx.saveGState()
                ctx.setStrokeColor(Look.gray.withAlphaComponent(0.7).cgColor)
                ctx.setLineWidth(0.6); ctx.setLineDash(phase: 0, lengths: [4, 3])
                for r in 0...4 {
                    let yy = Self.pageH - (top0 + CGFloat(r) * ch)
                    ctx.move(to: CGPoint(x: gx, y: yy)); ctx.addLine(to: CGPoint(x: gx + 2 * cw, y: yy)); ctx.strokePath()
                }
                for c in 0...2 {
                    let xx = gx + CGFloat(c) * cw
                    ctx.move(to: CGPoint(x: xx, y: Self.pageH - top0)); ctx.addLine(to: CGPoint(x: xx, y: Self.pageH - top0 - 4 * ch)); ctx.strokePath()
                }
                ctx.restoreGState()
            }
        }
    }

    private func drawCard(_ card: RevisionCard, front: Bool, x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat) {
        let inset: CGFloat = 9
        let ix = x + inset, itop = top + inset, iw = w - 2 * inset, ih = h - 2 * inset
        let color = front ? accent : Look.green
        fill(x: ix, top: itop, w: iw, h: ih, color: front ? .white : Look.softTint(color), radius: 10)
        ctx.setStrokeColor(color.withAlphaComponent(0.8).cgColor); ctx.setLineWidth(1.2)
        ctx.addPath(CGPath(roundedRect: CGRect(x: ix, y: Self.pageH - itop - ih, width: iw, height: ih), cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.strokePath()
        let tag = NSMutableAttributedString(string: "\(front ? "QUESTION" : "RÉPONSE") · \(card.id)", attributes: [
            .font: Look.font(8, bold: true), .foregroundColor: color, .paragraphStyle: Look.para()])
        drawBox(tag, x: ix + 12, top: itop + 10, width: iw - 24, height: 11)
        // texte centré, taille réduite jusqu'à ce qu'il tienne
        let content = front ? card.front : card.back
        let areaTop = itop + 28, areaH = ih - 28 - 14, areaW = iw - 28
        let center = NSMutableParagraphStyle(); center.alignment = .center; center.lineSpacing = 3
        var size: CGFloat = front ? 16 : 13.5
        var a = NSAttributedString()
        while true {
            a = NSAttributedString(string: content, attributes: [.font: Look.font(size, bold: front), .foregroundColor: Look.ink, .paragraphStyle: center])
            if measure(a, width: areaW) <= areaH || size <= 8 { break }
            size -= 0.5
        }
        let th = min(measure(a, width: areaW), areaH)
        drawBox(a, x: ix + 14, top: areaTop + (areaH - th) / 2, width: areaW, height: th)
        if front, let p = card.page {
            let pg = Look.attr("page \(p)", size: 8, color: Look.gray)
            drawBox(pg, x: ix + 12, top: itop + ih - 16, width: 60, height: 10)
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
