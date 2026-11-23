import Foundation
import SQLite3

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct KBError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

struct Project: Identifiable, Hashable { var id: Int64; var name: String; var pos: Int64; var group: Int64? = nil }
struct ProjectGroup: Identifiable, Hashable { var id: Int64; var name: String; var pos: Int64; var collapsed: Bool }
struct Column: Identifiable, Hashable {
    var id: Int64; var project: Int64; var name: String; var pos: Int64
    /// Hex like "#4D8FF5"; nil = automatic color from position.
    var color: String? = nil
    /// "Done" column: cards are struck through and dimmed in the app, collapsed in `kb`, not counted as open.
    var done: Bool = false
}
struct Card: Identifiable, Hashable {
    var id: Int64; var col: Int64; var pos: Int64
    var title: String; var body: String; var tags: [String]; var prio: Int
}

/// Lightweight row accessor.
struct Row {
    let s: OpaquePointer
    func i(_ c: Int32) -> Int64 { sqlite3_column_int64(s, c) }
    func isNull(_ c: Int32) -> Bool { sqlite3_column_type(s, c) == SQLITE_NULL }
    func t(_ c: Int32) -> String { sqlite3_column_text(s, c).map { String(cString: $0) } ?? "" }
}

final class DB {
    private var h: OpaquePointer?
    private var depth = 0

