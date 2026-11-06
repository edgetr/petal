import AppKit
import ApplicationServices

/// A request counter any thread can bump or check at once (behind a lock): a newer request makes older ones stand
/// down, even while they wait on an app that's slow to answer.
final class Generation: @unchecked Sendable {
    private let lock = NSLock()
    private var newest = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        newest += 1
        return newest
    }

    func cancel() { _ = next() }

    func current(_ request: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return newest == request
    }
}

/// An app's window, as Accessibility sees it.
struct AppWindow: Identifiable, Equatable {
    let id: String          // pid and the window server's number for it (else its place in the app's list)
    let pid: pid_t
    let title: String
    let minimized: Bool
    let frame: CGRect       // top-left origin, as Accessibility and the window server count
    let element: AXUIElement

    static func == (a: AppWindow, b: AppWindow) -> Bool {
        a.id == b.id && a.title == b.title && a.minimized == b.minimized && a.frame == b.frame
    }
}

/// Windows through macOS's Accessibility API: which windows an app has, which are minimized, the title of the
/// window in front, and bringing one particular window forward. macOS asks the person once for permission
/// (System Settings > Privacy & Security > Accessibility); until then these answer empty and the dock still works.
@MainActor
enum Windows {
    nonisolated static var trusted: Bool { AXIsProcessTrusted() }

