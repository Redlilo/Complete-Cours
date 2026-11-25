import Foundation
import PDFKit
import AppKit
import CryptoKit

// BANC D'ESSAI DE LA DÉTECTION DES TROUS — LECTURE SEULE sur ~/Desktop/Cours, sans réseau, sans moteur IA.
//   detection_test <dossier de sortie> [dossier des cours] [--seul texte] [--sans texte]... [--top N] [--sans-png] [--synthetique]
// Ce que le programme fait :
//   1. rassemble un jeu de référence à partir des PDF réels (jamais d'évaluation) :
//        - « paires » : original vide (rangé dans « _Originaux avant completion » ou à côté) <-> version complétée ;
//          vérité = encre ajoutée (PageDiff.addedInk) en dehors de ce qui était déjà sur l'original vide ;
//        - « annotations » : annotations FreeText et champs de formulaire remplis A LA MAIN par l'élève (auteur autre que
//          « CompleteCours ») : vérité INDÉPENDANTE du détecteur, car l'élève les a placées lui-même.
//      La copie de travail (annotations de l'élève retirées) est écrite dans <sortie>/vierge/ ; rien n'est écrit ailleurs.
//   2. lance la VRAIE chaîne d'analyse de l'app (CoursPipeline.analyzeChecked) sur cette copie vierge ;
//   3. compare zones détectées et vérité : trous manqués, zones sans réponse, précision et rappel par source.
//   4. rejoue les 14 lignes synthétiques de Tools/Tests/Text (6 trous attendus) pour garder un repère sans données de l'élève.
// Biais à connaître : l'encre d'une version complétée par l'app vient de zones que le détecteur avait déjà trouvées
// (vérité « appli » = surtout la précision) ; le rappel crédible est celui de la vérité « élève » (placée à la main).

// MARK: Options

var outDir = URL(fileURLWithPath: "build/detection")
var coursDir = ("~/Desktop/Cours" as NSString).expandingTildeInPath
var only = "", topN = 12, withPNG = true, syntheticOnly = false
var excluded: [String] = []
do {
    var args = Array(CommandLine.arguments.dropFirst()), pos: [String] = []
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--seul": only = args.isEmpty ? "" : args.removeFirst()
        case "--sans": if !args.isEmpty { excluded.append(args.removeFirst()) }
        case "--top": topN = Int(args.isEmpty ? "" : args.removeFirst()) ?? topN
        case "--sans-png": withPNG = false
        case "--synthetique": syntheticOnly = true
        default: pos.append(a)
        }
    }
    if pos.count > 0 { outDir = URL(fileURLWithPath: pos[0]) }
    if pos.count > 1 { coursDir = (pos[1] as NSString).expandingTildeInPath }
}
let fm = FileManager.default
try? fm.createDirectory(at: outDir.appendingPathComponent("vierge"), withIntermediateDirectories: true)
try? fm.createDirectory(at: outDir.appendingPathComponent("png"), withIntermediateDirectories: true)
func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// MARK: Vocabulaire commun

enum Origin: String { case eleve = "élève", appli = "appli" }
enum Tier: Int { case aucune = 0, desactivee, douteuse, sure     // meilleure zone qui recouvre un trou
    var label: String { ["aucune zone", "zone désactivée", "zone douteuse (<0,7)", "zone sûre"][rawValue] }
}

/// Une zone détectée, rangée dans une catégorie de source plus fine que `ZoneSource` (pixels, OCR…).
func bucket(_ z: Zone) -> String {
    let s = z.signals.first ?? ""
    switch z.source {
    case .formulaire: return "formulaire"
    case .texte: return s.contains("pointillés") ? "texte : pointillés" : (s.contains("libellé") ? "texte : « libellé : »" : "texte : ( ) [ ]")
    case .ligne: return s.contains("pointillés dessinés") ? "pixels : pointillés dessinés" : "pixels : trait dessiné"
    case .cadre: return s.contains("espace libre") ? "OCR : espace après consigne" : "pixels : cadre / case"
    case .manuel: return "manuel"
    }
}
func tier(_ z: Zone) -> Tier { !z.enabled ? .desactivee : (z.confidence >= ZoneTrust.threshold ? .sure : .douteuse) }

