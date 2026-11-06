import AppKit
import ApplicationServices
import Carbon
import Observation

/// The browser's front tab: its real address, and closing it.
///
/// - Chromium browsers (Helium, Chrome, Arc, Brave, Edge, Vivaldi, Opera) and Safari answer AppleScript. Each asks
///   once for Automation permission; Petal only asks from a button (the welcome window or settings), never by
///   surprise, and until then reads the tab's title instead.
/// - Firefox and Zen don't script tabs: Petal reads the address field through Accessibility, and closes a tab with
///   ⌘W sent to that browser alone. The pointer never moves.
@MainActor @Observable
final class Browsers {
    enum Kind { case chromium, safari, gecko }

    static let chromium: [String: String] = [
        "net.imput.helium": "Helium", "com.google.Chrome": "Chrome", "com.google.Chrome.beta": "Chrome Beta",
        "com.google.Chrome.dev": "Chrome Dev", "com.google.Chrome.canary": "Chrome Canary", "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave", "com.brave.Browser.beta": "Brave Beta", "com.microsoft.edgemac": "Edge",
        "com.vivaldi.Vivaldi": "Vivaldi", "com.operasoftware.Opera": "Opera", "org.chromium.Chromium": "Chromium",
    ]
    static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    static let gecko: Set<String> = ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen"]

    static func kind(_ bundleID: String) -> Kind? {
        if chromium[bundleID] != nil { return .chromium }
        if safari.contains(bundleID) { return .safari }
        if gecko.contains(bundleID) { return .gecko }
        return nil
    }

    /// One AppleScript at a time, off the main thread: a busy browser can take a while to answer.
    @ObservationIgnored private let queue = DispatchQueue(label: "tech.edgetr.petal.browsers")
    /// Each running browser's answer, as last asked (for the settings and welcome windows).
    private(set) var states: [String: Access] = [:]

    // MARK: Permission

    enum Access { case allowed, notAsked, denied, notRunning }

    /// Whether Petal may script this browser, without asking (or, with `ask`, macOS asks the person once). Only a
    /// running browser can say: asking about one that isn't running waits for it, so that's never done. Called off
    /// the main thread: a busy browser can take a while.
    nonisolated static func access(_ bundleID: String, ask: Bool = false) -> Access {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let desc = NSAppleEventDescriptor(processIdentifier: running.processIdentifier).aeDesc else { return .notRunning }
        switch AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask) {
        case noErr: return .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notRunning
        }
    }

    /// The scriptable browsers on this Mac, by name.
    static func installed() -> [(id: String, name: String)] {
        let ids = Array(chromium.keys) + Array(safari)
        return ids.filter { Apps.url($0) != nil }.map { ($0, Apps.name($0)) }.sorted { $0.1 < $1.1 }
    }

    /// Asks each running browser again, without prompting.
    func refresh() {
        let ids = Self.installed().map(\.id)
        queue.async {
            var found: [String: Access] = [:]
            for id in ids { found[id] = Self.access(id) }
            DispatchQueue.main.async { MainActor.assumeIsolated { if self.states != found { self.states = found } } }
        }
    }

    /// The button: asks each scriptable browser on this Mac once (macOS shows its own prompt). A browser has to be
    /// running to be asked, so one that isn't is opened in the background first.
    func askAll(done: @escaping () -> Void) {
        let list = Self.installed().map(\.id)
        Task {
            for id in list where states[id] != .allowed && states[id] != .denied {
                if NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty, let url = Apps.url(id) {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = false
                    configuration.hides = true
                    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                    try? await Task.sleep(for: .seconds(1.5))
                }
                let answer = await Task.detached { Self.access(id, ask: true) }.value
                states[id] = answer
            }
            refresh()
            done()
        }
    }

    /// Some browser has been allowed, and none that's running is still waiting to be asked or was refused.
    var allAllowed: Bool {
        states.values.contains(.allowed) && !states.values.contains(.notAsked) && !states.values.contains(.denied)
    }

    /// Browsers that said no: only System Settings can change that now.
    var refused: [String] { states.filter { $0.value == .denied }.keys.map(Apps.name).sorted() }

    // MARK: Reading

    /// The front tab's address, or nil (not a browser, not allowed yet, or no answer).
    func frontURL(of app: NSRunningApplication, done: @escaping (String?) -> Void) {
        guard let id = app.bundleIdentifier, let kind = Self.kind(id) else { return done(nil) }
        switch kind {
        case .gecko:
            done(Self.geckoAddress(pid: app.processIdentifier))
        case .chromium, .safari:
            let source = "tell application id \"\(id)\" to return URL of \(kind == .safari ? "current tab" : "active tab") of front window"
            queue.async {
                // Never a surprise prompt: only a browser that already said yes is asked.
                let url = Self.access(id) == .allowed ? Self.run(source) : nil
                DispatchQueue.main.async { done(url) }
            }
        }
    }

    // MARK: Closing

    /// Closes the browser's front tab.
    func closeTab(of app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, let kind = Self.kind(id) else { return }
        switch kind {
        case .gecko:
            Self.commandW(app)
        case .chromium, .safari:
            let source = "tell application id \"\(id)\" to close \(kind == .safari ? "current tab" : "active tab") of front window"
            queue.async {
                if Self.access(id) == .allowed { _ = Self.run(source) } else { DispatchQueue.main.async { Self.commandW(app) } }
            }
        }
    }

    /// ⌘W to that app only, as its own File menu would close a tab.
    static func commandW(_ app: NSRunningApplication) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0x0D, keyDown: down)   // W
            event?.flags = .maskCommand
            event?.postToPid(app.processIdentifier)
        }
    }

    nonisolated private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil, let text = result?.stringValue, !text.isEmpty else { return nil }
        return text
    }

    // MARK: Firefox and Zen

    /// The address field's text in the front window, found through Accessibility (Firefox shows it without
    /// "https://"; that's fine for the site).
    static func geckoAddress(pid: pid_t) -> String? {
        guard Windows.trusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        // Gecko builds its accessibility tree once something asks for it.
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        guard let window: AXUIElement = Windows.value(app, kAXFocusedWindowAttribute) else { return nil }
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var seen = 0
        let deadline = Date().addingTimeInterval(0.4)   // never long: the dock waits on this
        while !queue.isEmpty, seen < 600, Date() < deadline {
            let (element, depth) = queue.removeFirst()
            seen += 1
            let role: String = Windows.value(element, kAXRoleAttribute) ?? ""
            if role == kAXTextFieldRole as String || role == kAXComboBoxRole as String {
                let identifier: String = Windows.value(element, "AXIdentifier") ?? ""
                let description: String = Windows.value(element, kAXDescriptionAttribute) ?? ""
                let value: String = Windows.value(element, kAXValueAttribute) ?? ""
                let looksLikeBar = identifier.contains("urlbar") || description.localizedCaseInsensitiveContains("address")
                    || description.localizedCaseInsensitiveContains("search or enter")
                if looksLikeBar, !value.isEmpty { return value }
                if Sites.address(value) != nil || value.hasPrefix("about:") { return value }
            }
            guard depth < 14, role != kAXWebAreaRole else { continue }   // a page's own fields aren't the address bar
            let children: [AXUIElement] = Windows.value(element, kAXChildrenAttribute) ?? []
            queue += children.map { ($0, depth + 1) }
        }
        return nil
    }
}

private let kAXWebAreaRole = "AXWebArea"
