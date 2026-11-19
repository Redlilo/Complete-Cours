import Foundation
import CoreGraphics

/// Ligne à remplir repérée dans l'image de la page (pixels de l'image d'origine, origine en haut à gauche).
struct PixelLine: Hashable {
    var x0: Int
    var x1: Int
    var y: Int          // ordonnée du centre à gauche (en x0)
    var yEnd: Int       // ordonnée du centre à droite (en x1) ; différente de y si le scan est penché
    var dotted: Bool
    var occupied: Bool  // du texte est déjà écrit juste au-dessus de la ligne
}

struct PixelDetection {
    var lineGroups: [[PixelLine]] = []   // lignes libres, regroupées (plusieurs lignes alignées = une zone)
    var allLines: [PixelLine] = []       // toutes les lignes retenues, remplies ou non
    var boxes: [CGRect] = []             // cadres et cases vides
    var skew: CGFloat = 0                // pente corrigée du scan (dy/dx dans l'image)
}

/// Estimation et correction de l'inclinaison d'un scan.
enum Deskew {
    /// Pente (dy/dx, image) des lignes de texte du scan ; 0 si la page est droite ou si l'estimation est incertaine.
    static func estimateSlope(_ g: GrayBitmap) -> CGFloat {
        let w = g.width, h = g.height
        let f = max(1, w / 700)
        let bw = w / f, bh = h / f
        var xs: [Int32] = [], ys: [Int32] = []
        let x0 = Int(Double(bw) * 0.03), x1 = Int(Double(bw) * 0.97)
        let y0 = Int(Double(bh) * 0.03), y1 = Int(Double(bh) * 0.97)
        for by in y0..<y1 {
            for bx in x0..<x1 {
                var any = false
                search: for yy in 0..<f {
                    let row = (by * f + yy) * w + bx * f
                    for xx in 0..<f where g.data[row + xx] < 140 { any = true; break search }
                }
                if any { xs.append(Int32(bx)); ys.append(Int32(by)) }
            }
        }
        if xs.count < 300 { return 0 }
        let off = 80
        func score(_ t: Double) -> Double {
            var hist = [Int32](repeating: 0, count: bh + 2 * off)
            for i in 0..<xs.count {
                let yp = Int((Double(ys[i]) - Double(xs[i]) * t).rounded()) + off
                if yp >= 0 && yp < hist.count { hist[yp] += 1 }
            }
            var s = 0.0
            for c in hist { s += Double(c) * Double(c) }
            return s
        }
        let base = score(0)
        var best = 0.0, bestScore = base
        var t = -0.05
        while t <= 0.05 {
            let s = score(t)
            if s > bestScore { bestScore = s; best = t }
            t += 0.0015
        }
        var t2 = best - 0.0015
        while t2 <= best + 0.0015 {
            let s = score(t2)
            if s > bestScore { bestScore = s; best = t2 }
            t2 += 0.0003
        }
        if bestScore < base * 1.03 { return 0 }
        return CGFloat(best)
    }

    /// Cisaillement vertical qui redresse des lignes de pente `t` : out(x, y') = in(x, y' + (x - cx)·t).
    static func shear(_ g: GrayBitmap, slope t: CGFloat) -> GrayBitmap {
        let w = g.width, h = g.height
        var out = [UInt8](repeating: 255, count: w * h)
        let cx = CGFloat(w) / 2
        for x in 0..<w {
            let shift = Int(((CGFloat(x) - cx) * t).rounded())
            let lo = max(0, -shift), hi = min(h, h - shift)
            if lo >= hi { continue }
            for yp in lo..<hi { out[yp * w + x] = g.data[(yp + shift) * w + x] }
        }
        return GrayBitmap(width: w, height: h, data: out)
    }
}

/// Détection « à l'œil » : lignes, pointillés et cadres vides, sans dépendre de la couche texte du PDF.
enum PixelDetector {

    private struct Comp {
        var minX = Int.max, maxX = 0, minY = Int.max, maxY = 0, area = 0
    }

    private struct Raw {
        var x0: Int
        var x1: Int
        var y: Int
        var yTop: Int
        var dotted: Bool
        var occupied = false
    }

