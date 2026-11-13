import AppKit
import Combine
import SwiftUI

// The settings window's pages: each one's groups and rows, written once (`SettingsList`) for the page and for the
// ask bar's search, and the views those rows are made of. The vault's, the routines' and the API keys' rows are with
// their own code (VaultViews.swift, Routines.swift, APIKeys.swift); windows and shortcuts are in SettingsExtras.swift.

/// A row that needs Petal itself to draw.
struct WithApp<Content: View>: View {
    @Environment(PetalApp.self) private var app
    @ViewBuilder let content: (PetalApp) -> Content

    var body: some View { content(app) }
}

// MARK: - Dock

extension SettingsList {
    static let dock: [SettingsBlock] = [
        SettingsBlock(footer: "Quitting or removing Petal brings your Dock back as it was.", [
            SettingsEntry("dock", "Which dock", words: "petal macos apple own switch") { _ in DockChoices() },
        ]),
        SettingsBlock("Where it sits", [
            SettingsEntry("position", "Position", words: "bottom left right side edge") { title in
                WithApp { app in
                    ChoiceRow(title: title, options: [("bottom", "Bottom"), ("left", "Left"), ("right", "Right")],
                              selection: Binding(get: { app.config.position }, set: { app.config.setDock("position", $0) }))
                }
            },
            SettingsEntry("autoHide", "Auto-hide", words: "hide") { title in
                WithApp { app in
                    SwitchRow(title: title, isOn: Binding(get: { app.config.autoHide }, set: { app.config.setDock("autoHide", $0) }))
                }
            },
            SettingsEntry("keepWindowsClear", "Keep windows clear of the dock", words: "under overlap", when: { !$0.config.autoHide }) { title in
                WithApp { app in
                    SwitchRow(title: title, help: "Windows end above the dock instead of running under it.",
                              isOn: Binding(get: { app.config.keepWindowsClear }, set: { app.config.setDock("keepWindowsClear", $0) }))
                }
            },
            SettingsEntry("openAtLogin", "Open Petal at login", words: "start launch") { title in
                WithApp { app in SwitchRow(title: title, isOn: Binding(get: { app.openAtLogin }, set: { app.openAtLogin = $0 })) }
            },
            SettingsEntry(SettingToggle(key: "menuBarIcon", title: "Petal in the menu bar"), words: "icon mark"),
        ]),
        SettingsBlock("Apps", [
            SettingsEntry(SettingToggle(key: "thisWorkspaceOnly", title: "Only this Desktop’s apps"), words: "space workspace running"),
            SettingsEntry(SettingToggle(key: "previews", title: "Window previews"), words: "hover thumbnails"),
            SettingsEntry(SettingToggle(key: "minimized", title: "Minimized windows")),
            SettingsEntry(SettingToggle(key: "badges", title: "Badges"), words: "unread counts notifications"),
            SettingsEntry(SettingToggle(key: "bounce", title: "Bounce"), words: "attention"),
            SettingsEntry(SettingToggle(key: "progress", title: "Download progress")),
            SettingsEntry(SettingToggle(key: "dropToOpen", title: "Drop files on an app to open them")),
        ]),
        SettingsBlock("Right-click menu", [
            SettingsEntry(SettingToggle(key: "quickActions", title: "Quick actions")),
            SettingsEntry(SettingToggle(key: "recentFiles", title: "Recent files")),
        ]),
        SettingsBlock("Extras", [
            SettingsEntry(SettingToggle(key: "nowPlaying", title: "Now playing"), words: "music spotify song album"),
            SettingsEntry(SettingToggle(key: "stacks", title: "Folder stacks"), words: "downloads"),
            SettingsEntry("stackFolders", "Add a folder", words: "stacks folders downloads", when: { $0.config.bool("stacks") }) { StackFolders(title: $0) },
            SettingsEntry(SettingToggle(key: "trash", title: "Trash")),
        ]),
        windows,
        shortcuts,
        SettingsBlock("Bring your Dock along", footer: "Replaces Petal’s apps with your Dock’s. macOS’s Dock doesn’t change.", [
            SettingsEntry("importDock", "Import macOS’s Dock", words: "apps folders stacks") { _ in ImportDock() },
        ]),
    ]
}

/// Which dock: Petal's, or macOS's own, each as a small drawing of itself with its own apps.
struct DockChoices: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        let _ = BodyCount.hit("DockSettings")
        HStack(spacing: 12) {
            DockChoice(title: "Petal", selected: app.config.whichDock == "petal") {
                PetalDockSketch()
            } choose: { app.useDock("petal") }
            DockChoice(title: "macOS Dock", selected: app.config.whichDock == "macos") {
                MacDockSketch()
            } choose: { app.useDock("macos") }
        }
    }
}

