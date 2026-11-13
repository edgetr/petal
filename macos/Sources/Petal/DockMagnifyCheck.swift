import AppKit
import QuartzCore
import SwiftUI

/// `Petal --bench-dock`'s magnification step: the real dock (a `DockPanel` that's never shown, on the main screen's
/// place) with the pointer made up and held over its middle app, the magnifier stepped frame by frame as its display
/// link would, and what a person would see read back: how much the icon under the pointer grew, whether it's still
/// under the pointer, whether the glass, the strip's apps and the SwiftUI slots moved together, and whether
/// everything grown fits in what the panel draws. With the layer strip and the SwiftUI slots, the dock at the bottom,
/// left and right, magnification on from the start and switched on while the dock shows. Each case one line,
/// "ok" or "FAIL"; the number of failures is returned.
@MainActor
enum DockMagnifyCheck {
    static func run(app: PetalApp, apps: [String], folder: String?) -> Int {
        guard let screen = Screens.main else {
            print("magnification: no screen to lay the dock out for")
            return 1
        }
        print("magnification:")
        let was = (layers: DockStrip.shared.layers, position: app.config.position, on: app.config.bool("magnification"),
                   amount: app.config.number("magnificationAmount"))
        var failures = 0
        for layers in [true, false] {
            for position in ["bottom", "left", "right"] {
                for late in [false, true] {
                    failures += drive(app: app, apps: apps, screen: screen, layers: layers, position: position, late: late,
                                      folder: folder)
                }
            }
        }
        DockStrip.shared.layers = was.layers
        app.config.setDock("position", was.position)
        app.config.set("magnification", was.on)
        app.config.set("magnificationAmount", was.amount)
        return failures
    }