let adminRegex = "(^|[^a-z])(nom|prenom|classe|date|groupe|poste n|eleve|enseignant|professeur|signature|observations?|visa)[^\\n]{0,8}$"
func isAdmin(_ before: String) -> Bool {
    let f = ZoneKindRules.fold(before).trimmingCharacters(in: .whitespacesAndNewlines)
    return f.range(of: adminRegex, options: .regularExpression) != nil
}
func isMargin(_ r: CGRect, page: PDFPage) -> Bool {
    let g = PageGeometry(page: page)
    let top = (g.origin.y + g.displaySize.height - r.midY) / g.displaySize.height
    return top < 0.06 || top > 0.95
}

struct Item {
    var doc: String, page: Int          // page 1-based
    var rect: CGRect                    // espace des zones
    var origin: Origin
    var pixels = 0
    var covered = 1.0                   // part du trou recouverte par des zones
    var best = Tier.aucune
    var buckets: [String] = []
    var cause = "", context = ""
    var margin = false                  // annotation dans la marge (nom, date, numéro) : pas un trou, exclue du rappel
    var found: Bool { covered >= 0.5 }
}
struct ZoneRow {
    var doc: String, page: Int, number: Int, bucket: String, tier: Tier, confidence: Double, rect: CGRect
    var signals: String, context: String
    var truth: Bool
    var admin = false                   // champ d'identité (nom, classe, date…) : vrai trou volontairement laissé vide
}
struct DocStat {
    var name = "", kind = "", pages = 0, noncomparable = 0, error = ""
    var items = 0, found = 0, zones = 0, truthZones = 0
}

// MARK: Outils géométriques

func inflated(_ r: CGRect, _ d: CGFloat) -> CGRect { r.insetBy(dx: -d, dy: -d) }
func area(_ r: CGRect) -> CGFloat { max(0, r.width) * max(0, r.height) }

// MARK: Jeu de référence : documents

struct Doc { let name: String; let original: URL; let completed: URL? }

