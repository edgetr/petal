import AppKit

/// A focus mode from modes.json. On macOS its apps are bundle identifiers, and its icon is an SF Symbol name
/// (a Nerd Font glyph from an Omarchy modes.json still shows, as text).
struct Mode: Equatable {
    let id: String
    let name: String
    let icon: String
    let color: NSColor
    let apps: [String]
}

/// Petal's files in ~/.config/petal, the same folder and formats as on Omarchy:
/// - modes.json: the modes, and which mode each Desktop is in ("workspaces": {"1": "building"}).
/// - settings.json: the settings both platforms share (Claude's tools change them).
/// - dock.json: where the dock sits, which Omarchy keeps in its own shell config.
/// Each is read again within a second of changing on disk, whoever changed it (Petal's menus, Claude, an editor).
@MainActor
final class Config {
    static let folder = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".config/petal")
    let modesFile = folder.appending(path: "modes.json")
    let settingsFile = folder.appending(path: "settings.json")
    let dockFile = folder.appending(path: "dock.json")

    private(set) var modes: [Mode] = []
    private(set) var defaultMode = ""
    private(set) var workspaces: [String: String] = [:]
    private(set) var position = "bottom"
    private(set) var autoHide = false
    private(set) var replaceDock = true
    private(set) var iconSize: CGFloat = 36
    private(set) var idleOpacity: Double = 0.7
    private(set) var tooltips = true
    private(set) var hoverLift = true

    var onChange: (() -> Void)?
    private var timer: Timer?
    private var stamps: [Date?] = []

    init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: modesFile.path),
           let seed = Bundle.main.url(forResource: "modes", withExtension: "json") {
            try? FileManager.default.copyItem(at: seed, to: modesFile)
        }
        reload()
        watch()
    }

    func mode(id: String) -> Mode? { modes.first { $0.id == id } ?? modes.first }

    /// The mode of Desktop `number`: the one it was put in, else the default.
    func mode(forDesktop number: Int) -> Mode? { mode(id: workspaces[String(number)] ?? defaultMode) }

    /// Puts Desktop `number` in a mode, the way Omarchy remembers a workspace's mode. Only "workspaces" changes;
    /// everything else in modes.json is written back as it was read.
    func setMode(_ id: String, forDesktop number: Int) {
        var root = Self.readObject(modesFile)
        var map = root["workspaces"] as? [String: Any] ?? [:]
        map[String(number)] = id
        root["workspaces"] = map
        Self.writeObject(root, to: modesFile)
        reload()
        stamps = currentStamps()
    }

    func setDock(_ key: String, _ value: Any) {
        var root = Self.readObject(dockFile)
        root[key] = value
        Self.writeObject(root, to: dockFile)
        reload()
        stamps = currentStamps()
    }

    private func reload() {
        let root = Self.readObject(modesFile)
        defaultMode = root["defaultMode"] as? String ?? ""
        workspaces = (root["workspaces"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        modes = (root["modes"] as? [[String: Any]] ?? []).compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            return Mode(id: id, name: m["name"] as? String ?? id, icon: m["icon"] as? String ?? "",
                        color: NSColor(hex: m["color"] as? String) ?? .systemPink,
                        apps: (m["apps"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) })
        }

        let settings = Self.readObject(settingsFile)
        iconSize = CGFloat(settings["iconSize"] as? Double ?? 36)
        idleOpacity = settings["idleOpacity"] as? Double ?? 0.7
        tooltips = settings["tooltips"] as? Bool ?? true
        hoverLift = settings["hoverLift"] as? Bool ?? true

        let dock = Self.readObject(dockFile)
        let place = (dock["position"] as? String ?? "bottom").lowercased()
        position = ["bottom", "left", "right"].contains(place) ? place : "bottom"   // the menu bar holds the top
        autoHide = dock["autoHide"] as? Bool ?? false
        replaceDock = dock["replaceDock"] as? Bool ?? true
    }

    /// Looks for changes once a second. Modification times catch both ways a file gets written: replaced whole (as
    /// Petal and many editors do) and rewritten in place, which a watcher on the folder alone misses.
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

    static func readObject(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
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
}
