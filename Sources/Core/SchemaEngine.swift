import Foundation

// Moteur des « zones schéma » : Claude Opus 5.5 UNIQUEMENT.
//
// - Le modèle est `claude-opus-5-5`, en dur : jamais un autre modèle, jamais Apple Intelligence, aucun repli.
//   Sans clé API ni compte Claude, la fonctionnalité est indisponible (`motifIndisponible`).
// - L'appel réseau, les relances (429, 5xx, coupures), le refus de sécurité, la réponse coupée et la sécurité de la clé
//   sont ceux de `ClaudeEngine.generate` (aucune logique recopiée) ; le moteur « compte » passe par `ClaudeCodeEngine.generate`.
// - Opus ne dessine pas : il renvoie un `SchemaElectrique` (symboles du catalogue placés sur une grille + fils). Ce fichier
//   fabrique la demande, impose le format JSON, lit la réponse avec tolérance, puis la fait valider par `SchemaRenderer`.
// - Rien n'est journalisé : ni la clé, ni la page, ni la réponse.
// Tests (faux serveur local, aucun appel réseau réel) : Tools/Tests/SchemaEngine/run.sh

enum SchemaEngine {
    /// Le seul modèle permis pour les schémas.
    static let modele = "claude-opus-5-5"

    enum Acces {
        case cleAPI(String)
        #if COMPTE_PERSO
        case compte(cli: URL, effort: String)
        #endif
    }

    /// Adresse et délais du moteur par clé API : réservés aux tests (faux serveur sur 127.0.0.1).
    static var urlDeBase: URL = ClaudeEngine.defaultBaseURL
    static var reglagesReseau = ClaudeEngine.Tuning()

    static let messageIndisponible = "Les schémas électriques utilisent uniquement Claude Opus 5.5 : "
        + "ajoute ta clé API dans les Réglages, ou connecte ton compte Claude."

    /// nil = au moins un accès est possible ; sinon la phrase à afficher.
    static func motifIndisponible(cleAPI: String?, compteDispo: Bool) -> String? {
        let cle = cleAPI?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (cle.isEmpty && !compteDispo) ? messageIndisponible : nil
    }

    // MARK: - Appel

