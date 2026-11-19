import SwiftUI
import PDFKit
import AppKit

// MARK: - Surlignage des zones (dessiné par-dessus la page, jamais écrit dans le PDF)

/// Vue posée par PDFKit au-dessus d'une page. Elle dessine dans l'espace de la page PDF
/// (origine en bas à gauche, en points), comme les zones.
final class ZoneOverlayView: NSView {
    var zones: [Zone] = [] { didSet { needsDisplay = true } }
    var selectedID: Int? { didSet { needsDisplay = true } }
    /// Rectangle en cours de dessin (« Ajouter une zone »).
    var draft: CGRect? { didSet { needsDisplay = true } }
    /// Origine de la zone visible de la page (cropBox) : elle n'est pas toujours en (0, 0).
    var origin: CGPoint = .zero

    override var isFlipped: Bool { false }
    /// Les clics traversent le surlignage : c'est l'aperçu qui les reçoit.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: -origin.x, y: -origin.y)
        for z in zones where z.id != selectedID { drawZone(z, selected: false) }
        if let sel = zones.first(where: { $0.id == selectedID }) { drawZone(sel, selected: true) }
        if let d = draft {
            NSColor.systemOrange.withAlphaComponent(0.16).setFill()
            NSBezierPath(rect: d).fill()
            let p = NSBezierPath(rect: d)
            p.lineWidth = 1.5
            p.setLineDash([5, 3], count: 2, phase: 0)
            NSColor.systemOrange.setStroke()
            p.stroke()
        }
        ctx.restoreGState()
    }

    private func drawZone(_ z: Zone, selected: Bool) {
        let ignored = z.kind == .ignorer || !z.enabled
        let written = !z.answer.isEmpty && !ignored
        let base: NSColor = selected ? .systemOrange : (ignored ? .systemGray : .systemBlue)
        // une zone déjà remplie n'est qu'entourée : la réponse reste lisible
        let fillAlpha: CGFloat = selected ? (written ? 0.08 : 0.22) : (written || ignored ? 0 : 0.13)
        let strokeAlpha: CGFloat = selected ? 0.95 : (ignored ? 0.35 : 0.55)
        base.withAlphaComponent(fillAlpha).setFill()
        base.withAlphaComponent(strokeAlpha).setStroke()
        for r in shapes(of: z) {
            let path = NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2)
            path.lineWidth = selected ? 1.8 : 0.9
            if ignored { path.setLineDash([3, 2], count: 2, phase: 0) }
            if fillAlpha > 0 { path.fill() }
            path.stroke()
        }
        drawNumber(z.number, near: shapes(of: z).first ?? z.rect, color: base, selected: selected)
    }

    /// Une zone « lignes » est dessinée ligne par ligne (en suivant la pente d'un scan penché).
    private func shapes(of z: Zone) -> [CGRect] {
        if let b = z.box { return [b] }
        return z.lines.map { l in
            let h = max(z.textHeight * 1.25, 11)
            return CGRect(x: l.x0, y: min(l.y, l.yEnd), width: l.width, height: h + abs(l.yEnd - l.y))
        }
    }

    private func drawNumber(_ n: Int, near r: CGRect, color: NSColor, selected: Bool) {
        let text = "\(n)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let w = max(size.width + 4, 10), h: CGFloat = 10
        let pill = CGRect(x: r.minX - 1, y: r.maxY + 0.5, width: w, height: h)
        color.withAlphaComponent(selected ? 0.95 : 0.8).setFill()
        NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2).fill()
        text.draw(at: CGPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2), withAttributes: attrs)
    }
}

/// Donne à PDFKit une vue de surlignage par page et garde la liste des vues affichées pour les mettre à jour.
final class ZoneOverlayProvider: NSObject, PDFPageOverlayViewProvider {
    private var live: [Int: ZoneOverlayView] = [:]
    private var zonesByPage: [Int: [Zone]] = [:]
    private var selectedID: Int?
    private var draft: (page: Int, rect: CGRect)?

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let box = page.bounds(for: view.displayBox)
        let overlay = ZoneOverlayView(frame: box)
        overlay.origin = box.origin
        if let index = view.document?.index(for: page) {
            overlay.zones = zonesByPage[index] ?? []
            overlay.selectedID = selectedID
            overlay.draft = (draft?.page == index) ? draft?.rect : nil
            live[index] = overlay
        }
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        if let index = pdfView.document?.index(for: page), live[index] === overlayView { live[index] = nil }
    }

    func update(zones: [Zone], selectedID: Int?) {
        zonesByPage = Dictionary(grouping: zones, by: { $0.page })
        self.selectedID = selectedID
        for (index, overlay) in live {
            overlay.zones = zonesByPage[index] ?? []
            overlay.selectedID = selectedID
        }
    }

    func setDraft(page: Int?, rect: CGRect?) {
        if let page, let rect { draft = (page, rect) } else { draft = nil }
        for (index, overlay) in live { overlay.draft = (draft?.page == index) ? draft?.rect : nil }
    }

    /// Zone touchée par un point de la page `index` (la plus petite d'abord, pour les zones imbriquées).
    func zoneID(at point: CGPoint, page index: Int) -> Int? {
        let hits = (zonesByPage[index] ?? []).filter { z in
            let rects = z.box.map { [$0] } ?? z.lines.map {
                CGRect(x: $0.x0, y: min($0.y, $0.yEnd), width: $0.width, height: max(z.textHeight * 1.25, 11) + abs($0.yEnd - $0.y))
            }
            return rects.contains { $0.insetBy(dx: -3, dy: -3).contains(point) }
        }
        return hits.min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?.id
    }
}

