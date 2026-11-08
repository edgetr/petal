import Foundation

// Checks RoutineStop.swift: a routine's tidy stops before its next move once its asker hung up (or the routine
// changed), set from another thread, and says it stopped. No file is moved. Run with macos/checks/run.sh.
/// A value read and written from any thread, for the checks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@main
struct RoutineStopCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if !condition { failures += 1; print("FAIL: \(what) \(detail())") }
    }

    static func main() {
        // Not stopped: everything is done, nothing that moved nothing counts.
        let free = RoutineStop()
        let all = RoutineStop.each(Array(1...5), stop: free) { $0 == 3 ? nil : $0 * 10 }
        expect(all.done == [10, 20, 40, 50] && !all.stopped, "every item is done", "\(all)")

        // Stopped before it starts: nothing at all.
        let early = RoutineStop()
        early.stop()
        var touched = 0
        let none = RoutineStop.each(Array(1...5), stop: early) { touched += 1; return $0 }
        expect(none.done.isEmpty && none.stopped && touched == 0, "a stop before the first move moves nothing", "\(touched)")

        // Stopped during a move: that move finishes (and is kept), the next doesn't start.
        let midway = RoutineStop()
        var seen: [Int] = []
        let some = RoutineStop.each(Array(1...5), stop: midway) { item -> Int? in
            seen.append(item)
            if item == 2 { midway.stop() }
            return item
        }
        expect(some.done == [1, 2] && some.stopped && seen == [1, 2], "stops before the next move, keeping what was done", "\(some) \(seen)")

        // Stopped as the last move ends: all done, nothing left to stop.
        let late = RoutineStop()
        let last = RoutineStop.each([1, 2], stop: late) { item -> Int? in if item == 2 { late.stop() }; return item }
        expect(last.done == [1, 2] && !last.stopped, "a stop after the last move cuts nothing", "\(last)")

        // Set from another thread (the main thread, as the asker hangs up) while the moves run on a queue.
        let shared = RoutineStop()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var result: (done: [Int], stopped: Bool) = ([], false)
        DispatchQueue.global().async {
            result = RoutineStop.each(Array(0..<10_000), stop: shared) { item -> Int? in
                if item == 0 { started.signal() }
                usleep(100)
                return item
            }
            finished.signal()
        }
        started.wait()
        shared.stop()
        finished.wait()
        expect(result.stopped && result.done.count < 10_000, "a stop from another thread ends the moves", "\(result.done.count)")
        expect(shared.isStopped, "it stays stopped")

        // The asker's socket says it hung up before any main-thread cleanup calls stop(): the next move is the last.
        let socketGone = Locked(false)
        let watched = RoutineStop(also: { socketGone.value })
        let cut = RoutineStop.each(Array(1...5), stop: watched) { item -> Int? in
            if item == 2 { socketGone.value = true }
            return item
        }
        expect(cut.done == [1, 2] && cut.stopped, "a hang-up seen on the socket's thread stops the moves at once", "\(cut)")
        expect(!RoutineStop(also: { false }).isStopped, "an asker still there doesn't stop it")

        if failures > 0 { print("\(failures) routine stop check(s) failed"); exit(1) }
        print("routine stop: all checks passed")
    }
}
