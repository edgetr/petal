import AppKit
import Observation
import SwiftUI

/// Petal Notes on the screen (`notes`): the person's own writing on paper, stuck to places (a sentence, a tab, a
/// window, all of an app, a file in any app, a Desktop). On a window, notes rest as tabs on its right edge at the
/// height of their line (EdgeLayout); clicking a tab shows or hides its note beside the window, open to write in;
/// clicking away folds it. A note on a Desktop sits on that Desktop. Petal reads what's in front off the main thread
/// (the window, its browser tab, the file it shows, where a sentence is), never by a guess (NoteMatch).
@MainActor @Observable
final class NoteDesk {
    let store = NoteStore()
    /// Helpers in notes (@Petal), watchers, chains, notes coming back and morning notes.
    let helpers = NoteHelpers()

    /// The helpers know their desk (its store, this Mac's id) from the first moment, started or not: what they
    /// decide for the note tools and Petal's viewer (which notes a caller may read) never runs without the store.
    init() { helpers.desk = self }
    /// Notes showing, each folded, open or turned over (by paper key). Opening or folding one changes which
    /// pictures are on screen (NotePictures' retry).
    var faces: [String: PaperFace] = [:] { didSet { NotePictures.shared.visibilityChanged() } }
    /// The open note with the keyboard.
    var keyboard: String?
    /// Each open note's writing's height.
    var heights: [String: CGFloat] = [:]
    /// Notes of the window in front: the place of each that fits (by paper key), and the passages found there.
    private(set) var here: [String: Int] = [:]
    private(set) var found: [String: Bool] = [:]
    /// The tab a pointer is over (by its first note's key).
    var hovered: String?

    /// This Mac's own notes state: read off the main thread at start (`ready` once it and the folder are in).
    @ObservationIgnored var local = NoteLocal()
    /// Local state read and the notes folder resolved: notes work from then on.
    @ObservationIgnored private(set) var ready = false
    /// The notes folder as last resolved for the `notesFolder` setting (NoteShelf.cachedRoot).
    @ObservationIgnored private var rootCache: (setting: String, root: URL)?
    @ObservationIgnored private var panels: [String: NotePanel] = [:]
    @ObservationIgnored private var tabPanels: [String: EdgeTabPanel] = [:]
    /// Tab and pin panels no note uses now, hidden and kept to be used again. A panel that was ever on the screen
    /// stays alive as long as it stays ordered in (it's hidden by going clear, never ordered out), so one let go of
    /// would be a window kept for nothing; and a new one costs a few milliseconds each time a window comes forward.
    @ObservationIgnored private var spareTabs: [EdgeTabPanel] = []
    @ObservationIgnored private var sparePins: [PinPanel] = []
    @ObservationIgnored private(set) var scene: NoteScene?
    /// The private apps' generation the cached scene was filtered against: every reuse filters it again.
    @ObservationIgnored private var scenePrivacy = 0
    /// The front window's frame (Accessibility's: top-left origin) and its read.
    @ObservationIgnored private(set) var frame: CGRect?
    @ObservationIgnored private var front: ClaudePanel.FrontRead?
    @ObservationIgnored private var lines: [String: CGFloat] = [:]
    /// Each passage found on the window in front: its words' bounds (Accessibility's coordinates).
    @ObservationIgnored private var passageRects: [String: CGRect] = [:]
    @ObservationIgnored private var pinPanels: [String: PinPanel] = [:]
    /// Each open editor: to save what's typed now (on quit, or as it closes), and put pictures in.
    @ObservationIgnored var editors: [String: NoteEditorHandle] = [:]
    @ObservationIgnored private var looks = 0 { didSet { Self.lookNow.set(looks) } }

