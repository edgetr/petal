import AppKit
import ImageIO
import Observation
import SwiftUI

/// A borderless glass panel that sits over a dock slot: tooltips, previews, stacks and Petal AI's question.
@MainActor
final class GlassPanel: NSPanel {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    var interactive = true

    init(level: NSWindow.Level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = hosting
        isFloatingPanel = true
        self.level = level
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    /// Takes typing (a card asking for a secret), without bringing Petal forward.
    var takesKeys = false
    override var canBecomeKey: Bool { takesKeys }

    func show<Content: View>(_ content: Content, over slot: CGRect, dock: DockPanel?, gap: CGFloat = 8) {
        hosting.rootView = AnyView(content.environment(PetalApp.shared))
        place(over: slot, dock: dock, gap: gap)
    }

    /// Places what it shows over `slot` again, without making its view anew.
    func place(over slot: CGRect, dock: DockPanel?, gap: CGFloat = 8, size known: CGSize? = nil, front: Bool = true) {
        let size: CGSize
        if let known { size = known } else {
            hosting.layoutSubtreeIfNeeded()
            size = hosting.fittingSize
        }
        let screen = dock?.screenRef ?? Screens.main ?? Screens.all[0]
        let area = screen.frame.insetBy(dx: gap, dy: gap)
        let edge = dock?.glassFrame ?? slot
        var origin: CGPoint
        switch PetalApp.shared.config.position {
        case "left": origin = CGPoint(x: edge.maxX + gap, y: slot.midY - size.height / 2)
        case "right": origin = CGPoint(x: edge.minX - gap - size.width, y: slot.midY - size.height / 2)
        default: origin = CGPoint(x: slot.midX - size.width / 2, y: edge.maxY + gap)
        }
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        setFrame(NSRect(origin: origin, size: size).integral, display: true)
        ignoresMouseEvents = !interactive
        if alphaValue != 1 { Self.opaque(self) }
        if front || !isVisible { orderFrontRegardless() }
    }

    /// By a point on the screen (Petal AI's own pointer): below and to the right of it, kept on the screen.
    func show<Content: View>(_ content: Content, near point: CGPoint, on screen: NSScreen) {
        hosting.rootView = AnyView(content.environment(PetalApp.shared))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let area = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        var origin = CGPoint(x: point.x + 12, y: point.y - 24 - size.height)
        if origin.y < area.minY { origin.y = point.y + 8 }
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        setFrame(NSRect(origin: origin, size: size).integral, display: true)
        ignoresMouseEvents = !interactive
        if alphaValue != 1 { Self.opaque(self) }
        orderFrontRegardless()
    }

    /// Fully visible again, also stopping a fade that's under way (setting alphaValue alone wouldn't).
    static func opaque(_ panel: NSWindow) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
    }

    /// Gone from sight, letting the mouse through, and showing nothing (so nothing in it keeps drawing), but still
    /// on the screen: taking a window with macOS's glass off the screen waits on the window server for up to half
    /// a second, which held the dock up every time a preview, a card or a tooltip went away.
    /// One that took typing (a secret) gives it back to the app in front, so keys don't go on to a card no one can
    /// see.
    func hide() {
        guard alphaValue != 0 || !ignoresMouseEvents else { return }
        alphaValue = 0
        ignoresMouseEvents = true
        hosting.rootView = AnyView(EmptyView())
        releaseKeys()
    }

    /// Gives typing back to the app in front, if this has it.
    func releaseKeys() {
        takesKeys = false
        guard isKeyWindow else { return }
        resignKey()
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            front.activate(from: NSRunningApplication.current, options: [])
        }
    }

    /// Showing, not just on the screen (see `hide`).
    var shown: Bool { isVisible && alphaValue > 0 }
}

/// The slot's name, on a small glass pill outside the dock, with no delay. AppKit's own glass and a label, sized
/// from the words at once, so the pill is where the pointer is in the same frame (a SwiftUI pill learnt its new
/// words a frame later, and moving fast across the icons left it behind).
@MainActor
final class Tooltips {
    private let panel: GlassPanel = {
        let panel = GlassPanel()
        panel.interactive = false
        panel.ignoresMouseEvents = true
        return panel
    }()
    private let glass = NSGlassEffectView()
    private let label = NSTextField(labelWithString: "")
    private var shownFor = ""
    private var made = false
    /// Room around the glass, as the SwiftUI pills keep for its edge.
    private static let margin: CGFloat = 6

