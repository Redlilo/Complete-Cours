import Foundation
import PDFKit

/// Une ligne de texte de la page (espace des zones : la page telle qu'elle s'affiche).
struct TextLine {
    var text: String
    var bbox: CGRect
    /// Décalage UTF-16 du début de la ligne dans `page.string` (nil pour le texte lu par OCR).
    var globalStart: Int?
    var charHeight: CGFloat { bbox.height }
}

/// Suite de points / underscores dans le texte : un trou à compléter.
struct LeaderRun {
    var line: Int
    var charLo: Int             // décalage en Character dans `lines[line].text`
    var charHi: Int
    var rect: CGRect
    var ruleY: CGFloat          // hauteur de la ligne à remplir (espace page)
    var isPureLine: Bool        // la ligne ne contient (presque) que ce pointillé
    var endsLine: Bool          // plus rien d'autre après le pointillé sur la ligne
    var isLeader: Bool = true   // false : parenthèses vides ou « Libellé : » (ne s'enchaîne pas avec les lignes suivantes)
}

final class TextLayout {
    private(set) var lines: [TextLine]
    private let page: PDFPage?
    /// Sommaires (« Titre ……… 3 ») : pointillés ni trous ni lignes à remplir.
    private(set) var tocRects: [CGRect] = []

    init(lines: [TextLine], page: PDFPage? = nil) {
        self.lines = lines
        self.page = page
    }

