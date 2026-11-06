import AppKit
import Observation
import SwiftUI

/// An app in the dock (DockModel.js and Dock.qml's itemsFor on Omarchy).
struct DockItem: Identifiable, Equatable {
    let id: String          // bundle identifier
    let pinned: Bool        // in this Desktop's mode
    var running: Bool
    var windows: Int        // its normal windows, anywhere
    var here: Bool          // one of them is on this screen's Desktop
    var active: Bool        // the app in front
}

/// What one screen's dock shows.
@MainActor @Observable
final class ScreenDock {
    var desktop: Int?
    var mode: Mode?
    var items: [DockItem] = []
    var minimized: [AppWindow] = []
    var stageSlots = 0
    var dragging: String?
    var dragOffset: CGFloat = 0
    var revealed = true
    var openPopup: String?          // the slot whose stack, preview or menu is open
    @ObservationIgnored var order: [String] = []
    @ObservationIgnored var frames: [String: CGRect] = [:]   // slot frames in the panel, top-left origin
    @ObservationIgnored weak var panel: DockPanel?
    let magnifier = Magnifier()

    init() { magnifier.dock = self }

    var vertical: Bool { PetalApp.shared.config.position != "bottom" }
}

/// One dock per screen, and everything that keeps them current.
@MainActor
final class DockController {
    private(set) var panels: [CGDirectDisplayID: DockPanel] = [:]
    private var timer: Timer?
    private var minimizedAt = Date.distantPast
    private var minimizedCache: [AppWindow] = []
    var shown = false

