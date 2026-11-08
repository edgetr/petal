import AppKit
import Combine
import SwiftUI

/// The settings window: everything Petal can change, on a window of Liquid Glass that shows what's behind it.
/// On Omarchy the right-click menu stays tiny and the rest is asking Claude; the Mac adds this window, and its
/// first field still asks the AI (when there is one).
@MainActor
final class SettingsWindow {
    private(set) var window: NSWindow?
    var isOpen: Bool { window?.isVisible ?? false }
    /// The page a fresh view, made ahead in the closed window and never shown, opens on.
    private var madeAhead: SettingsSection?

    func show(_ section: SettingsSection = .dock) {
        PetalWindow.bringForward(prepare(section))
    }

    /// The window with its content, ready to show (`Petal --bench-settings` times this without showing it). Each
    /// opening shows a view nobody has seen yet: the one made ahead while the window was closed (on the page asked
    /// for), else one made now, as it always was.
    func prepare(_ section: SettingsSection = .dock) -> NSWindow {
        PetalApp.shared.refreshSystemFacts()
        let window = self.window ?? makeWindow()
        if let ahead = madeAhead, !window.isVisible {
            madeAhead = nil
            if ahead != section { SettingsBench.commands.send(.open(section)) }
        } else {
            madeAhead = nil
            window.setGlassContent(SettingsView(selection: section).environment(PetalApp.shared))
        }
        return window
    }

    /// Makes a fresh view in the closed window while nobody waits for it (a while after launch, and a moment after
    /// the window closes, which also lets the last one go: its views and timers stop), so the next opening only
    /// has to show it. Nothing of the last opening is kept: what was typed, picked or shown in it.
    func makeAhead() {
        let window = self.window ?? makeWindow()
        guard !window.isVisible, madeAhead == nil else { return }
        window.setGlassContent(SettingsView(selection: .dock).environment(PetalApp.shared))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        madeAhead = .dock
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 540)
        window.title = "Petal Settings"
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            // A moment after it's gone, so its closing is drawn as it was.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self?.makeAhead() } }
        }
        self.window = window
        return window
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case dock, modes, claude, vault, routines, focus, apps, look, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dock: "Dock"
        case .modes: "Modes"
        case .claude: "AI"
        case .vault: "Vault"
        case .routines: "Routines"
        case .focus: "Focus"
        case .apps: "Apps & Extras"
        case .look: "Look"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .dock: "dock.rectangle"
        case .modes: "circle.hexagongrid.fill"
        case .claude: "sparkles"
        case .vault: "key.fill"
        case .routines: "wand.and.sparkles"
        case .focus: "scope"
        case .apps: "square.grid.2x2.fill"
        case .look: "paintbrush.pointed.fill"
        case .permissions: "lock.shield.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .dock: Color(red: 0.85, green: 0.21, blue: 0.50)
        case .modes: Color(red: 0.69, green: 0.55, blue: 1.0)
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .vault: Color(red: 0.32, green: 0.66, blue: 0.62)
        case .routines: Color(red: 0.95, green: 0.68, blue: 0.22)
        case .focus: Color(red: 0.30, green: 0.68, blue: 0.95)
        case .apps: Color(red: 0.35, green: 0.78, blue: 0.55)
        case .look: Color(red: 1.0, green: 0.62, blue: 0.48)
        case .permissions: Color(red: 0.55, green: 0.58, blue: 0.65)
        case .about: Color(red: 0.55, green: 0.58, blue: 0.65)
        }
    }

    var subtitle: String {
        switch self {
        case .dock: "Choose your dock, and where it sits."
        case .modes: "Each Desktop has its own mode, with its own apps."
        case .claude: "Claude, Codex, or no AI at all."
        case .vault: "What Petal AI fills in for you, without seeing secrets."
        case .routines: "What Petal does by itself, in your words."
        case .focus: "Gentle cards when you drift from your mode."
        case .apps: "What the dock shows besides your apps."
        case .look: "Size, motion and color."
        case .permissions: "What macOS lets Petal see."
        case .about: "Petal for macOS."
        }
    }
}

struct SettingsView: View {
    @Environment(PetalApp.self) private var app
    @State var selection: SettingsSection
    @State private var ask = ""

