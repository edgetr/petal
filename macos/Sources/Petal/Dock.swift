import AppKit
import Observation
import SwiftUI

/// An app in the dock.
struct DockItem: Identifiable, Equatable {
    let id: String          // bundle identifier
    let pinned: Bool        // one of the dock's apps (dock.json), not just running
    var running: Bool
    var windows: Int        // its normal windows, anywhere
    var here: Bool          // one of them is on this screen's Desktop
    var active: Bool        // the app in front
}

/// What one screen's dock shows.
@MainActor @Observable
final class ScreenDock {
    var desktop: Int?
    var items: [DockItem] = [] {
        didSet {
            if items.count != appCount { appCount = items.count }
            let ids = items.map(\.id)
            if ids != itemIDs { itemIDs = ids }
        }
    }
    /// The apps' ids in order, changing only when they do (not when an app comes forward or gains a window): the
    /// dock animates its glass by it.
    private(set) var itemIDs: [String] = []
    /// How many apps `items` holds, changing only when that does: "+" over the layer strip goes after them, and
    /// watching this instead of `items` keeps an app coming forward from updating it.
    private(set) var appCount = 0
    var minimized: [AppWindow] = []
    var stageSlots = 0
    /// Finder, for its own button (FinderButton): running, its windows, in front.
    var finder = DockItem(id: DockController.finder, pinned: true, running: true, windows: 0, here: false, active: false)
    /// The icons' size here: the setting's, or smaller when that many wouldn't fit along the screen's edge (as
    /// macOS's Dock does). DockPanel.place works it out.
    var icon: CGFloat = 36
    var dragging: String?
    var dragOffset: CGFloat = 0
    /// The dragged app looks out of the dock (one of its own, past the glass by more than a slot: let go, it's
    /// removed). Only how it looks: letting go goes by where the pointer is (`DockRules.dragEnd`).
    var dragOut = false
    var revealed = true
    var openPopup: String?          // the slot whose stack, preview or menu is open
    @ObservationIgnored var order: [String] = []
    @ObservationIgnored var frames: [String: CGRect] = [:]   // slot frames in the panel, top-left origin
    /// The glass as SwiftUI lays it out and animates it, frame by frame (panel coordinates, top-left origin),
    /// whatever the panel last measured: where the dock takes the mouse is decided from it
    /// (`DockPanel.updateMouseThrough`), at once whenever it changes.
    ///
    /// SwiftUI reports the new layout at once, while it draws the glass growing or shrinking to it: where the glass
    /// is drawn on the way is read from its end slots (`glassNow`), so the dock's ends take the click wherever they are.
    @ObservationIgnored var drawnGlass: CGRect = .zero {
        didSet {
            guard drawnGlass != oldValue else { return }
            let now = ProcessInfo.processInfo.systemUptime
            glassMove = DockRules.glassMove(from: oldValue, drawn: glassMove?.at(now) ?? oldValue, to: drawnGlass, now: now,
                                            duration: Self.glassAnimation)
            panel?.updateMouseThrough()
            if glassMove != nil { panel?.followGlass() }
        }
    }
    @ObservationIgnored private(set) var glassMove: DockRules.GlassMove?
    /// How long the glass takes to grow or shrink, and the apps of the layer strip to move (DockView's animations).
    static let glassAnimation = 0.22

    /// The first and last slot's mouse, which reach along to the glass's ends (`SlotMouse.ends`).
    @ObservationIgnored weak var startMouse: NSView?
    @ObservationIgnored weak var endMouse: NSView?

    /// The glass as it's drawn now: along the dock, from where SwiftUI has put its first and last slot's mouse this
    /// moment (they reach to its ends, and move with it as it grows or shrinks); across, as laid out.
    var glassNow: CGRect {
        if let start = startMouse, let end = endMouse, let content = start.window?.contentView, end.window === start.window {
            func rect(_ view: NSView) -> CGRect {
                let frame = view.convert(view.bounds, to: nil)
                return CGRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
            }
            let low = rect(start), high = rect(end)
            if vertical { return CGRect(x: drawnGlass.minX, y: low.minY, width: drawnGlass.width, height: max(0, high.maxY - low.minY)) }
            return CGRect(x: low.minX, y: drawnGlass.minY, width: max(0, high.maxX - low.minX), height: drawnGlass.height)
        }
        // (No SwiftUI slot at an end, as when the strip's apps come first: along its own curve.)
        guard let move = glassMove else { return drawnGlass }
        let now = ProcessInfo.processInfo.systemUptime
        if move.done(at: now) {
            glassMove = nil
            return drawnGlass
        }
        // (And where it will be by the next frame: the panel is told at the display's rate, a frame at a time.)
        return move.at(now).union(move.at(now + 1.0 / 120))
    }
    @ObservationIgnored weak var panel: DockPanel?
    @ObservationIgnored weak var strip: AppStripView?
    let magnifier = Magnifier()

    init() { magnifier.dock = self }

    var vertical: Bool { PetalApp.shared.config.position != "bottom" }
}

/// One dock per screen, and everything that keeps them current.
@MainActor
final class DockController {
    private(set) var panels: [CGDirectDisplayID: DockPanel] = [:]
    private var timer: Timer?
    private var minimizedCache: [AppWindow] = []
    var shown = false

    var app: PetalApp { PetalApp.shared }
    var config: Config { app.config }

