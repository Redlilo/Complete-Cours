import SwiftUI
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

// Vues des schémas électriques : aperçu d'un schéma dessiné (liste des zones) et onglet « Schémas » des Réglages
// (exemples déjà remplis montrés à Opus 5.5). Le dessin lui-même est fait par SchemaRenderer (Core).

// MARK: - Aperçu d'un schéma

enum SchemaPreview {
    /// Le schéma dessiné sur fond blanc, à l'encre du style d'écriture choisi. nil si l'image ne peut pas être fabriquée.
    static func image(_ schema: SchemaElectrique, largeur: CGFloat = 560) -> NSImage? {
        let ratio = schema.largeurGrille > 0 && schema.hauteurGrille > 0 ? schema.hauteurGrille / schema.largeurGrille : 0.5
        let marge: CGFloat = 8
        let w = Int(largeur), h = max(40, min(2000, Int(largeur * CGFloat(min(ratio, 4)))))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let style = WritingStyle.named(UserDefaults.standard.string(forKey: Pref.writingStyle) ?? Pref.defaultStyle)
        let encre = CGColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: 1)
        SchemaRenderer.dessiner(schema, dans: CGRect(x: marge, y: marge, width: CGFloat(w) - 2 * marge, height: CGFloat(h) - 2 * marge),
                                ctx: ctx, couleur: encre)
        guard let image = ctx.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: w, height: h))
    }
}

/// Miniature d'un schéma dessiné.
struct SchemaThumbnail: View {
    let schema: SchemaElectrique
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.clear.frame(height: 50)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 190)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
        .onAppear { image = SchemaPreview.image(schema) }
        .onChange(of: schema) { _, new in image = SchemaPreview.image(new) }
        .accessibilityLabel("Aperçu du schéma : \(schema.symboles.count) symboles")
    }
}

// MARK: - Progression d'un schéma en cours

/// Carte affichée pendant qu'Opus dessine : message, temps écoulé (se remet à zéro à chaque schéma) et rappel que l'attente peut durer.
struct SchemaProgressCard: View {
    let progress: RunProgress
    let cancel: () -> Void
    @State private var debut = Date()

    static func duree(_ s: Int) -> String { s < 60 ? "\(s) s" : "\(s / 60) min \(String(format: "%02d", s % 60)) s" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Opus dessine le schéma…").font(.callout.weight(.medium))
            Text(progress.label).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: debut, by: 1)) { ctx in
                    Text("Temps écoulé : \(Self.duree(max(0, Int(ctx.date.timeIntervalSince(debut)))))")
                        .font(.caption.monospacedDigit())
                }
                Spacer()
                Button("Annuler", action: cancel).controlSize(.small)
            }
            Text("Cela prend en général de 1 à 5 minutes : tu peux laisser la fenêtre ouverte.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.35)))
        .id(progress.label)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Opus dessine le schéma, \(progress.label)")
    }
}

// MARK: - Réglages : onglet « Schémas »

struct SchemaSettings: View {
    private let store = SchemaExemples.shared
    @State private var exemples: [SchemaExemple] = []
    @State private var pdf: URL?
    @State private var pageCount = 0
    @State private var numeroPage = 1
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Quand tu marques une zone « Schéma électrique », Claude Opus 5.5 dessine le schéma dans ton cadre. "
                     + "Pour qu'il imite le style de ton cours, montre-lui des pages où le schéma est déjà juste.")
                    .fixedSize(horizontal: false, vertical: true)
                Label("Les symboles suivent la norme CEI 60617 (NF EN 60617).", systemImage: "checkmark.seal")
                    .font(.callout)
                Label("Les schémas utilisent uniquement Claude Opus 5.5 : ta clé API (Réglages, onglet Moteur)"
                      + (accountNote ? ", ou ton compte Claude." : "."), systemImage: "bolt.horizontal")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Confidentialité : la page du cours et les exemples sont envoyés à Anthropic au moment où tu demandes un schéma.",
                      systemImage: "paperplane.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                HStack {
                    Text("Exemples déjà remplis").font(.headline)
                    Text("\(exemples.count) sur \(SchemaExemples.maximum)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { choisirPDF() } label: { Label("Ajouter un exemple…", systemImage: "plus") }
                        .disabled(exemples.count >= SchemaExemples.maximum)
                }
                Text("À chaque schéma, jusqu'à 3 exemples sont montrés à Opus : ceux dont le titre ressemble au nom du cours, puis les plus récents.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let pdf { choixPage(pdf) }
                if let message {
                    Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if exemples.isEmpty {
                    Text("Aucun exemple pour l'instant : Opus dessine avec ses seules connaissances de la norme.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(exemples) { e in
                        SchemaExempleLigne(exemple: e, store: store, supprimer: { supprimer(e) })
                    }
                }
            }
            .padding(20)
        }
        .onAppear { exemples = store.exemples }
    }

    private var accountNote: Bool {
        #if COMPTE_PERSO
        return true
        #else
        return false
        #endif
    }

    private func choixPage(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Stepper("Page \(numeroPage) sur \(pageCount)", value: $numeroPage, in: 1...max(pageCount, 1))
            Button("Ajouter") { ajouter(url) }.buttonStyle(.borderedProminent)
            Button("Annuler") { pdf = nil }
        }
        .controlSize(.small)
        .card(padding: 10)
    }

    private func choisirPDF() {
        message = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choisis le PDF qui contient une page où le schéma est déjà rempli"
        panel.prompt = "Choisir"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            message = "Ce fichier n'est pas un PDF lisible."
            return
        }
        pdf = url
        pageCount = doc.pageCount
        numeroPage = 1
    }

    private func ajouter(_ url: URL) {
        do {
            try store.ajouter(pdf: url, numeroPage: numeroPage)
            exemples = store.exemples
            pdf = nil
            message = nil
        } catch {
            message = Fr.sentence(error.localizedDescription)
        }
    }

    private func supprimer(_ e: SchemaExemple) {
        do { try store.supprimer(e.id); exemples = store.exemples }
        catch { message = Fr.sentence(error.localizedDescription) }
    }
}

/// Un exemple : miniature, titre et note modifiables, bouton « Supprimer ».
struct SchemaExempleLigne: View {
    let exemple: SchemaExemple
    let store: SchemaExemples
    let supprimer: () -> Void
    @State private var titre = ""
    @State private var note = ""
    @State private var miniature: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let miniature {
                    Image(nsImage: miniature).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 96, height: 124)
            .background(Color.white)
            .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.15)))
            VStack(alignment: .leading, spacing: 6) {
                TextField("Titre", text: $titre).textFieldStyle(.roundedBorder)
                TextField("Note pour l'IA (ex. « le neutre est en bleu »)", text: $note, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(role: .destructive, action: supprimer) { Label("Supprimer", systemImage: "trash") }
                        .controlSize(.small)
                }
            }
        }
        .card(padding: 10)
        .onAppear {
            titre = exemple.titre
            note = exemple.note
            miniature = Self.miniature(of: store.fichier(exemple))
        }
        .onChange(of: titre) { _, _ in try? store.modifier(exemple.id, titre: titre, note: note) }
        .onChange(of: note) { _, _ in try? store.modifier(exemple.id, titre: titre, note: note) }
    }

    /// Image réduite (le JPEG gardé fait 1400 px de large : inutile de l'afficher en entier).
    private static func miniature(of url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 300,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
