import Foundation
import PDFKit
import AppKit
import CoreText

// Écriture des réponses dans le PDF : annotations FreeText (lignes et cadres), valeurs de champs de formulaire,
// export (avec ou sans aplatissement).
//
// Ce que PDFKit fait vraiment (mesuré sur ce Mac, voir Tools/Tests/Renderer) et dont le code tient compte :
//  - la taille de police d'une annotation ou d'un champ est arrondie à l'entier le plus proche au moment du dessin
//    (6,5 pt est dessiné à 7 pt) : on n'emploie donc que des tailles entières, de 7 pt jusqu'au maximum du style ;
//  - le texte d'une annotation FreeText commence à 2 pt du bord gauche de l'annotation ; la distance entre le haut de
//    l'annotation et la ligne de base ne suit aucune formule simple (elle dépend de la police et de la taille) : on la
//    mesure une fois par police et taille (`InkCalibration`) pour poser la ligne de base exactement où l'on veut ;
//  - la largeur du texte dessiné est celle de Core Text ; PDFKit passe à la ligne si la boîte est plus étroite ;
//  - le texte est rogné aux bornes de l'annotation : la boîte descend sous la ligne de base de la descente de la police ;
//  - champ de formulaire multiligne : 3 pt de marge de chaque côté, interligne égal à `NSLayoutManager.defaultLineHeight`,
//    une ligne qui ne tient pas entièrement n'est pas affichée ; champ à une seule ligne : PDFKit réduit lui-même la
//    police (et passe à la ligne) quand le texte est trop long, on s'arrange donc pour ne jamais l'y obliger ;
//  - une valeur de champ est tronquée à /MaxLen (100 caractères dans les formulaires du lycée) : on relève cette limite
//    le temps de la réponse et `remove` la rétablit.

// MARK: - Contrat public

/// Ce que `apply` a ajouté au document, pour pouvoir le retirer ou le mettre à jour ensuite.
struct RenderResult {
    /// Zone.id -> annotations ajoutées pour cette zone
    var annotations: [Int: [PDFAnnotation]] = [:]
    /// Zone.id dont le texte ne tient pas entièrement dans la zone (même à la plus petite taille)
    var overflowIDs: Set<Int> = []
    /// Zone.id -> taille de police finalement utilisée (en points)
    var fontSizes: [Int: CGFloat] = [:]
    /// Zone.id -> champ de formulaire rempli (avec son état d'origine, pour `remove`)
    var fields: [Int: FilledField] = [:]
    /// Index des pages modifiées : après `apply` comme après `remove`, l'interface doit appeler
    /// `pdfView.annotationsChanged(on:)` pour chacune de ces pages afin de rafraîchir l'aperçu.
    var touchedPages: Set<Int> = []
    /// Zone.id qui n'ont pas pu être écrites (page introuvable, page tournée — non gérée —, zone sans géométrie).
    var skippedIDs: Set<Int> = []
}

/// Un champ de formulaire rempli par `apply`, avec ce qu'il contenait avant.
struct FilledField {
    var widget: PDFAnnotation
    var pageIndex: Int
    var previousValue: String?
    var previousFont: NSFont?
    var previousFontColor: NSColor?
    var previousMaxLength: Int
}

enum AnswerRenderer {
    /// Texte du champ « auteur » de toutes les annotations posées par l'app (sert à les reconnaître).
    static let annotationAuthor = "CompleteCours"

