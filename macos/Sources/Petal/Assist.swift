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
        var every = false     // asked every time: no Always
        var owner: String?    // the chat asking (ComputerUse): its Stop, or its next turn, answers Don't
        /// Asks the person to type something into the vault (a login, a card, …), into the card itself.
        var form: VaultForm?
        /// What's asked doesn't match (a login on another site), or it pays: Don't is the default.
        var warn = false
        /// The word on the button that says yes ("Allow", "Buy").
        var allow = "Allow"
        /// An Always of its own, even where Don't is the default: "Always for this project" for an agent outside
        /// Petal (AgentCallers.swift), kept as a grant rather than in aiAllowed.
        var keep: String?
        /// The agent asking, when it's one outside Petal: its mark on the card.
        var mark: AgentAccess.Agent?
        var takesKeys: Bool { form != nil }
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
    /// `always`: asked even with Full access (the vault). `form`: the card takes what the person types for the vault,
    /// handed to `typed` before `done`. `warn`: Don't is the default (what's asked doesn't match).
    /// `keep`: the label of an Always kept as `kept` says (an agent's grant), shown even when Don't is the default.
    /// `owner`: the chat or AI session asking (Assist.handle's caller), always said: its Stop, next turn or hanging up
    /// answers its card Don't. Only what no chat asked for (a routine's own run) passes nil.
    func ask(_ kind: String, _ title: String, detail: String = "", always: Bool = false, form: VaultForm? = nil, warn: Bool = false,
             allow: String = "Allow", owner: String?, keep: String? = nil, mark: AgentAccess.Agent? = nil, kept: (() -> Void)? = nil,
             typed: ((VaultForm.Answer) -> Void)? = nil, done: @escaping (Bool) -> Void) {
        // `always` (the vault) asks every time: neither Full access nor an earlier Always skips it.
        if form == nil, !always, !warn, config.string("claudeAccess") == "full" || config.strings("aiAllowed").contains(kind) { return done(true) }
        settle(false)   // one question at a time: a newer one replaces an older one, which is declined
        formTyped = typed
        keptAlways = keep == nil ? nil : kept
        let request = Request(kind: kind, title: title, detail: detail, every: always || warn, owner: owner, form: form, warn: warn,
                              allow: allow, keep: keep, mark: mark)
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

    @ObservationIgnored private var formTyped: ((VaultForm.Answer) -> Void)?
    @ObservationIgnored private var keptAlways: (() -> Void)?

    /// Shows a made-up question, for `Petal --snapshot`.
    func preview(_ request: Request?) { pending = request }

    /// The answer to the question `id` (a newer question replaced an older one, which was answered Don't then: an
    /// answer meant for the older one, or what was typed for it, never goes to the newer).
    func choose(_ choice: Choice, typed: VaultForm.Answer? = nil, for id: UUID? = nil) {
        guard let pending, id == nil || pending.id == id else { return }
        if let form = pending.form, choice != .no {
            guard let typed, form.complete(typed) else { return }
            formTyped?(typed)
        }
        formTyped = nil
        if choice == .always, pending.keep != nil { keptAlways?() }
        if choice == .always, !pending.every {
            var allowed = config.strings("aiAllowed")
            if !allowed.contains(pending.kind) { allowed.append(pending.kind); config.set("aiAllowed", allowed) }
        }
        settle(choice != .no)
    }

    private func settle(_ allowed: Bool) {
        formTyped = nil
        keptAlways = nil
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

    /// A request's asker went before its answer (an agent that gave up waiting, or quit): what that chat or AI
    /// session had going stops, its card is answered Don't, and what it was allowed this task goes, so nothing it
    /// asked for happens with nobody to hear of it; its next request starts afresh and asks again. (An AI session's
    /// requests share one caller: all of them stop.)
    func hungUp(_ caller: String) {
        computer.abandon(caller)
        decline(owner: caller)
    }

    /// The card went away without an answer (×, Escape, another card): that's Don't.
    func cardClosed() {
        if pending != nil { settle(false) }
    }

    // MARK: The tools

    /// One of Petal AI's tools, from `Petal --mcp` (["assist", name, json]); the reply is one line of JSON.
    /// `note`: the sticky note whose chat asks (PETAL_NOTE), so looking looks at its window. `who`: who's asking, as
    /// Petal read it off the socket when the request came in (AgentCallers). `request`: the socket's request; once its
    /// client hangs up, its cards are answered Don't (hungUp) and what it started off the main thread neither asks nor
    /// acts.
    func handle(_ name: String, _ json: String, note: String? = nil, who: AgentAccess.Caller? = nil, request: IPC.Pending? = nil,
                reply: @escaping @MainActor (String) -> Void) {
        // Read on any thread: the socket's own flag, set the moment its client closes. Every change made for an
        // outside caller reads it on the thread making the change, right before it (`off`, an act's or a vault
        // call's `Acting.Cancel`, a routine's `RoutineStop`), never waiting for the main thread's `hungUp`.
        let gone: @Sendable () -> Bool = { request?.hungUp == true }
        let live: @Sendable () -> Bool = { !gone() }
        guard live() else { return }   // its client went before Petal got to it: nothing to answer
        let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        let send: (Any) -> Void = { result in
            let object: Any = JSONSerialization.isValidJSONObject(result) ? result : ["result": "\(result)"]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
            reply(String(decoding: data, as: UTF8.self))
        }
        let fail = { (text: String) in send(["error": text]) }
        switch name {
        // The note's window as it is now (a note stuck to none, or notes off: what's in front).
        case "petal_look": look(args, place: app.claude.notesOn ? note.flatMap { app.claude.note(withID: $0) }?.place : nil, note: note, send)
        case "petal_apps": apps(args, caller: note, live: live, send, fail)
        case "petal_windows": windows(args, caller: note, live: live, send, fail)
        case "petal_trash": trash(args, caller: note, live: live, send, fail)
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
        case "petal_vault": vault(args, caller: note, who: who, gone: request == nil ? nil : gone, send, fail)
        case "petal_ui", "petal_act": computer.handle(name, args, note: note, gone: request == nil ? nil : gone, send: send, fail: fail)
        case "petal_routines", "petal_routine_save", "petal_routine_run", "petal_routine_undo", "petal_routine_delete":
            // Its asker hanging up stops a tidy's moves under way off the main thread, not only what comes next.
            let stop = RoutineStop(also: gone)
            request?.onHangUp { stop.stop() }
            app.routines.handle(name, args, send, fail, caller: note, live: live, stop: stop)
        case _ where NoteDesk.tools.contains(name):
            // Its asker hanging up stops what's still to come: each change checks `live` right before it's made.
            app.paper.handle(name, args, asker: note, live: live, send, fail)
        case "petal_memories":
            let mode = args["mode"] as? String
            send(["memories": memories.filter { mode == nil || $0.mode == mode || $0.mode.isEmpty }.map(record)])
        default:
            fail("Unknown tool \(name)")
        }
    }

    // MARK: Looking

    /// Whether text selected in `field` may never go to the AI (petal_look's rule, and the note tools' for a
    /// passage): a password field, a field named like a password, token, key, card number or security code, a field
    /// Petal filled with a secret, any of the field's whole text holding a vault secret, or one piece of a secret the
    /// window shows in pieces (a card number as four fields: selected a field at a time, it would be told whole).
    /// Off the main thread (Accessibility, the vault).
    nonisolated static func selectionInSecret(_ field: AXUIElement, pid: pid_t, window: CGWindowID?) -> Bool {
        // The field's whole text, checked against the vault: a saved key in a field named nothing secret.
        var node = Reader.node(field)
        if !UIMap.isSecure(node) { node.value = Windows.value(field, kAXValueAttribute) ?? "" }
        return UIMap.selectionHidden(in: node, filled: Sensitive.isFilled(field, pid: pid), secret: VaultIndex.current().matches)
            || Reader.inJoinedSecret(pid: pid, window: window, controls: [field])
    }

    /// What's in front: the app, its window, the browser's tab, selected text, the mode, the other windows showing;
    /// with `screenshot` ("window" or "screen") a picture saved where the AI can read it, and the clipboard if asked.
    /// A sticky note (`place`) looks at its own window instead, wherever the person is now, unless it asks for an app
    /// or for what's in front (`front`).
    private func look(_ args: [String: Any], place: NotePlace? = nil, note: String? = nil, _ send: @escaping (Any) -> Void) {
        let named = args["app"] as? String ?? ""
        let place = named.isEmpty && args["front"] as? Bool != true ? place : nil
        let stuck = place?.running
        let front = place == nil ? frontApp(named: named) : stuck
        let wanted: CGWindowID? = if case .window(let number)? = place?.target { number } else { nil }
        var result: [String: Any] = [:]
        if let place, let mode = config.modes.first(where: { $0.id == place.mode }) { result["mode"] = ["id": mode.id, "name": mode.name] }
        else if let mode = app.docks.focusedDock?.mode { result["mode"] = ["id": mode.id, "name": mode.name] }
        if let place {
            // A note's window that's gone is said so, and nothing else is looked at in its place.
            guard stuck != nil else {
                return send(["note": place.kind == .app ? "This note is stuck to \(place.appName), which isn't open. front: true looks at what's in front now."
                                                      : "This note's window is closed: \(place.appName) has quit. front: true looks at what's in front now."])
            }
            // Asked where its app showed no window: none to look at, never a window that app shows later.
            if place.target == .nothing { return send(["note": ClaudePanel.noWindow(place.appName)]) }
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
        Self.queue.async {
            let before = tabPlace.flatMap { ClaudePanel.tabShowing($0) }
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
            // Nothing selected in a field holding a secret, not even part of one: a card number selected four
            // digits at a time would otherwise be told whole over four looks.
            let inSecret = !selected.isEmpty && focused.map { Self.selectionInSecret($0, pid: pid, window: number) } == true
            let shownSelection = selected.isEmpty ? "" : inSecret ? Self.selectionInSecret
                : Self.shownText(selected, limit: 8000) ?? Self.tooMuchSelected
            let shownClipboard = clipboard.map { Self.shownText($0, limit: 4000) ?? Self.tooMuchClipboard }
            let looked = window
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
                        // The picture is deleted off the main thread (the disk may wait), before the refusal is told.
                        let refuse = { (answer: [String: Any]) in
                            guard let picture else { return send(answer) }
                            nonisolated(unsafe) let answer = answer
                            Self.queue.async {
                                try? FileManager.default.removeItem(atPath: picture)
                                DispatchQueue.main.async { MainActor.assumeIsolated { send(answer) } }
                            }
                        }
                        let privately: [String: Any] = ["app": ["name": front.localizedName ?? "", "id": front.bundleIdentifier ?? ""],
                                                        "private": "The user keeps this app private: Petal doesn't look at what's in it."]
                        let tell = {
                            if self.neverLook(front.bundleIdentifier) { return refuse(privately) }
                            // Its tab, seen showing: the note follows it (a chat kept from before Petal restarted
                            // takes the tab's button from now on).
                            if let tabPlace, let before, let note { self.app.claude.tabSeen(note: note, was: tabPlace, tab: before.tab, window: before.window) }
                            let told = {
                                if picture != nil { self.did(shot == "screen" ? "Looked at your screen" : "Looked at \(front.localizedName ?? "a window")") }
                                send(result)
                            }
                            // A Buy said in this window (by any chat) ends if it now shows another tab or page, before
                            // the AI hears (or sees) what's in it: the same check petal_ui, fills and acts make.
                            guard let looked, let number, self.computer.hasBuy(in: number) else { return told() }
                            self.vaultTab(window: looked, pid: pid, bundle: front.bundleIdentifier ?? "", appName: front.localizedName ?? "",
                                          windowID: number, frame: frame) { pages in
                                self.computer.seen(pages, window: number)
                                // Made private while the tab was read: none of it goes.
                                if self.neverLook(front.bundleIdentifier) { return refuse(privately) }
                                told()
                            }
                        }
                        guard let tabPlace, let before else { return tell() }
                        Self.queue.async {
                            let after = ClaudePanel.tabShowing(tabPlace)
                            // The same tab of the same window it read: its id or button, place and address unchanged.
                            let same = after.map { now in
                                now.window == before.window && before.window == number && now.tab.id == before.tab.id
                                    && now.tab.element == before.tab.element && now.tab.index == before.tab.index
                                    && now.tab.count == before.tab.count && now.tab.url == before.tab.url
                            } ?? false
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated { same ? tell() : refuse(["note": ClaudePanel.tabNotShowing]) }
                            }
                        }
                    }
                    let finish = {
                        guard !shot.isEmpty else { return deliver(nil) }
                        Task {
                            let picture = await Self.screenshot(shot == "screen" ? nil : number, screen: shot == "screen", hiding: hidden)
                            if let path = picture.path {
                                result["screenshot"] = path
                                result["screenshotNote"] = "A PNG of the \(shot == "screen" ? "screen" : "window"); read it to see it. Black boxes are fields that may hold a password, card number, security code or key: Petal hides them."
                                    + (picture.note.map { " " + $0 } ?? "")
                            } else {
                                result["screenshotNote"] = picture.note ?? (Capture.allowed ? "Couldn't take the picture." : "Petal needs Screen Recording for pictures (Petal's settings, Permissions).")
                            }
                            deliver(picture.path)
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
    nonisolated static let selectionInSecret = "The selection is in a field holding a secret (a password, key, card number or security code): Petal doesn't read it."
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
    /// "(hidden)", the same matching petal_ui uses; all of it "(hidden)" while the vault can't be read. May read the
    /// Keychain: never on the main thread.
    nonisolated static func withoutSecrets(_ text: String) -> String {
        text.isEmpty ? text : VaultIndex.settled { $0.redacted(text) } ?? UIMap.hidden
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

    /// A picture of one window (its number), or of the main screen, saved in Petal's caches: its path, and what was
    /// left out. `window` nil is the whole screen; a window that can't be found is no picture, never the screen
    /// instead. What may show a secret is blacked out first (Sensitive), in memory: no picture is written before.
    /// A window Petal can't read whole through Accessibility is no picture (or, on the screen, isn't in it).
    /// The window server keeps where each window is; what Accessibility finds is placed by where it is now, so a window
    /// that moved or changed size between the list and the picture would have its blackouts in the wrong place, as
    /// would a field that scrolled far, appeared or went while it was taken: then it's taken again once, and after
    /// that there's no picture.
    nonisolated private static func screenshot(_ window: CGWindowID?, screen: Bool = false, hiding: Set<pid_t> = []) async -> (path: String?, note: String?) {
        var why: String?
        for _ in 0..<2 {
            let taken = await capture(window, screen: screen, hiding: hiding)
            if !taken.moved { return (taken.path, taken.note) }
            why = taken.note
        }
        return (nil, why ?? "A window moved or changed size while Petal took the picture, so it couldn't be sure what it hid: no picture. Try again once it's still.")
    }

    nonisolated static let scrolledText = "Something that may be secret scrolled, appeared or went while Petal took the picture, so it couldn't be sure what it hid: no picture. Try again once the window is still."

    /// Where the window server has a window now (top-left origin, as Accessibility and ScreenCaptureKit count), or
    /// nil when it's gone.
    nonisolated private static func frame(of window: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window }),
              let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    /// The window is still where (and the size) it was when the picture's place for it was worked out.
    nonisolated private static func still(_ window: SCWindow) -> Bool {
        guard let now = frame(of: window.windowID) else { return false }
        let then = window.frame
        return abs(now.minX - then.minX) <= 1 && abs(now.minY - then.minY) <= 1 && abs(now.width - then.width) <= 1 && abs(now.height - then.height) <= 1
    }

    nonisolated private static func capture(_ window: CGWindowID?, screen: Bool, hiding: Set<pid_t>) async -> (path: String?, note: String?, moved: Bool) {
        guard screen || window != nil else { return (nil, nil, false) }
        // Nothing can be checked for the vault's secrets while it can't be read: no picture at all.
        if VaultIndex.current().unreadable {
            return (nil, VaultStore.unreadableText + " Petal can't hide its secrets in a picture, so it takes none: try again in a moment.", false)
        }
        guard CGPreflightScreenCaptureAccess(),
              // One window may be behind others or on another Desktop (a note's): every window is listed then.
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: window == nil) else { return (nil, nil, false) }
        let filter: SCContentFilter
        let area: CGRect
        var note: String?
        // Each window in the picture, with its Accessibility window, read again once the picture is taken.
        var watched: [(window: SCWindow, element: AXUIElement, pid: pid_t, visible: CGRect, before: Sensitive.Scan)] = []
        var rects: [CGRect] = []
        if !screen {
            guard let window, let match = content.windows.first(where: { $0.windowID == window }), let pid = match.owningApplication?.processID else { return (nil, nil, false) }
            guard let element = Sensitive.window(pid: pid, id: window) else {
                return (nil, "Petal couldn't read that window through Accessibility, so it can't hide what may be secret in it: no picture.", false)
            }
            let before = Sensitive.scan(window: element, pid: pid, visible: match.frame, deadline: Date().addingTimeInterval(3))
            guard before.complete else {
                return (nil, "Petal couldn't check all of that window for passwords and card numbers in time (it's very big, or the app didn't answer): no picture.", false)
            }
            // Moved while it was read: its blackouts may be in the wrong place.
            guard still(match) else { return (nil, nil, true) }
            watched = [(match, element, pid, match.frame, before)]
            filter = SCContentFilter(desktopIndependentWindow: match)
            area = match.frame
        } else if let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first {
            // The screen without the apps kept private, and without Petal's own windows: its previews, banners,
            // cards and stacks can show what's in those apps (and the chat itself needn't be in the picture).
            // Notification banners too: they belong to Notification Center, not their app, and can show a private
            // app's messages. Only the windows checked are in the picture: one that opens meanwhile isn't.
            let me = ProcessInfo.processInfo.processIdentifier
            area = CGDisplayBounds(display.displayID)
            let deadline = Date().addingTimeInterval(6)
            var included: [SCWindow] = []
            var left: [String] = []
            var overlays = 0
            for candidate in content.windows where candidate.isOnScreen && candidate.frame.intersects(area) {
                guard let owner = candidate.owningApplication, !hiding.contains(owner.processID), owner.processID != me,
                      owner.bundleIdentifier != "com.apple.notificationcenterui" else { continue }
                if let element = Sensitive.window(pid: owner.processID, id: candidate.windowID) {
                    let found = Sensitive.scan(window: element, pid: owner.processID, visible: candidate.frame.intersection(area),
                                               deadline: min(deadline, Date().addingTimeInterval(2)))
                    if found.complete {
                        included.append(candidate)
                        watched.append((candidate, element, owner.processID, candidate.frame.intersection(area), found))
                        continue
                    }
                } else if candidate.windowLayer != 0 {
                    // The menu bar, menus, pop-overs and other overlays have no window of their own in Accessibility,
                    // so nothing in them was checked (a context menu can quote the selected text): left out.
                    overlays += 1
                    continue
                }
                let name = owner.applicationName.isEmpty ? "a window" : owner.applicationName
                if !left.contains(name) { left.append(name) }
            }
            var notes: [String] = []
            if !left.isEmpty {
                notes.append("Left out (Petal couldn't check them for passwords and card numbers): \(left.joined(separator: ", ")).")
            }
            if overlays > 0 { notes.append("Menus, the menu bar and other overlays aren't in the picture: Petal can't check them for secrets.") }
            if !notes.isEmpty { note = notes.joined(separator: " ") }
            filter = SCContentFilter(display: display, including: included)
        } else { return (nil, nil, false) }
        let configuration = SCStreamConfiguration()
        let scale = min(2, 2000 / max(1, max(area.width, area.height)))   // sharp enough to read, small enough to send
        configuration.width = Int(area.width * scale)
        configuration.height = Int(area.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return (nil, note, false) }
        // Read again now, each part matched to itself in the read before: one that moved while the picture was taken
        // is covered from where it was to where it is. On the screen, a window that can't be read whole again, or
        // where something secret appeared, went or scrolled far meanwhile, is covered completely; a window alone is
        // taken again (once).
        for item in watched {
            let after = Sensitive.scan(window: item.element, pid: item.pid, visible: item.visible, deadline: Date().addingTimeInterval(2))
            if !after.complete, !screen {
                return (nil, "Petal couldn't check all of that window for passwords and card numbers in time: no picture.", false)
            }
            if after.complete, let covered = Sensitive.blackouts(item.before, after, window: item.window.frame) {
                rects += covered
            } else if screen {
                rects.append(item.window.frame)
            } else {
                return (nil, scrolledText, true)
            }
            // The picture placed it where it was listed; what was found is where it is now. Moved meanwhile: taken
            // again (nothing is written).
            guard still(item.window) else { return (nil, nil, true) }
        }
        guard let clean = Sensitive.blackOut(image, rects, origin: area.origin, scale: CGFloat(image.width) / max(1, area.width)) else { return (nil, note, false) }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Petal/look")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Only the newest few are kept.
        let old = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for file in old.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(10) { try? FileManager.default.removeItem(at: file) }
        // Its own name (two notes looking in the same second never share a picture), in time order for the above.
        let url = folder.appending(path: "look-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).png")
        let rep = NSBitmapImageRep(cgImage: clean)
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url, options: .atomic)) != nil else { return (nil, note, false) }
        return (url.path, note, false)
    }

    // MARK: Apps

    private func apps(_ args: [String: Any], caller: String?, live: @escaping @Sendable () -> Bool, _ send: @escaping (Any) -> Void,
                      _ fail: @escaping (String) -> Void) {
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
                return Self.off(live, {
                    let appURL = name.isEmpty ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID(name))
                    // Its asker gone while the app was looked up: nothing opens.
                    guard live() else { return }
                    if let appURL {
                        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                    } else {
                        NSWorkspace.shared.open(url)
                    }
                }) { ran in if ran { send(["opened": target]) } }
            }
            // The name is looked up off the main thread (it scans the Applications folders); the launch is the dock's.
            var found: (id: String, url: URL?) = (name, nil)
            Self.off(live, {
                let id = Self.bundleID(name)
                found = (id, NSWorkspace.shared.urlForApplication(withBundleIdentifier: id))
            }) { [weak self] ran in
                guard let self, ran, live() else { return }
                guard found.url != nil else { return fail("No app called \(name) is installed.") }
                self.app.docks.launch(found.id)
                send(["opened": Apps.name(found.id)])
            }
        case "quit", "hide", "focus":
            guard let running = running(name) else { return fail("\(name) isn't open.") }
            let label = running.localizedName ?? name
            switch action {
            // Each asks the app (or Launch Services): off the main thread, the answer back on it.
            case "hide": Self.off(live, { running.hide() }) { ran in if ran { send(["hidden": label]) } }
            case "focus":
                let url = running.bundleURL
                Self.off(live, {
                    guard let url else { return }
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.addsToRecentItems = false
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                }) { ran in
                    guard ran else { return }
                    if url == nil, live() { running.activate() }
                    send(["focused": label])
                }
            default:
                ask("quit", "Quit \(label)", detail: "It asks to save anything unsaved.", owner: caller) { allowed in
                    guard allowed, live() else { return send(["declined": "The person didn't allow quitting \(label)."]) }
                    Self.off(live, { running.terminate() }) { ran in
                        guard ran else { return }
                        self.did("Quit \(label)")
                        send(["quit": label])
                    }
                }
            }
        default:
            fail("action is open, quit, hide or focus")
        }
    }

    /// Does `work` (which waits on another app) off the main thread, then `then` back on it. `live`: whoever asked
    /// is still there (or the routine still running), read on that thread right before `work`: one gone while it
    /// waited its turn gets nothing done, and `then` hears it didn't run (false). A `work` that waits before its
    /// change (a lookup) reads `live` again right before the change.
    nonisolated static func off(_ live: @escaping @Sendable () -> Bool, _ work: @escaping () -> Void,
                                then: @escaping @MainActor (_ ran: Bool) -> Void) {
        queue.async {
            let ran = live()
            if ran { work() }
            DispatchQueue.main.async { MainActor.assumeIsolated { then(ran) } }
        }
    }

    /// A bundle id for an app's name (or the id itself).
    nonisolated private static func bundleID(_ name: String) -> String {
        if name.contains(".") && !name.contains(" ") { return name }
        return MCP.apps(matching: name).first { ($0["name"] ?? "").caseInsensitiveCompare(name) == .orderedSame }?["id"]
            ?? MCP.apps(matching: name).first?["id"] ?? name
    }

    // MARK: Windows

    private func windows(_ args: [String: Any], caller: String?, live: @escaping @Sendable () -> Bool, _ send: @escaping (Any) -> Void,
                         _ fail: @escaping (String) -> Void) {
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
                    // Its asker gone while the windows were read: nothing is asked or done for it.
                    guard live() else { return }
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
                        Self.off(live, { AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }) { ran in
                            if ran { send(["minimized": label]) }
                        }
                    case "close":
                        self.ask("close", "Close “\(label)”", detail: "Its app asks to save anything unsaved.", owner: caller) { allowed in
                            guard allowed, live() else { return send(["declined": "The person didn't allow closing it."]) }
                            let element = window.element
                            var pressed = false
                            Self.off(live, {
                                guard let button: AXUIElement = Windows.value(element, kAXCloseButtonAttribute) else { return }
                                // Its asker gone while the app answered: the window stays.
                                guard live() else { return }
                                AXUIElementPerformAction(button, kAXPressAction as CFString)
                                pressed = true
                            }) { ran in
                                guard ran, pressed || live() else { return }
                                self.did("Closed “\(label)”")
                                send(["closed": label])
                            }
                        }
                    case "arrange":
                        let layout = args["layout"] as? String ?? "full"
                        guard let frame = self.arranged(window, layout) else { return fail("layout is left, right, top, bottom, full or center") }
                        Self.queue.async {
                            guard live() else { return }   // its asker gone while it waited its turn
                            _ = Windows.place(window.element, pid: window.pid, frame, live: live)
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
    private func trash(_ args: [String: Any], caller: String?, live: @escaping @Sendable () -> Bool, _ send: @escaping (Any) -> Void,
                       _ fail: @escaping (String) -> Void) {
        if args["undo"] as? Bool == true {
            let items = trashed
            Self.queue.async {
                var back: [String] = []
                var stuck: [(from: URL, to: URL)] = []
                for item in items {
                    // Its asker gone meanwhile: the rest stays in the Trash, to put back another time.
                    guard live() else { stuck.append(item); continue }
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
            detail: urls.count == 1 ? "You can put it back." : names, owner: caller) { allowed in
            guard allowed, live() else { return send(["declined": "The person didn't allow it."]) }
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
