import SwiftUI
import UniformTypeIdentifiers

@main
struct KanbanApp: App {
    @StateObject private var store = Store()
    @AppStorage("appearance") private var appearance: Appearance = .system

    var body: some Scene {
        Window("Kanban", id: "main") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 820, minHeight: 500)
                .onAppear { appearance.apply() }
                .onChange(of: appearance) { _, a in a.apply() }
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Nouveau projet") { store.newProject() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Thème : \(appearance.label) → \(appearance.next.label)") { appearance = appearance.next }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

/// Système → Clair → Sombre. Applied to NSApp so Liquid Glass, materials and SwiftUI all agree.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { switch self { case .system: "Système"; case .light: "Clair"; case .dark: "Sombre" } }
    var icon: String { switch self { case .system: "circle.lefthalf.filled"; case .light: "sun.max"; case .dark: "moon" } }
    var next: Appearance { switch self { case .system: .light; case .light: .dark; case .dark: .system } }
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// One click cycles Système → Clair → Sombre; the icon shows the active mode.
struct AppearanceButton: View {
    @AppStorage("appearance") private var appearance: Appearance = .system
    var body: some View {
        Button { appearance = appearance.next } label: {
            Image(systemName: appearance.icon)
        }
        .help("Thème : \(appearance.label) — cliquer pour passer à \(appearance.next.label) (⇧⌘D)")
    }
}

// MARK: - Palette

enum Palette {
    static let blue = Color(red: 0.30, green: 0.56, blue: 0.96)
    static let amber = Color(red: 0.96, green: 0.64, blue: 0.18)
    static let teal = Color(red: 0.25, green: 0.78, blue: 0.62)
    static let extra = [Color(red: 0.55, green: 0.47, blue: 0.92), Color(red: 0.90, green: 0.38, blue: 0.56), Color(red: 0.36, green: 0.72, blue: 0.95)]

    /// First column blue, second amber, last teal, others from `extra`.
    static func column(_ i: Int, of n: Int) -> Color {
        if n > 1 && i == n - 1 { return teal }
        switch i {
        case 0: return blue
        case 1: return amber
        default: return extra[(i - 2) % extra.count]
        }
    }

    /// Choices offered when clicking a column's dot.
    static let swatches: [(name: String, hex: String)] = [
        ("Bleu", "#4D8FF5"), ("Ambre", "#F5A32E"), ("Vert", "#40C79E"), ("Violet", "#8C78EB"),
        ("Rose", "#E66190"), ("Rouge", "#EB5757"), ("Cyan", "#5CB8F2"), ("Gris", "#8E8E93"),
    ]

    static func hex(_ s: String) -> Color? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// Custom color if set, otherwise automatic from position.
    static func color(for c: Column, index: Int, total: Int) -> Color {
        c.color.flatMap(hex) ?? column(index, of: total)
    }

    static func prio(_ p: Int) -> Color {
        switch p { case 3: return .red; case 2: return .orange; default: return .secondary }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            BoardScreen()
                .background(Backdrop())
        }
        // No opaque header bar: title and search float on the same backdrop as the board,
        // so the floating glass sidebar sits over one continuous surface (macOS 26 style).
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .alert("Erreur", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var store: Store
    @State private var confirmDelete: Project?
    @FocusState private var renameFocus: Bool
    @FocusState private var groupFocus: Bool

    var body: some View {
        List(selection: $store.selected) {
            // Ungrouped projects. Dropping a project on this header removes it from its group.
            Section {
                rows(store.projects(in: nil))
            } header: {
                HStack {
                    Text("Projets")
                    Spacer()
                    Menu {
                        Button("Nouveau projet") { store.newProject() }
                        Button("Nouveau groupe") { store.newGroup() }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
                    .help("Nouveau projet ou groupe")
                }
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in store.dropProjects(items, into: nil) }
            }

            ForEach(store.groups) { g in
                Section(isExpanded: Binding(get: { !g.collapsed }, set: { store.setCollapsed(g.id, !$0) })) {
                    rows(store.projects(in: g.id))
                } header: {
                    groupHeader(g)
                }
            }
        }
        .listStyle(.sidebar)
        .confirmationDialog("Supprimer « \(confirmDelete?.name ?? "") » et toutes ses cartes ?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Supprimer", role: .destructive) { if let p = confirmDelete { store.deleteProject(p.id) } }
        }
    }