struct DockChoice<Sketch: View>: View {
    @Environment(PetalApp.self) private var app
    let title: String
    let selected: Bool
    @ViewBuilder var sketch: Sketch
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 12) {
                sketch.frame(height: 36)
                HStack(spacing: 6) {
                    ChosenMark(on: selected, color: Color(nsColor: app.accent))
                    Text(title).font(.system(size: TextSize.body, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(.rect)
            .glassEffect(hovering ? .clear.interactive() : .identity, in: .rect(cornerRadius: Radius.tile))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A small drawing of Petal's dock, with its own apps.
struct PetalDockSketch: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        HStack(spacing: 5) {
            if let provider = app.chatProvider {
                ProviderMark(provider: provider).foregroundStyle(.primary.opacity(0.9))
                    .frame(width: 12, height: 12).frame(width: 22, height: 22)
                    .glassEffect(.clear, in: .circle)
            }
            ForEach(app.config.apps.filter(Apps.shows).prefix(7), id: \.self) { id in
                DockIcon(id: id, size: 22)
            }
        }
        .padding(6)
        .frame(minWidth: 46, minHeight: 34)
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
            Rectangle().fill(.primary.opacity(0.3)).frame(width: 1, height: 18)
            Image(nsImage: NSWorkspace.shared.icon(forFile: Stacks.trash.path)).resizable().frame(width: 22, height: 22)
        }
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.control))
    }
}

/// The folders shown as stacks, each with a way out, and a way to add one.
struct StackFolders: View {
    @Environment(PetalApp.self) private var app
    let title: String

    var body: some View {
        let folders = app.config.strings("stackFolders")
        ForEach(folders, id: \.self) { folder in
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Stacks.url(folder).path)).resizable().frame(width: 20, height: 20)
                Text(folder).font(.system(size: TextSize.body)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                RoundButton(symbol: "xmark") { app.config.set("stackFolders", app.config.strings("stackFolders").filter { $0 != folder }) }
            }
        }
        SettingRow(title: title) {
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let home = NSHomeDirectory()
                let path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
                app.config.set("stackFolders", app.config.strings("stackFolders") + [path])
            }
            .buttonStyle(.glass)
        }
    }
}

/// macOS's Dock's apps, and the button that makes them Petal's.
struct ImportDock: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: -6) {
                ForEach(app.systemDockApps.prefix(9), id: \.self) { id in
                    Image(nsImage: Apps.icon(id)).resizable().frame(width: 30, height: 30)
                }
            }
            Spacer(minLength: 12)
            AccentButton(title: "Import Dock") { app.config.importSystemDock() }
        }
    }
}

// MARK: - Look

extension SettingsList {
    static let look: [SettingsBlock] = [
        SettingsBlock("Icons", [
            SettingsEntry(SettingSlider(key: "iconSize", title: "Size", range: 24...72), words: "icon bigger smaller"),
            SettingsEntry(SettingSlider(key: "idleOpacity", title: "Apps not running", range: 0.2...1, step: 0.05, percent: true), words: "opacity dim faded"),
            SettingsEntry(SettingToggle(key: "appGlow", title: "Glow"), words: "running color"),
            SettingsEntry(SettingToggle(key: "separators", title: "Dividers"), words: "separators sections"),
        ]),
        SettingsBlock("Under the pointer", [
            SettingsEntry(SettingToggle(key: "magnification", title: "Magnification"), words: "grow zoom bigger"),
            SettingsEntry(SettingSlider(key: "magnificationAmount", title: "Grow", range: 0.1...1, step: 0.05, percent: true),
                          words: "magnification", when: { $0.config.bool("magnification") }),
            SettingsEntry(SettingToggle(key: "hoverLift", title: "Lift on hover"), when: { !$0.config.bool("magnification") }),
            SettingsEntry(SettingSlider(key: "hoverLiftAmount", title: "Lift", range: 0...0.3, step: 0.01, percent: true),
                          when: { !$0.config.bool("magnification") }),
            SettingsEntry(SettingToggle(key: "tooltips", title: "Names on hover"), words: "tooltips labels"),
        ]),
        SettingsBlock("Color", [
            SettingsEntry(ColorSetting(key: "dockColor", title: "Dock tint"), words: "glass"),
            SettingsEntry(ColorSetting(key: "accentColor", title: "Accent"), words: "pink dots buttons"),
            SettingsEntry(ColorSetting(key: "pointerColor", title: "Petal AI’s pointer"), words: "cursor arrow"),
        ]),
    ]
}

/// Look: the dock itself stays in view, where it sits on the screen (along the bottom, or down a side), and what's
/// under it scrolls.
struct LookPage: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        let _ = BodyCount.hit("LookSettings")
        let position = app.config.position
        HStack(spacing: 0) {
            if position == "left" { LiveDock().frame(width: LiveDock.room) }
            VStack(spacing: 0) {
                PageTitle(text: SettingsSection.look.title)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: SettingsLook.column)
                    .frame(maxWidth: .infinity)
                if position == "bottom" { LiveDock().frame(height: LiveDock.room).padding(.bottom, 10) } else { Color.clear.frame(height: SettingsLook.between) }
                PageScroll { SettingsBlocks(blocks: SettingsList.look) }
            }
            if position == "right" { LiveDock().frame(width: LiveDock.room) }
        }
    }
}

