import AppKit

/// Whether Mission Control (or App Exposé) is open, for everything that steps aside for it: Petal's dock and Petal
/// Notes. Owned by neither. Two ways of knowing, while anyone needs it (`need`):
/// - **While Petal's dock is shown** it keeps macOS's Dock hidden, so macOS's Dock on the screen is Mission Control
///   bringing it out: its one window is watched (`DockProbe`, a few times a second, off the main thread), and that
///   alone says open and closed. macOS 27 no longer sends the Dock's `AXExpose…` notifications, so this is what works
///   there.
/// - **With macOS's Dock chosen** its window is always on the screen and says nothing: the windows' events (the
///   Dock's `AXExpose…`, on a macOS that sends them) say open and closed, with a check while it's open that the Dock
///   still has a window up, ending it should the closing never be said.
@MainActor
final class MissionControlWatch {
    static let shared = MissionControlWatch()

    private(set) var open = false
    private var users = NoteShelf.TrackerUsers()
    private var subscribers: [String: @MainActor (Bool) -> Void] = [:]
    private var check: Timer?
    /// When it was last said open: the safety net never keeps it open longer than a minute past that.
    private var lastOpened = Date.distantPast
    nonisolated private static let queue = DispatchQueue(label: "petal.missioncontrol", qos: .utility)
    /// Watching macOS's Dock's window (while Petal's dock is shown): what it last said, and its timer on `queue`.
    private var poll: DispatchSourceTimer?
    private var polling: Bool { poll != nil }

    /// `who` is told every change (and, subscribing while it's open, at once).
    func subscribe(_ who: String, _ handler: @escaping @MainActor (Bool) -> Void) {
        subscribers[who] = handler
        if open { handler(true) }
    }

    /// `who` needs it (the dock while it's shown, the notes while they're on) or no longer does: it listens while
    /// anyone does, and stops (Mission Control taken as closed) when nobody does.
    func need(_ who: String, _ on: Bool) {
        let wasListening = users.listening
        users.need(who, on)
        // Petal's dock shown (it hides macOS's Dock then): macOS's Dock coming out is watched.
        watchDock(users.users.contains("dock"))
        guard users.listening != wasListening else { return }
        if users.listening {
            WindowEvents.shared.listen("missioncontrol") { [weak self] event in
                switch event.kind {
                case .missionControl:
                    self?.lastOpened = Date()
                    self?.set(true)
                case .missionControlEnded: self?.set(false)
                default: break
                }
            }
        } else {
            WindowEvents.shared.stopListening("missioncontrol")
            set(false)
        }
    }

    private func set(_ on: Bool) {
        guard on != open else { return }
        open = on
        check?.invalidate()
        check = nil
        // The safety net is for the events' way of knowing; the Dock's window, while it's watched, says closed itself.
        if on, !polling {
            check = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Petal keeps macOS's Dock hidden while its own dock shows: then the bar coming out is Mission Control.
                    let barHidden = PetalApp.shared.docks?.shown ?? false
                    let since = self.lastOpened
                    Self.queue.async {
                        let windows = Self.dockWindows()
                        let open = NoteShelf.missionControlOpen(dockWindows: windows, barHiddenByPetal: barHidden, lastOpened: since, now: Date())
                        DispatchQueue.main.async { MainActor.assumeIsolated { if !open { self.set(false) } } }
                    }
                }
            }
            check?.tolerance = 0.3
        }
        for handler in subscribers.values { handler(on) }
    }

    /// Starts or stops watching macOS's Dock's window. Its on-screen state is read on `queue` (the window server's,
    /// never the main thread), and only a change is told to the main thread.
    private func watchDock(_ on: Bool) {
        guard on != polling, !(on && Headless.on) else { return }
        if !on {
            poll?.cancel()
            poll = nil
            // Nothing says closed for it any more: taken as closed (the events open it again if it's still up).
            set(false)
            return
        }
        let probe = DockProbe()
        let timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in
            guard let out = probe.changed() else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.dockCame(out: out, from: timer) } }
        }
        poll = timer
        check?.invalidate()
        check = nil
        timer.resume()
    }

    /// macOS's Dock came onto the screen, or left it, while Petal keeps it hidden.
    private func dockCame(out: Bool, from timer: DispatchSourceTimer) {
        guard poll === timer else { return }
        let fullScreen = PetalApp.shared.docks?.inFullScreen ?? false
        guard let open = NoteShelf.missionControl(dockOut: out, fullScreen: fullScreen, open: self.open) else { return }
        if open { lastOpened = Date() }
        set(open)
    }

    /// macOS's Dock's windows (their names, and whether they're on the screen): its bar is "Dock"; Mission Control's
    /// own are the others. Asks the window server: off the main thread.
    nonisolated private static func dockWindows() -> [(name: String, onScreen: Bool)] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return windows.filter { $0[kCGWindowOwnerPID as String] as? pid_t == dock.processIdentifier }
            .map { ($0[kCGWindowName as String] as? String ?? "", true) }
    }
}

/// macOS's Dock's one window, watched for coming onto the screen: only ever used on MissionControlWatch's queue. The
/// Dock's windows are found once in the whole window list (a couple of milliseconds) and then asked about by their
/// ids alone (under a tenth of one); found again when the Dock restarted or they went.
private final class DockProbe: @unchecked Sendable {
    private var pid: pid_t = 0
    private var ids: [CGWindowID] = []
    private var found = Date.distantPast
    private var last = false

    /// Whether the Dock is on the screen, when that changed since it was last asked; nil when it didn't.
    func changed() -> Bool? {
        let now = onScreen()
        guard now != last else { return nil }
        last = now
        return now
    }

    private func onScreen() -> Bool {
        if ids.isEmpty { find() }
        guard !ids.isEmpty else { return false }
        // The window server takes the ids as a plain C array of numbers (a bridged Swift array describes nothing).
        var values: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let wanted = CFArrayCreate(kCFAllocatorDefault, &values, values.count, nil) else { return false }
        let described = CGWindowListCreateDescriptionFromArray(wanted) as? [[String: Any]] ?? []
        // A window gone (the Dock restarted): found again next time, at most once a second.
        if described.count < ids.count { ids = [] }
        return described.contains { $0[kCGWindowOwnerPID as String] as? pid_t == pid && ($0[kCGWindowIsOnscreen as String] as? Bool ?? false) }
    }

    private func find() {
        guard Date().timeIntervalSince(found) > 1 else { return }
        found = Date()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return }
        pid = dock.processIdentifier
        ids = windows.filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid }.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }
}
