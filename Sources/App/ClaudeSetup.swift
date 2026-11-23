import AppKit

/// "Installer kb pour Claude…": links the bundled `kb` CLI into ~/.local/bin and installs the Claude Code skill.
/// Lets anyone who downloaded the app use it with Claude, without the build script.
enum ClaudeSetup {
    static func install() {
        // Confirm first: this writes outside the app (PATH + Claude Code config).
        let ask = NSAlert()
        ask.messageText = "Installer kb pour Claude ?"
        ask.informativeText = """
        Ceci va créer :
        • ~/.local/bin/kb (lien vers la commande incluse dans l'app)
        • ~/.claude/skills/kanban/SKILL.md (remplacé s'il existe)
        """
        ask.addButton(withTitle: "Installer")
        ask.addButton(withTitle: "Annuler")
        guard ask.runModal() == .alertFirstButtonReturn else { return }

        let alert = NSAlert()
        do {
            alert.messageText = "kb est installé pour Claude"
            alert.informativeText = try run()
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Installation impossible"
            alert.informativeText = "\(error)"
        }
        alert.runModal()
    }

    private static func run() throws -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        // A link into a translocated copy, the mounted DMG or Downloads would break (or be hijackable).
        let inApps = bundle.hasPrefix("/Applications/") || bundle.hasPrefix(home.appendingPathComponent("Applications").path + "/")
        guard inApps, !bundle.contains("/AppTranslocation/") else {
            throw KBError("Déplace d'abord Kanban dans le dossier Applications, relance-le, puis recommence.\n(Emplacement actuel : \(bundle))")
        }
        let kb = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/kb")
        guard fm.isExecutableFile(atPath: kb.path) else { throw KBError("kb introuvable dans l'app") }

        // 1. ~/.local/bin/kb -> the binary inside the app (only replaces an existing symlink, never a real file).
        let bin = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("kb")
        // Only replace a previous Kanban link; never another tool's `kb`.
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
}
