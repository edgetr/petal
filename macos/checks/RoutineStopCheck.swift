import Foundation

// Checks RoutineStop.swift: a routine's tidy stops before its next move once its asker hung up (or the routine
// changed), set from another thread, and says it stopped. No file is moved. Run with macos/checks/run.sh.
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

        if failures > 0 { print("\(failures) routine stop check(s) failed"); exit(1) }
        print("routine stop: all checks passed")
    }
}