    /// Lays the panel out and draws it, as a frame would.
    private static func draw(_ panel: DockPanel, _ screen: NSScreen) {
        panel.place(on: screen)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    private static func drive(app: PetalApp, apps: [String], screen: NSScreen, layers: Bool, position: String, late: Bool,
                              folder: String?) -> Int {
        let name = "\(layers ? "layers" : "SwiftUI"), \(position), \(late ? "switched on" : "on from the start")"
        let amount: CGFloat = 0.5
        DockStrip.shared.layers = layers
        app.config.setDock("position", position)
        app.config.set("magnificationAmount", Double(amount))
        app.config.set("magnification", !late)
        let panel = DockPanel()
        defer { panel.close() }
        let dock = panel.dock
        dock.desktop = 1
        dock.items = apps.enumerated().map { index, id in
            DockItem(id: id, pinned: true, running: index % 2 == 0, windows: index % 2 == 0 ? 1 : 0, here: true, active: index == 0)
        }
        dock.stageSlots = dock.items.count + 1
        for _ in 0..<3 { draw(panel, screen) }
        if late {
            app.config.set("magnification", true)
            for _ in 0..<3 { draw(panel, screen) }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        draw(panel, screen)
        var problems: [String] = []
        let middle = dock.items[dock.items.count / 2].id
        guard let slot = panel.screenFrame(of: middle) else {
            print("  FAIL \(name): the middle app has no frame")
            return 1
        }
        let vertical = position != "bottom"
        // A little past the icon's centre, as a pointer usually is.
        let mouse = CGPoint(x: slot.midX + (vertical ? 0 : slot.width * 0.2), y: slot.midY - (vertical ? slot.height * 0.2 : 0))
        let rest = shown(dock, panel)
        for _ in 0..<60 {
            dock.magnifier.advance(mouse: mouse, dt: 1.0 / 120)
            draw(panel, screen)
        }
        let grown = shown(dock, panel)
        let magnifier = dock.magnifier
        let strength = magnifier.state.strength
        if strength < 0.95 { problems.append(String(format: "strength %.2f", strength)) }
        // The icon under the pointer: grown by the amount set, and still under the pointer.
        let effect = magnifier.effect(middle)
        if abs(effect.scale - (1 + amount)) > 0.05 { problems.append(String(format: "its scale %.2f", effect.scale)) }
        let point = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        if let drawn = grown[middle] {
            let along = vertical ? drawn.height : drawn.width
            let was = vertical ? (rest[middle]?.height ?? 0) : (rest[middle]?.width ?? 0)
            if was == 0 || abs(along / was - (1 + amount)) > 0.05 {
                problems.append(String(format: "drawn %.0f → %.0f", was, along))
            }
            if !drawn.insetBy(dx: -0.5, dy: -0.5).contains(point) { problems.append("not under the pointer") }
        } else {
            problems.append("not drawn")
        }
        // The order along the dock holds, nothing overlaps, and the SwiftUI slots move with the strip's apps.
        let order = (["claude", DockView.finderSlot, DockView.padSlot] + dock.items.map(\.id) + ["add", "trash"]).filter { grown[$0] != nil }
        for (a, b) in zip(order, order.dropFirst()) {
            guard let left = grown[a], let right = grown[b] else { continue }
            let gap = vertical ? right.minY - left.maxY : right.minX - left.maxX
            if gap < -1 { problems.append(String(format: "%@ over %@ by %.0f", short(a), short(b), -gap)) }
        }
        // All of it inside what the panel draws: the panel itself, and the strip's view.
        let bounds = CGRect(origin: .zero, size: panel.frame.size)
        for (id, rect) in grown where !bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect) {
            problems.append("\(short(id)) outside the panel")
        }
        if layers, let strip = dock.strip, let content = panel.contentView {
            let frame = strip.convert(strip.bounds, to: nil)
            let view = CGRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
            for id in dock.items.map(\.id) where grown[id].map({ !view.insetBy(dx: -0.5, dy: -0.5).contains($0) }) ?? false {
                problems.append("\(short(id)) outside the strip's view")
            }
        }
        let stretch = magnifier.glassStretch.scale
        if stretch < 1.05 { problems.append(String(format: "glass ×%.2f", stretch)) }
        if layers, let folder { write(dock, panel, folder: folder, name: "magnified-\(position)\(late ? "-late" : "")") }
        // Across three icons, near the grown icons' outer end: a click goes to the icon drawn under the pointer.
        if layers, let strip = dock.strip, let base = strip.windowRect(of: middle) {
            let index = dock.items.firstIndex { $0.id == middle } ?? 0
            let from = (vertical ? base.minY : base.minX) - (vertical ? base.height : base.width)
            var wrong: [String] = []
            for step in 0..<30 {
                // (Off the exact edges between slots, where either side is right.)
                let along = from + (CGFloat(step) + 0.37) * (vertical ? base.height : base.width) / 10
                let across: CGFloat = switch position {
                case "left": base.minX + base.width * (1 + amount * 0.8)
                case "right": base.maxX - base.width * (1 + amount * 0.8)
                default: base.maxY - base.height * (1 + amount * 0.8)
                }
                let point = vertical ? CGPoint(x: across, y: along) : CGPoint(x: along, y: across)
                let screenPoint = CGPoint(x: panel.frame.minX + point.x, y: panel.frame.maxY - point.y)
                for _ in 0..<40 {
                    dock.magnifier.advance(mouse: screenPoint, dt: 1.0 / 120)
                    draw(panel, screen)
                }
                let now = shown(dock, panel)
                let under = dock.items[max(0, index - 2)...min(dock.items.count - 1, index + 2)].map(\.id)
                    .first { now[$0]?.contains(point) ?? false }
                if let under, strip.app(atWindow: point) != under {
                    wrong.append("\(short(under)) → \(strip.app(atWindow: point).map(short) ?? "nothing")")
                }
            }
            if !wrong.isEmpty { problems.append("clicks: " + wrong.prefix(3).joined(separator: ", ")) }
        }
        // The pointer leaves: everything goes back to where it was.
        let away = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        for _ in 0..<90 {
            dock.magnifier.advance(mouse: away, dt: 1.0 / 120)
            draw(panel, screen)
        }
        if magnifier.state.strength != 0 { problems.append(String(format: "never settled (%.4f)", magnifier.state.strength)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        draw(panel, screen)
        let after = shown(dock, panel)
        for (id, rect) in rest where after[id].map({ !$0.insetBy(dx: -0.5, dy: -0.5).contains(rect) || $0.width > rect.width + 1 }) ?? true {
            problems.append("\(short(id)) not back (\(rect) at rest, \(after[id].map { "\($0)" } ?? "gone") now, strength \(magnifier.state.strength))")
            break
        }
        if !problems.isEmpty {
            print("    glass \(magnifier.glass), pointer \(point), panel \(panel.frame), \(magnifier.frames.count) frames")
        }
        print(String(format: "  %@ %@: ×%.2f, glass ×%.2f%@", problems.isEmpty ? "ok  " : "FAIL", name, effect.scale, stretch,
                     problems.isEmpty ? "" : "; " + problems.joined(separator: ", ")))
        return problems.isEmpty ? 0 : 1
    }

    /// Where every slot is drawn now, panel coordinates with the origin at its top left: the strip's apps from
    /// their layers, the SwiftUI slots from their layout and the magnifier's transform for them.
    private static func shown(_ dock: ScreenDock, _ panel: DockPanel) -> [String: CGRect] {
        var rects = dock.frames   // a SwiftUI slot's frame is measured inside its own transform: as it's drawn
        if let strip = dock.strip {
            for id in strip.shownOrder { rects[id] = strip.drawnRect(of: id) }
        }
        return rects
    }

    private static func short(_ id: String) -> String { id.split(separator: ".").last.map(String.init) ?? id }

    /// The strip as it's drawn, magnified, as a PNG (its layers, without the glass).
    private static func write(_ dock: ScreenDock, _ panel: DockPanel, folder: String, name: String) {
        guard let strip = dock.strip, let layer = strip.layer else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let scale: CGFloat = 2
        let size = strip.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        context.cgContext.setFillColor(NSColor(white: 0.2, alpha: 1).cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        context.cgContext.scaleBy(x: scale, y: scale)
        layer.render(in: context.cgContext)
        let path = (folder as NSString).appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
