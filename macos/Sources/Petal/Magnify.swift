import AppKit
import Observation
import QuartzCore
import SwiftUI

/// Magnification (`magnification`, `magnificationAmount`): icons grow under the pointer and their neighbours ease
/// aside, like macOS's Dock. Made to stay smooth at 120 Hz: nothing is laid out again while it runs. Every slot
/// keeps its place in the layout and only moves and grows by transforms; the glass stretches by a transform too; and
/// the panel is already big enough for the largest icons, so it never resizes.
///
/// The spread is anchored at the pointer: icons before it move back, icons after it move on, and the icon under the
/// pointer stays under it. So the icon you see under the pointer is always the one you click, even though each
/// slot's mouse area stays where the layout put it.
@MainActor @Observable
final class Magnifier {
    /// Where the pointer is along the dock (panel coordinates, top-left origin), and how far magnified (0–1).
    struct State: Equatable { var pointer: CGFloat = 0; var strength: CGFloat = 0 }
    private(set) var state = State()
    /// Where the easing is, every frame: `state` follows it only by steps big enough to draw.
    @ObservationIgnored private var live = State()

    /// The slots' frames in the layout (panel coordinates, top-left origin), before any transform: growing ones,
    /// and ones that only make room.
    @ObservationIgnored private(set) var frames: [String: (rect: CGRect, scales: Bool)] = [:]
    /// Each frame as every copy of its slot registered it (`owner`: a SwiftUI slot's own token, nil for the layer
    /// strip), the latest first: when the setting changes the dock's row is made anew, and the copy going away
    /// mustn't take the frame of the one replacing it, whichever of them registers or goes first.
    @ObservationIgnored private var copies: [String: [(owner: UUID?, rect: CGRect, scales: Bool)]] = [:]
    @ObservationIgnored var glass: CGRect = .zero
    @ObservationIgnored private var slots: [String: MagnifyRules.Slot] = [:]
    @ObservationIgnored private var extra: [String: CGFloat] = [:]
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var target: LinkTarget?
    @ObservationIgnored private var lastFrame: CFTimeInterval = 0
    @ObservationIgnored weak var dock: ScreenDock?

    var config: Config { PetalApp.shared.config }
    var on: Bool { Self.enabled }
    var amount: CGFloat { Self.amount }

    /// `Petal --snapshot` draws a magnified dock whatever the setting.
    static var forced = false
    static var enabled: Bool { forced || PetalApp.shared.config.bool("magnification") }
    static var amount: CGFloat { min(1, max(0.1, PetalApp.shared.config.number("magnificationAmount"))) }

    /// Draws the dock as if the pointer were at `pointer` (for snapshots).
    func preview(pointer: CGFloat) { publish(State(pointer: pointer, strength: 1)) }
    var vertical: Bool { config.position != "bottom" }

    /// The most the dock can grow along its length, to one side: the room the panel keeps for it.
    static func room(slot: CGFloat, amount: CGFloat) -> CGFloat { MagnifyRules.room(slot: slot, amount: amount) }

    func register(_ id: String, _ rect: CGRect, scales: Bool, owner: UUID?) {
        var list = copies[id, default: []].filter { $0.owner != owner }
        list.insert((owner, rect, scales), at: 0)
        copies[id] = list
        frames[id] = (rect, scales)
    }

    /// Takes the frame `owner` registered for a slot away; another copy's stays.
    func unregister(_ id: String, owner: UUID?) {
        guard let list = copies[id] else { return }
        let rest = list.filter { $0.owner != owner }
        copies[id] = rest.isEmpty ? nil : rest
        frames[id] = rest.first.map { ($0.rect, $0.scales) }
    }

    // MARK: Following the pointer