func discover() -> [Doc] {
    let root = URL(fileURLWithPath: coursDir)
    guard fm.fileExists(atPath: root.path) else { return [] }
    var docs: [Doc] = []
    var seen = Set<String>()
    func add(_ o: URL, _ c: URL?, _ name: String) {
        guard seen.insert(o.standardizedFileURL.path).inserted else { return }
        docs.append(Doc(name: name, original: o, completed: c))
    }
    // 1. originaux rangés : version complétée dans le dossier miroir (ou à côté)
    let archive = root.appendingPathComponent(OriginalsArchive.folderName)
    for f in LibraryTree.scan(archive) {
        let rel = f.folders + [f.url.lastPathComponent]
        if LibraryTree.isEvaluationPath(rel) || f.isEvaluation || f.state != .vierge { continue }
        let base = OriginalsArchive.normalized(f.name)
        let mirror = f.folders.reduce(root) { $0.appendingPathComponent($1) }
        for dir in [mirror, f.url.deletingLastPathComponent()] {
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            if let hit = names.sorted().first(where: { n in
                n.lowercased().hasSuffix(".pdf") && !LibraryTree.looksLikeEvaluation((n as NSString).deletingPathExtension)
                    && OriginalsArchive.completedBase((n as NSString).deletingPathExtension) == base }) {
                add(f.url, dir.appendingPathComponent(hit), rel.joined(separator: "/")); break
            }
        }
    }
    // 2. paires côte à côte
    let all = LibraryTree.scan(root)
    for p in OriginalsArchive.plan(files: all, root: root) {
        let o = p.original.path.replacingOccurrences(of: root.path + "/", with: "")
        if LibraryTree.isEvaluationPath(o.components(separatedBy: "/")) { continue }
        add(p.original, p.completed, o)
    }
    // 3. documents seuls portant des annotations de l'élève (pas de paire) ; ni évaluations, ni doublons, ni copies complétées
    for f in all {
        let rel = f.folders + [f.url.lastPathComponent]
        if f.folders.first?.hasPrefix("_") == true || LibraryTree.isEvaluationPath(rel) || f.isEvaluation { continue }
        if OriginalsArchive.completedBase(f.name) != nil { continue }
        guard let d = PDFDocument(url: f.url), !d.isLocked else { continue }
        var student = 0
        for i in 0..<d.pageCount { for a in d.page(at: i)?.annotations ?? [] where (a.type ?? "") == "FreeText" && a.userName != AnswerRenderer.annotationAuthor { student += 1 } }
        if student >= 1 { add(f.url, nil, rel.joined(separator: "/")) }
    }
    return docs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

/// Copie « vierge » : sans annotations FreeText, champs de texte remplis vidés. Renvoie aussi les trous posés à la main.
func makeBlank(_ doc: Doc, index: Int) -> (URL, [Item], PDFDocument)? {
    guard let d = PDFDocument(url: doc.original), !d.isLocked, d.pageCount > 0 else { return nil }
    var items: [Item] = []
    for i in 0..<d.pageCount {
        guard let p = d.page(at: i) else { continue }
        let frame = PageGeometry(page: p)
        for a in p.annotations {
            let t = a.type ?? ""
            if t == "FreeText" {
                let author = a.userName ?? ""
                if !(a.contents ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    items.append(Item(doc: doc.name, page: i + 1, rect: frame.zoneRect(fromPage: a.bounds),
                                      origin: author == AnswerRenderer.annotationAuthor ? .appli : .eleve))
                }
                p.removeAnnotation(a)
            } else if t == "Widget", a.widgetFieldType == .text, !(a.widgetStringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                items.append(Item(doc: doc.name, page: i + 1, rect: frame.zoneRect(fromPage: a.bounds), origin: .eleve))
                a.widgetStringValue = ""
            }
        }
    }
    let url = outDir.appendingPathComponent("vierge/\(String(format: "%02d", index)).pdf")
    guard d.write(to: url), let blank = PDFDocument(url: url) else { return nil }
    return (url, items, blank)
}

// MARK: Diagnostic d'un trou manqué

func diagnose(_ item: Item, page: PDFPage, layout: TextLayout, det: PixelDetection?, geo: PageGeometry?) -> (String, String) {
    let r = item.rect
    // contexte : ligne de texte à gauche sur la même rangée, sinon la plus proche au-dessus
    var left: TextLine?, above: TextLine?, aboveD = CGFloat.greatestFiniteMagnitude
    for l in layout.lines {
        let ov = min(l.bbox.maxY, r.maxY) - max(l.bbox.minY, r.minY)
        if ov > 0.4 * min(l.bbox.height, max(r.height, 1)), l.bbox.maxX <= r.minX + 4, r.minX - l.bbox.maxX < 250 {
            if left == nil || l.bbox.maxX > left!.bbox.maxX { left = l }
        }
        if l.bbox.minY >= r.maxY - 3 {
            let d = l.bbox.minY - r.maxY
            if d < aboveD { aboveD = d; above = l }
        }
    }
    let ctx = [above?.text, left?.text].compactMap { $0 }.map { String($0.suffix(60)) }.joined(separator: " ⏎ ")
    var cause = ""
    if let det, let geo {
        let m: CGFloat = 8
        for l in det.allLines {
            let a = geo.toPage(CGPoint(x: CGFloat(l.x0), y: CGFloat(l.y))), b = geo.toPage(CGPoint(x: CGFloat(l.x1), y: CGFloat(l.yEnd)))
            let lr = CGRect(x: a.x, y: min(a.y, b.y), width: b.x - a.x, height: abs(b.y - a.y))
            if lr.maxX > r.minX, lr.minX < r.maxX, lr.midY >= r.minY - m, lr.midY <= r.maxY + m { cause = "trait vu par PixelZones mais écarté (filtre : titre, sommaire, décor, marge, recouvrement)"; break }
        }
        if cause.isEmpty {
            for b in det.boxes {
                let br = geo.toPage(rect: b)
                if area(br.intersection(r)) > 0.4 * min(area(br), max(area(r), 1)) { cause = "cadre vu par PixelZones mais écarté (filtre : tableau, figure, décor, recouvrement)"; break }
            }
        }
    }
    if cause.isEmpty {
        if layout.meaningfulCharCount < 60 { cause = "scan : ni trait ni cadre détecté ici (pointillés pâles non vus par PixelDetector, ou espace blanc ; l'OCR « espace après consigne » ne s'active que si la page n'a AUCUNE autre zone)" }
        else if let l = left ?? above, l.text.trimmingCharacters(in: .whitespaces).hasSuffix(":") { cause = "« libellé : » sans zone (colonRuns/colonDoubt a écarté ou ne l'a pas vu)" }
        else { cause = "aucun repère (ni trait, ni cadre, ni pointillé, ni deux-points) : réponse dans un espace blanc ou un schéma" }
    }
    return (cause, ctx)
}

// MARK: Dessin de contrôle

func drawOverlay(page: PDFPage, zones: [Zone], items: [Item], to url: URL) {
    guard let (img, geo) = PageImaging.render(page: page, longEdge: 1300) else { return }
    let w = img.width, h = img.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    func rr(_ r: CGRect) -> CGRect { var q = geo.toImage(rect: r); q.origin.y = CGFloat(h) - q.origin.y - q.height; return q }
    ctx.setLineWidth(2)
    for z in zones {   // bleu : sûre, orange : douteuse ou désactivée
        let c = tier(z) == .sure ? CGColor(red: 0, green: 0.3, blue: 1, alpha: 1) : CGColor(red: 1, green: 0.55, blue: 0, alpha: 1)
        ctx.setStrokeColor(c); ctx.setFillColor(c.copy(alpha: 0.12)!)
        let r = rr(z.rect); ctx.fill(r); ctx.stroke(r)
    }
    for it in items {   // vert : trou trouvé, rouge : manqué
        let c = it.found ? CGColor(red: 0, green: 0.65, blue: 0.1, alpha: 1) : CGColor(red: 0.9, green: 0, blue: 0, alpha: 1)
        ctx.setStrokeColor(c); ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.stroke(rr(it.rect))
    }
    if let cg = ctx.makeImage(), let png = PageImaging.pngData(cg) { try? png.write(to: url) }
}

// MARK: Mesure d'un document

var allItems: [Item] = []
var allZones: [ZoneRow] = []
var docStats: [DocStat] = []
var pngCount = 0

func measure(_ doc: Doc, index: Int) {
    var st = DocStat(); st.name = doc.name; st.kind = doc.completed == nil ? "annotations" : "paire"
    defer { docStats.append(st) }
    guard let (blankURL, handItems, blank) = makeBlank(doc, index: index) else { st.error = "illisible"; return }
    st.pages = blank.pageCount
    var comp: PDFDocument?
    if let c = doc.completed { comp = PDFDocument(url: c); if comp == nil { st.error = "complétée illisible"; return } }
    guard let analyses = try? CoursPipeline.analyzeChecked(url: blankURL, needText: false, progress: { _, _ in }) else { st.error = "analyse impossible"; return }
    var masks: [Int: PageDiff.AddedMask] = [:]
    var addedTotal = 0
    if let comp {
        for i in 0..<blank.pageCount {
            guard i < comp.pageCount, let bp = blank.page(at: i), let cp = comp.page(at: i), let m = PageDiff.addedInk(blank: bp, completed: cp) else { st.noncomparable += 1; continue }
            masks[i] = m; addedTotal += m.addedTotal
        }
        if addedTotal < 300 && handItems.isEmpty { st.error = "aucune encre ajoutée (original déjà rempli ?)"; return }
    }
    for a in analyses {
        let i = a.pageIndex
        guard let page = blank.page(at: i) else { continue }
        let zones = a.zones
        var items = handItems.filter { $0.page == i + 1 }
        let handCount = items.count
        // vérité « appli » : amas d'encre ajoutée, hors annotations de l'élève déjà comptées
        var mask = masks[i]
        var inkBlobs: [(rect: CGRect, pixels: Int)] = []
        if var m = mask {
            let covered = zones.map { m.pixelRect($0.rect, margin: 4) }
            let all = m.blobs(excluding: [], minPixels: 80)
            var left = m
            for r in covered {
                let x0 = max(0, Int(r.minX.rounded(.down))), x1 = min(m.width, Int(r.maxX.rounded(.up)))
                let y0 = max(0, Int(r.minY.rounded(.down))), y1 = min(m.height, Int(r.maxY.rounded(.up)))
                guard x1 > x0, y1 > y0 else { continue }
                for y in y0..<y1 { for x in x0..<x1 { left.added[y * m.width + x] = 0 } }
            }
            for b in all {
                let (n, _) = m.count(in: b.rect), (nl, _) = left.count(in: b.rect)
                let zr = m.geometry.toPage(rect: b.rect)
                let dup = items.prefix(handCount).contains { area(inflated($0.rect, 4).intersection(zr)) > 0.5 * area(zr) }
                if dup || n == 0 { continue }
                var it = Item(doc: doc.name, page: i + 1, rect: zr, origin: .appli, pixels: n)
                it.covered = 1 - Double(nl) / Double(n)
                inkBlobs.append((b.rect, n))
                items.append(it)
            }
            mask = m; m.added = []
        }
        // trous posés à la main : trouvés si une zone les recouvre
        for k in 0..<handCount {
            let r = items[k].rect
            var best = Tier.aucune; var bks: [String] = []
            for z in zones {
                let zr = inflated(z.rect, 6)
                if zr.contains(CGPoint(x: r.midX, y: r.midY)) || area(zr.intersection(r)) >= 0.4 * area(r) {
                    best = Tier(rawValue: max(best.rawValue, tier(z).rawValue))!; bks.append(bucket(z))
                }
            }
            items[k].best = best; items[k].buckets = bks; items[k].covered = best == .aucune ? 0 : 1
        }
        for k in handCount..<items.count {   // trous « appli » : zones qui touchent l'amas
            var best = Tier.aucune; var bks: [String] = []
            for z in zones where inflated(z.rect, 4).intersects(items[k].rect) {
                best = Tier(rawValue: max(best.rawValue, tier(z).rawValue))!; bks.append(bucket(z))
            }
            if items[k].covered < 0.5 { best = best == .aucune ? .aucune : best }
            items[k].best = items[k].covered >= 0.5 ? best : .aucune; items[k].buckets = bks
        }
        // zones : vraies si une réponse (élève ou encre ajoutée) tombe dedans
        for z in zones {
            var truth = items.prefix(handCount).contains { it in let zr = inflated(z.rect, 6); return zr.contains(CGPoint(x: it.rect.midX, y: it.rect.midY)) || area(zr.intersection(it.rect)) >= 0.4 * area(it.rect) }
            if !truth, let m = masks[i] {
                let r = m.pixelRect(z.rect, margin: PageDiff.settings.zoneMargin)
                let (n, ar) = m.count(in: r)
                truth = n >= PageDiff.settings.minPixels && Double(n) >= PageDiff.settings.minRatio * Double(ar)
            }
            allZones.append(ZoneRow(doc: doc.name, page: i + 1, number: z.number, bucket: bucket(z), tier: tier(z), confidence: z.confidence, rect: z.rect,
                                    signals: z.signals.joined(separator: " · "), context: String(z.contextBefore.suffix(55)).replacingOccurrences(of: "\n", with: " ⏎ "), truth: truth,
                                    admin: !truth && isAdmin(z.contextBefore)))
            st.zones += 1; if truth { st.truthZones += 1 }
        }
        for k in items.indices where isMargin(items[k].rect, page: page) { items[k].margin = true }
        // diagnostic des manques
        let missed = items.indices.filter { !items[$0].found && !items[$0].margin }
        if !missed.isEmpty {
            let layout = TextLayout.fromPDF(page)
            var det: PixelDetection?; var geo: PageGeometry?
            if let (img, g) = PageImaging.render(page: page, longEdge: 2000) {
                det = PixelDetector.detect(PageImaging.gray(img), dpi: g.pixelSize.width / (g.displaySize.width / 72)); geo = g
            }
            for k in missed { (items[k].cause, items[k].context) = diagnose(items[k], page: page, layout: layout, det: det, geo: geo) }
        }
        st.items += items.filter { !$0.margin }.count; st.found += items.filter { $0.found && !$0.margin }.count
        let hasBad = items.contains { !$0.found } || zones.contains { z in !allZones.last(where: { $0.number == z.number && $0.page == i + 1 })!.truth }
        if withPNG, hasBad, pngCount < 80 {
            pngCount += 1
            drawOverlay(page: page, zones: zones, items: items, to: outDir.appendingPathComponent("png/\(String(format: "%02d", index))_p\(i + 1).png"))
        }
        allItems.append(contentsOf: items)
    }
}

// MARK: Test synthétique (les 14 lignes de Tools/Tests/Text/main.swift)

struct SynthCase { let text: String; let x: CGFloat; let hole: Bool }
func runSynthetic() -> (expected: Int, found: Int, faux: Int, lines: [String]) {
    let cases: [SynthCase] = [
        SynthCase(text: "Nom du client ( )", x: 72, hole: true), SynthCase(text: "Ville [ ] et code postal", x: 72, hole: true),
        SynthCase(text: "Chapitre 1 ........................................ 3", x: 72, hole: false),
        SynthCase(text: "Chapitre 2 ..................................... 12", x: 72, hole: false),
        SynthCase(text: "Il était une fois... la suite de l'histoire", x: 72, hole: false),
        SynthCase(text: "Ce qu'il faut retenir, etc... dans la phrase", x: 72, hole: false),
        SynthCase(text: "Ce qui compte pour le client, c'est la qualité :", x: 72, hole: false),
        SynthCase(text: "et le prix de vente, bien sûr.", x: 72, hole: false),
        SynthCase(text: "Liste à compléter :", x: 72, hole: false), SynthCase(text: "- premier point de la liste", x: 90, hole: false),
        SynthCase(text: "Votre prénom :", x: 72, hole: true), SynthCase(text: "Votre nom :", x: 72, hole: true),
        SynthCase(text: "Date de naissance :", x: 72, hole: true),
        SynthCase(text: "Le mot manquant est ……………………………………………………", x: 72, hole: true)]
    let url = outDir.appendingPathComponent("synthetique.pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return (0, 0, 0, ["PDF synthétique impossible"]) }
    ctx.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    var expectedY: [CGFloat] = [], texts: [String] = []
    for (i, c) in cases.enumerated() {
        let y: CGFloat = 740 - CGFloat(i) * 26
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: c.text, attributes: [.font: font]))
        ctx.textPosition = CGPoint(x: c.x, y: y); CTLineDraw(line, ctx)
        if c.hole { expectedY.append(y); texts.append(c.text) }
    }
    ctx.endPDFPage(); ctx.closePDF()
    guard let d = PDFDocument(url: url), let p = d.page(at: 0) else { return (0, 0, 0, ["PDF synthétique illisible"]) }
    let a = ZoneDetector.analyze(page: p, index: 0, firstID: 1, needText: false)
    var matched = Set<Int>(), faux = 0, lines: [String] = []
    for z in a.zones {
        if let k = expectedY.indices.first(where: { abs(z.rect.midY - (expectedY[$0] + 4)) < 10 && !matched.contains($0) }) { matched.insert(k) }
        else { faux += 1; lines.append(String(format: "  FAUX   %@ y=%.0f «%@»", bucket(z), z.rect.midY, String(z.contextBefore.suffix(40)))) }
    }
    for k in expectedY.indices where !matched.contains(k) { lines.append("  MANQUE «\(texts[k])»") }
    return (expectedY.count, matched.count, faux, lines)
}

