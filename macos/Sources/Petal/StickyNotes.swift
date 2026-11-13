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
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundleID, !front.isTerminated,
           !RunBrowsers.isRun(front.processIdentifier) { return front }
        return NSWorkspace.shared.personsApplications.first { $0.bundleIdentifier == bundleID && !$0.isTerminated }
    }

    /// As it may be kept or shown: a private app's (`aiNeverLook`) without its titles and addresses.
    @MainActor var sanitized: NotePlace { PetalApp.shared.assist.neverLook(app) ? scrubbed : self }
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
    /// Done while the person was somewhere else: its app's icon has a nudge.
    var ready = false
    /// Open when the person went to another window: it comes back with its window.
    @ObservationIgnored var away = false
    /// Its window closed or its app quit: it opens as a plain chat.
    @ObservationIgnored var windowGone = false
    /// A helper in one of Petal Notes (NoteHelpers): that note's id. Its cards, steps and answer go on the note.
    @ObservationIgnored var paper: String?
    /// A helper of a note in a Private notebook: never in the AI button's previews (checked again when shown).
    @ObservationIgnored var secret = false
    /// A second opinion's helper (its own agent beside the note's).
    @ObservationIgnored var reviewer = false
    /// A helper whose note moved to a place that isn't in front: it waits for it (its default look and act refused).
    @ObservationIgnored var waitingForPlace = false

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

    /// AI chats were sticky notes (`aiNotes`) until Petal Notes replaced them: the AI button opens the quick
    /// question, stuck nowhere, and Stick here makes it a note (NoteDesk). The notes' agents, their background acting
    /// and previews stay, for helpers in notes to come; nothing makes a chat a note now.
    var notesOn: Bool { false }

    /// How many notes hold a place among the `atOnce` at work: those running, and a helper whose turn ended asking
    /// the person (Allow or Don't), which is the same run going on (`Agent.holdsPlace`).
    var working: Int { notes.filter { $0.agent.holdsPlace }.count }
    /// The same, not counting `agent`'s own place: what its next turn has to fit beside.
    func working(besides agent: Agent) -> Int { notes.filter { $0.agent !== agent && $0.agent.holdsPlace }.count }

    func note(withID id: String) -> StickyNote? { notes.first { $0.id.uuidString == id } }

    /// Why a note's helper can't look or act on its default target now (its note's place isn't in front), or nil.
    func helperWaiting(_ id: String?) -> String? {
        // Never named: what an AI is told of a place is only what NoteShield made of it.
        guard let id, let note = note(withID: id), note.paper != nil, note.waitingForPlace else { return nil }
        return "This note's place isn't in front: Petal is waiting for it. Say so in one line, and go on once it's there."
    }

    /// The place a chat's tools look at: its note's (a helper's always; an AI sticky note's while those are on).
    func placed(_ id: String?) -> NotePlace? {
        guard let id, let note = note(withID: id), notesOn || note.paper != nil else { return nil }
        return note.place
    }

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

    /// The quick question is answering with its panel closed (the AI button shows it's working).
    var looseWorking: Bool { loose.agent.running && !(isOpen && current === loose) }

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
        let known = front.tab?.known == true
        if frontTabKnown != known { frontTabKnown = known }
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

    /// The notes here that can fit what's in front (stuck to a window that's there, or a Chromium tab's, whose tab
    /// may come back), then the chats kept from before, with their places for NoteRules (which keeps one per chat: a
    /// note here over a kept copy of its chat).
    private var gathered: (found: [Found], candidates: [NoteCandidate]) {
        var found: [Found] = []
        var candidates: [NoteCandidate] = []
        for note in notes {
            guard let place = note.place, note.attached || place.tabComesBack else { continue }
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

    /// Chromium tab notes whose window closed or browser quit, and chats kept for tabs, of `bundle` (nil: any
    /// browser): their tabs may come back (another window, or the browser restarted), so Petal keeps looking when it
    /// comes forward.
    func recoverableTabs(_ bundle: String?) -> Bool {
        notes.contains { $0.windowGone && $0.place?.tabComesBack == true && (bundle == nil || $0.place?.app == bundle) }
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
                              desktop: dock?.desktop, scope: tab == nil ? .window : .tab, tab: tab)
        // A chat kept for this tab, window or app from before Petal (or the browser) last started, carried on: by
        // the note that already holds it (picked from the list since), or a new one.
        if case .kept(let saved)? = found {
            // Every link to the chat goes: the note is it now.
            savedPlaces = savedPlaces.filter { $0.value.id != saved.id }
            if let old = saved.place {
                place.scope = old.scope
                if let tab = old.tab { place.tab = front.tab.map { NoteRules.follow(tab, to: $0, keepWords: !title.isEmpty) } ?? tab }
                if title.isEmpty { place.title = old.title }
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
        guard var place = note.place, NoteRules.fits(place, front) else { return }
        if note.windowGone, place.kind == .tab {
            // Its tab is back (in another window, or after its browser restarted): the same chat carries on.
            note.windowGone = false
            listenIfNeeded()
        }
        place = NoteRules.adopt(place, front, title: title, keepWords: !PetalApp.shared.assist.neverLook(place.app))
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
                // A tab read while its window couldn't be is no tab Petal can tell is this window's: nothing changes.
                guard mine == self.stickTicket, self.current === note, var now = note.place, now.kind == kind, let tab = read.tab, tab.known,
                      let window = read.window, NoteRules.sameWindow(now, read.place(pid, app: now.app)) else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { self.saw(running, read) }
                now.tab = tab
                now.pid = pid
                now.window = window
                now.scope = .tab
                note.place = now
                self.claimPlace(note)
            }
            return
        case .window:
            // An app's note sticks to the window in front now, read again (the one Petal saw last may be another
            // window by now), and only then stuck to; a choice made meanwhile wins.
            if place.kind == .app {
                guard let running = place.running else { return }
                Self.readFront(of: running) { read in
                    let pid = running.processIdentifier
                    guard mine == self.stickTicket, self.current === note, var now = note.place, now.kind == .app,
                          let window = read.window else { return }
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { self.saw(running, read) }
                    now.pid = pid
                    now.window = window
                    now.scope = .window
                    note.place = now
                    self.claimPlace(note)
                }
                return
            }
            guard place.window != nil else { return }
        case .app:
            guard !place.app.isEmpty else { return }
        }
        place.scope = scope
        note.place = place
        claimPlace(note)
    }

    /// `note` now holds its place: another note stuck to exactly that place (two tab notes of one window both made
    /// "This window", say) lets go of it and is kept in Chats, stuck to nothing, and so is a chat kept for it from
    /// before. A tab is the same tab only by its id or button (`NoteRules.samePlace`), never by its window, place and
    /// address. One place, one note: which comes back there is never a guess.
    private func claimPlace(_ note: StickyNote) {
        guard let place = note.place else { return }
        let others = notes.filter { $0 !== note && $0.place != nil }
        for index in NoteRules.letGo([place] + others.map(\.place)) where index > 0 { detach(others[index - 1]) }
        for (link, chat) in savedPlaces where chat.id != note.agent.chatID && chat.place.map({ NoteRules.samePlace($0, place) }) == true {
            savedPlaces[link] = nil
            if let held = live(chat: chat.id) {
                // Open as a plain chat (picked from Chats): it lets go too, or its next save would claim the place
                // back. A live note stuck there was already let go of above.
                guard held.place == nil else { continue }
                held.agent.keptPlace = nil
                if let now = held.agent.saved { Chats.save(now) }
                continue
            }
            var unstuck = chat
            unstuck.place = nil
            Chats.save(unstuck)
        }
        prune(sparing: note)
    }

    /// A note lets go of its place: its chat stays in Chats, stuck to nothing (its link from the place goes too).
    private func detach(_ note: StickyNote) {
        if pendingOpen === note { cancelPending() }
        note.agent.keptPlace = nil
        note.place = nil   // saved again by its chat, stuck to nothing
        note.windowGone = false
        note.away = false
        if note.ready { note.ready = false; updateReady() }
        unlink(note.agent.chatID)
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
        guard let place = chat.place?.sanitized else { present(note); return prune() }
        if holdsPlace(place, besides: note) {
            // Another note holds its place now (the list may still show the chat as it was before): it opens as a
            // plain chat and lets go of the place, or its next save would claim it back.
            note.agent.keptPlace = nil
            if let now = note.agent.saved { Chats.save(now) }
            present(note)
            return prune()
        }
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
        // A Safari, Firefox or Zen tab's chat (its tab's button meant something only to the Petal that saw it), and a
        // Chromium tab's after its browser restarted, are plain chats: never stuck again by address from here. A link
        // kept from the tab waits for it to come forward, where notes and kept chats are told apart together.
        if place.kind == .tab, place.tab != nil, tabID == nil { present(note); return prune() }
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
                var found = place
                // A Chromium tab's only once the browser found it by its id: asked and unanswered (Automation turned
                // off, the browser busy), its old window still open says nothing of the tab, so it stays unknown.
                let there = NoteRules.restoredThere(tabAsked: tabID != nil, tabFound: tab?.found) {
                    Windows.windows(of: place.pid).contains { $0.id == "\(place.pid)-w\(window)" }
                }
                // Its window now (learned once its tab is in front when that's unsure).
                if let tab { found.window = Self.windowHolding(pid: place.pid, old: place.window, bounds: tab.bounds) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Another chat picked since: this one doesn't stick (it keeps its window in its saves and the
                        // window's link to it).
                        guard mine == self.restoreTicket else { return self.prune() }
                        if there == true && self.notesOn && Self.privacy.current(privacy) {
                            let stuck = found
                            // Its window or tab is there: it's the note for it from now on, so the copy kept for it goes
                            // (two copies of one chat would make its tab unsure). As it may be kept: sanitized now. Not
                            // when another note here has that tab (by its id or button) or place since: it opens as a
                            // plain chat, keeping its link.
                            if !self.holdsPlace(stuck, besides: note) {
                                _ = self.attach(note, stuck.sanitized)
                                self.unlink(chatID)
                            } else {
                                // It lets go of the place, or its next save would claim it back.
                                note.agent.keptPlace = nil
                                if let now = note.agent.saved { Chats.save(now) }
                            }
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

    /// Another note holds `place`: stuck there, or a tab's note whose window went that may still come back with its
    /// tab (its tab moved to another window Petal hasn't looked at yet).
    private func holdsPlace(_ place: NotePlace, besides note: StickyNote) -> Bool {
        notes.contains { other in
            other !== note && (other.attached || (other.windowGone && other.place?.kind == .tab))
                && other.place.map { NoteRules.samePlace($0, place) } == true
        }
    }

    /// The links kept from windows, tabs and apps to a chat a note here now holds, stuck where they were: the note is it.
    private func unlink(_ chat: UUID) {
        savedPlaces = savedPlaces.filter { $0.value.id != chat }
        listenIfNeeded()
    }

    /// Notes nobody can come back to (their window gone, or stuck to none: chats read from the list) are let go,
    /// and past 30 idle ones the oldest too. All are kept in Chats; one whose window is still open is found again
    /// when that window opens the AI, and a Chromium tab's in another window, or after its browser restarts.
    func prune(sparing spared: StickyNote? = nil) {
        let keep = { (note: StickyNote) in
            note === spared || note === self.current || note === self.loose || note.agent.running || note.ready || !note.agent.waiting.isEmpty
                || note.paper != nil
        }
        // A window's link to a chat let go here holds the chat as it is now, never an older copy.
        for note in notes where !keep(note) {
            guard let chat = note.agent.saved else { continue }
            for (key, value) in savedPlaces where value.id == chat.id { savedPlaces[key] = chat }
        }
        var gone = notes.filter { !keep($0) && ($0.windowGone || $0.place == nil) }
        notes.removeAll { !keep($0) && ($0.windowGone || $0.place == nil) }
        // A Chromium tab's note whose browser quit (or window closed) can be found again: by its tab's id, or its
        // address. A Safari, Firefox or Zen tab's button went with its window: its chat waits in Chats.
        for note in gone where note.place?.tabComesBack == true {
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
    /// `tabs: false` leaves the browser's tab unread (no AppleScript: Petal Notes asks only when a note needs it).
    static func readFront(of running: NSRunningApplication, tabs wanted: Bool = true, _ done: @escaping @MainActor (FrontRead) -> Void) {
        let pid = running.processIdentifier
        let bundle = running.bundleIdentifier ?? ""
        let tabs = wanted && Browsers.kind(bundle) != nil && !PetalApp.shared.assist.neverLook(bundle)
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
    /// number), else nil: another tab shows, or Petal can't tell (`tabState` says which). A tab note's AI reads and
    /// acts only on its own tab (`NoteRules.surely`: its id, or its button in the tab strip, in the same run of the
    /// browser), never on whichever tab its window shows by then, nor one on its address. Asks Accessibility and the
    /// browser: never on the main thread.
    nonisolated static func tabShowing(_ place: NotePlace) -> (tab: NoteTab, window: CGWindowID)? {
        tabState(place).showing
    }

    /// The same, saying which when it isn't: another tab is showing (the browser answered with a tab Petal can tell
    /// apart, and it isn't the note's), or Petal can't tell (no answer, not allowed to ask the browser, its window not
    /// found among the browser's). Before it says it can't tell, one more way to be sure: the note's window is its
    /// browser's focused window, before and after the browser is asked, and the browser's front window's active tab
    /// is the note's own (by its id or button). Off the main thread.
    nonisolated static func tabState(_ place: NotePlace) -> TabShown {
        let access: Browsers.Access = Browsers.kind(place.app) == .gecko ? .allowed : Browsers.access(place.app)
        let unsure: TabShown = .unsure(access == .notAsked ? .notAsked : access == .denied ? .refused : .unknown)
        guard place.kind == .tab, place.tab != nil, Windows.trusted else { return unsure }
        let app = AXUIElementCreateApplication(place.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let element: AXUIElement?
        // Whether the browser listed its windows (and the note's isn't among them), or is gone.
        var listed = false
        if let number = place.window {
            let all: [AXUIElement]? = Windows.value(app, kAXWindowsAttribute)
            listed = all != nil || NSRunningApplication(processIdentifier: place.pid) == nil
            element = all?.first { Windows.id(of: $0) == number }
        } else {
            element = Windows.value(app, kAXFocusedWindowAttribute)
        }
        // Its window not among the browser's (closed, on another Desktop, the browser quit): said so, never "try again".
        if element == nil, listed { return .unsure(.noWindow) }
        guard let element, let number = Windows.id(of: element), let frame = Windows.frame(of: element) else { return unsure }
        let window = Browsers.Window(number: number, title: Windows.value(element, kAXTitleAttribute) ?? "", frame: frame)
        if let now = Browsers.shownTab(pid: place.pid, bundleID: place.app, window: window, element: element) {
            switch NoteRules.tabCheck(place, FrontPlace(pid: place.pid, app: place.app, window: number, tab: now)) {
            case .same: return .shown(tab: now, window: number)
            case .another: return .another
            case .unknown: break
            }
        }
        // Its window is the browser's focused one, and stays so while the browser tells its front window's tab, whose
        // title starts that window's own (so the front window the browser means is that very one).
        guard access == .allowed else { return unsure }
        let focused = { (Windows.value(app, kAXFocusedWindowAttribute) as AXUIElement?).flatMap { Windows.id(of: $0) } }
        guard focused() == number, let active = Browsers.activeTab(pid: place.pid, bundleID: place.app), focused() == number,
              !active.title.isEmpty, (Windows.value(element, kAXTitleAttribute) as String? ?? "").hasPrefix(active.title),
              NoteRules.tabCheck(place, FrontPlace(pid: place.pid, app: place.app, window: number, tab: active)) == .same
        else { return unsure }
        return .shown(tab: active, window: number)
    }

    /// What a tab note's AI hears when its tab isn't known to be showing in its window: Petal didn't read or use
    /// anything there. Another tab showing: the person is asked to show it; Petal can't tell: never that (they may be
    /// looking at it), but what helps. `browser`: the browser's name.
    nonisolated static func tabWords(_ state: TabShown, browser: String) -> String {
        let name = browser.isEmpty ? "the browser" : browser
        let help: String
        switch state {
        case .shown:
            return "This note's tab changed while Petal read it (another page, or it moved), so nothing of what was read is told: look again."
        case .another:
            return "Another tab is showing in this note's window, so Petal didn't read or use it: a tab's note works only on its own tab. Ask the person to switch back to that tab (if they closed it, the note has nothing to read); front: true uses what's in front instead."
        case .unsure(.notAsked):
            help = "Petal hasn't been allowed to see \(name)'s tabs yet: the person can allow it from this note's place menu (Let Petal see \(name)’s tabs…), then ask again."
        case .unsure(.refused):
            help = "\(name) refused to let Petal see its tabs: the person can allow it in System Settings › Privacy & Security › Automation, then ask again."
        case .unsure(.unknown):
            help = "Try once more in a moment."
        case .unsure(.noWindow):
            return "This note's window isn't open in \(name) where Petal can see it (it was closed, is on another Desktop, or \(name) quit), so nothing was read or used. Say so to the person in one line; front: true uses what's in front instead."
        }
        return "Petal couldn't tell which tab this note's window is showing, so nothing was read or used there (it never works on another tab). \(help) Don't ask the person to switch tabs: they may be looking at it."
    }

    /// The same where it isn't known which: nothing more was done on the note's tab.
    nonisolated static let tabNotShowing = "This note's tab isn't known to be the one showing in its window now (another tab is, or Petal can't tell which), so Petal didn't read or use it: it never works on another tab."

    /// What a note's AI hears when it was asked where its app showed no window (Finder's desktop): it has none.
    nonisolated static func noWindow(_ app: String) -> String {
        "This note was opened where \(app.isEmpty ? "its app" : app) showed no window, so it has no window to look at or use. front: true uses what's in front now."
    }

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

    /// The window of `pid` a Chromium tab is in now, from that window's bounds (the browser's answer, top-left
    /// origin): `old` while it's still that one, else the one window with those bounds; nil when that's unsure (none,
    /// or two alike). Off the main thread.
    nonisolated static func windowHolding(pid: pid_t, old: CGWindowID?, bounds: CGRect?) -> CGWindowID? {
        let windows = Windows.windows(of: pid)
        let was = old.flatMap { number in windows.first { $0.id == "\(pid)-w\(number)" } }
        guard let bounds else { return was == nil ? nil : old }
        let alike = windows.filter { NoteRules.sameFrame($0.frame, bounds) }
        if let was, alike.contains(where: { $0.id == was.id }) { return old }
        return alike.count == 1 ? Windows.id(of: alike[0].element) : nil
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
        // One of Petal's own windows (Settings, the welcome, a page) in front: the app in front is Petal,
        // which appCameForward leaves alone.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { if let window { self?.ownWindowCameForward(window) } }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let pid = running?.processIdentifier else { return }
                // An app's note waits for its app to open again; a window's and a tab's are gone with it.
                self.lost { NoteRules.gone($0, quit: pid) }   // a quit browser's tab notes keep it heard, for when it opens again
            }
        }
        Chats.list { [weak self] chats in
            guard let self else { return }
            var kept: [SavedChat] = []
            for var chat in chats {
                // A private app's titles and addresses (made private while Petal was closed) go from the file too.
                let sanitized = chat.place?.sanitized
                if sanitized != chat.place {
                    chat.place = sanitized
                    Chats.save(chat)
                }
                guard let place = chat.place else { continue }
                switch place.kind {
                case .window:
                    // A window lasts only as long as its app.
                    guard place.window != nil, NSRunningApplication(processIdentifier: place.pid)?.bundleIdentifier == place.app else { continue }
                case .tab:
                    // A Chromium tab is found again by its id while its browser runs, by its address after it
                    // restarted. A Safari, Firefox or Zen tab's button meant something only to the Petal that saw it:
                    // its chat waits in Chats, holding no place, so it never makes another chat let go of one.
                    guard place.tabComesBack else { continue }
                case .app:
                    guard !place.app.isEmpty else { continue }
                }
                kept.append(chat)
            }
            // Newest first: an older chat kept for the same place lets go of it (kept, stuck to nothing), so a place
            // never has two notes to come back.
            let older = Set(NoteRules.letGo(kept.map(\.place)))
            var found: [String: SavedChat] = [:]
            for (index, var chat) in kept.enumerated() {
                guard let place = chat.place else { continue }
                if !older.contains(index) {
                    found[NoteRules.key(place)] = chat
                } else if self.live(chat: chat.id) == nil {
                    chat.place = nil
                    Chats.save(chat)
                }
            }
            // Chats already carried on by a note since Petal started stay with it.
            self.savedPlaces = found.filter { self.live(chat: $0.value.id) == nil }
            self.listenIfNeeded()
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
        cancelPending()   // a note's window being brought forward opens nothing
        // The chat showing becomes the loose chat, stuck to no window: from now on it looks at what's in front.
        if current !== loose, current.place != nil, isOpen {
            current.place = nil
            current.windowGone = false
            loose = current
        }
        guard notes.contains(where: { $0.ready || $0.away }) else { return }
        for note in notes { note.ready = false; note.away = false }
        updateReady()
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
            // Another window of the app in front. An open note stuck to another of its windows steps away at once,
            // before the read: it never stays over the window that came forward while the app answers.
            guard notesOn, let front = NSWorkspace.shared.frontmostApplication, event.pid == front.processIdentifier else { return }
            if let window = event.window {
                // That window is in front from now on, before the read says more (its tab, its frame): a note closing
                // meanwhile is judged against it, never against the window that was in front before.
                lastFront = FrontPlace(pid: event.pid, app: front.bundleIdentifier ?? "", window: window, tab: nil)
            }
            if isOpen, current.attached, let place = current.place, place.kind != .app, place.pid == event.pid,
               let window = event.window, let mine = place.window, mine != window {
                looks += 1
                stepAway()
            }
            look(at: front)
        case .titleChanged, .tabSwitched:
            // A browser's window shows another tab (or its tab another page; two tabs alike change no title, but
            // selecting one moves the keyboard or the tab strip's selection): looked at again once it settles.
            guard notesOn, let front = NSWorkspace.shared.frontmostApplication, event.pid == front.processIdentifier,
                  let bundle = front.bundleIdentifier, Browsers.kind(bundle) != nil, event.window == nil || event.window == lastFront?.window,
                  notes.contains(where: { $0.attached && $0.place?.kind == .tab && $0.place?.app == bundle }) || recoverableTabs(bundle)
            else { return }
            // Only a look, never a step away first: these also come when the keyboard moves inside the same page
            // (a click into a field), and the note would blink on every click.
            lookSoon(at: front.processIdentifier)
        case .closed:
            guard let window = event.window else { return }
            lost { NoteRules.gone($0, closed: window) }
        default:
            break
        }
    }

    /// The notes whose window closed or app quit (`gone`): from now on they open as plain chats. The one open on that
    /// window is put away, kept as when the person goes elsewhere: with its window gone nothing else would (it's no
    /// longer stuck anywhere).
    private func lost(_ gone: (NotePlace) -> Bool) {
        let shown = isOpen && current.attached && current.place.map { place in
            gone(place) && lastFront.map { NoteRules.sameWindow(place, $0, orUnknown: true) } == true
        } == true
        for note in notes where note.place.map(gone) == true { note.windowGone = true }
        if shown { stepAway() }
        updateReady()
        listenIfNeeded()
    }

    private func appCameForward(_ running: NSRunningApplication) {
        let pid = running.processIdentifier
        let me = ProcessInfo.processInfo.processIdentifier
        // Another app came forward while a note's window was being brought: its retries stop now.
        if let bringing, pid != bringing, pid != me {
            self.bringing = nil
            NoteFocus.cancel()
        }
        guard notesOn, pid != me else { return }
        // What's in front is this app now, its window not read yet. An open note stuck to another app (or to another
        // app's window or tab) steps away at once, before anything is read: it never stays over the next app while
        // that app answers. The read only decides what shows next.
        let now = FrontPlace(pid: pid, app: running.bundleIdentifier ?? "", window: nil, tab: nil)
        if lastFront?.pid != pid { lastFront = now }
        if isOpen, current.attached, let place = current.place, !NoteRules.sameWindow(place, now, orUnknown: true) { stepAway() }
        // Also a browser whose tabs may take back a note (it quit with them, or they're kept from before).
        guard notes.contains(where: { $0.attached }) || running.bundleIdentifier.map(recoverableTabs) == true else { return }
        look(at: running)
    }

    /// One of Petal's own windows took the keyboard (Settings, the welcome, a page, an alert): an open note
    /// steps away as when another app comes forward, and comes
    /// back with its place (that app coming forward again). Petal's panels that never bring Petal forward (the note
    /// itself, cards, popups, the dock, the overview) don't count.
    private func ownWindowCameForward(_ window: NSWindow) {
        guard !window.styleMask.contains(.nonactivatingPanel), notesOn, isOpen, current.attached else { return }
        stepAway()
    }

    /// The pointer is on the note's chip: what's in front is read again, so a tab that can be told apart only now (a
    /// Safari window that just got its second tab and its tab strip) is offered.
    func refreshFront() {
        guard notesOn, let running = current.place?.running,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier else { return }
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
    /// app), over the dock. When several fit (a tab's, its window's, its app's), the most specific shows.
    private func frontChanged(_ front: FrontPlace, title: String) {
        if let pending = pendingOpen, let place = pending.place {
            // A tab's note: its own tab in front (a browser that couldn't be asked to show it waits for the person to),
            // which it follows (another window, a new address).
            let there = place.kind == .tab ? holds(pending, front) : NoteRules.sameWindow(place, front)
            if pending.windowGone ? place.pid == front.pid : there {
                if place.kind == .tab, there { adopt(pending, front, title: PetalApp.shared.assist.neverLook(front.app) ? "" : title) }
                pendingOpen = nil
                // Its window is in front: no more retries (they'd fight a switch the person makes next).
                bringing = nil
                NoteFocus.cancel()
                // After the app has finished coming forward, so its window taking focus doesn't close the note; and
                // only if nothing else was opened meanwhile and the window is still in front.
                let ticket = pendingTicket
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    let now = pending.place ?? place
                    guard ticket == self.pendingTicket, self.inFront(now), now.kind != .tab || self.lastFront == front else { return }
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

    /// `note` belongs on what's in front, told apart from the other notes and the chats kept from before together
    /// (`fitting`): a tab's note never shows on a tab another note or kept chat fits as well by its address.
    private func holds(_ note: StickyNote, _ front: FrontPlace) -> Bool {
        fitting(front).contains { $0 === note }
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
    /// elsewhere in the note's own window puts it away; going to another window, it comes back with this one.
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
                    if self.holds(note, read.place(pid, app: running.bundleIdentifier ?? "")) { note.away = false }
                }
            }
        }
    }

    // MARK: Done while away

    /// A note's turn ended. If the person isn't looking at it, its app's icon gets a nudge (a badge and one bounce).
    func finished(_ note: StickyNote) {
        startWaiting()
        // A helper in a note: its answer goes on the note.
        if note.paper != nil { return PetalApp.shared.paper.helpers.finished(note) }
        // The quick question (stuck nowhere) too: its answer came while its panel was closed.
        guard notesOn || note === loose, !(isOpen && current === note), note.agent.messages.contains(where: { $0.kind == .user }) else { return }
        note.ready = true
        updateReady()
        if let app = note.place?.app, !app.isEmpty { PetalApp.shared.signals.bounce(app) }
    }

    /// Notes waiting for room start, in order, while fewer than `atOnce` work. Called whenever a run ends or is
    /// ended (a new chat, a chat picked from the list).
    func startWaiting() {
        // A helper's turn starts only while its run admits it (paused: it keeps waiting; stopped: never).
        for note in notes where !note.agent.waiting.isEmpty && working(besides: note.agent) < Self.atOnce && note.agent.admitted { note.agent.runWaiting() }
    }

    func updateReady() {
        let ready = notes.filter { $0.ready }
        let apps = Set(ready.compactMap { $0.place?.app }.filter { !$0.isEmpty })
        if apps != readyApps { readyApps = apps }
    }

    /// The app's icon was clicked and one of its notes is done: its window comes forward and the note opens on it.
    /// False when no note of that app is waiting (or notes are off): the click does what it always does.
    func openReady(app bundleID: String) -> Bool {
        guard notesOn, let note = notes.first(where: { $0.ready && $0.place?.app == bundleID }), let place = note.place else { return false }
        go(to: note, place: place)
        return true
    }

    /// Brings a note's window forward and opens the note on it.
    func go(to note: StickyNote, place: NotePlace) {
        if isOpen { close() }   // first: its closing cancels what's pending, never this
        cancelPending()
        // An app's note: whichever of its app's windows; a window's or a tab's: its own window's app.
        let running = place.kind == .app
            ? NotePlace.running(place.app)
            : NSRunningApplication(processIdentifier: place.pid).flatMap { $0.isTerminated ? nil : $0 }
        guard !note.windowGone, let running else { return present(note, key: true) }
        let pid = running.processIdentifier
        // Anything opened, closed or turned off from here on cancels it.
        let ticket = pendingTicket
        guard notesOn else { return }
        // Its window is in front already (and, for a tab's note, its tab): nothing to wait for.
        if self.inFront(place), place.kind != .tab || self.lastFront.map({ self.holds(note, $0) }) == true {
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
                guard now.kind == .tab ? self.holds(note, seen) : NoteRules.sameWindow(now, seen)
                else { return }
                self.present(note, key: true, fromIcon: true)
            }
        }
        self.bringing = pid
        // Numbered now: closing, another app coming forward or another bringing stops both the tab's switch and
        // the window's.
        let request = NoteFocus.next()
        let url = running.bundleURL
        // A tab's note: its tab shows first (Chromium browsers by its id; Safari, Firefox and Zen by its button).
        if place.kind == .tab, let tab = place.tab {
            let app = place.app, window = place.window
            let chromium = Browsers.kind(app) == .chromium && tab.id != nil
            Self.tabQueue.async {
                let shown = Browsers.select(tab, bundleID: app, still: { NoteFocus.current(request) })
                // Its tab closed while its window stayed open (only a closed window says so by itself): the
                // note opens as a plain chat, and its nudge goes, instead of waiting for a tab that won't show.
                if shown.shown == .missing {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard ticket == self.pendingTicket, NoteFocus.current(request), !(self.isOpen && self.current === note) else { return }
                            self.cancelPending()
                            note.windowGone = true
                            self.present(note, key: true)
                            self.listenIfNeeded()
                        }
                    }
                    return
                }
                guard chromium else { return }
                // A Chromium tab may be in another window by now (dragged there before Petal looked): the window
                // that holds it is the one brought forward, and the note's window from now on.
                Self.windowQueue.async {
                    guard NoteFocus.current(request) else { return }
                    let number = shown.shown == .shown ? Self.windowHolding(pid: pid, old: window, bounds: shown.bounds) : window
                    Self.bringForward(pid: pid, window: number, app: url, request: request)
                    guard let number, number != window else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard ticket == self.pendingTicket, NoteFocus.current(request), var now = note.place, now.kind == .tab,
                                  now.pid == pid, now.tab?.id == tab.id else { return }
                            now.window = number
                            note.place = now
                        }
                    }
                }
            }
            // A Chromium tab's window is brought forward once the browser says which it is.
            if chromium { return }
        }
        Self.bringForward(pid: pid, window: place.kind == .app ? nil : place.window, app: url, request: request)
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

    /// The dock button the note comes out of: its app's icon when the dock shows it, else the AI button.
    func anchor(for note: StickyNote) -> CGRect? {
        let panel = PetalApp.shared.docks.focusedDock?.panel
        if note.place?.app == "com.apple.finder", let frame = panel?.screenFrame(of: DockView.finderSlot) { return frame }
        if let app = note.place?.app, !app.isEmpty, let frame = panel?.screenFrame(of: app) { return frame }
        return panel?.screenFrame(of: "claude")
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
                .font(.system(size: TextSize.small)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
        let _ = panel.frontTabKnown   // drawn again when the tab in front can (or can no longer) be told apart
        let scopes = NoteScope.allCases.filter { $0 != .tab || place.kind == .tab || panel.tabForCurrent != nil }
        Menu {
            Picker("Stick to", selection: Binding(get: { place.kind }, set: { panel.stick(to: $0) })) {
                ForEach(scopes, id: \.self) { Text(Self.name($0, app: place.appName)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pin.fill").font(.system(size: TextSize.micro))
                Text(Self.name(place.kind, app: place.appName)).font(.system(size: TextSize.small)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: TextSize.micro, weight: .bold))
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
        .onHover { if $0 { panel.refreshFront() } }
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
