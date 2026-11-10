import Foundation

// Checks ModesMigration.swift on throwaway folders in the temporary folder: a Mac's modes.json becomes the dock's
// apps in dock.json, once, and nothing else is written. Run with macos/checks/run.sh.
@main
struct ModesMigrationCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    /// A pair of empty folders for one case (Petal's config folder and its Application Support one), removed after.
    static func folders(_ body: (_ config: URL, _ support: URL) -> Void) {
        let root = FileManager.default.temporaryDirectory.appending(path: "petal-modes-check-\(UUID().uuidString)")
        let config = root.appending(path: "config"), support = root.appending(path: "support")
        try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        body(config, support)
    }

    static func write(_ text: String, _ file: URL) { try? Data(text.utf8).write(to: file) }
    static func object(_ file: URL) -> [String: Any]? {
        (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    static func names(_ folder: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
    /// Every file's bytes and modification date, to tell that a second run touched nothing.
    static func state(_ folders: [URL]) -> [String] {
        folders.flatMap { folder in
            names(folder).map { name in
                let file = folder.appending(path: name)
                let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
                return "\(name)|\((try? Data(contentsOf: file))?.base64EncodedString() ?? "")|\(date?.timeIntervalSince1970 ?? 0)"
            }
        }
    }

    /// Four modes, the default one second in the file, as a Mac that had modes kept them.
    static let modes = """
    { "defaultMode": "dock", "workspaces": { "1": "building", "2": "social" },
      "modes": [
        { "id": "building", "name": "Building", "icon": "hammer", "color": "#b18cff", "apps": ["com.apple.Terminal", "com.apple.dt.Xcode"] },
        { "id": "dock", "name": "My Dock", "icon": "dock.rectangle", "color": "#d9367f", "about": "everyday apps",
          "apps": ["com.apple.Safari", " com.apple.mail ", "https://github.com", "com.apple.Safari", "", "com.apple.Notes"], "hold": false },
        { "id": "social", "name": "Social", "apps": ["com.apple.MobileSMS"], "sites": ["x.com"], "distracting": true, "focusDelay": 30 },
        { "id": "writing", "name": "Writing", "apps": ["com.apple.TextEdit"], "hold": true, "allow": ["com.apple.Music"] }
      ] }
    """
    static let dockApps = ["com.apple.Safari", "com.apple.mail", "https://github.com", "com.apple.Notes"]

    static func main() {
        // 1. Four modes with a default: its apps become the dock's, in order; modes.json goes; nothing else is written.
        folders { config, support in
            write(modes, config.appending(path: "modes.json"))
            write(#"{"position": "left", "autoHide": true, "welcomed": true, "dock": "petal"}"#, config.appending(path: "dock.json"))
            write(#"{"iconSize": 44, "modes": true, "focusGuard": false, "holdNotifications": true, "dailySummary": "18:00", "tiling": true, "aiMemory": true, "mine": 1, "font": "Adwaita Sans", "dockSheen": true, "popupOpacity": 0.74}"#,
                  config.appending(path: "settings.json"))
            write("keep me\n", config.appending(path: "instructions.md"))
            write(#"{"memories": [{"id": "a1", "text": "likes tea", "mode": "building", "by": "you", "at": 1}]}"#, config.appending(path: "memory.json"))
            write(#"{"dismissed": ["a+b"]}"#, config.appending(path: "suggestions.json"))
            write(#"{"t": 1, "app": "com.apple.Safari", "mode": "dock", "ws": 1}"# + "\n", support.appending(path: "activity.jsonl"))
            write(#"{"app:com.apple.Music": "writing"}"#, support.appending(path: "sorted.json"))
            write(#"{"replies": []}"#, support.appending(path: "writing-style.json"))
            write(#"{"aiSpend": {"claude": 1.5}, "stacksSeen": {"~/Downloads": 2}, "summaryWeek": "2026-W45", "suggestionShown": "2026-11-09"}"#, support.appending(path: "state.json"))
            write("[]", support.appending(path: "ai-history.json"))

            let outcome = ModesMigration.run(config: config, support: support)
            expect(outcome == .moved(4), "the default mode's apps moved over", "\(outcome)")
            let dock = object(config.appending(path: "dock.json")) ?? [:]
            expect(dock["apps"] as? [String] == dockApps, "the default mode's apps, in order, trimmed, each once", "\(dock["apps"] ?? "nil")")
            expect(dock["position"] as? String == "left" && dock["autoHide"] as? Bool == true && dock["welcomed"] as? Bool == true
                   && dock["dock"] as? String == "petal" && dock.count == 5, "the dock's other choices stay as they were", "\(dock)")
            expect(!FileManager.default.fileExists(atPath: config.appending(path: "modes.json").path), "modes.json is gone")
            let settings = object(config.appending(path: "settings.json")) ?? [:]
            expect(Set(settings.keys) == ["iconSize", "tiling", "aiMemory", "mine"] && settings["iconSize"] as? Int == 44,
                   "settings that only meant something with modes, and the looks nothing reads, are gone; the rest (the person's own keys too) stay", "\(settings.keys.sorted())")
            let state = object(support.appending(path: "state.json")) ?? [:]
            expect(Set(state.keys) == ["aiSpend", "stacksSeen"], "state.json keeps what's still used", "\(state.keys.sorted())")
            // No other file written (no backup, no copy of the modes), and what only the removed features read is gone.
            expect(names(config) == ["dock.json", "instructions.md", "memory.json", "settings.json"], "the config folder holds nothing new", "\(names(config))")
            expect(names(support) == ["ai-history.json", "state.json"], "the support folder holds nothing new", "\(names(support))")
            expect((try? String(contentsOf: config.appending(path: "instructions.md"), encoding: .utf8)) == "keep me\n", "the person's notes for the AI are untouched")

            // 2. A second launch changes nothing: not a byte, not a date.
            let before = Self.state([config, support])
            Thread.sleep(forTimeInterval: 0.02)
            let again = ModesMigration.run(config: config, support: support)
            expect(again == .nothing && Self.state([config, support]) == before, "a second launch writes nothing", "\(again)")
        }

        // 3. A default that names no mode: the first mode's apps. No dock.json yet: one is made.
        folders { config, support in
            write(#"{"defaultMode": "gone", "modes": [{"id": "a", "apps": ["one.app", "two.app"]}, {"id": "b", "apps": ["three.app"]}]}"#, config.appending(path: "modes.json"))
            expect(ModesMigration.run(config: config, support: support) == .moved(2), "no such default: the first mode")
            expect(object(config.appending(path: "dock.json"))?["apps"] as? [String] == ["one.app", "two.app"] && names(config) == ["dock.json"],
                   "its apps, in a new dock.json, and nothing else", "\(names(config))")
        }

        // 4. An unreadable modes.json: an empty dock (no apps), nothing written, the file left as it is.
        for broken in ["{ not json", "[1, 2]", #"{"defaultMode": "dock"}"#] {
            folders { config, support in
                write(broken, config.appending(path: "modes.json"))
                write(#"{"position": "bottom"}"#, config.appending(path: "dock.json"))
                let before = Self.state([config, support])
                let outcome = ModesMigration.run(config: config, support: support)
                expect(outcome == .unreadable, "unreadable modes: said so", "\(broken): \(outcome)")
                expect(object(config.appending(path: "dock.json"))?["apps"] == nil, "the dock has no apps")
                expect(Self.state([config, support]) == before, "and nothing was written or removed", "\(names(config))")
            }
        }

        // 5. A dock.json that can't be read is never written over; modes.json waits.
        folders { config, support in
            write(modes, config.appending(path: "modes.json"))
            write("{ half", config.appending(path: "dock.json"))
            let before = Self.state([config, support])
            expect(ModesMigration.run(config: config, support: support) == .unreadable && Self.state([config, support]) == before, "a broken dock.json: nothing touched")
        }

        // 6. Stopped after the dock was written and before modes.json went (or a dock made since): the dock stands.
        folders { config, support in
            write(modes, config.appending(path: "modes.json"))
            write(#"{"apps": ["mine.app"], "position": "right"}"#, config.appending(path: "dock.json"))
            let dockBefore = try? Data(contentsOf: config.appending(path: "dock.json"))
            expect(ModesMigration.run(config: config, support: support) == .moved(1), "a dock already there stands")
            expect((try? Data(contentsOf: config.appending(path: "dock.json"))) == dockBefore && names(config) == ["dock.json"],
                   "it isn't rewritten, and modes.json goes", "\(names(config))")
        }

        // 7. A new install: nothing to move, nothing written.
        folders { config, support in
            expect(ModesMigration.run(config: config, support: support) == .nothing && names(config).isEmpty && names(support).isEmpty, "a new install: nothing written")
        }

        // 8. A default mode with no apps: an empty dock, and modes.json still goes.
        folders { config, support in
            write(#"{"defaultMode": "a", "modes": [{"id": "a"}]}"#, config.appending(path: "modes.json"))
            expect(ModesMigration.run(config: config, support: support) == .moved(0), "no apps: an empty dock")
            expect(object(config.appending(path: "dock.json"))?["apps"] as? [String] == [] && names(config) == ["dock.json"], "dock.json says so, modes.json is gone")
        }

        print(failures == 0 ? "ok: \(passed) checks" : "\(failures) of \(passed + failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