    func show(_ text: String?, over id: String, in dock: ScreenDock?) {
        let app = PetalApp.shared
        if text == nil && id != shownFor { return }   // leaving one icon after entering the next
        shownFor = id
        guard let text, !text.isEmpty, app.config.bool("tooltips"), let dock, dock.dragging == nil, dock.openPopup == nil,
              !app.popups.anyOpen, let panelRef = dock.panel, let slot = panelRef.screenFrame(of: id) else {
            hide()
            return
        }
        if !made { make() }
        label.stringValue = text
        let words = label.intrinsicContentSize
        let pill = CGSize(width: ceil(words.width) + 24, height: ceil(words.height) + 12)
        let size = CGSize(width: pill.width + Self.margin * 2, height: pill.height + Self.margin * 2)
        glass.frame = CGRect(x: Self.margin, y: Self.margin, width: pill.width, height: pill.height)
        glass.cornerRadius = pill.height / 2
        label.frame = CGRect(x: 12, y: (pill.height - ceil(words.height)) / 2, width: ceil(words.width), height: ceil(words.height))
        panel.place(over: slot, dock: panelRef, gap: 2, size: size, front: false)
    }

    private func make() {
        made = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byClipping
        let content = NSView()
        content.addSubview(label)
        glass.contentView = content
        glass.style = .regular
        let container = NSView()
        container.addSubview(glass)
        panel.contentView = container
    }

    /// See-through rather than taken off the screen: ordering a window with macOS's glass out (and back in) waits on
    /// the window server for most of half a second, which moving across the icons did at every one.
    func hide() { panel.alphaValue = 0 }   // see GlassPanel.hide
}

/// Stacks, previews and Petal AI's question: one open at a time; clicking elsewhere closes the stack.
@MainActor @Observable
final class Popups {
    @ObservationIgnored private let panel = GlassPanel()
    @ObservationIgnored private let cardPanel = GlassPanel()
    @ObservationIgnored private var monitor: Any?
    private(set) var kind: String?           // "stack", "preview"
    /// Petal AI's question is up over the dock (AskCard), for the person to answer there.
    private(set) var asking = false
    /// The open stack's files.
    @ObservationIgnored private(set) var stack: StackContents?
    @ObservationIgnored private var anchor: String?
    @ObservationIgnored private weak var openDock: ScreenDock?
    @ObservationIgnored private var keys: Any?

    var anyOpen: Bool { kind != nil || asking }

