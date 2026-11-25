import Foundation
import CoreGraphics
import PDFKit
import AppKit

// Dessin d'un `SchemaElectrique` (contrat dans SchemaContract.swift) : fils, symboles, repères, textes.
// Ne plante jamais sur des données absurdes : tout est ramené dans la grille avant le dessin.

enum SchemaRenderer {

    private static let grilleMax = 500.0
    private static let grilleDefaut = 10.0

    private enum Axe { case h, v }
    private struct Extremite { var point: CGPoint; var axe: Axe? }

    // MARK: - Nettoyage

    private static func borner(_ v: Double, _ maxi: Double) -> Double {
        v.isFinite ? min(max(v, 0), maxi) : maxi / 2
    }

    /// 0, 90, 180 ou 270 (l'entier le plus proche, multiple de 90).
    static func rotationNormalisee(_ r: Int) -> Int {
        let m = ((r % 360) + 360) % 360
        return ((m + 45) / 90 % 4) * 90
    }

    private static func formater(_ v: Double) -> String { String(format: "%g", v) }

    /// Bornes et point d'un symbole, avec le nom officiel de la borne ; nil si le symbole n'existe pas.
    private static func indexer(_ symboles: [SchemaSymbole]) -> (exact: [String: Int], minuscule: [String: Int]) {
        var exact: [String: Int] = [:], min: [String: Int] = [:]
        for (i, s) in symboles.enumerated() {
            if exact[s.id] == nil { exact[s.id] = i }
            if min[s.id.lowercased()] == nil { min[s.id.lowercased()] = i }
        }
        return (exact, min)
    }

    private static func trouver(_ id: String, _ idx: (exact: [String: Int], minuscule: [String: Int])) -> Int? {
        idx.exact[id] ?? idx.minuscule[id.lowercased()]
    }

    /// Découpe « id.borne » ou « id » ; renvoie l'indice du symbole et le nom de borne (éventuellement vide).
    private static func decouper(_ ref: String, _ idx: (exact: [String: Int], minuscule: [String: Int])) -> (Int, String)? {
        let r = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = trouver(r, idx) { return (i, "") }
        guard let point = r.lastIndex(of: ".") else { return nil }
        let id = String(r[..<point]), borne = String(r[r.index(after: point)...])
        guard let i = trouver(id, idx) else { return nil }
        return (i, borne)
    }

    /// Point libre « x,y » ; nil si ce n'en est pas un.
    private static func pointLibre(_ ref: String) -> (Double, Double)? {
        let parts = ref.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              x.isFinite, y.isFinite else { return nil }
        return (x, y)
    }

