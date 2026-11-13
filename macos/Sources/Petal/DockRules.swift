import CoreGraphics
import Foundation

/// The dock's own decisions about a click, as rules without AppKit (checked by checks/DockRulesCheck.swift).
enum DockRules {
    /// One of the clicked app's windows, as the click weighs it: `rank` 0 on this Desktop's screen, 1 minimized,
    /// 2 anywhere else; `number` the window server's number for it (it stays with the window while it lives), when
    /// known; `title` its title.
    struct Window: Equatable {
        var rank: Int
        var number: UInt32?
        var title: String
        var minimized = false
    }

    /// Which window a click on an app's icon brings forward, from its windows front to back as the app lists them.
    /// The app not in front (`active` false): its frontmost window on this Desktop, else a minimized one, else the
    /// rest. The app in front: the one after the window in front (`focused`, known by its number, else by its title)
    /// in an order that doesn't change as windows come forward (by rank, then number), so clicking again goes
    /// through every window and back to the first. Nil when it has none.
    static func pick(_ windows: [Window], active: Bool, focused: UInt32?, focusedTitle: String) -> Int? {
        let front = windows.indices.sorted { (windows[$0].rank, $0) < (windows[$1].rank, $1) }
        guard active, !windows.isEmpty else { return front.first }
        let around = windows.indices.sorted { (windows[$0].rank, windows[$0].number ?? .max, $0) < (windows[$1].rank, windows[$1].number ?? .max, $1) }
        let inFront = around.firstIndex { index in
            let window = windows[index]
            guard !window.minimized else { return false }
            if let focused, let number = window.number { return number == focused }
            return window.title == focusedTitle
        }
        guard let inFront else { return front.first }
        return around[(inFront + 1) % around.count]
    }

    // MARK: Which running apps show

    /// A running app that isn't one of the dock's own, as the dock weighs it: its windows anywhere (minimized and
    /// on other Desktops too), whether one is on this screen's Desktop, how many are minimized, and whether it's
    /// hidden.
    struct Running: Equatable {
        var id: String
        var windows = 0
        var here = false
        var minimized = 0
        var hidden = false
    }

    /// Whether it shows. Every running app does; with "only from the current Desktop" (`thisDesktopOnly`), all
    /// but one whose windows are all on another Desktop. Hidden, only minimized or with no window at all, it
    /// stays: it's still running, and the dock is the way back to it.
    static func shows(_ app: Running, thisDesktopOnly: Bool) -> Bool {
        guard thisDesktopOnly else { return true }
        return app.here || app.hidden || app.minimized > 0 || app.windows == 0
    }

    /// The running apps the dock lists after its own, in the order they first showed this session (`kept`), new
    /// ones after them in the order given.
    static func others(_ running: [Running], kept: [String], thisDesktopOnly: Bool) -> [String] {
        let showing = running.filter { shows($0, thisDesktopOnly: thisDesktopOnly) }.map(\.id)
        return kept.filter { showing.contains($0) } + showing.filter { !kept.contains($0) }
    }

    /// How bright an app's dot is: every running app has one, full when a window of it is here or it's in front,
    /// fainter otherwise (no window, or only elsewhere); none for an app that isn't running.
    static func dot(running: Bool, here: Bool, active: Bool) -> Double {
        guard running else { return 0 }
        return here || active ? 1 : 0.4
    }

    // MARK: Dragging an app

    /// The pointer this far past the glass, inward, is out of the dock: more than a slot, as macOS's Dock. Where
    /// the pointer is, whatever the app.
    static func isOut(inward: Double, slot: Double) -> Bool { inward > slot }

    /// Whether a dragged app looks out of the dock (faint, the others closing its gap): only one of the dock's own,
    /// which letting go there removes. How it looks never decides what letting go does (`dragEnd`).
    static func fades(inward: Double, slot: Double, kept: Bool) -> Bool { kept && isOut(inward: inward, slot: slot) }

