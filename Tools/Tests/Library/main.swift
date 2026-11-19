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

// Originaux vides : paires détectées par le nom, destination en miroir, jamais d'écrasement
check(OriginalsArchive.completedBase("SEANCE 4 (complétée)") == "seance 4", "(complétée)")
check(OriginalsArchive.completedBase("SEANCE 4 (complétée 2)") == "seance 4", "(complétée 2)")
check(OriginalsArchive.completedBase("Scan2026-11-16_115411_complete") == "scan2026-11-16 115411", "_complete")
check(OriginalsArchive.completedBase("3 - TP LAN (Packet Tracer) - rempli") == "3 - tp lan (packet tracer)", "- rempli")
check(OriginalsArchive.completedBase("Séance 1 - Origine") == nil, "un cours vierge n'est pas une version complétée")
let arch = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(getpid())")
func touch(_ rel: String) { let u = arch.appendingPathComponent(rel); try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); FileManager.default.createFile(atPath: u.path, contents: Data(rel.utf8)) }
touch("Histoire/Thème 1/SEANCE 4.pdf"); touch("Histoire/Thème 1/SEANCE 4 (complétée).pdf"); touch("Histoire/Thème 1/Séance 1.pdf")
touch("Maths/Contrôle 1.pdf"); touch("Maths/Contrôle 1 corrigé.pdf")
let archFiles = LibraryTree.scan(arch)
let archLedger = CourseLedger(directory: arch.appendingPathComponent(".journal"))
let archPlans = OriginalsArchive.plan(files: archFiles, root: arch)
check(archPlans.count == 1 && archPlans[0].original.lastPathComponent == "SEANCE 4.pdf", "une seule paire (la évaluation est ignorée) : \(archPlans.map { $0.original.lastPathComponent })")
if let p = archPlans.first {
    check(p.destination.path.hasSuffix("_Originaux avant completion/Histoire/Thème 1/SEANCE 4.pdf"), "destination en miroir : \(p.destination.path)")
    touch("_Originaux avant completion/Histoire/Thème 1/SEANCE 4.pdf")
    if let rec = try? OriginalsArchive.archive(p, ledger: archLedger) {
        check(rec.toURL.lastPathComponent == "SEANCE 4 (2).pdf", "jamais d'écrasement : \(rec.toURL.lastPathComponent)")
        check(!FileManager.default.fileExists(atPath: p.original.path) && FileManager.default.fileExists(atPath: p.completed.path), "l'original part, la version complétée reste")
        if case .restored = archLedger.undo(rec.id) { check(FileManager.default.fileExists(atPath: p.original.path), "annulation : l'original revient") } else { check(false, "annulation possible") }
    } else { check(false, "le rangement fonctionne") }
    try? FileManager.default.removeItem(at: p.completed)
    check((try? OriginalsArchive.archive(p, ledger: archLedger)) == nil, "refuse si la version complétée a disparu")
}
try? FileManager.default.removeItem(at: arch)

// Évaluations : « _ », en-tête, déplacement protégé, nom nettoyé, filtre de vie privée
for n in ["Maths_Controle_2", "Chap3_eval", "maths_ds3", "Seq2_Examen", "Devoir surveillé 2", "Seance_Eval", "Interrogation 3", "Bac blanc"] {
    check(LibraryTree.looksLikeEvaluation(n), "évaluation reconnue : \(n)")
}
for n in ["Séance 1 - Origine", "Le pH", "Dossiers", "Statistiques à une variable"] {
    check(!LibraryTree.looksLikeEvaluation(n), "cours non pris pour une évaluation : \(n)")
}
check(LibraryTree.headerLooksLikeEvaluation("Lycée Saint-Nicolas — Contrôle n°2 de mathématiques NOM :"), "en-tête « Contrôle »")
check(LibraryTree.headerLooksLikeEvaluation("Interrogation écrite – 30 min"), "en-tête « Interrogation »")
check(!LibraryTree.headerLooksLikeEvaluation("Séquence 1 : Chimie. Comprendre les éléments chimiques"), "en-tête d'un cours")
check(LibraryTree.isEvaluationPath(["Maths", "Évaluations", "DS 1.pdf"]), "chemin dans Évaluations")
check(CourseAnalysis.cleanName("  Séance 4 : Le Horla/fin.pdf ") == "Séance 4 Le Horla fin", "nom nettoyé : \(CourseAnalysis.cleanName("  Séance 4 : Le Horla/fin.pdf "))")
let evRoot = FileManager.default.temporaryDirectory.appendingPathComponent("eval-\(getpid())")
try? FileManager.default.createDirectory(at: evRoot.appendingPathComponent("Maths/Évaluations"), withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: evRoot.appendingPathComponent("Maths/Cours"), withIntermediateDirectories: true)
FileManager.default.createFile(atPath: evRoot.appendingPathComponent("Maths/Évaluations/DS 1.pdf").path, contents: Data("x".utf8))
FileManager.default.createFile(atPath: evRoot.appendingPathComponent("Maths/Cours/Stats.pdf").path, contents: Data("y".utf8))
let evMove = AnalysisSuggestion(path: "Maths/Évaluations/DS 1.pdf", folder: "Maths/Cours", newName: "", reason: "")
check((try? CourseAnalysis.move(evMove, root: evRoot)) == nil && FileManager.default.fileExists(atPath: evRoot.appendingPathComponent("Maths/Évaluations/DS 1.pdf").path), "une évaluation ne sort pas de « Évaluations »")
let evRename = AnalysisSuggestion(path: "Maths/Évaluations/DS 1.pdf", folder: "Maths/Évaluations", newName: "Autre nom", reason: "")
check((try? CourseAnalysis.move(evRename, root: evRoot)) == nil, "une évaluation n'est pas renommée")
let same = AnalysisSuggestion(path: "Maths/Cours/Stats.pdf", folder: "Maths/Cours", newName: "Stats", reason: "")
check((try? CourseAnalysis.move(same, root: evRoot))?.lastPathComponent == "Stats.pdf", "renommer vers le même nom ne crée pas « (2) »")
check((try? CourseAnalysis.move(same, root: evRoot.appendingPathComponent("absent"))) == nil, "racine introuvable : rien n'est déplacé")
let parsedEval = CourseAnalysis.parse(["propositions": [["chemin": "Maths/Évaluations/DS 1.pdf", "dossier": "Maths/Cours", "nouveauNom": "", "raison": "x"]]], knownPaths: ["Maths/Évaluations/DS 1.pdf"], folders: ["Maths", "Maths/Cours", "Maths/Évaluations"], evaluationPaths: ["Maths/Évaluations/DS 1.pdf"])
check(parsedEval.isEmpty, "l'IA ne peut pas sortir une évaluation de son dossier")
try? FileManager.default.removeItem(at: evRoot)
for personal in [("Facture EDF", ""), ("scan", "IBAN FR76 3000 6000 0112 3456 7890 189"), ("lettre", "écrire à marie.dupont@example.com"), ("doc", "tél 06 12 34 56 78"), ("Passeport", "")] {
    check(PrivacyGate.looksPersonal(name: personal.0, excerpt: personal.1), "pièce personnelle détectée : \(personal.0) \(personal.1)")
}
check(!PrivacyGate.looksPersonal(name: "Le pH", excerpt: "Séquence 1 : Chimie. Qu'est-ce que le pH ?"), "un cours n'est pas une pièce personnelle")

if failures == 0 { print("Library : tout est bon.") } else { print("Library : \(failures) échec(s)."); exit(1) }
