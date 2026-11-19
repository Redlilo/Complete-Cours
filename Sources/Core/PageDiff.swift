import Foundation
import PDFKit
import CoreGraphics

// Comparaison d'un PDF vierge et de sa version complétée : où de l'encre (ou du texte) a-t-elle été ajoutée ?
// Les deux pages sont rendues à la même taille ; un pixel est « ajouté » s'il est sombre dans la version complétée
// et qu'il n'y a rien de sombre à proximité (tolérance en pixels) dans la page vierge. Un léger décalage global
// (scan recentré, rééchantillonnage) est estimé puis compensé avant la comparaison.
// Tout est local : aucune IA, aucun réseau. Utilisé par CompletionStatus (état vide / partiel / complet) et par le banc.

/// Encre ajoutée dans une zone de la page vierge.
struct ZoneInk: Equatable {
    var zoneID: Int
    var page: Int
    var addedPixels: Int
    var area: Int
    /// Les deux pages ont pu être comparées (même format). Sinon `filled` vaut false et ne prouve rien.
    var comparable: Bool
    var filled: Bool
    var ratio: Double { area > 0 ? Double(addedPixels) / Double(area) : 0 }
}

/// Encre ajoutée en dehors de toute zone détectée : un trou probablement manqué par le détecteur.
struct InkBlob: Equatable {
    var page: Int
    var rect: CGRect       // espace page PDF
    var pixels: Int
}

struct PageDiffResult {
    var zones: [Int: ZoneInk] = [:]      // par identifiant de zone
    var blobs: [InkBlob] = []
    var pagesCompared = 0
    /// Total des pixels d'encre ajoutée sur les pages comparées (0 : la version complétée ressemble trait pour trait à la vierge).
    var addedTotal = 0
    var pagesSkipped: [Int] = []          // pages absentes d'un des deux PDF ou de format différent
}

enum PageDiff {
    struct Settings {
        /// Plus grand côté de l'image de comparaison (pixels).
        var longEdge: CGFloat = 1800
        /// Un pixel de la version complétée plus sombre que ça est de l'encre.
        var inkThreshold: UInt8 = 150
        /// Dans la page vierge, il faut que tout le voisinage soit plus clair que ça pour que l'encre soit « ajoutée ».
        var blankClear: UInt8 = 170
        /// Rayon de tolérance autour de chaque pixel de la page vierge (pixels).
        var tolerance = 3
        /// Décalage maximal recherché (pixels de l'image réduite de moitié).
        var maxShift = 6
        /// Une zone est remplie si au moins ce nombre de pixels est ajouté dedans…
        var minPixels = 20
        /// … et au moins cette part de sa surface.
        var minRatio = 0.0015
        /// Marge autour d'une zone (points) : une réponse peut déborder un peu de la ligne.
        var zoneMargin: CGFloat = 3
        /// Marge autour des zones (points) à l'intérieur de laquelle l'encre n'est pas « hors zone ».
        var outsideMargin: CGFloat = 8
        /// Encre hors zone : taille minimale d'un amas (pixels).
        var blobMinPixels = 80
        /// Au-delà de cette part de pixels sombres ajoutés, les pages ne se ressemblent plus : on ne conclut pas.
        var maxAddedShare = 0.5
    }
    nonisolated(unsafe) static var settings = Settings()

    // MARK: API

    /// Pour chaque zone de la page vierge (clé : `Zone.id`), l'encre ajoutée dans la version complétée.
    static func answeredZones(blank: PDFDocument, completed: PDFDocument, zones: [Zone]) -> [Int: ZoneInk] {
        compare(blank: blank, completed: completed, zones: zones).zones
    }

    static func answeredZones(blank: URL, completed: URL, zones: [Zone]) -> [Int: ZoneInk] {
        guard let b = PDFDocument(url: blank), let c = PDFDocument(url: completed) else { return [:] }
        return answeredZones(blank: b, completed: c, zones: zones)
    }

    /// Encre ajoutée hors de toute zone (marge comprise) : amas d'au moins `blobMinPixels` pixels.
    static func unexpectedInk(blank: PDFDocument, completed: PDFDocument, zones: [Zone]) -> [InkBlob] {
        compare(blank: blank, completed: completed, zones: zones).blobs
    }

    static func unexpectedInk(blank: URL, completed: URL, zones: [Zone]) -> [InkBlob] {
        guard let b = PDFDocument(url: blank), let c = PDFDocument(url: completed) else { return [] }
        return unexpectedInk(blank: b, completed: c, zones: zones)
    }

