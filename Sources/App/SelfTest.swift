import Foundation
import AppKit
import PDFKit

/// Mode de test sans fenêtre ni clic :
///   Complete-Cours --selftest <entrée.pdf> <sortie.pdf> [--engine apple|claude] [--claude-url URL] [--no-humanize]
/// Il suit la chaîne de l'interface (analyse, complétion, écriture sur l'aperçu, export aplati), écrit un résumé JSON
/// sur la sortie standard (la progression va sur la sortie d'erreur) et quitte avec 0 (tout va bien) ou 1.
/// La clé Claude vient de la variable d'environnement CC_API_KEY, jamais d'un argument.
@MainActor
enum SelfTest {
    struct Options {
        var input: URL
        var output: URL
        var engine: EngineKind = .apple
        var claudeURL: URL?
        var humanize = true
    }

    static func runAndExit(_ args: [String]) -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let code = await run(args)
            fflush(stdout)
            exit(code)
        }
        dispatchMain()
    }

    static func run(_ args: [String]) async -> Int32 {
        let options: Options
        do { options = try parse(args) } catch {
            printJSON(["ok": false, "error": Fr.sentence(error.localizedDescription)])
            return 1
        }
        let key = ProcessInfo.processInfo.environment["CC_API_KEY"]
        if options.engine == .claude, (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            printJSON(["ok": false, "error": "Pour --engine claude, la clé doit être dans la variable d'environnement CC_API_KEY."])
            return 1
        }

        var settings = RunSettings.current()
        settings.engine = options.engine
        settings.humanize = options.humanize
        settings.flatten = true
        let defaults = UserDefaults(suiteName: "fr.complete-cours.selftest") ?? .standard
        defaults.removePersistentDomain(forName: "fr.complete-cours.selftest")
        let snapshot = settings
        let model = CoursModel(
            settings: { snapshot },
            engineFactory: { try EngineFactory.make($0, claudeKey: key, claudeBaseURL: options.claudeURL) },
            dialogs: SilentDialogs(),
            defaults: defaults)
        model.progressObserver = { fraction, label in
            FileHandle.standardError.write(Data("[\(Int(fraction * 100)) %] \(label)\n".utf8))
        }

        var summary: [String: Any] = [
            "engine": options.engine.rawValue,
            "input": options.input.path,
            "output": options.output.path,
        ]
        var problems: [String] = []

        // 1. ouverture et analyse
        await model.load(options.input)
        guard model.document != nil else {
            summary["ok"] = false
            summary["error"] = model.openError ?? "Le PDF n'a pas pu être ouvert."
            printJSON(summary)
            return 1
        }
        summary["pages"] = model.pageCount
        summary["zones"] = model.zones.count
        summary["pagesWithZones"] = model.zonePageCount
        summary["skippedPages"] = model.skippedPages.map { $0 + 1 }
        summary["summary"] = model.analysisSummary

        // 2. complétion, 3. écriture sur le document affiché
        await model.complete()
        if let problem = model.runProblem { problems.append(problem.message) }
        model.renderAnswers()
        summary["answered"] = model.answeredCount
        summary["humanized"] = model.zones.filter { $0.humanized }.count
        summary["overflow"] = model.zones.filter { $0.enabled && $0.overflow }.count
        let zoneErrors = model.zones.filter { $0.error != nil }
        // un même message pour plusieurs zones (panne de réseau sur une page…) n'est écrit qu'une fois
        var byMessage: [String: Int] = [:]
        for z in zoneErrors { byMessage[z.error ?? "", default: 0] += 1 }
        for (message, count) in byMessage.sorted(by: { $0.key < $1.key }) {
            problems.append("\(Fr.zones(count)) sans réponse : \(message)")
        }

        // 4. export aplati, puis relecture du résultat
        do {
            try await model.export(to: options.output)
            if let out = PDFDocument(url: options.output) {
                summary["outputOpens"] = true
                summary["outputPages"] = out.pageCount
                if out.pageCount != model.pageCount { problems.append("Le PDF enregistré n'a pas le même nombre de pages que l'original.") }
                var remaining = 0
                for i in 0..<out.pageCount { remaining += (out.page(at: i)?.annotations ?? []).filter { $0.type == "FreeText" }.count }
                summary["outputFreeTextAnnotations"] = remaining
            } else {
                summary["outputOpens"] = false
                problems.append("Le PDF enregistré ne se rouvre pas.")
            }
        } catch {
            problems.append("Enregistrement impossible : \(Fr.sentence(error.localizedDescription))")
        }

        summary["items"] = model.zones.map { z -> [String: Any] in
            var item: [String: Any] = [
                "page": z.page + 1, "number": z.number, "kind": z.kind.rawValue, "enabled": z.enabled,
                "answer": z.answer, "humanized": z.humanized, "overflow": z.overflow,
            ]
            if let e = z.error { item["error"] = e }
            return item
        }
        summary["problems"] = problems
        summary["ok"] = problems.isEmpty
        printJSON(summary)
        return problems.isEmpty ? 0 : 1
    }

    private static func parse(_ args: [String]) throws -> Options {
        guard let i = args.firstIndex(of: "--selftest") else { throw CoursError.message("Option --selftest manquante") }
        var rest = Array(args[(i + 1)...])
        guard rest.count >= 2, !rest[0].hasPrefix("--"), !rest[1].hasPrefix("--") else {
            throw CoursError.message("Usage : --selftest <entrée.pdf> <sortie.pdf> [--engine apple|claude] [--claude-url URL] [--no-humanize]")
        }
        var options = Options(input: URL(fileURLWithPath: rest[0]), output: URL(fileURLWithPath: rest[1]))
        rest.removeFirst(2)
        while !rest.isEmpty {
            let option = rest.removeFirst()
            switch option {
            case "--no-humanize":
                options.humanize = false
            case "--engine":
                guard let value = rest.first, let kind = EngineKind(rawValue: value) else {
                    throw CoursError.message("--engine demande « apple » ou « claude »")
                }
                rest.removeFirst()
                options.engine = kind
            case "--claude-url":
                guard let value = rest.first, let url = URL(string: value), url.scheme != nil else {
                    throw CoursError.message("--claude-url demande une adresse complète, par exemple http://127.0.0.1:8080")
                }
                rest.removeFirst()
                options.claudeURL = url
            default:
                throw CoursError.message("Option inconnue : \(option)")
            }
        }
        if options.input.standardizedFileURL == options.output.standardizedFileURL {
            throw CoursError.message("Le fichier de sortie doit être différent du fichier d'entrée.")
        }
        return options
    }

    private static func printJSON(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{\"ok\": false}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