/// The dock as it looks now: the dock's own view with the person's own apps, drawn again at once as a setting
/// changes. It is `DockView` as `Petal --snapshot` draws it: its slots without their mouse, so nothing here opens an
/// app, a preview or a menu. Under the pointer it magnifies as the dock does (the dock's own `Magnifier`, given the
/// pointer by this view); at rest, with magnification on, it shows it at its middle app. Which apps have a dot is
/// made up (every third, the first in front), so every setting has something to show.
struct LiveDock: View {
    @Environment(PetalApp.self) private var app
    @State private var dock = ScreenDock()
    /// The room along the dock, once laid out.
    @State private var length: CGFloat = SettingsLook.column
    @State private var hovering = false
    /// The room it keeps across the dock: the dock rests on its screen-edge side, and icons that grow past it (large
    /// icons, magnified) rise over what's beside it, so nothing under the pointer moves while a slider is dragged.
    static let room: CGFloat = 112

    /// What the dock here shows, and how thick it is.
    struct Plan: Equatable {
        var ids: [String]
        var icon: CGFloat
        var thickness: CGFloat
    }

    var body: some View {
        let _ = BodyCount.hit("LiveDock")
        let position = app.config.position
        let vertical = position != "bottom"
        let plan = Self.plan(app, length: length)
        let magnify = Magnify(on: Magnifier.enabled, amount: Magnifier.amount, plan: plan, length: length)
        let _ = Self.show(plan, in: dock)
        DockView(dock: dock)
            .environment(\.snapshotting, true)
            .frame(width: vertical ? plan.thickness : nil, height: vertical ? nil : plan.thickness)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: position == "left" ? .leading : position == "right" ? .trailing : .bottom)
            .contentShape(.rect)
            .onGeometryChange(for: CGFloat.self) { vertical ? $0.size.height : $0.size.width } action: { length = $0 }
            .onContinuousHover(coordinateSpace: .global) { phase in
                guard Magnifier.enabled else { return }
                switch phase {
                case .active(let point):
                    let along = vertical ? point.y : point.x
                    if hovering { dock.magnifier.preview(pointer: along) } else {
                        hovering = true
                        withAnimation(.easeOut(duration: 0.12)) { dock.magnifier.preview(pointer: along) }
                    }
                case .ended:
                    hovering = false
                    withAnimation(.easeOut(duration: 0.2)) { rest() }
                }
            }
            // Magnification turned on, or grown: shown at the middle app, once the slots know where they are.
            .task(id: magnify) {
                guard magnify.on, !hovering else { return }
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(.easeOut(duration: 0.2)) { rest() }
            }
            .accessibilityElement()
            .accessibilityLabel("Your dock, as it looks now")
    }

    private struct Magnify: Equatable {
        var on: Bool
        var amount: CGFloat
        var plan: Plan
        var length: CGFloat
    }

    /// Magnified at the middle app, as if the pointer rested there.
    private func rest() {
        guard Magnifier.enabled, !dock.items.isEmpty else { return }
        let middle = dock.items[dock.items.count / 2].id
        guard let frame = dock.magnifier.frames[middle]?.rect else { return }
        dock.magnifier.preview(pointer: app.config.position == "bottom" ? frame.midX : frame.midY)
    }

    /// The person's apps, as many as fit along `length` at the size the setting asks (the real dock shrinks its icons
    /// to fit the screen instead; here the size shown is the size set).
    static func plan(_ app: PetalApp, length: CGFloat) -> Plan {
        let config = app.config
        let icon = max(16, config.number("iconSize"))
        let slot = icon + (config.number("iconPadding") >= 0 ? config.number("iconPadding") : 5) * 2
        let outer = DockView.outer(config, icon: icon)
        let vertical = config.position != "bottom"
        let thickness = slot + 8 + (vertical ? outer.leading + outer.trailing : outer.top + outer.bottom)
        // What the dock holds besides its apps, as DockView counts it: Petal's buttons, "+", the extras, the dividers.
        let buttons = [!app.providers.isEmpty && (config.bool("ai") || config.bool("claudeUsage")), config.bool("finderInDock"),
                       config.bool("notes") && config.bool("notesPad")].filter { $0 }.count
        let extras = (config.bool("stacks") ? stackCount(config.strings("stackFolders")) : 0) + (config.bool("trash") ? 1 : 0)
            + (config.bool("nowPlaying") && app.signals.nowPlaying != nil ? 1 : 0)
        let fixed = CGFloat(buttons + extras + 1) * slot + CGFloat((buttons > 0 ? 1 : 0) + (extras > 0 ? 1 : 0)) * 17 + 8
            + (vertical ? outer.top + outer.bottom : outer.leading + outer.trailing)
        let fits = Int(((length - fixed) / slot).rounded(.down))
        var ids = config.apps.filter(Apps.shows)
        if ids.isEmpty {
            // An empty dock shows the apps that are open; a headless run (a snapshot, a bench), a few every Mac has.
            ids = Headless.on ? ["com.apple.Safari", "com.apple.mail", "com.apple.Notes", "com.apple.iCal", "com.apple.Music"].filter { Apps.url($0) != nil }
                : NSWorkspace.shared.personsApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier)
        }
        return Plan(ids: Array(ids.prefix(max(1, min(7, fits)))), icon: icon, thickness: thickness)
    }

    /// How many of the stacks' folders exist, asked of the disk once for each list of folders, never on every
    /// drawing: a slider dragged on this page draws many times a second, and a folder on a slow disk would hold
    /// each one up.
    private static var stacksKnown: (folders: [String], count: Int)?
    private static func stackCount(_ folders: [String]) -> Int {
        if let known = stacksKnown, known.folders == folders { return known.count }
        let count = Stacks.resolve(folders).count
        stacksKnown = (folders, count)
        return count
    }

    /// Gives the dock its apps and size, only where they changed.
    @discardableResult
    static func show(_ plan: Plan, in dock: ScreenDock) -> Bool {
        if dock.icon != plan.icon { dock.icon = plan.icon }
        guard dock.items.map(\.id) != plan.ids else { return false }
        dock.desktop = 1
        dock.items = plan.ids.enumerated().map { index, id in
            DockItem(id: id, pinned: true, running: index % 3 == 0, windows: index % 3 == 0 ? 1 : 0, here: true, active: index == 0)
        }
        dock.stageSlots = dock.items.count + 1
        return true
    }
}

