import AppKit

/// Sharing a dock: a recipe is one `<name>.petal` file (JSON) with the modes, the apps' names, and the look and
/// feature settings; never paths, AI settings, the schedule or anything personal. The same format on Omarchy, so a
/// recipe made on one works on the other: apps are matched by id on the same platform, else by name.
enum Recipe {
    /// The settings a recipe carries: how the dock looks and what it shows.
    static let lookKeys = ["dockColor", "dockOpacity", "dockBorderColor", "dockBorderOpacity", "dockRadius", "dockSheen", "dockMargin",
                           "iconSize", "iconPadding", "idleOpacity", "separators", "hoverLiftAmount", "glowStrength", "accentColor",
                           "popupColor", "popupOpacity", "font", "tooltips", "hoverLift", "appGlow", "previews", "minimized", "badges",
                           "bounce", "progress", "quickActions", "recentFiles", "dropToOpen", "nowPlaying", "stacks", "trash",
                           "magnification", "magnificationAmount"]

    /// Words for those settings, for showing what a recipe's look would change.
    static let lookNames: [String: String] = [
        "dockColor": "dock tint", "dockOpacity": "tint strength", "dockBorderColor": "border color", "dockBorderOpacity": "border",
        "dockRadius": "corners", "dockSheen": "sheen", "dockMargin": "margin", "iconSize": "icon size", "iconPadding": "icon spacing",
        "idleOpacity": "apps not running", "separators": "dividers", "hoverLiftAmount": "lift", "glowStrength": "glow strength",
        "accentColor": "accent", "popupColor": "popup color", "popupOpacity": "popup opacity", "font": "font", "tooltips": "names on hover",
        "hoverLift": "lift on hover", "appGlow": "glow", "previews": "window previews", "minimized": "minimized windows",
        "badges": "badges", "bounce": "bounce", "progress": "download progress", "quickActions": "quick actions",
        "recentFiles": "recent files", "dropToOpen": "drop to open", "nowPlaying": "now playing", "stacks": "stacks", "trash": "Trash",
        "magnification": "magnification", "magnificationAmount": "magnification amount", "position": "position", "autoHide": "auto-hide",
    ]

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    // MARK: Export

    /// This Mac's dock as a recipe.
    static func make(name: String) -> [String: Any] {
        let root = MCP.read(MCP.modesFile) ?? [:]
        let settings = MCP.read(MCP.settingsFile) ?? [:]
        let dock = MCP.read(MCP.dockFile) ?? [:]
        var modes: [[String: Any]] = []
        var apps: [String: String] = [:]
        for var mode in root["modes"] as? [[String: Any]] ?? [] {
            mode["workspaces"] = nil
            if var look = mode["hyprland"] as? [String: Any] {   // a wallpaper is a path on someone's computer
                look["wallpaper"] = nil
                mode["hyprland"] = look.isEmpty ? nil : look
            }
            for id in (mode["apps"] as? [String] ?? []) + (mode["allow"] as? [String] ?? []) where apps[id] == nil {
                apps[id] = Insights.name(id)
            }
            modes.append(mode)
        }
        var look: [String: Any] = [:]
        for key in lookKeys { look[key] = settings[key] ?? MCP.schema[key]?.first }
        return ["petal": 1, "name": name, "from": "macos", "modes": modes, "apps": apps, "settings": look,
                "dock": ["position": dock["position"] as? String ?? "bottom", "autoHide": dock["autoHide"] as? Bool ?? false]]
    }

    /// Saves the recipe; `path` may be a folder, and defaults to ~/<name>.petal.
    static func export(path: String?, name: String?) throws -> String {
        let name = (name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "My dock"
        var url = URL(fileURLWithPath: ((path ?? "") as NSString).expandingTildeInPath)
        var isFolder: ObjCBool = false
        if path == nil || path!.isEmpty {
            url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: name.replacingOccurrences(of: "/", with: "-") + ".petal")
        } else if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            url = url.appending(path: name.replacingOccurrences(of: "/", with: "-") + ".petal")
        } else if url.pathExtension != "petal" {
            url = url.appendingPathExtension("petal")
        }
        let data = try JSONSerialization.data(withJSONObject: make(name: name), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        return url.path
    }

