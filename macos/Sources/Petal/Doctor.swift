import AppKit

/// Petal's doctor and reporter on macOS, the same two commands as bin/petal-doctor on Omarchy:
///
///     Petal doctor [--fix] [--json]      check Petal; --fix repairs what's safe to repair (backing up what it replaces)
///     Petal report "<what happened>" [--yes] [--preview]
///                                        a GitHub issue on edgetr/petal: findings, versions, recent log lines, redacted;
///                                        filed with `gh` when it's signed in, else opened as a filled-in issue page
///
/// The settings window runs these as a separate process and shows what they find. Permissions are the one thing
/// the window checks itself: macOS grants them to Petal.app, not to a command run from a terminal.
@MainActor
enum Doctor {
    struct Finding: Codable, Identifiable {
        var id: String { area + text }
        let level: String     // ok, warn, error
        let area: String
        let text: String
        var fixed: String?
    }

    static let repo = "edgetr/petal"
    static let bundleID = "tech.edgetr.petal"

    static func check(fix: Bool) -> [Finding] {
        var found: [Finding] = []
        func note(_ level: String, _ area: String, _ text: String, fixed: String? = nil) {
            found.append(Finding(level: level, area: area, text: text, fixed: fixed))
        }
        let folder = Config.folder
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

        // The app and its signature.
        let signer = signature()
        // A build of the person's own changes is signed with their own certificate (Personal.swift).
        let stable = signer == "Petal (Edgetr)" || (signer == "Petal (Personal)" && Personal.inUse)
        note(stable ? "ok" : "warn", "app",
             "Petal \(version) at \(home(Bundle.main.bundlePath))" + (stable ? (signer == "Petal (Personal)" ? ", with your own changes." : ".")
                : ", signed \(signer ?? "ad hoc"): macOS may ask for its permissions again after each update."))

        // The files, which Petal won't overwrite while they're broken.
        let seed = Bundle.main.url(forResource: "modes", withExtension: "json")
        for (name, fallback) in [("settings.json", Data("{}\n".utf8)), ("dock.json", Data("{}\n".utf8)),
                                 ("modes.json", seed.flatMap { try? Data(contentsOf: $0) })] {
            let url = folder.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                if name == "modes.json" { note("warn", "files", "modes.json is missing; Petal starts from its default modes.") }
                continue
            }
            guard Config.parse(url) == nil else { continue }
            var fixed: String?
            if fix, let fallback {
                let backup = url.path + ".broken-" + Self.stamp()
                try? FileManager.default.copyItem(atPath: url.path, toPath: backup)
                try? fallback.write(to: url, options: .atomic)
                fixed = "backed up as \(URL(fileURLWithPath: backup).lastPathComponent), started fresh"
            }
            note("error", "files", "\(name) isn't valid JSON, so Petal ignores it.", fixed: fixed)
        }
        let settings = Config.parse(folder.appending(path: "settings.json")) ?? [:]
        let unknown = settings.keys.filter { Config.defaults[$0] == nil }.sorted()
        if !unknown.isEmpty { note("warn", "files", "Unknown settings (ignored): \(unknown.joined(separator: ", ")).") }

        // Modes.
        let modesURL = folder.appending(path: "modes.json")
        if var modes = Config.parse(modesURL) {
            let ids = (modes["modes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            var problems: [String] = []
            var changed = false
            if ids.isEmpty { problems.append("there are no modes") }
            if let first = ids.first, !ids.contains(modes["defaultMode"] as? String ?? "") {
                problems.append("the default mode doesn't exist")
                if fix { modes["defaultMode"] = first; changed = true }
            }
            let workspaces = modes["workspaces"] as? [String: Any] ?? [:]
            let stale = workspaces.filter { !ids.contains($0.value as? String ?? "") }
            if !stale.isEmpty {
                problems.append("Desktops \(stale.keys.sorted().joined(separator: ", ")) point at modes that don't exist")
                if fix { modes["workspaces"] = workspaces.filter { ids.contains($0.value as? String ?? "") }; changed = true }
            }
            if changed { Config.writeObject(modes, to: modesURL) }
            if problems.isEmpty {
                let apps = Set((modes["modes"] as? [[String: Any]] ?? []).flatMap { $0["apps"] as? [String] ?? [] })
                let missing = apps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) == nil }.sorted()
                note("ok", "modes", "\(ids.count) modes." + (missing.isEmpty ? "" : " Not installed (skipped in the dock): \(missing.prefix(8).joined(separator: ", "))."))
            } else {
                note(ids.isEmpty ? "error" : "warn", "modes", "In modes.json: " + problems.joined(separator: "; ") + ".", fixed: changed ? "fixed" : nil)
            }
        }

