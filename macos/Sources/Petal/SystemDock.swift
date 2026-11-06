import Foundation

/// Petal replaces macOS's Dock while it runs: the Dock is set to hide, and to wait 1000 seconds before it shows,
/// which keeps it out of sight. A full-screen app shows macOS's Dock whatever its wait, as the pointer pushes on its
/// edge; that can't be turned off (slowing its showing left its labels stuck on the screen). It stays on its own edge
/// and size, since macOS minimizes windows toward it. Quitting Petal gives it back exactly as it was.
///
/// The Dock's own settings are saved to ~/.config/petal/macos-dock.json before they change, and that file is the
/// promise to put them back: if Petal crashes, the next launch keeps the saved settings (it doesn't save the hidden
/// ones over them), and the next quit restores them.
@MainActor
enum SystemDock {
    private static let backup = Config.folder.appending(path: "macos-dock.json")
    /// What Petal changes, saved first. (`orientation` is only put back: an earlier Petal moved the Dock to a side.)
    private static let keys = [("autohide", "-bool"), ("autohide-delay", "-float"), ("autohide-time-modifier", "-float"),
                               ("tilesize", "-float"), ("orientation", "-string")]

    static var isReplaced: Bool { FileManager.default.fileExists(atPath: backup.path) }

    /// The apps in macOS's Dock, in its order, as bundle ids: "Import Dock" makes them a mode.
    static func apps() -> [String] {
        let items = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] ?? []
        var ids: [String] = []
        for item in items {
            let tile = item["tile-data"] as? [String: Any] ?? [:]
            var id = tile["bundle-identifier"] as? String
            if id == nil, let file = tile["file-data"] as? [String: Any], let path = file["_CFURLString"] as? String,
               let url = URL(string: path) {
                id = Bundle(url: url)?.bundleIdentifier
            }
            if let id, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// The folders in macOS's Dock (Downloads, Screenshots…), written with ~ as Petal's stackFolders are.
    static func folders() -> [String] {
        let items = CFPreferencesCopyAppValue("persistent-others" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] ?? []
        return items.compactMap { item in
            let tile = item["tile-data"] as? [String: Any] ?? [:]
            guard let file = tile["file-data"] as? [String: Any], let text = file["_CFURLString"] as? String,
                  let url = URL(string: text), url.isFileURL else { return nil }
            let path = url.path(percentEncoded: false)
            let home = NSHomeDirectory()
            let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
            return trimmed.hasPrefix(home) ? "~" + trimmed.dropFirst(home.count) : trimmed
        }
    }

    /// Hides macOS's Dock, only once its own settings are saved. Returns false, leaving it alone, if they can't be.
    @discardableResult
    static func replace() -> Bool {
        // Saved once, before the first change. A file from an older Petal lacks the newer settings: theirs now are
        // still the person's own, so they're added to it.
        var saved = isReplaced ? Config.readObject(backup) : [:]
        let missing = keys.filter { saved[$0.0] == nil }
        if !missing.isEmpty {
            for (key, _) in missing { saved[key] = read(key) ?? NSNull() }
            Config.writeObject(saved, to: backup)
            // Read back: every setting Petal changes must be saved before it changes one.
            let written = Config.readObject(backup)
            guard isReplaced, keys.allSatisfy({ written[$0.0] != nil }) else { return false }
        }
        write("autohide", "-bool", "true")
        write("autohide-delay", "-float", "1000")
        // Its own pace (an earlier Petal slowed its showing to a crawl for full screen, which left its labels stuck).
        if let pace = saved["autohide-time-modifier"] as? Double { write("autohide-time-modifier", "-float", "\(pace)") } else { defaults("delete", "com.apple.dock", "autohide-time-modifier") }
        // Its own size (an earlier Petal made it smallest): about as wide as Petal's dock, which holds the same apps,
        // so a window minimizes toward its right end, where Petal keeps minimized windows.
        if let size = saved["tilesize"] as? Double { write("tilesize", "-float", "\(size)") } else { defaults("delete", "com.apple.dock", "tilesize") }
        // Its own edge, as the person had it.
        if let side = saved["orientation"] as? String { write("orientation", "-string", side) } else { defaults("delete", "com.apple.dock", "orientation") }
        restartDock()
        return true
    }

    static func restore() {
        guard isReplaced else { return }
        let saved = Config.readObject(backup)
        for (key, type) in keys {
            guard let value = saved[key] else { continue }   // never saved: never changed
            if !(value is NSNull) {
                write(key, type, type == "-bool" ? ((value as? Bool ?? false) ? "true" : "false") : "\(value)")
            } else {
                defaults("delete", "com.apple.dock", key)
            }
        }
        try? FileManager.default.removeItem(at: backup)
        restartDock()
    }

    private static func read(_ key: String) -> Any? {
        guard let text = defaults("read", "com.apple.dock", key)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if key == "autohide" { return text == "1" }
        if key == "orientation" { return text }
        return Double(text)
    }

    private static func write(_ key: String, _ type: String, _ value: String) {
        defaults("write", "com.apple.dock", key, type, value)
    }

    @discardableResult
    private static func defaults(_ arguments: String...) -> String? {
        run("/usr/bin/defaults", arguments)
    }

    private static func restartDock() {
        run("/usr/bin/killall", ["Dock"])
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