    /// `looks` as a scan on its own queue sees it: a scan whose look is gone by the time it starts doesn't traverse.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func set(_ new: Int) { lock.withLock { value = new } }
        var now: Int { lock.withLock { value } }
    }
    nonisolated static let lookNow = Counter()

    /// Passage scans and measurements: a queue of their own, so restoring or narrowing windows never waits behind one.
    nonisolated static let passageQueue = DispatchQueue(label: "petal.notes.passages", qos: .utility)
    @ObservationIgnored private var lookSoon: DispatchWorkItem?
    @ObservationIgnored private var listening = false
    /// Windows narrowed for an open note: their frame from before and the one Petal gave them.
    /// What was in front when the quick question opened, for Stick here.
    private(set) var captured: (scene: NoteScene, read: ClaudePanel.FrontRead, url: String, name: String, privacy: Int)?
    @ObservationIgnored private var ghost: NSPanel?
    /// Made just now and still empty: let go of if it's put away empty (folded or hidden; never when it's only
    /// handed to its other editor, `handOff`).
    @ObservationIgnored var fresh: Set<String> = []
    /// What each fresh note was made with (the words selected, as its quote): one still saying only that is untouched.
    @ObservationIgnored private var madeWith: [String: String] = [:]
    /// Notes opened on their own (from the Petal Notes window or a notebook's stack), by paper key: one record each,
    /// everything about it together, so it moves with its paper as one (`rekey`). Never kept past this run.
    @ObservationIgnored private(set) var standalone: [String: Standalone] = [:]

    struct Standalone {
        /// Where the paper's top-left corner is (AppKit's coordinates).
        var corner: CGPoint
        /// Opened from the Petal Notes window: Escape gives that window the keyboard back.
        var fromLibrary: Bool
    }

    nonisolated static let queue = DispatchQueue(label: "petal.notes.look", qos: .userInitiated)
    /// Narrowing a window for an open note: a newer turn (the note folded, notes off, quitting) makes one still
    /// waiting stand down.
    nonisolated static let roomTurn = Generation()

    var app: PetalApp { PetalApp.shared }
    var on: Bool { ready && app.config.bool("notes") }

    /// Notes take a change from the person or a tool (a new note, an editor, a paste, a move, a tool's call), on a
    /// paper's own panel, in the Petal Notes window and in Petal's viewer alike, only once they're ready: the store's
    /// `notesReady` (its folder entered: the old one drained, this Mac's journal put back, its first read in, what was
    /// pending replayed), at launch as on every switch. Else nothing is done, and it's said plainly.
    func takesChanges() -> Bool {
        guard acceptsChanges else { say(NoteStore.gettingReady); return false }
        return true
    }

    /// The same, asked without saying anything (what a view shows as read only meanwhile: Petal's viewer's margin).
    /// The store's readiness is the whole of it: its folder is entered only after this Mac's notes state and the
    /// folder were resolved (`ready`), so nothing more is asked here.
    var acceptsChanges: Bool { store.notesReady }
    var glass: Bool { app.config.string("notesLook") == "glass" }
    var defaultNotebook: String {
        let name = app.config.string("notesNotebook")
        return name.isEmpty ? NoteShelf.inbox : name
    }

    // MARK: Starting

    /// How a note's file and identity changing reach everything that shows or holds it (the desk's panels and
    /// records, Petal's viewer's margins: `rekey`, `identityChanged`), and what's kept by an id becomes lasting.
    /// Part of `start`; `Petal --viewer-check` installs these alone (it starts nothing else).
    func hookStore() {
        store.onRekey = { [weak self] old, paper in self?.rekey(old, to: paper) }
        // An id now in its file: what's kept by it is lasting (written to disk) from now on.
        store.onIDLanded = { [weak self] _ in
            guard let self else { return }
            self.local.save(pending: self.store.pendingIDs)
        }
        store.onIdentity = { [weak self] old, holder, new in
            guard let self else { return }
            self.identityChanged(holder: holder, new)
            self.local.rekeyID(old, holder: holder, new)
            self.local.save(pending: self.store.pendingIDs)
        }
    }

    func start() {
        // Writing a Petal before this one accepted and never saw land: put back first (NoteJournal.recover), from the
        // journal's own queue to the notes' queue.
        // File names are made from titles only after the vault's redaction (never a secret in a name); while the
        // vault can't be read, a plain name. And the names Petal made so, known again.
        NoteStore.nameRedactor = { text in VaultIndex.settled { $0.unreadable ? nil : $0.redacted(text) } ?? nil }
        store.onChange = { [weak self] in self?.refresh() }
        helpers.start(self)
        watchApps()
        // The one visibility signal for missing pictures: papers revealed and open now.
        NotePictures.shared.visible = { [weak self] in self?.picturesOnScreen() ?? [] }
        hookStore()
        store.onProblem = { [weak self] text in self?.say(text) }
        // Which Desktop each screen shows, followed on Space and screen changes whether or not Accessibility is
        // allowed (those notifications don't need it; WindowEvents' stop with the permission): NoteShelf.spaceSignals.
        let spaceChanged = { [weak self] in
            guard let self, NoteShelf.spaceSignals(notesOn: self.on, accessibility: WindowEvents.shared.live) else { return }
            self.refreshSpaces()
            self.lookAgain(after: 0.2)
        }
        spaceTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { spaceChanged() }
        })
        spaceTokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { spaceChanged() }
        })
        // Accessibility taken away: nothing tracks the windows notes are on, so they hide at once; given back, they
        // show again only after a fresh read of what's in front (NoteShelf.onPermission).
        WindowEvents.shared.onLive("papernotes") { [weak self] live in
            guard let self else { return }
            let step = NoteShelf.onPermission(live: live)
            if step.hide { self.concealWindowNotes() }
            if live, step.freshRead { self.awaitingRead = true; self.lookAgain(after: 0.1) }
        }
        // Only an editor with typing not saved yet fences its note against a read of the folder (an idle one takes
        // another Mac's version at once).
        store.keepAlive = { [weak self] key in NoteShelf.fenceEditor(dirty: self?.editors[key]?.busy() == true) }
        Self.queue.async { Self.recoverNarrowed() }
        // Mail drafts' staged pictures a Petal before left behind (it quit before their share finished), older than an hour.
        DispatchQueue.global(qos: .utility).async { NoteDrop.sweepStaging() }
        // This Mac's notes state and the notes folder, read and resolved off the main thread (the folder may be in
        // iCloud Drive): only then are notes read, watched and shown.
        let setting = app.config.string("notesFolder")
        NoteStore.io.async {
            let loaded = NoteLocal.load()
            let root = NoteStore.rootFolder(setting: setting)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.local = loaded
                    self.rootCache = (setting, root)
                    // The folder is entered the one way (NoteStore.switchRoot), as at every later switch: this Mac's
                    // journal put back (at launch all of it: notes, canvas edits, cover fields), then its first read,
                    // then what was pending replayed, each step started by the one before. Notes take no change, and
                    // no tool reads them, until the last (`takesChanges`).
                    self.ready = true
                    // Petal's viewer's margins are read only until the folder is entered, as on every switch.
                    self.app.viewers.folderSwitching(true)
                    self.store.switchRoot(to: root, launch: true) {
                        self.app.viewers.folderSwitching(false)
                        self.look()
                        self.followFolderSetting()
                    }
                    self.settingsChanged()
                }
            }
        }
    }

    /// For `Petal --helpers-check` only: the desk's own start without the parts that watch the person's apps, windows
    /// and Desktops (nothing is looked at, shown or narrowed). The real store, its sessions and journal, entered the
    /// one way (`switchRoot`, as at launch); the helpers started on it; a change of the notes heard as `refresh`
    /// hears it for them (their held results tried again, what waited for a place asked again).
    func startHeadless(root: URL, then done: @escaping @MainActor () -> Void) {
        guard Headless.on else { return }
        NoteStore.nameRedactor = { text in VaultIndex.settled { $0.unreadable ? nil : $0.redacted(text) } ?? nil }
        store.onChange = { [weak self] in
            self?.helpers.applyHeld()
            self?.helpers.placedNow()
        }
        helpers.start(self)
        hookStore()
        store.onProblem = { [weak self] text in self?.say(text) }
        let setting = app.config.string("notesFolder")
        NoteStore.io.async {
            let loaded = NoteLocal.load()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.local = loaded
                    self.rootCache = (setting, root)
                    self.ready = true
                    self.store.switchRoot(to: root, launch: true) { done() }
                }
            }
        }
    }

    /// `notes`, `notesLook` or `notesFolder` changed (or any setting did).
    func settingsChanged() {
        followFolderSetting()
        // Petal's viewer: its margin and the editor open there go with notes off, and come back with notes on.
        app.viewers.notesChanged()
        // Mission Control from the shared watcher, needed while notes are on (whichever dock is chosen).
        MissionControlWatch.shared.subscribe("notes") { [weak self] open in self?.missionControl(open) }
        MissionControlWatch.shared.need("notes", on && !Headless.on)
        if on && !listening {
            listening = true
            WindowEvents.shared.listen("papernotes") { [weak self] event in self?.event(event) }
            // Turned on: what's in front read again, and the Desktops read and placed (NoteShelf.onEnable).
            let enable = NoteShelf.onEnable()
            if enable.look { look() }
            if enable.desktops { refreshSpaces() }
        } else if !on && listening {
            listening = false
            WindowEvents.shared.stopListening("papernotes")
            stopWatchingPassages()
            for editor in editors.values { editor.flush() }
            hideAll()
            // Notes off: every window narrowed for one gets its width back (unless the person changed it since).
            giveBackAll {}
        }
        for panel in panels.values { panel.refresh() }
        // A browser showing another tab says so only through its title: heard only while a note is on a page.
        WindowEvents.shared.titles("papernotes", on && (pagesStuck || windowsStuck))
    }

    private func event(_ event: WindowEvents.Event) {
        // The window shown losing the front: its notes hide at once (clear and mouse-through), narrowing waiting for
        // it is cancelled, and nothing shows again until the new front window's read is in (NoteShelf.concealOnFocus).
        let change: NoteShelf.FocusChange? = switch event.kind {
        case .activated: .activated
        case .focused: .focused
        case .closed, .minimized, .hidden, .quit: .gone
        default: nil
        }
        if let change, NoteShelf.concealOnFocus(change, pid: event.pid, window: event.window, shownPID: scene?.window != nil ? scene?.pid : nil,
                                                 shownWindow: scene?.window, own: getpid()) {
            concealWindowNotes()
        }
        // The person went to another app before a paper waiting for the keyboard showed: it doesn't take it.
        // Focus going elsewhere before a paper waiting for the keyboard showed: its request goes, unless that's the
        // app and window Petal is bringing forward for it.
        if event.kind == .activated || event.kind == .focused, event.pid != getpid() {
            keyboardWanted.focusMoved(pid: event.pid, window: event.window)
        }
        // A window's title changed (in front or behind): anchors with that very window take it.
        if event.kind == .titleChanged, windowsStuck, let window = event.window, let element = event.element {
            followTitle(pid: event.pid, window: window, element: element)
        }
        // Another tab in the browser window shown: its tab and passage notes hide at once, until its tab is read again.
        if NoteShelf.tabReread(switched: event.kind == .tabSwitched || event.kind == .titleChanged, eventPID: event.pid, eventWindow: event.window,
                               shownPID: scene?.pid, shownWindow: scene?.window, browser: scene?.tab != nil) {
            awaitingTab = true
            // A read already under way (of the tab before) is stale from now on: it can't undo the hiding.
            looks = NoteShelf.hidingLook(looks)
            layout()
        }
        switch event.kind {
        case .moved, .resized: lookAgain(after: 0.03)
        case .activated, .focused, .closed, .titleChanged, .tabSwitched, .created, .minimized, .unminimized, .shown, .hidden, .quit: lookAgain(after: 0.12)
        case .space, .screens: lookAgain(after: 0.2); refreshSpaces()
        // Mission Control: the dock's own state, which follows it (`missionControl(_:)`), not these events alone.
        default: break
        }
    }

    /// Notes on the window that was in front: hidden now, and kept hidden (`awaitingRead`) until `apply` has the new
    /// front window's read; Desktop notes stay.
    private func concealWindowNotes() {
        awaitingRead = true
        // A read already under way (of the window left behind) is stale from now on.
        looks = NoteShelf.hidingLook(looks)
        // Narrowing waiting for it cancelled, and every narrowed window's width given back now (NoteShelf.onHide).
        if NoteShelf.onHide().giveBack { giveBackAll {} }
        // Hidden by where each is shown now (a paper shown by the window, not one shown on the Desktop), then the
        // Desktop placed again by the validated placement: a note also stuck to the Desktop showing moves there.
        for (_, panel) in panels where !panel.desktop { panel.conceal() }
        for panel in tabPanels.values { panel.conceal() }
        for panel in pinPanels.values { panel.conceal() }
        placeDesktop()
    }

    /// Set by a focus change, cleared by the next read applied: layout shows no window's notes meanwhile.
    @ObservationIgnored private var awaitingRead = false

    func lookAgain(after delay: Double) {
        lookSoon?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.look() }
        lookSoon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hideAll() {
        // Notes opened on their own are put away with the rest.
        for key in standalone.keys { faces[key] = nil }
        standalone = [:]
        watchPeople()
        for panel in panels.values { panel.conceal() }
        for panel in tabPanels.values { panel.conceal() }
        for panel in pinPanels.values { panel.conceal() }
    }

    /// Petal is about to quit (`applicationShouldTerminate`, which answers later): what's typed is handed to each
    /// note's session, then every session is drained and every narrowed window given back, off the main thread, for
    /// up to 10 seconds; then `done` (on the main thread) lets Petal go. The main thread never waits on the file or
    /// window queue.
    func prepareToQuit(then done: @escaping @MainActor () -> Void) {
        quitWaiters.append(done)
        guard !quitting else { return }
        quitting = true
        // Nothing new from here: no window events, no reads under way counted, no narrowing.
        if listening {
            listening = false
            WindowEvents.shared.stopListening("papernotes")
        }
        lookSoon?.cancel()
        looks += 1
        stopWatchingPassages()
        Self.roomTurn.cancel()
        for editor in editors.values { editor.flush() }
        // The journal holds every accepted edit and paste: once its queue is done, nothing is lost, whatever the
        // notes' folder (iCloud) does in the time it's given.
        let journal = DispatchGroup()
        journal.enter()
        NoteJournal.queue.async { journal.leave() }
        let group = DispatchGroup()
        group.enter()
        store.drain { group.leave() }
        group.enter()
        giveBackAll { group.leave() }
        DispatchQueue.global(qos: .userInitiated).async {
            journal.wait()
            // The drain clears journal entries as their writes land (on the journal's queue): waited for too, once the
            // drain is done or its time is up, so what it cleared is cleared.
            if group.wait(timeout: .now() + 10) == .success { NoteJournal.queue.sync {} }
            // On the run loop, not the main dispatch queue: AppKit is waiting for this answer inside `terminate`, and
            // if that was called from a main-queue block, the queue runs nothing until it returns (PetalApp.quit).
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    let waiting = self.quitWaiters
                    self.quitWaiters = []
                    for waiter in waiting { waiter() }
                }
            }
        }
    }

    @ObservationIgnored private var quitting = false
    @ObservationIgnored private var quitWaiters: [@MainActor () -> Void] = []

    /// Petal quits without asking first (applicationWillTerminate only): what's typed is handed on and the drain
    /// started, never waited for.
    func stop() {
        guard !quitting else { return }
        prepareToQuit {}
    }

    /// The notes folder the setting asks for now (the latest asked): switched to unless it's the one in use; while a
    /// switch is under way, it's asked again when that switch is done (NoteShelf.nextRoot), so a change made
    /// meanwhile is never forgotten.
    private func followFolderSetting() {
        guard ready else { return }
        let setting = app.config.string("notesFolder")
        // The folder for this setting, as last resolved; the setting changed, resolved again off the main thread.
        guard let wanted = NoteShelf.cachedRoot(setting: setting, cached: rootCache) else {
            guard resolvingRoot != setting else { return }
            resolvingRoot = setting
            NoteStore.io.async {
                let root = NoteStore.rootFolder(setting: setting)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.resolvingRoot = nil
                        self.rootCache = (setting, root)
                        self.followFolderSetting()
                    }
                }
            }
            return
        }
        if let next = NoteShelf.nextRoot(wanted: wanted, current: store.root, switching: store.switching) { switchFolder(to: next) }
    }

    @ObservationIgnored private var resolvingRoot: String?

    /// Another notes folder: what's typed is saved into the folder it was typed in (each note's session, drained off
    /// the main thread), every open note and editor of the old folder is put away and every window narrowed for one
    /// gets its width back (narrowing under way cancelled first), then the new folder's notes come.
    func switchFolder(to root: URL) {
        lookSoon?.cancel()
        looks += 1
        giveBackAll {}
        // Petal's viewer first: what's typed in a margin is saved and its editor closed before the store stops taking
        // changes, and the margin stays read only until the new folder is ready.
        // The helpers' runs, looks and summons for this folder's notes end with it.
        helpers.folderSwitching()
        app.viewers.folderSwitching(true)
        // Every editor of the old folder sealed: its composition committed, its text no longer editable, what's typed
        // saved into the folder it was typed in. Nothing can change after it.
        for editor in editors.values { editor.seal() }
        editors = [:]
        for panel in panels.values { panel.conceal() }
        for panel in tabPanels.values { spareTab(panel) }
        for pin in pinPanels.values { sparePin(pin) }
        panels = [:]
        tabPanels = [:]
        pinPanels = [:]
        faces = [:]
        here = [:]
        keyboard = nil
        fresh = []
        store.switchRoot(to: root) { [weak self] in
            self?.app.viewers.folderSwitching(false)
            self?.look()
            self?.followFolderSetting()
        }
    }

    /// Something couldn't be done to the notes' files: said by the AI button for a moment.
    /// Said on the paper from its editor (a copy refused).
    func tell(_ text: String) { say(text) }

    /// For `Petal --helpers-check` only: what the desk says (nothing shows headless), as it's said.
    @ObservationIgnored var heard: ((String) -> Void)?
    /// Shows a few words by what the person just clicked (true when it did); else they're said by the AI button.
    @ObservationIgnored private var sayNear: ((String) -> Bool)?

    private func say(_ text: String, about key: String? = nil) {
        heard?(text)
        // Said where the person is looking when whoever asked can show it there (Note by a selection).
        if let near = sayNear, near(text) { return }
        // Said by the AI button of the dock under the pointer (never a window-list lookup on the main thread), else
        // by the note pad, whether or not names show on hover.
        let mouse = NSEvent.mouseLocation
        if app.docks.shown, let dock = app.docks.panels.values.first(where: { $0.screen?.frame.contains(mouse) == true })?.dock
            ?? app.docks.panels.values.first?.dock,
           let slot = ["claude", DockView.padSlot].first(where: { dock.panel?.screenFrame(of: $0) != nil }) {
            app.tooltips.show(text, over: slot, in: dock, always: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.app.tooltips.show(nil, over: slot, in: dock) }
            return
        }
        // No button to say it by (macOS's Dock chosen, no AI and no note pad): on the paper concerned, while it shows
        // open.
        guard let key = key ?? keyboard, faces[key] == .open, isShowing(key), let id = store.paper(key)?.noteID else { return }
        helpers.hints[id] = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { if self.helpers.hints[id] == text { self.helpers.hints[id] = nil } } }
    }

    // MARK: What's in front

    /// Reads the window in front (its browser tab, the file it shows), off the main thread, and shows its notes.
    func look() {
        guard on, !quitting, !Headless.on else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let running = NSWorkspace.shared.frontmostApplication else { return }
        // Petal's own windows (the settings, a page) leave the notes where they are.
        guard running.processIdentifier != me else { return }
        // No note stuck to a window, tab or app: nothing to show on one, and nothing is read.
        let stuck = store.notes.contains { $0.file.places.contains { $0.kind != .desktop && $0.kind != .screen } }
        guard stuck || !here.isEmpty else { return }
        // One read at a time; looks asked for meanwhile are one follow-up, of what's in front by then
        // (NoteShelf.ReadGate): a slow browser's reads never pile up.
        guard reads.request() else { return }
        looks += 1
        let ticket = looks
        Self.read(running, mac: local.mac, tabs: pagesStuck, ticket: ticket, anchors: fileAnchors) { scene, read in
            self.activate(scene, read: read, ticket: ticket)
            if self.reads.finished() {
                self.reads = NoteShelf.ReadGate()
                self.look()
            }
        }
    }

    @ObservationIgnored private var reads = NoteShelf.ReadGate()

    /// A fresh read made the active scene, only while its look is still the current one (hiding notes on a focus
    /// change starts a new look) and its app is still the one in front (NoteShelf.mayBecomeActive): a late read of
    /// the app left behind never shows its notes over the next.
    @discardableResult
    private func activate(_ scene: NoteScene, read: ClaudePanel.FrontRead, ticket: Int) -> Bool {
        guard NoteShelf.mayBecomeActive(.look, ticket: ticket, current: looks, readPID: scene.pid,
                                        frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) else { return false }
        apply(scene, read: read)
        return true
    }

    /// Some note is on a window: its title is followed (NoteShelf.followedTitle), so titles changing are heard.
    private var windowsStuck: Bool { store.notes.contains { $0.file.places.contains { $0.kind == .window } } }

    /// The notes' places that name a file, each once: what a read of what's in front resolves (NoteScene.onFile).
    var fileAnchors: [NoteStick] {
        var seen: Set<String> = []
        return store.notes.flatMap { $0.file.places.filter(ViewerFiles.namesFile) }.filter { seen.insert($0.fileKey).inserted }
    }

    /// Some note is on a page (a tab, or a sentence on a page): browsers' tabs are worth reading.
    private var pagesStuck: Bool {
        store.notes.contains { $0.file.places.contains { $0.kind == .tab || ($0.kind == .passage && !$0.url.isEmpty) } }
    }

    /// What's in front in `running`: its window and tab (ClaudePanel.readFront, the same reads AI notes use), the
    /// file the window shows (AXDocument), and how many of its windows share its title.
    /// `tabs`: read the browser's tab too (AppleScript, which macOS asks the person to allow once per browser): only
    /// when a note is on a page, or one is being made.
    /// An app kept private (`aiNeverLook`) has no file read or offered (its document's name is never read), and
    /// what was read is dropped when it's made private while the read was under way. A file's bookmark is made
    /// here, off the main thread.
    /// `ticket`: the look it's for; gone by the time the app's window would be read further, nothing more is asked of
    /// the app (the answer is stale, and refused when it's used).
    /// `anchors`: the notes' places that name a file (`fileAnchors`): which of them are the file in front is worked out
    /// here, off the main thread, by the one file resolver (NoteScene.onFile).
    static func read(_ running: NSRunningApplication, mac: String, tabs: Bool = true, ticket: Int? = nil, anchors: [NoteStick] = [],
                     _ done: @escaping @MainActor (NoteScene, ClaudePanel.FrontRead) -> Void) {
        let pid = running.processIdentifier
        let app = running.bundleIdentifier ?? ""
        let appName = running.localizedName ?? ""
        let privacy = ClaudePanel.privacy.now
        let quiet = PetalApp.shared.assist.neverLook(app)
        // The screen under the pointer, for the Desktop it shows (read below, off the main thread, when the app has
        // no window in front).
        let mouse = NSEvent.mouseLocation
        let screen = (Screens.all.first { $0.frame.contains(mouse) } ?? Screens.main).flatMap(Spaces.screenID)
        ClaudePanel.readFront(of: running, tabs: tabs) { read in
            queue.async {
                // Stale before the app's window is read further: nothing more asked of it.
                if let ticket, !NoteShelf.readCurrent(ticket: ticket, now: lookNow.now) {
                    let scene = NoteScene(mac: mac, app: app, pid: pid, window: read.window)
                    DispatchQueue.main.async { MainActor.assumeIsolated { done(scene, read) } }
                    return
                }
                let desktop: Int? = read.window == nil && read.none ? screen.flatMap { Spaces.desktops([$0])[$0] } : nil
                var file = ""
                var bookmark = ""
                var fileID = ""
                var twins: Int?
                var person = ""
                var handle = ""
                if let number = read.window, Windows.trusted {
                    let element = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(element, 0.3)
                    let all: [AXUIElement] = Windows.value(element, kAXWindowsAttribute) ?? []
                    if !quiet, ClaudePanel.privacy.current(privacy), let window = all.first(where: { Windows.id(of: $0) == number }),
                       let document: String = Windows.value(window, kAXDocumentAttribute), let url = URL(string: document), url.isFileURL {
                        file = url.path
                        bookmark = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))?.base64EncodedString() ?? ""
                        // The file's own identity too: a note on it, or a sentence in it, is found again wherever it
                        // goes, and a new file at its path is never it (ViewerFiles).
                        fileID = ViewerFileID.of(url.path)?.record(mac: mac) ?? ""
                    }
                    if !read.title.isEmpty { twins = all.filter { (Windows.value($0, kAXTitleAttribute) as String?) == read.title }.count }
                    // The person in a chat app's conversation (never an app kept private): one person or none.
                    if !quiet, PersonRead.isChat(app), ClaudePanel.privacy.current(privacy), let window = all.first(where: { Windows.id(of: $0) == number }) {
                        (person, handle) = Self.person(in: window, title: read.title, app: app, appName: appName)
                    }
                }
                var made = NoteScene(mac: mac, app: app, pid: pid, window: read.window, title: read.title, titleTwins: twins, tab: read.tab, file: file)
                made.fileBookmark = bookmark
                made.person = person
                made.personHandle = handle
                made.fileID = fileID
                // Which notes' places are this very file (a path another file took since is never it; a renamed one is).
                if !file.isEmpty, let front = ViewerFileID.of(file) {
                    made.onFile = ViewerFiles.on(front, anchors, mac: mac, follow: ViewerLoader.follow)
                }
                // Worked out for these places (or, the file unreadable, by path for them): a place added since makes
                // it stale (NoteScene.resolves).
                made.resolved = Set(anchors.map(\.fileKey))
                let scene = made
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        var (scene, read) = Self.filtered(scene, read, since: privacy)
                        // Their vault contact, only by the address the chat shows (exactly one contact with it; the
                        // contacts read off the main thread, PetalApp.paper.contacts); after the privacy filter, so a
                        // private app has none.
                        if !scene.person.isEmpty {
                            scene.personContact = PersonRead.contact(handle: scene.personHandle, contacts: PetalApp.shared.paper.contacts) ?? ""
                        }
                        scene.desktop = desktop ?? Self.desktopShowing(on: Screens.all.first { $0.frame.contains(mouse) } ?? Screens.main)
                        done(scene, read)
                    }
                }
            }
        }
    }

    /// The person in one chat window's conversation, from that window's own header: one person or none, and their
    /// address only from the header element that named them, never the window's title. Off the main thread.
    nonisolated static func person(in window: AXUIElement, title: String, app: String, appName: String) -> (name: String, handle: String) {
        let header = headings(window)
        let name = PersonRead.person(app: app, appName: appName, title: title, headings: header) ?? ""
        return (name, PersonRead.handle(person: name, headings: header) ?? "")
    }

    /// A chat window's header, for the person in it: its Accessibility headings and its toolbar's words, in order,
    /// read breadth first within a small budget (a few hundred elements, a third of a second). Off the main thread.
    nonisolated static func headings(_ window: AXUIElement) -> [String] {
        var out: [String] = []
        var queue: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
        var seen = 0
        let deadline = Date().addingTimeInterval(0.33)
        while !queue.isEmpty, seen < 400, Date() < deadline, out.count < 6 {
            let (element, depth, inToolbar) = queue.removeFirst()
            AXUIElementSetMessagingTimeout(element, 0.2)
            seen += 1
            let role: String = Windows.value(element, kAXRoleAttribute) ?? ""
            let text = { () -> String in
                for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let words: String = Windows.value(element, attribute), !words.trimmingCharacters(in: .whitespaces).isEmpty { return words }
                }
                return ""
            }
            if role == "AXHeading" || (inToolbar && role == kAXStaticTextRole as String) {
                let words = text()
                if !words.isEmpty { out.append(words) }
                continue
            }
            guard depth < 9 else { continue }
            let children: [AXUIElement] = Windows.value(element, kAXChildrenAttribute) ?? []
            for child in children.prefix(60) { queue.append((child, depth + 1, inToolbar || role == kAXToolbarRole as String)) }
        }
        return out
    }

    /// The one final privacy filter, wherever a read of what's in front is used (as it arrives, and again when a
    /// cached one is used later, as Stick here's): an app kept private, now or since `privacy` (the private apps
    /// changed), leaves nothing but itself and its window: no title, tab, address or file.
    static func filtered(_ scene: NoteScene, _ read: ClaudePanel.FrontRead, since privacy: Int) -> (NoteScene, ClaudePanel.FrontRead) {
        guard !ClaudePanel.privacy.current(privacy) || PetalApp.shared.assist.neverLook(scene.app) else { return (scene, read) }
        var read = read
        read.title = ""
        read.tab = nil
        return (scene.privately, read)
    }

    /// `scan`: look for the passages again (not when only the files changed: the person typing in a note).
    /// `fresh`: a new read of what's in front (it ends a wait after a focus change); false for one kept from before.
    private func apply(_ scene: NoteScene, read: ClaudePanel.FrontRead, scan: Bool = true, fresh: Bool = true) {
        if fresh {
            awaitingRead = false
            awaitingTab = false
        }
        let moved = self.scene?.window != scene.window || self.scene?.pid != scene.pid
        let (scene, read) = Self.filtered(scene, read, since: ClaudePanel.privacy.now)
        self.scene = scene
        scenePrivacy = ClaudePanel.privacy.now
        front = read
        frame = read.frame
        var fits: [String: Int] = [:]
        if read.window != nil {
            let papers = store.notes.filter { !$0.file.places.isEmpty }
            let excluded = decideAnchors(papers, scene)
            for paper in papers {
                if let index = NoteMatch.best(paper.file.places, scene, excluding: excluded[paper.key] ?? []) { fits[paper.key] = index }
            }
        }
        // Papers whose place in front was left (another window or tab): an empty new one among them is let go.
        let left = Set(here.keys).subtracting(fits.keys)
        if fits != here { here = fits }
        // Only now that `here` says what's in front: a running helper follows its note's places.
        helpers.placesFollow()
        followTitles(scene, fits)
        followTabs(scene)
        followFiles(scene)
        if moved {
            lines = [:]
            passageRects = [:]
            stopWatchingPassages()
            // Notes that were open on the window left behind fold.
            for (key, face) in faces where face == .open && fits[key] == nil { faces[key] = .folded }
            }
        // Another window or tab in front: an empty new note whose place was left goes (open there, it folds first).
        // Only one that was showing there: a note made for a window still coming forward (a drop on one behind) stays.
        for key in left where self.fresh.contains(key) && placedOnce.contains(key) {
            if faces[key] == .open || faces[key] == .back { faces[key] = .folded }
            if keyboard == key { keyboard = nil }
            letGoIfEmpty(key)
        }
        layout()
        if scan || moved { findPassages(scene) }
        placeDesktop()
    }

    /// A browser window's tab switching: its tab and passage notes stay hidden until a fresh read of it is applied.
    @ObservationIgnored private var awaitingTab = false

    /// The paper's place on the window in front, when its kind is one hidden while a tab is reread.
    private func hiddenForTab(_ key: String) -> Bool {
        guard awaitingTab, let index = here[key], let paper = store.paper(key), paper.file.places.indices.contains(index) else { return false }
        return NoteShelf.hiddenDuringTabRead(paper.file.places[index].kind)
    }

    /// A title change heard for `window` of `pid` (any window, not only the one in front): its title read off the main
    /// thread, then every window anchor with that very identity on this Mac takes it (NoteShelf.followedTitle), fenced
    /// by each note's revision and without touching when it was edited; never for an app kept private.
    private func followTitle(pid: pid_t, window: CGWindowID, element: AXUIElement) {
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        guard !bundle.isEmpty, !app.assist.neverLook(bundle) else { return }
        let mac = local.mac
        guard store.notes.contains(where: { $0.file.places.contains { $0.kind == .window && $0.pid == pid && $0.window == window && $0.mac == mac } }) else { return }
        let carried = Self.Carried(element)
        Self.titleQueue.async {
            let title: String = Windows.value(carried.element, kAXTitleAttribute) ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !self.app.assist.neverLook(bundle) else { return }
                    for paper in self.store.notes where !self.store.readOnly(paper) {
                        let follows = paper.file.places.indices.filter {
                            NoteShelf.followedTitle(paper.file.places[$0], mac: mac, pid: pid, window: window, title: title) != nil
                        }
                        guard !follows.isEmpty else { continue }
                        // One write per note, fenced by the revision it was read at.
                        self.store.change(paper.key, expect: paper.revision, touch: false) { file in
                            for index in follows where file.places.indices.contains(index) && file.places[index].kind == .window { file.places[index].title = title }
                        }
                    }
                }
            }
        }
    }

    private final class Carried: @unchecked Sendable {
        let element: AXUIElement
        init(_ element: AXUIElement) { self.element = element }
    }

    nonisolated private static let titleQueue = DispatchQueue(label: "petal.notes.titles", qos: .utility)

    /// Window anchors confirmed by live identity take the window's current title (NoteShelf.followedTitle), written
    /// through the note's session fenced by its revision, without touching when it was last edited.
    private func followTitles(_ scene: NoteScene, _ fits: [String: Int]) {
        guard !app.assist.neverLook(scene.app) else { return }
        for (key, index) in fits {
            guard let paper = store.paper(key), !store.readOnly(paper), paper.file.places.indices.contains(index),
                  let title = NoteShelf.followedTitle(paper.file.places[index], scene: scene) else { continue }
            store.change(key, expect: paper.revision, touch: false) { file in
                if file.places.indices.contains(index), file.places[index].kind == .window { file.places[index].title = title }
            }
        }
    }

    /// Notes found on the tab in front by its address alone (a Chromium tab after its browser restarted), decided
    /// together: when they all come from one tab before, they take this one as theirs (its id and process from now
    /// on); notes from different old tabs that showed the same page never guess, and fall back to their other places.
    /// Notes whose anchors fit the tab or window in front only by address or title (their browser or app
    /// restarted), decided over every such anchor of every note before any note picks its place
    /// (`NoteMatch.anchors`): all from one old tab or window, they take this one (fenced by revision); else every one
    /// is left out, and each note falls back to its other places.
    private func decideAnchors(_ papers: [PaperNote], _ scene: NoteScene) -> [String: Set<Int>] {
        let decided = NoteMatch.anchors(papers.map(\.file.places), scene)
        for (note, place) in decided.adopt {
            let paper = papers[note]
            guard !store.readOnly(paper) else { continue }
            let adopted = paper.file.places[place].kind == .tab ? NoteMatch.adopt(paper.file.places[place], scene) : NoteMatch.adoptWindow(paper.file.places[place], scene)
            store.change(paper.key, expect: paper.revision, touch: false) { file in
                if file.places.indices.contains(place) { file.places[place] = adopted }
            }
        }
        var excluded: [String: Set<Int>] = [:]
        for (note, place) in decided.excluded { excluded[papers[note].key, default: []].insert(place) }
        return excluded
    }

    /// Tab notes seen surely on their own tab keep its address as it is now (and its title, and whether it's the one
    /// tab with it), so after a restart they're found by where the tab was last, never where it was stuck first.
    /// Not a change of the note's words: its modified time stays.
    private func followTabs(_ scene: NoteScene) {
        let keepWords = !app.assist.neverLook(scene.app)
        for (key, index) in here {
            guard let paper = store.paper(key), paper.file.places.indices.contains(index), !store.readOnly(paper),
                  let next = NoteMatch.followTab(paper.file.places[index], scene, keepWords: keepWords) else { continue }
            store.change(key, expect: paper.revision, touch: false) { file in
                if file.places.indices.contains(index) { file.places[index] = next }
            }
        }
    }

    /// The file in front matched no note: notes stuck to files (or sentences in them) follow their bookmarks off the
    /// main thread, so a file moved or renamed in any app keeps its notes. Once per file shown.
    @ObservationIgnored private var followedFile = ""

    private func followFiles(_ scene: NoteScene) {
        guard !scene.file.isEmpty, scene.file != followedFile else { return }
        followedFile = scene.file
        let anchored = store.notes.filter { paper in
            paper.version == nil && !store.readOnly(paper) && paper.file.places.contains { !$0.bookmark.isEmpty && ($0.kind == .file || $0.kind == .passage) }
        }
        // Followed unless a note here is on this very file by its identity (a path that matches while the identity
        // doesn't is no reason not to follow).
        guard !anchored.isEmpty, !here.contains(where: { key, index in
            store.paper(key).map { $0.file.places.indices.contains(index) && NoteMatch.onFrontFile($0.file.places[index], scene) } ?? false
        }) else { return }
        let files = anchored.map { ($0.key, $0.file, $0.revision) }
        Self.queue.async {
            var changed: [(String, NoteFile, String?)] = []
            for (key, file, revision) in files {
                var file = file
                if NoteStore.followBookmarks(&file) { changed.append((key, file, revision)) }
            }
            guard !changed.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for (key, file, revision) in changed {
                        // Fenced: only onto the note it was read from; changed since (stuck elsewhere, typed in), it
                        // waits for the next time this file is in front.
                        if self.store.change(key, expect: revision, touch: false, edit: { $0.places = file.places }) == nil { self.followedFile = "" }
                    }
                    self.lookAgain(after: 0.05)
                }
            }
        }
    }

    /// Where each passage stuck on this window is, off the main thread: the one place on the window its whole quote
    /// is, told apart by the words before and after it, else none ("passage moved").
    private func findPassages(_ scene: NoteScene) {
        guard scene.window != nil else { return stopWatchingPassages() }
        guard !wantedPassages().isEmpty else { return stopWatchingPassages() }
        // One scan at a time: a request while one runs is one follow-up, for the scene in front by then.
        guard scans.request() else { return }
        scan()
    }

    @ObservationIgnored private var scans = NoteShelf.ScanGate()

    private func wantedPassages() -> [(String, NoteStick)] {
        here.compactMap { key, index -> (String, NoteStick)? in
            guard let paper = store.paper(key), paper.file.places.indices.contains(index), paper.file.places[index].kind == .passage else { return nil }
            return (key, paper.file.places[index])
        }
    }

    private func scan() {
        let wanted = wantedPassages()
        guard let scene, let window = scene.window, !wanted.isEmpty else {
            if scans.finished() { scan() }
            return
        }
        let pid = scene.pid
        let ticket = looks, turn = passageTurn
        finding = true
        rescanned = Date()
        Self.passageQueue.async {
            // Stale before it starts (the window in front changed): no traversal.
            let current = Self.lookNow.now == ticket
            let anchors = current ? Self.passageAnchors(pid: pid, window: window, wanted.map { $0.1 }) : []
            let measured = anchors.map { $0.map(Self.measure) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finding = false
                    if current, ticket == self.looks, turn == self.passageTurn {
                        var states: [String: NoteShelf.PassageState] = [:]
                        for (index, item) in wanted.enumerated() {
                            // Found again by its quote: there (its pin and line), or moved: an explicit state that
                            // clears its line, pin and "found" (never the text's frame).
                            let measure = measured[index]
                            switch NoteShelf.passagePoll(read: measure?.read, quote: item.1.quote, words: measure?.words, rescanned: true) {
                            case .still(let words):
                                self.anchors[item.0] = anchors[index]
                                self.lost[item.0] = nil
                                states[item.0] = .at(words: words, visible: measure?.visible)
                            default:
                                self.anchors[item.0] = nil
                                self.lost[item.0] = Date()
                                states[item.0] = .moved
                            }
                        }
                        self.place(states)
                        self.reconcilePassages()
                    }
                    if self.scans.finished() { self.scan() }
                }
            }
        }
    }

    /// Each passage note's sentence placed by its state (NoteShelf.passagePlacement): at its line with its pin;
    /// above or below the visible text, on that edge with no pin; moved, no line, no pin and not found ("passage
    /// moved").
    private func place(_ states: [String: NoteShelf.PassageState]) {
        guard let frame else { return }
        var found = self.found
        var changed = false
        for (key, state) in states {
            let placed = NoteShelf.passagePlacement(state, window: frame)
            if lines[key] != placed.line || passageRects[key] != placed.pin { changed = true }
            lines[key] = placed.line
            passageRects[key] = placed.pin
            found[key] = placed.found
        }
        if found != self.found { self.found = found; changed = true }
        if changed { layout() }
    }

    /// The elements and ranges where passage notes' sentences were found (this window), measured again on a light
    /// timer while any passage note is on it, so their tabs and pins follow the page as it scrolls. A range that no
    /// longer holds its quote (text put in before it) is found again; found again and not there, it moved.
    @ObservationIgnored private var anchors: [String: PassageAnchor] = [:]
    /// Passages found to have moved: not looked for again until the window or the notes change.
    /// Passages found to have moved, with when they were last looked for: looked for again every 2 s at most while
    /// their note is here (NoteShelf.passageWatch), so one brought back (Undo) comes back.
    @ObservationIgnored private var lost: [String: Date] = [:]
    @ObservationIgnored private var passageTimer: Timer?
    @ObservationIgnored private var measuring = false
    @ObservationIgnored private var finding = false
    /// Bumped whenever watching stops or what's watched changes: measurements still under way are dropped.
    @ObservationIgnored private var passageTurn = 0

    /// The passage notes on the window in front now.
    private var passagesHere: Set<String> {
        Set(here.compactMap { key, index in
            store.paper(key).flatMap { $0.file.places.indices.contains(index) && $0.file.places[index].kind == .passage ? key : nil }
        })
    }

    /// The one place passage watching follows what's placed: whenever placements change (every layout). What's no
    /// longer a passage note here is let go (its anchor and any measurement of it); none left, the watcher stops.
    private func reconcilePassages() {
        let wanted = passagesHere
        let before = Set(anchors.keys).union(lost.keys)
        anchors = anchors.filter { wanted.contains($0.key) }
        lost = lost.filter { wanted.contains($0.key) }
        if Set(anchors.keys).union(lost.keys) != before { passageTurn += 1 }
        guard !wanted.isEmpty, on, listening else { return stopWatchingPassages() }
        if passageTimer == nil {
            passageTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickPassages() }
            }
        }
    }

    private func stopWatchingPassages() {
        passageTimer?.invalidate()
        passageTimer = nil
        anchors = [:]
        lost = [:]
        passageTurn += 1
    }

    /// One tick (NoteShelf.passageWatch): stop, find again, skip while busy, or measure.
    private func tickPassages() {
        guard on, listening else { return stopWatchingPassages() }
        switch NoteShelf.passageWatch(wanted: passagesHere, anchored: Set(anchors.keys), moved: lost, now: Date(), busy: measuring || finding || scans.running) {
        case .stop: stopWatchingPassages()
        case .skip: break
        case .find: if let scene { findPassages(scene) }
        case .measure: measurePassages()
        }
    }

    private func measurePassages() {
        guard !anchors.isEmpty else { return }
        measuring = true
        let watched = anchors
        let quotes = Dictionary(uniqueKeysWithValues: watched.keys.compactMap { key in
            here[key].flatMap { index in store.paper(key).map { (key, $0.file.places[index].quote) } }
        })
        let ticket = looks, turn = passageTurn
        Self.passageQueue.async {
            let measured = watched.mapValues(Self.measure)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.measuring = false
                    guard ticket == self.looks, turn == self.passageTurn else { return }
                    var states: [String: NoteShelf.PassageState] = [:]
                    var relocate = false
                    for (key, measure) in measured {
                        switch NoteShelf.passagePoll(read: measure.read, quote: quotes[key] ?? "", words: measure.words, rescanned: false) {
                        case .still(let words): states[key] = .at(words: words, visible: measure.visible)
                        default: relocate = true
                        }
                    }
                    self.place(states)
                    // A range that no longer holds its quote: found again by quote and context (once a second at most).
                    if relocate, let scene = self.scene, Date().timeIntervalSince(self.rescanned) > 1 { self.findPassages(scene) }
                }
            }
        }
    }

    @ObservationIgnored private var rescanned = Date.distantPast

    /// Where a passage's sentence was found: its text element and the range of its words in it. AXUIElement is a
    /// CF object, read only on `queue`.
    struct PassageAnchor: @unchecked Sendable {
        let element: AXUIElement
        let range: CFRange
    }

    /// A passage's words' bounds now, and the visible part of the scroll area holding them (Accessibility's
    /// coordinates). Off the main thread.
    /// `read`: the text its remembered range holds now (checked against the quote: NoteShelf.passagePoll); never the
    /// whole element's frame for its words.
    nonisolated static func measure(_ anchor: PassageAnchor) -> (words: CGRect?, visible: CGRect?, read: String?) {
        var cf = anchor.range
        var words: CGRect?
        var read: String?
        if let axRange = AXValueCreate(.cfRange, &cf) {
            var raw: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(anchor.element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &raw) == .success {
                read = raw as? String
            }
            raw = nil
            if AXUIElementCopyParameterizedAttributeValue(anchor.element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &raw) == .success,
               let raw, CFGetTypeID(raw) == AXValueGetTypeID() {
                var rect = CGRect.zero
                AXValueGetValue(raw as! AXValue, .cgRect, &rect)
                if rect.height > 1 { words = rect }
            }
        }
        // The scroll area it's in: its frame is the part of the text that shows.
        var visible: CGRect?
        var element = anchor.element
        for _ in 0..<16 {
            guard let parent: AXUIElement = Windows.value(element, kAXParentAttribute) else { break }
            if (Windows.value(parent, kAXRoleAttribute) as String?) == kAXScrollAreaRole as String { visible = Windows.frame(of: parent); break }
            element = parent
        }
        return (words, visible, read)
    }

    /// Where each passage's sentence is in the window: among the window's texts that hold its whole quote, the one
    /// place the words around it fit best (NoteMatch.pick), within half a second. Off the main thread.
    nonisolated static func passageAnchors(pid: pid_t, window number: CGWindowID, _ passages: [NoteStick]) -> [PassageAnchor?] {
        guard Windows.trusted else { return passages.map { _ in nil } }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let all: [AXUIElement] = Windows.value(app, kAXWindowsAttribute) ?? []
        guard let window = all.first(where: { Windows.id(of: $0) == number }) else { return passages.map { _ in nil } }
        var hits: [[(AXUIElement, String)]] = passages.map { _ in [] }
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var seen = 0
        let deadline = Date().addingTimeInterval(0.5)
        while !queue.isEmpty, seen < 4000, Date() < deadline {
            let (element, depth) = queue.removeFirst()
            seen += 1
            let role: String = Windows.value(element, kAXRoleAttribute) ?? ""
            if role == kAXStaticTextRole as String || role == kAXTextAreaRole as String || role == kAXTextFieldRole as String {
                if let value: String = Windows.value(element, kAXValueAttribute), !value.isEmpty {
                    for (index, passage) in passages.enumerated() where !passage.quote.isEmpty && value.contains(passage.quote) { hits[index].append((element, value)) }
                }
            }
            if depth < 60, let children: [AXUIElement] = Windows.value(element, kAXChildrenAttribute) {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        // The window wasn't read whole in time: whatever was found may not be the only place.
        let whole = queue.isEmpty
        return passages.indices.map { index -> PassageAnchor? in
            let passage = passages[index]
            guard whole, let picked = NoteMatch.pick(quote: passage.quote, before: passage.before, after: passage.after, in: hits[index].map(\.1)) else { return nil }
            let (element, value) = hits[index][picked.text]
            let ns = NSRange(picked.range, in: value)
            return PassageAnchor(element: element, range: CFRange(location: ns.location, length: ns.length))
        }
    }

    // MARK: Laying out

    private var primaryHeight: CGFloat { Screens.all.first?.frame.height ?? 0 }

    /// The visible frame (Accessibility's coordinates) of the screen a window is on.
    private func visible(for window: CGRect) -> CGRect? {
        let screens = Screens.all
        guard let screen = NoteRules.screen(for: NoteRules.appKitFrame(window, primaryHeight: primaryHeight), in: screens.map(\.frame)),
              let visible = screens.first(where: { $0.frame == screen })?.visibleFrame else { return nil }
        return CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
    }

    /// The tabs on the window in front, and its notes that are showing beside it.
    func layout() {
        defer { helpers.placedNow() }
        // Notes opened on their own show where they were opened, whatever is in front.
        if !missionControlOpen { placeStandalone() }
        // Mission Control open, or the front window changed and its read isn't in yet: nothing shows meanwhile.
        if missionControlOpen || awaitingRead { return concealUnplaced() }
        defer { reconcileRoom() }
        prunePassageGeometry()
        guard on, let frame, let scene, scene.window != nil else {
            placedBeside = []
            for panel in tabPanels.values { panel.conceal() }
            for panel in pinPanels.values { panel.conceal() }
            concealUnplaced()
            reconcilePassages()
            return
        }
        let now = Date()
        // While a browser's tab is read again, its tab and passage notes stay hidden (tabs, papers and pins).
        let edgeNotes = here.keys.sorted().compactMap { key -> EdgeNote? in
            guard let paper = store.paper(key), !hiddenForTab(key) else { return nil }
            return EdgeNote(id: key, line: lines[key], color: notebookKey(paper.notebook),
                            faded: NoteShelf.faded(modified: paper.file.modified, opened: local.opened?[paper.noteID], now: now))
        }
        let tabs = EdgeLayout.tabs(edgeNotes, height: frame.height)
        // Inside the window's right edge, as the sketch has them; the window's own edge stays in sight beside them.
        let outside = false
        var keep: Set<String> = []
        for tab in tabs {
            let key = tab.ids[0]
            keep.insert(key)
            let panel = tabPanels[key] ?? spareTabs.popLast() ?? EdgeTabPanel(desk: self)
            tabPanels[key] = panel
            panel.show(tab, outside: outside, window: frame, primaryHeight: primaryHeight)
        }
        for (key, panel) in tabPanels where !keep.contains(key) {
            spareTab(panel)
            tabPanels[key] = nil
        }
        edgeTabs = tabs
        let showing = placeBeside()
        // Shown only where its one placement says it belongs now; every other paper hidden.
        for (key, panel) in panels where !showing.contains(key) && !NoteShelf.restsOffWindow(placementNow(key)) { panel.conceal() }
        drawPins(showing)
        reconcilePassages()
    }

    /// The window in front's tabs as last laid out: where a paper with no line of its own would sit.
    @ObservationIgnored private var edgeTabs: [EdgeTab] = []
    /// Where each paper beside a window sat at its last layout there (its top and column, NoteRoom.Was, and whether
    /// it was open), by window: the order they keep down the window, and where one held still stays.
    @ObservationIgnored private var besides: [UInt32: [String: (was: NoteRoom.Was, open: Bool)]] = [:]
    /// The papers placed beside the window in front by the last layout.
    @ObservationIgnored private var placedBeside: Set<String> = []
    /// New notes that have been placed beside their window at least once (an empty one is let go only once its place
    /// is left after that).
    @ObservationIgnored private var placedOnce: Set<String> = []

    /// The notes showing on the window in front, placed beside it the one way (NoteRoom.stack): where the person
    /// left one, it stays; the others at their lines, never over one another. Returns them, in order.
    private func placeBeside() -> [String] {
        guard let frame, let number = scene?.window else { placedBeside = []; return [] }
        let visible = visible(for: frame) ?? frame
        let showing = here.keys.filter { faces[$0] != nil && !hiddenForTab($0) && standalone[$0] == nil }.sorted()
        let was = besides[number] ?? [:]
        var papers: [NoteRoom.Paper] = []
        for key in showing {
            let panel = panel(for: key)
            // Placed by its window (it fits the window in front): not the Desktop's or the screen's, whatever else
            // it's stuck to.
            panel.rest = .window
            let size = panel.paperSize
            // Its line; with none, its tab's place, or higher where it already sat (a new note's tab taking a place
            // above never moves a paper down).
            let tab = edgeTabs.first { $0.ids.contains(key) }?.y ?? EdgeLayout.top
            let top = lines[key] ?? min(tab, was[key]?.was.top ?? tab)
            // Where the person left it, by its window's nearest corner: over the window or anywhere else.
            let moved = spotFrame(key, size: size).map { NoteRules.appKitFrame($0, primaryHeight: primaryHeight) }
            // Held by the pointer, or being written in (open with the keyboard, and open already at the last layout:
            // the moment it opens it still goes around a paper the person moved): it stays still, and the others go
            // around it.
            let held = panel.held || (keyboard == key && faces[key] == .open && was[key]?.open == true)
            papers.append(NoteRoom.Paper(id: key, size: size, top: top, moved: moved, was: was[key]?.was, held: held))
        }
        var record: [String: (was: NoteRoom.Was, open: Bool)] = [:]
        // Each panel keeps its shadow's margin around its paper on the screen: placed where the panel really goes.
        for spot in NoteRoom.stack(window: frame, visible: visible, papers: papers, margin: PaperLook.margin) {
            guard let panel = panels[spot.id] else { continue }
            if let was = spot.was { record[spot.id] = (was, faces[spot.id] == .open) }
            panel.place(paperFrame: NoteRules.appKitFrame(spot.frame, primaryHeight: primaryHeight))
        }
        if besides[number] == nil, besides.count >= 24 { besides = [:] }
        besides[number] = record
        placedBeside = Set(showing)
        placedOnce.formUnion(showing.filter(fresh.contains))
        // Each placed first, then the keyboard for one that waited for it (taking it fits that paper again).
        for key in showing { if let panel = panels[key] { shown(key, panel) } }
        return showing
    }

    /// A paper beside the window in front changed size (opened, its writing grew, a helper's answer came): every
    /// paper there placed again, so the ones below it move with it. False: it isn't placed beside the window now.
    func refitBeside(_ key: String) -> Bool {
        guard on, !missionControlOpen, !awaitingRead, placedBeside.contains(key), frame != nil else { return false }
        let showing = placeBeside()
        guard showing.contains(key) else { return false }
        drawPins(showing)
        return true
    }

    /// Where a paper the person moved sits on the window in front (its NoteSpot, by the window's nearest corner), at
    /// `size`: whole on the screen the spot is on, wherever that is. Nil: nobody moved it (it sits beside its window),
    /// or it isn't placed by the window in front.
    func spotFrame(_ key: String, size: CGSize) -> CGRect? {
        guard let frame, case .window = placementNow(key), let paper = store.paper(key), let spot = local.spots[paper.noteID] else { return nil }
        let window = NoteRules.appKitFrame(frame, primaryHeight: primaryHeight)
        let screen = Screens.all.first { $0.frame.intersects(window) }?.visibleFrame ?? window
        return spot.frame(size: size, window: window, screen: screen, screens: Screens.all.map(\.visibleFrame))
    }

    /// A note re-stuck elsewhere (its winning anchor no longer a passage) lets go of its line, pin and found state
    /// (NoteShelf.passageGeometry): nothing of its old sentence is drawn.
    private func prunePassageGeometry() {
        let passages = passagesHere
        lines = NoteShelf.passageGeometry(lines, passages: passages)
        passageRects = NoteShelf.passageGeometry(passageRects, passages: passages)
        let kept = NoteShelf.passageGeometry(found, passages: passages)
        if kept != found { found = kept }
    }

    /// Whether a paper is on the screen now (its panel revealed, not hidden by going clear).
    func isShowing(_ key: String) -> Bool { panels[key]?.unveiled == true }

    /// Whether a paper is on the screen on a face that shows its watcher's corner (folded or open, not its back).
    func isShowingCorner(_ key: String) -> Bool { isShowing(key) && (faces[key] ?? .folded) != .back }

    /// The pictures on screen: those of papers whose panel is revealed (not hidden by going clear) and open
    /// (NoteShelf.picturesOnScreen), editors and read-only papers alike.
    func picturesOnScreen() -> Set<String> {
        // The desk's papers, and those open in a margin of Petal's viewer whose window is on screen.
        NoteShelf.picturesOnScreen(panels.compactMap { key, panel in
            store.paper(key).map { (panel.unveiled, faces[key] == .open, $0.url.deletingLastPathComponent().path, $0.file.body) }
        } + app.viewers.picturesShown())
    }

    /// The sketch's dashed line in the notebook's color from each showing note to its sentence, wherever the
    /// sentence's bounds are known, and only for a note placed on a passage now.
    private func drawPins(_ showing: [String]) {
        var keep: Set<String> = []
        let passages = passagesHere
        for key in showing where passages.contains(key) {
            guard let rect = passageRects[key], let paper = store.paper(key), let note = panels[key], note.unveiled else { continue }
            keep.insert(key)
            let words = NoteRules.appKitFrame(rect, primaryHeight: primaryHeight)
            let paperFrame = note.frame.insetBy(dx: PaperLook.margin, dy: PaperLook.margin)
            let pin = pinPanels[key] ?? sparePins.popLast() ?? PinPanel()
            pinPanels[key] = pin
            pin.show(from: CGPoint(x: words.maxX, y: words.midY), to: CGPoint(x: paperFrame.minX, y: paperFrame.maxY - 28),
                     color: store.color(of: paper.notebook))
        }
        for (key, pin) in pinPanels where !keep.contains(key) {
            sparePin(pin)
            pinPanels[key] = nil
        }
    }

    /// A tab panel no note uses now: hidden, emptied, and kept to be used again (`spareTabs`).
    private func spareTab(_ panel: EdgeTabPanel) {
        panel.retire()
        spareTabs.append(panel)
    }

    /// A pin no note uses now: hidden and kept to be used again (`sparePins`).
    private func sparePin(_ pin: PinPanel) {
        pin.conceal()
        sparePins.append(pin)
    }

    /// A notebook's color as the tabs name it.
    private func notebookKey(_ notebook: String) -> String { store.color(of: notebook).hex }

    /// Where a paper belongs right now (NoteShelf.placementNow): by the window in front, on a Desktop showing now, or
    /// nowhere.
    func placementNow(_ key: String) -> NoteShelf.Placement {
        let paper = store.paper(key)
        let desktops = paper.map(desktops(of:)) ?? []
        // A window placement counts only once it's fresh: never while a read is awaited (permission lost, focus
        // changed) or its tab is being read again.
        return NoteShelf.placementNow(window: here[key], desktops: desktops, showing: Set(Self.spaces.values),
                                      windowValid: !awaitingRead && !hiddenForTab(key), standalone: standalone[key] != nil,
                                      screen: paper.map(keptOnScreen) ?? false)
    }

    /// Whether a note is kept on this Mac's screen (NoteShelf.onScreen): one of its places is the screen, here.
    func keptOnScreen(_ paper: PaperNote) -> Bool { NoteShelf.onScreen(paper.file.places, mac: local.mac) }

    /// The Desktops a paper shows on: its own Desktop places, and, while it's summoned (coming back, a watcher's hit,
    /// a source picked) and its place isn't in front, the Desktop showing on the main screen.
    func desktops(of paper: PaperNote) -> [Int?] {
        var list = paper.file.places.filter { $0.kind == .desktop }.map(\.desktop)
        if helpers.summoned.contains(paper.key) { list.append(Self.desktopShowing(on: Screens.all.first)) }
        return list
    }

    /// A note was summoned: the Desktops are read (when no note was on one) and it's placed the one way.
    func summoned() {
        if Self.spaces.isEmpty { refreshSpaces() } else { placeDesktop() }
        layout()
    }

    /// Open all on a task (the note's own button, and the Petal Notes window's): its parts through the one opener
    /// (NoteTasks.openAll), a file found by the one file resolver; what couldn't be opened is said.
    func openAll(_ items: [NoteContract.TaskItem]) {
        NoteTasks.openAll(items, mac: local.mac, follow: { ViewerLoader.follow($0) }) { [weak self] in self?.tell($0) }
    }

    /// "Here" for the note tools: placed now (placementNow), or in the margin of Petal's viewer while it has the
    /// keyboard (it's the current place then).
    func hereNow(_ key: String) -> Bool {
        NoteShelf.isHere(placementNow(key)) || app.viewers.front?.shows(key) == true
    }

    /// Everything that may not be seen now hidden (NoteShelf.mayShow): every surface while Mission Control is open,
    /// the window's notes while a new front window's read is awaited, and any paper not where its one placement
    /// says it belongs.
    private func concealUnplaced() {
        for (key, panel) in panels where !NoteShelf.mayShow(placementNow(key), missionControl: missionControlOpen, awaitingRead: awaitingRead) { panel.conceal() }
        if missionControlOpen || awaitingRead {
            for panel in tabPanels.values { panel.conceal() }
            for panel in pinPanels.values { panel.conceal() }
        }
    }

    /// Mission Control (or App Exposé) open, as the dock knows it (its events, and its check that macOS's Dock still
    /// has a window up, for when they don't come): every paper, tab and pin hidden, and nothing shown again until it
    /// ends.
    @ObservationIgnored private(set) var missionControlOpen = false

    func missionControl(_ open: Bool) {
        guard open != missionControlOpen else { return }
        missionControlOpen = open
        if open {
            Self.roomTurn.cancel()
            concealUnplaced()
        } else {
            lookAgain(after: 0.1)
            refreshSpaces()
        }
    }

    private func panel(for key: String) -> NotePanel {
        if let panel = panels[key] { return panel }
        let panel = NotePanel(desk: self, key: key)
        panels[key] = panel
        return panel
    }

    // MARK: Notes on people

    /// Clicking another conversation in a chat app's window says nothing Petal hears (the window is the same, and its
    /// title may not change): while a note is on a person and a chat app is in front, what's in front is read again
    /// every second and a half (one read at a time, through the same gate), so a person's note never stays beside
    /// someone else's conversation.
    @ObservationIgnored private var peopleTimer: Timer?

    /// The vault's contacts (id and name only, never their details), for telling people apart: read off the main
    /// thread when notes start and again at most once a minute while a chat app is in front.
    @ObservationIgnored private(set) var contacts: [(id: String, addresses: [String])] = []
    @ObservationIgnored private var contactsRead: Date?

    func refreshContacts() {
        guard on, !Headless.on, contactsRead.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        contactsRead = Date()
        VaultStore.load { [weak self] result in
            // While the vault can't be read: no contacts, so no person is told apart by one.
            guard let self else { return }
            if case .success(let items) = result {
                self.contacts = items.filter { $0.kind == .contact }.map { (id: $0.id, addresses: [$0[.email], $0[.phone]].filter { !$0.isEmpty }) }
            }
            else { self.contacts = [] }
        }
    }

    func watchPeople() {
        if let front = NSWorkspace.shared.frontmostApplication, PersonRead.isChat(front.bundleIdentifier ?? "") { refreshContacts() }
        let wanted = on && store.notes.contains { $0.file.places.contains { $0.kind == .person } }
        if wanted, peopleTimer == nil {
            peopleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.on, let front = NSWorkspace.shared.frontmostApplication,
                          PersonRead.isChat(front.bundleIdentifier ?? "") else { return }
                    self.refreshContacts()
                    self.look()
                }
            }
        } else if !wanted {
            peopleTimer?.invalidate()
            peopleTimer = nil
        }
    }

    // MARK: Notes opened on their own

    /// Opens a note on its own, open with the keyboard, its top-left corner at `point` (AppKit's coordinates; else
    /// near the middle of the screen under the pointer): from the Petal Notes window or a notebook's stack. It shows
    /// through layout like every paper, and folding it or clicking away puts it away.
    func openStandalone(_ key: String, at point: CGPoint? = nil, fromLibrary: Bool = false) {
        guard on, takesChanges(), let paper = store.paper(key) else { return }
        // Opened counts as touched: a note read often doesn't fade.
        local.opened = (local.opened ?? [:]).merging([paper.noteID: Date()]) { _, new in new }
        local.save(pending: store.pendingIDs)
        let mouse = NSEvent.mouseLocation
        let screen = (Screens.all.first { $0.frame.contains(mouse) } ?? Screens.main)?.visibleFrame ?? .zero
        let corner = point ?? CGPoint(x: screen.midX - PaperLook.openWidth / 2, y: screen.midY + 220)
        // A note in a conflict opens with every other paper of it beside it (all read only, each with Keep this one),
        // through layout like any paper.
        // Laid out to fit the visible screen first (wrapping to another row), then each paper placed.
        let group = NoteShelf.standaloneGroup(key, group: store.paper(key).flatMap { store.conflict(of: $0) }?.map(\.key) ?? [])
        let spots = NoteShelf.groupLayout(count: group.count, corner: corner, paper: CGSize(width: PaperLook.openWidth, height: 380), visible: screen)
        for (index, other) in group.enumerated() {
            standalone[other] = Standalone(corner: spots[index], fromLibrary: fromLibrary)
            faces[other] = .open
        }
        faces[key] = .open
        keyboard = key
        layout()
        wantKeyboard(key)
    }

    /// Shows each note opened on its own where it was opened.
    private func placeStandalone() {
        guard on else { return }
        for (key, record) in standalone {
            let corner = record.corner
            guard store.paper(key) != nil, faces[key] != nil else { standalone[key] = nil; continue }
            let panel = panel(for: key)
            panel.rest = .window
            let size = panel.paperSize
            panel.place(paperFrame: CGRect(x: corner.x, y: corner.y - size.height, width: size.width, height: size.height))
            shown(key, panel)
        }
    }

    /// A note opened on its own, put away: what's typed is saved; on Escape the Petal Notes window it was opened from
    /// has the keyboard again, and on a click elsewhere the keyboard stays where the person clicked
    /// (NoteShelf.standaloneKeyboard).
    private func closeStandalone(_ key: String, escape: Bool) {
        keyboardWanted.cancel(key)
        editors[key]?.flush()
        let fromLibrary = standalone.removeValue(forKey: key)?.fromLibrary == true
        faces[key] = nil
        if keyboard == key { keyboard = nil }
        panels[key]?.conceal()
        layout()
        let library = app.notesWindow.window
        switch NoteShelf.standaloneKeyboard(escape: escape, fromLibrary: fromLibrary, libraryOpen: library?.isVisible == true) {
        case .library:
            handingBack = true   // the paper losing the keyboard now isn't a click away
            library?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self.handingBack = false } }
        case .app:
            // Opened from the dock (or the window's gone): the regular fold's handback to the app the person was using.
            giveKeyboardBack()
        case .stay:
            break
        }
    }

    // MARK: The Desktop

    /// Which Desktop each screen shows (display UUID → number), read off the main thread (`refreshSpaces`) and used
    /// from here during layout: the window server is never asked on the main thread.
    private static var spaces: [String: Int] = [:]
    @ObservationIgnored private var spacesTurn = 0

    /// The Desktop showing on `screen`, as last read.
    private static func desktopShowing(on screen: NSScreen?) -> Int? { screen.flatMap(Spaces.screenID).flatMap { spaces[$0] } }

    /// Reads which Desktop each screen shows, off the main thread, then places the Desktop's notes. Skipped while no
    /// note is on a Desktop.
    func refreshSpaces() {
        guard on, !Headless.on, !helpers.summoned.isEmpty || store.notes.contains(where: { $0.file.places.contains { $0.kind == .desktop } }) else {
            // No note on a Desktop: nothing is asked of the window server. Notes kept on the screen need no Desktop's
            // number, and are placed all the same.
            let had = !Self.spaces.isEmpty
            if had { Self.spaces = [:] }
            if had || store.notes.contains(where: keptOnScreen) { placeDesktop() }
            return
        }
        let screens = Screens.all.compactMap(Spaces.screenID)
        spacesTurn += 1
        let turn = spacesTurn
        DispatchQueue.global(qos: .userInitiated).async {
            let read = Spaces.desktops(screens)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard turn == self.spacesTurn else { return }
                    if read != Self.spaces { Self.spaces = read }
                    self.placeDesktop()
                }
            }
        }
    }

    /// Notes stuck to the Desktop showing now (on each screen's Desktop), where the person left them; never one
    /// placed by the window in front (NoteShelf.placement: the window wins). And the notes kept on the screen itself:
    /// at their spot on every Desktop, whatever is in front, above the windows.
    func placeDesktop() {
        guard on, !Headless.on, !missionControlOpen else { return }
        var showing: Set<String> = []
        // Kept on the screen (placementNow's rule: not while the window in front is one of its places).
        var resting = 0
        for paper in store.notes where keptOnScreen(paper) && standalone[paper.key] == nil && placementNow(paper.key) == .screen {
            showing.insert(paper.key)
            if faces[paper.key] == nil { faces[paper.key] = .folded }
            let panel = panel(for: paper.key)
            panel.rest = .screen
            let size = panel.paperSize
            var origin: CGPoint
            if let point = local.desk[paper.noteID], point.count == 2 {
                origin = CGPoint(x: point[0], y: point[1])
            } else {
                // Nobody put it anywhere yet (a tool stuck it there): down the main screen's right side.
                origin = NoteShelf.screenRest(index: resting, visible: Screens.all.first?.visibleFrame ?? .zero, paper: PaperLook.folded)
                resting += 1
            }
            panel.place(paperFrame: CGRect(x: origin.x, y: origin.y - size.height, width: size.width, height: size.height))
            shown(paper.key, panel)
        }
        for screen in Screens.all {
            guard let number = Self.desktopShowing(on: screen) else { continue }
            // The validated placement (placementNow's rule): a stale window placement never keeps a note off it.
            let notes = store.notes.filter { paper in
                standalone[paper.key] == nil && NoteShelf.onDesktop(window: here[paper.key], desktops: desktops(of: paper), screenDesktop: number,
                                    windowValid: !awaitingRead && !hiddenForTab(paper.key), screen: keptOnScreen(paper))
            }
            for (index, paper) in notes.enumerated() {
                showing.insert(paper.key)
                if fresh.contains(paper.key) { placedOnce.insert(paper.key) }
                if faces[paper.key] == nil { faces[paper.key] = .folded }
                let panel = panel(for: paper.key)
                panel.rest = .desktop
                let size = panel.paperSize
                let visible = screen.visibleFrame
                var origin = CGPoint(x: visible.minX + 60 + CGFloat(index % 5) * (PaperLook.folded + 24),
                                     y: visible.maxY - 60 - CGFloat(index / 5) * (PaperLook.folded + 24))
                if let point = local.desk[paper.noteID], point.count == 2 { origin = CGPoint(x: point[0], y: point[1]) }
                panel.place(paperFrame: CGRect(x: origin.x, y: origin.y - size.height, width: size.width, height: size.height))
                shown(paper.key, panel)
            }
        }
        leftDesktops()
        for (key, panel) in panels where panel.desktop && !showing.contains(key) {
            panel.rest = .window
            panel.conceal()
        }
    }

    // MARK: Showing, opening, folding

    /// A tab clicked: its notes show (open, with the keyboard) or, showing, put away.
    func tabClicked(_ ids: [String]) {
        let showing = ids.contains { faces[$0] != nil }
        for key in ids {
            if showing { hide(key) } else { faces[key] = .folded }
        }
        if !showing, let first = ids.first { open(first) } else { layout() }
    }

    /// `expecting`: the app and window Petal is bringing forward for it (a drop on a window behind): focus going
    /// there doesn't drop its keyboard request.
    /// A paper opened for writing (its editor): only once notes take changes.
    func open(_ key: String, expecting: NoteShelf.KeyboardRequests.Target? = nil) {
        guard takesChanges(), let paper = store.paper(key) else { return }
        // Open in Petal's viewer's margin: closed there first (one editor per note).
        releaseFromViewer(paper)
        faces[key] = .open
        keyboard = key
        local.shown = Array(Set(local.shown + [paper.noteID]))
        // Opened counts as touched: a note read often doesn't fade.
        local.opened = (local.opened ?? [:]).merging([paper.noteID: Date()]) { _, new in new }
        local.save(pending: store.pendingIDs)
        faceChanged(key)
        wantKeyboard(key, expecting: expecting)
    }

    /// Papers waiting for the keyboard until layout shows them (NoteShelf.KeyboardRequests).
    @ObservationIgnored private var keyboardWanted = NoteShelf.KeyboardRequests()

    /// The keyboard for `key`: now when it's shown, else once layout shows it.
    private func wantKeyboard(_ key: String, expecting: NoteShelf.KeyboardRequests.Target? = nil) {
        let panel = panel(for: key)
        panel.refit()
        if keyboardWanted.request(key, shown: panel.unveiled, expecting: expecting) { panel.takeKeyboard() }
    }

    /// Layout just showed `key`: the keyboard it was waiting for.
    private func shown(_ key: String, _ panel: NotePanel) {
        if keyboardWanted.shown(key), faces[key] == .open { panel.takeKeyboard() }
    }

    /// `escape`: the person pressed Escape on it (else a click elsewhere, or Petal folding it).
    func fold(_ key: String, escape: Bool = false) {
        // A note opened on its own has nowhere to rest: folding it puts it away.
        if standalone[key] != nil { return closeStandalone(key, escape: escape) }
        keyboardWanted.cancel(key)
        let hadKeyboard = panels[key]?.isKeyWindow == true
        // Already folded (a folded paper that took the keyboard, say by being clicked or dragged): Escape puts it away
        // where it can be, and hands the keyboard back.
        guard faces[key] == .open || faces[key] == .back else {
            if escape, putsAway(key) { putAway(key) }
            if escape && hadKeyboard { giveKeyboardBack() }
            return
        }
        Self.roomTurn.cancel()
        editors[key]?.flush()
        faces[key] = .folded
        if keyboard == key { keyboard = nil }
        // (An empty new note stays: it's let go of only once its window is left or it's put away.)
        faceChanged(key)
        if hadKeyboard { giveKeyboardBack() }
    }

    /// The paper open on the desk handed to Petal's viewer's margin (its other editor): what's typed saved, the
    /// desk's paper folded, and never let go of (an empty new note stays: it's open there now).
    func handOff(_ key: String) {
        keyboardWanted.cancel(key)
        guard faces[key] == .open || faces[key] == .back else { return }
        Self.roomTurn.cancel()
        editors[key]?.flush()
        faces[key] = .folded
        if keyboard == key { keyboard = nil }
        faceChanged(key)
    }

    /// The last app other than Petal the person brought forward (kept as apps activate).
    @ObservationIgnored private var lastOtherApp: pid_t?
    @ObservationIgnored private var appWatch: NSObjectProtocol?
    /// Set while the keyboard is handed back on a fold: the paper losing it then isn't a click away.
    @ObservationIgnored private var handingBack = false

    /// The paper that had the keyboard folded (Escape): the keyboard goes back to the app the person was using
    /// (NoteShelf.keyboardBack), activated, never by moving the pointer; the other open papers stay open.
    private func giveKeyboardBack() {
        let petal = getpid()
        guard let pid = NoteShelf.keyboardBack(paperWasKey: true, frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                               petal: petal, lastOther: lastOtherApp),
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        handingBack = true
        NSApp.yieldActivation(to: app)
        app.activate()
        // Already the active app under Petal's nonactivating paper: told through Accessibility too that it's in
        // front, so its own window takes the keys again (off the main thread; a hung app never stalls the desk).
        Self.queue.async {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.3)
            AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self.handingBack = false } }
    }

    /// Keeps the last app other than Petal the person used, for giving the keyboard back.
    private func watchApps() {
        guard appWatch == nil else { return }
        appWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != getpid() else { return }
            let pid = app.processIdentifier
            let chat = PersonRead.isChat(app.bundleIdentifier ?? "")
            MainActor.assumeIsolated {
                self?.lastOtherApp = pid
                // A chat app in front: the vault's contacts read (at most once a minute), to tell its people apart.
                if chat { self?.refreshContacts() }
            }
        }
    }

    /// An empty new note on a Desktop only, shown there before, whose Desktop no screen shows now (the person went to
    /// another): let go, as one on a window is when its window is left.
    private func leftDesktops() {
        let showing = Set(Self.spaces.values)
        guard !showing.isEmpty else { return }
        for key in Array(fresh) where standalone[key] == nil && placedOnce.contains(key) {
            guard let places = store.paper(key)?.file.places, !places.isEmpty, places.allSatisfy({ $0.kind == .desktop }),
                  !places.contains(where: { $0.desktop.map(showing.contains) ?? false }) else { continue }
            if faces[key] == .open || faces[key] == .back { faces[key] = .folded }
            if keyboard == key { keyboard = nil }
            letGoIfEmpty(key)
        }
    }

    /// The corner's @: the paper open (it opens first when folded or turned over), and a new "@Petal " line at the end
    /// of its writing with the cursor after it.
    func askPetal(_ key: String) {
        if faces[key] != .open { open(key) }
        guard faces[key] == .open else { return }
        if let editor = editors[key] { return editor.startPetal() }
        // Its editor isn't made yet: once it's registered.
        petalWanted.insert(key)
    }

    @ObservationIgnored private var petalWanted: Set<String> = []

    /// "@Petal " was put in: the paper says what to do next, until a run says more.
    func askHint(_ key: String) {
        guard let id = store.paper(key)?.noteID else { return }
        let words = "Write what you want, then press Return."
        helpers.hints[id] = words
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { MainActor.assumeIsolated { if self.helpers.hints[id] == words { self.helpers.hints[id] = nil } } }
    }

    /// Whether a paper can be put away where it shows now: on a window (its tab brings it back), brought up for a
    /// while (a summoned note), or opened on its own. One on its own Desktop or kept on the screen stays there.
    func putsAway(_ key: String) -> Bool {
        // An empty new note too, wherever it is: putting it away lets it go.
        if standalone[key] != nil || helpers.summoned.contains(key) || fresh.contains(key) { return true }
        if case .window = placementNow(key) { return true }
        return false
    }

    /// "Put away" (the letterhead's menu, Escape on a folded paper): hidden until its tab or Petal Notes brings it
    /// back.
    func putAway(_ key: String) {
        if standalone[key] != nil { return closeStandalone(key, escape: false) }
        hide(key)
        layout()
        placeDesktop()
    }

    func hide(_ key: String) {
        standalone[key] = nil
        keyboardWanted.cancel(key)
        Self.roomTurn.cancel()
        editors[key]?.flush()
        faces[key] = nil
        if keyboard == key { keyboard = nil }
        helpers.dismissed(key)
        panels[key]?.conceal()
        if let paper = store.paper(key) {
            local.shown.removeAll { $0 == paper.noteID }
            local.save(pending: store.pendingIDs)
        }
        letGoIfEmpty(key)
    }

    func flip(_ key: String) {
        if let paper = store.paper(key) { releaseFromViewer(paper) }
        faces[key] = faces[key] == .back ? .open : .back
        if faces[key] == .open { wantKeyboard(key) }
        panels[key]?.refit()
        faceChanged(key)
    }

    /// After any change of a note's face (open, turned over, folded): placed again the one way (on its window or its
    /// Desktop, kept whole on its screen), and the room beside its window reconciled.
    private func faceChanged(_ key: String) {
        layout()
        if isDesktopNote(key) { placeDesktop() }
    }

    /// Clicked away from every note: the open ones fold back.
    func clickedAway() {
        // The keyboard handed back on a fold (Escape) isn't a click away: the other open papers stay open.
        if handingBack { handingBack = false; return }
        keyboardWanted.cancelAll()
        for (key, face) in faces where face == .open || face == .back { fold(key) }
    }

    func measured(_ key: String, _ height: CGFloat) {
        guard abs((heights[key] ?? 0) - height) > 0.5 else { return }
        heights[key] = height
        panels[key]?.refit()
    }

    private func isDesktopNote(_ key: String) -> Bool { store.paper(key).map { !desktops(of: $0).isEmpty || keptOnScreen($0) } == true }

    /// Notes open for writing in Petal's viewer's margin, by the note's identity (its holder key, NoteShelf.holderKey:
    /// an id-less note's is its path id with its file's instance): told to fold before the desk opens one, so a note
    /// is never open in two editors. An id given to an id-less note moves its entry (`identityChanged`).
    @ObservationIgnored var heldByViewer: [String: () -> Void] = [:]

    /// A note open in a viewer's margin folded there first (before the desk opens or turns it).
    func releaseFromViewer(_ paper: PaperNote) {
        heldByViewer.removeValue(forKey: paper.holder)?()
    }

    /// Phase 1's identity change (`store.onIdentity`): an id-less note got its own id; what's held by its old
    /// identity follows it.
    func identityChanged(holder: String, _ new: String) {
        heldByViewer = NoteShelf.rekeyed(heldByViewer, holder, new)
    }

    /// Petal's viewer came to the front: the notes on the window left behind hide, as for any other app coming
    /// forward, until a fresh read of what's in front after it.
    func viewerFront() { concealWindowNotes() }

    /// A note made just now and put away with nothing written goes (to the Trash: never deleted outright). What's
    /// typed and not saved yet (the editor saves half a second after the last key) is saved first, so a note written
    /// in just before its window was left is kept; one whose typing still couldn't be saved stays too.
    func letGoIfEmpty(_ key: String) {
        guard fresh.contains(key) else { return }
        editors[key]?.flush()
        guard fresh.contains(key), editors[key]?.busy() != true, let paper = store.paper(key), faces[key] != .open,
              NoteShelf.mayTrash(bodyEmpty: NoteShelf.untouched(paper.file.body, madeWith: madeWith[key]), picturesPending: store.picturesPending(key),
                                 importing: store.importing(key))
        else { return }
        fresh.remove(key)
        placedOnce.remove(key)
        madeWith[key] = nil
        faces[key] = nil
        panels[key]?.conceal()
        panels[key] = nil
        store.trash(key, asked: true)
    }

    /// The person said to throw this note away (its tab's menu, its letterhead's, the Petal Notes window's): what's
    /// typed is saved first, then its file goes to the Trash, where it can be put back. Never deleted.
    func throwAway(_ key: String) {
        guard takesChanges(), let paper = store.paper(key) else { return }
        guard paper.version == nil, !store.conflicts.values.contains(where: { $0.contains { $0.key == key } }) else { return say("Keep one version of this note first.") }
        editors[key]?.flush()
        guard store.trash(key, asked: true) else { return say("A picture in this note is still being saved. Try again in a moment.") }
        fresh.remove(key)
        madeWith[key] = nil
        standalone[key] = nil
        keyboardWanted.cancel(key)
        if keyboard == key { keyboard = nil }
        helpers.dismissed(key)
        faces[key] = nil
        panels[key]?.conceal()
        panels[key] = nil
        say("Moved to the Trash.")
        layout()
    }

    /// An edge tab right-clicked: show its note, or throw it away (each note by name when the tab holds several).
    func tabMenu(_ ids: [String]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let showing = ids.contains { faces[$0] != nil }
        menu.addItem(ActionItem(showing ? "Hide" : "Show") { [weak self] in self?.tabClicked(ids) })
        menu.addItem(.separator())
        if ids.count == 1 {
            menu.addItem(ActionItem("Move to Trash") { [weak self] in self?.throwAway(ids[0]) })
        } else {
            let item = NSMenuItem(title: "Move to Trash", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for key in ids {
                let title = store.paper(key)?.file.title ?? ""
                sub.addItem(ActionItem(title.isEmpty ? "A note" : String(title.prefix(40))) { [weak self] in self?.throwAway(key) })
            }
            item.submenu = sub
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: Room beside the window

    /// Windows narrowed for a note: their frame from before and the one Petal gave them. Only ever touched on
    /// `queue`, the same serial queue that changes the windows, and written before a window is changed, so a change
    /// under way, cut short or finished, always has its record, and whatever comes after it on the queue (a fold,
    /// notes off, quitting) finds it.
    nonisolated(unsafe) private static var ledger: [CGWindowID: (pid: pid_t, before: CGRect, given: CGRect)] = [:] {
        didSet { keepLedger() }
    }

    /// The ledger on disk too (Application Support's notes-narrowed.json), so a window narrowed when Petal crashed
    /// gets its width back the next time Petal starts. Only on `queue`.
    nonisolated private static var ledgerFile: URL { Config.supportFolder.appending(path: "notes-narrowed.json") }

    nonisolated private static func keepLedger() {
        guard !Headless.on else { return }
        let rows = ledger.map { number, record in
            ["window": Double(number), "pid": Double(record.pid), "before": [record.before.minX, record.before.minY, record.before.width, record.before.height],
             "given": [record.given.minX, record.given.minY, record.given.width, record.given.height]] as [String: Any]
        }
        if rows.isEmpty { try? FileManager.default.removeItem(at: ledgerFile); return }
        if let data = try? JSONSerialization.data(withJSONObject: rows) {
            try? FileManager.default.createDirectory(at: Config.supportFolder, withIntermediateDirectories: true)
            try? data.write(to: ledgerFile, options: .atomic)
        }
    }

    /// At start: windows left narrowed by a Petal that didn't quit get their width back (where still as Petal left them).
    nonisolated private static func recoverNarrowed() {
        guard !Headless.on, let data = try? Data(contentsOf: ledgerFile),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        func rect(_ value: Any?) -> CGRect? {
            guard let v = value as? [Double], v.count == 4 else { return nil }
            return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        for row in rows {
            // Numbers from a file: only those a window number and a process id can be (a broken file never traps).
            guard let number = (row["window"] as? Double).flatMap({ CGWindowID(exactly: $0) }), let pid = (row["pid"] as? Double).flatMap({ pid_t(exactly: $0) }),
                  let before = rect(row["before"]), let given = rect(row["given"]) else { continue }
            ledger[number] = (pid, before, given)
            // What couldn't be given back yet (its app not answering) stays, tried again with every change.
            giveBack(number)
        }
    }

    /// The one path for room beside windows, after every change of what's showing (a note opened, folded, hidden,
    /// put on the Desktop, another window in front): the window in front narrows while a note open on it (where
    /// nobody moved it) has no room, and every other narrowed window gets its width back.
    private func reconcileRoom() {
        var wanted: (number: CGWindowID, pid: pid_t, frame: CGRect, target: CGRect?, opening: Bool)?
        // Only notes there by their window placement (never one opened on its own, or moved off by the person): one
        // open makes room; once made, any paper of it showing, folded too, keeps it (NoteRoom.keepsRoom).
        if on, !quitting, let frame, let scene, let number = scene.window {
            let notes = here.keys.map { (placement: placementNow($0), face: faces[$0], moved: local.spots[store.paper($0)?.noteID ?? ""] != nil) }
            let opening = NoteRoom.wanted(notes.map { ($0.placement, $0.face == .open, $0.moved) })
            let showing = NoteRoom.wanted(notes.map { ($0.placement, $0.face != nil, $0.moved) })
            if opening || showing {
                let target = visible(for: frame).flatMap { NoteRoom.narrowed(window: frame, visible: $0, note: PaperLook.openWidth, margin: PaperLook.margin) }
                wanted = (number, scene.pid, frame, target, opening)
            }
        }
        let turn = Self.roomTurn.next()
        Self.queue.async {
            // A window not narrowed yet gets room only for a note opening on it.
            let keep = wanted.flatMap { NoteRoom.keepsRoom(opening: $0.opening, showing: true, narrowed: Self.ledger[$0.number] != nil) ? $0.number : nil }
            let plan = NoteRoom.reconcile(narrowed: Set(Self.ledger.keys), wanted: keep)
            for number in plan.giveBack { Self.giveBack(number) }
            // A newer look is on its way: it decides whether to narrow.
            guard let wanted, plan.narrow == wanted.number, let target = wanted.target, Self.roomTurn.current(turn) else { return }
            Self.narrow(wanted.number, pid: wanted.pid, from: wanted.frame, to: target, turn: turn)
        }
    }

    /// Narrows one window, on `queue`: only while it's still where it was when this was decided, recorded before it
    /// changes, and with the frame the app took.
    nonisolated private static func narrow(_ number: CGWindowID, pid: pid_t, from frame: CGRect, to target: CGRect, turn: Int) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let all: [AXUIElement] = Windows.value(app, kAXWindowsAttribute) ?? []
        guard let element = all.first(where: { Windows.id(of: $0) == number }), let now = Windows.frame(of: element),
              NoteRoom.close(now, frame) else { return }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success, settable.boolValue else { return }
        ledger[number] = (pid, now, target)
        // A newer turn (a fold, notes off, quitting) stops it between its steps; whatever it had changed is put back
        // at once (the record was written first).
        let took = Windows.place(element, pid: pid, target, live: { Self.roomTurn.current(turn) })
        if let took { ledger[number]?.given = took } else { giveBack(number) }
        DispatchQueue.main.async { MainActor.assumeIsolated { PetalApp.shared.paper.lookAgain(after: 0.05) } }
    }

    /// A narrowed window's width back, on `queue`: the frame from before, while it still has the one Petal gave it
    /// (or part of it: a change cut short); the record goes either way.
    nonisolated private static func giveBack(_ number: CGWindowID) {
        guard let record = ledger[number] else { return }
        let app = AXUIElementCreateApplication(record.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        // Its app gone, or no window of it with that number: nothing left to give back.
        let alive = NSRunningApplication(processIdentifier: record.pid).map { !$0.isTerminated } ?? false
        var windows: CFTypeRef?
        let listed = alive && AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success
        let all = (windows as? [AXUIElement]) ?? []
        let element = all.first { Windows.id(of: $0) == number }
        // Gone with its app; there when its app couldn't list its windows (asked again next time); else by its number.
        let found = alive ? (listed ? element != nil : true) : false
        let plan = NoteRoom.giveBackPlan(found: found, now: element.flatMap { Windows.frame(of: $0) }, before: record.before, given: record.given)
        if plan.restore, let element {
            let back = Windows.place(element, pid: record.pid, record.before)
            // Kept until it's surely back (an app that refused is tried again with the next change).
            if let back, NoteRoom.close(back, record.before) { ledger[number] = nil }
            return
        }
        if plan.forget { ledger[number] = nil }
    }

    /// Every narrowed window gets its width back (notes off, Petal quitting). `wait`: before returning (on quit),
    /// after whatever change is under way on the queue.
    private func giveBackAll(then done: @escaping @Sendable () -> Void) {
        Self.roomTurn.cancel()
        Self.queue.async {
            for number in Array(Self.ledger.keys) { Self.giveBack(number) }
            done()
        }
    }

    // MARK: Writing

    func style(_ color: NSColor, glass: Bool) -> NoteRich.Style {
        let tint = PaperLook.rgb(color)
        if glass {
            return NoteRich.Style(ink: .labelColor, dim: .secondaryLabelColor, petal: .labelColor, accent: color)
        }
        return NoteRich.Style(ink: NSColor(srgbRed: 0x22 / 255, green: 0x22 / 255, blue: 0x22 / 255, alpha: 1),
                              dim: NSColor(white: 0.53, alpha: 1), petal: PaperLook.nsColor(NoteInk.ink(tint)), accent: color)
    }

    /// What the editor typed, made on `base` (the file as the editor last had it). Returns the next base; nil when
    /// it's refused, and then the editor keeps it as typed and not saved, and tries again. Typed text is never
    /// dropped: saved through the note; kept beside a paper that turned read only; when its folder is being switched
    /// away from or is no longer the one in use, handed to that folder's own drain (NoteStore.drainLate: stored there,
    /// or in Unsaved notes); else journaled under its note's id for the next launch (NoteStore.journalUnsaved).
    /// `also`: a helper's metadata, written in the same snapshot as the typing (one based write, never two).
    func write(_ key: String, body: String, base: String?, also: ((inout NoteFile) -> Void)? = nil,
               done: (@MainActor (NoteStore.Outcome) -> Void)? = nil) -> String? {
        write(key, noteID: nil, instance: "", body: body, base: base, also: also, done: done)
    }

    /// `noteID` and `instance`: the note the editor was typed in. Its file renamed or moved while the editor was open
    /// (Petal's viewer's margin, a final save as it closes), the save goes to that note as it is now, by its identity
    /// (NoteShelf.saveTarget, NoteStore.currentID): never lost to a key that's gone, never a guess.
    func write(_ key: String, noteID: String?, instance: String, body: String, base: String?, also: ((inout NoteFile) -> Void)? = nil,
               done: (@MainActor (NoteStore.Outcome) -> Void)? = nil) -> String? {
        let papers = store.notes.map { (key: $0.key, id: $0.noteID, instance: $0.instance, version: $0.version) }
        // With the note it was typed in known, only a paper that is that note (never another note that took its key).
        let target = noteID.map { id in NoteShelf.saveTarget(key: key, noteID: id, instance: instance, papers: papers, current: store.currentID) } ?? key
        guard let target, let paper = store.paper(target) else {
            // (What was to be written with it, a helper's metadata, wasn't: its asker keeps it and tries again.)
            done?(.failed)
            // Its folder switched away from (the note is in a session that ended): to that folder's drain.
            if let late = store.drainLate(key: key, body: body, base: base) { return late }
            // Refused (the paper gone, or no paper is surely that note): the typing goes into the journal under the
            // note it was typed in, at once.
            if let noteID {
                store.journalUnsaved(noteID: noteID, path: key, base: base,
                                     text: NoteShelf.unsavedText(current: nil, base: base, noteID: noteID, body: body, now: Date()))
            }
            return nil
        }
        let key = target
        if store.readOnly(paper) {
            // Typed just as it became one of two papers: kept in the copy beside it, never dropped (handled: the
            // editor doesn't keep it as unsaved).
            if paper.version == nil, paper.file.body != body { store.keepAside(key, body: body) }
            done?(.failed)
            return paper.revision ?? base ?? ""
        }
        // Petal's own changes since (a place followed or added) don't make this a conflict; words changed do.
        let base = NoteShelf.rebase(editor: base, current: paper.revision, currentBody: paper.file.body)
        guard paper.file.body != body || also != nil else { done?(.written); return base }
        if !NoteShelf.untouched(body, madeWith: madeWith[key]) { fresh.remove(key); madeWith[key] = nil }
        // Links the person typed (an address alone on a line): their pages' titles may be fetched; a link already
        // in the note (from sync) never is.
        let links = { (text: String) in Set(NoteBlock.blocks(text).compactMap { if case .link(let url) = $0 { url } else { nil } }) }
        for url in links(body).subtracting(links(paper.file.body)) { LinkPreviews.shared.requested(url) }
        let next = store.change(key, base: base, edit: { $0.body = body; also?(&$0) }, done: done)
        // Refused (the notes' folder switching or not ready yet, a drain): to the drain of the folder it was typed in
        // when that session has ended; else the typing goes into the journal under its note's id at once, made on
        // what the editor had (put back at the next launch if it never lands).
        // (`done` hears a refusal either way: what `also` would have written is its asker's to keep and try again.)
        if next == nil { done?(.failed) }
        if next == nil, let late = store.drainLate(key: key, body: body, base: base) { return late }
        if next == nil {
            store.journalUnsaved(noteID: paper.noteID, path: paper.url.path, base: base ?? paper.revision,
                                 text: NoteShelf.unsavedText(current: paper.file, base: base, noteID: paper.noteID, body: body, now: Date()))
        }
        return next
    }

    /// An editor back at what's saved after a refused save (the person undid it): the journal's snapshot of that
    /// refused typing replaced by the note as it is (what's still waiting to be written kept), or retired when
    /// nothing differs, keeping any picture or paste recovery still pending.
    func settleUnsaved(_ key: String, noteID: String, instance: String, saved: String?) {
        let papers = store.notes.map { (key: $0.key, id: $0.noteID, instance: $0.instance, version: $0.version) }
        // No paper surely that note: nothing of another note's is read for it (only what the editor saved).
        let target = NoteShelf.saveTarget(key: key, noteID: noteID, instance: instance, papers: papers, current: store.currentID)
        store.settleUnsaved(target, noteID: noteID, saved: saved)
    }

    /// Pictures pasted or dropped on a note: their bytes read and decoded first (a file that's slow or not downloaded
    /// yet, a screenshot's TIFF), on a background queue that's neither the journal's nor the notes' own. Only then is
    /// the paste accepted: the bytes into memory (and from there into the journal's snapshots and the note's
    /// pictures' folder), and the references into the note as ordinary text, at the cursor in its editor, or at the
    /// end of the note once the editor is gone. The paste is recorded with the note before anything is read
    /// (`beginImport`: its sources in the journal), so a note with a picture loading is never put away as empty,
    /// and a quit meanwhile keeps it for the next launch.
    @discardableResult
    func importPictures(_ items: NoteImport, into key: String) -> Bool {
        guard takesChanges() else { return false }
        guard let paper = store.paper(key), !store.readOnly(paper) else { say("This note has two versions: keep one before adding pictures."); return false }
        // A paste is journaled by the note's own id: an id-less note gets it in its file first (its session), and
        // the paste waits for that; it can't be written, the paste is refused (the paper says the note isn't saved).
        guard NoteShelf.lasting(paper.noteID, pending: store.pendingIDs) else {
            store.ensureID(key) { id in
                guard let id, let now = self.store.notes.first(where: { $0.noteID == id && $0.version == nil }) else {
                    return self.say("Petal couldn't write an id into this note's file, so the picture wasn't added.")
                }
                self.importPictures(items, into: now.key)
            }
            return true
        }
        guard let (token, sources) = store.beginImport(key, items) else { say("This note can't take pictures right now."); return false }
        let noteID = paper.noteID, instance = paper.instance
        let pastedIn = store.root
        DispatchQueue.global(qos: .userInitiated).async {
            // Each file on its own (NoteShelf.sourceEnd): read, not read but still there (waiting), or gone (or not
            // a picture at all).
            var read: [(ext: String, data: Data, caption: String)] = []
            var waiting: [NoteJournal.Import] = []
            for source in sources {
                if source.path != nil {
                    // The one read, live and in recovery (NoteJournal.read): a pasted picture only through the one
                    // link rule, and only the very file recorded.
                    switch NoteJournal.read(source) {
                    case .bytes(let data): read.append((source.ext, data, source.caption))
                    case .waiting: waiting.append(source)
                    case .gone: break
                    }
                } else if let data = source.data {
                    if source.ext == "tiff" {
                        if let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) { read.append(("png", png, "")) }
                    } else if NSImage(data: data) != nil {
                        read.append((source.ext, data, source.caption))
                    }
                }
            }
            // Their images made here, off the main thread, to be shown as one batch.
            let ready = read, unread = waiting
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // The note's id as it is now (one given its own meanwhile is followed: store.currentID).
                    let noteID = self.store.currentID(noteID, instance: instance)
                    // Tied to the note's id and the folder it was pasted in. Quitting meanwhile: left in the journal
                    // for the next launch. The folder changed, or the note can't take it now: put in from the
                    // journal into that note in that folder. Files not read yet but still there wait, in the journal
                    // and on the paper's Try again line. Nothing leaves the journal before its bytes and reference
                    // are stored (NoteShelf.importEnd).
                    let sameRoot = !self.store.switching && self.store.root == pastedIn
                    var end = NoteShelf.importEnd(read: !ready.isEmpty, waiting: !unread.isEmpty, quitting: self.store.quitting, sameRoot: sameRoot, taken: true)
                    var taken: (key: String, pictures: [(path: String, file: URL, caption: String)])?
                    if end == .accepted {
                        // Its read is over before its pictures go in, so the snapshot they make carries their bytes,
                        // not their sources (only the files still waiting).
                        self.store.keepWaiting(noteID, token, unread)
                        if let now = self.store.notes.first(where: { $0.noteID == noteID && $0.version == nil }),
                           let accepted = self.store.acceptPictures(now.key, ready) {
                            taken = (now.key, accepted)
                        } else {
                            self.store.keepWaiting(noteID, token, [])
                            self.store.holdImport(noteID, token, sources)
                            end = NoteShelf.importEnd(read: true, quitting: false, sameRoot: true, taken: false)
                        }
                    }
                    switch end {
                    case .keepForLaunch: return
                    case .waiting:
                        self.store.keepWaiting(noteID, token, unread)
                        return self.say("That picture isn't downloaded yet: Try again on the note once it is.")
                    case .nothingRead:
                        self.store.endImport(noteID, token, journal: true)
                        self.letGoIfEmpty(self.store.notes.first { $0.noteID == noteID && $0.version == nil }?.key ?? "")
                        return self.say("Petal couldn't read that picture.")
                    case .putIn:
                        return self.store.putIn(noteID, token, root: pastedIn) { stored, left in
                            let noteID = self.store.currentID(noteID, instance: instance)
                            if stored, left.isEmpty { return self.store.endImport(noteID, token, journal: false) }
                            // Files still waiting stay with the note (on its paper, when it's in this folder).
                            if stored { self.store.keepWaiting(noteID, token, left) }
                            self.say(left.isEmpty ? "Petal keeps that picture and puts it in the note when it next starts."
                                                  : "That picture isn't downloaded yet: Try again on the note once it is.")
                        }
                    case .accepted: break
                    }
                    guard let (nowKey, accepted) = taken else { return }
                    // Their bytes held until written; their images decoded off the main thread when drawn.
                    NotePictures.shared.accepted(accepted.enumerated().map { ($1.file, ready[$0].data) })
                    self.fresh.remove(nowKey)
                    if self.insertPictures(nowKey, accepted, at: items.at, length: items.length, selected: items.selected) {
                        // Into the note now (and its snapshot), not a moment later.
                        self.editors[nowKey]?.flush()
                    } else {
                        let lines = accepted.map { NoteBlock.image(path: $0.path, caption: $0.caption).markdown }
                        self.store.change(nowKey) { file in
                            file.body += (file.body.isEmpty || file.body.hasSuffix("\n") ? "" : "\n") + lines.joined(separator: "\n")
                        }
                    }
                    // Out of the journal: the files that went in; the ones still waiting stay.
                    NoteJournal.queue.async { NoteJournal.importsDone(noteID: noteID, token: token, keeping: unread) }
                    if !unread.isEmpty { self.say("A picture isn't downloaded yet: Try again on the note once it is.") }
                }
            }
        }
        return true
    }

    /// Try again on a paper: pictures whose bytes couldn't be written, and files of pastes not read yet (each read
    /// again as a new paste, recorded before its old one leaves the journal).
    func retryPictures(_ key: String) {
        store.retryPictures(key)
        guard let paper = store.paper(key) else { return }
        for (token, sources) in store.takeWaiting(paper.noteID) {
            let files = sources.compactMap { $0.path.map(URL.init(fileURLWithPath:)) }
            if !files.isEmpty, importPictures(NoteImport(files: files, png: nil, tiff: nil, at: -1), into: key) {
                store.endImport(paper.noteID, token, journal: true)
            } else {
                store.keepWaiting(paper.noteID, token, sources)
            }
        }
    }

    /// Remove on a paper: those pictures and waiting files let go.
    func dropPictures(_ key: String) {
        // Never on a read-only paper (one of a conflict's): its recovery bytes stay until it can be changed.
        guard let paper = store.paper(key), !store.readOnly(paper) else { return say("This note has two versions: keep one before removing pictures.") }
        store.dropWaiting(paper.noteID)
        // With its editor open, Remove is an edit there, saved like any typing (never a write under it that its
        // unsaved typing would undo); without one, a based write.
        if let editor = editors[key] {
            // Their bytes captured first: undo accepts them again (journaled, written in the background), redo removes
            // them again.
            let bytes = store.asideBytes(key)
            guard let names = store.retirePictures(key, write: false) else { return }
            // Undo and redo find the note by the editor's id as it is when they run (moved since, renamed, given its
            // own id), never by this key.
            editor.removePictures(names, { [weak self] noteID in
                guard let self, let now = self.store.current(noteID) else { return }
                self.store.reaccept(now.key, bytes)
                let folder = self.store.root.appending(path: NoteShelf.pictureFolder(id: now.noteID))
                NotePictures.shared.accepted(bytes.map { (folder.appending(path: $0.name), $0.data) })
            }, { [weak self] noteID in
                guard let self, let now = self.store.current(noteID) else { return }
                self.store.retireAgain(now.key, names: names)
            })
            editor.flush()
        } else {
            store.retirePictures(key, write: true)
        }
    }

    /// How many pictures the paper says couldn't be saved (or read yet).
    func troubleCount(_ paper: PaperNote) -> Int {
        (store.pictureTrouble[paper.key]?.count ?? 0) + (store.importTrouble[paper.noteID]?.values.reduce(0) { $0 + $1.count } ?? 0)
    }

    /// Pictures' references into a note's open editor, as ordinary text, at the cursor's place then; false when no
    /// editor is open on it.
    private func insertPictures(_ key: String, _ pictures: [(path: String, file: URL, caption: String)], at: Int, length: Int = 0,
                                selected: String = "") -> Bool {
        guard let editor = editors[key] else { return false }
        var at = at, length = length
        for picture in pictures {
            // The first replaces the selection it was pasted over (when it's still that text), or goes at a pasted
            // picture's spot.
            guard editor.insert(picture.path, picture.file, picture.caption, at, length, selected) else { return false }
            at = -1   // the next one after it, at the cursor
            length = 0
        }
        return true
    }

    /// Pictures pasted as bytes (a copy from a note), taken as a pasted screenshot's are: accepted in memory and
    /// journaled at once (their files written through the note's session), and shown at once.
    func acceptCopiedPictures(_ key: String, _ items: [(ext: String, data: Data, caption: String)]) -> [(path: String, file: URL, caption: String)]? {
        guard takesChanges() else { return nil }
        guard let accepted = store.acceptPictures(key, items) else { return nil }
        NotePictures.shared.accepted(accepted.enumerated().map { ($1.file, items[$0].data) })
        return accepted
    }

    /// A note's file got another name on disk than it was shown with: everything showing it follows.
    /// A paper's key changed (its file moved or was renamed): every per-paper record of the desk follows it
    /// (NoteShelf.rekeyed), the pending keyboard request too; tabs are drawn again by the next layout.
    private func rekey(_ old: String, to paper: PaperNote) {
        let new = paper.key
        guard old != new else { return }
        faces = NoteShelf.rekeyed(faces, old, new)
        helpers.rekeyed(old, new)
        if keyboard == old { keyboard = new }
        if hovered == old { hovered = new }
        keyboardWanted.rekey(old, new)
        heights = NoteShelf.rekeyed(heights, old, new)
        here = NoteShelf.rekeyed(here, old, new)
        found = NoteShelf.rekeyed(found, old, new)
        if fresh.remove(old) != nil { fresh.insert(new) }
        madeWith = NoteShelf.rekeyed(madeWith, old, new)
        lines = NoteShelf.rekeyed(lines, old, new)
        standalone = NoteShelf.rekeyed(standalone, old, new)
        passageRects = NoteShelf.rekeyed(passageRects, old, new)
        anchors = NoteShelf.rekeyed(anchors, old, new)
        lost = NoteShelf.rekeyed(lost, old, new)
        editors = NoteShelf.rekeyed(editors, old, new)
        editorTokens = NoteShelf.rekeyed(editorTokens, old, new)
        pinPanels = NoteShelf.rekeyed(pinPanels, old, new)
        if let tab = tabPanels.removeValue(forKey: old) { spareTab(tab) }
        if let panel = panels.removeValue(forKey: old) { panel.rekey(new); panels[new] = panel }
        app.viewers.rekeyed(old, new)
    }

    /// An editor came or went: gone (folded, closed), the folder is read again, so a version that arrived while it
    /// was open shows.
    /// `token`: the paper the editor is in; a going-away clears only that paper's own registration (a note can close
    /// on the desk as it opens in Petal's viewer, in either order).
    func editorRegistered(_ key: String, _ handle: NoteEditorHandle?, token: UUID? = nil) {
        if let handle {
            editors[key] = handle
            editorTokens[key] = token
            if petalWanted.remove(key) != nil { DispatchQueue.main.async { handle.startPetal() } }
        } else {
            guard token == nil || editorTokens[key] == nil || editorTokens[key] == token else { return }
            editors[key] = nil
            editorTokens[key] = nil
            store.reload()
        }
    }

    /// Which paper each registered editor is in (by paper key), for `editorRegistered`.
    @ObservationIgnored private var editorTokens: [String: UUID] = [:]

    func keep(_ key: String) {
        guard let paper = store.paper(key) else { return }
        store.keep(paper)
    }

    func reveal(_ key: String) {
        guard let paper = store.paper(key) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([paper.url])
    }

    /// A note moved by the person: it stays there on its window (by the window's nearest corner) or the Desktop.
    func moved(_ key: String, to rect: CGRect) {
        guard let paper = store.paper(key) else { return }
        if standalone[key] != nil {
            standalone[key]?.corner = CGPoint(x: rect.minX, y: rect.maxY)
            return
        } else if NoteShelf.restsOffWindow(placementNow(key)) {
            // On its Desktop or the screen: a point on the screen, its top-left corner.
            local.desk[paper.noteID] = [rect.minX, rect.maxY]
        } else if let frame, here[key] != nil {
            // By the window in front as last read (`frame` and `here` are of the same read): one of its places.
            local.spots[paper.noteID] = NoteSpot.stick(panel: rect, window: NoteRules.appKitFrame(frame, primaryHeight: primaryHeight))
        }
        local.save(pending: store.pendingIDs)
        // Placed again the one way, now: it stays where it was let go (moved in only from a screen's edge it crossed),
        // and a note dragged off its window's side no longer needs the room it was given (layout reconciles it).
        layout()
        if NoteShelf.restsOffWindow(placementNow(key)) { placeDesktop() }
    }

    // MARK: What the paper says

    func letterhead(_ paper: PaperNote) -> (place: String, notebook: String, others: String) {
        let places = paper.file.places
        // The place it shows by: the window in front's, else the screen (kept there on this Mac), else its Desktop.
        let mac = local.mac
        let index = here[paper.key] ?? places.firstIndex { $0.kind == .screen && $0.mac == mac } ?? places.firstIndex { $0.kind == .desktop } ?? 0
        let place = places.indices.contains(index) ? places[index].label(found: found[paper.key] ?? true) : "not stuck anywhere"
        let rest = places.indices.filter { $0 != index }
        let others = rest.count == 1 ? places[rest[0]].alsoLabel : rest.isEmpty ? "" : "\(rest.count) places"
        // A person's note says where it shows: beside them in any chat app.
        let person = places.indices.contains(index) && places[index].kind == .person
        return (place, person ? "any chat app · " + paper.notebook : paper.notebook, others)
    }

    /// The folded note's one line of what's coming: a helper at work, when it comes back, its watcher, or when it
    /// was written.
    func footer(_ paper: PaperNote) -> String {
        let file = paper.file
        if let run = helpers.runs[paper.noteID] {
            let step = run.sticky?.agent.activity.text ?? ""
            return run.paused ? "Paused" : step.isEmpty ? "Working" : step
        }
        if let helper = file.helper, helper.state == .failed { return "Couldn't finish" }
        if let helper = file.helper, helper.state != .done { return helper.step.isEmpty ? "Working" : helper.step }
        if let back = file.back { return NoteHelp.backLine(back, now: Date()) }
        // "This Mac" only for a watcher this Mac looks for: one the person set up here (`NoteLocal.standing`).
        if let watch = file.watch {
            let here = local.standing == nil || NoteHelp.stands(NoteHelp.Standing(watch, on: paper.noteID), in: local.standing)
            return watch.foot(thisMac: watch.mac == local.mac && here)
        }
        if file.fromPetal { return "From Petal · " + Self.when(file.created) }
        return Self.when(file.modified)
    }

    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// A place in a few plain words, for the back of a note and Petal AI.
    static func describe(_ stick: NoteStick) -> String { stick.words }

    // MARK: Making notes

    /// The places what's in front offers, most specific first: the passage selected, the tab, the file, the window,
    /// all of the app; the Desktop only when the app said it has no window in front (`FrontRead.none`). A window
    /// Petal couldn't read offers nothing (`NoteShelf.frontOffer`): never a Desktop note by mistake.
    func places(for scene: NoteScene, read: ClaudePanel.FrontRead, appName: String, passage: (quote: String, before: String, after: String)? = nil) -> [NoteStick] {
        var offers: [NoteStick] = []
        func stick(_ kind: NoteStick.Kind) -> NoteStick {
            var s = NoteStick(kind: kind)
            s.app = scene.app
            s.appName = appName
            s.mac = scene.mac
            s.pid = scene.pid
            s.window = scene.window
            s.title = app.assist.neverLook(scene.app) ? "" : scene.title
            return s
        }
        switch NoteShelf.frontOffer(window: scene.window, none: read.none) {
        case .window: break
        case .unknown: return []
        case .desktop:
            // Which Desktop it is (read off the main thread with the scene), or no note: never one stuck to no Desktop.
            return NoteShelf.desktopAnchor(number: scene.desktop).map { [$0] } ?? []
        }
        if let passage, !passage.quote.isEmpty, scene.tab != nil || !scene.file.isEmpty {
            var s = stick(.passage)
            s.quote = String(passage.quote.prefix(500))
            s.before = String(passage.before.suffix(80))
            s.after = String(passage.after.prefix(80))
            s.url = scene.tab?.url ?? ""
            s.path = scene.tab == nil ? scene.file : ""
            // A sentence in a file follows the file through its bookmark and its own identity, as a file's note does.
            if scene.tab == nil {
                s.bookmark = scene.fileBookmark
                s.fileID = scene.fileID
            }
            offers.append(s)
        }
        // A tab Petal can tell from the others (its id, or its tab-strip button): Safari's only tab, with no strip,
        // can't be, so its note goes on the window instead.
        if let tab = scene.tab, tab.known, !tab.url.isEmpty {
            var s = stick(.tab)
            s.url = tab.url
            s.title = tab.title
            // Its identity as NoteTab tells tabs apart: its id (Chromium) or its tab-strip button (Safari, Firefox,
            // Zen, this run of Petal only), and whether it was the one tab with its address.
            s.tabID = tab.id
            s.tabElement = tab.element
            s.shared = tab.shared
            offers.append(s)
        }
        if !scene.file.isEmpty {
            var s = stick(.file)
            s.path = scene.file
            s.title = (scene.file as NSString).lastPathComponent
            s.bookmark = scene.fileBookmark   // made with the read, off the main thread
            s.fileID = scene.fileID
            offers.append(s)
        }
        // The person in a chat's conversation: their note shows beside their conversation in any chat app.
        // Only with what tells them apart (their contact, or the chat's address for them): a name alone could be two
        // people, so then the note goes on the conversation's window.
        if let identity = PersonRead.identity(name: scene.person, handle: scene.personHandle, contacts: contacts) {
            var s = NoteStick(kind: .person)
            // The app they were noted in: only so the place is scrubbed for the tools once that app is kept private
            // (NoteStick.told); where the note shows never looks at it.
            s.app = scene.app
            s.appName = appName
            s.title = scene.person
            s.contact = identity.contact
            s.handle = identity.handle
            offers.append(s)
        }
        offers.append(stick(.window))
        offers.append(stick(.app))
        return offers
    }

    /// The notebook a new note on this place goes to: the one last used there, else the default.
    func notebook(for stick: NoteStick?) -> String {
        guard let stick else { return defaultNotebook }
        let site = NoteText.host(stick.url)
        let key = site.isEmpty ? stick.app : site
        if let last = local.lastNotebook[key], store.notebook(last) != nil { return last }
        return defaultNotebook
    }

    private func remember(_ notebook: String, for stick: NoteStick?) {
        guard let stick else { return }
        let site = NoteText.host(stick.url)
        local.lastNotebook[site.isEmpty ? stick.app : site] = notebook
        local.save(pending: store.pendingIDs)
    }

    /// A new note on `stick`, open with the keyboard. `body`: what it starts with.
    @discardableResult
    /// `window`: the frame (Accessibility's coordinates) of the window it's made on, when that isn't the one in
    /// front (a drop on a window behind): its spot is recorded against that window.
    /// `open` false: made without opening it on the desk (Petal's viewer opens it in its margin).
    func make(on stick: NoteStick, in chosen: String? = nil, body: String = "", quote: String? = nil, chat: String = "", at point: CGPoint? = nil,
              window: CGRect? = nil, expecting: NoteShelf.KeyboardRequests.Target? = nil, open opening: Bool = true) -> PaperNote? {
        var file = NoteFile(body: body)
        file.places = [stick]
        file.chat = chat
        let notebook = chosen.flatMap { store.notebook($0) != nil ? $0 : nil } ?? notebook(for: stick)
        guard let paper = store.make(file, in: notebook) else { return nil }
        remember(paper.notebook, for: stick)
        if body.isEmpty { fresh.insert(paper.key) }
        // Made with only the words selected, as a quote: still fresh, and let go if nothing is written under it.
        if let quote, !body.isEmpty, body == quote { fresh.insert(paper.key); madeWith[paper.key] = body }
        if let point {
            if stick.kind == .desktop || stick.kind == .screen { local.desk[paper.noteID] = [point.x, point.y] }
            else if let frame = window ?? frame {
                let rect = CGRect(x: point.x, y: point.y - PaperLook.folded, width: PaperLook.folded, height: PaperLook.folded)
                local.spots[paper.noteID] = NoteSpot.stick(panel: rect, window: NoteRules.appKitFrame(frame, primaryHeight: primaryHeight))
            }
        }
        guard opening else { return paper }
        if let scene, stick.kind != .desktop, stick.kind != .screen, let index = NoteMatch.best([stick], scene) { here[paper.key] = index }
        open(paper.key, expecting: expecting)
        if stick.kind == .desktop || stick.kind == .screen { refreshSpaces() }
        return paper
    }

    /// The notebook the Petal Notes window shows, while it's open on one.
    var libraryNotebook: String? {
        guard app.notesWindow.window?.isVisible == true, case .notebook(let name) = app.notesWindow.model.shelf, store.notebook(name) != nil else { return nil }
        return name
    }

    /// A new note on the Desktop showing (under the pointer), in `notebook` (else the one new notes go in), open to
    /// write in near the middle of that screen: "+ Note" in Petal Notes, and the note pad or ⌃⌥N with a window of
    /// Petal's in front. It's a Desktop note like any other: a click elsewhere folds it there; empty, it goes only
    /// when it's put away or its Desktop is left.
    func newOnDesktop(in notebook: String? = nil) {
        guard on, takesChanges() else { return }
        let mouse = NSEvent.mouseLocation
        let screen = (Screens.all.first { $0.frame.contains(mouse) } ?? Screens.main)?.visibleFrame ?? .zero
        let corner = CGPoint(x: screen.midX - PaperLook.openWidth / 2, y: screen.midY + 220)
        resolveDesktop { [weak self] number in
            guard let self else { return }
            guard let desk = NoteShelf.desktopAnchor(number: number) else { return self.say("Petal couldn't tell which Desktop is showing, so no note was made.") }
            self.make(on: desk, in: notebook, at: corner)
        }
    }

    /// ⌃⌥N: a new note on what's in front: the selected sentence, else its tab, its file, its window; on the
    /// Desktop, the Desktop.
    func newHere() { noteOnSelection() }

    /// "Note" by a selection: a new note on that sentence (its page or file); its text is read again here, under
    /// petal_look's rule, never taken from the button's capture. `near` shows what Petal says when it makes no
    /// note, by the selection.
    func note(on quote: String, near: ((String) -> Bool)? = nil) { noteOnSelection(near: near) }

    /// A new note on what's in front: the selected sentence, read and checked (`passage`), else its tab, file,
    /// window or Desktop. A selection refused (a secret, a field named for one, an app made private, the window or
    /// tab changed while it was read) makes no note at all: never a note without the check.
    private func noteOnSelection(near: ((String) -> Bool)? = nil, again: Bool = true) {
        guard on else { return }
        sayNear = near
        // Petal's viewer with the keyboard: a note on its selection (checked), else its page or slide, in its margin
        // (through the same readiness gate, in the viewer's own way of making a note).
        if let viewer = app.viewers.front { return viewer.newNote() }
        guard let running = NSWorkspace.shared.frontmostApplication else { return }
        // A window of Petal's own in front (Petal Notes, Settings): a note on the Desktop showing, in the notebook
        // Petal Notes shows (else the one new notes go in), open on its own.
        if running.processIdentifier == getpid() { return newOnDesktop(in: libraryNotebook) }
        guard takesChanges() else { return }
        // Without Accessibility no window can be read: the note goes on the Desktop showing, and that's said.
        guard Windows.trusted else {
            return resolveDesktop { [weak self] number in
                guard let self else { return }
                guard let desk = NoteShelf.desktopAnchor(number: number) else { return self.say(Self.unknownFront) }
                guard self.make(on: desk) != nil else { return }
                self.say("On your Desktop: Petal needs Accessibility to stick notes to windows.")
            }
        }
        let name = running.localizedName ?? ""
        let privacy = ClaudePanel.privacy.now
        let ticket = looks
        // No note, and why: said (by the selection when it was asked there) and kept in Petal's log. A read that only
        // came back stale or unreadable (an app slow to answer for a moment) is tried once more first: the person
        // asked for this note.
        func none(_ why: String, mayRetry: Bool = false) {
            if mayRetry, again {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.noteOnSelection(near: near, again: false) }
                return
            }
            PetalLog.notes.notice("no note made: \(why, privacy: .public)")
            say(why)
        }
        Self.read(running, mac: local.mac, anchors: fileAnchors) { scene, read in
            // A read refused (stale, or its app no longer in front): no note.
            guard self.activate(scene, read: read, ticket: ticket) else { return none(Self.frontChanged, mayRetry: true) }
            self.passage(in: scene, privacy: privacy) { selected in
                // Checked again after the selection read: still the active scene, its app still in front.
                guard NoteShelf.mayCreate(activated: true, activePID: self.scene?.pid, activeWindow: self.scene?.window, readPID: scene.pid,
                                          readWindow: scene.window, frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) else {
                    return none(Self.frontChanged, mayRetry: true)
                }
                let passage: (quote: String, before: String, after: String)?
                switch selected {
                case .refused: return none("Petal doesn't keep that selection in a note.")
                case .changed: return none(Self.frontChanged, mayRetry: true)
                case .none: passage = nil
                case .text(let quote, let before, let after): passage = (quote, before, after)
                }
                // Filtered again as it's used: an app made private since the read gives nothing of itself.
                let (scene, read) = Self.filtered(scene, read, since: privacy)
                guard let first = self.places(for: scene, read: read, appName: name, passage: passage).first else { return none(Self.unknownFront, mayRetry: true) }
                // Where the sentence itself can't be the place (an app with no page or file to find it in again), the
                // note goes on the window and starts with the words that were selected, so they aren't lost.
                let body = first.kind == .passage ? "" : NoteShelf.quoted(passage?.quote)
                self.make(on: first, body: body, quote: body.isEmpty ? nil : body)
                self.sayNear = nil
            }
        }
    }

    /// The selection in `scene`'s app, as one read: refused when petal_look's rule says no (Assist.selectionInSecret),
    /// when its window, tab or the private apps changed between the scene and the selection, or when the app is
    /// private now; the window, tab or private apps changed since the scene (whatever was selected): `.changed`;
    /// nothing selected: `.none`. Off the main thread, answered on it.
    static let unknownFront = "Petal couldn't tell where you are, so no note was made."
    static let frontChanged = "What's in front changed while Petal looked, so no note was made."

    func passage(in scene: NoteScene, privacy: Int, _ done: @escaping @MainActor (Selected) -> Void) {
        let pid = scene.pid, bundle = scene.app
        Self.queue.async {
            let read = Self.selection(pid: pid)
            var same = read.window == scene.window
            // A tab's selection only while that same tab still shows (its id or tab-strip button, its address).
            if same, let tab = scene.tab {
                let now = Browsers.activeTab(pid: pid, bundleID: bundle)
                same = now.map { ($0.id != nil && $0.id == tab.id || $0.element != nil && $0.element == tab.element) && NoteRules.sameURL($0.url, tab.url) } ?? false
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Whatever was or wasn't selected: a window or tab that changed, or private apps that changed,
                    // since the scene was read makes the read stale. An app kept private all along gives no text.
                    guard same, ClaudePanel.privacy.current(privacy) else { return done(.changed) }
                    switch read.result {
                    case .text where self.app.assist.neverLook(bundle): done(.refused)
                    default: done(read.result)
                    }
                }
            }
        }
    }

    /// Dragged from ✦ and let go at `point` (AppKit's coordinates): a blank note there, on the window under it,
    /// else on the Desktop.
    /// `point`: the real pointer (what's under it is hit); `paperAt`: where the paper lands, when that's offset from it.
    /// `onScreen`: let go holding Option: the note is kept on the screen itself, there, whatever is under it.
    func note(at point: CGPoint, paperAt: CGPoint? = nil, onScreen: Bool = false) {
        guard on, takesChanges() else { return }
        let landing = paperAt ?? point
        if onScreen {
            drops += 1
            guard let anchor = NoteShelf.screenAnchor(mac: local.mac) else { return say(Self.unknownFront) }
            make(on: anchor, at: landing)
            return
        }
        let ax = CGPoint(x: point.x, y: primaryHeight - point.y)
        let me = getpid()
        drops += 1
        let drop = drops
        let screens = Screens.all.map { (frame: $0.frame, id: Spaces.screenID($0)) }
        // The window list is the WindowServer's: asked off the main thread, and what it found checked again before
        // the note is made (Petal Notes still on, no newer drop, the app still running, the window still there).
        DispatchQueue.global(qos: .userInitiated).async {
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let hit = info.first { entry in
                guard (entry[kCGWindowLayer as String] as? Int) == 0, let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                      let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
                return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0).contains(ax)
            }
            let pid = hit?[kCGWindowOwnerPID as String] as? pid_t
            let number = hit?[kCGWindowNumber as String] as? CGWindowID
            let title = hit?[kCGWindowName as String] as? String ?? ""
            // That window's own frame (the window server's, top-left: Accessibility's coordinates), for the note's spot.
            let bounds = (hit?[kCGWindowBounds as String] as? [String: CGFloat]).map {
                CGRect(x: $0["X"] ?? 0, y: $0["Y"] ?? 0, width: $0["Width"] ?? 0, height: $0["Height"] ?? 0)
            }
            // No window under it: the Desktop that screen shows, read here (off the main thread).
            let target = screens.first { $0.frame.contains(point) }?.id
            let desktop: Int? = hit == nil ? target.flatMap { Spaces.desktops([$0])[$0] } : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.on, drop == self.drops else { return }
                    guard let pid, let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else {
                        guard let desktop else { return self.say("Petal couldn't tell which Desktop that is, so no note was made.") }
                        var desk = NoteStick(kind: .desktop)
                        desk.desktop = desktop
                        self.make(on: desk, at: landing)
                        return
                    }
                    self.noteOnDropped(running, window: number, frame: bounds, title: title, at: landing, drop: drop)
                }
            }
        }
    }

    @ObservationIgnored private var drops = 0
    @ObservationIgnored private var spaceTokens: [NSObjectProtocol] = []

    /// The Desktop a screen shows (the one under the pointer, or `screen`), read off the main thread; nil when it
    /// can't be told. Everything that sticks a note to a Desktop asks here and refuses without a number.
    func resolveDesktop(on screen: NSScreen? = nil, _ done: @escaping @MainActor (Int?) -> Void) {
        let target = screen ?? Screens.all.first { $0.frame.contains(NSEvent.mouseLocation) } ?? Screens.main
        guard let id = target.flatMap(Spaces.screenID) else { return done(nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            let number = Spaces.desktops([id])[id]
            DispatchQueue.main.async { MainActor.assumeIsolated { done(number) } }
        }
    }

    static let desktopUnknown = "Petal couldn't tell which Desktop is showing, so nothing was changed."

    /// Handles of a conflict's papers beyond the note's own (by paper key), for this run.
    @ObservationIgnored private var handlesSaving = false

    /// A note's handle for tools (made the first time; saved a moment later, once for many).
    func noteHandle(_ noteID: String) -> String {
        let had = local.handles?[noteID] != nil
        // Checked against the vault's redaction when its index is at hand (never read from the Keychain here).
        let index = VaultIndex.cached()
        let made = local.handle(noteID, redact: index.map { index in { index.redacted($0) } })
        if !had, !handlesSaving {
            handlesSaving = true
            DispatchQueue.main.async { self.handlesSaving = false; self.local.save(pending: self.store.pendingIDs) }
        }
        return made
    }

    /// The note for a drop on `running`'s window `number`, once what's in front of that app is read and the window
    /// is checked to be still there (off the main thread).
    private func noteOnDropped(_ running: NSRunningApplication, window number: CGWindowID?, frame bounds: CGRect?, title: String, at point: CGPoint, drop: Int) {
        let ticket = looks
        let name = running.localizedName ?? ""
        let pid = running.processIdentifier
        // The private apps as they were when the read began: filtered again after the last wait.
        let privacy = ClaudePanel.privacy.now
        Self.read(running, mac: local.mac, anchors: fileAnchors) { scene, read in
            guard self.on, drop == self.drops, !running.isTerminated, let number else { return }
            // Another window than the one read: the person in it is read from that window itself (never the front
            // window's), and only in a chat app that isn't kept private; else none.
            let other = scene.window != number
            let chat = other && PersonRead.isChat(scene.app) && !self.app.assist.neverLook(scene.app)
            let bundle = scene.app
            DispatchQueue.global(qos: .userInitiated).async {
                let alive = (CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]])?
                    .contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid } ?? false
                var there: (name: String, handle: String)?
                if alive, chat, Windows.trusted, ClaudePanel.privacy.current(privacy) {
                    let element = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(element, 0.3)
                    let all: [AXUIElement] = Windows.value(element, kAXWindowsAttribute) ?? []
                    if let target = all.first(where: { Windows.id(of: $0) == number }) {
                        let own: String = Windows.value(target, kAXTitleAttribute) ?? title
                        let found = Self.person(in: target, title: own, app: bundle, appName: name)
                        if !found.name.isEmpty { there = found }
                    }
                }
                let person = there
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard alive, self.on, drop == self.drops, !running.isTerminated else { return self.say("That window closed before the note could go on it.") }
                        // The front window of that app is the one under the drop: its tab and file. Another of its
                        // windows: that window alone.
                        var scene = scene
                        var read = read
                        if scene.window != number {
                            scene = scene.retargeted(to: number, title: title, person: person)
                            if !scene.person.isEmpty {
                                scene.personContact = PersonRead.contact(handle: scene.personHandle, contacts: self.contacts) ?? ""
                            }
                        }
                        // Filtered again right before its offers (the app made private meanwhile, or private apps
                        // changed): nothing of a private app's window, tab or file is kept (NoteShelf.refilterDrop).
                        if NoteShelf.refilterDrop(readPrivacy: privacy, nowPrivacy: ClaudePanel.privacy.now, appPrivate: self.app.assist.neverLook(scene.app)) {
                            (scene, read) = Self.filtered(scene, read, since: privacy)
                        }
                        if read.window == number { self.activate(scene, read: read, ticket: ticket) }
                        let offers = self.places(for: scene, read: read, appName: name)
                        // Brought forward for it (not in front now): its keyboard request waits for that app and window.
                        let bringing = read.window != number || !running.isActive
                        let target = bringing ? NoteShelf.KeyboardRequests.Target(pid: pid, window: number) : nil
                        if let first = offers.first(where: { $0.kind != .passage }) {
                            self.make(on: first, at: point, window: read.window == number ? read.frame ?? bounds : bounds, expecting: target)
                        }
                        // Another window than the one in front: it comes forward (the pointer stays), and the note with it.
                        if read.window != number || !running.isActive { self.bringForward(pid: pid, window: number) }
                    }
                }
            }
        }
    }

    /// A blank paper following the pointer out of the note pad or the AI button; let go over the dock, it's nothing.
    /// Let go anywhere else, the note is made right there: on the window under it, else on that Desktop; holding
    /// Option, on the screen itself.
    func dragPaper(ended: Bool) {
        let mouse = NSEvent.mouseLocation
        let option = NSEvent.modifierFlags.contains(.option)
        if ended {
            ghost?.orderOut(nil)
            ghost = nil
            ghostKept = nil
            let overDock = app.docks.shown && app.docks.panels.values.contains { $0.contentFrame.contains(mouse) }
            // The real pointer is hit-tested; only the paper's landing is offset (NoteShelf.dropPoints).
            let drop = NoteShelf.dropPoints(pointer: mouse)
            if !overDock { note(at: drop.hit, paperAt: drop.paper, onScreen: option) }
            return
        }
        // Holding Option says where it will go: under the paper, "Stays on screen".
        if ghost != nil, ghostKept != option {
            ghostKept = option
            (ghost?.contentView as? NSHostingView<PaperGhost>)?.rootView = PaperGhost(color: store.color(of: defaultNotebook), kept: option)
        }
        if ghost == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            ghostKept = option
            panel.contentView = NSHostingView(rootView: PaperGhost(color: store.color(of: defaultNotebook), kept: option))
            panel.setContentSize(PaperGhost.size)
            ghost = panel
        }
        // The paper's top-left corner 20 points up and left of the pointer, where the note lands (NoteShelf.dropPoints).
        ghost?.setFrameOrigin(NSPoint(x: mouse.x - 20 - PaperGhost.margin, y: mouse.y + 20 + PaperGhost.margin - PaperGhost.size.height))
        ghost?.orderFrontRegardless()
    }

    /// Whether the paper being dragged says "Stays on screen" (Option held), as last drawn.
    @ObservationIgnored private var ghostKept: Bool?

    private func bringForward(pid: pid_t, window number: CGWindowID) {
        Self.queue.async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            let all: [AXUIElement] = Windows.value(app, kAXWindowsAttribute) ?? []
            if let element = all.first(where: { Windows.id(of: $0) == number }) {
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                    self.lookAgain(after: 0.25)
                }
            }
        }
    }

    /// The selected text in the app `pid` and a little of the text around it, when the app says. Off the main thread.
    enum Selected { case none, refused, changed, text(String, String, String) }

    /// The selected text in the app `pid` and a little of the text around it, when the app says, with the window it
    /// was read in: refused when petal_look's rule says no (Assist.selectionInSecret). Off the main thread.
    nonisolated static func selection(pid: pid_t) -> (result: Selected, window: CGWindowID?) {
        guard Windows.trusted else { return (.none, nil) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let window: CGWindowID? = (Windows.value(app, kAXFocusedWindowAttribute) as AXUIElement?).flatMap { Windows.id(of: $0) }
        guard let focused: AXUIElement = Windows.value(app, kAXFocusedUIElementAttribute) else { return (.none, window) }
        // petal_look's rule exactly: nothing from a field holding, named for, or filled with a secret, nor any text
        // holding a vault secret.
        if Assist.selectionInSecret(focused, pid: pid, window: window) { return (.refused, window) }
        guard let text: String = Windows.value(focused, kAXSelectedTextAttribute) else { return (.none, window) }
        let quote = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard quote.count >= 2 else { return (.none, window) }
        var before = "", after = ""
        if let rangeValue: AXValue = Windows.value(focused, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            AXValueGetValue(rangeValue, .cfRange, &range)
            func string(_ location: Int, _ length: Int) -> String {
                var cf = CFRange(location: max(0, location), length: max(0, length))
                guard length > 0, let value = AXValueCreate(.cfRange, &cf) else { return "" }
                var raw: CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(focused, kAXStringForRangeParameterizedAttribute as CFString, value, &raw) == .success else { return "" }
                return raw as? String ?? ""
            }
            before = string(range.location - 80, min(80, range.location))
            after = string(range.location + range.length, 80)
        }
        return (.text(quote, before, after), window)
    }

    // MARK: The quick question

    /// The quick question opened: what's in front then is where Stick here sticks it.
    func capture() {
        captured = nil
        captures += 1
        guard on, let running = NSWorkspace.shared.frontmostApplication, running.processIdentifier != getpid() else { return }
        let name = running.localizedName ?? ""
        let privacy = ClaudePanel.privacy.now
        // This opening's own capture: one from an earlier opening, arriving late, is dropped (NoteShelf.captureCurrent).
        let generation = captures
        Self.read(running, mac: local.mac, anchors: fileAnchors) { scene, read in
            guard NoteShelf.captureCurrent(generation, latest: self.captures) else { return }
            self.captured = (scene, read, read.tab?.url ?? "", name, privacy)
        }
    }

    var canStick: Bool { on && captured != nil }

    @ObservationIgnored private var captures = 0

    /// Stick here: the quick question's conversation becomes a note on what was in front, open there.
    func stick(_ messages: [Agent.Message], chat: UUID) {
        guard takesChanges(), let captured else { return }
        var lines: [String] = []
        if let first = messages.first(where: { $0.kind == .user }) {
            let title = first.text.split(separator: "\n").first.map(String.init) ?? ""
            lines.append("# " + (title.count > 70 ? String(title.prefix(69)) + "…" : title))
        }
        for message in messages {
            switch message.kind {
            case .user: lines.append(contentsOf: message.text.components(separatedBy: "\n"))
            case .claude: lines.append(contentsOf: message.text.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 })
            default: continue
            }
            lines.append("")
        }
        while lines.last == "" { lines.removeLast() }
        // Read before the conversation: filtered again now, so an app made private since gives nothing of itself.
        let (scene, read) = Self.filtered(captured.scene, captured.read, since: captured.privacy)
        let offers = places(for: scene, read: read, appName: captured.name)
        guard let place = offers.first(where: { $0.kind != .passage }) else { return say(Self.unknownFront) }
        // Captured before: only the new note's anchor, never the active scene (NoteShelf.mayBecomeActive refuses a
        // captured read); the note shows once its place is next read in front.
        if let paper = make(on: place, body: lines.joined(separator: "\n"), chat: chat.uuidString) { fresh.remove(paper.key) }
        lookAgain(after: 0.05)
    }

    // MARK: The letterhead's menus

    /// Where it's stuck: stick it here instead, also here, or take it off one of its places.
    func placeMenu(_ key: String) {
        guard let paper = store.paper(key) else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Stuck to", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (index, stick) in paper.file.places.enumerated() {
            let item = NSMenuItem(title: Self.describe(stick), action: nil, keyEquivalent: "")
            item.representedObject = index
            let sub = NSMenu()
            // A file's note: the file in Petal's viewer, at its page or slide, with its notes in the margin.
            if ViewerFiles.offersViewer(stick) {
                sub.addItem(ActionItem("Open in Petal's viewer") { [weak self] in self?.openInViewer(stick) })
            }
            // A page's note: back to that page.
            if NoteTasks.web(stick.url) != nil, stick.kind != .file {
                sub.addItem(ActionItem("Open this page") { NoteTasks.openWeb(stick.url) })
            }
            if paper.file.places.count > 1 { sub.addItem(ActionItem("Take it off here") { [weak self] in self?.unstick(key, index) }) }
            if !sub.items.isEmpty { item.submenu = sub } else { item.isEnabled = false }
            menu.addItem(item)
        }
        // The place it shows at now, checked: the key viewer's margin, else the last look's window.
        let showing = shownIndex(key)
        for item in menu.items { if let index = item.representedObject as? Int { item.state = showing == index ? .on : .off } }
        let offers = stickOffers(key)
        if !offers.isEmpty {
            menu.addItem(.separator())
            let title = NSMenuItem(title: "Move it to", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for offer in offers { menu.addItem(ActionItem(Self.describe(offer)) { [weak self] in self?.restick(key, [offer]) }) }
            let also = NSMenuItem(title: "Also stick it to", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for offer in offers { sub.addItem(ActionItem(Self.describe(offer)) { [weak self] in self?.restick(key, paper.file.places + [offer]) }) }
            also.submenu = sub
            menu.addItem(also)
        }
        // A browser in front that hasn't been asked for its tabs yet: until it is, a note there is on its window.
        // Asked here, where a tab is first wanted (macOS shows its own prompt, once), never by surprise.
        if app.viewers.front == nil, let browser = scene?.app, Browsers.kind(browser) != nil, Browsers.waiting(browser) {
            if offers.isEmpty { menu.addItem(.separator()) }
            menu.addItem(ActionItem("Let Petal see \(Apps.name(browser))’s tabs…") { [weak self] in
                self?.app.browsers.ask(browser) { _ in self?.lookAgain(after: 0) }
            })
        }
        menu.addItem(.separator())
        // The Desktop the note's screen shows, read when chosen (off the main thread): only with its number is the note
        // moved there; its places stay as they are until then, and stay unknown.
        let screen = panels[key]?.screen
        menu.addItem(ActionItem("Move it to this Desktop") { [weak self] in
            self?.resolveDesktop(on: screen) { number in
                guard let self else { return }
                guard let desk = NoteShelf.desktopAnchor(number: number) else { return self.say(Self.desktopUnknown) }
                self.restick(key, [desk])
            }
        })
        // On the screen itself: it shows at its spot on every Desktop, whatever is in front (its other places stay,
        // and by its own window in front it still shows there). Ticked, choosing it again takes it off, unless the
        // screen is its only place.
        let kept = keptOnScreen(paper)
        let keep = ActionItem("Keep it on screen") { [weak self] in self?.keepOnScreen(key) }
        keep.state = kept ? .on : .off
        keep.isEnabled = NoteShelf.screenToggled(paper.file.places, mac: local.mac) != nil
        menu.addItem(keep)
        menu.addItem(.separator())
        // Hidden until its tab or Petal Notes brings it back (a note on its own Desktop or the screen stays there).
        if putsAway(key) { menu.addItem(ActionItem("Put away") { [weak self] in self?.putAway(key) }) }
        menu.addItem(ActionItem("Move to Trash") { [weak self] in self?.throwAway(key) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// "Keep it on screen", from the letterhead's menu: the screen added to the note's places, where the paper is
    /// right now, or taken off again (NoteShelf.screenToggled).
    func keepOnScreen(_ key: String) {
        guard let paper = store.paper(key), let places = NoteShelf.screenToggled(paper.file.places, mac: local.mac) else { return }
        // It stays where it is: the paper's top-left corner now is its spot on the screen.
        if !keptOnScreen(paper), let panel = panels[key], panel.unveiled {
            let rect = panel.frame.insetBy(dx: PaperLook.margin, dy: PaperLook.margin)
            local.desk[paper.noteID] = [rect.minX, rect.maxY]
            local.save(pending: store.pendingIDs)
        }
        restick(key, places)
    }

    /// What "Move it to" offers a note, from the current place (the one rule for "here"): Petal's viewer
    /// with the keyboard, its file at the page or slide shown (ViewerModel.fileAnchor), never the last scene outside
    /// it; else what the last look found in front (filtered again for privacy). Never a passage, nor a place the note
    /// already has.
    func stickOffers(_ key: String) -> [NoteStick] {
        guard let paper = store.paper(key) else { return [] }
        let offers: [NoteStick]
        if let viewer = app.viewers.front {
            // Only once its file's identity is in: nothing to offer until then.
            offers = viewer.fileAnchor().map { [$0] } ?? []
        } else if let cached = scene, let cachedRead = front, cached.window != nil {
            // Cached from the last look: filtered again, an app made private since gives nothing of itself.
            let (scene, front) = Self.filtered(cached, cachedRead, since: scenePrivacy)
            let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            offers = places(for: scene, read: front, appName: name)
        } else {
            offers = []
        }
        return offers.filter { offer in offer.kind != .passage && !paper.file.places.contains { $0.samePlace(offer) } }
    }

    /// Which of a note's places it shows at now: in the key viewer's margin, else by the window in front.
    func shownIndex(_ key: String) -> Int? {
        if let viewer = app.viewers.front {
            guard let paper = store.paper(key), let shown = viewer.notes.first(where: { $0.paper.key == key })?.place else { return nil }
            return paper.file.places.firstIndex { $0.samePlace(shown) }
        }
        return here[key]
    }

    /// A file's place opened in Petal's viewer: its file found by the one resolver the margin and comments use
    /// (ViewerFiles: its own file wherever it went, else its bookmark's, else its path's), off the main thread, then
    /// checked as any file the viewer opens. A place whose bookmark finds nothing opens nothing (never its old path).
    /// `done`: whether it opened.
    func openInViewer(_ stick: NoteStick, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        let mac = local.mac
        Self.queue.async {
            let found = ViewerFiles.locate(stick, mac: mac, follow: ViewerLoader.follow)?.path
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let found else {
                        self.say("Petal can't find that file any more.")
                        return done(false)
                    }
                    self.app.viewers.open(path: found, page: stick.page ?? stick.slide) { result in
                        if case .failure(let refusal) = result { self.say(refusal.description) }
                        done((try? result.get()) != nil)
                    }
                }
            }
        }
    }

    func restick(_ key: String, _ places: [NoteStick]) {
        // The letterhead's menu, on a paper's own panel and in Petal's viewer's margin alike.
        guard takesChanges(), let paper = store.paper(key) else { return }
        guard !store.readOnly(paper) else { return say("This note has two versions: keep one first.") }
        guard store.change(key, touch: false, edit: { $0.places = places }) != nil else { return }
        if let scene, let index = NoteMatch.best(places, scene) { here[key] = index } else { here[key] = nil }
        if places.contains(where: { $0.kind == .desktop }) { faces[key] = .folded }
        layout()
        // Its Desktop or the screen: placed there now (the Desktop's number read first when one is needed).
        refreshSpaces()
        placeDesktop()
    }

    private func unstick(_ key: String, _ index: Int) {
        guard let paper = store.paper(key), paper.file.places.indices.contains(index), paper.file.places.count > 1 else { return }
        var places = paper.file.places
        places.remove(at: index)
        restick(key, places)
    }

    /// Which notebook: another, a new one, or this notebook's color.
    func notebookMenu(_ key: String) {
        guard let paper = store.paper(key) else { return }
        let menu = NSMenu()
        for book in store.notebooks {
            let item = ActionItem(book.name) { [weak self] in self?.move(key, to: book.name) }
            item.state = book.name == paper.notebook ? .on : .off
            item.image = Self.swatch(store.color(of: book.name))
            menu.addItem(item)
        }
        menu.addItem(ActionItem("New notebook…") { [weak self] in
            guard let self, let name = Self.askName("New notebook", "Name it") else { return }
            let colors = ["#a550a7", "#f74f9e", "#f7821b", "#ffc600", "#62ba46", "#8c8c8c", "#007aff"]
            let made = self.store.ensureNotebook(name, color: colors[self.store.notebooks.count % colors.count])
            self.move(key, to: made)
        })
        menu.addItem(.separator())
        let color = NSMenuItem(title: "\(paper.notebook)'s color", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let choices: [(String, String)] = [("Mac's accent color", "accent"), ("Blue", "#007aff"), ("Purple", "#a550a7"), ("Pink", "#f74f9e"),
                                           ("Orange", "#f7821b"), ("Yellow", "#ffc600"), ("Green", "#62ba46"), ("Graphite", "#8c8c8c")]
        for (name, value) in choices {
            let item = ActionItem(name) { [weak self] in self?.recolor(paper.notebook, value) }
            item.image = Self.swatch(value == "accent" ? NSColor.controlAccentColor : NSColor(hex: value) ?? .gray)
            let current = store.notebook(paper.notebook)?.color ?? ""
            item.state = (current.isEmpty ? "accent" : current) == value ? .on : .off
            sub.addItem(item)
        }
        color.submenu = sub
        menu.addItem(color)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// The one move, from the letterhead and the note tools alike: what's typed is saved first, the move goes
    /// through the note's session, and its panel, editor and everything showing it follow it (`rekey`, from the
    /// store, for every change of a note's file). `done`: the note where it is now, or nil.
    func move(_ key: String, to notebook: String, live: (@Sendable () -> Bool)? = nil, then done: @escaping @MainActor (PaperNote?) -> Void = { _ in }) {
        guard takesChanges() else { return done(nil) }
        editors[key]?.flush()
        store.move(key, to: notebook, live: live) { moved in
            if let moved {
                self.remember(moved.notebook, for: moved.file.places.first)
                self.layout()
            }
            done(moved)
        }
    }

    /// A notebook's color, kept on its cover (made if it has none).
    func recolor(_ notebook: String, _ value: String) { store.recolor(notebook, value) }

    /// A notebook renamed in the Petal Notes window: what this Mac remembers by its name follows it.
    func renamedNotebook(_ old: String, to new: String) {
        local.lastNotebook = local.lastNotebook.mapValues { NoteLibrary.same($0, old) ? new : $0 }
        local.save(pending: store.pendingIDs)
    }

    /// Every paper drawn again (a notebook turned Private or back: whether pictures of the screen may show it).
    func refreshPanels() {
        for panel in panels.values { panel.refresh() }
        for panel in tabPanels.values { panel.refreshSharing() }
        app.popups.notebookPrivacyChanged()
    }

    /// Petal's own windows showing a Private notebook's note now (papers, edge tabs, a notebook's fan, the Petal Notes
    /// window): every picture Petal takes leaves them out (NotePrivacy.excludedWindows).
    func privateWindowNumbers() -> Set<Int> {
        var surfaces = panels.map { key, panel in NotePrivacy.Surface(window: panel.windowNumber, showsPrivate: isPrivate(key)) }
        surfaces += tabPanels.map { key, panel in NotePrivacy.Surface(window: panel.windowNumber, showsPrivate: panel.showsPrivate) }
        if let fan = app.popups.privateFanWindow { surfaces.append(NotePrivacy.Surface(window: fan, showsPrivate: true)) }
        if let window = app.notesWindow.window { surfaces.append(NotePrivacy.Surface(window: window.windowNumber, showsPrivate: app.notesWindow.showsPrivate)) }
        return NotePrivacy.excludedWindows(surfaces)
    }

    /// Whether a paper's notebook is Private.
    func isPrivate(_ key: String) -> Bool {
        guard let paper = store.paper(key) else { return false }
        // Its notebook's privacy as the store counts it: a notebook the latest read didn't find is unknown, so Private.
        return store.privateBooks.contains { NoteLibrary.same($0, paper.notebook) }
    }

    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: Radius.chip, yRadius: Radius.chip).fill()
            return true
        }
    }

    static func askName(_ title: String, _ message: String) -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Make")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let name = alert.runModal() == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespaces) : ""
        return name.isEmpty ? nil : name
    }

    // MARK: Refreshing

    /// The files changed (here or on another Mac): papers and tabs show what they say now.
    func refresh() {
        guard on else { return }
        // Answers held through a conflict: applied once their note is one writable paper (after Keep this one).
        helpers.applyHeld()
        WindowEvents.shared.titles("papernotes", pagesStuck || windowsStuck)
        // Notes shown on this Mac before it last quit show again.
        for paper in store.notes where local.shown.contains(paper.noteID) && faces[paper.key] == nil { faces[paper.key] = .folded }
        for (key, panel) in panels where store.paper(key) == nil {
            panel.conceal()
            panels[key] = nil
            faces[key] = nil
        }
        if let scene, let front {
            let (scene, read) = Self.filtered(scene, front, since: scenePrivacy)
            apply(scene, read: read, scan: false, fresh: false)
            // A note's file places changed since the file in front was resolved (one synced onto it, another
            // Mac's record, an older bookmark): it's read again, through the same gate as every look.
            if !scene.resolves(fileAnchors) { look() }
        } else { look() }
        // From the Spaces last read; read (off the main thread) when none were yet and a note is on a Desktop.
        if Self.spaces.isEmpty { refreshSpaces() } else { placeDesktop() }
        // Every paper and tab redrawn, and left out of Petal's pictures again if its notebook turned Private (here or elsewhere).
        for panel in panels.values { panel.refresh() }
        for panel in tabPanels.values { panel.refreshSharing() }
        app.popups.notebookPrivacyChanged()
        watchPeople()
    }

    /// For snapshots: Stick here as if a page were in front.
    /// For `Petal --viewer-check` only: notes on, with made-up notes and no folder read (the tools answer).
    func previewReady() { ready = true }

    /// For `Petal --viewer-check` only: the last look as if `scene` had been read in front (nothing read).
    func previewScene(_ scene: NoteScene, read: ClaudePanel.FrontRead = ClaudePanel.FrontRead()) {
        self.scene = scene
        front = read
        scenePrivacy = ClaudePanel.privacy.now
    }

    func previewCapture() {
        ready = true   // snapshots: nothing to load
        var tab = NoteTab(url: "https://guide.example/day-one", title: "Day one")
        tab.id = "1"
        captured = (NoteScene(mac: local.mac, app: "com.apple.Safari", pid: 1, window: 1, title: "Day one", tab: tab), ClaudePanel.FrontRead(), tab.url, "Safari",
                    ClaudePanel.privacy.now)
    }

    /// For snapshots: nothing read, nothing shown.
    func preview(here: [String: Int], found: [String: Bool]) {
        self.here = here
        self.found = found
    }

    /// For `Petal --bench-notes` only: a made-up window in front with these notes on it (nothing read), for `layout`
    /// to lay out as it does any window's notes. Headless, no panel is ordered in (NSPanel.unveil).
    func previewWindow(_ scene: NoteScene?, frame: CGRect?, here: [String: Int]) {
        self.scene = scene
        self.frame = frame
        self.here = here
        scenePrivacy = ClaudePanel.privacy.now
    }

    /// For `Petal --bench-notes` only: a paper's own panel and the tabs on the window's edge, to draw them off screen.
    func benchPanel(_ key: String) -> NSPanel? { panels[key] }
    var benchTabs: [NSPanel] { Array(tabPanels.values) }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

