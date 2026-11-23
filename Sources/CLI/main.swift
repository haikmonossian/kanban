import Foundation

// kb — CLI ultra-compacte pour le kanban (pensée pour Claude : peu de tokens en entrée comme en sortie).

let HELP = """
kb [@p] [col..] [-a] [-t tag]           tableau (« ls » optionnel ; colonnes terminées repliées, -a = tout)
kb show id..                            détail + description
kb find texte                           recherche tous projets (casse/accents ignorés)
kb add titre [!0-3] [+tag] [-c col] [-d desc] [--top] [@p]   -> id (+ @projet si implicite)
kb mv id.. col [--top|-at n] [@p]       n = position, 0 = en haut
kb set id [-T titre] [-d desc] [-t a,b|+a,-b] [-p 0-3] [-c col [--top|-at n]]
kb note id texte                        ajoute une ligne à la description (tout est littéral)
kb rm id..
kb p [add nom|ren @p nom|rm @p [-f]|mv @p n]   projets (* = courant)
kb use @p                               projet par défaut
kb col [@p] [add nom [-at n]|ren col nom|rm col [-f]|mv col n|done col [on|off]]   (✓ = terminée)
kb - <<'EOF'  (une commande par ligne, sans 'kb' ; erreurs : « !L<n> msg »)
Colonnes : nom, préfixe, ou todo/doing/done. @p : nom ou préfixe (espaces ignorés). \\n = retour à la ligne dans -d/note.
Ligne carte : id titre !prio +tag *   (* = a une description)
"""

/// Options accepted by each command. Anything else is a positional word (so "-a" inside a title stays in the title).
let specs: [String: (valued: Set<String>, bools: Set<String>, proj: Bool)] = [
    "ls": (["-t"], ["-a"], true),
    "add": (["-c", "-t", "-p", "-d"], ["--top"], true),
    "mv": (["-at"], ["--top"], true),
    "set": (["-T", "-d", "-t", "-p", "-c", "-at"], ["--top"], true),
    "show": ([], [], false), "rm": ([], [], false), "find": ([], [], false),
    "use": ([], [], true),
    "p": ([], ["-f"], true),
    "col": (["-at"], ["-f"], true),
]
let aliases = ["l": "ls", "a": "add", "m": "mv", "s": "set", "n": "note", "f": "find",
               "proj": "p", "projects": "p", "c": "col", "h": "help", "-h": "help", "--help": "help"]

struct Args {
    var pos: [String] = []
    var opt: [String: String] = [:]
    var flags: Set<String> = []
    var proj: String?

    init(_ a: [String], cmd: String) throws {
        let spec = specs[cmd] ?? ([], [], false)
        var i = 0, literal = false
        while i < a.count {
            let x = a[i]
            if literal { pos.append(x); i += 1; continue }
            if x == "--" { literal = true; i += 1; continue }
            if spec.valued.contains(x) {
                guard i + 1 < a.count else { throw KBError("valeur manquante pour \(x)") }
                opt[x] = a[i + 1]; i += 2; continue
            }
            if spec.bools.contains(x) { flags.insert(x) }
            // For add, @proj only counts as first or last word so "@" inside a title is kept.
            else if spec.proj, x.count > 1, x.hasPrefix("@"), proj == nil, cmd != "add" || i == 0 || i == a.count - 1 { proj = x }
            else { pos.append(x) }
            i += 1
        }
    }
}

var out: [String] = []
func emit(_ s: String) { out.append(s) }

func parseId(_ s: String) -> Int64? { Int64(s.hasPrefix("#") ? String(s.dropFirst()) : s) }

func ids(_ xs: [String]) throws -> [Int64] {
    DB.unique(try xs.map {
        guard let v = parseId($0) else { throw KBError("id invalide: \($0)") }
        return v
    })
}

func intOpt(_ a: Args, _ k: String) throws -> Int? {
    guard let v = a.opt[k] else { return nil }
    guard let n = Int(v) else { throw KBError("\(k) attend un nombre") }
    return n
}

