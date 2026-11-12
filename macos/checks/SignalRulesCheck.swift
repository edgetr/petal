import Foundation

// Checks SignalRules.swift: which badges went up (the dock bounces those apps) and which player the dock shows. Run
// with macos/checks/run.sh.
@main
struct SignalRulesCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static func main() {
        // A badge as an amount.
        expect(SignalRules.amount("") == 0, "no badge is none")
        expect(SignalRules.amount("3") == 3, "a number is itself")
        expect(SignalRules.amount(" 12 ") == 12, "spaces round a number don't count")
        expect(SignalRules.amount("99+") == 99, "a capped count is its number", "\(SignalRules.amount("99+"))")
        expect(SignalRules.amount("•") == 0.5, "a dot is less than one")
        expect(SignalRules.amount("!") == 0.5, "a mark is less than one")
        expect(SignalRules.amount("١٢") == 12, "another script's digits are a number", "\(SignalRules.amount("١٢"))")

        let start = Date(timeIntervalSince1970: 1_000_000)
        func read(_ dock: Int32, _ seconds: Double, _ badges: [String: String]) -> SignalRules.Read {
            SignalRules.Read(dock: dock, at: start.addingTimeInterval(seconds), badges: badges)
        }
        let settled = start   // the Dock first heard from at `start`
        // Petal starting: every badge already there is the first read, never a bounce.
        expect(SignalRules.wentUp(before: nil, now: read(7, 0, ["mail": "3", "slack": "•"]), dockSince: settled).isEmpty,
               "the first read bounces nothing")
        // A Dock that just started shows the badges apps had, one by one: no bounce while it settles.
        expect(SignalRules.wentUp(before: read(7, 2, [:]), now: read(7, 4, ["mail": "3"]), dockSince: settled).isEmpty,
               "badges coming back to a Dock that just started bounce nothing")
        // Then a real change bounces.
        expect(SignalRules.wentUp(before: read(7, 20, ["mail": "3"]), now: read(7, 22, ["mail": "4"]), dockSince: settled) == ["mail"],
               "a count going up bounces once")
        expect(SignalRules.wentUp(before: read(7, 20, [:]), now: read(7, 22, ["mail": "1"]), dockSince: settled) == ["mail"],
               "a new badge bounces")
        expect(SignalRules.wentUp(before: read(7, 20, ["slack": "•"]), now: read(7, 22, ["slack": "1"]), dockSince: settled) == ["slack"],
               "a dot becoming a count went up")
        expect(SignalRules.wentUp(before: read(7, 20, ["mail": "99+"]), now: read(7, 22, ["mail": "2"]), dockSince: settled).isEmpty,
               "99+ becoming 2 went down")
        expect(SignalRules.wentUp(before: read(7, 20, ["mail": "9"]), now: read(7, 22, ["mail": "99+"]), dockSince: settled) == ["mail"],
               "9 becoming 99+ went up")
        expect(SignalRules.wentUp(before: read(7, 20, ["mail": "3"]), now: read(7, 22, ["mail": "3"]), dockSince: settled).isEmpty,
               "the same badge again bounces nothing")
        expect(SignalRules.wentUp(before: read(7, 20, ["mail": "3"]), now: read(7, 22, [:]), dockSince: settled).isEmpty,
               "a badge going bounces nothing")
        // Another Dock (it restarted): its first read is a new start.
        expect(SignalRules.wentUp(before: read(7, 20, [:]), now: read(9, 22, ["mail": "3"]), dockSince: start.addingTimeInterval(22)).isEmpty,
               "the first read from a Dock that restarted bounces nothing")
        expect(SignalRules.wentUp(before: read(9, 24, [:]), now: read(9, 26, ["mail": "3"]), dockSince: start.addingTimeInterval(22)).isEmpty,
               "a restarted Dock settling bounces nothing")
        expect(SignalRules.wentUp(before: read(9, 40, ["mail": "3"]), now: read(9, 42, ["mail": "5"]), dockSince: start.addingTimeInterval(22)) == ["mail"],
               "a restarted Dock that settled bounces again")
        expect(SignalRules.wentUp(before: read(7, 20, [:]), now: read(7, 22, ["b": "1", "a": "2"]), dockSince: settled) == ["a", "b"],
               "several at once, in order")

        // Which player's song shows.
        expect(SignalRules.shownPlayer(playing: []) == nil, "no player with a song shows none")
        expect(SignalRules.shownPlayer(playing: [false, true]) == 1, "one playing shows before one paused")
        expect(SignalRules.shownPlayer(playing: [true, true]) == 0, "the first of two playing")
        expect(SignalRules.shownPlayer(playing: [false, false]) == 0, "both paused: the first")

        print("signals: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
