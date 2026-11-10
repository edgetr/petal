import Foundation

extension Acting.Cancel {
    /// The cancel of a reply's actions in the person's apps (ComputerUse's `Session`), for a note's helper: stopped
    /// whenever its run isn't running (`RunToken.halted`: paused, parked, stopped, failed or finished), read right
    /// before every change on whichever thread makes it, with no wait on the main thread. Every job of the reply is
    /// made under it, so a press, a key or a fill still waiting never goes once its run is paused. A chat with no run
    /// (`token` nil) has an ordinary one.
    convenience init(run token: RunToken?) {
        self.init(also: token.map { token in { @Sendable in token.halted } })
    }
}
