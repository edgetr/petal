import AppKit
import Observation
import ScreenCaptureKit

/// Petal AI's own powers on the Mac. Claude Code and Codex reach them through Petal's tools (`petal_look`,
/// `petal_apps`, `petal_windows`, `petal_trash`, `petal_remember`, `petal_forget`, `petal_memories`, and `petal_ui` and
/// `petal_act` for using apps, ComputerUse.swift), which the
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
        var secret = false    // asks the person for a secret (the vault), typed into the card
        var every = false     // asked every time: no Always
        var owner: String?    // the chat asking (ComputerUse): its Stop, or its next turn, answers Don't
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
    /// What Petal AI did, newest first (AssistMore.swift).
    var history: [Done] = []
    @ObservationIgnored private var answer: ((Bool) -> Void)?
    @ObservationIgnored private var giveUp: DispatchWorkItem?
    @ObservationIgnored private var trashed: [(from: URL, to: URL)] = []
    @ObservationIgnored private var timer: Timer?
    /// Using the person's apps with a pointer of its own (ComputerUse.swift).
    @ObservationIgnored let computer = ComputerUse()
    nonisolated private static let queue = DispatchQueue(label: "petal.assist", qos: .userInitiated, attributes: .concurrent)

    var app: PetalApp { PetalApp.shared }
    var config: Config { app.config }

    func start() {
        loadMemories()
        loadHistory()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.minute() }
        }
    }

    // MARK: Asking first

    enum Choice { case once, always, no }

    /// Allowed already (Full access, or Always for this kind), or asked with a card; `done` hears the answer.
    /// `always`: asked even with Full access (the vault). `secret`: the card takes a secret, handed to `typed`.
    func ask(_ kind: String, _ title: String, detail: String = "", always: Bool = false, secret: Bool = false, owner: String? = nil,
             typed: ((String) -> Void)? = nil, done: @escaping (Bool) -> Void) {
        // `always` (the vault) asks every time: neither Full access nor an earlier Always skips it.
        if !secret, !always, config.string("claudeAccess") == "full" || config.strings("aiAllowed").contains(kind) { return done(true) }
        settle(false)   // one question at a time: a newer one replaces an older one, which is declined
        secretTyped = typed
        let request = Request(kind: kind, title: title, detail: detail, secret: secret, every: always, owner: owner)
        pending = request
        answer = done
        // In the chat when it's open and the question is its own (the card shows there); over the dock otherwise
        // (another chat or AI session asking).
        if !app.claude.isOpen || !showsInChat(request) {
            // Over the dock; with no Petal dock showing (macOS's in use), in the chat asking, which shows the question.
            if app.docks.focusedDock?.panel != nil { app.popups.show(FocusCard(kind: .ask, title: title, reason: detail)) }
            else if let owner, let note = app.claude.note(withID: owner) { app.claude.present(note) }
            else if !app.claude.isOpen { app.claude.open(asking: nil) }
        }
        let work = DispatchWorkItem { [weak self] in self?.settle(false) }
        giveUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
    }

    @ObservationIgnored private var secretTyped: ((String) -> Void)?

    /// Shows a made-up question, for `Petal --snapshot`.
    func preview(_ request: Request?) { pending = request }

    /// The answer to the question `id` (a newer question replaced an older one, which was answered Don't then: an
    /// answer meant for the older one, or a secret typed for it, never goes to the newer).
    func choose(_ choice: Choice, secret: String = "", for id: UUID? = nil) {
        guard let pending, id == nil || pending.id == id else { return }
        if pending.secret, choice != .no {
            guard !secret.isEmpty else { return }
            secretTyped?(secret)
        }
        secretTyped = nil
        if choice == .always, !pending.every {
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

    /// The chat panel shows `request` only when it's that chat's own (or nobody's in particular): another chat's
    /// question never shows in the one open, where it could be answered for the wrong chat. An AI session outside
    /// Petal asks over the dock, or in the chat when there's no Petal dock.
    func showsInChat(_ request: Request) -> Bool {
        guard let owner = request.owner, owner != app.claude.current.id.uuidString else { return true }
        if app.claude.note(withID: owner) != nil { return false }
        return app.docks.focusedDock?.panel == nil
    }

    /// The chat `owner` stopped, or moved on to another turn: its question waiting is answered Don't.
    func decline(owner: String) {
        if pending?.owner == owner { settle(false) }
    }

    /// The card went away without an answer (×, Escape, another card): that's Don't.
    func cardClosed() {
        if pending != nil { settle(false) }
    }

    // MARK: The tools

    /// One of Petal AI's tools, from `Petal --mcp` (["assist", name, json]); the reply is one line of JSON.
    /// `note`: the sticky note whose chat asks (PETAL_NOTE), so looking looks at its window.
    func handle(_ name: String, _ json: String, note: String? = nil, reply: @escaping @MainActor (String) -> Void) {
        let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        let send: (Any) -> Void = { result in
            let object: Any = JSONSerialization.isValidJSONObject(result) ? result : ["result": "\(result)"]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
            reply(String(decoding: data, as: UTF8.self))
        }
        let fail = { (text: String) in send(["error": text]) }
        switch name {
        // The note's window as it is now (a note stuck to none, or notes off: what's in front).
        case "petal_look": look(args, place: app.claude.notesOn ? note.flatMap { app.claude.note(withID: $0) }?.place : nil, send)
        case "petal_apps": apps(args, send, fail)
        case "petal_windows": windows(args, send, fail)
        case "petal_trash": trash(args, send, fail)
        case "petal_remember":
            guard config.bool("aiMemory") else { return fail("Memory is off in Petal's settings (aiMemory).") }
            let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return fail("Nothing to remember.") }
            let memory = remember(text, mode: args["mode"] as? String ?? "", learned: args["learned"] as? Bool ?? false)
            did("Remembered “\(memory.text)”", undo: .forget(memory.id))
            send(["remembered": memory.text, "id": memory.id, "mode": memory.mode.isEmpty ? "everywhere" : memory.mode])
        case "petal_forget":
            let gone = forget(id: args["id"] as? String, matching: args["text"] as? String)
            for memory in gone { did("Forgot “\(memory.text)”", undo: .remember(memory.text, memory.mode)) }
            send(["forgot": gone.map(\.text)])
        case "petal_show":
            do {
                let title = args["title"] as? String ?? "Petal"
                let file = try Pages.show(title: title, markdown: args["markdown"] as? String,
                                          html: args["html"] as? String, path: args["path"] as? String, update: args["update"] as? String)
                did("Made a page: \(title)", undo: .open(file.path, title))
                send(["opened": file.path])
            } catch { fail(error.localizedDescription) }
        case "petal_vault": vault(args, send, fail)
        case "petal_ui", "petal_act": computer.handle(name, args, note: note, send: send, fail: fail)
        case "petal_routines", "petal_routine_save", "petal_routine_run", "petal_routine_undo", "petal_routine_delete":
            app.routines.handle(name, args, send, fail)
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
    /// A sticky note (`place`) looks at its own window instead, wherever the person is now, unless it asks for an app
    /// or for what's in front (`front`).
    private func look(_ args: [String: Any], place: NotePlace? = nil, _ send: @escaping (Any) -> Void) {
        let named = args["app"] as? String ?? ""
        let place = named.isEmpty && args["front"] as? Bool != true ? place : nil
        let stuck = place?.running
        let front = place == nil ? frontApp(named: named) : stuck
        let wanted = place?.lookWindow
        var result: [String: Any] = [:]
        if let place, let mode = config.modes.first(where: { $0.id == place.mode }) { result["mode"] = ["id": mode.id, "name": mode.name] }
        else if let mode = app.docks.focusedDock?.mode { result["mode"] = ["id": mode.id, "name": mode.name] }
        if let place {
            // A note's window that's gone is said so, and nothing else is looked at in its place.
            guard stuck != nil else {
                return send(["note": place.kind == .app ? "This note is stuck to \(place.appName), which isn't open. front: true looks at what's in front now."
                                                      : "This note's window is closed: \(place.appName) has quit. front: true looks at what's in front now."])
            }
            result["note"] = place.kind == .app
                ? "This note is stuck to all of \(place.appName): this is its window in front; the user may be looking at something else now (front: true shows that)."
                : "This is the window the note is stuck to; the user may be looking at something else now (front: true shows that)."
        }
        result["onScreen"] = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isHidden }
            .compactMap(\.localizedName)).sorted()
        // The clipboard only once the privacy checks below have passed, and never something private. Read here,
        // and told only with the vault's secrets taken out (off the main thread: that may read the Keychain).
        let wantsClipboard = args["clipboard"] as? Bool == true
        var clipboard: String?
        let addClipboard = {
            guard wantsClipboard else { return }
            if Self.clipboardIsPrivate || self.neverLook(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
                result["clipboard"] = "The clipboard holds something private (a password manager's, or one kept private): Petal doesn't read it."
            } else {
                // Read whole: the vault's secrets are taken out of all of it before it's cut short.
                clipboard = NSPasteboard.general.string(forType: .string) ?? ""
            }
        }
        guard let front else {
            addClipboard()
            guard let raw = clipboard else { return send(result) }
            return Self.queue.async {
                let clean = Self.shownText(raw, limit: 4000) ?? Self.tooMuchClipboard
                DispatchQueue.main.async {
                    result["clipboard"] = clean
                    send(result)
                }
            }
        }
        result["app"] = ["name": front.localizedName ?? "", "id": front.bundleIdentifier ?? ""]
        // An app the person keeps private (passwords, a bank): only its name, nothing of what's in it (its window,
        // selection, tab, picture, nor the clipboard).
        if neverLook(front.bundleIdentifier) {
            result["private"] = "The user keeps this app private: Petal doesn't look at what's in it."
            if wantsClipboard { result["clipboard"] = "The clipboard holds something private: Petal doesn't read it while a private app is in front." }
            return send(result)
        }
        addClipboard()
        let pid = front.processIdentifier
        let shot = args["screenshot"] as? String ?? ((args["screenshot"] as? Bool) == true ? "window" : "")
        // A note stuck to one tab looks only while that tab is the one its window shows: never at another tab.
        // Checked before reading and again once everything is read, right before it's told (`deliver`).
        let tabPlace = place.flatMap { $0.kind == .tab && $0.tab != nil ? $0 : nil }
        let previous = tabPlace.flatMap { app.claude.lastTab($0) }
        Self.queue.async {
            let before = tabPlace.flatMap { ClaudePanel.tabShowing($0, previous: previous) }
            if tabPlace != nil, before == nil {
                return DispatchQueue.main.async { send(["note": ClaudePanel.tabNotShowing]) }
            }
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.3)
            var window: AXUIElement? = Windows.value(element, kAXFocusedWindowAttribute)
            let focusedID = window.flatMap { Windows.id(of: $0) }
            // A note's own window, when it isn't its app's focused one (or is gone: then the focused one, said so).
            if let wanted, wanted != focusedID {
                let all: [AXUIElement] = Windows.value(element, kAXWindowsAttribute) ?? []
                guard let match = all.first(where: { Windows.id(of: $0) == wanted }) else {
                    let name = front.localizedName ?? "its app"
                    return DispatchQueue.main.async {
                        send(["note": "This note's window is closed (it was in \(name)). front: true looks at what's in front now."])
                    }
                }
                window = match
            }
            let number = window.flatMap { Windows.id(of: $0) }
            let realTitle: String = window.flatMap { Windows.value($0, kAXTitleAttribute) } ?? ""
            let frame = window.flatMap { Windows.frame(of: $0) } ?? .zero
            let focused: AXUIElement? = number == focusedID ? Windows.value(element, kAXFocusedUIElementAttribute) : nil
            let selected: String = focused.flatMap { Windows.value($0, kAXSelectedTextAttribute) } ?? ""
            // Nothing of the vault's secrets goes to the AI: not in the title, the selection, nor the clipboard.
            let title = Self.withoutSecrets(realTitle)
            let shownSelection = selected.isEmpty ? "" : Self.shownText(selected, limit: 8000) ?? Self.tooMuchSelected
            let shownClipboard = clipboard.map { Self.shownText($0, limit: 4000) ?? Self.tooMuchClipboard }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    result["window"] = title
                    if !shownSelection.isEmpty { result["selectedText"] = shownSelection }
                    if let shownClipboard { result["clipboard"] = shownClipboard }
                    let hidden = self.privatePIDs
                    // What was read goes to the AI only if it's still what it was read from: the app not made private
                    // meanwhile, and a tab note's tab still the one showing in the same window. Else none of it goes
                    // (the picture is deleted): another tab's text, address or picture is never told as the note's.
                    let deliver = { (picture: String?) in
                        let refuse = { (answer: [String: Any]) in
                            if let picture { try? FileManager.default.removeItem(atPath: picture) }
                            send(answer)
                        }
                        let privately: [String: Any] = ["app": ["name": front.localizedName ?? "", "id": front.bundleIdentifier ?? ""],
                                                        "private": "The user keeps this app private: Petal doesn't look at what's in it."]
                        let tell = {
                            if self.neverLook(front.bundleIdentifier) { return refuse(privately) }
                            if picture != nil { self.did(shot == "screen" ? "Looked at your screen" : "Looked at \(front.localizedName ?? "a window")") }
                            send(result)
                        }
                        guard let tabPlace, let before else { return tell() }
                        Self.queue.async {
                            let after = ClaudePanel.tabShowing(tabPlace, previous: previous)
                            // The same tab of the same window it read: its id or place and its address unchanged.
                            let same = after.map { now in
                                now.window == before.window && before.window == number && now.tab.id == before.tab.id
                                    && now.tab.index == before.tab.index && now.tab.count == before.tab.count
                                    && now.tab.url == before.tab.url
                            } ?? false
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated { same ? tell() : refuse(["note": ClaudePanel.tabNotShowing]) }
                            }
                        }
                    }
                    let finish = {
                        guard !shot.isEmpty else { return deliver(nil) }
                        Task {
                            let path = await Self.screenshot(shot == "screen" ? nil : number, screen: shot == "screen", hiding: hidden)
                            if let path {
                                result["screenshot"] = path
                                result["screenshotNote"] = "A PNG of the \(shot == "screen" ? "screen" : "window"); read it to see it."
                            } else {
                                result["screenshotNote"] = Capture.allowed ? "Couldn't take the picture." : "Petal needs Screen Recording for pictures (Petal's settings, Permissions)."
                            }
                            deliver(path)
                        }
                    }
                    guard Browsers.kind(front.bundleIdentifier ?? "") != nil else { return finish() }
                    // A note's tab is always its own window's (by id, or frame and title), never whichever window is
                    // in front by the time the browser answers.
                    let other = place == nil ? nil : Browsers.Window(number: number, title: realTitle, frame: frame)
                    // A note stuck to one tab: which, as it was last seen (the window may show another now).
                    let noteTab = place?.kind == .tab ? place?.tab : nil
                    self.app.browsers.frontURL(of: front, window: other) { url in
                        guard url != nil || noteTab != nil else { return finish() }
                        // An address can carry a key too (?token=…).
                        Self.queue.async {
                            let shown = url.map(Self.withoutSecrets)
                            let stuckTab = noteTab.map { ["url": Self.withoutSecrets($0.url), "title": Self.withoutSecrets($0.title)] }
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    if let shown { result["tab"] = ["url": shown, "title": title] }
                                    if let stuckTab {
                                        result["noteTab"] = stuckTab
                                        result["note"] = "This note is stuck to one tab of this window (noteTab); tab is the one the window shows now. The user may be looking at something else (front: true shows that)."
                                    }
                                    finish()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    nonisolated static let tooMuchClipboard = "The clipboard holds too much to check for saved secrets: Petal doesn't read it."
    nonisolated static let tooMuchSelected = "What's selected is too much to check for saved secrets: Petal doesn't read it."

    /// What password managers mark what they copy with (nspasteboard.org's markers, and 1Password's own): the
    /// clipboard then holds a secret, never read.
    nonisolated static let concealedTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                                          "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]

    nonisolated static func isConcealed(_ pasteboard: NSPasteboard) -> Bool {
        (pasteboard.types ?? []).contains { concealedTypes.contains($0.rawValue) }
    }

    static var clipboardIsPrivate: Bool { isConcealed(NSPasteboard.general) }

    /// `text` with the vault's secrets in it (whole, 8 characters or more of one, or a short one as a word) as
    /// "(hidden)", the same matching petal_ui uses. May read the Keychain: never on the main thread.
    nonisolated static func withoutSecrets(_ text: String) -> String {
        text.isEmpty ? text : VaultIndex.current().redacted(text)
    }

    /// The app in front (never Petal itself), or the running app called `name`.
    func frontApp(named name: String?) -> NSRunningApplication? {
        if let name, !name.isEmpty { return running(name) }
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me { return front }
        return nil
    }

    func running(_ name: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first { $0.bundleIdentifier?.caseInsensitiveCompare(name) == .orderedSame }
            ?? apps.first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
            ?? apps.first { $0.localizedName?.localizedCaseInsensitiveContains(name) == true }
    }

    /// A picture of one window (its number), or of the main screen, saved in Petal's caches; its path.
    /// `window` nil is the whole screen; a window that can't be found is no picture, never the screen instead.
    nonisolated private static func screenshot(_ window: CGWindowID?, screen: Bool = false, hiding: Set<pid_t> = []) async -> String? {
        guard screen || window != nil else { return nil }
        guard CGPreflightScreenCaptureAccess(),
              // One window may be behind others or on another Desktop (a note's): every window is listed then.
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: window == nil) else { return nil }
        let filter: SCContentFilter
        let size: CGSize
        if !screen {
            guard let window, let match = content.windows.first(where: { $0.windowID == window }) else { return nil }
            filter = SCContentFilter(desktopIndependentWindow: match)
            size = match.frame.size
        } else if let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first {
            // The screen without the apps kept private, and without Petal's own windows: its previews, banners,
            // cards and stacks can show what's in those apps (and the chat itself needn't be in the picture).
            // Notification banners too: they belong to Notification Center, not their app, and can show a private
            // app's messages.
            let me = ProcessInfo.processInfo.processIdentifier
            filter = SCContentFilter(display: display, excludingApplications: content.applications.filter {
                hiding.contains($0.processID) || $0.processID == me || $0.bundleIdentifier == "com.apple.notificationcenterui"
            }, exceptingWindows: [])
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
        for file in old.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(10) { try? FileManager.default.removeItem(at: file) }
        // Its own name (two notes looking in the same second never share a picture), in time order for the above.
        let url = folder.appending(path: "look-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).png")
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
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
                // Finding the app (a scan of the Applications folders) and Launch Services wait on the disk or the
                // app: off the main thread.
                return Self.off({
                    let appURL = name.isEmpty ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID(name))
                    if let appURL {
                        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                    } else {
                        NSWorkspace.shared.open(url)
                    }
                }) { send(["opened": target]) }
            }
            // The name is looked up off the main thread (it scans the Applications folders); the launch is the dock's.
            var found: (id: String, url: URL?) = (name, nil)
            Self.off({
                let id = Self.bundleID(name)
                found = (id, NSWorkspace.shared.urlForApplication(withBundleIdentifier: id))
            }) { [weak self] in
                guard let self else { return }
                guard found.url != nil else { return fail("No app called \(name) is installed.") }
                self.app.docks.launch(found.id)
                send(["opened": Apps.name(found.id)])
            }
        case "quit", "hide", "focus":
            guard let running = running(name) else { return fail("\(name) isn't open.") }
            let label = running.localizedName ?? name
            switch action {
            // Each asks the app (or Launch Services): off the main thread, the answer back on it.
            case "hide": Self.off({ running.hide() }) { send(["hidden": label]) }
            case "focus":
                let url = running.bundleURL
                Self.off({
                    guard let url else { return }
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.addsToRecentItems = false
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                }) { if url == nil { running.activate() }; send(["focused": label]) }
            default:
                ask("quit", "Quit \(label)", detail: "It asks to save anything unsaved.") { allowed in
                    guard allowed else { return send(["declined": "The person didn't allow quitting \(label)."]) }
                    Self.off({ running.terminate() }) {
                        self.did("Quit \(label)")
                        send(["quit": label])
                    }
                }
            }
        default:
            fail("action is open, quit, hide or focus")
        }
    }

    /// Does `work` (which waits on another app) off the main thread, then `then` back on it.
    nonisolated static func off(_ work: @escaping () -> Void, then: @escaping @MainActor () -> Void) {
        queue.async {
            work()
            DispatchQueue.main.async { MainActor.assumeIsolated { then() } }
        }
    }

    /// A bundle id for an app's name (or the id itself).
    nonisolated private static func bundleID(_ name: String) -> String {
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
                        let hidden = self.privatePIDs
                        return send(["windows": found.map { w in
                            ["id": w.id, "app": NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "", "title": hidden.contains(w.pid) ? "" : w.title,
                             "minimized": w.minimized, "here": self.app.docks.isOnScreen(w)] as [String: Any]
                        }])
                    }
                    let window = found.first { $0.id == wanted } ?? found.first { !wanted.isEmpty && $0.title.localizedCaseInsensitiveContains(wanted) }
                        ?? (wanted.isEmpty ? found.first { !$0.minimized } : nil)
                    guard let window else { return fail("No such window; list them first.") }
                    let appName = NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "the window"
                    // A private app's window is called by its app's name only, in replies and the history.
                    let label = window.title.isEmpty || self.privatePIDs.contains(window.pid) ? appName : window.title
                    switch action {
                    case "focus": Windows.focus(window, onScreen: self.app.docks.isOnScreen(window)); send(["focused": label])
                    case "minimize":
                        // Accessibility waits on the app (a hung one for its timeout): never on the main thread.
                        let element = window.element
                        Self.off({ AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }) {
                            send(["minimized": label])
                        }
                    case "close":
                        self.ask("close", "Close “\(label)”", detail: "Its app asks to save anything unsaved.") { allowed in
                            guard allowed else { return send(["declined": "The person didn't allow closing it."]) }
                            let element = window.element
                            Self.off({
                                guard let button: AXUIElement = Windows.value(element, kAXCloseButtonAttribute) else { return }
                                AXUIElementPerformAction(button, kAXPressAction as CFString)
                            }) {
                                self.did("Closed “\(label)”")
                                send(["closed": label])
                            }
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
            let items = trashed
            Self.queue.async {
                var back: [String] = []
                var stuck: [(from: URL, to: URL)] = []
                for item in items {
                    if (try? FileManager.default.moveItem(at: item.to, to: item.from)) != nil { back.append(item.from.path) }
                    else if FileManager.default.fileExists(atPath: item.to.path) { stuck.append(item) }
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.trashed = stuck   // what couldn't come back yet stays, to try again
                        var reply: [String: Any] = ["putBack": back]
                        if !stuck.isEmpty { reply["stillInTrash"] = stuck.map(\.from.path); reply["why"] = "Something is in their old place now." }
                        send(reply)
                    }
                }
            }
            return
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
                    self.did(moved.count == 1 ? "Moved “\(moved.keys.first?.lastPathComponent ?? "")” to the Trash" : "Moved \(moved.count) items to the Trash",
                             undo: .putBack(moved.map { [$0.key.path, $0.value.path] }))
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

    /// What the chat is told it remembers: everywhere, then the mode in front (or a note's own mode).
    func memoryBrief(mode id: String? = nil) -> String {
        guard config.bool("aiMemory") else { return "" }
        let mode = id.flatMap { id in config.modes.first { $0.id == id } } ?? app.docks.focusedDock?.mode
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
