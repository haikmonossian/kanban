import SwiftUI

@main
struct KanbanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store()
    @AppStorage("appearance") private var appearance: Appearance = .system

    var body: some Scene {
        Window("Kanban", id: "main") {
            RootView()
                .environmentObject(store)
                .onAppear { appDelegate.store = store }
                .frame(minWidth: 820, minHeight: 500)
                .onAppear { appearance.apply() }
                .onChange(of: appearance) { _, a in a.apply() }
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            SidebarCommands()
            CommandGroup(after: .appInfo) {
                Button("Installer kb pour Claude…") { ClaudeSetup.install() }
            }
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

struct RootView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject private var appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            BoardScreen()
                .background(Backdrop())
        }
        // No opaque header bar: title and search float on the same backdrop as the board,
        // so the floating glass sidebar sits over one continuous surface (macOS 26 style).
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear {
            // Lets the Dock menu reopen the window after it was closed.
            appDelegate.showMainWindow = { [openWindow] in openWindow(id: "main") }
        }
        .alert("Erreur", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("Modèle de colonnes", isPresented: Binding(get: { store.info != nil }, set: { if !$0 { store.info = nil } })) {
            Button("OK") { store.info = nil }
        } message: { Text(store.info ?? "") }
    }
}