    /// Écrit les réponses sur `document` : annotations de texte pour les lignes et les cadres,
    /// valeur de champ pour les champs de formulaire. Ignore les zones désactivées, sans réponse ou de type `.ignorer`.
    /// Le document peut être celui qui est affiché : l'aperçu se met à jour après l'appel.
    /// Pour réécrire après une modification : appeler `remove` avec l'ancien résultat, puis `apply`
    /// (appeler `apply` deux fois de suite sans `remove` écrit deux fois les réponses).
    static func apply(zones: [Zone], to document: PDFDocument, style: WritingStyle) -> RenderResult {
        var result = RenderResult()
        let ink = InkStyle(style)
        var widgetsByPage: [Int: [PDFAnnotation]] = [:]
        var usedWidgets = Set<ObjectIdentifier>()

        for zone in zones {
            guard zone.enabled, zone.kind != .ignorer else { continue }
            let tokens = InkText.tokens(zone.answer)
            guard !tokens.isEmpty else { continue }
            guard let page = document.page(at: zone.page) else {
                result.skippedIDs.insert(zone.id)
                continue
            }

            // les zones sont dans l'espace de la page affichée ; annotations et champs, dans l'espace page brut
            let frame = PageGeometry(page: page)

            // 1. champ de formulaire : on le retrouve dans CE document par page + rectangle (Zone.widget est celui d'une autre copie)
            if zone.source == .formulaire, let box = zone.box {
                if widgetsByPage[zone.page] == nil { widgetsByPage[zone.page] = InkFields.textWidgets(of: page) }
                if let widget = InkFields.match(frame.pageRect(fromZone: box), in: widgetsByPage[zone.page] ?? [], excluding: usedWidgets) {
                    if let filled = InkFields.fill(widget, page: page, frame: frame, pageIndex: zone.page, tokens: tokens, ink: ink) {
                        usedWidgets.insert(ObjectIdentifier(widget))
                        result.fields[zone.id] = filled.state
                        result.fontSizes[zone.id] = filled.size
                        if filled.overflow { result.overflowIDs.insert(zone.id) }
                        result.touchedPages.insert(zone.page)
                        continue
                    }
                }
                // champ introuvable ou qui n'affiche rien : on écrit dans le rectangle, comme pour un cadre
            }

            // 2. mise en page : lignes (pointillés, soulignés) ou cadre
            let usableLines = zone.lines.filter { $0.width >= 8 }
            let placement: InkPlacement?
            if (zone.source == .texte || zone.source == .ligne) && !usableLines.isEmpty {
                placement = InkLayout.onLines(tokens, lines: usableLines, textHeight: zone.textHeight, ink: ink)
            } else if let box = zone.box, box.width > 4, box.height > 4 {
                placement = InkLayout.inBox(tokens, box: box, ink: ink)
            } else if !usableLines.isEmpty {
                placement = InkLayout.onLines(tokens, lines: usableLines, textHeight: zone.textHeight, ink: ink)
            } else {
                placement = nil
            }
            guard let placement, !placement.pieces.isEmpty else { result.skippedIDs.insert(zone.id); continue }

            // 3. annotations
            var added: [PDFAnnotation] = []
            for (n, piece) in placement.pieces.enumerated() {
                let annotation = InkAnnotation.make(piece, font: placement.font, color: ink.color, frame: frame)
                _ = annotation.setValue("\(annotationAuthor)-\(zone.id)-\(n)", forAnnotationKey: .name)
                page.addAnnotation(annotation)
                added.append(annotation)
            }
            result.annotations[zone.id] = added
            result.fontSizes[zone.id] = placement.font.size
            if placement.overflow { result.overflowIDs.insert(zone.id) }
            result.touchedPages.insert(zone.page)
        }
        return result
    }

    /// Retire exactement ce que `apply` avait ajouté : les annotations, et les champs de formulaire retrouvent leur valeur,
    /// leur police, leur couleur et leur limite de longueur d'origine.
    static func remove(_ result: RenderResult, from document: PDFDocument) {
        for annotations in result.annotations.values {
            for annotation in annotations { InkFiles.detach(annotation, from: document) }
        }
        for field in result.fields.values {
            let w = InkFields.currentWidget(field, in: document)
            // on relève la limite le temps de remettre l'ancienne valeur (sinon PDFKit la tronque)
            w.maximumLength = 0
            w.widgetStringValue = field.previousValue
            w.maximumLength = field.previousMaxLength
            if let f = field.previousFont { w.font = f }
            if let c = field.previousFontColor { w.fontColor = c }
        }
    }

    /// Écrit le PDF final dans `url` en repartant du fichier d'origine, réponses incluses.
    /// Si `flatten` est vrai, le texte est intégré aux pages (non modifiable) ; sinon il reste en annotations.
    /// Le fichier d'origine n'est jamais modifié.
    static func export(sourceURL: URL, zones: [Zone], style: WritingStyle, flatten: Bool, to url: URL) throws {
        if InkFiles.isSameFile(sourceURL, url) {
            throw CoursError.message("Le fichier choisi est le PDF d'origine : il ne doit pas être écrasé. Choisis un autre nom, par exemple en ajoutant « - complété » à la fin.")
        }
        guard let doc = PDFDocument(url: sourceURL) else {
            throw CoursError.message("Impossible de rouvrir le PDF d'origine « \(sourceURL.lastPathComponent) ». Vérifie qu'il n'a pas été déplacé ou supprimé, puis recommence l'enregistrement.")
        }
        if doc.isLocked, !doc.unlock(withPassword: "") {
            throw CoursError.message("Le PDF « \(sourceURL.lastPathComponent) » est protégé par un mot de passe : impossible d'y écrire les réponses.")
        }
        let pageCount = doc.pageCount
        _ = apply(zones: zones, to: doc, style: style)

        var options: [PDFDocumentWriteOption: Any] = [:]
        if flatten { options[PDFDocumentWriteOption.burnInAnnotationsOption] = true }
        guard let data = doc.dataRepresentation(options: options), !data.isEmpty else {
            throw CoursError.message("Le PDF complété n'a pas pu être produit. Recommence l'enregistrement ; si le problème continue, essaie sans « aplatir le texte ».")
        }
        // on vérifie ce qu'on va écrire : le PDF doit se rouvrir avec le même nombre de pages
        guard let check = PDFDocument(data: data), check.pageCount == pageCount else {
            throw CoursError.message("Le PDF complété est incomplet (pages manquantes) : rien n'a été écrit. Recommence l'enregistrement.")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw CoursError.message("Impossible d'enregistrer « \(url.lastPathComponent) » : \(error.localizedDescription) Vérifie que le dossier existe et que tu as le droit d'y écrire.")
        }
    }
}

