import Foundation
import Observation
import Security
import SwiftUI

/// Bring your own API key: Claude Code and Codex can run on an Anthropic or OpenAI API key instead of the person's
/// subscription. The key lives in the Keychain under Petal's own item (service tech.edgetr.petal.api, account
/// anthropic or openai), never in a file, and only the processes Petal starts get it, through their environment:
///
/// - Claude Code: `ANTHROPIC_API_KEY`, which in `-p` runs wins over a claude.ai login (Claude Code's documented
///   precedence), with `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` so the commands and MCP servers it starts don't see it.
///   `ANTHROPIC_AUTH_TOKEN` (which would win over the key) is left out of those runs.
/// - Codex: `CODEX_API_KEY`, which `codex exec` uses over the ChatGPT login in ~/.codex/auth.json. Codex hands MCP
///   servers only a short list of variables, and keeps names with KEY in them from the commands it runs
///   (`shell_environment_policy.ignore_default_excludes=false`, passed with -c).
///
/// Neither writes anything to ~/.claude, ~/.claude.json, ~/.codex or Claude Code's Keychain item: the person's own
/// Claude Code and Codex keep their sign-in. `claudeAuth` / `codexAuth` ("subscription" or "api") say which one
/// Petal's runs use.
enum APIKeys {
    static let service = "tech.edgetr.petal.api"

    /// Read once, then kept in memory, so the chat and quick calls don't ask the Keychain every time.
    private final class Cache: @unchecked Sendable {
        private var keys: [Provider: String?] = [:]
        private let lock = NSLock()
        func get(_ provider: Provider, _ load: () -> String?) -> String? {
            lock.lock(); defer { lock.unlock() }
            if let cached = keys[provider] { return cached }
            let key = load()
            keys[provider] = .some(key)
            return key
        }
        func set(_ provider: Provider, _ key: String?) { lock.lock(); keys[provider] = .some(key); lock.unlock() }
    }
    private static let cache = Cache()

