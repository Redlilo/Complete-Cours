import SwiftUI

/// « Ranger les originaux vides » : on montre la liste, l'élève décoche ce qu'il veut garder, puis tout est rangé (annulable).
struct ArchiveSheet: View {
    @ObservedObject private var library = LibraryModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var plans: [ArchivePlan] = []
    @State private var chosen = Set<URL>()
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: "Ranger les originaux vides", subtitle: "On garde les versions complétées ; les PDF vides vont dans « \(OriginalsArchive.folderName) ».") {
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            if plans.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 34)).foregroundStyle(.green)
                    Text(message ?? "Aucun original vide à ranger : chaque cours complété est déjà seul dans son dossier.").multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
                List(plans) { p in
                    Toggle(isOn: Binding(get: { chosen.contains(p.id) }, set: { if $0 { chosen.insert(p.id) } else { chosen.remove(p.id) } })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.original.lastPathComponent).font(.body.weight(.medium))
                            Text("reste en place : \(p.completed.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                            Text("→ \(OriginalsArchive.folderName) › \(relative(p.destination))").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                HStack {
                    if let message { Text(message).font(.callout) }
                    Spacer()
                    Button("Ranger \(chosen.count) original\(chosen.count > 1 ? "s" : "")") { apply() }
                        .buttonStyle(.borderedProminent).disabled(chosen.isEmpty)
                }.padding(14)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .onAppear(perform: reload)
    }

    private func relative(_ url: URL) -> String {
        let base = LibraryModel.shared.root.appendingPathComponent(OriginalsArchive.folderName).standardizedFileURL.pathComponents.count
        return url.standardizedFileURL.pathComponents.dropFirst(base).dropLast().joined(separator: " › ")
    }

    private func reload() {
        plans = OriginalsArchive.plan(files: library.files, root: library.root, completions: CourseLedger.shared.completions)
        chosen = Set(plans.map(\.id))
    }

    private func apply() {
        var ids: [UUID] = [], failures: [String] = []
        for p in plans where chosen.contains(p.id) {
            do { ids.append(try OriginalsArchive.archive(p, ledger: CourseLedger.shared).id) }
            catch { failures.append(Fr.sentence(error.localizedDescription)) }
        }
        MoveHistory.shared.didMove(ids)
        message = "\(ids.count) original\(ids.count > 1 ? "s rangés" : " rangé"). Tu peux annuler depuis l'historique des rangements." + (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
        library.refresh()
        plans = []; chosen = []
    }
}
