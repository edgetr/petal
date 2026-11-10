import AppKit
import SwiftUI

// The note pad in the dock, the paper that comes off it, and what picks a paper up on the screen.
//
// Making a note is physical: a pad of paper sits by the AI button; a click takes a sheet for what's in front, a drag
// takes one anywhere. A paper on the screen is picked up from anywhere on it that isn't a control or the writing
// being edited, and stays where it's let go (NoteDesk.moved).

// MARK: - The pad

/// The note pad, as its own button by the AI button and Finder's (`notesPad`, while `notes` is on): a small stack of
/// paper in the default notebook's color on clear glass. A click makes a blank note on
/// what's in front, open to write in (as ⌃⌥N does); a drag takes a paper off it, and wherever that's let go the note
/// is made, stuck to the window under it at that spot, else on that Desktop (holding Option: on the screen itself).
/// A surface to click never moves or grows on hover: nothing here does.
struct NotePadButton: View {
    @Environment(PetalApp.self) private var app
    let dock: ScreenDock
    let size: CGFloat
    @State private var pressed = false

    static let tip = "New note · drag it anywhere"

    var body: some View {
        NotePadMark(color: app.paper.store.color(of: app.paper.defaultNotebook))
            .frame(width: size * 0.6, height: size * 0.6)
            .frame(width: size, height: size)
            .clearGlass(in: .circle, pressed: pressed)
            .slotFrame(dock, DockView.padSlot)
            .slotMouse(SlotMouse(left: {
                                     app.popups.closeAll()
                                     app.tooltips.hide()
                                     app.paper.newHere()
                                 },
                                 right: { Menus.notePad() },
                                 hover: { on in app.tooltips.show(on ? Self.tip : nil, over: DockView.padSlot, in: dock) },
                                 drag: { _, ended in
                                     app.tooltips.hide()
                                     app.paper.dragPaper(ended: ended)
                                 },
                                 press: { pressed = $0 }))
    }
}

/// The pad's picture: a small stack of paper squares, each a step down and right of the one above, the top one
/// paper in its notebook's color with the strip a note has on top and its folded corner.
struct NotePadMark: View {
    let color: NSColor

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let tint = PaperLook.rgb(color)
            let step = max(1.5, side * 0.1)
            let sheet = side - step * 2
            let radius = sheet * 0.16
            ZStack(alignment: .topLeading) {
                self.sheet(NoteInk.mix(tint, 0.5, NoteInk.paper), radius: radius).frame(width: sheet, height: sheet).offset(x: step * 2, y: step * 2)
                self.sheet(NoteInk.mix(tint, 0.32, NoteInk.paper), radius: radius).frame(width: sheet, height: sheet).offset(x: step, y: step)
                self.sheet(NoteInk.paper(tint), radius: radius)
                    .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: color)).frame(height: max(2, sheet * 0.15)) }
                    .overlay(alignment: .bottomTrailing) { FoldCorner().fill(Color.black.opacity(0.18)).frame(width: sheet * 0.3, height: sheet * 0.3) }
                    .clipShape(.rect(cornerRadius: radius))
                    .frame(width: sheet, height: sheet)
            }
            .frame(width: side, height: side, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sheet(_ fill: NoteInk.RGB, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius).fill(PaperLook.color(fill))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5) }
    }
}

extension Menus {
    /// The note pad's menu: a note here, the Petal Notes window, and the pad itself.
    static func notePad() {
        let app = PetalApp.shared
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "New note here") { app.paper.newHere() })
        menu.addItem(ClosureMenuItem(title: "Open Petal Notes") { app.notesWindow.show() })
        menu.addItem(.separator())
        menu.addItem(toggle("Show the note pad", app.config.bool("notesPad")) { app.config.set("notesPad", !app.config.bool("notesPad")) })
        app.tooltips.hide()
        app.previews.hold(true)   // none behind the menu, nor one that was about to open
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        app.previews.hold(false)
    }
}

// MARK: - The paper being dragged

/// The blank paper that follows the pointer out of the note pad (or the AI button): where it's let go, the note is
/// made. Holding Option it says the note will stay on the screen.
struct PaperGhost: View {
    let color: NSColor
    /// Option is held: let go now, it's kept on the screen itself.
    let kept: Bool

    static let paper: CGFloat = 72
    /// Room around the paper in its panel, for its shadow and its tilt.
    static let margin: CGFloat = 14
    static let size = NSSize(width: 150, height: 132)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .top) {
                PaperLook.color(NoteInk.paper(PaperLook.rgb(color)))
                Rectangle().fill(Color(nsColor: color)).frame(height: 4)
            }
            .overlay(alignment: .bottomTrailing) { FoldCorner().fill(Color.black.opacity(0.13)).frame(width: 14, height: 14) }
            .frame(width: Self.paper, height: Self.paper).clipShape(.rect(cornerRadius: 8)).modifier(PaperShadow(glass: false))
            .rotationEffect(.degrees(-4)).opacity(0.92)
            Text("Stays on screen").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color(.sRGB, red: 0.08, green: 0.08, blue: 0.1, opacity: 0.8), in: .rect(cornerRadius: 7))
                .fixedSize()
                .opacity(kept ? 1 : 0)
        }
        .padding(Self.margin)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }
}