    private static func query(_ provider: Provider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: provider.keyAccount]
    }

    static func key(_ provider: Provider) -> String? {
        if Headless.on { return nil }   // a benchmark or snapshot never reads the Keychain
        return cache.get(provider) {
            var query = query(provider)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            let key = String(decoding: data, as: UTF8.self)
            return key.isEmpty ? nil : key
        }
    }

    static func hasKey(_ provider: Provider) -> Bool { key(provider) != nil }

    /// Saves (or replaces) the key; false when the Keychain refused.
    @discardableResult
    static func save(_ key: String, for provider: Provider) -> Bool {
        if Headless.on { return false }
        let data = Data(key.utf8)
        var status = SecItemUpdate(query(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(provider)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Petal: \(provider.keyMaker) API key"
            item[kSecAttrDescription as String] = "API key Petal's own AI runs use"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status == errSecSuccess { cache.set(provider, key) }
        return status == errSecSuccess
    }

    static func remove(_ provider: Provider) {
        if Headless.on { return }
        SecItemDelete(query(provider) as CFDictionary)
        cache.set(provider, nil)
    }

    /// The end of a key, enough to tell which one it is: "sk-ant-…x7Qa".
    static func masked(_ key: String) -> String {
        let prefix = key.hasPrefix("sk-ant-") ? "sk-ant-" : key.hasPrefix("sk-") ? "sk-" : ""
        return prefix + "…" + key.suffix(4)
    }

    /// The environment for one of Petal's runs of `provider`: `base` as it is on a subscription; with the key on an
    /// API key. A missing key adds nothing: callers check `PetalApp.aiReady` first, so a run never quietly falls
    /// back to the subscription.
    static func environment(_ base: [String: String], for provider: Provider, api: Bool) -> [String: String] {
        guard api, let key = key(provider) else { return base }
        var environment = base
        switch provider {
        case .claude:
            environment["ANTHROPIC_API_KEY"] = key
            environment["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] = "1"
            environment["ANTHROPIC_AUTH_TOKEN"] = nil
            environment["CLAUDE_CODE_OAUTH_TOKEN"] = nil
        case .codex:
            environment["CODEX_API_KEY"] = key
        }
        return environment
    }

    /// Whether a CLI's error means the key (or sign-in) wasn't accepted.
    static func isAuthError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("401") || lower.contains("invalid api key") || lower.contains("invalid_api_key")
            || lower.contains("incorrect api key") || lower.contains("authentication_failed") || lower.contains("invalid x-api-key")
    }

    /// The same, in plain words.
    static func plain(_ error: String, _ provider: Provider) -> String {
        let lower = error.lowercased()
        if isAuthError(error) { return "\(provider.keyMaker) didn't accept this key." }
        if lower.contains("credit balance") || lower.contains("insufficient_quota") || lower.contains("billing") || lower.contains("quota") {
            return "This key has no credit left. Add some on \(provider.keyMaker)'s site."
        }
        if lower.contains("429") || lower.contains("rate limit") { return "\(provider.keyMaker) is busy for this key. Try again in a minute." }
        if lower.contains("could not resolve") || lower.contains("network") || lower.contains("connect") {
            return "Couldn't reach \(provider.keyMaker). Check your connection."
        }
        let line = error.split(separator: "\n").first.map(String.init) ?? error
        return String(line.prefix(160))
    }
}

/// What Codex's tokens cost on an API key, roughly. Codex reports tokens, not money, so Petal prices them with
/// OpenAI's list prices per million tokens (input, cached input, output) for its model tiers: the small, fast models
/// (Luna, mini) and the rest. An estimate; the bill on OpenAI's own usage page is the real one.
enum APIPricing {
    static let small = (input: 0.25, cached: 0.025, output: 2.0)
    static let large = (input: 1.25, cached: 0.125, output: 10.0)

    static func codex(model: String, input: Int, cached: Int, output: Int) -> Double {
        let lower = model.lowercased()
        let price = lower.contains("luna") || lower.contains("mini") || lower.contains("nano") ? small : large
        let fresh = max(0, input - cached)
        return (Double(fresh) * price.input + Double(cached) * price.cached + Double(output) * price.output) / 1_000_000
    }
}

extension Provider {
    var authSetting: String { self == .claude ? "claudeAuth" : "codexAuth" }
    var keyAccount: String { self == .claude ? "anthropic" : "openai" }
    var keyMaker: String { self == .claude ? "Anthropic" : "OpenAI" }
    var keysPage: URL {
        URL(string: self == .claude ? "https://console.anthropic.com/settings/keys" : "https://platform.openai.com/api-keys")!
    }
}

extension PetalApp {
    /// Whether Petal's runs of `provider` use an API key instead of the person's subscription.
    func usesAPIKey(_ provider: Provider) -> Bool { config.string(provider.authSetting) == "api" }

    /// On an API key, a key has to be saved; on a subscription, nothing more is needed here.
    func aiReady(_ provider: Provider) -> Bool { !usesAPIKey(provider) || APIKeys.hasKey(provider) }

    /// The environment for a run of `provider`: childEnvironment, with the key when it's on one.
    func aiEnvironment(_ provider: Provider) -> [String: String] {
        APIKeys.environment(childEnvironment, for: provider, api: usesAPIKey(provider))
    }
}

/// Checking a key with one tiny quick call (a few tokens on the cheap model): OK, or why not, in plain words.
@MainActor @Observable
final class APIKeyCheck {
    enum State: Equatable { case idle, checking, ok, failed(String) }
    private(set) var states: [Provider: State] = [:]
    /// The saved key's masked end per AI, so the settings follow a save or remove (the Keychain isn't observable).
    private var masked: [Provider: String?] = [:]

    func state(_ provider: Provider) -> State { states[provider] ?? .idle }
    func reset(_ provider: Provider) { states[provider] = .idle }

    func savedKey(_ provider: Provider) -> String? {
        if let known = masked[provider] { return known }
        return APIKeys.key(provider).map(APIKeys.masked)
    }

    func save(_ key: String, for provider: Provider) -> Bool {
        guard APIKeys.save(key, for: provider) else { return false }
        masked[provider] = .some(APIKeys.masked(key))
        check(provider)
        return true
    }

    func remove(_ provider: Provider) {
        APIKeys.remove(provider)
        masked[provider] = .some(nil)
        states[provider] = .idle
    }

    func check(_ provider: Provider) {
        let app = PetalApp.shared
        guard let path = app.paths[provider] else {
            states[provider] = .failed("Install \(provider.appName) first, above.")
            return
        }
        guard APIKeys.hasKey(provider) else { states[provider] = .failed("Save a key first."); return }
        states[provider] = .checking
        let environment = APIKeys.environment(app.childEnvironment, for: provider, api: true)
        var arguments = provider.quickArguments
        let model = provider == .codex ? (app.quickCodexModel ?? "") : "haiku"
        if provider == .codex, !model.isEmpty { arguments.insert(contentsOf: ["-m", model], at: arguments.count - 1) }
        Task {
            let result = await Task.detached { Self.run(path, arguments, environment: environment) }.value
            let reply = provider.quickResult(result.output)
            if let spent = provider.quickSpend(result.output, model: model) { app.usage.addSpend(spent, for: provider) }
            if let error = reply.error ?? (result.status != 0 ? (result.output.isEmpty ? "It didn't answer." : result.output) : nil) {
                states[provider] = .failed(APIKeys.plain(error, provider))
            } else {
                states[provider] = .ok
            }
        }
    }

    /// Runs the call and stops at the first sign the key was refused: Codex otherwise tries again for a while.
    nonisolated private static func run(_ path: String, _ arguments: [String], environment: [String: String]) -> AISetup.Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let text = TextBox()
        let buffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for line in buffer.lines(adding: chunk) {
                text.append(line + "\n")
                let failure = line.contains("\"type\":\"error\"") || line.contains("\"type\":\"turn.failed\"")
                if failure, APIKeys.isAuthError(line), process.isRunning { process.terminate() }
            }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return AISetup.Result(status: -1, output: "") }
        try? input.fileHandleForWriting.write(contentsOf: Data("Reply with the word OK.".utf8))
        try? input.fileHandleForWriting.close()
        if finished.wait(timeout: .now() + 60) == .timedOut {
            process.terminate()
            finished.wait()
        }
        output.fileHandleForReading.readabilityHandler = nil
        for line in buffer.lines(adding: output.fileHandleForReading.readDataToEndOfFile()) { text.append(line + "\n") }
        text.append(buffer.rest())
        return AISetup.Result(status: process.terminationStatus, output: text.text)
    }
}

