import Foundation
import AppKit
import PDFKit

// Intégration des zones « Schéma électrique » (Sources/Core/SchemaService, SchemaExemples, AnswerRenderer, Pipeline, CoursModel).
// Aucun réseau : le générateur de schémas et le moteur de texte sont des faux.

var passed = 0, failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passed += 1 } else { failed += 1; print("  ECHEC (ligne \(line)) : \(what)") }
}
func section(_ t: String) { print("== \(t)") }

let sortiePNG = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: sortiePNG, withIntermediateDirectories: true)

// MARK: - Faux moteur de texte : enregistre tout ce qu'il reçoit

final class SpyEngine: CompletionEngine, @unchecked Sendable {
    let displayName = "Faux moteur", usesImages = true, maxConcurrentPages = 1
    private let lock = NSLock()
    private(set) var requests: [PageRequest] = []
    private(set) var humanized: [HumanizeItem] = []
    /// Le moteur « devine » à tort que la zone n°2 est un schéma.
    var answersSchemaKind = false
    func complete(_ r: PageRequest) async throws -> [ZoneAnswer] {
        lock.withLock { requests.append(r) }
        return r.zones.map { ZoneAnswer(number: $0.number, kind: answersSchemaKind ? .schema : .question,
                                        text: "Il est important de noter que la tension est de 230 V, c'est la norme.") }
    }
    func humanize(_ items: [HumanizeItem]) async throws -> [Int: String] {
        lock.withLock { humanized.append(contentsOf: items) }
        return [:]
    }
    var seenNumbers: Set<Int> { lock.withLock { Set(requests.flatMap { $0.zones.map { $0.number } }) } }
}

// MARK: - Fichiers de test

func makePDF(_ url: URL, pages: Int = 1) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    for p in 0..<pages {
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ((p == 0 ? "Schéma de câblage d'un va-et-vient" : "Page \(p + 1) du cours") as NSString)
            .draw(at: NSPoint(x: 60, y: 740), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])
        ("Question : pourquoi faut-il protéger le circuit ?" as NSString)
            .draw(at: NSPoint(x: 60, y: 690), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        ("Complète le schéma de câblage ci-dessous." as NSString)
            .draw(at: NSPoint(x: 60, y: 480), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 1)); ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 60, y: 200, width: 480, height: 260))
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

let cadreSchema = CGRect(x: 60, y: 200, width: 480, height: 260)
let cadreTexte = CGRect(x: 60, y: 600, width: 480, height: 60)

func zoneTexte() -> Zone {
    var z = Zone(id: 1, page: 0, number: 1, source: .manuel)
    z.box = cadreTexte; z.kind = .question; z.contextBefore = "Question : pourquoi faut-il protéger le circuit ?"
    z.confidence = 0.3                       // douteuse : le contrôle facultatif la regarde
    return z
}
func zoneSchema(id: Int = 2, number: Int = 2) -> Zone {
    var z = Zone(id: id, page: 0, number: number, source: .manuel)
    z.box = cadreSchema; z.kind = .schema; z.confidence = 0.3
    z.contextBefore = "Complète le schéma de câblage ci-dessous."
    return z
}

func faussSchema() -> SchemaElectrique {
    SchemaElectrique(largeurGrille: 480.0 / 260.0 * 12, hauteurGrille: 12,
                     symboles: [SchemaSymbole(id: "Q1", type: .disjoncteur, x: 6, y: 6, label: "Q1"),
                                SchemaSymbole(id: "H1", type: .lampe, x: 14, y: 6, label: "H1"),
                                SchemaSymbole(id: "L1", type: .phase, x: 6, y: 2, label: "L1")],
                     fils: [SchemaFil(de: "L1.a", vers: "Q1.a"), SchemaFil(de: "Q1.b", vers: "H1.a")],
                     textes: [SchemaTexte(texte: "230 V", x: 18, y: 3)], remarque: "Schéma de test.")
}

