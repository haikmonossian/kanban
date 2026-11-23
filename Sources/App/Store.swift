import SwiftUI

/// App state. Reloads automatically when the CLI (or anything else) commits to the database.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var counts: [Int64: Int] = [:]
    @Published private(set) var columns: [Column] = []
    @Published private(set) var cards: [Int64: [Card]] = [:]
    @Published var selected: Int64? {
        didSet {
            guard selected != oldValue, !reloading else { return }
            if let id = selected { try? db.setCurrent(id) }
            loadBoard()
            version = db.dataVersion()
        }
    }
    @Published var error: String?
    @Published var renamingProject: Int64?
    @Published var renamingColumn: Int64?

    let db: DB
    private var version: Int64 = -1
    private var timer: Timer?
    private var reloading = false

    init() {
        do { db = try DB() } catch { fatalError("Base inaccessible : \(error)") }
        reloadAll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    var project: Project? { projects.first { $0.id == selected } }

    private func poll() {
        if db.dataVersion() != version { reloadAll() }
    }

    func reloadAll() {
        reloading = true
        defer { reloading = false }
        let v = db.dataVersion()
        do {
            projects = try db.projects()
            counts = try db.openCounts()
            if selected == nil || !projects.contains(where: { $0.id == selected }) {
                selected = (try? db.currentProject().id) ?? projects.first?.id
            }
            loadBoard()
            version = v
        } catch { self.error = "\(error)" }
    }

    private func loadBoard() {
        guard let p = selected else { columns = []; cards = [:]; return }
        do {
            columns = try db.columns(p)
            cards = try db.board(p)
        } catch { self.error = "\(error)" }
    }

    private func mutate(_ f: () throws -> Void) {
        do { try f() } catch { self.error = "\(error)" }
        reloadAll()
    }

    // MARK: - Projects

    func newProject() {
        mutate {
            let id = try db.addProject("Nouveau projet")
            selected = id
            renamingProject = id
        }
    }
    func renameProject(_ id: Int64, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        renamingProject = nil
        guard !n.isEmpty else { return }
        mutate { try db.renameProject(id, n) }
    }
    func deleteProject(_ id: Int64) { mutate { try db.deleteProject(id) } }
    func moveProjects(from: IndexSet, to: Int) {
        guard let i = from.first else { return }
        let id = projects[i].id
        mutate { try db.moveProject(id, to: to > i ? to - 1 : to) }
    }

    // MARK: - Columns

    func addColumn() {
        guard let p = selected else { return }
        mutate {
            let id = try db.addColumn(p, "Nouvelle colonne", at: max(0, columns.count - 1))
            renamingColumn = id
        }
    }
    func renameColumn(_ id: Int64, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        renamingColumn = nil
        guard !n.isEmpty else { return }
        mutate { try db.renameColumn(id, n) }
    }
    func deleteColumn(_ id: Int64) { mutate { try db.deleteColumn(id, force: true) } }
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

    /// Drop handler: insert dragged cards before `before` (nil = end of column).
    func drop(_ payload: [String], into col: Int64, before target: Int64?) {
        let onBoard = Set(cards.values.flatMap { $0.map(\.id) })
        let ids = DB.unique(payload.compactMap(Store.cardId)).filter(onBoard.contains)
        guard !ids.isEmpty else { return }
        if let t = target, ids.contains(t) { return }
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
    }

    /// Drag payloads are "kanban-card:<id>" so arbitrary dropped text is ignored.
    static let dragPrefix = "kanban-card:"
    static func dragPayload(_ id: Int64) -> String { dragPrefix + String(id) }
    static func cardId(_ s: String) -> Int64? {
        s.hasPrefix(dragPrefix) ? Int64(s.dropFirst(dragPrefix.count)) : nil
    }

    func cardCount(_ col: Int64) -> Int { cards[col]?.count ?? 0 }

    func move(_ id: Int64, to col: Int64) { mutate { try db.moveCards([id], to: col) } }
}
