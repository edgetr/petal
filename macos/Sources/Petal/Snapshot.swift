import AppKit
import SwiftUI

/// `Petal --snapshot <folder>` draws each of Petal's views into a PNG, in an off-screen window, without showing
/// anything or touching macOS's Dock: for checking the layout while working on Petal.
@MainActor
enum Snapshot {
    static func run(to folder: String) {
        let app = PetalApp()
        let dock = ScreenDock()
        dock.desktop = 1
        dock.mode = app.config.mode(forDesktop: 1)
        dock.items = (dock.mode?.apps ?? []).filter(Apps.shows).prefix(7).enumerated().map { index, id in
            DockItem(id: id, pinned: true, running: index % 3 == 0, windows: index % 3 == 0 ? (index == 0 ? 2 : 1) : 0, here: true, active: index == 0)
        }
        dock.stageSlots = dock.items.count + 1
        let agent = app.claude.agent
        agent.preview([
            .init(kind: .user, text: "Make my dock icons a bit bigger"),
            .init(kind: .step, text: "Looking at your dock"),
            .init(kind: .step, text: "Changing  iconSize"),
            .init(kind: .claude, text: "Done — icons are now **44 pt**, up from 36. Say *smaller* if it's too much."),
            .init(kind: .ask, text: "defaults write com.apple.finder AppleShowAllFiles -bool true"),
        ])
        // A sticky note: the tab it's stuck to shows under the header, with the chip that changes it.
        agent.place = NotePlace(pid: 0, app: "com.apple.Safari", appName: "Safari", window: 1, title: "Liquid Glass – Apple Developer",
                                mode: dock.mode?.id ?? "", desktop: 1, scope: .tab,
                                tab: NoteTab(index: 2, count: 5, url: "https://developer.apple.com/design/", title: "Liquid Glass – Apple Developer"))

        let installed = Apps.installed().map(\.id)
        let pick = { (wanted: [String]) in wanted.filter(installed.contains) + installed.filter { !wanted.contains($0) } }
        let sampleNew = Insights.Suggestion(kind: .mode, key: "a+b", apps: Array(pick(["com.figma.Desktop", "com.linear", "com.apple.Preview"]).prefix(2)),
                                            minutes: 260, days: 4)
        let sampleAdd = Insights.Suggestion(kind: .add, key: "add", apps: Array(pick(["com.tinyspeck.slackmacgap", "com.apple.MobileSMS"]).prefix(1)),
                                            mode: app.config.modes.first?.id ?? "", minutes: 90, days: 5)
        let sampleSummary = Insights.Summary(title: "Last week", from: Date().addingTimeInterval(-7 * 86400), to: Date(),
                                             modes: app.config.modes.prefix(3).enumerated().map { index, mode in
                                                 .init(id: mode.id, name: mode.name, minutes: [740, 185, 40][index],
                                                       apps: mode.apps.filter(installed.contains).prefix(3).enumerated().map { ($0.element, [500, 150, 60][$0.offset]) })
                                             }, cardsShown: 8, wentBack: 5)

        var views: [(String, AnyView, CGSize?)] = [
            ("dock", AnyView(DockView(dock: dock)), nil),
            ("welcome", AnyView(WelcomeView {}), CGSize(width: 640, height: 920)),
            ("claude-empty", AnyView(ClaudePanelView(panel: ClaudePanel())), nil),
            ("claude-chat", AnyView(ClaudePanelView(panel: app.claude)), nil),
            ("search", AnyView(AppSearchView(search: app.search)), nil),
            ("stack", AnyView(StackView(contents: StackContents(folder: "~/Downloads", entries: Stacks.entries("~/Downloads", limit: 12))) {}), nil),
            ("card-suggest", AnyView(CardView(card: FocusCard(kind: .suggestion, suggestion: sampleNew))), nil),
            ("card-add", AnyView(CardView(card: FocusCard(kind: .suggestion, suggestion: sampleAdd))), nil),
            ("card-made", AnyView(CardView(card: FocusCard(kind: .made, target: app.config.modes.last, desktop: 1, suggestion: sampleNew))), nil),
            ("card-summary", AnyView(CardView(card: FocusCard(kind: .summary, summary: sampleSummary))), nil),
        ]
        // The focus guard's cards and a notification that can't wait, each with its tail (bottom dock; then a side dock's).
        for kind in ["block", "move", "peek", "note"] {
            if let card = FocusCard.sample(kind, app: app, here: dock.mode, desktop: 1) {
                views.append(("card-\(kind)", AnyView(CardView(card: card, tail: Tail(edge: .bottom, offset: kind == "peek" ? 0 : -90))), nil))
            }
        }
        if let other = app.config.modes.first(where: { $0.id != dock.mode?.id }) {
            let card = FocusCard(kind: .noteReady, bundleID: "com.apple.Safari", title: "Compare these two plans", target: other,
                                 reason: "Pricing – Linear", noteID: UUID())
            views.append(("card-note-ready", AnyView(CardView(card: card, tail: Tail(edge: .bottom, offset: -90))), nil))
        }
        if let card = FocusCard.sample("block", app: app, here: dock.mode, desktop: 1) {
            views.append(("card-block-left", AnyView(CardView(card: card, tail: Tail(edge: .leading, offset: 20))), nil))
        }
        // The mode switcher: a countdown into a distracting mode, with Stay; a website shortcut with its globe.
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        if let social = app.config.modes.first(where: { $0.isDistracting && $0.id != dock.mode?.id }) {
            app.pendingMode = PendingMode(desktop: 1, mode: social.id, deadline: Date().addingTimeInterval(19), total: social.wait)
            write(render(AnyView(DockView(dock: dock)), app: app, size: nil), name: "dock-countdown", folder: folder)
            app.pendingMode = nil
        }
        // Held notifications waiting on two modes: counts on their buttons.
        for (index, mode) in app.config.modes.filter({ $0.id != dock.mode?.id }).prefix(2).enumerated() {
            for n in 0..<(index == 0 ? 3 : 1) {
                app.notes.preview(HeldNote(id: Int64(index * 10 + n), app: "com.apple.mail", title: "", subtitle: "", body: "x", date: Date(), mode: mode.id))
            }
        }
        write(render(AnyView(DockView(dock: dock)), app: app, size: nil), name: "dock-held", folder: folder)
        for mode in app.config.modes { app.notes.clear(mode.id) }
        // Stacks with something new, a full Trash, and a song playing.
        let stackFolders = Stacks.resolve(app.config.strings("stackFolders"))
        app.signals.preview(trashEmpty: false, fresh: Set(stackFolders.prefix(1)),
                            nowPlaying: NowPlaying(player: "com.spotify.client", title: "Pyramid Song", artist: "Radiohead", playing: true, artwork: nil))
        write(render(AnyView(DockView(dock: dock)), app: app, size: nil), name: "dock-extras", folder: folder)
        // Over the now-playing tile: the song and its controls. Over Spotify's icon: the controls above its windows.
        write(render(AnyView(PreviewView(id: Previews.media) {}), app: app, size: nil), name: "preview-media", folder: folder)
        let me = AXUIElementCreateApplication(getpid())
        let sampleWindows = ["Liked Songs", "Radiohead – OK Computer", ""].enumerated().map { index, title in
            AppWindow(id: "sample-\(index)", pid: getpid(), title: title, minimized: index == 2, frame: .zero, element: me)
        }
        let picture = NSImage(size: NSSize(width: 240, height: 150), flipped: false) { rect in
            NSColor(white: 0.12, alpha: 1).setFill(); rect.fill()
            NSColor(red: 0.11, green: 0.73, blue: 0.33, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 56, height: rect.height).fill()
            NSColor(white: 0.3, alpha: 1).setFill()
            for row in 0..<5 { NSRect(x: 72, y: 120 - CGFloat(row) * 22, width: 140, height: 10).fill() }
            return true
        }
        app.previews.preview(windows: Array(sampleWindows.prefix(2)), pictures: true, thumbnails: ["sample-0": picture])
        write(render(AnyView(PreviewView(id: "com.spotify.client") {}), app: app, size: nil), name: "preview-music", folder: folder)
        app.signals.preview(trashEmpty: true, fresh: [], nowPlaying: nil)
        // Without Screen Recording: the windows by name.
        app.previews.preview(windows: sampleWindows, pictures: false)
        write(render(AnyView(PreviewView(id: "com.apple.Safari") {}), app: app, size: nil), name: "preview-titles", folder: folder)
        app.previews.preview(windows: [], pictures: false)
        // The sites' own icons, fetched from the sites (up to 10 s).
        let samples = ["https://github.com", "https://www.figma.com"]
        for id in samples { _ = Sites.shared.icon(id) }
        let until = Date().addingTimeInterval(10)
        while Date() < until && samples.contains(where: { Sites.shared.icon($0) == nil }) { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        let sites = ScreenDock()
        sites.desktop = 2
        sites.mode = dock.mode
        sites.items = Array(dock.items.prefix(3)) + ["https://github.com", "https://www.figma.com", "https://example.invalid"].map {
            DockItem(id: $0, pinned: true, running: false, windows: 0, here: false, active: false)
        }
        sites.stageSlots = sites.items.count + 1
        views.append(("dock-sites", AnyView(DockView(dock: sites)), nil))
        views.append(("site-icons", AnyView(HStack(spacing: 14) {
            ForEach(["https://github.com", "https://www.figma.com", "https://example.invalid"], id: \.self) { SiteIcon(id: $0, size: 64) }
        }.padding(14)), nil))
        views.append(("banner", AnyView(BannerView(notes: [FocusCard.sample("note", app: app, here: dock.mode)?.note].compactMap { $0 },
                                                    heading: nil, color: nil, open: {})), nil))
        if let social = app.config.modes.first(where: \.isDistracting), let note = FocusCard.sample("note", app: app, here: dock.mode)?.note {
            views.append(("banner-held", AnyView(BannerView(notes: [note, note], heading: "2 notifications held for \(social.name)",
                                                             color: social.color, open: {})), nil))
        }
        if let mode = dock.mode {
            views.append(("menubar-mode", AnyView(HStack(spacing: 4) {
                Image(nsImage: MenuBar.modeImage(mode.icon, dot: false)).renderingMode(.template).foregroundStyle(.white)
                Text(mode.name).font(.system(size: 13)).foregroundStyle(.white)
            }.padding(10)), nil))
        }
        let recipeFile = URL(fileURLWithPath: folder).appending(path: "sample.petal")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? Data(##"{"petal":1,"name":"Ada's Omarchy","from":"omarchy","modes":[{"id":"building","name":"Building","icon":"x","color":"#b18cff","about":"code and terminals","apps":["com.mitchellh.ghostty","code","zed"]},{"id":"music","name":"Music","color":"#ff9f5f","about":"listening","apps":["spotify","steam"]}],"apps":{"com.mitchellh.ghostty":"Ghostty","code":"Visual Studio Code","zed":"Zed","spotify":"Spotify","steam":"Steam"},"settings":{"iconSize":48,"appGlow":false},"dock":{"position":"left","autoHide":true}}"##.utf8).write(to: recipeFile)
        if let plan = try? Recipe.plan(recipeFile) {
            views.append(("recipe", AnyView(RecipeImportView(url: recipeFile, plan: plan) {}), nil))
        }
        views.append(("overview", AnyView(OverviewView {}), nil))
        views.append(("whats-new", AnyView(ReleaseNotesView(version: "0.2.0", preloaded: .init(body: """
            ## Petal 0.2.0

            Your dock learns a little: **suggested modes** and a *weekly summary*, from a history that stays on your Mac.

            - Share your dock as a `.petal` file, by AirDrop or Messages
            - Keyboard shortcuts: ⌃⌥1…9 switch modes
            - Magnification, and [a menu bar icon](https://github.com/edgetr/petal)

            ### Fixes
            * Focus cards no longer cover the update card
            """, link: nil))), CGSize(width: 560, height: 600)))
        views.append(("describe-day", AnyView(DescribeDaySheet()), nil))
        views.append(("settings-windows", AnyView(VStack { WindowsCard(showTiling: true) }.padding(20)), CGSize(width: 640, height: 420)))
        views.append(("settings-api-keys", AnyView(VStack(spacing: 14) { ForEach(Provider.allCases) { APIKeyCard(provider: $0) } }.padding(20)), CGSize(width: 640, height: 420)))
        // Petal AI using an app: its first question, the chip with Stop by its pointer, and the pointer itself.
        app.assist.preview(Assist.Request(kind: "computer:com.apple.Safari", title: "Let Petal AI use Safari?",
                                          detail: "First, pressing Export. Until this reply is done it can press, type and choose menus in Safari with its own pointer; yours stays where it is. Esc stops it."))
        write(render(AnyView(CardView(card: FocusCard(kind: .ask))), app: app, size: nil), name: "card-ask-computer", folder: folder)
        app.assist.preview(nil)
        views.append(("computer-pill", AnyView(ActingPill(caption: "Pressing Export") {}), nil))
        views.append(("computer-pill-idle", AnyView(ActingPill(caption: nil) {}), nil))
        views.append(("computer-pill-long", AnyView(ActingPill(caption: "Typing in Search or enter website name, a long field name") {}), nil))
        if let pointer = FakeCursor.picture() { views.append(("computer-cursor", AnyView(Image(nsImage: pointer)), nil)) }
        for dot in [false, true] {
            let mark = MenuBar.mark(dot: dot)
            views.append(("menubar\(dot ? "-dot" : "")", AnyView(HStack(spacing: 16) {
                Image(nsImage: mark).renderingMode(.template).foregroundStyle(.white)
                Image(nsImage: mark).renderingMode(.template).resizable().frame(width: 72, height: 72).foregroundStyle(.white)
            }.padding(12)), nil))
        }
        for section in SettingsSection.allCases {
            views.append(("settings-\(section.rawValue)", AnyView(SettingsView(selection: section)), CGSize(width: 920, height: 700)))
        }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Magnification: drawn once to find where everything is, then with the pointer over the third app.
        Magnifier.forced = true
        let magnified = ScreenDock()
        magnified.desktop = 1
        magnified.mode = dock.mode
        magnified.items = dock.items
        magnified.stageSlots = dock.stageSlots
        _ = render(AnyView(DockView(dock: magnified)), app: app, size: nil)
        if magnified.items.count > 2, let frame = magnified.magnifier.frames[magnified.items[2].id]?.rect {
            magnified.magnifier.preview(pointer: frame.midX + frame.width * 0.25)
        }
        write(render(AnyView(DockView(dock: magnified)), app: app, size: nil), name: "dock-magnified", folder: folder)
        Magnifier.forced = false
        for (name, view, size) in views {
            write(render(view, app: app, size: size), name: name, folder: folder)
        }
    }

    private static func render(_ view: AnyView, app: PetalApp, size: CGSize?) -> NSImage? {
        let content = view.environment(app).environment(\.colorScheme, .dark).environment(\.snapshotting, true)
            .frame(width: size?.width, height: size?.height)
            .background(Color(white: 0.16))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return renderer.nsImage
    }

    private static func write(_ image: NSImage?, name: String, folder: String) {
        guard let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let path = (folder as NSString).appendingPathComponent(name + ".png")
        try? png.write(to: URL(fileURLWithPath: path))
        print(path)
    }
}

extension EnvironmentValues {
    /// True while `Petal --snapshot` draws a view: scroll areas draw as plain stacks.
    @Entry var snapshotting = false
}

/// A vertical scroll area, or a plain stack while snapshotting.
struct Scroll<Content: View>: View {
    @Environment(\.snapshotting) private var snapshotting
    @ViewBuilder var content: Content

    var body: some View {
        if snapshotting { VStack(spacing: 0) { content } } else { ScrollView { content } }
    }
}
