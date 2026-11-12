import Foundation

// Checks ConfigRules.swift: dock.json's apps and a file read again while someone edits it. Run with macos/checks/run.sh.
@main
struct ConfigRulesCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static func main() {
        // The apps, read from JSON as Petal reads dock.json.
        func apps(_ json: String) -> [String] {
            let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            return ConfigRules.apps(root["apps"])
        }
        expect(apps(#"{"apps": ["com.apple.Safari", "https://example.com"]}"#) == ["com.apple.Safari", "https://example.com"], "the apps, in order")
        expect(apps(#"{"apps": ["com.apple.Safari", null, 3, {"x": 1}, "com.apple.mail"]}"#) == ["com.apple.Safari", "com.apple.mail"],
               "an entry that isn't text is passed over, the rest kept")
        expect(apps(#"{"apps": [" com.apple.Safari ", "", "  "]}"#) == ["com.apple.Safari"], "trimmed, and empty ones left out")
        expect(apps(#"{"apps": "com.apple.Safari"}"#).isEmpty && apps(#"{}"#).isEmpty, "no list, no apps")
        // Adding an app after a stray entry keeps every app that was there (as Config.addApp writes the list back).
        var list = apps(#"{"apps": ["com.apple.Safari", null, "com.apple.mail"]}"#)
        list.append("com.apple.Notes")
        expect(list == ["com.apple.Safari", "com.apple.mail", "com.apple.Notes"], "a change after a stray entry keeps the dock")

        // A file read again.
        let before: [String: Any] = ["apps": ["com.apple.Safari"]]
        let fine = ConfigRules.reread(["apps": ["com.apple.mail"]], exists: true, before: before)
        expect(ConfigRules.apps(fine["apps"]) == ["com.apple.mail"], "a file that reads is what it says")
        let halfway = ConfigRules.reread(nil, exists: true, before: before)
        expect(ConfigRules.apps(halfway["apps"]) == ["com.apple.Safari"], "a file there that doesn't read keeps what was read before")
        expect(ConfigRules.reread(nil, exists: false, before: before).isEmpty, "a file that's gone is empty (the defaults)")

        print("config rules: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
