import Foundation

/// The person's other agents (Claude Code or Codex in T3 Code or a terminal) using the vault without seeing its
/// secrets: the pure side. Which variable `petal run` puts a key in, taking a key out of what a command prints
/// (`Redactor`), who's asking, from the processes Petal read itself (`Caller`), which project that is, and the
/// person's grants (`Grant`). Nothing here reads a process, the Keychain or a file (AgentCallers.swift and
/// AgentRun.swift do; `project` reads the disk only through the `GitFiles` it's handed), so `macos/checks/run.sh`
/// checks it.
enum AgentAccess {
    // MARK: Which variable

    /// Each service's usual variable, by the key's sites (its service) and then by a word of its title.
    static let services: [(variable: String, domains: [String], words: [String])] = [
        ("ANTHROPIC_API_KEY", ["anthropic.com", "claude.ai", "claude.com"], ["anthropic", "claude"]),
        ("OPENAI_API_KEY", ["openai.com", "chatgpt.com"], ["openai", "chatgpt"]),
        ("GEMINI_API_KEY", ["generativelanguage.googleapis.com", "aistudio.google.com", "ai.google.dev", "gemini.google.com"], ["gemini"]),
        ("XAI_API_KEY", ["x.ai"], ["xai", "grok"]),
        ("GITHUB_TOKEN", ["github.com", "githubusercontent.com"], ["github"]),
        ("STRIPE_SECRET_KEY", ["stripe.com"], ["stripe"]),
    ]

    /// The variable a key goes in when `petal run` isn't told one (--env): its service's, else nil.
    static func variable(sites: [String], title: String) -> String? {
        for site in sites {
            guard let host = host(site) else { continue }
            if let found = services.first(where: { $0.domains.contains { host == $0 || host.hasSuffix("." + $0) } }) { return found.variable }
        }
        let words = Set(title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return services.first { !words.isDisjoint(with: $0.words) }?.variable
    }

    /// A name a shell takes for a variable, and not one that changes how programs are found or loaded.
    static func validVariable(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else { return false }
        guard name.unicodeScalars.allSatisfy({ $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }) else { return false }
        let upper = name.uppercased()
        if ["PATH", "HOME", "SHELL", "USER", "LOGNAME", "TMPDIR", "PWD", "IFS", "ENV", "BASH_ENV", "PS4"].contains(upper) { return false }
        return !upper.hasPrefix("DYLD_") && !upper.hasPrefix("LD_") && !upper.hasPrefix("PETAL_")
    }

    /// A web address's host, lowercased ("https://console.anthropic.com/x" → "console.anthropic.com").
    static func host(_ text: String) -> String? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        let host = rest.split(whereSeparator: { "/?#:".contains($0) }).first.map(String.init) ?? ""
        return host.isEmpty ? nil : host
    }

    // MARK: Taking keys out of what a command prints

    /// What a command prints, with every key `petal run` gave it replaced by "[<title> key]" before it reaches the
    /// agent: the key itself, in hex, percent-encoded, and base64 (standard or URL-safe, at any of the three places
    /// it can start in a longer encoding, and wrapped onto lines as MIME, PEM and `base64.encodebytes` write it: the
    /// whole span, line breaks and all). Fed a read at a time: the end of a read that could be the start of a key is
    /// held back (`carry`) until the next read says, so a key split across two reads is still taken out.
    struct Redactor {
        private struct Pattern {
            let bytes: [UInt8]
            let replacement: [UInt8]
            /// Base64: whitespace may come between any two of its characters (`maxRun` bytes at a time, at most
            /// `maxRuns` times), as when an encoder wraps its lines.
            let wraps: Bool
            var maxRuns: Int { wraps ? bytes.count / 4 + 1 : 0 }
            /// The most bytes a match can span.
            var span: Int { bytes.count + maxRuns * Redactor.maxRun }
        }
        /// A line break and the indent after it ("\r\n    ").
        static let maxRun = 8
        /// Patterns by their first byte, longest first.
        private var byFirst = [[Pattern]](repeating: [], count: 256)
        private var longest = 0
        private var carry: [UInt8] = []

