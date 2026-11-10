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
/// app for the rest of the reply, Always for good, unless the chat has Full access. An AI session outside Petal has
/// no replies Petal can see: its Allow lasts one task (the same `task`, with no more than two minutes between acts).
/// Never apps kept private (`aiNeverLook`), never password fields, never a vault secret: the vault fills its own (VaultFill.swift).
///
/// A sticky note acting on its own window works in the background (Background.swift, BackgroundActing.swift): no
/// pointer, nothing brought forward, the person's keyboard untouched; what can't be done that way it hands back to the
/// person ("needs the window in front"). Only when the person has that very window in front does it use its pointer,
/// and never while they're typing or clicking in it.
///
/// Each chat is its own caller (its note's id, or `mcp-<pid>` for the Petal tools of an AI session outside Petal):
/// callers never share a window's ids or what the person allowed. An act only goes ahead on the window `petal_ui`
/// looked at, as it was then (UIMap.Fingerprint), checked before the cursor sets off and again right before the
/// change; and every change it makes checks first that its turn wasn't stopped, steered or ended, and that using
/// apps is still on and the app not private (Config's changes stop its `cancel`). Maps and turns nobody uses go
/// within a minute.
@MainActor
final class ComputerUse {
    struct Entry {
        let element: AXUIElement
        let node: UINode
        /// What it said and, for a switch, whether it was on, as read (before any redaction): read again right
        /// before acting, so a Mute that became Unmute isn't pressed.
        let meaning: UIMap.Meaning
    }

    /// One window's controls, as the last `petal_ui` saw them, and what the window showed then.
    struct Map {
        let id = UUID()
        let pid: pid_t
        let bundle: String
        let appName: String
        let window: AXUIElement
        let windowID: CGWindowID?
        let windowFrame: CGRect
        /// Its tables and lists: which of their rows are selected is part of the fingerprint.
        let lists: [AXUIElement]
        /// Refreshed after its own typing, focusing or scrolling, which aren't changes behind its back.
        var fingerprint: UIMap.Fingerprint
        let entries: [String: Entry]
        let count: Int
        let made: Date
        /// A note stuck to one tab: where, with the tab as seen showing when it was read. Every act checks that tab
        /// is still the one its window shows, never acting on another.
        var tabPlace: NotePlace? = nil
        /// Its chat's `places` count when it was read: a note stuck somewhere else since can't use it.
        var place = 0
        /// Read for a sticky note's own window (or tab), not `front: true` or another app: its acts go in the background.
        /// Also a window on the run's own hidden display (`hidden`).
        var ownPlace = false
        /// The window is on the caller's own hidden display (RunDisplay.swift): its acts always go the background
        /// way, with no pointer, whatever is in front.
        var hidden = false
    }

    /// One chat's reply (its turn; one task of an AI session outside Petal): the apps it may use, whether the person
    /// stopped it, and its `cancel`, which every action of the turn checks right before it changes anything.
    struct Session {
        var turn: String
        var task = ""
        var apps: Set<String> = []
        var stopped = false
        var last = Date()
        /// For a note's helper, bound to its run (`Acting.Cancel(run:)`): stopped whenever that run isn't running.
        let cancel: Acting.Cancel

        init(turn: String, run: RunToken? = nil) {
            self.turn = turn
            cancel = Acting.Cancel(run: run)
        }
        /// The Buy cards the person answered Buy in this reply: each lets payment info fill on its exact host, in its
        /// window, with its card (Vault.Checkout).
        var checkouts: [Vault.Checkout] = []
        /// It acted (or will act) with the pointer, where the person sees it: Escape and the small Stop stand for it.
        /// A note working only in the background leaves the person's Escape alone; its Stop is on the note and in
        /// the AI button's preview.
        var shown = false
    }

    /// One action, waiting its turn: the cursor does one thing at a time.
    struct Job {
        let caller: String
        let action: String
        let entry: Entry?
        let map: Map
        let bundle: String
        let caption: String
        let options: Acting.Options
        /// This action's own, under its turn's: stopping either stops it.
        let cancel: Acting.Cancel
        let send: (Any) -> Void
        let fail: (String) -> Void
        /// Done in the background, with no pointer.
        var quiet = false
        /// It waited for the person to leave its app (they were using it, and it needs real keys there) from then:
        /// taken up again, its patience still counts from there.
        var waitedFrom: Date?
        var appName: String { map.appName }
    }

    nonisolated static let stoppedText = "The person stopped it."
    /// How long an AI session outside Petal keeps what the person allowed after its last act.
    static let outsideGrant: TimeInterval = 120
    static let oldTools = "This AI session's Petal tools are from an older Petal: start a new chat or session to use apps."

    /// A reply that was stopped or ended (Stop, Escape, steering, another chat picked, using apps turned off): it
    /// never acts again. A Petal chat's turn stays closed until its next turn starts; an outside session's task
    /// until it has been quiet for `outsideGrant`.
    struct Closed {
        var turn: String
        var task = ""
        var at = Date()
    }

    /// By caller. Never shared between two chats.
    private(set) var maps: [String: Map] = [:]
    /// By caller: how many times its note was stuck to something else (`placeChanged`). A map, or a petal_ui under
    /// way, from before the last is no use.
    private var places: [String: Int] = [:]
    nonisolated static let moved = "This note was stuck somewhere else (its tab, its window or all of its app) since that petal_ui. Call petal_ui again for fresh ids."
    private var sessions: [String: Session] = [:] {
        didSet {
            // A Buy gone from every reply (its window moved on or closed, replaced, its reply over) is revoked at once.
            Vault.Checkout.revoke(oldValue.values.flatMap(\.checkouts), keeping: sessions.values.flatMap(\.checkouts))
            standGuard()
            unwatchBuys()
        }
    }
    private var closed: [String: Closed] = [:]
    private var line: [Job] = [] { didSet { standGuard() } }
    private var busy = false { didSet { standGuard() } }
    private var acting: Job?
    /// Chats whose copy-like press is still being watched (CopyWatch): their next action waits, nobody else's.
    private var watching: Set<String> = []
    /// Whose actions the cursor showing is for: Stop stops that reply, even between its actions.
    private var lastCaller: String?
    /// Lets maps and turns nobody uses go (an AI session that quit never says so), while there are any.
    private var sweeper: Timer?
    let cursor = FakeCursor()
    /// Reading windows and acting have a queue each, so a long read never holds an action (or its Stop) back.
    nonisolated static let readQueue = DispatchQueue(label: "petal.computer.read", qos: .userInitiated)
    nonisolated static let actQueue = DispatchQueue(label: "petal.computer.act", qos: .userInitiated)

    var app: PetalApp { PetalApp.shared }
    var assist: Assist { app.assist }

    init() {
        cursor.onStop = { [weak self] in self?.stop() }
    }

    /// `caller`: the chat asking (`Petal --mcp` always sends one). `gone`: for a call from outside Petal, its
    /// socket's own hung-up flag, read on whichever thread does the work: an act's `cancel` is stopped by it the moment
    /// the client goes, before the main thread hears (`Assist.hungUp`). Petal's own chats have none.
    func handle(_ name: String, _ args: [String: Any], note caller: String?, gone: (@Sendable () -> Bool)? = nil,
                send: @escaping (Any) -> Void, fail: @escaping (String) -> Void) {
        sweep()
        if let refusal = refusal() { return fail(refusal) }
        guard let caller, !caller.isEmpty else { return fail(Self.oldTools) }
        // A note's helper whose note moved to a place that isn't in front: its default look and act wait for it,
        // never taken from what was there before (or what's in front now).
        if (args["app"] as? String ?? "").trimmingCharacters(in: .whitespaces).isEmpty, args["front"] as? Bool != true,
           let waiting = app.claude.helperWaiting(caller) { return fail(waiting) }
        if name == "petal_ui" { look(args, caller: caller, gone: gone, send, fail) } else { act(args, caller: caller, gone: gone, send, fail) }
    }

    /// Why Petal can't use apps now (turned off, or no Accessibility), or nil.
    func refusal() -> String? {
        guard app.config.bool("computerUse") else { return "Using apps is off in Petal's settings (computerUse); only the person can turn it on." }
        guard Windows.trusted else { return "Petal needs Accessibility for this (Petal's settings, Permissions)." }
        return nil
    }

    /// The same, for one app: asked again right before every action and before a petal_ui answer goes back, since the
    /// person may have changed their mind meanwhile.
    func refusal(for bundle: String, name: String) -> String? {
        if let refusal = refusal() { return refusal }
        if assist.neverLook(bundle) { return "The user keeps \(name) private: Petal doesn't look into it or use it." }
        return nil
    }

    // MARK: Seeing a window's controls

