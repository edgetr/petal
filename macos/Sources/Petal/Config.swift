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
    var focusDelay: Double
    var allow: [String]

    var hex: String { color.hex }
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
    static let folder = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".config/petal")
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
        "stackFolders": ["~/Downloads", "~/Pictures/Screenshots"], "trash": true, "modes": true, "countdown": false,
        "focusGuard": false, "holdNotifications": true, "ai": true, "claudeUsage": true, "autoUpdate": true,
        "claudePath": "", "chatModel": "sonnet", "chatEffort": "medium", "claudeAccess": "auto",
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

    /// Puts Desktop `number` in a mode, the way Omarchy remembers a workspace's mode.
    func setMode(_ id: String, forDesktop number: Int) {
        update(modesFile) { root in
            var map = root["workspaces"] as? [String: Any] ?? [:]
            map[String(number)] = id
            root["workspaces"] = map
        }
    }

    func setDefaultMode(_ id: String) {
        update(modesFile) { $0["defaultMode"] = id }
    }

    /// Writes one mode back, adding it if it is new. Fields Petal for macOS doesn't use (hold) are kept.
    func save(_ mode: Mode) {
        update(modesFile) { root in
            var list = root["modes"] as? [[String: Any]] ?? []
            var entry = list.first { $0["id"] as? String == mode.id } ?? ["hold": false]
            entry["id"] = mode.id
            entry["name"] = mode.name
            entry["icon"] = mode.icon
            entry["color"] = mode.hex
            entry["about"] = mode.about
            entry["apps"] = mode.apps
            entry["sites"] = mode.sites
            entry["focusDelay"] = mode.focusDelay
            entry["allow"] = mode.allow
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
                    about: "everyday apps, from macOS's Dock", apps: [], sites: [], focusDelay: 0, allow: [])
        mode.apps = apps
        save(mode)
        setDefaultMode("dock")
        let folders = SystemDock.folders()
        if !folders.isEmpty { set("stackFolders", folders) }
    }

    // MARK: Files

    private func update(_ file: URL, _ change: (inout [String: Any]) -> Void) {
        // A file that's there but isn't valid JSON (half-written by an editor, say) is left alone, not replaced
        // by the one key being changed.
        if FileManager.default.fileExists(atPath: file.path), Self.parse(file) == nil {
            NSSound.beep()
            return
        }
        var root = Self.readObject(file)
        change(&root)
        Self.writeObject(root, to: file)
        reload()
        stamps = currentStamps()
        onChange?()
    }

    private func reload() {
        let root = Self.readObject(modesFile)
        defaultMode = root["defaultMode"] as? String ?? ""
        workspaces = (root["workspaces"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        modes = (root["modes"] as? [[String: Any]] ?? []).compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            return Mode(id: id, name: m["name"] as? String ?? id, icon: m["icon"] as? String ?? "",
                        color: NSColor(hex: m["color"] as? String) ?? .systemPink, about: m["about"] as? String ?? "",
                        apps: (m["apps"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) },
                        sites: m["sites"] as? [String] ?? [], focusDelay: (m["focusDelay"] as? NSNumber)?.doubleValue ?? 0,
                        allow: m["allow"] as? [String] ?? [])
        }
        settings = Self.readObject(settingsFile)
        dock = Self.readObject(dockFile)
    }

    /// Looks for changes once a second. Modification times catch both ways a file gets written: replaced whole (as
    /// Petal and many editors do) and rewritten in place.
    private func watch() {
        stamps = currentStamps()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
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

    static func readObject(_ url: URL) -> [String: Any] { parse(url) ?? [:] }

    static func parse(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func writeObject(_ object: [String: Any], to url: URL) {
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
