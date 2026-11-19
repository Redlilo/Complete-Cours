import Foundation
import PDFKit
import AppKit
import CoreText

// Tests de la recherche de doublons (Sources/Core/DuplicateFinder.swift) sur des PDF fabriqués.

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("ÉCHEC (ligne \(line)) : \(what)") }
}

let vocab = "atome noyau electron proton neutron ion cation anion charge masse tableau periodique element molecule liaison solution acide basique reaction equation mole concentration volume pression temperature energie circuit tension intensite resistance puissance loi ohm courant alternatif continu disjoncteur differentiel terre protection schema cablage reseau adresse masque passerelle routeur commutateur".split(separator: " ").map(String.init)
func words(seed: Int, count: Int = 150) -> [String] {
    var out: [String] = []; var x = seed &* 7919 &+ 13
    for _ in 0..<count { x = (x &* 1103515245 &+ 12345) & 0x7fffffff; out.append(vocab[x % vocab.count] + String(x % 7)) }
    return out
}
func makePDF(_ url: URL, _ w: [String]) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    ctx.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
    for (i, start) in stride(from: 0, to: w.count, by: 10).enumerated() {
        let line = w[start..<min(start + 10, w.count)].joined(separator: " ")
        ctx.textPosition = CGPoint(x: 40, y: 800 - CGFloat(i) * 14)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font])), ctx)
    }
    ctx.endPDFPage(); ctx.closePDF()
}

