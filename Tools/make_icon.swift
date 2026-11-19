import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Génère l'icône de « Complète-Cours » : une feuille de cours à trous dont un pointillé est déjà complété
// à la main (écriture bleue), et un crayon, sur un grand carré bleu aux coins arrondis (style macOS).
//
// Utilisation :  make_icon <dossier_de_sortie>
// Écrit  <dossier>/AppIcon-1024.png  et  <dossier>/AppIcon.iconset/  (les 10 images attendues par
// `iconutil -c icns`). Chaque taille est redessinée en vectoriel (pas réduite depuis le 1024 px) ;
// les petites tailles utilisent un dessin simplifié et un peu plus grand pour rester lisibles.
// Seuls CoreGraphics, CoreText et ImageIO sont utilisés (aucune dépendance).

// MARK: - Outils de dessin

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func couleur(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func degrade(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

/// Rectangle aux coins « continus » (superellipse d'exposant 5), comme les icônes de macOS.
func squircle(_ r: CGRect, exposant n: CGFloat = 5, pas: Int = 1440) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2
    for i in 0...pas {
        let t = CGFloat(i) / CGFloat(pas) * 2 * .pi
        let c = cos(t), s = sin(t)
        let pt = CGPoint(x: r.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                         y: r.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

func arrondi(_ r: CGRect, _ rayon: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: min(rayon, r.height / 2, r.width / 2),
           cornerHeight: min(rayon, r.height / 2, r.width / 2), transform: nil)
}

func remplir(_ ctx: CGContext, _ chemin: CGPath, _ c: CGColor) {
    ctx.addPath(chemin)
    ctx.setFillColor(c)
    ctx.fillPath()
}

// MARK: - Niveaux de détail

/// Plus la taille est petite, moins on dessine de choses (elles deviendraient une bouillie de pixels).
enum Detail {
    case complet   // 256 px et plus
    case moyen     // 64 à 255 px
    case minimal   // moins de 64 px

    init(pixels: Int) { self = pixels >= 256 ? .complet : (pixels >= 64 ? .moyen : .minimal) }
}

// MARK: - Dessin général (repère de 1024 × 1024, origine en bas à gauche)

func dessinerIcone(_ ctx: CGContext, detail: Detail, echelle: CGFloat) {
    // Grille d'icône macOS : un carré de 824 px au centre d'une toile de 1024 px.
    // Aux petites tailles, on agrandit un peu le tout pour ne pas perdre de pixels dans les marges.
    let zoom: CGFloat = detail == .minimal ? 1.10 : (detail == .moyen ? 1.04 : 1)
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: zoom, y: zoom)
    ctx.translateBy(x: -512, y: -512)
    let s = echelle * zoom

    let corps = CGRect(x: 100, y: 100, width: 824, height: 824)
    let forme = squircle(corps)

    // Ombre portée de l'icône
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: couleur(0x001133, 0.40))
    remplir(ctx, forme, couleur(0x0B3FB5))
    ctx.restoreGState()

    // Fond : dégradé bleu, lueur douce en haut à gauche
    ctx.saveGState()
    ctx.addPath(forme)
    ctx.clip()
    ctx.drawLinearGradient(degrade([(0, couleur(0x63B6FF)), (0.5, couleur(0x2A79F2)), (1, couleur(0x0A3DB0))]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.drawRadialGradient(degrade([(0, couleur(0xFFFFFF, 0.28)), (1, couleur(0xFFFFFF, 0))]),
                           startCenter: CGPoint(x: 300, y: 880), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 880), endRadius: 600, options: [])
    ctx.restoreGState()

    // Fine bordure intérieure claire, plus marquée en haut (effet de volume)
    if detail != .minimal {
        ctx.saveGState()
        ctx.addPath(squircle(corps.insetBy(dx: 2, dy: 2)))
        ctx.setLineWidth(4)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(degrade([(0, couleur(0xFFFFFF, 0.60)), (0.4, couleur(0xFFFFFF, 0.06)), (1, couleur(0xFFFFFF, 0))]),
                               start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        ctx.restoreGState()
    }

    let pointe = dessinerFeuille(ctx, detail: detail, echelle: s)
    dessinerCrayon(ctx, pointe: pointe, detail: detail, echelle: s)
}

// MARK: - La feuille de cours

/// Dessine la feuille et renvoie l'endroit où la pointe du crayon doit se poser (fin du mot écrit).
func dessinerFeuille(_ ctx: CGContext, detail: Detail, echelle s: CGFloat) -> CGPoint {
    let f = CGRect(x: 206, y: 168, width: 478, height: 676)
    let pli: CGFloat = 116
    let rayon: CGFloat = 32

    // forme de la feuille (coin supérieur droit plié)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: f.minX + rayon, y: f.minY))
    p.addLine(to: CGPoint(x: f.maxX - rayon, y: f.minY))
    p.addArc(tangent1End: CGPoint(x: f.maxX, y: f.minY), tangent2End: CGPoint(x: f.maxX, y: f.minY + rayon), radius: rayon)
    p.addLine(to: CGPoint(x: f.maxX, y: f.maxY - pli))
    p.addLine(to: CGPoint(x: f.maxX - pli, y: f.maxY))
    p.addLine(to: CGPoint(x: f.minX + rayon, y: f.maxY))
    p.addArc(tangent1End: CGPoint(x: f.minX, y: f.maxY), tangent2End: CGPoint(x: f.minX, y: f.maxY - rayon), radius: rayon)
    p.addLine(to: CGPoint(x: f.minX, y: f.minY + rayon))
    p.addArc(tangent1End: CGPoint(x: f.minX, y: f.minY), tangent2End: CGPoint(x: f.minX + rayon, y: f.minY), radius: rayon)
    p.closeSubpath()

    // ombre, puis papier légèrement dégradé
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 30 * s, color: couleur(0x03163F, 0.42))
    remplir(ctx, p, couleur(0xFFFFFF))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(p)
    ctx.clip()
    ctx.drawLinearGradient(degrade([(0, couleur(0xFFFFFF)), (1, couleur(0xE6EEFB))]),
                           start: CGPoint(x: f.minX, y: f.maxY), end: CGPoint(x: f.maxX, y: f.minY), options: [])
    ctx.restoreGState()

    // le coin plié
    let coin = CGMutablePath()
    coin.move(to: CGPoint(x: f.maxX - pli, y: f.maxY))
    coin.addLine(to: CGPoint(x: f.maxX - pli, y: f.maxY - pli + 16))
    coin.addArc(tangent1End: CGPoint(x: f.maxX - pli, y: f.maxY - pli), tangent2End: CGPoint(x: f.maxX - pli + 16, y: f.maxY - pli), radius: 16)
    coin.addLine(to: CGPoint(x: f.maxX, y: f.maxY - pli))
    coin.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -3 * s, height: -6 * s), blur: 10 * s, color: couleur(0x03163F, 0.30))
    remplir(ctx, coin, couleur(0xD3E0F5))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(coin)
    ctx.clip()
    ctx.drawLinearGradient(degrade([(0, couleur(0xF6F9FF)), (1, couleur(0xB4C8E8))]),
                           start: CGPoint(x: f.maxX - pli, y: f.maxY), end: CGPoint(x: f.maxX, y: f.maxY - pli), options: [])
    ctx.restoreGState()

    // --- contenu : un titre, puis des phrases à trous (barre grise = texte, pointillés = trou) ---
    let gauche = f.minX + 58
    let droite = f.maxX - 54
    let gris = couleur(0xC3CFE3)
    let pointille = couleur(0x8397BC)
    let encre = couleur(0x1B4FD8)
    let petit = detail == .minimal

    // titre
    remplir(ctx, arrondi(CGRect(x: gauche, y: 730, width: 232, height: petit ? 52 : 44), 22), couleur(0x16336E))
    if detail == .complet {
        remplir(ctx, arrondi(CGRect(x: gauche, y: 680, width: 150, height: 22), 11), gris)
    }

    // lignes à trous : un rang = une phrase (barre grise) suivie d'un pointillé ; un seul rang est déjà complété à la main
    struct Rang { var y: CGFloat; var phrase: CGFloat; var fin: CGFloat; var rempli: Bool }
    var rangs = [Rang(y: 594, phrase: 150, fin: droite, rempli: false),
                 Rang(y: 478, phrase: 104, fin: droite - 92, rempli: false),   // s'arrête avant le crayon
                 Rang(y: 362, phrase: 84, fin: droite, rempli: true)]
    if detail == .complet { rangs.append(Rang(y: 246, phrase: 128, fin: droite, rempli: false)) }
    if petit { rangs = [Rang(y: 580, phrase: 120, fin: droite, rempli: false), Rang(y: 440, phrase: 84, fin: droite, rempli: true)] }

    let epaisseurBarre: CGFloat = petit ? 34 : 26
    let diametre: CGFloat = petit ? 26 : (detail == .moyen ? 20 : 15)
    let pas: CGFloat = petit ? 44 : (detail == .moyen ? 36 : 30)
    var cible = CGPoint(x: f.maxX - 60, y: 400)

    for r in rangs {
        remplir(ctx, arrondi(CGRect(x: gauche, y: r.y - epaisseurBarre / 2 + 4, width: r.phrase, height: epaisseurBarre), epaisseurBarre / 2), gris)
        let debut = gauche + r.phrase + 28
        var x = debut + diametre / 2
        while x <= r.fin {
            ctx.setFillColor(pointille)
            ctx.fillEllipse(in: CGRect(x: x - diametre / 2, y: r.y - diametre / 2 + 4, width: diametre, height: diametre))
            x += pas
        }
        if r.rempli {
            // le mot écrit à la main sur le pointillé (les points restent visibles dessous)
            cible = ecrire(ctx, mot: "volt", de: debut + 10, jusqua: droite - 4, base: r.y + 18, detail: detail, couleur: encre)
        }
    }
    return cible
}

