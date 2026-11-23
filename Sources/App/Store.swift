import SwiftUI

/// App state. Reloads automatically when the CLI (or anything else) commits to the database.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var groups: [ProjectGroup] = []
    @Published private(set) var counts: [Int64: Int] = [:]
    @Published private(set) var columns: [Column] = []
    @Published private(set) var cards: [Int64: [Card]] = [:]
    @Published var selected: Int64? {
        didSet {
            guard selected != oldValue, !reloading else { return }
            if let id = selected { try? db.setCurrent(id); remember(id) }
            loadBoard()
            version = db.dataVersion()
        }
    }
    @Published var error: String?

    /// Inline renames. Drafts live here (not in the views) so a rename superseded by another action is saved, not lost.
    @Published var renamingProject: Int64?
    @Published var renamingGroup: Int64?
    @Published var renamingColumn: Int64?
    @Published var projectDraft = ""
    @Published var groupDraft = ""
    @Published var columnDraft = ""

    let db: DB
    private var version: Int64 = -1
    private var timer: Timer?
    private var reloading = false

    init() {
        db = Store.openDatabase()
        reloadAll()
        if let id = selected { remember(id) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Opens the DB; on failure offers to move the broken file aside instead of crashing at every launch.
    private static func openDatabase() -> DB {
        while true {
            do { return try DB() } catch {
                let path = DB.defaultPath
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Impossible d'ouvrir la base Kanban"
                alert.informativeText = "\(error)\n\n\(path)"
                alert.addButton(withTitle: "Réessayer")
                alert.addButton(withTitle: "Mettre de côté et repartir à zéro")
                alert.addButton(withTitle: "Quitter")
                switch alert.runModal() {
                case .alertSecondButtonReturn:
                    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                    for ext in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + ext) {
                        try? FileManager.default.moveItem(atPath: path + ext, toPath: path + ".corrompu-\(stamp)" + ext)
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path).deletingLastPathComponent()])
                case .alertThirdButtonReturn:
                    exit(1)
                default: break
                }
            }
        }
    }

    // MARK: - Recent projects (Dock menu)

    private static let recentKey = "recentProjects"

    /// Last opened projects, most recent first (existing ones only).
    var recentProjects: [Project] {
        let ids = UserDefaults.standard.array(forKey: Store.recentKey) as? [Int64] ?? []
        return ids.compactMap { id in projects.first { $0.id == id } }.prefix(3).map { $0 }
    }

    private func remember(_ id: Int64) {
        var ids = UserDefaults.standard.array(forKey: Store.recentKey) as? [Int64] ?? []
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        UserDefaults.standard.set(Array(ids.prefix(10)), forKey: Store.recentKey)
    }

    // MARK: - Loading

    var project: Project? { projects.first { $0.id == selected } }
    func projects(in group: Int64?) -> [Project] { projects.filter { $0.group == group } }
    func openCount(group: Int64) -> Int { projects(in: group).reduce(0) { $0 + (counts[$1.id] ?? 0) } }
    func cardCount(_ col: Int64) -> Int { cards[col]?.count ?? 0 }

    private func poll() {
        if db.dataVersion() != version { reloadAll() }
    }

    func reloadAll() {
        reloading = true
        defer { reloading = false }
        let v = db.dataVersion()
        do {
            set(\.projects, try db.projects())
            set(\.groups, try db.groups())
            set(\.counts, try db.openCounts())
            if selected == nil || !projects.contains(where: { $0.id == selected }) {
                selected = (try? db.currentProject().id) ?? projects.first?.id
            }
            loadBoard()
            version = v
        } catch { self.error = "\(error)" }
    }

    private func loadBoard() {
        guard let p = selected else { set(\.columns, []); set(\.cards, [:]); return }
        do {
            set(\.columns, try db.columns(p))
            set(\.cards, try db.board(p))
        } catch { self.error = "\(error)" }
    }

    /// Publishes only real changes, so a reload doesn't make every list re-diff and flicker.
    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<Store, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    private func mutate(_ f: () throws -> Void) {
        do { try f() } catch { self.error = "\(error)" }
        reloadAll()
    }

    // MARK: - Renames

    func startRename(_ p: Project) { commitRenames(); projectDraft = p.name; renamingProject = p.id }
    func startRename(_ g: ProjectGroup) { commitRenames(); groupDraft = g.name; renamingGroup = g.id }
    func startRename(_ c: Column) { commitRenames(); columnDraft = c.name; renamingColumn = c.id }

    /// Saves whatever rename is in progress.
    func commitRenames() {
        if let id = renamingProject { renameProject(id) }
        if let id = renamingGroup { renameGroup(id) }
        if let id = renamingColumn { renameColumn(id) }
    }

    func renameProject(_ id: Int64) {
        renamingProject = nil
        if let n = Store.trimmed(projectDraft) { mutate { try db.renameProject(id, n) } }
    }
    func renameGroup(_ id: Int64) {
        renamingGroup = nil
        if let n = Store.trimmed(groupDraft) { mutate { try db.renameGroup(id, n) } }
    }
    func renameColumn(_ id: Int64) {
        renamingColumn = nil
        if let n = Store.trimmed(columnDraft) { mutate { try db.renameColumn(id, n) } }
    }

    private static func trimmed(_ s: String) -> String? {
        let n = s.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }

    // MARK: - Projects

    func newProject(in group: Int64? = nil) {
        commitRenames()
        mutate {
            let id = try db.addProject("Nouveau projet", group: group)
            try reveal(group)
            selected = id
            projectDraft = "Nouveau projet"
            renamingProject = id
        }
    }

    func deleteProject(_ id: Int64) { mutate { try db.deleteProject(id, force: true) } }

    /// Reorder inside one sidebar section (`ids` = that section's projects, in order).
    func moveProjects(in ids: [Int64], from: IndexSet, to: Int) {
        guard let i = from.first, i < ids.count else { return }
        let id = ids[i]
        let before = to < ids.count ? ids[to] : nil
        mutate { try db.tx { try place(id, before: before, orAfter: ids.last) } }
    }

    // MARK: - Groups

    func newGroup() {
        commitRenames()
        mutate { _ = try createGroupForRename() }
    }

    /// Creates a group holding this project and starts renaming the group.
    func moveToNewGroup(_ id: Int64) {
        commitRenames()
        mutate { try db.tx { try db.setProjectGroup(id, try createGroupForRename()) } }
    }

    func deleteGroup(_ id: Int64) { mutate { try db.deleteGroup(id) } }
    func setCollapsed(_ id: Int64, _ on: Bool) { mutate { try db.setGroupCollapsed(id, on) } }

    /// Moves projects into `group` (nil = out of any group).
    func setGroup(_ ids: [Int64], _ group: Int64?) {
        guard !ids.isEmpty else { return }
        commitRenames()
        mutate {
            try db.tx {
                for id in ids { try db.setProjectGroup(id, group) }
                try reveal(group)
            }
        }
    }

    /// Drop on a section header: join that group (nil = "Projets", i.e. ungrouped).
    @discardableResult
    func dropProjects(_ payload: [String], into group: Int64?) -> Bool {
        let ids = projectIds(payload)
        setGroup(ids, group)
        return !ids.isEmpty
    }

    /// Drop project(s) on another project, like iOS folders:
    /// grouped → ungrouped target: leave the group, placed just before the target;
    /// target in a group: join it; both ungrouped: create a group holding both.
    @discardableResult
    func dropProjects(_ payload: [String], onto target: Project) -> Bool {
        let ids = projectIds(payload).filter { $0 != target.id }
        guard !ids.isEmpty else { return false }
        commitRenames()
        let leaving = target.group == nil && ids.allSatisfy { id in projects.first { $0.id == id }?.group != nil }
        mutate {
            try db.tx {
                if leaving {
                    for id in ids {
                        try db.setProjectGroup(id, nil)
                        try place(id, before: target.id, orAfter: nil)
                    }
                    return
                }
                let gid: Int64
                if let g = target.group {
                    gid = g
                } else {
                    gid = try createGroupForRename()
                    try db.setProjectGroup(target.id, gid)
                }
                for id in ids { try db.setProjectGroup(id, gid) }
                try reveal(gid)
            }
        }
        return true
    }

    /// Native List insertion: a project dropped between rows of a section joins that section's group
    /// (nil = ungrouped) at that position. This is what makes "drag out of a group" work reliably.
    func insertProject(payload: String, group: Int64?, at index: Int, sectionIds: [Int64]) {
        guard let id = projectIds([payload]).first else { return }
        commitRenames()
        let before = index < sectionIds.count ? sectionIds[index] : nil
        mutate {
            try db.tx {
                try db.setProjectGroup(id, group)
                try reveal(group)
                try place(id, before: before, orAfter: sectionIds.filter { $0 != id }.last)
            }
        }
    }

    // MARK: Project helpers (call inside mutate / tx)

    private func createGroupForRename() throws -> Int64 {
        let name = try db.freeGroupName("Nouveau groupe")
        let id = try db.addGroup(name)
        groupDraft = name
        renamingGroup = id
        return id
    }

    /// Expands a group so the project that just moved into it is visible.
    private func reveal(_ group: Int64?) throws {
        if let g = group { try db.setGroupCollapsed(g, false) }
    }

    /// Puts project `id` just before `before`, else just after `orAfter`, else last (global project order).
    private func place(_ id: Int64, before: Int64?, orAfter after: Int64?) throws {
        let order = try db.projects().map(\.id).filter { $0 != id }
        let target: Int
        if let b = before, b != id, let i = order.firstIndex(of: b) { target = i }
        else if let a = after, let i = order.firstIndex(of: a) { target = i + 1 }
        else { target = order.count }
        try db.moveProject(id, to: target)
    }

    // MARK: - Columns

    func addColumn() {
        guard let p = selected else { return }
        commitRenames()
        mutate {
            let id = try db.addColumn(p, "Nouvelle colonne", at: DB.newColumnIndex(columns))
            columnDraft = "Nouvelle colonne"
            renamingColumn = id
        }
    }

    func setColumnColor(_ id: Int64, _ hex: String?) { mutate { try db.setColumnColor(id, hex) } }
    func setColumnDone(_ id: Int64, _ on: Bool) { mutate { try db.setColumnDone(id, on) } }
    func deleteColumn(_ id: Int64) { mutate { try db.deleteColumn(id, force: true) } }
    func moveColumn(_ id: Int64, to index: Int) { mutate { try db.moveColumn(id, to: index) } }

    func moveColumn(_ id: Int64, by delta: Int) {
        guard let i = columns.firstIndex(where: { $0.id == id }) else { return }
        mutate { try db.moveColumn(id, to: i + delta) }
    }

    // MARK: - Cards

    /// Quick add with inline syntax ("titre !2 +tag") into a column (default: first one).
    func quickAdd(_ text: String, column: Int64? = nil) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let col = column ?? columns.first?.id else { return }
        let p = DB.parseInline(t)
        mutate { try db.addCard(col: col, title: p.title, tags: p.tags, prio: p.prio ?? 0) }
    }

    /// Writes only the fields changed in the editor, so concurrent edits from `kb` aren't overwritten.
    func save(original o: Card, edited e: Card, column: Int64) {
        mutate {
            try db.tx {
                try db.updateCard(e.id,
                                  title: e.title != o.title ? e.title : nil,
                                  body: e.body != o.body ? e.body : nil,
                                  tags: e.tags != o.tags ? e.tags : nil,
                                  prio: e.prio != o.prio ? e.prio : nil)
                if column != o.col, try db.column(column) != nil {
                    try db.moveCards([e.id], to: column)
                }
            }
        }
    }

    func setPrio(_ id: Int64, _ p: Int) { mutate { try db.updateCard(id, prio: p) } }
    func delete(_ id: Int64) { mutate { try db.deleteCards([id]) } }
    func move(_ id: Int64, to col: Int64) { mutate { try db.moveCards([id], to: col) } }

    /// Card drop: insert dragged cards before `target` (nil = end of column).
    @discardableResult
    func drop(_ payload: [String], into col: Int64, before target: Int64?) -> Bool {
        let onBoard = Set(cards.values.flatMap { $0.map(\.id) })
        let ids = DB.unique(payload.compactMap { Store.id(from: $0, prefix: Store.cardPrefix) }).filter(onBoard.contains)
        guard !ids.isEmpty else { return false }
        if let t = target, ids.contains(t) { return true }
        let full = cards[col] ?? []
        let others = full.filter { !ids.contains($0.id) }
        var index: Int? = nil
        if let t = target, var i = others.firstIndex(where: { $0.id == t }) {
            // Dragging downward inside the same column: drop lands after the hovered card.
            if ids.count == 1, let src = full.firstIndex(where: { $0.id == ids[0] }),
               let dst = full.firstIndex(where: { $0.id == t }), src < dst { i += 1 }
            index = i
        }
        mutate { try db.moveCards(ids, to: col, at: index) }
        return true
    }

    // MARK: - Drag payloads
    // Typed string payloads ("kanban-card:12", "kanban-project:3") so arbitrary dropped text is ignored.

    static let cardPrefix = "kanban-card:"
    static let projectPrefix = "kanban-project:"
    static func cardPayload(_ id: Int64) -> String { cardPrefix + String(id) }
    static func projectPayload(_ id: Int64) -> String { projectPrefix + String(id) }

    private static func id(from s: String, prefix: String) -> Int64? {
        s.hasPrefix(prefix) ? Int64(s.dropFirst(prefix.count)) : nil
    }

    /// Project ids from drag payloads, restricted to existing projects.
    private func projectIds(_ payload: [String]) -> [Int64] {
        DB.unique(payload.compactMap { Store.id(from: $0, prefix: Store.projectPrefix) })
            .filter { id in projects.contains { $0.id == id } }
    }
}
