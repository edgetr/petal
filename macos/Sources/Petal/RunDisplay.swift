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

/// A hidden display for each Petal AI run (`runDisplays`, off by default): the windows a run opens go to a display
/// of its own, which the person never sees and their pointer can't reach, so nothing a run does shows up in front of
/// them. Questions, Buy cards and the vault's card stay over the dock or on the note, on the person's screen.
///
/// A run is a helper in a note (with everything that note starts), a chat's reply, or an AI session outside Petal
/// (`RunDisplayRules.group`). It gets a display the first time it puts a window on the screen, never before; past
/// the limit (`RunDisplayRules.limit`) it waits its turn ("Waiting for a display"). Its display goes when it ends,
/// however it ends; a window still on it is closed if it's the run's own and empty, else brought back to the person's
/// main screen (`RunDisplayRules.leftover`). `RunDisplayPlan` decides all of that; this makes the displays and moves
/// the windows, through Accessibility alone, never activating an app or bringing anything forward.
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
        /// The run did something in it since.
        var changed = false
        /// The person took it to their screen (Show me).
        var shown = false
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
        var words: String {
            switch self {
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

    private var plan: RunDisplayPlan
    private(set) var displays: [String: Display] = [:]
    @ObservationIgnored private var members: [String: Member] = [:]
    @ObservationIgnored private var waiters: [String: [Waiter]] = [:]
    /// The groups waiting for a display now.
    private(set) var waiting: Set<String> = []
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

    /// A check's made-up displays instead of real ones (HelpersCheck): nothing is ever made or arranged for them.
    func useMadeUp(_ maker: @escaping Maker, placed: @escaping (CGDirectDisplayID, CGSize) -> Placing) {
        self.maker = maker
        placer = placed
    }

    // MARK: Whether, and for whom

    /// `runDisplays` is on, and this Petal can make displays.
    var on: Bool { PetalApp.started && app.config.bool("runDisplays") && maker != nil }

    /// Why there are none, in the person's words, for Settings; nil when they can be made.
    static var unavailableWords: String? {
        VirtualDisplay.available ? nil : "This Mac's macOS doesn't let Petal make a hidden display, so runs work on your screen as before."
    }

    var limit: Int {
        RunDisplayRules.limit(memory: ProcessInfo.processInfo.physicalMemory, setting: Int(app.config.number("runDisplaysLimit")))
    }

    func group(of caller: String) -> String {
        RunDisplayRules.group(caller: caller, paper: app.claude.note(withID: caller)?.paper)
    }

    func asker(_ caller: String) -> RunDisplayRules.Asker {
        if caller.hasPrefix("mcp-") { return .outside }
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
        guard PetalApp.started, app.config.bool("runDisplays") else { return done(.failure(.off)) }
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
        apply(plan.leave(run))
    }

    /// The setting changed: turned off, every display goes now; the limit raised, the next ones waiting get theirs.
    func settingsChanged() {
        guard PetalApp.started else { return }
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
        let target = Self.personArea()
        let deadline = Date().addingTimeInterval(1.5)
        for display in displays.values {
            var index = 0
            for tracked in display.windows.values where Date() < deadline && !tracked.shown {
                guard let frame = Windows.frame(of: tracked.element), display.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
                Windows.place(tracked.element, pid: tracked.pid, RunDisplayRules.frame(for: frame.size, on: target, index: index), size: false)
                index += 1
            }
            display.screen?.remove()
            display.screen = nil
        }
        displays = [:]
        members = [:]
        waiters = [:]
        waiting = []
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
        let left = Array(display.windows.values)
        let frame = display.frame
        display.windows = [:]
        guard display.ready, !left.isEmpty else { return release(display) }
        let target = Self.personArea()
        Self.queue.async {
            Self.settle(left, display: frame, to: target, deadline: Date().addingTimeInterval(4))
            DispatchQueue.main.async { MainActor.assumeIsolated { self.release(display) } }
        }
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
        guard !members.isEmpty || !displays.isEmpty else {
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
        if !app.config.bool("runDisplays") { return endAll() }
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
        watch()
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
    nonisolated static func newWindows(bundle: String, before: Set<CGWindowID>, timeout: TimeInterval, live: () -> Bool)
        -> [(window: CGWindowID, pid: pid_t, element: AXUIElement)] {
        let deadline = Date().addingTimeInterval(timeout)
        while live() {
            let now = windowNumbers(bundle: bundle).filter { !before.contains($0.key) }
            var found: [(window: CGWindowID, pid: pid_t, element: AXUIElement)] = []
            for (number, window) in now {
                // Only an ordinary window Accessibility lists (never a sheet, a palette or a tooltip).
                guard let element = element(number, pid: window.pid),
                      (Windows.value(element, kAXSubroleAttribute) as String?) == (kAXStandardWindowSubrole as String) else { continue }
                found.append((number, window.pid, element))
            }
            if !found.isEmpty { return found }
            guard Date() < deadline else { break }
            usleep(150_000)
        }
        return []
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
    func track(_ windows: [(window: CGWindowID, pid: pid_t, element: AXUIElement)], for caller: String, bare: Bool) {
        guard let display = displays[group(of: caller)] else { return }
        for item in windows {
            let running = NSRunningApplication(processIdentifier: item.pid)
            display.windows[item.window] = Tracked(window: item.window, pid: item.pid, element: item.element,
                                                   bundle: running?.bundleIdentifier ?? "", appName: running?.localizedName ?? "", bare: bare)
            display.opened += 1
        }
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
    /// theirs from then on; the run goes on, and what it opens next still goes to its display.
    func showMe(group: String) {
        guard let display = displays[group], display.ready else { return }
        let windows = Array(display.windows.values).filter { !$0.shown }.sorted { $0.at < $1.at }
        for tracked in windows { display.windows[tracked.window]?.shown = true }
        let frame = display.frame
        let target = Self.personArea()
        Self.queue.async {
            var index = 0
            var last: Tracked?
            for tracked in windows {
                guard let now = Windows.frame(of: tracked.element), frame.contains(CGPoint(x: now.midX, y: now.midY)) else { continue }
                Windows.place(tracked.element, pid: tracked.pid, RunDisplayRules.frame(for: now.size, on: target, index: index), size: false)
                index += 1
                last = tracked
            }
            guard let last else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { Windows.raise(last.element, pid: last.pid) } }
        }
    }

    func showMe(caller: String) { showMe(group: group(of: caller)) }

    /// The run itself brings its windows to the person's screen (`petal_windows`, action show): moved there, behind
    /// what they're doing; nothing raised, nothing activated. How many came.
    func bringOut(for caller: String, _ done: @escaping @MainActor (Int) -> Void) {
        guard let display = displays[group(of: caller)], display.ready else { return done(0) }
        let windows = Array(display.windows.values).filter { !$0.shown }.sorted { $0.at < $1.at }
        for tracked in windows { display.windows[tracked.window]?.shown = true }
        let frame = display.frame
        let target = Self.personArea()
        Self.queue.async {
            var moved = 0
            for tracked in windows {
                guard let now = Windows.frame(of: tracked.element), frame.contains(CGPoint(x: now.midX, y: now.midY)) else { continue }
                Windows.place(tracked.element, pid: tracked.pid, RunDisplayRules.frame(for: now.size, on: target, index: moved), size: false)
                moved += 1
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(moved) } }
        }
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

    /// A window is empty when the run opened it bare, did nothing in it, and it reads as holding no document and no
    /// unsaved change. Anything that can't be read is not empty.
    nonisolated static func isEmpty(_ tracked: Tracked) -> Bool {
        guard tracked.bare, !tracked.changed else { return false }
        switch read(tracked.element, kAXDocumentAttribute) {
        case .none: break
        case .value(let document): guard (document as? String ?? "x").isEmpty else { return false }
        case .unknown: return false
        }
        switch read(tracked.element, "AXModified") {
        case .none: return true
        case .value(let modified): return (modified as? Bool) == false
        case .unknown: return false
        }
    }

    /// Each window a run left on its display, by the rule (`RunDisplayRules.leftover`): closed when it's the run's own
    /// and empty (and brought back after all if it didn't close), else brought back to the person's main screen, behind
    /// what they're doing. Off the main thread; past `deadline` the rest is left to macOS, which moves a removed
    /// display's windows to the main screen itself.
    nonisolated static func settle(_ windows: [Tracked], display: CGRect, to target: CGRect, deadline: Date) {
        var index = 0
        for tracked in windows.sorted(by: { $0.at < $1.at }) where Date() < deadline {
            // Gone already, or not on the display any more (the person or its app moved it): left alone.
            guard let frame = Windows.frame(of: tracked.element) else { continue }
            let onDisplay = display.contains(CGPoint(x: frame.midX, y: frame.midY))
            let left = RunDisplayRules.Left(opened: true, empty: onDisplay && !tracked.shown && isEmpty(tracked), shown: tracked.shown || !onDisplay)
            var back = false
            switch RunDisplayRules.leftover(left) {
            case .leave: continue
            case .bringBack: back = true
            case .close:
                if let button: AXUIElement = Windows.value(tracked.element, kAXCloseButtonAttribute) {
                    AXUIElementPerformAction(button, kAXPressAction as CFString)
                    usleep(250_000)
                }
                // Still there (it asked something, or has no close button): never lost with the display.
                back = Windows.frame(of: tracked.element) != nil
            }
            if back {
                Windows.place(tracked.element, pid: tracked.pid, RunDisplayRules.frame(for: frame.size, on: target, index: index), size: false)
                index += 1
            }
        }
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