// MARK: Rapport

func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "  n/a" : String(format: "%4.0f %%", 100 * Double(a) / Double(b)) }
func short(_ s: String, _ n: Int) -> String { s.count > n ? "…" + s.suffix(n - 1) : s }
var report: [String] = []
func out(_ s: String = "") { print(s); report.append(s) }

// empreinte des sources de détection (le code évolue pendant les optimisations : savoir de quelle version on parle)
func sourcesHash() -> String {
    let base = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Core")
    var h = SHA256()
    for f in ["ZoneDetector", "PixelZones", "TextLayer", "OCR", "ZoneKindRules", "PageImaging", "Pipeline"] {
        if let d = try? Data(contentsOf: base.appendingPathComponent(f + ".swift")) { h.update(data: d) }
    }
    return h.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
}

let synth = runSynthetic()
out("BANC D'ESSAI DE LA DÉTECTION — sources de détection (empreinte) : \(sourcesHash())")
out("Synthétique (Tools/Tests/Text) : attendus=\(synth.expected) trouves=\(synth.found) faux=\(synth.faux) manques=\(synth.expected - synth.found)")
synth.lines.forEach { out($0) }

let docs = syntheticOnly ? [] : discover().filter { d in (only.isEmpty || d.name.localizedCaseInsensitiveContains(only)) && !excluded.contains { d.name.localizedCaseInsensitiveContains($0) } }
if docs.isEmpty {
    out(syntheticOnly ? "(--synthetique : PDF réels ignorés)" : "Aucun PDF de cours trouvé dans \(coursDir) : jeu de référence limité au synthétique.")
    print("SYNTHESE attendus=\(synth.expected) trouves=\(synth.found) faux=\(synth.faux)")
    try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("resultat.txt"), atomically: true, encoding: .utf8)
    exit(0)
}
let t0 = Date()
for (i, d) in docs.enumerated() {
    log("[\(i + 1)/\(docs.count)] \(d.name)")
    autoreleasepool { measure(d, index: i + 1) }
}

