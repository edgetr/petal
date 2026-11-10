import CoreGraphics
import Foundation

/// A hidden display for each Petal AI run (`runDisplays`): the pure side, checked by macos/checks/run.sh. Who gets a
/// display and who waits (`RunDisplayPlan`), how many the Mac can spare, where one goes so the person's pointer can't
/// wander onto it, which displays are the person's screens, and what happens to a window a run leaves behind.
/// RunDisplay.swift makes the displays and moves the windows; nothing here touches the screen.
enum RunDisplayRules {
    /// A run's display, in points.
    static let size = CGSize(width: 1440, height: 900)

    /// The most displays any Mac gets at once.
    static let most = 4
    /// One display for every this much physical memory.
    static let memoryEach: UInt64 = 8 * 1024 * 1024 * 1024

    /// How many run displays may exist at once: one per 8 GB of physical memory, at least 1, at most 4. `setting`
    /// (`runDisplaysLimit`) only ever lowers it; 0 or less, or anything above what the memory gives, is the memory's.
    static func limit(memory: UInt64, setting: Int) -> Int {
        let byMemory = max(1, min(most, Int(memory / memoryEach)))
        return setting >= 1 ? min(setting, byMemory) : byMemory
    }

    /// Who shares a display: a helper in a note and everything that note starts (a second opinion) are the note; a
    /// chat and an AI session outside Petal are themselves (their subagents call Petal through the same session).
    static func group(caller: String, paper: String?) -> String {
        if let paper, !paper.isEmpty { return "note-" + paper }
        return caller
    }

    /// Where a tool's window goes: the run's own display, or the person's screen.
    enum Place: String, Equatable { case display, screen }

    /// Who's asking, for the default place.
    enum Asker: Equatable {
        /// The quick question: the person is there, and asked for it themselves.
        case chat
        /// A helper in a note: it works while the person does something else.
        case helper
        /// An AI session outside Petal (T3 Code, a terminal).
        case outside
    }

    /// `asked`: the tool's `on` ("display", "screen", anything else is none). With `runDisplays` off, or where
    /// displays can't be made, always the person's screen. A helper and an AI session outside Petal work on their own
    /// display unless they say the person's screen; the quick question opens on the person's screen (they asked for it,
    /// and are looking) unless it says its own display.
    static func place(asked: String?, on: Bool, asker: Asker) -> Place {
        guard on else { return .screen }
        if let asked, let place = Place(rawValue: asked.lowercased()) { return place }
        return asker == .chat ? .screen : .display
    }

    /// What opening something for a run's display would do, known before anything opens.
    enum Opening: Equatable {
        /// A new window results, which is moved to the display.
        case go
        /// A browser that's already open takes an address as a tab in one of the person's own windows, in front of
        /// them: nothing is opened (a browser of the run's own is not built yet).
        case tabInTheirs
        /// The app is already open and only it was asked for: nothing new would show, and the person's windows are
        /// never moved.
        case nothingNew
    }

    /// `running`: the app is open already; `windows`: how many windows it has; `address`: an http(s) address is being
    /// opened; `browser`: the app is a browser; `bare`: only the app was asked for (no file, no address).
    static func opening(running: Bool, windows: Int, address: Bool, browser: Bool, bare: Bool) -> Opening {
        guard running, windows > 0 else { return .go }
        if bare { return .nothingNew }
        if address && browser { return .tabInTheirs }
        return .go
    }

    // MARK: Where a display goes

    /// Two rectangles share a stretch of edge longer than a point: the pointer could cross there.
    static func sharesEdge(_ a: CGRect, _ b: CGRect) -> Bool { sharedEdge(a, b) > 0.5 }

    /// How long a stretch of edge two rectangles share (0: none, or only a corner): what the pointer could cross.
    static func sharedEdge(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let overlapX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let sideBySide = abs(a.maxX - b.minX) < 0.5 || abs(b.maxX - a.minX) < 0.5
        let stacked = abs(a.maxY - b.minY) < 0.5 || abs(b.maxY - a.minY) < 0.5
        return max(sideBySide ? max(0, overlapY) : 0, stacked ? max(0, overlapX) : 0)
    }

