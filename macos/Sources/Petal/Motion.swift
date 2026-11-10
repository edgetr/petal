import AppKit
import QuartzCore
import SwiftUI

// The dock's moving part that runs by itself (the equalizer), drawn with Core Animation: once started, the window
// server runs it, and the main thread does nothing until something changes.

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