// MARK: - Style, polices, mesure

/// Police, couleur et taille maximale de l'écriture.
fileprivate struct InkStyle {
    let fontName: String
    let color: NSColor
    let maxSize: CGFloat

    init(_ style: WritingStyle) {
        fontName = style.fontName
        color = NSColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: 1)
        maxSize = max(style.maxSize, 4)
    }

    func font(_ size: CGFloat) -> InkFont { InkFont(name: fontName, size: size) }
}

/// Police prête à l'emploi : l'objet NSFont donné à PDFKit, vu aussi comme CTFont pour mesurer avec Core Text.
fileprivate struct InkFont {
    let ns: NSFont
    let ct: CTFont

    private static let lock = NSLock()
    private static var resolved: [String: String] = [:]

    /// Nom PostScript de la police demandée (nom complet, nom PostScript ou famille), « Helvetica » si introuvable.
    private static func resolvedName(_ requested: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let known = resolved[requested] { return known }
        var name = "Helvetica"
        if let f = NSFont(name: requested, size: 12) {
            name = f.fontName
        } else {
            let descriptor = NSFontDescriptor(fontAttributes: [.family: requested])
            if let f = NSFont(descriptor: descriptor, size: 12), f.familyName?.lowercased() == requested.lowercased() {
                name = f.fontName
            }
        }
        resolved[requested] = name
        return name
    }

    init(name: String, size: CGFloat) {
        let f = NSFont(name: InkFont.resolvedName(name), size: size) ?? NSFont.systemFont(ofSize: size)
        ns = f
        ct = f as CTFont
    }

    var size: CGFloat { ns.pointSize }
    var ascent: CGFloat { CTFontGetAscent(ct) }
    var descent: CGFloat { CTFontGetDescent(ct) }
    var leading: CGFloat { CTFontGetLeading(ct) }

    /// Largeur du texte (avance Core Text, identique à ce que PDFKit dessine).
    func width(_ s: String) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: ns]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Hauteur d'une ligne dans un champ de formulaire (c'est celle que PDFKit emploie).
    var fieldLineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: ns) }
}

/// Préparation du texte d'une réponse.
fileprivate enum InkText {
    /// Mots de la réponse. Les espaces insécables (dont la fine insécable des guillemets français) restent à
    /// l'intérieur d'un mot — on ne coupe pas la ligne à cet endroit — mais sont dessinés comme des espaces normales
    /// (certaines polices, comme Bradley Hand, n'ont pas ce glyphe).
    static func tokens(_ raw: String) -> [String] {
        var scalars = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            switch u.value {
            case 0x0A, 0x0D, 0x09, 0x0B, 0x0C, 0x2028, 0x2029, 0x85:
                scalars.append(" ")
            case 0x00A0, 0x2007, 0x2009, 0x202F:
                scalars.append(Unicode.Scalar(0x00A0)!)            // marque « insécable » le temps du découpage
            case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD:
                continue                                           // caractères invisibles
            default:
                if u.properties.generalCategory == .control { continue }
                scalars.append(u)
            }
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
    }
}

// MARK: - Découpage en lignes

fileprivate struct InkWrapped {
    var lines: [String]
    var truncated: Bool        // il reste des mots qui n'ont pas trouvé de place
}

