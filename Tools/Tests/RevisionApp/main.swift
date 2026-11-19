import Foundation
import AppKit
import PDFKit

// Tests du modèle du mode Révision (sans fenêtre, sans réseau). Lancement : Tools/Tests/RevisionApp/run_tests.sh

var passed = 0
var failed = 0
func check(_ c: @autoclosure () -> Bool, _ m: String, line: Int = #line) {
    if c() { passed += 1 } else { failed += 1; print("  ECHEC (ligne \(line)) : \(m)") }
}
func check(_ c: @autoclosure () -> Bool, _ m: String, _ detail: @autoclosure () -> String, line: Int = #line) {
    if c() { passed += 1 } else { failed += 1; print("  ECHEC (ligne \(line)) : \(m) — \(detail())") }
}
func section(_ t: String) { print("\n== \(t)") }

@MainActor
final class ScriptedDialogs: RevisionDialogs {
    var saveURL: URL?
    var openURL: URL?
    private(set) var informs: [String] = []
    private(set) var revealed: [URL] = []
    func chooseOpenURL() -> URL? { openURL }
    func chooseSaveURL(suggestedName: String) -> URL? { saveURL }
    func inform(title: String, message: String) { informs.append(title) }
    func reveal(_ url: URL) { revealed.append(url) }
}

let scratch = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
    .appendingPathComponent("donnees")
try? FileManager.default.removeItem(at: scratch)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

func makePDF(_ name: String) -> URL {
    let url = scratch.appendingPathComponent(name)
    let doc = PDFDocument()
    for i in 0..<3 {
        let img = NSImage(size: NSSize(width: 200, height: 200)); img.lockFocus(); NSColor.white.set(); NSRect(x: 0, y: 0, width: 200, height: 200).fill(); img.unlockFocus()
        if let p = PDFPage(image: img) { doc.insert(p, at: i) }
    }
    doc.write(to: url)
    return url
}

let usable = RevisionEngineStatus(name: "Claude (test)", usable: true, supportsImages: true, issue: nil, needsSettings: false)
let apple = RevisionEngineStatus(name: "Apple Intelligence", usable: false, supportsImages: false,
                                 issue: RevisionEngineStatus.message, needsSettings: true)

@MainActor
func makeModel(status: RevisionEngineStatus = usable, service: FakeRevisionService = FakeRevisionService(),
               exporter: FakeRevisionExporter = FakeRevisionExporter(), dialogs: ScriptedDialogs? = nil) -> RevisionModel {
    let dialogs = dialogs ?? ScriptedDialogs()
    return RevisionModel(engineStatus: { status }, makeService: { service }, exporter: exporter, dialogs: dialogs)
}