/// Nombre de pixels « encrés » (non blancs, non gris de cadre) dans `zone` (points page) d'une page rendue à 2 px par point.
func encre(pdf data: Data, dans zone: CGRect) -> Int {
    guard let doc = CGPDFDocument(CGDataProvider(data: data as CFData)!), let page = doc.page(at: 1) else { return -1 }
    let s: CGFloat = 2, W = Int(612 * s), H = Int(792 * s)
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.scaleBy(x: s, y: s)
    ctx.drawPDFPage(page)
    if let image = ctx.makeImage(), let png = PageImaging.pngData(image) {
        try? png.write(to: sortiePNG.appendingPathComponent("page-\(Int(Date().timeIntervalSince1970 * 1000) % 100000).png"))
    }
    let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let bpr = ctx.bytesPerRow
    var n = 0
    let inner = zone.insetBy(dx: 4, dy: 4)                     // sans le cadre gris de la page
    for y in Int(inner.minY * s)..<Int(inner.maxY * s) {
        for x in Int(inner.minX * s)..<Int(inner.maxX * s) {
            let row = H - 1 - y                                 // origine en haut dans le bitmap
            let p = px + row * bpr + x * 4
            let r = Int(p[0]), g = Int(p[1]), b = Int(p[2])
            if r < 200 || g < 200 || b < 200 { n += 1 }
        }
    }
    return n
}

// MARK: - 1. Le type de zone

func testType() {
    section("ZoneKind.schema")
    check(ZoneKind.schema.label == "Schéma électrique", "libellé")
    check(ZoneKind.schema.symbolName == "bolt.horizontal", "icône")
    check(!ZoneKind.schema.isHumanizable, "jamais humanisé")
    check(ZoneKind.allCases.contains(.schema), "présent dans le sélecteur")
    check(ZoneKind(rawValue: "schema") == .schema, "valeur brute")
    check(AnswerCleaner.clean("  ⟦3⟧ **x**  ", kind: .schema) == "  ⟦3⟧ **x**  ", "AnswerCleaner ne touche pas un schéma")
    var z = zoneSchema(); check(!z.isFilled, "zone schéma sans schéma : pas remplie")
    z.schema = faussSchema(); check(z.isFilled, "avec un schéma : remplie")
    let learn = ZoneLearning(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sch-learn-\(getpid())"))
    defer { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("sch-learn-\(getpid())")) }
    check(learn.record(.kind(.schema), for: zoneTexte(), documentName: "Cours") == false, "« schéma » n'est jamais mémorisé")
    check(ZoneLearning.Action(raw: "kind:schema") == nil, "une mémoire « kind:schema » est refusée")
}

// MARK: - 2. Pipeline : aucune demande de texte pour une zone schéma

func testPipeline(url: URL) async {
    section("Pipeline : zones schéma exclues des moteurs de texte")
    let analyses = (try? CoursPipeline.analyzeChecked(url: url, needText: false) { _, _ in }) ?? []
    check(!analyses.isEmpty, "analyse du PDF de test")
    var settings = CompletionSettings(humanize: true, student: StudentProfile(), verifyDoubtfulHoles: true, holeCache: HoleCheckCache())
    settings.userKindZoneIDs = []
    let moteur = SpyEngine()
    let zones = [zoneTexte(), zoneSchema()]
    let final = try? await CoursPipeline.complete(url: url, documentName: "Cours", analyses: analyses, zones: zones, engine: moteur,
                                                   settings: settings, onlyZoneIDs: nil) { _, _, _ in }
    check(final != nil, "la complétion se termine")
    check(!moteur.requests.isEmpty, "le moteur a reçu des demandes (zone de texte)")
    check(moteur.seenNumbers == [1], "complétion + contrôle des trous : seule la zone n°1 est demandée (vu : \(moteur.seenNumbers))")
    check(!moteur.humanized.contains { $0.id == 2 }, "humanisation : la zone schéma n'est pas envoyée")
    check(moteur.requests.allSatisfy { $0.fixedKinds[2] == nil && !$0.zones.contains { $0.kind == .schema } }, "aucune demande ne contient de zone schéma")
    let s = final?.first { $0.id == 2 }
    check(s?.kind == .schema && s?.answer == "" && s?.schema == nil && s?.error == nil, "la zone schéma n'est pas touchée")

    // une régénération ciblée sur la zone schéma n'appelle aucun moteur de texte
    let m2 = SpyEngine()
    _ = try? await CoursPipeline.complete(url: url, documentName: "Cours", analyses: analyses, zones: zones, engine: m2,
                                          settings: settings, onlyZoneIDs: [2]) { _, _, _ in }
    check(m2.requests.isEmpty && m2.humanized.isEmpty, "onlyZoneIDs = [schéma] : aucun appel au moteur de texte")

    // un moteur qui répondrait « schéma » pour une zone de texte ne la transforme pas en schéma
    let m3 = SpyEngine(); m3.answersSchemaKind = true
    var s3 = settings; s3.verifyDoubtfulHoles = false
    let f3 = try? await CoursPipeline.complete(url: url, documentName: "Cours", analyses: analyses, zones: zones, engine: m3,
                                               settings: s3, onlyZoneIDs: nil) { _, _, _ in }
    check(f3?.first { $0.id == 1 }?.kind != .schema, "l'IA ne marque jamais une zone « schéma »")
}

