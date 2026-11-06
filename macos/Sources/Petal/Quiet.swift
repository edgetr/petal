import AppKit
import ApplicationServices
import Observation

/// Do Not Disturb while a mode holds notifications, so macOS's banners stay away; off again when it doesn't, on quit,
/// and after a crash (the next launch and the Dock guard turn it off). Three ways, the first that works:
/// 1. macOS's own Do Not Disturb assertion (the private DoNotDisturb framework, as Control Center uses it), looked up
///    at run time. macOS 26 and 27 refuse it to apps without Apple's private entitlement, so this is a check that
///    costs nothing and is ready if that ever changes.
/// 2. A Shortcut, "Petal Do Not Disturb", that sets the Do Not Disturb Focus on or off. Petal makes it and macOS adds
///    it with one click.
/// 3. Closing macOS's banners through Accessibility as they appear.
/// Petal never turns off a Do Not Disturb the person turned on themselves.
@MainActor @Observable
final class Quiet {
    enum Way: String { case shortcut, closer }

    nonisolated static let shortcutName = "Petal Do Not Disturb"
    /// While Petal has Do Not Disturb on: which way turned it on, so whoever comes next can turn it off.
    nonisolated static let marker = Config.folder.appending(path: "quiet.json")

    private(set) var shortcutInstalled = false
    private(set) var addingShortcut = false
    @ObservationIgnored private(set) var on = false
    @ObservationIgnored private var closer: Timer?
    @ObservationIgnored private var pendingOff: DispatchWorkItem?
    @ObservationIgnored private var seen: [String: Date] = [:]

    /// The way Petal keeps banners away now, or nil when none can.
    var way: Way? {
        if shortcutInstalled { return .shortcut }
        return Windows.trusted ? .closer : nil
    }

    func refresh() {
        Task {
            let installed = await Task.detached { Self.shortcutIsInstalled() }.value
            shortcutInstalled = installed
        }
    }

    // MARK: On and off

    /// On at once; off a moment later, so flicking between Desktops doesn't flick Do Not Disturb. `wait` (quitting)
    /// turns it off now and waits until it's done.
    func set(_ wanted: Bool, wait: Bool = false) {
        if wanted {
            pendingOff?.cancel()
            pendingOff = nil
            guard !on, let way else { return }
            on = true
            // Someone's own Do Not Disturb (or another Focus) is theirs: banners are away already, and it stays as it is.
            if way != .closer && Self.focusIsOn() && !FileManager.default.fileExists(atPath: Self.marker.path) { return }
            Config.writeObject(["way": way.rawValue], to: Self.marker)
            switch way {
            case .shortcut: Self.runShortcut(true, wait: false)
            case .closer: startCloser()
            }
            return
        }
        let marked = FileManager.default.fileExists(atPath: Self.marker.path)
        if on {
            on = false
            closer?.invalidate()
            closer = nil
        }
        if wait {
            pendingOff?.cancel()
            pendingOff = nil
            Self.turnOff(wait: true)
            return
        }
        guard marked, pendingOff == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingOff = nil
            DispatchQueue.global(qos: .utility).async { Self.turnOff(wait: true) }
        }
        pendingOff = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Turns off what Petal turned on, by the way it did.
    nonisolated static func turnOff(wait: Bool) {
        guard let saved = Config.parse(marker), let way = (saved["way"] as? String).flatMap(Way.init(rawValue:)) else {
            try? FileManager.default.removeItem(at: marker)
            return
        }
        switch way {
        case .shortcut: runShortcut(false, wait: wait)
        case .closer: break
        }
        try? FileManager.default.removeItem(at: marker)
    }

    /// At launch: Petal didn't get to turn it off last time (a crash, Force Quit).
    static func recover() {
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        DispatchQueue.global(qos: .utility).async { turnOff(wait: true) }
    }

    /// Whether Do Not Disturb (or any Focus) is on now, from macOS's own record of it. Needs Full Disk Access, which
    /// holding needs anyway.
    nonisolated static func focusIsOn() -> Bool {
        let file = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/DoNotDisturb/DB/Assertions.json")
        guard let root = Config.parse(file), let data = root["data"] as? [[String: Any]] else { return false }
        return data.contains { !($0["storeAssertionRecords"] as? [Any] ?? []).isEmpty }
    }

    // MARK: The Shortcut