out("")
out("JEU DE RÉFÉRENCE : \(docs.count) document(s) (\(docStats.filter { $0.kind == "paire" }.count) paires original/complétée, \(docStats.filter { $0.kind == "annotations" }.count) avec annotations de l'élève), analysés en \(Int(Date().timeIntervalSince(t0))) s")
out(String(format: "%-52@ %-11@ %4@ %5@ %6@ %6@ %6@ %6@", "document" as NSString, "type" as NSString, "pg" as NSString, "trous" as NSString, "trouvés" as NSString, "zones" as NSString, "vraies" as NSString, "rappel" as NSString))
for s in docStats {
    if !s.error.isEmpty { out(String(format: "%-52@ %-11@ ÉCARTÉ : %@", short(s.name, 52) as NSString, s.kind as NSString, s.error as NSString)); continue }
    out(String(format: "%-52@ %-11@ %4d %5d %6d %6d %6d %@%@", short(s.name, 52) as NSString, s.kind as NSString, s.pages, s.items, s.found, s.zones, s.truthZones, pct(s.found, s.items) as NSString,
               (s.noncomparable > 0 ? "  (\(s.noncomparable) p. non comparable(s))" : "") as NSString))
}

let valid = Set(docStats.filter { $0.error.isEmpty }.map { $0.name })
let marginItems = allItems.filter { valid.contains($0.doc) && $0.margin }
let items = allItems.filter { valid.contains($0.doc) && !$0.margin }
let zones = allZones.filter { valid.contains($0.doc) }

