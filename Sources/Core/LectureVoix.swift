import Foundation

// « Écouter un cours » : reconnaître la voix du prof parmi les élèves.
// Au premier cours d'un prof, l'app retient la voix qui parle le plus (c'est le prof), la garde sur le Mac, puis la
// retrouve toute seule aux cours suivants. Seule la voix du PROF est gardée : les empreintes des élèves ne sont jamais
// enregistrées (elles ne servent que le temps du calcul, en mémoire). Le calcul des empreintes est fait par l'outil
// optionnel « voice.py » de l'app Écoute-Cours (Python) : s'il est absent, la reconnaissance est simplement désactivée.

enum LectureQui: String, Codable {
    case prof, autre, incertain
    var libelle: String {
        switch self { case .prof: return "prof"; case .autre: return "élève ?"; case .incertain: return "incertain" }
    }
}

/// Voix mémorisée d'un prof : un vecteur de 256 nombres, rien d'autre (pas d'audio).
struct LectureEmpreinte: Codable, Equatable {
    var vecteur: [Float]
    var secondes: Double      // quantité de voix déjà retenue (sert à savoir si la voix est « apprise »)
    var maj: Date
}

enum LectureVoix {
    static let seuilProf: Float = 0.75
    static let seuilAutre: Float = 0.70
    /// Au-delà de cette durée de voix retenue, l'empreinte est considérée comme apprise et ne bouge plus.
    static let secondesPourApprendre = 600.0
    /// Il faut au moins cela de voix commune pour décider qui est le prof.
    static let secondesMinimum = 30.0

    struct Aide { let python: URL; let script: URL }

