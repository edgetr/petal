import CoreGraphics
import Foundation

/// Magnification's maths, pure (`Magnifier` follows the pointer with them; `macos/checks/run.sh` checks them). Along
/// the dock only: a slot is its span along the dock in the layout, before any transform; the pointer is a position
/// along the same line.
enum MagnifyRules {
    /// How far an icon's growth reaches, in slots either side of the pointer.
    static let reach: CGFloat = 2.5

    /// A slot's span along the dock, and whether it grows (a separator only makes room).
    struct Slot: Equatable {
        var low: CGFloat
        var high: CGFloat
        var scales = true
        var length: CGFloat { high - low }
        var middle: CGFloat { (low + high) / 2 }
    }

    /// How much each slot grows along the dock with the pointer at `pointer`: `grow` is how far magnified (the
    /// setting's amount times how far in, 0 to 1), `slot` one slot's length. The icon under the pointer grows by
    /// `grow` of its length, its neighbours less the further they are, none past `reach` slots.
    static func growth(_ slots: [String: Slot], pointer: CGFloat, grow: CGFloat, slot: CGFloat) -> [String: CGFloat] {
        let width = reach * slot
        var extra: [String: CGFloat] = [:]
        for (id, s) in slots where s.scales {
            let distance = abs(pointer - s.middle)
            let weight = distance < width ? pow(cos(.pi * distance / (2 * width)), 2) : 0
            extra[id] = s.length * grow * weight
        }
        return extra
    }

    /// How much growth lies before `position` along the dock (a slot's own counts in part, up to where `position`
    /// is in it).
    static func before(_ position: CGFloat, _ slots: [String: Slot], _ extra: [String: CGFloat]) -> CGFloat {
        extra.reduce(0) { total, item in
            guard let s = slots[item.key] else { return total }
            return total + item.value * min(1, max(0, (position - s.low) / max(1, s.length)))
        }
    }

    /// How much a slot grows (its scale) and how far it moves along the dock, with the spread anchored at
    /// `pointer`: slots before it move back, slots after it move on, and the point under the pointer stays there.
    static func effect(_ id: String, _ slots: [String: Slot], _ extra: [String: CGFloat], pointer: CGFloat) -> (scale: CGFloat, shift: CGFloat) {
        guard let s = slots[id] else { return (1, 0) }
        let shift = before(s.middle, slots, extra) - before(pointer, slots, extra)
        return (1 + (extra[id] ?? 0) / max(1, s.length), shift)
    }

    /// Where a slot is drawn along the dock: its span, grown about its middle and moved by `effect`.
    static func drawn(_ id: String, _ slots: [String: Slot], _ extra: [String: CGFloat], pointer: CGFloat) -> (low: CGFloat, high: CGFloat)? {
        guard let s = slots[id] else { return nil }
        let effect = effect(id, slots, extra, pointer: pointer)
        let middle = s.middle + effect.shift, half = s.length * effect.scale / 2
        return (middle - half, middle + half)
    }

    /// The most the dock can grow along its length, to one side: the room the panel keeps for it.
    static func room(slot: CGFloat, amount: CGFloat) -> CGFloat { slot * amount * (reach + 0.1) }

    /// The glass grows to hold the spread icons: its scale along the dock, and the point it grows from (0 to 1 along
    /// its length), so its ends move as far as the first and last icons do.
    static func stretch(_ slots: [String: Slot], _ extra: [String: CGFloat], pointer: CGFloat, length: CGFloat) -> (scale: CGFloat, anchor: CGFloat) {
        let total = extra.values.reduce(0, +)
        guard total > 0.01, length > 0 else { return (1, 0.5) }
        return ((length + total) / length, before(pointer, slots, extra) / total)
    }

    /// Where the pointer counts as at the dock (panel coordinates, top-left origin): over the glass, and, once
    /// grown, over the grown icons that reach past it, away from the screen's edge.
    static func zone(glass: CGRect, position: String, slot: CGFloat, amount: CGFloat, strength: CGFloat) -> CGRect {
        let reach = strength > 0.3 ? slot * amount * strength + 4 : 2
        var zone = glass.insetBy(dx: -2, dy: -2)
        switch position {
        case "left": zone.size.width += reach
        case "right": zone.origin.x -= reach; zone.size.width += reach
        default: zone.origin.y -= reach; zone.size.height += reach
        }
        return zone
    }
}
