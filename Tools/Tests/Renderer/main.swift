import Foundation
import PDFKit
import AppKit
import CoreText
import Vision

// Banc d'essai du module « rendu » (AnswerRenderer) — vérifie l'écriture des réponses par l'exécution, avec des
// contrôles faits sur des images rendues par PDFKit (pas seulement sur les objets) :
//   renderer-test all [dossier]                         toute la batterie, avec un bilan réussi / échec
//   renderer-test calage|synthetic|cycle|exports [dossier]   une partie seulement (cycle, exports : vrais PDF)
//   renderer-test real <clé|fichier.pdf> <dossier> [pages 1,2] [--mode fit|kind|short|long|mix]
//                      [--style bleu|noir|manuscrit] [--sheets] [--dump] [--ppp 2.1]
//                                                        un PDF réel : réponses d'exemple, PNG des pages (--sheets : détails des zones)
//   renderer-test list                                  les clés des PDF réels
// Compilation :
//   swiftc -O -swift-version 5 -target arm64-apple-macos26.0 Sources/Core/*.swift Tools/Tests/Renderer/main.swift -o build/rendu/renderer-test
// Les PDF réels (~/Desktop/Cours) ne sont que lus : on travaille sur des copies vierges écrites dans le dossier de sortie.

// MARK: - Bilan

var failures = 0
var checks = 0

func check(_ ok: Bool, _ message: String) {
    checks += 1
    if !ok { failures += 1 }
    print((ok ? "  [ok]     " : "  [ECHEC]  ") + message)
}

func info(_ message: String) { print("           " + message) }

func section(_ title: String) { print("\n== \(title) ==") }

// MARK: - Pages synthétiques et rendu

/// PDF d'une page blanche dessinée par `draw` (espace page PDF, origine de la boîte `media`).
func makePDF(media: CGRect = CGRect(x: 0, y: 0, width: 595, height: 842), draw: (CGContext) -> Void) -> PDFDocument {
    let data = NSMutableData()
    var box = media
    let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(media)
    draw(ctx)
    ctx.endPDFPage()
    ctx.closePDF()
    return PDFDocument(data: data as Data)!
}

/// Trait gris d'une ligne à écrire.
func strokeRule(_ ctx: CGContext, _ l: WritingLine, width: CGFloat = 0.6) {
    ctx.setStrokeColor(gray: 0.5, alpha: 1)
    ctx.setLineWidth(width)
    ctx.move(to: CGPoint(x: l.x0, y: l.y)); ctx.addLine(to: CGPoint(x: l.x1, y: l.yEnd)); ctx.strokePath()
}

struct Pixels {
    let w: Int, h: Int
    var rgba: [UInt8]
    init(_ img: CGImage) {
        w = img.width; h = img.height
        rgba = [UInt8](repeating: 255, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }
    /// Pixel d'écriture bleue (le bleu domine nettement le rouge) : la couleur du style « bleu imprimé ».
    func isBlueInk(_ x: Int, _ y: Int) -> Bool {
        let i = (y * w + x) * 4
        let r = Int(rgba[i]), b = Int(rgba[i + 2])
        return b - r > 60 && b > 90 && r < 170
    }
    func gray(_ x: Int, _ y: Int) -> Int {
        let i = (y * w + x) * 4
        return (Int(rgba[i]) + Int(rgba[i + 1]) + Int(rgba[i + 2])) / 3
    }
    func differs(from o: Pixels, _ x: Int, _ y: Int) -> Bool {
        let i = (y * w + x) * 4
        for k in 0..<3 where abs(Int(rgba[i + k]) - Int(o.rgba[i + k])) > 40 { return true }
        return false
    }
}

func renderPage(_ page: PDFPage, ppp: CGFloat) -> (CGImage, PageGeometry) {
    let box = page.bounds(for: .cropBox)
    return PageImaging.render(page: page, longEdge: ppp * max(box.width, box.height))!
}

/// Image d'un rectangle de la page (points) à `ppp` pixels par point, par un dessin direct de la page (annotations comprises).
func snapshot(_ page: PDFPage, rect: CGRect, ppp: CGFloat) -> CGImage? {
    let box = page.bounds(for: .cropBox)
    let r = rect.intersection(box)
    guard !r.isNull, r.width > 1, r.height > 1 else { return nil }
    let w = Int(ceil(r.width * ppp)), h = Int(ceil(r.height * ppp))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: ppp, y: ppp)
    ctx.translateBy(x: -(r.minX - box.minX), y: -(r.minY - box.minY))
    page.draw(with: .cropBox, to: ctx)
    return ctx.makeImage()
}

func writePNG(_ img: CGImage, to path: String) {
    if let d = PageImaging.pngData(img) { try? d.write(to: URL(fileURLWithPath: path)) }
}

/// Fraction de blocs 8 x 8 dont la luminosité moyenne diffère nettement : insensible aux petits décalages de glyphes
/// (anti-crénelage), sensible à une ligne déplacée, manquante ou en trop.
func blockDifference(_ a: CGImage, _ b: CGImage) -> Double {
    guard a.width == b.width, a.height == b.height else { return 1 }
    let pa = Pixels(a), pb = Pixels(b)
    let bs = 8
    var differing = 0, total = 0
    var by = 0
    while by + bs <= pa.h {
        var bx = 0
        while bx + bs <= pa.w {
            var sa = 0, sb = 0
            for y in by..<by + bs { for x in bx..<bx + bs { sa += pa.gray(x, y); sb += pb.gray(x, y) } }
            if abs(sa - sb) / (bs * bs) > 24 { differing += 1 }
            total += 1
            bx += bs
        }
        by += bs
    }
    return total == 0 ? 0 : Double(differing) / Double(total)
}

/// Nombre de pixels qui diffèrent (écart > 40) entre deux images de même taille.
func pixelDifference(_ a: CGImage, _ b: CGImage) -> Int {
    guard a.width == b.width, a.height == b.height else { return Int.max }
    let pa = Pixels(a), pb = Pixels(b)
    var count = 0
    for y in 0..<pa.h { for x in 0..<pa.w where pa.differs(from: pb, x, y) { count += 1 } }
    return count
}

/// Image des différences : fond pâle, pixels qui diffèrent en rouge.
func diffImage(_ a: CGImage, _ b: CGImage) -> CGImage? {
    guard a.width == b.width, a.height == b.height else { return nil }
    let pa = Pixels(a), pb = Pixels(b)
    var out = pa
    for y in 0..<pa.h { for x in 0..<pa.w {
        let i = (y * pa.w + x) * 4
        if pa.differs(from: pb, x, y) { out.rgba[i] = 255; out.rgba[i + 1] = 0; out.rgba[i + 2] = 0 }
        else { for k in 0..<3 { out.rgba[i + k] = UInt8(min(255, 170 + Int(pa.rgba[i + k]) / 4)) } }
    } }
    return out.rgba.withUnsafeMutableBytes { buf in
        CGContext(data: buf.baseAddress, width: a.width, height: a.height, bitsPerComponent: 8, bytesPerRow: a.width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
}

func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: f])), nil, nil, nil))
}

// MARK: - Contrôles indépendants du code testé

/// L'encre d'une annotation : les pixels qui changent quand on la masque, dans un rendu direct de la page (6 px par point).
/// Renvoie aussi la position de l'annotation dans l'image (pour savoir si l'encre touche ses bords).
func annotationInk(_ a: PDFAnnotation, page: PDFPage, margin: CGFloat = 6, ppp: CGFloat = 6) -> (px: Pixels, mask: Pixels, boxInImage: CGRect)? {
    let rect = a.bounds.insetBy(dx: -margin, dy: -margin)
    a.shouldDisplay = false
    let off = snapshot(page, rect: rect, ppp: ppp)
    a.shouldDisplay = true
    guard let off, let on = snapshot(page, rect: rect, ppp: ppp), on.width == off.width, on.height == off.height else { return nil }
    let r = rect.intersection(page.bounds(for: .cropBox))
    let box = CGRect(x: (a.bounds.minX - r.minX) * ppp, y: (r.maxY - a.bounds.maxY) * ppp, width: a.bounds.width * ppp, height: a.bounds.height * ppp)
    return (Pixels(on), Pixels(off), box)
}

