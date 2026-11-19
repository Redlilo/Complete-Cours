import Foundation

// Tests de la bibliothèque (Sources/Core/LibraryTree.swift) : ordre, évaluations, états, recherche, dépliage.
//   build/tests/Library-tests                    lance les vérifications
//   build/tests/Library-tests tree <dossier>     affiche l'arbre d'un vrai dossier de cours, déplié (noms seulement)

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("ÉCHEC (ligne \(line)) : \(what)") }
}

func summary(_ rows: [LibraryRow]) -> [String] {
    rows.map { row in
        let pad = String(repeating: "  ", count: row.depth)
        switch row.content {
        case .folder(let f, let open): return pad + (open ? "▾ " : "▸ ") + f.displayName + " (\(f.count))"
        case .file(let f):
            var tags = ""
            if f.isEvaluation { tags += " [éval]" }
            if let l = f.state.label { tags += " [\(l)]" }
            return pad + "· " + f.name + tags
        }
    }
}

let args = CommandLine.arguments
if args.count >= 3, args[1] == "tree" {
    let root = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
    let tree = LibraryTree.build(LibraryTree.scan(root))
    let all = Set(LibraryTree.folderIDs(tree))
    print(summary(LibraryTree.rows(root: tree, expanded: all, query: "")).joined(separator: "\n"))
    exit(0)
}

let root = URL(fileURLWithPath: "/Cours")
let paths = [
    "Maths/Cours/Séquence 1.pdf", "Maths/Cours/Séquence 10.pdf", "Maths/Cours/Séquence 2.pdf",
    "Maths/Évaluations/Contrôle 1.pdf", "Maths/Fiche.pdf",
    "_Originaux avant completion/Atelier/Seance 1.pdf",
    "Atelier/Chantier 2/a.pdf", "Atelier/Chantier 10/b.pdf", "Atelier/chantier 3/c.pdf",
    "Atelier/Chantier 5/Seance_1_corrige.pdf",
    "PSE/EVAL PSE.pdf",
    "Histoire/Thème 1/SEANCE 4 (complétée).pdf", "Histoire/Thème 1/SEANCE 4.pdf",
]
let files = paths.compactMap { LibraryTree.makeFile(root: root, url: root.appendingPathComponent($0)) }
check(files.count == paths.count, "tous les chemins sont lus")
check(LibraryTree.makeFile(root: root, url: URL(fileURLWithPath: "/Ailleurs/x.pdf")) == nil, "un fichier hors racine est refusé")

let tree = LibraryTree.build(files)
check(tree.folders.map(\.displayName) == ["Atelier", "Histoire", "Maths", "PSE", "Originaux avant completion"],
      "matières dans l'ordre, dossier « _ » en dernier : \(tree.folders.map(\.displayName))")
check(tree.folders.last?.isArchive == true, "le dossier « _ » est une archive")
let atelier = tree.folders[0]
check(atelier.folders.map(\.name) == ["Chantier 2", "chantier 3", "Chantier 5", "Chantier 10"],
      "ordre naturel des chantiers : \(atelier.folders.map(\.name))")
let maths = tree.folders[2]
check(maths.count == 5, "Maths contient 5 PDF (\(maths.count))")
check(maths.folders[0].files.map(\.name) == ["Séquence 1", "Séquence 2", "Séquence 10"], "ordre naturel des séquences")

// Évaluations et états
func file(_ rel: String) -> LibraryFile { files.first { $0.relativePath == rel }! }
check(file("Maths/Évaluations/Contrôle 1.pdf").isEvaluation, "dossier Évaluations")
check(file("PSE/EVAL PSE.pdf").isEvaluation, "nom EVAL")
check(!file("Maths/Fiche.pdf").isEvaluation, "un cours n'est pas une évaluation")
check(LibraryTree.looksLikeEvaluation("evalphisyque"), "evalphisyque")
check(!LibraryTree.looksLikeEvaluation("Dossiers"), "pas de faux positif « ds »")
check(file("Histoire/Thème 1/SEANCE 4 (complétée).pdf").state == .rempli, "(complétée) = déjà rempli")
check(file("Histoire/Thème 1/SEANCE 4.pdf").state == .vierge, "sans suffixe = vierge")
check(file("Atelier/Chantier 5/Seance_1_corrige.pdf").state == .corrige, "corrigé")

