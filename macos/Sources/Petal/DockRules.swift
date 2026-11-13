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
}