    // MARK: Import

    struct PlannedMode: Identifiable {
        var object: [String: Any]
        let id: String
        let name: String
        let icon: String
        let color: String
        let about: String
        let apps: [String]
        let missing: [String]
        let renamed: Bool
    }

    struct Plan {
        let name: String
        let from: String
        let modes: [PlannedMode]
        let look: [String: Any]
        let dock: [String: Any]
        /// The look's settings that differ from this Mac's.
        let lookChanges: [String]
        var missing: [String] { modes.flatMap(\.missing).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    }

    /// What importing `url` would do, without doing it.
    static func plan(_ url: URL) throws -> Plan {
        guard let data = try? Data(contentsOf: url) else { throw Failure("Can't read \(url.lastPathComponent).") }
        guard let recipe = try? JSONSerialization.jsonObject(with: data) as? [String: Any], recipe["petal"] != nil,
              let modes = recipe["modes"] as? [[String: Any]] else {
            throw Failure("\(url.lastPathComponent) isn't a Petal recipe.")
        }
        guard ((recipe["petal"] as? NSNumber)?.intValue ?? 1) <= 1 else { throw Failure("This recipe needs a newer Petal.") }
        let from = recipe["from"] as? String ?? ""
        let names = recipe["apps"] as? [String: String] ?? [:]
        var byName: [String: String] = [:]
        for app in MCP.installed() {
            let file = ((app.path as NSString).lastPathComponent as NSString).deletingPathExtension
            for name in [app.name, file] where byName[name.lowercased()] == nil { byName[name.lowercased()] = app.id }
        }
        func resolve(_ id: String) -> String? {
            if from == "macos", NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { return id }
            return byName[(names[id] ?? id).lowercased()]
        }
        let existing = MCP.read(MCP.modesFile)?["modes"] as? [[String: Any]] ?? []
        var taken = Set(existing.compactMap { $0["id"] as? String })
        var takenNames = Set(existing.compactMap { ($0["name"] as? String)?.lowercased() })
        var planned: [PlannedMode] = []
        for (index, var mode) in modes.enumerated() {
            let original = (mode["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "mode"
            var id = original, n = 2
            while taken.contains(id) { id = "\(original)-\(n)"; n += 1 }
            taken.insert(id)
            var apps: [String] = [], missing: [String] = []
            for app in mode["apps"] as? [String] ?? [] {
                if let found = resolve(app) { if !apps.contains(found) { apps.append(found) } } else { missing.append(names[app] ?? app) }
            }
            let allow = (mode["allow"] as? [String] ?? []).compactMap(resolve)
            // A name that's already there gets a number too, so the two can be told apart.
            let given = mode["name"] as? String ?? original.capitalized
            var name = given, m = 2
            while takenNames.contains(name.lowercased()) { name = "\(given) \(m)"; m += 1 }
            takenNames.insert(name.lowercased())
            let about = mode["about"] as? String ?? ""
            var icon = mode["icon"] as? String ?? ""
            if NSImage(systemSymbolName: icon, accessibilityDescription: nil) == nil { icon = symbol(for: name + " " + about) }
            let color = NSColor(hex: mode["color"] as? String) != nil ? mode["color"] as! String
                : Insights.palette[index % Insights.palette.count]
            mode["id"] = id
            mode["apps"] = apps
            mode["allow"] = allow
            mode["icon"] = icon
            mode["color"] = color
            mode["name"] = name
            mode["workspaces"] = nil
            if mode["about"] == nil { mode["about"] = "" }
            if mode["sites"] == nil { mode["sites"] = [String]() }
            if mode["focusDelay"] == nil { mode["focusDelay"] = 0 }
            if mode["hold"] == nil { mode["hold"] = false }
            planned.append(PlannedMode(object: mode, id: id, name: name, icon: icon, color: color, about: about, apps: apps,
                                       missing: missing, renamed: id != original))
        }
        let settings = recipe["settings"] as? [String: Any] ?? [:]
        var look: [String: Any] = [:]
        for key in lookKeys { if let value = settings[key] { look[key] = value } }
        var dock: [String: Any] = [:]
        if let given = recipe["dock"] as? [String: Any] {
            if let position = given["position"] as? String { dock["position"] = ["left", "right"].contains(position) ? position : "bottom" }
            if let hide = given["autoHide"] as? Bool { dock["autoHide"] = hide }
        }
        let current = MCP.read(MCP.settingsFile) ?? [:]
        let currentDock = MCP.read(MCP.dockFile) ?? [:]
        var changes: [String] = []
        for key in lookKeys where look[key] != nil {
            let now = current[key] ?? MCP.schema[key]?.first
            if !same(now, look[key]) { changes.append(key) }
        }
        if let position = dock["position"] as? String, position != (currentDock["position"] as? String ?? "bottom") { changes.append("position") }
        if let hide = dock["autoHide"] as? Bool, hide != (currentDock["autoHide"] as? Bool ?? false) { changes.append("autoHide") }
        return Plan(name: recipe["name"] as? String ?? url.deletingPathExtension().lastPathComponent, from: from, modes: planned,
                    look: look, dock: dock, lookChanges: changes)
    }

    /// Adds the plan's modes, and its look when asked.
    @discardableResult
    static func apply(_ plan: Plan, look: Bool) throws -> [String: Any] {
        try MCP.update(MCP.modesFile, fallback: ["defaultMode": plan.modes.first?.id ?? "", "workspaces": [:], "modes": []]) { root in
            root["modes"] = (root["modes"] as? [[String: Any]] ?? []) + plan.modes.map(\.object)
            if (root["defaultMode"] as? String ?? "").isEmpty { root["defaultMode"] = plan.modes.first?.id ?? "" }
            if root["workspaces"] == nil { root["workspaces"] = [String: Any]() }
        }
        if look {
            if !plan.look.isEmpty { try MCP.update(MCP.settingsFile) { $0.merge(plan.look) { _, new in new } } }
            if !plan.dock.isEmpty { try MCP.update(MCP.dockFile) { $0.merge(plan.dock) { _, new in new } } }
        }
        return ["modes": plan.modes.map { ["id": $0.id, "name": $0.name, "apps": $0.apps] }, "missing": plan.missing, "look": look]
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x as NSObject, y as NSObject): return x.isEqual(y)
        default: return false
        }
    }

    /// An SF Symbol for a mode from another platform, whose icon is a Nerd Font glyph.
    static func symbol(for text: String) -> String {
        let table: [(String, String)] = [
            ("code", "hammer"), ("build", "hammer"), ("dev", "hammer"), ("program", "hammer"), ("terminal", "hammer"),
            ("writ", "pencil"), ("note", "pencil"), ("paper", "pencil"), ("social", "bubble.left.and.bubble.right"),
            ("chat", "bubble.left.and.bubble.right"), ("friend", "bubble.left.and.bubble.right"), ("music", "music.note"),
            ("design", "paintbrush"), ("art", "paintbrush"), ("draw", "paintbrush"), ("study", "graduationcap"), ("school", "graduationcap"),
            ("learn", "graduationcap"), ("game", "gamecontroller"), ("play", "gamecontroller"), ("read", "book"), ("book", "book"),
            ("video", "film"), ("film", "film"), ("watch", "film"), ("photo", "camera"), ("work", "briefcase"), ("mail", "envelope"),
            ("health", "heart"), ("home", "house"), ("travel", "airplane"), ("shop", "cart"),
        ]
        let lower = text.lowercased()
        return table.first { lower.contains($0.0) }?.1 ?? "circle.fill"
    }
}
