import AppKit
import ApplicationServices
import Observation
import ObjectiveC
import ScreenCaptureKit

/// One display made out of nothing, with CoreGraphics' private classes (`CGVirtualDisplay` and its descriptor,
/// settings and mode). They're looked up by name at run time and called through the Objective-C runtime, each method
/// only after its arguments were checked to be the ones Petal passes: nothing is linked or declared, so a macOS
/// without them (or with others) builds, launches and runs as before, and `available` is false. The display lasts
/// as long as this object: letting it go removes it, and so does Petal ending, however it ends.
final class VirtualDisplay {
    private var object: AnyObject?
    let id: CGDirectDisplayID
    /// It was made at twice the pixels (2880×1800 for 1440×900 points).
    let hiDPI: Bool

    private init(object: AnyObject, id: CGDirectDisplayID, hiDPI: Bool) {
        self.object = object
        self.id = id
        self.hiDPI = hiDPI
    }

    /// Removes the display. Twice does nothing.
    func remove() { object = nil }

    // MARK: The private classes

    private static let descriptorClass = "CGVirtualDisplayDescriptor"
    private static let displayClass = "CGVirtualDisplay"
    private static let settingsClass = "CGVirtualDisplaySettings"
    private static let modeClass = "CGVirtualDisplayMode"

    /// Every method Petal calls, with its return and argument types as the runtime encodes them.
    private static let needed: [(type: String, selector: String, signature: String)] = [
        (descriptorClass, "setName:", "v@:@"), (descriptorClass, "setQueue:", "v@:@"),
        (descriptorClass, "setMaxPixelsWide:", "v@:I"), (descriptorClass, "setMaxPixelsHigh:", "v@:I"),
        (descriptorClass, "setSizeInMillimeters:", "v@:{CGSize=dd}"), (descriptorClass, "setProductID:", "v@:I"),
        (descriptorClass, "setVendorID:", "v@:I"), (descriptorClass, "setSerialNum:", "v@:I"),
        (descriptorClass, "setTerminationHandler:", "v@:@?"),
        (displayClass, "initWithDescriptor:", "@@:@"), (displayClass, "applySettings:", "B@:@"), (displayClass, "displayID", "I@:"),
        (settingsClass, "setHiDPI:", "v@:I"), (settingsClass, "setModes:", "v@:@"),
        (modeClass, "initWithWidth:height:refreshRate:", "@@:IId"),
    ]

    /// A method's return and argument types, without their offsets: "v@:I".
    private static func signature(_ method: Method) -> String {
        var text = ""
        let returned = method_copyReturnType(method)
        text += String(cString: returned)
        free(returned)
        for index in 0..<method_getNumberOfArguments(method) {
            guard let type = method_copyArgumentType(method, index) else { continue }
            text += String(cString: type)
            free(type)
        }
        return text
    }

    private static func implementation(_ type: String, _ selector: String, _ expected: String) -> IMP? {
        guard let found: AnyClass = NSClassFromString(type),
              let method = class_getInstanceMethod(found, NSSelectorFromString(selector)),
              signature(method) == expected else { return nil }
        return method_getImplementation(method)
    }

    /// What's missing, by name ("CGVirtualDisplay applySettings:"); empty when everything is there. Looks only: makes
    /// no instance of anything.
    static let missing: [String] = needed.compactMap { item in
        implementation(item.type, item.selector, item.signature) == nil ? "\(item.type) \(item.selector)" : nil
    }

    /// This macOS has the classes, with the methods and arguments Petal uses.
    static var available: Bool { missing.isEmpty }

    private typealias SetObject = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    private typealias SetNumber = @convention(c) (AnyObject, Selector, UInt32) -> Void
    private typealias SetSize = @convention(c) (AnyObject, Selector, CGSize) -> Void
    private typealias InitWith = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
    private typealias InitMode = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
    private typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> ObjCBool
    private typealias GetNumber = @convention(c) (AnyObject, Selector) -> UInt32

    private static func set(_ object: AnyObject, _ type: String, _ selector: String, object value: AnyObject?) {
        guard let imp = implementation(type, selector, selector == "setTerminationHandler:" ? "v@:@?" : "v@:@") else { return }
        unsafeBitCast(imp, to: SetObject.self)(object, NSSelectorFromString(selector), value)
    }

    private static func set(_ object: AnyObject, _ type: String, _ selector: String, number value: UInt32) {
        guard let imp = implementation(type, selector, "v@:I") else { return }
        unsafeBitCast(imp, to: SetNumber.self)(object, NSSelectorFromString(selector), value)
    }

    /// A new, plain instance of a class by its name.
    private static func new(_ type: String) -> AnyObject? {
        guard let found = NSClassFromString(type) as? NSObject.Type else { return nil }
        return found.init()
    }

    /// An instance made by an initializer that takes arguments: allocated here, and handed to `start`, which calls
    /// the initializer (it takes over the reference it's given, and gives one back).
    private static func make(_ type: String, _ start: (AnyObject) -> Unmanaged<AnyObject>?) -> AnyObject? {
        guard let found: AnyClass = NSClassFromString(type), let raw = class_createInstance(found, 0) as AnyObject? else { return nil }
        let given = Unmanaged.passRetained(raw)
        return start(given.takeUnretainedValue())?.takeRetainedValue()
    }

    /// Makes a display of `points` (1440×900), at twice the pixels when macOS takes that, else at once the pixels.
    /// On the main thread. `gone`: macOS took the display away by itself. Nil when the classes aren't there or macOS
    /// refused. Its id is marked as a run's (`Screens.mark`) before it comes online.
    static func make(name: String, serial: UInt32, points: CGSize, gone: @escaping @Sendable () -> Void) -> VirtualDisplay? {
        guard available, let descriptor = new(descriptorClass), let settings = new(settingsClass) else { return nil }
        let wide = UInt32(points.width), high = UInt32(points.height)
        set(descriptor, descriptorClass, "setName:", object: name as NSString)
        set(descriptor, descriptorClass, "setQueue:", object: DispatchQueue.main)
        set(descriptor, descriptorClass, "setMaxPixelsWide:", number: wide * 2)
        set(descriptor, descriptorClass, "setMaxPixelsHigh:", number: high * 2)
        if let imp = implementation(descriptorClass, "setSizeInMillimeters:", "v@:{CGSize=dd}") {
            // About 110 points to the inch, as a laptop's own screen.
            let millimeters = CGSize(width: points.width * 25.4 / 110, height: points.height * 25.4 / 110)
            unsafeBitCast(imp, to: SetSize.self)(descriptor, NSSelectorFromString("setSizeInMillimeters:"), millimeters)
        }
        // Petal's own made-up maker and model, so macOS never takes it for a real monitor it knows.
        set(descriptor, descriptorClass, "setVendorID:", number: 0x5045)    // "PE"
        set(descriptor, descriptorClass, "setProductID:", number: 0x5441)   // "TA"
        set(descriptor, descriptorClass, "setSerialNum:", number: serial)
        let handler: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in gone() }
        set(descriptor, descriptorClass, "setTerminationHandler:", object: unsafeBitCast(handler, to: AnyObject.self))

        guard let start = implementation(displayClass, "initWithDescriptor:", "@@:@"),
              let display = make(displayClass, { unsafeBitCast(start, to: InitWith.self)($0, NSSelectorFromString("initWithDescriptor:"), descriptor) }),
              let read = implementation(displayClass, "displayID", "I@:"),
              let apply = implementation(displayClass, "applySettings:", "B@:@"),
              let mode = implementation(modeClass, "initWithWidth:height:refreshRate:", "@@:IId") else { return nil }
        let id = unsafeBitCast(read, to: GetNumber.self)(display, NSSelectorFromString("displayID"))
        guard id != 0 else { return nil }
        // A run's, from before it's on: nothing of Petal's takes it for one of the person's screens.
        Screens.mark(id)
        let one = make(modeClass) {
            unsafeBitCast(mode, to: InitMode.self)($0, NSSelectorFromString("initWithWidth:height:refreshRate:"), wide, high, 60)
        }
        guard let one else { Screens.forget(id); return nil }
        set(settings, settingsClass, "setModes:", object: [one] as NSArray)
        let applying = unsafeBitCast(apply, to: Apply.self)
        // Twice the pixels first; a macOS that refuses gets once.
        for sharp in [UInt32(1), UInt32(0)] {
            set(settings, settingsClass, "setHiDPI:", number: sharp)
            if applying(display, NSSelectorFromString("applySettings:"), settings).boolValue {
                return VirtualDisplay(object: display, id: id, hiDPI: sharp == 1)
            }
        }
        // Refused both ways: `display` goes with this scope, and its id once macOS no longer lists it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Screens.forget(id) }
        return nil
    }
}

