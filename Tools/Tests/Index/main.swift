import Foundation
import PDFKit
import AppKit

// Tests de l'index de recherche (ContentIndex) et des cours récents (Recents). PDF fabriqués, aucun vrai cours, aucun réseau.

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("ÉCHEC (ligne \(line)) : \(what)") }
}

let work = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
    .appendingPathComponent("run-\(getpid())")
try? FileManager.default.removeItem(at: work)
let fm = FileManager.default
let root = work.appendingPathComponent("Cours")
try fm.createDirectory(at: root, withIntermediateDirectories: true)

// MARK: fabrication de PDF

func makePDF(_ url: URL, pages: [String]) {
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { fatalError("PDF impossible") }
    for text in pages {
        ctx.beginPDFPage(nil)
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        (text as NSString).draw(in: CGRect(x: 40, y: 600, width: 500, height: 200),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

/// Scan factice : chaque page est une image (aucune couche texte).
func makeScan(_ url: URL, pages: [String]) {
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { fatalError("PDF impossible") }
    for text in pages {
        let img = NSImage(size: NSSize(width: 1190, height: 1684), flipped: false) { r in
            NSColor.white.setFill(); r.fill()
            (text as NSString).draw(in: CGRect(x: 80, y: 1200, width: 1000, height: 300),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
            return true
        }
        var rect = CGRect(origin: .zero, size: img.size)
        ctx.beginPDFPage(nil)
        if let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) { ctx.draw(cg, in: box) }
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

func files() -> [LibraryFile] { LibraryTree.scan(root) }
func index(_ name: String = "cache") -> ContentIndex { ContentIndex(cacheURL: work.appendingPathComponent("\(name).json")) }
func names(_ hits: [ContentHit]) -> [String] { hits.map { $0.url.deletingPathExtension().lastPathComponent } }

makePDF(root.appendingPathComponent("Physique/Chimie 1.pdf"),
        pages: ["Les solutions aqueuses.", "Le pH mesure l'acidité. Un pH bas : acide. Les ions H3O+ sont en excès. pH pH."])
makePDF(root.appendingPathComponent("Physique/Électricité.pdf"),
        pages: ["La loi de Coulomb décrit la force entre deux charges. COLOMB est une faute fréquente. Électricité statique."])
makePDF(root.appendingPathComponent("Réseaux/Cours VLAN.pdf"),
        pages: ["Introduction aux réseaux.", "Un VLAN sépare un réseau en plusieurs domaines. VLAN VLAN. Le pH n'a rien à voir.", "Les ions n'ont rien à voir non plus."])
makePDF(root.appendingPathComponent("Réseaux/Eval/Évaluation réseaux.pdf"), pages: ["Sujet secret : le VLAN 99 et le mot ZEBRE."])
makePDF(root.appendingPathComponent("Maths/Contrôle fin de thème.pdf"), pages: ["Question sur la fonction affine ZEBRE."])
makeScan(root.appendingPathComponent("Maths/Scan.pdf"), pages: ["Theoreme de Pythagore", "page deux", "page trois", "page quatre", "page cinq SECRETE"])

// 1. Indexation, évaluations exclues, progression
do {
    let idx = index()
    var progress: [(Int, Int)] = []
    var ocrCalls = 0
    idx.ocrPage = { page in ocrCalls += 1; return "texte reconnu Pythagore page \(ocrCalls)" }
    idx.update(files: files(), progress: { progress.append(($0, $1)) })
    check(idx.documentCount == 4, "4 cours indexés (2 évaluations exclues), trouvé \(idx.documentCount)")
    check(progress.first.map { $0 == (0, 4) } ?? false, "progression initiale 0/4 : \(progress)")
    check(progress.last.map { $0 == (4, 4) } ?? false, "progression finale 4/4 : \(progress)")
    check(idx.search("ZEBRE").isEmpty, "contenu d'une évaluation jamais trouvé")
    check(idx.search("secret").isEmpty, "le contenu des évaluations n'est pas indexé")
    let evalEntries = files().filter { $0.isEvaluation }.compactMap { idx.entry(for: $0.url) }
    check(evalEntries.isEmpty, "aucune entrée de cache pour une évaluation")
    let cacheText = (try? String(contentsOf: work.appendingPathComponent("cache.json"), encoding: .utf8)) ?? ""
    check(!cacheText.contains("ZEBRE") && !cacheText.contains("Sujet secret"), "le fichier de cache ne contient pas le texte des évaluations")
    check(ocrCalls == 4, "OCR limité aux 4 premières pages du scan, appels : \(ocrCalls)")
    let scan = idx.entry(for: root.appendingPathComponent("Maths/Scan.pdf"))
    check(scan?.ocr == true && scan?.pages.count == 5 && scan?.pages[4].isEmpty == true, "scan : OCR des 4 premières pages seulement")
    check(idx.search("pythagore").first?.url.lastPathComponent == "Scan.pdf", "mot du scan trouvé via l'OCR")
    let txt = idx.entry(for: root.appendingPathComponent("Physique/Chimie 1.pdf"))
    check(txt?.ocr == false, "un PDF avec texte n'est pas passé à l'OCR")
}

// 2. Recherche : accents, casse, mots multiples, classement, extrait, page
do {
    let idx = index()   // rechargé depuis le cache écrit au test 1
    check(idx.documentCount == 4, "cache rechargé : \(idx.documentCount)")
    let ph = idx.search("pH")
    check(names(ph).first == "Chimie 1", "« pH » : Chimie 1 en premier (4 occurrences), trouvé \(names(ph))")
    check(ph.first?.page == 2, "« pH » : page 2, trouvé \(String(describing: ph.first?.page))")
    check(ph.first?.snippet.contains("pH") == true, "l'extrait contient le mot : \(ph.first?.snippet ?? "")")
    check(names(ph).contains("Cours VLAN"), "« pH » aussi dans Cours VLAN")
    check(!names(ph).contains("Électricité"), "« pH » ne trouve pas Électricité")
    check(names(idx.search("PH")) == names(ph), "insensible à la casse")
    check(names(idx.search("electricite")) == ["Électricité"], "insensible aux accents : \(names(idx.search("electricite")))")
    check(names(idx.search("ÉLECTRICITÉ")) == ["Électricité"], "accents et majuscules")
    check(names(idx.search("colomb")) == ["Électricité"], "« colomb » trouve Coulomb/COLOMB seulement par préfixe de mot : \(names(idx.search("colomb")))")
    check(names(idx.search("vlan")) == ["Cours VLAN"], "« VLAN » : \(names(idx.search("vlan")))")
    check(idx.search("vlan").first?.page == 2, "« VLAN » page 2")
    check(names(idx.search("ions pH")) == ["Chimie 1", "Cours VLAN"] || names(idx.search("ions pH")).first == "Chimie 1",
          "« ions pH » : tous les mots présents, Chimie 1 d'abord : \(names(idx.search("ions pH")))")
    check(names(idx.search("ions vlan")) == ["Cours VLAN"], "« ions vlan » : seul Cours VLAN a les deux")
    check(idx.search("ions zzzz").isEmpty, "un mot absent exclut le cours")
    check(idx.search("   ").isEmpty && idx.search("").isEmpty, "requête vide : aucun résultat")
    check(idx.search("aphique").isEmpty, "un mot doit commencer un mot du texte")
    let terms = ContentIndex.terms("Ions, pH!")
    check(terms == ["ions", "ph"], "découpage des mots : \(terms)")
    let r = ContentIndex.highlightRanges(in: "Le pH mesure", terms: ["ph"])
    check(r.count == 1, "mot à surligner repéré")
}

// 3. Cache : inchangé = rien à relire ; taille ou date changées = relu
do {
    let idx = index()
    idx.ocrPage = { _ in "" }
    check(idx.pending(files()).isEmpty, "cache à jour : rien à relire")
    var n = 0
    idx.update(files: files(), progress: { _, _ in n += 1 })
    check(n == 0, "aucune relecture si rien n'a changé")

    let chimie = root.appendingPathComponent("Physique/Chimie 1.pdf")
    let old = try fm.attributesOfItem(atPath: chimie.path)[.modificationDate] as! Date
    try fm.setAttributes([.modificationDate: old.addingTimeInterval(3600)], ofItemAtPath: chimie.path)
    check(idx.pending(files()).map(\.name) == ["Chimie 1"], "date changée : relu")
    idx.update(files: files())
    check(idx.pending(files()).isEmpty, "après relecture, plus rien en attente")

    try fm.removeItem(at: chimie)
    makePDF(chimie, pages: ["Le sodium et la mole.", "Deuxième page du cours."])   // taille différente
    check(idx.pending(files()).map(\.name) == ["Chimie 1"], "taille changée : relu")
    idx.update(files: files())
    check(names(idx.search("sodium")) == ["Chimie 1"], "nouveau contenu trouvé")
    check(!names(idx.search("acidité")).contains("Chimie 1"), "l'ancien contenu a disparu")

    // fichier supprimé : retiré de l'index
    try fm.removeItem(at: root.appendingPathComponent("Réseaux/Cours VLAN.pdf"))
    idx.update(files: files())
    check(idx.search("vlan").isEmpty, "cours supprimé retiré de l'index")

    // une évaluation qui était dans le cache (ancienne version) est retirée
    let sneaky = root.appendingPathComponent("Réseaux/Eval/Évaluation réseaux.pdf")
    let idx2 = index()
    let fake = LibraryFile(url: sneaky, folders: ["Réseaux", "Eval"], isEvaluation: false, state: .vierge)
    idx2.update(files: [fake])     // l'appelant se trompe : on ne protège que par le drapeau, test de non-régression ci-dessous
    idx2.update(files: files())
    check(idx2.entry(for: sneaky) == nil, "une évaluation connue comme telle est retirée du cache")
}

// 4. Cache corrompu ou d'une autre version
do {
    let bad = work.appendingPathComponent("corrompu.json")
    try Data("{ pas du json \u{0}\u{1}".utf8).write(to: bad)
    let idx = ContentIndex(cacheURL: bad)
    check(idx.documentCount == 0 && idx.search("pH").isEmpty, "cache corrompu : index vide, sans plantage")
    idx.update(files: files())
    check(idx.documentCount > 0, "l'index se reconstruit après un cache corrompu")
    check(ContentIndex(cacheURL: bad).documentCount == idx.documentCount, "cache réécrit proprement")
    let missing = ContentIndex(cacheURL: work.appendingPathComponent("absent/dossier/x.json"))
    check(missing.documentCount == 0, "cache absent : index vide")
    missing.update(files: files())
    check(fm.fileExists(atPath: work.appendingPathComponent("absent/dossier/x.json").path), "dossier du cache créé")
    let wrong = work.appendingPathComponent("vieux.json")
    try Data(#"{"version":99,"entries":{"/x.pdf":{"size":1,"mtime":1,"pages":["pH"],"ocr":false}}}"#.utf8).write(to: wrong)
    check(ContentIndex(cacheURL: wrong).documentCount == 0, "version inconnue : index vide")
}

// 5. OCR Vision réel sur un scan fabriqué (fr-FR) — hors ligne
do {
    let idx = index("vision")
    idx.update(files: files().filter { $0.name == "Scan" })
    let e = idx.entry(for: root.appendingPathComponent("Maths/Scan.pdf"))
    let found = !idx.search("pythagore").isEmpty
    check(e?.ocr == true, "scan détecté")
    check(found, "OCR Vision réel : « Pythagore » retrouvé dans le scan fabriqué")
    check(idx.search("secrete").isEmpty, "la 5e page du scan n'est pas lue")
}

// 6. Cours récents
@MainActor func recentsTests() {
    let suite = "test.recents.\(getpid())"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    let r = Recents(defaults: d, key: "k")
    let urls = (1...9).map { work.appendingPathComponent("c\($0).pdf") }
    for u in urls { try? Data("x".utf8).write(to: u) }
    for u in urls { r.touch(u) }
    check(r.visible().count == 6, "6 cours récents au plus, trouvé \(r.visible().count)")
    check(r.visible().first?.lastPathComponent == "c9.pdf", "le plus récent d'abord")
    r.touch(urls[3])
    check(r.visible().first?.lastPathComponent == "c4.pdf" && r.visible().filter { $0.lastPathComponent == "c4.pdf" }.count == 1, "pas de doublon, remonté en tête")
    try? fm.removeItem(at: urls[8])
    check(!r.visible().contains { $0.lastPathComponent == "c9.pdf" }, "fichier disparu ignoré")
    check(r.visible().count == 6, "la liste reste à 6 malgré le fichier disparu")
    let again = Recents(defaults: d, key: "k")
    check(again.visible().first?.lastPathComponent == "c4.pdf", "persistance dans UserDefaults")
    again.clear()
    check(again.visible().isEmpty && Recents(defaults: d, key: "k").visible().isEmpty, "Effacer vide la liste (et la mémoire)")
    check(fm.fileExists(atPath: urls[0].path), "Effacer ne touche à aucun fichier")
    // une évaluation est listée comme les autres
    let ev = root.appendingPathComponent("Réseaux/Eval/Évaluation réseaux.pdf")
    again.touch(ev)
    check(again.visible().count == 1, "une évaluation peut être récente")
    d.removePersistentDomain(forName: suite)
}
MainActor.assumeIsolated { recentsTests() }

try? fm.removeItem(at: work)
if failures == 0 { print("Index : toutes les vérifications passent.") } else { print("Index : \(failures) échec(s)."); exit(1) }
