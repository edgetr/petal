import AppKit
import QuartzCore
import SwiftUI

/// `Petal --dock-check`: the real dock (a `DockPanel` that's never shown) driven headless, on folders of its own (its
/// own settings and Application Support; never the person's), with made-up apps.
///
/// Where clicks go: a dense grid of points over and under every slot, at every position, with the layer strip and the
/// SwiftUI slots, magnification off and on, is hit-tested against the real panel: every point from a slot's icon down
/// to the screen's edge (and, at the dock's ends, along to the glass's end) must be taken by the panel
/// (`DockPanel.takesMouse`, what the window server is told) and reach that slot's own view, and no point off the
/// glass may be taken. Then the same while things change, at every frame: an app appearing with the pointer already
/// over the Trash (the dock placed before SwiftUI laid the new app out, as a refresh does), an app going, the panel's
/// own move as auto-hide brings it out, and a full-screen Space coming and going.
///
/// One line per case, "ok" or "FAIL"; exits non-zero when any fails.
@MainActor
enum DockCheck {
    static func run() -> Never {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "petal-dock-check-\(getpid())")
        let config = root.appending(path: "config"), support = root.appending(path: "support")
        for folder in [config, support] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        setenv("PETAL_CONFIG_DIR", config.path, 1)
        setenv("PETAL_SUPPORT_DIR", support.path, 1)
        Headless.on = true
        guard Config.folder.path == config.path else {
            print("FAIL  set up: Petal's folders were read before the check could point them at its own; nothing was run")
            exit(1)
        }
        // The owner's dock: 24 apps of its own at 34 points, magnification off, hover lift on, the layer strip.
        let installed = Apps.installed().map(\.id).filter { $0 != DockController.finder }
        let kept = Array(installed.prefix(24))
        let loose = Array(installed.dropFirst(24).prefix(3))
        try? JSONSerialization.data(withJSONObject: ["aiProviders": ["claude"], "notes": true, "iconSize": 34,
                                                     "magnification": false, "hoverLift": true, "nowPlaying": false])
            .write(to: config.appending(path: "settings.json"))
        try? JSONSerialization.data(withJSONObject: ["apps": kept, "position": "bottom", "autoHide": false, "dock": "petal"])
            .write(to: config.appending(path: "dock.json"))
        let app = PetalApp()
        guard let screen = Screens.main else {
            print("FAIL  no screen to lay the dock out for")
            exit(1)
        }
        let checker = Checker(app: app, screen: screen, kept: kept, loose: loose)
        let failures = checker.run()
        try? FileManager.default.removeItem(at: root)
        exit(failures == 0 ? 0 : 1)
    }
}

@MainActor
private final class Checker {
    let app: PetalApp
    let screen: NSScreen
    let kept: [String]
    let loose: [String]
    var failures = 0

    init(app: PetalApp, screen: NSScreen, kept: [String], loose: [String]) {
        self.app = app
        self.screen = screen
        self.kept = kept
        self.loose = loose
    }

    var config: Config { app.config }

    func report(_ name: String, _ problems: [String], _ detail: String = "") {
        if problems.isEmpty {
            print("ok    \(name)\(detail.isEmpty ? "" : ": " + detail)")
        } else {
            failures += 1
            let labels = problems.map { String($0.prefix { $0 != ":" }) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            print("FAIL  \(name): " + problems.prefix(4).joined(separator: "; ") + (problems.count > 4 ? " (\(problems.count) in all, at \(labels.joined(separator: ", ")))" : ""))
        }
    }

    func run() -> Int {
        print("Where clicks go:")
        for layers in [true, false] {
            for position in ["bottom", "left", "right"] {
                for magnified in [false, true] {
                    grid(layers: layers, position: position, magnified: magnified)
                }
            }
        }
        for layers in [true, false] {
            appears(layers: layers)
            goes(layers: layers)
        }
        revealed()
        fullScreen()
        print("How the dock moves:")
        for layers in [true, false] {
            for magnified in [false, true] { trace(layers: layers, magnified: magnified) }
            shrinks(layers: layers)
        }
        return failures
    }

    // MARK: How the dock moves

    /// Where everything is drawn now, in screen coordinates: each SwiftUI slot's mouse (the view itself, where SwiftUI
    /// has put it this frame, known by its identity), each of the strip's apps as Core Animation draws it this moment,
    /// the glass as the panel goes by it, and the panel.
    func snapshot(_ panel: DockPanel) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for part in drawn(panel) {
            let key = part.app ?? part.view.map { "slot \(ObjectIdentifier($0).hashValue)" } ?? "?"
            out[key] = CGRect(x: panel.frame.minX + part.rect.minX, y: panel.frame.maxY - part.rect.maxY, width: part.rect.width, height: part.rect.height)
        }
        let glass = panel.dock.glassNow
        out["glass"] = CGRect(x: panel.frame.minX + glass.minX, y: panel.frame.maxY - glass.maxY, width: glass.width, height: glass.height)
        out["panel"] = panel.frame
        return out
    }