    var app: PetalApp { PetalApp.shared }
    var config: Config { app.config }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        // Another app in front changes only which icon is active: the last look at the windows does, at once.
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(quick: true) }
        }
        // Apps opening, quitting, hiding, and another Desktop: look at the windows again, off the main thread.
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshInBackground(force: true) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        // Windows opening, closing and minimizing send no notification to other apps, so look again now and then.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInBackground() }
        }
    }

    func show(_ on: Bool) {
        shown = on
        if on { refresh() } else {
            for panel in panels.values { panel.close() }
            panels = [:]
        }
    }

    /// Looks at the windows off the main thread, then refreshes with what it found: the once-a-second refresh. The
    /// window server can take a moment to answer (hundreds of milliseconds while apps launch), and the dock never
    /// waits for it.
    func refreshInBackground(force: Bool = false) {
        guard shown else { return }
        if looking { lookAgain = lookAgain || force; return }
        looking = true
        let pids = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)
        let wantsMinimized = config.bool("minimized") && Date().timeIntervalSince(minimizedAt) > 3
        if wantsMinimized { minimizedAt = Date() }
        Self.lookQueue.async {
            let snapshot = WindowList.current()
            let running = Self.runningApps()
            let minimized = wantsMinimized ? Self.minimizedWindows(pids) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let docks = PetalApp.shared.docks!
                    docks.looking = false
                    if let minimized { docks.minimizedCache = minimized }
                    docks.lastRunning = running
                    docks.refresh(with: snapshot)
                    if docks.lookAgain {
                        docks.lookAgain = false
                        docks.refreshInBackground()
                    }
                }
            }
        }
    }

    /// The apps with a place in the dock, by bundle id. Asking each running process for this costs several
    /// milliseconds, so it's done off the main thread with each look at the windows.
    nonisolated private static func runningApps() -> [String: NSRunningApplication] {
        var running: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, running[id] == nil { running[id] = app }
        }
        return running
    }
    @ObservationIgnored private var lastRunning: [String: NSRunningApplication]?
    @ObservationIgnored private var lookAgain = false
    nonisolated private static let lookQueue = DispatchQueue(label: "petal.windows", qos: .userInitiated)
    @ObservationIgnored private var looking = false
    /// The last look at the windows (at most a second old), for refreshes that only change what the dock shows.
    @ObservationIgnored private var lastSnapshot: WindowList?

    /// `quick`: what changed is the mode or a setting, not the windows, so the last look at them does.
    func refresh(quick: Bool = false) {
        refresh(with: quick ? (lastSnapshot ?? WindowList.current()) : Perf.span("refresh: window list") { WindowList.current() })
    }

    func refresh(with snapshot: WindowList) {
        guard shown else { return }
        lastSnapshot = snapshot
        let screens = NSScreen.screens
        let ids = Set(screens.compactMap(\.displayID))
        for (id, panel) in panels where !ids.contains(id) {
            panel.close()
            panels[id] = nil
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // The last list of running apps, less any that quit since (a quit app's dot goes at once).
        let running = Perf.span("refresh: running apps") { (lastRunning ?? Self.runningApps()).filter { !$0.value.isTerminated } }
        if !config.bool("minimized") { minimizedCache = [] }
        let minimizedAll = minimizedCache
        let modesOn = config.bool("modes")
        Perf.span("refresh: launching") { app.updateLaunching(snapshot) }

        for screen in screens {
            guard let id = screen.displayID else { continue }
            let panel = panels[id] ?? DockPanel()
            panels[id] = panel
            let dock = panel.dock
            let desktop = Perf.span("refresh: desktop") { Spaces.desktop(on: screen) }
            if desktop != nil || dock.mode == nil {   // a full-screen app keeps the mode of the Desktop before it
                dock.desktop = desktop
            }
            let mode = modesOn ? config.mode(forDesktop: dock.desktop ?? 1) : config.modes.first
            Perf.span("refresh: set mode") { if mode != dock.mode { dock.mode = mode } }
            let here = Set(snapshot.apps(on: screen))
            let otherModes = Set(config.modes.filter { $0.id != mode?.id }.flatMap(\.apps))

            var items: [DockItem] = []
            func item(_ bundleID: String, pinned: Bool) -> DockItem {
                DockItem(id: bundleID, pinned: pinned, running: running[bundleID] != nil, windows: snapshot.count[bundleID] ?? 0,
                         here: here.contains(bundleID), active: bundleID == frontmost)
            }
            for bundleID in mode?.apps ?? [] where Apps.shows(bundleID) && !items.contains(where: { $0.id == bundleID }) {
                items.append(item(bundleID, pinned: true))
            }
            for bundleID in snapshot.order where running[bundleID] != nil && !items.contains(where: { $0.id == bundleID }) {
                if modesOn && otherModes.contains(bundleID) { continue }
                if config.bool("thisWorkspaceOnly") && !here.contains(bundleID) { continue }
                items.append(item(bundleID, pinned: false))
            }

            // The mode's apps keep the mode's order; the others keep their slot for the session.
            let pinned = items.filter(\.pinned)
            let others = items.filter { !$0.pinned }
            dock.order = dock.order.filter { key in others.contains { $0.id == key } }
            for other in others where !dock.order.contains(other.id) { dock.order.append(other.id) }
            let ordered = pinned + dock.order.compactMap { key in others.first { $0.id == key } }
            Perf.span("refresh: set items") { if ordered != dock.items { dock.items = ordered } }
            if dock.minimized != minimizedAll { dock.minimized = minimizedAll }

            // The stage is as long as the most apps any mode would show here, so switching never moves the rest.
            let longest = Perf.span("refresh: stage") { config.modes.map { m in m.apps.filter(Apps.shows).count }.max() ?? 0 }
            let slots = max(longest, ordered.count) + 1
            if slots != dock.stageSlots { dock.stageSlots = slots }

            Perf.span("refresh: place panel") { panel.place(on: screen) }
        }
        if config.keepWindowsClear && !config.autoHide { Perf.span("refresh: keep windows clear") { keepWindowsClear(snapshot) } }
        Perf.span("refresh: automation") { app.automation.modeShown(dock(for: NSScreen.main)?.mode?.id) }
        Perf.span("refresh: menu bar") { app.menuBar.show(mode: dock(for: NSScreen.main)?.mode) }
        Perf.span("refresh: notes") { app.notes.update() }
    }

    /// macOS keeps no room for a dock other than its own, so windows would run under Petal's. While auto-hide is
    /// off, a window reaching into the dock's strip is shortened to end above it (or narrowed, for a side dock); one
    /// too small to shorten is moved out instead. Omarchy reserves the same strip for its dock.
    private func keepWindowsClear(_ snapshot: WindowList) {
        guard Windows.trusted else { return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        for panel in panels.values {
            guard let screen = panel.screenRef else { continue }
            let icon = max(16, config.number("iconSize"))
            let inset = config.number("iconPadding") >= 0 ? config.number("iconPadding") : 5
            let reserve = panel.gap * 2 + 2 + icon + inset * 2 + 8
            let area = screen.frame
            // The screen in Accessibility's coordinates (top-left origin).
            let screenAX = CGRect(x: area.minX, y: top - area.maxY, width: area.width, height: area.height)
            for window in snapshot.onScreenWindows where screenAX.intersects(window.frame) {
                let f = window.frame
                var target = f
                switch config.position {
                case "left":
                    let limit = screenAX.minX + reserve
                    guard f.minX < limit - 2, f.maxX > limit else { continue }
                    target = f.width - (limit - f.minX) >= 300 ? CGRect(x: limit, y: f.minY, width: f.maxX - limit, height: f.height)
                        : CGRect(x: limit, y: f.minY, width: f.width, height: f.height)
                case "right":
                    let limit = screenAX.maxX - reserve
                    guard f.maxX > limit + 2, f.minX < limit else { continue }
                    target = limit - f.minX >= 300 ? CGRect(x: f.minX, y: f.minY, width: limit - f.minX, height: f.height)
                        : CGRect(x: limit - f.width, y: f.minY, width: f.width, height: f.height)
                default:
                    let limit = screenAX.maxY - reserve
                    guard f.maxY > limit + 2, f.minY < limit else { continue }
                    target = limit - f.minY >= 200 ? CGRect(x: f.minX, y: f.minY, width: f.width, height: limit - f.minY)
                        : CGRect(x: f.minX, y: max(screenAX.minY + 30, limit - f.height), width: f.width, height: f.height)
                }
                guard let ax = Windows.windows(of: window.pid).first(where: { !$0.minimized && $0.frame.equalTo(f, within: 4) }) else { continue }
                Windows.setFrame(ax, target)
            }
        }
    }

    /// Every minimized window of the running apps, across Desktops and modes (off the main thread).
    nonisolated private static func minimizedWindows(_ pids: [pid_t]) -> [AppWindow] {
        guard Windows.trusted else { return [] }
        return pids.flatMap { Windows.windows(of: $0).filter(\.minimized) }
    }

    func dock(for screen: NSScreen?) -> ScreenDock? {
        guard let id = (screen ?? NSScreen.main)?.displayID else { return panels.values.first?.dock }
        return panels[id]?.dock ?? panels.values.first?.dock
    }

    /// The dock on the screen with the window in front: where cards go.
    /// The dock on the screen of the window in front. One screen has one dock; with more, the last look at the
    /// windows (at most a second old) says where the window in front is, so asking costs nothing.
    var focusedDock: ScreenDock? {
        if panels.count == 1 { return panels.values.first?.dock }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let frame = (lastSnapshot ?? WindowList.current()).onScreenFrames(pid: front.processIdentifier).first
        else { return dock(for: NSScreen.main) }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let center = CGPoint(x: frame.midX, y: top - frame.midY)
        return dock(for: NSScreen.screens.first { $0.frame.contains(center) })
    }

    func revealAll() {
        for panel in panels.values { panel.reveal() }
    }

    // MARK: Opening apps

    /// No windows: launch it. Windows: bring one forward, cycling through them on repeated clicks: this Desktop's
    /// first, then minimized ones, then the rest. The pointer never moves.
    func activate(_ item: DockItem) {
        if Sites.isWeb(item.id) { Sites.open(item.id); return }
        guard item.running, let running = NSRunningApplication.runningApplications(withBundleIdentifier: item.id).first else {
            launch(item.id)
            return
        }
        if Perf.span("activate: parking", { Parking.activate(item.id) }) { return }   // each mode keeps its own windows
        let windows = Perf.span("activate: windows (AX)") { Windows.windows(of: running.processIdentifier) }
        guard !windows.isEmpty else {
            if item.windows == 0 { launch(item.id) } else { Windows.bringForward(running) }
            return
        }
        let onScreen = (lastSnapshot ?? WindowList.current()).onScreenFrames(pid: running.processIdentifier)
        func rank(_ w: AppWindow) -> Int { w.minimized ? 1 : (onScreen.contains { $0.equalTo(w.frame, within: 4) } ? 0 : 2) }
        let sorted = windows.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        var pick = sorted[0]
        if item.active {
            let focused = Windows.frontTitle()
            if let index = sorted.firstIndex(where: { $0.title == focused && !$0.minimized }) { pick = sorted[(index + 1) % sorted.count] }
        }
        Perf.span("activate: focus") { Windows.focus(pick, onScreen: rank(pick) == 0) }
    }

    func launch(_ id: String, files: [URL] = []) {
        guard let url = Apps.url(id) else { return }
        app.launching[id] = (Date(), (lastSnapshot ?? WindowList.current()).count[id] ?? 0)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if files.isEmpty {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } else {
            NSWorkspace.shared.open(files, withApplicationAt: url, configuration: configuration)
        }
    }

    /// New window: the app comes forward and gets ⌘N, as its own File menu would.
    func newWindow(_ id: String) {
        if Sites.isWeb(id) { Sites.open(id); return }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { launch(id); return }
        Windows.bringForward(running)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0x2D, keyDown: down)   // N
                event?.flags = .maskCommand
                event?.postToPid(running.processIdentifier)
            }
        }
    }

    func quit(_ id: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) { app.terminate() }
    }

    func minimizeAll(_ id: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
            for window in Windows.windows(of: app.processIdentifier) where !window.minimized { Windows.minimize(window) }
        }
    }

    func hide(_ id: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) { app.hide() }
    }

    // MARK: Reordering

    /// Dropping an app at a new place saves the new order as the mode's apps. Dragging an app that isn't in the
    /// mode into place adds it.
    func move(_ id: String, to index: Int, in dock: ScreenDock) {
        guard let mode = dock.mode, let from = dock.items.firstIndex(where: { $0.id == id }) else { return }
        var keys = dock.items.map(\.id)
        keys.remove(at: from)
        keys.insert(id, at: min(max(0, index), keys.count))
        let shown = keys.filter { key in key == id || dock.items.first { $0.id == key }?.pinned == true }
        var updated = mode
        updated.apps = shown + mode.apps.filter { !shown.contains($0) }
        config.save(updated)
    }
}

