import Foundation

/// Moteur de test : répond sans réseau ni IA, avec des comportements réglables (lenteur, pages en échec,
/// clé refusée). Il garde les requêtes reçues pour que les tests puissent les examiner.
final class FakeEngine: CompletionEngine, @unchecked Sendable {
    let displayName: String
    let usesImages: Bool
    let maxConcurrentPages = 1

    var delayPerPage: TimeInterval = 0
    var failPages: Set<Int> = []                 // numéros de page (1 = première) qui échouent
    var failWithAuth = false
    var ignoreZoneNumbers: Set<Int> = []         // zones que le moteur déclare « à ignorer »
    var humanizeEnabled = true
    var answerPrefix = "réponse"

    private let lock = NSLock()
    private var _requests: [PageRequest] = []
    private var _humanizeCalls = 0

    var requests: [PageRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var humanizeCalls: Int { lock.lock(); defer { lock.unlock() }; return _humanizeCalls }

    init(name: String = "Moteur de test", usesImages: Bool = true) {
        self.displayName = name
        self.usesImages = usesImages
    }

    private func record(_ request: PageRequest) { lock.lock(); _requests.append(request); lock.unlock() }
    private func countHumanize() { lock.lock(); _humanizeCalls += 1; lock.unlock() }

    func complete(_ request: PageRequest) async throws -> [ZoneAnswer] {
        record(request)
        if delayPerPage > 0 { try await Task.sleep(nanoseconds: UInt64(delayPerPage * 1_000_000_000)) }
        if failWithAuth { throw EngineError.auth("La clé API a été refusée (clé de test).") }
        if failPages.contains(request.pageNumber) { throw EngineError.network("Panne de réseau simulée sur la page \(request.pageNumber).") }
        return request.zones.map { z in
            if ignoreZoneNumbers.contains(z.number) { return ZoneAnswer(number: z.number, kind: .ignorer, text: "") }
            let kind = z.kind == .ignorer ? ZoneKind.question : z.kind
            return ZoneAnswer(number: z.number, kind: kind, text: "\(answerPrefix) \(request.pageNumber)-\(z.number)")
        }
    }

    func humanize(_ items: [HumanizeItem]) async throws -> [Int: String] {
        countHumanize()
        guard humanizeEnabled else { return [:] }
        var out: [Int: String] = [:]
        for it in items {
            // même longueur que l'original : le garde-fou de l'humanisation l'accepte
            out[it.id] = it.answer.prefix(1).uppercased() + it.answer.dropFirst()
        }
        return out
    }
}
