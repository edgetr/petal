import AppKit
import Observation
import SwiftUI

/// Petal in the menu bar (`menuBarIcon`): Petal's mark, with a menu of Petal Notes, settings, which dock, and
/// updates, with what's new in this Petal. When a new Petal is ready, the mark turns blue with a dot and the menu
/// offers the restart and what's new in that one.
@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private var shownDot = false

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
        } else if !wanted, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
        let dot = app.updater.ready != nil
        if let item, dot != shownDot {
            item.button?.image = Self.mark(dot: dot)
            item.button?.toolTip = dot ? "Petal: an update is ready" : "Petal"
            shownDot = dot
        }
    }

    /// The menu bar icon's color while an update is ready, as an app's menu bar icon says it has news.
    static let updateBlue = NSColor.systemBlue

    private func observe() {
        withObservationTracking { _ = app.updater.ready } onChange: {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh(); self.observe() } }
        }
    }

    // MARK: The menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = app.config
        if let ready = app.updater.ready {
            menu.addItem(Menus.header("Petal \(ready) is ready"))
            menu.addItem(ClosureMenuItem(title: "Restart to Update") { [weak self] in self?.app.relaunch() })
            menu.addItem(ClosureMenuItem(title: "What’s New in \(ready)") { [weak self] in self?.app.releaseNotes.show(ready) })
        } else if let available = app.updater.available?.version {
            menu.addItem(Menus.header("Petal \(available) is available"))
            menu.addItem(ClosureMenuItem(title: "Install Petal \(available)") { [weak self] in
                self?.app.updater.installAvailable()
                self?.app.settings.show(.about)
            })
            menu.addItem(ClosureMenuItem(title: "What’s New in \(available)") { [weak self] in self?.app.releaseNotes.show(available) })
        } else {
            // Its answer shows in Settings › About as it comes: the menu is gone by then.
            let check = ClosureMenuItem(title: "Check for Updates") { [weak self] in
                self?.app.updater.check(manual: true)
                self?.app.settings.show(.about)
            }
            menu.addItem(check)
            let status = app.updater.status
            if !status.isEmpty {
                let line = NSMenuItem(title: status, action: nil, keyEquivalent: "")
                line.isEnabled = false
                menu.addItem(line)
            }
            let running = app.version
            if UpdateTrust.plainVersion(running) {
                menu.addItem(ClosureMenuItem(title: "What’s New in \(running)") { [weak self] in self?.app.releaseNotes.show(running) })
            }
        }
        menu.addItem(.separator())
        if config.bool("notes") {
            menu.addItem(ClosureMenuItem(title: "Petal Notes") { [weak self] in self?.app.notesWindow.show() })
        }
        menu.addItem(ClosureMenuItem(title: "Petal Settings…") { [weak self] in self?.app.settings.show() })
        if config.whichDock == "petal" {
            menu.addItem(ClosureMenuItem(title: "Use macOS’s Dock") { [weak self] in self?.app.useDock("macos") })
        } else {
            menu.addItem(ClosureMenuItem(title: "Use Petal’s Dock") { [weak self] in self?.app.useDock("petal") })
        }
        menu.addItem(ClosureMenuItem(title: "Quit Petal") { PetalApp.quit() })
    }

    // MARK: The mark

    /// Petal's five petals (the icon's, without its tile: brand/icon.py) as a template image, so macOS colors it like
    /// the menu bar's own icons; when an update is ready, in blue with a dot.
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
                // The petals and the dot in blue (drawn again for each appearance, so it's macOS's blue for it).
                updateBlue.setFill()
                NSRect(x: 0, y: 0, width: side, height: side).fill(using: .sourceAtop)
            }
            return true
        }
        image.isTemplate = !dot
        image.accessibilityDescription = dot ? "Petal, update ready" : "Petal"
        return image
    }
}

// MARK: - What's new

/// What's new in Petal: each version's notes as the app holds them (`Resources/notes/<version>.md`, which build.sh
/// copies from `macos/notes/`, the same files the release workflow makes each release's text from), or, for a version
/// the app doesn't hold (an update that's ready), the GitHub release's text. It opens by itself once after Petal
/// updated (`afterLaunch`), and from the menu bar and Settings › About.
@MainActor
final class ReleaseNotes {
    private var window: NSWindow?

    /// One version's notes as the app shows them (`WhatsNew.inApp`), or nil until they're fetched.
    struct Section: Sendable, Identifiable, Equatable {
        let version: String
        var body: String?
        var id: String { version }
    }

    /// `state.json`'s record of the version Petal last ran as on this Mac.
    nonisolated static let lastKey = "lastVersion"

    func show(_ version: String) { show([version], forward: true) }