/// Which apps have normal windows, and where: from the window server, which needs no permission for owners and
/// frames (never titles or contents).
struct WindowList {
    var count: [String: Int] = [:]
    var order: [String] = []                      // apps by their first window
    private var onScreen: [(bundleID: String, pid: pid_t, frame: CGRect)] = []

    static func current() -> WindowList {
        var list = WindowList()
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        var ids: [pid_t: String] = [:]
        for window in info.reversed() {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width > 60, bounds.height > 60,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            let bundleID: String
            if let known = ids[pid] { bundleID = known } else {
                if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular, let id = app.bundleIdentifier {
                    bundleID = id
                } else {
                    bundleID = ""
                }
                ids[pid] = bundleID
            }
            guard !bundleID.isEmpty else { continue }
            let isOnScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
            list.count[bundleID, default: 0] += 1
            if isOnScreen { list.onScreen.append((bundleID, pid, bounds)) }
            if !list.order.contains(bundleID) { list.order.append(bundleID) }
        }
        return list
    }

    /// Apps with a window on the Desktop `screen` shows. Window frames count from the top of the main screen.
    func apps(on screen: NSScreen) -> [String] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        var result: [String] = []
        for window in onScreen {
            let center = CGPoint(x: window.frame.midX, y: top - window.frame.midY)
            if screen.frame.contains(center), !result.contains(window.bundleID) { result.append(window.bundleID) }
        }
        return result
    }

    func onScreenFrames(pid: pid_t) -> [CGRect] { onScreen.filter { $0.pid == pid }.map(\.frame) }

    /// Every app window on screen, top-left origin as Accessibility counts.
    var onScreenWindows: [(pid: pid_t, frame: CGRect)] { onScreen.map { ($0.pid, $0.frame) } }
}

extension CGRect {
    func equalTo(_ other: CGRect, within tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) < tolerance && abs(minY - other.minY) < tolerance
            && abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
}

// MARK: - The panel

