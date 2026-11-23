import SwiftUI

/// Quick-add field on top, columns below.
struct BoardScreen: View {
    @EnvironmentObject var store: Store
    @State private var quick = ""
    @State private var search = ""
    @State private var editing: Card?
    @FocusState private var quickFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            quickAdd
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(store.columns.enumerated()), id: \.element.id) { i, c in
                        ColumnView(column: c, index: i, total: store.columns.count,
                                   cards: filtered(store.cards[c.id] ?? []), editing: $editing)
                    }
                    addColumnButton
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 22)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .padding(.top, 18)
        .navigationTitle(store.project?.name ?? "Kanban")
        .searchable(text: $search, placement: .toolbar, prompt: "Rechercher")
        .toolbar { ToolbarItem(placement: .primaryAction) { AppearanceButton() } }
        .sheet(item: $editing) { CardEditor(card: $0) }
        .onAppear { quickFocus = true }
    }

    private var quickAdd: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Palette.blue)
            TextField("Ajouter une tâche…   !2 priorité · +tag ou +\"deux mots\" étiquette", text: $quick, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($quickFocus)
                .onSubmit {
                    store.quickAdd(quick)
                    quick = ""
                    quickFocus = true
                }
            Text("↵ \(store.columns.first?.name ?? "To do")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 22)
    }

    private var addColumnButton: some View {
        Button { store.addColumn() } label: {
            Label("Colonne", systemImage: "plus")
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func filtered(_ cs: [Card]) -> [Card] {
        let q = DB.fold(search.trimmingCharacters(in: .whitespaces))
        return q.isEmpty ? cs : cs.filter { DB.matches($0, q) }
    }
}

struct ColumnView: View {
    @EnvironmentObject var store: Store
    let column: Column
    let index: Int
    let total: Int
    let cards: [Card]
    @Binding var editing: Card?

    @State private var adding = false
    @State private var newTitle = ""
    @State private var targeted = false
    @State private var picking = false
    @State private var confirmDelete = false
    @FocusState private var addFocus: Bool

    private var color: Color { Palette.color(for: column, index: index, total: total) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    GlassEffectContainer(spacing: 8) {
                        LazyVStack(spacing: 8) {
                            ForEach(cards) { c in
                                CardView(card: c, dimmed: column.done)
                                    .onTapGesture { editing = c }
                                    .draggable(Store.cardPayload(c.id))
                                    .dropDestination(for: String.self) { items, _ in
                                        store.drop(items, into: column.id, before: c.id)
                                    }
                            }
                            if adding { addField }
                        }
                    }
                    // Room for the glass shadows so the scroll view doesn't clip them.
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 14)
                }
                .scrollIndicators(.never)
                .onChange(of: adding) { _, on in
                    if on { withAnimation { proxy.scrollTo("add-field", anchor: .bottom) } }
                }
                .onChange(of: newTitle) { _, _ in proxy.scrollTo("add-field", anchor: .bottom) }
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 4)
        .frame(width: 290)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(color.opacity(targeted ? 0.16 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(targeted ? 0.35 : 0.14), lineWidth: 1)
        )
        .contentShape(Rectangle())
        // Accepts cards (appended) and columns dragged by their header (reordered).
        .dropDestination(for: String.self) { items, _ in
            store.drop(items, into: column.id, before: nil) || store.dropColumn(items, onto: column.id)
        } isTargeted: { targeted = $0 }
        .animation(.easeOut(duration: 0.15), value: targeted)
        .confirmationDialog("Supprimer « \(column.name) » et ses \(store.cardCount(column.id)) cartes ?", isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive) { store.deleteColumn(column.id) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { picking = true } label: {
                Circle().fill(color).frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                    .padding(4).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Changer la couleur")
            .popover(isPresented: $picking, arrowEdge: .bottom) { colorPicker }

            Group {
                if store.renamingColumn == column.id {
                    RenameField(text: $store.columnDraft,
                                commit: { if store.renamingColumn == column.id { store.renameColumn(column.id) } },
                                cancel: { store.renamingColumn = nil })
                } else {
                    Text(column.name).onTapGesture(count: 2) { store.startRename(column) }
                }
            }
            .font(.system(size: 13, weight: .semibold))

            Text("\(cards.count)").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button { adding = true; DispatchQueue.main.async { addFocus = true } } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Ajouter une carte")
            menu
        }
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        // Drag a column by its header to reorder it.
        .draggable(Store.columnPayload(column.id)) {
            Label(column.name, systemImage: "rectangle.split.3x1")
                .padding(.horizontal, 12).padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
        }
    }

    private var menu: some View {
        Menu {
            Toggle("Colonne terminée (cartes barrées et estompées)", isOn: Binding(
                get: { column.done }, set: { store.setColumnDone(column.id, $0) }))
            Divider()
            Button("Renommer") { store.startRename(column) }
            Button("Déplacer à gauche") { store.moveColumn(column.id, by: -1) }.disabled(index == 0)
            Button("Déplacer à droite") { store.moveColumn(column.id, by: 1) }.disabled(index == total - 1)
            Divider()
            Button("Supprimer la colonne", role: .destructive) {
                if store.cardCount(column.id) == 0 { store.deleteColumn(column.id) } else { confirmDelete = true }
            }.disabled(total <= 1)
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(.secondary)
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 10), count: 4), spacing: 10) {
                ForEach(Palette.swatches, id: \.hex) { sw in
                    let current = column.color == sw.hex
                    Button {
                        store.setColumnColor(column.id, sw.hex); picking = false
                    } label: {
                        Circle().fill(Palette.hex(sw.hex)!)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(.primary.opacity(current ? 0.9 : 0.12), lineWidth: current ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(sw.name)
                }
            }
            Button("Auto") { store.setColumnColor(column.id, nil); picking = false }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var addField: some View {
        TextField("Titre  !2 +tag", text: $newTitle, axis: .vertical)
            .lineLimit(1...8)
            .id("add-field")
            .textFieldStyle(.plain)
            .focused($addFocus)
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .onSubmit {
                store.quickAdd(newTitle, column: column.id)
                newTitle = ""
                DispatchQueue.main.async { addFocus = true }
            }
            .onExitCommand { adding = false; newTitle = "" }
            .onChange(of: addFocus) { _, f in if !f && newTitle.isEmpty { adding = false } }
    }
}