    /// The pointer may be at the dock: follow it, once a frame, until it has left and the icons have settled.
    func wake() {
        guard on, link == nil, let panel = dock?.panel, let view = panel.contentView else { return }
        let target = LinkTarget { [weak self] link in MainActor.assumeIsolated { self?.step(link) } }
        let link = view.displayLink(target: target, selector: #selector(LinkTarget.fire(_:)))
        link.add(to: .main, forMode: .common)
        self.target = target
        self.link = link
        lastFrame = 0
    }

    private func sleep() {
        link?.invalidate()
        link = nil
        target = nil
    }

    private func step(_ link: CADisplayLink) {
        let dt = lastFrame == 0 ? 1.0 / 120 : min(0.05, link.timestamp - lastFrame)
        lastFrame = link.timestamp
        advance(mouse: NSEvent.mouseLocation, dt: dt)
    }

    /// One frame: the pointer at `mouse` (screen coordinates), `dt` seconds after the last. The display link gives
    /// it the real pointer; `Petal --bench-dock` a made-up one.
    func advance(mouse: CGPoint, dt: Double) {
        guard let dock, let panel = dock.panel, on, glass != .zero else {
            settle()
            return
        }
        // Coming from rest: where the strip's apps are now (its view may have moved with the dock since it last
        // said), before anything grows.
        if live.strength == 0 { dock.strip?.registerFrames() }
        let point = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        let along = vertical ? point.y : point.x
        // In while over the glass; staying in while over the grown icons too.
        let zone = MagnifyRules.zone(glass: glass, position: config.position, slot: vertical ? glass.width : glass.height,
                                     amount: amount, strength: live.strength)
        let inside = zone.contains(point) && dock.dragging == nil && !panel.tucked && panel.alphaValue > 0.5
        // Critically damped easing toward where things should be: quick on the pointer, a little softer in and out.
        let follow = 1 - exp(-dt / 0.03), fade = 1 - exp(-dt / (inside ? 0.07 : 0.09))
        var next = live
        next.strength += ((inside ? 1 : 0) - next.strength) * fade
        if inside {
            next.pointer = live.strength < 0.02 ? along : next.pointer + (along - next.pointer) * follow
        }
        // (Eased from `live`, not from what was last drawn: the last steps out are too small to draw, and easing
        // from `state` stopped there, never settling, with the display link running on.)
        live = next
        if !inside && next.strength < 0.004 {
            settle()
            return
        }
        if abs(next.pointer - state.pointer) > 0.01 || abs(next.strength - state.strength) > 0.0005 { publish(next) }
    }

    private func settle() {
        sleep()
        live.strength = 0
        if state.strength != 0 { publish(State(pointer: state.pointer, strength: 0)) }
    }

    private func publish(_ next: State) {
        let vertical = self.vertical
        slots = frames.mapValues { frame in
            MagnifyRules.Slot(low: vertical ? frame.rect.minY : frame.rect.minX, high: vertical ? frame.rect.maxY : frame.rect.maxX,
                              scales: frame.scales)
        }
        let slot = slots.values.first(where: \.scales)?.length ?? (vertical ? glass.width : glass.height)
        extra = MagnifyRules.growth(slots, pointer: next.pointer, grow: amount * next.strength, slot: slot)
        state = next
        live = next
        dock?.strip?.magnify()   // the layer strip moves its icons itself
    }

    // MARK: What each slot does

    /// How much a slot grows, and how far it moves along the dock.
    func effect(_ id: String) -> (scale: CGFloat, shift: CGFloat) {
        guard state.strength > 0 else { return (1, 0) }
        return MagnifyRules.effect(id, slots, extra, pointer: state.pointer)
    }

    /// The glass grows to hold the spread icons: how much, and from where.
    var glassStretch: (scale: CGFloat, anchor: CGFloat) {
        guard state.strength > 0 else { return (1, 0.5) }
        return MagnifyRules.stretch(slots, extra, pointer: state.pointer, length: vertical ? glass.height : glass.width)
    }

    /// Icons grow away from the screen's edge.
    var anchor: UnitPoint {
        switch config.position { case "left": .leading; case "right": .trailing; default: .bottom }
    }
}

/// A display link's target (it needs an Objective-C object).
final class LinkTarget: NSObject {
    let action: (CADisplayLink) -> Void
    init(_ action: @escaping (CADisplayLink) -> Void) { self.action = action }
    @objc func fire(_ link: CADisplayLink) { action(link) }
}

/// A slot that grows (or only makes room) under the pointer. Only transforms: its layout never changes.
struct Magnified: ViewModifier {
    let dock: ScreenDock
    let id: String
    var scales = true

    func body(content: Content) -> some View {
        if dock.magnifier.on {
            content.modifier(Growing(magnifier: dock.magnifier, id: id, scales: scales))
        } else {
            content   // with magnification off a slot costs nothing more
        }
    }

    private struct Growing: ViewModifier {
        let magnifier: Magnifier
        let id: String
        let scales: Bool
        /// This copy of the slot, for registering its frame (see `Magnifier.register`).
        @State private var token = UUID()

        func body(content: Content) -> some View {
            let effect = magnifier.effect(id)
            let vertical = magnifier.vertical
            content
                .scaleEffect(effect.scale, anchor: magnifier.anchor)
                .offset(x: vertical ? 0 : effect.shift, y: vertical ? effect.shift : 0)
                // Measured outside its own transform: where the layout put the slot, not where it's drawn grown
                // (measured inside, each frame's growth fed the next, and the slot never grew).
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [token] in
                    magnifier.register(id, $0, scales: scales, owner: token)
                }
                .onDisappear { [token] in if !Magnifier.forced { magnifier.unregister(id, owner: token) } }   // a snapshot's views go as soon as drawn
        }
    }
}

/// The dock's glass: with magnification on, it's drawn behind the icons and stretched to hold them as they spread.
struct DockGlass: ViewModifier {
    let dock: ScreenDock
    let glass: Glass
    let radius: CGFloat

    func body(content: Content) -> some View {
        let magnifier = dock.magnifier
        if magnifier.on {
            let stretch = magnifier.glassStretch
            let vertical = magnifier.vertical
            content
                .background {
                    Color.clear
                        .glassEffect(glass, in: .rect(cornerRadius: radius))
                        .scaleEffect(x: vertical ? 1 : stretch.scale, y: vertical ? stretch.scale : 1,
                                     anchor: vertical ? UnitPoint(x: 0.5, y: stretch.anchor) : UnitPoint(x: stretch.anchor, y: 0.5))
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { magnifier.glass = $0 }
        } else {
            content.glassEffect(glass, in: .rect(cornerRadius: radius))
        }
    }
}

extension View {
    func magnified(_ dock: ScreenDock, _ id: String, scales: Bool = true) -> some View {
        modifier(Magnified(dock: dock, id: id, scales: scales))
    }

    /// A slot's mouse; with magnification on it reaches over the slot's grown icon too (clicks only arrive where the
    /// icon is drawn, since the panel is see-through elsewhere).
    func slotMouse(_ mouse: SlotMouse) -> some View { modifier(SlotMouseArea(mouse: mouse)) }
}

struct SlotMouseArea: ViewModifier {
    @Environment(\.snapshotting) private var snapshotting
    let mouse: SlotMouse

    func body(content: Content) -> some View {
        let config = PetalApp.shared.config
        let reach = Magnifier.enabled ? max(16, config.number("iconSize")) * Magnifier.amount * 1.3 : 0
        let edge: Edge.Set = switch config.position { case "left": .trailing; case "right": .leading; default: .top }
        if snapshotting { content } else { content.overlay(mouse.padding(edge, -reach)) }
    }
}
