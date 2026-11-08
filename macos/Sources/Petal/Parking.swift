import AppKit
import ApplicationServices

/// A window Parking keeps, as the focus guard is told about it.
struct ManagedWindow {
    let id: CGWindowID
    let pid: pid_t
    let bundleID: String
    let element: AXUIElement
    let desktop: Int
}

/// Per-mode windows (`modeWindows`): each mode keeps its own windows and tabs, as Linux workspaces do, while one
/// Desktop holds every mode. A window belongs to the mode that was in front on its Desktop when it first showed up,
/// or the mode it was moved to. Switching mode parks the other modes' windows just off-screen at the bottom-right
/// corner of their screen, one point still showing, as AeroSpace does, and puts this mode's back where they were.
/// Nothing is minimized and nothing changes Desktop, so the switch is instant.
///
/// A parked window must never be lost. Before a window moves, its frame is written to parked.json; quitting, being
/// killed, turning the setting off, and `petal restore-windows` put every window back; the next launch after a crash
/// does too (the Dock guard can't, as a launch agent has no Accessibility). A window found a point from a corner that
/// Petal isn't keeping is brought back as well.
@MainActor
enum Parking {
    struct Owner: Codable, Equatable {
        var mode: String
        var desktop: Int
        var pid: Int32
    }

    struct Record: Codable, Equatable {
        let id: UInt32
        let pid: Int32
        let app: String
        var mode: String
        let desktop: Int
        /// Where it goes back to, top-left origin.
        let frame: CGRect
        /// Where it waits.
        var spot: CGPoint
    }

    private struct Saved: Codable {
        var parked: [Record]
        var owners: [String: Owner]
    }

    static let file = Config.supportFolder.appending(path: "parked.json")

    /// A window of a mode not in front was brought forward (⌘-Tab, a click on its sliver, its app showing it). The
    /// focus guard sets this; until it does, the Desktop switches to the window's mode. The same news is posted as
    /// `parkedWindowFocusedNotification`, with "window" (a ManagedWindow) and "mode" in its userInfo.
    static var parkedWindowFocused: ((ManagedWindow, String) -> Void)?
    static let parkedWindowFocusedNotification = Notification.Name("PetalParkedWindowFocused")

    private(set) static var owners: [CGWindowID: Owner] = [:]
    private(set) static var parked: [CGWindowID: Record] = [:]
    private(set) static var active = false
    private static var started = false
    private static var dirty = false
    private static var timer: Timer?
    private static var reconcileWork: DispatchWorkItem?
    private static var focusWork: DispatchWorkItem?
    /// Petal's own focus changes (a mode switch, a moved tab) aren't someone bringing a window forward.
    private static var quietUntil = Date.distantPast
    /// The window brought forward and reported, left showing until focus leaves it or the guard decides.
    private static var exempt: CGWindowID?
    private static var lastFocused: [String: CGWindowID] = [:]
    /// The next window an app opens goes to this mode (a tab moved to a mode with no window of that browser yet).
    private static var incoming: [pid_t: (mode: String, desktop: Int, until: Date)] = [:]
    private static var created: [pid_t: Date] = [:]
    private static var standard: [CGWindowID: Bool] = [:]
    private static var lastRetry = Date.distantPast
    /// When a window last closed or minimized, or an app hid or quit: macOS then hands focus to another window on its
    /// own, which may be a parked one, and that isn't someone bringing it forward.
    private static var lastLeft = Date.distantPast

    private static var config: Config { PetalApp.shared.config }

    // MARK: Starting and stopping

