import AppKit
import Combine
import SwiftUI

/// The settings window: everything Petal can change, on one window of Liquid Glass that shows what's behind it. The
/// window is the only glass: the ask bar across its top, a sidebar with a tile for each part of Petal, and the page,
/// whose groups are a label and rows with hairlines between them. The right-click menu stays tiny, so this window
/// holds the rest. The pages and their rows are in `SettingsPages.swift`.
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

/// The settings window's pages, in the sidebar's order: one for each part of Petal.
enum SettingsSection: String, CaseIterable, Identifiable {
    case dock, look, notes, ai, vault, routines, privacy, about
    var id: String { rawValue }

    /// What these pages were called before, for whoever still opens one by that name.
    static let claude = SettingsSection.ai, apps = SettingsSection.dock, permissions = SettingsSection.privacy

    /// A page by its name, old or new ("claude" is Petal AI, "apps" the Dock, "permissions" Privacy).
    init?(named name: String) {
        switch name {
        case "claude": self = .ai
        case "apps": self = .dock
        case "permissions": self = .privacy
        default: self.init(rawValue: name)
        }
    }

    var title: String {
        switch self {
        case .dock: "Dock"
        case .look: "Look"
        case .notes: "Notes"
        case .ai: "Petal AI"
        case .vault: "Vault"
        case .routines: "Routines"
        case .privacy: "Privacy"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .dock: "dock.rectangle"
        case .look: "paintbrush.pointed.fill"
        case .notes: "note.text"
        case .ai: "sparkles"
        case .vault: "key.fill"
        case .routines: "wand.and.sparkles"
        case .privacy: "hand.raised.fill"
        case .about: "info"
        }
    }

    /// The part of Petal the page is about: its color is the tile's, and its controls'.
    var part: Part {
        switch self {
        case .dock: .dock
        case .look: .look
        case .notes: .notes
        case .ai: .ai
        case .vault: .vault
        case .routines: .routines
        case .privacy: .privacy
        case .about: .about
        }
    }

    var tint: Color { part.color }

    /// The color of the page's switches, sliders and filled buttons: its part's, or, where that is the neutral one
    /// (and on the Dock's page, whose color is the accent itself), the person's accent.
    @MainActor func controls(_ app: PetalApp) -> Color {
        switch self {
        case .dock, .privacy, .about: Color(nsColor: app.accent)
        default: part.color
        }
    }

    /// More words the ask bar finds the page by.
    var words: String {
        switch self {
        case .dock: "apps position shortcuts windows"
        case .look: "size color appearance theme"
        case .notes: "petal notes paper notebook"
        case .ai: "claude codex chat model"
        case .vault: "passwords logins cards keys addresses contacts import export agents"
        case .routines: "automation rules tidy"
        case .privacy: "permissions private memory history accessibility"
        case .about: "version update help report"
        }
    }
}

/// What the window shows: the page, and what's typed in the ask bar. Each view watches only what it draws, so a key
/// in the ask bar draws the bar again, and the page only once the search it means changes.
@MainActor @Observable
final class SettingsState {
    var selection: SettingsSection
    var ask = "" {
        didSet {
            let now = SettingsList.query(ask)
            if now != query { query = now }
        }
    }
    /// What the ask bar's text searches for; nil shows the page.
    private(set) var query: String?

    init(_ selection: SettingsSection) { self.selection = selection }

    /// A page chosen: the search, if any, is over.
    func go(_ section: SettingsSection) {
        if !ask.isEmpty { ask = "" }
        if selection != section { selection = section }
    }
}

struct SettingsView: View {
    @State private var state: SettingsState

    /// `asking`: what the ask bar already holds (a snapshot of the search).
    init(selection: SettingsSection, asking: String = "") {
        let state = SettingsState(selection)
        state.ask = asking
        _state = State(initialValue: state)
    }