fileprivate enum InkWrap {
    /// Remplit les lignes une à une (`widths[i]` = largeur de la ligne i, la dernière valeur sert ensuite) et passe à
    /// la ligne suivante quand un mot ne tient plus. Un mot plus large qu'une ligne vide est coupé (avec un tiret) si
    /// `allowSplit`, sinon le découpage s'arrête là (`truncated`) : l'appelant essaie alors une plus petite taille.
    static func wrap(_ tokens: [String], font: InkFont, widths: [CGFloat], maxLines: Int, allowSplit: Bool) -> InkWrapped {
        guard !widths.isEmpty, maxLines > 0 else { return InkWrapped(lines: [], truncated: !tokens.isEmpty) }
        let space = font.width(" ")
        var cache: [String: CGFloat] = [:]
        func width(_ s: String) -> CGFloat {
            if let v = cache[s] { return v }
            let v = font.width(s); cache[s] = v; return v
        }

        var out: [String] = []
        var current = ""
        var currentWidth: CGFloat = 0
        var queue = tokens
        var i = 0
        var truncated = false
        while i < queue.count {
            if out.count >= maxLines { truncated = true; break }
            let limit = widths[min(out.count, widths.count - 1)]
            let word = queue[i]
            let ww = width(word)
            if current.isEmpty {
                if ww <= limit {
                    current = word; currentWidth = ww; i += 1
                } else if allowSplit {
                    let (head, tail) = split(word, limit: limit, font: font)
                    out.append(head)
                    if let tail { queue[i] = tail } else { i += 1 }
                } else {
                    truncated = true; break
                }
            } else if currentWidth + space + ww <= limit {
                current += " " + word; currentWidth += space + ww; i += 1
            } else {
                out.append(current); current = ""; currentWidth = 0
            }
        }
        if !current.isEmpty {
            if out.count < maxLines { out.append(current) } else { truncated = true }
        }
        return InkWrapped(lines: out, truncated: truncated)
    }

    /// Coupe un mot trop long : le plus grand début qui tient (tiret compris), le reste à écrire sur la ligne suivante.
    private static func split(_ word: String, limit: CGFloat, font: InkFont) -> (String, String?) {
        let chars = Array(word)
        guard chars.count > 1 else { return (word, nil) }
        func head(_ n: Int) -> String {
            let h = String(chars[0..<n])
            let joinsLetters = chars[n - 1].isLetter || chars[n - 1].isNumber
            let nextIsWord = chars[n].isLetter || chars[n].isNumber
            return n >= 2 && joinsLetters && nextIsWord ? h + "-" : h
        }
        var lo = 1, hi = chars.count - 1, best = 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if font.width(head(mid)) <= limit { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return (head(best), String(chars[best...]))
    }

    /// La plus grande taille (entière) où tout le texte tient sans couper de mot ; à défaut, la plus petite taille avec
    /// les mots trop longs coupés, et ce qui ne tient toujours pas est abandonné (`truncated`).
    static func bestFit(_ tokens: [String], sizes: [CGFloat], ink: InkStyle,
                        geometry: (InkFont) -> (widths: [CGFloat], maxLines: Int)) -> (font: InkFont, wrapped: InkWrapped) {
        for size in sizes {
            let font = ink.font(size)
            let g = geometry(font)
            let wrapped = wrap(tokens, font: font, widths: g.widths, maxLines: g.maxLines, allowSplit: false)
            if !wrapped.truncated { return (font, wrapped) }
        }
        let font = ink.font(sizes.last ?? ink.maxSize)
        let g = geometry(font)
        return (font, wrap(tokens, font: font, widths: g.widths, maxLines: g.maxLines, allowSplit: true))
    }
}

// MARK: - Mise en page

/// Un morceau de texte d'une seule ligne, posé à (x, ligne de base).
fileprivate struct InkPiece {
    var text: String
    var x: CGFloat
    var baseline: CGFloat
}

fileprivate struct InkPlacement {
    var pieces: [InkPiece]
    var font: InkFont
    var overflow: Bool
}

fileprivate enum InkLayout {
    /// Plus petite taille employée. PDFKit arrondit les tailles à l'entier : 6,5 pt serait dessiné à 7 pt.
    static let minSize: CGFloat = 7
    /// Retrait du texte par rapport au début de la ligne, et marge à droite.
    static let leftMargin: CGFloat = 2
    static let rightMargin: CGFloat = 1.5

    /// Tailles entières essayées, de la plus grande à la plus petite.
    static func sizes(from top: CGFloat, downTo low: CGFloat = minSize) -> [CGFloat] {
        let high = max(floor(top), 1)
        let floorSize = min(low, high)
        var out: [CGFloat] = []
        var s = high
        while s >= floorSize { out.append(s); s -= 1 }
        return out
    }

    // MARK: Lignes (pointillés, soulignés)

    /// Le texte s'écrit au-dessus de chaque ligne, une ligne de texte par ligne de la zone.
    static func onLines(_ tokens: [String], lines rawLines: [WritingLine], textHeight: CGFloat, ink: InkStyle) -> InkPlacement? {
        let lines = rawLines.sorted {
            let a = max($0.y, $0.yEnd), b = max($1.y, $1.yEnd)
            return abs(a - b) > 1 ? a > b : $0.x0 < $1.x0
        }
        guard !lines.isEmpty else { return nil }

        // taille maximale : l'interligne pour plusieurs lignes, le corps du texte voisin pour une seule
        var cap = ink.maxSize
        if lines.count >= 2 {
            var pitches: [CGFloat] = []
            for (a, b) in zip(lines, lines.dropFirst()) {
                let d = (a.y + a.yEnd) / 2 - (b.y + b.yEnd) / 2
                if d >= 6 { pitches.append(d) }
            }
            if let p = pitches.min() { cap = min(cap, 0.85 * p) }
        } else {
            cap = min(cap, textHeight * 1.1)
        }
        let widths = lines.map { max(0, $0.width - leftMargin - rightMargin) }
        let (font, wrapped) = InkWrap.bestFit(tokens, sizes: sizes(from: max(cap, minSize), downTo: min(minSize, ink.maxSize)), ink: ink) { _ in
            (widths, lines.count)
        }

        var pieces: [InkPiece] = []
        for (text, line) in zip(wrapped.lines, lines) {
            pieces.append(contentsOf: placeOnLine(text, line: line, font: font))
        }
        return InkPlacement(pieces: pieces, font: font, overflow: wrapped.truncated)
    }

    /// Pose une ligne de texte sur une ligne de la zone. Si la ligne est penchée, le texte est découpé en morceaux
    /// de 60 à 90 pt posés chacun à la bonne hauteur.
    private static func placeOnLine(_ text: String, line: WritingLine, font: InkFont) -> [InkPiece] {
        let lift = min(max(font.size * 0.11, 1.0), 1.5)          // la ligne de base est 1 à 1,5 pt au-dessus de la ligne
        let startX = line.x0 + leftMargin
        let textWidth = font.width(text)
        let slope = line.slope
        if abs(slope) * textWidth < 0.6 {
            let baseline = line.y(atX: startX + textWidth / 2) + lift
            return [InkPiece(text: text, x: startX, baseline: baseline)]
        }

        let words = text.split(separator: " ").map(String.init)
        let space = font.width(" ")
        let maxChunk = min(max(1.4 / abs(slope), 60), 90)
        var chunks: [[String]] = []
        var current: [String] = []
        var currentWidth: CGFloat = 0
        for w in words {
            let ww = font.width(w)
            if current.isEmpty {
                current = [w]; currentWidth = ww
            } else if currentWidth + space + ww <= maxChunk {
                current.append(w); currentWidth += space + ww
            } else {
                chunks.append(current); current = [w]; currentWidth = ww
            }
        }
        if !current.isEmpty {
            // un dernier morceau très court rejoint le précédent
            if currentWidth < 28, let last = chunks.last, font.width(last.joined(separator: " ")) + space + currentWidth <= maxChunk * 1.3 {
                chunks[chunks.count - 1] = last + current
            } else {
                chunks.append(current)
            }
        }

        var pieces: [InkPiece] = []
        var before: [String] = []
        for chunk in chunks {
            let piece = chunk.joined(separator: " ")
            let offset = before.isEmpty ? 0 : font.width(before.joined(separator: " ") + " ")
            let x = startX + offset
            let center = x + font.width(piece) / 2
            pieces.append(InkPiece(text: piece, x: x, baseline: line.y(atX: center) + lift))
            before.append(contentsOf: chunk)
        }
        return pieces
    }

    // MARK: Cadres (cases, cadres de réponse, zones dessinées à la main)

    /// Texte à retour à la ligne dans le rectangle, marge 2 pt, aligné en haut à gauche.
    static func inBox(_ tokens: [String], box: CGRect, ink: InkStyle) -> InkPlacement? {
        let inset: CGFloat = 2
        let availWidth = box.width - 2 * inset
        let availHeight = box.height - 2 * inset
        guard availWidth > 3 else { return nil }

        let (font, wrapped) = InkWrap.bestFit(tokens, sizes: sizes(from: ink.maxSize, downTo: min(minSize, ink.maxSize)), ink: ink) { font in
            let body = font.ascent + font.descent
            let maxLines = max(1, Int(floor((availHeight - body) / linePitch(font))) + 1)
            return ([availWidth], maxLines)
        }
        let pitch = linePitch(font)

        var pieces: [InkPiece] = []
        var baseline = box.maxY - inset - font.ascent
        for text in wrapped.lines {
            pieces.append(InkPiece(text: text, x: box.minX + inset, baseline: baseline))
            baseline -= pitch
        }
        // le texte dépasse-t-il le bas du cadre ? (cadre plus bas qu'une ligne)
        let lastBaseline = baseline + pitch
        let tooLow = lastBaseline - font.descent < box.minY - 0.5
        return InkPlacement(pieces: pieces, font: font, overflow: wrapped.truncated || tooLow)
    }

    /// Interligne d'un texte écrit dans un cadre.
    static func linePitch(_ font: InkFont) -> CGFloat {
        max((font.ascent + font.descent + font.leading) * 1.05, font.size * 1.2)
    }
}

// MARK: - Annotations FreeText

fileprivate enum InkAnnotation {
    /// PDFKit dessine le texte à 2 pt du bord gauche de l'annotation.
    static let leftInset: CGFloat = 2

    /// Annotation FreeText d'une ligne, sans fond ni bordure, dont le texte a sa ligne de base exactement à `piece.baseline`.
    /// Page tournée : la mise en page se fait dans l'espace de la page affichée (texte droit), puis le rectangle de
    /// l'annotation est reporté dans l'espace page brut ; PDFKit dessine le texte droit dans ce rectangle tourné.
    static func make(_ piece: InkPiece, font: InkFont, color: NSColor, frame: PageGeometry) -> PDFAnnotation {
        let offset = InkCalibration.baselineOffset(font)
        let width = ceil(font.width(piece.text)) + 2 * leftInset + 4          // 4 pt de sécurité : PDFKit passe à la ligne sinon
        let height = ceil(offset + font.descent * 1.4 + 2)                     // sinon les jambages sont rognés
        let top = piece.baseline + offset
        let bounds = CGRect(x: piece.x - leftInset, y: top - height, width: width, height: height)
        return freeText(piece.text, font: font.ns, color: color, bounds: frame.pageRect(fromZone: bounds))
    }

    static func freeText(_ text: String, font: NSFont, color: NSColor, bounds: CGRect) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        a.font = font
        a.fontColor = color
        a.alignment = .left
        a.color = .clear                       // pas de fond
        let border = PDFBorder()
        border.lineWidth = 0                   // pas de bordure
        a.border = border
        a.contents = text
        a.userName = AnswerRenderer.annotationAuthor
        a.shouldDisplay = true
        a.shouldPrint = true
        return a
    }
}

