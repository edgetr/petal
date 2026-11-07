import AppKit
import ApplicationServices

/// A sticky note's acts in its own window, in the background (Background.swift decides which way): Accessibility
/// actions and values, focus inside that app only, and keys posted to that app's process alone, only while it isn't
/// the app in front. No pointer, nothing raised or activated. What can't be done this way comes back as
/// `Outcome.needs`, with nothing done. All of it off the main thread, on ComputerUse's act queue.
extension Acting {
    /// Seconds since the person last pressed a key, clicked or scrolled: the hardware's own times, so Petal's own
    /// posted keys never count.
    nonisolated static func idle() -> TimeInterval {
        let kinds: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }

    /// A note's situation, read now (off the main thread): its app in front (`front`, else asked through
    /// Accessibility), its window that app's focused one, and how long the person has been idle.
    nonisolated static func situation(_ map: ComputerUse.Map, front: Bool? = nil) -> Background.Situation {
        let appFront = front ?? isFront(map.pid)
        return Background.Situation(note: true, appFront: appFront, windowFocused: appFront && windowInFront(map), idle: idle())
    }

    /// The app in front, read through Accessibility (off the main thread, and at once, where NSWorkspace hears of it
    /// only through the main thread).
    nonisolated static func frontApp() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        if let app: AXUIElement = Windows.value(system, kAXFocusedApplicationAttribute) {
            var pid: pid_t = 0
            if AXUIElementGetPid(app, &pid) == .success { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func quietly(_ action: String, entry: ComputerUse.Entry?, map: ComputerUse.Map, prepared: Prepared, options: Options,
                        cancel: Cancel, baseline: Background.Baseline) -> Outcome {
        var outcome = Outcome()
        let pid = map.pid
        let element = entry?.element
        let fresh = element.map(Reader.node)
        let name = entry.map { UIMap.name($0.node) }.flatMap { $0.isEmpty ? nil : "“\($0)”" } ?? "That control"
        func say(_ note: String) { outcome.note = outcome.note.map { $0 + " " + note } ?? note }
        let front = isFront(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        // The window the person has in front in that app, when it's the app they're using: put back if a press raises
        // the note's window over it.
        let theirs: AXUIElement? = front ? Windows.value(app, kAXFocusedWindowAttribute) : nil
        let windowMain = windowInFront(map)
        let nodes = [fresh, entry?.node].compactMap { $0 }
        let clipboard: Bool
        switch action {
        // A Copy or Cut button (or one whose words say it copies) changes the person's clipboard.
        case "press": clipboard = Background.pressUsesClipboard(nodes)
        case "menu", "key": clipboard = clip(key: options.key, item: prepared.menuItem, title: prepared.menuTitle) != nil
        default: clipboard = false
        }
        let text = nodes.contains(where: UIMap.isText)
        let web = entry?.node.web ?? false
        let step = Background.plan(Background.Target(action: action, text: text, web: web, clipboard: clipboard,
                                                      menuItem: prepared.menuItem != nil, element: element != nil,
                                                      appFront: front, windowMain: windowMain))

        /// Right before each change: the person may have come back to the note's window (or its app) during the reads
        /// since it decided. Before the first change it's decided again (the foreground rules, with their pause);
        /// after one, it stops there. Never a change in the window the person is now using. Every change goes through
        /// `gate`, which runs this and then the change at once, with nothing read in between (Background.Gate): the
        /// shared helpers (focus, insert, typing, scrolling) do their reads first and take the gate for their changes.
        var changed = false
        func clear() -> Background.Verdict {
            // The situation read first; a Stop, steering, a new turn or the app made private (which stops `cancel`)
            // during that read is heard after it, right before the change (Background.check).
            guard let behind = Background.check(stopped: { cancel.stopped }, read: { situation(map) },
                                                plannedFront: front, changed: changed) else { return .no }
            switch behind {
            case .go:
                changed = true
                return .go
            case .again:
                outcome.again = true
            case .stop:
                outcome.error = "The person came back to \(map.appName)'s window while Petal worked there in the background, so it stopped part way. Call petal_ui to see what was done."
            }
            return .no
        }
        let gate = Background.Gate(clear)

        /// Typed but not as asked, in the background: never counted as done, never sent.
        let uncertain = "Petal couldn't confirm \(name) took that in the background (it doesn't read as asked now), so it isn't done and Return wasn't pressed. Call petal_ui to see what \(name) holds; then ask the person to bring the window forward (clicking this note in the AI button's preview does it) and type it there."

        /// Gives `element` its app's keyboard (the gate right before the focus is set). False when nothing more
        /// should happen (the gate's refusal has set the outcome already).
        func focused(_ element: AXUIElement) -> Bool {
            guard let error = focus(element, pid: pid, name: name, cancel: cancel, gate: gate) else { return true }
            if !cancel.stopped, !gate.refused { outcome.error = error }
            return false
        }

        /// The text as keys to its app alone, once `element` has that app's keyboard; stops if the app comes to the
        /// front meanwhile (keys would then be the person's). False when nothing more should happen.
        func keys(into element: AXUIElement) -> Bool {
            guard !isFront(pid) else { outcome.needs = .keys; return false }
            guard focused(element) else { return false }
            let before = Reader.text(Windows.value(element, kAXValueAttribute) as CFTypeRef?, whole: true)
            let caret = options.replace ? nil : selectedRange(element)
            if options.replace, let all = UIMap.parseKey("cmd-a") {
                guard keysGoTo(element, pid: pid), !isFront(pid) else { outcome.error = "The cursor left \(name); nothing was typed."; return false }
                guard gate.mutate({ post(all, to: pid, cancel: cancel) }) == true else { return false }
            }
            guard type(options.text, to: pid, cancel: cancel, still: { keysGoTo(element, pid: pid) && !isFront(pid) }, gate: gate) else {
                if !cancel.stopped, !gate.refused {
                    outcome.error = "\(map.appName) came to the front, or the cursor left \(name), while Petal typed, so it stopped there. Call petal_ui to see what was typed."
                }
                return false
            }
            usleep(150_000)
            let after = Reader.text(Windows.value(element, kAXValueAttribute) as CFTypeRef?, whole: true)
            // Done only when the field says just what was asked: nothing changed means the app ignored keys in the
            // background; anything else isn't counted as done.
            switch Background.typed(before: before, after: after, text: options.text, replace: options.replace,
                                    at: caret.map(\.location), replaced: caret.map(\.length) ?? 0) {
            case .done: return true
            case .ignored: outcome.needs = .ignored
            case .uncertain: outcome.error = uncertain
            }
            return false
        }

        /// The act itself. Every way out of it (done, refused, stopped part way) goes on to the same putting back below.
        func act() {
            switch step {
            case .needs(let reason):
                outcome.needs = reason
                return
            case .press:
                guard let element else { break }
                // Whatever might paste: never a secret off the clipboard, nor into a password field.
                if nodes.contains(where: UIMap.mightPaste), let why = pasteRefusal() ?? secretFieldRefusal(map, nil, pasting: true) {
                    outcome.error = why
                    break
                }
                // A link or a file opens in another app, which would come to the front: that needs the window in front.
                let address = (Windows.value(element, kAXURLAttribute) as URL?)?.absoluteString ?? Windows.value(element, kAXURLAttribute)
                let role = fresh?.role ?? entry?.node.role ?? ""
                if Background.pressOpens(role: role, url: address, browser: VaultReader.known.contains(map.bundle)) {
                    outcome.needs = .opens
                    return
                }
                let actions = Reader.actions(element)
                if let done = Background.pressAction(actions) {
                    guard let pressed = gate.mutate({ AXUIElementPerformAction(element, done as CFString) }) else { return }
                    if pressed == .success { break }
                } else if actions.contains("AXOpen") {
                    outcome.needs = .opens
                    return
                }
                if ["AXRow", "AXCell", "AXTab", "AXRadioButton"].contains(entry?.node.role ?? "") {
                    guard let picked = gate.mutate({ AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) }) else { return }
                    if picked == .success { break }
                }
                outcome.error = "\(name) can't be pressed through Accessibility, and in the background Petal never clicks for real: try a menu item or a key, or ask the person to click it."
            case .scroll:
                guard let element else { break }
                if options.direction.isEmpty {
                    guard let scrolled = gate.mutate({ AXUIElementPerformAction(element, "AXScrollToVisible" as CFString) }) else { return }
                    if scrolled != .success {
                        outcome.error = "\(name) can't be scrolled into view through Accessibility; give a direction instead."
                    }
                } else if let error = scroll(element, options.direction, cancel: cancel, gate: gate) {
                    outcome.error = error
                }
            case .focus:
                guard let element else { break }
                if isSecure(element) { outcome.error = password; break }
                guard let set = gate.mutate({ AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }) else { return }
                if set != .success {
                    guard let selected = gate.mutate({ AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) }) else { return }
                    if selected != .success {
                        outcome.error = "\(name) can't take the focus through Accessibility."
                    }
                }
            case .setValue, .keys:
                guard let element, let node = entry?.node else { break }
                switch Assist.vaultCheck(options.text) {
                case .secret: outcome.error = "That's one of the vault's secrets: petal_vault fills it (action: fill)."
                case .tooLong: outcome.error = tooMuch("type")
                case .unreadable: outcome.error = vaultUnreadable("type")
                case .clean: break
                }
                if outcome.error != nil { break }
                if isSecure(element) { outcome.error = password; break }
                if case .setValue(let keysAfter) = step {
                    // insert reads the field first, then the gate and the value together.
                    switch insert(options.text, into: element, replace: options.replace, cancel: cancel, gate: gate) {
                    case .done: break
                    case .unsure:
                        // Never counted as done, and never sent.
                        outcome.error = uncertain
                        return
                    case .stopped: return
                    case .no:
                        guard keysAfter else { outcome.needs = .didntStick; return }
                        guard keys(into: element) else { return }
                    }
                } else {
                    guard keys(into: element) else { return }
                }
                // Return goes only to a background app, and only once the keyboard is in this field: the focus (its
                // own gate), then where the keyboard is read, then the gate and Return together.
                if options.submit {
                    if Background.returnGoes(appFront: isFront(pid)), let enter = UIMap.parseKey("return") {
                        let unfocused = focus(element, pid: pid, name: name, cancel: cancel, gate: gate)
                        if unfocused != nil, cancel.stopped || gate.refused { return }
                        if unfocused == nil, keysGoTo(element, pid: pid), !isFront(pid) {
                            guard gate.mutate({ post(enter, to: pid, cancel: cancel) }) == true else { return }
                        } else {
                            say("It was typed, not sent: Return couldn't reach \(name). Press its send button with petal_act instead.")
                        }
                    } else {
                        say("It was typed, not sent: Return would reach the window the person is using in \(map.appName). Press its send button with petal_act instead.")
                    }
                }
                usleep(120_000)
                let now = Reader.text(Windows.value(element, kAXValueAttribute) as CFTypeRef?, whole: true)
                if !now.isEmpty, !options.submit {
                    outcome.value = UIMap.typedValue(now, node: node, filled: Sensitive.isFilled(element, pid: pid), secret: Assist.isVaultSecret)
                }
            case .menu:
                guard let item = prepared.menuItem else { break }
                // A key its menus have, for a control: that control takes its app's keyboard first (its app is behind).
                if let element, action == "key" {
                    guard focused(element) else { return }
                }
                // Right before it: still the note's window its app acts on, and still not the app in front (read), then
                // the gate and the item together.
                guard windowInFront(map), !isFront(pid) else { outcome.needs = .menu; return }
                guard let chosen = gate.mutate({ AXUIElementPerformAction(item, kAXPressAction as CFString) }) else { return }
                if chosen != .success {
                    outcome.error = "Couldn't choose \(prepared.menuTitle ?? "that item"); its app didn't answer."
                }
                outcome.chose = prepared.menuTitle
            case .key:
                guard let key = options.key else { break }
                if let element {
                    guard focused(element) else { return }
                }
                // Right before the key: its app still behind, and the keyboard still in that control (or that window, with
                // no password field), or it isn't sent; then the gate and the key together.
                guard !isFront(pid) else { outcome.needs = .keys; return }
                if let element {
                    guard keysGoTo(element, pid: pid) else { outcome.error = "The cursor left \(name); the key wasn't sent."; break }
                } else {
                    guard windowInFront(map) else { outcome.needs = .keys; return }
                    if let why = secretFieldRefusal(map, nil, pasting: false) { outcome.error = why; break }
                }
                guard gate.mutate({ post(key, to: pid, cancel: cancel) }) == true else { return }
            }
        }
        act()

        // Nothing comes forward. Any app that came to the front after it (the note's own, or another a press opened,
        // such as a browser for a link) gives the person back the app they were using; one that raised the note's
        // window over theirs (the app they use) gives them their window back. Either way only if they did nothing
        // since the baseline (taken with the app in front, before anything was prepared), read again right before:
        // otherwise it's theirs to decide. A press gets a moment for what it opens to come forward.
        var now = frontApp()
        if changed, action == "press", now == baseline.front {
            for _ in 0..<5 {
                usleep(100_000)
                now = frontApp()
                if now != baseline.front { break }
            }
        }
        if now == getpid() { now = nil }   // Petal's own windows are never put away here
        // Every read and lookup first, to decide; then each change that puts something back goes through its own
        // gate (stillJumped), read again right before it, with nothing read in between.
        let noteWindowFront = front && !windowMain && now == pid && windowInFront(map)
        let lastInput = ProcessInfo.processInfo.systemUptime - idle()
        let opened = Background.opened(baseline, note: pid, frontNow: now, lastInput: lastInput)
        let other = now.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "another app"
        /// What's said when nothing is put back (or the putting back stopped before it changed anything).
        func leftAsItIs() {
            if opened { say("That opened something in \(other), which is in front now.") }
            else if now == pid, baseline.front != pid { say("\(map.appName) came to the front after that.") }
            else if noteWindowFront { say("That brought this window forward in \(map.appName).") }
        }
        /// The restoration gate, right before each change that puts something back, with every lookup done before it:
        /// the app that jumped forward still in front with the expected window (`window`, read through Accessibility),
        /// then the person's last input, then a Stop sampled last (Background.putBackGoes). The person picking another
        /// app or window, a key or click of theirs, or a Stop meanwhile ends the putting back there.
        func stillJumped(window: () -> Bool = { true }) -> Bool {
            guard let jumped = now else { return false }
            return Background.putBackGoes(baseline: baseline, jumped: jumped, stopped: { cancel.stopped },
                                          read: {
                                              let front = frontApp()
                                              return (front, front == jumped && window())
                                          },
                                          lastInput: { ProcessInfo.processInfo.systemUptime - idle() })
        }
        switch Background.restore(baseline, note: pid, frontNow: now, lastInput: lastInput) {
        case .app(let person):
            if let theirApp = NSRunningApplication(processIdentifier: person), stillJumped() {
                theirApp.activate()
                say(opened
                    ? "That opened something in \(other), which came to the front; Petal put back the app the person was using. What it opened is in \(other), which this note can't see."
                    : "\(map.appName) came to the front by itself after that; Petal put back the app the person was using.")
            } else {
                leftAsItIs()
            }
        case .window:
            if noteWindowFront, let theirs {
                // Once theirs is raised, it may already be the focused window: either is still what Petal expects.
                func theirsFront() -> Bool {
                    guard let focused: AXUIElement = Windows.value(app, kAXFocusedWindowAttribute) else { return false }
                    return CFEqual(focused, theirs)
                }
                if stillJumped(window: { windowInFront(map) }) {
                    AXUIElementPerformAction(theirs, kAXRaiseAction as CFString)
                    if stillJumped(window: { windowInFront(map) || theirsFront() }) {
                        AXUIElementSetAttributeValue(theirs, kAXMainAttribute as CFString, kCFBooleanTrue)
                    }
                    say("That brought this window forward in \(map.appName); Petal put the person's window back in front.")
                } else {
                    leftAsItIs()
                }
            } else {
                leftAsItIs()
            }
        case .none:
            leftAsItIs()
        }
        // Its own change (text, caret, focus, scroll) becomes what's expected next, as in the foreground.
        if outcome.error == nil, outcome.needs == nil, !outcome.again, !cancel.stopped, ["type", "focus", "scroll", "key"].contains(action) {
            outcome.fingerprint = Reader.fingerprint(app: app, window: map.window, lists: map.lists)
        }
        return outcome
    }
}

/// Electron apps (T3 Code, Slack, VS Code) build their Accessibility tree only once something asks for it, through
/// `AXManualAccessibility` on the app; Chromium browsers turn theirs on for anything that reads them. Asked once per
/// process, before Petal reads one of its windows; apps that don't know it ignore it.
enum AccessibilityTree {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var asked: Set<pid_t> = []

    /// True when it was just turned on: the tree takes a moment to fill.
    nonisolated static func wake(_ pid: pid_t) -> Bool {
        let first = lock.withLock { asked.insert(pid).inserted }
        guard first else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }
}
