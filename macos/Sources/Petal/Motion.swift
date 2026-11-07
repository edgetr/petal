import AppKit
import QuartzCore
import SwiftUI

// The dock's moving parts that run by themselves (the equalizer, the countdown's fill), drawn with Core Animation:
// once started, the window server runs them, and the main thread does nothing until something changes.

/// A plain layer-backed view, its layers kept on the same scale as the screen it's on.
class LayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // only draws: clicks go to the slot's own mouse

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        func walk(_ layer: CALayer) {
            layer.contentsScale = scale
            layer.sublayers?.forEach(walk)
        }
        if let layer { walk(layer) }
    }
}

// MARK: - Playing music

/// Three bars rising and falling while music plays, each at its own pace.
struct Equalizer: View {
    @Environment(\.snapshotting) private var snapshotting
    let icon: CGFloat

    var body: some View {
        let height = max(4, icon * 0.16)
        if snapshotting {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3) { i in
                    Capsule().fill(Color(nsColor: PetalApp.shared.accent)).frame(width: 2, height: height * [0.5, 1, 0.35][i])
                }
            }
            .frame(height: height, alignment: .bottom)
        } else {
            EqualizerBars(height: height, color: PetalApp.shared.accent).frame(width: 10, height: height)
        }
    }
}

private struct EqualizerBars: NSViewRepresentable {
    let height: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> BarsView { BarsView() }
    func updateNSView(_ view: BarsView, context: Context) { view.set(height: height, color: color) }

    final class BarsView: LayerView {
        private var bars: [CALayer] = []
        private var shown: (CGFloat, NSColor)?

        func set(height: CGFloat, color: NSColor) {
            guard shown?.0 != height || shown?.1 != color else { return }
            shown = (height, color)
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0..<3).map { i in
                let bar = CALayer()
                let top = height * (i == 1 ? 1 : 0.7)
                bar.backgroundColor = color.cgColor
                bar.cornerRadius = 1
                bar.anchorPoint = CGPoint(x: 0.5, y: 0)          // grows up from the bottom
                bar.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
                bar.position = CGPoint(x: 1 + CGFloat(i) * 4, y: 0)
                // The old timeline's sine, half a period each way: (sin + 1) / 2 of the bar's height.
                let rise = CABasicAnimation(keyPath: "bounds.size.height")
                rise.fromValue = 2
                rise.toValue = max(2, top)
                rise.duration = (0.52 + Double(i) * 0.16) / 2
                rise.autoreverses = true
                rise.repeatCount = .infinity
                rise.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                rise.timeOffset = rise.duration * [0.2, 1.1, 0.6][i]   // out of step from the start
                bar.add(rise, forKey: "rise")
                layer?.addSublayer(bar)
                return bar
            }
            viewDidChangeBackingProperties()
        }
    }
}

// MARK: - The countdown

/// A countdown's fill in the mode's color: a bar filling left to right inside a capsule (with its track), or a ring
/// going round. It runs from where the wait is now to the deadline on its own; a new deadline (another click halved
/// the wait) starts it again from there.
struct CountdownFill: View {
    @Environment(\.snapshotting) private var snapshotting
    let color: NSColor
    let pending: PendingMode
    var ring = false

    var body: some View {
        if snapshotting {
            let done = 1 - max(0, pending.deadline.timeIntervalSinceNow) / max(0.1, pending.total)
            if ring {
                Circle().trim(from: 0, to: done).stroke(Color(nsColor: color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(nsColor: color).opacity(0.28))
                        Rectangle().fill(Color(nsColor: color)).frame(width: box.size.width * done)
                    }
                    .clipShape(.capsule)
                }
            }
        } else {
            CountdownLayers(color: color, deadline: pending.deadline, total: pending.total, ring: ring)
        }
    }
}

private struct CountdownLayers: NSViewRepresentable {
    let color: NSColor
    let deadline: Date
    let total: Double
    let ring: Bool

    func makeNSView(context: Context) -> FillView { FillView() }
    func updateNSView(_ view: FillView, context: Context) {
        view.set(color: color, deadline: deadline, total: total, ring: ring)
    }

    final class FillView: LayerView {
        private let track = CALayer()
        private let bar = CALayer()
        private let arc = CAShapeLayer()
        private var state: (color: NSColor, deadline: Date, total: Double, ring: Bool)?
        private var laidOut: CGSize = .zero

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer?.addSublayer(track)
            layer?.addSublayer(bar)
            layer?.addSublayer(arc)
            bar.anchorPoint = CGPoint(x: 0, y: 0.5)
            arc.fillColor = nil
            arc.lineWidth = 2.5
            arc.lineCap = .round
        }

        func set(color: NSColor, deadline: Date, total: Double, ring: Bool) {
            if let state, state.color == color, state.deadline == deadline, state.total == total, state.ring == ring { return }
            state = (color, deadline, total, ring)
            restart()
        }

        override func layout() {
            super.layout()
            guard bounds.size != laidOut else { return }
            laidOut = bounds.size
            restart()
        }

        private func restart() {
            guard let state, bounds.width > 0 else { return }
            let left = max(0, state.deadline.timeIntervalSinceNow)
            let done = min(1, max(0, 1 - left / max(0.1, state.total)))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.isHidden = state.ring
            bar.isHidden = state.ring
            arc.isHidden = !state.ring
            if state.ring {
                let inset = arc.lineWidth / 2
                // From the top, clockwise: a path drawn counterclockwise in a y-up view, starting at 12 o'clock.
                let box = bounds.insetBy(dx: inset, dy: inset)
                let path = CGMutablePath()
                path.addArc(center: CGPoint(x: box.midX, y: box.midY), radius: box.width / 2, startAngle: .pi / 2,
                            endAngle: .pi / 2 - 2 * .pi, clockwise: true)
                arc.frame = bounds
                arc.path = path
                arc.strokeColor = state.color.cgColor
                arc.removeAllAnimations()
                arc.strokeEnd = 1
                let fill = CABasicAnimation(keyPath: "strokeEnd")
                fill.fromValue = done
                fill.toValue = 1
                fill.duration = max(0.01, left)
                arc.add(fill, forKey: "fill")
            } else {
                layer?.cornerRadius = bounds.height / 2
                layer?.masksToBounds = true
                track.frame = bounds
                track.backgroundColor = state.color.withAlphaComponent(0.28).cgColor
                bar.backgroundColor = state.color.cgColor
                bar.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
                bar.position = CGPoint(x: 0, y: bounds.midY)
                bar.removeAllAnimations()
                let fill = CABasicAnimation(keyPath: "bounds.size.width")
                fill.fromValue = bounds.width * done
                fill.toValue = bounds.width
                fill.duration = max(0.01, left)
                bar.add(fill, forKey: "fill")
            }
            CATransaction.commit()
        }
    }
}

/// A timeline that ticks only when a countdown's whole seconds change ("0:30" → "0:29"), not every frame.
struct SecondsLeft: TimelineSchedule {
    let deadline: Date

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var date = start
        var first = true
        return AnyIterator {
            if first { first = false; return start }
            let left = deadline.timeIntervalSince(date)
            guard left > 0.0001 else { return nil }
            date = deadline.addingTimeInterval(-(left - 0.0001).rounded(.down))
            return date
        }
    }
}
