import Foundation

/// Whether a routine's run should stop: set on the main thread (the chat or AI session that ran it hung up, the
/// routine changed, went or was turned off), read by its moves off it (Routines.apply), so nothing moves once it's
/// set. Pure, so `macos/checks/run.sh` checks it.
final class RoutineStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    init() {}

    func stop() { lock.withLock { stopped = true } }
    var isStopped: Bool { lock.withLock { stopped } }

    /// Does `body` for each item in order, asking `stop` right before each: what was done (nil results are skipped:
    /// nothing moved), and whether it stopped before the end.
    static func each<Item, Done>(_ items: [Item], stop: RoutineStop, _ body: (Item) -> Done?) -> (done: [Done], stopped: Bool) {
        var done: [Done] = []
        for item in items {
            if stop.isStopped { return (done, true) }
            if let result = body(item) { done.append(result) }
        }
        return (done, false)
    }
}
