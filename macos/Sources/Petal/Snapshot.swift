import AppKit
import CoreImage
import SwiftUI

/// `Petal --snapshot <folder>` draws each of Petal's views into a PNG, in an off-screen window, without showing
/// anything or touching macOS's Dock: for checking the layout while working on Petal.
@MainActor
enum Snapshot {
    static func run(to folder: String) {
        // Made-up items stand in for the vault: a snapshot never reads or writes the Keychain.
        let vault = sampleVault()
        VaultStore.standIn(vault)
        let app = PetalApp()
        app.refreshSystemFacts(wait: true)
        VaultModel.shared.preview(vault)
        // Made-up grants for Settings › Vault › Agents: nothing is read or written.
        let home = NSHomeDirectory()
        AgentGrants.shared.preview([
            AgentAccess.Grant(item: vault.first { $0.kind == .apiKey }?.id ?? "", title: "OpenAI", project: home + "/petal", agent: .codex),
            AgentAccess.Grant(item: vault.first { $0.kind == .login }?.id ?? "", title: "GitHub", project: home + "/petal", agent: .claude),
            AgentAccess.Grant(item: AgentAccess.Grant.newLogins, title: "New logins", project: home + "/edgetr", agent: .any),
        ])
        let dock = ScreenDock()
        dock.desktop = 1
        // The dock's own apps, or (an empty dock, as in a throwaway folder) a few every Mac has.
        let installed = Apps.installed().map(\.id)
        let own = app.config.apps.filter(Apps.shows)
        let sample = ["com.apple.Safari", "com.apple.mail", "com.apple.Notes", "com.apple.iCal", "com.apple.Music", "com.apple.Terminal",
                      "com.apple.Preview"].filter(installed.contains)
        dock.items = (own.isEmpty ? sample : own).prefix(7).enumerated().map { index, id in
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
        // "+" with something typed: a row for each result over the field, up to eight.
        let typed = AppSearch()
        typed.query = "ca"
        var views: [(String, AnyView, CGSize?)] = [
            ("dock", AnyView(DockView(dock: dock)), nil),
            ("welcome", AnyView(WelcomeView {}), CGSize(width: 640, height: WelcomeView.height)),
            ("claude-empty", AnyView(ClaudePanelView(panel: ClaudePanel())), nil),
            ("claude-chat", AnyView(ClaudePanelView(panel: app.claude)), nil),
            ("search", AnyView(AppSearchView(search: app.search)), nil),
            ("search-results", AnyView(AppSearchView(search: typed)), nil),
            ("stack", AnyView(StackView(contents: StackContents(folder: "~/Downloads", entries: Stacks.entries("~/Downloads", limit: 12))) {}), nil),
        ]
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
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
        // A player that hasn't been asked whether Petal may see what's playing: the line that asks, under its windows.
        app.signals.preview(trashEmpty: true, fresh: [], nowPlaying: nil, playersWaiting: ["com.apple.Music"])
        write(render(AnyView(PreviewView(id: "com.apple.Music") {}), app: app, size: nil), name: "preview-player-ask", folder: folder)
        app.signals.preview(trashEmpty: true, fresh: [], nowPlaying: nil)
        app.previews.preview(windows: [], pictures: false)
        // Over the AI button: sticky notes at work in their windows in the background, one waiting for the person,
        // one done, and one in an app kept private (no picture).
        let editor = NSImage(size: NSSize(width: 240, height: 150), flipped: false) { rect in
            NSColor(white: 0.1, alpha: 1).setFill(); rect.fill()
            NSColor(white: 0.16, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 58, height: rect.height).fill()
            NSColor(red: 0.85, green: 0.21, blue: 0.5, alpha: 0.8).setFill(); NSRect(x: 72, y: 18, width: 150, height: 18).fill()
            NSColor(white: 0.32, alpha: 1).setFill()
            for row in 0..<4 { NSRect(x: 72, y: 128 - CGFloat(row) * 20, width: CGFloat(150 - row * 22), height: 8).fill() }
            return true
        }
        let ids = (0..<4).map { _ in UUID() }
        let notes = [
            NotePreviewItem(id: ids[0], app: "com.apple.Safari", appName: "Safari", title: "Find the cheapest flight to Lisbon",
                            line: "Waiting for you: " + Background.Reason.menu.status, working: true, needsYou: true, hidden: false,
                            pid: 0, window: nil, attached: true),
            NotePreviewItem(id: ids[1], app: "com.apple.Terminal", appName: "T3 Code", title: "Answer the agent's questions",
                            line: NoteStatus.step("Typing in “Ask anything”"), working: true, needsYou: false, hidden: false,
                            pid: 0, window: nil, attached: true),
            NotePreviewItem(id: ids[2], app: "com.apple.mail", appName: "Mail", title: "Sort this week's receipts", line: "Done",
                            working: false, needsYou: false, hidden: true, pid: 0, window: nil, attached: true),
        ]
        app.previews.preview(notes: notes, thumbnails: [ids[0]: picture, ids[1]: editor])
        write(render(AnyView(PreviewView(id: Previews.notes) {}), app: app, size: nil), name: "preview-notes", folder: folder)
        app.previews.preview(notes: nil)
        // Hidden displays (runDisplays): a helper at work on a display of its own (its display, live, with Show me),
        // one waiting its turn for a display, and an AI session outside Petal on its own. The picture is made up.
        let display = NSImage(size: NSSize(width: 240, height: 150), flipped: false) { rect in
            NSColor(red: 0.16, green: 0.2, blue: 0.3, alpha: 1).setFill(); rect.fill()
            NSColor(white: 0.97, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 14, y: 20, width: 150, height: 110), xRadius: Radius.control, yRadius: Radius.control).fill()
            NSColor(white: 0.86, alpha: 1).setFill(); NSRect(x: 14, y: 116, width: 150, height: 14).fill()
            NSColor(white: 0.7, alpha: 1).setFill()
            for row in 0..<5 { NSRect(x: 26, y: 98 - CGFloat(row) * 15, width: CGFloat(120 - row * 14), height: 6).fill() }
            NSColor(white: 0.2, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 120, y: 34, width: 106, height: 70), xRadius: Radius.control, yRadius: Radius.control).fill()
            return true
        }
        let shown = (0..<3).map { _ in UUID() }
        let onDisplays = [
            NotePreviewItem(id: shown[0], app: "", appName: "", title: "Compare the three quotes", line: NoteStatus.step("Typing in “Total”"),
                            working: true, needsYou: false, hidden: false, pid: 0, window: nil, attached: false, display: shown[0]),
            NotePreviewItem(id: shown[1], app: "", appName: "", title: "Book the dentist", line: NoteStatus.waitingForDisplay,
                            working: true, needsYou: false, hidden: false, pid: 0, window: nil, attached: false),
            NotePreviewItem(id: shown[2], app: "", appName: "", title: "Claude Code in T3 Code", line: "Working on a display of its own",
                            working: true, needsYou: false, hidden: false, pid: 0, window: nil, attached: false, display: shown[2], outside: true),
        ]
        app.previews.preview(notes: onDisplays, displays: [shown[0]: display, shown[2]: editor])
        write(render(AnyView(PreviewView(id: Previews.notes) {}), app: app, size: nil), name: "preview-notes-displays", folder: folder)
        app.previews.preview(notes: nil)
        // The sites' own icons, fetched from the sites (up to 10 s).
        let samples = ["https://github.com", "https://www.figma.com"]
        for id in samples { _ = Sites.shared.icon(id) }
        let until = Date().addingTimeInterval(10)
        while Date() < until && samples.contains(where: { Sites.shared.icon($0) == nil }) { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        let sites = ScreenDock()
        sites.desktop = 2
        sites.items = Array(dock.items.prefix(3)) + ["https://github.com", "https://www.figma.com", "https://example.invalid"].map {
            DockItem(id: $0, pinned: true, running: false, windows: 0, here: false, active: false)
        }
        sites.stageSlots = sites.items.count + 1
        views.append(("dock-sites", AnyView(DockView(dock: sites)), nil))
        // Petal Notes: a note folded, open, turned over, on glass, resting as tabs on a window's edge, and the quick
        // question with Stick here (NoteSnapshot.swift).
        paperNotes(app: app, folder: folder)
        // The Petal Notes window (grid, canvas, a Private notebook), a notebook's stack in the dock, a note on a person
        // (NoteLibrarySnapshot.swift).
        notesLibrary(app: app, folder: folder)
        // Petal's viewer: a PDF with margin notes and highlights, a deck with notes per slide, versions on copies.
        viewer(app: app, folder: folder)
        views.append(("site-icons", AnyView(HStack(spacing: 14) {
            ForEach(["https://github.com", "https://www.figma.com", "https://example.invalid"], id: \.self) { SiteIcon(id: $0, size: 64) }
        }.padding(14)), nil))
        views.append(("whats-new", AnyView(ReleaseNotesView(version: "0.2.0", preloaded: .init(body: """
            ## Petal 0.2.0

            Your dock holds **your notes** now, and a *note pad* to take a paper from.

            - Drag a paper off the note pad and let go anywhere
            - Keyboard shortcuts: ⌃⌥N for a new note
            - Magnification, and [a menu bar icon](https://github.com/edgetr/petal)

            ### Fixes
            * A note no longer covers the update notice
            """, link: nil))), CGSize(width: 560, height: 600)))
        // Groups of the settings window on their own, with every row whatever the settings say: tiling's keys, using
        // your apps with the switch for a hidden display for each run, and paying with a subscription or an API key.
        for (name, block, height) in [("settings-windows", SettingsList.windows, 420.0), ("settings-run-displays", SettingsList.usingApps, 260.0),
                                      ("settings-api-keys", SettingsList.paying, 260.0)] {
            views.append((name, AnyView(VStack { SettingsBlocks(blocks: [block], whatever: true) }.padding(20)), CGSize(width: 640, height: height)))
        }
        // Petal AI using an app: its first question, the chip with Stop by its pointer, and the pointer itself.
        app.assist.preview(Assist.Request(kind: "computer:com.apple.Safari", title: "Let Petal AI use Safari?",
                                          detail: "First: pressing Export. With its own pointer, for this reply. Esc stops it."))
        write(render(AnyView(AskCard()), app: app, size: nil), name: "card-ask-computer", folder: folder)
        app.assist.preview(nil)
        // The vault's cards: a login it doesn't have yet, the one Buy card of a checkout, an address, and a login on a
        // page that isn't its site.
        let cards: [(String, Assist.Request)] = [
            ("card-vault-login", Assist.Request(kind: "vault-new", title: "Add a login to your vault", detail: "", every: true,
                                                form: VaultForm(kind: .login, place: "github.com", fills: true))),
            ("card-vault-address", Assist.Request(kind: "vault-new", title: "Add an address", detail: "For your order from shop.example.", every: true,
                                                  form: VaultForm(kind: .address))),
            ("card-vault-buy", Assist.Request(kind: "vault-buy", title: "Buy on shop.example?",
                                              detail: "Petal AI says: “Sony WH-1000XM5 headphones, $279”. Pays with Visa •••• 4242.", every: true, warn: true, allow: "Buy")),
            ("card-agent-key", Assist.Request(kind: "agent-key", title: "Codex in T3 Code wants your OpenAI key for “npm test” in ~/petal",
                                              detail: "It never sees it: Petal gives it to the command and takes it out of what the command prints.",
                                              every: true, warn: true, allow: "Allow once", keep: "Always for this project", mark: .codex)),
            ("card-agent-fill", Assist.Request(kind: "agent-vault", title: "Claude Code in T3 Code wants to fill your GitHub login on github.com in ~/petal",
                                               detail: "It says: “Sign in to test the new settings page”. It never sees the secret: Petal fills it in itself.",
                                               every: true, warn: true, allow: "Allow once", keep: "Always for this project", mark: .claude)),
            ("card-agent-unknown", Assist.Request(kind: "agent-key", title: "An unknown program (claude) wants your OpenAI key for “node app.js” in ~/petal",
                                                  detail: "Petal can't tell what this program is: it isn't an agent Petal knows, signed by its maker. It never sees it: Petal gives it to the command and takes it out of what the command prints.",
                                                  every: true, warn: true, allow: "Allow once", mark: .unknown)),
            ("card-vault-mismatch", Assist.Request(kind: "vault-fill", title: "Fill your github.com password on githuh-login.com?",
                                                   detail: "This login is saved for github.com. This page is githuh-login.com: if it only looks like github.com, it may be trying to take your password.",
                                                   every: true, warn: true, allow: "Fill anyway")),
        ]
        for (name, request) in cards {
            app.assist.preview(request)
            write(render(AnyView(AskCard()), app: app, size: nil), name: name, folder: folder)
        }
        app.assist.preview(nil)
        views.append(("computer-pill", AnyView(ActingPill(caption: "Pressing Export") {}), nil))
        views.append(("computer-pill-idle", AnyView(ActingPill(caption: nil) {}), nil))
        views.append(("computer-pill-long", AnyView(ActingPill(caption: "Typing in Search or enter website name, a long field name") {}), nil))
        if let pointer = FakeCursor.picture() { views.append(("computer-cursor", AnyView(Image(nsImage: pointer)), nil)) }
        for dot in [false, true] {
            let mark = MenuBar.mark(dot: dot)
            // A template image is colored by the menu bar (white here); the update's blue one draws as it is.
            let rendering: Image.TemplateRenderingMode = mark.isTemplate ? .template : .original
            views.append(("menubar\(dot ? "-dot" : "")", AnyView(HStack(spacing: 16) {
                Image(nsImage: mark).renderingMode(rendering).foregroundStyle(.white)
                Image(nsImage: mark).renderingMode(rendering).resizable().frame(width: 72, height: 72).foregroundStyle(.white)
            }.padding(12)), nil))
        }
        // The settings window, a page at a time, each whole (as tall as its rows, never shorter than the window), and
        // what the ask bar finds for a word.
        for section in SettingsSection.allCases {
            write(settingsPage(SettingsView(selection: section), app: app), name: "settings-\(section.rawValue)", folder: folder)
        }
        write(settingsPage(SettingsView(selection: .dock, asking: "hover"), app: app), name: "settings-search", folder: folder)
        // The Petal AI page with the notes changed elsewhere while the person typed: their typing kept, and the
        // line under the editor to pick theirs or mine.
        app.instructions.preview(changedElsewhere: true)
        write(settingsPage(SettingsView(selection: .ai), app: app), name: "settings-ai-conflict", folder: folder)
        app.instructions.preview(changedElsewhere: false)
        // A vault of 300 logins, whole, and twelve releases' notes.
        VaultModel.shared.preview(vault + BenchTargets.logins(300))
        write(settingsPage(SettingsView(selection: .vault), app: app), name: "settings-vault-300", folder: folder)
        VaultModel.shared.preview(vault)
        views.append(("whats-new-long", AnyView(ReleaseNotesView(version: "1.0.0", preloaded: .init(body: BenchTargets.releaseNotes, link: nil))),
                      CGSize(width: 560, height: 3200)))
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Magnification: drawn once to find where everything is, then with the pointer over the third app.
        Magnifier.forced = true
        let magnified = ScreenDock()
        magnified.desktop = 1
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

    /// The settings window at its width, as tall as the page it shows (a snapshot doesn't scroll). App icons are
    /// HDR pictures on this macOS, and a page that shows one right on the window makes the renderer's own picture
    /// HDR; turned into a PNG the plain way, the whole page comes out grey. Core Image maps it to sRGB as it looks.
    static func settingsPage(_ view: SettingsView, app: PetalApp) -> NSImage? {
        let page = view.frame(width: 920).frame(minHeight: 640).fixedSize(horizontal: false, vertical: true)
        let renderer = ImageRenderer(content: page.environment(app).environment(\.colorScheme, .dark).environment(\.snapshotting, true)
            .background(Color(white: 0.16)))
        renderer.scale = 1
        guard let drawn = renderer.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let picture = CIImage(cgImage: drawn)
        guard let plain = CIContext().createCGImage(picture, from: picture.extent, format: .RGBA8, colorSpace: space) else { return nil }
        return NSImage(cgImage: plain, size: NSSize(width: plain.width, height: plain.height))
    }

    /// The vault's made-up items for snapshots.
    static func sampleVault() -> [VaultItem] {
        var github = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"])
        github[.username] = "ada@example.com"
        github[.password] = "sample-password-1"
        var bank = VaultItem(kind: .login, title: "Bank", sites: ["bank.com.tr"])
        bank[.username] = "ada"
        bank[.password] = "sample-password-2"
        var me = VaultItem(kind: .contact, title: "Me")
        me[.name] = "Ada Lovelace"
        me[.relationship] = "me"
        me[.email] = "ada@example.com"
        var deniz = VaultItem(kind: .contact, title: "Deniz")
        deniz[.name] = "Deniz Kaya"
        deniz[.relationship] = "girlfriend"
        deniz[.phone] = "+90 555 000 00 00"
        var home = VaultItem(kind: .address, title: "Home")
        home[.name] = "Deniz Kaya"
        home[.street] = "Bağdat Cd. 12"
        home[.city] = "İstanbul"
        home[.country] = "Türkiye"
        home[.contact] = deniz.id
        var card = VaultItem(kind: .card, title: "Visa")
        card[.number] = "4242 4242 4242 4242"
        card[.expiry] = "04/27"
        var key = VaultItem(kind: .apiKey, title: "OpenAI", sites: ["platform.openai.com"])
        key[.value] = "sample-key-123456"
        // Secrets from before kinds, waiting to be sorted.
        let old = Vault.migrate([("Figma password", "sample-password-3"), ("Stripe key", "sample-key-654321")])
        return [github, bank, me, deniz, home, card, key] + old
    }

    static func render(_ view: AnyView, app: PetalApp, size: CGSize?) -> NSImage? {
        let content = view.environment(app).environment(\.colorScheme, .dark).environment(\.snapshotting, true)
            .frame(width: size?.width, height: size?.height)
            .background(Color(white: 0.16))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return renderer.nsImage
    }

    static func write(_ image: NSImage?, name: String, folder: String) {
        guard let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("couldn't draw \(name)")
            return
        }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
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
