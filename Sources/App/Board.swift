import SwiftUI

/// Quick-add field on top, columns below.
struct BoardScreen: View {
    @EnvironmentObject var store: Store
    @State private var quick = ""
    @State private var search = ""
    @State private var editing: Card?
    /// Column being moved with its grip: which one, where it started, how far it moved.
    @State private var drag: (id: Int64, index: Int, dx: CGFloat, dy: CGFloat)?
    @FocusState private var quickFocus: Bool

    static let columnWidth: CGFloat = 290
    static let columnSpacing: CGFloat = 14
    private static let step = columnWidth + columnSpacing

    /// Where the dragged column would land: `index` among the other columns (the column passes every
    /// neighbour whose middle it crosses) and the `gap` (0…n) where the insertion line is drawn.
    /// nil when it would stay in place.
    private var dropTarget: (gap: Int, index: Int)? {
        guard let d = drag else { return nil }
        let position = CGFloat(d.index) + d.dx / Self.step
        let index = (0..<store.columns.count).filter { $0 != d.index && CGFloat($0) < position }.count
        guard index != d.index else { return nil }
        return (index < d.index ? index : index + 1, index)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            quickAdd
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Self.columnSpacing) {
                    ForEach(Array(store.columns.enumerated()), id: \.element.id) { i, c in
                        let moving = drag?.id == c.id
                        ColumnView(column: c, index: i, total: store.columns.count,
                                   cards: filtered(store.cards[c.id] ?? []), editing: $editing,
                                   onGrip: { t in drag = (c.id, i, t.width, t.height) },
                                   onGripEnd: endDrag)
                            // Live preview: the column follows the pointer, lifted above the others.
                            .offset(x: moving ? drag!.dx : 0, y: moving ? drag!.dy : 0)
                            .scaleEffect(moving ? 1.03 : 1)
                            .opacity(moving ? 0.85 : 1)
                            .shadow(color: .black.opacity(moving ? 0.25 : 0), radius: 18, y: 8)
                            .zIndex(moving ? 1 : 0)
                    }
                    addColumnButton
                }
                .overlay(alignment: .topLeading) { insertionLine }
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
            TextField("Ajouter une tâche…      priorité : !2   ·   étiquette : +nom", text: $quick, axis: .vertical)
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

    /// Vertical line in the gap where the dragged column will land.
    /// Only the line animates (sliding between gaps); the dragged column itself follows the pointer 1:1.
    private var insertionLine: some View {
        let gap = dropTarget?.gap
        return Capsule()
            .fill(Color.accentColor)
            .frame(width: 4)
            .frame(maxHeight: .infinity)
            .offset(x: CGFloat(gap ?? 0) * Self.step - Self.columnSpacing / 2 - 2)
            .opacity(gap == nil ? 0 : 1)
            .animation(.snappy(duration: 0.18), value: gap)
            .allowsHitTesting(false)
    }

    /// Drop: move + reset in one animated transaction, so the column glides from where it was released.
    private func endDrag() {
        let target = dropTarget
        withAnimation(.snappy(duration: 0.3)) {
            if let d = drag, let t = target { store.moveColumn(d.id, to: t.index) }
            drag = nil
        }
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
    /// Grip drag: translation while moving, then end.
    let onGrip: (CGSize) -> Void
    let onGripEnd: () -> Void

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
        .frame(width: BoardScreen.columnWidth)
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
        .dropDestination(for: String.self) { items, _ in
            store.drop(items, into: column.id, before: nil)
        } isTargeted: { targeted = $0 }
        .animation(.easeOut(duration: 0.15), value: targeted)
        .confirmationDialog("Supprimer « \(column.name) » et ses \(store.cardCount(column.id)) cartes ?", isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive) { store.deleteColumn(column.id) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            grip
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
            if column.sortByPriority {
                // Visible reminder that this column is sorted; click to go back to added order.
                Button { store.setColumnSort(column.id, byPriority: false) } label: {
                    Image(systemName: "arrow.down.square").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Triée par priorité — cliquer pour revenir à l'ordre d'ajout")
            }
            Spacer()
            Button { adding = true; DispatchQueue.main.async { addFocus = true } } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Ajouter une carte")
            menu
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
    }

    /// ⠿ handle: drag it to move the column (preview + insertion line are drawn by BoardScreen).
    private var grip: some View {
        // 6 dots (2 × 3), drawn rather than an SF Symbol so it always renders.
        Grid(horizontalSpacing: 2.5, verticalSpacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow { Circle().frame(width: 3, height: 3); Circle().frame(width: 3, height: 3) }
            }
        }
        .foregroundStyle(.tertiary)
        .frame(width: 14, height: 20)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { onGrip($0.translation) }
                    .onEnded { _ in onGripEnd() }
            )
            .help("Glisser pour déplacer la colonne")
    }

    private var menu: some View {
        Menu {
            Toggle("Trier par priorité", isOn: Binding(
                get: { column.sortByPriority }, set: { store.setColumnSort(column.id, byPriority: $0) }))
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
