import Foundation

// Dépôt automatique : surveillance d'un dossier (Téléchargements…) et rangement des nouveaux PDF de cours.
// Tout est testable avec des dossiers temporaires (Tools/Tests/Watcher) ; l'interface est dans Sources/App/AutoIntake.swift.

/// Ce qu'est devenu un fichier pris en charge par le surveillant.
enum IntakeOutcome: Equatable {
    case filed            // rangé : ne plus jamais le retraiter
    case notACourse       // pas un cours : il reste où il est, on n'y touche plus
    case unavailable      // IA indisponible : rien déplacé, il attend
    case failed           // erreur (disque, droits…) : il reste, on ne réessaie pas en boucle
}

/// Surveille un dossier (premier niveau seulement) et confie chaque nouveau PDF terminé à `handler`, une seule fois.
final class FolderWatcher: @unchecked Sendable {
    struct State: Codable {
        var since: Date?
        var processed: [String] = []       // clés « chemin|taille|date »
    }

    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload"]

    let folder: URL
    let stateURL: URL?
    let stableSeconds: TimeInterval
    let pollInterval: TimeInterval
    private let handler: @Sendable (URL) async -> IntakeOutcome

    private let lock = NSLock()
    private var state = State()
    private var deferred = Set<String>()
    private var candidates: [String: (size: Int64, mtime: Double, since: Date)] = [:]
    private var inFlight = Set<String>()
    private var scanning = false
    private var timer: DispatchSourceTimer?
    private var source: DispatchSourceFileSystemObject?
    private var running = false
    private var lastActivityDate: Date?