    init() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.kind == "stack" else { return }
                if !self.panel.frame.contains(NSEvent.mouseLocation) { self.closeAll() }
            }
        }
        // Escape answers the question Don't (it never takes the keyboard from the app in front).
        keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { if event.keyCode == 53 { self?.closeAsk() } }
        }
    }

    func closeAll() {
        let wasPreview = kind == "preview"
        panel.hide()
        panel.sharingType = .readOnly
        fanNotebook = nil
        kind = nil
        stack = nil
        anchor = nil
        openDock?.openPopup = nil
        openDock = nil
        PetalApp.shared.tooltips.hide()
        if wasPreview { PetalApp.shared.previews.closed() }
    }

    /// The stack opens once its files are read, off the main thread (a few milliseconds), at the size they need.
    /// The notebook whose papers are fanned up now, if any.
    private var fanNotebook: String?

    /// The fan's window while it shows a Private notebook's papers (Petal's own pictures leave it out).
    var privateFanWindow: Int? {
        guard let name = fanNotebook else { return nil }
        return PetalApp.shared.paper.store.notebook(name)?.isPrivate == false ? nil : panel.windowNumber
    }

    /// A notebook's privacy changed (here, or on another Mac): an open fan of a notebook that's Private now is kept out
    /// of pictures of the screen at once.
    func notebookPrivacyChanged() {
        guard let name = fanNotebook else { return }
        let book = PetalApp.shared.paper.store.notebook(name)
        // Gone or renamed meanwhile: kept out too, until it closes.
        panel.sharingType = book?.isPrivate == false ? .readOnly : .none
    }

    func toggleStack(_ folder: String, in dock: ScreenDock) {
        let key = "stack:\(folder)"
        if dock.openPopup == key { closeAll(); return }
        closeAll()
        PetalApp.shared.previews.hover(nil, in: dock)
        guard dock.panel?.screenFrame(of: key) != nil else { return }
        kind = "stack"
        openDock = dock
        anchor = key
        dock.openPopup = key
        // A notebook of Petal Notes: its papers fan up.
        if let book = PetalApp.shared.paper.notebook(forStack: folder) {
            PetalApp.shared.signals.opened(folder)
            guard let slot = dock.panel?.screenFrame(of: key) else { return }
            // A Private notebook's papers: left out of Petal's own pictures (privateFanWindow), macOS asked not to share
            // them as a best effort (and the fan follows
            // its notebook turning Private while it's open: notebookPrivacyChanged).
            fanNotebook = book.name
            panel.sharingType = book.isPrivate ? .none : .readOnly
            panel.show(NotebookFanView(book: book, papers: PetalApp.shared.paper.fanned(book)) { [weak self] in self?.closeAll() }, over: slot, dock: dock.panel)
            return
        }
        let contents = StackContents(folder: folder)
        stack = contents
        PetalApp.shared.signals.opened(folder)
        contents.load { [weak self] in
            guard let self, self.stack === contents, let slot = dock.panel?.screenFrame(of: key) else { return }
            self.panel.show(StackView(contents: contents) { [weak self] in self?.closeAll() }, over: slot, dock: dock.panel)
        }
    }

    /// Fits the stack or preview to what it shows now, over the same slot.
    func refit() {
        guard kind != nil, let anchor, let dock = openDock?.panel, let slot = dock.screenFrame(of: anchor), panel.shown else { return }
        panel.place(over: slot, dock: dock)
    }

    /// A preview over a slot: an app's windows (`id` is its bundle id), or the music controls over the now-playing
    /// tile (`id` is "media").
    func showPreview(_ id: String, in dock: ScreenDock) {
        guard kind != "stack", let slot = dock.panel?.screenFrame(of: id) else { return }
        kind = "preview"
        openDock = dock
        anchor = id
        PetalApp.shared.tooltips.hide()
        panel.show(PreviewView(id: id) { [weak self] in self?.closeAll() }, over: slot, dock: dock.panel)
    }

    /// The pointer is over the open preview, or on its way there from its slot: across the dock's glass and the
    /// gap above it, which aren't the slot and aren't the preview.
    var pointerNearPreview: Bool {
        guard kind == "preview" else { return false }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        if frame.insetBy(dx: -4, dy: -4).contains(mouse) { return true }
        guard let anchor, let slot = openDock?.panel?.screenFrame(of: anchor) else { return false }
        let corridor: CGRect
        switch PetalApp.shared.config.position {
        case "left": corridor = CGRect(x: slot.minX, y: slot.minY, width: frame.minX - slot.minX, height: slot.height)
        case "right": corridor = CGRect(x: frame.maxX, y: slot.minY, width: slot.maxX - frame.maxX, height: slot.height)
        default: corridor = CGRect(x: slot.minX, y: slot.minY, width: slot.width, height: frame.minY - slot.minY)
        }
        return corridor.standardized.insetBy(dx: -4, dy: -4).contains(mouse)
    }

    /// Petal AI's question (`Assist.pending`) over the middle of the dock, when the chat asking isn't showing it.
    func showAsk() {
        guard let dock = PetalApp.shared.docks.focusedDock, let panelRef = dock.panel else { return }
        asking = true
        closeAll()
        panelRef.reveal()
        GlassPanel.opaque(cardPanel)
        let pill = panelRef.frame
        cardPanel.show(AskCard(), over: CGRect(x: pill.midX - 1, y: pill.minY, width: 2, height: pill.height), dock: panelRef)
        // A question asking for a secret takes the keyboard for it.
        if PetalApp.shared.assist.pending?.takesKeys == true {
            cardPanel.takesKeys = true
            cardPanel.makeKey()
        } else {
            cardPanel.releaseKeys()
        }
    }

    /// The question goes; one that had no answer yet is answered Don't.
    func closeAsk() {
        guard asking else { return }
        asking = false
        PetalApp.shared.assist.cardClosed()
        cardPanel.hide()   // made opaque again as the next one shows
    }
}

// MARK: - Previews

/// Window previews: after 380 ms over an app with windows; swapping straight to another app's; gone 220 ms after
/// the pointer leaves both the app and the preview. The now-playing tile shows the music controls the same way, and
/// a music app's preview has them above its windows.
@MainActor @Observable
final class Previews {
    static let media = "media"
    /// Over the AI button: the sticky notes at work (NotePreviews.swift).
    static let notes = "claude"