    enum DragEnd: Equatable {
        case click             // it never really moved: the click it started as
        case move(to: Int)     // to another place in the dock
        case remove            // taken out of the dock
        case nothing           // out of the dock, but not one of its own
    }

    /// What letting go of a dragged app does. `began`: the drag got as far as moving it along the dock (or out);
    /// `offset` how far along, `slot` one slot's length, `inward` how far past the glass the pointer is as it's let go
    /// (the dock's panel's `inward(of:)`), `kept` whether it's one of the dock's own. Out of the dock, one of its own
    /// is removed and any other app is left as it was; in it, a wobble is still a click, and only moving an app to
    /// another place keeps it.
    static func dragEnd(began: Bool, from: Int, offset: Double, slot: Double, count: Int, kept: Bool, inward: Double) -> DragEnd {
        guard began else { return .click }
        if isOut(inward: inward, slot: slot) { return kept ? .remove : .nothing }
        let to = min(max(0, from + Int((offset / max(1, slot)).rounded())), max(0, count - 1))
        return to != from ? .move(to: to) : .click   // let go in its own slot: the click it started as
    }

    // MARK: Where the dock takes the mouse

    /// Whether the dock's panel takes the mouse at `point` (panel coordinates, top-left origin), from the glass as
    /// it's drawn now: the glass, out to the panel's edge on the screen's side (the panel runs to the screen's edge,
    /// and every point between the glass and the edge is the dock's), and `inward` past it for icons drawn grown or
    /// lifted over it. Anywhere else the click goes to what's under the panel.
    static func takesMouse(_ point: CGPoint, glass: CGRect, panel: CGSize, position: String, inward: CGFloat) -> Bool {
        guard glass.width > 0, glass.height > 0 else { return false }
        let area: CGRect = switch position {
        case "left": CGRect(x: 0, y: glass.minY, width: glass.maxX + inward, height: glass.height)
        case "right": CGRect(x: glass.minX - inward, y: glass.minY, width: panel.width - glass.minX + inward, height: glass.height)
        default: CGRect(x: glass.minX, y: glass.minY - inward, width: glass.width, height: panel.height - glass.minY + inward)
        }
        return area.contains(point)
    }

    /// The dock's glass growing or shrinking: SwiftUI draws it from where it was drawn (`from`) to its new layout
    /// (`to`) along an ease-out of `duration` seconds, while its layout already says `to`.
    struct GlassMove: Equatable {
        var from: CGRect
        var to: CGRect
        var start: Double
        var duration: Double

        /// Where the glass is drawn `now`.
        func at(_ now: Double) -> CGRect {
            let t = duration > 0 ? min(1, max(0, (now - start) / duration)) : 1
            let p = DockRules.easeOut(t)
            return CGRect(x: from.minX + (to.minX - from.minX) * p, y: from.minY + (to.minY - from.minY) * p,
                          width: from.width + (to.width - from.width) * p, height: from.height + (to.height - from.height) * p)
        }

        func done(at now: Double) -> Bool { now - start >= duration }
    }

    /// A glass moving from `old` to `new` (both layouts, panel coordinates) animates when it only grew or shrank
    /// around the same middle (an app, a minimized window or the player came or went); moved or laid out anew (another
    /// position, icon size or screen), it's drawn where it is at once. `drawn` is where the last move had got to.
    static func glassMove(from old: CGRect, drawn: CGRect, to new: CGRect, now: Double, duration: Double) -> GlassMove? {
        guard old.width > 0, old.height > 0, new.width > 0, new.height > 0, old != new,
              abs(old.midX - new.midX) < 1, abs(old.midY - new.midY) < 1,
              abs(old.width - new.width) < 1 || abs(old.height - new.height) < 1 else { return nil }
        return GlassMove(from: drawn, to: new, start: now, duration: duration)
    }

