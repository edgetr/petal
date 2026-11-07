import AppKit
import Observation
import SwiftUI

extension NotePlace {
    /// The app a note looks at: its window's (still the same app), or for an app's note that app, wherever it is.
    @MainActor var running: NSRunningApplication? {
        if kind == .app { return Self.running(app) }
        return NSRunningApplication(processIdentifier: pid).flatMap { $0.bundleIdentifier == app && !$0.isTerminated ? $0 : nil }
    }

    /// One app running with that bundle id (the one in front first), from the list NSWorkspace keeps up to date as
    /// apps open and quit: never a question to Launch Services on the main thread.
    @MainActor static func running(_ bundleID: String) -> NSRunningApplication? {
        guard !bundleID.isEmpty else { return nil }
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundleID, !front.isTerminated { return front }
        return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID && !$0.isTerminated }
    }

    /// As it may be kept or shown: a private app's (`aiNeverLook`) without its titles and addresses.
    @MainActor var sanitized: NotePlace { PetalApp.shared.assist.neverLook(app) ? scrubbed : self }

    /// The window it looks at: its own, or (an app's note) nil, its app's focused one.
    var lookWindow: CGWindowID? { kind == .app ? nil : window }
}

/// One AI sticky note: a chat stuck to the window that was in front when it was opened. Each has its own chat
/// process, so several work at once, and what they look at is their own window, wherever the person has gone since.
@MainActor @Observable
final class StickyNote {
    let agent = Agent()
    var id: UUID { agent.noteID }
    var draft = ""
    var attachments: [URL] = []
    var quotes: [ClaudePanel.Quote] = []
    /// Done while the person was somewhere else: its app's icon (and its mode, if another) has a nudge.
    var ready = false
    /// Open when the person went to another window: it comes back with its window.
    @ObservationIgnored var away = false
    /// Its window closed or its app quit: it opens as a plain chat.
    @ObservationIgnored var windowGone = false

    var place: NotePlace? {
        get { agent.place }
        set { agent.place = newValue }
    }

    /// Stuck to a window that's still there.
    var attached: Bool { place != nil && !windowGone }
}

extension ClaudePanel {
    enum CloseReason { case purpose, stepAway }

    /// No more than this many notes work at once; the next waits for one to finish.
    static let atOnce = 4

    var notesOn: Bool { PetalApp.shared.config.bool("aiNotes") }

    var working: Int { notes.filter { $0.agent.running }.count }

    func note(withID id: String) -> StickyNote? { notes.first { $0.id.uuidString == id } }

    /// The note holding a kept chat, if one does: a chat is only ever carried on by one note.
    func live(chat id: UUID) -> StickyNote? { notes.first { $0.agent.chatID == id } }

    // MARK: Which note

