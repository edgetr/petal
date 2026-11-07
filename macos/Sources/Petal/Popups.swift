import AppKit
import ImageIO
import Observation
import SwiftUI

/// A borderless glass panel that sits over a dock slot: tooltips, previews, stacks and cards.
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
        let screen = dock?.screenRef ?? NSScreen.main ?? NSScreen.screens[0]
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

    /// Shows a card next to `slot` (a mode button), with its tail pointing at it: above it on a bottom dock, beside
    /// it on a side dock. The card is laid out once to find its place, then again with the tail where the button is.
    func show<Content: View>(pointingAt slot: CGRect, dock: DockPanel, gap: CGFloat = 4, content: (Tail) -> Content) {
        let position = PetalApp.shared.config.position
        let edge: Tail.Edge = position == "left" ? .leading : position == "right" ? .trailing : .bottom
        hosting.rootView = AnyView(content(Tail(edge: edge, offset: 0)).environment(PetalApp.shared))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let screen = dock.screenRef ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.frame.insetBy(dx: 8, dy: 8)
        var origin: CGPoint
        switch edge {
        case .leading: origin = CGPoint(x: slot.maxX + gap, y: slot.midY - size.height / 2)
        case .trailing: origin = CGPoint(x: slot.minX - gap - size.width, y: slot.midY - size.height / 2)
        case .bottom: origin = CGPoint(x: slot.midX - size.width / 2, y: slot.maxY + gap)
        }
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        // How far the button is from the card's middle (SwiftUI counts y downward).
        let offset = edge == .bottom ? slot.midX - (origin.x + size.width / 2) : (origin.y + size.height / 2) - slot.midY
        hosting.rootView = AnyView(content(Tail(edge: edge, offset: offset)).environment(PetalApp.shared))
        setFrame(NSRect(origin: origin, size: size).integral, display: true)
        ignoresMouseEvents = !interactive
        if alphaValue != 1 { Self.opaque(self) }
        orderFrontRegardless()
    }

    /// At the screen's top right, under the menu bar.
    func showInCorner<Content: View>(_ content: Content, on screen: NSScreen) {
        hosting.rootView = AnyView(content.environment(PetalApp.shared))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let visible = screen.visibleFrame
        setFrame(NSRect(x: visible.maxX - size.width - 8, y: visible.maxY - size.height - 4, width: size.width, height: size.height).integral, display: true)
        ignoresMouseEvents = !interactive
        if alphaValue != 1 { Self.opaque(self) }
        orderFrontRegardless()
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
    /// One that took typing (a reply card, a secret) gives it back to the app in front, so keys don't go on to a
    /// card no one can see.
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

/// The small triangle on a card that points at the mode button it's about.
struct Tail: Equatable {
    enum Edge { case bottom, leading, trailing }
    var edge: Edge
    var offset: CGFloat
    static let size: CGFloat = 9
}

/// A rounded card with its tail.
struct CardShape: Shape {
    let tail: Tail?
    var radius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        guard let tail else { return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect) }
        var body = rect
        switch tail.edge {
        case .bottom: body.size.height -= Tail.size
        case .leading: body.origin.x += Tail.size; body.size.width -= Tail.size
        case .trailing: body.size.width -= Tail.size
        }
        let path = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: body)
        let half = Tail.size
        var point = Path()
        switch tail.edge {
        case .bottom:
            let x = min(max(body.midX + tail.offset, body.minX + radius + half), body.maxX - radius - half)
            point.move(to: CGPoint(x: x - half, y: body.maxY - 1))
            point.addLine(to: CGPoint(x: x, y: rect.maxY))
            point.addLine(to: CGPoint(x: x + half, y: body.maxY - 1))
        case .leading, .trailing:
            let y = min(max(body.midY + tail.offset, body.minY + radius + half), body.maxY - radius - half)
            let base = tail.edge == .leading ? body.minX + 1 : body.maxX - 1
            point.move(to: CGPoint(x: base, y: y - half))
            point.addLine(to: CGPoint(x: tail.edge == .leading ? rect.minX : rect.maxX, y: y))
            point.addLine(to: CGPoint(x: base, y: y + half))
        }
        point.closeSubpath()
        return path.union(point)
    }
}