    static func complete(_ d: SchemaDemande, acces: Acces) async throws -> SchemaElectrique {
        let message = construireMessage(d)
        let texte: String
        do {
            switch acces {
            case .cleAPI(let cle):
                guard !cle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SchemaErreur.indisponible(messageIndisponible)
                }
                let moteur = ClaudeEngine(apiKey: cle, model: modele, baseURL: urlDeBase)
                moteur.tuning = reglagesReseau
                texte = try await moteur.generate(system: promptSysteme, userText: message.texte,
                                                  images: message.images, schema: schemaJSON)
            #if COMPTE_PERSO
            case .compte(let cli, let effort):
                let moteur = ClaudeCodeEngine(cli: cli, model: modele, effort: effort)
                texte = try await moteur.generate(system: promptSysteme, userText: message.texte,
                                                  images: message.images, schema: ClaudeEngine.supportedSchema(schemaJSON))
            #endif
            }
        } catch let e as SchemaErreur {
            throw e
        } catch let e as EngineError {
            throw traduire(e)
        }
        // `SchemaRenderer.valider` ramène le schéma à des données saines (dans la grille, identifiants uniques, fils vers
        // des bornes inexistantes retirés) et signale ce qu'il corrige dans la remarque.
        return SchemaRenderer.valider(try lire(texte, largeur: d.largeurGrille, hauteur: d.hauteurGrille))
    }

    /// Erreurs du moteur -> erreurs du schéma (messages français déjà écrits par les moteurs).
    static func traduire(_ e: EngineError) -> SchemaErreur {
        switch e {
        case .unavailable(let m): return .indisponible(m)
        case .auth(let m), .refused(let m): return .refuse(m)
        case .invalidResponse(let m): return .illisible(m)
        case .rateLimited(let m), .network(let m), .other(let m): return .autre(m)
        }
    }

    // MARK: - Message

    /// Texte puis images, dans cet ordre : exemples (un par un), page entière, cadre avec grille.
    /// Le texte numérote les images pour dire à Opus laquelle est laquelle.
    static func construireMessage(_ d: SchemaDemande) -> (texte: String, images: [Data]) {
        var images: [Data] = []
        var lignes: [String] = []
        lignes.append("Document : « \(d.nomDocument) », page \(d.numeroPage). Zone à compléter : le numéro \(d.numeroZone).")
        lignes.append("Taille de la grille de la zone : \(nombre(d.largeurGrille)) unités de large sur \(nombre(d.hauteurGrille)) unités de haut "
            + "(origine en haut à gauche, y vers le bas). Dans ta réponse, largeurGrille = \(nombre(d.largeurGrille)) "
            + "et hauteurGrille = \(nombre(d.hauteurGrille)).")
        let consigne = d.consigne.trimmingCharacters(in: .whitespacesAndNewlines)
        lignes.append("Consigne autour de la zone : " + (consigne.isEmpty ? "(aucune)" : consigne))

        let exemples = d.exemples.prefix(3).filter { !$0.jpeg.isEmpty }
        if !exemples.isEmpty {
            lignes.append("Les premières images sont des exemples déjà remplis, pour imiter le style et les symboles :")
            for item in exemples {
                images.append(item.jpeg)
                var l = "Image \(images.count) : exemple « \(item.exemple.titre) »"
                let note = item.exemple.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty { l += " — remarque de l'élève : \(note)" }
                lignes.append(l)
            }
        }
        images.append(d.pageJPEG)
        lignes.append("Image \(images.count) : la page entière, avec les numéros des zones.")
        images.append(d.cadreGrilleJPEG)
        lignes.append("Image \(images.count) : le cadre de la zone \(d.numeroZone), avec la grille numérotée "
            + "(lignes fines tous les 1 unité, plus marquées tous les 5 ; les chiffres sont sur les bords).")
        lignes.append("Ajoute dans la zone ce qui manque, avec les coordonnées de cette grille.")
        return (lignes.joined(separator: "\n"), images)
    }

    private static func nombre(_ x: Double) -> String {
        (x.isFinite && abs(x) < 1e9 && x == x.rounded()) ? String(Int(x)) : String(x)
    }

    // MARK: - Prompt système

    static var promptSysteme: String {
        """
        Tu aides un élève de Seconde professionnelle MTNE (métiers de la transition numérique et énergétique) à compléter un schéma électrique dans son cours.
        Les symboles suivent la norme CEI 60617 (NF EN 60617, usage français) : jamais les symboles américains IEEE/ANSI (par exemple la résistance est un RECTANGLE, pas un zigzag). Les repères suivent NF EN 81346 / les manuels français (Q disjoncteur ou sectionneur, KM contacteur, F protection, S bouton, H voyant ou lampe, M moteur, T transformateur, L1/L2/L3, N, PE).

        Tu reçois :
        1. des exemples de schémas déjà remplis (au plus 3), avec leur titre et parfois une remarque de l'élève : imite leur style, leurs repères et leur façon de placer les symboles ;
        2. la page complète du cours, avec ses zones numérotées : elle donne la consigne et ce qui est déjà dessiné ;
        3. le cadre de la zone à compléter, avec une grille numérotée (unités de grille ; origine en haut à gauche ; x vers la droite, y vers le bas ; chiffres sur les bords).

        Ta mission : AJOUTER dans la zone ce qui manque. Ce qui est déjà dessiné en noir sur la page n'est pas à redessiner. Si le cadre est vide, dessine tout le schéma demandé par la consigne.

        Tu ne dessines pas de pixels : tu choisis des symboles normalisés, tu les places sur la grille et tu décris les fils.
        - Utilise UNIQUEMENT les types du catalogue ci-dessous, avec leur nom exact, et leurs bornes telles qu'elles y sont décrites.
        - `x` et `y` sont le CENTRE du symbole, en unités de grille, lus avec les chiffres de la grille. Laisse de la place entre les symboles (au moins 2 unités) pour les repères et les fils.
        - `rotation` : 0, 90, 180 ou 270 degrés. `label` : le repère normalisé écrit à côté (Q1, KM1, F1, H1, S1, M1, L1, N, PE…), vide s'il n'y en a pas. Garde les mêmes repères que les exemples et que la page.
        - Fils : orthogonaux (horizontaux et verticaux). `de` et `vers` sont une borne « id.borne » ou un point de grille « x,y » ; `via` liste les points de passage [x, y]. Évite les croisements inutiles ; utilise un symbole `jonction` quand plusieurs fils se rejoignent.
        - `textes` : repères de lignes (L1, N, PE), valeurs (16 A, 230 V), titres courts.
        - `largeurGrille` et `hauteurGrille` : recopie exactement ceux de la demande.
        - Les `id` des symboles sont uniques (Q1, KM1, J1…).
        - Méthode : (a) lis la consigne et la rangée de composants/repères imprimée sur la page (Q1, Q2 16 A, S1, TL, L1…) : ce sont les repères à reprendre et les appareils à placer ; (b) associe chaque appareil au type du catalogue qui lui correspond le mieux (un disjoncteur différentiel 30 mA = `disjoncteurDifferentiel`, un télérupteur = `telerupteur`, un bouton poussoir = `boutonPoussoirNO`…) ; ne dis jamais qu'un symbole manque sans avoir relu tout le catalogue ; (c) dessine d'abord le plan en pensée : alimentation en haut, appareils de protection, commande, récepteur en bas, retour du neutre ; (d) place, puis vérifie que chaque fil part d'une borne qui existe et que rien ne se chevauche.
        - Mise en page : le schéma doit occuper TOUTE la zone (pas seulement un coin), avec au moins 1 unité de marge au bord de la grille : aucun symbole, repère ni texte ne doit dépasser ou toucher le bord. Dispose le montage en lignes verticales (une colonne par conducteur : L à gauche, N à droite, ou un fil par branche), les appareils en rotation 0 ; les symboles `phase` et `neutre` restent en rotation 0 (barre horizontale en haut de leur colonne) et leur `label` reste VIDE : ils écrivent déjà eux-mêmes L ou N au-dessus de la barre (un label ferait un doublon qui se chevauche). Un appareil à un seul pôle (disjoncteur, sectionneur, contact) se dessine une fois par conducteur coupé (L et N : deux symboles côte à côte, à 3 unités l'un de l'autre en x au moins). Le repère (avec son calibre : « Q2 16 A ») s'écrit à DROITE du symbole : mets-le sur le pôle le plus à DROITE, laisse l'autre `label` vide, et garde 1,5 unité libre à droite de ce symbole, sinon le texte tombe sur un fil ou un autre appareil. N'utilise pas `textes` pour un calibre : mets-le dans le label du repère. Les `textes` ne doivent jamais se poser sur un fil ou un symbole. Évite les croisements de fils : range les colonnes dans l'ordre qui les supprime (la colonne dont le fil continue vers la droite se place à droite, celle qui rejoint le bas ou la gauche se place à gauche) ; un croisement n'est accepté que s'il est inévitable.
        - Si tu n'es pas sûr d'un point (consigne ambiguë, partie illisible), dis-le dans `remarque` plutôt que d'inventer. `remarque` : une ou deux phrases, ce que tu as dessiné et ce dont tu n'es pas sûr.
        - N'écris aucun prénom ni aucun nom de personne.
        - Réponds uniquement en JSON, selon le format imposé, sans texte autour.

        Catalogue des symboles et des bornes :
        \(SchemaSymbolType.catalogueDuPrompt)
        """
    }

    // MARK: - Schéma JSON de la réponse (clés = celles du contrat Codable)

    static var schemaJSON: [String: Any] {
        let nombre: [String: Any] = ["type": "number"]
        let texte: [String: Any] = ["type": "string"]
        let symbole: [String: Any] = [
            "type": "object",
            "properties": [
                "id": texte,
                "type": ["type": "string", "enum": SchemaSymbolType.allCases.map { $0.rawValue }] as [String: Any],
                "x": nombre,
                "y": nombre,
                "rotation": ["type": "integer", "enum": [0, 90, 180, 270]] as [String: Any],
                "label": texte,
            ] as [String: Any],
            "required": ["id", "type", "x", "y", "rotation", "label"],
            "additionalProperties": false,
        ]
        let fil: [String: Any] = [
            "type": "object",
            "properties": [
                "de": texte,
                "vers": texte,
                "via": ["type": "array", "items": ["type": "array", "items": nombre] as [String: Any]] as [String: Any],
            ] as [String: Any],
            "required": ["de", "vers", "via"],
            "additionalProperties": false,
        ]
        let libre: [String: Any] = [
            "type": "object",
            "properties": ["texte": texte, "x": nombre, "y": nombre] as [String: Any],
            "required": ["texte", "x", "y"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "largeurGrille": nombre,
                "hauteurGrille": nombre,
                "symboles": ["type": "array", "items": symbole] as [String: Any],
                "fils": ["type": "array", "items": fil] as [String: Any],
                "textes": ["type": "array", "items": libre] as [String: Any],
                "remarque": texte,
            ] as [String: Any],
            "required": ["largeurGrille", "hauteurGrille", "symboles", "fils", "textes", "remarque"],
            "additionalProperties": false,
        ]
    }

    // MARK: - Lecture de la réponse

    static let messageIllisible = "La réponse de Claude n'a pas pu être lue (schéma incomplet ou mal formé). "
        + "Réessaie ; si le problème continue, dessine ce schéma à la main."

    /// Extrait l'objet JSON d'un texte : tel quel, entre barrières ```json, ou entre la première et la dernière accolade.
    static func extraireJSON(_ brut: String) -> [String: Any]? {
        func objet(_ s: String) -> [String: Any]? {
            guard let d = s.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        let t = brut.trimmingCharacters(in: .whitespacesAndNewlines)
        if let o = objet(t) { return o }
        // Barrières Markdown (au début ou au milieu du texte).
        if let r = t.range(of: "```") {
            var reste = String(t[r.upperBound...])
            reste = reste.replacingOccurrences(of: "^[A-Za-z]*\\s*", with: "", options: .regularExpression)
            if let fin = reste.range(of: "```") { reste = String(reste[..<fin.lowerBound]) }
            if let o = objet(reste.trimmingCharacters(in: .whitespacesAndNewlines)) { return o }
        }
        if let b = t.lastIndex(of: "}") {
            // du premier « { » qui donne un objet valide (du texte de l'IA peut contenir des accolades avant le JSON)
            var depart = t.startIndex, essais = 0
            while essais < 20, let a = t[depart...].firstIndex(of: "{"), a < b {
                if let o = objet(String(t[a...b])) { return o }
                depart = t.index(after: a); essais += 1
            }
        }
        return nil
    }

    private static func reel(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), d.isFinite { return d }
        return nil
    }

    /// Décode la réponse. Tolérant : champs manquants -> valeurs par défaut ; symboles de type inconnu, sans identifiant ou en
    /// double (avec les fils qui y touchent) ignorés et signalés dans la remarque. `largeurGrille` / `hauteurGrille` sont
    /// ceux de la demande, quoi qu'ait écrit le modèle.
    static func lire(_ brut: String, largeur: Double, hauteur: Double) throws -> SchemaElectrique {
        guard let racine = extraireJSON(brut) else { throw SchemaErreur.illisible(messageIllisible) }
        guard racine["symboles"] is [Any] || racine["fils"] is [Any] || racine["textes"] is [Any] else {
            throw SchemaErreur.illisible(messageIllisible)
        }
        var s = SchemaElectrique(largeurGrille: largeur, hauteurGrille: hauteur)
        var ignores: [String] = []
        var retires = Set<String>()

        for case let ligne as [String: Any] in (racine["symboles"] as? [Any] ?? []) {
            let id = (ligne["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let brutType = (ligne["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let type = SchemaSymbolType(rawValue: brutType), let x = reel(ligne["x"]), let y = reel(ligne["y"]) else {
                ignores.append("\(id) (type « \(brutType) »)")
                retires.insert(id)
                continue
            }
            let rot = Int(max(-3600, min(3600, (reel(ligne["rotation"]) ?? 0).rounded())))   // Int(1e30) planterait
            let rotation = SchemaRenderer.rotationNormalisee(rot)   // multiple de 90 le plus proche (80 -> 90, pas 0)
            s.symboles.append(SchemaSymbole(id: id, type: type, x: x, y: y, rotation: rotation,
                                            label: (ligne["label"] as? String) ?? ""))
        }
        func touche(_ borne: String) -> Bool {
            guard let point = borne.firstIndex(of: ".") else { return false }
            return retires.contains(String(borne[..<point]))
        }
        for case let ligne as [String: Any] in (racine["fils"] as? [Any] ?? []) {
            guard let de = ligne["de"] as? String, let vers = ligne["vers"] as? String,
                  !de.isEmpty, !vers.isEmpty, !touche(de), !touche(vers) else { continue }
            let via: [[Double]] = (ligne["via"] as? [Any] ?? []).compactMap { p in
                guard let c = p as? [Any], c.count >= 2, let x = reel(c[0]), let y = reel(c[1]) else { return nil }
                return [x, y]
            }
            s.fils.append(SchemaFil(de: de, vers: vers, via: via))
        }
        for case let ligne as [String: Any] in (racine["textes"] as? [Any] ?? []) {
            guard let t = ligne["texte"] as? String, !t.isEmpty, let x = reel(ligne["x"]), let y = reel(ligne["y"]) else { continue }
            s.textes.append(SchemaTexte(texte: t, x: x, y: y))
        }
        s.remarque = (racine["remarque"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !ignores.isEmpty {
            let suite = "Symboles ignorés : " + ignores.joined(separator: ", ") + "."
            s.remarque = s.remarque.isEmpty ? suite : s.remarque + " " + suite
        }
        return s
    }
}
