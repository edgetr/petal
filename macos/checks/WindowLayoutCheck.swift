import CoreGraphics
import Foundation

// Checks WindowLayout.swift: frames in, frames out. Run with macos/checks/run.sh.
@main
struct WindowLayoutCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static func main() {
        tiling()
        neighbours()
        areas()
        parking()
        print(failures == 0 ? "ok: \(passed) checks" : "\(failures) of \(passed + failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func tiling() {
        let area = CGRect(x: 0, y: 25, width: 1600, height: 1000)
        var tree = TileTree()
        expect(TileLayout.frames(tree, in: area, gaps: 8).isEmpty, "empty tree has no frames")

        tree.insert(1)
        var f = TileLayout.frames(tree, in: area, gaps: 8)
        expect(f[1] == CGRect(x: 8, y: 33, width: 1584, height: 984), "one window fills the area less the gaps", "\(f)")

        // A wide area splits side by side; the new window takes the right half.
        tree.insert(2, splitting: 1)
        f = TileLayout.frames(tree, in: area, gaps: 8)
        expect(f[1] == CGRect(x: 8, y: 33, width: 788, height: 984), "first of two on the left", "\(f[1]!)")
        expect(f[2] == CGRect(x: 804, y: 33, width: 788, height: 984), "second of two on the right", "\(f[2]!)")
        expect(f[2]!.minX - f[1]!.maxX == 8, "gap between neighbours")

        // The right half is taller than wide, so splitting it stacks.
        tree.insert(3, splitting: 2)
        f = TileLayout.frames(tree, in: area, gaps: 8)
        expect(f[2]!.minX == f[3]!.minX && f[3]!.minY == f[2]!.maxY + 8, "third stacks under the second", "\(f)")
        expect(f[1]!.height == 984, "the first keeps its column")
        expect(f[3]!.maxY == area.maxY - 8, "gap at the bottom edge")

        // No frame overlaps another, and all are inside the area.
        tree.insert(4, splitting: 3)
        tree.insert(5, splitting: 1)
        f = TileLayout.frames(tree, in: area, gaps: 8)
        expect(f.count == 5, "five windows, five frames")
        let all = Array(f.values)
        for i in all.indices { for j in all.indices where i < j { expect(!all[i].intersects(all[j]), "no overlap", "\(all[i]) \(all[j])") } }
        expect(all.allSatisfy { area.contains($0) }, "all inside the area")

        // Splitting a window that isn't there splits the newest.
        var other = TileTree()
        other.insert(1); other.insert(2, splitting: 99)
        expect(other.windows == [1, 2], "unknown target splits the newest")

        // Removing gives the space back.
        tree.remove(5)
        tree.remove(4)
        f = TileLayout.frames(tree, in: area, gaps: 8)
        expect(f[1] == CGRect(x: 8, y: 33, width: 788, height: 984), "removing restores the first's column", "\(f[1]!)")
        expect(f[3]!.maxY == area.maxY - 8, "removing lets the third grow back")
        tree.remove(1)
        f = TileLayout.frames(tree, in: area, gaps: 8)
        expect(f[2]!.width == 788 && f[3]!.width == 788, "the other two share the area", "\(f)")
        tree.remove(2)
        f = TileLayout.frames(tree, in: area, gaps: 8)
        expect(f[3] == CGRect(x: 8, y: 33, width: 1584, height: 984), "the last one takes the whole area", "\(f)")
        tree.remove(3)
        expect(tree.isEmpty, "empty after removing all")

        // Swapping trades places; rebalancing evens ratios.
        var swap = TileTree(.split(.leaf(1), .split(.leaf(2), .leaf(3), ratio: 0.7), ratio: 0.3))
        let before = TileLayout.frames(swap, in: area, gaps: 0)
        swap.swap(1, 3)
        let after = TileLayout.frames(swap, in: area, gaps: 0)
        expect(after[3] == before[1] && after[1] == before[3] && after[2] == before[2], "swap trades frames")
        swap.rebalance()
        expect(swap == TileTree(.split(.leaf(3), .split(.leaf(2), .leaf(1), ratio: 0.5), ratio: 0.5)), "rebalance evens every split")

        // sync keeps only what's there and adds the rest next to the focus.
        var synced = TileTree()
        synced.sync([10, 11], focus: nil)
        synced.sync([10, 11, 12], focus: 10)
        expect(synced == TileTree(.split(.split(.leaf(10), .leaf(12), ratio: 0.5), .leaf(11), ratio: 0.5)), "sync splits the focus", "\(synced)")
        synced.sync([12], focus: nil)
        expect(synced.windows == [12], "sync drops closed windows")

        // A zero gap tiles edge to edge; frames are whole points even for odd sizes.
        let odd = CGRect(x: 0, y: 0, width: 1001, height: 601)
        var three = TileTree(); three.insert(1); three.insert(2); three.insert(3)
        let g = TileLayout.frames(three, in: odd, gaps: 0)
        expect(g.values.allSatisfy { $0 == $0.integral }, "whole points")
        expect(g[1]!.maxX == g[2]!.minX, "no gap with gaps 0")
    }