// MARK: - Notes

extension SettingsList {
    private static let notesOn: (PetalApp) -> Bool = { $0.config.bool("notes") }

    static let notes: [SettingsBlock] = [
        SettingsBlock([
            SettingsEntry(SettingToggle(key: "notes", title: "Petal Notes"), words: "sticky paper"),
            SettingsEntry(SettingToggle(key: "notesPad", title: "Note pad in the dock"), words: "new note", when: notesOn),
        ]),
        SettingsBlock("Look", when: notesOn, [
            SettingsEntry("notesLook", "Paper or Liquid Glass", words: "notes look") { _ in NotesLookChoice() },
        ]),
        SettingsBlock("Notebooks", when: notesOn, [
            SettingsEntry("notesNotebook", "New notes go to", words: "default notebook inbox color") { DefaultNotebookRow(title: $0) },
            SettingsEntry("notesFolder", "Kept in", words: "folder icloud drive files markdown finder") { NotesFolderRow(title: $0) },
        ]),
    ]
}

/// How notes look, picked by clicking one: two little papers drawn by the notes' own view (`PaperView`), one on paper
/// and one on Liquid Glass, in the default notebook's color, each saying which it is.
struct NotesLookChoice: View {
    @Environment(PetalApp.self) private var app
    static let side: CGFloat = 128

