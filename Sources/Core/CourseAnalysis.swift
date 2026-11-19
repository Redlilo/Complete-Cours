import Foundation
import PDFKit
import Vision
import AppKit

// « Analyser les cours » et « Déposer un cours » : l'IA compare le contenu de chaque PDF à son emplacement.
// Seuls le nom et un court extrait de la première page partent vers l'IA ; les évaluations ne sont jamais lues
// (leur nom seul sert à les ranger).

struct CourseDigest: Equatable {
    var path: String            // chemin relatif au dossier des cours
    var isEvaluation: Bool
    var excerpt: String         // début de la page 1 (vide pour une évaluation)
    var zones = 0               // trous détectés (PDF de cours seulement)
    var remaining = 0           // dont encore sans réponse
    var isIncomplete = false
}

struct AnalysisSuggestion: Identifiable, Equatable {
    var path: String            // fichier concerné (relatif)
    var folder: String          // dossier de destination (relatif, « Maths/Cours »)
    var newName: String         // nouveau nom sans extension, vide = garder
    var reason: String
    var id: String { path }
}

enum CourseAnalysis {
    // MARK: Lecture locale

    /// Résumé d'un fichier, relu seulement s'il est nouveau ou modifié (taille ou date) depuis le journal.
    /// `force` : relit tout. `fromCache` dit si la lecture a été évitée.
    static func digest(_ file: LibraryFile, ledger: CourseLedger?, force: Bool = false) -> (digest: CourseDigest, fromCache: Bool) {
        if !force, let ledger, let hit = ledger.cachedDigest(for: file.url, relativePath: file.relativePath) { return (hit, true) }
        return (digest(file), false)
    }

    static func digest(_ file: LibraryFile) -> CourseDigest {
        var d = CourseDigest(path: file.relativePath, isEvaluation: file.isEvaluation, excerpt: "")
        guard !file.isEvaluation, file.url.pathExtension.lowercased() == "pdf" else { return d }
        d.excerpt = firstPageText(file.url)
        if let r = CompletionStatus.report(url: file.url) {
            d.zones = r.zones; d.remaining = r.remaining; d.isIncomplete = r.isIncomplete
        }
        return d
    }

