import AppKit
import ApplicationServices
import ScreenCaptureKit

/// `Petal --display-check <folder>`: the one check that makes a real hidden display (RunDisplay.swift), for whoever
/// is at the Mac to run on purpose. It changes the screens' arrangement for a few seconds: never run by a check, a
/// bench, a snapshot or an agent working alone.
///
/// It makes one display, places it at a corner of the person's screens, opens a throwaway text file in TextEdit
/// without activating it, moves that window onto the display and sets its text, all through Accessibility alone (no
/// AppleScript, no System Events), writes a PNG of the display into the folder, shows that the app and window the
/// person had in front, their pointer and their screens didn't change, then closes the window and removes the
/// display. One line per step, "ok" or "FAIL" with what was read, so a failure says exactly what went wrong; the
/// exit code is the number of failures (0: all passed). Indented lines are what it read along the way, never a
/// verdict: each place tried with what macOS answered to each of the three calls, how long making, placing and
/// removing took, and what AppKit and `CGDisplayIsOnline` say (neither is relied on: a process with no app of its own
/// isn't told of new screens, and `CGDisplayIsOnline` goes on saying yes for a display that's gone).
///
/// `--full` (`runFull`) goes through all of it with the controller Petal itself uses: three runs, two displays, two
/// apps, turns on an app, what a run leaves, Show me. The same warning: only on purpose, by whoever is at the Mac.
@MainActor
enum DisplayCheck {
    private static var failures = 0
    private static var passes = 0

    private static func step(_ ok: Bool, _ what: String, _ detail: String = "") {
        print((ok ? "ok    " : "FAIL  ") + what + (detail.isEmpty ? "" : "  [" + detail + "]"))
        if ok { passes += 1 } else { failures += 1 }
    }

    private static func say(_ text: String) { print("      " + text) }

