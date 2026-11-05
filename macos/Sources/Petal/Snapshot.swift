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

        var views: [(String, AnyView, CGSize?)] = [
            ("dock", AnyView(DockView(dock: dock)), nil),
            ("welcome", AnyView(WelcomeView {}), CGSize(width: 640, height: 640)),
            ("claude-empty", AnyView(ClaudePanelView(panel: ClaudePanel())), nil),
            ("claude-chat", AnyView(ClaudePanelView(panel: app.claude)), nil),
            ("search", AnyView(AppSearchView(search: app.search)), nil),
            ("card", AnyView(CardView(card: FocusCard(kind: .guardCard, bundleID: "net.imput.helium", title: "x.com",
                                                      target: app.config.mode(id: "social"), here: dock.mode,
                                                      reason: "Social feed, not work"))), nil),
            ("stack", AnyView(StackView(folder: "~/Downloads") {}), nil),
        ]
        for section in SettingsSection.allCases {
            views.append(("settings-\(section.rawValue)", AnyView(SettingsView(selection: section)), CGSize(width: 920, height: 700)))
        }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (name, view, size) in views {
            let content = view.environment(app).environment(\.colorScheme, .dark).environment(\.snapshotting, true)
                .frame(width: size?.width, height: size?.height)
                .background(Color(white: 0.16))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            let path = (folder as NSString).appendingPathComponent(name + ".png")
            try? png.write(to: URL(fileURLWithPath: path))
            print(path)
        }
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