    private(set) var thumbnails: [String: NSImage] = [:]
    /// The windows the open preview shows, listed off the main thread.
    private(set) var windows: [AppWindow] = []
    /// Pictures of the windows (Screen Recording), or their titles in a list.
    private(set) var pictures = false
    @ObservationIgnored private var showTask: DispatchWorkItem?
    @ObservationIgnored private var hideTask: DispatchWorkItem?
    @ObservationIgnored private var refresh: Timer?
    @ObservationIgnored private(set) var showing: String?
    @ObservationIgnored private var capturing = false
    @ObservationIgnored private var hoveredID = ""
    /// Each app's windows as last listed, so moving to the next icon swaps the preview at once; listed again behind it.
    @ObservationIgnored private var listed: [String: [AppWindow]] = [:]
    /// While a menu from the dock is open, nothing opens behind it.
    @ObservationIgnored private var held = false
    /// Pictures of the windows the notes work in, by note, each with the note as it was when it was taken: shown only
    /// while the note still has that very window (`noteThumb`).
    private(set) var noteThumbs: [UUID: NotePicture.Kept<NSImage>] = [:]
    @ObservationIgnored private var capturingNotes = false
    @ObservationIgnored private var noteCount = 0
    /// Made-up notes, for `Petal --snapshot`.
    @ObservationIgnored private var sampleNotes: [NotePreviewItem]?
    /// The notes the AI button's preview shows.
    var noteItems: [NotePreviewItem] { sampleNotes ?? PetalApp.shared.claude.previewItems }

    /// A note's picture, only if it's of the window the note has now: never its old window's after it moved.
    func noteThumb(_ item: NotePreviewItem) -> NSImage? { NotePicture.current(noteThumbs[item.id], now: item.seen) }

    /// Made-up pictures of runs' hidden displays, for `Petal --snapshot`.
    @ObservationIgnored private var sampleDisplays: [UUID: NSImage] = [:]
    /// The picture of a run's own hidden display (RunDisplays keeps the latest), for its tile.
    func displayThumb(_ item: NotePreviewItem) -> NSImage? {
        guard let id = item.display else { return nil }
        return sampleDisplays[id] ?? PetalApp.shared.displays.display(tile: id)?.picture
    }
    /// Accessibility answers each app in its own time (up to 0.3 s for a busy one), so windows are listed here, each
    /// app on its own: a slow one never holds up the next.
    nonisolated private static let queue = DispatchQueue(label: "petal.previews", qos: .userInitiated, attributes: .concurrent)

    func hover(_ item: DockItem?, in dock: ScreenDock, id: String = "") {
        let app = PetalApp.shared
        if item == nil && !id.isEmpty && id != hoveredID { return }   // leaving one icon after entering the next
        hoveredID = item?.id ?? ""
        showTask?.cancel()
        guard !held else { return }
        if let item, item.windows > 0 || playing(item.id), app.config.bool("previews"), canOpen(in: dock) {
            if showing != nil && showing != item.id {
                // Already showing another app's: this one's at once if its windows are known, else the tooltip
                // until they are (never the last app's preview lingering over this icon).
                if let known = listed[item.id], !known.isEmpty || playing(item.id) {
                    hideTask?.cancel()
                    show(item.id, windows: known, in: dock)
                    again()   // and listed anew, in case they changed since
                    return
                }
                close()
            }
            prefetch(item.id)
            schedule(item.id, in: dock)
        } else if item != nil {
            // The pointer is on another icon, not on its way to the preview: it goes now.
            hideTask?.cancel()
            close()
        } else {
            scheduleHide()
        }
    }

    /// A menu opens from the dock: no preview now, none waiting to open behind it, until it closes.
    func hold(_ on: Bool) {
        held = on
        guard on else { return }
        showTask?.cancel()
        hideTask?.cancel()
        hoveredID = ""
        close()
    }

    /// The windows `id` had when last listed (for its menu).
    func knownWindows(_ id: String) -> [AppWindow]? { listed[id] }

    /// Lists an app's windows as the pointer reaches it, so they're ready when its preview opens.
    private func prefetch(_ id: String) {
        guard id != Self.media else { return }
        list(id) { [weak self] found in self?.listed[id] = found }
    }

    /// The pointer on the AI button. True when its preview has notes to show (working, waiting for the person, or
    /// done and not seen), or is open: then it takes the tooltip's place. False with none: the tooltip as before.
    @discardableResult
    func hoverNotes(_ on: Bool, in dock: ScreenDock) -> Bool {
        if !on {
            guard hoveredID == Self.notes else { return false }
            hoveredID = ""
            showTask?.cancel()
            scheduleHide()
            return true
        }
        // Over the open chat it would only cover it.
        guard !PetalApp.shared.claude.isOpen, !noteItems.isEmpty else {
            if showing == Self.notes { close() }
            return false
        }
        hoveredID = Self.notes
        showTask?.cancel()
        guard !held, canOpen(in: dock) else { return true }
        if showing != nil && showing != Self.notes {
            hideTask?.cancel()
            show(Self.notes, windows: [], in: dock)   // straight from another app's preview
            return true
        }
        schedule(Self.notes, in: dock)
        return true
    }