    static func detect(_ g0: GrayBitmap, dpi: CGFloat) -> PixelDetection {
        let w = g0.width, h = g0.height, n = w * h
        guard w > 50, h > 50 else { return PixelDetection() }

        // --- 0. redressement d'un scan penché
        let slope = Deskew.estimateSlope(g0)
        let applied: CGFloat = abs(slope) >= 0.0025 ? slope : 0
        let g = applied != 0 ? Deskew.shear(g0, slope: applied) : g0
        let cx = CGFloat(w) / 2

        var ink = [UInt8](repeating: 0, count: n)
        var faintInk = [UInt8](repeating: 0, count: n)
        let hat = blackTopHat(g.data, w: w, h: h, radius: 3)
        for i in 0..<n {
            let v = g.data[i]
            ink[i] = v < 165 ? 1 : 0
            // trait pâle : franchement gris, ou un peu plus sombre que son voisinage immédiat (trait fin)
            faintInk[i] = (v < 228 || (hat[i] >= 14 && v < 246)) ? 1 : 0
        }

        let minLen = Int(0.55 * dpi)
        let maxThick = max(3, Int(0.04 * dpi))
        let bandH = max(8, Int(0.12 * dpi))
        let marginY = Int(0.035 * Double(h))

        // --- 1. lignes pleines (traits foncés), puis lignes pâles
        var lines = solidLines(ink: ink, w: w, h: h, minLen: minLen, maxThick: maxThick)
        let (inkLabels, inkComps) = label(mask: ink, w: w, h: h, target: 1, eight: true)
        lines += dottedLines(comps: inkComps, dpi: dpi)

        let faintLines = solidLines(ink: faintInk, w: w, h: h, minLen: Int(1.0 * dpi), maxThick: 3)
        for f in faintLines {
            let dup = lines.contains { l in
                abs(l.y - f.y) <= 4 && min(l.x1, f.x1) - max(l.x0, f.x0) > Int(0.5 * Double(f.x1 - f.x0))
            }
            if !dup { lines.append(f) }
        }

        // un même trait peut sortir en plusieurs morceaux (scan légèrement penché, trait interrompu) : on les recolle
        lines = mergeCollinear(lines, gap: Int(0.08 * dpi))

        // régions blanches fermées par un trait, y compris les traits pâles (cadres arrondis, cellules, cartouches) :
        // leurs bords ne sont pas des lignes d'écriture, et celles qui sont vides sont des cases à remplir
        var regions: [CGRect] = []
        var faintBoxes: [CGRect] = []
        do {
            let (fLabels, fComps) = label(mask: faintInk, w: w, h: h, target: 1, eight: true)
            var faintClean = [UInt8](repeating: 0, count: n)
            for i in 0..<n where faintInk[i] == 1 {
                let l = Int(fLabels[i])
                if l >= 0 && fComps[l].area >= 6 { faintClean[i] = 1 }
            }
            let closedFaint = dilate(faintClean, w: w, h: h)
            let (_, whites) = label(mask: closedFaint, w: w, h: h, target: 0, eight: false)
            let rw = Int(0.45 * dpi), rh = Int(0.2 * dpi)
            for c in whites {
                if c.minX == 0 || c.minY == 0 || c.maxX == w - 1 || c.maxY == h - 1 { continue }
                let bw = c.maxX - c.minX + 1, bh = c.maxY - c.minY + 1
                if bw < rw || bh < rh || Double(bw * bh) > 0.6 * Double(n) { continue }
                regions.append(CGRect(x: c.minX, y: c.minY, width: bw, height: bh))
                // case vide : région rectangulaire sans encre à l'intérieur
                if Double(bw * bh) <= 0.4 * Double(n), Double(c.area) / Double(bw * bh) >= 0.97 {
                    var inside = 0
                    for y in c.minY...c.maxY {
                        let row = y * w
                        for x in c.minX...c.maxX where faintClean[row + x] == 1 { inside += 1 }
                    }
                    if inside <= max(12, Int(0.0004 * Double(bw * bh))) {
                        faintBoxes.append(CGRect(x: c.minX - 1, y: c.minY - 1, width: bw + 2, height: bh + 2))
                    }
                }
            }
        }

        // --- 2. cadres vides
        var boxes = emptyBoxes(ink: ink, labels: inkLabels, comps: inkComps, w: w, h: h, dpi: dpi)
        for fb in faintBoxes {
            let dup = boxes.contains { b in
                let inter = b.intersection(fb)
                guard !inter.isNull else { return false }
                return inter.width * inter.height > 0.5 * min(b.width * b.height, fb.width * fb.height)
            }
            if !dup { boxes.append(fb) }
        }

        // --- 3. filtrage
        func columnsWithInk(_ x0: Int, _ x1: Int, _ yFrom: Int, _ yTo: Int) -> (cols: Int, total: Int) {
            let ya = max(0, yFrom), yb = min(h - 1, yTo)
            guard yb >= ya, x1 > x0 else { return (0, max(0, x1 - x0 + 1)) }
            var cols = 0
            for x in x0...x1 {
                var count = 0
                for y in ya...yb where ink[y * w + x] == 1 { count += 1; if count >= 2 { break } }
                if count >= 2 { cols += 1 }
            }
            return (cols, x1 - x0 + 1)
        }
        func attached(_ x: Int, _ yTop: Int, _ yBot: Int) -> Bool {
            func vertical(_ rows: ClosedRange<Int>) -> Int {
                var count = 0
                for y in rows where y >= 0 && y < h {
                    var any = false
                    for xx in max(0, x - 3)...min(w - 1, x + 3) where faintInk[y * w + xx] == 1 { any = true; break }
                    if any { count += 1 }
                }
                return count
            }
            return vertical((yTop - 11)...(yTop - 2)) >= 8 || vertical((yBot + 2)...(yBot + 11)) >= 8
        }
        /// Nombre de traits verticaux qui traversent la ligne (quadrillage d'un schéma ou d'un tableau).
        func crossings(_ x0: Int, _ x1: Int, _ yTop: Int, _ yBot: Int) -> Int {
            var strokes = 0
            var inStroke = false
            guard x1 - x0 > 12 else { return 0 }
            for x in (x0 + 4)...(x1 - 4) {
                var above = false, below = false
                for y in max(0, yTop - 10)...max(0, yTop - 3) where faintInk[y * w + x] == 1 { above = true; break }
                for y in min(h - 1, yBot + 3)...min(h - 1, yBot + 10) where faintInk[y * w + x] == 1 { below = true; break }
                if above && below {
                    if !inStroke { strokes += 1; inStroke = true }
                } else if x % 1 == 0 { inStroke = false }
            }
            return strokes
        }
        var kept: [Raw] = []
        for l in lines {
            let width = l.x1 - l.x0
            if l.y < marginY || l.y > h - marginY { continue }
            // traits pleins (pas pointillés) dans les 4,5 % du haut et du bas de la page : filets d'en-tête et de pied de page
            if !l.dotted && (l.y < Int(0.045 * Double(h)) || l.y > Int(0.955 * Double(h))) { continue }
            if Double(width) > 0.95 * Double(w) { continue }
            // longs traits pleins dans les marges haute et basse : en-têtes et pieds de page
            if !l.dotted && Double(width) >= 0.6 * Double(w) && (l.y < Int(0.09 * Double(h)) || l.y > Int(0.93 * Double(h))) { continue }
            // bord d'un cadre ou d'un tableau : les deux extrémités touchent un trait vertical
            if !l.dotted && (attached(l.x0, l.yTop, l.y) || attached(l.x1, l.yTop, l.y)) { continue }
            let yBotApprox = l.dotted ? l.y + 1 : 2 * l.y - l.yTop
            let cross = crossings(l.x0, l.x1, l.yTop, yBotApprox)
            if cross >= 2 { continue }
            // bord d'une région fermée (haut ou bas d'un cadre, d'une cellule, d'un cartouche arrondi)
            if regions.contains(where: { r in
                let ox = min(CGFloat(l.x1), r.maxX) - max(CGFloat(l.x0), r.minX)
                guard ox > 0.6 * min(CGFloat(width), r.width) else { return false }
                return abs(CGFloat(l.y) - (r.minY - 3)) <= 7 || abs(CGFloat(l.y) - (r.maxY + 3)) <= 7
            }) { continue }
            // bord d'un cadre vide déjà repéré
            if boxes.contains(where: { b in
                let ox = min(CGFloat(l.x1), b.maxX) - max(CGFloat(l.x0), b.minX)
                guard ox > 0.6 * CGFloat(width) else { return false }
                let y = CGFloat(l.y)
                return abs(y - b.minY) <= 5 || abs(y - b.maxY) <= 5
            }) { continue }
            kept.append(l)
        }

        // dédoublonnage (un pointillé dense peut aussi sortir comme ligne pleine)
        kept.sort { ($0.y, $0.x0) < ($1.y, $1.x0) }
        var unique: [Raw] = []
        for l in kept {
            if let k = unique.firstIndex(where: { u in
                abs(u.y - l.y) <= 4 && min(u.x1, l.x1) - max(u.x0, l.x0) > Int(0.6 * Double(min(u.x1 - u.x0, l.x1 - l.x0)))
            }) {
                if (l.x1 - l.x0) > (unique[k].x1 - unique[k].x0) { unique[k] = l }
            } else { unique.append(l) }
        }

        // du texte juste au-dessus : soulignement, réponse déjà écrite (même courte)
        for i in unique.indices {
            let l = unique[i]
            let top = l.dotted ? l.y - 2 : l.yTop
            let r = columnsWithInk(l.x0 + 4, l.x1 - 4, top - bandH - 2, top - 3)
            unique[i].occupied = r.cols >= max(8, Int(0.03 * Double(r.total)))
        }

        // --- 4. regroupement : plusieurs lignes alignées et sans texte entre elles = une seule zone
        var groups: [[Raw]] = []
        for l in unique where !l.occupied {
            var placed = false
            for gi in groups.indices.reversed() {
                guard let last = groups[gi].last else { continue }
                let gap = l.y - last.y
                if gap < Int(0.10 * dpi) || gap > Int(0.55 * dpi) { continue }
                if abs(l.x0 - last.x0) > Int(0.18 * dpi) || abs(l.x1 - last.x1) > Int(0.30 * dpi) { continue }
                let from = last.y + 4, to = (l.dotted ? l.y - 2 : l.yTop) - bandH - 3
                if to > from {
                    let r = columnsWithInk(max(l.x0, last.x0), min(l.x1, last.x1), from, to)
                    if Double(r.cols) > 0.06 * Double(max(r.total, 1)) { continue }
                }
                groups[gi].append(l)
                placed = true
                break
            }
            if !placed { groups.append([l]) }
        }

        // --- 5. retour dans les coordonnées de l'image d'origine
        func back(_ l: Raw) -> PixelLine {
            let y0 = l.y + Int(((CGFloat(l.x0) - cx) * applied).rounded())
            let y1 = l.y + Int(((CGFloat(l.x1) - cx) * applied).rounded())
            return PixelLine(x0: l.x0, x1: l.x1, y: y0, yEnd: y1, dotted: l.dotted, occupied: l.occupied)
        }
        func backBox(_ r: CGRect) -> CGRect {
            let s0 = (r.minX - cx) * applied, s1 = (r.maxX - cx) * applied
            let top = max(r.minY + s0, r.minY + s1)
            let bottom = min(r.maxY + s0, r.maxY + s1)
            return CGRect(x: r.minX, y: top, width: r.width, height: max(1, bottom - top))
        }
        var result = PixelDetection()
        result.skew = applied
        result.allLines = unique.map(back)
        result.lineGroups = groups.map { $0.map(back) }
        result.boxes = boxes.map(backBox)
        return result
    }

