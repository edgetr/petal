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

    override var canBecomeKey: Bool { false }

    func show<Content: View>(_ content: Content, over slot: CGRect, dock: DockPanel?, gap: CGFloat = 8) {
        hosting.rootView = AnyView(content.environment(PetalApp.shared))
        place(over: slot, dock: dock, gap: gap)
    }

    /// Places what it shows over `slot` again, without making its view anew.
    func place(over slot: CGRect, dock: DockPanel?, gap: CGFloat = 8) {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
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
        orderFrontRegardless()
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
        orderFrontRegardless()
    }

    /// Fully visible again, also stopping a fade that's under way (setting alphaValue alone wouldn't).
    static func opaque(_ panel: NSWindow) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
    }

    func hide() { orderOut(nil) }
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

/// The slot's name, on a small glass pill outside the dock, with no delay.
@MainActor
final class Tooltips {
    private let panel: GlassPanel = {
        let panel = GlassPanel()
        panel.interactive = false
        return panel
    }()
    private var shownFor = ""
    /// One tooltip, its words changed in place: making its glass anew for every icon made it jump.
    private let words = TooltipWords()
    private var made = false

    func show(_ text: String?, over id: String, in dock: ScreenDock?) {
        let app = PetalApp.shared
        if text == nil && id != shownFor { return }   // leaving one icon after entering the next
        shownFor = id
        guard let text, !text.isEmpty, app.config.bool("tooltips"), let dock, dock.dragging == nil, dock.openPopup == nil,
              !app.popups.anyOpen, let panelRef = dock.panel, let slot = panelRef.screenFrame(of: id) else {
            panel.hide()
            return
        }
        words.text = text
        if made {
            panel.place(over: slot, dock: panelRef, gap: 2)
        } else {
            made = true
            panel.show(TooltipView(words: words), over: slot, dock: panelRef, gap: 2)
        }
    }

    func hide() { panel.hide() }
}

@MainActor @Observable
final class TooltipWords {
    var text = ""
}

struct TooltipView: View {
    let words: TooltipWords

    var body: some View {
        Text(words.text).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule).padding(6)
            .transaction { $0.animation = nil }
    }
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
        guard kind != nil, let anchor, let dock = openDock?.panel, let slot = dock.screenFrame(of: anchor), panel.isVisible else { return }
        panel.place(over: slot, dock: dock)
    }

    func showPreview(_ item: DockItem, in dock: ScreenDock) {
        guard let slot = dock.panel?.screenFrame(of: item.id) else { return }
        if kind == "stack" { return }
        kind = "preview"
        openDock = dock
        PetalApp.shared.tooltips.hide()
        panel.show(PreviewView(bundleID: item.id) { [weak self] in self?.closeAll() }, over: slot, dock: dock.panel)
    }

    var previewFrame: CGRect? { kind == "preview" ? panel.frame : nil }

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
        } else {
            let pill = panelRef.frame
            cardPanel.show(CardView(card: card), over: CGRect(x: pill.midX - 1, y: pill.minY, width: 2, height: pill.height), dock: panelRef)
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
        fade?.cancel()
        card = nil
        cardPanel.hide()
        GlassPanel.opaque(cardPanel)
    }
}

// MARK: - Previews

/// Window previews: after 380 ms over an app with windows; swapping straight to another app's; gone 220 ms after
/// the pointer leaves both the app and the preview.
@MainActor @Observable
final class Previews {
    private(set) var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored private var showTask: DispatchWorkItem?
    @ObservationIgnored private var hideTask: DispatchWorkItem?
    @ObservationIgnored private var refresh: Timer?
    @ObservationIgnored private(set) var showing: String?

    @ObservationIgnored private var hoveredID = ""

    func hover(_ item: DockItem?, in dock: ScreenDock, id: String = "") {
        let app = PetalApp.shared
        if item == nil && !id.isEmpty && id != hoveredID { return }   // leaving one icon after entering the next
        hoveredID = item?.id ?? ""
        showTask?.cancel()
        if let item, item.windows > 0, app.config.bool("previews"), dock.dragging == nil, app.popups.card == nil,
           app.popups.kind != "stack" {
            hideTask?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.open(item, in: dock) }
            showTask = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (showing == nil ? 0.38 : 0), execute: work)
        } else {
            scheduleHide()
        }
    }

    private func open(_ item: DockItem, in dock: ScreenDock) {
        // The window server counts windows Accessibility can't reach (another Desktop, hidden): with none to show,
        // no preview, rather than an empty bubble.
        guard !windows(of: item.id).isEmpty else { return scheduleHide() }
        showing = item.id
        PetalApp.shared.popups.showPreview(item, in: dock)
        capture(item.id)
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let id = self?.showing { self?.capture(id) } }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let frame = PetalApp.shared.popups.previewFrame, frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) {
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
        showing = nil
    }

    func windows(of bundleID: String) -> [AppWindow] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).flatMap { Windows.windows(of: $0.processIdentifier) }
    }

    private func capture(_ bundleID: String) {
        let list = Array(windows(of: bundleID).prefix(6))
        Task {
            let pictures = await Capture.capture(list)
            for (id, image) in pictures { thumbnails[id] = image }
        }
    }

    /// A still of a minimized window, taken once.
    func snapshot(_ window: AppWindow) {
        guard thumbnails[window.id] == nil else { return }
        Task {
            let pictures = await Capture.capture([window])
            for (id, image) in pictures { thumbnails[id] = image }
        }
    }
}

struct PreviewView: View {
    @Environment(PetalApp.self) private var app
    let bundleID: String
    let done: () -> Void

    var body: some View {
        let windows = Array(app.previews.windows(of: bundleID).prefix(6))
        HStack(spacing: 12) {
            ForEach(windows) { window in
                PreviewTile(window: window, image: app.previews.thumbnails[window.id], done: done)
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
                    VStack(spacing: 6) {
                        Image(systemName: "macwindow").font(.system(size: 28)).foregroundStyle(.secondary)
                        if !Capture.allowed {
                            Text("Allow Screen Recording\nfor previews").font(.system(size: 10)).multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(width: 200, height: 124)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hovering ? Color(nsColor: PetalApp.shared.accent) : .white.opacity(0.12),
                                                                    lineWidth: hovering ? 2 : 1))
            HStack(spacing: 6) {
                Text(window.title.isEmpty ? "Window" : window.title + (window.minimized ? " (minimized)" : ""))
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if !window.minimized { RoundButton(symbol: "minus") { Windows.minimize(window) } }
                RoundButton(symbol: "xmark") { Windows.close(window) }
            }
            .frame(width: 200)
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { Windows.focus(window); done() }
    }
}

struct RoundButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(hovering ? Color(nsColor: PetalApp.shared.accent) : .white.opacity(0.1), in: .circle)
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
    enum Kind { case block, move, peek, note, suggestion, made, summary }
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

    static func == (a: FocusCard, b: FocusCard) -> Bool { a.id == b.id && a.working == b.working && a.kind == b.kind }

    /// The mode button the card points at: the mode it's about; a peek's is the mode you're in.
    var pointsAt: String? {
        switch kind {
        case .block, .move, .note: target?.id
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
            }
        }
        .padding(card.kind == .peek ? 12 : 16)
        .frame(minWidth: card.kind == .peek ? 0 : 300, maxWidth: card.kind == .peek || card.kind == .note || card.kind == .block || card.kind == .move ? 380 : 420)
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
