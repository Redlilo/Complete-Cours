import Foundation
import PDFKit
import AppKit

// Magasin des « exemples déjà remplis » : des pages de cours dont le schéma est juste, montrées à Opus 5.5 pour qu'il
// imite le style et les symboles. Dossier `schemas-exemples` dans Application Support/<identifiant de l'app>/ :
// un index JSON (`index.json`, liste de `SchemaExemple`) et un JPEG par exemple. Au plus 12 exemples.
// Tests : Tools/Tests/SchemaIntegration/run.sh

final class SchemaExemples: @unchecked Sendable {
    static let maximum = 12
    /// Largeur de l'image gardée (la page est rendue à environ 1400 px de large).
    static let largeurImage: CGFloat = 1400
    static let nomIndex = "index.json"

    /// Le magasin de l'app (un dossier par identifiant d'app : la variante personnelle et la version distribuée ont chacune le leur).
    static let shared = SchemaExemples()

    let dossier: URL
    private let verrou = NSLock()
    private var liste: [SchemaExemple] = []

    /// `dossier` : seulement pour les tests ; par défaut Application Support/<identifiant de l'app>/schemas-exemples.
    init(dossier: URL? = nil) {
        if let dossier {
            self.dossier = dossier
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.dossier = base
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "fr.complete-cours.app", isDirectory: true)
                .appendingPathComponent("schemas-exemples", isDirectory: true)
        }
        recharger()
    }

    // MARK: - Lecture

    /// Les exemples, du plus ancien au plus récent.
    var exemples: [SchemaExemple] {
        verrou.lock(); defer { verrou.unlock() }
        return liste
    }

    var estPlein: Bool { exemples.count >= SchemaExemples.maximum }

    /// Relit l'index sur le disque. Les exemples dont l'image a disparu sont écartés.
    func recharger() {
        verrou.lock(); defer { verrou.unlock() }
        let url = dossier.appendingPathComponent(Self.nomIndex)
        guard let data = try? Data(contentsOf: url),
              let lus = try? JSONDecoder().decode([SchemaExemple].self, from: data) else { liste = []; return }
        liste = lus.filter { FileManager.default.fileExists(atPath: fichier($0).path) }
    }

    func fichier(_ e: SchemaExemple) -> URL { dossier.appendingPathComponent(e.fichierImage) }

    /// Le JPEG d'un exemple (nil si le fichier a disparu).
    func jpeg(_ e: SchemaExemple) -> Data? { try? Data(contentsOf: fichier(e)) }

    // MARK: - Ajout, modification, suppression

    /// Ajoute la page `numeroPage` (1 = première) du PDF `pdf` comme exemple. `titre` vide : « <nom du PDF> – page N ».
    @discardableResult
    func ajouter(pdf: URL, numeroPage: Int, titre: String = "", note: String = "") throws -> SchemaExemple {
        let doc = try CoursPipeline.openDocument(pdf)
        guard numeroPage >= 1, numeroPage <= doc.pageCount, let page = doc.page(at: numeroPage - 1) else {
            throw CoursError.message("Ce PDF a \(doc.pageCount) page\(doc.pageCount > 1 ? "s" : "") : choisis un numéro de page entre 1 et \(doc.pageCount).")
        }
        let nom = pdf.deletingPathExtension().lastPathComponent
        return try ajouter(page: page, titre: titre.isEmpty ? "\(nom) – page \(numeroPage)" : titre, note: note)
    }

    /// Ajoute une page déjà ouverte (celle que l'élève regarde dans l'écran de complétion).
    @discardableResult
    func ajouter(page: PDFPage, titre: String, note: String = "") throws -> SchemaExemple {
        if estPlein {
            throw CoursError.message("Tu as déjà \(Self.maximum) exemples : supprime-en un dans les Réglages (onglet Schémas) avant d'en ajouter un autre.")
        }
        let geo = PageGeometry(page: page)
        let largeurPage = max(geo.displaySize.width, 1)
        let grandCote = max(geo.displaySize.width, geo.displaySize.height)
        let longEdge = min(5000, Self.largeurImage * grandCote / largeurPage)
        guard let (image, _) = PageImaging.render(page: page, longEdge: longEdge),
              let jpeg = PageImaging.jpegData(image, quality: 0.85) else {
            throw CoursError.message("Cette page n'a pas pu être transformée en image : l'exemple n'a pas été ajouté.")
        }
        let exemple = SchemaExemple(titre: titre.trimmingCharacters(in: .whitespacesAndNewlines),
                                    note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                    fichierImage: "\(UUID().uuidString).jpg")
        try ecrireDossier()
        do { try jpeg.write(to: fichier(exemple), options: .atomic) }
        catch { throw CoursError.message("L'exemple n'a pas pu être enregistré : \(error.localizedDescription)") }
        verrou.lock()
        liste.append(exemple)
        let copie = liste
        verrou.unlock()
        try sauver(copie)
        return exemple
    }

    func supprimer(_ id: UUID) throws {
        verrou.lock()
        guard let i = liste.firstIndex(where: { $0.id == id }) else { verrou.unlock(); return }
        let retire = liste.remove(at: i)
        let copie = liste
        verrou.unlock()
        try sauver(copie)
        try? FileManager.default.removeItem(at: fichier(retire))
    }

    func modifier(_ id: UUID, titre: String, note: String) throws {
        verrou.lock()
        guard let i = liste.firstIndex(where: { $0.id == id }) else { verrou.unlock(); return }
        liste[i].titre = titre.trimmingCharacters(in: .whitespacesAndNewlines)
        liste[i].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let copie = liste
        verrou.unlock()
        try sauver(copie)
    }

    private func ecrireDossier() throws {
        do { try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true) }
        catch { throw CoursError.message("Le dossier des exemples n'a pas pu être créé : \(error.localizedDescription)") }
    }

    private func sauver(_ liste: [SchemaExemple]) throws {
        try ecrireDossier()
        do {
            let data = try JSONEncoder().encode(liste)
            try data.write(to: dossier.appendingPathComponent(Self.nomIndex), options: .atomic)
        } catch {
            throw CoursError.message("La liste des exemples n'a pas pu être enregistrée : \(error.localizedDescription)")
        }
    }

    // MARK: - Choix pour une demande

    /// Jusqu'à `max` exemples pour une demande : d'abord ceux dont le titre ressemble au nom du document (mots en commun),
    /// puis les plus récents. Renvoie aussi les JPEG ; un exemple dont l'image est illisible est écarté.
    func pourDemande(nomDocument: String, max: Int = 3) -> [(exemple: SchemaExemple, jpeg: Data)] {
        let mots = Self.mots(nomDocument)
        let tous = exemples
        let classes = tous.enumerated().map { (i, e) -> (SchemaExemple, Int, Int) in
            (e, Self.mots(e.titre).intersection(mots).count, i)
        }.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.2 > b.2 }      // ressemblance, puis plus récent d'abord
        var sortie: [(exemple: SchemaExemple, jpeg: Data)] = []
        for (e, _, _) in classes {
            guard sortie.count < max else { break }
            if let j = jpeg(e), !j.isEmpty { sortie.append((e, j)) }
        }
        return sortie
    }

    /// Mots significatifs (3 lettres ou plus, sans accents ni majuscules), pour comparer des titres.
    static func mots(_ texte: String) -> Set<String> {
        let plat = texte.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        return Set(plat.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 })
    }
}
