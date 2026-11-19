import AppKit
import PDFKit

/// Petits PDF de test, fabriqués à la volée (aucune donnée personnelle) :
///  - texte.pdf       2 pages : texte à pointillés, soulignés, cadre vide ; page 2 avec trois champs de formulaire
///  - tourne.pdf      1 page tournée de 90°
///  - verrouille.pdf  texte.pdf protégé par un mot de passe
///  - rognage.pdf     page dont la zone visible (cropBox) ne commence pas en (0, 0)
///  - vide.pdf        1 page sans aucun trou
///  - scan.pdf        la page 1 de texte.pdf photographiée : une image, pas de couche texte
enum TestPDFs {
    struct Files {
        let texte: URL
        let tourne: URL
        let verrouille: URL
        let rognage: URL
        let vide: URL
        let scan: URL
    }

    static let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
    static let userPassword = "secret-test"

    private static let body = NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)
    private static let bold = NSFont(name: "Helvetica-Bold", size: 20) ?? NSFont.boldSystemFont(ofSize: 20)

    private static func text(_ s: String, _ x: CGFloat, _ y: CGFloat, font: NSFont? = nil) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? body, .foregroundColor: NSColor.black]
        (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    private static func makePDF(_ url: URL, pages: [(CGContext) -> Void]) {
        var box = a4
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for draw in pages {
            ctx.beginPDFPage(nil)
            let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            draw(ctx)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private static let page1: (CGContext) -> Void = { ctx in
        let dots = String(repeating: "…", count: 22)
        let longDots = String(repeating: ".", count: 95)
        let unders = String(repeating: "_", count: 70)
        text("Les énergies renouvelables", 50, 780, font: bold)
        text("Le soleil est une énergie \(dots) car elle se renouvelle.", 50, 730)
        text("Un panneau photovoltaïque transforme la lumière en \(String(repeating: ".", count: 40)) électrique.", 50, 700)
        text("Définition : l'énergie éolienne est", 50, 660)
        text(longDots, 50, 640)
        text(longDots, 50, 620)
        text("Question : pourquoi faut-il économiser l'énergie ?", 50, 570)
        text(unders, 50, 548)
        text(unders, 50, 528)
        // Pas de « : » en fin de ligne : depuis la détection « Libellé : » (TextLayer.colonRuns), un libellé qui se
        // termine par deux-points compte comme un trou à droite. Ici le trou attendu est le cadre dessiné dessous.
        text("Schéma de la chaîne d'énergie (cadre ci-dessous)", 50, 470)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 50, y: 360, width: 300, height: 90))
        text("Conclusion : écris deux phrases.", 50, 320)
        text(unders, 50, 298)
    }

    private static let page2: (CGContext) -> Void = { _ in
        text("Fiche d'identité", 50, 780, font: bold)
        text("Nom :", 50, 730)
        text("Prénom :", 50, 700)
        text("Classe :", 50, 670)
        text("Cette page contient des champs de formulaire à remplir.", 50, 620)
    }

    /// Fabrique tous les PDF dans `dir` (créé si besoin).
    static func generate(in dir: URL) -> Files {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let texte = dir.appendingPathComponent("texte.pdf")
        let tourne = dir.appendingPathComponent("tourne.pdf")
        let verrouille = dir.appendingPathComponent("verrouille.pdf")
        let rognage = dir.appendingPathComponent("rognage.pdf")
        let vide = dir.appendingPathComponent("vide.pdf")
        let scan = dir.appendingPathComponent("scan.pdf")

        makePDF(texte, pages: [page1, page2])
        if let doc = PDFDocument(url: texte), let p2 = doc.page(at: 1) {
            func field(_ name: String, _ rect: CGRect) {
                let w = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
                w.widgetFieldType = .text
                w.fieldName = name
                w.widgetStringValue = ""
                w.font = NSFont.systemFont(ofSize: 11)
                p2.addAnnotation(w)
            }
            field("nom", CGRect(x: 120, y: 726, width: 200, height: 18))
            field("prenom", CGRect(x: 120, y: 696, width: 200, height: 18))
            field("classe", CGRect(x: 120, y: 666, width: 120, height: 18))
            doc.write(to: texte)
        }

        makePDF(tourne, pages: [page1])
        if let doc = PDFDocument(url: tourne), let p = doc.page(at: 0) {
            p.rotation = 90
            doc.write(to: tourne)
        }

        if let doc = PDFDocument(url: texte) {
            let opts: [PDFDocumentWriteOption: Any] = [.userPasswordOption: userPassword, .ownerPasswordOption: "owner-test"]
            doc.write(to: verrouille, withOptions: opts)
        }

        makePDF(rognage, pages: [page1])
        if let doc = PDFDocument(url: rognage), let p = doc.page(at: 0) {
            p.setBounds(CGRect(x: 36, y: 60, width: 520, height: 740), for: .cropBox)
            doc.write(to: rognage)
        }

        makePDF(vide, pages: [{ _ in
            text("Une page sans zone à remplir.", 50, 780, font: bold)
            text("Tout est déjà écrit ici : rien à compléter.", 50, 740)
        }])

        makeScan(from: texte, to: scan)
        return Files(texte: texte, tourne: tourne, verrouille: verrouille, rognage: rognage, vide: vide, scan: scan)
    }

    /// Photographie la page 1 d'un PDF et la remet dans un PDF sous forme d'image (aucune couche texte).
    private static func makeScan(from source: URL, to url: URL) {
        guard let doc = PDFDocument(url: source), let page = doc.page(at: 0) else { return }
        let scale: CGFloat = 2
        let size = CGSize(width: a4.width * scale, height: a4.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        var box = a4
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        ctx.beginPDFPage(nil)
        var rect = CGRect(origin: .zero, size: a4.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) { ctx.draw(cg, in: a4) }
        ctx.endPDFPage()
        ctx.closePDF()
    }
}