        init(_ secrets: [(secret: String, label: String)]) {
            var seen = Set<[UInt8]>()
            var all: [Pattern] = []
            for (secret, label) in secrets {
                let replacement = Array("[\(label) key]".utf8)
                let forms = Self.forms(of: secret)
                let wrapped = Set(Self.base64Forms(of: secret))
                for form in forms {
                    let bytes = Array(form.utf8)
                    guard !bytes.isEmpty, seen.insert(bytes).inserted else { continue }
                    all.append(Pattern(bytes: bytes, replacement: replacement, wraps: wrapped.contains(form)))
                }
            }
            for pattern in all.sorted(by: { $0.bytes.count > $1.bytes.count }) {
                byFirst[Int(pattern.bytes[0])].append(pattern)
                longest = max(longest, pattern.span)
            }
        }

        /// The ways a key is commonly printed. Short keys (under 8 characters) only as themselves, and base64 only
        /// where at least 12 characters of it come from the key alone: shorter pieces would take out ordinary text.
        static func forms(of secret: String) -> [String] {
            let bytes = Array(secret.utf8)
            guard bytes.count >= 4 else { return [] }
            var out = [secret]
            guard bytes.count >= 8 else { return out }
            out.append(bytes.map { String(format: "%02x", $0) }.joined())
            out.append(bytes.map { String(format: "%02X", $0) }.joined())
            let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: unreserved), encoded != secret {
                out.append(encoded)
                // The same with lowercase hex digits (%2f), as some encoders write it.
                var lower = ""
                var rest = Substring(encoded)
                while let percent = rest.firstIndex(of: "%") {
                    lower += rest[..<percent]
                    let end = rest.index(percent, offsetBy: 3, limitedBy: rest.endIndex) ?? rest.endIndex
                    lower += rest[percent..<end].lowercased()
                    rest = rest[end...]
                }
                lower += rest
                if lower != encoded { out.append(lower) }
            }
            return out + base64Forms(of: secret)
        }

        /// In base64 a key starts at one of three places in a group of three bytes. Each gives a run of characters
        /// that come from the key's bits alone, whatever is around it: standard and URL-safe.
        static func base64Forms(of secret: String) -> [String] {
            let bytes = Array(secret.utf8)
            guard bytes.count >= 8 else { return [] }
            var out: [String] = []
            for offset in 0..<3 {
                let encoded = Array(Data(Array(repeating: 0, count: offset) + bytes).base64EncodedString().utf8)
                let first = (8 * offset + 5) / 6
                let last = (8 * (offset + bytes.count)) / 6 - 1
                guard last - first + 1 >= 12, last < encoded.count else { continue }
                let core = String(decoding: encoded[first...last], as: UTF8.self)
                out.append(core)
                let safe = String(core.map { $0 == "+" ? "-" : $0 == "/" ? "_" : $0 })
                if safe != core { out.append(safe) }
            }
            return out
        }

        /// The next read: what can be passed on now.
        mutating func feed(_ bytes: [UInt8]) -> [UInt8] {
            carry += bytes
            return run(final: false)
        }

        /// The command finished: everything held back.
        mutating func finish() -> [UInt8] { run(final: true) }

        private mutating func run(final: Bool) -> [UInt8] {
            let buffer = carry
            let count = buffer.count
            let hold = final || longest == 0 ? count : held(buffer)
            var out: [UInt8] = []
            out.reserveCapacity(count)
            var index = 0
            while index < hold {
                if let (pattern, length) = match(buffer, at: index) {
                    out += pattern.replacement
                    index += length
                } else {
                    out.append(buffer[index])
                    index += 1
                }
            }
            carry = index < count ? Array(buffer[index...]) : []
            return out
        }

        /// The first place near the end where what's read so far could be the start of a key: nothing from there on
        /// is passed on yet. (A key starting before it was either read whole, or isn't there.)
        private func held(_ buffer: [UInt8]) -> Int {
            let count = buffer.count
            for start in max(0, count - longest + 1)..<count {
                if byFirst[Int(buffer[start])].contains(where: { Self.compare($0, buffer, at: start) == .partial }) { return start }
            }
            return count
        }

