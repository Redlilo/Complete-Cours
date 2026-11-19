import Foundation
import CoreGraphics
import PDFKit

// Tests de l'estimation du coût (Sources/Core/CostEstimate.swift). Aucun vrai cours, aucun réseau.

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("ÉCHEC (ligne \(line)) : \(what)") }
}
func near(_ a: Double?, _ b: Double, _ tol: Double = 1e-9) -> Bool { a.map { abs($0 - b) <= tol } ?? false }

let opus = CostEngine.claudeAPI(label: "Claude Opus 5.5", inputPerMillion: 4, outputPerMillion: 20)
let sonnet = CostEngine.claudeAPI(label: "Claude Sonnet 5.5", inputPerMillion: 2, outputPerMillion: 10)
let haiku = CostEngine.claudeAPI(label: "Claude Haiku 5.5", inputPerMillion: 0.10, outputPerMillion: 0.50)
func item(_ p: String, _ n: Int?) -> CostItem { CostItem(path: p, pages: n) }

// valeurs : une page, recalées sur 4 ¢ / 2 ¢ / 0,1 ¢ (borne haute)
let one = [item("Maths/Cours/Suites.pdf", 1)]
let eo = CostEstimate.compute(items: one, engine: opus)
check(near(eo.highUSD, 0.042), "Opus haut = 4,2 ¢ : \(String(describing: eo.highUSD))")
check(near(eo.lowUSD, (3100 * 4 + 400 * 20) / 1e6), "Opus bas")
check(near(CostEstimate.compute(items: one, engine: sonnet).highUSD, 0.021), "Sonnet haut = 2,1 ¢")
check(near(CostEstimate.compute(items: one, engine: haiku).highUSD, 0.00105, 1e-9), "Haiku haut = 0,1 ¢")
check((eo.lowUSD ?? 9) < (eo.highUSD ?? 0), "bas < haut")
check(eo.pages == 1 && eo.courses == 1, "1 cours, 1 page")

// linéarité et plusieurs cours
let many = CostEstimate.compute(items: [item("A/a.pdf", 4), item("A/b.pdf", 6)], engine: opus)
check(many.pages == 10 && many.courses == 2, "total des pages")
check(near(many.highUSD, 0.42), "10 pages Opus haut = 0,42 $")

// pages = 0 et sélection vide
let zero = CostEstimate.compute(items: [item("A/a.pdf", 0)], engine: opus)
check(zero.pages == 0 && zero.lowUSD == nil && zero.highUSD == nil, "pages = 0 : pas de prix")
check(zero.summary.contains("impossible d'estimer"), "pages = 0 : message")
let empty = CostEstimate.compute(items: [], engine: opus)
check(empty.courses == 0 && empty.summary.contains("Rien à compléter"), "sélection vide")

// PDF illisible
let bad = CostEstimate.compute(items: [item("A/a.pdf", 3), item("A/b.pdf", nil)], engine: opus)
check(bad.pages == 3 && bad.unreadable == 1 && bad.summary.contains("illisible"), "PDF illisible signalé")

// moteur inconnu, Apple, compte
let unk = CostEstimate.compute(items: one, engine: .unknown)
check(unk.lowUSD == nil && unk.summary.contains("n'est pas connu"), "moteur inconnu")
let apple = CostEstimate.compute(items: one, engine: .apple)
check(apple.lowUSD == nil && apple.summary.contains("gratuit") && apple.summary.contains("plus lent"), "Apple gratuit, plus lent")
let acc = CostEstimate.compute(items: [item("A/a.pdf", 3)], engine: .claudeAccount(label: "Claude (mon compte)", inputPerMillion: 4, outputPerMillion: 20))
check(near(acc.lowSeconds, 30) && near(acc.highSeconds, 60), "compte : 10 à 20 s par page")
check(acc.summary.contains("forfait Claude") && acc.summary.contains("Équivalent en coût API"), "compte : forfait + équivalent")
let acc2 = CostEstimate.compute(items: one, engine: .claudeAccount(label: "x", inputPerMillion: nil, outputPerMillion: nil))
check(acc2.lowUSD == nil && acc2.lowSeconds != nil, "compte sans prix connu")

// jamais d'évaluation comptée
let evals = CostEstimate.compute(items: [
    item("Maths/Évaluations/Contrôle 1.pdf", 5), item("Maths/Cours/Contrôle 2.pdf", 4), item("Français/Eval/Fiche.pdf", 3),
    item("Histoire/eval chapitre 3.pdf", 2), CostItem(path: "Maths/Cours/Fiche.pdf", pages: 7, isEvaluation: true),
    item("Maths/Cours/Fiche.pdf", 2)], engine: opus)
check(evals.courses == 1 && evals.pages == 2 && evals.skippedEvaluations == 5, "évaluations écartées : \(evals.courses)/\(evals.pages)/\(evals.skippedEvaluations)")
check(evals.summary.contains("jamais complétées ni lues"), "message évaluations")
check(CostEstimate.isEvaluationPath("Physique-Chimie/Évaluations/a.pdf"), "dossier Évaluations")
check(!CostEstimate.isEvaluationPath("Maths/Cours/Séquence 1.pdf"), "cours normal")

// textes
check(CostEstimate.dollars(0.042) == "0,04 $" && CostEstimate.dollars(0.001) == "moins de 0,01 $", "format dollars")
check(CostEstimate.duration(45) == "45 s" && CostEstimate.duration(600) == "10 min", "format durée")
check(eo.summary.contains("estimations, pas des mesures"), "texte honnête")
check(eo.summary.contains("de ") && eo.summary.contains(" à "), "fourchette")

// PageCounter : vrai PDF fabriqué, et jamais d'ouverture d'une évaluation
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cout-tests-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
func makePDF(_ url: URL, pages: Int) {
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    for _ in 0..<pages { ctx.beginPDFPage(nil); ctx.endPDFPage() }
    ctx.closePDF()
}
let cours = dir.appendingPathComponent("Cours.pdf"), controle = dir.appendingPathComponent("Contrôle 1.pdf")
makePDF(cours, pages: 3); makePDF(controle, pages: 4)
check(PageCounter.pages(of: cours) == 3, "pages d'un PDF")
check(PageCounter.pages(of: controle) == nil, "évaluation : jamais ouverte")
check(PageCounter.pages(of: cours, relativePath: "Maths/Évaluations/Cours.pdf") == nil, "évaluation par dossier")
check(PageCounter.pages(of: dir.appendingPathComponent("absent.pdf")) == nil, "fichier absent")

if failures == 0 { print("Cost : tout est vert."); exit(0) }
print("Cost : \(failures) échec(s)."); exit(1)
