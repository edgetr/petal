import AppKit
import SwiftUI

/// The dock's left end, on its own clear glass: the current mode as a clear glass pill with its icon in its color and
/// its name, the other modes as just their icon (clear glass comes up under the pointer). Clicking a distracting mode
/// (with countdown on) turns its button into a pill counting down ("Social 0:30") that fills with the mode's color,
/// with Stay after it; clicking it again halves the wait. Right-clicking opens the mode's menu. A side dock has no
/// room for names: there the current mode is a clear glass circle and the countdown a ring.
struct ModeSwitcher: View {
    @Environment(PetalApp.self) private var app
    let dock: ScreenDock
    let size: CGFloat
    @Namespace private var buttons

    var body: some View {
        let layout = dock.vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        let pending = app.pendingMode.flatMap { $0.desktop == dock.desktop ? $0 : nil }
        let current = dock.mode.flatMap { mode in app.config.modes.contains { $0.id == mode.id } ? mode.id : nil }
        layout {
            ForEach(app.config.modes) { mode in
                ModeButton(dock: dock, mode: mode, size: size, pending: pending?.mode == mode.id ? pending : nil, buttons: buttons)
            }
            if let pending {
                // It grows in from its left edge as the dock opens up, and goes at once when it closes, so the
                // dock closing up never runs over it.
                StayPill(pending: pending, size: size, vertical: dock.vertical)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: dock.vertical ? .top : .leading).combined(with: .opacity),
                        removal: .opacity.animation(.easeOut(duration: 0.08))))
            }
        }
        // The current mode's clear glass: one glass that moves to its button and takes its shape, never made anew
        // for a switch (making glass is most of what a switch would cost).
        .background {
            if let current {
                Color.clear.glassEffect(.clear.interactive(), in: .capsule)
                    .matchedGeometryEffect(id: current, in: buttons, properties: .frame, isSource: false)
            }
        }
        .padding(3)
        .glassEffect(.clear, in: .capsule)
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
    /// Where the current mode's glass finds this button (ModeSwitcher).
    let buttons: Namespace.ID
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        let active = dock.mode?.id == mode.id
        let wide = !dock.vertical && (active || pending != nil)
        let held = app.notes.held(in: mode.id).count
        content(active: active, wide: wide)
            .frame(minWidth: size, minHeight: size, maxHeight: size)
            .fixedSize()
            .matchedGeometryEffect(id: mode.id, in: buttons)
            // The current mode's glass is the switcher's; one counting down, or another under the pointer, has its
            // own while it lasts.
            .clearGlass(pending != nil || (hovering && !active), in: .capsule, pressed: pressed)
            // Growing into a pill or shrinking back to a circle, what it shows stays inside its own outline, so
            // it never runs over the buttons beside it.
            .clipShape(.capsule)
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
                },
                press: { pressed = $0 }))
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.2), value: held)
    }

    @ViewBuilder private func content(active: Bool, wide: Bool) -> some View {
        let color = Color(nsColor: mode.color)
        if let pending {
            // The fill runs on Core Animation; the words change once a second.
            if wide {
                TimelineView(SecondsLeft(deadline: pending.deadline)) { context in
                    pill(text: "\(mode.name) \(Self.clock(max(0, pending.deadline.timeIntervalSince(context.date))))", pending: pending)
                }
            } else {
                ZStack {
                    CountdownFill(color: mode.color, pending: pending, ring: true)
                    ModeIcon(icon: mode.icon, size: size * 0.46).foregroundStyle(.white)
                }
                .frame(width: size, height: size)
            }
        } else if wide {
            pill(text: mode.name, pending: nil)
        } else {
            ModeIcon(icon: mode.icon, size: size * 0.46)
                .foregroundStyle(color.opacity(active || hovering ? 1 : 0.62))
                .frame(width: size, height: size)
        }
    }

    /// The mode's icon in its color and its name, on the clear glass; while it waits, the color fills it left to
    /// right under both, in white.
    private func pill(text: String, pending: PendingMode?) -> some View {
        HStack(spacing: size * 0.18) {
            ModeIcon(icon: mode.icon, size: size * 0.42).foregroundStyle(pending == nil ? Color(nsColor: mode.color) : .white)
            Text(text).font(.system(size: max(11, size * 0.36), weight: .semibold).monospacedDigit()).lineLimit(1).fixedSize()
        }
        .foregroundStyle(.white)
        .padding(.leading, size * 0.3)
        .padding(.trailing, size * 0.38)
        .frame(height: size)
        .background {
            if let pending { CountdownFill(color: mode.color, pending: pending) }
        }
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
    @State private var pressed = false

    var body: some View {
        Text("Stay")
            .font(.system(size: max(10, size * (vertical ? 0.28 : 0.36)), weight: .bold))
            .foregroundStyle(.white)
            .scaleEffect(hovering ? 1.06 : 1)
            .padding(.horizontal, vertical ? 0 : size * 0.36)
            .frame(width: vertical ? size : nil, height: size)
            .clearGlass(in: .capsule, pressed: pressed)
            .fixedSize()
            .animation(.easeOut(duration: 0.12), value: hovering)
            .slotMouse(SlotMouse(left: { app.stay() }, hover: { hovering = $0 }, press: { pressed = $0 }))
    }
}