// MARK: - L'aperçu : PDFView avec clic sur une zone et tracé d'un rectangle

final class PreviewPDFView: PDFView {
    weak var provider: ZoneOverlayProvider?
    var onZoneClicked: ((Int) -> Void)?
    var onRectDrawn: ((Int, CGRect) -> Void)?
    var drawingEnabled = false {
        didSet {
            guard drawingEnabled != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            if !drawingEnabled { dragStart = nil; provider?.setDraft(page: nil, rect: nil) }
        }
    }
    private var dragStart: (page: PDFPage, point: CGPoint)?

    override func resetCursorRects() {
        super.resetCursorRects()
        if drawingEnabled { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if drawingEnabled {
            if let page = page(for: local, nearest: false) {
                dragStart = (page, convert(local, to: page))
            }
            return
        }
        super.mouseDown(with: event)
        guard event.clickCount == 1, let page = page(for: local, nearest: false),
              let doc = document, let id = provider?.zoneID(at: convert(local, to: page), page: doc.index(for: page)) else { return }
        onZoneClicked?(id)
    }

    override func mouseDragged(with event: NSEvent) {
        guard drawingEnabled, let start = dragStart, let doc = document else { return super.mouseDragged(with: event) }
        let rect = clampedRect(from: start, event: event)
        provider?.setDraft(page: doc.index(for: start.page), rect: rect)
    }

    override func mouseUp(with event: NSEvent) {
        guard drawingEnabled, let start = dragStart, let doc = document else { return super.mouseUp(with: event) }
        dragStart = nil
        let rect = clampedRect(from: start, event: event)
        provider?.setDraft(page: nil, rect: nil)
        // un simple clic ou un trait minuscule n'est pas une zone
        guard rect.width >= 10, rect.height >= 6 else { return }
        onRectDrawn?(doc.index(for: start.page), rect)
    }

    private func clampedRect(from start: (page: PDFPage, point: CGPoint), event: NSEvent) -> CGRect {
        let local = convert(event.locationInWindow, from: nil)
        let end = convert(local, to: start.page)
        let bounds = start.page.bounds(for: displayBox)
        let a = CGPoint(x: min(max(start.point.x, bounds.minX), bounds.maxX), y: min(max(start.point.y, bounds.minY), bounds.maxY))
        let b = CGPoint(x: min(max(end.x, bounds.minX), bounds.maxX), y: min(max(end.y, bounds.minY), bounds.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

struct PDFPreview: NSViewRepresentable {
    @EnvironmentObject var model: CoursModel

    final class Coordinator {
        let provider = ZoneOverlayProvider()
        var lastRevealSerial = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PreviewPDFView {
        let view = PreviewPDFView(frame: .zero)
        view.provider = context.coordinator.provider
        view.pageOverlayViewProvider = context.coordinator.provider
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        view.setAccessibilityLabel("Aperçu du PDF")
        view.onZoneClicked = { [weak model] id in model?.select(id, from: .preview) }
        view.onRectDrawn = { [weak model] page, rect in model?.zoneDrawn(pageIndex: page, rect: rect) }
        model.previewView = view
        return view
    }

    func updateNSView(_ view: PreviewPDFView, context: Context) {
        let coordinator = context.coordinator
        if view.document !== model.document {
            view.document = model.document
            view.autoScales = true
            coordinator.lastRevealSerial = model.revealRequest?.serial ?? 0
        }
        coordinator.provider.update(zones: model.zones, selectedID: model.selectedZoneID)
        view.drawingEnabled = model.isDrawingZone

        if let request = model.revealRequest, request.serial != coordinator.lastRevealSerial {
            coordinator.lastRevealSerial = request.serial
            // un clic dans l'aperçu ne fait pas défiler : la zone est déjà à l'écran
            if request.source != .preview, let zone = model.zone(request.zoneID) {
                reveal(zone, in: view)
            }
        }
    }

    static func dismantleNSView(_ view: PreviewPDFView, coordinator: Coordinator) {
        view.pageOverlayViewProvider = nil
        view.onZoneClicked = nil
        view.onRectDrawn = nil
    }

    /// Fait défiler l'aperçu pour que la zone soit visible, avec un peu de texte autour.
    private func reveal(_ zone: Zone, in view: PDFView) {
        guard let page = view.document?.page(at: zone.page) else { return }
        let r = zone.rect
        view.go(to: r.insetBy(dx: -30, dy: -90), on: page)
    }
}