    private func look(_ args: [String: Any], caller: String, gone: (@Sendable () -> Bool)?, _ send: @escaping (Any) -> Void,
                      _ fail: @escaping (String) -> Void) {
        let named = (args["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        // A sticky note's own window, as petal_look does, unless an app or what's in front is asked for.
        let wantsFront = args["front"] as? Bool == true
        let wantsDisplay = args["display"] as? Bool == true
        // The run's own window on its hidden display: asked for (display: true: the one it opened last, or of the app
        // named), or the app named has one there. Never with front: true, which is what the person has in front.
        let own = wantsFront ? nil : app.displays.window(for: caller, app: named, newest: wantsDisplay)
        if wantsDisplay, own == nil {
            return fail(app.displays.display(for: caller) == nil
                ? "You have no display of your own now. petal_apps open (on: \"display\") puts a window on one."
                : "None of your windows\(named.isEmpty ? "" : " of \(named)") is on your display. petal_apps open puts one there.")
        }
        let place = own == nil && named.isEmpty && !wantsFront ? app.claude.placed(caller) : nil
        let target: NSRunningApplication?
        if let own {
            target = NSRunningApplication(processIdentifier: own.pid)
        } else if let place {
            target = place.running
            guard target != nil else {
                return fail(place.kind == .app ? "This note is stuck to \(place.appName), which isn't open. front: true uses what's in front now."
                                               : "This note's window is closed: \(place.appName) has quit. front: true uses what's in front now.")
            }
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
        // A note asked where its app showed no window has none to read: never a window its app shows later.
        var wanted: CGWindowID?
        switch place?.target ?? .focused {
        case .nothing: return fail(ClaudePanel.noWindow(name))
        case .window(let number): wanted = number
        case .focused: wanted = nil
        }
        if let own { wanted = own.window }
        let find = args["find"] as? String ?? ""
        // A note stuck to one tab reads its window only while that tab is the one showing, checked before and after.
        let tabPlace = place.flatMap { $0.kind == .tab && $0.tab != nil ? $0 : nil }
        let stuck = places[caller, default: 0]
        Self.readQueue.async {
            // Its caller went while this waited its turn: nothing is read for nobody.
            if gone?() == true { return }
            if let tabPlace, ClaudePanel.tabShowing(tabPlace) == nil {
                return DispatchQueue.main.async { MainActor.assumeIsolated { self.waitsFor(caller, .tab) }; fail(ClaudePanel.tabNotShowing) }
            }
            // Read again if the vault (or a secret Petal typed) changed meanwhile: nothing goes out unchecked against it.
            let settled = VaultIndex.settled { _ in Reader.read(pid: pid, window: wanted, budget: 1.5) }
            let seen = tabPlace.flatMap { ClaudePanel.tabShowing($0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Turned off, or the app made private, while it read: nothing it read goes back.
                    if let refusal = self.refusal(for: bundle, name: name) { return fail(refusal) }
                    // The note was stuck somewhere else while it read: what it read was for the old place.
                    if self.places[caller, default: 0] != stuck { return fail(Self.moved) }
                    guard let reading = settled, !reading.vaultUnreadable else {
                        return fail(VaultStore.unreadableText + " Petal can't hide its secrets, so it doesn't read windows until it can: try again in a moment.")
                    }
                    if reading.gone {
                        return fail(own != nil ? "That window of yours is closed (it was in \(name))."
                                               : "This note's window is closed (it was in \(name)). front: true uses what's in front now.")
                    }
                    guard let window = reading.window else { return fail("\(name) has no window open.") }
                    // Another run's display is none of this one's: nothing read there goes back.
                    if self.app.displays.foreign(reading.windowFrame, to: caller) || self.app.displays.foreign(window: reading.windowID, to: caller) {
                        return fail("\(name)'s window there belongs to another helper's work, on a display of its own: Petal keeps them apart, and you never see or use its windows. For a window of your own in \(name), open a file or an address in it with petal_apps (it waits its turn for \(name) and says so).")
                    }
                    // On the caller's own display: worked on in the background, always.
                    let hidden = self.app.displays.holds(reading.windowFrame, for: caller)
                    // Another tab came forward while it read (or Petal can't tell any more): nothing it read goes back.
                    var stuckTab: NotePlace?
                    if let tabPlace {
                        guard let seen, seen.window == reading.windowID else { self.waitsFor(caller, .tab); return fail(ClaudePanel.tabNotShowing) }
                        self.app.claude.tabSeen(note: caller, was: tabPlace, tab: seen.tab, window: seen.window)
                        var now = tabPlace
                        if let tab = now.tab { now.tab = NoteRules.follow(tab, to: seen.tab, keepWords: true) }
                        now.window = seen.window
                        stuckTab = now
                    }
                    let picked = UIMap.select(reading.nodes, window: reading.windowFrame, find: find)
                    var entries: [String: Entry] = [:]
                    var list: [[String: Any]] = []
                    for (index, node) in picked.shown.enumerated() {
                        let id = "e\(index + 1)"
                        guard let element = reading.elements[node.order], let meaning = reading.meanings[node.order] else { continue }
                        entries[id] = Entry(element: element, node: node, meaning: meaning)
                        var item: [String: Any] = ["id": id, "role": UIMap.kind(node), "name": UIMap.name(node),
                                                   "frame": [node.frame.minX, node.frame.minY, node.frame.width, node.frame.height].map { Int($0.rounded()) }]
                        if let value = UIMap.value(node) { item["value"] = value }
                        if !node.enabled { item["disabled"] = true }
                        if node.focused { item["focused"] = true }
                        if !UIMap.isVisible(node, window: reading.windowFrame) { item["offscreen"] = true }
                        list.append(item)
                    }
                    let made = Map(pid: pid, bundle: bundle, appName: name, window: window, windowID: reading.windowID,
                                   windowFrame: reading.windowFrame, lists: reading.lists, fingerprint: reading.fingerprint,
                                   entries: entries, count: entries.count, made: Date(), tabPlace: stuckTab, place: stuck,
                                   ownPlace: place != nil || hidden, hidden: hidden)
                    self.maps[caller] = made
                    self.keepSweeping()
                    // Its tab shows again: the note no longer waits for that.
                    if place != nil, self.agent(caller)?.needs == Background.Reason.tab.status { self.waitsFor(caller, nil) }
                    var result: [String: Any] = ["app": name, "window": reading.title, "elements": list,
                                                 "note": "Act with petal_act by id. These ids last until the next petal_ui, or 5 minutes; call petal_ui again once the window changes."]
                    if hidden { result["display"] = "This window is on your own display: the person doesn't see it, and petal_act works in it without a pointer and without bringing anything forward." }
                    if picked.left > 0 { result["more"] = "\(picked.left) more not listed: pass find (a word in its name) to narrow." }
                    if reading.timedOut { result["partial"] = "The window is big: this is what Petal read in time." }
                    if list.isEmpty { result["empty"] = "No controls found\(find.isEmpty ? "" : " matching “\(find)”"). The app may not support Accessibility well; petal_look with a screenshot shows it." }
                    // A Buy said in this window (by any chat) ends if what was just read is another tab or page,
                    // before the AI hears what it read.
                    guard let id = reading.windowID, self.hasBuy(in: id) else { return send(result) }
                    self.assist.vaultShown(made, pages: reading.pages, title: reading.title) { pages in
                        self.seen(pages, window: id)
                        // Stuck somewhere else, turned off or made private meanwhile: these ids are no use.
                        if let refusal = self.refusal(for: bundle, name: name) { return fail(refusal) }
                        if self.places[caller, default: 0] != stuck { return fail(Self.moved) }
                        send(result)
                    }
                }
            }
        }
    }

    // MARK: Acting

    private func act(_ args: [String: Any], caller: String, gone: (@Sendable () -> Bool)?, _ send: @escaping (Any) -> Void,
                     _ fail: @escaping (String) -> Void) {
        let task = UIMap.tidy(args["task"] as? String ?? "").lowercased()
        let session = session(caller, task: task)
        sessions[caller]?.last = Date()
        keepSweeping()
        guard !session.stopped else { return fail(Self.stoppedText + " Don't carry on using apps in this reply: say what's left and wait for them.") }
        let action = (args["action"] as? String ?? "").lowercased()
        let byElement: Set<String> = ["press", "type", "focus", "scroll"]
        guard byElement.contains(action) || action == "menu" || action == "key" else {
            return fail("action is press, type, focus, scroll, menu or key.")
        }
        let id = (args["id"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if let map = maps[caller], Date().timeIntervalSince(map.made) > UIMap.lifetime { maps[caller] = nil }
        // Every action, menus and keys too, goes to the window the last petal_ui looked at: never another one.
        if let map = maps[caller], map.place != places[caller, default: 0] { maps[caller] = nil; return fail(Self.moved) }
        guard let map = maps[caller] else {
            return fail(byElement.contains(action) || !id.isEmpty
                ? "Call petal_ui first: ids come from it, and last until the next petal_ui or 5 minutes."
                : "Call petal_ui first (with app for another app): Petal only uses a window it has looked at.")
        }
        var entry: Entry?
        if byElement.contains(action) {
            guard !id.isEmpty else { return fail("Give the id of a control from petal_ui (like e12).") }
            guard let found = map.entries[id] else { return fail("There's no \(id) in the last petal_ui (it listed e1 to e\(map.count)). Call petal_ui again if the window changed.") }
            entry = found
        } else if !id.isEmpty {
            guard let found = map.entries[id] else { return fail("There's no \(id) in the last petal_ui. Call petal_ui again.") }
            entry = found
        }
        let named = (args["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if !named.isEmpty, named.caseInsensitiveCompare(map.appName) != .orderedSame, named.caseInsensitiveCompare(map.bundle) != .orderedSame {
            return fail("The last petal_ui looked at \(map.appName). Call petal_ui with app: \(named) first: Petal only uses a window it has looked at.")
        }
        guard let target = NSRunningApplication(processIdentifier: map.pid), !target.isTerminated else { return fail("\(map.appName) isn't open.") }
        let name = map.appName
        let bundle = target.bundleIdentifier ?? "\(target.processIdentifier)"
        if let refusal = refusal(for: bundle, name: name) { return fail(refusal) }

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
                return fail("That's a password field: petal_act never types there. petal_vault fills a saved password (action: fill), or asks the person for one (action: request).")
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

        let job = Job(caller: caller, action: action, entry: entry, map: map, bundle: bundle, caption: caption, options: options,
                      cancel: Acting.Cancel(under: session.cancel, also: gone), send: send, fail: fail)
        // A Buy said in this window lasts only while it shows the tab and page it was said on: looked at before
        // every act there (an act may be what leaves it, or the person may have).
        guard let window = map.windowID, hasBuy(in: window) else { return proceed(job) }
        assist.vaultTab(map) { [weak self] pages in
            guard let self else { return }
            self.seen(pages, window: window)
            self.proceed(job)
        }
    }

    /// A job the reply may do now, or the first in an app it hasn't used yet (asked first).
    private func proceed(_ job: Job) {
        guard let session = sessions[job.caller], !session.stopped, !job.cancel.stopped else { return job.fail(whyStopped(job)) }
        // Another run's window is never acted in, whatever a map says.
        if app.displays.foreign(window: job.map.windowID, to: job.caller) { return job.fail(Self.anothers(job.appName)) }
        // Two runs, one app: while another run uses this app on its display, this one waits its turn ("Waiting for
        // TextEdit"), and hears when the other ends or lets it go. With no run on a display, it goes ahead at once.
        app.displays.turn(job.caller, app: job.bundle, name: job.appName, hold: false) { [weak self] refused in
            guard let self else { return }
            if let refused { return job.fail(refused.words) }
            // Stopped, or its turn ended, while it waited.
            guard let session = self.sessions[job.caller], !session.stopped, !job.cancel.stopped else { return job.fail(self.whyStopped(job)) }
            if session.apps.contains(job.bundle) { return self.enqueue(job) }
            self.admit(job, session: session)
        }
    }

    static func anothers(_ app: String) -> String {
        "That window of \(app) belongs to another helper's work, on a display of its own: Petal keeps them apart. Nothing was done. Call petal_ui again."
    }

    /// The reply a vault call belongs to, taken as the call comes in (nil when that reply can't act): every later
    /// step of the call checks it's still that reply (`live`), so a card answered or a save finished after the person
    /// stopped or steered it never acts in the next reply. `gone`: a call from outside Petal's socket flag: the
    /// call's own token, under the reply's, stops the moment its client goes, on every thread that reads it.
    func token(_ caller: String, task: String, gone: (@Sendable () -> Bool)? = nil) -> Acting.Cancel? {
        let current = session(caller, task: UIMap.tidy(task).lowercased())
        sessions[caller]?.last = Date()
        keepSweeping()
        guard !current.stopped, !current.cancel.stopped else { return nil }
        guard let gone else { return current.cancel }
        let own = Acting.Cancel(under: current.cancel, also: gone)
        return own.stopped ? nil : own
    }

    /// The reply `token` came from is still the caller's, and wasn't stopped.
    func live(_ caller: String, _ token: Acting.Cancel) -> Bool {
        guard let current = sessions[caller] else { return false }
        return token.isUnder(current.cancel) && !current.stopped && !token.stopped
    }

    /// A field filled from the vault (VaultFill.swift): the same line, pointer, Stop and checks as petal_act, on a
    /// control of the window petal_ui looked at, in the reply `token` came from. `allowed`: the person just said yes
    /// to this very fill on its card, which lets it into the app for that fill alone (typing only: Return after it
    /// asks as petal_act does); otherwise the app is asked about as petal_act asks.
    /// `agent`: an agent outside Petal's pass for this operation and what it's checked for (the item, or new logins),
    /// checked again here, and stopping the fill if its grant is removed while it waits on a card or fills.
    func fill(_ plan: VaultFillPlan, entry: Entry, map: Map, caller: String, token: Acting.Cancel, allowed: Bool,
              agent: (pass: AgentPass, item: String)? = nil, send: @escaping (Any) -> Void, fail: @escaping (String) -> Void) {
        sessions[caller]?.last = Date()
        keepSweeping()
        guard live(caller, token), let session = sessions[caller] else {
            return fail(Self.stoppedText + " Don't carry on in this reply: say what's left and wait for them.")
        }
        if let agent, !AgentGrants.shared.still(agent.pass, item: agent.item) { return fail(AgentPass.revokedText) }
        guard maps[caller]?.id == map.id else { return fail("The window was looked at again (or 5 minutes passed) since these ids. " + Acting.changed) }
        guard let target = NSRunningApplication(processIdentifier: map.pid), !target.isTerminated else { return fail("\(map.appName) isn't open.") }
        let bundle = target.bundleIdentifier ?? "\(target.processIdentifier)"
        if let refusal = refusal(for: bundle, name: map.appName) { return fail(refusal) }
        var options = Acting.Options()
        options.fill = plan
        options.submit = plan.submit
        // Payment info fills only under the Buy that covers this page now, and stops the moment that Buy ends.
        var buy: Vault.BuyToken?
        if plan.payment {
            guard let covering = checkout(caller, token: token, place: plan.place, window: map.windowID, card: plan.itemID, revision: plan.revision) else {
                return fail(Acting.buyEndedText)
            }
            buy = covering
        }
        let job = Job(caller: caller, action: "fill", entry: entry, map: map, bundle: bundle, caption: "Filling your \(plan.field.words)",
                      options: options, cancel: Acting.Cancel(under: token, buy: buy, pass: agent?.pass), send: send, fail: fail)
        // Return after the fill presses as petal_act does: it asks to use the app, whatever card allowed the fill.
        if Vault.fillAdmitted(allowed: allowed, submit: plan.submit, appAllowed: session.apps.contains(bundle)) { return enqueue(job) }
        admit(job, session: session)
    }

    /// The Buy said in this reply that covers payment info at `place` (its exact host and page, this window and tab,
    /// this card), or nil. A window seen showing another page or tab ends that Buy.
    func checkout(_ caller: String, token: Acting.Cancel, place: Vault.Place, window: CGWindowID?, card: String, revision: Int?) -> Vault.BuyToken? {
        guard live(caller, token), let current = sessions[caller] else { return nil }
        if let window { seen([place], window: window) }
        let turn = Self.turnName(current)
        return sessions[caller]?.checkouts.first { $0.covers(place, window: window, card: card, revision: revision, turn: turn) }?.token
    }

    /// The person said Buy on `place`'s host: payment info from `card` fills there, in that window, for the rest of
    /// this reply. It doesn't let Petal AI use the browser otherwise: pressing the order button asks as any act does
    /// (unless the reply may use the browser already). False when the reply ended while they were asked.
    /// `asked`: the Buy card's number (endBuys); a newer card asked in that window since means no Buy. `revision`: the
    /// card as shown on the Buy card (`Vault.revision`); only that version of it fills.
    /// `map`: the window petal_ui read, watched while the Buy lasts; nil for a page of the run's own browser, which
    /// says itself when it moves on (RunBrowser.onLeft).
    func allowCheckout(_ caller: String, token: Acting.Cancel, place: Vault.Place, window: CGWindowID, watching map: Map?, card: String, revision: Int, asked: Int) -> Bool {
        guard live(caller, token), let current = sessions[caller], buyCards[window] == asked,
              let bought = Vault.Checkout(place: place, window: window, card: card, revision: revision, turn: Self.turnName(current)) else { return false }
        sessions[caller]?.checkouts.removeAll { $0.window == window }
        sessions[caller]?.checkouts.append(bought)
        if let map { watchBuy(map) }
        return true
    }

    /// The reply `token` came from may use `app` already (the person said so on its card, this reply): for what a
    /// reply uses another way than a window petal_ui read (a browser of its own, RunBrowserTool.swift).
    func allowed(_ caller: String, token: Acting.Cancel, app: String) -> Bool {
        live(caller, token) && sessions[caller]?.apps.contains(app) == true
    }

    /// The person just let the reply use `app`. False when the reply ended while they were asked.
    func allow(_ caller: String, token: Acting.Cancel, app: String) -> Bool {
        guard live(caller, token) else { return false }
        sessions[caller]?.apps.insert(app)
        return true
    }

    /// The newest Buy card asked in each window: Buy on an older card that's still open counts for nothing.
    private var buyCards: [CGWindowID: Int] = [:]

    /// A Buy card is about to show for `window`: every chat's Buy in it ends now (and is revoked, stopping what
    /// fills under it), whatever the person answers. The card's number, for `allowCheckout`.
    func endBuys(in window: CGWindowID) -> Int {
        for caller in Array(sessions.keys) {
            guard let list = sessions[caller]?.checkouts else { continue }
            let left = Vault.Checkout.asking(list, window: window)
            if left.count != list.count { sessions[caller]?.checkouts = left }
        }
        let card = (buyCards[window] ?? 0) + 1
        buyCards[window] = card
        return card
    }

    /// Some chat's Buy is in this window.
    func hasBuy(in window: CGWindowID) -> Bool {
        sessions.values.contains { $0.checkouts.contains { $0.window == window } }
    }

    /// `window` was seen showing `pages` (by a read or an act of any chat, or after its title changed): every Buy in
    /// it whose own tab and page isn't one of them is over, for good.
    func seen(_ pages: [Vault.Place], window: CGWindowID) {
        for caller in Array(sessions.keys) {
            guard let list = sessions[caller]?.checkouts, list.contains(where: { $0.window == window }) else { continue }
            let left = Vault.Checkout.seen(list, pages: pages, window: window)
            if left.count != list.count { sessions[caller]?.checkouts = left }
        }
    }

    // MARK: Watching a Buy's window

    /// Each window with a Buy in it, as looked at when Buy was said: its title is watched (a tab switch or a new page
    /// changes it), and so is its browser's tab selection (two tabs titled alike change no title), and what it shows
    /// is read again then.
    private var buyWindows: [CGWindowID: Map] = [:]
    /// Browsers whose Buy windows are being read again after a tab switch (`true`: switched again meanwhile, so read
    /// once more when this read is done).
    private var buyTabReads: [pid_t: Bool] = [:]

    private func watchBuy(_ map: Map) {
        guard let id = map.windowID, buyWindows[id] == nil else { return }
        if buyWindows.isEmpty {
            WindowEvents.shared.listen("buy") { [weak self] event in self?.buyEvent(event) }
            // Tab switches are passed on only while someone wants them, notes on or off.
            WindowEvents.shared.titles("buy", true)
        }
        buyWindows[id] = map
        AXWatcher.shared.watchTitle(map.window, pid: map.pid)
    }

    /// Stops watching windows no Buy is in anymore (sessions changed).
    private func unwatchBuys() {
        guard !buyWindows.isEmpty else { return }
        let windows = Set(sessions.values.flatMap { $0.checkouts.map(\.window) })
        for (id, map) in buyWindows where !windows.contains(id) {
            AXWatcher.shared.unwatchTitle(map.window, pid: map.pid)
            buyWindows[id] = nil
        }
        if buyWindows.isEmpty {
            WindowEvents.shared.stopListening("buy")
            buyTabReads = [:]
        }
    }

    private func buyEvent(_ event: WindowEvents.Event) {
        if event.kind == .tabSwitched { return buyTabSwitched(event.pid) }
        guard let id = event.window, let map = buyWindows[id] else { return }
        switch event.kind {
        case .closed:
            for caller in Array(sessions.keys) { sessions[caller]?.checkouts.removeAll { $0.window == id } }
            buyCards[id] = nil   // a card still open for it counts for nothing
        case .titleChanged:
            assist.vaultTab(map) { [weak self] pages in self?.seen(pages, window: id) }
        default:
            break
        }
    }

    /// A browser with a Buy in one of its windows selected another tab, or the keyboard moved within its page (the
    /// event doesn't say which window, nor tell the two apart): each of its Buy windows is read again, and a Buy ends
    /// only if the window now shows another tab or page (`seen`), never for the event itself.
    private func buyTabSwitched(_ pid: pid_t) {
        guard buyWindows.values.contains(where: { $0.pid == pid }) else { return }
        if buyTabReads[pid] != nil { buyTabReads[pid] = true; return }
        buyTabReads[pid] = false
        let maps = buyWindows.filter { $0.value.pid == pid }
        var left = maps.count
        for (id, map) in maps {
            assist.vaultTab(map) { [weak self] pages in
                guard let self else { return }
                self.seen(pages, window: id)
                left -= 1
                guard left == 0 else { return }
                let again = self.buyTabReads.removeValue(forKey: pid) == true
                if again { self.buyTabSwitched(pid) }
            }
        }
    }

    /// A reply's name for its Buys: its turn (and an outside session's task).
    private static func turnName(_ session: Session) -> String { "\(session.turn)|\(session.task)" }

    /// The first act on an app in a reply asks the person; Allow lets the reply use it.
    private func admit(_ job: Job, session: Session) {
        let caller = job.caller, name = job.appName, bundle = job.bundle, caption = job.caption
        let send = job.send, fail = job.fail
        let first = caption.prefix(1).lowercased() + caption.dropFirst()
        let lasting = session.turn == Self.outside ? "For this task" : "Until this reply is done"
        // A note on its own window works there in the background: said so, since nothing will show it working.
        let detail = job.map.hidden
            ? "First, \(first). \(lasting) it can press and type in a \(name) window on a display of its own, out of your way: nothing comes forward, and your pointer and keyboard stay yours. Stop it from its note or the AI button."
            : job.map.ownPlace
            ? "First, \(first). \(lasting) it can press and type in this note's \(name) window in the background, while you work elsewhere: nothing comes forward, and your pointer and keyboard stay yours. Stop it from its note."
            : "First, \(first). \(lasting) it can press, type and choose menus in \(name) with its own pointer; yours stays where it is. Esc stops it."
        assist.ask("computer:\(bundle)", "Let Petal AI use \(name)?", detail: detail,
                   owner: caller) { allowed in
            // The note was stuck somewhere else while the person was asked (its card was taken away): look again.
            if job.map.place != self.places[caller, default: 0] { return fail(Self.moved) }
            // Its turn ended, the person stopped it, or turned it off, while they were asked.
            if job.cancel.stopped { return fail(self.whyStopped(job)) }
            guard allowed else {
                return send(["declined": "The person didn't let Petal AI use \(name). Don't find another way; say what you would have done."])
            }
            guard self.sessions[caller]?.cancel === session.cancel else { return fail(Self.stoppedText) }
            if let refusal = self.refusal(for: bundle, name: name) { return fail(refusal) }
            self.sessions[caller]?.apps.insert(bundle)
            self.enqueue(job)
        }
    }

    static let outside = "outside"

    /// The chat's reply this is part of: a Petal chat's turn (stopped or ended, it never acts again: only its next
    /// turn can, asking again). An AI session outside Petal has no turns Petal can see: its acts are one task while
    /// they name the same `task` and come within two minutes of each other, and a Stop ends it; that task stays
    /// stopped while it keeps trying, and another starts afresh and asks again.
    /// A new one stops whatever the last one still had going.
    private func session(_ caller: String, task: String) -> Session {
        if let agent = app.claude.note(withID: caller)?.agent {
            let turn = "\(agent.turn)"
            // Its turn was stopped or ended, or it isn't running (a late call from a run that's over).
            if closed[caller]?.turn == turn || !agent.running { return Self.over(turn) }
            if let session = sessions[caller], session.turn == turn { return session }
            return fresh(caller, turn: turn)
        }
        // A Petal chat's id with no chat behind it anymore (its note let go): nothing it asks goes ahead.
        guard caller.hasPrefix("mcp-") else { return Self.over(Self.outside) }
        if let mark = closed[caller], mark.task == task, Date().timeIntervalSince(mark.at) < Self.outsideGrant {
            closed[caller]?.at = Date()
            return Self.over(Self.outside)
        }
        if let session = sessions[caller], session.turn == Self.outside, !session.stopped, session.task == task,
           Date().timeIntervalSince(session.last) < Self.outsideGrant {
            return session
        }
        return fresh(caller, turn: Self.outside, task: task)
    }

    /// A reply that can't act: stopped from the start, kept nowhere.
    private static func over(_ turn: String) -> Session {
        var session = Session(turn: turn)
        session.stopped = true
        session.cancel.stop()
        return session
    }

    /// Marks the caller's reply as over for good: its Petal chat's turn now, or its outside task.
    private func close(_ caller: String) {
        if let agent = app.claude.note(withID: caller)?.agent {
            closed[caller] = Closed(turn: "\(agent.turn)")
        } else if let session = sessions[caller], session.turn == Self.outside {
            closed[caller] = Closed(turn: Self.outside, task: session.task)
        }
    }

    private func fresh(_ caller: String, turn: String, task: String = "") -> Session {
        if sessions[caller] != nil { cancelWork(of: caller) }
        // A note's helper: every action of the reply is bound to its run's token, checked right before it acts.
        var made = Session(turn: turn, run: app.claude.note(withID: caller)?.agent.token)
        made.task = task
        sessions[caller] = made
        return made
    }

    /// Drops what nobody can use anymore: maps past their 5 minutes, an outside session's task gone quiet, a
    /// Petal chat's turn that's over or whose note is gone. Nothing waiting or under way is touched.
    private func sweep() {
        let now = Date()
        maps = maps.filter { now.timeIntervalSince($0.value.made) <= UIMap.lifetime }
        let working = Set(line.map(\.caller)).union(acting.map { [$0.caller] } ?? []).union(watching).union(assist.pending?.owner.map { [$0] } ?? [])
        for (caller, session) in sessions where !working.contains(caller) {
            let quiet = now.timeIntervalSince(session.last)
            if let agent = app.claude.note(withID: caller)?.agent {
                if !agent.running || "\(agent.turn)" != session.turn { sessions[caller] = nil }
            } else if session.turn != Self.outside || quiet >= Self.outsideGrant {
                sessions[caller] = nil
            }
        }
        // A closed turn is let go once its chat has moved on to another turn (or is gone); an outside task once
        // it has been quiet for its two minutes.
        closed = closed.filter { caller, mark in
            if let agent = app.claude.note(withID: caller)?.agent { return "\(agent.turn)" == mark.turn }
            return mark.turn == Self.outside && now.timeIntervalSince(mark.at) < Self.outsideGrant
        }
        if maps.isEmpty && sessions.isEmpty && closed.isEmpty {
            sweeper?.invalidate()
            sweeper = nil
        }
    }

    /// Every 15 seconds: an outside session's Stop and Escape go soon after it may no longer act.
    private func keepSweeping() {
        guard sweeper == nil else { return }
        sweeper = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    /// While any reply may act (a session the person allowed an app or a Buy, not stopped, or an action waiting or
    /// under way), Escape stops it and a small Stop stays on the screen, between actions too.
    private func standGuard() {
        // Only for what acts where the person sees it: a note working in the background never takes their Escape.
        let seen = { (job: Job) in !job.map.ownPlace || self.sessions[job.caller]?.shown == true }
        let live = (busy && acting?.quiet != true) || line.contains(where: seen)
            || sessions.values.contains { Self.mayAct($0) && $0.shown }
        cursor.stand(live)
    }

    /// A reply the person let use an app, or fill payment info after Buy, and that wasn't stopped.
    private static func mayAct(_ session: Session) -> Bool {
        !session.stopped && !session.cancel.stopped && (!session.apps.isEmpty || !session.checkouts.isEmpty)
    }

    private func enqueue(_ job: Job) {
        if !job.map.ownPlace { sessions[job.caller]?.shown = true }
        line.append(job)
        next()
    }

    private func next() {
        guard !busy, let index = line.firstIndex(where: { !watching.contains($0.caller) }) else { return }
        let job = line.remove(at: index)
        if job.cancel.stopped { job.fail(whyStopped(job)); return next() }
        var current = job
        current.quiet = job.map.ownPlace
        acting = current
        busy = true
        run(job)
    }

    private func finished() {
        busy = false
        acting = nil
        next()
    }

    /// Why a job can't go ahead now, or nil: its turn is over or stopped, using apps was turned off or its app made
    /// private, or a newer petal_ui (or 5 minutes) replaced the map its ids came from.
    private func stale(_ job: Job) -> String? {
        if job.cancel.stopped || sessions[job.caller]?.stopped == true { return whyStopped(job) }
        if let refusal = refusal(for: job.bundle, name: job.appName) { return refusal }
        if job.map.place != places[job.caller, default: 0] { return Self.moved }
        if app.displays.foreign(window: job.map.windowID, to: job.caller) { return Self.anothers(job.appName) }
        guard let map = maps[job.caller], map.id == job.map.id, Date().timeIntervalSince(map.made) <= UIMap.lifetime else {
            return "The window was looked at again (or 5 minutes passed) since these ids. " + Acting.changed
        }
        return nil
    }

    /// What a stopped job tells the chat: turned off or made private, or its note stuck somewhere else, said so; else
    /// the person stopped it.
    private func whyStopped(_ job: Job) -> String {
        if let refusal = refusal(for: job.bundle, name: job.appName) { return refusal }
        if job.map.place != places[job.caller, default: 0] { return Self.moved }
        return job.cancel.buyEnded ? Acting.buyEndedText : Self.stoppedText
    }

    /// Checks the window and control are as the map said, glides the cursor there, then checks it all again and does
    /// it, off the main thread; the reply goes back to the chat. Time may have passed since petal_act (the person was
    /// asked, other actions went first), and the person may have selected something else while the cursor moved, so
    /// the window is checked right before the change, in the same breath; a Stop, the turn's end, using apps turned off
    /// or the app made private stop `cancel`, which every change checks first.
    private func run(_ job: Job) {
        // A note's act on its own window is quiet until it's decided otherwise: deciding takes nothing from the
        // person's Escape.
        var current = job
        current.quiet = job.map.ownPlace
        acting = current
        lastCaller = job.caller
        sessions[job.caller]?.last = Date()
        if let error = stale(job) { job.fail(error); return finished() }
        let map = maps[job.caller] ?? job.map
        // What it's doing, as its chat's activity: shielded here, where it's made, with no wait and no hop (so
        // captions can't arrive out of order), and only for the turn this job belongs to (`stale` just said it isn't over).
        if let agent = agent(job.caller), sessions[job.caller].map({ $0.turn == "\(agent.turn)" }) ?? false {
            agent.caption(job.caption, turn: agent.turn)
        }
        guard map.ownPlace else { return show(job, map) }
        decide(job, map, since: job.waitedFrom ?? Date())
    }

    /// A note acting on its own window: in the background, unless the person has that very window in front (then
    /// with the pointer, as always), and never while they're typing or clicking in it: it waits for a pause, a few
    /// seconds at most (Background.way). Read right before, off the main thread.
    private func decide(_ job: Job, _ map: Map, since: Date) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == map.pid
        Self.actQueue.async {
            // Unknown (an Accessibility read failed): never assumed behind; nothing is done.
            let way = Acting.situation(map, front: front).map(Background.way)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error = self.stale(job) { job.fail(error); return self.finished() }
                    guard let way else {
                        job.fail(Background.unsure(map.appName, changed: false))
                        return self.finished()
                    }
                    switch way {
                    case .foreground:
                        self.acting = job
                        self.sessions[job.caller]?.shown = true
                        self.standGuard()
                        self.agent(job.caller)?.quietly = false
                        self.show(job, map, since: since)
                    case .background:
                        self.quietly(job, map, since: since)
                    case .wait:
                        guard Date().timeIntervalSince(since) < Background.patience else {
                            job.fail(Self.typingThere(map.appName))
                            return self.finished()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.decide(job, map, since: since) }
                    }
                }
            }
        }
    }

    nonisolated static func typingThere(_ app: String) -> String { Background.busyThere(app) }

    /// In the background: no pointer, nothing brought forward. The window, what's selected in it, what has its
    /// keyboard and the control are checked right before the change, with nothing in between, and a tab's note acts
    /// only while its tab is the one showing.
    private func quietly(_ job: Job, _ map: Map, since: Date) {
        var job = job
        job.quiet = true
        acting = job
        standGuard()
        agent(job.caller)?.quietly = true
        let cancel = job.cancel
        // The app the person is using and the time, together, before anything is prepared: given back should the
        // note's app jump forward by itself, unless the person does something from here on.
        let baseline = Background.Baseline(front: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                           at: ProcessInfo.processInfo.systemUptime)
        // On the run's own display: a window the act opens there (a button that opens one) is the run's too.
        let display = map.hidden ? app.displays.display(for: job.caller)?.frame : nil
        let next = app.displays.nextIndex(for: job.caller)
        Self.actQueue.async {
            let before = display == nil ? [] : Set(RunDisplays.windowNumbers(pid: map.pid).keys)
            var outcome = Acting.Outcome()
            if let tabPlace = map.tabPlace, ClaudePanel.tabShowing(tabPlace) == nil {
                outcome.needs = .tab
            } else if !cancel.stopped {
                let checked = Acting.prepare(job.action, entry: job.entry, map: map, options: job.options)
                if let error = checked.error {
                    outcome.error = error
                } else if !cancel.stopped {
                    outcome = Acting.quietly(job.action, entry: job.entry, map: map, prepared: checked, options: job.options,
                                             cancel: cancel, baseline: baseline)
                }
            }
            // What it opened, when the person did nothing meanwhile (a window of theirs is never taken): onto the
            // run's display, without raising it.
            var opened: [(window: CGWindowID, pid: pid_t, element: AXUIElement)] = []
            // Only what can open one (a press, a key, a menu item): typing and scrolling never wait for it.
            if let display, ["press", "key", "menu"].contains(job.action), outcome.error == nil, outcome.needs == nil, !outcome.again,
               !cancel.stopped, ProcessInfo.processInfo.systemUptime - Acting.idle() < baseline.at {
                let bundle = map.bundle
                opened = RunDisplays.newWindows(bundle: bundle, before: before, timeout: 0.6, live: { !cancel.stopped })
                    .filter { $0.pid == map.pid }
                for (offset, item) in opened.enumerated() {
                    _ = RunDisplays.move(item.element, pid: item.pid, to: display, index: next + offset, live: { !cancel.stopped })
                }
            }
            // What it needs reaches its app's window in front (real keys, the cursor, a menu): is the person in that app?
            let personThere = outcome.needs == nil ? Background.Known.no : Acting.frontState(map.pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !opened.isEmpty { self.app.displays.track(opened, for: job.caller, bare: false) }
                    // The person's own use of an app wins: on its own display, an act that needs the app out of
                    // their hands waits for them to leave it, and says so, instead of being refused at once.
                    if let reason = outcome.needs, !cancel.stopped,
                       Background.personFirst(reason, hidden: map.hidden, untouched: outcome.untouched, appFront: personThere,
                                              waited: Date().timeIntervalSince(since)) == .wait {
                        return self.waitForPerson(job, reason, since: since)
                    }
                    // The person came back to that window before anything changed: decided again, by the same
                    // rules (the pointer and its pause if it's in front now), within the same patience.
                    guard outcome.again else { return self.done(job, outcome) }
                    self.again(job, map, since: since)
                }
            }
        }
    }

    /// The person is using the app a run needs real keys in (its window is on its own display, where a key, the
    /// cursor or a menu would be theirs): nothing was done, and the act waits for them to leave that app. The line
    /// moves on meanwhile (other chats' acts never wait for it), its note says "Waiting for TextEdit", and once they
    /// leave it takes its turn in the line again; past `Background.personPatience` the AI is told as before.
    private func waitForPerson(_ job: Job, _ reason: Background.Reason, since: Date) {
        app.displays.personBusy(job.caller, app: job.appName)
        finished()
        waitsForPerson(job, reason, since: since)
    }

    private func waitsForPerson(_ job: Job, _ reason: Background.Reason, since: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                if let error = self.stale(job) {
                    self.app.displays.personBusy(job.caller, app: nil)
                    return job.fail(error)
                }
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == job.map.pid
                switch Background.personStill(appFront: front, waited: Date().timeIntervalSince(since)) {
                case .wait:
                    self.waitsForPerson(job, reason, since: since)
                case .retry:
                    self.app.displays.personBusy(job.caller, app: nil)
                    var again = job
                    again.waitedFrom = since
                    self.enqueue(again)
                case .tell:
                    self.app.displays.personBusy(job.caller, app: nil)
                    job.fail(reason.words(job.appName, hidden: true))
                }
            }
        }
    }

    /// Nothing was done because the person came or went right before the first change: decided again, by the same
    /// rules, within the same patience.
    private func again(_ job: Job, _ map: Map, since: Date) {
        if let error = stale(job) { job.fail(error); return finished() }
        guard Date().timeIntervalSince(since) < Background.patience else {
            job.fail(Self.typingThere(map.appName))
            return finished()
        }
        decide(job, map, since: since)
    }

    /// With the pointer, where the person sees it. `since`: when a note's act first decided which way (its patience).
    private func show(_ job: Job, _ map: Map, since: Date = Date()) {
        let cancel = job.cancel
        // Stop shows at once, before Petal reads the window (a slow app can take a while to answer).
        let near = job.entry.map { CGPoint(x: $0.node.frame.midX, y: $0.node.frame.midY) }
            ?? CGPoint(x: map.windowFrame.midX, y: map.windowFrame.minY + 14)
        cursor.preparing(job.caption, near: Self.screenPoint(near))
        Self.actQueue.async {
            // A tab note's tab must still be the one its window shows.
            if let tabPlace = map.tabPlace, ClaudePanel.tabShowing(tabPlace) == nil {
                return DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.cursor.rest(); job.fail(ClaudePanel.tabNotShowing); self.finished() }
                }
            }
            let prepared = Acting.prepare(job.action, entry: job.entry, map: map, options: job.options)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if cancel.stopped { self.cursor.rest(); job.fail(self.whyStopped(job)); return self.finished() }
                    if let error = prepared.error { self.cursor.rest(); job.fail(error); return self.finished() }
                    self.cursor.glide(to: Self.screenPoint(prepared.spot), caption: job.caption)
                    DispatchQueue.main.asyncAfter(deadline: .now() + FakeCursor.glide + 0.03) {
                        if let error = self.stale(job) { self.cursor.rest(); job.fail(error); return self.finished() }
                        Self.actQueue.async {
                            var outcome = Acting.Outcome()
                            if !cancel.stopped {
                                // Right before the change: a tab note's tab still showing, then the window (its title
                                // is the tab's), what's selected in it, what has the keyboard and the control, again.
                                if let tabPlace = map.tabPlace, ClaudePanel.tabShowing(tabPlace) == nil {
                                    outcome.error = ClaudePanel.tabNotShowing
                                } else {
                                    let checked = Acting.prepare(job.action, entry: job.entry, map: map, options: job.options, known: prepared)
                                    // A note's act, decided while its window was in front: still so, and the person
                                    // still not typing there? Gone elsewhere meanwhile, it goes the background way
                                    // instead, which never brings anything forward.
                                    let again = map.ownPlace ? Background.recheck(Acting.situation(map)) : .go
                                    if let error = checked.error {
                                        outcome.error = error
                                    } else if again == .background {
                                        return DispatchQueue.main.async {
                                            MainActor.assumeIsolated {
                                                self.cursor.rest()
                                                if let error = self.stale(job) { job.fail(error); return self.finished() }
                                                self.quietly(job, map, since: since)
                                            }
                                        }
                                    } else if again == .refuse {
                                        outcome.error = Self.typingThere(map.appName)
                                    } else if again == .unsure {
                                        outcome.error = Background.unsure(map.appName, changed: false)
                                    } else if !cancel.stopped {
                                        if ["press", "menu"].contains(job.action) || (job.action == "key" && checked.menuItem != nil) {
                                            DispatchQueue.main.async { MainActor.assumeIsolated { self.cursor.press() } }
                                        }
                                        outcome = Acting.perform(job.action, entry: job.entry, map: map, prepared: checked,
                                                                 options: job.options, cancel: cancel, stayBehind: map.ownPlace)
                                    }
                                }
                            }
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    // A note's person left its window right before the first change: nothing was
                                    // done, and it's decided again (the background way, now).
                                    guard outcome.again else { return self.done(job, outcome) }
                                    self.cursor.rest()
                                    self.again(job, map, since: since)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// A copy-like press is watched (`Acting.CopyWatch`) before its reply goes back, even if stopped meanwhile: the
    /// line moves on at once, and only that chat's next action waits for it.
    private func done(_ job: Job, _ outcome: Acting.Outcome) {
        if !job.quiet { cursor.rest() }
        defer { finished() }
        guard let mark = outcome.copied else { return answer(job, outcome) }
        watching.insert(job.caller)
        Acting.CopyWatch.start(mark) { [weak self] cleared in
            guard let self else { return }
            self.watching.remove(job.caller)
            self.answer(job, outcome, cleared: cleared)
            self.next()
        }
    }

    private func answer(_ job: Job, _ outcome: Acting.Outcome, cleared: String? = nil) {
        if let cleared {
            assist.did(historyLine(job, outcome))
            return job.fail(cleared)
        }
        if job.cancel.stopped { return job.fail(whyStopped(job)) }
        // What the background can't do: the person brings the window forward (the note says so, and the AI button).
        if let reason = outcome.needs {
            // On its own display nothing waits for the window to come forward: the AI is told the other ways.
            if !job.map.hidden { waitsFor(job.caller, reason) }
            return job.fail(reason.words(job.appName, hidden: job.map.hidden))
        }
        if let error = outcome.error { return job.fail(error) }
        if job.map.ownPlace { waitsFor(job.caller, nil) }
        // Its own window on its display isn't empty any more: it's never closed with the display.
        if job.map.hidden { app.displays.changed(job.map.windowID, by: job.caller) }
        // What its own typing, focusing or scrolling changed in the window isn't a change behind its back.
        if let fingerprint = outcome.fingerprint, maps[job.caller]?.id == job.map.id { maps[job.caller]?.fingerprint = fingerprint }
        assist.did(historyLine(job, outcome))
        if let plan = job.options.fill {
            var reply: [String: Any] = ["filled": plan.field.rawValue, "app": job.appName]
            if let note = outcome.note { reply["note"] = note }
            if plan.submit { reply["next"] = "The window may have changed: call petal_ui again before using more ids." }
            return job.send(reply)
        }
        var reply: [String: Any] = ["done": job.caption, "app": job.appName]
        if job.quiet { reply["background"] = "Done in the background: nothing came forward, and the person's pointer and keyboard weren't touched." }
        if let value = outcome.value { reply["value"] = value }
        if let chose = outcome.chose { reply["chose"] = chose }
        if let note = outcome.note { reply["note"] = note }
        if ["press", "menu", "key"].contains(job.action) || job.options.submit {
            reply["next"] = "The window may have changed: call petal_ui again before using more ids."
        }
        job.send(reply)
    }

    /// What it did, for Settings › AI (never what it typed: that may be private).
    /// What an act did, for What Petal AI did: the control's name, the menu item, the app and the site are names
    /// (HistoryLine: redacted with the vault's index before the line is kept, left out while it can't be read).
    private func historyLine(_ job: Job, _ outcome: Acting.Outcome) -> HistoryLine {
        let thing: HistoryLine = "\(quoted: job.entry.map { UIMap.name($0.node) } ?? "", else: "a control")"
        let app: HistoryLine = "\(named: job.appName, else: "an app")"
        switch job.action {
        case "press": return "Pressed \(thing) in \(app)"
        case "type": return "Typed into \(thing) in \(app)"
        case "focus": return "Went to \(thing) in \(app)"
        case "scroll": return "Scrolled in \(app)"
        case "menu": return "Chose \(named: outcome.chose ?? job.options.path.joined(separator: " › "), else: "a menu item") in \(app)"
        case "fill":
            let plan = job.options.fill
            let place = plan?.place.web == true ? plan?.place.host ?? job.appName : job.appName
            let what = (plan.map { $0.title.isEmpty ? "" : $0.title + " " } ?? "") + (plan?.field.words ?? "details")
            return "Filled your \(named: what, else: "details") on \(named: place, else: "a page")"
        default:
            let chose: HistoryLine = outcome.chose.map { " (\(named: $0, else: "a menu item"))" } ?? ""
            return "Pressed \(named: job.options.key?.label ?? "a key", else: "a key")\(chose) in \(app)"
        }
    }

    /// The chat's own Agent (a note's, or Petal AI's plain chat), for its line in the preview.
    private func agent(_ caller: String) -> Agent? { app.claude.note(withID: caller)?.agent }

    /// A note now waits for the person (its window in front, its tab showing), or no longer does.
    private func waitsFor(_ caller: String, _ reason: Background.Reason?) {
        guard let agent = agent(caller), agent.needs != reason?.status else { return }
        agent.needs = reason?.status
    }

    // MARK: Stopping

    /// The person pressed Stop or Escape: the action under way and the rest of that reply's are cancelled, and so is
    /// every other reply that may use apps now (Stop means Petal AI stops using them). A Petal chat's reply can't use
    /// apps again; an AI session outside Petal asks again at its next task.
    func stop() {
        var callers = Set(sessions.filter { Self.mayAct($0.value) }.keys).union(line.map(\.caller))
        if let caller = acting?.caller ?? lastCaller { callers.insert(caller) }
        // All marked stopped first, so Stop never comes back for one still to be stopped; a Buy goes with it.
        for caller in callers {
            close(caller)
            sessions[caller]?.stopped = true
            sessions[caller]?.checkouts = []
        }
        cursor.hide()
        for caller in callers {
            cancelWork(of: caller)
            // A note's helper stops through its run (NoteHelpers.stop); a chat is told it was stopped.
            if let paper = app.claude.note(withID: caller)?.paper { app.paper.helpers.stop(paper) }
            else if let agent = app.claude.note(withID: caller)?.agent, agent.running { agent.personStopped() }
        }
        keepSweeping()
    }

    /// A chat stopped, was steered, ended its turn or is about to start another, or moved to another chat (Agent):
    /// what it was doing in apps ends there, its question waiting is answered Don't, what it was allowed goes, and
    /// that turn never acts again (its next turn may, asking again). `forget`: its window's ids go too (a new chat,
    /// or another one picked).
    func end(_ caller: String, forget: Bool = false) {
        if acting?.caller == caller { cursor.hide() }
        close(caller)
        cancelWork(of: caller)
        sessions[caller] = nil
        if forget { maps[caller] = nil }
        if !closed.isEmpty { keepSweeping() }
    }

    /// The caller's request went unanswered by its asker's leaving (Assist.hungUp): what it had going and waiting
    /// stops, and what it was allowed goes, but unlike `end` its next request may ask again at once.
    func abandon(_ caller: String) {
        if acting?.caller == caller { cursor.hide() }
        cancelWork(of: caller)
        sessions[caller] = nil
    }

    /// A note was stuck to something else (its tab, its window or all of its app; Agent.place): its ids, a petal_ui
    /// under way, its actions waiting or under way and its question waiting (its card goes) were for the old place,
    /// so they go, and its AI is told at once to look again. What the person allowed this reply stays.
    func placeChanged(_ caller: String) {
        places[caller, default: 0] += 1
        maps[caller] = nil
        if let acting, acting.caller == caller {
            acting.cancel.stop()
            cursor.hide()
        }
        let waiting = line.filter { $0.caller == caller }
        line.removeAll { $0.caller == caller }
        for job in waiting {
            job.cancel.stop()
            job.fail(Self.moved)
        }
        assist.decline(owner: caller)
    }

    private func cancelWork(of caller: String) {
        sessions[caller]?.cancel.stop()
        if let acting, acting.caller == caller { acting.cancel.stop() }
        let waiting = line.filter { $0.caller == caller }
        line.removeAll { $0.caller == caller }
        for job in waiting {
            job.cancel.stop()
            job.fail(whyStopped(job))
        }
        assist.decline(owner: caller)
    }

    /// Settings changed (Config's onChange). Using apps turned off: everything under way stops, and what each chat
    /// was allowed this turn goes. An app made private: what was to be done in it stops, and its ids go.
    func settingsChanged() {
        if !app.config.bool("computerUse") {
            let callers = Set(sessions.keys).union(line.map(\.caller)).union(acting.map { [$0.caller] } ?? [])
            guard !callers.isEmpty || !maps.isEmpty else { return }
            cursor.hide()
            for caller in callers {
                close(caller)
                cancelWork(of: caller)
            }
            if !closed.isEmpty { keepSweeping() }
            sessions = [:]
            maps = [:]
            return
        }
        if let acting, assist.neverLook(acting.bundle) {
            acting.cancel.stop()
            cursor.hide()
        }
        let hidden = line.filter { assist.neverLook($0.bundle) }
        line.removeAll { assist.neverLook($0.bundle) }
        for job in hidden {
            job.cancel.stop()
            job.fail(whyStopped(job))
        }
        maps = maps.filter { !assist.neverLook($0.value.bundle) }
    }

    /// Accessibility's top-left point as AppKit's (bottom-left, from the main screen).
    static func screenPoint(_ point: CGPoint) -> CGPoint {
        let height = Screens.all.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: height - point.y)
    }
}

// MARK: - Reading a window

/// A window's controls through Accessibility, off the main thread, within a time budget.
enum Reader {
    struct Reading {
        var title = ""
        var window: AXUIElement?
        var windowID: CGWindowID?
        var windowFrame = CGRect.zero
        var nodes: [UINode] = []
        var elements: [Int: AXUIElement] = [:]   // by the node's order
        var meanings: [Int: UIMap.Meaning] = [:] // by the node's order
        var lists: [AXUIElement] = []
        var fingerprint = UIMap.Fingerprint()
        var gone = false
        var timedOut = false
        /// Somewhere in the window (any control, not only those told): a vault secret, a password field, or a control
        /// whose names say it holds a password, token or API key. A Copy button there may copy it.
        var holdsSecret = false
        /// The vault couldn't be read: nothing was read, since nothing could be checked for its secrets.
        var vaultUnreadable = false
        /// The web pages met (each tab page in a browser, several side by side in one split into panes) and their
        /// addresses: a Buy in this window ends when its own page isn't one of them.
        var pages: [(page: AXUIElement, url: String?)] = []
        /// The orders at which the controls asked about (`focus`) were met, and those hidden as pieces of a secret
        /// several show together (`UIMap.joinedHidden`).
        var focusOrders: Set<Int> = []
        var joined: Set<Int> = []
        /// The joined pieces' texts in reading order, the orders of everything that holds one (a page's web area),
        /// and whether the pieces were checked whole (else `joined` is the fallback's: short texts that are part of a
        /// vault secret).
        var joinedTexts: [String] = []
        var aroundJoined: Set<Int> = []
        var joinedWhole = true
        /// Controls showing a secret whole in their own text (a card number in one span of a page), and everything
        /// that holds one, with the secret's parts (`UIMap.guardedSecrets`): selecting it a little at a time would
        /// show it whole.
        var guarded: [Int: [String]] = [:]
    }

    static let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                             kAXPlaceholderValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute,
                             kAXIdentifierAttribute]
    /// Controls whose insides are only their own label: not walked into.
    static let leaves: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXSlider", "AXLink",
                                      "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXIncrementor", "AXColorWell", "AXSearchField", "AXImage"]
    static let listRoles: Set<String> = ["AXTable", "AXOutline", "AXList", "AXBrowser"]

