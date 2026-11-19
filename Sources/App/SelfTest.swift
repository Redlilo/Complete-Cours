import Foundation
import AppKit
import PDFKit

/// Mode de test sans fenêtre ni clic :
///   Complete-Cours --selftest <entrée.pdf> <sortie.pdf> [--engine apple|claude|claudeCode] [--claude-url URL] [--no-humanize]
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
        let claudeURL = options.claudeURL
        // Le même code que le bouton « Compléter la sélection » (Batch.swift) ; seules la sortie choisie
        // (qui peut être remplacée) et la conservation d'une copie incomplète (pour l'examiner) diffèrent.
        let r = await BatchCompleter.complete(
            url: options.input, output: options.output, settings: settings,
            engineFactory: { try EngineFactory.make($0, claudeKey: key, claudeBaseURL: claudeURL) },
            defaultsSuite: "fr.complete-cours.selftest", allowOverwrite: true, keepOnProblems: true,
            progress: { fraction, label in FileHandle.standardError.write(Data("[\(Int(fraction * 100)) %] \(label)\n".utf8)) })

        var summary: [String: Any] = [
            "engine": options.engine.rawValue,
            "input": options.input.path,
            "output": options.output.path,
        ]
        if r.pages > 0 {
            summary["pages"] = r.pages
            summary["zones"] = r.zones
            summary["pagesWithZones"] = r.pagesWithZones
            summary["skippedPages"] = r.skippedPages
            summary["summary"] = r.analysisSummary
            summary["answered"] = r.answered
            summary["humanized"] = r.humanized
            summary["overflow"] = r.overflow
            summary["outputOpens"] = r.outputOpens
            if r.outputOpens {
                summary["outputPages"] = r.outputPages
                summary["outputFreeTextAnnotations"] = r.outputFreeText
            }
            summary["items"] = r.items
            summary["problems"] = r.problems
            summary["ok"] = r.ok
        } else {
            summary["ok"] = false
            summary["error"] = r.problems.first ?? "Le PDF n'a pas pu être ouvert."
        }
        printJSON(summary)
        return summary["ok"] as? Bool == true ? 0 : 1
    }

    private static func parse(_ args: [String]) throws -> Options {
        guard let i = args.firstIndex(of: "--selftest") else { throw CoursError.message("Option --selftest manquante") }
        var rest = Array(args[(i + 1)...])
        guard rest.count >= 2, !rest[0].hasPrefix("--"), !rest[1].hasPrefix("--") else {
            throw CoursError.message("Usage : --selftest <entrée.pdf> <sortie.pdf> [--engine apple|claude|claudeCode] [--claude-url URL] [--no-humanize]")
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
                    throw CoursError.message("--engine demande « apple », « claude » ou « claudeCode » (variante personnelle)")
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
