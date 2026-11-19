import Foundation
import AppKit
import PDFKit

// Tests du passage de vérification (version personnelle : compiler avec -D COMPTE_PERSO).
// Faux générateur : aucun réseau, aucun programme claude, aucun quota consommé.
//   Tools/Tests/Verification/run.sh          (argument : dossier de travail pour le PDF d'essai)

guard CommandLine.arguments.count > 1 else {
    print("Usage : verification_tests <dossier de travail>")
    exit(2)
}
let workDir = CommandLine.arguments[1]

var failures: [String] = []
var passes = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        passes += 1
        print("  ok     \(name)")
    } else {
        failures.append(name)
        print("  ECHEC  \(name) \(detail())")
    }
}

// MARK: - Faux générateur

final class FakeGenerator: VerificationGenerator {
    var respond: (String) throws -> String
    var delayNs: UInt64 = 0
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var images = 0
    private(set) var schemas: [[String: Any]] = []
    private(set) var started = false

    init(respond: @escaping (String) throws -> String) { self.respond = respond }

    private func record(_ content: [[String: Any]], _ schema: [String: Any]) -> String {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        started = true
        schemas.append(schema)
        var text = ""
        for block in content {
            if block["type"] as? String == "image" { images += 1 }
            if block["type"] as? String == "text" { text = block["text"] as? String ?? "" }
        }
        return text
    }

    func generate(system: String, content: [[String: Any]], schema: [String: Any], timeout: TimeInterval?) async throws -> String {
        let text = record(content, schema)
        if delayNs > 0 { try await Task.sleep(nanoseconds: delayNs) }
        return try respond(text)
    }
}

func json(_ items: [[String: Any]]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["problemes": items])
    return String(data: data, encoding: .utf8)!
}

func item(_ zone: Int, _ action: String, _ explication: String, _ proposition: String) -> [String: Any] {
    ["zone": zone, "action": action, "explication": explication, "proposition": proposition]
}

func mkZone(id: Int, page: Int, number: Int, kind: ZoneKind, answer: String, before: String = "") -> Zone {
    var z = Zone(id: id, page: page, number: number, source: .texte,
                 box: CGRect(x: 72, y: 700 - CGFloat(number) * 30, width: 160, height: 14),
                 contextBefore: before, kind: kind, answer: answer)
    z.enabled = !answer.isEmpty
    return z
}

func analysis(_ page: Int) -> PageAnalysis {
    PageAnalysis(pageIndex: page, zones: [], transcript: "Texte de la page \(page + 1) avec ⟦1⟧ et ⟦2⟧.",
                 hasTextLayer: true, rotationUnsupported: false, fontSize: 11)
}

/// Schéma strict : aucune borne, objets fermés, tous les champs requis.
func schemaProblems(_ node: Any, path: String) -> [String] {
    var out: [String] = []
    if let d = node as? [String: Any] {
        for k in ["minLength", "maxLength", "minimum", "maximum", "minItems", "maxItems", "pattern", "format",
                  "exclusiveMinimum", "exclusiveMaximum", "minProperties", "maxProperties", "uniqueItems", "multipleOf"]
        where d[k] != nil {
            out.append("\(path) : borne « \(k) »")
        }
        if (d["type"] as? String) == "object" {
            if (d["additionalProperties"] as? Bool) != false { out.append("\(path) : additionalProperties n'est pas false") }
            let props = ((d["properties"] as? [String: Any]) ?? [:]).keys.sorted()
            let req = ((d["required"] as? [String]) ?? []).sorted()
            if props != req { out.append("\(path) : required ne couvre pas toutes les propriétés") }
        }
        for (k, v) in d { out += schemaProblems(v, path: path + "/" + k) }
    } else if let a = node as? [Any] {
        for (i, v) in a.enumerated() { out += schemaProblems(v, path: "\(path)[\(i)]") }
    }
    return out
}

// MARK: - PDF d'essai (trois pages blanches : seulement de quoi l'ouvrir)

