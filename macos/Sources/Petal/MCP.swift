import Foundation

/// Claude's Petal tools on macOS: `Petal --mcp` speaks the Model Context Protocol on stdin and stdout, so a Mac
/// needs nothing installed for them (petal-mcp.py would need python3, which a Mac only has with Apple's developer
/// tools). The tools' names, descriptions, settings and mode fields come from petal-mcp.py, written into the app
/// by build.sh as Resources/mcp/tools.json, so both platforms describe them the same way; what each tool does on a
/// Mac is here, as in petal-mcp.py's macOS branch.
enum MCP {
    static let folder = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".config/petal")
    static let settingsFile = folder.appending(path: "settings.json")
    static let modesFile = folder.appending(path: "modes.json")
    static let dockFile = folder.appending(path: "dock.json")
    static let socket = folder.appending(path: "petal.sock").path

    static let description: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "tools", withExtension: "json", subdirectory: "mcp"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }()
    static var schema: [String: [Any]] { description["settings"] as? [String: [Any]] ?? [:] }

    static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = message["id"] else { continue }   // notifications need no answer
            var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
            if let result = handle(message) {
                reply["result"] = result
            } else {
                reply["error"] = ["code": -32601, "message": "Method not found"]
            }
            if let data = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) {
                FileHandle.standardOutput.write(data + Data("\n".utf8))
            }
        }
        exit(0)
    }

    static func handle(_ message: [String: Any]) -> [String: Any]? {
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "initialize":
            return ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18", "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "petal", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? ""],
                    "instructions": "Tools to customize the Petal dock. Call petal_get_state first."]
        case "tools/list":
            return ["tools": description["tools"] ?? []]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let result = try call(name, arguments)
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
            } catch {
                return ["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true]
            }
        case "ping":
            return [:]
        default:
            return nil
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    static func call(_ name: String, _ args: [String: Any]) throws -> Any {
        switch name {
        case "petal_get_state":
            let settings = read(settingsFile) ?? [:]
            var effective: [String: Any] = [:]
            var help: [String: Any] = [:]
            for (key, entry) in schema {
                effective[key] = settings[key] ?? entry.first ?? NSNull()
                help[key] = entry.count > 1 ? entry[1] : ""
            }
            let dock = read(dockFile) ?? [:]
            let environment = ProcessInfo.processInfo.environment
            return ["settings": effective, "settings_help": help, "modes": read(modesFile) ?? [:],
                    "mode_fields": description["mode_fields"] ?? [:], "current_mode": petal("current"),
                    "dock": ["position": dock["position"] ?? "bottom", "autohide": dock["autoHide"] ?? false, "dock": dock["dock"] ?? "petal"],
                    "files": ["settings": settingsFile.path, "modes": modesFile.path,
                              "instructions": folder.appending(path: "instructions.md").path,
                              "plugin_source": Personal.sourceForAgents ?? environment["PETAL_SOURCE"] ?? "",
                              "app": environment["PETAL_APP"] ?? Bundle.main.bundlePath],
                    "personal": ["source": Personal.source.path, "set_up": Personal.exists, "how": Personal.how]]
        case "petal_set_settings":
            let changes = args["settings"] as? [String: Any] ?? [:]
            let unknown = changes.keys.filter { schema[$0] == nil }.sorted()
            guard unknown.isEmpty else { throw Failure("Unknown settings: \(unknown.joined(separator: ", ")). Use petal_get_state to see them all.") }
            try update(settingsFile) { $0.merge(changes) { _, new in new } }
            return ["ok": true, "changed": changes]
        case "petal_reset_settings":
            let keys = args["keys"] as? [String] ?? []
            try update(settingsFile) { settings in
                for key in keys.isEmpty ? Array(schema.keys) : keys where key != "claudePath" {
                    if let entry = schema[key] { settings[key] = entry.first }
                }
            }
            return ["ok": true, "reset": keys.isEmpty ? "all" as Any : keys as Any]
        case "petal_set_dock":
            var done: [String: Any] = [:]
            if let position = args["position"] as? String, !["bottom", "left", "right"].contains(position) {
                throw Failure("position must be bottom, left or right (the menu bar holds the top)")
            }
            try update(dockFile) { dock in
                if let position = args["position"] as? String { dock["position"] = position; done["position"] = position }
                if let hide = args["autohide"] as? Bool { dock["autoHide"] = hide; done["autohide"] = hide }
            }
            if let use = args["use"] as? String {
                guard ["petal", "macos"].contains(use) else { throw Failure("use must be petal or macos") }
                done["use"] = petal("dock", use)
            }
            return done
        case "petal_save_mode":
            guard let mode = args["mode"] as? [String: Any], let id = mode["id"] as? String, !id.isEmpty else {
                throw Failure("mode.id is required")
            }
            var saved: [String: Any] = [:]
            try update(modesFile, fallback: ["defaultMode": id, "workspaces": [:], "modes": []]) { data in
                var modes = data["modes"] as? [[String: Any]] ?? []
                if let index = modes.firstIndex(where: { $0["id"] as? String == id }) {
                    modes[index].merge(mode) { _, new in new }
                    saved = modes[index]
                } else {
                    var new: [String: Any] = ["name": id.capitalized, "icon": "circle.fill", "color": "#ff5fae", "about": "",
                                              "apps": [], "sites": [], "focusDelay": 0, "hold": false, "allow": []]
                    new.merge(mode) { _, new in new }
                    modes.append(new)
                    saved = new
                }
                data["modes"] = modes
                if data["workspaces"] == nil { data["workspaces"] = [String: Any]() }
                if (data["defaultMode"] as? String ?? "").isEmpty { data["defaultMode"] = id }
            }
            return ["ok": true, "mode": saved]
        case "petal_delete_mode":
            let id = args["id"] as? String ?? ""
            try update(modesFile) { data in
                let all = data["modes"] as? [[String: Any]] ?? []
                let kept = all.filter { $0["id"] as? String != id }
                guard kept.count < all.count else { throw Failure("No mode with id \"\(id)\"") }
                guard !kept.isEmpty else { throw Failure("Petal needs at least one mode") }
                data["modes"] = kept
                data["workspaces"] = (data["workspaces"] as? [String: Any] ?? [:]).filter { $0.value as? String != id }
                if data["defaultMode"] as? String == id { data["defaultMode"] = kept[0]["id"] }
            }
            return ["ok": true]
        case "petal_set_default_mode":
            let id = args["id"] as? String ?? ""
            try update(modesFile) { data in
                guard (data["modes"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == id }) else {
                    throw Failure("No mode with id \"\(id)\"")
                }
                data["defaultMode"] = id
            }
            return ["ok": true]
        case "petal_switch_mode":
            return ["result": petal("mode", args["id"] as? String ?? "")]
        case "petal_list_apps":
            return apps(matching: args["query"] as? String ?? "")
        case "petal_reload":
            return ["ok": true, "note": petal("restart") + "; the Claude panel closes."]
        default:
            throw Failure("Unknown tool")
        }
    }

    // MARK: Files

    static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Changes a file in place. A file that's there but isn't valid JSON is left alone, with an error for Claude.
    static func update(_ url: URL, fallback: [String: Any] = [:], _ change: (inout [String: Any]) throws -> Void) throws {
        var object: [String: Any]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let parsed = read(url) else { throw Failure("\(url.lastPathComponent) isn't valid JSON; fix it first") }
            object = parsed
        } else {
            object = fallback
        }
        try change(&object)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    // MARK: The running Petal

    /// Asks the running Petal over its socket, as petal-mcp.py does.
    static func petal(_ args: String...) -> String { petal(args) }

    static func petal(_ args: [String]) -> String {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "Petal isn't running" }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socket.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in for (i, b) in bytes.prefix(buffer.count - 1).enumerated() { buffer[i] = b } }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, let request = try? JSONSerialization.data(withJSONObject: args) else { return "Petal isn't running" }
        let out = Array(request + Data("\n".utf8))
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            reply.append(buffer, count: count)
            if reply.last == 0x0A { break }
        }
        return String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Installed apps by bundle id and name, filtered by a word in either.
    static func apps(matching query: String) -> [[String: String]] {
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var found: [[String: String]] = []
        for root in roots {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            var paths = names.filter { $0.hasSuffix(".app") }.map { root + "/" + $0 }
            for folder in names where !folder.hasSuffix(".app") {
                paths += ((try? FileManager.default.contentsOfDirectory(atPath: root + "/" + folder)) ?? [])
                    .filter { $0.hasSuffix(".app") }.map { root + "/" + folder + "/" + $0 }
            }
            for path in paths {
                guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier, !seen.contains(id) else { continue }
                seen.insert(id)
                let name = bundle.infoDictionary?["CFBundleDisplayName"] as? String ?? bundle.infoDictionary?["CFBundleName"] as? String
                    ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
                if !query.isEmpty && !"\(id) \(name)".localizedCaseInsensitiveContains(query) { continue }
                found.append(["id": id, "name": name])
            }
        }
        return found.sorted { $0["name"]!.localizedCaseInsensitiveCompare($1["name"]!) == .orderedAscending }
    }
}
