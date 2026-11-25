import SwiftUI

// Onglet « Cartes mémoire » : réglage, révision avec carte qui se retourne, fin de série.

struct CardsTab: View {
    @ObservedObject var model: RevisionModel
    var body: some View {
        if model.cards.isEmpty {
            setup
        } else if model.cardsFinished {
            CardsEnd(model: model)
        } else if let card = model.currentCard {
            CardStudy(model: model, card: card)
        }
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HeroCard(icon: "rectangle.on.rectangle.angled", title: "Cartes mémoire",
                         text: "L'app fabrique des cartes à partir de ton cours : la question au recto, la réponse au verso. Tu les retournes, puis tu dis si tu savais ou si tu dois revoir.")
                VStack(alignment: .leading, spacing: 8) {
                    Stepper(value: Binding(get: { model.cardCount }, set: { model.setCardCount($0) }), in: CardLimits.range) {
                        Text("Nombre de cartes : \(model.cardCount)").font(.headline)
                    }
                    .accessibilityValue("\(model.cardCount)")
                    Text("Tu pourras ensuite imprimer les cartes en PDF, à découper.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).card()
                HStack(spacing: 12) {
                    Button("Créer les cartes") { model.makeCards() }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canStart)
                    EstimateNote(model: model)
                }
                if model.isBusy { SkeletonCard(lines: 3); SkeletonCard(lines: 3) }
            }
            .padding(20).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Carte qui se retourne

/// Retourne autour de l'axe vertical : le recto jusqu'à 90°, puis le verso (à l'endroit).
struct FlipView<Front: View, Back: View>: View, Animatable {
    var angle: Double
    @ViewBuilder var front: () -> Front
    @ViewBuilder var back: () -> Back
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    var body: some View {
        ZStack {
            if angle < 90 {
                front()
            } else {
                back().rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
    }
}

struct CardFace: View {
    let label: String
    let text: String
    let page: Int?
    let back: Bool
    var body: some View {
        let color: Color = back ? .green : .accentColor
        VStack(spacing: 10) {
            HStack {
                Tag(text: label, color: color)
                Spacer()
                if let page { Text("page \(page)").font(.caption).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 0)
            Text(text)
                .font(.system(size: back ? 20 : 24, weight: back ? .regular : .semibold, design: .rounded))
                .foregroundStyle(back ? Color.blue : Color.primary)    // question en noir, réponse en bleu
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 280)
        .background(RoundedRectangle(cornerRadius: 18).fill(back ? Color.green.opacity(0.10) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(color.opacity(0.55), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
    }
}

// MARK: - Révision

struct CardStudy: View {
    @ObservedObject var model: RevisionModel
    let card: RevisionCard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Text("Carte \(model.cardIndex + 1) sur \(model.deck.count)").font(.subheadline).foregroundStyle(.secondary)
                    if model.cardRound > 1 { Text("· série \(model.cardRound)").font(.subheadline).foregroundStyle(.secondary) }
                    Spacer()
                    if !model.cardToReview.isEmpty { Tag(text: "\(model.cardToReview.count) à revoir", color: .orange) }
                    if !model.cardKnown.isEmpty { Tag(text: "\(model.cardKnown.count) \(Fr.plural(model.cardKnown.count, "acquise", "acquises"))", color: .green) }
                }
                ProgressView(value: Double(model.cardsAnswered), total: Double(max(model.deck.count, 1)))
                    .accessibilityLabel("Progression de la série")
                    .accessibilityValue("\(model.cardsAnswered) cartes sur \(model.deck.count)")

                FlipView(angle: model.cardFlipped ? 180 : 0) {
                    CardFace(label: "Question", text: card.front, page: card.page, back: false)
                } back: {
                    CardFace(label: "Réponse", text: card.back, page: card.page, back: true)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: model.cardFlipped)
                .id(card.id)    // nouvelle carte = nouvelle vue : pas de retournement visible, donc pas de réponse dévoilée
                .contentShape(Rectangle())
                .onTapGesture { model.flipCard() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.cardFlipped ? "Réponse : \(card.back)" : "Question : \(card.front)")
                .accessibilityHint("Appuie pour retourner la carte")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.flipCard() }

                HStack(spacing: 12) {
                    Button { model.markCard(known: false) } label: {
                        Label("À revoir", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                    }
                    .tint(.orange).keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!model.canMarkCard)
                    Button { model.flipCard() } label: {
                        Label("Retourner", systemImage: "rectangle.2.swap").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    Button { model.markCard(known: true) } label: {
                        Label("Je savais", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .tint(.green).keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!model.canMarkCard)
                }
                .buttonStyle(.bordered).controlSize(.large)
                Text(model.cardFlipped ? "Tu savais la réponse ? Choisis « Je savais ». Sinon, « À revoir »."
                                       : "Réfléchis à la réponse, puis retourne la carte (touche espace).")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button("Recommencer") { model.restartCards() }.disabled(model.isBusy)
                    Spacer()
                    Button("Enregistrer les cartes en PDF…") { model.exportCardsPDF() }.disabled(model.isBusy)
                }
            }
            .padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Fin de série

struct CardsEnd: View {
    @ObservedObject var model: RevisionModel

    private var message: String {
        let total = model.deck.count, known = model.cardKnown.count
        if known == total { return "Bravo, tu connais toutes ces cartes !" }
        if known * 2 >= total { return "Bien joué. Rejoue les cartes à revoir pour les fixer." }
        return "Pas de souci : rejoue les cartes à revoir, ça rentre à force de les répéter."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Série terminée : \(model.cardsScoreText)")
                        .font(.system(size: 26, weight: .bold, design: .rounded)).accessibilityAddTraits(.isHeader)
                    Text("Tu connaissais \(model.cardKnown.count) \(Fr.plural(model.cardKnown.count, "carte", "cartes")), \(model.cardToReview.count) à revoir.")
                        .foregroundStyle(.secondary)
                    Text(message).fontWeight(.medium)
                    ProgressView(value: Double(model.cardKnown.count), total: Double(max(model.deck.count, 1)))
                        .tint(.green).accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading).card(selected: true, padding: 16)

                HStack {
                    Button("Rejouer les cartes à revoir (\(model.cardsToReview.count))") { model.replayCardsToReview() }
                        .buttonStyle(.borderedProminent).disabled(model.cardsToReview.isEmpty)
                    Button("Tout recommencer") { model.restartCards() }
                    Button("Nouvelles cartes") { model.newCards() }.disabled(model.isBusy)
                    Spacer()
                    Button("Enregistrer en PDF…") { model.exportCardsPDF() }.disabled(model.isBusy)
                }

                if !model.cardsToReview.isEmpty {
                    SectionHeader(title: "À revoir", icon: "arrow.counterclockwise")
                    ForEach(model.cardsToReview) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.front).fontWeight(.semibold)
                            Text(c.back).font(.callout).foregroundStyle(.blue)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .card(padding: 10)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(20).frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}
