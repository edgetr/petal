import Foundation

/// Petal replaces macOS's Dock while it runs: the Dock is set to hide, and to wait 1000 seconds before it shows,
/// which keeps it out of sight. Quitting Petal gives it back exactly as it was.
///
/// The Dock's own settings are saved to ~/.config/petal/macos-dock.json before they change, and that file is the
/// promise to put them back: if Petal crashes, the next launch keeps the saved settings (it doesn't save the hidden
/// ones over them), and the next quit restores them.
@MainActor
enum SystemDock {
    private static let backup = Config.folder.appending(path: "macos-dock.json")
    private static let keys = [("autohide", "-bool"), ("autohide-delay", "-float")]

    static var isReplaced: Bool { FileManager.default.fileExists(atPath: backup.path) }

    static func replace() {
        if !isReplaced {
            var saved: [String: Any] = [:]
            for (key, _) in keys { saved[key] = read(key) ?? NSNull() }
            Config.writeObject(saved, to: backup)
        }
        write("autohide", "-bool", "true")
        write("autohide-delay", "-float", "1000")
        restartDock()
    }

    static func restore() {
        guard isReplaced else { return }
        let saved = Config.readObject(backup)
        for (key, type) in keys {
            if let value = saved[key], !(value is NSNull) {
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