// MARK: - Panels

/// One note's paper on the screen: a panel that takes the keyboard without taking it from the app in front, grows
/// in place (its top-left corner stays) as it opens, and goes where the person drags it.
final class NotePanel: NSPanel {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private weak var desk: NoteDesk?
    private(set) var key: String
    /// Where it rests now: by its window, on its Desktop (just above the icons while it isn't open), or on the
    /// screen itself (above the windows, on every Desktop).
    enum Rest { case window, desktop, screen }
    var rest: Rest = .window {
        didSet { level = restingLevel }
    }
    /// Shown off any window (on its Desktop or the screen): a focus change leaves it where it is.
    var desktop: Bool { rest != .window }
    private var restingLevel: NSWindow.Level { rest == .desktop && desk?.faces[key] != .open ? Self.desktopLevel : .floating }
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    /// Held by the pointer (picked up, not yet let go).
    var held: Bool { dragStart != nil }

    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    init(desk: NoteDesk, key: String) {
        self.desk = desk
        self.key = key
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hosting.sizingOptions = [.intrinsicContentSize]
        contentView = hosting
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        // Petal is a background app: without this, the paper's tooltips never show.
        allowsToolTipsWhenApplicationIsInactive = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        refresh()
    }

    override var canBecomeKey: Bool { true }

