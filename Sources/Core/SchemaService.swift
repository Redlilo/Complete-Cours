import Foundation
import PDFKit

// Dessin des zones « Schéma électrique » : pour chaque zone, une demande à Claude Opus 5.5 (jamais un autre moteur),
// une zone après l'autre, annulable, avec progression. Le résultat va dans `Zone.schema`, une erreur dans `Zone.error` ;
// une zone en erreur ne bloque pas les suivantes. Le texte (pipeline) ne voit jamais ces zones.
// Le « générateur » est `SchemaEngine.complete` avec l'accès choisi par l'app (clé API ou compte) ; les tests en donnent un faux.
// Tests : Tools/Tests/SchemaIntegration/run.sh

enum SchemaService {
    typealias Generateur = @Sendable (SchemaDemande) async throws -> SchemaElectrique

    static let messageSansCadre = "Cette zone n'a pas de cadre : dessine un cadre autour de l'endroit du schéma "
        + "(bouton « Ajouter une zone »), puis choisis « Schéma électrique » comme type."

    /// Le générateur de l'app : `SchemaEngine.complete` avec un accès donné.
    static func generateur(acces: SchemaEngine.Acces) -> Generateur {
        { demande in try await SchemaEngine.complete(demande, acces: acces) }
    }

    // MARK: - Construction d'une demande

    /// Fabrique la demande d'une zone : page entière numérotée, cadre avec grille, consigne, exemples.
    /// `schemaZones` : les zones schéma de la page (leurs numéros sont dessinés sur l'image de la page).
    static func construireDemande(document: PDFDocument, zone: Zone, pageZones: [Zone], nomDocument: String,
                                  exemples: [(exemple: SchemaExemple, jpeg: Data)]) throws -> SchemaDemande {
        guard let box = zone.box, box.width > 8, box.height > 8 else { throw SchemaErreur.autre(messageSansCadre) }
        guard let page = document.page(at: zone.page) else {
            throw SchemaErreur.autre("La page \(zone.page + 1) de ce PDF n'a pas pu être lue.")
        }
        let marquees = pageZones.filter { $0.box != nil }
        guard let pageJPEG = autoreleasepool(invoking: { MarkedImage.make(page: page, zones: marquees.isEmpty ? [zone] : marquees) }) else {
            throw SchemaErreur.autre("La page \(zone.page + 1) n'a pas pu être transformée en image.")
        }
        guard let grille = autoreleasepool(invoking: { SchemaGrille.demande(page: page, box: box) }) else {
            throw SchemaErreur.autre("Le cadre de la zone \(zone.number) n'a pas pu être transformé en image.")
        }
        return SchemaDemande(nomDocument: nomDocument, numeroPage: zone.page + 1, numeroZone: zone.number,
                             pageJPEG: pageJPEG, cadreGrilleJPEG: grille.cadreJPEG,
                             largeurGrille: grille.largeur, hauteurGrille: grille.hauteur,
                             consigne: consigne(zone: zone, page: page), exemples: Array(exemples.prefix(3)))
    }

    /// Texte voisin de la zone (avant et après) et intitulé de la page (première ligne de texte).
    static func consigne(zone: Zone, page: PDFPage) -> String {
        var parties: [String] = []
        let intitule = (page.string ?? "").split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.count >= 3 } ?? ""
        if !intitule.isEmpty { parties.append("Intitulé de la page : \(String(intitule.prefix(120)))") }
        let avant = zone.contextBefore.trimmingCharacters(in: .whitespacesAndNewlines)
        let apres = zone.contextAfter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !avant.isEmpty { parties.append("Texte avant la zone : \(avant)") }
        if !apres.isEmpty { parties.append("Texte après la zone : \(apres)") }
        return parties.joined(separator: "\n")
    }

    // MARK: - Dessin

    /// Dessine les zones schéma de `ids`, une après l'autre. Renvoie toutes les zones (celles de `ids` mises à jour).
    /// - Annulation de la Task : plus aucune demande, un dernier `onUpdate` livre ce qui est déjà dessiné, puis `CancellationError`.
    /// - Erreur de zone (réponse illisible, réseau, refus, zone sans cadre) : dans `Zone.error`, le schéma précédent est gardé, on continue.
    /// - Accès indisponible (ni clé ni compte) : tout s'arrête, `SchemaErreur.indisponible` est levée.
    static func dessiner(url: URL, documentName: String, zones inputZones: [Zone], ids: Set<Int>,
                         exemples: [(exemple: SchemaExemple, jpeg: Data)],
                         generateur: Generateur,
                         onUpdate: @escaping @Sendable ([Zone], Double, String) -> Void) async throws -> [Zone] {
        try Task.checkCancellation()
        var zones = inputZones
        let aFaire = zones.filter { $0.kind == .schema && ids.contains($0.id) }.sorted { ($0.page, $0.number) < ($1.page, $1.number) }
        guard !aFaire.isEmpty else { return zones }
        let doc = try CoursPipeline.openDocument(url)
        let total = Double(aFaire.count)

        for (rang, base) in aFaire.enumerated() {
            if Task.isCancelled {
                onUpdate(zones, Double(rang) / total, "Annulé")
                throw CancellationError()
            }
            guard let i = zones.firstIndex(where: { $0.id == base.id }) else { continue }
            let etiquette = aFaire.count > 1
                ? "Schéma \(rang + 1) sur \(aFaire.count) (zone \(base.number), page \(base.page + 1)) — Opus dessine le schéma…"
                : "Schéma de la zone \(base.number) (page \(base.page + 1)) — Opus dessine le schéma…"
            onUpdate(zones, Double(rang) / total, etiquette)
            do {
                let pageZones = zones.filter { $0.page == base.page && $0.kind == .schema }
                let demande = try construireDemande(document: doc, zone: zones[i], pageZones: pageZones,
                                                    nomDocument: documentName, exemples: exemples)
                let schema = try await generateur(demande)
                if schema.symboles.isEmpty && schema.fils.isEmpty && schema.textes.isEmpty {
                    zones[i].error = "Opus n'a rien dessiné dans cette zone"
                        + (schema.remarque.isEmpty ? "." : " : \(schema.remarque)")
                } else {
                    zones[i].schema = schema
                    zones[i].error = nil
                }
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    onUpdate(zones, Double(rang) / total, "Annulé")
                    throw CancellationError()
                }
                if case SchemaErreur.indisponible = error { throw error }
                zones[i].error = error.localizedDescription
            }
            onUpdate(zones, Double(rang + 1) / total, etiquette)
        }
        onUpdate(zones, 1, "Terminé")
        return zones
    }
}