    var body: some View {
        let chosen = app.config.string("notesLook") == "glass" ? "glass" : "paper"
        let book = app.paper.defaultNotebook
        let color = app.paper.store.color(of: book)
        HStack(spacing: 28) {
            ForEach([("paper", "Paper"), ("glass", "Liquid Glass")], id: \.0) { id, name in
                Button { app.config.set("notesLook", id) } label: {
                    VStack(spacing: 10) {
                        PaperView(paper: Self.sample(name, in: book), color: color, glass: id == "glass", face: .folded,
                                  place: "Petal Notes", notebook: book, others: "", footer: "")
                            .allowsHitTesting(false)
                            .scaleEffect(Self.side / PaperLook.folded)
                            .frame(width: Self.side, height: Self.side)
                        ChosenMark(on: chosen == id, color: Color(nsColor: color))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityAddTraits(chosen == id ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    /// A note that says which look it shows: it is never saved anywhere.
    private static func sample(_ words: String, in book: String) -> PaperNote {
        PaperNote(file: NoteFile(id: "settings-look-" + words, created: Date(timeIntervalSinceReferenceDate: 0), body: "# " + words),
                  url: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: words + ".md"), notebook: book)
    }
}

/// The notebook new notes go to, with its color.
struct DefaultNotebookRow: View {
    @Environment(PetalApp.self) private var app
    let title: String

    var body: some View {
        let book = app.paper.defaultNotebook
        SettingRow(title: title) {
            Circle().fill(Color(nsColor: app.paper.store.color(of: book))).frame(width: 10, height: 10)
            Picker(title, selection: Binding(get: { book }, set: { app.config.set("notesNotebook", $0) })) {
                ForEach(Array(Set(app.paper.store.notebooks.map(\.name) + [book])).sorted(), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }
}

/// Where the notes' files are.
struct NotesFolderRow: View {
    @Environment(PetalApp.self) private var app
    let title: String

    var body: some View {
        let store = app.paper.store
        SettingRow(title: title, help: store.inICloud ? "iCloud Drive › Petal Notes" : (store.root.path as NSString).abbreviatingWithTildeInPath) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.root]) }.buttonStyle(.glass)
        }
    }
}

// MARK: - Petal AI

extension SettingsList {
    private static let hasAI: (PetalApp) -> Bool = { $0.chatProvider != nil }

    /// Using the person's apps, and where a run's windows open: on their screen, or on a hidden display of its own.
    static let usingApps = SettingsBlock("Using your apps", when: hasAI, [
        SettingsEntry(SettingToggle(key: "computerUse", title: "Let Petal AI use your apps", detail: "It asks before each app, and Stop or Esc ends it."),
                      words: "computer use press type click pointer"),
        SettingsEntry("runDisplays", "Give each run a display of its own", words: "hidden display background screen") { RunDisplaysRow(title: $0) },
    ])

    static let ai: [SettingsBlock] = [
        SettingsBlock("Your AI", [
            SettingsEntry("aiProviders", "Your AI", words: "claude codex anthropic openai chatgpt install sign in none") { _ in
                WithApp { app in ProviderList().onAppear { app.aiSetup.refreshAll() } }
            },
        ]),
        paying,
        SettingsBlock("Usage", when: hasAI, [
            SettingsEntry("usage", "Usage", words: "limits spent cost plan") { _ in UsageRow() },
        ]),
        SettingsBlock("Chat", when: hasAI, [
            SettingsEntry("chatWhileWorking", "Writing while it works", words: "steer queue interrupt") { title in
                WithApp { app in
                    ChoiceRow(title: title, options: [("steer", "Steers it"), ("queue", "Waits its turn")],
                              selection: Binding(get: { app.config.string("chatWhileWorking") }, set: { app.config.set("chatWhileWorking", $0) }))
                }
            },
            SettingsEntry("chatProvider", "Chat with", words: "claude codex", when: { $0.providers.count > 1 }) { title in
                WithApp { app in
                    ChoiceRow(title: title, options: app.providers.map { ($0.rawValue, $0.name) },
                              selection: Binding(get: { app.chatProvider?.rawValue ?? "" }, set: {
                                  app.config.set("chatProvider", $0)
                                  Task { await app.usage.refresh() }
                              }))
                }
            },
            SettingsEntry("chatModel", "Model", words: "haiku sonnet opus fable gpt",
                          when: { app in app.chatProvider.map { app.models(for: $0).count > 1 } ?? false }) { title in
                WithApp { app in
                    if let provider = app.chatProvider {
                        ChoiceRow(title: title, options: app.models(for: provider).map { ($0.0, $0.1) },
                                  selection: Binding(get: { app.currentModel(for: provider) }, set: { app.config.set(provider.modelSetting, $0) }))
                    }
                }
            },
            SettingsEntry("chatEffort", "Effort", words: "thinking reasoning low medium high") { title in
                WithApp { app in
                    if let provider = app.chatProvider {
                        ChoiceRow(title: title, options: app.efforts(for: provider).map { ($0, $0.capitalized) },
                                  selection: Binding(get: { app.config.string(provider.effortSetting) }, set: { app.config.set(provider.effortSetting, $0) }))
                    }
                }
            },
            SettingsEntry("claudeAccess", "Access", words: "permissions full risky ask allow") { title in
                WithApp { app in
                    ChoiceRow(title: title, help: "Full access never asks before a step.",
                              options: [("auto", app.chatProvider == .codex ? "Safe steps only" : "Ask before risky steps"), ("full", "Full access")],
                              selection: Binding(get: { app.config.string("claudeAccess") }, set: { app.config.set("claudeAccess", $0) }), menu: true)
                }
            },
        ]),
        usingApps,
        SettingsBlock("In the background", when: hasAI, [
            SettingsEntry(SettingToggle(key: "ai", title: "Small jobs", detail: "Routines that sort files, and notes’ quick answers."), words: "quick small model"),
            SettingsEntry(SettingToggle(key: "claudeUsage", title: "Usage ring"), words: "ai button limits"),
        ]),
        SettingsBlock("Your notes for Petal AI", when: hasAI, [
            SettingsEntry("instructions", "Your notes for Petal AI", words: "instructions prompt remember always") { _ in InstructionsEditor() },
        ]),
        SettingsBlock("Other AI agents", when: hasAI, [
            SettingsEntry(SettingToggle(key: "otherAgents", title: "Let other AI agents change Petal"),
                          words: "agents sessions claude code codex opencode t3 terminal mcp skill command"),
        ]),
    ]
}

/// Where a run's windows open: on the person's screen, or on a hidden display of its own. Where macOS can't make
/// one, the row says so and its switch stays off.
struct RunDisplaysRow: View {
    @Environment(PetalApp.self) private var app
    let title: String

    var body: some View {
        SwitchRow(title: title, help: RunDisplays.unavailableWords ?? "Its windows open where you don’t see them.",
                  isOn: Binding(get: { app.config.bool("runDisplays") }, set: { app.config.set("runDisplays", $0) }))
            .disabled(RunDisplays.unavailableWords != nil)
    }
}

/// How much of the plan is used (the ring, each limit and when it resets), or, on an API key, what Petal's own runs
/// spent this month.
struct UsageRow: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        if let spent = app.usage.spentText {
            VStack(alignment: .leading, spacing: 2) {
                Text(spent).font(.system(size: TextSize.subtitle, weight: .semibold).monospacedDigit())
                Text(app.chatProvider == .codex ? "Estimated at list prices. OpenAI’s usage page has the bill."
                     : "Petal’s own runs on your key. Anthropic’s console has the bill.")
                    .font(.system(size: TextSize.small)).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 18) {
                UsageRing(usage: app.usage, size: 56)
                VStack(alignment: .leading, spacing: 6) {
                    if app.usage.limits.isEmpty {
                        Text(app.usage.help.isEmpty ? "Checking your usage…" : app.usage.help)
                            .font(.system(size: TextSize.callout)).foregroundStyle(.secondary)
                    }
                    ForEach(app.usage.limits, id: \.label) { limit in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(limit.label).font(.system(size: TextSize.callout, weight: .medium))
                                Spacer()
                                if let reset = limit.resetsAt {
                                    Text("resets \(reset, style: .relative)").font(.system(size: TextSize.small)).foregroundStyle(.secondary)
                                }
                                Text("\(Int(limit.percent * 100))%").font(.system(size: TextSize.callout).monospacedDigit())
                                    .frame(width: SettingsLook.value, alignment: .trailing)
                            }
                            ProgressView(value: limit.percent).tint(UsageRing.color(limit.percent))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Privacy

extension SettingsList {
    static let privacy: [SettingsBlock] = [
        SettingsBlock("Kept private", footer: "Petal AI sees only these apps’ names.", [
            SettingsEntry("aiNeverLook", "Add an app", words: "private apps never look hidden passwords") { PrivateApps(title: $0) },
        ]),
        SettingsBlock("What Petal AI did", [
            SettingsEntry("aiHistory", "What Petal AI did", words: "history undo log") { _ in AIHistory() },
        ]),
        SettingsBlock("Memory", [
            SettingsEntry(SettingToggle(key: "aiMemory", title: "Remember what helps"), words: "memory memories forget"),
            SettingsEntry("memories", "What it remembers", words: "memory memories forget", when: { $0.config.bool("aiMemory") }) { _ in Memories() },
        ]),
        SettingsBlock("Allowed without asking", when: { !$0.config.strings("aiAllowed").isEmpty }, [
            SettingsEntry("aiAllowed", "Allowed without asking", words: "always ask quit close trash") { _ in AllowedList() },
        ]),
        SettingsBlock("What macOS lets Petal see", [
            SettingsEntry("permissions", "Permissions", words: "accessibility screen recording browsers music spotify automation allow") { _ in Permissions() },
        ]),
    ]
}

/// Apps Petal AI never looks into: it gets their name, never their windows, text or a picture of them.
struct PrivateApps: View {
    @Environment(PetalApp.self) private var app
    let title: String

    var body: some View {
        let ids = app.config.strings("aiNeverLook")
        // Only the ones on this Mac are listed: one that isn't installed (the password managers kept private from
        // the start) has no name or icon to show, only its identifier. It stays private all the same.
        ForEach(ids.filter { Apps.url($0) != nil }, id: \.self) { id in
            HStack(spacing: 8) {
                Image(nsImage: Apps.icon(id)).resizable().frame(width: 20, height: 20)
                Text(Apps.name(id)).font(.system(size: TextSize.body))
                Spacer(minLength: 8)
                RoundButton(symbol: "xmark") { app.config.set("aiNeverLook", ids.filter { $0 != id }) }
            }
        }
        SettingRow(title: title) {
            Menu("Choose…") {
                ForEach(NSWorkspace.shared.personsApplications.filter { $0.activationPolicy == .regular && !ids.contains($0.bundleIdentifier ?? "") }
                    .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }.sorted { $0.1 < $1.1 }, id: \.0) { id, name in
                    Button(name) { app.config.set("aiNeverLook", ids + [id]) }
                }
            }
            .menuStyle(.button).buttonStyle(.glass).fixedSize()
        }
    }
}

/// Everything Petal AI did, newest first, with Undo where it can be undone: the latest few, and the rest on asking.
struct AIHistory: View {
    @Environment(PetalApp.self) private var app
    @State private var all = false
    static let few = 5

    var body: some View {
        let history = app.assist.history.prefix(30)
        if history.isEmpty {
            Text("Nothing yet.").font(.system(size: TextSize.callout)).foregroundStyle(.secondary)
        }
        ForEach(all ? history : history.prefix(Self.few)) { done in
            HStack(spacing: 8) {
                Text(done.text).font(.system(size: TextSize.body)).strikethrough(done.undone).foregroundStyle(done.undone ? .secondary : .primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(done.at, style: .relative).font(.system(size: TextSize.small)).foregroundStyle(.secondary)
                if let undo = done.undo, !done.undone {
                    if case .open = undo {
                        Button("Open") { app.assist.undo(done) }.buttonStyle(.glass).controlSize(.small)
                    } else {
                        Button("Undo") { app.assist.undo(done) }.buttonStyle(.glass).controlSize(.small)
                    }
                }
            }
        }
        if history.count > Self.few {
            HStack {
                Spacer()
                Button(all ? "Show fewer" : "Show all \(history.count)") { all.toggle() }.buttonStyle(.glass).controlSize(.small)
            }
        }
    }
}

/// What Petal AI remembers, each with a way to forget it.
struct Memories: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        if app.assist.memories.isEmpty {
            Text("Nothing yet.").font(.system(size: TextSize.callout)).foregroundStyle(.secondary)
        }
        ForEach(app.assist.memories) { memory in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(memory.text).font(.system(size: TextSize.body)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                RoundButton(symbol: "xmark") { app.assist.forget(id: memory.id, matching: nil) }
            }
        }
    }
}

/// What the person chose Always for: taking one away makes Petal AI ask again.
struct AllowedList: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        ForEach(app.config.strings("aiAllowed"), id: \.self) { kind in
            HStack {
                AllowedKindName(kind: kind)
                Spacer(minLength: 8)
                RoundButton(symbol: "xmark") { app.config.set("aiAllowed", app.config.strings("aiAllowed").filter { $0 != kind }) }
            }
        }
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
        case Routines.card: "Routines that open things or run Shortcuts"
        case RunBrowsers.kind: "Using a browser of its own"
        default: kind.hasPrefix("computer:") ? "Using \(Apps.cachedName(String(kind.dropFirst(9))) ?? String(kind.dropFirst(9)))" : kind
        }
    }
}

/// A kind's name in the Allowed list: an app's name is read off the main thread (its bundle id until then).
struct AllowedKindName: View {
    let kind: String
    @State private var appName: String?

    var body: some View {
        Text(appName.map { "Using \($0)" } ?? AllowedKinds.name(kind)).font(.system(size: TextSize.body))
            .task(id: kind) {
                guard kind.hasPrefix("computer:") else { return }
                let id = String(kind.dropFirst(9))
                if Apps.cachedName(id) == nil { Apps.loadName(id) { appName = $0 } }
            }
    }
}

/// What macOS lets Petal see: each permission, what it's for in a few words, and where it stands (Allowed, or the
/// button that asks). Checked every 1.5 s; a row draws again only when its own answer changes.
struct Permissions: View {
    @Environment(PetalApp.self) private var app
    @State private var trusted = Windows.trusted
    @State private var capture = Capture.allowed
    @State private var asking = false
    /// What Music and Spotify said, each as last asked without prompting.
    @State private var players: [Browsers.Access] = []
    let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let _ = BodyCount.hit("PermissionsSettings")
        PermissionRow(symbol: "accessibility", title: "Accessibility", help: "Windows, badges, notes on windows, using your apps") {
            if trusted { Allowed() } else { AccentButton(title: "Allow…") { Windows.askForPermission() } }
        }
        .onReceive(timer) { _ in check() }
        .onAppear { check() }
        PermissionRow(symbol: "rectangle.dashed.badge.record", title: "Screen Recording", help: "A still of each window in previews, never a recording") {
            if capture { Allowed() } else { AccentButton(title: "Allow…") { Capture.askForPermission() } }
        }
        PermissionRow(symbol: "safari", title: "Browsers", help: "Which site a tab is on") {
            BrowserAccessButton(asking: $asking)
        }
        PermissionRow(symbol: "music.note", title: "Music and Spotify", help: "Now playing") {
            if players.contains(.denied) {
                Button("Open Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.glass)
            } else if players.contains(.notAsked) {
                AccentButton(title: "Allow…") { askPlayers() }
            } else if players.contains(.allowed) {
                Allowed()
            } else {
                Text("Asked when a player is open").font(.system(size: TextSize.callout)).foregroundStyle(.secondary)
            }
        }
    }

    private func check() {
        let nowTrusted = Windows.trusted, nowCapture = Capture.allowed
        if nowTrusted != trusted { trusted = nowTrusted }
        if nowCapture != capture { capture = nowCapture }
        app.browsers.refresh()
        // A headless run asks no app anything.
        guard !Headless.on else { return }
        DispatchQueue.global(qos: .utility).async {
            let found = NowPlaying.players.map { Browsers.access($0) }
            DispatchQueue.main.async { if found != players { players = found } }
        }
    }

    /// macOS asks the person once for each player that's open and hasn't been asked.
    private func askPlayers() {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = NowPlaying.players.map { Browsers.access($0) == .notAsked ? Browsers.access($0, ask: true) : Browsers.access($0) }
            DispatchQueue.main.async { players = found }
        }
    }

    private struct Allowed: View {
        var body: some View {
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .font(.system(size: TextSize.callout, weight: .medium))
        }
    }
}

/// The browsers' answer in Privacy: Allow… asks every installed browser that hasn't been asked (macOS asks once for
/// each), Open Settings… when one said no, Allowed when all said yes.
struct BrowserAccessButton: View {
    @Environment(PetalApp.self) private var app
    @Binding var asking: Bool

