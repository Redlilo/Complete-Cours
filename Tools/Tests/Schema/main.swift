import Foundation
import CoreGraphics
import PDFKit
import AppKit
import ImageIO

// Test des symboles et du rendu de schémas : écrit des PNG/PDF dans le dossier donné, vérifie quelques invariants.

let sortie = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: sortie, withIntermediateDirectories: true)
var echecs = 0
func verifier(_ ok: Bool, _ message: String) {
    if ok { print("OK    \(message)") } else { print("ECHEC \(message)"); echecs += 1 }
}

let noir = CGColor(gray: 0.05, alpha: 1)
let espace = CGColorSpace(name: CGColorSpace.sRGB)!

func bitmap(_ w: Int, _ h: Int) -> CGContext {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: espace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return c
}
func ecrire(_ c: CGContext, _ nom: String) {
    let d = CGImageDestinationCreateWithURL(sortie.appendingPathComponent(nom) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, c.makeImage()!, nil); CGImageDestinationFinalize(d)
}

// MARK: - (a) Galerie

func galerie() {
    let colonnes = 6, tous = SchemaSymbolType.allCases
    let lignes = (tous.count + colonnes - 1) / colonnes
    let u: CGFloat = 38, cw: CGFloat = 5.2 * u, ch: CGFloat = 5.4 * u
    let ctx = bitmap(Int(cw) * colonnes, Int(ch) * lignes)
    for (i, t) in tous.enumerated() {
        let col = i % colonnes, lig = i / colonnes
        let ox = CGFloat(col) * cw, oy = CGFloat(ctx.height) - CGFloat(lig + 1) * ch
        ctx.setStrokeColor(CGColor(gray: 0.82, alpha: 1)); ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: ox, y: oy, width: cw, height: ch))
        let cx = ox + cw / 2, cy = oy + ch / 2 - 0.2 * u
        // cadre 2 × 3 unités
        ctx.setStrokeColor(CGColor(red: 0.55, green: 0.75, blue: 1, alpha: 1)); ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3]); ctx.stroke(CGRect(x: cx - u, y: cy - 1.5 * u, width: 2 * u, height: 3 * u)); ctx.setLineDash(phase: 0, lengths: [])
        ctx.setStrokeColor(noir); ctx.setFillColor(noir)
        ctx.saveGState(); ctx.translateBy(x: cx, y: cy)
        t.dessiner(dans: ctx, echelle: u)
        ctx.restoreGState()
        for (nom, p) in t.terminaux {
            ctx.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1))
            let px = cx + p.x * u, py = cy - p.y * u
            ctx.fillEllipse(in: CGRect(x: px - 3, y: py - 3, width: 6, height: 6))
            let droite = p.x >= 0
            SchemaPolice.dessiner(nom, ctx: ctx, x: px + (droite ? 6 : -6), y: py + (p.y < 0 ? 8 : -8), taille: 12, ancre: droite ? .gauche : .droite)
        }
        ctx.setFillColor(noir)
        SchemaPolice.dessiner(t.nomFrancais, ctx: ctx, x: cx, y: oy + ch - 14, taille: 10.5, ancre: .centre)
        ctx.setFillColor(CGColor(gray: 0.45, alpha: 1))
        SchemaPolice.dessiner(t.rawValue, ctx: ctx, x: cx, y: oy + ch - 29, taille: 10.5, ancre: .centre)
    }
    ecrire(ctx, "galerie.png")
}

// MARK: - (b) Exemples

func S(_ id: String, _ t: SchemaSymbolType, _ x: Double, _ y: Double, _ r: Int = 0, _ l: String = "") -> SchemaSymbole {
    SchemaSymbole(id: id, type: t, x: x, y: y, rotation: r, label: l)
}
func F(_ a: String, _ b: String, via: [[Double]] = []) -> SchemaFil { SchemaFil(de: a, vers: b, via: via) }