    init() {
        guard !Headless.on else { return }   // a benchmark's docks never follow the screen
        let center = NSWorkspace.shared.notificationCenter
        // Another app in front changes only which icon is active: the last look at the windows does, at once.
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(quick: true) }
        }
        // Another Desktop, or a full-screen app's Space: the dock steps aside (or comes back) at once.
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(quick: true) }
        }
        // Apps opening, quitting, hiding, and another Desktop: look at the windows again, off the main thread.
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshInBackground() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    func show(_ on: Bool) {
        shown = on
        // Mission Control from the shared watcher (MissionControlWatch), needed while this dock is shown.
        MissionControlWatch.shared.subscribe("dock") { [weak self] open in self?.setMissionControl(open) }
        MissionControlWatch.shared.need("dock", on)
        if on {
            // Windows opening, closing, minimizing and moving, as they happen (with Accessibility).
            WindowEvents.shared.listen("dock") { [weak self] event in self?.handle(event) }
            eventsLive = WindowEvents.shared.live
            readAllMinimized = true   // nothing was heard while hidden
            refresh()
            refreshInBackground()   // the minimized windows
        } else {
            WindowEvents.shared.stopListening("dock")
            trailing?.cancel()   // a timed look waiting: none while hidden
            trailing = nil
            armedFor = nil
            setMissionControl(false)
            for panel in panels.values { panel.close() }
            panels = [:]
        }
        setPolling()
    }

    // MARK: Looking at the windows

    /// Looks at the windows off the main thread, then refreshes with what it found. The window server can take a
    /// moment to answer (hundreds of milliseconds while apps launch), and the dock never waits for it.
    func refreshInBackground() { look(.now) }

    private var schedule = LookSchedule()
    private var trailing: DispatchWorkItem?
    private var eventsLive = false
    private var pollInterval: Double = 0
    nonisolated private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// A window opened, closed, minimized, came back, moved or resized (WindowEvents, with Accessibility).
    private func handle(_ event: WindowEvents.Event) {
        switch event.kind {
        case .created, .closed, .minimized, .unminimized:
            minimizedChanged[event.pid] = Self.now
            look(.window)
        case .moved, .resized:
            look(.movement)
        case .focused:
            // A window minimizing hands focus to another: the next look reads this app's minimized windows too, in
            // case the minimize itself went unheard.
            minimizedChanged[event.pid] = Self.now
        case .quit:
            minimizedByApp[event.pid] = nil
            minimizedChanged[event.pid] = nil
        default:
            break   // apps launching, quitting, hiding, another Desktop: the NSWorkspace observers above
        }
    }

    // MARK: Mission Control

    /// Mission Control (or App Exposé) is open. macOS's Dock always comes out there, whatever its own settings say
    /// (no setting keeps it away, and it's the Dock that draws Mission Control), so Petal's dock steps aside while
    /// it's open: one dock on the screen, not two. Comes back the moment it closes.
    /// As MissionControlWatch says (its events, and its check that macOS's Dock still has a window up).
    private(set) var missionControl = false

    /// Some screen shows a full-screen app's Space: macOS brings its Dock out there at the screen's edge, which
    /// isn't Mission Control (MissionControlWatch).
    var inFullScreen: Bool { panels.values.contains { $0.fullScreen } }

    private func setMissionControl(_ on: Bool) {
        guard on != missionControl else { return }
        missionControl = on
        if on {
            app.popups.closeAll()   // nothing of the dock's left floating over Mission Control
        }
        app.previews.hold(on)
        for panel in panels.values { panel.aside = on }
    }

    private func look(_ cause: LookSchedule.Cause) {
        guard shown else { return }
        if schedule.note(cause, at: Self.now) { startLook() }
        armTrailing()
    }

    /// One timer for the next timed look. While a drag keeps pushing it later, the timer isn't remade for every
    /// step: it fires, finds the look not due yet, and waits again. A sooner one (after the gap) remakes it.
    private func armTrailing() {
        guard let due = schedule.due else { return }
        if trailing != nil, let armed = armedFor, armed <= due + 0.001 { return }
        trailing?.cancel()
        armedFor = due
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.trailing = nil
                self.armedFor = nil
                // Hidden (macOS's Dock chosen): no looks, and no timer again for a look that can't happen. Showing
                // again looks at once.
                guard self.shown else { return }
                if self.schedule.fire(at: Self.now) { self.startLook() }
                self.armTrailing()
            }
        }
        trailing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - Self.now), execute: work)
    }
    private var armedFor: Double?

    /// The timer: once a second without Accessibility's events (or while an app is launching, to end its pulse on
    /// time), every 5 s with them, as a safety net. It also notices Accessibility being allowed or taken away.
    private func setPolling() {
        guard shown else {
            timer?.invalidate()
            timer = nil
            pollInterval = 0
            return
        }
        let interval = LookSchedule.interval(events: eventsLive, launching: !app.launching.isEmpty)
        guard interval != pollInterval else { return }
        pollInterval = interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = interval / 10
    }

    private func tick() {
        WindowEvents.shared.checkPermission()
        if WindowEvents.shared.live != eventsLive {
            // Accessibility was just allowed (or taken away): read every app's minimized windows again.
            eventsLive = WindowEvents.shared.live
            readAllMinimized = true
            look(.now)
            setPolling()
            return
        }
        // Now and then, every app's minimized windows: a minimize whose event never came is caught.
        polls += 1
        if polls % 6 == 0 { readAllMinimized = true }
        look(.poll)
    }

    private func startLook() {
        // Which apps' minimized windows to read: every app's, or those with a window event lately. Asking each
        // process whether it's a regular app costs milliseconds, so the list of apps is made off the main thread.
        let read = minimizedToRead()
        Self.lookQueue.async { [weak self] in
            let snapshot = WindowList.current()
            let running = Self.runningApps()
            let pids = running.values.map(\.processIdentifier).sorted()   // by launch, so minimized windows keep their order
            var minimized: [pid_t: [AppWindow]] = [:]
            for pid in pids where read.all || read.changed.contains(pid) { minimized[pid] = Windows.windows(of: pid).filter(\.minimized) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let alive = Set(pids)
                    for (pid, windows) in minimized { self.minimizedByApp[pid] = windows }
                    self.minimizedByApp = self.minimizedByApp.filter { alive.contains($0.key) }
                    self.minimizedCache = pids.flatMap { self.minimizedByApp[$0] ?? [] }
                    self.lastRunning = running
                    self.refresh(with: snapshot)
                    if self.schedule.finished(at: Self.now) { self.startLook() }
                    self.armTrailing()
                    self.setPolling()
                }
            }
        }
    }

    // MARK: Minimized windows

    /// Each app's minimized windows, across Desktops. Read again only for an app whose windows opened,
    /// closed, minimized or came back (and once for every app when the events start), never by scanning every app.
    private var minimizedByApp: [pid_t: [AppWindow]] = [:]
    /// Apps with a window event lately, by when: each look in the second after reads them, so the trailing look
    /// catches a window the app listed late.
    private var minimizedChanged: [pid_t: Double] = [:]
    private var readAllMinimized = true
    private var polls = 0

    private func minimizedToRead() -> (all: Bool, changed: Set<pid_t>) {
        guard config.bool("minimized") || config.bool("thisWorkspaceOnly"), eventsLive else {
            minimizedByApp = [:]
            minimizedChanged = [:]
            readAllMinimized = true   // read every app again once the setting or Accessibility is back
            return (false, [])
        }
        let now = Self.now
        let changed = Set(minimizedChanged.keys)   // every app marked is read at least once
        minimizedChanged = minimizedChanged.filter { now - $0.value < LookSchedule.followUp + 1 }
        if readAllMinimized {
            readAllMinimized = false
            return (true, [])
        }
        return (false, changed)
    }

    /// The apps with a place in the dock, by bundle id. Asking each running process for this costs several
    /// milliseconds, so it's done off the main thread with each look at the windows.
    static let finder = "com.apple.finder"

    nonisolated static func runningApps() -> [String: NSRunningApplication] {
        var running: [String: NSRunningApplication] = [:]
        // Never a browser Petal started for a run (the same app as the person's, as a second process).
        for app in NSWorkspace.shared.personsApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, running[id] == nil { running[id] = app }
        }
        return running
    }
    @ObservationIgnored private var lastRunning: [String: NSRunningApplication]?
    nonisolated private static let lookQueue = DispatchQueue(label: "petal.windows", qos: .userInitiated)
    /// The last look at the windows, for refreshes that only change what the dock shows. Windows opening, closing
    /// and moving keep it current through Accessibility's events (without them, it's at most a second old).
    @ObservationIgnored private var lastSnapshot: WindowList?

    /// The window is on the Desktop showing (as of the last look at the windows): it can come forward at once.
    func isOnScreen(_ window: AppWindow) -> Bool {
        !window.minimized && (lastSnapshot?.onScreenFrames(pid: window.pid) ?? []).contains { $0.equalTo(window.frame, within: 4) }
    }

    /// `quick`: what changed is the dock's apps or a setting, not the windows, so the last look at them does.
    func refresh(quick: Bool = false) {
        refresh(with: quick ? (lastSnapshot ?? WindowList.current()) : Perf.span("refresh: window list") { WindowList.current() })
    }

    func refresh(with snapshot: WindowList) {
        guard shown else { return }
        lastSnapshot = snapshot
        let screens = Screens.all
        let ids = Set(screens.compactMap(\.displayID))
        for (id, panel) in panels where !ids.contains(id) {
            panel.close()
            panels[id] = nil
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // The last list of running apps, less any that quit since (a quit app's dot goes at once).
        let running = Perf.span("refresh: running apps") { (lastRunning ?? Self.runningApps()).filter { !$0.value.isTerminated } }
        // Minimized windows are read with either setting on: shown as thumbnails, or keeping an app with only
        // minimized windows in the dock while thisWorkspaceOnly drops the ones on other Desktops.
        let minimizedAll = config.bool("minimized") ? minimizedCache : []
        var minimizedCount: [String: Int] = [:]
        let byPid = Dictionary(running.map { ($0.value.processIdentifier, $0.key) }, uniquingKeysWith: { a, _ in a })
        for window in minimizedCache { if let id = byPid[window.pid] { minimizedCount[id, default: 0] += 1 } }
        let finderButton = config.bool("finderInDock")
        // Finder is its own button by the AI button (FinderButton): never among the apps.
        var seen = Set<String>()
        let apps = config.apps.filter { Apps.shows($0) && !(finderButton && $0 == Self.finder) && seen.insert($0).inserted }
        Perf.span("refresh: launching") { app.updateLaunching(snapshot) }
        // The running apps that aren't the dock's own: those with a window by their first window, then the rest
        // (hidden, or with none) by launch.
        let candidates = (snapshot.order + running.values.sorted { $0.processIdentifier < $1.processIdentifier }.compactMap(\.bundleIdentifier))
            .reduce(into: [String]()) { list, id in
                if running[id] != nil, !seen.contains(id), !(finderButton && id == Self.finder), !list.contains(id) { list.append(id) }
            }

        for screen in screens {
            guard let id = screen.displayID else { continue }
            let panel = panels[id] ?? DockPanel()
            panels[id] = panel
            let dock = panel.dock
            let showing = Perf.span("refresh: desktop") { Spaces.showing(on: screen) }
            // A full-screen app's Space keeps the Desktop before it.
            if let desktop = showing.desktop, desktop != dock.desktop { dock.desktop = desktop }
            panel.fullScreen = showing.fullScreen
            panel.aside = missionControl   // a screen joining while Mission Control is open
            let here = Set(snapshot.apps(on: screen))

            func item(_ bundleID: String, pinned: Bool) -> DockItem {
                DockItem(id: bundleID, pinned: pinned, running: running[bundleID] != nil, windows: snapshot.count[bundleID] ?? 0,
                         here: here.contains(bundleID), active: bundleID == frontmost)
            }
            // The dock's apps in their order, then the running apps that aren't among them, each keeping its slot
            // for the session.
            let pinned = apps.map { item($0, pinned: true) }
            // Every running app, hidden or with no window too, but one whose windows are all on another Desktop
            // (with thisWorkspaceOnly): apps with a window first, by their first window, then the rest by launch.
            let others = DockRules.others(candidates.map { id in
                DockRules.Running(id: id, windows: snapshot.count[id] ?? 0, here: here.contains(id), minimized: minimizedCount[id] ?? 0,
                                  hidden: running[id]?.isHidden ?? false)
            }, kept: dock.order, thisDesktopOnly: config.bool("thisWorkspaceOnly"))
            dock.order = others
            let ordered = pinned + dock.order.map { item($0, pinned: false) }
            Perf.span("refresh: set items") { if ordered != dock.items { dock.items = ordered } }
            let finderNow = item(Self.finder, pinned: true)
            if finderNow != dock.finder { dock.finder = finderNow }
            if dock.minimized != minimizedAll { dock.minimized = minimizedAll }
            // The stage holds the apps and "+".
            let slots = ordered.count + 1
            if slots != dock.stageSlots { dock.stageSlots = slots }

            Perf.span("refresh: place panel") { panel.place(on: screen) }
        }
        Perf.span("refresh: keep windows clear") { keepWindowsClear(snapshot) }
    }

    /// macOS keeps no room for a dock other than its own, so windows would run under Petal's. While auto-hide is
    /// off, a window reaching into the dock's strip is shortened to end where the dock's glass begins (or narrowed,
    /// for a side dock); one too small to shorten, or one the person moved there at its own size, is moved out
    /// instead.
    ///
    /// Petal remembers each window's frame from before it touched it. A new position (or icon size) starts again
    /// from that frame, so windows never shrink step by step as the dock moves around; turning this off, or
    /// auto-hide on, or the window's screen going full screen, gives it back. A window moved or resized since is
    /// the person's, and forgotten.
    private func keepWindowsClear(_ snapshot: WindowList) {
        guard Windows.trusted else { return }
        let on = config.keepWindowsClear && !config.autoHide
        guard on || !clearing.isEmpty else { return }
        let top = Screens.all.first?.frame.maxY ?? 0
        let docks = panels.values.compactMap { panel -> DockRules.ClearDock? in
            guard let area = panel.screenRef?.frame else { return nil }
            // Top-left origin, as Accessibility counts.
            return DockRules.ClearDock(screen: CGRect(x: area.minX, y: top - area.maxY, width: area.width, height: area.height),
                                       reach: panel.reach, fullScreen: panel.fullScreen)
        }
        let windows = snapshot.onScreenWindows
        let pids = Dictionary(windows.map { ($0.number, $0.pid) }, uniquingKeysWith: { a, _ in a })
        let moves = clearing.look(windows.map { (number: $0.number, frame: $0.frame) }, alive: snapshot.numbers, docks: docks, on: on,
                                  position: config.position)
        guard !moves.isEmpty else { return }
        // Accessibility waits on each app: never on the main thread.
        Self.clearQueue.async {
            for move in moves {
                guard let pid = pids[move.number] else { continue }
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.3)
                let list: [AXUIElement] = Windows.value(app, kAXWindowsAttribute) ?? []
                // Still where it was when this was decided: moved since (by the person, a newer look), it's left
                // alone, and weighed again at the next look.
                var actual: CGRect?
                if let element = list.first(where: { Windows.id(of: $0) == move.number }),
                   let there = Windows.frame(of: element), there.equalTo(move.from, within: 4) {
                    actual = Windows.place(element, pid: pid, move.to)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Where the app let it go (an app may keep a minimum size), which is now Petal's frame for it.
                        PetalApp.shared.docks?.clearing.landed(move.number, asked: move.to, at: actual)
                    }
                }
            }
        }
    }

    /// Windows kept clear of the dock, and every window's frame at the last look (DockRules.ClearLedger).
    private var clearing = DockRules.ClearLedger()
    nonisolated private static let clearQueue = DispatchQueue(label: "petal.windows.clear", qos: .userInitiated)

    /// How far the dock on `screen` reaches in from its edge: where windows kept clear of it end.
    func reach(on screen: NSScreen?) -> CGFloat? {
        guard shown, let screen, let id = screen.displayID, let panel = panels[id], !panel.fullScreen else { return nil }
        return panel.reach
    }

    func dock(for screen: NSScreen?) -> ScreenDock? {
        guard let id = (screen ?? Screens.main)?.displayID else { return panels.values.first?.dock }
        return panels[id]?.dock ?? panels.values.first?.dock
    }

    /// The dock on the screen with the window in front: where cards go.
    /// The dock on the screen of the window in front. One screen has one dock; with more, the last look at the
    /// windows says where the window in front is, so asking costs nothing.
    var focusedDock: ScreenDock? {
        if panels.count == 1 { return panels.values.first?.dock }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let frame = (lastSnapshot ?? WindowList.current()).onScreenFrames(pid: front.processIdentifier).first
        else { return dock(for: Screens.main) }
        let top = Screens.all.first?.frame.maxY ?? 0
        let center = CGPoint(x: frame.midX, y: top - frame.midY)
        return dock(for: Screens.all.first { $0.frame.contains(center) })
    }

    func revealAll() {
        for panel in panels.values { panel.reveal() }
    }

    // MARK: Opening apps

    /// No windows: launch it. Windows: bring one forward, cycling through them on repeated clicks: this Desktop's
    /// first, then minimized ones, then the rest. The pointer never moves.
    func activate(_ item: DockItem) {
        Windows.focusing.cancel()   // first, whatever this click turns out to be: an earlier one's focus stands down
        if Sites.isWeb(item.id) { Sites.open(item.id); return }
        if app.claude.openReady(app: item.id) { return }   // its note is done: its window, and the note on it
        guard item.running, let running = NSRunningApplication.persons(withBundleIdentifier: item.id).first else {
            launch(item.id)
            return
        }
        // Decided here from what the dock already knows; the app's windows are listed (Accessibility, which waits on
        // a busy app) on the focus queue, and a newer click makes this one stand down.
        let pid = running.processIdentifier, active = item.active, known = item.windows, id = item.id
        let onScreen = (lastSnapshot ?? WindowList.current()).onScreenFrames(pid: pid)
        let ticket = Windows.focusing.next()
        Windows.focusQueue.async {
            guard Windows.focusing.current(ticket) else { return }
            let windows = Windows.windows(of: pid)
            func rank(_ w: AppWindow) -> Int { w.minimized ? 1 : (onScreen.contains { $0.equalTo(w.frame, within: 4) } ? 0 : 2) }
            var focused: AXUIElement?
            if active, !windows.isEmpty {
                // The window in front now: the next one along comes forward (clicking again cycles through them all).
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.3)
                focused = Windows.value(app, kAXFocusedWindowAttribute)
            }
            let weighed = windows.map { DockRules.Window(rank: rank($0), number: Windows.id(of: $0.element), title: $0.title, minimized: $0.minimized) }
            let pick = DockRules.pick(weighed, active: active, focused: focused.flatMap { Windows.id(of: $0) },
                                      focusedTitle: focused.flatMap { Windows.value($0, kAXTitleAttribute) } ?? "").map { windows[$0] }
            let onIt = pick.map { rank($0) == 0 } ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard Windows.focusing.current(ticket) else { return }
                    guard let pick else {
                        if known == 0 { PetalApp.shared.docks.launch(id) } else { Windows.bringForward(running) }
                        return
                    }
                    Windows.focus(pick, onScreen: onIt)
                }
            }
        }
    }

    func launch(_ id: String, files: [URL] = []) {
        guard let url = Apps.url(id) else { return }
        // The icon breathes only while an app starts: a file opened in one already running (maybe as a tab) isn't.
        if NSRunningApplication.persons(withBundleIdentifier: id).isEmpty {
            app.launching[id] = (Date(), (lastSnapshot ?? WindowList.current()).count[id] ?? 0)
            setPolling()   // once a second until its window shows
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // While a run has a browser of its own going, macOS would take that copy for the app: the person's own is
        // opened as a new one.
        if RunBrowsers.running(bundle: id) { configuration.createsNewApplicationInstance = true }
        if files.isEmpty {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } else {
            NSWorkspace.shared.open(files, withApplicationAt: url, configuration: configuration)
        }
    }

    /// New window: the app comes forward and gets ⌘N, as its own File menu would.
    func newWindow(_ id: String) {
        Windows.focusing.cancel()   // an earlier click's focus still on its way would come in front of the new window
        if Sites.isWeb(id) { Sites.open(id); return }
        guard let running = NSRunningApplication.persons(withBundleIdentifier: id).first else { launch(id); return }
        Windows.bringForward(running)
        let pid = running.processIdentifier
        // The app's own menu item for ⌘N (File › New Window, in any language), pressed through Accessibility; an
        // app without one gets the keystroke, once it's in front.
        DispatchQueue.global(qos: .userInitiated).async {
            guard !Windows.pressMenuItem(pid: pid, key: "N") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let source = CGEventSource(stateID: .combinedSessionState)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0x2D, keyDown: down)   // N
                    event?.flags = .maskCommand
                    event?.postToPid(pid)
                }
            }
        }
    }

    func quit(_ id: String) {
        for app in NSRunningApplication.persons(withBundleIdentifier: id) { app.terminate() }
    }

    func forceQuit(_ id: String) {
        for app in NSRunningApplication.persons(withBundleIdentifier: id) { app.forceTerminate() }
    }

    func minimizeAll(_ id: String) {
        let pids = NSRunningApplication.persons(withBundleIdentifier: id).map(\.processIdentifier)
        DispatchQueue.global(qos: .userInitiated).async {   // listing the windows waits on the app too
            for pid in pids {
                for window in Windows.windows(of: pid) where !window.minimized { Windows.minimize(window) }
            }
        }
    }

    func hide(_ id: String) {
        for app in NSRunningApplication.persons(withBundleIdentifier: id) { app.hide() }
    }

    // MARK: Reordering

    /// Dropping an app at a new place saves the new order as the dock's apps. Dragging a running app that isn't
    /// one of them into place adds it.
    func move(_ id: String, to index: Int, in dock: ScreenDock) {
        guard let from = dock.items.firstIndex(where: { $0.id == id }) else { return }
        var keys = dock.items.map(\.id)
        keys.remove(at: from)
        keys.insert(id, at: min(max(0, index), keys.count))
        let shown = keys.filter { key in key == id || dock.items.first { $0.id == key }?.pinned == true }
        // The dock's apps that aren't showing here (not installed on this Mac, or Finder under its own button) stay.
        config.setApps(shown + config.apps.filter { !shown.contains($0) })
    }
}

