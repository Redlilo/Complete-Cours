import Foundation
import Darwin
import PDFKit

// Tests du moteur « Claude (mon compte) » (ClaudeCodeEngine). À lancer avec run.sh (compile avec -D COMPTE_PERSO).
//
//   - Phase 1 : le VRAI programme Claude Code installé, seulement pour ce qui ne coûte rien : --version, auth status,
//     et un appel -p qui répond « Not logged in » (ni réseau, ni quota). Ignoré s'il est absent ; l'appel -p est ignoré
//     s'il est connecté.
//   - Phase 2 : un FAUX programme (fake_claude.py) qui vérifie les arguments exacts, refuse de tourner si une variable
//     ANTHROPIC_* / CLAUDE_CODE_* / CLAUDECODE existe (le test en place de fausses dans l'environnement du parent) et
//     rejoue des scénarios. Aucun appel réseau, aucune connexion, jamais « auth login » pour de vrai.
//
//   claudecode_tests [--fake chemin/fake_claude.py] [--work dossier]       code de sortie non nul si un test échoue

#if COMPTE_PERSO

// MARK: - Mini cadre de test

var nbReussis = 0, nbEchecs = 0, nbIgnores = 0

func verif(_ ok: Bool, _ nom: String, _ detail: @autoclosure () -> String = "") {
    if ok { nbReussis += 1; print("  OK      \(nom)") } else {
        nbEchecs += 1
        let d = detail()
        print("  ÉCHEC   \(nom)" + (d.isEmpty ? "" : "   → " + d))
    }
}
func ignore(_ nom: String, _ raison: String) { nbIgnores += 1; print("  IGNORÉ  \(nom) (\(raison))") }
func titre(_ t: String) { print("\n== \(t)") }

let fm = FileManager.default
let racineProjet = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
var fauxSource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fake_claude.py").path
var dossierTest = NSTemporaryDirectory() + "ClaudeCodeTests-\(getpid())"
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        if a == "--fake", let v = it.next() { fauxSource = v }
        if a == "--work", let v = it.next() { dossierTest = v }
    }
}

// MARK: - Outils