    nonisolated static func shortcutIsInstalled() -> Bool {
        run("/usr/bin/shortcuts", ["list"], wait: true).split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == shortcutName }
    }

    nonisolated static func runShortcut(_ on: Bool, wait: Bool) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Petal")
        let input = folder.appending(path: on ? "quiet-on.txt" : "quiet-off.txt")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data((on ? "on" : "off").utf8).write(to: input)
        run("/usr/bin/shortcuts", ["run", shortcutName, "--input-path", input.path], wait: wait)
    }

    /// Makes the Shortcut, has macOS sign it, and opens it: Shortcuts asks once, Add Shortcut.
    func addShortcut() {
        addingShortcut = true
        Task {
            let opened = await Task.detached { () -> Bool in
                let folder = FileManager.default.temporaryDirectory.appending(path: "petal-shortcut-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let plain = folder.appending(path: "plain.wflow"), signed = folder.appending(path: "\(Self.shortcutName).shortcut")
                guard let data = try? PropertyListSerialization.data(fromPropertyList: Self.workflow(), format: .binary, options: 0),
                      (try? data.write(to: plain)) != nil else { return false }
                Self.run("/usr/bin/shortcuts", ["sign", "--mode", "anyone", "--input", plain.path, "--output", signed.path], wait: true)
                guard FileManager.default.fileExists(atPath: signed.path) else { return false }
                return NSWorkspace.shared.open(signed)
            }.value
            addingShortcut = false
            if !opened { NSSound.beep() }
            // Shortcuts adds it once the person says so; look a few times.
            for _ in 0..<20 where !shortcutInstalled {
                try? await Task.sleep(for: .seconds(3))
                shortcutInstalled = await Task.detached { Self.shortcutIsInstalled() }.value
            }
        }
    }

    /// "If Shortcut Input is on: turn Do Not Disturb on until turned off. Otherwise: turn it off."
    nonisolated static func workflow() -> [String: Any] {
        let group = UUID().uuidString
        let focus: [String: Any] = ["Identifier": "com.apple.donotdisturb.mode.default", "DisplayString": "Do Not Disturb"]
        func setFocus(_ on: Bool) -> [String: Any] {
            var parameters: [String: Any] = ["FocusModes": focus, "Enabled": on ? 1 : 0, "Operation": "Turn"]
            if on { parameters["AssertionType"] = "Turned Off" }
            return ["WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set", "WFWorkflowActionParameters": parameters]
        }
        func branch(_ mode: Int, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
             "WFWorkflowActionParameters": ["GroupingIdentifier": group, "WFControlFlowMode": mode].merging(extra) { a, _ in a }]
        }
        let input: [String: Any] = ["Type": "Variable",
                                    "Variable": ["Value": ["Type": "ExtensionInput"], "WFSerializationType": "WFTextTokenAttachment"]]
        return [
            "WFWorkflowClientVersion": "2700.0.4", "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowImportQuestions": [Any](), "WFWorkflowTypes": [Any](), "WFQuickActionSurfaces": [Any](),
            "WFWorkflowInputContentItemClasses": ["WFStringContentItem", "WFGenericFileContentItem"],
            "WFWorkflowHasShortcutInputVariables": true, "WFWorkflowOutputContentItemClasses": [Any](),
            "WFWorkflowActions": [
                branch(0, ["WFCondition": 4, "WFConditionalActionString": "on", "WFInput": input]),
                setFocus(true),
                branch(1),
                setFocus(false),
                branch(2),
            ],
        ]
    }

    // MARK: Closing banners

    /// Every half second while holding: macOS's banners (Notification Center's own windows) are closed through
    /// Accessibility once they've been up a moment, long enough for Petal to have read them. The open Notification
    /// Center is left alone.
    private func startCloser() {
        closer?.invalidate()
        closer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeBanners() }
        }
    }

    private func closeBanners() {
        guard Windows.trusted, let center = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return }
        let app = AXUIElementCreateApplication(center.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let screenHeight = NSScreen.main?.frame.height ?? 900
        var now: Set<String> = []
        for window: AXUIElement in Windows.value(app, kAXWindowsAttribute) ?? [] {
            var size = CGSize.zero
            if let value: AXValue = Windows.value(window, kAXSizeAttribute) { AXValueGetValue(value, .cgSize, &size) }
            guard size.height < screenHeight * 0.6 else { continue }   // the open Notification Center, not banners
            for banner in Self.banners(in: window) {
                let key = String(describing: banner)
                now.insert(key)
                let first = seen[key] ?? Date()
                seen[key] = first
                guard Date().timeIntervalSince(first) > 0.6 else { continue }
                Self.close(banner)
            }
        }
        seen = seen.filter { now.contains($0.key) }
    }

    private static func banners(in window: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        while !queue.isEmpty, found.count < 10 {
            let (element, depth) = queue.removeFirst()
            let subrole: String = Windows.value(element, kAXSubroleAttribute) ?? ""
            if subrole.hasPrefix("AXNotificationCenterBanner") || subrole.hasPrefix("AXNotificationCenterAlert") {
                found.append(element)
                continue
            }
            guard depth < 6 else { continue }
            queue += (Windows.value(element, kAXChildrenAttribute) as [AXUIElement]? ?? []).map { ($0, depth + 1) }
        }
        return found
    }

    /// A banner's own Close action (named "Close" in its action list), else its close button.
    private static func close(_ banner: AXUIElement) {
        var names: CFArray?
        if AXUIElementCopyActionNames(banner, &names) == .success, let list = names as? [String],
           let action = list.first(where: { $0.hasPrefix("Name:Close") || $0 == "AXClose" }) {
            AXUIElementPerformAction(banner, action as CFString)
            return
        }
        if let button: AXUIElement = Windows.value(banner, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    // MARK: Running

    @discardableResult
    nonisolated static func run(_ path: String, _ arguments: [String], wait: Bool) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        guard wait else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
