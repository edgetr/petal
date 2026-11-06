import AppKit

/// `petal` on macOS: Petal.app's own executable, linked as ~/.local/bin/petal, with the same commands as bin/petal on
/// Omarchy, so any agent (T3 Code, Claude Code, Codex in a terminal) or person can drive the dock from a shell.
enum CLI {
    static let commands: Set<String> = ["mode", "stay", "current", "desktop", "ask", "chat", "search", "settings", "reveal", "check",
                                        "dock", "restart", "version", "update", "modes", "get", "set", "restore-dock", "restore-windows", "help", "logs",
                                        "recipe", "suggest", "summary", "overview", "personal", "bench"]

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
    petal recipe export [<file>]           share your dock: modes, apps and look in a .petal file
    petal recipe import <file> [--look] [--dry-run]
                              add the modes from a .petal file (and its look, with --look)
    petal suggest [--json]    modes Petal would suggest from your activity
    petal summary [--json]    the last 7 days in your modes
    petal overview            every Desktop and its mode
    petal doctor [--fix]      check Petal, and repair what it safely can
    petal report "<what>"     tell Petal's maker what went wrong (a GitHub issue; shown to you first)
    petal restore-dock        give macOS its Dock back, even if Petal crashed
    petal logs [<minutes>]    Petal's own log, the last 30 minutes (or as many as asked)
    petal bench               time the dock's clicks (brings apps forward and switches modes for ~15 s;
                              results in ~/Library/Logs/Petal/bench.json)
    petal bench quiet         only hovering the icons and a setting back and forth (no app or mode changes)
    petal restore-windows     bring back every window put away for another mode, even if Petal crashed
    petal personal …          your own changes to Petal's code, kept through updates (petal personal help)
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
        case "recipe":
            recipe(rest)
        case "suggest":
            guard Insights.setting("activityLog") else { fail("The activity history is off (petal set activityLog true).") }
            let found = Insights.suggestions()
            if rest.contains("--json") { output(["suggestions": found.map(\.json)]) }
            else if found.isEmpty { print("Nothing to suggest yet.") }
            else { for suggestion in found { print("- " + (suggestion.json["text"] as? String ?? "")) } }
        case "summary":
            guard Insights.setting("activityLog") else { fail("The activity history is off (petal set activityLog true).") }
            let summary = Insights.summary(lastWeek: false)
            if rest.contains("--json") { output(summary.json) }
            else if summary.modes.isEmpty { print("Nothing yet: Petal notes which app is in front, a minute at a time.") }
            else { print(summary.title + ":"); for line in summary.lines { print("  " + line) } }
        case "chat":
            print(MCP.petal("chat", rest.joined(separator: " ")))
        case "personal":
            Personal.command(rest)
        case "restore-windows":
            restoreWindows()
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
        case "mode":
            guard let id = rest.first else { fail("usage: petal mode <id>") }
            print(MCP.petal("mode", id))
        default:
            print(MCP.petal(([command] + rest)))
        }
        exit(0)
    }

    /// `petal recipe export [<file>]` and `petal recipe import <file> [--look]`.
    static func recipe(_ args: [String]) {
        switch args.first {
        case "export":
            do { print(try Recipe.export(path: args.dropFirst().first, name: nil)) } catch { fail(error.localizedDescription) }
        case "import":
            guard let path = args.dropFirst().first(where: { !$0.hasPrefix("--") }) else { fail("usage: petal recipe import <file> [--look]") }
            let look = args.contains("--look")
            do {
                let plan = try Recipe.plan(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                print("\(plan.name) adds \(plan.modes.count == 1 ? "a mode" : "\(plan.modes.count) modes"):")
                for mode in plan.modes {
                    print("  \(mode.name) (\(mode.id)): \(mode.apps.map(Insights.name).joined(separator: ", "))"
                          + (mode.missing.isEmpty ? "" : "; not on this Mac: " + mode.missing.joined(separator: ", ")))
                }
                if look && !plan.lookChanges.isEmpty {
                    print("Its look changes: " + plan.lookChanges.map { Recipe.lookNames[$0] ?? $0 }.joined(separator: ", "))
                }
                if args.contains("--dry-run") { exit(0) }
                if isatty(0) != 0 {
                    print("Add \(plan.modes.count == 1 ? "it" : "them")? [y/N] ", terminator: "")
                    guard readLine()?.lowercased().hasPrefix("y") == true else { exit(1) }
                }
                try Recipe.apply(plan, look: look)
                print("Added.")
            } catch {
                fail(error.localizedDescription)
            }
        default:
            fail("usage: petal recipe export [<file>] | petal recipe import <file> [--look]")
        }
    }

    /// The running Petal brings the windows back; without it, this command does, if the terminal may move windows.
    static func restoreWindows() {
        MainActor.assumeIsolated { restoreWindowsHere() }   // CLI.run runs on the main thread (main.swift)
    }

    @MainActor private static func restoreWindowsHere() {
        let reply = MCP.petal("restoreWindows")
        if reply.hasPrefix("Brought back") || reply.hasPrefix("No windows") { print(reply); return }
        guard AXIsProcessTrusted() else {
            let waiting = Parking.waiting()
            if waiting == 0 { print("No windows were waiting off-screen."); return }
            fail("\(waiting) window\(waiting == 1 ? " is" : "s are") waiting off-screen, and this terminal isn't allowed to move windows "
                 + "(System Settings > Privacy & Security > Accessibility). Open Petal: it brings them back as it starts.")
        }
        let count = Parking.restoreEverything()
        print(count == 0 ? "No windows were waiting off-screen." : "Brought back \(count) window\(count == 1 ? "" : "s").")
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
