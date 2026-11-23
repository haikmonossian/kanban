import SwiftUI
import UniformTypeIdentifiers

/// Projects (ungrouped first), then one section per group.
struct Sidebar: View {
    @EnvironmentObject var store: Store
    @State private var confirmDelete: Project?
    @State private var hoveredGroup: Int64?
    /// How much the native section chevron (shown on hover) narrows the header, measured on first hover.
    @AppStorage("groupChevronShrink") private var chevronShrink: Double = 0
    @State private var headerWidth: [Int64: CGFloat] = [:]
    private static let chevronRoom: CGFloat = 18

    var body: some View {
        List(selection: $store.selected) {
            Section {
                rows(store.projects(in: nil), group: nil)
            } header: {
                projectsHeader
            }

            // Native collapsible sections: system chevron on the right and the system expand/collapse animation.
            ForEach(store.groups) { g in
                Section(isExpanded: Binding(get: { !g.collapsed }, set: { open in setExpanded(g, open) })) {
                    rows(store.projects(in: g.id), group: g.id)
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

    private func setExpanded(_ g: ProjectGroup, _ open: Bool) {
        withAnimation(.snappy(duration: 0.3)) { store.setCollapsed(g.id, !open) }
    }

    // MARK: Headers

    /// "Projets" + new project/group menu. Dropping a project here takes it out of its group.
    private var projectsHeader: some View {
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

    private func groupHeader(_ g: ProjectGroup) -> some View {
        let hovered = hoveredGroup == g.id
        return HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 11))
            if store.renamingGroup == g.id {
                RenameField(text: $store.groupDraft,
                            commit: { if store.renamingGroup == g.id { store.renameGroup(g.id) } },
                            cancel: { store.renamingGroup = nil })
            } else {
                Text(g.name).lineLimit(1)
            }
            Spacer(minLength: 4)
            let n = store.openCount(group: g.id)
            if n > 0 {
                // Room is kept on the right for the system chevron; when it appears on hover the header
                // narrows by `chevronShrink`, so the padding shrinks by the same amount and the count stays put.
                Text("\(n)").monospacedDigit().foregroundStyle(.secondary)
                    .padding(.trailing, max(Self.chevronRoom - (hovered ? chevronShrink : 0), 0))
            }
        }
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size.width, initial: true) { _, w in measure(g.id, width: w) }
        })
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredGroup = g.id } else if hoveredGroup == g.id { hoveredGroup = nil }
        }
        .onTapGesture { if store.renamingGroup != g.id { setExpanded(g, g.collapsed) } }
        // A click on the header only toggles the group: no selection / focus highlight.
        .selectionDisabled()
        .focusEffectDisabled()
        .dropDestination(for: String.self) { items, _ in store.dropProjects(items, into: g.id) }
        .contextMenu {
            Button("Nouveau projet dans ce groupe") { store.newProject(in: g.id) }
            Button("Renommer") { store.startRename(g) }
            Divider()
            Button("Supprimer le groupe (garde les projets)", role: .destructive) { store.deleteGroup(g.id) }
        }
    }

    /// Learns how much the header narrows while hovered (system chevron appearing).
    private func measure(_ id: Int64, width w: CGFloat) {
        if hoveredGroup == id {
            if let base = headerWidth[id] {
                let shrink = base - w
                if shrink >= 0 && shrink < 60 { chevronShrink = Double(shrink) }
            }
        } else {
            headerWidth[id] = w
        }
    }

    // MARK: Rows

    private func rows(_ ps: [Project], group: Int64?) -> some View {
        let ids = ps.map(\.id)
        return ForEach(ps) { p in
            row(p).tag(p.id)
                .draggable(Store.projectPayload(p.id))
                .dropDestination(for: String.self) { items, _ in store.dropProjects(items, onto: p) }
        }
        .onMove { store.moveProjects(in: ids, from: $0, to: $1) }
        // Drop between rows (from another section): the project joins this section at that spot.
        .onInsert(of: [.plainText, .utf8PlainText]) { index, providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let s = obj as? String else { return }
                    DispatchQueue.main.async { store.insertProject(payload: s, group: group, at: index, sectionIds: ids) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ p: Project) -> some View {
        if store.renamingProject == p.id {
            RenameField(text: $store.projectDraft,
                        commit: { if store.renamingProject == p.id { store.renameProject(p.id) } },
                        cancel: { store.renamingProject = nil })
        } else {
            Label(p.name, systemImage: "square.stack.3d.up")
                .badge(store.counts[p.id] ?? 0)
                .contextMenu {
                    Button("Renommer") { store.startRename(p) }
                    Menu("Déplacer vers") {
                        Button("Aucun groupe") { store.setGroup([p.id], nil) }.disabled(p.group == nil)
                        if !store.groups.isEmpty { Divider() }
                        ForEach(store.groups) { g in
                            Button(g.name) { store.setGroup([p.id], g.id) }.disabled(p.group == g.id)
                        }
                        Divider()
                        Button("Nouveau groupe…") { store.moveToNewGroup(p.id) }
                    }
                    Divider()
                    Button("Supprimer…", role: .destructive) { confirmDelete = p }
                        .disabled(store.projects.count <= 1)
                }
        }
    }
}
