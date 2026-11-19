import Foundation
import PDFKit
import AppKit
import CoreText

// Outil de test en ligne de commande.
//   harness zones fichier.pdf dossier_sortie [pages: 1,2,3] [--ocr] [--blank]
//       écrit une image annotée par page et liste les zones trouvées (vérification visuelle).
//   harness run entrée.pdf sortie.pdf [--engine apple|claude] [--claude-url URL] [--claude-model ID]
//                [--no-humanize] [--no-flatten] [--style bleu|noir|manuscrit] [--blank] [--png dossier]
//       chaîne complète : détection -> IA -> humanisation -> écriture dans le PDF.
//       La clé Claude vient de la variable d'environnement CC_API_KEY (jamais d'un argument).
// --blank retire les annotations FreeText (anciennes réponses) pour simuler la feuille vierge.

func drawOverlay(page: PDFPage, analysis: PageAnalysis, out: URL) {
    guard let (img, geo) = PageImaging.render(page: page, longEdge: 1400) else { return }
    let w = img.width, h = img.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setLineWidth(2)
    for z in analysis.zones {
        let color: CGColor
        switch z.source {
        case .formulaire: color = CGColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        case .texte: color = CGColor(red: 0.8, green: 0, blue: 0.8, alpha: 1)
        case .ligne: color = CGColor(red: 0, green: 0.65, blue: 0.1, alpha: 1)
        case .cadre: color = CGColor(red: 0, green: 0.3, blue: 1, alpha: 1)
        case .manuel: color = .black
        }
        ctx.setStrokeColor(color)
        ctx.setFillColor(color.copy(alpha: 0.14)!)
        var labelPoint = CGPoint.zero
        if let b = z.box {
            var r = geo.toImage(rect: b)
            r.origin.y = CGFloat(h) - r.origin.y - r.height   // bitmap context: origine en bas
            ctx.fill(r); ctx.stroke(r)
            labelPoint = CGPoint(x: r.minX, y: r.maxY + 2)
        } else {
            for (i, l) in z.lines.enumerated() {
                let p0 = geo.toImage(CGPoint(x: l.x0, y: l.y))
                let p1 = geo.toImage(CGPoint(x: l.x1, y: l.yEnd))
                let hpx = z.textHeight * geo.scale * 1.2
                let H = CGFloat(h)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: p0.x, y: H - p0.y))
                path.addLine(to: CGPoint(x: p1.x, y: H - p1.y))
                path.addLine(to: CGPoint(x: p1.x, y: H - p1.y + hpx))
                path.addLine(to: CGPoint(x: p0.x, y: H - p0.y + hpx))
                path.closeSubpath()
                ctx.addPath(path); ctx.fillPath()
                ctx.addPath(path); ctx.strokePath()
                if i == 0 { labelPoint = CGPoint(x: p0.x, y: H - p0.y + hpx + 2) }
            }
        }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 15, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.red]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(z.number)", attributes: attrs))
        ctx.textPosition = labelPoint
        CTLineDraw(line, ctx)
    }
    if let cg = ctx.makeImage(), let png = PageImaging.pngData(cg) { try? png.write(to: out) }
}