func ecrire(_ texte: String, _ url: URL, executable: Bool = false) {
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? texte.write(to: url, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
}

func attendre(_ secondes: Double, _ condition: () -> Bool) async -> Bool {
    let fin = Date().addingTimeInterval(secondes)
    while Date() < fin {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Vivant = existe et n'est pas un zombie.
func vivant(_ pid: Int32) -> Bool {
    var info = proc_bsdinfo()
    let taille = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, taille) == taille else { return false }
    return info.pbi_status != 5
}

func nbDescripteurs() -> Int {
    let octets = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
    return octets > 0 ? Int(octets) / MemoryLayout<proc_fdinfo>.size : -1
}

func dossiersTemporairesDeLApp() -> Int {
    ((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("CompleteCours-ClaudeCode-") }.count
}

func image(_ octets: Int) -> Data { Data((0..<octets).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

func zonesDe(_ n: Int) -> [Zone] {
    (1...max(1, n)).map { i in
        Zone(id: 100 + i, page: 0, number: i, source: .texte, lines: [WritingLine(x0: 50, x1: 300, y: 700 - CGFloat(i) * 20)],
             contextBefore: "avant \(i)", contextAfter: "après \(i)", kind: .mot)
    }
}

func requete(zones n: Int = 3, image octets: Int? = 2_000) -> PageRequest {
    PageRequest(documentName: "Cours de test", pageNumber: 1, pageCount: 2,
                transcript: (1...max(1, n)).map { "Texte ⟦\($0)⟧" }.joined(separator: " puis "), hasTextLayer: true,
                zones: zonesDe(n), markedImageJPEG: octets.map { image($0) }, student: StudentProfile(),
                todayText: "mardi 17 novembre 2026")
}

func elements(_ n: Int) -> [HumanizeItem] {
    (1...max(1, n)).map { HumanizeItem(id: 10 + $0, kind: $0 % 2 == 0 ? .definition : .question, question: "Consigne \($0)",
                                       answer: "Réponse \($0)", maxChars: 200) }
}

func message(_ e: EngineError) -> String { e.errorDescription ?? "" }
func genre(_ e: EngineError) -> String {
    switch e {
    case .unavailable: return "unavailable"
    case .auth: return "auth"
    case .rateLimited: return "rateLimited"
    case .network: return "network"
    case .refused: return "refused"
    case .invalidResponse: return "invalid"
    case .other: return "other"
    }
}
func est(_ e: EngineError, _ g: String, _ morceaux: String...) -> Bool { genre(e) == g && morceaux.allSatisfy { message(e).contains($0) } }

// MARK: - Monde de test (Phase 2)

let racine = URL(fileURLWithPath: dossierTest)
let fauxHome = racine.appendingPathComponent("home")
let travail = racine.appendingPathComponent("travail")
let faux = racine.appendingPathComponent("bin/claude")
let etat = fauxHome.appendingPathComponent("fake-claude-state")

func scenario(_ nom: String) {
    try? fm.createDirectory(at: etat, withIntermediateDirectories: true)
    try? nom.write(to: etat.appendingPathComponent("scenario"), atomically: true, encoding: .utf8)
}
func etatFichier(_ nom: String, _ contenu: String?) {
    try? fm.createDirectory(at: etat, withIntermediateDirectories: true)
    if let c = contenu { try? c.write(to: etat.appendingPathComponent(nom), atomically: true, encoding: .utf8) }
    else { try? fm.removeItem(at: etat.appendingPathComponent(nom)) }
}
func razAppels() { etatFichier("calls.log", nil); etatFichier("started.json", nil) }
func appels(_ ev: String = "start") -> [[String: Any]] {
    guard let t = try? String(contentsOf: etat.appendingPathComponent("calls.log"), encoding: .utf8) else { return [] }
    return t.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        .filter { ($0["ev"] as? String) == ev }
}

func reglages(timeout: Double = 30, relances: [Double] = [0.05, 0.05], killGrace: Double = 0.3, pipeGrace: Double = 0.5)
    -> ClaudeCodeEngine.Tuning {
    var t = ClaudeCodeEngine.Tuning()
    t.callTimeout = timeout; t.statusTimeout = 5; t.loginTimeout = 10
    t.retryDelays = relances; t.killGrace = killGrace; t.pipeGrace = pipeGrace
    t.workRoot = travail
    return t
}
func moteur(_ modele: String = "", _ effort: String = "medium", _ t: ClaudeCodeEngine.Tuning? = nil) -> ClaudeCodeEngine {
    ClaudeCodeEngine(cli: faux, model: modele, effort: effort, tuning: t ?? reglages())
}

/// Joue un scénario d'erreur : le type d'erreur, des morceaux du message et le nombre d'appels du programme.
func erreurAttendue(_ nom: String, _ scn: String, appels attendus: Int, _ g: String, _ morceaux: String..., fatale: Bool? = nil,
                    moteur m: ClaudeCodeEngine? = nil) async {
    scenario(scn); razAppels()
    do {
        _ = try await (m ?? moteur()).complete(requete())
        verif(false, "\(nom) : une erreur était attendue")
    } catch let e as EngineError {
        verif(genre(e) == g && morceaux.allSatisfy { message(e).contains($0) }, "\(nom) : erreur \(g) avec le bon message", message(e))
        if let f = fatale { verif(e.isFatal == f, "\(nom) : \(f ? "fatale" : "non fatale")") }
    } catch {
        verif(false, "\(nom) : erreur inattendue", "\(error)")
    }
    verif(appels().count == attendus, "\(nom) : \(attendus) appel(s) du programme", "\(appels().count)")
}

// MARK: - Phase 1 : le vrai programme, sans rien consommer

func phase1() async {
    titre("Phase 1 — vrai programme Claude Code (seulement ce qui ne coûte rien)")
    guard let reel = ClaudeCodeEngine.locateCLI(override: nil) else { ignore("vrai programme", "Claude Code est introuvable sur ce Mac"); return }
    let avant = dossiersTemporairesDeLApp()
    let version = await ClaudeCodeEngine.version(of: reel)
    verif(version != nil && ClaudeCodeEngine.parseVersion(version ?? "") != nil, "--version répond avec un numéro", "\(version ?? "nil")")
    let etatReel = await ClaudeCodeEngine.status(cli: reel)
    switch etatReel {
    case .notLoggedIn: verif(true, "auth status : pas connecté (JSON loggedIn=false lu)")
    case .ready: verif(true, "auth status : connecté (\(etatReel.summary.isEmpty ? "?" : "compte lu"))")
    default: verif(false, "auth status lisible", etatReel.summary)
    }
    let raison = await ClaudeCodeEngine.unavailabilityReason(cliOverride: nil)
    verif((etatReel == .notLoggedIn) == (raison?.contains(ClaudeCodeEngine.loginButtonTitle) == true) || etatReel.isReady,
          "unavailabilityReason cohérent avec l'état", raison ?? "nil")
    if etatReel == .notLoggedIn {
        for (modele, effort) in [("", "medium"), ("sonnet", "low"), ("opus", "high"), ("haiku", "medium")] {
            var t = ClaudeCodeEngine.Tuning()
            t.callTimeout = 90; t.retryDelays = []
            let m = ClaudeCodeEngine(cli: reel, model: modele, effort: effort, tuning: t)
            do {
                _ = try await m.complete(requete())
                verif(false, "appel -p réel (\(modele.isEmpty ? "défaut" : modele)) : « Not logged in » attendu")
            } catch let e as EngineError {
                verif(est(e, "unavailable", "pas connecté") && e.isFatal,
                      "appel -p réel (\(modele.isEmpty ? "défaut" : modele)/\(effort)) → « Tu n'es pas connecté… » (fatale)", message(e))
            } catch { verif(false, "appel -p réel : erreur inattendue", "\(error)") }
        }
        do {
            var t = ClaudeCodeEngine.Tuning(); t.retryDelays = []
            _ = try await ClaudeCodeEngine(cli: reel, tuning: t).humanize(elements(2))
            verif(false, "humanize réel : « Not logged in » attendu")
        } catch let e as EngineError { verif(est(e, "unavailable", "pas connecté"), "humanize réel → pas connecté", message(e)) }
        catch { verif(false, "humanize réel : erreur inattendue", "\(error)") }
    } else if etatReel.isReady {
        ignore("appel -p réel", "le compte est connecté : un appel consommerait ton quota")
    }
    verif(dossiersTemporairesDeLApp() == avant, "aucun dossier temporaire laissé par la phase 1", "\(dossiersTemporairesDeLApp()) au lieu de \(avant)")
}

// MARK: - Phase 2 : le faux programme

func phase2() async {
    // Mise en place : faux HOME, faux programme, FAUSSES clés dans l'environnement du parent.
    try? fm.removeItem(at: racine)
    for d in [fauxHome, travail, faux.deletingLastPathComponent()] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    if let source = try? String(contentsOfFile: fauxSource, encoding: .utf8) { ecrire(source, faux, executable: true) }
    setenv("HOME", fauxHome.path, 1)
    let canaris = ["ANTHROPIC_API_KEY": "sk-ant-FAUX-NE-PAS-UTILISER-0000", "ANTHROPIC_AUTH_TOKEN": "faux-jeton", "ANTHROPIC_BASE_URL": "http://127.0.0.1:9",
                   "CLAUDE_CODE_OAUTH_TOKEN": "faux-oauth", "CLAUDE_CODE_ENTRYPOINT": "sdk-ts", "CLAUDECODE": "1", "CLAUDE_CODE_SIMPLE": "1"]
    for (k, v) in canaris { setenv(k, v, 1) }

    titre("Garde-fous de l'environnement")
    verif(canaris.keys.allSatisfy { ProcessInfo.processInfo.environment[$0] != nil }, "les fausses variables sont bien dans l'environnement du parent")
    do {   // contrôle négatif : lancé tel quel, le faux programme doit refuser
        let p = Process()
        p.executableURL = faux; p.arguments = ["--version"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        verif(p.terminationStatus == 97, "contrôle négatif : le faux programme refuse de tourner avec ces variables (code 97)", "\(p.terminationStatus)")
    } catch { verif(false, "contrôle négatif", "\(error)") }
    let base = ["HOME": "/h", "USER": "u", "LANG": "fr_FR.UTF-8", "TMPDIR": "/t/", "PATH": "/tmp/evil:/usr/bin", "ANTHROPIC_API_KEY": "x",
                "ANTHROPIC_BASE_URL": "y", "CLAUDE_CODE_OAUTH_TOKEN": "z", "CLAUDECODE": "1", "CLAUDE_CODE_SIMPLE": "1",
                "AWS_SECRET_ACCESS_KEY": "s", "HTTPS_PROXY": "http://proxy:3128", "GITHUB_TOKEN": "g"]
    let assaini = ClaudeCodeEngine.sanitizedEnvironment(base: base, cli: URL(fileURLWithPath: "/opt/homebrew/bin/claude"))
    verif(assaini["HOME"] == "/h" && assaini["USER"] == "u" && assaini["LANG"] == "fr_FR.UTF-8" && assaini["TMPDIR"] == "/t/",
          "HOME, USER, LANG, TMPDIR conservés")
    verif(!assaini.keys.contains { $0.hasPrefix("ANTHROPIC_") || $0.hasPrefix("CLAUDE_CODE_") || $0 == "CLAUDECODE" }, "ANTHROPIC_*, CLAUDE_CODE_*, CLAUDECODE supprimées")
    verif(assaini["AWS_SECRET_ACCESS_KEY"] == nil && assaini["GITHUB_TOKEN"] == nil, "les autres secrets ne passent pas non plus")
    verif(assaini["PATH"]?.contains("/tmp/evil") == false && assaini["PATH"]?.hasPrefix("/usr/bin:/bin") == true, "PATH sûr (le PATH de l'app est ignoré)", assaini["PATH"] ?? "")
    verif(assaini["HTTPS_PROXY"] == "http://proxy:3128", "proxy conservé (réseau d'école)")
    verif(ClaudeCodeEngine.cleanOption("opus") == "opus" && ClaudeCodeEngine.cleanOption("--evil") == "" && ClaudeCodeEngine.cleanOption("a b") == ""
          && ClaudeCodeEngine.cleanOption("") == "" && ClaudeCodeEngine.cleanOption("claude-opus-4-5") == "claude-opus-4-5", "options modèle/effort filtrées")
    let defauts = ClaudeCodeEngine.Tuning()
    verif(defauts.callTimeout == 300 && defauts.retryDelays.count == 2 && defauts.killGrace == 2, "réglages par défaut : 5 min, 2 relances, SIGKILL après 2 s")
    let m0 = moteur()
    verif(m0.displayName == "Claude (mon compte)" && m0.usesImages && m0.maxConcurrentPages == 2, "nom, images, 2 pages en parallèle")
    verif(ClaudeCodeEngine.models.map(\.id) == ["", "claude-opus-5-5", "opus", "sonnet", "haiku"] && ClaudeCodeEngine.defaultEffort == "high" && ClaudeCodeEngine.defaultModel == "claude-opus-5-5"
          && ClaudeCodeEngine.models.allSatisfy { !$0.label.isEmpty && !$0.hint.isEmpty }, "modèles : défaut du compte / Opus / Sonnet / Haiku, effort medium")

    // ---- Localisation du programme
    titre("Localisation du programme (dossiers simulés)")
    let home2 = racine.appendingPathComponent("home2")
    let appBase = "Library/Application Support/Claude/claude-code"
    func fabriquer(_ rel: String, _ version: String, dans home: URL, executable: Bool = true) -> URL {
        let u = home.appendingPathComponent(rel)
        ecrire("#!/bin/sh\necho \"\(version) (Claude Code)\"\n", u, executable: executable)
        return u
    }
    let v9 = fabriquer("\(appBase)/2.1.9/aaa/claude.app/Contents/MacOS/claude", "2.1.9", dans: home2)
    let v325 = fabriquer("\(appBase)/2.1.325/bbb/claude.app/Contents/MacOS/claude", "2.1.325", dans: home2)
    let v100 = fabriquer("\(appBase)/2.1.100/ccc/claude.app/Contents/MacOS/claude", "2.1.100", dans: home2)
    let v20 = fabriquer("\(appBase)/2.0.50/ddd/claude.app/Contents/MacOS/claude", "2.0.50", dans: home2)
    _ = fabriquer("\(appBase)/nimportequoi/eee/claude.app/Contents/MacOS/claude", "0.0.1", dans: home2)
    let local = fabriquer(".local/bin/claude", "9.9.9", dans: home2)
    let sysDir = racine.appendingPathComponent("usrlocal")
    let sys = fabriquer("claude", "8.8.8", dans: sysDir)
    let ancien = fabriquer(".claude/local/claude", "7.7.7", dans: home2)
    let cand = ClaudeCodeEngine.candidateCLIs(home: home2, systemBinDirs: [sysDir.path])
    verif(cand.map(\.path) == [v325, v100, v9, v20, local, sys, ancien].map(\.path), "ordre : versions décroissantes (2.1.325 avant 2.1.100 avant 2.1.9), puis ~/.local/bin, système, ~/.claude/local",
          cand.map { $0.path.replacingOccurrences(of: racine.path, with: "") }.joined(separator: " | "))
    verif(ClaudeCodeEngine.locateCLI(override: nil, home: home2, systemBinDirs: [sysDir.path])?.path == v325.path, "locateCLI : la version la plus haute")
    try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: v325.path)
    verif(ClaudeCodeEngine.locateCLI(override: nil, home: home2, systemBinDirs: [sysDir.path])?.path == v100.path, "un fichier non exécutable est écarté")
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: v325.path)
    verif(ClaudeCodeEngine.locateCLI(override: local.path, home: home2)?.path == local.path, "chemin imposé accepté")
    verif(ClaudeCodeEngine.locateCLI(override: "~/.local/bin/claude", home: home2)?.path == local.path, "chemin imposé avec ~")
    verif(ClaudeCodeEngine.locateCLI(override: "\"\(local.path)\" ", home: home2)?.path == local.path, "chemin imposé collé avec des guillemets")
    verif(ClaudeCodeEngine.locateCLI(override: home2.appendingPathComponent("nexiste/pas").path, home: home2) == nil, "chemin imposé inexistant : nil (pas de repli silencieux)")
    verif(ClaudeCodeEngine.locateCLI(override: home2.appendingPathComponent("\(appBase)/2.1.100/ccc/claude.app").path, home: home2)?.path == v100.path, "chemin imposé = dossier .app")
    verif(ClaudeCodeEngine.locateCLI(override: local.deletingLastPathComponent().path, home: home2)?.path == local.path, "chemin imposé = dossier contenant claude")
    verif(ClaudeCodeEngine.locateCLI(override: nil, home: racine.appendingPathComponent("vide"), systemBinDirs: []) == nil, "aucun programme : nil")
    let home3 = racine.appendingPathComponent("home3")
    ecrire("#!/bin/sh\nexit 1\n", home3.appendingPathComponent("\(appBase)/3.0.0/zzz/claude.app/Contents/MacOS/claude"), executable: true)
    ecrire("#!/bin/sh\necho bonjour\n", home3.appendingPathComponent("\(appBase)/2.9.5/yyy/claude.app/Contents/MacOS/claude"), executable: true)
    _ = fabriquer("\(appBase)/2.9.0/xxx/claude.app/Contents/MacOS/claude", "2.9.0", dans: home3)
    var tc = reglages(); tc.statusTimeout = 5
    let travailleur = await ClaudeCodeEngine.locateWorkingCLI(override: nil, home: home3, systemBinDirs: [], tuning: tc)
    verif(travailleur?.version == "2.9.0", "locateWorkingCLI saute les programmes qui ne répondent pas à --version", "\(travailleur?.version ?? "nil")")
    verif(await ClaudeCodeEngine.version(of: v325, tuning: tc) == "2.1.325", "version(of:) lit le numéro")

    // ---- État du compte, connexion
    titre("Compte : auth status, unavailabilityReason, connexion")
    etatFichier("logged_in", nil); etatFichier("status_mode", nil)
    verif(await ClaudeCodeEngine.version(of: faux, tuning: tc) == "2.1.999", "faux programme : --version (avec les fausses clés dans l'environnement du parent)")
    verif(await ClaudeCodeEngine.status(cli: faux, tuning: tc) == .notLoggedIn, "auth status loggedIn=false (code de sortie 1) → pas connecté")
    etatFichier("logged_in", "1")
    let connecte = await ClaudeCodeEngine.status(cli: faux, tuning: tc)
    verif(connecte == .ready(account: "eleve@example.com (abonnement Pro)"), "auth status connecté → prêt avec e-mail et abonnement", connecte.summary)
    etatFichier("status_mode", "garbage")
    if case .problem = await ClaudeCodeEngine.status(cli: faux, tuning: tc) { verif(true, "sortie illisible → problème") } else { verif(false, "sortie illisible → problème") }
    etatFichier("status_mode", "apikey")
    if case .problem(let m) = await ClaudeCodeEngine.status(cli: faux, tuning: tc) { verif(m.contains("clé API"), "connexion par clé API signalée (facturation à l'usage)") } else { verif(false, "clé API signalée") }
    etatFichier("status_mode", "hang")
    var tcc = tc; tcc.statusTimeout = 0.6; tcc.killGrace = 0.2
    let t0 = Date()
    if case .problem = await ClaudeCodeEngine.status(cli: faux, tuning: tcc) { verif(Date().timeIntervalSince(t0) < 5, "auth status qui ne répond pas → problème après le délai") } else { verif(false, "auth status muet → problème") }
    etatFichier("status_mode", nil)
    verif(await ClaudeCodeEngine.status(cli: racine.appendingPathComponent("nexiste-pas"), tuning: tc) == .absent, "programme inexistant → absent")
    verif(await ClaudeCodeEngine.status(cli: home2.appendingPathComponent("\(appBase)/2.1.9"), tuning: tc) == .absent, "un dossier n'est pas un programme → absent")
    etatFichier("logged_in", nil)
    let r1 = await ClaudeCodeEngine.unavailabilityReason(cliOverride: nil, home: racine.appendingPathComponent("vide"), systemBinDirs: [], tuning: tc)
    verif(r1 == ClaudeCodeEngine.missingMessage && r1?.contains("introuvable") == true, "raison : Claude Code introuvable", r1 ?? "nil")
    let r2 = await ClaudeCodeEngine.unavailabilityReason(cliOverride: faux.path, tuning: tc)
    verif(r2?.contains("Tu n'es pas connecté") == true && r2?.contains("Me connecter") == true, "raison : pas connecté, clique sur « Me connecter »", r2 ?? "nil")
    let r3 = await ClaudeCodeEngine.unavailabilityReason(cliOverride: racine.appendingPathComponent("nexiste-pas").path, tuning: tc)
    verif(r3?.contains("indiqué") == true, "raison : chemin imposé invalide", r3 ?? "nil")
    etatFichier("logged_in", "1")
    verif(await ClaudeCodeEngine.unavailabilityReason(cliOverride: faux.path, tuning: tc) == nil, "raison : nil quand tout est prêt")
    etatFichier("logged_in", nil)

    etatFichier("login_mode", "ok")
    do {
        try await ClaudeCodeEngine.login(cli: faux, tuning: tc)
        verif(await ClaudeCodeEngine.status(cli: faux, tuning: tc).isReady, "login : `auth login --claudeai` lancé (arguments exacts vérifiés), puis connecté")
    } catch { verif(false, "login réussi", "\(error)") }
    etatFichier("logged_in", nil); etatFichier("login_mode", "fail")
    do { try await ClaudeCodeEngine.login(cli: faux, tuning: tc); verif(false, "login en échec : erreur attendue") }
    catch let e as EngineError { verif(est(e, "unavailable", "Terminal", "auth login") && !message(e).contains("SECRET"), "login en échec → message avec la commande du Terminal, sans rien de la sortie du programme", message(e)) }
    catch { verif(false, "login en échec", "\(error)") }
    etatFichier("login_mode", "noeffect")
    do { try await ClaudeCodeEngine.login(cli: faux, tuning: tc); verif(false, "login sans effet : erreur attendue") }
    catch let e as EngineError { verif(est(e, "unavailable", "pas terminée"), "login terminé mais toujours pas connecté → erreur claire", message(e)) }
    catch { verif(false, "login sans effet", "\(error)") }
    etatFichier("login_mode", "hang")
    var tl = tc; tl.loginTimeout = 0.6; tl.killGrace = 0.2
    do { try await ClaudeCodeEngine.login(cli: faux, tuning: tl); verif(false, "login trop long : erreur attendue") }
    catch let e as EngineError { verif(est(e, "unavailable", "à temps"), "login trop long → arrêté, message clair", message(e)) }
    catch { verif(false, "login trop long", "\(error)") }
    etatFichier("login_mode", nil)
    verif(ClaudeCodeEngine.terminalLoginCommand(cli: URL(fileURLWithPath: "/a b/it's/claude")) == "'/a b/it'\\''s/claude' auth login", "commande du Terminal correctement protégée")

    // ---- Succès
    titre("Complétion et humanisation : succès")
    scenario("ok"); razAppels()
    do {
        let rep = try await moteur().complete(requete(zones: 4, image: 5_000))
        verif(rep.map(\.number) == [1, 2, 3, 4] && rep.map(\.kind) == [.mot, .definition, .question, .ignorer], "complete : numéros et types décodés")
        verif(rep[0].text == "réponse 1" && rep[3].text.isEmpty, "complete : textes décodés (ignorer = vide)")
        let msg = appels("message")
        verif(appels().count == 1 && msg.count == 1 && (msg[0]["blocks"] as? [String]) == ["image", "text"] && (msg[0]["newlines"] as? Int) == 1,
              "stdin : une seule ligne JSON, l'image avant le texte")
    } catch { verif(false, "complete (ok)", "\(error)") }
    razAppels()
    do {
        _ = try await moteur().complete(requete(zones: 2, image: nil))
        verif((appels("message").first?["blocks"] as? [String]) == ["text"], "sans image : texte seul")
    } catch { verif(false, "complete sans image", "\(error)") }
    razAppels()
    do {
        let rep = try await moteur().humanize(elements(3))
        verif(rep == [11: "Retouché : Réponse 1", 12: "Retouché : Réponse 2", 13: "Retouché : Réponse 3"], "humanize : réponses retouchées par id", "\(rep)")
        verif(appels().count == 1 && (appels("message").first?["blocks"] as? [String]) == ["text"], "humanize : texte seul, un appel")
    } catch { verif(false, "humanize (ok)", "\(error)") }
    razAppels()
    do {
        let rep = try await moteur().humanize(elements(20))
        verif(rep.count == 20 && appels().count == 2, "humanize : 20 réponses en 2 appels (paquets de 15)", "\(rep.count) réponses, \(appels().count) appels")
    } catch { verif(false, "humanize 20", "\(error)") }
    razAppels()
    let vide = (try? await moteur().humanize([])) ?? [99: ""]
    var zonesVides = requete(); zonesVides.zones = []
    let repVide = (try? await moteur().complete(zonesVides)) ?? [ZoneAnswer(number: 0, kind: .mot, text: "")]
    verif(vide.isEmpty && repVide.isEmpty && appels().isEmpty, "rien à faire : aucun programme lancé")

    titre("Options transmises (modèle, effort)")
    for (modele, effort, attenduModele, attenduEffort) in [("opus", "high", "opus", "high"), ("", "medium", nil, "medium"), ("haiku", "medium", "haiku", nil),
                                                           ("--evil", "x y", nil, nil), ("sonnet", "low", "sonnet", "low")] as [(String, String, String?, String?)] {
        scenario("ok"); razAppels()
        _ = try? await moteur(modele, effort).complete(requete(zones: 1))
        let a = appels().first
        verif((a?["model"] as? String) == attenduModele && (a?["effort"] as? String) == attenduEffort,
              "modèle « \(modele) » effort « \(effort) » → --model \(attenduModele ?? "(absent)"), --effort \(attenduEffort ?? "(absent)")", "\(String(describing: a))")
    }
    scenario("ok")
    do {
        let texte = try await moteur().generate(system: "Système de test", content: [["type": "text", "text": "[{\"id\": 7, \"reponse\": \"abc\"}]"]],
                                                schema: ["type": "object", "properties": ["reponses": ["type": "array"]], "required": ["reponses"]])
        let obj = (try? JSONSerialization.jsonObject(with: Data(texte.utf8))) as? [String: Any]
        let r0 = (obj?["reponses"] as? [[String: Any]])?.first
        verif((r0?["id"] as? Int) == 7 && (r0?["texte"] as? String) == "Retouché : abc", "generate : renvoie le JSON texte de la réponse structurée", texte)
    } catch { verif(false, "generate", "\(error)") }
    scenario("ok"); razAppels()
    do {   // protocole StructuredGenerator du mode Révision (images + texte, image vide ignorée)
        let comme: CompletionEngine = moteur()
        let gen = comme as? StructuredGenerator
        let texte = try await gen?.generate(system: "S", userText: "[{\"id\": 3, \"reponse\": \"zz\"}]", images: [image(100), Data(), image(200)],
                                            schema: ["type": "object"]) ?? ""
        let obj = (try? JSONSerialization.jsonObject(with: Data(texte.utf8))) as? [String: Any]
        let r0 = (obj?["reponses"] as? [[String: Any]])?.first
        verif(gen?.supportsImages == true && (appels("message").first?["blocks"] as? [String]) == ["image", "image", "text"] && (r0?["id"] as? Int) == 3,
              "StructuredGenerator (mode Révision) : le moteur s'y conforme, images puis texte", texte)
    } catch { verif(false, "StructuredGenerator", "\(error)") }
    verif(ClaudeCodeEngine.Tuning().generateTimeout == 600, "mode Révision : délai de 10 minutes par appel")
    scenario("limit")
    do { _ = try await moteur().generate(system: "S", content: [["type": "text", "text": "x"]], schema: ["type": "object"]); verif(false, "generate sous limite : erreur attendue") }
    catch let e as EngineError { verif(est(e, "unavailable", "limite") && e.isFatal, "generate : mêmes garde-fous (limite → erreur fatale)") }
    catch { verif(false, "generate sous limite", "\(error)") }

    // ---- Formats de réponse
    titre("Formats de réponse tolérés")
    for (scn, nom) in [("fence", "result en JSON dans des barrières ```"), ("prose", "result en JSON entouré de texte")] {
        scenario(scn); razAppels()
        do { let rep = try await moteur().complete(requete(zones: 2)); verif(rep.count == 2 && rep[0].text == "réponse 1", "structured_output absent, \(nom) → lu") }
        catch { verif(false, nom, "\(error)") }
    }
    await erreurAttendue("JSON mal formé", "badjson", appels: 1, "invalid", "format demandé", fatale: false)
    await erreurAttendue("JSON valide mais mauvaise forme", "badshape", appels: 1, "invalid", fatale: false)
    await erreurAttendue("échec du format structuré (subtype d'erreur)", "structfail", appels: 1, "invalid", "format demandé", fatale: false)
    await erreurAttendue("refus", "refusal", appels: 1, "refused", "refusé", fatale: false)
    await erreurAttendue("page trop grosse", "toolong", appels: 1, "invalid", "trop volumineuse", fatale: false)

    // ---- Erreurs de compte
    titre("Erreurs : connexion, limite, version")
    await erreurAttendue("pas connecté (1,3 Mo sur stdin, le programme ne les lit pas)", "notlogged", appels: 1, "unavailable", "Tu n'es pas connecté à ton compte Claude", "Me connecter", fatale: true,
                         moteur: moteur())
    scenario("notlogged"); razAppels()
    do { _ = try await moteur().complete(requete(zones: 2, image: 1_000_000)); verif(false, "pas connecté + gros stdin : erreur attendue") }
    catch let e as EngineError { verif(est(e, "unavailable", "pas connecté") && appels().count == 1, "écrire dans un programme déjà parti (EPIPE) ne plante pas l'app et ne relance pas", message(e)) }
    catch { verif(false, "pas connecté + gros stdin", "\(error)") }
    await erreurAttendue("limite d'abonnement avec heure", "limit", appels: 1, "unavailable", "limite de ton abonnement Claude", "Elle se renouvelle", fatale: true)
    scenario("limit")
    if let e = try? await { () async throws -> EngineError? in do { _ = try await moteur().complete(requete()); return nil } catch let e as EngineError { return e } }() {
        verif(message(e).range(of: #"\d{2}:\d{2}"#, options: .regularExpression) != nil, "limite : l'heure HH:MM de remise à zéro est dans le message", message(e))
    } else { verif(false, "limite : message") }
    await erreurAttendue("limite (horodatage Unix après |)", "limit_epoch", appels: 1, "unavailable", "limite de ton abonnement", "vers", fatale: true)
    await erreurAttendue("limite sans heure", "limit_plain", appels: 1, "unavailable", "limite de ton abonnement", "d'ici quelques heures", fatale: true)
    await erreurAttendue("version de Claude Code trop ancienne", "oldcli", appels: 1, "unavailable", "--safe-mode", "Mets à jour", fatale: true)
    await erreurAttendue("programme qui ne peut pas démarrer (127)", "exit127", appels: 1, "unavailable", "ne peut pas être lancé", fatale: true)
    await erreurAttendue("erreur inconnue (texte nettoyé)", "weird", appels: 1, "other", "Quelque chose d'inattendu", fatale: false)
    scenario("weird")
    if let e = try? await { () async throws -> EngineError? in do { _ = try await moteur().complete(requete()); return nil } catch let e as EngineError { return e } }() {
        verif(!message(e).contains("sk-ant-abcdef") && !message(e).contains("quelquun"), "erreur inconnue : ni clé ni nom d'utilisateur dans le message", message(e))
    } else { verif(false, "erreur inconnue : message") }

    // ---- Pannes passagères
    titre("Pannes passagères : relances (2 au plus, attente progressive)")
    await erreurAttendue("surcharge (529)", "overloaded", appels: 3, "network", "surchargé", fatale: false)
    await erreurAttendue("plantage sans ligne result", "crash", appels: 3, "network", "sans donner de réponse", fatale: false)
    await erreurAttendue("programme tué par un signal", "crash_signal", appels: 3, "network", fatale: false)
    await erreurAttendue("sortie vide", "empty", appels: 3, "network", fatale: false)
    await erreurAttendue("sortie coupée au milieu d'une ligne", "truncated", appels: 3, "network", fatale: false)
    scenario("flaky"); razAppels()
    do { let rep = try await moteur().complete(requete(zones: 2)); verif(rep.count == 2 && appels().count == 2, "panne puis succès : réussi au 2e essai", "\(appels().count) appels") }
    catch { verif(false, "relance puis succès", "\(error)") }
    scenario("overloaded"); razAppels()
    let debut = Date()
    _ = try? await moteur("", "medium", reglages(relances: [0.4, 0.8])).complete(requete())
    verif(Date().timeIntervalSince(debut) >= 1.2 && appels().count == 3, "l'attente entre relances est respectée (0,4 s puis 0,8 s)", "\(Date().timeIntervalSince(debut)) s")

    // ---- Débit, délai, annulation
    titre("Sorties volumineuses, délai maximal, annulation")
    scenario("bigout"); razAppels()
    do {
        let d0 = Date()
        let rep = try await moteur().complete(requete(zones: 2, image: 400_000))
        verif(rep.count == 2, "6 Mo en sortie avant de lire stdin : pas d'inter-blocage", String(format: "%.1f s", Date().timeIntervalSince(d0)))
    } catch { verif(false, "sortie volumineuse", "\(error)") }

    scenario("hang"); razAppels()
    let dt0 = Date()
    do { _ = try await moteur("", "medium", reglages(timeout: 0.8)).complete(requete()); verif(false, "délai : erreur attendue") }
    catch let e as EngineError {
        let dt = Date().timeIntervalSince(dt0)
        verif(est(e, "network", "délai prévu") && !e.isFatal, "délai dépassé → erreur réseau claire", message(e))
        verif(appels().count == 1 && dt < 6, "délai dépassé : pas de relance, arrêt rapide", String(format: "%d appels, %.1f s", appels().count, dt))
        if let pid = (try? JSONSerialization.jsonObject(with: Data(contentsOf: etat.appendingPathComponent("started.json"))) as? [String: Any])?["pid"] as? Int {
            verif(!vivant(Int32(pid)), "délai dépassé : le programme est bien arrêté")
        } else { verif(false, "started.json lisible") }
    } catch { verif(false, "délai", "\(error)") }

    for (scn, grace, attenteMin) in [("hang_child", 0.3, 0.0), ("ignore_term", 0.5, 0.4)] {
        scenario(scn); razAppels()
        let eng = moteur("", "medium", reglages(timeout: 60, killGrace: grace))
        let tache = Task { try await eng.complete(requete()) }
        let demarre = await attendre(10) { fm.fileExists(atPath: etat.appendingPathComponent("started.json").path) }
        verif(demarre, "annulation (\(scn)) : le faux programme est démarré")
        let info = (try? JSONSerialization.jsonObject(with: Data(contentsOf: etat.appendingPathComponent("started.json"))) as? [String: Any]) ?? [:]
        let pid = Int32(info["pid"] as? Int ?? 0), enfant = Int32(info["child"] as? Int ?? 0)
        verif(pid > 0 && vivant(pid) && enfant > 0 && vivant(enfant), "annulation (\(scn)) : le programme et son sous-processus tournent")
        let c0 = Date()
        tache.cancel()
        let res = await tache.result
        let dt = Date().timeIntervalSince(c0)
        if case .failure(let e) = res, e is CancellationError { verif(true, "annulation (\(scn)) : CancellationError") }
        else { verif(false, "annulation (\(scn)) : CancellationError attendue", "\(res)") }
        verif(dt < 5 && dt >= attenteMin, "annulation (\(scn)) : arrêt en \(String(format: "%.2f", dt)) s" + (attenteMin > 0 ? " (SIGTERM ignoré → SIGKILL après le délai)" : ""))
        verif(!vivant(pid) && !vivant(enfant), "annulation (\(scn)) : plus aucun processus (ni le programme, ni son sous-processus)")
        verif(appels().count == 1, "annulation (\(scn)) : pas de relance")
    }
    do {   // réponse normale, mais un sous-processus garde les tubes ouverts et reste vivant
        scenario("orphan"); razAppels()
        let o0 = Date()
        do {
            let rep = try await moteur().complete(requete(zones: 2))
            let dt = Date().timeIntervalSince(o0)
            let info = (try? JSONSerialization.jsonObject(with: Data(contentsOf: etat.appendingPathComponent("started.json"))) as? [String: Any]) ?? [:]
            let enfant = Int32(info["child"] as? Int ?? 0)
            verif(rep.count == 2 && dt < 6, "sous-processus qui garde les tubes : la réponse arrive quand même (sans attendre indéfiniment)", String(format: "%.1f s", dt))
            var mort = false
            if enfant > 0 { mort = await attendre(3) { !vivant(enfant) } }
            verif(mort, "sous-processus resté vivant après la fin de l'appel : arrêté (aucun orphelin)")
        } catch { verif(false, "sous-processus orphelin", "\(error)") }
    }
    do {   // annulée avant même de démarrer
        scenario("ok"); razAppels()
        let eng = moteur()
        let tache = Task { () -> Int in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            return try await eng.complete(requete()).count
        }
        tache.cancel()
        let res = await tache.result
        if case .failure(let e) = res, e is CancellationError { verif(appels().isEmpty, "Task déjà annulée : CancellationError, aucun programme lancé") }
        else { verif(false, "Task déjà annulée", "\(res)") }
    }

    titre("Deux appels en parallèle")
    scenario("slow"); razAppels()
    do {
        let eng = moteur()
        let t0 = Date()
        async let a = eng.complete(requete(zones: 2))
        async let b = eng.humanize(elements(2))
        let (ra, rb) = try await (a, b)
        let starts = appels().compactMap { $0["t"] as? Double }, ends = appels("end").compactMap { $0["t"] as? Double }
        verif(ra.count == 2 && rb.count == 2, "les deux réponses sont correctes")
        verif(starts.count == 2 && ends.count == 2 && (starts.max() ?? 1) < (ends.min() ?? 0), "les deux programmes ont tourné en même temps",
              String(format: "%.1f s au total", Date().timeIntervalSince(t0)))
    } catch { verif(false, "appels en parallèle", "\(error)") }

    // ---- Nettoyage
    titre("Nettoyage : dossiers temporaires, tubes, processus")
    let nbFichiers = ((try? fm.contentsOfDirectory(atPath: travail.path)) ?? []).count
    verif(nbFichiers == 0, "aucun dossier de travail laissé (succès, erreurs, délai, annulation)", "\(nbFichiers) restant(s)")
    scenario("ok")
    _ = try? await moteur().complete(requete())
    try? await Task.sleep(nanoseconds: 300_000_000)
    let fd0 = nbDescripteurs()
    for scn in ["ok", "crash", "notlogged", "limit", "ok", "hang"] {
        scenario(scn)
        _ = try? await moteur("", "medium", reglages(timeout: scn == "hang" ? 0.5 : 30)).complete(requete(zones: 2, image: scn == "notlogged" ? 300_000 : 2_000))
    }
    scenario("hang_child")
    let tache = Task { try await moteur("", "medium", reglages(timeout: 60)).complete(requete()) }
    _ = await attendre(10) { fm.fileExists(atPath: etat.appendingPathComponent("started.json").path) }
    tache.cancel(); _ = await tache.result
    try? await Task.sleep(nanoseconds: 500_000_000)
    let fd1 = nbDescripteurs()
    verif(fd0 > 0 && fd1 == fd0, "aucun tube ni descripteur de fichier ne fuit (11 appels de tous types)", "avant \(fd0), après \(fd1)")
    verif(((try? fm.contentsOfDirectory(atPath: travail.path)) ?? []).isEmpty, "dossiers de travail tous supprimés")
}

// MARK: - Fonctions pures

func phase3() {
    titre("Lecture de la sortie (parseStream), tolérance")
    let lignes = """
    {"type":"system","subtype":"init","tools":["StructuredOutput"]}

    {"type":"stream_event","event":{}}
    texte qui n'est pas du JSON
    {"type":"inconnu_du_futur","x":1}
    {"type":"result","subtype":"success","is_error":false,"result":"premier","structured_output":{"zones":[]}}\r
    {"type":"assistant","error":"rate_limit","message":{}}
    {"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","api_error_status":null,"stop_reason":"stop_sequence"}
    {"type":"result","subtype":"succ
    """
    let p = ClaudeCodeEngine.parseStream(Data(lignes.utf8))
    verif(p.result?.isError == true && p.result?.text == "Not logged in · Please run /login" && p.result?.apiStatus == nil, "types inconnus et lignes vides ignorés, dernière ligne result retenue")
    verif(p.assistantError == "rate_limit" && p.plainText.contains("texte qui n'est pas du JSON") && p.plainText.contains("succ"), "erreur de la ligne assistant gardée ; texte brut et ligne coupée mis à part")
    verif(ClaudeCodeEngine.parseStream(Data()).result == nil && ClaudeCodeEngine.parseStream(Data("{\"type\":\"system\"}\n".utf8)).result == nil, "sortie vide ou sans result : pas de résultat")
    let struct1 = ClaudeCodeEngine.parseStream(Data("{\"type\":\"result\",\"is_error\":false,\"structured_output\":\"{\\\"zones\\\":[]}\"}".utf8)).result
    verif(struct1.flatMap { ClaudeCodeEngine.structuredText(from: $0) } == "{\"zones\":[]}", "structured_output donné sous forme de chaîne JSON")
    let struct2 = ClaudeCodeEngine.parseStream(Data("{\"type\":\"result\",\"is_error\":false,\"structured_output\":null,\"result\":\"```json\\n{\\\"a\\\":1}\\n```\"}".utf8)).result
    verif(struct2.flatMap { ClaudeCodeEngine.structuredText(from: $0) } == "{\"a\":1}", "structured_output null : result lu comme JSON (barrières retirées)")
    verif(ClaudeCodeEngine.jsonText(from: "blabla") == nil && ClaudeCodeEngine.jsonText(from: "") == nil && ClaudeCodeEngine.jsonText(from: "Ok: {\"a\": [1,2]} fin") == "{\"a\": [1,2]}", "jsonText : texte non JSON refusé, accolades extraites")

    titre("auth status : lecture du JSON (parseStatus)")
    func st(_ s: String, _ code: Int32 = 0) -> ClaudeCodeEngine.Status { ClaudeCodeEngine.parseStatus(stdout: Data(s.utf8), exitCode: code) }
    verif(st(#"{"loggedIn":true,"authMethod":"claude.ai","email":"a@b.fr","subscriptionType":"max"}"#) == .ready(account: "a@b.fr (abonnement Max)"), "e-mail + abonnement")
    verif(st(#"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"pro"}"#) == .ready(account: "abonnement Pro"), "abonnement seul")
    verif(st(#"{"loggedIn":true,"authMethod":"claude.ai"}"#) == .ready(account: nil), "connecté sans détail")
    verif(st(#"{"loggedIn":false,"authMethod":"none"}"#, 1) == .notLoggedIn, "loggedIn=false")
    verif(st("Not logged in. Run claude auth login to authenticate.", 1) == .notLoggedIn, "texte « Not logged in » sans JSON")
    if case .problem = st("???") { verif(true, "sortie illisible → problème") } else { verif(false, "sortie illisible → problème") }

    titre("Heure de remise à zéro de la limite (resetPhrase)")
    let paris = TimeZone(identifier: "Europe/Paris")!
    var cal = Calendar(identifier: .gregorian); cal.timeZone = paris
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date { cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))! }
    let maintenant = date(2026, 11, 18, 10, 0)
    func rp(_ s: String) -> String? { ClaudeCodeEngine.resetPhrase(from: s, now: maintenant, timeZone: paris) }
    verif(rp("5-hour limit reached ∙ resets 3pm (Europe/Paris)") == "vers 15:00", "resets 3pm (Europe/Paris) → vers 15:00", rp("5-hour limit reached ∙ resets 3pm (Europe/Paris)") ?? "nil")
    verif(rp("limit reached ∙ resets 3pm (America/New_York)") == "vers 21:00", "autre fuseau converti (New York 15:00 → Paris 21:00)", rp("limit reached ∙ resets 3pm (America/New_York)") ?? "nil")
    verif(rp("You've hit your limit · resets 9am") == "demain vers 09:00", "heure déjà passée aujourd'hui → demain")
    verif(rp("resets 11:30pm") == "vers 23:30" && rp("resets 12pm") == "vers 12:00" && rp("resets 12am") == "demain vers 00:00", "11:30pm, 12pm, 12am")
    verif(rp("reset at 15:30") == "vers 15:30", "reset at 15:30 (24 h)")
    verif(rp("Weekly limit reached ∙ resets Nov 25, 12pm") == "le 25 novembre vers 12:00", "date + heure → « le 25 novembre vers 12:00 »", rp("Weekly limit reached ∙ resets Nov 25, 12pm") ?? "nil")
    verif(rp("Claude AI usage limit reached|\(Int(date(2026, 11, 18, 14, 5).timeIntervalSince1970))") == "vers 14:05", "horodatage Unix après |")
    verif(rp("Claude AI usage limit reached|\(Int(date(2026, 11, 18, 8, 5).timeIntervalSince1970))") == nil, "horodatage passé → pas d'heure")
    verif(rp("limit resets in 2h 30m") == "vers 12:30", "resets in 2h 30m")
    verif(rp("You've hit your limit") == nil && rp("resets 3") == nil && rp("") == nil, "pas d'heure dans le message → nil")

    titre("Reconnaissance des erreurs (classify)")
    typealias C = ClaudeCodeEngine
    func cl(_ t: String, code: String? = nil, status: Int? = nil, sub: String = "") -> (error: EngineError, retry: Bool)? {
        C.classify(text: t, assistantError: code, apiStatus: status, subtype: sub, stopReason: nil)
    }
    verif(cl("Invalid API key · Please run /login").map { est($0.error, "unavailable", "pas connecté") && !$0.retry } == true, "Invalid API key → connexion, sans relance")
    verif(cl("", status: 401).map { est($0.error, "unavailable", "pas connecté") } == true, "statut 401 → connexion")
    verif(cl("Context limit reached ∙ /compact or /clear to continue").map { est($0.error, "invalid", "trop volumineuse") } == true, "« Context limit reached » n'est PAS la limite d'abonnement")
    verif(cl("Opus weekly limit reached ∙ resets Oct 9, 12pm").map { est($0.error, "unavailable", "limite de ton abonnement") && !$0.retry } == true, "limite hebdomadaire Opus")
    verif(cl("", code: "rate_limit").map { est($0.error, "unavailable", "limite") } == true, "erreur assistant rate_limit → limite")
    verif(cl("API Error: 500 Internal Server Error").map { est($0.error, "network") && $0.retry } == true, "500 → réseau, avec relance")
    verif(cl("API Error: Unable to connect to API (ECONNRESET)").map { est($0.error, "network") && $0.retry } == true, "ECONNRESET → réseau, avec relance")
    verif(cl("Your credit balance is too low").map { est($0.error, "unavailable", "abonnement ou de paiement") } == true, "facturation")
    verif(cl("error: unknown option '--permission-prompts'").map { est($0.error, "unavailable", "--permission-prompts") } == true, "option inconnue → version trop ancienne")
    verif(cl("Quelque chose d'imprévu") == nil, "cause inconnue → nil (l'appelant produit une erreur générique)")
    verif(C.scrub("clé sk-ant-api03-abcdefghijkl dans /Users/jean/doc  et\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") == "clé … dans /Users/…/doc et …", "scrub : clés, noms d'utilisateur, espaces", C.scrub("clé sk-ant-api03-abcdefghijkl dans /Users/jean/doc  et\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
    verif(C.parseVersion("2.1.325") == [2, 1, 325] && C.isNewer([2, 1, 325], than: [2, 1, 9]) && !C.isNewer([2, 1], than: [2, 1, 0]) && C.parseVersion("abc") == nil, "comparaison de versions nombre par nombre")

    titre("Fichier du moteur : enveloppe COMPTE_PERSO, rien de journalisé, aucune donnée personnelle")
    let source = (try? String(contentsOf: racineProjet.appendingPathComponent("Sources/Core/ClaudeCodeEngine.swift"), encoding: .utf8)) ?? ""
    verif(!source.isEmpty, "fichier du moteur lu")
    let utiles = source.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("//") }
    verif(utiles.first == "#if COMPTE_PERSO" && utiles.last == "#endif", "tout le code est entre « #if COMPTE_PERSO » et « #endif »")
    verif(source.hasPrefix("// ====") && source.prefix(1500).contains("COMPTE_PERSO") && source.prefix(1500).lowercased().contains("règles d'anthropic"), "commentaire d'en-tête qui explique pourquoi")
    let interdits = ["print(", "NSLog", "os_log", "Logger(", "debugPrint", "dump(", "FileHandle.standardError", "OSLog"]
    verif(!interdits.contains { source.contains($0) }, "aucun print / NSLog / journal dans le moteur", interdits.filter { source.contains($0) }.joined(separator: ", "))
    verif(!source.contains("maelehuidoux") && !source.contains("sk-ant-") && !source.contains("/Users/maelehuidoux"), "aucune donnée personnelle ni clé dans le moteur")
}

// MARK: - Programme principal

await phase1()
await phase2()
phase3()
if nbEchecs == 0 { try? fm.removeItem(at: racine) } else { print("\n(dossier de test conservé pour l'analyse : \(racine.path))") }
print("\n== Résultat : \(nbReussis) réussite(s), \(nbEchecs) échec(s), \(nbIgnores) ignoré(s)")
exit(nbEchecs == 0 ? 0 : 1)

#else

FileHandle.standardError.write(Data("Ces tests se compilent avec -D COMPTE_PERSO (voir run.sh).\n".utf8))
exit(2)

#endif
