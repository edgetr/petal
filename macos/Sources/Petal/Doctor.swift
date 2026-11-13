import AppKit

/// Petal's doctor and reporter:
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
        /// `doctor --fix` can repair it (nil, from an older Petal's JSON: it can't).
        var fixable: Bool?
    }

    static let repo = "edgetr/petal"
    static let bundleID = "tech.edgetr.petal"

    static func check(fix: Bool) -> [Finding] {
        var found: [Finding] = []
        func note(_ level: String, _ area: String, _ text: String, fixed: String? = nil, fixable: Bool = false) {
            found.append(Finding(level: level, area: area, text: text, fixed: fixed, fixable: fixable))
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
        let fallback = Data("{}\n".utf8)
        for name in ["settings.json", "dock.json"] {
            let url = folder.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path), Config.parse(url) == nil else { continue }
            var fixed: String?
            if fix {
                let backup = url.path + ".broken-" + Self.stamp()
                try? FileManager.default.copyItem(atPath: url.path, toPath: backup)
                try? fallback.write(to: url, options: .atomic)
                fixed = "kept a copy (\(URL(fileURLWithPath: backup).lastPathComponent)) and started fresh"
            }
            note("error", "files", "\(name == "dock.json" ? "Your dock file" : "Your settings file") (\(name)) is damaged, so Petal is using its defaults.", fixed: fixed, fixable: true)
        }
        let settings = Config.parse(folder.appending(path: "settings.json")) ?? [:]
        let unknown = settings.keys.filter { Settings.defaults[$0] == nil }.sorted()
        if !unknown.isEmpty { note("warn", "files", "Settings Petal doesn’t know, left alone: \(unknown.joined(separator: ", ")).") }

        // The dock's apps.
        let dock = Config.parse(folder.appending(path: "dock.json")) ?? [:]
        if let apps = dock["apps"] as? [String] {
            let missing = apps.filter { !Sites.isWeb($0) && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) == nil }.sorted()
            note("ok", "apps", "\(apps.count) apps in your dock." + (missing.isEmpty ? "" : missing.count == 1 ? " One isn’t installed and is left out." : " \(missing.count) aren’t installed and are left out."))
        } else if FileManager.default.fileExists(atPath: folder.appending(path: "modes.json").path) {
            // Petal for macOS had modes once; opening it moves the default mode's apps into the dock, unless it can't read them.
            note("warn", "apps", "Your dock from when Petal had modes hasn't been moved over. Open Petal; if the dock stays empty, "
                 + "it can't be read: choose Import Dock in Petal's settings, or add apps with “+”.")
        }

        // macOS's Dock: never left hidden without Petal running.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && PetalProcess.isDock(pid: $0.processIdentifier) }
        if SystemDock.isReplaced && !running {
            if fix { SystemDock.restore() }
            note("error", "dock", "macOS's Dock is hidden but Petal isn't running.", fixed: fix ? "gave macOS its Dock back" : nil, fixable: true)
        } else if dock["welcomed"] as? Bool != true {
            note("ok", "dock", "Petal hasn't been set up yet: open it to start.")
        } else if (dock["dock"] as? String ?? "petal") == "petal" && !running {
            note("warn", "dock", "Petal is set to be your dock but isn't running: open Petal.")
        } else if running && !IPC.answering() {
            // Running, but `petal` and the AI's tools can't reach it (another copy took its socket, say).
            note("error", "dock", "Petal AI can’t reach Petal. Quit Petal and open it again.")
        } else {
            note("ok", "dock", (dock["dock"] as? String ?? "petal") == "petal" ? "Petal is your dock." : "macOS's Dock is in use; Petal's is off.")
        }
        if !FileManager.default.fileExists(atPath: DockGuard.plist.path) && dock["welcomed"] as? Bool == true
            && (dock["dock"] as? String ?? "petal") == "petal" {
            if fix { DockGuard.install() }
            note("warn", "dock", "The helper that gives macOS its Dock back if Petal crashes is missing.", fixed: fix ? "installed it" : nil, fixable: true)
        }

        // The AI apps.
        let chosen = (settings["aiProviders"] as? [String] ?? Settings.defaults["aiProviders"] as? [String] ?? []).compactMap(Provider.init(rawValue:))
        if chosen.isEmpty { note("ok", "ai", "No AI chosen: Petal works as a dock without it.") }
        for provider in chosen {
            guard let path = PetalApp.find(provider, setting: settings[provider.pathSetting] as? String ?? "") else {
                note("error", "ai", "\(provider.name) isn’t installed. Install it in Settings › Petal AI.")
                continue
            }
            let status = shell(path, provider.statusArguments)
            if provider.signedIn(status: status.status, output: status.output) != nil {
                note("ok", "ai", "\(provider.name) is installed and signed in.")
            } else {
                note("error", "ai", "\(provider.name) isn’t signed in. Sign in in Settings › Petal AI.")
            }
            if settings["otherAgents"] as? Bool ?? true, !Skill.installed(for: provider) {
                if fix { Skill.install() }
                note("warn", "ai", "\(provider.name) doesn’t know about Petal yet.", fixed: fix ? "installed it" : nil, fixable: true)
            }
        }

        // Petal's AI tools.
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"# + "\n"
        let tools = shell(Bundle.main.executablePath ?? "", ["--mcp"], input: request)
        if let line = tools.output.split(separator: "\n").first,
           let reply = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
           let list = (reply["result"] as? [String: Any])?["tools"] as? [Any], !list.isEmpty {
            note("ok", "tools", "Petal AI’s tools work.")
        } else {
            note("error", "tools", "Petal AI’s tools don’t work. Install Petal again from petal.codes.")
        }

        // The person's own changes to Petal's code (Personal.swift).
        found += Personal.findings(fix: fix)

        // Recent trouble in the log.
        let problems = logLines(minutes: 30).filter { $0.localizedCaseInsensitiveContains("error") || $0.localizedCaseInsensitiveContains("fault") }
        note(problems.isEmpty ? "ok" : "warn", "logs",
             problems.isEmpty ? "Nothing went wrong in the last 30 minutes." : "\(problems.count) things went wrong in the last 30 minutes. Report a problem sends the details.")
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
        return "The report is open in your browser. Sign in to GitHub there and press Submit."
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
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Petal's skill for Claude Code and Codex (macos/Resources/skill/SKILL.md, inside Petal.app): copied into
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

    /// Petal's own skill taken out of each AI app's skills folder (the folder too, once empty); someone else's skill
    /// by the same name is left alone.
    static func remove() {
        for provider in Provider.allCases {
            let folder = folder(for: provider), target = folder.appending(path: "SKILL.md")
            guard let existing = try? Data(contentsOf: target), String(decoding: existing, as: UTF8.self).contains("name: petal") else { continue }
            try? FileManager.default.removeItem(at: target)
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? FileManager.default.removeItem(at: folder) }
        }
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