    /// `deep`: also read every other control's text, for `holdsSecret` (a dashboard's key shown as plain text).
    /// `focus`: controls whose orders are noted (`focusOrders`), to tell whether one is a piece of a joined secret.
    static func read(pid: pid_t, window wanted: UInt32?, budget: TimeInterval, deep: Bool = false, focus: [AXUIElement] = []) -> Reading {
        var reading = Reading()
        // An Electron app's tree, asked for the first time, fills in a moment later.
        if AccessibilityTree.wake(pid) { usleep(300_000) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var window: AXUIElement? = Windows.value(app, kAXFocusedWindowAttribute) ?? Windows.value(app, kAXMainWindowAttribute)
        let all: [AXUIElement] = Windows.value(app, kAXWindowsAttribute) ?? []
        if let wanted, window.flatMap({ Windows.id(of: $0) }) != wanted {
            guard let match = all.first(where: { Windows.id(of: $0) == wanted }) else { reading.gone = true; return reading }
            window = match
        }
        guard let window = window ?? all.first else { return reading }
        // Nothing that holds a vault secret is told to the AI: not a control's text, not the window's title.
        let vault = VaultIndex.current()
        guard !vault.unreadable else { reading.vaultUnreadable = true; return reading }
        reading.window = window
        reading.windowID = Windows.id(of: window)
        let title: String = Windows.value(window, kAXTitleAttribute) ?? ""
        reading.title = vault.matches(title) ? UIMap.hidden : title
        if reading.title == UIMap.hidden { reading.holdsSecret = true }
        reading.windowFrame = Windows.frame(of: window) ?? .zero

        let deadline = Date().addingTimeInterval(budget)
        // Each element: its parent (by order) and its place among that parent's children, for secrets in pieces.
        var stack: [(element: AXUIElement, depth: Int, clip: CGRect?, web: Bool, parent: Int, sibling: Int)] = [(window, 0, nil, false, -1, 0)]
        var order = 0
        var visited = 0
        // Every element read (by order), and which of them are told: a secret shown only by several together (a card
        // number in four fields) is hidden in each before anything goes out.
        var walked: [UINode] = []
        // Each as read, before anything of it is hidden or cut short: the pieces of a secret shown in several are
        // looked for in these, so a piece that holds part of it by itself (an Amex number as 37828224 and 6310005)
        // still finds the rest beside it.
        var whole: [UINode] = []
        var told: [Int] = []
        var own: [Int: [String]] = [:]
        while let (element, depth, clip, web, parent, sibling) = stack.popLast() {
            if visited >= 5000 || Date() > deadline { reading.timedOut = true; break }
            visited += 1
            let values = Self.values(element, attributes)
            let role = values[kAXRoleAttribute] as? String ?? ""
            var node = UINode(role: role)
            node.subrole = values[kAXSubroleAttribute] as? String ?? ""
            // Whole until the vault's secrets are taken out (a secret cut at the end would leave its start), then short.
            node.title = values[kAXTitleAttribute] as? String ?? ""
            node.label = values[kAXDescriptionAttribute] as? String ?? ""
            node.help = values[kAXHelpAttribute] as? String ?? ""
            node.placeholder = values[kAXPlaceholderValueAttribute] as? String ?? ""
            node.identifier = String((values[kAXIdentifierAttribute] as? String ?? "").prefix(200))
            node.frame = frame(values[kAXPositionAttribute], values[kAXSizeAttribute])
            node.enabled = (values[kAXEnabledAttribute] as? Bool) ?? true
            node.focused = (values[kAXFocusedAttribute] as? Bool) ?? false
            node.web = web
            node.clip = clip
            node.order = order
            node.parent = parent
            node.sibling = sibling
            if focus.contains(where: { CFEqual($0, element) }) { reading.focusOrders.insert(order) }
            // The tab's page: never an app's own (T3 Code's t3code://app/ page holds its sites' pages).
            if role == "AXWebArea", reading.pages.count < VaultReader.panes {
                let address = VaultReader.url(element)
                if Vault.isTabPage(address) { reading.pages.append((element, address)) }
            }
            // A password field's value is never read. A static text's is, for secrets shown in pieces (a web page's
            // spans show their text only there); it's never told.
            if UIMap.valueRoles.contains(role) || role == "AXStaticText", !UIMap.isSecure(node) {
                node.value = text(Windows.value(element, kAXValueAttribute) as CFTypeRef?, whole: true)
            }
            let toggle = UIMap.isToggle(role: role, subrole: node.subrole)
            let meaning = UIMap.meaning(role: role, subrole: node.subrole, title: node.title, label: node.label,
                                        value: !toggle ? "" : UIMap.valueRoles.contains(role) ? node.value
                                            : text(Windows.value(element, kAXValueAttribute) as CFTypeRef?))
            // Each text matched against the vault once, for both what's told and whether Copy may go.
            var matched: [String: Bool] = [:]
            let secret = { (text: String) -> Bool in
                if let known = matched[text] { return known }
                let found = vault.matches(text)
                matched[text] = found
                return found
            }
            // Named for a secret counts only for a field one types into: a heading "Card number" doesn't keep Copy
            // away from the page (what it shows is still matched against the vault).
            // A field Petal filled with a secret stays hidden whatever it shows now (part of a card number left
            // after an edit is still part of it).
            let filled = Sensitive.isFilled(element, pid: pid)
            whole.append(node)
            let parts = UIMap.ownSecrets(node, secret: secret, parts: vault.parts)
            if !parts.isEmpty { own[order] = parts }
            let holds = UIMap.holdsSecret(node, filled: filled, secret: secret)
            node = UIMap.redact(node, filled: filled, secret: secret)
            if holds {
                reading.holdsSecret = true
            } else if deep, !UIMap.valueRoles.contains(role), vault.matches(text(Windows.value(element, kAXValueAttribute) as CFTypeRef?, whole: true)) {
                reading.holdsSecret = true
            }
            for path in [\UINode.title, \.label, \.help, \.placeholder] { node[keyPath: path] = String(node[keyPath: path].prefix(200)) }
            node.value = String(node.value.prefix(400))
            if UIMap.pressableRoles.contains(role), depth > 0, !UIMap.name(node).isEmpty {
                node.pressable = actions(element).contains(kAXPressAction as String)
            }
            walked.append(node)
            if UIMap.isActionable(node) {
                told.append(order)
                reading.elements[order] = element
                reading.meanings[order] = meaning
            }
            if listRoles.contains(role), reading.lists.count < 6 { reading.lists.append(element) }
            order += 1
            guard depth < 40, !leaves.contains(role) else { continue }
            var inner = clip
            if role == "AXScrollArea", node.frame.width > 0 { inner = clip.map { $0.intersection(node.frame) } ?? node.frame }
            // Long tables and lists: only the rows showing.
            let children: [AXUIElement]
            if listRoles.contains(role) {
                children = Windows.value(element, "AXVisibleRows") ?? Windows.value(element, "AXVisibleChildren") ?? Windows.value(element, kAXChildrenAttribute) ?? []
            } else {
                children = Windows.value(element, kAXChildrenAttribute) ?? []
            }
            let me = order - 1
            for (index, child) in children.prefix(500).enumerated().reversed() {
                stack.append((child, depth + 1, inner, web || role == "AXWebArea", me, index))
            }
        }
        // Bounded as the picture's check is; out of time, only a text that holds a secret by itself is hidden.
        let joinBy = Date().addingTimeInterval(0.5)
        (reading.joined, reading.joinedWhole) = UIMap.joinedHidden(whole, matches: vault.matches, spans: vault.spans, going: { Date() < joinBy })
        if !reading.joined.isEmpty { reading.holdsSecret = true }
        for index in reading.joined.sorted() {
            if let path = UIMap.pieceText(whole[index]) { reading.joinedTexts.append(whole[index][keyPath: path]) }
            var at = walked[index].parent
            while at >= 0, at < walked.count, reading.aroundJoined.insert(at).inserted { at = walked[at].parent }
        }
        for index in reading.joined { UIMap.hideAll(&walked[index]) }
        reading.guarded = UIMap.guardedSecrets(whole, own: own)
        reading.nodes = told.map { walked[$0] }
        reading.fingerprint = fingerprint(app: app, window: window, lists: reading.lists)
        return reading
    }

    /// One of `controls` (what has the keyboard in window `window` of `pid`) is a piece of a secret its window shows
    /// only in pieces, or holds one shown whole and what's selected is part of it (`UIMap.focusInJoined`), or the
    /// window couldn't be checked: then nothing of it is selected out or copied. Reads the whole window (within a second), so never on the main thread.
    static func inJoinedSecret(pid: pid_t, window: UInt32?, controls: [AXUIElement]) -> Bool {
        guard !controls.isEmpty else { return false }
        guard let reading = VaultIndex.settled({ _ in read(pid: pid, window: window, budget: 1.0, focus: controls) }),
              !reading.vaultUnreadable, !reading.gone, reading.window != nil else { return true }
        // What would go out: what's selected, or a control's value when it tells no selection.
        let selected = controls.compactMap { control -> String? in
            let found = values(control, [kAXSelectedTextAttribute, kAXValueAttribute])
            return found[kAXSelectedTextAttribute] as? String ?? found[kAXValueAttribute] as? String
        }
        // The pieces count only when they were checked whole; else what's selected counts by the vault's own rules.
        return UIMap.focusInJoined(focus: reading.focusOrders, hidden: reading.joined, around: reading.aroundJoined,
                                   pieces: reading.joinedWhole ? reading.joinedTexts : [], guarded: reading.guarded,
                                   complete: !reading.timedOut && reading.joinedWhole,
                                   selected: selected, matches: VaultIndex.current().matches)
    }

    /// What the window shows now that an act depends on (UIMap.Fingerprint): its title, the control with the
    /// keyboard when it's in this window, and its lists' selected rows. Kept by Petal, never told to the AI.
    static func fingerprint(app: AXUIElement, window: AXUIElement, lists: [AXUIElement]) -> UIMap.Fingerprint {
        let title: String = Windows.value(window, kAXTitleAttribute) ?? ""
        var role = "", subrole = "", value = "", identifier = "", caret = ""
        var place = CGRect.zero
        var element: AXUIElement?
        if let focused: AXUIElement = Windows.value(app, kAXFocusedUIElementAttribute),
           let home: AXUIElement = Windows.value(focused, kAXWindowAttribute), CFEqual(home, window) {
            let found = values(focused, [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXPositionAttribute, kAXSizeAttribute])
            role = found[kAXRoleAttribute] as? String ?? ""
            subrole = found[kAXSubroleAttribute] as? String ?? ""
            identifier = found[kAXIdentifierAttribute] as? String ?? ""
            place = frame(found[kAXPositionAttribute], found[kAXSizeAttribute])
            element = focused
            if subrole != "AXSecureTextField" {
                // The whole value (an edit at the end of a long draft counts) and where the caret or selection is.
                value = text(Windows.value(focused, kAXValueAttribute) as CFTypeRef?, whole: true)
                var range = CFRange()
                if let raw: AXValue = Windows.value(focused, kAXSelectedTextRangeAttribute), AXValueGetValue(raw, .cfRange, &range) {
                    caret = "\(range.location),\(range.length)"
                }
            }
        }
        // Every selected row counts (up to UIMap.rowCap), not only the first few: a sixth file selected while the
        // person is asked changes it. The first few in words, the rest by their index and own texts (one message each).
        let deadline = Date().addingTimeInterval(0.5)
        var selected: [UIMap.Selected] = []
        for list in lists {
            guard let rows = selectedRows(list) else { selected.append(UIMap.Selected(count: nil)); continue }
            var read = UIMap.Selected(count: rows.count)
            for (index, row) in rows.prefix(UIMap.rowCap).enumerated() {
                if Date() > deadline { read.complete = false; break }
                read.rows.append(index < 5 ? describe(row) : identity(row))
            }
            selected.append(read)
        }
        return UIMap.fingerprint(title: title, focusRole: role, focusSubrole: subrole, focusValue: value, focusIdentifier: identifier,
                                 focusFrame: place, focusRange: caret, focused: element, selection: UIMap.selection(selected))
    }

    /// A list's selected rows: none when it can't select anything, nil when its app didn't say (busy, or no answer).
    static func selectedRows(_ list: AXUIElement) -> [AXUIElement]? {
        for name in [kAXSelectedRowsAttribute, kAXSelectedChildrenAttribute] {
            var raw: CFTypeRef?
            switch AXUIElementCopyAttributeValue(list, name as CFString, &raw) {
            case .success: return raw as? [AXUIElement]
            case .noValue: return []
            case .attributeUnsupported: continue
            default: return nil
            }
        }
        return []
    }

    /// A selected row by its index and its own texts, in one message to the app.
    static func identity(_ row: AXUIElement) -> String {
        let names = [kAXIndexAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute]
        let found = values(row, names)
        return names.map { name in
            switch found[name] {
            case let text as String: return String(text.prefix(80))
            case let number as NSNumber: return number.stringValue
            default: return ""
            }
        }.joined(separator: "|")
    }

    /// A selected row in a few words: its index and the first texts in it.
    static func describe(_ row: AXUIElement) -> String {
        var words: [String] = []
        if let index: Int = Windows.value(row, kAXIndexAttribute) { words.append("#\(index)") }
        var stack: [(element: AXUIElement, depth: Int)] = [(row, 0)]
        var seen = 0
        while let (element, depth) = stack.popLast(), seen < 24, words.count < 6 {
            seen += 1
            let found = values(element, [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute])
            if let text = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].lazy.compactMap({ found[$0] as? String }).first(where: { !$0.isEmpty }) {
                words.append(String(text.prefix(80)))
            }
            guard depth < 3 else { continue }
            let children: [AXUIElement] = Windows.value(element, kAXChildrenAttribute) ?? []
            for child in children.prefix(8).reversed() { stack.append((child, depth + 1)) }
        }
        return words.joined(separator: " ")
    }

