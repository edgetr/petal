import CoreGraphics
import Foundation

// The pure side of AI sticky notes (StickyNotes.swift): what a note is stuck to, which notes fit what's in front,
// telling browser tabs apart, and where a note moved by the person sits on its window. No AppKit, so
// macos/checks/run.sh checks it on its own.

/// What a note is stuck to: one browser tab, one window, or every window of an app ("All of Slack").
enum NoteScope: String, Codable, Sendable, CaseIterable {
    case tab, window, app

    /// The more specific wins when several notes fit what's in front: a tab's, then its window's, then its app's.
    var rank: Int {
        switch self {
        case .tab: 0
        case .window: 1
        case .app: 2
        }
    }
}

/// One browser tab, as far as Petal can tell it apart from the others.
/// - Chromium browsers: `id`, the tab's own id, which lasts as long as the browser runs (a tab dragged to another
///   window keeps it); after the browser restarts, the address finds it again.
/// - Safari, Firefox and Zen give tabs no id: `index` is the tab's place in its window (1 is the first) and `count`
///   how many tabs the window had, with the address. A tab dragged to another window loses its note.
struct NoteTab: Codable, Equatable, Sendable {
    var id: String?
    var index: Int?
    var count: Int?
    var url: String
    var title: String

    init(id: String? = nil, index: Int? = nil, count: Int? = nil, url: String, title: String) {
        self.id = id
        self.index = index
        self.count = count
        self.url = url
        self.title = title
    }
}

/// Where the person left a note on its window: tied to the window's nearest corner, so it keeps its spot when the
/// window moves or resizes. `dx`, `dy`: from that corner of the window to the same corner of the note (points,
/// y going up, as AppKit's screen coordinates).
struct NoteSpot: Codable, Equatable, Sendable {
    enum Corner: String, Codable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
        var right: Bool { self == .topRight || self == .bottomRight }
        var top: Bool { self == .topLeft || self == .topRight }
    }

    var corner: Corner
    var dx: Double
    var dy: Double

    static func point(_ corner: Corner, of rect: CGRect) -> CGPoint {
        CGPoint(x: corner.right ? rect.maxX : rect.minX, y: corner.top ? rect.maxY : rect.minY)
    }

    /// The note at `panel`, stuck to the corner of `window` nearest its centre.
    static func stick(panel: CGRect, window: CGRect) -> NoteSpot {
        let right = panel.midX > window.midX
        let top = panel.midY > window.midY
        let corner: Corner = top ? (right ? .topRight : .topLeft) : (right ? .bottomRight : .bottomLeft)
        let a = point(corner, of: window), b = point(corner, of: panel)
        return NoteSpot(corner: corner, dx: Double(b.x - a.x), dy: Double(b.y - a.y))
    }

    /// The note's frame at `size` on `window`, kept whole on `screen` (the window's screen). Its stuck corner stays
    /// put as it grows: stuck by a top corner it grows down, by a bottom one up.
    func frame(size: CGSize, window: CGRect, screen: CGRect) -> CGRect {
        let a = Self.point(corner, of: window)
        let b = CGPoint(x: a.x + CGFloat(dx), y: a.y + CGFloat(dy))
        var x = corner.right ? b.x - size.width : b.x
        var y = corner.top ? b.y - size.height : b.y
        x = min(max(x, screen.minX), max(screen.minX, screen.maxX - size.width))
        // Too tall for the screen: its top stays on it (the header, where it's dragged).
        y = min(max(y, screen.minY), screen.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height).integral
    }
}

/// The window a note is stuck to: the app, the window server's number for the window, its title then, and the mode
/// it was asked in; for a tab, which tab; and, once the person moved it, where on the window. Kept with the chat
/// (Chats.swift), so the chat still knows where it was asked and a note comes back where it was left.
struct NotePlace: Codable, Equatable, Sendable {
    var pid: Int32
    var app: String          // bundle id
    var appName: String
    var window: UInt32?      // CGWindowID; nil for an app with no window
    var title: String
    var mode: String         // the mode's id
    var desktop: Int?
    /// nil: a window (chats kept before notes could stick to tabs and apps).
    var scope: NoteScope? = nil
    var tab: NoteTab? = nil
    /// nil until the person moves it: it opens over the dock.
    var spot: NoteSpot? = nil

    var kind: NoteScope { scope ?? .window }

    func matches(pid other: pid_t, window number: CGWindowID?) -> Bool {
        pid == other && (window == nil || number == nil || window == number)
    }
}