    /// Every Accessibility call gives up after 0.3 s, so a hung app can't hang the dock. Called once at start.
    static func limitWaiting() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
    }

    /// Brings an app forward. Petal's dock never becomes the active app, and macOS lets only the active app hand
    /// activation on, so this goes through Launch Services, which may always do it.
    static func bringForward(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { app.activate(); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Shows macOS's own prompt, once, pointing at the Accessibility list.
    static func askForPermission() {
        let key = "AXTrustedCheckOptionPrompt"   // kAXTrustedCheckOptionPrompt, which Swift 6 calls unsafe to share
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    nonisolated static func windows(of pid: pid_t) -> [AppWindow] {
        guard trusted else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)   // a hung app mustn't hang the dock
        guard let list: [AXUIElement] = value(app, kAXWindowsAttribute) else { return [] }
        var result: [AppWindow] = []
        for (index, window) in list.enumerated() {
            let minimized: Bool = value(window, kAXMinimizedAttribute) ?? false
            // Only the person's own windows, not dialogs or palettes. A minimized window calls itself a dialog
            // (macOS 26 and later), so minimized ones count whatever they say.
            let role: String? = value(window, kAXSubroleAttribute)
            guard role == kAXStandardWindowSubrole as String || minimized else { continue }
            let title: String = value(window, kAXTitleAttribute) ?? ""
            var frame = CGRect.zero
            if let position: AXValue = value(window, kAXPositionAttribute), let size: AXValue = value(window, kAXSizeAttribute) {
                var point = CGPoint.zero, extent = CGSize.zero
                AXValueGetValue(position, .cgPoint, &point)
                AXValueGetValue(size, .cgSize, &extent)
                frame = CGRect(origin: point, size: extent)
            }
            // The window server's number stays with the window as others open, close and minimize around it.
            let key = id(of: window).map { "\(pid)-w\($0)" } ?? "\(pid)-\(index)"
            result.append(AppWindow(id: key, pid: pid, title: title, minimized: minimized,
                                    frame: frame, element: window))
        }
        return result
    }

    /// Brings one window forward: unminimizes it, raises it, and makes its app the active one. The pointer stays.
    /// Brings one window to the front. A window on this Desktop comes forward through Accessibility, at once; one
    /// elsewhere (another Desktop, minimized) goes through Launch Services, which also switches Desktop.
    ///
    /// This window is raised last, after its app comes forward, and once more a moment later: bringing an app
    /// forward through Launch Services asks it to reopen, and an app like Zoom answers by showing its main window
    /// over the one asked for.
    /// Each focus request; a later one makes an earlier one stand down, its delayed retries included. A counter
    /// behind a lock, so a new request reaches it at once, never waiting behind an app that's slow to answer.
    nonisolated static let focusing = Generation()
    /// Where focusing happens: every Accessibility call and Launch Services, never on the dock's main thread.
    nonisolated static let focusQueue = DispatchQueue(label: "petal.windows.focus", qos: .userInitiated)

    static func focus(_ window: AppWindow, onScreen: Bool = false) {
        let ticket = focusing.next()
        let element = window.element, pid = window.pid, minimized = window.minimized
        let app = NSRunningApplication(processIdentifier: window.pid)
        let url = app?.bundleURL, hidden = app?.isHidden ?? false
        focusQueue.async {
            guard focusing.current(ticket) else { return }
            if minimized { AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            let raise = {
                guard focusing.current(ticket) else { return }
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            let bring = {
                guard focusing.current(ticket) else { return }
                if let url {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.addsToRecentItems = false
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                } else {
                    DispatchQueue.main.async { app?.activate() }
                }
            }
            raise()
            guard app != nil else { return }
            var forward = false
            if onScreen && !minimized && !hidden && focusing.current(ticket) {
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.3)
                forward = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
            }
            if !forward { bring() }
            raise()
            // Some apps (Chromium browsers) say yes to coming forward through Accessibility and don't: if it isn't
            // in front a moment later, Launch Services brings it, which always works.
            if forward {
                focusQueue.asyncAfter(deadline: .now() + 0.15) {
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return }
                    bring()
                    focusQueue.asyncAfter(deadline: .now() + 0.2) { raise() }
                }
            }
            for delay in forward ? [0.12] : [0.15, 0.4] {
                focusQueue.asyncAfter(deadline: .now() + delay) { raise() }
            }
        }
    }

    /// Moves and resizes a window (top-left origin).
    static func setFrame(_ window: AppWindow, _ frame: CGRect) {
        var origin = frame.origin, size = frame.size
        if frame.origin != window.frame.origin, let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, value)
        }
        if frame.size != window.frame.size, let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, value)
        }
    }

    static func minimize(_ window: AppWindow) {
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    static func close(_ window: AppWindow) {
        guard let button: AXUIElement = value(window.element, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    /// The title of the front window of the app in front: a browser's is its tab's title.
    static func frontTitle() -> String {
        guard trusted, let app = NSWorkspace.shared.frontmostApplication else { return "" }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard let window: AXUIElement = value(element, kAXFocusedWindowAttribute) else { return "" }
        return value(window, kAXTitleAttribute) ?? ""
    }

    /// Presses the app's menu item whose shortcut is ⌘ plus `key` (no other modifiers), the way choosing it from the
    /// menu would. Returns false when there's none, or no Accessibility. Off the main thread.
    nonisolated static func pressMenuItem(pid: pid_t, key: String) -> Bool {
        guard trusted else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar: AXUIElement = value(app, kAXMenuBarAttribute),
              let menus: [AXUIElement] = value(bar, kAXChildrenAttribute) else { return false }
        func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 4, let children: [AXUIElement] = value(element, kAXChildrenAttribute) else { return nil }
            for child in children {
                if let char: String = value(child, kAXMenuItemCmdCharAttribute), char.uppercased() == key,
                   let modifiers: Int = value(child, kAXMenuItemCmdModifiersAttribute), modifiers == 0,
                   (value(child, kAXEnabledAttribute) as Bool?) != false {
                    return child
                }
                if let found = find(child, depth: depth + 1) { return found }
            }
            return nil
        }
        for menu in menus.dropFirst() {   // the first is the app's own menu (About, Quit)
            if let item = find(menu, depth: 0) {
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    nonisolated static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw else { return nil }
        return raw as? T
    }
}

// MARK: - Managing windows (per-mode windows and tiling)

/// A window on a Desktop that's showing, as the window server lists it (front to back): its id, owner, and frame in
/// Accessibility's coordinates. Windows parked off-screen by Parking are listed too: one point of them is showing.
struct ScreenWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let bundleID: String
    let frame: CGRect
}

extension Windows {
    /// Per-mode windows and tiling, from launch to quit (App.swift's start and stop).
    static func startManaging() {
        Parking.start()
        Tiling.start()
    }

    static func stopManaging() {
        Tiling.stop()
        Parking.stop()
    }

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    /// `_AXUIElementGetWindow`, the private call every window manager uses to tie an Accessibility window to the
    /// window server's id. Looked up at run time, so a macOS without it leaves per-mode windows and tiling idle
    /// instead of failing to launch.
    nonisolated private static let getWindow: GetWindow? = {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }   // RTLD_DEFAULT
        return unsafeBitCast(pointer, to: GetWindow.self)
    }()

    nonisolated static var canManage: Bool { getWindow != nil }

    /// The window server's id of an Accessibility window.
    nonisolated static func id(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        return getWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// Every app window on the Desktops showing now, front to back, Petal's own left out.
    static func onScreen() -> [ScreenWindow] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        var bundles: [pid_t: String] = [:]
        var result: [ScreenWindow] = []
        for window in info {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let number = window[kCGWindowNumber as String] as? CGWindowID,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width > 20, bounds.height > 20,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            if bundles[pid] == nil {
                let app = NSRunningApplication(processIdentifier: pid)
                bundles[pid] = app?.activationPolicy == .regular ? (app?.bundleIdentifier ?? "") : ""
            }
            guard let bundleID = bundles[pid], !bundleID.isEmpty else { continue }
            result.append(ScreenWindow(id: number, pid: pid, bundleID: bundleID, frame: bounds))
        }
        return result
    }

    private static var elements: [CGWindowID: AXUIElement] = [:]
    private static var listed: [pid_t: Date] = [:]

    /// The Accessibility window for a window server id. Accessibility lists only the windows of the Desktops showing
    /// (and minimized ones), so a window elsewhere is found once its Desktop shows, or through an element kept from before.
    static func element(_ id: CGWindowID, pid: pid_t) -> AXUIElement? {
        if let known = elements[id] { return known }
        guard trusted, Date().timeIntervalSince(listed[pid] ?? .distantPast) > 0.5 else { return nil }
        listed[pid] = Date()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        for window in value(app, kAXWindowsAttribute) as [AXUIElement]? ?? [] {
            if let windowID = self.id(of: window) { elements[windowID] = window }
        }
        return elements[id]
    }

    static func remember(_ element: AXUIElement, as id: CGWindowID) { elements[id] = element }
    static func forget(_ id: CGWindowID) { elements[id] = nil }
    static func forget(pid: pid_t) {
        listed[pid] = nil
        elements = elements.filter { _, element in
            var owner: pid_t = 0
            return AXUIElementGetPid(element, &owner) == .success && owner != pid
        }
    }

    /// A window's frame now (top-left origin), asked of the app itself.
    nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = value(element, kAXPositionAttribute), let size: AXValue = value(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    /// An ordinary document window (not a dialog, sheet, palette or panel).
    static func isStandard(_ element: AXUIElement) -> Bool {
        (value(element, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole as String
    }

    static func isResizable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    static func isMinimized(_ element: AXUIElement) -> Bool { value(element, kAXMinimizedAttribute) ?? false }
    static func isFullScreen(_ element: AXUIElement) -> Bool { value(element, "AXFullScreen") ?? false }

    /// Moves (and, with `size`, resizes) a window at once, with no animation. Apps that turn on Accessibility's
    /// enhanced interface (for VoiceOver and the like) animate every move, so it's off for the moment of the move, as
    /// Rectangle and AeroSpace do. Returns the frame the app accepted.
    @discardableResult
    nonisolated static func place(_ element: AXUIElement, pid: pid_t, _ frame: CGRect, size: Bool = true) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let enhanced: Bool = value(app, "AXEnhancedUserInterface") ?? false
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        var origin = frame.origin, extent = frame.size
        let sizeValue = AXValueCreate(.cgSize, &extent)
        // Size, then position, then size again: a window moving to a smaller screen first shrinks, and one the
        // screen's edge had held back gets its full size once it's in place.
        if size, let sizeValue { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue) }
        if let point = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, point) }
        if size, let sizeValue { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue) }
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        return self.frame(of: element)
    }

    /// The window that has focus, in the app in front.
    static func focused() -> (pid: pid_t, element: AXUIElement, id: CGWindowID)? {
        guard trusted, let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let window: AXUIElement = value(app, kAXFocusedWindowAttribute), let id = id(of: window) else { return nil }
        elements[id] = window
        return (front.processIdentifier, window, id)
    }

    /// Brings one window forward and gives it focus. The pointer stays where it is.
    static func raise(_ element: AXUIElement, pid: pid_t) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if let app = NSRunningApplication(processIdentifier: pid), !app.isActive { bringForward(app) }
    }

    /// Each screen's frame and visible frame in Accessibility's coordinates, with the Desktop it shows (nil on a
    /// full-screen app's Space).
    static func screens() -> [(screen: NSScreen, frame: CGRect, visible: CGRect, desktop: Int?)] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.map { ($0, ScreenArea.toAX($0.frame, mainTop: top), ScreenArea.toAX($0.visibleFrame, mainTop: top), Spaces.desktop(on: $0)) }
    }

    /// Where a window may go on a screen: its visible frame, less Petal's dock strip while the dock shows and doesn't
    /// auto-hide (and, with `respectClear`, only while keepWindowsClear is on).
    static func usableArea(frame: CGRect, visible: CGRect, respectClear: Bool) -> CGRect {
        guard PetalApp.started else { return visible }
        let app = PetalApp.shared, config = app.config
        guard app.docks.shown, !config.autoHide, !respectClear || config.keepWindowsClear else { return visible }
        // The same strip as Dock.swift's keepWindowsClear keeps: up to the dock's glass.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let screen = NSScreen.screens.first { ScreenArea.toAX($0.frame, mainTop: top).equalTo(frame, within: 1) }
        guard let reserve = app.docks.reach(on: screen) else { return visible }
        return ScreenArea.usable(visible: visible, screen: frame, position: config.position, reserve: reserve)
    }
}

