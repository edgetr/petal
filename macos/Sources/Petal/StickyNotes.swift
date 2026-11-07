import AppKit
import Observation
import SwiftUI

extension NotePlace {
    /// The app a note looks at: its window's (still the same app), or for an app's note that app, wherever it is.
    @MainActor var running: NSRunningApplication? {
        if kind == .app {
            if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == app { return front }
            return NSRunningApplication.runningApplications(withBundleIdentifier: app).first { !$0.isTerminated }
        }
        return NSRunningApplication(processIdentifier: pid).flatMap { $0.bundleIdentifier == app && !$0.isTerminated ? $0 : nil }
    }

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
            let seen = self.saw(front, read)
            done(self.note(for: front, seen.front, previous: seen.previous, title: read.title))
        }
    }

    /// The one chat stuck to no window: kept, so closing and opening again (or turning notes off) never loses it.
    var looseNote: StickyNote {
        if !notes.contains(where: { $0 === loose }) { notes.append(loose) }
        return loose
    }

    /// What's in front, as just read, remembered; and the tab its window showed the time before.
    @discardableResult
    func saw(_ running: NSRunningApplication, _ read: FrontRead) -> (front: FrontPlace, previous: NoteTab?) {
        let front = FrontPlace(pid: running.processIdentifier, app: running.bundleIdentifier ?? "", window: read.window, tab: read.tab)
        let key = "\(front.pid)-\(front.window ?? 0)"
        let previous = lastTabs[key]
        if lastTabs.count > 64 { lastTabs = [:] }
        lastTabs[key] = read.tab
        lastFront = front
        let primary = NSScreen.screens.first?.frame.height ?? 0
        lastFrontFrame = read.frame.map { NoteRules.appKitFrame($0, primaryHeight: primary) }
        return (front, previous)
    }

    /// The notes stuck to what's in front.
    private func fitting(_ front: FrontPlace, previous: NoteTab?) -> [StickyNote] {
        notes.filter { $0.attached && $0.place.map { NoteRules.fits($0, front, previous: previous) } == true }
    }

    private func mostSpecific(_ notes: [StickyNote]) -> StickyNote? {
        NoteRules.pick(notes, scope: { $0.place?.kind ?? .window }, showing: { self.isOpen && $0 === self.current })
    }

    private func note(for app: NSRunningApplication, _ front: FrontPlace, previous: NoteTab?, title: String) -> StickyNote {
        // An app kept private: its window's title isn't kept or told (and its tabs aren't read).
        let title = PetalApp.shared.assist.neverLook(app.bundleIdentifier) ? "" : title
        if let note = mostSpecific(fitting(front, previous: previous)) {
            adopt(note, front, title: title)
            return note
        }
        let petal = PetalApp.shared
        let dock = petal.docks.focusedDock
        var place = NotePlace(pid: front.pid, app: front.app, appName: app.localizedName ?? "", window: front.window, title: title,
                              mode: dock?.mode?.id ?? "", desktop: dock?.desktop, scope: front.tab == nil ? .window : .tab, tab: front.tab)
        // A chat kept for this tab, window or app from before Petal (or the browser) last started, carried on: by
        // the note that already holds it (picked from the list since), or a new one.
        let kept = savedPlaces.filter { $0.value.place.map { NoteRules.fits($0, front, previous: previous) } == true }
        if let (key, saved) = NoteRules.pick(kept.map { ($0.key, $0.value) }, scope: { $0.1.place?.kind ?? .window }, showing: { _ in false }) {
            savedPlaces.removeValue(forKey: key)
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
        return attach(StickyNote(), place)
    }

    /// A note found on what's in front follows it: an app's note to the window in front (and the app's new process
    /// after it restarted), a tab's note to its tab's new address, window and place. A private app's titles and
    /// addresses are never kept.
    private func adopt(_ note: StickyNote, _ front: FrontPlace, title: String) {
        guard var place = note.place else { return }
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
        if let front = lastFront, NoteRules.sameWindow(place, front), let tab = front.tab { return tab }
        return place.tab
    }

    /// The chip: the note in the panel sticks to its tab, its window, or all of its app from now on.
    func stick(to scope: NoteScope) {
        let note = current
        guard var place = note.place, place.kind != scope else { return }
        let front = lastFront.flatMap { NoteRules.sameWindow(place, $0) ? $0 : nil }
        switch scope {
        case .tab:
            guard let tab = tabForCurrent else { return }
            place.tab = tab
            if let front { place.pid = front.pid; place.window = front.window }
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
        return NoteRules.sameWindow(place, front)
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
        // Its link to its window (savedPlaces) stays: opening the AI there finds the note holding the chat.
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
        guard let place = chat.place, !notes.contains(where: { $0.attached && $0.place.map(NoteRules.key) == NoteRules.key(place) })
        else { present(note); return prune() }
        // An app's note sticks to its app again, open or not: it shows on whichever of its windows is in front.
        if place.kind == .app, !place.app.isEmpty {
            _ = attach(note, place)
            present(note)
            return prune()
        }
        guard let window = place.window, NSRunningApplication(processIdentifier: place.pid)?.bundleIdentifier == place.app
        else { present(note); return prune() }
        let ticket = pendingTicket
        restoreTicket += 1
        let mine = restoreTicket
        Self.windowQueue.async {
            let there = Windows.windows(of: place.pid).contains { $0.id == "\(place.pid)-w\(window)" }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Another chat picked since: this one doesn't stick (it keeps its window in its saves and the
                    // window's link to it).
                    guard mine == self.restoreTicket else { return self.prune() }
                    if there && self.notesOn { _ = self.attach(note, place) } else if !there { note.agent.keptPlace = nil }
                    // Shown only if the panel wasn't closed (any way) or something else opened meanwhile; else it
                    // stays stuck to its window, quietly.
                    if ticket == self.pendingTicket { self.present(note) }
                    self.prune()
                }
            }
        }
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
        var title = ""
        var frame: CGRect?
        var tab: NoteTab?
    }

    /// Reads what's in front in an app, off the main thread.
    static func readFront(of running: NSRunningApplication, _ done: @escaping @MainActor (FrontRead) -> Void) {
        let pid = running.processIdentifier
        let bundle = running.bundleIdentifier ?? ""
        let tabs = Browsers.kind(bundle) != nil && !PetalApp.shared.assist.neverLook(bundle)
        windowQueue.async {
            var read = FrontRead()
            if Windows.trusted {
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.3)
                if let window: AXUIElement = Windows.value(element, kAXFocusedWindowAttribute) {
                    read.window = Windows.id(of: window)
                    read.title = Windows.value(window, kAXTitleAttribute) ?? ""
                    read.frame = Windows.frame(of: window)
                }
            }
            let seen = read
            guard tabs else { return DispatchQueue.main.async { MainActor.assumeIsolated { done(seen) } } }
            tabQueue.async {
                var withTab = seen
                withTab.tab = Browsers.activeTab(pid: pid, bundleID: bundle)
                let found = withTab
                DispatchQueue.main.async { MainActor.assumeIsolated { done(found) } }
            }
        }
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
            }
        }
        Chats.list { [weak self] chats in
            var found: [String: SavedChat] = [:]
            for chat in chats {
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
        }
    }

    /// `aiNotes` changed (or any setting did): with notes off, nothing listens, nudges or takes the app's click.
    func notesSettingChanged() {
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

    /// Window events (focus moving between an app's windows, a window closing, moving or resizing, and a browser
    /// window's title changing as another tab shows), heard only while a note is stuck somewhere: no watching loop,
    /// only what Petal's Accessibility observers already say.
    func listenIfNeeded() {
        let wanted = notesOn && notes.contains { $0.attached }
        WindowEvents.shared.titles("notes", wanted && notes.contains { $0.attached && $0.place?.kind == .tab })
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
        case .titleChanged:
            // A browser's window shows another tab (or its tab another page): looked at again once it settles.
            guard notesOn, let front = NSWorkspace.shared.frontmostApplication, event.pid == front.processIdentifier,
                  Browsers.kind(front.bundleIdentifier ?? "") != nil, event.window == nil || event.window == lastFront?.window,
                  notes.contains(where: { $0.attached && $0.place?.kind == .tab && $0.place?.app == front.bundleIdentifier }) else { return }
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
        guard notesOn, pid != ProcessInfo.processInfo.processIdentifier, notes.contains(where: { $0.attached }) else { return }
        look(at: running)
    }

    /// Reads what's in front in `running` (its window, and its tab) and shows its notes. Only the newest look counts.
    private func look(at running: NSRunningApplication) {
        let pid = running.processIdentifier
        looks += 1
        let mine = looks
        Self.readFront(of: running) { read in
            guard mine == self.looks, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            let seen = self.saw(running, read)
            self.frontChanged(seen.front, previous: seen.previous, title: read.title)
        }
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
    private func frontChanged(_ front: FrontPlace, previous: NoteTab?, title: String) {
        if let pending = pendingOpen, let place = pending.place {
            if pending.windowGone ? place.pid == front.pid : NoteRules.sameWindow(place, front) {
                pendingOpen = nil
                // Its window is in front: no more retries (they'd fight a switch the person makes next).
                bringing = nil
                NoteFocus.cancel()
                // After the app has finished coming forward, so its window taking focus doesn't close the note; and
                // only if nothing else was opened meanwhile and the window is still in front.
                let ticket = pendingTicket
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard ticket == self.pendingTicket, self.inFront(place) else { return }
                    self.present(pending, key: true, fromIcon: true)
                }
                return
            }
            // The person went to another app meanwhile.
            if front.pid != place.pid && !(place.kind == .app && place.app == front.app) { cancelPending() }
        }
        let here = fitting(front, previous: previous)
        let quiet = PetalApp.shared.assist.neverLook(front.app)
        for note in here { adopt(note, front, title: quiet ? "" : title) }
        if isOpen, current.attached, !here.contains(where: { $0 === current }) {
            stepAway()
        }
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

    /// The note's window (any of its app's, for an app's note) is the one in front, as far as Petal has heard.
    private func inFront(_ place: NotePlace) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if place.kind == .app { return !place.app.isEmpty && app.bundleIdentifier == place.app }
        guard app.processIdentifier == place.pid else { return false }
        guard let front = lastFront else { return true }
        return NoteRules.sameWindow(place, front)
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
        savedPlaces = savedPlaces.filter { $0.value.id != chat.id }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard !self.isOpen || self.current !== note, let place = note.place, self.inFront(place) else { return }
                note.away = false
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
            ? NSRunningApplication.runningApplications(withBundleIdentifier: place.app).first { !$0.isTerminated }
            : NSRunningApplication(processIdentifier: place.pid).flatMap { $0.isTerminated ? nil : $0 }
        guard !note.windowGone, let running else { return present(note, key: true) }
        let pid = running.processIdentifier
        // Taken now, before any mode's countdown: anything opened, closed or turned off meanwhile cancels it.
        let ticket = pendingTicket
        let bring = {
            guard ticket == self.pendingTicket, self.notesOn else { return }
            // Its window is in front already (and, for a tab's note, its tab): nothing to wait for.
            if self.inFront(place), place.kind == .app || self.lastFront?.window == place.window,
               place.kind != .tab || self.lastFront.map({ NoteRules.fits(place, $0) }) == true {
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
                    guard NoteRules.sameWindow(place, seen.front) else { return }
                    self.present(note, key: true, fromIcon: true)
                }
            }
            self.bringing = pid
            // A tab's note: its tab shows first (Chromium browsers and Safari; Firefox and Zen can't be asked).
            if place.kind == .tab, let tab = place.tab {
                let app = place.app, window = place.window
                Self.tabQueue.async { Browsers.select(tab, bundleID: app, window: window) }
            }
            Self.bringForward(pid: pid, window: place.kind == .app ? nil : place.window, app: running.bundleURL)
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
    nonisolated static func bringForward(pid: pid_t, window number: CGWindowID?, app url: URL?) {
        // Numbered now: a newer request, or a cancel, stops this one at once, even while it waits on the app.
        let request = NoteFocus.next()
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