/// What's in front, as notes see it: the app, its focused window, and the browser's active tab (nil when it isn't
/// a browser, Petal may not ask it, or it's kept private).
struct FrontPlace: Equatable, Sendable {
    var pid: Int32
    var app: String
    var window: UInt32?
    var tab: NoteTab?
}

enum NoteRules {
    /// The same address: a #fragment and a trailing slash don't count.
    static func sameURL(_ a: String, _ b: String) -> Bool {
        func plain(_ url: String) -> String {
            var text = url.trimmingCharacters(in: .whitespaces)
            if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        let x = plain(a), y = plain(b)
        return !x.isEmpty && x == y
    }

    /// Whether `front` is the note's tab. `previous`: the tab its window showed the last time Petal looked, which
    /// tells a tab that went to another address (same place, as many tabs, a new address) from another tab.
    static func sameTab(_ note: NoteTab, pid notePID: Int32, window noteWindow: UInt32?,
                        _ front: NoteTab, pid frontPID: Int32, window frontWindow: UInt32?, previous: NoteTab?) -> Bool {
        // The browser restarted since: ids and windows are new, the address finds it.
        guard notePID == frontPID else { return sameURL(note.url, front.url) }
        if let a = note.id, let b = front.id { return a == b }
        // No ids: a tab belongs to its window.
        guard noteWindow == nil || frontWindow == nil || noteWindow == frontWindow else { return false }
        if sameURL(note.url, front.url) { return true }
        // It went to another address while it was the tab showing: the same place, as many tabs as before.
        guard let index = note.index, front.index == index, let previous, previous.index == index,
              sameURL(previous.url, note.url), previous.count == front.count else { return false }
        return true
    }

    /// Whether a note stuck to `place` belongs on what's in front.
    static func fits(_ place: NotePlace, _ front: FrontPlace, previous: NoteTab? = nil) -> Bool {
        switch place.kind {
        case .app:
            return !place.app.isEmpty && place.app == front.app
        case .window:
            return place.matches(pid: front.pid, window: front.window)
        case .tab:
            guard let tab = place.tab else { return place.matches(pid: front.pid, window: front.window) }
            guard let now = front.tab, place.app == front.app else { return false }
            return sameTab(tab, pid: place.pid, window: place.window, now, pid: front.pid, window: front.window, previous: previous)
        }
    }

    /// Whether `place`'s window (or, for an app's note, any of its windows) is the one in front, whichever tab shows:
    /// for bringing a note's window forward.
    static func sameWindow(_ place: NotePlace, _ front: FrontPlace) -> Bool {
        place.kind == .app ? !place.app.isEmpty && place.app == front.app : place.matches(pid: front.pid, window: front.window)
    }

    /// Of the notes that fit what's in front, the one shown: the most specific; between equals, the one showing.
    static func pick<T>(_ notes: [T], scope: (T) -> NoteScope, showing: (T) -> Bool) -> T? {
        notes.enumerated().min { a, b in
            let ra = scope(a.element).rank, rb = scope(b.element).rank
            if ra != rb { return ra < rb }
            let sa = showing(a.element), sb = showing(b.element)
            if sa != sb { return sa }
            return a.offset < b.offset
        }?.element
    }

    /// A kept chat's place, as a key: a window's chat by its window, a tab's by its tab, an app's by its app.
    static func key(_ place: NotePlace) -> String {
        switch place.kind {
        case .app: return "app|\(place.app)"
        case .window: return "\(place.pid)-\(place.window ?? 0)"
        case .tab:
            let tab = place.tab
            return "tab|\(place.pid)|" + (tab?.id ?? "\(place.window ?? 0)/\(tab?.index ?? 0)|\(tab?.url ?? "")")
        }
    }

    /// The note's tab as it is now: its place, address and title follow it (a private app's are never kept).
    static func follow(_ tab: NoteTab, to front: NoteTab, keepWords: Bool) -> NoteTab {
        var next = tab
        if front.id != nil { next.id = front.id }
        next.index = front.index
        next.count = front.count
        if keepWords {
            next.url = front.url
            next.title = front.title
        }
        return next
    }

    /// An Accessibility frame (top-left origin, y going down) in AppKit's screen coordinates (bottom-left, y up).
    static func appKitFrame(_ frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// The screen a window is on: the one it covers most (else the first).
    static func screen(for window: CGRect, in screens: [CGRect]) -> CGRect? {
        func covered(_ screen: CGRect) -> CGFloat {
            let part = screen.intersection(window)
            return part.isNull ? 0 : part.width * part.height
        }
        let best = screens.max { covered($0) < covered($1) }
        return (best.map(covered) ?? 0) > 0 ? best : screens.first
    }
}
