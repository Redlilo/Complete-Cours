import SwiftUI

// « Fonctionnement » : briques de dessin communes aux schémas (cases, flèches, légendes).
// Tout est en SwiftUI pur : les cases sont de vrais textes (lus par VoiceOver), seules les flèches sont des formes
// (cachées à VoiceOver). Les couleurs suivent le mode clair / sombre.

/// Couleur d'une case : le sens est toujours aussi donné par le texte, jamais par la couleur seule.
enum FoncTeinte {
    case bleu, vert, orange, violet, gris, rouge
}

struct FoncPalette {
    let sombre: Bool

    func fond(_ t: FoncTeinte) -> Color {
        switch (t, sombre) {
        case (.bleu, false): return Color(red: 0.88, green: 0.93, blue: 1.0)
        case (.bleu, true): return Color(red: 0.13, green: 0.20, blue: 0.32)
        case (.vert, false): return Color(red: 0.88, green: 0.96, blue: 0.89)
        case (.vert, true): return Color(red: 0.13, green: 0.25, blue: 0.17)
        case (.orange, false): return Color(red: 1.0, green: 0.93, blue: 0.82)
        case (.orange, true): return Color(red: 0.33, green: 0.23, blue: 0.10)
        case (.violet, false): return Color(red: 0.93, green: 0.90, blue: 1.0)
        case (.violet, true): return Color(red: 0.23, green: 0.17, blue: 0.34)
        case (.gris, false): return Color(red: 0.94, green: 0.94, blue: 0.95)
        case (.gris, true): return Color(red: 0.20, green: 0.20, blue: 0.22)
        case (.rouge, false): return Color(red: 1.0, green: 0.90, blue: 0.89)
        case (.rouge, true): return Color(red: 0.34, green: 0.15, blue: 0.14)
        }
    }

    func trait(_ t: FoncTeinte) -> Color {
        switch (t, sombre) {
        case (.bleu, false): return Color(red: 0.25, green: 0.48, blue: 0.85)
        case (.bleu, true): return Color(red: 0.42, green: 0.64, blue: 1.0)
        case (.vert, false): return Color(red: 0.20, green: 0.60, blue: 0.30)
        case (.vert, true): return Color(red: 0.40, green: 0.80, blue: 0.50)
        case (.orange, false): return Color(red: 0.85, green: 0.50, blue: 0.10)
        case (.orange, true): return Color(red: 1.0, green: 0.70, blue: 0.30)
        case (.violet, false): return Color(red: 0.50, green: 0.35, blue: 0.80)
        case (.violet, true): return Color(red: 0.70, green: 0.58, blue: 1.0)
        case (.gris, false): return Color(red: 0.55, green: 0.55, blue: 0.58)
        case (.gris, true): return Color(red: 0.62, green: 0.62, blue: 0.66)
        case (.rouge, false): return Color(red: 0.80, green: 0.25, blue: 0.22)
        case (.rouge, true): return Color(red: 1.0, green: 0.50, blue: 0.46)
        }
    }

    var texte: Color { sombre ? Color(white: 0.95) : Color(white: 0.08) }
    var discret: Color { sombre ? Color(white: 0.72) : Color(white: 0.35) }
    var fleche: Color { sombre ? Color(white: 0.75) : Color(white: 0.30) }
    var page: Color { sombre ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0.98, green: 0.98, blue: 0.985) }
}

private struct FoncPaletteKey: EnvironmentKey { static let defaultValue = FoncPalette(sombre: false) }
extension EnvironmentValues {
    var foncPalette: FoncPalette {
        get { self[FoncPaletteKey.self] }
        set { self[FoncPaletteKey.self] = newValue }
    }
}

/// Fournit la palette selon le mode clair / sombre, avec un fond explicite.
struct FoncFond<Contenu: View>: View {
    @Environment(\.colorScheme) private var schema
    let contenu: Contenu
    init(@ViewBuilder _ contenu: () -> Contenu) { self.contenu = contenu() }
    var body: some View {
        let p = FoncPalette(sombre: schema == .dark)
        contenu.environment(\.foncPalette, p).background(p.page)
    }
}

// MARK: - Case

/// Une case : titre, phrase simple, et (en petit, pour les curieux) le nom du fichier ou du module.
struct FoncCase: View {
    @Environment(\.foncPalette) private var p
    let titre: String
    var detail: String = ""
    var fichier: String = ""
    var teinte: FoncTeinte = .bleu
    var symbole: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if !symbole.isEmpty {
                    Image(systemName: symbole).font(.callout).foregroundStyle(p.trait(teinte)).accessibilityHidden(true)
                }
                Text(titre).font(.callout.weight(.semibold)).foregroundStyle(p.texte)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(p.texte).fixedSize(horizontal: false, vertical: true)
            }
            if !fichier.isEmpty {
                Text(fichier).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.discret)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9).fill(p.fond(teinte)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(p.trait(teinte), lineWidth: 1.2))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Flèches

