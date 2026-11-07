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
                     element: Bool = true, front: Bool = false, main: Bool = true) -> Background.Step {
        Background.plan(Background.Target(action: action, text: text, web: web, clipboard: clipboard, menuItem: menuItem,
                                          element: element, appFront: front, windowMain: main))
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

        // MARK: Putting back what jumped forward

        let base = Background.Baseline(front: 100, at: 50)
        expect(Background.restore(base, note: 200, noteFrontNow: true, lastInput: 40) == .app(100),
               "the note's app jumped forward with no input since: the person's app goes back")
        expect(Background.restore(base, note: 200, noteFrontNow: true, lastInput: 55) == .none,
               "the person pressed a key or clicked after the baseline: theirs to decide")
        expect(Background.restore(base, note: 200, noteFrontNow: true, lastInput: 50) == .none, "input at the baseline itself counts")
        expect(Background.restore(base, note: 200, noteFrontNow: false, lastInput: 40) == .none, "nothing jumped forward")
        expect(Background.restore(Background.Baseline(front: 200, at: 50), note: 200, noteFrontNow: true, lastInput: 40) == .window,
               "the person was using the note's app: only their window goes back")
        expect(Background.restore(Background.Baseline(front: nil, at: 50), note: 200, noteFrontNow: true, lastInput: 40) == .none,
               "no app known in front then: nothing to put back")

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

        // MARK: What's said

        for reason in Background.Reason.allCases {
            let words = reason.words("T3 Code")
            expect(words.contains("Nothing was done"), "\(reason) says nothing was done")
            expect(words.contains("preview"), "\(reason) says how the person brings it forward")
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

        print("Background: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