/// Une annotation de texte s'affiche-t-elle sur UNE ligne, en entier, sans être rognée ? Sa largeur d'encre doit être celle
/// du texte (Core Text), sa hauteur celle d'une seule ligne, et elle ne doit pas toucher le bas ni le côté droit de
/// l'annotation (là où PDFKit rogne). Renvoie la description du problème, ou nil.
func annotationInkProblem(_ a: PDFAnnotation, page: PDFPage) -> String? {
    guard let font = a.font, let text = a.contents, !text.isEmpty else { return "annotation sans texte" }
    guard let (on, off, box) = annotationInk(a, page: page) else { return "rendu impossible : « \(text.prefix(30)) »" }
    let ppp: CGFloat = 6
    var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
    for y in 0..<on.h { for x in 0..<on.w where on.differs(from: off, x, y) {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    guard maxX >= 0 else { return "aucune encre visible : « \(text.prefix(30)) »" }
    let inkW = CGFloat(maxX - minX + 1) / ppp, inkH = CGFloat(maxY - minY + 1) / ppp
    let expected = textWidth(text, font)
    if inkW > expected + 2.5 { return String(format: "encre trop large (%.1f pt pour un texte de %.1f pt) : « %@ »", inkW, expected, String(text.prefix(30))) }
    if inkW < expected - 3.5 - 0.005 * expected { return String(format: "texte raccourci ou passé à la ligne (encre %.1f pt pour %.1f pt) : « %@ »", inkW, expected, String(text.prefix(30))) }
    let lineHeight = font.ascender - font.descender + font.leading
    if inkH > lineHeight * 1.3 + 1 { return String(format: "plusieurs lignes d'encre (hauteur %.1f pt pour une ligne de %.1f pt) : « %@ »", inkH, lineHeight, String(text.prefix(30))) }
    if CGFloat(maxY) >= box.maxY - 1 { return "l'encre touche le bas de l'annotation (jambages rognés) : « \(text.prefix(30)) »" }
    if CGFloat(maxX) >= box.maxX - 1 { return "l'encre touche le bord droit de l'annotation : « \(text.prefix(30)) »" }
    if CGFloat(minY) <= box.minY + 1 { return "l'encre touche le haut de l'annotation (accents rognés) : « \(text.prefix(30)) »" }
    return nil
}

/// Texte reconnu (OCR) dans une image.
func ocrText(_ img: CGImage) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["fr-FR", "en-US"]
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: img, options: [:])
    guard (try? handler.perform([request])) != nil else { return "" }
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
}

func normalized(_ s: String) -> String {
    let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
    return folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
        .split(separator: " ").joined(separator: " ")
}

/// Distance d'édition (pour tolérer une erreur de lecture de l'OCR).
func editDistance(_ a: String, _ b: String) -> Int {
    let x = Array(a), y = Array(b)
    if x.isEmpty { return y.count }
    if y.isEmpty { return x.count }
    var prev = Array(0...y.count)
    for i in 1...x.count {
        var cur = [i] + Array(repeating: 0, count: y.count)
        for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
        prev = cur
    }
    return prev[y.count]
}

/// Le mot (ou un mot proche) figure-t-il dans le texte reconnu ?
func ocrContains(_ ocr: String, word: String) -> Bool {
    let w = normalized(word)
    if w.isEmpty { return true }
    let all = normalized(ocr)
    if all.contains(w) { return true }
    let tolerance = w.count >= 6 ? 2 : (w.count >= 4 ? 1 : 0)
    return all.split(separator: " ").contains { editDistance(String($0), w) <= tolerance }
}

/// Champs de formulaire remplis : la valeur relue se termine par le bon mot et ce mot se lit à l'écran (OCR).
func widgetProblems(doc: PDFDocument, zones: [Zone], result: RenderResult) -> (checked: Int, problems: [String]) {
    var problems: [String] = []
    var checked = 0
    for z in zones {
        guard let filled = result.fields[z.id], let page = doc.page(at: z.page) else { continue }
        let w = filled.widget
        let value = w.widgetStringValue ?? ""
        let wanted = InkProbe.expectedLastWord(of: z.answer, shown: value)
        guard let last = value.split(separator: " ").last.map(String.init) else { problems.append("p\(z.page + 1) #\(z.number) : valeur vide"); continue }
        checked += 1
        if !z.answer.hasPrefix(String(value.prefix(max(0, value.count - 2)))) && value.count > 3 && wanted == nil {
            problems.append("p\(z.page + 1) #\(z.number) : la valeur écrite n'est pas le début de la réponse")
        }
        guard let img = snapshot(page, rect: w.bounds.insetBy(dx: -1, dy: -1), ppp: 6) else { problems.append("p\(z.page + 1) #\(z.number) : rendu impossible"); continue }
        let text = ocrText(img)
        if !ocrContains(text, word: last) {
            problems.append("p\(z.page + 1) #\(z.number) : le dernier mot « \(last) » ne se lit pas dans le champ (taille \(Int(result.fontSizes[z.id] ?? 0)) pt ; OCR : « \(text.prefix(60)) »)")
        }
    }
    return (checked, problems)
}

/// Petit utilitaire de comparaison texte écrit / réponse (la réponse peut avoir été tronquée ou coupée avec des tirets).
enum InkProbe {
    static func expectedLastWord(of answer: String, shown: String) -> String? { nil }
}

// MARK: - Calage : le texte tombe-t-il exactement sur la ligne de base voulue ?

/// Bas de l'encre d'une zone de la page, en points au-dessus de `lineY` (on masque les annotations pour isoler l'encre).
func inkBottom(page: PDFPage, annotations: [PDFAnnotation], x0: CGFloat, x1: CGFloat, lineY: CGFloat, height: CGFloat) -> CGFloat? {
    let ppp: CGFloat = 8
    let rect = CGRect(x: x0, y: lineY - 5, width: x1 - x0, height: height + 9)
    annotations.forEach { $0.shouldDisplay = false }
    let off = snapshot(page, rect: rect, ppp: ppp)
    annotations.forEach { $0.shouldDisplay = true }
    guard let off, let on = snapshot(page, rect: rect, ppp: ppp) else { return nil }
    let a = Pixels(on), b = Pixels(off)
    var lowest = -1
    for y in 0..<a.h { for x in 0..<a.w where a.differs(from: b, x, y) { lowest = max(lowest, y) } }
    guard lowest >= 0 else { return nil }
    let r = rect.intersection(page.bounds(for: .cropBox))
    return r.maxY - CGFloat(lowest + 1) / ppp - lineY            // le haut de l'image est r.maxY
}