        // macOS's Dock: never left hidden without Petal running.
        let dock = Config.parse(folder.appending(path: "dock.json")) ?? [:]
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if SystemDock.isReplaced && !running {
            if fix { SystemDock.restore() }
            note("error", "dock", "macOS's Dock is hidden but Petal isn't running.", fixed: fix ? "gave macOS its Dock back" : nil)
        } else if dock["welcomed"] as? Bool != true {
            note("ok", "dock", "Petal hasn't been set up yet: open it to start.")
        } else if (dock["dock"] as? String ?? "petal") == "petal" && !running {
            note("warn", "dock", "Petal is set to be your dock but isn't running: open Petal.")
        } else {
            note("ok", "dock", (dock["dock"] as? String ?? "petal") == "petal" ? "Petal is your dock." : "macOS's Dock is in use; Petal's is off.")
        }
        if !FileManager.default.fileExists(atPath: DockGuard.plist.path) && dock["welcomed"] as? Bool == true
            && (dock["dock"] as? String ?? "petal") == "petal" {
            if fix { DockGuard.install() }
            note("warn", "dock", "The guard that gives macOS its Dock back if Petal crashes isn't installed.", fixed: fix ? "installed it" : nil)
        }

        // Per-mode windows: none left off-screen. The Dock guard runs without Accessibility, so it can't move
        // windows; after a crash, Petal's next launch brings them back (or `petal restore-windows`).
        let waiting = Parking.waiting()
        if waiting > 0 && !running {
            var fixed: String?
            if fix && AXIsProcessTrusted() { fixed = "brought back \(Parking.restoreEverything())" }
            note("error", "windows", "\(waiting) window\(waiting == 1 ? " is" : "s are") waiting off-screen since Petal last quit unexpectedly. "
                 + "Open Petal, or run petal restore-windows, to bring them back.", fixed: fixed)
        } else if settings["modeWindows"] as? Bool == true {
            note("ok", "windows", "Each mode keeps its own windows. If Petal ever quits unexpectedly, its next launch brings back "
                 + "the windows it had put away; the Dock guard can't move windows, so it doesn't.")
        }

        // Held notifications: the running Petal says whether it can hold them (macOS gives Petal.app its permissions,
        // not this command).
        let holdWanted = settings["holdNotifications"] as? Bool ?? true
        let holdingModes = (Config.parse(modesURL)?["modes"] as? [[String: Any]] ?? []).filter { $0["hold"] as? Bool == true }
        if holdWanted && !holdingModes.isEmpty && running {
            let reply = MCP.petal("holding")
            if let status = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] {
                if status["works"] as? Bool == true {
                    note("ok", "notes", "Holding notifications works (\(status["way"] as? String == "closer" ? "Petal closes macOS's banners" : "Do Not Disturb while holding")).")
                } else {
                    note("warn", "notes", "Petal holds no notifications. \(status["why"] as? String ?? "") Petal's settings, under Focus, show how.")
                }
            }
        }
        if FileManager.default.fileExists(atPath: Quiet.marker.path) && !running {
            if fix { Quiet.turnOff(wait: true) }
            note("warn", "notes", "Do Not Disturb that Petal turned on is still on, and Petal isn't running.", fixed: fix ? "turned it off" : nil)
        }

