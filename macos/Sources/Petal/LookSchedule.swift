import Foundation

/// When the dock looks at the windows again (DockController): times in, decisions out, so `macos/checks` can run it.
///
/// - A window opening, closing or minimizing: a look now, and one more shortly after, since apps animate a new
///   window in and the window server may list it a moment late.
/// - Looks are at least `gap` apart, so a burst (a browser restoring its windows) becomes one look now, one when
///   the gap is over, and the one after.
/// - A window moving or resizing: one look once it stops, not one per step of a drag.
/// - The timer: a look unless one is under way. With Accessibility's events it's a safety net every few seconds;
///   without them it's the only way to see windows change, so it stays once a second.
struct LookSchedule {
    enum Cause {
        case now        // apps launching or quitting, another Desktop, a setting: look now
        case window     // a window opened, closed, minimized or came back
        case movement   // a window moved or resized
        case poll       // the timer
    }

    static let followUp = 0.5       // the second look after a window event
    static let settle = 0.3         // the look after a window stops moving
    static let gap = 0.1            // looks start at least this far apart
    static let safetyNet = 5.0      // the timer, with Accessibility's events
    static let poll = 1.0           // the timer, without them

    private(set) var looking = false
    private var again = false
    private var lastStart = -Double.infinity
    private var trailing: Double?   // after window events and moves; each pushes it later
    private var queued: Double?     // what came in during a look or too soon after one

    /// When the next timed look is due (the caller keeps one timer for it).
    var due: Double? { [trailing, queued].compactMap { $0 }.min() }

    /// Something happened at `now`. True: start a look now.
    mutating func note(_ cause: Cause, at now: Double) -> Bool {
        switch cause {
        case .now:
            return begin(at: now, queue: true)
        case .window:
            trailing = max(trailing ?? 0, now + Self.followUp)
            return begin(at: now, queue: true)
        case .movement:
            trailing = max(trailing ?? 0, now + Self.settle)
            return false
        case .poll:
            return begin(at: now, queue: false)
        }
    }

    /// The caller's timer fired at `now`. True: start a look now.
    mutating func fire(at now: Double) -> Bool {
        var hit = false
        if let trailing, now >= trailing - Self.slack { self.trailing = nil; hit = true }
        if let queued, now >= queued - Self.slack { self.queued = nil; hit = true }
        return hit && begin(at: now, queue: true)
    }

    /// A look finished at `now`. True: start another now, for what happened while it ran.
    mutating func finished(at now: Double) -> Bool {
        looking = false
        guard again else { return false }
        again = false
        return begin(at: now, queue: true)
    }

    /// How often the timer looks.
    static func interval(events: Bool, launching: Bool) -> Double { events && !launching ? safetyNet : poll }

    private static let slack = 0.001

    private mutating func begin(at now: Double, queue: Bool) -> Bool {
        if looking {
            if queue { again = true }
            return false
        }
        if now < lastStart + Self.gap - Self.slack {
            if queue { queued = min(queued ?? .infinity, lastStart + Self.gap) }
            return false
        }
        looking = true
        lastStart = now
        queued = nil
        return true
    }
}
