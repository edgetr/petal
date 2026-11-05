import AppKit

/// `petal` on macOS: Petal.app's own executable, linked as ~/.local/bin/petal, with the same commands as bin/petal on
/// Omarchy, so any agent (T3 Code, Claude Code, Codex in a terminal) or person can drive the dock from a shell.
enum CLI {
    static let commands: Set<String> = ["mode", "stay", "current", "desktop", "ask", "chat", "search", "settings", "reveal", "check",
                                        "dock", "restart", "version", "update", "modes", "get", "set", "restore-dock", "help"]

    static let help = """
    petal mode <id>           put this Desktop in a mode (waits out a focus countdown)
    petal stay                cancel a countdown
    petal current             this Desktop's mode
    petal modes               the modes and their apps
    petal get                 everything about the dock: settings (with help), modes, files
    petal set <key> <value>   change a setting (value as JSON: true, 44, "#d9367f", ["~/Downloads"])
    petal dock [petal|macos]  which dock is showing, or switch
    petal ask | chat <text>   open the AI panel, or ask it something
    petal search | settings   open the "+" search, or Petal's settings
    petal restart | update    restart Petal, or check for a new one
    petal doctor [--fix]      check Petal, and repair what it safely can
    petal report "<what>"     tell Petal's maker what went wrong (a GitHub issue; shown to you first)
    petal restore-dock        give macOS its Dock back, even if Petal crashed
    """

    /// Runs a command and exits. Commands that need the running Petal reach it over its socket.
    static func run(_ arguments: [String]) -> Never {
        let command = arguments.first ?? "help"
        let rest = Array(arguments.dropFirst())
        switch command {
        case "help":
            print(help)
        case "modes":
            let modes = (MCP.read(MCP.modesFile)?["modes"] as? [[String: Any]]) ?? []
            for mode in modes {
                print("\(mode["id"] ?? "") - \(mode["name"] ?? "") | \((mode["apps"] as? [String] ?? []).joined(separator: ", "))")
            }
        case "get":
            output(try? MCP.call("petal_get_state", [:]))
        case "set":
            guard rest.count >= 2 else { fail("usage: petal set <key> <value>") }
            let text = rest.dropFirst().joined(separator: " ")
            let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) ?? text
            do { output(try MCP.call("petal_set_settings", ["settings": [rest[0]: value]])) } catch { fail(error.localizedDescription) }
        case "chat":
            print(MCP.petal("chat", rest.joined(separator: " ")))
        case "mode":
            guard let id = rest.first else { fail("usage: petal mode <id>") }
            print(MCP.petal("mode", id))
        default:
            print(MCP.petal(([command] + rest)))
        }
        exit(0)
    }

    static func output(_ value: Any?) {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        print(String(decoding: data, as: UTF8.self))
    }

    static func fail(_ text: String) -> Never {
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(1)
    }
}

/// Lets the person's other AI sessions (T3 Code, Claude Code or Codex in a terminal) change Petal too: Petal's MCP
/// server is registered with Claude Code and Codex through their own `mcp add`, the skill is in their skills
/// folders, and `petal` is on the PATH. Kept current on every start while `otherAgents` is on.
@MainActor
enum OtherAgents {
    static func connect(paths: [Provider: String]) {
        guard let executable = Bundle.main.executablePath else { return }
        Skill.install()
        linkCommand(executable)
        let environment = PetalApp.shared.childEnvironment
        Task.detached {
            for (provider, path) in paths { register(provider, cli: path, server: executable, environment: environment) }
        }
    }

    /// ~/.local/bin/petal → Petal's executable, unless something else already has that name.
    static func linkCommand(_ executable: String) {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin")
        let link = bin.appending(path: "petal")
        if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            guard existing != executable, existing.contains("Petal.app") || existing.contains("/petal/") else { return }
            try? FileManager.default.removeItem(at: link)
        } else if FileManager.default.fileExists(atPath: link.path) {
            return
        }
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: executable)
    }

    /// Registers `petal` with the agent, replacing an older registration that points somewhere else.
    nonisolated static func register(_ provider: Provider, cli: String, server: String, environment: [String: String]) {
        func run(_ arguments: [String]) -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = arguments
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return (-1, "") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let (status, current) = run(["mcp", "get", "petal"])
        if status == 0 && current.contains(server) { return }
        switch provider {
        case .claude:
            if status == 0 { _ = run(["mcp", "remove", "-s", "user", "petal"]) }
            _ = run(["mcp", "add", "-s", "user", "petal", "--", server, "--mcp"])
        case .codex:
            if status == 0 { _ = run(["mcp", "remove", "petal"]) }
            _ = run(["mcp", "add", "petal", "--", server, "--mcp"])
        }
    }
}