    func rekey(_ key: String) {
        self.key = key
        refresh()
    }

    func refresh() {
        guard let desk else { return }
        // A Private notebook's paper: left out of Petal's own pictures (privateWindowNumbers); macOS is asked not to
        // share it too, a best effort only.
        sharingType = desk.isPrivate(key) ? .none : .readOnly
        hosting.rootView = AnyView(NotePanelContent(desk: desk, key: key, panel: self).environment(PetalApp.shared))
    }

    /// The paper's size now (folded, open or its back).
    var paperSize: CGSize {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        return CGSize(width: size.width - PaperLook.margin * 2, height: size.height - PaperLook.margin * 2)
    }

    /// Shows the paper at `paperFrame` (AppKit's coordinates).
    func place(paperFrame: CGRect) {
        guard dragStart == nil else { return }
        let target = Self.whole(paperFrame.insetBy(dx: -PaperLook.margin, dy: -PaperLook.margin).integral)
        if frame != target { setFrame(target, display: true) }
        unveil()
        level = restingLevel
    }

    /// Its size changed (opened, folded, the writing grew): it grows from its top-left corner; one the person left
    /// somewhere on its window grows from the corner it's stuck by, exactly as layout places it (NoteDesk.spotFrame),
    /// so it never jumps as it opens or its writing grows.
    func refit() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        // Held by the pointer: left where it is until it's let go.
        guard dragStart == nil else { return }
        // Beside the window in front: every paper there placed again the one way, so none covers another.
        if unveiled, rest == .window, desk?.refitBeside(key) == true {
            level = restingLevel
            return
        }
        var wanted = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        let paper = CGSize(width: size.width - PaperLook.margin * 2, height: size.height - PaperLook.margin * 2)
        if unveiled, let spotted = desk?.spotFrame(key, size: paper) { wanted = spotted.insetBy(dx: -PaperLook.margin, dy: -PaperLook.margin) }
        // Kept whole on its screen: a note near an edge that grows (opened, turned over) moves in from it.
        let target = Self.whole(wanted.integral)
        if target != frame { setFrame(target, display: true, animate: false) }
        level = restingLevel
    }

    /// `rect` whole on the screen it's mostly on (NoteShelf.wholeOnScreen).
    static func whole(_ rect: NSRect) -> NSRect {
        let screens = Screens.all
        let area = { (screen: NSScreen) -> CGFloat in let cut = screen.frame.intersection(rect); return cut.isNull ? 0 : cut.width * cut.height }
        guard let screen = screens.max(by: { area($0) < area($1) }).flatMap({ area($0) > 0 ? $0 : nil }) ?? Screens.main else { return rect }
        return NoteShelf.wholeOnScreen(rect, visible: screen.visibleFrame)
    }

    /// The keyboard, only for a paper layout already showed (NoteShelf.mayTakeKeyboard): never unveiled here.
    func takeKeyboard() {
        refit()
        guard NoteShelf.mayTakeKeyboard(shown: unveiled) else { return }
        makeKeyAndOrderFront(nil)
    }

    /// Escape, on any face of the note (open, turned over, folded, a conflict's read-only paper; from its editor too,
    /// which passes it here): folded with the keyboard handed back (NoteDesk.fold's Escape), the one way.
    override func cancelOperation(_ sender: Any?) { desk?.fold(key, escape: true) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return cancelOperation(nil) }
        super.keyDown(with: event)
    }

    /// The Edit menu's keys (⌘C, ⌘V, ⌘Z…) here too, after the paper's own (EditMenu.keyEquivalent).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditMenu.keyEquivalent(event, window: self, viewsHandled: super.performKeyEquivalent(with: event))
    }

    override func resignKey() {
        super.resignKey()
        // Clicked away from every note (not onto another): the open ones fold back.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !(NSApp.keyWindow is NotePanel) else { return }
                self.desk?.clickedAway()
            }
        }
    }

    // MARK: Dragging

    /// The pointer went down on the paper (PaperGrab): a drag from here moves it by exactly what the pointer moves,
    /// from where it was pressed. Layout leaves it alone until it's let go.
    func grab() { dragStart = (NSEvent.mouseLocation, frame.origin) }

    /// Let go without moving.
    func released() { dragStart = nil }

    func drag() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, frame.origin) }
        guard let start = dragStart else { return }
        setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    func dragEnded() {
        guard dragStart != nil else { return }
        dragStart = nil
        desk?.moved(key, to: frame.insetBy(dx: PaperLook.margin, dy: PaperLook.margin))
    }
}