    /// At launch: windows a crash left parked come back first; then the setting is followed.
    static func start() {
        guard !started else { return }
        started = true
        load()
        if !parked.isEmpty {
            bringBack(Array(parked.values))
            rescueStranded()
        }
        PetalApp.shared.ipc.on("restoreWindows") { _ in
            let count = restoreEverything()
            return count == 0 ? "No windows were waiting off-screen." : "Brought back \(count) window\(count == 1 ? "" : "s")."
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        tick()
    }

    /// Quitting or being killed: every window back where it was. Which mode each belongs to is kept for next time.
    static func stop() {
        timer?.invalidate()
        bringBack(Array(parked.values))
        save()
    }

    private static var wanted: Bool {
        let app = PetalApp.shared
        return config.bool("modeWindows") && config.bool("modes") && app.docks.shown && Windows.trusted && Windows.canManage
    }

    private static func tick() {
        if wanted != active { wanted ? enable() : disable() }
        if active {
            reconcile()
        } else if !parked.isEmpty, Date().timeIntervalSince(lastRetry) > 5 {
            // Windows from a crash on a Desktop not showing yet: Accessibility reaches them once it shows.
            lastRetry = Date()
            bringBack(Array(parked.values))
        }
    }

    private static func enable() {
        active = true
        WindowEvents.shared.listen("parking") { event in handle(event) }
        reconcile()
    }

    /// Turned off: every window comes back and stays.
    private static func disable() {
        active = false
        WindowEvents.shared.stopListening("parking")
        bringBack(Array(parked.values))
        owners = owners.filter { parked[$0.key] != nil }   // only windows not reached yet keep theirs
        lastFocused = [:]
        exempt = nil
        dirty = true
        save()
    }

    // MARK: Switching mode

    /// The mode of `desktop` changed (App.swift's apply): park the other modes' windows, bring this one's back, and
    /// give focus to this mode's window used last.
    static func modeChanged(desktop: Int) {
        guard active else { return }
        quietUntil = Date().addingTimeInterval(0.6)
        exempt = nil
        reconcile()
        if let focused = Windows.focused(), let owner = owners[focused.id], owner.desktop == desktop,
           owner.mode == front(desktop), parked[focused.id] == nil { return }
        focusFront(desktop)
    }

    // MARK: Keeping every Desktop in order

    private static func scheduleReconcile(after delay: Double = 0.05) {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { reconcile() }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func front(_ desktop: Int) -> String { config.mode(forDesktop: desktop)?.id ?? "" }

    /// Every window on a Desktop showing gets a mode; those of other modes wait off-screen, those of the mode in
    /// front are back in place. A window the size of a sliver at a corner that Petal isn't keeping is brought back.
    static func reconcile() {
        guard active else { return }
        let screens = Windows.screens()
        let list = Windows.onScreen()
        let onScreen = Set(list.map(\.id))
        let modeIDs = Set(config.modes.map(\.id))
        let showing = Set(screens.compactMap(\.desktop))

        for window in list where parked[window.id] == nil {
            guard isStandard(window) else { continue }
            guard let screen = screen(for: window.frame, in: screens) else {
                if ParkingLayout.looksParked(window.frame, screens: screens.map(\.frame)) { rescue(window, screens: screens) }
                continue
            }
            guard let desktop = screen.desktop else { continue }   // a full-screen app's Space
            if let owner = owners[window.id], owner.desktop == desktop, modeIDs.contains(owner.mode) { continue }
            var mode = front(desktop)
            if let next = incoming[window.pid], next.until > Date(), next.desktop == desktop {
                mode = next.mode
                incoming[window.pid] = nil
            }
            // A window dragged here from another Desktop or screen joins this one's mode in front.
            owners[window.id] = Owner(mode: mode, desktop: desktop, pid: window.pid)
            dirty = true
        }

        let focused = Windows.focused()?.id
        // Parked windows that closed, or that their app or macOS moved from their spot.
        for (id, record) in parked where showing.contains(record.desktop) {
            if !modeIDs.contains(record.mode) { parked[id]?.mode = front(record.desktop) }
            if owners[id]?.mode != parked[id]?.mode {
                owners[id] = Owner(mode: parked[id]?.mode ?? record.mode, desktop: record.desktop, pid: record.pid)
                dirty = true
            }
            guard onScreen.contains(id) else {
                if Windows.element(id, pid: record.pid).flatMap(Windows.frame(of:)) == nil { parked[id] = nil; owners[id] = nil; dirty = true }
                continue
            }
            if let now = list.first(where: { $0.id == id }), abs(now.frame.minX - record.spot.x) > 3 || abs(now.frame.minY - record.spot.y) > 3,
               id != focused, let element = Windows.element(id, pid: record.pid),
               let screen = screens.first(where: { $0.desktop == record.desktop }) {
                let spot = ParkingLayout.parkedOrigin(size: now.frame.size, screen: screen.frame, others: screens.map(\.frame).filter { $0 != screen.frame })
                let actual = Windows.place(element, pid: record.pid, CGRect(origin: spot, size: now.frame.size), size: false)
                parked[id]?.spot = actual?.origin ?? spot   // where macOS let it go, so it isn't moved again every second
                dirty = true
            }
        }

        if exempt != nil && exempt != focused { exempt = nil }
        for screen in screens {
            guard let desktop = screen.desktop else { continue }
            let mode = front(desktop)
            let here = owners.filter { $0.value.desktop == desktop && onScreen.contains($0.key) }.mapValues(\.mode)
            let plan = ParkingLayout.plan(mode: mode, owners: here, parked: Set(parked.keys))
            // The other modes' windows go first, then this mode's come back.
            let leaving = plan.park.filter { $0 != exempt }.compactMap { id in list.first { $0.id == id } }
            park(leaving, owners: here, desktop: desktop, screen: screen.frame, others: screens.map(\.frame))
            bringBack(plan.restore.compactMap { parked[$0] })
            if let focused, leaving.contains(where: { $0.id == focused }) { focusFront(desktop) }
        }
        if dirty { save() }
    }

    private static func screen(for frame: CGRect, in screens: [(screen: NSScreen, frame: CGRect, visible: CGRect, desktop: Int?)])
        -> (screen: NSScreen, frame: CGRect, visible: CGRect, desktop: Int?)? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return screens.first { $0.frame.contains(center) }
    }

    private static func isStandard(_ window: ScreenWindow) -> Bool {
        if let known = standard[window.id] { return known }
        guard let element = Windows.element(window.id, pid: window.pid) else { return false }
        let answer = Windows.isStandard(element) && !Windows.isFullScreen(element)
        standard[window.id] = answer
        return answer
    }

    /// Parks windows at their screen's corner. Each is written down before any of them moves: a crash a moment
    /// later still knows where they go back to.
    private static func park(_ windows: [ScreenWindow], owners modes: [CGWindowID: String], desktop: Int, screen: CGRect, others: [CGRect]) {
        var moves: [(ScreenWindow, AXUIElement, CGRect)] = []
        for window in windows {
            guard let element = Windows.element(window.id, pid: window.pid), let mode = modes[window.id] else { continue }
            let frame = Windows.frame(of: element) ?? window.frame
            let spot = ParkingLayout.parkedOrigin(size: frame.size, screen: screen, others: others.filter { $0 != screen })
            parked[window.id] = Record(id: window.id, pid: window.pid, app: window.bundleID, mode: mode, desktop: desktop, frame: frame, spot: spot)
            moves.append((window, element, CGRect(origin: spot, size: frame.size)))
        }
        guard !moves.isEmpty else { return }
        dirty = true
        save()
        for (window, element, target) in moves {
            if let actual = Windows.place(element, pid: window.pid, target, size: false), actual.origin != target.origin {
                parked[window.id]?.spot = actual.origin   // where macOS let it go
                dirty = true
            }
        }
    }

    /// Puts windows back at their saved frames (inside their screen, and clear of the dock's strip when
    /// keepWindowsClear is on). One Accessibility can't reach yet stays on the list, for the next try.
    @discardableResult
    private static func bringBack(_ records: [Record]) -> Int {
        guard !records.isEmpty, Windows.trusted else { return 0 }
        let screens = Windows.screens()
        var count = 0
        for record in records {
            guard NSRunningApplication(processIdentifier: record.pid) != nil else {
                parked[record.id] = nil   // its app quit: the window went with it
                dirty = true
                continue
            }
            guard let element = Windows.element(record.id, pid: record.pid) else { continue }
            let home = screens.max { overlap(record.frame, $0.frame) < overlap(record.frame, $1.frame) }
            var target = record.frame
            if let home, overlap(record.frame, home.frame) > 0 {
                target = ScreenArea.fit(record.frame, in: Windows.usableArea(frame: home.frame, visible: home.visible, respectClear: true))
            } else if let main = screens.first {
                target = ParkingLayout.rescued(record.frame, in: Windows.usableArea(frame: main.frame, visible: main.visible, respectClear: true))
            }
            Windows.place(element, pid: record.pid, target)
            parked[record.id] = nil
            dirty = true
            count += 1
        }
        save()
        return count
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let cut = a.intersection(b)
        return cut.isNull ? 0 : cut.width * cut.height
    }

    /// A window a corner's sliver from gone that Petal isn't keeping: back to the middle of its screen.
    private static func rescue(_ window: ScreenWindow, screens: [(screen: NSScreen, frame: CGRect, visible: CGRect, desktop: Int?)]) {
        guard parked[window.id] == nil, let element = Windows.element(window.id, pid: window.pid), Windows.isStandard(element),
              let home = screens.max(by: { overlap(window.frame, $0.frame) < overlap(window.frame, $1.frame) }) else { return }
        Windows.place(element, pid: window.pid,
                      ParkingLayout.rescued(window.frame, in: Windows.usableArea(frame: home.frame, visible: home.visible, respectClear: true)))
    }

    @discardableResult
    private static func rescueStranded() -> Int {
        guard Windows.trusted else { return 0 }
        let screens = Windows.screens()
        let stranded = Windows.onScreen().filter {
            parked[$0.id] == nil && ParkingLayout.looksParked($0.frame, screens: screens.map(\.frame))
        }
        for window in stranded { rescue(window, screens: screens) }
        return stranded.count
    }

    /// This mode's window used last on `desktop`, else its front-most one, gets focus.
    private static func focusFront(_ desktop: Int) {
        let mode = front(desktop)
        let list = Windows.onScreen()
        func ours(_ id: CGWindowID) -> Bool { owners[id]?.mode == mode && owners[id]?.desktop == desktop && parked[id] == nil }
        let pick = lastFocused["\(desktop)|\(mode)"].flatMap { id in list.first { $0.id == id && ours(id) } } ?? list.first { ours($0.id) }
        guard let pick, let element = Windows.element(pick.id, pid: pick.pid) else { return }
        quietUntil = Date().addingTimeInterval(0.6)
        Windows.raise(element, pid: pick.pid)
    }

    // MARK: Events

    private static func handle(_ event: WindowEvents.Event) {
        switch event.kind {
        case .created:
            created[event.pid] = Date()
            scheduleReconcile()
        case .closed:
            lastLeft = Date()
            guard let id = event.window else { return }
            standard[id] = nil
            if owners.removeValue(forKey: id) != nil || parked.removeValue(forKey: id) != nil { dirty = true; save() }
        case .quit:
            lastLeft = Date()
            let before = owners.count + parked.count
            owners = owners.filter { $0.value.pid != event.pid }
            parked = parked.filter { $0.value.pid != event.pid }
            incoming[event.pid] = nil
            if owners.count + parked.count != before { dirty = true; save() }
        case .focused, .activated:
            scheduleFocusCheck(after: 0.15)
        case .minimized, .hidden:
            lastLeft = Date()
        case .space, .screens, .unminimized, .shown:
            scheduleReconcile(after: 0.15)
        default:
            break
        }
    }

    private static func scheduleFocusCheck(after delay: Double) {
        focusWork?.cancel()
        let work = DispatchWorkItem { checkFocus(retry: true) }
        focusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Someone brought forward a window of a mode not in front: tell the guard, or switch to its mode.
    private static func checkFocus(retry: Bool) {
        guard active, Date() > quietUntil, let focused = Windows.focused() else { return }
        if let next = incoming[focused.pid], next.until > Date() { return }
        let mode: String, desktop: Int
        if let record = parked[focused.id] {
            (mode, desktop) = (record.mode, record.desktop)
        } else if let owner = owners[focused.id], owner.mode != front(owner.desktop) {
            (mode, desktop) = (owner.mode, owner.desktop)
        } else {
            if let owner = owners[focused.id] { lastFocused["\(owner.desktop)|\(owner.mode)"] = focused.id }
            if exempt != focused.id { exempt = nil }
            return
        }
        guard exempt != focused.id else { return }
        if Date().timeIntervalSince(lastLeft) < 0.8 {
            // macOS's choice after a window closed or an app hid or quit: focus stays in the mode in front.
            if Windows.screens().contains(where: { $0.desktop == desktop }) { focusFront(desktop) }
            return
        }
        // ⌘-Tab to a window on another Desktop switches Desktop first; ask again once it shows.
        guard Windows.screens().contains(where: { $0.desktop == desktop }) else {
            if retry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { checkFocus(retry: false) }
            }
            return
        }
        exempt = focused.id
        lastFocused["\(desktop)|\(mode)"] = focused.id
        let bundleID = NSRunningApplication(processIdentifier: focused.pid)?.bundleIdentifier ?? ""
        let window = ManagedWindow(id: focused.id, pid: focused.pid, bundleID: bundleID, element: focused.element, desktop: desktop)
        NotificationCenter.default.post(name: parkedWindowFocusedNotification, object: nil, userInfo: ["window": window, "mode": mode])
        if let hook = parkedWindowFocused {
            hook(window, mode)
        } else {
            PetalApp.shared.setModeNow(mode, desktop: desktop)
        }
    }

    // MARK: Moving windows and tabs between modes

    /// Moves a window to `mode`: it waits off-screen unless that mode is in front. Returns false while per-mode
    /// windows are off.
    @discardableResult
    static func moveWindow(_ element: AXUIElement, to mode: String) -> Bool {
        guard active, config.modes.contains(where: { $0.id == mode }), let id = Windows.id(of: element) else { return false }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        Windows.remember(element, as: id)
        let screens = Windows.screens()
        let desktop = owners[id]?.desktop ?? parked[id]?.desktop
            ?? Windows.frame(of: element).flatMap { screen(for: $0, in: screens)?.desktop }
        guard let desktop else { return false }
        owners[id] = Owner(mode: mode, desktop: desktop, pid: pid)
        parked[id]?.mode = mode
        if exempt == id { exempt = nil }
        dirty = true
        let wasFocused = Windows.focused()?.id == id
        reconcile()
        if wasFocused && mode != front(desktop) { focusFront(desktop) }
        return true
    }

    @discardableResult
    static func moveWindow(_ window: AppWindow, to mode: String) -> Bool { moveWindow(window.element, to: mode) }

    /// The window in front, to `mode`.
    @discardableResult
    static func moveFrontWindow(to mode: String) -> Bool {
        guard let focused = Windows.focused() else { return false }
        return moveWindow(focused.element, to: mode)
    }

    /// Browsers Petal can move tabs in, through AppleScript.
    static let chromium: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
                                        "net.imput.helium", "company.thebrowser.Browser", "com.brave.Browser", "com.brave.Browser.beta",
                                        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "org.chromium.Chromium",
                                        "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]
    static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    /// Moves a browser tab to `mode`: it closes here and opens in that mode's window of the same browser, which is
    /// made if the mode has none. A window with only that tab moves whole. `done` gets whether it worked.
    static func moveTab(url: String, from window: AXUIElement, to mode: String, done: ((Bool) -> Void)? = nil) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard active, config.modes.contains(where: { $0.id == mode }), let sourceID = Windows.id(of: window),
              let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              chromium.contains(bundleID) || safari.contains(bundleID),
              bundleID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { done?(false); return }
        let screens = Windows.screens()
        let list = Windows.onScreen()
        guard let sourceFrame = list.first(where: { $0.id == sourceID })?.frame ?? Windows.frame(of: window),
              let desktop = owners[sourceID]?.desktop ?? screen(for: sourceFrame, in: screens)?.desktop else { done?(false); return }
        if owners[sourceID]?.mode == mode { done?(true); return }

        // That mode's window of this browser on this Desktop: the one used last, else any.
        let candidates = owners.filter { $0.value.mode == mode && $0.value.pid == pid && $0.value.desktop == desktop }.map(\.key)
        let targetID = lastFocused["\(desktop)|\(mode)"].flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.sorted().first
        let targetFrame = targetID.flatMap { id in list.first { $0.id == id }?.frame }
        let title: String = Windows.value(window, kAXTitleAttribute) ?? ""

        incoming[pid] = (mode, desktop, Date().addingTimeInterval(5))
        quietUntil = Date().addingTimeInterval(1.5)
        let script = safari.contains(bundleID) ? safariScript(bundleID) : chromiumScript(bundleID)
        func number(_ value: CGFloat?) -> String { value.map { String(Int($0.rounded())) } ?? "0" }
        let arguments = [url, number(sourceFrame.minX), number(sourceFrame.minY), title,
                         targetFrame == nil ? "0" : "1", number(targetFrame?.minX), number(targetFrame?.minY)]
        Task { @MainActor in
            let output = await Task.detached { runScript(script, arguments) }.value
            switch output {
            case "single":
                incoming[pid] = nil
                done?(moveWindow(window, to: mode))
            case "moved", "new":
                if output == "moved" { incoming[pid] = nil }
                // Focus stays in the mode in front: the source window if it's still open, else its mode's last one.
                quietUntil = Date().addingTimeInterval(0.8)
                scheduleReconcile(after: 0.3)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if Windows.frame(of: window) != nil, parked[sourceID] == nil { Windows.raise(window, pid: pid) } else { focusFront(desktop) }
                }
                done?(true)
            default:
                incoming[pid] = nil
                done?(false)
            }
        }
    }

    @discardableResult
    static func moveTab(url: String, from window: AppWindow, to mode: String, done: ((Bool) -> Void)? = nil) -> Bool {
        moveTab(url: url, from: window.element, to: mode, done: done)
        return active
    }

    /// Arguments: the tab's URL, the source window's top-left and title, whether there's a target window, its
    /// top-left. Windows are found by where they are (AppleScript's bounds count from the top-left, as Accessibility
    /// does), the source failing that by its title.
    private static let findWindows = """
        on near(a, b)
            return (a - b) < 4 and (b - a) < 4
        end near
        """

    private static func chromiumScript(_ bundleID: String) -> String {
        """
        \(findWindows)
        on run argv
            set theURL to item 1 of argv
            set sx to (item 2 of argv) as number
            set sy to (item 3 of argv) as number
            set st to item 4 of argv
            set hasTarget to (item 5 of argv) is "1"
            set tx to (item 6 of argv) as number
            set ty to (item 7 of argv) as number
            tell application id "\(bundleID)"
                set src to missing value
                set tgt to missing value
                repeat with w in windows
                    try
                        set b to bounds of w
                        if src is missing value and my near(item 1 of b, sx) and my near(item 2 of b, sy) then set src to contents of w
                        if hasTarget and tgt is missing value and my near(item 1 of b, tx) and my near(item 2 of b, ty) then set tgt to contents of w
                    end try
                end repeat
                if src is missing value then
                    repeat with w in windows
                        try
                            if name of w is st then set src to contents of w
                        end try
                    end repeat
                end if
                if src is missing value then return "nosource"
                set theTab to missing value
                repeat with t in tabs of src
                    if URL of t is theURL then set theTab to contents of t
                end repeat
                if theTab is missing value then set theTab to active tab of src
                set openURL to URL of theTab
                if (count of tabs of src) is 1 and tgt is missing value then return "single"
                if tgt is missing value then
                    set tgt to make new window
                    set URL of active tab of tgt to openURL
                    close theTab
                    return "new"
                end if
                tell tgt to make new tab with properties {URL:openURL}
                close theTab
                return "moved"
            end tell
        end run
        """
    }

    private static func safariScript(_ bundleID: String) -> String {
        """
        \(findWindows)
        on run argv
            set theURL to item 1 of argv
            set sx to (item 2 of argv) as number
            set sy to (item 3 of argv) as number
            set st to item 4 of argv
            set hasTarget to (item 5 of argv) is "1"
            set tx to (item 6 of argv) as number
            set ty to (item 7 of argv) as number
            tell application id "\(bundleID)"
                set src to missing value
                set tgt to missing value
                repeat with w in windows
                    try
                        set b to bounds of w
                        if src is missing value and my near(item 1 of b, sx) and my near(item 2 of b, sy) then set src to contents of w
                        if hasTarget and tgt is missing value and my near(item 1 of b, tx) and my near(item 2 of b, ty) then set tgt to contents of w
                    end try
                end repeat
                if src is missing value then
                    repeat with w in windows
                        try
                            if name of w is st then set src to contents of w
                        end try
                    end repeat
                end if
                if src is missing value then return "nosource"
                set theTab to missing value
                repeat with t in tabs of src
                    if URL of t is theURL then set theTab to contents of t
                end repeat
                if theTab is missing value then set theTab to current tab of src
                set openURL to URL of theTab
                if (count of tabs of src) is 1 and tgt is missing value then return "single"
                if tgt is missing value then
                    make new document with properties {URL:openURL}
                    close theTab
                    return "new"
                end if
                make new tab at end of tabs of tgt with properties {URL:openURL}
                close theTab
                return "moved"
            end tell
        end run
        """
    }

    /// Runs an AppleScript with osascript, so a first-time "Petal wants to control…" prompt never holds up the dock.
    nonisolated private static func runScript(_ script: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The dock opening an app

    /// The dock's click on a running app, while each mode keeps its own windows: this mode's windows of it (cycling
    /// on repeated clicks), and when it has only other modes' windows here, a new window for this mode. Returns false
    /// when the dock's usual way fits (no windows here, or per-mode windows off).
    static func activate(_ bundleID: String) -> Bool {
        guard active, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        let pid = app.processIdentifier
        let screens = Windows.screens()
        let showing = Set(screens.compactMap(\.desktop))
        var mine: [ScreenWindow] = [], others: [ScreenWindow] = []
        for window in Windows.onScreen() where window.pid == pid {
            guard let owner = owners[window.id], showing.contains(owner.desktop) else { continue }
            if parked[window.id] != nil || owner.mode != front(owner.desktop) { others.append(window) } else { mine.append(window) }
        }
        if !mine.isEmpty {
            var pick = mine[0]
            if app.isActive, let focused = Windows.focused()?.id, let index = mine.firstIndex(where: { $0.id == focused }) {
                pick = mine[(index + 1) % mine.count]
            }
            guard let element = Windows.element(pick.id, pid: pid) else { return false }
            Windows.raise(element, pid: pid)
            return true
        }
        guard let other = others.first, let desktop = owners[other.id]?.desktop else { return false }
        // This mode's minimized window of it, if it has one.
        if let window = Windows.windows(of: pid).first(where: { w in
            w.minimized && Windows.id(of: w.element).flatMap { owners[$0] }.map { $0.mode == front($0.desktop) } == true
        }) {
            Windows.focus(window)
            return true
        }
        // The app comes forward on its parked window, then gets ⌘N; that window isn't someone bringing it forward.
        let asked = Date()
        incoming[pid] = (front(desktop), desktop, asked.addingTimeInterval(2))
        PetalApp.shared.docks.newWindow(bundleID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if let made = created[pid], made > asked { return }
            // An app with no New Window (one-window apps): its window comes to this mode instead.
            incoming[pid] = nil
            if let element = Windows.element(other.id, pid: pid), moveWindow(element, to: front(desktop)) {
                Windows.raise(element, pid: pid)
            }
        }
        return true
    }

    // MARK: Bringing everything back

    /// `petal restore-windows`: every window Petal moved aside comes back, and any found stranded at a corner. In a
    /// running Petal the windows brought back join the mode in front of their Desktop, so they stay. Returns how many.
    @discardableResult
    static func restoreEverything() -> Int {
        if !started { load() }
        let records = Array(parked.values)
        let count = bringBack(records) + rescueStranded()
        for record in records where parked[record.id] == nil {
            if active { owners[record.id]?.mode = front(record.desktop) } else { owners[record.id] = nil }
        }
        exempt = nil
        dirty = true
        save()
        return count
    }

    /// How many windows parked.json says are off-screen (for `petal doctor`).
    static func waiting() -> Int {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return 0 }
        return saved.parked.count
    }

    // MARK: The file

    private static func load() {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        let alive = { (pid: Int32) in NSRunningApplication(processIdentifier: pid) != nil }
        parked = Dictionary(saved.parked.filter { alive($0.pid) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        owners = Dictionary(saved.owners.compactMap { key, owner in UInt32(key).flatMap { alive(owner.pid) ? ($0, owner) : nil } },
                            uniquingKeysWith: { a, _ in a })
    }

    private static func save() {
        guard dirty else { return }
        dirty = false
        if parked.isEmpty && owners.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let saved = Saved(parked: parked.values.sorted { $0.id < $1.id },
                          owners: Dictionary(uniqueKeysWithValues: owners.map { (String($0.key), $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(saved) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
