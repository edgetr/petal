import AppKit
import ApplicationServices
import Carbon
import Observation

/// The browser's front tab: its real address, and closing it.
///
/// - Chromium browsers (Helium, Chrome, Arc, Brave, Edge, Vivaldi, Opera, Aside) and Safari answer AppleScript. Each asks
///   once for Automation permission; Petal only asks from a button (the welcome window or settings), never by
///   surprise, and until then reads the tab's title instead.
/// - Firefox and Zen don't script tabs: Petal reads the address field through Accessibility, and closes a tab with
///   ⌘W sent to that browser alone. The pointer never moves.
@MainActor @Observable
final class Browsers {
    enum Kind { case chromium, safari, gecko }

    nonisolated static let chromium: [String: String] = [
        "net.imput.helium": "Helium", "com.google.Chrome": "Chrome", "com.google.Chrome.beta": "Chrome Beta",
        "com.google.Chrome.dev": "Chrome Dev", "com.google.Chrome.canary": "Chrome Canary", "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave", "com.brave.Browser.beta": "Brave Beta", "com.microsoft.edgemac": "Edge",
        "com.vivaldi.Vivaldi": "Vivaldi", "com.operasoftware.Opera": "Opera", "org.chromium.Chromium": "Chromium",
        "at.studio.AsideBrowser": "Aside",
    ]
    nonisolated static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    nonisolated static let gecko: Set<String> = ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen"]

    nonisolated static func kind(_ bundleID: String) -> Kind? {
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

    /// One of a browser's windows as Accessibility sees it: the window server's number, title and frame (top left).
    struct Window: Sendable {
        let number: CGWindowID?
        let title: String
        let frame: CGRect
    }

    /// The front tab's address, or nil (not a browser, not allowed yet, or no answer). `window`: another of its
    /// windows (a sticky note's), whose tab is wanted instead; Firefox and Zen answer only for the front one.
    func frontURL(of app: NSRunningApplication, window: Window? = nil, done: @escaping (String?) -> Void) {
        guard let id = app.bundleIdentifier, let kind = Self.kind(id) else { return done(nil) }
        switch kind {
        case .gecko:
            // Accessibility, which waits on a busy browser: off the main thread. The front window, or a note's own
            // (found by id, or frame and title).
            let pid = app.processIdentifier
            queue.async {
                let url = Self.geckoAddress(pid: pid, window: window)
                DispatchQueue.main.async { done(url) }
            }
        case .chromium, .safari:
            let tab = kind == .safari ? "current tab" : "active tab"
            let source = window == nil ? "tell application id \"\(id)\" to return URL of \(tab) of front window"
                : Self.windowsScript(id, tab: tab)
            queue.async {
                // Never a surprise prompt: only a browser that already said yes is asked.
                let answer = Self.access(id) == .allowed ? Self.run(source) : nil
                let url = window.map { Self.url(in: answer ?? "", for: $0) } ?? answer
                DispatchQueue.main.async { done(url) }
            }
        }
    }

    /// `window`'s tab: its address and the browser's own id for it (Chromium's tab id, Safari's tab index), either nil
    /// when the browser doesn't say (not allowed yet, Firefox and Zen have no id). `done` runs on the main thread.
    func tab(of app: NSRunningApplication, window: Window, done: @escaping (_ url: String?, _ id: String?) -> Void) {
        guard let id = app.bundleIdentifier, let kind = Self.kind(id) else { return done(nil, nil) }
        guard kind != .gecko else { return frontURL(of: app, window: window) { done($0, nil) } }
        let source = Self.tabsScript(id, tab: kind == .safari ? "current tab" : "active tab",
                                     tabID: kind == .safari ? "index of current tab of w" : "id of active tab of w")
        queue.async {
            let answer = Self.access(id) == .allowed ? Self.run(source) : nil
            // The tab's id comes first, then its address (which may hold a tab character).
            let row = Self.url(in: answer ?? "", for: window).map { $0.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init) }
            let url = row.flatMap { $0.count == 2 && !$0[1].isEmpty ? $0[1] : nil }
            let tabID = row.flatMap { $0.first.flatMap { $0.isEmpty ? nil : $0 } }
            DispatchQueue.main.async { done(url, url == nil ? nil : tabID) }
        }
    }