    var body: some View {
        let browsers = app.browsers
        if asking {
            ProgressView().controlSize(.small)
        } else if !browsers.refused.isEmpty {
            Button("Open Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.glass)
        } else if browsers.allAllowed || Browsers.installed().isEmpty {
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .font(.system(size: TextSize.callout, weight: .medium))
        } else {
            AccentButton(title: "Allow…") {
                asking = true
                browsers.askAll { asking = false }
            }
        }
    }
}

struct PermissionRow<Status: View>: View {
    let symbol: String
    let title: String
    let help: String
    @ViewBuilder var status: Status

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: TextSize.heading)).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: TextSize.body))
                Text(help).font(.system(size: TextSize.small)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            status
        }
    }
}

// MARK: - About

extension SettingsList {
    static let about: [SettingsBlock] = [
        SettingsBlock([
            SettingsEntry("petal", "Petal", words: "version website github open source edgetr") { AboutRow(title: $0) },
        ]),
        SettingsBlock("Check Petal", footer: "You see a report before it goes anywhere.", [
            SettingsEntry("doctor", "Check Petal", words: "doctor fix problem report bug broken") { _ in DoctorRows() },
        ]),
        SettingsBlock("Updates", [
            SettingsEntry(SettingToggle(key: "autoUpdate", title: "Update automatically"), words: "updates new version"),
            SettingsEntry("update", "Check for updates", words: "new version restart what’s new") { UpdateRow(title: $0) },
        ]),
    ]
}