    /// Là où l'app installe elle-même la reconnaissance de la voix (bouton dans les réglages de l'écoute).
    static var dossierInstallation: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Complete-Cours", isDirectory: true)
            .appendingPathComponent("Voix", isDirectory: true)
    }

    /// L'outil de calcul des empreintes : celui installé par l'app ; dans la version personnelle seulement, aussi celui indiqué par
    /// ECOUTE_VOIX_DIR et celui d'Écoute-Cours. La version distribuée n'exécute jamais un Python venu d'ailleurs que de son propre dossier.
    static func aide() -> Aide? {
        var dossiers: [URL] = [dossierInstallation]
        #if COMPTE_PERSO
        if let d = ProcessInfo.processInfo.environment["ECOUTE_VOIX_DIR"] { dossiers.append(URL(fileURLWithPath: d)) }
        dossiers.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Projets/Ecoute-Cours/app"))
        #endif
        for d in dossiers {
            let py = d.appendingPathComponent("venv/bin/python3"), sc = d.appendingPathComponent("voice.py")
            if FileManager.default.isExecutableFile(atPath: py.path), FileManager.default.fileExists(atPath: sc.path) {
                return Aide(python: py, script: sc)
            }
        }
        return nil
    }
    static var disponible: Bool { aide() != nil }

    static func qui(score: Float) -> LectureQui {
        score >= seuilProf ? .prof : (score < seuilAutre ? .autre : .incertain)
    }

    static func cosinus(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var d: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return d / ((na.squareRoot() * nb.squareRoot()) + 1e-9)
    }

    private static func normaliser(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    // MARK: Calcul des empreintes (outil Python, hors du fil principal)

    static func convertirEn16k(_ source: URL) throws -> URL {
        let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voix-\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", source.path, dest.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw LectureErreur.transcription("conversion de l'audio impossible") }
        return dest
    }

    /// Une empreinte par segment (nil si le segment est trop court). `wav` : 16 kHz, mono.
    static func empreintes(wav: URL, segments: [(debut: Double, fin: Double)]) throws -> [[Float]?] {
        guard let aide = aide(), !segments.isEmpty else { return segments.map { _ in nil } }
        let fichier = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("segments-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fichier) }
        let json = segments.map { ["s": max(0, $0.debut), "e": max($0.debut, $0.fin)] }
        try JSONSerialization.data(withJSONObject: json).write(to: fichier)
        let p = Process(), sortie = Pipe(), erreur = Pipe()
        p.executableURL = aide.python
        p.arguments = [aide.script.path, "embed", wav.path, fichier.path]
        p.standardOutput = sortie; p.standardError = erreur
        try p.run()
        let data = sortie.fileHandleForReading.readDataToEndOfFile()   // lire avant d'attendre : la sortie est volumineuse
        p.waitUntilExit()
        guard p.terminationStatus == 0, let tableau = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            let msg = String(data: erreur.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .split(separator: "\n").last.map(String.init) ?? "code \(p.terminationStatus)"
            throw LectureErreur.transcription("reconnaissance de la voix : \(msg)")
        }
        return tableau.map { ($0 as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue } }
    }

    // MARK: Apprentissage (premières écoutes)

    /// Une phrase candidate pour retrouver la voix du prof : son empreinte, sa durée, et ce qu'elle dit (indice de LectureTexte.indiceProf).
    struct Candidat {
        var vecteur: [Float]
        var duree: Double
        var indice: Float = 0.5
    }

    /// Décide qui parle en combinant la voix et ce qui est dit. Sans voix mesurable (phrase trop courte, voix pas encore apprise),
    /// le texte seul décide, avec prudence. Une consigne claire du prof n'est jamais écartée toute seule à cause de la voix.
    static func decider(score: Float?, indice: Float) -> LectureQui {
        guard let s = score else { return indice >= 0.75 ? .prof : (indice <= 0.25 ? .autre : .incertain) }
        switch qui(score: s) {
        case .incertain: return indice >= 0.55 ? .prof : (indice <= 0.4 ? .autre : .incertain)
        case .autre: return indice >= 0.8 ? .incertain : .autre
        case .prof: return indice <= 0.1 ? .incertain : .prof
        }
    }

    /// Cherche la voix dominante : celle de la plus grande part du temps de parole, en comptant davantage ce qui ressemble à des
    /// paroles de prof. Renvoie l'empreinte du prof, fusionnée avec l'ancienne si c'est la même voix ; nil s'il n'y a pas
    /// assez de voix, ou si ce n'est pas la même voix.
    static func apprendre(candidats: [Candidat], existante: LectureEmpreinte?, maintenant: Date = Date()) -> LectureEmpreinte? {
        let c = candidats.filter { $0.duree > 0 && !$0.vecteur.isEmpty }
        guard !c.isEmpty else { return nil }
        func poids(_ x: Candidat) -> Double { x.duree * (0.5 + Double(x.indice)) }
        let totalPondere = c.reduce(0) { $0 + poids($1) }
        var meilleur = -1, meilleurPondere = 0.0
        for i in c.indices {
            var w = 0.0
            for j in c.indices where cosinus(c[i].vecteur, c[j].vecteur) >= seuilProf { w += poids(c[j]) }
            if w > meilleurPondere { meilleurPondere = w; meilleur = i }
        }
        guard meilleur >= 0 else { return nil }
        let membres = c.indices.filter { cosinus(c[meilleur].vecteur, c[$0].vecteur) >= seuilProf }
        let secondes = membres.reduce(0) { $0 + c[$1].duree }
        guard secondes >= secondesMinimum, meilleurPondere >= 0.4 * totalPondere else { return nil }
        var somme = [Float](repeating: 0, count: c[meilleur].vecteur.count)
        for j in membres { for k in somme.indices { somme[k] += c[j].vecteur[k] * Float(c[j].duree) } }
        let centre = normaliser(somme)
        guard let e = existante else { return LectureEmpreinte(vecteur: centre, secondes: secondes, maj: maintenant) }
        guard cosinus(e.vecteur, centre) >= seuilProf else { return nil }   // une autre voix : on ne touche pas à l'empreinte
        let ancien = Float(min(e.secondes, secondesPourApprendre)), nouveau = Float(secondes)
        let fusion = normaliser(zip(e.vecteur, centre).map { $0 * ancien + $1 * nouveau })
        return LectureEmpreinte(vecteur: fusion, secondes: e.secondes + secondes, maj: maintenant)
    }
}
