import Foundation

/// What counts as macOS's Dock hidden by Petal, kept apart from SystemDock so checks/run.sh can try it without
/// touching the Dock. Petal hides the Dock with auto-hide and a 1000-second wait; nobody waits that long on purpose,
/// so a wait that long is Petal's, never the person's own setting.
enum SystemDockRules {
    /// A wait at least this long (seconds) is Petal's hiding.
    static let hiddenDelay = 100.0

    static func isHidden(delay: Any?) -> Bool {
        guard let delay = delay as? Double else { return false }
        return delay >= hiddenDelay
    }

    /// The person's own settings, from what was saved. Settings saved while the Dock was already hidden (Petal's
    /// file lost while it was the dock, then saved again) are Petal's, not theirs: putting those back would leave
    /// the Dock hidden for good. So a saved wait that long goes back to macOS's default (no wait, no auto-hide), and
    /// the no-bouncing saved with it, which Petal set too.
    static func own(_ saved: [String: Any]) -> [String: Any] {
        guard isHidden(delay: saved["autohide-delay"]) else { return saved }
        var own = saved
        own["autohide-delay"] = NSNull()
        own["autohide"] = false
        if own["no-bouncing"] as? Bool == true { own["no-bouncing"] = NSNull() }
        return own
    }

    /// With nothing saved, what clears Petal's hiding still on the Dock (nil when it isn't hidden): the wait goes and
    /// auto-hide goes off. Other settings, which may be the person's own, are left alone.
    static func leftover(delay: Any?) -> [String: Any]? {
        isHidden(delay: delay) ? ["autohide": false, "autohide-delay": NSNull()] : nil
    }
}