/// The panel a dock lives in: borderless, see-through, above windows, on every Desktop (not over full-screen apps),
/// never taking focus from the app in front.
@MainActor
final class DockPanel: NSPanel {
    let dock = ScreenDock()
    private var hosting: DockHostingView!
    private var measured: CGSize?
    private var hideAt: Date?
    private var mouseTimer: Timer?
    private(set) weak var screenRef: NSScreen?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        dock.panel = self
        hosting = DockHostingView(rootView: AnyView(DockView(dock: dock).environment(PetalApp.shared)))
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
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followMouse() }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func close() {
        mouseTimer?.invalidate()
        super.close()
    }

    var config: Config { PetalApp.shared.config }

    /// The glass itself, without the clear room around it for lifting and bouncing icons: tooltips, previews and
    /// stacks sit just above this, as they do over macOS's Dock.
    var glassFrame: CGRect {
        let room = DockView.outer(config)
        return CGRect(x: frame.minX + room.leading, y: frame.minY + room.bottom,
                      width: frame.width - room.leading - room.trailing, height: frame.height - room.top - room.bottom)
    }

    /// The gap between the dock and the screen's edge (Omarchy's `gap`).
    var gap: CGFloat { config.number("dockMargin") >= 0 ? config.number("dockMargin") : 4 }

    /// Something open over the dock keeps it out while auto-hide is on.
    var busy: Bool { dock.openPopup != nil || dock.dragging != nil || PetalApp.shared.overlayOpen }

    var tucked: Bool { config.autoHide && !dock.revealed && !busy }

    func place(on screen: NSScreen) {
        screenRef = screen
        // Measured again only when the dock's content says its size may have changed: once a second, nothing has.
        let size: CGSize
        if let measured, !hosting.sizeChanged {
            size = measured
        } else {
            hosting.layoutSubtreeIfNeeded()
            size = hosting.fittingSize
            measured = size
            hosting.sizeChanged = false
        }
        let area = screen.frame
        let visible = screen.visibleFrame
        var origin: CGPoint
        switch config.position {
        case "left": origin = CGPoint(x: area.minX + gap, y: visible.midY - size.height / 2)
        case "right": origin = CGPoint(x: area.maxX - size.width - gap, y: visible.midY - size.height / 2)
        default: origin = CGPoint(x: area.midX - size.width / 2, y: area.minY + gap)
        }
        // Tucked away, it slides a little toward the edge and fades out (sliding off the edge would put it on a
        // display arranged next to this one).
        let shift: CGFloat = tucked ? 12 : 0
        switch config.position {
        case "left": origin.x -= shift
        case "right": origin.x += shift
        default: origin.y -= shift
        }
        ignoresMouseEvents = tucked
        let alpha: CGFloat = tucked ? 0 : 1
        if alphaValue != alpha {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = tucked ? 0.12 : 0.18
                animator().alphaValue = alpha
            }
        }
        let frame = NSRect(origin: origin, size: size).integral
        guard frame != self.frame else { return }
        if self.frame.size == .zero || frame.size != self.frame.size {
            setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = tucked ? 0.12 : 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(frame, display: true)
            }
        }
    }

    func reveal() {
        dock.revealed = true
        if let screenRef { place(on: screenRef) }
    }

    /// The slot `id` in screen coordinates.
    func screenFrame(of id: String) -> CGRect? {
        guard let rect = dock.frames[id] else { return nil }
        return CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Auto-hide: the dock comes out when the pointer meets its edge, and goes 150 ms after it leaves.
    private func followMouse() {
        guard config.autoHide, let screen = screenRef else {
            if !dock.revealed { dock.revealed = true }
            if frame.contains(NSEvent.mouseLocation) { dock.magnifier.wake() }
            return
        }
        let mouse = NSEvent.mouseLocation
        let area = screen.frame
        let depth: CGFloat = 3
        let atEdge: Bool
        switch config.position {
        case "left": atEdge = mouse.x <= area.minX + depth && mouse.y >= area.minY && mouse.y <= area.maxY
        case "right": atEdge = mouse.x >= area.maxX - depth && mouse.y >= area.minY && mouse.y <= area.maxY
        default: atEdge = mouse.y <= area.minY + depth && mouse.x >= area.minX && mouse.x <= area.maxX
        }
        let over = frame.insetBy(dx: -8, dy: -8).contains(mouse)
        if over && !tucked { dock.magnifier.wake() }
        if !dock.revealed && atEdge {
            dock.revealed = true
            place(on: screen)
        } else if dock.revealed && !over && !atEdge && !busy {
            if hideAt == nil { hideAt = Date().addingTimeInterval(0.15) }
            if let hideAt, Date() >= hideAt {
                dock.revealed = false
                self.hideAt = nil
                place(on: screen)
            }
        } else {
            hideAt = nil
        }
    }
}

// MARK: - The view

struct DockView: View {
    @Environment(PetalApp.self) private var app
    @Environment(\.snapshotting) private var snapshotting
    let dock: ScreenDock

    var config: Config { app.config }
    var icon: CGFloat { max(16, config.number("iconSize")) }
    var inset: CGFloat { config.number("iconPadding") >= 0 ? config.number("iconPadding") : 5 }
    var slot: CGFloat { icon + inset * 2 }

    var body: some View {
        let layout = dock.vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        let modesOn = config.bool("modes") && !config.modes.isEmpty
        let stacks = Stacks.resolve(config.strings("stackFolders"))
        let extras = (config.bool("nowPlaying") && app.signals.nowPlaying != nil) || !dock.minimized.isEmpty
            || (config.bool("stacks") && !stacks.isEmpty) || config.bool("trash")
        let row = layout {
            if modesOn {
                ModeSwitcher(dock: dock, size: icon * 0.95).padding(dock.vertical ? .vertical : .horizontal, 6)
                    .magnified(dock, "switcher", scales: false)
            }
            if !app.providers.isEmpty && (config.bool("ai") || config.bool("claudeUsage")) {
                ClaudeButton(dock: dock, size: icon * 0.95).frame(width: slot, height: slot).magnified(dock, "claude")
            }
            if modesOn { Separator(vertical: dock.vertical, slot: slot).magnified(dock, "separator:modes", scales: false) }
            stage(layout)
            if extras { Separator(vertical: dock.vertical, slot: slot).magnified(dock, "separator:extras", scales: false) }
            if config.bool("nowPlaying"), let playing = app.signals.nowPlaying {
                NowPlayingSlot(dock: dock, playing: playing, icon: icon).frame(width: slot, height: slot).magnified(dock, "media")
            }
            ForEach(dock.minimized) { window in
                MinimizedSlot(dock: dock, window: window, icon: icon).frame(width: slot, height: slot)
                    .magnified(dock, "min:\(window.id)")
            }
            if config.bool("stacks") {
                ForEach(stacks, id: \.self) { folder in
                    StackSlot(dock: dock, folder: folder, icon: icon).frame(width: slot, height: slot).magnified(dock, "stack:\(folder)")
                }
            }
            if config.bool("trash") { TrashSlot(dock: dock, icon: icon).frame(width: slot, height: slot).magnified(dock, "trash") }
        }
        .padding(4)
        .background { if !snapshotting { RightClickCatcher { Menus.settings(for: dock) } } }
        .modifier(DockGlass(dock: dock, glass: glass, radius: radius))
        // A container would lift the stretching glass above the icons; there's only the one glass to hold anyway.
        Group {
            if Magnifier.enabled { row } else { GlassEffectContainer { row } }
        }
        .padding(outer)
        .fixedSize()
        .animation(.easeOut(duration: 0.22), value: dock.items.map(\.id))
        .animation(.easeOut(duration: 0.22), value: dock.minimized.map(\.id))
    }