    /// A dock just full enough that one more app makes every icon shrink to fit the screen's edge: the app appearing
    /// and the icons shrinking are one move, in the same frames, never the shrink a moment later.
    func shrinks(layers: Bool) {
        let name = "\(layers ? "layers" : "SwiftUI"): one more app makes the icons shrink to fit"
        let all = Apps.installed().map(\.id).filter { $0 != DockController.finder }
        // The fewest apps at which the icons shrink.
        var count = 0
        for n in stride(from: 20, through: min(90, all.count), by: 1) {
            let panel = make(layers: layers, position: "bottom", magnified: false, ids: Array(all.prefix(n)))
            let icon = panel.dock.icon
            panel.close()
            if icon < 34 { count = n; break }
        }
        guard count > 20 else {
            report(name, [], "not reached on this screen with the apps installed")
            return
        }
        let panel = make(layers: layers, position: "bottom", magnified: false, ids: Array(all.prefix(count - 1)))
        defer { panel.close() }
        var problems: [String] = []
        var icons = [panel.dock.icon]
        var panels = [panel.frame]
        panel.dock.items = items(Array(all.prefix(count)))
        panel.dock.stageSlots = count + 1
        panel.place(on: screen)   // as a refresh places it
        for _ in 0..<60 {
            draw(panel, place: false)
            icons.append(panel.dock.icon)
            panels.append(panel.frame)
        }
        let changes = zip(icons, icons.dropFirst()).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        if changes.count != 1 || (changes.first ?? 99) > 1 {
            problems.append("the icons' size changed at frames \(changes) (\(icons.map { Int($0) }.reduce(into: [Int]()) { if $0.last != $1 { $0.append($1) } }))")
        }
        let moved = zip(panels, panels.dropFirst()).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        if moved.count > 1 || (moved.first ?? 0) > 1 { problems.append("the panel moved at frames \(moved)") }
        report(name, problems, "at \(count) apps, \(Int(icons.first!)) → \(Int(icons.last!)) pt")
    }

    /// Drives `change` and records every part, frame by frame, for half a second: whether each part moves once (one
    /// path, from where it was to where it ends, never back), whether they move together, and whether anything moves
    /// when nothing shown changed.
    func trace(layers: Bool, magnified: Bool) {
        let name = "\(layers ? "layers" : "SwiftUI"), magnification \(magnified ? "on" : "off")"
        let panel = make(layers: layers, position: "bottom", magnified: magnified, ids: kept + loose.prefix(1))
        defer { panel.close() }
        func record(_ label: String, _ change: () -> Void) -> [[String: CGRect]] {
            var frames = [snapshot(panel)]
            change()
            panel.place(on: screen)   // as a refresh places it, before SwiftUI has laid the change out
            for _ in 0..<60 {
                draw(panel, place: false)
                frames.append(snapshot(panel))
            }
            return frames
        }
        /// Each part's path along the dock: how many times it changes direction or jumps, and when it stops.
        func judge(_ label: String, _ frames: [[String: CGRect]], still: Bool) {
            var problems: [String] = []
            let ids = frames.last!.keys.filter { $0 != "panel" }
            for id in ids.sorted() {
                let path = frames.compactMap { $0[id].map { $0.midX } }
                let widths = frames.compactMap { $0[id].map { $0.width } }
                guard path.count == frames.count else { continue }   // appeared or went: its own animation
                let moves = zip(path, path.dropFirst()).map { $1 - $0 }.filter { abs($0) > 0.25 }
                if still {
                    if !moves.isEmpty || Set(widths.map { Int($0) }).count > 1 { problems.append("\(short(id)) moved by \(Int(moves.reduce(0, +)))") }
                    continue
                }
                let turns = zip(moves, moves.dropFirst()).filter { ($0 > 0) != ($1 > 0) }.count
                let jump = moves.map(abs).max() ?? 0
                if turns > 0 { problems.append("\(short(id)) went back and forth (\(turns) turns: \(path.map { Int($0) }.reduce(into: [Int]()) { if $0.last != $1 { $0.append($1) } }))") }
                if jump > 12, moves.count < 3 { problems.append("\(short(id)) jumped \(Int(jump)) at once") }
            }
            report("\(name): \(label)", problems)
        }
        let appear = record("appears") {
            let ids = kept + loose.prefix(2)
            panel.dock.items = items(Array(ids))
            panel.dock.stageSlots = ids.count + 1
        }
        judge("an app appears at the end", appear, still: false)
        let go = record("goes") {
            let ids = kept.prefix(5) + kept.dropFirst(6) + loose.prefix(2)
            panel.dock.items = items(Array(ids))
            panel.dock.stageSlots = ids.count + 1
        }
        judge("an app in the middle goes", go, still: false)
        let same = record("same") {
            var now = panel.dock.items
            now[3].windows += 1
            now[4].active.toggle()
            panel.dock.items = now
        }
        judge("a window opens, another app comes forward", same, still: true)
        let nothing = record("nothing") { panel.dock.items = panel.dock.items }
        judge("a refresh that changes nothing", nothing, still: true)
    }

