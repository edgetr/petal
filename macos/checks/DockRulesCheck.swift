import CoreGraphics
import Foundation

// Checks DockRules.swift: which window a click on an app's icon brings forward. Run with macos/checks/run.sh.
@main
struct DockRulesCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static func main() {
        typealias W = DockRules.Window
        // Not in front: its frontmost window here, then minimized, then elsewhere.
        let here = [W(rank: 2, number: 5, title: "far"), W(rank: 0, number: 30, title: "A"), W(rank: 1, number: 7, title: "min", minimized: true),
                    W(rank: 0, number: 10, title: "B")]
        expect(DockRules.pick(here, active: false, focused: nil, focusedTitle: "") == 1, "a click on an app not in front brings its frontmost window here")
        expect(DockRules.pick([W(rank: 1, number: 7, title: "m", minimized: true), W(rank: 2, number: 3, title: "x")], active: false, focused: nil, focusedTitle: "") == 0,
               "with none here, a minimized one comes before one elsewhere")
        expect(DockRules.pick([], active: true, focused: nil, focusedTitle: "") == nil, "no windows, nothing to pick")

        // In front: clicking again goes through every window, whatever order the app lists them in as they come forward.
        var windows = [W(rank: 0, number: 30, title: "A"), W(rank: 0, number: 10, title: "B"), W(rank: 0, number: 20, title: "C")]
        var focused: UInt32 = 30
        var seen: [UInt32] = [focused]
        for _ in 0..<3 {
            let title = windows.first { $0.number == focused }?.title ?? ""
            guard let index = DockRules.pick(windows, active: true, focused: focused, focusedTitle: title) else { break }
            focused = windows[index].number!
            seen.append(focused)
            // The app lists the window that just came forward first (front to back).
            let picked = windows.remove(at: index)
            windows.insert(picked, at: 0)
        }
        expect(Set(seen.prefix(3)) == [10, 20, 30] && seen.last == seen.first, "three clicks go through all three windows and back", "\(seen)")

        // Two windows with the same title: the one in front is known by its number.
        let twins = [W(rank: 0, number: 8, title: "Untitled"), W(rank: 0, number: 4, title: "Untitled"), W(rank: 0, number: 6, title: "Notes")]
        // (By number: 4, 6, 8; after 8 comes 4 again.)
        let twin = DockRules.pick(twins, active: true, focused: 8, focusedTitle: "Untitled")
        expect(twin == 1, "after the window in front comes the next by number, even with the same title", "\(String(describing: twin))")
        // No number known: by title, as before.
        let untitled = [W(rank: 0, number: nil, title: "One"), W(rank: 0, number: nil, title: "Two")]
        expect(DockRules.pick(untitled, active: true, focused: nil, focusedTitle: "One") == 1, "without numbers, the window in front is known by its title")
        // The window in front isn't one of its windows (a panel): its frontmost, as when it isn't in front.
        expect(DockRules.pick(here, active: true, focused: 99, focusedTitle: "panel") == 1, "an unknown window in front picks the frontmost")
        // Minimized windows come into the round after the ones here.
        let mixed = [W(rank: 0, number: 2, title: "a"), W(rank: 1, number: 1, title: "m", minimized: true)]
        expect(DockRules.pick(mixed, active: true, focused: 2, focusedTitle: "a") == 1, "after the last window here comes a minimized one")

        // Which running apps that aren't the dock's own it lists: every one, but (only from this Desktop) one whose
        // windows are all on another Desktop. Hidden, only minimized, or with no window, it stays.
        typealias R = DockRules.Running
        let running = [R(id: "here", windows: 2, here: true), R(id: "elsewhere", windows: 1), R(id: "hidden", windows: 1, hidden: true),
                       R(id: "minimized", windows: 1, minimized: 1), R(id: "none"), R(id: "split", windows: 2, minimized: 1)]
        let shown = DockRules.others(running, kept: [], thisDesktopOnly: true)
        expect(shown == ["here", "hidden", "minimized", "none", "split"], "a running app stays unless its windows are all on another Desktop", "\(shown)")
        expect(DockRules.others(running, kept: [], thisDesktopOnly: false).count == 6, "with every Desktop, every running app shows")
        expect(DockRules.others(running, kept: ["none", "gone", "here"], thisDesktopOnly: true) == ["none", "here", "hidden", "minimized", "split"],
               "each keeps its slot for the session, new ones after, gone ones out")

