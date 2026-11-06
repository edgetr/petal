import AppKit
import Observation

/// A focus mode from modes.json. On macOS its apps are bundle identifiers, and its icon is an SF Symbol name
/// (a Nerd Font glyph from an Omarchy modes.json still shows, as text).
struct Mode: Equatable, Identifiable {
    let id: String
    var name: String
    var icon: String
    var color: NSColor
    var about: String
    var apps: [String]
    var sites: [String]
    /// A distracting mode's wait to get in, in seconds (30 when 0); other modes ignore it.
    var focusDelay: Double
    var allow: [String]
    /// A Shortcut (Shortcuts app) to run when the Desktop in front enters this mode.
    var shortcut: String = ""
    /// A mode that pulls you away from work (Social, Gaming): getting in takes its wait, and elsewhere its apps and
    /// sites are blocked. nil until the AI has decided (see `isDistracting`).
    var distracting: Bool? = nil
    /// Notifications from apps outside the mode wait on their own mode.
    var hold = false

    var hex: String { color.hex }

    /// My Dock (macOS's Dock, imported): everything the person uses, the default rather than a focus mode, so it
    /// has no focus cards and nothing in it is sorted.
    var isEverything: Bool { id == "dock" }

    /// Distracting, or, before the AI has decided, a mode named like one.
    var isDistracting: Bool {
        distracting ?? ["social", "gaming", "games", "entertainment"].contains { $0 == id.lowercased() || $0 == name.lowercased() }
    }

    /// The wait to get into a distracting mode.
    var wait: Double { focusDelay > 0 ? focusDelay : 30 }
}