    // MARK: The panel

    func items(_ ids: [String]) -> [DockItem] {
        ids.enumerated().map { index, id in
            DockItem(id: id, pinned: kept.contains(id), running: index % 3 != 1, windows: index % 3 == 1 ? 0 : 1, here: true, active: index == 0)
        }
    }

    func make(layers: Bool, position: String, magnified: Bool, ids: [String]) -> DockPanel {
        DockStrip.shared.layers = layers
        config.setDock("position", position)
        config.set("magnification", magnified)
        config.set("magnificationAmount", 0.5)
        let panel = DockPanel()
        panel.dock.desktop = 1
        panel.dock.items = items(ids)
        panel.dock.stageSlots = ids.count + 1
        for _ in 0..<4 { draw(panel) }
        return panel
    }

    /// Lays the panel out and draws it, as a frame would (placed first, as a refresh places it).
    func draw(_ panel: DockPanel, place: Bool = true) {
        if place { panel.place(on: screen) }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.008))
    }

    /// Every slot as drawn now, in panel coordinates (top-left origin), in order along the dock.
    func slots(_ panel: DockPanel) -> [(id: String, rect: CGRect)] {
        let dock = panel.dock
        var all = dock.frames
        if let strip = dock.strip { for id in strip.shownOrder { all[id] = strip.windowRect(of: id) } }
        let shown = Set(dock.items.map(\.id) + ["claude", DockView.finderSlot, DockView.padSlot, "add", "trash", "media"])
            .union(all.keys.filter { $0.hasPrefix("stack:") || $0.hasPrefix("min:") })
        let vertical = dock.vertical
        return all.filter { shown.contains($0.key) && $0.value.width > 1 }.map { (id: $0.key, rect: $0.value) }
            .sorted { vertical ? $0.rect.midY < $1.rect.midY : $0.rect.midX < $1.rect.midX }
    }

    func screenPoint(_ point: CGPoint, _ panel: DockPanel) -> CGPoint {
        CGPoint(x: panel.frame.minX + point.x, y: panel.frame.maxY - point.y)
    }

    /// Which slot a click at `point` (panel coordinates) reaches: the layer strip's app under it, or the SwiftUI slot
    /// whose mouse took it (known by where its slot is).
    func reached(_ point: CGPoint, _ panel: DockPanel, _ slots: [(id: String, rect: CGRect)]) -> String? {
        guard let content = panel.contentView else { return nil }
        var view = content.hitTest(NSPoint(x: point.x, y: content.bounds.height - point.y))
        while let current = view {
            if let strip = current as? AppStripView { return strip.app(atWindow: point) }
            if current is SlotMouse.MouseView {
                let frame = current.convert(current.bounds, to: nil)
                let rect = CGRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
                let vertical = panel.dock.vertical
                return slots.first { vertical ? rect.minY <= $0.rect.midY && $0.rect.midY <= rect.maxY
                    : rect.minX <= $0.rect.midX && $0.rect.midX <= rect.maxX }?.id
            }
            view = current.superview
        }
        return nil
    }

    /// Points over each slot, from its far side down to the panel's edge on the screen's side, and at the dock's ends
    /// along to the glass's end: each must be taken and reach that slot. Then points off the glass: none taken.
    func sweep(_ panel: DockPanel, label: String, steps: Int = 7, problems: inout [String], off: Bool = true) {
        let dock = panel.dock
        let all = slots(panel)
        let glass = dock.glassNow
        let vertical = dock.vertical
        let position = config.position
        guard !all.isEmpty, glass.width > 0 else {
            problems.append("\(label): nothing laid out")
            return
        }
        for (index, slot) in all.enumerated() {
            var along = vertical ? (slot.rect.minY, slot.rect.maxY) : (slot.rect.minX, slot.rect.maxX)
            if index == 0 { along.0 = vertical ? glass.minY : glass.minX }
            if index == all.count - 1 { along.1 = vertical ? glass.maxY : glass.maxX }
            let across: (CGFloat, CGFloat) = switch position {
            case "left": (0, slot.rect.maxX)
            case "right": (slot.rect.minX, panel.frame.width)
            default: (slot.rect.minY, panel.frame.height)
            }
            for i in 0..<steps {
                for j in 0..<steps {
                    let a = along.0 + 0.6 + (along.1 - along.0 - 1.2) * CGFloat(i) / CGFloat(steps - 1)
                    let b = across.0 + 0.6 + (across.1 - across.0 - 1.2) * CGFloat(j) / CGFloat(steps - 1)
                    let point = vertical ? CGPoint(x: b, y: a) : CGPoint(x: a, y: b)
                    let taken = panel.takesMouse(at: screenPoint(point, panel))
                    let to = reached(point, panel, all)
                    if !taken || to != slot.id {
                        let hit = panel.contentView?.hitTest(NSPoint(x: point.x, y: (panel.contentView?.bounds.height ?? 0) - point.y))
                        problems.append("\(label): \(short(slot.id)) at \(Int(point.x)),\(Int(point.y)) → \(taken ? (to.map(short) ?? "nothing (\(hit.map { String(describing: type(of: $0)) } ?? "none"))") : "the desktop")")
                    }
                }
            }
        }
        guard off else { return }
        // Off the glass: past its ends, and past it inward (beyond any icon drawn over it).
        let inward = DockView.inwardReach(config, icon: dock.icon) + (dock.magnifier.on ? dock.icon * 2 : 0) + 3
        var outside: [CGPoint] = []
        for k in 0..<9 {
            let t = CGFloat(k) / 8
            if vertical {
                let x = position == "left" ? glass.maxX + inward : glass.minX - inward
                outside.append(CGPoint(x: x, y: glass.minY + glass.height * t))
                outside.append(CGPoint(x: glass.minX + glass.width * t, y: glass.minY - 3))
                outside.append(CGPoint(x: glass.minX + glass.width * t, y: glass.maxY + 3))
            } else {
                outside.append(CGPoint(x: glass.minX + glass.width * t, y: glass.minY - inward))
                outside.append(CGPoint(x: glass.minX - 3, y: glass.minY + glass.height * t))
                outside.append(CGPoint(x: glass.maxX + 3, y: glass.minY + glass.height * t))
            }
        }
        for point in outside where panel.takesMouse(at: screenPoint(point, panel)) {
            problems.append("\(label): off the glass at \(Int(point.x)),\(Int(point.y)) taken")
        }
    }

    func short(_ id: String) -> String { id.split(separator: ".").last.map(String.init) ?? id }

    // MARK: Cases

    func grid(layers: Bool, position: String, magnified: Bool) {
        let name = "\(layers ? "layers" : "SwiftUI"), \(position), magnification \(magnified ? "on" : "off")"
        let panel = make(layers: layers, position: position, magnified: magnified, ids: kept + loose)
        defer { panel.close() }
        var problems: [String] = []
        sweep(panel, label: "at rest", steps: 9, problems: &problems)
        if magnified, let slot = slots(panel).first(where: { $0.id == kept[kept.count / 2] }) {
            // Grown under a pointer held over the middle app.
            let mouse = screenPoint(CGPoint(x: slot.rect.midX, y: slot.rect.midY), panel)
            for _ in 0..<60 {
                panel.dock.magnifier.advance(mouse: mouse, dt: 1.0 / 120)
                draw(panel)
            }
            let grown = slots(panel).filter { abs(($0.rect.midX + $0.rect.midY) - (slot.rect.midX + slot.rect.midY)) < 3 * slot.rect.width }
            for item in grown {
                let point = CGPoint(x: item.rect.midX, y: item.rect.midY)
                if !panel.takesMouse(at: screenPoint(point, panel)) { problems.append("grown \(short(item.id)) not taken") }
            }
            for _ in 0..<90 {
                panel.dock.magnifier.advance(mouse: CGPoint(x: screen.frame.midX, y: screen.frame.midY), dt: 1.0 / 120)
                draw(panel)
            }
        }
        report(name, problems, "\(slots(panel).count) slots, icons \(Int(panel.dock.icon)) pt")
    }

    /// Every slot where it's drawn this frame (panel coordinates, top-left origin): each SwiftUI slot's mouse (the
    /// view itself, where SwiftUI has put it on its way), and each of the strip's apps as Core Animation draws it.
    func drawn(_ panel: DockPanel) -> [(rect: CGRect, view: NSView?, app: String?)] {
        guard let content = panel.contentView else { return [] }
        var out: [(rect: CGRect, view: NSView?, app: String?)] = []
        func walk(_ view: NSView) {
            if view is SlotMouse.MouseView {
                let frame = view.convert(view.bounds, to: nil)
                out.append((CGRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height), view, nil))
            }
            view.subviews.forEach(walk)
        }
        walk(content)
        if let strip = panel.dock.strip {
            for id in strip.shownOrder { if let rect = strip.presentedRect(of: id) { out.append((rect, nil, id)) } }
        }
        return out
    }

    /// One frame of a change: every point over every slot as drawn is taken and reaches that slot; nothing past the
    /// drawn ends is taken; and the glass the panel goes by is where the dock's ends are drawn.
    func frameCheck(_ panel: DockPanel, label: String, problems: inout [String]) {
        guard let content = panel.contentView else { return }
        let parts = drawn(panel)
        let bounds = CGRect(origin: .zero, size: panel.frame.size)
        for part in parts {
            let rect = part.rect.intersection(bounds)
            guard rect.width > 2, rect.height > 2 else { continue }
            for i in 0..<3 {
                for j in 0..<3 {
                    let point = CGPoint(x: rect.minX + 1 + (rect.width - 2) * CGFloat(i) / 2, y: rect.minY + 1 + (rect.height - 2) * CGFloat(j) / 2)
                    guard panel.takesMouse(at: screenPoint(point, panel)) else {
                        problems.append("\(label): a slot at \(Int(point.x)),\(Int(point.y)) goes to the desktop")
                        continue
                    }
                    let hit = content.hitTest(NSPoint(x: point.x, y: content.bounds.height - point.y))
                    if let view = part.view {
                        if hit !== view, !(parts.contains { $0.view === hit && $0.rect.contains(point) }) {
                            problems.append("\(label): a slot at \(Int(point.x)),\(Int(point.y)) reaches \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
                        }
                    } else if let app = part.app, let strip = panel.dock.strip, strip.app(atWindow: point) != app {
                        // (Two of the strip's icons may overlap for a moment as one grows in or shrinks away.)
                        if !parts.contains(where: { $0.app != nil && $0.app != app && $0.rect.contains(point) }) {
                            problems.append("\(label): \(short(app)) at \(Int(point.x)),\(Int(point.y)) reaches \(strip.app(atWindow: point).map(short) ?? "nothing")")
                        }
                    }
                }
            }
        }
        // The dock's ends as drawn: its first and last slot's mouse reach to the glass's ends.
        let mice = parts.filter { $0.view != nil }.map(\.rect)
        guard let low = mice.map(\.minX).min(), let high = mice.map(\.maxX).max() else { return }
        let glass = panel.dock.glassNow
        if glass.minX > low + 1.5 || glass.maxX < high - 1.5 {
            problems.append("\(label): the glass gone by (\(Int(glass.minX))–\(Int(glass.maxX))) is inside the drawn ends (\(Int(low))–\(Int(high)))")
        }
        if glass.minX < low - 3 || glass.maxX > high + 3 {
            problems.append("\(label): the glass gone by (\(Int(glass.minX))–\(Int(glass.maxX))) reaches past the drawn ends (\(Int(low))–\(Int(high)))")
        }
        let y = glass.midY
        for point in [CGPoint(x: low - 3, y: y), CGPoint(x: high + 3, y: y)] where panel.takesMouse(at: screenPoint(point, panel)) {
            problems.append("\(label): past the drawn end at \(Int(point.x)) taken")
        }
    }

    /// The dock changes while the pointer stays where it is: the change is laid out before SwiftUI has the new apps,
    /// as a refresh places it, then drawn frame by frame through its animation and after.
    func change(layers: Bool, _ label: String, from: [String], to: [String]) {
        let panel = make(layers: layers, position: "bottom", magnified: false, ids: from)
        defer { panel.close() }
        var problems: [String] = []
        panel.dock.items = items(to)
        panel.dock.stageSlots = to.count + 1
        panel.place(on: screen)
        var frames = 0, before = 0, points = 0
        for frame in 0..<45 {
            draw(panel, place: frame % 15 == 14)   // placed again only now and then, as looks come
            frames += 1
            frameCheck(panel, label: "frame \(frame)", problems: &problems)
            // What deciding by the size measured before (the rule this replaced) would have let through to the desktop.
            if let size = panel.measuredSize {
                let old = CGRect(x: panel.frame.width / 2 - size.width / 2, y: panel.frame.height / 2 - size.height / 2,
                                 width: size.width, height: size.height).insetBy(dx: -2, dy: -2)
                for part in drawn(panel) {
                    for t in [0.1, 0.5, 0.9] as [CGFloat] {
                        points += 1
                        if !old.contains(CGPoint(x: part.rect.minX + part.rect.width * t, y: part.rect.midY)) { before += 1 }
                    }
                }
            }
        }
        sweep(panel, label: "after", steps: 5, problems: &problems)
        report("\(layers ? "layers" : "SwiftUI"): \(label)", problems,
               "\(frames) frames; by the size measured before, \(before) of \(points) points over slots went to the desktop")
    }

    func appears(layers: Bool) { change(layers: layers, "an app appears, the pointer still over the dock", from: kept + loose.prefix(1), to: kept + loose.prefix(2)) }
    func goes(layers: Bool) { change(layers: layers, "an app goes, the pointer still over the dock", from: kept + loose, to: Array(kept.prefix(5) + kept.dropFirst(6) + loose)) }

    /// Auto-hide: tucked away, nothing is the dock's; brought out (the panel's own move), every slot is, at every frame.
    func revealed() {
        let panel = make(layers: true, position: "bottom", magnified: false, ids: kept + loose)
        defer {
            panel.close()
            config.setDock("autoHide", false)
        }
        var problems: [String] = []
        config.setDock("autoHide", true)
        panel.dock.revealed = false
        for _ in 0..<3 { draw(panel) }
        if let trash = slots(panel).first(where: { $0.id == "trash" }), panel.takesMouse(at: screenPoint(CGPoint(x: trash.rect.midX, y: trash.rect.midY), panel)) {
            problems.append("tucked away, the Trash still takes the click")
        }
        panel.reveal()
        for frame in 0..<30 {
            draw(panel)
            frameCheck(panel, label: "frame \(frame)", problems: &problems)
        }
        report("auto-hide: brought out, every slot the dock's at every frame", problems)
    }

    /// A full-screen app's Space comes and goes (the dock steps aside, then comes back).
    func fullScreen() {
        let panel = make(layers: true, position: "bottom", magnified: false, ids: kept + loose)
        defer { panel.close() }
        var problems: [String] = []
        panel.fullScreen = true
        for _ in 0..<3 { draw(panel) }
        if let trash = slots(panel).first(where: { $0.id == "trash" }), panel.takesMouse(at: screenPoint(CGPoint(x: trash.rect.midX, y: trash.rect.midY), panel)) {
            problems.append("on a full-screen app's Space, the hidden dock still takes the click")
        }
        panel.fullScreen = false
        for frame in 0..<20 {
            draw(panel)
            frameCheck(panel, label: "frame \(frame)", problems: &problems)
        }
        report("a full-screen Space comes and goes", problems)
    }
}