        // A dot for every running app: full with a window here or in front, fainter otherwise; none when not running.
        expect(DockRules.dot(running: true, here: false, active: false) == 0.4, "a running app with no window here has a faint dot")
        expect(DockRules.dot(running: true, here: true, active: false) == 1 && DockRules.dot(running: true, here: false, active: true) == 1,
               "a window here or the app in front: a full dot")
        expect(DockRules.dot(running: false, here: false, active: false) == 0, "no dot for an app that isn't running")

        // Letting go of a dragged app, from what the callers have: how far along it moved, how far past the glass
        // the pointer is (inward), and whether it's one of the dock's own.
        let slot = 44.0
        let inDock = 10.0, outside = slot + 20
        expect(DockRules.dragEnd(began: false, from: 3, offset: 3, slot: slot, count: 8, kept: true, inward: inDock) == .click,
               "a press that slipped before it became a drag is a click")
        expect(DockRules.dragEnd(began: true, from: 3, offset: 10, slot: slot, count: 8, kept: false, inward: inDock) == .click,
               "a wobble in its own slot is a click, and never keeps a running app in the dock")
        expect(DockRules.dragEnd(began: true, from: 3, offset: 2 * slot + 5, slot: slot, count: 8, kept: true, inward: inDock) == .move(to: 5),
               "dragged two slots on: moved there")
        expect(DockRules.dragEnd(began: true, from: 1, offset: -10 * slot, slot: slot, count: 8, kept: true, inward: inDock) == .move(to: 0),
               "dragged past the start: first")
        expect(DockRules.dragEnd(began: true, from: 3, offset: 0, slot: slot, count: 8, kept: true, inward: outside) == .remove,
               "one of the dock's own let go out of the dock: removed")
        // A running app that isn't kept: out of the dock, letting go does nothing, whichever way it went; it never
        // looks as if it's being removed.
        for offset in [0, -2 * slot, 3 * slot] {
            expect(DockRules.dragEnd(began: true, from: 3, offset: offset, slot: slot, count: 8, kept: false, inward: outside) == .nothing,
                   "a running app that isn't kept, let go out of the dock (\(offset) along): nothing, not pinned or opened")
        }
        expect(!DockRules.fades(inward: outside, slot: slot, kept: false) && DockRules.fades(inward: outside, slot: slot, kept: true)
               && !DockRules.fades(inward: inDock, slot: slot, kept: true), "only one of the dock's own fades out of the dock")
        expect(DockRules.isOut(inward: slot + 1, slot: slot) && !DockRules.isOut(inward: slot - 1, slot: slot), "out means past the glass by more than a slot")

        // Dropped on the dock: apps, folders and addresses are added; documents open with the app; an app is never
        // opened with another app.
        let app = DockRules.dropped(path: "/Applications/Slack.app", web: nil, isDirectory: true)!
        let folder = DockRules.dropped(path: "/Users/x/Projects", web: nil, isDirectory: true)!
        let site = DockRules.dropped(path: nil, web: "https://example.com", isDirectory: false)!
        let document = DockRules.dropped(path: "/Users/x/a.pdf", web: nil, isDirectory: false)!
        expect(app == .app("/Applications/Slack.app") && folder == .folder("/Users/x/Projects") && site == .site("https://example.com")
               && document == .document("/Users/x/a.pdf"), "what each dropped thing is")
        expect(DockRules.drop([app], onApp: true) == .add([app]), "an app dropped on another app is added, not opened with it")
        expect(DockRules.drop([app, folder, site], onApp: false) == .add([app, folder, site]), "apps, folders and addresses dropped on the glass are added")
        expect(DockRules.drop([document], onApp: true) == .open(["/Users/x/a.pdf"]), "a document dropped on an app opens with it")
        expect(DockRules.drop([document], onApp: false) == nil, "a document on the glass, \"+\" or a website shortcut isn't taken")
        expect(DockRules.drop([document, app], onApp: true) == .open(["/Users/x/a.pdf"]), "documents and an app on an app: only the documents open")

