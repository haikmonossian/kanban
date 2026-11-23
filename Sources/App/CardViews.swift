import SwiftUI

struct CardView: View {
    @EnvironmentObject var store: Store
    let card: Card
    /// In a "done" column: struck through and faded.
    let dimmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(card.title)
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough(dimmed, color: .secondary)
                    .foregroundStyle(dimmed ? .secondary : .primary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("#\(card.id)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if !card.body.isEmpty {
                Text(card.body)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if card.prio > 0 || !card.tags.isEmpty {
                HStack(spacing: 5) {
                    if card.prio > 0 {
                        Label("\(card.prio)", systemImage: "flag.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Palette.prio(card.prio))
                    }
                    ForEach(card.tags, id: \.self) { t in
                        Text(t)
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .foregroundStyle(.secondary)
                            .background(Capsule().fill(.primary.opacity(0.07)))
                            .overlay(Capsule().strokeBorder(.primary.opacity(0.10)))
                    }
                }
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 13))
        .opacity(dimmed ? 0.5 : 1)
        .saturation(dimmed ? 0.2 : 1)
        .contentShape(.rect(cornerRadius: 13))
        .contextMenu {
            Menu("Déplacer vers") {
                ForEach(store.columns) { c in
                    Button(c.name) { store.move(card.id, to: c.id) }.disabled(c.id == card.col)
                }
            }
            Menu("Priorité") {
                ForEach(0...3, id: \.self) { p in
                    Button(p == 0 ? "Aucune" : "!\(p)") { store.setPrio(card.id, p) }
                }
            }
            Divider()
            Button("Supprimer", role: .destructive) { store.delete(card.id) }
        }
    }
}

struct CardEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    private let original: Card
    @State private var card: Card
    @State private var tags: String
    @State private var column: Int64

    init(card: Card) {
        original = card
        _card = State(initialValue: card)
        _tags = State(initialValue: card.tags.joined(separator: ", "))
        _column = State(initialValue: card.col)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Titre", text: $card.title, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold))
                Text("#\(card.id)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
            TextEditor(text: $card.body)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 160)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Étiquettes").foregroundStyle(.secondary)
                    TextField("client, en attente", text: $tags).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Priorité").foregroundStyle(.secondary)
                    Picker("", selection: $card.prio) {
                        Text("—").tag(0); Text("1").tag(1); Text("2").tag(2); Text("3").tag(3)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                GridRow {
                    Text("Colonne").foregroundStyle(.secondary)
                    Picker("", selection: $column) {
                        ForEach(store.columns) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 200)
                }
            }
            .font(.system(size: 13))
            HStack {
                Button("Supprimer", role: .destructive) { store.delete(card.id); dismiss() }
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    card.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    store.save(original: original, edited: card, column: column)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.glassProminent)
                .disabled(card.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
