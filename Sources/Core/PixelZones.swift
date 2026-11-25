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
    var gridBoxes: [CGRect] = []         // papier pointé (déjà dans `boxes`) : cadre d'un schéma à compléter
    var shortMarks: [PixelLine] = []     // courts tirets au pied du texte (« __ » d'un scan) : réponse d'un mot ou d'un signe
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

    static var attachedRun: CGFloat = 0.14
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

        let (fLabels, fComps) = label(mask: faintInk, w: w, h: h, target: 1, eight: true)
        do {
            // pointillés pâles (scan clair) : seuil plus strict que pour l'encre franche
            for f in dottedLines(comps: fComps, dpi: dpi, minDots: 14, minLength: Int(1.0 * dpi)) {
                let dup = lines.contains { l in
                    abs(l.y - f.y) <= 4 && min(l.x1, f.x1) - max(l.x0, f.x0) > Int(0.5 * Double(f.x1 - f.x0))
                }
                if !dup { lines.append(f) }
            }
        }
        let faintLines = solidLines(ink: faintInk, w: w, h: h, minLen: Int(1.0 * dpi), maxThick: 3)
        for f in faintLines {
            let dup = lines.contains { l in
                abs(l.y - f.y) <= 4 && min(l.x1, f.x1) - max(l.x0, f.x0) > Int(0.5 * Double(f.x1 - f.x0))
            }
            if !dup { lines.append(f) }
        }

        // un même trait peut sortir en plusieurs morceaux (scan légèrement penché, trait interrompu) : on les recolle
        lines = mergeCollinear(lines, gap: Int(0.08 * dpi))

        // papier pointé (grille de points d'un schéma à compléter) : ce ne sont pas des lignes d'écriture, mais un seul cadre
        var gridBoxes: [CGRect] = []
        do {
            let (rest, found) = extractDotGrids(lines, dpi: dpi)
            lines = rest
            gridBoxes = found
        }

        // régions blanches fermées par un trait, y compris les traits pâles (cadres arrondis, cellules, cartouches) :
        // leurs bords ne sont pas des lignes d'écriture, et celles qui sont vides sont des cases à remplir
        var regions: [CGRect] = []
        var faintBoxes: [CGRect] = []
        do {
            var faintClean = [UInt8](repeating: 0, count: n)
            for i in 0..<n where faintInk[i] == 1 {
                let l = Int(fLabels[i])
                if l >= 0 && fComps[l].area >= 6 { faintClean[i] = 1 }
            }
            let closedFaint = dilate(faintClean, w: w, h: h)
            let whites = components4(mask: closedFaint, w: w, h: h, target: 0)
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

        for gb in gridBoxes {
            let dup = boxes.contains { b in
                let inter = b.intersection(gb)
                return !inter.isNull && inter.width * inter.height > 0.5 * min(b.width * b.height, gb.width * gb.height)
            }
            if !dup { boxes.append(gb) }
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
            // plus long segment vertical continu (à ±3 px de x) dans une fenêtre : un bord de cadre ou de tableau est long,
            // la lettre qui touche le bout d'un tiret « inline » (Le n______ bourgeois) ne dépasse pas la hauteur d'une ligne
            func run(_ rows: ClosedRange<Int>) -> Int {
                var best = 0, cur = 0
                for y in rows where y >= 0 && y < h {
                    var any = false
                    for xx in max(0, x - 3)...min(w - 1, x + 3) where faintInk[y * w + xx] == 1 { any = true; break }
                    if any { cur += 1; best = max(best, cur) } else { cur = 0 }
                }
                return best
            }
            let need = max(8, Int(attachedRun * dpi))
            let span = need + 4
            return run((yTop - span)...(yTop - 2)) >= need || run((yBot + 2)...(yBot + span)) >= need
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


        // --- 3b. courts tirets posés sur la ligne de base d'un texte (« ... arrivé __ Oh ... ») : un signe ou un mot à écrire
        var marks: [Raw] = []
        do {
            let minW = max(7, Int(0.11 * dpi)), maxW = Int(0.5 * dpi)
            let maxH = max(3, Int(0.03 * dpi)) + 1
            let near = Int(0.22 * dpi), above = max(6, Int(0.10 * dpi))
            let letters = inkComps.filter { c in
                let cw = c.maxX - c.minX + 1, ch = c.maxY - c.minY + 1
                return ch >= Int(0.04 * dpi) && ch <= Int(0.2 * dpi) && cw <= Int(0.2 * dpi) && c.area >= 6
            }
            for c in inkComps {
                let cw = c.maxX - c.minX + 1, ch = c.maxY - c.minY + 1
                guard cw >= minW, cw <= maxW, ch <= maxH, cw >= 4 * ch, c.area * 10 >= cw * ch * 7 else { continue }
                let y = (c.minY + c.maxY) / 2
                guard y > marginY, y < h - marginY else { continue }
                // rien au-dessus (sinon : mot souligné, trait d'un tableau) ni en dessous
                let up = columnsWithInk(c.minX, c.maxX, c.minY - above, c.minY - 2)
                let down = columnsWithInk(c.minX, c.maxX, c.maxY + 3, c.maxY + above)
                guard up.cols * 10 <= up.total, down.cols * 10 <= down.total else { continue }
                // des lettres à gauche ou à droite, dont le pied est à la hauteur du tiret (ligne de base)
                var left = false, right = false
                for l in letters where l.maxY >= c.minY - Int(0.05 * dpi) && l.maxY <= c.maxY + Int(0.03 * dpi) {
                    if l.maxX < c.minX && c.minX - l.maxX <= near { left = true }
                    if l.minX > c.maxX && l.minX - c.maxX <= near { right = true }
                }
                guard left || right else { continue }
                marks.append(Raw(x0: c.minX, x1: c.maxX, y: y, yTop: c.minY, dotted: false))
            }
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
        result.shortMarks = marks.map(back)
        result.lineGroups = groups.map { $0.map(back) }
        result.boxes = boxes.map(backBox)
        result.gridBoxes = gridBoxes.map(backBox)
        return result
    }

    /// Fermeture morphologique (carré de côté 2r+1) moins l'image : fait ressortir les traits fins sombres sur fond clair.
    private static func blackTopHat(_ g: [UInt8], w: Int, h: Int, radius r: Int) -> [UInt8] {
        let n = w * h
        var a = [UInt8](repeating: 0, count: n)
        var b = [UInt8](repeating: 0, count: n)
        var out = [UInt8](repeating: 0, count: n)
        g.withUnsafeBufferPointer { gp in
        a.withUnsafeMutableBufferPointer { ap in
        b.withUnsafeMutableBufferPointer { bp in
        out.withUnsafeMutableBufferPointer { op in
            // dilatation (maximum) : horizontale puis verticale ; érosion (minimum) : idem.
            // Boucles sur des décalages (accès contigus, vectorisables) : fenêtre tronquée aux bords, comme avant.
            morph(gp.baseAddress!, ap.baseAddress!, w: w, h: h, r: r, horizontal: true, maximum: true)
            morph(UnsafePointer(ap.baseAddress!), bp.baseAddress!, w: w, h: h, r: r, horizontal: false, maximum: true)
            morph(UnsafePointer(bp.baseAddress!), ap.baseAddress!, w: w, h: h, r: r, horizontal: true, maximum: false)
            morph(UnsafePointer(ap.baseAddress!), bp.baseAddress!, w: w, h: h, r: r, horizontal: false, maximum: false)
            for i in 0..<n {
                let d = Int(bp[i]) - Int(gp[i])
                op[i] = d > 0 ? UInt8(min(d, 255)) : 0
            }
        }}}}
        return out
    }

    /// Maximum (ou minimum) glissant sur 2r+1 pixels, horizontal ou vertical, fenêtre tronquée aux bords.
    private static func morph(_ src: UnsafePointer<UInt8>, _ dst: UnsafeMutablePointer<UInt8>, w: Int, h: Int, r: Int,
                              horizontal: Bool, maximum: Bool) {
        let n = w * h
        dst.update(repeating: maximum ? 0 : 255, count: n)
        if horizontal {
            for y in 0..<h {
                let s = src + y * w, d = dst + y * w
                for off in -r...r {
                    let x0 = max(0, -off), x1 = min(w, w - off)
                    guard x1 > x0 else { continue }
                    if maximum { for x in x0..<x1 { let v = s[x + off]; if v > d[x] { d[x] = v } } }
                    else { for x in x0..<x1 { let v = s[x + off]; if v < d[x] { d[x] = v } } }
                }
            }
        } else {
            for y in 0..<h {
                let d = dst + y * w
                for yy in max(0, y - r)...min(h - 1, y + r) {
                    let s = src + yy * w
                    if maximum { for x in 0..<w { let v = s[x]; if v > d[x] { d[x] = v } } }
                    else { for x in 0..<w { let v = s[x]; if v < d[x] { d[x] = v } } }
                }
            }
        }
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

    /// Papier pointé (grille de points d'un schéma à compléter) : au moins 10 rangées pointillées espacées d'un pas
    /// régulier et serré (moins de 0,12 pouce, loin des lignes d'écriture) ; les rangées sont souvent coupées en
    /// morceaux par les dessins. Retourne les lignes restantes et un cadre pour la grille.
    private static func extractDotGrids(_ lines: [Raw], dpi: CGFloat) -> ([Raw], [CGRect]) {
        let dotted = lines.indices.filter { lines[$0].dotted }
        guard dotted.count >= 10 else { return (lines, []) }
        // rangées : ordonnées regroupées à 4 px près
        let ys = dotted.map { lines[$0].y }.sorted()
        var centers: [Double] = []
        var cur: [Int] = [ys[0]]
        for y in ys.dropFirst() {
            if y - cur.last! <= 4 { cur.append(y) } else { centers.append(Double(cur.reduce(0, +)) / Double(cur.count)); cur = [y] }
        }
        centers.append(Double(cur.reduce(0, +)) / Double(cur.count))
        guard centers.count >= 10 else { return (lines, []) }
        let lo = 0.04 * Double(dpi), hi = 0.12 * Double(dpi)
        var gaps: [Double] = []
        for i in 1..<centers.count { let g = centers[i] - centers[i - 1]; if g >= lo && g <= hi { gaps.append(g) } }
        guard gaps.count >= 9 else { return (lines, []) }
        let pitch = gaps.sorted()[gaps.count / 2]
        func regularGap(_ g: Double) -> Bool {
            let m = (g / pitch).rounded()
            return m >= 1 && m <= 3 && abs(g - m * pitch) <= max(3.0, 0.12 * pitch)
        }
        var regular: [Double] = []
        for i in centers.indices {
            let before = i > 0 && regularGap(centers[i] - centers[i - 1])
            let after = i + 1 < centers.count && regularGap(centers[i + 1] - centers[i])
            if before || after { regular.append(centers[i]) }
        }
        guard regular.count >= 10, let top = regular.first, let bottom = regular.last else { return (lines, []) }
        var remove = Set<Int>()
        var x0 = Int.max, x1 = 0
        for k in dotted {
            let l = lines[k]
            if regular.contains(where: { abs($0 - Double(l.y)) <= 4 }) {
                remove.insert(k); x0 = min(x0, l.x0); x1 = max(x1, l.x1)
            }
        }
        guard remove.count >= 10, x1 - x0 > Int(1.0 * dpi) else { return (lines, []) }
        let box = CGRect(x: x0, y: Int(top), width: x1 - x0, height: Int(bottom - top))
        return (lines.indices.filter { !remove.contains($0) }.map { lines[$0] }, [box])
    }

    // MARK: - Pointillés (suite)

    private static func dottedLines(comps: [Comp], dpi: CGFloat, minDots: Int = 8, minLength: Int? = nil) -> [Raw] {
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
        for c in chains where c.xs.count >= minDots {
            let x0 = c.xs.first!.0, x1 = c.xs.last!.1
            guard x1 - x0 + 1 >= (minLength ?? Int(0.5 * dpi)) else { continue }
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
        let whites = components4(mask: closed, w: w, h: h, target: 0)

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

    /// Composantes 4-connexes de `target` (mêmes `Comp`, dans le même ordre que `label(..., eight: false).1`), sans
    /// image d'étiquettes : remplissage par segments horizontaux, bien plus rapide sur les grandes zones blanches.
    private static func components4(mask: [UInt8], w: Int, h: Int, target: UInt8) -> [Comp] {
        var seen = mask            // les pixels déjà traités passent à 2 (jamais une valeur cible : 0 ou 1)
        var comps: [Comp] = []
        var stack: [Int32] = []
        stack.reserveCapacity(4096)
        seen.withUnsafeMutableBufferPointer { sp in
            for start in 0..<(w * h) where sp[start] == target {
                var c = Comp()
                stack.append(Int32(start))
                while let p32 = stack.popLast() {
                    let p = Int(p32)
                    guard sp[p] == target else { continue }
                    let y = p / w
                    let row = y * w
                    var l = p - row, r = l
                    while l > 0 && sp[row + l - 1] == target { l -= 1 }
                    while r < w - 1 && sp[row + r + 1] == target { r += 1 }
                    for x in l...r { sp[row + x] = 2 }
                    c.area += r - l + 1
                    if l < c.minX { c.minX = l }
                    if r > c.maxX { c.maxX = r }
                    if y < c.minY { c.minY = y }
                    if y > c.maxY { c.maxY = y }
                    for ny in [y - 1, y + 1] where ny >= 0 && ny < h {
                        let nrow = ny * w
                        var x = l
                        while x <= r {
                            if sp[nrow + x] == target {
                                stack.append(Int32(nrow + x))
                                while x <= r && sp[nrow + x] == target { x += 1 }
                            } else { x += 1 }
                        }
                    }
                }
                comps.append(c)
            }
        }
        return comps
    }

    private static func label(mask: [UInt8], w: Int, h: Int, target: UInt8, eight: Bool) -> ([Int32], [Comp]) {
        var labels = [Int32](repeating: -1, count: w * h)
        var comps: [Comp] = []
        var stack: [Int32] = []
        stack.reserveCapacity(8192)
        mask.withUnsafeBufferPointer { mp in
        labels.withUnsafeMutableBufferPointer { lp in
            for start in 0..<(w * h) where mp[start] == target && lp[start] < 0 {
                let id = Int32(comps.count)
                var c = Comp()
                lp[start] = id
                stack.append(Int32(start))
                while let p32 = stack.popLast() {
                    let p = Int(p32)
                    let y = p / w
                    let x = p - y * w
                    c.area += 1
                    if x < c.minX { c.minX = x }
                    if x > c.maxX { c.maxX = x }
                    if y < c.minY { c.minY = y }
                    if y > c.maxY { c.maxY = y }
                    let y0 = max(0, y - 1), y1 = min(h - 1, y + 1)
                    let x0 = max(0, x - 1), x1 = min(w - 1, x + 1)
                    for ny in y0...y1 {
                        let rowBase = ny * w
                        for nx in x0...x1 {
                            if nx == x && ny == y { continue }
                            if !eight && nx != x && ny != y { continue }
                            let q = rowBase + nx
                            if mp[q] == target && lp[q] < 0 {
                                lp[q] = id
                                stack.append(Int32(q))
                            }
                        }
                    }
                }
                comps.append(c)
            }
        }}
        return (labels, comps)
    }
}