/// Literal "\n" typed in a command becomes a real newline.
func unescape(_ s: String) -> String { s.replacingOccurrences(of: "\\n", with: "\n") }

func project(_ db: DB, _ a: Args) throws -> Project {
    try a.proj.map { try db.resolveProject($0) } ?? db.currentProject()
}

func splitTags(_ s: String) -> [String] { s.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }

func applyTagEdit(_ cur: [String], _ spec: String) -> [String] {
    let parts = splitTags(spec)
    guard parts.contains(where: { $0.hasPrefix("+") || $0.hasPrefix("-") }) else { return parts }
    var t = cur
    for p in parts {
        if p.hasPrefix("-") { let v = DB.norm(String(p.dropFirst())); t.removeAll { DB.norm($0) == v } }
        else { t.append(p.hasPrefix("+") ? String(p.dropFirst()) : p) }
    }
    return t
}

func projectOf(_ db: DB, _ card: Card) throws -> Int64 {
    guard let c = try db.column(card.col) else { throw KBError("colonne introuvable") }
    return c.project
}

func ls(_ db: DB, _ a: Args) throws {
    let p = try project(db, a)
    let cols = try db.columns(p.id)
    let board = try db.board(p.id)
    let only = try Set(a.pos.map { try db.resolveColumn(p.id, $0).id })
    let tag = a.opt["-t"].map(DB.norm)
    if try db.projects().count > 1 { emit("@\(p.name)") }
    for (i, c) in cols.enumerated() {
        if !only.isEmpty && !only.contains(c.id) { continue }
        var cs = board[c.id] ?? []
        if let t = tag {
            cs = cs.filter { $0.tags.contains { DB.norm($0) == t } }
            if cs.isEmpty { continue }
        }
        let collapsed = only.isEmpty && !a.flags.contains("-a") && c.done
        emit("#\(c.name) \(cs.count)\(collapsed && !cs.isEmpty ? "…" : "")")
        if !collapsed { cs.forEach { emit(DB.line($0)) } }
    }
}

