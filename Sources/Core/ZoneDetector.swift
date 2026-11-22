import Foundation
import PDFKit

struct PageAnalysis {
    var pageIndex: Int
    var zones: [Zone]
    var transcript: String        // texte de la page avec des repères ⟦n⟧ à la place des trous
    var hasTextLayer: Bool
    var rotationUnsupported: Bool
    var fontSize: CGFloat
}

enum ZoneDetector {

    /// Analyse une page : trouve les trous à remplir et reconstruit le texte autour.
    /// - Parameter needText: lit aussi le texte des pages scannées (OCR) — utile pour les IA sans vision.
    static func analyze(page: PDFPage, index: Int, firstID: Int, needText: Bool) -> PageAnalysis {
        // Les zones sont dans l'espace de la page AFFICHÉE (rotation appliquée) : voir PageGeometry.
        let frame = PageGeometry(page: page)

        var layout = TextLayout.fromPDF(page)
        let hasText = layout.meaningfulCharCount >= 60
        var drafts: [Zone] = []
        var leaderOf: [Int: (run: LeaderRun, extraLines: [Int])] = [:]   // index dans drafts -> info pointillé

        // 1. champs de formulaire vides
        for ann in page.annotations {
            guard (ann.type ?? "") == "Widget", ann.widgetFieldType == .text else { continue }
            let value = ann.widgetStringValue ?? ""
            if !value.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let b = frame.zoneRect(fromPage: ann.bounds)
            if b.width < 12 || b.height < 8 { continue }
            var z = Zone(id: 0, page: index, number: 0, source: .formulaire)
            z.box = b
            z.widget = ann
            z.confidence = 0.98
            z.signals = ["champ de formulaire vide"]
            drafts.append(z)
        }

        // 2. pointillés et underscores du texte
        if hasText {
            let runs = layout.leaderRuns() + layout.bracketRuns() + layout.colonRuns()
            var consumed = Set<Int>()   // index de run déjà absorbé dans une zone multi-lignes
            for (ri, r) in runs.enumerated() where !consumed.contains(ri) {
                // déjà couvert par un champ de formulaire : pas de doublon
                if drafts.contains(where: { $0.source == .formulaire && ($0.box?.intersects(r.rect) ?? false) }) { continue }
                var z = Zone(id: 0, page: index, number: 0, source: .texte)
                z.lines = [WritingLine(x0: r.rect.minX, x1: r.rect.maxX, y: r.ruleY)]
                var extra: [Int] = []
                var covered = r.isLeader && layout.hasTypedAnswer(on: r)   // réponse déjà tapée sur le pointillé
                // lignes de pointillés qui suivent directement
                var cur = r
                while cur.endsLine, cur.isLeader,
                      let nj = runs.indices.first(where: { runs[$0].line == cur.line + 1 && runs[$0].isPureLine && !consumed.contains($0) }) {
                    let nxt = runs[nj]
                    let lh = max(layout.lines[cur.line].charHeight, 8)
                    guard cur.ruleY - nxt.ruleY <= 2.6 * lh, cur.ruleY - nxt.ruleY > 0.5 * lh else { break }
                    z.lines.append(WritingLine(x0: nxt.rect.minX, x1: nxt.rect.maxX, y: nxt.ruleY))
                    extra.append(nxt.line)
                    if layout.hasTypedAnswer(on: nxt) { covered = true }
                    consumed.insert(nj)
                    cur = nxt
                }
                if r.isLeader {
                    z.confidence = 0.92; z.signals = ["pointillés dans le texte"]
                    if covered {
                        z.confidence = 0.4
                        z.signals.append("texte déjà écrit sur le pointillé (réponse probablement déjà donnée)")
                    }
                } else if r.endsLine {
                    z.confidence = 0.7; z.signals = ["« libellé : » sans rien à droite"]
                } else {
                    z.confidence = 0.7; z.signals = ["parenthèses ou crochets vides"]
                }
                drafts.append(z)
                leaderOf[drafts.count - 1] = (r, extra)
            }
        }

        // 3. image de la page (détection visuelle, OCR des scans)
        let rendered = PageImaging.render(page: page, longEdge: 2000)
        if !hasText && needText, let (img, geo) = rendered {
            layout = OCR.layout(image: img, geometry: geo)
        }
        let textAvailable = layout.meaningfulCharCount >= 20
        let fontSize: CGFloat = textAvailable ? min(12, max(8.5, layout.bodyHeight / 1.2)) : 10.5
        let body = layout.bodyHeight

        /// Titre souligné ou trait décoratif : la ligne de texte juste au-dessus est plus grosse, ou collée et large.
        func isHeadingRule(_ l: WritingLine) -> Bool {
            guard textAvailable else { return false }
            for tl in layout.lines {
                let gap = tl.bbox.minY - l.y
                guard gap > -2, gap < 1.8 * tl.bbox.height else { continue }
                let ox = min(tl.bbox.maxX, l.x1) - max(tl.bbox.minX, l.x0)
                guard ox > 0.25 * min(tl.bbox.width, l.width) else { continue }
                if tl.bbox.height >= 1.22 * body { return true }
                if gap <= 0.35 * tl.bbox.height && tl.bbox.width >= 0.5 * l.width { return true }
            }
            return false
        }

        if let (img, geo) = rendered {
            let gray = PageImaging.gray(img)
            let dpi = geo.pixelSize.width / (geo.displaySize.width / 72)
            // détection de la page + formes des autres pages (décor répété : en-têtes, pieds de page, logos)
            let decor = DecorIndex.shared
            let det = decor.detection(page: page, index: index, own: (gray, geo, dpi))
            let pageW = geo.displaySize.width, pageH = geo.displaySize.height
            /// Position verticale depuis le haut de la page affichée (0 en haut, 1 en bas).
            func fromTop(_ y: CGFloat) -> CGFloat { (geo.origin.y + pageH - y) / pageH }
            func inMargin(_ y: CGFloat) -> String? {
                let f = fromTop(y)
                if f < 0.105 { return "dans la marge haute de la page" }
                if f > 0.915 { return "dans la marge basse de la page" }
                return nil
            }

            // 3a. pointillés du texte : caler sur la vraie ligne dessinée, écarter ceux qui sont déjà remplis
            var drop = Set<Int>()
            // « Libellé : » ou parenthèses dont la place est occupée par une image ou un tableau : pas un trou
            for di in drafts.indices where drafts[di].source == .texte && !(leaderOf[di]?.run.isLeader ?? true) && (leaderOf[di]?.run.endsLine ?? false) {
                guard let wl = drafts[di].lines.first, let info = leaderOf[di] else { continue }
                let hpx = max(4, Int(layout.lines[info.run.line].bbox.height * geo.sx * 0.9))
                let a = geo.toImage(CGPoint(x: wl.x0, y: wl.y))
                let b = geo.toImage(CGPoint(x: wl.x1, y: wl.y))
                let x0 = max(0, Int(min(a.x, b.x))), x1 = min(gray.width - 1, Int(max(a.x, b.x)))
                let y0 = max(0, Int(a.y) - hpx), y1 = min(gray.height - 1, Int(a.y) + 2)
                guard x1 > x0, y1 > y0 else { continue }
                var ink = 0
                for y in y0...y1 {
                    for x in x0...x1 where gray.data[y * gray.width + x] < 110 { ink += 1 }
                }
                if Double(ink) > 0.02 * Double((x1 - x0 + 1) * (y1 - y0 + 1)) { drop.insert(di) }
            }
            // « Libellé : » dont la réponse n'est probablement pas à droite : texte courant ou figure juste en dessous
            for di in drafts.indices where drafts[di].source == .texte && !drop.contains(di) {
                guard let info = leaderOf[di], !info.run.isLeader, info.run.endsLine else { continue }
                let label = layout.lines[info.run.line].bbox
                if let why = colonDoubt(label: label, layout: layout, gray: gray, geo: geo) {
                    drafts[di].confidence = min(drafts[di].confidence, 0.35)
                    drafts[di].signals.append(why)
                }
            }
            for di in drafts.indices where drafts[di].source == .texte {
                for li in drafts[di].lines.indices {
                    let wl = drafts[di].lines[li]
                    let a = geo.toImage(CGPoint(x: wl.x0, y: wl.y))
                    let b = geo.toImage(CGPoint(x: wl.x1, y: wl.y))
                    var best: PixelLine?
                    var bestDy = Int.max
                    for pl in det.allLines {
                        let ox = min(Int(b.x), pl.x1) - max(Int(a.x), pl.x0)
                        let shorter = max(1, min(Int(b.x - a.x), pl.x1 - pl.x0))
                        guard Double(ox) >= 0.5 * Double(shorter) else { continue }
                        let dy = abs((pl.y + pl.yEnd) / 2 - Int(a.y))
                        if dy <= Int(0.08 * dpi) && dy < bestDy { best = pl; bestDy = dy }
                    }
                    guard let pl = best else { continue }
                    let p0 = geo.toPage(CGPoint(x: CGFloat(pl.x0), y: CGFloat(pl.y)))
                    let p1 = geo.toPage(CGPoint(x: CGFloat(pl.x1), y: CGFloat(pl.yEnd)))
                    let k = abs(p1.x - p0.x) > 1 ? (p1.y - p0.y) / (p1.x - p0.x) : 0
                    func yAt(_ x: CGFloat) -> CGFloat { p0.y + (x - p0.x) * k }
                    drafts[di].lines[li] = WritingLine(x0: wl.x0, x1: wl.x1, y: yAt(wl.x0), yEnd: yAt(wl.x1))
                    if li == 0 && pl.occupied { drop.insert(di) }
                }
            }
            if !drop.isEmpty {
                var remap: [Int: Int] = [:]
                var kept: [Zone] = []
                for (i, z) in drafts.enumerated() where !drop.contains(i) { remap[i] = kept.count; kept.append(z) }
                var newLeaders: [Int: (run: LeaderRun, extraLines: [Int])] = [:]
                for (old, info) in leaderOf { if let n = remap[old] { newLeaders[n] = info } }
                drafts = kept
                leaderOf = newLeaders
            }

            func overlapsExisting(_ rect: CGRect) -> Bool {
                let r = rect.insetBy(dx: -2, dy: -5)
                for e in drafts {
                    let er = e.rect.insetBy(dx: -2, dy: -5)
                    let inter = r.intersection(er)
                    if inter.isNull || inter.isEmpty { continue }
                    let minArea = max(1, min(r.width * r.height, er.width * er.height))
                    if inter.width * inter.height > 0.35 * minArea { return true }
                }
                return false
            }

            // 3b. lignes libres repérées dans l'image
            for group in det.lineGroups {
                var z = Zone(id: 0, page: index, number: 0, source: .ligne)
                for pl in group {
                    let a = geo.toPage(CGPoint(x: CGFloat(pl.x0), y: CGFloat(pl.y)))
                    let b = geo.toPage(CGPoint(x: CGFloat(pl.x1), y: CGFloat(pl.yEnd)))
                    z.lines.append(WritingLine(x0: a.x, x1: b.x, y: a.y, yEnd: b.y))
                }
                if let first = z.lines.first, isHeadingRule(first) { continue }
                if layout.tocRects.contains(where: { $0.intersects(z.rect) }) { continue }
                guard !overlapsExisting(z.rect), let first = z.lines.first else { continue }
                let dotted = group.first?.dotted ?? false
                z.confidence = dotted ? 0.85 : 0.8
                z.signals = [dotted ? "pointillés dessinés" : "ligne dessinée"]
                if z.lines.count >= 2 { z.confidence = 0.88; z.signals.append("\(z.lines.count) lignes alignées") }
                else if !dotted && first.width < 60 { z.confidence = 0.55; z.signals.append("ligne très courte") }
                let others = decor.repeats(of: PageShape(line: first), page: index, anyX: inMargin(first.y) != nil)
                if let why = inMargin(first.y) {
                    // en-tête, pied de page : une forme qui revient à la même hauteur sur d'autres pages n'est pas un trou
                    z.confidence = min(z.confidence, 0.3); z.signals.append(why)
                } else if others >= 2 && z.lines.count == 1 && first.width < 0.5 * pageW {
                    z.confidence = min(z.confidence, 0.35)
                    z.signals.append("même ligne sur \(others + 1) pages (décor probable)")
                }
                drafts.append(z)
            }
            // 3c. cadres et cases vides
            var cadreDrafts: [Int] = []
            for b in det.boxes {
                let r = geo.toPage(rect: b)
                var z = Zone(id: 0, page: index, number: 0, source: .cadre)
                z.box = r
                if overlapsExisting(r) { continue }
                z.confidence = 0.55
                z.signals = ["cadre vide dessiné (rien n'indique qu'il faut y écrire)"]
                let others = decor.repeats(of: PageShape(box: r), page: index, anyX: false)
                if others >= 2 {
                    z.confidence = min(z.confidence, 0.3)
                    z.signals.append("même cadre sur \(others + 1) pages (décor probable)")
                } else if let why = inMargin(r.midY) {
                    z.confidence = min(z.confidence, 0.35); z.signals.append(why)
                }
                cadreDrafts.append(drafts.count)
                drafts.append(z)
            }
            // cases d'un tableau vide, cadres posés sur une figure : plus douteux
            var dropped = Set<Int>()
            for di in cadreDrafts {
                guard let r = drafts[di].box else { continue }
                var aligned = 0
                for oi in cadreDrafts where oi != di {
                    guard let o = drafts[oi].box else { continue }
                    if abs(o.height - r.height) <= 5 && (abs(o.minY - r.minY) <= 4 || abs(o.minX - r.minX) <= 4) { aligned += 1 }
                }
                if aligned >= 3 {
                    drafts[di].confidence = min(drafts[di].confidence, 0.5)
                    drafts[di].signals.append("case d'un tableau vide (\(aligned + 1) cases alignées)")
                }
                if tickedNeighbour(r, gray: gray, geo: geo) {
                    drafts[di].confidence = min(drafts[di].confidence, 0.4)
                    drafts[di].signals.append("case laissée vide dans une ligne dont les autres cases sont déjà marquées")
                }
                let busy = surroundingInk(r, gray: gray, geo: geo)
                if busy > 0.25 { dropped.insert(di); continue }    // posé sur une photo ou un fond coloré : décor
                if busy > 0.08 {
                    drafts[di].confidence = min(drafts[di].confidence, 0.4)
                    drafts[di].signals.append("posé sur un schéma ou une image")
                }
            }
            // (les cadres sont les derniers brouillons : retirer des indices ne décale pas les pointillés du texte)
            if !dropped.isEmpty { drafts = drafts.enumerated().filter { !dropped.contains($0.offset) }.map { $0.element } }

            // 3d. scan sans aucune ligne ni case à remplir : les réponses vont dans les blancs, après les consignes
            if drafts.isEmpty, !hasText {
                // lecture du scan (OCR) seulement pour cette page sans trou trouvé, même si l'IA a la vision
                if layout.meaningfulCharCount < 20 { layout = OCR.layout(image: img, geometry: geo) }
                if layout.meaningfulCharCount >= 20 {
                    drafts = implicitSpaces(layout: layout, gray: gray, geo: geo, pageIndex: index, body: layout.bodyHeight)
                }
            }
        }

        // 4. ordre de lecture et numérotation
        let tol = max(6, body * 0.6)
        let order = drafts.indices.sorted { a, b in
            let ra = drafts[a].rect, rb = drafts[b].rect
            if abs(ra.maxY - rb.maxY) > tol { return ra.maxY > rb.maxY }
            return ra.minX < rb.minX
        }
        var zones: [Zone] = []
        var oldToNew: [Int: Int] = [:]
        for (n, oldIndex) in order.enumerated() {
            var z = drafts[oldIndex]
            z.id = firstID + n
            z.number = n + 1
            z.textHeight = fontSize
            oldToNew[oldIndex] = n
            zones.append(z)
        }
        var leaders: [Int: (run: LeaderRun, extraLines: [Int])] = [:]
        for (old, info) in leaderOf { if let n = oldToNew[old] { leaders[n] = info } }

        // 5. texte de la page avec repères + contexte autour de chaque zone
        let (transcript, contexts) = buildTranscript(layout: layout, zones: zones, leaders: leaders)
        for i in zones.indices {
            zones[i].contextBefore = contexts[i]?.before ?? ""
            zones[i].contextAfter = contexts[i]?.after ?? ""
            zones[i].kind = KindGuesser.guess(zones[i])
        }
        return PageAnalysis(pageIndex: index, zones: zones, transcript: transcript, hasTextLayer: hasText,
                            rotationUnsupported: false, fontSize: fontSize)
    }