    /// As windowsScript, with the browser's id for each window's tab (`tabID`, "" when it doesn't say) before the
    /// address.
    private static func tabsScript(_ id: String, tab: String, tabID: String) -> String {
        """
        set out to ""
        set sep to tab
        set nl to linefeed
        tell application id "\(id)"
        repeat with w in windows
        try
        set b to bounds of w
        set t to ""
        try
        set t to (\(tabID)) as text
        end try
        set out to out & (id of w) & sep & (name of w) & sep & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & sep & t & sep & (URL of \(tab) of w) & nl
        end try
        end repeat
        end tell
        return out
        """
    }

    /// Every window's id, name, bounds and tab address, one per line (the separators set outside the browser's
    /// own words, where Safari's `tab` is a tab, not the character).
    private static func windowsScript(_ id: String, tab: String) -> String {
        """
        set out to ""
        set sep to tab
        set nl to linefeed
        tell application id "\(id)"
        repeat with w in windows
        try
        set b to bounds of w
        set out to out & (id of w) & sep & (name of w) & sep & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & sep & (URL of \(tab) of w) & nl
        end try
        end repeat
        end tell
        return out
        """
    }

    /// The tab address of the one window that is `window`: by the window server's number (Safari's window id is
    /// it), else by the same frame and title. Two windows alike, or none: no address rather than a wrong one.
    nonisolated static func url(in listing: String, for window: Window) -> String? {
        struct Row { let id: UInt32?; let name: String; let frame: CGRect; let url: String }
        let rows: [Row] = listing.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4 else { return nil }
            let b = parts[2].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard b.count == 4 else { return nil }
            return Row(id: UInt32(parts[0]), name: parts[1], frame: CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1]),
                       url: parts[3...].joined(separator: "\t"))
        }
        if let number = window.number {
            let same = rows.filter { $0.id == number }
            if same.count == 1 { return same[0].url }
        }
        func near(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
        }
        let title = window.title
        let matches = rows.filter { row in
            near(row.frame, window.frame) && !row.name.isEmpty && (row.name == title || title.hasPrefix(row.name))
        }
        return matches.count == 1 ? matches[0].url : nil
    }

    // MARK: Tabs, for sticky notes

    /// The front window's active tab, for a sticky note to stick to (NoteTab says how each browser's tabs are told
    /// apart), or nil: not a browser, not allowed to ask it yet, or no answer. Called off the main thread.
    nonisolated static func activeTab(pid: pid_t, bundleID: String) -> NoteTab? {
        switch kind(bundleID) {
        case .chromium?:
            guard access(bundleID) == .allowed else { return nil }
            let fields = run("""
                set sep to tab
                tell application id "\(bundleID)"
                set w to front window
                set t to active tab of w
                set u to ""
                set n to ""
                try
                set u to URL of t
                end try
                try
                set n to title of t
                end try
                \(sharedScript)
                return ((id of t) as text) & sep & ((active tab index of w) as text) & sep & ((count of tabs of w) as text) & sep & (k as text) & sep & u & sep & n
                end tell
                """).map { Self.fields($0, 6) } ?? []
            guard fields.count >= 6, !fields[0].isEmpty else { return nil }
            return NoteTab(id: fields[0], index: Int(fields[1]), count: Int(fields[2]), shared: shared(fields[4], among: fields[3]),
                           url: fields[4], title: fields[5])
        case .safari?:
            guard access(bundleID) == .allowed, Windows.trusted else { return nil }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            let window: AXUIElement? = Windows.value(app, kAXFocusedWindowAttribute)
            let before = window.flatMap { strip(of: $0) }
            let fields = run("""
                set sep to tab
                tell application id "\(bundleID)"
                set w to front window
                set t to current tab of w
                set u to ""
                set n to ""
                try
                set u to URL of t
                end try
                try
                set n to name of t
                end try
                return ((index of t) as text) & sep & ((count of tabs of w) as text) & sep & u & sep & n
                end tell
                """).map { Self.fields($0, 4) } ?? []
            guard fields.count >= 4, let index = Int(fields[0]) else { return nil }
            let count = Int(fields[1])
            let after = window.flatMap { strip(of: $0) }
            let element = tabElement(before, after, index: index, count: count, pid: pid, window: window.flatMap { Windows.id(of: $0) })
            return NoteTab(element: element, index: index, count: count, url: fields[2], title: fields[3])
        case .gecko?:
            return geckoTab(pid: pid)
        case nil:
            return nil
        }
    }

    /// AppleScript that lists the address of every tab of every window of a Chromium browser into `k`, apart by
    /// character 30, for Petal to count the ones that are `u`'s (`shared`) with the same rule matching uses; empty
    /// when it can't (a list half done would say a tab is the only one when it isn't).
    nonisolated private static let sharedScript = """
        set k to ""
        if u is not "" then
        try
        repeat with x in windows
        repeat with v in (get URL of tabs of x)
        set s to contents of v
        if s is not missing value then set k to k & s & (character id 30)
        end repeat
        end repeat
        on error
        set k to ""
        end try
        end if
        """

    /// The tab one of the browser's windows (`window`, a sticky note's; `element`, that window's Accessibility element)
    /// shows now, or nil when Petal can't tell: the window found by the window server's number (Safari's window id is
    /// it), else by the same frame and title; none, or two alike, is no tab rather than another window's. Firefox and
    /// Zen through Accessibility. Off the main thread.
    nonisolated static func shownTab(pid: pid_t, bundleID: String, window: Window, element: AXUIElement?) -> NoteTab? {
        let kind = kind(bundleID)
        if kind == .gecko { return geckoTab(pid: pid, window: window.number) }
        guard let kind, access(bundleID) == .allowed else { return nil }
        let chromium = kind == .chromium
        // Safari's tab is its button in the window's tab strip, the same before and after the browser is asked.
        let before = chromium ? nil : element.flatMap { strip(of: $0) }
        // Fields apart by character 31, windows by character 30: titles may hold tabs and line breaks.
        guard let listing = run("""
            set out to ""
            set sep to character id 31
            set nl to character id 30
            tell application id "\(bundleID)"
            repeat with w in windows
            try
            set b to bounds of w
            set t to \(chromium ? "active tab" : "current tab") of w
            set u to ""
            set n to ""
            try
            set u to URL of t
            end try
            if u is missing value then set u to ""
            try
            set n to \(chromium ? "title" : "name") of t
            end try
            if n is missing value then set n to ""
            set out to out & (id of w) & sep & (name of w) & sep & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & sep & \(chromium ? "((id of t) as text)" : "\"\"") & sep & \(chromium ? "((active tab index of w) as text)" : "((index of t) as text)") & sep & ((count of tabs of w) as text) & sep & u & sep & n & nl
            end try
            end repeat
            end tell
            return out
            """) else { return nil }
        struct Row { let id: UInt32?; let name: String; let frame: CGRect; let tab: NoteTab }
        let rows: [Row] = listing.components(separatedBy: "\u{1E}").compactMap { line in
            let parts = line.components(separatedBy: "\u{1F}")
            guard parts.count >= 8 else { return nil }
            let b = parts[2].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard b.count == 4 else { return nil }
            let tab = NoteTab(id: parts[3].isEmpty ? nil : parts[3], index: Int(parts[4]), count: Int(parts[5]),
                              url: parts[6], title: parts[7...].joined(separator: "\u{1F}"))
            return Row(id: UInt32(parts[0]), name: parts[1], frame: CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1]), tab: tab)
        }
        if kind == .safari {
            guard let number = window.number else { return nil }
            let same = rows.filter { $0.id == number }
            guard same.count == 1 else { return nil }
            var tab = same[0].tab
            let after = element.flatMap { strip(of: $0) }
            tab.element = tabElement(before, after, index: tab.index, count: tab.count, pid: pid, window: number)
            return tab
        }
        let title = window.title
        let matches = rows.filter { row in
            NoteRules.sameFrame(row.frame, window.frame) && !row.name.isEmpty && (row.name == title || title.hasPrefix(row.name))
        }
        return matches.count == 1 ? matches[0].tab : nil
    }

    /// How many tabs of the browser have the address `url`, from `sharedScript`'s list: nil when it couldn't list them.
    nonisolated private static func shared(_ url: String, among listing: String) -> Int? {
        NoteRules.shared(url, among: listing.components(separatedBy: "\u{1E}"))
    }

    /// A script's answer split at tabs into `count` fields; the last (a title) keeps any tab of its own.
    nonisolated private static func fields(_ text: String, _ count: Int) -> [String] {
        let parts = text.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        guard parts.count > count else { return parts }
        return Array(parts.prefix(count - 1)) + [parts.dropFirst(count - 1).joined(separator: "\t")]
    }

    /// A window's tab strip as Accessibility shows it: each tab's own button, in order, and the one selected.
    struct Strip {
        let tabs: [AXUIElement]
        let selected: Int
        let titles: [String]
        var element: AXUIElement { tabs[selected] }
    }

    /// The tab strip in `window` (not in a page: a page's own tabs aren't the browser's), with exactly one tab
    /// selected; nil when there's none (Safari hides it for a window's only tab) or it takes too long.
    nonisolated static func strip(of window: AXUIElement, deadline: Date = Date().addingTimeInterval(0.4)) -> Strip? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var seen = 0
        while !queue.isEmpty, seen < 800, Date() < deadline {
            let (element, depth) = queue.removeFirst()
            seen += 1
            let role: String = Windows.value(element, kAXRoleAttribute) ?? ""
            if role == kAXTabGroupRole as String, let found = strip(in: element) { return found }
            guard depth < 14, role != kAXWebAreaRole else { continue }
            let children: [AXUIElement] = Windows.value(element, kAXChildrenAttribute) ?? []
            queue += children.map { ($0, depth + 1) }
        }
        return nil
    }

    /// A tab group's tabs (its radio buttons), when exactly one is selected.
    nonisolated static func strip(in group: AXUIElement) -> Strip? {
        let children: [AXUIElement] = Windows.value(group, kAXChildrenAttribute) ?? []
        let tabs = children.filter { (Windows.value($0, kAXRoleAttribute) as String?) == kAXRadioButtonRole as String }
        let selected = tabs.indices.filter { i in
            let value: Any? = Windows.value(tabs[i], kAXValueAttribute)
            return (value as? NSNumber)?.boolValue == true
        }
        guard selected.count == 1 else { return nil }
        return Strip(tabs: tabs, selected: selected[0], titles: tabs.map { (Windows.value($0, kAXTitleAttribute) as String?) ?? "" })
    }

    /// The selected tab's element number (`TabElements`) when the strip read before and after the browser was asked
    /// shows the same tab selected, in the place and among as many tabs as the browser said; else nil (no strip, or
    /// another tab came forward meanwhile): a tab Petal can't tell apart, never a guess. A strip that agrees with the
    /// browser also lets go of the buttons gone from it.
    nonisolated private static func tabElement(_ before: Strip?, _ after: Strip?, index: Int?, count: Int?, pid: pid_t,
                                               window: CGWindowID?) -> Int? {
        guard let before, let after, CFEqual(before.element, after.element), before.tabs.count == after.tabs.count,
              index == after.selected + 1, count == after.tabs.count else { return nil }
        TabElements.shared.prune(after, pid: pid, window: window)
        return TabElements.shared.number(for: after.element, pid: pid, window: window)
    }

    /// What came of showing a note's tab: shown, not there (its tab closed while its window stayed open, or a Safari,
    /// Firefox or Zen tab went to another window), or unsure (no answer, not allowed, cancelled, or a tab Petal can't
    /// tell apart).
    enum TabShown: Sendable { case shown, missing, unsure }

    /// Shows a note's tab in its window (bringing the note back from its app's icon): a Chromium browser's by its id,
    /// in whichever window it is now, that window coming to the browser's front (`bounds`: that window's, top-left
    /// origin as Accessibility's, so Petal raises that one); Safari's, Firefox's and Zen's by pressing its own button
    /// in the tab strip (no bounds: the button is in its window). Off the main thread. `still`: asked right before
    /// the browser is told, so a bringing cancelled meanwhile switches no tab.
    nonisolated static func select(_ tab: NoteTab, bundleID: String, still: () -> Bool) -> (shown: TabShown, bounds: CGRect?) {
        switch kind(bundleID) {
        case .chromium?:
            guard let id = tab.id, access(bundleID) == .allowed, still() else { return (.unsure, nil) }
            guard let answer = run("""
                set sep to tab
                tell application id "\(bundleID)"
                repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                set i to i + 1
                if ((id of t) as text) is \(quoted(id)) then
                set active tab index of w to i
                set index of w to 1
                set b to bounds of w
                return "ok" & sep & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b)
                end if
                end repeat
                end repeat
                end tell
                return "none"
                """) else { return (.unsure, nil) }
            if answer == "none" { return (.missing, nil) }
            let parts = answer.components(separatedBy: "\t")
            guard parts.first == "ok" else { return (.unsure, nil) }
            return (.shown, parts.count > 1 ? bounds(parts[1]) : nil)
        case .safari?, .gecko?:
            guard let number = tab.element, Windows.trusted else { return (.unsure, nil) }
            if TabElements.shared.gone(number) { return (.missing, nil) }
            guard let element = TabElements.shared.element(number) else { return (.unsure, nil) }
            AXUIElementSetMessagingTimeout(element, 0.3)
            var role: CFTypeRef?
            let alive = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if alive == .invalidUIElement { return (.missing, nil) }
            guard alive == .success, still() else { return (.unsure, nil) }
            return (AXUIElementPerformAction(element, kAXPressAction as CFString) == .success ? .shown : .unsure, nil)
        case nil:
            return (.unsure, nil)
        }
    }

    /// AppleScript's window bounds ("left,top,right,bottom") as a frame, top-left origin; nil when they don't read.
    nonisolated private static func bounds(_ text: String) -> CGRect? {
        let b = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return b.count == 4 ? CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1]) : nil
    }
    /// Where a Chromium browser's tab is, by its id: its window's bounds (top-left origin, as Accessibility's), or
    /// `nil` bounds when no tab has that id. nil: no answer (not allowed, or the browser didn't say). Off the main thread.
    nonisolated static func tabWindow(id: String, bundleID: String) -> (found: Bool, bounds: CGRect?)? {
        guard kind(bundleID) == .chromium, access(bundleID) == .allowed else { return nil }
        guard let answer = run("""
            set sep to tab
            tell application id "\(bundleID)"
            repeat with w in windows
            repeat with t in tabs of w
            if ((id of t) as text) is \(quoted(id)) then
            set b to bounds of w
            return "found" & sep & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b)
            end if
            end repeat
            end repeat
            end tell
            return "none"
            """) else { return nil }
        if answer == "none" { return (false, nil) }
        let parts = answer.components(separatedBy: "\t")
        guard parts.first == "found" else { return nil }
        return (true, parts.count > 1 ? bounds(parts[1]) : nil)
    }

    /// Text as an AppleScript string.
    nonisolated private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Firefox's and Zen's front window (or `wanted`, one of its windows by the window server's number, none if it
    /// isn't there): the selected tab in its tab strip (its button, place, how many, its title) and the address
    /// field, through Accessibility, both read again at the end so they're the same tab's. Best effort: what each
    /// version shows differs. As Safari's, a Firefox or Zen tab is found only by its button, never by its address.
    nonisolated static func geckoTab(pid: pid_t, window wanted: CGWindowID? = nil) -> NoteTab? {
        guard Windows.trusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let all: [AXUIElement] = Windows.value(app, kAXWindowsAttribute) ?? []
        let found: AXUIElement?
        if let wanted {
            found = all.first { Windows.id(of: $0) == wanted }
        } else {
            found = Windows.value(app, kAXFocusedWindowAttribute)
        }
        guard let window = found else { return nil }
        let number = Windows.id(of: window)
        let windowTitle: String = Windows.value(window, kAXTitleAttribute) ?? ""
        var field: AXUIElement?
        var address: String?
        var group: AXUIElement?
        var strip: Strip?
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var seen = 0
        let deadline = Date().addingTimeInterval(0.4)
        while !queue.isEmpty, seen < 800, Date() < deadline, address == nil || strip == nil {
            let (element, depth) = queue.removeFirst()
            seen += 1
            let role: String = Windows.value(element, kAXRoleAttribute) ?? ""
            if address == nil, role == kAXTextFieldRole as String || role == kAXComboBoxRole as String {
                let identifier: String = Windows.value(element, "AXIdentifier") ?? ""
                let description: String = Windows.value(element, kAXDescriptionAttribute) ?? ""
                let value: String = Windows.value(element, kAXValueAttribute) ?? ""
                if !value.isEmpty, identifier.contains("urlbar") || description.localizedCaseInsensitiveContains("address")
                    || description.localizedCaseInsensitiveContains("search or enter") || Sites.address(value) != nil {
                    address = value
                    field = element
                }
            }
            if strip == nil, role == kAXTabGroupRole as String, let tabs = Self.strip(in: element) {
                strip = tabs
                group = element
            }
            guard depth < 14, role != kAXWebAreaRole else { continue }   // a page's own fields and tabs aren't the browser's
            let children: [AXUIElement] = Windows.value(element, kAXChildrenAttribute) ?? []
            queue += children.map { ($0, depth + 1) }
        }
        guard address != nil || strip != nil else { return nil }
        // The same tab still selected, and the address field still saying the same: else another tab came forward
        // while the window was read, and its button isn't this address's.
        var element: Int?
        if let strip, let group, let again = Self.strip(in: group), CFEqual(strip.element, again.element),
           strip.tabs.count == again.tabs.count, field.map({ (Windows.value($0, kAXValueAttribute) as String?) == address }) != false {
            TabElements.shared.prune(again, pid: pid, window: number)
            element = TabElements.shared.number(for: again.element, pid: pid, window: number)
        }
        let title = strip.map { $0.titles[$0.selected] } ?? ""
        return NoteTab(element: element, index: strip.map { $0.selected + 1 }, count: strip?.tabs.count,
                       url: address ?? "", title: title.isEmpty ? windowTitle : title)
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

    /// The address field's text in the front window (or `window`, one of its windows: by the window server's
    /// number, else the one with that frame and title; none, or two alike, is no address), found through
    /// Accessibility (Firefox shows it without "https://"; that's fine for the site).
    nonisolated static func geckoAddress(pid: pid_t, window wanted: Window? = nil) -> String? {
        guard Windows.trusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        // Gecko builds its accessibility tree once something asks for it.
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let found: AXUIElement?
        if let wanted {
            let all: [AXUIElement] = Windows.value(app, kAXWindowsAttribute) ?? []
            if let number = wanted.number, let match = all.first(where: { Windows.id(of: $0) == number }) {
                found = match
            } else {
                let alike = all.filter { w in
                    guard let frame = Windows.frame(of: w), let title: String = Windows.value(w, kAXTitleAttribute) else { return false }
                    return title == wanted.title && abs(frame.minX - wanted.frame.minX) <= 2 && abs(frame.minY - wanted.frame.minY) <= 2
                        && abs(frame.width - wanted.frame.width) <= 2 && abs(frame.height - wanted.frame.height) <= 2
                }
                found = alike.count == 1 ? alike[0] : nil
            }
        } else {
            found = Windows.value(app, kAXFocusedWindowAttribute)
        }
        guard let window = found else { return nil }
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

/// Safari's, Firefox's and Zen's tabs have no id: each is known by its own button in its window's tab strip, an
/// Accessibility element that is the same (CFEqual) for as long as the tab lives, wherever it moves in the strip and
/// whatever page it shows. Petal keeps the buttons of the tabs it saw selected here, in memory only, behind a number
/// (`NoteTab.element`) the pure rules compare; nothing of it is ever saved. A button gone from its window's strip
/// (its tab closed, or dragged to another window) is let go and its number never comes back, so a tab that later
/// gets an element alike is another tab. Used from any thread.
final class TabElements: @unchecked Sendable {
    static let shared = TabElements()

    private struct Entry {
        let pid: pid_t
        var window: CGWindowID?
        let element: AXUIElement
        var used: Int
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private var byHash: [CFHashCode: [Int]] = [:]
    private var released: Set<Int> = []
    private var next = 1
    private var clock = 0

    /// The number for a tab's button (the one it had if seen before), in `window` of `pid`.
    func number(for element: AXUIElement, pid: pid_t, window: CGWindowID?) -> Int {
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        let hash = CFHash(element)
        if let found = byHash[hash]?.first(where: { entries[$0]?.pid == pid && entries[$0].map { CFEqual($0.element, element) } == true }) {
            entries[found]?.used = clock
            if let window { entries[found]?.window = window }
            return found
        }
        if entries.count >= 1024 { evict() }
        let number = next
        next += 1
        entries[number] = Entry(pid: pid, window: window, element: element, used: clock)
        byHash[hash, default: []].append(number)
        return number
    }

    /// The buttons kept for `window` that its strip no longer has are let go: their tabs closed or went elsewhere.
    func prune(_ strip: Browsers.Strip, pid: pid_t, window: CGWindowID?) {
        guard let window else { return }
        lock.lock()
        defer { lock.unlock() }
        for (number, entry) in entries where entry.pid == pid && entry.window == window {
            guard !strip.tabs.contains(where: { CFEqual($0, entry.element) }) else { continue }
            remove(number)
            released.insert(number)
        }
        if released.count > 4096 { released.removeAll() }
    }

    /// The tab's button, while Petal keeps it.
    func element(_ number: Int) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return entries[number]?.element
    }

    /// Let go because its tab left its window's strip.
    func gone(_ number: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return released.contains(number)
    }

    /// Room for more: the buttons of browsers that quit go first, then those not seen for longest.
    private func evict() {
        for (number, entry) in entries where kill(entry.pid, 0) != 0 && errno == ESRCH { remove(number) }
        guard entries.count >= 1024 else { return }
        for (number, _) in entries.sorted(by: { $0.value.used < $1.value.used }).prefix(256) { remove(number) }
    }

    private func remove(_ number: Int) {
        guard let entry = entries.removeValue(forKey: number) else { return }
        let hash = CFHash(entry.element)
        byHash[hash]?.removeAll { $0 == number }
        if byHash[hash]?.isEmpty == true { byHash[hash] = nil }
    }
}
