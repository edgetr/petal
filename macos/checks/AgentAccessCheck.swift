import Foundation

// Checks AgentAccess.swift: which variable `petal run` puts a key in, taking keys out of what a command prints (as
// themselves, hex, percent-encoded and base64, and split across reads), reading `petal run`'s words, who's asking from
// a chain of processes, which project a folder is (a T3 worktree is its main checkout), and which grants cover a use.
// No process, Keychain or file is read. Run with macos/checks/run.sh.
@main
struct AgentAccessCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if !condition { failures += 1; print("FAIL: \(what) \(detail())") }
    }

    static func main() {
        variables()
        redaction()
        splitReads()
        running()
        callers()
        projects()
        grants()
        words()
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
        expect(quick.feed(Array("bc\n".utf8)) == Array("sk-abc\n".utf8), "and goes on once it isn't one")
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
        expect(viaCodex.agent == .codex && viaCodex.label == "Codex in T3 Code" && viaCodex.confirmed, "Petal --mcp under Codex")
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
        expect(AgentAccess.caller(chain: [run, wrongID, zsh], petalPID: 5, peerIsPetal: true, project: "/p").agent == .command,
               "Anthropic's other apps aren't Claude Code")
        // What connected isn't Petal's own code: an unknown program, whatever is above it.
        let netcat = AgentAccess.caller(chain: [P(pid: 50, path: "/usr/bin/nc"), zsh, claude] + host, petalPID: 5, peerIsPetal: false, project: "/p")
        expect(netcat.agent == .unknown && netcat.label == "An unknown program (nc)" && !netcat.peerIsPetal, "nc on the socket", netcat.label)
        // Petal's own chats: Petal is in the chain.
        let own = AgentAccess.caller(chain: [P(pid: 60, path: petal), claude, P(pid: 5, path: petal)], petalPID: 5, peerIsPetal: true, project: "/p")
        expect(own.agent == .petal && own.label == "Petal AI" && !own.grantable, "Petal's own chat")
        // No agent above: the person's own command.
        let mine = AgentAccess.caller(chain: [run, zsh, P(pid: 7, path: "/usr/bin/login"), terminal], petalPID: 5, peerIsPetal: true, project: "/p")
        expect(mine.agent == .command && mine.label == "A command in Terminal", "a command typed in Terminal", mine.label)
        let opencode = AgentAccess.caller(chain: [run, P(pid: 26, path: "/Users/me/.opencode/bin/opencode")] + host, petalPID: 5, peerIsPetal: true, project: "/p")
        expect(opencode.agent == .opencode && !opencode.confirmed && opencode.grantable, "opencode by its name, unconfirmed")
        expect(AgentAccess.hostApp([P(pid: 1, path: "/Applications/iTerm.app/Contents/MacOS/iTerm2")]) == "iTerm", "iTerm")
        expect(AgentAccess.hostApp([P(pid: 1, path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)")])
               == "Visual Studio Code", "the outermost app, not a helper")
        expect(AgentAccess.hostApp([zsh]) == nil, "no app")
    }

    static func projects() {
        let marks: [String: AgentAccess.GitMark] = [
            "/Users/me/petal": .folder,
            "/Users/me/.t3/worktrees/petal/t3-1": .file("gitdir: /Users/me/petal/.git/worktrees/t3-1\n"),
            "/Users/me/petal/.claude/worktrees/x": .file("gitdir: ../../../.git/worktrees/x"),
            "/Users/me/app/vendor/lib": .file("gitdir: ../../.git/modules/lib"),
            "/Users/me/app": .folder,
        ]
        let git = { (folder: String) in marks[folder] }
        expect(AgentAccess.project("/Users/me/petal/macos/Sources", git: git) == "/Users/me/petal", "a subfolder: its repository")
        expect(AgentAccess.project("/Users/me/.t3/worktrees/petal/t3-1/macos", git: git) == "/Users/me/petal", "a T3 worktree: its main checkout")
        expect(AgentAccess.project("/Users/me/petal/.claude/worktrees/x", git: git) == "/Users/me/petal", "a relative worktree link")
        expect(AgentAccess.project("/Users/me/app/vendor/lib/src", git: git) == "/Users/me/app/vendor/lib", "a submodule is its own project")
        expect(AgentAccess.project("/Users/me/notes/drafts", git: git) == "/Users/me/notes/drafts", "no repository: the folder itself")
        expect(AgentAccess.project("/Users/me/petal/./macos/../", git: git) == "/Users/me/petal", "dots and slashes tidied")
        expect(AgentAccess.shown("/Users/me/petal", home: "/Users/me") == "~/petal" && AgentAccess.shown("/opt/x", home: "/Users/me") == "/opt/x",
               "shown from the home folder")
        expect(AgentAccess.shown("/Users/mead", home: "/Users/me") == "/Users/mead", "another person's folder isn't under home")
        expect(AgentAccess.tooBroad("/", home: "/Users/me") && AgentAccess.tooBroad("/Users/me/", home: "/Users/me") && AgentAccess.tooBroad("/Users", home: "/Users/me"),
               "home and above are too much for one grant")
        expect(!AgentAccess.tooBroad("/Users/me/petal", home: "/Users/me"), "a project isn't")
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
        let saved = try? JSONDecoder().decode([AgentAccess.Grant].self, from: JSONEncoder().encode([grant, any]))
        expect(saved == [grant, any], "grants survive being saved")
        expect(!(String(data: (try? JSONEncoder().encode(grant)) ?? Data(), encoding: .utf8) ?? "").contains("sk-"), "a grant holds no secret")
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
    }
}
