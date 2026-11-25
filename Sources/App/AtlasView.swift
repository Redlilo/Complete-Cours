#if COMPTE_PERSO
import SwiftUI
import AppKit
import WebKit

// « Atlas des skills » (variante personnelle) : la page HTML Resources/Perso/Atlas.html, affichée dans l'app.
// Elle est copiée dans le paquet seulement par `./build.sh --personnel` ; la version distribuable ne la contient pas.
// Les liens vers d'autres sites s'ouvrent dans le navigateur ; la page elle-même ne quitte jamais l'app.

struct AtlasView: View {
    private var fichier: URL? { Bundle.main.url(forResource: "Atlas", withExtension: "html", subdirectory: "Perso") }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Atlas des skills",
                         subtitle: "Mes skills classés par utilité, mes outils et comment les déclencher") { EmptyView() }
            if let fichier {
                AtlasWebView(fichier: fichier)
            } else {
                ContentUnavailableView("Atlas introuvable",
                                       systemImage: "map",
                                       description: Text("Recompile avec ./build.sh --personnel : la page doit se trouver dans Resources/Perso/Atlas.html."))
            }
        }
    }
}

private struct AtlasWebView: NSViewRepresentable {
    let fichier: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()   // rien n'est gardé : ni cookies ni historique
        let vue = WKWebView(frame: .zero, configuration: cfg)
        vue.navigationDelegate = context.coordinator
        vue.setValue(false, forKey: "drawsBackground")
        vue.loadFileURL(fichier, allowingReadAccessTo: fichier.deletingLastPathComponent())
        return vue
    }

    func updateNSView(_ vue: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Liens vers le web : navigateur par défaut. Ancres et fichier local : dans la page.
            if action.navigationType == .linkActivated, let url = action.request.url,
               let schema = url.scheme, schema == "http" || schema == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
#endif
