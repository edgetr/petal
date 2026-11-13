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
/// Always, Don't), unless the chat has Full access or the person said Always for that kind of thing. Both cover Petal
/// AI and the person's own Claude Code and Codex; any other program is asked every time, on a card that says who it
/// is. Files go to the Trash, never away for good, and the last batch can be put back.
///
/// It also remembers what the person says to remember and what the AI notices on its own (`aiMemory`).
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
    /// Using the person's apps with a pointer of its own (ComputerUse.swift).
    @ObservationIgnored let computer = ComputerUse()
    nonisolated private static let queue = DispatchQueue(label: "petal.assist", qos: .userInitiated, attributes: .concurrent)

    var app: PetalApp { PetalApp.shared }
    var config: Config { app.config }

    func start() {
        loadMemories()
        loadHistory()
    }

    // MARK: Asking first

    enum Choice { case once, always, no }

    /// Allowed already (Full access, or Always for this kind), or asked with a card; `done` hears the answer.
    /// `always`: asked even with Full access (the vault). `form`: the card takes what the person types for the vault,
    /// handed to `typed` before `done`. `warn`: Don't is the default (what's asked doesn't match).
    /// `keep`: the label of an Always kept as `kept` says (an agent's grant), shown even when Don't is the default.
    /// `owner`: the chat or AI session asking (Assist.handle's caller), always said: its Stop, next turn or hanging up
    /// answers its card Don't. Only what no chat asked for (a routine's own run) passes nil.
    /// Full access and Always cover Petal's own chats and helpers (an owner the panel knows), a routine's own run, and
    /// the person's own Claude Code and Codex outside Petal (signed by their makers), whose cards say who asks and
    /// `wants` (what for: "use Mail") under that agent's mark. Anyone else (a program, a command, an agent Petal
    /// can't verify) gets a card every time, with no Always, that says the same.
    func ask(_ kind: String, _ title: String, wants: String? = nil, detail: String = "", always: Bool = false, form: VaultForm? = nil, warn: Bool = false,
             allow: String = "Allow", owner: String?, keep: String? = nil, mark: AgentAccess.Agent? = nil, kept: (() -> Void)? = nil,
             typed: ((VaultForm.Answer) -> Void)? = nil, done: @escaping (Bool) -> Void) {
        let asker = NoteHelp.asker(owner: owner, known: owner.map { app.claude.note(withID: $0) != nil } ?? false,
                                   verified: owner.flatMap { outside[$0] }?.agent.verified ?? false)
        // `always` (the vault) asks every time: neither Full access nor an earlier Always skips it.
        // An automatic approval (an Always given earlier, or Full access) is registered on the asking helper's run
        // first: taking that Always back cancels every run using it. A run that isn't going on is refused.
        if form == nil, !always, !warn,
           let grant = NoteHelp.autoGrant(kind: kind, fullAccess: config.string("claudeAccess") == "full", allowed: config.strings("aiAllowed"), asker: asker) {
            return done(app.paper.helpers.authorized(owner, grant))
        }
        settle(false)   // one question at a time: a newer one replaces an older one, which is declined
        formTyped = typed
        keptAlways = keep == nil ? nil : kept
        // Who asks, when it isn't Petal AI: as Petal read it off the socket with this caller's request.
        let who = asker == .outside || asker == .agent ? owner.flatMap { outside[$0] } : nil
        let card = NoteHelp.card(title: title, wants: wants, every: always || warn, asker: asker, label: who?.label)
        let request = Request(kind: kind, title: card.title, detail: detail, every: card.every, owner: owner, form: form, warn: warn,
                              allow: allow, keep: keep, mark: mark ?? (asker == .outside || asker == .agent ? who?.agent ?? .unknown : nil))
        pending = request
        answer = done
        // In the chat when it's open and the question is its own (the card shows there); over the dock otherwise
        // (another chat or AI session asking).
        if let owner, app.paper.helpers.owns(owner) {
            // A helper in a note asks on the note itself.
            app.paper.helpers.asking(owner)
        } else if Headless.on {
            // A headless run (a check) never orders a window in: its question waits to be answered, shown nowhere.
        } else if !app.claude.isOpen || !showsInChat(request) {
            // Over the dock; with no Petal dock showing (macOS's in use), in the chat asking, which shows the question.
            if app.docks.focusedDock?.panel != nil { app.popups.showAsk() }
            else if let owner, let note = app.claude.note(withID: owner) { app.claude.present(note) }
            else if !app.claude.isOpen { app.claude.open(asking: nil) }
        }
        // A helper's card waits on its note for as long as it takes (the run holds its place; Stop ends it). Anyone
        // else's goes after two minutes, told as unanswered, not as a no.
        if let owner, app.paper.helpers.owns(owner) { return }
        let work = DispatchWorkItem { [weak self] in self?.settle(false, unanswered: true) }
        giveUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
    }

    /// The last card closed with nobody answering it (two minutes went by), rather than with Don't.
    @ObservationIgnored private(set) var unanswered = false

    /// What the AI is told when its card came back without a yes: `words` for a Don't, or that nobody answered.
    func declined(_ words: String) -> String {
        unanswered ? "The person hasn't answered yet (the card closed after two minutes). Say in one line what you need, and stop." : words
    }

    @ObservationIgnored private var formTyped: ((VaultForm.Answer) -> Void)?
    @ObservationIgnored private var keptAlways: (() -> Void)?
    /// Who each caller outside Petal is, by the name its requests go under (`mcp-<pid>`): as Petal read it off the
    /// socket with that caller's latest request (`handle`), for what its cards say. Never what the caller says.
    @ObservationIgnored private var outside: [String: AgentAccess.Caller] = [:]

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
        app.paper.helpers.answered(pending, choice)
        if choice == .always, !pending.every {
            var allowed = config.strings("aiAllowed")
            if !allowed.contains(pending.kind) { allowed.append(pending.kind); config.set("aiAllowed", allowed) }
        }
        settle(choice != .no)
    }

    private func settle(_ allowed: Bool, unanswered: Bool = false) {
        self.unanswered = unanswered
        formTyped = nil
        keptAlways = nil
        giveUp?.cancel()
        giveUp = nil
        let done = answer
        answer = nil
        pending = nil
        app.popups.closeAsk()
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

    /// That one card, if it's still up, is answered Don't.
    func decline(card: UUID) {
        if pending?.id == card { settle(false) }
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
                reply answer: @escaping @MainActor (String) -> Void) {
        // A note's helper: the admission gate (NoteHelpers.admit), from what's true now, before the tool runs and
        // again right before its answer goes back (what it waited on may have changed meanwhile).
        let reply: @MainActor (String) -> Void = { [weak self] text in
            if let refusal = self?.app.paper.helpers.admitTool(note) {
                let data = (try? JSONSerialization.data(withJSONObject: ["error": refusal])) ?? Data("{}".utf8)
                return answer(String(decoding: data, as: UTF8.self))
            }
            answer(text)
        }
        if let refusal = app.paper.helpers.admitTool(note) {
            let data = (try? JSONSerialization.data(withJSONObject: ["error": refusal])) ?? Data("{}".utf8)
            return answer(String(decoding: data, as: UTF8.self))
        }
        // Read on any thread: the socket's own flag, set the moment its client closes. Every change made for an
        // outside caller reads it on the thread making the change, right before it (`off`, an act's or a vault
        // call's `Acting.Cancel`, a routine's `RoutineStop`), never waiting for the main thread's `hungUp`.
        let gone: @Sendable () -> Bool = { request?.hungUp == true }
        let live: @Sendable () -> Bool = { !gone() }
        guard live() else { return }   // its client went before Petal got to it: nothing to answer
        // Who a caller outside Petal is goes with its requests to every card made for them (`ask`).
        if let note, let who {
            if outside.count > 200 {
                outside = outside.filter { name, _ in name.hasPrefix("mcp-") ? Int32(name.dropFirst(4)).map { kill($0, 0) == 0 } ?? false : true }
            }
            outside[note] = who.agent == .petal ? nil : who
        }
        // An AI session outside Petal keeps its hidden display while it keeps asking (RunDisplays).
        app.displays.touched(note)
        let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        let send: (Any) -> Void = { result in
            let object: Any = JSONSerialization.isValidJSONObject(result) ? result : ["result": "\(result)"]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
            reply(String(decoding: data, as: UTF8.self))
        }
        let fail = { (text: String) in send(["error": text]) }
        switch name {
        // The note's window as it is now (a note stuck to none, or notes off: what's in front).
        case "petal_look":
            // A note's helper waiting for its note's place: never what was there before, or what's in front now.
            if (args["app"] as? String ?? "").isEmpty, args["front"] as? Bool != true, let waiting = app.claude.helperWaiting(note) { return fail(waiting) }
            look(args, place: app.claude.placed(note), note: note, send)
        case "petal_apps": apps(args, caller: note, label: who.map { $0.agent == .petal ? "" : $0.label } ?? "", live: live, send, fail)
        case "petal_windows": windows(args, caller: note, live: live, send, fail)
        case "petal_trash": trash(args, caller: note, live: live, send, fail)
        case "petal_remember":
            guard config.bool("aiMemory") else { return fail("Memory is off in Petal's settings (aiMemory).") }
            let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return fail("Nothing to remember.") }
            let memory = remember(text, learned: args["learned"] as? Bool ?? false)
            did("Remembered \(quoted: memory.text, else: "something")", undo: .forget(memory.id))
            send(["remembered": memory.text, "id": memory.id])
        case "petal_forget":
            let gone = forget(id: args["id"] as? String, matching: args["text"] as? String)
            for memory in gone { did("Forgot \(quoted: memory.text, else: "something")", undo: .remember(memory.text)) }
            send(["forgot": gone.map(\.text)])
        case "petal_show":
            do {
                let title = args["title"] as? String ?? "Petal"
                let file = try Pages.show(title: title, markdown: args["markdown"] as? String,
                                          html: args["html"] as? String, path: args["path"] as? String, update: args["update"] as? String)
                did("Made a page\(named: ": " + title, else: "")", undo: .open(file.path, title))
                send(["opened": file.path])
            } catch { fail(error.localizedDescription) }
        case "petal_vault": vault(args, caller: note, who: who, gone: request == nil ? nil : gone, send, fail)
        case "petal_browser": browser(args, caller: note, who: who, gone: request == nil ? nil : gone, send, fail)
        case "petal_ui", "petal_act": computer.handle(name, args, note: note, gone: request == nil ? nil : gone, send: send, fail: fail)
        case "petal_routines", "petal_routine_save", "petal_routine_run", "petal_routine_undo", "petal_routine_delete":
            // Its asker hanging up stops a tidy's moves under way off the main thread, not only what comes next.
            let stop = RoutineStop(also: gone)
            request?.onHangUp { stop.stop() }
            app.routines.handle(name, args, send, fail, caller: note, live: live, stop: stop)
        case _ where Viewers.tools.contains(name):
            app.viewers.handle(name, args, caller: note ?? "petal", live: live, send, fail)
        case _ where NoteDesk.tools.contains(name):
            // Its asker hanging up stops what's still to come: each change checks `live` right before it's made.
            // `asker`: the note a helper's request comes from (its paper's id), what Private notebooks go by; `caller`: its chat.
            app.paper.handle(name, args, asker: note.flatMap { app.claude.note(withID: $0)?.paper }, caller: note, live: live, send, fail)
        case "petal_memories":
            send(["memories": memories.map(record)])
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

    /// What's in front: the app, its window, the browser's tab, selected text, the other windows showing;
    /// with `screenshot` ("window" or "screen") a picture saved where the AI can read it, and the clipboard if asked.
    /// A sticky note (`place`) looks at its own window instead, wherever the person is now, unless it asks for an app
    /// or for what's in front (`front`).
    private func look(_ args: [String: Any], place: NotePlace? = nil, note: String? = nil, _ send: @escaping (Any) -> Void) {
        let named = args["app"] as? String ?? ""
        let wantsFront = args["front"] as? Bool == true
        let wantsDisplay = args["display"] as? Bool == true
        // The run's own window on its hidden display (RunDisplays): asked for (display: true), or the app named has
        // one there. Never with front: true, which is what the person has in front.
        let own = wantsFront ? nil : app.displays.window(for: note, app: named, newest: wantsDisplay)
        let ownDisplay = wantsFront ? nil : app.displays.display(for: note)
        if wantsDisplay, own == nil, (args["screenshot"] as? String) != "screen" {
            return send(["note": ownDisplay == nil ? "You have no display of your own now. petal_apps open (on: \"display\") puts a window on one."
                                                   : "None of your windows\(named.isEmpty ? "" : " of \(named)") is on your display. petal_apps open puts one there."])
        }
        let place = own == nil && named.isEmpty && !wantsFront ? place : nil
        let stuck = place?.running
        let front = own.flatMap { NSRunningApplication(processIdentifier: $0.pid) } ?? (place == nil ? frontApp(named: named) : stuck)
        let placed: CGWindowID? = if case .window(let number)? = place?.target { number } else { nil }
        let wanted: CGWindowID? = own?.window ?? placed
        var result: [String: Any] = [:]
        if own != nil { result["display"] = "This window is on your own display: the person doesn't see it." }
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
        result["onScreen"] = Set(NSWorkspace.shared.personsApplications.filter { $0.activationPolicy == .regular && !$0.isHidden }
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
        // The window's words: asked for with text, or a word to find, or a part of them.
        let find = (args["find"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let part = (args["part"] as? NSNumber)?.intValue ?? Int(args["part"] as? String ?? "")
        let wantsText = args["text"] as? Bool == true || !find.isEmpty || part != nil
        // A note stuck to one tab looks only while that tab is the one its window shows: never at another tab.
        // Checked before reading and again once everything is read, right before it's told (`deliver`).
        let tabPlace = place.flatMap { $0.kind == .tab && $0.tab != nil ? $0 : nil }
        Self.queue.async {
            let state = tabPlace.map { ClaudePanel.tabState($0) }
            let before = state?.showing
            if let tabPlace, let state, before == nil {
                return DispatchQueue.main.async { send(["note": ClaudePanel.tabWords(state, browser: tabPlace.appName)]) }
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
                        send(["note": own != nil ? "That window of yours is closed (it was in \(name))."
                                                 : "This note's window is closed (it was in \(name)). front: true looks at what's in front now."])
                    }
                }
                window = match
            }
            let number = window.flatMap { Windows.id(of: $0) }
            let realTitle: String = window.flatMap { Windows.value($0, kAXTitleAttribute) } ?? ""
            let frame = window.flatMap { Windows.frame(of: $0) } ?? .zero
            let focused: AXUIElement? = number == focusedID ? Windows.value(element, kAXFocusedUIElementAttribute) : nil
            // Never the selection in Petal's own windows: a note's words are told through the note tools, which keep
            // a Private notebook's to itself.
            let selected: String = pid == getpid() ? "" : focused.flatMap { Windows.value($0, kAXSelectedTextAttribute) } ?? ""
            // Nothing of the vault's secrets goes to the AI: not in the title, the selection, nor the clipboard.
            let title = Self.withoutSecrets(realTitle)
            // Nothing selected in a field holding a secret, not even part of one: a card number selected four
            // digits at a time would otherwise be told whole over four looks.
            let inSecret = !selected.isEmpty && focused.map { Self.selectionInSecret($0, pid: pid, window: number) } == true
            let shownSelection = selected.isEmpty ? "" : inSecret ? Self.selectionInSecret
                : Self.shownText(selected, limit: 8000) ?? Self.tooMuchSelected
            let shownClipboard = clipboard.map { Self.shownText($0, limit: 4000) ?? Self.tooMuchClipboard }
            let looked = window
            let words = wantsText ? Self.words(pid: pid, window: number, find: find, part: part ?? 1) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Another run's display is none of this one's: nothing of its window is told.
                    if looked != nil, self.app.displays.foreign(frame, to: note) || self.app.displays.foreign(window: number, to: note) {
                        return send(["note": "\(front.localizedName ?? "That app")'s window there belongs to another helper's work, on a display of its own: Petal keeps them apart."])
                    }
                    result["window"] = title
                    if let words { result.merge(words) { _, new in new } }
                    if !shownSelection.isEmpty { result["selectedText"] = shownSelection }
                    if let shownClipboard { result["clipboard"] = shownClipboard }
                    let hidden = self.privatePIDs
                    // Petal's own windows showing a Private notebook's note: never in a picture.
                    let shielded = self.app.paper.privateWindowNumbers()
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
                                if words?["text"] != nil { self.did("Read the words in \(named: front.localizedName ?? "", else: "a window")") }
                                if picture != nil {
                                    self.did(shot != "screen" ? "Looked at \(named: front.localizedName ?? "", else: "a window")"
                                             : ownDisplay != nil ? "Looked at its own display" : "Looked at your screen")
                                }
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
                            let state = ClaudePanel.tabState(tabPlace)
                            // The same tab of the same window it read: its id or button, place and address unchanged.
                            let same = state.showing.map { now in
                                now.window == before.window && before.window == number && now.tab.id == before.tab.id
                                    && now.tab.element == before.tab.element && now.tab.index == before.tab.index
                                    && now.tab.count == before.tab.count && now.tab.url == before.tab.url
                            } ?? false
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated { same ? tell() : refuse(["note": ClaudePanel.tabWords(state, browser: tabPlace.appName)]) }
                            }
                        }
                    }
                    let finish = {
                        guard !shot.isEmpty else { return deliver(nil) }
                        Task {
                            // A run with a display of its own sees that display, never the person's screen (front: true does).
                            let picture = await Self.screenshot(shot == "screen" ? nil : number, screen: shot == "screen", display: ownDisplay?.number,
                                                                hiding: hidden, excluding: shielded)
                            if let path = picture.path {
                                let what = shot != "screen" ? "window" : ownDisplay != nil ? "display of your own (the person's screen isn't in it; front: true shows that; a menu bar along its top would be the system's, for whichever app is in front, not your window's)" : "screen"
                                result["screenshot"] = path
                                result["screenshotNote"] = "A PNG of the \(what); read it to see it. Black boxes are fields that may hold a password, card number, security code or key: Petal hides them."
                                    + (picture.note.map { " " + $0 } ?? "")
                            } else {
                                result["screenshotNote"] = picture.note ?? (Capture.allowed ? "Couldn't take the picture." : Self.askScreenRecording())
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
                        // A browser that hasn't been asked yet: the AI says so, instead of the address just missing.
                        if url == nil, Browsers.waiting(front.bundleIdentifier ?? "") {
                            result["tabNote"] = "Petal hasn't been allowed to read this browser's tabs yet, so there's no address (the person allows it in Petal's settings, Privacy)."
                        }
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

    /// What petal_look tells of a window's words (`text`, with `find` and `part`): read through Accessibility within
    /// three seconds, by petal_ui's rules (`Reader.read` with `words`: a password field never, every text through the
    /// vault's redaction, a secret shown in pieces hidden in each), then each line and the whole once more; nothing
    /// while the vault can't be read, and all of it read again if the vault changed meanwhile (`VaultIndex.settled`).
    /// Never Petal's own windows. Off the main thread.
    nonisolated static func words(pid: pid_t, window: CGWindowID?, find: String, part: Int) -> [String: Any] {
        if let own = UIMap.petalsOwn(pid) { return ["textNote": own] }
        guard Windows.trusted else {
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = Assist.askAccessibility() } }
            return ["textNote": Assist.accessibilityAsked]
        }
        let unreadable: [String: Any] = ["textNote": VaultStore.unreadableText + " Petal can't hide its secrets, so it doesn't read a window's words until it can: try again in a moment."]
        let made: [String: Any]?? = VaultIndex.settled { index -> [String: Any]? in
            guard !index.unreadable else { return nil }
            let reading = Reader.read(pid: pid, window: window, budget: 3, words: true)
            guard !reading.vaultUnreadable else { return nil }
            if reading.gone || reading.window == nil { return ["textNote": "Petal couldn't find that window to read its words."] }
            // What's told (one part, or the passages around a word) checked whole for a secret shown in pieces, whatever
            // the window's own scan managed (a long page runs out of time), each line and the whole redacted again.
            let checkBy = Date().addingTimeInterval(1.5)
            let made = WindowText.told(shown: reading.nodes, raw: reading.raw, part: part, find: find, redact: index.redacted,
                                       matches: index.matches, spans: index.spans, going: { Date() < checkBy })
            var told: [String: Any] = [:]
            if made.cut || reading.timedOut { told["partial"] = "Petal read what it could of this window in time: the rest of it isn't here." }
            guard let text = made.text else {
                told["textNote"] = "Petal couldn't finish checking this part for saved secrets, so it isn't told: ask again, or find a word to read less."
                return told
            }
            if find.isEmpty, made.parts == 0 || text.isEmpty {
                told["textNote"] = "Petal found no words in this window: the app may not show its text to Accessibility (a screenshot shows it)."
                return told
            }
            told["text"] = text
            if !find.isEmpty {
                told["found"] = made.found
                if made.found == 0 { told["textNote"] = "No “\(index.redacted(find))” in what Petal read of this window: try another word, or read all of it (text: true, without find)." }
                if made.findLeft > 0 { told["more"] = "\(made.findLeft) more places with it didn't fit: find a longer phrase, or read the parts." }
                return told
            }
            // A part past the end: said so, and nothing told twice.
            if part > made.parts {
                return ["textNote": made.parts == 1 ? "This window's words were all in one part: there's no part \(part)."
                                                    : "This window's words have \(made.parts) parts: part \(made.parts) was the last.",
                        "parts": made.parts]
            }
            if made.parts > 1 {
                told["part"] = made.part
                told["parts"] = made.parts
            }
            if made.left > 0 { told["more"] = "\(made.left) more characters: petal_look with part: \(made.part + 1) gives the next part (find: a word gives only the passages around it)." }
            return told
        }
        guard case .some(.some(let told)) = made else { return unreadable }
        return told
    }

    /// When Petal last asked the person for Screen Recording or Accessibility from a tool: at most once a minute each,
    /// so a run that keeps trying doesn't keep asking.
    private static var asked: [String: Date] = [:]

    /// Whether it asked now (else it asked within the last minute).
    @discardableResult
    private static func askOnce(_ what: String, _ ask: () -> Void) -> Bool {
        if let last = asked[what], Date().timeIntervalSince(last) < 60 { return false }
        asked[what] = Date()
        ask()
        return true
    }

    /// A picture was asked for without Screen Recording: macOS asks the person (`Capture.askForPermission`), and the
    /// AI is told so, in a line.
    static func askScreenRecording() -> String {
        let now = askOnce("screen") { Capture.askForPermission() }
        return "Petal can't take pictures yet: it \(now ? "just asked" : "is waiting for") the person to allow Screen Recording (Settings › Privacy shows it too). Tell them in one line; ask again once it's allowed."
    }

    /// The same for Accessibility, which reading and using apps need.
    @discardableResult
    static func askAccessibility() -> String {
        askOnce("accessibility") { Windows.askForPermission() }
        return accessibilityAsked
    }

    nonisolated static let accessibilityAsked = "Petal can't read or use apps yet: it just asked the person to allow Accessibility (Settings › Privacy shows it too). Tell them in one line; ask again once it's allowed."

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
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me, !RunBrowsers.isRun(front.processIdentifier) { return front }
        return nil
    }

    func running(_ name: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.personsApplications.filter { $0.activationPolicy == .regular }
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
    /// `display`: the screen pictured is this one (a run's own hidden display) rather than the person's main screen.
    nonisolated private static func screenshot(_ window: CGWindowID?, screen: Bool = false, display: CGDirectDisplayID? = nil,
                                               hiding: Set<pid_t> = [], excluding: Set<Int> = []) async -> (path: String?, note: String?) {
        var why: String?
        for _ in 0..<2 {
            let taken = await capture(window, screen: screen, display: display, hiding: hiding, excluding: excluding)
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

    /// `excluding`: Petal's own windows showing a Private notebook's note (NotePrivacy.excludedWindows): left out of
    /// a picture of the screen, and a picture of one of them alone is never taken.
    nonisolated private static func capture(_ window: CGWindowID?, screen: Bool, display wanted: CGDirectDisplayID? = nil, hiding: Set<pid_t>,
                                            excluding: Set<Int> = []) async -> (path: String?, note: String?, moved: Bool) {
        guard screen || window != nil else { return (nil, nil, false) }
        if !screen, let window, !NotePrivacy.mayCapture(window: Int(window), excluded: excluding) {
            return (nil, "That window shows a note from a Private notebook: Petal takes no picture of it.", false)
        }
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
        } else if let display = content.displays.first(where: { $0.displayID == (wanted ?? Screens.mainDisplay) })
                    // "The screen" is the person's, never a run's hidden display; a run's own display that's gone is no picture.
                    ?? (wanted == nil ? content.displays.first { !Screens.isRun($0.displayID) } : nil) {
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
            for candidate in content.windows where candidate.isOnScreen && candidate.frame.intersects(area)
                && NotePrivacy.mayCapture(window: Int(candidate.windowID), excluded: excluding) {
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

    private func apps(_ args: [String: Any], caller: String?, label: String = "", live: @escaping @Sendable () -> Bool, _ send: @escaping (Any) -> Void,
                      _ fail: @escaping (String) -> Void) {
        let action = args["action"] as? String ?? ""
        let name = args["app"] as? String ?? ""
        let target = args["open"] as? String ?? ""
        switch action {
        case "open":
            // A run with hidden displays on opens on a display of its own (RunDisplays), unless it says the person's screen.
            let asked = args["on"] as? String
            if let caller, app.displays.place(for: caller, asked: asked) == .display {
                return openOnDisplay(name: name, target: target, caller: caller, label: label, live: live, send, fail)
            }
            if asked?.lowercased() == RunDisplayRules.Place.display.rawValue {
                return fail(app.config.bool("runDisplays") ? RunDisplayRules.unavailable : RunDisplayRules.off)
            }
            if !target.isEmpty {
                // An address or a file, in its app (or the one named).
                let url = target.contains("://") ? URL(string: target) : URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
                guard let url else { return fail("That isn't an address or a file.") }
                // Finding the app (a scan of the Applications folders) and Launch Services wait on the disk or the
                // app: off the main thread.
                let opener = OpenedOnDisplay()
                return Self.off(live, {
                    let appURL = name.isEmpty ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID(name))
                    opener.bundle = (appURL ?? NSWorkspace.shared.urlForApplication(toOpen: url)).flatMap { Bundle(url: $0)?.bundleIdentifier } ?? ""
                    // Its asker gone while the app was looked up: nothing opens.
                    guard live() else { return }
                    if let appURL {
                        let configuration = NSWorkspace.OpenConfiguration()
                        // A run's own copy of that browser is never the one this opens in (as DockController.launch).
                        if RunApps.running(bundle: opener.bundle) { configuration.createsNewApplicationInstance = true }
                        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
                    } else {
                        NSWorkspace.shared.open(url)
                    }
                }) { [weak self] ran in
                    guard ran else { return }
                    // Opened for the person to see: an app a run had started on a display is theirs from now on.
                    self?.app.displays.handedOver(bundle: opener.bundle)
                    send(["opened": target])
                }
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
                self.app.displays.handedOver(bundle: found.id)
                send(["opened": Apps.name(found.id)])
            }
        case "quit", "hide", "focus":
            guard let running = running(name) else { return fail("\(name) isn't open.") }
            let label = running.localizedName ?? name
            // An app a run started on its display, which the person never saw: another run's is none of this one's,
            // and its own quits without a card and never comes forward (RunDisplayRules.apps).
            let owner = app.displays.owner(of: running.processIdentifier, for: caller)
            let answer = RunDisplayRules.apps(action, owner: owner)
            if answer == .refuse {
                return fail(owner == .another
                    ? "\(label) belongs to another helper's work, on a display of its own: Petal keeps them apart, and nothing of it is quit, hidden or brought forward from here."
                    : "\(label) is on your own display, where nothing comes forward. Work in it with petal_ui and petal_act; petal_windows with action: show brings its windows to the person's screen when they need to see one.")
            }
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
                let quit = {
                    Self.off(live, { running.terminate() }) { ran in
                        guard ran else { return }
                        self.did("Quit \(named: label, else: "an app")")
                        send(["quit": label])
                    }
                }
                // Its own, which the person never saw: the run's to put away, with nobody to ask.
                if answer == .go { return quit() }
                ask("quit", "Quit \(label)", wants: "quit \(label)", detail: "It asks to save anything unsaved.", owner: caller) { allowed in
                    guard allowed, live() else { return send(["declined": self.declined("The person didn't allow quitting \(label).")]) }
                    quit()
                }
            }
        default:
            fail("action is open, quit, hide or focus")
        }
    }

    /// Opens an app, a file or an address on the caller's own hidden display: the app it opens in is found first,
    /// then its display (now, or once it's its turn), then its turn for that app (another run using it on its display
    /// has it until it ends or lets go: "Waiting for TextEdit"), then the open without activating anything, and the
    /// window that results moved there through Accessibility (`RunDisplays.open`). Only a window that wasn't there
    /// before is moved: one the person had is never taken. Where nothing new would result (a browser already open
    /// takes an address as a tab in the person's own window; an app already open shows nothing new), nothing is
    /// opened and it says so. An app this open started is the run's to put away when it ends.
    private func openOnDisplay(name: String, target: String, caller: String, label: String, live: @escaping @Sendable () -> Bool,
                               _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        var url: URL?
        if !target.isEmpty {
            url = target.contains("://") ? URL(string: target) : URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            guard url != nil else { return fail("That isn't an address or a file.") }
        } else if name.isEmpty {
            return fail("Give an app, a file or an address to open.")
        }
        // Which app: looked up off the main thread (it scans the Applications folders).
        let found = OpenedOnDisplay()
        Self.off(live, {
            let appURL: URL?
            if !name.isEmpty {
                appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID(name))
            } else {
                appURL = url.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            }
            guard let appURL, let bundle = Bundle(url: appURL)?.bundleIdentifier else { return }
            found.appURL = appURL
            found.bundle = bundle
            found.app = appURL.deletingPathExtension().lastPathComponent
        }) { [weak self] ran in
            guard let self, ran, live() else { return }
            guard let appURL = found.appURL else {
                return fail(name.isEmpty ? "No app on this Mac opens that." : "No app called \(name) is installed.")
            }
            let bundle = found.bundle, appName = found.app
            self.app.displays.need(caller, label: label) { [weak self] result in
                guard let self, live() else { return }
                if case .failure(let why) = result { return fail(why.words) }
                // Its turn for the app: another run using it on its display has it until it ends or lets it go.
                self.app.displays.turn(caller, app: bundle, name: appName, hold: true) { [weak self] refused in
                    guard let self else { return }
                    if let refused {
                        if live() { fail(refused.words) }
                        return
                    }
                    // From here its turn is given back whatever becomes of the open.
                    let displays = self.app.displays
                    guard live(), let display = displays.display(for: caller) else {
                        displays.finished(caller, app: bundle)
                        if live() { fail(RunDisplays.Failure.ended.words) }
                        return
                    }
                    let frame = display.frame
                    let index = displays.nextIndex(for: caller)
                    Self.off(live, {
                        found.opened = RunDisplays.open(appURL: appURL, bundle: bundle, url: url, on: frame, index: index, live: live)
                    }) { [weak self] ran in
                        guard let self else { return }
                        let opened = found.opened
                        // What it started and what it made are its own, whoever is still there to hear of it: the
                        // run's ending puts them away.
                        if let pid = opened.launched { displays.launched(pid, bundle: bundle, name: appName, by: caller) }
                        if !opened.moved.isEmpty {
                            displays.track(opened.moved, for: caller, bare: url == nil, panels: opened.panels, app: (bundle, appName))
                        }
                        displays.finished(caller, app: bundle)
                        guard ran, live() else { return }
                        if let problem = opened.problem { return fail(problem) }
                        let what = target.isEmpty ? appName : target
                        guard !opened.moved.isEmpty else {
                            return send(["opened": what, "on": "the person's screen",
                                         "note": opened.stayed > 0
                                            ? "\(appName) wouldn't let Petal move its window, so it's on the person's screen, not your display."
                                            : "\(appName) showed no new window for it (it may have opened in a window the person already had), so nothing is on your display."])
                        }
                        self.did("Opened \(named: appName, else: "an app") on a display of its own")
                        var reply: [String: Any] = ["opened": what, "app": appName, "on": "your own display",
                              "next": "petal_ui with app: \"\(appName)\" reads it there, and petal_act works in it without a pointer and without bringing anything forward. The person doesn't see it; petal_look with a screenshot shows you."]
                        if opened.launched != nil {
                            reply["yours"] = "\(appName) wasn't open, so it's yours: when you're done Petal quits it, unless the person used it meanwhile, you showed it to them (petal_windows, action: show) or it has unsaved changes."
                        }
                        send(reply)
                    }
                }
            }
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
        // A run brings what's on its own display to the person's screen: moved there, nothing raised or activated.
        if action == "show" {
            guard let caller, app.displays.display(for: caller) != nil else { return fail("You have no display of your own now, so nothing is on one.") }
            return app.displays.bringOut(for: caller) { count in
                guard live() else { return }
                send(["shown": count, "note": count == 0 ? "None of your windows was on your display."
                                                         : "On the person's screen now, behind what they're doing; nothing came forward. What you open next still goes to your display."])
            }
        }
        let pids: [pid_t]
        if !appName.isEmpty {
            guard let running = running(appName) else { return fail("\(appName) isn't open.") }
            pids = [running.processIdentifier]
        } else {
            pids = NSWorkspace.shared.personsApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)
        }
        Self.queue.async {
            var found: [AppWindow] = []
            // A run's own display too: whose windows each caller sees is decided below.
            for pid in pids { found += Windows.windows(of: pid, everywhere: true) }
            // Each title as the AI may be told it: the vault's secrets taken out, as petal_look's are (here, off the
            // main thread, since it may read the Keychain).
            let titles = Dictionary(found.map { ($0.id, Self.withoutSecrets($0.title)) }, uniquingKeysWith: { first, _ in first })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Its asker gone while the windows were read: nothing is asked or done for it.
                    guard live() else { return }
                    // Another run's display is none of this one's: its windows aren't listed, found or touched.
                    let found = found.filter { !self.app.displays.foreign($0.frame, to: caller) && !self.app.displays.foreign(window: $0.number, to: caller) }
                    let mine = { (window: AppWindow) in caller.map { self.app.displays.holds(window.frame, for: $0) } ?? false }
                    if action == "list" {
                        let hidden = self.privatePIDs
                        return send(["windows": found.map { w in
                            var item: [String: Any] = ["id": w.id, "app": NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "",
                                                       "title": hidden.contains(w.pid) ? "" : titles[w.id] ?? UIMap.hidden,
                                                       "minimized": w.minimized, "here": self.app.docks.isOnScreen(w)]
                            if mine(w) { item["display"] = "yours" }
                            return item
                        }])
                    }
                    // Found by its id, or by words of its title as the list told it (never its own title's hidden
                    // words, nor a private app's title, which the list leaves empty).
                    let hidden = self.privatePIDs
                    let window = found.first { $0.id == wanted }
                        ?? found.first { !wanted.isEmpty && !hidden.contains($0.pid) && (titles[$0.id] ?? "").localizedCaseInsensitiveContains(wanted) }
                        ?? (wanted.isEmpty ? found.first { !$0.minimized } : nil)
                    guard let window else { return fail("No such window; list them first.") }
                    // Nothing on a run's own display comes forward: the person can't see it there.
                    if action == "focus", mine(window) {
                        return fail("That window is on your own display, where nothing comes forward. Work in it with petal_ui and petal_act; action: show brings your windows to the person's screen (behind what they're doing) when they need to see one.")
                    }
                    let appName = NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? "the window"
                    // A private app's window is called by its app's name only, in replies and the history.
                    let title = titles[window.id] ?? UIMap.hidden
                    let label = title.isEmpty || self.privatePIDs.contains(window.pid) ? appName : title
                    switch action {
                    case "focus": Windows.focus(window, onScreen: self.app.docks.isOnScreen(window)); send(["focused": label])
                    case "minimize":
                        // Accessibility waits on the app (a hung one for its timeout): never on the main thread.
                        let element = window.element
                        Self.off(live, { AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }) { ran in
                            if ran { send(["minimized": label]) }
                        }
                    case "close":
                        let close = {
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
                                self.did("Closed \(quoted: label, else: "a window")")
                                send(["closed": label])
                            }
                        }
                        // Its own window on its own display, which the person never saw: closed without asking them
                        // (its app still asks to save anything unsaved, there, where the run can answer).
                        if self.app.displays.owns(window: window.number, for: caller) { return close() }
                        self.ask("close", "Close “\(label)”", wants: "close “\(label)”", detail: "Its app asks to save anything unsaved.", owner: caller) { allowed in
                            guard allowed, live() else { return send(["declined": self.declined("The person didn't allow closing it.")]) }
                            close()
                        }
                    case "arrange":
                        let layout = args["layout"] as? String ?? "full"
                        guard let frame = self.arranged(window, layout) else { return fail("layout is left, right, top, bottom, full or center") }
                        Self.queue.async {
                            guard live() else { return }   // its asker gone while it waited its turn
                            _ = Windows.place(window.element, pid: window.pid, frame, live: live)
                            DispatchQueue.main.async { send(["arranged": label, "layout": layout]) }
                        }
                    default: fail("action is list, focus, minimize, close, arrange or show")
                    }
                }
            }
        }
    }

    /// Where a window goes for a layout: its screen's room, less the dock.
    private func arranged(_ window: AppWindow, _ layout: String) -> CGRect? {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let screens = Windows.screens()
        let a: CGRect
        if let own = Screens.runFrames.first(where: { $0.frame.contains(center) }) {
            // On a run's own display it's arranged there: never pulled onto the person's screen.
            a = own.frame.insetBy(dx: 12, dy: 12)
        } else {
            guard let screen = screens.first(where: { $0.frame.contains(center) }) ?? screens.first else { return nil }
            a = Windows.usableArea(frame: screen.frame, visible: screen.visible, respectClear: true)
        }
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
        let moving = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
        ask("trash", "Move \(moving) to the Trash", wants: "move \(moving) to the Trash",
            detail: urls.count == 1 ? "You can put it back." : names, owner: caller) { allowed in
            guard allowed, live() else { return send(["declined": self.declined("The person didn't allow it.")]) }
            NSWorkspace.shared.recycle(urls) { moved, error in
                MainActor.assumeIsolated {
                    self.trashed = moved.map { (from: $0.key, to: $0.value) }
                    if let error, moved.isEmpty { return fail(error.localizedDescription) }
                    self.did(moved.count == 1 ? "Moved \(quoted: moved.keys.first?.lastPathComponent ?? "", else: "a file") to the Trash" : "Moved \(moved.count) items to the Trash",
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
            return Memory(id: id, text: text, learned: item["by"] as? String == "petal",
                          at: Date(timeIntervalSince1970: item["at"] as? Double ?? 0))
        }
    }

    private func record(_ memory: Memory) -> [String: Any] {
        ["id": memory.id, "text": memory.text, "by": memory.learned ? "petal" : "you", "at": memory.at.timeIntervalSince1970]
    }

    private func saveMemories() {
        Config.writeObject(["memories": memories.map(record)], to: memoryFile)
    }

    @discardableResult
    func remember(_ text: String, learned: Bool) -> Memory {
        if let same = memories.first(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) { return same }
        let memory = Memory(id: String(UUID().uuidString.prefix(8)).lowercased(), text: text, learned: learned, at: Date())
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

    /// What the chat is told it remembers.
    func memoryBrief() -> String {
        guard config.bool("aiMemory") else { return "" }
        return memories.map { "- \($0.text) [\($0.id)]" }.joined(separator: "\n")
    }
}

/// What `Assist.openOnDisplay` found, handed from the thread that opened it to the main one.
final class OpenedOnDisplay: @unchecked Sendable {
    var app = ""
    var bundle = ""
    var appURL: URL?
    var opened = RunDisplays.Opened()
}
