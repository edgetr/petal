import AppKit
import Observation
import SwiftUI

/// An app in the dock: the mode's apps first, in the mode's order, then other apps with a window on this screen's
/// Desktop, in the order they joined (DockModel.js on Omarchy).
struct DockItem: Identifiable, Equatable {
    let id: String   // bundle identifier
    let url: URL
    let name: String
    let pinned: Bool
    var running: Bool
    var active: Bool
}

/// What one screen's dock shows.
@MainActor @Observable
final class ScreenDock {
    var desktop: Int?
    var mode: Mode?
    var items: [DockItem] = []
    var position = "bottom"
    var iconSize: CGFloat = 36
    var idleOpacity: Double = 0.7
    var tooltips = true
    var hoverLift = true
    @ObservationIgnored var order: [String] = []   // apps outside the mode keep their slot for the session

    var vertical: Bool { position == "left" || position == "right" }
}

/// One dock per screen, and everything that keeps them current.
@MainActor
final class DockController {
    let config: Config
    private var panels: [CGDirectDisplayID: DockPanel] = [:]
    private var timer: Timer?
    private let debug = ProcessInfo.processInfo.environment["PETAL_DEBUG"] == "1"

    init(config: Config) {
        self.config = config
        config.onChange = { [weak self] in self?.refresh() }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Windows opening and closing send no notification without Accessibility, so look again now and then.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let screens = NSScreen.screens
        let ids = Set(screens.compactMap(\.displayID))
        for (id, panel) in panels where !ids.contains(id) {
            panel.close()
            panels[id] = nil
        }
        let windows = WindowList.current()
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

        for screen in screens {
            guard let id = screen.displayID else { continue }
            let panel = panels[id] ?? DockPanel(controller: self)
            panels[id] = panel
            let dock = panel.dock
            let desktop = Spaces.desktop(on: screen)
            if desktop != nil || dock.mode == nil {   // a full-screen app keeps the mode of the Desktop before it
                dock.desktop = desktop
                dock.mode = config.mode(forDesktop: desktop ?? 1)
            }
            dock.position = config.position
            dock.iconSize = config.iconSize
            dock.idleOpacity = config.idleOpacity
            dock.tooltips = config.tooltips
            dock.hoverLift = config.hoverLift

            var items: [DockItem] = []
            func add(_ bundleID: String, pinned: Bool) {
                guard !items.contains(where: { $0.id == bundleID }),
                      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
                items.append(DockItem(id: bundleID, url: url, name: FileManager.default.displayName(atPath: url.path)
                                        .replacingOccurrences(of: ".app", with: ""),
                                      pinned: pinned, running: running.contains(bundleID), active: bundleID == frontmost))
            }
            for app in dock.mode?.apps ?? [] { add(app, pinned: true) }
            for app in windows.apps(on: screen) { add(app, pinned: false) }

            // The mode's apps keep the mode's order. The others keep their slot for the session, and newcomers go
            // at the end.
            let pinned = items.filter(\.pinned)
            let others = items.filter { !$0.pinned }
            dock.order = dock.order.filter { key in others.contains { $0.id == key } }
            for item in others where !dock.order.contains(item.id) { dock.order.append(item.id) }
            let ordered = pinned + dock.order.compactMap { key in others.first { $0.id == key } }
            if ordered != dock.items { dock.items = ordered }

            if debug {
                FileHandle.standardError.write(Data("desktop \(desktop.map(String.init) ?? "-") mode \(dock.mode?.id ?? "-") windows \(windows.apps(on: screen)) items \(dock.items.map(\.id))\n".utf8))
            }
            panel.place(on: screen, autoHide: config.autoHide)
        }
    }

