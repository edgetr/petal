import AppKit
import SwiftUI

/// Selecting text in any app (`selectionAsk`): a small glass "Ask Petal AI" button comes up by the selection, the
/// way T3 Code offers to cite a passage; clicking it brings the text into the chat as a quote. macOS lets no app put
/// its own item in another app's right-click menu (Services, under their own submenu, is the only door, and stays),
/// so this is the button by the selection instead. It goes as soon as you click elsewhere, type or scroll, and by
/// itself after a few seconds. Never in apps kept private, never for a password field.
@MainActor
final class SelectionAsk {
    private let panel: GlassPanel = {
        let panel = GlassPanel(level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1))
        panel.interactive = true
        return panel
    }()
    private var monitors: [Any] = []
    private var down: (point: NSPoint, at: Date)?
    private var found: (text: String, source: String)?
    private var hideLater: DispatchWorkItem?
    private var looking = 0
    nonisolated private static let queue = DispatchQueue(label: "petal.selection", qos: .userInitiated)

    var app: PetalApp { PetalApp.shared }

    func start() {
        let handle: (NSEvent) -> Void = { [weak self] event in MainActor.assumeIsolated { self?.event(event) } }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown, .scrollWheel], handler: handle) {
            monitors.append(monitor)
        }
    }

    private func event(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            down = (NSEvent.mouseLocation, Date())
            hide()
        case .leftMouseUp:
            guard app.config.bool("selectionAsk"), let down else { return }
            let mouse = NSEvent.mouseLocation
            let dragged = hypot(mouse.x - down.point.x, mouse.y - down.point.y) > 6
            // A drag across text, or a double or triple click (a word, a line).
            guard dragged || event.clickCount >= 2 else { return }
            look(near: mouse)
        default:
            hide()
        }
    }

    /// Reads the selection in the app in front (off the main thread: the app may be slow to answer).
    private func look(near mouse: NSPoint) {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !app.assist.neverLook(front.bundleIdentifier), Windows.trusted else { return }
        looking += 1
        let ticket = looking
        let pid = front.processIdentifier
        let source = front.localizedName ?? ""
        Self.queue.asyncAfter(deadline: .now() + 0.06) {
            let selection = Self.selection(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ticket == self.looking, let selection else { return }
                    self.found = (selection.text, source)
                    self.show(at: selection.bounds, mouse: mouse)
                }
            }
        }
    }

    /// The selected text in the focused element of `pid`, and where it is on screen (Cocoa coordinates) if the app
    /// says. Nothing from a password field.
    nonisolated private static func selection(pid: pid_t) -> (text: String, bounds: CGRect?)? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        guard let focused: AXUIElement = Windows.value(appElement, kAXFocusedUIElementAttribute) else { return nil }
        if (Windows.value(focused, kAXSubroleAttribute) as String?) == kAXSecureTextFieldSubrole as String { return nil }
        guard let text: String = Windows.value(focused, kAXSelectedTextAttribute) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 20000 else { return nil }
        var bounds: CGRect?
        if let range: AXValue = Windows.value(focused, kAXSelectedTextRangeAttribute) {
            var raw: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute as CFString, range, &raw) == .success,
               let value = raw, CFGetTypeID(value) == AXValueGetTypeID() {
                var rect = CGRect.zero
                AXValueGetValue(value as! AXValue, .cgRect, &rect)
                if rect.width > 1, rect.height > 1 {
                    let top = NSScreen.screens.first?.frame.maxY ?? 0
                    bounds = CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
                }
            }
        }
        return (trimmed, bounds)
    }

    private func show(at bounds: CGRect?, mouse: NSPoint) {
        // Just above the selection's end, else just above the pointer.
        let anchor = bounds.map { CGRect(x: $0.maxX - 2, y: $0.maxY, width: 2, height: 2) } ?? CGRect(x: mouse.x, y: mouse.y + 10, width: 2, height: 2)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        panel.show(SelectionButton(note: app.paper.on, ask: { [weak self] in self?.ask() }, write: { [weak self] in self?.note() }), near: anchor, on: screen)
        hideLater?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func ask() {
        guard let found else { return hide() }
        app.claude.quote(found.text, from: found.source)
        app.claude.open(asking: nil)
        hide()
    }

    /// "Note": a new Petal Note on the selected sentence (its page or file), open to write in.
    private func note() {
        guard let found else { return hide() }
        hide()
        app.paper.note(on: found.text)
    }

    private func hide() {
        hideLater?.cancel()
        looking += 1   // a look still on its way is for a selection that's gone
        found = nil
        panel.hide()
    }
}

extension GlassPanel {
    /// Just above `anchor` (Cocoa coordinates), kept on `screen`.
    func show<Content: View>(_ content: Content, near anchor: CGRect, on screen: NSScreen) {
        show(content, over: anchor, dock: nil, gap: 4)
        var frame = self.frame
        frame.origin.x = min(max(anchor.midX - frame.width / 2, screen.visibleFrame.minX + 4), screen.visibleFrame.maxX - frame.width - 4)
        frame.origin.y = min(anchor.maxY + 4, screen.visibleFrame.maxY - frame.height - 4)
        setFrame(frame, display: true)
    }
}

/// The small buttons by a selection: Note (with Petal Notes on) and Ask Petal AI.
private struct SelectionButton: View {
    let note: Bool
    let ask: () -> Void
    let write: () -> Void
    @State private var hovering: String?

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                if note {
                    pill("note", action: write) {
                        Image(systemName: "note.text").font(.system(size: 11, weight: .medium))
                        Text("Note").font(.system(size: 12, weight: .medium))
                    }
                }
                pill("ask", action: ask) {
                    ProviderMark(provider: PetalApp.shared.chatProvider).frame(width: 13, height: 13)
                    Text("Ask Petal AI").font(.system(size: 12, weight: .medium))
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .padding(4)
    }

    private func pill<Label: View>(_ id: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { label() }
                .padding(.horizontal, 11).frame(height: 26)
                .glassEffect(.regular.interactive(), in: .capsule)
                .scaleEffect(hovering == id ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 ? id : (hovering == id ? nil : hovering) }
    }
}
