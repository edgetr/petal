import AppKit
import Observation
import ScreenCaptureKit

/// Petal AI's own powers on the Mac. Claude Code and Codex reach them through Petal's tools (`petal_look`,
/// `petal_apps`, `petal_windows`, `petal_trash`, `petal_remember`, `petal_forget`, `petal_memories`), which the
/// running Petal answers over its socket: Petal holds the Mac's permissions (Accessibility, Screen Recording, each
/// browser's Automation), so the AI never needs them itself.
///
/// Looking is free. Anything that changes something asks first, with a card in the dock's style (Allow once,
/// Always, Don't), unless the chat has Full access or the person said Always for that kind of thing. Files go to the
/// Trash, never away for good, and the last batch can be put back.
///
/// It also remembers (per mode, or everywhere): what the person says to remember, what the AI notices on its own,
/// and once a day what it learns from how each mode is used (`aiLearns`). And at `dailySummary` it shows the day.
@MainActor @Observable
final class Assist {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let kind: String      // what Always remembers: "quit", "close", "trash"
        let title: String     // "Quit Spotify"
        let detail: String    // a line more, or ""
    }

    struct Memory: Identifiable, Equatable {
        let id: String
        var text: String
        var mode: String      // a mode's id, or "" for everywhere
        var learned: Bool     // noticed by Petal AI rather than asked for
        var at: Date
    }

    private(set) var pending: Request?
    private(set) var memories: [Memory] = []
    @ObservationIgnored private var answer: ((Bool) -> Void)?
    @ObservationIgnored private var giveUp: DispatchWorkItem?
    @ObservationIgnored private var trashed: [(from: URL, to: URL)] = []
    @ObservationIgnored private var timer: Timer?
    nonisolated private static let queue = DispatchQueue(label: "petal.assist", qos: .userInitiated, attributes: .concurrent)

    var app: PetalApp { PetalApp.shared }
    var config: Config { app.config }

    func start() {
        loadMemories()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.minute() }
        }
    }

    // MARK: Asking first

    enum Choice { case once, always, no }

    /// Allowed already (Full access, or Always for this kind), or asked with a card; `done` hears the answer.
    func ask(_ kind: String, _ title: String, detail: String = "", done: @escaping (Bool) -> Void) {
        if config.string("claudeAccess") == "full" || config.strings("aiAllowed").contains(kind) { return done(true) }
        settle(false)   // one question at a time: a newer one replaces an older one, which is declined
        let request = Request(kind: kind, title: title, detail: detail)
        pending = request
        answer = done
        // In the chat when it's open (the card shows there); over the dock otherwise (another AI session asking).
        if !app.claude.isOpen { app.popups.show(FocusCard(kind: .ask, title: title, reason: detail)) }
        let work = DispatchWorkItem { [weak self] in self?.settle(false) }
        giveUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
    }

    func choose(_ choice: Choice) {
        guard let pending else { return }
        if choice == .always {
            var allowed = config.strings("aiAllowed")
            if !allowed.contains(pending.kind) { allowed.append(pending.kind); config.set("aiAllowed", allowed) }
        }
        settle(choice != .no)
    }

    private func settle(_ allowed: Bool) {
        giveUp?.cancel()
        giveUp = nil
        let done = answer
        answer = nil
        let asked = pending != nil
        pending = nil
        if asked, app.popups.card?.kind == .ask { app.popups.dismissCard() }
        done?(allowed)
    }

    /// The card went away without an answer (×, Escape, another card): that's Don't.
    func cardClosed() {
        if pending != nil { settle(false) }
    }

    // MARK: The tools

    /// One of Petal AI's tools, from `Petal --mcp` (["assist", name, json]); the reply is one line of JSON.
    func handle(_ name: String, _ json: String, reply: @escaping @MainActor (String) -> Void) {
        let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        let send: (Any) -> Void = { result in
            let object: Any = JSONSerialization.isValidJSONObject(result) ? result : ["result": "\(result)"]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
            reply(String(decoding: data, as: UTF8.self))
        }
        let fail = { (text: String) in send(["error": text]) }
        switch name {
        case "petal_look": look(args, send)
        case "petal_apps": apps(args, send, fail)
        case "petal_windows": windows(args, send, fail)
        case "petal_trash": trash(args, send, fail)
        case "petal_remember":
            guard config.bool("aiMemory") else { return fail("Memory is off in Petal's settings (aiMemory).") }
            let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return fail("Nothing to remember.") }
            let memory = remember(text, mode: args["mode"] as? String ?? "", learned: args["learned"] as? Bool ?? false)
            send(["remembered": memory.text, "id": memory.id, "mode": memory.mode.isEmpty ? "everywhere" : memory.mode])
        case "petal_forget":
            let gone = forget(id: args["id"] as? String, matching: args["text"] as? String)
            send(["forgot": gone.map(\.text)])
        case "petal_memories":
            let mode = args["mode"] as? String
            send(["memories": memories.filter { mode == nil || $0.mode == mode || $0.mode.isEmpty }.map(record)])
        default:
            fail("Unknown tool \(name)")
        }
    }

    // MARK: Looking

    /// What's in front: the app, its window, the browser's tab, selected text, the mode, the other windows showing;
    /// with `screenshot` ("window" or "screen") a picture saved where the AI can read it, and the clipboard if asked.
    private func look(_ args: [String: Any], _ send: @escaping (Any) -> Void) {
        let front = frontApp(named: args["app"] as? String)
        var result: [String: Any] = [:]
        if let mode = app.docks.focusedDock?.mode { result["mode"] = ["id": mode.id, "name": mode.name] }
        result["onScreen"] = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isHidden }
            .compactMap(\.localizedName)).sorted()
        if args["clipboard"] as? Bool == true { result["clipboard"] = NSPasteboard.general.string(forType: .string).map { String($0.prefix(4000)) } ?? "" }
        guard let front else { return send(result) }
        result["app"] = ["name": front.localizedName ?? "", "id": front.bundleIdentifier ?? ""]
        let pid = front.processIdentifier
        let shot = args["screenshot"] as? String ?? ((args["screenshot"] as? Bool) == true ? "window" : "")
        Self.queue.async {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.3)
            let window: AXUIElement? = Windows.value(element, kAXFocusedWindowAttribute)
            let title: String = window.flatMap { Windows.value($0, kAXTitleAttribute) } ?? ""
            let focused: AXUIElement? = Windows.value(element, kAXFocusedUIElementAttribute)
            let selected: String = focused.flatMap { Windows.value($0, kAXSelectedTextAttribute) } ?? ""
            let number = window.flatMap { Windows.id(of: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    result["window"] = title
                    if !selected.isEmpty { result["selectedText"] = String(selected.prefix(8000)) }
                    let finish = {
                        guard !shot.isEmpty else { return send(result) }
                        Task {
                            if let path = await Self.screenshot(shot == "screen" ? nil : number) {
                                result["screenshot"] = path
                                result["screenshotNote"] = "A PNG of the \(shot == "screen" ? "screen" : "window"); read it to see it."
                            } else {
                                result["screenshotNote"] = Capture.allowed ? "Couldn't take the picture." : "Petal needs Screen Recording for pictures (Petal's settings, Permissions)."
                            }
                            send(result)
                        }
                    }
                    guard Browsers.kind(front.bundleIdentifier ?? "") != nil else { return finish() }
                    self.app.browsers.frontURL(of: front) { url in
                        MainActor.assumeIsolated {
                            if let url { result["tab"] = ["url": url, "title": title] }
                            finish()
                        }
                    }
                }
            }
        }
    }

    /// The app in front (never Petal itself), or the running app called `name`.
    private func frontApp(named name: String?) -> NSRunningApplication? {
        if let name, !name.isEmpty { return running(name) }
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me { return front }
        return nil
    }

    private func running(_ name: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first { $0.bundleIdentifier?.caseInsensitiveCompare(name) == .orderedSame }
            ?? apps.first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
            ?? apps.first { $0.localizedName?.localizedCaseInsensitiveContains(name) == true }
    }

    /// A picture of one window (its number), or of the main screen, saved in Petal's caches; its path.
    nonisolated private static func screenshot(_ window: CGWindowID?) async -> String? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let filter: SCContentFilter
        let size: CGSize
        if let window, let match = content.windows.first(where: { $0.windowID == window }) {
            filter = SCContentFilter(desktopIndependentWindow: match)
            size = match.frame.size
        } else if let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first {
            filter = SCContentFilter(display: display, excludingWindows: [])
            size = CGSize(width: display.width, height: display.height)
        } else { return nil }
        let configuration = SCStreamConfiguration()
        let scale = min(2, 2000 / max(1, max(size.width, size.height)))   // sharp enough to read, small enough to send
        configuration.width = Int(size.width * scale)
        configuration.height = Int(size.height * scale)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Petal/look")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Only the newest few are kept.
        let old = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for file in old.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(5) { try? FileManager.default.removeItem(at: file) }
        let url = folder.appending(path: "look-\(Int(Date().timeIntervalSince1970)).png")
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else { return nil }
        return url.path
    }

    // MARK: Apps

    private func apps(_ args: [String: Any], _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        let action = args["action"] as? String ?? ""
        let name = args["app"] as? String ?? ""
        let target = args["open"] as? String ?? ""
        switch action {
        case "open":
            if !target.isEmpty {
                // An address or a file, in its app (or the one named).
                let url = target.contains("://") ? URL(string: target) : URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
                guard let url else { return fail("That isn't an address or a file.") }
                let configuration = NSWorkspace.OpenConfiguration()
                if !name.isEmpty, let appURL = Apps.url(Self.bundleID(name)) {
                    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
                } else {
                    NSWorkspace.shared.open(url)
                }
                return send(["opened": target])
            }
            let id = Self.bundleID(name)
            guard Apps.url(id) != nil else { return fail("No app called \(name) is installed.") }
            app.docks.launch(id)
            send(["opened": Apps.name(id)])
        case "quit", "hide", "focus":
            guard let running = running(name) else { return fail("\(name) isn't open.") }
            let label = running.localizedName ?? name
            switch action {
            case "hide": running.hide(); send(["hidden": label])
            case "focus": Windows.bringForward(running); send(["focused": label])
            default:
                ask("quit", "Quit \(label)", detail: "It asks to save anything unsaved.") { allowed in
                    guard allowed else { return send(["declined": "The person didn't allow quitting \(label)."]) }
                    running.terminate()
                    send(["quit": label])
                }
            }
        default:
            fail("action is open, quit, hide or focus")
        }
    }

    /// A bundle id for an app's name (or the id itself).
    private static func bundleID(_ name: String) -> String {
        if name.contains(".") && !name.contains(" ") { return name }
        return MCP.apps(matching: name).first { ($0["name"] ?? "").caseInsensitiveCompare(name) == .orderedSame }?["id"]
            ?? MCP.apps(matching: name).first?["id"] ?? name
    }

    // MARK: Windows

    private func windows(_ args: [String: Any], _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        let action = args["action"] as? String ?? "list"
        let appName = args["app"] as? String ?? ""
        let wanted = args["window"] as? String ?? ""
        let pids: [pid_t]
        if !appName.isEmpty {
            guard let running = running(appName) else { return fail("\(appName) isn't open.") }
            pids = [running.processIdentifier]
        } else {
            pids = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)
        }
        Self.queue.async {
            var found: [AppWindow] = []
            for pid in pids { found += Windows.windows(of: pid) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if action == "list" {
                        return send(["windows": found.map { w in
                            ["id": w.id, "app": NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "", "title": w.title,
                             "minimized": w.minimized, "here": self.app.docks.isOnScreen(w)] as [String: Any]
                        }])
                    }
                    let window = found.first { $0.id == wanted } ?? found.first { !wanted.isEmpty && $0.title.localizedCaseInsensitiveContains(wanted) }
                        ?? (wanted.isEmpty ? found.first { !$0.minimized } : nil)
                    guard let window else { return fail("No such window; list them first.") }
                    let label = window.title.isEmpty ? (NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "the window") : window.title
                    switch action {
                    case "focus": Windows.focus(window, onScreen: self.app.docks.isOnScreen(window)); send(["focused": label])
                    case "minimize": Windows.minimize(window); send(["minimized": label])
                    case "close":
                        self.ask("close", "Close “\(label)”", detail: "Its app asks to save anything unsaved.") { allowed in
                            guard allowed else { return send(["declined": "The person didn't allow closing it."]) }
                            Windows.close(window)
                            send(["closed": label])
                        }
                    case "arrange":
                        let layout = args["layout"] as? String ?? "full"
                        guard let frame = self.arranged(window, layout) else { return fail("layout is left, right, top, bottom, full or center") }
                        Self.queue.async {
                            _ = Windows.place(window.element, pid: window.pid, frame)
                            DispatchQueue.main.async { send(["arranged": label, "layout": layout]) }
                        }
                    default: fail("action is list, focus, minimize, close or arrange")
                    }
                }
            }
        }
    }

    /// Where a window goes for a layout: its screen's room, less the dock.
    private func arranged(_ window: AppWindow, _ layout: String) -> CGRect? {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let screens = Windows.screens()
        guard let screen = screens.first(where: { $0.frame.contains(center) }) ?? screens.first else { return nil }
        let a = Windows.usableArea(frame: screen.frame, visible: screen.visible, respectClear: true)
        switch layout {
        case "left": return CGRect(x: a.minX, y: a.minY, width: a.width / 2, height: a.height)
        case "right": return CGRect(x: a.midX, y: a.minY, width: a.width / 2, height: a.height)
        case "top": return CGRect(x: a.minX, y: a.minY, width: a.width, height: a.height / 2)
        case "bottom": return CGRect(x: a.minX, y: a.midY, width: a.width, height: a.height / 2)
        case "full": return a
        case "center": return CGRect(x: a.minX + a.width * 0.15, y: a.minY + a.height * 0.1, width: a.width * 0.7, height: a.height * 0.8)
        default: return nil
        }
    }

    // MARK: The Trash

    /// Files to the Trash (asked first), or the last ones back where they were (`undo`).
    private func trash(_ args: [String: Any], _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        if args["undo"] as? Bool == true {
            var back: [String] = []
            for item in trashed where (try? FileManager.default.moveItem(at: item.to, to: item.from)) != nil { back.append(item.from.path) }
            trashed = []
            return send(["putBack": back])
        }
        let paths = (args["paths"] as? [String] ?? []).map { ($0 as NSString).expandingTildeInPath }
        let urls = paths.map(URL.init(fileURLWithPath:)).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return fail("None of those files are there.") }
        let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: ", ") + (urls.count > 3 ? " and \(urls.count - 3) more" : "")
        ask("trash", urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to the Trash" : "Move \(urls.count) items to the Trash",
            detail: urls.count == 1 ? "You can put it back." : names) { allowed in
            guard allowed else { return send(["declined": "The person didn't allow it."]) }
            NSWorkspace.shared.recycle(urls) { moved, error in
                MainActor.assumeIsolated {
                    self.trashed = moved.map { (from: $0.key, to: $0.value) }
                    if let error, moved.isEmpty { return fail(error.localizedDescription) }
                    send(["trashed": moved.keys.map(\.path), "undo": "petal_trash with undo: true puts them back"])
                }
            }
        }
    }

    // MARK: Memory

    private var memoryFile: URL { Config.folder.appending(path: "memory.json") }

    private func loadMemories() {
        let list = (Config.parse(memoryFile)?["memories"] as? [[String: Any]]) ?? []
        memories = list.compactMap { item in
            guard let id = item["id"] as? String, let text = item["text"] as? String else { return nil }
            return Memory(id: id, text: text, mode: item["mode"] as? String ?? "", learned: item["by"] as? String == "petal",
                          at: Date(timeIntervalSince1970: item["at"] as? Double ?? 0))
        }
    }

    private func record(_ memory: Memory) -> [String: Any] {
        ["id": memory.id, "text": memory.text, "mode": memory.mode, "by": memory.learned ? "petal" : "you", "at": memory.at.timeIntervalSince1970]
    }

    private func saveMemories() {
        Config.writeObject(["memories": memories.map(record)], to: memoryFile)
    }

    @discardableResult
    func remember(_ text: String, mode: String, learned: Bool) -> Memory {
        let mode = config.modes.contains { $0.id == mode } ? mode : ""
        if let same = memories.first(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame && $0.mode == mode }) { return same }
        let memory = Memory(id: String(UUID().uuidString.prefix(8)).lowercased(), text: text, mode: mode, learned: learned, at: Date())
        memories.append(memory)
        saveMemories()
        return memory
    }

    @discardableResult
    func forget(id: String?, matching text: String?) -> [Memory] {
        let gone = memories.filter { m in
            if let id, !id.isEmpty { return m.id == id }
            if let text, !text.isEmpty { return m.text.localizedCaseInsensitiveContains(text) }
            return false
        }
        memories.removeAll { m in gone.contains { $0.id == m.id } }
        saveMemories()
        return gone
    }

    /// What the chat is told it remembers: everywhere, then the mode in front.
    var memoryBrief: String {
        guard config.bool("aiMemory") else { return "" }
        let mode = app.docks.focusedDock?.mode
        let general = memories.filter { $0.mode.isEmpty }
        let here = memories.filter { !$0.mode.isEmpty && $0.mode == mode?.id }
        var text = ""
        if !general.isEmpty { text += general.map { "- \($0.text) [\($0.id)]" }.joined(separator: "\n") }
        if let mode, !here.isEmpty { text += (text.isEmpty ? "" : "\n") + "In \(mode.name):\n" + here.map { "- \($0.text) [\($0.id)]" }.joined(separator: "\n") }
        return text
    }

    // MARK: Once a minute: learning and the day's summary

    private func minute() {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now).timeIntervalSince1970
        let defaults = UserDefaults.standard
        // The day's summary, at its time.
        let when = config.string("dailySummary")
        if let at = Self.time(when, on: now), now >= at, defaults.double(forKey: "dailySummaryShown") < today {
            defaults.set(today, forKey: "dailySummaryShown")
            showDay()
        }
        // Learning, once a day, in the evening.
        if config.bool("aiMemory"), config.bool("aiLearns"), app.focus.brain.enabled, calendar.component(.hour, from: now) >= 17,
           defaults.double(forKey: "learnedOn") < today {
            defaults.set(today, forKey: "learnedOn")
            learn()
        }
    }

    private static func time(_ text: String, on day: Date) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }

    /// Today's time in each mode as a card, with a line from Petal AI when it's on.
    func showDay() {
        Task {
            let summary = await Task.detached { Insights.summary(from: Calendar.current.startOfDay(for: Date()), to: Date(), title: "Today") }.value
            var card = FocusCard(kind: .summary)
            card.summary = summary
            guard app.focus.brain.enabled, !summary.modes.isEmpty else { return app.popups.show(card) }
            let prompt = """
            Here is how someone spent today on their Mac, by focus mode: \(summary.lines.joined(separator: " "))
            Write ONE short, kind sentence summing up their day for a card on their dock (no greeting, under 20 words).
            Reply with ONLY JSON: {"line": "<sentence>"}
            """
            app.focus.brain.ask(prompt, key: "day|\(Int(Date().timeIntervalSince1970))") { answer in
                card.reason = (answer?["line"] as? String) ?? ""
                self.app.popups.show(card)
            }
        }
    }

    /// What Petal AI learns from the last week of each mode (the apps and when), kept as memories it made.
    func learn() {
        Task {
            let week = await Task.detached { Insights.summary(lastWeek: false) }.value
            for mode in week.modes where mode.minutes >= 60 {
                let known = memories.filter { $0.mode == mode.id }.map(\.text)
                let prompt = """
                You help someone with their Mac. Their focus mode "\(mode.name)" took \(Insights.Summary.duration(mode.minutes)) this week, mostly in \(Insights.list(mode.apps.map { Insights.name($0.id) })).
                What you already remember about this mode: \(known.isEmpty ? "nothing" : known.joined(separator: "; ")).
                Note at most 2 new, short facts about how they use this mode that would help you help them later (habits, tools they rely on). No guesses about their life; nothing already remembered; [] if there's nothing new.
                Reply with ONLY JSON: {"facts": ["<under 15 words>", ...]}
                """
                app.focus.brain.ask(prompt, key: "learn|\(mode.id)|\(Int(Date().timeIntervalSince1970))") { answer in
                    for fact in (answer?["facts"] as? [String] ?? []).prefix(2) where !fact.isEmpty {
                        self.remember(fact, mode: mode.id, learned: true)
                    }
                }
            }
        }
    }
}
