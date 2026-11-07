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
    /// agent: the key itself, in hex, percent-encoded (each character as itself or as %XX in either case, as Python's
    /// `quote` and `quote_plus`, JavaScript's `encodeURI` and `encodeURIComponent` and any mix of them write it), and
    /// base64 (standard or URL-safe, at any of the three places it can start in a longer encoding, and wrapped onto
    /// lines as MIME, PEM, `base64.encodebytes` and an indented YAML block write it: the whole span, line breaks and
    /// all). Fed a read at a time: the end of a read that could be the start of a key is held back (`carry`) until the
    /// next read says, so a key split across two reads is still taken out.
    struct Redactor {
        private enum Kind: Hashable {
            /// Byte for byte.
            case plain
            /// Base64: a gap (`gap`) may come between any two of its characters, at most `maxRuns` times, as when an
            /// encoder wraps its lines.
            case wraps
            /// Percent-encoding: each byte as itself, or as %XX (hex in either case), or a space as "+".
            case percent
        }
        private struct Pattern {
            let bytes: [UInt8]
            let replacement: [UInt8]
            let kind: Kind
            var maxRuns: Int { kind == .wraps ? bytes.count / 4 + 1 : 0 }
            /// The most bytes a match can span.
            var span: Int {
                switch kind {
                case .plain: bytes.count
                case .wraps: bytes.count + maxRuns * Redactor.maxGap
                case .percent: bytes.count * 3
                }
            }
            /// The bytes a match can start with.
            var firsts: [UInt8] {
                guard kind == .percent else { return [bytes[0]] }
                return [bytes[0], UInt8(ascii: "%")] + (bytes[0] == 0x20 ? [UInt8(ascii: "+")] : [])
            }
        }
        /// A gap in wrapped base64: up to `maxBlanks` spaces or tabs, then maybe a line break (CRLF, LF or CR) and an
        /// indent of up to `maxIndent` spaces or tabs (a YAML block nested a few levels deep).
        static let maxBlanks = 8
        static let maxIndent = 64
        static let maxGap = maxBlanks + 2 + maxIndent
        /// The shortest key `petal run` hands over: from 16 characters every form (itself, hex, percent-encoded and
        /// base64 at each of its three places) is long enough to be found without taking out ordinary text. Real API
        /// keys are far longer; a shorter one is filled into a field instead.
        static let minimumKey = 16
        static func tooShort(_ secret: String) -> Bool { secret.count < minimumKey || secret.utf8.count < minimumKey }
        static let tooShortText = "This key is too short for Petal to keep out of the command's output; use it by filling it into a field instead (petal_vault, action fill)."
        /// Patterns by the bytes they can start with, longest first.
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
                    all.append(Pattern(bytes: bytes, replacement: replacement, kind: wrapped.contains(form) ? .wraps : .plain))
                }
                // Percent-encoded, in any of the ways encoders write it (the key as itself stays a plain pattern too).
                let bytes = Array(secret.utf8)
                if bytes.count >= 8 { all.append(Pattern(bytes: bytes, replacement: replacement, kind: .percent)) }
            }
            for pattern in all.sorted(by: { $0.bytes.count > $1.bytes.count }) {
                for first in pattern.firsts { byFirst[Int(first)].append(pattern) }
                longest = max(longest, pattern.span)
            }
        }

        /// The ways a key is commonly printed, byte for byte (percent-encoding is matched character by character,
        /// in `compare`). Short keys (under 8 characters) only as themselves, and base64 only where at least 12
        /// characters of it come from the key alone: shorter pieces would take out ordinary text. `petal run` hands
        /// over no key under `minimumKey`, so every key it gives is found in all of these forms.
        static func forms(of secret: String) -> [String] {
            let bytes = Array(secret.utf8)
            guard bytes.count >= 4 else { return [] }
            var out = [secret]
            guard bytes.count >= 8 else { return out }
            out.append(bytes.map { String(format: "%02x", $0) }.joined())
            out.append(bytes.map { String(format: "%02X", $0) }.joined())
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
                if byFirst[Int(buffer[start])].contains(where: { Self.compare($0, buffer, at: start).cut }) { return start }
            }
            return count
        }

        /// The longest of the patterns found at `index` (the key as itself and percent-encoded both fit "…%25" for a
        /// key ending in "%": the encoded one takes the "25" too).
        private func match(_ buffer: [UInt8], at index: Int) -> (Pattern, Int)? {
            var best: (Pattern, Int)?
            for pattern in byFirst[Int(buffer[index])] {
                switch Self.compare(pattern, buffer, at: index) {
                case .match(let length), .longer(let length): if length > best?.1 ?? 0 { best = (pattern, length) }
                case .partial, .none: continue
                }
            }
            return best
        }

        private enum Outcome: Equatable {
            case match(Int), partial, none
            /// Found (this many bytes), and another reading of it, longer, is cut off by the end of what's read so far
            /// (a key ending in "%" before "%25"): held back while more may come, and taken out as found at the end.
            case longer(Int)
            /// What's read so far ends inside a reading that may still be the key.
            var cut: Bool {
                switch self {
                case .partial, .longer: true
                case .match, .none: false
                }
            }
        }

        private static func blank(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

        private static func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            default: nil
            }
        }

        /// `pattern` at `index`: found (and how many bytes it spans), cut off by the end of what's read so far, or not
        /// there. A wrapping pattern skips bounded gaps between its characters; a percent pattern takes each byte as
        /// itself or encoded.
        private static func compare(_ pattern: Pattern, _ buffer: [UInt8], at index: Int) -> Outcome {
            if pattern.kind == .percent { return percent(pattern, buffer, at: index) }
            let count = buffer.count
            var position = index
            var runs = 0
            for (offset, byte) in pattern.bytes.enumerated() {
                if pattern.kind == .wraps, offset > 0 {
                    let before = position
                    var blanks = 0
                    while position < count, blank(buffer[position]) {
                        blanks += 1
                        position += 1
                        if blanks > maxBlanks { return .none }
                    }
                    var broke = false
                    if position < count, buffer[position] == 0x0D { position += 1; broke = true }
                    if position < count, buffer[position] == 0x0A { position += 1; broke = true }
                    if broke {
                        var indent = 0
                        while position < count, blank(buffer[position]) {
                            indent += 1
                            position += 1
                            if indent > maxIndent { return .none }
                        }
                    }
                    if position > before {
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

        /// A percent pattern: each byte of the key as itself, as %XX, or a space as "+". A "%" in the key read as
        /// itself or as "%25" can both fit ("%25" in the output is the key's own "%25", or its "%" encoded), so every
        /// reading is followed at once: the places the next byte of the key may start, at most one more for each "%"
        /// of the key, so it stays bounded by the key's length. The longest reading found wins.
        private static func percent(_ pattern: Pattern, _ buffer: [UInt8], at index: Int) -> Outcome {
            let count = buffer.count
            let sign = UInt8(ascii: "%")
            var positions = [index]
            var cut = false
            for byte in pattern.bytes {
                var next: [Int] = []
                func add(_ position: Int) { if !next.contains(position) { next.append(position) } }
                for position in positions {
                    guard position < count else { cut = true; continue }
                    let found = buffer[position]
                    if found == sign {
                        if position + 2 < count {
                            if let high = hex(buffer[position + 1]), let low = hex(buffer[position + 2]), high << 4 | low == byte { add(position + 3) }
                        } else if position + 1 == count || hex(buffer[position + 1]) == byte >> 4 {
                            // "%" or "%X" at the end: may still be this byte encoded.
                            cut = true
                        }
                    }
                    if found == byte || (byte == 0x20 && found == UInt8(ascii: "+")) { add(position + 1) }
                }
                positions = next
                if positions.isEmpty { return cut ? .partial : .none }
            }
            let length = (positions.max() ?? index) - index
            return cut ? .longer(length) : .match(length)
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

    /// Who signed each agent: its maker's Team ID, the identifier its maker gives the agent, and the identifiers of
    /// the helpers it runs commands through (Codex's `codex-exec-server`), as the installed ones are signed. A program
    /// that only looks like one of these (its name) and isn't signed so is an unknown program.
    static let makers: [Agent: (team: String, identifiers: [String], helpers: [String])] = [
        .claude: ("Q6L2SF6YDW", ["com.anthropic.claude-code"], []),                                               // Anthropic
        .codex: ("2DC432GLL2", ["codex"], ["codex-exec-server", "codex-code-mode-host", "com.openai.codex.rg"]),  // OpenAI
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

        /// What it is in the chain: an agent (one with a maker only when signed by that maker), a program of an
        /// agent's maker that isn't the agent (its helper, or another of its programs), or neither.
        enum Role: Equatable {
            case agent(Agent)
            /// Signed by this agent's maker, under another identifier: never the agent itself, and the walk goes on
            /// to its parent (Codex runs commands through `codex-exec-server`, signed by OpenAI).
            case helper(Agent)
            case other
        }

        var role: Role {
            for (agent, maker) in makers where team == maker.team {
                if let identifier, maker.identifiers.contains(identifier) { return .agent(agent) }
                // A known helper (`helpers`) or another program its maker signed: passed through either way.
                return .helper(agent)
            }
            guard let named = looksLike else { return .other }
            return .agent(makers[named] == nil ? named : .unknown)
        }

        /// The agent it is, when it is one.
        var agent: Agent? {
            if case .agent(let agent) = role { return agent }
            return nil
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
        // The maker whose helpers the walk passed through: only that maker's agent may be above them.
        var through: (agent: Agent, file: String)?
        for process in chain.dropFirst() {
            switch process.role {
            case .other: continue
            case .helper(let maker):
                if let seen = through, seen.agent != maker { return Caller(agent: .unknown, host: host, project: project, program: process.file, pid: pid) }
                through = (maker, process.file)
            case .agent(let agent):
                if agent == .unknown { return Caller(agent: .unknown, host: host, project: project, program: process.file, pid: pid) }
                if let seen = through, seen.agent != agent { return Caller(agent: .unknown, host: host, project: project, program: seen.file, pid: pid) }
                return Caller(agent: agent, host: host, project: project, program: process.file, pid: pid)
            }
        }
        return Caller(agent: .command, host: host, project: project, program: peer.file, pid: pid)
    }

    /// macOS's own programs (a shell, `env`), whose signer Petal doesn't read: never an agent. Not /usr/local or
    /// /opt, where Homebrew puts Claude Code and Codex.
    static func systemProgram(_ path: String) -> Bool {
        ["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/System/"].contains { path.hasPrefix($0) }
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

    /// What's at a folder's `.git`: a repository's own folder, a file pointing at one (a worktree's, a submodule's),
    /// or a symbolic link (anyone can link a folder's `.git` to another project's; git never makes one).
    enum GitMark: Equatable {
        case folder
        case file(String)
        case link
    }

    /// How `project` looks at the disk (AgentCallers.disk reads the real one; the checks hand in their own).
    struct GitFiles: Sendable {
        /// What's at `folder`/.git, without following a link there.
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
                // Never the linked repository's project: only the folder itself.
                case .link: return folder
                }
            }
            guard folder != "/" else { return start }
            folder = (folder as NSString).deletingLastPathComponent
            if folder.isEmpty { folder = "/" }
        }
    }

    /// The main checkout of the worktree at `folder`, whose `.git` file says `gitFile`, only when git itself made it
    /// so: the gitdir it names exists and is an entry in a repository's `.git/worktrees/`, and that entry's own
    /// `gitdir` file points back at this folder's `.git` (every path with its links resolved), a `.git` in this very
    /// folder. A `.git` file anyone can write ("gitdir: ~/trusted/.git/worktrees/x" in a folder of their own), or a
    /// `.git` linked to a real worktree's, never borrows another project's grants; nil, and the project is the folder
    /// itself.
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
        // That .git is this folder's own, not another's reached through a link.
        guard let real = files.real(pointed).map(standard), (real as NSString).lastPathComponent == ".git",
              let mine = files.real(folder).map(standard), (real as NSString).deletingLastPathComponent == mine,
              (here as NSString).deletingLastPathComponent == mine else { return nil }
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

    // MARK: Authorization

    /// What let one vault use go on, carried with it to the moment the secret is used (a field filled, a key handed
    /// to `petal run`), where it's checked again (`stillAllowed`): a card or a grant may have waited minutes on
    /// another card meanwhile.
    struct Authorization: Equatable {
        enum Kind: Equatable {
            /// Petal's own chats: the vault's own rules.
            case petal
            /// The person's Allow once on the card `card`: this one operation only, and never again once it's done.
            case allowOnce(card: String)
            /// A grant (its id): only while the person keeps it, and only while it still covers this use.
            case grant(String)
        }
        var kind: Kind
        /// The one operation (a fill, a `petal run`) it was given for.
        var operation: String
        /// What it lets the agent use: a vault item's id, or `Grant.newLogins`.
        var item: String
    }

    /// Right before a field is filled or a key is handed over: does `authorization` still let `caller` use `item` in
    /// `operation`? A grant must still be among `grants` and cover the item, project and agent; an Allow once only in
    /// the operation it was said for, and not once that operation is done (`spent`: its card).
    static func stillAllowed(_ authorization: Authorization, item: String, caller: Caller, operation: String, grants: [Grant], spent: Set<String>) -> Bool {
        guard authorization.operation == operation, authorization.item == item else { return false }
        switch authorization.kind {
        case .petal: return caller.agent == .petal
        case .allowOnce(let card): return caller.agent != .petal && !spent.contains(card)
        case .grant(let id):
            return grants.first { $0.id == id }?.covers(item: item, project: caller.project, agent: caller.agent) ?? false
        }
    }

    /// The person removed the grant `id`: whether an operation under `authorization`, perhaps waiting on a card, ends.
    static func revokedBy(_ authorization: Authorization, removing id: String) -> Bool {
        authorization.kind == .grant(id)
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

    /// Two keys going in the same variable (two OpenAI keys, both OPENAI_API_KEY by default): what to tell the
    /// agent, or nil when every key has its own. `keys` are each key's title and variable (nil for --stdin).
    static func sameVariable(_ keys: [(title: String, variable: String?)]) -> String? {
        var first: [String: String] = [:]
        for key in keys {
            guard let variable = key.variable else { continue }
            if let other = first[variable] {
                return "“\(other)” and “\(key.title)” would both go in \(variable): say each one's variable with --env NAME after its --key."
            }
            first[variable] = key.title
        }
        return nil
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