let args = CommandLine.arguments
if args.count >= 3, args[1] == "scan" {
    // lecture seule : affiche les groupes trouvés dans un vrai dossier de cours (évaluations ignorées)
    let real = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
    let found = DuplicateFinder.find(files: LibraryTree.scan(real), root: real)
    print("\(found.count) groupe(s)")
    for g in found {
        print("- \(g.kind) ; garder : \(g.keep.lastPathComponent)")
        for c in g.files { print("    \(c.relativePath)  (\(c.size) o, \(c.pages) p.)") }
    }
    exit(0)
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("doublons-\(getpid())")
try? FileManager.default.removeItem(at: root)
let T1 = words(seed: 1), T2 = words(seed: 2), T3 = words(seed: 3), T4 = words(seed: 4)
makePDF(root.appendingPathComponent("Physique/Cours/Atome.pdf"), T1)
try? FileManager.default.copyItem(at: root.appendingPathComponent("Physique/Cours/Atome.pdf"), to: root.appendingPathComponent("Physique/Cours/Atome (2).pdf"))
makePDF(root.appendingPathComponent("Maths/Cours/Stats.pdf"), T2)
var T2b = T2; T2b[75] = "motmodifie"
makePDF(root.appendingPathComponent("Maths/Cours/Stats refait.pdf"), T2b)
makePDF(root.appendingPathComponent("Maths/Cours/Probas.pdf"), T3)
makePDF(root.appendingPathComponent("Maths/Cours/Probas (complétée).pdf"), T3 + ["reponse"])
makePDF(root.appendingPathComponent("Maths/Cours/Autre.pdf"), T4)
makePDF(root.appendingPathComponent("Maths/Cours/Calcul.pdf"), words(seed: 5))
try? FileManager.default.createDirectory(at: root.appendingPathComponent("_Originaux avant completion/Maths/Cours"), withIntermediateDirectories: true)
try? FileManager.default.copyItem(at: root.appendingPathComponent("Maths/Cours/Calcul.pdf"), to: root.appendingPathComponent("_Originaux avant completion/Maths/Cours/Calcul.pdf"))
makePDF(root.appendingPathComponent("Maths/Contrôle 1.pdf"), words(seed: 6))
try? FileManager.default.copyItem(at: root.appendingPathComponent("Maths/Contrôle 1.pdf"), to: root.appendingPathComponent("Maths/Contrôle 1 copie.pdf"))

let files = LibraryTree.scan(root)
check(files.count == 11, "11 PDF lus (\(files.count))")
var lastProgress = 0.0
let groups = DuplicateFinder.find(files: files, root: root, progress: { f, _ in lastProgress = f })
check(lastProgress == 1, "la progression va jusqu'à 1")
func names(_ g: DuplicateGroup) -> Set<String> { Set(g.files.map { $0.url.lastPathComponent }) }

let identical = groups.filter { $0.kind == .identiques }
check(identical.count == 2, "2 groupes d'identiques : \(identical.map(names))")
if let g = identical.first(where: { names($0).contains("Atome.pdf") }) {
    check(names(g) == ["Atome.pdf", "Atome (2).pdf"], "Atome et sa copie : \(names(g))")
    check(g.keep.lastPathComponent == "Atome.pdf", "on garde celui sans « (2) » : \(g.keep.lastPathComponent)")
} else { check(false, "groupe Atome trouvé") }
if let g = identical.first(where: { names($0).contains("Calcul.pdf") }) {
    check(g.files.count == 2 && g.files.contains(where: { $0.inArchive }), "le dossier des originaux est comparé aussi")
    check(!g.keep.path.contains("_Originaux"), "on garde celui qui n'est pas dans le dossier des originaux : \(g.keep.path)")
} else { check(false, "groupe Calcul trouvé") }

let similar = groups.filter { if case .tresSemblables = $0.kind { return true }; return false }
check(similar.count == 1 && names(similar[0]) == ["Stats.pdf", "Stats refait.pdf"], "un groupe de très semblables : \(similar.map(names))")
if let s = similar.first, case .tresSemblables(let p) = s.kind { check(p >= 90, "similitude ≥ 90 % (\(p))") }

let all = groups.flatMap { $0.files.map { $0.url.lastPathComponent } }
check(!all.contains("Probas.pdf") && !all.contains("Probas (complétée).pdf"), "une version vide et sa version complétée ne sont pas des doublons")
check(!all.contains("Autre.pdf"), "un document différent n'est pas un doublon")
check(!all.contains("Contrôle 1.pdf") && !all.contains("Contrôle 1 copie.pdf"), "les évaluations ne sont jamais comparées")

// Corbeille : refuse si le fichier a changé ; refuse si le fichier gardé a disparu ; réussit sinon (puis nettoie la Corbeille de test)
if let g = identical.first(where: { names($0).contains("Atome.pdf") }) {
    let copy = g.files.first { $0.url.lastPathComponent == "Atome (2).pdf" }!
    var gk = g; gk.keep = g.files.first { $0.url.lastPathComponent == "Atome.pdf" }!.url
    try? Data("changé".utf8).write(to: copy.url)
    let r1 = DuplicateFinder.trash(gk, removing: [copy.url])
    check(r1.trashed.isEmpty && r1.refused.count == 1, "un fichier modifié depuis l'analyse est laissé en place")
    var gMissing = gk; gMissing.keep = root.appendingPathComponent("absent.pdf")
    let r2 = DuplicateFinder.trash(gMissing, removing: [copy.url])
    check(r2.trashed.isEmpty && FileManager.default.fileExists(atPath: copy.url.path), "si le fichier gardé n'existe plus, rien n'est retiré")
}
if let g = identical.first(where: { names($0).contains("Calcul.pdf") }) {
    let victim = g.files.first { $0.inArchive }!
    var gk = g; gk.keep = g.files.first { !$0.inArchive }!.url
    let r = DuplicateFinder.trash(gk, removing: [victim.url, gk.keep])
    check(r.trashed == [victim.url] && !FileManager.default.fileExists(atPath: victim.url.path), "mise à la Corbeille réussie")
    check(FileManager.default.fileExists(atPath: gk.keep.path), "le fichier gardé n'est jamais retiré, même s'il est demandé")
    // ménage : on retire de la Corbeille le fichier de test (il porte un nom unique du dossier temporaire ci-dessus)
    let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/Calcul.pdf")
    if let a = try? FileManager.default.attributesOfItem(atPath: bin.path), (a[.size] as? NSNumber)?.int64Value == victim.size { try? FileManager.default.removeItem(at: bin) }
}
check(DuplicateFinder.sha256(root.appendingPathComponent("Maths/Cours/Stats.pdf")) != nil, "empreinte calculable")
check(DuplicateFinder.jaccard([1, 2, 3], [2, 3, 4]) == 0.5, "jaccard")
try? FileManager.default.removeItem(at: root)
if failures == 0 { print("Duplicates : tout est bon.") } else { print("Duplicates : \(failures) échec(s)."); exit(1) }
