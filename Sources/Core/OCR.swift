import Foundation
import Vision
import CoreGraphics

enum OCR {
    /// Reconnaît le texte d'une page rendue (pour les PDF scannés sans couche texte).
    /// Les lignes sont renvoyées en espace page PDF, dans l'ordre de lecture.
    static func layout(image: CGImage, geometry: PageGeometry) -> TextLayout {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return TextLayout(lines: []) }

        let W = CGFloat(image.width), H = CGFloat(image.height)
        var items: [TextLine] = []
        for obs in request.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            var text = cand.string.trimmingCharacters(in: .whitespaces)
            // Les pointillés lus comme du texte sont retirés : ils seront traités comme des zones.
            text = text.replacingOccurrences(of: "[._…·\\-–—]{4,}", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            let bb = obs.boundingBox
            let imgRect = CGRect(x: bb.minX * W, y: (1 - bb.maxY) * H, width: bb.width * W, height: bb.height * H)
            items.append(TextLine(text: text, bbox: geometry.toPage(rect: imgRect), globalStart: nil))
        }
        // ordre de lecture : de haut en bas, puis de gauche à droite sur une même ligne
        items.sort { a, b in
            let tol = min(a.bbox.height, b.bbox.height) * 0.5
            if abs(a.bbox.midY - b.bbox.midY) > tol { return a.bbox.midY > b.bbox.midY }
            return a.bbox.minX < b.bbox.minX
        }
        return TextLayout(lines: items)
    }
}