/// Petal's files in ~/.config/petal, the same folder and formats as on Omarchy:
/// - modes.json: the modes, and which mode each Desktop is in ("workspaces": {"1": "building"}).
/// - settings.json: the settings both platforms share, with Omarchy's defaults (Dock.qml's JsonAdapter and
///   SETTINGS_SCHEMA in petal-mcp.py list the same keys; so does `defaults` here).
/// - dock.json: what Omarchy keeps in its own shell config (where the dock sits, auto-hide), and the Mac's own
///   choices: which dock (Petal or macOS's), opening at login, whether the first-run welcome was seen.
/// Each is read again within a second of changing on disk, whoever changed it (the settings window, Claude, an editor).
@MainActor @Observable
final class Config {
    nonisolated static let folder = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".config/petal")
    @ObservationIgnored let modesFile = folder.appending(path: "modes.json")
    @ObservationIgnored let settingsFile = folder.appending(path: "settings.json")
    @ObservationIgnored let dockFile = folder.appending(path: "dock.json")
    @ObservationIgnored let instructionsFile = folder.appending(path: "instructions.md")

    static let defaults: [String: Any] = [
        "dockColor": "", "dockOpacity": 0.45, "dockBorderColor": "#ffffff", "dockBorderOpacity": 0.28, "dockRadius": -1,
        "dockSheen": true, "dockMargin": -1, "iconSize": 36, "iconPadding": -1, "idleOpacity": 0.7, "separators": true,
        "hoverLiftAmount": 0.05, "glowStrength": 1.0, "accentColor": "", "popupColor": "", "popupOpacity": 0.74,
        "font": "Adwaita Sans", "tooltips": true, "hoverLift": true, "appGlow": true, "thisWorkspaceOnly": true,
        "previews": true, "minimized": true, "badges": true, "bounce": true, "progress": true, "quickActions": true,
        "recentFiles": true, "dropToOpen": true, "nowPlaying": true, "stacks": true,
        "stackFolders": ["~/Downloads", "~/Pictures/Screenshots"], "trash": true, "modes": true, "countdown": true,
        "focusGuard": true, "blockDistractions": true, "peeks": true, "holdNotifications": true, "urgentNotifications": true,
        "modeWindows": false, "tiling": false, "tilingGaps": 8, "tilingFloat": [String](), "ai": true, "claudeUsage": true, "autoUpdate": true,
        "claudePath": "", "chatModel": "sonnet", "chatEffort": "medium", "claudeAccess": "auto",
        "aiProviders": ["claude"], "otherAgents": true, "aiMemory": true, "aiLearns": true, "dailySummary": "", "aiAllowed": [Any](), "replyDrafts": true, "chatWhileWorking": "steer", "selectionAsk": true, "routines": true,
        "aiNeverLook": ["com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords", "com.apple.keychainaccess"],
        "shortcuts": true, "schedule": [Any](), "activityLog": true, "suggestModes": true, "summary": true,
        "magnification": false, "magnificationAmount": 0.5, "menuBarIcon": true, "chatProvider": "claude", "codexModel": "", "codexEffort": "medium", "codexPath": "",
        "claudeAuth": "subscription", "codexAuth": "subscription",
    ]

    private(set) var modes: [Mode] = []
    private(set) var defaultMode = ""
    private(set) var workspaces: [String: String] = [:]
    private(set) var settings: [String: Any] = [:]
    private(set) var dock: [String: Any] = [:]

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var stamps: [Date?] = []

    init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: modesFile.path),
           let seed = Bundle.main.url(forResource: "modes", withExtension: "json") {
            try? FileManager.default.copyItem(at: seed, to: modesFile)
        }
        reload()
        watch()
    }

    // MARK: Settings

    func bool(_ key: String) -> Bool { settings[key] as? Bool ?? Self.defaults[key] as? Bool ?? false }
    func number(_ key: String) -> Double {
        (settings[key] as? NSNumber)?.doubleValue ?? (Self.defaults[key] as? NSNumber)?.doubleValue ?? 0
    }
    func string(_ key: String) -> String { settings[key] as? String ?? Self.defaults[key] as? String ?? "" }
    func strings(_ key: String) -> [String] { settings[key] as? [String] ?? Self.defaults[key] as? [String] ?? [] }
    func value(_ key: String) -> Any? { settings[key] ?? Self.defaults[key] }

    /// Changes one setting; everything else in settings.json stays as it was.
    func set(_ key: String, _ value: Any) {
        update(settingsFile) { $0[key] = value }
    }

    // MARK: The dock's place, and the Mac's own choices

    var position: String {
        let place = (dock["position"] as? String ?? "bottom").lowercased()
        return ["bottom", "left", "right"].contains(place) ? place : "bottom"   // the menu bar holds the top
    }
    var autoHide: Bool { dock["autoHide"] as? Bool ?? false }
    /// "petal" shows Petal and hides macOS's Dock; "macos" keeps macOS's Dock and turns Petal's off.
    var whichDock: String { dock["dock"] as? String ?? "petal" }
    var welcomed: Bool { dock["welcomed"] as? Bool ?? false }
    /// Windows end above the dock instead of running under it (while auto-hide is off).
    var keepWindowsClear: Bool { dock["keepWindowsClear"] as? Bool ?? true }

    func setDock(_ key: String, _ value: Any) {
        update(dockFile) { $0[key] = value }
    }

    // MARK: Modes

    func mode(id: String) -> Mode? { modes.first { $0.id == id } ?? modes.first }

    /// The mode of Desktop `number`: the one it was put in, else the default.
    func mode(forDesktop number: Int) -> Mode? { mode(id: workspaces[String(number)] ?? defaultMode) }

    func desktops(in mode: String) -> [Int] {
        workspaces.filter { $0.value == mode }.compactMap { Int($0.key) }.sorted()
    }

    /// Puts Desktop `number` in a mode, the way Omarchy remembers a workspace's mode. The dock sees it at once; the
    /// file is written a moment later, off the main thread, so switching mode never waits for the disk.
    func setMode(_ id: String, forDesktop number: Int) {
        workspaces[String(number)] = id
        var map = modesRoot["workspaces"] as? [String: Any] ?? [:]
        map[String(number)] = id
        modesRoot["workspaces"] = map
        let file = modesFile
        let files = self.files
        writing += 1
        Self.writer.async {
            // A file that's there but isn't valid JSON is left alone (see `update`).
            if !FileManager.default.fileExists(atPath: file.path) || Self.parse(file) != nil {
                var root = Self.readObject(file)
                var map = root["workspaces"] as? [String: Any] ?? [:]
                map[String(number)] = id
                root["workspaces"] = map
                Self.writeObject(root, to: file)
            }
            let disk = Self.snapshot(files)
            DispatchQueue.main.async { MainActor.assumeIsolated { PetalApp.shared.config.written(disk, valid: true, stale: false) } }
        }
    }

    /// The three files as they are on disk now (on the writer's queue, after a write).
    nonisolated private static func snapshot(_ files: [URL]) -> [NSDictionary] { files.map { readObject($0) as NSDictionary } }

    /// One of Petal's writes is done. Once none is still on its way, memory must match all three files: one that
    /// doesn't (someone else's change landed meanwhile, in that file or another) is loaded, and the files' stamps
    /// are taken as they are now, so the watcher never mistakes an unseen change for one already read.
    private func written(_ disk: [NSDictionary], valid: Bool, stale: Bool) {
        writing -= 1
        if !valid { NSSound.beep() }
        guard writing == 0 else { return }   // the last write's check covers this one's
        let mine = [modesRoot as NSDictionary, settings as NSDictionary, dock as NSDictionary]
        if !valid || stale || !zip(disk, mine).allSatisfy({ $0.isEqual($1) }) {
            reload()   // what's on disk stands
            onChange?()
        }
        stamps = currentStamps()
    }

    private var files: [URL] { [modesFile, settingsFile, dockFile] }

    /// Writes from `setMode`, one after another, in order.
    nonisolated private static let writer = DispatchQueue(label: "petal.config.write", qos: .userInitiated)
    /// Writes not finished yet: the watcher waits for them, so Petal's own write isn't read back as someone's change.
    @ObservationIgnored private var writing = 0

    func setDefaultMode(_ id: String) {
        update(modesFile) { $0["defaultMode"] = id }
    }

    /// Writes one mode back, adding it if it is new. Fields Petal for macOS doesn't use (hyprland) are kept.
    func save(_ mode: Mode) {
        update(modesFile) { root in
            var list = root["modes"] as? [[String: Any]] ?? []
            var entry = list.first { $0["id"] as? String == mode.id } ?? [:]
            entry["id"] = mode.id
            entry["name"] = mode.name
            entry["icon"] = mode.icon
            entry["color"] = mode.hex
            entry["about"] = mode.about
            entry["apps"] = mode.apps
            entry["sites"] = mode.sites
            entry["focusDelay"] = mode.focusDelay
            entry["allow"] = mode.allow
            entry["shortcut"] = mode.shortcut.isEmpty ? nil : mode.shortcut
            entry["distracting"] = mode.distracting
            entry["hold"] = mode.hold
            if let index = list.firstIndex(where: { $0["id"] as? String == mode.id }) { list[index] = entry } else { list.append(entry) }
            root["modes"] = list
        }
    }

    func delete(mode id: String) {
        update(modesFile) { root in
            root["modes"] = (root["modes"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != id }
            root["workspaces"] = (root["workspaces"] as? [String: Any] ?? [:]).filter { $0.value as? String != id }
            if root["defaultMode"] as? String == id {
                root["defaultMode"] = ((root["modes"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
            }
        }
    }

    func addApp(_ app: String, to mode: String) {
        guard var entry = self.mode(id: mode), !entry.apps.contains(app) else { return }
        entry.apps.append(app)
        save(entry)
    }

    func removeApp(_ app: String, from mode: String) {
        guard var entry = self.mode(id: mode) else { return }
        entry.apps.removeAll { $0 == app }
        save(entry)
    }

    /// "Keep it here": an app or site that's fine in this mode without being in its dock.
    func allow(_ thing: String, in mode: String) {
        guard var entry = self.mode(id: mode), entry.id == mode, !entry.allow.contains(thing) else { return }
        entry.allow.append(thing)
        save(entry)
    }

    /// The AI's answer for a mode that didn't say whether it's distracting; nothing else in the mode changes.
    func setDistracting(_ value: Bool, for id: String) {
        update(modesFile) { root in
            var list = root["modes"] as? [[String: Any]] ?? []
            guard let index = list.firstIndex(where: { $0["id"] as? String == id }), list[index]["distracting"] == nil else { return }
            list[index]["distracting"] = value
            root["modes"] = list
        }
    }

    /// A site the AI sorted into a mode.
    func addSite(_ domain: String, to mode: String) {
        guard var entry = self.mode(id: mode), entry.id == mode, !entry.sites.contains(where: { $0.caseInsensitiveCompare(domain) == .orderedSame }) else { return }
        entry.sites.append(domain)
        save(entry)
    }

    func moveApp(_ app: String, in mode: String, to index: Int) {
        guard var entry = self.mode(id: mode), let from = entry.apps.firstIndex(of: app) else { return }
        entry.apps.remove(at: from)
        entry.apps.insert(app, at: min(max(0, index), entry.apps.count))
        save(entry)
    }

    /// "Import Dock": macOS's Dock becomes a mode, My Dock, which every Desktop starts in, and its folders become
    /// Petal's stacks.
    func importSystemDock() {
        let apps = SystemDock.apps()
        var mode = self.mode(id: "dock").flatMap { $0.id == "dock" ? $0 : nil }
            ?? Mode(id: "dock", name: "My Dock", icon: "dock.rectangle", color: NSColor(hex: "#d9367f")!,
                    about: "everyday apps, from macOS's Dock", apps: [], sites: [], focusDelay: 0, allow: [],
                    distracting: false)
        mode.apps = apps
        save(mode)
        setDefaultMode("dock")
        let folders = SystemDock.folders()
        if !folders.isEmpty { set("stackFolders", folders) }
    }

    // MARK: Files

    /// A change takes effect at once, in memory: the dock, the settings window and the menus show it in the same
    /// frame. The file is written a moment later, off the main thread, in order with every other write (reading,
    /// changing and writing a file took the main thread several milliseconds, and the settings window stuttered).
    private func update(_ file: URL, _ change: @escaping (inout [String: Any]) -> Void) {
        var root = file == settingsFile ? settings : file == dockFile ? dock : modesRoot
        change(&root)
        Perf.span("config: in memory") {
            if file == settingsFile { settings = root } else if file == dockFile { dock = root } else { use(modes: root) }
        }
        // Someone else changed a file in the last second, before the watcher read it: read it once this is written.
        let stale = writing == 0 && currentStamps() != stamps
        let files = self.files
        writing += 1
        Self.writer.async {
            // A file that's there but isn't valid JSON (half-written by an editor, say) is left alone, not replaced
            // by the one key being changed.
            let valid = !FileManager.default.fileExists(atPath: file.path) || Self.parse(file) != nil
            if valid {
                var disk = Self.readObject(file)
                change(&disk)
                Self.writeObject(disk, to: file)
            }
            // What's on disk now: someone else's change may have landed with ours.
            let disk = Self.snapshot(files)
            DispatchQueue.main.async { MainActor.assumeIsolated { PetalApp.shared.config.written(disk, valid: valid, stale: stale) } }
        }
        Perf.span("config: onChange") { onChange?() }
    }

    /// Waits for every write still under way (on quit).
    func flush() { Self.writer.sync {} }

    /// modes.json as read, for changes made in memory before it's written.
    @ObservationIgnored private var modesRoot: [String: Any] = [:]

    private func reload() {
        use(modes: Self.readObject(modesFile))
        settings = Self.readObject(settingsFile)
        dock = Self.readObject(dockFile)
    }

    private func use(modes root: [String: Any]) {
        modesRoot = root
        defaultMode = root["defaultMode"] as? String ?? ""
        workspaces = (root["workspaces"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        modes = (root["modes"] as? [[String: Any]] ?? []).compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            return Mode(id: id, name: m["name"] as? String ?? id, icon: m["icon"] as? String ?? "",
                        color: NSColor(hex: m["color"] as? String) ?? .systemPink, about: m["about"] as? String ?? "",
                        apps: (m["apps"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) },
                        sites: m["sites"] as? [String] ?? [], focusDelay: (m["focusDelay"] as? NSNumber)?.doubleValue ?? 0,
                        allow: m["allow"] as? [String] ?? [], shortcut: m["shortcut"] as? String ?? "",
                        distracting: m["distracting"] as? Bool, hold: m["hold"] as? Bool ?? false)
        }
    }

    /// Looks for changes once a second. Modification times catch both ways a file gets written: replaced whole (as
    /// Petal and many editors do) and rewritten in place.
    private func watch() {
        stamps = currentStamps()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.writing == 0 else { return }
                let now = self.currentStamps()
                guard now != self.stamps else { return }
                self.stamps = now
                self.reload()
                self.onChange?()
            }
        }
    }

    private func currentStamps() -> [Date?] {
        [modesFile, settingsFile, dockFile].map {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
    }

    nonisolated static func readObject(_ url: URL) -> [String: Any] { parse(url) ?? [:] }

    nonisolated static func parse(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated static func writeObject(_ object: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}

extension NSColor {
    convenience init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), text.hasPrefix("#") else { return nil }
        text.removeFirst()
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