    /// Room around the glass: for its shadow, and inward for icons lifting and bouncing.
    /// With magnification, it's room for the largest icons too, so the panel never resizes while they grow.
    private var outer: EdgeInsets { Self.outer(config) }

    /// The room around the glass (see `outer`), for anything placed by the glass rather than by the panel.
    static func outer(_ config: Config) -> EdgeInsets {
        let icon = max(16, config.number("iconSize"))
        let slot = icon + (config.number("iconPadding") >= 0 ? config.number("iconPadding") : 5) * 2
        var room = icon * 0.55
        var along: CGFloat = 10
        if Magnifier.enabled {
            room = max(room, slot * Magnifier.amount + 6)
            along += Magnifier.room(slot: slot, amount: Magnifier.amount)
        }
        switch config.position {
        case "left": return EdgeInsets(top: along, leading: 2, bottom: along, trailing: room)
        case "right": return EdgeInsets(top: along, leading: room, bottom: along, trailing: 2)
        default: return EdgeInsets(top: room, leading: along, bottom: 2, trailing: along)
        }
    }

    private var glass: Glass {
        guard let tint = NSColor(hex: config.string("dockColor")) else { return .regular }
        return .regular.tint(Color(nsColor: tint).opacity(max(0.15, config.number("dockOpacity"))))
    }

    private var radius: CGFloat {
        let setting = config.number("dockRadius")
        return setting >= 0 ? min(setting, (slot + 8) / 2) : (slot + 8) / 2.6
    }

    /// The mode's apps, the rest, and "+", centered on a stage as long as the fullest mode.
    @ViewBuilder private func stage(_ layout: AnyLayout) -> some View {
        let length = CGFloat(dock.stageSlots) * slot
        layout {
            ForEach(Array(dock.items.enumerated()), id: \.element.id) { index, item in
                AppSlot(dock: dock, item: item, index: index, icon: icon, slot: slot)
                    .frame(width: slot, height: slot)
                    .magnified(dock, item.id)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
            AddSlot(dock: dock, icon: icon).frame(width: slot, height: slot).magnified(dock, "add")
        }
        .frame(width: dock.vertical ? slot : length, height: dock.vertical ? length : slot)
    }
}

struct Separator: View {
    let vertical: Bool
    let slot: CGFloat

    var body: some View {
        let on = PetalApp.shared.config.bool("separators")
        Rectangle()
            .fill(.white.opacity(on ? 0.22 : 0))
            .frame(width: vertical ? slot * 0.6 : 1, height: vertical ? 1 : slot * 0.6)
            .padding(vertical ? .vertical : .horizontal, 8)
    }
}

/// Records a slot's frame in the panel, for popups and tooltips to sit over it.
struct SlotFrame: ViewModifier {
    let dock: ScreenDock
    let id: String

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dock.frames[id] = $0 }
    }
}

extension View {
    func slotFrame(_ dock: ScreenDock, _ id: String) -> some View { modifier(SlotFrame(dock: dock, id: id)) }

    /// The icon lifts and grows inward under the pointer.
    func lift(_ hovering: Bool, icon: CGFloat) -> some View {
        let config = PetalApp.shared.config
        // Magnification takes lift's place.
        let amount = config.bool("hoverLift") && !Magnifier.enabled && hovering ? config.number("hoverLiftAmount") : 0
        let position = config.position
        let shift = icon * amount * 1.2
        return scaleEffect(1 + amount, anchor: position == "left" ? .leading : position == "right" ? .trailing : .bottom)
            .offset(x: position == "left" ? shift : position == "right" ? -shift : 0, y: position == "bottom" ? -shift : 0)
            .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

// The mode switcher is in Switcher.swift.

// MARK: - Claude button

struct ClaudeButton: View {
    @Environment(PetalApp.self) private var app
    let dock: ScreenDock
    let size: CGFloat
    @State private var hovering = false

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(hovering ? 0.16 : 0.07)).overlay(Circle().strokeBorder(.white.opacity(0.14)))
            ProviderMark(provider: app.chatProvider).foregroundStyle(.white.opacity(0.9))
                .frame(width: size * 0.56, height: size * 0.56).scaleEffect(hovering ? 1.08 : 1)
            if app.config.bool("claudeUsage") { UsageRing(usage: app.usage, size: size, line: 2.5, track: false) }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .slotFrame(dock, "claude")
        .slotMouse(SlotMouse(left: { app.claude.open(asking: nil) }, right: { Menus.settings(for: dock) },
                           hover: { on in
                               hovering = on
                               app.tooltips.show(on ? app.usageTooltip : nil, over: "claude", in: dock)
                           }))
    }
}

/// Claude's mark, from Petal's own assets.
struct ClaudeMark: View {
    static let image: NSImage? = Bundle.main.url(forResource: "claude", withExtension: "svg").flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "sparkle").resizable().scaledToFit().foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
        }
    }
}

/// How much of the fullest Claude limit is used: the accent, then amber, then red as it fills.
struct UsageRing: View {
    let usage: Usage
    var size: CGFloat = 64
    var line: CGFloat = 6
    var track = true

    static func color(_ used: Double) -> Color {
        used >= 0.9 ? Color(red: 1, green: 0.30, blue: 0.43) : used >= 0.7 ? Color(red: 1, green: 0.70, blue: 0.28)
            : Color(nsColor: PetalApp.shared.accent)
    }