/// Which apps have normal windows, and where: from the window server, which needs no permission for owners and
/// frames (never titles or contents).
struct WindowList {
    var count: [String: Int] = [:]
    var order: [String] = []                      // apps by their first window
    /// Every app window's number, on any Desktop or minimized.
    var numbers: Set<CGWindowID> = []
    private var onScreen: [(bundleID: String, pid: pid_t, frame: CGRect, number: CGWindowID)] = []

    static func current() -> WindowList {
        var list = WindowList()
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        var ids: [pid_t: String] = [:]
        for window in info.reversed() {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != me, !RunBrowsers.isRun(pid),
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
            let number = window[kCGWindowNumber as String] as? CGWindowID ?? 0
            list.count[bundleID, default: 0] += 1
            list.numbers.insert(number)
            if isOnScreen { list.onScreen.append((bundleID, pid, bounds, number)) }
            if !list.order.contains(bundleID) { list.order.append(bundleID) }
        }
        return list
    }

    /// Apps with a window on the Desktop `screen` shows. Window frames count from the top of the main screen.
    func apps(on screen: NSScreen) -> [String] {
        let top = Screens.all.first?.frame.maxY ?? 0
        var result: [String] = []
        for window in onScreen {
            let center = CGPoint(x: window.frame.midX, y: top - window.frame.midY)
            if screen.frame.contains(center), !result.contains(window.bundleID) { result.append(window.bundleID) }
        }
        return result
    }

    func onScreenFrames(pid: pid_t) -> [CGRect] { onScreen.filter { $0.pid == pid }.map(\.frame) }