    private func rows(_ ps: [Project]) -> some View {
        let ids = ps.map(\.id)
        return ForEach(ps) { p in
            row(p).tag(p.id)
                .draggable(Store.projectDragPrefix + String(p.id))
                .dropDestination(for: String.self) { items, _ in store.dropProjects(items, onto: p) }
        }
        .onMove { store.moveProjects(in: ids, from: $0, to: $1) }
    }

    @ViewBuilder
    private func groupHeader(_ g: ProjectGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 11))
            if store.renamingGroup == g.id {
                TextField("Nom", text: $store.groupDraft)
                    .textFieldStyle(.plain)
                    .focused($groupFocus)
                    .onAppear { DispatchQueue.main.async { groupFocus = true } }
                    .onSubmit { store.renameGroup(g.id, store.groupDraft) }
                    .onExitCommand { store.renamingGroup = nil }
                    .onChange(of: groupFocus) { _, f in if !f && store.renamingGroup == g.id { store.renameGroup(g.id, store.groupDraft) } }
            } else {
                Text(g.name)
            }
            Spacer()
            let n = store.openCount(group: g.id)
            if n > 0 { Text("\(n)").monospacedDigit() }
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in store.dropProjects(items, into: g.id) }
        .contextMenu {
            Button("Nouveau projet dans ce groupe") { store.newProject(in: g.id) }
            Button("Renommer") { store.startRenameGroup(g) }
            Divider()
            Button("Supprimer le groupe (garde les projets)", role: .destructive) { store.deleteGroup(g.id) }
        }
    }

    @ViewBuilder
    private func row(_ p: Project) -> some View {
        if store.renamingProject == p.id {
            TextField("Nom", text: $store.projectDraft)
                .textFieldStyle(.plain)
                .focused($renameFocus)
                .onAppear { DispatchQueue.main.async { renameFocus = true } }
                .onSubmit { store.renameProject(p.id, store.projectDraft) }
                .onExitCommand { store.renamingProject = nil }
                .onChange(of: renameFocus) { _, f in if !f && store.renamingProject == p.id { store.renameProject(p.id, store.projectDraft) } }
        } else {
            Label(p.name, systemImage: "square.stack.3d.up")
                .badge(store.counts[p.id] ?? 0)
                .contextMenu {
                    Button("Renommer") { store.startRenameProject(p) }
                    Menu("Déplacer vers") {
                        Button("Aucun groupe") { store.setGroup(p.id, nil) }.disabled(p.group == nil)
                        if !store.groups.isEmpty { Divider() }
                        ForEach(store.groups) { g in
                            Button(g.name) { store.setGroup(p.id, g.id) }.disabled(p.group == g.id)
                        }
                        Divider()
                        Button("Nouveau groupe…") {
                            if let g = store.newGroup() { store.setGroup(p.id, g) }
                        }
                    }
                    Divider()
                    Button("Supprimer…", role: .destructive) { confirmDelete = p }
                        .disabled(store.projects.count <= 1)
                }
        }
    }
}

// MARK: - Board

struct BoardScreen: View {
    @EnvironmentObject var store: Store
    @State private var quick = ""
    @State private var search = ""
    @State private var editing: Card?
    @FocusState private var quickFocus: Bool

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16) {
                quickAdd
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(store.columns.enumerated()), id: \.element.id) { i, c in
                            ColumnView(column: c, index: i, total: store.columns.count,
                                       cards: filtered(store.cards[c.id] ?? []), editing: $editing)
                        }
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
                    .padding(.horizontal, 22)
                    .padding(.top, 4)
                    .padding(.bottom, 22)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .scrollIndicators(.automatic)
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
            .padding(.top, 18)
        }
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
            TextField("Ajouter une tâche…   !2 pour la priorité, +tag pour une étiquette", text: $quick, axis: .vertical)
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

    private func filtered(_ cs: [Card]) -> [Card] {
        let q = DB.fold(search.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return cs }
        return cs.filter { DB.matches($0, q) }
    }
}