let pdfURL = URL(fileURLWithPath: workDir).appendingPathComponent("verification-essai.pdf")
var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
if let ctx = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil) {
    for _ in 0..<3 {
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(mediaBox)
        ctx.endPDFPage()
    }
    ctx.closePDF()
}
check(PDFDocument(url: pdfURL)?.pageCount == 3, "PDF d'essai écrit (3 pages)", pdfURL.path)

print("Passage de vérification (faux générateur, aucun réseau)")

// 1. Zones vides et incohérentes détectées ; zones correctes non touchées
do {
    let zones = [
        mkZone(id: 1, page: 0, number: 1, kind: .mot, answer: "", before: "L'unité de tension est le ⟦1⟧"),
        mkZone(id: 2, page: 0, number: 2, kind: .question, answer: "", before: "Explique la loi d'Ohm."),
        mkZone(id: 3, page: 0, number: 3, kind: .mot, answer: "15 V", before: "La tension du secteur est de ⟦3⟧"),
        mkZone(id: 4, page: 0, number: 4, kind: .mot, answer: "", before: "Signature de l'élève : ⟦4⟧"),
        mkZone(id: 5, page: 0, number: 5, kind: .mot, answer: "électron", before: "Particule chargée négativement : ⟦5⟧"),
        mkZone(id: 7, page: 0, number: 7, kind: .question, answer: "Une réponse exacte.", before: "Donne une définition."),
    ]
    let gen = FakeGenerator { text in
        guard text.contains("Page 1 sur") else { return json([]) }
        return json([
            item(1, "corriger", "Le trou demande l'unité de tension.", "volt"),
            item(2, "corriger", "La consigne est claire et la case est vide.", "La loi d'Ohm relie la tension, l'intensité et la résistance : U = R × I."),
            item(3, "corriger", "La tension du secteur est de 230 V, pas 15 V.", "230 V"),
            item(4, "ignorer", "Signature de l'élève, pas un trou à remplir.", ""),
            item(5, "corriger", "Même réponse, seulement la casse.", "Électron."),
            item(7, "corriger", "Déjà juste.", "Une réponse exacte."),
            item(99, "corriger", "Zone inexistante sur cette page.", "x"),
        ])
    }
    do {
        let r = try await VerificationPass.run(url: pdfURL, analyses: [analysis(0)], zones: zones, generator: gen)
        let byZone = Dictionary(r.problems.map { ($0.zoneNumber, $0) }, uniquingKeysWith: { a, _ in a })
        check(gen.calls == 1, "une seule requête pour une page", "\(gen.calls)")
        check(gen.images == 1, "image JPEG de la page envoyée avec la requête", "\(gen.images)")
        check(gen.schemas.count == 1, "schéma transmis à la requête")
        check(r.problems.map { $0.zoneNumber } == [1, 2, 3, 4], "zones signalées : 1, 2, 3, 4 seulement",
              "\(r.problems.map { $0.zoneNumber })")
        check(byZone[1]?.kind == .vide && byZone[1]?.proposal == "volt", "zone vide détectée, proposition « volt »")
        check(byZone[2]?.kind == .vide && (byZone[2]?.proposal.hasPrefix("La loi d'Ohm") ?? false),
              "question vide détectée (type vide même si l'IA dit incohérent)")
        check(byZone[3]?.kind == .incoherent && byZone[3]?.proposal == "230 V", "unité fausse détectée : « 15 V » -> « 230 V »")
        check(byZone[4]?.action == .ignorer && byZone[4]?.proposal == "", "signature marquée « ignorer », sans proposition")
        check(byZone[5] == nil, "mot correct (seule la casse diffère) non réécrit")
        check(byZone[7] == nil, "réponse correcte non touchée")
        check(byZone[99] == nil, "numéro de zone inconnu ignoré")
        check(r.pagesChecked == [0] && r.pageErrors.isEmpty, "page vérifiée sans erreur")
    } catch {
        check(false, "passage de vérification (cas 1) sans erreur", "\(error)")
    }
}

