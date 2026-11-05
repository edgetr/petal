import Foundation
import Observation

/// A Claude usage limit: what share of it is used (0–1) and when it resets.
struct UsageLimit: Equatable {
    let label: String
    let percent: Double
    let resetsAt: Date?
}

/// Usage for the ring around the AI button, every 5 minutes. Codex keeps its limits in its own session logs. Claude's
/// come as Omarchy's
/// omarchy-agent-usage-claude does it: the Claude Code login's access token asks Anthropic's usage endpoint for the
/// 5-hour session and the weekly limit. On macOS Claude Code keeps its login in the Keychain, read here with
/// macOS's own `security` tool. The token goes nowhere but that one request's Authorization header.
@MainActor @Observable
final class Usage {
    private(set) var limits: [UsageLimit] = []
    private(set) var help = ""
    @ObservationIgnored private var timer: Timer?

    /// The fullest limit: what the ring shows.
    var worst: UsageLimit? { limits.max { $0.percent < $1.percent } }

    func start(enabled: @escaping () -> Bool) {
        timer?.invalidate()
        let poll = { [weak self] in
            guard enabled() else { self?.limits = []; return }
            Task { await self?.refresh() }
        }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in MainActor.assumeIsolated { poll() } }
    }

    func refresh() async {
        switch PetalApp.shared.chatProvider {
        case .claude?: await refreshClaude()
        case .codex?: await refreshCodex()
        case nil: limits = []; help = ""
        }
    }

    /// The newest Codex session log's last rate limits: a primary and maybe a secondary window. Read off the main
    /// thread: a log can be long.
    private func refreshCodex() async {
        let found = await Task.detached { Self.codexLimits() }.value
        limits = found ?? []
        help = found == nil ? "Use Codex once to see your usage." : ""
    }

    nonisolated private static func codexLimits() -> [UsageLimit]? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }) ?? []
        let date = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        guard let newest = files.max(by: { date($0) < date($1) }), let text = try? String(contentsOf: newest, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let limits = find("rate_limits", in: event) as? [String: Any] else { continue }
            var found: [UsageLimit] = []
            for key in ["primary", "secondary"] {
                guard let window = limits[key] as? [String: Any], let used = number(window["used_percent"]) else { continue }
                let minutes = number(window["window_minutes"]) ?? 0
                let label = minutes >= 10_000 ? "Weekly (7-day)" : minutes >= 300 ? "Session (5-hour)" : "Limit"
                found.append(UsageLimit(label: label, percent: min(1, max(0, used / 100)),
                                        resetsAt: number(window["resets_at"]).map { Date(timeIntervalSince1970: $0) }))
            }
            return found
        }
        return nil
    }

    nonisolated private static func find(_ key: String, in object: Any) -> Any? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[key] { return value }
            for value in dictionary.values { if let found = find(key, in: value) { return found } }
        } else if let array = object as? [Any] {
            for value in array { if let found = find(key, in: value) { return found } }
        }
        return nil
    }

    private func refreshClaude() async {
        guard let token = await Self.accessToken() else {
            help = "Sign in to Claude Code to see your usage."
            return
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else {
            help = "Couldn't reach Anthropic. Trying again shortly."
            return
        }
        guard status == 200, let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            help = status == 401 || status == 403 ? "Run `claude auth login` to sign in again." : "Anthropic's usage check answered \(status)."
            return
        }
        var found: [UsageLimit] = []
        for (key, label) in [("five_hour", "Session (5-hour)"), ("seven_day", "Weekly (7-day)")] {
            guard let bucket = payload[key] as? [String: Any], let used = Self.number(bucket["utilization"]) else { continue }
            // The endpoint answers percentages: 0.6 is 0.6%, as Claude Code's own /usage shows it.
            found.append(UsageLimit(label: label, percent: min(1, max(0, used / 100)), resetsAt: Self.date(bucket["resets_at"])))
        }
        limits = found
        help = found.isEmpty ? "Anthropic's usage check returned no limits." : ""
    }

    private static func accessToken() async -> String? {
        let output = await Task.detached { () -> Data? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }.value
        guard let output,
              let login = (try? JSONSerialization.jsonObject(with: output) as? [String: Any])?["claudeAiOauth"] as? [String: Any],
              let token = login["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    nonisolated private static func number(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let s = value as? String { return Double(s.replacingOccurrences(of: "%", with: "")) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
