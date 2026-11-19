import SwiftUI
import AppKit

/// « Supprimer les doublons » : lit tous les PDF, regroupe les doublons, met à la Corbeille ce que l'élève valide.
@MainActor
final class DuplicatesModel: ObservableObject {
    enum Phase: Equatable { case idle, reading(Double, String), ready, done(String) }

    @Published var phase: Phase = .idle
    @Published var groups: [DuplicateGroup] = []
    @Published var keep: [UUID: URL] = [:]
    @Published var removeSimilar = Set<UUID>()      // groupes « très semblables » que l'élève a choisi de nettoyer
    private var task: Task<Void, Never>?

    func run() {
        guard phase == .idle || phase == .ready || { if case .done = phase { return true }; return false }() else { return }
        let library = LibraryModel.shared
        let files = library.files, root = library.root
        let completions = CourseLedger.shared.completions
        groups = []; keep = [:]; removeSimilar = []
        phase = .reading(0, "Lecture des PDF…")
        task = Task {
            let found = await Task.detached(priority: .userInitiated) {
                DuplicateFinder.find(files: files, root: root, completions: completions,
                                     isCancelled: { Task.isCancelled },
                                     progress: { f, label in Task { @MainActor in if case .reading = self.phase { self.phase = .reading(f, label) } } })
            }.value
            if Task.isCancelled { phase = .idle; return }
            groups = found
            keep = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.keep) })
            phase = .ready
        }
    }

    func cancel() { task?.cancel() }

    /// Fichiers qui partiraient à la Corbeille : tout sauf le gardé, pour les identiques ; pour les très semblables,
    /// seulement si l'élève a coché le groupe.
    func toRemove(_ g: DuplicateGroup) -> [DuplicateCandidate] {
        let kept = keep[g.id] ?? g.keep
        if case .tresSemblables = g.kind, !removeSimilar.contains(g.id) { return [] }
        return g.files.filter { $0.url != kept }
    }

    var totalToRemove: Int { groups.reduce(0) { $0 + toRemove($1).count } }

    func apply() {
        let n = totalToRemove
        guard n > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Mettre \(n) fichier\(n > 1 ? "s" : "") à la Corbeille ?"
        alert.informativeText = "Ils ne sont pas supprimés définitivement : tu pourras les récupérer avec « Remettre » dans la Corbeille du Finder. Les fichiers gardés ne sont pas touchés."
        alert.addButton(withTitle: "Mettre à la Corbeille"); alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var trashed = 0, refused: [String] = []
        for g in groups {
            var g2 = g; g2.keep = keep[g.id] ?? g.keep
            let r = DuplicateFinder.trash(g2, removing: Set(toRemove(g).map(\.url)))
            trashed += r.trashed.count; refused += r.refused
        }
        phase = .done("\(trashed) fichier\(trashed > 1 ? "s" : "") mis à la Corbeille." + (refused.isEmpty ? "" : "\n" + refused.joined(separator: "\n")))
        groups = []
        LibraryModel.shared.refresh()
    }
}

struct DuplicatesSheet: View {
    @StateObject private var model = DuplicatesModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: "Supprimer les doublons", subtitle: "Lit tous les PDF et compare leur contenu. Les évaluations ne sont jamais lues.") {
                Button("Fermer") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { model.run() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .reading(let f, let label):
            VStack(spacing: 12) {
                ProgressView(value: f).frame(maxWidth: 360)
                Text(label).foregroundStyle(.secondary).lineLimit(1)
                Button("Arrêter") { model.cancel() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let message):
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle").font(.system(size: 36)).foregroundStyle(.green)
                Text(message).multilineTextAlignment(.center)
                Button("Chercher de nouveau") { model.run() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
        case .ready:
            if model.groups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.system(size: 36)).foregroundStyle(.green)
                    Text("Aucun doublon : chaque PDF est différent des autres.").multilineTextAlignment(.center)
                    Text("Une version vide et sa version complétée ne comptent pas comme des doublons.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.groups) { g in groupCard(g) }
                    }.padding(16)
                }
                Divider()
                HStack {
                    Text(model.totalToRemove == 0 ? "Rien n'est sélectionné." : "\(model.totalToRemove) fichier\(model.totalToRemove > 1 ? "s" : "") à mettre à la Corbeille (récupérables).")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Mettre à la Corbeille") { model.apply() }
                        .buttonStyle(.borderedProminent).disabled(model.totalToRemove == 0)
                }.padding(14)
            }
        }
    }

    private func groupCard(_ g: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                switch g.kind {
                case .identiques: Tag(text: "Identiques", color: .green)
                case .tresSemblables(let p):
                    Tag(text: "Très semblables (\(p) %)", color: .orange)
                    Toggle("Nettoyer ce groupe", isOn: Binding(get: { model.removeSimilar.contains(g.id) },
                                                              set: { if $0 { model.removeSimilar.insert(g.id) } else { model.removeSimilar.remove(g.id) } }))
                        .toggleStyle(.switch).controlSize(.small)
                    Text("à vérifier avant de cocher").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ForEach(g.files) { c in
                let kept = (model.keep[g.id] ?? g.keep) == c.url
                HStack(spacing: 10) {
                    ThumbnailView(url: c.url, size: CGSize(width: 30, height: 40))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.url.lastPathComponent).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text("\(c.relativePath.split(separator: "/").dropLast().joined(separator: " › ")) · \(ByteCountFormatter.string(fromByteCount: c.size, countStyle: .file)) · \(c.pages) p.")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if kept { Label("Gardé", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption.weight(.semibold)) }
                    else {
                        Button("Garder celui-ci") { model.keep[g.id] = c.url }.controlSize(.small)
                        Text(model.toRemove(g).contains(where: { $0.url == c.url }) ? "→ Corbeille" : "laissé").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .card()
    }
}
