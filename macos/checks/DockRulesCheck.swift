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

        print("dock rules: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
