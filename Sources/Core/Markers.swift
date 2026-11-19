import Foundation
import PDFKit
import AppKit
import CoreText

/// Image d'une page avec le numéro de chaque zone dessiné à l'intérieur de la zone
/// (à l'intérieur : jamais sur le texte imprimé). Sert aux IA qui voient les images.
enum MarkedImage {
    private static let palette: [CGColor] = [
        CGColor(red: 0.85, green: 0.10, blue: 0.10, alpha: 1),
        CGColor(red: 0.10, green: 0.35, blue: 0.90, alpha: 1),
        CGColor(red: 0.05, green: 0.60, blue: 0.20, alpha: 1),
        CGColor(red: 0.90, green: 0.45, blue: 0.00, alpha: 1),
        CGColor(red: 0.60, green: 0.15, blue: 0.75, alpha: 1),
    ]

    static func make(page: PDFPage, zones: [Zone], longEdge: CGFloat = 1568) -> Data? {
        guard let (img, geo) = PageImaging.render(page: page, longEdge: longEdge) else { return nil }
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let H = CGFloat(h)
        ctx.setLineWidth(2)

        for z in zones {
            let color = palette[(max(z.number, 1) - 1) % palette.count]
            ctx.setStrokeColor(color)
            ctx.setFillColor(color.copy(alpha: 0.13)!)
            var labelOrigin = CGPoint.zero
            var labelRoom: CGFloat = 20

            if let b = z.box {
                let r = geo.toImage(rect: b)                       // origine en haut à gauche
                let cg = CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
                ctx.fill(cg); ctx.stroke(cg)
                labelOrigin = CGPoint(x: cg.minX + 2, y: cg.maxY - 2)    // coin haut-gauche
                labelRoom = cg.height - 4
            } else {
                for (i, l) in z.lines.enumerated() {
                    let a = geo.toImage(CGPoint(x: l.x0, y: l.y))
                    let b = geo.toImage(CGPoint(x: l.x1, y: l.yEnd))
                    let band = max(z.textHeight * 1.35 * geo.scale, 16)
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: a.x, y: H - a.y))
                    path.addLine(to: CGPoint(x: b.x, y: H - b.y))
                    path.addLine(to: CGPoint(x: b.x, y: H - b.y + band))
                    path.addLine(to: CGPoint(x: a.x, y: H - a.y + band))
                    path.closeSubpath()
                    ctx.addPath(path); ctx.fillPath()
                    ctx.addPath(path); ctx.strokePath()
                    if i == 0 { labelOrigin = CGPoint(x: a.x + 2, y: H - a.y + band - 1); labelRoom = band - 2 }
                }
            }
            drawLabel("\(z.number)", at: labelOrigin, room: labelRoom, color: color, in: ctx)
        }
        guard let out = ctx.makeImage() else { return nil }
        return PageImaging.jpegData(out, quality: 0.82)
    }

    /// Petit cadre coloré avec le numéro en blanc, dont le coin haut-gauche est `at` (repère CoreGraphics).
    private static func drawLabel(_ text: String, at p: CGPoint, room: CGFloat, color: CGColor, in ctx: CGContext) {
        let fontSize = min(18, max(11, room * 0.75))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let tb = CTLineGetBoundsWithOptions(line, [])
        let padX: CGFloat = 4, padY: CGFloat = 2
        let box = CGRect(x: p.x, y: p.y - tb.height - 2 * padY, width: tb.width + 2 * padX, height: tb.height + 2 * padY)
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.fillPath()
        ctx.textPosition = CGPoint(x: box.minX + padX - tb.minX, y: box.minY + padY - tb.minY)
        CTLineDraw(line, ctx)
    }
}