    /// Les deux résultats en un seul passage (un seul rendu des pages).
    static func compare(blank: PDFDocument, completed: PDFDocument, zones: [Zone]) -> PageDiffResult {
        var out = PageDiffResult()
        let byPage = Dictionary(grouping: zones, by: { $0.page })
        for i in 0..<blank.pageCount {
            let pageZones = byPage[i] ?? []
            guard i < completed.pageCount, let bp = blank.page(at: i), let cp = completed.page(at: i),
                  let mask = addedInk(blank: bp, completed: cp) else {
                out.pagesSkipped.append(i)
                for z in pageZones { out.zones[z.id] = ZoneInk(zoneID: z.id, page: i, addedPixels: 0, area: 0, comparable: false, filled: false) }
                continue
            }
            out.pagesCompared += 1
            out.addedTotal += mask.addedTotal
            let s = settings
            var covered: [CGRect] = []     // zones élargies, en pixels
            for z in pageZones {
                let r = mask.pixelRect(z.rect, margin: s.zoneMargin)
                let (n, area) = mask.count(in: r)
                out.zones[z.id] = ZoneInk(zoneID: z.id, page: i, addedPixels: n, area: area, comparable: true,
                                          filled: n >= s.minPixels && Double(n) >= s.minRatio * Double(area))
                covered.append(mask.pixelRect(z.rect, margin: s.outsideMargin))
            }
            for b in mask.blobs(excluding: covered, minPixels: s.blobMinPixels) {
                out.blobs.append(InkBlob(page: i, rect: mask.geometry.toPage(rect: b.rect), pixels: b.pixels))
            }
        }
        return out
    }

    // MARK: Masque d'encre ajoutée d'une page

    struct AddedMask {
        let width: Int
        let height: Int
        var added: [UInt8]                 // 1 = encre ajoutée
        let geometry: PageGeometry
        var shift: (dx: Int, dy: Int)
        var addedTotal: Int

        func pixelRect(_ pageRect: CGRect, margin: CGFloat) -> CGRect {
            geometry.toImage(rect: pageRect.insetBy(dx: -margin, dy: -margin))
        }

        /// (pixels ajoutés, surface) dans un rectangle en pixels.
        func count(in r: CGRect) -> (Int, Int) {
            let x0 = max(0, Int(r.minX.rounded(.down))), x1 = min(width, Int(r.maxX.rounded(.up)))
            let y0 = max(0, Int(r.minY.rounded(.down))), y1 = min(height, Int(r.maxY.rounded(.up)))
            guard x1 > x0, y1 > y0 else { return (0, 0) }
            var n = 0
            for y in y0..<y1 {
                let row = y * width
                for x in x0..<x1 { n += Int(added[row + x]) }
            }
            return (n, (x1 - x0) * (y1 - y0))
        }

