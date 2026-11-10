import CoreGraphics
import Foundation

// Checks RunDisplayPlan.swift: who gets a hidden display and who waits, sharing within a note, release on every
// ending, the limit by memory, where a display goes (a corner of the person's screens, never beside one), which
// displays are the person's, what an open would do, and what happens to a window a run leaves. No display is made:
// these are the plan's own decisions. Run with macos/checks/run.sh.
@main
struct RunDisplayCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    typealias Effect = RunDisplayPlan.Effect

    static func main() {
        // MARK: The limit

        let gb: UInt64 = 1024 * 1024 * 1024
        expect(RunDisplayRules.limit(memory: 8 * gb, setting: 0) == 1, "8 GB: one display")
        expect(RunDisplayRules.limit(memory: 4 * gb, setting: 0) == 1, "less than 8 GB: still one")
        expect(RunDisplayRules.limit(memory: 16 * gb, setting: 0) == 2, "16 GB: two")
        expect(RunDisplayRules.limit(memory: 18 * gb, setting: 0) == 2, "18 GB: two (whole 8 GBs)")
        expect(RunDisplayRules.limit(memory: 36 * gb, setting: 0) == 4, "36 GB: four")
        expect(RunDisplayRules.limit(memory: 128 * gb, setting: 0) == 4, "never more than four")
        expect(RunDisplayRules.limit(memory: 64 * gb, setting: 2) == 2, "the setting lowers it")
        expect(RunDisplayRules.limit(memory: 16 * gb, setting: 4) == 2, "the setting never raises it past the memory's")
        expect(RunDisplayRules.limit(memory: 64 * gb, setting: -3) == 4, "a setting of nothing is the memory's")
        expect(RunDisplayRules.limit(memory: 64 * gb, setting: 1) == 1, "down to one")

        // MARK: Who shares

        expect(RunDisplayRules.group(caller: "A1", paper: "note-7") == RunDisplayRules.group(caller: "B2", paper: "note-7"),
               "a helper and the second opinion its note starts share one group")
        expect(RunDisplayRules.group(caller: "A1", paper: "n1") != RunDisplayRules.group(caller: "A1", paper: "n2"), "two notes never share")
        expect(RunDisplayRules.group(caller: "mcp-41", paper: nil) == "mcp-41", "an AI session outside Petal is itself (its subagents ask through it)")
        expect(RunDisplayRules.group(caller: "mcp-41", paper: nil) != RunDisplayRules.group(caller: "mcp-42", paper: nil), "two sessions never share")
        expect(RunDisplayRules.group(caller: "chat", paper: "") == "chat", "a chat is itself")

        // MARK: Where a window goes by default

        expect(RunDisplayRules.place(asked: nil, on: false, asker: .helper) == .screen, "off: always the person's screen")
        expect(RunDisplayRules.place(asked: "display", on: false, asker: .helper) == .screen, "off: even when asked")
        expect(RunDisplayRules.place(asked: nil, on: true, asker: .helper) == .display, "a helper works on its own display")
        expect(RunDisplayRules.place(asked: nil, on: true, asker: .outside) == .display, "so does an AI session outside Petal")
        expect(RunDisplayRules.place(asked: nil, on: true, asker: .chat) == .screen, "the quick question opens on the person's screen")
        expect(RunDisplayRules.place(asked: "Display", on: true, asker: .chat) == .display, "unless it says its own display")
        expect(RunDisplayRules.place(asked: "screen", on: true, asker: .helper) == .screen, "a helper may say the person's screen")
        expect(RunDisplayRules.place(asked: "elsewhere", on: true, asker: .helper) == .display, "a word it doesn't know is no word")

        // MARK: The plan: not before it's needed

        var plan = RunDisplayPlan(limit: 2)
        expect(plan.join("a", group: "A") == [], "a run existing makes nothing")
        expect(plan.standing(of: "A") == .none, "no display before the first window")
        var asked = plan.need("a", group: "A")
        expect(asked.standing == .has && asked.effects == [.make("A")], "the first window makes its display", "\(asked)")
        asked = plan.need("a", group: "A")
        expect(asked.standing == .has && asked.effects == [], "the same run needs no second one")

        // MARK: Sharing

        asked = plan.need("a2", group: "A")
        expect(asked.standing == .has && asked.effects == [], "what the run starts shares its display")
        expect(plan.join("a3", group: "A") == [], "a second opinion joins without making anything")
        expect(plan.runs(in: "A") == ["a", "a2", "a3"], "all three hold it")

        // MARK: The limit and the queue, in order

        asked = plan.need("b", group: "B")
        expect(asked.standing == .has && asked.effects == [.make("B")], "a second group gets the second display")
        asked = plan.need("c", group: "C")
        expect(asked.standing == .waiting(1) && asked.effects == [], "the third waits", "\(asked)")
        asked = plan.need("d", group: "D")
        expect(asked.standing == .waiting(2) && asked.effects == [], "the fourth waits behind it")
        expect(plan.need("c", group: "C").standing == .waiting(1), "asking again keeps its place")
        expect(plan.holding == ["A", "B"] && plan.queue == ["C", "D"], "two have one, two wait in order")

        // MARK: Release

        expect(plan.leave("a") == [], "one of three leaving keeps the display")
        expect(plan.leave("a2") == [], "two of three leaving keeps it")
        expect(plan.leave("a3") == [.remove("A"), .make("C")], "the last leaving removes it, and the first waiting gets one")
        expect(plan.leave("a3") == [], "leaving twice does nothing")
        expect(plan.leave("nobody") == [], "a run that never was leaves nothing")
        expect(plan.standing(of: "C") == .has && plan.standing(of: "D") == .waiting(1), "the queue moved up one")

        // A run that ends while it waits.
        expect(plan.leave("d") == [], "one that ends while waiting removes nothing")
        expect(plan.standing(of: "D") == .none && plan.queue.isEmpty, "and waits no more")
        expect(plan.leave("b") == [.remove("B")], "with nobody waiting, a display removed makes none")
        expect(plan.leave("c") == [.remove("C")], "the last one")
        expect(plan.holding.isEmpty && plan.queue.isEmpty && plan.members.isEmpty, "nothing left behind")

        // MARK: A queue never jumped

        plan = RunDisplayPlan(limit: 1)
        _ = plan.need("a", group: "A")
        _ = plan.need("b", group: "B")
        _ = plan.need("c", group: "C")
        expect(plan.queue == ["B", "C"], "two wait")
        var effects = plan.leave("b")
        expect(effects == [] && plan.queue == ["C"], "the first waiting giving up lets the next be first")
        effects = plan.leave("a")
        expect(effects == [.remove("A"), .make("C")], "then it gets the display")
        // A new group never goes ahead of one waiting, even when a place just freed in the same breath.
        plan = RunDisplayPlan(limit: 1)
        _ = plan.need("a", group: "A")
        _ = plan.need("b", group: "B")
        expect(plan.need("z", group: "Z").standing == .waiting(2), "a newcomer goes to the back")

        // MARK: Moving to another group

        plan = RunDisplayPlan(limit: 2)
        _ = plan.need("a", group: "A")
        effects = plan.join("a", group: "B")
        expect(effects == [.remove("A")] && plan.group(of: "a") == "B", "a run that moves leaves its old group's display behind")

        // MARK: Every ending

        plan = RunDisplayPlan(limit: 1)
        _ = plan.need("a", group: "A")
        _ = plan.need("a2", group: "A")
        _ = plan.need("b", group: "B")
        expect(plan.end(group: "A") == [.remove("A"), .make("B")], "a whole group ending at once (Stop on its tile)")
        expect(plan.end(group: "A") == [], "twice does nothing")
        expect(plan.lost(group: "B") == [], "a display macOS took away: nothing to remove")
        expect(plan.standing(of: "B") == .none && plan.group(of: "b") == "B", "its run stays, without a display")
        asked = plan.need("b", group: "B")
        expect(asked.standing == .has && asked.effects == [.make("B")], "and gets another when it next needs one")
        _ = plan.need("c", group: "C")
        effects = plan.endAll()
        expect(effects == [.remove("B")] && plan.members.isEmpty && plan.queue.isEmpty && plan.holding.isEmpty,
               "turned off, or quitting: every display removed, nobody waiting", "\(effects)")
        expect(plan.endAll() == [], "twice does nothing")

        // MARK: The limit changing

        plan = RunDisplayPlan(limit: 1)
        _ = plan.need("a", group: "A")
        _ = plan.need("b", group: "B")
        _ = plan.need("c", group: "C")
        expect(plan.setLimit(3) == [.make("B"), .make("C")], "raised: the ones waiting get theirs, in order")
        expect(plan.setLimit(1) == [], "lowered: nothing is taken from a run at work")
        expect(plan.holding == ["A", "B", "C"], "all three keep theirs")
        expect(plan.need("d", group: "D").standing == .waiting(1), "a new one waits")
        expect(plan.leave("a") == [.remove("A")], "one ending doesn't let the next in while over the limit")
        expect(plan.leave("b") == [.remove("B")], "nor the second")
        expect(plan.leave("c") == [.remove("C"), .make("D")], "under the limit again: the one waiting gets it")
        expect(RunDisplayPlan(limit: 0).limit == 1, "never fewer than one")

        // MARK: Where a display goes

        let size = RunDisplayRules.size
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        func frame(_ point: CGPoint?) -> CGRect { point.map { CGRect(origin: $0, size: size) } ?? .null }
        let first = RunDisplayRules.origin(size: size, screens: [main], taken: [])
        expect(first == CGPoint(x: -1440, y: -900), "above and left of the main screen, at its corner", "\(String(describing: first))")
        expect(RunDisplayRules.hiddenFrom(frame(first), screens: [main], others: []), "which the pointer can't reach")
        expect(!RunDisplayRules.sharesEdge(frame(first), main) && !RunDisplayRules.overlaps(frame(first), main), "no shared edge, no overlap")
        // Beside the screen, where macOS first puts a new display: the pointer would wander onto it.
        let beside = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        expect(RunDisplayRules.sharesEdge(beside, main), "beside the screen shares an edge")
        expect(!RunDisplayRules.hiddenFrom(beside, screens: [main], others: []), "so that's never where it stays")
        expect(!RunDisplayRules.hiddenFrom(CGRect(x: 100, y: -900, width: 1440, height: 900), screens: [main], others: []), "nor above it")
        expect(!RunDisplayRules.hiddenFrom(CGRect(x: 200, y: 200, width: 1440, height: 900), screens: [main], others: []), "nor over it")
        // Four corners for four displays, none overlapping another.
        var taken: [CGRect] = []
        for index in 0..<4 {
            let next = RunDisplayRules.origin(size: size, screens: [main], taken: taken)
            expect(next != nil, "a corner for display \(index + 1)")
            guard let next else { break }
            let rect = frame(next)
            expect(RunDisplayRules.hiddenFrom(rect, screens: [main], others: taken), "display \(index + 1) is out of reach and overlaps no other")
            taken.append(rect)
        }
        expect(Set(taken.map { "\($0.minX),\($0.minY)" }).count == 4, "four different corners")
        // A fifth has no corner left: it goes beside a run display, still away from the person's screen.
        let fifth = RunDisplayRules.origin(size: size, screens: [main], taken: taken)
        expect(fifth != nil && RunDisplayRules.hiddenFrom(frame(fifth), screens: [main], others: taken), "past the corners: beside another run's display")
        // Two screens side by side: a corner that is beside the other screen is no corner.
        let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        for point in RunDisplayRules.origins(size: size, screens: [main, second], taken: []) {
            expect(RunDisplayRules.hiddenFrom(frame(point), screens: [main, second], others: []), "with two screens, out of reach of both: \(point)")
        }
        expect(!RunDisplayRules.origins(size: size, screens: [main, second], taken: []).isEmpty, "two screens still leave corners")
        // A screen above and to the left of the main one, exactly where the first choice would go.
        let above = CGRect(x: -1440, y: -900, width: 1440, height: 900)
        let other = RunDisplayRules.origin(size: size, screens: [main, above], taken: [])
        expect(other != nil && frame(other) != above && RunDisplayRules.hiddenFrom(frame(other), screens: [main, above], others: []),
               "a corner already holding one of the person's screens is passed over")
        expect(RunDisplayRules.origins(size: size, screens: [], taken: []).isEmpty, "no screens: nowhere")

        // MARK: The person's screens

        expect(RunDisplayRules.persons([1, 2, 3], runs: [2]) == [1, 3], "a run's display is not the person's screen")
        expect(RunDisplayRules.persons([1, 2], runs: []) == [1, 2], "with none, every screen is theirs")
        expect(RunDisplayRules.persons([7], runs: [7]) == [], "only a run's: none of theirs")
        let displays: [(id: Int, frame: CGRect)] = [(9, frame(first)), (10, CGRect(x: 1512, y: 982, width: 1440, height: 900))]
        expect(RunDisplayRules.display(holding: CGRect(x: -1400, y: -860, width: 800, height: 600), among: displays) == 9, "a window is on the display its middle is on")
        expect(RunDisplayRules.display(holding: CGRect(x: 100, y: 100, width: 800, height: 600), among: displays) == nil, "one on the person's screen is on none")
        expect(RunDisplayRules.display(holding: CGRect(x: -500, y: -300, width: 1000, height: 800), among: displays) == nil,
               "one mostly on the person's screen isn't taken for a run's")

        // MARK: Where a window goes on a display

        let display = frame(first)
        let small = RunDisplayRules.frame(for: CGSize(width: 900, height: 600), on: display)
        expect(display.contains(small) && small.size == CGSize(width: 900, height: 600), "a window that fits keeps its size, inside the display", "\(small)")
        let big = RunDisplayRules.frame(for: CGSize(width: 3000, height: 2000), on: display)
        expect(display.contains(big), "one too big is made to fit", "\(big)")
        let next = RunDisplayRules.frame(for: CGSize(width: 900, height: 600), on: display, index: 1)
        expect(next.origin != small.origin && display.contains(next), "the next one sits a little down and right")
        for index in 0..<20 {
            expect(display.contains(RunDisplayRules.frame(for: CGSize(width: 1300, height: 800), on: display, index: index)), "window \(index) stays inside")
        }

        // MARK: What an open would do

        typealias Opening = RunDisplayRules.Opening
        expect(RunDisplayRules.opening(running: false, windows: 0, address: true, browser: true, bare: false) == .go, "a browser that isn't open makes a window of its own")
        expect(RunDisplayRules.opening(running: true, windows: 2, address: true, browser: true, bare: false) == Opening.tabInTheirs,
               "an address in a browser the person has open would be a tab in their window: not opened")
        expect(RunDisplayRules.opening(running: true, windows: 0, address: true, browser: true, bare: false) == .go, "a browser open with no window makes one")
        expect(RunDisplayRules.opening(running: true, windows: 3, address: false, browser: false, bare: true) == Opening.nothingNew,
               "an app the person has open, asked for by itself, shows nothing new")
        expect(RunDisplayRules.opening(running: true, windows: 3, address: false, browser: false, bare: false) == .go, "a file in an app that's open makes its own window")
        expect(RunDisplayRules.opening(running: false, windows: 0, address: false, browser: false, bare: true) == .go, "an app that isn't open opens")
        expect(RunDisplayRules.opening(running: true, windows: 1, address: true, browser: false, bare: false) == .go, "an address in an app that isn't a browser")

        // MARK: What a run leaves behind

        typealias Left = RunDisplayRules.Left
        expect(RunDisplayRules.leftover(Left(opened: true, empty: true, shown: false)) == .close, "its own empty window is closed")
        expect(RunDisplayRules.leftover(Left(opened: true, empty: false, shown: false)) == .bringBack, "its own window with anything in it comes back to the person")
        expect(RunDisplayRules.leftover(Left(opened: false, empty: true, shown: false)) == .bringBack, "a window it didn't open is never closed")
        expect(RunDisplayRules.leftover(Left(opened: false, empty: false, shown: false)) == .bringBack, "nor one with work in it")
        expect(RunDisplayRules.leftover(Left(opened: true, empty: true, shown: true)) == .leave, "one the person took to their screen is left alone")
        expect(RunDisplayRules.leftover(Left(opened: true, empty: false, shown: true)) == .leave, "whatever is in it")

        if failures > 0 { print("run displays: \(failures) failed"); exit(1) }
        print("run displays: \(passed) checks passed")
    }
}
