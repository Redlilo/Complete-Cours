#if COMPTE_PERSO
import Foundation

// « Suivi MacBook IA » : lecture des pages des vendeurs.
// Chaque lecteur est une fonction PURE (texte de la page -> offres) : testée sur des pages enregistrées, sans réseau.
// Le seul accès réseau est `SuiviReseau.page`. Seuls les MacBook Pro puce Max à 36 ou 48 Go sont gardés.

// MARK: - Petits outils de texte

enum SuiviTexte {
    /// Entités HTML courantes + espaces insécables -> texte normal.
    static func decoder(_ s: String) -> String {
        var t = s
        for (a, b) in [("&quot;", "\""), ("&#34;", "\""), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                       ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("\u{00A0}", " "), ("\u{202F}", " "),
                       ("\u{2011}", "-"), ("\\u00a0", " ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    static func sansBalises(_ s: String) -> String {
        decoder(s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Premier résultat d'un motif : [tout, groupe 1, groupe 2…] (vide si un groupe n'a pas participé).
    static func premier(_ motif: String, dans t: String,
                        options: NSRegularExpression.Options = [.dotMatchesLineSeparators]) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: motif, options: options) else { return nil }
        let ns = t as NSString
        guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    static func tous(_ motif: String, dans t: String,
                     options: NSRegularExpression.Options = [.dotMatchesLineSeparators]) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: motif, options: options) else { return [] }
        let ns = t as NSString
        return re.matches(in: t, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    /// « 5 699 » + « 00 » -> 5699.00
    static func prixFrancais(entier: String, centimes: String) -> Double? {
        let e = entier.filter(\.isNumber)
        return e.isEmpty ? nil : Double("\(e).\(centimes)")
    }

    /// « 5.931,00 » (format allemand) -> 5931.0
    static func prixAllemand(_ s: String) -> Double? {
        let t = s.filter { $0.isNumber || $0 == "." || $0 == "," }
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Double(t)
    }
}

// MARK: - Caractéristiques lues dans un intitulé

struct SuiviCaracteristiques {
    var puce: String?
    var ecran: Int?
    var gpu: Int?
    var ram: Int?
    var ssd: String?

    static let rams: Set<Int> = [16, 18, 24, 32, 36, 48, 64, 96, 128]

    /// Lit un intitulé dans n'importe quelle langue (français, anglais, allemand, espagnol, italien, néerlandais).
    static func lire(_ brut: String) -> SuiviCaracteristiques {
        let t = SuiviTexte.decoder(brut)
        var c = SuiviCaracteristiques()
        if let m = SuiviTexte.premier(#"\bM([2-9])\s*(Pro|Max|Ultra)\b"#, dans: t, options: [.caseInsensitive]) {
            c.puce = "M\(m[1]) \(m[2].capitalized)"
        }
        if let m = SuiviTexte.premier(#"(?<![\d,.])(14|16)(?:[,.]\d)?\s*(?:-|‑)?\s*(?:pouces|"|″|inch|zoll|pulgadas|pollici|'|p\b)"#,
                                      dans: t, options: [.caseInsensitive]) {
            c.ecran = Int(m[1])
        }
        // GPU : « GPU 40 cœurs », « GPU de 32 núcleos », « 40-Core GPU »… On cherche d'abord « GPU <nombre> cœurs » :
        // dans « CPU 18 cœurs GPU 40 cœurs », le « 18 cœurs GPU » ne doit pas être pris pour le GPU.
        let motsCoeurs = #"(?:core|cœurs?|coeurs?|núcleos|nuclei|kern\w*|cores)"#
        if let m = SuiviTexte.premier(#"GPU\D{0,8}(\d+)\s*[-‑]?\s*"# + motsCoeurs, dans: t, options: [.caseInsensitive]) {
            c.gpu = Int(m[1])
        } else if let m = SuiviTexte.premier(#"(?<!CPU )(\d+)\s*[-‑]?\s*"# + motsCoeurs + #"\s*(?:de\s+|di\s+)?GPU"#, dans: t, options: [.caseInsensitive]) {
            c.gpu = Int(m[1])
        }
        // Mémoire et stockage : « 48 Go », « 48GB » ; stockage = valeur en To, ou en Go si ≥ 256.
        var ssd: String?
        for m in SuiviTexte.tous(#"(\d{1,4})\s*(To|TB|Go|GB)\b"#, dans: t, options: [.caseInsensitive]) {
            guard let n = Int(m[1]) else { continue }
            let unite = m[2].lowercased()
            if unite == "to" || unite == "tb" { if ssd == nil { ssd = "\(n) To" } }
            else if n >= 256 { if ssd == nil { ssd = n >= 1000 ? "\(n / 1000) To" : "\(n) Go" } }
            else if rams.contains(n), c.ram == nil { c.ram = n }
        }
        c.ssd = ssd
        return c
    }
}

// MARK: - Fabrique d'offre

/// Mémoires suivies (Go).
let suiviMemoires: Set<Int> = [36, 48, 64]

/// Liens des offres : seulement https, et seulement vers le site attendu pour la source (une page piégée ne peut pas
/// glisser un lien vers un autre domaine). Un lien refusé devient « » (l'offre reste, sans lien).
enum SuiviLiens {
    static let hotesParSource: [(prefixe: String, hotes: [String])] = [
        ("apple", ["apple.com"]), ("ldlc", ["ldlc.com"]), ("materiel", ["materiel.net"]), ("boulanger", ["boulanger.com"]),
        ("alternate", ["alternate.de"]), ("mac-store24", ["mac-store24.com"]), ("fnac", ["fnac.com"]), ("darty", ["darty.com"]),
        ("mediamarkt", ["mediamarkt.de"]), ("refurb", ["refurb.me", "backmarket.fr", "backmarket.com", "okamac.com", "rebuy.fr", "rebuy.de"]),
        ("amazon", ["amazon.fr", "amazon.de", "amazon.it", "amazon.es", "amazon.nl"]), ("leboncoin", ["leboncoin.fr"]),
        ("kleinanzeigen", ["kleinanzeigen.de"]), ("rue du commerce", ["rueducommerce.fr"]), ("okamac", ["okamac.com"]),
    ]
    static var tousLesHotes: [String] { hotesParSource.flatMap(\.hotes) }

    static func hoteOK(_ host: String?, parmi hotes: [String]) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return hotes.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// `lien` (absolu ou relatif à `base`) -> URL https de la bonne boutique, sinon nil.
    static func valide(_ lien: String, base: String? = nil, source: String? = nil) -> URL? {
        let b = base.flatMap { URL(string: $0) }
        guard !lien.isEmpty, let u = URL(string: lien, relativeTo: b)?.absoluteURL, u.scheme?.lowercased() == "https" else { return nil }
        let nom = source?.lowercased()
        let hotes = hotesParSource.first { nom?.hasPrefix($0.prefixe) == true }?.hotes ?? tousLesHotes
        return hoteOK(u.host, parmi: hotes) ? u : nil
    }

    /// Pour l'ouverture dans le navigateur (n'importe quelle boutique connue).
    static func ouvrable(_ u: URL) -> Bool { u.scheme?.lowercased() == "https" && hoteOK(u.host, parmi: tousLesHotes) }
}

private func offre(key: String, source: String, pays: String, etat: SuiviEtat, titre: String,
                   c: SuiviCaracteristiques, ram: Int? = nil, ssd: String? = nil, couleur: String = "",
                   affichage: String = "standard", clavier: String? = nil,
                   prix: Double, prixOriginal: Double? = nil, stock: String = "", url: String,
                   livraison: SuiviLivraison, remarque: String = "", grade: String? = nil,
                   ecranOptionnel: Bool = false) -> SuiviOffre? {
    // ecran 0 = taille non indiquée (annonces de particuliers)
    guard let puce = c.puce, (puce.hasSuffix("Max") || puce.hasSuffix("Ultra")), let ecran = c.ecran ?? (ecranOptionnel ? 0 : nil) else { return nil }
    guard let memoire = ram ?? c.ram, suiviMemoires.contains(memoire), SuiviCalcul.prixValide(prix) else { return nil }
    let gpu = c.gpu ?? SuiviReference.gpuProbable(puce: puce, ram: memoire)
    return SuiviOffre(key: key, source: source, pays: pays, etat: etat, titre: titre, puce: puce, ecran: ecran,
                      gpu: gpu, ram: memoire, ssd: ssd ?? c.ssd ?? "?", affichage: affichage, couleur: couleur,
                      clavier: clavier ?? SuiviReference.claviersParPays[pays] ?? "inconnu",
                      prix: prix, prixOriginal: prixOriginal, stock: stock,
                      url: SuiviLiens.valide(url, source: source)?.absoluteString ?? "",
                      livraison: livraison, remarque: remarque, manuelle: false, ajoutee: nil, grade: grade)
}

private func couleurFrancaise(_ s: String) -> String {
    let t = s.lowercased()
    if t.contains("argent") || t.contains("silver") || t.contains("silber") || t.contains("plata") || t.contains("zilver") || t.contains("argento") { return "Argent" }
    if t.contains("noir") || t.contains("space black") || t.contains("space schwarz") || t.contains("spaceblack") || t.contains("schwarz")
        || t.contains("negro") || t.contains("nero") || t.contains("spacezwart") || t.contains("hazel") { return "Noir sidéral" }
    return ""
}

// MARK: - Lecteurs

enum SuiviLecteurs {

    // Apple (tous les pays) : les produits sont dans un tableau JSON `"tiles":[…]` de la page.
    static func apple(_ html: String, pays: String, base: String) -> [SuiviOffre] {
        let livraison: SuiviLivraison = pays == "FR" ? .oui : .non
        let remarque = pays == "FR" ? "" : "Le Store Apple d'un pays ne livre qu'à une adresse de ce pays : prix indicatif."
        var out: [SuiviOffre] = []
        for tuile in tuilesApple(html) {
            guard let titreBrut = tuile["title"] as? String,
                  let prixDict = tuile["price"] as? [String: Any],
                  let courant = prixDict["currentPrice"] as? [String: Any],
                  let brut = courant["raw_amount"] as? String, let prix = Double(brut) else { continue }
            let titre = SuiviTexte.decoder(titreBrut)
            guard titre.lowercased().contains("macbook pro") else { continue }
            let dims = ((tuile["filters"] as? [String: Any])?["dimensions"] as? [String: Any]) ?? [:]
            var c = SuiviCaracteristiques.lire(titre)
            if let e = (dims["dimensionScreensize"] as? String).flatMap({ Int($0.replacingOccurrences(of: "inch", with: "")) }) { c.ecran = e }
            let ram = (dims["tsMemorySize"] as? String).flatMap { Int($0.replacingOccurrences(of: "gb", with: "")) }
            var ssd: String?
            if let cap = dims["dimensionCapacity"] as? String,
               let m = SuiviTexte.premier(#"^(\d+)(tb|gb)$"#, dans: cap), let n = Int(m[1]) {
                ssd = m[2] == "tb" ? "\(n) To" : "\(n) Go"
            }
            let piece = (tuile["partNumber"] as? String)
                ?? ((tuile["omnitureModel"] as? [String: Any])?["partNumber"] as? String)
                ?? (prixDict["partNumber"] as? String) ?? titre
            let chemin = (tuile["productDetailsUrl"] as? String) ?? ""
            let url = SuiviLiens.valide(chemin.isEmpty ? base : chemin, base: base, source: "Apple")?.absoluteString ?? ""
            let original = prixDict["originalProductAmount"] as? Double
            let couleur = couleurFrancaise((dims["dimensionColor"] as? String) ?? titre)
            let nano = titre.lowercased().contains("nano")
            if let o = offre(key: "apple-\(pays)|\(piece)", source: pays == "FR" ? "Apple reconditionné" : "Apple reconditionné (\(pays))",
                             pays: pays, etat: .reconditionneApple, titre: titre, c: c, ram: ram, ssd: ssd, couleur: couleur,
                             affichage: nano ? "nano-texturé" : "standard", prix: prix, prixOriginal: original,
                             url: url, livraison: livraison, remarque: remarque) {
                out.append(o)
            }
        }
        return out
    }

    /// Extrait et décode le tableau JSON des produits (parcours des crochets, en tenant compte des chaînes).
    static func tuilesApple(_ html: String) -> [[String: Any]] {
        let data = Data(html.utf8)
        let cle = Data(#""tiles":["#.utf8)
        var debut = data.startIndex
        while let r = data.range(of: cle, in: debut..<data.endIndex) {
            let crochet = r.upperBound - 1
            if let fin = finTableau(data, depuis: crochet),
               let obj = try? JSONSerialization.jsonObject(with: data.subdata(in: crochet..<(fin + 1))) as? [[String: Any]],
               obj.contains(where: { $0["productDetailsUrl"] != nil }) {
                return obj
            }
            debut = r.upperBound
        }
        return []
    }

    private static func finTableau(_ d: Data, depuis i0: Int) -> Int? {
        var profondeur = 0, dansChaine = false, echappe = false
        var i = i0
        while i < d.endIndex {
            let c = d[i]
            if dansChaine {
                if echappe { echappe = false } else if c == 0x5C { echappe = true } else if c == 0x22 { dansChaine = false }
            } else {
                switch c {
                case 0x22: dansChaine = true
                case 0x5B, 0x7B: profondeur += 1
                case 0x5D, 0x7D:
                    profondeur -= 1
                    if profondeur == 0 { return i }
                default: break
                }
            }
            i += 1
        }
        return nil
    }

    // LDLC (neuf, France)
    static func ldlc(_ html: String) -> [SuiviOffre] {
        let nettoye = html.replacingOccurrences(of: "&nbsp;", with: " ")
        var out: [SuiviOffre] = []
        for bloc in nettoye.components(separatedBy: #"<li id="pdt-"#).dropFirst() {
            guard let t = SuiviTexte.premier(#"<h3 class ="title-3"><a href="([^"]+)">(.*?)</a>"#, dans: bloc),
                  let p = SuiviTexte.premier(#"<div class="price">([\d\s]+)€<sup>(\d\d)</sup>"#, dans: bloc),
                  let prix = SuiviTexte.prixFrancais(entier: p[1], centimes: p[2]) else { continue }
            let titre = SuiviTexte.sansBalises(t[2])
            let desc = SuiviTexte.premier(#"<p class="desc">(.*?)</p>"#, dans: bloc).map { SuiviTexte.sansBalises($0[1]) } ?? ""
            let c = SuiviCaracteristiques.lire(titre + " " + desc)
            let stock = SuiviTexte.premier(#"stock-\d"[^>]*><span>(.*?)</span>"#, dans: bloc).map { SuiviTexte.sansBalises($0[1]) } ?? ""
            let ref = SuiviTexte.premier(#"\(([A-Z0-9]+/A[^)]*)\)\s*$"#, dans: titre)?[1] ?? t[1]
            if let o = offre(key: "ldlc|\(ref)", source: "LDLC", pays: "FR", etat: .neuf, titre: titre, c: c,
                             ssd: SuiviTexte.premier(#"(\d+ (?:To|Go))\s*\("#, dans: titre)?[1],
                             couleur: couleurFrancaise(titre), affichage: titre.contains("PROLED") ? "PROLED" : "standard",
                             prix: prix, stock: stock, url: SuiviLiens.valide(t[1], base: "https://www.ldlc.com", source: "LDLC")?.absoluteString ?? "", livraison: .oui) {
                out.append(o)
            }
        }
        return out
    }

    // Materiel.net (même groupe que LDLC)
    static func materiel(_ html: String) -> [SuiviOffre] {
        let nettoye = html.replacingOccurrences(of: "&nbsp;", with: " ")
        var out: [SuiviOffre] = []
        for bloc in nettoye.components(separatedBy: #"<li class="c-products-list__item""#).dropFirst() {
            guard let t = SuiviTexte.premier(#"class="c-product__title">(.*?)</h2>"#, dans: bloc),
                  let p = SuiviTexte.premier(#"o-product__price">([\d\s]+)€<sup>(\d\d)</sup>"#, dans: bloc),
                  let prix = SuiviTexte.prixFrancais(entier: p[1], centimes: p[2]) else { continue }
            let titre = SuiviTexte.sansBalises(t[1])
            let desc = SuiviTexte.premier(#"c-product__description">(.*?)</p>"#, dans: bloc).map { SuiviTexte.sansBalises($0[1]) } ?? ""
            var c = SuiviCaracteristiques.lire(titre + " " + desc)
            // la fiche se contredit parfois (36 Go dans la description, 48 Go dans le titre) : on se fie au titre
            if let m = SuiviTexte.premier(#"\b(36|48) ?Go\b"#, dans: titre) { c.ram = Int(m[1]) }
            let href = SuiviTexte.premier(#"href="(https://www\.materiel\.net/produit/[^"]+)""#, dans: bloc)?[1] ?? "https://www.materiel.net"
            let ref = SuiviTexte.premier(#"\(([A-Z0-9]+/A[^)]*)\)\s*$"#, dans: titre)?[1] ?? href
            if let o = offre(key: "materiel|\(ref)", source: "Materiel.net", pays: "FR", etat: .neuf, titre: titre, c: c,
                             ssd: SuiviTexte.premier(#"/\s*(\d+ (?:To|Go))"#, dans: titre)?[1],
                             couleur: couleurFrancaise(titre), affichage: titre.contains("PROLED") ? "PROLED" : "standard",
                             prix: prix, url: href, livraison: .oui) {
                out.append(o)
            }
        }
        return out
    }

    // Boulanger (France) : neuf ou reconditionné, prix dans data-offer.
    static func boulanger(_ html: String) -> [SuiviOffre] {
        var out: [SuiviOffre] = []
        for bloc in html.components(separatedBy: #"<li class=" product-list__item"#).dropFirst() {
            guard let t = SuiviTexte.premier(#"<h2[^>]*>(.*?)</h2>"#, dans: bloc),
                  let p = SuiviTexte.premier(#""offerPrice": ([\d.]+)"#, dans: bloc), let prix = Double(p[1]),
                  let ref = SuiviTexte.premier(#"href="(/ref/\d+)(?:\?[^"]*)?""#, dans: bloc) else { continue }
            let titre = SuiviTexte.sansBalises(t[1])
            let marketplace = SuiviTexte.premier(#"data-is-marketplace="(\w+)""#, dans: bloc)?[1] == "true"
            let reconditionne = titre.lowercased().contains("reconditionn")
                || SuiviTexte.premier(#"data-is-reconditioned="(\w+)""#, dans: bloc)?[1] == "true"
            let c = SuiviCaracteristiques.lire(titre)
            let nano = titre.lowercased().contains("nano")
            if let o = offre(key: "boulanger|\(ref[1])", source: "Boulanger", pays: "FR",
                             etat: reconditionne ? .reconditionneTiers : .neuf, titre: titre, c: c,
                             couleur: couleurFrancaise(titre),
                             affichage: nano ? "nano-texturé" : (titre.contains("XDR") && !titre.contains("Liquid") ? "XDR" : "standard"),
                             clavier: "AZERTY", prix: prix, url: SuiviLiens.valide(ref[1], base: "https://www.boulanger.com", source: "Boulanger")?.absoluteString ?? "", livraison: .oui,
                             remarque: marketplace ? "Vendu par un partenaire de Boulanger (Marketplace)." :
                                 (reconditionne ? "Reconditionné par Boulanger." : "")) {
                out.append(o)
            }
        }
        return out
    }

    // Kleinanzeigen.de (Allemagne) : petites annonces, comme Leboncoin. Lecture simple de la page de résultats (aucune protection
    // contournée : si le site affiche autre chose que des annonces, on ne lit rien). Seules les ventes de MacBook Pro Max 36/48/64 Go sont gardées.
    static func kleinanzeigen(_ html: String) -> [SuiviOffre] {
        var out: [SuiviOffre] = []
        for morceau in html.components(separatedBy: "<article ").dropFirst() {
            let corps = morceau.components(separatedBy: "</article>").first ?? morceau
            guard let id = SuiviTexte.premier(#"data-adid="(\d+)""#, dans: corps)?[1],
                  let t = SuiviTexte.premier(#"<h3[^>]*>\s*<a[^>]*>(.*?)</a>"#, dans: corps) else { continue }
            let titre = SuiviTexte.sansBalises(t[1])
            let bas = titre.lowercased()
            // pas des ventes : recherches (« Gesuch », « Suche »), échanges, rachats, appareils cassés ou pièces
            if corps.contains(">Gesuch<") || bas.hasPrefix("suche") || bas.contains("tausch") || bas.contains("ankauf")
                || bas.contains("defekt") || bas.contains("ersatzteil") || bas.contains("bastler") || bas.contains("kaputt") { continue }
            let descr = SuiviTexte.premier(#"</h3>\s*<p[^>]*>(.*?)</p>"#, dans: corps).map { SuiviTexte.sansBalises($0[1]) } ?? ""
            let apres = corps.components(separatedBy: "</h3>").dropFirst().joined(separator: "</h3>")
            let prix = SuiviTexte.tous(#"<p[^>]*>\s*([\d.]{3,7})\s*€"#, dans: apres).compactMap { SuiviTexte.prixAllemand($0[1]) }
            guard let p = prix.first, p >= 500, SuiviCalcul.prixValide(p) else { continue }   // < 500 € : « 1 € VB » ou accessoire, pas un MacBook Max
            let ancien = prix.count > 1 && prix[1] > p ? prix[1] : nil
            let c = SuiviCaracteristiques.lire(titre + " " + descr)
            let envoi = corps.contains("Versand möglich")
            let ville = SuiviTexte.premier(#"<span[^>]*>(\d{5} [^<]+)</span>"#, dans: corps)?[1].trimmingCharacters(in: .whitespaces)
            let href = SuiviTexte.premier(#"data-href="([^"]+)""#, dans: corps).map { SuiviTexte.decoder($0[1]) } ?? ""
            if var o = offre(key: "kleinanzeigen|\(id)", source: "Kleinanzeigen.de", pays: "DE", etat: .occasion, titre: titre, c: c,
                             prix: p, prixOriginal: ancien, url: SuiviLiens.valide(href, base: "https://www.kleinanzeigen.de", source: "Kleinanzeigen.de")?.absoluteString ?? "",
                             livraison: envoi ? .aVerifier : .non,
                             remarque: "Petite annonce allemande (particulier ou professionnel) : prix souvent négociable. "
                                + (envoi ? "Envoi possible : vers la France à demander au vendeur." : "Retrait sur place seulement."),
                             ecranOptionnel: true) {
                o.ville = ville
                out.append(o)
            }
        }
        return out
    }

    // Alternate.de (Allemagne) : livraison en France non vérifiée, clavier allemand.
    static func alternate(_ html: String, rechercheURL: String) -> [SuiviOffre] {
        let t0 = SuiviTexte.decoder(html)
        var out: [SuiviOffre] = []
        for bloc in t0.components(separatedBy: #"product-name font-weight-bold"#).dropFirst() {
            guard let nom = SuiviTexte.premier(#"^[^>]*>(.*?)</div>"#, dans: bloc).map({ SuiviTexte.sansBalises($0[1]) }),
                  nom.lowercased().contains("macbook pro"),
                  let proz = SuiviTexte.premier(#"Prozessor: Apple (M\d (?:Pro|Max))"#, dans: bloc),
                  let pr = SuiviTexte.premier(#"class="price[^"]*">€ ([\d.,]+)<"#, dans: bloc),
                  let prix = SuiviTexte.prixAllemand(pr[1]) else { continue }
            var c = SuiviCaracteristiques()
            c.puce = proz[1]
            c.gpu = SuiviTexte.premier(#"(\d+)-Core GPU"#, dans: bloc).flatMap { Int($0[1]) }
            c.ram = SuiviTexte.premier(#"(\d+) GB Arbeitsspeicher"#, dans: bloc).flatMap { Int($0[1]) }
            c.ssd = SuiviTexte.premier(#"(\d+) (TB|GB) SSD"#, dans: bloc).flatMap { m in
                guard let n = Int(m[1]) else { return nil }
                return m[2] == "TB" ? "\(n) To" : "\(n) Go"
            }
            c.ecran = SuiviTexte.premier(#"\((1[46])[,.]\d Zoll\)"#, dans: bloc).flatMap { Int($0[1]) }
                ?? SuiviTexte.premier(#"\((1[46])""#, dans: nom).flatMap { Int($0[1]) }
            let sous = SuiviTexte.premier(#"product-name-sub">(.*?)</span>"#, dans: bloc).map { SuiviTexte.sansBalises($0[1]) } ?? ""
            let sku = SuiviTexte.premier(#"data-id="?(\d{6,})"#, dans: bloc)?[1] ?? "\(nom)|\(prix)"
            if let o = offre(key: "alternate|\(sku)|\(prix)", source: "Alternate.de", pays: "DE", etat: .neuf, titre: "\(nom) — \(sous)", c: c,
                             couleur: couleurFrancaise(sous), affichage: nom.contains("PROLED") ? "PROLED" : "standard",
                             clavier: sous.contains("Deutsch") ? "QWERTZ" : nil,
                             prix: prix, url: rechercheURL, livraison: .aVerifier,
                             remarque: "Vendeur allemand : livraison en France et frais à vérifier, clavier allemand.") {
                out.append(o)
            }
        }
        return out
    }

    // mac-store24.com (Allemagne, reconditionné) : les variantes sont dans l'événement « search_submitted » de la page.
    static func macStore24(_ html: String) -> [SuiviOffre] {
        guard let evenements = chaineJSON(apres: #""events":""#, dans: html),
              let data = evenements.data(using: .utf8),
              let liste = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }
        var out: [SuiviOffre] = []
        var vus = Set<String>()
        for ev in liste where (ev.first as? String) == "search_submitted" {
            let variantes = (((ev.last as? [String: Any])?["searchResult"]) as? [String: Any])?["productVariants"] as? [[String: Any]] ?? []
            for v in variantes {
                guard let p = v["product"] as? [String: Any], let titre = p["title"] as? String,
                      let prixD = v["price"] as? [String: Any], let prix = (prixD["amount"] as? Double),
                      let titreVariante = v["title"] as? String else { continue }
                let id = (v["id"] as? String) ?? titre + titreVariante
                guard vus.insert(id).inserted else { continue }
                let morceaux = titreVariante.components(separatedBy: " / ")
                let clavier = ["AZERTY", "QWERTZ", "QWERTY"].first { titreVariante.uppercased().contains($0) }
                var c = SuiviCaracteristiques.lire(titre.replacingOccurrences(of: "16,2", with: "16").replacingOccurrences(of: "14,2", with: "14") + " pouces")
                if let m = SuiviTexte.premier(#"M([2-9]) Max"#, dans: titre) { c.puce = "M\(m[1]) Max" }
                c.ecran = SuiviTexte.premier(#"(14|16)(?:,\d)? pouces"#, dans: titre).flatMap { Int($0[1]) } ?? c.ecran
                let ramTxt = morceaux.first { $0.lowercased().contains(" go") && !$0.lowercased().contains(" to") }
                let ssdTxt = morceaux.first { $0.lowercased().hasSuffix(" to") }
                c.ram = ramTxt.flatMap { SuiviTexte.premier(#"(\d+)"#, dans: $0) }.flatMap { Int($0[1]) }
                var ssd = ssdTxt.flatMap { SuiviTexte.premier(#"(\d+)"#, dans: $0) }.flatMap { Int($0[1]) }.map { "\($0) To" }
                if ssd == nil { ssd = "?" }
                let chemin = (p["url"] as? String) ?? ""
                let url = SuiviLiens.valide((chemin.components(separatedBy: "?").first ?? chemin) + "?variant=\((id).filter(\.isNumber))",
                                            base: "https://mac-store24.com", source: "mac-store24.com")?.absoluteString ?? ""
                if let o = offre(key: "macstore24|\(id)", source: "mac-store24.com", pays: "DE", etat: .reconditionneTiers,
                                 titre: "\(titre) — \(titreVariante)", c: c, ssd: ssd, couleur: couleurFrancaise(titre),
                                 clavier: clavier, prix: prix, url: url, livraison: .oui,
                                 remarque: "Vendeur allemand : annonce la livraison dans toute l'UE (à confirmer), garantie 12 mois du vendeur.") {
                    out.append(o)
                }
            }
        }
        return out
    }

    // MARK: Sites lus avec WebKit (fiches extraites de la page rendue : voir SuiviMacWebKit.swift)

    /// Prix en euros trouvés dans un texte (« 5 699 € », « 5 868,99 € »), au-dessus de 1 500 € pour écarter les bons d'achat.
    static func prixEuros(_ texte: String) -> [Double] {
        SuiviTexte.tous(#"(\d{1,3}(?: \d{3})+|\d{4,5})(?:,(\d\d))?\s?€"#, dans: SuiviTexte.decoder(texte)).compactMap { m in
            guard let v = Double("\(m[1].filter(\.isNumber)).\(m[2].isEmpty ? "00" : m[2])"), v >= 1500, v <= 30000 else { return nil }
            return v
        }
    }

    private static func depuisBlocs(_ blocs: [SuiviBlocWeb], source: String, pays: String, livraison: SuiviLivraison,
                                    clavier: String?, remarque: String,
                                    prix: (String) -> (Double, String)?) -> [SuiviOffre] {
        var out: [SuiviOffre] = []
        for b in blocs {
            let titre = SuiviTexte.decoder(b.titre)
            let texte = SuiviTexte.decoder(b.texte)
            guard titre.lowercased().contains("macbook"), let (p, note) = prix(texte) else { continue }
            let c = SuiviCaracteristiques.lire(titre + " " + String(texte.prefix(600)))
            let bas = titre.lowercased()
            let reconditionne = bas.contains("reconditionn") || bas.contains("refurbished")
            let outlet = texte.uppercased().contains("OUTLET")
            let affichage = titre.uppercased().contains("PROLED") ? "PROLED" : (bas.contains("nano") ? "nano-texturé" : "standard")
            let rem = [remarque, outlet ? "Offre « Outlet » : état à vérifier." : "", note].filter { !$0.isEmpty }.joined(separator: " ")
            if let o = offre(key: "\(source)|\(b.url)", source: source, pays: pays,
                             etat: reconditionne ? .reconditionneTiers : .neuf, titre: titre, c: c,
                             couleur: couleurFrancaise(titre), affichage: affichage, clavier: clavier,
                             prix: p, url: b.url, livraison: livraison, remarque: rem) {
                out.append(o)
            }
        }
        return out
    }

    static func fnac(_ blocs: [SuiviBlocWeb]) -> [SuiviOffre] {
        depuisBlocs(blocs, source: "Fnac", pays: "FR", livraison: .oui, clavier: "AZERTY", remarque: "") { texte in
            let p = prixEuros(texte)
            guard let premier = p.first else { return nil }
            if p.count > 1, p[1] < premier { return (premier, "Un prix plus bas (\(Int(p[1])) €) est affiché, sans doute réservé aux adhérents Fnac.") }
            return (premier, "")
        }
    }

    static func darty(_ blocs: [SuiviBlocWeb]) -> [SuiviOffre] {
        depuisBlocs(blocs, source: "Darty", pays: "FR", livraison: .oui, clavier: "AZERTY", remarque: "") { texte in
            prixEuros(texte).first.map { ($0, "") }
        }
    }

    static func mediaMarkt(_ blocs: [SuiviBlocWeb]) -> [SuiviOffre] {
        depuisBlocs(blocs, source: "MediaMarkt.de", pays: "DE", livraison: .aVerifier, clavier: "QWERTZ",
                    remarque: "Magasin allemand : livraison en France non confirmée (souvent réservée à l'Allemagne), clavier allemand.") { texte in
            // « 5699,– € 5699,00€ 4969,– € 4969,00€ inkl. MwSt. » : le prix à payer est le dernier avant « inkl. MwSt. ».
            guard let m = SuiviTexte.tous(#"(\d{3,5}),00\s?€\s*inkl\."#, dans: texte).last, let v = Double(m[1]), v >= 1500 else { return nil }
            return (v, "")
        }
    }

    // MARK: Sites de reconditionné et places de marché

    /// RefurbMe : comparateur de reconditionnés. Chaque fiche donne le prix le plus bas d'une configuration, le vendeur
    /// (Back Market, Okamac, reBuy, Fnac, Darty…) et l'état esthétique (Excellent, Bon, Moyen). Le Store Apple est ignoré
    /// (lu directement ailleurs).
    static func refurbMe(_ blocs: [SuiviBlocWeb]) -> [SuiviOffre] {
        var out: [SuiviOffre] = []
        for b in blocs {
            let texte = SuiviTexte.decoder(b.texte)
            guard let v = SuiviTexte.premier(#"(Excellent|Bon|Moyen) chez (.+?)(?= Excellent dès| Bon dès| \d+ offre|$)"#, dans: texte),
                  let prix = prixEuros(texte).first else { continue }
            let vendeur = v[2].trimmingCharacters(in: .whitespaces)
            if vendeur.lowercased().contains("apple") { continue }
            let c = SuiviCaracteristiques.lire(SuiviTexte.decoder(b.titre).components(separatedBy: " €").first.map { String($0.prefix(110)) } ?? b.titre)
            if let o = offre(key: "refurbme|\(b.url)|\(vendeur)", source: vendeur, pays: "FR", etat: .reconditionneTiers,
                             titre: SuiviTexte.decoder(b.titre).prefix(120).description, c: c, affichage: "standard", clavier: "AZERTY",
                             prix: prix, url: b.url, livraison: .oui,
                             remarque: "Prix le plus bas relevé sur RefurbMe pour cette configuration, état « \(v[1]) » ; le lien ouvre RefurbMe puis le vendeur.",
                             grade: v[1]) {
                out.append(o)
            }
        }
        return out
    }

    /// Amazon (France, Allemagne, Italie, Espagne, Pays-Bas) : neuf ou reconditionné. Les résultats sponsorisés doublonnent :
    /// le regroupement garde le moins cher.
    static func amazon(_ blocs: [SuiviBlocWeb], pays: String) -> [SuiviOffre] {
        let domaines = ["FR": "Amazon.fr", "DE": "Amazon.de", "IT": "Amazon.it", "ES": "Amazon.es", "NL": "Amazon.nl"]
        var out: [SuiviOffre] = []
        for b in blocs {
            let titre = SuiviTexte.decoder(b.titre)
            let texte = SuiviTexte.decoder(b.texte)
            guard titre.lowercased().contains("macbook pro") else { continue }
            let bas = titre.lowercased()
            let reconditionne = ["reconditionn", "renewed", "generalüberholt", "ricondizionat", "reacondicionad", "gereviseerd", "refurbished"].contains { bas.contains($0) }
            let prix: Double?
            if pays == "FR" {
                prix = prixEuros(texte.replacingOccurrences(of: "Conseillé", with: "")).first
            } else {
                // « 3.899,00 € » ou « € 3.899,00 » : points pour les milliers, virgule pour les centimes
                prix = SuiviTexte.tous(#"(\d{1,3}(?:\.\d{3})+),(\d\d)"#, dans: texte)
                    .compactMap { Double($0[1].replacingOccurrences(of: ".", with: "") + "." + $0[2]) }
                    .first { $0 >= 1500 && $0 <= 30000 }
            }
            guard let p = prix else { continue }
            let c = SuiviCaracteristiques.lire(titre)
            let asin = SuiviTexte.premier(#"/dp/([A-Z0-9]{10})"#, dans: b.url)?[1] ?? String(titre.prefix(60))
            let nom = domaines[pays] ?? "Amazon"
            let rem = pays == "FR" ? "Vendeur et expéditeur à vérifier sur la fiche Amazon."
                : "\(nom) : livraison en France possible pour la plupart des articles (frais à vérifier), clavier local."
            if let o = offre(key: "amazon-\(pays)|\(asin)|\(Int(p))", source: nom, pays: pays,
                             etat: reconditionne ? .reconditionneTiers : .neuf, titre: titre, c: c,
                             couleur: couleurFrancaise(titre), affichage: titre.uppercased().contains("PROLED") ? "PROLED" : "standard",
                             clavier: nil, prix: p, url: b.url,
                             livraison: pays == "FR" ? .oui : .aVerifier, remarque: rem) {
                out.append(o)
            }
        }
        return out
    }

    /// Leboncoin (annonces autour de Paris, 20 km) : particuliers et professionnels. Pas de garantie pour un particulier.
    static func leboncoin(_ blocs: [SuiviBlocWeb], rayonKm: Double = 20) -> [SuiviOffre] {
        let parisLat = 48.8566, parisLng = 2.3522
        var out: [SuiviOffre] = []
        for b in blocs {
            guard let d = b.donnees, let prix = Double(d["prix"] ?? ""), prix >= 1500, prix <= 9000 else { continue }
            let titre = SuiviTexte.decoder(b.titre)
            let corps = SuiviTexte.decoder(b.texte)
            let tout = titre + " " + corps
            let bas = tout.lowercased()
            // Accessoires, pièces, appareils bloqués ou demandes d'achat : pas des offres.
            if SuiviTexte.premier(#"\b(coque|housse|chargeur|câble|pour pièces|hs\b|cassé|casse\b|fissur|bloqué|icloud|verrouill|je recherche|recherche un|échange)"#,
                                  dans: bas) != nil { continue }
            var c = SuiviCaracteristiques.lire(tout)
            if c.ram == nil {   // « M4 Max 36 1to » : la mémoire n'est pas toujours suivie de « Go »
                if let m = SuiviTexte.premier(#"\b(36|48)\b(?!\s*(?:cycles?|%|mm|cm|w\b))"#, dans: titre) { c.ram = Int(m[1]) }
            }
            var km: Double?
            if let lat = Double(d["lat"] ?? ""), let lng = Double(d["lng"] ?? "") {
                let dLat = (lat - parisLat) * .pi / 180, dLng = (lng - parisLng) * .pi / 180
                let a = sin(dLat / 2) * sin(dLat / 2) + cos(parisLat * .pi / 180) * cos(lat * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
                km = 6371 * 2 * atan2(sqrt(a), sqrt(1 - a))
                if let k = km, k > rayonKm { continue }
            }
            let pro = d["pro"] == "pro"
            let clavier = bas.contains("qwertz") ? "QWERTZ" : (bas.contains("qwerty") ? "QWERTY" : (bas.contains("azerty") ? "AZERTY" : "inconnu"))
            let neuf = ["neuf", "jamais utilis", "scell"].contains { bas.contains($0) }
            let nano = bas.contains("nano")
            let ville = [d["ville"], d["cp"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let rem = (pro ? "Annonce de professionnel : garantie à demander. " : "Particulier : aucune garantie légale ; vérifier la facture, le numéro de série, l'écran « Localiser » désactivé et l'état de la batterie ; remise en main propre conseillée. ")
                + "Prix et état tels qu'annoncés."
            if var o = offre(key: "leboncoin|\(b.url)", source: pro ? "Leboncoin (professionnel)" : "Leboncoin (particulier)", pays: "FR",
                             etat: .occasion, titre: titre, c: c, affichage: nano ? "nano-texturé" : (bas.contains("proled") ? "PROLED" : "standard"),
                             clavier: clavier, prix: prix, url: b.url, livraison: .aVerifier, remarque: rem,
                             grade: neuf ? "Annoncé comme neuf" : nil, ecranOptionnel: true) {
                o.ville = ville
                o.distanceKm = km
                o.vendeurPro = pro
                out.append(o)
            }
        }
        return out
    }

    /// Rue du Commerce (places de marché, souvent du reconditionné) : « Ancien prix : X Y » -> le prix à payer est le dernier.
    static func rueDuCommerce(_ blocs: [SuiviBlocWeb]) -> [SuiviOffre] {
        depuisBlocs(blocs, source: "Rue du Commerce", pays: "FR", livraison: .oui, clavier: "AZERTY",
                    remarque: "Vendeur de la place de marché : vendeur, état et garantie à vérifier sur la fiche.") { texte in
            prixEuros(texte).last.map { ($0, "") }
        }
    }

    /// Okamac (reconditionné, France) : les produits de la page sont décrits dans la variable JavaScript `cdcDatalayer`.
    static func okamac(_ html: String, rechercheURL: String) -> [SuiviOffre] {
        let data = Data(html.utf8)
        guard let r = data.range(of: Data("cdcDatalayer = ".utf8)),
              let debut = data[r.upperBound...].firstIndex(of: 0x7B),
              let fin = finTableau(data, depuis: debut),
              let obj = try? JSONSerialization.jsonObject(with: data.subdata(in: debut..<(fin + 1))) as? [String: Any],
              let items = (obj["ecommerce"] as? [String: Any])?["items"] as? [[String: Any]] else { return [] }
        var out: [SuiviOffre] = []
        for it in items {
            guard let nom = it["item_name"] as? String, let variante = it["item_variant"] as? String,
                  let prix = (it["price"] as? String).flatMap(Double.init) ?? (it["price"] as? Double) else { continue }
            let c = SuiviCaracteristiques.lire(nom + ", " + variante)
            let etat = variante.components(separatedBy: ", ").first { $0.lowercased().contains("état") || $0.lowercased().contains("etat") }
            if let o = offre(key: "okamac|\((it["item_id"] as? String) ?? nom)", source: "Okamac", pays: "FR", etat: .reconditionneTiers,
                             titre: "\(nom) — \(variante)", c: c, couleur: couleurFrancaise(variante), clavier: "AZERTY",
                             prix: prix, url: rechercheURL, livraison: .oui,
                             remarque: "Reconditionné par Okamac (Paris) ; le lien ouvre la recherche Okamac.",
                             grade: etat?.trimmingCharacters(in: .whitespaces)) {
                out.append(o)
            }
        }
        return out
    }

    /// Lit une chaîne JSON échappée qui commence juste après `cle` (jusqu'au guillemet non échappé) et la décode.
    static func chaineJSON(apres cle: String, dans html: String) -> String? {
        guard let r = html.range(of: cle) else { return nil }
        var fin = r.upperBound
        var echappe = false
        while fin < html.endIndex {
            let c = html[fin]
            if echappe { echappe = false } else if c == "\\" { echappe = true } else if c == "\"" { break }
            fin = html.index(after: fin)
        }
        guard fin < html.endIndex else { return nil }
        let brute = "\"" + String(html[r.upperBound..<fin]) + "\""
        guard let d = brute.data(using: .utf8),
              let s = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) as? String else { return nil }
        return s
    }
}

// MARK: - Sources et réseau

struct SuiviSource {
    var nom: String
    var urls: [String]
    var lire: (String, String) -> [SuiviOffre] = { _, _ in [] }     // (page, url) -> offres (lecture simple)
    var lireBlocs: (([SuiviBlocWeb], String) -> [SuiviOffre])? = nil  // lecture avec WebKit : (fiches, url) -> offres
    var extracteur: SuiviExtracteur = .generique

    static let toutes: [SuiviSource] = {
        let pays: [(String, String)] = [("FR", "fr"), ("DE", "de"), ("AT", "at"), ("IT", "it"), ("ES", "es"), ("NL", "nl"), ("IE", "ie")]
        var s: [SuiviSource] = pays.map { code, chemin in
            SuiviSource(nom: code == "FR" ? "Apple reconditionné" : "Apple reconditionné (\(code))",
                        urls: ["https://www.apple.com/\(chemin)/shop/refurbished/mac/macbook-pro"],
                        lire: { page, _ in SuiviLecteurs.apple(page, pays: code, base: "https://www.apple.com") })
        }
        s.append(SuiviSource(nom: "LDLC", urls: ["48", "36"].map { "https://www.ldlc.com/recherche/macbook%20pro%20m5%20max%20\($0)%20go/" },
                             lire: { page, _ in SuiviLecteurs.ldlc(page) }))
        s.append(SuiviSource(nom: "Materiel.net", urls: ["48", "36"].map { "https://www.materiel.net/recherche/macbook%20pro%20m5%20max%20\($0)%20go/" },
                             lire: { page, _ in SuiviLecteurs.materiel(page) }))
        s.append(SuiviSource(nom: "Boulanger", urls: ["https://www.boulanger.com/resultats?tr=macbook%20pro%20m5%20max"],
                             lire: { page, _ in SuiviLecteurs.boulanger(page) }))
        s.append(SuiviSource(nom: "Alternate.de", urls: ["https://www.alternate.de/listing.xhtml?q=macbook%20pro%20m5%20max"],
                             lire: { page, url in SuiviLecteurs.alternate(page, rechercheURL: url) }))
        s.append(SuiviSource(nom: "mac-store24.com",
                             urls: ["m2", "m3", "m4", "m5"].flatMap { p in (p == "m2" ? ["64"] : ["36", "48"]).map { "https://mac-store24.com/fr/search?q=macbook%20pro%20\(p)%20max%20\($0)gb" } },
                             lire: { page, _ in SuiviLecteurs.macStore24(page) }))
        // Sites qui bloquent la lecture simple : lus avec WebKit (le moteur de Safari), une page à la fois.
        s.append(SuiviSource(nom: "Fnac", urls: ["48", "36"].map { "https://www.fnac.com/SearchResult/ResultList.aspx?Search=macbook+pro+m5+max+\($0)+go" },
                             lireBlocs: { b, _ in SuiviLecteurs.fnac(b) }))
        s.append(SuiviSource(nom: "Darty", urls: ["48", "36"].map { "https://www.darty.com/nav/recherche?text=macbook+pro+m5+max+\($0)+go" },
                             lireBlocs: { b, _ in SuiviLecteurs.darty(b) }))
        s.append(SuiviSource(nom: "MediaMarkt.de", urls: ["48", "36"].map { "https://www.mediamarkt.de/de/search.html?query=macbook%20pro%20m5%20max%20\($0)gb" },
                             lireBlocs: { b, _ in SuiviLecteurs.mediaMarkt(b) }))
        // Reconditionné, comparateurs et places de marché
        s.append(SuiviSource(nom: "RefurbMe (Back Market, Okamac, reBuy…)",
                             urls: ["m2-max", "m3-max", "m3-max?page=2", "m4-max", "m5-max", "m5-max?page=2"].map { "https://www.refurb.me/fr/refurbished/macbook/macbook-pro/\($0)" },
                             lireBlocs: { b, _ in SuiviLecteurs.refurbMe(b) }))
        s.append(SuiviSource(nom: "Amazon.fr",
                             urls: ["m5+max+36+go", "m5+max+48+go", "m4+max+reconditionn%C3%A9", "m3+max+reconditionn%C3%A9", "m2+max+64+go+reconditionn%C3%A9"].map { "https://www.amazon.fr/s?k=macbook+pro+\($0)" },
                             lireBlocs: { b, _ in SuiviLecteurs.amazon(b, pays: "FR") }))
        s.append(SuiviSource(nom: "Amazon.de",
                             urls: ["m5+max+36gb", "m5+max+48gb"].map { "https://www.amazon.de/s?k=macbook+pro+\($0)" },
                             lireBlocs: { b, _ in SuiviLecteurs.amazon(b, pays: "DE") }))
        for (code, domaine, requetes) in [("IT", "amazon.it", ["m5+max+36gb", "m5+max+48gb"]), ("ES", "amazon.es", ["m5+max+36gb", "m5+max+48gb"]),
                                          ("NL", "amazon.nl", ["m5+max+36gb", "m5+max+48gb"])] {
            s.append(SuiviSource(nom: "Amazon.\(code.lowercased())", urls: requetes.map { "https://www.\(domaine)/s?k=macbook+pro+\($0)" },
                                 lireBlocs: { b, _ in SuiviLecteurs.amazon(b, pays: code) }))
        }
        // Leboncoin : annonces dans un rayon de 20 km autour de Paris (catégorie ordinateurs)
        s.append(SuiviSource(nom: "Leboncoin (Paris, 20 km)",
                             urls: ["m2", "m3", "m4", "m5"].map { "https://www.leboncoin.fr/recherche?category=15&text=macbook%20pro%20\($0)%20max&locations=Paris_75000__48.8566_2.3522_5000_20000" },
                             lireBlocs: { b, _ in SuiviLecteurs.leboncoin(b) }, extracteur: .leboncoin))
        s.append(SuiviSource(nom: "Kleinanzeigen.de",
                             urls: ["m2-max-64gb", "m3-max", "m4-max", "m5-max"].map { "https://www.kleinanzeigen.de/s-macbook-pro-\($0)/k0" },
                             lire: { page, _ in SuiviLecteurs.kleinanzeigen(page) }))
        s.append(SuiviSource(nom: "Rue du Commerce",
                             urls: ["m4", "m5"].map { "https://www.rueducommerce.fr/recherche/macbook%20pro%20\($0)%20max" },
                             lireBlocs: { b, _ in SuiviLecteurs.rueDuCommerce(b) }))
        s.append(SuiviSource(nom: "Okamac",
                             urls: ["m2", "m3", "m4", "m5"].map { "https://www.okamac.com/recherche?controller=search&s=macbook+pro+\($0)+max" },
                             lire: { page, url in SuiviLecteurs.okamac(page, rechercheURL: url) }))
        return s
    }()
}

enum SuiviReseau {
    static func page(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u, timeoutInterval: 30)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("fr-FR,fr;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, rep) = try await URLSession.shared.data(for: req)
        if let h = rep as? HTTPURLResponse, h.statusCode >= 400 {
            throw NSError(domain: "SuiviMac", code: h.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "le site a répondu « \(h.statusCode) » (accès refusé ou page absente)"])
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Un relevé complet : toutes les sources en parallèle ; une source en panne ne bloque pas les autres.
enum SuiviReleveur {
    /// Lit une page, avec un 2ᵉ essai si le site n'a pas répondu à temps. Lecture simple d'abord ; si elle ne donne
    /// aucune offre (le site a servi une page de blocage sans erreur), on relit la page avec WebKit, comme Safari.
    static func lireUnePage(_ source: SuiviSource, url: String) async throws -> [SuiviOffre] {
        var essai = 0
        while true {
            do {
                if let lireBlocs = source.lireBlocs {
                    let blocs = try await SuiviWebKit.shared.blocs(url: url, extracteur: source.extracteur)
                    return lireBlocs(blocs, url)
                }
                let offres = source.lire(try await SuiviReseau.page(url), url)
                if !offres.isEmpty { return offres }
                let html = try await SuiviWebKit.shared.html(url: url)
                return source.lire(html, url)
            } catch {
                essai += 1
                if essai >= 2 || !erreurTemporaire(error) { throw error }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private static func erreurTemporaire(_ e: Error) -> Bool {
        let n = e as NSError
        if n.domain == NSURLErrorDomain { return true }   // délai dépassé, connexion perdue…
        return n.domain == "SuiviMac" && n.code == 3      // le moteur de la page s'est arrêté
    }

    static func releverTout() async -> SuiviReleve {
        var offres: [SuiviOffre] = []
        var erreurs: [String: String] = [:]
        var comptes: [String: Int] = [:]
        await withTaskGroup(of: (String, Result<[SuiviOffre], Error>).self) { groupe in
            for source in SuiviSource.toutes {
                groupe.addTask {
                    // Une page qui échoue ne fait pas échouer toute la source : on garde les autres pages,
                    // et la source n'est en erreur que si AUCUNE page n'a pu être lue.
                    var tout: [SuiviOffre] = []
                    var derniereErreur: Error?
                    var lues = 0
                    for url in source.urls {
                        do {
                            tout += try await SuiviReleveur.lireUnePage(source, url: url)
                            lues += 1
                        } catch {
                            derniereErreur = error
                        }
                    }
                    if lues == 0, let e = derniereErreur { return (source.nom, .failure(e)) }
                    return (source.nom, .success(tout))
                }
            }
            for await (nom, resultat) in groupe {
                switch resultat {
                case .success(let o): offres += o; comptes[nom] = o.count
                case .failure(let e): erreurs[nom] = e.localizedDescription
                }
            }
        }
        // mac-store24 renvoie les mêmes variantes pour plusieurs recherches : on enlève les doublons.
        var vus = Set<String>()
        offres = offres.filter { vus.insert($0.key).inserted }
        return SuiviReleve(date: Date(), offres: offres, erreurs: erreurs, comptes: comptes)
    }
}
#endif
