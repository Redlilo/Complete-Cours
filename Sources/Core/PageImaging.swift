import Foundation
import PDFKit
import AppKit

/// Correspondance entre l'ESPACE DES ZONES et l'image rendue (pixels, origine en haut à gauche).
///
/// Espace des zones = la page telle qu'elle s'affiche, rotation `/Rotate` appliquée, en points, origine en bas à gauche.
/// Pour une page non tournée, c'est exactement l'espace page PDF (origine du cropBox comprise). Pour une page tournée,
/// l'origine est le coin bas-gauche de la page affichée. Les annotations, champs de formulaire et sélections de texte
/// de PDFKit restent, eux, dans l'espace page brut : `zoneRect(fromPage:)` et `pageRect(fromZone:)` font le passage.
struct PageGeometry {
    let box: CGRect
    let rotation: Int
    let pixelSize: CGSize

    var displaySize: CGSize {
        rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }
    var sx: CGFloat { pixelSize.width / displaySize.width }
    var sy: CGFloat { pixelSize.height / displaySize.height }
    /// Pixels par point.
    var scale: CGFloat { sx }
    /// Origine de l'espace des zones.
    var origin: CGPoint { rotation == 0 ? box.origin : .zero }
    /// L'espace des zones (les conversions de cette structure en sont déjà : alias pour la lisibilité).
    var zoneSpace: PageGeometry { self }

    /// Géométrie « à l'échelle 1 » d'une page, pour passer de l'espace brut à l'espace des zones sans image.
    init(page: PDFPage) {
        let box = page.bounds(for: .cropBox)
        let rot = ((page.rotation % 360) + 360) % 360
        self.box = box
        self.rotation = rot
        self.pixelSize = rot % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    init(box: CGRect, rotation: Int, pixelSize: CGSize) {
        self.box = box; self.rotation = rotation; self.pixelSize = pixelSize
    }

    /// Point de l'espace des zones -> pixel de l'image.
    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) * sx, y: (origin.y + displaySize.height - p.y) * sy)
    }

    /// Pixel de l'image -> point de l'espace des zones.
    func toPage(_ q: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + q.x / sx, y: origin.y + displaySize.height - q.y / sy)
    }

    func toImage(rect r: CGRect) -> CGRect {
        let a = toImage(CGPoint(x: r.minX, y: r.minY))
        let b = toImage(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    func toPage(rect r: CGRect) -> CGRect {
        let a = toPage(CGPoint(x: r.minX, y: r.minY))
        let b = toPage(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Espace page brut <-> espace des zones

    /// Point de l'espace page brut (annotations, sélections PDFKit) -> espace des zones.
    func zonePoint(fromPage p: CGPoint) -> CGPoint {
        switch rotation {
        case 90:  return CGPoint(x: p.y - box.minY, y: box.width - (p.x - box.minX))
        case 180: return CGPoint(x: box.maxX - p.x, y: box.maxY - p.y)
        case 270: return CGPoint(x: box.maxY - p.y, y: p.x - box.minX)
        default:  return p
        }
    }

    /// Point de l'espace des zones -> espace page brut.
    func pagePoint(fromZone z: CGPoint) -> CGPoint {
        switch rotation {
        case 90:  return CGPoint(x: box.minX + box.width - z.y, y: box.minY + z.x)
        case 180: return CGPoint(x: box.maxX - z.x, y: box.maxY - z.y)
        case 270: return CGPoint(x: box.minX + z.y, y: box.maxY - z.x)
        default:  return z
        }
    }

    func zoneRect(fromPage r: CGRect) -> CGRect {
        let a = zonePoint(fromPage: CGPoint(x: r.minX, y: r.minY)), b = zonePoint(fromPage: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    func pageRect(fromZone r: CGRect) -> CGRect {
        let a = pagePoint(fromZone: CGPoint(x: r.minX, y: r.minY)), b = pagePoint(fromZone: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

struct GrayBitmap {
    let width: Int
    let height: Int
    var data: [UInt8]
}

enum PageImaging {
    /// Rend une page (annotations comprises) en image RVB dont le plus grand côté fait `longEdge` pixels.
    static func render(page: PDFPage, longEdge: CGFloat) -> (CGImage, PageGeometry)? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 1, box.height > 1 else { return nil }
        let rot = ((page.rotation % 360) + 360) % 360
        let dw = rot % 180 == 0 ? box.width : box.height
        let dh = rot % 180 == 0 ? box.height : box.width
        let scale = longEdge / max(dw, dh)
        let pw = max(1, Int((dw * scale).rounded()))
        let ph = max(1, Int((dh * scale).rounded()))

        let thumb = page.thumbnail(of: CGSize(width: pw, height: ph), for: .cropBox)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let full = CGRect(x: 0, y: 0, width: pw, height: ph)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(full)
        var proposed = full
        guard let cg = thumb.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: full)
        guard let out = ctx.makeImage() else { return nil }
        return (out, PageGeometry(box: box, rotation: rot, pixelSize: CGSize(width: pw, height: ph)))
    }

    static func gray(_ img: CGImage) -> GrayBitmap {
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 255, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        data.withUnsafeMutableBytes { buf in
            if let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: w, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return GrayBitmap(width: w, height: h, data: data)
    }

    static func jpegData(_ img: CGImage, quality: CGFloat = 0.85) -> Data? {
        let rep = NSBitmapImageRep(cgImage: img)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    static func pngData(_ img: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}
