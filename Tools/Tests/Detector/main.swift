import Foundation
import PDFKit
import AppKit
import CoreText

// Tests du détecteur sur des PDF FABRIQUÉS (aucun cours réel) : pages tournées, filtres de faux trous,
// confiance et signaux. Compilé avec Sources/Core/*.swift (Tools/run_all_tests.sh Detector).

var failures = 0
var checks = 0
func check(_ ok: Bool, _ message: String) {
    checks += 1
    if !ok { failures += 1 }
    print((ok ? "  [ok]     " : "  [ECHEC]  ") + message)
}
func section(_ title: String) { print("\n== \(title) ==") }

// MARK: - Fabrication de pages

let dispW: CGFloat = 595, dispH: CGFloat = 842

/// Page dont le CONTENU s'affiche droit une fois la rotation appliquée : `draw` dessine dans l'espace de la page affichée
/// (origine en bas à gauche, 595 x 842), la transformation inverse de la rotation est appliquée au contexte.
func makePage(rotation: Int, size: CGSize = CGSize(width: dispW, height: dispH), draw: (CGContext) -> Void) -> PDFDocument {
    let data = NSMutableData()
    let swap = rotation % 180 != 0
    var box = CGRect(x: 0, y: 0, width: swap ? size.height : size.width, height: swap ? size.width : size.height)
    let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(box)
    switch rotation {
    case 90:  ctx.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0))
    case 180: ctx.concatenate(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height))
    case 270: ctx.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width))
    default: break
    }
    draw(ctx)
    ctx.endPDFPage(); ctx.closePDF()
    let doc = PDFDocument(data: data as Data)!
    doc.page(at: 0)!.rotation = rotation
    return doc
}