    /// The note for what's in front: the most specific one stuck there (its tab's, its window's, its app's), one kept
    /// from before (Petal or the browser restarted), or a new one, stuck to the tab in a browser Petal may read and
    /// to the window elsewhere. The window and tab are looked up off the main thread (Accessibility and AppleScript
    /// may wait on the app).
    func noteForFront(again: Bool = true, _ done: @escaping @MainActor (StickyNote) -> Void) {
        let me = ProcessInfo.processInfo.processIdentifier
        guard notesOn, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me,
              front.activationPolicy == .regular else { return done(looseNote) }
        let pid = front.processIdentifier
        Self.readFront(of: front) { read in
            guard self.notesOn else { return done(self.looseNote) }
            // Another app came forward while its window was looked up: that one's, looked up once more.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                return again ? self.noteForFront(again: false, done) : done(self.looseNote)
            }
            done(self.note(for: front, self.saw(front, read), title: read.title))
        }
    }

    /// The one chat stuck to no window: kept, so closing and opening again (or turning notes off) never loses it.
    var looseNote: StickyNote {
        if !notes.contains(where: { $0 === loose }) { notes.append(loose) }
        return loose
    }

    /// What's in front, as just read, remembered.
    @discardableResult
    func saw(_ running: NSRunningApplication, _ read: FrontRead) -> FrontPlace {
        let front = read.place(running.processIdentifier, app: running.bundleIdentifier ?? "")
        lastFront = front
        let primary = NSScreen.screens.first?.frame.height ?? 0
        lastFrontFrame = read.frame.map { NoteRules.appKitFrame($0, primaryHeight: primary) }
        return front
    }

    /// The notes stuck to what's in front. A tab's note whose window closed or browser quit counts too: its tab
    /// (dragged to another window, or back after the browser restarted) takes it back (`adopt`). Notes told apart
    /// from each other only by a guess (NoteRules.fitting), here or with a chat kept from before, are neither shown
    /// nor moved: the same candidates as opening the AI there (`note(for:)`).
    private func fitting(_ front: FrontPlace) -> [StickyNote] {
        let (found, candidates) = gathered
        return NoteRules.fitting(candidates, front).compactMap { index in
            if case .live(let note) = found[index] { return note }
            return nil
        }
    }

    /// A note here, or a chat kept from before Petal (or the browser) last started.
    enum Found { case live(StickyNote), kept(SavedChat) }

    /// The notes here that can fit what's in front (stuck to a window that's there, or a tab's, whose tab may come
    /// back), then the chats kept from before, with their places for NoteRules (which keeps one per chat: a note here
    /// over a kept copy of its chat).
    private var gathered: (found: [Found], candidates: [NoteCandidate]) {
        var found: [Found] = []
        var candidates: [NoteCandidate] = []
        for note in notes {
            guard let place = note.place, note.attached || place.kind == .tab else { continue }
            found.append(.live(note))
            candidates.append(NoteCandidate(place: place, chat: note.agent.chatID, live: true))
        }
        for (_, chat) in savedPlaces.sorted(by: { $0.key < $1.key }) {
            guard let place = chat.place else { continue }
            found.append(.kept(chat))
            candidates.append(NoteCandidate(place: place, chat: chat.id, live: false))
        }
        return (found, candidates)
    }

    /// Tab notes whose window closed or browser quit, and chats kept for tabs, of `bundle` (nil: any browser): their
    /// tabs may come back (another window, or the browser restarted), so Petal keeps looking when it comes forward.
    func recoverableTabs(_ bundle: String?) -> Bool {
        notes.contains { $0.windowGone && $0.place?.kind == .tab && (bundle == nil || $0.place?.app == bundle) }
            || savedPlaces.values.contains { $0.place?.kind == .tab && (bundle == nil || $0.place?.app == bundle) }
    }

    private func note(for app: NSRunningApplication, _ front: FrontPlace, title: String) -> StickyNote {
        // An app kept private: its window's title isn't kept or told (and its tabs aren't read).
        let title = PetalApp.shared.assist.neverLook(app.bundleIdentifier) ? "" : title
        // The notes here and the chats kept from before Petal (or the browser) last started, together: the most
        // specific wins (a tab's kept chat over a window's note); between equals, a note here.
        // Told apart together: a note here and a kept chat that fit the same tab only by a guess are neither taken.
        let (all, candidates) = gathered
        let found = NoteRules.pick(NoteRules.fitting(candidates, front).map { all[$0] },
                                   scope: { found in
                                       switch found {
                                       case .live(let note): note.place?.kind ?? .window
                                       case .kept(let chat): chat.place?.kind ?? .window
                                       }
                                   },
                                   showing: { found in
                                       if case .live(let note) = found { return self.isOpen && note === self.current }
                                       return false
                                   })
        if case .live(let note)? = found {
            adopt(note, front, title: title)
            return note
        }
        let petal = PetalApp.shared
        let dock = petal.docks.focusedDock
        // A tab Petal can't tell from the others (Safari's only tab, with no tab strip): its window's note instead.
        let tab = front.tab?.known == true ? front.tab : nil
        var place = NotePlace(pid: front.pid, app: front.app, appName: app.localizedName ?? "", window: front.window, title: title,
                              mode: dock?.mode?.id ?? "", desktop: dock?.desktop, scope: tab == nil ? .window : .tab, tab: tab)
        // A chat kept for this tab, window or app from before Petal (or the browser) last started, carried on: by
        // the note that already holds it (picked from the list since), or a new one.
        if case .kept(let saved)? = found {
            // Every link to the chat goes: the note is it now.
            savedPlaces = savedPlaces.filter { $0.value.id != saved.id }
            if let old = saved.place {
                place.scope = old.scope
                place.spot = old.spot
                if let tab = old.tab { place.tab = front.tab.map { NoteRules.follow(tab, to: $0, keepWords: !title.isEmpty) } ?? tab }
                if title.isEmpty { place.title = old.title }
                place.mode = old.mode
                place.desktop = old.desktop ?? place.desktop
            }
            // A note holding the chat already (picked from the list since, maybe carried on) wins over the copy kept
            // for the window: it moves to the window as it is, never replaced by an older copy.
            if let note = live(chat: saved.id) {
                if note === loose {
                    // The loose chat goes with it; a new, empty one is the loose chat from now on.
                    let fresh = StickyNote()
                    notes.append(fresh)
                    loose = fresh
                }
                return attach(note, place)
            }
            let note = StickyNote()
            note.agent.restore(saved, switchProvider: false)
            notes.append(note)
            return attach(note, place)
        }
        // Which window is in front isn't known (no Accessibility, or an app slow to answer): a new note there could
        // never be found again, so it's the plain chat instead.
        if front.unread { return looseNote }
        return attach(StickyNote(), place)
    }

    /// A note found on what's in front follows it: an app's note to the window in front (and the app's new process
    /// after it restarted), a tab's note to its tab's new address, window and place. A private app's titles and
    /// addresses are never kept.
    private func adopt(_ note: StickyNote, _ front: FrontPlace, title: String) {
        guard var place = note.place else { return }
        if note.windowGone, place.kind == .tab {
            // Its tab is back (in another window, or after its browser restarted): the same chat carries on.
            note.windowGone = false
            listenIfNeeded()
        }
        let quiet = PetalApp.shared.assist.neverLook(place.app)
        switch place.kind {
        case .app:
            place.pid = front.pid
            place.window = front.window
        case .tab:
            place.pid = front.pid
            place.window = front.window
            if let tab = place.tab, let now = front.tab { place.tab = NoteRules.follow(tab, to: now, keepWords: !quiet) }
        case .window:
            break
        }
        if !title.isEmpty, !quiet { place.title = title }
        if place != note.place { note.place = place }
    }

    private func attach(_ note: StickyNote, _ place: NotePlace) -> StickyNote {
        note.place = place
        note.windowGone = false
        if !notes.contains(where: { $0 === note }) { notes.append(note) }
        prune(sparing: note)   // the note being opened is never let go before it shows
        listenIfNeeded()
        return note
    }

    // MARK: What it's stuck to

    /// The tab the note in the panel could stick to: the one showing in its window now, else its own.
    var tabForCurrent: NoteTab? {
        guard let place = current.place, Browsers.kind(place.app) != nil, !PetalApp.shared.assist.neverLook(place.app) else { return nil }
        if let front = lastFront, NoteRules.sameWindow(place, front) { return front.tab?.known == true ? front.tab : nil }
        return place.tab
    }

    /// The chip: the note in the panel sticks to its tab, its window, or all of its app from now on.
    func stick(to scope: NoteScope) {
        let note = current
        guard var place = note.place, place.kind != scope else { return }
        let front = lastFront.flatMap { NoteRules.sameWindow(place, $0) ? $0 : nil }
        stickTicket += 1
        let mine = stickTicket
        switch scope {
        case .tab:
            // The tab showing in its window now, read again (the one Petal saw last may be another by now), and only
            // then stuck to; a choice made meanwhile wins.
            guard tabForCurrent != nil, let running = place.running else { return }
            let kind = place.kind
            Self.readFront(of: running) { read in
                let pid = running.processIdentifier
                guard mine == self.stickTicket, self.current === note, var now = note.place, now.kind == kind, let tab = read.tab, tab.known,
                      NoteRules.sameWindow(now, read.place(pid, app: now.app)) else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { self.saw(running, read) }
                now.tab = tab
                now.pid = pid
                if let window = read.window { now.window = window }
                now.scope = .tab
                note.place = now
                self.listenIfNeeded()
            }
            return
        case .window:
            // An app's note sticks to the window it's on now.
            if let front, front.window != nil { place.pid = front.pid; place.window = front.window }
            guard place.window != nil else { return }
        case .app:
            guard !place.app.isEmpty else { return }
        }
        place.scope = scope
        note.place = place
        listenIfNeeded()
    }

    // MARK: Where it sits

    /// Where the note in the panel sits, once the person moved it: on its window, as they left it. nil (over the
    /// dock) until then, or while it isn't on its own window (opened here from another mode).
    func stuckFrame(_ size: CGSize) -> CGRect? {
        guard notesOn, current.attached, let place = current.place, let spot = place.spot, let front = lastFront,
              let window = lastFrontFrame, NoteRules.sameWindow(place, front) else { return nil }
        let screens = NSScreen.screens
        guard let screen = NoteRules.screen(for: window, in: screens.map(\.frame)),
              let visible = screens.first(where: { $0.frame == screen })?.visibleFrame else { return nil }
        return spot.frame(size: size, window: window, screen: visible)
    }

    /// The note in the panel stays when the person clicks elsewhere in its place: they stuck it there.
    var stuckHere: Bool {
        guard notesOn, current.attached, let place = current.place, place.spot != nil, let front = lastFront else { return false }
        return NoteRules.sameWindow(place, front, orUnknown: true)
    }

    /// The person let go of the note after dragging it: it sticks there, on its window (its nearest corner).
    func noteMoved(to frame: CGRect) {
        let note = current
        guard notesOn, note.attached, let place = note.place, let front = lastFront, NoteRules.sameWindow(place, front),
              let number = front.window else { return }
        Self.windowFrame(pid: front.pid, window: number) { found in
            guard let found, self.current === note, self.lastFront == front else { return }
            let window = NoteRules.appKitFrame(found, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
            self.lastFrontFrame = window
            note.place?.spot = NoteSpot.stick(panel: frame, window: window)
        }
    }

    /// The window the open note sits on moved or resized: the note goes with it. Its frame is read off the main
    /// thread; a move meanwhile reads it once more when that's done, never a queue of reads.
    private func follow(_ element: AXUIElement, window number: CGWindowID) {
        guard !following else { followAgain = true; return }
        following = true
        // Accessibility's elements may be asked from any thread; Swift can't know that.
        nonisolated(unsafe) let moving = element
        Self.windowQueue.async {
            let frame = Windows.frame(of: moving)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.following = false
                    if let frame, self.lastFront?.window == number {
                        self.lastFrontFrame = NoteRules.appKitFrame(frame, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
                        if self.isOpen { self.fit() }
                    }
                    if self.followAgain {
                        self.followAgain = false
                        self.follow(moving, window: number)
                    }
                }
            }
        }
    }

    /// A chat picked from the list: the note holding it, else carried on. With notes on, it sticks again to its
    /// window (or tab, or app) if that's still there; with them off (or its window gone), it's the loose chat.
    func restoreNote(_ chat: SavedChat) {
        cancelPending()
        // The chat being left stops using the person's apps, and its question waiting is answered Don't: it never
        // carries on (or asks) behind the chat picked. The one picked, when it's the same, carries on.
        if live(chat: chat.id) !== current { PetalApp.shared.assist.computer.end(current.id.uuidString) }
        // Its link to its window (savedPlaces) stays until the note sticks there again: till then, opening the AI
        // there finds the note holding the chat (and once stuck, the link goes: one chat, one note).
        guard notesOn else {
            // With notes off the loose chat is the chat: it becomes the one holding this one (stuck to no window).
            if let note = live(chat: chat.id) {
                note.place = nil
                note.windowGone = false
                loose = note
            } else if loose.agent.running {
                let note = StickyNote()
                note.agent.restore(chat)
                notes.append(note)
                loose = note
            } else {
                loose.agent.restore(chat)
            }
            present(looseNote)
            return prune()
        }
        if let note = live(chat: chat.id) { return present(note) }
        let note = StickyNote()
        note.agent.restore(chat)
        notes.append(note)
        guard let place = chat.place?.sanitized,
              !notes.contains(where: { $0.attached && $0.place.map(NoteRules.key) == NoteRules.key(place) })
        else { present(note); return prune() }
        // An app's note sticks to its app again, open or not: it shows on whichever of its windows is in front.
        if place.kind == .app, !place.app.isEmpty {
            _ = attach(note, place)
            unlink(chat.id)
            present(note)
            return prune()
        }
        // A Chromium tab's chat: its tab, by its id, may be in another window by now (dragged out, or its window
        // closed with the tab moved first); only the browser can say, so it's asked (AppleScript) before Accessibility.
        let tabID = place.kind == .tab && Browsers.kind(place.app) == .chromium ? place.tab?.id : nil
        guard place.window != nil || tabID != nil, NSRunningApplication(processIdentifier: place.pid)?.bundleIdentifier == place.app
        else { present(note); return prune() }
        let window = place.window ?? 0
        let ticket = pendingTicket
        restoreTicket += 1
        let mine = restoreTicket
        // Apps made private while its window is looked up: it doesn't stick with what was read before.
        let privacy = Self.privacy.now
        let chatID = chat.id
        (tabID == nil ? Self.windowQueue : Self.tabQueue).async {
            let tab = tabID.flatMap { Browsers.tabWindow(id: $0, bundleID: place.app) }
            Self.windowQueue.async {
                let windows = Windows.windows(of: place.pid)
                var found = place
                let there: Bool?
                if let tab {
                    there = tab.found
                    // Its window now: the one with its bounds (its old one if that's it); when that's unsure, none,
                    // learned once its tab is in front.
                    let old = windows.first { $0.id == "\(place.pid)-w\(window)" }
                    if let bounds = tab.bounds {
                        let alike = windows.filter { NoteRules.sameFrame($0.frame, bounds) }
                        if old.map({ o in alike.contains { $0.id == o.id } }) != true {
                            found.window = alike.count == 1 ? Windows.id(of: alike[0].element) : nil
                        }
                    } else if old == nil {
                        found.window = nil
                    }
                } else {
                    let open = windows.contains { $0.id == "\(place.pid)-w\(window)" }
                    // The browser couldn't be asked about a Chromium tab: its window gone says nothing of its tab.
                    there = open || tabID == nil ? open : nil
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Another chat picked since: this one doesn't stick (it keeps its window in its saves and the
                        // window's link to it).
                        guard mine == self.restoreTicket else { return self.prune() }
                        if there == true && self.notesOn && Self.privacy.current(privacy) {
                            // Its window or tab is there: it's the note for it from now on, so the copy kept for it goes
                            // (two copies of one chat would make its tab unsure). As it may be kept: sanitized now.
                            _ = self.attach(note, found.sanitized)
                            self.unlink(chatID)
                        } else if there == false {
                            note.agent.keptPlace = nil
                        }
                        // Shown only if the panel wasn't closed (any way) or something else opened meanwhile; else
                        // it stays stuck to its window, quietly.
                        if ticket == self.pendingTicket { self.present(note) }
                        self.prune()
                    }
                }
            }
        }
    }

    /// The links kept from windows, tabs and apps to a chat a note here now holds, stuck where they were: the note is it.
    private func unlink(_ chat: UUID) {
        savedPlaces = savedPlaces.filter { $0.value.id != chat }
        listenIfNeeded()
    }

    /// Notes nobody can come back to (their window gone, or stuck to none: chats read from the list) are let go,
    /// and past 30 idle ones the oldest too. All are kept in Chats; one whose window is still open is found again
    /// when that window opens the AI, and a tab's after its browser restarts, by its address.
    func prune(sparing spared: StickyNote? = nil) {
        let keep = { (note: StickyNote) in
            note === spared || note === self.current || note === self.loose || note.agent.running || note.ready || !note.agent.waiting.isEmpty
        }
        // A window's link to a chat let go here holds the chat as it is now, never an older copy.
        for note in notes where !keep(note) {
            guard let chat = note.agent.saved else { continue }
            for (key, value) in savedPlaces where value.id == chat.id { savedPlaces[key] = chat }
        }
        var gone = notes.filter { !keep($0) && ($0.windowGone || $0.place == nil) }
        notes.removeAll { !keep($0) && ($0.windowGone || $0.place == nil) }
        // A tab's note whose browser quit (or window closed) can be found again by its tab's address.
        for note in gone where note.place?.kind == .tab {
            if let place = note.place, let chat = note.agent.saved { savedPlaces[NoteRules.key(place)] = chat }
        }
        let idle = notes.filter { !keep($0) && $0.attached }
        for old in idle.dropLast(30) {
            if let place = old.place, place.kind != .window || place.window != nil, let chat = old.agent.saved {
                savedPlaces[NoteRules.key(place)] = chat
            }
            notes.removeAll { $0 === old }
            gone.append(old)
        }
        // A note let go takes its window's ids and what it was allowed in apps with it.
        for note in gone { PetalApp.shared.assist.computer.end(note.id.uuidString, forget: true) }
        listenIfNeeded()
    }

    /// Where notes do their Accessibility work (looking up and bringing forward windows), never the main thread.
    nonisolated static let windowQueue = DispatchQueue(label: "petal.notes.windows", qos: .userInitiated)
    /// Where a browser is asked which tab it shows (AppleScript can take a while): never the main thread, and never
    /// holding up a window being brought forward.
    nonisolated static let tabQueue = DispatchQueue(label: "petal.notes.tabs", qos: .userInitiated)

    /// What's in front in an app: its focused window's number, title and frame (Accessibility's, top-left origin),
    /// and in a browser Petal may read (not a private one) its active tab.
    struct FrontRead: Sendable {
        var window: CGWindowID?
        /// The app said it has no window in front (as Finder on the desktop): not a window Petal couldn't read.
        var none = false
        var title = ""
        var frame: CGRect?
        var tab: NoteTab?

        func place(_ pid: pid_t, app: String) -> FrontPlace {
            FrontPlace(pid: pid, app: app, window: window, tab: tab, none: window == nil && none)
        }
    }

    /// Bumped when the apps kept private change: a tab read under way for an app made private meanwhile is dropped.
    nonisolated static let privacy = Generation()

    /// Reads what's in front in an app, off the main thread. The browser's tab is read from its front window, the
    /// window from Accessibility: the tab counts only when the same window is in front before and after it's read
    /// (once more if not, else no tab). An app made private meanwhile has nothing of its tab or title kept.
    static func readFront(of running: NSRunningApplication, _ done: @escaping @MainActor (FrontRead) -> Void) {
        let pid = running.processIdentifier
        let bundle = running.bundleIdentifier ?? ""
        let tabs = Browsers.kind(bundle) != nil && !PetalApp.shared.assist.neverLook(bundle)
        let privacy = Self.privacy.now
        let finish: @Sendable (FrontRead) -> Void = { read in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var read = read
                    // Checked again as it's used, on the main thread where the setting changes.
                    if !Self.privacy.current(privacy) { read.tab = nil }
                    if PetalApp.shared.assist.neverLook(bundle) { read.tab = nil; read.title = "" }
                    done(read)
                }
            }
        }
        windowQueue.async {
            let seen = focusedWindow(pid)
            guard tabs else { return finish(seen) }
            tabQueue.async {
                var read = seen
                for _ in 0..<2 {
                    guard Self.privacy.current(privacy) else { read.tab = nil; break }
                    let tab = Browsers.activeTab(pid: pid, bundleID: bundle)
                    let after = focusedWindow(pid)
                    if after.window == read.window, after.none == read.none {
                        read = after
                        read.tab = tab
                        break
                    }
                    // Another window came forward while the tab was read: the tab may be either's.
                    read = after
                    read.tab = nil
                }
                finish(read)
            }
        }
    }

    /// For a note stuck to a tab: the tab its window shows now, when that's the note's own tab (with the window's
    /// number), else nil: another tab shows, or Petal can't tell (no answer, no window, not allowed to ask). A tab
    /// note's AI reads and acts only on its own tab (NoteRules.sameTab: its id, or its button in the tab strip),
    /// never on whichever tab its window shows by then. Asks Accessibility and the browser: never on the main thread.
    nonisolated static func tabShowing(_ place: NotePlace) -> (tab: NoteTab, window: CGWindowID)? {
        guard place.kind == .tab, place.tab != nil, Windows.trusted else { return nil }
        let app = AXUIElementCreateApplication(place.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let element: AXUIElement?
        if let number = place.window {
            let all: [AXUIElement] = Windows.value(app, kAXWindowsAttribute) ?? []
            element = all.first { Windows.id(of: $0) == number }
        } else {
            element = Windows.value(app, kAXFocusedWindowAttribute)
        }
        guard let element, let number = Windows.id(of: element), let frame = Windows.frame(of: element) else { return nil }
        let window = Browsers.Window(number: number, title: Windows.value(element, kAXTitleAttribute) ?? "", frame: frame)
        guard let now = Browsers.shownTab(pid: place.pid, bundleID: place.app, window: window, element: element) else { return nil }
        let front = FrontPlace(pid: place.pid, app: place.app, window: number, tab: now)
        return NoteRules.fits(place, front) ? (now, number) : nil
    }

    /// What a tab note's AI hears when its tab isn't the one showing in its window.
    nonisolated static let tabNotShowing = "Your note's tab isn't showing in its window now (another tab is, or Petal can't tell which), so Petal won't read or use it: it never works on another tab. Ask the person to switch back to that tab; front: true uses what's in front instead."

    /// A tab note's tab was just seen showing in its window (its AI read or used it there): the note follows it (a new
    /// address, place or window), as when Petal sees it in front. Only while the note is still stuck where it was
    /// checked; a private app's words are never kept.
    func tabSeen(note id: String, was place: NotePlace, tab: NoteTab, window: CGWindowID) {
        let quiet = PetalApp.shared.assist.neverLook(place.app)
        guard let note = note(withID: id), note.place == place, var next = note.place, let old = next.tab else { return }
        next.tab = NoteRules.follow(old, to: tab, keepWords: !quiet)
        next.window = window
        if next != note.place { note.place = next }
    }

    /// An app's focused window: its number, title and frame; or that it has none (it answered so, rather than not
    /// answering). Off the main thread.
    nonisolated private static func focusedWindow(_ pid: pid_t) -> FrontRead {
        var read = FrontRead()
        guard Windows.trusted else { return read }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var raw: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &raw) {
        case .success:
            guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
            let window = raw as! AXUIElement
            read.window = Windows.id(of: window)
            read.title = Windows.value(window, kAXTitleAttribute) ?? ""
            read.frame = Windows.frame(of: window)
        case .noValue:
            read.none = true
        default:
            break
        }
        return read
    }

    /// One window's frame now (Accessibility's, top-left origin), when it's its app's focused one; off the main thread.
    static func windowFrame(pid: pid_t, window number: CGWindowID, _ done: @escaping @MainActor (CGRect?) -> Void) {
        windowQueue.async {
            var frame: CGRect?
            if Windows.trusted {
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.3)
                if let window: AXUIElement = Windows.value(element, kAXFocusedWindowAttribute), Windows.id(of: window) == number {
                    frame = Windows.frame(of: window)
                }
            }
            let found = frame
            DispatchQueue.main.async { MainActor.assumeIsolated { done(found) } }
        }
    }

    // MARK: Following the windows

    /// Starts watching which app is in front (only while notes are stuck to windows does it look further), and reads
    /// the kept chats once, so a window, tab or app that had a note before Petal started gets it back.
    func startNotes() {
        privateApps = PetalApp.shared.config.strings("aiNeverLook")
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let running { self?.appCameForward(running) } }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let pid = running?.processIdentifier else { return }
                // An app's note waits for its app to open again; a window's and a tab's are gone with it.
                for note in self.notes where note.place?.pid == pid && note.place?.kind != .app { note.windowGone = true }
                self.updateReady()
                self.listenIfNeeded()   // a quit browser's tab notes keep it heard, for when it opens again
            }
        }
        Chats.list { [weak self] chats in
            var found: [String: SavedChat] = [:]
            for var chat in chats {
                chat.place = chat.place?.sanitized
                guard let place = chat.place else { continue }
                switch place.kind {
                case .window:
                    // A window lasts only as long as its app.
                    guard place.window != nil, NSRunningApplication(processIdentifier: place.pid)?.bundleIdentifier == place.app else { continue }
                case .tab:
                    // A tab is found again by its address after its browser restarts.
                    guard place.tab != nil else { continue }
                case .app:
                    guard !place.app.isEmpty else { continue }
                }
                let key = NoteRules.key(place)
                if found[key] == nil { found[key] = chat }   // newest first
            }
            // Chats already carried on by a note since Petal started stay with it.
            self?.savedPlaces = found.filter { self?.live(chat: $0.value.id) == nil }
            self?.listenIfNeeded()
        }
    }

    /// `aiNotes` changed (or any setting did): with notes off, nothing listens, nudges or takes the app's click.
    func notesSettingChanged() {
        let hidden = PetalApp.shared.config.strings("aiNeverLook")
        if hidden != privateApps {
            // Apps made private: tab reads under way are dropped, and the tab last seen is forgotten.
            privateApps = hidden
            Self.privacy.cancel()
            if let front = lastFront, PetalApp.shared.assist.neverLook(front.app) { lastFront?.tab = nil }
            forgetPrivateWords()
        }
        listenIfNeeded()
        guard !notesOn else { return }
        cancelPending()   // a note's window being brought forward (or a mode's countdown before it) opens nothing
        // The chat showing becomes the loose chat, stuck to no window: from now on it looks at what's in front.
        if current !== loose, current.place != nil, isOpen {
            current.place = nil
            current.windowGone = false
            loose = current
        }
        guard notes.contains(where: { $0.ready || $0.away }) else { return }
        for note in notes { note.ready = false; note.away = false }
        updateReady()
        if PetalApp.shared.popups.card?.kind == .noteReady { PetalApp.shared.popups.dismissCard() }
    }

    /// An app was made private: what its windows and tabs said (titles, addresses) goes from every note, the chats
    /// kept for windows, and the chats in the list, so it's neither shown nor saved again.
    private func forgetPrivateWords() {
        for note in notes {
            if let place = note.place, place.sanitized != place { note.place = place.sanitized }   // saved again by its chat
            if let kept = note.agent.keptPlace { note.agent.keptPlace = kept.sanitized }
        }
        var linked: [String: SavedChat] = [:]
        for (key, chat) in savedPlaces {
            var chat = chat
            chat.place = chat.place?.sanitized
            linked[chat.place.map(NoteRules.key) ?? key] = chat
        }
        savedPlaces = linked
        // The chats in the list: a note's own chat as it is now (newer than the copy read here), the rest as read.
        Chats.list { [weak self] chats in
            guard let self else { return }
            for chat in chats {
                guard let place = chat.place, place.sanitized != place else { continue }
                if let note = self.live(chat: chat.id) {
                    if let now = note.agent.saved, now.id == chat.id { Chats.save(now) }
                } else {
                    var clean = chat
                    clean.place = place.sanitized
                    Chats.save(clean)
                }
            }
        }
    }

    /// Window events (focus moving between an app's windows, a window closing, moving or resizing, and a browser
    /// window's title changing or another tab being selected), heard only while a note is stuck somewhere or a tab's
    /// may come back: no watching loop, only what Petal's Accessibility observers already say.
    func listenIfNeeded() {
        let tabs = notes.contains { $0.attached && $0.place?.kind == .tab } || recoverableTabs(nil)
        let wanted = notesOn && (notes.contains { $0.attached } || tabs)
        WindowEvents.shared.titles("notes", wanted && tabs)
        guard wanted != listening else { return }
        listening = wanted
        if wanted {
            WindowEvents.shared.listen("notes") { [weak self] event in self?.windowEvent(event) }
        } else {
            WindowEvents.shared.stopListening("notes")
        }
    }

    private func windowEvent(_ event: WindowEvents.Event) {
        switch event.kind {
        case .focused:
            // Another window of the app in front.
            guard notesOn, let front = NSWorkspace.shared.frontmostApplication, event.pid == front.processIdentifier else { return }
            look(at: front)
        case .titleChanged, .tabSwitched:
            // A browser's window shows another tab (or its tab another page; two tabs alike change no title, but
            // selecting one moves the keyboard or the tab strip's selection): looked at again once it settles.
            guard notesOn, let front = NSWorkspace.shared.frontmostApplication, event.pid == front.processIdentifier,
                  let bundle = front.bundleIdentifier, Browsers.kind(bundle) != nil, event.window == nil || event.window == lastFront?.window,
                  notes.contains(where: { $0.attached && $0.place?.kind == .tab && $0.place?.app == bundle }) || recoverableTabs(bundle)
            else { return }
            lookSoon(at: front.processIdentifier)
        case .moved, .resized:
            // The open note's window: the note goes with it, where the person left it.
            guard isOpen, current.place?.spot != nil, let element = event.element, let window = event.window,
                  let front = lastFront, front.pid == event.pid, front.window == window, stuckHere else { return }
            follow(element, window: window)
        case .closed:
            guard let window = event.window else { return }
            for note in notes where note.place?.window == window && note.place?.kind != .app { note.windowGone = true }
            updateReady()
            listenIfNeeded()
        default:
            break
        }
    }

    private func appCameForward(_ running: NSRunningApplication) {
        let pid = running.processIdentifier
        // Another app came forward while a note's window was being brought: its retries stop now.
        if let bringing, pid != bringing, pid != ProcessInfo.processInfo.processIdentifier {
            self.bringing = nil
            NoteFocus.cancel()
        }
        // Also a browser whose tabs may take back a note (it quit with them, or they're kept from before).
        guard notesOn, pid != ProcessInfo.processInfo.processIdentifier,
              notes.contains(where: { $0.attached }) || running.bundleIdentifier.map(recoverableTabs) == true else { return }
        look(at: running)
    }

    /// Reads what's in front in `running` (its window, and its tab) and shows its notes. Only the newest look counts.
    private func look(at running: NSRunningApplication) {
        let pid = running.processIdentifier
        looks += 1
        let mine = looks
        Self.readFront(of: running) { read in
            guard mine == self.looks, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.frontChanged(self.saw(running, read), title: read.title)
        }
    }

    /// Which window of the app in front is focused couldn't be read: looked at again, a little later each time, at
    /// most three times while it stays unknown (a focus event or another app coming forward looks anyway).
    private func lookWhileUnknown(_ pid: pid_t) {
        guard unknownLooks.pid == pid, unknownLooks.count < 3 else { return }
        unknownLooks.count += 1
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == pid else { return }
                self.look(at: front)
            }
        }
        lookAgain?.cancel()
        lookAgain = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(unknownLooks.count), execute: item)
    }

    /// A browser's title changes several times as a tab switches or loads: one look once it settles.
    private func lookSoon(at pid: pid_t) {
        lookAgain?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == pid else { return }
                self.look(at: front)
            }
        }
        lookAgain = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    /// Something else is in front (another app, window or tab): an open note stuck elsewhere steps away; the note
    /// stuck here that was open when the person left or is done comes back (without taking the keyboard from the
    /// app), where they left it. When several fit (a tab's, its window's, its app's), the most specific shows.
    private func frontChanged(_ front: FrontPlace, title: String) {
        if let pending = pendingOpen, let place = pending.place {
            // A tab's note: its own tab in front (a browser that couldn't be asked to show it waits for the person to).
            let there = place.kind == .tab ? NoteRules.fits(place, front) : NoteRules.sameWindow(place, front)
            if pending.windowGone ? place.pid == front.pid : there {
                pendingOpen = nil
                // Its window is in front: no more retries (they'd fight a switch the person makes next).
                bringing = nil
                NoteFocus.cancel()
                // After the app has finished coming forward, so its window taking focus doesn't close the note; and
                // only if nothing else was opened meanwhile and the window is still in front.
                let ticket = pendingTicket
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard ticket == self.pendingTicket, self.inFront(place), place.kind != .tab || self.lastFront == front else { return }
                    self.present(pending, key: true, fromIcon: true)
                }
                return
            }
            // The person went to another app meanwhile.
            if front.pid != place.pid && !(place.kind == .app && place.app == front.app) { cancelPending() }
        }
        let here = fitting(front)
        let quiet = PetalApp.shared.assist.neverLook(front.app)
        for note in here { adopt(note, front, title: quiet ? "" : title) }
        if !front.unread || unknownLooks.pid != front.pid { unknownLooks = (front.pid, 0) }
        // Its app is in front but not which window (one still opening, an app slow to answer): it may be
        // another window of the app, so the open note steps away (kept to come back, never as if closed), and nothing
        // takes its place. It shows again only once its own window is seen in front: the window's focus event looks
        // again, and so does Petal, a few times, in case none comes.
        var unknown = false
        if isOpen, current.attached, !here.contains(where: { $0 === current }) {
            unknown = current.place.map { NoteRules.windowUnknown($0, front) } ?? false
            stepAway()
        }
        if front.unread, notes.contains(where: { $0.attached && $0.away && $0.place.map { NoteRules.windowUnknown($0, front) } == true }) {
            lookWhileUnknown(front.pid)
        }
        if unknown { return }
        // The loose chat open stays: a note never takes its place by itself.
        if isOpen && !current.attached { return }
        let shown: StickyNote? = isOpen ? current : nil
        let waiting = here.filter { $0.away || $0.ready || $0 === shown }
        guard let best = NoteRules.pick(waiting, scope: { $0.place?.kind ?? .window }, showing: { $0 === shown }) else { return }
        if best === shown {
            // Still its place: an app's note goes to the window now in front, a moved one stays where it was left.
            fit()
            return
        }
        // A more specific note takes the panel; the one showing comes back where it fits.
        shown?.away = true
        present(best, key: false, fromIcon: true)
    }

    /// The note's window (any of its app's, for an app's note) is the one in front, as far as Petal has heard: for
    /// showing it, only once that window is known. `orUnknown`: also its app in front with its window not known yet,
    /// for putting a note away (never for showing one).
    private func inFront(_ place: NotePlace, orUnknown: Bool = false) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if place.kind == .app { return !place.app.isEmpty && app.bundleIdentifier == place.app }
        guard app.processIdentifier == place.pid else { return false }
        guard let front = lastFront else { return orUnknown }
        return NoteRules.sameWindow(place, front, orUnknown: orUnknown)
    }

    /// A note waiting for its window to come forward isn't opened after all (nor its window brought forward again).
    func cancelPending() {
        pendingOpen = nil
        pendingTicket += 1
        bringing = nil
        NoteFocus.cancel()
    }

    /// A chat deleted from the list stays deleted: no window brings it back, and a note holding it starts afresh.
    func forget(_ chat: SavedChat) {
        unlink(chat.id)
        for note in notes where note.agent.chatID == chat.id {
            note.agent.reset()
            note.ready = false
            note.away = false
            if PetalApp.shared.popups.card?.noteID == note.id { PetalApp.shared.popups.dismissCard() }
        }
        updateReady()
    }

    /// A chat was saved: a window's link to it holds it as it is now.
    func chatSaved(_ chat: SavedChat) {
        for (key, value) in savedPlaces where value.id == chat.id { savedPlaces[key] = chat }
    }

    private func stepAway() {
        closeReason = .stepAway
        close()
    }

    /// The panel closed: on purpose (×, Escape, the AI button), stepping away, or a click elsewhere. A click
    /// elsewhere in the note's own window puts it away (one the person moved stays: InputPanel.stays); going to
    /// another window, it comes back with this one.
    func closed() {
        // However it closed, nothing opens it again behind the person's back: opens, restores and windows being
        // brought forward are cancelled.
        cancelPending()
        let reason = closeReason
        closeReason = nil
        let note = current
        switch reason {
        case .purpose?: note.away = false
        case .stepAway?: note.away = true
        case nil:
            guard notesOn, note.attached else { note.away = false; return }
            note.away = true
            let ticket = pendingTicket
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard !self.isOpen || self.current !== note, let place = note.place, self.inFront(place, orUnknown: true) else { return }
                guard place.kind == .tab, let running = NSWorkspace.shared.frontmostApplication else { note.away = false; return }
                // A tab's note only when its own tab still shows, read again now: the click may have been on another
                // tab, and then the note comes back with its tab. Anything opened or closed meanwhile wins.
                let pid = running.processIdentifier
                Self.readFront(of: running) { read in
                    guard ticket == self.pendingTicket, !self.isOpen || self.current !== note,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let place = note.place, place.kind == .tab
                    else { return }
                    if NoteRules.fits(place, read.place(pid, app: running.bundleIdentifier ?? "")) { note.away = false }
                }
            }
        }
    }

    // MARK: Done while away

    /// A note's turn ended. If the person isn't looking at it, its app's icon gets a nudge (a badge and one bounce),
    /// and a note from another mode nudges that mode's button too, with a card to open it here.
    func finished(_ note: StickyNote) {
        startWaiting()
        guard notesOn, !(isOpen && current === note), note.agent.messages.contains(where: { $0.kind == .user }) else { return }
        note.ready = true
        updateReady()
        guard let place = note.place else { return }
        let app = PetalApp.shared
        if !place.app.isEmpty { app.signals.bounce(place.app) }
        let here = app.docks.focusedDock?.mode?.id
        if !place.mode.isEmpty, place.mode != here, let mode = app.config.modes.first(where: { $0.id == place.mode }),
           app.popups.card == nil, !isOpen {
            app.popups.show(FocusCard(kind: .noteReady, bundleID: place.app, title: note.agent.title, target: mode,
                                      reason: place.title.isEmpty ? place.appName : place.title, noteID: note.id))
        }
    }

    /// Notes waiting for room start, in order, while fewer than `atOnce` work. Called whenever a run ends or is
    /// ended (a new chat, a chat picked from the list).
    func startWaiting() {
        for note in notes where !note.agent.waiting.isEmpty && working < Self.atOnce { note.agent.runWaiting() }
    }

    func updateReady() {
        let ready = notes.filter { $0.ready }
        let apps = Set(ready.compactMap { $0.place?.app }.filter { !$0.isEmpty })
        var modes: [String: Int] = [:]
        for note in ready { if let mode = note.place?.mode, !mode.isEmpty { modes[mode, default: 0] += 1 } }
        if apps != readyApps { readyApps = apps }
        if modes != readyModes { readyModes = modes }
    }

    /// The app's icon was clicked and one of its notes is done: its window comes forward (in its mode) and the note
    /// opens on it. False when no note of that app is waiting (or notes are off): the click does what it always does.
    func openReady(app bundleID: String) -> Bool {
        guard notesOn, let note = notes.first(where: { $0.ready && $0.place?.app == bundleID }), let place = note.place else { return false }
        go(to: note, place: place)
        return true
    }

    /// Brings a note's window forward and opens the note on it. When the Desktop the note was asked on has left the
    /// note's mode, that Desktop (not the one showing) goes back to it first.
    func go(to note: StickyNote, place: NotePlace) {
        let app = PetalApp.shared
        app.popups.dismissCard()
        if isOpen { close() }   // first: its closing cancels what's pending, never this
        cancelPending()
        // An app's note: whichever of its app's windows; a window's or a tab's: its own window's app.
        let running = place.kind == .app
            ? NotePlace.running(place.app)
            : NSRunningApplication(processIdentifier: place.pid).flatMap { $0.isTerminated ? nil : $0 }
        guard !note.windowGone, let running else { return present(note, key: true) }
        let pid = running.processIdentifier
        // Taken now, before any mode's countdown: anything opened, closed or turned off meanwhile cancels it.
        let ticket = pendingTicket
        let bring = {
            guard ticket == self.pendingTicket, self.notesOn else { return }
            // Its window is in front already (and, for a tab's note, its tab): nothing to wait for.
            if self.inFront(place), place.kind != .tab || self.lastFront.map({ NoteRules.fits(place, $0) }) == true {
                return self.present(note, key: true, fromIcon: true)
            }
            self.pendingOpen = note
            // If the window never says it's in front (another Desktop, a slow app), it's asked once more; the note
            // opens only when its window really is in front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard ticket == self.pendingTicket, self.pendingOpen === note else { return }
                self.pendingOpen = nil
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                Self.readFront(of: running) { read in
                    guard ticket == self.pendingTicket, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    let seen = self.saw(running, read)
                    // A tab's note only on its tab: the browser may not have shown it (or couldn't tell which it is);
                    // it stays done (its nudge too) until its tab shows.
                    let now = note.place ?? place
                    guard now.kind == .tab ? NoteRules.fits(now, seen) : NoteRules.sameWindow(now, seen)
                    else { return }
                    self.present(note, key: true, fromIcon: true)
                }
            }
            self.bringing = pid
            // Numbered now: closing, another app coming forward or another bringing stops both the tab's switch and
            // the window's.
            let request = NoteFocus.next()
            // A tab's note: its tab shows first (Chromium browsers by its id; Safari, Firefox and Zen by its button).
            if place.kind == .tab, let tab = place.tab {
                let app = place.app, window = place.window
                Self.tabQueue.async {
                    // Its tab closed while its window stayed open (only a closed window says so by itself): the
                    // note opens as a plain chat, and its nudge goes, instead of waiting for a tab that won't show.
                    guard Browsers.select(tab, bundleID: app, window: window, still: { NoteFocus.current(request) }) == .missing
                    else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard ticket == self.pendingTicket, NoteFocus.current(request), !(self.isOpen && self.current === note) else { return }
                            self.cancelPending()
                            note.windowGone = true
                            self.present(note, key: true)
                            self.listenIfNeeded()
                        }
                    }
                }
            }
            Self.bringForward(pid: pid, window: place.kind == .app ? nil : place.window, app: running.bundleURL, request: request)
        }
        let desktop = place.desktop ?? app.docks.focusedDock?.desktop
        if let desktop, !place.mode.isEmpty, app.config.modes.contains(where: { $0.id == place.mode }),
           app.config.mode(forDesktop: desktop)?.id != place.mode {
            app.requestMode(place.mode, desktop: desktop, then: bring)
        } else {
            bring()
        }
    }

    /// Brings one window forward, all of it on `windowQueue` (Accessibility and Launch Services may wait on the
    /// app): unminimized, raised, its app in front; through Launch Services when it isn't on the screen (another
    /// Desktop, which macOS then switches to). The pointer stays where it is.
    nonisolated static func bringForward(pid: pid_t, window number: CGWindowID?, app url: URL?, request: Int) {
        // A newer request, or a cancel, stops this one at once, even while it waits on the app.
        windowQueue.async {
            guard NoteFocus.current(request) else { return }
            let element = Windows.windows(of: pid).first { $0.id == "\(pid)-w\(number ?? 0)" }?.element
            let raise = {
                guard let element, NoteFocus.current(request) else { return }
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            let launch = {
                guard let url, NoteFocus.current(request) else { return }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.addsToRecentItems = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
            var minimized = false
            if let element {
                minimized = Windows.value(element, kAXMinimizedAttribute) ?? false
                if minimized, NoteFocus.current(request) { AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            }
            let shown = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .contains { ($0[kCGWindowNumber as String] as? UInt32) == number }
            raise()
            var forward = false
            if element != nil, shown, !minimized, NoteFocus.current(request) {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.3)
                forward = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
            }
            if !forward { launch() }
            raise()
            // Some apps say yes to coming forward and don't, or show another window as they reopen: once more.
            windowQueue.asyncAfter(deadline: .now() + 0.15) {
                if forward, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { launch() }
                raise()
            }
            windowQueue.asyncAfter(deadline: .now() + 0.4) { raise() }
        }
    }

    /// "Open here": the note, over this dock, without going to its window or mode.
    func openHere(_ id: UUID) {
        PetalApp.shared.popups.dismissCard()
        cancelPending()
        guard let note = notes.first(where: { $0.id == id }) else { return }
        present(note, key: true)
    }

    /// "Go to <mode>" on the card.
    func goTo(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }), let place = note.place else { return PetalApp.shared.popups.dismissCard() }
        go(to: note, place: place)
    }

    /// The dock button the note comes out of: its app's icon when the dock shows it, else the AI button.
    func anchor(for note: StickyNote) -> CGRect? {
        let panel = PetalApp.shared.docks.focusedDock?.panel
        if note.place?.app == "com.apple.finder", let frame = panel?.screenFrame(of: DockView.finderSlot) { return frame }
        if let app = note.place?.app, !app.isEmpty, let frame = panel?.screenFrame(of: app) { return frame }
        return panel?.screenFrame(of: "claude")
    }
}

