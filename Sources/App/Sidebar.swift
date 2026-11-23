import SwiftUI
import UniformTypeIdentifiers

/// Projects (ungrouped first), then one section per group.
struct Sidebar: View {
    @EnvironmentObject var store: Store
    @State private var confirmDelete: Project?
    @State private var hoveredGroup: Int64?
    /// Expand/collapse is applied here first (animated), then persisted to the DB.
    @State private var expandedOverride: [Int64: Bool] = [:]

    var body: some View {
        List(selection: $store.selected) {
            Section {
                rows(store.projects(in: nil), group: nil)
            } header: {
                projectsHeader
            }

            // Plain sections with our own chevron: the system collapsible header adds its chevron on hover,
            // which changes the header width and makes the right-aligned count jump.
            ForEach(store.groups) { g in
                Section {
                    // Always the same ForEach, fed an empty list when collapsed: the List then animates
                    // row insertions/removals (a conditional block would just pop in and out).
                    rows(isExpanded(g) ? store.projects(in: g.id) : [], group: g.id)
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
        HStack(spacing: 6) {
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
            if n > 0 { Text("\(n)").monospacedDigit().foregroundStyle(.secondary) }
            // The chevron's slot is always reserved (only its opacity changes on hover), so the count never moves.
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(isExpanded(g) ? 90 : 0))
                .frame(width: 12)
                .opacity(hoveredGroup == g.id ? 1 : 0)
                .padding(.trailing, 8)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredGroup = g.id } else if hoveredGroup == g.id { hoveredGroup = nil }
        }
        .onTapGesture { if store.renamingGroup != g.id { toggle(g) } }
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

    private func isExpanded(_ g: ProjectGroup) -> Bool { expandedOverride[g.id] ?? !g.collapsed }

    private func toggle(_ g: ProjectGroup) {
        let open = !isExpanded(g)
        withAnimation(.snappy(duration: 0.3)) { expandedOverride[g.id] = open }
        // Persist after the animation so the DB reload can't interrupt it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            store.setCollapsed(g.id, !open)
            expandedOverride[g.id] = nil
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
