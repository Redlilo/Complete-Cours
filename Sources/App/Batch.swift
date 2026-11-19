import Foundation
import PDFKit

/// Compléter un PDF sans fenêtre : ouverture, analyse, réponses de l'IA, écriture sur l'aperçu, export aplati,
/// relecture du résultat. C'est LE chemin utilisé par le bouton « Compléter la sélection » (Analysis.swift)
/// et par `--selftest` (SelfTest.swift) : le test exerce donc le vrai code.
@MainActor
enum BatchCompleter {
    struct Result {
        var input: URL
        var output: URL
        var engineName = ""
        var pages = 0
        var zones = 0
        var pagesWithZones = 0
        var skippedPages: [Int] = []
        var analysisSummary = ""
        var answered = 0
        var humanized = 0
        var overflow = 0
        var outputOpens = false
        var outputPages = 0
        var outputFreeText = 0
        var items: [[String: Any]] = []
        /// Ce qui empêche d'avoir une copie correcte (PDF illisible, moteur en panne, enregistrement impossible…).
        var hardProblems: [String] = []
        /// Zones restées sans réponse : la copie existe mais elle est incomplète.
        var zoneProblems: [String] = []
        /// Erreur qui concerne tout le reste du lot (clé refusée, moteur indisponible, limite atteinte) : on arrête.
        var fatal = false
        /// La copie a été écrite à `output`.
        var written = false

        var problems: [String] { hardProblems + zoneProblems }
        var ok: Bool { problems.isEmpty && written }
    }

    /// « Cours (complétée).pdf », puis « Cours (complétée 2).pdf »… : un nom qui n'existe pas encore.
    static func copyURL(for url: URL) -> URL {
        let base = url.deletingPathExtension()
        let dir = base.deletingLastPathComponent()
        var out = dir.appendingPathComponent(base.lastPathComponent + " (complétée).pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = dir.appendingPathComponent("\(base.lastPathComponent) (complétée \(n)).pdf"); n += 1
        }
        return out
    }