/// A hidden display for each Petal AI run (`runDisplays`, on by default): the windows a run opens go to a display
/// of its own, which the person never sees and their pointer can't reach, so nothing a run does shows up in front of
/// them. Questions, Buy cards and the vault's card stay over the dock or on the note, on the person's screen.
///
/// A run is a helper in a note (with everything that note starts), a chat's reply, or an AI session outside Petal
/// (`RunDisplayRules.group`). It gets a display the first time it puts a window on the screen, never before; past
/// the limit (`RunDisplayRules.limit`) it waits its turn ("Waiting for a display"). Its display goes when it ends,
/// however it ends. What it leaves is put away first: an app the run itself started, which the person hasn't used
/// since and which holds nothing unsaved, is asked to quit (`RunDisplayRules.leftover(app:)`); of what's left, a
/// window still on the display is closed if it's the run's own and holds nothing, else brought back to the person's
/// main screen (`RunDisplayRules.leftover`). Two runs take turns on one app (`AppTurns`: "Waiting for TextEdit").
/// `RunDisplayPlan` decides all of that; this makes the displays and moves the windows, through Accessibility alone,
/// never activating an app or bringing anything forward.
///
/// A headless run (a check, a bench, a snapshot) never makes a display: `maker` is nil there, and only a made-up one
/// handed in (`useMadeUp`) is ever used.
@MainActor @Observable
final class RunDisplays {
    /// A window a run put on its display.
    struct Tracked {
        let window: CGWindowID
        let pid: pid_t
        let element: AXUIElement
        let bundle: String
        let appName: String
        /// Opened with no file and no address: an app's own new, blank window.
        let bare: Bool
        /// A dialog or panel, not an ordinary window (an Open panel, a welcome window).
        var panel = false
        /// The run did something in it since.
        var changed = false
        /// The person took it to their screen (Show me), or the run brought it there (petal_windows show).
        var shown = false
        let at = Date()
    }

    /// An app a run's own open started: it wasn't running before, so it's the run's to put away.
    struct Launched {
        let pid: pid_t
        let bundle: String
        let name: String
        /// The person used it since (`RunDisplayRules.personUsed`): theirs from then on.
        var used = false
        let at = Date()
    }

    /// One group's display.
    @MainActor @Observable
    final class Display: Identifiable {
        let id = UUID()
        let group: String
        /// Who it's for, for a tile of its own in the AI button's preview ("Claude Code in T3 Code"); a note's and a
        /// chat's show on their own tile.
        var label = ""
        @ObservationIgnored var screen: Made?
        var number: CGDirectDisplayID = 0
        /// In the window server's coordinates, once it's placed.
        var frame = CGRect.zero
        var ready = false
        @ObservationIgnored var windows: [CGWindowID: Tracked] = [:]
        /// The apps this group's opens started, by process.
        @ObservationIgnored var launched: [pid_t: Launched] = [:]
        @ObservationIgnored var opened = 0
        /// The latest picture of it, for the preview.
        var picture: NSImage?

        init(group: String) { self.group = group }
    }

    /// A display as the controller holds it: the real one, or a made-up one in a check.
    struct Made {
        let id: CGDirectDisplayID
        let hiDPI: Bool
        let remove: () -> Void
    }

    enum Failure: Error {
        case off, unavailable, placing, ended
        /// Waiting for this app could never end (`AppTurns.Standing.circular`).
        case circular(String)
        /// The run ended while it waited its turn for this app.
        case turnEnded(String)
        var words: String {
            switch self {
            case .circular(let app): return AppTurns.circularWords(app)
            case .turnEnded(let app): return "This run ended (or was stopped or paused) while it waited its turn for \(app). Nothing was done."
            case .off: return RunDisplayRules.off
            case .unavailable: return RunDisplayRules.unavailable
            case .placing: return "macOS wouldn't keep a hidden display out of the pointer's way, so Petal made none. Pass on: \"screen\" to open it on the person's screen instead, if they'd want that."
            case .ended: return "This run's display went before it was used (the run was stopped or paused, or hidden displays were turned off)."
            }
        }
    }

    typealias Maker = @MainActor (_ name: String, _ serial: UInt32, _ gone: @escaping @Sendable () -> Void) -> Made?

    private struct Member {
        var group: String
        /// Still going, asked now and then (a chat's reply, an outside session's process); a helper's run ends itself.
        var alive: () -> Bool
        var used = Date()
        var deadSince: Date?
    }

    private struct Waiter {
        let run: String
        let done: (Result<Display, Failure>) -> Void
    }

    private struct TurnWaiter {
        let run: String
        let hold: Bool
        let done: (Failure?) -> Void
    }

    private var plan: RunDisplayPlan
    private(set) var displays: [String: Display] = [:]
    @ObservationIgnored private var members: [String: Member] = [:]
    @ObservationIgnored private var waiters: [String: [Waiter]] = [:]
    /// The groups waiting for a display now.
    private(set) var waiting: Set<String> = []
    /// Who has each app and who waits for it (`AppTurns`).
    @ObservationIgnored private var turns = AppTurns()
    /// By group, then app: who's waiting to hear it's their turn.
    @ObservationIgnored private var turnWaiters: [String: [String: [TurnWaiter]]] = [:]
    /// The app each group waits its turn for now, by its name ("TextEdit"), where its state shows.
    private(set) var waitingApps: [String: String] = [:]
    /// The app each group waits for the person to leave (it needs real keys there, and the person's use wins).
    private(set) var busyApps: [String: String] = [:]
    /// Opens under way, by group and app: the group has the app while one is, whatever windows it has yet.
    @ObservationIgnored private var claims: [String: [String: Int]] = [:]
    /// Apps being put away for a run that ended (asked to quit): whoever asks for one waits until that's done.
    @ObservationIgnored private var settling: [String: Int] = [:]
    @ObservationIgnored private var afterSettling: [String: [() -> Void]] = [:]
    /// Each app's name, by bundle id, as last asked for.
    @ObservationIgnored private var appNames: [String: String] = [:]
    /// What reads and changes apps and windows for it: the real ones, or a check's made-up ones.
    @ObservationIgnored private(set) var hands = Hands.real
    /// A check running it without Petal's settings and chats (`--display-check --full`): its limit.
    @ObservationIgnored private var alone: Int?
    /// A run's app in front, when it came forward with the person's hands still: watched for their first key or click.
    @ObservationIgnored private var frontWatch: (pid: pid_t, since: TimeInterval)?
    @ObservationIgnored private var frontTimer: Timer?
    @ObservationIgnored private var frontToken: NSObjectProtocol?
    /// What settling the last runs' leftovers did, newest last (for checks and `--display-check`).
    @ObservationIgnored private(set) var settled: [Settled] = []
    @ObservationIgnored private var pruning = false
    @ObservationIgnored private var maker: Maker?
    @ObservationIgnored private var placer: (CGDirectDisplayID, CGSize) -> Placing
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var serial: UInt32 = 0
    @ObservationIgnored private var screensToken: NSObjectProtocol?
    /// Displays removed, until macOS stops listing them.
    @ObservationIgnored private var retired: Set<CGDirectDisplayID> = []
    /// Making, placing and settling a display's windows: one at a time, never on the main thread.
    nonisolated static let queue = DispatchQueue(label: "petal.rundisplays", qos: .userInitiated)
    /// How long an AI session outside Petal keeps its display without asking Petal anything.
    static let outsideQuiet: TimeInterval = 600

    var app: PetalApp { PetalApp.shared }

    /// The real displays, except in a headless run, which never makes one.
    init() {
        plan = RunDisplayPlan(limit: 1)
        placer = { id, size in RunDisplays.place(id, size: size) }
        guard !Headless.on else { return }
        maker = { name, serial, gone in
            guard let made = VirtualDisplay.make(name: name, serial: serial, points: RunDisplayRules.size, gone: gone) else { return nil }
            return Made(id: made.id, hiDPI: made.hiDPI, remove: { made.remove() })
        }
    }

    /// A check's made-up displays instead of real ones (HelpersCheck): nothing is ever made or arranged for them,
    /// and with made-up `hands` no real app or window is read, moved, closed or quit either.
    func useMadeUp(_ maker: @escaping Maker, placed: @escaping (CGDirectDisplayID, CGSize) -> Placing, hands: Hands? = nil) {
        self.maker = maker
        placer = placed
        if let hands { self.hands = hands }
    }

    /// For `--display-check --full`, which has no PetalApp: real displays, on by itself, with a limit of its own, and
    /// every caller its own group (as an AI session outside Petal).
    convenience init(alone limit: Int) {
        self.init()
        alone = limit
        maker = { name, serial, gone in
            guard let made = VirtualDisplay.make(name: name, serial: serial, points: RunDisplayRules.size, gone: gone) else { return nil }
            return Made(id: made.id, hiDPI: made.hiDPI, remove: { made.remove() })
        }
    }

    /// The limit of one run alone (`init(alone:)`).
    func setLimit(alone limit: Int) {
        guard alone != nil else { return }
        alone = limit
        apply(plan.setLimit(self.limit))
    }

    // MARK: Whether, and for whom

    /// The person turned hidden displays on (`runDisplays`).
    private var enabled: Bool { alone != nil || (PetalApp.started && app.config.bool("runDisplays")) }

    /// `runDisplays` is on, and this Petal can make displays.
    var on: Bool { enabled && maker != nil }

    /// Why there are none, in the person's words, for Settings; nil when they can be made.
    static var unavailableWords: String? {
        VirtualDisplay.available ? nil : "This Mac's macOS doesn't let Petal make a hidden display, so runs work on your screen as before."
    }

    var limit: Int {
        if let alone { return max(1, alone) }
        return RunDisplayRules.limit(memory: ProcessInfo.processInfo.physicalMemory, setting: Int(app.config.number("runDisplaysLimit")))
    }