    /// Every app window on screen, top-left origin as Accessibility counts.
    var onScreenWindows: [(pid: pid_t, frame: CGRect, number: CGWindowID)] { onScreen.map { ($0.pid, $0.frame, $0.number) } }
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
    private var measuredShape = ""
    private var hideAt: Date?
    private var mouseTimer: Timer?
    private(set) weak var screenRef: NSScreen?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        dock.panel = self
        hosting = DockHostingView(rootView: AnyView(DockView(dock: dock).environment(PetalApp.shared)))
        contentView = DockHostingView.container(hosting)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Said outright from the start, never left to the window server's guess from what's drawn: the panel takes the
        // mouse exactly where `updateMouseThrough` says.
        ignoresMouseEvents = true
        // A check's dock (`Petal --bench-dock`) is laid out and drawn without ever being shown or following the mouse.
        guard !Headless.on else { return }
        orderFrontRegardless()
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followMouse() }
        }
        // The panel runs the screen's whole edge so it never resizes; only the dock itself takes the mouse, and the
        // clear rest lets clicks through to the windows below. Pointer moves anywhere set it at once.
        let follow: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.updateMouseThrough() } }
        mouseMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: follow) as Any,
            NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { follow($0); return $0 } as Any,
        ]
    }

    private var mouseMonitors: [Any] = []

    /// Takes the mouse only over the dock (its glass and the room above it for lifting icons), never over the
    /// clear rest of the panel, and not at all while tucked away.
    ///
    /// Decided from the glass as it's drawn now (`ScreenDock.glassNow`, from SwiftUI's own layout, and stretched as
    /// magnification draws it), whenever the pointer moves, the glass changes or the timer ticks: never from a size
    /// measured before, which lagged behind an app appearing and let clicks at the dock's ends through to the desktop.
    func updateMouseThrough() {
        // (While a press that began on the dock is held, it keeps the mouse: an app dragged out of the dock is let
        // go there.)
        let held = pressing && NSEvent.pressedMouseButtons & 1 != 0   // (never stuck, should a release go unseen)
        let wanted = tucked || (!held && !takesMouse(at: NSEvent.mouseLocation))
        guard ignoresMouseEvents != wanted else { return }
        ignoresMouseEvents = wanted
        if wanted { NotificationCenter.default.post(name: Self.mouseLeft, object: self) }
    }

    /// While the glass grows or shrinks, whether the panel takes the mouse is decided again at the display's rate,
    /// not only on the pointer's moves and the 50 ms timer, so the dock's ends take the click wherever they're drawn.
    func followGlass() {
        // Past the animation's own length too: SwiftUI may start it a few frames late.
        followUntil = ProcessInfo.processInfo.systemUptime + ScreenDock.glassAnimation + 0.25
        guard glassTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.updateMouseThrough()
                if ProcessInfo.processInfo.systemUptime > self.followUntil {
                    timer.invalidate()
                    self.glassTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        glassTimer = timer
    }
    private var glassTimer: Timer?
    private var followUntil: Double = 0

    /// Whether a click at `point` (screen coordinates) is the dock's: over the glass as drawn now, out to the screen's
    /// edge, or over an icon drawn grown or lifted past it (`DockRules.takesMouse`). Hover goes by it too, so an icon
    /// that shows its tooltip always takes the click.
    func takesMouse(at point: CGPoint) -> Bool {
        guard !tucked else { return false }
        var glass = dock.glassNow
        let magnifier = dock.magnifier
        var inward = DockView.inwardReach(config, icon: dock.icon)
        if magnifier.on {
            let strength = magnifier.state.strength
            let stretch = magnifier.glassStretch
            if dock.vertical {
                let height = glass.height * stretch.scale
                glass = CGRect(x: glass.minX, y: glass.minY + (glass.height - height) * stretch.anchor, width: glass.width, height: height)
            } else {
                let width = glass.width * stretch.scale
                glass = CGRect(x: glass.minX + (glass.width - width) * stretch.anchor, y: glass.minY, width: width, height: glass.height)
            }
            let slot = dock.icon + (config.number("iconPadding") >= 0 ? config.number("iconPadding") : 5) * 2
            inward = strength > 0.01 ? slot * Magnifier.amount * strength + 2 : 0
        }
        let local = CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
        return DockRules.takesMouse(local, glass: glass, panel: frame.size, position: config.position, inward: inward)
    }

    /// The left button went down on the dock and hasn't come up yet.
    private var pressing = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: pressing = true
        case .leftMouseUp: pressing = false
        default: break
        }
        super.sendEvent(event)
        guard event.type == .leftMouseUp else { return }
        updateMouseThrough()
        // The release ends any drag of an app: one whose slot went while it was held (the app quit) never heard it,
        // and a drag left standing would keep the dock out, its icons from growing and lifting, for good.
        if dock.dragging != nil {
            dock.dragging = nil
            dock.dragOffset = 0
            dock.dragOut = false
        }
    }

    /// Posted as the dock stops taking the mouse: whatever was hovered in it isn't any more.
    static let mouseLeft = Notification.Name("PetalDockMouseLeft")

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func close() {
        mouseTimer?.invalidate()
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []
        super.close()
    }

    var config: Config { PetalApp.shared.config }

    /// The dock's size as last measured, which the panel once decided the mouse by (`Petal --dock-check` shows how far
    /// behind it fell).
    var measuredSize: CGSize? { measured }

    /// The dock's content (the glass and the clear room around it), centered in the panel. The panel itself is as
    /// long as the screen's edge, so it never resizes while the dock grows or shrinks: SwiftUI animates the glass
    /// around its centre instead. (From the glass as laid out now; until SwiftUI first lays it out, from the last
    /// measure.)
    var contentFrame: CGRect {
        let room = DockView.outer(config, icon: dock.icon)
        if dock.drawnGlass != .zero {
            let glass = glassFrame
            return CGRect(x: glass.minX - room.leading, y: glass.minY - room.bottom, width: glass.width + room.leading + room.trailing,
                          height: glass.height + room.top + room.bottom)
        }
        let size = measured ?? frame.size
        return CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The glass itself, without the clear room around it for lifting and bouncing icons: tooltips, previews and
    /// stacks sit just above this, as they do over macOS's Dock. As laid out now (screen coordinates).
    var glassFrame: CGRect {
        let glass = dock.drawnGlass
        if glass != .zero { return CGRect(x: frame.minX + glass.minX, y: frame.maxY - glass.maxY, width: glass.width, height: glass.height) }
        let room = DockView.outer(config, icon: dock.icon)
        let size = measured ?? frame.size
        let content = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        return CGRect(x: content.minX + room.leading, y: content.minY + room.bottom,
                      width: content.width - room.leading - room.trailing, height: content.height - room.top - room.bottom)
    }

    /// What tooltips, previews and stacks sit beyond: the glass, and with magnification on, the icons grown past it
    /// (they grow from the edge the dock sits on by a slot times the amount, from 4 points inside the glass).
    var popupEdge: CGRect {
        var edge = glassFrame
        guard Magnifier.enabled else { return edge }
        let inset = config.number("iconPadding") >= 0 ? config.number("iconPadding") : 5
        let grown = max(0, (dock.icon + inset * 2) * Magnifier.amount - 4)
        switch config.position {
        case "left": edge.size.width += grown
        case "right": edge.origin.x -= grown; edge.size.width += grown
        default: edge.size.height += grown
        }
        return edge
    }

    /// How far a point on the screen is past the glass, away from the screen's edge (negative: over the glass or
    /// beyond it toward the edge).
    func inward(of point: CGPoint) -> CGFloat {
        let glass = glassFrame
        switch config.position {
        case "left": return point.x - glass.maxX
        case "right": return glass.minX - point.x
        default: return point.y - glass.maxY
        }
    }

    /// How far the glass reaches in from the screen's edge: windows kept clear of the dock end right there. (The
    /// panel runs to the screen's edge, with the gap inside it.)
    var reach: CGFloat {
        let size = measured ?? frame.size
        let room = DockView.outer(config, icon: dock.icon)
        switch config.position {
        case "left": return size.width - room.trailing
        case "right": return size.width - room.leading
        default: return size.height - room.top
        }
    }

    /// Something open over the dock keeps it out while auto-hide is on.
    /// (A stack, a window preview or the player's controls, a drag, the chat, a question, or the "+" search.)
    var busy: Bool {
        let app = PetalApp.shared
        return dock.openPopup != nil || dock.dragging != nil || app.overlayOpen || app.popups.kind != nil || app.search.isOpen
    }

    /// The screen shows a full-screen app: the dock keeps out of its way and comes out at the screen's edge, as
    /// macOS's does there.
    var fullScreen = false {
        didSet {
            guard fullScreen != oldValue else { return }
            dock.revealed = !hides
            hideAt = nil
        }
    }

    /// Out of the way until the pointer reaches the edge: auto-hide, or a full-screen app.
    var hides: Bool { config.autoHide || fullScreen }

    /// Mission Control is open, where macOS's own Dock comes out: this one steps aside until it closes.
    var aside = false {
        didSet {
            guard aside != oldValue, let screenRef else { return }
            place(on: screenRef)
        }
    }

    var tucked: Bool { aside || (hides && !dock.revealed && !busy) }

    func place(on screen: NSScreen) {
        screenRef = screen
        // Measured again only when the dock's content says its size may have changed: once a second, nothing has.
        // A new position (or icon size) lays the dock out the other way: the last measure doesn't hold. Nor does it
        // once magnification is switched on or grows: the room kept for grown icons changes at once (`outer`), and a
        // setting's change places the dock before SwiftUI says its size changed. Nor once an app or a minimized window
        // comes or goes: measured now, in the same update, the icons shrink or grow to fit with the change itself
        // (one move), not at the next look seconds later.
        let shape = "\(config.position)|\(config.number("iconSize"))|\(config.number("iconPadding"))|\(config.number("dockMargin"))|"
            + "\(Magnifier.enabled)|\(Magnifier.amount)|\(screen.frame)|\(dock.stageSlots)|\(dock.minimized.count)"
        if shape != measuredShape { measured = nil; measuredShape = shape }
        let area = screen.frame
        let visible = screen.visibleFrame
        let content: CGSize
        if let measured, !hosting.sizeChanged {
            content = measured
        } else {
            content = fit(along: config.position == "bottom" ? area.width - 16 : visible.height - 16)
            measured = content
        }
        // Only the dock's thickness comes from its content; along the edge the panel is the screen's length.
        var origin: CGPoint
        let size: CGSize
        switch config.position {
        // At the screen's edge: the gap is inside the panel (`DockView.outer`), so what's between the dock and the
        // edge is the dock's too.
        case "left":
            size = CGSize(width: content.width, height: visible.height)
            origin = CGPoint(x: area.minX, y: visible.minY)
        case "right":
            size = CGSize(width: content.width, height: visible.height)
            origin = CGPoint(x: area.maxX - content.width, y: visible.minY)
        default:
            size = CGSize(width: area.width, height: content.height)
            origin = CGPoint(x: area.minX, y: area.minY)
        }
        // Tucked away, it slides a little toward the edge and fades out (sliding off the edge would put it on a
        // display arranged next to this one).
        let shift: CGFloat = tucked ? 12 : 0
        switch config.position {
        case "left": origin.x -= shift
        case "right": origin.x += shift
        default: origin.y -= shift
        }
        updateMouseThrough()
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

    /// Places the panel again on its screen (its content's size changed).
    func placeAgain() {
        if let screenRef { place(on: screenRef) }
    }

    func reveal() {
        dock.revealed = true
        if let screenRef { place(on: screenRef) }
    }

    /// Measures the dock with the icons as large as the setting asks, or, when that many wouldn't fit in `room`
    /// along the screen's edge, as large as fits (not under 16 points), as macOS's Dock does. The dock's length is
    /// the icons' share, which grows with them, plus a fixed part (padding, the separators): two measures tell
    /// both, so the second guess fits.
    private func fit(along room: CGFloat) -> CGSize {
        let wanted = max(16, config.number("iconSize"))
        func length(_ size: CGSize) -> CGFloat { config.position == "bottom" ? size.width : size.height }
        func measure(at icon: CGFloat) -> CGSize {
            if dock.icon != icon {
                dock.icon = icon
                hosting.rootView = hosting.rootView   // laid out again now, at the new size
            }
            return hosting.measure()
        }
        var icon = min(dock.icon, wanted)
        var size = measure(at: icon)
        // Grown back to the setting when there's room again (fewer apps): measured there first.
        if icon < wanted, length(size) < room {
            let full = measure(at: wanted)
            if length(full) <= room { return full }
            let perPoint = (length(full) - length(size)) / (wanted - icon)
            icon = perPoint > 0 ? min(wanted, floor(icon + (room - length(size)) / perPoint)) : icon
            size = measure(at: icon)
        }
        guard length(size) > room, icon > 16 else { return size }
        // Too long: a first guess as if all of it grew with the icons, then the line through both measures.
        let first = (icon, length(size))
        icon = max(16, floor(icon * room / length(size)))
        size = measure(at: icon)
        if length(size) > room, icon > 16, first.0 != icon {
            let perPoint = (first.1 - length(size)) / (first.0 - icon)
            if perPoint > 0 { icon = max(16, floor(icon - (length(size) - room) / perPoint)) }
            size = measure(at: icon)
        }
        while length(size) > room, icon > 16 {   // rounding: a point at a time
            icon -= 1
            size = measure(at: icon)
        }
        return size
    }

    /// The slot `id` in screen coordinates.
    /// (The strip's apps are asked where they are now: their view moves with the dock without being told.)
    func screenFrame(of id: String) -> CGRect? {
        guard let rect = dock.strip?.windowRect(of: id) ?? dock.frames[id] else { return nil }
        return CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Auto-hide: the dock comes out when the pointer meets its edge, and goes 150 ms after it leaves.
    private func followMouse() {
        updateMouseThrough()
        guard hides, let screen = screenRef else {
            if !dock.revealed { dock.revealed = true }
            if !aside && contentFrame.contains(NSEvent.mouseLocation) { dock.magnifier.wake() }
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
        let over = contentFrame.insetBy(dx: -8, dy: -8).contains(mouse)
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
    var icon: CGFloat { dock.icon }
    var inset: CGFloat { config.number("iconPadding") >= 0 ? config.number("iconPadding") : 5 }
    var slot: CGFloat { icon + inset * 2 }

    static let finderSlot = "finder"
    static let padSlot = "notepad"

    var body: some View {
        let layout = dock.vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        let stacks = Stacks.resolve(config.strings("stackFolders"))
        let extras = (config.bool("nowPlaying") && app.signals.nowPlaying != nil) || !dock.minimized.isEmpty
            || (config.bool("stacks") && !stacks.isEmpty) || config.bool("trash")
        let ai = !app.providers.isEmpty   // whenever an AI is chosen
        let pad = config.bool("notes") && config.bool("notesPad")
        let finder = config.bool("finderInDock")
        let playing = config.bool("nowPlaying") ? app.signals.nowPlaying : nil
        let shownStacks = config.bool("stacks") ? stacks : []
        // The first and last slot: their mouse reaches along to the dock's ends.
        let first = ai ? "claude" : finder ? Self.finderSlot : pad ? Self.padSlot : "stage"
        let last = config.bool("trash") ? "trash" : !shownStacks.isEmpty ? "stack:\(shownStacks.last!)"
            : !dock.minimized.isEmpty ? "min:\(dock.minimized.last!.id)" : playing != nil ? "media" : "stage"
        let ends: (String) -> DockEnds = { id in
            var ends: DockEnds = []
            if id == first { ends.insert(.start) }
            if id == last { ends.insert(.end) }
            return ends
        }
        let row = layout {
            if ai {
                ClaudeButton(dock: dock, size: icon * 0.95).frame(width: slot, height: slot).magnified(dock, "claude")
                    .environment(\.dockEnds, ends("claude"))
            }
            if finder {
                FinderButton(dock: dock, size: icon * 0.95).frame(width: slot, height: slot).magnified(dock, Self.finderSlot)
                    .environment(\.dockEnds, ends(Self.finderSlot))
            }
            // The note pad, by the AI button and Finder's, while Petal Notes is on.
            if pad {
                NotePadButton(dock: dock, size: icon * 0.95).frame(width: slot, height: slot).magnified(dock, Self.padSlot)
                    .environment(\.dockEnds, ends(Self.padSlot))
            }
            // Petal's own buttons, then the apps.
            if ai || pad || finder {
                Separator(vertical: dock.vertical, slot: slot).magnified(dock, "separator:buttons", scales: false)
            }
            stage(layout, ends: ends("stage"))
            if extras { Separator(vertical: dock.vertical, slot: slot).magnified(dock, "separator:extras", scales: false) }
            if let playing {
                NowPlayingSlot(dock: dock, playing: playing, icon: icon).frame(width: slot, height: slot).magnified(dock, "media")
                    .environment(\.dockEnds, ends("media"))
            }
            ForEach(dock.minimized) { window in
                MinimizedSlot(dock: dock, window: window, icon: icon).frame(width: slot, height: slot)
                    .magnified(dock, "min:\(window.id)")
                    .environment(\.dockEnds, ends("min:\(window.id)"))
            }
            ForEach(shownStacks, id: \.self) { folder in
                StackSlot(dock: dock, folder: folder, icon: icon).frame(width: slot, height: slot).magnified(dock, "stack:\(folder)")
                    .environment(\.dockEnds, ends("stack:\(folder)"))
            }
            if config.bool("trash") {
                TrashSlot(dock: dock, icon: icon).frame(width: slot, height: slot).magnified(dock, "trash")
                    .environment(\.dockEnds, ends("trash"))
            }
        }
        .padding(Self.rowPadding)
        .background { if !snapshotting { RightClickCatcher { Menus.settings(for: dock) } } }
        .modifier(DockGlass(dock: dock, glass: glass, radius: radius))
        // No GlassEffectContainer: in one, the glass's size and the slots' places change at once while only the
        // centring animates, so an app appearing threw the dock's end out a whole slot and slid it back
        // (`Petal --dock-check`). (A container would also lift the stretching glass above the icons.)
        row
        .padding(outer)
        .fixedSize()
        // Centered in a panel that never resizes, so the glass grows and shrinks around its centre in the same
        // animation as what changed inside it: the window never moves under it. The layer strip's apps move with the
        // same curve and length, laid out from the stage's centre, which stays put (`Row.update`).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: ScreenDock.glassAnimation), value: dock.itemIDs)
        .animation(.easeOut(duration: ScreenDock.glassAnimation), value: dock.stageSlots)
        .animation(.easeOut(duration: 0.22), value: dock.minimized.map(\.id))
        .animation(.easeOut(duration: 0.22), value: app.signals.nowPlaying == nil)
    }

    /// Room around the glass: for its shadow, and inward for icons lifting and bouncing.
    /// With magnification, it's room for the largest icons too, so the panel never resizes while they grow.
    private var outer: EdgeInsets { Self.outer(config, icon: icon) }

    /// The room around the glass (see `outer`), for anything placed by the glass rather than by the panel.
    static func outer(_ config: Config, icon: CGFloat) -> EdgeInsets {
        let slot = icon + (config.number("iconPadding") >= 0 ? config.number("iconPadding") : 5) * 2
        var room = icon * 0.55
        var along: CGFloat = 10
        if Magnifier.enabled {
            room = max(room, slot * Magnifier.amount + 6)
            along += Magnifier.room(slot: slot, amount: Magnifier.amount)
        }
        // On the screen's side: 2 points, then the gap to the screen's edge. The panel runs to the edge, so every
        // point between the dock and the edge is the dock's, never the desktop's under it.
        let edge = 2 + gap(config)
        switch config.position {
        case "left": return EdgeInsets(top: along, leading: edge, bottom: along, trailing: room)
        case "right": return EdgeInsets(top: along, leading: room, bottom: along, trailing: edge)
        default: return EdgeInsets(top: room, leading: along, bottom: edge, trailing: along)
        }
    }

    /// The gap between the dock and the screen's edge.
    static func gap(_ config: Config) -> CGFloat { config.number("dockMargin") >= 0 ? config.number("dockMargin") : 4 }

    /// The glass's own padding around its row of slots.
    static let rowPadding: CGFloat = 4

    /// How far below a slot (toward the screen's edge) its mouse reaches: the glass's padding, then the room under the
    /// glass to the panel's edge, which is the screen's.
    static func edgeRoom(_ config: Config) -> CGFloat { rowPadding + 2 + gap(config) }

    /// How far along past the first and last slot their mouse reaches: to the glass's end.
    static func endRoom(_ config: Config, icon: CGFloat) -> CGFloat { rowPadding }

    /// How far inward past its slot an icon is drawn at most: grown by magnification, or lifted on hover (it grows
    /// from the edge and rises, `lift`), less the room it has inside its slot and the glass.
    static func inwardReach(_ config: Config, icon: CGFloat) -> CGFloat {
        if Magnifier.enabled { return icon * Magnifier.amount * 1.3 }
        guard config.bool("hoverLift") else { return 0 }
        let inset = config.number("iconPadding") >= 0 ? config.number("iconPadding") : 5
        return max(0, icon * min(0.3, max(0, config.number("hoverLiftAmount"))) * 2.2 - inset)
    }

    private var glass: Glass {
        guard let tint = NSColor(hex: config.string("dockColor")) else { return .regular }
        return .regular.tint(Color(nsColor: tint).opacity(max(0.15, config.number("dockOpacity"))))
    }

    private var radius: CGFloat {
        let setting = config.number("dockRadius")
        return setting >= 0 ? min(setting, (slot + 8) / 2) : (slot + 8) / 2.6
    }

    /// The dock's apps, the running ones that aren't among them, and "+".
    @ViewBuilder private func stage(_ layout: AnyLayout, ends: DockEnds) -> some View {
        let length = CGFloat(dock.stageSlots) * slot
        if DockStrip.shared.layers && !snapshotting {
            AppStrip(dock: dock, length: length, slot: slot, startsDock: ends.contains(.start))
                .stripRoom(dock, icon: icon, slot: slot)
                .frame(width: dock.vertical ? slot : length, height: dock.vertical ? length : slot)
                .overlay(alignment: dock.vertical ? .top : .leading) {
                    StripAddSlot(dock: dock, icon: icon, slot: slot, length: length)
                        .environment(\.dockEnds, ends.intersection(dock.items.isEmpty ? [.start, .end] : [.end]))
                }
        } else {
            swiftUIStage(layout, length: length, ends: ends)
        }
    }

    @ViewBuilder private func swiftUIStage(_ layout: AnyLayout, length: CGFloat, ends: DockEnds) -> some View {
        layout {
            ForEach(Array(dock.items.enumerated()), id: \.element.id) { index, item in
                AppSlot(dock: dock, item: item, index: index, icon: icon, slot: slot)
                    .frame(width: slot, height: slot)
                    .magnified(dock, item.id)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                    .environment(\.dockEnds, index == 0 ? ends.intersection(.start) : [])
            }
            AddSlot(dock: dock, icon: icon).frame(width: slot, height: slot).magnified(dock, "add")
                .environment(\.dockEnds, ends.intersection(dock.items.isEmpty ? [.start, .end] : [.end]))
        }
        .frame(width: dock.vertical ? slot : length, height: dock.vertical ? length : slot)
    }
}

/// Where a mark of a slot's own (a dot, the equalizer) sits: on the side of the screen's edge, as the apps' dots do,
/// `distance` past the slot's middle toward that edge from its edge-side alignment.
@MainActor
enum DockEdge {
    static var alignment: Alignment {
        switch PetalApp.shared.config.position { case "left": .leading; case "right": .trailing; default: .bottom }
    }

    static func offset(_ distance: CGFloat) -> CGSize {
        switch PetalApp.shared.config.position {
        case "left": CGSize(width: -distance, height: 0)
        case "right": CGSize(width: distance, height: 0)
        default: CGSize(width: 0, height: distance)
        }
    }

    /// Turned so what stands up from the bottom edge stands out from a side edge.
    static var turn: Angle {
        switch PetalApp.shared.config.position { case "left": .degrees(90); case "right": .degrees(-90); default: .zero }
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

    /// Pressed: a little darker and smaller the moment the button goes down, as macOS's Dock does.
    func pressed(_ on: Bool) -> some View {
        brightness(on ? -0.22 : 0)
            .scaleEffect(on ? 0.92 : 1)
            .animation(.easeOut(duration: on ? 0.06 : 0.14), value: on)
    }

    /// A control's own surface on the dock's glass (the AI button, Finder's, "+"): clear Liquid Glass, so the layers
    /// read as glass on glass, not shapes stacked on it. Pressed, it
    /// shrinks as `pressed` does and what's on it darkens; the glass itself stays clear (darkened, it turns into a
    /// dark disc).
    func clearGlass<S: Shape>(in shape: S, pressed: Bool = false) -> some View {
        brightness(pressed ? -0.22 : 0)
            .glassEffect(.clear.interactive(), in: shape)
            .scaleEffect(pressed ? 0.92 : 1)
            .animation(.easeOut(duration: pressed ? 0.06 : 0.14), value: pressed)
    }

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

// MARK: - Claude button

struct ClaudeButton: View {
    @Environment(PetalApp.self) private var app
    let dock: ScreenDock
    let size: CGFloat
    @State private var hovering = false
    @State private var pressed = false
    /// A file is over it: it leans in, wide awake, with rings rippling out to say "give it here".
    @State private var fileOver = false
    /// Counts drops: each one plays the "gulp" (a squash and the file's icon falling in).
    @State private var swallowed = 0
    @State private var dropped: NSImage?

    var body: some View {
        ZStack {
            if fileOver { DropRipples(size: size, color: Color(nsColor: app.accent)) }
            ProviderMark(provider: app.chatProvider).foregroundStyle(.white.opacity(0.9))
                .frame(width: size * 0.56, height: size * 0.56)
                .scaleEffect(fileOver ? 1.22 : hovering ? 1.08 : 1)
                .rotationEffect(.degrees(fileOver ? -10 : 0))
                .phaseAnimator(app.claude.looseWorking ? [1.0, 0.4] : [1.0]) { mark, phase in mark.opacity(phase) } animation: { _ in .easeInOut(duration: 0.8) }
            if app.config.bool("claudeUsage") { UsageRing(usage: app.usage, size: size, line: 2.5, track: false) }
            if let dropped {
                Image(nsImage: dropped).resizable().frame(width: size * 0.5, height: size * 0.5)
                    .keyframeAnimator(initialValue: DropFall(), trigger: swallowed) { content, value in
                        content.offset(y: value.y).scaleEffect(value.scale).opacity(value.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.y) { LinearKeyframe(-size * 0.9, duration: 0); CubicKeyframe(0, duration: 0.28) }
                        KeyframeTrack(\.scale) { LinearKeyframe(1, duration: 0); CubicKeyframe(0.2, duration: 0.3) }
                        KeyframeTrack(\.opacity) { LinearKeyframe(1, duration: 0.2); LinearKeyframe(0, duration: 0.1) }
                    }
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(fileOver ? 1.12 : 1)
        .keyframeAnimator(initialValue: 1.0, trigger: swallowed) { content, scale in
            content.scaleEffect(x: scale, y: 2 - scale)
        } keyframes: { _ in
            KeyframeTrack { CubicKeyframe(1, duration: 0.22); SpringKeyframe(0.86, duration: 0.1); SpringKeyframe(1.0, duration: 0.35, spring: .bouncy) }
        }
        .clearGlass(in: .circle, pressed: pressed)
        // A sticky note waits for the person (its window in front, its tab showing, an answer): hovering shows which.
        .overlay(alignment: .topTrailing) {
            if app.claude.needsYou { Badge(text: "✦", icon: size * 0.8).offset(x: size * 0.08, y: -size * 0.08) }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.spring(response: 0.32, dampingFraction: 0.6), value: fileOver)
        .slotFrame(dock, "claude")
        // A second click closes what the first opened.
        .slotMouse(SlotMouse(left: { app.claude.toggle() }, right: { Menus.settings(for: dock) },
                           hover: { on in
                               hovering = on
                               // The notes at work, as an app's windows show; with none, the usage tooltip.
                               if app.previews.hoverNotes(on, in: dock) { app.tooltips.hide() }
                               else { app.tooltips.show(on ? app.usageTooltip : nil, over: "claude", in: dock) }
                           },
                           // Dragged out onto a spot: a blank Petal Note there (on the window under it, or the Desktop),
                           // as from the note pad.
                           drag: app.config.bool("notes") ? { _, ended in app.paper.dragPaper(ended: ended) } : nil,
                           // A file dropped on it goes to the AI: "summarize it", "what's in it?".
                           files: { urls in
                               dropped = urls.first.map { NSWorkspace.shared.icon(forFile: $0.path) }
                               swallowed += 1
                               DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { app.claude.open(asking: nil, attaching: urls) }
                           },
                           fileOver: { over in fileOver = over },
                           dropOperation: .generic,
                           press: { pressed = $0 }))
    }
}

/// Finder, as its own button by the AI button (macOS's Dock keeps Finder first too): Petal's
/// own mark for it on clear glass, a dot while it has windows, Finder's menu on a right-click, and files dropped on it
/// shown in Finder.
struct FinderButton: View {
    @Environment(PetalApp.self) private var app
    let dock: ScreenDock
    let size: CGFloat
    @State private var hovering = false
    @State private var pressed = false
    @State private var hop: CGFloat = 0

    var body: some View {
        let item = dock.finder
        let noteReady = app.claude.readyApps.contains(item.id)   // a sticky note on a Finder window is done
        ZStack(alignment: DockEdge.alignment) {
            FinderMark().stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: max(1.4, size * 0.045), lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.5, height: size * 0.5)
                .frame(width: size, height: size)
                .scaleEffect(hovering ? 1.08 : 1)
            if item.windows > 0 {
                Circle().fill(.white.opacity(item.active ? 0.95 : 0.6)).frame(width: 4, height: 4).offset(DockEdge.offset(size * 0.12))
            }
        }
        .frame(width: size, height: size)
        .clearGlass(in: .circle, pressed: pressed)
        .overlay(alignment: .topTrailing) {
            if noteReady { Badge(text: "✦", icon: size * 0.8).offset(x: size * 0.08, y: -size * 0.08) }
        }
        // The hop goes inward, away from the screen's edge.
        .offset(x: app.config.position == "left" ? hop * size * 0.4 : app.config.position == "right" ? -hop * size * 0.4 : 0,
                y: app.config.position == "bottom" ? -hop * size * 0.4 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onChange(of: app.signals.bounces[item.id]) { _, _ in
            guard app.config.bool("bounce") else { return }
            withAnimation(.easeOut(duration: 0.22)) { hop = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.interpolatingSpring(stiffness: 260, damping: 9)) { hop = 0 }
            }
        }
        .slotFrame(dock, DockView.finderSlot)
        .slotMouse(SlotMouse(left: {
                                 app.popups.closeAll()
                                 app.tooltips.hide()
                                 if app.claude.openReady(app: item.id) { return }
                                 // Its windows forward; none open, a new one, as macOS's Dock does.
                                 if item.windows > 0 { app.docks.activate(item) } else { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory())) }
                             },
                             right: { Menus.app(item) },
                             hover: { on in
                                 hovering = on
                                 app.tooltips.show(on ? "Finder" : nil, over: DockView.finderSlot, in: dock)
                             },
                             files: { urls in NSWorkspace.shared.activateFileViewerSelecting(urls) },
                             press: { pressed = $0 }))
    }
}

/// Petal's mark for Finder: its face in a few lines (the outline, the profile down the middle, the eyes, the smile).
struct FinderMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.addRoundedRect(in: rect, cornerSize: CGSize(width: w * 0.24, height: h * 0.24), style: .continuous)
        // The profile: down from the top, a nose to the left, back, down to the bottom.
        p.move(to: CGPoint(x: rect.minX + w * 0.54, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.46, y: rect.minY + h * 0.5))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.55, y: rect.minY + h * 0.52))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.52, y: rect.maxY))
        // The eyes.
        p.move(to: CGPoint(x: rect.minX + w * 0.27, y: rect.minY + h * 0.28))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.27, y: rect.minY + h * 0.4))
        p.move(to: CGPoint(x: rect.minX + w * 0.73, y: rect.minY + h * 0.28))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.73, y: rect.minY + h * 0.4))
        // The smile.
        p.move(to: CGPoint(x: rect.minX + w * 0.22, y: rect.minY + h * 0.66))
        p.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.78, y: rect.minY + h * 0.66), control: CGPoint(x: rect.midX, y: rect.minY + h * 0.86))
        return p
    }
}

