import Foundation

// Checks Background.swift: when a sticky note acts in the background, what it does there for each action, what needs
// its window in front, what it puts back after, its preview's pictures, and each note's line in the AI button's preview. Run with macos/checks/run.sh.
@main
struct BackgroundCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static func situation(note: Bool = true, front: Bool = false, focused: Bool = false, idle: TimeInterval = 30) -> Background.Situation {
        Background.Situation(note: note, appFront: front, windowFocused: focused, idle: idle)
    }

    static func plan(_ action: String, text: Bool = false, web: Bool = false, clipboard: Bool = false, menuItem: Bool = false,
                     opens: Bool = false, element: Bool = true, front: Bool = false, main: Bool = true) -> Background.Step {
        Background.plan(Background.Target(action: action, text: text, web: web, clipboard: clipboard, menuItem: menuItem,
                                          opens: opens, element: element, appFront: front, windowMain: main))
    }

    static func main() {
        // MARK: Which way

        expect(Background.way(situation(note: false)) == .foreground, "Petal AI's plain chat keeps its pointer")
        expect(Background.way(situation(note: false, front: true, focused: true, idle: 0)) == .foreground,
               "an AI session outside Petal keeps today's rules, even while the person types")
        expect(Background.way(situation()) == .background, "a note whose app is behind works in the background")
        expect(Background.way(situation(front: false, focused: true)) == .background, "its app's focused window, but the app is behind")
        expect(Background.way(situation(front: true, focused: false)) == .background,
               "the person uses another window of the same app: the note's window is still in the background")
        expect(Background.way(situation(front: true, focused: true, idle: 30)) == .foreground,
               "the note's window in front and the person idle: done there, with the pointer")
        expect(Background.way(situation(front: true, focused: true, idle: 0.4)) == .wait, "never while the person types in that window")
        expect(Background.way(situation(front: true, focused: true, idle: 1.99)) == .wait, "within the two seconds")
        expect(Background.way(situation(front: true, focused: true, idle: 2)) == .foreground, "after a two-second pause")
        expect(Background.way(situation(front: true, focused: false, idle: 0)) == .background,
               "typing in another window of its app doesn't hold the note up")

        // MARK: Typing there now

        expect(Background.typingThere(situation(front: true, focused: true, idle: 0.5)), "a key half a second ago in that window")
        expect(!Background.typingThere(situation(front: false, focused: true, idle: 0)), "not when its app is behind")
        expect(!Background.typingThere(situation(front: true, focused: false, idle: 0)), "not when it's another window")
        expect(!Background.typingThere(situation(front: true, focused: true, idle: 5)), "not after a pause")
        expect(Background.patience > Background.pause, "it waits longer than a pause")

        // MARK: Right before each background change

        let away = situation(front: false)
        expect(Background.behind(away, plannedFront: false, changed: false) == .go, "still behind: it goes ahead")
        expect(Background.behind(situation(front: true, focused: false), plannedFront: true, changed: true) == .go,
               "the person still in another window of its app, as planned")
        let back = situation(front: true, focused: true, idle: 30)
        expect(Background.behind(back, plannedFront: false, changed: false) == .again,
               "the person came back to that window during the reads: decided again, by the foreground rules")
        expect(Background.behind(situation(front: true, focused: true, idle: 0.3), plannedFront: false, changed: false) == .again,
               "typing there now: decided again, which waits for a pause")
        expect(Background.behind(back, plannedFront: false, changed: true) == .stop,
               "after a change already made, it stops: never a change in the window they're now using")
        expect(Background.behind(back, plannedFront: true, changed: false) == .again,
               "from another window of its app to the note's: decided again")
        expect(Background.behind(situation(front: true, focused: false), plannedFront: false, changed: false) == .again,
               "its app came to the front (another window): keys and focus were planned for an app behind")
        expect(Background.behind(situation(front: true, focused: false), plannedFront: false, changed: true) == .stop,
               "and after a change, it stops there")
        for front in [false, true] {
            for focused in [false, true] {
                for idle in [0.1, 30.0] {
                    for changed in [false, true] {
                        let now = situation(front: front, focused: focused, idle: idle)
                        let behind = Background.behind(now, plannedFront: false, changed: changed)
                        expect(behind != .go || Background.way(now) == .background, "it only goes ahead the background way",
                               "\(now) \(behind)")
                        expect(behind != .go || !(front && focused), "never in the window in front", "\(now)")
                    }
                }
            }
        }

        // MARK: Each action in the background

        expect(plan("press") == .press, "a button is pressed through Accessibility")
        expect(plan("press", front: true, main: false) == .press, "pressing works even in the app the person uses")
        expect(plan("press", clipboard: true) == .needs(.clipboard), "a Copy button needs the window: it uses the person's clipboard")
        expect(plan("scroll", front: true) == .scroll, "scrolling never needs the window")
        expect(plan("focus") == .focus, "focus inside a background app")
        expect(plan("focus", front: true) == .needs(.focus), "never moves the cursor in the app the person uses")
        expect(plan("type", text: true) == .setValue(keysAfter: true), "a native field takes its value, keys if it doesn't stick")
        expect(plan("type", text: true, front: true) == .setValue(keysAfter: false), "in the app in front: the value only, never keys")
        expect(plan("type", text: true, web: true) == .keys, "a web page's field hears keys, posted to its app alone")
        expect(plan("type", text: true, web: true, front: true) == .setValue(keysAfter: false),
               "a web field in the app the person uses: its value, never keys")
        expect(plan("type", text: false) == .keys, "something that isn't a field gets keys, its app behind")
        expect(plan("type", text: false, front: true) == .needs(.keys), "and needs the window while the person uses its app")
        expect(plan("menu") == .menu, "a menu of a background app whose front window is the note's")
        expect(plan("menu", main: false) == .needs(.menu), "a menu would act on another of its windows")
        expect(plan("menu", front: true) == .needs(.menu), "a menu of the app the person uses acts on their window")
        expect(plan("menu", clipboard: true) == .needs(.clipboard), "Edit › Paste uses the clipboard")
        expect(plan("key", menuItem: true) == .menu, "a key its menus have is chosen there")
        expect(plan("key", menuItem: true, main: false) == .needs(.menu), "not on another of its windows")
        expect(plan("key") == .key, "a key to a named control, its app behind")
        expect(plan("key", element: false, main: false) == .needs(.keys), "no control named: only when the note's window has its keyboard")
        expect(plan("key", element: false, main: true) == .key, "the note's window has its app's keyboard")
        expect(plan("key", front: true) == .needs(.keys), "never keys to the app the person uses")
        expect(plan("key", clipboard: true) == .needs(.clipboard), "cmd-v uses the clipboard")
        expect(plan("fill") == .needs(.vault), "the vault fills only in front")
        expect(plan("fill", front: true, main: true) == .needs(.vault), "whatever else is true")
        expect(plan("swipe") == .needs(.keys), "an unknown action never goes quietly")
        expect(Background.returnGoes(appFront: false), "Return goes to a background app")
        expect(!Background.returnGoes(appFront: true), "but never to the app the person uses")
        expect(Background.pressUsesClipboard([UINode(role: "AXButton", title: "Quick paste")]),
               "a paste word in a button's name, with no clipboard identifier, uses the clipboard")
        expect(Background.pressUsesClipboard([UINode(role: "AXButton", label: "Click to copy API key")]), "so does a copy word")
        expect(Background.pressUsesClipboard([UINode(role: "AXButton", identifier: "paste:")]), "and the app's own name for Paste")
        expect(!Background.pressUsesClipboard([UINode(role: "AXButton", title: "Send")]), "an ordinary button doesn't")
        expect(plan("press", clipboard: Background.pressUsesClipboard([UINode(role: "AXButton", title: "Quick paste")])) == .needs(.clipboard),
               "so “Quick paste” needs the window in front")

        // MARK: Read again right before the pointer's change

        expect(Background.recheck(situation(front: true, focused: true, idle: 30)) == .go, "still in front, the person idle: it goes")
        expect(Background.recheck(situation(front: false, focused: false, idle: 0.2)) == .background,
               "the person switched apps during the glide: the background way, never brought forward")
        expect(Background.recheck(situation(front: true, focused: false, idle: 0.2)) == .background,
               "another window of its app came forward: the background way")
        expect(Background.recheck(situation(front: true, focused: true, idle: 0.3)) == .refuse, "the person typing there now: refused")
        expect(Background.recheck(nil) == .unsure, "couldn't tell: refused, never the background way")

        // MARK: Unknown is never behind

        expect(Background.situation(appFront: .unknown, windowFocused: .no, idle: 30) == nil, "the app in front unknown: no situation")
        expect(Background.situation(appFront: .yes, windowFocused: .unknown, idle: 30) == nil,
               "its app in front, its window unknown: no situation")
        expect(Background.situation(appFront: .no, windowFocused: .unknown, idle: 30) == situation(front: false, focused: false),
               "its app behind for certain: which window it focuses doesn't matter")
        expect(Background.situation(appFront: .yes, windowFocused: .no, idle: 30) == situation(front: true, focused: false),
               "the person in another window of its app, for certain")
        expect(Background.check(stopped: { false }, read: { nil }, plannedFront: false, changed: false) == .unsure,
               "the background gate: unknown refuses the change")
        expect(Background.check(stopped: { false }, read: { nil }, plannedFront: true, changed: true) == .unsure,
               "even after a change, as planned in front")
        expect(Background.check(stopped: { true }, read: { nil }, plannedFront: false, changed: false) == nil, "a Stop is still a Stop")
        expect(Background.check(stopped: { false }, note: { nil }) == .interrupted(.unsure), "a note in front: unknown stops it")
        expect(Background.check(stopped: { false }, note: { situation(front: true, focused: true, idle: 30) }) == .go,
               "a note in front, the person idle there: it goes")
        let unsureGate = Background.Gate { Background.check(stopped: { false }, note: { nil }) }
        expect(unsureGate.mutate({ 1 }) == nil && unsureGate.refused && unsureGate.interruption == .unsure, "the gate refuses on unknown")
        expect(Background.stopped(.unsure, app: "Mail", changed: false).contains("couldn't tell"), "and says Petal couldn't tell")
        expect(Background.interrupted(.unsure, app: "Mail", typed: "", of: "Hi").contains("couldn't tell"), "for typing too")

        // MARK: Putting back what jumped forward

        let base = Background.Baseline(front: 100, at: 50)
        expect(Background.restore(base, note: 200, frontNow: 200, lastInput: 40, changed: true, windowMoved: true) == .app(100),
               "the note's app jumped forward with no input since: the person's app goes back")
        expect(Background.restore(base, note: 200, frontNow: 200, lastInput: 55, changed: true, windowMoved: true) == .none,
               "the person pressed a key or clicked after the baseline: theirs to decide")
        expect(Background.restore(base, note: 200, frontNow: 200, lastInput: 50, changed: true, windowMoved: true) == .none, "input at the baseline itself counts")
        expect(Background.restore(base, note: 200, frontNow: 100, lastInput: 40, changed: true, windowMoved: true) == .none, "nothing jumped forward")
        expect(Background.restore(base, note: 200, frontNow: nil, lastInput: 40, changed: true, windowMoved: true) == .none, "the app in front unknown: nothing done")
        expect(Background.restore(Background.Baseline(front: 200, at: 50), note: 200, frontNow: 200, lastInput: 40, changed: true, windowMoved: true) == .window,
               "the person was using the note's app: only their window goes back")
        expect(Background.restore(Background.Baseline(front: nil, at: 50), note: 200, frontNow: 200, lastInput: 40, changed: true, windowMoved: true) == .none,
               "no app known in front then: nothing to put back")
        // A press that opened another app (a link in Safari, a file in Preview) is put back too, and the AI told.
        expect(Background.restore(base, note: 200, frontNow: 300, lastInput: 40, changed: true, windowMoved: true) == .app(100),
               "a press opened Safari over the person's app: their app goes back")
        expect(Background.opened(base, note: 200, frontNow: 300, lastInput: 40, changed: true), "and the AI hears something opened elsewhere")
        expect(Background.restore(Background.Baseline(front: 200, at: 50), note: 200, frontNow: 300, lastInput: 40, changed: true, windowMoved: true) == .app(200),
               "the person in the note's app, another app came forward: the note's app goes back")
        expect(Background.restore(base, note: 200, frontNow: 300, lastInput: 60, changed: true, windowMoved: true) == .none
               && !Background.opened(base, note: 200, frontNow: 300, lastInput: 60, changed: true),
               "the person switched apps themselves: nothing put back, nothing said opened")
        expect(!Background.opened(base, note: 200, frontNow: 200, lastInput: 40, changed: true), "the note's own app isn't another app")
        expect(!Background.opened(base, note: 200, frontNow: 100, lastInput: 40, changed: true), "the person's own app still in front")
        expect(!Background.opened(base, note: 200, frontNow: nil, lastInput: 40, changed: true), "unknown isn't opened")
        // Nothing changed (refused, or needed the window): nothing is put back, nor said opened, whatever moved.
        expect(Background.restore(base, note: 200, frontNow: 300, lastInput: 40, changed: false, windowMoved: true) == .none,
               "no change went through: an app the person launched before isn't undone")
        expect(Background.restore(Background.Baseline(front: 200, at: 50), note: 200, frontNow: 200, lastInput: 40, changed: false,
                                  windowMoved: true) == .none, "no change went through: no window put back")
        expect(!Background.opened(base, note: 200, frontNow: 300, lastInput: 40, changed: false), "and nothing said opened")
        // The person in the note's app: any other window that came over theirs (Mail's New Message opened from the
        // note's window) gives theirs back; their own window still focused, nothing.
        expect(Background.restore(Background.Baseline(front: 200, at: 50), note: 200, frontNow: 200, lastInput: 40, changed: true,
                                  windowMoved: true) == .window, "a new window of the same app over theirs: their window goes back")
        expect(Background.restore(Background.Baseline(front: 200, at: 50), note: 200, frontNow: 200, lastInput: 40, changed: true,
                                  windowMoved: false) == .none, "their window still focused: nothing put back")
        expect(Background.restore(Background.Baseline(front: 200, at: 50), note: 200, frontNow: 200, lastInput: 55, changed: true,
                                  windowMoved: true) == .none, "the person clicked since: theirs to decide")

        // Each change that puts something back has its own gate, read again right before it.
        func seen(stopped: Bool = false, input: TimeInterval = 40, front: pid_t? = 200, window: Bool = true) -> Background.PutBack {
            Background.PutBack(stopped: stopped, lastInput: input, frontNow: front, windowExpected: window)
        }
        expect(Background.putBack(seen(), baseline: base, jumped: 200), "nothing moved since: put back")
        expect(!Background.putBack(seen(input: 55), baseline: base, jumped: 200), "a key or click of the person's since: left alone")
        expect(!Background.putBack(seen(front: 100), baseline: base, jumped: 200),
               "the person switched back themselves meanwhile: nothing activated over their choice")
        expect(!Background.putBack(seen(front: 300), baseline: base, jumped: 200), "another app in front now: left alone")
        expect(!Background.putBack(seen(front: nil), baseline: base, jumped: 200), "the app in front unknown: left alone")
        expect(!Background.putBack(seen(window: false), baseline: base, jumped: 200),
               "another window of that app picked meanwhile: the old one isn't promoted again")
        expect(!Background.putBack(seen(stopped: true), baseline: base, jumped: 200), "a Stop ends the putting back")
        // Its order: what's in front read, then the person's last input, then the Stop last; a Stop or a click during
        // the reads is heard.
        var putTrace: [String] = []
        var putStop = false
        let goes = Background.putBackGoes(baseline: base, jumped: 200,
                                          stopped: { putTrace.append("stop?"); return putStop },
                                          read: { putTrace.append("front"); putStop = true; return (200, true) },
                                          lastInput: { putTrace.append("input"); return 40 })
        expect(!goes, "stopped while reading what's in front: nothing put back")
        expect(putTrace == ["stop?", "front", "input", "stop?"], "the Stop sampled after every read", "\(putTrace)")
        var clicked: TimeInterval = 40
        expect(!Background.putBackGoes(baseline: base, jumped: 200, stopped: { false },
                                       read: { clicked = 60; return (200, true) }, lastInput: { clicked }),
               "the person clicked while it read: their input is read after, and counts")
        var readFront = false
        expect(!Background.putBackGoes(baseline: base, jumped: 200, stopped: { true },
                                       read: { readFront = true; return (200, true) }, lastInput: { 40 }) && !readFront,
               "already stopped: nothing read")
        expect(Background.putBackGoes(baseline: base, jumped: 200, stopped: { false }, read: { (200, true) }, lastInput: { 40 }),
               "nothing moved: it goes")

        // MARK: Presses that open another app

        expect(!Background.pressOpens(role: "AXLink", url: "https://example.com/a", browser: true), "a web link in a browser opens there")
        expect(!Background.pressOpens(role: "AXLink", url: "HTTP://example.com", browser: true), "any case of http")
        expect(Background.pressOpens(role: "AXLink", url: "https://example.com", browser: false),
               "a web link in Slack opens the default browser: refused")
        expect(Background.pressOpens(role: "AXLink", url: "mailto:a@b.c", browser: true), "mailto: opens Mail")
        expect(Background.pressOpens(role: "AXLink", url: "zoommtg://join?x=1", browser: true), "an app's own scheme")
        expect(Background.pressOpens(role: "AXLink", url: nil, browser: true), "a link with no address: can't tell, refused")
        expect(Background.pressOpens(role: "AXLink", url: "  ", browser: true), "nor a blank one")
        expect(Background.pressOpens(role: "AXRow", url: "file:///Users/me/a.pdf", browser: false), "a file in Finder opens in its app")
        expect(Background.pressOpens(role: "AXImage", url: "file:///Applications/Notes.app", browser: false), "an app in Finder")
        expect(!Background.pressOpens(role: "AXButton", url: nil, browser: false), "an ordinary button isn't refused")
        expect(!Background.pressOpens(role: "AXRow", url: nil, browser: false), "nor a row with no address")
        expect(!Background.pressOpens(role: "AXButton", url: "https://example.com", browser: true), "a web button in a browser")
        expect(Background.pressAction(["AXShowMenu", "AXPress"]) == "AXPress", "pressed with AXPress")
        expect(Background.pressAction(["AXPick", "AXOpen"]) == "AXPick", "AXPick before AXOpen")
        expect(Background.pressAction(["AXOpen"]) == nil, "never AXOpen in the background")
        expect(Background.pressAction([]) == nil, "nothing to press")

        // MARK: A note typing in its window in front, interrupted

        expect(Background.interrupt(situation(front: true, focused: true, idle: 30)) == nil, "the person still idle there: carry on")
        expect(Background.interrupt(situation(front: true, focused: true, idle: 0.2)) == .typing, "they typed there again: stop")
        expect(Background.interrupt(situation(front: true, focused: true, idle: 1.9)) == .typing, "within the pause")
        expect(Background.interrupt(situation(front: false, focused: false, idle: 0.1)) == .left, "they went to another app: stop")
        expect(Background.interrupt(situation(front: true, focused: false, idle: 30)) == .left, "another of its windows came forward")
        expect(Background.interrupt(situation(note: false, front: true, focused: true, idle: 0)) == nil,
               "Petal AI's plain chat is never interrupted this way (it has Escape)")
        let partWay = Background.interrupted(.typing, app: "Slack", typed: "Hello th", of: "Hello there")
        expect(partWay.contains("started typing") && partWay.contains("“Hello th”") && partWay.contains("Return wasn't pressed")
               && partWay.contains("Don't type it again"), "part way: what went, no Return, not again", partWay)
        let none = Background.interrupted(.left, app: "Slack", typed: "", of: "Hello")
        expect(none.contains("moved away") && none.contains("before typing anything"), "nothing typed yet", none)
        let all = Background.interrupted(.typing, app: "Slack", typed: "Hello", of: "Hello")
        expect(all.contains("all of it") && all.contains("Return wasn't pressed"), "all typed, Return held back", all)
        let fillPart = Background.fillInterrupted(.typing, app: "Safari", typed: true)
        expect(fillPart.contains("part way") && fillPart.contains("Return wasn't pressed"), "a fill stopped part way says so", fillPart)
        expect(Background.fillInterrupted(.left, app: "Safari", typed: false).contains("before filling anything"), "a fill stopped before any key")
        expect(Background.stopped(.typing, app: "Slack", changed: false) == Background.busyThere("Slack"), "typing there before anything: nothing done")
        expect(Background.stopped(.left, app: "Slack", changed: true).contains("part way"), "left after a change: part way")

        // MARK: Guard, then change

        expect(Background.verdict(stopped: true, note: situation(front: true, focused: true, idle: 30)) == .no, "a Stop refuses")
        expect(Background.verdict(stopped: false, note: nil) == .go, "Petal AI's plain chat: only its Stop")
        expect(Background.verdict(stopped: false, note: situation(front: true, focused: true, idle: 30)) == .go, "a note, the person idle there")
        expect(Background.verdict(stopped: false, note: situation(front: true, focused: true, idle: 0.3)) == .interrupted(.typing),
               "a note, the person typing there again")
        expect(Background.verdict(stopped: false, note: situation(front: false)) == .interrupted(.left), "a note, the person gone elsewhere")

        // The gate's order: the situation read first (Accessibility, which can block), the Stop sampled last. A Stop
        // (or the app made private) that comes during the read refuses, never a stale go.
        var cancelled = false
        var gateTrace: [String] = []
        let flipped = Background.check(stopped: { gateTrace.append("stop?"); return cancelled },
                                       read: { gateTrace.append("read"); cancelled = true; return situation(front: true, focused: true, idle: 30) })
        expect(flipped == .no, "stopped during the read: refused", "\(flipped)")
        expect(gateTrace == ["stop?", "read", "stop?"], "the Stop sampled again after the read", "\(gateTrace)")
        cancelled = false
        let plain = Background.check(stopped: { cancelled }, read: { cancelled = true; return nil })
        expect(plain == .no, "Petal AI's plain chat: stopped while its gate ran: refused")
        var read = false
        expect(Background.check(stopped: { true }, read: { read = true; return nil }) == .no && !read, "already stopped: nothing read")
        expect(Background.check(stopped: { false }, read: { situation(front: true, focused: true, idle: 30) }) == .go,
               "nothing stopped, the person idle there: go")
        expect(Background.check(stopped: { false }, read: { situation(front: true, focused: true, idle: 0.2) }) == .interrupted(.typing),
               "the person typing there: interrupted")
        // The background way's gate: the same order.
        cancelled = false
        let behindFlipped = Background.check(stopped: { cancelled }, read: { cancelled = true; return situation() },
                                             plannedFront: false, changed: false)
        expect(behindFlipped == nil, "a background change stopped during its read: refused")
        expect(Background.check(stopped: { false }, read: { situation() }, plannedFront: false, changed: false) == .go,
               "a background change, nothing stopped: go")
        expect(Background.check(stopped: { false }, read: { situation(front: true, focused: true) }, plannedFront: false, changed: true) == .stop,
               "the person back after a change: stop")

        // Every change comes right after its guard: a trace of the reads, the guard and the changes, with stubs. The
        // guard is the person (scripted: they come back at the third guard).
        var trace: [String] = []
        var answers: [Background.Verdict] = [.go, .go, .interrupted(.typing), .go]
        let gate = Background.Gate {
            trace.append("guard")
            return answers.isEmpty ? .go : answers.removeFirst()
        }
        // A helper's shape (insert, focus): its reads first, then the gate and the change together.
        trace.append("read value"); trace.append("read selection")
        let set = gate.mutate { trace.append("set"); return true }
        expect(set == true && gate.changed && !gate.refused, "the guard said go: the change was made")
        // Keys in batches: each batch's reads (the keyboard still in the field), then the guard, then the batch.
        let sentAll = Background.send(["He", "ll", "o"], still: { trace.append("read keyboard"); return true }, gate: gate) {
            trace.append("keys \($0)")
        }
        expect(!sentAll, "the person came back at the second batch: it stops there")
        expect(gate.refused && gate.interruption == .typing, "and the gate says why")
        expect(trace == ["read value", "read selection", "guard", "set", "read keyboard", "guard", "keys He",
                         "read keyboard", "guard"], "nothing read between a guard and its change; nothing after a refusal", "\(trace)")
        // Return after an interruption: the focus read, then the guard, which refuses: no Return.
        var returned = false
        let refusing = Background.Gate { .interrupted(.left) }
        refusing.mutate { returned = true }
        expect(!returned && refusing.refused && !refusing.changed && refusing.interruption == .left, "no Return once the person left")
        // Every change after a guard: no change without its guard immediately before it.
        let pairs = zip(trace.dropFirst(), trace).filter { $0.0 == "set" || $0.0.hasPrefix("keys") }
        expect(pairs.allSatisfy { $0.1 == "guard" }, "each change's step before it is its guard")
        // A read that fails stops it before any guard or change.
        var onlyReads: [String] = []
        let quiet = Background.Gate { onlyReads.append("guard"); return .go }
        let none2 = Background.send([1, 2], still: { onlyReads.append("read"); return false }, gate: quiet) { onlyReads.append("keys \($0)") }
        expect(!none2 && onlyReads == ["read"] && !quiet.changed, "the cursor left: no guard, no keys", "\(onlyReads)")
        let stopped = Background.Gate { .no }
        expect(stopped.mutate({ 1 }) == nil && stopped.refused && stopped.interruption == nil, "a Stop refuses with no interruption")

        // MARK: Typed in the background, read back

        expect(Background.typed(before: "Send the invoice today", after: "Send the invoice today", text: "Send the invoice",
                                replace: true) == .ignored,
               "replacing: the old text merely holding the new one is not done")
        expect(Background.typed(before: "Send the invoice today", after: "Send the invoice", text: "Send the invoice", replace: true) == .done,
               "replacing: exactly the text")
        expect(Background.typed(before: "old", after: "Send the invoice\n", text: "Send the invoice", replace: true) == .done,
               "a trailing newline the field adds")
        expect(Background.typed(before: "old", after: "oldSend the invoice", text: "Send the invoice", replace: true) == .uncertain,
               "replacing: appended instead of replaced is not done")
        expect(Background.typed(before: "Send", after: "Send", text: "Send", replace: true) == .done, "already just that")
        expect(Background.typed(before: "Hi ", after: "Hi there", text: "there", replace: false, at: 3) == .done, "inserted at the cursor")
        expect(Background.typed(before: "Hi ", after: "Hi ", text: "there", replace: false, at: 3) == .ignored, "nothing changed")
        expect(Background.typed(before: "there Hi ", after: "there Hi ", text: "there", replace: false, at: 9) == .ignored,
               "the old text holding the words already isn't done")
        expect(Background.typed(before: "Hi ", after: "thereHi ", text: "there", replace: false, at: 3) == .uncertain,
               "in the wrong place")
        expect(Background.typed(before: "Hi ", after: "Hi therethere", text: "there", replace: false, at: 3) == .uncertain,
               "typed twice")
        expect(Background.typed(before: "Hi xx", after: "Hi there", text: "there", replace: false, at: 3, replaced: 2) == .done,
               "over a selection")
        expect(Background.typed(before: "Hi ", after: "Hi there", text: "there", replace: false) == .done, "cursor unknown: grew by just it")
        expect(Background.typed(before: "Hi ", after: "Hi the", text: "there", replace: false) == .uncertain, "cut short")
        expect(Background.typed(before: "abc", after: "xyzabc", text: "xyz", replace: false, at: 10) == .uncertain, "a cursor past the end")
        expect(Background.typed(before: "Hello world", after: "Hello brave EARTH", text: "brave ", replace: false, at: 6) == .uncertain,
               "inserted, but what followed changed: not done")
        expect(Background.typed(before: "Hello world", after: "Hello brave world", text: "brave ", replace: false, at: 6) == .done,
               "inserted, with what followed as it was")
        expect(Background.typed(before: "Hello big world", after: "Hello brave EARTH", text: "brave", replace: false, at: 6, replaced: 3)
               == .uncertain, "over a selection, what followed it changed")
        expect(Background.typed(before: "Hello big world", after: "Hello brave world", text: "brave", replace: false, at: 6, replaced: 3)
               == .done, "over a selection, what followed it kept")
        expect(Background.typed(before: "ab", after: "abxy", text: "xy", replace: false, at: 1, replaced: 2) == .uncertain,
               "a selection past the end")

        // MARK: Menu items and keys that open things

        for title in ["Open…", "Open...", "File > Open", "Open With", "Open in Terminal", "Open Recent", "Open Link in New Tab",
                      "Show in Finder", "Reveal in Finder", "Reveal", "New Window", "New Tab", "New Private Window",
                      "Aç…", "Birlikte Aç", "Bağlantıyı Yeni Sekmede Aç", "Finder'da Göster", "Yeni Pencere", "Yeni Sekme", "YENİ SEKME"] {
            expect(Background.menuOpens(title: title), "“\(title)” opens something: refused in the background")
        }
        for title in ["Save", "Reopen Closed Tab", "Show Sidebar", "New Folder", "Close Window", "Kaydet", "Kenar Çubuğunu Göster",
                      "Openness", "Format › Font › Bold"] {
            expect(!Background.menuOpens(title: title), "“\(title)” goes ahead")
        }
        expect(Background.menuOpens(title: "Ouvrir…", character: "O", modifiers: 0), "⌘O in any language")
        expect(Background.menuOpens(title: "Ouvrir…", character: "o", modifiers: 1), "⇧⌘O too")
        expect(!Background.menuOpens(title: "Ouvrir…", character: "O", modifiers: 8), "O with no ⌘ isn't")
        expect(!Background.menuOpens(title: nil, character: "S", modifiers: 0), "⌘S isn't")
        if let cmdO = UIMap.parseKey("cmd-o"), let cmdDown = UIMap.parseKey("cmd-down"), let down = UIMap.parseKey("down"),
           let cmdS = UIMap.parseKey("cmd-s") {
            expect(Background.keyOpens(cmdO, finder: false), "⌘O anywhere")
            expect(Background.keyOpens(cmdDown, finder: true), "⌘↓ in Finder")
            expect(!Background.keyOpens(cmdDown, finder: false), "⌘↓ elsewhere moves to the end")
            expect(!Background.keyOpens(down, finder: true), "↓ alone in Finder only moves the selection")
            expect(!Background.keyOpens(cmdS, finder: true), "⌘S isn't")
        } else {
            expect(false, "keys parse")
        }
        expect(plan("menu", opens: true) == .needs(.opens), "a menu item that opens: the window in front")
        expect(plan("key", menuItem: true, opens: true) == .needs(.opens), "its key too")
        expect(plan("key", opens: true) == .needs(.opens), "a key that opens, with no menu item")
        expect(plan("menu", clipboard: true, opens: true) == .needs(.clipboard), "the clipboard still said first")
        expect(plan("menu") == .menu && plan("key") == .key, "others still go")

        // MARK: The preview's pictures

        let isPrivate = { (app: String) in app == "com.secret.app" }
        expect(NotePicture.hidden(app: "com.secret.app", private: isPrivate), "a private app's note")
        expect(!NotePicture.hidden(app: "com.apple.Safari", private: isPrivate), "an ordinary app's")
        expect(!NotePicture.hidden(app: nil, private: isPrivate) && !NotePicture.hidden(app: "", private: isPrivate), "a chat stuck to nothing")
        let shown = NotePicture.Seen(app: "com.apple.Safari", attached: true, pid: 7, window: 42, hidden: false)
        var closed = shown; closed.attached = false
        var secret = NotePicture.Seen(app: "com.secret.app", attached: false, pid: 0, window: nil,
                                      hidden: NotePicture.hidden(app: "com.secret.app", private: isPrivate))
        expect(secret.hidden, "a private app's note stays private after its window closed")
        expect(!NotePicture.shows(secret), "and has no picture")
        secret.attached = true
        expect(!NotePicture.shows(secret), "nor while attached")
        expect(NotePicture.shows(shown) && !NotePicture.shows(closed), "a picture only while its window is there")
        expect(NotePicture.keeps(taken: shown, now: shown), "a capture of the same window is kept")
        var moved = shown; moved.window = 43
        expect(!NotePicture.keeps(taken: shown, now: moved), "not once the note has another window")
        expect(!NotePicture.keeps(taken: shown, now: closed), "nor once its window closed")
        var madePrivate = shown; madePrivate.hidden = true
        expect(!NotePicture.keeps(taken: shown, now: madePrivate), "nor once its app was made private")
        expect(!NotePicture.keeps(taken: shown, now: nil), "nor once the note is gone")

        // Which window a picture is of, and which pictures are kept.
        let windows = [NotePicture.Shot(pid: 7, window: 40), NotePicture.Shot(pid: 7, window: 42), NotePicture.Shot(pid: 9, window: 44)]
        expect(NotePicture.pick(shown, from: windows) == NotePicture.Shot(pid: 7, window: 42), "a window's note: that very window")
        expect(NotePicture.pick(shown, from: windows.filter { $0.window != 42 }) == nil,
               "its window gone from the list: no picture, never another of its app's")
        expect(NotePicture.pick(shown, from: [NotePicture.Shot(pid: 9, window: 42)]) == nil, "the same number in another process isn't it")
        var appWide = shown; appWide.appWide = true
        expect(NotePicture.pick(appWide, from: windows) == NotePicture.Shot(pid: 7, window: 42), "an app's note: the window it names first")
        expect(NotePicture.pick(appWide, from: windows.filter { $0.window != 42 }) == NotePicture.Shot(pid: 7, window: 40),
               "else any of its app's windows")
        expect(NotePicture.pick(appWide, from: windows.filter { $0.window != 42 }, ordinary: { $0.window != 40 }) == nil,
               "the fallback is only an ordinary window of its own app")
        var unnamed = appWide; unnamed.window = nil
        expect(NotePicture.pick(unnamed, from: windows) == NotePicture.Shot(pid: 7, window: 40), "an app's note naming no window")
        expect(NotePicture.pick(closed, from: windows) == nil && NotePicture.pick(madePrivate, from: windows) == nil,
               "no picture of a closed or private note's window")
        expect(NotePicture.accepts(NotePicture.Shot(pid: 7, window: 42), taken: shown, now: shown), "its own window's picture is kept")
        expect(!NotePicture.accepts(NotePicture.Shot(pid: 7, window: 40), taken: shown, now: shown),
               "another window of its app, for a window's note, never is")
        expect(!NotePicture.accepts(NotePicture.Shot(pid: 9, window: 42), taken: shown, now: shown), "nor its number in another process")
        expect(NotePicture.accepts(NotePicture.Shot(pid: 7, window: 40), taken: appWide, now: appWide),
               "an app's note: another of its app's windows is")
        expect(!NotePicture.accepts(NotePicture.Shot(pid: 9, window: 44), taken: appWide, now: appWide), "never another app's")
        expect(!NotePicture.accepts(NotePicture.Shot(pid: 7, window: 42), taken: shown, now: appWide),
               "nor once the note was stuck to all of its app instead")
        expect(!NotePicture.accepts(NotePicture.Shot(pid: 7, window: 42), taken: shown, now: madePrivate), "nor once made private")

        // A kept picture shows only while the note still has the window it was taken of.
        let kept = NotePicture.Kept(seen: shown, image: "window 42")
        expect(NotePicture.current(kept, now: shown) == "window 42", "the same window: its picture shows")
        expect(NotePicture.current(kept, now: moved) == nil, "the note moved to another window: the old picture never shows")
        var otherApp = shown; otherApp.pid = 9; otherApp.app = "com.google.Chrome"
        expect(NotePicture.current(kept, now: otherApp) == nil, "nor once it's in another app")
        expect(NotePicture.current(kept, now: appWide) == nil, "nor once it's stuck to all of the app")
        expect(NotePicture.current(kept, now: closed) == nil && NotePicture.current(kept, now: madePrivate) == nil,
               "nor once its window closed or its app was made private")
        expect(NotePicture.current(NotePicture.Kept<String>?.none, now: shown) == nil, "no picture kept")
        let keptWide = NotePicture.Kept(seen: appWide, image: "any of Safari's")
        expect(NotePicture.current(keptWide, now: appWide) == "any of Safari's", "an app's note keeps its app's picture")

        // MARK: What's said

        expect(Background.Reason.opens.words("Slack").contains("another app"), "opening elsewhere says so")
        for reason in Background.Reason.allCases {
            let words = reason.words("T3 Code")
            expect(words.contains("Nothing was done"), "\(reason) says nothing was done")
            expect(words.contains("click that window") || reason == .tab && words.contains("switch back"), "\(reason) says how the person brings it forward")
            expect(reason == .tab ? reason.status == "needs its tab showing" : reason.status.hasPrefix("needs the window in front"),
                   "\(reason)'s line", reason.status)
        }

        // MARK: The preview's lines

        let working = NoteStatus.Facts(running: true, activity: "Typing in “Prompt”")
        expect(NoteStatus.line(working) == "Typing in “Prompt”…", "a step, with an ellipsis", NoteStatus.line(working))
        expect(NoteStatus.line(NoteStatus.Facts(running: true, activity: "Running  git   status")) == "Running git status…", "spaces tidied")
        expect(NoteStatus.line(NoteStatus.Facts(running: true)) == "Working…", "a step not said yet")
        expect(NoteStatus.line(NoteStatus.Facts(running: true, activity: "Planning…")) == "Planning…", "no second ellipsis")
        expect(NoteStatus.step(String(repeating: "a", count: 90)).count == 60, "a long step is cut short")
        let needs = NoteStatus.Facts(running: true, needs: Background.Reason.menu.status, activity: "Choosing File › Export")
        expect(NoteStatus.line(needs) == "Waiting for you: needs the window in front to choose from its menus", "waiting beats working",
               NoteStatus.line(needs))
        let asking = NoteStatus.Facts(running: true, asking: "Let Petal AI use T3 Code?")
        expect(NoteStatus.line(asking) == "Waiting for you: Let Petal AI use T3 Code?", "its Allow card")
        expect(NoteStatus.line(NoteStatus.Facts(ready: true)) == "Done", "done while away")
        expect(NoteStatus.line(NoteStatus.Facts()) == "", "an idle note says nothing")
        expect(!NoteStatus.shows(NoteStatus.Facts()), "an idle, seen note isn't in the preview")
        expect(NoteStatus.shows(NoteStatus.Facts(ready: true)), "done and not seen is")
        expect(NoteStatus.shows(NoteStatus.Facts(needs: "x")), "waiting for the person after its turn ended is")
        expect(NoteStatus.needsYou(asking) && NoteStatus.needsYou(needs) && !NoteStatus.needsYou(working), "who badges the AI button")
        let order = NoteStatus.order([NoteStatus.Facts(ready: true), working, NoteStatus.Facts(), needs, NoteStatus.Facts(running: true)])
        expect(order == [3, 1, 4, 0], "waiting first, then working, then done; the idle one left out", "\(order)")

        // Four working and two waiting for room (queued: `running`), one done: every one shows, none dropped, and
        // the preview scrolls sideways for them; each that works or waits has its Stop (`running`).
        let queued = NoteStatus.Facts(running: true, activity: "Waiting for another note to finish")
        let crowd = Array(repeating: working, count: 4) + [queued, queued, NoteStatus.Facts(ready: true), NoteStatus.Facts()]
        let shownNotes = NoteStatus.order(crowd)
        expect(shownNotes.count == 7 && Set(shownNotes) == Set(0..<7), "every note at work, queued or done shows", "\(shownNotes)")
        expect(shownNotes.filter { crowd[$0].running }.count == 6, "both queued notes keep a Stop in the preview")
        expect(NoteStatus.previewScrolls(shownNotes.count), "more than fit: the preview scrolls")
        expect(!NoteStatus.previewScrolls(NoteStatus.tilesInView), "as many as fit: side by side")

        // MARK: A window on the run's own hidden display

        var hiddenFront = situation(front: true, focused: true, idle: 30)
        hiddenFront.hidden = true
        expect(Background.way(hiddenFront) == .background, "on its own display: the background way, even when that window is its app's front one")
        var hiddenTyping = situation(front: true, focused: true, idle: 0)
        hiddenTyping.hidden = true
        expect(Background.way(hiddenTyping) == .background, "never a wait for the person's typing: they can't be typing there on purpose")
        var hiddenBehind = situation()
        hiddenBehind.hidden = true
        expect(Background.way(hiddenBehind) == .background, "and with its app behind, as any note")
        expect(Background.behind(hiddenFront, plannedFront: true, changed: false) == .go, "a change planned with its app in front still goes")
        expect(Background.behind(hiddenFront, plannedFront: false, changed: false) == .again, "its app come to the front since it was planned: decided again")
        expect(Background.situation(appFront: .yes, windowFocused: .yes, idle: 9, hidden: true)?.hidden == true, "the situation carries it")
        expect(Background.situation(appFront: .no, windowFocused: .no, idle: 9, hidden: true)?.hidden == true, "behind too")
        expect(Background.situation(appFront: .unknown, windowFocused: .no, idle: 9, hidden: true) == nil, "unknown is still unknown")
        expect(Background.situation(appFront: .yes, windowFocused: .yes, idle: 9)?.hidden == false, "a note's own window on the person's screen isn't hidden")
        // Keys and menus keep to their rule there: only while the person isn't using that app.
        expect(plan("key", element: false, front: true, main: true) == .needs(.keys), "keys never reach it while the person uses that app")
        expect(plan("type", text: true, front: true) == .setValue(keysAfter: false), "a field's own value still goes")
        for reason in Background.Reason.allCases {
            let told = reason.words("Safari", hidden: true)
            expect(told.contains("your own display") && told.contains("Show me") && !told.contains("bring the window forward"),
                   "on its own display, \(reason) says Show me, never bring it forward", told)
            expect(told.contains("Nothing was done"), "\(reason): nothing was done")
        }
        expect(Background.Reason.keys.words("Safari").contains("click that window"), "a note on the person's screen still asks for the window")

        // MARK: Waiting for a display

        let waitingDisplay = NoteStatus.Facts(running: true, activity: "Opening Safari", waitingForDisplay: true)
        expect(NoteStatus.line(waitingDisplay) == "Waiting for a display", "its turn for a display hasn't come", NoteStatus.line(waitingDisplay))
        expect(NoteStatus.shows(waitingDisplay) && !NoteStatus.needsYou(waitingDisplay), "it shows, and isn't waiting for the person")
        expect(NoteStatus.line(NoteStatus.Facts(running: true, asking: "Let Petal AI use Safari?", waitingForDisplay: true)) == "Waiting for you: Let Petal AI use Safari?",
               "a question for the person comes first")
        expect(NoteStatus.shows(NoteStatus.Facts(waitingForDisplay: true)), "it shows even between turns")

        // MARK: Waiting for an app

        let waitingApp = NoteStatus.Facts(running: true, activity: "Opening a file", waitingForApp: "TextEdit")
        expect(NoteStatus.line(waitingApp) == "Waiting for TextEdit", "its turn for an app hasn't come", NoteStatus.line(waitingApp))
        expect(NoteStatus.waiting(for: "") == "Waiting for an app", "an app with no name")
        expect(NoteStatus.line(NoteStatus.Facts(running: true, waitingForDisplay: true, waitingForApp: "TextEdit")) == "Waiting for a display",
               "waiting for a display comes first: without one it can't use the app either")
        expect(NoteStatus.line(NoteStatus.Facts(running: true, asking: "Let Petal AI use TextEdit?", waitingForApp: "TextEdit")) == "Waiting for you: Let Petal AI use TextEdit?",
               "a question for the person still comes before it")
        expect(NoteStatus.shows(NoteStatus.Facts(waitingForApp: "TextEdit")), "it shows even between turns")
        expect(!NoteStatus.needsYou(waitingApp), "waiting for an app isn't waiting for the person: no mark on the AI button")
        expect(NoteStatus.line(NoteStatus.Facts(running: true, activity: "Reading")) == "Reading…", "with nothing to wait for, its step as before")

        // MARK: The person's own use of an app wins

        typealias First = Background.PersonFirst
        expect(Background.personFirst(.keys, hidden: true, untouched: true, appFront: .yes, waited: 0) == First.wait,
               "keys needed in the app the person is using: the run waits for them")
        expect(Background.personFirst(.focus, hidden: true, untouched: true, appFront: .yes, waited: 30) == First.wait, "so does moving the cursor there")
        expect(Background.personFirst(.menu, hidden: true, untouched: true, appFront: .yes, waited: 30) == First.wait, "and a menu")
        expect(Background.personFirst(.keys, hidden: true, untouched: true, appFront: .yes, waited: Background.personPatience) == First.tell,
               "past its patience the AI is told instead")
        expect(Background.personFirst(.keys, hidden: true, untouched: true, appFront: .no, waited: 0) == First.tell,
               "the person isn't in that app: waiting wouldn't help")
        expect(Background.personFirst(.keys, hidden: true, untouched: true, appFront: .unknown, waited: 0) == First.tell, "Petal couldn't tell: never a wait on a guess")
        expect(Background.personFirst(.keys, hidden: true, untouched: false, appFront: .yes, waited: 0) == First.tell,
               "something of the act was already tried: it isn't done over")
        expect(Background.personFirst(.keys, hidden: false, untouched: true, appFront: .yes, waited: 0) == First.tell,
               "a note on the person's own window asks them to bring it forward, as before")
        for reason in Background.Reason.allCases where ![.keys, .focus, .menu].contains(reason) {
            expect(Background.personFirst(reason, hidden: true, untouched: true, appFront: .yes, waited: 0) == First.tell,
                   "\(reason.rawValue) doesn't get better when the person leaves: told at once")
        }
        expect(Background.personStill(appFront: true, waited: 5) == First.wait, "still in that app: it goes on waiting")
        expect(Background.personStill(appFront: false, waited: 5) == First.retry, "they left it: the act is tried again")
        expect(Background.personStill(appFront: false, waited: Background.personPatience + 1) == First.retry, "even at the last moment")
        expect(Background.personStill(appFront: true, waited: Background.personPatience) == First.tell, "still there past its patience: told")

        print("Background: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