func scenarioCalage(outDir: String) {
    section("Calage de la ligne de base (police, taille entière, hauteur de ligne fractionnaire)")
    let fonts = ["Helvetica", "Bradley Hand"]
    let sizes: [CGFloat] = [7, 8, 9, 10, 11, 12, 13]
    var cases: [(font: String, size: CGFloat, y: CGFloat)] = []
    for (fi, f) in fonts.enumerated() { for (si, s) in sizes.enumerated() {
        let i = fi * sizes.count + si
        cases.append((f, s, 800.37 - CGFloat(i) * 47.61))                  // hauteurs fractionnaires, comme dans un vrai scan
    } }
    let doc = makePDF { ctx in for c in cases { strokeRule(ctx, WritingLine(x0: 60, x1: 500, y: c.y)) } }
    var annotations: [[PDFAnnotation]] = []
    for (i, c) in cases.enumerated() {
        var z = Zone(id: i + 1, page: 0, number: i + 1, source: .texte)
        z.lines = [WritingLine(x0: 60, x1: 500, y: c.y)]
        z.textHeight = 30; z.kind = .mot; z.answer = "HEHEH HEH"
        let style = WritingStyle(fontName: c.font, red: 0.05, green: 0.15, blue: 0.75, maxSize: c.size)
        let r = AnswerRenderer.apply(zones: [z], to: doc, style: style)
        annotations.append(r.annotations[z.id] ?? [])
        check(r.fontSizes[z.id] == c.size, "\(c.font) \(Int(c.size)) pt : taille utilisée \(r.fontSizes[z.id] ?? 0)")
    }
    let page = doc.page(at: 0)!
    var rows: [String] = []
    var bad = 0
    for (i, c) in cases.enumerated() {
        guard let above = inkBottom(page: page, annotations: annotations[i], x0: 62, x1: 400, lineY: c.y, height: c.size + 6) else { bad += 1; rows.append("\(c.font) \(c.size) : pas d'encre"); continue }
        // Helvetica : le bas du « H » est sur la ligne de base (1 à 1,5 pt au-dessus de la ligne) ; Bradley Hand : les capitales
        // dépassent un peu sous leur ligne de base, d'où une marge plus large.
        let ok = c.font == "Helvetica" ? (0.8...1.7).contains(above) : (0.15...1.7).contains(above)
        if !ok { bad += 1 }
        rows.append(String(format: "%@ %4.0f pt : bas de l'encre à %+.2f pt de la ligne %@", c.font.padding(toLength: 13, withPad: " ", startingAt: 0), Double(c.size), Double(above), ok ? "" : "  <-- HORS TOLERANCE"))
    }
    rows.forEach(info)
    check(bad == 0, "le texte repose à 0,8–1,7 pt au-dessus de la ligne (Bradley Hand : 0,15–1,7), pour toutes les polices et tailles (\(cases.count) cas)")
    if let c = snapshot(page, rect: CGRect(x: 50, y: 800.37 - 6 * 47.61 - 15, width: 300, height: 6 * 47.61 + 40), ppp: 3) { writePNG(c, to: outDir + "/calage_helvetica.png") }
}

// MARK: - Lignes penchées, origine de page décalée, polices, cas limites

func scenarioSlant(outDir: String) {
    section("Lignes penchées (scan de travers) : le texte suit la pente")
    let slopes: [CGFloat] = [0, 0.004, -0.004, 0.01, -0.01, 0.02, -0.02, 0.04, -0.04]
    let x0: CGFloat = 60, x1: CGFloat = 535
    func line(_ i: Int, _ s: CGFloat) -> WritingLine { WritingLine(x0: x0, x1: x1, y: 800 - CGFloat(i) * 40, yEnd: 800 - CGFloat(i) * 40 + s * (x1 - x0)) }
    let upper = "LE MOTEUR TRANSFORME UNE ENERGIE EN MOUVEMENT ET EN CHALEUR"           // sans jambage : le bas de l'encre est la ligne de base
    let lower = "Le moteur transforme une énergie électrique en mouvement et il produit aussi de la chaleur."
    for (name, text) in [("capitales", upper), ("minuscules", lower)] {
        let doc = makePDF { ctx in for (i, s) in slopes.enumerated() { strokeRule(ctx, line(i, s)) } }
        var zones: [Zone] = []
        for (i, s) in slopes.enumerated() {
            var z = Zone(id: i + 1, page: 0, number: i + 1, source: .ligne)
            z.lines = [line(i, s)]; z.textHeight = 12; z.kind = .question; z.answer = text
            zones.append(z)
        }
        let r = AnswerRenderer.apply(zones: zones, to: doc, style: .bleuImprime)
        let page = doc.page(at: 0)!
        if name == "capitales" {
            var worst: CGFloat = 0, bad = 0, pieces = 0
            var report: [String] = []
            for (i, z) in zones.enumerated() {
                let l = line(i, slopes[i])
                var lifts: [CGFloat] = []
                for a in r.annotations[z.id] ?? [] {
                    guard let font = a.font, let t = a.contents else { continue }
                    let ax0 = a.bounds.minX + 2, ax1 = ax0 + textWidth(t, font)
                    let center = (ax0 + ax1) / 2
                    let yl = l.y(atX: center)
                    guard let above = inkBottom(page: page, annotations: [a], x0: ax0 + 0.5, x1: ax1 - 0.5, lineY: yl, height: font.pointSize + 6) else { bad += 1; continue }
                    lifts.append(above)
                    pieces += 1
                    // la dérive de la ligne d'un bout à l'autre du morceau s'ajoute à l'écart toléré
                    let drift = abs(slopes[i]) * (ax1 - ax0) / 2
                    if above < 0.5 - drift - 0.2 || above > 2.0 + drift + 0.2 { bad += 1 }
                    worst = max(worst, abs(above - 1.2))
                }
                report.append(String(format: "pente %+.3f : %d morceau(x), bas de l'encre entre %+.2f et %+.2f pt au-dessus de la ligne, taille %.0f pt%@", Double(slopes[i]), lifts.count,
                                     Double(lifts.min() ?? 0), Double(lifts.max() ?? 0), Double(r.fontSizes[z.id] ?? 0), r.overflowIDs.contains(z.id) ? " DEBORDE" : ""))
            }
            report.forEach(info)
            check(bad == 0, "capitales : \(pieces) morceaux, tous posés 0,5–2 pt au-dessus de la ligne penchée (écart max. à 1,2 pt : \(String(format: "%.2f", Double(worst))) pt)")
            check(r.overflowIDs.isEmpty, "capitales : aucun débordement")
            let flat = (r.annotations[1] ?? []).count, steep = (r.annotations[8] ?? []).count
            check(flat == 1 && steep > flat, "ligne droite : 1 morceau ; ligne très penchée (0,04) : \(steep) morceaux")
        }
        if let c = snapshot(page, rect: CGRect(x: 40, y: 800 - 8 * 40 - 20, width: 520, height: 8 * 40 + 50), ppp: 2.6) { writePNG(c, to: outDir + "/penche_\(name).png") }
    }

    // plusieurs lignes penchées dans une même zone
    let ml = (0..<3).map { WritingLine(x0: 60, x1: 535, y: 700 - CGFloat($0) * 24, yEnd: 700 - CGFloat($0) * 24 + 0.015 * 475) }
    let doc = makePDF { ctx in ml.forEach { strokeRule(ctx, $0) } }
    var z = Zone(id: 1, page: 0, number: 1, source: .ligne)
    z.lines = ml; z.textHeight = 12; z.kind = .question
    z.answer = "L’information doit être vérifiée avant d’être partagée. On regarde d’abord qui l’a publiée et quand, puis on cherche une deuxième source indépendante. Enfin, on se méfie des titres « chocs »."
    let r = AnswerRenderer.apply(zones: [z], to: doc, style: .bleuImprime)
    check((r.annotations[1]?.count ?? 0) >= 6, "3 lignes penchées : \(r.annotations[1]?.count ?? 0) morceaux, taille \(Int(r.fontSizes[1] ?? 0)) pt, débordement : \(r.overflowIDs.contains(1))")
    var inkProblems = 0
    for a in r.annotations[1] ?? [] { if let p = annotationInkProblem(a, page: doc.page(at: 0)!) { inkProblems += 1; info("   " + p) } }
    check(inkProblems == 0, "3 lignes penchées : tous les morceaux sont lisibles en entier")
    if let c = snapshot(doc.page(at: 0)!, rect: CGRect(x: 40, y: 690 - 24 * 2 - 12, width: 520, height: 24 * 2 + 70), ppp: 2.6) { writePNG(c, to: outDir + "/penche_multilignes.png") }
}