// MARK: - 3. Rendu : apply, remove, export

func testRendu(url: URL, base: URL) throws {
    section("Rendu : annotation, retrait, export")
    var z = zoneSchema(); z.schema = faussSchema()
    guard let doc = PDFDocument(url: url) else { check(false, "ouverture"); return }
    let style = WritingStyle.bleuImprime
    let r = AnswerRenderer.apply(zones: [z], to: doc, style: style)
    let annotations = r.annotations[z.id] ?? []
    check(annotations.count == 1 && annotations[0] is SchemaAnnotation, "apply ajoute une SchemaAnnotation")
    check(doc.page(at: 0)!.annotations.contains { $0 is SchemaAnnotation }, "elle est sur la page")
    check(annotations.first.map { abs($0.bounds.minX - 60) < 0.5 && abs($0.bounds.minY - 200) < 0.5 && abs($0.bounds.width - 480) < 0.5 } == true,
          "dans le rectangle de la zone")
    check(r.touchedPages == [0], "page rafraîchie")
    check((annotations.first as? SchemaAnnotation).map { abs($0.couleur.blueComponent - style.blue) < 0.01 } == true, "encre du style choisi")
    AnswerRenderer.remove(r, from: doc)
    check(!doc.page(at: 0)!.annotations.contains { $0 is SchemaAnnotation }, "remove retire l'annotation")

    // zone sans cadre : ignorée avec un repère
    var sansCadre = z; sansCadre.box = nil
    let r2 = AnswerRenderer.apply(zones: [sansCadre], to: doc, style: style)
    check(r2.annotations.isEmpty && r2.skippedIDs.contains(z.id), "zone schéma sans cadre : non écrite, signalée")
    var desactivee = z; desactivee.enabled = false
    check(AnswerRenderer.apply(zones: [desactivee], to: doc, style: style).annotations.isEmpty, "zone désactivée : rien")
    check(doc.page(at: 0)!.annotations.isEmpty, "rien ne reste sur le document")

    // export aplati : le schéma est visible (encre dans le cadre) ; l'original n'est pas modifié
    let avant = try Data(contentsOf: url)
    let sortieAvec = base.appendingPathComponent("aplati.pdf"), sortieSans = base.appendingPathComponent("sans.pdf")
    try AnswerRenderer.export(sourceURL: url, zones: [z], style: style, flatten: true, to: sortieAvec)
    try AnswerRenderer.export(sourceURL: url, zones: [], style: style, flatten: true, to: sortieSans)
    let inkAvec = encre(pdf: try Data(contentsOf: sortieAvec), dans: cadreSchema)
    let inkSans = encre(pdf: try Data(contentsOf: sortieSans), dans: cadreSchema)
    check(inkAvec - inkSans > 300, "export aplati : le schéma est visible (encre \(inkAvec) contre \(inkSans) sans schéma)")
    check(PDFDocument(url: sortieAvec)?.pageCount == 1, "l'export se rouvre")
    check(PDFDocument(url: sortieAvec)?.page(at: 0)?.annotations.contains { $0 is SchemaAnnotation } == false, "aplati : plus d'annotation de schéma")
    check(try Data(contentsOf: url) == avant, "le PDF d'origine n'est jamais modifié")
    // même chemin d'export sans schéma (texte seul) : inchangé
    let texte = base.appendingPathComponent("texte.pdf")
    var t = zoneTexte(); t.answer = "Pour éviter un incendie."; t.rawAnswer = t.answer
    try AnswerRenderer.export(sourceURL: url, zones: [t], style: style, flatten: true, to: texte)
    check(encre(pdf: try Data(contentsOf: texte), dans: cadreTexte) > 50, "export aplati d'une réponse texte : toujours visible")

    // export demandé « non aplati » avec un schéma : aplati quand même (sinon le schéma serait invisible hors de l'app)
    let garde = base.appendingPathComponent("annote.pdf")
    try AnswerRenderer.export(sourceURL: url, zones: [z], style: style, flatten: false, to: garde)
    let inkGarde = encre(pdf: try Data(contentsOf: garde), dans: cadreSchema)
    check(inkGarde - inkSans > 300, "flatten: false avec un schéma : le schéma reste visible (encre \(inkGarde))")
    // sans schéma, flatten: false garde bien les réponses en annotations
    let texteGarde = base.appendingPathComponent("texte-annote.pdf")
    try AnswerRenderer.export(sourceURL: url, zones: [t], style: style, flatten: false, to: texteGarde)
    check(PDFDocument(url: texteGarde)?.page(at: 0)?.annotations.contains { $0.type == "FreeText" } == true, "sans schéma, flatten: false : annotations de texte conservées")
}

