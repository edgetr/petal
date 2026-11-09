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
    var items: [DockItem] = [] { didSet { if items.count != appCount { appCount = items.count } } }
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
    var revealed = true
    var openPopup: String?          // the slot whose stack, preview or menu is open
    @ObservationIgnored var order: [String] = []
    @ObservationIgnored var frames: [String: CGRect] = [:]   // slot frames in the panel, top-left origin
    @ObservationIgnored weak var panel: DockPanel?
    /// Every mode's apps as this screen would show them, for the layer strip's rows made ahead of time.
    @ObservationIgnored var rows: [String: [DockItem]] = [:]
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

    /// Each app's minimized windows, across Desktops and modes. Read again only for an app whose windows opened,
    /// closed, minimized or came back (and once for every app when the events start), never by scanning every app.
    private var minimizedByApp: [pid_t: [AppWindow]] = [:]
    /// Apps with a window event lately, by when: each look in the second after reads them, so the trailing look
    /// catches a window the app listed late.
    private var minimizedChanged: [pid_t: Double] = [:]
    private var readAllMinimized = true
    private var polls = 0

    private func minimizedToRead() -> (all: Bool, changed: Set<pid_t>) {
        guard config.bool("minimized"), eventsLive else {
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
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
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
            let showing = Perf.span("refresh: desktop") { Spaces.showing(on: screen) }
            let desktop = showing.desktop
            if desktop != nil || dock.mode == nil {   // a full-screen app keeps the mode of the Desktop before it
                dock.desktop = desktop
            }
            panel.fullScreen = showing.fullScreen
            panel.aside = missionControl   // a screen joining while Mission Control is open
            let mode = modesOn ? config.mode(forDesktop: dock.desktop ?? 1) : config.modes.first
            Perf.span("refresh: set mode") { if mode != dock.mode { dock.mode = mode } }
            let here = Set(snapshot.apps(on: screen))
            let otherModes = Set(config.modes.filter { $0.id != mode?.id }.flatMap(\.apps))

            var items: [DockItem] = []
            func item(_ bundleID: String, pinned: Bool) -> DockItem {
                DockItem(id: bundleID, pinned: pinned, running: running[bundleID] != nil, windows: snapshot.count[bundleID] ?? 0,
                         here: here.contains(bundleID), active: bundleID == frontmost)
            }
            // Finder is its own button by the AI button (FinderButton), the same in every mode: never among the apps.
            let finder: [DockItem] = []
            let finderButton = config.bool("finderInDock")
            for bundleID in mode?.apps ?? [] where Apps.shows(bundleID) && !items.contains(where: { $0.id == bundleID })
                && !(finderButton && bundleID == Self.finder) {
                items.append(item(bundleID, pinned: true))
            }
            for bundleID in snapshot.order where running[bundleID] != nil && !items.contains(where: { $0.id == bundleID })
                && !(finderButton && bundleID == Self.finder) {
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
            let finderNow = item(Self.finder, pinned: true)
            if finderNow != dock.finder { dock.finder = finderNow }
            // The layer strip keeps every mode's row ready: each mode's apps, then the running apps in no mode.
            if DockStrip.shared.layers {
                let loose = ordered.filter { !$0.pinned }
                var rows: [String: [DockItem]] = [:]
                for other in modesOn ? config.modes : Array(config.modes.prefix(1)) where other.id != mode?.id {
                    var seen = Set<String>()
                    if finderButton { seen.insert(Self.finder) }
                    rows[other.id] = finder + other.apps.filter { Apps.shows($0) && seen.insert($0).inserted }.map { item($0, pinned: true) } + loose
                }
                rows[mode?.id ?? ""] = ordered
                dock.rows = rows
            }
            if dock.minimized != minimizedAll { dock.minimized = minimizedAll }

            // The stage is as long as the most apps any mode would show here, so switching never moves the rest.
            let longest = Perf.span("refresh: stage") {
                config.modes.map { m in m.apps.filter { Apps.shows($0) && !(finderButton && $0 == Self.finder) }.count }.max() ?? 0
            }
            let slots = max(longest + finder.count, ordered.count) + 1
            if slots != dock.stageSlots { dock.stageSlots = slots }

            Perf.span("refresh: place panel") { panel.place(on: screen) }
        }
        Perf.span("refresh: keep windows clear") { keepWindowsClear(snapshot) }
        Perf.span("refresh: automation") { app.automation.modeShown(dock(for: NSScreen.main)?.mode?.id) }
        Perf.span("refresh: menu bar") { app.menuBar.show(mode: dock(for: NSScreen.main)?.mode) }
        Perf.span("refresh: notes") { app.notes.update() }
    }

    /// macOS keeps no room for a dock other than its own, so windows would run under Petal's. While auto-hide is
    /// off, a window reaching into the dock's strip is shortened to end where the dock's glass begins (or narrowed,
    /// for a side dock); one too small to shorten is moved out instead. Omarchy reserves the same strip for its dock.
    ///
    /// Petal remembers each window's frame from before it touched it. A new position (or icon size) starts again
    /// from that frame, so windows never shrink step by step as the dock moves around; turning this off, or
    /// auto-hide on, or the window's screen going full screen, gives it back. A window moved or resized since is
    /// the person's, and forgotten.
    private func keepWindowsClear(_ snapshot: WindowList) {
        guard Windows.trusted else { return }
        let on = config.keepWindowsClear && !config.autoHide
        guard on || !cleared.isEmpty else { return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let docks = panels.values.compactMap { panel -> (panel: DockPanel, screen: CGRect)? in
            guard let area = panel.screenRef?.frame else { return nil }
            return (panel, CGRect(x: area.minX, y: top - area.maxY, width: area.width, height: area.height))   // top-left origin
        }
        var moves: [(pid: pid_t, number: CGWindowID, from: CGRect, to: CGRect)] = []
        for window in snapshot.onScreenWindows {
            // Parked by its mode (Parking): its frame there is Parking's, not the person's, so its record (and the
            // frame from before Petal touched it) stays as it is until it comes back.
            if Parking.parked[window.number] != nil { continue }
            let now = window.frame
            var before = now
            if let record = cleared[window.number] {
                // A frame Petal gave it, or one it had on the way (the look may be a moment old): still Petal's
                // doing. Any other frame is the person's.
                if record.knows(now) { before = record.before } else { cleared[window.number] = nil }
            }
            var target = before
            let center = CGPoint(x: before.midX, y: before.midY)
            if on, let dock = docks.first(where: { $0.screen.contains(center) }), !dock.panel.fullScreen {
                target = Self.clear(before, screen: dock.screen, reach: dock.panel.reach, position: config.position)
            }
            let moving = !target.equalTo(now, within: 2)
            guard moving || cleared[window.number] != nil || !target.equalTo(before, within: 1) else { continue }
            var record = cleared[window.number] ?? Cleared(before: before)
            record.saw(now)
            record.saw(target)
            cleared[window.number] = record
            if moving { moves.append((window.pid, window.number, now, target)) }
        }
        // Windows that closed: nothing to give back.
        cleared = cleared.filter { snapshot.numbers.contains($0.key) }
        guard !moves.isEmpty else { return }
        // Accessibility waits on each app: never on the main thread.
        Self.clearQueue.async {
            for move in moves {
                let app = AXUIElementCreateApplication(move.pid)
                AXUIElementSetMessagingTimeout(app, 0.3)
                let list: [AXUIElement] = Windows.value(app, kAXWindowsAttribute) ?? []
                guard let element = list.first(where: { Windows.id(of: $0) == move.number }),
                      // Still where it was when this was decided: moved since (by the person, Parking, a newer
                      // look), it's left alone.
                      let there = Windows.frame(of: element), there.equalTo(move.from, within: 4) else { continue }
                let actual = Windows.place(element, pid: move.pid, move.to)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Where the app let it go (an app may keep a minimum size), which is now Petal's frame for it.
                        guard let controller = PetalApp.shared.docks, let actual else { return }
                        controller.cleared[move.number]?.saw(actual)
                    }
                }
            }
        }
    }

    /// A window kept clear of the dock: its own frame from before, and the frames it has had since through Petal
    /// (the ones Petal gave it, where it was moving from, where the app let it go). Kept until the window closes or
    /// the person moves it, so a look at the windows from a moment before a move never mistakes Petal's frame for
    /// theirs.
    struct Cleared {
        var before: CGRect
        private var frames: [CGRect] = []

        init(before: CGRect) { self.before = before }

        func knows(_ frame: CGRect) -> Bool {
            before.equalTo(frame, within: 4) || frames.contains { $0.equalTo(frame, within: 4) }
        }

        mutating func saw(_ frame: CGRect) {
            guard !knows(frame) else { return }
            frames.append(frame)
            if frames.count > 12 { frames.removeFirst() }
        }
    }

    /// The frame `f` keeps clear of a dock reaching `reach` in from `screen`'s edge (both top-left origin).
    nonisolated static func clear(_ f: CGRect, screen: CGRect, reach: CGFloat, position: String) -> CGRect {
        switch position {
        case "left":
            let limit = screen.minX + reach
            guard f.minX < limit - 1, f.maxX > limit else { return f }
            return f.maxX - limit >= 300 ? CGRect(x: limit, y: f.minY, width: f.maxX - limit, height: f.height)
                : CGRect(x: limit, y: f.minY, width: f.width, height: f.height)
        case "right":
            let limit = screen.maxX - reach
            guard f.maxX > limit + 1, f.minX < limit else { return f }
            return limit - f.minX >= 300 ? CGRect(x: f.minX, y: f.minY, width: limit - f.minX, height: f.height)
                : CGRect(x: limit - f.width, y: f.minY, width: f.width, height: f.height)
        default:
            let limit = screen.maxY - reach
            guard f.maxY > limit + 1, f.minY < limit else { return f }
            return limit - f.minY >= 200 ? CGRect(x: f.minX, y: f.minY, width: f.width, height: limit - f.minY)
                : CGRect(x: f.minX, y: max(screen.minY + 30, limit - f.height), width: f.width, height: f.height)
        }
    }

    /// Windows kept clear of the dock, by window number: the frame each had before and the one Petal gave it.
    private var cleared: [CGWindowID: Cleared] = [:]
    nonisolated private static let clearQueue = DispatchQueue(label: "petal.windows.clear", qos: .userInitiated)

    /// How far the dock on `screen` reaches in from its edge: where windows kept clear of it end.
    func reach(on screen: NSScreen?) -> CGFloat? {
        guard shown, let screen, let id = screen.displayID, let panel = panels[id], !panel.fullScreen else { return nil }
        return panel.reach
    }

    func dock(for screen: NSScreen?) -> ScreenDock? {
        guard let id = (screen ?? NSScreen.main)?.displayID else { return panels.values.first?.dock }
        return panels[id]?.dock ?? panels.values.first?.dock
    }

    /// The dock on the screen with the window in front: where cards go.
    /// The dock on the screen of the window in front. One screen has one dock; with more, the last look at the
    /// windows says where the window in front is, so asking costs nothing.
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
        Windows.focusing.cancel()   // first, whatever this click turns out to be: an earlier one's focus stands down
        if Sites.isWeb(item.id) { Sites.open(item.id); return }
        if app.claude.openReady(app: item.id) { return }   // its note is done: its window, and the note on it
        guard item.running, let running = NSRunningApplication.runningApplications(withBundleIdentifier: item.id).first else {
            launch(item.id)
            return
        }
        if Perf.span("activate: parking", { Parking.activate(item.id) }) { return }   // each mode keeps its own windows
        // Decided here from what the dock already knows; the app's windows are listed (Accessibility, which waits on
        // a busy app) on the focus queue, and a newer click makes this one stand down.
        let pid = running.processIdentifier, active = item.active, known = item.windows, id = item.id
        let onScreen = (lastSnapshot ?? WindowList.current()).onScreenFrames(pid: pid)
        let ticket = Windows.focusing.next()
        Windows.focusQueue.async {
            guard Windows.focusing.current(ticket) else { return }
            let windows = Windows.windows(of: pid)
            func rank(_ w: AppWindow) -> Int { w.minimized ? 1 : (onScreen.contains { $0.equalTo(w.frame, within: 4) } ? 0 : 2) }
            let sorted = windows.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
            var pick = sorted.first
            if active, !sorted.isEmpty {
                // The window in front now: the next one along comes forward (clicking again cycles through them).
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.3)
                let focused: String = (Windows.value(app, kAXFocusedWindowAttribute) as AXUIElement?).flatMap { Windows.value($0, kAXTitleAttribute) } ?? ""
                if let index = sorted.firstIndex(where: { $0.title == focused && !$0.minimized }) { pick = sorted[(index + 1) % sorted.count] }
            }
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
        app.launching[id] = (Date(), (lastSnapshot ?? WindowList.current()).count[id] ?? 0)
        setPolling()   // once a second until its window shows
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
        Windows.focusing.cancel()   // an earlier click's focus still on its way would come in front of the new window
        if Sites.isWeb(id) { Sites.open(id); return }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { launch(id); return }
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
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) { app.terminate() }
    }

    func minimizeAll(_ id: String) {
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: id).map(\.processIdentifier)
        DispatchQueue.global(qos: .userInitiated).async {   // listing the windows waits on the app too
            for pid in pids {
                for window in Windows.windows(of: pid) where !window.minimized { Windows.minimize(window) }
            }
        }
    }

    func hide(_ id: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) { app.hide() }
    }

    // MARK: Reordering

    /// Dropping an app at a new place saves the new order as the mode's apps. Dragging an app that isn't in the
    /// mode into place adds it.
    func move(_ id: String, to index: Int, in dock: ScreenDock) {
        // Finder stays first; nothing goes before it.
        guard id != Self.finder, let mode = dock.mode, let from = dock.items.firstIndex(where: { $0.id == id }) else { return }
        var keys = dock.items.map(\.id)
        keys.remove(at: from)
        let first = keys.first == Self.finder ? 1 : 0
        keys.insert(id, at: min(max(first, index), keys.count))
        let shown = keys.filter { key in key != Self.finder && (key == id || dock.items.first { $0.id == key }?.pinned == true) }
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
    var onScreenWindows: [(pid: pid_t, frame: CGRect, number: CGWindowID)] { onScreen.map { ($0.pid, $0.frame, $0.number) } }
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
    func updateMouseThrough() {
        let wanted = tucked || !contentFrame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        guard ignoresMouseEvents != wanted else { return }
        ignoresMouseEvents = wanted
        if wanted { NotificationCenter.default.post(name: Self.mouseLeft, object: self) }
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

    /// The dock's content (the glass and the clear room around it), centered in the panel. The panel itself is as
    /// long as the screen's edge, so it never resizes while the dock grows or shrinks: SwiftUI animates the glass
    /// around its centre instead. Its clear parts let clicks through to the windows below.
    var contentFrame: CGRect {
        let size = measured ?? frame.size
        return CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The glass itself, without the clear room around it for lifting and bouncing icons: tooltips, previews and
    /// stacks sit just above this, as they do over macOS's Dock.
    var glassFrame: CGRect {
        let room = DockView.outer(config, icon: dock.icon)
        let content = contentFrame
        return CGRect(x: content.minX + room.leading, y: content.minY + room.bottom,
                      width: content.width - room.leading - room.trailing, height: content.height - room.top - room.bottom)
    }

    /// The gap between the dock and the screen's edge (Omarchy's `gap`).
    var gap: CGFloat { config.number("dockMargin") >= 0 ? config.number("dockMargin") : 4 }

    /// How far the glass reaches in from the screen's edge: windows kept clear of the dock end right there.
    var reach: CGFloat {
        let size = measured ?? frame.size
        let room = DockView.outer(config, icon: dock.icon)
        switch config.position {
        case "left": return gap + size.width - room.trailing
        case "right": return gap + size.width - room.leading
        default: return gap + size.height - room.top
        }
    }

    /// Something open over the dock keeps it out while auto-hide is on.
    var busy: Bool { dock.openPopup != nil || dock.dragging != nil || PetalApp.shared.overlayOpen }

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
        // A new position (or icon size) lays the dock out the other way: the last measure doesn't hold.
        let shape = "\(config.position)|\(config.number("iconSize"))|\(config.number("iconPadding"))|\(config.number("dockMargin"))|\(screen.frame)"
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
        case "left":
            size = CGSize(width: content.width, height: visible.height)
            origin = CGPoint(x: area.minX + gap, y: visible.minY)
        case "right":
            size = CGSize(width: content.width, height: visible.height)
            origin = CGPoint(x: area.maxX - content.width - gap, y: visible.minY)
        default:
            size = CGSize(width: area.width, height: content.height)
            origin = CGPoint(x: area.minX, y: area.minY + gap)
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

    func reveal() {
        dock.revealed = true
        if let screenRef { place(on: screenRef) }
    }

    /// Measures the dock with the icons as large as the setting asks, or, when that many wouldn't fit in `room`
    /// along the screen's edge, as large as fits (not under 16 points), as macOS's Dock does. The dock's length is
    /// the icons' share, which grows with them, plus a fixed part (padding, the mode's name): two measures tell
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
    func screenFrame(of id: String) -> CGRect? {
        guard let rect = dock.frames[id] else { return nil }
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
            if config.bool("finderInDock") {
                FinderButton(dock: dock, size: icon * 0.95).frame(width: slot, height: slot).magnified(dock, Self.finderSlot)
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
        // Centered in a panel that never resizes, so the glass grows and shrinks around its centre in the same
        // animation as what changed inside it: the window never moves under it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // (The layer strip animates its own apps, and its stage never changes size with them.)
        .animation(.easeOut(duration: 0.22), value: DockStrip.shared.layers && !snapshotting ? [] : dock.items.map(\.id))
        .animation(.easeOut(duration: 0.22), value: dock.minimized.map(\.id))
        .animation(.easeOut(duration: 0.24), value: dock.mode?.id)
        .animation(.easeOut(duration: 0.24), value: app.pendingMode?.mode)
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
        if DockStrip.shared.layers && !snapshotting {
            AppStrip(dock: dock, length: length, slot: slot)
                .stripRoom(dock, icon: icon, slot: slot)
                .frame(width: dock.vertical ? slot : length, height: dock.vertical ? length : slot)
                .overlay(alignment: dock.vertical ? .top : .leading) { StripAddSlot(dock: dock, icon: icon, slot: slot, length: length) }
        } else {
            swiftUIStage(layout, length: length)
        }
    }

    @ViewBuilder private func swiftUIStage(_ layout: AnyLayout, length: CGFloat) -> some View {
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

    /// Pressed: a little darker and smaller the moment the button goes down, as macOS's Dock does.
    func pressed(_ on: Bool) -> some View {
        brightness(on ? -0.22 : 0)
            .scaleEffect(on ? 0.92 : 1)
            .animation(.easeOut(duration: on ? 0.06 : 0.14), value: on)
    }

    /// A control's own surface on the dock's glass (the mode switcher, the AI button, "+"): clear Liquid Glass, so
    /// the layers read as glass on glass, not shapes stacked on it. `on` false adds no glass at all (another mode's
    /// button until the pointer is on it), not `.identity` glass, which still costs on every update. Pressed, it
    /// shrinks as `pressed` does and what's on it darkens; the glass itself stays clear (darkened, it turns into a
    /// dark disc).
    func clearGlass<S: Shape>(_ on: Bool = true, in shape: S, pressed: Bool = false) -> some View {
        brightness(pressed ? -0.22 : 0)
            .modifier(ClearGlass(on: on, shape: shape))
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

/// See `clearGlass`.
struct ClearGlass<S: Shape>: ViewModifier {
    let on: Bool
    let shape: S

    func body(content: Content) -> some View {
        if on { content.glassEffect(.clear.interactive(), in: shape) } else { content }
    }
}

// The mode switcher is in Switcher.swift.

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
                           // Dragged out onto a spot: a blank Petal Note there (on the window under it, or the Desktop).
                           drag: app.config.bool("notes") ? { _, ended in app.paper.dragFromAI(ended: ended) } : nil,
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

/// Finder, as its own button by the AI button, the same in every mode (macOS's Dock keeps Finder first too): Petal's
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
        ZStack(alignment: .bottom) {
            FinderMark().stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: max(1.4, size * 0.045), lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.5, height: size * 0.5)
                .frame(width: size, height: size)
                .scaleEffect(hovering ? 1.08 : 1)
            if item.windows > 0 {
                Circle().fill(.white.opacity(item.active ? 0.95 : 0.6)).frame(width: 4, height: 4).offset(y: size * 0.12)
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
                             right: { Menus.app(item, in: dock) },
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
                app.previews.hover(on ? item : nil, in: dock, id: item.id)
                app.tooltips.show(on ? Apps.name(item.id) : nil, over: item.id, in: dock)
                if on && app.config.bool("recentFiles") { Apps.prefetchRecent(item.id) }
            },
            drag: { delta, ended in drag(delta, ended: ended) },
            files: config.bool("dropToOpen") ? { urls in app.docks.launch(item.id, files: urls) } : nil,
            fileOver: { fileOver = $0 },
            note: Sites.isWeb(item.id) ? nil : { id in app.paper.use(id, in: item.id) },
            press: { pressed = $0 }))
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

/// "+": add apps or folders to this Desktop's mode. A plus in the mode's color on a clear glass tile. The layer strip
/// leaves its slot empty and the dock puts this over it (see `DockView.stage`), so it's real glass either way.
struct AddSlot: View {
    @Environment(PetalApp.self) private var app
    let dock: ScreenDock
    let icon: CGFloat
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        let color = Color(nsColor: dock.mode?.color ?? PetalApp.shared.accent)
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
                                   app.tooltips.show(on ? (dock.mode.map { "Add apps to \($0.name)" } ?? "Add apps") : nil, over: "add", in: dock)
                               }, press: { pressed = $0 }))
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
        .overlay(alignment: .bottom) {
            if playing.playing { Equalizer(icon: icon).offset(y: icon * 0.22) }
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
                let wanted: [NSPasteboard.PasteboardType] = (handlers?.files != nil ? [.fileURL] : []) + (handlers?.note != nil ? [.petalNote] : [])
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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let leftObserver { NotificationCenter.default.removeObserver(leftObserver) }
            leftObserver = nil
            guard let window else { return }
            // The dock stops taking the mouse as the pointer leaves it, sometimes before macOS says the pointer left
            // this slot: a slot would stay hovered (a mode button kept its highlight). The dock says so instead.
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
                // Any click on the dock (an app, a website, Finder, the AI button, "+", a mode): an earlier click
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
            handlers?.fileOver(true)
            PetalApp.shared.docks.revealAll()
            return handlers?.dropOperation ?? .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { handlers?.fileOver(false) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            handlers?.fileOver(false)
            if let id = sender.draggingPasteboard.data(forType: .petalNote).map({ String(decoding: $0, as: UTF8.self) }), let note = handlers?.note {
                note(id)
                return true
            }
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
    }

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
