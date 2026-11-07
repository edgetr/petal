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
/// - `twins`: how many tabs in its window have its address (Firefox and Zen: its title), itself included; nil when
///   unknown. Two tabs on the same page are told apart by their place, never by the address.
struct NoteTab: Codable, Equatable, Sendable {
    var id: String?
    var index: Int?
    var count: Int?
    var twins: Int?
    var url: String
    var title: String

    init(id: String? = nil, index: Int? = nil, count: Int? = nil, twins: Int? = nil, url: String, title: String) {
        self.id = id
        self.index = index
        self.count = count
        self.twins = twins
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

    /// On that window of its app: its own window, or, kept with no window (its app showed none), only while its app
    /// shows none. A window Petal couldn't read (nil) is no window of its: a note never shows on one by a guess.
    func on(pid other: pid_t, window number: CGWindowID?) -> Bool {
        pid == other && window == number
    }

    /// Without anything a private app's window or tab said: its title, and its tab's address and title (the tab's
    /// place stays, so the note still knows its tab while the browser runs).
    var scrubbed: NotePlace {
        var place = self
        place.title = ""
        place.tab?.url = ""
        place.tab?.title = ""
        return place
    }
}

/// A note here (`live`) or a chat kept from before Petal (or the browser) last started, as it may fit what's in
/// front: where it's stuck and its chat.
struct NoteCandidate: Sendable {
    var place: NotePlace
    var chat: UUID?
    var live: Bool
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
    /// The same address: a trailing slash doesn't count, a #fragment does (an app's own pages often differ only by it).
    static func sameURL(_ a: String, _ b: String) -> Bool {
        let x = plain(a, fragment: true), y = plain(b, fragment: true)
        return !x.isEmpty && x == y
    }

    /// The same page, whatever its #fragment.
    static func samePage(_ a: String, _ b: String) -> Bool {
        let x = plain(a, fragment: false), y = plain(b, fragment: false)
        return !x.isEmpty && x == y
    }

    private static func plain(_ url: String, fragment keep: Bool) -> String {
        var text = url.trimmingCharacters(in: .whitespaces)
        var fragment = ""
        if let hash = text.firstIndex(of: "#") {
            fragment = String(text[text.index(after: hash)...])
            text = String(text[..<hash])
        }
        while text.hasSuffix("/") { text.removeLast() }
        return keep && !fragment.isEmpty && !text.isEmpty ? text + "#" + fragment : text
    }

    /// Whether `front` is the note's tab. `previous`: the tab its window showed the last time Petal looked, which
    /// tells a tab that went to another address (same place, as many tabs, a new address) from another tab.
    static func sameTab(_ note: NoteTab, pid notePID: Int32, window noteWindow: UInt32?,
                        _ front: NoteTab, pid frontPID: Int32, window frontWindow: UInt32?, previous: NoteTab?) -> Bool {
        let samePlace = note.index != nil && note.index == front.index
        // The browser restarted since: ids and windows are new, the address finds it; when several tabs have it,
        // its place too (a restored window keeps its tabs in order).
        guard notePID == frontPID else { return sameURL(note.url, front.url) && ((front.twins ?? 1) <= 1 || samePlace) }
        if let a = note.id, let b = front.id { return a == b }
        // No ids: a tab belongs to its window.
        guard noteWindow == nil || frontWindow == nil || noteWindow == frontWindow else { return false }
        if sameURL(note.url, front.url) {
            // The only tab with that address (a tab before it closed, or one opened, moved it), or in its place.
            return onlyOne(front) || samePlace
        }
        // Only its #fragment changed, in its place among as many tabs.
        if samePlace, note.count == front.count, samePage(note.url, front.url) { return true }
        // It went to another address while it was the tab showing: the same place, as many tabs as before.
        guard samePlace, let previous, previous.index == note.index,
              sameURL(previous.url, note.url), previous.count == front.count else { return false }
        return true
    }

    /// No other tab in its window has its address: as far as Petal can tell (a browser that says nothing of its
    /// tabs' places has only the address to go by).
    private static func onlyOne(_ tab: NoteTab) -> Bool {
        if let twins = tab.twins { return twins <= 1 }
        return tab.index == nil
    }

    /// Whether a note stuck to `place` belongs on what's in front: for showing it there, or taking it there. A
    /// window's note only on its own window (`NotePlace.on`).
    static func fits(_ place: NotePlace, _ front: FrontPlace, previous: NoteTab? = nil) -> Bool {
        switch place.kind {
        case .app:
            return !place.app.isEmpty && place.app == front.app
        case .window:
            return place.on(pid: front.pid, window: front.window)
        case .tab:
            guard let tab = place.tab else { return place.on(pid: front.pid, window: front.window) }
            guard let now = front.tab, place.app == front.app else { return false }
            return sameTab(tab, pid: place.pid, window: place.window, now, pid: front.pid, window: front.window, previous: previous)
        }
    }