    // MARK: - Espaces libres après une consigne (scans sans lignes)

    private static let instructionCue = "^(\\(?\\d+[\\).]?\\s*)?(calcule|determine|represente|compare|justifie|explique|donne|cite|complete|trace|dessine|ecris|indique|resume|decris|nomme|precise|deduis|convertis|detaille|quelle|quel|quels|quelles|combien|pourquoi|comment|en quoi|cette experience|est-ce)"

    /// Propose les espaces blancs qui suivent une consigne (à droite sur la même ligne, ou juste dessous).
    /// Ces zones sont DÉSACTIVÉES et douteuses : une proposition à confirmer, jamais remplie d'office.
    static func implicitSpaces(layout: TextLayout, gray: GrayBitmap, geo: PageGeometry, pageIndex: Int, body: CGFloat) -> [Zone] {
        let pageRect = CGRect(origin: geo.origin, size: geo.displaySize)
        let left = pageRect.minX + 24, right = pageRect.maxX - 30
        var out: [Zone] = []
        for (i, tl) in layout.lines.enumerated() {
            let folded = ZoneKindRules.fold(tl.text).trimmingCharacters(in: .whitespaces)
            let isCue = folded.range(of: instructionCue, options: .regularExpression) != nil || folded.hasSuffix("?")
            guard isCue, folded.count >= 12 else { continue }
            let h = max(tl.bbox.height, 8)
            // pas dans les marges de la page
            let fromTop = (pageRect.maxY - tl.bbox.midY) / pageRect.height
            guard fromTop > 0.08, fromTop < 0.94 else { continue }
            let others = layout.lines.enumerated().filter { $0.offset != i }.map { $0.element.bbox }
            var candidate: CGRect?
            var why = ""
            let rightX = tl.bbox.maxX + 10
            if right - rightX >= 150 {
                // la réponse tient souvent sur deux lignes : on descend jusqu'au prochain texte (au plus 2,4 lignes)
                var bottom = tl.bbox.minY - 1.4 * h
                for o in others where o.maxX > rightX && o.minX < right && o.maxY < tl.bbox.maxY - 0.3 * h { bottom = max(bottom, o.maxY + 2) }
                let r = CGRect(x: rightX, y: bottom, width: right - rightX, height: tl.bbox.maxY + 3 - bottom)
                if r.height >= h, !others.contains(where: { $0.intersects(CGRect(x: r.minX, y: tl.bbox.minY, width: r.width, height: h).insetBy(dx: 0, dy: 1)) }) { candidate = r; why = "espace libre à droite de la consigne" }
            }
            if candidate == nil {
                let below = others.filter { $0.maxY <= tl.bbox.minY + 1 && min($0.maxX, tl.bbox.maxX + 200) > tl.bbox.minX && $0.minX < tl.bbox.maxX }
                let gapTo = below.map { tl.bbox.minY - $0.maxY }.min() ?? (tl.bbox.minY - (pageRect.minY + 40))
                if gapTo >= 2.4 * h {
                    let bh = min(gapTo - 8, 80)
                    candidate = CGRect(x: max(left, tl.bbox.minX), y: tl.bbox.minY - 4 - bh, width: right - max(left, tl.bbox.minX), height: bh)
                    why = "espace libre sous la consigne"
                }
            }
            guard let r = candidate, r.width > 60, r.height > 8, darkShare(r, gray: gray, geo: geo) < 0.015 else { continue }
            if out.contains(where: { $0.rect.intersects(r) }) { continue }
            var z = Zone(id: 0, page: pageIndex, number: 0, source: .cadre)
            z.box = r
            z.confidence = 0.45
            z.signals = [why + " (aucune ligne dessinée : à confirmer)"]
            z.enabled = false
            out.append(z)
        }
        return out
    }