    /// Schéma ramené à des données saines. `retirerFils` : supprime les fils dont une extrémité n'existe pas
    /// (sinon on les garde et le dessin utilisera le centre du symbole). Renvoie aussi les remarques sur ce qui a été corrigé.
    private static func assainir(_ s: SchemaElectrique, retirerFils: Bool) -> (SchemaElectrique, [String]) {
        let L = (s.largeurGrille.isFinite && s.largeurGrille > 0) ? min(s.largeurGrille, grilleMax) : grilleDefaut
        let H = (s.hauteurGrille.isFinite && s.hauteurGrille > 0) ? min(s.hauteurGrille, grilleMax) : grilleDefaut
        var notes: [String] = []
        var sortie = SchemaElectrique(largeurGrille: L, hauteurGrille: H)
        sortie.remarque = s.remarque

        if s.largeurGrille != L || s.hauteurGrille != H { notes.append("taille de grille corrigée") }
        if s.symboles.count > 400 || s.fils.count > 800 || s.textes.count > 200 { notes.append("éléments en trop ignorés") }

        var ids = Set<String>()
        var renomme = false
        for (i, sym) in s.symboles.prefix(400).enumerated() {
            var q = sym
            q.x = borner(sym.x, L); q.y = borner(sym.y, H)
            q.rotation = rotationNormalisee(sym.rotation)
            q.label = String(sym.label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            let base = sym.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "S\(i + 1)" : sym.id.trimmingCharacters(in: .whitespacesAndNewlines)
            var id = base, n = 2
            while ids.contains(id) { id = "\(base)_\(n)"; n += 1; renomme = true }
            ids.insert(id)
            q.id = id
            sortie.symboles.append(q)
        }
        if renomme { notes.append("identifiants en double renommés") }

        let idx = indexer(sortie.symboles)
        var filsRetires = 0

        /// Réécrit une extrémité de fil sous forme normalisée ; nil si elle n'existe pas.
        func normaliser(_ ref: String) -> String? {
            let r = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.contains(",") {
                guard let (x, y) = pointLibre(r) else { return nil }
                return "\(formater(borner(x, L))),\(formater(borner(y, H)))"
            }
            guard let (i, borne) = decouper(r, idx) else { return nil }
            let sym = sortie.symboles[i]
            if borne.isEmpty { return sym.id }
            guard let b = sym.type.borne(borne) else { return nil }
            return "\(sym.id).\(b.nom)"
        }

        for fil in s.fils.prefix(800) {
            var f = fil
            if retirerFils {
                guard let a = normaliser(fil.de), let b = normaliser(fil.vers) else { filsRetires += 1; continue }
                f.de = a; f.vers = b
            }
            f.via = fil.via.prefix(20).compactMap { p in
                guard p.count >= 2, p[0].isFinite, p[1].isFinite else { return nil }
                return [borner(p[0], L), borner(p[1], H)]
            }
            sortie.fils.append(f)
        }
        if filsRetires > 0 { notes.append("\(filsRetires) fil(s) vers une borne inexistante retiré(s)") }

        for t in s.textes.prefix(200) {
            let texte = String(t.texte.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !texte.isEmpty else { continue }
            sortie.textes.append(SchemaTexte(texte: texte, x: borner(t.x, L), y: borner(t.y, H)))
        }
        return (sortie, notes)
    }

    /// Nettoie un schéma venant de l'IA : dans la grille, ids uniques, rotation valide, fils vers des bornes
    /// inexistantes retirés (la `remarque` le signale).
    static func valider(_ s: SchemaElectrique) -> SchemaElectrique {
        var (v, notes) = assainir(s, retirerFils: true)
        if !notes.isEmpty {
            let ajout = "À vérifier : " + notes.joined(separator: ", ") + "."
            v.remarque = v.remarque.isEmpty ? ajout : v.remarque + " " + ajout
        }
        return v
    }

    // MARK: - Résolution des bornes

    private static func tourner(_ p: CGPoint, _ deg: Int) -> CGPoint {
        switch deg {
        case 90: return CGPoint(x: -p.y, y: p.x)
        case 180: return CGPoint(x: -p.x, y: -p.y)
        case 270: return CGPoint(x: p.y, y: -p.x)
        default: return p
        }
    }

    private static func extremite(_ ref: String, _ symboles: [SchemaSymbole], _ idx: (exact: [String: Int], minuscule: [String: Int]), L: Double, H: Double) -> Extremite? {
        if ref.contains(",") {
            guard let (x, y) = pointLibre(ref) else { return nil }
            return Extremite(point: CGPoint(x: borner(x, L), y: borner(y, H)), axe: nil)
        }
        guard let (i, borne) = decouper(ref, idx) else { return nil }
        let s = symboles[i]
        let local = s.type.borne(borne)?.point ?? .zero   // borne inconnue : centre du symbole
        let r = tourner(local, rotationNormalisee(s.rotation))
        let axe: Axe? = hypot(r.x, r.y) < 0.3 ? nil : (abs(r.y) >= abs(r.x) ? .v : .h)
        return Extremite(point: CGPoint(x: s.x + Double(r.x), y: s.y + Double(r.y)), axe: axe)
    }

    /// Position (unités de grille) d'une borne « id.borne » ou d'un point « x,y » ; nil si elle n'existe pas.
    static func positionBorne(_ ref: String, dans s: SchemaElectrique) -> CGPoint? {
        let (n, _) = assainir(s, retirerFils: false)
        return extremite(ref, n.symboles, indexer(n.symboles), L: n.largeurGrille, H: n.hauteurGrille)?.point
    }

    // MARK: - Fils

    private static func memes(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.0001 }

    /// Chemin orthogonal passant par les points donnés, avec coudes automatiques.
    private static func chemin(depart: Extremite, via: [CGPoint], arrivee: Extremite) -> [CGPoint] {
        let pts = [depart.point] + via + [arrivee.point]
        var sortie = [pts[0]]
        var dir: Axe? = depart.axe
        for i in 0..<(pts.count - 1) {
            let p = pts[i], q = pts[i + 1]
            let dFin: Axe? = (i == pts.count - 2) ? arrivee.axe : nil
            func ajouter(_ r: CGPoint) {
                if let dernier = sortie.last, memes(dernier.x, r.x), memes(dernier.y, r.y) { return }
                sortie.append(r)
            }
            if memes(p.x, q.x) || memes(p.y, q.y) {
                ajouter(q)
                dir = memes(p.x, q.x) ? .v : .h
                continue
            }
            switch (dir, dFin) {
            case (.v?, .v?):
                let my = (p.y + q.y) / 2
                ajouter(CGPoint(x: p.x, y: my)); ajouter(CGPoint(x: q.x, y: my)); ajouter(q); dir = .v
            case (.h?, .h?):
                let mx = (p.x + q.x) / 2
                ajouter(CGPoint(x: mx, y: p.y)); ajouter(CGPoint(x: mx, y: q.y)); ajouter(q); dir = .h
            case (.v?, _), (nil, .h?):
                ajouter(CGPoint(x: p.x, y: q.y)); ajouter(q); dir = .h
            default: // (.h, _) ou (nil, .v) ou (nil, nil)
                if dir == nil && dFin == nil {
                    ajouter(CGPoint(x: p.x, y: q.y)); ajouter(q); dir = .h
                } else {
                    ajouter(CGPoint(x: q.x, y: p.y)); ajouter(q); dir = .v
                }
            }
        }
        return sortie
    }

    // MARK: - Dessin

    /// Dessine le schéma dans `rect` (points PDF, origine en bas à gauche). La grille est étirée sur `rect` ; les symboles
    /// ont pour taille min(sx, sy) points par unité de grille.
    static func dessiner(_ s: SchemaElectrique, dans rect: CGRect, ctx: CGContext, couleur: CGColor) {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width > 1, rect.height > 1 else { return }
        let (n, _) = assainir(s, retirerFils: false)
        let L = CGFloat(n.largeurGrille), H = CGFloat(n.hauteurGrille)
        let sx = rect.width / L, sy = rect.height / H
        let f = min(sx, sy)
        func pt(_ g: CGPoint) -> CGPoint { CGPoint(x: rect.minX + g.x * sx, y: rect.maxY - g.y * sy) }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(couleur); ctx.setFillColor(couleur)
        ctx.setLineWidth(max(0.07 * f, 0.6))
        ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineDash(phase: 0, lengths: [])

        let idx = indexer(n.symboles)
        let taillePolice = max(5, 0.38 * f)   // repères proportionnés aux lettres internes des symboles (0,42 à 0,55)

        // fils
        for fil in n.fils {
            guard let a = extremite(fil.de, n.symboles, idx, L: n.largeurGrille, H: n.hauteurGrille),
                  let b = extremite(fil.vers, n.symboles, idx, L: n.largeurGrille, H: n.hauteurGrille) else { continue }
            let via = fil.via.map { CGPoint(x: $0[0], y: $0[1]) }
            let ch = chemin(depart: a, via: via, arrivee: b).map(pt)
            guard let premier = ch.first else { continue }
            ctx.move(to: premier)
            if ch.count == 1 { ctx.addLine(to: premier) }
            ch.dropFirst().forEach { ctx.addLine(to: $0) }
            ctx.strokePath()
        }

        // symboles
        for sym in n.symboles {
            let c = pt(CGPoint(x: sym.x, y: sym.y))
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.scaleBy(x: 1, y: -1)                       // y vers le bas, 1 unité = 1 point
            ctx.rotate(by: CGFloat(rotationNormalisee(sym.rotation)) * .pi / 180)
            sym.type.dessiner(dans: ctx, echelle: f)
            ctx.restoreGState()
        }

        // repères (labels) : à droite du corps du symbole, au-dessus s'il est couché
        for sym in n.symboles where !sym.label.isEmpty {
            let c = pt(CGPoint(x: sym.x, y: sym.y))
            let rot = rotationNormalisee(sym.rotation)
            let cr = sym.type.corpsLocal
            let coins = [CGPoint(x: cr.minX, y: cr.minY), CGPoint(x: cr.maxX, y: cr.minY),
                         CGPoint(x: cr.minX, y: cr.maxY), CGPoint(x: cr.maxX, y: cr.maxY)].map { tourner($0, rot) }
            let x0 = coins.map(\.x).min() ?? 0, x1 = coins.map(\.x).max() ?? 0
            let y0 = coins.map(\.y).min() ?? 0
            let marge = 0.2 * f
            if rot == 0 || rot == 180 {
                let largeur = SchemaPolice.largeur(sym.label, taille: taillePolice)
                if c.x + x1 * f + marge + largeur <= rect.maxX + 2 || c.x + x0 * f - marge - largeur < rect.minX {
                    SchemaPolice.dessiner(sym.label, ctx: ctx, x: c.x + x1 * f + marge, y: c.y, taille: taillePolice, ancre: .gauche)
                } else {
                    SchemaPolice.dessiner(sym.label, ctx: ctx, x: c.x + x0 * f - marge, y: c.y, taille: taillePolice, ancre: .droite)
                }
            } else {
                SchemaPolice.dessiner(sym.label, ctx: ctx, x: c.x, y: c.y - y0 * f + taillePolice * 0.8, taille: taillePolice, ancre: .centre)
            }
        }

        // textes libres
        for t in n.textes {
            let p = pt(CGPoint(x: t.x, y: t.y))
            SchemaPolice.dessiner(t.texte, ctx: ctx, x: p.x, y: p.y, taille: taillePolice, ancre: .gauche)
        }
    }
}

// MARK: - Annotation PDF

/// Zone schéma comme annotation « tampon », dessinée en vectoriel par `SchemaRenderer`.
/// ATTENTION : PDFKit n'appelle `draw(with:in:)` qu'à l'AFFICHAGE (PDFView, `PDFPage.draw`). L'aplatissement
/// `dataRepresentation(options: [.burnInAnnotationsOption: true])` ignore ce dessin et écrit une croix de tampon vide
/// (vérifié sur macOS 26 : 0 appel de `draw`, quel que soit le sous-type). Pour exporter, utiliser `aplatir(_:)`.
final class SchemaAnnotation: PDFAnnotation {
    private(set) var schema: SchemaElectrique
    private(set) var couleur: NSColor
    /// Rotation `/Rotate` de la page (0, 90, 180, 270, sens horaire). `bounds` est dans l'espace page BRUT : sur une page
    /// tournée, le schéma est dessiné tourné en sens inverse pour apparaître droit à l'écran, dans le cadre de la zone.
    let rotationPage: Int

    init(schema: SchemaElectrique, bounds: CGRect, couleur: NSColor, rotationPage: Int = 0) {
        self.schema = SchemaRenderer.valider(schema)
        self.couleur = couleur
        self.rotationPage = SchemaRenderer.rotationNormalisee(rotationPage)
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        shouldDisplay = true
        shouldPrint = true
        border = nil
        setValue("Schéma", forAnnotationKey: .name)
    }

    required init?(coder: NSCoder) { nil }

    override func copy(with zone: NSZone? = nil) -> Any {
        SchemaAnnotation(schema: schema, bounds: bounds, couleur: couleur, rotationPage: rotationPage)
    }

    /// Dessine `schema` dans `bounds` (espace page brut) pour une page de rotation `rotation` : le contexte est tourné
    /// autour du centre pour que le schéma soit droit une fois la page affichée.
    static func dessiner(_ schema: SchemaElectrique, bounds: CGRect, rotation: Int, ctx: CGContext, couleur: CGColor) {
        let r = SchemaRenderer.rotationNormalisee(rotation)
        guard r != 0 else { SchemaRenderer.dessiner(schema, dans: bounds, ctx: ctx, couleur: couleur); return }
        let vue = r % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)   // taille du cadre à l'écran
        ctx.saveGState()
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.rotate(by: CGFloat(r) * .pi / 180)            // sens trigonométrique : annule la rotation horaire de la page
        SchemaRenderer.dessiner(schema, dans: CGRect(x: -vue.width / 2, y: -vue.height / 2, width: vue.width, height: vue.height),
                                ctx: ctx, couleur: couleur)
        ctx.restoreGState()
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        // Deux conventions de PDFKit (vérifiées sur macOS 26) :
        //  - PDFView (aperçu) : contexte en espace page BRUT (rotation dans la CTM), clip = `bounds` : on dessine tourné ;
        //  - PDFPage.thumbnail / impression : contexte déjà dans l'espace de la page AFFICHÉE, sans clip : on convertit `bounds`.
        if rotationPage != 0 {
            let clip = context.boundingBoxOfClipPath
            let espaceBrut = clip.width <= bounds.width + 2 && clip.height <= bounds.height + 2     // clip réduit au cadre de l'annotation
            if espaceBrut || page == nil {
                SchemaAnnotation.dessiner(schema, bounds: bounds, rotation: rotationPage, ctx: context, couleur: couleur.cgColor)
            } else {
                let geo = PageGeometry(page: page!)
                SchemaRenderer.dessiner(schema, dans: geo.zoneRect(fromPage: bounds), ctx: context, couleur: couleur.cgColor)
            }
        } else {
            SchemaRenderer.dessiner(schema, dans: bounds, ctx: context, couleur: couleur.cgColor)
        }
        context.restoreGState()
    }

    /// Export aplati : PDF de `doc` avec les autres annotations « brûlées » (PDFKit) et les `SchemaAnnotation` dessinées
    /// en vectoriel par-dessus. Le document `doc` n'est pas modifié (les annotations retirées le temps de l'écriture sont
    /// remises). Réécrit les pages par Core Graphics : signets, liens et métadonnées du PDF d'origine ne sont pas conservés.
    /// Pages tournées : la page est écrite DANS son orientation d'affichage (la rotation est appliquée au contenu, la page
    /// sortie n'a plus de `/Rotate`) et le schéma est dessiné droit dans le cadre de la zone.
    static func aplatir(_ doc: PDFDocument) -> Data? {
        var schemas: [Int: [SchemaAnnotation]] = [:]
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let liste = page.annotations.compactMap { $0 as? SchemaAnnotation }
            if !liste.isEmpty { schemas[i] = liste }
        }
        for (i, liste) in schemas { liste.forEach { doc.page(at: i)?.removeAnnotation($0) } }
        let brut = doc.dataRepresentation(options: [PDFDocumentWriteOption.burnInAnnotationsOption: true])
        for (i, liste) in schemas { liste.forEach { doc.page(at: i)?.addAnnotation($0) } }
        guard let brut else { return nil }
        if schemas.isEmpty { return brut }

        guard let fournisseur = CGDataProvider(data: brut as CFData), let source = CGPDFDocument(fournisseur) else { return brut }
        let sortie = NSMutableData()
        guard let consommateur = CGDataConsumer(data: sortie) else { return brut }
        var boite = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consommateur, mediaBox: &boite, nil) else { return brut }
        for i in 0..<source.numberOfPages {
            guard let page = source.page(at: i + 1) else { continue }
            let media = page.getBoxRect(.mediaBox)
            let rot = SchemaRenderer.rotationNormalisee(Int(page.rotationAngle))
            // page de sortie = page affichée (largeur et hauteur échangées à 90/270), origine en (0, 0)
            var sortieBoite = CGRect(origin: .zero, size: rot % 180 == 0 ? media.size : CGSize(width: media.height, height: media.width))
            let octets = Data(bytes: &sortieBoite, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: octets] as CFDictionary)
            ctx.saveGState()
            // espace page brut -> page affichée (rotation de la page appliquée, aucune rotation en plus)
            ctx.concatenate(page.getDrawingTransform(.mediaBox, rect: sortieBoite, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            for a in schemas[i] ?? [] {
                dessiner(a.schema, bounds: a.bounds, rotation: rot, ctx: ctx, couleur: a.couleur.cgColor)
            }
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return sortie as Data
    }
}
