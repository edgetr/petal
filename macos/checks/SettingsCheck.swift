import Foundation

/// The settings list (Settings.swift) and the AI's tools (Resources/mcp/tools.json) are well formed, and the sources
/// agree with them. It runs the real list, and reads the tools' file and the sources as text; nothing of Petal runs.
///
///     SettingsCheck <macos/Resources/mcp/tools.json> <macos/Sources/Petal>
@main
struct SettingsCheck {
    static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        if !condition {
            failures += 1
            print("FAILED: \(what)")
        }
    }

    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            print("usage: SettingsCheck <tools.json> <Sources/Petal>")
            exit(2)
        }
        settings()
        let names = tools(URL(fileURLWithPath: arguments[1]))
        sources(URL(fileURLWithPath: arguments[2]), tools: names)
        if failures > 0 { exit(1) }
        print("Settings and tools: \(Settings.all.count) settings (\(Settings.forTools.count) for the AI's tools), \(names.count) tools, and the sources agree")
    }

    // MARK: The settings list

    static func kind(_ fallback: Setting.Default) -> String {
        switch fallback {
        case .bool: return "bool"
        case .number: return "number"
        case .string: return "string"
        case .list: return "list"
        }
    }

    static func settings() {
        var seen = Set<String>()
        for setting in Settings.all {
            let key = setting.key
            expect(seen.insert(key).inserted, "setting \(key) is listed twice")
            let plain = key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
            expect(!key.isEmpty && plain && key.first?.isLowercase == true, "setting \(key) isn't a plain lowerCamelCase key")
            let help = setting.help.trimmingCharacters(in: .whitespacesAndNewlines)
            expect(help.count >= 10 && help == setting.help, "setting \(key) has no help, or help with space around it")
            // The default is of the setting's type, as JSON keeps it: what settings.json would hold.
            let value = setting.fallback.value
            let json = try? JSONSerialization.data(withJSONObject: [value])
            let back = json.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }?.first
            switch setting.fallback {
            case .bool(let wanted):
                expect((back as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue == wanted } == true, "setting \(key)'s default isn't a true or false")
            case .number(let wanted):
                expect(wanted.isFinite, "setting \(key)'s default isn't a number")
                expect((back as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == wanted } == true, "setting \(key)'s default isn't kept as a number")
            case .string(let wanted):
                expect(back as? String == wanted, "setting \(key)'s default isn't kept as text")
            case .list(let wanted):
                expect(back as? [String] == wanted, "setting \(key)'s default isn't kept as a list of text")
            }
            expect(Settings.named(key)?.key == key, "setting \(key) can't be found by its key")
            let fromDefaults = Settings.defaults[key]
            expect(fromDefaults != nil, "setting \(key) has no default in Settings.defaults")
        }
        expect(Settings.defaults.count == Settings.all.count, "Settings.defaults doesn't hold every setting once")
        expect(!Settings.forTools.isEmpty && Settings.forTools.allSatisfy { $0.forTools }, "the tools' settings are the ones marked for them")
    }

    // MARK: The tools' file

    /// The tools' names, in the file's order.
    static func tools(_ file: URL) -> [String] {
        guard let data = try? Data(contentsOf: file), let parsed = try? JSONSerialization.jsonObject(with: data) else {
            expect(false, "\(file.lastPathComponent) isn't valid JSON")
            return []
        }
        guard let list = parsed as? [[String: Any]], !list.isEmpty else {
            expect(false, "\(file.lastPathComponent) isn't a list of tools")
            return []
        }
        var names: [String] = []
        for tool in list {
            let name = tool["name"] as? String ?? ""
            let plain = name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
            expect(name.hasPrefix("petal_") && plain, "a tool's name isn't petal_ and lowercase words: “\(name)”")
            expect(!names.contains(name), "tool \(name) is listed twice")
            names.append(name)
            expect(Set(tool.keys) == ["name", "description", "inputSchema"], "tool \(name) has keys other than name, description and inputSchema")
            let description = tool["description"] as? String ?? ""
            expect(description.count >= 20 && description == description.trimmingCharacters(in: .whitespacesAndNewlines), "tool \(name) has no description, or one with space around it")
            guard let schema = tool["inputSchema"] as? [String: Any] else {
                expect(false, "tool \(name) has no input schema")
                continue
            }
            expect(schema["type"] as? String == "object", "tool \(name)'s input isn't an object")
            guard let properties = schema["properties"] as? [String: Any] else {
                expect(false, "tool \(name)'s input schema has no properties")
                continue
            }
            for (property, value) in properties {
                let shape = value as? [String: Any]
                expect(shape?["type"] is String, "tool \(name)'s \(property) has no type")
            }
            if let required = schema["required"] {
                let wanted = required as? [String]
                expect(wanted != nil && wanted?.allSatisfy { properties[$0] != nil } == true, "tool \(name) requires something its schema doesn't describe")
            }
        }
        return names
    }

    // MARK: The sources

    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: whole).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    /// Every setting the sources read or change by name is in the list, and read as the type it is; every tool the
    /// file lists is one MCP.swift does, and the other way round.
    static func sources(_ folder: URL, tools: [String]) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "swift" }
        expect(files.count > 50, "the sources weren't found in \(folder.path)")
        let readers = ["bool": "bool", "number": "number", "string": "string", "strings": "list"]
        let controls = ["SettingToggle": "bool", "SettingSlider": "number", "ColorSetting": "string"]
        var read = Set<String>()
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let name = file.lastPathComponent
            for found in matches(#"config\.(bool|number|string|strings|set)\("([A-Za-z0-9]+)""#, in: text) {
                let key = found[2]
                guard let setting = Settings.named(key) else {
                    expect(false, "\(name) uses the setting \(key), which isn't in Settings")
                    continue
                }
                read.insert(key)
                if let wanted = readers[found[1]] {
                    expect(kind(setting.fallback) == wanted, "\(name) reads \(key) as a \(wanted), and it's a \(kind(setting.fallback))")
                }
            }
            for found in matches(#"(SettingToggle|SettingSlider|ColorSetting)\(key: "([A-Za-z0-9]+)""#, in: text) {
                let key = found[2]
                guard let setting = Settings.named(key) else {
                    expect(false, "\(name) shows the setting \(key), which isn't in Settings")
                    continue
                }
                expect(kind(setting.fallback) == controls[found[1]], "\(name) shows \(key) with a \(found[1]), and it's a \(kind(setting.fallback))")
            }
            if name == "MCP.swift" {
                // The tools MCP.swift does: every "petal_…" it names.
                let done = Set(matches(#""(petal_[a-z_]+)""#, in: text).map { $0[1] })
                for tool in tools { expect(done.contains(tool), "tools.json lists \(tool), which MCP.swift doesn't do") }
                for tool in done.sorted() { expect(tools.contains(tool), "MCP.swift does \(tool), which tools.json doesn't list") }
            }
        }
        expect(read.count > 30, "the sources' reads of settings weren't found")
    }
}
