import Foundation

/// Petal's tools for the AI: `Petal --mcp` speaks the Model Context Protocol on stdin and stdout, so nothing needs
/// installing for them. Each tool's name, description and input schema is in Resources/mcp/tools.json (in the
/// repository at macos/Resources/mcp/tools.json), served as it is; the settings they list and change are
/// `Settings`; what each tool does is here.
enum MCP {
    static let folder = Config.folder
    static let settingsFile = folder.appending(path: "settings.json")
    static let dockFile = folder.appending(path: "dock.json")
    /// The running Petal's socket (`PETAL_SOCKET` points a client at another, for testing).
    static let socket = ProcessInfo.processInfo.environment["PETAL_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? folder.appending(path: "petal.sock").path

    /// The tools as `tools/list` gives them.
    static let tools: [[String: Any]] = {
        guard let url = Bundle.main.url(forResource: "tools", withExtension: "json", subdirectory: "mcp"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }()

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
            return ["tools": tools]
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

    /// Inside the running Petal (set at its start): settings and dock changes go through its Config.
    nonisolated(unsafe) static var inPetal = false

    /// The tools that change settings.json or dock.json.
    static let writeTools: Set<String> = ["petal_set_settings", "petal_reset_settings", "petal_set_dock"]

    static func call(_ name: String, _ args: [String: Any]) throws -> Any {
        // While Petal runs, a change is made by Petal itself, in order with every other change (two notes changing
        // settings at once never undo each other); only without it is the file changed here, under a lock.
        if !inPetal, writeTools.contains(name), let done = try viaPetal(name, args) { return done }
        switch name {
        case "petal_get_state":
            let settings = read(settingsFile) ?? [:]
            var effective: [String: Any] = [:]
            var help: [String: Any] = [:]
            for setting in Settings.forTools {
                effective[setting.key] = settings[setting.key] ?? setting.fallback.value
                help[setting.key] = setting.help
            }
            let dock = read(dockFile) ?? [:]
            let environment = ProcessInfo.processInfo.environment
            return ["settings": effective, "settings_help": help,
                    "dock": ["apps": ConfigRules.apps(dock["apps"]), "position": dock["position"] ?? "bottom",
                             "autohide": dock["autoHide"] ?? false, "dock": dock["dock"] ?? "petal"],
                    "files": ["settings": settingsFile.path, "dock": dockFile.path,
                              "instructions": folder.appending(path: "instructions.md").path,
                              "source": Personal.sourceForAgents ?? environment["PETAL_SOURCE"] ?? "",
                              "app": environment["PETAL_APP"] ?? Bundle.main.bundlePath],
                    "personal": ["source": Personal.source.path, "set_up": Personal.exists, "how": Personal.how]]
        case "petal_set_settings":
            let changes = args["settings"] as? [String: Any] ?? [:]
            let unknown = changes.keys.filter { Settings.named($0)?.forTools != true }.sorted()
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
                let had = Set(current["aiNeverLook"] as? [String] ?? Settings.defaults["aiNeverLook"] as? [String] ?? [])
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
                for key in asked.isEmpty ? Settings.forTools.map(\.key) : asked where key != "aiNeverLook" && !(off && key == "computerUse") {
                    if let setting = Settings.named(key), setting.forTools { settings[key] = setting.fallback.value }
                }
            }
            return ["ok": true, "reset": asked.isEmpty ? "all" as Any : asked as Any]
        case "petal_set_dock":
            var done: [String: Any] = [:]
            if let position = args["position"] as? String, !["bottom", "left", "right"].contains(position) {
                throw Failure("position must be bottom, left or right (the menu bar holds the top)")
            }
            // The dock's apps: the whole list in its order, or a few added at the end or taken out.
            func ids(_ key: String) throws -> [String]? {
                guard let value = args[key] else { return nil }
                guard let list = value as? [String] else { throw Failure("\(key) is a list of bundle ids and https:// addresses") }
                return list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            let whole = try ids("apps"), add = try ids("add"), remove = try ids("remove")
            try update(dockFile) { dock in
                if let position = args["position"] as? String { dock["position"] = position; done["position"] = position }
                if let hide = args["autohide"] as? Bool { dock["autoHide"] = hide; done["autohide"] = hide }
                guard whole != nil || add != nil || remove != nil else { return }
                var apps: [String] = []
                for app in (whole ?? ConfigRules.apps(dock["apps"])) + (add ?? []) where !apps.contains(app) { apps.append(app) }
                apps.removeAll { remove?.contains($0) == true }
                dock["apps"] = apps
                done["apps"] = apps
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
        case "petal_list_apps":
            return apps(matching: args["query"] as? String ?? "")
        case "petal_look", "petal_apps", "petal_windows", "petal_trash", "petal_remember", "petal_forget", "petal_memories", "petal_show", "petal_vault", "petal_ui", "petal_act", "petal_browser",
             "petal_routines", "petal_routine_save", "petal_routine_run", "petal_routine_undo", "petal_routine_delete",
             "petal_notes", "petal_note_read", "petal_note_write", "petal_note_move", "petal_note_stick",
             "petal_view", "petal_view_versions", "petal_view_pick", "petal_note_pdf_comments":
            // Petal itself does these, with its own permissions (and asks the person first where it should).
            let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            // Which chat asks: a Petal chat's note (PETAL_NOTE, set by Petal for its own chats), answered about the
            // note's window; any other AI session is this process, so two sessions never share what they looked at
            // or were allowed.
            let note = ProcessInfo.processInfo.environment["PETAL_NOTE"] ?? ""
            let caller = note.isEmpty ? "mcp-\(getpid())" : note
            // Petal answers within 150 seconds, or keeps saying it's waiting (a space every 10 s) while a card is up for
            // the person, however many one request shows (an agent's, then the app's), so their answer always arrives.
            // Giving up (or this process ending) ends what the request had going, and answers its card Don't.
            let reply = petal(["assist", name, json, caller], timeout: 150)
            guard let data = reply.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else {
                throw Failure(reply.isEmpty ? "Petal isn't running" : reply)
            }
            if let error = (object as? [String: Any])?["error"] as? String { throw Failure(error) }
            return object
        case "petal_reload":
            return ["ok": true, "note": petal("restart") + "; the chat's panel closes."]
        default:
            throw Failure("Unknown tool")
        }
    }

    /// Using apps is on in these settings (missing: its default, on).
    private static func computerUseOn(_ settings: [String: Any]) -> Bool {
        settings["computerUse"] as? Bool ?? Settings.defaults["computerUse"] as? Bool ?? true
    }

    // MARK: Files

    /// The two files Petal keeps in memory: inside Petal, asked of it (its own changes may not be written yet).
    private static func kept(_ url: URL) -> Bool { [settingsFile.path, dockFile.path].contains(url.path) }

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

    /// What the running Petal does for `viaPetal`: one line of JSON, the result or the error. Only the write tools
    /// `viaPetal` sends (`writeTools`); any other is refused, never done on the dock's thread.
    static func answer(_ name: String, _ json: String) -> String {
        var reply: [String: Any]
        guard writeTools.contains(name) else { return #"{"error": "Only Petal's settings and dock tools come this way."}"# }
        do {
            let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
            reply = ["result": try call(name, args)]
        } catch {
            reply = ["error": error.localizedDescription]
        }
        let data = (try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]))
            ?? Data("{\"error\": \"Couldn't answer\"}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs `body` holding ~/.config/petal/.lock, so two processes changing the files
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
    /// Inside Petal, settings and dock changes go through its Config; elsewhere every change is made under
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

    /// Asks the running Petal over its socket.
    static func petal(_ args: String...) -> String { petal(args) }

    /// `timeout`: seconds to wait for the answer, or for the next sign Petal is still waiting on the person (nil waits
    /// as long as it takes). Running out of time says so; it's never "Petal isn't running".
    static func petal(_ args: [String], timeout: Int? = nil) -> String {
        switch petalAnswer(args, timeout: timeout) {
        case .failed(let text): return text
        case .bytes(let bytes): return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Petal's answer as it came (`bytes`, the line's end included), or what went wrong on this side (`failed`: one of
    /// this function's own sentences, never anything Petal sent). Its read buffer is zeroed before it returns; the
    /// answer is the caller's to wipe.
    enum Answer { case bytes([UInt8]), failed(String) }

    static func petalAnswer(_ args: [String], timeout: Int? = nil) -> Answer {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed("Petal isn't running") }
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
        guard connected == 0, let request = try? JSONSerialization.data(withJSONObject: args) else { return .failed("Petal isn't running") }
        let out = Array(request + Data("\n".utf8))
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
        var reply = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        defer { wipe(&buffer) }
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                wipe(&reply)
                return .failed("Petal didn't answer in time")
            }
            if count <= 0 { break }
            reply.append(contentsOf: buffer[..<count])
            if reply.last == 0x0A { break }
        }
        return .bytes(reply)
    }

    /// Overwrites `bytes` with zeros in place (memset_s, which the compiler keeps).
    static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { _ = memset_s(base, raw.count, 0, raw.count) }
        }
    }

    /// Installed apps by bundle id and name, filtered by a word in either.
    static func apps(matching query: String) -> [[String: String]] {
        installed().filter { query.isEmpty || "\($0.id) \($0.name)".localizedCaseInsensitiveContains(query) }
            .map { ["id": $0.id, "name": $0.name] }
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
                found.append((id, Apps.plain(name), path))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