/// Première police d'écriture manuscrite disponible sur ce Mac (Bradley Hand est fournie avec macOS ; les autres
/// ne servent que si elle manquait, pour que l'icône reste fabricable partout).
func policeManuscrite(taille: CGFloat) -> CTFont {
    for nom in ["BradleyHandITCTT-Bold", "Noteworthy-Bold", "SnellRoundhand-Bold"] {
        let f = CTFontCreateWithName(nom as CFString, taille, nil)
        if (CTFontCopyPostScriptName(f) as String) == nom { return f }
    }
    return CTFontCreateWithName("Helvetica-Oblique" as CFString, taille, nil)
}

/// Écrit un mot en écriture manuscrite bleue (police « Bradley Hand » fournie avec macOS), ajusté à la largeur
/// disponible. Aux très petites tailles, on dessine à la place un trait d'encre ondulé. Renvoie la fin du mot.
func ecrire(_ ctx: CGContext, mot: String, de x: CGFloat, jusqua xMax: CGFloat, base y: CGFloat,
            detail: Detail, couleur c: CGColor) -> CGPoint {
    if detail == .minimal {
        let t = CGMutablePath()
        t.move(to: CGPoint(x: x + 4, y: y + 6))
        t.addCurve(to: CGPoint(x: x + 70, y: y + 14), control1: CGPoint(x: x + 20, y: y + 62), control2: CGPoint(x: x + 44, y: y - 34))
        t.addCurve(to: CGPoint(x: xMax - 6, y: y + 18), control1: CGPoint(x: x + 100, y: y + 56), control2: CGPoint(x: xMax - 60, y: y - 28))
        ctx.saveGState()
        ctx.addPath(t)
        ctx.setStrokeColor(c)
        ctx.setLineWidth(28)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
        return CGPoint(x: xMax - 4, y: y + 18)
    }
    func ligne(taille: CGFloat) -> CTLine {
        let police = policeManuscrite(taille: taille)
        let attrs: [CFString: Any] = [kCTFontAttributeName: police, kCTForegroundColorFromContextAttributeName: true]
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, mot as CFString, attrs as CFDictionary))
    }
    // on cherche la taille de police qui occupe exactement la largeur disponible
    let mesure = CTLineGetTypographicBounds(ligne(taille: 100), nil, nil, nil)
    let taille = min(122, 100 * Double(xMax - x) / mesure)
    let l = ligne(taille: CGFloat(taille))
    ctx.saveGState()
    ctx.setFillColor(c)
    ctx.setStrokeColor(c)
    ctx.setLineWidth(detail == .complet ? 3 : 6)           // épaissit le trait pour mieux le lire
    ctx.setTextDrawingMode(.fillStroke)
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(l, ctx)
    ctx.restoreGState()
    let fin = x + CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
    return CGPoint(x: fin + 2, y: y + 8)
}