    // MARK: - Doute sur un « Libellé : »

    /// Part de pixels foncés dans un rectangle de l'espace des zones (hors texte de la couche texte si `skipping`).
    private static func darkShare(_ r: CGRect, gray: GrayBitmap, geo: PageGeometry, skipping: [CGRect] = [], threshold: UInt8 = 150) -> Double {
        let ir = geo.toImage(rect: r)
        let x0 = max(0, Int(ir.minX)), x1 = min(gray.width - 1, Int(ir.maxX))
        let y0 = max(0, Int(ir.minY)), y1 = min(gray.height - 1, Int(ir.maxY))
        guard x1 > x0, y1 > y0 else { return 0 }
        let skip = skipping.map { geo.toImage(rect: $0.insetBy(dx: -1.5, dy: -1.5)) }.filter { $0.intersects(ir) }
        var dark = 0, total = 0
        for y in y0...y1 {
            for x in x0...x1 {
                if !skip.isEmpty, skip.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { continue }
                total += 1
                if gray.data[y * gray.width + x] < threshold { dark += 1 }
            }
        }
        return total > 0 ? Double(dark) / Double(total) : 0
    }

    /// Part de pixels non blancs dans un anneau autour d'un cadre (fond coloré, photo, schéma voisin).
    private static func surroundingInk(_ r: CGRect, gray: GrayBitmap, geo: PageGeometry) -> Double {
        let ir = geo.toImage(rect: r)
        let inner = 5, outer = 16
        let x0 = max(0, Int(ir.minX) - outer), x1 = min(gray.width - 1, Int(ir.maxX) + outer)
        let y0 = max(0, Int(ir.minY) - outer), y1 = min(gray.height - 1, Int(ir.maxY) + outer)
        guard x1 > x0, y1 > y0 else { return 0 }
        var busy = 0, total = 0
        for y in y0...y1 {
            for x in x0...x1 {
                let dx = max(Int(ir.minX) - x, x - Int(ir.maxX), 0), dy = max(Int(ir.minY) - y, y - Int(ir.maxY), 0)
                let d = max(dx, dy)
                guard d >= inner && d <= outer else { continue }
                total += 1
                if gray.data[y * gray.width + x] < 225 { busy += 1 }
            }
        }
        return total > 0 ? Double(busy) / Double(total) : 0
    }