/// What a note's panel shows: its paper, as the desk says it is now.
struct NotePanelContent: View {
    let desk: NoteDesk
    let key: String
    weak var panel: NotePanel?

    /// What changes a paper's height from a helper: its file as written, a run, a question waiting on it.
    private func helperShape(_ paper: PaperNote) -> String {
        let run = desk.helpers.runs[paper.noteID]
        return "\(paper.revision?.count ?? 0)|\(paper.file.ink.count)|\(run != nil)|\(run?.sticky?.agent.pendingAsk.count ?? 0)|\(run?.paused == true)|\(desk.helpers.card(paper.noteID)?.id.uuidString ?? "")"
    }

    var body: some View {
        if let paper = desk.store.paper(key) {
            let face = desk.faces[key] ?? .folded
            let head = desk.letterhead(paper)
            PaperView(paper: paper, color: desk.store.color(of: paper.notebook), glass: desk.glass, face: face,
                      place: head.place, notebook: head.notebook, others: head.others, footer: desk.footer(paper),
                      keyboard: desk.keyboard == key, editorHeight: desk.heights[key] ?? 0, desk: desk,
                      conflict: desk.store.readOnly(paper), unsaved: desk.store.failed.contains(key),
                      pictureTrouble: desk.troubleCount(paper),
                      // The paper itself, under its words and controls (PaperGrab): picked up from anywhere on it that
                      // isn't a control or the writing being edited (the editor takes its own clicks and drags): all
                      // of a folded paper, and an open one's top strip, letterhead row, margins and back.
                      grab: PaperGrab(panel: panel, tap: face == .folded ? { desk.open(key) } : nil))
                .modifier(FoldedTouch(folded: face == .folded, open: { desk.open(key) }, drag: { panel?.drag() }, dropped: { panel?.dragEnded() }))
                .padding(PaperLook.margin)
                .onChange(of: face) { _, _ in DispatchQueue.main.async { panel?.refit() } }
                // A helper's ink, step or card came or went: the paper fits itself again.
                .onChange(of: helperShape(paper)) { _, _ in DispatchQueue.main.async { panel?.refit() } }
        }
    }
}