    /// What a control means now (UIMap.Meaning): its kind and words in one message, and a switch's state in a second
    /// (never a password field's value); nil when it's gone or its app didn't answer.
    static func meaning(_ element: AXUIElement) -> UIMap.Meaning? {
        let found = values(element, [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute])
        guard let role = found[kAXRoleAttribute] as? String, !role.isEmpty else { return nil }
        let subrole = found[kAXSubroleAttribute] as? String ?? ""
        let value = UIMap.isToggle(role: role, subrole: subrole) ? text(Windows.value(element, kAXValueAttribute) as CFTypeRef?) : ""
        return UIMap.meaning(role: role, subrole: subrole, title: found[kAXTitleAttribute] as? String ?? "",
                             label: found[kAXDescriptionAttribute] as? String ?? "", value: value)
    }

    /// A control's names and kind, in one message to its app (never its value): enough to tell a password field, a
    /// field for a token, or a Paste button.
    static func node(_ element: AXUIElement) -> UINode {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                     kAXPlaceholderValueAttribute, kAXIdentifierAttribute]
        let found = values(element, names)
        func string(_ name: String) -> String { String((found[name] as? String ?? "").prefix(200)) }
        var node = UINode(role: string(kAXRoleAttribute))
        node.subrole = string(kAXSubroleAttribute)
        node.title = string(kAXTitleAttribute)
        node.label = string(kAXDescriptionAttribute)
        node.help = string(kAXHelpAttribute)
        node.placeholder = string(kAXPlaceholderValueAttribute)
        node.identifier = string(kAXIdentifierAttribute)
        return node
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