func scenarioOrigin(outDir: String) {
    section("Page dont la boîte ne commence pas à (0, 0)")
    let media = CGRect(x: 40, y: 70, width: 420, height: 300)
    let line = WritingLine(x0: 100, x1: 420, y: 250.5)
    let cell = CGRect(x: 100, y: 120, width: 150, height: 60)
    let doc = makePDF(media: media) { ctx in
        strokeRule(ctx, line)
        ctx.setStrokeColor(gray: 0.3, alpha: 1); ctx.setLineWidth(1); ctx.stroke(cell)
    }
    let page = doc.page(at: 0)!
    let b = page.bounds(for: .cropBox)
    info(String(format: "boîte de la page : origine (%.0f, %.0f), taille %.0f x %.0f", Double(b.minX), Double(b.minY), Double(b.width), Double(b.height)))
    var l = Zone(id: 1, page: 0, number: 1, source: .ligne); l.lines = [line]; l.textHeight = 12; l.kind = .mot; l.answer = "HEHEH HEH"
    var c = Zone(id: 2, page: 0, number: 2, source: .cadre); c.box = cell; c.kind = .definition; c.answer = "Un mot puis une phrase plus longue qui passe à la ligne."
    let r = AnswerRenderer.apply(zones: [l, c], to: doc, style: .bleuImprime)
    let above = inkBottom(page: page, annotations: r.annotations[1] ?? [], x0: 104, x1: 200, lineY: line.y, height: 18)
    check(above.map { (0.8...1.7).contains($0) } ?? false, String(format: "ligne : le bas de l'encre est à %+.2f pt de la ligne", Double(above ?? -99)))
    // le texte du cadre : dans le cadre, près du haut à gauche
    let anns = r.annotations[2] ?? []
    var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
    for a in anns {
        guard let (on, off, _) = annotationInk(a, page: page, margin: 2, ppp: 6) else { continue }
        let rr = a.bounds.insetBy(dx: -2, dy: -2).intersection(b)
        for y in 0..<on.h { for x in 0..<on.w where on.differs(from: off, x, y) {
            let px = rr.minX + CGFloat(x) / 6, py = rr.maxY - CGFloat(y) / 6
            minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, py); maxY = max(maxY, py)
        } }
    }
    check(anns.count >= 2 && minX >= cell.minX + 1 && maxX <= cell.maxX - 1 && maxY <= cell.maxY - 1 && minY >= cell.minY,
          String(format: "cadre (page à origine décalée) : %d lignes, texte entre x %.1f–%.1f / y %.1f–%.1f pour un cadre x %.0f–%.0f / y %.0f–%.0f", anns.count, Double(minX), Double(maxX), Double(minY), Double(maxY), Double(cell.minX), Double(cell.maxX), Double(cell.minY), Double(cell.maxY)))
    if let img = snapshot(page, rect: b, ppp: 2.5) { writePNG(img, to: outDir + "/origine_decalee.png") }
}

func scenarioFonts(outDir: String) {
    section("Polices : trois styles, police inconnue, caractères français et symboles")
    let lines = [
        "Accents : à â ä é è ê ë î ï ô ö ù û ü ÿ ç œ æ — À É È Ç Œ",
        "Typographie : l’énergie, « citation », “anglais”, ‘a’, 'droit', \"droit\", … – —",
        "Maths : 2 × 3 = 6 ; 6 ÷ 2 ; x² + y³ ; 5 ≤ 7 ≥ 3 ≠ 4 ≈ 4,1 ; √2 ; π ; ∞ ; 25 % ; −3 ; ±2",
        "Physique : 230 V ; 50 Hz ; 10 Ω ; 5 µA ; 20 °C ; ΔU ; λ ; → ← ↔ ; 5 € ; N° 3",
        "Espaces : 12 000 € ; « test » ; 5\u{00A0}km ; 1\u{202F}234 ; Qui\u{00A0}? Oui\u{202F}!",
    ]
    let styles: [(String, WritingStyle)] = [
        ("bleu imprime", .bleuImprime), ("noir imprime", .noirImprime), ("manuscrit", .manuscrit),
        ("police inconnue", WritingStyle(fontName: "PoliceQuiNExistePas", red: 0.7, green: 0.1, blue: 0.1, maxSize: 11)),
    ]
    for (name, style) in styles {
        let doc = makePDF { ctx in for i in 0..<lines.count { strokeRule(ctx, WritingLine(x0: 40, x1: 560, y: 800 - CGFloat(i) * 30)) } }
        var zones: [Zone] = []
        for (i, t) in lines.enumerated() {
            var z = Zone(id: i + 1, page: 0, number: i + 1, source: .texte)
            z.lines = [WritingLine(x0: 40, x1: 560, y: 800 - CGFloat(i) * 30)]
            z.textHeight = 11; z.kind = .mot; z.answer = t
            zones.append(z)
        }
        let r = AnswerRenderer.apply(zones: zones, to: doc, style: style)
        let page = doc.page(at: 0)!
        let anns = page.annotations.filter { ($0.type ?? "") == "FreeText" }
        let fontNames = Set(anns.compactMap { $0.font?.fontName })
        let expected: String = name == "manuscrit" ? "BradleyHand" : "Helvetica"
        check(fontNames.count == 1 && (fontNames.first ?? "").contains(expected), "\(name) : police employée \(fontNames.sorted().joined(separator: ", "))")
        check(r.overflowIDs.isEmpty && r.skippedIDs.isEmpty, "\(name) : tout est écrit, sans débordement (tailles \(r.fontSizes.sorted { $0.key < $1.key }.map { String(format: "%.0f", Double($0.value)) }.joined(separator: ",")))")
        check(anns.allSatisfy { $0.userName == AnswerRenderer.annotationAuthor && $0.color.alphaComponent == 0 && ($0.border?.lineWidth ?? 0) == 0 },
              "\(name) : annotations marquées « \(AnswerRenderer.annotationAuthor) », sans fond ni bordure")
        var bad = 0
        for a in anns { if let p = annotationInkProblem(a, page: page) { bad += 1; info("   " + p) } }
        check(bad == 0, "\(name) : les \(anns.count) lignes s'affichent en entier (accents, apostrophes, guillemets, symboles)")
        if let c = snapshot(page, rect: CGRect(x: 30, y: 800 - CGFloat(lines.count) * 30 + 10, width: 540, height: CGFloat(lines.count) * 30 + 5), ppp: 2.8) {
            writePNG(c, to: outDir + "/polices_\(name.replacingOccurrences(of: " ", with: "_")).png")
        }
    }
}

/// Copie indépendante d'un document (pour les tests qui ne doivent pas laisser de traces dans l'original).
func copyOf(_ doc: PDFDocument) -> PDFDocument { PDFDocument(data: doc.dataRepresentation()!)! }

