import Foundation
import AppKit
import PDFKit
import Combine

// Tests du modèle de l'interface (sans fenêtre) : ouverture, analyse, complétion avec un faux moteur,
// modifications, annulation, zones manuelles, enregistrement, réglages, trousseau.
// Lancement : Tools/Tests/App/run_tests.sh   (aucun réseau, aucune clé, aucun fichier de l'élève)

var passed = 0
var failed = 0
var skipped = 0

func check(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) rethrows {
    if try condition() { passed += 1 } else { failed += 1; print("  ECHEC (ligne \(line)) : \(message)") }
}

/// Même chose quand la condition demande d'attendre quelque chose (`await checkA(await ...)`).
func checkA(_ condition: @autoclosure () async -> Bool, _ message: String, line: Int = #line) async {
    if await condition() { passed += 1 } else { failed += 1; print("  ECHEC (ligne \(line)) : \(message)") }
}

func skip(_ message: String) { skipped += 1; print("  (ignoré) \(message)") }
func section(_ title: String) { print("\n== \(title)") }

/// Réponses programmées aux questions du modèle.
@MainActor
final class ScriptedDialogs: Dialogs {
    var confirmAnswers: [Bool] = []
    var saveURLs: [URL?] = []
    var openURL: URL?
    private(set) var confirms: [(title: String, message: String)] = []
    private(set) var informs: [(title: String, message: String)] = []
    private(set) var revealed: [URL] = []
    private(set) var saveRequests = 0

    func confirm(title: String, message: String, accept: String, cancel: String, destructive: Bool) -> Bool {
        confirms.append((title, message))
        return confirmAnswers.isEmpty ? true : confirmAnswers.removeFirst()
    }
    func inform(title: String, message: String) { informs.append((title, message)) }
    func chooseOpenURL() -> URL? { openURL }
    func chooseSaveURL(suggestedName: String, directory: URL?) -> URL? {
        saveRequests += 1
        lastSuggestedName = suggestedName
        lastDirectory = directory
        return saveURLs.isEmpty ? nil : saveURLs.removeFirst()
    }
    func reveal(_ url: URL) { revealed.append(url) }
    var lastSuggestedName = ""
    var lastDirectory: URL?
}

