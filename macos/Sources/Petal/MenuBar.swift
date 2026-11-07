import AppKit
import Observation
import SwiftUI

/// Petal in the menu bar (`menuBarIcon`): the current mode's icon and name (Petal's mark when modes are off), with a
/// menu of this Desktop's mode and the others, every Desktop, settings, and updates. When a new Petal is ready, the
/// icon gets a dot and the menu offers the restart and what's new.
@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private var shownDot = false
    private var shownMode: Mode?
    private var mode: Mode?

    var app: PetalApp { PetalApp.shared }

    func start() {
        refresh()
        observe()
    }

    /// Follows the setting and the updater.
    func refresh() {
        let wanted = app.config.bool("menuBarIcon")
        if wanted && item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            item.button?.image = Self.mark(dot: false)
            item.button?.imagePosition = .imageLeading
            item.button?.toolTip = "Petal"
            self.item = item
            shownDot = false
            shownMode = nil
        } else if !wanted, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
        let dot = app.updater.ready != nil
        let mode = app.docks.shown && app.config.bool("modes") ? self.mode : nil
        if let item, dot != shownDot || mode != shownMode {
            if let mode {
                // The mode's symbol only: its name is on the dock already.
                item.button?.image = Self.modeImage(mode.icon, dot: dot)
                item.button?.title = ""
                item.button?.toolTip = dot ? "Petal: an update is ready" : "Petal: \(mode.name)"
            } else {
                item.button?.image = Self.mark(dot: dot)
                item.button?.title = ""
                item.button?.toolTip = dot ? "Petal: an update is ready" : "Petal"
            }
            shownDot = dot
            shownMode = mode
        }
    }

    /// The mode in front changed (the dock calls this as it refreshes).
    func show(mode: Mode?) {
        guard mode != self.mode else { return }
        self.mode = mode
        refresh()
    }

    /// A mode's SF Symbol as a menu bar template image, with the update dot; a Nerd Font glyph (from an Omarchy
    /// modes.json) has no symbol, so Petal's mark stands in.
    static func modeImage(_ symbol: String, dot: Bool) -> NSImage {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) else { return mark(dot: dot) }
        guard dot else {
            base.isTemplate = true
            return base
        }
        let size = NSSize(width: base.size.width + 4, height: max(base.size.height, 16))
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: (rect.height - base.size.height) / 2, width: base.size.width, height: base.size.height))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 5, height: 5)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "update ready"
        return image
    }

    private func observe() {
        withObservationTracking { _ = app.updater.ready } onChange: {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh(); self.observe() } }
        }
    }

    // MARK: The menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = app.config
        let dock = app.docks.focusedDock
        let desktop = dock?.desktop ?? Spaces.desktop(on: NSScreen.main ?? NSScreen.screens[0])
        if app.docks.shown && config.bool("modes") && !config.modes.isEmpty {
            menu.addItem(Menus.header(desktop.map { "Desktop \($0)" } ?? "This Desktop"))
            let current = dock?.mode?.id ?? desktop.flatMap { config.mode(forDesktop: $0)?.id }
            for (index, mode) in config.modes.enumerated() {
                let row = ClosureMenuItem(title: mode.name) { [weak self] in
                    guard let self, let desktop else { return }
                    app.requestMode(mode.id, desktop: desktop)
                }
                row.state = mode.id == current ? .on : .off
                row.image = Menus.symbol(mode.icon, color: mode.color)
                if index < 9 && config.bool("shortcuts") && !app.hotkeys.taken.contains(UInt32(index + 1)) {
                    row.keyEquivalent = String(index + 1)
                    row.keyEquivalentModifierMask = [.control, .option]
                }
                row.isEnabled = desktop != nil
                menu.addItem(row)
            }
            menu.addItem(ClosureMenuItem(title: "All Desktops…") { [weak self] in self?.app.overview.show() })
            menu.addItem(.separator())
        }
        if let ready = app.updater.ready {
            menu.addItem(Menus.header("Petal \(ready) is ready"))
            menu.addItem(ClosureMenuItem(title: "Restart to Update") { [weak self] in self?.app.relaunch() })
            menu.addItem(ClosureMenuItem(title: "What’s New in \(ready)") { [weak self] in self?.app.releaseNotes.show(ready) })
        } else {
            let check = ClosureMenuItem(title: "Check for Updates") { [weak self] in self?.app.updater.check(manual: true) }
            menu.addItem(check)
            let status = app.updater.status
            if !status.isEmpty {
                let line = NSMenuItem(title: status, action: nil, keyEquivalent: "")
                line.isEnabled = false
                menu.addItem(line)
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Petal Settings…") { [weak self] in self?.app.settings.show() })
        if config.whichDock == "petal" {
            menu.addItem(ClosureMenuItem(title: "Use macOS’s Dock") { [weak self] in self?.app.useDock("macos") })
        } else {
            menu.addItem(ClosureMenuItem(title: "Use Petal’s Dock") { [weak self] in self?.app.useDock("petal") })
        }
        menu.addItem(ClosureMenuItem(title: "Quit Petal") { NSApp.terminate(nil) })
    }

    // MARK: The mark

    /// Petal's five petals (plugin/assets/petal.svg, without its tile) as a template image, so macOS colors it like
    /// the menu bar's own icons; with a dot when an update is ready.
    static func mark(dot: Bool) -> NSImage {
        let petals: [[CGFloat]] = [
            [32.00, 29.50, 36.80, 25.30, 36.80, 18.70, 32.00, 14.50, 27.20, 18.70, 27.20, 25.30],
            [36.28, 32.61, 41.76, 35.88, 48.03, 33.84, 50.55, 27.97, 45.07, 24.71, 38.79, 26.75],
            [34.65, 37.64, 33.23, 43.86, 37.11, 49.20, 43.46, 49.78, 44.88, 43.56, 41.00, 38.22],
            [29.35, 37.64, 23.00, 38.22, 19.12, 43.56, 20.54, 49.78, 26.89, 49.20, 30.77, 43.86],
            [27.72, 32.61, 25.21, 26.75, 18.93, 24.71, 13.45, 27.97, 15.97, 33.84, 22.24, 35.88],
        ]
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let scale: CGFloat = 16.5 / 37.1, center = CGPoint(x: 32.0, y: 32.14)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: side / 2 + (x - center.x) * scale, y: side / 2 + (y - center.y) * scale)
            }
            NSColor.black.setFill()
            for p in petals {
                let path = NSBezierPath()
                path.move(to: point(p[0], p[1]))
                path.curve(to: point(p[6], p[7]), controlPoint1: point(p[2], p[3]), controlPoint2: point(p[4], p[5]))
                path.curve(to: point(p[0], p[1]), controlPoint1: point(p[8], p[9]), controlPoint2: point(p[10], p[11]))
                path.close()
                path.fill()
            }
            if dot {
                let ring = NSBezierPath(ovalIn: NSRect(x: side - 7, y: 0, width: 7, height: 7))
                NSGraphicsContext.current?.compositingOperation = .clear
                ring.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: NSRect(x: side - 6, y: 1, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = dot ? "Petal, update ready" : "Petal"
        return image
    }
}