func exempleVaEtVient() -> SchemaElectrique {
    var s = SchemaElectrique(largeurGrille: 11, hauteurGrille: 12)
    s.symboles = [
        S("L", .phase, 3, 1, 0, "L"), S("S1", .vaEtVient, 3, 5, 0, "S1"), S("S2", .vaEtVient, 3, 9, 180, "S2"),
        S("E1", .lampe, 8, 9, 0, "E1"), S("N", .neutre, 8, 1, 0, "N"),
    ]
    s.fils = [
        F("L.a", "S1.c"), F("S1.1", "S2.2"), F("S1.2", "S2.1"),
        F("S2.c", "E1.b", via: [[3, 11], [8, 11]]), F("E1.a", "N.a"),
    ]
    s.textes = [SchemaTexte(texte: "navettes", x: 4.3, y: 7)]
    return s
}

func exempleMoteur() -> SchemaElectrique {
    var s = SchemaElectrique(largeurGrille: 17, hauteurGrille: 21)
    let xs = [3.2, 4.0, 4.8]
    for (i, x) in xs.enumerated() {
        s.symboles.append(S("B\(i)", .borne, x, 1.5))
        s.symboles.append(S("Q1\(i)", .disjoncteur, x, 4.5, 0, i == 2 ? "Q1" : ""))
        s.fils.append(F("B\(i).a", "Q1\(i).a"))
    }
    s.symboles += [S("KM1", .contactPuissance, 4, 9, 0, "KM1"), S("F1", .relaisThermique, 4, 13.5, 0, "F1"), S("M1", .moteurTri, 4, 19, 0, "M1")]
    for (i, b) in ["1", "3", "5"].enumerated() { s.fils.append(F("Q1\(i).b", "KM1.\(b)")) }
    for (i, b) in ["2", "4", "6"].enumerated() { s.fils.append(F("KM1.\(b)", "F1.\(["1", "3", "5"][i])")) }
    for (i, b) in ["2", "4", "6"].enumerated() { s.fils.append(F("F1.\(b)", "M1.\(["U", "V", "W"][i])")) }
    s.textes = [SchemaTexte(texte: "L1", x: 2.9, y: 0.6), SchemaTexte(texte: "L2", x: 3.7, y: 0.6), SchemaTexte(texte: "L3", x: 4.5, y: 0.6),
                SchemaTexte(texte: "Puissance", x: 1.2, y: 21 - 0.4), SchemaTexte(texte: "Commande", x: 9.0, y: 21 - 0.4)]
    // commande
    s.symboles += [
        S("P", .phase, 11, 1, 0, "L1"), S("F1c", .contactNF, 11, 3.5, 0, "F1"), S("S1", .boutonPoussoirNF, 11, 6.5, 0, "S1"),
        S("J1", .jonction, 11, 8), S("KMa", .contactNO, 9, 10.5, 0, "KM1"), S("S2", .boutonPoussoirNO, 13.5, 10.5, 0, "S2"),
        S("J2", .jonction, 11, 13), S("KMb", .contacteurBobine, 11, 15.5, 0, "KM1"), S("N", .neutre, 11, 19, 180, "N"),
    ]
    s.fils += [
        F("P.a", "F1c.a"), F("F1c.b", "S1.a"), F("S1.b", "J1.a"), F("J1.a", "KMa.a"), F("J1.a", "S2.a"),
        F("KMa.b", "J2.a"), F("S2.b", "J2.a"), F("J2.a", "KMb.A1"), F("KMb.A2", "N.a"),
    ]
    return s
}

func exemplePrise() -> SchemaElectrique {
    var s = SchemaElectrique(largeurGrille: 12, hauteurGrille: 13)
    s.symboles = [
        S("L1", .phase, 2, 1), S("S1", .interrupteur, 2, 4.5, 0, "S1"), S("E1", .lampe, 2, 7.5, 0, "E1"), S("N1", .neutre, 2, 10.2, 180),
        S("L2", .phase, 7, 1), S("Q1", .disjoncteur, 7, 4, 0, "Q1"), S("N2", .neutre, 9.6, 1),
        S("XS", .priseCourant, 8, 8, 0, "XS1"), S("T", .terre, 8, 11.5),
    ]
    s.fils = [
        F("L1.a", "S1.a"), F("S1.b", "E1.a"), F("E1.b", "N1.a"),
        F("L2.a", "Q1.a"), F("Q1.b", "XS.L"), F("N2.a", "XS.N"), F("XS.PE", "T.a"),
    ]
    s.textes = [SchemaTexte(texte: "PE", x: 8.6, y: 11.5), SchemaTexte(texte: "Éclairage", x: 0.4, y: 12.5), SchemaTexte(texte: "Prise 16 A", x: 6.4, y: 12.5)]
    return s
}