    /// - `root` : dossier des cours, pour reconnaître une évaluation par son dossier ; sans lui, seul le nom du fichier compte.
    /// - `output` : par défaut la copie « (complétée) » à côté de l'original.
    /// - `allowOverwrite` : seulement pour un fichier de sortie choisi explicitement (--selftest) ; jamais pour le lot.
    /// - `keepOnProblems` : garde la copie même si elle est incomplète (--selftest, pour l'examiner).
    /// - `ledger` : si fourni, la complétion réussie y est inscrite.
    static func complete(url: URL, output: URL? = nil, root: URL? = nil,
                         settings: RunSettings,
                         engineFactory: @escaping (RunSettings) throws -> CompletionEngine = { try EngineFactory.make($0) },
                         defaultsSuite: String = "fr.complete-cours.batch",
                         allowOverwrite: Bool = false, keepOnProblems: Bool = false,
                         ledger: CourseLedger? = nil,
                         progress: @escaping (Double, String) -> Void = { _, _ in }) async -> Result {
        let out = output ?? copyURL(for: url)
        var r = Result(input: url, output: out, engineName: settings.engineDisplayName)
        let fm = FileManager.default

        // garde-fous : jamais d'évaluation, jamais d'écrasement
        let name = url.deletingPathExtension().lastPathComponent
        let isEval = root.flatMap { LibraryTree.makeFile(root: $0, url: url)?.isEvaluation } ?? LibraryTree.looksLikeEvaluation(name)
        if isEval { r.hardProblems.append("« \(name) » est une évaluation : elle n'est jamais complétée."); return r }
        guard fm.fileExists(atPath: url.path) else { r.hardProblems.append("Le fichier « \(name) » n'existe plus."); return r }
        // une évaluation au nom neutre se reconnaît à son en-tête (lecture locale de la première page seulement)
        if LibraryTree.headerLooksLikeEvaluation(CourseAnalysis.firstPageText(url)) {
            r.hardProblems.append("« \(name) » ressemble à une évaluation : elle n'est jamais complétée."); return r
        }
        if out.standardizedFileURL == url.standardizedFileURL { r.hardProblems.append("Le fichier de sortie doit être différent du fichier d'entrée."); return r }
        if fm.fileExists(atPath: out.path), !allowOverwrite {
            r.hardProblems.append("« \(out.lastPathComponent) » existe déjà : rien n'a été remplacé."); return r
        }

        var s = settings; s.flatten = true
        let snapshot = s
        let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
        defaults.removePersistentDomain(forName: defaultsSuite)
        let model = CoursModel(settings: { snapshot }, engineFactory: engineFactory, dialogs: SilentDialogs(), defaults: defaults)
        model.progressObserver = progress

        // 1. ouverture et analyse
        await model.load(url)
        if Task.isCancelled { r.hardProblems.append("Arrêté avant la fin de ce cours : aucune copie n'a été écrite."); return r }
        guard model.document != nil else {
            r.hardProblems.append(model.openError ?? "Le PDF n'a pas pu être ouvert."); return r
        }
        r.pages = model.pageCount
        r.zones = model.zones.count
        r.pagesWithZones = model.zonePageCount
        r.skippedPages = model.skippedPages.map { $0 + 1 }
        r.analysisSummary = model.analysisSummary

        // 2. réponses, 3. écriture sur le document affiché
        await model.complete()
        // « Arrêter » : ne jamais écrire une copie vide ou partielle
        if Task.isCancelled { r.hardProblems.append("Arrêté avant la fin de ce cours : aucune copie n'a été écrite."); return r }
        if let problem = model.runProblem { r.hardProblems.append(problem.message); r.fatal = problem.needsSettings }
        model.renderAnswers()
        r.answered = model.answeredCount
        r.humanized = model.zones.filter { $0.humanized }.count
        r.overflow = model.zones.filter { $0.enabled && $0.overflow }.count
        // un même message pour plusieurs zones (panne de réseau sur une page…) n'est écrit qu'une fois
        var byMessage: [String: Int] = [:]
        for z in model.zones where z.error != nil { byMessage[z.error ?? "", default: 0] += 1 }
        for (message, count) in byMessage.sorted(by: { $0.key < $1.key }) {
            r.zoneProblems.append("\(Fr.zones(count)) sans réponse : \(message)")
        }
        r.items = model.zones.map { z -> [String: Any] in
            var item: [String: Any] = ["page": z.page + 1, "number": z.number, "kind": z.kind.rawValue, "enabled": z.enabled,
                                       "answer": z.answer, "humanized": z.humanized, "overflow": z.overflow]
            if let e = z.error { item["error"] = e }
            return item
        }
        if r.hardProblems.isEmpty, r.zones == 0, !keepOnProblems { r.hardProblems.append("Aucun trou à remplir n'a été détecté dans ce PDF.") }
        if !r.hardProblems.isEmpty, !keepOnProblems { return r }

        // 4. export aplati dans un fichier caché voisin, relu, puis mis en place sans rien écraser
        let temp = out.deletingLastPathComponent().appendingPathComponent(".cc-\(UUID().uuidString).pdf")
        defer { try? fm.removeItem(at: temp) }
        do {
            try await model.export(to: temp)
            guard let doc = PDFDocument(url: temp) else {
                r.hardProblems.append("Le PDF enregistré ne se rouvre pas.")
                return r
            }
            r.outputOpens = true
            r.outputPages = doc.pageCount
            for i in 0..<doc.pageCount { r.outputFreeText += (doc.page(at: i)?.annotations ?? []).filter { $0.type == "FreeText" }.count }
            if doc.pageCount != model.pageCount { r.hardProblems.append("Le PDF enregistré n'a pas le même nombre de pages que l'original.") }
            if !r.hardProblems.isEmpty, !keepOnProblems { return r }
            if fm.fileExists(atPath: out.path) {
                guard allowOverwrite else { r.hardProblems.append("« \(out.lastPathComponent) » existe déjà : rien n'a été remplacé."); return r }
                try fm.removeItem(at: out)
            }
            try fm.moveItem(at: temp, to: out)       // échoue plutôt que d'écraser
            r.written = true
        } catch {
            r.hardProblems.append("Enregistrement impossible : \(Fr.sentence(error.localizedDescription))")
            return r
        }
        if r.hardProblems.isEmpty { ledger?.recordCompletion(original: url, copy: out, engine: r.engineName) }
        return r
    }
}
