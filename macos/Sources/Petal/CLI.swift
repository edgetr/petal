import AppKit

/// `petal`: Petal.app's own executable, linked as ~/.local/bin/petal, so any agent (T3 Code, Claude Code, Codex in a
/// terminal) or person can drive the dock from a shell.
enum CLI {
    static let commands: Set<String> = ["desktop", "ask", "chat", "search", "settings", "reveal", "dock", "restart", "version", "update",
                                        "apps", "get", "set", "restore-dock", "help", "logs", "chats", "personal", "bench", "run"]

    static let help = """
    petal apps                the dock's apps, in the order they show
    petal get                 everything about the dock: settings (with help), its apps, files
    petal set <key> <value>   change a setting (value as JSON: true, 44, "#d9367f", ["~/Downloads"])
    petal dock [petal|macos]  which dock is showing, or switch
    petal ask | chat <text>   open the AI panel, or ask it something
    petal chats               your kept chats with Petal AI, to read again or carry on
    petal search | settings   open the "+" search, or Petal's settings (settings privacy: a page by name)
    petal restart | update    restart Petal, or check for a new one
    petal doctor [--fix]      check Petal, and repair what it safely can
    petal report "<what>"     tell Petal's maker what went wrong (a GitHub issue; shown to you first)
    petal restore-dock        give macOS its Dock back, even if Petal crashed
    petal logs [<minutes>]    Petal's own log, the last 30 minutes (or as many as asked)
    petal bench               time the dock's clicks (brings apps forward for ~15 s; results in
                              ~/Library/Logs/Petal/bench.json)
    petal bench quiet         only hovering the icons and a setting back and forth (no app comes forward)
    petal personal …          your own changes to Petal's code, kept through updates (petal personal help)
    petal run --key "<title>" [--env NAME] [--stdin] -- <command…>
                              run a command with an API key from your vault, for an agent testing with a real
                              key: the key goes in the command's variable (ANTHROPIC_API_KEY, OPENAI_API_KEY, …;
                              --env names another, --stdin writes it to the command's input), and is taken out of
                              what the command prints. Petal asks you first, unless you said Always for that
                              agent in that project (Settings, Vault, Agents). It keeps keys out of the agent's
                              chat and logs; a command written to leak one still can.
    """

    /// Runs a command and exits. Commands that need the running Petal reach it over its socket.
    static func run(_ arguments: [String]) -> Never {
        let command = arguments.first ?? "help"
        let rest = Array(arguments.dropFirst())
        switch command {
        case "help":
            print(help)
        case "apps":
            for app in ConfigRules.apps(MCP.read(MCP.dockFile)?["apps"]) { print(app) }
        case "get":
            output(try? MCP.call("petal_get_state", [:]))
        case "set":
            guard rest.count >= 2 else { fail("usage: petal set <key> <value>") }
            let text = rest.dropFirst().joined(separator: " ")
            let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) ?? text
            do { output(try MCP.call("petal_set_settings", ["settings": [rest[0]: value]])) } catch { fail(error.localizedDescription) }
        case "chat":
            print(MCP.petal("chat", rest.joined(separator: " ")))
        case "personal":
            Personal.command(rest)
        case "run":
            AgentRun.run(rest)
        case "restore-dock":
            // Done here, not by the running Petal: it has to work when Petal has crashed.
            MainActor.assumeIsolated {
                guard SystemDock.isReplaced else { print("macOS's Dock is already as you had it."); return }
                SystemDock.restore()
                print("macOS's Dock is back as you had it.")
            }
        case "logs":
            let minutes = rest.first.flatMap(Int.init) ?? 30
            let lines = MainActor.assumeIsolated { Doctor.logLines(minutes: minutes) }
            print(lines.isEmpty ? "Nothing in Petal's log in the last \(minutes) minutes." : lines.joined(separator: "\n"))
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
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path,
              // Only an installed Petal.app registers itself; a build or test copy never takes over.
              executable.hasSuffix("Petal.app/Contents/MacOS/Petal"), !executable.contains("/build/"), !executable.contains("/tmp/") else { return }
        Skill.install()
        linkCommand(executable)
        let environment = PetalApp.shared.childEnvironment
        Task.detached {
            for (provider, path) in paths { register(provider, cli: path, server: executable, environment: environment) }
        }
    }

    /// ~/.local/bin/petal → Petal's executable, unless something else already has that name.
    static func linkCommand(_ executable: String) {
        // Only an installed Petal.app: a bare build or a test copy running for a moment must never take the link.
        guard executable.hasSuffix("Petal.app/Contents/MacOS/Petal"), !executable.contains("/build/"), !executable.contains("/tmp/") else { return }
        let bin = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin")
        let link = bin.appending(path: "petal")
        if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            // Petal's own link (or a broken one: pointing nowhere, or at itself) is made anew.
            let broken = !FileManager.default.fileExists(atPath: link.path)
            guard existing != executable, broken || existing.contains("Petal.app") || existing.contains("/petal/") else { return }
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
