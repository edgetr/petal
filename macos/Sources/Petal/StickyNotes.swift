import AppKit
import Observation
import SwiftUI

/// The window a note is stuck to: the app, the window server's number for the window, its title then, and the mode
/// it was asked in. Kept with the chat (Chats.swift), so the chat still knows where it was asked.
struct NotePlace: Codable, Equatable, Sendable {
    var pid: Int32
    var app: String          // bundle id
    var appName: String
    var window: UInt32?      // CGWindowID; nil for an app with no window
    var title: String
    var mode: String         // the mode's id
    var desktop: Int?

    func matches(pid other: pid_t, window number: CGWindowID?) -> Bool {
        pid == other && (window == nil || number == nil || window == number)
    }
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

    /// The note for the window in front: the one stuck to it, one kept from before (Petal restarted), or a new one.
    /// The window is looked up off the main thread (Accessibility may wait on the app).
    func noteForFront(again: Bool = true, _ done: @escaping @MainActor (StickyNote) -> Void) {
        let me = ProcessInfo.processInfo.processIdentifier
        guard notesOn, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me,
              front.activationPolicy == .regular else { return done(looseNote) }
        let pid = front.processIdentifier
        Self.frontWindow(of: pid) { window, title in
            guard self.notesOn else { return done(self.looseNote) }
            // Another app came forward while its window was looked up: that one's, looked up once more.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                return again ? self.noteForFront(again: false, done) : done(self.looseNote)
            }
            self.lastFront = (pid, window)
            done(self.note(for: front, window: window, title: title))
        }
    }

    /// The one chat stuck to no window: kept, so closing and opening again (or turning notes off) never loses it.
    var looseNote: StickyNote {
        if !notes.contains(where: { $0 === loose }) { notes.append(loose) }
        return loose
    }

    private func note(for front: NSRunningApplication, window: CGWindowID?, title: String) -> StickyNote {
        let pid = front.processIdentifier
        // An app kept private: its window's title isn't kept or told.
        let title = PetalApp.shared.assist.neverLook(front.bundleIdentifier) ? "" : title
        if let note = notes.first(where: { $0.attached && $0.place?.pid == pid && $0.place?.window == window }) {
            if !title.isEmpty { note.place?.title = title }
            return note
        }
        let app = PetalApp.shared
        let dock = app.docks.focusedDock
        var place = NotePlace(pid: pid, app: front.bundleIdentifier ?? "", appName: front.localizedName ?? "",
                              window: window, title: title, mode: dock?.mode?.id ?? "", desktop: dock?.desktop)
        // A chat this window had before Petal last started, carried on: by the note that already holds it (picked
        // from the list since), or a new one.
        if let window, let saved = savedPlaces.removeValue(forKey: Self.key(pid, window)) {
            if title.isEmpty { place.title = saved.place?.title ?? "" }
            place.mode = saved.place?.mode ?? place.mode
            place.desktop = saved.place?.desktop ?? place.desktop
            let note = live(chat: saved.id) ?? StickyNote()
            if !notes.contains(where: { $0 === note }) {
                note.agent.restore(saved, switchProvider: false)
                notes.append(note)
            }
            if note === loose {
                // The loose chat had picked it up: it moves to this window (unless it's working; then it stays).
                let fresh = StickyNote()
                if !loose.agent.running { fresh.agent.restore(saved, switchProvider: false); loose.agent.reset() }
                return attach(fresh, place)
            }
            return attach(note, place)
        }
        return attach(StickyNote(), place)
    }

    private func attach(_ note: StickyNote, _ place: NotePlace) -> StickyNote {
        note.place = place
        note.windowGone = false
        if !notes.contains(where: { $0 === note }) { notes.append(note) }
        prune()
        listenIfNeeded()
        return note
    }

    /// A chat picked from the list: the note holding it, else carried on. With notes on, it sticks again to its
    /// window if that's still there; with them off (or its window gone), it's the loose chat.
    func restoreNote(_ chat: SavedChat) {
        cancelPending()
        savedPlaces = savedPlaces.filter { $0.value.id != chat.id }
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
        guard let place = chat.place, let window = place.window,
              NSRunningApplication(processIdentifier: place.pid)?.bundleIdentifier == place.app,
              !notes.contains(where: { $0.attached && $0.place?.pid == place.pid && $0.place?.window == window })
        else { present(note); return prune() }
        let ticket = pendingTicket
        Self.windowQueue.async {
            let there = Windows.windows(of: place.pid).contains { $0.id == "\(place.pid)-w\(window)" }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Shown only if the panel wasn't closed (or something else opened) meanwhile.
                    guard ticket == self.pendingTicket else { return self.prune() }   // picked another, or closed
                    if there && self.notesOn { _ = self.attach(note, place) }
                    if ticket == self.pendingTicket { self.present(note) }
                    self.prune()
                }
            }
        }
    }

    /// Notes nobody can come back to (their window gone, or stuck to none: chats read from the list) are let go,
    /// and past 30 idle ones the oldest too. All are kept in Chats; one whose window is still open is found again
    /// when that window opens the AI.
    func prune() {
        let keep = { (note: StickyNote) in note === self.current || note === self.loose || note.agent.running || note.ready || !note.agent.waiting.isEmpty }
        notes.removeAll { !keep($0) && ($0.windowGone || $0.place == nil) }
        let idle = notes.filter { !keep($0) && $0.attached }
        for old in idle.dropLast(30) {
            if let place = old.place, let window = place.window, let chat = old.agent.saved {
                savedPlaces[Self.key(place.pid, window)] = chat
            }
            notes.removeAll { $0 === old }
        }
    }

    static func key(_ pid: pid_t, _ window: CGWindowID) -> String { "\(pid)-\(window)" }

    /// Where notes do their Accessibility work (looking up and bringing forward windows), never the main thread.
    nonisolated static let windowQueue = DispatchQueue(label: "petal.notes.windows", qos: .userInitiated)

    /// The focused window of an app, its number and title, off the main thread.
    static func frontWindow(of pid: pid_t, _ done: @escaping @MainActor (CGWindowID?, String) -> Void) {
        windowQueue.async {
            var number: CGWindowID?
            var title = ""
            if Windows.trusted {
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.3)
                if let window: AXUIElement = Windows.value(element, kAXFocusedWindowAttribute) {
                    number = Windows.id(of: window)
                    title = Windows.value(window, kAXTitleAttribute) ?? ""
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(number, title) } }
        }
    }

    // MARK: Following the windows

    /// Starts watching which app is in front (only while notes are stuck to windows does it look further), and reads
    /// the kept chats once, so a window that had a note before Petal started gets it back.
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
                for note in self.notes where note.place?.pid == pid { note.windowGone = true }
                self.updateReady()
            }
        }
        Chats.list { [weak self] chats in
            var found: [String: SavedChat] = [:]
            for chat in chats {
                guard let place = chat.place, let window = place.window,
                      NSRunningApplication(processIdentifier: place.pid)?.bundleIdentifier == place.app else { continue }
                let key = Self.key(place.pid, window)
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

    /// Window events (focus moving between an app's windows, a window closing), heard only while a note is stuck to
    /// a window: no watching loop, only what Petal's Accessibility observers already say.
    func listenIfNeeded() {
        let wanted = notesOn && notes.contains { $0.attached }
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
            guard notesOn, event.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            frontChanged(event.pid, event.window)
        case .closed:
            guard let window = event.window else { return }
            for note in notes where note.place?.window == window { note.windowGone = true }
            updateReady()
            listenIfNeeded()
        default:
            break
        }
    }

    private func appCameForward(_ running: NSRunningApplication) {
        let pid = running.processIdentifier
        guard notesOn, pid != ProcessInfo.processInfo.processIdentifier, notes.contains(where: { $0.attached }) else { return }
        Self.frontWindow(of: pid) { window, _ in
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.frontChanged(pid, window)
        }
    }

    /// Another window is in front: an open note stuck elsewhere steps away; a note stuck to this one, that was open
    /// when the person left or is done, comes back (without taking the keyboard from the app).
    private func frontChanged(_ pid: pid_t, _ window: CGWindowID?) {
        lastFront = (pid, window)
        if let pending = pendingOpen, let place = pending.place {
            if place.matches(pid: pid, window: pending.windowGone ? nil : window) {
                pendingOpen = nil
                // After the app has finished coming forward, so its window taking focus doesn't close the note; and
                // only if nothing else was opened meanwhile and the window is still in front.
                let ticket = pendingTicket
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard ticket == self.pendingTicket, self.inFront(place) else { return }
                    self.present(pending, key: true, fromIcon: true)
                }
                return
            }
            if pid != place.pid { cancelPending() }   // the person went to another app meanwhile
        }
        if isOpen, current.attached, let place = current.place, !place.matches(pid: pid, window: window) {
            stepAway()
        }
        if !isOpen, let note = notes.first(where: { ($0.away || $0.ready) && $0.attached && $0.place?.matches(pid: pid, window: window) == true }) {
            present(note, key: false, fromIcon: true)
        }
    }

    /// The note's window is the one in front, as far as Petal has heard.
    private func inFront(_ place: NotePlace) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == place.pid else { return false }
        guard let front = lastFront else { return true }
        return place.matches(pid: front.pid, window: front.window)
    }

    /// A note waiting for its window to come forward isn't opened after all (nor its window brought forward again).
    func cancelPending() {
        pendingOpen = nil
        pendingTicket += 1
        NoteFocus.cancel()
    }

    private func stepAway() {
        closeReason = .stepAway
        close()
    }

    /// The panel closed: on purpose (×, Escape, the AI button), stepping away, or a click elsewhere. A click
    /// elsewhere in the note's own window puts it away; going to another window, it comes back with this one.
    func closed() {
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
                guard !self.isOpen || self.current !== note, let place = note.place,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == place.pid,
                      let front = self.lastFront, place.matches(pid: front.pid, window: front.window) else { return }
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
        cancelPending()
        guard !note.windowGone, let running = NSRunningApplication(processIdentifier: place.pid), !running.isTerminated else {
            return present(note, key: true)
        }
        // Taken now, before any mode's countdown: anything opened, closed or turned off meanwhile cancels it.
        let ticket = pendingTicket
        let bring = {
            guard ticket == self.pendingTicket, self.notesOn else { return }
            // Its window is in front already: nothing to wait for.
            if self.inFront(place), self.lastFront?.window == place.window { return self.present(note, key: true, fromIcon: true) }
            self.pendingOpen = note
            // If the window never says it's in front (another Desktop, a slow app), it's asked once more; the note
            // opens only when its window really is in front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard ticket == self.pendingTicket, self.pendingOpen === note else { return }
                self.pendingOpen = nil
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == place.pid else { return }
                Self.frontWindow(of: place.pid) { window, _ in
                    guard ticket == self.pendingTicket, place.matches(pid: place.pid, window: window),
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == place.pid else { return }
                    self.lastFront = (place.pid, window)
                    self.present(note, key: true, fromIcon: true)
                }
            }
            Self.bringForward(pid: place.pid, window: place.window, app: running.bundleURL)
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

/// Which window a note is stuck to, under the panel's header: the app's icon and the window's title.
struct NotePlaceLine: View {
    let place: NotePlace
    let gone: Bool

    var body: some View {
        HStack(spacing: 6) {
            AppIconView(id: place.app, size: 14)
            Text(gone ? "\(place.appName) · window closed" : [place.appName, place.title].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .help("This chat is stuck to this window: it looks at it, wherever you go.")
    }
}

/// Which request to bring a note's window forward is the newest: a counter behind a lock, so cancelling reaches
/// it at once from any thread (never waiting behind a slow Accessibility call on the window queue).
enum NoteFocus {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var newest = 0

    /// A new request's number; every older one stops.
    static func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        newest += 1
        return newest
    }

    static func cancel() { _ = next() }

    /// Still the newest: checked right before every activate and raise.
    static func current(_ request: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return newest == request
    }
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
