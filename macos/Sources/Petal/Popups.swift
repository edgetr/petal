import AppKit
import Observation
import SwiftUI

/// A borderless glass panel that sits over a dock slot: tooltips, previews, stacks and cards.
@MainActor
final class GlassPanel: NSPanel {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    var interactive = true

    init(level: NSWindow.Level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = hosting
        isFloatingPanel = true
        self.level = level
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }

    func show<Content: View>(_ content: Content, over slot: CGRect, dock: DockPanel?, gap: CGFloat = 8) {
        hosting.rootView = AnyView(content.environment(PetalApp.shared))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let screen = dock?.screenRef ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.frame.insetBy(dx: gap, dy: gap)
        let edge = dock?.frame ?? slot
        var origin: CGPoint
        switch PetalApp.shared.config.position {
        case "left": origin = CGPoint(x: edge.maxX + gap, y: slot.midY - size.height / 2)
        case "right": origin = CGPoint(x: edge.minX - gap - size.width, y: slot.midY - size.height / 2)
        default: origin = CGPoint(x: slot.midX - size.width / 2, y: edge.maxY + gap)
        }
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        setFrame(NSRect(origin: origin, size: size).integral, display: true)
        ignoresMouseEvents = !interactive
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}

/// The slot's name, on a small glass pill outside the dock, with no delay.
@MainActor
final class Tooltips {
    private let panel: GlassPanel = {
        let panel = GlassPanel()
        panel.interactive = false
        return panel
    }()

    func show(_ text: String?, over id: String, in dock: ScreenDock?) {
        let app = PetalApp.shared
        guard let text, !text.isEmpty, app.config.bool("tooltips"), let dock, dock.dragging == nil, dock.openPopup == nil,
              !app.popups.anyOpen, let panelRef = dock.panel, let slot = panelRef.screenFrame(of: id) else {
            panel.hide()
            return
        }
        panel.show(Text(text).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule).padding(6),
                   over: slot, dock: panelRef, gap: 2)
    }

    func hide() { panel.hide() }
}

/// Stacks, previews and cards: one open at a time; clicking elsewhere closes the stack.
@MainActor @Observable
final class Popups {
    @ObservationIgnored private let panel = GlassPanel()
    @ObservationIgnored private let cardPanel = GlassPanel()
    @ObservationIgnored private var monitor: Any?
    private(set) var kind: String?           // "stack", "preview"
    private(set) var card: FocusCard?
    @ObservationIgnored private weak var openDock: ScreenDock?

    var anyOpen: Bool { kind != nil || card != nil }

    init() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.kind == "stack" else { return }
                if !self.panel.frame.contains(NSEvent.mouseLocation) { self.closeAll() }
            }
        }
    }

    func closeAll() {
        panel.hide()
        kind = nil
        openDock?.openPopup = nil
        openDock = nil
        PetalApp.shared.tooltips.hide()
    }

    func toggleStack(_ folder: String, in dock: ScreenDock) {
        let key = "stack:\(folder)"
        if dock.openPopup == key { closeAll(); return }
        closeAll()
        PetalApp.shared.previews.hover(nil, in: dock)
        guard let slot = dock.panel?.screenFrame(of: key) else { return }
        kind = "stack"
        openDock = dock
        dock.openPopup = key
        panel.show(StackView(folder: folder) { [weak self] in self?.closeAll() }, over: slot, dock: dock.panel)
    }

    func showPreview(_ item: DockItem, in dock: ScreenDock) {
        guard let slot = dock.panel?.screenFrame(of: item.id) else { return }
        if kind == "stack" { return }
        kind = "preview"
        openDock = dock
        PetalApp.shared.tooltips.hide()
        panel.show(PreviewView(bundleID: item.id) { [weak self] in self?.closeAll() }, over: slot, dock: dock.panel)
    }

    var previewFrame: CGRect? { kind == "preview" ? panel.frame : nil }

    func show(_ card: FocusCard) {
        self.card = card
        guard let dock = PetalApp.shared.docks.focusedDock, let panelRef = dock.panel else { return }
        closeAll()
        panelRef.reveal()
        let pill = panelRef.frame
        cardPanel.show(CardView(card: card), over: CGRect(x: pill.midX - 1, y: pill.minY, width: 2, height: pill.height), dock: panelRef)
    }

    func dismissCard() {
        card = nil
        cardPanel.hide()
    }
}

