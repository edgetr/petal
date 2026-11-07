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
        /// after one, it stops there. Never a change in the window the person is now using.
        var changed = false
        func clear() -> Bool {
            guard !cancel.stopped else { return false }
            switch Background.behind(situation(map), plannedFront: front, changed: changed) {
            case .go:
                changed = true
                return true
            case .again:
                outcome.again = true
            case .stop:
                outcome.error = "The person came back to \(map.appName)'s window while Petal worked there in the background, so it stopped part way. Call petal_ui to see what was done."
            }
            return false
        }

        /// The text as keys to its app alone, once `element` has that app's keyboard; stops if the app comes to the
        /// front meanwhile (keys would then be the person's). False when nothing more should happen.
        func keys(into element: AXUIElement) -> Bool {
            guard clear() else { return false }
            guard !isFront(pid) else { outcome.needs = .keys; return false }
            if let error = focus(element, pid: pid, name: name, cancel: cancel) {
                if !cancel.stopped { outcome.error = error }
                return false
            }
            let before = Reader.text(Windows.value(element, kAXValueAttribute) as CFTypeRef?, whole: true)
            if options.replace, let all = UIMap.parseKey("cmd-a") {
                guard keysGoTo(element, pid: pid), !isFront(pid) else { outcome.error = "The cursor left \(name); nothing was typed."; return false }
                guard clear(), post(all, to: pid, cancel: cancel) else { return false }
            }
            guard clear() else { return false }
            guard type(options.text, to: pid, cancel: cancel, still: { keysGoTo(element, pid: pid) && !isFront(pid) }) else {
                if !cancel.stopped {
                    outcome.error = "\(map.appName) came to the front, or the cursor left \(name), while Petal typed, so it stopped there. Call petal_ui to see what was typed."
                }
                return false
            }
            usleep(150_000)
            let after = Reader.text(Windows.value(element, kAXValueAttribute) as CFTypeRef?, whole: true)
            // Nothing changed: the app ignored keys while it was in the background.
            if after == before, !after.contains(options.text) {
                outcome.needs = .ignored
                return false
            }
            return true
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
                let actions = Reader.actions(element)
                if let done = ["AXPress", "AXPick", "AXConfirm", "AXOpen"].first(where: actions.contains) {
                    guard clear() else { return }
                    if AXUIElementPerformAction(element, done as CFString) == .success { break }
                }
                if ["AXRow", "AXCell", "AXTab", "AXRadioButton"].contains(entry?.node.role ?? "") {
                    guard clear() else { return }
                    if AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success { break }
                }
                outcome.error = "\(name) can't be pressed through Accessibility, and in the background Petal never clicks for real: try a menu item or a key, or ask the person to click it."
            case .scroll:
                guard let element else { break }
                guard clear() else { return }
                if options.direction.isEmpty {
                    if AXUIElementPerformAction(element, "AXScrollToVisible" as CFString) != .success {
                        outcome.error = "\(name) can't be scrolled into view through Accessibility; give a direction instead."
                    }
                } else if let error = scroll(element, options.direction, cancel: cancel) {
                    outcome.error = error
                }
            case .focus:
                guard let element else { break }
                if isSecure(element) { outcome.error = password; break }
                guard clear() else { return }
                if AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) != .success {
                    guard clear() else { return }
                    if AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) != .success {
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
                    guard clear() else { return }
                    switch insert(options.text, into: element, replace: options.replace, cancel: cancel) {
                    case .done: break
                    case .unsure:
                        say("Petal may not have typed it (the field didn't say what it holds now): call petal_ui to see \(name) before typing again.")
                    case .stopped: return
                    case .no:
                        guard keysAfter else { outcome.needs = .didntStick; return }
                        guard keys(into: element) else { return }
                    }
                } else {
                    guard keys(into: element) else { return }
                }
                // Return goes only to a background app, and only once the keyboard is in this field.
                if options.submit {
                    if Background.returnGoes(appFront: isFront(pid)), let enter = UIMap.parseKey("return") {
                        guard clear() else { return }
                        if focus(element, pid: pid, name: name, cancel: cancel) == nil, keysGoTo(element, pid: pid), !isFront(pid) {
                            guard clear(), post(enter, to: pid, cancel: cancel) else { return }
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
                    guard clear() else { return }
                    if let error = focus(element, pid: pid, name: name, cancel: cancel) {
                        if !cancel.stopped { outcome.error = error }
                        break
                    }
                }
                // Right before it: still the note's window its app acts on, and still not the app in front.
                guard windowInFront(map), !isFront(pid) else { outcome.needs = .menu; return }
                guard clear() else { return }
                if AXUIElementPerformAction(item, kAXPressAction as CFString) != .success {
                    outcome.error = "Couldn't choose \(prepared.menuTitle ?? "that item"); its app didn't answer."
                }
                outcome.chose = prepared.menuTitle
            case .key:
                guard let key = options.key else { break }
                if let element {
                    guard clear() else { return }
                    if let error = focus(element, pid: pid, name: name, cancel: cancel) {
                        if !cancel.stopped { outcome.error = error }
                        break
                    }
                }
                // Right before the key: its app still behind, and the keyboard still in that control (or that window, with
                // no password field), or it isn't sent.
                guard !isFront(pid) else { outcome.needs = .keys; return }
                if let element {
                    guard keysGoTo(element, pid: pid) else { outcome.error = "The cursor left \(name); the key wasn't sent."; break }
                } else {
                    guard windowInFront(map) else { outcome.needs = .keys; return }
                    if let why = secretFieldRefusal(map, nil, pasting: false) { outcome.error = why; break }
                }
                guard clear(), post(key, to: pid, cancel: cancel) else { return }
            }
        }
        act()

        // Nothing comes forward. An app that jumped to the front by itself gives the person back the app they were
        // using; one that raised the note's window over theirs (the app they use) gives them their window back.
        // Either way only if they did nothing since the baseline (taken with the app in front, before anything was
        // prepared), read again right before: otherwise it's theirs to decide.
        if isFront(pid) {
            let lastInput = ProcessInfo.processInfo.systemUptime - idle()
            switch Background.restore(baseline, note: pid, noteFrontNow: true, lastInput: lastInput) {
            case .app(let person):
                if let theirApp = NSRunningApplication(processIdentifier: person) {
                    theirApp.activate()
                    say("\(map.appName) came to the front by itself after that; Petal put back the app the person was using.")
                }
            case .window:
                if front, !windowMain, windowInFront(map), let theirs {
                    AXUIElementPerformAction(theirs, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(theirs, kAXMainAttribute as CFString, kCFBooleanTrue)
                    say("That brought this window forward in \(map.appName); Petal put the person's window back in front.")
                }
            case .none:
                if baseline.front != pid { say("\(map.appName) came to the front after that.") }
                else if front, !windowMain, windowInFront(map) { say("That brought this window forward in \(map.appName).") }
            }
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
