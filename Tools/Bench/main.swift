import Foundation
import PDFKit

// Banc d'essai de la détection des zones. LECTURE SEULE : ouvre l'original vide et sa version complétée, ne
// modifie ni ne déplace rien, n'ouvre jamais une évaluation. Voir Tools/Bench/run.sh.

// MARK: Options

var folder = ("~/Desktop/Cours" as NSString).expandingTildeInPath
var asJSON = false, top = 15, only = "", doubtful = 0.6
do {
    var args = Array(CommandLine.arguments.dropFirst()), positional: [String] = []
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--json": asJSON = true
        case "--compare": args.removeAll()
        case "--top": top = Int(args.isEmpty ? "" : args.removeFirst()) ?? top
        case "--seul": only = args.isEmpty ? "" : args.removeFirst()
        case "--douteux": doubtful = Double(args.isEmpty ? "" : args.removeFirst()) ?? doubtful
        case "--aide", "-h", "--help":
            print("Banc d'essai : Tools/Bench/run.sh [dossier] [--json] [--top N] [--seul texte] [--douteux X]"); exit(0)
        default:
            if a.hasPrefix("--") { FileHandle.standardError.write(Data("Option inconnue : \(a)\n".utf8)); exit(2) }
            positional.append(a)
        }
    }
    if let p = positional.first { folder = (p as NSString).expandingTildeInPath }
}
let root = URL(fileURLWithPath: folder)
func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// Diagnostic d'une paire : Tools/Bench/run.sh --compare <original vide> <complétée> [dossier de PNG]
if let i = CommandLine.arguments.firstIndex(of: "--compare"), CommandLine.arguments.count > i + 2 {
    let a = CommandLine.arguments, bURL = URL(fileURLWithPath: a[i + 1]), cURL = URL(fileURLWithPath: a[i + 2])
    guard let b = PDFDocument(url: bURL), let c = PDFDocument(url: cURL) else { print("illisible"); exit(1) }
    for k in 0..<b.pageCount {
        guard k < c.pageCount, let bp = b.page(at: k), let cp = c.page(at: k) else { print("p.\(k + 1) absente"); continue }
        if let m = PageDiff.addedInk(blank: bp, completed: cp) {
            print("p.\(k + 1) : \(m.width)x\(m.height) décalage \(m.shift) encre ajoutée \(m.addedTotal) px")
            if a.count > i + 3 {
                var px = m.added.map { $0 != 0 ? UInt8(0) : UInt8(255) }
                let img: CGImage? = px.withUnsafeMutableBytes { buf in
                    CGContext(data: buf.baseAddress, width: m.width, height: m.height, bitsPerComponent: 8, bytesPerRow: m.width,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
                }
                if let img, let d = PageImaging.pngData(img) { try? d.write(to: URL(fileURLWithPath: a[i + 3]).appendingPathComponent("diff-\(k + 1).png")) }
            }
        } else { print("p.\(k + 1) : non comparable (format ou contenu trop différent)") }
    }
    exit(0)
}

// MARK: Paires original vide ↔ version complétée

struct Pair { let original: URL; let completed: URL; let name: String }

func findPairs(root: URL) -> [Pair] {
    let fm = FileManager.default
    var pairs: [Pair] = []
    var seen = Set<String>()
    func add(_ o: URL, _ c: URL, _ name: String) {
        guard o.standardizedFileURL != c.standardizedFileURL, seen.insert(o.standardizedFileURL.path).inserted else { return }
        pairs.append(Pair(original: o, completed: c, name: name))
    }
    // 1. originaux rangés dans « _Originaux avant completion » : version complétée dans le dossier miroir (ou à côté)
    let archive = root.appendingPathComponent(OriginalsArchive.folderName)
    for f in LibraryTree.scan(archive) {
        let rel = f.folders + [f.url.lastPathComponent]
        if LibraryTree.isEvaluationPath(rel) || f.isEvaluation || f.state != .vierge { continue }
        let base = OriginalsArchive.normalized(f.name)
        let mirror = f.folders.reduce(root) { $0.appendingPathComponent($1) }
        for dir in [mirror, f.url.deletingLastPathComponent()] {
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let hit = names.sorted().first { n in
                n.lowercased().hasSuffix(".pdf") && !LibraryTree.looksLikeEvaluation((n as NSString).deletingPathExtension)
                    && OriginalsArchive.completedBase((n as NSString).deletingPathExtension) == base
            }
            if let hit { add(f.url, dir.appendingPathComponent(hit), rel.joined(separator: "/")); break }
        }
    }
    // 2. paires encore côte à côte dans le dossier des cours (même logique que « Ranger les originaux vides »)
    for p in OriginalsArchive.plan(files: LibraryTree.scan(root), root: root) {
        let o = p.original.path.replacingOccurrences(of: root.path + "/", with: "")
        if LibraryTree.isEvaluationPath(o.components(separatedBy: "/")) { continue }
        add(p.original, p.completed, o)
    }
    return pairs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

// MARK: Mesures par zone

struct ZoneRow {
    let doc: String, page: Int, number: Int, source: String, kind: String
    let confidence: Double, signals: [String]
    let meaningful: Bool, comparable: Bool, filled: Bool
    let estimatedAnswered: Bool       // l'estimation actuelle (sans original) sur la version complétée
    let added: Int, w: Int, h: Int
    var isDoubtful: Bool { confidence < doubtful }
}

struct DocResult {
    let name: String
    var rows: [ZoneRow] = []
    var blobs: [InkBlob] = []
    var pages = 0, compared = 0, skipped = 0, rotated = 0, addedTotal = 0
    /// Paire exploitable : de l'encre a bien été ajoutée (sinon l'« original » était déjà rempli ou identique).
    var usable: Bool { error == nil && addedTotal >= 300 }
    var stateWithout = "", stateWith = ""
    var seconds = 0.0
    var error: String?
}

func measure(_ pair: Pair) -> DocResult {
    var res = DocResult(name: pair.name)
    let t0 = Date()
    defer { res.seconds = Date().timeIntervalSince(t0) }
    guard let blank = PDFDocument(url: pair.original), let done = PDFDocument(url: pair.completed) else { res.error = "illisible"; return res }
    guard let analyses = try? CoursPipeline.analyzeChecked(url: pair.original, needText: false, progress: { _, _ in }) else { res.error = "analyse impossible"; return res }
    res.pages = blank.pageCount
    res.rotated = analyses.filter { $0.rotationUnsupported }.count
    let zones = analyses.flatMap { $0.zones }
    let diff = PageDiff.compare(blank: blank, completed: done, zones: zones)
    res.blobs = diff.blobs
    res.addedTotal = diff.addedTotal
    res.compared = diff.pagesCompared; res.skipped = diff.pagesSkipped.count
    for a in analyses where !a.zones.isEmpty {
        guard let bp = blank.page(at: a.pageIndex) else { continue }
        let dp = done.page(at: a.pageIndex)
        let notes = dp.map(CompletionStatus.textAnnotationRects) ?? []
        let ink = dp.flatMap(CompletionStatus.inkProbe)
        for z in a.zones {
            let d = diff.zones[z.id]
            let r = z.rect
            res.rows.append(ZoneRow(doc: pair.name, page: a.pageIndex + 1, number: z.number, source: z.source.rawValue, kind: z.kind.rawValue,
                                    confidence: z.confidence, signals: z.signals,
                                    meaningful: CompletionStatus.isMeaningful(z, page: bp),
                                    comparable: d?.comparable ?? false, filled: d?.filled ?? false,
                                    estimatedAnswered: dp != nil && CompletionStatus.isAnswered(z, notes: notes, ink: ink),
                                    added: d?.addedPixels ?? 0, w: Int(r.width), h: Int(r.height)))
        }
    }
    res.stateWith = CompletionStatus.report(url: pair.completed, analyses: analyses, blankOriginal: pair.original).state.rawValue
    res.stateWithout = CompletionStatus.report(url: pair.completed)?.state.rawValue ?? "?"
    return res
}

// MARK: Statistiques

struct Stats {
    var zones = 0, kept = 0, true_ = 0, doubt = 0, doubtTrue = 0, blobs = 0, blobPixels = 0
    var estTP = 0, estFP = 0, estFN = 0, estTN = 0       // estimateur actuel contre vérité, sur les zones retenues
    var precision: Double { kept > 0 ? Double(true_) / Double(kept) : .nan }
    var recall: Double { true_ + blobs > 0 ? Double(true_) / Double(true_ + blobs) : .nan }
    var estAccuracy: Double { kept > 0 ? Double(estTP + estTN) / Double(kept) : .nan }
}
func stats(_ rows: [ZoneRow], blobs: Int, blobPixels: Int) -> Stats {
    var s = Stats()
    s.blobs = blobs; s.blobPixels = blobPixels
    for r in rows where r.comparable {
        s.zones += 1
        guard r.meaningful else { continue }
        s.kept += 1
        if r.filled { s.true_ += 1 }
        if r.isDoubtful { s.doubt += 1; if r.filled { s.doubtTrue += 1 } }
        switch (r.estimatedAnswered, r.filled) {
        case (true, true): s.estTP += 1
        case (true, false): s.estFP += 1
        case (false, true): s.estFN += 1
        case (false, false): s.estTN += 1
        }
    }
    return s
}
func pct(_ x: Double) -> String { x.isNaN ? "  n/a" : String(format: "%4.0f %%", x * 100) }

// MARK: Exécution

let pairs = findPairs(root: root).filter { only.isEmpty || $0.name.localizedCaseInsensitiveContains(only) }
log("Banc : \(pairs.count) paire(s) original vide / complétée dans \(root.path)")
var results: [DocResult] = []
for (i, p) in pairs.enumerated() {
    log("[\(i + 1)/\(pairs.count)] \(p.name)")
    results.append(autoreleasepool { measure(p) })
}

let unusable = results.filter { !$0.usable }
results = results.filter { $0.usable }
let allRows = results.flatMap { $0.rows }
let total = stats(allRows, blobs: results.reduce(0) { $0 + $1.blobs.count }, blobPixels: results.reduce(0) { $0 + $1.blobs.reduce(0) { $0 + $1.pixels } })

// pires erreurs
let falsePositives = allRows.filter { $0.comparable && $0.meaningful && !$0.filled }
    .sorted { ($0.confidence, -$0.w) > ($1.confidence, -$1.w) }                    // les plus « sûres » d'abord
let estWrong = allRows.filter { $0.comparable && $0.meaningful && $0.estimatedAnswered != $0.filled }
    .sorted { $0.added > $1.added }
let filteredAway = allRows.filter { $0.comparable && !$0.meaningful && $0.filled }   // vrais trous écartés à tort
let worstBlobs = results.flatMap { r in r.blobs.map { (r.name, $0) } }.sorted { $0.1.pixels > $1.1.pixels }
func describe(_ r: ZoneRow) -> String {
    "\(r.doc) · p.\(r.page) zone \(r.number) · \(r.source)/\(r.kind) · confiance \(String(format: "%.2f", r.confidence)) · \(r.w)×\(r.h) pt · +\(r.added) px · [\(r.signals.joined(separator: ", "))]"
}
func describe(_ b: (String, InkBlob)) -> String {
    "\(b.0) · p.\(b.1.page + 1) · \(Int(b.1.rect.width))×\(Int(b.1.rect.height)) pt en (\(Int(b.1.rect.minX)), \(Int(b.1.rect.minY))) · \(b.1.pixels) px"
}

if asJSON {
    func j(_ s: Stats) -> [String: Any] {
        ["zonesDetectees": s.zones, "zonesRetenues": s.kept, "zonesVraies": s.true_,
         "precision": s.precision.isNaN ? NSNull() : s.precision, "rappelEstime": s.recall.isNaN ? NSNull() : s.recall,
         "zonesDouteuses": s.doubt, "douteusesVraies": s.doubtTrue, "encreHorsZone": s.blobs, "pixelsHorsZone": s.blobPixels,
         "estimation": ["vraiPositif": s.estTP, "fauxPositif": s.estFP, "fauxNegatif": s.estFN, "vraiNegatif": s.estTN]]
    }
    func jr(_ r: ZoneRow) -> [String: Any] {
        ["document": r.doc, "page": r.page, "zone": r.number, "source": r.source, "type": r.kind, "confiance": r.confidence,
         "signaux": r.signals, "largeurPt": r.w, "hauteurPt": r.h, "pixelsAjoutes": r.added, "retenue": r.meaningful,
         "remplie": r.filled, "estimeeRepondue": r.estimatedAnswered]
    }
    var bySource: [String: Any] = [:]
    for src in Set(allRows.map { $0.source }).sorted() { bySource[src] = j(stats(allRows.filter { $0.source == src }, blobs: 0, blobPixels: 0)) }
    let out: [String: Any] = [
        "dossier": root.path, "paires": pairs.count, "pairesEcartees": unusable.map { $0.name }, "seuilDouteux": doubtful, "total": j(total), "parSource": bySource,
        "documents": results.map { r -> [String: Any] in
            var d = j(stats(r.rows, blobs: r.blobs.count, blobPixels: r.blobs.reduce(0) { $0 + $1.pixels }))
            d["nom"] = r.name; d["pages"] = r.pages; d["pagesComparees"] = r.compared; d["pagesTournees"] = r.rotated
            d["etatSansOriginal"] = r.stateWithout; d["etatAvecOriginal"] = r.stateWith
            if let e = r.error { d["erreur"] = e }
            return d },
        "fauxTrous": falsePositives.prefix(top).map(jr),
        "vraisTrousEcartes": filteredAway.prefix(top).map(jr),
        "estimationErronee": estWrong.prefix(top).map(jr),
        "trousManques": worstBlobs.prefix(top).map { ["document": $0.0, "page": $0.1.page + 1, "pixels": $0.1.pixels,
                                                      "x": Int($0.1.rect.minX), "y": Int($0.1.rect.minY),
                                                      "largeurPt": Int($0.1.rect.width), "hauteurPt": Int($0.1.rect.height)] }
    ]
    if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]), let s = String(data: data, encoding: .utf8) { print(s) }
    exit(0)
}