// MARK: - Previews

/// Window previews: after 380 ms over an app with windows; swapping straight to another app's; gone 220 ms after
/// the pointer leaves both the app and the preview.
@MainActor @Observable
final class Previews {
    private(set) var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored private var showTask: DispatchWorkItem?
    @ObservationIgnored private var hideTask: DispatchWorkItem?
    @ObservationIgnored private var refresh: Timer?
    @ObservationIgnored private(set) var showing: String?

    func hover(_ item: DockItem?, in dock: ScreenDock) {
        let app = PetalApp.shared
        showTask?.cancel()
        if let item, item.windows > 0, app.config.bool("previews"), dock.dragging == nil, app.popups.card == nil,
           app.popups.kind != "stack" {
            hideTask?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.open(item, in: dock) }
            showTask = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (showing == nil ? 0.38 : 0), execute: work)
        } else {
            scheduleHide()
        }
    }

    private func open(_ item: DockItem, in dock: ScreenDock) {
        showing = item.id
        PetalApp.shared.popups.showPreview(item, in: dock)
        capture(item.id)
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let id = self?.showing { self?.capture(id) } }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let frame = PetalApp.shared.popups.previewFrame, frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) {
                self.scheduleHide()
                return
            }
            self.close()
        }
        hideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    func close() {
        refresh?.invalidate()
        if showing != nil, PetalApp.shared.popups.kind == "preview" { PetalApp.shared.popups.closeAll() }
        showing = nil
    }

    func windows(of bundleID: String) -> [AppWindow] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).flatMap { Windows.windows(of: $0.processIdentifier) }
    }

    private func capture(_ bundleID: String) {
        let list = Array(windows(of: bundleID).prefix(6))
        Task {
            let pictures = await Capture.capture(list)
            for (id, image) in pictures { thumbnails[id] = image }
        }
    }

    /// A still of a minimized window, taken once.
    func snapshot(_ window: AppWindow) {
        guard thumbnails[window.id] == nil else { return }
        Task {
            let pictures = await Capture.capture([window])
            for (id, image) in pictures { thumbnails[id] = image }
        }
    }
}

struct PreviewView: View {
    @Environment(PetalApp.self) private var app
    let bundleID: String
    let done: () -> Void

    var body: some View {
        let windows = Array(app.previews.windows(of: bundleID).prefix(6))
        HStack(spacing: 12) {
            ForEach(windows) { window in
                PreviewTile(window: window, image: app.previews.thumbnails[window.id], done: done)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(6)
    }
}

struct PreviewTile: View {
    let window: AppWindow
    let image: NSImage?
    let done: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25))
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(3)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "macwindow").font(.system(size: 28)).foregroundStyle(.secondary)
                        if !Capture.allowed {
                            Text("Allow Screen Recording\nfor previews").font(.system(size: 10)).multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(width: 200, height: 124)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hovering ? Color(nsColor: PetalApp.shared.accent) : .white.opacity(0.12),
                                                                    lineWidth: hovering ? 2 : 1))
            HStack(spacing: 6) {
                Text(window.title.isEmpty ? "Window" : window.title + (window.minimized ? " (minimized)" : ""))
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if !window.minimized { RoundButton(symbol: "minus") { Windows.minimize(window) } }
                RoundButton(symbol: "xmark") { Windows.close(window) }
            }
            .frame(width: 200)
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { Windows.focus(window); done() }
    }
}