    init(folder: URL, stateURL: URL? = nil, stableSeconds: TimeInterval = 3, pollInterval: TimeInterval = 1,
         handler: @escaping @Sendable (URL) async -> IntakeOutcome) {
        self.folder = folder.standardizedFileURL
        self.stateURL = stateURL
        self.stableSeconds = stableSeconds
        self.pollInterval = pollInterval
        self.handler = handler
        loadState()
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    /// Fichiers qui attendent (IA indisponible).
    var deferredCount: Int { lock.lock(); defer { lock.unlock() }; return deferred.count }
    var activatedAt: Date? { lock.lock(); defer { lock.unlock() }; return state.since }
    var lastActivity: Date? { lock.lock(); defer { lock.unlock() }; return lastActivityDate }

    // MARK: Démarrage / arrêt

    /// `freshActivation` : l'élève vient d'activer le dépôt, seuls les fichiers apparus à partir de maintenant comptent.
    /// Sinon (relance de l'app avec le dépôt déjà actif) : on garde la date d'activation, et le balayage de
    /// rattrapage traite les PDF apparus depuis, pendant que l'app était fermée.
    func start(freshActivation: Bool, now: Date = Date()) {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        if freshActivation || state.since == nil {
            state.since = now
            state.processed = []
        }
        deferred = []; candidates = [:]
        saveLocked()
        lock.unlock()

        let fd = open(folder.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend],
                                                                queue: DispatchQueue(label: "cours.watcher.fs"))
            src.setEventHandler { [weak self] in Task { await self?.scan() } }
            src.setCancelHandler { close(fd) }
            src.resume()
            lock.lock(); source = src; lock.unlock()
        }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "cours.watcher.timer"))
        t.schedule(deadline: .now() + 0.05, repeating: pollInterval)
        t.setEventHandler { [weak self] in Task { await self?.scan() } }
        t.resume()
        lock.lock(); timer = t; lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false
        timer?.cancel(); timer = nil
        source?.cancel(); source = nil
        candidates = [:]
        lock.unlock()
    }

    /// Les fichiers mis en attente (IA indisponible) seront retentés au prochain balayage.
    func retryDeferred() { lock.lock(); deferred = []; lock.unlock() }

    // MARK: Balayage

    /// Un passage : repère les nouveaux PDF, vérifie qu'ils sont terminés, les confie au `handler`.
    func scan(now: Date = Date()) async {
        guard let since = beginScan() else { return }
        defer { sync { scanning = false } }

        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        var live = Set<String>()
        for name in names.sorted() {
            if !isRunning { return }   // désactivé en cours de balayage : on ne range plus rien
            guard let url = acceptable(name) else { continue }
            let path = url.path
            live.insert(path)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { continue }
            let created = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) ?? now
            // seulement ce qui est apparu depuis l'activation
            if created < since { continue }
            let key = Self.key(path, size, mtime)
            let ready = checkReady(path: path, key: key, size: size, mtime: mtime, now: now)
            guard ready, Self.looksComplete(url) else { continue }
            sync { inFlight.insert(key); candidates[path] = nil }

            let outcome = await handler(url)

            sync {
                inFlight.remove(key)
                switch outcome {
                case .filed, .notACourse, .failed:
                    state.processed.append(key)
                    if state.processed.count > 500 { state.processed.removeFirst(state.processed.count - 500) }
                    if outcome == .filed { lastActivityDate = Date() }
                    saveLocked()
                case .unavailable: deferred.insert(key)
                }
            }
        }
        sync { candidates = candidates.filter { live.contains($0.key) } }
    }

    private func sync<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    private func beginScan() -> Date? {
        sync {
            guard running, !scanning, let since = state.since else { return nil }
            scanning = true
            return since
        }
    }

    /// Vrai quand le fichier n'est pas déjà traité et que sa taille et sa date n'ont pas bougé depuis `stableSeconds`.
    private func checkReady(path: String, key: String, size: Int64, mtime: Double, now: Date) -> Bool {
        sync {
            if state.processed.contains(key) || deferred.contains(key) || inFlight.contains(key) { return false }
            if let c = candidates[path], c.size == size, c.mtime == mtime {
                return now.timeIntervalSince(c.since) >= stableSeconds
            }
            candidates[path] = (size, mtime, now)       // nouveau, ou encore en train de grandir
            return false
        }
    }

    /// Garde-fous : un PDF visible, ordinaire (ni dossier, ni alias), directement dans le dossier surveillé, pas un téléchargement.
    private func acceptable(_ name: String) -> URL? {
        guard !name.hasPrefix("."), !name.contains("/") else { return nil }
        let url = folder.appendingPathComponent(name)
        guard url.pathExtension.lowercased() == "pdf",
              !Self.partialExtensions.contains(url.pathExtension.lowercased()),
              url.deletingLastPathComponent().standardizedFileURL.path == folder.path,
              let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              v.isRegularFile == true, v.isSymbolicLink != true else { return nil }
        return url
    }

    /// Un PDF terminé finit par « %%EOF » (un téléchargement coupé ou en cours d'écriture, non).
    static func looksComplete(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size > 8 else { return false }
        try? h.seek(toOffset: size > 2048 ? size - 2048 : 0)
        guard let tail = try? h.readToEnd() else { return false }
        return String(decoding: tail, as: UTF8.self).contains("%%EOF")
    }

    static func key(_ path: String, _ size: Int64, _ mtime: Double) -> String { "\(path)|\(size)|\(Int(mtime))" }

    // MARK: État sur disque

    private func loadState() {
        guard let stateURL, let data = try? Data(contentsOf: stateURL) else { return }
        let d = JSONDecoder()
        if let s = try? d.decode(State.self, from: data) { state = s }
    }

    private func saveLocked() {
        guard let stateURL else { return }
        let e = JSONEncoder()
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? e.encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }
}

// MARK: - Rangement d'un PDF déposé

enum IntakeResult: Equatable {
    case filed(record: MoveRecord, folder: String, name: String)
    case notACourse
    case unavailable
    case failed(String)

    var outcome: IntakeOutcome {
        switch self {
        case .filed: return .filed
        case .notACourse: return .notACourse
        case .unavailable: return .unavailable
        case .failed: return .failed
        }
    }
}

/// Lit la première page, demande à l'IA (cours ou pas ? quel dossier ?) et déplace, avec journal, sans jamais écraser.
enum AutoIntakeProcessor {
    static let system = CourseAnalysis.system + """

    C'est un NOUVEAU fichier arrivé dans le dossier Téléchargements : propose toujours un dossier s'il s'agit d'un cours. \
    "estUnCours" : true seulement pour un document scolaire (cours, fiche, exercices, évaluation) ; false pour tout le reste \
    (facture, billet, document administratif, photo, formulaire personnel…). Si "estUnCours" est false, laisse "propositions" vide.
    """

