import CoreGraphics
import Foundation

// Checks MagnifyRules.swift: magnification's maths (how much each icon grows, where it moves, the glass, where the
// pointer counts as at the dock). Run with macos/checks/run.sh.
@main
struct MagnifyRulesCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    typealias R = MagnifyRules

    /// A dock as the magnifier sees it: the AI button, a separator (it only makes room), `apps` apps and "+", each
    /// `slot` long, from `start`.
    static func dock(apps: Int, slot: CGFloat = 44, start: CGFloat = 100) -> (slots: [String: R.Slot], order: [String]) {
        var slots: [String: R.Slot] = [:]
        var order: [String] = []
        var at = start
        func add(_ id: String, _ length: CGFloat, scales: Bool = true) {
            slots[id] = R.Slot(low: at, high: at + length, scales: scales)
            order.append(id)
            at += length
        }
        add("claude", slot)
        add("separator", 17, scales: false)
        for index in 0..<apps { add("app\(index)", slot) }
        add("add", slot)
        return (slots, order)
    }

    static func main() {
        let slot: CGFloat = 44
        let (slots, _) = dock(apps: 24, slot: slot)
        let close: (CGFloat, CGFloat) -> Bool = { abs($0 - $1) < 0.01 }

        for amount in [0.1, 0.5, 1] as [CGFloat] {
            // The pointer at an app's middle: it grows by the amount set, and stays where it is.
            let middle = slots["app12"]!.middle
            let extra = R.growth(slots, pointer: middle, grow: amount, slot: slot)
            let effect = R.effect("app12", slots, extra, pointer: middle)
            expect(close(effect.scale, 1 + amount), "the icon under the pointer grows by the amount set (\(amount))", "\(effect.scale)")
            expect(close(effect.shift, 0), "the icon under the pointer stays under it (\(amount))", "\(effect.shift)")
            // Its neighbours grow less the further they are, and none past the reach.
            let scales = (8...16).map { R.effect("app\($0)", slots, extra, pointer: middle).scale }
            expect(zip(scales.prefix(5), scales.prefix(5).dropFirst()).allSatisfy { $0 <= $1 + 0.0001 }
                   && zip(scales.suffix(5), scales.suffix(5).dropFirst()).allSatisfy { $0 >= $1 - 0.0001 },
                   "icons grow less the further they are from the pointer (\(amount))", "\(scales)")
            expect(close(R.effect("app9", slots, extra, pointer: middle).scale, 1) && close(R.effect("app15", slots, extra, pointer: middle).scale, 1),
                   "three slots away nothing grows (\(amount))")
            expect(R.effect("separator", slots, extra, pointer: middle).scale == 1, "a separator only makes room (\(amount))")
            // Before the pointer they move back, after it on; far ones by all the growth on their side.
            let total = extra.values.reduce(0, +)
            let first = R.effect("claude", slots, extra, pointer: middle).shift, last = R.effect("add", slots, extra, pointer: middle).shift
            expect(close(first, -total / 2) && close(last, total / 2), "the ends move out by the growth on their side (\(amount))", "\(first) \(last) of \(total)")
        }

        // Anywhere along the dock, at any strength, with any number of apps and any icon size: the drawn icons keep
        // their order and never overlap or part; the icon drawn under the pointer is the one whose slot the pointer is
        // in (so a click opens what's under it); the glass's ends move as far as the first and last icons; and no side
        // grows past the room the panel keeps.
        var worst = (overlap: CGFloat(0), room: CGFloat(0), glass: CGFloat(0))
        var wrongUnder: [String] = []
        var cases = 0
        for apps in [0, 1, 2, 5, 24, 60] {
            for slotSize in [16, 30, 44, 80, 128] as [CGFloat] {
                let (slots, order) = dock(apps: apps, slot: slotSize, start: 37)
                let low = slots["claude"]!.low, high = slots["add"]!.high
                for amount in [0.1, 0.25, 0.5, 0.75, 1] as [CGFloat] {
                    for strength in [0.05, 0.3, 0.7, 1] as [CGFloat] {
                        var pointer = low - slotSize
                        while pointer <= high + slotSize {
                            cases += 1
                            let extra = R.growth(slots, pointer: pointer, grow: amount * strength, slot: slotSize)
                            let drawn = order.map { R.drawn($0, slots, extra, pointer: pointer)! }
                            for (a, b) in zip(drawn, drawn.dropFirst()) { worst.overlap = max(worst.overlap, abs(b.low - a.high)) }
                            if let inSlot = order.first(where: { slots[$0]!.low <= pointer && pointer < slots[$0]!.high }),
                               let index = order.firstIndex(of: inSlot), !(drawn[index].low - 0.01 <= pointer && pointer <= drawn[index].high + 0.01) {
                                wrongUnder.append("\(apps) apps, \(slotSize) pt, at \(pointer)")
                            }
                            let room = R.room(slot: slotSize, amount: amount)
                            worst.room = max(worst.room, low - drawn.first!.low - room, drawn.last!.high - high - room)
                            let stretch = R.stretch(slots, extra, pointer: pointer, length: high - low)
                            let length = (high - low) * stretch.scale
                            let glassLow = low + (high - low) * stretch.anchor - length * stretch.anchor
                            worst.glass = max(worst.glass, abs(glassLow - drawn.first!.low), abs(glassLow + length - drawn.last!.high))
                            pointer += slotSize / 11.3
                        }
                    }
                }
            }
        }
        expect(worst.overlap < 0.01, "magnified icons never overlap or part (\(cases) cases)", "\(worst.overlap)")
        expect(wrongUnder.isEmpty, "the icon drawn under the pointer is the one its slot is", "\(wrongUnder.prefix(5))")
        expect(worst.room <= 0.001, "nothing grows past the room the panel keeps", "\(worst.room)")
        expect(worst.glass < 0.01, "the glass's ends move with the first and last icons", "\(worst.glass)")
        let low = slots["claude"]!.low, high = slots["add"]!.high

        // Nothing grows with the pointer far away or the strength at nothing.
        let far = R.growth(slots, pointer: high + 500, grow: 0.5, slot: slot)
        expect(far.values.allSatisfy { $0 == 0 }, "nothing grows with the pointer away from the dock")
        expect(R.stretch(slots, far, pointer: high + 500, length: high - low) == (1, 0.5), "the glass rests with nothing grown")
        let none = R.growth(slots, pointer: slots["app3"]!.middle, grow: 0, slot: slot)
        expect(R.effect("app3", slots, none, pointer: slots["app3"]!.middle) == (1, 0), "at no strength nothing moves")

        // The zone the pointer counts as at the dock: the glass, and once grown, the grown icons away from the edge.
        let glass = CGRect(x: 100, y: 30, width: 1000, height: 54)
        let rest = R.zone(glass: glass, position: "bottom", slot: 54, amount: 0.5, strength: 0)
        let grown = R.zone(glass: glass, position: "bottom", slot: 54, amount: 0.5, strength: 1)
        expect(rest.contains(CGPoint(x: 500, y: 31)) && !rest.contains(CGPoint(x: 500, y: 10)), "at rest, the glass is the zone")
        expect(grown.contains(CGPoint(x: 500, y: 6)) && grown.maxY == rest.maxY, "grown, it reaches over the grown icons, upward, not past the screen's edge")
        let left = R.zone(glass: CGRect(x: 2, y: 100, width: 54, height: 900), position: "left", slot: 54, amount: 0.5, strength: 1)
        let right = R.zone(glass: CGRect(x: 30, y: 100, width: 54, height: 900), position: "right", slot: 54, amount: 0.5, strength: 1)
        expect(left.contains(CGPoint(x: 80, y: 500)) && left.minX == 0, "on the left, it reaches rightward")
        expect(right.contains(CGPoint(x: 4, y: 500)) && right.maxX == 86, "on the right, it reaches leftward")

        print("magnification: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
