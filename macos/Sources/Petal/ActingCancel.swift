import Foundation

extension Acting {
    /// Stop, seen at once from any thread. A job's is under its turn's: stopping the turn stops every job in it.
    /// Pure (Foundation only), so `macos/checks/run.sh` checks it.
    final class Cancel: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        private let parent: Cancel?
        /// A payment fill's Buy: revoking it stops the fill as a Stop would.
        private let buy: Vault.BuyToken?
        /// An agent's fill: removing the grant it relies on stops it as a Stop would.
        private let pass: AgentPass?
        /// Read on whichever thread asks, with no wait on the main thread: for a call from outside Petal, its socket's
        /// own flag (`IPC.Pending.hungUp`), set the moment the socket's thread sees the client go. The main thread's
        /// cleanup (Assist.hungUp, which stops the whole session) may come later; this stops the call's own work at
        /// once. Petal's own chats have none.
        private let also: (@Sendable () -> Bool)?

        init(under parent: Cancel? = nil, buy: Vault.BuyToken? = nil, pass: AgentPass? = nil, also: (@Sendable () -> Bool)? = nil) {
            self.parent = parent
            self.buy = buy
            self.pass = pass
            self.also = also
        }

        var stopped: Bool {
            lock.lock()
            let own = flag
            lock.unlock()
            return own || (also?() ?? false) || buyEnded || (pass?.revoked ?? false) || (parent?.stopped ?? false)
        }
        /// The Buy this fill was made under is over.
        var buyEnded: Bool { (buy?.revoked ?? false) || (parent?.buyEnded ?? false) }
        func stop() { lock.lock(); flag = true; lock.unlock() }
        /// Ends the Buy this fill was made under, for good: its page moved on while it filled.
        func endBuy() { buy?.revoke() }
        /// This is `other`, or was made under it (a call's own token under its turn's).
        func isUnder(_ other: Cancel) -> Bool { self === other || (parent?.isUnder(other) ?? false) }
    }
}