    func group(of caller: String) -> String {
        guard alone == nil else { return caller }
        return RunDisplayRules.group(caller: caller, paper: app.claude.note(withID: caller)?.paper)
    }

    func asker(_ caller: String) -> RunDisplayRules.Asker {
        if alone != nil || caller.hasPrefix("mcp-") { return .outside }
        return app.claude.note(withID: caller)?.paper != nil ? .helper : .chat
    }

    /// Where a tool's window goes for this caller (`on`: what the tool was asked).
    func place(for caller: String?, asked: String?) -> RunDisplayRules.Place {
        guard let caller, !caller.isEmpty else { return .screen }
        return RunDisplayRules.place(asked: asked, on: on, asker: asker(caller))
    }

    /// The caller's display, when its group has one that's ready.
    func display(for caller: String?) -> Display? {
        guard let caller, let display = displays[group(of: caller)], display.ready else { return nil }
        return display
    }

    /// The caller waits for a display now.
    func waits(_ caller: String?) -> Bool {
        guard let caller, !waiting.isEmpty else { return false }
        return waiting.contains(group(of: caller))
    }

    /// The app the caller waits its turn for now (another run is using it, or the person is and it needs real keys
    /// there), by its name; nil when it waits for none.
    func waitsForApp(_ caller: String?) -> String? {
        guard let caller, !(waitingApps.isEmpty && busyApps.isEmpty) else { return nil }
        let group = group(of: caller)
        return waitingApps[group] ?? busyApps[group]
    }

    /// A window Petal's tools found by its number is another run's own (it put it on its display, and nobody brought
    /// it to the person's screen since): nothing of it is the caller's to see or use, wherever it is right now.
    func foreign(window: CGWindowID?, to caller: String?) -> Bool {
        guard let window, !displays.isEmpty else { return false }
        for display in displays.values {
            guard let tracked = display.windows[window], !tracked.shown else { continue }
            return caller.map { group(of: $0) != display.group } ?? true
        }
        return false
    }

    /// The group whose display holds a window with this frame (the window server's coordinates).
    func owner(of frame: CGRect) -> String? {
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        return displays.values.first { $0.ready && $0.frame.contains(middle) }?.group
    }

    /// A window with this frame is on the caller's own display.
    func holds(_ frame: CGRect, for caller: String) -> Bool { owner(of: frame) == group(of: caller) }

    /// A window with this frame is on another run's display: nothing of it is the caller's to see or use.
    func foreign(_ frame: CGRect, to caller: String?) -> Bool {
        guard let owner = owner(of: frame) else { return false }
        return caller.map { group(of: $0) != owner } ?? true
    }

    // MARK: Getting one

    /// A run is about to put a window on the screen: its display, now or once it's its turn. `done` hears it on the
    /// main thread, or why there's none. `label`: who it is, for an AI session outside Petal.
    func need(_ caller: String, label: String = "", done: @escaping (Result<Display, Failure>) -> Void) {
        guard enabled else { return done(.failure(.off)) }
        guard maker != nil else { return done(.failure(.unavailable)) }
        let group = group(of: caller)
        register(caller, group: group)
        _ = apply(plan.setLimit(limit))
        let asked = plan.need(caller, group: group)
        apply(asked.effects)
        guard let display = displays[group] else {
            if case .waiting = asked.standing {
                waiters[group, default: []].append(Waiter(run: caller, done: done))
                waiting.insert(group)
                say(group, waiting: true)
                return
            }
            return done(.failure(.unavailable))
        }
        if !label.isEmpty { display.label = label }
        if display.ready { return done(.success(display)) }
        waiters[group, default: []].append(Waiter(run: caller, done: done))
    }

    /// A run exists and shares its group's display (a second opinion begun on a note whose helper has one): nothing
    /// is made for it.
    func join(_ run: String, group: String, alive: @escaping () -> Bool = { true }) {
        guard on || !displays.isEmpty else { return }
        members[run] = Member(group: group, alive: alive)
        apply(plan.join(run, group: group))
        watch()
    }

    private func register(_ caller: String, group: String) {
        if var known = members[caller] {
            known.group = group
            known.used = Date()
            known.deadSince = nil
            members[caller] = known
        } else {
            members[caller] = Member(group: group, alive: liveness(caller))
        }
        watch()
    }

    /// Whether a caller's run still goes: a helper's while its run runs (paused, it ends: Pause takes the display
    /// away, and Go on gets one again when it next needs it); a chat's while its reply runs or waits for an Allow;
    /// an AI session outside Petal's while its process lives and it asked Petal something in the last ten minutes.
    private func liveness(_ caller: String) -> () -> Bool {
        // One run alone (a check) says itself when it ends.
        if alone != nil { return { true } }
        if caller.hasPrefix("mcp-") {
            let pid = pid_t(caller.dropFirst(4)) ?? 0
            return { [weak self] in
                guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
                let used = self?.members[caller]?.used ?? .distantPast
                return Date().timeIntervalSince(used) < Self.outsideQuiet
            }
        }
        return { [weak self] in
            guard let self, let note = self.app.claude.note(withID: caller) else { return false }
            if let token = note.agent.token { return token.state == .running }
            return note.agent.running || !note.agent.pendingAsk.isEmpty || !note.agent.queued.isEmpty
        }
    }

    /// The caller asked Petal something: an AI session outside Petal keeps its display while it does.
    func touched(_ caller: String?) {
        guard let caller, members[caller] != nil else { return }
        members[caller]?.used = Date()
    }

    // MARK: Ending

    /// A run ended (done, failed, stopped, paused, its note thrown away, its session gone): out of its group, and
    /// with the group's last run its display goes. Twice does nothing.
    func ended(_ run: String) {
        guard members.removeValue(forKey: run) != nil || plan.group(of: run) != nil else { return }
        failWaiters(of: run)
        failTurnWaiters(of: run)
        apply(plan.leave(run))
    }

    /// The setting changed: turned off, every display goes now; the limit raised, the next ones waiting get theirs.
    func settingsChanged() {
        guard PetalApp.started, alone == nil else { return }
        if !app.config.bool("runDisplays") {
            if !displays.isEmpty || !members.isEmpty { endAll() }
            return
        }
        guard !members.isEmpty else { return }
        apply(plan.setLimit(limit))
    }

    /// Every display goes: `runDisplays` turned off.
    func endAll() {
        let effects = plan.endAll()
        // Whoever waits its turn for an app hears it ended, while its chat is still known.
        for group in Array(turnWaiters.keys) { endTurns(of: group) }
        for group in Array(busyApps.keys) { clearBusy(group) }
        members = [:]
        for (group, list) in waiters { waiters[group] = nil; for waiter in list { waiter.done(.failure(.ended)) } }
        for group in waiting { say(group, waiting: false) }
        waiting = []
        apply(effects)
        watch()
    }

    /// Petal is quitting: each window still on a display is put on the person's main screen (a quick try, by its
    /// position alone), then every display is removed. Nothing is left behind: the process owns them, so one that
    /// crashes loses them too.
    func quit() {
        timer?.invalidate()
        timer = nil
        app.runBrowsers.quit()   // each run's own browser ends first: its window never lands on the person's screen
        stopFrontWatch()
        if let frontToken { NSWorkspace.shared.notificationCenter.removeObserver(frontToken) }
        frontToken = nil
        let target = Self.personArea()
        let deadline = Date().addingTimeInterval(2)
        let front = hands.front()
        for display in displays.values {
            // An app the run started that nobody used and that holds nothing unsaved is asked to quit, and not waited
            // for: it goes by itself, and a window it keeps open to ask something comes to the main screen with its
            // display (macOS moves a removed display's windows there).
            var going: Set<pid_t> = []
            for started in display.launched.values.sorted(by: { $0.at < $1.at }) where Date() < deadline && hands.running(started.pid) {
                let shown = display.windows.values.contains { $0.pid == started.pid && $0.shown }
                let left = RunDisplayRules.LeftApp(launched: true, used: started.used || front == started.pid, shown: shown,
                                                   unsaved: hands.unsaved(started.pid))
                guard RunDisplayRules.leftover(app: left) == .quit else { continue }
                hands.quit(started.pid)
                going.insert(started.pid)
            }
            var index = 0
            for tracked in display.windows.values where Date() < deadline && !tracked.shown && !going.contains(tracked.pid) {
                guard let frame = hands.frame(tracked), display.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
                hands.place(tracked, RunDisplayRules.frame(for: frame.size, on: target, index: index))
                index += 1
            }
            display.screen?.remove()
            display.screen = nil
        }
        displays = [:]
        members = [:]
        waiters = [:]
        waiting = []
        turns = AppTurns()
        turnWaiters = [:]
        waitingApps = [:]
        busyApps = [:]
        claims = [:]
        _ = plan.endAll()
    }

    private func failWaiters(of run: String) {
        for (group, list) in waiters {
            let mine = list.filter { $0.run == run }
            guard !mine.isEmpty else { continue }
            waiters[group] = list.filter { $0.run != run }
            for waiter in mine { waiter.done(.failure(.ended)) }
        }
    }

    // MARK: The plan's effects