    static var defaultPath: String {
        if let p = ProcessInfo.processInfo.environment["KB_DB"], !p.isEmpty { return p }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Kanban")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kanban.sqlite").path
    }

    static let defaultColumns = ["To do", "En cours", "Terminé"]

    init(path: String = DB.defaultPath) throws {
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw KBError("impossible d'ouvrir \(path)")
        }
        sqlite3_busy_timeout(h, 5000)
        // Switching to WAL on a brand-new file can return BUSY without honouring busy_timeout: retry.
        var attempt = 0
        while true {
            do { try setup(); break } catch {
                attempt += 1
                if attempt > 40 || !"\(error)".contains("locked") { throw error }
                usleep(50_000)
            }
        }
    }

    private func setup() throws {
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        try exec("""
        CREATE TABLE IF NOT EXISTS projects(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, pos INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS cols(id INTEGER PRIMARY KEY AUTOINCREMENT,
            project INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE, name TEXT NOT NULL, pos INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS cards(id INTEGER PRIMARY KEY AUTOINCREMENT,
            col INTEGER NOT NULL REFERENCES cols(id) ON DELETE CASCADE, pos INTEGER NOT NULL,
            title TEXT NOT NULL, body TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '', prio INTEGER NOT NULL DEFAULT 0,
            created INTEGER NOT NULL DEFAULT (strftime('%s','now')), updated INTEGER NOT NULL DEFAULT (strftime('%s','now')));
        CREATE INDEX IF NOT EXISTS cards_col ON cards(col, pos);
        CREATE INDEX IF NOT EXISTS cols_project ON cols(project, pos);
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
        """)
        try tx {
            // v2: per-column color + done flag. Existing boards: last column of each project becomes "done".
            // v3: project groups (one level, like Notes folders).
            if try !hasColumn("projects", "grp") {
                try exec("""
                CREATE TABLE IF NOT EXISTS groups(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, pos INTEGER NOT NULL,
                    collapsed INTEGER NOT NULL DEFAULT 0);
                ALTER TABLE projects ADD COLUMN grp INTEGER REFERENCES groups(id) ON DELETE SET NULL;
                """)
            }
            if try !hasColumn("cols", "done") {
                try exec("""
                ALTER TABLE cols ADD COLUMN color TEXT;
                ALTER TABLE cols ADD COLUMN done INTEGER NOT NULL DEFAULT 0;
                UPDATE cols SET done=1 WHERE id IN (
                  SELECT (SELECT id FROM cols c2 WHERE c2.project=p.id ORDER BY pos DESC, id DESC LIMIT 1) FROM projects p
                  WHERE (SELECT count(*) FROM cols c3 WHERE c3.project=p.id) >= 2);
                """)
            }
            if try int("SELECT count(*) FROM projects") == 0 { _ = try addProject("Perso") }
        }
    }

    private func hasColumn(_ table: String, _ col: String) throws -> Bool {
        var found = false
        try run("SELECT name FROM pragma_table_info(?)", [table]) { if $0.t(0) == col { found = true } }
        return found
    }

    deinit { sqlite3_close_v2(h) }

    // MARK: - Low level

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(h, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "erreur SQL"
            sqlite3_free(err)
            throw KBError(m)
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = [], _ each: ((Row) throws -> Void)? = nil) throws -> Int {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK, let s = st else {
            throw KBError(String(cString: sqlite3_errmsg(h)))
        }
        defer { sqlite3_finalize(s) }
        for (n, a) in args.enumerated() {
            let i = Int32(n + 1)
            guard let a = a else { sqlite3_bind_null(s, i); continue }
            switch a {
            case let v as Int: sqlite3_bind_int64(s, i, Int64(v))
            case let v as Int64: sqlite3_bind_int64(s, i, v)
            case let v as String: sqlite3_bind_text(s, i, v, -1, TRANSIENT)
            default: throw KBError("type de paramètre non géré")
            }
        }
        var rows = 0
        while true {
            let r = sqlite3_step(s)
            if r == SQLITE_ROW { rows += 1; try each?(Row(s: s)) }
            else if r == SQLITE_DONE { break }
            else { throw KBError(String(cString: sqlite3_errmsg(h))) }
        }
        return rows
    }

    func int(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        var v: Int64 = 0
        try run(sql, args) { v = $0.i(0) }
        return v
    }

    var lastId: Int64 { sqlite3_last_insert_rowid(h) }

    /// Nested-safe transaction (BEGIN IMMEDIATE at top level, savepoints inside).
    @discardableResult
    func tx<T>(_ f: () throws -> T) throws -> T {
        depth += 1
        let top = depth == 1, sp = "sp\(depth)"
        defer { depth -= 1 }
        try exec(top ? "BEGIN IMMEDIATE" : "SAVEPOINT \(sp)")
        do {
            let r = try f()
            try exec(top ? "COMMIT" : "RELEASE \(sp)")
            return r
        } catch {
            try? exec(top ? "ROLLBACK" : "ROLLBACK TO \(sp); RELEASE \(sp)")
            throw error
        }
    }

    /// Changes whenever another connection (app or CLI) commits.
    func dataVersion() -> Int64 { (try? int("PRAGMA data_version")) ?? 0 }

    // MARK: - Reads

    func projects() throws -> [Project] {
        var r: [Project] = []
        try run("SELECT id,name,pos,grp FROM projects ORDER BY pos,id") {
            r.append(Project(id: $0.i(0), name: $0.t(1), pos: $0.i(2), group: $0.isNull(3) ? nil : $0.i(3)))
        }
        return r
    }

    func project(_ id: Int64) throws -> Project? { try projects().first { $0.id == id } }

    func columns(_ project: Int64) throws -> [Column] {
        var r: [Column] = []
        try run("SELECT \(DB.colCols) FROM cols WHERE project=? ORDER BY pos,id", [project]) {
            r.append(DB.columnFrom($0))
        }
        return r
    }

    func column(_ id: Int64) throws -> Column? {
        var c: Column?
        try run("SELECT \(DB.colCols) FROM cols WHERE id=?", [id]) {
            c = DB.columnFrom($0)
        }
        return c
    }

    private static let colCols = "id,project,name,pos,color,done"
    private static func columnFrom(_ r: Row) -> Column {
        let hex = r.t(4)
        return Column(id: r.i(0), project: r.i(1), name: r.t(2), pos: r.i(3), color: hex.isEmpty ? nil : hex, done: r.i(5) != 0)
    }

    private static let cardCols = "c.id,c.col,c.pos,c.title,c.body,c.tags,c.prio"
    private static func cardFrom(_ r: Row) -> Card {
        Card(id: r.i(0), col: r.i(1), pos: r.i(2), title: r.t(3), body: r.t(4),
             tags: r.t(5).split(separator: ",").map(String.init), prio: Int(r.i(6)))
    }

    /// Cards of a project grouped by column id, ordered.
    func board(_ project: Int64) throws -> [Int64: [Card]] {
        var r: [Int64: [Card]] = [:]
        try run("SELECT \(DB.cardCols) FROM cards c JOIN cols k ON k.id=c.col WHERE k.project=? ORDER BY c.col,c.pos,c.id", [project]) {
            let c = DB.cardFrom($0); r[c.col, default: []].append(c)
        }
        return r
    }

    func cards(inColumn col: Int64) throws -> [Card] {
        var r: [Card] = []
        try run("SELECT \(DB.cardCols) FROM cards c WHERE c.col=? ORDER BY c.pos,c.id", [col]) { r.append(DB.cardFrom($0)) }
        return r
    }

    func card(_ id: Int64) throws -> Card? {
        var c: Card?
        try run("SELECT \(DB.cardCols) FROM cards c WHERE c.id=?", [id]) { c = DB.cardFrom($0) }
        return c
    }

    func requireCard(_ id: Int64) throws -> Card {
        guard let c = try card(id) else { throw KBError("carte \(id) introuvable") }
        return c
    }

    /// Case- and accent-insensitive search over title, description and tags (all projects).
    func search(_ q: String) throws -> [(Card, String, String)] {
        let needle = DB.fold(q)
        var r: [(Card, String, String)] = []
        try run("""
        SELECT \(DB.cardCols), p.name, k.name FROM cards c JOIN cols k ON k.id=c.col JOIN projects p ON p.id=k.project
        ORDER BY p.pos,p.id,k.pos,k.id,c.pos,c.id
        """) { row in
            let c = DB.cardFrom(row)
            if DB.matches(c, needle) { r.append((c, row.t(7), row.t(8))) }
        }
        return r
    }

    /// Lowercased, accent-free, spaces kept.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    static func matches(_ c: Card, _ foldedNeedle: String) -> Bool {
        guard !foldedNeedle.isEmpty else { return true }
        return [c.title, c.body, c.tags.joined(separator: " ")].contains { fold($0).contains(foldedNeedle) }
    }

    /// Open card count per project (cards outside "done" columns).
    func openCounts() throws -> [Int64: Int] {
        var r: [Int64: Int] = [:]
        try run("""
        SELECT k.project, count(c.id) FROM cols k JOIN cards c ON c.col=k.id
        WHERE k.done = 0
        GROUP BY k.project
        """) { r[$0.i(0)] = Int($0.i(1)) }
        return r
    }

    func currentProject() throws -> Project {
        let ps = try projects()
        var cur: Int64?
        try run("SELECT v FROM meta WHERE k='cur'") { cur = Int64($0.t(0)) }
        if let c = cur, let p = ps.first(where: { $0.id == c }) { return p }
        guard let first = ps.first else { throw KBError("aucun projet") }
        return first
    }

    func setCurrent(_ project: Int64) throws {
        try run("INSERT INTO meta(k,v) VALUES('cur',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", [String(project)])
    }

    // MARK: - Resolution (names, prefixes, aliases)

    static func norm(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased().filter { !$0.isWhitespace }
    }

    func resolveProject(_ ref: String) throws -> Project {
        let ps = try projects()
        let raw = ref.hasPrefix("@") ? String(ref.dropFirst()) : ref
        let n = DB.norm(raw)
        if let p = ps.first(where: { DB.norm($0.name) == n }) { return p }
        if let id = Int64(raw), let p = ps.first(where: { $0.id == id }) { return p }
        let m = ps.filter { DB.norm($0.name).hasPrefix(n) }
        if m.count == 1 { return m[0] }
        throw KBError("projet \(m.isEmpty ? "inconnu" : "ambigu"): \(raw) (\(ps.map { $0.name }.joined(separator: "|")))")
    }

    /// Accepts exact name, unique prefix, or aliases todo/doing/done (first/second/last column).
    func resolveColumn(_ project: Int64, _ ref: String) throws -> Column {
        let cs = try columns(project)
        let n = DB.norm(ref)
        if let c = cs.first(where: { DB.norm($0.name) == n }) { return c }
        switch n {
        case "todo": if let c = cs.first { return c }
        case "doing", "wip": if cs.count >= 3 { return cs[1] }
        case "done": if let i = DB.doneIndex(cs) { return cs[i] }
        default: break
        }
        let m = cs.filter { DB.norm($0.name).hasPrefix(n) }
        if m.count == 1 { return m[0] }
        throw KBError("colonne \(m.isEmpty ? "inconnue" : "ambiguë"): \(ref) (\(cs.map { $0.name }.joined(separator: "|")))")
    }

    // MARK: - Projects

    @discardableResult
    func addProject(_ name: String, group: Int64? = nil) throws -> Int64 {
        let name = try DB.cleanName(name)
        return try tx {
            let pos = try int("SELECT coalesce(max(pos)+1,0) FROM projects")
            try run("INSERT INTO projects(name,pos,grp) VALUES(?,?,?)", [name, pos, group])
            let id = lastId
            for (i, c) in DB.defaultColumns.enumerated() {
                try run("INSERT INTO cols(project,name,pos,done) VALUES(?,?,?,?)", [id, c, i, i == DB.defaultColumns.count - 1 ? 1 : 0])
            }
            return id
        }
    }

    func renameProject(_ id: Int64, _ name: String) throws {
        try run("UPDATE projects SET name=? WHERE id=?", [DB.cleanName(name), id])
    }

    func deleteProject(_ id: Int64) throws {
        try tx {
            if try int("SELECT count(*) FROM projects") <= 1 { throw KBError("impossible de supprimer le dernier projet") }
            try run("DELETE FROM projects WHERE id=?", [id])
            // Pin the default project to an explicit one instead of following whatever ends up first.
            if try int("SELECT count(*) FROM meta WHERE k='cur' AND v=?", [String(id)]) > 0 || (try? currentProject()) == nil {
                if let first = try projects().first { try setCurrent(first.id) }
            }
        }
    }

    func moveProjectInGroup(_ id: Int64, to index: Int) throws {
        try tx {
            let all = try projects()
            guard let me = all.first(where: { $0.id == id }) else { throw KBError("projet introuvable") }
            let slots = all.enumerated().filter { $0.element.group == me.group }.map { $0.offset }
            var subset = slots.map { all[$0].id }.filter { $0 != id }
            subset.insert(id, at: max(0, min(index, subset.count)))
            var order = all.map(\.id)
            for (slot, pid) in zip(slots, subset) { order[slot] = pid }
            try renumber("projects", order)
        }
    }

    func moveProject(_ id: Int64, to index: Int) throws {
        try tx {
            var ids = try projects().map { $0.id }.filter { $0 != id }
            ids.insert(id, at: max(0, min(index, ids.count)))
            try renumber("projects", ids)
        }
    }

    /// Where "done" lives: leftmost column of the trailing run of done columns; else the last done column; else the last column.
    static func doneIndex(_ cs: [Column]) -> Int? {
        guard !cs.isEmpty else { return nil }
        var i = cs.count
        while i > 0 && cs[i - 1].done { i -= 1 }
        if i < cs.count { return i }
        return cs.lastIndex { $0.done } ?? cs.count - 1
    }

    // MARK: - Groups

    func groups() throws -> [ProjectGroup] {
        var r: [ProjectGroup] = []
        try run("SELECT id,name,pos,collapsed FROM groups ORDER BY pos,id") {
            r.append(ProjectGroup(id: $0.i(0), name: $0.t(1), pos: $0.i(2), collapsed: $0.i(3) != 0))
        }
        return r
    }

    func resolveGroup(_ ref: String) throws -> ProjectGroup {
        let gs = try groups()
        var r = ref.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("[") && r.hasSuffix("]") && r.count >= 2 { r = String(r.dropFirst().dropLast()) }
        let n = DB.norm(r)
        guard !n.isEmpty else { throw KBError("groupe vide") }
        if let id = Int64(r), let g = gs.first(where: { $0.id == id }), !gs.contains(where: { DB.norm($0.name) == n }) { return g }
        if let g = gs.first(where: { DB.norm($0.name) == n }) { return g }
        let m = gs.filter { DB.norm($0.name).hasPrefix(n) }
        if m.count == 1 { return m[0] }
        throw KBError("groupe \(m.isEmpty ? "inconnu" : "ambigu"): \(ref) (\(gs.map { $0.name }.joined(separator: "|")))")
    }

    @discardableResult
    func addGroup(_ name: String) throws -> Int64 {
        let name = try checkGroupName(name, except: nil)
        return try tx {
            let pos = try int("SELECT coalesce(max(pos)+1,0) FROM groups")
            try run("INSERT INTO groups(name,pos) VALUES(?,?)", [name, pos])
            return lastId
        }
    }

    func renameGroup(_ id: Int64, _ name: String) throws {
        try run("UPDATE groups SET name=? WHERE id=?", [checkGroupName(name, except: id), id])
    }

    private func checkGroupName(_ name: String, except: Int64?) throws -> String {
        let n = try DB.cleanName(name)
        if n == "-" || n.hasPrefix("[") || n.hasSuffix("]") { throw KBError("nom de groupe invalide: \(n)") }
        if try groups().contains(where: { $0.id != except && DB.norm($0.name) == DB.norm(n) }) { throw KBError("groupe existant: \(n)") }
        return n
    }

    /// "Nouveau groupe", "Nouveau groupe 2", ... (first free name).
    func freeGroupName(_ base: String) throws -> String {
        let taken = Set(try groups().map { DB.norm($0.name) })
        if !taken.contains(DB.norm(base)) { return base }
        var i = 2
        while taken.contains(DB.norm("\(base) \(i)")) { i += 1 }
        return "\(base) \(i)"
    }

    /// Projects of a deleted group become ungrouped (nothing else is deleted).
    func deleteGroup(_ id: Int64) throws {
        try tx {
            try run("UPDATE projects SET grp=NULL WHERE grp=?", [id])
            try run("DELETE FROM groups WHERE id=?", [id])
        }
    }

    func setGroupCollapsed(_ id: Int64, _ on: Bool) throws {
        try run("UPDATE groups SET collapsed=? WHERE id=?", [on ? 1 : 0, id])
    }

    func setProjectGroup(_ project: Int64, _ group: Int64?) throws {
        try tx {
            if let g = group, try int("SELECT count(*) FROM groups WHERE id=?", [g]) == 0 { throw KBError("groupe introuvable") }
            try run("UPDATE projects SET grp=? WHERE id=?", [group, project])
        }
    }

    // MARK: - Columns

    @discardableResult
    func addColumn(_ project: Int64, _ name: String, at index: Int? = nil) throws -> Int64 {
        let name = try DB.cleanName(name)
        return try tx {
            guard try self.project(project) != nil else { throw KBError("projet introuvable") }
            try run("INSERT INTO cols(project,name,pos) VALUES(?,?,?)", [project, name, Int64.max / 2])
            let id = lastId
            var ids = try columns(project).map { $0.id }.filter { $0 != id }
            ids.insert(id, at: max(0, min(index ?? ids.count, ids.count)))
            try renumber("cols", ids)
            return id
        }
    }

    func setColumnColor(_ id: Int64, _ hex: String?) throws {
        try run("UPDATE cols SET color=? WHERE id=?", [hex, id])
    }

    func setColumnDone(_ id: Int64, _ done: Bool) throws {
        try run("UPDATE cols SET done=? WHERE id=?", [done ? 1 : 0, id])
    }

    func renameColumn(_ id: Int64, _ name: String) throws {
        try run("UPDATE cols SET name=? WHERE id=?", [DB.cleanName(name), id])
    }

    func deleteColumn(_ id: Int64, force: Bool = false) throws {
        try tx {
            guard let c = try column(id) else { throw KBError("colonne introuvable") }
            if try columns(c.project).count <= 1 { throw KBError("impossible de supprimer la dernière colonne") }
            let n = try int("SELECT count(*) FROM cards WHERE col=?", [id])
            if n > 0 && !force { throw KBError("colonne non vide (\(n) cartes), ajoute -f") }
            try run("DELETE FROM cols WHERE id=?", [id])
        }
    }

    func moveColumn(_ id: Int64, to index: Int) throws {
        try tx {
            guard let c = try column(id) else { throw KBError("colonne introuvable") }
            var ids = try columns(c.project).map { $0.id }.filter { $0 != id }
            ids.insert(id, at: max(0, min(index, ids.count)))
            try renumber("cols", ids)
        }
    }

    // MARK: - Cards

    @discardableResult
    func addCard(col: Int64, title: String, body: String = "", tags: [String] = [], prio: Int = 0, top: Bool = false) throws -> Int64 {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw KBError("titre vide") }
        return try tx {
            guard try column(col) != nil else { throw KBError("colonne introuvable") }
            let pos = try int(top ? "SELECT coalesce(min(pos)-1,0) FROM cards WHERE col=?" : "SELECT coalesce(max(pos)+1,0) FROM cards WHERE col=?", [col])
            try run("INSERT INTO cards(col,pos,title,body,tags,prio) VALUES(?,?,?,?,?,?)",
                    [col, pos, t, body, DB.joinTags(tags), DB.clampPrio(prio)])
            return lastId
        }
    }

    /// Moves cards into `col`, inserted at `index` among the column's other cards (nil = end).
    func moveCards(_ ids: [Int64], to col: Int64, at index: Int? = nil) throws {
        let ids = DB.unique(ids)
        guard !ids.isEmpty else { return }
        try tx {
            guard try column(col) != nil else { throw KBError("colonne introuvable") }
            for id in ids { _ = try requireCard(id) }
            var order = try cards(inColumn: col).map { $0.id }.filter { !ids.contains($0) }
            let at = max(0, min(index ?? order.count, order.count))
            order.insert(contentsOf: ids, at: at)
            for id in ids {
                try run("UPDATE cards SET col=?, updated=strftime('%s','now') WHERE id=?", [col, id])
            }
            try renumber("cards", order)
        }
    }

    func updateCard(_ id: Int64, title: String? = nil, body: String? = nil, tags: [String]? = nil, prio: Int? = nil) throws {
        try tx {
            var c = try requireCard(id)
            if let t = title {
                let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { throw KBError("titre vide") }
                c.title = t
            }
            if let b = body { c.body = b }
            if let t = tags { c.tags = t }
            if let p = prio { c.prio = DB.clampPrio(p) }
            try run("UPDATE cards SET title=?,body=?,tags=?,prio=?,updated=strftime('%s','now') WHERE id=?",
                    [c.title, c.body, DB.joinTags(c.tags), c.prio, id])
        }
    }

    func deleteCards(_ ids: [Int64]) throws {
        try tx {
            for id in DB.unique(ids) {
                _ = try requireCard(id)
                try run("DELETE FROM cards WHERE id=?", [id])
            }
        }
    }

    // MARK: - Helpers

    private func renumber(_ table: String, _ ids: [Int64]) throws {
        for (i, id) in ids.enumerated() { try run("UPDATE \(table) SET pos=? WHERE id=?", [i, id]) }
    }

    static func clampPrio(_ p: Int) -> Int { max(0, min(3, p)) }

    static func unique(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func cleanName(_ s: String) throws -> String {
        let n = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw KBError("nom vide") }
        return n
    }

    static func cleanTags(_ tags: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for t in tags {
            let v = t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "+#"))
            if !v.isEmpty, seen.insert(v.lowercased()).inserted { out.append(v) }
        }
        return out
    }

    static func joinTags(_ t: [String]) -> String { cleanTags(t).joined(separator: ",") }

    /// "Fix login !2 +bug" -> ("Fix login", ["bug"], 2). Shared by the app's quick-add and `kb add`.
    static func parseInline(_ s: String) -> (title: String, tags: [String], prio: Int?) {
        var words: [String] = [], tags: [String] = [], prio: Int?
        for w in s.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            if w.count == 2, w.first == "!", let d = Int(String(w.last!)), (0...3).contains(d) { prio = d }
            else if w.count > 1, w.first == "+", w.dropFirst().first!.isLetter { tags.append(String(w.dropFirst())) }
            else { words.append(w) }
        }
        let title = words.joined(separator: " ")
        return title.isEmpty ? (s.trimmingCharacters(in: .whitespaces), [], nil) : (title, tags, prio)
    }

    /// Compact one-line representation, mirrors the inline syntax.
    static func line(_ c: Card, star: Bool = true) -> String {
        var s = "\(c.id) \(c.title.replacingOccurrences(of: "\n", with: " "))"
        if c.prio > 0 { s += " !\(c.prio)" }
        for t in c.tags { s += " +\(t)" }
        if star && !c.body.isEmpty { s += " *" }
        return s
    }
}
