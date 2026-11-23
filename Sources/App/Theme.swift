import SwiftUI

/// Système → Clair → Sombre. Applied to NSApp so Liquid Glass, materials and SwiftUI all agree.
enum Appearance: String {
    case system, light, dark

    var label: String { switch self { case .system: "Système"; case .light: "Clair"; case .dark: "Sombre" } }
    var icon: String { switch self { case .system: "circle.lefthalf.filled"; case .light: "sun.max"; case .dark: "moon" } }
    var next: Appearance { switch self { case .system: .light; case .light: .dark; case .dark: .system } }

    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// One click cycles Système → Clair → Sombre; the icon shows the active mode.
struct AppearanceButton: View {
    @AppStorage("appearance") private var appearance: Appearance = .system

    var body: some View {
        Button { appearance = appearance.next } label: {
            Image(systemName: appearance.icon)
        }
        .help("Thème : \(appearance.label) — cliquer pour passer à \(appearance.next.label) (⇧⌘D)")
    }
}

enum Palette {
    static let blue = hex(DB.autoPalette[0])!
    static let amber = hex(DB.autoPalette[1])!
    static let teal = hex(DB.autoPalette[2])!

    /// Choices offered when clicking a column's dot.
    static let swatches: [(name: String, hex: String)] = [
        ("Bleu", "#4D8FF5"), ("Ambre", "#F5A32E"), ("Vert", "#40C79E"), ("Violet", "#8C78EB"),
        ("Rose", "#E66190"), ("Rouge", "#EB5757"), ("Cyan", "#5CB8F2"), ("Gris", "#8E8E93"),
    ]

    /// Custom color if set, otherwise the automatic one for this position.
    static func color(for c: Column, index: Int, total: Int) -> Color {
        hex(c.color ?? DB.autoColorHex(index, of: total)) ?? blue
    }

    static func hex(_ s: String) -> Color? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static func prio(_ p: Int) -> Color {
        switch p { case 3: return .red; case 2: return .orange; default: return .secondary }
    }
}

/// Soft colored blobs behind the glass.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { g in
            let o = scheme == .dark ? 0.32 : 0.22
            ZStack {
                Circle().fill(Palette.blue.opacity(o)).frame(width: g.size.width * 0.55)
                    .position(x: g.size.width * 0.18, y: g.size.height * 0.2)
                Circle().fill(Palette.amber.opacity(o * 0.8)).frame(width: g.size.width * 0.45)
                    .position(x: g.size.width * 0.6, y: g.size.height * 0.85)
                Circle().fill(Palette.teal.opacity(o)).frame(width: g.size.width * 0.5)
                    .position(x: g.size.width * 0.95, y: g.size.height * 0.15)
            }
            .blur(radius: 90)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Inline rename field shared by projects, groups and columns: focuses itself,
/// Return or focus loss commits, Escape cancels.
struct RenameField: View {
    @Binding var text: String
    let commit: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Nom", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
            .onChange(of: focused) { _, f in if !f { commit() } }
    }
}
