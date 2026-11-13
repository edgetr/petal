import AppKit
import Observation
import QuartzCore
import SwiftUI

/// Which way the dock's apps are drawn: SwiftUI views (one view tree per app), or Core Animation layers in one
/// view, the way macOS's own Dock is drawn. `defaults write tech.edgetr.petal layerStrip -bool NO` (then restarting
/// Petal) goes back to the SwiftUI views; `petal bench` times both.
@MainActor @Observable
final class DockStrip {
    static let shared = DockStrip()
    var layers = UserDefaults.standard.object(forKey: "layerStrip") as? Bool ?? true

    static var label: String { shared.layers ? "layers" : "SwiftUI" }
}

/// The dock's apps as Core Animation layers in one view: a row that changes only when the apps do. Hover lift, the
/// press, the bounce, the launch pulse, the glow and magnification are all layer properties and animations: the
/// window server runs them, and SwiftUI never lays the dock out again for them. Popups find each app through
/// `dock.frames`, as with the SwiftUI slots. The row keeps the slot after its apps for "+", which the dock draws over
/// it as SwiftUI's clear glass (`DockView.stage`): a layer can't be glass.
struct AppStrip: NSViewRepresentable {
    let dock: ScreenDock
    let length: CGFloat
    let slot: CGFloat

    func makeNSView(context: Context) -> AppStripView { AppStripView(dock: dock) }
    func updateNSView(_ view: AppStripView, context: Context) { view.stageSize = stageSize }
    var stageSize: CGSize { dock.vertical ? CGSize(width: slot, height: length) : CGSize(width: length, height: slot) }

    /// The room the strip's view reaches past its stage: inward for lifted, bouncing and magnified icons (and their
    /// mouse, when magnified), and along the dock for badges and glows. Its clear parts let the mouse through.
    static func room(icon: CGFloat, slot: CGFloat) -> (inward: CGFloat, along: CGFloat) {
        let reach = Magnifier.enabled ? Magnifier.room(slot: slot, amount: Magnifier.amount) : 0
        return (max(icon * 0.75, Magnifier.enabled ? slot * Magnifier.amount + 6 : 0), max(slot * 0.5, reach))
    }
}

extension View {
    /// The strip's view, reaching past the stage it holds (see `AppStrip.room`).
    func stripRoom(_ dock: ScreenDock, icon: CGFloat, slot: CGFloat) -> some View {
        let room = AppStrip.room(icon: icon, slot: slot)
        let inward: Edge.Set = switch PetalApp.shared.config.position { case "left": .trailing; case "right": .leading; default: .top }
        let along: Edge.Set = dock.vertical ? .vertical : .horizontal
        return padding(inward, -room.inward).padding(along, -room.along)
    }
}

@MainActor
final class AppStripView: NSView {
    weak var dock: ScreenDock?
    /// The stage's size; the view reaches past it on every side by `room`.
    var stageSize: CGSize = .zero { didSet { if stageSize != oldValue { needsSync() } } }

    private var row: Row?
    private var look: Look?
    private var hovered: String?
    private var pressed: String?
    private var fileOver: String?
    private var down: NSPoint?
    private var downOn: String?
    private var dragging = false
    private var bounced: [String: Int] = [:]
    private var tracking: NSTrackingArea?
    private var dirty = true

    var app: PetalApp { PetalApp.shared }

    init(dock: ScreenDock) {
        self.dock = dock
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        registerForDraggedTypes(DockDrops.types + [.petalNote])
        dock.strip = self
        bounced = PetalApp.shared.signals.bounces
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Keeping current

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { observe() }
        watchMouseLeaving()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        look = nil   // icons drawn again for the new scale
        needsSync()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsSync()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        registerFrames()
    }

    /// Something the layers show changed: they're brought up to date in the window's next layout pass, before it
    /// draws (so the change is drawn in the same frame, and `petal bench` counts it).
    private func needsSync() {
        dirty = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if dirty { observe() }
    }

    /// Brings the layers up to date, and does it again whenever anything they show changes.
    private func observe() {
        guard window != nil else { return }
        dirty = false
        withObservationTracking { sync() } onChange: { [weak self] in
            if Thread.isMainThread { MainActor.assumeIsolated { self?.needsSync() } }
            else { DispatchQueue.main.async { MainActor.assumeIsolated { self?.needsSync() } } }
        }
        registerFrames()
        magnify()
        updateHover()
        applyLift()
    }