    /// Core Animation's and SwiftUI's ease-out: the cubic Bézier (0, 0), (0.58, 1), at `t` of the way in time.
    static func easeOut(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        // x(s) = 3(1-s)s²·0.58 + s³ (the first control point is at 0); solve x(s) = t by bisection, then y(s).
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let s = (low + high) / 2
            let x = 3 * (1 - s) * s * s * 0.58 + s * s * s
            if x < t { low = s } else { high = s }
        }
        let s = (low + high) / 2
        return 3 * (1 - s) * (1 - s) * s + 3 * (1 - s) * s * s + s * s * s
    }

    // MARK: Dropped on the dock

    enum Dropped: Equatable {
        case app(String)        // an app's path: added to the dock
        case folder(String)     // a folder's path: a stack
        case site(String)       // a web address: a website shortcut
        case document(String)   // a file: opened with the app it's dropped on
    }

    /// What one dropped item is: an app (a folder ending in .app), a folder, a web address, or a document.
    static func dropped(path: String?, web: String?, isDirectory: Bool) -> Dropped? {
        if let web { return .site(web) }
        guard let path else { return nil }
        if path.lowercased().hasSuffix(".app") { return .app(path) }
        return isDirectory ? .folder(path) : .document(path)
    }

    /// What a drop does: apps, folders and web addresses dropped together are added to the dock; documents are
    /// opened with the app they're dropped on (`onApp`), never an app "with" another app. Nil: nothing to do.
    enum DropAction: Equatable {
        case add([Dropped])
        case open([String])
    }

    static func drop(_ items: [Dropped], onApp: Bool) -> DropAction? {
        let documents = items.compactMap { if case .document(let path) = $0 { path } else { nil } }
        let additions = items.filter { if case .document = $0 { false } else { true } }
        if !additions.isEmpty && (documents.isEmpty || !onApp) { return .add(additions) }
        if onApp && !documents.isEmpty { return .open(documents) }
        return nil
    }

    // MARK: Windows kept clear of the dock

    /// The frame `f` keeps clear of a dock reaching `reach` in from `screen`'s edge (both top-left origin).
    /// `moved`: it got there by being moved at its own size (not opened or resized there): it's moved back out at
    /// that size where it fits, rather than shortened.
    static func clear(_ f: CGRect, screen: CGRect, reach: CGFloat, position: String, moved: Bool = false) -> CGRect {
        if moved {
            switch position {
            case "left":
                let limit = screen.minX + reach
                if f.minX < limit - 1, f.maxX > limit, limit + f.width <= screen.maxX { return f.offsetBy(dx: limit - f.minX, dy: 0) }
            case "right":
                let limit = screen.maxX - reach
                if f.maxX > limit + 1, f.minX < limit, limit - f.width >= screen.minX { return f.offsetBy(dx: limit - f.maxX, dy: 0) }
            default:
                let limit = screen.maxY - reach
                if f.maxY > limit + 1, f.minY < limit, limit - f.height >= screen.minY + 30 { return f.offsetBy(dx: 0, dy: limit - f.maxY) }
            }
        }
        switch position {
        case "left":
            let limit = screen.minX + reach
            guard f.minX < limit - 1, f.maxX > limit else { return f }
            return f.maxX - limit >= 300 ? CGRect(x: limit, y: f.minY, width: f.maxX - limit, height: f.height)
                : CGRect(x: limit, y: f.minY, width: f.width, height: f.height)
        case "right":
            let limit = screen.maxX - reach
            guard f.maxX > limit + 1, f.minX < limit else { return f }
            return limit - f.minX >= 300 ? CGRect(x: f.minX, y: f.minY, width: limit - f.minX, height: f.height)
                : CGRect(x: limit - f.width, y: f.minY, width: f.width, height: f.height)
        default:
            let limit = screen.maxY - reach
            guard f.maxY > limit + 1, f.minY < limit else { return f }
            return limit - f.minY >= 200 ? CGRect(x: f.minX, y: f.minY, width: f.width, height: limit - f.minY)
                : CGRect(x: f.minX, y: max(screen.minY + 30, limit - f.height), width: f.width, height: f.height)
        }
    }

    /// A screen's dock, as keeping windows clear of it needs it: the screen (top-left origin), how far the dock
    /// reaches in from its edge, and whether a full-screen app shows there (nothing is kept clear then).
    struct ClearDock: Equatable {
        var screen: CGRect
        var reach: CGFloat
        var fullScreen = false
    }

    /// A window kept clear of the dock: its own frame from before, how it got into the dock's strip, what Petal last
    /// asked of it and the frames it has had since through Petal (the ones Petal gave it, where it was moving from,
    /// where the app let it go). Kept until the window closes or the person moves it, so a look at the windows from a
    /// moment before a move never mistakes Petal's frame for theirs.
    struct Cleared {
        var before: CGRect
        /// It got into the strip by being moved at its own size: it's moved back out, every look, not shortened.
        var moved: Bool
        /// The frame Petal last asked for, whether that was the way out for a window the app kept bigger, and where
        /// the app let the window go when asked (nil while the move is on its way).
        var asked: CGRect?
        var askedFallback = false
        var answer: CGRect?
        /// The app kept the window bigger than Petal asked (a minimum size): what was asked and where it stayed.
        var refusal: (asked: CGRect, answer: CGRect)?
        /// The frames it has had through Petal (where it was moving from, the frames asked for, where the app let it
        /// go) since a look last found it where the app put it with no move on its way: all a look a moment old can
        /// show. Older ones are forgotten then, so the person moving it near a frame Petal gave it before is still
        /// the person's.
        private(set) var frames: [CGRect] = []
        /// Moves asked for that haven't landed yet.
        private(set) var inFlight = 0

        init(before: CGRect, moved: Bool) {
            self.before = before
            self.moved = moved
        }

        func knows(_ frame: CGRect) -> Bool {
            before.equalTo(frame, within: 4) || frames.contains { $0.equalTo(frame, within: 4) }
        }

        mutating func saw(_ frame: CGRect) {
            guard !knows(frame) else { return }
            frames.append(frame)
        }

        /// A new ask, from where it is now.
        mutating func ask(_ target: CGRect, from now: CGRect, fallback: Bool) {
            saw(now)
            saw(target)
            asked = target
            askedFallback = fallback
            answer = nil
            inFlight += 1
        }

        /// A look found it at `now`: once every move landed and it's where the app put it, the frames before are
        /// done with.
        mutating func settled(at now: CGRect) {
            guard inFlight == 0, let answer, answer.equalTo(now, within: 4) else { return }
            frames = [answer]
        }

        /// A move landed at `actual` (nil: it didn't happen).
        mutating func landed(_ to: CGRect, at actual: CGRect?) {
            inFlight = max(0, inFlight - 1)
            let latest = asked.map { $0.equalTo(to, within: 0.5) } ?? false
            if let actual { saw(actual) }
            guard latest else { return }   // an older ask, overtaken by this one
            if let actual {
                answer = actual
                if !actual.equalTo(to, within: 2), !askedFallback { refusal = (to, actual) }
            } else {
                asked = nil
            }
        }
    }

    /// What keeping windows clear of the dock remembers between looks at the windows (Dock.swift's
    /// `keepWindowsClear` does the moves through Accessibility).
    ///
    /// Each look decides every window from its frame before Petal touched it, so windows never shrink step by step
    /// as the dock moves around, and asks for a frame once: a look from a moment before the move landed, or an app
    /// that keeps its window bigger than asked, never makes Petal ask again and again. A window the app kept bigger
    /// is moved out at the size it kept, where that fits. A window moved into the strip at its own size stays moved
    /// out, look after look, never shortened later.
    struct ClearLedger {
        private(set) var cleared: [UInt32: Cleared] = [:]
        /// Every window's frame at the last look: one that comes into the dock's strip at the same size was moved there.
        private(set) var lastFrames: [UInt32: CGRect] = [:]

        struct Move: Equatable {
            var number: UInt32
            var from: CGRect
            var to: CGRect
        }

        /// Nothing to give back.
        var isEmpty: Bool { cleared.isEmpty }

        /// One look: the windows on screen now (top-left origin), the numbers of every window that still exists, each
        /// screen's dock, whether keeping clear is on, and where the dock sits. Returns the moves to make.
        mutating func look(_ windows: [(number: UInt32, frame: CGRect)], alive: Set<UInt32>, docks: [ClearDock], on: Bool,
                           position: String) -> [Move] {
            var moves: [Move] = []
            for window in windows {
                let number = window.number, now = window.frame
                var before = now
                // Where it was as last seen: at the last look (which may have been a moment old), or any frame it had
                // through Petal lately.
                var previous = [lastFrames[number]]
                if let record = cleared[number] {
                    previous += record.frames.map(Optional.some) + [record.answer, record.asked]
                    // A frame Petal gave it, or one it had on the way (the look may be a moment old): still Petal's
                    // doing. Any other frame is the person's.
                    if record.knows(now) {
                        before = record.before
                        cleared[number]?.settled(at: now)
                    } else {
                        cleared[number] = nil
                    }
                }
                var record = cleared[number]
                // Moved there at its own size since it was last seen (dragged down past the dock), or remembered as moved.
                let moved = record?.moved ?? previous.contains { frame in
                    frame.map { !$0.equalTo(now, within: 1) && abs($0.width - now.width) < 2 && abs($0.height - now.height) < 2 } ?? false
                }
                var target = before
                var fallback = false
                let center = CGPoint(x: before.midX, y: before.midY)
                if on, let dock = docks.first(where: { $0.screen.contains(center) }), !dock.fullScreen {
                    target = DockRules.clear(before, screen: dock.screen, reach: dock.reach, position: position, moved: moved)
                    // The app wouldn't take that size: out at the size it kept, where that fits.
                    if let refusal = record?.refusal, refusal.asked.equalTo(target, within: 2) {
                        target = DockRules.clear(refusal.answer, screen: dock.screen, reach: dock.reach, position: position, moved: true)
                        fallback = true
                    }
                }
                let moving = !target.equalTo(now, within: 2)
                guard moving || record != nil || !target.equalTo(before, within: 1) else { continue }
                if record == nil { record = Cleared(before: before, moved: moved) }
                // Asked for already: while the move is on its way, or where the app let it go, it stands. (Elsewhere,
                // back at its old frame say, it's asked again.)
                let asked = record!.asked.map { $0.equalTo(target, within: 2) } ?? false
                let standing = asked && (record!.answer.map { $0.equalTo(now, within: 2) } ?? true)
                if moving, !standing {
                    record!.ask(target, from: now, fallback: fallback)
                    moves.append(Move(number: number, from: now, to: target))
                }
                cleared[number] = record
            }
            // Windows that closed: nothing to give back.
            cleared = cleared.filter { alive.contains($0.key) }
            lastFrames = Dictionary(windows.map { ($0.number, $0.frame) }, uniquingKeysWith: { a, _ in a })
            return moves
        }

        /// Where the app let a window go after Petal asked for `asked` (it may keep a minimum size), which is now
        /// Petal's frame for it. Nil: the move didn't happen (the window had moved meanwhile, or the app didn't
        /// answer), so the next look weighs it again.
        mutating func landed(_ number: UInt32, asked: CGRect, at actual: CGRect?) {
            if let actual { lastFrames[number] = actual }
            cleared[number]?.landed(asked, at: actual)
        }
    }
}

/// Two frames within `tolerance` points of each other on every side and size.
extension CGRect {
    func equalTo(_ other: CGRect, within tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) < tolerance && abs(minY - other.minY) < tolerance
            && abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}