    var meaningfulCharCount: Int {
        lines.reduce(0) { $0 + $1.text.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) } }
    }

    /// Hauteur médiane d'une ligne de texte (≈ 1,2 × corps du texte).
    var bodyHeight: CGFloat {
        let hs = lines.map { $0.bbox.height }.filter { $0 > 3 && $0 < 60 }.sorted()
        guard !hs.isEmpty else { return 12 }
        return hs[hs.count / 2]
    }

    // MARK: - Lecture de la couche texte du PDF

    /// Les positions viennent des sélections PDFKit (par ligne et par plage), seules fiables :
    /// `characterBounds(at:)` renvoie des positions décalées sur certains PDF.
    static func fromPDF(_ page: PDFPage) -> TextLayout {
        guard let s = page.string, !s.isEmpty else { return TextLayout(lines: [], page: page) }
        let ns = s as NSString
        guard let all = page.selection(for: page.bounds(for: .cropBox)) else { return TextLayout(lines: [], page: page) }
        var cursor = 0
        var out: [TextLine] = []
        let frame = PageGeometry(page: page)
        for ls in all.selectionsByLine() {
            let text = (ls.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let raw = ls.bounds(for: page)
            if raw.isNull || raw.isEmpty { continue }
            let b = frame.zoneRect(fromPage: raw)
            if b.isNull || b.isEmpty || b.width.isNaN || b.height.isNaN || b.height > 200 { continue }

            var start: Int? = nil
            var r = ns.range(of: text, options: [], range: NSRange(location: cursor, length: ns.length - cursor))
            if r.location == NSNotFound { r = ns.range(of: text) }
            if r.location == NSNotFound && text.count > 24 {
                r = ns.range(of: String(text.prefix(24)), options: [], range: NSRange(location: cursor, length: ns.length - cursor))
            }
            if r.location != NSNotFound {
                start = r.location
                if r.location >= cursor { cursor = r.location + r.length }
            }
            out.append(TextLine(text: text, bbox: b, globalStart: start))
        }
        return TextLayout(lines: out, page: page)
    }

    // MARK: - Pointillés et underscores

    private static func weight(_ c: Character) -> (dots: Int, unders: Int)? {
        switch c {
        case ".", "·", "∙": return (1, 0)
        case "‥": return (2, 0)
        case "…", "⋯": return (3, 0)
        case "_", "＿", "‗": return (0, 1)
        default: return nil
        }
    }

    func leaderRuns() -> [LeaderRun] {
        var runs: [LeaderRun] = []
        for (li, line) in lines.enumerated() {
            let cs = Array(line.text)
            var i = 0
            while i < cs.count {
                guard Self.weight(cs[i]) != nil else { i += 1; continue }
                var j = i
                var lastLeader = i
                var dots = 0, unders = 0
                while j < cs.count {
                    if let w = Self.weight(cs[j]) {
                        dots += w.dots; unders += w.unders; lastLeader = j; j += 1
                    } else if (cs[j] == " " || cs[j] == "\u{00A0}"), j + 1 < cs.count, Self.weight(cs[j + 1]) != nil {
                        j += 1
                    } else { break }
                }
                let lo = i, hi = lastLeader + 1
                let rect = runRect(line: line, chars: cs, lo: lo, hi: hi)
                // « Chapitre 1 ……… 3 » : une entrée de sommaire, pas un trou
                let rest = String(cs[hi...]).trimmingCharacters(in: .whitespaces)
                let toc = rest.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil
                if (dots >= 6 || unders >= 3 || dots + 2 * unders >= 6) && rect.width >= 24 && toc {
                    tocRects.append(rect)
                }
                if (dots >= 6 || unders >= 3 || dots + 2 * unders >= 6) && rect.width >= 24 && !toc {
                    let others = cs.enumerated().filter { ($0.offset < lo || $0.offset >= hi) && !$0.element.isWhitespace }.count
                    let after = cs[hi...].contains { !$0.isWhitespace }
                    let ruleY = unders > dots ? rect.minY + 0.12 * rect.height : rect.minY + 0.22 * rect.height
                    runs.append(LeaderRun(line: li, charLo: lo, charHi: hi, rect: rect, ruleY: ruleY,
                                          isPureLine: others <= 1, endsLine: !after))
                }
                i = hi
            }
        }
        return runs
    }

    /// Texte déjà tapé SUR un pointillé (ou juste au-dessus) : la réponse est déjà écrite, le trou n'est plus à remplir.
    /// Le texte tapé est en corps plus petit que la ligne de pointillés (réponse d'élève, réponse de l'app) ; une question
    /// ou une consigne au-dessus du pointillé a le même corps que lui et n'est donc pas prise pour une réponse.
    func hasTypedAnswer(on run: LeaderRun) -> Bool {
        guard run.line < lines.count else { return false }
        let dh = max(lines[run.line].bbox.height, 6)
        for (i, o) in lines.enumerated() where i != run.line {
            let ob = o.bbox
            guard ob.height >= 5, ob.height <= 0.9 * dh else { continue }
            guard o.text.reduce(0, { $0 + ($1.isLetter || $1.isNumber ? 1 : 0) }) >= 3 else { continue }
            let ox = min(ob.maxX, run.rect.maxX) - max(ob.minX, run.rect.minX)
            guard ox >= 20, ox >= 0.35 * min(ob.width, run.rect.width) else { continue }
            // sur le pointillé ou juste au-dessus (jamais en dessous : c'est la ligne suivante, une autre question)
            guard ob.midY >= run.rect.midY - 0.3 * dh else { continue }
            guard ob.minY - run.rect.maxY <= 0.8 * dh else { continue }
            return true
        }
        return false
    }

    /// Parenthèses ou crochets vides « ( ) », « [   ] » : le trou est entre les deux signes.
    /// Le texte écrit remplace seulement l'intérieur, les signes restent.
    func bracketRuns() -> [LeaderRun] {
        var runs: [LeaderRun] = []
        for (li, line) in lines.enumerated() {
            let cs = Array(line.text)
            var i = 0
            while i < cs.count {
                guard cs[i] == "(" || cs[i] == "[" else { i += 1; continue }
                let close: Character = cs[i] == "(" ? ")" : "]"
                var j = i + 1
                while j < cs.count, cs[j] == " " || cs[j] == "\u{00A0}" { j += 1 }
                guard j < cs.count, cs[j] == close else { i += 1; continue }
                let whole = runRect(line: line, chars: cs, lo: i, hi: j + 1)
                // au moins 40 pt pour écrire un mot, même si les signes sont serrés
                let atEnd = cs[(j + 1)...].allSatisfy { $0 == " " || $0 == "\u{00A0}" }
                let rect = CGRect(x: whole.minX, y: whole.minY, width: atEnd ? max(whole.width, 40) : whole.width, height: whole.height)
                runs.append(LeaderRun(line: li, charLo: i + 1, charHi: j, rect: rect,
                                      ruleY: rect.minY + 0.22 * rect.height, isPureLine: false,
                                      endsLine: false, isLeader: false))
                i = j + 1
            }
        }
        return runs
    }

    /// « Libellé : » suivi de rien sur la même ligne : le trou est à droite du signe deux-points.
    /// Ce n'est pas un trou si la phrase continue à la ligne suivante (minuscule) ou si la ligne suivante
    /// est en retrait (liste de réponses).
    func colonRuns() -> [LeaderRun] {
        let rightEdge = lines.map { $0.bbox.maxX }.max() ?? 0
        let body = bodyHeight
        var runs: [LeaderRun] = []
        for (li, line) in lines.enumerated() {
            let t = line.text.trimmingCharacters(in: .whitespaces)
            guard t.hasSuffix(":"), t.count >= 4 else { continue }
            let b = line.bbox
            // le trou s'arrête au premier texte de la même rangée (autre cellule, autre colonne)
            var limit = rightEdge
            for o in lines where o.bbox.minX > b.maxX + 4 {
                let ov = min(o.bbox.maxY, b.maxY) - max(o.bbox.minY, b.minY)
                if ov > 0.4 * min(o.bbox.height, b.height) { limit = min(limit, o.bbox.minX - 6) }
            }
            guard b.height <= 1.6 * body, limit - b.maxX >= 120 else { continue }
            if li + 1 < lines.count {
                let nx = lines[li + 1]
                let dy = b.minY - nx.bbox.minY
                if dy > 0 && dy < 3.0 * b.height {
                    if nx.bbox.minX > b.minX + 6 { continue }
                    if let f = nx.text.first, f.isLowercase { continue }
                }
            }
            let n = Array(line.text).count
            runs.append(LeaderRun(line: li, charLo: n, charHi: n,
                                  rect: CGRect(x: b.maxX + 6, y: b.minY, width: limit - b.maxX - 6, height: b.height),
                                  ruleY: b.minY + 0.22 * b.height, isPureLine: false, endsLine: true, isLeader: false))
        }
        return runs
    }

    /// Rectangle exact d'une portion de ligne (via la sélection PDFKit de la plage), sinon estimation proportionnelle.
    private func runRect(line: TextLine, chars: [Character], lo: Int, hi: Int) -> CGRect {
        if let page, let start = line.globalStart {
            let prefix = String(chars[0..<lo]).utf16.count
            let length = String(chars[lo..<hi]).utf16.count
            if let sel = page.selection(for: NSRange(location: start + prefix, length: length)) {
                let b = PageGeometry(page: page).zoneRect(fromPage: sel.bounds(for: page))
                if !b.isNull, !b.isEmpty, b.width.isFinite, b.height < 80 { return b }
            }
        }
        let n = max(chars.count, 1)
        let x0 = line.bbox.minX + CGFloat(lo) / CGFloat(n) * line.bbox.width
        let x1 = line.bbox.minX + CGFloat(hi) / CGFloat(n) * line.bbox.width
        return CGRect(x: x0, y: line.bbox.minY, width: x1 - x0, height: line.bbox.height)
    }
}