func rendreExemple(_ s: SchemaElectrique, _ nom: String, echelle u: CGFloat = 38) {
    let m: CGFloat = 24
    let ctx = bitmap(Int(CGFloat(s.largeurGrille) * u + 2 * m), Int(CGFloat(s.hauteurGrille) * u + 2 * m))
    let r = CGRect(x: m, y: m, width: CGFloat(s.largeurGrille) * u, height: CGFloat(s.hauteurGrille) * u)
    ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
    for gx in 0...Int(s.largeurGrille) { for gy in 0...Int(s.hauteurGrille) {
        ctx.fill(CGRect(x: r.minX + CGFloat(gx) * u - 1, y: r.maxY - CGFloat(gy) * u - 1, width: 2, height: 2)) } }
    SchemaRenderer.dessiner(s, dans: r, ctx: ctx, couleur: noir)
    ecrire(ctx, nom)
}

// MARK: - Vérifications

func verifierBornes() {
    for t in SchemaSymbolType.allCases {
        let bornes = t.terminaux
        verifier(!bornes.isEmpty, "\(t.rawValue) : au moins une borne")
        verifier(bornes.values.allSatisfy { abs($0.x) <= 1.5 && abs($0.y) <= 1.5 }, "\(t.rawValue) : bornes dans 3 × 3")
        verifier(bornes.keys.allSatisfy { t.borne($0)?.point == bornes[$0] }, "\(t.rawValue) : bornes retrouvées par nom")
        verifier(!t.nomFrancais.isEmpty, "\(t.rawValue) : nom français")
        verifier(SchemaSymbolType.catalogueDuPrompt.contains("- \(t.rawValue) :"), "\(t.rawValue) : dans le catalogue")
    }
    let s = exempleVaEtVient()
    let p1 = SchemaRenderer.positionBorne("S1.1", dans: s), p2 = SchemaRenderer.positionBorne("S2.2", dans: s)
    verifier(p1 == CGPoint(x: 2.3, y: 6.5), "S1.1 en (2,3 ; 6,5) : \(String(describing: p1))")
    verifier(p2 == CGPoint(x: 2.3, y: 7.5), "S2.2 tourné de 180° en (2,3 ; 7,5) : \(String(describing: p2))")
    var r = SchemaElectrique(largeurGrille: 10, hauteurGrille: 10)
    r.symboles = [S("A", .disjoncteur, 5, 5, 90)]
    verifier(SchemaRenderer.positionBorne("A.a", dans: r) == CGPoint(x: 6.5, y: 5), "rotation 90° : a à droite")
    verifier(SchemaRenderer.positionBorne("A.1", dans: r) == CGPoint(x: 6.5, y: 5), "synonyme « 1 » = a")
    verifier(SchemaRenderer.positionBorne("3.5,2", dans: r) == CGPoint(x: 3.5, y: 2), "point libre")
}