func run(_ db: DB, _ argv: [String]) throws {
    guard let first = argv.first else { return try ls(db, Args([], cmd: "ls")) }
    let cmd = aliases[first] ?? first
    let rest = Array(argv.dropFirst())
    // Anything that isn't a command is an argument of ls: `kb @p`, `kb done`, `kb -a`.
    if specs[cmd] == nil && !["note", "help"].contains(cmd) {
        do { return try ls(db, Args(argv, cmd: "ls")) } catch {
            if !first.hasPrefix("@") && !first.hasPrefix("-") && "\(error)".hasPrefix("colonne inconnue") {
                throw KBError("commande inconnue: \(first) (kb help)")
            }
            throw error
        }
    }

    if cmd == "note" {
        // Everything after the id is literal text.
        guard rest.count >= 2, let id = parseId(rest[0]) else { throw KBError("usage: note id texte") }
        let c = try db.requireCard(id)
        let text = unescape(rest.dropFirst().joined(separator: " "))
        try db.updateCard(id, body: c.body.isEmpty ? text : c.body + "\n" + text)
        return
    }
    if cmd == "help" { emit(HELP); return }

    let a = try Args(rest, cmd: cmd)
    switch cmd {
    case "ls":
        try ls(db, a)

    case "show":
        guard !a.pos.isEmpty else { throw KBError("usage: show id..") }
        for (n, id) in try ids(a.pos).enumerated() {
            let c = try db.requireCard(id)
            let col = try db.column(c.col)
            let proj = try col.flatMap { try db.project($0.project) }
            if n > 0 { emit("---") }
            emit("\(DB.line(c, star: false)) [\(proj?.name ?? "?")/\(col?.name ?? "?")]")
            if !c.body.isEmpty { emit(c.body) }
        }

    case "find":
        let q = a.pos.joined(separator: " ")
        guard !q.isEmpty else { throw KBError("usage: find texte") }
        for (c, p, k) in try db.search(q) { emit("\(DB.line(c)) [\(p)/\(k)]") }

    case "add":
        let parsed = DB.parseInline(a.pos.joined(separator: " "))
        let p = try project(db, a)
        let col = try a.opt["-c"].map { try db.resolveColumn(p.id, $0) } ?? db.columns(p.id).first
        guard let col else { throw KBError("aucune colonne") }
        let tags = parsed.tags + (a.opt["-t"].map(splitTags) ?? [])
        let prio = try intOpt(a, "-p") ?? parsed.prio ?? 0
        let id = try db.addCard(col: col.id, title: parsed.title, body: unescape(a.opt["-d"] ?? ""), tags: tags, prio: prio,
                                top: a.flags.contains("--top"))
        // Say where it went when the project was implicit and could be ambiguous.
        let many = try db.projects().count > 1
        emit(a.proj == nil && many ? "\(id) @\(p.name)" : String(id))

    case "mv":
        guard a.pos.count >= 2, let colRef = a.pos.last else { throw KBError("usage: mv id.. col") }
        let list = try ids(Array(a.pos.dropLast()))
        let at = a.flags.contains("--top") ? 0 : try intOpt(a, "-at")
        try db.tx {
            if let pr = a.proj {
                try db.moveCards(list, to: db.resolveColumn(db.resolveProject(pr).id, colRef).id, at: at)
            } else {
                // Each card moves within its own project.
                var groups: [(Int64, [Int64])] = []
                for id in list {
                    let pid = try projectOf(db, db.requireCard(id))
                    if let i = groups.firstIndex(where: { $0.0 == pid }) { groups[i].1.append(id) } else { groups.append((pid, [id])) }
                }
                for (pid, g) in groups { try db.moveCards(g, to: db.resolveColumn(pid, colRef).id, at: at) }
            }
        }

    case "set":
        guard a.pos.count == 1, let id = parseId(a.pos[0]) else { throw KBError("usage: set id [-T titre] [-d desc] [-t tags] [-p n] [-c col]") }
        let c = try db.requireCard(id)
        try db.tx {
            try db.updateCard(id, title: a.opt["-T"], body: a.opt["-d"].map(unescape),
                              tags: a.opt["-t"].map { applyTagEdit(c.tags, $0) }, prio: try intOpt(a, "-p"))
            if let ref = a.opt["-c"] {
                let pid = try a.proj.map { try db.resolveProject($0).id } ?? projectOf(db, c)
                let at = a.flags.contains("--top") ? 0 : try intOpt(a, "-at")
                try db.moveCards([id], to: db.resolveColumn(pid, ref).id, at: at)
            }
        }

    case "rm":
        guard !a.pos.isEmpty else { throw KBError("usage: rm id..") }
        try db.deleteCards(ids(a.pos))

    case "use":
        guard let ref = a.proj ?? a.pos.first else { throw KBError("usage: use @p") }
        try db.setCurrent(db.resolveProject(ref).id)

    case "p":
        let sub = a.pos.first
        let rest = Array(a.pos.dropFirst())
        switch sub {
        case nil:
            let cur = try db.currentProject().id
            let counts = try db.openCounts()
            for p in try db.projects() { emit("@\(p.name)\(p.id == cur ? "*" : "") \(counts[p.id] ?? 0)") }
        case "add":
            guard !rest.isEmpty else { throw KBError("usage: p add nom") }
            try db.addProject(rest.joined(separator: " "))
        case "ren":
            guard let ref = a.proj, !rest.isEmpty else { throw KBError("usage: p ren @p nom") }
            try db.renameProject(db.resolveProject(ref).id, rest.joined(separator: " "))
        case "rm":
            guard let ref = a.proj else { throw KBError("usage: p rm @p [-f]") }
            let p = try db.resolveProject(ref)
            let n = try db.int("SELECT count(*) FROM cards c JOIN cols k ON k.id=c.col WHERE k.project=?", [p.id])
            if n > 0 && !a.flags.contains("-f") { throw KBError("projet non vide (\(n) cartes), ajoute -f") }
            try db.deleteProject(p.id)
        case "mv":
            guard let ref = a.proj, let n = rest.first.flatMap({ Int($0) }) else { throw KBError("usage: p mv @p n") }
            try db.moveProject(db.resolveProject(ref).id, to: n)
        default: throw KBError("sous-commande inconnue: p \(sub!) (add|ren|rm|mv)")
        }

    case "col":
        let p = try project(db, a)
        let sub = a.pos.first
        let rest = Array(a.pos.dropFirst())
        switch sub {
        case nil:
            let board = try db.board(p.id)
            emit(try db.columns(p.id).map { "\($0.name)\($0.done ? "✓" : "") \(board[$0.id]?.count ?? 0)" }.joined(separator: " | "))
        case "add":
            guard !rest.isEmpty else { throw KBError("usage: col add nom [-at n]") }
            // Default: just before the last (done) column so done stays last.
            let at = try intOpt(a, "-at") ?? max(0, try db.columns(p.id).count - 1)
            try db.addColumn(p.id, rest.joined(separator: " "), at: at)
        case "ren":
            guard rest.count >= 2 else { throw KBError("usage: col ren col nom") }
            try db.renameColumn(db.resolveColumn(p.id, rest[0]).id, rest.dropFirst().joined(separator: " "))
        case "rm":
            guard rest.count == 1 else { throw KBError("usage: col rm col [-f]") }
            try db.deleteColumn(db.resolveColumn(p.id, rest[0]).id, force: a.flags.contains("-f"))
        case "mv":
            guard rest.count == 2, let n = Int(rest[1]) else { throw KBError("usage: col mv col n") }
            try db.moveColumn(db.resolveColumn(p.id, rest[0]).id, to: n)
        case "done":
            guard rest.count == 1 || rest.count == 2 else { throw KBError("usage: col done col [on|off]") }
            let c = try db.resolveColumn(p.id, rest[0])
            let on: Bool
            switch rest.count == 2 ? rest[1] : nil {
            case nil: on = !c.done
            case "on"?: on = true
            case "off"?: on = false
            default: throw KBError("usage: col done col [on|off]")
            }
            try db.setColumnDone(c.id, on)
        default: throw KBError("sous-commande inconnue: col \(sub!) (add|ren|rm|mv|done)")
        }

    default:
        throw KBError("commande inconnue: \(cmd) (kb help)")
    }
}