/// Soft colored blobs behind the glass.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { g in
            let o = scheme == .dark ? 0.32 : 0.22
            ZStack {
                Circle().fill(Palette.blue.opacity(o)).frame(width: g.size.width * 0.55)
                    .position(x: g.size.width * 0.18, y: g.size.height * 0.2)
                Circle().fill(Palette.amber.opacity(o * 0.8)).frame(width: g.size.width * 0.45)
                    .position(x: g.size.width * 0.6, y: g.size.height * 0.85)
                Circle().fill(Palette.teal.opacity(o)).frame(width: g.size.width * 0.5)
                    .position(x: g.size.width * 0.95, y: g.size.height * 0.15)
            }
            .blur(radius: 90)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Column

struct ColumnView: View {
    @EnvironmentObject var store: Store
    let column: Column
    let index: Int
    let total: Int
    let cards: [Card]
    @Binding var editing: Card?

    @State private var adding = false
    @State private var newTitle = ""
    @State private var draft = ""
    @State private var targeted = false
    @State private var confirmDelete = false
    @FocusState private var addFocus: Bool
    @FocusState private var renameFocus: Bool

    private var color: Color { Palette.color(for: column, index: index, total: total) }
    @State private var picking = false

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
                                .draggable(Store.dragPayload(c.id))
                                .dropDestination(for: String.self) { items, _ in
                                    store.drop(items, into: column.id, before: c.id)
                                }
                        }
                        if adding { addField }
                    }
                }
                // room for the glass shadows so the scroll view doesn't clip them
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
            Button { picking = true } label: {
                Circle().fill(color).frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                    .padding(4).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Changer la couleur")
            .popover(isPresented: $picking, arrowEdge: .bottom) { colorPicker }
            if store.renamingColumn == column.id {
                TextField("Nom", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .focused($renameFocus)
                    .onAppear { draft = column.name; DispatchQueue.main.async { renameFocus = true } }
                    .onSubmit { store.renameColumn(column.id, draft) }
                    .onExitCommand { store.renamingColumn = nil }
                    .onChange(of: renameFocus) { _, f in
                        if !f && store.renamingColumn == column.id { store.renameColumn(column.id, draft) }
                    }
            } else {
                Text(column.name).font(.system(size: 13, weight: .semibold))
                    .onTapGesture(count: 2) { store.renamingColumn = column.id }
            }
            Text("\(cards.count)").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button { adding = true; DispatchQueue.main.async { addFocus = true } } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Ajouter une carte")
            Menu {
                Toggle("Colonne terminée (cartes barrées et estompées)", isOn: Binding(
                    get: { column.done }, set: { store.setColumnDone(column.id, $0) }))
                Divider()
                Button("Renommer") { store.renamingColumn = column.id }
                Button("Déplacer à gauche") { store.moveColumn(column.id, by: -1) }.disabled(index == 0)
                Button("Déplacer à droite") { store.moveColumn(column.id, by: 1) }.disabled(index == total - 1)
                Divider()
                Button("Supprimer la colonne", role: .destructive) {
                    if cards.isEmpty && store.cardCount(column.id) == 0 { store.deleteColumn(column.id) } else { confirmDelete = true }
                }.disabled(total <= 1)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 10), count: 4), spacing: 10) {
                ForEach(Palette.swatches, id: \.hex) { sw in
                    Button {
                        store.setColumnColor(column.id, sw.hex); picking = false
                    } label: {
                        Circle().fill(Palette.hex(sw.hex)!)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(.primary.opacity(column.color == sw.hex ? 0.9 : 0.12), lineWidth: column.color == sw.hex ? 2 : 1))
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

// MARK: - Card

struct CardView: View {
    @EnvironmentObject var store: Store
    let card: Card
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

// MARK: - Editor

struct CardEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var card: Card
    @State private var tags: String
    @State private var column: Int64
    private let original: Card

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
                    TextField("client, front", text: $tags).textFieldStyle(.roundedBorder)
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