    func open(_ item: DockItem) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: item.url, configuration: configuration)
    }

    func showModeMenu(for dock: ScreenDock) {
        let menu = NSMenu()
        if let desktop = dock.desktop {
            let title = NSMenuItem(title: "Desktop \(desktop)", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
        }
        for mode in config.modes {
            let item = ClosureMenuItem(title: mode.name) { [weak self] in self?.setMode(mode, for: dock) }
            item.state = mode.id == dock.mode?.id ? .on : .off
            item.isEnabled = dock.desktop != nil   // a full-screen app's Space has no mode of its own
            if let image = NSImage(systemSymbolName: mode.icon, accessibilityDescription: nil) {
                item.image = image.withSymbolConfiguration(.init(paletteColors: [mode.color]))
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func setMode(_ mode: Mode, for dock: ScreenDock) {
        guard let desktop = dock.desktop else { return }
        config.setMode(mode.id, forDesktop: desktop)
    }

    var modes: [Mode] { config.modes }
    var autoHide: Bool { config.autoHide }
    var replaceDock: Bool { config.replaceDock }
    func setPosition(_ position: String) { config.setDock("position", position) }
    func setAutoHide(_ on: Bool) { config.setDock("autoHide", on) }
    func setReplaceDock(_ on: Bool) {
        config.setDock("replaceDock", on)
        if on { SystemDock.replace() } else { SystemDock.restore() }
    }
}

/// The apps with a normal window on the Desktop each screen shows. The window list needs no permission for this:
/// only owners and frames are read, never titles or contents.
struct WindowList {
    private var windows: [(bundleID: String, center: CGPoint)] = []

    static func current() -> WindowList {
        var list = WindowList()
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        var seen: [pid_t: String] = [:]
        for window in info {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width > 60, bounds.height > 60 else { continue }
            let bundleID: String
            if let known = seen[pid] {
                bundleID = known
            } else {
                guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                      let id = app.bundleIdentifier else { continue }
                seen[pid] = id
                bundleID = id
            }
            list.windows.append((bundleID, CGPoint(x: bounds.midX, y: bounds.midY)))
        }
        return list
    }

    /// Bundle ids in the order their frontmost window is stacked. Window frames count from the top of the main
    /// screen, AppKit's from the bottom.
    func apps(on screen: NSScreen) -> [String] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = screen.frame
        var result: [String] = []
        for window in windows.reversed() {   // back to front, so an app joins where its first window is
            let point = CGPoint(x: window.center.x, y: top - window.center.y)
            if frame.contains(point), !result.contains(window.bundleID) { result.append(window.bundleID) }
        }
        return result
    }
}

/// The panel a dock lives in: borderless, see-through, above windows, on every Desktop, never taking focus away
/// from the app in front.
@MainActor
final class DockPanel: NSPanel {
    let dock = ScreenDock()
    private let hosting: NSHostingView<DockView>
    private var revealed = true
    private var hideAt: Date?
    private var mouseTimer: Timer?
    private weak var screenRef: NSScreen?
    private var autoHide = false

    init(controller: DockController) {
        hosting = NSHostingView(rootView: DockView(dock: dock, controller: controller))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = hosting
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        orderFrontRegardless()
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followMouse() }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func place(on screen: NSScreen, autoHide: Bool) {
        screenRef = screen
        self.autoHide = autoHide
        if !autoHide { revealed = true }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let area = screen.frame
        let visible = screen.visibleFrame   // below the menu bar
        let margin: CGFloat = 4
        var origin: CGPoint
        switch dock.position {
        case "left": origin = CGPoint(x: area.minX + margin, y: visible.midY - size.height / 2)
        case "right": origin = CGPoint(x: area.maxX - size.width - margin, y: visible.midY - size.height / 2)
        default: origin = CGPoint(x: area.midX - size.width / 2, y: area.minY + margin)
        }
        if !revealed {   // slide past the edge, leaving nothing on screen
            switch dock.position {
            case "left": origin.x = area.minX - size.width
            case "right": origin.x = area.maxX
            default: origin.y = area.minY - size.height
            }
        }
        let frame = NSRect(origin: origin, size: size)
        if frame != self.frame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                animator().setFrame(frame, display: true)
            }
        }
    }

    /// Auto-hide: the dock comes out when the pointer meets its screen edge, and goes half a second after it leaves.
    private func followMouse() {
        guard autoHide, let screen = screenRef else { return }
        let mouse = NSEvent.mouseLocation
        let area = screen.frame
        let atEdge: Bool
        switch dock.position {
        case "left": atEdge = mouse.x <= area.minX + 2 && area.contains(CGPoint(x: area.minX + 1, y: mouse.y))
        case "right": atEdge = mouse.x >= area.maxX - 2 && area.contains(CGPoint(x: area.maxX - 1, y: mouse.y))
        default: atEdge = mouse.y <= area.minY + 2 && area.contains(CGPoint(x: mouse.x, y: area.minY + 1))
        }
        let over = frame.insetBy(dx: -12, dy: -12).contains(mouse)
        if !revealed && atEdge {
            revealed = true
            place(on: screen, autoHide: autoHide)
        } else if revealed && !over && !atEdge {
            if hideAt == nil { hideAt = Date().addingTimeInterval(0.5) }
            if let hideAt, Date() >= hideAt {
                revealed = false
                self.hideAt = nil
                place(on: screen, autoHide: autoHide)
            }
        } else {
            hideAt = nil
        }
    }
}