        /// Amas d'encre ajoutée hors des rectangles `excluding` (pixels). Regroupe les lettres proches.
        func blobs(excluding: [CGRect], minPixels: Int) -> [(rect: CGRect, pixels: Int)] {
            var mask = added
            for r in excluding {
                let x0 = max(0, Int(r.minX.rounded(.down))), x1 = min(width, Int(r.maxX.rounded(.up)))
                let y0 = max(0, Int(r.minY.rounded(.down))), y1 = min(height, Int(r.maxY.rounded(.up)))
                guard x1 > x0, y1 > y0 else { continue }
                for y in y0..<y1 { for x in x0..<x1 { mask[y * width + x] = 0 } }
            }
            let cell = 10
            let cw = (width + cell - 1) / cell, ch = (height + cell - 1) / cell
            var cellCount = [Int](repeating: 0, count: cw * ch)
            for y in 0..<height {
                let row = y * width
                for x in 0..<width where mask[row + x] != 0 { cellCount[(y / cell) * cw + x / cell] += 1 }
            }
            // cellules actives, puis fusion des voisines (écart de 1 cellule ≈ 10 px permis)
            var seen = [Bool](repeating: false, count: cw * ch)
            var result: [(CGRect, Int)] = []
            for start in 0..<(cw * ch) where cellCount[start] >= 2 && !seen[start] {
                var stack = [start]; seen[start] = true
                var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0, total = 0
                while let c = stack.popLast() {
                    let cx = c % cw, cy = c / cw
                    total += cellCount[c]
                    minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy)
                    for dy in -2...2 { for dx in -2...2 {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, ny >= 0, nx < cw, ny < ch else { continue }
                        let n = ny * cw + nx
                        if !seen[n] && cellCount[n] >= 2 { seen[n] = true; stack.append(n) }
                    } }
                }
                if total >= minPixels {
                    result.append((CGRect(x: minX * cell, y: minY * cell, width: (maxX - minX + 1) * cell, height: (maxY - minY + 1) * cell), total))
                }
            }
            return result.sorted { $0.1 > $1.1 }
        }
    }

    /// Masque de l'encre ajoutée entre deux pages ; nil si elles n'ont pas le même format ou sont trop différentes.
    static func addedInk(blank: PDFPage, completed: PDFPage) -> AddedMask? {
        let s = settings
        guard let (bImg, geo) = PageImaging.render(page: blank, longEdge: s.longEdge),
              let (cImg, cGeo) = PageImaging.render(page: completed, longEdge: s.longEdge) else { return nil }
        let ba = geo.displaySize.width / max(geo.displaySize.height, 1), ca = cGeo.displaySize.width / max(cGeo.displaySize.height, 1)
        guard abs(ba - ca) / ba < 0.04 else { return nil }
        let w = bImg.width, h = bImg.height
        let bGray = PageImaging.gray(bImg).data
        let cGray = grayResized(cImg, width: w, height: h)

        let shift = estimateShift(blank: bGray, completed: cGray, width: w, height: h, maxShift: s.maxShift)
        let shifted = shift == (0, 0) ? bGray : shiftedCopy(bGray, width: w, height: h, dx: shift.0, dy: shift.1)
        let clear = minFilter(shifted, width: w, height: h, radius: s.tolerance)

        var added = [UInt8](repeating: 0, count: w * h)
        var total = 0, dark = 0
        cGray.withUnsafeBufferPointer { c in
            clear.withUnsafeBufferPointer { b in
                for i in 0..<(w * h) where c[i] < s.inkThreshold {
                    dark += 1
                    if b[i] >= s.blankClear { added[i] = 1; total += 1 }
                }
            }
        }
        if dark > 0, Double(total) > s.maxAddedShare * Double(dark), total > 2000 { return nil }
        return AddedMask(width: w, height: h, added: added, geometry: geo, shift: shift, addedTotal: total)
    }

    // MARK: Outils d'image

    static func grayResized(_ img: CGImage, width: Int, height: Int) -> [UInt8] {
        var data = [UInt8](repeating: 255, count: width * height)
        data.withUnsafeMutableBytes { buf in
            if let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return data
    }

    /// Copie de `a` décalée : pixel (x, y) du résultat = pixel (x + dx, y + dy) de `a` (blanc hors de l'image).
    static func shiftedCopy(_ a: [UInt8], width w: Int, height h: Int, dx: Int, dy: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            let sy = y + dy
            guard sy >= 0, sy < h else { continue }
            for x in 0..<w {
                let sx = x + dx
                if sx >= 0, sx < w { out[y * w + x] = a[sy * w + sx] }
            }
        }
        return out
    }

    /// Minimum sur une fenêtre carrée de rayon `radius` (filtre séparable).
    static func minFilter(_ a: [UInt8], width w: Int, height h: Int, radius r: Int) -> [UInt8] {
        guard r > 0 else { return a }
        var tmp = a
        a.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w {
                        var m: UInt8 = 255
                        for k in max(0, x - r)...min(w - 1, x + r) { m = min(m, src[row + k]) }
                        dst[row + x] = m
                    }
                }
            }
        }
        var out = tmp
        tmp.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let y0 = max(0, y - r), y1 = min(h - 1, y + r)
                    for x in 0..<w {
                        var m: UInt8 = 255
                        for k in y0...y1 { m = min(m, src[k * w + x]) }
                        dst[y * w + x] = m
                    }
                }
            }
        }
        return out
    }

    /// Décalage entier (pixels de l'image pleine) qui aligne au mieux la page vierge sur la page complétée :
    /// recherche sur images réduites de moitié ; on ne décale que si le gain est net (≥ 10 %).
    static func estimateShift(blank: [UInt8], completed: [UInt8], width: Int, height: Int, maxShift m: Int) -> (Int, Int) {
        let hw = width / 2, hh = height / 2
        guard m > 0, hw > 4 * m, hh > 4 * m else { return (0, 0) }
        func half(_ a: [UInt8]) -> [UInt8] {
            var o = [UInt8](repeating: 255, count: hw * hh)
            for y in 0..<hh { for x in 0..<hw {
                let i = 2 * y * width + 2 * x
                o[y * hw + x] = UInt8((Int(a[i]) + Int(a[i + 1]) + Int(a[i + width]) + Int(a[i + width + 1])) / 4)
            } }
            return o
        }
        let c = half(completed)
        let bDark = half(blank).map { $0 < 170 ? UInt8(0) : UInt8(255) }
        let bNear = minFilter(bDark, width: hw, height: hh, radius: 1)    // 0 = du sombre à ≤ 1 px
        var darkC: [Int] = []
        for i in 0..<(hw * hh) where c[i] < 150 { darkC.append(i) }
        guard darkC.count > 200 else { return (0, 0) }
        func score(_ dx: Int, _ dy: Int) -> Int {
            var n = 0
            for i in darkC {
                let x = i % hw + dx, y = i / hw + dy
                if x < 0 || y < 0 || x >= hw || y >= hh { n += 1; continue }
                if bNear[y * hw + x] != 0 { n += 1 }
            }
            return n
        }
        let s0 = score(0, 0)
        guard s0 > 100 else { return (0, 0) }
        var best = (0, 0), bestScore = s0
        for dy in -m...m { for dx in -m...m where dx != 0 || dy != 0 {
            let sc = score(dx, dy)
            if sc < bestScore { bestScore = sc; best = (dx, dy) }
        } }
        return Double(bestScore) < 0.9 * Double(s0) ? (best.0 * 2, best.1 * 2) : (0, 0)
    }
}