func scenarioEdgeCases(outDir: String) {
    section("Cas limites")
    let doc = makePDF { ctx in
        for i in 0..<4 { strokeRule(ctx, WritingLine(x0: 60, x1: 260, y: 780 - CGFloat(i) * 30)) }
        strokeRule(ctx, WritingLine(x0: 60, x1: 260, y: 560))
        strokeRule(ctx, WritingLine(x0: 60, x1: 160, y: 530)); strokeRule(ctx, WritingLine(x0: 60, x1: 160, y: 506))
        strokeRule(ctx, WritingLine(x0: 60, x1: 260, y: 470))
        ctx.setStrokeColor(gray: 0.3, alpha: 1); ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 300, y: 600, width: 30, height: 12))                  // case minuscule
        ctx.stroke(CGRect(x: 300, y: 300, width: 250, height: 200))               // grand cadre
    }
    var nextID = 1
    func lineZone(_ y: CGFloat, _ text: String) -> Zone {
        var z = Zone(id: nextID, page: 0, number: nextID, source: .texte); nextID += 1
        z.lines = [WritingLine(x0: 60, x1: 260, y: y)]; z.textHeight = 11; z.kind = .mot; z.answer = text
        return z
    }
    func boxZone(_ r: CGRect, _ text: String) -> Zone {
        var z = Zone(id: nextID, page: 0, number: nextID, source: .cadre); nextID += 1
        z.box = r; z.kind = .question; z.answer = text
        return z
    }
    let empty = lineZone(780, "")
    let blank = lineZone(750, "  \n \t ")
    var disabled = lineZone(720, "Réponse désactivée"); disabled.enabled = false
    var ignored = lineZone(690, "Réponse ignorée"); ignored.kind = .ignorer
    var elsewhere = lineZone(660, "Page qui n'existe pas"); elsewhere.page = 7
    var tooShort = lineZone(630, "Trop court"); tooShort.lines = [WritingLine(x0: 60, x1: 64, y: 630)]
    let r1 = AnswerRenderer.apply(zones: [empty, blank, disabled, ignored], to: doc, style: .bleuImprime)
    check(r1.annotations.isEmpty && r1.fields.isEmpty && r1.touchedPages.isEmpty && r1.skippedIDs.isEmpty,
          "réponse vide, blanche, zone désactivée ou « à ignorer » : rien n'est écrit")
    let r2 = AnswerRenderer.apply(zones: [elsewhere, tooShort], to: doc, style: .bleuImprime)
    check(r2.skippedIDs == [elsewhere.id, tooShort.id] && r2.annotations.isEmpty, "page introuvable ou ligne trop courte : zones signalées dans skippedIDs (\(r2.skippedIDs.sorted()))")

    // débordements
    let longWord = lineZone(560, "Anticonstitutionnellement-et-sans-aucune-coupure-possible-dans-ce-mot")
    var twoLines = lineZone(530, "Une réponse beaucoup trop longue pour deux lignes de cent points seulement, qui doit déborder.")
    twoLines.lines = [WritingLine(x0: 60, x1: 160, y: 530), WritingLine(x0: 60, x1: 160, y: 506)]
    let tinyBox = boxZone(CGRect(x: 300, y: 600, width: 30, height: 12), "Beaucoup trop long pour cette case minuscule")
    let bigBox = boxZone(CGRect(x: 300, y: 300, width: 250, height: 200), Sample.paragraphs.joined(separator: " "))
    let hugeBox = boxZone(CGRect(x: 300, y: 300, width: 250, height: 200), String(repeating: "mot ", count: 1500))
    let emoji = lineZone(470, "Smiley 😀 et ✓ test")
    let t0 = Date()
    let r3 = AnswerRenderer.apply(zones: [longWord, twoLines, tinyBox, bigBox, emoji], to: doc, style: .bleuImprime)
    check(r3.overflowIDs.contains(longWord.id), "mot de 70 caractères sans espace sur une ligne de 200 pt : coupé, et signalé en débordement (\(Int(r3.fontSizes[longWord.id] ?? 0)) pt)")
    check(r3.overflowIDs.contains(twoLines.id) && !(r3.annotations[twoLines.id] ?? []).isEmpty, "deux lignes de 100 pt, réponse trop longue : ce qui tient est écrit (\(r3.annotations[twoLines.id]?.count ?? 0) lignes), débordement signalé")
    check(r3.overflowIDs.contains(tinyBox.id) && !(r3.annotations[tinyBox.id] ?? []).isEmpty, "case de 30 x 12 pt : débordement signalé, rien ne plante")
    check(!r3.overflowIDs.contains(bigBox.id), "grand cadre, réponse de trois paragraphes : tient, sans débordement (\(Int(r3.fontSizes[bigBox.id] ?? 0)) pt)")
    check(!(r3.annotations[emoji.id] ?? []).isEmpty, "émoji et symboles : écrits sans erreur")
    check(r3.fontSizes.values.allSatisfy { $0 == $0.rounded() && $0 >= 7 }, "toutes les tailles sont entières et d'au moins 7 pt (PDFKit arrondit les tailles à l'entier)")
    if let img = snapshot(doc.page(at: 0)!, rect: CGRect(x: 40, y: 440, width: 520, height: 370), ppp: 2.5) { writePNG(img, to: outDir + "/cas_limites.png") }
    let r4 = AnswerRenderer.apply(zones: [hugeBox], to: copyOf(doc), style: .manuscrit)
    check(r4.overflowIDs.contains(hugeBox.id) && Date().timeIntervalSince(t0) < 5, "réponse de 6 000 caractères dans un cadre : tronquée, signalée, le tout en moins de 5 s")

    // page tournée : prise en charge (zones dans l'espace de la page affichée) ; le détail est dans Tools/Tests/Detector
    for rot in [90, 180, 270] {
        let rotated = makePDF { _ in }
        rotated.page(at: 0)!.rotation = rot
        let rz = lineZone(400, "Page tournée")
        let r5 = AnswerRenderer.apply(zones: [rz], to: rotated, style: .bleuImprime)
        check(r5.skippedIDs.isEmpty && !(r5.annotations[rz.id] ?? []).isEmpty, "page tournée de \(rot)° : réponse écrite, aucune zone ignorée")
    }
}

// MARK: - Réponses d'exemple

enum Sample {
    static let words = ["Safran", "turboréacteur", "1924", "le chiffre d’affaires", "équipementier", "230 V", "énergie", "résistance",
                        "l’ouvrier", "Ohm", "les médias", "une source fiable"]
    static let sentences = [
        "Une entreprise est une organisation qui produit des biens ou des services pour les vendre.",
        "Le courant électrique est un déplacement ordonné de charges dans un conducteur.",
        "Une fake news est une information fausse diffusée pour tromper ou pour faire du bruit sur les réseaux.",
    ]
    static let paragraphs = [
        "Safran est un grand groupe français spécialisé dans l’aéronautique, la défense et l’espace. Il conçoit et fabrique des moteurs d’avions, des trains d’atterrissage et des équipements de bord. Son activité repose sur l’innovation et sur des centaines de sites dans le monde.",
        "L’information doit être vérifiée avant d’être partagée. On regarde d’abord qui l’a publiée et quand, puis on cherche une deuxième source indépendante. Enfin, on se méfie des titres « chocs » qui jouent sur l’émotion plutôt que sur les faits.",
        "La moyenne d’une série statistique s’obtient en additionnant toutes les valeurs puis en divisant par l’effectif total. La médiane partage la série en deux groupes de même effectif. L’étendue est la différence entre la plus grande et la plus petite valeur.",
    ]

    /// La réponse la plus longue (mot < phrase < trois phrases) qui tient dans la capacité de la zone — ce que ferait une IA raisonnable.
    static func fitting(for z: Zone, index: Int) -> String {
        let cap = z.capacity
        let w = words[(index + z.number) % words.count]
        let one = sentences[(index + z.number) % sentences.count]
        let three = paragraphs[(index + z.number) % paragraphs.count]
        if z.kind == .mot { return w }
        if three.count <= cap { return three }
        if one.count <= cap { return one }
        return w
    }

    static func answer(for z: Zone, index: Int, mode: String) -> String {
        switch mode {
        case "fit": return fitting(for: z, index: index)
        case "short": return words[(index + z.number) % words.count]
        case "long": return paragraphs[(index + z.number) % paragraphs.count] + " " + paragraphs[(index + z.number + 1) % paragraphs.count]
        case "mix":
            switch (index + z.page) % 3 {
            case 0: return words[(index + z.number) % words.count]
            case 1: return sentences[(index + z.number) % sentences.count]
            default: return paragraphs[(index + z.number) % paragraphs.count]
            }
        default:      // « kind » : un mot, une phrase ou trois phrases selon Zone.kind
            switch z.kind {
            case .mot: return words[(index + z.number) % words.count]
            case .definition: return sentences[(index + z.number) % sentences.count]
            default: return paragraphs[(index + z.number) % paragraphs.count]
            }
        }
    }
}

// MARK: - Vrais PDF

let home = NSHomeDirectory()
let realFiles: [(key: String, path: String)] = [
    ("safran", home + "/Desktop/Cours/Économie-Gestion/Mission 1 - Présenter un secteur d'activité (Safran).pdf"),
    ("portail", home + "/Desktop/Cours/Co-intervention/Portail - Séance 1 - Découvrir Copilot et charte IA.pdf"),
    ("fakenews", home + "/Desktop/Cours/Français/Objet d'étude 1 - S'informer/Séance 4 - Les fake news.pdf"),
    ("stats", home + "/Desktop/Cours/Maths/Cours/Séquence 1 - Statistiques à une variable.pdf"),
    ("ph", home + "/Desktop/Cours/Physique-Chimie/Cours/Le pH.pdf"),
    ("atelier", home + "/Desktop/Cours/_Originaux avant completion/Atelier Professionnel/Chantier 5/Seance 1.pdf"),
]