struct DockView: View {
    let dock: ScreenDock
    let controller: DockController

    var body: some View {
        let layout = dock.vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        GlassEffectContainer {
            layout {
                ModeButton(dock: dock, controller: controller)
                SectionLine(dock: dock)
                ForEach(Array(dock.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 && !item.pinned && dock.items[index - 1].pinned { SectionLine(dock: dock) }
                    AppButton(item: item, dock: dock) { controller.open(item) }
                }
            }
            .padding(8)
            .glassEffect(.regular, in: .rect(cornerRadius: dock.iconSize * 0.5 + 8))
        }
        .padding(10)   // room for the glass's shadow inside the panel
        .contextMenu { DockMenu(controller: controller, dock: dock) }
        .animation(.smooth(duration: 0.2), value: dock.items.map(\.id))
    }
}

/// The mode this Desktop is in, in its color. Clicking it puts the Desktop in another mode. A SwiftUI Menu would
/// draw its label as a flat template and lose the color, so this is a button that opens the menu itself.
struct ModeButton: View {
    let dock: ScreenDock
    let controller: DockController

    var body: some View {
        let mode = dock.mode
        Button {
            controller.showModeMenu(for: dock)
        } label: {
            // The color is on the symbol, not tinted into the glass: macOS's tinted icon style takes the color out
            // of tinted glass, and the mode's color is how you tell the mode at a glance.
            ModeIcon(icon: mode?.icon ?? "", size: dock.iconSize * 0.5)
                .foregroundStyle(mode.map { Color(nsColor: $0.color) } ?? .pink)
                .frame(width: dock.iconSize, height: dock.iconSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(dock.desktop.map { "Desktop \($0): \(mode?.name ?? "")" } ?? (mode?.name ?? ""))
    }
}

/// A thin line between the dock's sections.
struct SectionLine: View {
    let dock: ScreenDock

    var body: some View {
        Capsule()
            .fill(.secondary.opacity(0.35))
            .frame(width: dock.vertical ? dock.iconSize * 0.6 : 1, height: dock.vertical ? 1 : dock.iconSize * 0.6)
    }
}

struct ModeIcon: View {
    let icon: String
    let size: CGFloat

    var body: some View {
        if NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
        } else {
            Text(icon).font(.system(size: size))   // a Nerd Font glyph from an Omarchy modes.json
        }
    }
}

struct AppButton: View {
    let item: DockItem
    let dock: ScreenDock
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 3) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: dock.iconSize, height: dock.iconSize)
                Circle()
                    .fill(.primary)
                    .frame(width: 4, height: 4)
                    .opacity(item.running ? (item.active ? 0.9 : 0.5) : 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(item.running || !item.pinned ? 1 : dock.idleOpacity)
        .scaleEffect(hovering && dock.hoverLift ? 1.08 : 1, anchor: .bottom)
        .animation(.spring(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .help(dock.tooltips ? item.name : "")
    }
}

/// The right-click menu stays tiny, as on Omarchy: where the dock sits, auto-hide, and quitting. Everything else is
/// asking Claude.
struct DockMenu: View {
    let controller: DockController
    let dock: ScreenDock

    var body: some View {
        Picker("Position", selection: Binding(get: { dock.position }, set: { controller.setPosition($0) })) {
            Text("Bottom").tag("bottom")
            Text("Left").tag("left")
            Text("Right").tag("right")
        }
        Toggle("Auto-hide", isOn: Binding(get: { controller.autoHide }, set: { controller.setAutoHide($0) }))
        Toggle("Hide macOS's Dock", isOn: Binding(get: { controller.replaceDock }, set: { controller.setReplaceDock($0) }))
        Divider()
        Button("Quit Petal") { NSApp.terminate(nil) }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
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