    /// Tableau à cocher / à marquer : la ligne compte au moins trois cases de même largeur (bordées par des traits verticaux)
    /// et l'une des autres contient déjà une croix ou du texte. La case vide est alors laissée vide exprès (faux, non, aucune).
    /// Deux cases seulement (« terme | définition ») ne suffisent pas : la case vide est alors précisément à remplir.
    private static func tickedNeighbour(_ r: CGRect, gray: GrayBitmap, geo: PageGeometry) -> Bool {
        let ir = geo.toImage(rect: r)
        let w = Int(ir.width), top = Int(ir.minY) + 4, bottom = Int(ir.maxY) - 4
        guard w >= 20, bottom - top >= 12 else { return false }
        func dark(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < gray.width && y >= 0 && y < gray.height && gray.data[y * gray.width + x] < 140
        }
        var cells = 0, marked = false
        for dir in [1, -1] {
            var near = dir > 0 ? Int(ir.maxX) : Int(ir.minX)
            for _ in 0..<8 {
                // trait vertical qui ferme la case voisine, à une largeur de case (à 8 % près) de la précédente
                var farEdge: Int?
                for d in -(w * 8 / 100)...(w * 8 / 100) {
                    let x = near + dir * w + d
                    var hits = 0
                    for y in top...bottom where dark(x - 1, y) || dark(x, y) || dark(x + 1, y) { hits += 1 }
                    if Double(hits) >= 0.8 * Double(bottom - top + 1) { farEdge = x; break }
                }
                guard let far = farEdge else { break }
                let x0 = min(near, far) + 5, x1 = max(near, far) - 5
                guard x1 - x0 > 10 else { break }
                cells += 1
                var ink = 0
                for y in top...bottom { for x in x0...x1 where dark(x, y) { ink += 1 } }
                if ink >= 40 && Double(ink) >= 0.002 * Double((x1 - x0 + 1) * (bottom - top + 1)) { marked = true }
                near = far
            }
        }
        return marked && cells >= 2
    }

