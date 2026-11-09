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
    /// When it was last said open: the safety net never keeps it open longer than a minute past that.
    private var lastOpened = Date.distantPast
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
        if on {
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

    /// macOS's Dock's windows (their names, and whether they're on the screen): its bar is "Dock"; Mission Control's
    /// own are the others. Asks the window server: off the main thread.
    nonisolated private static func dockWindows() -> [(name: String, onScreen: Bool)] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return windows.filter { $0[kCGWindowOwnerPID as String] as? pid_t == dock.processIdentifier }
            .map { ($0[kCGWindowName as String] as? String ?? "", true) }
    }
}
