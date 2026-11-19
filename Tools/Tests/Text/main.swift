import Foundation
import PDFKit
import AppKit
import CoreText

// Test synthétique de la détection texte. Génère un PDF dont on connaît les trous, puis compare
// aux zones trouvées par ZoneDetector : un trou attendu sans zone est « manqué », une zone sans trou attendu est « fausse ».
//   texte_test <dossier_de_sortie>
// Dernière ligne : « SYNTHESE attendus=N trouves=M faux=K ».

struct Case { let text: String; let x: CGFloat; let hole: Bool }   // hole : un trou est attendu sur cette ligne

let cases: [Case] = [
    Case(text: "Nom du client ( )", x: 72, hole: true),
    Case(text: "Ville [ ] et code postal", x: 72, hole: true),
    Case(text: "Chapitre 1 ........................................ 3", x: 72, hole: false),
    Case(text: "Chapitre 2 ..................................... 12", x: 72, hole: false),
    Case(text: "Il était une fois... la suite de l'histoire", x: 72, hole: false),
    Case(text: "Ce qu'il faut retenir, etc... dans la phrase", x: 72, hole: false),
    Case(text: "Ce qui compte pour le client, c'est la qualité :", x: 72, hole: false),
    Case(text: "et le prix de vente, bien sûr.", x: 72, hole: false),
    Case(text: "Liste à compléter :", x: 72, hole: false),
    Case(text: "- premier point de la liste", x: 90, hole: false),
    Case(text: "Votre prénom :", x: 72, hole: true),
    Case(text: "Votre nom :", x: 72, hole: true),
    Case(text: "Date de naissance :", x: 72, hole: true),
    Case(text: "Le mot manquant est ……………………………………………………", x: 72, hole: true),
]

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let pdfURL = outDir.appendingPathComponent("synthetique.pdf")
var box = CGRect(x: 0, y: 0, width: 612, height: 792)
guard let ctx = CGContext(pdfURL as CFURL, mediaBox: &box, nil) else { print("PDF impossible à écrire"); exit(1) }
ctx.beginPDFPage(nil)
let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
var expectedY: [CGFloat] = []
for (i, c) in cases.enumerated() {
    let y: CGFloat = 740 - CGFloat(i) * 26
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: c.text, attributes: [.font: font]))
    ctx.textPosition = CGPoint(x: c.x, y: y)
    CTLineDraw(line, ctx)
    if c.hole { expectedY.append(y) }
}
ctx.endPDFPage()
ctx.closePDF()

guard let doc = PDFDocument(url: pdfURL), let page = doc.page(at: 0) else { print("PDF illisible"); exit(1) }
let analysis = ZoneDetector.analyze(page: page, index: 0, firstID: 1, needText: false)
var matched = Set<Int>()
var faux = 0
for z in analysis.zones {
    let y = z.rect.midY
    if let k = expectedY.indices.first(where: { abs(y - (expectedY[$0] + 4)) < 10 && !matched.contains($0) }) {
        matched.insert(k)
    } else {
        faux += 1
        let ctxText = z.contextBefore.suffix(50).replacingOccurrences(of: "\n", with: " ")
        print(String(format: "FAUX    y=%.0f x=%.0f %@ «%@»", y, z.rect.minX, z.source.rawValue, ctxText))
    }
}
for (k, y) in expectedY.enumerated() where !matched.contains(k) {
    print(String(format: "MANQUE  y=%.0f «%@»", y, cases.filter { $0.hole }[k].text))
}
print("SYNTHESE attendus=\(expectedY.count) trouves=\(matched.count) faux=\(faux)")