/// Petal's icon, its name and version, and where it lives on the web.
struct AboutRow: View {
    @Environment(PetalApp.self) private var app
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: TextSize.subtitle, weight: .semibold))
                Text("Version \(app.version)").font(.system(size: TextSize.callout)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Website") { NSWorkspace.shared.open(URL(string: "https://petal.codes")!) }.buttonStyle(.glass)
            Button("GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/edgetr/petal")!) }.buttonStyle(.glass)
        }
    }
}

/// A new version waiting (restart, and what's new in it), or what's new in this one and a look for a newer one now.
struct UpdateRow: View {
    @Environment(PetalApp.self) private var app
    let title: String

    var body: some View {
        if let ready = app.updater.ready {
            SettingRow(title: "Petal \(ready) is ready") {
                Button("What’s new") { app.releaseNotes.show(ready) }.buttonStyle(.glass)
                AccentButton(title: "Restart to update") { app.relaunch() }
            }
        } else {
            SettingRow(title: title, help: app.updater.status.isEmpty ? nil : app.updater.status) {
                if UpdateTrust.plainVersion(app.version) {
                    Button("What’s new") { app.releaseNotes.show(app.version) }.buttonStyle(.glass)
                }
                Button("Check now") { app.updater.check(manual: true) }.buttonStyle(.glass)
            }
        }
    }
}

