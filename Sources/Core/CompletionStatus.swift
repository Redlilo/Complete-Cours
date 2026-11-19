import Foundation
import PDFKit
import CoreGraphics

// État de complétion d'un PDF : parmi les zones que le détecteur trouve, lesquelles ont déjà une réponse ?
// Le détecteur retrouve les pointillés même quand une réponse est écrite dessus ; on regarde donc, zone par zone,
// s'il y a une annotation de texte (anciennes réponses de l'app) ou de l'encre juste au-dessus de la ligne.
// Tout est local : aucune IA, aucun réseau.

struct CompletionReport: Equatable {
    var zones: Int          // zones détectées
    var answered: Int       // dont déjà répondues
    var pages: Int

    var remaining: Int { max(0, zones - answered) }
    /// Cours à compléter : il reste des trous, et ce n'est pas juste une zone isolée mal repérée.
    var isIncomplete: Bool { remaining >= 2 && Double(remaining) >= 0.34 * Double(max(zones, 1)) }
}

enum CompletionStatus {
    /// Rapport pour un PDF déjà analysé (`CoursPipeline.analyzeChecked`).
    static func report(url: URL, analyses: [PageAnalysis]) -> CompletionReport {
        guard let doc = PDFDocument(url: url) else { return CompletionReport(zones: 0, answered: 0, pages: 0) }
        var zones = 0, answered = 0
        for a in analyses where !a.zones.isEmpty {
            guard let page = doc.page(at: a.pageIndex) else { continue }
            let notes = textAnnotationRects(page)
            let ink = inkProbe(page)
            for z in a.zones {
                zones += 1
                if isAnswered(z, notes: notes, ink: ink) { answered += 1 }
            }
        }
        return CompletionReport(zones: zones, answered: answered, pages: doc.pageCount)
    }

    /// Analyse puis rapport (hors thread principal : l'analyse lit toutes les pages).
    static func report(url: URL) -> CompletionReport? {
        guard let analyses = try? CoursPipeline.analyzeChecked(url: url, needText: false, progress: { _, _ in }) else { return nil }
        return report(url: url, analyses: analyses)
    }

    // MARK: Signaux

    /// Zones de la page couvertes par une annotation de texte non vide (réponses écrites par l'app).
    static func textAnnotationRects(_ page: PDFPage) -> [CGRect] {
        page.annotations.compactMap { ann -> CGRect? in
            guard (ann.type ?? "") == "FreeText" else { return nil }
            let text = (ann.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : ann.bounds
        }
    }

    /// Rendu de la page en niveaux de gris (annotations comprises) pour mesurer l'encre au-dessus des lignes.
    struct InkProbe {
        var gray: GrayBitmap
        var geometry: PageGeometry

        /// Part de pixels foncés dans un rectangle de la page (espace PDF), entre 0 et 1.
        func darkRatio(in pageRect: CGRect, threshold: UInt8 = 125) -> Double {
            let r = geometry.toImage(rect: pageRect)
            let x0 = max(0, Int(r.minX)), x1 = min(gray.width - 1, Int(r.maxX))
            let y0 = max(0, Int(r.minY)), y1 = min(gray.height - 1, Int(r.maxY))
            guard x1 > x0, y1 > y0 else { return 0 }
            var dark = 0
            for y in y0...y1 {
                let row = y * gray.width
                for x in x0...x1 where gray.data[row + x] < threshold { dark += 1 }
            }
            return Double(dark) / Double((x1 - x0 + 1) * (y1 - y0 + 1))
        }
    }

    static func inkProbe(_ page: PDFPage) -> InkProbe? {
        guard let (img, geo) = PageImaging.render(page: page, longEdge: 1600) else { return nil }
        return InkProbe(gray: PageImaging.gray(img), geometry: geo)
    }

    // MARK: Décision

    static func isAnswered(_ z: Zone, notes: [CGRect], ink: InkProbe?) -> Bool {
        let h = max(z.textHeight, 9)
        // 1. une annotation de texte recouvre la zone (ou la ligne, un peu au-dessus)
        let zoneRect = z.rect.insetBy(dx: -3, dy: -0.4 * h)
        if notes.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(zoneRect) }) { return true }
        // 2. de l'encre juste au-dessus de la ligne (réponse aplatie dans la page)
        guard let ink else { return false }
        if let box = z.box {
            // cadre ou champ : de l'encre à l'intérieur, en gardant une marge pour les bords
            let inner = box.insetBy(dx: min(3, box.width / 4), dy: min(3, box.height / 4))
            return ink.darkRatio(in: inner) > 0.015
        }
        guard !z.lines.isEmpty else { return false }
        var strips = 0, filled = 0
        for l in z.lines {
            let yMid = (l.y + l.yEnd) / 2
            // bande au-dessus de la ligne, sans la ligne elle-même (≈ 1,5 pt d'écart)
            let strip = CGRect(x: l.x0 + 2, y: yMid + 2, width: max(4, l.width - 4), height: max(5, 0.95 * h))
            strips += 1
            if ink.darkRatio(in: strip) > 0.02 { filled += 1 }
        }
        return filled * 2 >= strips      // au moins la moitié des lignes de la zone sont écrites
    }
}
