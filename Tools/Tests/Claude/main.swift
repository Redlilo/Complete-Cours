import Foundation
import PDFKit
import ImageIO
import CryptoKit
import Darwin

// Tests du moteur Claude contre un faux serveur local (claude_mock.py, à côté de ce fichier) : aucun appel réseau réel.
//
//   run.sh [options]               compile avec Sources/Core/*.swift puis lance tout
//   claude_tests [options]
//       --mock-port N              utilise un mock déjà lancé au lieu d'en démarrer un
//       --mock chemin              autre emplacement de claude_mock.py
//       --out dossier              journal du mock (par défaut build/claude/mock-out) : ni clé ni image
//       --save-images dossier      enregistre aussi les images reçues par le mock (pages de cours : à regarder, puis à effacer)
//       --engine-source chemin     fichier dont on vérifie l'absence de journaux (print, NSLog…)
//
// Les requêtes sont de VRAIES PageRequest : CoursPipeline.analyze sur des PDF réels (lecture seule) puis
// MarkedImage.make pour l'image jointe. Code de sortie non nul si un scénario échoue.

/// Pour arrêter le mock si le test est interrompu (Ctrl-C).
enum ClaudeTestSignal { static var pid: pid_t = 0 }

/// Résultats d'un scénario : on note tous les écarts au lieu de s'arrêter au premier.
final class ClaudeTestAsserts {
    private(set) var failures: [String] = []
    func expect(_ ok: Bool, _ message: @autoclosure () -> String) {
        if !ok { failures.append(message()) }
    }
}

struct ClaudeMockReport {
    let requests: Int
    let maxInflight: Int
    let errors: [String]
    let calls: [[String: Any]]
}

struct ClaudeTestRig {
    let engine: ClaudeEngine
    let inst: String
}

struct ClaudeTestDoc {
    let url: URL
    let name: String
    let pdf: PDFDocument
    let analyses: [PageAnalysis]
    let requests: [PageRequest]
}

/// Appel depuis le thread principal (comme le fait l'interface) : il ne doit pas le bloquer.
@MainActor
func claudeCompleteFromMain(_ engine: ClaudeEngine, _ request: PageRequest) async throws -> Int {
    try await engine.complete(request).count
}