    var body: some View {
        let _ = BodyCount.hit("SettingsView")
        ZStack {
            Backdrop()
            HStack(spacing: 14) {
                sidebar
                Scroll {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        GlassEffectContainer(spacing: 14) {
                            VStack(alignment: .leading, spacing: 14) { content }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
            }
            .padding(.horizontal, 14)
            .padding(.top, 36)
            .padding(.bottom, 14)
        }
        .frame(minWidth: 780, minHeight: 540)
        .animation(.smooth(duration: 0.25), value: selection)
        .onReceive(SettingsBench.commands) { command in
            switch command {
            case .select(let section): selection = section
            case .type(let text): ask = text
            case .open(let section):
                // A view made ahead, opening on another page: as if made on it, without the page's animation.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { selection = section }
            }
        }
    }

    private var sidebar: some View {
        let _ = BodyCount.hit("sidebar")
        return VStack(alignment: .leading, spacing: 4) {
            if let provider = app.chatProvider {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").foregroundStyle(SettingsSection.claude.tint)
                TextField("Ask \(provider.name) to change anything…", text: $ask)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        app.claude.open(asking: text)
                        ask = ""
                    }
            }
            .padding(10)
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.bottom, 10)
            }

            ForEach(SettingsSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(section.tint.gradient, in: .rect(cornerRadius: 7))
                        Text(section.title).font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                    .background(selection == section ? AnyShapeStyle(.white.opacity(0.14)) : AnyShapeStyle(.clear),
                                in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Petal").font(.system(size: 12, weight: .semibold))
                    Text(app.version).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
        .padding(12)
        .frame(width: 230)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: selection.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(selection.tint.gradient, in: .rect(cornerRadius: 13))
                .shadow(color: selection.tint.opacity(0.45), radius: 12, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(selection.title).font(.system(size: 26, weight: .bold))
                Text(selection.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder private var content: some View {
        let _ = BodyCount.hit("page")
        switch selection {
        case .dock: DockSettings()
        case .modes: ModesSettings()
        case .claude: ClaudeSettings()
        case .vault: VaultSettings()
        case .routines: RoutinesSettings()
        case .focus: FocusSettings()
        case .apps: AppsSettings()
        case .look: LookSettings()
        case .permissions: PermissionsSettings()
        case .about: AboutSettings()
        }
    }
}

// MARK: - Building blocks

/// What's behind a window's content. Petal's windows are Liquid Glass themselves (`NSWindow.setGlassContent`), so
/// the windows and desktop behind them show through, blurred; this only adds a faint wash so text stays easy to read
/// over a busy window. A snapshot can't see behind a window, so there it's a plain gradient.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.snapshotting) private var snapshotting

    var body: some View {
        let _ = BodyCount.hit("Backdrop")
        ZStack {
            if snapshotting {
                LinearGradient(colors: [Color(red: 0.85, green: 0.21, blue: 0.50), Color(red: 0.36, green: 0.27, blue: 0.62)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            scheme == .dark ? Color.black.opacity(0.16) : Color.white.opacity(0.18)
        }
        .ignoresSafeArea()
    }
}

extension NSWindow {
    /// Once closed, the window lets its content go, so its views, timers and observers stop instead of running on
    /// out of sight; `setGlassContent` makes it anew the next time it's shown. A moment after it's gone, so its
    /// closing is drawn as it was.
    func letContentGoWhenClosed() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: self, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    guard let self, !self.isVisible, let glass = self.contentView as? NSGlassEffectView else { return }
                    glass.contentView = nil
                }
            }
        }
    }

    /// The window itself becomes Liquid Glass (AppKit's own `NSGlassEffectView`): what's behind it shows through,
    /// blurred, and the content sits in the glass.
    func setGlassContent<Content: View>(_ view: Content) {
        isOpaque = false
        backgroundColor = .clear
        let glass = (contentView as? NSGlassEffectView) ?? NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 16
        glass.contentView = NSHostingView(rootView: view)
        contentView = glass
    }
}

/// A card of settings on glass.
struct Card<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        let _ = BodyCount.hit("Card")
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
            content
            if let footer { Text(footer).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// A switch bound to a boolean setting.
struct SettingToggle: View {
    @Environment(PetalApp.self) private var app
    let key: String
    let title: String
    var detail: String? = nil

    var body: some View {
        let _ = BodyCount.hit("SettingToggle")
        Toggle(isOn: Binding(get: { app.config.bool(key) }, set: { app.config.set(key, $0) })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

struct SettingSlider: View {
    @Environment(PetalApp.self) private var app
    let key: String
    let title: String
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { String(Int($0)) }

    var body: some View {
        let _ = BodyCount.hit("SettingSlider")
        HStack {
            Text(title)
            Slider(value: Binding(get: { app.config.number(key) },
                                  set: { app.config.set(key, step >= 1 ? Double(Int($0)) : ($0 * 100).rounded() / 100) }),
                   in: range, step: step)
            Text(format(app.config.number(key))).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - Dock

struct DockSettings: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        let _ = BodyCount.hit("DockSettings")
        HStack(spacing: 14) {
            DockChoice(title: "Petal", detail: "A mode for every Desktop, and Claude.", selected: app.config.whichDock == "petal") {
                PetalDockSketch()
            } choose: { app.useDock("petal") }
            DockChoice(title: "macOS Dock", detail: "Apple's own. Petal stays off.", selected: app.config.whichDock == "macos") {
                MacDockSketch()
            } choose: { app.useDock("macos") }
        }

        Text("Your own Dock is kept safe: quitting Petal, or removing it, brings it back as it was.")
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 6)
            .fixedSize(horizontal: false, vertical: true)

        Card(title: "Where it sits") {
            Picker("Position", selection: Binding(get: { app.config.position }, set: { app.config.setDock("position", $0) })) {
                Text("Bottom").tag("bottom")
                Text("Left").tag("left")
                Text("Right").tag("right")
            }
            .pickerStyle(.segmented)
            Toggle("Auto-hide", isOn: Binding(get: { app.config.autoHide }, set: { app.config.setDock("autoHide", $0) }))
                .toggleStyle(.switch).controlSize(.small)
            if !app.config.autoHide {
                Toggle(isOn: Binding(get: { app.config.keepWindowsClear }, set: { app.config.setDock("keepWindowsClear", $0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Keep windows clear of the dock")
                        Text("Windows end above the dock instead of running under it.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch).controlSize(.small)
            }
            Toggle("Open Petal at login", isOn: Binding(get: { app.openAtLogin }, set: { app.openAtLogin = $0 }))
                .toggleStyle(.switch).controlSize(.small)
            SettingToggle(key: "menuBarIcon", title: "Petal in the menu bar", detail: "Your mode, your Desktops, and updates.")
        }

        ShortcutsCard()

        Card(title: "Bring your Dock along", footer: "Copies macOS's Dock into a mode called My Dock, which every Desktop starts in, and its folders into stacks. Your Dock itself doesn't change.") {
            HStack(spacing: -6) {
                ForEach(app.systemDockApps.prefix(9), id: \.self) { id in
                    Image(nsImage: Apps.icon(id)).resizable().frame(width: 34, height: 34)
                }
            }
            Button("Import Dock") { app.config.importSystemDock() }
                .buttonStyle(.glassProminent)
                .tint(SettingsSection.dock.tint)
        }
    }
}

struct DockChoice<Sketch: View>: View {
    let title: String
    let detail: String
    let selected: Bool
    @ViewBuilder var sketch: Sketch
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.18))
                    sketch.padding(.horizontal, 10)
                }
                .frame(height: 96)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(selected ? SettingsSection.dock.tint : .secondary)
                }
            }
            .padding(12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(SettingsSection.dock.tint.opacity(0.18)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(selected ? SettingsSection.dock.tint : .clear, lineWidth: 2))
    }
}

/// A small drawing of Petal's dock, with the default mode's own apps.
struct PetalDockSketch: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        let mode = app.config.mode(id: app.config.defaultMode)
        HStack(spacing: 5) {
            ModeIcon(icon: mode?.icon ?? "", size: 10)
                .foregroundStyle(mode.map { Color(nsColor: $0.color) } ?? .pink)
                .frame(width: 22, height: 22)
                .glassEffect(.regular, in: .circle)
            ForEach((mode?.apps ?? []).filter(Apps.shows).prefix(6), id: \.self) { id in
                Image(nsImage: Apps.icon(id)).resizable().frame(width: 22, height: 22)
            }
            Image(systemName: "sparkle").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(SettingsSection.claude.tint.gradient, in: .circle)
        }
        .padding(6)
        .glassEffect(.regular, in: .capsule)
    }
}

/// A small drawing of macOS's Dock, with its own apps.
struct MacDockSketch: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        HStack(spacing: 4) {
            ForEach(app.systemDockApps.prefix(7), id: \.self) { id in
                Image(nsImage: Apps.icon(id)).resizable().frame(width: 22, height: 22)
            }
            Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 18)
            Image(nsImage: NSWorkspace.shared.icon(forFile: Stacks.trash.path)).resizable().frame(width: 22, height: 22)
        }
        .padding(6)
        .background(.white.opacity(0.18), in: .rect(cornerRadius: 10))
    }
}

// MARK: - Modes

struct ModesSettings: View {
    @Environment(PetalApp.self) private var app
    @State private var editing: Mode?

    var body: some View {
        let _ = BodyCount.hit("ModesSettings")
        SettingToggle(key: "modes", title: "Focus modes", detail: "Each Desktop's own mode, with its own apps.")
            .padding(16).glassEffect(.regular, in: .rect(cornerRadius: 20))
        WindowsCard()

        DescribeDayCard()
        SuggestionsCard()

        let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(app.config.modes) { mode in
                ModeCard(mode: mode, isDefault: mode.id == app.config.defaultMode, desktops: app.config.desktops(in: mode.id))
                    .onTapGesture { editing = mode }
            }
            Button {
                editing = Mode(id: "mode\(Int(Date().timeIntervalSince1970) % 100000)", name: "New mode", icon: "circle.fill",
                               color: NSColor(hex: "#5fb8ff")!, about: "", apps: [], sites: [], focusDelay: 0, allow: [])
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
                    Text("New mode").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 150)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        }

        Card(title: "Desktops", footer: "Switching Desktop swaps the dock to that Desktop's mode. Clicking the mode button in the dock changes it too.") {
            let count = max(app.desktopCount, app.config.workspaces.keys.compactMap(Int.init).max() ?? 0, 1)
            ForEach(1...count, id: \.self) { number in
                HStack {
                    Text("Desktop \(number)")
                    Spacer()
                    Picker("", selection: Binding(get: { app.config.mode(forDesktop: number)?.id ?? "" },
                                                  set: { app.config.setMode($0, forDesktop: number) })) {
                        ForEach(app.config.modes) { mode in Text(mode.name).tag(mode.id) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
            Button("See every Desktop") { app.overview.show() }.buttonStyle(.glass)
        }
        ScheduleCard()
        ShareDockCard()
        .sheet(item: $editing) { mode in
            ModeEditor(mode: mode, isNew: !app.config.modes.contains { $0.id == mode.id }).environment(app)
        }
    }
}

struct ModeCard: View {
    let mode: Mode
    let isDefault: Bool
    let desktops: [Int]

    var body: some View {
        let _ = BodyCount.hit("ModeCard")
        let color = Color(nsColor: mode.color)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ModeIcon(icon: mode.icon, size: 15)
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(color.gradient, in: .circle)
                    .shadow(color: color.opacity(0.5), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.name).font(.system(size: 15, weight: .semibold))
                    Text(mode.about.isEmpty ? " " : mode.about).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: -5) {
                ForEach(mode.apps.filter(Apps.shows).prefix(7), id: \.self) { id in
                    Image(nsImage: Apps.icon(id)).resizable().frame(width: 30, height: 30)
                }
                if mode.apps.isEmpty { Text("No apps yet").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .frame(height: 30)
            HStack(spacing: 6) {
                if isDefault { Chip(text: "Default", color: color) }
                ForEach(desktops, id: \.self) { Chip(text: "Desktop \($0)", color: color) }
            }
            .frame(height: 18)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .contentShape(.rect)
        .glassEffect(.regular.tint(color.opacity(0.10)).interactive(), in: .rect(cornerRadius: 20))
    }
}

struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.22), in: .capsule)
    }
}

struct ModeEditor: View {
    @Environment(PetalApp.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var mode: Mode
    let isNew: Bool
    @State private var adding = false
    @State private var sitesText = ""

    static let symbols = ["hammer", "pencil", "bubble.left.and.bubble.right", "book", "music.note", "gamecontroller",
                          "paintbrush", "briefcase", "graduationcap", "film", "camera", "heart", "leaf", "moon",
                          "sun.max", "cart", "dumbbell", "airplane", "house", "dock.rectangle", "sparkle", "circle.fill"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ModeIcon(icon: mode.icon, size: 18).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Color(nsColor: mode.color).gradient, in: .circle)
                TextField("Name", text: $mode.name).font(.system(size: 20, weight: .semibold)).textFieldStyle(.plain)
                ColorPicker("", selection: Binding(get: { Color(nsColor: mode.color) }, set: { mode.color = NSColor($0) }),
                            supportsOpacity: false).labelsHidden()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 11), spacing: 6) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button { mode.icon = symbol } label: {
                        Image(systemName: symbol).frame(width: 30, height: 30)
                            .background(mode.icon == symbol ? Color(nsColor: mode.color).opacity(0.35) : .clear, in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("What it's for (Claude sorts new apps with this)", text: $mode.about, axis: .vertical)
                .lineLimit(2...3)
            VStack(alignment: .leading, spacing: 6) {
                Text("Apps").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(mode.apps, id: \.self) { id in
                            VStack(spacing: 3) {
                                Image(nsImage: Apps.icon(id)).resizable().frame(width: 36, height: 36)
                                Text(Apps.name(id)).font(.system(size: 9)).lineLimit(1).frame(width: 52)
                            }
                            .overlay(alignment: .topTrailing) {
                                Button { mode.apps.removeAll { $0 == id } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Button { adding = true } label: {
                            Image(systemName: "plus").frame(width: 36, height: 36).background(.quaternary, in: .rect(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $adding) {
                            AppPicker { mode.apps.append($0.id); adding = false }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            TextField("Sites, comma separated (domains like github.com, or words in tab titles)", text: $sitesText)
            Toggle(isOn: Binding(get: { mode.isDistracting }, set: { mode.distracting = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Distracting")
                    Text("Pulls you away from work, like social media or games. Getting in takes a wait, and in other modes its apps and sites are blocked.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            if mode.isDistracting {
                HStack {
                    Text("Wait to get in")
                    Slider(value: Binding(get: { mode.wait }, set: { mode.focusDelay = $0 }), in: 5...120, step: 5)
                    Text("\(Int(mode.wait)) s").monospacedDigit().frame(width: 52)
                }
            }
            Toggle("Hold notifications from other apps", isOn: $mode.hold).toggleStyle(.switch)
            ShortcutPicker(name: $mode.shortcut)
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { app.config.delete(mode: mode.id); dismiss() }
                    Button("Make default") { app.config.setDefaultMode(mode.id) }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    mode.sites = sitesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    app.config.save(mode)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { sitesText = mode.sites.joined(separator: ", ") }
    }
}

/// The "+" search: installed apps, filtered as you type.
struct AppPicker: View {
    let pick: (InstalledApp) -> Void
    @State private var query = ""

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search apps", text: $query).textFieldStyle(.roundedBorder)
            List(Apps.search(query).prefix(60)) { app in
                Button { pick(app) } label: {
                    HStack {
                        Image(nsImage: Apps.icon(app.id)).resizable().frame(width: 20, height: 20)
                        Text(app.name)
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .padding(10)
        .frame(width: 280, height: 360)
    }
}

// MARK: - Claude

struct ClaudeSettings: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        let _ = BodyCount.hit("ClaudeSettings")
        Card(title: "Your AI", footer: "Each is your own app and account. Choose one, both, or neither: without AI, Petal is still a whole dock.") {
            ProviderList()
        }
        .onAppear { app.aiSetup.refreshAll() }
        ForEach(app.providers) { APIKeyCard(provider: $0) }
        if let provider = app.chatProvider {
            if let spent = app.usage.spentText {
                Card(footer: provider == .claude ? "What Claude Code reports for Petal's own chats and quick calls on your key. Anthropic's console has the bill."
                     : "Estimated from Codex's tokens at OpenAI's list prices, for Petal's own chats and quick calls on your key. OpenAI's usage page has the bill.") {
                    Text(spent).font(.system(size: 20, weight: .semibold).monospacedDigit())
                }
            } else {
                Card {
                    HStack(spacing: 18) {
                        UsageRing(usage: app.usage, size: 64)
                        VStack(alignment: .leading, spacing: 6) {
                            if app.usage.limits.isEmpty {
                                Text(app.usage.help.isEmpty ? "Checking your \(provider.name) usage…" : app.usage.help).foregroundStyle(.secondary)
                            }
                            ForEach(app.usage.limits, id: \.label) { limit in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(limit.label).font(.system(size: 12, weight: .medium))
                                        Spacer()
                                        Text("\(Int(limit.percent * 100))%").font(.system(size: 12).monospacedDigit())
                                        if let reset = limit.resetsAt {
                                            Text("resets \(reset, style: .relative)").font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                    }
                                    ProgressView(value: limit.percent).tint(UsageRing.color(limit.percent))
                                }
                            }
                        }
                    }
                }
            }
            Card(title: "Chat") {
                Picker("Writing while it works", selection: Binding(get: { app.config.string("chatWhileWorking") }, set: { app.config.set("chatWhileWorking", $0) })) {
                    Text("Steers it").tag("steer")
                    Text("Waits its turn").tag("queue")
                }
                if app.providers.count > 1 {
                    Picker("Chat with", selection: Binding(get: { provider.rawValue }, set: {
                        app.config.set("chatProvider", $0)
                        Task { await app.usage.refresh() }
                    })) {
                        ForEach(app.providers) { Text($0.name).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                if app.models(for: provider).count > 1 {
                    Picker("Model", selection: Binding(get: { app.currentModel(for: provider) }, set: { app.config.set(provider.modelSetting, $0) })) {
                        ForEach(app.models(for: provider), id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                }
                Picker("Effort", selection: Binding(get: { app.config.string(provider.effortSetting) }, set: { app.config.set(provider.effortSetting, $0) })) {
                    ForEach(app.efforts(for: provider), id: \.self) { Text($0.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Access", selection: Binding(get: { app.config.string("claudeAccess") }, set: { app.config.set("claudeAccess", $0) })) {
                    Text(provider == .claude ? "Ask before risky steps" : "Safe steps only").tag("auto")
                    Text("Full access").tag("full")
                }
                Button("Open \(provider.name)") { app.claude.open(asking: nil) }.buttonStyle(.glass)
            }
            Card(title: "Your other AI sessions", footer: "Petal's tools, skill and `petal` command are set up for Claude Code and Codex, so you can ask any session to change your dock.") {
                SettingToggle(key: "otherAgents", title: "Let them change Petal", detail: "T3 Code, or Claude Code and Codex in a terminal.")
            }
            Card(title: "In the background") {
                SettingToggle(key: "claudeUsage", title: "Usage ring", detail: "Around the \(provider.name) button, every 5 minutes.")
                SettingToggle(key: "ai", title: "Sort new apps and sites", detail: "\(provider.name) decides which mode something new belongs to.")
                DailySummaryRow()
            }
            Card(title: "Using your apps", footer: "Petal AI presses buttons, types and chooses menu items with a pink pointer of its own; yours stays where it is. It asks before it uses each app, and Stop or Esc ends it.") {
                SettingToggle(key: "computerUse", title: "Let Petal AI use your apps", detail: "Never apps kept private, and never password fields.")
            }
            MemoryCard()
            PrivacyCard()
            AIHistoryCard()
            if !app.config.strings("aiAllowed").isEmpty {
                Card(title: "Allowed without asking", footer: "You chose Always for these. Take one away and Petal AI asks again.") {
                    ForEach(app.config.strings("aiAllowed"), id: \.self) { kind in
                        HStack {
                            AllowedKindName(kind: kind)
                            Spacer()
                            RoundButton(symbol: "xmark") { app.config.set("aiAllowed", app.config.strings("aiAllowed").filter { $0 != kind }) }
                        }
                    }
                }
            }
            Card(title: "Your notes for \(provider.name)", footer: "\(provider.name) reads these every time you ask it something.") {
                InstructionsEditor()
            }
        }
    }
}

/// What Petal AI remembers, everywhere and per mode, each with a way to forget it.
struct MemoryCard: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        Card(title: "Memory", footer: "Petal AI keeps what helps it help you, so you don't have to say it twice. All of it is here; ask it to forget anything.") {
            SettingToggle(key: "aiMemory", title: "Remember what helps", detail: "What you ask it to, and what it notices along the way.")
            SettingToggle(key: "aiLearns", title: "Learn from each mode", detail: "Once a day, from the apps you use in it and for how long.")
            if app.config.bool("aiMemory") {
                if app.assist.memories.isEmpty {
                    Text("Nothing yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(app.assist.memories) { memory in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(memory.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(app.config.modes.first { $0.id == memory.mode }?.name ?? "Everywhere")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        RoundButton(symbol: "xmark") { app.assist.forget(id: memory.id, matching: nil) }
                    }
                }
            }
        }
    }
}

/// Everything Petal AI did, newest first, with Undo where it can be undone.
struct AIHistoryCard: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        Card(title: "What Petal AI did", footer: app.assist.history.isEmpty ? "Things it does on your Mac show here, each with a way back." : nil) {
            if app.assist.history.isEmpty {
                Text("Nothing yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(app.assist.history.prefix(30)) { done in
                HStack(spacing: 8) {
                    Text(done.text).font(.system(size: 13)).strikethrough(done.undone).foregroundStyle(done.undone ? .secondary : .primary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(done.at, style: .relative).font(.system(size: 11)).foregroundStyle(.secondary)
                    if let undo = done.undo, !done.undone {
                        if case .open = undo {
                            Button("Open") { app.assist.undo(done) }.buttonStyle(.glass).controlSize(.small)
                        } else {
                            Button("Undo") { app.assist.undo(done) }.buttonStyle(.glass).controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

/// Apps Petal AI never looks into: it gets their name, never their windows, text or a picture of them.
struct PrivacyCard: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        let ids = app.config.strings("aiNeverLook")
        Card(title: "Kept private", footer: "Petal AI sees only these apps' names: never their windows, text or a picture of them.") {
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 8) {
                    Image(nsImage: Apps.icon(id)).resizable().frame(width: 18, height: 18)
                    Text(Apps.name(id)).font(.system(size: 13))
                    Spacer()
                    RoundButton(symbol: "xmark") { app.config.set("aiNeverLook", ids.filter { $0 != id }) }
                }
            }
            Menu("Add an app") {
                ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !ids.contains($0.bundleIdentifier ?? "") }
                    .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }.sorted { $0.1 < $1.1 }, id: \.0) { id, name in
                    Button(name) { app.config.set("aiNeverLook", ids + [id]) }
                }
            }
            .fixedSize()
        }
    }
}

/// The day's summary: on or off, and when.
struct DailySummaryRow: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        let time = app.config.string("dailySummary")
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Summary of the day").font(.system(size: 13))
                Text("A card with your day in each mode, and a line from Petal AI.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !time.isEmpty {
                DatePicker("", selection: Binding(get: { Self.date(time) }, set: { app.config.set("dailySummary", Self.text($0)) }),
                           displayedComponents: .hourAndMinute).labelsHidden().datePickerStyle(.field)
            }
            Toggle("", isOn: Binding(get: { !time.isEmpty }, set: { app.config.set("dailySummary", $0 ? "18:00" : "") }))
                .toggleStyle(.switch).labelsHidden()
        }
    }

    static func date(_ text: String) -> Date {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: parts.first ?? 18, minute: parts.dropFirst().first ?? 0, second: 0, of: Date()) ?? Date()
    }

    static func text(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 18, parts.minute ?? 0)
    }
}

/// What the kinds of thing Petal AI asks about are called.
@MainActor
enum AllowedKinds {
    static func name(_ kind: String) -> String {
        switch kind {
        case "quit": "Quitting apps"
        case "close": "Closing windows"
        case "trash": "Moving files to the Trash"
        case "tidy": "Tidying many files at once"
        default: kind.hasPrefix("computer:") ? "Using \(Apps.cachedName(String(kind.dropFirst(9))) ?? String(kind.dropFirst(9)))" : kind
        }
    }
}

/// A kind's name in the Allowed list: an app's name is read off the main thread (its bundle id until then).
struct AllowedKindName: View {
    let kind: String
    @State private var appName: String?

    var body: some View {
        Text(appName.map { "Using \($0)" } ?? AllowedKinds.name(kind)).font(.system(size: 13))
            .task(id: kind) {
                guard kind.hasPrefix("computer:") else { return }
                let id = String(kind.dropFirst(9))
                if Apps.cachedName(id) == nil { Apps.loadName(id) { appName = $0 } }
            }
    }
}

struct InstructionsEditor: View {
    @Environment(PetalApp.self) private var app
    @State private var text = ""

    var body: some View {
        let notes = app.instructions
        TextEditor(text: $text)
            .font(.system(size: 12))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 110)
            .padding(8)
            .background(.black.opacity(0.12), in: .rect(cornerRadius: 12))
            // Nothing to type over until the file was first read: typing onto an empty editor while the notes are
            // still on their way would be lost, or write over them. It's empty until then, so it looks no different.
            .disabled(!notes.loaded)
            // As last read off the main thread; read again as it appears, and while it shows, a change made elsewhere
            // (an agent, an editor) comes in within a second.
            .onAppear {
                text = notes.text
                notes.watch(true)
                notes.refresh(from: app.config.instructionsFile)
            }
            .onDisappear { notes.watch(false) }
            .onChange(of: notes.version) { _, _ in if text != notes.text { text = notes.text } }
            .onChange(of: text) { _, new in notes.save(new, to: app.config.instructionsFile) }
    }
}

/// The notes for the AI, kept in memory for the settings window. Read and written off the main thread, on one queue,
/// in order: a read asked for after a save reads what that save wrote. A read begun before a save, or while the
/// person is typing, never replaces what they typed. A save never writes over a change made elsewhere that the editor
/// hasn't shown: the file's version comes into the editor instead, as a change made elsewhere always has.
@MainActor @Observable
final class InstructionsText {
    @ObservationIgnored private(set) var text = ""
    /// Counts reads that changed `text`, so the editor follows a change made elsewhere.
    private(set) var version = 0
    /// Whether the file was read once: until then `text` is no baseline, and the editor takes no typing.
    private(set) var loaded = false
    /// What the file held when `text` was read from it or written to it: a save writes only over this.
    @ObservationIgnored private var base = ""
    /// Counts saves: a read begun before one is older than what's typed, and is dropped.
    @ObservationIgnored private var saves = 0
    @ObservationIgnored private var lastSave = Date.distantPast
    /// The file's modification date as last seen: the watcher reads the file again only once it changes.
    @ObservationIgnored private var seen: Date?
    /// Editors showing the notes: while any does, the file is watched.
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var file: URL?
    nonisolated private static let queue = DispatchQueue(label: "petal.instructions", qos: .userInitiated)
    /// How long after a key the person counts as typing: a change from elsewhere waits until they pause.
    private static let typing: TimeInterval = 1.5

    /// Reads the file (off the main thread, unless `wait`). `ifChanged`: only when its modification date changed.
    func refresh(from file: URL, wait: Bool = false, ifChanged: Bool = false) {
        self.file = file
        let asOf = saves
        let known = ifChanged ? seen : nil
        let read = { () -> (stamp: Date?, text: String)? in
            let stamp = Self.modified(file)
            if ifChanged, stamp == known { return nil }
            return (stamp, Self.contents(file))
        }
        let apply = { (disk: (stamp: Date?, text: String)?) in
            guard let disk, asOf == self.saves else { return }
            // Typing: theirs stays; the change is read again once they pause (and a save meanwhile doesn't write
            // over it: it shows the file's version instead).
            guard Date().timeIntervalSince(self.lastSave) >= Self.typing else { return }
            self.show(disk)
        }
        if wait { apply(Self.queue.sync { read() }); return }
        Self.queue.async {
            let disk = read()
            DispatchQueue.main.async { MainActor.assumeIsolated { apply(disk) } }
        }
    }

    func save(_ new: String, to file: URL) {
        guard new != text else { return }
        let over = base
        text = new
        base = new   // the next save builds on this one
        saves += 1
        lastSave = Date()
        let saved = saves
        Self.queue.async {
            // Writes only over what the editor had: a change made elsewhere since then is kept, and shown instead.
            let now = Self.contents(file)
            let written = now == over && (try? new.write(to: file, atomically: true, encoding: .utf8)) != nil
            let disk = (stamp: Self.modified(file), text: written ? new : now)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard saved == self.saves else { return }   // a later save decides (and finds the same change)
                if written { self.seen = disk.stamp } else { self.show(disk) }
            } }
        }
    }

    /// The file as read: the editor shows it and builds on it.
    private func show(_ disk: (stamp: Date?, text: String)) {
        seen = disk.stamp
        base = disk.text
        if !loaded { loaded = true }
        guard disk.text != text else { return }
        text = disk.text
        version += 1
    }

    /// An editor showing the notes appeared (true) or went (false).
    func watch(_ on: Bool) { watchers = max(0, watchers + (on ? 1 : -1)) }

    /// Each second (Config's watcher): while an editor shows the notes, a change made elsewhere is read.
    func tick() {
        guard watchers > 0, let file else { return }
        refresh(from: file, ifChanged: true)
    }

    nonisolated private static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    nonisolated private static func contents(_ file: URL) -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }
}

// MARK: - Focus, apps, look

// FocusSettings is in FocusSettings.swift.

struct AppsSettings: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        let _ = BodyCount.hit("AppsSettings")
        Card(title: "Apps") {
            SettingToggle(key: "thisWorkspaceOnly", title: "Only this Desktop's apps", detail: "Running apps from other Desktops stay out of the dock.")
            SettingToggle(key: "previews", title: "Window previews", detail: "Hover a running app to see its windows.")
            SettingToggle(key: "minimized", title: "Minimized windows")
            SettingToggle(key: "badges", title: "Badges", detail: "Unread counts on app icons.")
            SettingToggle(key: "bounce", title: "Bounce", detail: "Once, when an app wants you.")
            SettingToggle(key: "progress", title: "Download progress")
            SettingToggle(key: "quickActions", title: "Quick actions in the right-click menu")
            SettingToggle(key: "recentFiles", title: "Recent files in the right-click menu")
            SettingToggle(key: "dropToOpen", title: "Drop files on an app to open them")
        }
        Card(title: "Extras") {
            SettingToggle(key: "nowPlaying", title: "Now playing", detail: "Music and Spotify, with album art.")
            SettingToggle(key: "stacks", title: "Folder stacks")
            ForEach(app.config.strings("stackFolders"), id: \.self) { folder in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Stacks.url(folder).path)).resizable().frame(width: 20, height: 20)
                    Text(folder).font(.system(size: 12))
                    Spacer()
                    Button { app.config.set("stackFolders", app.config.strings("stackFolders").filter { $0 != folder }) } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Add folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let home = NSHomeDirectory()
                let path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
                app.config.set("stackFolders", app.config.strings("stackFolders") + [path])
            }
            SettingToggle(key: "trash", title: "Trash")
        }
    }
}

struct LookSettings: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        let _ = BodyCount.hit("LookSettings")
        Card(title: "Icons") {
            SettingSlider(key: "iconSize", title: "Size", range: 24...72)
            SettingSlider(key: "idleOpacity", title: "Apps not running", range: 0.2...1, step: 0.05,
                          format: { "\(Int($0 * 100))%" })
            SettingToggle(key: "magnification", title: "Magnification", detail: "Icons grow under the pointer, and their neighbours make room.")
            if app.config.bool("magnification") {
                SettingSlider(key: "magnificationAmount", title: "Grow", range: 0.1...1, step: 0.05, format: { "\(Int($0 * 100))%" })
            } else {
                SettingToggle(key: "hoverLift", title: "Lift on hover")
                SettingSlider(key: "hoverLiftAmount", title: "Lift", range: 0...0.3, step: 0.01, format: { "\(Int($0 * 100))%" })
            }
            SettingToggle(key: "appGlow", title: "Glow", detail: "Running apps glow in their icon's color.")
            SettingToggle(key: "tooltips", title: "Names on hover")
            SettingToggle(key: "separators", title: "Dividers between sections")
        }
        Card(title: "Color", footer: "The dock is macOS's own Liquid Glass. A color tints it; leave it empty to keep it clear.") {
            ColorSetting(key: "dockColor", title: "Dock tint")
            ColorSetting(key: "accentColor", title: "Accent")
        }
    }
}

struct ColorSetting: View {
    @Environment(PetalApp.self) private var app
    let key: String
    let title: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if !app.config.string(key).isEmpty {
                Button("Clear") { app.config.set(key, "") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            ColorPicker("", selection: Binding(get: { Color(nsColor: NSColor(hex: app.config.string(key)) ?? .clear) },
                                               set: { app.config.set(key, NSColor($0).hex) }), supportsOpacity: false)
                .labelsHidden()
        }
    }
}

// MARK: - Permissions, about

struct PermissionsSettings: View {
    @Environment(PetalApp.self) private var app
    /// Checked every 1.5 s; the page draws again only when one changes.
    @State private var trusted = Windows.trusted
    @State private var capture = Capture.allowed
    let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let _ = BodyCount.hit("PermissionsSettings")
        Permission(symbol: "accessibility", title: "Accessibility", detail: "Window previews, minimized windows, badges, and focus cards.",
                   granted: trusted) { Windows.askForPermission() }
        Permission(symbol: "rectangle.dashed.badge.record", title: "Screen Recording", detail: "A picture of each window in previews; without it, they list windows by name. Petal never records: it takes a still while you hover an app.",
                   granted: capture) { Capture.askForPermission() }
        Permission(symbol: "bell.badge", title: "Full Disk Access", detail: "Seeing notifications, to hold them in modes that hold them. Petal only reads Notification Center's list.",
                   granted: app.notes.canRead) { NotificationAccessRow.openSettings() }
        Permission(symbol: "safari", title: "Browsers", detail: "Which site a tab is on, and closing a distracting one. Each browser asks once.",
                   granted: Browsers.installed().isEmpty ? nil : app.browsers.allAllowed) { app.browsers.askAll {} }
        Permission(symbol: "music.note", title: "Music and Spotify", detail: "Now playing. macOS asks the first time a player is open.",
                   granted: nil) {}
            .onReceive(timer) { _ in
                let nowTrusted = Windows.trusted, nowCapture = Capture.allowed
                if nowTrusted != trusted { trusted = nowTrusted }
                if nowCapture != capture { capture = nowCapture }
                app.browsers.refresh()
            }
    }
}

