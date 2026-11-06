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

    // MARK: Which note

    /// The note for the window in front: the one stuck to it, one kept from before (Petal restarted), or a new one.
    /// The window is looked up off the main thread (Accessibility may wait on the app).
    func noteForFront(_ done: @escaping @MainActor (StickyNote) -> Void) {
        let me = ProcessInfo.processInfo.processIdentifier
        guard notesOn, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me,
              front.activationPolicy == .regular else { return done(looseNote) }
        let pid = front.processIdentifier
        Self.frontWindow(of: pid) { window, title in
            self.lastFront = (pid, window)
            done(self.note(for: front, window: window, title: title))
        }
    }

    /// The note not stuck to any window (no app in front, or sticky notes off).
    var looseNote: StickyNote {
        if let loose = notes.first(where: { $0.place == nil }) { return loose }
        let note = StickyNote()
        notes.append(note)
        return note
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
        let place = NotePlace(pid: pid, app: front.bundleIdentifier ?? "", appName: front.localizedName ?? "",
                              window: window, title: title, mode: dock?.mode?.id ?? "", desktop: dock?.desktop)
        let note = StickyNote()
        // A chat this window had before Petal last started, carried on.
        if let window, let saved = savedPlaces.removeValue(forKey: Self.key(pid, window)) {
            note.agent.restore(saved, switchProvider: false)
            note.place = NotePlace(pid: pid, app: place.app, appName: place.appName, window: window,
                                   title: title.isEmpty ? saved.place?.title ?? "" : title, mode: saved.place?.mode ?? place.mode,
                                   desktop: saved.place?.desktop ?? place.desktop)
        } else {
            note.place = place
        }
        notes.append(note)
        prune()
        listenIfNeeded()
        return note
    }

    /// Notes nobody can come back to (their window gone, idle, read) are let go: they're kept in Chats.
    private func prune() {
        notes.removeAll { $0 !== current && $0.windowGone && !$0.agent.running && !$0.ready && $0.agent.waiting == nil }
        let idle = notes.filter { $0 !== current && !$0.agent.running && !$0.ready && $0.agent.waiting == nil && $0.place != nil }
        for old in idle.dropLast(30) { notes.removeAll { $0 === old } }
    }

    static func key(_ pid: pid_t, _ window: CGWindowID) -> String { "\(pid)-\(window)" }

    /// The focused window of an app, its number and title, off the main thread.
    static func frontWindow(of pid: pid_t, _ done: @escaping @MainActor (CGWindowID?, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
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
            self?.savedPlaces = found
        }
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
            guard event.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
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
        if let pending = pendingOpen, pending.place.map({ $0.matches(pid: pid, window: pending.windowGone ? nil : window) }) == true {
            pendingOpen = nil
            // After the app has finished coming forward, so its window taking focus doesn't close the note.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.present(pending, key: true, fromIcon: true) }
            return
        }
        if isOpen, current.attached, let place = current.place, !place.matches(pid: pid, window: window) {
            stepAway()
        }
        if !isOpen, let note = notes.first(where: { ($0.away || $0.ready) && $0.attached && $0.place?.matches(pid: pid, window: window) == true }) {
            present(note, key: false, fromIcon: true)
        }
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

    /// A note waiting for room starts once fewer than `atOnce` work.
    func startWaiting() {
        for note in notes where note.agent.waiting != nil && working < Self.atOnce { note.agent.runWaiting() }
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
    /// opens on it. False when no note of that app is waiting.
    func openReady(app bundleID: String) -> Bool {
        guard let note = notes.first(where: { $0.ready && $0.place?.app == bundleID }), let place = note.place else { return false }
        go(to: note, place: place)
        return true
    }

    /// Brings a note's window forward (switching to its mode first when it's in another) and opens the note on it.
    func go(to note: StickyNote, place: NotePlace) {
        let app = PetalApp.shared
        app.popups.dismissCard()
        guard !note.windowGone, let running = NSRunningApplication(processIdentifier: place.pid), !running.isTerminated else {
            return present(note, key: true)
        }
        let bring = {
            // Its window is in front already: nothing to wait for.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == place.pid, let front = self.lastFront,
               front.pid == place.pid, front.window == place.window {
                return self.present(note, key: true, fromIcon: true)
            }
            self.pendingOpen = note
            // Shown anyway if the window never says it's in front (another Desktop, a slow app).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if self.pendingOpen === note { self.pendingOpen = nil; self.present(note, key: true, fromIcon: true) }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let window = Windows.windows(of: place.pid).first { $0.id == "\(place.pid)-w\(place.window ?? 0)" }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let window { Windows.focus(window, onScreen: app.docks.isOnScreen(window)) } else { Windows.bringForward(running) }
                    }
                }
            }
        }
        let here = app.docks.focusedDock
        if !place.mode.isEmpty, place.mode != here?.mode?.id, app.config.modes.contains(where: { $0.id == place.mode }),
           let desktop = here?.desktop {
            app.requestMode(place.mode, desktop: desktop, then: bring)
        } else {
            bring()
        }
    }

    /// "Open here": the note, over this dock, without going to its window or mode.
    func openHere(_ id: UUID) {
        PetalApp.shared.popups.dismissCard()
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
                Image(nsImage: Apps.icon(card.bundleID)).resizable().frame(width: 28, height: 28)
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
            Image(nsImage: Apps.icon(place.app)).resizable().frame(width: 14, height: 14)
            Text(gone ? "\(place.appName) · window closed" : [place.appName, place.title].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .help("This chat is stuck to this window: it looks at it, wherever you go.")
    }
}