    /// Fermeture morphologique (carré de côté 2r+1) moins l'image : fait ressortir les traits fins sombres sur fond clair.
    private static func blackTopHat(_ g: [UInt8], w: Int, h: Int, radius r: Int) -> [UInt8] {
        let n = w * h
        var a = g
        var b = g
        // dilatation (maximum) : horizontale puis verticale
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                var m: UInt8 = 0
                for xx in max(0, x - r)...min(w - 1, x + r) { let v = g[row + xx]; if v > m { m = v } }
                a[row + x] = m
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var m: UInt8 = 0
                for yy in max(0, y - r)...min(h - 1, y + r) { let v = a[yy * w + x]; if v > m { m = v } }
                b[y * w + x] = m
            }
        }
        // érosion (minimum)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                var m: UInt8 = 255
                for xx in max(0, x - r)...min(w - 1, x + r) { let v = b[row + xx]; if v < m { m = v } }
                a[row + x] = m
            }
        }
        var out = [UInt8](repeating: 0, count: n)
        for y in 0..<h {
            for x in 0..<w {
                var m: UInt8 = 255
                for yy in max(0, y - r)...min(h - 1, y + r) { let v = a[yy * w + x]; if v < m { m = v } }
                let d = Int(m) - Int(g[y * w + x])
                out[y * w + x] = d > 0 ? UInt8(min(d, 255)) : 0
            }
        }
        return out
    }

    private static func mergeCollinear(_ input: [Raw], gap: Int) -> [Raw] {
        let sorted = input.sorted { ($0.y, $0.x0) < ($1.y, $1.x0) }
        var out: [Raw] = []
        for l in sorted {
            if let k = out.firstIndex(where: { u in
                u.dotted == l.dotted && abs(u.y - l.y) <= 4 && l.x0 <= u.x1 + gap && u.x0 <= l.x1 + gap
            }) {
                out[k].x0 = min(out[k].x0, l.x0)
                out[k].x1 = max(out[k].x1, l.x1)
                out[k].y = (out[k].y + l.y) / 2
                out[k].yTop = min(out[k].yTop, l.yTop)
            } else { out.append(l) }
        }
        return out
    }

    // MARK: - Lignes pleines

    private static func solidLines(ink: [UInt8], w: Int, h: Int, minLen: Int, maxThick: Int) -> [Raw] {
        struct Acc { var x0: Int; var x1: Int; var yTop: Int; var yBot: Int }
        var finished: [Acc] = []
        var active: [Acc] = []
        for y in 0..<h {
            var next: [Acc] = []
            let row = y * w
            var i = 0
            while i < w {
                if ink[row + i] == 0 { i += 1; continue }
                var end = i, gap = 0, j = i + 1
                while j < w {
                    if ink[row + j] == 1 { end = j; gap = 0 } else { gap += 1; if gap > 2 { break } }
                    j += 1
                }
                let len = end - i + 1
                if len >= minLen {
                    if let k = active.firstIndex(where: { a in
                        guard a.yBot == y - 1 else { return false }
                        let ov = min(a.x1, end) - max(a.x0, i) + 1
                        return Double(ov) >= 0.7 * Double(min(len, a.x1 - a.x0 + 1))
                    }) {
                        var a = active.remove(at: k)
                        a.x0 = min(a.x0, i); a.x1 = max(a.x1, end); a.yBot = y
                        next.append(a)
                    } else {
                        next.append(Acc(x0: i, x1: end, yTop: y, yBot: y))
                    }
                }
                i = end + 1
            }
            finished.append(contentsOf: active)
            active = next
        }
        finished.append(contentsOf: active)
        return finished
            .filter { $0.yBot - $0.yTop + 1 <= maxThick }
            .map { Raw(x0: $0.x0, x1: $0.x1, y: ($0.yTop + $0.yBot) / 2, yTop: $0.yTop, dotted: false) }
    }

    // MARK: - Pointillés

    private static func dottedLines(comps: [Comp], dpi: CGFloat) -> [Raw] {
        let maxDot = max(5, Int(0.075 * dpi))
        let maxDotH = max(4, Int(0.05 * dpi))
        let maxGap = Int(0.14 * dpi)

        var dots = comps.filter { c in
            let cw = c.maxX - c.minX + 1, ch = c.maxY - c.minY + 1
            return cw <= maxDot && ch <= maxDotH && c.area >= 2 && max(cw, ch) <= 4 * min(cw, ch)
        }
        dots.sort { $0.minX < $1.minX }

        struct Chain { var xs: [(Int, Int)]; var ys: [Int]; var lastRight: Int; var lastCY: Int }
        var chains: [Chain] = []
        var buckets: [Int: [Int]] = [:]
        for d in dots {
            let cy = (d.minY + d.maxY) / 2
            let b = cy / 3
            var best = -1, bestGap = Int.max
            for bb in (b - 1)...(b + 1) {
                for ci in buckets[bb] ?? [] {
                    let c = chains[ci]
                    let gap = d.minX - c.lastRight - 1
                    if gap >= -1 && gap <= maxGap && abs(cy - c.lastCY) <= 2 && gap < bestGap { best = ci; bestGap = gap }
                }
            }
            if best >= 0 {
                let oldB = chains[best].lastCY / 3
                chains[best].xs.append((d.minX, d.maxX))
                chains[best].ys.append(cy)
                chains[best].lastRight = d.maxX
                chains[best].lastCY = cy
                if oldB != b { buckets[b, default: []].append(best) }
            } else {
                chains.append(Chain(xs: [(d.minX, d.maxX)], ys: [cy], lastRight: d.maxX, lastCY: cy))
                buckets[b, default: []].append(chains.count - 1)
            }
        }

        var out: [Raw] = []
        for c in chains where c.xs.count >= 8 {
            let x0 = c.xs.first!.0, x1 = c.xs.last!.1
            guard x1 - x0 + 1 >= Int(0.5 * dpi) else { continue }
            var gaps: [Int] = []
            for i in 1..<c.xs.count { gaps.append(c.xs[i].0 - c.xs[i - 1].1 - 1) }
            let med = gaps.sorted()[gaps.count / 2]
            let tol = max(2, med / 2)
            let ok = gaps.filter { abs($0 - med) <= tol }.count
            guard Double(ok) / Double(gaps.count) >= 0.8 else { continue }
            let y = c.ys.sorted()[c.ys.count / 2]
            out.append(Raw(x0: x0, x1: x1, y: y, yTop: y - 1, dotted: true))
        }
        return out
    }

    // MARK: - Cadres vides

    private static func emptyBoxes(ink: [UInt8], labels: [Int32], comps: [Comp], w: Int, h: Int, dpi: CGFloat) -> [CGRect] {
        let n = w * h
        var clean = [UInt8](repeating: 0, count: n)
        for i in 0..<n where ink[i] == 1 {
            let l = Int(labels[i])
            if l >= 0 && comps[l].area >= 6 { clean[i] = 1 }
        }
        let closed = dilate(clean, w: w, h: h)
        let (_, whites) = label(mask: closed, w: w, h: h, target: 0, eight: false)

        let minW = Int(0.5 * dpi), minH = Int(0.22 * dpi)
        var out: [CGRect] = []
        for c in whites {
            if c.minX == 0 || c.minY == 0 || c.maxX == w - 1 || c.maxY == h - 1 { continue }
            let bw = c.maxX - c.minX + 1, bh = c.maxY - c.minY + 1
            if bw < minW || bh < minH { continue }
            if Double(bw * bh) > 0.4 * Double(n) { continue }
            if Double(c.area) / Double(bw * bh) < 0.97 { continue }
            // « vide » = presque aucune encre à l'intérieur (une croix ou un mot suffit à écarter la case)
            var inside = 0
            for y in c.minY...c.maxY {
                let row = y * w
                for x in c.minX...c.maxX where clean[row + x] == 1 { inside += 1 }
            }
            if inside > max(12, Int(0.0004 * Double(bw * bh))) { continue }
            out.append(CGRect(x: c.minX - 1, y: c.minY - 1, width: bw + 2, height: bh + 2))
        }
        return out
    }

    private static func dilate(_ m: [UInt8], w: Int, h: Int) -> [UInt8] {
        var tmp = m
        for y in 0..<h {
            let r = y * w
            for x in 0..<w where m[r + x] == 1 {
                if x > 0 { tmp[r + x - 1] = 1 }
                if x < w - 1 { tmp[r + x + 1] = 1 }
            }
        }
        var out = tmp
        for y in 0..<h {
            let r = y * w
            for x in 0..<w where tmp[r + x] == 1 {
                if y > 0 { out[r - w + x] = 1 }
                if y < h - 1 { out[r + w + x] = 1 }
            }
        }
        return out
    }

    // MARK: - Composantes connexes

    private static func label(mask: [UInt8], w: Int, h: Int, target: UInt8, eight: Bool) -> ([Int32], [Comp]) {
        var labels = [Int32](repeating: -1, count: w * h)
        var comps: [Comp] = []
        var stack: [Int32] = []
        stack.reserveCapacity(8192)
        for start in 0..<(w * h) where mask[start] == target && labels[start] < 0 {
            let id = Int32(comps.count)
            var c = Comp()
            labels[start] = id
            stack.append(Int32(start))
            while let p32 = stack.popLast() {
                let p = Int(p32)
                let x = p % w, y = p / w
                c.area += 1
                if x < c.minX { c.minX = x }
                if x > c.maxX { c.maxX = x }
                if y < c.minY { c.minY = y }
                if y > c.maxY { c.maxY = y }
                let y0 = max(0, y - 1), y1 = min(h - 1, y + 1)
                let x0 = max(0, x - 1), x1 = min(w - 1, x + 1)
                for ny in y0...y1 {
                    for nx in x0...x1 {
                        if nx == x && ny == y { continue }
                        if !eight && nx != x && ny != y { continue }
                        let q = ny * w + nx
                        if mask[q] == target && labels[q] < 0 {
                            labels[q] = id
                            stack.append(Int32(q))
                        }
                    }
                }
            }
            comps.append(c)
        }
        return (labels, comps)
    }
}