    static var schema: [String: Any] {
        var s = CourseAnalysis.schema
        var props = (s["properties"] as? [String: Any]) ?? [:]
        props["estUnCours"] = ["type": "boolean"]
        s["properties"] = props
        s["required"] = ["estUnCours", "propositions"]
        return s
    }

    /// En-tête qui annonce une évaluation (source unique : LibraryTree).
    static func headerLooksLikeEvaluation(_ excerpt: String) -> Bool { LibraryTree.headerLooksLikeEvaluation(excerpt) }

    static func process(_ url: URL, watchedFolder: URL, root: URL, ledger: CourseLedger,
                        generator: StructuredGenerator?) async -> IntakeResult {
        let src = url.standardizedFileURL
        guard src.deletingLastPathComponent().path == watchedFolder.standardizedFileURL.path,
              src.pathExtension.lowercased() == "pdf" else { return .failed("Ce fichier n'est pas dans le dossier surveillé.") }
        guard let generator else { return .unavailable }
        let name = src.deletingPathExtension().lastPathComponent
        // une évaluation (nom, puis en-tête) est rangée d'après son nom : son contenu n'est jamais envoyé à l'IA
        var isEval = LibraryTree.looksLikeEvaluation(name)
        var excerpt = ""
        if !isEval {
            excerpt = CourseAnalysis.firstPageText(src)
            if headerLooksLikeEvaluation(excerpt) { isEval = true; excerpt = "" }
        }
        // document personnel (facture, papiers d'identité, IBAN, e-mail…) : jamais envoyé à l'IA, laissé où il est
        if !isEval, PrivacyGate.looksPersonal(name: name, excerpt: excerpt) { return .notACourse }
        let folders = CourseAnalysis.folderCatalog(root: root)
        let digest = CourseDigest(path: "À ranger/\(src.lastPathComponent)", isEvaluation: isEval, excerpt: excerpt)
        let raw: String
        do {
            raw = try await generator.generate(system: system, userText: CourseAnalysis.userText(digests: [digest], folders: folders),
                                               images: [], schema: schema)
        } catch { return .unavailable }
        guard let parsed = try? RevJSON.parse(raw), let dict = parsed as? [String: Any],
              let isCourse = dict["estUnCours"] as? Bool else { return .failed("Réponse de l'IA illisible.") }
        if !isCourse && !isEval { return .notACourse }
        // pas de dossier convenable : le fichier reste où il est (jamais de nouvelle « matière » inventée)
        guard var suggestion = CourseAnalysis.parse(parsed, knownPaths: [digest.path], folders: folders, evaluationPaths: isEval ? [digest.path] : []).first else {
            return .failed("Aucun dossier convenable : le fichier reste où il est.")
        }
        // un nom de scan (« Scan2026… », « IMG_… ») est remplacé ; un nom choisi par l'élève est gardé
        let junk = name.range(of: "^(scan|img|image|document|sans titre|untitled)[ _-]*\\d", options: [.regularExpression, .caseInsensitive]) != nil
        if !junk { suggestion.newName = "" }
        do {
            let to = try CourseAnalysis.move(suggestion, root: root, source: src, sourceIsEvaluation: isEval)
            let record = ledger.recordMove(from: src, to: to, origin: .depot)
            return .filed(record: record, folder: suggestion.folder, name: to.lastPathComponent)
        } catch { return .failed(error.localizedDescription) }
    }
}


/// Filtre local avant tout envoi à l'IA depuis un dossier partagé comme Téléchargements : un document qui ressemble à
/// une pièce personnelle n'est pas lu plus loin et n'est jamais envoyé.
enum PrivacyGate {
    private static let patterns = [
        "\\b[a-z]{2}\\d{2}(?:\\s?[a-z0-9]{4}){3,}\\b",                          // IBAN
        "[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}",                                  // e-mail
        "(?:\\+33|\\b0)\\s?[1-9](?:[\\s.]?\\d{2}){4}\\b",                          // téléphone
        "\\b(facture|releve de compte|bulletin de paie|bulletin de salaire|avis d.imposition|passeport|carte d.identite|carte nationale|ordonnance|securite sociale|e-?billet|billet|reservation|devis|attestation|contrat|certificat medical)\\b",
    ]
    static func looksPersonal(name: String, excerpt: String) -> Bool {
        let text = CostEstimate.fold(name + " " + excerpt)
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}
