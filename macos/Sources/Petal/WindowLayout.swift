import CoreGraphics
import Foundation

// The maths behind tiling (Tiling.swift) and where a window may go on a screen, kept free of AppKit and Accessibility
// so `macos/checks/run.sh` can check it without moving a single window. Every rectangle here is in the window
// server's coordinates, as Accessibility counts them: the origin at the top-left of the main screen, y going down.

// MARK: - Tiling: a dwindle tree

/// A binary tree of windows. Each new window splits the one that had focus; the direction of every split follows the
/// shape of the space it divides (wider than tall: side by side; otherwise one above the other), and is worked out
/// again whenever that space changes shape.
struct TileTree: Equatable {
    indirect enum Node: Equatable {
        case leaf(UInt32)
        /// `ratio` is the first child's share of the space, 0.1…0.9.
        case split(Node, Node, ratio: Double)
    }

    private(set) var root: Node?

    init(_ root: Node? = nil) { self.root = root }

    var windows: [UInt32] { root.map(Self.leaves) ?? [] }
    var isEmpty: Bool { root == nil }
    func contains(_ id: UInt32) -> Bool { windows.contains(id) }

    private static func leaves(_ node: Node) -> [UInt32] {
        switch node {
        case .leaf(let id): [id]
        case .split(let a, let b, _): leaves(a) + leaves(b)
        }
    }

    /// Adds a window by splitting `target` (the window that had focus); with no target, or one not in the tree, the
    /// newest window is split, which is where the layout's spiral ends. The new window takes the second half.
    mutating func insert(_ id: UInt32, splitting target: UInt32? = nil) {
        guard !contains(id) else { return }
        guard let root else { self.root = .leaf(id); return }
        let anchor = target.flatMap { contains($0) ? $0 : nil } ?? windows.last!
        self.root = Self.replace(anchor, in: root) { .split($0, .leaf(id), ratio: 0.5) }
    }

    mutating func remove(_ id: UInt32) {
        guard let root else { return }
        self.root = Self.removing(id, from: root)
    }

    /// Swaps two windows' places.
    mutating func swap(_ a: UInt32, _ b: UInt32) {
        guard a != b, contains(a), contains(b), let root else { return }
        self.root = Self.mapLeaves(root) { $0 == a ? b : $0 == b ? a : $0 }
    }

    /// Every split back to half and half.
    mutating func rebalance() {
        guard let root else { return }
        self.root = Self.balanced(root)
    }

    /// Keeps only `ids` (in any order), adding the new ones by splitting `focus` (or the newest window).
    mutating func sync(_ ids: [UInt32], focus: UInt32?) {
        for id in windows where !ids.contains(id) { remove(id) }
        for id in ids where !contains(id) { insert(id, splitting: focus) }
    }

    private static func replace(_ id: UInt32, in node: Node, with make: (Node) -> Node) -> Node {
        switch node {
        case .leaf(let leaf): leaf == id ? make(node) : node
        case .split(let a, let b, let ratio): .split(replace(id, in: a, with: make), replace(id, in: b, with: make), ratio: ratio)
        }
    }

    private static func removing(_ id: UInt32, from node: Node) -> Node? {
        switch node {
        case .leaf(let leaf):
            return leaf == id ? nil : node
        case .split(let a, let b, let ratio):
            let left = removing(id, from: a), right = removing(id, from: b)
            if let left, let right { return .split(left, right, ratio: ratio) }
            return left ?? right
        }
    }

    private static func mapLeaves(_ node: Node, _ change: (UInt32) -> UInt32) -> Node {
        switch node {
        case .leaf(let id): .leaf(change(id))
        case .split(let a, let b, let ratio): .split(mapLeaves(a, change), mapLeaves(b, change), ratio: ratio)
        }
    }

    private static func balanced(_ node: Node) -> Node {
        switch node {
        case .leaf: node
        case .split(let a, let b, _): .split(balanced(a), balanced(b), ratio: 0.5)
        }
    }
}

enum TileLayout {
    /// Each window's frame inside `area`, with `gaps` around the edge and between neighbours. Frames are whole points.
    static func frames(_ tree: TileTree, in area: CGRect, gaps: CGFloat) -> [UInt32: CGRect] {
        guard let root = tree.root else { return [:] }
        let gap = max(0, gaps)
        var result: [UInt32: CGRect] = [:]
        place(root, in: area.insetBy(dx: gap, dy: gap), gap: gap, into: &result)
        return result.mapValues(\.integral)
    }