func path(forKey key: String) -> String? {
    let p = realFiles.first { $0.key == key }?.path ?? key
    return FileManager.default.fileExists(atPath: p) ? p : nil
}

/// Feuille vierge : copie du PDF sans les annotations FreeText (anciennes réponses), écrite dans `dir`.
func writeBlankCopy(of source: String, in dir: String, name: String) -> URL? {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: source)) else { return nil }
    for i in 0..<doc.pageCount {
        guard let p = doc.page(at: i) else { continue }
        for a in p.annotations where (a.type ?? "") == "FreeText" { p.removeAnnotation(a) }
    }
    let url = URL(fileURLWithPath: dir + "/" + name + "_vierge.pdf")
    guard let data = doc.dataRepresentation(), (try? data.write(to: url)) != nil else { return nil }
    return url
}

func sha(_ url: URL) -> String {
    guard let d = try? Data(contentsOf: url) else { return "?" }
    var h: UInt64 = 1469598103934665603
    for b in d { h = (h ^ UInt64(b)) &* 1099511628211 }
    return String(h, radix: 16) + "/\(d.count)"
}

func fileSize(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1 }

struct RealRun {
    var blank: URL
    var zones: [Zone]
    var doc: PDFDocument
    var result: RenderResult
}

/// Zones d'un PDF réel (copie vierge analysée par la vraie détection), avec des réponses d'exemple.
func analyzedZones(key: String, outDir: String, name: String, pages: [Int]?, mode: String) -> (URL, [Zone])? {
    guard let source = path(forKey: key), let blank = writeBlankCopy(of: source, in: outDir, name: name) else { return nil }
    let analyses = CoursPipeline.analyze(url: blank, needText: false, progress: { _, _ in })
    var zones = analyses.flatMap { $0.zones }
    if let pages { zones = zones.filter { pages.contains($0.page + 1) } }
    for i in zones.indices { zones[i].answer = Sample.answer(for: zones[i], index: i, mode: mode); zones[i].rawAnswer = zones[i].answer }
    return (blank, zones)
}

/// Écrit des réponses d'exemple dans une copie ouverte, comme le fait l'application.
func runReal(key: String, outDir: String, pages: [Int]?, mode: String, style: WritingStyle) -> RealRun? {
    let stem = (key as NSString).lastPathComponent.replacingOccurrences(of: ".pdf", with: "")
    guard let (blank, zones) = analyzedZones(key: key, outDir: outDir, name: stem, pages: pages, mode: mode) else { print("PDF inconnu ou illisible : \(key)"); return nil }
    let doc = PDFDocument(url: blank)!
    let result = AnswerRenderer.apply(zones: zones, to: doc, style: style)
    return RealRun(blank: blank, zones: zones, doc: doc, result: result)
}

/// Planche de détails : pour chaque zone, un extrait de la page (rectangle de la zone agrandi), empilés avec une étiquette.
func contactSheet(page: PDFPage, zones: [Zone], result: RenderResult, ppp: CGFloat, to path: String) {
    guard !zones.isEmpty else { return }
    let box = page.bounds(for: .cropBox)
    let (full, geo) = renderPage(page, ppp: ppp)
    var crops: [(CGImage, String)] = []
    for z in zones {
        var r = z.rect.insetBy(dx: -8, dy: -8)
        if let b = z.box { r = b.insetBy(dx: -6, dy: -6) } else { r.size.height += 6 }
        r = r.intersection(box)
        if r.width > 540 { r.size.width = 540 }
        if r.isNull || r.width < 4 { continue }
        let px = geo.toImage(rect: r).integral.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard let c = full.cropping(to: px) else { continue }
        let size = result.fontSizes[z.id].map { String(format: "%.0f pt", Double($0)) } ?? "-"
        let kind = result.fields[z.id] != nil ? "champ" : (z.box != nil ? "cadre" : "\(z.lines.count) lig.")
        crops.append((c, "p\(z.page + 1) #\(z.number) \(z.source.rawValue)/\(z.kind.rawValue) \(kind) \(size)\(result.overflowIDs.contains(z.id) ? " DEBORDE" : "")"))
    }
    let labelH = 18, gap = 6
    let width = crops.map { $0.0.width }.max() ?? 10
    let height = crops.reduce(0) { $0 + $1.0.height + labelH + gap }
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    var y = height
    for (c, label) in crops {
        y -= labelH
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(calibratedRed: 0.6, green: 0, blue: 0, alpha: 1)]
        ctx.textPosition = CGPoint(x: 4, y: CGFloat(y) + 4)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attrs)), ctx)
        y -= c.height
        ctx.draw(c, in: CGRect(x: 0, y: y, width: c.width, height: c.height))
        y -= gap
    }
    if let img = ctx.makeImage() { writePNG(img, to: path) }
}

func scenarioReal(key: String, outDir: String, pages: [Int]?, mode: String, styleKey: String, sheets: Bool, dump: Bool, ppp: CGFloat = 2.1) {
    guard path(forKey: key) != nil else { print("  [ignoré] cours absent du Mac : \(key)"); return }
    section("\(key) — réponses « \(mode) », style \(styleKey)")
    let t0 = Date()
    guard let run = runReal(key: key, outDir: outDir, pages: pages, mode: mode, style: WritingStyle.named(styleKey)) else { check(false, "\(key) : préparation impossible"); return }
    let totalMs = Int(Date().timeIntervalSince(t0) * 1000)
    let zones = run.zones, result = run.result, doc = run.doc
    let nAnn = result.annotations.values.reduce(0) { $0 + $1.count }
    info("\(zones.count) zones (analyse + écriture : \(totalMs) ms), \(nAnn) annotations, \(result.fields.count) champs remplis, \(result.overflowIDs.count) débordement(s), \(result.skippedIDs.count) ignorée(s)")
    check(result.skippedIDs.isEmpty, "aucune zone ignorée (pages sans rotation)")
    check(result.fontSizes.values.allSatisfy { $0 == $0.rounded() }, "toutes les tailles sont entières")

    // chaque annotation de texte s'affiche en une ligne, entière
    var problems: [String] = []
    var inspected = 0
    for z in zones {
        guard let page = doc.page(at: z.page) else { continue }
        for a in result.annotations[z.id] ?? [] {
            inspected += 1
            if let p = annotationInkProblem(a, page: page) { problems.append("p\(z.page + 1) #\(z.number) : \(p)") }
        }
    }
    check(problems.isEmpty, "\(inspected) annotations de texte : toutes lisibles en entier sur une ligne" + (problems.isEmpty ? "" : " — \(problems.count) problème(s)"))
    problems.prefix(8).forEach { info("   " + $0) }

    // champs de formulaire : valeur relue + dernier mot lisible à l'écran (OCR)
    if !result.fields.isEmpty {
        let w = widgetProblems(doc: doc, zones: zones, result: result)
        check(w.problems.isEmpty, "\(w.checked) champs de formulaire : le dernier mot de chaque valeur se lit à l'écran (OCR)" + (w.problems.isEmpty ? "" : " — \(w.problems.count) problème(s)"))
        w.problems.prefix(8).forEach { info("   " + $0) }
    }

    if dump {
        for z in zones {
            let size = result.fontSizes[z.id].map { String(format: "%.0f", Double($0)) } ?? "-"
            info(String(format: "p%d #%d %@/%@ %@ taille=%@ annots=%d réponse=%d car.%@", z.page + 1, z.number, z.source.rawValue, z.kind.rawValue,
                         z.box != nil ? "cadre" : "\(z.lines.count) ligne(s)", size, result.annotations[z.id]?.count ?? 0, z.answer.count, result.overflowIDs.contains(z.id) ? " DEBORDE" : ""))
        }
    }
    let touched = Set(zones.map { $0.page })
    let stem = (key as NSString).lastPathComponent.replacingOccurrences(of: ".pdf", with: "")
    for p in touched.sorted() {
        guard let page = doc.page(at: p) else { continue }
        if sheets {
            let pz = zones.filter { $0.page == p && result.fontSizes[$0.id] != nil }
            var k = 0
            while k < pz.count {
                contactSheet(page: page, zones: Array(pz[k..<min(k + 7, pz.count)]), result: result, ppp: 3,
                             to: String(format: "%@/%@_%@_%@_p%02d_zones%d.png", outDir, stem, mode, styleKey, p + 1, k / 7 + 1))
                k += 7
            }
        }
        writePNG(renderPage(page, ppp: ppp).0, to: String(format: "%@/%@_%@_%@_p%02d.png", outDir, stem, mode, styleKey, p + 1))
    }
}