extension View {
    /// Room inside the card for its tail.
    func roomForTail(_ tail: Tail?) -> some View {
        padding(tail?.edge == .bottom ? .bottom : tail?.edge == .leading ? .leading : .trailing, tail == nil ? 0 : Tail.size)
    }
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

/// Stacks, previews and cards: one open at a time; clicking elsewhere closes the stack.
@MainActor @Observable
final class Popups {
    @ObservationIgnored private let panel = GlassPanel()
    @ObservationIgnored private let cardPanel = GlassPanel()
    @ObservationIgnored private var monitor: Any?
    private(set) var kind: String?           // "stack", "preview"
    private(set) var card: FocusCard?
    /// The open stack's files.
    @ObservationIgnored private(set) var stack: StackContents?
    @ObservationIgnored private var anchor: String?
    @ObservationIgnored private weak var openDock: ScreenDock?
    @ObservationIgnored private var keys: Any?
    @ObservationIgnored private var fade: DispatchWorkItem?

    var anyOpen: Bool { kind != nil || card != nil }

    init() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.kind == "stack" else { return }
                if !self.panel.frame.contains(NSEvent.mouseLocation) { self.closeAll() }
            }
        }
        // Escape answers a card the way × does (cards never take the keyboard from the app in front).
        keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard event.keyCode == 53, let card = self?.card else { return }
                PetalApp.shared.focus.dismiss(card)
            }
        }
    }

    func closeAll() {
        let wasPreview = kind == "preview"
        panel.hide()
        kind = nil
        stack = nil
        anchor = nil
        openDock?.openPopup = nil
        openDock = nil
        PetalApp.shared.tooltips.hide()
        if wasPreview { PetalApp.shared.previews.closed() }
    }

    /// The stack opens once its files are read, off the main thread (a few milliseconds), at the size they need.
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

    /// One card at a time; a newer one replaces an older one. A card about a mode points at that mode's button.
    func show(_ card: FocusCard) {
        guard let dock = PetalApp.shared.docks.focusedDock, let panelRef = dock.panel else { return }
        self.card = card
        closeAll()
        panelRef.reveal()
        fade?.cancel()
        GlassPanel.opaque(cardPanel)
        if let mode = card.pointsAt, let slot = panelRef.screenFrame(of: "mode:\(mode)") {
            cardPanel.show(pointingAt: slot, dock: panelRef) { CardView(card: card, tail: $0) }
        } else if [.summary, .suggestion, .made, .reply].contains(card.kind) {
            // Nothing on the dock to point at: top right, out of the dock's way, as macOS's own notices sit.
            cardPanel.showInCorner(CardView(card: card), on: panelRef.screenRef ?? NSScreen.main ?? NSScreen.screens[0])
        } else {
            let pill = panelRef.frame
            cardPanel.show(CardView(card: card), over: CGRect(x: pill.midX - 1, y: pill.minY, width: 2, height: pill.height), dock: panelRef)
        }
        // A card asking for a secret takes the keyboard for it.
        // One taking the place of a card that had the keyboard (a notice over a reply being written) gives it back.
        if card.kind == .reply || (card.kind == .ask && PetalApp.shared.assist.pending?.takesKeys == true) {
            cardPanel.takesKeys = true
            cardPanel.makeKey()
        } else {
            cardPanel.releaseKeys()
        }
        // A peek fades out by itself.
        if card.kind == .peek {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.card?.id == card.id else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.4
                    self.cardPanel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated { if self.card?.id == card.id { self.dismissCard() } }
                })
            }
            fade = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }

    func dismissCard() {
        let asking = card?.kind == .ask
        fade?.cancel()
        card = nil
        if asking { PetalApp.shared.assist.cardClosed() }
        cardPanel.hide()   // made opaque again as the next card shows
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
    /// Pictures of the windows the notes work in, by note.
    private(set) var noteThumbs: [UUID: NSImage] = [:]
    @ObservationIgnored private var capturingNotes = false
    @ObservationIgnored private var noteCount = 0
    /// Made-up notes, for `Petal --snapshot`.
    @ObservationIgnored private var sampleNotes: [NotePreviewItem]?
    /// The notes the AI button's preview shows.
    var noteItems: [NotePreviewItem] { sampleNotes ?? PetalApp.shared.claude.previewItems }
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
        dock.dragging == nil && PetalApp.shared.popups.card == nil && PetalApp.shared.popups.kind != "stack"
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
        if id == Self.notes { noteCount = noteItems.count; captureNotes() }
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
            // No picture kept of a window that's gone, or of an app now kept private.
            let pictured = Set(items.filter(\.pictured).map(\.id))
            noteThumbs = noteThumbs.filter { pictured.contains($0.key) }
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
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).flatMap { Windows.windows(of: $0.processIdentifier) }
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
            let pictures = await Capture.notes(items.map { (id: $0.id, seen: $0.seen) })
            capturingNotes = false
            guard showing == Self.notes else { return }
            // Kept only if it shows the window asked for (any of its app's only for a note on all of an app), its
            // note still has that very window, and its app wasn't made private meanwhile.
            let now = Dictionary(noteItems.map { ($0.id, $0.seen) }, uniquingKeysWith: { first, _ in first })
            for (id, picture) in pictures {
                if let seen = taken[id], NotePicture.accepts(picture.shot, taken: seen, now: now[id]) { noteThumbs[id] = picture.image }
                else { noteThumbs[id] = nil }
            }
        }
    }

    /// What `Petal --snapshot` draws the AI button's preview with.
    func preview(notes: [NotePreviewItem]?, thumbnails: [UUID: NSImage] = [:]) {
        sampleNotes = notes
        noteThumbs = thumbnails
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

// MARK: - Cards

/// A card over the dock: a focus card (block, move or peek), a held notification that can't wait, a suggested mode,
/// a mode just made from one, or the weekly summary. Updates are in the menu bar, not here.
struct FocusCard: Identifiable, Equatable {
    enum Kind { case block, move, peek, note, suggestion, made, summary, ask, reply, noteReady }
    let id = UUID()
    let kind: Kind
    var bundleID = ""
    var title = ""
    var target: Mode?
    var here: Mode?
    var reason = ""
    var desktop: Int?
    var front: Front?
    var note: HeldNote?
    var suggestion: Insights.Suggestion?
    var summary: Insights.Summary?
    var working = false
    /// A sticky note done in another mode (noteReady).
    var noteID: UUID?

    static func == (a: FocusCard, b: FocusCard) -> Bool { a.id == b.id && a.working == b.working && a.kind == b.kind }

    /// The mode button the card points at: the mode it's about; a peek's is the mode you're in.
    var pointsAt: String? {
        switch kind {
        case .block, .move, .note, .noteReady: target?.id
        case .peek: here?.id
        default: nil
        }
    }
}

struct CardView: View {
    @Environment(PetalApp.self) private var app
    let card: FocusCard
    var tail: Tail? = nil

    var body: some View {
        Group {
            switch card.kind {
            case .block, .move, .peek: FrontCard(card: card)
            case .note: NoteCard(card: card)
            case .suggestion, .made: suggestionCard
            case .summary: SummaryCard(card: card)
            case .ask: AskCard()
            case .reply: ReplyCard(card: card)
            case .noteReady: NoteReadyCard(card: card)
            }
        }
        .padding(card.kind == .peek ? 12 : 16)
        .frame(minWidth: card.kind == .peek ? 0 : 300, maxWidth: card.kind == .peek || card.kind == .note || card.kind == .noteReady || card.kind == .block || card.kind == .move ? 380 : 420)
        .fixedSize(horizontal: card.kind == .peek, vertical: false)
        .roomForTail(tail)
        .glassEffect(.regular, in: CardShape(tail: tail))
        .padding(6)
    }

    // MARK: Suggestions

    private var suggestionCard: some View {
        let suggestion = card.suggestion
        let mode = card.kind == .made ? card.target : app.config.modes.first { $0.id == suggestion?.mode }
        return VStack(alignment: .trailing, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AppIcons(ids: suggestion?.apps ?? [], size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    if card.kind == .made, let mode {
                        Text("\(Text(mode.name).bold()) is ready.").font(.system(size: 13))
                        Text("With \(Insights.list((suggestion?.apps ?? []).map(Apps.name))). Put a Desktop in it from the mode switcher.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if let suggestion {
                        Text(suggestion.text(modeName: mode?.name ?? suggestion.mode)).font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(suggestion.kind == .mode ? "A mode of their own, with just these apps in its dock." : "\(suggestion.names.first ?? "It") joins \(mode?.name ?? "the mode")'s apps in the dock.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                RoundButton(symbol: "xmark") { app.popups.dismissCard() }
            }
            HStack(spacing: 8) {
                if card.kind == .made, let mode {
                    Button("OK") { app.popups.dismissCard() }.buttonStyle(.glass)
                    if let desktop = card.desktop {
                        Button("Use it here") { app.popups.dismissCard(); app.requestMode(mode.id, desktop: desktop) }
                            .buttonStyle(.glassProminent).tint(Color(nsColor: mode.color))
                    }
                } else if let suggestion {
                    if card.working { ProgressView().controlSize(.small) }
                    Button("Not now") { app.insights.decline(card) }.buttonStyle(.glass).disabled(card.working)
                    Button(suggestion.kind == .mode ? "Make it" : "Keep it") { app.insights.accept(card) }
                        .buttonStyle(.glassProminent).tint(Color(nsColor: mode?.color ?? app.accent)).disabled(card.working)
                }
            }
        }
    }
}

/// A few app icons, overlapping a little.
struct AppIcons: View {
    let ids: [String]
    let size: CGFloat

    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(ids.prefix(3), id: \.self) { id in
                Image(nsImage: Apps.icon(id)).resizable().frame(width: size, height: size)
            }
        }
    }
}

/// The weekly summary: time in each mode, its top apps, and how focus cards went. Plain and kind.
/// Petal AI wants to do something that changes things: Allow once, Always (for this kind), or Don't. The chat panel
/// shows the same question in the conversation when it's open.
struct AskCard: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        if let request = app.assist.pending {
            // Its own view per question: nothing typed for one is ever kept for the next.
            AskRequestView(request: request).id(request.id)
        }
    }
}

