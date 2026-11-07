import AppKit
import ApplicationServices
import QuartzCore
import SwiftUI

/// Petal AI using the person's apps (`computerUse`): `petal_ui` reads the controls of a window through
/// Accessibility and gives each a short id; `petal_act` presses, types, focuses, scrolls, chooses a menu item or
/// presses a key, by id. Everything goes through Accessibility actions and keystrokes posted to the app's own
/// process: the person's real pointer is never moved or used (no warping, no mouse events). What only a real click
/// could do, it says so instead. A pink pointer of Petal's own (`FakeCursor`) glides to each control and says what
/// it's doing, with a Stop pill; Escape stops it too.
///
/// The first act on an app in a reply asks the person (Assist.ask, kind `computer:<bundle id>`): Allow covers that
/// app for the rest of the reply, Always for good, unless the chat has Full access. Never apps kept private
/// (`aiNeverLook`), never password fields, never a vault secret: the vault types its own.
@MainActor
final class ComputerUse {
    struct Entry {
        let element: AXUIElement
        let node: UINode
    }

    /// One window's controls, as the last `petal_ui` saw them.
    struct Map {
        let pid: pid_t
        let bundle: String
        let appName: String
        let window: AXUIElement
        let windowFrame: CGRect
        let entries: [String: Entry]
        let count: Int
        let made: Date
    }

    /// One chat's reply (its turn): the apps it may use, and whether the person stopped it.
    struct Session {
        var turn: String
        var apps: Set<String> = []
        var stopped = false
        var last = Date()
    }

    /// One action, waiting its turn: the cursor does one thing at a time.
    struct Job {
        let caller: String
        let action: String
        let entry: Entry?
        let pid: pid_t
        let appName: String
        let window: AXUIElement?
        let windowFrame: CGRect
        let caption: String
        let options: Acting.Options
        let send: (Any) -> Void
        let fail: (String) -> Void
    }

    static let stoppedText = "The person stopped it."

    /// By caller: a chat's note id, or "" for an AI session outside Petal.
    private var maps: [String: Map] = [:]
    private var sessions: [String: Session] = [:]
    private var line: [Job] = []
    private var busy = false
    private var acting: (caller: String, cancel: Acting.Cancel)?
    /// Whose actions the cursor showing is for: Stop stops that reply, even between its actions.
    private var lastCaller: String?
    let cursor = FakeCursor()
    nonisolated static let queue = DispatchQueue(label: "petal.computer", qos: .userInitiated)

    var app: PetalApp { PetalApp.shared }
    var assist: Assist { app.assist }

    init() {
        cursor.onStop = { [weak self] in self?.stop() }
    }

    func handle(_ name: String, _ args: [String: Any], note: String?, send: @escaping (Any) -> Void, fail: @escaping (String) -> Void) {
        guard app.config.bool("computerUse") else { return fail("Using apps is off in Petal's settings (computerUse); only the person can turn it on.") }
        guard Windows.trusted else { return fail("Petal needs Accessibility for this (Petal's settings, Permissions).") }
        if name == "petal_ui" { look(args, caller: note ?? "", send, fail) } else { act(args, caller: note ?? "", send, fail) }
    }

    // MARK: Seeing a window's controls

    private func look(_ args: [String: Any], caller: String, _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        let named = (args["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        // A sticky note's own window, as petal_look does, unless an app or what's in front is asked for.
        let place = named.isEmpty && args["front"] as? Bool != true && app.claude.notesOn ? app.claude.note(withID: caller)?.place : nil
        let target: NSRunningApplication?
        if let place {
            target = NSRunningApplication(processIdentifier: place.pid).flatMap { $0.bundleIdentifier == place.app && !$0.isTerminated ? $0 : nil }
            guard target != nil else { return fail("This note's window is closed: \(place.appName) has quit. front: true uses what's in front now.") }
        } else {
            target = assist.frontApp(named: named)
        }
        guard let target else { return fail(named.isEmpty ? "Nothing's in front." : "\(named) isn't open.") }
        let name = target.localizedName ?? named
        let bundle = target.bundleIdentifier ?? ""
        if assist.neverLook(bundle) {
            return send(["app": name, "private": "The user keeps this app private: Petal doesn't look into it or use it."])
        }
        let pid = target.processIdentifier
        let wanted = place?.window
        let find = args["find"] as? String ?? ""
        Self.queue.async {
            let reading = Reader.read(pid: pid, window: wanted, budget: 1.5)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if reading.gone { return fail("This note's window is closed (it was in \(name)). front: true uses what's in front now.") }
                    guard let window = reading.window else { return fail("\(name) has no window open.") }
                    let picked = UIMap.select(reading.nodes, window: reading.windowFrame, find: find)
                    var entries: [String: Entry] = [:]
                    var list: [[String: Any]] = []
                    for (index, node) in picked.shown.enumerated() {
                        let id = "e\(index + 1)"
                        guard let element = reading.elements[node.order] else { continue }
                        entries[id] = Entry(element: element, node: node)
                        var item: [String: Any] = ["id": id, "role": UIMap.kind(node), "name": UIMap.name(node),
                                                   "frame": [node.frame.minX, node.frame.minY, node.frame.width, node.frame.height].map { Int($0.rounded()) }]
                        if let value = UIMap.value(node) { item["value"] = value }
                        if !node.enabled { item["disabled"] = true }
                        if node.focused { item["focused"] = true }
                        if !UIMap.isVisible(node, window: reading.windowFrame) { item["offscreen"] = true }
                        list.append(item)
                    }
                    self.maps[caller] = Map(pid: pid, bundle: bundle, appName: name, window: window, windowFrame: reading.windowFrame,
                                            entries: entries, count: entries.count, made: Date())
                    var result: [String: Any] = ["app": name, "window": reading.title, "elements": list,
                                                 "note": "Act with petal_act by id. These ids last until the next petal_ui, or 5 minutes; call petal_ui again once the window changes."]
                    if picked.left > 0 { result["more"] = "\(picked.left) more not listed: pass find (a word in its name) to narrow." }
                    if reading.timedOut { result["partial"] = "The window is big: this is what Petal read in time." }
                    if list.isEmpty { result["empty"] = "No controls found\(find.isEmpty ? "" : " matching “\(find)”"). The app may not support Accessibility well; petal_look with a screenshot shows it." }
                    send(result)
                }
            }
        }
    }

