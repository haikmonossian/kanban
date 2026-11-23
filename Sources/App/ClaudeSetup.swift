import AppKit

/// Connects the app to Claude:
/// - "Installer kb pour Claude…" (Claude Code): links the bundled `kb` CLI into ~/.local/bin and installs the skill.
/// - "Connecter au Chat de Claude…" (Claude Desktop Chat): registers `kb mcp` as an MCP server.
enum ClaudeSetup {
    static func installForCode() {
        perform(question: "Installer kb pour Claude Code ?",
                details: """
                Ceci va créer :
                • ~/.local/bin/kb (lien vers la commande incluse dans l'app)
                • ~/.claude/skills/kanban/SKILL.md (remplacé s'il existe)
                """,
                action: "Installer", success: "kb est installé pour Claude Code", run: installCode)
    }

    static func connectChat() {
        perform(question: "Connecter Kanban au Chat de Claude ?",
                details: """
                Ajoute l'outil « kanban » dans la configuration de Claude Desktop :
                ~/Library/Application Support/Claude/claude_desktop_config.json
                Le reste du fichier n'est pas modifié ; une copie est gardée (.bak-kanban).
                L'outil ne peut que lire et modifier ton kanban : ni fichiers, ni commandes, ni réseau.
                """,
                action: "Connecter", success: "Kanban est connecté au Chat", run: installChat)
    }

    // MARK: - Shared flow

    private static func perform(question: String, details: String, action: String, success: String,
                                run: () throws -> String) {
        let ask = NSAlert()
        ask.messageText = question
        ask.informativeText = details
        ask.addButton(withTitle: action)
        ask.addButton(withTitle: "Annuler")
        guard ask.runModal() == .alertFirstButtonReturn else { return }

        let alert = NSAlert()
        do {
            alert.messageText = success
            alert.informativeText = try run()
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Opération impossible"
            alert.informativeText = "\(error)"
        }
        alert.runModal()
    }

    /// The bundled `kb`, only when the app lives in Applications: a path into a translocated copy,
    /// the mounted DMG or Downloads would break (or be hijackable).
    private static func bundledKB() throws -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let inApps = bundle.hasPrefix("/Applications/") || bundle.hasPrefix(home.appendingPathComponent("Applications").path + "/")
        guard inApps, !bundle.contains("/AppTranslocation/") else {
            throw KBError("Déplace d'abord Kanban dans le dossier Applications, relance-le, puis recommence.\n(Emplacement actuel : \(bundle))")
        }
        let kb = URL(fileURLWithPath: bundle).appendingPathComponent("Contents/MacOS/kb")
        guard fm.isExecutableFile(atPath: kb.path) else { throw KBError("kb introuvable dans l'app") }
        return kb
    }

    // MARK: - Claude Code

    private static func installCode() throws -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let kb = try bundledKB()

        // 1. ~/.local/bin/kb -> the binary inside the app. Only replaces a previous Kanban link, never another tool's `kb`.
        let bin = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("kb")
        if let attrs = try? fm.attributesOfItem(atPath: link.path) {
            let target = (try? fm.destinationOfSymbolicLink(atPath: link.path)) ?? ""
            guard attrs[.type] as? FileAttributeType == .typeSymbolicLink, target.contains("Kanban.app/") else {
                throw KBError("\(link.path) existe déjà et appartient à un autre outil : renomme-le ou supprime-le d'abord.")
            }
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: kb)

        // 2. Claude Code skill.
        guard let skill = Bundle.main.url(forResource: "SKILL", withExtension: "md") else { throw KBError("skill introuvable dans l'app") }
        let dir = home.appendingPathComponent(".claude/skills/kanban")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("SKILL.md")
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: skill, to: dest)

        return """
        • Commande : \(link.path)
        • Skill Claude : \(dest.path)

        Demande à Claude « ajoute X à mon kanban ».
        Si la commande kb n'est pas trouvée dans le terminal, ajoute ~/.local/bin à ton PATH :
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
        """
    }

    // MARK: - Claude Desktop Chat (MCP)

    private static func installChat() throws -> String {
        let fm = FileManager.default
        let kb = try bundledKB()
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude")
        let config = dir.appendingPathComponent("claude_desktop_config.json")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Merge into the existing config; never write if it can't be parsed.
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: config), !data.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw KBError("Le fichier de configuration de Claude n'est pas lisible : rien n'a été modifié.\n\(config.path)")
            }
            root = obj
            let backup = dir.appendingPathComponent("claude_desktop_config.json.bak-kanban")
            if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
            try fm.copyItem(at: config, to: backup)
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["kanban"] = ["command": kb.path, "args": ["mcp"]]
        root["mcpServers"] = servers
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: config, options: .atomic)

        return """
        Quitte complètement Claude (⌘Q) puis relance-le.
        Dans le Chat, l'outil « kanban » apparaît dans le menu des outils : demande « qu'est-ce que j'ai à faire ? ».
        """
    }
}
