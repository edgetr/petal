import AppKit
import Combine
import SwiftUI

/// The settings window: everything Petal can change, on Liquid Glass over the person's own wallpaper, blurred.
/// On Omarchy the right-click menu stays tiny and the rest is asking Claude; the Mac adds this window, and its
/// first field still asks the AI (when there is one).
@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(_ section: SettingsSection = .dock) {
        if window == nil {
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
            self.window = window
        }
        window?.contentView = NSHostingView(rootView: SettingsView(selection: section).environment(PetalApp.shared))
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case dock, modes, claude, focus, apps, look, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dock: "Dock"
        case .modes: "Modes"
        case .claude: "AI"
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
        ZStack {
            Wallpaper()
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
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        switch selection {
        case .dock: DockSettings()
        case .modes: ModesSettings()
        case .claude: ClaudeSettings()
        case .focus: FocusSettings()
        case .apps: AppsSettings()
        case .look: LookSettings()
        case .permissions: PermissionsSettings()
        case .about: AboutSettings()
        }
    }
}

// MARK: - Building blocks

/// The person's own wallpaper, blurred, so the glass has something to be glass over.
struct Wallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = Self.image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .blur(radius: 48, opaque: true)
                        .saturation(1.15)
                } else {
                    LinearGradient(colors: [Color(red: 0.85, green: 0.21, blue: 0.50), Color(red: 0.36, green: 0.27, blue: 0.62)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                (scheme == .dark ? Color.black.opacity(0.32) : Color.white.opacity(0.22))
            }
            .clipped()
        }
        .ignoresSafeArea()
    }

    static var image: NSImage? {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// A card of settings on glass.
struct Card<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
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
                ForEach(SystemDock.apps().prefix(9), id: \.self) { id in
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
            ForEach((mode?.apps ?? []).filter { Apps.url($0) != nil }.prefix(6), id: \.self) { id in
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
    var body: some View {
        HStack(spacing: 4) {
            ForEach(SystemDock.apps().prefix(7), id: \.self) { id in
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
        SettingToggle(key: "modes", title: "Focus modes", detail: "Each Desktop's own mode, with its own apps.")
            .padding(16).glassEffect(.regular, in: .rect(cornerRadius: 20))

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
            let count = max(Spaces.count(), app.config.workspaces.keys.compactMap(Int.init).max() ?? 0, 1)
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
                ForEach(mode.apps.filter { Apps.url($0) != nil }.prefix(7), id: \.self) { id in
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
            TextField("Sites, comma separated (words in tab titles: github, docs)", text: $sitesText)
            HStack {
                Text("Focus card after")
                Slider(value: $mode.focusDelay, in: 0...120, step: 5)
                Text(mode.focusDelay == 0 ? "never" : "\(Int(mode.focusDelay)) s").monospacedDigit().frame(width: 52)
            }
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
        Card(title: "Your AI", footer: "Each is your own app and account. Choose one, both, or neither: without AI, Petal is still a whole dock.") {
            ProviderList()
        }
        .onAppear { app.aiSetup.refreshAll() }
        if let provider = app.chatProvider {
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
            Card(title: "Chat") {
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
                    let picker = Picker("Model", selection: Binding(get: { app.currentModel(for: provider) }, set: { app.config.set(provider.modelSetting, $0) })) {
                        ForEach(app.models(for: provider), id: \.0) { Text($0.1).tag($0.0) }
                    }
                    if provider == .codex { picker.pickerStyle(.menu) } else { picker.pickerStyle(.segmented) }
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
            }
            Card(title: "Your notes for \(provider.name)", footer: "\(provider.name) reads these every time you ask it something.") {
                InstructionsEditor()
            }
        }
    }
}

struct InstructionsEditor: View {
    @Environment(PetalApp.self) private var app
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 110)
            .padding(8)
            .background(.black.opacity(0.12), in: .rect(cornerRadius: 12))
            .onAppear { text = (try? String(contentsOf: app.config.instructionsFile, encoding: .utf8)) ?? "" }
            .onChange(of: text) { _, new in try? new.write(to: app.config.instructionsFile, atomically: true, encoding: .utf8) }
    }
}

// MARK: - Focus, apps, look

struct FocusSettings: View {
    var body: some View {
        Card(footer: "When the window in front belongs to another mode, a card says so: \"x.com belongs to Social\", with Go back and Switch. Each mode sets how long to wait.") {
            SettingToggle(key: "focusGuard", title: "Focus cards")
            SettingToggle(key: "countdown", title: "Wait before leaving a mode", detail: "Switching to another mode waits out the mode's own delay.")
        }
        HistoryCard()
    }
}

struct AppsSettings: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
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
    @State private var tick = 0
    let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let _ = tick
        Permission(symbol: "accessibility", title: "Accessibility", detail: "Window lists, minimized windows, badges, and focus cards.",
                   granted: Windows.trusted) { Windows.askForPermission() }
        Permission(symbol: "rectangle.dashed.badge.record", title: "Screen Recording", detail: "Window previews. Petal never records; it takes a still of a window when you hover its app.",
                   granted: Capture.allowed) { Capture.askForPermission() }
        Permission(symbol: "music.note", title: "Music and Spotify", detail: "Now playing. macOS asks the first time a player is open.",
                   granted: nil) {}
            .onReceive(timer) { _ in tick += 1 }
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