func blankDocument(_ doc: PDFDocument) {
    for i in 0..<doc.pageCount {
        guard let p = doc.page(at: i) else { continue }
        for a in p.annotations where (a.type ?? "") == "FreeText" { p.removeAnnotation(a) }
    }
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = Array(CommandLine.arguments.dropFirst())

if args.count >= 3, args[0] == "zones" {
    let doc = PDFDocument(url: URL(fileURLWithPath: args[1]))!
    let outDir = URL(fileURLWithPath: args[2])
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var pages = Array(0..<doc.pageCount)
    if args.count >= 4, !args[3].hasPrefix("--") { pages = args[3].split(separator: ",").compactMap { Int($0) }.map { $0 - 1 } }
    let ocr = args.contains("--ocr")
    if args.contains("--blank") { blankDocument(doc) }
    var nextID = 1
    for p in pages where p >= 0 && p < doc.pageCount {
        guard let page = doc.page(at: p) else { continue }
        let t0 = Date()
        let a = ZoneDetector.analyze(page: page, index: p, firstID: nextID, needText: ocr)
        nextID += a.zones.count
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("=== page \(p + 1) : \(a.zones.count) zone(s), texte=\(a.hasTextLayer), rotation=\(page.rotation) [\(ms) ms]")
        if a.rotationUnsupported { print("   (page tournée : non gérée)") }
        for z in a.zones {
            let r = z.rect
            print(String(format: "  #%d %@ %@ x=%.0f y=%.0f w=%.0f h=%.0f lignes=%d  cap=%d  avant=«%@»  apres=«%@»",
                         z.number, z.source.rawValue, z.kind.rawValue, r.minX, r.minY, r.width, r.height, z.lines.count, z.capacity,
                         String(z.contextBefore.suffix(70)).replacingOccurrences(of: "\n", with: " ⏎ "),
                         String(z.contextAfter.prefix(40)).replacingOccurrences(of: "\n", with: " ⏎ ")))
        }
        drawOverlay(page: page, analysis: a, out: outDir.appendingPathComponent(String(format: "p%02d.png", p + 1)))
    }
} else if args.count >= 3, args[0] == "run" {
    let inURL = URL(fileURLWithPath: args[1])
    let outURL = URL(fileURLWithPath: args[2])
    var sourceURL = inURL
    if args.contains("--blank") {
        guard let doc = PDFDocument(url: inURL) else { print("PDF illisible"); exit(1) }
        blankDocument(doc)
        sourceURL = outURL.deletingLastPathComponent().appendingPathComponent("_entree_vierge.pdf")
        doc.write(to: sourceURL)
    }

    let engine: CompletionEngine
    switch option("--engine", in: args) ?? "apple" {
    case "claude":
        let key = ProcessInfo.processInfo.environment["CC_API_KEY"] ?? ""
        let url = option("--claude-url", in: args).flatMap { URL(string: $0) } ?? ClaudeEngine.defaultBaseURL
        engine = ClaudeEngine(apiKey: key, model: option("--claude-model", in: args) ?? ClaudeEngine.defaultModel, baseURL: url)
    default:
        if let why = AppleEngine.unavailabilityReason() { print("Apple Intelligence indisponible : \(why)"); exit(2) }
        engine = AppleEngine()
    }
    let humanize = !args.contains("--no-humanize")
    let flatten = !args.contains("--no-flatten")
    let style = WritingStyle.named(option("--style", in: args) ?? "bleu")

    let t0 = Date()
    let analyses = CoursPipeline.analyze(url: sourceURL, needText: !engine.usesImages) { f, msg in
        if f == 1 { print("[analyse] \(msg)") }
    }
    let zones0 = analyses.flatMap { $0.zones }
    print("[analyse] \(zones0.count) zone(s) sur \(analyses.count) page(s) en \(Int(Date().timeIntervalSince(t0))) s")

    do {
        var lastMessage = ""
        let zones = try await CoursPipeline.complete(
            url: sourceURL, documentName: inURL.deletingPathExtension().lastPathComponent, analyses: analyses,
            zones: zones0, engine: engine, settings: CompletionSettings(humanize: humanize, student: StudentProfile())
        ) { _, fraction, message in
            if message != lastMessage { lastMessage = message; print(String(format: "[%3.0f%%] %@", fraction * 100, message)) }
        }
        print("\n=== RÉSULTAT (\(engine.displayName)) en \(Int(Date().timeIntervalSince(t0))) s")
        for z in zones {
            let flag = !z.enabled ? "ignorée" : (z.humanized ? "humanisée" : "brute")
            print("p\(z.page + 1) ⟦\(z.number)⟧ [\(z.kind.rawValue), \(flag)] \(z.rawAnswer.isEmpty ? "—" : "« \(z.rawAnswer) »")")
            if z.humanized { print("        → « \(z.answer) »") }
            if let e = z.error { print("        ! \(e)") }
        }
        try AnswerRenderer.export(sourceURL: sourceURL, zones: zones, style: style, flatten: flatten, to: outURL)
        print("\nPDF écrit : \(outURL.path)")
        if let dir = option("--png", in: args), let doc = PDFDocument(url: outURL) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i), let (img, _) = PageImaging.render(page: page, longEdge: 1500), let png = PageImaging.pngData(img) {
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "p%02d.png", i + 1)))
                }
            }
            print("Images : \(dir)")
        }
    } catch {
        print("ERREUR : \(error.localizedDescription)")
        exit(1)
    }
} else {
    print("usage : harness zones <pdf> <dossier> [pages] [--ocr] [--blank]\n        harness run <entrée.pdf> <sortie.pdf> [--engine apple|claude] [--claude-url URL] [--no-humanize] [--no-flatten] [--style bleu|noir|manuscrit] [--blank] [--png dossier]")
    exit(1)
}