    var body: some View {
        let used = usage.worst?.percent
        ZStack {
            if track { Circle().stroke(.white.opacity(0.15), lineWidth: line) }
            if let used {
                Circle().trim(from: 0, to: max(0.02, used))
                    .stroke(Self.color(used), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if track {
                Text(used.map { "\(Int(((1 - $0) * 100).rounded()))%" } ?? "–")
                    .font(.system(size: size * 0.24, weight: .semibold).monospacedDigit())
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Apps

struct AppSlot: View {
    @Environment(PetalApp.self) private var app
    let dock: ScreenDock
    let item: DockItem
    let index: Int
    let icon: CGFloat
    let slot: CGFloat
    @State private var hovering = false
    @State private var fileOver = false
    @State private var hop: CGFloat = 0

    var body: some View {
        let config = app.config
        let dragged = dock.dragging == item.id
        let color = Color(nsColor: config.bool("appGlow") ? AppColor.of(item.id) : app.accent)
        let launching = app.launching[item.id] != nil
        ZStack {
            if config.bool("appGlow") && item.running {
                RadialGradient(colors: [color.opacity(0.55), color.opacity(0.18), .clear], center: .center,
                               startRadius: 0, endRadius: slot * 0.62)
                    .opacity((item.active ? 0.75 : hovering ? 0.55 : 0.32) * min(1, max(0, config.number("glowStrength"))))
                    .animation(.easeOut(duration: 0.2), value: item.active)
            }
            DockIcon(id: item.id, size: icon)
                .opacity((item.running || !item.pinned || Sites.isWeb(item.id) ? 1 : config.number("idleOpacity")) * (fileOver ? 0.6 : 1))
                .modifier(Pulse(on: launching, floor: config.number("idleOpacity")))
                .overlay(alignment: .topTrailing) {
                    if config.bool("badges"), let badge = app.signals.badges[item.id] {
                        Badge(text: badge, icon: icon).offset(x: icon * 0.12, y: -icon * 0.12)
                    }
                }
        }
        .scaleEffect(dragged || fileOver ? 1.18 : 1)
        .lift(hovering && dock.dragging == nil, icon: icon)
        .offset(hopOffset)
        .overlay(alignment: dotAlignment) {
            if item.windows > 0 && !dragged {
                Capsule().fill(color)
                    .frame(width: dock.vertical ? dot : dot * (item.windows > 1 ? 2.6 : 1),
                           height: dock.vertical ? dot * (item.windows > 1 ? 2.6 : 1) : dot)
                    .opacity(item.here || item.active ? 1 : 0.4)
                    .padding(1)
                    .animation(.easeOut(duration: 0.15), value: item.windows)
            }
        }
        .offset(dragShift)
        .zIndex(dragged ? 10 : 0)
        .slotFrame(dock, item.id)
        .slotMouse(SlotMouse(
            left: { app.popups.closeAll(); app.docks.activate(item) },
            right: { Menus.app(item, in: dock) },
            middle: { app.docks.newWindow(item.id) },
            hover: { on in
                hovering = on
                app.tooltips.show(on ? Apps.name(item.id) : nil, over: item.id, in: dock)
                app.previews.hover(on ? item : nil, in: dock, id: item.id)
                if on && app.config.bool("recentFiles") { Apps.prefetchRecent(item.id) }
            },
            drag: { delta, ended in drag(delta, ended: ended) },
            files: config.bool("dropToOpen") ? { urls in app.docks.launch(item.id, files: urls) } : nil,
            fileOver: { fileOver = $0 }))
        .onChange(of: app.signals.bounces[item.id]) { _, _ in bounce() }
    }

    private var dot: CGFloat { max(4, icon * 0.13) }

    private var dotAlignment: Alignment {
        switch app.config.position { case "left": .leading; case "right": .trailing; default: .bottom }
    }

    /// The hop goes inward, away from the screen's edge.
    private var hopOffset: CGSize {
        let distance = hop * icon * 0.5
        switch app.config.position {
        case "left": return CGSize(width: distance, height: 0)
        case "right": return CGSize(width: -distance, height: 0)
        default: return CGSize(width: 0, height: -distance)
        }
    }

    /// While an app is dragged, it follows the pointer and the apps it passes make room.
    private var dragShift: CGSize {
        guard let dragging = dock.dragging, let from = dock.items.firstIndex(where: { $0.id == dragging }) else { return .zero }
        var shift: CGFloat = 0
        if dragging == item.id {
            shift = dock.dragOffset
        } else {
            let to = from + Int((dock.dragOffset / slot).rounded())
            if from < index && index <= to { shift = -slot }
            if to <= index && index < from { shift = slot }
        }
        return dock.vertical ? CGSize(width: 0, height: shift) : CGSize(width: shift, height: 0)
    }

    private func drag(_ delta: CGFloat, ended: Bool) {
        if ended {
            if dock.dragging == item.id, let from = dock.items.firstIndex(where: { $0.id == item.id }) {
                let to = min(max(0, from + Int((dock.dragOffset / slot).rounded())), dock.items.count - 1)
                if to != from || !item.pinned { app.docks.move(item.id, to: to, in: dock) }
            }
            withAnimation(.easeOut(duration: 0.15)) { dock.dragging = nil; dock.dragOffset = 0 }
            return
        }
        if dock.dragging == nil {
            guard abs(delta) >= 6 else { return }
            app.popups.closeAll()
            app.previews.hover(nil, in: dock, id: item.id)
            app.tooltips.hide()
            dock.dragging = item.id
        }
        dock.dragOffset = delta
    }

    private func bounce() {
        guard app.config.bool("bounce"), !item.active else { return }
        withAnimation(.easeOut(duration: 0.22)) { hop = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.interpolatingSpring(stiffness: 260, damping: 9)) { hop = 0 }
        }
    }
}

/// An app's icon, or a website shortcut's (the site's icon, with a globe badge).
struct DockIcon: View {
    let id: String
    let size: CGFloat

    var body: some View {
        if Sites.isWeb(id) {
            SiteIcon(id: id, size: size)
        } else {
            Image(nsImage: Apps.icon(id)).resizable().interpolation(.high).frame(width: size, height: size)
        }
    }
}

/// Opacity 1 → idle → 1, half a second each way, while an app is launching.
struct Pulse: ViewModifier {
    let on: Bool
    let floor: Double
    @State private var low = false

    func body(content: Content) -> some View {
        content.opacity(on && low ? floor : 1)
            .animation(on ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default, value: low)
            .onChange(of: on, initial: true) { _, now in low = now }
    }
}

struct Badge: View {
    let text: String
    let icon: CGFloat

    var body: some View {
        let height = icon * 0.42
        let label = (Int(text) ?? 0) > 99 ? "99+" : text
        Text(label)
            .font(.system(size: height * 0.62, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: height, minHeight: height)
            .background(Color(red: 1, green: 0.23, blue: 0.5), in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
            .fixedSize()
    }
}

/// An app's own color, sampled from its icon: the saturated pixels count most, kept light enough to glow.
@MainActor
enum AppColor {
    private static var cache: [String: NSColor] = [:]

    static func of(_ id: String) -> NSColor {
        if let color = cache[id] { return color }
        let color = sample(Apps.icon(id)) ?? PetalApp.shared.accent
        cache[id] = color
        return color
    }

    private static func sample(_ image: NSImage) -> NSColor? {
        let side = 16
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0, pr = 0.0, pg = 0.0, pb = 0.0, plain = 0.0
        for x in 0..<side {
            for y in 0..<side {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent >= 0.5 else { continue }
                let maxC = max(c.redComponent, c.greenComponent, c.blueComponent)
                let minC = min(c.redComponent, c.greenComponent, c.blueComponent)
                let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
                let w = saturation * saturation * c.alphaComponent
                r += c.redComponent * w; g += c.greenComponent * w; b += c.blueComponent * w; weight += w
                pr += c.redComponent; pg += c.greenComponent; pb += c.blueComponent; plain += 1
            }
        }
        let base: NSColor
        if weight >= 3 { base = NSColor(red: r / weight, green: g / weight, blue: b / weight, alpha: 1) }
        else if plain > 0 { base = NSColor(red: pr / plain, green: pg / plain, blue: pb / plain, alpha: 1) }
        else { return nil }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        (base.usingColorSpace(.sRGB) ?? base).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        let gray = saturation < 0.08
        return NSColor(hue: gray ? 0.92 : hue, saturation: gray ? 0.6 : max(0.55, saturation),
                       brightness: min(0.98, max(0.82, brightness)), alpha: 1)
    }
}

/// "+": add apps or folders to this Desktop's mode.
struct AddSlot: View {
    @Environment(PetalApp.self) private var app
    let dock: ScreenDock
    let icon: CGFloat
    @State private var hovering = false

    var body: some View {
        let color = Color(nsColor: dock.mode?.color ?? PetalApp.shared.accent)
        ZStack {
            RoundedRectangle(cornerRadius: icon * 0.8 * 0.28)
                .fill(.white.opacity(hovering ? 0.14 : 0.07))
                .overlay(RoundedRectangle(cornerRadius: icon * 0.8 * 0.28).strokeBorder(.white.opacity(0.22)))
                .frame(width: icon * 0.8, height: icon * 0.8)
            Image(systemName: "plus").font(.system(size: icon * 0.36, weight: .bold)).foregroundStyle(color)
        }
        .lift(hovering, icon: icon)
        .slotFrame(dock, "add")
        .slotMouse(SlotMouse(left: { app.popups.closeAll(); app.search.open(in: dock) }, right: { Menus.settings(for: dock) },
                           hover: { on in
                               hovering = on
                               app.tooltips.show(on ? (dock.mode.map { "Add apps to \($0.name)" } ?? "Add apps") : nil, over: "add", in: dock)
                           }))
    }
}

// MARK: - Extras

struct NowPlayingSlot: View {
    @Environment(PetalApp.self) private var app
    let dock: ScreenDock
    let playing: NowPlaying
    let icon: CGFloat
    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: icon * 0.24).fill(.white.opacity(0.08))
            if let artwork = app.signals.artwork {
                Image(nsImage: artwork).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: icon * 0.5)).foregroundStyle(Color(nsColor: app.accent))
            }
            if hovering || !playing.playing {
                Color.black.opacity(0.38)
                Image(systemName: playing.playing ? "pause.fill" : "play.fill").font(.system(size: icon * 0.36)).foregroundStyle(.white)
            }
        }
        .frame(width: icon, height: icon)
        .clipShape(.rect(cornerRadius: icon * 0.24))
        .overlay(alignment: .bottom) {
            if playing.playing { Equalizer(icon: icon).offset(y: icon * 0.22) }
        }
        .lift(hovering, icon: icon)
        .slotFrame(dock, "media")
        .slotMouse(SlotMouse(left: { NowPlaying.send("playpause", to: playing.player) },
                           right: { Menus.media(playing) },
                           middle: { NowPlaying.send("next track", to: playing.player) },
                           hover: { on in
                               hovering = on
                               app.tooltips.show(on ? "\(playing.title) — \(playing.artist)" : nil, over: "media", in: dock)
                           }))
    }
}

struct Equalizer: View {
    let icon: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3) { i in
                    let period = 0.52 + Double(i) * 0.16
                    let phase = (sin(t * .pi * 2 / period) + 1) / 2
                    Capsule().fill(Color(nsColor: PetalApp.shared.accent))
                        .frame(width: 2, height: max(2, max(4, icon * 0.16) * (i == 1 ? 1 : 0.7) * phase))
                }
            }
            .frame(height: max(4, icon * 0.16), alignment: .bottom)
        }
    }
}