        // Windows kept clear of a dock at the bottom of a 1000-point screen, reaching 80 in.
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let tall = CGRect(x: 100, y: 200, width: 800, height: 760)   // ends at 960, past 920
        expect(DockRules.clear(tall, screen: screen, reach: 80, position: "bottom") == CGRect(x: 100, y: 200, width: 800, height: 720),
               "a window opened or resized into the strip is shortened")
        expect(DockRules.clear(tall, screen: screen, reach: 80, position: "bottom", moved: true) == CGRect(x: 100, y: 160, width: 800, height: 760),
               "one moved there at its own size is moved back up at that size")
        let huge = CGRect(x: 0, y: 40, width: 800, height: 940)
        expect(DockRules.clear(huge, screen: screen, reach: 80, position: "bottom", moved: true).height == 880,
               "one too tall to fit above the dock is shortened even when moved")
        expect(DockRules.clear(CGRect(x: 10, y: 0, width: 500, height: 500), screen: screen, reach: 70, position: "left", moved: true).minX == 70,
               "a side dock: moved out sideways")

        // Look after look: a window dragged into the strip at its size goes back up at that size and stays so; an
        // app that keeps its window taller than asked is asked once, then moved out at its size, and left there.
        let docks = [DockRules.ClearDock(screen: screen, reach: 80)]
        var ledger = DockRules.ClearLedger()
        let resting = CGRect(x: 100, y: 300, width: 800, height: 600)   // ends at 900, clear of 920
        _ = ledger.look([(number: 7, frame: resting)], alive: [7], docks: docks, on: true, position: "bottom")
        let dropped = resting.offsetBy(dx: 0, dy: 80)   // dragged down to end at 980
        let up = ledger.look([(number: 7, frame: dropped)], alive: [7], docks: docks, on: true, position: "bottom")
        expect(up.map(\.to) == [CGRect(x: 100, y: 320, width: 800, height: 600)], "dragged into the strip at its size: moved back up", "\(up)")
        ledger.landed(7, asked: up[0].to, at: up[0].to)
        let again = ledger.look([(number: 7, frame: up[0].to)], alive: [7], docks: docks, on: true, position: "bottom")
        expect(again.isEmpty, "and on the next look it stays as it is, never shortened back down", "\(again)")
        var stubborn = DockRules.ClearLedger()
        let opened = CGRect(x: 100, y: 300, width: 800, height: 700)   // ends at 1000; the app keeps it 700 tall
        let first = stubborn.look([(number: 3, frame: opened)], alive: [3], docks: docks, on: true, position: "bottom")
        stubborn.landed(3, asked: first[0].to, at: opened)
        let out = stubborn.look([(number: 3, frame: opened)], alive: [3], docks: docks, on: true, position: "bottom")
        expect(first.map(\.to.height) == [620] && out.map(\.to) == [CGRect(x: 100, y: 220, width: 800, height: 700)],
               "a window its app keeps taller than asked is moved out at its size", "\(first) \(out)")
        stubborn.landed(3, asked: out[0].to, at: out[0].to)
        let rest = (0..<3).flatMap { _ in stubborn.look([(number: 3, frame: out[0].to)], alive: [3], docks: docks, on: true, position: "bottom") }
        expect(rest.isEmpty, "and then left alone, never asked again look after look", "\(rest)")

        ruleSweeps()
        clearSequences()

