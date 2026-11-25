import Foundation
import PDFKit
import AppKit
import CoreText

// Images d'une demande de schéma : le CADRE de la zone (avec une marge) sous une grille numérotée, que Claude lit pour
// placer les symboles en unités de grille. La grille couvre exactement la zone : (0, 0) = coin haut-gauche de `box`,
// (largeurGrille, hauteurGrille) = coin bas-droit. Le dessin final (SchemaRenderer) utilise la même correspondance.

enum SchemaGrille {
    static let hauteurStandard = 12.0
    static let largeurMini = 6.0
    static let largeurMaxi = 48.0
    static let margeRelative: CGFloat = 0.08
    static let largeurMaxPixels: CGFloat = 1400
    static let hauteurMaxPixels: CGFloat = 1800

    /// Taille de la grille d'une zone : 12 unités de haut, largeur proportionnelle (arrondie à 0,5, entre 6 et 48).
    static func dimensionsGrille(pour box: CGRect) -> (largeur: Double, hauteur: Double) {
        guard box.width > 0, box.height > 0 else { return (largeurMini, hauteurStandard) }
        let brut = hauteurStandard * Double(box.width / box.height)
        let arrondi = (brut * 2).rounded() / 2
        return (min(largeurMaxi, max(largeurMini, arrondi)), hauteurStandard)
    }

    /// Les deux ensembles utiles à une demande : dimensions et image du cadre. nil si la page ne peut pas être rendue.
    static func demande(page: PDFPage, box: CGRect) -> (largeur: Double, hauteur: Double, cadreJPEG: Data)? {
        let d = dimensionsGrille(pour: box)
        guard let jpeg = cadreAvecGrille(page: page, box: box, largeurGrille: d.largeur, hauteurGrille: d.hauteur) else { return nil }
        return (d.largeur, d.hauteur, jpeg)
    }

    /// Image JPEG (qualité 0,8) du cadre `box` (espace des zones : page affichée, points, origine en bas à gauche) entouré
    /// d'une marge de 8 %, avec la grille : lignes fines toutes les unités, plus marquées toutes les 5, chiffres sur les quatre bords.
    static func cadreAvecGrille(page: PDFPage, box: CGRect, largeurGrille: Double, hauteurGrille: Double) -> Data? {
        guard box.width > 1, box.height > 1, largeurGrille > 0, hauteurGrille > 0 else { return nil }
        let marge = CGSize(width: box.width * margeRelative, height: box.height * margeRelative)
        let etendu = box.insetBy(dx: -marge.width, dy: -marge.height)

        // Résolution : cadre étendu d'au plus 1400 × 1800 pixels ; la page entière est rendue à cette échelle (plafonnée).
        let pxParPoint = min(largeurMaxPixels / etendu.width, hauteurMaxPixels / etendu.height)
        let geo0 = PageGeometry(page: page)
        let grandCote = max(geo0.displaySize.width, geo0.displaySize.height)
        let cote = min(5000, max(200, pxParPoint * grandCote))
        guard let (pageImage, geo) = PageImaging.render(page: page, longEdge: cote) else { return nil }

        let largeur = max(1, Int((etendu.width * geo.scale).rounded()))
        let hauteur = max(1, Int((etendu.height * geo.scale).rounded()))
        guard let ctx = CGContext(data: nil, width: largeur, height: hauteur, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: largeur, height: hauteur))

        // Coin haut-gauche du cadre étendu, en pixels de l'image de la page (origine en haut à gauche).
        let coin = geo.toImage(CGPoint(x: etendu.minX, y: etendu.maxY))
        let H = CGFloat(hauteur)
        ctx.interpolationQuality = .high
        ctx.draw(pageImage, in: CGRect(x: -coin.x, y: H + coin.y - CGFloat(pageImage.height),
                                       width: CGFloat(pageImage.width), height: CGFloat(pageImage.height)))

        // La zone elle-même, en pixels du canevas (origine en haut à gauche).
        let hautGauche = geo.toImage(CGPoint(x: box.minX, y: box.maxY))
        let basDroit = geo.toImage(CGPoint(x: box.maxX, y: box.minY))
        let zone = CGRect(x: hautGauche.x - coin.x, y: hautGauche.y - coin.y,
                          width: basDroit.x - hautGauche.x, height: basDroit.y - hautGauche.y)
        dessinerGrille(ctx, zone: zone, hauteurImage: H, largeurImage: CGFloat(largeur),
                       largeurGrille: largeurGrille, hauteurGrille: hauteurGrille)

