import AppKit

/// The right-click menus, as macOS's own menus (Liquid Glass on macOS 26), with Omarchy's entries in Omarchy's order.
@MainActor
enum Menus {
    static var app: PetalApp { PetalApp.shared }
    static var config: Config { app.config }

    /// The dock's own menu stays tiny: where it sits, auto-hide, focus cards; anything else is asking Claude.
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
        menu.addItem(toggle("Focus cards", config.bool("focusGuard")) { config.set("focusGuard", !config.bool("focusGuard")) })
        menu.addItem(.separator())
        if let provider = app.chatProvider {
            menu.addItem(ClosureMenuItem(title: "Anything else? Ask \(provider.name)…") { app.claude.open(asking: nil) })
            let hint = NSMenuItem(title: "Like “stop the icons bouncing” or “turn off the app glow”.", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(title: "Petal Settings…") { app.settings.show() })
        menu.addItem(ClosureMenuItem(title: "Use macOS’s Dock") { app.useDock("macos") })
        menu.addItem(ClosureMenuItem(title: "Quit Petal") { NSApp.terminate(nil) })
        pop(menu)
    }

    static func app(_ item: DockItem, in dock: ScreenDock) {
        let menu = NSMenu()
        let name = Apps.name(item.id)
        var listed = false
        if config.bool("quickActions"), item.running {
            let windows = app.previews.windows(of: item.id)
            if !windows.isEmpty {
                menu.addItem(header("Windows"))
                for window in windows.prefix(10) {
                    let row = ClosureMenuItem(title: (window.title.isEmpty ? name : window.title) + (window.minimized ? " (minimized)" : "")) {
                        Windows.focus(window)
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
                    row.image = icon(NSWorkspace.shared.icon(forFile: url.path))
                    menu.addItem(row)
                }
                listed = true
            }
        }
        if listed { menu.addItem(header(name)) }
        if item.running { menu.addItem(ClosureMenuItem(title: "New Window") { app.docks.newWindow(item.id) }) }
        let modeName = dock.mode?.name ?? "dock"
        if let mode = dock.mode {
            let inMode = mode.apps.contains(item.id)
            menu.addItem(ClosureMenuItem(title: inMode ? "Remove from \(modeName)" : "Keep in \(modeName)") {
                if inMode { config.removeApp(item.id, from: mode.id) } else { config.addApp(item.id, to: mode.id) }
            })
        }
        if config.bool("modes") && config.modes.count > 1 {
            menu.addItem(header("In modes"))
            for mode in config.modes {
                let row = toggle(mode.name, mode.apps.contains(item.id)) {
                    if mode.apps.contains(item.id) { config.removeApp(item.id, from: mode.id) } else { config.addApp(item.id, to: mode.id) }
                }
                row.image = symbol(mode.icon, color: mode.color)
                menu.addItem(row)
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Show in Finder") {
            if let url = Apps.url(item.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        })
        if item.running {
            if item.windows > 0 { menu.addItem(ClosureMenuItem(title: "Minimize") { app.docks.minimizeAll(item.id) }) }
            menu.addItem(ClosureMenuItem(title: "Hide") { app.docks.hide(item.id) })
            menu.addItem(ClosureMenuItem(title: "Quit") { app.docks.quit(item.id) })
        }
        pop(menu)
    }

    static func mode(_ mode: Mode, for dock: ScreenDock) {
        let menu = NSMenu()
        menu.addItem(header(mode.name))
        if dock.mode?.id != mode.id, let desktop = dock.desktop {
            menu.addItem(ClosureMenuItem(title: "Use on this Desktop") { app.requestMode(mode.id, desktop: desktop) })
        }
        menu.addItem(toggle("Default mode", config.defaultMode == mode.id) { config.setDefaultMode(mode.id) })
        if config.bool("countdown") {
            menu.addItem(header("Countdown to leave"))
            for (title, seconds) in [("Off", 0.0), ("15s", 15), ("30s", 30), ("1m", 60)] {
                let row = ClosureMenuItem(title: title) {
                    var updated = mode
                    updated.focusDelay = seconds
                    config.save(updated)
                }
                row.state = mode.focusDelay == seconds ? .on : .off
                menu.addItem(row)
            }
        }
        menu.addItem(ClosureMenuItem(title: "All Desktops…") { app.overview.show() })
        menu.addItem(.separator())
        if let provider = app.chatProvider {
            menu.addItem(ClosureMenuItem(title: "Change with \(provider.name)…") { app.claude.open(asking: "Change my \(mode.name) mode: ", send: false) })
        }
        menu.addItem(ClosureMenuItem(title: "Edit in Settings…") { app.settings.show(.modes) })
        if config.modes.count > 1 {
            menu.addItem(ClosureMenuItem(title: "Delete Mode…") {
                let alert = NSAlert()
                alert.messageText = "Delete \(mode.name)?"
                alert.informativeText = "Desktops in \(mode.name) go back to the default mode."
                alert.addButton(withTitle: "Delete")
                alert.addButton(withTitle: "Cancel")
                alert.buttons.first?.hasDestructiveAction = true
                NSApp.activate()
                if alert.runModal() == .alertFirstButtonReturn { config.delete(mode: mode.id) }
            })
        }
        pop(menu)
    }

    static func media(_ playing: NowPlaying) {
        let menu = NSMenu()
        menu.addItem(header(Apps.name(playing.player)))
        menu.addItem(ClosureMenuItem(title: "Previous") { NowPlaying.send("previous track", to: playing.player) })
        menu.addItem(ClosureMenuItem(title: "Next") { NowPlaying.send("next track", to: playing.player) })
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

    static func symbol(_ name: String, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [color]))
    }

    static func icon(_ image: NSImage) -> NSImage {
        let small = image.copy() as! NSImage
        small.size = NSSize(width: 16, height: 16)
        return small
    }

    /// At the pointer, as the dock's own menus open.
    private static func pop(_ menu: NSMenu) {
        app.tooltips.hide()
        app.previews.close()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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