    /// Overlapping by more than a sliver.
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let both = a.intersection(b)
        return !both.isNull && both.width > 0.5 && both.height > 0.5
    }

    /// A display here is out of the pointer's reach: it overlaps none of the person's screens and shares no stretch
    /// of edge with any (a corner alone may touch), and overlaps no other run display.
    static func hiddenFrom(_ frame: CGRect, screens: [CGRect], others: [CGRect]) -> Bool {
        for screen in screens where overlaps(frame, screen) || sharesEdge(frame, screen) { return false }
        for other in others where overlaps(frame, other) { return false }
        return true
    }

    /// Where a new display of `size` may go (its top-left, in the window server's coordinates: the main screen's
    /// top-left is 0,0 and y grows downward), best first: diagonal to a corner of one of the person's `screens` (the
    /// main one first), touching it only at that corner; then beside a run display already there (`taken`), away
    /// from the person's screens. Never beside the person's screen. Empty: nowhere.
    static func origins(size: CGSize, screens: [CGRect], taken: [CGRect]) -> [CGPoint] {
        var candidates: [CGPoint] = []
        for screen in screens {
            // Below and right first: the corner macOS was seen to keep a display at (27.3). Then the other three.
            candidates.append(CGPoint(x: screen.maxX, y: screen.maxY))
            candidates.append(CGPoint(x: screen.minX - size.width, y: screen.maxY))
            candidates.append(CGPoint(x: screen.maxX, y: screen.minY - size.height))
            candidates.append(CGPoint(x: screen.minX - size.width, y: screen.minY - size.height))
        }
        for other in taken {
            candidates.append(CGPoint(x: other.minX - size.width, y: other.minY))
            candidates.append(CGPoint(x: other.maxX, y: other.minY))
            candidates.append(CGPoint(x: other.minX, y: other.minY - size.height))
            candidates.append(CGPoint(x: other.minX, y: other.maxY))
        }
        var found: [CGPoint] = []
        for point in candidates where !found.contains(point) {
            let frame = CGRect(origin: point, size: size)
            // It must still touch something (macOS keeps displays together): a corner of a screen, or a run display.
            let touches = (screens + taken).contains { other in
                other.insetBy(dx: -0.5, dy: -0.5).intersects(frame)
            }
            if touches, hiddenFrom(frame, screens: screens, others: taken) { found.append(point) }
        }
        return found
    }

    static func origin(size: CGSize, screens: [CGRect], taken: [CGRect]) -> CGPoint? {
        origins(size: size, screens: screens, taken: taken).first
    }

    // MARK: The person's screens

    /// The displays that are the person's screens: every one that isn't a run's. Everything Petal shows the person
    /// (the dock, notes, cards, the pointer) and everything it takes for "the screen" goes by this.
    static func persons<ID: Hashable>(_ displays: [ID], runs: Set<ID>) -> [ID] {
        displays.filter { !runs.contains($0) }
    }

    /// A window is on a run's display when its middle is inside that display's frame (the window server's coordinates).
    static func display<ID>(holding window: CGRect, among displays: [(id: ID, frame: CGRect)]) -> ID? {
        let middle = CGPoint(x: window.midX, y: window.midY)
        return displays.first { $0.frame.contains(middle) }?.id
    }

    /// Where a window goes on a display: its own size when it fits, else the display's, less a small margin; placed
    /// from the top-left, each next one a little down and right (`index`).
    static func frame(for window: CGSize, on display: CGRect, index: Int = 0) -> CGRect {
        let margin: CGFloat = 24
        let room = display.insetBy(dx: margin, dy: margin)
        let width = min(max(window.width, 200), room.width)
        let height = min(max(window.height, 150), room.height)
        let step = CGFloat(index % 6) * 28
        let x = min(room.minX + step, room.maxX - width)
        let y = min(room.minY + step, room.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: What a run leaves behind

    /// A window a run put on its display, as it is when the run ends.
    struct Left: Equatable {
        /// The run opened it (it wasn't there before the run's open): never a window the person had.
        var opened: Bool
        /// The run made the window empty (a new blank document or tab) and nothing was put in it since: no file, no
        /// address, no text, not edited.
        var empty: Bool
        /// The person took it to their screen (Show me), or moved it off the display themselves.
        var shown: Bool
    }

    enum Leftover: Equatable {
        /// Closed with its display: an empty window the run made, with nothing in it to lose.
        case close
        /// Brought back to the person's main screen before the display goes, so it's never lost with it.
        case bringBack
        /// Already on the person's screen: left alone.
        case leave
    }

    /// When a run ends, each window still on its display: one that's the run's own and empty is closed (nothing is
    /// lost, nothing asked); anything else (a document, a page, anything with work in it, anything Petal can't tell
    /// is empty) is brought back to the person's main screen, behind what they're doing, never closed. A window they
    /// already took to their screen is left where it is.
    static func leftover(_ window: Left) -> Leftover {
        if window.shown { return .leave }
        return window.opened && window.empty ? .close : .bringBack
    }

    // MARK: Words

    /// What the AI is told when the private classes aren't there, or macOS refused.
    static let unavailable = "This Mac can't make a hidden display for Petal AI (macOS didn't allow it), so there's none to work on. Pass on: \"screen\" to open it on the person's screen instead, if they'd want that."
    static let off = "Hidden displays for Petal AI's runs are off (runDisplays in Petal's settings); only the person turns them on."
}

/// Who has a display and who waits for one. A run joins a group (`RunDisplayRules.group`); a group gets a display the
/// first time one of its runs needs to put a window on the screen, never before, and keeps it until its last run
/// ends. Past the limit a group waits in order and gets the next display freed. Leaving twice does nothing.
struct RunDisplayPlan: Equatable {
    enum Standing: Equatable {
        /// No display, and not waiting for one.
        case none
        /// Waiting, with this many ahead of it plus one (1: next).
        case waiting(Int)
        case has
    }

    /// What the plan's change means for the screens: RunDisplay.swift does it.
    enum Effect: Equatable {
        /// Make a display for this group (it has one now, in the plan).
        case make(String)
        /// Remove this group's display: its last run ended.
        case remove(String)
    }

    private(set) var limit: Int
    /// Each run's group.
    private(set) var members: [String: String] = [:]
    /// Groups with a display, in the order they got one.
    private(set) var holding: [String] = []
    /// Groups waiting for one, in order.
    private(set) var queue: [String] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func standing(of group: String) -> Standing {
        if holding.contains(group) { return .has }
        if let index = queue.firstIndex(of: group) { return .waiting(index + 1) }
        return .none
    }

    func group(of run: String) -> String? { members[run] }
    func runs(in group: String) -> [String] { members.filter { $0.value == group }.keys.sorted() }

    /// A run exists and belongs to `group`: it shares whatever display the group has or gets. Nothing is made.
    /// A run that was in another group leaves that one first.
    mutating func join(_ run: String, group: String) -> [Effect] {
        if members[run] == group { return [] }
        let effects = leave(run)
        members[run] = group
        return effects
    }

    /// A run is about to put a window on the screen: its group has a display, gets one now (`make`), or waits.
    mutating func need(_ run: String, group: String) -> (standing: Standing, effects: [Effect]) {
        var effects = join(run, group: group)
        if holding.contains(group) { return (.has, effects) }
        if let index = queue.firstIndex(of: group) { return (.waiting(index + 1), effects) }
        if holding.count < limit, queue.isEmpty {
            holding.append(group)
            effects.append(.make(group))
            return (.has, effects)
        }
        queue.append(group)
        return (.waiting(queue.count), effects)
    }

    /// A run ended (done, failed, stopped, paused, its note thrown away): with it the last of its group, the group's
    /// display is removed and the next group waiting gets one; a group that was only waiting stops waiting.
    mutating func leave(_ run: String) -> [Effect] {
        guard let group = members.removeValue(forKey: run) else { return [] }
        guard !members.values.contains(group) else { return [] }
        return drop(group, removing: true)
    }

    /// Every run of a group ended at once.
    mutating func end(group: String) -> [Effect] {
        let had = members.contains { $0.value == group }
        members = members.filter { $0.value != group }
        guard had || holding.contains(group) || queue.contains(group) else { return [] }
        return drop(group, removing: true)
    }

    /// A group's display couldn't be made, or went by itself (macOS took it): the group has none, its runs stay, and
    /// the next waiting group gets its turn. Nothing to remove.
    mutating func lost(group: String) -> [Effect] {
        guard holding.contains(group) else { return [] }
        return drop(group, removing: false)
    }

    /// Everything ends (`runDisplays` turned off, Petal quitting): every display is removed, nobody waits.
    mutating func endAll() -> [Effect] {
        let effects = holding.map { Effect.remove($0) }
        members = [:]
        holding = []
        queue = []
        return effects
    }

    /// The limit changed. Raised: the next ones waiting get displays. Lowered: nothing is taken from a run at work;
    /// the ones waiting wait until enough have ended.
    mutating func setLimit(_ limit: Int) -> [Effect] {
        self.limit = max(1, limit)
        return promote()
    }

    private mutating func drop(_ group: String, removing: Bool) -> [Effect] {
        var effects: [Effect] = []
        if let index = holding.firstIndex(of: group) {
            holding.remove(at: index)
            if removing { effects.append(.remove(group)) }
        }
        queue.removeAll { $0 == group }
        return effects + promote()
    }

    private mutating func promote() -> [Effect] {
        var effects: [Effect] = []
        while holding.count < limit, !queue.isEmpty {
            let next = queue.removeFirst()
            holding.append(next)
            effects.append(.make(next))
        }
        return effects
    }
}