        guard let image = ctx.makeImage() else { return nil }
        return PageImaging.jpegData(image, quality: 0.8)
    }

    // MARK: - Dessin

    private static func dessinerGrille(_ ctx: CGContext, zone: CGRect, hauteurImage H: CGFloat, largeurImage W: CGFloat,
                                       largeurGrille: Double, hauteurGrille: Double) {
        let ux = zone.width / CGFloat(largeurGrille)
        let uy = zone.height / CGFloat(hauteurGrille)
        func px(_ x: Double) -> CGFloat { zone.minX + CGFloat(x) * ux }
        func py(_ y: Double) -> CGFloat { H - (zone.minY + CGFloat(y) * uy) }     // repère CoreGraphics (origine en bas)
        let fin = CGColor(red: 0.10, green: 0.35, blue: 0.85, alpha: 0.28)
        let fort = CGColor(red: 0.85, green: 0.20, blue: 0.10, alpha: 0.55)
        let bord = CGColor(red: 0.85, green: 0.20, blue: 0.10, alpha: 0.9)
        let basY = py(hauteurGrille), hautY = py(0)

        ctx.setLineWidth(1)
        for i in 0...Int(largeurGrille.rounded(.down)) {
            let fortLigne = i % 5 == 0
            ctx.setStrokeColor(fortLigne ? fort : fin)
            ctx.setLineWidth(fortLigne ? 1.6 : 0.8)
            ctx.move(to: CGPoint(x: px(Double(i)), y: basY)); ctx.addLine(to: CGPoint(x: px(Double(i)), y: hautY)); ctx.strokePath()
        }
        let droite = px(largeurGrille), gauche = px(0)
        for j in 0...Int(hauteurGrille.rounded(.down)) {
            let fortLigne = j % 5 == 0
            ctx.setStrokeColor(fortLigne ? fort : fin)
            ctx.setLineWidth(fortLigne ? 1.6 : 0.8)
            ctx.move(to: CGPoint(x: gauche, y: py(Double(j)))); ctx.addLine(to: CGPoint(x: droite, y: py(Double(j)))); ctx.strokePath()
        }
        // Contour exact de la zone.
        ctx.setStrokeColor(bord)
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: gauche, y: basY, width: droite - gauche, height: hautY - basY))

        // Chiffres : sur les quatre bords ; tous les 1 si la place le permet, sinon tous les 2 ou tous les 5.
        let marge = min(zone.minX, zone.minY, W - zone.maxX, H - zone.maxY)
        let taille = max(9, min(17, marge * 0.7))
        let pas = max(1, min(ux, uy) >= taille * 1.7 ? 1 : (min(ux, uy) >= taille * 0.9 ? 2 : 5))
        var i = 0
        while Double(i) <= largeurGrille {
            let x = px(Double(i))
            chiffre("\(i)", centre: CGPoint(x: x, y: hautY + (marge + 2) * 0.5 + taille * 0.1), taille: taille, ctx: ctx)
            chiffre("\(i)", centre: CGPoint(x: x, y: basY - (marge + 2) * 0.5 - taille * 0.1), taille: taille, ctx: ctx)
            i += pas
        }
        var j = 0
        while Double(j) <= hauteurGrille {
            let y = py(Double(j))
            chiffre("\(j)", centre: CGPoint(x: gauche - (marge + 2) * 0.5, y: y), taille: taille, ctx: ctx)
            chiffre("\(j)", centre: CGPoint(x: droite + (marge + 2) * 0.5, y: y), taille: taille, ctx: ctx)
            j += pas
        }
    }

    /// Un nombre centré sur `centre` (repère CoreGraphics), sur un petit fond blanc pour rester lisible.
    private static func chiffre(_ texte: String, centre: CGPoint, taille: CGFloat, ctx: CGContext) {
        let police = CTFontCreateWithName("Helvetica-Bold" as CFString, taille, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: police, .foregroundColor: NSColor(calibratedRed: 0.75, green: 0.1, blue: 0.05, alpha: 1)]
        let ligne = CTLineCreateWithAttributedString(NSAttributedString(string: texte, attributes: attrs))
        let b = CTLineGetBoundsWithOptions(ligne, [])
        let fond = CGRect(x: centre.x - b.width / 2 - 2, y: centre.y - b.height / 2 - 1, width: b.width + 4, height: b.height + 2)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        ctx.fill(fond)
        ctx.textPosition = CGPoint(x: centre.x - b.width / 2 - b.minX, y: centre.y - b.height / 2 - b.minY)
        CTLineDraw(ligne, ctx)
    }
}