    private static func place(_ node: TileTree.Node, in box: CGRect, gap: CGFloat, into result: inout [UInt32: CGRect]) {
        switch node {
        case .leaf(let id):
            result[id] = CGRect(x: box.minX, y: box.minY, width: max(1, box.width), height: max(1, box.height))
        case .split(let a, let b, let ratio):
            let share = min(0.9, max(0.1, ratio))
            if box.width >= box.height {
                let first = ((box.width - gap) * share).rounded()
                place(a, in: CGRect(x: box.minX, y: box.minY, width: first, height: box.height), gap: gap, into: &result)
                place(b, in: CGRect(x: box.minX + first + gap, y: box.minY, width: box.width - first - gap, height: box.height),
                      gap: gap, into: &result)
            } else {
                let first = ((box.height - gap) * share).rounded()
                place(a, in: CGRect(x: box.minX, y: box.minY, width: box.width, height: first), gap: gap, into: &result)
                place(b, in: CGRect(x: box.minX, y: box.minY + first + gap, width: box.width, height: box.height - first - gap),
                      gap: gap, into: &result)
            }
        }
    }

    /// Whether a tiled window that moved or changed size was the person's drag: the button is down now, or was pressed
    /// or let go a moment ago (the window's own event can come after a drag ended, a long one too). Otherwise its app moved it (it resized
    /// itself, say), and it only goes back to its place: where the pointer happens to rest swaps nothing.
    static func dragged(buttonDown: Bool, sinceMouseDown: Double, sinceMouseUp: Double = .infinity) -> Bool {
        buttonDown || sinceMouseDown < 1.5 || sinceMouseUp < 1.5
    }

    enum Direction: String, CaseIterable { case left, right, up, down }

    /// The window next to `id` in a direction: among those whose span overlaps it across that direction, the
    /// nearest; failing that, the nearest by centre in that half-plane.
    static func neighbor(of id: UInt32, _ direction: Direction, in frames: [UInt32: CGRect]) -> UInt32? {
        guard let from = frames[id] else { return nil }
        func ahead(_ f: CGRect) -> CGFloat? {
            let d: CGFloat
            switch direction {
            case .left: d = from.minX - f.maxX
            case .right: d = f.minX - from.maxX
            case .up: d = from.minY - f.maxY
            case .down: d = f.minY - from.maxY
            }
            return d >= -1 ? d : nil
        }
        func overlap(_ f: CGRect) -> CGFloat {
            switch direction {
            case .left, .right: min(from.maxY, f.maxY) - max(from.minY, f.minY)
            case .up, .down: min(from.maxX, f.maxX) - max(from.minX, f.minX)
            }
        }
        let others = frames.filter { $0.key != id }
        let aligned = others.compactMap { key, f in ahead(f).flatMap { overlap(f) > 0 ? (key, $0, overlap(f), f) : nil } }
        if let best = aligned.min(by: { ($0.1, -$0.2, $0.3.minY, $0.3.minX) < ($1.1, -$1.2, $1.3.minY, $1.3.minX) }) { return best.0 }
        let center = CGPoint(x: from.midX, y: from.midY)
        let beyond = others.filter { _, f in
            switch direction {
            case .left: f.midX < center.x - 1
            case .right: f.midX > center.x + 1
            case .up: f.midY < center.y - 1
            case .down: f.midY > center.y + 1
            }
        }
        return beyond.min { hypot($0.value.midX - center.x, $0.value.midY - center.y) < hypot($1.value.midX - center.x, $1.value.midY - center.y) }?.key
    }

    /// The tiled window under a point (where a dragged window was dropped), other than the one dragged.
    static func window(at point: CGPoint, in frames: [UInt32: CGRect], except id: UInt32) -> UInt32? {
        frames.first { $0.key != id && $0.value.contains(point) }?.key
    }
}

// MARK: - The area windows get

enum ScreenArea {
    /// A screen's frame in Accessibility's coordinates, from AppKit's (bottom-left origin); `mainTop` is the main
    /// screen's frame.maxY.
    static func toAX(_ rect: CGRect, mainTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainTop - rect.maxY, width: rect.width, height: rect.height)
    }

    /// `visible` (the screen's visible frame) less the strip Petal's dock keeps along one edge of `screen` (its full
    /// frame): `reserve` points from the screen's edge, as Dock.swift's keepWindowsClear counts it.
    static func usable(visible: CGRect, screen: CGRect, position: String, reserve: CGFloat) -> CGRect {
        guard reserve > 0 else { return visible }
        var area = visible
        switch position {
        case "left":
            let edge = screen.minX + reserve
            if area.minX < edge { area = CGRect(x: edge, y: area.minY, width: max(0, area.maxX - edge), height: area.height) }
        case "right":
            let edge = screen.maxX - reserve
            if area.maxX > edge { area.size.width = max(0, edge - area.minX) }
        default:
            let edge = screen.maxY - reserve
            if area.maxY > edge { area.size.height = max(0, edge - area.minY) }
        }
        return area
    }

    /// A frame moved (and if need be shortened) to sit inside `area`: a restored window never comes back under the
    /// dock or off its screen.
    static func fit(_ frame: CGRect, in area: CGRect) -> CGRect {
        guard area.width > 0, area.height > 0 else { return frame }
        let width = min(frame.width, area.width), height = min(frame.height, area.height)
        let x = min(max(frame.minX, area.minX), area.maxX - width)
        let y = min(max(frame.minY, area.minY), area.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
