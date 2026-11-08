import Foundation

// Checks ActingCancel.swift with IPC.swift's request: an act's or a vault call's `Acting.Cancel`, built for a call
// from outside Petal with its request's hung-up flag (as Assist.handle builds it), reads stopped the moment the
// socket's thread sees the client go, on any thread, while the main thread is blocked and has heard nothing; so does
// every job made under it. Petal's own chats (no request) are never stopped by it. No socket, no running Petal.
// Run with macos/checks/run.sh.

/// Stand-ins for what IPC.swift and ActingCancel.swift name but this check doesn't use.
enum Config { static let folder = URL(fileURLWithPath: NSTemporaryDirectory()) }
enum Acting {}
enum Vault {
    final class BuyToken: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var revoked: Bool { lock.withLock { flag } }
        func revoke() { lock.withLock { flag = true } }
    }
}
final class AgentPass: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    var revoked: Bool { lock.withLock { ended } }
    func revoke() { lock.withLock { ended = true } }
}

@main
struct CancelCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        if !condition { failures += 1; print("FAIL: \(what)") }
    }

    /// `body`'s answer, worked out on another thread while this one (the main thread) waits.
    static func elsewhere<T>(_ body: @escaping @Sendable () -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var answer: T?
        DispatchQueue.global().async { answer = body(); done.signal() }
        done.wait()
        return answer!
    }

    static func main() {
        // As Assist.handle: the socket's request, and `gone` read off it.
        let request: IPC.Pending? = IPC.Pending()
        let gone: @Sendable () -> Bool = { request?.hungUp == true }
        // The reply's (a session's) cancel, a call's token under it (ComputerUse.token), a job under that (fill, act).
        let turn = Acting.Cancel()
        let token = Acting.Cancel(under: turn, also: gone)
        let job = Acting.Cancel(under: token)
        let buy = Vault.BuyToken()
        let paid = Acting.Cancel(under: token, buy: buy, pass: AgentPass())
        // Petal's own chat: no request, nothing but its own Stop stops it.
        let own = Acting.Cancel(under: turn)

        expect(!token.stopped && !job.stopped && !paid.stopped, "nothing is stopped before the client goes")
        expect(token.isUnder(turn) && job.isUnder(turn) && job.isUnder(token) && turn.isUnder(turn), "a call's token and jobs are under its turn")
        expect(!turn.isUnder(token) && !own.isUnder(token), "a turn isn't under a call's token")

        // The main thread busy (blocked here), with something queued on it that would mark it as having run.
        nonisolated(unsafe) var mainRan = false
        DispatchQueue.main.async { mainRan = true }
        // The socket's thread sees the client go: IPC.Pending.cancel(), off the main thread.
        _ = elsewhere { request?.cancel(); return true }
        // Read at once on yet another thread, the main thread still blocked.
        let seen = elsewhere { (token: token.stopped, job: job.stopped, paid: paid.stopped, turn: turn.stopped, own: own.stopped) }
        expect(!mainRan, "the main thread didn't run in between")
        expect(seen.token, "the call's token reads stopped the moment the request is hung up, without the main thread")
        expect(seen.job, "a job under the call's token reads stopped at once")
        expect(seen.paid, "a payment fill under the call's token reads stopped at once")
        expect(!seen.turn, "the turn itself waits for the main thread's cleanup (Assist.hungUp)")
        expect(!seen.own, "Petal's own chat (no request) isn't stopped by an outside call's flag")
        expect(!paid.buyEnded, "a hang-up isn't a Buy ending")

        // A Stop still stops everything under the turn.
        own.stop()
        expect(own.stopped && !turn.stopped, "a job's own Stop stops only it")
        turn.stop()
        let afterStop = Acting.Cancel(under: turn)
        expect(afterStop.stopped, "the turn's Stop stops what's made under it")

        if failures > 0 { print("cancel: \(failures) failed"); exit(1) }
        print("cancel: a call's Acting.Cancel stops the moment its client hangs up, on any thread")
    }
}