// 2. Mots non réécrits sauf erreur visible ; explication bornée
do {
    let zones = [
        mkZone(id: 11, page: 1, number: 1, kind: .mot, answer: "électron", before: "Particule chargée négativement : ⟦1⟧"),
        mkZone(id: 12, page: 1, number: 2, kind: .mot, answer: "chlore", before: "Gaz vert : ⟦2⟧"),
        mkZone(id: 13, page: 1, number: 3, kind: .mot, answer: "oxygène", before: "Gaz vital : ⟦3⟧"),
        mkZone(id: 14, page: 1, number: 4, kind: .question, answer: "Réponse A", before: "Question ouverte."),
    ]
    let gen = FakeGenerator { text in
        guard text.contains("Page 2 sur") else { return json([]) }
        return json([
            item(1, "corriger", "Un proton est chargé positivement, pas l'électron.", "proton"),
            item(2, "corriger", "Forme seulement.", "Chlore."),
            item(3, "corriger", "Réécriture en phrase.", "dioxygène ou oxygène moléculaire de la sorte"),
            item(4, "corriger", String(repeating: "a", count: 1000), "Réponse B"),
        ])
    }
    do {
        let r = try await VerificationPass.run(url: pdfURL, analyses: [analysis(1)], zones: zones, generator: gen)
        let nums = r.problems.map { $0.zoneNumber }
        check(nums == [1, 4], "mot faux corrigé, mots réécrits (casse, phrase) refusés", "\(nums)")
        check(r.problems.first(where: { $0.zoneNumber == 1 })?.proposal == "proton", "« électron » -> « proton » accepté")
        let expl = r.problems.first(where: { $0.zoneNumber == 4 })?.explanation.count ?? -1
        check(expl > 0 && expl <= VerificationPass.maxExplanationChars, "explication bornée à 400 caractères", "\(expl)")
        check(r.problems.first(where: { $0.zoneNumber == 4 })?.kind == .incoherent, "réponse remplie fausse = incohérente")
    } catch {
        check(false, "passage de vérification (cas 2) sans erreur", "\(error)")
    }
}

// 3. Une page en erreur n'arrête pas les autres
do {
    let zones = [
        mkZone(id: 21, page: 0, number: 1, kind: .mot, answer: ""),
        mkZone(id: 22, page: 1, number: 1, kind: .mot, answer: ""),
        mkZone(id: 23, page: 2, number: 1, kind: .mot, answer: ""),
    ]
    let gen = FakeGenerator { text in
        if text.contains("Page 1 sur") { return "{\"problemes\": [{\"zone\": 1, \"action\": " }  // réponse coupée
        if text.contains("Page 2 sur") { throw EngineError.network("Délai dépassé : Claude n'a pas répondu à temps.") }
        return json([item(1, "corriger", "Il manque l'unité.", "volt")])
    }
    do {
        let r = try await VerificationPass.run(url: pdfURL, analyses: [analysis(0), analysis(1), analysis(2)], zones: zones, generator: gen)
        check(gen.calls == 3, "les trois pages ont été essayées", "\(gen.calls)")
        check(r.pageErrors.map { $0.pageIndex } == [0, 1], "pages en erreur notées (coupée, délai)", "\(r.pageErrors)")
        check(r.problems.map { $0.pageIndex } == [2] && r.pagesChecked == [2], "la page 3 est tout de même vérifiée")
    } catch {
        check(false, "une page en erreur n'arrête pas les autres", "\(error)")
    }
}

// 4. Erreur fatale : tout s'arrête
do {
    let zones = [
        mkZone(id: 31, page: 0, number: 1, kind: .mot, answer: ""),
        mkZone(id: 32, page: 1, number: 1, kind: .mot, answer: ""),
        mkZone(id: 33, page: 2, number: 1, kind: .mot, answer: ""),
    ]
    let gen = FakeGenerator { text in
        if text.contains("Page 2 sur") { throw EngineError.unavailable("Ta connexion Claude a expiré : reconnecte-toi dans les Réglages.") }
        return json([])
    }
    do {
        _ = try await VerificationPass.run(url: pdfURL, analyses: [analysis(0), analysis(1), analysis(2)], zones: zones, generator: gen)
        check(false, "erreur fatale propagée", "aucune erreur levée")
    } catch let e as EngineError {
        check(e.isFatal && gen.calls == 2, "erreur fatale propagée et plus aucune page essayée", "appels : \(gen.calls)")
    } catch {
        check(false, "erreur fatale propagée", "\(error)")
    }
}