    /// The settings the layers are drawn from; a change in any of them draws the row anew.
    struct Look: Equatable {
        var icon: CGFloat
        var slot: CGFloat
        var position: String
        var scale: CGFloat
        var glow: Bool
        var accent: NSColor
    }

    private func sync() {
        guard let dock else { return }
        let config = app.config
        let icon = dock.icon   // the setting's, or smaller to fit along the screen's edge
        let inset = config.number("iconPadding") >= 0 ? config.number("iconPadding") : 5
        let now = Look(icon: icon, slot: icon + inset * 2, position: config.position, scale: window?.backingScaleFactor ?? 2,
                       glow: config.bool("appGlow"), accent: app.accent)
        if now != look {
            row?.container.removeFromSuperlayer()
            row = nil
            look = now
        }
        guard let look else { return }
        // What the dock shows that the layers depend on (read here so a change in any of them syncs again).
        let state = Shared(app: app, dock: dock, look: look)
        // The first time the apps are just there; after that they grow in, shrink away and move.
        let made = row == nil
        let row = self.row ?? Row()
        if made {
            layer?.addSublayer(row.container)
            self.row = row
        }
        row.update(dock.items, stage: stageRect, state: state, live: !made, strip: self)
        // Bounces: once for each new ask.
        for (id, count) in app.signals.bounces where count != bounced[id] {
            bounced[id] = count
            if config.bool("bounce"), let tile = row.tiles[id], tile.item?.active == false { tile.bounce(look) }
        }
    }

    /// What every tile reads, read once per sync.
    struct Shared {
        let config: Config
        let look: Look
        let launching: Set<String>
        let badges: [String: String]
        let dragging: String?
        let dragOffset: CGFloat
        let dragOut: Bool
        let idle: CGFloat
        let glowStrength: CGFloat
        let showBadges: Bool

        @MainActor init(app: PetalApp, dock: ScreenDock, look: Look) {
            config = app.config
            self.look = look
            launching = Set(app.launching.keys)
            var badges = app.config.bool("badges") ? app.signals.badges : [:]
            for id in app.claude.readyApps { badges[id] = "✦" }   // a sticky note done while away
            self.badges = badges
            dragging = dock.dragging
            dragOffset = dock.dragOffset
            dragOut = dock.dragOut
            idle = app.config.number("idleOpacity")
            glowStrength = min(1, max(0, app.config.number("glowStrength")))
            showBadges = app.config.bool("badges") || !app.claude.readyApps.isEmpty
        }
    }

    /// The stage inside the view (layer coordinates, y up): the view reaches past it by `AppStrip.room`.
    private var stageRect: CGRect {
        guard let look else { return .zero }
        let room = AppStrip.room(icon: look.icon, slot: look.slot)
        var rect = bounds
        let vertical = look.position != "bottom"
        if vertical { rect = rect.insetBy(dx: 0, dy: room.along) } else { rect = rect.insetBy(dx: room.along, dy: 0) }
        switch look.position {
        case "left": rect.size.width -= room.inward
        case "right": rect.origin.x += room.inward; rect.size.width -= room.inward
        default: rect.size.height -= room.inward
        }
        return rect
    }

    /// A shift toward the inside of the screen (away from the dock's edge), in layer coordinates.
    static func inward(_ position: String, _ distance: CGFloat) -> CGAffineTransform {
        switch position {
        case "left": CGAffineTransform(translationX: distance, y: 0)
        case "right": CGAffineTransform(translationX: -distance, y: 0)
        default: CGAffineTransform(translationX: 0, y: distance)
        }
    }

    // MARK: Where things are, for popups and magnification