    @discardableResult
    private static func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return done()
    }

    private static func describe(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))"
    }

    /// The app in front and its focused window's number, as the person has them.
    private static func front() -> (pid: pid_t, name: String, window: CGWindowID?) {
        let running = NSWorkspace.shared.frontmostApplication
        let pid = running?.processIdentifier ?? 0
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let window: AXUIElement? = Windows.value(app, kAXFocusedWindowAttribute)
        return (pid, running?.localizedName ?? "nothing", window.flatMap { Windows.id(of: $0) })
    }

    /// Where the pointer is, in the window server's coordinates (as displays' bounds are).
    private static func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private static func seconds(_ time: TimeInterval) -> String { String(format: "%.2f s", time) }

    /// The first text area in a window, a few levels down.
    private static func textArea(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if (Windows.value(element, kAXRoleAttribute) as String?) == (kAXTextAreaRole as String) { return element }
        guard depth < 8 else { return nil }
        let children: [AXUIElement] = Windows.value(element, kAXChildrenAttribute) ?? []
        for child in children {
            if let found = textArea(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    static func run(folder path: String, full: Bool = false) -> Never {
        if full { runFull(folder: path) }
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        print("Petal display check, macOS \(version). This makes a real display for a few seconds.")

        // 1. What it needs.
        step(VirtualDisplay.available, "macOS has the classes Petal makes a display with",
             VirtualDisplay.available ? "" : "missing: " + VirtualDisplay.missing.joined(separator: ", "))
        let trusted = AXIsProcessTrusted()
        step(trusted, "this Petal may use Accessibility", trusted ? "" : "allow it for the program this was started from (System Settings, Privacy & Security, Accessibility)")
        let recording = CGPreflightScreenCaptureAccess()
        step(recording, "this Petal may record the screen (for the picture)", recording ? "" : "without Screen Recording there is no PNG; the rest still runs")
        guard VirtualDisplay.available else { finish() }

        // 2. How things are before.
        let before = front()
        let screensBefore = Screens.displays.map { CGDisplayBounds($0) }
        let pointerBefore = pointer()
        let countBefore = NSScreen.screens.count
        let onlineBefore = Screens.online
        say("in front before: \(before.name) (pid \(before.pid), window \(before.window.map(String.init) ?? "none"))")
        say("the person's screens before: " + screensBefore.map(describe).joined(separator: " | "))

        // 3. The display.
        let gone = GoneFlag()
        let makingStarted = Date()
        let display = VirtualDisplay.make(name: "Petal display check", serial: UInt32(getpid()), points: RunDisplayRules.size) { gone.set() }
        let making = Date().timeIntervalSince(makingStarted)
        step(display != nil, "a display was made", display.map { "id \($0.id), \($0.hiDPI ? "2880×1800 pixels (HiDPI)" : "1440×900 pixels (HiDPI refused)"), in \(seconds(making))" }
            ?? "CGVirtualDisplay refused: initWithDescriptor or applySettings failed")
        guard let display else { finish() }
        let id = display.id

        // 4. Where it is. Placing waits for macOS's own list to hold it, then a moment more, then asks.
        let placed = PlacedBox()
        RunDisplays.queue.async {
            let placing = RunDisplays.place(id, size: RunDisplayRules.size)
            DispatchQueue.main.async { placed.value = placing }
        }
        wait(30) { placed.value != nil }
        for line in placed.value?.tried ?? ["placing never answered (30 s)"] { say(line) }
        if let placing = placed.value {
            say("online \(seconds(placing.online)) after it was made; placing took \(seconds(placing.placed)) more (the first ask waits until a second and a half after it was made)")
        }
        let listed = Screens.isOnline(id)
        step(listed, "macOS's list of online displays holds it", "the list: \(Screens.online.sorted()), before: \(onlineBefore.sorted())")
        let frame = placed.value?.frame
        step(frame != nil, "macOS kept it where Petal asked, at a corner of the person's screens", frame.map(describe) ?? "see the tries above")
        // Wherever it is now: could the pointer get onto it? Only across a shared stretch of edge (a corner alone
        // can't be crossed), or where it overlaps a screen.
        let bounds = CGDisplayBounds(id)
        let persons = Screens.displays.map { CGDisplayBounds($0) }
        let edges = persons.map { RunDisplayRules.sharedEdge(bounds, $0) }
        let overlapping = persons.contains { RunDisplayRules.overlaps(bounds, $0) }
        step(listed && !overlapping && edges.allSatisfy { $0 < 0.5 }, "the pointer can't get onto it: it shares no stretch of edge with any of the person's screens",
             "it is at \(describe(bounds)); shared edge with each screen: \(edges.map { "\(Int($0)) pt" }.joined(separator: ", "))\(overlapping ? "; it overlaps one" : "")")
        step(!Screens.displays.contains(id) && Screens.isRun(id), "Petal's list of the person's displays leaves it out",
             "the person's: \(Screens.displays), runs': \(Screens.runIDs.sorted())")
        wait(1) { NSScreen.screens.count > countBefore }
        say("AppKit, in this process, sees \(NSScreen.screens.count) screen(s) (\(countBefore) before). A process with no app of its own isn't told of new screens; the running Petal is, at once, which is why Petal goes by the display's id and bounds.")
        let screensDuring = Screens.displays.map { CGDisplayBounds($0) }
        step(screensDuring == screensBefore, "the person's screens didn't move or change size",
             screensDuring == screensBefore ? "" : "now " + screensDuring.map(describe).joined(separator: " | "))

        // 5. A TextEdit window of the check's own: a throwaway file, opened without activating anything.
        var window: (window: CGWindowID, pid: pid_t, element: AXUIElement)?
        let file = folder.appending(path: "petal-display-check-\(getpid()).txt")
        let target = frame ?? CGDisplayBounds(id)
        if trusted {
            try? Data("Petal display check\n".utf8).write(to: file)
            let bundle = "com.apple.TextEdit"
            let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            step(textEdit != nil, "TextEdit is installed")
            if let textEdit {
                let existing = Set(RunDisplays.windowNumbers(bundle: bundle).keys)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.addsToRecentItems = false
                let opened = OpenFlag()
                NSWorkspace.shared.open([file], withApplicationAt: textEdit, configuration: configuration) { _, error in
                    opened.error = error?.localizedDescription
                    opened.set()
                }
                wait(20) { opened.isSet }
                step(opened.isSet && opened.error == nil, "TextEdit opened the throwaway file without being activated", opened.error ?? (opened.isSet ? "" : "Launch Services never answered"))
                let found = FoundBox()
                RunDisplays.queue.async {
                    let made = RunDisplays.newWindows(bundle: bundle, before: existing, timeout: 15, live: { true })
                    DispatchQueue.main.async { found.value = made; found.done = true }
                }
                wait(20) { found.done }
                window = found.value.first
                step(window != nil, "its new window was found through Accessibility", window.map { "window \($0.window), pid \($0.pid)" }
                    ?? "no new standard window of TextEdit in 15 s (\(existing.count) were there before)")
            }
        } else {
            say("skipped: opening, moving and typing need Accessibility")
        }

        // 6. Onto the display, and its text set, through Accessibility alone.
        if let window {
            let was = Windows.frame(of: window.element)
            let moved = MovedBox()
            nonisolated(unsafe) let element = window.element
            let owner = window.pid
            RunDisplays.queue.async {
                let ok = RunDisplays.move(element, pid: owner, to: target, index: 0)
                DispatchQueue.main.async { moved.value = ok }
            }
            wait(6) { moved.value != nil }
            let now = Windows.frame(of: window.element)
            // The window server's own list catches up a moment after Accessibility: read until it agrees, a second and a half at most.
            var server: CGRect?
            let agreed = wait(1.5) {
                server = RunDisplays.windowNumbers(pid: window.pid)[window.window]?.frame
                return server.map { target.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false
            }
            step(moved.value == true && agreed, "the window is on the display",
                 "was \(was.map(describe) ?? "?"), Accessibility says \(now.map(describe) ?? "?"), the window server says \(server.map(describe) ?? "?")\(agreed ? "" : " after 1.5 s"), the display is \(describe(target))")
            let words = "Typed by Petal on a hidden display, \(Int(Date().timeIntervalSince1970))"
            if let area = textArea(in: window.element) {
                let set = AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, words as CFString)
                wait(0.4) { false }
                let read: String = Windows.value(area, kAXValueAttribute) ?? ""
                step(set == .success && read == words, "its text was set through Accessibility and reads back", "AXError \(set.rawValue), reads “\(read.prefix(60))”")
            } else {
                step(false, "its text was set through Accessibility and reads back", "no text area found in the window")
            }
        }

        // 7. The person's front app, window, pointer: as they were.
        let after = front()
        step(after.pid == before.pid, "the app in front didn't change", "before \(before.name) (\(before.pid)), now \(after.name) (\(after.pid))")
        step(after.window == before.window, "its window in front didn't change",
             "before \(before.window.map(String.init) ?? "none"), now \(after.window.map(String.init) ?? "none")")
        let pointerNow = pointer()
        let pointerOn = Screens.displays.contains { CGDisplayBounds($0).contains(pointerNow) }
        say("pointer before \(Int(pointerBefore.x)),\(Int(pointerBefore.y)), now \(Int(pointerNow.x)),\(Int(pointerNow.y)) (it may have moved if someone moved it)")
        step(pointerOn && !CGDisplayBounds(id).contains(pointerNow), "the pointer is on one of the person's screens, not on the display")

        // 8. A picture of the display.
        if recording {
            let shot = ShotBox()
            Task {
                shot.value = await picture(of: id)
                shot.done = true
            }
            wait(15) { shot.done }
            let png = folder.appending(path: "display.png")
            var written = false
            if let image = shot.value {
                let rep = NSBitmapImageRep(cgImage: image)
                written = (try? rep.representation(using: .png, properties: [:])?.write(to: png)) != nil
            }
            step(written, "a PNG of the display was written", written ? png.path : (shot.value == nil ? "ScreenCaptureKit gave no picture of display \(id)" : "couldn't write \(png.path)"))
        }

        // 9. The window closed (its file is a throwaway), or brought back if it wouldn't close.
        if let window {
            if let button: AXUIElement = Windows.value(window.element, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
            let closed = wait(3) { RunDisplays.windowNumbers(pid: window.pid)[window.window] == nil }
            if !closed {
                Windows.place(window.element, pid: window.pid, RunDisplayRules.frame(for: Windows.frame(of: window.element)?.size ?? .zero, on: RunDisplays.personArea()), size: false)
            }
            step(closed, "the window closed", closed ? "" : "it stayed open (it may be asking to save), so it was moved to your main screen: close it yourself")
        }
        try? fm.removeItem(at: file)

        // 10. The display removed.
        let removingStarted = Date()
        display.remove()
        let removed = wait(8) { !Screens.isOnline(id) }
        let removing = Date().timeIntervalSince(removingStarted)
        step(removed, "the display is gone: macOS's list of online displays no longer holds it",
             "the list: \(Screens.online.sorted()), after \(seconds(removing))")
        say("CGDisplayIsOnline(\(id)) says \(CGDisplayIsOnline(id) != 0) (it goes on saying yes for a display that's gone: never relied on)")
        Screens.forget(id)
        step(!Screens.isRun(id), "Petal let its id go", "runs': \(Screens.runIDs.sorted())")
        step(Screens.online == onlineBefore, "the displays online are the ones from before", "before \(onlineBefore.sorted()), now \(Screens.online.sorted())")
        say("made in \(seconds(making)), online after \(seconds(placed.value?.online ?? 0)), placed after \(seconds(placed.value?.placed ?? 0)) more, removed in \(seconds(removing))")
        let screensAfter = Screens.displays.map { CGDisplayBounds($0) }
        step(screensAfter == screensBefore, "the person's screens are as they were",
             screensAfter == screensBefore ? "" : "now " + screensAfter.map(describe).joined(separator: " | "))
        let last = front()
        step(last.pid == before.pid && last.window == before.window, "the app and window in front are still the same",
             "now \(last.name) (\(last.pid)), window \(last.window.map(String.init) ?? "none")")
        step(!gone.isSet, "macOS never took the display away by itself while it was in use")
        finish()
    }

    // MARK: --full

    private typealias Found = (window: CGWindowID, pid: pid_t, element: AXUIElement)

    private static func isRunning(_ bundle: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains { !$0.isTerminated }
    }

    private static func pid(of bundle: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first { !$0.isTerminated }?.processIdentifier
    }

    /// Which corner of which of the person's screens a display touches: "the bottom-right corner of screen 1".
    private static func corner(of frame: CGRect, screens: [CGRect]) -> String {
        for (index, screen) in screens.enumerated() {
            let left = abs(frame.maxX - screen.minX) < 1, right = abs(frame.minX - screen.maxX) < 1
            let above = abs(frame.maxY - screen.minY) < 1, below = abs(frame.minY - screen.maxY) < 1
            guard left || right, above || below else { continue }
            return "the \(below ? "bottom" : "top")-\(right ? "right" : "left") corner of screen \(index + 1)"
        }
        return "no corner of your screens"
    }

    /// The pointer could get onto a display only across a stretch of edge it shares with one of the person's screens
    /// (a corner alone can't be crossed), or where it overlaps one.
    private static func outOfReach(_ id: CGDirectDisplayID) -> (ok: Bool, detail: String) {
        let bounds = CGDisplayBounds(id)
        let persons = Screens.displays.map { CGDisplayBounds($0) }
        let edges = persons.map { RunDisplayRules.sharedEdge(bounds, $0) }
        let overlapping = persons.contains { RunDisplayRules.overlaps(bounds, $0) }
        let ok = Screens.isOnline(id) && !overlapping && edges.allSatisfy { $0 < 0.5 }
        return (ok, "it is at \(describe(bounds)), \(corner(of: bounds, screens: persons)); shared edge with each screen: "
            + edges.map { "\(Int($0)) pt" }.joined(separator: ", ") + (overlapping ? "; it overlaps one" : ""))
    }

    private static func onMainScreen(_ frame: CGRect?) -> Bool {
        guard let frame else { return false }
        return CGDisplayBounds(Screens.mainDisplay).contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// The app and window in front against how they were `before`. Other software on this Mac sometimes brings its
    /// own apps forward while a check runs, so when the app in front changed, which one came forward is printed: a
    /// FAIL only when it's an app the check started, or a window of the check's own; otherwise information.
    private static func frontStep(_ when: String, before: (pid: pid_t, name: String, window: CGWindowID?), apps: Set<pid_t>, windows: Set<CGWindowID>) {
        let now = front()
        let window = now.window.map(String.init) ?? "none"
        if let focused = now.window, windows.contains(focused) {
            return step(false, "nothing of the check's came forward \(when)", "a window of the check's (\(focused), in \(now.name)) is in front")
        }
        if now.pid == before.pid {
            step(true, "the app in front didn't change \(when)", "\(now.name) (\(now.pid))")
            if now.window != before.window {
                say("its window in front is \(window) (it was \(before.window.map(String.init) ?? "none")): not one of the check's, so that was you or \(now.name) itself")
            }
        } else if apps.contains(now.pid) {
            step(false, "the app in front didn't change \(when)", "\(now.name) (\(now.pid)) came forward, and the check started it; before: \(before.name) (\(before.pid))")
        } else {
            step(true, "nothing of the check's came forward \(when)", "information: \(now.name) (\(now.pid)) is in front now instead of \(before.name) (\(before.pid)); the check didn't start it, so other software or you brought it forward")
        }
    }

    /// Opens something for a run once it has its display and its turn for the app, as Petal's tools do
    /// (`RunDisplays.open`, off the main thread), and tells the controller what it started and made.
    private static func open(_ displays: RunDisplays, run: String, appURL: URL, bundle: String, name: String, url: URL?) -> RunDisplays.Opened? {
        guard let display = displays.display(for: run) else {
            displays.finished(run, app: bundle)
            return nil
        }
        let frame = display.frame
        let index = displays.nextIndex(for: run)
        let box = OpenedBox()
        DispatchQueue.global(qos: .userInitiated).async {
            let opened = RunDisplays.open(appURL: appURL, bundle: bundle, url: url, on: frame, index: index, live: { true })
            DispatchQueue.main.async { box.value = opened }
        }
        wait(60) { box.value != nil }
        guard let opened = box.value else {
            displays.finished(run, app: bundle)
            return nil
        }
        if let pid = opened.launched { displays.launched(pid, bundle: bundle, name: name, by: run) }
        if !opened.moved.isEmpty { displays.track(opened.moved, for: run, bare: url == nil, panels: opened.panels, app: (bundle, name)) }
        displays.finished(run, app: bundle)
        return opened
    }

    /// The windows a run is given by `petal_windows`, of these apps: every one but another run's.
    private static func listed(_ displays: RunDisplays, for run: String, pids: [pid_t]) -> Set<CGWindowID> {
        var found: Set<CGWindowID> = []
        for pid in pids {
            for window in Windows.windows(of: pid, everywhere: true) {
                guard !displays.foreign(window.frame, to: run), !displays.foreign(window: window.number, to: run), let number = window.number else { continue }
                found.insert(number)
            }
        }
        return found
    }

    private static func close(_ window: Found) -> Bool {
        if let button: AXUIElement = Windows.value(window.element, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
        return wait(3) { RunDisplays.windowNumbers(pid: window.pid)[window.window] == nil }
    }

    /// `Petal --display-check <folder> --full`: the whole of it with real displays and real apps, for whoever is at
    /// the Mac to run on purpose. Three runs with a limit of two displays, through the same controller Petal uses
    /// (`RunDisplays`, on its own, with no settings and no chats), TextEdit and Calculator, throwaway files only, and
    /// Accessibility alone (no AppleScript, no System Events):
    /// two runs each get a display at a different corner, out of the pointer's reach, and the person's screens don't
    /// move; a third waits and gets one when one is freed; a run's window is on its own display and not listed for
    /// another; a second run asking for the app the first is using waits and gets it when the first ends; an app a
    /// run started is quit when the run ends, and one that was open before is left running; Show me brings a run's
    /// window to the main screen while its display stays; and at the end nothing is left: no display, no app or
    /// window of the check's, the app in front as before. One line per step, "ok" or "FAIL" with what was read and
    /// how long it took; the exit code is the number of failures.
    static func runFull(folder path: String) -> Never {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        print("Petal display check (full), macOS \(ProcessInfo.processInfo.operatingSystemVersionString). This makes real displays and opens TextEdit and Calculator for about a minute.")

        // 1. What it needs.
        step(VirtualDisplay.available, "macOS has the classes Petal makes a display with",
             VirtualDisplay.available ? "" : "missing: " + VirtualDisplay.missing.joined(separator: ", "))
        let trusted = AXIsProcessTrusted()
        step(trusted, "this Petal may use Accessibility", trusted ? "" : "allow it for the program this was started from (System Settings, Privacy & Security, Accessibility)")
        let textEdit = "com.apple.TextEdit", calculator = "com.apple.calculator"
        let textEditURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: textEdit)
        let calculatorURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: calculator)
        step(textEditURL != nil && calculatorURL != nil, "TextEdit and Calculator are installed")
        guard VirtualDisplay.available, trusted, let textEditURL, let calculatorURL else {
            say("the full check needs all three: nothing was made or opened")
            finish()
        }

        // 2. How things are before.
        let before = front()
        let screensBefore = Screens.displays.map { CGDisplayBounds($0) }
        let onlineBefore = Screens.online
        let pointerBefore = pointer()
        let textEditWas = isRunning(textEdit)
        let calculatorWas = isRunning(calculator)
        let theirWindows = Set(RunDisplays.windowNumbers(bundle: textEdit).keys)
        say("in front before: \(before.name) (pid \(before.pid), window \(before.window.map(String.init) ?? "none"))")
        say("your screens before: " + screensBefore.map(describe).joined(separator: " | "))
        say("TextEdit \(textEditWas ? "is open (yours: left running, your windows never touched)" : "isn't open"); Calculator \(calculatorWas ? "is open (yours)" : "isn't open")")
        var files: [String: URL] = [:]
        for name in ["open", "first", "second"] {
            let file = folder.appending(path: "petal-display-check-\(getpid())-\(name).txt")
            try? Data("Petal display check: \(name)\n".utf8).write(to: file)
            files[name] = file
        }
        /// Apps the check (or a run of its own) started, and its windows: nothing of these may come forward.
        var startedApps: Set<pid_t> = []
        var ownWindows: [Found] = []

        // 3. An app that was open before any run. TextEdit, when it's open; else the check starts it itself, outside
        // any run, with a throwaway file and without activating it, to stand for an app the person had open.
        var checkStartedTextEdit = false
        if !textEditWas, let file = files["open"] {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            let opened = OpenFlag()
            NSWorkspace.shared.open([file], withApplicationAt: textEditURL, configuration: configuration) { _, error in
                opened.error = error?.localizedDescription
                opened.set()
            }
            wait(20) { opened.isSet }
            let found = FoundBox()
            DispatchQueue.global(qos: .userInitiated).async {
                let made = RunDisplays.newWindows(bundle: textEdit, before: theirWindows, timeout: 15, live: { true })
                DispatchQueue.main.async { found.value = made; found.done = true }
            }
            wait(20) { found.done }
            ownWindows += found.value
            checkStartedTextEdit = isRunning(textEdit)
            step(checkStartedTextEdit && !found.value.isEmpty, "TextEdit wasn't open, so the check started it itself, outside any run, to stand for an app you had open",
                 opened.error ?? "its window \(found.value.first.map { String($0.window) } ?? "wasn't found"), on your screen, not activated")
            if let pid = pid(of: textEdit) { startedApps.insert(pid) }
        }
        guard let textEditPID = pid(of: textEdit) else {
            step(false, "TextEdit is running", "it never started: nothing more was done")
            for file in files.values { try? fm.removeItem(at: file) }
            finish()
        }

        // 4. Two runs, two displays, at two corners; the limit is two.
        let displays = RunDisplays(alone: 2)
        for run in ["A", "B", "C"] { displays.join(run, group: run) }
        var got: [String: RunDisplays.Display] = [:]
        var refused: [String: String] = [:]
        var times: [String: TimeInterval] = [:]
        for run in ["A", "B"] {
            let asked = Date()
            displays.need(run, label: "Run \(run)") { result in
                switch result {
                case .success(let display): got[run] = display
                case .failure(let why): refused[run] = why.words
                }
                times[run] = Date().timeIntervalSince(asked)
            }
            wait(40) { got[run] != nil || refused[run] != nil }
            step(got[run] != nil, "run \(run) got a display", got[run].map { "id \($0.number), \(describe($0.frame)), in \(seconds(times[run] ?? 0))" } ?? refused[run] ?? "no answer in 40 s")
        }
        guard let first = got["A"], let second = got["B"] else {
            say("without two displays the rest can't run: ending the runs and cleaning up")
            for run in ["A", "B", "C"] { displays.ended(run) }
            wait(10) { Screens.online == onlineBefore }
            for window in ownWindows { _ = close(window) }
            if checkStartedTextEdit { _ = NSRunningApplication(processIdentifier: textEditPID)?.terminate() }
            for file in files.values { try? fm.removeItem(at: file) }
            step(Screens.online == onlineBefore, "no display is left", "online: \(Screens.online.sorted()), before: \(onlineBefore.sorted())")
            finish()
        }
        let persons = Screens.displays.map { CGDisplayBounds($0) }
        let cornerA = corner(of: CGDisplayBounds(first.number), screens: persons), cornerB = corner(of: CGDisplayBounds(second.number), screens: persons)
        step(first.number != second.number && cornerA != cornerB && !RunDisplayRules.overlaps(CGDisplayBounds(first.number), CGDisplayBounds(second.number)),
             "the two displays are at two different corners", "A: \(cornerA); B: \(cornerB)")
        for (run, display) in [("A", first), ("B", second)] {
            let reach = outOfReach(display.number)
            step(reach.ok, "the pointer can't get onto run \(run)'s display", reach.detail)
        }
        step(!Screens.displays.contains(first.number) && !Screens.displays.contains(second.number), "Petal's list of your displays leaves both out",
             "yours: \(Screens.displays), runs': \(Screens.runIDs.sorted())")
        let screensDuring = Screens.displays.map { CGDisplayBounds($0) }
        step(screensDuring == screensBefore, "your screens didn't move or change size", screensDuring == screensBefore ? "" : "now " + screensDuring.map(describe).joined(separator: " | "))

        // 5. A third run is past the limit: it waits.
        var third: RunDisplays.Display?
        var thirdRefused: String?
        let thirdAsked = Date()
        var thirdTook: TimeInterval = 0
        displays.need("C", label: "Run C") { result in
            switch result {
            case .success(let display): third = display
            case .failure(let why): thirdRefused = why.words
            }
            thirdTook = Date().timeIntervalSince(thirdAsked)
        }
        wait(2) { third != nil || thirdRefused != nil }
        step(third == nil && thirdRefused == nil && displays.waits("C") && Screens.online.count == onlineBefore.count + 2,
             "with the limit at 2, a third run waits its turn, and no third display is made",
             thirdRefused ?? "online: \(Screens.online.sorted())")

        // 6. Run A opens a throwaway file in TextEdit, which was open before the run.
        var turnA: Bool?
        displays.turn("A", app: textEdit, name: "TextEdit", hold: true) { turnA = $0 == nil }
        var windowA: Found?
        if turnA == true, let file = files["first"] {
            let opening = Date()
            let opened = open(displays, run: "A", appURL: textEditURL, bundle: textEdit, name: "TextEdit", url: file)
            windowA = opened?.moved.first
            if let windowA { ownWindows.append(windowA) }
            step(windowA != nil, "run A opened a throwaway file in TextEdit without activating it, and its window is on A's display",
                 opened?.problem ?? windowA.map { "window \($0.window), at \(Windows.frame(of: $0.element).map(describe) ?? "?"), in \(seconds(Date().timeIntervalSince(opening)))" }
                    ?? "no new window was moved there (\(opened?.stayed ?? 0) wouldn't move)")
            step(opened?.launched == nil, "TextEdit was open before the run, so it isn't run A's to quit")
        } else {
            step(false, "run A has TextEdit to itself at once", "its turn didn't come")
        }
        frontStep("after run A's open", before: before, apps: startedApps, windows: Set(ownWindows.map(\.window)))

        // 7. Run B asks for the app run A is using: it waits its turn.
        var turnB: Bool?
        var turnBWhy: String?
        let turnBAsked = Date()
        var turnBTook: TimeInterval = 0
        let textEditWindows = RunDisplays.windowNumbers(bundle: textEdit).count
        displays.turn("B", app: textEdit, name: "TextEdit", hold: true) { failure in
            turnB = failure == nil
            turnBWhy = failure?.words
            turnBTook = Date().timeIntervalSince(turnBAsked)
        }
        wait(1.5) { turnB != nil }
        step(turnB == nil && displays.waitsForApp("B") == "TextEdit", "run B, asking for TextEdit while run A uses it, waits its turn",
             turnBWhy ?? "it says: \(NoteStatus.waiting(for: displays.waitsForApp("B") ?? ""))")
        step(RunDisplays.windowNumbers(bundle: textEdit).count == textEditWindows, "and nothing was opened among run A's windows meanwhile")

        // 8. Run A ends: its document comes back to the person's screen (it holds a file, so it's never closed),
        // TextEdit is left running, the third run gets the display that was freed, and run B gets TextEdit.
        let endingA = Date()
        displays.ended("A")
        let goneA = wait(20) { !Screens.isOnline(first.number) }
        step(goneA, "run A ended and its display is gone", "after \(seconds(Date().timeIntervalSince(endingA))); online: \(Screens.online.sorted())")
        if let windowA {
            let now = Windows.frame(of: windowA.element)
            step(onMainScreen(now), "the document run A left open came back to your main screen, not closed (it holds a file)", now.map(describe) ?? "the window is gone")
        }
        step(isRunning(textEdit), "TextEdit, open before the run, was left running")
        frontStep("when run A ended", before: before, apps: startedApps, windows: Set(ownWindows.map(\.window)))
        let gotThird = wait(40) { third != nil || thirdRefused != nil }
        step(gotThird && third != nil, "the third run got a display once one was freed",
             third.map { "id \($0.number), \(describe($0.frame)), \(corner(of: CGDisplayBounds($0.number), screens: Screens.displays.map { CGDisplayBounds($0) })), \(seconds(thirdTook)) after it asked" } ?? thirdRefused ?? "no answer in 40 s")
        if let third {
            let reach = outOfReach(third.number)
            step(reach.ok, "the pointer can't get onto the third run's display", reach.detail)
        }
        let gotTurn = wait(15) { turnB != nil }
        step(gotTurn && turnB == true, "run B got TextEdit once run A had ended", turnBWhy ?? "\(seconds(turnBTook)) after it asked")

        // 9. Run B opens its own file in TextEdit; run C starts Calculator.
        var windowB: Found?
        if turnB == true, let file = files["second"] {
            let opened = open(displays, run: "B", appURL: textEditURL, bundle: textEdit, name: "TextEdit", url: file)
            windowB = opened?.moved.first
            if let windowB { ownWindows.append(windowB) }
            step(windowB != nil, "run B opened its own throwaway file in TextEdit, on B's display",
                 opened?.problem ?? windowB.map { "window \($0.window), at \(Windows.frame(of: $0.element).map(describe) ?? "?")" } ?? "no new window was moved there")
        }
        var windowC: Found?
        var calculatorPID: pid_t?
        if calculatorWas {
            say("skipped: Calculator is open already (yours), so no run can start it. Quit Calculator and run this again to see an app a run started being quit.")
        } else if third != nil {
            var turnC: Bool?
            displays.turn("C", app: calculator, name: "Calculator", hold: true) { turnC = $0 == nil }
            if turnC == true {
                let opening = Date()
                let opened = open(displays, run: "C", appURL: calculatorURL, bundle: calculator, name: "Calculator", url: nil)
                windowC = opened?.moved.first
                calculatorPID = opened?.launched
                if let calculatorPID { startedApps.insert(calculatorPID) }
                if let windowC { ownWindows.append(windowC) }
                step(windowC != nil, "run C started Calculator without activating it, and its window is on C's display",
                     opened?.problem ?? windowC.map { "window \($0.window), at \(Windows.frame(of: $0.element).map(describe) ?? "?"), in \(seconds(Date().timeIntervalSince(opening)))" }
                        ?? "no new window was moved there (\(opened?.stayed ?? 0) wouldn't move)")
                step(calculatorPID != nil && displays.launchedApps(for: "C").contains { $0.pid == calculatorPID }, "Calculator wasn't open, so it's run C's own to put away")
            } else {
                step(false, "run C has Calculator to itself at once", "its turn didn't come")
            }
        }
        frontStep("after the runs' opens", before: before, apps: startedApps, windows: Set(ownWindows.map(\.window)))

        // 10. Each run's window is on its own display, and not listed for the other.
        if let windowB, let windowC, let frameB = Windows.frame(of: windowB.element), let frameC = Windows.frame(of: windowC.element) {
            step(displays.holds(frameB, for: "B") && displays.holds(frameC, for: "C"), "each run's window is on its own display",
                 "B's at \(describe(frameB)), C's at \(describe(frameC))")
            step(displays.foreign(window: windowB.window, to: "C") && displays.foreign(window: windowC.window, to: "B")
                    && !displays.foreign(window: windowB.window, to: "B") && !displays.foreign(window: windowC.window, to: "C"),
                 "each is its own run's, and none of the other's")
            let pids = [windowB.pid, windowC.pid]
            let listB = listed(displays, for: "B", pids: pids), listC = listed(displays, for: "C", pids: pids)
            step(listB.contains(windowB.window) && !listB.contains(windowC.window) && listC.contains(windowC.window) && !listC.contains(windowB.window),
                 "each run's list of windows (as petal_windows gives it) has its own and not the other's", "B is given \(listB.sorted()), C is given \(listC.sorted())")
            let dock = Set(pids.flatMap { Windows.windows(of: $0) }.compactMap(\.number))
            step(!dock.contains(windowB.window) && !dock.contains(windowC.window), "the dock's own window lists leave both out", "the dock sees \(dock.sorted())")
        } else if !calculatorWas {
            step(false, "each run's window is on its own display, and not listed for the other", "one of the two windows wasn't made")
        }

        // 11. Show me on run B: its window comes to the main screen, and its display stays while the run goes on.
        if let windowB {
            let showing = Date()
            displays.showMe(group: "B", raise: false)
            let came = wait(6) { onMainScreen(Windows.frame(of: windowB.element)) }
            step(came, "Show me brought run B's window to your main screen", "\(Windows.frame(of: windowB.element).map(describe) ?? "the window is gone"), in \(seconds(Date().timeIntervalSince(showing)))")
            say("the check moves it only. Pressed for real, Show me also brings the window forward: that is your own click.")
            frontStep("with Show me", before: before, apps: startedApps, windows: Set(ownWindows.map(\.window)))
            step(Screens.isOnline(second.number) && displays.display(for: "B") != nil, "run B's display stays while the run goes on", "online: \(Screens.online.sorted())")
        }

        // 12. Run C ends: the app it started, which nobody used, is quit.
        if let third {
            let ending = Date()
            displays.ended("C")
            let gone = wait(25) { !Screens.isOnline(third.number) }
            step(gone, "run C ended and its display is gone", "after \(seconds(Date().timeIntervalSince(ending)))")
            if let calculatorPID {
                let quit = wait(6) { !isRunning(calculator) }
                step(quit, "Calculator, which run C started and nobody used, was quit",
                     quit ? "what Petal did: \(displays.settled.last.map { "quit \($0.quit), wouldn't quit \($0.stayed), kept \($0.kept)" } ?? "nothing recorded")"
                          : "pid \(calculatorPID) still runs; settled: \(String(describing: displays.settled.last))")
            }
        }

        // 13. Run B ends: its display goes, and the window the person was shown stays where it is.
        let endingB = Date()
        displays.ended("B")
        let goneB = wait(20) { !Screens.isOnline(second.number) }
        step(goneB, "run B ended and its display is gone", "after \(seconds(Date().timeIntervalSince(endingB)))")
        if let windowB {
            step(onMainScreen(Windows.frame(of: windowB.element)), "the window you were shown stayed on your screen")
        }
        step(isRunning(textEdit), "TextEdit is still running")

        // 14. The check's own leftovers: its throwaway windows are closed, and TextEdit is quit only if the check
        // itself started it and nothing else is open in it.
        var unclosed: [CGWindowID] = []
        for window in ownWindows where RunDisplays.windowNumbers(pid: window.pid)[window.window] != nil {
            if !close(window) { unclosed.append(window.window) }
        }
        step(unclosed.isEmpty, "the check closed its own throwaway windows", unclosed.isEmpty ? "" : "still open: \(unclosed) (they may be asking to save: close them yourself)")
        if checkStartedTextEdit {
            let left = Set(RunDisplays.windowNumbers(pid: textEditPID).keys)
            if left.isEmpty, RunDisplays.unsaved(pid: textEditPID) == .no {
                _ = NSRunningApplication(processIdentifier: textEditPID)?.terminate()
                step(wait(6) { !isRunning(textEdit) }, "TextEdit, which the check itself started, was quit")
            } else {
                say("TextEdit, which the check started, has something open in it now (\(left.count) window(s)) that isn't the check's: left running for you")
            }
        }
        for file in files.values { try? fm.removeItem(at: file) }

        // 15. Nothing is left.
        // A removed display's id is let go a few seconds after macOS stops listing it.
        wait(15) { Screens.online == onlineBefore && Screens.runIDs.isEmpty }
        step(Screens.online == onlineBefore, "no display is left: macOS's list of online displays is as before", "before \(onlineBefore.sorted()), now \(Screens.online.sorted())")
        step(Screens.runIDs.isEmpty, "Petal let every display's id go", "runs': \(Screens.runIDs.sorted())")
        let calculatorLeft = !calculatorWas && isRunning(calculator)
        let textEditLeft = !textEditWas && isRunning(textEdit) && RunDisplays.windowNumbers(bundle: textEdit).isEmpty
        step(!calculatorLeft && !textEditLeft, "no app the check started is left running",
             "Calculator \(isRunning(calculator) ? "runs" : "doesn't run") (before: \(calculatorWas ? "open" : "not open")); TextEdit \(isRunning(textEdit) ? "runs" : "doesn't run") (before: \(textEditWas ? "open" : "not open"))")
        if textEditWas { step(isRunning(textEdit), "TextEdit, yours, is still running") }
        let mine = Set(ownWindows.map(\.window))
        let stillThere = mine.filter { number in ownWindows.contains { $0.window == number && RunDisplays.windowNumbers(pid: $0.pid)[number] != nil } }
        step(stillThere.isEmpty, "no window of the check's is on your screen", stillThere.isEmpty ? "" : "still there: \(stillThere.sorted())")
        if textEditWas {
            let now = Set(RunDisplays.windowNumbers(bundle: textEdit).keys)
            say("your TextEdit windows: \(theirWindows.count) before, \(now.count) now (the check never touched them)")
        }
        let screensAfter = Screens.displays.map { CGDisplayBounds($0) }
        step(screensAfter == screensBefore, "your screens are as they were", screensAfter == screensBefore ? "" : "now " + screensAfter.map(describe).joined(separator: " | "))
        frontStep("at the end", before: before, apps: startedApps, windows: mine)
        let pointerNow = pointer()
        say("pointer before \(Int(pointerBefore.x)),\(Int(pointerBefore.y)), now \(Int(pointerNow.x)),\(Int(pointerNow.y)) (it moves only if you moved it)")
        step(Screens.displays.contains { CGDisplayBounds($0).contains(pointerNow) }, "the pointer is on one of your screens")
        finish()
    }

    private static func finish() -> Never {
        print("\(passes) passed, \(failures) failed")
        exit(Int32(min(failures, 100)))
    }

    /// The whole display as it is, with everything on it.
    nonisolated private static func picture(of id: CGDirectDisplayID) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

private final class GoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.withLock { on = true } }
    var isSet: Bool { lock.withLock { on } }
}

private final class OpenFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    private var text: String?
    func set() { lock.withLock { on = true } }
    var isSet: Bool { lock.withLock { on } }
    var error: String? {
        get { lock.withLock { text } }
        set { lock.withLock { text = newValue } }
    }
}

private final class PlacedBox: @unchecked Sendable { var value: RunDisplays.Placing? }
private final class OpenedBox: @unchecked Sendable { var value: RunDisplays.Opened? }
private final class MovedBox: @unchecked Sendable { var value: Bool? }
private final class FoundBox: @unchecked Sendable {
    var value: [(window: CGWindowID, pid: pid_t, element: AXUIElement)] = []
    var done = false
}
private final class ShotBox: @unchecked Sendable {
    var value: CGImage?
    var done = false
}