// MARK: - Le crayon

/// Crayon jaune incliné à 50°, dont la pointe touche `pointe` (le bout du mot écrit).
func dessinerCrayon(_ ctx: CGContext, pointe: CGPoint, detail: Detail, echelle s: CGFloat) {
    let longueur: CGFloat = 372
    let largeur: CGFloat = detail == .minimal ? 100 : 90
    let h = largeur / 2
    let cone: CGFloat = 112
    let gomme: CGFloat = 56
    let virole: CGFloat = 62
    let r: CGFloat = 16                       // coins arrondis du bout

    ctx.saveGState()
    ctx.translateBy(x: pointe.x, y: pointe.y)
    ctx.rotate(by: 50 * .pi / 180)

    // silhouette complète (pointe en (0,0), gomme à droite)
    let sil = CGMutablePath()
    sil.move(to: .zero)
    sil.addLine(to: CGPoint(x: cone, y: h))
    sil.addLine(to: CGPoint(x: longueur - r, y: h))
    sil.addArc(tangent1End: CGPoint(x: longueur, y: h), tangent2End: CGPoint(x: longueur, y: h - r), radius: r)
    sil.addLine(to: CGPoint(x: longueur, y: -h + r))
    sil.addArc(tangent1End: CGPoint(x: longueur, y: -h), tangent2End: CGPoint(x: longueur - r, y: -h), radius: r)
    sil.addLine(to: CGPoint(x: cone, y: -h))
    sil.closeSubpath()

    // ombre portée sur la feuille et le fond
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 9 * s, height: -15 * s), blur: 20 * s, color: couleur(0x021030, 0.50))
    remplir(ctx, sil, couleur(0xE5A50A))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(sil)
    ctx.clip()

    // bois taillé (le cône), avec une mine sombre à la pointe
    ctx.drawLinearGradient(degrade([(0, couleur(0xFBE6C2)), (1, couleur(0xD9A468))]),
                           start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: -h), options: [])
    let mine = CGMutablePath()
    mine.move(to: .zero)
    mine.addLine(to: CGPoint(x: 44, y: h * 44 / cone))
    mine.addLine(to: CGPoint(x: 44, y: -h * 44 / cone))
    mine.closeSubpath()
    remplir(ctx, mine, couleur(0x2A2D3B))

    // corps jaune en trois facettes
    let x0 = cone
    let x1 = longueur - gomme - virole
    let facettes: [(CGFloat, CGFloat, UInt32)] = [(h * 0.32, h, 0xFFDF5C), (-h * 0.32, h * 0.32, 0xFFC928), (-h, -h * 0.32, 0xE6A100)]
    for (bas, haut, c) in facettes {
        ctx.setFillColor(couleur(c))
        ctx.fill(CGRect(x: x0 - 1, y: bas, width: x1 - x0 + 1, height: haut - bas))
    }
    // ombre portée du cône sur le corps
    ctx.setFillColor(couleur(0x000000, 0.12))
    ctx.fill(CGRect(x: x0 - 1, y: -h, width: 6, height: largeur))

    // virole métallique avec trois rainures
    ctx.saveGState()
    ctx.clip(to: CGRect(x: x1, y: -h, width: virole, height: largeur))
    ctx.drawLinearGradient(degrade([(0, couleur(0xF4F7FA)), (0.35, couleur(0xC2CAD4)), (0.62, couleur(0xF8FAFC)), (1, couleur(0x8A94A2))]),
                           start: CGPoint(x: x1, y: h), end: CGPoint(x: x1, y: -h), options: [])
    ctx.restoreGState()
    if detail != .minimal {
        for k in [14, 31, 48] as [CGFloat] {
            ctx.setStrokeColor(couleur(0x66707E, 0.55))
            ctx.setLineWidth(3)
            ctx.move(to: CGPoint(x: x1 + k, y: -h)); ctx.addLine(to: CGPoint(x: x1 + k, y: h)); ctx.strokePath()
        }
    }

    // gomme rose
    let gx = longueur - gomme
    ctx.saveGState()
    ctx.clip(to: CGRect(x: gx, y: -h, width: gomme, height: largeur))
    ctx.drawLinearGradient(degrade([(0, couleur(0xFFB0C2)), (1, couleur(0xE0597A))]),
                           start: CGPoint(x: gx, y: h), end: CGPoint(x: gx, y: -h), options: [])
    ctx.restoreGState()
    ctx.restoreGState()

    // contour fin
    ctx.addPath(sil)
    ctx.setStrokeColor(couleur(0x5A3B00, 0.35))
    ctx.setLineWidth(2.5)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Export

