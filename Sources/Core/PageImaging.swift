import Foundation
import PDFKit
import AppKit

/// Correspondance entre l'espace page PDF (points, origine en bas à gauche) et l'image rendue
/// (pixels, origine en haut à gauche), en tenant compte de la rotation de la page.
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

    func toImage(_ p: CGPoint) -> CGPoint {
        let dx: CGFloat, dy: CGFloat
        switch rotation {
        case 90:  dx = p.y - box.minY; dy = p.x - box.minX
        case 180: dx = box.maxX - p.x; dy = p.y - box.minY
        case 270: dx = box.maxY - p.y; dy = box.maxX - p.x
        default:  dx = p.x - box.minX; dy = box.maxY - p.y
        }
        return CGPoint(x: dx * sx, y: dy * sy)
    }

    func toPage(_ q: CGPoint) -> CGPoint {
        let dx = q.x / sx, dy = q.y / sy
        switch rotation {
        case 90:  return CGPoint(x: box.minX + dy, y: box.minY + dx)
        case 180: return CGPoint(x: box.maxX - dx, y: box.minY + dy)
        case 270: return CGPoint(x: box.maxX - dy, y: box.maxY - dx)
        default:  return CGPoint(x: box.minX + dx, y: box.maxY - dy)
        }
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