// 5. Annulation
do {
    let zones = [
        mkZone(id: 41, page: 0, number: 1, kind: .mot, answer: ""),
        mkZone(id: 42, page: 1, number: 1, kind: .mot, answer: ""),
        mkZone(id: 43, page: 2, number: 1, kind: .mot, answer: ""),
    ]
    let gen = FakeGenerator { _ in json([]) }
    gen.delayNs = 2_000_000_000
    let task = Task {
        try await VerificationPass.run(url: pdfURL, analyses: [analysis(0), analysis(1), analysis(2)], zones: zones, generator: gen)
    }
    var waited = 0
    while !gen.started && waited < 500 {
        try? await Task.sleep(nanoseconds: 10_000_000)
        waited += 1
    }
    task.cancel()
    do {
        _ = try await task.value
        check(false, "annulation : CancellationError levée", "rien levé")
    } catch is CancellationError {
        check(gen.calls <= 1, "annulation : CancellationError, aucune page suivante lancée", "appels : \(gen.calls)")
    } catch {
        check(false, "annulation : CancellationError levée", "\(error)")
    }
}

// 6. Schéma : restrictions respectées
do {
    let problems = schemaProblems(VerificationPass.schema, path: "")
    check(problems.isEmpty, "schéma strict : aucune borne, objets fermés, requis complets", problems.joined(separator: " ; "))
    check(VerificationPass.model == "opus", "modèle de relecture : Opus")
}

// 7. Réglage désactivé : aucun appel ; activé avec un programme absent : erreur fatale du moteur
do {
    let base = ClaudeCodeEngine(cli: URL(fileURLWithPath: "/nonexistent/claude-verification-test"))
    let zones = [mkZone(id: 51, page: 0, number: 1, kind: .mot, answer: "")]
    do {
        let off = try await CoursPipeline.verifyAfterCompletion(url: pdfURL, analyses: [analysis(0)], zones: zones,
                                                                engine: base, enabled: false)
        check(off == nil, "réglage désactivé : aucun passage, aucun appel")
    } catch {
        check(false, "réglage désactivé : aucun passage", "\(error)")
    }
    do {
        _ = try await CoursPipeline.verifyAfterCompletion(url: pdfURL, analyses: [analysis(0)], zones: zones,
                                                          engine: base, enabled: true)
        check(false, "réglage activé : le passage est lancé", "aucune erreur (programme absent attendu)")
    } catch let e as EngineError {
        check(e.isFatal, "réglage activé : le passage est lancé (programme absent -> erreur fatale)", "\(e)")
    } catch {
        check(false, "réglage activé : le passage est lancé", "\(error)")
    }
    let other = FakeGenerator { _ in json([]) }
    let notClaudeCode = try? await CoursPipeline.verifyAfterCompletion(url: pdfURL, analyses: [analysis(0)], zones: zones,
                                                                       engine: FakeEngineForGate(), enabled: true)
    check(notClaudeCode == nil && other.calls == 0, "moteur autre que « Claude (mon compte) » : pas de passage")
}

print("")
print("Résultat : \(passes) réussi(s), \(failures.count) échec(s).")
if !failures.isEmpty {
    print("Échecs : " + failures.joined(separator: " ; "))
    exit(1)
}
exit(0)

// Moteur de complétion quelconque (ni « Claude (mon compte) »), pour le test du garde-fou.
final class FakeEngineForGate: CompletionEngine {
    let displayName = "Faux moteur"
    let usesImages = false
    let maxConcurrentPages = 1
    func complete(_ request: PageRequest) async throws -> [ZoneAnswer] { [] }
    func humanize(_ items: [HumanizeItem]) async throws -> [Int: String] { [:] }
}