    /// A control's value as words, cut to 400 characters unless `whole` (then the vault's secrets are taken out first).
    static func text(_ value: CFTypeRef?, whole: Bool = false) -> String {
        switch value {
        case let string as String: return whole ? string : String(string.prefix(400))
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
/// pointer. Every change checks `cancel` right before it's made: a Stop, a steer or the turn's end lands between
/// any two of them.
enum Acting {
    struct Options {
        var text = ""
        var replace = true
        var submit = false
        var direction = ""
        var path: [String] = []
        var key: UIMap.Key?
        /// A field filled from the vault (VaultFill.swift).
        var fill: VaultFillPlan?
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
        /// The window as its own typing, focusing or scrolling left it.
        var fingerprint: UIMap.Fingerprint?
        /// A copy-like press: the clipboard is watched from here before the reply goes back.
        var copied: CopyMark?
        /// In the background, it can't be done without the window in front: nothing was done.
        var needs: Background.Reason?
        /// With `needs`: decided before anything of the act was tried, so trying the whole act again later is safe.
        var untouched = false
        /// In the background, the person came back to the note's window before anything changed: nothing was done,
        /// and it's decided again (Background.behind).
        var again = false
    }

    static let buyEndedText = "The Buy is over (the tab moved on, the window closed, or the reply ended): no more payment info was filled. Don't try another way; if the person still wants it, fill again on the checkout page and Petal asks them again."

    static let changed = "Call petal_ui again for fresh ids."
    static let password = "That's a password field: petal_act doesn't type there. petal_vault fills a saved password (action: fill)."

    /// The window is still there, where the map said and showing what it showed (the same title, the same rows
    /// selected, the same control with the keyboard); so is the control. Then where the cursor goes, and for a
    /// menu, its item. `known`: checked again right before the change (after the cursor's glide, when the person may
    /// have selected another email), keeping the menu item found before if it's still there and enabled.
    static func prepare(_ action: String, entry: ComputerUse.Entry?, map: ComputerUse.Map, options: Options, known: Prepared? = nil) -> Prepared {
        var prepared = Prepared()
        guard let now = Windows.frame(of: map.window), now.width > 0 else {
            prepared.error = "The window is gone (closed, or its app quit). " + changed
            return prepared
        }
        // A menu or a key doesn't care where the window is; a control does.
        if entry != nil, UIMap.moved(now, map.windowFrame) {
            prepared.error = "The window moved or changed size since petal_ui. " + changed
            return prepared
        }
        prepared.spot = CGPoint(x: now.midX, y: now.minY + 14)
        let app = AXUIElementCreateApplication(map.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let current = Reader.fingerprint(app: app, window: map.window, lists: map.lists)
        if let why = UIMap.changed(map.fingerprint, current) {
            prepared.error = why
            return prepared
        }
        if let entry {
            guard let meaning = Reader.meaning(entry.element) else {
                prepared.error = "That control isn't there anymore: the window changed. " + changed
                return prepared
            }
            let frame = Windows.frame(of: entry.element) ?? .zero
            if UIMap.moved(frame, entry.node.frame) {
                prepared.error = "That control moved: the window changed since petal_ui. " + changed
                return prepared
            }
            // Where it was is not enough: the same button may mean the opposite now (Mute became Unmute). A field
            // Petal filled never has its new name told (it may echo what's in it).
            let filled = Sensitive.isFilled(entry.element, pid: map.pid)
            if let why = UIMap.changed(entry.meaning, meaning, secret: { filled || VaultIndex.current().matches($0) }) {
                prepared.error = why
                return prepared
            }
            if frame.width > 0 { prepared.spot = CGPoint(x: frame.midX, y: frame.midY) }
        }
        if let known {
            prepared.spot = known.spot
            if let item = known.menuItem {
                var role: CFTypeRef?
                let there = AXUIElementCopyAttributeValue(item, kAXRoleAttribute as CFString, &role) == .success && role != nil
                let enabled = (Windows.value(item, kAXEnabledAttribute) as Bool?) != false
                if there && enabled {
                    prepared.menuItem = item
                    prepared.menuTitle = known.menuTitle
                } else if action == "menu" {
                    prepared.error = "\(known.menuTitle ?? "That menu item") isn't there or is greyed out now. " + changed
                    return prepared
                }
            }
        }
        switch action {
        case "menu" where known != nil: break
        case "menu":
            let found = menuItem(app, path: options.path)
            if let error = found.error { prepared.error = error; return prepared }
            prepared.menuItem = found.item
            prepared.menuTitle = found.title
            if let bar = found.bar, bar.width > 0 { prepared.spot = CGPoint(x: bar.midX, y: bar.midY) }
        case "key", "type":
            // Never into a password field: the one asked for, or (with none asked for) what has the cursor now.
            if let entry, UIMap.isSecure(entry.node) || isSecure(entry.element) {
                prepared.error = password
                return prepared
            }
            if entry == nil, let why = secretFieldRefusal(map, nil, pasting: false) {
                prepared.error = why
                return prepared
            }
            if known == nil, action == "key", let key = options.key, key.command, let found = menuEquivalent(app, key) {
                prepared.menuItem = found.item
                prepared.menuTitle = found.title
            }
        case "press":
            // A Paste button: never a secret off the clipboard, nor into a password field (early here; again right
            // before the press).
            if let entry {
                let pastes = UIMap.clip(control: entry.node) == .paste
                if pastes || UIMap.mightPaste(entry.node), let why = pasteRefusal() ?? secretFieldRefusal(map, nil, pasting: true) {
                    prepared.error = why
                    return prepared
                }
            }
        default: break
        }
        guard action == "menu" || action == "key" else { return prepared }
        let key = action == "key" ? options.key : nil
        // Delete, Trash, Close or Quit on rows Petal couldn't count: only straight after a look.
        let destructive = UIMap.destructive(menu: prepared.menuTitle) || key.map(UIMap.destructive(key:)) == true
        if let why = UIMap.unsure(map.fingerprint, current, destructive: destructive, age: Date().timeIntervalSince(map.made)) {
            prepared.error = why
            return prepared
        }
        // A secret on the clipboard is never pasted, nor anything into a password field (early here; again right
        // before the paste). What a copy takes is checked only in perform, once the window is in front: the keyboard
        // may be in another window until then.
        if clip(key: key, item: prepared.menuItem, title: prepared.menuTitle) == .paste,
           let why = pasteRefusal() ?? secretFieldRefusal(map, nil, pasting: true) {
            prepared.error = why
        }
        return prepared
    }

    // MARK: The clipboard and the vault

    /// Never a vault secret onto the clipboard, where petal_look could read it, nor off it into a window, nor anything
    /// pasted into a password field: the vault fills its own (VaultFill.swift). The one check for every
    /// way Petal copies or pastes (a key, a menu item, a button), right before it, in the window it acts on (`perform`).
    static func clipboardRefusal(_ map: ComputerUse.Map, _ element: AXUIElement?, clip: UIMap.Clip?) -> String? {
        switch clip {
        case .copy?: return copyRefusal(map, element)
        case .paste?: return pasteRefusal() ?? secretFieldRefusal(map, element, pasting: true)
        case nil: return nil
        }
    }

    /// What a key, or the menu item it or a menu path chose, does with the clipboard: the key itself first, then the
    /// item's shortcut (the same in every language), its selector, and last its words.
    static func clip(key: UIMap.Key?, item: AXUIElement?, title: String?) -> UIMap.Clip? {
        if let key, let clip = UIMap.clip(key: key) { return clip }
        guard let item else { return title.flatMap { UIMap.clip(title: $0) } }
        let found = Reader.values(item, [kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXIdentifierAttribute, kAXTitleAttribute])
        let own = found[kAXTitleAttribute] as? String ?? ""
        return UIMap.clip(menuItem: own.isEmpty ? title : own, identifier: found[kAXIdentifierAttribute] as? String ?? "",
                          character: found[kAXMenuItemCmdCharAttribute] as? String,
                          modifiers: (found[kAXMenuItemCmdModifiersAttribute] as? NSNumber)?.intValue ?? 0)
            ?? title.flatMap { UIMap.clip(title: $0) }
    }

    /// What has the app's keyboard now (and `element`, which a key focuses first) is a password field, or, for a
    /// paste, a field whose names say it holds a password or token: then why nothing goes in. Every key and every
    /// paste (a key, a menu item or a button) asks this right before it.
    static func secretFieldRefusal(_ map: ComputerUse.Map, _ element: AXUIElement?, pasting: Bool) -> String? {
        let app = AXUIElementCreateApplication(map.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let focused: AXUIElement? = Windows.value(app, kAXFocusedUIElementAttribute)
        for control in [element, focused].compactMap({ $0 }) {
            let node = Reader.node(control)
            if UIMap.isSecure(node) {
                return pasting ? "A password field has the cursor: Petal doesn't paste there. petal_vault fills a saved one (action: fill)."
                    : "A password field has the cursor: Petal doesn't type there. petal_vault fills a saved one (action: fill)."
            }
            if pasting, UIMap.looksSecret(node) {
                return "The cursor is in a field for a password or token: Petal doesn't paste there. petal_vault fills a saved one (action: fill)."
            }
        }
        return nil
    }

    /// The window petal_ui looked at is in front, and what has its keyboard (and `element`, which a key focuses
    /// first) holds no vault secret in what's selected or in its value; else why nothing is copied.
    static func copyRefusal(_ map: ComputerUse.Map, _ element: AXUIElement?) -> String? {
        guard windowInFront(map) else { return "That window isn't in front anymore; nothing was copied." }
        let app = AXUIElementCreateApplication(map.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let focused: AXUIElement? = Windows.value(app, kAXFocusedUIElementAttribute)
        if let focused, let home: AXUIElement = Windows.value(focused, kAXWindowAttribute), !isWindow(home, of: map) {
            return "The keyboard is in another window of \(map.appName); nothing was copied."
        }
        for control in [element, focused].compactMap({ $0 }) {
            // A field Petal filled with a secret, whatever it shows now (part of a card number left after an edit).
            if Sensitive.isFilled(control, pid: map.pid) {
                return "That field holds a secret Petal filled in: Petal doesn't copy it. petal_vault fills a saved one where it's needed (action: fill)."
            }
            let found = Reader.values(control, [kAXSelectedTextAttribute, kAXValueAttribute])
            for name in [kAXSelectedTextAttribute, kAXValueAttribute] {
                guard let text = found[name] as? String else { continue }
                switch Assist.vaultCheck(text) {
                case .secret:
                    return "What's selected holds one of the vault's secrets: Petal doesn't copy it. petal_vault fills a saved one where it's needed (action: fill)."
                case .tooLong: return tooMuch("copy")
                case .unreadable: return vaultUnreadable("copy")
                case .clean: break
                }
            }
        }
        // Nor one piece of a secret the window shows in pieces (a card number as four fields of four digits): copied
        // a field at a time, it would be whole again.
        if Reader.inJoinedSecret(pid: map.pid, window: map.windowID, controls: [element, focused].compactMap { $0 }) {
            return "What has the keyboard is part of a secret this window shows in pieces (a card number, a key): Petal doesn't copy it. petal_vault fills a saved one where it's needed (action: fill)."
        }
        return nil
    }

    /// The clipboard holds a vault secret (the redaction's matching), or something a password manager marked
    /// private (what petal_look won't read): then why nothing is pasted. Off the main thread: the Keychain and an
    /// app's promised clipboard data may take a while.
    nonisolated static func pasteRefusal(_ pasteboard: NSPasteboard = .general) -> String? {
        let refusal = "The clipboard holds a secret (one of the vault's, or a password manager's): Petal doesn't paste it. petal_vault fills a saved one (action: fill)."
        if Assist.isConcealed(pasteboard) { return refusal }
        for type in [NSPasteboard.PasteboardType.string, .html, .rtf, .URL] {
            guard let text = pasteboard.string(forType: type) else { continue }
            switch Assist.vaultCheck(text) {
            case .secret: return refusal
            case .tooLong: return tooMuch("paste")
            case .unreadable: return vaultUnreadable("paste")
            case .clean: break
            }
        }
        return nil
    }

    /// Text past `UIMap.SecretIndex.limit` (about 1 MB) isn't searched for the vault's secrets, so it isn't moved.
    nonisolated static func tooMuch(_ verb: String) -> String {
        "That's too much to check for saved secrets; \(verb) it yourself."
    }

    /// While the vault can't be read, nothing can be checked for its secrets, so nothing is moved.
    nonisolated static func vaultUnreadable(_ verb: String) -> String {
        VaultStore.unreadableText + " Petal can't check this for saved secrets, so it doesn't \(verb) it: ask the person, or try again in a moment."
    }

    /// Before a Copy or Cut button (or one whose names mention copying): the window, read again now (every control, and every text in it), shows no vault
    /// secret and no password, token or API key field, since a button like "Copy API key" copies its own key
    /// whatever has the keyboard. Off the main thread.
    static func copyButtonRefusal(_ map: ComputerUse.Map) -> String? {
        guard let reading = VaultIndex.settled({ _ in Reader.read(pid: map.pid, window: map.windowID, budget: 1.5, deep: true) }),
              !reading.vaultUnreadable else { return vaultUnreadable("copy") }
        if reading.gone || reading.window == nil { return "That window is gone; nothing was copied. " + changed }
        if reading.holdsSecret {
            return "This window shows a secret (one of the vault's, or a password, token or API key): Petal doesn't press its Copy buttons. petal_vault fills a saved one where it's needed (action: fill)."
        }
        if reading.timedOut { return "Petal couldn't read all of this window in time to check it for secrets, so nothing was copied: ask the person to copy it." }
        return nil
    }

    /// A copy-like press's backstop, should a secret reach the clipboard anyway: the clipboard's change count just
    /// before the press (never what it held), and when the press was (system uptime).
    struct CopyMark {
        let count: Int
        let at: TimeInterval

        static func now(_ pasteboard: NSPasteboard = .general) -> CopyMark {
            CopyMark(count: pasteboard.changeCount, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// Watches the clipboard for `wait` after a copy-like press, every 50 ms on a queue of its own, so neither the act
    /// queue nor another chat's actions wait behind it. Only the press's own copy (one step on) is read, and only its
    /// plain text and the password managers' markers: a vault secret or something marked private is cleared, while
    /// it's still that copy. Nothing is ever put back. Another copy, or the person's own key or click (a global
    /// monitor installed just for the watch, and the keyboard's and mouse's own times since the press), and it's left
    /// alone for good. `then` gets why it was cleared, or nil, on the main thread.
    final class CopyWatch: @unchecked Sendable {
        nonisolated static let queue = DispatchQueue(label: "petal.computer.clipboard", qos: .userInitiated)
        static let cleared = "That button copied a saved secret (or more text than Petal can check for one); Petal cleared the clipboard. petal_vault fills a saved one where it's needed (action: fill)."

        private let mark: CopyMark
        private let until: TimeInterval
        private let pasteboard: NSPasteboard
        private let then: @MainActor (String?) -> Void
        private let lock = NSLock()
        private var heard = false
        private var monitor: Any?

        private init(_ mark: CopyMark, wait: TimeInterval, pasteboard: NSPasteboard, then: @escaping @MainActor (String?) -> Void) {
            self.mark = mark
            self.until = mark.at + wait
            self.pasteboard = pasteboard
            self.then = then
        }

        @MainActor static func start(_ mark: CopyMark, wait: TimeInterval = 0.6, pasteboard: NSPasteboard = .general,
                                     then: @escaping @MainActor (String?) -> Void) {
            let watch = CopyWatch(mark, wait: wait, pasteboard: pasteboard, then: then)
            watch.monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
                watch.lock.withLock { watch.heard = true }
            }
            queue.async { watch.tick() }
        }

        /// The person typed or clicked since the press: what the monitor heard, and the hardware's own times, which
        /// also cover the moment before the monitor was installed (never Petal's posted keys).
        private func input() -> Bool {
            if lock.withLock({ heard }) { return true }
            let since = ProcessInfo.processInfo.systemUptime - mark.at
            return [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains {
                CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) < since
            }
        }

        private func tick() {
            let now = pasteboard.changeCount
            let late = ProcessInfo.processInfo.systemUptime >= until
            switch UIMap.copyWatch(start: mark.count, now: now, input: input()) {
            case .leave: return finish(nil)
            case .wait: return late ? finish(nil) : again()
            case .look:
                let types = pasteboard.types ?? []
                // Counted but not written yet: the copy's contents are still coming.
                if types.isEmpty { return late ? finish(nil) : again() }
                // Too long to check counts as unsafe too: a "Copy all" of a big log may hold a saved secret.
                let secret = Assist.isConcealed(pasteboard)
                    || pasteboard.string(forType: .string).map { Assist.vaultCheck($0) != .clean } == true
                if UIMap.clearsCopy(start: mark.count, seen: now, now: pasteboard.changeCount, input: input(), secret: secret) {
                    pasteboard.clearContents()
                    return finish(Self.cleared)
                }
                finish(nil)
            }
        }

        private func again() {
            Self.queue.asyncAfter(deadline: .now() + 0.05) { self.tick() }
        }

        private func finish(_ why: String?) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let monitor = self.monitor { NSEvent.removeMonitor(monitor) }
                    self.monitor = nil
                    self.then(why)
                }
            }
        }
    }

    static func perform(_ action: String, entry: ComputerUse.Entry?, map: ComputerUse.Map, prepared: Prepared, options: Options,
                        cancel: Cancel, stayBehind: Bool = false) -> Outcome {
        var outcome = Outcome()
        let pid = map.pid
        let element = entry?.element
        let name = entry.map { UIMap.name($0.node) }.flatMap { $0.isEmpty ? nil : "“\($0)”" } ?? "That control"
        let cameForward = "\(map.appName) came to the front to take the keys."
        func say(_ note: String) { outcome.note = outcome.note.map { $0 + " " + note } ?? note }
        // `stayBehind`: a sticky note's act, decided while its window was in front. Should the person leave it while
        // this runs, nothing is brought forward for the note: it stops there and says the window must be in front.
        func behind() -> Bool { stayBehind && !(isFront(pid) && windowInFront(map)) }
        // Every change goes through the gate: a Stop, and for a note the person typing there again or gone elsewhere,
        // read right before the change with nothing read in between (Background.Gate). What the act needs to read
        // (where the keyboard is, the window, the clipboard) comes before it.
        let gate = changeGate(map, cancel: cancel, note: stayBehind)
        // How much of a `type` went, for what the AI is told if it's interrupted.
        var sent = 0
        // On a Stop the outcome goes back as it is: ComputerUse.done tells the chat it was stopped. A refused gate
        // returns at once; what the person did is said below.
        func act() {
            switch action {
            case "press":
                guard let element else { break }
                // A Copy, Cut or Paste button gets the same checks as the keys and menu items, in its window, in front.
                let fresh = Reader.node(element)
                let clip = UIMap.clip(control: fresh) ?? entry.flatMap({ UIMap.clip(control: $0.node) })
                if let clip {
                    if behind() { outcome.needs = .clipboard; return }
                    if let error = bringWindow(map, cancel: cancel, stayBehind: stayBehind) {
                        if cancel.stopped { return }
                        if stayBehind { outcome.needs = .clipboard; return }
                        outcome.error = error
                        break
                    }
                    if let why = clipboardRefusal(map, nil, clip: clip) {
                        outcome.error = why
                        break
                    }
                }
                // And whatever might paste, never while a secret is on the clipboard, nor into a password field.
                if UIMap.mightPaste(fresh) || entry.map({ UIMap.mightPaste($0.node) }) == true,
                   let why = pasteRefusal() ?? secretFieldRefusal(map, nil, pasting: true) {
                    outcome.error = why
                    break
                }
                // A Copy or Cut button (or one whose names mention copying: "Click to copy API key") copies what it's for,
                // not what has the keyboard: never in a window showing a secret.
                let copies = clip == .copy || UIMap.mightCopy(fresh) || entry.map({ UIMap.mightCopy($0.node) }) == true
                if copies, let why = copyButtonRefusal(map) {
                    outcome.error = why
                    break
                }
                // And should a secret reach the clipboard anyway, it's cleared (CopyWatch, after the reply's press): only
                // the change count now, never what the clipboard holds.
                let actions = Reader.actions(element)
                if let done = ["AXPress", "AXPick", "AXConfirm", "AXOpen"].first(where: actions.contains) {
                    let mark = copies ? CopyMark.now() : nil
                    guard let pressed = gate.mutate({ AXUIElementPerformAction(element, done as CFString) }) else { return }
                    if pressed == .success {
                        outcome.copied = mark
                        break
                    }
                }
                if ["AXRow", "AXCell", "AXTab", "AXRadioButton"].contains(entry?.node.role ?? "") {
                    let mark = copies ? CopyMark.now() : nil
                    guard let picked = gate.mutate({ AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) }) else { return }
                    if picked == .success {
                        outcome.copied = mark
                        break
                    }
                }
                outcome.error = "\(name) can't be pressed through Accessibility. Only a real click would do it, and Petal never moves the person's pointer: ask them to click it, or try a menu item or a key."
            case "focus":
                guard let element else { break }
                guard let focused = gate.mutate({ AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }) else { return }
                if focused != .success {
                    guard let selected = gate.mutate({ AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) }) else { return }
                    if selected != .success {
                        outcome.error = "\(name) can't take the focus through Accessibility."
                    }
                }
            case "type":
                guard let element, let node = entry?.node else { break }
                switch Assist.vaultCheck(options.text) {
                case .secret: outcome.error = "That's one of the vault's secrets: petal_vault fills it (action: fill)."
                case .tooLong: outcome.error = tooMuch("type")
                case .unreadable: outcome.error = vaultUnreadable("type")
                case .clean: break
                }
                if outcome.error != nil { break }
                // A note in its window in front went ahead because the person was idle there. The gate before every
                // change (the value, the focus, ⌘A, each batch of keys, Return) stops it should they start typing there
                // again (or leave that window): it says how much went, and never presses Return after it.
                var typed = false
                // A native field takes its new value directly; a web page's needs keys, so its page hears them.
                if !node.web, UIMap.isText(node) {
                    switch insert(options.text, into: element, replace: options.replace, cancel: cancel, gate: gate) {
                    case .done:
                        typed = true
                        sent = options.text.utf16.count
                    case .unsure:
                        // Never typed a second time: it may be there already.
                        typed = true
                        say("Petal may not have typed it (the field didn't say what it holds now): call petal_ui to see \(name) before typing again.")
                    case .no: break
                    case .stopped: return
                    }
                }
                // Keys (the text, or Return) go wherever the keyboard is: only once it's this field, never a password field.
                var submit = options.submit
                if !typed || submit {
                    let unsent = "It was typed, not sent: \(map.appName)'s window went behind before Return, and Petal doesn't bring it forward for a note. Press its send button with petal_act instead."
                    if behind() {
                        guard typed else { outcome.needs = .keys; return }
                        say(unsent)
                        submit = false
                    } else if !isFront(pid) {
                        if bringForward(pid, cancel: cancel, stayBehind: stayBehind) {
                            if !stayBehind { say(cameForward) }
                        } else if cancel.stopped || !stayBehind {
                            return
                        } else {
                            // A note's window went behind between the reads: bringForward refused, nothing came forward.
                            guard typed else { outcome.needs = .keys; return }
                            say(unsent)
                            submit = false
                        }
                    }
                }
                if !typed || submit {
                    if let error = focus(element, pid: pid, name: name, cancel: cancel, gate: gate) {
                        if cancel.stopped || gate.refused { return }
                        outcome.error = error
                        break
                    }
                }
                if !typed {
                    // Never ⌘A over a whole document: only once the keyboard is in this field.
                    if options.replace, let all = UIMap.parseKey("cmd-a") {
                        guard keysGoTo(element, pid: pid) else { outcome.error = "The cursor left \(name); nothing was typed."; break }
                        guard gate.mutate({ post(all, to: pid, cancel: cancel) }) == true else { return }
                    }
                    let went = type(options.text, to: pid, cancel: cancel, still: { keysGoTo(element, pid: pid) }, gate: gate,
                                    progress: { sent = $0 })
                    guard went else {
                        if cancel.stopped || gate.refused { return }
                        outcome.error = "The cursor left \(name) while typing, so Petal stopped there. Call petal_ui to see what was typed."
                        break
                    }
                }
                // Return: where the keyboard is is read first, then the gate and the key together.
                if submit, let enter = UIMap.parseKey("return") {
                    guard keysGoTo(element, pid: pid) else { outcome.error = "The cursor left \(name) before Return: it was typed, not sent."; break }
                    guard gate.mutate({ post(enter, to: pid, cancel: cancel) }) == true else { return }
                }
                usleep(120_000)
                let now = Reader.text(Windows.value(element, kAXValueAttribute) as CFTypeRef?, whole: true)
                if !now.isEmpty, !submit {
                    outcome.value = UIMap.typedValue(now, node: node, filled: Sensitive.isFilled(element, pid: pid), secret: Assist.isVaultSecret)
                }
            case "fill":
                guard let element, let plan = options.fill else { break }
                if behind() { outcome.needs = .vault; return }
                if let error = VaultFiller.fill(plan, into: element, map: map, cancel: cancel, stayBehind: stayBehind, gate: gate) {
                    if cancel.stopped { return }
                    outcome.error = error
                }
            case "scroll":
                guard let element else { break }
                if options.direction.isEmpty {
                    guard let scrolled = gate.mutate({ AXUIElementPerformAction(element, "AXScrollToVisible" as CFString) }) else { return }
                    if scrolled != .success {
                        outcome.error = "\(name) can't be scrolled into view through Accessibility; give a direction instead."
                    }
                } else if let error = scroll(element, options.direction, cancel: cancel, gate: gate) {
                    outcome.error = error
                }
            case "menu":
                guard let item = prepared.menuItem else { break }
                // A menu command acts on its app's front window: that must be the one petal_ui looked at.
                if behind() { outcome.needs = .menu; return }
                if let error = bringWindow(map, cancel: cancel, stayBehind: stayBehind) {
                    if cancel.stopped { return }
                    if stayBehind { outcome.needs = .menu; return }
                    outcome.error = error
                    break
                }
                // Right before it: what a copy takes, in this window now, what a paste puts in, and where. The item is known
                // by its shortcut first, so a menu in any language counts.
                if let why = clipboardRefusal(map, nil, clip: clip(key: nil, item: item, title: prepared.menuTitle)) {
                    outcome.error = why
                    break
                }
                guard let chosen = gate.mutate({ AXUIElementPerformAction(item, kAXPressAction as CFString) }) else { return }
                if chosen != .success {
                    outcome.error = "Couldn't choose \(prepared.menuTitle ?? "that item"); its app didn't answer."
                }
                outcome.chose = prepared.menuTitle
            case "key":
                guard let key = options.key else { break }
                if behind() { outcome.needs = .keys; return }
                if let error = bringWindow(map, cancel: cancel, stayBehind: stayBehind) {
                    if cancel.stopped { return }
                    if stayBehind { outcome.needs = .keys; return }
                    outcome.error = error
                    break
                }
                if let element {
                    if let error = focus(element, pid: pid, name: name, cancel: cancel, gate: gate) {
                        if cancel.stopped || gate.refused { return }
                        outcome.error = error
                        break
                    }
                }
                // A shortcut its menus have is chosen there (any app, in front or not); otherwise the key itself. Either
                // way, right before it: what a copy takes, in this window now, what a paste puts in, and where.
                let clipping = clip(key: key, item: prepared.menuItem, title: prepared.menuTitle)
                if let item = prepared.menuItem {
                    if let why = clipboardRefusal(map, element, clip: clipping) {
                        outcome.error = why
                        break
                    }
                    guard let chosen = gate.mutate({ AXUIElementPerformAction(item, kAXPressAction as CFString) }) else { return }
                    if chosen == .success {
                        outcome.chose = prepared.menuTitle
                        break
                    }
                }
                if behind() { outcome.needs = .keys; return }
                if !isFront(pid) {
                    guard bringForward(pid, cancel: cancel, stayBehind: stayBehind) else {
                        if !cancel.stopped, stayBehind { outcome.needs = .keys }
                        return
                    }
                    say(cameForward)
                }
                // Right before the key: still that control (or still that window, and no password field), or it isn't sent.
                if let element {
                    guard keysGoTo(element, pid: pid) else { outcome.error = "The cursor left \(name); the key wasn't sent."; break }
                } else {
                    guard windowInFront(map) else { outcome.error = "That window isn't in front anymore; the key wasn't sent."; break }
                    if let why = secretFieldRefusal(map, nil, pasting: false) { outcome.error = why; break }
                }
                if let why = clipboardRefusal(map, element, clip: clipping) {
                    outcome.error = why
                    break
                }
                guard gate.mutate({ post(key, to: pid, cancel: cancel) }) == true else { return }
            default: break
            }
        }
        act()
        // The person came back to type in that window, or left it, right before a change: nothing more was done. Gone
        // before anything changed, it's decided again (the background way); otherwise the AI is told how far it got.
        if !cancel.stopped, let why = gate.interruption {
            if why == .left, !gate.changed {
                outcome = Outcome()
                outcome.again = true
            } else if action == "type" {
                let typed = String(decoding: Array(options.text.utf16.prefix(sent)), as: UTF16.self)
                outcome.error = Background.interrupted(why, app: map.appName, typed: typed, of: options.text)
            } else if outcome.error == nil {
                outcome.error = Background.stopped(why, app: map.appName, changed: gate.changed)
            }
            return outcome
        }
        // Petal's own change (text, caret, focus, scroll) becomes what's expected next, so its next step isn't taken
        // for someone else's.
        if outcome.error == nil, outcome.needs == nil, !cancel.stopped, ["type", "focus", "scroll", "key", "fill"].contains(action) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            outcome.fingerprint = Reader.fingerprint(app: app, window: map.window, lists: map.lists)
        }
        return outcome
    }

    // MARK: Putting text in

    enum Insertion { case done, unsure, no, stopped }

    /// Sets a native field's text through Accessibility (`replace`: its whole value; else at the cursor, over what's
    /// selected), then reads back what changed: `done` when the text is there, `no` when nothing changed (keys may
    /// type it), `unsure` when it can't tell, which is never typed again. `stopped`: the gate refused it (a Stop, or the
    /// person), nothing set; its reads all come before the gate, and the value is set right after it.
    static func insert(_ text: String, into element: AXUIElement, replace: Bool, cancel: Cancel, gate: Background.Gate) -> Insertion {
        let attribute = replace ? kAXValueAttribute : kAXSelectedTextAttribute
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success, settable.boolValue else { return .no }
        // Where it goes and what was there, to read back just what was put in (never a truncated copy).
        let before: String? = Windows.value(element, kAXValueAttribute)
        let count = characters(element)
        let selection = selectedRange(element)
        guard let set = gate.mutate({ AXUIElementSetAttributeValue(element, attribute as CFString, text as CFString) }) else { return .stopped }
        guard set == .success else { return .no }
        let after: String? = Windows.value(element, kAXValueAttribute)
        if replace {
            guard let after else { return .unsure }
            // Only the whole value as asked is done: the old text merely holding it ("Send the invoice today" for
            // "Send the invoice") isn't.
            switch Background.typed(before: before ?? "", after: after, text: text, replace: true) {
            case .done: return .done
            case .ignored: return before == nil ? .unsure : .no
            case .uncertain: return .unsure
            }
        }
        // The whole value known before and after: it must be exactly what was before the selection, the text, and
        // what followed it (Background.typed), never only the text somewhere in it.
        if let before, let after, let selection {
            switch Background.typed(before: before, after: after, text: text, replace: false,
                                    at: selection.location, replaced: selection.length) {
            case .done: return .done
            case .ignored: return .no
            case .uncertain: return .unsure
            }
        }
        let length = text.utf16.count
        if let selection, let there = string(element, CFRange(location: selection.location, length: length)) {
            if there == text { return .done }
        }
        guard let count, let now = characters(element) else { return after != nil && after == before ? .no : .unsure }
        let replaced = selection?.length ?? 0
        if now == count && replaced == 0 && after == before { return .no }
        if selection != nil, now - count == length - replaced, length != replaced { return .done }
        return .unsure
    }

    /// How many characters a text control holds (its whole text, not what Petal reads of it).
    static func characters(_ element: AXUIElement) -> Int? {
        if let count: Int = Windows.value(element, kAXNumberOfCharactersAttribute) { return count }
        return (Windows.value(element, kAXValueAttribute) as String?)?.utf16.count
    }

    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success, let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(raw as! AXValue, .cfRange, &range) ? range : nil
    }

    /// The text at `range`, through the control's own reading of ranges.
    static func string(_ element: AXUIElement, _ range: CFRange) -> String? {
        var range = range
        guard range.location >= 0, let value = AXValueCreate(.cfRange, &range) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, value, &raw) == .success else { return nil }
        return raw as? String
    }