func recallBlock(_ title: String, _ its: [Item]) {
    let n = its.count
    guard n > 0 else { out("  \(title) : aucun trou de référence"); return }
    let any = its.filter { $0.found }.count
    let enabled = its.filter { $0.found && $0.best.rawValue >= Tier.douteuse.rawValue }.count
    let sure = its.filter { $0.found && $0.best == .sure }.count
    out("  \(title) : \(n) trous  |  couverts par une zone \(any) (\(pct(any, n)))  |  par une zone ACTIVE \(enabled) (\(pct(enabled, n)))  |  par une zone SÛRE (>=0,7) \(sure) (\(pct(sure, n)))  |  MANQUÉS \(n - any)")
}
out("")
out("RAPPEL (trou de la vérité recouvert par au moins une zone détectée ; \(marginItems.count) annotations dans la marge — nom, date — exclues)")
recallBlock("vérité ÉLÈVE (placée à la main, indépendante du détecteur)", items.filter { $0.origin == .eleve })
recallBlock("vérité APPLI (encre ajoutée par la complétion)           ", items.filter { $0.origin == .appli })
let appliPx = items.filter { $0.origin == .appli }.reduce(0) { $0 + $1.pixels }
let appliPxFound = items.filter { $0.origin == .appli }.reduce(0.0) { $0 + Double($1.pixels) * min(1, $1.covered) }
out("  encre « appli » recouverte par des zones : \(String(format: "%.0f", 100 * appliPxFound / Double(max(appliPx, 1)))) % des pixels")