// MARK: - 3 bis. Pages tournées (90, 180, 270)

/// Rend une page affichée (rotation comprise, annotations comprises) à 2 px/point : niveaux de gris, origine en haut à gauche.
func gris(_ image: CGImage) -> (w: Int, h: Int, px: [UInt8]) {
    let w = image.width, h = image.height
    var px = [UInt8](repeating: 255, count: w * h)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, px)
}
func rendreAffichee(_ page: PDFPage) -> (w: Int, h: Int, px: [UInt8])? {
    let b = page.bounds(for: .cropBox), r = ((page.rotation % 360) + 360) % 360
    let d = r % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    guard let cg = page.thumbnail(of: CGSize(width: d.width * 2, height: d.height * 2), for: .cropBox)
        .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return gris(cg)
}
/// Pixels qui diffèrent entre deux rendus : (nombre, boîte englobante en points, origine en haut à gauche).
func difference(_ a: (w: Int, h: Int, px: [UInt8]), _ b: (w: Int, h: Int, px: [UInt8])) -> (n: Int, boite: CGRect, masque: Set<Int>) {
    guard a.w == b.w, a.h == b.h else { return (-1, .zero, []) }
    var n = 0, x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
    var masque = Set<Int>()
    for y in 0..<a.h { for x in 0..<a.w where abs(Int(a.px[y * a.w + x]) - Int(b.px[y * a.w + x])) > 40 {
        n += 1; masque.insert(y * a.w + x); x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
    } }
    return (n, n == 0 ? .zero : CGRect(x: CGFloat(x0) / 2, y: CGFloat(y0) / 2, width: CGFloat(x1 - x0 + 1) / 2, height: CGFloat(y1 - y0 + 1) / 2), masque)
}