    /// The pointer on the now-playing tile.
    func hoverMedia(_ on: Bool, in dock: ScreenDock) {
        if !on && hoveredID != Self.media { return }
        hoveredID = on ? Self.media : ""
        showTask?.cancel()
        if on, canOpen(in: dock) { schedule(Self.media, in: dock) } else { scheduleHide() }
    }

    private func canOpen(in dock: ScreenDock) -> Bool {
        dock.dragging == nil && !PetalApp.shared.popups.asking && PetalApp.shared.popups.kind != "stack"
    }

    private func schedule(_ id: String, in dock: ScreenDock) {
        hideTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.held, self.hoveredID == id else { return }
            self.open(id, in: dock)
        }
        showTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (showing == nil ? 0.38 : 0), execute: work)
    }

    /// The music controls belong over this app's icon: it's the player with a song.
    private func playing(_ id: String) -> Bool {
        PetalApp.shared.config.bool("nowPlaying") && PetalApp.shared.signals.nowPlaying?.player == id
    }

    private func open(_ id: String, in dock: ScreenDock) {
        if id == Self.notes {
            guard !noteItems.isEmpty else { return scheduleHide() }
            return show(id, windows: [], in: dock)
        }
        if id == Self.media {
            guard PetalApp.shared.signals.nowPlaying != nil else { return scheduleHide() }
            return show(id, windows: [], in: dock)
        }
        if let known = listed[id], !known.isEmpty {
            show(id, windows: known, in: dock)   // listed as the pointer arrived; `again` lists them anew
            return
        }
        list(id) { [weak self] found in
            // The pointer moved on while Accessibility answered.
            guard let self, self.hoveredID == id, !self.held else { return }
            // The window server counts windows Accessibility can't reach (another Desktop, hidden), and none at all
            // without Accessibility: with none to show, no preview, rather than an empty bubble.
            guard !found.isEmpty || self.playing(id) else { return self.scheduleHide() }
            self.show(id, windows: found, in: dock)
        }
    }

    private func show(_ id: String, windows found: [AppWindow], in dock: ScreenDock) {
        showing = id
        windows = found
        pictures = Capture.allowed
        PetalApp.shared.popups.showPreview(id, in: dock)
        capture(found)
        if id == Self.notes { noteCount = noteItems.count; captureNotes(); PetalApp.shared.displays.refreshPictures() }
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.again() }
        }
    }

    /// Once a second while it's open: the windows again (one may have closed), and new pictures of them.
    private func again() {
        guard let id = showing else { return }
        if id == Self.notes {
            let items = noteItems
            if items.isEmpty { return close() }
            if items.count != noteCount {
                noteCount = items.count
                PetalApp.shared.popups.refit()
            }
            // No picture kept of a window that's gone, of an app now kept private, or of a window the note left.
            let now = Dictionary(items.map { ($0.id, $0.seen) }, uniquingKeysWith: { first, _ in first })
            noteThumbs = noteThumbs.filter { id, kept in now[id].map { NotePicture.current(kept, now: $0) != nil } ?? false }
            // The runs' own displays, live: a new picture of each about once a second while this is open.
            if sampleNotes == nil { PetalApp.shared.displays.refreshPictures() }
            return captureNotes()
        }
        if id == Self.media {
            if PetalApp.shared.signals.nowPlaying == nil { close() }
            return
        }
        list(id) { [weak self] found in
            guard let self, self.showing == id else { return }
            if found.isEmpty && !self.playing(id) { return self.close() }
            if found != self.windows {
                self.windows = found
                PetalApp.shared.popups.refit()
            }
            self.capture(found)
        }
    }

    private func list(_ bundleID: String, _ done: @escaping ([AppWindow]) -> Void) {
        Self.queue.async {
            let found = Array(Self.windows(of: bundleID).prefix(6))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    PetalApp.shared.previews.listed[bundleID] = found
                    done(found)
                }
            }
        }
    }

    /// Every window of an app, through Accessibility (empty without it).
    nonisolated static func windows(of bundleID: String) -> [AppWindow] {
        NSRunningApplication.persons(withBundleIdentifier: bundleID).flatMap { Windows.windows(of: $0.processIdentifier) }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if PetalApp.shared.popups.pointerNearPreview {
                self.scheduleHide()
                return
            }
            self.close()
        }
        hideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    func close() {
        if showing != nil, PetalApp.shared.popups.kind == "preview" { PetalApp.shared.popups.closeAll() } else { closed() }
    }

    /// The preview's panel closed, however it closed (a click on the app closes every popup): stop taking pictures.
    func closed() {
        refresh?.invalidate()
        refresh = nil
        let minimized = Set(PetalApp.shared.docks.panels.values.flatMap { $0.dock.minimized.map(\.id) })
        thumbnails = thumbnails.filter { minimized.contains($0.key) }
        windows = []
        showing = nil
        let notes = Set(PetalApp.shared.claude.notes.map(\.id))
        noteThumbs = noteThumbs.filter { notes.contains($0.key) }
    }

    /// New pictures of the notes' windows, off the main thread (ScreenCaptureKit), one round at a time; none of a
    /// private app's.
    private func captureNotes() {
        guard sampleNotes == nil, Capture.allowed, !capturingNotes else { return }
        let items = noteItems.filter(\.pictured)
        guard !items.isEmpty else { return }
        let taken = Dictionary(items.map { ($0.id, $0.seen) }, uniquingKeysWith: { first, _ in first })
        capturingNotes = true
        Task {
            let excluded = PetalApp.shared.paper.privateWindowNumbers()
            let pictures = await Capture.notes(items.map { (id: $0.id, seen: $0.seen) }, excluding: excluded)
            capturingNotes = false
            guard showing == Self.notes else { return }
            // Kept only if it shows the window asked for (any of its app's only for a note on all of an app), its
            // note still has that very window, and its app wasn't made private meanwhile.
            let now = Dictionary(noteItems.map { ($0.id, $0.seen) }, uniquingKeysWith: { first, _ in first })
            for (id, picture) in pictures {
                if let seen = taken[id], NotePicture.accepts(picture.shot, taken: seen, now: now[id]) {
                    noteThumbs[id] = NotePicture.Kept(seen: seen, image: picture.image)
                } else {
                    noteThumbs[id] = nil
                }
            }
            // A note with no new picture keeps its old one only while that's still of the window it has now.
            noteThumbs = noteThumbs.filter { id, kept in now[id].map { NotePicture.current(kept, now: $0) != nil } ?? false }
        }
    }

    /// What `Petal --snapshot` draws the AI button's preview with.
    func preview(notes: [NotePreviewItem]?, thumbnails: [UUID: NSImage] = [:], displays: [UUID: NSImage] = [:]) {
        sampleNotes = notes
        sampleDisplays = displays
        let seen = Dictionary((notes ?? []).map { ($0.id, $0.seen) }, uniquingKeysWith: { first, _ in first })
        noteThumbs = Dictionary(uniqueKeysWithValues: thumbnails.compactMap { id, image in
            seen[id].map { (id, NotePicture.Kept(seen: $0, image: image)) }
        })
    }

    /// Each window's id in the window server ties it to ScreenCaptureKit's window exactly; the frame is the fallback.
    private func capture(_ list: [AppWindow]) {
        guard !list.isEmpty, Capture.allowed, !capturing else { return }
        capturing = true
        // The window server's number is in each window's id ("pid-w<number>"): no Accessibility call here.
        let targets = list.map { (window: $0, number: $0.id.split(separator: "w").last.flatMap { CGWindowID(String($0)) }) }
        Task {
            let pictures = await Capture.capture(targets)
            capturing = false
            for (id, image) in pictures { thumbnails[id] = image }
        }
    }

    /// A still of a minimized window, taken once.
    func snapshot(_ window: AppWindow) {
        guard thumbnails[window.id] == nil, Capture.allowed else { return }
        // The window server's number is in its id, as in `capture`: no Accessibility call on the main thread.
        let target = (window: window, number: window.id.split(separator: "w").last.flatMap { CGWindowID(String($0)) })
        Task {
            let pictures = await Capture.capture([target])
            for (id, image) in pictures { thumbnails[id] = image }
        }
    }

    /// What `Petal --snapshot` draws a preview with.
    func preview(windows: [AppWindow], pictures: Bool, thumbnails: [String: NSImage] = [:]) {
        self.windows = windows
        self.pictures = pictures
        self.thumbnails = thumbnails
    }
}