    /// Début de la page 1 : couche texte, ou OCR pour un scan. 450 caractères suffisent à reconnaître la matière.
    static func firstPageText(_ url: URL, limit: Int = 450) -> String {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return "" }
        func norm(_ s: String) -> String {
            s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var text = norm(page.string ?? "")
        if text.count < 60 {
            let b = page.bounds(for: .mediaBox), k = 1800 / max(b.width, b.height)
            let img = page.thumbnail(of: CGSize(width: b.width * k, height: b.height * k), for: .mediaBox)
            if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate; req.recognitionLanguages = ["fr-FR", "en-US"]
                try? VNImageRequestHandler(cgImage: cg).perform([req])
                text = norm((req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " "))
            }
        }
        return String(text.prefix(limit))
    }

    /// Tous les dossiers (même vides), relatifs à la racine, sans les dossiers de travail « _ ».
    static func folderCatalog(root: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let n = root.standardizedFileURL.pathComponents.count
        var out: [String] = []
        for case let url as URL in walker {
            let parts = Array(url.standardizedFileURL.pathComponents.dropFirst(n))
            if parts.first?.hasPrefix("_") == true { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true, parts.count <= 3 {
                out.append(parts.joined(separator: "/"))
            }
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Demande à l'IA

    static let system = """
    Tu aides un élève de Seconde (bac pro MTNE, lycée Saint-Nicolas, Paris) à ranger ses cours. Les dossiers sont \
    « Matière / type ou chapitre » (ex. « Maths/Cours », « Histoire-Géographie/Thème 1 - … », « Atelier Professionnel/Chantier 2 - … »). \
    On te donne la liste des dossiers puis des fichiers avec le début de leur première page.

    Ne propose un changement que lorsque tu es sûr :
    - le contenu relève clairement d'une autre matière ou d'un autre chapitre que son dossier actuel ;
    - ou le nom du fichier contredit son contenu (ex. « secteur 4 » alors que le document est la « Séance 4 : Le Horla »).
    Si le fichier est bien rangé, ne dis rien à son sujet. Les évaluations (« contenu non lu ») se jugent sur le nom seul : \
    elles vont dans « <matière>/Évaluations » si ce dossier existe.
    "dossier" doit être un dossier de la liste, ou un sous-dossier nouveau dans une matière existante (jamais une nouvelle matière). \
    "nouveauNom" : vide si le nom est bon, sinon un nom court dans le style des autres fichiers, sans extension. \
    "raison" : une phrase en français. Réponds uniquement en JSON.
    """

    static var schema: [String: Any] {
        let s: [String: Any] = ["type": "string"]
        let item: [String: Any] = ["type": "object",
                                   "properties": ["chemin": s, "dossier": s, "nouveauNom": s, "raison": s],
                                   "required": ["chemin", "dossier", "nouveauNom", "raison"], "additionalProperties": false]
        return ["type": "object", "properties": ["propositions": ["type": "array", "items": item]],
                "required": ["propositions"], "additionalProperties": false]
    }

    static func userText(digests: [CourseDigest], folders: [String]) -> String {
        var t = "Dossiers existants :\n" + folders.map { "- " + $0 }.joined(separator: "\n") + "\n\nFichiers :\n"
        for d in digests {
            t += "• chemin : \(d.path)\n"
            t += d.isEvaluation ? "  (évaluation, contenu non lu)\n" : "  début : \(d.excerpt.isEmpty ? "(illisible)" : d.excerpt)\n"
        }
        return t
    }

    /// Lit la réponse ; ignore tout ce qui n'est pas un chemin connu ou un dossier plausible.
    static func parse(_ raw: Any, knownPaths: Set<String>, folders: [String]) -> [AnalysisSuggestion] {
        guard let root = raw as? [String: Any], let list = root["propositions"] as? [[String: Any]] else { return [] }
        let subjects = Set(folders.compactMap { $0.split(separator: "/").first.map(String.init) })
        var out: [AnalysisSuggestion] = []
        for item in list {
            let path = RevJSON.str(item["chemin"]), folder = RevJSON.str(item["dossier"])
            let name = RevJSON.str(item["nouveauNom"]).replacingOccurrences(of: "/", with: "-")
            guard knownPaths.contains(path), !folder.isEmpty, !folder.contains(".."),
                  let subject = folder.split(separator: "/").first.map(String.init), subjects.contains(subject) else { continue }
            let current = (path as NSString).deletingLastPathComponent
            if folder == current && name.isEmpty { continue }
            out.append(AnalysisSuggestion(path: path, folder: folder, newName: name, reason: RevJSON.str(item["raison"])))
        }
        return out
    }

    /// Une série de demandes (16 fichiers à la fois). `progress` reçoit la part faite, de 0 à 1.
    /// Avec un `ledger`, une demande déjà faite (mêmes extraits, mêmes dossiers) reprend la réponse gardée au lieu de rappeler l'IA.
    static func suggest(digests: [CourseDigest], folders: [String], generator: StructuredGenerator,
                        ledger: CourseLedger? = nil, useCache: Bool = true,
                        progress: @escaping (Double) -> Void) async throws -> [AnalysisSuggestion] {
        let known = Set(digests.map(\.path))
        var out: [AnalysisSuggestion] = []
        let chunks = stride(from: 0, to: digests.count, by: 16).map { Array(digests[$0..<min($0 + 16, digests.count)]) }
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let text = userText(digests: chunk, folders: folders)
            let key = CourseLedger.fingerprint(system, text)
            if useCache, let ledger, let kept = ledger.cachedAI(key), let parsed = try? RevJSON.parse(kept) {
                out += parse(parsed, knownPaths: known, folders: folders)
                progress(Double(i + 1) / Double(chunks.count))
                continue
            }
            let raw = try await generator.generate(system: system, userText: text, images: [], schema: schema)
            let parsed = try RevJSON.parse(raw)
            ledger?.storeAI(key, json: raw)
            out += parse(parsed, knownPaths: known, folders: folders)
            progress(Double(i + 1) / Double(chunks.count))
        }
        return out
    }

    // MARK: Déplacement

    /// Déplace sans jamais écraser : « Nom (2).pdf » si le nom existe déjà. Renvoie le nouvel emplacement.
    static func move(_ s: AnalysisSuggestion, root: URL, source explicitSource: URL? = nil) throws -> URL {
        let source = explicitSource ?? root.appendingPathComponent(s.path)
        let ext = source.pathExtension
        let base = s.newName.isEmpty ? source.deletingPathExtension().lastPathComponent : s.newName
        let dir = s.folder.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var target = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext); n += 1
        }
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }
}