extension SettingsList {
    /// How each chosen AI is paid for: the person's subscription, or an API key of theirs.
    static let paying = SettingsBlock("Paying", says: { app in
        app.providers.contains(where: app.usesAPIKey) ? "Your key stays in your Mac’s Keychain. Only Petal AI uses it." : nil
    }, when: { !$0.providers.isEmpty }, Provider.allCases.map { provider in
        SettingsEntry(provider.authSetting, provider.name, words: "pay paying subscription api key billing \(provider.keyMaker.lowercased())",
                      when: { $0.providers.contains(provider) }) { APIKeyRows(provider: provider, title: $0) }
    })
}

/// Settings › Petal AI, per AI: pay with the subscription or an API key; the key pasted into a secure field, saved in
/// the Keychain, checked with one tiny call.
struct APIKeyRows: View {
    @Environment(PetalApp.self) private var app
    let provider: Provider
    let title: String
    @State private var draft = ""
    @State private var replacing = false
    @State private var refused = false

    var body: some View {
        let _ = BodyCount.hit("APIKeyCard")
        let api = app.usesAPIKey(provider)
        let key = app.apiKeyCheck.savedKey(provider)
        let check = app.apiKeyCheck.state(provider)
        ChoiceRow(title: title, options: [("subscription", "My subscription"), ("api", "An API key")],
                  selection: Binding(get: { api ? "api" : "subscription" }, set: {
                      app.config.set(provider.authSetting, $0)
                      app.apiKeyCheck.reset(provider)
                      Task { await app.usage.refresh(provider) }
                  }))
        if api {
            if let key, !replacing {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                    Text(key).font(.system(size: TextSize.callout, design: .monospaced))
                    status(check)
                    Spacer(minLength: 8)
                    Button("Check") { app.apiKeyCheck.check(provider) }.buttonStyle(.glass).disabled(check == .checking)
                    Button("Replace") { replacing = true; draft = "" }.buttonStyle(.glass)
                    Button("Remove") { app.apiKeyCheck.remove(provider) }.buttonStyle(.glass)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        SecureField("Paste your \(provider.keyMaker) API key", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(save)
                        Button("Save", action: save).buttonStyle(.glassProminent).tint(Part.ai.color)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if replacing { Button("Cancel") { replacing = false; draft = "" }.buttonStyle(.glass) }
                    }
                    if refused {
                        Text("The Keychain didn't save it. Try again.").font(.system(size: TextSize.callout)).foregroundStyle(Self.trouble)
                    }
                    Link("Get a key from \(provider.keyMaker)", destination: provider.keysPage).font(.system(size: TextSize.callout))
                }
            }
        }
    }

    /// What went wrong, in the red the chat uses for it.
    private static let trouble = Color(red: 1, green: 0.42, blue: 0.54)

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        refused = !app.apiKeyCheck.save(key, for: provider)
        guard !refused else { return }
        draft = ""
        replacing = false
    }

    @ViewBuilder private func status(_ state: APIKeyCheck.State) -> some View {
        switch state {
        case .idle: EmptyView()
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }.font(.system(size: TextSize.callout))
        case .ok:
            Label("Works", systemImage: "checkmark.circle.fill").font(.system(size: TextSize.callout)).foregroundStyle(.green)
        case .failed(let text):
            Text(text).font(.system(size: TextSize.callout)).foregroundStyle(Self.trouble).fixedSize(horizontal: false, vertical: true)
        }
    }
}