struct PreviewView: View {
    @Environment(PetalApp.self) private var app
    let id: String
    let done: () -> Void

    var body: some View {
        let windows = id == Previews.media || id == Previews.notes ? [] : app.previews.windows
        VStack(alignment: .leading, spacing: 12) {
            if id == Previews.notes { NotesPreview(done: done) }
            if app.config.bool("nowPlaying"), let playing = app.signals.nowPlaying, id == Previews.media || id == playing.player {
                MediaControls(playing: playing)
            }
            if !windows.isEmpty {
                if app.previews.pictures {
                    HStack(spacing: 12) {
                        ForEach(windows) { window in
                            PreviewTile(window: window, image: app.previews.thumbnails[window.id], done: done)
                        }
                    }
                } else {
                    WindowTitles(windows: windows, done: done)
                }
            }
            // Music or Spotify, not asked yet whether Petal may see what's playing: asked from here, once.
            if app.config.bool("nowPlaying"), app.signals.playersWaiting.contains(id) {
                Button { app.signals.askPlayer(id) } label: {
                    Label("Show what’s playing…", systemImage: "music.note")
                        .font(.system(size: TextSize.callout)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(6)
    }
}

struct PreviewTile: View {
    let window: AppWindow
    let image: NSImage?
    let done: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25))
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(3)
                } else {
                    Image(systemName: window.minimized ? "minus.rectangle" : "macwindow").font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 124)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hovering ? Color(nsColor: PetalApp.shared.accent) : .white.opacity(0.12),
                                                                    lineWidth: hovering ? 2 : 1))
            HStack(spacing: 6) {
                Text(WindowTitles.title(window)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if !window.minimized { RoundButton(symbol: "minus") { Windows.minimize(window) } }
                RoundButton(symbol: "xmark") { Windows.close(window) }
            }
            .frame(width: 200)
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { Windows.focus(window, onScreen: PetalApp.shared.docks.isOnScreen(window)); done() }
    }
}

