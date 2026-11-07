import AppKit

/// Quick JSON calls that sort activity into modes (Brain.qml), to the chosen AI's quick, cheap setting (Claude
/// Haiku; Codex at low effort): one at a time, answers cached.
@MainActor
final class Brain {
    private var queue: [(prompt: String, key: String, done: ([String: Any]?) -> Void)] = []
    private var busy = false
    private var cache: [String: [String: Any]] = [:]

    var enabled: Bool {
        let app = PetalApp.shared
        guard app.config.bool("ai"), let provider = app.chatProvider else { return false }
        return app.paths[provider] != nil && app.aiReady(provider)
    }

    func classifyWindow(app: String, title: String, key: String? = nil, done: @escaping ([String: Any]?) -> Void) {
        let prompt = """
        You sort a user's desktop activity into focus modes.
        Modes:
        \(modesBrief)

        Focused window: app="\(app)" title="\(title)"
        Which mode does this activity belong to? Use null if none fits.
        Reply with ONLY JSON: {"mode": "<id>"|null, "reason": "<max 8 words, what it is>"}
        """
        ask(prompt, key: key.map { "w|" + $0 } ?? "w|\(app)|\(title)", done: done)
    }

    /// Which mode a notification belongs to, and whether it can't wait (Brain.qml's classifyNotification).
    func classifyNotification(app: String, title: String, body: String, done: @escaping ([String: Any]?) -> Void) {
        let prompt = """
        You triage notifications for a user in focus modes.
        Modes:
        \(modesBrief)

        Notification from app "\(app)": "\(title)" — "\(body.prefix(300))"
        Which mode does it belong to, and is it time-sensitive (needs an answer within the hour, or is an emergency)?
        Reply with ONLY JSON: {"mode": "<id>"|null, "urgent": true|false, "reason": "<max 8 words>"}
        """
        ask(prompt, key: "n|\(app)|\(title)|\(body)", done: done)
    }

    /// Whether a mode pulls you away from work: asked once for a mode that doesn't say.
    func isDistracting(_ mode: Mode, done: @escaping ([String: Any]?) -> Void) {
        let apps = mode.apps.prefix(12).map(Apps.name).joined(separator: ", ")
        let prompt = """
        A focus mode in a dock is named "\(mode.name)". It's for: \(mode.about.isEmpty ? "(not said)" : mode.about). Its apps: \(apps.isEmpty ? "(none yet)" : apps).
        Is it a mode that's mainly for distraction, like social media, chatting with friends, videos or games? An everyday or general mode with a mix of apps (work tools among them) is not.
        Reply with ONLY JSON: {"distracting": true|false}
        """
        ask(prompt, key: "d|\(mode.id)|\(mode.name)|\(mode.about)", done: done)
    }

    /// A name, symbol, color and about for a new mode holding `apps` (names), unlike the modes there are.
    func nameMode(apps: [String], done: @escaping ([String: Any]?) -> Void) {
        let colors = PetalApp.shared.config.modes.map(\.hex).joined(separator: ", ")
        let prompt = """
        You name focus modes for a dock. Each mode has its own apps; the user switches a Desktop into a mode.
        Modes they have:
        \(modesBrief)

        These apps are often used together: \(apps.joined(separator: ", ")).
        Name a new mode for them: 1 or 2 words, unlike the existing names. Pick an SF Symbol name for its icon, a #rrggbb color unlike these (\(colors)), and a short about: what the mode is for, used to sort new apps into it. Say whether it pulls you away from work, like social media, chat, videos or games.
        Reply with ONLY JSON: {"name": "<name>", "icon": "<SF Symbol>", "color": "#rrggbb", "about": "<under 12 words>", "distracting": true|false}
        """
        ask(prompt, key: "n|" + apps.joined(separator: "|"), done: done)
    }

    private var modesBrief: String {
        PetalApp.shared.config.modes.map { m in
            "- \(m.id) (\(m.name)): \(m.about)" + (m.sites.isEmpty ? "" : "; sites: " + m.sites.joined(separator: ", "))
        }.joined(separator: "\n")
    }

    /// One quick JSON call (answers cached by `key`).
    func ask(_ prompt: String, key: String, done: @escaping ([String: Any]?) -> Void) {
        if let cached = cache[key] { return done(cached) }
        queue.append((prompt, key, done))
        next()
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        // No AI chosen (all of them turned off): everyone waiting hears nothing, so a routine waiting on an answer
        // moves on. One chosen but not found yet (at launch) is waited for.
        guard let provider = PetalApp.shared.chatProvider else {
            let waiting = queue
            queue = []
            for job in waiting { job.done(nil) }
            return
        }
        guard let path = PetalApp.shared.paths[provider] else { return }
        // On an API key with none saved, nothing is asked (and nothing falls back to the subscription).
        guard PetalApp.shared.aiReady(provider) else {
            let waiting = queue
            queue = []
            for job in waiting { job.done(nil) }
            return
        }
        busy = true
        let job = queue.removeFirst()
        let environment = PetalApp.shared.aiEnvironment(provider)
        let api = PetalApp.shared.usesAPIKey(provider)
        var arguments = provider.quickArguments
        // Codex's quick calls go to its newest Luna, its small fast model, at low effort.
        let luna = provider == .codex ? PetalApp.shared.quickCodexModel : nil
        if let luna { arguments.insert(contentsOf: ["-m", luna], at: arguments.count - 1) }
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            var answer: [String: Any]?
            var spent: Double?
            if (try? process.run()) != nil {
                input.fileHandleForWriting.write(Data(job.prompt.utf8))
                try? input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let raw = String(decoding: data, as: UTF8.self)
                let text = provider.quickReply(raw)
                if api { spent = provider.quickSpend(raw, model: luna ?? "") }
                if process.terminationStatus == 0, let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
                    answer = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let spent { PetalApp.shared.usage.addSpend(spent, for: provider) }
                    if let answer { self.cache[job.key] = answer }
                    job.done(answer)
                    self.busy = false
                    self.next()
                }
            }
        }
    }
}

extension PetalApp {
    /// The newest "Luna" model Codex lists (`codex debug models`), for quick calls; nil leaves Codex's default.
    var quickCodexModel: String? {
        func version(_ model: CodexModel) -> [Int] {
            let digits = model.name.split(whereSeparator: { !$0.isNumber && $0 != "." }).first ?? ""
            return digits.split(separator: ".").map { Int($0) ?? 0 }
        }
        return codexModels.filter { "\($0.id) \($0.name)".localizedCaseInsensitiveContains("luna") }
            .max { version($0).lexicographicallyPrecedes(version($1)) }?.id
    }
}