    /// Of the notes stuck to `places`, the ones that belong on what's in front (their indices in `places`). Tab notes
    /// that fit only by the address (one tab with it closed or went elsewhere, and the one left has it alone, or a
    /// restarted browser restored it in several windows) can't be told apart: when more than one does, only the one
    /// still in its place among as many tabs counts, and if that isn't exactly one, none; and none when a note has
    /// the tab by its own id. A note is never moved onto another note's tab by a guess.
    static func fitting(_ places: [NotePlace], _ front: FrontPlace, previous: NoteTab? = nil) -> [Int] {
        let fit = places.indices.filter { fits(places[$0], front, previous: previous) }
        // A Chromium tab's own id, in the same run of the browser, is certain.
        let tabs = fit.filter { places[$0].kind == .tab && places[$0].tab != nil }
        let sure = tabs.filter { places[$0].pid == front.pid && places[$0].tab?.id != nil && places[$0].tab?.id == front.tab?.id }
        let weak = tabs.filter { !sure.contains($0) }
        if !sure.isEmpty { return fit.filter { !weak.contains($0) } }
        guard weak.count > 1 else { return fit }
        let inPlace = weak.filter { i in
            guard let tab = places[i].tab, let now = front.tab, let index = tab.index else { return false }
            return index == now.index && tab.count != nil && tab.count == now.count
        }
        let kept = inPlace.count == 1 ? inPlace : []
        return fit.filter { !weak.contains($0) || kept.contains($0) }
    }

    /// Of the notes here and the chats kept from before together, the ones that belong on what's in front (their
    /// indices in `candidates`), told apart together (`fitting`): a note here and a kept chat that fit the same tab
    /// only by a guess are neither taken. A chat is one note: a kept copy of a chat a note here holds is that note.
    static func fitting(_ candidates: [NoteCandidate], _ front: FrontPlace, previous: NoteTab? = nil) -> [Int] {
        let kept = unique(candidates)
        return fitting(kept.map { candidates[$0].place }, front, previous: previous).map { kept[$0] }
    }

    /// One candidate per chat (their indices, in order): a note here over a kept copy of its chat, else the first.
    static func unique(_ candidates: [NoteCandidate]) -> [Int] {
        let held = Set(candidates.filter(\.live).compactMap(\.chat))
        var seen = Set<UUID>()
        return candidates.indices.filter { i in
            guard let chat = candidates[i].chat else { return true }
            if !candidates[i].live, held.contains(chat) { return false }
            return seen.insert(chat).inserted
        }
    }

    /// Which of a window's tabs (`urls`, in order) to show for a note's tab, when the browser knows tabs only by
    /// place and address (Safari): the one tab with its address; of several, the one in its place; with none, its
    /// place only when the window still has as many tabs and that tab is on its page (only its #fragment changed).
    /// `missing`: no tab there could be it.
    enum TabChoice: Equatable { case at(Int), missing, unsure }

    static func choose(_ tab: NoteTab, urls: [String]) -> TabChoice {
        guard !urls.isEmpty else { return .unsure }
        let same = urls.indices.filter { sameURL(urls[$0], tab.url) }.map { $0 + 1 }
        if same.count == 1 { return .at(same[0]) }
        if same.count > 1 {
            guard let index = tab.index, same.contains(index) else { return .unsure }
            return .at(index)
        }
        if let index = tab.index, let count = tab.count, count == urls.count, urls.indices.contains(index - 1) {
            // Only its #fragment changed, in its place among as many tabs: it's the tab there. Another address there
            // may be it gone elsewhere, or another tab (it closed and one opened): no guess.
            return samePage(urls[index - 1], tab.url) ? .at(index) : .unsure
        }
        // No address kept (a private app's): nothing to say it's gone.
        return tab.url.isEmpty ? .unsure : .missing
    }

    /// Two frames the same, give or take the 2 points browsers and Accessibility round differently.
    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    /// Whether `place`'s window (or, for an app's note, any of its windows) is the one in front, whichever tab shows:
    /// for bringing a note's window forward. `orUnknown`: also while its app is in front and which of its windows
    /// isn't known yet (one still opening): for keeping a note that shows where it is, never for showing one.
    static func sameWindow(_ place: NotePlace, _ front: FrontPlace, orUnknown: Bool = false) -> Bool {
        if place.kind == .app { return !place.app.isEmpty && place.app == front.app }
        return place.on(pid: front.pid, window: front.window) || orUnknown && place.pid == front.pid && front.window == nil
    }

    /// A window's note (or a tab's that knows no tab) whose app is in front, when Petal couldn't tell which window
    /// is: it neither shows nor steps away until the window is known (the window's focus event looks again).
    static func windowUnknown(_ place: NotePlace, _ front: FrontPlace) -> Bool {
        (place.kind == .window || place.tab == nil) && place.kind != .app && place.pid == front.pid && front.window == nil
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
        next.twins = front.twins
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