        // The AI apps.
        let chosen = (settings["aiProviders"] as? [String] ?? Config.defaults["aiProviders"] as? [String] ?? []).compactMap(Provider.init(rawValue:))
        if chosen.isEmpty { note("ok", "ai", "No AI chosen: Petal works as a dock without it.") }
        for provider in chosen {
            guard let path = PetalApp.find(provider, setting: settings[provider.pathSetting] as? String ?? "") else {
                note("error", "ai", "\(provider.name) is chosen but isn't installed: install it from Petal's settings, under AI.")
                continue
            }
            let status = shell(path, provider.statusArguments)
            if provider.signedIn(status: status.status, output: status.output) != nil {
                note("ok", "ai", "\(provider.name) is installed and signed in.")
            } else {
                note("error", "ai", "\(provider.name) isn't signed in: sign in from Petal's settings, under AI.")
            }
            if !Skill.installed(for: provider) {
                if fix { Skill.install() }
                note("warn", "ai", "\(provider.name) doesn't have Petal's skill.", fixed: fix ? "installed it" : nil)
            }
        }

        // Petal's AI tools.
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"# + "\n"
        let tools = shell(Bundle.main.executablePath ?? "", ["--mcp"], input: request)
        if let line = tools.output.split(separator: "\n").first,
           let reply = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
           let list = (reply["result"] as? [String: Any])?["tools"] as? [Any], !list.isEmpty {
            note("ok", "tools", "Petal's AI tools answer (\(list.count) tools).")
        } else {
            note("error", "tools", "Petal's AI tools don't answer (Petal.app may be damaged: reinstall it).")
        }

        // The person's own changes to Petal's code (Personal.swift).
        found += Personal.findings(fix: fix)