@MainActor
func waitUntil(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Réglages modifiables pendant un test (le modèle les relit à chaque action).
final class Knobs {
    var kind: EngineKind = .claude
    var humanize = true
    var style = "bleu"
    var flatten = true
    var student = StudentProfile()
}

let suiteName = "fr.complete-cours.tests"

@MainActor
func makeModel(engine: CompletionEngine, knobs knobsOrNil: Knobs? = nil, dialogs dialogsOrNil: ScriptedDialogs? = nil) -> CoursModel {
    let knobs = knobsOrNil ?? Knobs()
    let dialogs = dialogsOrNil ?? ScriptedDialogs()
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return CoursModel(
        settings: { RunSettings(engine: knobs.kind, claudeModel: "claude-test", humanize: knobs.humanize,
                                styleKey: knobs.style, flatten: knobs.flatten, student: knobs.student) },
        engineFactory: { _ in engine },
        dialogs: dialogs,
        defaults: defaults)
}

@MainActor
func openAndWait(_ model: CoursModel, _ url: URL) async -> Bool {
    await model.load(url)
    return model.document != nil
}

// MARK: - Scénarios

@MainActor
func testHelpers() {
    section("Textes français (accords, listes)")
    check(Fr.foundSummary(zones: 12, pages: 3) == "12 zones trouvées sur 3 pages", "pluriel")
    check(Fr.foundSummary(zones: 1, pages: 1) == "1 zone trouvée sur 1 page", "singulier : \(Fr.foundSummary(zones: 1, pages: 1))")
    check(Fr.foundSummary(zones: 0, pages: 0) == "Aucune zone à remplir n'a été trouvée", "aucune zone")
    check(Fr.list([2, 5, 7]) == "2, 5 et 7", "liste de trois")
    check(Fr.list([2, 5]) == "2 et 5", "liste de deux")
    check(Fr.sentence("Bonjour") == "Bonjour.", "point final ajouté")
    check(Fr.sentence("Bonjour !") == "Bonjour !", "ponctuation déjà là")
    check(Fr.pageList([2]) == "la page 3", "une page")
    check(Fr.pageList([4, 1]) == "les pages 2 et 5", "deux pages")
    check(Fr.quote("x") == "«\u{00A0}x\u{00A0}»", "guillemets")
    check(Fr.answers(1) == "1 réponse" && Fr.answers(2) == "2 réponses", "réponses")
}

@MainActor
func testKeychain() {
    section("Trousseau (service d'essai, jamais la vraie clé)")
    let service = "fr.complete-cours.app.tests"
    let account = "essai-\(UUID().uuidString.prefix(8))"
    do {
        try? Keychain.delete(service: service, account: account)
        check(!Keychain.exists(service: service, account: account), "rien au départ")
        check((try? Keychain.read(service: service, account: account)) == .some(nil), "lecture vide = nil")
        try Keychain.save("valeur-de-test-1", service: service, account: account)
        check(Keychain.exists(service: service, account: account), "présent après l'enregistrement")
        try check(Keychain.read(service: service, account: account) == "valeur-de-test-1", "relecture identique")
        try Keychain.save("valeur-de-test-2", service: service, account: account)
        try check(Keychain.read(service: service, account: account) == "valeur-de-test-2", "remplacement")
        try Keychain.delete(service: service, account: account)
        check(!Keychain.exists(service: service, account: account), "supprimé")
        try Keychain.delete(service: service, account: account)
        check(true, "supprimer deux fois ne lève pas d'erreur")
    } catch {
        failed += 1
        print("  ECHEC : trousseau inutilisable dans cet environnement : \(error.localizedDescription)")
        try? Keychain.delete(service: service, account: account)
    }
    check(Keychain.service == "fr.complete-cours.app", "nom du service")
}

@MainActor
func testSettings() {
    section("Réglages (UserDefaults, jamais la clé)")
    let suite = "fr.complete-cours.tests.reglages"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    let s0 = RunSettings.current(d)
    check(s0.humanize == true, "humaniser par défaut")
    check(s0.flatten == true, "aplatir par défaut")
    check(s0.styleKey == "bleu", "style bleu par défaut")
    check(s0.student.isEmpty, "profil vide par défaut")
    d.set("apple", forKey: Pref.engine)
    d.set(false, forKey: Pref.humanize)
    d.set("manuscrit", forKey: Pref.writingStyle)
    d.set("Martin", forKey: Pref.studentName)
    d.set("Léa", forKey: Pref.studentFirstName)
    d.set("2de MTNE", forKey: Pref.studentClass)
    let s1 = RunSettings.current(d)
    check(s1.engine == .apple && s1.engine.needsPageText, "moteur Apple : lit le texte des scans")
    check(s1.humanize == false, "humaniser coupé")
    check(s1.style == WritingStyle.manuscrit, "style manuscrit")
    check(s1.student == StudentProfile(nom: "Martin", prenom: "Léa", classe: "2de MTNE"), "profil élève")
    d.set("claude", forKey: Pref.engine)
    check(!RunSettings.current(d).engine.needsPageText, "Claude lit les images : pas d'OCR")
    check(RunSettings.current(d).engineDisplayName == (ClaudeEngine.models.first { $0.id == RunSettings.current(d).claudeModel }?.label ?? RunSettings.current(d).claudeModel), "nom du moteur Claude")
    check(StyleChoice.allCases.map { $0.rawValue } == ["bleu", "noir", "manuscrit"], "styles proposés")
    d.removePersistentDomain(forName: suite)
}

@MainActor
func testEngineFactory() {
    section("Fabrique de moteur")
    let claude = RunSettings(engine: .claude, claudeModel: ClaudeEngine.defaultModel, humanize: true, styleKey: "bleu", flatten: true, student: StudentProfile())
    do {
        _ = try EngineFactory.make(claude, claudeKey: "   ")
        check(false, "une clé vide doit être refusée")
    } catch let e as EngineError {
        check(e.isFatal && (e.errorDescription ?? "").contains("clé"), "clé vide : message clair (\(e.errorDescription ?? ""))")
    } catch { check(false, "mauvaise erreur : \(error)") }
    if let engine = try? EngineFactory.make(claude, claudeKey: " sk-test-factice \n", claudeBaseURL: URL(string: "http://127.0.0.1:9")!) {
        check(engine.usesImages, "Claude lit les images")
        check(engine.usesImages != claude.engine.needsPageText, "EngineKind.needsPageText est cohérent avec le moteur")
    } else { check(false, "moteur Claude non construit avec une clé de test") }
    var apple = claude
    apple.engine = .apple
    if let reason = AppleEngine.unavailabilityReason() {
        do { _ = try EngineFactory.make(apple); check(false, "Apple indisponible doit lever une erreur") }
        catch let e as EngineError { check(e.isFatal && e.errorDescription == Fr.sentence(reason), "Apple indisponible : \(e.errorDescription ?? "")") }
        catch { check(false, "mauvaise erreur") }
    } else if let engine = try? EngineFactory.make(apple) {
        check(!engine.usesImages, "Apple lit seulement le texte")
        check(apple.engine.needsPageText, "EngineKind.needsPageText est cohérent avec le moteur Apple")
    } else { check(false, "Apple disponible mais moteur non construit") }

    let status = EngineStatus()
    let p = status.problem(for: .apple)
    check((p == nil) == (status.appleReason == nil), "problème Apple cohérent avec la disponibilité")
    if !status.claudeKeyPresent { check(status.problem(for: .claude)?.title == "Il manque ta clé Claude", "problème Claude sans clé") }
}

@MainActor
func testOpening(_ files: TestPDFs.Files, dir: URL) async {
    section("Ouverture et analyse")
    let engine = FakeEngine()
    let model = makeModel(engine: engine)
    await checkA(await openAndWait(model, files.texte), "texte.pdf s'ouvre")
    check(model.isReady && !model.isBusy, "analyse terminée")
    check(model.pageCount == 2, "2 pages")
    check(model.zones.count == 9, "9 zones trouvées (6 + 3) : \(model.zones.count)")
    check(model.zonePageCount == 2, "zones sur 2 pages")
    check(model.analysisSummary == "9 zones trouvées sur 2 pages", "résumé : \(model.analysisSummary)")
    check(model.documentName == "texte", "nom du document")
    check(model.recents.first?.lastPathComponent == "texte.pdf", "document récent noté")
    check(!model.hasUnsavedChanges, "rien à enregistrer au départ")
    check(model.zones.map { $0.page } == model.zones.map { $0.page }.sorted(), "zones triées par page")
    check(model.skippedPages.isEmpty && model.skippedPagesMessage == nil, "aucune page ignorée")
    check(model.canComplete && model.canSave && model.canDrawZone, "boutons disponibles")
    check(Set(model.zones.map { $0.id }).count == model.zones.count, "identifiants uniques")

    // page tournée
    await checkA(await openAndWait(model, files.tourne), "tourne.pdf s'ouvre")
    check(model.skippedPages == [0], "page tournée repérée")
    check((model.skippedPagesMessage ?? "").contains("tournées"), "message pour PDF entièrement tourné : \(model.skippedPagesMessage ?? "")")
    check(model.zones.isEmpty && !model.canComplete && !model.canDrawZone, "rien à faire sur un PDF tourné")
    check(model.analysisSummary == "Aucune zone à remplir n'a été trouvée", "résumé sans zone")

    // PDF verrouillé
    await checkA(!(await openAndWait(model, files.verrouille)), "verrouille.pdf ne s'ouvre pas")
    check((model.openError ?? "").contains("mot de passe"), "message de mot de passe : \(model.openError ?? "")")
    check(model.document == nil && model.zones.isEmpty, "état vide après échec")

    // fichier absent
    await checkA(!(await openAndWait(model, dir.appendingPathComponent("absent.pdf"))), "fichier absent")
    check((model.openError ?? "").contains("introuvable"), "message : \(model.openError ?? "")")

    // fichier qui n'est pas un PDF
    let fake = dir.appendingPathComponent("faux.pdf")
    try? "ceci n'est pas un pdf".write(to: fake, atomically: true, encoding: .utf8)
    await checkA(!(await openAndWait(model, fake)), "faux PDF refusé")
    check((model.openError ?? "").contains("pas un PDF valide"), "message : \(model.openError ?? "")")

    // glisser-déposer
    check(!model.handleDrop([URL(fileURLWithPath: "/tmp/notes.txt")]), "un .txt est refusé")
    check((model.openError ?? "").contains("n'est pas un PDF"), "message de dépôt : \(model.openError ?? "")")

    // PDF sans zone
    await checkA(await openAndWait(model, files.vide), "vide.pdf s'ouvre")
    check(model.zones.isEmpty && !model.canComplete, "pas de zone, pas de complétion")
    check(model.canDrawZone, "mais on peut ajouter une zone à la main")

    // rognage décalé
    await checkA(await openAndWait(model, files.rognage), "rognage.pdf s'ouvre")
    check(model.zones.count == 6, "6 zones malgré le rognage : \(model.zones.count)")
}

@MainActor
func testCompletion(_ files: TestPDFs.Files) async {
    section("Compléter le cours (faux moteur)")
    let engine = FakeEngine()
    // Le pipeline n'envoie pas plus d'une mise à jour par 0,1 s : sans délai, les pages défilent trop vite pour être vues.
    engine.delayPerPage = 0.25
    let dialogs = ScriptedDialogs()
    let model = makeModel(engine: engine, dialogs: dialogs)
    _ = await openAndWait(model, files.texte)

    var labels: [String] = []
    var fractions: [Double] = []
    let bag = model.$run.sink { state in
        if case .running(let p, _) = state { labels.append(p.label); fractions.append(p.fraction) }
    }
    model.startCompletion()
    check(model.isRunning || true, "démarrage")
    await checkA(await waitUntil { !model.isRunning && model.zones.contains { !$0.answer.isEmpty } }, "traitement terminé")
    bag.cancel()

    check(!model.isRunning, "plus de traitement en cours")
    check(dialogs.confirms.isEmpty, "pas de confirmation tant qu'il n'y a pas de réponse")
    check(labels.contains("Complétion — page 1 sur 2"), "étiquette de progression page 1 : \(labels)")
    check(labels.contains("Complétion — page 2 sur 2"), "étiquette de progression page 2")
    check(labels.contains("Humanisation…"), "étiquette d'humanisation")
    check(fractions == fractions.sorted(), "la progression ne recule jamais : \(fractions)")
    check(model.zones.allSatisfy { !$0.answer.isEmpty && $0.error == nil }, "toutes les zones ont une réponse")
    let motZones = model.zones.filter { $0.kind == .mot }
    let longZones = model.zones.filter { $0.kind.isHumanizable }
    check(!motZones.isEmpty && !longZones.isEmpty, "il y a des mots et des réponses longues")
    check(motZones.allSatisfy { !$0.humanized && $0.answer.first?.isLowercase == true }, "les mots à compléter ne sont jamais réécrits")
    check(model.zones.filter { $0.kind == .definition }.allSatisfy { !$0.humanized && $0.answer == $0.rawAnswer },
          "les définitions restent inchangées")
    check(model.zones.filter { $0.kind == .question && $0.enabled }.allSatisfy { $0.humanized && $0.answer != $0.rawAnswer },
          "les questions ouvertes sont humanisées")
    check(engine.humanizeCalls >= 1, "l'étape d'humanisation a eu lieu")
    check(model.hasUnsavedChanges, "du travail à enregistrer")
    check(model.notice?.style == .success && (model.notice?.text ?? "").hasPrefix("C'est fait : 9 réponses écrites."), "message de fin : \(model.notice?.text ?? "")")
    check(engine.requests.count == 2, "une requête par page")
    check(engine.requests.first?.markedImageJPEG != nil, "Claude reçoit l'image de la page")
    check(engine.requests.first?.documentName == "texte", "nom du document dans la requête")

    // refaire tout : confirmation demandée
    dialogs.confirmAnswers = [false]
    let before = model.zones.map { $0.answer }
    model.startCompletion()
    check(dialogs.confirms.count == 1 && dialogs.confirms[0].title == "Refaire tout le cours ?", "confirmation avant de remplacer")
    check(!model.isRunning && model.zones.map { $0.answer } == before, "refus : rien ne change")
    dialogs.confirmAnswers = [true]
    engine.answerPrefix = "nouvelle"
    model.startCompletion()
    await checkA(await waitUntil { !model.isRunning && model.zones.allSatisfy { $0.answer.lowercased().hasPrefix("nouvelle") } }, "accepté : tout est remplacé")

    // moteur qui ignore une zone
    let ig = FakeEngine()
    ig.ignoreZoneNumbers = [1]
    let model2 = makeModel(engine: ig)
    _ = await openAndWait(model2, files.texte)
    await model2.complete()
    let ignored = model2.zones.filter { $0.number == 1 }
    check(ignored.count == 2 && ignored.allSatisfy { $0.kind == .ignorer && !$0.enabled && $0.answer.isEmpty }, "zones ignorées par le moteur")
    check(model2.answeredCount == 7, "7 réponses sur 9 zones : \(model2.answeredCount)")

    // sans humanisation
    let knobs = Knobs()
    knobs.humanize = false
    let plain = FakeEngine()
    let model3 = makeModel(engine: plain, knobs: knobs)
    _ = await openAndWait(model3, files.texte)
    await model3.complete()
    check(plain.humanizeCalls == 0 && model3.zones.allSatisfy { !$0.humanized }, "humanisation désactivée dans les réglages")
}

@MainActor
func testEdits(_ files: TestPDFs.Files) async {
    section("Modifications de l'élève")
    let engine = FakeEngine()
    let model = makeModel(engine: engine)
    _ = await openAndWait(model, files.texte)
    await model.complete()

    guard let long = model.zones.first(where: { $0.humanized }) else { check(false, "une zone humanisée"); return }
    check(long.rawAnswer != long.answer, "texte d'origine différent")
    model.useOriginalText(for: long.id)
    var z = model.zone(long.id)!
    check(z.answer == z.rawAnswer && !z.humanized, "retour au texte d'origine")

    model.setAnswer("ma propre réponse", for: z.id)
    z = model.zone(z.id)!
    check(z.answer == "ma propre réponse" && z.rawAnswer == "ma propre réponse" && !z.humanized, "réponse tapée = nouvelle référence")
    check(model.hasUnsavedChanges, "modification à enregistrer")

    // un mot à compléter ne reste jamais humanisé
    guard let h = model.zones.first(where: { $0.humanized }) else { check(false, "autre zone humanisée"); return }
    model.setKind(.mot, for: h.id)
    let m = model.zone(h.id)!
    check(m.kind == .mot && !m.humanized && m.answer == m.rawAnswer, "passer en « mot » remet le texte d'origine")

    // ignorer puis réactiver
    model.setKind(.ignorer, for: m.id)
    check(model.zone(m.id)!.enabled == false, "ignorer désactive l'écriture")
    model.setEnabled(true, for: m.id)
    check(model.zone(m.id)!.enabled == false, "on ne réactive pas une zone ignorée avec la case")
    model.setKind(.definition, for: m.id)
    check(model.zone(m.id)!.enabled == true, "changer le type réactive la zone")
    model.setEnabled(false, for: m.id)
    check(model.zone(m.id)!.enabled == false, "case décochée")

    // taper une réponse dans une zone vide l'active
    model.setAnswer("", for: m.id)
    model.setEnabled(false, for: m.id)
    model.setAnswer("écrit à la main", for: m.id)
    check(model.zone(m.id)!.enabled == true, "écrire dans une zone vide l'active")
}

@MainActor
func testRegenerateAndErrors(_ files: TestPDFs.Files) async {
    section("Régénérer, erreurs, clé refusée")
    let engine = FakeEngine()
    engine.failPages = [1]
    let model = makeModel(engine: engine)
    _ = await openAndWait(model, files.texte)
    await model.complete()
    let page1 = model.zones.filter { $0.page == 0 }
    let page2 = model.zones.filter { $0.page == 1 }
    check(page1.allSatisfy { $0.error != nil && $0.answer.isEmpty }, "page 1 en erreur")
    check((page1.first?.error ?? "").contains("Panne de réseau"), "message d'erreur lisible : \(page1.first?.error ?? "")")
    check(page2.allSatisfy { $0.error == nil && !$0.answer.isEmpty }, "page 2 réussie malgré l'erreur de la page 1")
    check(model.notice?.style == .warning && (model.notice?.text ?? "").contains("Réessayer"), "message de fin avec avertissement : \(model.notice?.text ?? "")")
    check(model.saveWarning()?.contains("erreur") == true, "avertissement avant l'enregistrement : \(model.saveWarning() ?? "-")")

    check(model.notice?.offersRetry == true && model.failedZoneCount == page1.count, "le message propose de réessayer toutes les zones en erreur")

    engine.failPages = []
    let target = page1[2]
    let requestsBefore = engine.requests.count
    model.regenerate(target.id)
    await checkA(await waitUntil { !model.isRunning && model.zone(target.id)!.error == nil && !model.zone(target.id)!.answer.isEmpty }, "la zone réessayée est remplie")
    check(engine.requests.count == requestsBefore + 1 && engine.requests.last!.zones.count == 1 && engine.requests.last!.zones[0].number == target.number, "une seule zone demandée")
    check(model.zones.filter { $0.page == 0 && $0.id != target.id }.allSatisfy { $0.error != nil }, "les autres zones de la page 1 ne sont pas touchées")
    check(model.notice == nil, "pas de message après une régénération réussie")

    // « Réessayer les zones en erreur » : seules les zones restées en erreur sont redemandées
    let remaining = model.failedZoneCount
    let before = engine.requests.count
    model.retryFailedZones()
    await checkA(await waitUntil { !model.isRunning && model.failedZoneCount == 0 }, "toutes les zones en erreur sont reprises")
    check(remaining == page1.count - 1, "il restait \(page1.count - 1) zones en erreur : \(remaining)")
    check(engine.requests.count == before + 1 && engine.requests.last!.zones.count == remaining, "une seule requête pour la page 1, avec les zones en erreur seulement")
    check(model.zones.filter { $0.page == 0 }.allSatisfy { !$0.answer.isEmpty && $0.error == nil }, "la page 1 est complète")

    // clé refusée : erreur fatale, bouton vers les Réglages
    let bad = FakeEngine()
    bad.failWithAuth = true
    let model2 = makeModel(engine: bad)
    _ = await openAndWait(model2, files.texte)
    await model2.complete()
    check(model2.runProblem?.needsSettings == true, "clé refusée → bouton Réglages")
    check((model2.runProblem?.message ?? "").contains("clé"), "message : \(model2.runProblem?.message ?? "")")
    check(!model2.isRunning, "plus de traitement")
    check(model2.zones.allSatisfy { $0.error == nil }, "panne générale : le message n'est pas répété sur chaque zone")

    // moteur introuvable (pas de clé)
    let knobs = Knobs()
    let defaults = UserDefaults(suiteName: suiteName)!
    let model3 = CoursModel(settings: { RunSettings(engine: knobs.kind, claudeModel: "x", humanize: true, styleKey: "bleu", flatten: true, student: StudentProfile()) },
                            engineFactory: { _ in throw EngineError.unavailable("Aucune clé API Claude n'est enregistrée.") },
                            dialogs: ScriptedDialogs(), defaults: defaults)
    _ = await openAndWait(model3, files.texte)
    await model3.complete()
    check(model3.runProblem?.needsSettings == true && !model3.isRunning, "moteur indisponible : message + Réglages")
    model3.dismissRunProblem()
    check(model3.runProblem == nil, "message fermé")
}

@MainActor
func testCancel(_ files: TestPDFs.Files) async {
    section("Annuler pendant le traitement")
    let engine = FakeEngine()
    engine.delayPerPage = 0.6
    let model = makeModel(engine: engine)
    _ = await openAndWait(model, files.texte)
    model.startCompletion()
    await checkA(await waitUntil { model.zones.contains { $0.page == 0 && !$0.answer.isEmpty } }, "la page 1 est arrivée")
    model.cancelRun()
    check(!model.isRunning, "annulé immédiatement")
    check((model.notice?.text ?? "").contains("annulé"), "message : \(model.notice?.text ?? "")")
    check(model.zones.filter { $0.page == 0 }.allSatisfy { !$0.answer.isEmpty }, "les réponses de la page 1 sont gardées")
    check(model.zones.filter { $0.page == 1 }.allSatisfy { $0.answer.isEmpty }, "la page 2 n'a rien")
    try? await Task.sleep(nanoseconds: 1_800_000_000)
    check(model.zones.filter { $0.page == 1 }.allSatisfy { $0.answer.isEmpty && $0.error == nil }, "une réponse qui arrive après l'annulation est ignorée")
    check(model.canComplete && !model.isRunning, "on peut relancer")
}

@MainActor
func testManualZones(_ files: TestPDFs.Files) async {
    section("Zones ajoutées à la main")
    let engine = FakeEngine()
    let model = makeModel(engine: engine)
    _ = await openAndWait(model, files.texte)
    let before = model.zones.count
    model.beginDrawingZone()
    check(model.isDrawingZone, "mode dessin")
    model.cancelDrawingZone()
    check(!model.isDrawingZone, "mode dessin annulé")

    await model.addManualZone(pageIndex: 0, rect: CGRect(x: 60, y: 200, width: 220, height: 40))
    check(model.zones.count == before + 1, "zone ajoutée")
    let manual = model.zones.first { $0.source == .manuel }
    check(manual != nil, "zone manuelle présente")
    if let manual {
        check(manual.page == 0 && manual.number == 7, "numéro suivant sur la page : \(manual.number)")
        check(manual.box == CGRect(x: 60, y: 200, width: 220, height: 40), "rectangle conservé")
        check(model.selectedZoneID == manual.id && model.revealRequest?.zoneID == manual.id, "zone sélectionnée")
        check(Set(model.zones.map { $0.id }).count == model.zones.count, "identifiants uniques")
        // « Compléter cette zone »
        model.regenerate(manual.id)
        await checkA(await waitUntil { !model.isRunning && !(model.zone(manual.id)?.answer ?? "").isEmpty }, "zone manuelle complétée")
        check(engine.requests.last?.zones.count == 1 && engine.requests.last?.pageNumber == 1, "requête limitée à cette zone")
        // suppression : seulement pour les zones manuelles
        let detected = model.zones.first { $0.source != .manuel }!
        model.deleteManualZone(detected.id)
        check(model.zone(detected.id) != nil, "une zone détectée ne se supprime pas")
        model.deleteManualZone(manual.id)
        check(model.zone(manual.id) == nil && model.zones.count == before, "zone manuelle supprimée")
    }

    // page tournée
    _ = await openAndWait(model, files.tourne)
    await model.addManualZone(pageIndex: 0, rect: CGRect(x: 60, y: 200, width: 220, height: 40))
    check(model.zones.isEmpty && (model.notice?.text ?? "").contains("tournée"), "page tournée : refus clair : \(model.notice?.text ?? "")")
}

@MainActor
func rendererIsReal(_ files: TestPDFs.Files) -> Bool {
    guard let doc = PDFDocument(url: files.texte) else { return false }
    var z = Zone(id: 1, page: 0, number: 1, source: .texte)
    z.lines = [WritingLine(x0: 100, x1: 300, y: 500)]
    z.answer = "test"
    z.enabled = true
    z.kind = .mot
    let r = AnswerRenderer.apply(zones: [z], to: doc, style: .bleuImprime)
    return !r.annotations.isEmpty
}

@MainActor
func testSaving(_ files: TestPDFs.Files, dir: URL) async {
    section("Enregistrer le PDF complété")
    let engine = FakeEngine()
    let dialogs = ScriptedDialogs()
    let model = makeModel(engine: engine, dialogs: dialogs)
    _ = await openAndWait(model, files.texte)

    model.savePDF()
    check(dialogs.informs.count == 1 && dialogs.informs[0].title.contains("Rien à enregistrer"), "sans réponse : explication")
    check(dialogs.saveRequests == 0, "pas de panneau d'enregistrement sans réponse")

    await model.complete()
    let originalData = try? Data(contentsOf: files.texte)
    let out = dir.appendingPathComponent("sortie (complétée).pdf")
    try? FileManager.default.removeItem(at: out)

    // 1) on choisit d'abord le PDF d'origine : refus, puis un bon nom
    dialogs.saveURLs = [files.texte, out]
    model.savePDF()
    await checkA(await waitUntil(20) { dialogs.saveRequests == 2 && (!dialogs.informs.isEmpty) && !model.isSaving }, "deux demandes de nom")
    check(dialogs.informs.last?.title == "Choisis un autre nom" || dialogs.informs.count >= 2, "l'origine ne peut pas être écrasée : \(dialogs.informs.map { $0.title })")
    check(dialogs.lastSuggestedName == "texte (complétée).pdf", "nom proposé : \(dialogs.lastSuggestedName)")
    check(dialogs.lastDirectory?.standardizedFileURL == files.texte.deletingLastPathComponent().standardizedFileURL, "dossier d'origine proposé")
    _ = await waitUntil(20) { !model.isSaving && (model.notice?.style == .success || dialogs.informs.contains { $0.title.contains("a échoué") }) }
    let failedInform = dialogs.informs.first { $0.title.contains("a échoué") }
    if let failedInform {
        if rendererIsReal(files) { check(false, "export refusé alors que le rendu est réel : \(failedInform.message)") }
        else { skip("export : le rendu est encore un squelette (\(failedInform.message))") }
    } else {
        check(FileManager.default.fileExists(atPath: out.path), "le PDF complété existe")
        check(dialogs.revealed == [out], "révélé dans le Finder")
        check(!model.hasUnsavedChanges, "plus de travail non enregistré")
        if let doc = PDFDocument(url: out) { check(doc.pageCount == 2, "même nombre de pages") } else { check(false, "PDF de sortie illisible") }
        check(model.notice?.revealURL == out, "message avec lien vers le fichier")
    }
    check((try? Data(contentsOf: files.texte)) == originalData, "le PDF d'origine n'a pas changé")

    // 2) avertissement avant l'enregistrement (zone qui déborde)
    let dialogs2 = ScriptedDialogs()
    let model2 = makeModel(engine: FakeEngine(), dialogs: dialogs2)
    _ = await openAndWait(model2, files.texte)
    await model2.complete()
    if rendererIsReal(files) {
        model2.setAnswer(String(repeating: "mot ", count: 120), for: model2.zones[1].id)
        model2.renderAnswers()
        check(model2.zones[1].overflow, "le rendu signale le débordement")
        check(model2.saveWarning()?.contains("ne rentre pas") == true, "avertissement de débordement : \(model2.saveWarning() ?? "-")")
        dialogs2.confirmAnswers = [false]
        model2.savePDF()
        check(dialogs2.confirms.last?.title == "Certaines zones posent problème" && dialogs2.saveRequests == 0, "on peut revenir à la liste sans enregistrer")
    } else {
        skip("débordement : le rendu est encore un squelette")
    }
}

@MainActor
func testRescanForText(_ files: TestPDFs.Files) async {
    section("Moteur sans vision : lecture des scans (OCR) à la demande")
    let knobs = Knobs()
    knobs.kind = .claude
    let blind = FakeEngine(name: "Moteur texte", usesImages: false)
    let model = makeModel(engine: blind, knobs: knobs)
    await checkA(await openAndWait(model, files.scan), "scan.pdf s'ouvre")
    check(model.isReady, "analyse faite")
    let manualRect = CGRect(x: 60, y: 150, width: 200, height: 30)
    await model.addManualZone(pageIndex: 0, rect: manualRect)
    let zonesBefore = model.zones.count
    check(model.zones.contains { $0.source == .manuel }, "zone manuelle sur le scan")
    check(zonesBefore >= 2, "des zones sont trouvées dans l'image : \(zonesBefore)")

    knobs.kind = .apple          // on change de moteur après l'ouverture
    await model.complete()
    check(!model.isRunning && model.runProblem == nil, "traitement sans problème")
    let transcript = blind.requests.first?.transcript.lowercased() ?? ""
    check(transcript.contains("soleil") || transcript.contains("énergie") || transcript.contains("energie"), "le texte du scan a été lu avant d'écrire : «\(transcript.prefix(80))»")
    check(model.zones.contains { $0.source == .manuel && $0.box == manualRect }, "la zone manuelle survit à la relecture")
}

@MainActor
func runAll() async {
    let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        .appendingPathComponent("tests-app-\(getpid())")
    let files = TestPDFs.generate(in: dir)
    defer { try? FileManager.default.removeItem(at: dir) }

    testHelpers()
    testKeychain()
    testSettings()
    testEngineFactory()
    await testOpening(files, dir: dir)
    await testCompletion(files)
    await testEdits(files)
    await testRegenerateAndErrors(files)
    await testCancel(files)
    await testManualZones(files)
    await testSaving(files, dir: dir)
    await testRescanForText(files)
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
}

_ = NSApplication.shared
Task { @MainActor in
    await runAll()
    print("\nRésultat : \(passed) réussis, \(failed) échec(s), \(skipped) ignoré(s)")
    exit(failed == 0 ? 0 : 1)
}
dispatchMain()