out("")
out("PRÉCISION (zone qui contient une réponse ; « fausse » = aucune réponse : majorant des faux trous, l'élève a pu laisser vide)")
func precBlock(_ title: String, _ zs: [ZoneRow]) {
    let t = zs.filter { $0.truth }.count
    let adm = zs.filter { $0.admin }.count
    out(String(format: "  %-34@ zones %4d  vraies %4d  sans réponse %4d (dont identité %3d)  précision %@  hors identité %@", title as NSString, zs.count, t, zs.count - t, adm, pct(t, zs.count) as NSString, pct(t, zs.count - adm) as NSString))
}
precBlock("toutes les zones", zones)
precBlock("zones actives sûres (>=0,7)", zones.filter { $0.tier == .sure })
precBlock("zones actives douteuses (<0,7)", zones.filter { $0.tier == .douteuse })
precBlock("zones désactivées", zones.filter { $0.tier == .desactivee })

out("")
out("PAR SOURCE DE DÉTECTION")
out(String(format: "  %-30@ %5@ %5@ %5@ %9@ %6@ %9@ %9@", "source" as NSString, "zones" as NSString, "vraies" as NSString, "ident" as NSString, "préc.horsId" as NSString, "sûres" as NSString, "préc.sûres" as NSString, "trous cvt" as NSString))
for b in Set(zones.map { $0.bucket }).sorted() {
    let zs = zones.filter { $0.bucket == b }, sure = zs.filter { $0.tier == .sure }
    let covered = items.filter { $0.found && $0.buckets.contains(b) }.count
    let adm = zs.filter { $0.admin }.count
    out(String(format: "  %-30@ %5d %5d %5d %@ %6d %@ %9d", b as NSString, zs.count, zs.filter { $0.truth }.count, adm, pct(zs.filter { $0.truth }.count, zs.count - adm) as NSString,
               sure.count, pct(sure.filter { $0.truth }.count, sure.count) as NSString, covered))
}

