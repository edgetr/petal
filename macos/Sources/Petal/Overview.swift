import AppKit
import SwiftUI

/// Every Desktop and its mode, on one glass panel, to see and change them at a glance. From the mode switcher's menu,
/// the menu bar, Settings, or `petal overview`.
@MainActor
final class Overview {
    private var panel: OverviewPanel?

    var isOpen: Bool { panel?.isVisible ?? false }

    func show() {
        let app = PetalApp.shared
        app.tooltips.hide()
        app.popups.closeAll()
        let panel = self.panel ?? OverviewPanel()
        self.panel = panel
        panel.show(OverviewView { [weak panel] in panel?.close() })
    }

    func close() { panel?.close() }
}

/// A key glass panel in the middle of the screen with the pointer; it closes when you click elsewhere.
@MainActor
final class OverviewPanel: NSPanel {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = hosting
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override func cancelOperation(_ sender: Any?) { close() }

    func show<Content: View>(_ content: Content) {
        hosting.rootView = AnyView(content.environment(PetalApp.shared))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let area = screen.visibleFrame
        setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + area.height * 0.08,
                        width: size.width, height: size.height).integral, display: true)
        makeKeyAndOrderFront(nil)
    }
}

struct OverviewView: View {
    @Environment(PetalApp.self) private var app
    let done: () -> Void

    var body: some View {
        let config = app.config
        let count = max(Spaces.count(), config.workspaces.keys.compactMap(Int.init).max() ?? 0, 1)
        let here = app.docks.focusedDock?.desktop
        let columns = Array(repeating: GridItem(.fixed(168), spacing: 12), count: min(4, count))
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Desktops").font(.system(size: 20, weight: .bold))
                    Text("Each keeps its own mode. Click one to change it.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                RoundButton(symbol: "xmark", action: done)
            }
            GlassEffectContainer(spacing: 12) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(1...count, id: \.self) { number in
                        DesktopTile(number: number, mode: config.mode(forDesktop: number), here: number == here)
                    }
                }
            }
            if config.bool("modes"), let fallback = config.mode(id: config.defaultMode) {
                Text("New Desktops start in \(fallback.name).").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(8)
    }
}

struct DesktopTile: View {
    @Environment(PetalApp.self) private var app
    let number: Int
    let mode: Mode?
    let here: Bool
    @State private var hovering = false

    var body: some View {
        let color = Color(nsColor: mode?.color ?? app.accent)
        Menu {
            ForEach(app.config.modes) { option in
                Button {
                    app.config.setMode(option.id, forDesktop: number)
                } label: {
                    Label(option.name + (option.id == mode?.id ? "  ✓" : ""), systemImage: NSImage(systemSymbolName: option.icon, accessibilityDescription: nil) == nil ? "circle.fill" : option.icon)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Desktop \(number)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if here { Chip(text: "Here", color: color) }
                }
                HStack(spacing: 10) {
                    ModeIcon(icon: mode?.icon ?? "circle.fill", size: 15).foregroundStyle(color)
                        .frame(width: 34, height: 34).glassEffect(.regular, in: .circle)
                    Text(mode?.name ?? "No mode").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                }
                HStack(spacing: -4) {
                    ForEach((mode?.apps ?? []).filter { Apps.url($0) != nil }.prefix(6), id: \.self) { id in
                        Image(nsImage: Apps.icon(id)).resizable().frame(width: 22, height: 22)
                    }
                }
                .frame(height: 22, alignment: .leading)
            }
            .padding(12)
            .frame(width: 168, alignment: .leading)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(here ? .regular.tint(color.opacity(0.16)).interactive() : .regular.interactive(), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(here ? color.opacity(0.7) : .clear, lineWidth: 1.5))
    }
}
