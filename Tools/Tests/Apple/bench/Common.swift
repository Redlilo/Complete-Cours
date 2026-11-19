import Foundation
import FoundationModels

// MARK: - Cas du banc d'essai (Tools/Tests/Apple/benchmark.json)

struct BenchCase: Decodable {
    var id: String
    var matiere: String
    var document: String
    var type: String            // mot | definition | question | ignorer | champ
    var avant: String
    var apres: String
    var attendu: [String]?      // mot : réponses acceptées
    var motsCles: [[String]]?   // definition / question : groupes de mots-clés
    var minimum: Int?
    var capacite: Int?
    var forme: String?
    var split: String?          // dev | test
    var page: String?           // texte de la page (document, banque de mots)
    var attenduTexte: String?   // champ : texte exact
    var attenduKind: String?    // champ : "ignorer"
    var profilVide: Bool?
}

struct BenchFile: Decodable { var cases: [BenchCase] }

func loadCases(_ path: String) -> [BenchCase] {
    guard let data = FileManager.default.contents(atPath: path),
          let f = try? JSONDecoder().decode(BenchFile.self, from: data) else {
        FileHandle.standardError.write(Data("Impossible de lire \(path)\n".utf8))
        exit(1)
    }
    return f.cases
}

/// Réponse « ce n'est pas un trou à remplir ».
let ignoredAnswer = "⟨ignorer⟩"

func zoneInput(_ c: BenchCase) -> AppleZoneInput {
    AppleZoneInput(document: c.document, before: c.avant, after: c.apres, capacity: c.capacite ?? 40)
}

// MARK: - Notation (sans accents ni casse)

func norm(_ s: String) -> String { AppleText.fold(s) }

/// Mot : exact, ou « indulgent » (le mot attendu figure dans une réponse de 5 mots au plus).
func scoreMot(_ answer: String, _ c: BenchCase) -> (strict: Bool, lenient: Bool) {
    let a = norm(answer)
    let wanted = (c.attendu ?? []).map(norm)
    if a.isEmpty { return (false, false) }
    if wanted.contains(a) { return (true, true) }
    let tokens = a.split(separator: " ").map(String.init)
    if tokens.count <= 5 {
        for w in wanted {
            let wt = w.split(separator: " ").map(String.init)
            if wt.isEmpty || wt.count > tokens.count { continue }
            for i in 0...(tokens.count - wt.count) where Array(tokens[i..<(i + wt.count)]) == wt { return (false, true) }
        }
    }
    return (false, false)
}

/// Définition / question : groupes de mots-clés.
func scoreKeywords(_ answer: String, _ c: BenchCase) -> Bool {
    let a = " " + norm(answer) + " "
    var hit = 0
    for group in c.motsCles ?? [] where group.contains(where: { a.contains(norm($0)) }) { hit += 1 }
    return hit >= (c.minimum ?? (c.motsCles?.count ?? 1))
}

// MARK: - Variantes

struct Variant {
    var name: String
    var types: Set<String>
    /// true : la variante décide seulement si la zone est à ignorer (réponse = ignoredAnswer) ou non.
    var isGate = false
    var run: (BenchCase) async throws -> String?
}

let fakeStudent = StudentProfile(nom: "Dupont", prenom: "Camille", classe: "2nde MTNE 1")
let fakeToday = "mardi 17 novembre 2026 (17/11/2026)"
