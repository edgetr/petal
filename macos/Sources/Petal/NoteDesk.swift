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
    /// Made just now and still empty: let go of if it's put away empty.
    @ObservationIgnored private var fresh: Set<String> = []

    nonisolated static let queue = DispatchQueue(label: "petal.notes.look", qos: .userInitiated)
    /// Narrowing a window for an open note: a newer turn (the note folded, notes off, quitting) makes one still
    /// waiting stand down.
    nonisolated static let roomTurn = Generation()

    var app: PetalApp { PetalApp.shared }
    var on: Bool { ready && app.config.bool("notes") }
    var glass: Bool { app.config.string("notesLook") == "glass" }
    var defaultNotebook: String {
        let name = app.config.string("notesNotebook")
        return name.isEmpty ? NoteShelf.inbox : name
    }

    // MARK: Starting

    func start() {
        // Writing a Petal before this one accepted and never saw land: put back first (NoteJournal.recover), from the
        // journal's own queue to the notes' queue.
        // File names are made from titles only after the vault's redaction (never a secret in a name); while the
        // vault can't be read, a plain name. And the names Petal made so, known again.
        NoteStore.nameRedactor = { text in VaultIndex.settled { $0.unreadable ? nil : $0.redacted(text) } ?? nil }
        store.onChange = { [weak self] in self?.refresh() }
        watchApps()
        // The one visibility signal for missing pictures: papers revealed and open now.
        NotePictures.shared.visible = { [weak self] in self?.picturesOnScreen() ?? [] }
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
            self.local.save(pending: store.pendingIDs)
        }
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
                    NoteJournal.queue.async {
                        // The journal as it was, and any recovery a launch before didn't finish: resumed, entry by entry.
                        let leftovers = NoteJournal.leftovers()
                        guard !leftovers.isEmpty else { return }
                        NoteStore.io.async { for holding in leftovers { NoteJournal.recover(holding, root: root) } }
                    }
                    self.store.switchRoot(to: root)
                    self.ready = true
                    // Read and watched only once the first folder is settled: the switch starts the store itself
                    // when it's done (and after every later switch).
                    if !self.store.switching { self.store.start() }
                    self.settingsChanged()
                }
            }
        }
    }

    /// `notes`, `notesLook` or `notesFolder` changed (or any setting did).
    func settingsChanged() {
        followFolderSetting()
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
            DispatchQueue.main.async {
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
    private func switchFolder(to root: URL) {
        lookSoon?.cancel()
        looks += 1
        giveBackAll {}
        for editor in editors.values { editor.flush() }
        editors = [:]
        for panel in panels.values { panel.conceal() }
        for panel in tabPanels.values { panel.conceal() }
        for panel in pinPanels.values { panel.conceal() }
        panels = [:]
        tabPanels = [:]
        pinPanels = [:]
        faces = [:]
        here = [:]
        keyboard = nil
        fresh = []
        store.switchRoot(to: root) { [weak self] in
            self?.look()
            self?.followFolderSetting()
        }
    }

    /// Something couldn't be done to the notes' files: said by the AI button for a moment.
    /// Said on the paper from its editor (a copy refused).
    func tell(_ text: String) { say(text) }

    private func say(_ text: String) {
        // Said by the AI button of the dock under the pointer (never a window-list lookup on the main thread); with
        // macOS's Dock chosen there's no button to say it by.
        let mouse = NSEvent.mouseLocation
        guard app.docks.shown, let dock = app.docks.panels.values.first(where: { $0.screen?.frame.contains(mouse) == true })?.dock
                ?? app.docks.panels.values.first?.dock else { return }
        app.tooltips.show(text, over: "claude", in: dock)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.app.tooltips.show(nil, over: "claude", in: dock) }
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
        let stuck = store.notes.contains { $0.file.places.contains { $0.kind != .desktop } }
        guard stuck || !here.isEmpty else { return }
        // One read at a time; looks asked for meanwhile are one follow-up, of what's in front by then
        // (NoteShelf.ReadGate): a slow browser's reads never pile up.
        guard reads.request() else { return }
        looks += 1
        let ticket = looks
        Self.read(running, mac: local.mac, tabs: pagesStuck, ticket: ticket) { scene, read in
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
    static func read(_ running: NSRunningApplication, mac: String, tabs: Bool = true, ticket: Int? = nil,
                     _ done: @escaping @MainActor (NoteScene, ClaudePanel.FrontRead) -> Void) {
        let pid = running.processIdentifier
        let app = running.bundleIdentifier ?? ""
        let privacy = ClaudePanel.privacy.now
        let quiet = PetalApp.shared.assist.neverLook(app)
        // The screen under the pointer, for the Desktop it shows (read below, off the main thread, when the app has
        // no window in front).
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main).flatMap(Spaces.screenID)
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
                var twins: Int?
                if let number = read.window, Windows.trusted {
                    let element = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(element, 0.3)
                    let all: [AXUIElement] = Windows.value(element, kAXWindowsAttribute) ?? []
                    if !quiet, ClaudePanel.privacy.current(privacy), let window = all.first(where: { Windows.id(of: $0) == number }),
                       let document: String = Windows.value(window, kAXDocumentAttribute), let url = URL(string: document), url.isFileURL {
                        file = url.path
                        bookmark = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))?.base64EncodedString() ?? ""
                    }
                    if !read.title.isEmpty { twins = all.filter { (Windows.value($0, kAXTitleAttribute) as String?) == read.title }.count }
                }
                var made = NoteScene(mac: mac, app: app, pid: pid, window: read.window, title: read.title, titleTwins: twins, tab: read.tab, file: file)
                made.fileBookmark = bookmark
                let scene = made
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        var (scene, read) = Self.filtered(scene, read, since: privacy)
                        scene.desktop = desktop ?? Self.desktopShowing(on: NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)
                        done(scene, read)
                    }
                }
            }
        }
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
        if fits != here { here = fits }
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
        guard !anchored.isEmpty, !here.contains(where: { key, index in
            store.paper(key).flatMap { $0.file.places.indices.contains(index) ? $0.file.places[index].path : nil } == scene.file
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

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// The visible frame (Accessibility's coordinates) of the screen a window is on.
    private func visible(for window: CGRect) -> CGRect? {
        let screens = NSScreen.screens
        guard let screen = NoteRules.screen(for: NoteRules.appKitFrame(window, primaryHeight: primaryHeight), in: screens.map(\.frame)),
              let visible = screens.first(where: { $0.frame == screen })?.visibleFrame else { return nil }
        return CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
    }

    /// The tabs on the window in front, and its notes that are showing beside it.
    func layout() {
        // Mission Control open, or the front window changed and its read isn't in yet: nothing shows meanwhile.
        if missionControlOpen || awaitingRead { return concealUnplaced() }
        defer { reconcileRoom() }
        prunePassageGeometry()
        guard on, let frame, let scene, scene.window != nil else {
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
            return EdgeNote(id: key, line: lines[key], color: notebookKey(paper.notebook), faded: NoteShelf.faded(modified: paper.file.modified, now: now))
        }
        let tabs = EdgeLayout.tabs(edgeNotes, height: frame.height)
        let visible = visible(for: frame) ?? frame
        // Inside the window's right edge, as the sketch has them; the window's own edge stays in sight beside them.
        let outside = false
        var keep: Set<String> = []
        for tab in tabs {
            let key = tab.ids[0]
            keep.insert(key)
            let panel = tabPanels[key] ?? EdgeTabPanel(desk: self)
            tabPanels[key] = panel
            panel.show(tab, outside: outside, window: frame, primaryHeight: primaryHeight)
        }
        for (key, panel) in tabPanels where !keep.contains(key) {
            panel.conceal()
            tabPanels[key] = nil
        }
        // The notes showing on this window, stacked down its right side where nobody moved them.
        var placed: [CGRect] = []
        let showing = here.keys.filter { faces[$0] != nil && !hiddenForTab($0) }.sorted { (lines[$0] ?? 0, $0) < (lines[$1] ?? 0, $1) }
        for key in showing {
            let panel = panel(for: key)
            // Placed by its window (it fits the window in front): not the Desktop's, whatever else it's stuck to.
            panel.desktop = false
            let size = panel.paperSize
            var rect: CGRect
            if let paper = store.paper(key), let spot = local.spots[paper.noteID] {
                let window = NoteRules.appKitFrame(frame, primaryHeight: primaryHeight)
                let screen = NSScreen.screens.first { $0.frame.intersects(window) }?.visibleFrame ?? window
                rect = spot.frame(size: size, window: window, screen: screen)
            } else {
                let top = lines[key] ?? tabs.first { $0.ids.contains(key) }?.y ?? EdgeLayout.top
                var ax = NoteRoom.beside(window: frame, visible: visible, size: size, top: top)
                while let clash = placed.first(where: { $0.intersects(ax) }), ax.maxY < visible.maxY { ax.origin.y = clash.maxY + 10 }
                placed.append(ax)
                rect = NoteRules.appKitFrame(ax, primaryHeight: primaryHeight)
            }
            panel.place(paperFrame: rect)
            shown(key, panel)
        }
        // Shown only where its one placement says it belongs now; every other paper hidden.
        for (key, panel) in panels where !showing.contains(key) && placementNow(key) != .desktop { panel.conceal() }
        drawPins(showing)
        reconcilePassages()
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

    /// The pictures on screen: those of papers whose panel is revealed (not hidden by going clear) and open
    /// (NoteShelf.picturesOnScreen), editors and read-only papers alike.
    func picturesOnScreen() -> Set<String> {
        NoteShelf.picturesOnScreen(panels.compactMap { key, panel in
            store.paper(key).map { (panel.unveiled, faces[key] == .open, $0.url.deletingLastPathComponent().path, $0.file.body) }
        })
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
            let pin = pinPanels[key] ?? PinPanel()
            pinPanels[key] = pin
            pin.show(from: CGPoint(x: words.maxX, y: words.midY), to: CGPoint(x: paperFrame.minX, y: paperFrame.maxY - 28),
                     color: store.color(of: paper.notebook))
        }
        for (key, pin) in pinPanels where !keep.contains(key) {
            pin.conceal()
            pinPanels[key] = nil
        }
    }

    /// A notebook's color as the tabs name it.
    private func notebookKey(_ notebook: String) -> String { store.color(of: notebook).hex }

    /// Where a paper belongs right now (NoteShelf.placementNow): by the window in front, on a Desktop showing now, or
    /// nowhere.
    func placementNow(_ key: String) -> NoteShelf.Placement {
        let desktops = store.paper(key)?.file.places.filter { $0.kind == .desktop }.map(\.desktop) ?? []
        // A window placement counts only once it's fresh: never while a read is awaited (permission lost, focus
        // changed) or its tab is being read again.
        return NoteShelf.placementNow(window: here[key], desktops: desktops, showing: Set(Self.spaces.values),
                                      windowValid: !awaitingRead && !hiddenForTab(key))
    }

    private func isDesktop(_ key: String) -> Bool { placementNow(key) == .desktop }

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
        guard on, !Headless.on, store.notes.contains(where: { $0.file.places.contains { $0.kind == .desktop } }) else {
            if !Self.spaces.isEmpty { Self.spaces = [:]; placeDesktop() }
            return
        }
        let screens = NSScreen.screens.compactMap(Spaces.screenID)
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
    /// placed by the window in front (NoteShelf.placement: the window wins).
    func placeDesktop() {
        guard on, !Headless.on, !missionControlOpen else { return }
        var showing: Set<String> = []
        for screen in NSScreen.screens {
            guard let number = Self.desktopShowing(on: screen) else { continue }
            // The validated placement (placementNow's rule): a stale window placement never keeps a note off it.
            let notes = store.notes.filter { paper in
                NoteShelf.onDesktop(window: here[paper.key], desktops: paper.file.places.filter { $0.kind == .desktop }.map(\.desktop), screenDesktop: number,
                                    windowValid: !awaitingRead && !hiddenForTab(paper.key))
            }
            for (index, paper) in notes.enumerated() {
                showing.insert(paper.key)
                if faces[paper.key] == nil { faces[paper.key] = .folded }
                let panel = panel(for: paper.key)
                panel.desktop = true
                let size = panel.paperSize
                let visible = screen.visibleFrame
                var origin = CGPoint(x: visible.minX + 60 + CGFloat(index % 5) * (PaperLook.folded + 24),
                                     y: visible.maxY - 60 - CGFloat(index / 5) * (PaperLook.folded + 24))
                if let point = local.desk[paper.noteID], point.count == 2 { origin = CGPoint(x: point[0], y: point[1]) }
                panel.place(paperFrame: CGRect(x: origin.x, y: origin.y - size.height, width: size.width, height: size.height))
                shown(paper.key, panel)
            }
        }
        for (key, panel) in panels where panel.desktop && !showing.contains(key) {
            panel.desktop = false
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
    func open(_ key: String, expecting: NoteShelf.KeyboardRequests.Target? = nil) {
        guard let paper = store.paper(key) else { return }
        // Open in Petal's viewer's margin: closed there first (one editor per note).
        releaseFromViewer(paper)
        faces[key] = .open
        keyboard = key
        local.shown = Array(Set(local.shown + [paper.noteID]))
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

    func fold(_ key: String) {
        keyboardWanted.cancel(key)
        guard faces[key] == .open || faces[key] == .back else { return }
        Self.roomTurn.cancel()
        editors[key]?.flush()
        let hadKeyboard = panels[key]?.isKeyWindow == true
        faces[key] = .folded
        if keyboard == key { keyboard = nil }
        letGoIfEmpty(key)
        faceChanged(key)
        if hadKeyboard { giveKeyboardBack() }
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
            MainActor.assumeIsolated { self?.lastOtherApp = pid }
        }
    }

    func hide(_ key: String) {
        keyboardWanted.cancel(key)
        Self.roomTurn.cancel()
        editors[key]?.flush()
        faces[key] = nil
        if keyboard == key { keyboard = nil }
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

    private func isDesktopNote(_ key: String) -> Bool { store.paper(key)?.file.places.contains { $0.kind == .desktop } == true }

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

    /// A note made just now and put away with nothing written goes (to the Trash: never deleted outright).
    func letGoIfEmpty(_ key: String) {
        guard fresh.contains(key), let paper = store.paper(key), faces[key] != .open,
              NoteShelf.mayTrash(bodyEmpty: paper.file.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, picturesPending: store.picturesPending(key),
                                 importing: store.importing(key))
        else { return }
        fresh.remove(key)
        faces[key] = nil
        panels[key]?.conceal()
        panels[key] = nil
        _ = paper
        store.trash(key)
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
        var wanted: (number: CGWindowID, pid: pid_t, frame: CGRect, target: CGRect?)?
        if on, !quitting, let frame, let scene, let number = scene.window,
           here.keys.contains(where: { faces[$0] == .open && local.spots[store.paper($0)?.noteID ?? ""] == nil }) {
            let target = visible(for: frame).flatMap { NoteRoom.narrowed(window: frame, visible: $0, note: PaperLook.openWidth) }
            wanted = (number, scene.pid, frame, target)
        }
        let turn = Self.roomTurn.next()
        Self.queue.async {
            let plan = NoteRoom.reconcile(narrowed: Set(Self.ledger.keys), wanted: wanted?.number)
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
    /// the paper can't be written (read only: one of a conflict's papers).
    func write(_ key: String, body: String, base: String?) -> String? {
        guard let paper = store.paper(key) else { return nil }
        if store.readOnly(paper) {
            // Typed just as it became one of two papers: kept in the copy beside it, never dropped.
            if paper.version == nil, paper.file.body != body { store.keepAside(key, body: body) }
            return nil
        }
        // Petal's own changes since (a place followed or added) don't make this a conflict; words changed do.
        let base = NoteShelf.rebase(editor: base, current: paper.revision, currentBody: paper.file.body)
        guard paper.file.body != body else { return base }
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fresh.remove(key) }
        // Links the person typed (an address alone on a line): their pages' titles may be fetched; a link already
        // in the note (from sync) never is.
        let links = { (text: String) in Set(NoteBlock.blocks(text).compactMap { if case .link(let url) = $0 { url } else { nil } }) }
        for url in links(body).subtracting(links(paper.file.body)) { LinkPreviews.shared.requested(url) }
        return store.change(key, base: base) { $0.body = body }
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
        if keyboard == old { keyboard = new }
        if hovered == old { hovered = new }
        keyboardWanted.rekey(old, new)
        heights = NoteShelf.rekeyed(heights, old, new)
        here = NoteShelf.rekeyed(here, old, new)
        found = NoteShelf.rekeyed(found, old, new)
        if fresh.remove(old) != nil { fresh.insert(new) }
        lines = NoteShelf.rekeyed(lines, old, new)
        passageRects = NoteShelf.rekeyed(passageRects, old, new)
        anchors = NoteShelf.rekeyed(anchors, old, new)
        lost = NoteShelf.rekeyed(lost, old, new)
        editors = NoteShelf.rekeyed(editors, old, new)
        editorTokens = NoteShelf.rekeyed(editorTokens, old, new)
        pinPanels = NoteShelf.rekeyed(pinPanels, old, new)
        if let tab = tabPanels.removeValue(forKey: old) { tab.conceal() }
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
        if isDesktop(key) {
            local.desk[paper.noteID] = [rect.minX, rect.maxY]
        } else if let frame {
            local.spots[paper.noteID] = NoteSpot.stick(panel: rect, window: NoteRules.appKitFrame(frame, primaryHeight: primaryHeight))
        }
        local.save(pending: store.pendingIDs)
        // A note dragged off its window's side (or onto the Desktop) no longer needs the room it was given.
        reconcileRoom()
    }

    // MARK: What the paper says

    func letterhead(_ paper: PaperNote) -> (place: String, notebook: String, others: String) {
        let places = paper.file.places
        let index = here[paper.key] ?? (places.firstIndex { $0.kind == .desktop } ?? 0)
        let place = places.indices.contains(index) ? places[index].label(found: found[paper.key] ?? true) : "not stuck anywhere"
        let rest = places.indices.filter { $0 != index }
        let others = rest.count == 1 ? places[rest[0]].label() : rest.isEmpty ? "" : "\(rest.count) places"
        return (place, paper.notebook, others)
    }

    func footer(_ paper: PaperNote) -> String { Self.when(paper.file.modified) }

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
            s.mode = modeHere
            return s
        }
        switch NoteShelf.frontOffer(window: scene.window, none: read.none) {
        case .window: break
        case .unknown: return []
        case .desktop:
            // Which Desktop it is (read off the main thread with the scene), or no note: never one stuck to no Desktop.
            return NoteShelf.desktopAnchor(number: scene.desktop, mode: modeID(desktop: scene.desktop)).map { [$0] } ?? []
        }
        if let passage, !passage.quote.isEmpty, scene.tab != nil || !scene.file.isEmpty {
            var s = stick(.passage)
            s.quote = String(passage.quote.prefix(500))
            s.before = String(passage.before.suffix(80))
            s.after = String(passage.after.prefix(80))
            s.url = scene.tab?.url ?? ""
            s.path = scene.tab == nil ? scene.file : ""
            // A sentence in a file follows the file through its bookmark, as a file's note does.
            if scene.tab == nil { s.bookmark = scene.fileBookmark }
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
    func make(on stick: NoteStick, body: String = "", chat: String = "", at point: CGPoint? = nil, window: CGRect? = nil,
              expecting: NoteShelf.KeyboardRequests.Target? = nil, open opening: Bool = true) -> PaperNote? {
        var file = NoteFile(body: body)
        file.places = [stick]
        file.chat = chat
        let notebook = notebook(for: stick)
        guard let paper = store.make(file, in: notebook) else { return nil }
        remember(paper.notebook, for: stick)
        if body.isEmpty { fresh.insert(paper.key) }
        if let point {
            if stick.kind == .desktop { local.desk[paper.noteID] = [point.x, point.y] }
            else if let frame = window ?? frame {
                let rect = CGRect(x: point.x, y: point.y - PaperLook.folded, width: PaperLook.folded, height: PaperLook.folded)
                local.spots[paper.noteID] = NoteSpot.stick(panel: rect, window: NoteRules.appKitFrame(frame, primaryHeight: primaryHeight))
            }
        }
        guard opening else { return paper }
        if let scene, stick.kind != .desktop, let index = NoteMatch.best([stick], scene) { here[paper.key] = index }
        open(paper.key, expecting: expecting)
        if stick.kind == .desktop { refreshSpaces() }
        return paper
    }

    /// ⌃⌥N: a new note on what's in front: the selected sentence, else its tab, its file, its window; on the
    /// Desktop, the Desktop.
    func newHere() { noteOnSelection() }

    /// "Note" by a selection: a new note on that sentence (its page or file); its text is read again here, under
    /// petal_look's rule, never taken from the button's capture.
    func note(on quote: String) { noteOnSelection() }

    /// A new note on what's in front: the selected sentence, read and checked (`passage`), else its tab, file,
    /// window or Desktop. A selection refused (a secret, a field named for one, an app made private, the window or
    /// tab changed while it was read) makes no note at all: never a note without the check.
    private func noteOnSelection() {
        guard on, let running = NSWorkspace.shared.frontmostApplication, running.processIdentifier != getpid() else { return }
        let name = running.localizedName ?? ""
        let privacy = ClaudePanel.privacy.now
        let ticket = looks
        Self.read(running, mac: local.mac) { scene, read in
            // A read refused (stale, or its app no longer in front): no note.
            guard self.activate(scene, read: read, ticket: ticket) else { return self.say(Self.frontChanged) }
            self.passage(in: scene, privacy: privacy) { selected in
                // Checked again after the selection read: still the active scene, its app still in front.
                guard NoteShelf.mayCreate(activated: true, activePID: self.scene?.pid, activeWindow: self.scene?.window, readPID: scene.pid,
                                          readWindow: scene.window, frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) else {
                    return self.say(Self.frontChanged)
                }
                let passage: (quote: String, before: String, after: String)?
                switch selected {
                case .refused: return self.say("Petal doesn't keep that selection in a note.")
                case .changed: return self.say(Self.frontChanged)
                case .none: passage = nil
                case .text(let quote, let before, let after): passage = (quote, before, after)
                }
                // Filtered again as it's used: an app made private since the read gives nothing of itself.
                let (scene, read) = Self.filtered(scene, read, since: privacy)
                guard let first = self.places(for: scene, read: read, appName: name, passage: passage).first else { return self.say(Self.unknownFront) }
                self.make(on: first)
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
    func note(at point: CGPoint, paperAt: CGPoint? = nil) {
        guard on else { return }
        let landing = paperAt ?? point
        let ax = CGPoint(x: point.x, y: primaryHeight - point.y)
        let me = getpid()
        drops += 1
        let drop = drops
        let screens = NSScreen.screens.map { (frame: $0.frame, id: Spaces.screenID($0)) }
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
                        desk.mode = self.modeID(desktop: desktop)
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
        let target = screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let id = target.flatMap(Spaces.screenID) else { return done(nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            let number = Spaces.desktops([id])[id]
            DispatchQueue.main.async { MainActor.assumeIsolated { done(number) } }
        }
    }

    static let desktopUnknown = "Petal couldn't tell which Desktop is showing, so nothing was changed."

    /// The mode a Desktop is in (modes.json's workspaces, NoteShelf.modeID): never asked of the dock.
    func modeID(desktop: Int?) -> String { NoteShelf.modeID(desktop: desktop, workspaces: app.config.workspaces, defaultMode: app.config.defaultMode) }

    /// The mode of the Desktop under the pointer, from the Desktops last read (no window server on the main thread).
    var modeHere: String { modeID(desktop: Self.desktopShowing(on: NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)) }
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
        Self.read(running, mac: local.mac) { scene, read in
            guard self.on, drop == self.drops, !running.isTerminated, let number else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let alive = (CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]])?
                    .contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid } ?? false
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard alive, self.on, drop == self.drops, !running.isTerminated else { return self.say("That window closed before the note could go on it.") }
                        // The front window of that app is the one under the drop: its tab and file. Another of its
                        // windows: that window alone.
                        var scene = scene
                        var read = read
                        if scene.window != number { scene.tab = nil; scene.file = ""; scene.window = number; scene.title = title }
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

    /// A blank paper following the pointer out of the AI button; let go over the dock, it's nothing.
    func dragFromAI(ended: Bool) {
        let mouse = NSEvent.mouseLocation
        if ended {
            ghost?.orderOut(nil)
            ghost = nil
            let overDock = app.docks.shown && app.docks.panels.values.contains { $0.frame.contains(mouse) }
            // The real pointer is hit-tested; only the paper's landing is offset (NoteShelf.dropPoints).
            let drop = NoteShelf.dropPoints(pointer: mouse)
            if !overDock { note(at: drop.hit, paperAt: drop.paper) }
            return
        }
        if ghost == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let color = store.color(of: defaultNotebook)
            let view = ZStack(alignment: .top) {
                PaperLook.color(NoteInk.paper(PaperLook.rgb(color)))
                Rectangle().fill(Color(nsColor: color)).frame(height: 4)
            }
            .frame(width: 72, height: 72).clipShape(.rect(cornerRadius: 8)).modifier(PaperShadow(glass: false)).padding(12)
            .rotationEffect(.degrees(-4)).opacity(0.92)
            panel.contentView = NSHostingView(rootView: view)
            panel.setContentSize(NSSize(width: 100, height: 100))
            ghost = panel
        }
        ghost?.setFrameOrigin(NSPoint(x: mouse.x - 32, y: mouse.y - 68))
        ghost?.orderFrontRegardless()
    }

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
        Self.read(running, mac: local.mac) { scene, read in
            guard NoteShelf.captureCurrent(generation, latest: self.captures) else { return }
            self.captured = (scene, read, read.tab?.url ?? "", name, privacy)
        }
    }

    var canStick: Bool { on && captured != nil }

    @ObservationIgnored private var captures = 0

    /// Stick here: the quick question's conversation becomes a note on what was in front, open there.
    func stick(_ messages: [Agent.Message], chat: UUID) {
        guard let captured else { return }
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
            item.state = here[key] == index ? .on : .off
            let sub = NSMenu()
            // A file's note: the file in Petal's viewer, at its page or slide, with its notes in the margin.
            if stick.kind == .file, ViewerKind.of(stick.path) != nil {
                sub.addItem(ActionItem("Open in Petal's viewer") { [weak self] in self?.openInViewer(stick) })
            }
            if paper.file.places.count > 1 { sub.addItem(ActionItem("Take it off here") { [weak self] in self?.unstick(key, index) }) }
            if !sub.items.isEmpty { item.submenu = sub }
            menu.addItem(item)
        }
        if let cached = scene, let cachedRead = front, cached.window != nil {
            // Cached from the last look: filtered again, an app made private since gives nothing of itself.
            let (scene, front) = Self.filtered(cached, cachedRead, since: scenePrivacy)
            let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            let offers = places(for: scene, read: front, appName: name).filter { offer in !paper.file.places.contains { $0.samePlace(offer) } }
            if !offers.isEmpty {
                menu.addItem(.separator())
                let title = NSMenuItem(title: "Stick it here instead", action: nil, keyEquivalent: "")
                title.isEnabled = false
                menu.addItem(title)
                for offer in offers where offer.kind != .passage { menu.addItem(ActionItem(Self.describe(offer)) { [weak self] in self?.restick(key, [offer]) }) }
                let also = NSMenuItem(title: "Also stick it to", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for offer in offers where offer.kind != .passage { sub.addItem(ActionItem(Self.describe(offer)) { [weak self] in self?.restick(key, paper.file.places + [offer]) }) }
                also.submenu = sub
                menu.addItem(also)
            }
        }
        menu.addItem(.separator())
        // The Desktop the note's screen shows, read when chosen (off the main thread): only with its number is the note
        // moved there; its places stay as they are until then, and stay unknown.
        let screen = panels[key]?.screen
        menu.addItem(ActionItem("Put it on this Desktop") { [weak self] in
            self?.resolveDesktop(on: screen) { number in
                guard let self else { return }
                guard let desk = NoteShelf.desktopAnchor(number: number, mode: self.modeID(desktop: number)) else { return self.say(Self.desktopUnknown) }
                self.restick(key, [desk])
            }
        })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// A file's place opened in Petal's viewer: its file found again through its bookmark (off the main thread),
    /// then checked as any file the viewer opens.
    func openInViewer(_ stick: NoteStick) {
        let path = stick.path
        let bookmark = Data(base64Encoded: stick.bookmark)
        Self.queue.async {
            let found = bookmark.flatMap(ViewerLoader.follow)?.path
            let target = found.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? path
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.app.viewers.open(path: target, page: stick.page ?? stick.slide) { result in
                        if case .failure(let refusal) = result { self.say(refusal.description) }
                    }
                }
            }
        }
    }

    private func restick(_ key: String, _ places: [NoteStick]) {
        guard let paper = store.paper(key) else { return }
        guard !store.readOnly(paper) else { return say("This note has two versions: keep one first.") }
        guard store.change(key, touch: false, edit: { $0.places = places }) != nil else { return }
        if let scene, let index = NoteMatch.best(places, scene) { here[key] = index } else { here[key] = nil }
        if places.contains(where: { $0.kind == .desktop }) { faces[key] = .folded; refreshSpaces() }
        layout()
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
            guard let self, let name = Self.askName("New notebook", "What's it for? Its name:") else { return }
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

    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
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
        } else { look() }
        // From the Spaces last read; read (off the main thread) when none were yet and a note is on a Desktop.
        if Self.spaces.isEmpty { refreshSpaces() } else { placeDesktop() }
        for panel in panels.values { panel.refresh() }
    }

    /// For snapshots: Stick here as if a page were in front.
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
    var desktop = false {
        didSet { level = desktop && desk?.faces[key] != .open ? Self.desktopLevel : .floating }
    }
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?

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
        level = desktop && desk?.faces[key] != .open ? Self.desktopLevel : .floating
    }

    /// Its size changed (opened, folded, the writing grew): it grows from its top-left corner.
    func refit() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        // Kept whole on its screen: a note near an edge that grows (opened, turned over) moves in from it.
        let target = Self.whole(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height).integral)
        if target != frame { setFrame(target, display: true, animate: false) }
        level = desktop && desk?.faces[key] != .open ? Self.desktopLevel : .floating
    }

    /// `rect` whole on the screen it's mostly on (NoteShelf.wholeOnScreen).
    static func whole(_ rect: NSRect) -> NSRect {
        let screens = NSScreen.screens
        let area = { (screen: NSScreen) -> CGFloat in let cut = screen.frame.intersection(rect); return cut.isNull ? 0 : cut.width * cut.height }
        guard let screen = screens.max(by: { area($0) < area($1) }).flatMap({ area($0) > 0 ? $0 : nil }) ?? NSScreen.main else { return rect }
        return NoteShelf.wholeOnScreen(rect, visible: screen.visibleFrame)
    }

    /// The keyboard, only for a paper layout already showed (NoteShelf.mayTakeKeyboard): never unveiled here.
    func takeKeyboard() {
        refit()
        guard NoteShelf.mayTakeKeyboard(shown: unveiled) else { return }
        makeKeyAndOrderFront(nil)
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

    var body: some View {
        if let paper = desk.store.paper(key) {
            let face = desk.faces[key] ?? .folded
            let head = desk.letterhead(paper)
            PaperView(paper: paper, color: desk.store.color(of: paper.notebook), glass: desk.glass, face: face,
                      place: head.place, notebook: head.notebook, others: head.others, footer: desk.footer(paper),
                      keyboard: desk.keyboard == key, editorHeight: desk.heights[key] ?? 0, desk: desk,
                      conflict: desk.store.readOnly(paper), unsaved: desk.store.failed.contains(key),
                      pictureTrouble: desk.troubleCount(paper))
                .background {
                    // Open, the paper moves by its margins and letterhead's row, never by the writing (the editor
                    // takes its own clicks and drags).
                    Color.clear.contentShape(.rect)
                        .gesture(DragGesture(minimumDistance: 3).onChanged { _ in panel?.drag() }.onEnded { _ in panel?.dragEnded() })
                }
                .modifier(FoldedTouch(folded: face == .folded, open: { desk.open(key) }, drag: { panel?.drag() }, dropped: { panel?.dragEnded() }))
                .padding(PaperLook.margin)
                .onChange(of: face) { _, _ in DispatchQueue.main.async { panel?.refit() } }
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

    /// At its line on `window` (Accessibility's frame): hanging out of the right edge, or in over it with no room.
    func show(_ tab: EdgeTab, outside: Bool, window: CGRect, primaryHeight: CGFloat) {
        self.edgeTab = tab
        self.outside = outside
        let top = primaryHeight - (window.minY + tab.y)
        anchor = CGPoint(x: window.maxX, y: top)
        draw()
        unveil()
    }

    private func draw() {
        guard let tab = edgeTab, let desk else { return }
        let label = hovering ? (desk.store.paper(tab.ids[0]).map { $0.file.title.isEmpty ? "Empty note" : $0.file.title } ?? "") + (tab.count > 1 ? "  +\(tab.count - 1)" : "") : ""
        let view = EdgeTabView(tab: tab, colors: [:], outside: outside, hovering: hovering, label: String(label.prefix(60)))
            .padding(.vertical, 8).padding(.horizontal, 8)
            .contentShape(.rect)
            .onHover { [weak self] on in self?.hover(on) }
            .onTapGesture { [weak self] in
                guard let self, let tab = self.edgeTab else { return }
                self.desk?.tabClicked(tab.ids)
            }
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
        // A paper hidden: what's on screen changed (NotePictures' retry weighs it again).
        if was != 0, self is NotePanel { MainActor.assumeIsolated { NotePictures.shared.visibilityChanged() } }
    }

    /// Showing again: on screen once, then only made opaque. `mouse`: whether it takes clicks (a pin never does).
    func unveil(mouse: Bool = true) {
        let was = unveiled
        if !isVisible { orderFrontRegardless() }
        if alphaValue != 1 { alphaValue = 1 }
        if ignoresMouseEvents == mouse { ignoresMouseEvents = !mouse }
        // A paper revealed: missing pictures on it are retried again (NotePictures' retry).
        if !was, self is NotePanel { MainActor.assumeIsolated { NotePictures.shared.visibilityChanged() } }
    }

    /// On the screen and seen (not concealed).
    var unveiled: Bool { isVisible && alphaValue > 0 }
}