struct AskRequestView: View {
    @Environment(PetalApp.self) private var app
    let request: Assist.Request

    var body: some View {
        if let form = request.form { VaultFormView(request: request, form: form) } else { question }
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ProviderMark(provider: app.chatProvider).frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if !request.detail.isEmpty {
                        Text(request.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer()
                if request.warn {
                    // Something doesn't match, or it pays: Don't is the one to press without thinking.
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
}

struct SummaryCard: View {
    @Environment(PetalApp.self) private var app
    let card: FocusCard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(card.summary?.title ?? "Your week").font(.system(size: 13, weight: .bold))
                Spacer()
                RoundButton(symbol: "xmark") { app.popups.dismissCard() }
            }
            if !card.reason.isEmpty {
                Text("✦ " + card.reason).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            }
            if let summary = card.summary { SummaryRows(summary: summary) }
            HStack {
                Spacer()
                Button("Thanks") { app.popups.dismissCard() }.buttonStyle(.glass)
            }
        }
    }
}

struct SummaryRows: View {
    @Environment(PetalApp.self) private var app
    let summary: Insights.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if summary.modes.isEmpty {
                Text("Nothing yet: Petal notes which app is in front, a minute at a time, while you use your Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(summary.modes.prefix(5), id: \.id) { mode in
                let color = Color(nsColor: app.config.modes.first { $0.id == mode.id }?.color ?? app.accent)
                HStack(spacing: 10) {
                    ModeIcon(icon: app.config.modes.first { $0.id == mode.id }?.icon ?? "circle.fill", size: 12)
                        .foregroundStyle(color).frame(width: 22)
                    Text(Insights.Summary.line(mode)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    AppIcons(ids: mode.apps.map(\.id), size: 20)
                }
            }
            if let line = summary.cardsLine {
                Text(line).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
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
