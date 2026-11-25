import SwiftUI

// Look commun de l'application : mêmes cartes, mêmes étiquettes, mêmes en-têtes sur tous les écrans.

/// Couleur et pictogramme d'une matière, d'après son nom.
enum SubjectStyle {
    static func color(_ name: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .red]
        let h = name.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return palette[abs(h) % palette.count]
    }
    static func symbol(_ name: String) -> String {
        let n = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        if n.contains("math") { return "function" }
        if n.contains("physique") || n.contains("chimie") { return "atom" }
        if n.contains("histoire") || n.contains("geo") { return "globe.europe.africa" }
        if n.contains("francais") { return "text.book.closed" }
        if n.contains("anglais") { return "character.bubble" }
        if n.contains("atelier") { return "bolt.fill" }
        if n.contains("eco") || n.contains("gestion") { return "chart.bar" }
        if n.contains("pse") { return "cross.case" }
        if n.contains("co-int") { return "person.2" }
        if n.contains("original") { return "archivebox" }
        return "folder.fill"
    }
}

/// Petite étiquette arrondie (« Évaluation », « Déjà rempli »…).
extension CourseDigest {
    /// Couleur de l'étiquette d'état : à compléter (orange), partiel (ambre lisible), complet (vert).
    /// Ambre plus sombre que `.yellow` (illisible en clair) ; jaune système en mode sombre.
    private static let amber = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemYellow : NSColor(red: 0.62, green: 0.40, blue: 0.0, alpha: 1)
    })
    var badgeColor: Color {
        switch state { case .vide: return .orange; case .partiel: return Self.amber; case .complet: return .green }
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold)).foregroundStyle(color.mix(with: .primary, by: 0.35))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// En-tête commun : grand titre arrondi, sous-titre, actions à droite, léger dégradé.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 26, weight: .bold, design: .rounded)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

extension View {
    /// Carte arrondie : fond discret, contour fin ; `selected` la met en couleur.
    func card(selected: Bool = false, padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)))
    }
}