/// What windows do, for the dock, Parking and Tiling: macOS tells other apps nothing about windows opening, closing,
/// moving or minimizing, except through an Accessibility observer on each app. Observers run only while something
/// listens and Petal may use Accessibility, and start or stop when that permission changes, without a restart. They
/// live on a thread of their own (`AXWatcher`): adding one asks the app, and a hung app must never stall the dock.
/// Listeners hear about them on the main thread.
@MainActor
final class WindowEvents {
    static let shared = WindowEvents()

    /// `missionControl`: Mission Control (or App Exposé) opened; `missionControlEnded`: it closed. macOS's Dock says
    /// so through Accessibility.
    enum Kind { case created, closed, focused, minimized, unminimized, moved, resized, activated, launched, quit, hidden, shown, space, screens,
                     missionControl, missionControlEnded }
    struct Event {
        let kind: Kind
        let pid: pid_t
        let window: CGWindowID?
        let element: AXUIElement?
    }

    private var listeners: [String: (Event) -> Void] = [:]
    private var tokens: [NSObjectProtocol] = []
    /// The observers are running: something listens, and Petal may use Accessibility.
    private(set) var live = false

    func listen(_ key: String, _ handler: @escaping (Event) -> Void) {
        listeners[key] = handler
        checkPermission()
    }