private struct FoncPointe: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Flèche vers le bas, centrée, avec une légende facultative à droite.
struct FoncFlecheCentre: View {
    @Environment(\.foncPalette) private var p
    var legende: String = ""
    var hauteur: CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(maxWidth: .infinity)
            VStack(spacing: 0) {
                Rectangle().fill(p.fleche).frame(width: 1.6, height: max(hauteur - 7, 2))
                FoncPointe().fill(p.fleche).frame(width: 9, height: 7)
            }
            .accessibilityHidden(true)
            Text(legende).font(.caption2).foregroundStyle(p.discret).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 8).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: hauteur)
    }
}

/// Une flèche qui se sépare en `n` branches (ou se rassemble si `fusion`), au-dessus d'une rangée de `n` cases.
struct FoncBranches: Shape {
    var n: Int
    var espace: CGFloat
    var fusion = false

    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = (r.width - CGFloat(n - 1) * espace) / CGFloat(n)
        let xs = (0..<n).map { CGFloat($0) * (w + espace) + w / 2 }
        let mid = r.midY
        if fusion {
            for x in xs { p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: mid)) }
            p.move(to: CGPoint(x: xs.first ?? 0, y: mid)); p.addLine(to: CGPoint(x: xs.last ?? 0, y: mid))
            p.move(to: CGPoint(x: r.midX, y: mid)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY - 6))
            p.move(to: CGPoint(x: r.midX - 4.5, y: r.maxY - 7)); p.addLine(to: CGPoint(x: r.midX + 4.5, y: r.maxY - 7))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.closeSubpath()
        } else {
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: mid))
            p.move(to: CGPoint(x: xs.first ?? 0, y: mid)); p.addLine(to: CGPoint(x: xs.last ?? 0, y: mid))
            for x in xs {
                p.move(to: CGPoint(x: x, y: mid)); p.addLine(to: CGPoint(x: x, y: r.maxY - 6))
                p.move(to: CGPoint(x: x - 4.5, y: r.maxY - 7)); p.addLine(to: CGPoint(x: x + 4.5, y: r.maxY - 7))
                p.addLine(to: CGPoint(x: x, y: r.maxY)); p.closeSubpath()
            }
        }
        return p
    }
}

/// Séparation en branches suivie de la rangée de cases (de même hauteur).
struct FoncRangee<Contenu: View>: View {
    @Environment(\.foncPalette) private var p
    let n: Int
    var avecBranches = true
    let contenu: Contenu
    private let espace: CGFloat = 8

    init(_ n: Int, branches: Bool = true, @ViewBuilder _ contenu: () -> Contenu) {
        self.n = n; self.avecBranches = branches; self.contenu = contenu()
    }

    var body: some View {
        VStack(spacing: 0) {
            if avecBranches {
                FoncBranches(n: n, espace: espace)
                    .stroke(p.fleche, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(height: 22)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: espace) { contenu }
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Rassemblement : `n` colonnes qui se rejoignent en une flèche vers le bas.
struct FoncFusion: View {
    @Environment(\.foncPalette) private var p
    let n: Int
    var body: some View {
        FoncBranches(n: n, espace: 8, fusion: true)
            .stroke(p.fleche, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            .frame(height: 22)
            .accessibilityHidden(true)
    }
}

// MARK: - Textes de page

/// En-tête d'un schéma : titre et phrase d'explication.
struct FoncEntete: View {
    @Environment(\.foncPalette) private var p
    let numero: Int
    let titre: String
    let intro: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(numero). \(titre)").font(.title3.weight(.bold)).foregroundStyle(p.texte)
                .accessibilityAddTraits(.isHeader)
            Text(intro).font(.callout).foregroundStyle(p.texte).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Petit titre de section dans un schéma.
struct FoncTitre: View {
    @Environment(\.foncPalette) private var p
    let texte: String
    var body: some View {
        Text(texte).font(.subheadline.weight(.bold)).foregroundStyle(p.texte)
            .padding(.top, 10).accessibilityAddTraits(.isHeader)
    }
}

/// Légende : pastille de couleur + sens.
struct FoncLegende: View {
    @Environment(\.foncPalette) private var p
    let elements: [(FoncTeinte, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(elements.enumerated()), id: \.offset) { _, e in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(p.fond(e.0))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(p.trait(e.0), lineWidth: 1))
                        .frame(width: 14, height: 14).accessibilityHidden(true)
                    Text(e.1).font(.caption).foregroundStyle(p.texte)
                }
            }
        }
    }
}

/// Remarque en bas d'un schéma.
struct FoncNote: View {
    @Environment(\.foncPalette) private var p
    let texte: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(p.discret).accessibilityHidden(true)
            Text(texte).font(.caption).foregroundStyle(p.discret).fixedSize(horizontal: false, vertical: true)
        }
    }
}
