import Foundation
import PDFKit

// Premier vrai essai du moteur « Claude (mon compte) » : fait passer UNE page d'un PDF dans le vrai programme Claude Code et
// affiche les réponses. À lancer par l'élève, une fois connecté (bouton « Me connecter » des réglages, ou `claude auth login`).
// ATTENTION : cet essai consomme un peu du quota de ton abonnement Claude.
//
//   live <fichier.pdf> <page> [--model opus|sonnet|haiku] [--effort low|medium|high] [--cli chemin] [--sans-humanisation]
//
// Compilation : Tools/Tests/ClaudeCode/run.sh --live   (donne build/claudecode/live)
// Le PDF n'est jamais modifié ; rien n'est écrit sur le disque.

#if COMPTE_PERSO

@main
struct LiveTool {
    static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }

    static func usage() {
        print("""
        Usage : live <fichier.pdf> <page> [--model opus|sonnet|haiku] [--effort low|medium|high] [--cli chemin] [--sans-humanisation]
          page : numéro de la page, en commençant à 1.
          Cet essai envoie la page à ton compte Claude : il consomme un peu de ton quota d'abonnement.
        """)
    }

    static func main() async {
        var positional: [String] = []
        var model = ClaudeCodeEngine.defaultModel
        var effort = ClaudeCodeEngine.defaultEffort
        var cliPath: String?
        var humanize = true
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--model": model = it.next() ?? model
            case "--effort": effort = it.next() ?? effort
            case "--cli": cliPath = it.next()
            case "--sans-humanisation": humanize = false
            case "-h", "--help", "--aide": usage(); exit(0)
            default: positional.append(a)
            }
        }
        guard positional.count == 2, let pageNumber = Int(positional[1]), pageNumber >= 1 else { usage(); exit(2) }
        let url = URL(fileURLWithPath: (positional[0] as NSString).expandingTildeInPath)
        guard let doc = PDFDocument(url: url) else { fail("Impossible d'ouvrir ce PDF : \(url.lastPathComponent)") }
        guard pageNumber <= doc.pageCount, let page = doc.page(at: pageNumber - 1) else {
            fail("Ce PDF a \(doc.pageCount) page(s) : la page \(pageNumber) n'existe pas.")
        }

        print("Moteur : \(ClaudeCodeEngine.engineName) — cet essai consomme un peu du quota de ton abonnement Claude.")
        if let reason = await ClaudeCodeEngine.unavailabilityReason(cliOverride: cliPath) { fail(reason) }
        guard let cli = ClaudeCodeEngine.locateCLI(override: cliPath) else { fail(ClaudeCodeEngine.missingMessage) }
        let version = await ClaudeCodeEngine.version(of: cli) ?? "?"
        let status = await ClaudeCodeEngine.status(cli: cli)
        print("Claude Code \(version) — \(status.summary)")
        let engine = ClaudeCodeEngine(cli: cli, model: model, effort: effort)

        let analysis = ZoneDetector.analyze(page: page, index: pageNumber - 1, firstID: 1, needText: false)
        guard !analysis.zones.isEmpty else { fail("Aucune zone à remplir détectée sur cette page.") }
        guard let jpeg = MarkedImage.make(page: page, zones: analysis.zones) else { fail("Impossible de dessiner la page.") }
        print("Page \(pageNumber)/\(doc.pageCount) de « \(url.deletingPathExtension().lastPathComponent) » : \(analysis.zones.count) zone(s). Envoi à Claude…")
        let request = PageRequest(documentName: url.deletingPathExtension().lastPathComponent, pageNumber: pageNumber,
                                  pageCount: doc.pageCount, transcript: analysis.transcript, hasTextLayer: analysis.hasTextLayer,
                                  zones: analysis.zones, markedImageJPEG: jpeg, student: StudentProfile(), todayText: Prompts.todayText())

        let start = Date()
        let answers: [ZoneAnswer]
        do { answers = try await engine.complete(request) } catch {
            fail("Échec : \((error as? EngineError)?.errorDescription ?? error.localizedDescription)")
        }
        print(String(format: "Réponse reçue en %.1f s.\n", Date().timeIntervalSince(start)))
        for a in answers {
            let context = analysis.zones.first { $0.number == a.number }?.shortContext ?? ""
            print("⟦\(a.number)⟧ [\(a.kind.label)] « \(a.text) »" + (context.isEmpty ? "" : "\n      contexte : \(context)"))
        }

        guard humanize else { return }
        let items: [HumanizeItem] = answers.compactMap { a in
            guard a.kind.isHumanizable, !a.text.isEmpty, let z = analysis.zones.first(where: { $0.number == a.number }) else { return nil }
            return HumanizeItem(id: z.id, kind: a.kind, question: z.contextBefore, answer: a.text, maxChars: z.capacity)
        }
        guard !items.isEmpty else { print("\nRien à humaniser sur cette page (seules les questions ouvertes le sont)."); return }
        print("\nHumanisation de \(items.count) réponse(s)…")
        let t1 = Date()
        do {
            let result = try await engine.humanize(items)
            print(String(format: "Terminé en %.1f s.\n", Date().timeIntervalSince(t1)))
            for it in items {
                print("avant : « \(it.answer) »\naprès : « \(result[it.id] ?? it.answer) »" + (result[it.id] == nil ? "  (gardée telle quelle)" : "") + "\n")
            }
        } catch {
            fail("Humanisation échouée : \((error as? EngineError)?.errorDescription ?? error.localizedDescription)")
        }
    }
}

#else

@main
struct LiveTool {
    static func main() {
        FileHandle.standardError.write(Data("Cet outil se compile avec -D COMPTE_PERSO (voir run.sh --live).\n".utf8))
        exit(2)
    }
}

#endif