// MARK: - Effacer puis réécrire : pas de doublons, état d'origine rétabli

func fingerprint(_ doc: PDFDocument) -> String {
    var parts: [String] = []
    for i in 0..<doc.pageCount {
        let page = doc.page(at: i)!
        var freeText = 0
        for a in page.annotations {
            if (a.type ?? "") == "FreeText" { freeText += 1 }
            else if (a.type ?? "") == "Widget", a.widgetFieldType == .text {
                parts.append("p\(i)|\(a.fieldName ?? "")|\(a.widgetStringValue ?? "∅")|\(a.font?.fontName ?? "")|\(a.font?.pointSize ?? 0)|\(a.maximumLength)|\(a.fontColor?.description ?? "")")
            }
        }
        parts.append("p\(i)|freetext=\(freeText)|total=\(page.annotations.count)")
    }
    return parts.joined(separator: "\n")
}

func scenarioCycle(key: String, outDir: String, pages: [Int]? = nil) {
    guard path(forKey: key) != nil else { print("  [ignoré] cours absent du Mac : \(key)"); return }
    section("\(key) — apply, remove, apply")
    guard let (blank, zones) = analyzedZones(key: key, outDir: outDir, name: key + "_cycle", pages: pages, mode: "fit") else { if path(forKey: key) == nil { print("  [ignoré] cours absent du Mac : \(key)") } else { check(false, "préparation impossible") }; return }
    let doc = PDFDocument(url: blank)!
    let pagesWithZones = Set(zones.map { $0.page }).sorted()
    let before = fingerprint(doc)
    let ppp: CGFloat = 1.5
    let imgBefore = pagesWithZones.map { renderPage(doc.page(at: $0)!, ppp: ppp).0 }

    let r1 = AnswerRenderer.apply(zones: zones, to: doc, style: .bleuImprime)
    let after1 = fingerprint(doc)
    let img1 = pagesWithZones.map { renderPage(doc.page(at: $0)!, ppp: ppp).0 }
    check(after1 != before, "apply modifie le document (\(r1.annotations.values.reduce(0) { $0 + $1.count }) annotations, \(r1.fields.count) champs)")
    check(zip(imgBefore, img1).contains { pixelDifference($0, $1) > 0 }, "apply change bien le rendu des pages")

    AnswerRenderer.remove(r1, from: doc)
    let removed = fingerprint(doc)
    check(removed == before, "remove rétablit exactement l'état d'origine (annotations, valeurs, polices et limites des champs)")
    if removed != before {
        let a = Set(before.split(separator: "\n")), b = Set(removed.split(separator: "\n"))
        for l in a.symmetricDifference(b).sorted().prefix(4) { info("   différence : " + l.prefix(110)) }
    }
    let imgRemoved = pagesWithZones.map { renderPage(doc.page(at: $0)!, ppp: ppp).0 }
    let worst = zip(imgBefore, imgRemoved).map { blockDifference($0, $1) }.max() ?? 0
    check(worst == 0, String(format: "remove : les pages se rendent comme avant (blocs différents au pire : %.3f %%)", worst * 100))

    let r2 = AnswerRenderer.apply(zones: zones, to: doc, style: .bleuImprime)
    let after2 = fingerprint(doc)
    check(after2 == after1, "remove puis apply donne le même état qu'un seul apply (pas de doublons)")
    let img2 = pagesWithZones.map { renderPage(doc.page(at: $0)!, ppp: ppp).0 }
    check(zip(img1, img2).allSatisfy { blockDifference($0, $1) == 0 }, "remove puis apply : rendu identique à celui du premier apply")
    check(r2.annotations.values.reduce(0) { $0 + $1.count } == r1.annotations.values.reduce(0) { $0 + $1.count } && r2.overflowIDs == r1.overflowIDs,
          "mêmes annotations et mêmes débordements au second passage")

    // changement de réponse : on retire, on réécrit avec un autre texte et un autre style
    AnswerRenderer.remove(r2, from: doc)
    var changed = zones
    for i in changed.indices { changed[i].answer = Sample.words[i % Sample.words.count] }
    let r3 = AnswerRenderer.apply(zones: changed, to: doc, style: .manuscrit)
    let count = pagesWithZones.reduce(0) { $0 + doc.page(at: $1)!.annotations.filter { ($0.type ?? "") == "FreeText" }.count }
    check(count == r3.annotations.values.reduce(0) { $0 + $1.count }, "changement de réponse et de style : seules les nouvelles annotations sont présentes (\(count))")
    AnswerRenderer.remove(r3, from: doc)
    check(fingerprint(doc) == before, "après un second remove, le document est de nouveau intact")

    // remove avec le document enregistré puis rouvert : les annotations et les champs sont retrouvés par nom ou par rectangle
    let doc2 = PDFDocument(url: blank)!
    let r4 = AnswerRenderer.apply(zones: zones, to: doc2, style: .bleuImprime)
    let doc3 = copyOf(doc2)
    AnswerRenderer.remove(r4, from: doc3)
    let leftover = (0..<doc3.pageCount).reduce(0) { $0 + doc3.page(at: $1)!.annotations.filter { ($0.userName ?? "") == AnswerRenderer.annotationAuthor }.count }
    check(leftover == 0, "remove sur le document enregistré puis rouvert : plus aucune annotation « \(AnswerRenderer.annotationAuthor) » (\(leftover) restante(s))")
    if !r4.fields.isEmpty {
        let empties = (0..<doc3.pageCount).reduce(0) { total, pageIndex in
            let page = doc3.page(at: pageIndex)!
            let restoredFields = page.annotations.filter { annotation in
                guard (annotation.type ?? "") == "Widget", annotation.widgetFieldType == .text else { return false }
                return r4.fields.values.contains { field in
                    field.pageIndex == pageIndex
                        && abs(field.widget.bounds.minX - annotation.bounds.minX) < 1
                        && abs(field.widget.bounds.minY - annotation.bounds.minY) < 1
                        && (annotation.widgetStringValue ?? "") == (field.previousValue ?? "")
                }
            }
            return total + restoredFields.count
        }
        check(empties >= r4.fields.count, "remove sur le document rouvert : les champs retrouvent leur valeur d'origine (\(empties) / \(r4.fields.count))")
    }
}

// MARK: - Export