    /// Opens the window with these versions' notes, newest first. What the app holds is read off the main thread;
    /// the rest is fetched by the window. Asked for (`forward`), it comes forward and takes the keyboard; opened by
    /// itself after an update, it shows over the other windows and leaves the keyboard where it is.
    func show(_ versions: [String], forward: Bool) {
        guard !versions.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let sections = versions.map { Section(version: $0, body: Self.carried($0)) }
            await self.open(sections, forward: forward)
        }
    }

    /// Once, a moment after the dock is up: when Petal started as a newer version than it last ran as, What's New
    /// opens by itself with each version missed since (`WhatsNew.versions`). The version is kept whatever shows, so
    /// it opens once for a version, and a first install (not `welcomed` when Petal started) shows nothing. When it
    /// can't be kept (state.json can't be written), nothing opens: it would open again at every start. Never in a
    /// headless run, and never over the welcome.
    func afterLaunch(running: String, welcomed: Bool) {
        guard !Headless.on else { return }
        Task.detached(priority: .utility) {
            let last = PetalState.read()[Self.lastKey] as? String
            let versions = WhatsNew.versions(last: last, running: running, welcomed: welcomed, carried: Self.carriedVersions())
            let kept = WhatsNew.keeps(last: last, running: running) && PetalState.set(Self.lastKey, running)
            guard WhatsNew.opens(versions, kept: kept) else { return }
            await MainActor.run {
                guard !PetalApp.shared.welcome.isOpen else { return }
                self.show(versions, forward: false)
            }
        }
    }

    private func open(_ sections: [Section], forward: Bool) {
        guard !Headless.on else { return }
        let window = self.window ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 460, height: 360)
            window.letContentGoWhenClosed()
            return window
        }()
        self.window = window
        window.title = ReleaseNotesView.title(sections)
        window.setGlassContent(ReleaseNotesView(sections: sections).environment(PetalApp.shared))
        if !window.isVisible { window.center() }
        if forward { PetalWindow.bringForward(window) } else { window.orderFrontRegardless() }
    }

    /// The notes this app holds for a version, as the app shows them; nil when it holds none.
    nonisolated static func carried(_ version: String) -> String? {
        guard UpdateTrust.plainVersion(version), let folder = Bundle.main.resourceURL?.appending(path: "notes"),
              let text = try? String(contentsOf: folder.appending(path: "\(version).md"), encoding: .utf8) else { return nil }
        return WhatsNew.inApp(text)
    }

    /// The versions whose notes this app holds.
    nonisolated static func carriedVersions() -> [String] {
        guard let folder = Bundle.main.resourceURL?.appending(path: "notes"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.compactMap(WhatsNew.version(ofFile:))
    }

    /// A version's notes from its GitHub release (the tag macos-v<version>), as the app shows them.
    static func fetch(_ version: String) async -> String? {
        guard UpdateTrust.plainVersion(version),
              let url = URL(string: "https://api.github.com/repos/edgetr/petal/releases/tags/macos-v\(version)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return WhatsNew.inApp(release["body"] as? String ?? "")
    }
}

/// The What's New window: its title, each version's notes (under its version when there are several, newest first),
/// and one button at most: Restart to update while that version waits, Install while it's available with updates off,
/// or the release page when notes couldn't load.
struct ReleaseNotesView: View {
    @Environment(PetalApp.self) private var app
    let sections: [ReleaseNotes.Section]
    @State private var fetched: [String: String] = [:]
    @State private var failed: Set<String> = []

    static func title(_ sections: [ReleaseNotes.Section]) -> String {
        sections.count == 1 ? "What’s new in \(sections[0].version)" : "What’s new in Petal"
    }

    var body: some View {
        ZStack {
            Backdrop()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                    Text(Self.title(sections)).font(.system(size: TextSize.title, weight: .bold))
                }
                Scroll {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            if index > 0 { Divider() }
                            notes(section)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let ready = app.updater.ready, ready == sections.first?.version {
                    HStack {
                        Spacer()
                        AccentButton(title: "Restart to update") { app.relaunch() }.keyboardShortcut(.defaultAction)
                    }
                } else if let available = app.updater.available, available.version == sections.first?.version {
                    HStack {
                        Spacer()
                        AccentButton(title: "Install") { app.updater.installAvailable() }.keyboardShortcut(.defaultAction)
                    }
                } else if !failed.isEmpty {
                    HStack {
                        Spacer()
                        Button("Read them online") {
                            NSWorkspace.shared.open(URL(string: "https://github.com/edgetr/petal/releases")!)
                        }.buttonStyle(.glass)
                    }
                }
            }
            .padding(24)
            .padding(.top, 14)
        }
        .frame(minWidth: 460, minHeight: 360)
        .task {
            for section in sections where section.body == nil {
                if let body = await ReleaseNotes.fetch(section.version) { fetched[section.version] = body } else { failed.insert(section.version) }
            }
        }
    }

    @ViewBuilder private func notes(_ section: ReleaseNotes.Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if sections.count > 1 {
                Text("Petal \(section.version)").font(.system(size: TextSize.subtitle, weight: .semibold))
            }
            if let body = section.body ?? fetched[section.version] {
                MarkdownView(text: body.isEmpty ? "No notes for this one." : body)
            } else if failed.contains(section.version) {
                Text("Couldn’t load these notes.").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 30)
            }
        }
    }
}
