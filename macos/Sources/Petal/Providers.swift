import AppKit
import SwiftUI

/// The AI apps Petal can talk to, each the person's own local install and account: Claude Code and Codex, as T3
/// Code uses them. Everything that differs between them lives here; a new one (Grok, and so on) is a new case.
enum Provider: String, CaseIterable, Identifiable, Sendable {
    case claude, codex

    var id: String { rawValue }
    var name: String { self == .claude ? "Claude" : "Codex" }
    var binary: String { rawValue }
    var pathSetting: String { self == .claude ? "claudePath" : "codexPath" }
    var modelSetting: String { self == .claude ? "chatModel" : "codexModel" }
    var effortSetting: String { self == .claude ? "chatEffort" : "codexEffort" }
    var plan: String { self == .claude ? "Uses your own Claude plan." : "Uses your own ChatGPT plan." }
    var appName: String { self == .claude ? "Claude Code" : "Codex" }

    /// The maker's own installer, which needs no developer tools.
    var installer: String {
        switch self {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=true sh"
        }
    }

    /// Signing in finishes in the browser, with the person's own account.
    var signInArguments: [String] { self == .claude ? ["auth", "login", "--claudeai"] : ["login"] }
    var statusArguments: [String] { self == .claude ? ["auth", "status", "--json"] : ["login", "status"] }

    /// Who is signed in, from the status command's output: nil when no one is.
    func signedIn(status: Int32, output: String) -> String? {
        switch self {
        case .claude:
            let info = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
            return info?["loggedIn"] as? Bool == true ? (info?["email"] as? String ?? "") : nil
        case .codex:
            return status == 0 && output.localizedCaseInsensitiveContains("logged in") ? "" : nil
        }
    }

    var models: [(String, String)] {
        switch self {
        case .claude: [("haiku", "Haiku"), ("sonnet", "Sonnet"), ("opus", "Opus"), ("fable", "Fable")]
        case .codex: [("", "Default")]
        }
    }

    var efforts: [String] {
        self == .claude ? ["low", "medium", "high", "xhigh", "max"] : ["low", "medium", "high", "xhigh"]
    }

    /// The places its installer puts it, after the person's own shell.
    func knownPaths(home: String) -> [String] {
        switch self {
        case .claude: ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        case .codex: ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        }
    }

    // MARK: Chat

    struct Chat {
        let model: String
        let effort: String
        let fullAccess: Bool
        let instructions: String
        let tools: String          // Petal itself, with --mcp
        let session: String?
        let allowed: [String]
        var api = false            // on an API key (APIKeys.swift)
        var note: String?          // a sticky note's id: Petal's tools answer about its window
    }