// Lignes : tout replié, puis déplié
let collapsed = summary(LibraryTree.rows(root: tree, expanded: [], query: ""))
check(collapsed == ["▸ Atelier (4)", "▸ Histoire (2)", "▸ Maths (5)", "▸ PSE (1)", "▸ Originaux avant completion (1)"],
      "tout replié : \(collapsed)")
let mathsOpen = summary(LibraryTree.rows(root: tree, expanded: ["Maths"], query: ""))
check(mathsOpen.contains("  ▸ Cours (3)") && mathsOpen.contains("  ▸ Évaluations (1)") && mathsOpen.contains("  · Fiche"),
      "Maths déplié : sous-dossiers puis fichiers : \(mathsOpen)")
check(!mathsOpen.contains { $0.contains("Séquence") }, "les sous-dossiers repliés cachent leurs fichiers")
let mathsIdx = mathsOpen.firstIndex(of: "  ▸ Évaluations (1)")!, ficheIdx = mathsOpen.firstIndex(of: "  · Fiche")!
check(mathsIdx < ficheIdx, "dossiers avant fichiers")

// Recherche : ancêtres conservés, tout déplié, insensible aux accents et à la casse
let s10 = summary(LibraryTree.rows(root: tree, expanded: [], query: "10"))
check(s10 == ["▾ Atelier (1)", "  ▾ Chantier 10 (1)", "    · b", "▾ Maths (1)", "  ▾ Cours (1)", "    · Séquence 10"], "recherche « 10 » : \(s10)")
let sEval = summary(LibraryTree.rows(root: tree, expanded: [], query: "evaluations"))
check(sEval.contains("  ▾ Évaluations (1)") && sEval.contains("    · Contrôle 1 [éval]"), "recherche d'un dossier : \(sEval)")
check(LibraryTree.rows(root: tree, expanded: [], query: "zzz").isEmpty, "aucun résultat")

// Analyse : lecture de la réponse de l'IA et déplacement sans écrasement
let folders = ["Maths", "Maths/Cours", "Maths/Évaluations", "Atelier", "Atelier/Cours/Réseaux"]
let answer: [String: Any] = ["propositions": [
    ["chemin": "Atelier/Chantier 2/a.pdf", "dossier": "Atelier/Cours/Réseaux", "nouveauNom": "TP LAN", "raison": "réseau"],
    ["chemin": "inconnu.pdf", "dossier": "Maths/Cours", "nouveauNom": "", "raison": "x"],
    ["chemin": "Maths/Fiche.pdf", "dossier": "Nouvelle matière/Cours", "nouveauNom": "", "raison": "x"],
    ["chemin": "Maths/Fiche.pdf", "dossier": "Maths", "nouveauNom": "", "raison": "déjà bien rangé"],
]]
let parsed = CourseAnalysis.parse(answer, knownPaths: Set(paths), folders: folders)
check(parsed.count == 1 && parsed[0].folder == "Atelier/Cours/Réseaux", "seule la proposition valide est gardée : \(parsed)")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-\(getpid())")
try? FileManager.default.createDirectory(at: tmp.appendingPathComponent("Atelier"), withIntermediateDirectories: true)
FileManager.default.createFile(atPath: tmp.appendingPathComponent("Atelier/a.pdf").path, contents: Data("x".utf8))
FileManager.default.createFile(atPath: tmp.appendingPathComponent("Atelier/b.pdf").path, contents: Data("y".utf8))
if let first = try? CourseAnalysis.move(AnalysisSuggestion(path: "Atelier/a.pdf", folder: "Atelier/Cours/Réseaux", newName: "TP", reason: ""), root: tmp),
   let second = try? CourseAnalysis.move(AnalysisSuggestion(path: "Atelier/b.pdf", folder: "Atelier/Cours/Réseaux", newName: "TP", reason: ""), root: tmp) {
    check(first.lastPathComponent == "TP.pdf" && second.lastPathComponent == "TP (2).pdf", "jamais d'écrasement : \(first.lastPathComponent), \(second.lastPathComponent)")
} else { check(false, "le déplacement fonctionne") }
try? FileManager.default.removeItem(at: tmp)

if failures == 0 { print("Library : tout est bon.") } else { print("Library : \(failures) échec(s)."); exit(1) }