    @discardableResult
    private func apply(_ effects: [RunDisplayPlan.Effect]) -> Bool {
        for effect in effects {
            switch effect {
            case .make(let group): make(group)
            case .remove(let group): remove(group)
            }
        }
        // Whoever no longer waits (it got one, or ended) says so no more.
        for group in waiting where plan.standing(of: group) == .none || displays[group] != nil {
            if plan.standing(of: group) == .none, displays[group] == nil {
                for waiter in waiters.removeValue(forKey: group) ?? [] { waiter.done(.failure(.ended)) }
            }
            waiting.remove(group)
            say(group, waiting: false)
        }
        watch()
        return !effects.isEmpty
    }

    private func make(_ group: String) {
        let display = Display(group: group)
        displays[group] = display
        serial &+= 1
        let gone: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lost(group, display) } }
        }
        guard let made = maker?("Petal AI", serial, gone) else { return failed(group, display, .unavailable) }
        display.screen = made
        display.number = made.id
        observeScreens()
        let placer = self.placer
        Self.queue.async {
            let placing = placer(made.id, RunDisplayRules.size)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Ended while it was placed: it's gone already.
                    guard self.displays[group] === display else { return }
                    guard let frame = placing.frame else { return self.failed(group, display, .placing) }
                    display.frame = frame
                    display.ready = true
                    for waiter in self.waiters.removeValue(forKey: group) ?? [] { waiter.done(.success(display)) }
                }
            }
        }
    }

    /// A display that couldn't be made or placed: removed, its runs told, the next group's turn.
    private func failed(_ group: String, _ display: Display, _ why: Failure) {
        guard displays[group] === display else { return }
        app.runBrowsers.displayGoing(group)
        displays[group] = nil
        release(display)
        for waiter in waiters.removeValue(forKey: group) ?? [] { waiter.done(.failure(why)) }
        apply(plan.lost(group: group))
    }

    /// macOS took a display away by itself: its windows are wherever macOS put them; the group has none now.
    private func lost(_ group: String, _ display: Display) {
        guard displays[group] === display else { return }
        app.runBrowsers.displayGoing(group)
        displays[group] = nil
        release(display)
        for waiter in waiters.removeValue(forKey: group) ?? [] { waiter.done(.failure(.ended)) }
        apply(plan.lost(group: group))
    }

    /// A group's display goes: what's left on it is settled first, off the main thread (a few seconds at most), then
    /// the display is removed.
    private func remove(_ group: String) {
        // The run's own browser ends before its display goes, so its window is never left to land on the person's screen.
        app.runBrowsers.displayGoing(group)
        guard let display = displays.removeValue(forKey: group) else { return }
        for waiter in waiters.removeValue(forKey: group) ?? [] { waiter.done(.failure(.ended)) }
        let leaving = Leaving(windows: Array(display.windows.values), apps: Array(display.launched.values),
                              display: display.frame, target: Self.personArea(), front: hands.front())
        display.windows = [:]
        display.launched = [:]
        // The apps it started are being put away from here on: whoever asks for one, or is next in line for it, waits
        // until that's done (an app asked to quit can't take an open).
        let bundles = display.ready ? Set(leaving.apps.map(\.bundle)) : []
        for bundle in bundles { settling[bundle, default: 0] += 1 }
        // Its turns end with it: what it waited for it no longer does, and what it had goes to the next in line.
        endTurns(of: group)
        clearBusy(group)
        watchApps()
        guard display.ready, !(leaving.windows.isEmpty && leaving.apps.isEmpty) else {
            release(display)
            for bundle in bundles { settledApp(bundle) }
            return
        }
        let hands = self.hands
        let deadline = Date().addingTimeInterval(4 + RunDisplayRules.quitBound * Double(min(2, leaving.apps.count)))
        Self.queue.async {
            let result = Self.settle(leaving, hands: hands, deadline: deadline)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.release(display)
                    self.record(result, of: leaving)
                    for bundle in bundles { self.settledApp(bundle) }
                }
            }
        }
    }

    /// What settling did, kept for checks, and said in What Petal AI did (an app Petal quit is the person's to know).
    private func record(_ result: Settled, of leaving: Leaving) {
        settled.append(result)
        if settled.count > 20 { settled.removeFirst(settled.count - 20) }
        guard alone == nil, PetalApp.started else { return }
        for started in leaving.apps where result.quit.contains(started.pid) {
            app.assist.did("Quit \(named: started.name, else: "an app"), which it had opened on a display of its own")
        }
    }

    /// An app that was being put away is (asked to quit and gone, or kept): whoever waited for that goes on.
    private func settledApp(_ bundle: String) {
        let left = (settling[bundle] ?? 1) - 1
        settling[bundle] = left > 0 ? left : nil
        guard left <= 0 else { return }
        for next in afterSettling.removeValue(forKey: bundle) ?? [] { next() }
    }

    private func release(_ display: Display) {
        display.ready = false
        display.picture = nil
        guard let screen = display.screen else { return }
        display.screen = nil
        screen.remove()
        retired.insert(screen.id)
        // Its id stays a run's until macOS no longer lists it (the screens changing says when; this is the net).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { self.forgetRetired() } }
    }

    private func forgetRetired() {
        for id in retired where !Screens.isOnline(id) {
            Screens.forget(id)
            retired.remove(id)
        }
    }

    private func observeScreens() {
        guard screensToken == nil else { return }
        screensToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forgetRetired() }
        }
    }

    /// "Waiting for a display", where the run's state shows (its chat's step: the AI button's preview and the note).
    private func say(_ group: String, waiting on: Bool) {
        guard alone == nil else { return }
        for (run, member) in members where member.group == group {
            guard let agent = app.claude.note(withID: run)?.agent else { continue }
            if on {
                agent.activity = "Waiting for a display"
            } else if agent.activity.text == NoteStatus.waitingForDisplay {
                agent.activity = ""
            }
        }
    }

    // MARK: Watching for runs that ended

    /// While any run is known: once a second, a run that's no longer going (twice in a row, so the moment between a
    /// reply ending and its queued message starting isn't taken for its end) leaves, and its display with it.
    private func watch() {
        guard !members.isEmpty || !displays.isEmpty || !turnWaiters.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.2
    }

    private func tick() {
        // Turned off, however that was heard: every display goes.
        if !enabled { return endAll() }
        let now = Date()
        var gone: [String] = []
        for (run, member) in members {
            if member.alive() {
                if member.deadSince != nil { members[run]?.deadSince = nil }
            } else if let since = member.deadSince {
                if now.timeIntervalSince(since) >= 1.5 { gone.append(run) }
            } else {
                members[run]?.deadSince = now
            }
        }
        for run in gone { ended(run) }
        // A display nobody holds any more (its runs all left another way) goes too.
        for group in displays.keys where plan.standing(of: group) != .has { remove(group) }
        prune()
        watch()
    }

    /// An app that quit, or a window its run closed, is no longer its group's, and the next in line for that app gets
    /// it. Apps are looked at every time; windows only while another run waits for their app, off the main thread.
    private func prune() {
        var apps = false
        for display in displays.values {
            for pid in Array(display.launched.keys) where !hands.running(pid) {
                display.launched[pid] = nil
                apps = true
            }
        }
        if apps { watchApps() }
        let wanted = Set(turnWaiters.values.flatMap { $0.keys })
        var looked: [(group: String, tracked: Tracked)] = []
        for display in displays.values {
            for tracked in display.windows.values where wanted.contains(tracked.bundle) && !tracked.shown {
                looked.append((display.group, tracked))
            }
        }
        guard !looked.isEmpty, !pruning else { return letGoOfApps() }
        pruning = true
        let hands = self.hands
        Self.queue.async {
            let gone = looked.filter { !hands.exists($0.tracked) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pruning = false
                    for item in gone { self.displays[item.group]?.windows[item.tracked.window] = nil }
                    self.letGoOfApps()
                }
            }
        }
    }

    // MARK: Placing a display

    /// Where a display ended up, and what was tried, for `--display-check`.
    struct Placing {
        var frame: CGRect?
        var tried: [String] = []
        /// How long it took to come online, and then to be placed (seconds).
        var online: TimeInterval = 0
        var placed: TimeInterval = 0
    }

    /// The three calls that move a display, each with what macOS answered (0 is success).
    struct Arranged {
        var begin: Int32
        var origin: Int32?
        var complete: Int32?
        var ok: Bool { begin == 0 && origin == 0 && complete == 0 }
        var words: String {
            "begin \(begin), origin \(origin.map(String.init) ?? "not called"), complete \(complete.map(String.init) ?? "not called")"
        }
    }

    /// Asks macOS to put a display's top-left at `point`: exactly the three calls seen to work on macOS 27.3 (begin,
    /// origin, complete for this app only), and nothing else. Only for this Petal: the person's own arrangement is
    /// never saved over, and it's undone when Petal ends.
    nonisolated static func arrange(_ id: CGDirectDisplayID, at point: CGPoint) -> Arranged {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { return Arranged(begin: begin.rawValue, origin: nil, complete: nil) }
        let origin = CGConfigureDisplayOrigin(config, id, Int32(point.x.rounded()), Int32(point.y.rounded()))
        guard origin == .success else {
            CGCancelDisplayConfiguration(config)
            return Arranged(begin: begin.rawValue, origin: origin.rawValue, complete: nil)
        }
        let complete = CGCompleteDisplayConfiguration(config, .forAppOnly)
        return Arranged(begin: begin.rawValue, origin: origin.rawValue, complete: complete.rawValue)
    }

    /// Waits for the display to be in macOS's own list of online displays with real bounds and to have been there a
    /// moment (asked sooner, macOS refuses: 1006), then moves it to where it touches the person's screens only at a
    /// corner (`RunDisplayRules.origins`). A refusal is tried again for up to two seconds, from this thread and then
    /// from the main one (what was seen to work ran there); a place macOS accepts but doesn't keep moves on to the
    /// next corner. Where it landed is read until it's where it was asked or a second and a half passed. Never called
    /// on the main thread: the window server may take a moment.
    nonisolated static func place(_ id: CGDirectDisplayID, size: CGSize) -> Placing {
        var placing = Placing()
        let started = Date()
        let deadline = started.addingTimeInterval(5)
        while !(Screens.isOnline(id) && CGDisplayBounds(id).width > 1) {
            guard Date() < deadline else {
                placing.tried.append("the display never came into macOS's list of online displays (5 s)")
                return placing
            }
            usleep(50_000)
        }
        placing.online = Date().timeIntervalSince(started)
        // A moment more: a display just listed isn't ready to be moved yet. A second and a half after it was made is
        // what was seen to work; never less than half a second after it's listed.
        usleep(useconds_t(max(0.5, 1.5 - placing.online) * 1_000_000))
        let screens = Screens.displays.map { CGDisplayBounds($0) }
        let others = Screens.runFrames.filter { $0.id != id }.map(\.frame)
        let extent = CGDisplayBounds(id).size
        let actual = extent.width > 1 ? extent : size
        let patience = Date().addingTimeInterval(2)
        var onMain = false
        for point in RunDisplayRules.origins(size: actual, screens: screens, taken: others) {
            while true {
                let asked = "asked for \(Int(point.x)),\(Int(point.y)) from \(onMain ? "the main thread" : "a background thread")"
                var calls = Arranged(begin: -1, origin: nil, complete: nil)
                if onMain, !Thread.isMainThread {
                    DispatchQueue.main.sync { calls = arrange(id, at: point) }
                } else {
                    calls = arrange(id, at: point)
                }
                if calls.ok {
                    // Where it landed: read until it's where it was asked, or a second and a half passed.
                    var now = CGDisplayBounds(id)
                    let until = Date().addingTimeInterval(1.5)
                    while abs(now.minX - point.x) > 1 || abs(now.minY - point.y) > 1, Date() < until {
                        usleep(100_000)
                        now = CGDisplayBounds(id)
                    }
                    let hidden = RunDisplayRules.hiddenFrom(now, screens: Screens.displays.map { CGDisplayBounds($0) }, others: others)
                    placing.tried.append("\(asked): \(calls.words); it is at \(Int(now.minX)),\(Int(now.minY)) \(Int(now.width))×\(Int(now.height))"
                        + (hidden ? ", out of the pointer's way" : ", where the pointer could reach it"))
                    if hidden {
                        placing.frame = now
                        placing.placed = Date().timeIntervalSince(started) - placing.online
                        return placing
                    }
                    break   // accepted but not kept there: the next corner
                }
                placing.tried.append("\(asked): \(calls.words) (refused)")
                guard Date() < patience else { break }
                onMain.toggle()
                usleep(300_000)
            }
        }
        if placing.tried.isEmpty { placing.tried.append("no corner of the person's screens is free") }
        placing.placed = Date().timeIntervalSince(started) - placing.online
        return placing
    }

    /// Where a window brought back goes: the person's main display, less the menu bar and a margin (the window
    /// server's coordinates). Any thread.
    nonisolated static func personArea() -> CGRect {
        let bounds = CGDisplayBounds(Screens.mainDisplay)
        return CGRect(x: bounds.minX, y: bounds.minY + 30, width: bounds.width, height: max(200, bounds.height - 110))
    }

    // MARK: Windows on a display

    /// The app windows there are now, by number, with their owner and frame (the window server's list: no permission
    /// needed, never a title). Any thread.
    nonisolated static func windowNumbers(pid: pid_t? = nil, bundle: String? = nil) -> [CGWindowID: (pid: pid_t, frame: CGRect)] {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var pids: [pid_t: Bool] = [:]
        var found: [CGWindowID: (pid: pid_t, frame: CGRect)] = [:]
        for window in info {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  let number = window[kCGWindowNumber as String] as? CGWindowID,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo), bounds.width > 60, bounds.height > 60 else { continue }
            if let pid, owner != pid { continue }
            if let bundle {
                if pids[owner] == nil { pids[owner] = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier == bundle }
                guard pids[owner] == true else { continue }
            }
            found[number] = (owner, bounds)
        }
        return found
    }

    /// A window found for a run: the Accessibility window for a window server number.
    nonisolated static func element(_ number: CGWindowID, pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let list: [AXUIElement] = Windows.value(app, kAXWindowsAttribute) ?? []
        return list.first { Windows.id(of: $0) == number }
    }

    /// What opening something made: the windows of `bundle` that weren't there `before`, waited for up to `timeout`
    /// (an app starting takes a while). `live`: whoever asked is still there. Off the main thread.
    /// `anyKind`: its dialogs and panels too, for an app the run itself started (everything it shows is the run's:
    /// an Open panel, a welcome window); otherwise only ordinary windows.
    nonisolated static func newWindows(bundle: String, before: Set<CGWindowID>, timeout: TimeInterval, anyKind: Bool = false,
                                       live: () -> Bool) -> [(window: CGWindowID, pid: pid_t, element: AXUIElement)] {
        let deadline = Date().addingTimeInterval(timeout)
        while live() {
            let now = windowNumbers(bundle: bundle).filter { !before.contains($0.key) }
            var found: [(window: CGWindowID, pid: pid_t, element: AXUIElement)] = []
            for (number, window) in now {
                // Only a window Accessibility lists, and an ordinary one (never a sheet, a palette or a tooltip)
                // unless the app is the run's own.
                guard let element = element(number, pid: window.pid) else { continue }
                if !anyKind, !isOrdinary(element) { continue }
                found.append((number, window.pid, element))
            }
            if !found.isEmpty { return found }
            guard Date() < deadline else { break }
            usleep(150_000)
        }
        return []
    }

    /// An ordinary window, not a dialog or panel.
    nonisolated static func isOrdinary(_ element: AXUIElement) -> Bool {
        (Windows.value(element, kAXSubroleAttribute) as String?) == (kAXStandardWindowSubrole as String)
    }

    /// What `open` did.
    struct Opened {
        /// The app's name.
        var app = ""
        var bundle = ""
        /// Why nothing was opened, in words for the AI.
        var problem: String?
        /// The windows it made, now on the display.
        var moved: [(window: CGWindowID, pid: pid_t, element: AXUIElement)] = []
        /// Of those, the dialogs and panels.
        var panels: Set<CGWindowID> = []
        /// Windows it made that wouldn't move (they're on the person's screen).
        var stayed = 0
        /// The app wasn't running, and this open started it: its process.
        var launched: pid_t?
    }

    /// Opens an app (`url` nil), a file or an address in the app at `appURL` for a run's display at `frame`, without
    /// activating anything, and moves the window that results there through Accessibility. Only a window that wasn't
    /// there before is moved. Where nothing new would result (`RunDisplayRules.opening`), nothing is opened and
    /// `problem` says so. Off the main thread; `live`: whoever asked is still there, read right before the open.
    nonisolated static func open(appURL: URL, bundle: String, url: URL?, on frame: CGRect, index: Int, live: () -> Bool) -> Opened {
        var opened = Opened()
        opened.app = appURL.deletingPathExtension().lastPathComponent
        opened.bundle = bundle
        let web = ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
        let running = !NSRunningApplication.persons(withBundleIdentifier: bundle).isEmpty
        let before = Set(windowNumbers(bundle: bundle).keys)
        switch RunDisplayRules.opening(running: running, windows: before.count, address: web, browser: Browsers.kind(bundle) != nil, bare: url == nil) {
        case .tabInTheirs:
            opened.problem = "\(opened.app) is open with the person's own windows, and an address opens there as a tab in one of them, in front of them. Nothing was opened. petal_browser open opens it in a browser of your own, on your display; or pass on: \"screen\" if the person would want it opened on their screen."
            return opened
        case .nothingNew:
            opened.problem = "\(opened.app) is already open with the person's own windows, and Petal never moves those to your display. Nothing was opened. Open a file or an address in it (that makes a window of your own), or pass on: \"screen\" to use it on their screen."
            return opened
        case .go: break
        }
        // Its asker gone while the app was looked up: nothing opens.
        guard live() else { return opened }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let done = DispatchSemaphore(value: 0)
        let answer = OpenAnswer()
        let finished: @Sendable (NSRunningApplication?, Error?) -> Void = { started, error in
            answer.set(pid: started?.processIdentifier, error: error?.localizedDescription)
            done.signal()
        }
        if let url {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration, completionHandler: finished)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: finished)
        }
        _ = done.wait(timeout: .now() + 15)
        if let problem = answer.error {
            opened.problem = problem
            return opened
        }
        // It wasn't running before this open, so this open started it: the run's own, to put away when it ends.
        if !running {
            opened.launched = answer.pid ?? NSRunningApplication.persons(withBundleIdentifier: bundle).first?.processIdentifier
        }
        // What it made: an app still starting takes a while to show its window.
        let made = newWindows(bundle: bundle, before: before, timeout: running ? 5 : 15, anyKind: !running, live: live)
        for (offset, item) in made.enumerated() {
            if !isOrdinary(item.element) { opened.panels.insert(item.window) }
            if move(item.element, pid: item.pid, to: frame, index: index + offset, live: live) {
                opened.moved.append(item)
            } else {
                opened.stayed += 1
            }
        }
        return opened
    }

    /// Moves a window onto a display through Accessibility: its position and size, nothing raised, nothing activated.
    /// True when it's there after, by what Accessibility reads back (the window server's own list says so only a
    /// moment later, so it's never what confirms a move). Off the main thread.
    nonisolated static func move(_ element: AXUIElement, pid: pid_t, to display: CGRect, index: Int, live: () -> Bool = { true }) -> Bool {
        let size = Windows.frame(of: element)?.size ?? CGSize(width: 1000, height: 700)
        let target = RunDisplayRules.frame(for: size, on: display, index: index)
        guard let placed = Windows.place(element, pid: pid, target, live: live) else { return false }
        return display.contains(CGPoint(x: placed.midX, y: placed.midY))
    }

    /// A run opened these windows: they're its own from now on (the leftover rule goes by them).
    /// `panels`: the ones that are dialogs or panels, not ordinary windows. `app`: its bundle id and name, when
    /// whoever opened it knows them already.
    func track(_ windows: [(window: CGWindowID, pid: pid_t, element: AXUIElement)], for caller: String, bare: Bool,
               panels: Set<CGWindowID> = [], app known: (bundle: String, name: String)? = nil) {
        guard let display = displays[group(of: caller)] else { return }
        for item in windows {
            let running = known == nil ? NSRunningApplication(processIdentifier: item.pid) : nil
            let bundle = known?.bundle ?? running?.bundleIdentifier ?? ""
            let name = known?.name ?? running?.localizedName ?? ""
            display.windows[item.window] = Tracked(window: item.window, pid: item.pid, element: item.element, bundle: bundle,
                                                   appName: name, bare: bare, panel: panels.contains(item.window))
            display.opened += 1
            // Its group has that app from now, while a window of it is on its display.
            if !bundle.isEmpty, turns.holder(of: bundle) == nil { _ = turns.ask(display.group, app: bundle, hold: true) }
            if !bundle.isEmpty, !name.isEmpty { appNames[bundle] = name }
        }
    }

    /// A run's own open started this app (it wasn't running before): the run's to put away when it ends, unless the
    /// person uses it meanwhile.
    func launched(_ pid: pid_t, bundle: String, name: String, by caller: String) {
        guard pid > 0, let display = displays[group(of: caller)], display.launched[pid] == nil else { return }
        display.launched[pid] = Launched(pid: pid, bundle: bundle, name: name)
        if !bundle.isEmpty, !name.isEmpty { appNames[bundle] = name }
        if !bundle.isEmpty, turns.holder(of: bundle) == nil { _ = turns.ask(display.group, app: bundle, hold: true) }
        watchApps()
    }

    /// Whose an app is, for a caller that asks to quit, hide or bring it forward.
    func owner(of pid: pid_t, for caller: String?) -> RunDisplayRules.AppOwner {
        let mine = caller.map { group(of: $0) }
        for display in displays.values {
            guard let started = display.launched[pid], !started.used else { continue }
            // One of its windows went to the person's screen: theirs now.
            if display.windows.values.contains(where: { $0.pid == pid && $0.shown }) { continue }
            return display.group == mine ? .own : .another
        }
        return .persons
    }

    /// A window is the caller's own on its display, never seen by the person: its to close without asking them.
    func owns(window: CGWindowID?, for caller: String?) -> Bool {
        guard let window, let caller, let tracked = displays[group(of: caller)]?.windows[window] else { return false }
        return !tracked.shown
    }

    /// The apps the caller's group started and that are still its own (for checks).
    func launchedApps(for caller: String) -> [Launched] {
        (displays[group(of: caller)]?.launched.values).map { Array($0) } ?? []
    }

    /// The caller's own window on its display: of the app named (its name or bundle id), else the one it opened last.
    func window(for caller: String?, app named: String, newest: Bool) -> Tracked? {
        guard let caller, let display = displays[group(of: caller)], display.ready else { return nil }
        let own = display.windows.values.filter { !$0.shown }.sorted { $0.at > $1.at }
        if named.isEmpty { return newest ? own.first : nil }
        return own.first {
            $0.bundle.caseInsensitiveCompare(named) == .orderedSame || $0.appName.caseInsensitiveCompare(named) == .orderedSame
                || $0.appName.localizedCaseInsensitiveContains(named)
        }
    }

    /// The run did something in one of its windows: it's no longer empty.
    func changed(_ window: CGWindowID?, by caller: String) {
        guard let window, let display = displays[group(of: caller)] else { return }
        display.windows[window]?.changed = true
    }

    /// The next place on a caller's display (each window a little down and right of the last).
    func nextIndex(for caller: String) -> Int { displays[group(of: caller)]?.opened ?? 0 }

    // MARK: Show me

    /// The person asked to see it: the run's windows come to their main screen and forward (their own click), and are
    /// theirs from then on; the run goes on, and what it opens next still goes to its display. `raise`: brought
    /// forward too (the person's click); without, only moved there, behind what they're doing.
    func showMe(group: String, raise: Bool = true) {
        guard let display = displays[group], display.ready else { return }
        let windows = Array(display.windows.values).filter { !$0.shown }.sorted { $0.at < $1.at }
        for tracked in windows { display.windows[tracked.window]?.shown = true }
        // What it showed is the person's now: its group no longer has those apps to itself.
        letGoOfApps(group)
        let frame = display.frame
        let target = Self.personArea()
        let hands = self.hands
        Self.queue.async {
            var index = 0
            var last: Tracked?
            for tracked in windows {
                guard let now = hands.frame(tracked), frame.contains(CGPoint(x: now.midX, y: now.midY)) else { continue }
                hands.place(tracked, RunDisplayRules.frame(for: now.size, on: target, index: index))
                index += 1
                last = tracked
            }
            guard raise, let last else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { hands.raise(last) } }
        }
    }

    func showMe(caller: String) { showMe(group: group(of: caller)) }

    /// The run itself brings its windows to the person's screen (`petal_windows`, action show): moved there, behind
    /// what they're doing; nothing raised, nothing activated. How many came.
    func bringOut(for caller: String, _ done: @escaping @MainActor (Int) -> Void) {
        let group = group(of: caller)
        guard let display = displays[group], display.ready else { return done(0) }
        let windows = Array(display.windows.values).filter { !$0.shown }.sorted { $0.at < $1.at }
        for tracked in windows { display.windows[tracked.window]?.shown = true }
        letGoOfApps(group)
        let frame = display.frame
        let target = Self.personArea()
        let hands = self.hands
        Self.queue.async {
            var moved = 0
            for tracked in windows {
                guard let now = hands.frame(tracked), frame.contains(CGPoint(x: now.midX, y: now.midY)) else { continue }
                hands.place(tracked, RunDisplayRules.frame(for: now.size, on: target, index: moved))
                moved += 1
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(moved) } }
        }
    }

    // MARK: Two runs, one app

    /// A run asks for an app (its bundle id; `name` for what it says while it waits). `hold`: it's about to open
    /// something in it on its display, and has the app until `finished` and for as long as a window of it stays
    /// there; without, it's about to act in it once. Free, or its own: `done(nil)` at once. Another run's, on its
    /// display: it waits in order ("Waiting for TextEdit") and hears when the other ends or lets it go; `done` with
    /// a failure when waiting could never end, or the run itself ended first. Only runs with displays take turns:
    /// with none anywhere, everything goes ahead as always. Every `hold` that's granted must be given back with
    /// `finished`, whatever became of the open.
    func turn(_ caller: String, app bundle: String, name: String, hold: Bool, done: @escaping (Failure?) -> Void) {
        guard !bundle.isEmpty, !(displays.isEmpty && turns.holders.isEmpty && settling.isEmpty) else { return done(nil) }
        // The quick question acting in an app is the person's own request, in front of them: it never waits.
        guard RunDisplayRules.takesTurns(asker: asker(caller), hold: hold) else { return done(nil) }
        if !name.isEmpty { appNames[bundle] = name }
        let group = group(of: caller)
        // Being put away for a run that just ended: asked again once that's done.
        if settling[bundle] != nil, turns.holder(of: bundle) != group {
            if busyApps[group] == nil { busyApps[group] = name }
            afterSettling[bundle, default: []].append { [weak self] in
                guard let self else { return }
                if self.busyApps[group] == name { self.busyApps[group] = nil }
                self.turn(caller, app: bundle, name: name, hold: hold, done: done)
            }
            return
        }
        switch turns.ask(group, app: bundle, hold: hold) {
        case .has:
            if hold { claims[group, default: [:]][bundle, default: 0] += 1 }
            done(nil)
        case .circular:
            done(.circular(name))
        case .waiting:
            // Known as a run from here, so its ending (however it ends) is heard and its wait ends with it.
            if members[caller] == nil { register(caller, group: group) }
            turnWaiters[group, default: [:]][bundle, default: []].append(TurnWaiter(run: caller, hold: hold, done: done))
            refreshWaiting(group)
            watch()
        }
    }

    /// An open asked for with `turn(hold: true)` is over, whatever became of it: the group keeps the app only while
    /// a window of it is on its display (or it started the app); else the next in line has it.
    func finished(_ caller: String, app bundle: String) {
        let group = group(of: caller)
        if let count = claims[group]?[bundle] {
            claims[group]?[bundle] = count > 1 ? count - 1 : nil
            if claims[group]?.isEmpty == true { claims[group] = nil }
        }
        reconcile(group, bundle)
    }

    /// The group still uses the app on its display: an open of it is under way, a window of it is there that nobody
    /// took to the person's screen, or the group started it and it's still nobody else's.
    private func uses(_ group: String, _ bundle: String) -> Bool {
        if (claims[group]?[bundle] ?? 0) > 0 { return true }
        guard let display = displays[group] else { return false }
        if display.windows.values.contains(where: { $0.bundle == bundle && !$0.shown }) { return true }
        return display.launched.values.contains { started in
            started.bundle == bundle && !started.used && !display.windows.values.contains { $0.pid == started.pid && $0.shown }
        }
    }

    private func reconcile(_ group: String, _ bundle: String) {
        guard turns.holder(of: bundle) == group, !uses(group, bundle) else { return }
        grant(turns.letGo(group, app: bundle))
    }

    /// Every app a group (or every group) no longer uses goes to the next in line.
    private func letGoOfApps(_ only: String? = nil) {
        for (bundle, group) in turns.holders where only == nil || only == group { reconcile(group, bundle) }
    }

    private func grant(_ grants: [AppTurns.Grant]) {
        for grant in grants {
            // Still being put away for the run that had it: handed on once that's done.
            if settling[grant.app] != nil {
                afterSettling[grant.app, default: []].append { [weak self] in self?.deliver(grant) }
            } else {
                deliver(grant)
            }
        }
    }

    private func deliver(_ grant: AppTurns.Grant) {
        let list = turnWaiters[grant.group]?.removeValue(forKey: grant.app) ?? []
        if turnWaiters[grant.group]?.isEmpty == true { turnWaiters[grant.group] = nil }
        refreshWaiting(grant.group)
        let holding = list.filter(\.hold).count
        if holding > 0 { claims[grant.group, default: [:]][grant.app, default: 0] += holding }
        for waiter in list { waiter.done(nil) }
        // Nobody who keeps it (they only act in it once, or all gave up): the next in line at once.
        reconcile(grant.group, grant.app)
    }

    /// The app a group waits its turn for, where its state shows.
    private func refreshWaiting(_ group: String) {
        let bundle = turnWaiters[group]?.keys.sorted().first
        let name = bundle.map { appNames[$0] ?? $0 }
        if waitingApps[group] != name { waitingApps[group] = name }
    }

    /// A run ended while it waited its turn: it's told, and its group waits for that app no more unless another of
    /// its runs still does.
    private func failTurnWaiters(of run: String) {
        for (group, apps) in turnWaiters {
            for (bundle, list) in apps {
                let mine = list.filter { $0.run == run }
                guard !mine.isEmpty else { continue }
                let rest = list.filter { $0.run != run }
                turnWaiters[group]?[bundle] = rest.isEmpty ? nil : rest
                if rest.isEmpty { turns.stopWaiting(group, app: bundle) }
                for waiter in mine { waiter.done(.turnEnded(appNames[bundle] ?? bundle)) }
            }
            if turnWaiters[group]?.isEmpty == true { turnWaiters[group] = nil }
            refreshWaiting(group)
        }
    }

    /// A group's turns end (its display goes, or everything does): whoever of it waited is told, and every app it
    /// had goes to the next in line.
    private func endTurns(of group: String) {
        let apps = turnWaiters.removeValue(forKey: group) ?? [:]
        claims[group] = nil
        refreshWaiting(group)
        let grants = turns.leave(group)
        for (bundle, list) in apps {
            for waiter in list { waiter.done(.turnEnded(appNames[bundle] ?? bundle)) }
        }
        grant(grants)
    }

    /// The caller's act needs real keys in an app the person is using: it waits for them to leave it, and says so
    /// ("Waiting for TextEdit"). Nil: it waits no more.
    func personBusy(_ caller: String, app name: String?) {
        let group = group(of: caller)
        if busyApps[group] != name { busyApps[group] = name }
    }

    private func clearBusy(_ group: String) {
        if busyApps[group] != nil { busyApps[group] = nil }
    }

    /// The turns as they stand (for checks).
    var appTurns: AppTurns { turns }

    // MARK: Whether the person used an app a run started

    /// While any run has an app it started: which app comes to the front is heard, and one of those that does with
    /// the person's hands still is watched for their first key or click in it (`RunDisplayRules.personUsed`).
    private func watchApps() {
        let any = displays.values.contains { !$0.launched.isEmpty }
        if any, frontToken == nil, !Headless.on {
            frontToken = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                         object: nil, queue: .main) { [weak self] note in
                let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = running?.processIdentifier ?? 0
                MainActor.assumeIsolated { self?.cameForward(pid) }
            }
        } else if !any {
            if let frontToken { NSWorkspace.shared.notificationCenter.removeObserver(frontToken) }
            frontToken = nil
            stopFrontWatch()
        }
    }

    private func isLaunched(_ pid: pid_t) -> Bool {
        displays.values.contains { $0.launched[pid] != nil && $0.launched[pid]?.used == false }
    }

    /// The person used an app a run started: it's theirs from now on, never quit, and no longer the run's alone.
    func used(_ pid: pid_t) {
        for display in displays.values where display.launched[pid] != nil {
            display.launched[pid]?.used = true
            letGoOfApps(display.group)
        }
    }

    /// A run opened something in this app on the person's screen (`on: "screen"`), for them to see: if a run had
    /// started it on a display, it's the person's from now on.
    func handedOver(bundle: String) {
        guard !bundle.isEmpty else { return }
        for display in displays.values {
            for started in display.launched.values where started.bundle == bundle && !started.used { used(started.pid) }
        }
    }

    /// An app came to the front. One a run started: by the person's doing (their last key, click or scroll was a
    /// moment ago) it's theirs now; with their hands still it came forward by itself, and is watched while it's in
    /// front for their first key or click in it.
    func cameForward(_ pid: pid_t) {
        stopFrontWatch()
        guard pid > 0, isLaunched(pid) else { return }
        if RunDisplayRules.personUsed(idleAtFront: hands.idle(), idleNow: nil, frontFor: nil) { return used(pid) }
        frontWatch = (pid, ProcessInfo.processInfo.systemUptime)
        guard !Headless.on else { return }
        frontTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleFront() }
        }
    }

    /// While a run's app is in front: did the person press a key, click or scroll since it came forward?
    func sampleFront() {
        guard let watch = frontWatch else { return stopFrontWatch() }
        guard hands.front() == watch.pid, isLaunched(watch.pid) else { return stopFrontWatch() }
        let frontFor = ProcessInfo.processInfo.systemUptime - watch.since
        guard RunDisplayRules.personUsed(idleAtFront: nil, idleNow: hands.idle(), frontFor: frontFor) else { return }
        used(watch.pid)
        stopFrontWatch()
    }

    private func stopFrontWatch() {
        frontTimer?.invalidate()
        frontTimer = nil
        frontWatch = nil
    }

    // MARK: What a run leaves behind

    /// What Accessibility says of an attribute: its value, that there's none, or that it couldn't be read.
    enum Read { case value(Any), none, unknown }

    nonisolated static func read(_ element: AXUIElement, _ attribute: String) -> Read {
        var raw: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) {
        case .success: return raw.map { .value($0) } ?? .none
        case .noValue, .attributeUnsupported: return .none
        default: return .unknown
        }
    }

    /// Whether a window shows a document (a file, an address), and whether it says it has unsaved changes. A window
    /// of a kind that never says is `no`; one that couldn't be read is `unknown`.
    nonisolated static func state(of element: AXUIElement) -> (document: RunDisplayRules.Told, modified: RunDisplayRules.Told) {
        var document = RunDisplayRules.Told.no
        switch read(element, kAXDocumentAttribute) {
        case .none: break
        case .value(let value): document = (value as? String ?? "x").isEmpty ? .no : .yes
        case .unknown: document = .unknown
        }
        var modified = RunDisplayRules.Told.no
        switch read(element, "AXModified") {
        case .none: break
        case .value(let value): modified = (value as? Bool) == false ? .no : .yes
        case .unknown: modified = .unknown
        }
        return (document, modified)
    }

    /// Whether an app has unsaved changes Petal can read: from every window it lists (minimized ones too).
    nonisolated static func unsaved(pid: pid_t) -> RunDisplayRules.Told {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        switch read(app, kAXWindowsAttribute) {
        case .none:
            return RunDisplayRules.unsaved(listed: true, modified: [])
        case .unknown:
            return RunDisplayRules.unsaved(listed: false, modified: [])
        case .value(let raw):
            guard let windows = raw as? [AXUIElement] else { return RunDisplayRules.unsaved(listed: false, modified: []) }
            return RunDisplayRules.unsaved(listed: true, modified: windows.map { state(of: $0).modified })
        }
    }

    /// What reads and changes apps and windows when a run's leftovers are settled, its windows shown, and the
    /// person's use of its apps watched: Accessibility and the window server (`real`), or a check's made-up ones
    /// (`useMadeUp`), so that nothing real is read, moved, closed or quit there. Each may be called off the main
    /// thread, except `raise`.
    struct Hands: @unchecked Sendable {
        /// A window's frame now (the window server's coordinates); nil: it's gone.
        var frame: (Tracked) -> CGRect?
        /// The window server still lists it (its own list: a slow app is never taken for a closed window).
        var exists: (Tracked) -> Bool
        var state: (Tracked) -> (document: RunDisplayRules.Told, modified: RunDisplayRules.Told)
        /// Presses its close button.
        var close: (Tracked) -> Void
        /// Moves it (its position only): nothing raised, nothing activated.
        var place: (Tracked, CGRect) -> Void
        /// Brings it forward: only ever for the person's own click on Show me. On the main thread.
        var raise: (Tracked) -> Void
        var unsaved: (pid_t) -> RunDisplayRules.Told
        var running: (pid_t) -> Bool
        /// Asks an app to quit, politely (it may ask to save, or refuse); never forced.
        var quit: (pid_t) -> Void
        /// The app in front.
        var front: () -> pid_t?
        /// Seconds since the person's last key, click or scroll.
        var idle: () -> TimeInterval
        /// Waits a moment between two looks.
        var pause: (TimeInterval) -> Void

        static let real = Hands(
            frame: { Windows.frame(of: $0.element) },
            exists: { RunDisplays.windowNumbers(pid: $0.pid)[$0.window] != nil },
            state: { RunDisplays.state(of: $0.element) },
            close: { tracked in
                guard let button: AXUIElement = Windows.value(tracked.element, kAXCloseButtonAttribute) else { return }
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            },
            place: { tracked, frame in Windows.place(tracked.element, pid: tracked.pid, frame, size: false) },
            raise: { tracked in MainActor.assumeIsolated { Windows.raise(tracked.element, pid: tracked.pid) } },
            unsaved: { RunDisplays.unsaved(pid: $0) },
            // Asked of the system itself: an app object's own word for it is only brought up to date by the main run loop.
            running: { pid in pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) },
            quit: { pid in _ = NSRunningApplication(processIdentifier: pid)?.terminate() },
            front: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            idle: { Acting.idle() },
            pause: { usleep(useconds_t($0 * 1_000_000)) })
    }

    /// What a run leaves when its display goes.
    struct Leaving {
        var windows: [Tracked]
        var apps: [Launched]
        /// Its display, and where a window brought back goes (the window server's coordinates).
        var display: CGRect
        var target: CGRect
        /// The app in front as the run ended: one the person is in is in use, whatever else is known.
        var front: pid_t?
    }

    /// What settling did.
    struct Settled: Equatable {
        /// Apps asked to quit that went.
        var quit: [pid_t] = []
        /// Apps asked to quit that didn't go in time: their windows were settled one by one.
        var stayed: [pid_t] = []
        /// Apps the run started that were kept (the person used one, a window of it was shown, it has unsaved
        /// changes, or Petal couldn't tell).
        var kept: [pid_t] = []
        var closed: [CGWindowID] = []
        var broughtBack: [CGWindowID] = []
    }

    /// Puts away what a run left when its display goes. First the apps it started (`RunDisplayRules.leftover(app:)`):
    /// one the person didn't use, with no window brought to their screen and nothing unsaved, is asked to quit and
    /// given `quitBound` to go; its windows go with it. Then each window still there, by the rule
    /// (`RunDisplayRules.leftover`): closed when it's the run's own and holds nothing (and brought back after all if it
    /// didn't close), else brought back to the person's main screen, behind what they're doing. Off the main thread;
    /// past `deadline` the rest is left to macOS, which moves a removed display's windows to the main screen itself.
    nonisolated static func settle(_ leaving: Leaving, hands: Hands, deadline: Date) -> Settled {
        var result = Settled()
        var gone: Set<pid_t> = []
        // Apps the run started that the person used since: theirs now, with everything in them.
        var theirs: Set<pid_t> = []
        for started in leaving.apps.sorted(by: { $0.at < $1.at }) where Date() < deadline {
            // Gone already (the person quit it, or it ended): nothing of it is left.
            guard hands.running(started.pid) else { gone.insert(started.pid); continue }
            let shown = leaving.windows.contains { $0.pid == started.pid && $0.shown }
            let used = started.used || leaving.front == started.pid
            if used { theirs.insert(started.pid) }
            let left = RunDisplayRules.LeftApp(launched: true, used: used, shown: shown, unsaved: hands.unsaved(started.pid))
            guard RunDisplayRules.leftover(app: left) == .quit else { result.kept.append(started.pid); continue }
            hands.quit(started.pid)
            let bound = Date().addingTimeInterval(RunDisplayRules.quitBound)
            while hands.running(started.pid), Date() < bound { hands.pause(0.1) }
            if hands.running(started.pid) {
                // It asked something, or takes its time: its windows follow the rule for windows, never lost.
                result.stayed.append(started.pid)
            } else {
                result.quit.append(started.pid)
                gone.insert(started.pid)
            }
        }
        var index = 0
        for tracked in leaving.windows.sorted(by: { $0.at < $1.at }) where Date() < deadline && !gone.contains(tracked.pid) {
            // Gone already, or not on the display any more (the person or its app moved it): left alone.
            guard let frame = hands.frame(tracked) else { continue }
            let onDisplay = leaving.display.contains(CGPoint(x: frame.midX, y: frame.midY))
            var empty = false
            if onDisplay, !tracked.shown {
                let state = hands.state(tracked)
                empty = RunDisplayRules.holdsNothing(bare: tracked.bare, changed: tracked.changed, panel: tracked.panel,
                                                     document: state.document, modified: state.modified)
            }
            let left = RunDisplayRules.Left(opened: true, empty: empty, shown: tracked.shown || !onDisplay, theirs: theirs.contains(tracked.pid))
            var back = false
            switch RunDisplayRules.leftover(left) {
            case .leave: continue
            case .bringBack: back = true
            case .close:
                hands.close(tracked)
                hands.pause(0.25)
                // Still there (it asked something, or has no close button): never lost with the display.
                back = hands.frame(tracked) != nil
                if !back { result.closed.append(tracked.window) }
            }
            if back {
                hands.place(tracked, RunDisplayRules.frame(for: frame.size, on: leaving.target, index: index))
                result.broughtBack.append(tracked.window)
                index += 1
            }
        }
        return result
    }

    // MARK: Pictures

    /// A picture of a run's display, for the person's preview: the windows on it, never a private app's
    /// (`hiding`), never one of Petal's own.
    nonisolated static func picture(of id: CGDirectDisplayID, hiding: Set<pid_t>, height: CGFloat = 150) async -> NSImage? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let area = CGDisplayBounds(id)
        let me = ProcessInfo.processInfo.processIdentifier
        let shown = content.windows.filter { window in
            guard window.frame.intersects(area), let owner = window.owningApplication else { return false }
            return owner.processID != me && !hiding.contains(owner.processID)
        }
        let configuration = SCStreamConfiguration()
        let scale = height * 2 / max(1, area.height)
        configuration.width = Int(area.width * scale)
        configuration.height = Int(area.height * scale)
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, including: shown)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }

    /// New pictures of the displays the preview shows, kept on each (`Display.picture`). One round at a time.
    @ObservationIgnored private var picturing = false

    func refreshPictures() {
        guard !picturing else { return }
        let shown = displays.values.filter(\.ready)
        guard !shown.isEmpty else { return }
        picturing = true
        let hiding = app.assist.privatePIDs
        Task {
            for display in shown {
                let picture = await Self.picture(of: display.number, hiding: hiding)
                if display.ready, let picture { display.picture = picture }
            }
            picturing = false
        }
    }

    // MARK: Tiles for sessions outside Petal

    /// The displays of AI sessions outside Petal: each gets a tile of its own in the AI button's preview (a note's
    /// and a chat's show on their own).
    var outside: [Display] {
        displays.values.filter { $0.group.hasPrefix("mcp-") && $0.ready }.sorted { $0.group < $1.group }
    }

    func display(tile id: UUID) -> Display? { displays.values.first { $0.id == id } }

    /// Stop on an outside session's tile: what it was doing in apps stops, and its display goes.
    func stop(tile id: UUID) {
        guard let display = display(tile: id) else { return }
        let group = display.group
        for run in plan.runs(in: group) {
            app.assist.hungUp(run)
            members[run] = nil
        }
        apply(plan.end(group: group))
    }

    // MARK: For checks

    /// The plan, as it stands.
    var standing: RunDisplayPlan { plan }
}

/// What Launch Services answered an open with, handed from its own thread to the one that waits for it.
private final class OpenAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var process: pid_t?
    private var words: String?
    func set(pid: pid_t?, error: String?) { lock.withLock { process = pid; words = error } }
    var pid: pid_t? { lock.withLock { process } }
    var error: String? { lock.withLock { words } }
}

extension AppWindow {
    /// The window server's number for it, when its id holds one ("<pid>-w<number>").
    var number: CGWindowID? {
        guard let mark = id.range(of: "-w") else { return nil }
        return CGWindowID(id[mark.upperBound...])
    }
}