print("")
print("BANC D'ESSAI — \(results.count) cours exploitables sur \(pairs.count) paires, zones détectées sur l'original vide, vérité = encre ajoutée dans la version complétée")
print(String(repeating: "─", count: 110))
for u in unusable { print("Paire écartée (\(u.error ?? "aucune encre ajoutée : l'original est déjà rempli ou identique à la version complétée")) : \(u.name)") }
print("précision = zones retenues qui sont vraies ; rappel estimé = vraies / (vraies + amas d'encre hors zone) ; douteuse = confiance < \(doubtful)")
print("")
print(String(format: "%-46@ %5@ %6@ %6@ %8@ %6@ %7@ %6@  %@", "document" as NSString, "pages" as NSString, "zones" as NSString, "vraies" as NSString, "précision" as NSString, "dout." as NSString, "manqués" as NSString, "rappel" as NSString, "état sans/avec original" as NSString))
for r in results {
    let s = stats(r.rows, blobs: r.blobs.count, blobPixels: 0)
    let nm = r.name.count > 46 ? "…" + r.name.suffix(45) : r.name
    if let e = r.error { print("\(nm)  ERREUR : \(e)"); continue }
    print(String(format: "%-46@ %5d %6d %6d %@  %6d %7d %@  %@ / %@%@", nm as NSString, r.pages, s.kept, s.true_, pct(s.precision) as NSString, s.doubt, s.blobs, pct(s.recall) as NSString,
                 r.stateWithout as NSString, r.stateWith as NSString,
                 (r.skipped > 0 ? "  (\(r.skipped) page(s) non comparable(s))" : "") + (r.rotated > 0 ? "  (\(r.rotated) page(s) tournée(s))" : "") as NSString))
}
print(String(repeating: "─", count: 110))
print(String(format: "TOTAL  zones détectées %d, retenues %d (écartées par les faux trous : %d), vraies %d", total.zones, total.kept, total.zones - total.kept, total.true_))
print("       PRÉCISION \(pct(total.precision))   RAPPEL ESTIMÉ \(pct(total.recall))   douteuses \(total.doubt) (dont vraies \(total.doubtTrue))   amas d'encre hors zone \(total.blobs)")
print("       vrais trous écartés à tort par le filtre des faux trous : \(filteredAway.count)")
print("       estimation actuelle (sans original) vs vérité : justesse \(pct(total.estAccuracy))  [répondue à raison \(total.estTP), à tort \(total.estFP) ; ratée \(total.estFN), vide à raison \(total.estTN)]")
let completeWithout = results.filter { $0.stateWithout == "complet" }.count
print("       documents complétés reconnus « complet » sans l'original : \(completeWithout)/\(results.count) ; avec l'original : \(results.filter { $0.stateWith == "complet" }.count)/\(results.count)")
print("")
print("Par source :")
for src in Set(allRows.map { $0.source }).sorted() {
    let s = stats(allRows.filter { $0.source == src }, blobs: 0, blobPixels: 0)
    print(String(format: "   %-10@ retenues %4d, vraies %4d, précision %@", src as NSString, s.kept, s.true_, pct(s.precision) as NSString))
}
let buckets: [(String, ClosedRange<Int>)] = [("0", 0...0), ("1-9", 1...9), ("10-39", 10...39), ("40-99", 40...99), ("100-299", 100...299), ("300+", 300...Int.max)]
print("")
print("Encre ajoutée par zone retenue (pixels, pour régler les seuils de PageDiff ; remplie si ≥ \(PageDiff.settings.minPixels) px et ≥ \(PageDiff.settings.minRatio * 100) % de la surface) :")
print("   " + buckets.map { b in "\(b.0) px : \(allRows.filter { $0.comparable && $0.meaningful && b.1.contains($0.added) }.count)" }.joined(separator: "   "))
print("")
print("Faux trous les plus « sûrs » (retenus, jamais remplis) — \(min(top, falsePositives.count)) sur \(falsePositives.count) :")
for r in falsePositives.prefix(top) { print("   " + describe(r)) }
print("")
print("Vrais trous écartés à tort par le filtre — \(min(top, filteredAway.count)) sur \(filteredAway.count) :")
for r in filteredAway.prefix(top) { print("   " + describe(r)) }
print("")
print("Estimation actuelle fausse (réponse ratée ou inventée) — \(min(top, estWrong.count)) sur \(estWrong.count) :")
for r in estWrong.prefix(top) { print("   [\(r.estimatedAnswered ? "estimée répondue, vide en vrai" : "estimée vide, remplie en vrai")] " + describe(r)) }
print("")
print("Trous manqués probables (encre ajoutée hors de toute zone) — \(min(top, worstBlobs.count)) sur \(worstBlobs.count) :")
for b in worstBlobs.prefix(top) { print("   " + describe(b)) }
