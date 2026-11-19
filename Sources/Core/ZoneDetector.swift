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
        let rot = ((page.rotation % 360) + 360) % 360
        if rot != 0 {
            return PageAnalysis(pageIndex: index, zones: [], transcript: "", hasTextLayer: false,
                                rotationUnsupported: true, fontSize: 11)
        }

        var layout = TextLayout.fromPDF(page)
        let hasText = layout.meaningfulCharCount >= 60
        var drafts: [Zone] = []
        var leaderOf: [Int: (run: LeaderRun, extraLines: [Int])] = [:]   // index dans drafts -> info pointillé

        // 1. champs de formulaire vides
        for ann in page.annotations {
            guard (ann.type ?? "") == "Widget", ann.widgetFieldType == .text else { continue }
            let value = ann.widgetStringValue ?? ""
            if !value.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let b = ann.bounds
            if b.width < 12 || b.height < 8 { continue }
            var z = Zone(id: 0, page: index, number: 0, source: .formulaire)
            z.box = b
            z.widget = ann
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
                // lignes de pointillés qui suivent directement
                var cur = r
                while cur.endsLine, cur.isLeader,
                      let nj = runs.indices.first(where: { runs[$0].line == cur.line + 1 && runs[$0].isPureLine && !consumed.contains($0) }) {
                    let nxt = runs[nj]
                    let lh = max(layout.lines[cur.line].charHeight, 8)
                    guard cur.ruleY - nxt.ruleY <= 2.6 * lh, cur.ruleY - nxt.ruleY > 0.5 * lh else { break }
                    z.lines.append(WritingLine(x0: nxt.rect.minX, x1: nxt.rect.maxX, y: nxt.ruleY))
                    extra.append(nxt.line)
                    consumed.insert(nj)
                    cur = nxt
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
            let det = PixelDetector.detect(gray, dpi: dpi)

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
                if !overlapsExisting(z.rect) { drafts.append(z) }
            }
            // 3c. cadres et cases vides
            for b in det.boxes {
                let r = geo.toPage(rect: b)
                var z = Zone(id: 0, page: index, number: 0, source: .cadre)
                z.box = r
                if !overlapsExisting(r) { drafts.append(z) }
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