        print("dock rules: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: Generated sets

    /// The rules for which apps show, letting go of a drag and drops, over generated inputs: a running app is listed
    /// once and only while it's running, every one with only every Desktop asked for, each keeps its slot for the
    /// session; letting go never removes an app that isn't the dock's own or one let go in the dock, never moves one
    /// off the dock's ends, and a press that never became a drag is a click; a drop never adds a document or opens
    /// an app with another.
    static func ruleSweeps() {
        var dice = Dice(state: 7)
        var problems: [String] = []
        for _ in 0..<5000 {
            let ids = (0..<dice.int(0...12)).map { "app\($0)" }
            let running = ids.map { id in
                DockRules.Running(id: id, windows: dice.int(0...3), here: dice.chance(0.5), minimized: dice.int(0...2), hidden: dice.chance(0.2))
            }.map { app -> DockRules.Running in
                var app = app
                if app.windows == 0 { app.here = false; app.minimized = 0 }   // (as the window list counts them)
                app.minimized = min(app.minimized, app.windows)
                return app
            }
            let kept = (0..<dice.int(0...8)).map { _ in "app\(dice.int(0...15))" }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            for only in [false, true] {
                let shown = DockRules.others(running, kept: kept, thisDesktopOnly: only)
                if Set(shown).count != shown.count { problems.append("listed twice: \(shown)") }
                if !shown.allSatisfy(ids.contains) { problems.append("not running, listed: \(shown)") }
                if !only && shown.count != ids.count { problems.append("every Desktop, yet \(shown.count) of \(ids.count)") }
                let elsewhereOnly = running.filter { $0.windows > 0 && !$0.here && !$0.hidden && $0.minimized == 0 }.map(\.id)
                if only && (shown.contains { elsewhereOnly.contains($0) } || ids.count - elsewhereOnly.count != shown.count) {
                    problems.append("this Desktop only: \(shown) with \(elsewhereOnly) elsewhere")
                }
                let stayed = kept.filter(shown.contains)
                if Array(shown.prefix(stayed.count)) != stayed { problems.append("slots not kept: \(kept) → \(shown)") }
            }
            let count = dice.int(1...20), from = dice.int(0...(count - 1)), slot = dice.real(16, 128)
            let offset = dice.real(-30, 30) * slot / 10, inward = dice.real(-20, 3) * slot / 2, began = dice.chance(0.8), isKept = dice.chance(0.5)
            let end = DockRules.dragEnd(began: began, from: from, offset: offset, slot: slot, count: count, kept: isKept, inward: inward)
            switch end {
            case .click: break
            case .remove: if !isKept || inward <= slot || !began { problems.append("removed: kept \(isKept), inward \(inward), slot \(slot)") }
            case .nothing: if isKept || inward <= slot { problems.append("left alone: kept \(isKept), inward \(inward)") }
            case .move(let to): if to == from || to < 0 || to >= count || !began || inward > slot { problems.append("moved \(from) → \(to) of \(count)") }
            }
            if !began && end != .click { problems.append("a press that never became a drag: \(end)") }
            if DockRules.fades(inward: inward, slot: slot, kept: isKept) != (began && end == .remove) && began {
                problems.append("looks out (\(DockRules.fades(inward: inward, slot: slot, kept: isKept))) but lets go as \(end)")
            }
            let items: [DockRules.Dropped] = (0..<dice.int(0...4)).map { index in
                switch dice.int(0...3) {
                case 0: .app("/A\(index).app")
                case 1: .folder("/F\(index)")
                case 2: .site("https://s\(index).example")
                default: .document("/d\(index).pdf")
                }
            }
            let onApp = dice.chance(0.5)
            switch DockRules.drop(items, onApp: onApp) {
            case .add(let added): if added.contains(where: { if case .document = $0 { true } else { false } }) || added.isEmpty { problems.append("added \(added)") }
                if onApp && items.contains(where: { if case .document = $0 { true } else { false } }) { problems.append("added on an app with documents: \(items)") }
            case .open(let paths): if !onApp || paths.isEmpty { problems.append("opened \(paths) on the glass") }
            case nil: if !items.isEmpty && !(items.allSatisfy { if case .document = $0 { true } else { false } } && !onApp) { problems.append("nothing for \(items)") }
            }
        }
        expect(problems.isEmpty, "which apps show, letting go of a drag and drops hold over 5000 generated sets", problems.prefix(5).joined(separator: "\n  "))
    }

    // MARK: Windows kept clear of the dock, look after look

    /// A small generator that gives the same sequences every run.
    struct Dice {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func real(_ low: Double, _ high: Double) -> CGFloat { CGFloat(low + (high - low) * Double(next() % 10_000) / 10_000) }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
    }

    /// The window `frame` keeps out of the dock's strip on `dock` (as far as its size lets it).
    static func reachesIn(_ frame: CGRect, _ dock: DockRules.ClearDock, _ position: String) -> Bool {
        switch position {
        case "left": frame.minX < dock.screen.minX + dock.reach - 2 && frame.maxX > dock.screen.minX + dock.reach
        case "right": frame.maxX > dock.screen.maxX - dock.reach + 2 && frame.minX < dock.screen.maxX - dock.reach
        default: frame.maxY > dock.screen.maxY - dock.reach + 2 && frame.minY < dock.screen.maxY - dock.reach
        }
    }

    /// The ledger driven the way the dock drives it, over generated screens, windows and people: looks at the windows
    /// (some a moment old, from before a move landed), moves that land later (or find the window moved meanwhile),
    /// apps that keep a minimum size, the person dragging a window into the strip at its size, resizing into it,
    /// opening and closing windows, the dock's reach changing and the setting going off and on. Whatever happened,
    /// once the person stops: Petal stops moving windows within a few looks; a window keeps clear of the strip where
    /// its size lets it; a window dragged in at its size goes back out at that size and is never shortened later; a
    /// window that was on its screen stays on it; the same settings give the same frames (nothing creeps); and with
    /// the setting off every window Petal touched is back at the person's frame.
    static func clearSequences() {
        var dice = Dice(state: 20261113)
        var problems: [String] = []
        let layouts: [[CGRect]] = [
            [CGRect(x: 0, y: 0, width: 1440, height: 900)],
            [CGRect(x: 0, y: 0, width: 1280, height: 800)],
            [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1920, y: -100, width: 1920, height: 1080)],   // one to the left
            [CGRect(x: 0, y: 0, width: 1728, height: 1117), CGRect(x: 200, y: -1440, width: 2560, height: 1440)],   // one above
            [CGRect(x: 0, y: 0, width: 1024, height: 640), CGRect(x: 1024, y: 0, width: 1024, height: 640)],
        ]
        var runs = 0, steps = 0, moves = 0
        for run in 0..<1500 {
            runs += 1
            let screens = layouts[run % layouts.count]
            let position = ["bottom", "left", "right"][dice.int(0...2)]
            var reach = dice.real(40, 130)
            var on = true
            var fullScreen = Set<Int>()
            func docks() -> [DockRules.ClearDock] {
                screens.enumerated().map { DockRules.ClearDock(screen: $0.element, reach: reach, fullScreen: fullScreen.contains($0.offset)) }
            }
            // The app's own rule: never under its minimum size.
            var minimum: [UInt32: CGSize] = [:]
            var world: [UInt32: CGRect] = [:]
            // The person's own frame for each window (what giving back returns to), and whether it was dragged in at
            // its size.
            var person: [UInt32: CGRect] = [:]
            var draggedIn: Set<UInt32> = []
            var next: UInt32 = 1
            func apply(_ number: UInt32, _ frame: CGRect) -> CGRect {
                let least = minimum[number] ?? .zero
                return CGRect(x: frame.minX, y: frame.minY, width: max(frame.width, least.width), height: max(frame.height, least.height))
            }
            func open(into strip: Bool) {
                let screen = screens[dice.int(0...(screens.count - 1))]
                let least = dice.chance(0.4) ? CGSize(width: dice.real(200, 900), height: dice.real(150, 900)) : .zero
                var size = CGSize(width: dice.real(120, Double(screen.width)), height: dice.real(100, Double(screen.height - 30)))
                size = CGSize(width: max(size.width, min(least.width, screen.width)), height: max(size.height, min(least.height, screen.height - 30)))
                var origin = CGPoint(x: screen.minX + dice.real(0, Double(screen.width - size.width)),
                                     y: screen.minY + 30 + dice.real(0, Double(screen.height - 30 - size.height)))
                if strip {   // opened reaching into the strip, at the screen's far edge
                    switch position {
                    case "left": origin.x = screen.minX
                    case "right": origin.x = screen.maxX - size.width
                    default: origin.y = screen.maxY - size.height
                    }
                }
                let number = next
                next += 1
                minimum[number] = CGSize(width: min(least.width, size.width), height: min(least.height, size.height))
                world[number] = CGRect(origin: origin, size: size)
                person[number] = world[number]
            }
            for _ in 0..<dice.int(1...5) { open(into: dice.chance(0.5)) }
            var ledger = DockRules.ClearLedger()
            var pending: [DockRules.ClearLedger.Move] = []
            var old = world   // a look from a moment ago
            var lastSeen: [UInt32: CGRect] = [:]   // what the last look saw
            // Dragged at its size, until a look sees it: in the strip only where something is kept clear then.
            var awaiting: Set<UInt32> = []
            // (Dictionaries' order differs from run to run: picked from the numbers in order.)
            func pick() -> UInt32? { world.isEmpty ? nil : world.keys.sorted()[dice.int(0...(world.count - 1))] }
            func look(stale: Bool) {
                let seen = (stale ? old : world).sorted { $0.key < $1.key }.map { (number: $0.key, frame: $0.value) }
                old = world
                lastSeen = Dictionary(seen.map { ($0.number, $0.frame) }, uniquingKeysWith: { a, _ in a })
                if !stale {
                    for number in awaiting {
                        let frame = world[number] ?? .zero
                        let index = screens.firstIndex { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
                        if on, let index, !fullScreen.contains(index) { draggedIn.insert(number) } else { draggedIn.remove(number) }
                    }
                    awaiting = []
                }
                pending += ledger.look(seen, alive: Set(world.keys), docks: docks(), on: on, position: position)
            }
            func land() {
                for move in pending {
                    moves += 1
                    // As Dock.swift does: only while the window is still where the look saw it.
                    if let now = world[move.number], now.equalTo(move.from, within: 4) {
                        let actual = apply(move.number, move.to)
                        world[move.number] = actual
                        lastSeen[move.number] = actual
                        ledger.landed(move.number, asked: move.to, at: actual)
                    } else {
                        ledger.landed(move.number, asked: move.to, at: nil)
                    }
                }
                pending = []
            }
            // What happens, in any order.
            for _ in 0..<dice.int(4...30) {
                steps += 1
                switch dice.int(0...11) {
                case 0...3: look(stale: dice.chance(0.25)); if dice.chance(0.7) { land() }
                case 4: land()
                case 5:   // dragged at its size, often into the strip
                    guard let number = pick(), let frame = world[number],
                          let screen = screens.first(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else { break }
                    var moved = frame
                    if dice.chance(0.7) {
                        switch position {
                        case "left": moved.origin.x = screen.minX + dice.real(0, Double(reach) - 6)
                        case "right": moved.origin.x = screen.maxX - frame.width - dice.real(0, Double(reach) - 6)
                        default: moved.origin.y = screen.maxY - frame.height - dice.real(0, Double(reach) - 6)
                        }
                    } else {
                        moved.origin.x = screen.minX + dice.real(0, Double(max(0, screen.width - frame.width)))
                    }
                    // (A move of a few points, or to within a few points of a frame Petal just gave it, can't be told
                    // from Petal's own: a person's is more.)
                    guard screen.contains(moved.insetBy(dx: 1, dy: 1)) || !screen.contains(frame.insetBy(dx: 1, dy: 1)),
                          !moved.equalTo(frame, within: 6), !(ledger.cleared[number]?.knows(moved) ?? false) else { break }
                    world[number] = moved
                    person[number] = moved
                    // (Moved at its size, as a look can tell only from the frame the last look saw.)
                    draggedIn.remove(number)
                    if let last = lastSeen[number], abs(last.width - frame.width) < 1, abs(last.height - frame.height) < 1 { awaiting.insert(number) }
                    else { awaiting.remove(number) }
                case 6:   // resized, often into the strip
                    guard let number = pick(), var frame = world[number],
                          let screen = screens.first(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else { break }
                    switch position {
                    case "left": frame = CGRect(x: screen.minX, y: frame.minY, width: frame.maxX - screen.minX, height: frame.height)
                    case "right": frame.size.width = screen.maxX - frame.minX
                    default: frame.size.height = screen.maxY - frame.minY
                    }
                    frame = apply(number, frame)
                    guard !frame.equalTo(world[number]!, within: 6), !(ledger.cleared[number]?.knows(frame) ?? false) else { break }
                    world[number] = frame
                    person[number] = frame
                    draggedIn.remove(number)
                    awaiting.remove(number)
                case 7: open(into: dice.chance(0.7))
                case 8:
                    if world.count > 1, let number = pick() {
                        world[number] = nil
                        person[number] = nil
                    }
                case 9: reach = dice.real(40, 130)
                case 10: on.toggle()
                default:
                    if dice.chance(0.5) { fullScreen.insert(dice.int(0...(screens.count - 1))) } else { fullScreen = [] }
                }
            }
            // The person stops. Petal settles within a few looks, some of them a moment old.
            func settle(_ what: String) -> Bool {
                for round in 0..<8 {
                    look(stale: round == 0 && dice.chance(0.5))
                    if pending.isEmpty && round >= 1 { return true }
                    land()
                }
                problems.append("run \(run) (\(position), \(what)): still moving windows after 8 looks")
                return false
            }
            guard settle("first") else { continue }
            let settled = world, wasOn = on
            for (number, frame) in world {
                guard let index = screens.firstIndex(where: { $0.contains(CGPoint(x: (person[number] ?? frame).midX, y: (person[number] ?? frame).midY)) })
                else { continue }
                let dock = docks()[index]
                let mine = person[number] ?? frame
                if !on || dock.fullScreen {
                    if !frame.equalTo(mine, within: 5) { problems.append("run \(run) (\(position)): with nothing to keep clear, \(mine) is at \(frame)") }
                    continue
                }
                let least = minimum[number] ?? .zero
                // Where the size the app keeps can't fit beside the strip, it may still reach in.
                let room: CGFloat = position == "bottom" ? dock.screen.height - dock.reach - 30 : dock.screen.width - dock.reach
                let need = position == "bottom" ? least.height : least.width
                if reachesIn(frame, dock, position) && need <= room - 1 {
                    problems.append("run \(run) (\(position)): \(mine) (at least \(least)) left in the strip at \(frame), reach \(dock.reach)")
                }
                if screens[index].contains(mine.insetBy(dx: 1, dy: 1)) && !screens[index].insetBy(dx: -1, dy: -1).contains(frame) {
                    problems.append("run \(run) (\(position)): \(mine) moved off its screen to \(frame)")
                }
                // Dragged in at its size: back out at that size where it fits, never shortened.
                let fits = (position == "bottom" ? mine.height : mine.width) <= room - 1
                if draggedIn.contains(number), fits, reachesIn(mine, dock, position),
                   abs(frame.width - mine.width) > 2 || abs(frame.height - mine.height) > 2 {
                    problems.append("run \(run) (\(position)): dragged in at \(mine.size), shortened to \(frame.size)")
                }
            }
            // Nothing creeps: looking again and again changes nothing.
            for _ in 0..<3 { look(stale: false); land() }
            if world != settled { problems.append("run \(run) (\(position)): frames crept after settling") }
            // The setting off: every window back at the person's frame.
            on = false
            guard settle("given back") else { continue }
            for (number, frame) in world where !frame.equalTo(person[number] ?? frame, within: 5) {
                problems.append("run \(run) (\(position)): not given back: \(person[number]!) is at \(frame)")
            }
            // And on again: the same frames as before.
            on = true
            guard settle("on again") else { continue }
            for (number, frame) in world where wasOn && settled[number].map({ !$0.equalTo(frame, within: 2) }) ?? false {
                problems.append("run \(run) (\(position)): on again, \(settled[number]!) became \(frame)")
            }
        }
        expect(problems.isEmpty, "windows kept clear of the dock settle, keep clear where they fit, never shrink step by step and come back (\(runs) runs, \(steps) steps, \(moves) moves)",
               problems.prefix(6).joined(separator: "\n  "))
    }
}