/// Mesure, pour une police et une taille, la distance entre le haut d'une annotation FreeText et la ligne de base du
/// texte que PDFKit y dessine. On compare un « H » dans une annotation à un « H » dessiné par Core Text à une ligne
/// de base connue, sur une mini-page rendue par PDFKit lui-même.
fileprivate enum InkCalibration {
    private static let lock = NSLock()
    private static var cache: [String: CGFloat] = [:]

    static func baselineOffset(_ font: InkFont) -> CGFloat {
        let key = "\(font.ns.fontName)|\(Int((font.size * 100).rounded()))"
        lock.lock(); let known = cache[key]; lock.unlock()
        if let known { return known }
        let value = measure(font) ?? ceil(font.ascent + 3.7)         // estimation si la mesure échoue
        lock.lock(); cache[key] = value; lock.unlock()
        return value
    }

    private static func measure(_ font: InkFont) -> CGFloat? {
        let pageWidth: CGFloat = 110, pageHeight: CGFloat = 70, scale: CGFloat = 8
        let refBaseline: CGFloat = 14, top: CGFloat = 60

        // mini-page PDF : « H » de référence à droite, dessiné par Core Text
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(data: data),
              let pdf = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        pdf.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "H", attributes: [.font: font.ns, .foregroundColor: NSColor.black]))
        pdf.textPosition = CGPoint(x: 80, y: refBaseline)
        CTLineDraw(line, pdf)
        pdf.endPDFPage()
        pdf.closePDF()
        guard let doc = PDFDocument(data: data as Data), let page = doc.page(at: 0) else { return nil }

        // le même glyphe dans une annotation FreeText à gauche, dont le haut est à y = top
        page.addAnnotation(InkAnnotation.freeText("H", font: font.ns, color: .black,
                                                  bounds: CGRect(x: 4, y: top - 50, width: 60, height: 50)))

        // rendu en niveaux de gris
        let w = Int(pageWidth * scale), h = Int(pageHeight * scale)
        var pixels = [UInt8](repeating: 255, count: w * h)
        let drawn: Bool = withExtendedLifetime(doc) {
            pixels.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
                else { return false }
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
                return true
            }
        }
        guard drawn else { return nil }

        /// Ligne de pixels la plus basse qui porte de l'encre dans la colonne [x0, x1).
        func lowestInkRow(_ x0: Int, _ x1: Int) -> Int? {
            for row in stride(from: h - 1, through: 0, by: -1) {
                for x in x0..<min(x1, w) where pixels[row * w + x] < 140 { return row }
            }
            return nil
        }
        let split = Int(70 * scale)
        guard let annRow = lowestInkRow(0, split), let refRow = lowestInkRow(split, w) else { return nil }
        let annBottom = pageHeight - CGFloat(annRow + 1) / scale
        let refBottom = pageHeight - CGFloat(refRow + 1) / scale
        let below = refBaseline - refBottom                      // dépassement du « H » sous sa ligne de base
        let offset = top - (annBottom + below)
        guard offset > 1, offset < 80 else { return nil }
        let whole = offset.rounded()                             // PDFKit place la ligne de base sur un nombre entier de points
        return abs(offset - whole) < 0.2 ? whole : (offset * 8).rounded() / 8
    }
}