/// Document de plusieurs pages (chacune dessinée par son propre `draw`).
func makeDoc(rotation: Int = 0, pages: [(CGContext) -> Void]) -> PDFDocument {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: dispW, height: dispH)
    let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    for d in pages {
        ctx.beginPDFPage(nil)
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(box)
        d(ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return PDFDocument(data: data as Data)!
}

func text(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat = 11, bold: Bool = false) {
    let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}
func rule(_ ctx: CGContext, x0: CGFloat, x1: CGFloat, y: CGFloat, width: CGFloat = 1, gray: CGFloat = 0) {
    ctx.setStrokeColor(gray: gray, alpha: 1); ctx.setLineWidth(width)
    ctx.move(to: CGPoint(x: x0, y: y)); ctx.addLine(to: CGPoint(x: x1, y: y)); ctx.strokePath()
}
func strokeRect(_ ctx: CGContext, _ r: CGRect, width: CGFloat = 1) {
    ctx.setStrokeColor(gray: 0, alpha: 1); ctx.setLineWidth(width); ctx.stroke(r)
}

func analyze(_ doc: PDFDocument, page: Int = 0, ocr: Bool = false) -> PageAnalysis {
    ZoneDetector.analyze(page: doc.page(at: page)!, index: page, firstID: 1, needText: ocr)
}

// MARK: - Pixels

struct Pix {
    let w: Int, h: Int
    var rgba: [UInt8]
    init(_ img: CGImage) {
        w = img.width; h = img.height
        rgba = [UInt8](repeating: 255, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buf in
            let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }
    func isBlue(_ x: Int, _ y: Int) -> Bool {
        let i = (y * w + x) * 4
        let r = Int(rgba[i]), b = Int(rgba[i + 2])
        return b - r > 60 && b > 90 && r < 170
    }
    func gray(_ x: Int, _ y: Int) -> Int { let i = (y * w + x) * 4; return (Int(rgba[i]) + Int(rgba[i + 1]) + Int(rgba[i + 2])) / 3 }
}

/// Rectangle (espace des zones, points, origine en bas à gauche) qui englobe l'encre bleue de la page affichée.
func blueInk(_ page: PDFPage) -> CGRect? {
    guard let (img, geo) = PageImaging.render(page: page, longEdge: 2400) else { return nil }
    let p = Pix(img)
    var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
    for y in 0..<p.h { for x in 0..<p.w where p.isBlue(x, y) { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
    if maxX < 0 { return nil }
    let z = geo.zoneSpace
    let a = z.toPage(CGPoint(x: CGFloat(minX), y: CGFloat(maxY + 1))), b = z.toPage(CGPoint(x: CGFloat(maxX + 1), y: CGFloat(minY)))
    return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
}

func blockDifference(_ a: CGImage, _ b: CGImage) -> Double {
    guard a.width == b.width, a.height == b.height else { return 1 }
    let pa = Pix(a), pb = Pix(b)
    var diff = 0, total = 0
    var by = 0
    while by + 8 <= pa.h {
        var bx = 0
        while bx + 8 <= pa.w {
            var sa = 0, sb = 0
            for y in by..<by + 8 { for x in bx..<bx + 8 { sa += pa.gray(x, y); sb += pb.gray(x, y) } }
            if abs(sa - sb) / 64 > 24 { diff += 1 }
            total += 1; bx += 8
        }
        by += 8
    }
    return Double(diff) / Double(max(total, 1))
}

// MARK: - Pages tournées

func drawCourse(_ ctx: CGContext) {
    text(ctx, "Fiche de cours : l'énergie électrique", x: 72, y: 780, size: 16, bold: true)
    text(ctx, "Le relais est un interrupteur commandé. Complète les phrases suivantes avec soin.", x: 72, y: 740)
    text(ctx, "1. Un relais sert à .............................................................", x: 72, y: 700)
    text(ctx, "2. Décris le rôle du contact :", x: 72, y: 650)
    rule(ctx, x0: 72, x1: 520, y: 620)
    rule(ctx, x0: 72, x1: 520, y: 592)
    text(ctx, "3. Quelle est la tension de la bobine ?", x: 72, y: 540)
    rule(ctx, x0: 72, x1: 300, y: 505)
    text(ctx, "Fin de la fiche.", x: 72, y: 400)
}

func scenarioRotation() {
    section("Pages tournées : détection, écriture, export")
    let ref = makePage(rotation: 0, draw: drawCourse)
    let refA = analyze(ref)
    check(refA.zones.count >= 3, "page droite de référence : \(refA.zones.count) zones")
    for z in refA.zones { z.rect.isEmpty ? () : () }

    for rot in [90, 180, 270] {
        let doc = makePage(rotation: rot, draw: drawCourse)
        let a = analyze(doc)
        check(!a.rotationUnsupported, "rotation \(rot) : la page est analysée")
        check(a.hasTextLayer, "rotation \(rot) : couche texte lue")
        check(a.zones.count == refA.zones.count, "rotation \(rot) : \(a.zones.count) zones, comme la page droite (\(refA.zones.count))")
        var maxDelta: CGFloat = 0
        for (z, r) in zip(a.zones, refA.zones) {
            maxDelta = max(maxDelta, abs(z.rect.minX - r.rect.minX), abs(z.rect.minY - r.rect.minY), abs(z.rect.width - r.rect.width))
            check(z.source == r.source, "rotation \(rot) zone \(z.number) : même source (\(z.source.rawValue))")
        }
        check(maxDelta < 4, "rotation \(rot) : zones à moins de 4 pt de celles de la page droite (écart max \(String(format: "%.1f", maxDelta)) pt)")
        check(a.transcript == refA.transcript, "rotation \(rot) : même texte avec repères que la page droite")
        check(a.zones.allSatisfy { $0.lines.allSatisfy { abs($0.yEnd - $0.y) < 1 } }, "rotation \(rot) : lignes d'écriture horizontales dans la page affichée")

        // écriture : l'aperçu doit être (presque) identique à celui de la page droite
        var zs = a.zones, zr = refA.zones
        for i in zs.indices { zs[i].answer = "Réponse numéro \(i + 1)"; zs[i].kind = .mot }
        for i in zr.indices { zr[i].answer = "Réponse numéro \(i + 1)"; zr[i].kind = .mot }
        let res = AnswerRenderer.apply(zones: zs, to: doc, style: .bleuImprime)
        let resRef = AnswerRenderer.apply(zones: zr, to: ref, style: .bleuImprime)
        check(res.skippedIDs.isEmpty, "rotation \(rot) : aucune zone ignorée à l'écriture")
        check(res.annotations.values.reduce(0) { $0 + $1.count } == resRef.annotations.values.reduce(0) { $0 + $1.count }, "rotation \(rot) : même nombre d'annotations que la page droite")
        let (img, _) = PageImaging.render(page: doc.page(at: 0)!, longEdge: 1700)!
        let (imgRef, _) = PageImaging.render(page: ref.page(at: 0)!, longEdge: 1700)!
        let diff = blockDifference(img, imgRef)
        check(diff < 0.006, "rotation \(rot) : aperçu quasi identique à la page droite (blocs différents : \(String(format: "%.3f", diff)))")
        if let bi = blueInk(doc.page(at: 0)!), let br = blueInk(ref.page(at: 0)!) {
            check(abs(bi.minX - br.minX) < 2 && abs(bi.minY - br.minY) < 2 && abs(bi.maxX - br.maxX) < 2 && abs(bi.maxY - br.maxY) < 2,
                  "rotation \(rot) : encre bleue au même endroit que sur la page droite")
        } else { check(false, "rotation \(rot) : encre bleue introuvable") }

        // export aplati et non aplati, puis relecture
        let tmp = NSTemporaryDirectory() + "detecteur-rot-\(rot)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let src = URL(fileURLWithPath: tmp + "/source.pdf")
        try? doc.dataRepresentation()?.write(to: src)
        for flatten in [false, true] {
            let out = URL(fileURLWithPath: tmp + "/sortie-\(flatten).pdf")
            do {
                try AnswerRenderer.export(sourceURL: src, zones: zs, style: .bleuImprime, flatten: flatten, to: out)
                if let d = PDFDocument(url: out), let p = d.page(at: 0) {
                    check(p.rotation == rot, "rotation \(rot) export (aplati=\(flatten)) : rotation conservée")
                    if let bi = blueInk(p), let br = blueInk(ref.page(at: 0)!) {
                        check(abs(bi.minX - br.minX) < 2 && abs(bi.maxY - br.maxY) < 2 && abs(bi.width - br.width) < 3,
                              "rotation \(rot) export (aplati=\(flatten)) : texte au bon endroit et droit (\(Int(bi.width)) x \(Int(bi.height)) pt)")
                    } else { check(false, "rotation \(rot) export (aplati=\(flatten)) : encre introuvable") }
                } else { check(false, "rotation \(rot) export : fichier illisible") }
            } catch { check(false, "rotation \(rot) export : \(error.localizedDescription)") }
        }
        // retrait : la page redevient comme avant
        AnswerRenderer.remove(res, from: doc)
        check(doc.page(at: 0)!.annotations.isEmpty, "rotation \(rot) : remove retire les annotations")
    }

    // image repérée (Markers) : numéros aux bons endroits pour une page tournée
    let rdoc = makePage(rotation: 90, draw: drawCourse)
    let ra = analyze(rdoc)
    check(MarkedImage.make(page: rdoc.page(at: 0)!, zones: ra.zones) != nil, "image marquée d'une page tournée produite")
}

/// Rectangle de la page affichée -> espace page (calcul indépendant de PageGeometry : mêmes transformations que `makePage`).
func pageRect(_ r: CGRect, rotation: Int) -> CGRect {
    func map(_ p: CGPoint) -> CGPoint {
        switch rotation {
        case 90:  return CGPoint(x: dispH - p.y, y: p.x)
        case 180: return CGPoint(x: dispW - p.x, y: dispH - p.y)
        case 270: return CGPoint(x: p.y, y: dispW - p.x)
        default:  return p
        }
    }
    let a = map(CGPoint(x: r.minX, y: r.minY)), b = map(CGPoint(x: r.maxX, y: r.maxY))
    return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

func scenarioRotatedFields() {
    section("Pages tournées : champ de formulaire et zone dessinée à la main")
    let fieldRect = CGRect(x: 120, y: 480, width: 200, height: 26)
    for rot in [0, 90, 180, 270] {
        let doc = makePage(rotation: rot) { ctx in
            text(ctx, "Nom de l'entreprise :", x: 72, y: 490)
            text(ctx, "Texte de fin de page pour avoir de quoi lire sur la page entière, suffisamment long pour être lu.", x: 72, y: 300)
            text(ctx, "Encore une ligne de texte courant pour que la couche texte compte plus de soixante caractères.", x: 72, y: 280)
        }
        let w = PDFAnnotation(bounds: pageRect(fieldRect, rotation: rot), forType: .widget, withProperties: nil)
        w.widgetFieldType = .text
        w.fieldName = "nom"
        doc.page(at: 0)!.addAnnotation(w)
        let a = analyze(doc)
        let fz = a.zones.first { $0.source == .formulaire }
        check(fz != nil, "rotation \(rot) : champ de formulaire vide détecté")
        if let fz, let b = fz.box {
            check(abs(b.minX - fieldRect.minX) < 1 && abs(b.minY - fieldRect.minY) < 1 && abs(b.width - fieldRect.width) < 1 && abs(b.height - fieldRect.height) < 1,
                  "rotation \(rot) : cadre du champ dans la page affichée (\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height)))")
            var z = fz; z.answer = "Safran"; z.kind = .mot
            let res = AnswerRenderer.apply(zones: [z], to: doc, style: .bleuImprime)
            check(res.skippedIDs.isEmpty, "rotation \(rot) : réponse du champ écrite")
            if let ink = blueInk(doc.page(at: 0)!) {
                check(fieldRect.insetBy(dx: -2, dy: -2).contains(ink), "rotation \(rot) : écriture à l'intérieur du champ (\(Int(ink.minX)),\(Int(ink.minY)) \(Int(ink.width))x\(Int(ink.height)))")
            } else { check(false, "rotation \(rot) : écriture introuvable") }
        }
        // zone dessinée à la main (espace des zones)
        let m = ZoneDetector.manualZone(page: doc.page(at: 0)!, index: 0, id: 9, number: 9, rect: CGRect(x: 80, y: 200, width: 200, height: 40), useOCR: false)
        check(m.box == CGRect(x: 80, y: 200, width: 200, height: 40) && (m.contextBefore.contains("Encore une ligne") || m.contextBefore.contains("Texte de fin")),
              "rotation \(rot) : zone manuelle avec le texte voisin lu dans la page affichée")
    }
}

// MARK: - Filtres, confiance, signaux

func body(_ ctx: CGContext, extra: String = "") {
    text(ctx, "Le circuit comporte une source, un interrupteur, une lampe et des fils de connexion. \(extra)", x: 72, y: 720)
    text(ctx, "Lorsque l'interrupteur est fermé, le courant circule dans toute la boucle du circuit électrique.", x: 72, y: 700)
}
func zones(_ a: PageAnalysis, _ src: ZoneSource) -> [Zone] { a.zones.filter { $0.source == src } }
func nearY(_ z: Zone, _ y: CGFloat, tol: CGFloat = 8) -> Bool { abs(z.rect.minY - y) <= tol || z.lines.contains { abs($0.y - y) <= tol } }

func scenarioDecor() {
    section("Décor répété et marges (document de 4 pages)")
    // en-tête et pied de page identiques sur les 4 pages ; un vrai trou (ligne de réponse) seulement sur la page 1
    let doc = makeDoc(pages: (0..<4).map { i in { ctx in
        body(ctx)
        rule(ctx, x0: 72, x1: 220, y: 800)                      // trait court d'en-tête
        rule(ctx, x0: 72, x1: 220, y: 44)                       // trait court de pied de page
        if i == 0 {
            text(ctx, "Question 1 : explique le rôle de la lampe.", x: 72, y: 600)
            rule(ctx, x0: 72, x1: 400, y: 570)
        }
    } })
    let p1 = analyze(doc, page: 0), p2 = analyze(doc, page: 1)
    check(p1.zones.filter { nearY($0, 800) || nearY($0, 44) }.allSatisfy { $0.confidence < 0.7 }, "traits d'en-tête et de pied de page identiques sur 4 pages : douteux (page 1)")
    check(p2.zones.allSatisfy { $0.confidence < 0.7 }, "page 2 : seul le décor, rien de sûr (\(p2.zones.count))")
    if let hole = p1.zones.first(where: { nearY($0, 570) }) {
        check(hole.confidence >= 0.6, "vrai trou de la page 1 conservé avec une bonne confiance (\(String(format: "%.2f", hole.confidence)))")
        check(!hole.signals.isEmpty, "le vrai trou a des signaux lisibles : \(hole.signals.joined(separator: " ; "))")
    } else { check(false, "vrai trou de la page 1 conservé") }

    // un trait de marge qui n'est PAS répété : gardé mais douteux
    let doc2 = makeDoc(pages: (0..<4).map { i in { ctx in
        body(ctx)
        if i == 0 { rule(ctx, x0: 72, x1: 260, y: 795) }
    } })
    let q = analyze(doc2, page: 0)
    if let z = q.zones.first(where: { nearY($0, 795) }) {
        check(z.confidence <= 0.4, "trait de marge isolé : conservé mais douteux (\(String(format: "%.2f", z.confidence)))")
        check(z.signals.contains { $0.contains("marge") }, "signal « marge » : \(z.signals.joined(separator: " ; "))")
    } else { check(false, "trait de marge isolé conservé (douteux)") }

    // forme identique dans le corps de la page sur toutes les pages : gardée, confiance basse
    let doc3 = makeDoc(pages: (0..<4).map { _ in { ctx in
        body(ctx)
        strokeRect(ctx, CGRect(x: 380, y: 300, width: 120, height: 60))
    } })
    let c = analyze(doc3, page: 1)
    if let z = zones(c, .cadre).first {
        check(z.confidence <= 0.4 && z.signals.contains { $0.contains("pages") }, "cadre identique sur 4 pages : conservé, confiance basse (\(String(format: "%.2f", z.confidence))) · \(z.signals.joined(separator: " ; "))")
    } else { check(false, "cadre répété conservé") }
    // la même case sur UNE page seulement : confiance normale
    let doc4 = makeDoc(pages: (0..<4).map { i in { ctx in
        body(ctx)
        if i == 0 { strokeRect(ctx, CGRect(x: 380, y: 300, width: 120, height: 60)) }
    } })
    if let z = zones(analyze(doc4, page: 0), .cadre).first {
        check(z.confidence >= 0.5, "même cadre sur une seule page : confiance normale (\(String(format: "%.2f", z.confidence)))")
    } else { check(false, "cadre unique détecté") }
    // document de 2 pages : pas de recherche de décor, mais les marges restent douteuses
    let doc5 = makeDoc(pages: (0..<2).map { _ in { ctx in body(ctx); rule(ctx, x0: 72, x1: 220, y: 800) } })
    if let z = analyze(doc5, page: 0).zones.first(where: { nearY($0, 800) }) {
        check(z.confidence <= 0.4, "document de 2 pages : trait de marge conservé mais douteux")
    } else { check(true, "document de 2 pages : trait de marge écarté") }
}

func scenarioLabels() {
    section("« Libellé : » suivi de texte, de rien, ou d'un schéma")
    let doc = makeDoc(pages: [{ ctx in
        text(ctx, "Fiche signalétique de l'appareil étudié en atelier, à compléter avec soin pendant la séance.", x: 72, y: 780)
        text(ctx, "Nom de l'appareil :", x: 72, y: 700)                                    // vrai champ : rien à droite
        text(ctx, "Observations :", x: 72, y: 600)                                         // suivi de texte courant juste en dessous
        text(ctx, "L'appareil présente une usure normale, aucune trace de choc ni de corrosion visible sur le boîtier.", x: 72, y: 585)
        text(ctx, "Schéma :", x: 72, y: 450)                                               // un schéma occupe la place à droite
        strokeRect(ctx, CGRect(x: 160, y: 400, width: 120, height: 70))
        ctx.setFillColor(gray: 0.2, alpha: 1); ctx.fill(CGRect(x: 200, y: 420, width: 40, height: 30))
        ctx.addEllipse(in: CGRect(x: 300, y: 410, width: 60, height: 50)); ctx.strokePath()
    }])
    let a = analyze(doc)
    let nom = a.zones.first { $0.contextBefore.contains("Nom de l'appareil") || $0.rect.midY > 690 && $0.rect.midY < 715 }
    check(nom != nil && nom!.confidence >= 0.55, "« Nom de l'appareil : » libre à droite : conservé (\(String(format: "%.2f", nom?.confidence ?? 0))) \(nom?.signals.joined(separator: " ; ") ?? "")")
    let obs = a.zones.first { $0.rect.midY > 590 && $0.rect.midY < 615 }
    check(obs != nil && obs!.confidence < 0.6, "« Observations : » suivi d'un paragraphe : douteux (\(String(format: "%.2f", obs?.confidence ?? 0))) \(obs?.signals.joined(separator: " ; ") ?? "")")
    check(!a.zones.contains { $0.source == .texte && $0.rect.midY > 440 && $0.rect.midY < 470 }, "« Schéma : » suivi d'un dessin : pas de trou texte")

    // la figure est SOUS le libellé (pas à droite) : trou douteux
    let doc2 = makeDoc(pages: [{ ctx in
        text(ctx, "Fiche signalétique de l'appareil étudié en atelier, à compléter avec soin pendant la séance.", x: 72, y: 780)
        text(ctx, "Schéma de câblage :", x: 72, y: 700)
        strokeRect(ctx, CGRect(x: 72, y: 600, width: 300, height: 85))
        for i in 1...5 { rule(ctx, x0: 72, x1: 372, y: 600 + CGFloat(i) * 14) }
        text(ctx, "Nom de l'appareil :", x: 72, y: 500)
    }])
    let b = analyze(doc2)
    let below = b.zones.first { $0.source == .texte && $0.rect.midY > 695 && $0.rect.midY < 715 }
    check(below == nil || below!.confidence < 0.6, "« Schéma de câblage : » avec la figure dessous : écarté ou douteux (\(below.map { String(format: "%.2f", $0.confidence) } ?? "écarté"))")
    let free = b.zones.first { $0.source == .texte && $0.rect.midY > 495 && $0.rect.midY < 520 }
    check(free != nil && free!.confidence >= 0.55, "libellé libre sans rien dessous : confiance normale (\(String(format: "%.2f", free?.confidence ?? 0)))")
}

func scenarioHeadings() {
    section("Soulignés de titres, bords de tableaux, lignes trop courtes")
    let doc = makeDoc(pages: [{ ctx in
        text(ctx, "Chapitre 3 - Le courant électrique", x: 72, y: 780, size: 20, bold: true)
        rule(ctx, x0: 72, x1: 420, y: 774, width: 1.2)                                     // souligné de titre
        body(ctx)
        text(ctx, "Mot souligné dans une phrase", x: 72, y: 660)
        rule(ctx, x0: 72, x1: 200, y: 657, width: 1)                                       // souligné de texte courant
        // tableau 3 x 2 avec du texte dans chaque case : ses bords ne sont pas des trous
        let x0: CGFloat = 72, y0: CGFloat = 500, cw: CGFloat = 150, ch: CGFloat = 30
        for r in 0...3 { rule(ctx, x0: x0, x1: x0 + 3 * cw, y: y0 + CGFloat(r) * ch) }
        for c in 0...3 { ctx.setStrokeColor(gray: 0, alpha: 1); ctx.move(to: CGPoint(x: x0 + CGFloat(c) * cw, y: y0)); ctx.addLine(to: CGPoint(x: x0 + CGFloat(c) * cw, y: y0 + 3 * ch)); ctx.strokePath() }
        for r in 0..<3 { for c in 0..<3 { text(ctx, "Cellule \(r)\(c)", x: x0 + CGFloat(c) * cw + 8, y: y0 + CGFloat(r) * ch + 10) } }
        // lignes : une courte (30 pt), une assez longue (200 pt)
        rule(ctx, x0: 72, x1: 102, y: 350)
        rule(ctx, x0: 72, x1: 272, y: 300)
    }])
    let a = analyze(doc)
    check(!a.zones.contains { nearY($0, 774, tol: 6) }, "souligné d'un gros titre : pas un trou")
    if let z = a.zones.first(where: { nearY($0, 657, tol: 6) }) {
        check(z.confidence <= 0.45, "souligné d'un mot dans une phrase : douteux (\(String(format: "%.2f", z.confidence))) · \(z.signals.joined(separator: " ; "))")
    } else { check(true, "souligné d'un mot dans une phrase : écarté") }
    check(!a.zones.contains { $0.source == .ligne && $0.rect.minY > 480 && $0.rect.minY < 620 }, "bords d'un tableau rempli : aucune ligne à remplir")
    check(!a.zones.contains { nearY($0, 350, tol: 6) }, "trait de 30 pt : trop court pour être un trou")
    if let z = a.zones.first(where: { nearY($0, 300, tol: 6) }) {
        check(z.confidence >= 0.6, "ligne de 200 pt isolée : trou conservé (\(String(format: "%.2f", z.confidence)))")
    } else { check(false, "ligne de 200 pt conservée") }
}

func scenarioConfidenceBasics() {
    section("Confiance et signaux selon la source")
    let doc = makeDoc(pages: [{ ctx in
        body(ctx)
        text(ctx, "Le mot manquant est ..............................................", x: 72, y: 650)
        text(ctx, "Résultat ( )", x: 72, y: 620)
        text(ctx, "Prénom :", x: 72, y: 590)
        strokeRect(ctx, CGRect(x: 72, y: 400, width: 200, height: 60))
        rule(ctx, x0: 72, x1: 300, y: 330)
    }])
    let a = analyze(doc)
    check(a.zones.allSatisfy { $0.confidence >= 0 && $0.confidence <= 1 && !$0.signals.isEmpty }, "chaque zone a une confiance entre 0 et 1 et au moins un signal : \(a.zones.map { "\($0.source.rawValue) \(String(format: "%.2f", $0.confidence))" }.joined(separator: ", "))")
    if let t = a.zones.first(where: { $0.source == .texte && $0.rect.midY > 640 && $0.rect.midY < 670 }) {
        check(t.confidence >= 0.85, "pointillés dans le texte : confiance élevée (\(String(format: "%.2f", t.confidence)))")
    } else { check(false, "pointillés détectés") }
    let br = a.zones.first { $0.source == .texte && $0.rect.midY > 610 && $0.rect.midY < 640 }
    check(br != nil && br!.confidence < 0.85 && br!.confidence >= 0.5, "parenthèses vides : confiance moyenne (\(String(format: "%.2f", br?.confidence ?? 0)))")
    let col = a.zones.first { $0.source == .texte && $0.rect.midY > 580 && $0.rect.midY < 610 }
    check(col != nil && col!.confidence >= 0.55, "« Prénom : » libre : conservé (\(String(format: "%.2f", col?.confidence ?? 0)))")
}

func scenarioFiguresAndShortLines() {
    section("Cadres sur une image, case de tableau, ligne très courte")
    let doc = makeDoc(pages: [{ ctx in
        body(ctx)
        // image de fond (aplat gris moyen) avec un cadre vide posé dessus : décor, pas un trou
        ctx.setFillColor(gray: 0.55, alpha: 1); ctx.fill(CGRect(x: 60, y: 330, width: 300, height: 200))
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 100, y: 400, width: 120, height: 50))
        strokeRect(ctx, CGRect(x: 100, y: 400, width: 120, height: 50))
        // un cadre isolé sur la page blanche : gardé mais douteux (rien n'indique qu'il faut y écrire)
        strokeRect(ctx, CGRect(x: 400, y: 150, width: 130, height: 60))
        // ligne très courte (50 pt) : douteuse
        text(ctx, "Valeur mesurée :", x: 72, y: 260)
        rule(ctx, x0: 200, x1: 250, y: 258)
    }])
    let a = analyze(doc)
    check(!a.zones.contains { $0.source == .cadre && $0.rect.midY > 400 && $0.rect.midY < 450 && $0.rect.midX < 250 }, "cadre posé sur une image : écarté")
    if let c = a.zones.first(where: { $0.source == .cadre && $0.rect.midX > 380 }) {
        check(c.confidence >= 0.5 && c.confidence < 0.6, "cadre isolé : douteux mais conservé (\(String(format: "%.2f", c.confidence)))")
    } else { check(false, "cadre isolé conservé") }
    if let l = a.zones.first(where: { nearY($0, 258, tol: 6) && $0.source != .texte }) {
        check(l.confidence < 0.6 && l.signals.contains { $0.contains("courte") }, "ligne de 50 pt : douteuse (\(String(format: "%.2f", l.confidence))) · \(l.signals.joined(separator: " ; "))")
    } else { check(true, "ligne de 50 pt : écartée") }

    // tableau vide : cases alignées, douteuses
    let grid = makeDoc(pages: [{ ctx in
        body(ctx)
        for r in 0..<3 { for c in 0..<3 { strokeRect(ctx, CGRect(x: 72 + CGFloat(c) * 120, y: 300 + CGFloat(r) * 40, width: 120, height: 40)) } }
    }])
    let g = analyze(grid).zones.filter { $0.source == .cadre }
    check(!g.isEmpty && g.allSatisfy { $0.confidence <= 0.5 && $0.signals.contains { $0.contains("tableau") } }, "cases d'un tableau vide : douteuses, signal « tableau » (\(g.count) cases)")
}

scenarioFiguresAndShortLines()
scenarioRotation()
scenarioRotatedFields()
scenarioDecor()
scenarioLabels()
scenarioHeadings()
scenarioConfidenceBasics()

print("\nBilan : \(checks - failures)/\(checks) contrôles réussis")
exit(failures == 0 ? 0 : 1)
