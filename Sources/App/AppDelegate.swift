import AppKit
import Combine

/// Right-click on the Dock icon: the 3 most recently opened projects + "Nouveau projet".
/// ObservableObject so SwiftUI also puts it in the environment (RootView hands it `openWindow`).
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// Set by the app once the store exists.
    weak var store: Store?
    /// Brings the main window back if it was closed (set from SwiftUI's openWindow).
    var showMainWindow: () -> Void = {}

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let store = MainActor.assumeIsolated({ self.store }) else { return nil }
        let menu = NSMenu()
        let recents = MainActor.assumeIsolated { store.recentProjects }
        for p in recents {
            let item = NSMenuItem(title: p.name, action: #selector(openProject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p.id
            item.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
            menu.addItem(item)
        }
        if !recents.isEmpty { menu.addItem(.separator()) }
        let new = NSMenuItem(title: "Nouveau projet", action: #selector(newProject), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        return menu
    }

    @objc private func openProject(_ item: NSMenuItem) {
        guard let id = item.representedObject as? Int64 else { return }
        bringToFront()
        MainActor.assumeIsolated { store?.selected = id }
    }

    @objc private func newProject() {
        bringToFront()
        MainActor.assumeIsolated { store?.newProject() }
    }

    private func bringToFront() {
        NSApp.activate()
        if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        } else {
            showMainWindow()
        }
    }
}