/// A note done in another mode, out of that mode's button: "Safari · Your note is ready", Open here or Go to Design.
struct NoteReadyCard: View {
    @Environment(PetalApp.self) private var app
    let card: FocusCard

    var body: some View {
        let target = card.target
        let color = Color(nsColor: target?.color ?? app.accent)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                AppIconView(id: card.bundleID, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Text(card.title.isEmpty ? Apps.name(card.bundleID) : card.title).bold()) · your note is ready")
                        .font(.system(size: 13)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text("\(card.reason) · in \(target?.name ?? "another mode")")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                RoundButton(symbol: "xmark") { app.popups.dismissCard() }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Open here") { if let id = card.noteID { app.claude.openHere(id) } }.buttonStyle(.glass)
                if let target {
                    Button("Go to \(target.name)") { if let id = card.noteID { app.claude.goTo(id) } }
                        .buttonStyle(.glassProminent).tint(color)
                }
            }
        }
    }
}

/// What a note is stuck to, under the panel's header: the app's icon, the tab's or window's title, and the chip
/// that changes it.
struct NotePlaceLine: View {
    let panel: ClaudePanel
    let place: NotePlace
    let gone: Bool

    var body: some View {
        HStack(spacing: 6) {
            AppIconView(id: place.app, size: 14)
            Text(words)
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if !gone { NoteScopeChip(panel: panel, place: place) }
        }
        .help(help)
    }

