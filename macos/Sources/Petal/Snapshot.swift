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
        dock.items = (dock.mode?.apps ?? []).filter { Apps.url($0) != nil }.prefix(7).enumerated().map { index, id in
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
            ("welcome", AnyView(WelcomeView {}), CGSize(width: 640, height: 720)),
            ("claude-empty", AnyView(ClaudePanelView(panel: ClaudePanel())), nil),
            ("claude-chat", AnyView(ClaudePanelView(panel: app.claude)), nil),
            ("search", AnyView(AppSearchView(search: app.search)), nil),
            ("card", AnyView(CardView(card: FocusCard(kind: .guardCard, bundleID: "net.imput.helium", title: "x.com",
                                                      target: app.config.mode(id: "social"), here: dock.mode,
                                                      reason: "Social feed, not work"))), nil),
            ("stack", AnyView(StackView(folder: "~/Downloads") {}), nil),
            ("card-suggest", AnyView(CardView(card: FocusCard(kind: .suggestion, suggestion: sampleNew))), nil),
            ("card-add", AnyView(CardView(card: FocusCard(kind: .suggestion, suggestion: sampleAdd))), nil),
            ("card-made", AnyView(CardView(card: FocusCard(kind: .made, target: app.config.modes.last, desktop: 1, suggestion: sampleNew))), nil),
            ("card-summary", AnyView(CardView(card: FocusCard(kind: .summary, summary: sampleSummary))), nil),
        ]
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
