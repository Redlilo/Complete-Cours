import Foundation
import PDFKit
import AppKit
import CoreText

// Tests de SchemaEngine / SchemaGrille, sans réseau réel : faux serveur local (mock.py) sur 127.0.0.1.
// Usage : schema_tests <mock.py> <dossier d'images de sortie>   (voir run.sh)

setvbuf(stdout, nil, _IONBF, 0)
var echecs: [String] = []
var nbControles = 0
func verifie(_ ok: Bool, _ message: @autoclosure () -> String) {
    nbControles += 1
    if !ok { echecs.append(message()); print("  ECHEC :", message()) }
}

let args = CommandLine.arguments
let mockPath = args[1]
let sortie = args[2]
try? FileManager.default.createDirectory(atPath: sortie, withIntermediateDirectories: true)

// MARK: - Images de test

func jpegUni(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Data {
    let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
    return PageImaging.jpegData(ctx.makeImage()!)!
}
let imgEx1 = jpegUni(1, 0, 0), imgEx2 = jpegUni(0, 1, 0), imgPage = jpegUni(0, 0, 1), imgCadre = jpegUni(1, 1, 0)

func demande(exemples: Int = 2) -> SchemaDemande {
    var ex: [(exemple: SchemaExemple, jpeg: Data)] = []
    if exemples >= 1 { ex.append((SchemaExemple(titre: "Va-et-vient", note: "le neutre est en bleu", fichierImage: "a.jpg"), imgEx1)) }
    if exemples >= 2 { ex.append((SchemaExemple(titre: "Marche-arrêt", fichierImage: "b.jpg"), imgEx2)) }
    return SchemaDemande(nomDocument: "Chapitre 3 - Schémas", numeroPage: 2, numeroZone: 3, pageJPEG: imgPage,
                         cadreGrilleJPEG: imgCadre, largeurGrille: 24, hauteurGrille: 12,
                         consigne: "Complète le schéma de câblage d'une lampe commandée par un disjoncteur.", exemples: ex)
}

// MARK: - Extraction / décodage (sans réseau)

print("Lecture de la réponse")
let bon = """
{"largeurGrille":99,"hauteurGrille":99,"remarque":"ok","symboles":[{"id":"Q1","type":"disjoncteur","x":3,"y":4,"rotation":90,"label":"Q1"},{"id":"H1","type":"lampe","x":3.5,"y":8,"rotation":0,"label":"H1"}],"fils":[{"de":"Q1.b","vers":"H1.a","via":[[3,6],[3.5,6]]}],"textes":[{"texte":"L1","x":1,"y":1}]}
"""
do {
    let s = try SchemaEngine.lire(bon, largeur: 24, hauteur: 12)
    verifie(s.largeurGrille == 24 && s.hauteurGrille == 12, "la taille de la grille doit venir de la demande")
    verifie(s.symboles.count == 2 && s.symboles[0].type == .disjoncteur && s.symboles[0].rotation == 90, "symboles mal lus")
    verifie(s.fils.count == 1 && s.fils[0].via == [[3, 6], [3.5, 6]], "fils mal lus")
    verifie(s.textes.first?.texte == "L1" && s.remarque == "ok", "textes ou remarque mal lus")
    let avecBarrieres = try SchemaEngine.lire("```json\n\(bon)\n```", largeur: 24, hauteur: 12)
    verifie(avecBarrieres.symboles.count == 2, "```json mal lu")
    let autour = try SchemaEngine.lire("Voici :\n\(bon)\nVoilà.", largeur: 24, hauteur: 12)
    verifie(autour.symboles.count == 2, "texte autour mal géré")
    let barrieresAutour = try SchemaEngine.lire("Voici le schéma :\n```json\n\(bon)\n```\nBonne chance", largeur: 24, hauteur: 12)
    verifie(barrieresAutour.fils.count == 1, "barrières au milieu d'un texte mal gérées")
    // champs manquants / types faibles
    let faible = try SchemaEngine.lire(#"{"symboles":[{"id":"S1","type":"interrupteur","x":"2,5","y":1}]}"#, largeur: 10, hauteur: 12)
    verifie(faible.symboles.first?.x == 2.5 && faible.symboles.first?.rotation == 0 && faible.fils.isEmpty, "valeurs par défaut mal gérées")
    // types inconnus : symbole et fils qui y touchent ignorés, signalés dans la remarque
    let inconnu = try SchemaEngine.lire(#"{"symboles":[{"id":"Q1","type":"disjoncteur","x":1,"y":1,"rotation":0,"label":""},{"id":"Z9","type":"fusee","x":2,"y":2,"rotation":0,"label":""},{"id":"Q1","type":"lampe","x":3,"y":3,"rotation":0,"label":""}],"fils":[{"de":"Z9.a","vers":"Q1.a","via":[]},{"de":"Q1.b","vers":"4,4","via":[]}],"textes":[],"remarque":""}"#, largeur: 10, hauteur: 12)
    verifie(inconnu.symboles.count == 2 && inconnu.fils.count == 1, "symbole inconnu : \(inconnu.symboles.count) symboles, \(inconnu.fils.count) fils")
    verifie(inconnu.remarque.contains("Z9"), "remarque : \(inconnu.remarque)")
    let rotLoin = try SchemaEngine.lire(#"{"symboles":[{"id":"A","type":"lampe","x":1,"y":1,"rotation":-90,"label":""},{"id":"B","type":"lampe","x":1,"y":1,"rotation":450,"label":""}]}"#, largeur: 10, hauteur: 12)
    verifie(rotLoin.symboles.map { $0.rotation } == [270, 90], "rotations hors plage : \(rotLoin.symboles.map { $0.rotation })")
} catch { verifie(false, "exception inattendue : \(error)") }
do {   // attaque : accolades dans le texte avant le JSON, rotations approximatives ou énormes
    let a = try SchemaEngine.lire("Voici {mon schéma} :\n\(bon)", largeur: 24, hauteur: 12)
    verifie(a.symboles.count == 2, "accolades avant le JSON : \(a.symboles.count) symboles")
    let r = try SchemaEngine.lire(#"{"symboles":[{"id":"A","type":"lampe","x":1,"y":1,"rotation":80},{"id":"B","type":"lampe","x":1,"y":1,"rotation":1e300},{"id":"C","type":"lampe","x":1,"y":1,"rotation":45}]}"#, largeur: 10, hauteur: 12)
    verifie(r.symboles.map { $0.rotation } == [90, 0, 90], "rotations approximatives : \(r.symboles.map { $0.rotation })")
} catch { verifie(false, "exception inattendue (attaque) : \(error)") }
for mauvais in [String(bon.prefix(70)), "pas du JSON", "", "{\"autre\": 1}", "[1,2]"] {
    do { _ = try SchemaEngine.lire(mauvais, largeur: 1, hauteur: 1); verifie(false, "« \(mauvais.prefix(20)) » aurait dû échouer") }
    catch SchemaErreur.illisible(let m) { verifie(m.contains("n'a pas pu être lue"), "message illisible : \(m)") }
    catch { verifie(false, "mauvaise erreur : \(error)") }
}

// MARK: - Message, schéma, prompt, accès

print("Message, schéma, prompt")
let msg = SchemaEngine.construireMessage(demande())
verifie(msg.images == [imgEx1, imgEx2, imgPage, imgCadre], "ordre des images : exemples, page, cadre")
let t = msg.texte
verifie(t.contains("Chapitre 3 - Schémas") && t.contains("page 2") && t.contains("numéro 3"), "texte : document, page, zone")
verifie(t.contains("24 unités de large sur 12 unités de haut") && t.contains("largeurGrille = 24"), "texte : taille de grille")
verifie(t.contains("Complète le schéma de câblage"), "texte : consigne")
verifie(t.contains("Image 1 : exemple « Va-et-vient » — remarque de l'élève : le neutre est en bleu"), "texte : exemple 1 + note")
verifie(t.contains("Image 2 : exemple « Marche-arrêt »") && t.contains("Image 3 : la page entière") && t.contains("Image 4 : le cadre de la zone 3"), "texte : numérotation des images")
let sansEx = SchemaEngine.construireMessage(demande(exemples: 0))
verifie(sansEx.images == [imgPage, imgCadre] && !sansEx.texte.contains("exemples"), "message sans exemple")
var quatre = demande(); quatre.exemples = Array(repeating: quatre.exemples[0], count: 5)
verifie(SchemaEngine.construireMessage(quatre).images.count == 5, "au plus 3 exemples (3 + page + cadre)")
verifie(SchemaEngine.modele == "claude-opus-5-5", "modèle")
let sys = SchemaEngine.promptSysteme
verifie(sys.contains(SchemaSymbolType.catalogueDuPrompt) && !SchemaSymbolType.catalogueDuPrompt.isEmpty && sys.contains("Seconde professionnelle MTNE") && sys.contains("Réponds uniquement en JSON"), "prompt système")
verifie(sys.contains("aucun prénom"), "prompt : prénoms")
let sch = SchemaEngine.schemaJSON
let props = (sch["properties"] as? [String: Any]) ?? [:]
verifie(Set(props.keys) == ["largeurGrille", "hauteurGrille", "symboles", "fils", "textes", "remarque"], "clés du schéma")
let enumTypes = (((((props["symboles"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any])?["type"]) as? [String: Any])?["enum"] as? [String]
verifie(enumTypes == SchemaSymbolType.allCases.map { $0.rawValue }, "enum des types")
verifie(JSONSerialization.isValidJSONObject(sch), "schéma JSON valide")
// Les clés du schéma correspondent à celles du Codable du contrat.
if let d = try? JSONEncoder().encode(SchemaElectrique(largeurGrille: 1, hauteurGrille: 1, symboles: [SchemaSymbole(id: "a", type: .lampe, x: 0, y: 0)], fils: [SchemaFil(de: "a", vers: "b")], textes: [SchemaTexte(texte: "t", x: 0, y: 0)])),
   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
    verifie(Set(o.keys) == Set(props.keys), "clés Codable ≠ clés du schéma : \(o.keys.sorted())")
    func cles(_ chemin: [String]) -> Set<String> {
        var n: Any? = sch
        for c in chemin { n = ((n as? [String: Any])?["properties"] as? [String: Any])?[c]; if let a = n as? [String: Any], let i = a["items"] { n = i } }
        return Set((((n as? [String: Any])?["properties"]) as? [String: Any] ?? [:]).keys)
    }
    for (nom, valeur) in o {
        if let arr = valeur as? [[String: Any]], let premier = arr.first {
            verifie(Set(premier.keys) == cles([nom]), "clés de \(nom) : \(premier.keys.sorted()) ≠ \(cles([nom]).sorted())")
        }
    }
}

verifie(SchemaEngine.motifIndisponible(cleAPI: nil, compteDispo: false) == "Les schémas électriques utilisent uniquement Claude Opus 5.5 : ajoute ta clé API dans les Réglages, ou connecte ton compte Claude.", "motif sans accès")
verifie(SchemaEngine.motifIndisponible(cleAPI: "  ", compteDispo: false) != nil, "clé blanche = pas d'accès")
verifie(SchemaEngine.motifIndisponible(cleAPI: "k", compteDispo: false) == nil && SchemaEngine.motifIndisponible(cleAPI: nil, compteDispo: true) == nil, "motif avec accès")

// MARK: - Grille

print("Grille")
func dim(_ w: CGFloat, _ h: CGFloat) -> (Double, Double) { let d = SchemaGrille.dimensionsGrille(pour: CGRect(x: 0, y: 0, width: w, height: h)); return (d.largeur, d.hauteur) }
verifie(dim(240, 120) == (24, 12), "240×120 -> 24×12 : \(dim(240, 120))")
verifie(dim(100, 100) == (12, 12), "carré")
verifie(dim(100, 300) == (6, 12), "borne basse 6 : \(dim(100, 300))")
verifie(dim(1000, 100) == (48, 12), "borne haute 48")
verifie(dim(130, 100) == (15.5, 12), "arrondi à 0,5 : \(dim(130, 100))")
verifie(dim(0, 0) == (6, 12), "boîte vide")

// PDF de test : un cadre à (100,500)-(400,650) avec un repère en son coin haut-gauche et un carré à 1/4 de sa largeur.
func fabriquePDF(chemin: String) {
    var media = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(URL(fileURLWithPath: chemin) as CFURL, mediaBox: &media, nil)!
    for _ in 0..<2 {
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(media)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(1.5)
        ctx.stroke(CGRect(x: 100, y: 500, width: 300, height: 150))                      // le cadre de la zone
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 100 + 300 / 4 - 10, y: 650 - 150 / 2 - 10, width: 20, height: 20))   // carré centré en grille (6, 6) pour 24×12
        ctx.fill(CGRect(x: 100, y: 640, width: 10, height: 10))                           // coin haut-gauche : (0,0)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.move(to: CGPoint(x: 60, y: 700)); ctx.addLine(to: CGPoint(x: 540, y: 700)); ctx.strokePath()
        ctx.endPDFPage()
    }
    ctx.closePDF()
}
let cheminPDF = sortie + "/test.pdf"
fabriquePDF(chemin: cheminPDF)
if let pdf = PDFDocument(url: URL(fileURLWithPath: cheminPDF)), let page = pdf.page(at: 0), let page2 = pdf.page(at: 1) {
    let box = CGRect(x: 100, y: 500, width: 300, height: 150)
    let d = SchemaGrille.dimensionsGrille(pour: box)
    verifie(d.largeur == 24 && d.hauteur == 12, "dimensions du cadre de test")
    if let jpeg = SchemaGrille.cadreAvecGrille(page: page, box: box, largeurGrille: d.largeur, hauteurGrille: d.hauteur),
       let img = NSBitmapImageRep(data: jpeg) {
        try? jpeg.write(to: URL(fileURLWithPath: sortie + "/cadre.jpg"))
        verifie(img.pixelsWide <= 1400 && img.pixelsHigh <= 1800 && img.pixelsWide > 800, "taille du cadre : \(img.pixelsWide)×\(img.pixelsHigh)")
        // Rapport marge : (1 + 2×8 %) × largeur de la zone.
        let ratio = Double(img.pixelsWide) / Double(img.pixelsHigh), attendu = (300 * 1.16) / (150 * 1.16)
        verifie(abs(ratio - attendu) < 0.02, "proportions : \(ratio) ≠ \(attendu)")
    } else { verifie(false, "cadreAvecGrille a échoué") }
    // Page tournée de 90° : le rendu doit rester cohérent (regarder cadre-90.jpg).
    page2.rotation = 90
    let box90 = CGRect(x: 100, y: 120, width: 150, height: 300)     // espace des zones de la page tournée (842 de large)
    let d90 = SchemaGrille.dimensionsGrille(pour: box90)
    if let j = SchemaGrille.cadreAvecGrille(page: page2, box: box90, largeurGrille: d90.largeur, hauteurGrille: d90.hauteur) {
        try? j.write(to: URL(fileURLWithPath: sortie + "/cadre-90.jpg"))
    } else { verifie(false, "rendu de page tournée") }
    // Zone au bord de la page : marge blanche, pas d'échec.
    let bord = CGRect(x: 0, y: 0, width: 200, height: 100)
    let db = SchemaGrille.dimensionsGrille(pour: bord)
    verifie(SchemaGrille.cadreAvecGrille(page: page, box: bord, largeurGrille: db.largeur, hauteurGrille: db.hauteur) != nil, "zone au bord de la page")
    verifie(SchemaGrille.cadreAvecGrille(page: page, box: .zero, largeurGrille: 12, hauteurGrille: 12) == nil, "boîte vide -> nil")
    if let tout = SchemaGrille.demande(page: page, box: box) { verifie(tout.largeur == 24 && !tout.cadreJPEG.isEmpty, "demande()") } else { verifie(false, "demande()") }
} else { verifie(false, "PDF de test illisible") }

// MARK: - Moteur contre le faux serveur

func lireCorps(_ scenario: String, _ dossier: String) -> [String: Any]? {
    guard let d = FileManager.default.contents(atPath: "\(dossier)/\(scenario).json") else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

let dossierMock = NSTemporaryDirectory() + "schema-mock-\(getpid())"
try? FileManager.default.createDirectory(atPath: dossierMock, withIntermediateDirectories: true)
let port = Int.random(in: 20000...40000)
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
proc.arguments = [mockPath, String(port), dossierMock]
try? proc.run()
for _ in 0..<50 {
    if (try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/_ping")!)) != nil { break }
    Thread.sleep(forTimeInterval: 0.1)
}

var reglages = ClaudeEngine.Tuning()
reglages.backoffBase = 0.01; reglages.rateLimitBase = 0.01; reglages.maxWait = 0.05
SchemaEngine.reglagesReseau = reglages
func appeler(_ scenario: String, cle: String = "cle-de-test-0123456789") async -> Result<SchemaElectrique, Error> {
    SchemaEngine.urlDeBase = URL(string: "http://127.0.0.1:\(port)/\(scenario)")!
    do { return .success(try await SchemaEngine.complete(demande(), acces: .cleAPI(cle))) } catch { return .failure(error) }
}
func nombreAppels(_ s: String) -> Int { (try? String(contentsOfFile: "\(dossierMock)/\(s).count"))?.count ?? 0 }

print("Moteur (faux serveur)")
switch await appeler("ok") {
case .success(let s):
    verifie(s.largeurGrille == 24 && s.hauteurGrille == 12 && s.symboles.count == 2, "ok : résultat")
case .failure(let e): verifie(false, "ok : \(e)")
}
if let b = lireCorps("ok", dossierMock) {
    verifie(b["model"] as? String == "claude-opus-5-5", "modèle envoyé : \(String(describing: b["model"]))")
    let interdits = ["temperature", "top_p", "top_k", "thinking", "tool_choice", "tools", "stream", "stop_sequences"]
    verifie(interdits.allSatisfy { b[$0] == nil }, "paramètres interdits présents : \(b.keys.sorted())")
    let oc = b["output_config"] as? [String: Any]
    let fmt = oc?["format"] as? [String: Any]
    verifie(fmt?["type"] as? String == "json_schema" && (fmt?["schema"] as? [String: Any]) != nil, "output_config.format")
    let sc = fmt?["schema"] as? [String: Any]
    verifie(sc?["additionalProperties"] as? Bool == false, "additionalProperties:false imposé")
    verifie((b["system"] as? String)?.contains(SchemaSymbolType.catalogueDuPrompt) == true, "système avec catalogue")
    let content = ((b["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]] ?? []
    let envoyees: [Data] = content.compactMap { bloc in
        guard bloc["type"] as? String == "image", let s = (bloc["source"] as? [String: Any]), s["media_type"] as? String == "image/jpeg",
              s["type"] as? String == "base64", let b64 = s["data"] as? String else { return nil }
        return Data(base64Encoded: b64)
    }
    verifie(envoyees == [imgEx1, imgEx2, imgPage, imgCadre], "images envoyées en base64 dans l'ordre (\(envoyees.count))")
    let textes = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
    verifie(textes.count == 1 && textes[0].contains("Image 4 : le cadre"), "un bloc de texte avec les consignes")
    verifie(((try? String(contentsOfFile: "\(dossierMock)/ok.headers")) ?? "").contains("\"has_key\": true"), "clé envoyée en en-tête")
    let brut = (try? String(contentsOfFile: "\(dossierMock)/ok.json")) ?? ""
    verifie(!brut.contains("cle-de-test"), "la clé ne doit pas être dans le corps")
} else { verifie(false, "corps de requête non reçu") }

for sc in ["fenced", "noisy"] {
    if case .success(let s) = await appeler(sc) { verifie(s.symboles.count == 2 && s.fils.count == 1, "\(sc) : lecture") }
    else { verifie(false, "\(sc) a échoué") }
}
if case .success(let s) = await appeler("unknown") { verifie(s.symboles.count == 2 && s.fils.count == 1 && s.remarque.contains("Z9"), "unknown : \(s.remarque)") }
else { verifie(false, "unknown a échoué") }
if case .success(let s) = await appeler("hors") {
    verifie(s.remarque.contains("À vérifier") && s.fils.isEmpty && s.symboles.first?.x == 24, "valider appelé : \(s.remarque) / x=\(String(describing: s.symboles.first?.x))")
}
else { verifie(false, "hors a échoué") }

switch await appeler("truncated") {
case .failure(SchemaErreur.illisible(let m)): verifie(m.contains("n'a pas pu être lue"), "tronquée : \(m)")
default: verifie(false, "tronquée : erreur .illisible attendue")
}
switch await appeler("refusal") {
case .failure(SchemaErreur.refuse(let m)): verifie(m.contains("refusé"), "refus : \(m)")
default: verifie(false, "refus : erreur .refuse attendue")
}
switch await appeler("auth401") {
case .failure(SchemaErreur.refuse(let m)):
    verifie(m.contains("refusé la clé API") && !m.contains("SECRET") && !m.contains("cle-de-test"), "401 : \(m)")
    verifie(nombreAppels("auth401") == 1, "401 : pas de relance (\(nombreAppels("auth401")) appels)")
default: verifie(false, "401 : erreur .refuse attendue")
}
switch await appeler("rate429") {
case .failure(SchemaErreur.autre(let m)):
    verifie(m.contains("limite le nombre de demandes"), "429 : \(m)")
    verifie(nombreAppels("rate429") == 3, "429 : 3 essais attendus (\(nombreAppels("rate429")))")
default: verifie(false, "429 : erreur .autre attendue")
}
switch await appeler("ok", cle: "   ") {
case .failure(SchemaErreur.indisponible(let m)): verifie(m == SchemaEngine.messageIndisponible, "aucun accès : \(m)")
default: verifie(false, "clé vide : .indisponible attendue")
}
// Réseau : rien n'écoute sur ce port.
SchemaEngine.urlDeBase = URL(string: "http://127.0.0.1:1")!
do { _ = try await SchemaEngine.complete(demande(), acces: .cleAPI("cle-de-test-0123456789")); verifie(false, "réseau : erreur attendue") }
catch SchemaErreur.autre(let m) { verifie(m.contains("Impossible de joindre"), "réseau : \(m)") }
catch { verifie(false, "réseau : mauvaise erreur \(error)") }

// Aucun journal dans les sources du moteur.
for f in ["SchemaEngine.swift", "SchemaGrille.swift"] {
    let src = (try? String(contentsOfFile: FileManager.default.currentDirectoryPath + "/Sources/Core/" + f)) ?? ""
    verifie(!src.isEmpty && !src.contains("print(") && !src.contains("NSLog") && !src.contains("os_log"), "\(f) : journal détecté ou fichier introuvable")
}
#if COMPTE_PERSO
verifie(true, "compilé avec COMPTE_PERSO (cas .compte compilé)")
#endif

print(echecs.isEmpty ? "OK : \(nbControles) contrôles" : "\(echecs.count) ÉCHEC(S) sur \(nbControles) contrôles")
proc.terminate()
try? FileManager.default.removeItem(atPath: dossierMock)
exit(echecs.isEmpty ? 0 : 1)