/// Where a dropped file's icon is as it falls into the AI button.
struct DropFall {
    var y: CGFloat = 0
    var scale: CGFloat = 1
    var opacity: Double = 0
}

/// Rings rippling out from the AI button while a file is over it.
struct DropRipples: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<2) { i in
                    let phase = (t / 1.1 + Double(i) / 2).truncatingRemainder(dividingBy: 1)
                    Circle().strokeBorder(color.opacity(0.7 * (1 - phase)), lineWidth: 2)
                        .frame(width: size * (0.9 + 0.7 * phase), height: size * (0.9 + 0.7 * phase))
                }
            }
        }
        .allowsHitTesting(false)
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
    @State private var pressed = false
    @State private var hop: CGFloat = 0

    var body: some View {
        let config = app.config
        let dragged = dock.dragging == item.id
        let color = Color(nsColor: config.bool("appGlow") ? AppColor.of(item.id) : app.accent)
        let launching = app.launching[item.id] != nil
        ZStack {
            // Only the app in front glows, softly; a halo around every open app read as a pale haze over the icons.
            if config.bool("appGlow") && item.running {
                RadialGradient(colors: [color.opacity(0.45), color.opacity(0.12), .clear], center: .center,
                               startRadius: 0, endRadius: slot * 0.6)
                    .opacity((item.active ? 0.6 : 0) * min(1, max(0, config.number("glowStrength"))))
                    .animation(.easeOut(duration: 0.2), value: item.active)
            }
            DockIcon(id: item.id, size: icon)
                .pressed(pressed)
                .opacity((item.running || !item.pinned || Sites.isWeb(item.id) ? 1 : config.number("idleOpacity")) * (fileOver ? 0.6 : 1))
                .modifier(Pulse(on: launching, floor: config.number("idleOpacity")))
                .overlay(alignment: .topTrailing) {
                    // A sticky note done while away shows over the app's own badge until it's opened.
                    if let badge = app.claude.readyApps.contains(item.id) ? "✦" : config.bool("badges") ? app.signals.badges[item.id] : nil {
                        Badge(text: badge, icon: icon).offset(x: icon * 0.12, y: -icon * 0.12)
                    }
                }
        }
        .scaleEffect(dragged || fileOver ? 1.18 : 1)
        .opacity(dragged && dock.dragOut ? 0.4 : 1)   // out of the dock: let go, it's gone
        .lift(hovering && dock.dragging == nil, icon: icon)
        .offset(hopOffset)
        .overlay(alignment: dotAlignment) {
            if item.running && !dragged {
                Capsule().fill(color)
                    .frame(width: dock.vertical ? dot : dot * (item.windows > 1 ? 2.6 : 1),
                           height: dock.vertical ? dot * (item.windows > 1 ? 2.6 : 1) : dot)
                    .opacity(DockRules.dot(running: item.running, here: item.here, active: item.active))
                    .padding(1)
                    .animation(.easeOut(duration: 0.15), value: item.windows)
            }
        }
        .offset(dragShift)
        .zIndex(dragged ? 10 : 0)
        .slotFrame(dock, item.id)
        .slotMouse(SlotMouse(
            id: item.id,
            left: { app.popups.closeAll(); app.docks.activate(item) },
            right: { Menus.app(item) },
            middle: { app.docks.newWindow(item.id) },
            hover: { on in
                hovering = on
                app.previews.hover(on ? item : nil, in: dock, id: item.id)
                app.tooltips.show(on ? Apps.name(item.id) : nil, over: item.id, in: dock)
                if on && app.config.bool("recentFiles") { Apps.prefetchRecent(item.id) }
                if on && item.running { Apps.prefetchNewItem(item.id) }   // what ⌘N is, for its menu
            },
            drag: { delta, ended in drag(delta, ended: ended) },
            // Documents open with it (dropToOpen; never on a website shortcut); an app, a folder or an address is added.
            files: { urls in DockDrops.perform(DockDrops.items(urls), onApp: dropTarget) },
            takes: { urls in DockDrops.action(DockDrops.items(urls), onApp: dropTarget) != nil },
            fileOver: { fileOver = $0 },
            note: Sites.isWeb(item.id) ? nil : { id in app.paper.use(id, in: item.id) },
            press: { pressed = $0 }))
        .onChange(of: app.signals.bounces[item.id]) { _, _ in bounce() }
    }

    private var dot: CGFloat { max(4, icon * 0.13) }

    /// The app documents dropped here open with: this one, with dropToOpen on and not a website shortcut.
    private var dropTarget: String? { app.config.bool("dropToOpen") && !Sites.isWeb(item.id) ? item.id : nil }

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

    /// While an app is dragged, it follows the pointer and the apps it passes make room; out of the dock, the apps
    /// after it close the gap it leaves.
    private var dragShift: CGSize {
        guard let dragging = dock.dragging, let from = dock.items.firstIndex(where: { $0.id == dragging }) else { return .zero }
        var shift: CGFloat = 0
        if dragging == item.id {
            shift = dock.dragOffset
        } else if dock.dragOut {
            if index > from { shift = -slot }
        } else {
            let to = from + Int((dock.dragOffset / slot).rounded())
            if from < index && index <= to { shift = -slot }
            if to <= index && index < from { shift = slot }
        }
        return dock.vertical ? CGSize(width: 0, height: shift) : CGSize(width: shift, height: 0)
    }

    private func drag(_ delta: CGFloat, ended: Bool) {
        let kept = app.config.apps.contains(item.id)
        // How far past the glass the pointer is (out of the dock past a slot).
        let inward = dock.panel?.inward(of: NSEvent.mouseLocation) ?? 0
        if ended {
            let from = dock.items.firstIndex { $0.id == item.id } ?? 0
            // Where the pointer is as it's let go, not how the icon looks (only one of the dock's own fades out).
            let end = DockRules.dragEnd(began: dock.dragging == item.id, from: from, offset: dock.dragOffset, slot: slot,
                                        count: dock.items.count, kept: kept, inward: inward)
            withAnimation(.easeOut(duration: 0.15)) { dock.dragging = nil; dock.dragOffset = 0; dock.dragOut = false }
            switch end {
            case .click:
                app.popups.closeAll()
                app.docks.activate(item)
            case .move(let to): app.docks.move(item.id, to: to, in: dock)
            case .remove: app.config.removeApp(item.id)
            case .nothing: break
            }
            return
        }
        if dock.dragging == nil {
            guard abs(delta) >= 6 || DockRules.isOut(inward: inward, slot: slot) else { return }
            app.popups.closeAll()
            app.previews.hover(nil, in: dock, id: item.id)
            app.tooltips.hide()
            dock.dragging = item.id
        }
        dock.dragOffset = delta
        let fades = DockRules.fades(inward: inward, slot: slot, kept: kept)
        if dock.dragOut != fades { withAnimation(.easeOut(duration: 0.12)) { dock.dragOut = fades } }
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
            .font(.system(size: height * 0.62, weight: .semibold))
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

/// "+": add apps, folders or websites to the dock. A plus in Petal's accent on a clear glass tile. The layer strip
/// leaves its slot empty and the dock puts this over it (see `DockView.stage`), so it's real glass either way.
struct AddSlot: View {
    @Environment(PetalApp.self) private var app
    let dock: ScreenDock
    let icon: CGFloat
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        let color = Color(nsColor: app.accent)
        let side = icon * 0.8
        Image(systemName: "plus").font(.system(size: icon * 0.36, weight: .bold)).foregroundStyle(color)
            .scaleEffect(hovering ? 1.08 : 1)
            .frame(width: side, height: side)
            .clearGlass(in: .rect(cornerRadius: side * 0.28), pressed: pressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .lift(hovering, icon: icon)
            .slotFrame(dock, "add")
            .slotMouse(SlotMouse(left: { if app.search.isOpen { app.search.close() } else { app.popups.closeAll(); app.search.open(in: dock) } }, right: { Menus.settings(for: dock) },
                               hover: { on in
                                   hovering = on
                                   app.tooltips.show(on ? "Add to the dock" : nil, over: "add", in: dock)
                               },
                               files: { urls in DockDrops.perform(DockDrops.items(urls), onApp: nil) },
                               takes: { urls in DockDrops.action(DockDrops.items(urls), onApp: nil) != nil },
                               press: { pressed = $0 }))
    }
}

/// "+" over the layer strip, which draws the apps and keeps the slot after them for it (a layer can't be glass): at
/// the same place, start + count × slot along the stage, moving there with the strip's apps. Its own view, so the
/// apps changing updates only this, never the rest of the dock.
struct StripAddSlot: View {
    let dock: ScreenDock
    let icon: CGFloat
    let slot: CGFloat
    let length: CGFloat

    var body: some View {
        let count = CGFloat(dock.appCount)
        AddSlot(dock: dock, icon: icon).frame(width: slot, height: slot).magnified(dock, "add")
            .padding(dock.vertical ? .top : .leading, (length + (count - 1) * slot) / 2)
            .animation(.easeOut(duration: 0.22), value: count)
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
        .overlay(alignment: DockEdge.alignment) {
            // Its bars stand up from the screen's edge: under the icon, or beside it on a side dock.
            if playing.playing {
                let bars = max(4, icon * 0.16)   // Equalizer's height; it's 10 points wide
                Equalizer(icon: icon).rotationEffect(DockEdge.turn)
                    .offset(DockEdge.offset(dock.vertical ? icon * 0.22 + 5 - bars / 2 : icon * 0.22))
            }
        }
        .lift(hovering, icon: icon)
        .slotFrame(dock, "media")
        .slotMouse(SlotMouse(left: { app.signals.control("playpause") },
                           right: { Menus.media(playing) },
                           middle: { app.signals.control("next track") },
                           hover: { on in
                               hovering = on
                               // The song and its controls, in a pop-over that stays while the pointer moves into it.
                               app.previews.hoverMedia(on, in: dock)
                           }))
    }
}

// The equalizer is in Motion.swift.

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
        .slotMouse(SlotMouse(left: { Windows.focus(window) }, right: { Menus.minimized(window, app: bundleID) },
                           middle: { Windows.focus(window) },
                           hover: { on in
                               hovering = on
                               let name = window.title.isEmpty ? Apps.name(bundleID) : window.title
                               app.tooltips.show(on ? "\(name) (minimized)" : nil, over: "min:\(window.id)", in: dock)
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
            // A notebook of Petal Notes: a little pile of paper in its color.
            if let book = app.paper.notebook(forStack: folder) {
                NotebookPile(color: app.paper.store.color(of: book.name), icon: icon)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Stacks.url(folder).path)).resizable().frame(width: icon, height: icon)
            }
            if app.config.bool("progress"), let progress = app.signals.progress[folder] {
                Circle().stroke(.white.opacity(0.18), lineWidth: 3).frame(width: icon + 8, height: icon + 8)
                Circle().trim(from: 0, to: max(0.02, progress))
                    .stroke(Color(nsColor: app.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: icon + 8, height: icon + 8)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Something new since the stack was last opened: a dot, not a count. Counts are for unread messages.
            if app.signals.fresh.contains(folder) && app.signals.progress[folder] == nil && dock.openPopup != key {
                NewDot(icon: icon).offset(x: icon * 0.04, y: -icon * 0.04).transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.signals.fresh.contains(folder))
        .lift(hovering, icon: icon)
        .overlay(alignment: DockEdge.alignment) {
            if dock.openPopup == key { Circle().fill(Color(nsColor: app.accent)).frame(width: 4, height: 4).offset(DockEdge.offset(5)) }
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

/// A small dot in Petal's accent: something new is in a stack.
struct NewDot: View {
    let icon: CGFloat

    var body: some View {
        let size = max(7, icon * 0.2)
        Circle().fill(Color(nsColor: PetalApp.shared.accent))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
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
            .slotMouse(SlotMouse(left: {
                                   // The tooltip and any preview go with the click, as they do for an app.
                                   app.popups.closeAll()
                                   app.previews.hover(nil, in: dock)
                                   Stacks.openTrash()
                               }, right: { Menus.trash() },
                               hover: { on in
                                   hovering = on
                                   app.tooltips.show(on ? "Trash" : nil, over: "trash", in: dock)
                               },
                               files: { Stacks.moveToTrash($0.filter(\.isFileURL)) },
                               takes: { $0.contains(where: \.isFileURL) }, fileOver: { fileOver = $0 }, dropOperation: .move))
    }
}

/// A slot's mouse: left, right and middle clicks, hover, dragging along the dock, and files dropped on it. AppKit
/// does this directly, since the dock never becomes the key window.
struct SlotMouse: NSViewRepresentable {
    /// The dock's first or last slot: its mouse reaches along to that end of the glass, so where SwiftUI puts it this
    /// moment is where that end of the glass is drawn (`ScreenDock.glassNow`).
    var ends: DockEnds = []
    /// Whose mouse it is (an app's bundle identifier), for `Petal --bench-dock` to tell which slot a click reaches.
    var id: String?
    var left: () -> Void = {}
    var right: () -> Void = {}
    var middle: () -> Void = {}
    var hover: (Bool) -> Void = { _ in }
    var drag: ((CGFloat, Bool) -> Void)? = nil
    /// Files or web addresses dropped on it.
    var files: (([URL]) -> Void)? = nil
    /// Whether it takes what's dragged over it (nil: anything `files` would get).
    var takes: (([URL]) -> Bool)? = nil
    var fileOver: (Bool) -> Void = { _ in }
    /// A note dropped on it (Petal Notes): its id.
    var note: ((String) -> Void)? = nil
    /// What a drag over it shows: a copy ("+") into an app, or nothing extra where the slot has its own animation.
    var dropOperation: NSDragOperation = .copy
    /// The button went down (true) or up, or a drag took over (false): for feedback the moment it's pressed. What a
    /// click does still happens on the way up, so a press can turn into a drag.
    var press: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> MouseView { MouseView() }
    func updateNSView(_ view: MouseView, context: Context) { view.handlers = self }

    final class MouseView: NSView {
        var handlers: SlotMouse? {
            didSet {
                registerEnds()
                let wanted: [NSPasteboard.PasteboardType] = (handlers?.files != nil ? DockDrops.types : []) + (handlers?.note != nil ? [.petalNote] : [])
                if wanted != registered {
                    unregisterDraggedTypes()
                    if !wanted.isEmpty { registerForDraggedTypes(wanted) }
                    registered = wanted
                }
            }
        }
        private var registered: [NSPasteboard.PasteboardType] = []
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

        private var inside = false
        private var leftObserver: Any?

        /// The dock's end slots tell their dock where they are.
        private func registerEnds() {
            guard let dock = (window as? DockPanel)?.dock else { return }
            let ends = handlers?.ends ?? []
            if ends.contains(.start) { dock.startMouse = self } else if dock.startMouse === self { dock.startMouse = nil }
            if ends.contains(.end) { dock.endMouse = self } else if dock.endMouse === self { dock.endMouse = nil }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            registerEnds()
            if let leftObserver { NotificationCenter.default.removeObserver(leftObserver) }
            leftObserver = nil
            guard let window else { return }
            // The dock stops taking the mouse as the pointer leaves it, sometimes before macOS says the pointer left
            // this slot: a slot would stay hovered (and keep its highlight). The dock says so instead.
            leftObserver = NotificationCenter.default.addObserver(forName: DockPanel.mouseLeft, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.inside else { return }
                    self.inside = false
                    self.handlers?.hover(false)
                }
            }
        }

        override func mouseEntered(with event: NSEvent) {
            (window as? DockPanel)?.dock.magnifier.wake()
            // Only where the dock takes the click: a tooltip never shows where a click would go to the desktop.
            if let panel = window as? DockPanel, !panel.takesMouse(at: NSEvent.mouseLocation) { return }
            inside = true
            handlers?.hover(true)
        }
        override func mouseExited(with event: NSEvent) {
            inside = false
            handlers?.hover(false)
        }

        override func mouseDown(with event: NSEvent) {
            down = NSEvent.mouseLocation
            dragging = false
            handlers?.press(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down, let drag = handlers?.drag else { return }
            let point = NSEvent.mouseLocation
            let vertical = PetalApp.shared.config.position != "bottom"
            let delta = vertical ? down.y - point.y : point.x - down.x
            if !dragging && (abs(point.x - down.x) > 4 || abs(point.y - down.y) > 4) {
                dragging = true
                handlers?.press(false)
            }
            if dragging { drag(delta, false) }
        }

        override func mouseUp(with event: NSEvent) {
            if !dragging { handlers?.press(false) }
            if dragging { handlers?.drag?(0, true) } else {
                // Any click on the dock (an app, a website, Finder, the AI button, "+"): an earlier click
                // still bringing a window forward stands down, so it can't come up over what this one opens.
                Windows.focusing.cancel()
                handlers?.left()
            }
            down = nil
            dragging = false
        }

        override func rightMouseDown(with event: NSEvent) { handlers?.right() }

        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 { handlers?.middle() }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            PetalApp.shared.docks.revealAll()
            let note = handlers?.note != nil && sender.draggingPasteboard.types?.contains(.petalNote) == true
            if !note, let takes = handlers?.takes, !takes(Self.urls(sender)) { return [] }
            handlers?.fileOver(true)
            return handlers?.dropOperation ?? .copy
        }

        private static func urls(_ sender: NSDraggingInfo) -> [URL] { DockDrops.urls(sender) }

        override func draggingExited(_ sender: NSDraggingInfo?) { handlers?.fileOver(false) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            handlers?.fileOver(false)
            if let id = sender.draggingPasteboard.data(forType: .petalNote).map({ String(decoding: $0, as: UTF8.self) }), let note = handlers?.note {
                note(id)
                return true
            }
            let urls = Self.urls(sender)
            guard !urls.isEmpty, let files = handlers?.files, handlers?.takes?(urls) ?? true else { return false }
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

        // An app, a folder or a web address let go on the dock's glass is added to it.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { registerForDraggedTypes(DockDrops.types) }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            PetalApp.shared.docks.revealAll()
            return draggingUpdated(sender)
        }

        // (Weighed again as it moves: a folder Petal looked at off the main thread counts from then on.)
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            DockDrops.action(DockDrops.items(sender), onApp: nil) == nil ? [] : .copy
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            DockDrops.perform(DockDrops.items(sender), onApp: nil)
        }
    }
}

/// The dock's hosting view, which notes when SwiftUI says its content's size may have changed, so the dock is
/// measured only then.
final class DockHostingView: NSHostingView<AnyView> {
    var sizeChanged = true

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        // Only its size for measuring: no minimum or maximum that would make the window follow the content.
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        sizeChanged = true
        // Measured again (and the icons fitted to the screen again) with the change that resized it, not at the next
        // look at the windows seconds later, which moved the dock a second time.
        guard !placing else { return }
        placing = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.placing = false
                if self.sizeChanged, let panel = self.window as? DockPanel { panel.placeAgain() }
            }
        }
    }
    private var placing = false

    /// The content's own size (the glass and the room around it), laid out now.
    func measure() -> CGSize {
        layoutSubtreeIfNeeded()
        sizeChanged = false
        return intrinsicContentSize
    }

    /// A plain view holding the hosting view at its full size, so the window's size is the panel's alone.
    static func container(_ hosting: DockHostingView) -> NSView {
        let container = NSView()
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        return container
    }
}