    /// Raison pour laquelle la place à droite d'un « Libellé : » n'est probablement pas le trou : le texte continue
    /// juste en dessous (paragraphe), ou une figure / un tableau se trouve juste en dessous. nil si rien à signaler.
    private static func colonDoubt(label: CGRect, layout: TextLayout, gray: GrayBitmap, geo: PageGeometry) -> String? {
        let lh = max(label.height, 8)
        var below: TextLine?
        var bestGap = CGFloat.greatestFiniteMagnitude
        for t in layout.lines {
            let gap = label.minY - t.bbox.maxY
            guard gap > -2, gap < bestGap, t.bbox.minX < label.maxX, t.bbox.maxX > label.minX else { continue }
            below = t; bestGap = gap
        }
        if let t = below, bestGap < 0.9 * lh, t.text.count >= 20, !t.text.hasSuffix(":"), t.bbox.minX < label.minX + 40 {
            return "texte courant juste en dessous du libellé"
        }
        let band = CGRect(x: label.minX, y: label.minY - 62, width: 280, height: 58)
        let textBoxes = layout.lines.map { $0.bbox }
        if darkShare(band, gray: gray, geo: geo, skipping: textBoxes) > 0.05 {
            return "schéma ou tableau juste en dessous du libellé"
        }
        return nil
    }

