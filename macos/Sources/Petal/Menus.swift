import AppKit
import QuickLookUI

/// The right-click menus, as macOS's own menus (Liquid Glass on macOS 26).
@MainActor
enum Menus {
    static var app: PetalApp { PetalApp.shared }
    static var config: Config { app.config }

    /// The dock's own menu stays tiny: where it sits and auto-hide; anything else is asking Claude.
    static func settings(for dock: ScreenDock?) {
        let menu = NSMenu()
        menu.addItem(header("Position"))
        for (title, value) in [("Left", "left"), ("Bottom", "bottom"), ("Right", "right")] {
            let item = ClosureMenuItem(title: title) { config.setDock("position", value) }
            item.state = config.position == value ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(toggle("Auto-hide", config.autoHide) { config.setDock("autoHide", !config.autoHide) })
        menu.addItem(.separator())
        if app.chatProvider != nil {
            menu.addItem(ClosureMenuItem(title: "Anything else? Ask Petal AI…") { app.claude.open(asking: nil) })
            let hint = NSMenuItem(title: "Like “stop the icons bouncing” or “turn off the app glow”.", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(.separator())
        }
        // A dock with no apps of its own yet (a new one, or modes that couldn't be read): macOS's Dock, one click away.
        if config.apps.isEmpty { menu.addItem(ClosureMenuItem(title: "Import macOS’s Dock") { config.importSystemDock() }) }
        menu.addItem(ClosureMenuItem(title: "Petal Settings…") { app.settings.show() })
        menu.addItem(ClosureMenuItem(title: "Use macOS’s Dock") { app.useDock("macos") })
        menu.addItem(ClosureMenuItem(title: "Quit Petal") { PetalApp.quit() })
        pop(menu)
    }

    /// An app's menu. Its windows (listed as the pointer reached the icon, or else now, off the main thread) and its
    /// recent files' icons are gathered first, for 150 ms at most: past that, the menu opens without what isn't in.
    static func app(_ item: DockItem) {
        if Sites.isWeb(item.id) { return site(item) }
        let known = app.previews.knownWindows(item.id)
        let wantWindows = config.bool("quickActions") && item.running && known == nil
        // What ⌘N is in it, for "New Window"'s name: looked up now if hovering hadn't.
        let pid = item.running && Apps.newItem(item.id) == nil ? NSRunningApplication.persons(withBundleIdentifier: item.id).first?.processIdentifier : nil
        let recent = config.bool("recentFiles") ? Apps.recent(item.id) : []
        // Not looked for yet (no hover first): looked for now, within the same wait.
        let wantRecent = config.bool("recentFiles") && !Apps.knowsRecent(item.id)
        let appURL = wantRecent ? Apps.url(item.id) : nil
        guard wantWindows || wantRecent || pid != nil || !recent.isEmpty else { return appMenu(item, windows: known ?? [], icons: [:]) }
        let once = Once()
        let open = { (windows: [AppWindow], icons: [URL: NSImage]) in
            guard once.first() else { return }
            appMenu(item, windows: windows, icons: icons)
        }
        let id = item.id
        openers.async {
            let newItem = pid.flatMap { Apps.newItemTitle(pid: $0) }
            let found = wantRecent ? Apps.recentFiles(appURL: appURL, limit: 6) : recent
            let windows = wantWindows ? Previews.windows(of: id) : (known ?? [])
            let icons = Dictionary(found.map { ($0, NSWorkspace.shared.icon(forFile: $0.path)) }, uniquingKeysWith: { a, _ in a })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if wantRecent { Apps.found(found, recentFor: id) }
                    if pid != nil { Apps.found(newItem, newItemFor: id) }
                    open(windows, icons)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { open(known ?? [], [:]) }
    }

    /// The first of several ways something can finish is the one that counts (on the main thread).
    private final class Once {
        private var done = false
        func first() -> Bool { defer { done = true }; return !done }
    }

    private static func appMenu(_ item: DockItem, windows: [AppWindow], icons: [URL: NSImage]) {
        let menu = NSMenu()
        let name = Apps.name(item.id)
        var listed = false
        if config.bool("quickActions"), item.running {
            if !windows.isEmpty {
                menu.addItem(header("Windows"))
                for window in windows.prefix(10) {
                    let row = ClosureMenuItem(title: (window.title.isEmpty ? name : window.title) + (window.minimized ? " (minimized)" : "")) {
                        Windows.focus(window, onScreen: app.docks.isOnScreen(window))
                    }
                    menu.addItem(row)
                }
                listed = true
            }
        }
        if config.bool("recentFiles") {
            let recent = Apps.recent(item.id)
            if !recent.isEmpty {
                menu.addItem(header("Recent"))
                for url in recent {
                    let row = ClosureMenuItem(title: url.lastPathComponent) { app.docks.launch(item.id, files: [url]) }
                    row.image = icons[url].map(icon) ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
                    menu.addItem(row)
                }
                listed = true
            }
        }
        if listed { menu.addItem(header(name)) }
        let finder = item.id == DockController.finder
        if !item.running { menu.addItem(ClosureMenuItem(title: "Open") { app.docks.launch(item.id) }) }
        // Named by what ⌘N does in it ("New Message" in Mail), and left out when it has nothing on ⌘N or Petal
        // can't tell.
        if item.running, let new = Apps.newItem(item.id), !new.isEmpty {
            menu.addItem(ClosureMenuItem(title: new) { app.docks.newWindow(item.id) })
        }
        // Finder is its own button (finderInDock), not one of the dock's apps.
        if item.id != DockController.finder || !config.bool("finderInDock") {
            let kept = config.apps.contains(item.id)
            menu.addItem(ClosureMenuItem(title: kept ? "Remove from Dock" : "Keep in Dock") {
                if kept { config.removeApp(item.id) } else { config.addApp(item.id) }
            })
        }
        menu.addItem(.separator())
        // Finder itself: not shown in Finder, and never quit from here (its Desktop goes with it).
        if !finder {
            menu.addItem(ClosureMenuItem(title: "Show in Finder") {
                if let url = Apps.url(item.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            })
        }
        if item.running {
            if item.windows > 0 { menu.addItem(ClosureMenuItem(title: "Minimize All") { app.docks.minimizeAll(item.id) }) }
            menu.addItem(ClosureMenuItem(title: "Hide") { app.docks.hide(item.id) })
            if !finder {
                // Option held as the menu opens: Force Quit, for an app that doesn't answer.
                if NSEvent.modifierFlags.contains(.option) {
                    menu.addItem(ClosureMenuItem(title: "Force Quit") { app.docks.forceQuit(item.id) })
                } else {
                    menu.addItem(ClosureMenuItem(title: "Quit") { app.docks.quit(item.id) })
                }
            }
        }
        pop(menu)
    }

    /// A website shortcut: open it, or take it out of the dock.
    static func site(_ item: DockItem) {
        let menu = NSMenu()
        menu.addItem(header(Apps.name(item.id)))
        menu.addItem(ClosureMenuItem(title: "Open in Browser") { Sites.open(item.id) })
        menu.addItem(ClosureMenuItem(title: "Remove from Dock") { config.removeApp(item.id) })
        pop(menu)
    }

    /// A minimized window: bring it back, or close it.
    static func minimized(_ window: AppWindow, app id: String) {
        let menu = NSMenu()
        menu.addItem(header(window.title.isEmpty ? Apps.name(id) : window.title))
        menu.addItem(ClosureMenuItem(title: "Show") { Windows.focus(window) })
        menu.addItem(ClosureMenuItem(title: "Close Window") { Windows.close(window) })
        pop(menu)
    }

    static func media(_ playing: NowPlaying) {
        let menu = NSMenu()
        menu.addItem(header(Apps.name(playing.player)))
        menu.addItem(ClosureMenuItem(title: "Previous") { app.signals.control("previous track") })
        menu.addItem(ClosureMenuItem(title: "Next") { app.signals.control("next track") })
        menu.addItem(ClosureMenuItem(title: "Show Player") { app.docks.launch(playing.player) })
        pop(menu)
    }

    static func stack(_ folder: String) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Open in Finder") { NSWorkspace.shared.open(Stacks.url(folder)) })
        menu.addItem(ClosureMenuItem(title: "Remove from Dock") {
            config.set("stackFolders", config.strings("stackFolders").filter { $0 != folder && Stacks.resolve([$0]).first != folder })
        })
        pop(menu)
    }

    /// A file in an open stack, with what Finder offers for it. The apps that open it come from Launch Services,
    /// off the dock's thread; the menu opens once they're known.
    static func file(_ url: URL, done: @escaping () -> Void) {
        openers.async {
            let preferred = NSWorkspace.shared.urlForApplication(toOpen: url)
            let others = NSWorkspace.shared.urlsForApplications(toOpen: url).filter { $0 != preferred }
            let apps = ([preferred].compactMap { $0 } + others).map { app in
                (url: app, name: FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""),
                 icon: NSWorkspace.shared.icon(forFile: app.path))
            }
            let sortedOthers = apps.dropFirst(preferred == nil ? 0 : 1).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let list = Array(apps.prefix(preferred == nil ? 0 : 1)) + sortedOthers
            DispatchQueue.main.async {
                MainActor.assumeIsolated { fileMenu(url, apps: list, preferred: preferred != nil, done: done) }
            }
        }
    }

    nonisolated private static let openers = DispatchQueue(label: "petal.openers", qos: .userInitiated)

    private static func fileMenu(_ url: URL, apps: [(url: URL, name: String, icon: NSImage)], preferred: Bool, done: @escaping () -> Void) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Open") { NSWorkspace.shared.open(url); done() })
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        for (index, app) in apps.enumerated() {
            let item = ClosureMenuItem(title: app.name + (preferred && index == 0 ? " (default)" : "")) {
                NSWorkspace.shared.open([url], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
                done()
            }
            item.image = icon(app.icon)
            choices.addItem(item)
            if preferred && index == 0 && apps.count > 1 { choices.addItem(.separator()) }
        }
        openWith.submenu = choices
        openWith.isEnabled = !apps.isEmpty
        menu.addItem(openWith)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]); done() })
        menu.addItem(ClosureMenuItem(title: "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        })
        menu.addItem(NSSharingServicePicker(items: [url]).standardShareMenuItem)
        menu.addItem(ClosureMenuItem(title: "Quick Look") { done(); QuickLook.shared.show(url) })
        menu.addItem(.separator())
        // Through the Trash, so Finder can put it back.
        menu.addItem(ClosureMenuItem(title: "Move to Trash") {
            NSWorkspace.shared.recycle([url]) { _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { app.signals.lookAtTrash() } }
            }
        })
        pop(menu)
    }

    static func trash() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Open Trash") { Stacks.openTrash() })
        let empty = ClosureMenuItem(title: "Empty Trash…") {
            let alert = NSAlert()
            alert.messageText = "Empty the Trash?"
            alert.informativeText = "Everything in it is deleted for good."
            alert.addButton(withTitle: "Empty Trash")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { Stacks.emptyTrash() }
        }
        menu.addItem(empty)
        pop(menu)
    }

    // MARK: Pieces

    static func header(_ title: String) -> NSMenuItem { NSMenuItem.sectionHeader(title: title) }

    static func toggle(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: action)
        item.state = on ? .on : .off
        return item
    }

    static func icon(_ image: NSImage) -> NSImage {
        let small = image.copy() as! NSImage
        small.size = NSSize(width: 16, height: 16)
        return small
    }

    /// At the pointer, as the dock's own menus open.
    private static func pop(_ menu: NSMenu) {
        app.tooltips.hide()
        app.previews.hold(true)   // none behind the menu, nor one that was about to open
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        app.previews.hold(false)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// Quick Look for a file in a stack. Petal has no window of its own for the panel to belong to, so Petal answers for
/// it from the end of the app's responder chain.
@MainActor
final class QuickLook: NSResponder, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        if NSApp.nextResponder !== self { NSApp.nextResponder = self }
        guard let panel = QLPreviewPanel.shared() else { return }
        NSApp.activate()
        if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}
