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

        print("dock rules: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