func scenarioExport(key: String, outDir: String, pages: [Int]? = nil) {
    section("\(key) — export annoté et aplati")
    guard let (blank, zones) = analyzedZones(key: key, outDir: outDir, name: key + "_export", pages: pages, mode: "fit") else { if path(forKey: key) == nil { print("  [ignoré] cours absent du Mac : \(key)") } else { check(false, "préparation impossible") }; return }
    let style = WritingStyle.bleuImprime

    let live = PDFDocument(url: blank)!
    let result = AnswerRenderer.apply(zones: zones, to: live, style: style)
    let nPages = live.pageCount
    let expectedAnnotations = result.annotations.values.reduce(0) { $0 + $1.count }
    let before = sha(blank)

    for flatten in [false, true] {
        let tag = flatten ? "aplati" : "annote"
        let out = URL(fileURLWithPath: "\(outDir)/\(key)_export_\(tag).pdf")
        try? FileManager.default.removeItem(at: out)
        let t0 = Date()
        do { try AnswerRenderer.export(sourceURL: blank, zones: zones, style: style, flatten: flatten, to: out) }
        catch { check(false, "\(tag) : l'export a échoué : \(error.localizedDescription)"); continue }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        guard let re = PDFDocument(url: out) else { check(false, "\(tag) : le PDF produit ne se rouvre pas"); continue }
        check(re.pageCount == nPages, "\(tag) : le PDF se rouvre avec \(re.pageCount) pages (attendu \(nPages)) — \(ms) ms, \(fileSize(out) / 1024) Ko (copie vierge : \(fileSize(blank) / 1024) Ko)")
        var freeTexts = 0, widgets = 0
        for i in 0..<re.pageCount { for a in re.page(at: i)!.annotations { if (a.type ?? "") == "FreeText" { freeTexts += 1 } else if (a.type ?? "") == "Widget" { widgets += 1 } } }
        if flatten { check(freeTexts == 0 && widgets == 0, "aplati : le texte est intégré aux pages (annotations de texte : \(freeTexts), champs : \(widgets))") }
        else { check(freeTexts >= expectedAnnotations, "annoté : \(freeTexts) annotations de texte (au moins \(expectedAnnotations) attendues)") }
        // rendu comparé à l'aperçu
        var worst = 0.0, worstPage = 0
        for i in Set(zones.map { $0.page }).sorted() {
            let a = renderPage(live.page(at: i)!, ppp: 1.6).0
            let b = renderPage(re.page(at: i)!, ppp: 1.6).0
            let d = blockDifference(a, b)
            if d > worst { worst = d; worstPage = i + 1 }
            if d > 0.002, let di = diffImage(a, b) { writePNG(di, to: "\(outDir)/\(key)_export_\(tag)_diff_p\(i + 1).png") }
        }
        check(worst < 0.003, String(format: "%@ : rendu identique à l'aperçu (blocs différents au pire : %.3f %% à la page %d)", tag, worst * 100, worstPage))
        if let p = Set(zones.map { $0.page }).sorted().first { writePNG(renderPage(re.page(at: p)!, ppp: 2.0).0, to: "\(outDir)/\(key)_export_\(tag)_p\(p + 1).png") }
        // les valeurs de champs restent lisibles dans le fichier (OCR)
        if !result.fields.isEmpty, let z = zones.first(where: { result.fields[$0.id] != nil && (result.fontSizes[$0.id] ?? 0) >= 9 }), let page = re.page(at: z.page) {
            let w = result.fields[z.id]!.widget
            let expected = (w.widgetStringValue ?? "").split(separator: " ").last.map(String.init) ?? ""
            if let img = snapshot(page, rect: w.bounds.insetBy(dx: -1, dy: -1), ppp: 6) {
                check(ocrContains(ocrText(img), word: expected), "\(tag) : la valeur du champ p\(z.page + 1) #\(z.number) se lit dans le fichier relu (dernier mot « \(expected) »)")
            }
        }
    }
    check(sha(blank) == before, "le fichier d'origine n'a pas été modifié")

    // protections : jamais écraser l'original, dossier inexistant, PDF d'origine absent
    do { try AnswerRenderer.export(sourceURL: blank, zones: zones, style: style, flatten: false, to: blank); check(false, "écraser l'original aurait dû être refusé") }
    catch { check(sha(blank) == before, "écraser l'original est refusé (« \(error.localizedDescription.prefix(60))… »), fichier intact") }
    do { try AnswerRenderer.export(sourceURL: blank, zones: zones, style: style, flatten: false, to: URL(fileURLWithPath: outDir + "/nexiste/pas/x.pdf")); check(false, "un dossier inexistant aurait dû produire une erreur") }
    catch { check(true, "dossier de destination inexistant : erreur claire (« \(error.localizedDescription.prefix(70))… »)") }
    do { try AnswerRenderer.export(sourceURL: URL(fileURLWithPath: outDir + "/absent.pdf"), zones: zones, style: style, flatten: false, to: URL(fileURLWithPath: outDir + "/sortie.pdf")); check(false, "un PDF d'origine absent aurait dû produire une erreur") }
    catch { check(true, "PDF d'origine absent : erreur claire (« \(error.localizedDescription.prefix(70))… »)") }
}

// MARK: - Programme

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? { if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }; return nil }
func positional(_ n: Int) -> String? {
    var out: [String] = []
    var skip = false
    for a in args.dropFirst() {
        if skip { skip = false; continue }
        if ["--mode", "--style", "--ppp"].contains(a) { skip = true; continue }
        if a.hasPrefix("--") { continue }
        out.append(a)
    }
    return n < out.count ? out[n] : nil
}

let command = args.first ?? "all"
func makeDir(_ p: String) -> String { try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true); return p }
let defaultOut = NSTemporaryDirectory() + "renderer-test"

switch command {
case "list":
    realFiles.forEach { print($0.key, "→", $0.path) }
case "calage":
    scenarioCalage(outDir: makeDir(positional(0) ?? defaultOut))
case "synthetic":
    let out = makeDir(positional(0) ?? defaultOut)
    scenarioCalage(outDir: out); scenarioSlant(outDir: out); scenarioOrigin(outDir: out); scenarioFonts(outDir: out); scenarioEdgeCases(outDir: out)
case "real":
    guard let key = positional(0), let dir = positional(1) else { print("usage : real <clé|fichier.pdf> <dossier> [pages]"); exit(2) }
    var pages: [Int]? = nil
    if let p = positional(2) { pages = p.split(separator: ",").compactMap { Int($0) } }
    scenarioReal(key: key, outDir: makeDir(dir), pages: pages, mode: opt("--mode") ?? "fit", styleKey: opt("--style") ?? "bleu",
                 sheets: args.contains("--sheets"), dump: args.contains("--dump"), ppp: opt("--ppp").flatMap { Double($0) }.map { CGFloat($0) } ?? 2.1)
case "cycle":
    let out = makeDir(positional(0) ?? defaultOut)
    for k in ["portail", "safran", "stats"] { scenarioCycle(key: k, outDir: out) }
case "exports":
    let out = makeDir(positional(0) ?? defaultOut)
    scenarioExport(key: "portail", outDir: out, pages: [2, 3, 4]); scenarioExport(key: "safran", outDir: out, pages: [2, 3]); scenarioExport(key: "fakenews", outDir: out, pages: [1, 3])
default:     // all
    let out = makeDir(positional(0) ?? defaultOut)
    scenarioCalage(outDir: out); scenarioSlant(outDir: out); scenarioOrigin(outDir: out); scenarioFonts(outDir: out); scenarioEdgeCases(outDir: out)
    for (key, _) in realFiles { scenarioReal(key: key, outDir: makeDir(out + "/" + key), pages: key == "atelier" ? [1, 3, 4, 6] : nil, mode: "fit", styleKey: "bleu", sheets: true, dump: false) }
    scenarioReal(key: "safran", outDir: out + "/safran", pages: nil, mode: "kind", styleKey: "manuscrit", sheets: true, dump: false)
    scenarioReal(key: "portail", outDir: out + "/portail", pages: [2, 3, 4, 5], mode: "long", styleKey: "noir", sheets: true, dump: false)
    for k in ["portail", "safran", "stats"] { scenarioCycle(key: k, outDir: out) }
    scenarioExport(key: "portail", outDir: out, pages: [2, 3, 4]); scenarioExport(key: "safran", outDir: out, pages: [2, 3]); scenarioExport(key: "fakenews", outDir: out, pages: [1, 3])
}
print("\n\(checks - failures) / \(checks) contrôles réussis" + (failures == 0 ? "" : " — \(failures) ÉCHEC(S)"))
exit(failures == 0 ? 0 : 1)