let missed = items.filter { !$0.found }
let weak = items.filter { $0.found && $0.best != .sure }
out("")
out("TROUS COUVERTS SEULEMENT PAR UNE ZONE DOUTEUSE (<0,7) OU DÉSACTIVÉE : \(weak.count) (le pipeline ne remplit pas d'office une zone désactivée ; une douteuse n'est contrôlée par l'IA que si l'option est active)")
var weakBy: [String: Int] = [:]
for w in weak { for b in Set(w.buckets) { weakBy[b, default: 0] += 1 } }
out("  par source : " + weakBy.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ; "))
out("")
out("CAUSES DES \(missed.count) TROUS MANQUÉS")
var causes: [String: [Item]] = [:]
for m in missed { causes[m.cause, default: []].append(m) }
for (c, its) in causes.sorted(by: { $0.value.count > $1.value.count }) {
    out("  \(its.count) × \(c)  (élève \(its.filter { $0.origin == .eleve }.count), appli \(its.filter { $0.origin == .appli }.count))")
}
out("")
out("TROUS MANQUÉS (\(min(topN * 2, missed.count)) sur \(missed.count), élève d'abord puis plus grosse encre)")
for m in missed.sorted(by: { ($0.origin == .eleve ? 1 : 0, $0.pixels) > ($1.origin == .eleve ? 1 : 0, $1.pixels) }).prefix(topN * 2) {
    out(String(format: "  [%@] %@ p.%d  x=%.0f y=%.0f %.0f×%.0f pt  %d px  zones voisines: %@\n        cause : %@\n        texte voisin : «%@»", m.origin.rawValue, short(m.doc, 44), m.page, m.rect.minX, m.rect.minY, m.rect.width, m.rect.height, m.pixels,
               (m.buckets.isEmpty ? "-" : m.buckets.joined(separator: ",")) as String, m.cause, m.context))
}
let falseZones = zones.filter { !$0.truth && !$0.admin }
out("")
out("ZONES SANS RÉPONSE hors champs d'identité (\(min(topN * 2, falseZones.count)) sur \(falseZones.count), les plus sûres d'abord)")
for z in falseZones.sorted(by: { ($0.confidence, $0.rect.width) > ($1.confidence, $1.rect.width) }).prefix(topN * 2) {
    out(String(format: "  %@ p.%d #%d  %@  conf %.2f  %.0f×%.0f pt  [%@]  «%@»", short(z.doc, 44), z.page, z.number, z.bucket, z.confidence, z.rect.width, z.rect.height, z.signals, z.context))
}
var falseByBucket: [String: Int] = [:]
for z in falseZones { falseByBucket[z.bucket, default: 0] += 1 }
out("")
out("ZONES SANS RÉPONSE PAR SOURCE : " + falseByBucket.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ; "))
var falseByDoc: [String: Int] = [:]
for z in falseZones { falseByDoc[z.doc, default: 0] += 1 }
out("ZONES SANS RÉPONSE PAR DOCUMENT (les 8 premiers) :")
for (d, n) in falseByDoc.sorted(by: { $0.value > $1.value }).prefix(8) { out("   \(n) × \(short(d, 70))") }

// fichiers détaillés pour le rapport
var tsv = "origine\tdocument\tpage\tx\ty\tl\th\tpixels\tcouverture\tzones\tcause\tcontexte\n"
for m in items where !m.found {
    tsv += "\(m.origin.rawValue)\t\(m.doc)\t\(m.page)\t\(Int(m.rect.minX))\t\(Int(m.rect.minY))\t\(Int(m.rect.width))\t\(Int(m.rect.height))\t\(m.pixels)\t\(String(format: "%.2f", m.covered))\t\(m.buckets.joined(separator: ","))\t\(m.cause)\t\(m.context)\n"
}
try? tsv.write(to: outDir.appendingPathComponent("manques.tsv"), atomically: true, encoding: .utf8)
var tsv2 = "document\tpage\tnumero\tsource\tconfiance\tsignaux\tcontexte\n"
for z in falseZones { tsv2 += "\(z.doc)\t\(z.page)\t\(z.number)\t\(z.bucket)\t\(String(format: "%.2f", z.confidence))\t\(z.signals)\t\(z.context)\n" }
try? tsv2.write(to: outDir.appendingPathComponent("zones_sans_reponse.tsv"), atomically: true, encoding: .utf8)

let eleve = items.filter { $0.origin == .eleve }, appli = items.filter { $0.origin == .appli }
let line = "REEL docs=\(docs.count) trous_eleve=\(eleve.count) trouves_eleve=\(eleve.filter { $0.found }.count) trous_appli=\(appli.count) trouves_appli=\(appli.filter { $0.found }.count) zones=\(zones.count) vraies=\(zones.filter { $0.truth }.count)"
out("")
out(line)
print("SYNTHESE attendus=\(synth.expected) trouves=\(synth.found) faux=\(synth.faux)")
try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("resultat.txt"), atomically: true, encoding: .utf8)