// MARK: - Picking a paper up

/// The paper itself, under its words and controls and over its own surface: an AppKit view, so a drag is the mouse's
/// own events (the paper moves by exactly what the pointer moves, from the first event), a first click on a paper
/// that hasn't the keyboard already picks it up, and the pointer over it is an open hand. A control on the paper
/// (the letterhead's two buttons, the folded corner, a card's) and the editor take their own clicks: they're above it.
struct PaperGrab: NSViewRepresentable {
    weak var panel: NotePanel?
    /// A click that didn't move it: a folded paper opens.
    var tap: (() -> Void)?

    func makeNSView(context: Context) -> GrabView { GrabView() }

    func updateNSView(_ view: GrabView, context: Context) {
        view.panel = panel
        view.tap = tap
    }

    final class GrabView: NSView {
        weak var panel: NotePanel?
        var tap: (() -> Void)?
        private var down: NSPoint?
        private var dragging = false
        private var area: NSTrackingArea?
        /// The pointer shows the open hand now (set by this view).
        private var hand = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            // Always: a paper is picked up whichever app is in front, and whether or not it has the keyboard.
            let new = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(new)
            area = new
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { point(nil) }
        }

        override func mouseEntered(with event: NSEvent) { point(event) }
        override func mouseMoved(with event: NSEvent) { point(event) }
        override func cursorUpdate(with event: NSEvent) { point(event) }
        override func mouseExited(with event: NSEvent) { if !dragging { point(nil) } }

        /// The pointer's shape for where it is: the open hand over the paper itself; over a control above it, the
        /// arrow again; over the writing, the text's own.
        private func point(_ event: NSEvent?) {
            guard !dragging else { return }
            guard let event, let window, window.alphaValue > 0, let content = window.contentView else { return show(.away) }
            let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
            if hit === self { return show(.paper) }
            show(hit is NSTextView ? .writing : .away)
        }

        private enum Over { case paper, writing, away }

        private func show(_ over: Over) {
            switch over {
            case .paper:
                hand = true
                PaperCursor.take(self)
                NSCursor.openHand.set()
            case .writing, .away:
                guard hand else { return }
                hand = false
                (over == .writing ? NSCursor.iBeam : NSCursor.arrow).set()
                PaperCursor.leave(self)
            }
        }

        /// Another paper has the pointer now, or this one was hidden under it: this one no longer shows the hand.
        func lost() { hand = false }

        override func mouseDown(with event: NSEvent) {
            down = NSEvent.mouseLocation
            dragging = false
            panel?.grab()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down else { return }
            let now = NSEvent.mouseLocation
            if !dragging, abs(now.x - down.x) > 3 || abs(now.y - down.y) > 3 {
                dragging = true
                hand = true
                PaperCursor.take(self)
                NSCursor.closedHand.set()
            }
            if dragging { panel?.drag() }
        }

        override func mouseUp(with event: NSEvent) {
            let moved = dragging
            down = nil
            dragging = false
            if moved {
                panel?.dragEnded()
                point(event)
            } else {
                panel?.released()
                tap?()
            }
        }
    }
}

/// The pointer's shape while another app is in front. Petal is a background app, and macOS lets only the app in
/// front set the pointer; the window server's own switch for that ("SetsCursorInBackground", a connection property,
/// as other background apps with things to pick up use it) is looked up at run time, turned on only while the
/// pointer is on a paper and off again as it leaves. A macOS without it leaves the pointer an arrow: nothing else
/// depends on it.
@MainActor
enum PaperCursor {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    nonisolated(unsafe) private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    nonisolated private static let mainConnection: MainConnection? = symbol("SLSMainConnectionID")
    nonisolated private static let setProperty: SetProperty? = symbol("SLSSetConnectionProperty")

    nonisolated private static func symbol<T>(_ name: String) -> T? {
        guard let skyLight, let pointer = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// The paper the pointer is on (the one whose hand shows), if any.
    private static weak var holder: PaperGrab.GrabView?

    /// The pointer is on `view`'s paper: Petal may set the pointer though another app is in front.
    static func take(_ view: PaperGrab.GrabView) {
        guard holder !== view else { return }
        holder?.lost()
        let had = holder != nil
        holder = view
        if !had { background(true) }
    }

    /// The pointer left `view`'s paper.
    static func leave(_ view: PaperGrab.GrabView) {
        guard holder === view else { return }
        holder = nil
        background(false)
    }

    /// A paper hidden (NSPanel.conceal) with the pointer on it: the arrow again, and the switch off.
    static func hidden(_ window: NSWindow) {
        guard let view = holder, view.window === window else { return }
        view.lost()
        holder = nil
        NSCursor.arrow.set()
        background(false)
    }

    private static func background(_ on: Bool) {
        guard !Headless.on, let mainConnection, let setProperty else { return }
        let connection = mainConnection()
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    }
}