    /// Whether the app is in front (through Accessibility, off the main thread): an error or a timeout is
    /// `unknown`, never "behind".
    static func frontState(_ pid: pid_t) -> Background.Known {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &raw) == .success,
              let front = raw as? Bool else { return .unknown }
        return front ? .yes : .no
    }

    /// The app is in front, for certain.
    static func isFront(_ pid: pid_t) -> Bool { frontState(pid) == .yes }

    /// The app is behind, for certain (unknown is neither).
    static func isBehind(_ pid: pid_t) -> Bool { frontState(pid) == .no }

    // MARK: Focus

    static func isSecure(_ element: AXUIElement) -> Bool {
        (Windows.value(element, kAXSubroleAttribute) as String?) == "AXSecureTextField"
    }

    static func focusedIsSecure(_ app: AXUIElement) -> Bool {
        guard let focused: AXUIElement = Windows.value(app, kAXFocusedUIElementAttribute) else { return false }
        return isSecure(focused)
    }

    /// Gives `element` the keyboard and reads it back from its app: nil once keys sent now land there (and it isn't a
    /// password field), else why they can't go. The focus is set right after the gate (`gate.refused`: nothing set).
    static func focus(_ element: AXUIElement, pid: pid_t, name: String, cancel: Cancel, gate: Background.Gate) -> String? {
        if isSecure(element) { return password }
        let refused = "Couldn't put the cursor in \(name) through Accessibility; only a real click would. Ask the person to click into it."
        guard let set = gate.mutate({ AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }) else {
            return ComputerUse.stoppedText
        }
        guard set == .success else { return refused }
        for attempt in 0..<3 {
            if keysGoTo(element, pid: pid) { return nil }
            if attempt < 2 { usleep(60_000) }
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        return focusedIsSecure(app) ? "A password field has the cursor: Petal doesn't type there." : refused
    }

    /// What has the app's keyboard is `element` (or inside it), and isn't a password field.
    static func keysGoTo(_ element: AXUIElement, pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let focused: AXUIElement = Windows.value(app, kAXFocusedUIElementAttribute), !isSecure(focused) else { return false }
        var current: AXUIElement? = focused
        for _ in 0..<4 {
            guard let at = current else { return false }
            if CFEqual(at, element) { return true }
            current = Windows.value(at, kAXParentAttribute)
        }
        return false
    }

    /// The window petal_ui looked at is its app's front window: menus and keys act there, never on another.
    static func windowInFront(_ map: ComputerUse.Map) -> Bool { windowState(map) == .yes }

    /// Whether the window petal_ui looked at is its app's front window: its focused window, else (none focused) its
    /// main one. A read that failed or timed out is `unknown`, never "another window".
    static func windowState(_ map: ComputerUse.Map) -> Background.Known {
        let app = AXUIElementCreateApplication(map.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        switch focusedWindow(app) {
        case .window(let focused): return isWindow(focused, of: map) ? .yes : .no
        case .unknown: return .unknown
        case .none:
            var raw: CFTypeRef?
            switch AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &raw) {
            case .success:
                guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return .unknown }
                return isWindow((raw as! AXUIElement), of: map) ? .yes : .no
            case .noValue, .attributeUnsupported: return .no
            default: return .unknown
            }
        }
    }

    enum FocusedWindow { case window(AXUIElement), none, unknown }

    /// The app's focused window: none when it says it has none, unknown when the read failed or timed out.
    static func focusedWindow(_ app: AXUIElement) -> FocusedWindow {
        var raw: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &raw) {
        case .success:
            guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return .unknown }
            return .window(raw as! AXUIElement)
        case .noValue, .attributeUnsupported: return .none
        default: return .unknown
        }
    }

    /// `other` is the window petal_ui looked at.
    static func isWindow(_ other: AXUIElement?, of map: ComputerUse.Map) -> Bool {
        guard let other else { return false }
        if CFEqual(other, map.window) { return true }
        if let id = map.windowID, let otherID = Windows.id(of: other) { return id == otherID }
        return false
    }

    /// Brings the window petal_ui looked at to the front of its app if it isn't (the pointer stays), and checks
    /// again: nil once it's there, else why not. `stayBehind` (a sticky note's act): never raises anything; nil only
    /// while its app is in front with that window its focused one, else it refuses with nothing done.
    static func bringWindow(_ map: ComputerUse.Map, cancel: Cancel, stayBehind: Bool = false) -> String? {
        if stayBehind {
            return isFront(map.pid) && windowInFront(map) ? nil : Background.Reason.menu.words(map.appName)
        }
        if windowInFront(map) { return nil }
        guard !cancel.stopped else { return ComputerUse.stoppedText }
        AXUIElementPerformAction(map.window, kAXRaiseAction as CFString)
        guard !cancel.stopped else { return ComputerUse.stoppedText }
        AXUIElementSetAttributeValue(map.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        for _ in 0..<3 {
            usleep(80_000)
            if windowInFront(map) { return nil }
        }
        return "That window isn't in front in \(map.appName), so nothing was sent to it. Bring it forward first (petal_windows), then try again."
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

    /// One key, down and up, to the app's own process: the person's keyboard and pointer aren't involved. False,
    /// and nothing sent, once stopped.
    @discardableResult
    static func post(_ key: UIMap.Key, to pid: pid_t, cancel: Cancel) -> Bool {
        guard !cancel.stopped else { return false }
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
        return true
    }

    /// Text as keystrokes to the app's process, a few characters at a time: before each batch, `still`'s reads (the
    /// keyboard still in the field), then the gate and the batch at once (Background.send). False when stopped,
    /// interrupted or moved part way.
    static func type(_ text: String, to pid: pid_t, cancel: Cancel, still: () -> Bool, gate: Background.Gate,
                     progress: (Int) -> Void = { _ in }) -> Bool {
        let source = CGEventSource(stateID: .privateState)
        var sent = 0
        return Background.send(UIMap.batches(text), still: { !cancel.stopped && still() }, gate: gate) { chunk in
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                chunk.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                event?.postToPid(pid)
            }
            sent += chunk.count
            progress(sent)
            usleep(8_000)
        }
    }

    /// The gate every act's changes go through: a Stop, and for a note acting in its window in front (`note`), the
    /// person typing there again or gone elsewhere, read just now; the Stop sampled last, after those reads
    /// (Background.check).
    static func changeGate(_ map: ComputerUse.Map, cancel: Cancel, note: Bool) -> Background.Gate {
        Background.Gate {
            note ? Background.check(stopped: { cancel.stopped }, note: { situation(map) })
                : Background.check(stopped: { cancel.stopped }, read: { nil })
        }
    }

    /// Keys only reach the app in front: this one comes forward first (through Accessibility; the pointer stays).
    /// False, and nothing done, once stopped. `stayBehind` (a sticky note's act): never activates anything; true
    /// only while the app is already in front, else false with nothing done.
    static func bringForward(_ pid: pid_t, cancel: Cancel, stayBehind: Bool = false) -> Bool {
        guard !cancel.stopped else { return false }
        if stayBehind { return isFront(pid) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        usleep(150_000)
        return !cancel.stopped
    }

    // MARK: Scrolling

    /// Moves the scroll area around `element` (or it) by most of a page, through its scroll bar's value.
    /// Each change right after the gate (refused: nil, nothing changed; the caller reads `gate.refused`).
    static func scroll(_ element: AXUIElement, _ direction: String, cancel: Cancel, gate: Background.Gate) -> String? {
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
        let canSet = AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        // On a Stop (or the person back), nothing more: ComputerUse.done says why.
        if canSet {
            guard let set = gate.mutate({ AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: next)) }) else { return nil }
            if set == .success { return nil }
        }
        let action = direction == "down" || direction == "right" ? kAXIncrementAction : kAXDecrementAction
        guard let stepped = gate.mutate({ AXUIElementPerformAction(bar, action as CFString) }) else { return nil }
        if stepped == .success { return nil }
        return "That area can't be scrolled through Accessibility; only the person's own scrolling would do it."
    }
}