struct MinimizedSlot: View {
    @Environment(PetalApp.self) private var app
    let dock: ScreenDock
    let window: AppWindow
    let icon: CGFloat
    @State private var hovering = false

    var body: some View {
        let bundleID = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier ?? ""
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: icon * 0.18).fill(.black.opacity(0.3))
                .overlay(RoundedRectangle(cornerRadius: icon * 0.18).strokeBorder(.white.opacity(0.25)))
                .overlay {
                    if let thumb = app.previews.thumbnails[window.id] {
                        Image(nsImage: thumb).resizable().scaledToFit().padding(3)
                    } else {
                        Image(systemName: "macwindow").font(.system(size: icon * 0.4)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: icon + 4, height: icon + 4)
            Image(nsImage: Apps.icon(bundleID)).resizable().frame(width: icon * 0.5, height: icon * 0.5)
                .offset(x: icon * 0.15, y: icon * 0.15)
        }
        .lift(hovering, icon: icon)
        .slotFrame(dock, "min:\(window.id)")
        .onAppear { app.previews.snapshot(window) }
        .slotMouse(SlotMouse(left: { Windows.focus(window) }, right: { Windows.focus(window) }, middle: { Windows.close(window) },
                           hover: { on in
                               hovering = on
                               app.tooltips.show(on ? "\(window.title) (minimized)" : nil, over: "min:\(window.id)", in: dock)
                           }))
    }
}