/// Minimal shell-like tokenizer for batch lines (quotes + backslash escapes; "\n" kept for unescape()).
func tokenize(_ line: String) throws -> [String] {
    var out: [String] = [], cur = "", has = false, quote: Character?, esc = false
    for ch in line {
        if esc { cur += ch == "n" ? "\\n" : String(ch); esc = false; has = true; continue }
        if ch == "\\" && quote != "'" { esc = true; continue }
        if let q = quote {
            if ch == q { quote = nil } else { cur.append(ch) }
            continue
        }
        if ch == "'" || ch == "\"" { quote = ch; has = true; continue }
        if ch.isWhitespace { if has { out.append(cur); cur = ""; has = false }; continue }
        cur.append(ch); has = true
    }
    if quote != nil { throw KBError("guillemet non fermé") }
    if has { out.append(cur) }
    return out
}

// MARK: - Entry

var code: Int32 = 0
do {
    let db = try DB()
    let argv = Array(CommandLine.arguments.dropFirst())
    if argv == ["-"] {
        let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Each line is its own transaction: a failing line changes nothing, the others still apply.
        for (n, raw) in input.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            do {
                var tokens = try tokenize(line)
                if tokens.first == "kb" { tokens.removeFirst() }
                try db.tx { try run(db, tokens) }
            } catch {
                emit("!L\(n + 1) \(error)")
                code = 1
            }
        }
    } else {
        try run(db, argv)
    }
} catch {
    FileHandle.standardError.write("kb: \(error)\n".data(using: .utf8)!)
    code = 1
}
if !out.isEmpty { print(out.joined(separator: "\n")) }
exit(code)
