import SwiftUI

// Réglages › Fonctionnement : schémas détaillés qui expliquent comment l'app marche.
// Tout est dessiné en SwiftUI (cases et flèches), sans image, en mode clair comme en sombre.

/// Les schémas, dans l'ordre. Le « Suivi MacBook IA » n'existe que dans la version perso.
enum FoncPage: String, CaseIterable, Identifiable {
    case ensemble, parcours, moteurs, depot, ecoute, schemas
    #if COMPTE_PERSO
    case suivi
    #endif
    case donnees, diagnostic

    var id: String { rawValue }

    var titre: String {
        switch self {
        case .ensemble: return "Vue d'ensemble"
        case .parcours: return "Parcours d'un PDF"
        case .moteurs: return "Les moteurs d'IA"
        case .depot: return "Dépôt automatique"
        case .ecoute: return "Écouter un cours"
        case .schemas: return "Schémas électriques"
        #if COMPTE_PERSO
        case .suivi: return "Suivi MacBook IA"
        #endif
        case .donnees: return "Données et vie privée"
        case .diagnostic: return "Diagnostic et bugs"
        }
    }

    var numero: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// Le schéma lui-même, à la largeur donnée par l'appelant.
    @ViewBuilder var contenu: some View {
        switch self {
        case .ensemble: FoncVueEnsemble(numero: numero)
        case .parcours: FoncParcoursPDF(numero: numero)
        case .moteurs: FoncMoteurs(numero: numero)
        case .depot: FoncDepot(numero: numero)
        case .ecoute: FoncEcoute(numero: numero)
        case .schemas: FoncSchemas(numero: numero)
        #if COMPTE_PERSO
        case .suivi: FoncSuiviMac(numero: numero)
        #endif
        case .donnees: FoncDonnees(numero: numero)
        case .diagnostic: FoncDiagnostic(numero: numero)
        }
    }
}

struct FonctionnementSettings: View {
    @State private var page: FoncPage = .ensemble

    var body: some View {
        VStack(spacing: 0) {
            barre
            Divider()
            ScrollView {
                FoncFond {
                    page.contenu
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(page)
            }
        }
    }

    private var barre: some View {
        HStack(spacing: 8) {
            Button { aller(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Schéma précédent")
                .disabled(page == FoncPage.allCases.first)
            Picker("Schéma", selection: $page) {
                ForEach(FoncPage.allCases) { p in Text("\(p.numero). \(p.titre)").tag(p) }
            }
            .labelsHidden()
            .accessibilityLabel("Choisir un schéma")
            Button { aller(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Schéma suivant")
                .disabled(page == FoncPage.allCases.last)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func aller(_ pas: Int) {
        let toutes = FoncPage.allCases
        guard let i = toutes.firstIndex(of: page), toutes.indices.contains(i + pas) else { return }
        page = toutes[i + pas]
    }
}