struct RoundButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(hovering ? Color(nsColor: PetalApp.shared.accent) : .white.opacity(0.1), in: .circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Stacks

struct StackView: View {
    @Environment(PetalApp.self) private var app
    let folder: String
    let done: () -> Void

    var body: some View {
        let entries = Stacks.entries(folder, limit: 12)
        VStack(alignment: .leading, spacing: 2) {
            Text(Stacks.name(folder)).font(.system(size: 15, weight: .bold)).foregroundStyle(Color(nsColor: app.accent))
                .padding(.horizontal, 8).padding(.bottom, 6)
            if entries.isEmpty {
                Text("Empty").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            ForEach(entries) { entry in
                StackRow(entry: entry) { NSWorkspace.shared.open(entry.url); done() }
            }
            Divider().padding(.vertical, 4)
            Button {
                NSWorkspace.shared.open(Stacks.url(folder))
                done()
            } label: {
                HStack { Text("Open in Finder"); Spacer(); Image(systemName: "arrow.right") }
                    .padding(.horizontal, 8).padding(.vertical, 6).contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 300)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(6)
    }
}

struct StackRow: View {
    let entry: Stacks.Entry
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if Stacks.isImage(entry.url), let image = NSImage(contentsOf: entry.url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(nsImage: Apps.icon(file: entry.url)).resizable()
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(.rect(cornerRadius: 6))
            Text(entry.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(hovering ? .white.opacity(0.08) : .clear, in: .rect(cornerRadius: 9))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .onDrag { NSItemProvider(contentsOf: entry.url) ?? NSItemProvider() }
    }
}

// MARK: - Cards

/// A focus card or an update card (Omarchy's card kinds guard and update; holding isn't on the Mac).
struct FocusCard: Identifiable, Equatable {
    enum Kind { case guardCard, update }
    let id = UUID()
    let kind: Kind
    var bundleID = ""
    var title = ""
    var target: Mode?
    var here: Mode?
    var reason = ""
    var version = ""
    var desktop: Int?
    var snoozeKey = ""

    static func == (a: FocusCard, b: FocusCard) -> Bool { a.id == b.id }
}

struct CardView: View {
    @Environment(PetalApp.self) private var app
    let card: FocusCard

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if card.kind == .update {
                        Image(nsImage: NSApp.applicationIconImage).resizable()
                    } else {
                        Image(nsImage: Apps.icon(card.bundleID)).resizable()
                    }
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    line1
                    line2.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    if !card.reason.isEmpty {
                        Text("✦ " + card.reason).font(.system(size: 11)).foregroundStyle(Color(nsColor: card.target?.color ?? app.accent))
                    }
                }
                Spacer(minLength: 0)
                RoundButton(symbol: "xmark") { app.focus.close(card) }
            }
            HStack(spacing: 8) {
                Button(card.kind == .update ? "Later" : "Go back") { app.focus.stay(card) }
                    .buttonStyle(.glass)
                if card.kind == .update {
                    Button("Restart now") { app.focus.close(card); app.relaunch() }
                        .buttonStyle(.glassProminent).tint(Color(nsColor: app.accent))
                } else if let target = card.target {
                    Button(switchLabel(target)) { app.focus.go(card) }
                        .buttonStyle(.glassProminent).tint(Color(nsColor: target.color))
                }
            }
        }
        .padding(16)
        .frame(minWidth: 330, maxWidth: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(6)
    }

    private func switchLabel(_ target: Mode) -> String {
        let delay = Int(card.here?.focusDelay ?? 0)
        return "Switch to \(target.name)" + (app.config.bool("countdown") && delay > 0 ? " (\(delay)s)" : "")
    }

    @ViewBuilder private var line1: some View {
        switch card.kind {
        case .update:
            Text("Petal updated to \(card.version)").font(.system(size: 13, weight: .bold))
        case .guardCard:
            Text("\(Text(card.title).bold()) belongs to \(card.target?.name ?? "another mode").").font(.system(size: 13))
        }
    }

    @ViewBuilder private var line2: some View {
        switch card.kind {
        case .update:
            Text("Restart Petal to finish (a second or two).")
        case .guardCard:
            Text("This Desktop is in \(card.here?.name ?? "this") mode. Go back to what you were doing, or switch the Desktop to \(card.target?.name ?? "it").")
        }
    }
}