struct StackSlot: View {
    @Environment(PetalApp.self) private var app
    let dock: ScreenDock
    let folder: String
    let icon: CGFloat
    @State private var hovering = false

    var body: some View {
        let key = "stack:\(folder)"
        ZStack {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Stacks.url(folder).path)).resizable().frame(width: icon, height: icon)
            if app.config.bool("progress"), let progress = app.signals.progress[folder] {
                Circle().stroke(.white.opacity(0.18), lineWidth: 3).frame(width: icon + 8, height: icon + 8)
                Circle().trim(from: 0, to: max(0.02, progress))
                    .stroke(Color(nsColor: app.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: icon + 8, height: icon + 8)
            }
        }
        .lift(hovering, icon: icon)
        .overlay(alignment: .bottom) {
            if dock.openPopup == key { Circle().fill(Color(nsColor: app.accent)).frame(width: 4, height: 4).offset(y: 5) }
        }
        .slotFrame(dock, key)
        .slotMouse(SlotMouse(left: { app.popups.toggleStack(folder, in: dock) },
                           right: { Menus.stack(folder) },
                           middle: { NSWorkspace.shared.open(Stacks.url(folder)) },
                           hover: { on in
                               hovering = on
                               app.tooltips.show(on ? Stacks.name(folder) : nil, over: key, in: dock)
                           }))
    }
}

struct TrashSlot: View {
    @Environment(PetalApp.self) private var app
    let dock: ScreenDock
    let icon: CGFloat
    @State private var hovering = false
    @State private var fileOver = false

    var body: some View {
        let empty = app.signals.trashEmpty
        Image(nsImage: NSImage(named: empty ? NSImage.trashEmptyName : NSImage.trashFullName) ?? NSImage())
            .resizable().frame(width: icon, height: icon)
            .scaleEffect(fileOver ? 1.2 : 1)
            .lift(hovering, icon: icon)
            .slotFrame(dock, "trash")
            .slotMouse(SlotMouse(left: { Stacks.openTrash() }, right: { Menus.trash() },
                               hover: { on in
                                   hovering = on
                                   app.tooltips.show(on ? "Trash" : nil, over: "trash", in: dock)
                               },
                               files: { Stacks.moveToTrash($0) }, fileOver: { fileOver = $0 }))
    }
}

/// A slot's mouse: left, right and middle clicks, hover, dragging along the dock, and files dropped on it. AppKit
/// does this directly, since the dock never becomes the key window.
struct SlotMouse: NSViewRepresentable {
    var left: () -> Void = {}
    var right: () -> Void = {}
    var middle: () -> Void = {}
    var hover: (Bool) -> Void = { _ in }
    var drag: ((CGFloat, Bool) -> Void)? = nil
    var files: (([URL]) -> Void)? = nil
    var fileOver: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> MouseView { MouseView() }
    func updateNSView(_ view: MouseView, context: Context) { view.handlers = self }

    final class MouseView: NSView {
        var handlers: SlotMouse? {
            didSet {
                let wantsFiles = handlers?.files != nil
                if wantsFiles != registered {
                    if wantsFiles { registerForDraggedTypes([.fileURL]) } else { unregisterDraggedTypes() }
                    registered = wantsFiles
                }
            }
        }
        private var registered = false
        private var down: NSPoint?
        private var dragging = false
        private var area: NSTrackingArea?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let new = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(new)
            area = new
        }

        override func mouseEntered(with event: NSEvent) {
            (window as? DockPanel)?.dock.magnifier.wake()
            handlers?.hover(true)
        }
        override func mouseExited(with event: NSEvent) { handlers?.hover(false) }

        override func mouseDown(with event: NSEvent) {
            down = NSEvent.mouseLocation
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down, let drag = handlers?.drag else { return }
            let point = NSEvent.mouseLocation
            let vertical = PetalApp.shared.config.position != "bottom"
            let delta = vertical ? down.y - point.y : point.x - down.x
            if abs(point.x - down.x) > 4 || abs(point.y - down.y) > 4 { dragging = true }
            if dragging { drag(delta, false) }
        }

        override func mouseUp(with event: NSEvent) {
            if dragging { handlers?.drag?(0, true) } else { handlers?.left() }
            down = nil
            dragging = false
        }

        override func rightMouseDown(with event: NSEvent) { handlers?.right() }

        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 { handlers?.middle() }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            handlers?.fileOver(true)
            PetalApp.shared.docks.revealAll()
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { handlers?.fileOver(false) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            handlers?.fileOver(false)
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty, let files = handlers?.files else { return false }
            files(urls)
            return true
        }
    }
}

/// Right-clicking the dock's empty glass.
struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: (() -> Void)?
        override func rightMouseDown(with event: NSEvent) { action?() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

struct ModeIcon: View {
    let icon: String
    let size: CGFloat

    var body: some View {
        if NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
        } else {
            Text(icon.isEmpty ? "●" : icon).font(.system(size: size))   // a Nerd Font glyph from an Omarchy modes.json
        }
    }
}

/// The dock's hosting view, which notes when SwiftUI says its content's size may have changed, so the dock is
/// measured only then.
final class DockHostingView: NSHostingView<AnyView> {
    var sizeChanged = true

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        sizeChanged = true
    }
}
