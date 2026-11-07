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
    /// The running Petal's socket (`PETAL_SOCKET` points a client at another, for testing).
    static let socket = ProcessInfo.processInfo.environment["PETAL_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? folder.appending(path: "petal.sock").path

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

    /// Inside the running Petal (set at its start): settings, modes and dock changes go through its Config.
    nonisolated(unsafe) static var inPetal = false

    /// The tools that change settings.json, modes.json or dock.json.
    static let writeTools: Set<String> = ["petal_set_settings", "petal_reset_settings", "petal_set_dock", "petal_save_mode",
                                          "petal_delete_mode", "petal_set_default_mode", "petal_import_recipe"]

    static func call(_ name: String, _ args: [String: Any]) throws -> Any {
        // While Petal runs, a change is made by Petal itself, in order with every other change (two notes changing
        // settings at once never undo each other); only without it is the file changed here, under a lock.
        if !inPetal, writeTools.contains(name), let done = try viaPetal(name, args) { return done }
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
            // What Petal AI may do unasked, and what it may look at, are the person's to widen, never the AI's.
            let current = read(settingsFile) ?? [:]
            if let allowed = changes["aiAllowed"] as? [String] {
                let had = Set(current["aiAllowed"] as? [String] ?? [])
                if !Set(allowed).isSubset(of: had) { throw Failure("Only the person can allow more, with Always on Petal's card or in its settings.") }
            }
            if changes["claudeAccess"] as? String == "full", current["claudeAccess"] as? String != "full" {
                throw Failure("Only the person can turn on Full access, in the chat's options or Petal's settings.")
            }
            // Using the person's apps: the AI may turn it off, never back on.
            if let use = changes["computerUse"], (use as? Bool) != false, !computerUseOn(current) {
                throw Failure("Only the person can turn on using apps (computerUse), in Petal's settings.")
            }
            if changes.keys.contains("aiNeverLook"), !(changes["aiNeverLook"] is [String]) {
                throw Failure("aiNeverLook is a list of app ids.")
            }
            if changes.keys.contains("aiAllowed"), !(changes["aiAllowed"] is [String]) { throw Failure("aiAllowed is a list.") }
            if let hidden = changes["aiNeverLook"] as? [String] {
                let had = Set(current["aiNeverLook"] as? [String] ?? (schema["aiNeverLook"]?.first as? [String] ?? []))
                if !had.isSubset(of: Set(hidden)) { throw Failure("Only the person can take an app off the private list, in Petal's settings.") }
            }
            try update(settingsFile) { $0.merge(changes) { _, new in new } }
            return ["ok": true, "changed": changes]
        case "petal_reset_settings":
            let asked = args["keys"] as? [String] ?? []
            // Never the private list, which only the person shortens, nor using apps once it's off, which only they
            // turn back on.
            try update(settingsFile) { settings in
                let off = !computerUseOn(settings)
                for key in asked.isEmpty ? Array(schema.keys) : asked where key != "claudePath" && key != "aiNeverLook" && !(off && key == "computerUse") {
                    if let entry = schema[key] { settings[key] = entry.first }
                }
            }
            return ["ok": true, "reset": asked.isEmpty ? "all" as Any : asked as Any]
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
                if inPetal, Thread.isMainThread {
                    MainActor.assumeIsolated { PetalApp.shared.useDock(use) }
                    done["use"] = "ok"
                } else {
                    done["use"] = petal("dock", use)
                }
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
                                              "apps": [], "sites": [], "focusDelay": 0, "distracting": false, "hold": false, "allow": []]
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
        case "petal_export_recipe":
            return ["path": try Recipe.export(path: args["path"] as? String, name: args["name"] as? String)]
        case "petal_import_recipe":
            let plan = try importPlan(args)
            return try Recipe.apply(plan, look: args["look"] as? Bool ?? false)
        case "petal_suggestions":
            guard Insights.setting("activityLog") else { return ["suggestions": [], "note": "The activity history is off (activityLog)."] }
            return ["suggestions": Insights.suggestions().map(\.json)]
        case "petal_summary":
            guard Insights.setting("activityLog") else { return ["note": "The activity history is off (activityLog)."] }
            // The last `days` (up to the 30 the history keeps), or from/to (YYYY-MM-DD); the last 7 days by default.
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd"
            let days = min(30, max(1, (args["days"] as? NSNumber)?.intValue ?? 7))
            let to = (args["to"] as? String).flatMap(format.date).map { $0.addingTimeInterval(86400) } ?? Date()
            let from = (args["from"] as? String).flatMap(format.date) ?? to.addingTimeInterval(-Double(days) * 86400)
            var json = Insights.summary(from: from, to: to, title: "From \(format.string(from: from))").json
            json["byDay"] = Insights.byDay(from: from, to: to)
            return json
        case "petal_look", "petal_apps", "petal_windows", "petal_trash", "petal_remember", "petal_forget", "petal_memories", "petal_show", "petal_vault", "petal_ui", "petal_act",
             "petal_routines", "petal_routine_save", "petal_routine_run", "petal_routine_undo", "petal_routine_delete":
            // Petal itself does these, with its own permissions (and asks the person first where it should).
            let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            // Which chat asks: a Petal chat's note (PETAL_NOTE, set by Petal for its own chats), answered about the
            // note's window; any other AI session is this process, so two sessions never share what they looked at
            // or were allowed.
            let note = ProcessInfo.processInfo.environment["PETAL_NOTE"] ?? ""
            let caller = note.isEmpty ? "mcp-\(getpid())" : note
            // A card asking the person first waits up to 120 s: this waits longer, so their answer always arrives.
            let reply = petal(["assist", name, json, caller], timeout: 150)
            guard let data = reply.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else {
                throw Failure(reply.isEmpty ? "Petal isn't running" : reply)
            }
            if let error = (object as? [String: Any])?["error"] as? String { throw Failure(error) }
            return object
        case "petal_reload":
            return ["ok": true, "note": petal("restart") + "; the Claude panel closes."]
        default:
            throw Failure("Unknown tool")
        }
    }

    /// Using apps is on in these settings (missing: its default, on).
    private static func computerUseOn(_ settings: [String: Any]) -> Bool {
        settings["computerUse"] as? Bool ?? (schema["computerUse"]?.first as? Bool ?? true)
    }

    // MARK: Files

    /// The three files Petal keeps in memory: inside Petal, asked of it (its own changes may not be written yet).
    private static func kept(_ url: URL) -> Bool { [settingsFile.path, modesFile.path, dockFile.path].contains(url.path) }

    /// One of the write tools, done by the running Petal (["mcpCall", name, json]); nil when Petal isn't running
    /// (or is one from before this), to be done here.
    private static func viaPetal(_ name: String, _ args: [String: Any]) throws -> Any? {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        let reply = petal(["mcpCall", name, json], timeout: 30)
        if reply.hasPrefix("Petal isn't running") || reply.hasPrefix("unknown function") { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else { throw Failure(reply) }
        if let error = object["error"] as? String { throw Failure(error) }
        return object["result"] ?? [:]
    }

    /// What the running Petal does for `viaPetal`: one line of JSON, the result or the error.
    /// `plan`: a recipe import's plan, made off the main thread (`importPlan`).
    static func answer(_ name: String, _ json: String, plan: Result<Recipe.Plan, Error>? = nil) -> String {
        var reply: [String: Any]
        do {
            let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
            if let plan {
                reply = ["result": try Recipe.apply(plan.get(), look: args["look"] as? Bool ?? false)]
            } else {
                reply = ["result": try call(name, args)]
            }
        } catch {
            reply = ["error": error.localizedDescription]
        }
        let data = (try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]))
            ?? Data("{\"error\": \"Couldn't answer\"}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs `body` holding ~/.config/petal/.lock (shared with petal-mcp.py), so two processes changing the files
    /// while Petal isn't running take turns: each reads, changes and writes inside it.
    static func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.appending(path: ".lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return try body() }
        defer { flock(fd, LOCK_UN); close(fd) }
        flock(fd, LOCK_EX)
        return try body()
    }

    static func read(_ url: URL) -> [String: Any]? {
        if inPetal, Thread.isMainThread, kept(url) { return MainActor.assumeIsolated { PetalApp.shared.config.root(of: url) } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Changes a file in place. A file that's there but isn't valid JSON is left alone, with an error for Claude.
    /// Inside Petal, settings, modes and dock changes go through its Config; elsewhere every change is made under
    /// the lock, read to written, and written whole (renamed into place).
    static func update(_ url: URL, fallback: [String: Any] = [:], _ change: @escaping (inout [String: Any]) throws -> Void) throws {
        if inPetal, Thread.isMainThread, kept(url) {
            return try MainActor.assumeIsolated { try PetalApp.shared.config.change(url, fallback: fallback, change) }
        }
        try locked {
            var object: [String: Any]
            if FileManager.default.fileExists(atPath: url.path) {
                guard let data = try? Data(contentsOf: url), let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw Failure("\(url.lastPathComponent) isn't valid JSON; fix it first")
                }
                object = parsed
            } else {
                object = fallback
            }
            try change(&object)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        }
    }

    // MARK: The running Petal

    /// Asks the running Petal over its socket, as petal-mcp.py does.
    static func petal(_ args: String...) -> String { petal(args) }

    /// `timeout`: seconds to wait for the answer (nil waits as long as it takes). Running out of time says so; it's
    /// never "Petal isn't running".
    static func petal(_ args: [String], timeout: Int? = nil) -> String {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "Petal isn't running" }
        defer { close(fd) }
        if let timeout {
            var limit = timeval(tv_sec: timeout, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        }
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
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return "Petal didn't answer in time" }
            if count <= 0 { break }
            reply.append(buffer, count: count)
            if reply.last == 0x0A { break }
        }
        return String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Installed apps by bundle id and name, filtered by a word in either.
    static func apps(matching query: String) -> [[String: String]] {
        installed().filter { query.isEmpty || "\($0.id) \($0.name)".localizedCaseInsensitiveContains(query) }
            .map { ["id": $0.id, "name": $0.name] }
    }

    /// What importing the recipe in `args` would add (reads it and finds its apps: off the main thread in Petal).
    static func importPlan(_ args: [String: Any]) throws -> Recipe.Plan {
        guard let path = args["path"] as? String, !path.isEmpty else { throw Failure("path is required") }
        return try Recipe.plan(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    static func importPlan(_ json: String) throws -> Recipe.Plan {
        try importPlan((try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:])
    }

    /// Every app in the usual places: bundle id, name, and where it is.
    static func installed() -> [(id: String, name: String, path: String)] {
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var found: [(id: String, name: String, path: String)] = []
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
                found.append((id, Insights.plain(name), path))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