// MARK: - What's new

/// The release notes for a version: the GitHub release's text for its macos-v tag, as Markdown.
@MainActor
final class ReleaseNotes {
    private var window: NSWindow?

    func show(_ version: String) {
        let window = self.window ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 460, height: 360)
            return window
        }()
        self.window = window
        window.title = "What’s New in Petal \(version)"
        window.setGlassContent(ReleaseNotesView(version: version).environment(PetalApp.shared))
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    struct Notes: Sendable { let body: String; let link: URL? }

    static func fetch(_ version: String) async -> Notes? {
        guard let url = URL(string: "https://api.github.com/repos/edgetr/petal/releases/tags/macos-v\(version)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Notes(body: release["body"] as? String ?? "", link: (release["html_url"] as? String).flatMap(URL.init(string:)))
    }
}

struct ReleaseNotesView: View {
    @Environment(PetalApp.self) private var app
    let version: String
    var preloaded: ReleaseNotes.Notes?
    @State private var notes: ReleaseNotes.Notes?
    @State private var failed = false

    var body: some View {
        ZStack {
            Backdrop()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What’s new in \(version)").font(.system(size: 22, weight: .bold))
                        Text(app.updater.ready == version ? "Ready: restart Petal to finish." : "Petal for macOS")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Scroll {
                    Group {
                        if let notes = notes ?? preloaded {
                            MarkdownView(text: notes.body.isEmpty ? "No notes for this one." : notes.body)
                        } else if failed {
                            Text("Couldn’t load the notes. They’re on GitHub too.").foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 30)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                HStack {
                    if let link = (notes ?? preloaded)?.link ?? URL(string: "https://github.com/edgetr/petal/releases") {
                        Button("On GitHub") { NSWorkspace.shared.open(link) }.buttonStyle(.glass)
                    }
                    Spacer()
                    if app.updater.ready == version {
                        Button("Restart to update") { app.relaunch() }
                            .buttonStyle(.glassProminent).tint(SettingsSection.dock.tint).keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(24)
            .padding(.top, 14)
        }
        .frame(minWidth: 460, minHeight: 360)
        .task {
            guard preloaded == nil else { return }
            notes = await ReleaseNotes.fetch(version)
            failed = notes == nil
        }
    }
}
