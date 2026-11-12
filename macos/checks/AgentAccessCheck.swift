import Foundation

// Checks AgentAccess.swift: which variable `petal run` puts a key in, taking keys out of what a command prints (as
// themselves, hex, percent-encoded as each encoder writes it, and base64, wrapped onto lines and indented, and split
// across reads), reading `petal run`'s words, two keys in one variable, who's asking from a chain of processes (and
// whose signature is read), which project a folder is (a T3 worktree is its main checkout; a forged `.git` file or a
// linked `.git` is not, checked on throwaway folders in the temporary folder), which grants cover a use (only verified
// agents'), and that a request with no identity is refused. No process or Keychain is read. Run with macos/checks/run.sh.
@main
struct AgentAccessCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if !condition { failures += 1; print("FAIL: \(what) \(detail())") }
    }

    static func main() {
        variables()
        redaction()
        percentForms()
        ambiguousPercent()
        splitReads()
        heldTail()
        wrapped()
        running()
        callers()
        helpers()
        projects()
        worktrees()
        linkedGit()
        systemPrograms()
        grants()
        authorizations()
        shortKeys()
        gates()
        words()
        sameVariable()
        relaying()
        writing()
        answers()
        signals()
        if failures > 0 { print("\(failures) agent access check(s) failed"); exit(1) }
        print("agent access: all checks passed")
    }

    static func variables() {
        expect(AgentAccess.variable(sites: ["console.anthropic.com"], title: "Work") == "ANTHROPIC_API_KEY", "Anthropic by its site")
        expect(AgentAccess.variable(sites: ["https://platform.openai.com/api-keys"], title: "") == "OPENAI_API_KEY", "OpenAI by an address")
        expect(AgentAccess.variable(sites: ["aistudio.google.com"], title: "") == "GEMINI_API_KEY", "Gemini by AI Studio")
        expect(AgentAccess.variable(sites: ["maps.google.com"], title: "Maps") == nil, "another Google key: no guess")
        expect(AgentAccess.variable(sites: ["console.x.ai"], title: "") == "XAI_API_KEY", "xAI by its site")
        expect(AgentAccess.variable(sites: ["netflix.ai"], title: "") == nil, "a name ending like x.ai isn't xAI")
        expect(AgentAccess.variable(sites: [], title: "Grok test key") == "XAI_API_KEY", "xAI by a word of its title")
        expect(AgentAccess.variable(sites: [], title: "GitHub token") == "GITHUB_TOKEN", "GitHub by its title")
        expect(AgentAccess.variable(sites: ["dashboard.stripe.com"], title: "") == "STRIPE_SECRET_KEY", "Stripe by its site")
        expect(AgentAccess.variable(sites: [], title: "Anthropic (staging)") == "ANTHROPIC_API_KEY", "Anthropic by its title")
        expect(AgentAccess.variable(sites: [], title: "Resend") == nil, "a service Petal doesn't know: --env needed")
        expect(AgentAccess.variable(sites: [], title: "openaiish") == nil, "only whole words of the title")
        expect(AgentAccess.validVariable("MY_KEY") && AgentAccess.validVariable("_k2"), "ordinary names")
        expect(!AgentAccess.validVariable("2KEY") && !AgentAccess.validVariable("MY-KEY") && !AgentAccess.validVariable(""), "names a shell refuses")
        expect(!AgentAccess.validVariable("PATH") && !AgentAccess.validVariable("DYLD_INSERT_LIBRARIES") && !AgentAccess.validVariable("home"),
               "names that change how programs run")
    }

    static func redact(_ secrets: [(String, String)], _ text: String) -> String {
        var redactor = AgentAccess.Redactor(secrets.map { (secret: $0.0, label: $0.1) })
        return String(decoding: redactor.feed(Array(text.utf8)) + redactor.finish(), as: UTF8.self)
    }

    static let key = "sk-ant-api03-Abc_def+ghi/JKL0123456789xyz=="

    static func redaction() {
        let label = [(key, "Anthropic")]
        expect(redact(label, "key is \(key)!") == "key is [Anthropic key]!", "the key itself", redact(label, "key is \(key)!"))
        expect(redact(label, "\(key)\(key)") == "[Anthropic key][Anthropic key]", "twice in a row")
        let hex = Array(key.utf8).map { String(format: "%02x", $0) }.joined()
        expect(redact(label, "x=\(hex);") == "x=[Anthropic key];", "in hex")
        expect(redact(label, "X=\(hex.uppercased())") == "X=[Anthropic key]", "in uppercase hex")
        let percent = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
        expect(redact(label, "?k=\(percent)&a=1") == "?k=[Anthropic key]&a=1", "percent-encoded", redact(label, "?k=\(percent)&a=1"))
        expect(redact(label, "?k=\(percent.lowercased().replacingOccurrences(of: "sk-ant", with: "sk-ant"))").contains(key) == false, "lowercase hex in percent-encoding")
        // In base64 at each of the three places a key can start, standard and URL-safe: no piece of it is left
        // that decodes back to the key.
        for prefix in ["", "a", "ab", "Bearer ", "user:"] {
            let encoded = Data((prefix + key).utf8).base64EncodedString()
            let out = redact(label, "Authorization: Basic \(encoded)\n")
            expect(out.contains("[Anthropic key]"), "base64 after \"\(prefix)\"", out)
            expect(!out.contains(String(encoded.dropFirst(4).prefix(20))), "no long run of its base64 left after \"\(prefix)\"", out)
            let safe = encoded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            expect(redact(label, safe).contains("[Anthropic key]"), "URL-safe base64 after \"\(prefix)\"")
        }
        // Two keys, the longer one found whole even when the shorter is in it.
        let two = [("sk-test-0123456789", "Short"), ("sk-test-0123456789-and-more", "Long")]
        expect(redact(two, "a sk-test-0123456789-and-more b sk-test-0123456789") == "a [Long key] b [Short key]", "the longest match first",
               redact(two, "a sk-test-0123456789-and-more b sk-test-0123456789"))
        expect(redact(label, "nothing to see here") == "nothing to see here", "other text untouched")
        expect(redact([("abc", "Tiny")], "abc abc") == "abc abc", "a 3-character secret isn't searched for: it would take out words")
        expect(redact([("pin1", "Pin")], "pin1 and \(Data("pin1".utf8).base64EncodedString())") == "[Pin key] and cGluMQ==", "a short one only as itself")
        expect(AgentAccess.Redactor.forms(of: key).allSatisfy { $0.count >= 12 }, "every form long enough not to take out ordinary text")
        let unicode = "ключ-🔑-0123456789"
        expect(redact([(unicode, "U")], "→\(unicode)←") == "→[U key]←", "a key in any script")
    }

    /// Percent-encoded as each encoder writes it, each keeping a different set of characters as they are (the key
    /// has "/", "+" and "="): Python's `quote` (keeps "/") and `quote_plus` (a space as "+"), JavaScript's
    /// `encodeURIComponent` and `encodeURI` (keeps "/", "+" and "="), in uppercase or lowercase hex, and mixed.
    static func percentForms() {
        func encode(_ text: String, keeping: String, plus: Bool = false, lower: Bool = false) -> String {
            let kept = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" + keeping)
            var out = text.addingPercentEncoding(withAllowedCharacters: kept)!
            if plus { out = out.replacingOccurrences(of: "%20", with: "+") }
            if lower {
                var low = ""
                var rest = Substring(out)
                while let percent = rest.firstIndex(of: "%") {
                    low += rest[..<percent]
                    let end = rest.index(percent, offsetBy: 3)
                    low += rest[percent..<end].lowercased()
                    rest = rest[end...]
                }
                out = low + rest
            }
            return out
        }
        let quote = "_.-~/", quotePlus = "_.-~", component = "-_.!~*'()", uri = "-_.!~*'();,/?:@&=+$#"
        for secret in [key, "my secret/key+=0123"] {
            for (keeping, plus, name) in [(quote, false, "quote"), (quotePlus, true, "quote_plus"), (component, false, "encodeURIComponent"), (uri, false, "encodeURI")] {
                for lower in [false, true] {
                    let encoded = encode(secret, keeping: keeping, plus: plus, lower: lower)
                    let text = "GET https://api.example.com/v1?key=\(encoded)&x=1 200"
                    let out = redact([(secret, "K")], text)
                    expect(out == "GET https://api.example.com/v1?key=[K key]&x=1 200", "\(name)\(lower ? " (lowercase hex)" : "") of \(secret)", out)
                    // And split across two reads anywhere.
                    let bytes = Array(text.utf8)
                    for cut in 1..<bytes.count {
                        var redactor = AgentAccess.Redactor([(secret: secret, label: "K")])
                        let split = redactor.feed(Array(bytes[..<cut])) + redactor.feed(Array(bytes[cut...])) + redactor.finish()
                        if String(decoding: split, as: UTF8.self) != out { expect(false, "\(name) split at \(cut)", String(decoding: split, as: UTF8.self)); break }
                    }
                }
            }
        }
        // Every character encoded, and a mix of encoded and not.
        let all = Array(key.utf8).map { String(format: "%%%02X", $0) }.joined()
        expect(redact([(key, "K")], "[\(all)]") == "[[K key]]", "every character encoded")
        let mixed = Array(key.utf8).enumerated().map { $0.offset % 2 == 0 ? String(format: "%%%02x", $0.element) : String(UnicodeScalar($0.element)) }.joined()
        expect(redact([(key, "K")], mixed) == "[K key]", "a mix of encoded and not", redact([(key, "K")], mixed))
        // Ordinary percent signs and other encoded text stay as they are.
        let plain = "100% done, %2F is a slash, 50%% off, ends with %"
        expect(redact([(key, "K")], plain) == plain, "other percent-encoded text untouched", redact([(key, "K")], plain))
        let near = encode(String(key.dropLast()) + "X", keeping: quote)
        expect(redact([(key, "K")], near) == near, "a different key encoded isn't this one")
    }

    /// A "%" in the key makes "%25" in the output fit two ways (the key's own "%25", or its "%" encoded): every
    /// reading is tried, so neither hides the key.
    static func ambiguousPercent() {
        let secret = "%25-test-0123456789/="
        let forms = ["%25-test-0123456789%2F=", "%25-test-0123456789/=", "%2525-test-0123456789/=", "%2525-test-0123456789%2F%3D",
                     "%%32%35-test-0123456789/=", "%25%32%35-test-0123456789/=", "%2525%2Dtest-0123456789%2f%3d",
                     Array(secret.utf8).map { String(format: "%%%02X", $0) }.joined()]
        for form in forms {
            let text = "GET /v1?key=\(form)&x=1"
            let out = redact([(secret, "K")], text)
            expect(out == "GET /v1?key=[K key]&x=1", "\(form) for \(secret)", out)
            let bytes = Array(text.utf8)
            for cut in 1..<bytes.count {
                var redactor = AgentAccess.Redactor([(secret: secret, label: "K")])
                let split = String(decoding: redactor.feed(Array(bytes[..<cut])) + redactor.feed(Array(bytes[cut...])) + redactor.finish(), as: UTF8.self)
                if split != out { expect(false, "\(form) split at \(cut)", split); break }
            }
        }
        let near = "%25-test-0123456789%2F%3E"
        expect(redact([(secret, "K")], near) == near, "a near miss stays")
        // A key ending in "%": the longest reading is taken out, and one cut off at the very end still is.
        let ends = "0123456789abcdef%"
        expect(redact([(ends, "K")], "a 0123456789abcdef%25 b") == "a [K key] b", "a final % encoded", redact([(ends, "K")], "a 0123456789abcdef%25 b"))
        expect(redact([(ends, "K")], "a 0123456789abcdef% b") == "a [K key] b", "a final % as itself")
        expect(redact([(ends, "K")], "0123456789abcdef%2") == "[K key]2", "a final % before the end of the output", redact([(ends, "K")], "0123456789abcdef%2"))
        expect(redact([(ends, "K")], "0123456789abcdef%") == "[K key]", "a final % at the end of the output")
        // Two in a row, and a "%25" right after one.
        let double = "ab%%cd-0123456789"
        for form in ["ab%%cd-0123456789", "ab%25%cd-0123456789", "ab%%25cd-0123456789", "ab%25%25cd-0123456789"] {
            expect(redact([(double, "K")], "<\(form)>") == "<[K key]>", "\(form) for \(double)", redact([(double, "K")], "<\(form)>"))
        }
        let pct = "%2525252525-0123456789"
        expect(redact([(pct, "K")], "<%252525252525-0123456789>") == "<[K key]>", "the key's own %25s, its first % encoded")
    }

    /// What the redactor holds back at the end of a read (it could start a key) comes out whole when the output is
    /// over, as `petal run` passes it on when it stops listening.
    static func heldTail() {
        let secret = "q0123456789abcdefg"
        expect(AgentAccess.Redactor.base64Forms(of: secret).first?.first == "c", "the key's base64 starts with c")
        var redactor = AgentAccess.Redactor([(secret: secret, label: "K")])
        let fed = redactor.feed(Array("public\n".utf8))
        let rest = redactor.finish()
        expect(String(decoding: fed, as: UTF8.self) == "publi", "a possible key's start is held", String(decoding: fed, as: UTF8.self))
        expect(String(decoding: fed + rest, as: UTF8.self) == "public\n", "finish passes the held tail on", String(decoding: fed + rest, as: UTF8.self))
        var masked = AgentAccess.Redactor([(secret: secret, label: "K")])
        let half = masked.feed(Array("x \(secret)".utf8))
        expect(String(decoding: half + masked.finish(), as: UTF8.self) == "x [K key]", "a key at the very end is masked by finish")
    }

    /// The command's output arrives a read at a time: a key split anywhere across reads, or arriving a byte at a
    /// time, is still taken out, and nothing of the text around it is lost, doubled or held back once it's over.
    static func splitReads() {
        let text = "start \(key) middle \(Data(("x" + key).utf8).base64EncodedString()) end"
        let whole = redact([(key, "K")], text)
        let bytes = Array(text.utf8)
        for cut in stride(from: 1, to: bytes.count, by: 3) {
            var redactor = AgentAccess.Redactor([(secret: key, label: "K")])
            let out = redactor.feed(Array(bytes[..<cut])) + redactor.feed(Array(bytes[cut...])) + redactor.finish()
            expect(String(decoding: out, as: UTF8.self) == whole, "split at \(cut)", String(decoding: out, as: UTF8.self))
        }
        var redactor = AgentAccess.Redactor([(secret: key, label: "K")])
        var out: [UInt8] = []
        var leaked = false
        var shown: [UInt8] = []
        for byte in bytes {
            let part = redactor.feed([byte])
            out += part
            shown += part
            if String(decoding: shown, as: UTF8.self).contains("sk-ant-api03-Abc") { leaked = true }
        }
        out += redactor.finish()
        expect(String(decoding: out, as: UTF8.self) == whole, "a byte at a time")
        expect(!leaked, "no start of the key passed on before it's known not to be the key")
        // Ordinary text isn't held back: what can't start a key goes on at once.
        var quick = AgentAccess.Redactor([(secret: key, label: "K")])
        expect(quick.feed(Array("Enter a value: ".utf8)) == Array("Enter a value: ".utf8), "a prompt with no key in it goes on at once")
        expect(quick.feed(Array("sk-a".utf8)).isEmpty, "the start of a key waits")
        expect(quick.feed(Array("bc.\n".utf8)) == Array("sk-abc.\n".utf8), "and goes on once it isn't one")
        // A line ending in what could start the key's wrapped base64 waits for the next read, or the end.
        var line = AgentAccess.Redactor([(secret: key, label: "K")])
        let ending = AgentAccess.Redactor.base64Forms(of: key)[0].prefix(3) + "\n"
        let passed = line.feed(Array("ok ".utf8) + Array(ending.utf8))
        expect(String(decoding: passed + line.finish(), as: UTF8.self) == "ok " + ending, "and is passed on whole at the end")
    }

    /// Base64 wrapped onto lines (MIME's CRLF every 76, `base64.encodebytes`' LF every 76, PEM's every 64, an indented
    /// YAML block): the whole span, breaks and all, is taken out, whole or split across reads at any point.
    static func wrapped() {
        let long = "sk-proj-" + String(repeating: "Ab3_Xy9-Qz7+Lm2/", count: 6)
        func wrap(_ text: String, every: Int, with separator: String) -> String {
            var out: [String] = []
            var rest = Substring(text)
            while !rest.isEmpty { out.append(String(rest.prefix(every))); rest = rest.dropFirst(every) }
            return out.joined(separator: separator)
        }
        for prefix in ["", "a", "ab", "Bearer ", "user:"] {
            let encoded = Data((prefix + long).utf8).base64EncodedString()
            let yaml = "\n" + String(repeating: " ", count: 8), deep = "\n" + String(repeating: " ", count: 24)
            for (every, separator, name) in [(76, "\r\n", "MIME"), (76, "\n", "encodebytes"), (64, "\n", "PEM"), (40, "\n    ", "indented"), (20, " ", "spaced"),
                                             (76, yaml, "YAML, 8 spaces"), (76, deep, "YAML, 24 spaces"), (76, "\r\n" + String(repeating: " ", count: 12), "CRLF and an indent"),
                                             (76, "\n\t\t\t", "tabs"), (76, "  \n      ", "trailing blanks and an indent")] {
                let body = wrap(encoded, every: every, with: separator)
                let text = "data:\n" + body + "\nend\n"
                let whole = redact([(long, "K")], text)
                expect(whole.contains("[K key]"), "\(name) after \"\(prefix)\"", whole)
                // Nothing of the key's own base64 is left on any line.
                let lines = whole.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " })
                expect(!lines.contains { $0.count >= 12 && !$0.contains("[") && encoded.contains($0) }, "no line of it left: \(name) after \"\(prefix)\"", whole)
                expect(whole.hasPrefix("data:\n") && whole.hasSuffix("\nend\n"), "what's around it untouched: \(name)", whole)
                let bytes = Array(text.utf8)
                for cut in stride(from: 1, to: bytes.count, by: 7) {
                    var redactor = AgentAccess.Redactor([(secret: long, label: "K")])
                    let out = redactor.feed(Array(bytes[..<cut])) + redactor.feed(Array(bytes[cut...])) + redactor.finish()
                    expect(String(decoding: out, as: UTF8.self) == whole, "\(name) after \"\(prefix)\" split at \(cut)")
                }
            }
        }
        // A byte at a time, MIME: the same, and no long run of it passed on before it's known.
        let mime = wrap(Data(("x" + long).utf8).base64EncodedString(), every: 76, with: "\r\n")
        let text = "Content-Transfer-Encoding: base64\r\n\r\n" + mime + "\r\n"
        let whole = redact([(long, "K")], text)
        var redactor = AgentAccess.Redactor([(secret: long, label: "K")])
        var shown: [UInt8] = []
        for byte in Array(text.utf8) { shown += redactor.feed([byte]) }
        shown += redactor.finish()
        expect(String(decoding: shown, as: UTF8.self) == whole && whole.contains("[K key]"), "MIME a byte at a time", String(decoding: shown, as: UTF8.self))
        // Bounded: whitespace between every character, or a run longer than a line break and its indent, isn't a
        // wrapped key (ordinary text with gaps stays as it is).
        let core = AgentAccess.Redactor.base64Forms(of: long)[0]
        let spread = core.map(String.init).joined(separator: " ")
        expect(redact([(long, "K")], spread) == spread, "a gap after every character isn't how base64 wraps")
        let half = core.index(core.startIndex, offsetBy: core.count / 2)
        let gap = String(core[..<half]) + String(repeating: " ", count: 9) + String(core[half...])
        expect(redact([(long, "K")], gap) == gap, "nor a gap of more than 8 blanks on one line")
        let indent = String(core[..<half]) + "\n" + String(repeating: " ", count: 65) + String(core[half...])
        expect(redact([(long, "K")], indent) == indent, "nor an indent deeper than 64")
        let blankLine = String(core[..<half]) + "\n\n" + String(core[half...])
        expect(redact([(long, "K")], blankLine) == blankLine, "nor a blank line between")
        expect(redact([(long, "K")], "plain words, with\nline breaks and  spaces") == "plain words, with\nline breaks and  spaces", "ordinary text untouched")
    }

    static func running() {
        func parse(_ words: [String]) -> AgentAccess.Run? { try? AgentAccess.parseRun(words).get() }
        let one = parse(["--key", "Anthropic", "--", "npm", "test"])
        expect(one == AgentAccess.Run(keys: [.init(ref: "Anthropic")], command: ["npm", "test"]), "one key, a command after --")
        let two = parse(["--key=OpenAI", "--env", "MY_KEY", "--key", "id-2", "--stdin", "node", "app.js", "--key", "x"])
        expect(two?.keys == [.init(ref: "OpenAI", variable: "MY_KEY"), .init(ref: "id-2")], "--env names the key before it")
        expect(two?.stdin == true && two?.command == ["node", "app.js", "--key", "x"], "the command's own words stay its own")
        if case .success = AgentAccess.parseRun(["--", "ls"]) { expect(false, "no key: refused") }
        if case .success = AgentAccess.parseRun(["--key", "A"]) { expect(false, "no command: refused") }
        if case .success = AgentAccess.parseRun(["--env", "X", "--key", "A", "--", "ls"]) { expect(false, "--env before any key: refused") }
        if case .success = AgentAccess.parseRun(["--key", "A", "--env", "PATH", "--", "ls"]) { expect(false, "PATH: refused") }
        if case .success = AgentAccess.parseRun(["--key", "A", "--env", "K", "--key", "B", "--env", "K", "--", "ls"]) { expect(false, "one variable twice: refused") }
        if case .success = AgentAccess.parseRun(["--key", "A", "--print", "--", "ls"]) { expect(false, "a flag it doesn't know: refused") }
        expect(AgentAccess.commandLine(["npm", "run", "test it", "it's"]) == "npm run 'test it' 'it'\\''s'", "the command as the card shows it",
               AgentAccess.commandLine(["npm", "run", "test it", "it's"]))
    }

    static func callers() {
        typealias P = AgentAccess.Process
        let t3 = "/Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)"
        let petal = "/Applications/Petal.app/Contents/MacOS/Petal"
        let claude = P(pid: 20, path: "/Users/me/.hermes/node/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe",
                       team: "Q6L2SF6YDW", identifier: "com.anthropic.claude-code")
        let codex = P(pid: 21, path: "/Users/me/.codex/packages/standalone/releases/0.167.0-aarch64-apple-darwin/bin/codex",
                      team: "2DC432GLL2", identifier: "codex")
        let zsh = P(pid: 30, path: "/bin/zsh")
        let host = [P(pid: 10, path: t3), P(pid: 9, path: t3)]
        let run = P(pid: 40, path: petal)

        let viaClaude = AgentAccess.caller(chain: [run, zsh, claude] + host, petalPID: 5, peerIsPetal: true, project: "/p")
        expect(viaClaude.agent == .claude && viaClaude.host == "T3 Code" && viaClaude.label == "Claude Code in T3 Code" && viaClaude.pid == 40,
               "petal run in a shell under Claude Code in T3 Code", viaClaude.label)
        let viaCodex = AgentAccess.caller(chain: [P(pid: 41, path: petal), codex] + host, petalPID: 5, peerIsPetal: true, project: "/p")
        expect(viaCodex.agent == .codex && viaCodex.label == "Codex in T3 Code" && viaCodex.grantable, "Petal --mcp under Codex")
        // Claude Code's own installer names its binary by version.
        let versioned = P(pid: 22, path: "/Users/me/.local/share/claude/versions/2.1.3", team: "Q6L2SF6YDW", identifier: "com.anthropic.claude-code")
        let terminal = P(pid: 8, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        let inTerminal = AgentAccess.caller(chain: [run, zsh, versioned, P(pid: 7, path: "/usr/bin/login"), terminal], petalPID: 5, peerIsPetal: true, project: "/p")
        expect(inTerminal.label == "Claude Code in Terminal", "Claude Code in Terminal, its binary named by version", inTerminal.label)
        // A program named like an agent but not signed by its maker is an unknown program, never that agent.
        let fake = P(pid: 23, path: "/tmp/claude", team: nil, identifier: nil)
        let faked = AgentAccess.caller(chain: [run, fake] + host, petalPID: 5, peerIsPetal: true, project: "/p")
        expect(faked.agent == .unknown && faked.label == "An unknown program (claude)" && !faked.grantable, "a fake claude", faked.label)
        let otherTeam = P(pid: 24, path: claude.path, team: "ABCDE12345", identifier: "com.anthropic.claude-code")
        expect(AgentAccess.caller(chain: [run, otherTeam], petalPID: 5, peerIsPetal: true, project: "/p").agent == .unknown, "Claude's name, another team")
        let wrongID = P(pid: 25, path: "/x/helper", team: "Q6L2SF6YDW", identifier: "com.anthropic.claudefordesktop")
        let other = AgentAccess.caller(chain: [run, wrongID, zsh], petalPID: 5, peerIsPetal: true, project: "/p")
        expect(other.agent == .command && !other.grantable, "Anthropic's other apps aren't Claude Code")
        // Any program can start the real `petal run`: with no verified agent above it, it's a command, allowed once.
        let launcher = AgentAccess.caller(chain: [run, P(pid: 27, path: "/Users/me/Downloads/helper")] + host, petalPID: 5, peerIsPetal: true, project: "/p")
        expect(launcher.agent == .command && !launcher.grantable, "an unrelated program running petal run: a command, never Always")
        // What connected isn't Petal's own code: an unknown program, whatever is above it.
        let netcat = AgentAccess.caller(chain: [P(pid: 50, path: "/usr/bin/nc"), zsh, claude] + host, petalPID: 5, peerIsPetal: false, project: "/p")
        expect(netcat.agent == .unknown && netcat.label == "An unknown program (nc)" && !netcat.peerIsPetal, "nc on the socket", netcat.label)
        ownChats()
        // No agent above: the person's own command.
        let mine = AgentAccess.caller(chain: [run, zsh, P(pid: 7, path: "/usr/bin/login"), terminal], petalPID: 5, peerIsPetal: true, project: "/p")
        expect(mine.agent == .command && mine.label == "A command in Terminal", "a command typed in Terminal", mine.label)
        let opencode = AgentAccess.caller(chain: [run, P(pid: 26, path: "/Users/me/.opencode/bin/opencode")] + host, petalPID: 5, peerIsPetal: true, project: "/p")
        expect(opencode.agent == .opencode && !opencode.grantable, "opencode by its name only: allowed once, never Always")
        let anyOpencode = AgentAccess.caller(chain: [run, P(pid: 28, path: "/tmp/x/opencode")] + host, petalPID: 5, peerIsPetal: true, project: "/p")
        expect(anyOpencode.agent == .opencode && !anyOpencode.grantable, "an unsigned binary named opencode: never Always")
        expect(!mine.grantable, "a command typed in Terminal: never Always")
        expect(AgentAccess.hostApp([P(pid: 1, path: "/Applications/iTerm.app/Contents/MacOS/iTerm2")]) == "iTerm", "iTerm")
        expect(AgentAccess.hostApp([P(pid: 1, path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)")])
               == "Visual Studio Code", "the outermost app, not a helper")
        expect(AgentAccess.hostApp([zsh]) == nil, "no app")
    }

    /// Petal's own chats: only the tool process an AI started itself, where that AI is the very process Petal started
    /// for the chat (its pid and start, as Petal recorded them) and is signed by its maker. Petal somewhere above is
    /// never enough: a shell, a hook, another tool server or a command the chat runs is the agent's, asked as it is
    /// anywhere else; the chat is the one Petal recorded, whatever the caller says; and `petal run` is never Petal AI.
    static func ownChats() {
        typealias P = AgentAccess.Process
        typealias S = AgentAccess.Started
        let petal = "/Applications/Petal.app/Contents/MacOS/Petal"
        let dock = P(pid: 5, path: petal)
        let tool = P(pid: 60, path: petal)
        let claudePath = "/Users/me/.local/share/claude/versions/2.1.144"
        let chat = P(pid: 20, path: claudePath, team: "Q6L2SF6YDW", identifier: "com.anthropic.claude-code", start: 1_000)
        let codexPath = "/Users/me/.codex/packages/standalone/releases/0.167.0-aarch64-apple-darwin/bin/codex"
        let codexChat = P(pid: 21, path: codexPath, team: "2DC432GLL2", identifier: "codex", start: 2_000)
        let records = [S(pid: 20, start: 1_000, note: "note-1"), S(pid: 21, start: 2_000, note: "note-2")]
        let zsh = P(pid: 30, path: "/bin/zsh"), sh = P(pid: 31, path: "/bin/sh"), node = P(pid: 32, path: "/opt/homebrew/bin/node")
        func ask(_ chain: [P], started: [S] = records, tools: Bool = true) -> AgentAccess.Caller {
            AgentAccess.caller(chain: chain, petalPID: 5, peerIsPetal: true, project: "/p", started: started, tools: tools)
        }
        let own = ask([tool, chat, dock])
        expect(own.agent == .petal && own.label == "Petal AI" && !own.grantable && own.note == "note-1", "the tools of an AI Petal started: its chat's", "\(own)")
        expect(ask([tool, codexChat, dock]).note == "note-2", "each chat by its own process")
        expect(AgentAccess.gate(own) == .petal, "and the vault's own rules")
        // Further down than the AI's own tool process: the agent's, never Petal AI, and no chat's.
        let hook = ask([tool, sh, P(pid: 33, path: "/Users/me/.claude/hooks/x"), chat, dock])
        expect(hook.agent == .claude && hook.note == nil && hook.label == "Claude Code in Petal", "a hook's program under the chat", "\(hook)")
        let server = ask([tool, node, chat, dock])
        expect(server.agent == .claude && server.note == nil, "another tool server under the chat", "\(server)")
        let command = ask([tool, sh, node, zsh, chat, dock])
        expect(command.agent == .claude && command.note == nil, "a command the chat runs, and what that runs", "\(command)")
        if case .check = AgentAccess.gate(command) {} else { expect(false, "what a chat runs is checked like any agent outside Petal") }
        // Anything Petal started that isn't Claude Code or Codex signed by its maker.
        let stray = P(pid: 40, path: "/Users/me/Downloads/claude", start: 3_000)
        let unsigned = ask([tool, stray, dock], started: [S(pid: 40, start: 3_000, note: "note-3")])
        expect(unsigned.agent != .petal && unsigned.note == nil && !unsigned.grantable, "a program named like Claude Code that Petal started", "\(unsigned)")
        let plain = P(pid: 41, path: "/Users/me/Downloads/x", start: 3_000)
        let other = ask([tool, plain, dock], started: [S(pid: 41, start: 3_000, note: "note-3")])
        expect(other.agent == .command && other.note == nil, "any other program Petal started", "\(other)")
        let otherTeam = P(pid: 42, path: claudePath, team: "ABCDE12345", identifier: "com.anthropic.claude-code", start: 3_000)
        expect(ask([tool, otherTeam, dock], started: [S(pid: 42, start: 3_000, note: "note-3")]).agent == .unknown, "Claude Code's name, another team")
        // The real agent, but not a process Petal recorded: never by Petal being above it.
        expect(ask([tool, chat, dock], started: []).agent == .claude, "an agent Petal has no record of")
        expect(ask([tool, chat, dock], started: [S(pid: 20, start: 999, note: "note-1")]).agent == .claude, "a pid Petal recorded for an earlier process")
        let unread = P(pid: 20, path: claudePath, team: "Q6L2SF6YDW", identifier: "com.anthropic.claude-code")
        expect(ask([tool, unread, dock], started: [S(pid: 20, start: 0, note: "note-1")]).agent == .claude, "a start Petal couldn't read matches nothing")
        expect(ask([tool, chat, zsh, dock]).agent == .claude, "the recorded process must be Petal's own child")
        expect(ask([tool, chat, P(pid: 6, path: petal)]).agent == .claude, "and under this Petal, not another")
        // What Petal started is the agent's launcher (npm's codex is a script): the signed agent right under it.
        let launcher = P(pid: 50, path: "/opt/homebrew/bin/node", start: 4_000)
        let launched = [S(pid: 50, start: 4_000, note: "note-4")]
        let native = P(pid: 51, path: "/opt/homebrew/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex", team: "2DC432GLL2", identifier: "codex", start: 4_001)
        expect(ask([tool, native, launcher, dock], started: launched).note == "note-4", "the signed agent its launcher started")
        expect(ask([tool, zsh, native, launcher, dock], started: launched).agent == .codex, "a command under it is still the agent's")
        expect(ask([tool, P(pid: 52, path: "/Users/me/x"), launcher, dock], started: launched).agent == .command, "the launcher's other children aren't the agent")
        expect(ask([tool, native, chat, dock]).agent == .codex, "an agent another agent started is itself, not the chat")
        // `petal run` is never Petal AI: it's the agent that ran it, asked and granted as that agent.
        let run = ask([tool, chat, dock], tools: false)
        expect(run.agent == .claude && run.note == nil && run.grantable && run.label == "Claude Code in Petal", "petal run right under the chat's AI", "\(run)")
        let deeper = ask([tool, zsh, chat, dock], tools: false)
        expect(deeper.agent == .claude && deeper.grantable, "petal run in the chat's shell", "\(deeper)")
        let grant = AgentAccess.Grant(item: "k1", title: "Anthropic", project: "/p", agent: .claude)
        expect(AgentAccess.granted([grant], item: "k1", caller: run) != nil && AgentAccess.granted([grant], item: "k1", caller: own) == nil,
               "a grant for Claude Code in the project covers it; nothing is granted to Petal AI")
        // What connected isn't Petal's own code: an unknown program, wherever it runs.
        let nc = AgentAccess.caller(chain: [P(pid: 61, path: "/usr/bin/nc"), chat, dock], petalPID: 5, peerIsPetal: false, project: "/p", started: records)
        expect(nc.agent == .unknown && nc.note == nil && !nc.peerIsPetal, "nc under the chat's AI", "\(nc)")
    }

    /// A made-up disk: `marks` by folder, every path real as written, `files` by path.
    /// Codex runs commands through its own helpers (`codex-exec-server`), signed by OpenAI under their own
    /// identifiers: the walk passes through them to the signed Codex above, never taking a helper for the agent.
    static func helpers() {
        typealias P = AgentAccess.Process
        let t3 = "/Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)"
        let host = [P(pid: 10, path: t3), P(pid: 9, path: t3)]
        let run = P(pid: 40, path: "/Applications/Petal.app/Contents/MacOS/Petal")
        let zsh = P(pid: 30, path: "/bin/zsh")
        let bin = "/Users/me/.codex/packages/standalone/releases/0.167.0-aarch64-apple-darwin/bin/"
        let codex = P(pid: 21, path: bin + "codex", team: "2DC432GLL2", identifier: "codex")
        let claude = P(pid: 20, path: "/Users/me/.local/share/claude/versions/2.1.144", team: "Q6L2SF6YDW", identifier: "com.anthropic.claude-code")
        func helper(_ identifier: String?, team: String? = "2DC432GLL2", file: String = "codex-exec-server") -> P {
            P(pid: 31, path: bin + file, team: team, identifier: identifier)
        }
        let server = helper("codex-exec-server")
        expect(server.role == .helper(.codex) && server.agent == nil, "codex-exec-server is Codex's helper, not Codex")
        let through = AgentAccess.caller(chain: [run, zsh, server, codex] + host, petalPID: 5, peerIsPetal: true, project: "/p")
        expect(through.agent == .codex && through.label == "Codex in T3 Code" && through.grantable && through.program == "codex",
               "a command run through codex-exec-server is Codex's", through.label)
        for identifier in AgentAccess.makers[.codex]!.helpers {
            let found = AgentAccess.caller(chain: [run, helper(identifier, file: identifier), zsh, codex], petalPID: 5, peerIsPetal: true, project: "/p")
            expect(found.agent == .codex, "through Codex's \(identifier)", found.label)
        }
        let newer = AgentAccess.caller(chain: [run, helper("codex-sandbox-runner", file: "codex-sandbox-runner"), codex], petalPID: 5, peerIsPetal: true, project: "/p")
        expect(newer.agent == .codex, "a helper OpenAI signs that Petal doesn't know yet passes through too", newer.label)
        let twice = AgentAccess.caller(chain: [run, helper("com.openai.codex.rg", file: "rg"), zsh, server, codex], petalPID: 5, peerIsPetal: true, project: "/p")
        expect(twice.agent == .codex, "through two of Codex's helpers", twice.label)
        // Signed by anyone else, or not at all: it stops the walk, whatever is above it.
        let forged = AgentAccess.caller(chain: [run, helper("codex-exec-server", team: "ABCDE12345"), codex] + host, petalPID: 5, peerIsPetal: true, project: "/p")
        expect(forged.agent == .unknown && forged.program == "codex-exec-server" && !forged.grantable, "another team's codex-exec-server stops it", forged.label)
        let unsigned = AgentAccess.caller(chain: [run, helper(nil, team: nil), codex], petalPID: 5, peerIsPetal: true, project: "/p")
        expect(unsigned.agent == .unknown, "an unsigned codex-exec-server stops it", unsigned.label)
        // A helper is never the agent: with no Codex above, a command.
        let alone = AgentAccess.caller(chain: [run, zsh, server] + host, petalPID: 5, peerIsPetal: true, project: "/p")
        expect(alone.agent == .command && !alone.grantable, "codex-exec-server with no Codex above isn't Codex", alone.label)
        // One maker's helper never leads to another maker's agent.
        let crossed = AgentAccess.caller(chain: [run, server, zsh, claude] + host, petalPID: 5, peerIsPetal: true, project: "/p")
        expect(crossed.agent == .unknown && !crossed.grantable, "OpenAI's helper under Claude Code", crossed.label)
        // Claude Code's own helper-like program from Anthropic, under Claude Code.
        let desktop = P(pid: 32, path: "/Applications/Claude.app/Contents/Helpers/chrome-native-host", team: "Q6L2SF6YDW", identifier: "chrome-native-host")
        let anthropic = AgentAccess.caller(chain: [run, desktop, claude], petalPID: 5, peerIsPetal: true, project: "/p")
        expect(anthropic.agent == .claude, "another Anthropic program passes through to Claude Code", anthropic.label)
    }

    static func fake(_ marks: [String: AgentAccess.GitMark], files: [String: String] = [:], real: Set<String> = []) -> AgentAccess.GitFiles {
        AgentAccess.GitFiles(mark: { marks[$0] }, real: { path in
            let path = AgentAccess.standard(path)
            return real.contains(path) || marks[path] != nil || files[path] != nil ? path : nil
        }, read: { files[AgentAccess.standard($0)] })
    }

    static func projects() {
        let disk = fake(["/Users/me/petal": .folder, "/Users/me/app/vendor/lib": .file("gitdir: ../../.git/modules/lib"), "/Users/me/app": .folder])
        expect(AgentAccess.project("/Users/me/petal/macos/Sources", files: disk) == "/Users/me/petal", "a subfolder: its repository")
        expect(AgentAccess.project("/Users/me/app/vendor/lib/src", files: disk) == "/Users/me/app/vendor/lib", "a submodule is its own project")
        expect(AgentAccess.project("/Users/me/notes/drafts", files: disk) == "/Users/me/notes/drafts", "no repository: the folder itself")
        expect(AgentAccess.project("/Users/me/petal/./macos/../", files: disk) == "/Users/me/petal", "dots and slashes tidied")
        expect(AgentAccess.shown("/Users/me/petal", home: "/Users/me") == "~/petal" && AgentAccess.shown("/opt/x", home: "/Users/me") == "/opt/x",
               "shown from the home folder")
        expect(AgentAccess.shown("/Users/mead", home: "/Users/me") == "/Users/mead", "another person's folder isn't under home")
        expect(AgentAccess.tooBroad("/", home: "/Users/me") && AgentAccess.tooBroad("/Users/me/", home: "/Users/me") && AgentAccess.tooBroad("/Users", home: "/Users/me"),
               "home and above are too much for one grant")
        expect(!AgentAccess.tooBroad("/Users/me/petal", home: "/Users/me"), "a project isn't")
    }

    /// Worktrees on throwaway folders (the real disk, through AgentCallers.disk): a real one is its main checkout; a
    /// `.git` file anyone wrote, pointing at a trusted repository's worktree entry, is only its own folder.
    static func worktrees() {
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appending(path: "petal-agent-check-\(UUID().uuidString)").path
        try? fm.createDirectory(atPath: made, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: made) }
        guard let root = AgentCallers.realPath(made) else { return expect(false, "a throwaway folder") }
        func folder(_ path: String) { try? fm.createDirectory(atPath: root + "/" + path, withIntermediateDirectories: true) }
        func file(_ path: String, _ text: String) { try? text.write(toFile: root + "/" + path, atomically: true, encoding: .utf8) }
        func project(_ path: String) -> String { AgentAccess.project(root + "/" + path, files: AgentCallers.disk) }

        // The trusted repository and a real worktree of it, made as git makes them (absolute paths both ways).
        folder("trusted/.git/worktrees/wt")
        folder("wt/src")
        file("wt/.git", "gitdir: \(root)/trusted/.git/worktrees/wt\n")
        file("trusted/.git/worktrees/wt/gitdir", "\(root)/wt/.git\n")
        expect(project("wt/src") == root + "/trusted", "a real worktree: its main checkout", project("wt/src"))
        expect(project("trusted") == root + "/trusted", "the main checkout itself")
        // Git 2.48's relative paths, both ways.
        folder("trusted/.git/worktrees/rel")
        folder("side/rel")
        file("side/rel/.git", "gitdir: ../../trusted/.git/worktrees/rel\n")
        file("trusted/.git/worktrees/rel/gitdir", "../../../../side/rel/.git\n")
        expect(project("side/rel") == root + "/trusted", "a worktree with relative links", project("side/rel"))
        // Reached through a symbolic link to the worktree: the same project.
        try? fm.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/wt")
        expect(AgentAccess.project(AgentCallers.realPath(root + "/link/src") ?? "", files: AgentCallers.disk) == root + "/trusted", "through a link")

        // Forged: a folder of anyone's pointing at the real worktree's entry, which points back at wt, not here.
        folder("evil/sub")
        file("evil/.git", "gitdir: \(root)/trusted/.git/worktrees/wt\n")
        expect(project("evil/sub") == root + "/evil", "a forged .git file naming a real worktree entry: its own folder", project("evil/sub"))

        // The git repository a note's file is really in (AgentAccess.repository, what a file's note is routed by): a
        // file under a linked worktree is in its main checkout's repository; a forged `.git` file is in none.
        func repository(_ path: String) -> String? { AgentAccess.repository(root + "/" + path, files: AgentCallers.disk) }
        expect(repository("wt/src") == root + "/trusted", "a file in a linked worktree: its repository is the main checkout", repository("wt/src") ?? "nil")
        expect(repository("side/rel") == root + "/trusted" && repository("trusted") == root + "/trusted", "a worktree with relative links, and the main checkout itself")
        expect(repository("evil/sub") == nil, "a forged .git file: no repository (never coding in the one it names)", repository("evil/sub") ?? "nil")
        folder("loose/docs")
        expect(repository("loose/docs") == nil, "a folder in no repository: none", repository("loose/docs") ?? "nil")
        try? fm.createSymbolicLink(atPath: root + "/loose/.git", withDestinationPath: root + "/trusted/.git")
        expect(repository("loose/docs") == nil, "a .git that is a symbolic link is never followed")
        // The same with a repository and a linked worktree git itself made (when git is here).
        if fm.isExecutableFile(atPath: "/usr/bin/git") {
            func git(_ arguments: [String]) -> Bool {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-c", "user.name=check", "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false"] + arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return false }
                process.waitUntilExit()
                return process.terminationStatus == 0
            }
            folder("made")
            if git(["init", "-q", root + "/made/repo"]), git(["-C", root + "/made/repo", "commit", "-q", "--allow-empty", "-m", "start"]),
               git(["-C", root + "/made/repo", "worktree", "add", "-q", "-b", "linked", root + "/made/linked"]) {
                folder("made/linked/Sources")
                expect(repository("made/linked/Sources") == root + "/made/repo", "git's own linked worktree: a file in it routes to its main checkout's repository",
                       repository("made/linked/Sources") ?? "nil")
                expect(repository("made/repo") == root + "/made/repo", "and git's own main checkout is itself")
            } else {
                expect(false, "git made a repository and a linked worktree in the throwaway folder")
            }
        }
        // Forged: an entry that doesn't exist.
        folder("ghost")
        file("ghost/.git", "gitdir: \(root)/trusted/.git/worktrees/none\n")
        expect(project("ghost") == root + "/ghost", "an entry that isn't there: its own folder")
        // Forged: the repository's own .git, or something else in it, rather than a worktree entry.
        folder("plain")
        file("plain/.git", "gitdir: \(root)/trusted/.git\n")
        expect(project("plain") == root + "/plain", "the repository's .git itself isn't a worktree entry")
        folder("dots")
        file("dots/.git", "gitdir: \(root)/trusted/.git/worktrees/wt/../../worktrees/wt\n")
        expect(project("dots") == root + "/dots", "dots don't make another folder's entry point here")
        // Forged: an entry of the forger's own, named like a worktree's, under a folder that only looks like a repository.
        folder("mine/.git/worktrees/x")
        folder("mine-wt")
        file("mine-wt/.git", "gitdir: \(root)/mine/.git/worktrees/x\n")
        file("mine/.git/worktrees/x/gitdir", "\(root)/mine-wt/.git\n")
        expect(project("mine-wt") == root + "/mine", "the forger's own repository is only theirs")
        // Forged: an entry reached through a link, pointing back through a link to a .git that isn't this folder's.
        folder("trusted/.git/worktrees/linked")
        file("trusted/.git/worktrees/linked/gitdir", "\(root)/wt/.git\n")
        folder("lnk")
        file("lnk/.git", "gitdir: \(root)/trusted/.git/worktrees/linked\n")
        expect(project("lnk") == root + "/lnk", "an entry pointing at another worktree's .git")
        // A worktree whose entry was pruned: its own folder.
        folder("pruned")
        file("pruned/.git", "gitdir: \(root)/trusted/.git/worktrees/gone\n")
        expect(project("pruned") == root + "/pruned", "a pruned worktree: its own folder")
        // A real worktree entry pointing back here, but the main checkout's .git is a link elsewhere: not trusted.
        folder("elsewhere/.git/worktrees/w2")
        folder("decoy")
        try? fm.createSymbolicLink(atPath: root + "/decoy/.git", withDestinationPath: root + "/elsewhere/.git")
        folder("w2")
        file("w2/.git", "gitdir: \(root)/decoy/.git/worktrees/w2\n")
        file("elsewhere/.git/worktrees/w2/gitdir", "\(root)/w2/.git\n")
        expect(project("w2") == root + "/elsewhere", "an entry reached through a link is the repository it really is in", project("w2"))
    }

    /// A `.git` that is a link (to a real worktree's `.git` file, or to a repository's `.git` folder) never makes a
    /// folder part of that project; and a `.git` that resolves to another folder's (as a link does) doesn't pass the
    /// worktree's backlink.
    static func linkedGit() {
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appending(path: "petal-agent-link-\(UUID().uuidString)").path
        try? fm.createDirectory(atPath: made, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: made) }
        guard let root = AgentCallers.realPath(made) else { return expect(false, "a throwaway folder") }
        func folder(_ path: String) { try? fm.createDirectory(atPath: root + "/" + path, withIntermediateDirectories: true) }
        func file(_ path: String, _ text: String) { try? text.write(toFile: root + "/" + path, atomically: true, encoding: .utf8) }
        func link(_ path: String, to target: String) { try? fm.createSymbolicLink(atPath: root + "/" + path, withDestinationPath: root + "/" + target) }
        func project(_ path: String) -> String { AgentAccess.project(root + "/" + path, files: AgentCallers.disk) }

        folder("trusted/.git/worktrees/wt")
        folder("wt/src")
        file("wt/.git", "gitdir: \(root)/trusted/.git/worktrees/wt\n")
        file("trusted/.git/worktrees/wt/gitdir", "\(root)/wt/.git\n")
        expect(project("wt/src") == root + "/trusted", "the real worktree still is its main checkout")
        folder("copycat/sub")
        link("copycat/.git", to: "wt/.git")
        expect(AgentCallers.gitMark(root + "/copycat") == .link, "a linked .git is read as a link")
        expect(project("copycat/sub") == root + "/copycat", "a .git linked to a worktree's: its own folder", project("copycat/sub"))
        folder("mirror")
        link("mirror/.git", to: "trusted/.git")
        expect(project("mirror") == root + "/mirror", "a .git linked to a repository's: its own folder", project("mirror"))
        // A dangling link is still a link, never the folder above.
        folder("dangling")
        link("dangling/.git", to: "nowhere/.git")
        expect(project("dangling") == root + "/dangling", "a dangling .git link: its own folder")

        // The backlink must name a .git in this very folder: a disk where /x/.git resolves to /wt/.git (as a link
        // would, were it read as a file) doesn't pass.
        let resolved = AgentAccess.GitFiles(mark: { ["/t": .folder, "/x": .file("gitdir: /t/.git/worktrees/wt")][$0] }, real: { path in
            let path = AgentAccess.standard(path)
            return path == "/x/.git" ? "/wt/.git" : path
        }, read: { AgentAccess.standard($0) == "/t/.git/worktrees/wt/gitdir" ? "/wt/.git\n" : nil })
        expect(AgentAccess.project("/x", files: resolved) == "/x", "a .git resolving to another folder's doesn't borrow its project")
        let honest = AgentAccess.GitFiles(mark: { ["/t": .folder, "/wt": .file("gitdir: /t/.git/worktrees/wt")][$0] }, real: { AgentAccess.standard($0) },
                                          read: { AgentAccess.standard($0) == "/t/.git/worktrees/wt/gitdir" ? "/wt/.git\n" : nil })
        expect(AgentAccess.project("/wt", files: honest) == "/t", "while the real worktree on that disk is its main checkout")
    }

    /// Only macOS's own programs go unread; agents under /usr/local and /opt (Homebrew) have their signature checked.
    static func systemPrograms() {
        for path in ["/bin/zsh", "/sbin/launchd", "/usr/bin/env", "/usr/sbin/sshd", "/usr/libexec/sshd-session", "/System/Library/CoreServices/x"] {
            expect(AgentAccess.systemProgram(path), "\(path) is macOS's own")
        }
        for path in ["/usr/local/bin/claude", "/usr/local/Cellar/codex/1.0/bin/codex", "/opt/homebrew/bin/codex", "/usr/binx/claude",
                     "/Users/me/.local/bin/claude", "/Applications/T3 Code.app/Contents/MacOS/T3 Code", ""] {
            expect(!AgentAccess.systemProgram(path), "\(path) has its signature read")
        }
    }

    static func grants() {
        let grant = AgentAccess.Grant(item: "anthropic", title: "Anthropic", project: "/Users/me/petal", agent: .codex)
        func who(_ agent: AgentAccess.Agent, _ project: String) -> AgentAccess.Caller {
            AgentAccess.Caller(agent: agent, host: "T3 Code", project: project)
        }
        expect(AgentAccess.granted([grant], item: "anthropic", caller: who(.codex, "/Users/me/petal")) != nil, "the same item, project and agent")
        expect(AgentAccess.granted([grant], item: "anthropic", caller: who(.codex, "/Users/me/petal/site")) != nil, "a folder in the project")
        expect(AgentAccess.granted([grant], item: "anthropic", caller: who(.codex, "/Users/me/petal-old")) == nil, "a folder named alike isn't in it")
        expect(AgentAccess.granted([grant], item: "anthropic", caller: who(.claude, "/Users/me/petal")) == nil, "another agent")
        expect(AgentAccess.granted([grant], item: "openai", caller: who(.codex, "/Users/me/petal")) == nil, "another item")
        expect(AgentAccess.granted([grant], item: "anthropic", caller: who(.codex, "/Users/me")) == nil, "the folder above")
        let any = AgentAccess.Grant(item: AgentAccess.Grant.newLogins, title: "New logins", project: "/Users/me/petal", agent: .any)
        expect(AgentAccess.granted([any], item: AgentAccess.Grant.newLogins, caller: who(.claude, "/Users/me/petal")) != nil, "any agent covers Claude Code")
        expect(AgentAccess.granted([any], item: AgentAccess.Grant.newLogins, caller: who(.unknown, "/Users/me/petal")) == nil, "never an unknown program")
        expect(AgentAccess.granted([any], item: AgentAccess.Grant.newLogins, caller: who(.petal, "/Users/me/petal")) == nil, "nor as Petal AI")
        // Only verified agents (Claude Code, Codex signed by their makers) are ever covered, by any grant.
        expect(AgentAccess.granted([any], item: AgentAccess.Grant.newLogins, caller: who(.codex, "/Users/me/petal")) != nil, "any agent covers Codex")
        expect(AgentAccess.granted([any], item: AgentAccess.Grant.newLogins, caller: who(.command, "/Users/me/petal")) == nil,
               "any agent never covers a command with no verified agent above it")
        expect(AgentAccess.granted([any], item: AgentAccess.Grant.newLogins, caller: who(.opencode, "/Users/me/petal")) == nil,
               "any agent never covers opencode, known by name only")
        let opencode = AgentAccess.Grant(item: "anthropic", title: "Anthropic", project: "/Users/me/petal", agent: .opencode)
        expect(AgentAccess.granted([opencode], item: "anthropic", caller: who(.opencode, "/Users/me/petal")) == nil, "an older opencode grant counts for nothing")
        let command = AgentAccess.Grant(item: "anthropic", title: "Anthropic", project: "/Users/me/petal", agent: .command)
        expect(AgentAccess.granted([command], item: "anthropic", caller: who(.command, "/Users/me/petal")) == nil, "nor a command's")
        expect(!opencode.storable && !command.storable && grant.storable && any.storable, "only a verified agent's grant, or any agent's, is kept")
        expect(AgentAccess.Agent.grantable.allSatisfy { $0 == .any || $0.verified }, "Settings offers only verified agents")
        for agent in AgentAccess.Agent.allCases {
            let caller = who(agent, "/Users/me/petal")
            expect(caller.grantable == [.claude, .codex].contains(agent), "Always only for Claude Code and Codex: \(agent)")
        }
        let saved = try? JSONDecoder().decode([AgentAccess.Grant].self, from: JSONEncoder().encode([grant, any]))
        expect(saved == [grant, any], "grants survive being saved")
        expect(!(String(data: (try? JSONEncoder().encode(grant)) ?? Data(), encoding: .utf8) ?? "").contains("sk-"), "a grant holds no secret")
    }

    /// What let a vault use go on is checked again right before the secret goes: a grant removed meanwhile (or no
    /// longer covering the use), an Allow once from another operation or one already used, and nothing goes.
    static func authorizations() {
        let codex = AgentAccess.Caller(agent: .codex, host: "T3 Code", project: "/Users/me/petal")
        let grant = AgentAccess.Grant(item: "anthropic", title: "Anthropic", project: "/Users/me/petal", agent: .codex)
        let byGrant = AgentAccess.Authorization(kind: .grant(grant.id), operation: "op1", item: "anthropic")
        func still(_ auth: AgentAccess.Authorization, item: String = "anthropic", caller: AgentAccess.Caller = codex, operation: String = "op1",
                   grants: [AgentAccess.Grant], spent: Set<String> = []) -> Bool {
            AgentAccess.stillAllowed(auth, item: item, caller: caller, operation: operation, grants: grants, spent: spent)
        }
        expect(still(byGrant, grants: [grant]), "a grant still there goes on")
        expect(!still(byGrant, grants: []), "the grant removed while it waited: refused")
        let other = AgentAccess.Grant(item: "anthropic", title: "Anthropic", project: "/Users/me/petal", agent: .codex)
        expect(!still(byGrant, grants: [other]), "removed and a new one made: the operation's own grant is gone, refused")
        expect(AgentAccess.revokedBy(byGrant, removing: grant.id) && !AgentAccess.revokedBy(byGrant, removing: other.id),
               "removing a grant ends the operations relying on it, and only those")
        expect(!still(byGrant, caller: AgentAccess.Caller(agent: .codex, host: nil, project: "/Users/me/other"), grants: [grant]),
               "a grant that no longer covers the project: refused")
        expect(!still(byGrant, caller: AgentAccess.Caller(agent: .claude, host: nil, project: "/Users/me/petal"), grants: [grant]),
               "nor another agent")
        expect(!still(byGrant, item: "openai", grants: [grant]), "nor another item")
        expect(!still(byGrant, operation: "op2", grants: [grant]), "an authorization from another operation: refused")
        let once = AgentAccess.Authorization(kind: .allowOnce(card: "card1"), operation: "op1", item: "anthropic")
        expect(still(once, grants: []), "Allow once, in its own operation")
        expect(!still(once, grants: [], spent: ["card1"]), "Allow once used again after its operation: refused")
        expect(!still(once, operation: "op2", grants: []), "Allow once reused for another operation: refused")
        expect(!AgentAccess.revokedBy(once, removing: grant.id), "removing a grant doesn't touch an Allow once")
        let own = AgentAccess.Authorization(kind: .petal, operation: "op1", item: "anthropic")
        expect(still(own, caller: AgentAccess.Caller(agent: .petal, host: nil, project: "/p"), grants: []), "Petal's own chats keep the vault's rules")
        expect(!still(own, grants: []), "Petal's own authorization never lets an agent through")
        let newLogins = AgentAccess.Grant(item: AgentAccess.Grant.newLogins, title: "New logins", project: "/Users/me/petal", agent: .any)
        let make = AgentAccess.Authorization(kind: .grant(newLogins.id), operation: "op1", item: AgentAccess.Grant.newLogins)
        expect(still(make, item: AgentAccess.Grant.newLogins, grants: [newLogins]), "new logins by an any-agent grant")
        expect(!still(make, item: AgentAccess.Grant.newLogins, grants: []), "new logins, the grant removed: refused")
    }

    /// `petal run` hands over no key under 16 characters; from 16 on, every form of it is taken out of what's printed.
    static func shortKeys() {
        expect(AgentAccess.Redactor.tooShort("12345678"), "an 8-character key is too short")
        expect(AgentAccess.Redactor.tooShort("0123456789abcde"), "15 characters are too short")
        expect(!AgentAccess.Redactor.tooShort("0123456789abcdef"), "16 characters are enough")
        expect(AgentAccess.Redactor.tooShort("ключ-🔑"), "short in any script")
        expect(AgentAccess.Redactor.tooShortText.contains("filling it into a field"), "the refusal says how to use it instead")
        for secret in ["Abc_def+ghi/JK01", "0123456789abcdef", "s3cr3t-k3y_ABCD=", "ÿ~?>xyz/+=-_.!*q"] {
            expect(!AgentAccess.Redactor.tooShort(secret), "\(secret) is accepted")
            let label = [(secret, "K")]
            func gone(_ text: String, _ what: String) {
                let out = redact(label, text)
                expect(out.contains("[K key]"), "\(what) of a 16-character key", out)
            }
            gone("v=\(secret);", "itself")
            let hex = Array(secret.utf8).map { String(format: "%02x", $0) }.joined()
            gone("h=\(hex)", "hex")
            gone("H=\(hex.uppercased())", "uppercase hex")
            gone("?k=\(secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&", "percent-encoded")
            let all = Array(secret.utf8).map { String(format: "%%%02X", $0) }.joined()
            gone("?k=\(all)", "every byte percent-encoded")
            // Base64 at each of the three places it can start, as HTTP Basic writes "user:key" (only the key known).
            for prefix in ["", "a", "ab", "u:", "me:", "user:", "Bearer "] {
                let encoded = Data((prefix + secret).utf8).base64EncodedString()
                let out = redact(label, "Authorization: Basic \(encoded)\n")
                expect(out.contains("[K key]"), "base64 of \"\(prefix)\" + a 16-character key", out)
                let safe = encoded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                expect(redact(label, safe).contains("[K key]"), "URL-safe base64 of \"\(prefix)\" + a 16-character key")
                // No long run left that comes from the key's bits alone.
                let core = AgentAccess.Redactor.base64Forms(of: secret)
                expect(!core.contains { out.contains($0) }, "nothing of the key's base64 left after \"\(prefix)\"", out)
            }
            let forms = AgentAccess.Redactor.base64Forms(of: secret)
            // Standard base64 has no "-" or "_": those are the URL-safe copies.
            expect(Set(forms.filter { !$0.contains("-") && !$0.contains("_") }).count == 3,
                   "a 16-character key has its base64 at all three alignments", "\(forms)")
        }
        // Each alignment found on its own.
        let secret = "0123456789abcdef"
        for offset in 0..<3 {
            let encoded = Data((String(repeating: "x", count: offset) + secret).utf8).base64EncodedString()
            expect(redact([(secret, "K")], encoded).contains("[K key]"), "base64 at alignment \(offset)")
        }
    }

    /// A request is decided by the identity it came with: none, and it's refused, never let through.
    static func gates() {
        let codex = AgentAccess.Caller(agent: .codex, host: "T3 Code", project: "/p")
        let own = AgentAccess.Caller(agent: .petal, host: nil, project: "/p")
        expect(AgentAccess.gate(nil) == .refuse, "no identity: refused")
        expect(AgentAccess.gate(own) == .petal, "Petal's own chat: the vault's own rules")
        expect(AgentAccess.gate(codex) == .check(codex), "another agent: checked against its grants")
        expect(AgentAccess.gate(AgentAccess.Caller(agent: .unknown, host: nil, project: "/p")) != .petal, "an unknown program is checked")
    }

    /// Two keys that would go in one variable are refused before anyone is asked, with what to do.
    static func sameVariable() {
        let clash = AgentAccess.sameVariable([("OpenAI work", "OPENAI_API_KEY"), ("Anthropic", "ANTHROPIC_API_KEY"), ("OpenAI home", "OPENAI_API_KEY")])
        expect(clash?.contains("OpenAI work") == true && clash?.contains("OpenAI home") == true && clash?.contains("--env") == true,
               "two OpenAI keys in OPENAI_API_KEY: refused, saying --env", clash ?? "nil")
        expect(AgentAccess.sameVariable([("OpenAI work", "OPENAI_API_KEY"), ("OpenAI home", "OPENAI_HOME_KEY")]) == nil, "each in its own: fine")
        expect(AgentAccess.sameVariable([("A", nil), ("B", nil), ("C", "C_KEY")]) == nil, "keys on the command's input don't clash")
    }

    static func words() {
        let caller = AgentAccess.Caller(agent: .codex, host: "T3 Code", project: "/Users/me/petal")
        expect(AgentAccess.keyQuestion(caller, titles: ["Anthropic"], command: "npm test", home: "/Users/me")
               == "Codex in T3 Code wants your Anthropic key for “npm test” in ~/petal", "the key card's question")
        expect(AgentAccess.keyQuestion(caller, titles: ["Anthropic", "OpenAI", "xAI"], command: "", home: "/Users/me")
               == "Codex in T3 Code wants your Anthropic, OpenAI and xAI keys in ~/petal", "several keys")
        expect(AgentAccess.fillQuestion(caller, what: "fill your github.com login", home: "/Users/me")
               == "Codex in T3 Code wants to fill your github.com login in ~/petal", "the fill card's question")
        expect(AgentAccess.clipped("npm\ntest " + String(repeating: "x", count: 80), 20).count == 20, "a long command is cut short on one line")
        // A command longer than the title holds is said whole on the card: the person reads all of what they allow.
        let long = AgentAccess.commandLine(["sh", "-c", "npm test --workspace packages/web --reporter dot --silent && node scripts/report.js --out coverage/summary.json"])
        let title = AgentAccess.keyQuestion(caller, titles: ["Anthropic"], command: long, home: "/Users/me")
        expect(!title.contains("summary.json") && title.contains("…"), "the title says a long command's beginning", title)
        expect(AgentAccess.keyCommand(long)?.contains("coverage/summary.json") == true, "and the card says all of it", AgentAccess.keyCommand(long) ?? "nil")
        expect(AgentAccess.keyCommand(long) == "The whole command: “\(long)”.", "in these words", AgentAccess.keyCommand(long) ?? "nil")
        expect(AgentAccess.keyCommand("npm test") == nil && AgentAccess.keyCommand("") == nil, "a command the title says whole isn't said twice")
        let longest = AgentAccess.keyCommand(String(repeating: "x", count: 500)) ?? ""
        expect(longest.contains(String(repeating: "x", count: AgentAccess.commandWhole - 1) + "…") && !longest.contains(String(repeating: "x", count: AgentAccess.commandWhole)),
               "as much as the card keeps, and a mark where it's cut")
        // What shows is what runs: nothing that turns the reading around, hides or looks like something else.
        let turned = AgentAccess.commandLine(["sh", "-c", "x\u{202E}y\u{200B}", "a\u{00A0}b", "tab\there", "line\nbreak", "it's\u{2066}", "\u{E0041}", "back\\slash\u{7}"])
        expect(turned == "sh -c $'x\\u202ey\\u200b' $'a\\xa0b' $'tab\\there' $'line\\nbreak' $'it\\'s\\u2066' $'\\U000e0041' $'back\\\\slash\\x07'",
               "each written the way a shell reads it back", turned)
        expect(!turned.unicodeScalars.contains(where: AgentAccess.unseen), "nothing unseen is left in a command line")
        for scalar in ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{200E}", "\u{200F}", "\u{061C}",
                       "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00AD}", "\u{2028}", "\u{2029}", "\u{0}", "\u{1B}", "\u{7F}", "\u{85}",
                       "\u{3000}", "\u{2003}", "\u{3164}", "\u{2800}", "\u{FE0F}", "\u{E000}"] {
            let line = AgentAccess.commandLine(["echo", "a" + scalar + "b"])
            expect(!line.unicodeScalars.contains(where: AgentAccess.unseen) && !line.contains(scalar) && line.hasPrefix("echo $'a\\"),
                   "U+\(String(scalar.unicodeScalars.first!.value, radix: 16)) is written as its number", line)
        }
        expect(AgentAccess.commandLine(["npm", "run", "test it", "it's", "héllo wörld", "日本語"]) == "npm run 'test it' 'it'\\''s' 'héllo wörld' '日本語'",
               "ordinary words stay as they were", AgentAccess.commandLine(["héllo wörld", "日本語"]))
        // A command line that came from anywhere else is shown the same way.
        expect(AgentAccess.visible("npm test\u{202E}tset") == "npm test\\u202etset" && AgentAccess.visible("npm test") == "npm test", "a command line from elsewhere")
        let sent = AgentAccess.keyQuestion(caller, titles: ["Anthropic"], command: "sh -c 'a\u{202E}b'", home: "/Users/me")
        expect(!sent.unicodeScalars.contains(where: AgentAccess.unseen) && sent.contains("a\\u202eb"), "the title too", sent)
        expect(AgentAccess.keyCommand("x\u{202E}" + String(repeating: "y", count: 80))?.unicodeScalars.contains(where: AgentAccess.unseen) == false, "and the whole command")
    }

    /// `petal run`'s streams (AgentAccess.relay): the moment after the command ends stops the reading, never the
    /// writing. A pipe of bytes, an agent that may pause, and a clock that passes the deadline while a write waits.
    /// Writing to the agent's end: a full pipe that doesn't block (EAGAIN) is waited on, never the end.
    static func writing() {
        expect(AgentAccess.wrote(10, errno: 0) == .wrote(10), "some written")
        expect(AgentAccess.wrote(-1, errno: EINTR) == .again, "a signal: write again")
        expect(AgentAccess.wrote(-1, errno: EAGAIN) == .wait, "a full non-blocking pipe: wait for room")
        expect(AgentAccess.wrote(-1, errno: EWOULDBLOCK) == .wait, "EWOULDBLOCK too")
        expect(AgentAccess.wrote(-1, errno: EPIPE) == .gone, "the reader closed its end")
        expect(AgentAccess.wrote(-1, errno: EBADF) == .gone, "another error")
        expect(AgentAccess.wrote(0, errno: 0) == .gone, "nothing written: never a loop")

        // A pipe that takes 3 bytes at a time and is full every other write: everything arrives, after waits.
        let bytes = Array("hello, agent".utf8)
        var got: [UInt8] = [], full = false, waits = 0, interrupted = false
        let done = AgentAccess.writeAll(bytes, write: { part in
            if !interrupted { interrupted = true; return (-1, EINTR) }
            full.toggle()
            if full { return (-1, EAGAIN) }
            let n = min(3, part.count)
            got += part.prefix(n)
            return (n, 0)
        }, writable: { waits += 1; return true })
        expect(done && got == bytes, "every byte through a full pipe", String(decoding: got, as: UTF8.self))
        expect(waits > 0, "waited for room rather than giving up")

        // The reader leaves while the pipe is full: the rest is dropped, and the writing says so.
        var tries = 0
        let left = AgentAccess.writeAll(bytes, write: { _ in tries += 1; return tries == 1 ? (-1, EAGAIN) : (-1, EPIPE) },
                                        writable: { true })
        expect(!left && tries == 2, "EPIPE after a wait ends it")
        expect(!AgentAccess.writeAll(bytes, write: { _ in (-1, EAGAIN) }, writable: { false }), "a pipe that can't be waited on ends it")
        expect(AgentAccess.writeAll([], write: { _ in (-1, EPIPE) }, writable: { true }), "nothing to write: done")
    }

    static func relaying() {
        final class Pipe {
            var bytes: [UInt8] = []
            var open = true
            var read = 0
        }
        func run(_ pipe: Pipe, chunk: Int = 65536, secrets: [(secret: String, label: String)] = [],
                 write: ([UInt8]) -> Bool, stopped: () -> Bool, during: (Int) -> Void = { _ in }) {
            var redactor = AgentAccess.Redactor(secrets)
            var reads = 0
            AgentAccess.relay(&redactor, chunk: chunk, read: { most in
                reads += 1
                during(reads)
                guard pipe.read < pipe.bytes.count else { return pipe.open ? .nothingYet : .ended }
                let end = min(pipe.bytes.count, pipe.read + most)
                defer { pipe.read = end }
                return .bytes(Array(pipe.bytes[pipe.read..<end]))
            }, waiting: { pipe.bytes.count - pipe.read }, write: write, stopped: stopped)
        }

        // 100,000 bytes, the command gone, the agent paused: the deadline passes while the first write waits, and
        // still every byte arrives.
        let pipe = Pipe()
        pipe.bytes = Array(repeating: UInt8(ascii: "a"), count: 100_000)
        pipe.open = true   // something left running in the background holds it open
        var passed = false
        var delivered: [UInt8] = []
        run(pipe, write: { bytes in
            passed = true   // the agent took longer than the deadline to read this
            delivered += bytes
            return true
        }, stopped: { passed })
        expect(delivered.count == 100_000, "a paused agent still gets every byte once the deadline passed", "\(delivered.count)")

        // After the deadline only what was in the pipe right then: what a background writer adds later isn't read.
        let busy = Pipe()
        busy.bytes = Array(repeating: UInt8(ascii: "b"), count: 1000)
        var stop = false
        var got = 0
        run(busy, chunk: 100, write: { bytes in
            got += bytes.count
            if got == 100 { stop = true }
            return true
        }, stopped: { stop }, during: { _ in
            if stop { busy.bytes += Array(repeating: UInt8(ascii: "c"), count: 50) }   // written after the deadline
        })
        expect(got == 1000, "what was in the pipe at the deadline is passed on", "\(got)")
        expect(busy.read == 1000, "nothing written after the deadline is read", "\(busy.read)")

        // The keys come out across the deadline too, and what the redactor held back is written at the end.
        let key = "sk-test-0123456789abcdefXYZ"
        let keyed = Pipe()
        keyed.bytes = Array(("before " + key + " after").utf8)
        var text: [UInt8] = []
        var halfway = false
        run(keyed, chunk: 10, secrets: [(secret: key, label: "K")], write: { bytes in
            text += bytes
            halfway = true
            return true
        }, stopped: { halfway })
        expect(String(decoding: text, as: UTF8.self) == "before [K key] after", "redacted across the deadline", String(decoding: text, as: UTF8.self))

        // The output's end before the deadline: everything, then done.
        let short = Pipe()
        short.bytes = Array("done\n".utf8)
        short.open = false
        var all: [UInt8] = []
        run(short, write: { all += $0; return true }, stopped: { false })
        expect(all == Array("done\n".utf8), "the output's end passes everything on")

        // An agent that closed its end: nothing more is written, but the output is still read to its end, so the
        // command never blocks on a full pipe.
        let closed = Pipe()
        closed.bytes = Array(repeating: UInt8(ascii: "d"), count: 5000)
        closed.open = false
        var writes = 0
        run(closed, chunk: 1000, write: { _ in writes += 1; return false }, stopped: { false })
        expect(writes == 1, "no write after the agent's end closed", "\(writes)")
        expect(closed.read == 5000, "the rest is read and dropped", "\(closed.read)")
    }

    /// An answer petal run can't read is never shown: only one of three fixed sentences, whatever it holds.
    static func answers() {
        let key = "sk-ant-api03-0123456789abcdefXYZ"
        let fixed = [AgentAccess.noAnswerText, AgentAccess.tooOldText, AgentAccess.unreadableText]
        let cases: [(String, String)] = [
            ("", AgentAccess.noAnswerText), (" \n", AgentAccess.noAnswerText),
            ("unknown function agentKeys", AgentAccess.tooOldText),
            ("{\"keys\":[{\"title\":\"K\",\"secret\":\"" + key, AgentAccess.unreadableText),   // cut short
            (key, AgentAccess.unreadableText), ("Petal isn't running", AgentAccess.unreadableText),
            ("unknown function " + key, AgentAccess.tooOldText),
        ]
        for (answer, expected) in cases {
            let text = AgentAccess.unreadable(Array(answer.utf8))
            expect(text == expected, "an unreadable answer gets its fixed sentence", "\(answer.prefix(20)) → \(text)")
            expect(fixed.contains(text) && !text.contains(key) && !text.contains("sk-"), "nothing of the answer is shown", text)
        }
        // Any bytes at all, garbled or cut anywhere: always one of the three sentences.
        var generator = SystemRandomNumberGenerator()
        let whole = Array(("{\"keys\":[{\"secret\":\"" + key + "\"}]}").utf8)
        for cut in 0...whole.count {
            expect(fixed.contains(AgentAccess.unreadable(Array(whole[..<cut]))), "a cut answer gets a fixed sentence", "\(cut)")
        }
        for _ in 0..<200 {
            let bytes = (0..<Int.random(in: 0...64, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            expect(fixed.contains(AgentAccess.unreadable(bytes)), "random bytes get a fixed sentence")
        }
    }

    /// What petal run does with each signal while its command runs: the terminal's (sent to the whole group, so the
    /// command has them already) are ignored, never passed on again; what's sent to petal run alone is passed on.
    static func signals() {
        expect(AgentAccess.onSignal(SIGINT) == .ignore, "Ctrl-C isn't passed on a second time")
        expect(AgentAccess.onSignal(SIGQUIT) == .ignore, "Ctrl-\\ isn't passed on a second time")
        expect(AgentAccess.onSignal(SIGTERM) == .forward, "SIGTERM to petal run alone is passed on")
        expect(AgentAccess.onSignal(SIGHUP) == .forward, "SIGHUP is passed on")
        expect(AgentAccess.onSignal(SIGTSTP) == .usual, "Ctrl-Z keeps its usual effect")
        expect(AgentAccess.onSignal(SIGPIPE) == .usual && AgentAccess.onSignal(SIGKILL) == .usual, "others aren't taken over")
        expect(Set(AgentAccess.handledSignals) == [SIGINT, SIGQUIT, SIGTERM, SIGHUP], "the signals taken over")
        expect(AgentAccess.handledSignals.allSatisfy { AgentAccess.onSignal($0) != .usual }, "each taken over is ignored or passed on")
    }
}
