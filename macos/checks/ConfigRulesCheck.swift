import Foundation

// Checks ConfigRules.swift: dock.json's apps, a file read again while someone edits it, and the settings that let
// Petal AI do more growing only in Petal itself. Run with macos/checks/run.sh.
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

        // What Petal AI may do grows only in Petal itself: settings.json read again while Petal runs.
        let defaults: [String: Any] = ["claudeAccess": "auto", "computerUse": true, "aiAllowed": [String](),
                                       "aiNeverLook": ["com.1password.1password", "com.apple.Passwords"], "magnify": true]
        func taken(_ disk: [String: Any], over memory: [String: Any]) -> (settings: [String: Any], refused: [String]) {
            ConfigRules.taken(disk, over: memory, defaults: defaults)
        }
        func strings(_ settings: [String: Any], _ key: String) -> [String] { settings[key] as? [String] ?? defaults[key] as? [String] ?? [] }
        expect(ConfigRules.personsOwn.sorted() == ["aiAllowed", "aiNeverLook", "claudeAccess", "computerUse"], "the four settings that are the person's own")

        // Full access.
        var answer = taken(["claudeAccess": "full", "magnify": false], over: ["claudeAccess": "auto"])
        expect(answer.settings["claudeAccess"] as? String == "auto" && answer.refused == ["claudeAccess"], "Full access turned on in the file isn't taken", "\(answer)")
        expect(answer.settings["magnify"] as? Bool == false, "the rest of the file is taken with it")
        answer = taken(["claudeAccess": "full"], over: [:])
        expect(answer.settings["claudeAccess"] == nil && answer.refused == ["claudeAccess"], "nor when Petal had none set: it stays unset (auto)", "\(answer)")
        answer = taken(["claudeAccess": "auto"], over: ["claudeAccess": "full"])
        expect(answer.settings["claudeAccess"] as? String == "auto" && answer.refused.isEmpty, "Full access turned off in the file is taken")
        answer = taken([:], over: ["claudeAccess": "full"])
        expect(answer.settings["claudeAccess"] == nil && answer.refused.isEmpty, "and so is the key taken out (auto)")
        answer = taken(["claudeAccess": "full"], over: ["claudeAccess": "full"])
        expect(answer.settings["claudeAccess"] as? String == "full" && answer.refused.isEmpty, "Full access the person turned on stays on")

        // Using the person's apps (on unless turned off).
        answer = taken(["computerUse": true], over: ["computerUse": false])
        expect(answer.settings["computerUse"] as? Bool == false && answer.refused == ["computerUse"], "using apps turned on in the file isn't taken", "\(answer)")
        answer = taken([:], over: ["computerUse": false])
        expect(answer.settings["computerUse"] as? Bool == false && answer.refused == ["computerUse"], "nor by taking the key out (its default is on)", "\(answer)")
        answer = taken(["computerUse": "yes"], over: ["computerUse": false])
        expect(answer.settings["computerUse"] as? Bool == false && answer.refused == ["computerUse"], "nor by a value that isn't yes or no (read as its default)", "\(answer)")
        answer = taken(["computerUse": false], over: ["computerUse": true])
        expect(answer.settings["computerUse"] as? Bool == false && answer.refused.isEmpty, "using apps turned off in the file is taken")
        answer = taken(["computerUse": true], over: [:])
        expect(answer.settings["computerUse"] as? Bool == true && answer.refused.isEmpty, "on in the file while it's on changes nothing")

        // What's allowed without asking.
        answer = taken(["aiAllowed": ["quit", "computer:com.apple.Safari"]], over: ["aiAllowed": ["quit"]])
        expect(strings(answer.settings, "aiAllowed") == ["quit"] && answer.refused == ["aiAllowed"], "a kind added in the file isn't allowed", "\(answer)")
        answer = taken(["aiAllowed": ["browser"]], over: [:])
        expect(strings(answer.settings, "aiAllowed").isEmpty && answer.refused == ["aiAllowed"], "nor when nothing was allowed", "\(answer)")
        answer = taken(["aiAllowed": ["trash", "browser"]], over: ["aiAllowed": ["quit", "trash"]])
        expect(strings(answer.settings, "aiAllowed") == ["trash"] && answer.refused == ["aiAllowed"], "one taken away and one added: the first is taken, the second isn't", "\(answer)")
        answer = taken(["aiAllowed": ["trash"]], over: ["aiAllowed": ["quit", "trash"]])
        expect(strings(answer.settings, "aiAllowed") == ["trash"] && answer.refused.isEmpty, "a kind taken away in the file is taken")
        answer = taken([:], over: ["aiAllowed": ["quit"]])
        expect(strings(answer.settings, "aiAllowed").isEmpty && answer.refused.isEmpty, "and so is the whole list taken out")

        // The apps kept private (a list of its own by default).
        answer = taken(["aiNeverLook": ["com.apple.Passwords"]], over: [:])
        expect(strings(answer.settings, "aiNeverLook") == ["com.apple.Passwords", "com.1password.1password"] && answer.refused == ["aiNeverLook"],
               "an app taken off the private list in the file is put back", "\(answer)")
        answer = taken(["aiNeverLook": [String]()], over: ["aiNeverLook": ["com.example.bank"]])
        expect(strings(answer.settings, "aiNeverLook") == ["com.example.bank"] && answer.refused == ["aiNeverLook"], "an emptied list keeps every app", "\(answer)")
        answer = taken([:], over: ["aiNeverLook": ["com.1password.1password", "com.apple.Passwords", "com.example.bank"]])
        expect(strings(answer.settings, "aiNeverLook") == ["com.1password.1password", "com.apple.Passwords", "com.example.bank"] && answer.refused == ["aiNeverLook"],
               "the key taken out keeps the apps the person added", "\(answer)")
        answer = taken(["aiNeverLook": ["com.apple.Passwords", "com.1password.1password", "com.example.bank"]], over: [:])
        expect(strings(answer.settings, "aiNeverLook") == ["com.apple.Passwords", "com.1password.1password", "com.example.bank"] && answer.refused.isEmpty,
               "an app added to the private list in the file is taken")
        answer = taken(["aiNeverLook": ["com.example.bank"]], over: ["aiNeverLook": ["com.apple.Passwords"]])
        expect(strings(answer.settings, "aiNeverLook") == ["com.example.bank", "com.apple.Passwords"] && answer.refused == ["aiNeverLook"],
               "one added and one taken off: both end up on the list", "\(answer)")

        // Several at once, and a file that asks for nothing more.
        answer = taken(["claudeAccess": "full", "computerUse": true, "aiAllowed": ["quit"], "aiNeverLook": [String](), "accentColor": "#112233"],
                       over: ["computerUse": false])
        expect(answer.refused == ConfigRules.personsOwn && answer.settings["accentColor"] as? String == "#112233", "all four at once are all refused", "\(answer)")
        let same: [String: Any] = ["claudeAccess": "full", "computerUse": false, "aiAllowed": ["quit"], "aiNeverLook": ["com.example.bank"], "magnify": false]
        answer = taken(same, over: same)
        expect(answer.refused.isEmpty && (answer.settings as NSDictionary).isEqual(same as NSDictionary), "a file that says what Petal has is taken whole")

        // Swept: settings.json read again with every mix of the four, including values of the wrong type, as Config
        // reads them (a value that isn't the setting's type is its default). Whatever the file says, Petal AI may do
        // no more than both the file and Petal allow, every other key is taken as it is, and writing the answer back
        // settles at once: read again, it's taken whole.
        var random = SystemRandomNumberGenerator()
        let accessValues: [Any?] = [nil, "full", "auto", "FULL", 3, true]
        let boolValues: [Any?] = [nil, true, false, "yes", 1, 0]
        let kinds = ["quit", "close", "trash", "browser", "computer:com.apple.Safari"]
        let apps = ["com.1password.1password", "com.apple.Passwords", "com.example.bank", "com.example.mail"]
        func someList(_ from: [String]) -> Any? {
            switch Int.random(in: 0...5, using: &random) {
            case 0: return nil
            case 1: return "quit"
            case 2: return [from.randomElement(using: &random)!, 3] as [Any]
            default: return (0..<Int.random(in: 0...4, using: &random)).map { _ in from.randomElement(using: &random)! }
            }
        }
        func file() -> [String: Any] {
            var out: [String: Any] = ["accentColor": "#\(Int.random(in: 100000...999999, using: &random))"]
            out["claudeAccess"] = accessValues.randomElement(using: &random)!
            out["computerUse"] = boolValues.randomElement(using: &random)!
            out["aiAllowed"] = someList(kinds)
            out["aiNeverLook"] = someList(apps)
            return out
        }
        func full(_ s: [String: Any]) -> Bool { (s["claudeAccess"] as? String ?? defaults["claudeAccess"] as? String) == "full" }
        func uses(_ s: [String: Any]) -> Bool { s["computerUse"] as? Bool ?? defaults["computerUse"] as? Bool ?? false }
        var cases = 0
        for _ in 0..<20000 {
            let disk = file(), memory = file()
            let (read, refused) = taken(disk, over: memory)
            let what = "disk \(disk) memory \(memory) -> \(read) refused \(refused)"
            cases += 1
            expect(full(read) == (full(disk) && full(memory)), "Full access only when both say so", what)
            expect(uses(read) == (uses(disk) && uses(memory)), "using apps only when both say so", what)
            expect(Set(strings(read, "aiAllowed")) == Set(strings(disk, "aiAllowed")).intersection(strings(memory, "aiAllowed")),
                   "allowed without asking: only what both allow", what)
            expect(Set(strings(read, "aiNeverLook")) == Set(strings(disk, "aiNeverLook")).union(strings(memory, "aiNeverLook")),
                   "kept private: what either keeps private", what)
            expect(read["accentColor"] as? String == disk["accentColor"] as? String, "every other key is taken as it is", what)
            expect(refused.allSatisfy(ConfigRules.personsOwn.contains) && Set(refused).count == refused.count, "only the four are ever refused, each once", what)
            let again = taken(read, over: memory)
            expect(again.refused.isEmpty, "the file written back is taken whole when it's read again", "\(what) then \(again)")
            if failures > 20 { break }
        }
        expect(cases > 0, "the sweep ran")

        // Numbers: whatever the file holds, a number Petal can round to a whole one.
        let wild: [Any?] = [nil, 1e300, -1e300, 9.3e18, -9.3e18, 1e19, 72, 0.5, -1, true, false, "48", [1], NSNull()]
        for value in wild {
            for fallback in [36.0, -1.0, 0.45] {
                let n = ConfigRules.number(value, default: fallback)
                expect(n.isFinite && abs(n) <= ConfigRules.numberBound && Int(exactly: n.rounded()) != nil,
                       "a number setting is always one Petal can round", "\(String(describing: value)) -> \(n)")
            }
        }
        expect(ConfigRules.number(72, default: 36) == 72 && ConfigRules.number("48", default: 36) == 36
               && ConfigRules.number(nil, default: -1) == -1 && ConfigRules.number(true, default: 0) == 1, "a number in range is itself; anything else is the default")
        expect(ConfigRules.number(1e300, default: 36) == ConfigRules.numberBound && ConfigRules.number(-1e19, default: 36) == -ConfigRules.numberBound,
               "one past the bound is the bound")

        print("config rules: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