final class ClaudeTestRunner {
    // MARK: Paramètres et état
    var port = 0
    var outDir = ""
    var imagesDir: String?
    var mockScript = ""
    var engineSource = ""
    var externalMock = false
    var process: Process?
    let control: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        return URLSession(configuration: c)
    }()

    /// Fausse clé : le mock ne reconnaît que celle-ci pour en noter l'empreinte.
    let canary = "sk-ant-api03-CANARI" + String((0..<40).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    var canaryFP: String { ClaudeTestRunner.fingerprint(canary) }
    var counter = 0
    var passed = 0
    var failed = 0
    var failedIDs: [String] = []
    var errorTexts: [String] = []
    var imageCount = 0
    var firstImage: String?
    let student = StudentProfile(nom: "Dupont", prenom: "Camille", classe: "2nde Test")

    // MARK: Aides de test

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func kind(_ e: Error) -> String {
        if e is CancellationError { return "annulation" }
        guard let e = e as? EngineError else { return "inconnue(\(type(of: e)))" }
        switch e {
        case .unavailable: return "unavailable"
        case .auth: return "auth"
        case .rateLimited: return "rateLimited"
        case .network: return "network"
        case .refused: return "refused"
        case .invalidResponse: return "invalidResponse"
        case .other: return "other"
        }
    }

    static func text(_ e: Error) -> String { (e as? EngineError)?.errorDescription ?? e.localizedDescription }

    /// Un message destiné à l'élève : français, sans jargon technique ni texte d'erreur système.
    static func problem(with m: String) -> String? {
        let low = " " + m.lowercased() + " "
        let words = [" le ", " la ", " les ", " de ", " du ", " des ", " une ", " un ", " pas ", " ta ", " ton ",
                     " vérifie ", " réessaie ", " essaie ", " recommence", " réglages"]
        if words.filter({ low.contains($0) }).count < 2 || low.contains("please") || low.contains("error:") {
            return "message peu clair ou pas en français : \(m)"
        }
        for jargon in ["Optional(", "Error Domain", "NSURL", "URLError", "Swift.", "EngineError", "\\n"] where m.contains(jargon) {
            return "texte technique dans le message (« \(jargon) ») : \(m)"
        }
        if m.range(of: "\\bnil\\b", options: .regularExpression) != nil { return "« nil » dans le message : \(m)" }
        return nil
    }

    func attempt<T>(_ op: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await op()) } catch { return .failure(error) }
    }

    /// Vérifie qu'un résultat est l'erreur attendue ; renvoie le message pour d'autres contrôles.
    @discardableResult
    func expectError<T>(_ a: ClaudeTestAsserts, _ r: Result<T, Error>, _ kind: String, fatal: Bool? = nil,
                        contains: [String] = []) -> String {
        switch r {
        case .success:
            a.expect(false, "aurait dû échouer avec une erreur « \(kind) »")
            return ""
        case .failure(let e):
            let m = ClaudeTestRunner.text(e)
            a.expect(ClaudeTestRunner.kind(e) == kind, "erreur « \(ClaudeTestRunner.kind(e)) » au lieu de « \(kind) » : \(m)")
            if let f = fatal, let ee = e as? EngineError { a.expect(ee.isFatal == f, "isFatal vaut \(ee.isFatal), attendu \(f)") }
            for s in contains { a.expect(m.localizedCaseInsensitiveContains(s), "le message ne contient pas « \(s) » : \(m)") }
            if kind != "annulation" {
                if let p = ClaudeTestRunner.problem(with: m) { a.expect(false, p) }
                a.expect(!m.contains(canary), "la clé apparaît dans le message d'erreur")
            }
            errorTexts.append(m)
            return m
        }
    }

    func rig(_ scenario: String, model: String = ClaudeEngine.defaultModel, key: String? = nil,
             suffix: String = "") -> ClaudeTestRig {
        counter += 1
        let inst = String(format: "t%03d", counter)
        let url = URL(string: "http://127.0.0.1:\(port)/\(scenario)/\(inst)\(suffix)")!
        return ClaudeTestRig(engine: ClaudeEngine(apiKey: key ?? canary, model: model, baseURL: url), inst: inst)
    }

    func scenario(_ id: String, _ title: String, _ body: (ClaudeTestAsserts) async -> Void) async {
        let a = ClaudeTestAsserts()
        let t0 = Date()
        await body(a)
        let label = "[\(id)] \(title) (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s)"
        if a.failures.isEmpty {
            passed += 1
            print("PASS  \(label)")
        } else {
            failed += 1
            failedIDs.append(id)
            print("FAIL  \(label)")
            for f in a.failures { print("        - \(f)") }
        }
    }

    // MARK: Le mock

    func controlRequest(_ path: String, post: Bool = false) async -> (Int, Data)? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = post ? "POST" : "GET"
        if post { req.httpBody = Data() }
        guard let (d, r) = try? await control.data(for: req) else { return nil }
        return ((r as? HTTPURLResponse)?.statusCode ?? 0, d)
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        var len = size
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    func startMock() async -> Bool {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        // anciennes images : on repart d'un dossier propre
        if let dir = imagesDir {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".jpg") {
                try? FileManager.default.removeItem(atPath: dir + "/" + f)
            }
        }
        if !externalMock {
            guard FileManager.default.fileExists(atPath: mockScript) else {
                print("ERREUR : mock introuvable : \(mockScript)")
                return false
            }
            port = ClaudeTestRunner.freePort()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", "-I", mockScript, String(port), "--out", outDir] + (imagesDir.map { ["--images", $0] } ?? [])
            p.standardOutput = FileHandle.nullDevice
            let errPath = outDir + "/mock.stderr"
            FileManager.default.createFile(atPath: errPath, contents: nil)
            p.standardError = FileHandle(forWritingAtPath: errPath)
            do { try p.run() } catch {
                print("ERREUR : impossible de lancer python3 : \(error)")
                return false
            }
            process = p
            ClaudeTestSignal.pid = p.processIdentifier
        }
        for _ in 0..<100 {
            if let (s, _) = await controlRequest("/_ping"), s == 200 { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        print("ERREUR : le mock ne répond pas sur le port \(port)")
        return false
    }

    /// Arrête le mock et dit s'il s'est terminé proprement (code 0, avant le délai).
    func stopMock() async -> Bool {
        guard let p = process else { return true }
        _ = await controlRequest("/_quit", post: true)
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        if p.isRunning {
            p.terminate()
            return false
        }
        ClaudeTestSignal.pid = 0
        return p.terminationStatus == 0
    }

    func report(_ inst: String) async -> ClaudeMockReport? {
        guard let (s, d) = await controlRequest("/_report/\(inst)"), s == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return ClaudeMockReport(requests: o["requests"] as? Int ?? 0, maxInflight: o["max_inflight"] as? Int ?? 0,
                                errors: o["errors"] as? [String] ?? [], calls: o["calls"] as? [[String: Any]] ?? [])
    }

    /// Récupère le rapport du mock : aucun écart de validation, la clé intacte, et (si demandé) le bon nombre de requêtes.
    @discardableResult
    func finish(_ a: ClaudeTestAsserts, _ r: ClaudeTestRig, requests: Int? = nil) async -> ClaudeMockReport? {
        guard let rep = await report(r.inst) else {
            a.expect(false, "le mock n'a reçu aucune requête de cette instance")
            return nil
        }
        a.expect(rep.errors.isEmpty, "le mock a relevé des écarts : \(rep.errors.joined(separator: " | "))")
        if let n = requests { a.expect(rep.requests == n, "\(rep.requests) requête(s) reçue(s) au lieu de \(n)") }
        for c in rep.calls {
            a.expect(c["key_fp"] as? String == canaryFP, "la clé reçue par le mock n'est pas celle qui a été donnée au moteur")
            if c["has_image"] as? Bool == true { imageCount += 1 }
            if let f = c["image_file"] as? String, firstImage == nil { firstImage = f }
        }
        return rep
    }

    /// Pages et zones demandées au mock, lues dans le texte de chaque requête de page (« page N sur M » puis la liste
    /// « ⟦n⟧ — … » après « Zones à remplir »), dans l'ordre d'arrivée.
    static func asked(_ rep: ClaudeMockReport) -> [(page: Int, numbers: [Int])] {
        rep.calls.compactMap { c -> (page: Int, numbers: [Int])? in
            guard c["kind"] as? String == "complete", let t = c["user_text"] as? String,
                  let r = t.range(of: "page [0-9]+ sur", options: .regularExpression),
                  let list = t.range(of: "Zones à remplir :\n") else { return nil }
            let numbers = t[list.upperBound...].split(separator: "\n").compactMap { line -> Int? in
                guard let m = line.range(of: "^⟦[0-9]+⟧ — ", options: .regularExpression) else { return nil }
                return Int(line[m].filter { $0.isNumber })
            }
            return (Int(t[r].filter { $0.isNumber }) ?? 0, numbers)
        }
    }

    /// Chaque zone à remplir doit avoir été demandée une fois, et une seule, quel que soit le découpage des pages en lots.
    func expectEveryZoneAskedOnce(_ a: ClaudeTestAsserts, _ rep: ClaudeMockReport, zones: [Zone]) {
        let want = zones.map { "\($0.page + 1):\($0.number)" }.sorted()
        let got = ClaudeTestRunner.asked(rep).flatMap { q in q.numbers.map { "\(q.page):\($0)" } }.sorted()
        a.expect(want == got, "\(got.count) zone(s) demandée(s) pour \(want.count) à remplir (manquantes : \(Set(want).subtracting(got).sorted()), en double ou en trop : \(Set(got.filter { g in got.filter { $0 == g }.count > 1 || !want.contains(g) }).sorted()))")
    }

    static func gap(_ rep: ClaudeMockReport, _ i: Int, _ j: Int) -> Double {
        guard i < rep.calls.count, j < rep.calls.count,
              let a = rep.calls[i]["t"] as? Double, let b = rep.calls[j]["t"] as? Double else { return -1 }
        return b - a
    }

    /// Champ JSON absent ou null.
    static func absent(_ v: Any?) -> Bool { v == nil || v is NSNull }

    static func sameJSON(_ a: Any?, _ b: Any?) -> Bool {
        guard let a = a as? [String: Any], let b = b as? [String: Any] else { return false }
        return NSDictionary(dictionary: a).isEqual(to: b)
    }

    /// Message d'humanisation : texte d'introduction + tableau JSON. L'ordre des clés du JSON n'est pas garanti
    /// d'un appel à l'autre : on compare donc le contenu, pas le texte brut.
    static func sameHumanizeText(_ received: String?, _ expected: String) -> Bool {
        func split(_ s: String) -> (String, NSArray)? {
            guard let r = s.range(of: "\n\n"),
                  let rows = try? JSONSerialization.jsonObject(with: Data(s[r.upperBound...].utf8)) as? [Any] else { return nil }
            return (String(s[..<r.lowerBound]), rows as NSArray)
        }
        guard let received, let a = split(received), let b = split(expected) else { return false }
        return a.0 == b.0 && a.1.isEqual(b.1)
    }

    // MARK: Vraies pages

    func loadDoc(folder: String, prefix: String, requests wanted: Bool = true) -> ClaudeTestDoc? {
        let dir = NSHomeDirectory() + "/Desktop/Cours/" + folder
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir),
              let file = names.sorted().first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".pdf") }) else { return nil }
        let url = URL(fileURLWithPath: dir + "/" + file)
        guard let doc = PDFDocument(url: url) else { return nil }
        let analyses = CoursPipeline.analyze(url: url, needText: false) { _, _ in }
        var requests: [PageRequest] = []
        if wanted {
            for an in analyses where !an.zones.isEmpty {
                if let r = makeRequest(doc: doc, name: url.deletingPathExtension().lastPathComponent, analysis: an) { requests.append(r) }
            }
        }
        return ClaudeTestDoc(url: url, name: url.deletingPathExtension().lastPathComponent, pdf: doc, analyses: analyses, requests: requests)
    }

    func makeRequest(doc: PDFDocument, name: String, analysis an: PageAnalysis) -> PageRequest? {
        guard let page = doc.page(at: an.pageIndex), let jpeg = MarkedImage.make(page: page, zones: an.zones) else { return nil }
        return PageRequest(documentName: name, pageNumber: an.pageIndex + 1, pageCount: doc.pageCount,
                           transcript: an.transcript, hasTextLayer: an.hasTextLayer, zones: an.zones,
                           markedImageJPEG: jpeg, student: student, todayText: Prompts.todayText())
    }

    // MARK: Programme principal

    func run() async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        var args = Array(CommandLine.arguments.dropFirst())
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root: URL = here.path.hasSuffix("Tools/Tests/Claude")
            ? here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            : URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/Projets/Complete-Cours")
        mockScript = option("--mock") ?? here.appendingPathComponent("claude_mock.py").path
        outDir = option("--out") ?? root.appendingPathComponent("build/claude/mock-out").path
        imagesDir = option("--save-images")
        engineSource = option("--engine-source") ?? root.appendingPathComponent("Sources/Core/ClaudeEngine.swift").path
        if let p = option("--mock-port"), let n = Int(p) { port = n; externalMock = true }

        print("Tests du moteur Claude : faux serveur local, aucun appel réseau réel.")
        signal(SIGINT) { _ in if ClaudeTestSignal.pid > 0 { kill(ClaudeTestSignal.pid, SIGTERM) }; _exit(130) }
        signal(SIGTERM) { _ in if ClaudeTestSignal.pid > 0 { kill(ClaudeTestSignal.pid, SIGTERM) }; _exit(143) }
        // garde-fou : si un scénario reste bloqué, on arrête tout (et le mock avec) au lieu d'attendre indéfiniment
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            print("FAIL  [garde-fou] les tests durent plus de 5 minutes : arrêt forcé")
            if ClaudeTestSignal.pid > 0 { kill(ClaudeTestSignal.pid, SIGTERM) }
            _exit(3)
        }

        guard await startMock() else { return 2 }
        print("Mock démarré sur 127.0.0.1:\(port) (journal dans \(outDir)" + (imagesDir.map { ", images dans \($0)" } ?? ", images non enregistrées") + ")\n")

        // ---- vraies pages ----
        let t0 = Date()
        let docA = loadDoc(folder: "Économie-Gestion", prefix: "Mission 1")
        let docB = loadDoc(folder: "Co-intervention", prefix: "Portail - Séance 1")
        let scan = loadDoc(folder: "_Originaux avant completion/Atelier Professionnel/Chantier 5", prefix: "Seance 1", requests: false)
        let docs = [docA, docB].compactMap { $0 }
        var pool: [PageRequest] = docs.flatMap { $0.requests }
        print("PDF réels analysés en \(String(format: "%.1f", Date().timeIntervalSince(t0))) s : "
              + docs.map { "« \($0.name) » → \($0.requests.count) page(s) avec zones, \($0.requests.reduce(0) { $0 + $1.zones.count }) zone(s)" }.joined(separator: " ; "))
        if let s = scan {
            print("Scan vierge « \(s.name) » : \(s.analyses.filter { !$0.zones.isEmpty }.count) page(s) avec zones, "
                  + "\(s.analyses.reduce(0) { $0 + $1.zones.count }) zone(s), jusqu'à \(s.analyses.map { $0.zones.count }.max() ?? 0) sur une page")
        }
        print("")
        guard !pool.isEmpty else {
            print("FAIL  [pdf] aucune page avec zones trouvée dans les PDF de test (~/Desktop/Cours).")
            _ = await stopMock()
            return 1
        }
        // une page « riche » d'abord (au moins 2 zones si possible)
        pool.sort { $0.zones.count > $1.zones.count }
        let req = pool[0]
        let humanizeItems: [HumanizeItem] = req.zones.prefix(3).map {
            HumanizeItem(id: $0.id, kind: .definition, question: $0.contextBefore,
                         answer: "Un exemple de réponse numéro \($0.id) à réécrire.", maxChars: 200)
        }

        await runContract()
        await runUnits()
        await runSuccessScenarios(req: req, humanizeItems: humanizeItems)
        await runErrorScenarios(req: req)
        await runRetryScenarios(req: req)
        await runResponseScenarios(req: req, humanizeItems: humanizeItems)
        await runConfigScenarios(req: req)
        await runTimingScenarios(req: req, pool: pool)
        await runKeyCheckScenarios()
        await runRevisionScenarios(req: req)
        await runRealPagesScenarios(scan: scan)
        await runPipelineScenarios(docs: docs, scan: scan)
        await runPrivacyScenarios()

        let clean = await stopMock()
        await scenario("mock_stop", "le faux serveur s'arrête proprement") { a in
            a.expect(clean, "le mock ne s'est pas arrêté proprement (voir \(outDir)/mock.stderr)")
        }
        if let err = try? String(contentsOfFile: outDir + "/mock.stderr", encoding: .utf8), !err.isEmpty {
            print("\nSortie d'erreur du mock :\n\(err)")
        }

        print("\n\(imageCount) image(s) de page reçue(s) par le mock" + (imagesDir.map { ", enregistrées dans \($0)" + (firstImage.map { " (par exemple \($0))" } ?? "") } ?? " (non enregistrées : option --save-images pour les regarder)"))
        print("Résultat : \(passed) scénario(s) réussi(s), \(failed) échec(s)\(failedIDs.isEmpty ? "" : " : " + failedIDs.joined(separator: ", "))")
        return failed == 0 ? 0 : 1
    }

    // MARK: 1. Contrat

    func runContract() async {
        await scenario("contrat", "signatures publiques et valeurs imposées") { a in
            a.expect(ClaudeEngine.models.map { $0.id } == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"], "liste des modèles")
            a.expect(ClaudeEngine.models.map { $0.label } == ["Claude Opus 5.5", "Claude Sonnet 5.5", "Claude Haiku 5.5"], "noms des modèles")
            a.expect(ClaudeEngine.models.map { $0.hint } == ["le plus précis", "très bon, environ 2 fois moins cher", "le moins cher, moins précis"], "commentaires des modèles")
            a.expect(ClaudeEngine.defaultModel == "claude-opus-5-5", "modèle par défaut")
            a.expect(ClaudeEngine.defaultBaseURL.absoluteString == "https://api.anthropic.com", "adresse par défaut")
            let e: CompletionEngine = ClaudeEngine(apiKey: "x", model: "claude-sonnet-5-5")
            a.expect(e.displayName == "Claude Sonnet 5.5", "displayName = \(e.displayName)")
            a.expect(e.usesImages, "usesImages")
            a.expect(e.maxConcurrentPages == 3, "maxConcurrentPages")
            a.expect(ClaudeEngine(apiKey: "x", model: "autre-modele").displayName == "autre-modele", "displayName d'un modèle inconnu")
            let t = ClaudeEngine.Tuning()
            a.expect(t.requestTimeout == 180 && t.maxWait == 30, "délai 180 s et attente plafonnée à 30 s")
            a.expect(t.generateTimeout == 420, "délai de révision 420 s")
            let m = ClaudeEngine.models
            a.expect(m.map { $0.tier } == ["Précis", "Équilibré", "Économique"], "libellés courts des modèles")
            a.expect(m.map { $0.inputPricePerMillion } == [4, 2, 0.10] && m.map { $0.outputPricePerMillion } == [20, 10, 0.50], "prix par million de jetons")
            a.expect(abs(m[0].estimatedPageCostUSD - 0.042) < 1e-9 && abs(m[1].estimatedPageCostUSD - 0.021) < 1e-9, "coût estimé d'une page (Opus, Sonnet)")
            a.expect(m[0].costNote == "environ 0,04 $ par page" && m[1].costNote == "environ 0,02 $ par page" && m[2].costNote == "moins de 0,01 $ par page", "notes de coût : \(m.map { $0.costNote })")
            let g: StructuredGenerator = ClaudeEngine(apiKey: "x", model: "claude-sonnet-5-5")
            a.expect(g.supportsImages && g.displayName == "Claude Sonnet 5.5", "StructuredGenerator : supportsImages et displayName")
        }
    }

    // MARK: 2. Fonctions pures

    func runUnits() async {
        await scenario("decode_zones", "décodage des zones : bruit, doublons, types, JSON entouré de ```") { a in
            let raw = """
            {"zones":[{"numero":1,"type":"mot","texte":"a"},{"numero":1,"type":"question","texte":"doublon"},
            {"numero":2,"type":"définition","texte":"c"},{"numero":3,"type":"inconnu","texte":"d"},
            {"numero":99,"type":"mot","texte":"hors requête"},{"numero":4,"type":"ignorer","texte":"à jeter"},
            {"numero":5.0,"type":"MOT","texte":"e"},{"numero":"6","type":"mot","texte":"f"},{"type":"mot","texte":"sans numéro"},
            {"numero":7,"type":"mot","texte":null}]}
            """
            let expected: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
            if let r = try? ClaudeEngine.decodeCompletion(raw, expected: expected) {
                a.expect(r.map { $0.number } == [1, 2, 3, 4, 5, 6, 7], "numéros : \(r.map { $0.number })")
                a.expect(r.first?.text == "a" && r.first?.kind == .mot, "le premier d'un doublon doit gagner")
                a.expect(r.first { $0.number == 2 }?.kind == .definition, "« définition » avec accent -> .definition")
                a.expect(r.first { $0.number == 3 }?.kind == .question, "type inconnu -> .question")
                a.expect(r.first { $0.number == 4 }?.kind == .ignorer && r.first { $0.number == 4 }?.text == "", "ignorer -> texte vide")
                a.expect(r.first { $0.number == 5 }?.kind == .mot, "numéro décimal 5.0 et type en majuscules")
                a.expect(r.first { $0.number == 6 }?.text == "f", "numéro donné sous forme de texte")
                a.expect(r.first { $0.number == 7 }?.text == "", "texte null -> texte vide")
            } else { a.expect(false, "décodage refusé") }

            let fenced = "```json\n{\"zones\":[{\"numero\":1,\"type\":\"mot\",\"texte\":\"x\"}]}\n```"
            a.expect((try? ClaudeEngine.decodeCompletion(fenced, expected: [1]))?.first?.text == "x", "JSON entouré de ```json")
            let spaced = "  \n{\"zones\":[{\"numero\":1,\"type\":\"mot\",\"texte\":\"x\"}]}\n  "
            a.expect((try? ClaudeEngine.decodeCompletion(spaced, expected: [1]))?.first?.text == "x", "JSON entouré d'espaces")
            for bad in ["pas du json", "{\"zones\": \"oops\"}", "{\"zones\": [", "[]", ""] {
                do { _ = try ClaudeEngine.decodeCompletion(bad, expected: [1]); a.expect(false, "« \(bad) » aurait dû échouer") }
                catch { a.expect(ClaudeTestRunner.kind(error) == "invalidResponse", "« \(bad) » : \(ClaudeTestRunner.kind(error))") }
            }
            do { _ = try ClaudeEngine.decodeCompletion("{\"zones\":[{\"numero\":9,\"type\":\"mot\",\"texte\":\"x\"}]}", expected: [1]); a.expect(false, "aucun numéro connu : doit échouer") }
            catch { a.expect(ClaudeTestRunner.kind(error) == "invalidResponse", "aucun numéro connu : \(ClaudeTestRunner.kind(error))") }
        }

        await scenario("decode_humanize", "décodage de l'humanisation : id inconnus, doublons, textes vides") { a in
            let raw = "{\"reponses\":[{\"id\":10,\"texte\":\"un\"},{\"id\":10,\"texte\":\"doublon\"},{\"id\":11,\"texte\":\"   \"},{\"id\":404,\"texte\":\"inconnu\"},{\"id\":12,\"texte\":\"trois\"}]}"
            if let r = try? ClaudeEngine.decodeHumanization(raw, expected: [10, 11, 12, 13]) {
                a.expect(r == [10: "un", 12: "trois"], "résultat : \(r)")
            } else { a.expect(false, "décodage refusé") }
            for bad in ["", "{\"reponses\": 3}", "{\"reponses\":[{\"id\":99,\"texte\":\"x\"}]}"] {
                do { _ = try ClaudeEngine.decodeHumanization(bad, expected: [10]); a.expect(false, "« \(bad) » aurait dû échouer") }
                catch { a.expect(ClaudeTestRunner.kind(error) == "invalidResponse", "« \(bad) » : \(ClaudeTestRunner.kind(error))") }
            }
        }

        await scenario("attentes", "durées d'attente : retry-after, exponentiel, plafond de 30 s") { a in
            let t = ClaudeEngine.Tuning()
            func w(_ ra: String?, _ n: Int, _ rl: Bool) -> Double { ClaudeEngine.waitTime(retryAfter: ra, retryNumber: n, rateLimited: rl, tuning: t) }
            a.expect(w("120", 1, true) == 30, "retry-after 120 doit être plafonné à 30 s (\(w("120", 1, true)))")
            a.expect(w("2", 1, true) == 2, "retry-after 2 -> 2 s")
            a.expect(w(" 3 ", 1, true) == 3, "retry-after avec espaces")
            a.expect(w(nil, 1, true) == 2 && w(nil, 2, true) == 4 && w(nil, 3, true) == 8, "429 sans en-tête : 2, 4, 8 s")
            a.expect(w(nil, 1, false) == 1 && w(nil, 2, false) == 2, "5xx : 1, 2 s")
            a.expect(w(nil, 12, true) == 30, "plafond à 30 s")
            a.expect(w("abc", 1, true) == 2, "retry-after illisible : attente exponentielle")
            a.expect(w("-5", 1, true) == 0.25, "retry-after négatif : attente minimale")
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let d = w(f.string(from: Date().addingTimeInterval(6)), 1, true)
            a.expect(d > 3 && d <= 6.5, "retry-after au format date HTTP : \(d)")
            a.expect(ClaudeEngine.waitTime(retryAfter: "100", retryNumber: 1, rateLimited: true, tuning: t, jitter: 1.15) == 30, "le plafond s'applique aussi avec le délai aléatoire")
        }

        await scenario("adresses", "https accepté, http seulement vers 127.0.0.1 / localhost") { a in
            let ok = ["https://api.anthropic.com", "https://proxy.example.org/prefix", "http://127.0.0.1:8080", "http://localhost:9", "HTTP://LOCALHOST"]
            let no = ["http://api.anthropic.com", "http://example.com", "http://127.0.0.1.example.com", "http://localhost.example.com",
                      "http://127.0.0.1@example.com", "ftp://127.0.0.1", "file:///tmp/x", "api.anthropic.com"]
            for u in ok { a.expect(URL(string: u).map(ClaudeEngine.isAllowedBaseURL) == true, "\(u) devrait être accepté") }
            for u in no { a.expect(URL(string: u).map(ClaudeEngine.isAllowedBaseURL) == false, "\(u) devrait être refusé") }
        }

        await scenario("erreurs_url", "erreurs système (hors ligne, délai, DNS, TLS…) -> network, en français") { a in
            let codes: [(URLError.Code, [String])] = [
                (.notConnectedToInternet, ["connexion"]), (.dataNotAllowed, ["connexion"]), (.timedOut, ["180 secondes"]),
                (.networkConnectionLost, ["coupée"]), (.cannotFindHost, ["trouver"]), (.dnsLookupFailed, ["trouver"]),
                (.cannotConnectToHost, ["joindre"]), (.secureConnectionFailed, ["TLS"]), (.serverCertificateUntrusted, ["TLS"]),
                (.serverCertificateHasBadDate, ["TLS"]), (.cancelled, ["interrompue"]), (.badServerResponse, ["connexion"]),
            ]
            for (code, words) in codes {
                let e = ClaudeEngine.networkError(URLError(code), timeout: 180)
                guard case .network(let m) = e else { a.expect(false, "\(code.rawValue) : pas une erreur network"); continue }
                for w in words { a.expect(m.localizedCaseInsensitiveContains(w), "code \(code.rawValue) : « \(w) » absent de « \(m) »") }
                if let p = ClaudeTestRunner.problem(with: m) { a.expect(false, "code \(code.rawValue) : \(p)") }
                a.expect(!e.isFatal, "une erreur réseau ne doit pas être fatale")
            }
        }
    }

    // MARK: 3. Succès

    func runSuccessScenarios(req: PageRequest, humanizeItems: [HumanizeItem]) async {
        await scenario("ok_opus", "succès : vraie page (image + texte), Opus, contenu exact de la requête") { a in
            let r = self.rig("ok")
            let res = await self.attempt { try await r.engine.complete(req) }
            if case .success(let answers) = res {
                let wanted = Set(req.zones.map { $0.number })
                a.expect(Set(answers.map { $0.number }) == wanted && answers.count == wanted.count, "numéros reçus \(answers.map { $0.number }) pour \(wanted.sorted())")
                for z in req.zones {
                    if let ans = answers.first(where: { $0.number == z.number }) {
                        a.expect(ans.kind == z.kind, "zone \(z.number) : type \(ans.kind) au lieu de \(z.kind)")
                        a.expect(ans.kind == .ignorer || !ans.text.isEmpty, "zone \(z.number) : texte vide")
                    }
                }
            } else if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }

            if let rep = await self.finish(a, r, requests: 1), let c = rep.calls.first {
                a.expect(c["kind"] as? String == "complete", "type de requête \(String(describing: c["kind"]))")
                a.expect(c["model"] as? String == "claude-opus-5-5", "modèle")
                a.expect(c["max_tokens"] as? Int == 8000, "max_tokens \(String(describing: c["max_tokens"]))")
                a.expect(c["has_image"] as? Bool == true, "l'image doit être jointe")
                a.expect(c["fallbacks"] as? Bool == true && c["anthropic_beta"] as? String == "server-side-fallback-2026-07-01", "fallbacks et en-tête bêta pour Opus")
                a.expect(c["system"] as? String == Prompts.completionSystem, "system différent de Prompts.completionSystem")
                a.expect(c["user_text"] as? String == Prompts.completionUserText(req), "texte différent de Prompts.completionUserText")
                a.expect(ClaudeTestRunner.sameJSON(c["schema"], Prompts.completionSchema), "schéma différent de Prompts.completionSchema")
                if let img = c["image"] as? [String: Any], let w = img["w"] as? Int, let h = img["h"] as? Int, let n = img["bytes"] as? Int,
                   let sent = req.markedImageJPEG {
                    print("        image reçue : \(w)x\(h) px, \(n / 1024) Ko, page \(req.pageNumber) de « \(req.documentName) » avec \(req.zones.count) zone(s)")
                    // l'image reçue est exactement celle qui a été envoyée, et un vrai décodeur JPEG la lit avec les mêmes dimensions
                    a.expect(img["sha256"] as? String == ClaudeTestRunner.sha256(sent), "l'image reçue n'est pas identique à l'image envoyée")
                    if let src = CGImageSourceCreateWithData(sent as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                        a.expect(cg.width == w && cg.height == h, "dimensions : \(cg.width)x\(cg.height) (ImageIO) contre \(w)x\(h) (mock)")
                        a.expect(max(w, h) == 1568, "plus grand côté \(max(w, h)) px au lieu de 1568")
                    } else { a.expect(false, "l'image envoyée n'est pas décodable") }
                } else { a.expect(false, "pas d'image dans le rapport") }
            }
        }

        await scenario("ok_sonnet", "Sonnet : fallbacks + en-tête bêta") { a in
            let r = self.rig("ok", model: "claude-sonnet-5-5")
            let res = await self.attempt { try await r.engine.complete(req) }
            if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            if let rep = await self.finish(a, r, requests: 1) {
                let c = rep.calls.first
                a.expect(c?["fallbacks"] as? Bool == true && c?["model"] as? String == "claude-sonnet-5-5"
                         && c?["anthropic_beta"] as? String == "server-side-fallback-2026-07-01", "fallbacks pour Sonnet")
            }
        }

        await scenario("ok_haiku", "Haiku : jamais de fallbacks ni d'en-tête bêta") { a in
            let r = self.rig("ok", model: "claude-haiku-5-5")
            let res = await self.attempt { try await r.engine.complete(req) }
            if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            if let rep = await self.finish(a, r, requests: 1) {
                let c = rep.calls.first
                a.expect(c?["fallbacks"] as? Bool == false && ClaudeTestRunner.absent(c?["anthropic_beta"]), "Haiku ne doit pas recevoir fallbacks ni l'en-tête bêta")
            }
        }

        await scenario("sans_image", "page sans image : seul le bloc texte est envoyé") { a in
            var noImage = req
            noImage.markedImageJPEG = nil
            let r = self.rig("ok")
            let res = await self.attempt { try await r.engine.complete(noImage) }
            if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            if let rep = await self.finish(a, r, requests: 1) {
                a.expect(rep.calls.first?["has_image"] as? Bool == false, "aucune image attendue")
            }
        }

        await scenario("sans_zone", "page sans zone : aucune requête, aucune réponse") { a in
            var none = req
            none.zones = []
            let r = self.rig("ok")
            let res = await self.attempt { try await r.engine.complete(none) }
            if case .success(let out) = res { a.expect(out.isEmpty, "réponses inattendues") } else { a.expect(false, "erreur inattendue") }
            a.expect(await self.report(r.inst) == nil, "une requête a été envoyée")
        }

        await scenario("reponse_bruitee", "numéro inconnu ignoré, doublon écarté, type inconnu -> question") { a in
            let r = self.rig("ok_noisy")
            let res = await self.attempt { try await r.engine.complete(req) }
            if case .success(let answers) = res {
                let wanted = req.zones.map { $0.number }.sorted()
                a.expect(answers.map { $0.number } == wanted, "numéros \(answers.map { $0.number }) pour \(wanted)")
                a.expect(!answers.contains { $0.text == "DOUBLON" || $0.text == "intrus" }, "le doublon ou l'intrus n'a pas été écarté")
                a.expect(answers.last?.kind == .question, "type inconnu -> .question (reçu \(String(describing: answers.last?.kind)))")
            } else if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            await self.finish(a, r, requests: 1)
        }

        for (id, title) in [("fenced_json", "réponse entourée de ```json acceptée"),
                            ("split_text", "JSON réparti sur plusieurs blocs texte : concaténés"),
                            ("fallback_block", "réponse avec un bloc « fallback » (reprise côté serveur) : seul le texte compte")] {
            await scenario(id, title) { a in
                let r = self.rig(id)
                let res = await self.attempt { try await r.engine.complete(req) }
                if case .success(let answers) = res {
                    a.expect(Set(answers.map { $0.number }) == Set(req.zones.map { $0.number }), "numéros \(answers.map { $0.number })")
                } else if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
                let res2 = await self.attempt { try await r.engine.humanize(humanizeItems) }
                if case .failure(let e) = res2 { a.expect(false, "humanisation : erreur inattendue : \(ClaudeTestRunner.text(e))") }
                await self.finish(a, r, requests: 2)
            }
        }

        await scenario("humanize", "humanisation : bon schéma, sans image, id inconnu ignoré") { a in
            let r = self.rig("ok")
            let res = await self.attempt { try await r.engine.humanize(humanizeItems) }
            if case .success(let out) = res {
                a.expect(Set(out.keys) == Set(humanizeItems.map { $0.id }), "id reçus \(out.keys.sorted())")
                for it in humanizeItems { a.expect(out[it.id] == "u" + it.answer.dropFirst(), "texte de \(it.id) : \(String(describing: out[it.id]))") }
                a.expect(out[424242] == nil, "l'id inconnu doit être ignoré")
            } else if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            if let rep = await self.finish(a, r, requests: 1), let c = rep.calls.first {
                a.expect(c["kind"] as? String == "humanize" && c["has_image"] as? Bool == false, "requête d'humanisation sans image")
                a.expect(c["system"] as? String == Prompts.humanizeSystem, "system différent de Prompts.humanizeSystem")
                a.expect(ClaudeTestRunner.sameHumanizeText(c["user_text"] as? String, Prompts.humanizeUserText(humanizeItems)),
                         "texte différent de Prompts.humanizeUserText")
                a.expect(ClaudeTestRunner.sameJSON(c["schema"], Prompts.humanizeSchema), "schéma différent de Prompts.humanizeSchema")
                a.expect(c["max_tokens"] as? Int == 8000 && c["fallbacks"] as? Bool == true, "max_tokens 8000 et fallbacks (Opus)")
            }
        }

        await scenario("humanize_vide", "humanize([]) ne fait aucune requête") { a in
            let r = self.rig("ok")
            let res = await self.attempt { try await r.engine.humanize([]) }
            if case .success(let out) = res { a.expect(out.isEmpty, "résultat non vide") } else { a.expect(false, "erreur inattendue") }
            a.expect(await self.report(r.inst) == nil, "une requête a été envoyée")
        }

        await scenario("corps_deterministe", "deux requêtes identiques envoient exactement les mêmes octets (clés triées)") { a in
            let r = self.rig("ok")
            _ = await self.attempt { try await r.engine.complete(req) }
            _ = await self.attempt { try await r.engine.complete(req) }
            if let rep = await self.finish(a, r, requests: 2) {
                let s0 = rep.calls[0]["schema"], s1 = rep.calls[1]["schema"]
                a.expect(ClaudeTestRunner.sameJSON(s0, s1), "schémas différents")
                a.expect(rep.calls[0]["body_sha"] as? String == rep.calls[1]["body_sha"] as? String, "les deux corps de requête ne sont pas identiques octet pour octet")
            }
        }
    }

    // MARK: 4. Erreurs HTTP

    func runErrorScenarios(req: PageRequest) async {
        let cases: [(id: String, title: String, kind: String, fatal: Bool, words: [String])] = [
            ("auth401", "401 -> auth (fatale), aucune nouvelle tentative", "auth", true, ["clé"]),
            ("forbidden403", "403 -> auth (fatale), avec le message d'Anthropic", "auth", true, ["accès", "not allowed to use this model"]),
            ("billing402", "402 -> moteur indisponible (fatale)", "unavailable", true, ["crédit"]),
            ("credit400", "400 « credit balance » -> moteur indisponible (fatale)", "unavailable", true, ["crédit"]),
            ("notfound404", "404 -> other, avec le nom du modèle", "other", false, ["claude-opus-5-5", "modèle"]),
            ("toolarge413", "413 -> other, page trop volumineuse", "other", false, ["volumineuse"]),
            ("bad400", "400 -> other, avec le message de l'API, sans nouvel essai", "other", false, ["text content blocks must be non-empty"]),
            ("redirect302", "redirection refusée (la clé ne part pas ailleurs)", "other", false, ["redirection"]),
        ]
        for c in cases {
            await scenario(c.id, c.title) { a in
                let r = self.rig(c.id)
                let res = await self.attempt { try await r.engine.complete(req) }
                self.expectError(a, res, c.kind, fatal: c.fatal, contains: c.words)
                await self.finish(a, r, requests: 1)
            }
        }

        for (id, title) in [("refusal", "refus de sécurité (contenu vide)"), ("refusal_partial", "refus de sécurité (texte partiel)")] {
            await scenario(id, "stop_reason refusal -> refused : \(title)") { a in
                let r = self.rig(id)
                let res = await self.attempt { try await r.engine.complete(req) }
                self.expectError(a, res, "refused", fatal: false, contains: ["refusé"])
                await self.finish(a, r, requests: 1)
            }
        }
    }

    // MARK: 5. Réessais

    func runRetryScenarios(req: PageRequest) async {
        await scenario("rate_limit_ok", "429 avec retry-after: 1 puis succès") { a in
            let r = self.rig("rate_limit_ok")
            let res = await self.attempt { try await r.engine.complete(req) }
            if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            if let rep = await self.finish(a, r, requests: 2) {
                let g = ClaudeTestRunner.gap(rep, 0, 1)
                a.expect(g >= 0.9 && g < 5, "attente de \(String(format: "%.2f", g)) s au lieu d'environ 1 s")
                a.expect(rep.calls.first?["status"] as? Int == 429, "la première réponse devait être 429")
            }
        }

        await scenario("rate_limit_noheader", "429 sans retry-after : attente exponentielle de 2 s, puis succès") { a in
            let r = self.rig("rate_limit_noheader_ok")
            let res = await self.attempt { try await r.engine.complete(req) }
            if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            if let rep = await self.finish(a, r, requests: 2) {
                let g = ClaudeTestRunner.gap(rep, 0, 1)
                a.expect(g >= 1.9 && g < 6, "attente de \(String(format: "%.2f", g)) s au lieu d'environ 2 s")
            }
        }

        await scenario("rate_limit_cap", "429 avec retry-after: 120 : l'attente est plafonnée (plafond réduit à 1 s pour le test)") { a in
            let r = self.rig("rate_limit_cap_ok")
            r.engine.tuning.maxWait = 1
            let res = await self.attempt { try await r.engine.complete(req) }
            if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            if let rep = await self.finish(a, r, requests: 2) {
                let g = ClaudeTestRunner.gap(rep, 0, 1)
                a.expect(g >= 0.9 && g < 3, "attente de \(String(format: "%.2f", g)) s au lieu de 1 s (plafond)")
            }
        }

        await scenario("rate_limit_always", "429 sans fin : 3 essais puis rateLimited") { a in
            let r = self.rig("rate_limit_always")
            let t0 = Date()
            let res = await self.attempt { try await r.engine.complete(req) }
            let dt = Date().timeIntervalSince(t0)
            self.expectError(a, res, "rateLimited", fatal: false, contains: ["limite"])
            a.expect(dt >= 1.9 && dt < 10, "durée totale \(String(format: "%.1f", dt)) s (deux attentes d'environ 1 s attendues)")
            await self.finish(a, r, requests: 3)
        }

        await scenario("overloaded_ok", "529 puis succès (attente exponentielle)") { a in
            let r = self.rig("overloaded_ok")
            let res = await self.attempt { try await r.engine.complete(req) }
            if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            if let rep = await self.finish(a, r, requests: 2) {
                let g = ClaudeTestRunner.gap(rep, 0, 1)
                a.expect(g >= 0.9 && g < 5, "attente de \(String(format: "%.2f", g)) s au lieu d'environ 1 s")
            }
        }

        await scenario("overloaded_retry_after", "529 avec retry-after: 2 : l'attente demandée par le serveur est respectée") { a in
            let r = self.rig("overloaded_retry_after_ok")
            let res = await self.attempt { try await r.engine.complete(req) }
            if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            if let rep = await self.finish(a, r, requests: 2) {
                let g = ClaudeTestRunner.gap(rep, 0, 1)
                a.expect(g >= 1.9 && g < 6, "attente de \(String(format: "%.2f", g)) s au lieu d'environ 2 s")
            }
        }

        await scenario("overloaded_always", "529 sans fin : 2 réessais puis network") { a in
            let r = self.rig("overloaded_always")
            let t0 = Date()
            let res = await self.attempt { try await r.engine.complete(req) }
            let dt = Date().timeIntervalSince(t0)
            self.expectError(a, res, "network", fatal: false, contains: ["surchargé"])
            a.expect(dt >= 2.8 && dt < 12, "durée totale \(String(format: "%.1f", dt)) s (attentes de 1 s puis 2 s attendues)")
            await self.finish(a, r, requests: 3)
        }

        for (id, title) in [("server500_ok", "500 puis succès"), ("status408_ok", "408 puis succès"),
                            ("bad_gateway_html_ok", "502 avec une page HTML (proxy) puis succès"), ("drop_ok", "connexion coupée par le serveur puis succès"),
                            ("truncated_body_ok", "connexion coupée au milieu de la réponse puis succès")] {
            await scenario(id, title) { a in
                let r = self.rig(id)
                let res = await self.attempt { try await r.engine.complete(req) }
                if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
                await self.finish(a, r, requests: 2)
            }
        }

        for (id, title) in [("fallbacks400_a", "400 « fallbacks » -> nouvelle requête sans fallbacks"),
                            ("fallbacks400_b", "400 sur l'en-tête bêta -> nouvelle requête sans fallbacks")] {
            await scenario(id, title + ", mémorisé pour la suite") { a in
                let r = self.rig(id)
                let res1 = await self.attempt { try await r.engine.complete(req) }
                if case .failure(let e) = res1 { a.expect(false, "1re page : erreur inattendue : \(ClaudeTestRunner.text(e))") }
                if let rep = await self.finish(a, r, requests: 2) {
                    a.expect(rep.calls[0]["fallbacks"] as? Bool == true && rep.calls[0]["status"] as? Int == 400, "la 1re requête devait porter fallbacks et recevoir 400")
                    a.expect(rep.calls[1]["fallbacks"] as? Bool == false && rep.calls[1]["status"] as? Int == 200, "la 2e requête devait être sans fallbacks")
                    a.expect(ClaudeTestRunner.absent(rep.calls[1]["anthropic_beta"]), "la 2e requête ne doit plus porter l'en-tête bêta")
                }
                // les pages suivantes ne retentent pas fallbacks
                let res2 = await self.attempt { try await r.engine.complete(req) }
                if case .failure(let e) = res2 { a.expect(false, "2e page : erreur inattendue : \(ClaudeTestRunner.text(e))") }
                let res3 = await self.attempt { try await r.engine.humanize([HumanizeItem(id: 5, kind: .question, question: "Pourquoi ?", answer: "Parce que.", maxChars: 100)]) }
                if case .failure(let e) = res3 { a.expect(false, "humanisation : erreur inattendue : \(ClaudeTestRunner.text(e))") }
                if let rep = await self.finish(a, r, requests: 4) {
                    a.expect(rep.calls[2]["fallbacks"] as? Bool == false && rep.calls[3]["fallbacks"] as? Bool == false, "les requêtes suivantes ne doivent plus porter fallbacks")
                }
            }
        }

        await scenario("connexion_perimee", "le serveur ferme la connexion entre deux pages : la page suivante aboutit quand même") { a in
            let r = self.rig("stale_ok")
            var failures = 0
            for _ in 0..<4 {
                if case .failure = await self.attempt({ try await r.engine.complete(req) }) { failures += 1 }
            }
            a.expect(failures == 0, "\(failures) page(s) en échec sur 4")
            await self.finish(a, r, requests: 4)
        }

        await scenario("enchainement", "429, puis 400 « fallbacks », puis réponse coupée, puis succès : l'état passe d'un essai au suivant") { a in
            let r = self.rig("seq_429_400fb_trunc_ok")
            let res = await self.attempt { try await r.engine.complete(req) }
            if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            if let rep = await self.finish(a, r, requests: 4) {
                let statuses = rep.calls.map { $0["status"] as? Int ?? 0 }
                let fallbacks = rep.calls.map { $0["fallbacks"] as? Bool ?? false }
                let maxTokens = rep.calls.map { $0["max_tokens"] as? Int ?? 0 }
                a.expect(statuses == [429, 400, 200, 200], "statuts \(statuses)")
                a.expect(fallbacks == [true, true, false, false], "fallbacks \(fallbacks) : renvoyés après le 429, retirés après le 400")
                a.expect(maxTokens == [8000, 8000, 8000, 16000], "max_tokens \(maxTokens)")
            }
        }

        await scenario("fallbacks400_parallele", "6 pages en parallèle quand le serveur refuse fallbacks : toutes aboutissent") { a in
            let r = self.rig("fallbacks400_a")
            let okCount = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<6 {
                    group.addTask {
                        if case .success = await self.attempt({ try await r.engine.complete(req) }) { return true }
                        return false
                    }
                }
                var n = 0
                for await ok in group where ok { n += 1 }
                return n
            }
            a.expect(okCount == 6, "\(okCount) page(s) réussie(s) sur 6")
            if let rep = await self.finish(a, r) {
                a.expect(rep.requests >= 7 && rep.requests <= 12, "\(rep.requests) requête(s) (entre 7 et 12 attendues)")
                a.expect(rep.calls.filter { $0["status"] as? Int == 200 }.count == 6, "6 succès attendus")
            }
        }

        await scenario("max_tokens_ok", "réponse coupée (max_tokens) : une relance à 16000, puis succès") { a in
            let r = self.rig("max_tokens_ok")
            let res = await self.attempt { try await r.engine.complete(req) }
            if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            if let rep = await self.finish(a, r, requests: 2) {
                a.expect(rep.calls[0]["max_tokens"] as? Int == 8000 && rep.calls[1]["max_tokens"] as? Int == 16000,
                         "max_tokens \(String(describing: rep.calls[0]["max_tokens"])) puis \(String(describing: rep.calls[1]["max_tokens"]))")
            }
        }

        await scenario("max_tokens_always", "toujours coupée : invalidResponse après une seule relance") { a in
            let r = self.rig("max_tokens_always")
            let res = await self.attempt { try await r.engine.complete(req) }
            self.expectError(a, res, "invalidResponse", fatal: false, contains: ["coupée"])
            await self.finish(a, r, requests: 2)
        }

        await scenario("max_tokens_humanize", "humanisation coupée : même relance à 16000") { a in
            let r = self.rig("max_tokens_ok")
            let res = await self.attempt { try await r.engine.humanize([HumanizeItem(id: 5, kind: .question, question: "Pourquoi ?", answer: "Parce que.", maxChars: 100)]) }
            if case .success(let out) = res { a.expect(out[5] != nil, "aucune réponse pour l'id 5") }
            else if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            if let rep = await self.finish(a, r, requests: 2) {
                a.expect(rep.calls[0]["max_tokens"] as? Int == 8000 && rep.calls[1]["max_tokens"] as? Int == 16000, "max_tokens 8000 puis 16000")
            }
        }
    }

    // MARK: 6. Réponses inexploitables

    func runResponseScenarios(req: PageRequest, humanizeItems: [HumanizeItem]) async {
        for (id, title, words) in [("invalid_json", "texte qui n'est pas du JSON", ["réponse"]),
                                   ("bad_shape", "JSON de mauvaise forme", ["réponse"]),
                                   ("no_zones", "JSON valide mais aucune zone connue", ["réponse"]),
                                   ("empty_content", "réponse sans aucun contenu", ["réponse"]),
                                   ("html200", "page HTML à la place de la réponse (portail Wi-Fi, proxy)", ["réponse", "réseau"]),
                                   ("context_window", "page trop longue pour le modèle", ["trop de texte"])] {
            await scenario(id, "\(title) -> invalidResponse, sans nouvel essai") { a in
                let r = self.rig(id)
                let res = await self.attempt { try await r.engine.complete(req) }
                self.expectError(a, res, "invalidResponse", fatal: false, contains: words)
                await self.finish(a, r, requests: 1)
            }
        }

        await scenario("humanize_invalide", "humanisation : réponse inexploitable -> invalidResponse (les réponses d'origine restent)") { a in
            let r = self.rig("invalid_json")
            let res = await self.attempt { try await r.engine.humanize(humanizeItems) }
            self.expectError(a, res, "invalidResponse", fatal: false, contains: ["réponse"])
            await self.finish(a, r, requests: 1)
        }
    }

    // MARK: 7. Configuration

    func runConfigScenarios(req: PageRequest) async {
        await scenario("cle_vide", "clé absente -> unavailable (fatale), aucune requête") { a in
            let r = self.rig("ok", key: "   ")
            let res = await self.attempt { try await r.engine.complete(req) }
            self.expectError(a, res, "unavailable", fatal: true, contains: ["clé"])
            a.expect(await self.report(r.inst) == nil, "une requête a été envoyée")
        }

        await scenario("cle_invalide", "clé avec guillemet typographique ou espace interne -> auth (fatale), aucune requête") { a in
            for bad in ["sk-ant-\u{201C}abc\u{201D}", "sk-ant abc", "sk-ant-é"] {
                let r = self.rig("ok", key: bad)
                let res = await self.attempt { try await r.engine.complete(req) }
                self.expectError(a, res, "auth", fatal: true, contains: ["clé"])
                a.expect(await self.report(r.inst) == nil, "une requête a été envoyée avec « \(bad) »")
            }
        }

        await scenario("adresse_refusee", "http hors machine locale, ftp et adresse sans schéma -> unavailable, aucune requête") { a in
            for u in ["http://example.com", "ftp://127.0.0.1", "http://127.0.0.1.example.com"] {
                let engine = ClaudeEngine(apiKey: self.canary, model: ClaudeEngine.defaultModel, baseURL: URL(string: u)!)
                let t0 = Date()
                let res = await self.attempt { try await engine.complete(req) }
                self.expectError(a, res, "unavailable", fatal: true, contains: ["https"])
                a.expect(Date().timeIntervalSince(t0) < 1, "l'adresse \(u) devait être refusée tout de suite")
            }
            let r = self.rig("ok")
            let engine = ClaudeEngine(apiKey: self.canary, model: "  ", baseURL: URL(string: "http://127.0.0.1:\(self.port)/ok/\(r.inst)")!)
            self.expectError(a, await self.attempt { try await engine.complete(req) }, "unavailable", fatal: true, contains: ["modèle"])
            a.expect(await self.report(r.inst) == nil, "une requête a été envoyée sans modèle")
        }

        await scenario("cle_espaces", "clé collée avec espaces et retour à la ligne : nettoyée") { a in
            let r = self.rig("ok", key: "  \(self.canary)\n")
            let res = await self.attempt { try await r.engine.complete(req) }
            if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            await self.finish(a, r, requests: 1)    // vérifie aussi que la clé reçue est la clé sans espaces
        }

        await scenario("adresse_slash", "adresse de base avec « / » final et préfixe de chemin") { a in
            let r = self.rig("ok", suffix: "/")
            let res = await self.attempt { try await r.engine.complete(req) }
            if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            await self.finish(a, r, requests: 1)
        }

        await scenario("hors_ligne", "serveur injoignable -> network, message de connexion") { a in
            let closed = ClaudeTestRunner.freePort()
            let engine = ClaudeEngine(apiKey: self.canary, model: ClaudeEngine.defaultModel, baseURL: URL(string: "http://127.0.0.1:\(closed)")!)
            let t0 = Date()
            let res = await self.attempt { try await engine.complete(req) }
            self.expectError(a, res, "network", fatal: false, contains: ["connexion"])
            a.expect(Date().timeIntervalSince(t0) < 8, "trop long pour un refus de connexion immédiat")
        }

        await scenario("tls", "https vers un serveur qui ne parle pas TLS -> network, message de connexion sécurisée") { a in
            let r = self.rig("ok")
            let url = URL(string: "https://127.0.0.1:\(self.port)/ok/\(r.inst)")!
            let engine = ClaudeEngine(apiKey: self.canary, model: ClaudeEngine.defaultModel, baseURL: url)
            let t0 = Date()
            let res = await self.attempt { try await engine.complete(req) }
            let m = self.expectError(a, res, "network", fatal: false)
            print("        message reçu : « \(m) »")
            a.expect(Date().timeIntervalSince(t0) < 15, "trop long pour un échec TLS")
            a.expect(await self.report(r.inst) == nil, "le mock a reçu une requête alors que la poignée de main TLS devait échouer")
        }
    }

    // MARK: 8. Durées, annulation, parallélisme

    func runTimingScenarios(req: PageRequest, pool: [PageRequest]) async {
        await scenario("annulation", "réponse très lente : l'annulation de la Task arrête tout de suite") { a in
            let r = self.rig("slow")
            let task = Task { try await r.engine.complete(req) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let t0 = Date()
            task.cancel()
            let res = await task.result
            let dt = Date().timeIntervalSince(t0)
            self.expectError(a, res, "annulation")
            a.expect(dt < 2, "l'annulation a pris \(String(format: "%.1f", dt)) s")
            if let rep = await self.report(r.inst) { a.expect(rep.requests == 1 && rep.errors.isEmpty, "requêtes : \(rep.requests), écarts : \(rep.errors)") }
        }

        await scenario("annulation_humanize", "annulation pendant l'humanisation") { a in
            let r = self.rig("slow")
            let item = HumanizeItem(id: 5, kind: .question, question: "Pourquoi ?", answer: "Parce que.", maxChars: 100)
            let task = Task { try await r.engine.humanize([item]) }
            try? await Task.sleep(nanoseconds: 700_000_000)
            let t0 = Date()
            task.cancel()
            let res = await task.result
            self.expectError(a, res, "annulation")
            a.expect(Date().timeIntervalSince(t0) < 2, "l'annulation a pris trop de temps")
        }

        await scenario("annulation_avant", "Task déjà annulée au départ : aucune requête") { a in
            let r = self.rig("ok")
            let task = Task { () -> [ZoneAnswer] in
                withUnsafeCurrentTask { $0?.cancel() }           // annulée juste avant l'appel
                return try await r.engine.complete(req)
            }
            self.expectError(a, await task.result, "annulation")
            a.expect(await self.report(r.inst) == nil, "une requête a été envoyée par une Task annulée")
        }

        await scenario("annulation_attente", "annulation pendant l'attente avant un nouvel essai (429)") { a in
            let r = self.rig("rate_limit_always")
            let task = Task { try await r.engine.complete(req) }
            try? await Task.sleep(nanoseconds: 400_000_000)   // la 1re réponse 429 est arrivée, le moteur attend
            let t0 = Date()
            task.cancel()
            let res = await task.result
            self.expectError(a, res, "annulation")
            a.expect(Date().timeIntervalSince(t0) < 1, "l'annulation de l'attente a pris trop de temps")
            if let rep = await self.report(r.inst) { a.expect(rep.requests == 1, "\(rep.requests) requête(s) : aucun nouvel essai après l'annulation") }
        }

        await scenario("delai", "délai dépassé -> network (délai de requête réduit à 2 s pour le test)") { a in
            let r = self.rig("slow_timeout")
            r.engine.tuning.requestTimeout = 2
            let t0 = Date()
            let res = await self.attempt { try await r.engine.complete(req) }
            let dt = Date().timeIntervalSince(t0)
            self.expectError(a, res, "network", fatal: false, contains: ["délai", "2 secondes"])
            a.expect(dt >= 1.5 && dt < 7, "durée \(String(format: "%.1f", dt)) s au lieu d'environ 2 s")
        }

        await scenario("parallele", "3 pages en parallèle, thread principal libre pendant l'appel") { a in
            let pages = Array(pool.prefix(3))
            let r = self.rig("ok_delay")
            let beat = ClaudeTestHeartbeat()
            beat.start()
            let t0 = Date()
            let results: [(Int, Result<[ZoneAnswer], Error>)] = await withTaskGroup(of: (Int, Result<[ZoneAnswer], Error>).self) { group in
                for (i, p) in pages.enumerated() {
                    group.addTask { (i, await self.attempt { try await r.engine.complete(p) }) }
                }
                var out: [(Int, Result<[ZoneAnswer], Error>)] = []
                for await x in group { out.append(x) }
                return out
            }
            let dt = Date().timeIntervalSince(t0)
            beat.stop()
            for (i, res) in results {
                switch res {
                case .success(let answers):
                    a.expect(Set(answers.map { $0.number }) == Set(pages[i].zones.map { $0.number }), "page \(i) : numéros mélangés")
                case .failure(let e): a.expect(false, "page \(i) : \(ClaudeTestRunner.text(e))")
                }
            }
            if let rep = await self.finish(a, r, requests: pages.count), pages.count >= 2 {
                a.expect(rep.maxInflight >= 2, "pas de parallélisme : \(rep.maxInflight) requête(s) en même temps")
            }
            a.expect(beat.maxGap < 0.5, "thread principal bloqué \(String(format: "%.2f", beat.maxGap)) s")
            print("        \(pages.count) page(s) en \(String(format: "%.2f", dt)) s, plus long arrêt du thread principal : \(String(format: "%.0f", beat.maxGap * 1000)) ms")
        }

        await scenario("thread_principal", "appel depuis le thread principal (comme l'interface) : il reste libre") { a in
            let r = self.rig("ok_delay")
            let beat = ClaudeTestHeartbeat()
            beat.start()
            let res = await self.attempt { try await claudeCompleteFromMain(r.engine, req) }
            beat.stop()
            if case .success(let n) = res { a.expect(n == req.zones.count, "\(n) réponse(s) pour \(req.zones.count) zone(s)") }
            else if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            a.expect(beat.maxGap < 0.3, "thread principal bloqué \(String(format: "%.2f", beat.maxGap)) s")
            await self.finish(a, r, requests: 1)
            print("        plus long arrêt du thread principal : \(String(format: "%.0f", beat.maxGap * 1000)) ms")
        }
    }

    // MARK: 9. Vérification de la clé

    func runKeyCheckScenarios() async {
        func check(_ scenarioName: String, model: String = ClaudeEngine.defaultModel, key: String? = nil) async -> (String?, ClaudeTestRig) {
            let r = rig(scenarioName, model: model, key: key)
            let url = URL(string: "http://127.0.0.1:\(port)/\(scenarioName)/\(r.inst)")!
            return (await ClaudeEngine.checkKey(apiKey: key ?? canary, model: model, baseURL: url), r)
        }

        await scenario("cle_ok", "checkKey : 200 -> nil (aussi quand la réponse est coupée à 16 jetons)") { a in
            for name in ["ok", "ping_max_tokens"] {
                for model in ClaudeEngine.models.map({ $0.id }) {
                    let (msg, r) = await check(name, model: model)
                    a.expect(msg == nil, "\(name)/\(model) : message inattendu : \(msg ?? "")")
                    if let rep = await self.finish(a, r, requests: 1), let c = rep.calls.first {
                        a.expect(c["kind"] as? String == "ping" && c["max_tokens"] as? Int == 16 && c["fallbacks"] as? Bool == false, "requête de vérification incorrecte")
                    }
                }
            }
        }

        let failing: [(String, String, [String])] = [
            ("auth401", "clé refusée", ["clé"]),
            ("forbidden403", "accès refusé", ["accès"]),
            ("notfound404", "modèle indisponible", ["claude-opus-5-5"]),
            ("billing402", "crédit épuisé", ["crédit"]),
            ("credit400", "crédit épuisé (400)", ["crédit"]),
            ("rate_limit_always", "trop de demandes (sans réessai)", ["demandes"]),
            ("overloaded_always", "serveurs surchargés (sans réessai)", ["surchargés"]),
            ("bad400", "requête refusée", ["Anthropic"]),
        ]
        for (name, title, words) in failing {
            await scenario("cle_\(name)", "checkKey : \(title)") { a in
                let (msg, r) = await check(name)
                if let m = msg {
                    for w in words { a.expect(m.localizedCaseInsensitiveContains(w), "le message ne contient pas « \(w) » : \(m)") }
                    if let p = ClaudeTestRunner.problem(with: m) { a.expect(false, p) }
                    self.errorTexts.append(m)
                } else { a.expect(false, "doit renvoyer un message d'erreur") }
                await self.finish(a, r, requests: 1)
            }
        }

        await scenario("cle_reseau", "checkKey : serveur injoignable, adresse refusée, clé vide") { a in
            let closed = ClaudeTestRunner.freePort()
            let m1 = await ClaudeEngine.checkKey(apiKey: self.canary, model: ClaudeEngine.defaultModel, baseURL: URL(string: "http://127.0.0.1:\(closed)")!)
            a.expect(m1?.localizedCaseInsensitiveContains("connexion") == true || m1?.localizedCaseInsensitiveContains("joindre") == true, "serveur injoignable : \(m1 ?? "nil")")
            let m2 = await ClaudeEngine.checkKey(apiKey: self.canary, model: ClaudeEngine.defaultModel, baseURL: URL(string: "http://example.com")!)
            a.expect(m2?.contains("https") == true, "adresse refusée : \(m2 ?? "nil")")
            let m3 = await ClaudeEngine.checkKey(apiKey: "", model: ClaudeEngine.defaultModel)
            a.expect(m3?.contains("clé") == true, "clé vide : \(m3 ?? "nil")")
            for m in [m1, m2, m3].compactMap({ $0 }) {
                self.errorTexts.append(m)
                if let p = ClaudeTestRunner.problem(with: m) { a.expect(false, p) }
            }
        }

        await scenario("cle_annulee", "checkKey : tâche annulée -> message d'interruption, sans planter") { a in
            let r = self.rig("slow")
            let url = URL(string: "http://127.0.0.1:\(self.port)/slow/\(r.inst)")!
            let task = Task { await ClaudeEngine.checkKey(apiKey: self.canary, model: ClaudeEngine.defaultModel, baseURL: url) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let t0 = Date()
            task.cancel()
            let msg = await task.value
            a.expect(msg != nil, "un message était attendu")
            a.expect(Date().timeIntervalSince(t0) < 2, "l'annulation a pris trop de temps")
        }
    }

    // MARK: 10. Pages chargées (scan de 64 zones)

    func runRealPagesScenarios(scan: ClaudeTestDoc?) async {
        guard let scan, let heavy = scan.analyses.max(by: { $0.zones.count < $1.zones.count }), heavy.zones.count >= 1,
              let req = makeRequest(doc: scan.pdf, name: scan.name, analysis: heavy) else {
            print("SKIP  [page_chargee] scan vierge de test introuvable (~/Desktop/Cours/_Originaux avant completion) ou sans zone")
            return
        }
        await scenario("page_chargee", "scan vierge de \(req.zones.count) zones : requête valide et toutes les zones décodées") { a in
            let r = self.rig("ok")
            let res = await self.attempt { try await r.engine.complete(req) }
            if case .success(let answers) = res {
                a.expect(Set(answers.map { $0.number }) == Set(req.zones.map { $0.number }), "\(answers.count) réponse(s) pour \(req.zones.count) zone(s)")
            } else if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            if let rep = await self.finish(a, r, requests: 1), let c = rep.calls.first {
                a.expect(c["has_image"] as? Bool == true, "image absente")
                if let img = c["image"] as? [String: Any], let w = img["w"] as? Int, let h = img["h"] as? Int, let n = img["bytes"] as? Int {
                    print("        page \(req.pageNumber) du scan : image \(w)x\(h) px, \(n / 1024) Ko, \(req.zones.count) zones, requête de \((c["body_bytes"] as? Int ?? 0) / 1024) Ko")
                }
                a.expect((c["body_bytes"] as? Int ?? 0) < 8_000_000, "requête trop grosse")
            }
        }
    }

    // MARK: 11. Pipeline complet

    func runPipelineScenarios(docs: [ClaudeTestDoc], scan: ClaudeTestDoc?) async {
        // De bout en bout : complétion + humanisation, avec le vrai moteur et le faux serveur.
        for doc in docs {
            await scenario("pipeline_\(doc.name.prefix(12))", "CoursPipeline.complete de bout en bout sur « \(doc.name) » (complétion + humanisation)") { a in
                let r = self.rig("ok")
                let zones = doc.analyses.flatMap { $0.zones }
                let t0 = Date()
                let result = await self.attempt {
                    try await CoursPipeline.complete(url: doc.url, documentName: doc.name, analyses: doc.analyses, zones: zones,
                                                     engine: r.engine, settings: CompletionSettings(humanize: true, student: self.student),
                                                     onUpdate: { _, _, _ in })
                }
                switch result {
                case .failure(let e): a.expect(false, "erreur : \(ClaudeTestRunner.text(e))")
                case .success(let out):
                    a.expect(out.count == zones.count, "\(out.count) zone(s) au lieu de \(zones.count)")
                    a.expect(out.allSatisfy { $0.error == nil }, "zones en erreur : \(out.filter { $0.error != nil }.map { "\($0.number): \($0.error ?? "")" })")
                    a.expect(out.allSatisfy { !$0.enabled || !$0.answer.isEmpty }, "une zone activée n'a pas de réponse")
                    let humanizable = out.filter { $0.enabled && $0.kind.isHumanizable }
                    a.expect(humanizable.allSatisfy { $0.humanized }, "\(humanizable.filter { !$0.humanized }.count) réponse(s) à humaniser ne l'ont pas été")
                    a.expect(out.filter { $0.kind == .mot }.allSatisfy { !$0.humanized }, "un mot à compléter a été humanisé")
                    let pagesWithZones = Set(zones.map { $0.page }).count
                    if let rep = await self.finish(a, r) {
                        let completes = rep.calls.filter { $0["kind"] as? String == "complete" }.count
                        let humanizes = rep.calls.filter { $0["kind"] as? String == "humanize" }.count
                        self.expectEveryZoneAskedOnce(a, rep, zones: zones)
                        a.expect(completes >= pagesWithZones, "\(completes) requête(s) de page pour \(pagesWithZones) page(s)")
                        a.expect(humanizes == (humanizable.count + 9) / 10, "\(humanizes) requête(s) d'humanisation pour \(humanizable.count) réponse(s) (lots de 10)")
                        a.expect(rep.calls.filter { $0["kind"] as? String == "complete" }.allSatisfy { $0["has_image"] as? Bool == true }, "une page est partie sans image")
                        print("        \(zones.count) zone(s), \(pagesWithZones) page(s), \(completes) requête(s) de page, \(humanizable.count) humanisée(s), \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, \(rep.requests) requête(s), jusqu'à \(rep.maxInflight) en parallèle")
                    }
                }
            }
        }

        // Un scan de 8 pages chargées en zones : 3 pages en parallèle au plus.
        if scan == nil { print("SKIP  [pipeline_scan] scan vierge de test introuvable") }
        if let doc = scan {
            await scenario("pipeline_scan", "CoursPipeline.complete sur le scan « \(doc.name) » : 3 pages en parallèle au plus") { a in
                let r = self.rig("ok_delay")
                let zones = doc.analyses.flatMap { $0.zones }
                let t0 = Date()
                let result = await self.attempt {
                    try await CoursPipeline.complete(url: doc.url, documentName: doc.name, analyses: doc.analyses, zones: zones,
                                                     engine: r.engine, settings: CompletionSettings(humanize: true, student: self.student),
                                                     onUpdate: { _, _, _ in })
                }
                switch result {
                case .failure(let e): a.expect(false, "erreur : \(ClaudeTestRunner.text(e))")
                case .success(let out):
                    a.expect(out.count == zones.count && out.allSatisfy { $0.error == nil }, "zones en erreur : \(out.filter { $0.error != nil }.count)")
                    let pagesWithZones = Set(zones.map { $0.page }).count
                    if let rep = await self.finish(a, r) {
                        let completes = rep.calls.filter { $0["kind"] as? String == "complete" }.count
                        self.expectEveryZoneAskedOnce(a, rep, zones: zones)
                        if completes >= 2 {
                            a.expect(rep.maxInflight >= 2 && rep.maxInflight <= r.engine.maxConcurrentPages, "\(rep.maxInflight) requête(s) en parallèle (attendu entre 2 et \(r.engine.maxConcurrentPages))")
                        }
                        print("        \(zones.count) zone(s), \(pagesWithZones) page(s), \(completes) requête(s) de page, jusqu'à \(rep.maxInflight) en parallèle, \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
                    }
                }
            }
        }

        // Comment le pipeline reçoit nos erreurs : une clé refusée arrête tout ; un refus de sécurité ne concerne que la page.
        if let doc = docs.last {
            await scenario("pipeline_auth", "clé refusée (401) : le pipeline s'arrête tout de suite avec l'erreur d'authentification") { a in
                let r = self.rig("auth401")
                let zones = doc.analyses.flatMap { $0.zones }
                let t0 = Date()
                let result = await self.attempt {
                    try await CoursPipeline.complete(url: doc.url, documentName: doc.name, analyses: doc.analyses, zones: zones,
                                                     engine: r.engine, settings: CompletionSettings(humanize: true, student: self.student),
                                                     onUpdate: { _, _, _ in })
                }
                self.expectError(a, result, "auth", fatal: true, contains: ["clé"])
                a.expect(Date().timeIntervalSince(t0) < 5, "trop long")
                if let rep = await self.finish(a, r) {
                    a.expect(rep.requests <= r.engine.maxConcurrentPages, "\(rep.requests) requête(s) envoyée(s) malgré l'erreur fatale")
                }
            }
        }
        if let doc = docs.first {
            await scenario("pipeline_refus", "refus de sécurité : zones marquées en erreur (message français), pas d'exception") { a in
                let r = self.rig("refusal")
                let zones = doc.analyses.flatMap { $0.zones }
                let result = await self.attempt {
                    try await CoursPipeline.complete(url: doc.url, documentName: doc.name, analyses: doc.analyses, zones: zones,
                                                     engine: r.engine, settings: CompletionSettings(humanize: true, student: self.student),
                                                     onUpdate: { _, _, _ in })
                }
                switch result {
                case .failure(let e): a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))")
                case .success(let out):
                    a.expect(out.count == zones.count && out.allSatisfy { $0.error?.contains("refusé") == true }, "zones sans le message de refus : \(out.filter { $0.error == nil }.count)")
                    a.expect(out.allSatisfy { $0.answer.isEmpty }, "une réponse a été écrite malgré le refus")
                    if let m = out.first?.error, let p = ClaudeTestRunner.problem(with: m) { a.expect(false, p) }
                }
                if let rep = await self.finish(a, r) {
                    self.expectEveryZoneAskedOnce(a, rep, zones: zones)
                    a.expect(rep.requests == ClaudeTestRunner.asked(rep).count, "\(rep.requests) requête(s) : un refus ne doit pas être renouvelé")
                }
            }
        }
    }


    // MARK: 11. Mode « Révision » : StructuredGenerator.generate

    func runRevisionScenarios(req: PageRequest) async {
        let system = "Tu aides un élève de Seconde à réviser son cours. Réponds uniquement en JSON."
        let userText = "Voici le cours à résumer. Fais une fiche de révision courte."
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string", "minLength": 1, "maxLength": 80],
                "points": ["type": "array", "items": ["type": "string"], "minItems": 3, "maxItems": 12],
                "level": ["type": "integer", "minimum": 1, "maximum": 5],
                "kind": ["type": "string", "enum": ["fiche", "quiz"]],
                "minLength": ["type": "string"],     // un champ nommé comme un mot-clé : doit rester
                "terms": ["type": "array", "items": ["type": "object",
                          "properties": ["term": ["type": "string"], "definition": ["type": "string"]],
                          "required": ["term", "definition"]]],
            ],
            "required": ["title", "points", "level", "kind", "minLength", "terms"],
        ]
        guard let jpeg = req.markedImageJPEG else { return }

        await scenario("revision_schema", "generate : le schéma envoyé respecte les restrictions des sorties structurées") { a in
            let s = ClaudeEngine.supportedSchema(schema)
            let text = String(data: (try? JSONSerialization.data(withJSONObject: s, options: .sortedKeys)) ?? Data(), encoding: .utf8) ?? ""
            for k in ["\"maxLength\"", "\"minimum\"", "\"maximum\"", "\"maxItems\"", "\"minItems\"", "\"minLength\":1"] {
                a.expect(!text.contains(k), "le schéma nettoyé contient encore \(k)")
            }
            let props = s["properties"] as? [String: Any]
            a.expect(props?["minLength"] != nil, "le champ « minLength » (un nom de champ) a été supprimé à tort")
            a.expect(s["additionalProperties"] as? Bool == false, "additionalProperties false à la racine")
            let terms = (props?["terms"] as? [String: Any])?["items"] as? [String: Any]
            a.expect(terms?["additionalProperties"] as? Bool == false, "additionalProperties false dans les objets imbriqués")
        }

        await scenario("revision_ok", "generate : images avant le texte, schéma nettoyé, max_tokens 12000, fallbacks (Opus), JSON renvoyé") { a in
            let r = self.rig("ok")
            let res = await self.attempt { try await r.engine.generate(system: system, userText: userText, images: [jpeg, jpeg], schema: schema) }
            if case .success(let text) = res {
                let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                a.expect(o?["kind"] as? String == "fiche" && o?["title"] is String && (o?["terms"] as? [Any])?.isEmpty == false,
                         "JSON renvoyé inattendu : \(text)")
            } else if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            if let rep = await self.finish(a, r, requests: 1), let c = rep.calls.first {
                a.expect(c["kind"] as? String == "generic" && c["image_count"] as? Int == 2, "2 images attendues, reçu \(String(describing: c["image_count"]))")
                a.expect(c["max_tokens"] as? Int == 12000, "max_tokens \(String(describing: c["max_tokens"]))")
                a.expect(c["fallbacks"] as? Bool == true && c["anthropic_beta"] as? String == "server-side-fallback-2026-07-01", "fallbacks et en-tête bêta pour Opus")
                a.expect(c["system"] as? String == system && c["user_text"] as? String == userText, "system ou texte modifié")
                a.expect(ClaudeTestRunner.sameJSON(c["schema"], ClaudeEngine.supportedSchema(schema)), "schéma reçu différent du schéma nettoyé")
            }
        }

        await scenario("revision_sans_image", "generate : sans image, et Haiku n'envoie jamais fallbacks") { a in
            let r = self.rig("ok", model: "claude-haiku-5-5")
            let res = await self.attempt { try await r.engine.generate(system: system, userText: userText, images: [], schema: schema) }
            if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
            if let rep = await self.finish(a, r, requests: 1), let c = rep.calls.first {
                a.expect(c["has_image"] as? Bool == false && c["fallbacks"] as? Bool == false, "sans image ni fallbacks pour Haiku")
            }
        }

        let errors: [(id: String, kind: String, fatal: Bool, words: [String])] = [
            ("auth401", "auth", true, ["clé"]),
            ("billing402", "unavailable", true, ["crédit"]),
            ("credit400", "unavailable", true, ["crédit"]),
            ("notfound404", "other", false, ["modèle"]),
            ("toolarge413", "other", false, ["volumineuse"]),
            ("refusal", "refused", false, ["refusé"]),
            ("context_window", "invalidResponse", false, ["trop de texte"]),
            ("max_tokens_always", "invalidResponse", false, ["coupée", "document"]),
        ]
        for c in errors {
            await scenario("revision_\(c.id)", "generate : \(c.id) -> \(c.kind)") { a in
                let r = self.rig(c.id)
                let res = await self.attempt { try await r.engine.generate(system: system, userText: userText, images: [jpeg], schema: schema) }
                self.expectError(a, res, c.kind, fatal: c.fatal, contains: c.words)
                await self.finish(a, r, requests: c.id == "max_tokens_always" ? 2 : 1)
            }
        }

        for id in ["rate_limit_ok", "overloaded_ok", "server500_ok", "max_tokens_ok", "fallbacks400_a"] {
            await scenario("revision_\(id)", "generate : \(id) -> réessai puis succès") { a in
                let r = self.rig(id)
                r.engine.tuning.backoffBase = 0.05
                r.engine.tuning.rateLimitBase = 0.05
                let res = await self.attempt { try await r.engine.generate(system: system, userText: userText, images: [jpeg], schema: schema) }
                if case .failure(let e) = res { a.expect(false, "erreur inattendue : \(ClaudeTestRunner.text(e))") }
                if let rep = await self.finish(a, r), id == "max_tokens_ok" {
                    a.expect(rep.requests == 2 && rep.calls.last?["max_tokens"] as? Int == 16000, "relance à 16000 attendue")
                } else if id != "max_tokens_ok" {
                    // le contrôle de finish() sur les écarts a déjà eu lieu ; au moins 2 requêtes pour un réessai
                    if let rep = await self.report(r.inst) { a.expect(rep.requests >= 2, "\(rep.requests) requête(s), un réessai était attendu") }
                }
            }
        }

        await scenario("revision_delai", "generate : délai de révision dépassé -> network") { a in
            let r = self.rig("slow_timeout")
            r.engine.tuning.generateTimeout = 2
            let res = await self.attempt { try await r.engine.generate(system: system, userText: userText, images: [], schema: schema) }
            self.expectError(a, res, "network", fatal: false, contains: ["délai"])
        }

        await scenario("revision_mock_strict", "le faux serveur refuse un corps de révision interdit (schéma à bornes, temperature, thinking, tool_choice, prefill)") { a in
            let r = self.rig("ok")
            let bad: [String: Any] = [
                "model": "claude-opus-5-5", "max_tokens": 12000, "system": system,
                "temperature": 0.2, "thinking": ["type": "disabled"], "tool_choice": ["type": "any"],
                "messages": [["role": "user", "content": [["type": "text", "text": userText]]],
                             ["role": "assistant", "content": "{"]],
                "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": [
                    "type": "object", "properties": ["a": ["type": "string", "minLength": 2]], "required": ["a"]]]],
            ]
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(self.port)/ok/\(r.inst)/v1/messages")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.setValue("sk-ant-api03-CANARI-test", forHTTPHeaderField: "x-api-key")
            req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            req.httpBody = try? JSONSerialization.data(withJSONObject: bad)
            let status = (try? await self.control.data(for: req)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
            a.expect(status == 400, "le mock a répondu \(String(describing: status)) au lieu de 400")
            let errs = (await self.report(r.inst))?.errors.joined(separator: " | ") ?? ""
            for word in ["temperature", "thinking", "tool_choice", "minLength", "additionalProperties", "messages"] {
                a.expect(errs.contains(word), "le mock n'a pas relevé « \(word) » : \(errs)")
            }
        }
    }

    // MARK: 12. Vie privée

    func runPrivacyScenarios() async {
        await scenario("vie_privee", "ni la clé ni les images dans les messages, le journal du mock ou le code") { a in
            for m in self.errorTexts { a.expect(!m.contains(self.canary), "la clé apparaît dans un message d'erreur") }
            a.expect(!self.errorTexts.isEmpty, "aucun message d'erreur n'a été contrôlé")
            if let log = try? String(contentsOfFile: self.outDir + "/mock.log", encoding: .utf8) {
                a.expect(!log.isEmpty, "journal du mock vide")
                a.expect(!log.contains(self.canary) && !log.contains("CANARI") && !log.contains("/9j/"), "la clé ou une image apparaît dans le journal du mock")
            } else { a.expect(false, "journal du mock introuvable") }
            if let src = try? String(contentsOfFile: self.engineSource, encoding: .utf8) {
                for banned in ["print(", "NSLog(", "os_log(", "Logger(", "debugPrint(", "dump(", "OSLog", "UserDefaults", "FileManager", "write(to"] {
                    a.expect(!src.contains(banned), "ClaudeEngine.swift contient \(banned)")
                }
                for banned in ["temperature", "top_p", "top_k", "tool_choice", "\"thinking\""] {
                    // ces mots ne doivent apparaître que dans des commentaires (jamais dans une chaîne envoyée)
                    let inCode = src.split(separator: "\n").contains { line in
                        let l = line.trimmingCharacters(in: .whitespaces)
                        return !l.hasPrefix("//") && l.contains(banned)
                    }
                    a.expect(!inCode, "« \(banned) » apparaît hors commentaire dans ClaudeEngine.swift")
                }
            } else { a.expect(false, "source introuvable : \(self.engineSource)") }
        }
    }
}

/// Mesure le plus long silence du thread principal (file principale) pendant un appel.
final class ClaudeTestHeartbeat {
    private var timer: DispatchSourceTimer?
    private var last = Date()
    private(set) var maxGap: TimeInterval = 0

    func start() {
        last = Date()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [self] in
            let now = Date()
            maxGap = max(maxGap, now.timeIntervalSince(last))
            last = now
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

let exitCode = await ClaudeTestRunner().run()
exit(exitCode)