    /// One turn of the chat; the prompt goes on stdin.
    func chatArguments(_ chat: Chat) -> [String] {
        switch self {
        case .claude:
            var server: [String: Any] = ["command": chat.tools, "args": ["--mcp"]]
            if let note = chat.note { server["env"] = ["PETAL_NOTE": note] }
            let mcp: [String: Any] = ["mcpServers": ["petal": server]]
            let config = (try? JSONSerialization.data(withJSONObject: mcp, options: [.withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            var arguments = ["-p", "--model", chat.model.isEmpty ? "sonnet" : chat.model, "--effort", chat.effort,
                             "--output-format", "stream-json", "--verbose",
                             "--permission-mode", chat.fullAccess ? "bypassPermissions" : "auto",
                             "--append-system-prompt", chat.instructions, "--mcp-config", config]
            if let session = chat.session { arguments += ["--resume", session] }
            // Petal's tools, and looking into Petal itself (its health check and log), need no asking.
            let petal = chat.tools
            return arguments + ["--allowedTools", "mcp__petal", "Bash(petal doctor:*)", "Bash(petal logs:*)",
                                "Bash(\(petal) doctor:*)", "Bash(\(petal) logs:*)"] + chat.allowed
        case .codex:
            var arguments = ["exec", "--json", "--skip-git-repo-check", "-C", NSHomeDirectory()]
            arguments += chat.fullAccess ? ["--dangerously-bypass-approvals-and-sandbox"] : ["--sandbox", "workspace-write"]
            if !chat.model.isEmpty { arguments += ["-m", chat.model] }
            arguments += ["-c", "model_reasoning_effort=\(Self.toml(chat.effort))",
                          "-c", "developer_instructions=\(Self.toml(chat.instructions))",
                          "-c", "mcp_servers.petal.command=\(Self.toml(chat.tools))",
                          "-c", "mcp_servers.petal.args=[\"--mcp\"]",
                          "-c", "mcp_servers.petal.default_tools_approval_mode=\"approve\"",
                          // A tool that asks the person first may wait for them.
                          "-c", "mcp_servers.petal.tool_timeout_sec=180"]
            if let note = chat.note { arguments += ["-c", "mcp_servers.petal.env={PETAL_NOTE=\(Self.toml(note))}"] }
            // On an API key: the commands Codex runs never see it (names with KEY in them stay out).
            if chat.api { arguments += ["-c", "shell_environment_policy.ignore_default_excludes=false"] }
            if let session = chat.session { arguments += ["resume", session] }
            return arguments + ["-"]
        }
    }

    /// What one line of the chat's output means.
    func events(_ line: String) -> [Agent.Event] {
        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return [] }
        switch self {
        case .claude: return Self.claudeEvents(event)
        case .codex: return Self.codexEvents(event)
        }
    }

    private static func claudeEvents(_ event: [String: Any]) -> [Agent.Event] {
        var out: [Agent.Event] = []
        if let id = event["session_id"] as? String { out.append(.session(id)) }
        switch event["type"] as? String {
        case "assistant" where event["error"] != nil:
            // The API refused the call (on an API key: the key); its text is Claude Code's own wording.
            if APIKeys.isAuthError(event["error"] as? String ?? "") { out.append(.authFailed) }
        case "assistant":
            for part in (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [] {
                if part["type"] as? String == "text", let text = part["text"] as? String {
                    out.append(.text(text))
                } else if part["type"] as? String == "tool_use", let name = part["name"] as? String, name != "ToolSearch" {
                    out.append(.step(Agent.describe(name, part["input"] as? [String: Any] ?? [:])))
                }
            }
        case "result":
            var denials: [Agent.Denial] = []
            for denial in event["permission_denials"] as? [[String: Any]] ?? [] {
                let tool = denial["tool_name"] as? String ?? ""
                let input = denial["tool_input"] as? [String: Any] ?? [:]
                let label = tool == "Bash" ? (input["command"] as? String ?? "") : Agent.describe(tool, input)
                guard !denials.contains(where: { $0.label == label }) else { continue }
                denials.append(Agent.Denial(tool: tool, label: label, rules: tool == "Bash" ? Agent.bashRules(input["command"] as? String ?? "") : [tool]))
            }
            if !denials.isEmpty { out.append(.denials(denials)) }
            if let cost = event["total_cost_usd"] as? Double, cost > 0 { out.append(.cost(cost)) }
            if event["is_error"] as? Bool == true {
                let text = event["result"] as? String ?? "Something went wrong"
                out.append(event["api_error_status"] as? Int == 401 || APIKeys.isAuthError(text) ? .authFailed : .error(text))
            }
            out.append(.finished)
        default:
            break
        }
        return out
    }

    private static func codexEvents(_ event: [String: Any]) -> [Agent.Event] {
        let item = event["item"] as? [String: Any] ?? [:]
        switch (event["type"] as? String, item["type"] as? String) {
        case ("thread.started", _):
            return (event["thread_id"] as? String).map { [.session($0)] } ?? []
        case ("item.completed", "agent_message"):
            return [.text(item["text"] as? String ?? "")]
        case ("item.started", "command_execution"):
            return [.step("Running  " + ((item["command"] as? String ?? "").components(separatedBy: "\n").first ?? ""))]
        case ("item.started", "mcp_tool_call"):
            return [.step(Agent.describe("mcp__petal__" + (item["tool"] as? String ?? ""), item["arguments"] as? [String: Any] ?? [:]))]
        case ("item.started", "file_change"):
            let path = ((item["changes"] as? [[String: Any]])?.first?["path"] as? String) ?? ""
            return [.step("Editing  " + path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))]
        case ("item.started", "web_search"):
            return [.step("Searching the web  " + (item["query"] as? String ?? ""))]
        case ("error", _):
            // Codex tries a refused key again for a while; the first refusal is enough.
            return APIKeys.isAuthError(event["message"] as? String ?? "") ? [.authFailed] : []
        case ("turn.failed", _):
            let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "Something went wrong"
            return [APIKeys.isAuthError(message) ? .authFailed : .error(message), .finished]
        case ("turn.completed", _):
            let usage = event["usage"] as? [String: Any] ?? [:]
            let count = { (key: String) in (usage[key] as? Int) ?? 0 }
            return [.tokens(input: count("input_tokens"), cached: count("cached_input_tokens"), output: count("output_tokens")), .finished]
        default:
            return []
        }
    }

    // MARK: Quick calls

    /// A quick, cheap call that answers with JSON (sorting activity into modes).
    var quickArguments: [String] {
        switch self {
        case .claude:
            ["-p", "--model", "haiku", "--effort", "low", "--no-session-persistence", "--setting-sources", "",
             "--strict-mcp-config", "--tools", "", "--output-format", "json"]
        case .codex:
            ["exec", "--json", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "-C", NSTemporaryDirectory(),
             "-c", "model_reasoning_effort=\"low\"", "-"]
        }
    }

    /// The reply text in a quick call's output.
    func quickReply(_ output: String) -> String { quickResult(output).text }

    /// A quick call's reply, or what went wrong.
    func quickResult(_ output: String) -> (text: String, error: String?) {
        var text = "", error: String?
        for event in Self.jsonLines(output) {
            switch self {
            case .claude:
                guard event["type"] as? String == "result" else { continue }
                text = event["result"] as? String ?? ""
                if event["is_error"] as? Bool == true { error = text.isEmpty ? "It didn't answer." : text; text = "" }
            case .codex:
                let item = event["item"] as? [String: Any] ?? [:]
                if item["type"] as? String == "agent_message" { text = item["text"] as? String ?? "" }
                if event["type"] as? String == "turn.failed" {
                    error = ((event["error"] as? [String: Any])?["message"] as? String) ?? "It didn't answer."
                } else if event["type"] as? String == "error", error == nil, let message = event["message"] as? String {
                    error = message
                }
            }
        }
        // Codex may say it's reconnecting and still answer: an answer wins.
        return text.isEmpty ? ("", error) : (text, nil)
    }

    /// What a quick call cost on an API key: Claude Code's own figure, or Codex's tokens priced by APIPricing.
    func quickSpend(_ output: String, model: String) -> Double? {
        for event in Self.jsonLines(output).reversed() {
            switch self {
            case .claude:
                if let cost = event["total_cost_usd"] as? Double { return cost > 0 ? cost : nil }
            case .codex:
                guard event["type"] as? String == "turn.completed", let usage = event["usage"] as? [String: Any] else { continue }
                return APIPricing.codex(model: model, input: usage["input_tokens"] as? Int ?? 0,
                                        cached: usage["cached_input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0)
            }
        }
        return nil
    }

    private static func jsonLines(_ output: String) -> [[String: Any]] {
        output.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    static func toml(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

/// OpenAI's mark for Codex, one color: drawn as a template, so it follows light and dark like the text around it.
struct OpenAIMark: View {
    static let image: NSImage? = Bundle.main.url(forResource: "openai", withExtension: "svg").flatMap { NSImage(contentsOf: $0) }.map {
        $0.isTemplate = true
        return $0
    }

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "chevron.left.forwardslash.chevron.right").resizable().scaledToFit().fontWeight(.bold)
        }
    }
}

/// Each AI's mark, from Petal's assets.
struct ProviderMark: View {
    let provider: Provider?

    var body: some View {
        switch provider {
        case .claude?: ClaudeMark()
        case .codex?: OpenAIMark()
        case nil: Image(systemName: "sparkle").resizable().scaledToFit()
        }
    }
}
