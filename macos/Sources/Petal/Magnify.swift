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

    /// The slots' frames in the layout, before any transform: growing ones, and ones that only make room.
    @ObservationIgnored var frames: [String: (rect: CGRect, scales: Bool)] = [:]
    @ObservationIgnored var glass: CGRect = .zero
    @ObservationIgnored private var spread: [(low: CGFloat, high: CGFloat, extra: CGFloat)] = []
    @ObservationIgnored private var anchorSpread: CGFloat = 0
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var target: LinkTarget?
    @ObservationIgnored private var lastFrame: CFTimeInterval = 0
    @ObservationIgnored weak var dock: ScreenDock?

    /// How far an icon's growth reaches, in slots either side of the pointer.
    static let reach: CGFloat = 2.5

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
    static func room(slot: CGFloat, amount: CGFloat) -> CGFloat { slot * amount * (reach + 0.1) }

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
        guard let dock, let panel = dock.panel, on, glass != .zero else {
            settle()
            return
        }
        let dt = lastFrame == 0 ? 1.0 / 120 : min(0.05, link.timestamp - lastFrame)
        lastFrame = link.timestamp
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        let along = vertical ? point.y : point.x
        // In while over the glass; staying in while over the grown icons too.
        let slot = vertical ? glass.width : glass.height
        let grown = state.strength > 0.3 ? slot * amount * state.strength + 4 : 2
        var zone = glass.insetBy(dx: -2, dy: -2)
        switch config.position {
        case "left": zone.size.width += grown
        case "right": zone.origin.x -= grown; zone.size.width += grown
        default: zone.origin.y -= grown; zone.size.height += grown
        }
        let inside = zone.contains(point) && dock.dragging == nil && !panel.tucked && panel.alphaValue > 0.5
        // Critically damped easing toward where things should be: quick on the pointer, a little softer in and out.
        let follow = 1 - exp(-dt / 0.03), fade = 1 - exp(-dt / (inside ? 0.07 : 0.09))
        var next = state
        next.strength += ((inside ? 1 : 0) - next.strength) * fade
        if inside {
            next.pointer = state.strength < 0.02 ? along : next.pointer + (along - next.pointer) * follow
        }
        if !inside && next.strength < 0.004 {
            settle()
            return
        }
        if abs(next.pointer - state.pointer) > 0.01 || abs(next.strength - state.strength) > 0.0005 { publish(next) }
    }

    private func settle() {
        sleep()
        if state.strength != 0 { publish(State(pointer: state.pointer, strength: 0)) }
    }

    private func publish(_ next: State) {
        let a = amount * next.strength
        let slot = frames.values.first(where: \.scales).map { vertical ? $0.rect.height : $0.rect.width } ?? (vertical ? glass.width : glass.height)
        let width = Self.reach * slot
        spread = frames.values.filter(\.scales).map { frame in
            let low = vertical ? frame.rect.minY : frame.rect.minX, high = vertical ? frame.rect.maxY : frame.rect.maxX
            let distance = abs(next.pointer - (low + high) / 2)
            let weight = distance < width ? pow(cos(.pi * distance / (2 * width)), 2) : 0
            return (low, high, (high - low) * a * weight)
        }
        anchorSpread = Self.spread(at: next.pointer, spread)
        state = next
    }

    /// How much growth lies before `position` along the dock.
    private static func spread(at position: CGFloat, _ spread: [(low: CGFloat, high: CGFloat, extra: CGFloat)]) -> CGFloat {
        spread.reduce(0) { total, slot in
            total + slot.extra * min(1, max(0, (position - slot.low) / max(1, slot.high - slot.low)))
        }
    }

    // MARK: What each slot does

    /// How much a slot grows, and how far it moves along the dock.
    func effect(_ id: String) -> (scale: CGFloat, shift: CGFloat) {
        guard state.strength > 0, let frame = frames[id] else { return (1, 0) }
        let low = vertical ? frame.rect.minY : frame.rect.minX, high = vertical ? frame.rect.maxY : frame.rect.maxX
        let shift = Self.spread(at: (low + high) / 2, spread) - anchorSpread
        guard frame.scales, let mine = spread.first(where: { $0.low == low && $0.high == high }) else { return (1, shift) }
        return (1 + mine.extra / max(1, high - low), shift)
    }

    /// The glass grows to hold the spread icons: how much, and from where.
    var glassStretch: (scale: CGFloat, anchor: CGFloat) {
        let total = spread.reduce(0) { $0 + $1.extra }
        let length = vertical ? glass.height : glass.width
        guard state.strength > 0, total > 0.01, length > 0 else { return (1, 0.5) }
        return ((length + total) / length, anchorSpread / total)
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
        let magnifier = dock.magnifier
        if magnifier.on {
            let effect = magnifier.effect(id)
            let vertical = magnifier.vertical
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { magnifier.frames[id] = ($0, scales) }
                .onDisappear { if !Magnifier.forced { magnifier.frames[id] = nil } }   // a snapshot's views go as soon as drawn
                .scaleEffect(effect.scale, anchor: magnifier.anchor)
                .offset(x: vertical ? 0 : effect.shift, y: vertical ? effect.shift : 0)
        } else {
            content
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