/// A folded paper opens with a click and moves with a drag, anywhere on it.
struct FoldedTouch: ViewModifier {
    let folded: Bool
    let open: () -> Void
    let drag: () -> Void
    let dropped: () -> Void

    func body(content: Content) -> some View {
        if folded {
            content.contentShape(.rect)
                .onTapGesture(perform: open)
                .gesture(DragGesture(minimumDistance: 3).onChanged { _ in drag() }.onEnded { _ in dropped() })
        } else {
            content
        }
    }
}

/// One tab on the window's edge: hovering shows the note's first line, clicking shows or hides the note.
final class EdgeTabPanel: NSPanel {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private weak var desk: NoteDesk?
    private var edgeTab: EdgeTab?
    private var outside = true
    private var anchor: CGPoint = .zero
    private var hovering = false

    init(desk: NoteDesk) {
        self.desk = desk
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = hosting
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }

    /// A right-click (or a Control-click) on a tab: its menu.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)), let tab = edgeTab {
            desk?.tabMenu(tab.ids)
            return
        }
        super.sendEvent(event)
    }

    /// At its line on `window` (Accessibility's frame): hanging out of the right edge, or in over it with no room.
    func show(_ tab: EdgeTab, outside: Bool, window: CGRect, primaryHeight: CGFloat) {
        self.edgeTab = tab
        self.outside = outside
        let top = primaryHeight - (window.minY + tab.y)
        anchor = CGPoint(x: window.maxX, y: top)
        draw()
        unveil()
    }

    /// A tab whose notes include a Private notebook's never shows in pictures of the screen (its hover says its title).
    func refreshSharing() {
        guard let tab = edgeTab, let desk else { return }
        showsPrivate = tab.ids.contains(where: desk.isPrivate)
        sharingType = showsPrivate ? .none : .readOnly
    }

    /// Its tab is for a Private notebook's note (its hover says its title): Petal's own pictures leave it out.
    private(set) var showsPrivate = false

    private func draw() {
        guard let tab = edgeTab, let desk else { return }
        refreshSharing()
        let label = hovering ? (desk.store.paper(tab.ids[0]).map { $0.file.title.isEmpty ? "Empty note" : $0.file.title } ?? "") + (tab.count > 1 ? "  +\(tab.count - 1)" : "") : ""
        // Only the tab itself takes the pointer: the room around it (for its shadow) lets clicks through to the window,
        // its scroll bar too.
        let view = EdgeTabView(tab: tab, colors: [:], outside: outside, hovering: hovering, label: String(label.prefix(60)))
            .contentShape(.rect)
            .onHover { [weak self] on in self?.hover(on) }
            .onTapGesture { [weak self] in
                guard let self, let tab = self.edgeTab else { return }
                self.desk?.tabClicked(tab.ids)
            }
            .padding(.vertical, 8).padding(.horizontal, 8)
        hosting.rootView = AnyView(view)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        // The tab's edge sits on the window's edge (the panel's 8 points of padding past it).
        let x = outside ? anchor.x - 8 : anchor.x - size.width + 8
        let y = anchor.y - size.height + 8
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height).integral, display: true)
    }

    private func hover(_ on: Bool) {
        guard on != hovering else { return }
        hovering = on
        draw()
    }

    /// No note's tab any more (kept to be used for another): hidden, holding nothing of the note it showed, and not
    /// hovered, so the next note's tab starts closed.
    func retire() {
        conceal()
        edgeTab = nil
        hovering = false
        hosting.rootView = AnyView(EmptyView())
        showsPrivate = false
        sharingType = .readOnly
    }
}