    // MARK: Acting

    private func act(_ args: [String: Any], caller: String, _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        guard !session(caller).stopped else { return fail(Self.stoppedText + " Don't carry on using apps in this reply: say what's left and wait for them.") }
        let action = (args["action"] as? String ?? "").lowercased()
        let byElement: Set<String> = ["press", "type", "focus", "scroll"]
        guard byElement.contains(action) || action == "menu" || action == "key" else {
            return fail("action is press, type, focus, scroll, menu or key.")
        }
        let id = (args["id"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if let map = maps[caller], Date().timeIntervalSince(map.made) > UIMap.lifetime { maps[caller] = nil }
        let map = maps[caller]
        var entry: Entry?
        if byElement.contains(action) {
            guard !id.isEmpty else { return fail("Give the id of a control from petal_ui (like e12).") }
            guard let map else { return fail("Call petal_ui first: ids come from it, and last until the next petal_ui or 5 minutes.") }
            guard let found = map.entries[id] else { return fail("There's no \(id) in the last petal_ui (it listed e1 to e\(map.count)). Call petal_ui again if the window changed.") }
            entry = found
        } else if !id.isEmpty {
            guard let found = map?.entries[id] else { return fail("There's no \(id) in the last petal_ui. Call petal_ui again.") }
            entry = found
        }
        // Which app: the control's; for a menu or a key, `app`, else the last petal_ui's, else what's in front.
        let named = (args["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        var target: NSRunningApplication?
        var window: AXUIElement?
        var windowFrame = CGRect.zero
        if let map, entry != nil || named.isEmpty {
            target = NSRunningApplication(processIdentifier: map.pid)
            // Only an act on a control checks its window: a menu or a key doesn't care where the window is.
            if entry != nil {
                window = map.window
                windowFrame = map.windowFrame
            }
        } else {
            target = assist.frontApp(named: named)
        }
        guard let target, !target.isTerminated else {
            return fail(named.isEmpty && map == nil ? "Nothing's in front." : "\(named.isEmpty ? map?.appName ?? "That app" : named) isn't open.")
        }
        let name = target.localizedName ?? named
        let bundle = target.bundleIdentifier ?? "\(target.processIdentifier)"
        guard !assist.neverLook(bundle) else { return fail("The user keeps \(name) private: Petal doesn't use it for them.") }

        var options = Acting.Options()
        options.text = args["text"] as? String ?? ""
        options.replace = args["replace"] as? Bool ?? true
        options.submit = args["submit"] as? Bool ?? false
        options.direction = (args["direction"] as? String ?? "").lowercased()
        let thing = entry.map { UIMap.name($0.node) } ?? ""
        let kind = entry.map { UIMap.kind($0.node) } ?? "app"
        var caption = UIMap.caption(action, name: thing, kind: kind)
        switch action {
        case "type":
            guard !options.text.isEmpty else { return fail("Give the text to type.") }
            if let entry, UIMap.isSecure(entry.node) {
                return fail("That's a password field: Petal never types into those for you. Use petal_vault (action: use) to type a saved secret, or ask the person.")
            }
        case "scroll":
            guard ["", "up", "down", "left", "right"].contains(options.direction) else { return fail("direction is up, down, left or right (or none, to bring the control into view).") }
        case "menu":
            options.path = UIMap.menuPath(args["path"] as? String ?? args["menu"] as? String ?? "")
            guard options.path.count >= 2 else { return fail("Give the menu path, like “File > Export…”.") }
            caption = UIMap.caption("menu", name: options.path.joined(separator: " › "), kind: "menu")
        case "key":
            guard let key = UIMap.parseKey(args["key"] as? String ?? "") else {
                return fail("key is one key with modifiers, like cmd-s, cmd-shift-z, return, escape, tab or down.")
            }
            options.key = key
            caption = UIMap.caption("key", name: "", kind: "", key: key.label)
        default: break
        }

        let job = Job(caller: caller, action: action, entry: entry, pid: target.processIdentifier, appName: name, window: window,
                      windowFrame: windowFrame, caption: caption, options: options, send: send, fail: fail)
        if session(caller).apps.contains(bundle) { return enqueue(job) }
        let first = caption.prefix(1).lowercased() + caption.dropFirst()
        assist.ask("computer:\(bundle)", "Let Petal AI use \(name)?",
                   detail: "First, \(first). Until this reply is done it can press, type and choose menus in \(name) with its own pointer; yours stays where it is. Esc stops it.") { allowed in
            guard allowed else {
                return send(["declined": "The person didn't let Petal AI use \(name). Don't find another way; say what you would have done."])
            }
            self.sessions[caller]?.apps.insert(bundle)
            guard self.app.config.bool("computerUse"), !self.session(caller).stopped else { return fail(Self.stoppedText) }
            self.enqueue(job)
        }
    }

    /// The chat's reply this is part of: a Petal chat's turn, or (an AI session outside Petal) five quiet minutes.
    private func session(_ caller: String) -> Session {
        let agent = caller.isEmpty ? nil : app.claude.note(withID: caller)?.agent
        let turn = agent.map { "\(caller)#\($0.turn)" } ?? "\(caller)#other"
        if let session = sessions[caller], session.turn == turn, agent != nil || Date().timeIntervalSince(session.last) < 300 {
            return session
        }
        let fresh = Session(turn: turn)
        sessions[caller] = fresh
        return fresh
    }

    private func enqueue(_ job: Job) {
        line.append(job)
        next()
    }

    private func next() {
        guard !busy, !line.isEmpty else { return }
        let job = line.removeFirst()
        if session(job.caller).stopped { job.fail(Self.stoppedText); return next() }
        busy = true
        run(job)
    }

    private func finished() {
        busy = false
        acting = nil
        next()
    }

    /// Checks the window and control are where the map said, glides the cursor there, then does it, off the main
    /// thread; the reply goes back to the chat.
    private func run(_ job: Job) {
        let cancel = Acting.Cancel()
        acting = (job.caller, cancel)
        lastCaller = job.caller
        sessions[job.caller]?.last = Date()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == job.pid
        Self.queue.async {
            let prepared = Acting.prepare(job.action, entry: job.entry, pid: job.pid, window: job.window, windowFrame: job.windowFrame, options: job.options)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if cancel.stopped { job.fail(Self.stoppedText); return self.finished() }
                    if let error = prepared.error { job.fail(error); return self.finished() }
                    self.cursor.glide(to: Self.screenPoint(prepared.spot), caption: job.caption)
                    DispatchQueue.main.asyncAfter(deadline: .now() + FakeCursor.glide + 0.03) {
                        if cancel.stopped { job.fail(Self.stoppedText); return self.finished() }
                        if ["press", "menu"].contains(job.action) || (job.action == "key" && prepared.menuItem != nil) { self.cursor.press() }
                        Self.queue.async {
                            let outcome = Acting.perform(job.action, entry: job.entry, pid: job.pid, front: front, prepared: prepared,
                                                         options: job.options, cancel: cancel)
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated { self.done(job, outcome, cancel) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func done(_ job: Job, _ outcome: Acting.Outcome, _ cancel: Acting.Cancel) {
        cursor.rest()
        defer { finished() }
        if cancel.stopped { return job.fail(Self.stoppedText) }
        if let error = outcome.error { return job.fail(error) }
        assist.did(historyLine(job, outcome))
        var reply: [String: Any] = ["done": job.caption, "app": job.appName]
        if let value = outcome.value { reply["value"] = value }
        if let chose = outcome.chose { reply["chose"] = chose }
        if let note = outcome.note { reply["note"] = note }
        if ["press", "menu", "key"].contains(job.action) || job.options.submit {
            reply["next"] = "The window may have changed: call petal_ui again before using more ids."
        }
        job.send(reply)
    }

    /// What it did, for Settings › AI (never what it typed: that may be private).
    private func historyLine(_ job: Job, _ outcome: Acting.Outcome) -> String {
        let thing = job.entry.map { UIMap.name($0.node) }.flatMap { $0.isEmpty ? nil : "“\($0)”" } ?? "a control"
        switch job.action {
        case "press": return "Pressed \(thing) in \(job.appName)"
        case "type": return "Typed into \(thing) in \(job.appName)"
        case "focus": return "Went to \(thing) in \(job.appName)"
        case "scroll": return "Scrolled in \(job.appName)"
        case "menu": return "Chose \(outcome.chose ?? job.options.path.joined(separator: " › ")) in \(job.appName)"
        default:
            let key = job.options.key?.label ?? "a key"
            return "Pressed \(key)\(outcome.chose.map { " (\($0))" } ?? "") in \(job.appName)"
        }
    }

    /// The person pressed Stop or Escape: the action under way and the rest of that reply's are cancelled.
    func stop() {
        let caller = acting?.caller ?? lastCaller
        acting?.cancel.stop()
        cursor.hide()
        guard let caller else { return }
        sessions[caller]?.stopped = true
        let waiting = line.filter { $0.caller == caller }
        line.removeAll { $0.caller == caller }
        for job in waiting { job.fail(Self.stoppedText) }
        if !caller.isEmpty, let agent = app.claude.note(withID: caller)?.agent, agent.running { agent.personStopped() }
    }

    /// Accessibility's top-left point as AppKit's (bottom-left, from the main screen).
    static func screenPoint(_ point: CGPoint) -> CGPoint {
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: height - point.y)
    }
}

// MARK: - Reading a window

/// A window's controls through Accessibility, off the main thread, within a time budget.
enum Reader {
    struct Reading {
        var title = ""
        var window: AXUIElement?
        var windowFrame = CGRect.zero
        var nodes: [UINode] = []
        var elements: [Int: AXUIElement] = [:]   // by the node's order
        var gone = false
        var timedOut = false
    }

    static let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                             kAXPlaceholderValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute]
    /// Controls whose insides are only their own label: not walked into.
    static let leaves: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXSlider", "AXLink",
                                      "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXIncrementor", "AXColorWell", "AXSearchField", "AXImage"]

    static func read(pid: pid_t, window wanted: UInt32?, budget: TimeInterval) -> Reading {
        var reading = Reading()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var window: AXUIElement? = Windows.value(app, kAXFocusedWindowAttribute) ?? Windows.value(app, kAXMainWindowAttribute)
        let all: [AXUIElement] = Windows.value(app, kAXWindowsAttribute) ?? []
        if let wanted, window.flatMap({ Windows.id(of: $0) }) != wanted {
            guard let match = all.first(where: { Windows.id(of: $0) == wanted }) else { reading.gone = true; return reading }
            window = match
        }
        guard let window = window ?? all.first else { return reading }
        reading.window = window
        reading.title = Windows.value(window, kAXTitleAttribute) ?? ""
        reading.windowFrame = Windows.frame(of: window) ?? .zero

        let deadline = Date().addingTimeInterval(budget)
        var stack: [(element: AXUIElement, depth: Int, clip: CGRect?, web: Bool)] = [(window, 0, nil, false)]
        var order = 0
        var visited = 0
        while let (element, depth, clip, web) = stack.popLast() {
            if visited >= 5000 || Date() > deadline { reading.timedOut = true; break }
            visited += 1
            let values = Self.values(element, attributes)
            let role = values[kAXRoleAttribute] as? String ?? ""
            var node = UINode(role: role)
            node.subrole = values[kAXSubroleAttribute] as? String ?? ""
            node.title = String((values[kAXTitleAttribute] as? String ?? "").prefix(200))
            node.label = String((values[kAXDescriptionAttribute] as? String ?? "").prefix(200))
            node.help = String((values[kAXHelpAttribute] as? String ?? "").prefix(200))
            node.placeholder = String((values[kAXPlaceholderValueAttribute] as? String ?? "").prefix(200))
            node.frame = frame(values[kAXPositionAttribute], values[kAXSizeAttribute])
            node.enabled = (values[kAXEnabledAttribute] as? Bool) ?? true
            node.focused = (values[kAXFocusedAttribute] as? Bool) ?? false
            node.web = web
            node.clip = clip
            node.order = order
            // A password field's value is never read.
            if UIMap.valueRoles.contains(role), !UIMap.isSecure(node) {
                node.value = text(Windows.value(element, kAXValueAttribute) as CFTypeRef?)
            }
            if UIMap.pressableRoles.contains(role), depth > 0, !UIMap.name(node).isEmpty {
                node.pressable = actions(element).contains(kAXPressAction as String)
            }
            if UIMap.isActionable(node) {
                reading.nodes.append(node)
                reading.elements[order] = element
            }
            order += 1
            guard depth < 40, !leaves.contains(role) else { continue }
            var inner = clip
            if role == "AXScrollArea", node.frame.width > 0 { inner = clip.map { $0.intersection(node.frame) } ?? node.frame }
            // Long tables and lists: only the rows showing.
            let children: [AXUIElement]
            if ["AXTable", "AXOutline", "AXList", "AXBrowser"].contains(role) {
                children = Windows.value(element, "AXVisibleRows") ?? Windows.value(element, "AXVisibleChildren") ?? Windows.value(element, kAXChildrenAttribute) ?? []
            } else {
                children = Windows.value(element, kAXChildrenAttribute) ?? []
            }
            for child in children.prefix(500).reversed() { stack.append((child, depth + 1, inner, web || role == "AXWebArea")) }
        }
        return reading
    }

    /// Several attributes in one message to the app (one round trip, not ten).
    static func values(_ element: AXUIElement, _ names: [String]) -> [String: Any] {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let list = raw as? [AnyObject] else { return [:] }
        var out: [String: Any] = [:]
        for (name, value) in zip(names, list) {
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
            out[name] = value
        }
        return out
    }

    static func frame(_ position: Any?, _ size: Any?) -> CGRect {
        guard let position, let size, CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(), CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else { return .zero }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    static func text(_ value: CFTypeRef?) -> String {
        switch value {
        case let string as String: return String(string.prefix(400))
        case let number as NSNumber: return number.stringValue
        default: return ""
        }
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }
}

// MARK: - Doing it

/// Each action, off the main thread, through Accessibility or keystrokes posted to the app's process. Never the
/// pointer.
enum Acting {
    struct Options {
        var text = ""
        var replace = true
        var submit = false
        var direction = ""
        var path: [String] = []
        var key: UIMap.Key?
    }

    struct Prepared {
        var error: String?
        var spot = CGPoint.zero          // where the cursor goes (Accessibility's top-left coordinates)
        var menuItem: AXUIElement?       // a menu's item, or a key's menu equivalent
        var menuTitle: String?
    }

    struct Outcome {
        var error: String?
        var value: String?
        var chose: String?
        var note: String?
    }

    /// Stop, seen at once from any thread.
    final class Cancel: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var stopped: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func stop() { lock.lock(); flag = true; lock.unlock() }
    }

    static let changed = "Call petal_ui again for fresh ids."

    /// The window is still there and where the map said; so is the control. Then where the cursor goes, and for a
    /// menu, its item.
    static func prepare(_ action: String, entry: ComputerUse.Entry?, pid: pid_t, window: AXUIElement?, windowFrame: CGRect,
                        options: Options) -> Prepared {
        var prepared = Prepared()
        if let window {
            guard let now = Windows.frame(of: window), now.width > 0 else {
                prepared.error = "The window is gone (closed, or its app quit). " + changed
                return prepared
            }
            if UIMap.moved(now, windowFrame) {
                prepared.error = "The window moved or changed size since petal_ui. " + changed
                return prepared
            }
            prepared.spot = CGPoint(x: now.midX, y: now.minY + 14)
        }
        if let entry {
            var role: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(entry.element, kAXRoleAttribute as CFString, &role)
            if result == .invalidUIElement || role == nil {
                prepared.error = "That control isn't there anymore: the window changed. " + changed
                return prepared
            }
            let frame = Windows.frame(of: entry.element) ?? .zero
            if UIMap.moved(frame, entry.node.frame) {
                prepared.error = "That control moved: the window changed since petal_ui. " + changed
                return prepared
            }
            if frame.width > 0 { prepared.spot = CGPoint(x: frame.midX, y: frame.midY) }
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if window == nil, entry == nil, let front: AXUIElement = Windows.value(app, kAXFocusedWindowAttribute) ?? Windows.value(app, kAXMainWindowAttribute),
           let frame = Windows.frame(of: front) {
            prepared.spot = CGPoint(x: frame.midX, y: frame.minY + 14)
        }
        switch action {
        case "menu":
            let found = menuItem(app, path: options.path)
            if let error = found.error { prepared.error = error; return prepared }
            prepared.menuItem = found.item
            prepared.menuTitle = found.title
            if let bar = found.bar, bar.width > 0 { prepared.spot = CGPoint(x: bar.midX, y: bar.midY) }
        case "key", "type":
            // Never into a password field: the one asked for, or (with none asked for) what has the cursor now.
            let secure = { (element: AXUIElement) in (Windows.value(element, kAXSubroleAttribute) as String?) == "AXSecureTextField" }
            if let entry, UIMap.isSecure(entry.node) || secure(entry.element) {
                prepared.error = "That's a password field: Petal doesn't type there. petal_vault types a saved secret."
                return prepared
            }
            if entry == nil, let focused: AXUIElement = Windows.value(app, kAXFocusedUIElementAttribute), secure(focused) {
                prepared.error = "A password field has the cursor: Petal doesn't type there. petal_vault types a saved secret."
                return prepared
            }
            if action == "key", let key = options.key, key.command, let found = menuEquivalent(app, key) {
                prepared.menuItem = found.item
                prepared.menuTitle = found.title
            }
        default: break
        }
        return prepared
    }

    static func perform(_ action: String, entry: ComputerUse.Entry?, pid: pid_t, front: Bool, prepared: Prepared, options: Options,
                        cancel: Cancel) -> Outcome {
        var outcome = Outcome()
        let element = entry?.element
        let name = entry.map { UIMap.name($0.node) }.flatMap { $0.isEmpty ? nil : "“\($0)”" } ?? "That control"
        switch action {
        case "press":
            guard let element else { break }
            let actions = Reader.actions(element)
            if let done = ["AXPress", "AXPick", "AXConfirm", "AXOpen"].first(where: actions.contains),
               AXUIElementPerformAction(element, done as CFString) == .success {
                break
            }
            if ["AXRow", "AXCell", "AXTab", "AXRadioButton"].contains(entry?.node.role ?? ""),
               AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success {
                break
            }
            outcome.error = "\(name) can't be pressed through Accessibility. Only a real click would do it, and Petal never moves the person's pointer: ask them to click it, or try a menu item or a key."
        case "focus":
            guard let element else { break }
            if AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) != .success,
               AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) != .success {
                outcome.error = "\(name) can't take the focus through Accessibility."
            }
        case "type":
            guard let element, let node = entry?.node else { break }
            if Assist.isVaultSecret(options.text) {
                outcome.error = "That's one of the vault's secrets: petal_vault types it, after asking."
                break
            }
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            var typed = false
            // A native field takes its new value directly; a web page's needs keys, so its page hears them.
            if !node.web, UIMap.isText(node) {
                var settable: DarwinBoolean = false
                let attribute = options.replace ? kAXValueAttribute : kAXSelectedTextAttribute
                if AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success, settable.boolValue,
                   AXUIElementSetAttributeValue(element, attribute as CFString, options.text as CFString) == .success {
                    let now = Reader.text(Windows.value(element, kAXValueAttribute) as CFTypeRef?)
                    typed = now.contains(String(options.text.prefix(400)))
                }
            }
            if !typed {
                if !front { bringForward(pid) }
                if cancel.stopped { break }
                // Keys go wherever the cursor is: only into this field, never (with ⌘A) over a whole document.
                AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                guard hasFocus(element, pid: pid) else {
                    outcome.error = "Couldn't put the cursor in \(name) through Accessibility; only a real click would. Ask the person to click into it."
                    break
                }
                if options.replace, let all = UIMap.parseKey("cmd-a") { post(all, to: pid) }
                if !type(options.text, to: pid, cancel: cancel) { break }
            }
            if options.submit, !cancel.stopped, let enter = UIMap.parseKey("return") {
                if typed, !front { bringForward(pid) }
                post(enter, to: pid)
            }
            usleep(120_000)
            let now = Reader.text(Windows.value(element, kAXValueAttribute) as CFTypeRef?)
            if !now.isEmpty, !options.submit { outcome.value = UIMap.truncate(UIMap.tidy(now), 200) }
            if !typed, !front { outcome.note = "\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "The app") came to the front to take the keys." }
        case "scroll":
            guard let element else { break }
            if options.direction.isEmpty {
                if AXUIElementPerformAction(element, "AXScrollToVisible" as CFString) != .success {
                    outcome.error = "\(name) can't be scrolled into view through Accessibility; give a direction instead."
                }
            } else if let error = scroll(element, options.direction) {
                outcome.error = error
            }
        case "menu":
            guard let item = prepared.menuItem else { break }
            if AXUIElementPerformAction(item, kAXPressAction as CFString) != .success {
                outcome.error = "Couldn't choose \(prepared.menuTitle ?? "that item"); its app didn't answer."
            }
            outcome.chose = prepared.menuTitle
        case "key":
            guard let key = options.key else { break }
            if let element { AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
            // A shortcut its menus have is chosen there (any app, in front or not); otherwise the key itself.
            if let item = prepared.menuItem, AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                outcome.chose = prepared.menuTitle
                break
            }
            if !front { bringForward(pid); outcome.note = "\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "The app") came to the front to take the key." }
            if !cancel.stopped { post(key, to: pid) }
        default: break
        }
        return outcome
    }

    /// The control has the keyboard's focus: it says so, or it's what its app says is focused.
    static func hasFocus(_ element: AXUIElement, pid: pid_t) -> Bool {
        if (Windows.value(element, kAXFocusedAttribute) as Bool?) == true { return true }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let focused: AXUIElement = Windows.value(app, kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(focused, element)
    }

    // MARK: Menus

    static func children(_ element: AXUIElement) -> [AXUIElement] { Windows.value(element, kAXChildrenAttribute) ?? [] }
    static func title(_ element: AXUIElement) -> String { Windows.value(element, kAXTitleAttribute) ?? "" }

    /// The item at `path` in the app's menu bar, the frame of its menu's title, and its whole title.
    static func menuItem(_ app: AXUIElement, path: [String]) -> (item: AXUIElement?, bar: CGRect?, title: String?, error: String?) {
        guard let bar: AXUIElement = Windows.value(app, kAXMenuBarAttribute) else { return (nil, nil, nil, "This app has no menus Petal can reach.") }
        let tops = children(bar)
        guard let top = tops.first(where: { UIMap.sameTitle(title($0), path[0]) }) else {
            let names = tops.dropFirst().map(title).filter { !$0.isEmpty }
            return (nil, nil, nil, "There's no “\(path[0])” menu. The menus are: \(names.joined(separator: ", ")).")
        }
        var current = top
        var walked = [title(top)]
        for name in path.dropFirst() {
            let items = children(current).first { (Windows.value($0, kAXRoleAttribute) as String?) == "AXMenu" }.map(children) ?? []
            guard let match = items.first(where: { UIMap.sameTitle(title($0), name) }) else {
                let names = items.map(title).filter { !$0.isEmpty }.prefix(30)
                return (nil, nil, nil, "There's no “\(name)” in \(walked.joined(separator: " › ")). It has: \(names.joined(separator: ", ")).")
            }
            current = match
            walked.append(title(match))
        }
        if (Windows.value(current, kAXEnabledAttribute) as Bool?) == false {
            return (nil, nil, nil, "\(walked.joined(separator: " › ")) is greyed out right now.")
        }
        return (current, Windows.frame(of: top), walked.joined(separator: " › "), nil)
    }

    /// The enabled menu item whose shortcut is this key, if the app's menus have one.
    static func menuEquivalent(_ app: AXUIElement, _ key: UIMap.Key) -> (item: AXUIElement, title: String)? {
        guard let character = key.character, let bar: AXUIElement = Windows.value(app, kAXMenuBarAttribute) else { return nil }
        func find(_ element: AXUIElement, depth: Int, path: [String]) -> (AXUIElement, String)? {
            guard depth < 4 else { return nil }
            for child in children(element) {
                let name = title(child)
                if let char: String = Windows.value(child, kAXMenuItemCmdCharAttribute), char.uppercased() == character.uppercased(),
                   let modifiers: Int = Windows.value(child, kAXMenuItemCmdModifiersAttribute), modifiers == key.menuModifiers,
                   (Windows.value(child, kAXEnabledAttribute) as Bool?) != false {
                    return (child, (path + [name]).filter { !$0.isEmpty }.joined(separator: " › "))
                }
                if let found = find(child, depth: depth + 1, path: name.isEmpty ? path : path + [name]) { return found }
            }
            return nil
        }
        for menu in children(bar).dropFirst() {   // the first is the app's own menu (About, Quit)
            if let found = find(menu, depth: 0, path: []) { return (found.0, found.1) }
        }
        return nil
    }

    // MARK: Keys

    /// One key, down and up, to the app's own process: the person's keyboard and pointer aren't involved.
    static func post(_ key: UIMap.Key, to pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: down) else { continue }
            event.flags = key.flags
            if let character = key.character {
                let units = Array(character.utf16)
                units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
            }
            event.postToPid(pid)
        }
    }

    /// Text as keystrokes to the app's process, a few characters at a time; false when stopped part way.
    static func type(_ text: String, to pid: pid_t, cancel: Cancel) -> Bool {
        let source = CGEventSource(stateID: .privateState)
        var rest = Array(text.utf16)
        while !rest.isEmpty {
            if cancel.stopped { return false }
            let chunk = Array(rest.prefix(16))
            rest.removeFirst(chunk.count)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                chunk.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                event?.postToPid(pid)
            }
            usleep(8_000)
        }
        return true
    }

    /// Keys only reach the app in front: this one comes forward first (through Accessibility; the pointer stays).
    static func bringForward(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        usleep(150_000)
    }

    // MARK: Scrolling

    /// Moves the scroll area around `element` (or it) by most of a page, through its scroll bar's value.
    static func scroll(_ element: AXUIElement, _ direction: String) -> String? {
        var area: AXUIElement? = element
        for _ in 0..<8 {
            guard let current = area else { break }
            if (Windows.value(current, kAXRoleAttribute) as String?) == "AXScrollArea" { break }
            area = Windows.value(current, kAXParentAttribute)
        }
        guard let area, (Windows.value(area, kAXRoleAttribute) as String?) == "AXScrollArea" else {
            return "That control isn't in anything that scrolls."
        }
        let vertical = direction == "up" || direction == "down"
        guard let bar: AXUIElement = Windows.value(area, vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute) else {
            return "It doesn't scroll \(vertical ? "up and down" : "sideways")."
        }
        let current = (Windows.value(bar, kAXValueAttribute) as NSNumber?)?.doubleValue ?? 0
        // Most of a page: how much shows of the whole, from the area and what's in it.
        let shown = Windows.frame(of: area) ?? .zero
        let content = children(area).compactMap { child -> CGRect? in
            (Windows.value(child, kAXRoleAttribute) as String?) == "AXScrollBar" ? nil : Windows.frame(of: child)
        }.max { ($0.width * $0.height) < ($1.width * $1.height) } ?? .zero
        let page = vertical ? shown.height : shown.width
        let whole = vertical ? content.height : content.width
        let step = whole > page + 1 ? min(1, max(0.02, 0.8 * page / (whole - page))) : 0.25
        let next = min(1, max(0, current + (direction == "down" || direction == "right" ? step : -step)))
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
           AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: next)) == .success {
            return nil
        }
        let action = direction == "down" || direction == "right" ? kAXIncrementAction : kAXDecrementAction
        if AXUIElementPerformAction(bar, action as CFString) == .success { return nil }
        return "That area can't be scrolled through Accessibility; only the person's own scrolling would do it."
    }
}

// MARK: - The fake cursor

/// Petal AI's own pointer: a soft pink arrow over everything, letting every click through, on every Space. It
/// glides to each control before the action, with a small ripple on a press, a glass chip saying what it's doing
/// with Stop beside it, and fades a few seconds after the last action. Core Animation moves it; the main thread
/// only sets where it goes.
@MainActor
final class FakeCursor {
    static let pink = NSColor(red: 0xd9 / 255, green: 0x36 / 255, blue: 0x7f / 255, alpha: 1)
    static let glide: TimeInterval = 0.35
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))

    var onStop: (() -> Void)?
    private var panel: NSPanel?
    private var pill: GlassPanel?
    private let pointer = CALayer()
    private var fade: DispatchWorkItem?
    private var monitors: [Any] = []
    private(set) var showing = false

    /// Glides to `point` (AppKit's screen coordinates) and says what it's doing.
    func glide(to point: CGPoint, caption: String) {
        fade?.cancel()
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
        let panel = self.panel ?? make()
        var fresh = !showing
        if panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: false)
            fresh = true
        }
        let target = CGPoint(x: point.x - screen.frame.minX, y: point.y - screen.frame.minY)
        let from = fresh ? CGPoint(x: target.x - 44, y: target.y + 32) : (pointer.presentation()?.position ?? pointer.position)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.position = target
        pointer.opacity = 1
        CATransaction.commit()
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: from)
        move.toValue = NSValue(point: target)
        move.duration = Self.glide
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
        pointer.add(move, forKey: "glide")
        if fresh {
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = 0.2
            pointer.add(appear, forKey: "appear")
        }
        if !showing {
            showing = true
            panel.orderFrontRegardless()
            listen()
        }
        // The chip follows once the cursor is there.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.glide) { [weak self] in
            guard let self, self.showing else { return }
            self.showPill(caption, at: point, on: screen)
        }
    }

    /// A small ripple at the tip: a press.
    func press() {
        guard showing else { return }
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -16, y: -16, width: 32, height: 32), transform: nil)
        ring.fillColor = Self.pink.withAlphaComponent(0.16).cgColor
        ring.strokeColor = Self.pink.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 1.5
        ring.position = pointer.position
        ring.contentsScale = panel?.backingScaleFactor ?? 2
        ring.opacity = 0
        pointer.superlayer?.insertSublayer(ring, below: pointer)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.35
        grow.toValue = 1.3
        let vanish = CABasicAnimation(keyPath: "opacity")
        vanish.fromValue = 0.9
        vanish.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, vanish]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
        let dip = CAKeyframeAnimation(keyPath: "transform.scale")
        dip.values = [1, 0.86, 1]
        dip.duration = 0.22
        pointer.add(dip, forKey: "dip")
    }

    /// The last action is done: it fades a few seconds later, unless another comes.
    func rest() {
        fade?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    /// Gone at once (Stop).
    func hide() {
        fade?.cancel()
        fade = nil
        guard showing else { return }
        showing = false
        pill?.hide()
        unlisten()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.opacity = 0
        CATransaction.commit()
        panel?.orderOut(nil)
    }

    private func fadeOut() {
        guard showing else { return }
        pill?.hide()
        unlisten()
        showing = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.showing else { return }
                self.panel?.orderOut(nil)
            }
        }
        let vanish = CABasicAnimation(keyPath: "opacity")
        vanish.fromValue = 1
        vanish.toValue = 0
        vanish.duration = 0.4
        pointer.opacity = 0
        pointer.add(vanish, forKey: "fade")
        CATransaction.commit()
    }

    private func showPill(_ caption: String, at point: CGPoint, on screen: NSScreen) {
        let pill = self.pill ?? {
            let made = GlassPanel(level: NSWindow.Level(rawValue: Self.level.rawValue + 1))
            made.collectionBehavior.insert(.fullScreenAuxiliary)
            self.pill = made
            return made
        }()
        pill.show(ActingPill(caption: caption) { [weak self] in self?.onStop?() }, near: point, on: screen)
    }

    /// Escape stops it, wherever the keyboard is (Petal's own windows included).
    private func listen() {
        guard monitors.isEmpty else { return }
        let escape: (NSEvent) -> Bool = { [weak self] event in
            guard event.keyCode == 53 else { return false }
            MainActor.assumeIsolated { self?.onStop?() }
            return true
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = escape($0) }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { escape($0) ? nil : $0 }) { monitors.append(local) }
    }

    private func unlisten() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func make() -> NSPanel {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = Self.level
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = LayerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        Self.build(pointer, scale: screen.backingScaleFactor)
        pointer.opacity = 0
        view.layer?.addSublayer(pointer)
        self.panel = panel
        return panel
    }

    /// The pointer's layers: an arrow in Petal's pink with a white edge and a soft pink glow, its tip at (0, 0).
    static func build(_ pointer: CALayer, scale: CGFloat) {
        pointer.bounds = .zero
        pointer.anchorPoint = .zero
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: -19), CGPoint(x: 4.8, y: -14.6), CGPoint(x: 8, y: -21.6),
                                CGPoint(x: 11.4, y: -20.1), CGPoint(x: 8.3, y: -13.4), CGPoint(x: 14.4, y: -13.4)])
        path.closeSubpath()
        let glow = CAShapeLayer()
        glow.path = path
        glow.fillColor = pink.withAlphaComponent(0.55).cgColor
        glow.shadowColor = pink.cgColor
        glow.shadowOpacity = 0.9
        glow.shadowRadius = 9
        glow.shadowOffset = .zero
        let arrow = CAShapeLayer()
        arrow.path = path
        arrow.fillColor = pink.cgColor
        arrow.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        arrow.lineWidth = 1.4
        arrow.lineJoin = .round
        arrow.shadowColor = NSColor.black.cgColor
        arrow.shadowOpacity = 0.25
        arrow.shadowRadius = 2
        arrow.shadowOffset = CGSize(width: 0, height: -1)
        for layer in [glow, arrow] {
            layer.contentsScale = scale
            pointer.addSublayer(layer)
        }
    }

    /// The pointer as a picture, for `Petal --snapshot`.
    static func picture() -> NSImage? {
        let size = CGSize(width: 64, height: 64)
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        let pointer = CALayer()
        build(pointer, scale: 2)
        pointer.position = CGPoint(x: 22, y: 46)
        root.addSublayer(pointer)
        guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2)
        root.render(in: context)
        return context.makeImage().map { NSImage(cgImage: $0, size: size) }
    }
}

/// The glass chip by the fake cursor: what Petal AI is doing, and Stop (or Escape).
struct ActingPill: View {
    let caption: String
    let stop: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(Color(nsColor: FakeCursor.pink)).frame(width: 7, height: 7)
            Text(caption).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .leading).fixedSize()
            Button(action: stop) {
                HStack(spacing: 5) {
                    Text("Stop").font(.system(size: 12, weight: .semibold))
                    Text("esc").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(hovering ? .clear.tint(Color(nsColor: FakeCursor.pink)).interactive() : .clear.interactive(), in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .padding(6)
    }
}
