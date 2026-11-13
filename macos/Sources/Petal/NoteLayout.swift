import CoreGraphics
import Foundation

// The pure side of AI sticky notes (StickyNotes.swift): what a note is stuck to, which notes fit what's in front,
// and telling browser tabs apart; and where a paper of Petal Notes the person moved sits on its window (NoteSpot).
// No AppKit, so macos/checks/run.sh checks it on its own.

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
///   window keeps it, and so does a Petal restart). `shared`: how many tabs of the whole browser (every window) have
///   its address (`NoteRules.sameURL`), itself included; nil when unknown. After the browser restarted (new ids), a
///   tab is found again by its address only when no other tab of the browser has it, now and when the note last saw
///   it, and no other note or kept chat fits it as well (`NoteRules.fitting`).
/// - Safari, Firefox and Zen give tabs no id: `element` stands for the tab's own button in its window's tab strip
///   (an Accessibility element, the same for as long as the tab lives, wherever it moves in its strip and whatever
///   page it shows). It means something only while this Petal runs, so it's never saved, and it's the only way such
///   a tab is found: after Petal or the browser restarts, its chat waits in Chats and opens as a plain chat. A tab
///   dragged to another window gets another button and loses its note. No strip (Safari hides it for a window's only
///   tab): no element. Their `shared` is always nil.
/// - `index`, `count`: its place in its window (1 is the first) and how many tabs the window had.
struct NoteTab: Codable, Equatable, Sendable {
    var id: String?
    var element: Int?
    var index: Int?
    var count: Int?
    var shared: Int?
    var url: String
    var title: String

    init(id: String? = nil, element: Int? = nil, index: Int? = nil, count: Int? = nil, shared: Int? = nil, url: String, title: String) {
        self.id = id
        self.element = element
        self.index = index
        self.count = count
        self.shared = shared
        self.url = url
        self.title = title
    }

    /// `element` is left out: it means nothing once Petal quits.
    enum CodingKeys: String, CodingKey { case id, index, count, shared, url, title }

    /// Petal can tell this tab from every other while the browser runs: by its id or its strip's button.
    var known: Bool { id != nil || element != nil }
}

/// Where the person left a note's paper on its window (Petal Notes; the chat's own panel never moves): tied to the
/// window's nearest corner, so it keeps its spot when the window moves or resizes. `dx`, `dy`: from that corner of the window to the same corner of the note (points,
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

    /// The same, for a paper the person may have left anywhere (`screens`: every screen's visible frame): kept
    /// whole on the screen the spot itself is mostly on, so a note dragged to another screen than its window's stays
    /// there; on none of them (a screen unplugged), on the window's (`screen`).
    func frame(size: CGSize, window: CGRect, screen: CGRect, screens: [CGRect]) -> CGRect {
        let free = frame(size: size, window: window, screen: CGRect(x: -1e7, y: -1e7, width: 2e7, height: 2e7))
        func area(_ visible: CGRect) -> CGFloat { let cut = visible.intersection(free); return cut.isNull ? 0 : cut.width * cut.height }
        let best = screens.max { area($0) < area($1) }
        return frame(size: size, window: window, screen: best.flatMap { area($0) > 0 ? $0 : nil } ?? screen)
    }
}

/// The window a note is stuck to: the app, the window server's number for the window and its title then; for a tab,
/// which tab. Kept with the chat (Chats.swift), so the chat still knows where it was asked. (A chat kept by an earlier
/// Petal may also say `spot`, where its panel was dragged to, and `mode`, the mode it was asked in: no longer read.)
struct NotePlace: Codable, Equatable, Sendable {
    var pid: Int32
    var app: String          // bundle id
    var appName: String
    var window: UInt32?      // CGWindowID; nil for an app with no window
    var title: String
    var desktop: Int?
    /// nil: a window (chats kept before notes could stick to tabs and apps).
    var scope: NoteScope? = nil
    var tab: NoteTab? = nil

    var kind: NoteScope { scope ?? .window }

    /// A tab's note that can be found again once its window closed, its browser quit or Petal restarted: only a
    /// Chromium tab's, by its id (or, after the browser restarted, its address). A Safari, Firefox or Zen tab's
    /// button goes with its window and means nothing to another run of Petal: such a note's chat waits in Chats.
    var tabComesBack: Bool { kind == .tab && tab?.id != nil }

    /// On that window of its app: its own window, or, kept with no window (its app showed none, as Finder on the
    /// desktop), only while its app is known to show none (`none`). A window Petal couldn't read (nil, not `none`) is
    /// no window of its: a note never shows on one by a guess.
    func on(pid other: pid_t, window number: CGWindowID?, none: Bool) -> Bool {
        guard pid == other else { return false }
        if let window { return window == number }
        return number == nil && none
    }