    var body: some View {
        let _ = BodyCount.hit("SettingsView")
        ZStack {
            Backdrop()
            // No glass container around these: one would lift glass drawn behind its content (a note on Liquid Glass,
            // the dock's own glass while it magnifies) over that content.
            VStack(spacing: 12) {
                AskBar(state: state)
                HStack(alignment: .top, spacing: 10) {
                    SettingsSidebar(state: state)
                    SettingsContent(state: state)
                }
            }
            .padding(.horizontal, 12)
            // Under the window's own buttons: the strip above stays the window's to drag.
            .padding(.top, 34)
            .padding(.bottom, 12)
        }
        .frame(minWidth: 780, minHeight: 540)
        .onReceive(SettingsBench.commands) { command in
            switch command {
            case .select(let section): state.go(section)
            case .type(let text): state.ask = text
            case .open(let section):
                // A view made ahead, opening on another page: as if made on it, without the page's animation.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { state.go(section) }
            }
        }
    }
}

/// Across the top of the window: what's typed finds settings on every page as it's typed, and Return opens the page
/// of the first one found, or, when nothing matched, hands the words to Petal AI. With no AI chosen it only searches.
struct AskBar: View {
    @Environment(PetalApp.self) private var app
    let state: SettingsState

    var body: some View {
        let _ = BodyCount.hit("AskBar")
        @Bindable var state = state
        let ai = app.chatProvider != nil
        HStack(spacing: 8) {
            Image(systemName: ai ? "sparkle" : "magnifyingglass")
                .font(.system(size: TextSize.body, weight: .semibold))
                .foregroundStyle(ai ? AnyShapeStyle(Part.ai.color) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            TextField(ai ? "Ask Petal AI, or search settings" : "Search settings", text: $state.ask)
                .textFieldStyle(.plain)
                .font(.system(size: TextSize.body))
                .onSubmit {
                    let text = state.ask.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    // As in any search field, Return goes to what was found; only words that find nothing are a
                    // question for Petal AI.
                    if let query = state.query, let first = SettingsList.find(query, app: app).first {
                        state.go(first.section)
                    } else if ai {
                        app.claude.open(asking: text)
                        state.ask = ""
                    }
                }
                // Escape clears it: back to the page.
                .onExitCommand { if !state.ask.isEmpty { state.ask = "" } }
            if !state.ask.isEmpty {
                if ai { KeyCaps(text: "↩").help("Return opens the first setting found, or asks Petal AI") }
                RoundButton(symbol: "xmark") { state.ask = "" }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 36)
        .glassEffect(.clear.interactive(), in: .capsule)
    }
}

/// The pages, down the window's left side with no panel of their own: a tile in each part's color, its name, and a
/// dot by the page that's showing, as under a running app in the dock. Petal's icon and version rest at the bottom.
struct SettingsSidebar: View {
    @Environment(PetalApp.self) private var app
    let state: SettingsState

    var body: some View {
        let _ = BodyCount.hit("sidebar")
        let current = state.query == nil ? state.selection : nil
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                SidebarRow(section: section, current: current == section) { state.go(section) }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Petal").font(.system(size: TextSize.callout, weight: .semibold))
                    Text(app.version).font(.system(size: TextSize.small)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, SidebarRow.dot + SidebarRow.inset)
            .padding(.bottom, 4)
        }
        .frame(width: SettingsLook.sidebar)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct SidebarRow: View {
    let section: SettingsSection
    let current: Bool
    let action: () -> Void
    @State private var hovering = false
    static let dot: CGFloat = 5
    static let inset: CGFloat = 8

    var body: some View {
        Button(action: action) {
            HStack(spacing: Self.inset) {
                Circle().fill(section.part.color).frame(width: Self.dot, height: Self.dot).opacity(current ? 1 : 0)
                PartTile(section: section, size: 24)
                Text(section.title).font(.system(size: TextSize.body, weight: current ? .semibold : .medium))
                    .opacity(current || hovering ? 1 : 0.8)
                Spacer(minLength: 0)
            }
            .padding(.leading, 0)
            .padding(.trailing, Self.inset)
            .padding(.vertical, 5)
            .contentShape(.rect)
            // Under the pointer the row is clear glass of its own (pressed, it gives as glass does); at rest, nothing.
            .glassEffect(hovering ? .clear.interactive() : .identity, in: .rect(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// A part of Petal as a flat tile in its color, its symbol drawn on it.
struct PartTile: View {
    let section: SettingsSection
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: section.symbol)
            .font(.system(size: size > 20 ? TextSize.callout : TextSize.caption, weight: .semibold))
            .foregroundStyle(section.part.onColor)
            .frame(width: size, height: size)
            .background(section.part.color, in: .rect(cornerRadius: size > 20 ? Radius.control : Radius.chip))
    }
}

/// What the window shows beside the sidebar: the page, or what the ask bar found.
struct SettingsContent: View {
    let state: SettingsState

    var body: some View {
        let _ = BodyCount.hit("page")
        Group {
            if let query = state.query {
                SettingsSearch(query: query, state: state)
            } else {
                SettingsPage(section: state.selection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.smooth(duration: 0.25), value: state.selection)
    }
}

/// One page: its title, then its groups. Look keeps the dock itself in view above what scrolls.
struct SettingsPage: View {
    @Environment(PetalApp.self) private var app
    let section: SettingsSection

    var body: some View {
        Group {
            switch section {
            case .look:
                LookPage()
            case .vault:
                PageScroll {
                    PageTitle(text: section.title)
                    VaultSettings()
                }
            default:
                PageScroll {
                    PageTitle(text: section.title)
                    SettingsBlocks(blocks: SettingsList.blocks(section))
                }
                // Each page is its own: it opens at its top, wherever the last one was scrolled to.
                .id(section)
            }
        }
        .environment(\.settingsTint, section.controls(app))
    }
}

extension EnvironmentValues {
    /// The color of a page's switches and sliders: its part's. Only theirs: a button's glass is never tinted.
    @Entry var settingsTint: Color? = nil
}

/// A page's one title: nothing beside it, nothing under it.
struct PageTitle: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: TextSize.title, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}

/// A page's column: its groups one under another with room between them, as wide as reads well, scrolling.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Scroll {
            VStack(alignment: .leading, spacing: SettingsLook.between) { content }
                .padding(.horizontal, 8)
                .padding(.bottom, 20)
                .frame(maxWidth: SettingsLook.column, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }
}

/// What the ask bar found: the rows that match, from every page, each under its page's name and working as it does
/// there. A page's name alone finds the page.
struct SettingsSearch: View {
    @Environment(PetalApp.self) private var app
    let query: String
    let state: SettingsState

    var body: some View {
        let _ = BodyCount.hit("SettingsSearch")
        let found = SettingsList.find(query, app: app)
        PageScroll {
            if found.isEmpty {
                Text(app.chatProvider == nil ? "No setting matches." : "No setting matches. Return asks Petal AI.")
                    .font(.system(size: TextSize.body)).foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            ForEach(found) { hit in
                VStack(alignment: .leading, spacing: 4) {
                    Button { state.go(hit.section) } label: {
                        HStack(spacing: 8) {
                            PartTile(section: hit.section, size: 18)
                            Text(hit.section.title).font(.system(size: TextSize.heading, weight: .semibold))
                            Image(systemName: "chevron.right").font(.system(size: TextSize.caption, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if !hit.entries.isEmpty {
                        SettingsGroup { ForEach(hit.entries) { $0.view } }
                    }
                }
                .environment(\.settingsTint, hit.section.controls(app))
            }
        }
    }
}

// MARK: - Building blocks

/// The settings window's measures, once.
enum SettingsLook {
    static let sidebar: CGFloat = 190
    /// The widest a page's rows get.
    static let column: CGFloat = 620
    /// Between one group and the next.
    static let between: CGFloat = 26
    /// A row's least height, so a row with a switch and one with a button are as tall.
    static let row: CGFloat = 28
    /// The sliders' labels: one column, so every slider starts on one line.
    static let label: CGFloat = 132
    /// A slider's value, right-aligned in tabular digits.
    static let value: CGFloat = 40
}

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
    /// blurred, and the content sits in the glass. Its corner is the corner macOS gives a titled window.
    func setGlassContent<Content: View>(_ view: Content) {
        isOpaque = false
        backgroundColor = .clear
        let glass = (contentView as? NSGlassEffectView) ?? NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = Radius.card
        glass.contentView = NSHostingView(rootView: view)
        contentView = glass
    }
}

/// A group of settings, right on the window's glass: a small label, its rows with hairlines between them, and under
/// them, rarely, one line the person needs (a promise: "Nothing is deleted"). Each view given to it is a row.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    /// Room kept at the sides and under the rows for what reaches past a row (a paper's shadow, a field's ring).
    private static var slack: CGFloat { 12 }

    var body: some View {
        let _ = BodyCount.hit("SettingsGroup")
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.system(size: TextSize.callout, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
            // Every row draws the hairline above itself, and the rows are cut along their top edge only, which takes
            // the first row's away: hairlines between rows, none over the first. (Counting the rows to put a line
            // between them made a long list, a vault of 300, many times slower to draw.)
            VStack(alignment: .leading, spacing: 0) { content.modifier(SettingsGroupRow()) }
                .padding(.horizontal, Self.slack).padding(.bottom, Self.slack)
                .clipped()
                .padding(.horizontal, -Self.slack).padding(.bottom, -Self.slack)
            if let footer {
                Text(footer).font(.system(size: TextSize.small)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row of a group: as wide as the group, never shorter than a row with a switch, the hairline right above it.
struct SettingsGroupRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: SettingsLook.row, alignment: .leading)
            .padding(.vertical, 5)
            .overlay(alignment: .top) { Divider().offset(y: -1) }
    }
}

/// A row: what it sets on the left, its control at the right edge, where every row's control is. `help` is one short
/// line, only where the name can't say it or the switch is risky.
struct SettingRow<Control: View>: View {
    let title: String
    var help: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: TextSize.body))
                if let help {
                    Text(help).font(.system(size: TextSize.small)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

/// A switch at the right edge of its row.
struct SwitchRow: View {
    @Environment(\.settingsTint) private var tint
    let title: String
    var help: String? = nil
    let isOn: Binding<Bool>

    var body: some View {
        SettingRow(title: title, help: help) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(tint)
        }
    }
}

/// A switch bound to a boolean setting.
struct SettingToggle: View, SettingControl {
    @Environment(PetalApp.self) private var app
    let key: String
    let title: String
    var detail: String? = nil

    var body: some View {
        let _ = BodyCount.hit("SettingToggle")
        SwitchRow(title: title, help: detail, isOn: Binding(get: { app.config.bool(key) }, set: { app.config.set(key, $0) }))
    }
}

/// A slider bound to a number: its label in the labels' column, its value in tabular digits at the right edge.
struct SettingSlider: View, SettingControl {
    @Environment(PetalApp.self) private var app
    @Environment(\.settingsTint) private var tint
    let key: String
    let title: String
    let range: ClosedRange<Double>
    var step: Double = 1
    /// Shown as a percentage (a setting kept as 0 to 1).
    var percent = false

    var body: some View {
        let _ = BodyCount.hit("SettingSlider")
        let value = app.config.number(key)
        HStack(spacing: 12) {
            Text(title).font(.system(size: TextSize.body)).frame(width: SettingsLook.label, alignment: .leading)
            Slider(value: Binding(get: { app.config.number(key) },
                                  set: { app.config.set(key, step >= 1 ? Double(Int($0)) : ($0 * 100).rounded() / 100) }),
                   in: range, step: step) { Text(title) }
                .labelsHidden()
                .tint(tint)
            Text(percent ? "\(Int((value * 100).rounded()))%" : String(Int(value)))
                .font(.system(size: TextSize.callout).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: SettingsLook.value, alignment: .trailing)
        }
    }
}

/// A color, or none: the well at the right edge, Clear beside it while one is set.
struct ColorSetting: View, SettingControl {
    @Environment(PetalApp.self) private var app
    let key: String
    let title: String

    var body: some View {
        SettingRow(title: title) {
            if !app.config.string(key).isEmpty {
                Button("Clear") { app.config.set(key, "") }.buttonStyle(.plain)
                    .font(.system(size: TextSize.callout)).foregroundStyle(.secondary)
            }
            ColorPicker(title, selection: Binding(get: { Color(nsColor: NSColor(hex: app.config.string(key)) ?? .clear) },
                                                  set: { app.config.set(key, NSColor($0).hex) }), supportsOpacity: false)
                .labelsHidden()
        }
    }
}

/// One of a few, side by side (or, where their words are long, in a menu), at the right edge of its row.
struct ChoiceRow: View {
    let title: String
    var help: String? = nil
    let options: [(String, String)]
    let selection: Binding<String>
    var menu = false

    var body: some View {
        SettingRow(title: title, help: help) {
            let picker = Picker(title, selection: selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            if menu { picker.pickerStyle(.menu).fixedSize() } else { picker.pickerStyle(.segmented).fixedSize() }
        }
    }
}

/// A filled button in Petal's accent: the one thing to do next (Allow…, Import, Restart to update).
struct AccentButton: View {
    @Environment(PetalApp.self) private var app
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action).buttonStyle(.glassProminent).tint(Color(nsColor: app.accent))
    }
}

/// A choice shown as a picture: a round mark under it, filled with a check on the one chosen.
struct ChosenMark: View {
    let on: Bool
    var color: Color

    var body: some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.system(size: TextSize.subtitle))
            .foregroundStyle(on ? AnyShapeStyle(color) : AnyShapeStyle(.tertiary))
    }
}

// MARK: - The list of settings

/// A row's own control, bound to one setting by its key: its title is written once, on the control, and read from it.
@MainActor
protocol SettingControl: View {
    var key: String { get }
    var title: String { get }
}

/// One row of the settings window, defined once: its page shows it, and the ask bar finds it by its title and a few
/// more words.
@MainActor
struct SettingsEntry: Identifiable {
    let id: String
    let title: String
    /// Whether it shows now (a row that only means something while another is on).
    let when: (PetalApp) -> Bool
    let view: AnyView
    /// What the ask bar's words are looked for in, lowercased.
    let found: String

    /// A setting's own control.
    init<Control: SettingControl>(_ control: Control, words: String = "", when: @escaping (PetalApp) -> Bool = { _ in true }) {
        id = control.key
        title = control.title
        self.when = when
        view = AnyView(control)
        found = (control.title + " " + words).lowercased()
    }

    /// Any other row: built with its title, so the title is written once.
    init<Row: View>(_ id: String, _ title: String, words: String = "", when: @escaping (PetalApp) -> Bool = { _ in true },
                    @ViewBuilder row: (String) -> Row) {
        self.id = id
        self.title = title
        self.when = when
        view = AnyView(row(title))
        found = (title + " " + words).lowercased()
    }
}

/// A group of rows on a page.
@MainActor
struct SettingsBlock: Identifiable {
    let id: String
    let title: String?
    /// The one line under the rows, if the group has one now.
    let footer: (PetalApp) -> String?
    let when: (PetalApp) -> Bool
    let entries: [SettingsEntry]

    /// `footer` always shows; `says` is a footer that depends on what's chosen.
    init(_ title: String, footer: String? = nil, says: ((PetalApp) -> String?)? = nil, when: @escaping (PetalApp) -> Bool = { _ in true },
         _ entries: [SettingsEntry]) {
        id = title
        self.title = title
        self.footer = says ?? { _ in footer }
        self.when = when
        self.entries = entries
    }

    /// A group with no label: a page's first rows.
    init(footer: String? = nil, when: @escaping (PetalApp) -> Bool = { _ in true }, _ entries: [SettingsEntry]) {
        id = entries.first?.id ?? ""
        title = nil
        self.footer = { _ in footer }
        self.when = when
        self.entries = entries
    }
}

/// A page's groups, drawn: each block that shows now, with the rows that show now (`whatever`: every one of them,
/// for a snapshot of rows a setting hides).
struct SettingsBlocks: View {
    @Environment(PetalApp.self) private var app
    let blocks: [SettingsBlock]
    var whatever = false

    var body: some View {
        let _ = BodyCount.hit("SettingsBlocks")
        ForEach(blocks.filter { whatever || $0.when(app) }) { block in
            SettingsGroup(title: block.title, footer: block.footer(app)) {
                ForEach(block.entries.filter { whatever || $0.when(app) }) { $0.view }
            }
        }
    }
}

/// Every page's rows, and the ask bar's search over them.
@MainActor
enum SettingsList {
    /// A page's groups. The vault is its own view (`VaultSettings`): its name finds it.
    static func blocks(_ section: SettingsSection) -> [SettingsBlock] {
        switch section {
        case .dock: dock
        case .look: look
        case .notes: notes
        case .ai: ai
        case .vault: []
        case .routines: routines
        case .privacy: privacy
        case .about: about
        }
    }

    /// What typed text searches for: its words, lowercased, once there are two letters; nil while there's nothing to
    /// look for.
    static func query(_ text: String) -> String? {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count >= 2 ? words : nil
    }

    struct Hit: Identifiable {
        let section: SettingsSection
        let entries: [SettingsEntry]
        var id: String { section.rawValue }
    }

    /// What the ask bar found: on each page, the rows that hold every word of `query` in their title, their extra
    /// words, their group's label or their page's name ("hide dock" finds Dock's Auto-hide); and a page whose own name
    /// or words hold them, with or without rows.
    static func find(_ query: String, app: PetalApp) -> [Hit] {
        let words = query.split(separator: " ")
        func holds(_ text: String) -> Bool { words.allSatisfy { text.contains($0) } }
        return SettingsSection.allCases.compactMap { section in
            let page = section.title.lowercased() + " "
            let entries = blocks(section).filter { $0.when(app) }.flatMap { block in
                let label = (block.title ?? "").lowercased() + " "
                // The page's name counts only beside the row's own words: "dock" alone isn't every row of Dock.
                return block.entries.filter { entry in
                    let own = label + entry.found
                    return entry.when(app) && words.contains(where: { own.contains($0) }) && holds(page + own)
                }
            }
            let named = holds((section.title + " " + section.words).lowercased())
            return entries.isEmpty && !named ? nil : Hit(section: section, entries: entries)
        }
    }
}

// MARK: - The notes for Petal AI

struct InstructionsEditor: View {
    @Environment(PetalApp.self) private var app
    @State private var text = ""
    /// The notes' `version` the editor's text was last given: typing goes with it, so typing over text the editor no
    /// longer holds is never written over the file.
    @State private var shown = 0

    var body: some View {
        let notes = app.instructions
        VStack(alignment: .leading, spacing: 6) {
            editor(notes)
            // Only when the file changed elsewhere while the person had typing not yet written: neither is dropped
            // until they pick.
            if notes.changedElsewhere {
                HStack(spacing: 8) {
                    Text("This changed somewhere else while you were typing.").font(.system(size: TextSize.callout)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Use that version") { notes.useTheirs() }
                    Button("Keep mine") { notes.keepMine() }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
    }

    private func editor(_ notes: InstructionsText) -> some View {
        TextEditor(text: $text)
            .font(.system(size: TextSize.callout))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 110)
            .padding(8)
            // The field is clear glass of its own on the window's glass, as the ask bar is.
            .glassEffect(.clear, in: .rect(cornerRadius: Radius.tile))
            // Nothing to type over until the file was first read: typing onto an empty editor while the notes are
            // still on their way would be lost, or write over them. It's empty until then, so it looks no different.
            .disabled(!notes.loaded)
            // As last read off the main thread; read again as it appears, and while it shows, a change made elsewhere
            // (an agent, an editor) comes in within a second.
            .onAppear {
                shown = notes.version
                text = notes.text
                notes.watch(true)
                notes.refresh()
            }
            .onDisappear { notes.watch(false) }
            .onChange(of: notes.version) { _, new in
                shown = new
                if text != notes.text { text = notes.text }
            }
            .onChange(of: text) { _, new in notes.typed(new, basedOn: shown) }
    }
}

/// The notes for the AI as the settings window shows them: what the editor is given, from the notes' one state
/// (`InstructionsStore`, on its own queue). Typing, picks and the watcher's looks go to that queue in order; what comes
/// back is shown only once it has taken every key sent, so a key on its way is never undone.
@MainActor @Observable
final class InstructionsText {
    /// What the editor holds: as last given, or typed since.
    @ObservationIgnored private(set) var text = ""
    /// Counts the times the editor is given text it didn't type (the file read, a pick, a draft kept from before).
    private(set) var version = 0
    /// Whether the file was read once: until then the editor takes no typing.
    private(set) var loaded = false
    /// The conflict the line under the editor answers: the file changed elsewhere while the typing wasn't written.
    private(set) var conflict: Int?
    var changedElsewhere: Bool { conflict != nil }
    /// Keys sent to the queue: what comes back before it took the last one isn't shown.
    @ObservationIgnored private var sent = 0
    /// Editors showing the notes: while any does, the file is watched.
    @ObservationIgnored private var watchers = 0
    nonisolated private static let store = InstructionsStore(file: Config.folder.appending(path: "instructions.md"),
                                                             draft: Config.folder.appending(path: "instructions.draft.md"))

    /// Reads the file (off the main thread, unless `wait`).
    func refresh(wait: Bool = false) { send(wait: wait) { $0.refresh(ifChanged: false) } }

    /// The editor's text changed: typed over what it was given at `basedOn` (its `version`).
    func typed(_ new: String, basedOn: Int) {
        guard loaded, new != text else { return }
        text = new
        sent += 1
        let seq = sent, now = Date().timeIntervalSinceReferenceDate
        send { $0.typed(new, basedOn: basedOn, now: now, seq: seq) }
    }

    /// "Use theirs": the file as it is now comes into the editor; the typing not yet written is dropped.
    func useTheirs() {
        guard conflict != nil else { return }
        send { $0.useTheirs() }
    }

    /// "Keep mine": what's in the editor is written over the change the person saw.
    func keepMine() {
        guard let conflict else { return }
        send { $0.keepMine(conflict) }
    }

    /// Snapshots: the editor as it is when the file changed elsewhere while the person typed (false: as before).
    func preview(changedElsewhere: Bool) { conflict = changedElsewhere ? 0 : nil }

    /// Waits for the notes' reads and writes to finish (on quit): an edit made just before, and the draft of a
    /// conflict not picked yet, are on disk.
    nonisolated static func flush() { InstructionsStore.queue.sync {} }

    /// An editor showing the notes appeared (true) or went (false).
    func watch(_ on: Bool) { watchers = max(0, watchers + (on ? 1 : -1)) }

    /// Each second (Config's watcher): while an editor shows the notes, a change made elsewhere is read.
    func tick() {
        guard watchers > 0 else { return }
        send { $0.refresh(ifChanged: true) }
    }

    private func send(wait: Bool = false, _ job: @escaping @Sendable (InstructionsStore) -> InstructionsStore.Shown?) {
        let store = Self.store
        if wait {
            if let shown = InstructionsStore.queue.sync(execute: { job(store) }) { apply(shown) }
            return
        }
        InstructionsStore.queue.async {
            guard let shown = job(store) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(shown) } }
        }
    }

    private func apply(_ shown: InstructionsStore.Shown) {
        // Keys still on their way: the answer to the last one shows them.
        guard shown.through == sent else { return }
        if shown.loaded != loaded { loaded = shown.loaded }
        if shown.conflict != conflict { conflict = shown.conflict }
        text = shown.text
        if shown.version != version { version = shown.version }
    }
}

/// The notes' one state (`NotesState`), owned by one serial queue: reading the file, typing, writing, the person's
/// picks and the watcher's looks all go through it in order, each write's answer taken at once, so none crosses
/// another. After every step the draft file beside the notes follows the state: it holds the draft while a conflict
/// is unresolved (so quitting loses neither side, and the next launch shows the line again), and is gone otherwise.
final class InstructionsStore: @unchecked Sendable {
    static let queue = DispatchQueue(label: "petal.instructions", qos: .userInitiated)

    /// What the editor is given after a step; `through` counts the keys taken so far.
    struct Shown: Sendable {
        var text: String
        var version: Int
        var loaded: Bool
        var conflict: Int?
        var through: Int
    }

    private let file: URL
    private let draftFile: URL
    // Only touched on `queue`.
    private var state = NotesState()
    private var through = 0
    private var draftOnDisk: String?

    init(file: URL, draft: URL) {
        self.file = file
        draftFile = draft
    }

    /// Reads the file, and the first time the draft kept beside it. `ifChanged`: only once its modification date moved.
    func refresh(ifChanged: Bool) -> Shown? {
        let now = Date().timeIntervalSinceReferenceDate
        if !state.loaded {
            let saved = try? String(contentsOf: draftFile, encoding: .utf8)
            draftOnDisk = saved
            run(.opened(read(), saved: saved, now: now))
        } else {
            if ifChanged, Self.modified(file) == state.stamp { return nil }
            run(.read(read(), now: now))
        }
        return shown
    }

    func typed(_ text: String, basedOn: Int, now: Double, seq: Int) -> Shown {
        through = seq
        run(.typed(text, basedOn: basedOn, now: now))
        return shown
    }

    func keepMine(_ conflict: Int) -> Shown {
        run(.keepMine(conflict: conflict))
        return shown
    }

    func useTheirs() -> Shown {
        run(.useTheirs(read()))
        return shown
    }

    private var shown: Shown {
        Shown(text: state.draft, version: state.shown, loaded: state.loaded, conflict: state.conflictShown, through: through)
    }

    /// One step, and the write it asks for done at once, its answer the next step.
    private func run(_ event: NotesEvent) {
        var next: NotesEvent? = event
        while let step = next { next = NotesSteps.step(&state, step).map(write) }
        keepDraft()
    }

    /// Writes only while the file holds what the write builds on: a change made elsewhere is kept, and said. The new
    /// text is written beside the file and swapped in at once (`RENAME_SWAP`), so what was in place at that very
    /// moment comes back: a save made elsewhere between the check and the swap is put back and said too, never lost.
    private func write(_ asked: NotesWrite) -> NotesEvent {
        let refused = { (now: String) in
            NotesEvent.wrote(generation: asked.generation, ok: false, NotesDisk(stamp: Self.modified(self.file), text: now))
        }
        let now = Self.contents(file)
        guard now == asked.over else { return refused(now) }
        // Through a link to the file it names (made if it isn't there yet): the link stays, as the person set it.
        let target = Self.linked(file)
        let fm = FileManager.default
        let existing = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
        let temp = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temp) }
        // Private from the start, then the file's own permissions: a private file stays private.
        guard fm.createFile(atPath: temp.path, contents: Data(asked.text.utf8), attributes: [.posixPermissions: 0o600]) else { return refused(now) }
        if let existing { try? fm.setAttributes([.posixPermissions: existing], ofItemAtPath: temp.path) }
        if existing != nil {
            guard renamex_np(temp.path, target.path, UInt32(RENAME_SWAP)) == 0 else { return refused(now) }
            let displaced = Self.contents(temp)
            if displaced != asked.over {
                // Saved elsewhere in between: that version goes back in place, and the person is asked.
                _ = renamex_np(temp.path, target.path, UInt32(RENAME_SWAP))
                return refused(displaced)
            }
        } else {
            // No file yet: only if none appeared meanwhile.
            guard renamex_np(temp.path, target.path, UInt32(RENAME_EXCL)) == 0 else { return refused(Self.contents(file)) }
        }
        return .wrote(generation: asked.generation, ok: true, NotesDisk(stamp: Self.modified(file), text: asked.text))
    }

    /// The file a path names, following links (a few deep), whether or not that file is there yet.
    private static func linked(_ url: URL) -> URL {
        var url = url
        for _ in 0..<8 {
            guard let next = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { break }
            url = URL(fileURLWithPath: next, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        }
        return url
    }

    private func keepDraft() {
        let want = state.draftFile
        guard want != draftOnDisk else { return }
        if let want {
            // Private, as the notes it holds may be.
            guard (try? want.write(to: draftFile, atomically: true, encoding: .utf8)) != nil else { return }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: draftFile.path)
        } else {
            try? FileManager.default.removeItem(at: draftFile)
        }
        draftOnDisk = want
    }

    private func read() -> NotesDisk { NotesDisk(stamp: Self.modified(file), text: Self.contents(file)) }

    /// The date of the file the notes are in (through a link, its target's: the link's own never changes).
    private static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: linked(file).path))?[.modificationDate] as? Date
    }

    private static func contents(_ file: URL) -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }
}
