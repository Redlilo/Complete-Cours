import Foundation
import FoundationModels

// Banc d'essai du moteur Apple Intelligence.
// usage : bench [--cases chemin] [--split dev|test|all] [--types mot,definition] [--variants a,b] [--only id1,id2]
//               [--verbose] [--out resultats.json]
var casesPath = "/Users/maelehuidoux/Desktop/Projets/Complete-Cours/Tools/Tests/Apple/benchmark.json"
var variantNames: [String]? = nil
var only: Set<String>? = nil
var types: Set<String>? = nil
var split = "dev"
var verbose = false
var outPath: String? = nil
var argv = Array(CommandLine.arguments.dropFirst())
while !argv.isEmpty {
    let a = argv.removeFirst()
    switch a {
    case "--cases": casesPath = argv.removeFirst()
    case "--split": split = argv.removeFirst()
    case "--variants": variantNames = argv.removeFirst().split(separator: ",").map(String.init)
    case "--only": only = Set(argv.removeFirst().split(separator: ",").map(String.init))
    case "--types": types = Set(argv.removeFirst().split(separator: ",").map(String.init))
    case "--out": outPath = argv.removeFirst()
    case "--verbose": verbose = true
    default: print("option inconnue \(a)"); exit(1)
    }
}

if let why = AppleEngine.unavailabilityReason() { print("Apple Intelligence indisponible : \(why)"); exit(1) }
let cases = loadCases(casesPath).filter {
    (only == nil || only!.contains($0.id)) && (types == nil || types!.contains($0.type)) && (split == "all" || ($0.split ?? "dev") == split)
}
let variants = allVariants().filter { variantNames == nil || variantNames!.contains($0.name) }

struct Row: Codable { var id: String; var variant: String; var answer: String; var ok: Bool; var lenient: Bool; var fit: Bool; var seconds: Double; var error: String? }
var allRows: [Row] = []

for v in variants {
    var rows: [Row] = []
    for c in cases where v.types.contains(c.type) {
        let t0 = Date()
        var ans = ""
        var err: String? = nil
        do { ans = try await v.run(c) ?? "" } catch { err = String(describing: error).prefix(120).description }
        let dt = Date().timeIntervalSince(t0)
        var ok = false, len = false, fit = true
        if v.isGate {
            let shouldIgnore = c.type == "ignorer" || c.attenduKind == "ignorer"
            ok = (ans == ignoredAnswer) == shouldIgnore; len = ok
        } else {
        switch c.type {
        case "mot": let s = scoreMot(ans, c); ok = s.strict; len = s.lenient
        case "definition", "question":
            ok = scoreKeywords(ans, c); len = ok
            fit = ans.count <= (c.capacite ?? 200)
        case "ignorer": ok = ans == ignoredAnswer; len = ok
        case "champ":
            ok = c.attenduTexte != nil ? ans == c.attenduTexte! : (c.attenduKind == "ignorer" && ans == ignoredAnswer); len = ok
        default: break
        }
        }
        rows.append(Row(id: c.id, variant: v.name, answer: ans, ok: ok, lenient: len, fit: fit, seconds: dt, error: err))
        if verbose || !ok {
            let want = c.attendu?.joined(separator: " | ") ?? c.attenduTexte ?? c.attenduKind ?? "(mots-clés)"
            print(String(format: "  %@ %-10@ %.2fs  attendu=%@  réponse=« %@ »%@", ok ? "✓" : "✗", c.id, dt, want, ans, err.map { "  ERREUR \($0)" } ?? ""))
        }
    }
    let n = rows.count
    if n == 0 { continue }
    let ok = rows.filter { $0.ok }.count, len = rows.filter { $0.lenient }.count, fit = rows.filter { $0.fit }.count
    let avg = rows.map { $0.seconds }.reduce(0, +) / Double(n)
    print(String(format: "=== %@ [%@] : %d/%d exact (%.0f %%), %d/%d indulgent (%.0f %%), %d/%d dans la capacité, %.2f s par zone\n",
                 v.name, split, ok, n, 100 * Double(ok) / Double(n), len, n, 100 * Double(len) / Double(n), fit, n, avg))
    if v.isGate {
        let ignoredCases = cases.filter { $0.type == "ignorer" || $0.attenduKind == "ignorer" }.map { $0.id }
        let tp = rows.filter { ignoredCases.contains($0.id) && $0.answer == ignoredAnswer }.count
        let fp = rows.filter { !ignoredCases.contains($0.id) && $0.answer == ignoredAnswer }.count
        let others = rows.filter { !ignoredCases.contains($0.id) }.count
        print("    zones à ignorer retrouvées : \(tp)/\(ignoredCases.count) ; zones à remplir ignorées à tort : \(fp)/\(others)\n")
    }
    allRows += rows
}
if let p = outPath, let d = try? JSONEncoder().encode(allRows) { try? d.write(to: URL(fileURLWithPath: p)) }
