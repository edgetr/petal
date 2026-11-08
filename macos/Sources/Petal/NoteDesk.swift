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
    /// Notes showing, each folded, open or turned over (by paper key).
    var faces: [String: PaperFace] = [:]
    /// The open note with the keyboard.
    var keyboard: String?
    /// Each open note's writing's height.
    var heights: [String: CGFloat] = [:]
    /// Notes of the window in front: the place of each that fits (by paper key), and the passages found there.
    private(set) var here: [String: Int] = [:]
    private(set) var found: [String: Bool] = [:]
    /// The tab a pointer is over (by its first note's key).
    var hovered: String?

    @ObservationIgnored var local = NoteLocal.load()
    @ObservationIgnored private var panels: [String: NotePanel] = [:]
    @ObservationIgnored private var tabPanels: [String: EdgeTabPanel] = [:]
    @ObservationIgnored private(set) var scene: NoteScene?
    /// The front window's frame (Accessibility's: top-left origin) and its read.
    @ObservationIgnored private(set) var frame: CGRect?
    @ObservationIgnored private var front: ClaudePanel.FrontRead?
    @ObservationIgnored private var lines: [String: CGFloat] = [:]
    /// Each passage found on the window in front: its words' bounds (Accessibility's coordinates).
    @ObservationIgnored private var passageRects: [String: CGRect] = [:]
    @ObservationIgnored private var pinPanels: [String: PinPanel] = [:]
    /// Each open editor: to save what's typed now (on quit, or as it closes), and put pictures in.
    @ObservationIgnored var editors: [String: NoteEditorHandle] = [:]
    @ObservationIgnored private var looks = 0
    @ObservationIgnored private var lookSoon: DispatchWorkItem?
    @ObservationIgnored private var listening = false
    /// Windows narrowed for an open note: their frame from before and the one Petal gave them.
    /// What was in front when the quick question opened, for Stick here.
    private(set) var captured: (scene: NoteScene, read: ClaudePanel.FrontRead, url: String, name: String)?
    @ObservationIgnored private var ghost: NSPanel?
    /// Made just now and still empty: let go of if it's put away empty.
    @ObservationIgnored private var fresh: Set<String> = []

    nonisolated static let queue = DispatchQueue(label: "petal.notes.look", qos: .userInitiated)
    /// Narrowing a window for an open note: a newer turn (the note folded, notes off, quitting) makes one still
    /// waiting stand down.
    nonisolated static let roomTurn = Generation()

    var app: PetalApp { PetalApp.shared }
    var on: Bool { app.config.bool("notes") }
    var glass: Bool { app.config.string("notesLook") == "glass" }
    var defaultNotebook: String {
        let name = app.config.string("notesNotebook")
        return name.isEmpty ? NoteShelf.inbox : name
    }

    // MARK: Starting

    func start() {
        store.switchRoot(to: NoteStore.rootFolder(setting: app.config.string("notesFolder")))
        store.onChange = { [weak self] in self?.refresh() }
        store.onPictures = { [weak self] key, pictures, at in self?.insertPictures(key, pictures, at: at) ?? false }
        store.onRekey = { [weak self] old, paper in self?.rekey(old, to: paper) }
        store.onProblem = { [weak self] text in self?.say(text) }
        store.keepAlive = { [weak self] key in self?.editors[key] != nil }
        Self.queue.async { Self.recoverNarrowed() }
        store.start()
        settingsChanged()
    }

    /// `notes`, `notesLook` or `notesFolder` changed (or any setting did).
    func settingsChanged() {
        let root = NoteStore.rootFolder(setting: app.config.string("notesFolder"))
        if root != store.root, !store.switching { switchFolder(to: root) }
        if on && !listening {
            listening = true
            WindowEvents.shared.listen("papernotes") { [weak self] event in self?.event(event) }
            look()
        } else if !on && listening {
            listening = false
            WindowEvents.shared.stopListening("papernotes")
            for editor in editors.values { editor.flush() }
            hideAll()
            // Notes off: every window narrowed for one gets its width back (unless the person changed it since).
            giveBackAll(wait: false)
        }
        for panel in panels.values { panel.refresh() }
        // A browser showing another tab says so only through its title: heard only while a note is on a page.
        WindowEvents.shared.titles("papernotes", on && pagesStuck)
    }

    private func event(_ event: WindowEvents.Event) {
        switch event.kind {
        case .moved, .resized: lookAgain(after: 0.03)
        case .activated, .focused, .closed, .titleChanged, .tabSwitched, .created, .minimized, .unminimized, .shown, .hidden, .quit: lookAgain(after: 0.12)
        case .space, .screens: lookAgain(after: 0.2); placeDesktop()
        case .missionControl: for panel in Array(panels.values) + tabPanels.values.map({ $0 as NSPanel }) { panel.orderOut(nil) }
        case .missionControlEnded: lookAgain(after: 0.1)
        default: break
        }
    }

    func lookAgain(after delay: Double) {
        lookSoon?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.look() }
        lookSoon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hideAll() {
        for panel in panels.values { panel.orderOut(nil) }
        for panel in tabPanels.values { panel.orderOut(nil) }
        for panel in pinPanels.values { panel.orderOut(nil) }
    }

    /// Petal quits: what's typed is saved and written, and narrowed windows get their width back, before it goes.
    func stop() {
        for editor in editors.values { editor.flush() }
        giveBackAll(wait: true)
        store.drain()
    }

    /// Another notes folder: what's typed is saved into the folder it was typed in (each note's session, drained off
    /// the main thread), every open note and editor of the old folder is put away, then the new folder's notes come.
    private func switchFolder(to root: URL) {
        for editor in editors.values { editor.flush() }
        editors = [:]
        for panel in panels.values { panel.orderOut(nil) }
        for panel in tabPanels.values { panel.orderOut(nil) }
        for panel in pinPanels.values { panel.orderOut(nil) }
        panels = [:]
        tabPanels = [:]
        pinPanels = [:]
        faces = [:]
        here = [:]
        keyboard = nil
        fresh = []
        store.switchRoot(to: root) { [weak self] in self?.look() }
    }

    /// Something couldn't be done to the notes' files: said by the AI button for a moment.
    private func say(_ text: String) {
        guard let dock = app.docks.focusedDock else { return }
        app.tooltips.show(text, over: "claude", in: dock)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.app.tooltips.show(nil, over: "claude", in: dock) }
    }

    // MARK: What's in front

    /// Reads the window in front (its browser tab, the file it shows), off the main thread, and shows its notes.
    func look() {
        guard on, !Headless.on else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let running = NSWorkspace.shared.frontmostApplication else { return }
        // Petal's own windows (the settings, a page) leave the notes where they are.
        guard running.processIdentifier != me else { return }
        // No note stuck to a window, tab or app: nothing to show on one, and nothing is read.
        let stuck = store.notes.contains { $0.file.places.contains { $0.kind != .desktop } }
        guard stuck || !here.isEmpty else { return }
        looks += 1
        let ticket = looks
        Self.read(running, mac: local.mac, tabs: pagesStuck) { scene, read in
            guard ticket == self.looks else { return }
            self.apply(scene, read: read)
        }
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
    static func read(_ running: NSRunningApplication, mac: String, tabs: Bool = true, _ done: @escaping @MainActor (NoteScene, ClaudePanel.FrontRead) -> Void) {
        let pid = running.processIdentifier
        let app = running.bundleIdentifier ?? ""
        let privacy = ClaudePanel.privacy.now
        let quiet = PetalApp.shared.assist.neverLook(app)
        ClaudePanel.readFront(of: running, tabs: tabs) { read in
            queue.async {
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
                        var scene = scene
                        var read = read
                        // The one final filter, as the result is used: an app kept private (now, or made private
                        // while it was read) leaves nothing but itself and its window: no title, tab, address or file.
                        if !ClaudePanel.privacy.current(privacy) || PetalApp.shared.assist.neverLook(app) {
                            scene = scene.privately
                            read.title = ""
                            read.tab = nil
                        }
                        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
                        scene.desktop = screen.flatMap { Spaces.desktop(on: $0) }
                        done(scene, read)
                    }
                }
            }
        }
    }

    /// `scan`: look for the passages again (not when only the files changed: the person typing in a note).
    private func apply(_ scene: NoteScene, read: ClaudePanel.FrontRead, scan: Bool = true) {
        let moved = self.scene?.window != scene.window || self.scene?.pid != scene.pid
        self.scene = scene
        front = read
        frame = read.frame
        var fits: [String: Int] = [:]
        if read.window != nil {
            for paper in store.notes where !paper.file.places.isEmpty {
                if let index = NoteMatch.best(paper.file.places, scene) { fits[paper.key] = index }
            }
            fits = recoverTabs(fits, scene)
        }
        if fits != here { here = fits }
        followTabs(scene)
        followFiles(scene)
        if moved {
            lines = [:]
            passageRects = [:]
            // Notes that were open on the window left behind fold.
            for (key, face) in faces where face == .open && fits[key] == nil { faces[key] = .folded }
            }
        layout()
        if scan || moved { findPassages(scene) }
        placeDesktop()
    }

    /// Notes found on the tab in front by its address alone (a Chromium tab after its browser restarted), decided
    /// together: when they all come from one tab before, they take this one as theirs (its id and process from now
    /// on); notes from different old tabs that showed the same page never guess, and fall back to their other places.
    private func recoverTabs(_ fits: [String: Int], _ scene: NoteScene) -> [String: Int] {
        let byAddress = fits.filter { key, index in
            store.paper(key).map { $0.file.places.indices.contains(index) && NoteMatch.tabMatch($0.file.places[index], scene) == .address } ?? false
        }
        guard !byAddress.isEmpty else { return fits }
        var fits = fits
        let sticks = byAddress.compactMap { key, index in store.paper(key)?.file.places[index] }
        if NoteMatch.recover(sticks) {
            for (key, index) in byAddress {
                guard let paper = store.paper(key), !store.readOnly(paper) else { continue }
                let adopted = NoteMatch.adopt(paper.file.places[index], scene)
                store.change(key, expect: paper.revision, touch: false) { file in
                    if file.places.indices.contains(index) { file.places[index] = adopted }
                }
            }
            return fits
        }
        for (key, index) in byAddress {
            guard let paper = store.paper(key) else { continue }
            fits[key] = NoteMatch.best(paper.file.places, scene, excluding: [index])
        }
        return fits
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
        guard let window = scene.window else { return }
        let wanted = here.compactMap { key, index -> (String, NoteStick)? in
            guard let paper = store.paper(key), paper.file.places[index].kind == .passage else { return nil }
            return (key, paper.file.places[index])
        }
        guard !wanted.isEmpty else { return }
        let pid = scene.pid
        let ticket = looks
        Self.queue.async {
            let bounds = Self.passageBounds(pid: pid, window: window, wanted.map { $0.1 })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ticket == self.looks, let frame = self.frame else { return }
                    var found: [String: Bool] = [:]
                    for (index, item) in wanted.enumerated() {
                        self.lines[item.0] = bounds[index].map { $0.minY - frame.minY }
                        self.passageRects[item.0] = bounds[index]
                        found[item.0] = bounds[index] != nil
                    }
                    if found != self.found { self.found = found }
                    self.layout()
                }
            }
        }
    }

    /// Each passage's words' bounds on the screen (Accessibility's coordinates), where the app tells them: among
    /// the window's texts that hold its whole quote, the one place the words around it fit best (NoteMatch.pick),
    /// within half a second; a text's own bounds for those words where it gives them, else the text's frame. Off the
    /// main thread.
    nonisolated static func passageBounds(pid: pid_t, window number: CGWindowID, _ passages: [NoteStick]) -> [CGRect?] {
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
        return passages.indices.map { index -> CGRect? in
            let passage = passages[index]
            guard whole, let picked = NoteMatch.pick(quote: passage.quote, before: passage.before, after: passage.after, in: hits[index].map(\.1)) else { return nil }
            let (element, value) = hits[index][picked.text]
            let ns = NSRange(picked.range, in: value)
            var cf = CFRange(location: ns.location, length: ns.length)
            if let axRange = AXValueCreate(.cfRange, &cf) {
                var raw: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &raw) == .success,
                   let raw, CFGetTypeID(raw) == AXValueGetTypeID() {
                    var rect = CGRect.zero
                    AXValueGetValue(raw as! AXValue, .cgRect, &rect)
                    if rect.height > 1 { return rect }
                }
            }
            return Windows.frame(of: element)
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
        defer { reconcileRoom() }
        guard on, let frame, let scene, scene.window != nil else {
            for panel in tabPanels.values { panel.orderOut(nil) }
            for panel in pinPanels.values { panel.orderOut(nil) }
            for (key, panel) in panels where !isDesktop(key) { panel.orderOut(nil) }
            return
        }
        let now = Date()
        let edgeNotes = here.keys.sorted().compactMap { key -> EdgeNote? in
            guard let paper = store.paper(key) else { return nil }
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
            panel.orderOut(nil)
            tabPanels[key] = nil
        }
        // The notes showing on this window, stacked down its right side where nobody moved them.
        var placed: [CGRect] = []
        let showing = here.keys.filter { faces[$0] != nil }.sorted { (lines[$0] ?? 0, $0) < (lines[$1] ?? 0, $1) }
        for key in showing {
            let panel = panel(for: key)
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
        }
        for (key, panel) in panels where !isDesktop(key) && !showing.contains(key) { panel.orderOut(nil) }
        drawPins(showing)
    }

    /// The sketch's dashed line in the notebook's color from each showing note to its sentence, wherever the
    /// sentence's bounds are known.
    private func drawPins(_ showing: [String]) {
        var keep: Set<String> = []
        for key in showing {
            guard let rect = passageRects[key], let paper = store.paper(key), let note = panels[key], note.isVisible else { continue }
            keep.insert(key)
            let words = NoteRules.appKitFrame(rect, primaryHeight: primaryHeight)
            let paperFrame = note.frame.insetBy(dx: PaperLook.margin, dy: PaperLook.margin)
            let pin = pinPanels[key] ?? PinPanel()
            pinPanels[key] = pin
            pin.show(from: CGPoint(x: words.maxX, y: words.midY), to: CGPoint(x: paperFrame.minX, y: paperFrame.maxY - 28),
                     color: store.color(of: paper.notebook))
        }
        for (key, pin) in pinPanels where !keep.contains(key) {
            pin.orderOut(nil)
            pinPanels[key] = nil
        }
    }

    /// A notebook's color as the tabs name it.
    private func notebookKey(_ notebook: String) -> String { store.color(of: notebook).hex }

    private func isDesktop(_ key: String) -> Bool {
        store.paper(key)?.file.places.contains { $0.kind == .desktop } == true && here[key] == nil
    }

    private func panel(for key: String) -> NotePanel {
        if let panel = panels[key] { return panel }
        let panel = NotePanel(desk: self, key: key)
        panels[key] = panel
        return panel
    }

    // MARK: The Desktop

    /// Notes stuck to the Desktop showing now (on each screen's Desktop), where the person left them.
    func placeDesktop() {
        guard on, !Headless.on else { return }
        var showing: Set<String> = []
        for screen in NSScreen.screens {
            guard let number = Spaces.desktop(on: screen) else { continue }
            let notes = store.notes.filter { paper in paper.file.places.contains { $0.kind == .desktop && $0.desktop == number } }
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
            }
        }
        for (key, panel) in panels where panel.desktop && !showing.contains(key) {
            panel.desktop = false
            panel.orderOut(nil)
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

    func open(_ key: String) {
        guard let paper = store.paper(key) else { return }
        faces[key] = .open
        keyboard = key
        local.shown = Array(Set(local.shown + [paper.noteID]))
        local.save()
        layout()
        if isDesktopNote(key) { placeDesktop() }
        panel(for: key).takeKeyboard()
    }

    func fold(_ key: String) {
        guard faces[key] == .open || faces[key] == .back else { return }
        Self.roomTurn.cancel()
        editors[key]?.flush()
        faces[key] = .folded
        if keyboard == key { keyboard = nil }
        letGoIfEmpty(key)
        layout()
        if isDesktopNote(key) { placeDesktop() }
    }

    func hide(_ key: String) {
        Self.roomTurn.cancel()
        editors[key]?.flush()
        faces[key] = nil
        if keyboard == key { keyboard = nil }
        panels[key]?.orderOut(nil)
        if let paper = store.paper(key) {
            local.shown.removeAll { $0 == paper.noteID }
            local.save()
        }
        letGoIfEmpty(key)
    }

    func flip(_ key: String) {
        faces[key] = faces[key] == .back ? .open : .back
        if faces[key] == .open { panel(for: key).takeKeyboard() }
        panels[key]?.refit()
    }

    /// Clicked away from every note: the open ones fold back.
    func clickedAway() {
        for (key, face) in faces where face == .open || face == .back { fold(key) }
    }

    func measured(_ key: String, _ height: CGFloat) {
        guard abs((heights[key] ?? 0) - height) > 0.5 else { return }
        heights[key] = height
        panels[key]?.refit()
    }

    private func isDesktopNote(_ key: String) -> Bool { store.paper(key)?.file.places.contains { $0.kind == .desktop } == true }

    /// A note made just now and put away with nothing written goes (to the Trash: never deleted outright).
    private func letGoIfEmpty(_ key: String) {
        guard fresh.contains(key), let paper = store.paper(key), paper.file.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              faces[key] != .open else { return }
        fresh.remove(key)
        faces[key] = nil
        panels[key]?.orderOut(nil)
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
            guard let number = (row["window"] as? Double).map({ CGWindowID($0) }), let pid = (row["pid"] as? Double).map({ pid_t($0) }),
                  let before = rect(row["before"]), let given = rect(row["given"]) else { continue }
            ledger[number] = (pid, before, given)
            giveBack(number)
        }
        ledger = [:]
    }

    /// The one path for room beside windows, after every change of what's showing (a note opened, folded, hidden,
    /// put on the Desktop, another window in front): the window in front narrows while a note open on it (where
    /// nobody moved it) has no room, and every other narrowed window gets its width back.
    private func reconcileRoom() {
        var wanted: (number: CGWindowID, pid: pid_t, frame: CGRect, target: CGRect?)?
        if on, let frame, let scene, let number = scene.window,
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
            Self.narrow(wanted.number, pid: wanted.pid, from: wanted.frame, to: target)
        }
    }

    /// Narrows one window, on `queue`: only while it's still where it was when this was decided, recorded before it
    /// changes, and with the frame the app took.
    nonisolated private static func narrow(_ number: CGWindowID, pid: pid_t, from frame: CGRect, to target: CGRect) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let all: [AXUIElement] = Windows.value(app, kAXWindowsAttribute) ?? []
        guard let element = all.first(where: { Windows.id(of: $0) == number }), let now = Windows.frame(of: element),
              NoteRoom.close(now, frame) else { return }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success, settable.boolValue else { return }
        ledger[number] = (pid, now, target)
        let took = Windows.place(element, pid: pid, target)
        if let took { ledger[number]?.given = took }
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
    private func giveBackAll(wait: Bool) {
        Self.roomTurn.cancel()
        let work: @Sendable () -> Void = { for number in Array(Self.ledger.keys) { Self.giveBack(number) } }
        if wait { Self.queue.sync(execute: work) } else { Self.queue.async(execute: work) }
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
        return store.change(key, base: base) { $0.body = body }
    }

    /// Pictures pasted or dropped on a note: its session reads, decodes and saves them beside it (after whatever is
    /// waiting there, a move too), then they go in where the cursor was, or at the end of the note once its editor
    /// is gone.
    func importPictures(_ items: NoteImport, into key: String) {
        if !store.importPictures(key, items) { say("This note has two versions: keep one before adding pictures.") }
    }

    /// The session saved pictures for a note: into its open editor, at the cursor's place then (true); no editor open
    /// on it (false), the session puts them at the end of the note.
    private func insertPictures(_ key: String, _ pictures: [(path: String, file: URL, caption: String)], at: Int) -> Bool {
        guard let editor = editors[key] else { return false }
        var at = at
        for picture in pictures {
            guard editor.insert(picture.path, picture.file, picture.caption, at) else { return false }
            at = -1   // the next one after it, at the cursor
        }
        fresh.remove(key)
        return true
    }

    /// A note's file got another name on disk than it was shown with: everything showing it follows.
    private func rekey(_ old: String, to paper: PaperNote) {
        let new = paper.key
        if let face = faces.removeValue(forKey: old) { faces[new] = face }
        if keyboard == old { keyboard = new }
        if let height = heights.removeValue(forKey: old) { heights[new] = height }
        if let index = here.removeValue(forKey: old) { here[new] = index }
        if fresh.remove(old) != nil { fresh.insert(new) }
        if let line = lines.removeValue(forKey: old) { lines[new] = line }
        if let editor = editors.removeValue(forKey: old) { editors[new] = editor }
        if let panel = panels.removeValue(forKey: old) { panel.rekey(new); panels[new] = panel }
    }

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
        local.save()
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
    static func describe(_ stick: NoteStick) -> String {
        switch stick.kind {
        case .passage:
            let quote = "“" + stick.quote.prefix(60) + (stick.quote.count > 60 ? "…”" : "”")
            return quote + " on " + (stick.url.isEmpty ? (stick.path as NSString).lastPathComponent : NoteText.shortAddress(stick.url))
        case .tab: return "The page " + (NoteText.shortAddress(stick.url).isEmpty ? stick.title : NoteText.shortAddress(stick.url))
        case .file: return "The file " + (stick.path as NSString).lastPathComponent + (stick.appName.isEmpty ? "" : " (in any app)")
        case .window: return "A window of \(stick.appName.isEmpty ? stick.app : stick.appName)" + (stick.title.isEmpty ? "" : ": “\(stick.title)”")
        case .app: return "Every window of \(stick.appName.isEmpty ? stick.app : stick.appName)"
        case .desktop: return "Desktop \(stick.desktop.map(String.init) ?? "")" + (stick.mode.isEmpty ? "" : " (\(stick.mode))")
        }
    }

    // MARK: Making notes

    /// The places what's in front offers, most specific first: the passage selected, the tab, the file, the window,
    /// all of the app; with no window, the Desktop.
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
            s.mode = app.docks.focusedDock?.mode?.id ?? ""
            return s
        }
        guard scene.window != nil else {
            var desk = NoteStick(kind: .desktop)
            desk.desktop = scene.desktop ?? app.docks.focusedDock?.desktop
            desk.mode = app.docks.focusedDock?.mode?.id ?? ""
            return [desk]
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
        local.save()
    }

    /// A new note on `stick`, open with the keyboard. `body`: what it starts with.
    @discardableResult
    func make(on stick: NoteStick, body: String = "", chat: String = "", at point: CGPoint? = nil) -> PaperNote? {
        var file = NoteFile(body: body)
        file.places = [stick]
        file.chat = chat
        let notebook = notebook(for: stick)
        guard let paper = store.make(file, in: notebook) else { return nil }
        remember(paper.notebook, for: stick)
        if body.isEmpty { fresh.insert(paper.key) }
        if let point {
            if stick.kind == .desktop { local.desk[paper.noteID] = [point.x, point.y] }
            else if let frame {
                let rect = CGRect(x: point.x, y: point.y - PaperLook.folded, width: PaperLook.folded, height: PaperLook.folded)
                local.spots[paper.noteID] = NoteSpot.stick(panel: rect, window: NoteRules.appKitFrame(frame, primaryHeight: primaryHeight))
            }
        }
        if let scene, stick.kind != .desktop, let index = NoteMatch.best([stick], scene) { here[paper.key] = index }
        open(paper.key)
        if stick.kind == .desktop { placeDesktop() }
        return paper
    }

    /// ⌃⌥N: a new note on what's in front: the selected sentence, else its tab, its file, its window; on the
    /// Desktop, the Desktop.
    func newHere() {
        guard on, let running = NSWorkspace.shared.frontmostApplication, running.processIdentifier != getpid() else { return }
        let pid = running.processIdentifier
        let name = running.localizedName ?? ""
        Self.read(running, mac: local.mac) { scene, read in
            self.apply(scene, read: read)
            Self.queue.async {
                let passage = Self.selection(pid: pid)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let first = self.places(for: scene, read: read, appName: name, passage: passage).first { self.make(on: first) }
                    }
                }
            }
        }
    }

    /// "Note" by a selection: a new note on that sentence (its page or file), else on what's in front.
    func note(on quote: String) {
        guard on, let running = NSWorkspace.shared.frontmostApplication, running.processIdentifier != getpid() else { return }
        let pid = running.processIdentifier
        let name = running.localizedName ?? ""
        Self.read(running, mac: local.mac) { scene, read in
            self.apply(scene, read: read)
            Self.queue.async {
                let passage = Self.selection(pid: pid) ?? (quote, "", "")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let first = self.places(for: scene, read: read, appName: name, passage: passage).first { self.make(on: first) }
                    }
                }
            }
        }
    }

    /// Dragged from ✦ and let go at `point` (AppKit's coordinates): a blank note there, on the window under it,
    /// else on the Desktop.
    func note(at point: CGPoint) {
        guard on else { return }
        let ax = CGPoint(x: point.x, y: primaryHeight - point.y)
        let me = getpid()
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let hit = info.first { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0, let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0).contains(ax)
        }
        guard let hit, let pid = hit[kCGWindowOwnerPID as String] as? pid_t, let running = NSRunningApplication(processIdentifier: pid) else {
            var desk = NoteStick(kind: .desktop)
            desk.desktop = (NSScreen.screens.first { $0.frame.contains(point) }).flatMap { Spaces.desktop(on: $0) }
            desk.mode = app.docks.focusedDock?.mode?.id ?? ""
            make(on: desk, at: point)
            return
        }
        let number = hit[kCGWindowNumber as String] as? CGWindowID
        let name = running.localizedName ?? ""
        Self.read(running, mac: local.mac) { scene, read in
            // The front window of that app is the one under the drop: its tab and file. Another of its windows: that
            // window alone.
            var scene = scene
            if scene.window != number { scene.tab = nil; scene.file = ""; scene.window = number; scene.title = hit[kCGWindowName as String] as? String ?? "" }
            if read.window == number { self.apply(scene, read: read) }
            let offers = self.places(for: scene, read: read, appName: name)
            if let first = offers.first(where: { $0.kind != .passage }) { self.make(on: first, at: point) }
            // Another window than the one in front: it comes forward (the pointer stays), and the note with it.
            if read.window != number || !running.isActive, let number { self.bringForward(pid: pid, window: number) }
        }
    }

    /// A blank paper following the pointer out of the AI button; let go over the dock, it's nothing.
    func dragFromAI(ended: Bool) {
        let mouse = NSEvent.mouseLocation
        if ended {
            ghost?.orderOut(nil)
            ghost = nil
            let overDock = app.docks.focusedDock?.panel.map { $0.frame.contains(mouse) } ?? false
            if !overDock { note(at: CGPoint(x: mouse.x - 20, y: mouse.y + 20)) }
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
    nonisolated static func selection(pid: pid_t) -> (quote: String, before: String, after: String)? {
        guard Windows.trusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focused: AXUIElement = Windows.value(app, kAXFocusedUIElementAttribute) else { return nil }
        if (Windows.value(focused, kAXSubroleAttribute) as String?) == kAXSecureTextFieldSubrole as String { return nil }
        guard let text: String = Windows.value(focused, kAXSelectedTextAttribute) else { return nil }
        let quote = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard quote.count >= 2 else { return nil }
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
        return (quote, before, after)
    }

    // MARK: The quick question

    /// The quick question opened: what's in front then is where Stick here sticks it.
    func capture() {
        captured = nil
        guard on, let running = NSWorkspace.shared.frontmostApplication, running.processIdentifier != getpid() else { return }
        let name = running.localizedName ?? ""
        Self.read(running, mac: local.mac) { scene, read in
            self.captured = (scene, read, read.tab?.url ?? "", name)
        }
    }

    var canStick: Bool { on && captured != nil }

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
        let offers = places(for: captured.scene, read: captured.read, appName: captured.name)
        guard let place = offers.first(where: { $0.kind != .passage }) else { return }
        apply(captured.scene, read: captured.read)
        if let paper = make(on: place, body: lines.joined(separator: "\n"), chat: chat.uuidString) { fresh.remove(paper.key) }
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
            if paper.file.places.count > 1 {
                let sub = NSMenu()
                sub.addItem(ActionItem("Take it off here") { [weak self] in self?.unstick(key, index) })
                item.submenu = sub
            }
            menu.addItem(item)
        }
        if let scene, let front, scene.window != nil {
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
        var desk = NoteStick(kind: .desktop)
        desk.desktop = scene?.desktop ?? app.docks.focusedDock?.desktop
        desk.mode = app.docks.focusedDock?.mode?.id ?? ""
        menu.addItem(ActionItem("Put it on this Desktop") { [weak self] in self?.restick(key, [desk]) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func restick(_ key: String, _ places: [NoteStick]) {
        guard let paper = store.paper(key) else { return }
        guard !store.readOnly(paper) else { return say("This note has two versions: keep one first.") }
        guard store.change(key, touch: false, edit: { $0.places = places }) != nil else { return }
        if let scene, let index = NoteMatch.best(places, scene) { here[key] = index } else { here[key] = nil }
        if places.contains(where: { $0.kind == .desktop }) { faces[key] = .folded; placeDesktop() }
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
            let made = self.store.makeNotebook(name, color: colors[self.store.notebooks.count % colors.count])
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
    func move(_ key: String, to notebook: String, then done: @escaping @MainActor (PaperNote?) -> Void = { _ in }) {
        editors[key]?.flush()
        store.move(key, to: notebook) { moved in
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
        WindowEvents.shared.titles("papernotes", pagesStuck)
        // Notes shown on this Mac before it last quit show again.
        for paper in store.notes where local.shown.contains(paper.noteID) && faces[paper.key] == nil { faces[paper.key] = .folded }
        for (key, panel) in panels where store.paper(key) == nil {
            panel.orderOut(nil)
            panels[key] = nil
            faces[key] = nil
        }
        if let scene, let front { apply(scene, read: front, scan: false) } else { look() }
        placeDesktop()
        for panel in panels.values { panel.refresh() }
    }

    /// For snapshots: Stick here as if a page were in front.
    func previewCapture() {
        var tab = NoteTab(url: "https://guide.example/day-one", title: "Day one")
        tab.id = "1"
        captured = (NoteScene(mac: local.mac, app: "com.apple.Safari", pid: 1, window: 1, title: "Day one", tab: tab), ClaudePanel.FrontRead(), tab.url, "Safari")
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
        let target = paperFrame.insetBy(dx: -PaperLook.margin, dy: -PaperLook.margin).integral
        if frame != target { setFrame(target, display: true) }
        if !isVisible { orderFrontRegardless() }
        level = desktop && desk?.faces[key] != .open ? Self.desktopLevel : .floating
    }

    /// Its size changed (opened, folded, the writing grew): it grows from its top-left corner.
    func refit() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let target = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height).integral
        if target != frame { setFrame(target, display: true, animate: false) }
        level = desktop && desk?.faces[key] != .open ? Self.desktopLevel : .floating
    }

    func takeKeyboard() {
        refit()
        if !isVisible { orderFrontRegardless() }
        makeKeyAndOrderFront(nil)
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
                      conflict: desk.store.readOnly(paper), unsaved: desk.store.failed.contains(key))
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
        if !isVisible { orderFrontRegardless() }
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
        guard box.width > 12 else { return orderOut(nil) }
        let a = CGPoint(x: start.x - box.minX, y: box.maxY - start.y)
        let b = CGPoint(x: end.x - box.minX, y: box.maxY - end.y)
        hosting.rootView = AnyView(PinLine(from: a, to: b, color: Color(nsColor: color)).frame(width: box.width, height: box.height))
        setFrame(box.integral, display: true)
        if !isVisible { orderFrontRegardless() }
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