// MARK: - The fake cursor

/// Petal AI's own pointer: a soft arrow in Petal's pink (or the person's `pointerColor`) over everything, letting every click through, on every Space. It
/// glides to each control before the action, with a small ripple on a press, and a glass chip saying what it's
/// doing with Stop beside it. The pointer fades a few seconds after the last action; while the AI may still act
/// (`stand`), the chip stays as a small Stop and Escape keeps stopping it. Core Animation moves it; the main thread
/// only sets where it goes.
@MainActor
final class FakeCursor {
    /// The pointer's color: the person's own (`pointerColor`, #rrggbb), else Petal's pink.
    static var tint: NSColor {
        NSColor(hex: PetalApp.shared.config.string("pointerColor")) ?? NSColor(red: 0xd9 / 255, green: 0x36 / 255, blue: 0x7f / 255, alpha: 1)
    }
    static let glide: TimeInterval = 0.35
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))

    var onStop: (() -> Void)?
    private var panel: NSPanel?
    private var pill: GlassPanel?
    private let pointer = CALayer()
    /// The color the pointer's layers were last drawn in.
    private var drawn: NSColor?
    private var fade: DispatchWorkItem?
    private var monitors: [Any] = []
    /// The pointer is on the screen.
    private(set) var showing = false
    /// The AI may act now (ComputerUse.standGuard): Stop and Escape stay, between actions too.
    private(set) var standing = false
    /// The chip (with Stop) is on the screen, and where it was put last.
    private var pillShown = false
    private var pillPlace: (point: CGPoint, screen: NSScreen)?

    /// The AI may act (or no longer may): Escape listens and the small Stop stays only while it may. Told again
    /// at every change, so Stop comes back after another reply's ended while this one may still act.
    func stand(_ on: Bool) {
        standing = on
        if on {
            if !pillShown, !showing, let place = pillPlace { showPill(nil, at: place.point, on: place.screen) }
        } else if !showing {
            hidePill()
        }
        listening()
    }

    /// An action was let go ahead: Stop shows straight away, before Petal reads the window, where it was or by
    /// `point` (AppKit's screen coordinates).
    func preparing(_ caption: String, near point: CGPoint) {
        fade?.cancel()
        showPill(caption, at: point, on: Self.screen(at: point))
    }

    /// Glides to `point` (AppKit's screen coordinates) and says what it's doing.
    func glide(to point: CGPoint, caption: String) {
        fade?.cancel()
        let screen = Self.screen(at: point)
        let panel = self.panel ?? make()
        var fresh = !showing
        // A color chosen since it was last drawn shows the next time the pointer comes out.
        if fresh, drawn != Self.tint {
            Self.build(pointer, scale: screen.backingScaleFactor)
            drawn = Self.tint
        }
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
        }
        // The chip follows once the cursor is there.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.glide) { [weak self] in
            guard let self, self.showing else { return }
            self.showPill(caption, at: point, on: screen)
        }
    }

    private static func screen(at point: CGPoint) -> NSScreen {
        Screens.all.first { $0.frame.contains(point) } ?? Screens.main ?? Screens.all[0]
    }

    /// A small ripple at the tip: a press.
    func press() {
        guard showing else { return }
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -16, y: -16, width: 32, height: 32), transform: nil)
        ring.fillColor = Self.tint.withAlphaComponent(0.16).cgColor
        ring.strokeColor = Self.tint.withAlphaComponent(0.9).cgColor
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

    /// The last action is done (or didn't go ahead): the pointer fades a few seconds later, unless another comes.
    func rest() {
        fade?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    /// Gone at once (Stop). Another reply that may still act brings Stop back (`stand`).
    func hide() {
        fade?.cancel()
        fade = nil
        hidePill()
        listening()
        guard showing else { return }
        showing = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.opacity = 0
        CATransaction.commit()
        panel?.orderOut(nil)
    }

    /// The pointer fades; Stop stays, small, while the AI may still act.
    private func fadeOut() {
        if standing {
            if let place = pillPlace { showPill(nil, at: place.point, on: place.screen) }
        } else {
            hidePill()
        }
        guard showing else { return }
        showing = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.listening()
                guard !self.showing else { return }
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

    /// `caption` nil: the small Stop between actions.
    private func showPill(_ caption: String?, at point: CGPoint, on screen: NSScreen) {
        let pill = self.pill ?? {
            let made = GlassPanel(level: NSWindow.Level(rawValue: Self.level.rawValue + 1))
            made.collectionBehavior.insert(.fullScreenAuxiliary)
            self.pill = made
            return made
        }()
        pill.show(ActingPill(caption: caption) { [weak self] in self?.onStop?() }, near: point, on: screen)
        pillShown = true
        pillPlace = (point, screen)
        listening()
    }

    private func hidePill() {
        if pillShown { pill?.hide() }
        pillShown = false
        listening()
    }

    /// Escape listens only while a reply may act (`standing`), whatever the pointer is doing: told at every change of
    /// it, when the pointer is hidden and when its fade ends, so Escape in Petal's own chat is never kept after.
    private func listening() {
        if standing { listen() } else { unlisten() }
    }

    /// Escape stops it, wherever the keyboard is. Another app's Escape still reaches it (a global monitor only
    /// hears); in Petal's own windows Escape is taken only while a reply may act, and goes on as usual otherwise.
    private func listen() {
        guard monitors.isEmpty else { return }
        let escape: (NSEvent) -> Bool = { [weak self] event in
            guard event.keyCode == 53 else { return false }
            return MainActor.assumeIsolated {
                guard let self, self.standing else { return false }
                self.onStop?()
                return true
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = escape($0) }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { escape($0) ? nil : $0 }) { monitors.append(local) }
    }

    private func unlisten() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func make() -> NSPanel {
        let screen = Screens.main ?? Screens.all[0]
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
        drawn = Self.tint
        pointer.opacity = 0
        view.layer?.addSublayer(pointer)
        self.panel = panel
        return panel
    }

    /// The pointer's layers: an arrow in its color with a white edge and a soft glow of the same, its tip at (0, 0).
    /// Drawn again, it replaces what was there.
    static func build(_ pointer: CALayer, scale: CGFloat) {
        let color = tint
        pointer.sublayers = nil
        pointer.bounds = .zero
        pointer.anchorPoint = .zero
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: -19), CGPoint(x: 4.8, y: -14.6), CGPoint(x: 8, y: -21.6),
                                CGPoint(x: 11.4, y: -20.1), CGPoint(x: 8.3, y: -13.4), CGPoint(x: 14.4, y: -13.4)])
        path.closeSubpath()
        let glow = CAShapeLayer()
        glow.path = path
        glow.fillColor = color.withAlphaComponent(0.55).cgColor
        glow.shadowColor = color.cgColor
        glow.shadowOpacity = 0.9
        glow.shadowRadius = 9
        glow.shadowOffset = .zero
        let arrow = CAShapeLayer()
        arrow.path = path
        arrow.fillColor = color.cgColor
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

/// The glass chip by the fake cursor: what Petal AI is doing, and Stop (or Escape). Between actions (no caption)
/// it's only the dot and Stop, for as long as Petal AI may still use the person's apps.
struct ActingPill: View {
    let caption: String?
    let stop: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(Color(nsColor: FakeCursor.tint)).frame(width: 7, height: 7)
            if let caption {
                Text(caption).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading).fixedSize()
            }
            Button(action: stop) {
                HStack(spacing: 5) {
                    Text("Stop").font(.system(size: 12, weight: .semibold))
                    Text("esc").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(hovering ? .clear.tint(Color(nsColor: FakeCursor.tint)).interactive() : .clear.interactive(), in: .capsule)
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