func aleatoire() {
    let bizarres: [Double] = [.nan, .infinity, -.infinity, 1e300, -1e300, 0, -3, 5, 99999, 0.5, 7.25]
    let refs = ["Q1.a", "Q1.b", "Q1.zz", "X.z", "3,4", "nan,2", "", ".", "a,b,c", "Q1", "Q1.1", "q1.A", "S0.U", "1e999,2", "-5,500"]
    let ids = ["Q1", "Q1", "", "S0", "S1", "x.y"]
    var invalides = 0
    for _ in 0..<200 {
        func d() -> Double { Bool.random() ? bizarres.randomElement()! : Double.random(in: -5...15) }
        var s = SchemaElectrique(largeurGrille: d(), hauteurGrille: d())
        for _ in 0..<Int.random(in: 0...30) {
            s.symboles.append(SchemaSymbole(id: ids.randomElement()!, type: SchemaSymbolType.allCases.randomElement()!, x: d(), y: d(),
                                            rotation: [0, 90, 7, -90, 12345, Int.max, Int.min, 450].randomElement()!, label: ["", "Q1", String(repeating: "W", count: 200)].randomElement()!))
        }
        for _ in 0..<Int.random(in: 0...30) {
            s.fils.append(SchemaFil(de: refs.randomElement()!, vers: refs.randomElement()!, via: (0..<Int.random(in: 0...3)).map { _ in Bool.random() ? [d(), d()] : [d()] }))
        }
        for _ in 0..<Int.random(in: 0...5) { s.textes.append(SchemaTexte(texte: ["", "L1", "é"].randomElement()!, x: d(), y: d())) }
        // dessin direct d'un schéma non validé : ne doit pas planter
        let c = bitmap(120, 120)
        SchemaRenderer.dessiner(s, dans: CGRect(x: 5, y: 5, width: 110, height: 110), ctx: c, couleur: noir)
        SchemaRenderer.dessiner(s, dans: CGRect(x: Double.nan, y: 0, width: 10, height: 10), ctx: c, couleur: noir)
        let v = SchemaRenderer.valider(s)
        var ok = v.largeurGrille > 0 && v.hauteurGrille > 0 && Set(v.symboles.map(\.id)).count == v.symboles.count
        ok = ok && v.symboles.allSatisfy { [0, 90, 180, 270].contains($0.rotation) && $0.x.isFinite && $0.y.isFinite
            && $0.x >= 0 && $0.x <= v.largeurGrille && $0.y >= 0 && $0.y <= v.hauteurGrille }
        ok = ok && v.fils.allSatisfy { SchemaRenderer.positionBorne($0.de, dans: v) != nil && SchemaRenderer.positionBorne($0.vers, dans: v) != nil }
        ok = ok && SchemaRenderer.valider(v).fils == v.fils
        if v.fils.count < s.fils.count { ok = ok && v.remarque.contains("retiré") }
        if !ok { invalides += 1 }
        SchemaRenderer.dessiner(v, dans: CGRect(x: 5, y: 5, width: 110, height: 110), ctx: c, couleur: noir)
    }
    verifier(invalides == 0, "200 schémas absurdes : pas de plantage, validation cohérente (\(invalides) invalides)")
}

// MARK: - (c) PDF aplati

func compterEncre(_ c: CGContext, _ zone: CGRect) -> Int {
    guard let base = c.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
    var n = 0
    let h = c.height
    for y in Int(zone.minY)..<Int(zone.maxY) {
        let ligne = h - 1 - y
        for x in Int(zone.minX)..<Int(zone.maxX) {
            let o = ligne * c.bytesPerRow + x * 4
            if Int(base[o]) + Int(base[o + 1]) + Int(base[o + 2]) < 560 { n += 1 }
        }
    }
    return n
}