    // MARK: - Zone dessinée à la main

    /// Crée une zone à partir d'un rectangle (espace page PDF) désigné par l'utilisateur,
    /// avec le texte voisin comme contexte. `useOCR` lit aussi le texte d'un scan.
    static func manualZone(page: PDFPage, index: Int, id: Int, number: Int, rect: CGRect, useOCR: Bool) -> Zone {
        var z = Zone(id: id, page: index, number: number, source: .manuel)
        z.box = rect
        var layout = TextLayout.fromPDF(page)
        if layout.meaningfulCharCount < 60, useOCR, let (img, geo) = PageImaging.render(page: page, longEdge: 2000) {
            layout = OCR.layout(image: img, geometry: geo)
        }
        let lines = layout.lines
        z.textHeight = layout.meaningfulCharCount >= 20 ? min(12, max(8.5, layout.bodyHeight / 1.2)) : 10.5

        // même rangée : à gauche (avant) et à droite (après)
        var left: [TextLine] = [], right: [TextLine] = []
        for l in lines {
            let bb = l.bbox
            let ov = min(bb.maxY, rect.maxY) - max(bb.minY, rect.minY)
            guard ov > 0.4 * min(bb.height, max(rect.height, 1)) else { continue }
            if bb.maxX <= rect.minX + 4 { left.append(l) } else if bb.minX >= rect.maxX - 4 { right.append(l) }
        }
        left.sort { $0.bbox.minX < $1.bbox.minX }
        right.sort { $0.bbox.minX < $1.bbox.minX }
        // lignes au-dessus, les plus proches d'abord, remises dans l'ordre de lecture
        let above = lines
            .filter { $0.bbox.minY >= rect.maxY - 3 && max(0, max($0.bbox.minX - rect.maxX, rect.minX - $0.bbox.maxX)) < 120 }
            .sorted { ($0.bbox.minY - rect.maxY) < ($1.bbox.minY - rect.maxY) }
            .prefix(5)
            .sorted { $0.bbox.minY > $1.bbox.minY }
        let beforeText = (above.map { $0.text } + left.map { $0.text }).joined(separator: "\n")
        z.contextBefore = String(beforeText.suffix(650))
        z.contextAfter = String(right.map { $0.text }.joined(separator: " ").prefix(220))
        z.kind = KindGuesser.guess(z)
        return z
    }

    // MARK: - Texte de la page avec repères

    static func marker(_ n: Int) -> String { "⟦\(n)⟧" }

    private struct Edit { var line: Int; var lo: Int; var hi: Int; var text: String }   // décalages en Character