struct Permission: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool?
    let ask: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 40, height: 40)
                .glassEffect(.regular, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let granted {
                if granted {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12, weight: .medium))
                } else {
                    Button("Allow…", action: ask).buttonStyle(.glassProminent).tint(SettingsSection.dock.tint)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct AboutSettings: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        let _ = BodyCount.hit("AboutSettings")
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
            Text("Petal").font(.system(size: 30, weight: .bold))
            Text("Version \(app.version)").foregroundStyle(.secondary)
            Text("A dock with a focus mode for every Desktop, and Claude built in. Free and open source, by Edgetr.")
                .multilineTextAlignment(.center).font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: 380)
            HStack {
                Button("Website") { NSWorkspace.shared.open(URL(string: "https://petal-dock.vercel.app")!) }.buttonStyle(.glass)
                Button("GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/edgetr/petal")!) }.buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))

        DoctorCard()

        Card(title: "Updates") {
            SettingToggle(key: "autoUpdate", title: "Update automatically", detail: "New versions install themselves, then offer a restart.")
            HStack {
                if let ready = app.updater.ready {
                    Button("Restart to update") { app.relaunch() }.buttonStyle(.glassProminent).tint(SettingsSection.dock.tint)
                    Button("What’s new in \(ready)") { app.releaseNotes.show(ready) }.buttonStyle(.glass)
                } else {
                    Button("Check now") { app.updater.check(manual: true) }.buttonStyle(.glass)
                    Text(app.updater.status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// "Check Petal": the doctor's findings, a button to fix what it can, and a way to report what it can't.
struct DoctorCard: View {
    @Environment(PetalApp.self) private var app
    @State private var findings: [Doctor.Finding] = []
    @State private var working = false
    @State private var reporting = false

    var body: some View {
        Card(title: "Check Petal", footer: "Finds and fixes common problems. If something's still wrong, report it: you see the report before it goes anywhere.") {
            ForEach(permissionFindings + findings) { finding in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: finding.level == "ok" ? "checkmark.circle.fill" : finding.level == "warn" ? "exclamationmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(finding.level == "ok" ? .green : finding.level == "warn" ? .orange : .red)
                    Text(finding.text + (finding.fixed.map { " Fixed: \($0)." } ?? "")).font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button(findings.isEmpty ? "Check Petal" : "Check again") { run(fix: false) }.buttonStyle(.glass)
                if findings.contains(where: { $0.level != "ok" && $0.fixed == nil }) {
                    Button("Fix what can be fixed") { run(fix: true) }.buttonStyle(.glassProminent).tint(SettingsSection.dock.tint)
                }
                Button("Report a problem…") { reporting = true }.buttonStyle(.glass)
                if working { ProgressView().controlSize(.small) }
            }
        }
        .sheet(isPresented: $reporting) { ReportSheet().environment(app) }
    }

    /// macOS grants these to the app itself, so the window checks them, not the doctor command.
    private var permissionFindings: [Doctor.Finding] {
        guard !findings.isEmpty else { return [] }
        return [Doctor.Finding(level: Windows.trusted ? "ok" : "warn", area: "permissions",
                               text: Windows.trusted ? "Petal can see your windows." : "Petal can't see your windows yet: allow it under Permissions."),
                Doctor.Finding(level: Capture.allowed ? "ok" : "warn", area: "permissions",
                               text: Capture.allowed ? "Window previews are allowed." : "Window previews need Screen Recording (optional).")]
    }

    private func run(fix: Bool) {
        working = true
        Task {
            let result = await AISetup.run(Bundle.main.executablePath ?? "", ["doctor", "--json"] + (fix ? ["--fix"] : []),
                                           environment: ProcessInfo.processInfo.environment, timeout: 120)
            let json = result.output.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? ""
            findings = (try? JSONDecoder().decode([String: [Doctor.Finding]].self, from: Data(json.utf8)))?["findings"] ?? []
            working = false
            app.docks.refresh()
        }
    }
}

struct ReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var what = ""
    @State private var preview = ""
    @State private var status = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report a problem").font(.system(size: 18, weight: .semibold))
            TextField("What happened?", text: $what, axis: .vertical).lineLimit(2...4)
            if !preview.isEmpty {
                ScrollView {
                    Text(preview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .padding(8)
                .background(.black.opacity(0.12), in: .rect(cornerRadius: 10))
                Text("This goes to github.com/edgetr/petal, where anyone can read it. Your username is replaced, and no window titles or file contents are included.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !status.isEmpty { Text(status).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if preview.isEmpty {
                    Button("Show the report") { run(["--preview"]) { preview = $0 } }
                        .buttonStyle(.glassProminent).disabled(what.trimmingCharacters(in: .whitespaces).isEmpty || working)
                } else {
                    Button("Report it") { run(["--yes"]) { status = $0.split(separator: "\n").last.map(String.init) ?? "" } }
                        .buttonStyle(.glassProminent).disabled(working || !status.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func run(_ flags: [String], done: @escaping (String) -> Void) {
        working = true
        Task {
            let result = await AISetup.run(Bundle.main.executablePath ?? "", ["report", what] + flags,
                                           environment: ProcessInfo.processInfo.environment, timeout: 120)
            working = false
            done(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