func testPagesTournees(url: URL, base: URL) throws {
    section("Pages tournées : schéma dessiné droit dans le cadre (aperçu et export aplati)")
    let schema = faussSchema()
    let style = WritingStyle.bleuImprime
    // référence : le schéma dessiné seul dans un cadre de 480 x 260 pt (2 px/pt), page non tournée
    let refCtx = CGContext(data: nil, width: 960, height: 520, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                           bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    refCtx.setFillColor(gray: 1, alpha: 1); refCtx.fill(CGRect(x: 0, y: 0, width: 960, height: 520))
    refCtx.scaleBy(x: 2, y: 2)
    SchemaRenderer.dessiner(SchemaRenderer.valider(schema), dans: CGRect(x: 0, y: 0, width: 480, height: 260), ctx: refCtx, couleur: CGColor(gray: 0, alpha: 1))
    let ref = gris(refCtx.makeImage()!)
    var refMasque = Set<Int>()
    for y in 0..<ref.h { for x in 0..<ref.w where ref.px[y * ref.w + x] < 215 { refMasque.insert(y * ref.w + x) } }

    var rx0 = Int.max, ry0 = Int.max, rx1 = -1, ry1 = -1
    for i in refMasque { let x = i % ref.w, y = i / ref.w; rx0 = min(rx0, x); rx1 = max(rx1, x); ry0 = min(ry0, y); ry1 = max(ry1, y) }
    let refBoite = CGRect(x: CGFloat(rx0) / 2, y: CGFloat(ry0) / 2, width: CGFloat(rx1 - rx0 + 1) / 2, height: CGFloat(ry1 - ry0 + 1) / 2)
    for rot in [0, 90, 180, 270] {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { check(false, "ouverture"); return }
        page.rotation = rot
        let geo = PageGeometry(page: page)
        let dw = geo.displaySize.width, dh = geo.displaySize.height
        // cadre à l'écran (espace des zones, origine en bas à gauche), 480 x 260 pt, bien à l'intérieur de la page
        let cadre = CGRect(x: 60, y: 150, width: 480, height: 260)
        var z = zoneSchema(); z.box = cadre; z.schema = schema
        let sans = rendreAffichee(page)
        let r = AnswerRenderer.apply(zones: [z], to: doc, style: style)
        let ann = r.annotations[z.id]?.first as? SchemaAnnotation
        check(ann != nil && !r.skippedIDs.contains(z.id), "rot \(rot) : annotation posée (non ignorée)")
        guard let ann, let sans, let avec = rendreAffichee(page) else { check(false, "rot \(rot) : rendu"); continue }
        check(ann.rotationPage == rot, "rot \(rot) : rotation mémorisée")
        check(geo.zoneRect(fromPage: ann.bounds).equalTo(cadre) || (abs(geo.zoneRect(fromPage: ann.bounds).minX - cadre.minX) < 0.5
              && abs(geo.zoneRect(fromPage: ann.bounds).minY - cadre.minY) < 0.5 && abs(geo.zoneRect(fromPage: ann.bounds).width - 480) < 0.5),
              "rot \(rot) : bounds brut = cadre une fois remis à l'écran")
        // aperçu (PDFKit appelle draw(with:in:))
        let d = difference(avec, sans)
        let attendu = CGRect(x: cadre.minX, y: dh - cadre.maxY, width: cadre.width, height: cadre.height)   // origine en haut
        check(d.n > 300, "rot \(rot) : aperçu, le schéma est visible (\(d.n) pixels d'encre)")
        check(attendu.insetBy(dx: -2, dy: -2).contains(d.boite), "rot \(rot) : aperçu, toute l'encre est dans le cadre (boîte \(d.boite), cadre \(attendu))")
        // droit : le dessin recouvre la référence non tournée (même orientation)
        func recouvrement(_ m: Set<Int>, w: Int, ox: Int, oy: Int) -> Double {
            var inter = 0
            for i in refMasque { let x = i % ref.w + ox, y = i / ref.w + oy; if m.contains(y * w + x) { inter += 1 } }
            return Double(inter) / Double(max(1, refMasque.count))
        }
        let ox = Int(attendu.minX * 2), oy = Int(attendu.minY * 2)
        let rec = recouvrement(d.masque, w: avec.w, ox: ox, oy: oy)
        check(rec > 0.85, "rot \(rot) : aperçu, schéma droit (recouvrement avec le dessin de référence \(Int(rec * 100)) %)")

        // convention de PDFView : contexte en espace page BRUT, clip = bounds, la rotation vient de la CTM
        if let data = doc.dataRepresentation(), let cgDoc = CGPDFDocument(CGDataProvider(data: data as CFData)!), let cgPage = cgDoc.page(at: 1) {
            let sortie = CGRect(x: 0, y: 0, width: dw, height: dh)
            let c2 = CGContext(data: nil, width: Int(dw * 2), height: Int(dh * 2), bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            c2.setFillColor(gray: 1, alpha: 1); c2.fill(CGRect(x: 0, y: 0, width: dw * 2, height: dh * 2))
            c2.scaleBy(x: 2, y: 2)
            c2.concatenate(cgPage.getDrawingTransform(.mediaBox, rect: sortie, rotate: 0, preserveAspectRatio: true))
            c2.clip(to: ann.bounds)
            ann.draw(with: .cropBox, in: c2)
            let g2 = gris(c2.makeImage()!)
            let blanc = (w: g2.w, h: g2.h, px: [UInt8](repeating: 255, count: g2.w * g2.h))
            let dv = difference(g2, blanc)
            check(dv.n > 300 && attendu.insetBy(dx: -2, dy: -2).contains(dv.boite), "rot \(rot) : convention PDFView, encre dans le cadre (boîte \(dv.boite))")
            let rv = recouvrement(dv.masque, w: g2.w, ox: ox, oy: oy)
            check(rv > 0.85, "rot \(rot) : convention PDFView, schéma droit (recouvrement \(Int(rv * 100)) %)")
        } else { check(false, "rot \(rot) : lecture PDF") }

        // export aplati : même page, plus de /Rotate, schéma droit dans le même cadre
        let src = base.appendingPathComponent("rot\(rot).pdf"), out = base.appendingPathComponent("rot\(rot)-aplati.pdf")
        let vide = PDFDocument(url: url)!; vide.page(at: 0)!.rotation = rot
        try (vide.dataRepresentation() ?? Data()).write(to: src)
        try AnswerRenderer.export(sourceURL: src, zones: [z], style: style, flatten: true, to: out)
        guard let sortie = PDFDocument(url: out), let sp = sortie.page(at: 0) else { check(false, "rot \(rot) : export lisible"); continue }
        check(sp.rotation == 0 && abs(sp.bounds(for: .mediaBox).width - dw) < 0.5 && abs(sp.bounds(for: .mediaBox).height - dh) < 0.5,
              "rot \(rot) : export, page affichée \(Int(dw)) x \(Int(dh)) sans rotation")
        let sansExport = base.appendingPathComponent("rot\(rot)-sans.pdf")
        try AnswerRenderer.export(sourceURL: src, zones: [], style: style, flatten: true, to: sansExport)
        if let e1 = PDFDocument(url: out)?.page(at: 0), let e0 = PDFDocument(url: sansExport)?.page(at: 0),
           let g1 = rendreAffichee(e1), let g0 = rendreAffichee(e0) {
            let de = difference(g1, g0)
            check(de.n > 300, "rot \(rot) : export aplati, schéma visible (\(de.n) pixels)")
            check(attendu.insetBy(dx: -2, dy: -2).contains(de.boite), "rot \(rot) : export, toute l'encre est dans le cadre (boîte \(de.boite))")
            let rec2 = recouvrement(de.masque, w: g1.w, ox: ox, oy: oy)
            check(rec2 > 0.85, "rot \(rot) : export, schéma droit (recouvrement \(Int(rec2 * 100)) %)")
            // le contenu de la page est resté identique à l'écran (texte non déplacé) : mêmes pixels hors du cadre
            let horsCadre = difference(g0, sans)
            check(horsCadre.n < 4000, "rot \(rot) : export, le reste de la page est inchangé (\(horsCadre.n) px d'écart de lissage)")
        } else { check(false, "rot \(rot) : rendu de l'export") }
    }
}

// MARK: - 4. Magasin d'exemples

func testExemples(url: URL, base: URL) throws {
    section("Magasin d'exemples")
    let dossier = base.appendingPathComponent("schemas-exemples")
    let store = SchemaExemples(dossier: dossier)
    check(store.exemples.isEmpty, "vide au départ")
    let e1 = try store.ajouter(pdf: url, numeroPage: 1, titre: "Va-et-vient – cours chap. 3", note: "le neutre est bleu")
    check(store.exemples.count == 1 && store.jpeg(e1) != nil, "ajout : image enregistrée")
    if let j = store.jpeg(e1), let img = NSBitmapImageRep(data: j) { check(img.pixelsWide >= 1300 && img.pixelsWide <= 1500, "image à ~1400 px de large (\(img.pixelsWide))") }
    check(store.exemples[0].titre == "Va-et-vient – cours chap. 3" && store.exemples[0].note == "le neutre est bleu", "titre et note")
    // relecture depuis le disque
    check(SchemaExemples(dossier: dossier).exemples == store.exemples, "relecture de l'index")
    try store.modifier(e1.id, titre: "Va-et-vient (corrigé)", note: "")
    check(SchemaExemples(dossier: dossier).exemples.first?.titre == "Va-et-vient (corrigé)", "modification du titre persistée")
    // page invalide
    check((try? store.ajouter(pdf: url, numeroPage: 5)) == nil, "numéro de page hors du PDF refusé")
    // limite
    for i in 2...SchemaExemples.maximum { _ = try store.ajouter(pdf: url, numeroPage: 1, titre: "Exemple \(i)") }
    check(store.exemples.count == 12 && store.estPlein, "12 exemples au plus")
    var refuse = false
    do { _ = try store.ajouter(pdf: url, numeroPage: 1, titre: "13e") } catch { refuse = (error.localizedDescription.contains("12")) }
    check(refuse && store.exemples.count == 12, "le 13e est refusé avec un message clair")
    // choix pour une demande : 3 au plus, titre qui ressemble d'abord, sinon les plus récents
    let choisis = store.pourDemande(nomDocument: "Va-et-vient")
    check(choisis.count == 3 && choisis[0].exemple.id == e1.id, "choix : titre ressemblant d'abord (3 au plus)")
    let recents = store.pourDemande(nomDocument: "Autre cours")
    check(recents.count == 3 && recents[0].exemple.titre == "Exemple 12", "sinon les plus récents")
    check(choisis.allSatisfy { !$0.jpeg.isEmpty }, "JPEG lus pour la demande")
    // suppression
    let fichier = store.fichier(e1)
    try store.supprimer(e1.id)
    check(store.exemples.count == 11 && !FileManager.default.fileExists(atPath: fichier.path), "suppression : index et image")
    check(SchemaExemples(dossier: dossier).exemples.count == 11, "suppression persistée")
    _ = try store.ajouter(pdf: url, numeroPage: 1, titre: "Après suppression")
    check(store.exemples.count == 12, "on peut en rajouter un après avoir supprimé")
    // image disparue : l'exemple est écarté à la relecture
    try? FileManager.default.removeItem(at: store.fichier(store.exemples[0]))
    check(SchemaExemples(dossier: dossier).exemples.count == 11, "exemple sans image écarté")
}

// MARK: - 5. Modèle de l'app avec un faux générateur

final class Compteur: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0; private(set) var demandes: [SchemaDemande] = []
    func noter(_ d: SchemaDemande) { lock.withLock { n += 1; demandes.append(d) } }
    var total: Int { lock.withLock { n } }
}

@MainActor
func testModele(url: URL, base: URL) async {
    section("Modèle : « Compléter », « Dessiner le schéma »")
    let defaults = UserDefaults(suiteName: "schema-integration-\(getpid())")!
    defaults.removePersistentDomain(forName: "schema-integration-\(getpid())")
    var settings = RunSettings.current(); settings.engine = .claude; settings.humanize = false
    let snapshot = settings
    let moteur = SpyEngine()
    let compteur = Compteur()
    let magasin = SchemaExemples(dossier: base.appendingPathComponent("exemples-modele"))
    _ = try? magasin.ajouter(pdf: url, numeroPage: 1, titre: "Exemple de test")
    let generateur: SchemaService.Generateur = { d in
        compteur.noter(d)
        if d.numeroZone == 99 { throw SchemaErreur.autre("Réponse illisible (test).") }
        return faussSchema()
    }
    let model = CoursModel(settings: { snapshot }, engineFactory: { _ in moteur }, dialogs: SilentDialogs(), defaults: defaults,
                           learning: ZoneLearning(directory: base.appendingPathComponent("learn")),
                           schemaExemples: magasin, schemaGenerator: generateur)
    await model.load(url)
    check(model.document != nil, "PDF ouvert")
    await model.addManualZone(pageIndex: 0, rect: cadreSchema)
    guard let schemaZone = model.zones.first(where: { $0.source == .manuel && $0.box == cadreSchema }) else { check(false, "zone ajoutée"); return }
    check(schemaZone.kind != .schema, "une zone n'est jamais schéma toute seule (type proposé : \(schemaZone.kind.label))")
    model.setKind(.schema, for: schemaZone.id)
    check(model.zone(schemaZone.id)?.kind == .schema, "l'élève marque la zone « Schéma électrique »")
    check(model.schemaZoneCount == 1 && !model.needsTextEngine || model.needsTextEngine, "compteurs")

    await model.complete(only: [schemaZone.id])
    let faite = model.zone(schemaZone.id)
    check(faite?.schema != nil && faite?.error == nil, "« Dessiner le schéma » : schéma reçu")
    check(compteur.total == 1, "un seul appel au générateur")
    check(moteur.requests.isEmpty, "aucun moteur de texte appelé")
    if let d = compteur.demandes.first {
        check(d.numeroPage == 1 && d.numeroZone == schemaZone.number, "demande : page et zone")
        check(!d.pageJPEG.isEmpty && !d.cadreGrilleJPEG.isEmpty, "demande : page entière et cadre avec grille")
        check(d.exemples.count == 1 && d.exemples[0].exemple.titre == "Exemple de test", "demande : exemples du magasin")
        check(d.consigne.contains("Complète") || d.consigne.contains("Question") || d.consigne.contains("Intitulé"), "demande : consigne (\(d.consigne.prefix(60)))")
        check(abs(d.largeurGrille - SchemaGrille.dimensionsGrille(pour: cadreSchema).largeur) < 0.01, "demande : grille de la zone")
    }
    model.renderAnswers()
    check(model.document?.page(at: 0)?.annotations.contains { $0 is SchemaAnnotation } == true, "le schéma est affiché sur l'aperçu")
    check(model.answeredCount >= 1, "compté parmi les zones remplies")

    // « Compléter » : le texte part au moteur de texte, le schéma à Opus ; jamais mélangés
    await model.complete()
    check(!moteur.seenNumbers.contains(schemaZone.number) || moteur.requests.allSatisfy { !$0.zones.contains { $0.id == schemaZone.id } },
          "Compléter : la zone schéma n'est pas dans les demandes de texte")
    check(compteur.total == 2, "Compléter : le schéma est redessiné une fois (\(compteur.total))")

    // erreur d'une zone : dans Zone.error, le schéma précédent est gardé
    let mauvais = CoursModel(settings: { snapshot }, engineFactory: { _ in moteur }, dialogs: SilentDialogs(), defaults: defaults,
                             learning: ZoneLearning(directory: base.appendingPathComponent("learn2")), schemaExemples: magasin,
                             schemaGenerator: { _ in throw SchemaErreur.autre("Réponse illisible (test).") })
    await mauvais.load(url)
    await mauvais.addManualZone(pageIndex: 0, rect: cadreSchema)
    if let z = mauvais.zones.first(where: { $0.source == .manuel }) {
        mauvais.setKind(.schema, for: z.id)
        await mauvais.complete(only: [z.id])
        check(mauvais.zone(z.id)?.error?.contains("illisible") == true && mauvais.zone(z.id)?.schema == nil, "erreur de zone : dans Zone.error")
        check(mauvais.runProblem == nil, "une erreur de zone n'arrête pas le traitement")
    }

    // sans accès (ni clé ni compte) : message clair, aucun repli
    let sansAcces = CoursModel(settings: { snapshot }, engineFactory: { _ in moteur }, dialogs: SilentDialogs(), defaults: defaults,
                               learning: ZoneLearning(directory: base.appendingPathComponent("learn3")), schemaExemples: magasin,
                               schemaGenerator: { _ in throw SchemaErreur.indisponible(SchemaEngine.messageIndisponible) })
    await sansAcces.load(url)
    await sansAcces.addManualZone(pageIndex: 0, rect: cadreSchema)
    if let z = sansAcces.zones.first(where: { $0.source == .manuel }) {
        sansAcces.setKind(.schema, for: z.id)
        await sansAcces.complete(only: [z.id])
        check(sansAcces.runProblem?.needsSettings == true && sansAcces.runProblem?.message.contains("Opus 5.5") == true,
              "pas d'accès : message « Opus 5.5 uniquement », ouvre les Réglages")
    }

    // zone sans cadre : message clair
    var sansCadre = zoneSchema(); sansCadre.box = nil
    let demande = try? SchemaService.construireDemande(document: PDFDocument(url: url)!, zone: sansCadre, pageZones: [], nomDocument: "x", exemples: [])
    check(demande == nil, "zone schéma sans cadre : pas de demande")
    do { _ = try SchemaService.construireDemande(document: PDFDocument(url: url)!, zone: sansCadre, pageZones: [], nomDocument: "x", exemples: []) }
    catch { check(error.localizedDescription.contains("cadre"), "message « dessine un cadre »") }

    // page ouverte comme exemple
    let avant = magasin.exemples.count
    model.addCurrentPageAsSchemaExample()
    check(magasin.exemples.count == min(avant + 1, 12) || magasin.estPlein, "« Prendre cette page comme exemple »")
}

// MARK: - 6. Annulation du service

func testAnnulation(url: URL) async {
    section("Service : annulation")
    var zones = [zoneSchema(id: 2, number: 2), zoneSchema(id: 3, number: 3)]
    zones[1].box = CGRect(x: 60, y: 480, width: 300, height: 150)
    let t = Task { () -> Bool in
        do {
            _ = try await SchemaService.dessiner(url: url, documentName: "Cours", zones: zones, ids: [2, 3], exemples: [],
                                                 generateur: { _ in try await Task.sleep(nanoseconds: 3_000_000_000); return faussSchema() }) { _, _, _ in }
            return false
        } catch is CancellationError { return true } catch { return false }
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    t.cancel()
    check(await t.value, "annulable : CancellationError")
}

// MARK: - Programme

@MainActor
func runAll() async {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("schema-integration-\(getpid())")
    try? fm.removeItem(at: base)
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let pdf = base.appendingPathComponent("cours.pdf")
    makePDF(pdf)
    testType()
    await testPipeline(url: pdf)
    do { try testRendu(url: pdf, base: base) } catch { check(false, "rendu : \(error)") }
    do { try testPagesTournees(url: pdf, base: base) } catch { check(false, "pages tournées : \(error)") }
    do { try testExemples(url: pdf, base: base) } catch { check(false, "exemples : \(error)") }
    await testModele(url: pdf, base: base)
    await testAnnulation(url: pdf)
}

_ = NSApplication.shared
Task { @MainActor in
    await runAll()
    print("\nRésultat : \(passed) réussis, \(failed) échec(s)")
    exit(failed == 0 ? 0 : 1)
}
dispatchMain()
