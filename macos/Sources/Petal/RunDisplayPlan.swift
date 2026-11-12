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

    /// Whether an ask for an app takes its turn behind another run. `hold`: an open on the asker's own display.
    /// The quick question acting in an app is the person's own request, in front of them, and their use of an app
    /// always wins: it never waits behind a helper. Everything else takes turns.
    static func takesTurns(asker: Asker, hold: Bool) -> Bool { hold || asker != .chat }

    /// What opening something for a run's display would do, known before anything opens.
    enum Opening: Equatable {
        /// A new window results, which is moved to the display.
        case go
        /// A browser that's already open takes an address as a tab in one of the person's own windows, in front of
        /// them: nothing is opened (the run's own browser is the way: petal_browser).
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

    /// The process an open for a run's display started, for that run to put away when it ends; nil where it started
    /// none. `wasRunning`: the person had the app open before. `answered`: the process macOS says took the open.
    /// `runs`: that process is a run's own browser (the same app as the person's, as a second process), which is
    /// its own run's and never another's to quit. `persons`: the person's copies of the app now, for where macOS
    /// named none.
    static func started(wasRunning: Bool, answered: Int32?, runs: (Int32) -> Bool, persons: [Int32]) -> Int32? {
        guard !wasRunning else { return nil }
        if let answered { return runs(answered) ? nil : answered }
        return persons.first { !runs($0) }
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
        /// Its app is one the run started and the person then used: theirs now, so nothing of it is closed.
        var theirs = false
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
    /// already took to their screen is left where it is, and one in an app that became theirs comes back to them
    /// even when empty.
    static func leftover(_ window: Left) -> Leftover {
        if window.shown { return .leave }
        return window.opened && window.empty && !window.theirs ? .close : .bringBack
    }

    /// Something Petal read of an app or a window: yes, no, or it couldn't be read (an error, a timeout), which is
    /// never taken for no.
    enum Told: Equatable { case yes, no, unknown }

    /// A window holds nothing to keep. `document`: it shows a file or an address; `modified`: it says it has unsaved
    /// changes (a kind of window that never says is `no`). Anything that couldn't be read holds something. A dialog
    /// or panel with no document behind it (an Open panel, a welcome window: `panel`) is nothing to keep whatever it
    /// was opened with; an ordinary window only when the run opened it `bare` (no file, no address) and did nothing
    /// in it since (`changed`).
    static func holdsNothing(bare: Bool, changed: Bool, panel: Bool, document: Told, modified: Told) -> Bool {
        guard document == .no, modified == .no else { return false }
        if panel { return true }
        return bare && !changed
    }

    /// Whether an app has unsaved changes, from its windows: `listed`: its windows could be read at all; `modified`:
    /// what each says. One that says yes is yes; else one that couldn't be read is unknown; else no.
    static func unsaved(listed: Bool, modified: [Told]) -> Told {
        guard listed else { return .unknown }
        if modified.contains(.yes) { return .yes }
        return modified.contains(.unknown) ? .unknown : .no
    }

    // MARK: An app a run started

    /// An app a run's open touched, as it is when the run ends.
    struct LeftApp: Equatable {
        /// The run's own open started it: it wasn't running before. Never true of an app the person had open.
        var launched: Bool
        /// The person used it since (`personUsed`).
        var used: Bool
        /// One of its windows was taken to the person's screen: Show me, or the run's own petal_windows show.
        var shown: Bool
        /// It has unsaved changes Petal can read (`unsaved`).
        var unsaved: Told
    }

    enum AppLeftover: Equatable {
        /// Asked to quit, politely: the run started it, nobody used it, and it holds nothing unsaved.
        case quit
        /// Left running: its windows follow `leftover`.
        case keep
    }

    /// An app the run started is the run's to put away: when the run ends it's asked to quit, unless the person used
    /// it since, one of its windows was brought to their screen, or it has unsaved changes. When Petal can't tell
    /// whether it has (`unknown`), it's kept and its windows come back. An app the person already had open is never
    /// quit. An app that's kept, or doesn't quit in time (`quitBound`: it asked to save, say), has its windows
    /// settled one by one (`leftover`).
    static func leftover(app: LeftApp) -> AppLeftover {
        guard app.launched, !app.used, !app.shown, app.unsaved == .no else { return .keep }
        return .quit
    }

    /// Whose an app is, when a run asks to quit, hide or bring it forward (petal_apps).
    enum AppOwner: Equatable {
        /// The person's: they had it open, or used it since a run started it.
        case persons
        /// The asking run started it, on its own display, and nobody used it since.
        case own
        /// Another run started it, on its display, and nobody used it since.
        case another
    }

    enum AppAnswer: Equatable {
        case go
        /// The person is asked first.
        case ask
        case refuse
    }

    /// An app another run started is none of this one's: nothing of it is quit, hidden or brought forward. A run's
    /// own, which the person never saw, quits without asking them (it's the run's to put away) and never comes
    /// forward (nothing on a hidden display does). The person's app is as always: quitting asks them first.
    static func apps(_ action: String, owner: AppOwner) -> AppAnswer {
        switch owner {
        case .another: return .refuse
        case .own: return action == "focus" ? .refuse : .go
        case .persons: return action == "quit" ? .ask : .go
        }
    }

    /// How long an app asked to quit has to go, before its windows are settled as if it had been kept.
    static let quitBound: TimeInterval = 3

    /// How Petal knows the person used an app a run started, from what it can observe. Petal itself never brings a
    /// run's app forward (its opens don't activate, and nothing on a hidden display is raised), so:
    /// - the app came to the front within a moment (`byHand`) of the person's last key, click or scroll: they
    ///   switched to it (the Dock, ⌘Tab, a click on its window, Show me). One that comes forward while the person's
    ///   hands are still did so by itself, which is nobody's use;
    /// - or, while it was in front, the person pressed a key, clicked or scrolled (`usedInFront`), whoever brought it.
    /// Both go by the hardware's own times (keys Petal posts never count). Typing elsewhere at the very moment an
    /// app comes forward by itself reads as use: the app is then kept, never the other way round.
    static let byHand: TimeInterval = 1.5

    /// `idle`: seconds since the person's last key, click or scroll, read as the app came to the front.
    static func cameForwardByPerson(idle: TimeInterval) -> Bool { idle <= byHand }

    /// `idle`: seconds since the person's last key, click or scroll, read while the app is in front; `frontFor`: how
    /// long it has been. Their last input came after it did.
    static func usedInFront(idle: TimeInterval, frontFor: TimeInterval) -> Bool { idle < frontFor }

    static func personUsed(idleAtFront: TimeInterval?, idleNow: TimeInterval?, frontFor: TimeInterval?) -> Bool {
        if let idleAtFront, cameForwardByPerson(idle: idleAtFront) { return true }
        if let idleNow, let frontFor, usedInFront(idle: idleNow, frontFor: frontFor) { return true }
        return false
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

/// Two runs, one app: they take turns. Most Mac apps run once, with one set of menus, one keyboard focus and one
/// window in front, so a second run in an app a first one is using on its display would act on the first one's
/// windows, or open its own among them. A run holds an app while it has windows of it on its display (or started it);
/// another run that asks to open something in that app, or to act in it, waits in order and gets it when the holder
/// ends or lets it go. Reads never wait (and never show another run's window). A group is who shares a display
/// (`RunDisplayRules.group`); an app is its bundle identifier.
struct AppTurns: Equatable {
    enum Standing: Equatable {
        /// It may go ahead now.
        case has
        /// Another run has the app: waiting, with this many ahead of it plus one (1: next).
        case waiting(Int)
        /// Waiting would never end: the run that has the app is itself waiting for one this run has. Nothing waits.
        case circular
    }

    /// The next in line has the app now.
    struct Grant: Equatable {
        let app: String
        let group: String
    }

    /// Who has each app.
    private(set) var holders: [String: String] = [:]
    /// Who waits for each, in order.
    private(set) var queues: [String: [String]] = [:]

    func holder(of app: String) -> String? { holders[app] }

    /// The apps a group has, in a fixed order.
    func apps(of group: String) -> [String] { holders.filter { $0.value == group }.keys.sorted() }

    /// The apps a group waits for, in a fixed order.
    func waits(of group: String) -> [String] { queues.filter { $0.value.contains(group) }.keys.sorted() }

    func standing(of group: String, app: String) -> Standing? {
        if holders[app] == group { return .has }
        if let index = queues[app]?.firstIndex(of: group) { return .waiting(index + 1) }
        return nil
    }

    /// A group asks for an app. `hold`: it's about to put a window of it on its display, so it has the app from now
    /// (until `letGo` or `leave`); without, it only acts in it once and takes nothing. Free, or its own already: it
    /// goes ahead. Another group's: it waits in order, unless that could never end (`circular`).
    mutating func ask(_ group: String, app: String, hold: Bool) -> Standing {
        guard let holder = holders[app] else {
            if hold { holders[app] = group }
            return .has
        }
        if holder == group { return .has }
        if let index = queues[app]?.firstIndex(of: group) { return .waiting(index + 1) }
        if blocked(holder, by: group) { return .circular }
        queues[app, default: []].append(group)
        return .waiting(queues[app]?.count ?? 1)
    }

    /// `first` waits, directly or through others, for an app `group` has.
    private func blocked(_ first: String, by group: String) -> Bool {
        var seen: Set<String> = []
        var next = [first]
        while let one = next.popLast() {
            if one == group { return true }
            guard seen.insert(one).inserted else { continue }
            for app in waits(of: one) {
                if let holder = holders[app] { next.append(holder) }
            }
        }
        return false
    }

    /// A group is done with an app (its windows of it are closed or went to the person, the app quit, or its one act
    /// is over): the next in line has it now.
    mutating func letGo(_ group: String, app: String) -> [Grant] {
        guard holders[app] == group else { return [] }
        holders[app] = nil
        guard var queue = queues[app], !queue.isEmpty else {
            queues[app] = nil
            return []
        }
        let next = queue.removeFirst()
        queues[app] = queue.isEmpty ? nil : queue
        holders[app] = next
        return [Grant(app: app, group: next)]
    }

    /// A group no longer waits for an app (whoever asked gave up).
    mutating func stopWaiting(_ group: String, app: String) {
        guard var queue = queues[app] else { return }
        queue.removeAll { $0 == group }
        queues[app] = queue.isEmpty ? nil : queue
    }

    /// A group ended: it waits for nothing, and every app it had goes to the next in line.
    mutating func leave(_ group: String) -> [Grant] {
        for app in waits(of: group) { stopWaiting(group, app: app) }
        var grants: [Grant] = []
        for app in apps(of: group) { grants += letGo(group, app: app) }
        return grants
    }

    /// What the AI is told when waiting could never end.
    static func circularWords(_ app: String) -> String {
        "\(app) is in use by another helper, which is itself waiting for an app you're using, so waiting would never end. Nothing was done. Finish with what you have open first (petal_windows close, or show to hand it to the person), or do this part another way."
    }
}