        private func match(_ buffer: [UInt8], at index: Int) -> (Pattern, Int)? {
            for pattern in byFirst[Int(buffer[index])] {
                if case .match(let length) = Self.compare(pattern, buffer, at: index) { return (pattern, length) }
            }
            return nil
        }

        private enum Outcome: Equatable { case match(Int), partial, none }

        private static func whitespace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }

        /// `pattern` at `index`: found (and how many bytes it spans), cut off by the end of what's read so far, or not
        /// there. A wrapping pattern skips bounded runs of whitespace between its characters.
        private static func compare(_ pattern: Pattern, _ buffer: [UInt8], at index: Int) -> Outcome {
            let count = buffer.count
            var position = index
            var runs = 0
            for (offset, byte) in pattern.bytes.enumerated() {
                if pattern.wraps, offset > 0 {
                    var run = 0
                    while position < count, whitespace(buffer[position]) {
                        run += 1
                        position += 1
                        if run > maxRun { return .none }
                    }
                    if run > 0 {
                        runs += 1
                        if runs > pattern.maxRuns { return .none }
                    }
                }
                guard position < count else { return .partial }
                guard buffer[position] == byte else { return .none }
                position += 1
            }
            return .match(position - index)
        }
    }

    // MARK: Who's asking

    /// The kinds of caller. A grant names a verified agent (or `any`, for every verified agent).
    enum Agent: String, Codable, CaseIterable {
        case claude, codex, opencode
        /// A command the person ran in a terminal, with no agent above it.
        case command
        /// Petal AI's own chats (a sticky note, the panel): Petal started them.
        case petal
        /// Not Petal's own `petal run` or `Petal --mcp`, or an agent that isn't signed by its maker.
        case unknown
        /// Any of the agents (in a grant only).
        case any

        var name: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .opencode: "opencode"
            case .command: "A command"
            case .petal: "Petal AI"
            case .unknown: "An unknown program"
            case .any: "Any agent"
            }
        }

        /// Signed by its maker, checked by Petal (Claude Code, Codex): only these are ever allowed Always, and only
        /// these does a grant (even one for any agent) cover. Everything else (opencode, known by its name only; a
        /// command with no verified agent above it; an unknown program) is allowed once at a time.
        var verified: Bool { AgentAccess.makers[self] != nil }

        /// What a grant can name, in Settings.
        static let grantable: [Agent] = [.claude, .codex, .any]
    }

    /// Who signed each agent: its maker's Team ID and the identifier its maker gives it. A program that only looks
    /// like one of these (its name) and isn't signed so is an unknown program.
    static let makers: [Agent: (team: String, identifiers: [String])] = [
        .claude: ("Q6L2SF6YDW", ["com.anthropic.claude-code"]),   // Anthropic
        .codex: ("2DC432GLL2", ["codex"]),                        // OpenAI
    ]

    /// One process of the chain, as Petal read it: what it runs, and who signed it (its Team ID and identifier, nil
    /// when its signature didn't check out or Petal didn't read it).
    struct Process: Equatable {
        var pid: Int32
        var path: String
        var team: String?
        var identifier: String?

        init(pid: Int32, path: String, team: String? = nil, identifier: String? = nil) {
            self.pid = pid
            self.path = path
            self.team = team
            self.identifier = identifier
        }

        var file: String { (path as NSString).lastPathComponent }

        /// The agent its name suggests, before its signature is checked.
        var looksLike: Agent? {
            let file = file.lowercased()
            let path = path.lowercased()
            if file == "claude" || file == "claude.exe" || path.contains("/claude-code/") || path.contains("/claude/versions/") { return .claude }
            if file == "codex" || file.hasPrefix("codex-") || path.contains("/.codex/packages/") || path.contains("/@openai/codex/") { return .codex }
            if file == "opencode" || path.contains("/opencode-ai/") || path.contains("/.opencode/bin/") { return .opencode }
            return nil
        }

        /// The agent it is: one with a maker only when signed by that maker.
        var agent: Agent? {
            for (agent, maker) in makers where team == maker.team {
                if let identifier, maker.identifiers.contains(identifier) { return agent }
            }
            guard let named = looksLike else { return nil }
            return makers[named] == nil ? named : .unknown
        }
    }

    /// Who's asking, as Petal worked it out.
    struct Caller: Equatable {
        var agent: Agent
        /// The app the agent runs in ("T3 Code", "Terminal"), when one is in the chain.
        var host: String?
        /// Where it works: the git repository (a worktree's main checkout), else its folder.
        var project: String
        /// What connected, by name, for an unknown program ("nc", "python3").
        var program: String = ""
        /// What connected is Petal's own code (`petal run`, `Petal --mcp`): only it is ever handed a key.
        var peerIsPetal = true
        /// The process that connected.
        var pid: Int32 = 0

        /// "Codex in T3 Code", "Claude Code in Terminal", "An unknown program (nc)".
        var label: String {
            switch agent {
            case .unknown: return program.isEmpty ? agent.name : "\(agent.name) (\(program))"
            case .petal: return agent.name
            default: return host.map { "\(agent.name) in \($0)" } ?? agent.name
            }
        }

        /// May be granted Always, and covered by a grant: only an agent signed by its maker (`Agent.verified`).
        var grantable: Bool { agent.verified }
    }

    /// Who's asking: `chain` is the process that connected to Petal's socket, then its parent, and so on up.
    /// `peerIsPetal`: what connected is Petal's own code (`petal run`, `Petal --mcp`), checked by its signature.
    static func caller(chain: [Process], petalPID: Int32, peerIsPetal: Bool, project: String) -> Caller {
        let host = hostApp(chain)
        let pid = chain.first?.pid ?? 0
        guard let peer = chain.first, peerIsPetal else {
            return Caller(agent: .unknown, host: host, project: project, program: chain.first?.file ?? "", peerIsPetal: false, pid: pid)
        }
        // Petal's own chats: Petal started them.
        if chain.dropFirst().contains(where: { $0.pid == petalPID }) {
            return Caller(agent: .petal, host: nil, project: project, program: peer.file, pid: pid)
        }
        for process in chain.dropFirst() {
            guard let agent = process.agent else { continue }
            if agent == .unknown { return Caller(agent: .unknown, host: host, project: project, program: process.file, pid: pid) }
            return Caller(agent: agent, host: host, project: project, program: process.file, pid: pid)
        }
        return Caller(agent: .command, host: host, project: project, program: peer.file, pid: pid)
    }

    /// The app the chain runs in: the outermost app bundle of the highest process inside one ("/Applications/T3 Code
    /// (Nightly).app/…" → "T3 Code"), without a trailing "(Nightly)" or "(Beta)".
    static func hostApp(_ chain: [Process]) -> String? {
        for process in chain.reversed() {
            guard let range = process.path.range(of: ".app/") else { continue }
            var name = (String(process.path[..<range.lowerBound]) as NSString).lastPathComponent
            if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) { name = String(name[..<open.lowerBound]) }
            guard !name.isEmpty else { continue }
            return name
        }
        return nil
    }

    // MARK: Projects

    /// What's at a folder's `.git`: a repository's own folder, or a file pointing at one (a worktree's, a submodule's).
    enum GitMark: Equatable {
        case folder
        case file(String)
    }

    /// How `project` looks at the disk (AgentCallers.disk reads the real one; the checks hand in their own).
    struct GitFiles: Sendable {
        /// What's at `folder`/.git.
        var mark: @Sendable (String) -> GitMark?
        /// A path with every link resolved (realpath), or nil when nothing is there.
        var real: @Sendable (String) -> String?
        /// A small file's text, or nil.
        var read: @Sendable (String) -> String?
    }

    /// The project a folder belongs to: the nearest git repository above it (a worktree's main checkout, so T3's
    /// worktrees of ~/petal are all ~/petal), else the folder itself. `path` is absolute with links resolved.
    static func project(_ path: String, files: GitFiles) -> String {
        let start = standard(path)
        var folder = start
        while true {
            if let mark = files.mark(folder) {
                switch mark {
                case .folder: return folder
                case .file(let text): return worktreeMain(folder, gitFile: text, files: files) ?? folder
                }
            }
            guard folder != "/" else { return start }
            folder = (folder as NSString).deletingLastPathComponent
            if folder.isEmpty { folder = "/" }
        }
    }

    /// The main checkout of the worktree at `folder`, whose `.git` file says `gitFile`, only when git itself made it
    /// so: the gitdir it names exists and is an entry in a repository's `.git/worktrees/`, and that entry's own
    /// `gitdir` file points back at this folder's `.git` (every path with its links resolved). A `.git` file anyone
    /// can write ("gitdir: ~/trusted/.git/worktrees/x" in a folder of their own) never borrows another project's
    /// grants; nil, and the project is the folder itself.
    static func worktreeMain(_ folder: String, gitFile: String, files: GitFiles) -> String? {
        guard let line = gitFile.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        if !target.hasPrefix("/") { target = folder + "/" + target }
        guard let entry = files.real(target).map(standard) else { return nil }
        // <main>/.git/worktrees/<name>
        let parts = entry.split(separator: "/")
        guard parts.count >= 4, parts[parts.count - 2] == "worktrees", parts[parts.count - 3] == ".git" else { return nil }
        let main = "/" + parts.dropLast(3).joined(separator: "/")
        guard files.mark(main) == .folder, files.real(main + "/.git").map(standard) == main + "/.git" else { return nil }
        // The entry points back here (git writes the worktree's .git file's path, absolute or relative to the entry).
        guard let back = files.read(entry + "/gitdir")?.split(whereSeparator: \.isNewline).first
            .map({ $0.trimmingCharacters(in: .whitespaces) }), !back.isEmpty else { return nil }
        let pointed = back.hasPrefix("/") ? back : entry + "/" + back
        guard let here = files.real(folder + "/.git").map(standard), files.real(pointed).map(standard) == here else { return nil }
        return main
    }

    /// An absolute path without "." and "..", or a trailing slash.
    static func standard(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// "~/petal" for /Users/me/petal.
    static func shown(_ path: String, home: String) -> String {
        let home = standard(home)
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The home folder or anything above it: too much to grant for at once.
    static func tooBroad(_ path: String, home: String) -> Bool {
        let path = standard(path), home = standard(home)
        return path == "/" || path == home || home.hasPrefix(path + "/")
    }

    // MARK: Grants

    /// "Always for this project": an agent may use an item in a project (and its folders) without asking. Kept
    /// without any secret, in a file of Petal's (AgentCallers.swift).
    struct Grant: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        /// The vault item's id, or `Grant.newLogins` for making new logins.
        var item: String
        /// The item's title when granted, for the list.
        var title: String
        var project: String
        var agent: Agent
        var added = Date()

        static let newLogins = "*new-logins"

        /// Only a verified agent's grant (or any agent's) is ever kept: one for opencode, a command or an unknown
        /// program, even from an older file, counts for nothing.
        var storable: Bool { agent == .any || agent.verified }

        func covers(item: String, project: String, agent: Agent) -> Bool {
            guard self.item == item, storable, agent.verified else { return false }
            guard self.agent == .any || self.agent == agent else { return false }
            let mine = AgentAccess.standard(self.project), theirs = AgentAccess.standard(project)
            return theirs == mine || theirs.hasPrefix(mine == "/" ? "/" : mine + "/")
        }
    }

    static func granted(_ grants: [Grant], item: String, caller: Caller) -> Grant? {
        grants.first { $0.covers(item: item, project: caller.project, agent: caller.agent) }
    }

    /// How a vault use goes on, from the identity Petal read off the socket when the request came in and carried
    /// with it (never looked up again later): Petal's own chats keep the vault's own rules, any other caller is
    /// checked against its grants and asked, and a request that came with no identity is refused.
    enum Gate: Equatable {
        case petal
        case check(Caller)
        case refuse
    }

    static func gate(_ who: Caller?) -> Gate {
        guard let who else { return .refuse }
        return who.agent == .petal ? .petal : .check(who)
    }

    // MARK: petal run

    /// `petal run --key "<title or id>" [--env NAME] [--stdin] … -- <command…>`, read. --env names the variable of
    /// the --key before it; --stdin writes the keys to the command's input (one a line) instead of a variable.
    struct Run: Equatable {
        struct Key: Equatable {
            var ref: String
            var variable: String?
        }
        var keys: [Key] = []
        var stdin = false
        var command: [String] = []
    }

    static let runUsage = "usage: petal run --key \"<title or id>\" [--env NAME] [--stdin] [--key …] -- <command…>"

    static func parseRun(_ args: [String]) -> Result<Run, RunError> {
        var run = Run()
        var index = 0
        func value(_ flag: String) -> String? {
            let word = args[index]
            if word.hasPrefix(flag + "=") { return String(word.dropFirst(flag.count + 1)) }
            guard index + 1 < args.count else { return nil }
            index += 1
            return args[index]
        }
        while index < args.count {
            let word = args[index]
            if word == "--" { run.command = Array(args[(index + 1)...]); break }
            if word == "--key" || word.hasPrefix("--key=") {
                guard let ref = value("--key")?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else { return .failure(.init("--key needs the key's title or id. " + runUsage)) }
                run.keys.append(.init(ref: ref))
            } else if word == "--env" || word.hasPrefix("--env=") {
                guard let name = value("--env"), !name.isEmpty else { return .failure(.init("--env needs a variable's name. " + runUsage)) }
                guard !run.keys.isEmpty else { return .failure(.init("--env goes after the --key it names a variable for. " + runUsage)) }
                guard validVariable(name) else { return .failure(.init("\(name) can't hold a key (a variable is letters, digits and _, and not one like PATH or HOME).")) }
                run.keys[run.keys.count - 1].variable = name
            } else if word == "--stdin" {
                run.stdin = true
            } else if word.hasPrefix("-") {
                return .failure(.init("petal run doesn't know \(word). " + runUsage))
            } else {
                run.command = Array(args[index...])
                break
            }
            index += 1
        }
        guard !run.keys.isEmpty else { return .failure(.init("Say which key with --key. " + runUsage)) }
        guard !run.command.isEmpty else { return .failure(.init("Give the command to run after --. " + runUsage)) }
        let names = run.keys.compactMap(\.variable)
        guard Set(names).count == names.count else { return .failure(.init("Two keys can't go in the same variable.")) }
        return .success(run)
    }

    struct RunError: Error, Equatable {
        let text: String
        init(_ text: String) { self.text = text }
    }

    /// The command as the card shows it: its words, quoted where they have spaces.
    static func commandLine(_ words: [String]) -> String {
        let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%+=:,./_-")
        return words.map { word in
            guard word.isEmpty || !word.unicodeScalars.allSatisfy(plain.contains) else { return word }
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    // MARK: Words

    /// "Codex in T3 Code wants your Anthropic key for “npm test” in ~/petal".
    static func keyQuestion(_ caller: Caller, titles: [String], command: String, home: String) -> String {
        let names = titles.count <= 1 ? (titles.first ?? "") : titles.dropLast().joined(separator: ", ") + " and " + titles.last!
        let what = "your \(names) key\(titles.count == 1 ? "" : "s")"
        let command = clipped(command, 60)
        return "\(caller.label) wants \(what)" + (command.isEmpty ? "" : " for “\(command)”") + " in \(shown(caller.project, home: home))"
    }

    /// "Claude Code in T3 Code wants to fill your github.com login in ~/petal".
    static func fillQuestion(_ caller: Caller, what: String, home: String) -> String {
        "\(caller.label) wants to \(what) in \(shown(caller.project, home: home))"
    }

    /// One line of text, at most `limit` characters.
    static func clipped(_ text: String, _ limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