    /// A tile's slot in the panel, top-left origin, as SwiftUI's `.global` frames are.
    func windowRect(of id: String) -> CGRect? {
        guard let tile = row?.tiles[id], let content = window?.contentView else { return nil }
        let rect = convert(tile.base, to: nil)
        return CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A tile's slot as it's drawn now (grown and moved by magnification), in the same coordinates as `windowRect`.
    func drawnRect(of id: String) -> CGRect? {
        guard let tile = row?.tiles[id], let content = window?.contentView else { return nil }
        let rect = convert(tile.slot.frame, to: nil)
        return CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private var registered: Set<String> = []

    func registerFrames() {
        guard let dock, let row, window != nil else { return }
        var now: Set<String> = []
        for id in row.order {
            guard let rect = windowRect(of: id) else { continue }
            dock.frames[id] = rect
            if Magnifier.enabled { dock.magnifier.register(id, rect, scales: true, owner: nil) }
            now.insert(id)
        }
        for id in registered.subtracting(now) { dock.magnifier.unregister(id, owner: nil) }
        registered = now
    }

    /// Magnification: each tile grows and moves by a transform, as the SwiftUI slots do.
    func magnify() {
        guard let dock, let row, let look else { return }
        let magnifier = dock.magnifier
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tile in row.allTiles {
            let effect: (scale: CGFloat, shift: CGFloat) = magnifier.on ? magnifier.effect(tile.id) : (1, 0)
            tile.magnify(scale: effect.scale, shift: effect.shift, look: look)
        }
        CATransaction.commit()
    }

    // MARK: The mouse

    /// The tile under a point (view coordinates): its slot, reaching inward over its grown icon when magnified.
    private func tile(at point: NSPoint) -> Tile? {
        guard let row, let look else { return nil }
        let reach = Magnifier.enabled ? look.icon * Magnifier.amount * 1.3 : 0
        for tile in row.allTiles where !tile.leaving {
            var area = tile.base
            switch look.position {
            case "left": area.size.width += reach
            case "right": area.origin.x -= reach; area.size.width += reach
            default: area.size.height += reach
            }
            if area.contains(point) { return tile }
        }
        return nil
    }

    /// The app a click at `point` (window coordinates, top-left origin, as `windowRect`) goes to (`--bench-dock`).
    func app(atWindow point: CGPoint) -> String? {
        guard let content = window?.contentView else { return nil }
        return tile(at: convert(CGPoint(x: point.x, y: content.bounds.height - point.y), from: nil))?.id
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return tile(at: convert(point, from: superview)) != nil ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        registerFrames()
        dock?.magnifier.wake()
        updateHover()
    }
    override func mouseMoved(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { setHover(nil) }

    /// See SlotMouse: the dock says when the pointer has left it, in case macOS doesn't get to.
    private func watchMouseLeaving() {
        if let leftObserver { NotificationCenter.default.removeObserver(leftObserver) }
        leftObserver = nil
        guard let window else { return }
        leftObserver = NotificationCenter.default.addObserver(forName: DockPanel.mouseLeft, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setHover(nil) }
        }
    }
    private var leftObserver: Any?

    private func updateHover() {
        guard let window, dragging == false, dock?.dragging == nil else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let inside = window.frame.contains(NSEvent.mouseLocation) && !(window as? DockPanel).map(\.tucked).isTrue
        setHover(inside ? tile(at: point)?.id : nil)
    }

    /// `petal bench`: the pointer reaching an icon, without moving it.
    func benchHover(_ id: String?) { setHover(id) }

    /// The apps showing, in order.
    var shownOrder: [String] { row?.order ?? [] }

    private func setHover(_ id: String?) {
        guard id != hovered, let dock else { return }
        let old = hovered
        hovered = id
        if let old { hover(old, false, dock) }
        if let id { hover(id, true, dock) }
        Perf.span("hover: lift") { applyLift() }
    }

    private func hover(_ id: String, _ on: Bool, _ dock: ScreenDock) {
        guard let item = row?.tiles[id]?.item else {
            if !on { app.tooltips.show(nil, over: id, in: dock); app.previews.hover(nil, in: dock, id: id) }
            return
        }
        if on { Perf.span("hover: magnifier") { dock.magnifier.wake() } }
        // The preview first: the last app's goes (or this one's swaps in) before the tooltip asks whether one is open.
        Perf.span("hover: preview") { app.previews.hover(on ? item : nil, in: dock, id: item.id) }
        let name = Perf.span("hover: name") { on ? Apps.name(item.id) : nil }
        Perf.span("hover: tooltip") { app.tooltips.show(name, over: item.id, in: dock) }
        if on && app.config.bool("recentFiles") { Perf.span("hover: recent") { Apps.prefetchRecent(item.id) } }
        if on && item.running { Perf.span("hover: new item") { Apps.prefetchNewItem(item.id) } }   // what ⌘N is, for its menu
    }

    private func applyLift() {
        guard let row, let look, let dock else { return }
        let amount = app.config.bool("hoverLift") && !Magnifier.enabled ? app.config.number("hoverLiftAmount") : 0
        for tile in row.allTiles {
            let on = tile.id == hovered && dock.dragging == nil
            tile.setLift(on ? amount : 0, look: look)
        }
    }

    override func mouseDown(with event: NSEvent) {
        down = NSEvent.mouseLocation
        downOn = tile(at: convert(event.locationInWindow, from: nil))?.id
        dragging = false
        setPressed(downOn)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down, let id = downOn, let dock else { return }
        let point = NSEvent.mouseLocation
        let delta = dock.vertical ? down.y - point.y : point.x - down.x
        if !dragging && (abs(point.x - down.x) > 4 || abs(point.y - down.y) > 4) {
            dragging = true
            setPressed(nil)
        }
        guard dragging else { return }
        // Past the glass by more than a slot, one of the dock's own apps is out: let go, it's removed.
        let slot = Double(look?.slot ?? 44)
        let inward = Double(dock.panel?.inward(of: point) ?? 0)
        if dock.dragging == nil {
            guard abs(delta) >= 6 || DockRules.isOut(inward: inward, slot: slot) else { return }
            app.popups.closeAll()
            app.previews.hover(nil, in: dock, id: id)
            app.tooltips.hide()
            setHover(nil)
            dock.dragging = id
        }
        dock.dragOffset = delta
        let fades = DockRules.fades(inward: inward, slot: slot, kept: app.config.apps.contains(id))
        if dock.dragOut != fades { dock.dragOut = fades }
    }

    override func mouseUp(with event: NSEvent) {
        defer { down = nil; downOn = nil; dragging = false }
        setPressed(nil)
        guard let dock, let id = downOn else { return }
        if dragging {
            let from = dock.items.firstIndex { $0.id == id } ?? 0
            // Where the pointer is as it's let go, not how the icon looks (only one of the dock's own fades out).
            let inward = Double(dock.panel?.inward(of: NSEvent.mouseLocation) ?? 0)
            let end = DockRules.dragEnd(began: dock.dragging == id, from: from, offset: dock.dragOffset, slot: Double(look?.slot ?? 44),
                                        count: dock.items.count, kept: app.config.apps.contains(id), inward: inward)
            dock.dragging = nil
            dock.dragOffset = 0
            dock.dragOut = false
            switch end {
            case .click: click(id)   // a click that slipped is still a click
            case .move(let to): app.docks.move(id, to: to, in: dock)
            case .remove: app.config.removeApp(id)
            case .nothing: break
            }
            return
        }
        // Released somewhere else: no click.
        guard tile(at: convert(event.locationInWindow, from: nil))?.id == id else { return }
        click(id)
    }

    private func click(_ id: String) {
        guard let item = row?.tiles[id]?.item else { return }
        app.popups.closeAll()
        app.docks.activate(item)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let item = tile(at: convert(event.locationInWindow, from: nil))?.item { Menus.app(item) }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let tile = tile(at: convert(event.locationInWindow, from: nil)), tile.item != nil else { return }
        app.docks.newWindow(tile.id)
    }

    private func setPressed(_ id: String?) {
        guard id != pressed else { return }
        let old = pressed
        pressed = id
        for key in [old, id].compactMap({ $0 }) {
            guard let tile = row?.tiles[key] else { continue }
            tile.press(key == id)
        }
    }

    // MARK: Files dropped on an app

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        app.docks.revealAll()
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // A note (Petal Notes) goes to any app; documents only with dropToOpen, and never to a website shortcut;
        // an app, a folder or a web address is added to the dock, wherever it's let go.
        let note = sender.draggingPasteboard.types?.contains(.petalNote) == true
        let under = tile(at: convert(sender.draggingLocation, from: nil)).flatMap { $0.item == nil || Sites.isWeb($0.id) ? nil : $0.id }
        if !note {
            switch DockDrops.action(dropped(sender), onApp: app.config.bool("dropToOpen") ? under : nil) {
            case .add:
                setFileOver(nil)
                return .copy
            case .open:
                setFileOver(under)
                return .copy
            case nil:
                setFileOver(nil)
                return []
            }
        }
        setFileOver(under)
        return under == nil ? [] : .copy
    }

    /// What the drag under way holds, read once per drag.
    private func dropped(_ sender: NSDraggingInfo) -> [DockRules.Dropped] {
        if let held, held.0 == sender.draggingSequenceNumber { return held.1 }
        let items = DockDrops.items(sender.draggingPasteboard)
        held = (sender.draggingSequenceNumber, items)
        return items
    }
    private var held: (Int, [DockRules.Dropped])?

    override func draggingExited(_ sender: NSDraggingInfo?) { setFileOver(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let target = fileOver
        setFileOver(nil)
        if let target, let id = sender.draggingPasteboard.data(forType: .petalNote).map({ String(decoding: $0, as: UTF8.self) }) {
            app.paper.use(id, in: target)
            return true
        }
        let items = dropped(sender)
        held = nil
        return DockDrops.perform(items, onApp: target)
    }

    private func setFileOver(_ id: String?) {
        guard id != fileOver else { return }
        fileOver = id
        needsSync()
    }

    var fileTarget: String? { fileOver }
}

private extension Optional where Wrapped == Bool {
    var isTrue: Bool { self ?? false }
}

// MARK: - The row of apps

@MainActor
final class Row {
    let container = CALayer()
    var tiles: [String: Tile] = [:]
    var order: [String] = []

    var allTiles: [Tile] { order.compactMap { tiles[$0] } }

    init() { container.masksToBounds = false }

    /// Brings the row to `items`: new apps grow in, gone ones shrink away, the rest move to their places.
    func update(_ items: [DockItem], stage: CGRect, state: AppStripView.Shared, live: Bool, strip: AppStripView) {
        let look = state.look
        let scale = look.scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = strip.bounds
        container.contentsScale = scale
        CATransaction.commit()

        let ids = items.map(\.id)
        // Gone.
        for (id, tile) in tiles where !ids.contains(id) {
            tiles[id] = nil
            tile.leave(animated: live)
        }
        // Where each slot is: the apps and "+" (the dock's SwiftUI glass, over the slot kept for it), centered on the
        // stage.
        let count = CGFloat(items.count + 1)
        let vertical = look.position != "bottom"
        let lengthAlong = vertical ? stage.height : stage.width
        let start = (lengthAlong - count * look.slot) / 2
        func base(_ index: Int) -> CGRect {
            let offset = start + CGFloat(index) * look.slot
            return vertical
                ? CGRect(x: stage.minX, y: stage.maxY - offset - look.slot, width: look.slot, height: look.slot)
                : CGRect(x: stage.minX + offset, y: stage.minY, width: look.slot, height: look.slot)
        }
        // While an app is dragged, it follows the pointer and the apps it passes make room.
        let from = state.dragging.flatMap { ids.firstIndex(of: $0) }
        func dragShift(_ index: Int, _ id: String) -> CGFloat {
            guard let from else { return 0 }
            if id == state.dragging { return state.dragOffset }
            if state.dragOut { return index > from ? -look.slot : 0 }   // out of the dock: the apps after it close the gap
            let to = from + Int((state.dragOffset / look.slot).rounded())
            if from < index && index <= to { return -look.slot }
            if to <= index && index < from { return look.slot }
            return 0
        }
        for (index, item) in items.enumerated() {
            let isNew = tiles[item.id] == nil
            let tile = tiles[item.id] ?? Tile(id: item.id, in: container)
            tiles[item.id] = tile
            let rect = base(index)
            let shift = dragShift(index, item.id)
            tile.set(item: item, state: state, fileOver: strip.fileTarget == item.id)
            tile.place(rect, shift: shift, look: look, animated: live && !isNew, dragged: item.id == state.dragging)
            if isNew && live { tile.appear() }
        }
        order = ids
    }
}

// MARK: - One app

/// One app's layers. Each concern has its own layer, so their transforms never fight: the slot (where it is, and
/// magnification), the hop (the bounce), the lift (hover, and growing while dragged or under a file), the holder (idle
/// dimming and the press), and inside it the icon (the launch pulse) with its press shade; the glow and the badge
/// ride the lift, the dot stays on the slot.
@MainActor
final class Tile {
    let id: String
    private(set) var item: DockItem?
    private(set) var base: CGRect = .zero
    private(set) var leaving = false

    let slot = CALayer()
    let hop = CALayer()
    let lift = CALayer()
    let glow = CAGradientLayer()
    let holder = CALayer()
    let icon = CALayer()
    let shade = CALayer()
    let shadeMask = CALayer()
    let badge = CALayer()
    let dot = CALayer()

    private var drawn: (image: String, size: CGFloat, scale: CGFloat)?
    private var sized: AppStripView.Look?
    private var badgeText: String?
    private var pulsing = false
    private var liftAmount: CGFloat = 0
    private var magnification: (scale: CGFloat, shift: CGFloat) = (1, 0)
    private var grown = false
    private var glowColor: NSColor?
    private var dotColor: NSColor?

    init(id: String, in container: CALayer) {
        self.id = id
        for layer in [slot, hop, lift, glow, holder, icon, shade, shadeMask, badge, dot] {
            layer.delegate = NoActions.shared   // no implicit animations: each one is explicit
            layer.masksToBounds = false
        }
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.locations = [0, 0.5, 1]
        glow.opacity = 0
        icon.contentsGravity = .resizeAspect
        icon.minificationFilter = .trilinear
        icon.magnificationFilter = .linear
        shade.backgroundColor = NSColor.black.cgColor
        shade.opacity = 0
        shade.mask = shadeMask
        shadeMask.contentsGravity = .resizeAspect
        badge.contentsGravity = .resize
        dot.opacity = 0
        holder.addSublayer(icon)
        holder.addSublayer(shade)
        lift.addSublayer(glow)
        lift.addSublayer(holder)
        lift.addSublayer(badge)
        hop.addSublayer(lift)
        slot.addSublayer(hop)
        slot.addSublayer(dot)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.addSublayer(slot)
        CATransaction.commit()
    }

    /// Sets properties with no animation.
    private func still(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// A property change that animates (the tile's layers animate only through explicit animations).
    private func ease(_ layer: CALayer, _ key: String, to value: Any, from: Any?, duration: Double) {
        guard duration > 0, let from else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: key)
    }

    private func setOpacity(_ layer: CALayer, _ value: Float, duration: Double) {
        guard layer.opacity != value else { return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = value
        ease(layer, "opacity", to: value, from: from, duration: duration)
    }

    private func setTransform(_ layer: CALayer, _ value: CATransform3D, duration: Double) {
        guard !CATransform3DEqualToTransform(layer.transform, value) else { return }
        let from = layer.presentation()?.transform ?? layer.transform
        layer.transform = value
        ease(layer, "transform", to: value, from: duration > 0 ? NSValue(caTransform3D: from) : nil, duration: duration)
    }

    // MARK: What it shows

    func set(item: DockItem, state: AppStripView.Shared, fileOver: Bool) {
        let look = state.look
        let old = self.item
        self.item = item
        let size = look.icon
        let slotSize = look.slot
        let web = Sites.isWeb(item.id)
        if sized != look {
            sized = look
            still {
                for layer in [slot, hop, lift, holder] {
                    layer.bounds = CGRect(x: 0, y: 0, width: slotSize, height: slotSize)
                    layer.position = CGPoint(x: slotSize / 2, y: slotSize / 2)
                }
                for layer in [icon, shade] {
                    layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                    layer.position = CGPoint(x: slotSize / 2, y: slotSize / 2)
                }
                shadeMask.frame = shade.bounds
                glow.bounds = CGRect(x: 0, y: 0, width: slotSize * 1.2, height: slotSize * 1.2)
                glow.position = CGPoint(x: slotSize / 2, y: slotSize / 2)
                for layer in [slot, hop, lift, glow, holder, icon, shade, shadeMask, badge, dot] { layer.contentsScale = look.scale }
            }
        }
        // The icon, drawn at twice its size so magnification and dragging stay sharp. A site's icon is drawn
        // again when it arrives.
        let key = web ? "\(item.id)#\(Sites.shared.icon(item.id) != nil)" : item.id
        if drawn?.image != key || drawn?.size != size || drawn?.scale != look.scale {
            drawn = (key, size, look.scale)
            let image = Tile.image(Apps.icon(item.id), points: size * 2, scale: look.scale)
            still {
                icon.contents = image
                shadeMask.contents = image
            }
        }
        // The glow: only the app in front, softly, in its own color.
        let color = look.glow ? AppColor.of(item.id) : PetalApp.shared.accent
        let glows = look.glow && item.running
        if glows == glow.isHidden || glowColor != color {
            glowColor = color
            still {
                glow.isHidden = !glows
                glow.colors = [color.withAlphaComponent(0.45).cgColor, color.withAlphaComponent(0.12).cgColor, NSColor.clear.cgColor]
            }
        }
        setOpacity(glow, Float((item.active ? 0.6 : 0) * state.glowStrength), duration: old == nil ? 0 : 0.2)
        // Idle (pinned and not running) apps dim; one under a dragged file dims more.
        let idle: CGFloat = item.running || !item.pinned || web ? 1 : state.idle
        setOpacity(holder, Float(idle * (fileOver ? 0.6 : 1)), duration: old == nil ? 0 : 0.15)
        // Launching: the icon breathes between full and idle until its window shows.
        let launching = state.launching.contains(item.id)
        if launching != pulsing {
            pulsing = launching
            if launching {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = state.idle
                pulse.duration = 0.5
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                icon.add(pulse, forKey: "pulse")
            } else {
                icon.removeAnimation(forKey: "pulse")
            }
        }
        // The badge, at the icon's top corner.
        let text = state.showBadges ? state.badges[item.id] : nil
        if text != badgeText || drawn?.size != size {
            badgeText = text
            still {
                if let text, let image = Tile.badgeImage(text, icon: size, scale: look.scale) {
                    badge.contents = image.image
                    badge.bounds = CGRect(origin: .zero, size: image.size)
                    badge.anchorPoint = CGPoint(x: 1, y: 1)
                    badge.position = CGPoint(x: slotSize / 2 + size / 2 + size * 0.12, y: slotSize / 2 + size / 2 + size * 0.12)
                    badge.isHidden = false
                } else {
                    badge.isHidden = true
                }
            }
        }
        // The dot: one window, or several; bright when it's on this Desktop or in front.
        let dragged = state.dragging == item.id
        let dotSize = max(4, size * 0.13)
        let long = dotSize * (item.windows > 1 ? 2.6 : 1)
        // With a glow the slot is the app's whole box; without it, the icon is, as the SwiftUI slot lays it out.
        let edge = glows ? 1 : (slotSize - size) / 2 + 1
        let vertical = look.position != "bottom"
        let dotBounds = CGRect(x: 0, y: 0, width: vertical ? dotSize : long, height: vertical ? long : dotSize)
        let dotPosition: CGPoint = switch look.position {
        case "left": CGPoint(x: edge + dotSize / 2, y: slotSize / 2)
        case "right": CGPoint(x: slotSize - edge - dotSize / 2, y: slotSize / 2)
        default: CGPoint(x: slotSize / 2, y: edge + dotSize / 2)
        }
        let animateDot = old != nil && old?.windows != item.windows && dot.opacity > 0
        let fromBounds = dot.presentation()?.bounds ?? dot.bounds
        if dot.bounds != dotBounds || dot.position != dotPosition || dotColor != color {
            dotColor = color
            still {
                dot.backgroundColor = color.cgColor
                dot.cornerRadius = dotSize / 2
                dot.bounds = dotBounds
                dot.position = dotPosition
            }
        }
        if animateDot { ease(dot, "bounds", to: NSValue(rect: dotBounds), from: NSValue(rect: fromBounds), duration: 0.15) }
        setOpacity(dot, dragged ? 0 : Float(DockRules.dot(running: item.running, here: item.here, active: item.active)),
                   duration: old == nil ? 0 : 0.15)
        // Out of the dock while dragged: faint, since letting go removes it.
        setOpacity(hop, dragged && state.dragOut ? 0.4 : 1, duration: old == nil ? 0 : 0.12)
        // Dragged, or under a file: it grows.
        let grow = dragged || fileOver
        if grow != grown {
            grown = grow
            applyLift(look, duration: 0.15)
        }
    }

    // MARK: Where it is

    func place(_ rect: CGRect, shift: CGFloat, look: AppStripView.Look, animated: Bool, dragged: Bool) {
        base = rect
        let vertical = look.position != "bottom"
        let target = CGPoint(x: rect.midX + (vertical ? 0 : shift), y: rect.midY - (vertical ? shift : 0))
        guard slot.position != target else { return }
        let from = slot.presentation()?.position ?? slot.position
        slot.position = target
        if animated && !dragged { ease(slot, "position", to: NSValue(point: target), from: NSValue(point: from), duration: 0.22) }
        else { slot.removeAnimation(forKey: "position") }
    }

    /// New in the row: it grows in from 70 %.
    func appear() {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.7
        grow.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.22
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        hop.add(group, forKey: "appear")
    }

    /// Gone from the row: it shrinks to 70 % and fades, then goes.
    func leave(animated: Bool) {
        leaving = true
        guard animated else { slot.removeFromSuperlayer(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [slot] in slot.removeFromSuperlayer() }
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.toValue = 0.7
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [shrink, fade]
        group.duration = 0.22
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        hop.add(group, forKey: "leave")
        CATransaction.commit()
    }

    // MARK: Moving parts

    /// Icons grow away from the screen's edge: the point they grow from, relative to the slot's centre.
    private static func anchor(_ position: String, _ size: CGFloat) -> CGPoint {
        switch position {
        case "left": CGPoint(x: -size / 2, y: 0)
        case "right": CGPoint(x: size / 2, y: 0)
        default: CGPoint(x: 0, y: -size / 2)
        }
    }

    private static func scale(_ s: CGFloat, about point: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -point.x, y: -point.y).scaledBy(x: 1, y: 1)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: point.x, y: point.y))
    }

    func setLift(_ amount: CGFloat, look: AppStripView.Look) {
        guard amount != liftAmount else { return }
        liftAmount = amount
        applyLift(look, duration: 0.14)
    }

    /// Hover lift (it grows from the edge and rises) and growing while dragged or under a file.
    private func applyLift(_ look: AppStripView.Look, duration: Double) {
        let anchor = Self.anchor(look.position, look.slot)
        var t = CGAffineTransform(scaleX: grown ? 1.18 : 1, y: grown ? 1.18 : 1)
        t = t.concatenating(Self.scale(1 + liftAmount, about: anchor))
        t = t.concatenating(AppStripView.inward(look.position, look.icon * liftAmount * 1.2))
        setTransform(lift, CATransform3DMakeAffineTransform(t), duration: duration)
    }

    func magnify(scale: CGFloat, shift: CGFloat, look: AppStripView.Look) {
        guard magnification.scale != scale || magnification.shift != shift else { return }
        magnification = (scale, shift)
        let vertical = look.position != "bottom"
        let t = Self.scale(scale, about: Self.anchor(look.position, look.slot))
            .concatenating(CGAffineTransform(translationX: vertical ? 0 : shift, y: vertical ? -shift : 0))
        slot.transform = CATransform3DMakeAffineTransform(t)
    }

    func press(_ on: Bool) {
        let scale: CGFloat = on ? 0.92 : 1
        let duration = on ? 0.06 : 0.14
        setTransform(holder, CATransform3DMakeScale(scale, scale, 1), duration: duration)
        setOpacity(shade, on ? 0.22 : 0, duration: duration)
    }

    /// The bounce: up half an icon, then a spring back.
    func bounce(_ look: AppStripView.Look) {
        let height = look.icon * 0.5
        let key: String
        let sign: CGFloat
        switch look.position {
        case "left": key = "transform.translation.x"; sign = 1
        case "right": key = "transform.translation.x"; sign = -1
        default: key = "transform.translation.y"; sign = 1
        }
        let up = CABasicAnimation(keyPath: key)
        up.fromValue = 0
        up.toValue = height * sign
        up.duration = 0.22
        up.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let back = CASpringAnimation(keyPath: key)
        back.fromValue = height * sign
        back.toValue = 0
        back.mass = 1
        back.stiffness = 260
        back.damping = 9
        back.beginTime = 0.22
        back.duration = back.settlingDuration
        up.isAdditive = true
        back.isAdditive = true
        let group = CAAnimationGroup()
        group.animations = [up, back]
        group.duration = 0.22 + back.settlingDuration
        hop.add(group, forKey: "bounce")
    }

    // MARK: Images

    private static var images: [String: CGImage] = [:]

    /// An image as pixels for a layer, `points` across.
    static func image(_ image: NSImage, points: CGFloat, scale: CGFloat) -> CGImage? {
        var rect = CGRect(origin: .zero, size: CGSize(width: points * scale, height: points * scale))
        return image.cgImage(forProposedRect: &rect, context: nil, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    /// The badge as an image: its count in white on Petal's pink capsule with a white edge.
    static func badgeImage(_ text: String, icon: CGFloat, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let height = icon * 0.42
        let label = (Int(text) ?? 0) > 99 ? "99+" : text
        let font = NSFont.systemFont(ofSize: height * 0.62, weight: .semibold)
        let words = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white])
        let width = max(height, ceil(words.size().width) + 8)
        let size = CGSize(width: width, height: height)
        let key = "badge:\(label):\(height):\(scale)"
        if let cached = images[key] { return (cached, size) }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((width * scale).rounded(.up)),
                                         pixelsHigh: Int((height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let capsule = NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: height / 2, yRadius: height / 2)
        NSColor(red: 1, green: 0.23, blue: 0.5, alpha: 1).setFill()
        capsule.fill()
        let edge = NSBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75),
                                xRadius: height / 2 - 0.75, yRadius: height / 2 - 0.75)
        edge.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.85).setStroke()
        edge.stroke()
        let textSize = words.size()
        words.draw(at: CGPoint(x: (width - textSize.width) / 2, y: (height - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = rep.cgImage else { return nil }
        images[key] = image
        return (image, size)
    }
}

/// A layer delegate that turns off implicit animations.
final class NoActions: NSObject, CALayerDelegate {
    static let shared = NoActions()
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}