    /// Position d'insertion (en Character) dans une ligne pour une abscisse donnée, calée sur une frontière de mot.
    private static func insertionIndex(line: TextLine, x: CGFloat) -> Int {
        let chars = Array(line.text)
        let frac = (x - line.bbox.minX) / max(line.bbox.width, 1)
        var idx = Int((frac * CGFloat(chars.count)).rounded())
        idx = min(max(idx, 0), chars.count)
        var lo = idx, hi = idx
        while lo > 0 && chars[lo - 1] != " " { lo -= 1 }
        while hi < chars.count && chars[hi] != " " { hi += 1 }
        return (idx - lo <= hi - idx) ? lo : hi
    }

    private static func buildTranscript(layout: TextLayout, zones: [Zone],
                                        leaders: [Int: (run: LeaderRun, extraLines: [Int])])
        -> (String, [Int: (before: String, after: String)]) {
        let lines = layout.lines
        var edits: [Edit] = []
        var removed = Set<Int>()
        var after: [Int: [String]] = [:]       // repères ajoutés sur une ligne à part, après la ligne i
        var tail: [String] = []

        for (zi, z) in zones.enumerated() {
            let mk = marker(z.number)
            if let info = leaders[zi] {
                edits.append(Edit(line: info.run.line, lo: info.run.charLo, hi: info.run.charHi, text: " \(mk) "))
                for l in info.extraLines { removed.insert(l) }
                continue
            }
            let r = z.rect
            // ligne de texte sur la même rangée ?
            var best: (idx: Int, dist: CGFloat)? = nil
            for (li, line) in lines.enumerated() where !removed.contains(li) {
                let bb = line.bbox
                let ov = min(bb.maxY, r.maxY) - max(bb.minY, r.minY)
                if ov > 0.5 * min(bb.height, max(r.height, 1)) {
                    let dx = max(0, max(bb.minX - r.maxX, r.minX - bb.maxX))
                    if best == nil || dx < best!.dist { best = (li, dx) }
                }
            }
            if let b = best, b.dist < 160 {
                let line = lines[b.idx]
                var idx = line.text.count
                if r.maxX <= line.bbox.minX { idx = 0 }
                else if r.minX < line.bbox.maxX { idx = insertionIndex(line: line, x: r.minX) }
                edits.append(Edit(line: b.idx, lo: idx, hi: idx, text: " \(mk) "))
                continue
            }
            // sinon : sur une ligne à part, après la ligne de texte la plus proche au-dessus
            var above: (idx: Int, dist: CGFloat)? = nil
            for (li, line) in lines.enumerated() where !removed.contains(li) {
                let bb = line.bbox
                guard bb.minY >= r.maxY - 3 else { continue }
                let dx = max(0, max(bb.minX - r.maxX, r.minX - bb.maxX))
                let d = (bb.minY - r.maxY) + dx * 0.25
                if above == nil || d < above!.dist { above = (li, d) }
            }
            if let a = above { after[a.idx, default: []].append(mk) } else { tail.append(mk) }
        }

        var out: [String] = []
        for (li, line) in lines.enumerated() {
            if !removed.contains(li) {
                var chars = Array(line.text).map { String($0) }
                let es = edits.filter { $0.line == li }.sorted { $0.lo > $1.lo }
                for e in es {
                    let lo = min(max(0, e.lo), chars.count), hi = min(max(lo, e.hi), chars.count)
                    chars.replaceSubrange(lo..<hi, with: [e.text])
                }
                out.append(chars.joined().replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces))
            }
            for m in after[li] ?? [] { out.append(m) }
        }
        out.append(contentsOf: tail)
        let text = out.joined(separator: "\n")

        var ctx: [Int: (before: String, after: String)] = [:]
        for (zi, z) in zones.enumerated() {
            let mk = marker(z.number)
            guard let range = text.range(of: mk) else { continue }
            var before = String(text[..<range.lowerBound].suffix(650))
            if let nl = before.firstIndex(of: "\n"), before.count > 500 { before = String(before[before.index(after: nl)...]) }
            var aft = String(text[range.upperBound...].prefix(220))
            if let nl2 = aft.range(of: "\n\n") { aft = String(aft[..<nl2.lowerBound]) }
            ctx[zi] = (before.trimmingCharacters(in: .whitespacesAndNewlines), aft.trimmingCharacters(in: .whitespaces))
        }
        return (text, ctx)
    }
}

/// Devine le type de réponse attendu d'après la forme du trou et le texte voisin.
enum KindGuesser {
    private static let defRegex = "d[ée]fin(i|ir|issez|ition)|qu['’]est[- ]ce (que|qu['’])|c['’]est quoi|que (signifie|veut dire)|signification|d[ée]crivez|expliquez"

