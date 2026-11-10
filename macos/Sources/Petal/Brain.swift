import AppKit

/// Quick JSON calls to the chosen AI's quick, cheap setting (Claude Haiku; Codex at low effort), for routines that
/// sort files by what they are and for helpers in notes: one at a time, answers cached.
@MainActor
final class Brain {
    /// What a note helper's call is made into when its turn in the line comes (`NoteHelpers.prepare`): its words, a
    /// wait (its run paused, or its gate: it goes back in line), or nothing to send.
    enum Made { case go(Shielded), wait, over }
    /// What a call sends: a routine's sorting prompt, or a note helper's words, made only when the call starts (never
    /// kept in the line as text).
    private enum Words {
        case text(String)
        case made((@escaping @MainActor (Made) -> Void) -> Void)
    }
    private typealias Job = (words: Words, key: String, done: ([String: Any]?) -> Void)
    /// Calls waiting (NoteHelp's QuickQueue: each out of the queue before anything is called back).
    private var queue = QuickQueue<Job, Provider>()
    private var busy = false
    private var cache: [String: [String: Any]] = [:]

    var enabled: Bool {
        let app = PetalApp.shared
        guard app.config.bool("ai"), let provider = app.chatProvider else { return false }
        return app.paths[provider] != nil && app.aiReady(provider)
    }

    /// One quick JSON call (answers cached by `key`).
    func ask(_ prompt: String, key: String, done: @escaping ([String: Any]?) -> Void) {
        if let cached = cache[key] { return done(cached) }
        queue.add(.init(job: (.text(prompt), key, done), token: nil, provider: nil, gate: nil))
        next()
    }

    /// A note helper's quick call: only words NoteShield made, and made only when the call starts (`make`, the
    /// helpers' `prepare`: the vault, the cover, the gate, then the words from its sources as they are then); what
    /// waits in the line is how to make them, never the words. Admitted only while its run runs (paused, it waits
    /// in the queue, and a call under way is ended and kept for Go on; stopped, it's dropped and its process ended).
    /// `provider`: the AI the person named (validated by the helper), else the chat's. `gate`: the helper's admission,
    /// asked right when the call would start (false: it waits, or its run already failed).
    func ask(key: String, token: RunToken, provider: Provider? = nil, gate: (() -> Bool)? = nil,
             make: @escaping (@escaping @MainActor (Made) -> Void) -> Void, done: @escaping ([String: Any]?) -> Void) {
        queue.add(.init(job: (.made(make), key, done), token: token, provider: provider, gate: gate))
        next()
    }

    /// A run went on (Go on) or ended: its calls waiting are admitted again, or dropped. Asked later, never inside a
    /// pass (an answer that ends a run asks again from outside it).
    func resume() { DispatchQueue.main.async { MainActor.assumeIsolated { self.next() } } }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        // One pass: calls of stopped runs taken out; calls of paused runs wait where they are; the first admitted goes
        // now, a helper's only once its gate admits it right then. Its own AI first (the one the person named, else
        // the chat's), and only then whether that one is ready: none chosen, a named one not found, or one on an API
        // key with none saved hears nothing (never another instead, never a quiet fall back to the subscription). The
        // chat's not found yet (at launch) is waited for.
        let app = PetalApp.shared
        let step = queue.pass { named in
            guard let provider = named ?? app.chatProvider else { return .none }
            guard app.paths[provider] != nil else { return named == nil ? .wait : .none }
            return app.aiReady(provider) ? .go(provider) : .none
        }
        // What's dropped is answered later, outside this pass (its answer may end a run, which asks the queue again).
        for entry in step.dropped { DispatchQueue.main.async { entry.job.done(nil) } }
        guard let (entry, provider) = step.start, let path = app.paths[provider] else { return }
        busy = true
        switch entry.job.words {
        case .text(let prompt): run(entry, prompt, provider: provider, path: path)
        case .made(let make):
            // Its turn: its words are made now, and it goes at once, or not at all.
            make { made in
                switch made {
                case .go(let words): self.run(entry, words.text, provider: provider, path: path)
                case .wait:
                    // Paused, or held by its gate (either keeps a pass from picking it): back in line, first.
                    self.queue.putBack(entry)
                    self.busy = false
                    self.next()
                case .over:
                    self.busy = false
                    DispatchQueue.main.async { entry.job.done(nil) }
                    self.next()
                }
            }
        }
    }

    /// One call's process, with words made just now.
    private func run(_ entry: QuickQueue<Job, Provider>.Entry, _ prompt: String, provider: Provider, path: String) {
        let job = (prompt: prompt, key: entry.job.key, token: entry.token, done: entry.job.done)
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
            var handle: Int?
            if (try? process.run()) != nil {
                if let token = job.token {
                    handle = token.bind { [weak process] in process?.terminate() }
                    if handle == nil { process.terminate() }
                }
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
            job.token?.unbind(handle)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let spent { PetalApp.shared.usage.addSpend(spent, for: provider) }
                    // Paused while it ran: kept, first in line, for Go on (its answer, if any, isn't used).
                    if job.token?.paused == true {
                        self.queue.putBack(entry)
                        self.busy = false
                        return self.next()
                    }
                    if let answer, job.token == nil { self.cache[job.key] = answer }
                    job.done(job.token.map { $0.admits } == false ? nil : answer)
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