    func stopListening(_ key: String) {
        listeners[key] = nil
        checkPermission()
    }

    /// Starts the observers once Accessibility is allowed and someone listens, and stops them when it's taken away or
    /// nobody does. The dock asks on its timer, so permission granted in System Settings takes effect within a second.
    func checkPermission() {
        let wanted = !listeners.isEmpty && Windows.trusted
        if wanted != live { wanted ? start() : stop() }
        if live { AXWatcher.shared.watchDock() }   // after Petal restarts macOS's Dock, for Mission Control
    }

    fileprivate func send(_ event: Event) {
        guard live else { return }   // one that left the observers' thread just before they stopped
        for handler in listeners.values { handler(event) }
    }

    private func send(_ kind: Kind, pid: pid_t) { send(Event(kind: kind, pid: pid, window: nil, element: nil)) }

    private func start() {
        live = true
        AXWatcher.shared.start()
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ body: @escaping @MainActor (NSRunningApplication?) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { body(app) }
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            AXWatcher.shared.observe(app)
            send(.launched, pid: app.processIdentifier)
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            AXWatcher.shared.forget(app.processIdentifier)
            Windows.forget(pid: app.processIdentifier)
            send(.quit, pid: app.processIdentifier)
        }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            AXWatcher.shared.observe(app)   // an app that wasn't ready when it launched
            send(.activated, pid: app.processIdentifier)
        }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            // Accessibility lists only the windows of the Desktops showing: those of the one just shown are new to it.
            AXWatcher.shared.watchAll()
            self?.send(.space, pid: 0)
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.screens, pid: 0) }
        })
    }

    private func stop() {
        live = false
        for token in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        tokens = []
        AXWatcher.shared.stop()
    }
}