    static func guess(_ z: Zone) -> ZoneKind {
        let before = z.contextBefore.lowercased()
        let tail = String(before.suffix(150))
        let width = z.rect.width
        let multi = z.lines.count >= 2 || (z.box.map { $0.width * $0.height > 9000 && $0.height > 40 } ?? false)
        let afterSame = z.contextAfter.prefix(while: { $0 != "\n" }).trimmingCharacters(in: .whitespaces)
        let hasDef = tail.range(of: defRegex, options: .regularExpression) != nil

        if multi { return hasDef && z.lines.count <= 2 ? .definition : .question }
        if hasDef && width > 120 { return .definition }
        if afterSame.count >= 2 && width < 230 { return .mot }
        if width < 150 { return .mot }
        return .question
    }
}

// MARK: - Décor répété d'une page à l'autre

/// Forme repérée dans l'image d'une page (espace des zones), pour retrouver le décor qui revient sur plusieurs pages.
struct PageShape {
    var rect: CGRect
    var isBox: Bool
    init(line: WritingLine) { rect = CGRect(x: line.x0, y: line.y, width: line.width, height: 0); isBox = false }
    init(box: CGRect) { rect = box; isBox = true }

    /// Même forme à la même place (quelques points près) ; `anyX` : seule la hauteur compte (traits d'en-tête et de pied de page).
    func matches(_ o: PageShape, anyX: Bool) -> Bool {
        guard isBox == o.isBox else { return false }
        if isBox {
            return abs(rect.minX - o.rect.minX) <= 4 && abs(rect.maxX - o.rect.maxX) <= 4
                && abs(rect.minY - o.rect.minY) <= 4 && abs(rect.maxY - o.rect.maxY) <= 4
        }
        guard abs(rect.minY - o.rect.minY) <= 3 else { return false }
        if anyX { return true }
        return abs(rect.minX - o.rect.minX) <= 5 && abs(rect.maxX - o.rect.maxX) <= 5
    }
}

/// Mémoire (par document) de ce que la détection visuelle a trouvé sur chaque page : la première page analysée
/// examine toutes les pages une seule fois, les suivantes réutilisent le résultat.
final class DecorIndex: @unchecked Sendable {
    static let shared = DecorIndex()
    /// Au-delà, on ne cherche plus le décor (coût d'examen de toutes les pages au premier appel).
    static let maxPages = 80

    private struct Entry { var det: PixelDetection; var shapes: [PageShape]; var annotations: Int }
    private let lock = NSLock()
    private weak var document: PDFDocument?
    private var entries: [Int: Entry] = [:]

    /// Détection de la page `index` (calculée avec `own` si elle n'est pas en mémoire) ; examine aussi les autres pages.
    func detection(page: PDFPage, index: Int, own: (GrayBitmap, PageGeometry, CGFloat)) -> PixelDetection {
        guard let doc = page.document, doc.pageCount >= 3, doc.pageCount <= Self.maxPages else {
            return PixelDetector.detect(own.0, dpi: own.2)
        }
        lock.lock()
        if document !== doc { document = doc; entries = [:] }
        let known = entries[index]
        lock.unlock()
        let det: PixelDetection
        if let known, known.annotations == page.annotations.count { det = known.det } else {
            det = PixelDetector.detect(own.0, dpi: own.2)
            store(det, geometry: own.1, page: page, index: index)
        }
        // les autres pages : une seule fois
        for j in 0..<doc.pageCount where j != index {
            lock.lock(); let have = entries[j] != nil; lock.unlock()
            if have { continue }
            guard let p = doc.page(at: j) else { continue }
            autoreleasepool {
                guard let (img, geo) = PageImaging.render(page: p, longEdge: 2000) else { return }
                let g = PageImaging.gray(img)
                let d = PixelDetector.detect(g, dpi: geo.pixelSize.width / (geo.displaySize.width / 72))
                store(d, geometry: geo, page: p, index: j)
            }
        }
        return det
    }

    private func store(_ det: PixelDetection, geometry geo: PageGeometry, page: PDFPage, index: Int) {
        var shapes: [PageShape] = []
        for l in det.allLines {
            let a = geo.toPage(CGPoint(x: CGFloat(l.x0), y: CGFloat(l.y)))
            let b = geo.toPage(CGPoint(x: CGFloat(l.x1), y: CGFloat(l.yEnd)))
            shapes.append(PageShape(line: WritingLine(x0: a.x, x1: b.x, y: a.y, yEnd: b.y)))
        }
        for b in det.boxes { shapes.append(PageShape(box: geo.toPage(rect: b))) }
        lock.lock()
        entries[index] = Entry(det: det, shapes: shapes, annotations: page.annotations.count)
        lock.unlock()
    }

    /// Nombre d'AUTRES pages où la même forme se trouve au même endroit (0 si le document a moins de 3 pages).
    func repeats(of shape: PageShape, page index: Int, anyX: Bool) -> Int {
        lock.lock(); defer { lock.unlock() }
        var n = 0
        for (j, e) in entries where j != index {
            if e.shapes.contains(where: { shape.matches($0, anyX: anyX) }) { n += 1 }
        }
        return n
    }
}