/// "Check Petal": the doctor's findings, a button to fix what it can, and a way to report what it can't.
struct DoctorRows: View {
    @Environment(PetalApp.self) private var app
    @State private var findings: [Doctor.Finding] = []
    @State private var working = false
    @State private var reporting = false

    var body: some View {
        ForEach(permissionFindings + findings) { finding in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: finding.level == "ok" ? "checkmark.circle.fill" : finding.level == "warn" ? "exclamationmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(finding.level == "ok" ? .green : finding.level == "warn" ? .orange : .red)
                Text(finding.text + (finding.fixed.map { " Fixed: \($0)." } ?? "")).font(.system(size: TextSize.callout))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack(spacing: 8) {
            Button(findings.isEmpty ? "Check Petal" : "Check again") { run(fix: false) }.buttonStyle(.glass)
            if findings.contains(where: { $0.level != "ok" && $0.fixed == nil }) {
                AccentButton(title: "Fix what can be fixed") { run(fix: true) }
            }
            if working { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            Button("Report a problem…") { reporting = true }.buttonStyle(.glass)
        }
        .sheet(isPresented: $reporting) { ReportSheet().environment(app) }
    }

    /// macOS grants these to the app itself, so the window checks them, not the doctor command.
    private var permissionFindings: [Doctor.Finding] {
        guard !findings.isEmpty else { return [] }
        return [Doctor.Finding(level: Windows.trusted ? "ok" : "warn", area: "permissions",
                               text: Windows.trusted ? "Petal can see your windows." : "Petal can't see your windows yet: allow it under Privacy."),
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
            Text("Report a problem").font(.system(size: TextSize.subtitle, weight: .semibold))
            TextField("What happened?", text: $what, axis: .vertical).lineLimit(2...4)
            if !preview.isEmpty {
                ScrollView {
                    Text(preview).font(.system(size: TextSize.small, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .padding(8)
                .glassEffect(.clear, in: .rect(cornerRadius: Radius.tile))
                Text("This goes to github.com/edgetr/petal, where anyone can read it. Your username is replaced, and no window titles or file contents are included.")
                    .font(.system(size: TextSize.small)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !status.isEmpty { Text(status).font(.system(size: TextSize.callout)).foregroundStyle(.secondary).textSelection(.enabled) }
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