    /// What the note's AI reads and uses (petal_look, petal_ui): its own window; for an app's note, and a tab's that
    /// knows its tab (checked before and after reading), its app's focused window; for a note asked where its app
    /// showed no window (Finder's desktop), nothing: never a window that app shows later.
    var target: NoteTarget {
        if kind == .app { return .focused }
        if let window { return .window(window) }
        return kind == .tab && tab != nil ? .focused : .nothing
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

/// One of a browser's windows as its AppleScript lists it: the browser's own id for it, its scripted name, its frame
/// (top-left origin, as Accessibility counts) and its active tab's title.
struct ScriptedWindow: Equatable, Sendable {
    var id: String
    var name: String
    var frame: CGRect
    var tabTitle: String
}

/// Whether a tab note's own tab is the one its window shows (`NoteRules.tabCheck`).
enum TabCheck: Equatable, Sendable { case same, another, unknown }

/// The same, as a tab note's AI is told it: its tab showing (with that tab as read now and its window's number),
/// another tab showing, or Petal can't tell which, and why: no answer it could be sure of, or the browser hasn't been
/// asked yet whether Petal may see its tabs, or said no.
enum TabShown: Equatable, Sendable {
    enum Unsure: Equatable, Sendable { case unknown, notAsked, refused }

    case shown(tab: NoteTab, window: UInt32)
    case another
    case unsure(Unsure)

    var showing: (tab: NoteTab, window: UInt32)? {
        if case .shown(let tab, let window) = self { return (tab, window) }
        return nil
    }
}

/// The window a note's AI reads and uses: its app's focused one, one window by its number, or none at all.
enum NoteTarget: Equatable, Sendable { case focused, window(UInt32), nothing }

/// A note here (`live`) or a chat kept from before Petal (or the browser) last started, as it may fit what's in
/// front: where it's stuck and its chat.
struct NoteCandidate: Sendable {
    var place: NotePlace
    var chat: UUID?
    var live: Bool
}

/// What's in front, as notes see it: the app, its focused window, and the browser's active tab (nil when it isn't
/// a browser, Petal may not ask it, or it's kept private). `window` nil: no window, when the app said it has none in
/// front (`none`, as Finder on the desktop), else Petal couldn't read it (one still opening, an app slow to answer).
struct FrontPlace: Equatable, Sendable {
    var pid: Int32
    var app: String
    var window: UInt32?
    var tab: NoteTab?
    var none = false

    /// Which window is in front isn't known.
    var unread: Bool { window == nil && !none }
}

enum NoteRules {
    /// The same address: a trailing slash doesn't count, a #fragment does (an app's own pages often differ only by it).
    static func sameURL(_ a: String, _ b: String) -> Bool {
        let x = plain(a, fragment: true), y = plain(b, fragment: true)
        return !x.isEmpty && x == y
    }

    /// How many of the browser's tabs (`urls`: every tab of every window) have the address `url` (`sameURL`, as
    /// matching uses), itself included; nil when unknown: no address, or the listing doesn't have it.
    static func shared(_ url: String, among urls: [String]) -> Int? {
        let count = urls.filter { sameURL($0, url) }.count
        return count > 0 ? count : nil
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

    /// Whether `front` is the note's tab. While the browser runs, only its own id (Chromium) or its own button in
    /// the tab strip (Safari, Firefox, Zen) says so: wherever it moved, whatever page it shows, never another tab on
    /// the same address. A Chromium tab after its browser restarted: only an address no other tab of the browser
    /// has, now and when the note last saw its tab (`byAddress`). Safari, Firefox and Zen tabs never by address.
    static func sameTab(_ note: NoteTab, pid notePID: Int32, _ front: NoteTab, pid frontPID: Int32) -> Bool {
        if notePID == frontPID {
            if let a = note.id, let b = front.id { return a == b }
            if let a = note.element, let b = front.element { return a == b }
            // It has its own id or element, and the tab in front another kind or none: not its tab.
            if note.known { return false }
        }
        return byAddress(note, front)
    }

    /// A Chromium tab found again by its address alone, after its browser restarted: the only tab of the whole
    /// browser with it, as it was when the note last saw its tab, onto a tab with an id of its own.
    static func byAddress(_ note: NoteTab, _ front: NoteTab) -> Bool {
        note.id != nil && front.id != nil && note.shared == 1 && front.shared == 1 && sameURL(note.url, front.url)
    }

    /// Whether a note stuck to `place` belongs on what's in front: for showing it there, or taking it there. A
    /// window's note only on its own window (`NotePlace.on`).
    static func fits(_ place: NotePlace, _ front: FrontPlace) -> Bool {
        switch place.kind {
        case .app:
            return !place.app.isEmpty && place.app == front.app
        case .window:
            return place.on(pid: front.pid, window: front.window, none: front.none)
        case .tab:
            guard let tab = place.tab else { return place.on(pid: front.pid, window: front.window, none: front.none) }
            // A tab read while its window couldn't be (the browser answered, Accessibility didn't): never a match.
            guard let now = front.tab, front.window != nil, place.app == front.app else { return false }
            return sameTab(tab, pid: place.pid, now, pid: front.pid)
        }
    }

    /// A note found on what's in front (`fits`) follows it: an app's note to the window in front (and the app's new
    /// process after it restarted), a tab's to its tab's new address, window and place. A window Petal couldn't read
    /// never replaces the one it knows. `keepWords` false (a private app): no title or address is kept.
    static func adopt(_ place: NotePlace, _ front: FrontPlace, title: String, keepWords: Bool) -> NotePlace {
        var next = place
        switch place.kind {
        case .app:
            next.pid = front.pid
            if !front.unread { next.window = front.window }
        case .tab:
            next.pid = front.pid
            if let window = front.window { next.window = window }
            if let tab = place.tab, let now = front.tab { next.tab = follow(tab, to: now, keepWords: keepWords) }
        case .window:
            break
        }
        if !title.isEmpty, keepWords { next.title = title }
        return next
    }

    /// Of the notes stuck to `places` (nil: stuck to none), the ones that let go of their place (their indices): a
    /// place holds one note, the first to have it, so which note comes back there is never a guess.
    static func letGo(_ places: [NotePlace?]) -> [Int] {
        var taken: [NotePlace] = []
        return places.indices.filter { index in
            guard let place = places[index] else { return false }
            if taken.contains(where: { samePlace($0, place) }) { return true }
            taken.append(place)
            return false
        }
    }

    /// Two notes stuck to the same place, for one letting go of it. Tabs are the same only by their own id
    /// (Chromium) or tab strip's button, in the same run of the browser: two tabs on one address that swapped places
    /// are never one because their window, place and address say so, and a tab known by neither (a Safari chat read
    /// back after Petal restarted) holds no place at all. Windows and apps by their keys.
    static func samePlace(_ a: NotePlace, _ b: NotePlace) -> Bool {
        if a.kind == .tab, b.kind == .tab, let x = a.tab, let y = b.tab {
            guard a.pid == b.pid, a.app == b.app else { return false }
            if let i = x.id, let j = y.id { return i == j }
            if let i = x.element, let j = y.element { return i == j }
            return false
        }
        return key(a) == key(b)
    }

    /// A tab note that fits by the tab's own id or element in the same run of the browser: certain.
    static func surely(_ place: NotePlace, _ front: FrontPlace) -> Bool {
        guard place.kind == .tab, place.pid == front.pid, let tab = place.tab, let now = front.tab else { return false }
        if let a = tab.id, let b = now.id { return a == b }
        if let a = tab.element, let b = now.element { return a == b }
        return false
    }

    /// Of the notes stuck to `places`, the ones that belong on what's in front (their indices in `places`). Tab notes
    /// that fit only by the address (`byAddress`: a Chromium tab after its browser restarted) are taken only when
    /// exactly one does and no note has the tab by its own id or element. A note is never moved onto another note's
    /// tab by a guess.
    static func fitting(_ places: [NotePlace], _ front: FrontPlace) -> [Int] {
        let fit = places.indices.filter { fits(places[$0], front) }
        let tabs = fit.filter { places[$0].kind == .tab && places[$0].tab != nil }
        let weak = tabs.filter { !surely(places[$0], front) }
        guard !weak.isEmpty, weak.count > 1 || weak.count < tabs.count else { return fit }
        return fit.filter { !weak.contains($0) }
    }

    /// Of the notes here and the chats kept from before together, the ones that belong on what's in front (their
    /// indices in `candidates`), told apart together (`fitting`): a note here and a kept chat that fit the same tab
    /// only by a guess are neither taken. A chat is one note: a kept copy of a chat a note here holds is that note.
    static func fitting(_ candidates: [NoteCandidate], _ front: FrontPlace) -> [Int] {
        let kept = unique(candidates)
        return fitting(kept.map { candidates[$0].place }, front).map { kept[$0] }
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

    /// Two frames the same, give or take the 2 points browsers and Accessibility round differently.
    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    /// Which of a browser's windows, as its AppleScript lists them (`rows`), is the window Accessibility calls `title`
    /// at `frame` (Chromium browsers: their script's window id isn't the window server's number). The frame must
    /// match: one window there is that window; among several, the one whose name or active tab's title `title` starts
    /// with (a browser adds its own name after it, " - Google Chrome", and may add a mark to its scripted name while a
    /// tab plays sound, "… 🔊"); anything else, none. Never a guess between two.
    static func scriptedWindow(title: String, frame: CGRect, rows: [ScriptedWindow]) -> Int? {
        let there = rows.indices.filter { sameFrame(rows[$0].frame, frame) }
        if there.count == 1 { return there[0] }
        let named = there.filter { index in
            [rows[index].name, rows[index].tabTitle].contains { !$0.isEmpty && title.hasPrefix($0) }
        }
        return named.count == 1 ? named[0] : nil
    }

    /// What a tab note's own window shows, from the browser's answer (`front`: that window, its tab as the browser
    /// tells it): its own tab (by its id or its strip's button), another tab (the browser told a tab Petal can tell
    /// apart, and it isn't the note's), or not known (a tab Petal can't tell apart, or no tab at all).
    static func tabCheck(_ place: NotePlace, _ front: FrontPlace) -> TabCheck {
        if surely(place, front) { return .same }
        guard place.kind == .tab, place.pid == front.pid, let tab = place.tab, let now = front.tab else { return .unknown }
        if let a = tab.id, let b = now.id, a != b { return .another }
        if tab.id == nil, now.id == nil, let a = tab.element, let b = now.element, a != b { return .another }
        return .unknown
    }

    /// Whether `place`'s window (or, for an app's note, any of its windows) is the one in front, whichever tab shows:
    /// for bringing a note's window forward. `orUnknown`: also while its app is in front and which of its windows
    /// isn't known yet (one still opening): for keeping a note that shows where it is, never for showing one.
    static func sameWindow(_ place: NotePlace, _ front: FrontPlace, orUnknown: Bool = false) -> Bool {
        if place.kind == .app { return !place.app.isEmpty && place.app == front.app }
        return place.on(pid: front.pid, window: front.window, none: front.none) || orUnknown && place.pid == front.pid && front.unread
    }

    /// A window's or a tab's note whose app is in front, when Petal couldn't tell which window is: the window may be
    /// another of the app's (a tab read then is no tab of its), so it doesn't show, but it's kept to come back once
    /// its own window is seen in front (the window's focus event looks again).
    static func windowUnknown(_ place: NotePlace, _ front: FrontPlace) -> Bool {
        place.kind != .app && place.pid == front.pid && front.unread
    }

    /// Whether a note stuck to `place` goes with a window closing (`closed`) or its app quitting (`quit`): a window's
    /// and a tab's do (a tab's may come back with its tab); an app's waits for its app.
    static func gone(_ place: NotePlace, closed window: UInt32? = nil, quit pid: Int32? = nil) -> Bool {
        guard place.kind != .app else { return false }
        if let window, place.window == window { return true }
        if let pid, place.pid == pid { return true }
        return false
    }

    /// A chat picked from the list: whether its place is still there. A Chromium tab's by its id, as the browser
    /// answered (nil, unknown, when it couldn't be asked: its old window still open says nothing of the tab); any
    /// other place by its window still being open.
    static func restoredThere(tabAsked: Bool, tabFound: Bool?, windowOpen: () -> Bool) -> Bool? {
        tabAsked ? tabFound : windowOpen()
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

    /// A kept chat's place, as a key: a window's chat by its window, a tab's by its tab (its id, else its button,
    /// else its window, place and address), an app's by its app.
    static func key(_ place: NotePlace) -> String {
        switch place.kind {
        case .app: return "app|\(place.app)"
        case .window: return "\(place.pid)-\(place.window ?? 0)"
        case .tab:
            let tab = place.tab
            if let id = tab?.id { return "tab|\(place.pid)|\(id)" }
            if let element = tab?.element { return "tab|\(place.pid)|e\(element)" }
            return "tab|\(place.pid)|\(place.window ?? 0)/\(tab?.index ?? 0)|\(tab?.url ?? "")"
        }
    }

    /// The note's tab as it is now: its id or element, place, address and title follow it (a private app's address
    /// and title are never kept). A read that didn't count the tabs sharing its address (`shared` nil) keeps the
    /// count made for the same address; a new address drops it.
    static func follow(_ tab: NoteTab, to front: NoteTab, keepWords: Bool) -> NoteTab {
        var next = tab
        if front.id != nil { next.id = front.id }
        if front.element != nil { next.element = front.element }
        next.index = front.index
        next.count = front.count
        if front.shared != nil || !sameURL(tab.url, front.url) { next.shared = front.shared }
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
