#if COMPTE_PERSO
import AppKit
import WebKit

// « Suivi MacBook IA » : lecture des sites qui bloquent la lecture simple (Fnac, Darty, MediaMarkt…).
// On charge la page avec WebKit, le moteur de Safari, dans une fenêtre invisible : pour le site, c'est une visite
// normale. Un script de la page repère ensuite les fiches « MacBook Pro » et renvoie leur titre, leur lien et leur texte ;
// les lecteurs de SuiviMacSources.swift en tirent les offres. Rien n'est enregistré (ni cookies ni identifiants).
// Si un site affiche une vérification « êtes-vous un robot ? », le relevé de ce site échoue sans bloquer les autres.

struct SuiviBlocWeb: Decodable, Sendable {
    var titre: String
    var url: String
    var texte: String
    var donnees: [String: String]? = nil   // champs précis fournis par l'extracteur (annonces Leboncoin)
}

enum SuiviExtracteur { case generique, leboncoin }

@MainActor
final class SuiviWebKit: NSObject, WKNavigationDelegate {
    static let shared = SuiviWebKit()

    private let vue: WKWebView
    private let fenetre: NSWindow
    private var chargement: CheckedContinuation<Void, Error>?
    private var occupe = false
    private var enAttente: [CheckedContinuation<Void, Never>] = []

    private override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        vue = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
        fenetre = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1280, height: 900),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        vue.navigationDelegate = self
        fenetre.isReleasedWhenClosed = false
        fenetre.ignoresMouseEvents = true
        fenetre.collectionBehavior = [.stationary, .ignoresCycle, .transient]
        fenetre.contentView = vue
        fenetre.orderBack(nil)   // hors écran ; sans fenêtre, WebKit suspend le JavaScript de la page
    }

    /// Une seule page à la fois : les demandes simultanées font la queue.
    private func prendreTour() async {
        if occupe { await withCheckedContinuation { enAttente.append($0) } } else { occupe = true }
    }
    private func libererTour() {
        if enAttente.isEmpty { occupe = false } else { enAttente.removeFirst().resume() }
    }

    /// Charge la page, laisse 6 secondes au JavaScript du site, puis renvoie les fiches « MacBook Pro » trouvées.
    func blocs(url: String, attente secondes: Double = 6, extracteur: SuiviExtracteur = .generique) async throws -> [SuiviBlocWeb] {
        await prendreTour()
        defer { libererTour() }
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            chargement = c
            vue.load(URLRequest(url: u, timeoutInterval: 60))
        }
        try await Task.sleep(for: .seconds(secondes))
        let res = try await vue.evaluateJavaScript(extracteur == .leboncoin ? Self.extracteurLeboncoin : Self.extracteurGenerique)
        guard let json = res as? String, let d = json.data(using: .utf8) else {
            throw NSError(domain: "SuiviMac", code: 1, userInfo: [NSLocalizedDescriptionKey: "la page n'a rien renvoyé"])
        }
        let blocs = try JSONDecoder().decode([SuiviBlocWeb].self, from: d)
        let page = (try? await vue.evaluateJavaScript("document.body.innerText.slice(0,1500)") as? String) ?? ""
        if blocs.isEmpty, page.range(of: "captcha|robot|denied|vérification", options: [.regularExpression, .caseInsensitive]) != nil {
            throw NSError(domain: "SuiviMac", code: 2, userInfo: [NSLocalizedDescriptionKey: "le site demande une vérification « êtes-vous un robot ? »"])
        }
        return blocs
    }

    /// Le code HTML de la page après exécution de son JavaScript (pour les lecteurs qui lisent du HTML brut).
    func html(url: String, attente secondes: Double = 5) async throws -> String {
        await prendreTour()
        defer { libererTour() }
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            chargement = c
            vue.load(URLRequest(url: u, timeoutInterval: 60))
        }
        try await Task.sleep(for: .seconds(secondes))
        return (try await vue.evaluateJavaScript("document.documentElement.outerHTML") as? String) ?? ""
    }

    private func fin(_ erreur: Error?) {
        guard let c = chargement else { return }
        chargement = nil
        if let erreur { c.resume(throwing: erreur) } else { c.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { fin(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fin(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fin(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fin(NSError(domain: "SuiviMac", code: 3, userInfo: [NSLocalizedDescriptionKey: "le moteur de la page s'est arrêté"]))
    }

    /// Repère chaque lien « MacBook Pro » et remonte jusqu'à la fiche produit : le plus petit bloc qui contient un prix
    /// (plus de 1 000 €) et un seul produit. Renvoie le titre, le lien et le texte du bloc.
    private static let extracteurGenerique = #"""
    (function(){
     const out=[]; const seen=new Set();
     const est=x=>/macbook\s+(apple\s+)?pro/i.test(x.textContent)&&x.textContent.length<250;
     const as=[...document.querySelectorAll('a')].filter(est);
     for(const a of as){
       let e=a, bloc=null;
       for(let i=0;i<10 && e.parentElement;i++){
         e=e.parentElement; const t=e.innerText||'';
         if(/\d{1,2}[\s .]?\d{3}(?:[,.]\d\d)?\s?€|\d{4,5},[–-]/.test(t)){
           const n=[...e.querySelectorAll('a')].filter(est).map(x=>x.href);
           if(new Set(n).size===1){bloc=e;break;}
         }
       }
       if(!bloc) continue;
       const href=a.href; if(seen.has(href)) continue; seen.add(href);
       out.push({titre:a.textContent.replace(/\s+/g,' ').trim(), url:href, texte:bloc.innerText.replace(/\s+/g,' ').slice(0,1800)});
     }
     return JSON.stringify(out);
    })()
    """#

    /// Leboncoin : les annonces de la page de recherche sont dans les données JSON de la page (`__NEXT_DATA__`).
    private static let extracteurLeboncoin = #"""
    (function(){
     const s=document.getElementById('__NEXT_DATA__'); if(!s) return '[]';
     let j; try{j=JSON.parse(s.textContent);}catch(e){return '[]';}
     const ads=(j.props&&j.props.pageProps&&j.props.pageProps.searchData&&j.props.pageProps.searchData.ads)||[];
     return JSON.stringify(ads.map(a=>({titre:a.subject||'', url:a.url||'', texte:(a.body||'').replace(/\s+/g,' ').slice(0,600),
       donnees:{prix:String((a.price&&a.price[0])||''), ville:String((a.location&&(a.location.city||a.location.city_label))||''),
                cp:String((a.location&&a.location.zipcode)||''), lat:String((a.location&&a.location.lat)||''),
                lng:String((a.location&&a.location.lng)||''), pro:String((a.owner&&a.owner.type)||''),
                date:String(a.first_publication_date||'')}})));
    })()
    """#
}
#endif