@MainActor
func run() async {
    let pdf = makePDF("cours.pdf")
    let pdfBytes = try? Data(contentsOf: pdf)

    section("Ouverture")
    do {
        let d = ScriptedDialogs()
        let m = makeModel(dialogs: d)
        check(!m.hasDocument && !m.canStart, "rien d'ouvert au départ")
        m.handleDrop([scratch.appendingPathComponent("notes.txt")])
        check(m.issue?.title == "Ce fichier n'est pas un PDF", "un non-PDF est refusé en français")
        let bad = scratch.appendingPathComponent("faux.pdf"); try? Data("pas un pdf".utf8).write(to: bad)
        m.open(bad)
        check(!m.hasDocument && m.issue?.title == "Ce PDF ne s'ouvre pas", "PDF illisible")
        d.openURL = pdf
        m.chooseDocument()
        check(m.documentName == "cours" && m.pageCount == 3 && m.issue == nil, "ouverture par le dialogue")
        check(m.estimate?.contains("jetons") == true, "estimation affichée")
    }

    section("Parcours fiche")
    do {
        let svc = FakeRevisionService()
        let d = ScriptedDialogs()
        let m = makeModel(service: svc, dialogs: d)
        m.open(pdf)
        m.makeSummary()
        check(m.isBusy && m.activity != nil, "activité pendant la création")
        m.makeSummary()
        await m.waitUntilIdle()
        check(m.summary?.title == "La loi d'Ohm" && !m.isBusy, "fiche créée")
        check(svc.calls == ["loadSource", "makeSummary"], "un seul appel malgré le double clic : \(svc.calls)")
        check(svc.lastLoadWithImages == false, "fiche sans images")
        let out = scratch.appendingPathComponent("fiche.pdf")
        d.saveURL = out
        m.saveSummaryPDF(); await m.waitUntilIdle()
        check((try? Data(contentsOf: out))?.starts(with: Data("%PDF".utf8)) == true, "PDF enregistré")
        check(m.notice?.contains("fiche.pdf") == true && d.revealed == [out], "message et affichage dans le Finder")
        d.saveURL = pdf
        m.saveSummaryPDF(); await m.waitUntilIdle()
        check(d.informs == ["Ton cours d'origine est protégé"] && (try? Data(contentsOf: pdf)) == pdfBytes, "l'original n'est jamais écrasé")
        let failing = makeModel(exporter: FakeRevisionExporter(fail: true), dialogs: d)
        failing.open(pdf); failing.makeSummary(); await failing.waitUntilIdle()
        d.saveURL = scratch.appendingPathComponent("x.pdf")
        failing.saveSummaryPDF(); await failing.waitUntilIdle()
        check(failing.issue?.title == "La fiche n'a pas pu être enregistrée", "échec d'export expliqué")
    }

    section("Parcours entraînement")
    do {
        let svc = FakeRevisionService()
        let d = ScriptedDialogs()
        let m = makeModel(service: svc, dialogs: d)
        m.open(pdf)
        m.quizOptions.styles = [.qcm, .vraiFaux, .definition, .calcul]
        m.quizOptions.count = 10
        m.makeQuiz(); await m.waitUntilIdle()
        check(m.questions.count == 4 && m.current?.id == 1, "questions générées")
        // question 1 (QCM) : mauvais choix -> faux, corrigé localement
        m.setAnswer("Le volt", for: m.questions[0])
        check(m.canGrade(m.questions[0]), "Corriger actif après un choix")
        m.gradeCurrent()
        check(m.graded[1]?.verdict == .faux && !svc.calls.contains("grade"), "QCM corrigé sans appel réseau")
        m.setAnswer("L'ohm", for: m.questions[0])
        check(m.answer(for: m.questions[0]) == "Le volt", "réponse figée après correction")
        m.next()
        m.setAnswer("faux", for: m.questions[1]); m.gradeCurrent()
        check(m.graded[2]?.verdict == .juste, "vrai/faux juste (casse ignorée)")
        m.next()
        check(!m.canGrade(m.questions[2]), "réponse vide : pas de correction")
        m.setAnswer("je ne sais pas", for: m.questions[2])
        m.gradeCurrent(); await m.waitUntilIdle()
        check(m.graded[3]?.verdict == .faux, "définition corrigée par le service")
        m.next()
        m.setAnswer("U = 20 V", for: m.questions[3]); m.gradeCurrent(); await m.waitUntilIdle()
        check(m.graded[4]?.verdict == .juste && m.allGraded, "calcul juste, tout corrigé")
        m.next()
        check(m.showingResults && m.score == 2 && m.scoreText == "2 sur 4", "score \(m.scoreText)")
        check(m.missedQuestions.map(\.id) == [1, 3], "ratées : \(m.missedQuestions.map(\.id))")
        m.retryMissed()
        check(m.questions.map(\.id) == [1, 3] && m.graded.isEmpty && !m.showingResults && m.round == 2, "série de rattrapage")
        let out = scratch.appendingPathComponent("q.pdf")
        d.saveURL = out
        m.exportQuizPDF(withAnswers: true); await m.waitUntilIdle()
        check(String(data: (try? Data(contentsOf: out)) ?? Data(), encoding: .utf8)?.contains("avec") == true, "export avec réponses")
        m.exportQuizPDF(withAnswers: false); await m.waitUntilIdle()
        check(String(data: (try? Data(contentsOf: out)) ?? Data(), encoding: .utf8)?.contains("sans") == true, "export sans réponses")
        m.toggleStyle(.qcm); m.newQuiz()
        check(m.questions.isEmpty, "retour aux options")
        m.quizOptions.styles = [.calcul]; m.toggleStyle(.calcul)
        check(m.quizOptions.styles == [.calcul], "au moins un type reste coché")
    }

    section("Parcours corrigé")
    do {
        let svc = FakeRevisionService()
        let m = makeModel(service: svc)
        m.open(pdf)
        check(!m.canMakeCorrige, "bouton inactif sans la case")
        m.makeCorrige(); await m.waitUntilIdle()
        check(m.corrigeItems.isEmpty && svc.calls.isEmpty, "rien ne part sans la case")
        m.corrigeConfirmed = true
        check(m.canMakeCorrige, "bouton actif avec la case")
        m.makeCorrige(); await m.waitUntilIdle()
        check(m.corrigeItems.count == 2 && svc.lastLoadWithImages == true, "corrigé avec images")
        check(RevisionModel.corrigeWelcome.hasPrefix("À utiliser une fois ton évaluation rendue et corrigée"), "texte d'accueil")
        let other = makePDF("autre.pdf")
        m.open(other)
        check(m.corrigeItems.isEmpty && !m.corrigeConfirmed, "nouveau document : case décochée")
    }

    section("Erreurs de moteur")
    do {
        let m = makeModel(status: apple)
        m.open(pdf)
        check(!m.canStart && m.engine.needsSettings, "Apple Intelligence : rien ne démarre")
        m.makeSummary()
        check(!m.isBusy && m.summary == nil, "pas de tâche")
        check(RevisionEngineStatus.message.what + " " + RevisionEngineStatus.message.todo == "La révision demande Claude (clé API ou ton compte). Change de moteur dans les Réglages.", "message exact")
        let svc = FakeRevisionService()
        let m2 = makeModel(service: svc)
        m2.open(pdf)
        svc.failNext = EngineError.auth("Clé invalide")
        m2.makeSummary(); await m2.waitUntilIdle()
        check(m2.issue?.what.hasPrefix("Claude a refusé ta clé") == true && m2.issue?.todo.contains("Réglages") == true, "clé refusée")
        check(!m2.isBusy, "plus d'activité après l'erreur")
        svc.failNext = EngineError.network("x")
        m2.makeSummary(); await m2.waitUntilIdle()
        check(m2.issue?.todo.contains("connexion") == true, "réseau")
        svc.failNext = EngineError.rateLimited("x")
        m2.makeSummary(); await m2.waitUntilIdle()
        check(m2.issue?.what.contains("trop de demandes") == true, "limite")
        m2.makeSummary(); await m2.waitUntilIdle()
        check(m2.issue == nil && m2.summary != nil, "réessai réussi efface l'erreur")
        let m3 = RevisionModel(engineStatus: { usable },
                               makeService: { throw RevisionIssueError(issue: RevisionIssue(title: "t", what: "Pas de clé.", todo: "Ajoute-la.")) },
                               exporter: FakeRevisionExporter(), dialogs: ScriptedDialogs())
        m3.open(pdf); m3.makeSummary(); await m3.waitUntilIdle()
        check(m3.issue?.what == "Pas de clé.", "erreur de fabrication du service")
    }

    section("Annulation")
    do {
        let svc = FakeRevisionService()
        svc.delayNanos = 80_000_000
        let m = makeModel(service: svc)
        m.open(pdf)
        m.makeSummary()
        try? await Task.sleep(nanoseconds: 100_000_000)
        m.cancel()
        check(!m.isBusy && m.notice == "Opération annulée.", "annulé")
        try? await Task.sleep(nanoseconds: 700_000_000)
        check(m.summary == nil && m.issue == nil && !m.isBusy, "aucun résultat tardif ni erreur")
        m.makeSummary(); await m.waitUntilIdle()
        check(m.summary != nil, "on peut relancer après annulation")
        // changer de document pendant une tâche
        let m2 = makeModel(service: svc)
        m2.open(pdf); m2.makeQuiz()
        m2.open(makePDF("b.pdf"))
        try? await Task.sleep(nanoseconds: 700_000_000)
        check(m2.questions.isEmpty && m2.documentName == "b", "résultat d'un ancien document ignoré")
    }

    section("Consigne libre")
    do {
        let svc = FakeRevisionService()
        let m = makeModel(service: svc)
        m.open(pdf)
        let ohm = InstructionShortcut.all.first { $0.label == "Seulement les formules" }!
        check(InstructionShortcut.all.map(\.label) == ["Très court", "Seulement les formules", "Vocabulaire à connaître", "Pour l'oral", "Plus détaillé"], "cinq pastilles de raccourci")
        check(!m.isActive(ohm, for: .summary), "pastille inactive au départ")
        m.toggleShortcut(ohm, for: .summary)
        check(m.isActive(ohm, for: .summary) && m.summaryInstruction == ohm.phrase && !m.isActive(ohm, for: .quiz), "pastille ajoutée à la consigne de la fiche seulement")
        m.toggleShortcut(InstructionShortcut.all[0], for: .summary)
        check(m.summaryInstruction == ohm.phrase + " " + InstructionShortcut.all[0].phrase, "deux pastilles : phrases à la suite", m.summaryInstruction)
        m.toggleShortcut(ohm, for: .summary)
        check(m.summaryInstruction == InstructionShortcut.all[0].phrase && !m.isActive(ohm, for: .summary), "second clic : la phrase est retirée", m.summaryInstruction)
        m.setInstruction("  Avec\nun retour <b>ligne</b>  ", for: .summary)
        m.makeSummary(); await m.waitUntilIdle()
        check(svc.lastSummaryInstruction == "Avec un retour ligne", "consigne nettoyée avant l'envoi", svc.lastSummaryInstruction ?? "nil")
        check(m.summaryInstruction == "  Avec\nun retour <b>ligne</b>  ", "le champ garde ce que l'élève a écrit")
        m.setInstruction("", for: .summary)
        m.makeSummary(); await m.waitUntilIdle()
        check(svc.lastSummaryInstruction == "", "sans consigne : chaîne vide")
        m.setInstruction("Questions faciles", for: .quiz)
        check(m.quizOptions.instruction == "Questions faciles" && m.instruction(for: .quiz) == "Questions faciles", "consigne de l'entraînement")
        m.makeQuiz(); await m.waitUntilIdle()
        check(svc.lastQuizInstruction == "Questions faciles" && !m.questions.isEmpty, "consigne transmise au service du quiz")
        m.toggleShortcut(InstructionShortcut.all[3], for: .quiz)
        check(m.quizOptions.instruction == "Questions faciles " + InstructionShortcut.all[3].phrase, "pastille de l'entraînement")
    }

    section("Cartes mémoire")
    do {
        check(RevisionTab.allCases.contains(.cartes) && RevisionTab.cartes.title == "Cartes mémoire" && RevisionTab.allCases.count == 4, "onglet « Cartes mémoire »")
        check(RevisionTab.allCases.map(\.id).count == Set(RevisionTab.allCases.map(\.id)).count, "identifiants d'onglets uniques")
        let svc = FakeRevisionService()
        let d = ScriptedDialogs()
        let m = makeModel(service: svc, dialogs: d)
        check(m.cardCount == CardLimits.defaultCount && m.cards.isEmpty && m.currentCard == nil, "état initial")
        m.makeCards()
        check(!m.isBusy, "rien sans document")
        m.open(pdf)
        m.setCardCount(1); check(m.cardCount == 5, "nombre borné en bas")
        m.setCardCount(99); check(m.cardCount == 30, "nombre borné en haut")
        m.setCardCount(5)
        m.makeCards()
        check(m.isBusy && m.activity != nil, "activité pendant la création")
        m.makeCards()
        await m.waitUntilIdle()
        check(m.cards.count == 5 && m.deck.count == 5 && m.currentCard?.id == 1 && !m.cardFlipped && !m.cardsFinished, "cartes créées, première carte à l'endroit")
        check(svc.calls == ["loadSource", "makeCards"] && svc.lastCardCount == 5 && svc.lastLoadWithImages == false, "un seul appel, nombre transmis, sans images", "\(svc.calls)")

        m.markCard(known: true)
        check(m.cardIndex == 0 && m.cardsAnswered == 0, "« Je savais » refusé tant que la carte n'est pas retournée")
        m.flipCard()
        check(m.cardFlipped && m.canMarkCard, "carte retournée")
        m.flipCard()
        check(!m.cardFlipped, "re-retourner remet le recto")
        m.flipCard(); m.markCard(known: true)
        check(m.cardIndex == 1 && !m.cardFlipped && m.cardKnown == [1], "carte 1 sue, carte suivante au recto")
        m.flipCard(); m.markCard(known: false)
        check(m.cardToReview == [2] && m.cardIndex == 2, "carte 2 à revoir")
        m.flipCard(); m.markCard(known: false)
        m.flipCard(); m.markCard(known: true)
        check(m.cardIndex == 4 && !m.cardsFinished && m.cardsAnswered == 4, "progression : 4 cartes sur 5")
        m.flipCard(); m.markCard(known: true)
        check(m.cardsFinished && m.cardKnown == [1, 4, 5] && m.cardToReview == [2, 3], "fin de série")
        check(m.cardsScoreText == "3 sur 5" && m.cardsToReview.map(\.id) == [2, 3], "score \(m.cardsScoreText)")
        m.flipCard(); m.markCard(known: true)
        check(m.cardKnown == [1, 4, 5], "plus rien après la fin")

        let out = scratch.appendingPathComponent("cartes.pdf")
        d.saveURL = out
        m.exportCardsPDF(); await m.waitUntilIdle()
        check(String(data: (try? Data(contentsOf: out)) ?? Data(), encoding: .utf8)?.contains("cartes 5") == true && d.revealed == [out], "export PDF des cartes")
        d.saveURL = pdf
        m.exportCardsPDF(); await m.waitUntilIdle()
        check(d.informs.last == "Ton cours d'origine est protégé" && (try? Data(contentsOf: pdf)) == pdfBytes, "l'original n'est jamais écrasé")

        m.replayCardsToReview()
        check(m.deck.map(\.id) == [2, 3] && m.cardRound == 2 && !m.cardsFinished && m.cardIndex == 0 && m.cardKnown.isEmpty && m.cards.count == 5, "paquet « à revoir » rejoué")
        m.flipCard(); m.markCard(known: true); m.flipCard(); m.markCard(known: true)
        check(m.cardsFinished && m.cardsScoreText == "2 sur 2" && m.cardsToReview.isEmpty, "série de rattrapage réussie")
        m.replayCardsToReview()
        check(m.cardsFinished && m.deck.count == 2, "rien à rejouer : inchangé")
        m.restartCards()
        check(m.deck.count == 5 && m.cardRound == 1 && !m.cardsFinished && m.cardKnown.isEmpty, "tout recommencer")
        m.newCards()
        check(m.cards.isEmpty && m.deck.isEmpty && m.currentCard == nil, "nouvelles cartes : retour au réglage")

        let failing = makeModel(exporter: FakeRevisionExporter(fail: true), dialogs: d)
        failing.open(pdf); failing.makeCards(); await failing.waitUntilIdle()
        d.saveURL = scratch.appendingPathComponent("y.pdf")
        failing.exportCardsPDF(); await failing.waitUntilIdle()
        check(failing.issue?.title == "Les cartes n'ont pas pu être enregistrées", "échec d'export expliqué")

        let other = makePDF("autre2.pdf")
        m.makeCards(); await m.waitUntilIdle()
        m.open(other)
        check(m.cards.isEmpty && m.deck.isEmpty && !m.cardsFinished, "nouveau document : cartes effacées")
    }

    section("Cartes : erreurs et annulation")
    do {
        let svc = FakeRevisionService()
        let m = makeModel(service: svc)
        m.open(pdf)
        svc.failNext = EngineError.network("x")
        m.makeCards(); await m.waitUntilIdle()
        check(m.issue?.title == "Les cartes n'ont pas pu être créées" && m.issue?.todo.contains("connexion") == true && m.cards.isEmpty, "erreur réseau expliquée")
        svc.failNext = EngineError.invalidResponse("x")
        m.makeCards(); await m.waitUntilIdle()
        check(m.issue?.what.contains("incomplète ou illisible") == true, "JSON invalide : message lisible")
        m.makeCards(); await m.waitUntilIdle()
        check(m.issue == nil && m.cards.count == 5, "réessai réussi efface l'erreur")
        let slow = FakeRevisionService(); slow.delayNanos = 80_000_000
        let m2 = makeModel(service: slow)
        m2.open(pdf); m2.makeCards()
        try? await Task.sleep(nanoseconds: 100_000_000)
        m2.cancel()
        check(!m2.isBusy && m2.notice == "Opération annulée.", "cartes : annulé")
        try? await Task.sleep(nanoseconds: 700_000_000)
        check(m2.cards.isEmpty && m2.issue == nil, "aucun résultat tardif")
        let apple = makeModel(status: apple)
        apple.open(pdf); apple.makeCards()
        check(!apple.isBusy && apple.cards.isEmpty, "moteur Apple : cartes impossibles")
    }

    print("\n\(passed) réussis, \(failed) échoués")
    exit(failed == 0 ? 0 : 1)
}

Task { @MainActor in await run() }
RunLoop.main.run()