        // Recent trouble in the log.
        let problems = logLines(minutes: 30).filter { $0.localizedCaseInsensitiveContains("error") || $0.localizedCaseInsensitiveContains("fault") }
        note(problems.isEmpty ? "ok" : "warn", "logs",
             problems.isEmpty ? "No recent errors in Petal's log." : "\(problems.count) recent errors in Petal's log, the last: \(redact(problems.last ?? "").prefix(200))")
        return found
    }

    // MARK: Reporting

    static func reportBody(_ title: String, findings: [Finding]) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        var lines = ["**What happened:** \(title)", "", "**Petal** \(version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", "",
                     "**Doctor:**", ""]
        lines += findings.map { "- \($0.level) **\($0.area)**: \(redact($0.text))" + ($0.fixed.map { " (fixed: \($0))" } ?? "") }
        let logs = logLines(minutes: 30).suffix(40).map(redact)
        if !logs.isEmpty { lines += ["", "<details><summary>Recent log lines</summary>", "", "```"] + logs + ["```", "</details>"] }
        lines += ["", "_Filed with Petal's report._"]
        return lines.joined(separator: "\n")
    }

    /// Files the issue with `gh` when it's signed in; otherwise opens GitHub's new-issue page, filled in.
    @discardableResult
    static func file(_ title: String, body: String) -> String {
        if let gh = ghPath(), shell(gh, ["auth", "status"]).status == 0 {
            let result = shell(gh, ["issue", "create", "--repo", repo, "--title", title, "--body", body])
            if result.status == 0 { return result.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        var components = URLComponents(string: "https://github.com/\(repo)/issues/new")!
        components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: String(body.prefix(6000)))]
        if let url = components.url { NSWorkspace.shared.open(url) }
        return "Opened the issue page in your browser; check it and press Submit."
    }

    static func ghPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", NSHomeDirectory() + "/.local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: The command line

    static func command(_ arguments: [String]) -> Never {
        let rest = Array(arguments.drop { $0 != "doctor" && $0 != "report" }.dropFirst())
        if arguments.contains("report") {
            let title = rest.first { !$0.hasPrefix("--") }?.trimmingCharacters(in: .whitespaces) ?? ""
            let subject = title.isEmpty ? "Something went wrong in Petal" : title
            let body = reportBody(subject, findings: check(fix: false))
            print("Title: \(subject)\n\n\(body)\n")
            if rest.contains("--preview") { exit(0) }
            if !rest.contains("--yes") {
                guard isatty(0) != 0 else { print("Run again with --yes to file it."); exit(0) }
                print("File this on github.com/\(repo)? [y/N] ", terminator: "")
                guard ["y", "yes"].contains(readLine()?.lowercased() ?? "") else { print("Not filed."); exit(0) }
            }
            print(file(subject, body: body))
            exit(0)
        }
        let findings = check(fix: rest.contains("--fix"))
        if rest.contains("--json") {
            let data = (try? JSONEncoder().encode(["findings": findings])) ?? Data()
            print(String(decoding: data, as: UTF8.self))
        } else {
            let marks = ["ok": "✓", "warn": "!", "error": "✗"]
            for f in findings {
                print("\(marks[f.level] ?? "·") \(f.area.padding(toLength: 6, withPad: " ", startingAt: 0)) \(f.text)" + (f.fixed.map { "  → \($0)" } ?? ""))
            }
            if findings.contains(where: { $0.level == "error" && $0.fixed == nil }) {
                print("\nSomething still needs fixing. `Petal doctor --fix` repairs what it can; `Petal report \"what happened\"` tells Petal's maker.")
            }
        }
        exit(findings.contains { $0.level == "error" && $0.fixed == nil } ? 1 : 0)
    }

    // MARK: Helpers

    static func signature() -> String? {
        let result = shell("/usr/bin/codesign", ["-dvv", Bundle.main.bundlePath])
        return result.output.split(separator: "\n").first { $0.hasPrefix("Authority=") }.map { String($0.dropFirst("Authority=".count)) }
    }

    static func logLines(minutes: Int) -> [String] {
        // Petal's own messages only; macOS logs plenty about every app that isn't trouble.
        shell("/usr/bin/log", ["show", "--last", "\(minutes)m", "--style", "compact", "--predicate", "subsystem == \"tech.edgetr.petal\""])
            .output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("Timestamp") && !$0.isEmpty }
    }

    static func redact(_ text: String) -> String {
        let user = NSUserName()
        let out = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return user.count > 2 ? out.replacingOccurrences(of: user, with: "<user>") : out
    }

    static func home(_ path: String) -> String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    static func shell(_ path: String, _ arguments: [String], input: String? = nil) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + NSHomeDirectory() + "/.local/bin"]) { _, new in new }
        let output = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        guard (try? process.run()) != nil else { return (-1, "") }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Petal's skill for Claude Code and Codex (plugin/skill/SKILL.md, inside Petal.app): copied into
/// ~/.claude/skills/petal and ~/.codex/skills/petal, so any session knows Petal and its doctor.
@MainActor
enum Skill {
    static var source: URL? { Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "skill") }

    static func folder(for provider: Provider) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".\(provider.rawValue)/skills/petal")
    }

    static func installed(for provider: Provider) -> Bool {
        guard let source, let ours = try? Data(contentsOf: source) else { return true }
        return (try? Data(contentsOf: folder(for: provider).appending(path: "SKILL.md"))) == ours
    }

    /// For each AI app that's on this Mac; an older copy of Petal's own skill is replaced.
    static func install() {
        guard let source, let ours = try? Data(contentsOf: source) else { return }
        for provider in Provider.allCases {
            let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".\(provider.rawValue)")
            guard FileManager.default.fileExists(atPath: home.path) else { continue }
            let target = folder(for: provider).appending(path: "SKILL.md")
            if let existing = try? Data(contentsOf: target) {
                if existing == ours { continue }
                guard String(decoding: existing, as: UTF8.self).contains("name: petal") else { continue }   // someone else's
            }
            try? FileManager.default.createDirectory(at: folder(for: provider), withIntermediateDirectories: true)
            try? ours.write(to: target, options: .atomic)
        }
    }
}