    static func neighbours() {
        // 1 | 2
        //   | 3
        let f: [UInt32: CGRect] = [1: CGRect(x: 0, y: 0, width: 100, height: 200),
                                   2: CGRect(x: 108, y: 0, width: 100, height: 96),
                                   3: CGRect(x: 108, y: 104, width: 100, height: 96)]
        expect(TileLayout.neighbor(of: 1, .right, in: f) == 2, "right of 1 is the upper one")
        expect(TileLayout.neighbor(of: 3, .left, in: f) == 1, "left of 3 is 1")
        expect(TileLayout.neighbor(of: 2, .down, in: f) == 3, "down from 2 is 3")
        expect(TileLayout.neighbor(of: 3, .up, in: f) == 2, "up from 3 is 2")
        expect(TileLayout.neighbor(of: 1, .left, in: f) == nil, "nothing left of 1")
        expect(TileLayout.neighbor(of: 2, .right, in: f) == nil, "nothing right of 2")
        expect(TileLayout.window(at: CGPoint(x: 150, y: 150), in: f, except: 1) == 3, "drop point over 3")
        expect(TileLayout.window(at: CGPoint(x: 50, y: 50), in: f, except: 1) == nil, "dropping on itself swaps nothing")
    }

    static func areas() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)            // AppKit, bottom-left origin
        let ax = ScreenArea.toAX(main, mainTop: 982)
        expect(ax == CGRect(x: 0, y: 0, width: 1512, height: 982), "main screen in AX coordinates")
        let above = CGRect(x: 0, y: 982, width: 1920, height: 1080)        // a screen above the main one
        expect(ScreenArea.toAX(above, mainTop: 982).minY == -1080, "a screen above has negative y")

        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let bottom = ScreenArea.usable(visible: visible, screen: screen, position: "bottom", reserve: 70)
        expect(bottom == CGRect(x: 0, y: 33, width: 1512, height: 879), "bottom dock takes its strip", "\(bottom)")
        let left = ScreenArea.usable(visible: visible, screen: screen, position: "left", reserve: 70)
        expect(left == CGRect(x: 70, y: 33, width: 1442, height: 949), "left dock takes its strip", "\(left)")
        let right = ScreenArea.usable(visible: visible, screen: screen, position: "right", reserve: 70)
        expect(right == CGRect(x: 0, y: 33, width: 1442, height: 949), "right dock takes its strip", "\(right)")
        expect(ScreenArea.usable(visible: visible, screen: screen, position: "bottom", reserve: 0) == visible, "auto-hide keeps the whole area")

        let fitted = ScreenArea.fit(CGRect(x: 100, y: 800, width: 600, height: 400), in: bottom)
        expect(fitted == CGRect(x: 100, y: 512, width: 600, height: 400), "a restored frame moves up out of the strip", "\(fitted)")
        let tall = ScreenArea.fit(CGRect(x: 100, y: 0, width: 600, height: 2000), in: bottom)
        expect(tall == CGRect(x: 100, y: 33, width: 600, height: 879), "a too-tall frame is shortened to fit", "\(tall)")
        let inside = CGRect(x: 200, y: 200, width: 300, height: 300)
        expect(ScreenArea.fit(inside, in: bottom) == inside, "a frame inside stays")
    }

    static func parking() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let size = CGSize(width: 800, height: 600)
        let origin = ParkingLayout.parkedOrigin(size: size, screen: main, others: [])
        expect(origin == CGPoint(x: 1511, y: 981), "parked at the bottom-right corner, 1 pt in", "\(origin)")
        let parked = CGRect(origin: origin, size: size)
        let onScreen = parked.intersection(main)
        expect(onScreen.width == 1 && onScreen.height == 1, "one point stays visible", "\(onScreen)")
        expect(ParkingLayout.looksParked(parked, screens: [main]), "a parked frame looks parked")
        expect(!ParkingLayout.looksParked(CGRect(x: 100, y: 100, width: 800, height: 600), screens: [main]), "a normal window doesn't")
        expect(!ParkingLayout.looksParked(CGRect(x: 1400, y: 900, width: 800, height: 600), screens: [main]), "a window half off doesn't")
        expect(!ParkingLayout.looksParked(CGRect(x: -10000, y: -10000, width: 800, height: 600), screens: [main]), "a helper window kept wholly off-screen doesn't")

        // A second screen to the right: park at the bottom-left corner instead, so nothing shows on it.
        let rightScreen = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let o2 = ParkingLayout.parkedOrigin(size: size, screen: main, others: [rightScreen])
        let f2 = CGRect(origin: o2, size: size)
        expect(o2 == CGPoint(x: -799, y: 981), "a screen to the right parks bottom-left", "\(o2)")
        expect(f2.intersection(rightScreen).isNull, "nothing on the other screen")
        expect(ParkingLayout.looksParked(f2, screens: [main, rightScreen]), "bottom-left parked looks parked")
        // On the right screen, with the main one to its left: bottom-right stays fine (below main's bottom it is
        // still clear, since the right screen is taller).
        let o3 = ParkingLayout.parkedOrigin(size: size, screen: rightScreen, others: [main])
        expect(CGRect(origin: o3, size: size).intersection(main).isNull, "parked off the right screen avoids the main one", "\(o3)")

        let area = CGRect(x: 0, y: 33, width: 1512, height: 879)
        let back = ParkingLayout.rescued(parked, in: area)
        expect(area.contains(back) && back.size == size, "a stranded window comes back whole, centred", "\(back)")

        let owners: [UInt32: String] = [1: "work", 2: "work", 3: "social", 4: "social", 5: "design"]
        let plan = ParkingLayout.plan(mode: "social", owners: owners, parked: [3, 5])
        expect(plan.park == [1, 2], "switching to social parks work's windows", "\(plan)")
        expect(plan.restore == [3], "and brings social's parked one back", "\(plan)")
        let same = ParkingLayout.plan(mode: "social", owners: owners, parked: [1, 2, 5])
        expect(same.park.isEmpty && same.restore.isEmpty, "nothing moves when already in place")
    }
}