/// Every app's Accessibility observer, on a thread of its own with its own run loop. Adding an observer, listing an
/// app's windows and asking a window's id all wait on the app (up to 0.3 s each, for one that hangs), so none of it
/// happens on the main thread. Everything below runs on this thread; WindowEvents calls in through `perform`.
final class AXWatcher: @unchecked Sendable {
    static let shared = AXWatcher()

    private var runLoop: CFRunLoop!
    private var observers: [pid_t: AXObserver] = [:]
    /// macOS's Dock (0 until it's watched), watched only for Mission Control, never for its windows.
    private var dockPID: pid_t = 0
    private var windowIDs: [AXUIElement: CGWindowID] = [:]
    private var running = false
    private var generation = 0   // retries from before a stop are dropped

    /// On the app itself: windows opening, focus, hiding, and (as well as on each window, for one not watched yet)
    /// minimizing, so a minimized window reaches the dock even if its own observer was never added.
    private static let appNotifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                                           kAXApplicationHiddenNotification, kAXApplicationShownNotification,
                                           kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]
    private static let windowNotifications = [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                                              kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]
    /// On macOS's Dock, which draws Mission Control: it opening (all windows, or one app's), and closing. Showing the
    /// desktop counts as closing, since the Dock doesn't come out for it. (yabai watches the same four.)
    private static let dockID = "com.apple.dock"
    private static let missionControlOpened = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows"]
    private static let missionControlClosed = ["AXExposeExit", "AXExposeShowDesktop"]

    private init() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            runLoop = CFRunLoopGetCurrent()
            RunLoop.current.add(NSMachPort(), forMode: .default)   // keeps the run loop waiting before any observer exists
            ready.signal()
            while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        thread.name = "petal.window-events"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
    }

    private func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: Called from the main thread

    func start() {
        perform { [self] in
            running = true
            generation += 1
            for app in NSWorkspace.shared.runningApplications { observe(app, attempt: 0, generation: generation) }
        }
    }

    func stop() {
        perform { [self] in
            running = false
            generation += 1
            for observer in observers.values {
                CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            observers = [:]
            windowIDs = [:]
            dockPID = 0
        }
    }

    func observe(_ app: NSRunningApplication) {
        perform { [self] in observe(app, attempt: 0, generation: generation) }
    }

    /// Watches macOS's Dock again if it isn't watched: Petal restarts it when it hides it, and macOS may not say
    /// when it's back. Asks Launch Services, so it's on this thread.
    func watchDock() {
        perform { [self] in
            guard running, dockPID == 0,
                  let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockID).first else { return }
            observe(dock, attempt: 0, generation: generation)
        }
    }

    func forget(_ pid: pid_t) {
        perform { [self] in
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            if pid == dockPID { dockPID = 0 }
            windowIDs = windowIDs.filter { element, _ in
                var owner: pid_t = 0
                return AXUIElementGetPid(element, &owner) == .success && owner != pid
            }
        }
    }

    /// Watches every window not watched yet, of every app: after a Desktop change, which brings windows into view.
    func watchAll() {
        perform { [self] in for pid in Array(observers.keys) { watchAll(pid) } }
    }

    /// How many apps and windows are being watched (`Petal --bench`). Waits for this thread.
    func counts() -> (apps: Int, windows: Int) {
        var result = (0, 0)
        let done = DispatchSemaphore(value: 0)
        perform { [self] in result = (observers.count, windowIDs.count); done.signal() }
        done.wait()
        return result
    }

    // MARK: On this thread

    private func observe(_ app: NSRunningApplication, attempt: Int, generation: Int) {
        let pid = app.processIdentifier
        let isDock = app.bundleIdentifier == Self.dockID
        guard running, generation == self.generation, observers[pid] == nil, app.activationPolicy == .regular || isDock,
              pid != ProcessInfo.processInfo.processIdentifier, !app.isTerminated else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, _ in
            AXWatcher.shared.received(notification as String, element)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var added = 0
        let names = isDock ? Self.missionControlOpened + Self.missionControlClosed : Self.appNotifications
        for name in names where AXObserverAddNotification(observer, element, name as CFString, nil) == .success { added += 1 }
        guard added > 0 else {
            // An app that has only just launched may not answer yet: try again a few times.
            if attempt < 5 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5 * Double(attempt + 1)) { [self] in
                    perform { [self] in observe(app, attempt: attempt + 1, generation: generation) }
                }
            }
            return
        }
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        if isDock { dockPID = pid } else { watchAll(pid) }
    }

    private func watchAll(_ pid: pid_t) {
        guard pid != dockPID else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        for window in Windows.value(app, kAXWindowsAttribute) as [AXUIElement]? ?? [] where windowIDs[window] == nil {
            watch(window, pid: pid)
        }
    }

    private func watch(_ window: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid], let id = Windows.id(of: window) else { return }
        windowIDs[window] = id
        DispatchQueue.main.async { MainActor.assumeIsolated { Windows.remember(window, as: id) } }
        for name in Self.windowNotifications { AXObserverAddNotification(observer, window, name as CFString, nil) }
    }

    private func received(_ name: String, _ element: AXUIElement) {
        guard running else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        func send(_ kind: WindowEvents.Kind, window: CGWindowID? = nil, element: AXUIElement? = nil) {
            let event = WindowEvents.Event(kind: kind, pid: pid, window: window, element: element)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if kind == .closed, let window { Windows.forget(window) }
                    WindowEvents.shared.send(event)
                }
            }
        }
        switch name {
        case kAXWindowCreatedNotification:
            watch(element, pid: pid)
            send(.created, window: windowIDs[element], element: element)
        case kAXUIElementDestroyedNotification:
            // A closed window can't be asked its id any more: it's the one remembered for this element.
            guard let id = windowIDs.removeValue(forKey: element) else { return }
            send(.closed, window: id)
        case kAXFocusedWindowChangedNotification:
            if windowIDs[element] == nil { watch(element, pid: pid) }
            send(.focused, window: windowIDs[element], element: element)
        case kAXWindowMiniaturizedNotification: send(.minimized, window: windowIDs[element], element: element)
        case kAXWindowDeminiaturizedNotification: send(.unminimized, window: windowIDs[element], element: element)
        case kAXMovedNotification: send(.moved, window: windowIDs[element], element: element)
        case kAXResizedNotification: send(.resized, window: windowIDs[element], element: element)
        case kAXApplicationHiddenNotification: send(.hidden)
        case kAXApplicationShownNotification: send(.shown)
        case _ where Self.missionControlOpened.contains(name): send(.missionControl)
        case _ where Self.missionControlClosed.contains(name): send(.missionControlEnded)
        default: break
        }
    }
}
