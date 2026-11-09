import AppKit

/// Whether Mission Control (or App Exposé) is open, for everything that steps aside for it: Petal's dock and Petal
/// Notes. Owned by neither: it listens to the windows' events (macOS's Dock says when it opens and closes) while
/// anyone needs it (`need`), whichever dock is chosen, and while it's open checks that macOS's Dock still has a
/// window up, ending it should the closing never be said (the Dock restarted, or a macOS that doesn't send it).
@MainActor
final class MissionControlWatch {
    static let shared = MissionControlWatch()

    private(set) var open = false
    private var users = NoteShelf.TrackerUsers()
    private var subscribers: [String: @MainActor (Bool) -> Void] = [:]
    private var check: Timer?
    nonisolated private static let queue = DispatchQueue(label: "petal.missioncontrol", qos: .utility)

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
        guard users.listening != wasListening else { return }
        if users.listening {
            WindowEvents.shared.listen("missioncontrol") { [weak self] event in
                switch event.kind {
                case .missionControl: self?.set(true)
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
        if on {
            check = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Self.queue.async {
                    let up = Self.systemDockOnScreen()
                    DispatchQueue.main.async { MainActor.assumeIsolated { if !up { self?.set(false) } } }
                }
            }
            check?.tolerance = 0.3
        }
        for handler in subscribers.values { handler(on) }
    }

    /// Whether macOS's Dock has a window on the screen: it does while Mission Control is open. Asks the window
    /// server: off the main thread.
    nonisolated private static func systemDockOnScreen() -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { $0[kCGWindowOwnerPID as String] as? pid_t == dock.processIdentifier }
    }
}
