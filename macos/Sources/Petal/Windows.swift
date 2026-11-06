import AppKit
import ApplicationServices

/// An app's window, as Accessibility sees it.
struct AppWindow: Identifiable, Equatable {
    let id: String          // pid and position in the app's window list, stable while the window stays
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
            guard let role: String = value(window, kAXSubroleAttribute), role == kAXStandardWindowSubrole as String else { continue }
            let title: String = value(window, kAXTitleAttribute) ?? ""
            let minimized: Bool = value(window, kAXMinimizedAttribute) ?? false
            var frame = CGRect.zero
            if let position: AXValue = value(window, kAXPositionAttribute), let size: AXValue = value(window, kAXSizeAttribute) {
                var point = CGPoint.zero, extent = CGSize.zero
                AXValueGetValue(position, .cgPoint, &point)
                AXValueGetValue(size, .cgSize, &extent)
                frame = CGRect(origin: point, size: extent)
            }
            result.append(AppWindow(id: "\(pid)-\(index)", pid: pid, title: title, minimized: minimized,
                                    frame: frame, element: window))
        }
        return result
    }

    /// Brings one window forward: unminimizes it, raises it, and makes its app the active one. The pointer stays.
    /// Brings one window to the front. A window on this Desktop comes forward through Accessibility, at once; one
    /// elsewhere (another Desktop, minimized) goes through Launch Services, which also switches Desktop.
    static func focus(_ window: AppWindow, onScreen: Bool = false) {
        if window.minimized { AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        if onScreen && !window.minimized && !app.isHidden {
            let element = AXUIElementCreateApplication(window.pid)
            AXUIElementSetMessagingTimeout(element, 0.3)
            if AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success { return }
        }
        bringForward(app)
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
    private static let getWindow: GetWindow? = {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }   // RTLD_DEFAULT
        return unsafeBitCast(pointer, to: GetWindow.self)
    }()

    static var canManage: Bool { getWindow != nil }

    /// The window server's id of an Accessibility window.
    static func id(of element: AXUIElement) -> CGWindowID? {
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
    static func frame(of element: AXUIElement) -> CGRect? {
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
    static func place(_ element: AXUIElement, pid: pid_t, _ frame: CGRect, size: Bool = true) -> CGRect? {
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
        // The same strip as Dock.swift's keepWindowsClear keeps.
        let gap = config.number("dockMargin") >= 0 ? config.number("dockMargin") : 4
        let icon = max(16, config.number("iconSize"))
        let inset = config.number("iconPadding") >= 0 ? config.number("iconPadding") : 5
        let reserve = gap * 2 + 2 + icon + inset * 2 + 8
        return ScreenArea.usable(visible: visible, screen: frame, position: config.position, reserve: reserve)
    }
}

/// What windows do, for Parking and Tiling: macOS tells other apps nothing about windows opening, closing, moving or
/// minimizing, except through an Accessibility observer on each app. Observers run only while something listens.
@MainActor
final class WindowEvents {
    static let shared = WindowEvents()

    enum Kind { case created, closed, focused, minimized, unminimized, moved, resized, activated, launched, quit, hidden, shown, space, screens }
    struct Event {
        let kind: Kind
        let pid: pid_t
        let window: CGWindowID?
        let element: AXUIElement?
    }

    private var listeners: [String: (Event) -> Void] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var windowIDs: [AXUIElement: CGWindowID] = [:]
    private var tokens: [NSObjectProtocol] = []

    private static let appNotifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                                           kAXApplicationHiddenNotification, kAXApplicationShownNotification]
    private static let windowNotifications = [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                                              kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]

    func listen(_ key: String, _ handler: @escaping (Event) -> Void) {
        let starting = listeners.isEmpty
        listeners[key] = handler
        if starting { start() }
    }

    func stopListening(_ key: String) {
        listeners[key] = nil
        if listeners.isEmpty { stop() }
    }

    private func send(_ kind: Kind, pid: pid_t, window: CGWindowID? = nil, element: AXUIElement? = nil) {
        let event = Event(kind: kind, pid: pid, window: window, element: element)
        for handler in listeners.values { handler(event) }
    }

    private func start() {
        guard Windows.trusted else { return }
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ body: @escaping @MainActor (NSRunningApplication?) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { body(app) }
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            observe(app)
            send(.launched, pid: app.processIdentifier)
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            forget(app.processIdentifier)
            send(.quit, pid: app.processIdentifier)
        }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            observe(app)   // an app that wasn't ready when it launched
            send(.activated, pid: app.processIdentifier)
        }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            guard let self else { return }
            // Accessibility lists only the windows of the Desktops showing: those of the one just shown are new to it.
            for pid in observers.keys { watchAll(pid) }
            send(.space, pid: 0)
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.screens, pid: 0) }
        })
    }

    private func stop() {
        for token in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        tokens = []
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers = [:]
        windowIDs = [:]
    }

    private func observe(_ app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, app.activationPolicy == .regular, pid != ProcessInfo.processInfo.processIdentifier,
              !app.isTerminated else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, _ in
            let name = notification as String
            MainActor.assumeIsolated { WindowEvents.shared.received(name, element) }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var added = 0
        for name in Self.appNotifications where AXObserverAddNotification(observer, element, name as CFString, nil) == .success { added += 1 }
        guard added > 0 else {
            // An app that has only just launched may not answer yet: try again a few times.
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(attempt + 1)) { [weak self] in
                    guard let self, !self.listeners.isEmpty else { return }
                    self.observe(app, attempt: attempt + 1)
                }
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        watchAll(pid)
    }

    private func watchAll(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        for window in Windows.value(app, kAXWindowsAttribute) as [AXUIElement]? ?? [] where windowIDs[window] == nil {
            watch(window, pid: pid)
        }
    }

    private func watch(_ window: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid], let id = Windows.id(of: window) else { return }
        windowIDs[window] = id
        Windows.remember(window, as: id)
        for name in Self.windowNotifications { AXObserverAddNotification(observer, window, name as CFString, nil) }
    }

    private func forget(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        windowIDs = windowIDs.filter { element, _ in
            var owner: pid_t = 0
            return AXUIElementGetPid(element, &owner) == .success && owner != pid
        }
        Windows.forget(pid: pid)
    }

    private func received(_ name: String, _ element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        switch name {
        case kAXWindowCreatedNotification:
            watch(element, pid: pid)
            send(.created, pid: pid, window: windowIDs[element], element: element)
        case kAXUIElementDestroyedNotification:
            // A closed window can't be asked its id any more: it's the one remembered for this element.
            guard let id = windowIDs.removeValue(forKey: element) else { return }
            Windows.forget(id)
            send(.closed, pid: pid, window: id)
        case kAXFocusedWindowChangedNotification:
            if windowIDs[element] == nil { watch(element, pid: pid) }
            send(.focused, pid: pid, window: windowIDs[element], element: element)
        case kAXWindowMiniaturizedNotification: send(.minimized, pid: pid, window: windowIDs[element], element: element)
        case kAXWindowDeminiaturizedNotification: send(.unminimized, pid: pid, window: windowIDs[element], element: element)
        case kAXMovedNotification: send(.moved, pid: pid, window: windowIDs[element], element: element)
        case kAXResizedNotification: send(.resized, pid: pid, window: windowIDs[element], element: element)
        case kAXApplicationHiddenNotification: send(.hidden, pid: pid)
        case kAXApplicationShownNotification: send(.shown, pid: pid)
        default: break
        }
    }
}