/// Without Screen Recording, a preview lists the windows by name, with a way to have their pictures.
struct WindowTitles: View {
    @Environment(PetalApp.self) private var app
    let windows: [AppWindow]
    let done: () -> Void

    static func title(_ window: AppWindow) -> String {
        (window.title.isEmpty ? "Window" : window.title) + (window.minimized ? " (minimized)" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(windows) { window in WindowRow(window: window, done: done) }
            Divider().padding(.vertical, 4)
            Button {
                done()
                app.settings.show(.permissions)
            } label: {
                Label("Show pictures of windows…", systemImage: "rectangle.dashed.badge.record")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4).contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 280)
    }
}

struct WindowRow: View {
    let window: AppWindow
    let done: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: window.minimized ? "minus.rectangle" : "macwindow").font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 16)
            Text(WindowTitles.title(window)).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if hovering {
                if !window.minimized { RoundButton(symbol: "minus") { Windows.minimize(window) } }
                RoundButton(symbol: "xmark") { Windows.close(window) }
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(hovering ? .white.opacity(0.08) : .clear, in: .rect(cornerRadius: 9))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { Windows.focus(window, onScreen: PetalApp.shared.docks.isOnScreen(window)); done() }
    }
}

/// What's playing, with previous, play or pause, and next: over the now-playing tile, and over a music app's windows.
struct MediaControls: View {
    @Environment(PetalApp.self) private var app
    let playing: NowPlaying

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08))
                if let artwork = app.signals.artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.system(size: 18)).foregroundStyle(Color(nsColor: app.accent))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(playing.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(playing.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            HStack(spacing: 2) {
                MediaButton(symbol: "backward.fill") { app.signals.control("previous track") }
                MediaButton(symbol: playing.playing ? "pause.fill" : "play.fill", size: 17) { app.signals.control("playpause") }
                MediaButton(symbol: "forward.fill") { app.signals.control("next track") }
            }
        }
    }
}