/// The dashed line from an open note to its sentence (the sketch's pin): drawn in a panel the pointer goes through.
final class PinPanel: NSPanel {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = hosting
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        // Under the notes and their tabs (one level down), over the windows: it never crosses a tab.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }

    /// From the end of the sentence to the note's left edge (AppKit's coordinates).
    func show(from start: CGPoint, to end: CGPoint, color: NSColor) {
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            .insetBy(dx: -4, dy: -4)
        guard box.width > 12 else { return conceal() }
        let a = CGPoint(x: start.x - box.minX, y: box.maxY - start.y)
        let b = CGPoint(x: end.x - box.minX, y: box.maxY - end.y)
        hosting.rootView = AnyView(PinLine(from: a, to: b, color: Color(nsColor: color)).frame(width: box.width, height: box.height))
        setFrame(box.integral, display: true)
        unveil(mouse: false)
    }
}

/// The sketch's pin: a curve, 1.5 points, dashed 3 and 4, at 55%.
struct PinLine: View {
    let from: CGPoint
    let to: CGPoint
    let color: Color

    var body: some View {
        Path { path in
            path.move(to: from)
            path.addCurve(to: to, control1: CGPoint(x: from.x + 90, y: from.y), control2: CGPoint(x: to.x - 90, y: to.y))
        }
        .stroke(color.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
    }
}

extension NSPanel {
    /// Hidden as GlassPanel hides (see its `hide`): clear and letting the mouse through, never ordered out. Ordering
    /// a window with macOS's glass out (and back in) waits on the window server for most of half a second; paper
    /// notes hide the same way, so a note's look never changes how it hides. One with the keyboard gives it back.
    func conceal() {
        guard alphaValue != 0 || !ignoresMouseEvents else { return }
        if isKeyWindow { resignKey() }
        let was = alphaValue
        alphaValue = 0
        ignoresMouseEvents = true
        // A paper hidden: what's on screen changed (NotePictures' retry weighs it again), and the pointer on it is
        // the arrow again.
        if was != 0, self is NotePanel {
            MainActor.assumeIsolated {
                NotePictures.shared.visibilityChanged()
                PaperCursor.hidden(self)
                // Hidden while it was held: let go of, so layout places it again when it next shows.
                (self as? NotePanel)?.released()
            }
        }
    }

    /// Showing again: on screen once, then only made opaque. `mouse`: whether it takes clicks (a pin never does).
    func unveil(mouse: Bool = true) {
        let was = unveiled
        // A headless run (a check, a bench) never orders a window of Petal's in: laid out and drawn, never shown.
        if !isVisible, !Headless.on { orderFrontRegardless() }
        if alphaValue != 1 { alphaValue = 1 }
        if ignoresMouseEvents == mouse { ignoresMouseEvents = !mouse }
        // A paper revealed: missing pictures on it are retried again (NotePictures' retry).
        if !was, self is NotePanel { MainActor.assumeIsolated { NotePictures.shared.visibilityChanged() } }
    }

    /// On the screen and seen (not concealed).
    var unveiled: Bool { isVisible && alphaValue > 0 }
}