// MARK: - Champs de formulaire

fileprivate enum InkFields {
    static func textWidgets(of page: PDFPage) -> [PDFAnnotation] {
        page.annotations.filter { ($0.type ?? "") == "Widget" && $0.widgetFieldType == .text }
    }

    /// Le champ dont le rectangle est celui de la zone, à 1 pt près (le plus proche si plusieurs).
    static func match(_ box: CGRect, in widgets: [PDFAnnotation], excluding used: Set<ObjectIdentifier>) -> PDFAnnotation? {
        var best: (PDFAnnotation, CGFloat)?
        for w in widgets where !used.contains(ObjectIdentifier(w)) {
            let b = w.bounds
            let d = [abs(b.minX - box.minX), abs(b.minY - box.minY), abs(b.maxX - box.maxX), abs(b.maxY - box.maxY)]
            guard d.allSatisfy({ $0 <= 1 }) else { continue }
            let total = d.reduce(0, +)
            if best == nil || total < best!.1 { best = (w, total) }
        }
        return best?.0
    }

    /// Le champ à restaurer : celui mémorisé s'il est toujours dans `document`, sinon le champ de même rectangle.
    static func currentWidget(_ field: FilledField, in document: PDFDocument) -> PDFAnnotation {
        if let page = field.widget.page, page.document === document { return field.widget }
        if let page = document.page(at: field.pageIndex),
           let w = match(field.widget.bounds, in: textWidgets(of: page), excluding: []) { return w }
        return field.widget
    }

    /// Écrit la réponse dans le champ, avec la police et la couleur du style, à la plus grande taille entière qui tient
    /// et qui s'affiche vraiment (vérifié sur un rendu du champ). Renvoie nil, champ rétabli, s'il n'affiche rien.
    static func fill(_ w: PDFAnnotation, page: PDFPage, frame: PageGeometry, pageIndex: Int, tokens: [String], ink: InkStyle)
        -> (state: FilledField, size: CGFloat, overflow: Bool)? {
        let state = FilledField(widget: w, pageIndex: pageIndex, previousValue: w.widgetStringValue, previousFont: w.font,
                                previousFontColor: w.fontColor, previousMaxLength: w.maximumLength)
        let b = frame.zoneRect(fromPage: w.bounds)             // dimensions du champ tel qu'on le voit
        let multiline = w.isMultiline
        let availWidth = max(8, b.width - 8)                   // PDFKit garde 3 pt de chaque côté ; 1 pt de réserve
        let minSize = min(InkLayout.minSize, ink.maxSize)

        func put(_ text: String, _ font: InkFont) {
            if w.maximumLength > 0, text.count > w.maximumLength { w.maximumLength = text.count }
            w.font = font.ns
            w.fontColor = ink.color
            w.widgetStringValue = text
        }
        func restore() {
            w.maximumLength = 0
            w.widgetStringValue = state.previousValue
            w.maximumLength = state.previousMaxLength
            if let f = state.previousFont { w.font = f }
            if let c = state.previousFontColor { w.fontColor = c }
        }
        /// Nombre de lignes de ce corps que le champ peut afficher.
        func rows(_ font: InkFont) -> Int {
            let pitch = font.fieldLineHeight
            if multiline { return max(0, Int(floor((b.height - 6) / pitch))) }
            return pitch <= b.height - 2 ? 1 : 0
        }

        // candidats : d'abord les tailles où tout tient sans couper de mot, puis la plus petite avec les mots coupés
        var candidates: [(InkFont, InkWrapped)] = []
        for size in InkLayout.sizes(from: ink.maxSize, downTo: minSize) {
            let font = ink.font(size)
            let n = rows(font)
            guard n > 0 else { continue }
            let wrapped = InkWrap.wrap(tokens, font: font, widths: [availWidth], maxLines: n, allowSplit: false)
            if !wrapped.truncated { candidates.append((font, wrapped)) }
        }
        let small = ink.font(minSize)
        let smallRows = max(1, rows(small))
        let fallback = (small, InkWrap.wrap(tokens, font: small, widths: [availWidth], maxLines: smallRows, allowSplit: true))
        let complete = !candidates.isEmpty
        if candidates.isEmpty { candidates = [fallback] }

        // on prend le premier candidat dont le dernier mot est effectivement visible dans le champ
        for (font, wrapped) in candidates {
            let lines = wrapped.lines
            guard !lines.isEmpty else { continue }
            let text = lines.joined(separator: " ")
            put(text, font)
            if (w.widgetStringValue ?? "") == text, lastWordShows(w, page: page, frame: frame, text: text) {
                return (state, font.size, wrapped.truncated || !complete)
            }
        }
        restore()
        return nil
    }

    /// Le dernier mot de `text` est-il visible dans le champ ? On compare le rendu du champ avec et sans ce mot.
    private static func lastWordShows(_ w: PDFAnnotation, page: PDFPage, frame: PageGeometry, text: String) -> Bool {
        let withText = text
        let words = text.split(separator: " ")
        let without = words.dropLast().joined(separator: " ")
        let rect = frame.zoneRect(fromPage: w.bounds).insetBy(dx: -2, dy: -2)
        guard let a = InkSnapshot.gray(page: page, rect: rect, scale: 5) else { return true }   // pas de rendu : on fait confiance
        let saved = w.widgetStringValue
        w.widgetStringValue = without
        let b = InkSnapshot.gray(page: page, rect: rect, scale: 5)
        w.widgetStringValue = saved ?? withText
        guard let b, a.count == b.count else { return true }
        var changed = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 24 { changed += 1; if changed >= 2 { return true } }
        return false
    }
}