    private var words: String {
        switch place.kind {
        case .app: return place.appName
        case .tab:
            if gone { return "\(place.appName) · tab closed" }
            return [place.appName, place.tab?.title.isEmpty == false ? place.tab?.title ?? "" : place.title].filter { !$0.isEmpty }.joined(separator: " · ")
        case .window:
            if gone { return "\(place.appName) · window closed" }
            return [place.appName, place.title].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    private var help: String {
        switch place.kind {
        case .app: "This chat is stuck to \(place.appName): it shows on whichever of its windows is in front."
        case .tab: "This chat is stuck to this tab: it looks at it, wherever you go, and comes back with it."
        case .window: "This chat is stuck to this window: it looks at it, wherever you go, and comes back with it."
        }
    }
}

/// "This tab", "This window" or "All of Safari", on clear glass as the panel's other controls are: picks what the
/// note sticks to. Drag the note by its glass to stick it anywhere on that.
struct NoteScopeChip: View {
    let panel: ClaudePanel
    let place: NotePlace

    static func name(_ scope: NoteScope, app: String) -> String {
        switch scope {
        case .tab: "This tab"
        case .window: "This window"
        case .app: "All of \(app.isEmpty ? "the app" : app)"
        }
    }

    var body: some View {
        let scopes = NoteScope.allCases.filter { $0 != .tab || place.kind == .tab || panel.tabForCurrent != nil }
        Menu {
            Picker("Stick to", selection: Binding(get: { place.kind }, set: { panel.stick(to: $0) })) {
                ForEach(scopes, id: \.self) { Text(Self.name($0, app: place.appName)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pin.fill").font(.system(size: 8.5))
                Text(Self.name(place.kind, app: place.appName)).font(.system(size: 11.5)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 8).padding(.trailing, 7)
            .frame(height: 20)
            .glassEffect(.clear.interactive(), in: .capsule)
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("What this note is stuck to")
    }
}

/// Which request to bring a note's window forward is the newest (`Generation`: cancelling reaches it at once from
/// any thread, never waiting behind a slow Accessibility call). Its own counter: closing the panel, which cancels
/// it, never stops the dock's own focusing of an app just clicked.
enum NoteFocus {
    private static let requests = Generation()
    static func next() -> Int { requests.next() }
    static func cancel() { requests.cancel() }
    /// Still the newest: checked right before every activate and raise.
    static func current(_ request: Int) -> Bool { requests.current(request) }
}

/// An app's icon, never read from the disk on the main thread: the one Petal has already, else a plain one until
/// it's loaded in the background.
struct AppIconView: View {
    let id: String
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image ?? Apps.cachedIcon(id) {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "app").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: id) { if Apps.cachedIcon(id) == nil { Apps.loadIcon(id) { image = $0 } } }
    }
}
