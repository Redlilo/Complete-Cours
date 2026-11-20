import Foundation
import PDFKit
import CoreGraphics

// État de complétion d'un PDF : parmi les zones que le détecteur trouve, lesquelles ont déjà une réponse ?
// Le détecteur retrouve les pointillés même quand une réponse est écrite dessus ; on regarde donc, zone par zone,
// s'il y a une annotation de texte (anciennes réponses de l'app) ou de l'encre juste au-dessus de la ligne.
// Tout est local : aucune IA, aucun réseau.

/// État d'un cours : rien de fait, en cours, terminé.
enum CompletionState: String, Equatable {
    case vide, partiel, complet
}

struct CompletionReport: Equatable {
    var zones: Int          // zones détectées
    var answered: Int       // dont déjà répondues
    var pages: Int
    /// Le rapport vient de la comparaison avec l'original vide (fiable) et non d'une simple estimation.
    var usedBlank = false
    /// Amas d'encre ajoutée hors de toute zone (seulement avec l'original vide) : trous probablement manqués.
    var unexpectedInk = 0

    var remaining: Int { max(0, zones - answered) }
    /// Cours à compléter : il reste des trous, et ce n'est pas juste une zone isolée mal repérée.
    var isIncomplete: Bool { remaining >= 2 && Double(remaining) >= 0.34 * Double(max(zones, 1)) }

    /// Part des zones à partir de laquelle un cours est « vide » : pas plus de 10 % de zones remplies.
    static let emptyShare = 0.10

    /// État à trois valeurs (règles simples) :
    /// - complet : plus aucun trou. Avec l'original vide la comparaison est fiable, donc on exige 0 restant ;
    ///   sans lui, un trou isolé peut être un faux trou : on garde la tolérance de `isIncomplete` ;
    /// - vide : presque rien n'est rempli (au plus 10 % des zones) ;
    /// - partiel : tout le reste.
    /// Un cours sans aucune zone détectée est « complet » (rien à compléter).
    var state: CompletionState {
        if zones == 0 { return .complet }
        if usedBlank ? remaining == 0 : !isIncomplete { return .complet }
        if Double(answered) <= CompletionReport.emptyShare * Double(zones) { return .vide }
        return .partiel
    }
}

enum CompletionStatus {
    /// Rapport pour un PDF déjà analysé (`CoursPipeline.analyzeChecked`). Sans `blankOriginal`, `analyses` est celle
    /// de `url` ; avec lui, c'est celle de l'original vide (les zones y sont intactes) et `url` est la version complétée.
    static func report(url: URL, analyses: [PageAnalysis], blankOriginal: URL? = nil) -> CompletionReport {
        guard let doc = PDFDocument(url: url) else { return CompletionReport(zones: 0, answered: 0, pages: 0) }
        if let blankURL = blankOriginal, let blankDoc = PDFDocument(url: blankURL) {
            return blankReport(completed: doc, blank: blankDoc, analyses: analyses)
        }
        var zones = 0, answered = 0
        for a in analyses where !a.zones.isEmpty {
            guard let page = doc.page(at: a.pageIndex) else { continue }
            let notes = textAnnotationRects(page)
            let ink = inkProbe(page)
            for z in a.zones where isMeaningful(z, page: page) {
                zones += 1
                if isAnswered(z, notes: notes, ink: ink) { answered += 1 }
            }
        }
        return CompletionReport(zones: zones, answered: answered, pages: doc.pageCount)
    }

    /// Analyse puis rapport (hors thread principal : l'analyse lit toutes les pages). Avec `blankOriginal`, les zones
    /// sont cherchées dans l'original vide et comparées à `url` (PageDiff) ; si l'original n'est pas lisible, on
    /// retombe sur l'estimation à partir de `url` seul.
    static func report(url: URL, blankOriginal: URL? = nil) -> CompletionReport? {
        if let blank = blankOriginal, PDFDocument(url: blank) != nil,
           let analyses = try? CoursPipeline.analyzeChecked(url: blank, needText: false, progress: { _, _ in }) {
            return report(url: url, analyses: analyses, blankOriginal: blank)
        }
        guard let analyses = try? CoursPipeline.analyzeChecked(url: url, needText: false, progress: { _, _ in }) else { return nil }
        return report(url: url, analyses: analyses)
    }

    /// Comparaison avec l'original vide : une zone est répondue si de l'encre y a été ajoutée. Les pages que l'on ne
    /// peut pas comparer (format différent, page absente) retombent sur l'estimation par annotations et encre.
    private static func blankReport(completed: PDFDocument, blank: PDFDocument, analyses: [PageAnalysis]) -> CompletionReport {
        let all = analyses.flatMap { $0.zones }
        let diff = PageDiff.compare(blank: blank, completed: completed, zones: all)
        var zones = 0, answered = 0
        for a in analyses where !a.zones.isEmpty {
            guard let blankPage = blank.page(at: a.pageIndex) else { continue }
            let donePage = completed.page(at: a.pageIndex)
            let notes = donePage.map(textAnnotationRects) ?? []
            let ink = donePage.flatMap(inkProbe)
            for z in a.zones where isMeaningful(z, page: blankPage) {
                zones += 1
                if let d = diff.zones[z.id], d.comparable { if d.filled { answered += 1 } }
                else if donePage != nil, isAnswered(z, notes: notes, ink: ink) { answered += 1 }
            }
        }
        return CompletionReport(zones: zones, answered: answered, pages: completed.pageCount,
                                usedBlank: true, unexpectedInk: diff.blobs.count)
    }

    // MARK: Faux trous

    /// Écarte ce que le détecteur prend pour un trou sans en être un : le trait de pied de page ou d'en-tête
    /// (une longue ligne dans les marges) et les « Libellé : » suivis d'un schéma plutôt que de pointillés.
    static func isMeaningful(_ z: Zone, page: PDFPage) -> Bool {
        let geo = PageGeometry(page: page)
        let b = CGRect(origin: geo.origin, size: geo.displaySize), r = z.rect     // espace de la page affichée
        if z.source == .ligne || z.source == .texte {
            let rel = (r.midY - b.minY) / max(b.height, 1)
            if (rel < 0.09 || rel > 0.94) && r.width > 0.5 * b.width { return false }
        }
        if z.source == .texte {
            let under = page.selection(for: geo.pageRect(fromZone: r.insetBy(dx: -4, dy: -4)))?.string ?? ""
            let leader = under.range(of: "[._…·\\-–—]{4,}", options: .regularExpression) != nil
            let brackets = under.range(of: "[\\(\\[]\\s*[\\)\\]]", options: .regularExpression) != nil
            if !leader && !brackets { return false }
        }
        return true
    }

    // MARK: Signaux

    /// Zones de la page couvertes par une annotation de texte non vide (réponses écrites par l'app).
    static func textAnnotationRects(_ page: PDFPage) -> [CGRect] {
        let geo = PageGeometry(page: page)
        return page.annotations.compactMap { ann -> CGRect? in
            guard (ann.type ?? "") == "FreeText" else { return nil }
            let text = (ann.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : geo.zoneRect(fromPage: ann.bounds)
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