struct MediaButton: View {
    let symbol: String
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .background(hovering ? .white.opacity(0.12) : .clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A small round button (×, −) on clear glass over the glass it sits on; Petal's accent tints the glass under the
/// pointer.
struct RoundButton: View {
    let symbol: String
    var size: CGFloat = 20
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: (size * 0.45).rounded(), weight: .bold))
                .frame(width: size, height: size)
                .glassEffect(hovering ? .clear.tint(Color(nsColor: PetalApp.shared.accent)).interactive() : .clear.interactive(), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Stacks

struct StackView: View {
    @Environment(PetalApp.self) private var app
    let contents: StackContents
    let done: () -> Void

    var body: some View {
        let folder = contents.folder
        let entries = contents.entries
        VStack(alignment: .leading, spacing: 2) {
            Text(Stacks.name(folder)).font(.system(size: 15, weight: .bold)).foregroundStyle(Color(nsColor: app.accent))
                .padding(.horizontal, 8).padding(.bottom, 6)
            if entries.isEmpty {
                Text("Empty").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            ForEach(entries) { entry in
                StackRow(entry: entry, done: done) { NSWorkspace.shared.open(entry.url); done() }
            }
            Divider().padding(.vertical, 4)
            Button {
                NSWorkspace.shared.open(Stacks.url(folder))
                done()
            } label: {
                HStack { Text("Open in Finder"); Spacer(); Image(systemName: "arrow.right") }
                    .padding(.horizontal, 8).padding(.vertical, 6).contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 300)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(6)
    }
}

struct StackRow: View {
    let entry: Stacks.Entry
    let done: () -> Void
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if Stacks.isImage(entry.url), let image = Thumbnails.shared.image(for: entry.url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(nsImage: Apps.icon(file: entry.url)).resizable()
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(.rect(cornerRadius: 6))
            Text(entry.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(hovering ? .white.opacity(0.08) : .clear, in: .rect(cornerRadius: 9))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .overlay { RightClick { Menus.file(entry.url, done: done) } }
        .onDrag { NSItemProvider(contentsOf: entry.url) ?? NSItemProvider() }
    }
}

/// Catches right clicks over a view and lets every other click, hover and drag through to it.
struct RightClick: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ view: Catcher, context: Context) { view.action = action }

    final class Catcher: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) { action?() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

// MARK: - Petal AI's question

/// Petal AI wants to do something that changes things: Allow once, Always (for this kind), or Don't. The chat panel
/// shows the same question in the conversation when it's open. An agent outside Petal asking for the vault gets
/// Always for this project, Allow once, and Don't as the default (AgentVault.swift).
struct AskCard: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        Group {
            if let request = app.assist.pending {
                // Its own view per question: nothing typed for one is ever kept for the next.
                AskRequestView(request: request).id(request.id)
            }
        }
        .padding(16)
        .frame(minWidth: 300, maxWidth: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        .padding(6)
    }
}

struct AskRequestView: View {
    @Environment(PetalApp.self) private var app
    let request: Assist.Request
    /// On a note: the room its words get on this screen (they scroll past it); its buttons always stay below them.
    var room: CGFloat? = nil

    /// Whose question it is: the chat's AI, or an agent outside Petal (Claude Code, Codex, or a terminal's).
    @ViewBuilder private var mark: some View {
        if let agent = request.mark { AgentMark(agent: agent) } else { ProviderMark(provider: app.chatProvider) }
    }

    var body: some View {
        if let form = request.form { VaultFormView(request: request, form: form, room: room) } else { question }
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let room { BoundedScroll(maxHeight: room) { words } } else { words }
            actions.background(GeometryReader { Color.clear.preference(key: FormActionsHeight.self, value: $0.size.height) })
        }
    }

    private var words: some View {
            HStack(alignment: .top, spacing: 10) {
                mark.frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if !request.detail.isEmpty {
                        Text(request.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
    }

    /// Allow, Don't, Always, Buy: never inside the scroll.
    private var actions: some View {
            HStack(spacing: 8) {
                Spacer()
                if request.warn {
                    // Something doesn't match, or it pays: Don't is the one to press without thinking.
                    if let keep = request.keep { Button(keep) { app.assist.choose(.always, for: request.id) }.buttonStyle(.glass) }
                    Button(request.allow) { app.assist.choose(.once, for: request.id) }.buttonStyle(.glass)
                    Button("Don't") { app.assist.choose(.no, for: request.id) }.buttonStyle(.glassProminent).tint(Color(nsColor: app.accent))
                } else {
                    Button("Don't") { app.assist.choose(.no, for: request.id) }.buttonStyle(.glass)
                    if !request.every { Button("Always") { app.assist.choose(.always, for: request.id) }.buttonStyle(.glass) }
                    Button(request.allow) { app.assist.choose(.once, for: request.id) }.buttonStyle(.glassProminent).tint(Color(nsColor: app.accent))
                }
            }
    }
}

/// The measured height of a card's buttons (on a note: kept below its scrolling words).
struct FormActionsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Small pictures of image files for stacks, made off the main thread and kept.
@MainActor @Observable
final class Thumbnails {
    static let shared = Thumbnails()
    private var images: [URL: NSImage] = [:]
    @ObservationIgnored private var making: Set<URL> = []

    func image(for url: URL) -> NSImage? {
        if let image = images[url] { return image }
        guard !making.contains(url) else { return nil }
        making.insert(url)
        DispatchQueue.global(qos: .userInitiated).async {
            var picture: NSImage?
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 96,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                picture = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.images.count > 300 { self.images = [:] }
                    self.images[url] = picture ?? NSWorkspace.shared.icon(forFile: url.path)
                }
            }
        }
        return nil
    }
}
