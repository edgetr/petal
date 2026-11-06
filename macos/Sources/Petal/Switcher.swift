import AppKit
import SwiftUI

/// The dock's left end: the current mode as a pill in its color with its icon and name, the other modes as small
/// round buttons with just their icon. Clicking a distracting mode (with countdown on) turns its button into a pill
/// counting down ("Social 0:30") that fills with the mode's color, with a white Stay after it; clicking it again
/// halves the wait. Right-clicking opens the mode's menu. A side dock has no room for names: there the current
/// mode is a filled circle and the countdown a ring.
struct ModeSwitcher: View {
    @Environment(PetalApp.self) private var app
    let dock: ScreenDock
    let size: CGFloat

    var body: some View {
        let layout = dock.vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        let pending = app.pendingMode.flatMap { $0.desktop == dock.desktop ? $0 : nil }
        layout {
            ForEach(app.config.modes) { mode in
                ModeButton(dock: dock, mode: mode, size: size, pending: pending?.mode == mode.id ? pending : nil)
            }
            if let pending {
                StayPill(pending: pending, size: size, vertical: dock.vertical)
                    .transition(.scale(scale: 0.6, anchor: dock.vertical ? .top : .leading).combined(with: .opacity))
            }
        }
        .padding(3)
        .background(.white.opacity(0.07), in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .animation(.easeOut(duration: 0.24), value: dock.mode?.id)
        .animation(.easeOut(duration: 0.24), value: pending?.mode)
    }
}

struct ModeButton: View {
    @Environment(PetalApp.self) private var app
    let dock: ScreenDock
    let mode: Mode
    let size: CGFloat
    let pending: PendingMode?
    @State private var hovering = false

    var body: some View {
        let active = dock.mode?.id == mode.id
        let wide = !dock.vertical && (active || pending != nil)
        let held = app.notes.held(in: mode.id).count
        content(active: active, wide: wide)
            .frame(minWidth: size, minHeight: size, maxHeight: size)
            .fixedSize()
            .contentShape(.capsule)
            .overlay(alignment: .topTrailing) {
                if held > 0 && !active {
                    Text(held > 99 ? "99+" : "\(held)")
                        .font(.system(size: max(8, size * 0.26), weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: size * 0.4, minHeight: size * 0.4)
                        .background(Color(nsColor: mode.color), in: .capsule)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1))
                        .offset(x: size * 0.12, y: -size * 0.12)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .slotFrame(dock, "mode:\(mode.id)")
            .slotMouse(SlotMouse(
                left: { if let desktop = dock.desktop { app.requestMode(mode.id, desktop: desktop) } },
                right: { Menus.mode(mode, for: dock) },
                hover: { on in
                    hovering = on
                    app.tooltips.show(on && !wide ? mode.name : nil, over: "mode:\(mode.id)", in: dock)
                }))
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.2), value: held)
    }

    @ViewBuilder private func content(active: Bool, wide: Bool) -> some View {
        let color = Color(nsColor: mode.color)
        if let pending {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let left = max(0, pending.deadline.timeIntervalSince(context.date))
                let done = 1 - left / max(0.1, pending.total)
                if wide {
                    pill(text: "\(mode.name) \(Self.clock(left))", fill: done)
                } else {
                    ZStack {
                        Circle().fill(.white.opacity(0.08))
                        Circle().trim(from: 0, to: done).stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        ModeIcon(icon: mode.icon, size: size * 0.46).foregroundStyle(.white)
                    }
                    .frame(width: size, height: size)
                }
            }
        } else if wide {
            pill(text: mode.name, fill: 1)
        } else {
            ZStack {
                Circle().fill(active ? color : .white.opacity(hovering ? 0.12 : 0))
                ModeIcon(icon: mode.icon, size: size * 0.46)
                    .foregroundStyle(active ? .white : color.opacity(hovering ? 1 : 0.62))
            }
            .frame(width: size, height: size)
        }
    }

    /// The mode's icon and name in white on its color; `fill` is how much of it is colored, left to right.
    private func pill(text: String, fill: Double) -> some View {
        let color = Color(nsColor: mode.color)
        return HStack(spacing: size * 0.18) {
            ModeIcon(icon: mode.icon, size: size * 0.42)
            Text(text).font(.system(size: max(11, size * 0.36), weight: .semibold).monospacedDigit()).lineLimit(1).fixedSize()
        }
        .foregroundStyle(.white)
        .padding(.leading, size * 0.3)
        .padding(.trailing, size * 0.38)
        .frame(height: size)
        .background {
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.28))
                    Rectangle().fill(color).frame(width: box.size.width * min(1, max(0, fill)))
                }
                .clipShape(.capsule)
            }
        }
        .overlay(Capsule().strokeBorder(Color(nsColor: mode.color.blended(withFraction: 0.25, of: .white) ?? mode.color).opacity(0.8), lineWidth: 1))
    }

    /// 30.0 → "0:30", rounded up so it reads 0:01 until the very end.
    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.up))
        return "\(whole / 60):\(String(format: "%02d", whole % 60))"
    }
}

/// Stay: cancels the switch that's waiting.
struct StayPill: View {
    @Environment(PetalApp.self) private var app
    let pending: PendingMode
    let size: CGFloat
    var vertical = false
    @State private var hovering = false

    var body: some View {
        Text("Stay")
            .font(.system(size: max(10, size * (vertical ? 0.28 : 0.36)), weight: .bold))
            .foregroundStyle(Color(red: 0.16, green: 0.08, blue: 0.15))
            .padding(.horizontal, vertical ? 0 : size * 0.36)
            .frame(width: vertical ? size : nil, height: size)
            .background(.white.opacity(hovering ? 1 : 0.92), in: .capsule)
            .fixedSize()
            .slotMouse(SlotMouse(left: { app.stay() }, hover: { hovering = $0 }))
    }
}
