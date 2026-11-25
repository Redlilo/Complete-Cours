import Foundation

// Fin d'un cours « Écouter un cours » : attendre les derniers morceaux audio et ne jamais sauter l'analyse finale.
// Logique pure (aucun micro, aucun réseau) pour pouvoir la tester avec de faux moteurs ; LectureModel l'utilise.

/// Suit les morceaux audio en cours de transcription, cours par cours, et permet d'attendre qu'ils soient finis (avec un délai maximal).
@MainActor
final class LectureAttente {
    private var enCours: [UUID: Int] = [:]

    func nombre(_ cours: UUID) -> Int { enCours[cours] ?? 0 }
    var total: Int { enCours.values.reduce(0, +) }

    /// Lance une transcription suivie ; `apres` est appelé quand elle est finie (le compteur est déjà à jour).
    func suivre(_ cours: UUID, _ travail: @escaping @MainActor () async -> Void, apres: (@MainActor () -> Void)? = nil) {
        enCours[cours, default: 0] += 1
        Task { @MainActor in
            await travail()
            let n = (self.enCours[cours] ?? 1) - 1
            if n <= 0 { self.enCours[cours] = nil } else { self.enCours[cours] = n }
            apres?()
        }
    }

    /// Attend la fin des morceaux de ce cours. Renvoie false si le délai maximal est dépassé (on ne bloque jamais « Terminer »).
    func attendreFin(_ cours: UUID, delaiMax: Duration, pas: Duration = .milliseconds(50)) async -> Bool {
        let limite = ContinuousClock.now + delaiMax
        while nombre(cours) > 0 {
            if ContinuousClock.now >= limite { return false }
            try? await Task.sleep(for: pas)
        }
        return true
    }
}

/// Une seule analyse à la fois ; une demande « finale » faite pendant qu'une autre tourne attend la fin de celle-ci puis se lance (au lieu d'être sautée).
@MainActor
final class LectureAnalyseSerie {
    private(set) var enCours = false
    private(set) var enAttente = false
    private(set) var lancees = 0
    private let executer: @MainActor () async -> Void
    /// Faux s'il n'y a rien (de nouveau) à analyser.
    private let aAnalyser: @MainActor () -> Bool

    init(aAnalyser: @escaping @MainActor () -> Bool = { true }, executer: @escaping @MainActor () async -> Void) {
        self.aAnalyser = aAnalyser; self.executer = executer
    }

    /// Demande ordinaire : ignorée si une analyse tourne déjà. Renvoie true si elle démarre.
    @discardableResult
    func demander() -> Bool {
        guard !enCours, aAnalyser() else { return false }
        demarrer()
        return true
    }

    /// Demande finale : si une analyse tourne, une nouvelle partira juste après (une seule, même si on insiste).
    func demanderFinale() {
        if enCours { enAttente = true; return }
        _ = demander()
    }

    /// Annule les demandes en attente (nouveau cours).
    func reinitialiser() { enAttente = false }

    private func demarrer() {
        enCours = true; lancees += 1
        Task { @MainActor in
            await executer()
            enCours = false
            if enAttente { enAttente = false; _ = demander() }
        }
    }
}

enum LectureFin {
    /// Délai maximal d'attente des derniers morceaux à la fin du cours (au-delà, on termine avec ce qu'on a ; la fin arrive ensuite toute seule).
    static let delaiMaxMorceaux: Duration = .seconds(180)

    /// Le dossier audio d'un cours s'appelle « ecoute-<id du cours> » : retrouve le cours d'un morceau (nil si inconnu).
    static func cours(deMorceau url: URL) -> UUID? {
        let nom = url.deletingLastPathComponent().lastPathComponent
        guard nom.hasPrefix("ecoute-") else { return nil }
        return UUID(uuidString: String(nom.dropFirst("ecoute-".count)))
    }
}