func rendre(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldSmoothFonts(false)
    let echelle = CGFloat(pixels) / 1024
    ctx.scaleBy(x: echelle, y: echelle)
    dessinerIcone(ctx, detail: Detail(pixels: pixels), echelle: echelle)
    return ctx.makeImage()!
}

func ecrirePNG(_ image: CGImage, vers url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make_icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Impossible de créer \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make_icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Impossible d'écrire \(url.path)"])
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 1 else {
    FileHandle.standardError.write(Data("Utilisation : make_icon <dossier_de_sortie>\n".utf8))
    exit(2)
}
let sortie = URL(fileURLWithPath: args[0], isDirectory: true)
let iconset = sortie.appendingPathComponent("AppIcon.iconset", isDirectory: true)

do {
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    // (nom du fichier, taille en pixels) — les noms sont imposés par iconutil
    let fichiers: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    var deja: [Int: CGImage] = [:]
    for (nom, px) in fichiers {
        let image = deja[px] ?? rendre(pixels: px)
        deja[px] = image
        try ecrirePNG(image, vers: iconset.appendingPathComponent(nom))
    }
    try ecrirePNG(deja[1024]!, vers: sortie.appendingPathComponent("AppIcon-1024.png"))
    print("Icône générée dans \(sortie.path) (\(fichiers.count) images + AppIcon-1024.png)")
} catch {
    FileHandle.standardError.write(Data("Erreur : \(error.localizedDescription)\n".utf8))
    exit(1)
}