/// Rendu d'un petit rectangle d'une page (annotations comprises), en niveaux de gris.
fileprivate enum InkSnapshot {
    /// `rect` : rectangle de l'espace des zones (page affichée) ; la page est rendue telle qu'on la voit.
    static func gray(page: PDFPage, rect: CGRect, scale: CGFloat) -> [UInt8]? {
        let frame = PageGeometry(page: page)
        let box = CGRect(origin: frame.origin, size: frame.displaySize)
        let r = rect.intersection(box)
        guard !r.isNull, r.width > 1, r.height > 1 else { return nil }
        let w = Int(ceil(r.width * scale)), h = Int(ceil(r.height * scale))
        var pixels = [UInt8](repeating: 255, count: w * h)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -(r.minX - box.minX), y: -(r.minY - box.minY))
            page.draw(with: .cropBox, to: ctx)
            return true
        }
        return ok ? pixels : nil
    }
}

// MARK: - Fichiers et annotations

fileprivate enum InkFiles {
    /// Les deux URL désignent-elles le même fichier (chemins identiques, liens symboliques, liens physiques) ?
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        if a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path { return true }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let ia = try? a.resourceValues(forKeys: keys).fileResourceIdentifier,
              let ib = try? b.resourceValues(forKeys: keys).fileResourceIdentifier else { return false }
        return ia.isEqual(ib)
    }

    /// Retire une annotation du document, y compris si PDFKit l'a rechargée sous une autre instance.
    static func detach(_ annotation: PDFAnnotation, from document: PDFDocument) {
        if let page = annotation.page, page.document === document {
            page.removeAnnotation(annotation)
            return
        }
        let name = annotation.value(forAnnotationKey: .name) as? String
        let sourcePage = annotation.page
        let sourcePageIndex = sourcePage.flatMap { source in
            source.document?.index(for: source)
        }
        let pageIndexes: [Int]
        if let sourcePageIndex, document.page(at: sourcePageIndex) != nil {
            pageIndexes = [sourcePageIndex]
        } else {
            pageIndexes = Array(0..<document.pageCount)
        }
        for index in pageIndexes {
            guard let page = document.page(at: index) else { continue }
            if let name, let match = page.annotations.first(where: { ($0.value(forAnnotationKey: .name) as? String) == name }) {
                page.removeAnnotation(match)
                return
            }
            guard annotation.userName == AnswerRenderer.annotationAuthor else { return }
            if let match = page.annotations.first(where: {
                $0.userName == annotation.userName
                    && $0.type == annotation.type
                    && $0.contents == annotation.contents
                    && abs($0.bounds.minX - annotation.bounds.minX) < 0.5
                    && abs($0.bounds.minY - annotation.bounds.minY) < 0.5
                    && abs($0.bounds.width - annotation.bounds.width) < 0.5
                    && abs($0.bounds.height - annotation.bounds.height) < 0.5
            }) {
                page.removeAnnotation(match)
                return
            }
        }
    }
}
