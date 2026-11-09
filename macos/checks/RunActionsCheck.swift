import Foundation

// Checks that what a note's helper does in the person's apps ends with every change of its run's state, with the real
// RunToken (NoteHelp.swift), Acting.Cancel (ActingCancel.swift, RunActions.swift) and the gate every change goes
// through (Background.Gate with Background.check, as Acting.changeGate builds it): Pause with a press still waiting,
// and the press never happens. No app, no Accessibility, nothing pressed. Run with macos/checks/run.sh.

/// Stand-ins for what ActingCancel.swift names but this check doesn't use.
enum Acting {}
enum Vault {
    final class BuyToken: @unchecked Sendable {
        var revoked: Bool { false }
        func revoke() {}
    }
}
final class AgentPass: @unchecked Sendable {
    var revoked: Bool { false }
}

@main
struct RunActionsCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ condition: Bool, _ what: String) {
        if condition { passed += 1 } else { failures += 1; print("FAIL: \(what)") }
    }

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ what: String) { lock.withLock { list.append(what) } }
        var all: [String] { lock.withLock { list } }
    }

    /// A reply's actions for a helper's run, as ComputerUse makes them: the turn's cancel bound to the run's token
    /// (`Session.init(turn:run:)`), a job's under it (`Job.cancel`), and the gate its change goes through.
    static func press(under token: RunToken?) -> (turn: Acting.Cancel, job: Acting.Cancel, gate: Background.Gate) {
        let turn = Acting.Cancel(run: token)
        let job = Acting.Cancel(under: turn)
        return (turn, job, Background.Gate { Background.check(stopped: { job.stopped }, read: { nil }) })
    }

    static func main() {
        // Pause with a queued press: the press never happens.
        let token = RunToken()
        let log = Log()
        token.actions { log.add("actions ended") }
        _ = token.bind { log.add("process ended") }
        let queued = press(under: token)
        expect(!queued.job.stopped && !token.halted, "a running run: its press may go")
        var pressed = 0
        expect(queued.gate.mutate { pressed += 1 } != nil && pressed == 1, "and goes through its gate")
        let waiting = press(under: token)
        expect(token.pause(), "Pause")
        expect(log.all == ["actions ended", "process ended"], "pausing ends its actions in apps first, synchronously, then its process")
        expect(waiting.job.stopped && waiting.turn.stopped && token.halted, "every pending effect of the run reads stopped at once")
        expect(waiting.gate.mutate { pressed += 1 } == nil && pressed == 1 && waiting.gate.refused && !waiting.gate.changed, "the press that waited never happens")
        // The same from another thread, with this one (the main thread) blocked: nothing waits on it.
        let elsewhere = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var seen = false
        DispatchQueue.global().async { seen = waiting.job.stopped; elsewhere.signal() }
        elsewhere.wait()
        expect(seen, "read on any thread, with no wait on the main thread")
        // A tool's park pauses the token the same way: there is no other way to pause one.
        let parked = RunToken()
        let parkedLog = Log()
        parked.actions { parkedLog.add("actions ended") }
        let parkedPress = press(under: parked)
        parked.pause()
        expect(parkedLog.all == ["actions ended"] && parkedPress.gate.mutate { pressed += 1 } == nil && pressed == 1, "parked: its actions end, its queued press never happens")
        // Stop, a failure, a stamp taken back and the run's end: each ends its actions, first.
        for (name, change) in [("stop", { (token: RunToken) in _ = token.cancel() }), ("stopped", { _ = $0.complete(.stopped) }),
                               ("failed", { _ = $0.complete(.failed("no API key")) }), ("succeeded", { _ = $0.complete(.succeeded) }),
                               ("grant taken back", { $0.hold("always:computer:x"); _ = $0.revoke("always:computer:x") })] as [(String, (RunToken) -> Void)] {
            let token = RunToken()
            let log = Log()
            token.actions { log.add("actions ended") }
            _ = token.bind { log.add("process ended") }
            let press = press(under: token)
            change(token)
            expect(log.all.first == "actions ended" && press.job.stopped && press.gate.mutate { pressed += 1 } == nil && pressed == 1,
                   "\(name): its actions end first, and a press still waiting never happens")
        }
        // Go on: the run runs again, but what waited under the paused turn was already ended (ComputerUse closed that
        // turn); a new turn's actions are its own.
        expect(token.goOn() && !token.halted, "Go on: the run admits again")
        let after = press(under: token)
        expect(after.gate.mutate { pressed += 1 } != nil && pressed == 2, "a new turn's press goes")
        // An ordinary chat has no run: its actions are stopped only by its own Stop.
        let chat = press(under: nil)
        expect(!chat.job.stopped && chat.gate.mutate { pressed += 1 } != nil && pressed == 3, "a chat with no run acts as before")
        chat.turn.stop()
        expect(chat.job.stopped, "and its own Stop still stops it")

        print("run actions: \(passed) passed" + (failures > 0 ? ", \(failures) failed" : ""))
        if failures > 0 { exit(1) }
    }
}
