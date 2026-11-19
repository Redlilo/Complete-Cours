import SwiftUI

/// Une zone de la liste : numéro, type, contexte, réponse modifiable et actions.
struct ZoneRow: View {
    @EnvironmentObject var model: CoursModel
    let zone: Zone
    @State private var draft = ""
    @State private var showOriginal = false
    @FocusState private var focused: Bool

    private var isSelected: Bool { model.selectedZoneID == zone.id }
    private var isManual: Bool { zone.source == .manuel }
    private var isIgnored: Bool { zone.kind == .ignorer }
    private var isThisRunning: Bool {
        if case .running(_, let id) = model.run { return id == zone.id }
        return false
    }
    private var hasAnswer: Bool { !zone.answer.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            badge
            VStack(alignment: .leading, spacing: 7) {
                topLine
                Text(zone.shortContext)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(zone.contextBefore)
                if isIgnored {
                    Text("Cette zone est ignorée : rien n'y sera écrit.")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    answerField
                    statusLines
                    actions
                }
            }
        }
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isSelected ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { model.select(zone.id, from: .list) }
        .onAppear { draft = zone.answer }
        .onChange(of: zone.answer) { _, new in if new != draft { draft = new } }
        .onChange(of: draft) { _, new in if new != zone.answer { model.setAnswer(new, for: zone.id) } }
        .onChange(of: focused) { _, now in if now { model.select(zone.id, from: .list) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zone \(zone.number), page \(zone.page + 1)")
    }

    // MARK: Parties

    private var badge: some View {
        Text("\(zone.number)")
            .font(.callout.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(minWidth: 26, minHeight: 26)
            .background(Circle().fill(isIgnored || !zone.enabled ? Color.gray : (isSelected ? Color.orange : Color.accentColor)))
            .accessibilityHidden(true)
    }

    private var topLine: some View {
        HStack(spacing: 8) {
            Picker("Type de zone", selection: Binding(get: { zone.kind }, set: { model.setKind($0, for: zone.id) })) {
                ForEach(ZoneKind.allCases) { kind in Text(kind.label).tag(kind) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(model.isRunning)
            Spacer(minLength: 4)
            if isThisRunning {
                ProgressView().controlSize(.small)
            } else if !isIgnored {
                Toggle("Écrire dans le PDF", isOn: Binding(get: { zone.enabled }, set: { model.setEnabled($0, for: zone.id) }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(model.isRunning)
                    .help("Décoche pour laisser cette zone vide dans le PDF enregistré")
            }
        }
    }

    private var answerField: some View {
        TextField(isManual ? "Écris la réponse, ou clique sur « Compléter cette zone »" : "Réponse",
                  text: $draft, axis: .vertical)
            .lineLimit(1...6)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .disabled(model.isRunning)
            .accessibilityLabel("Réponse de la zone \(zone.number)")
    }

    @ViewBuilder private var statusLines: some View {
        if zone.humanized {
            HStack(spacing: 6) {
                Label("Humanisée", systemImage: "wand.and.stars")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.purple.opacity(0.12), in: Capsule())
                Button(showOriginal ? "Masquer le texte d'origine" : "Voir le texte d'origine") { showOriginal.toggle() }
                    .buttonStyle(.link).font(.caption)
                Spacer(minLength: 0)
            }
            if showOriginal {
                VStack(alignment: .leading, spacing: 6) {
                    Text(zone.rawAnswer)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Button("Utiliser ce texte") { model.useOriginalText(for: zone.id); showOriginal = false }
                        Button("Garder l'humanisée") { showOriginal = false }
                    }
                    .controlSize(.small)
                }
            }
        }
        if zone.overflow, zone.enabled {
            Label("Ne rentre pas dans la zone : raccourcis la réponse.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = zone.error {
            VStack(alignment: .leading, spacing: 5) {
                Label(Fr.sentence(error), systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Réessayer") { model.regenerate(zone.id) }
                    .controlSize(.small)
                    .disabled(model.isBusy)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            // en cas d'erreur, « Réessayer » (plus haut) fait déjà le même travail
            if zone.error == nil {
                Button {
                    model.regenerate(zone.id)
                } label: {
                    Label(hasAnswer ? "Régénérer" : "Compléter cette zone", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)
                .help(hasAnswer ? "Demander une autre réponse pour cette zone" : "Écrire une réponse pour cette zone seulement")
            }
            Spacer(minLength: 0)
            if isManual {
                Button(role: .destructive) { model.deleteManualZone(zone.id) } label: {
                    Label("Supprimer la zone", systemImage: "trash")
                }
                .disabled(model.isBusy)
            }
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }
}