func testerPDF() {
    let page = CGRect(x: 0, y: 0, width: 300, height: 230)
    let donnees = NSMutableData()
    var mb = page
    let pdf = CGContext(consumer: CGDataConsumer(data: donnees)!, mediaBox: &mb, nil)!
    pdf.beginPDFPage(nil)
    pdf.setFillColor(noir)
    SchemaPolice.dessiner("Exercice 3 : complète le schéma du va-et-vient", ctx: pdf, x: 14, y: 212, taille: 10, ancre: .gauche)
    pdf.setStrokeColor(CGColor(gray: 0.6, alpha: 1)); pdf.stroke(CGRect(x: 14, y: 14, width: 272, height: 180))
    pdf.endPDFPage(); pdf.closePDF()

    guard let doc = PDFDocument(data: donnees as Data), let p = doc.page(at: 0) else { verifier(false, "PDF de départ"); return }
    let zone = CGRect(x: 16, y: 16, width: 268, height: 176)
    let k: CGFloat = 3
    let zoneEncre = CGRect(x: 20 * k, y: 20 * k, width: 260 * k, height: 170 * k)
    func rendre(_ page: PDFPage) -> CGContext {
        let c = bitmap(Int(page.bounds(for: .mediaBox).width * k), Int(page.bounds(for: .mediaBox).height * k))
        c.scaleBy(x: k, y: k)
        page.draw(with: PDFDisplayBox.mediaBox, to: c)
        return c
    }
    // référence : page vide + schéma dessiné directement
    let ref = rendre(p)
    let avantSchema = compterEncre(ref, zoneEncre)
    ref.saveGState()
    SchemaRenderer.dessiner(exempleVaEtVient(), dans: zone, ctx: ref, couleur: NSColor(calibratedRed: 0, green: 0.1, blue: 0.5, alpha: 1).cgColor)
    ref.restoreGState()
    let attendu = compterEncre(ref, zoneEncre)
    verifier(attendu > avantSchema + 2000, "référence : le schéma ajoute de l'encre (\(attendu - avantSchema) pixels)")

    let annotation = SchemaAnnotation(schema: exempleVaEtVient(), bounds: zone, couleur: NSColor(calibratedRed: 0, green: 0.1, blue: 0.5, alpha: 1))
    p.addAnnotation(annotation)
    // affichage : PDFPage.draw appelle bien le dessin de l'annotation
    let affiche = rendre(p)
    let nAffiche = compterEncre(affiche, zoneEncre)
    verifier(abs(Double(nAffiche - attendu)) < 0.05 * Double(attendu), "affichage à l'écran = dessin direct (\(nAffiche) / \(attendu))")

    // aplatissement natif PDFKit : NE conserve PAS le dessin personnalisé (voir commentaire de SchemaAnnotation)
    if let natif = doc.dataRepresentation(options: [PDFDocumentWriteOption.burnInAnnotationsOption: true]), let d = PDFDocument(data: natif), let pg = d.page(at: 0) {
        for a in pg.annotations { pg.removeAnnotation(a) }
        let n = compterEncre(rendre(pg), zoneEncre)
        print("INFO  burnInAnnotationsOption natif : \(n) pixels (≠ \(attendu) : le tampon est remplacé par une croix vide)")
    }

    // aplatissement par SchemaAnnotation.aplatir
    guard let aplati = SchemaAnnotation.aplatir(doc), let doc2 = PDFDocument(data: aplati), let p2 = doc2.page(at: 0) else { verifier(false, "aplatir"); return }
    verifier(p.annotations.contains { $0 === annotation }, "aplatir ne modifie pas le document source")
    verifier(p2.annotations.isEmpty, "PDF aplati : plus d'annotation séparée")
    let c = rendre(p2)
    ecrire(c, "pdf-aplati.png")
    let n = compterEncre(c, zoneEncre)
    verifier(abs(Double(n - attendu)) < 0.05 * Double(attendu), "PDF aplati = dessin direct (\(n) / \(attendu) pixels d'encre)")
    verifier(p2.string?.contains("Exercice 3") == true, "PDF aplati : le texte de la page reste du texte")
    verifier(annotation.type == "Stamp", "type d'annotation « Stamp » (\(annotation.type ?? "nil"))")
    verifier(annotation.setValue("Schéma 1", forAnnotationKey: .name), "setValue du nom d'annotation possible")
}

galerie()
rendreExemple(exempleVaEtVient(), "exemple-va-et-vient.png")
rendreExemple(exempleMoteur(), "exemple-demarrage-moteur.png", echelle: 34)
rendreExemple(exemplePrise(), "exemple-prise-luminaire.png")
verifierBornes()
aleatoire()
testerPDF()
print(echecs == 0 ? "TOUT EST BON" : "\(echecs) échec(s)")
exit(echecs == 0 ? 0 : 1)
