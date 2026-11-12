import AppKit
import Security

/// What Petal AI did (shown in Settings › Privacy, each with its own undo where there is one), the apps it never looks
/// into, and keeping the vault's secrets out of everything it reads.
extension Assist {
    // MARK: What it did

    enum Undo: Codable, Equatable {
        case putBack([[String]])          // [from, to in the Trash]
        case forget(String)               // a memory's id
        case remember(String)             // a memory's text
        case open(String, String)         // a page: path, title (not an undo: open it again)
    }

    struct Done: Codable, Identifiable, Equatable {
        var id = UUID()
        let at: Date
        let text: String
        var undo: Undo?
        var undone = false
    }

    static var historyFile: URL {
        Config.supportFolder.appending(path: "ai-history.json")
    }

    /// The one way a line gets into What Petal AI did. A line of Petal's own words is kept at once; one that names
    /// anything (HistoryLine) is kept once each name went through the vault's settled redaction, off the main thread
    /// (the index may read the Keychain), with every name left out while the vault can't be read. Kept by when it
    /// happened, not when its redaction was done.
    func did(_ line: HistoryLine, undo: Undo? = nil) {
        let at = Date()
        guard line.hasNames else { return keep(Done(at: at, text: line.text(nil), undo: undo)) }
        Self.lineQueue.async {
            let text = (VaultIndex.settled { index in index.unreadable ? nil : line.text { index.redacted($0) } } ?? nil) ?? line.text(nil)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.keep(Done(at: at, text: text, undo: undo)) } }
        }
    }

    nonisolated private static let lineQueue = DispatchQueue(label: "petal.ai-history.lines", qos: .utility)

    private func keep(_ done: Done) {
        var list = history
        // Newest first; one whose redaction finished late goes where it happened.
        list.insert(done, at: list.firstIndex { $0.at <= done.at } ?? list.count)
        history = Array(list.prefix(200))
        saveHistory()
    }

    func loadHistory() {
        guard let data = try? Data(contentsOf: Self.historyFile) else { return }
        history = (try? JSONDecoder().decode([Done].self, from: data)) ?? []
    }

    /// One at a time, in order (an older save never lands after a newer one), and flushed on quit.
    nonisolated static let historyQueue = DispatchQueue(label: "petal.ai-history", qos: .utility)
    nonisolated static func flushHistory() { historyQueue.sync {} }

    private func saveHistory() {
        let list = history
        Self.historyQueue.async {
            try? FileManager.default.createDirectory(at: Self.historyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(list) { try? data.write(to: Self.historyFile, options: .atomic) }
        }
    }

    /// Undoes one thing it did (or opens the page again).
    func undo(_ done: Done) {
        guard let undo = done.undo else { return }
        switch undo {
        case .putBack(let pairs):
            // The files move off the main thread; what couldn't come back stays to try again.
            Self.historyQueue.async {
                var stuck: [[String]] = []
                let fm = FileManager.default
                for pair in pairs where pair.count == 2 {
                    guard fm.fileExists(atPath: pair[1]) else { continue }   // emptied from the Trash: nothing to bring
                    if fm.fileExists(atPath: pair[0]) || (try? fm.moveItem(atPath: pair[1], toPath: pair[0])) == nil { stuck.append(pair) }
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let index = self.history.firstIndex(where: { $0.id == done.id }) else { return }
                        if stuck.isEmpty { self.history[index].undone = true } else { self.history[index].undo = .putBack(stuck) }
                        self.saveHistory()
                    }
                }
            }
            return
        case .forget(let id): forget(id: id, matching: nil)
        case .remember(let text): remember(text, learned: false)
        case .open(let path, let title):
            Pages.open(URL(fileURLWithPath: path), title: title)
            return
        }
        if let index = history.firstIndex(where: { $0.id == done.id }) { history[index].undone = true; saveHistory() }
    }

    // MARK: Apps it never looks into

    /// Password managers and the like: their names only, never what's in them, nor in a picture of the screen.
    func neverLook(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return config.strings("aiNeverLook").contains(bundleID)
    }

    var privatePIDs: Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications.filter { neverLook($0.bundleIdentifier) }.map(\.processIdentifier))
    }

    // MARK: The vault (VaultStore.swift keeps it, VaultFill.swift uses it)

    /// Whether `text` is one of the vault's secrets, holds 8 characters or more of one, or holds a short one (a PIN)
    /// as a word of its own, anywhere in it; or is too long to look through (about 1 MB): petal_act never types one
    /// (the vault fills its own, VaultFill.swift), and petal_ui never shows one. The first call after the vault changes
    /// reads the Keychain: off the main thread.
    nonisolated static func isVaultSecret(_ text: String) -> Bool {
        vaultCheck(text) != .clean
    }

    /// The same, saying which: a secret, too long to check, or the vault couldn't be read (nothing checked).
    nonisolated static func vaultCheck(_ text: String) -> UIMap.SecretIndex.Check {
        text.isEmpty ? .clean : VaultIndex.settled { $0.check(text) } ?? .unreadable
    }

    /// What may be told of `text`: the vault's secrets in it as "(hidden)", all of it searched, then cut to `limit`
    /// characters; nil when it's too long to search. While the vault can't be read, it says so instead of the text.
    /// Off the main thread.
    nonisolated static func shownText(_ text: String, limit: Int) -> String? {
        let shown: String?? = VaultIndex.settled { index in
            if index.unreadable { return Self.vaultUnreadable }
            guard index.isEmpty || text.utf8.count <= UIMap.SecretIndex.limit else { return nil }
            let clean = index.redacted(text)
            return clean.count > limit ? String(clean.prefix(limit)) : clean
        }
        switch shown {
        case .some(let text): return text   // nil inside: too long to search
        case .none: return Self.vaultUnreadable
        }
    }

    nonisolated static let vaultUnreadable = "(hidden: Petal can't read the vault right now, so it can't check this for saved secrets)"
}

/// The vault's secrets as hashes (UIMap.SecretIndex), read from the Keychain once and again only after the vault
/// changes, so checking every control petal_ui reads never touches the Keychain. With them, every secret Petal typed
/// into a field this run (`typed`), saved or not: a login asked for without saving it, or one the Keychain refused,
/// is hidden from the AI just the same. Never on the main thread.
enum VaultIndex {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var index: UIMap.SecretIndex?
    nonisolated(unsafe) private static var generation = 0
    /// Secrets Petal typed, kept (in memory only) until Petal quits.
    nonisolated(unsafe) private static var typed: [String] = []

    /// A secret was saved or removed: the next check reads the vault again.
    static func changed() {
        lock.lock()
        index = nil
        failedAt = nil
        generation += 1
        lock.unlock()
        DispatchQueue.main.async { MainActor.assumeIsolated { VaultModel.shared.changed() } }
    }

    /// Secrets Petal is about to type (every form of each: Vault.secrets): hidden from the AI from now on.
    static func remember(_ secrets: [String]) {
        let fresh = secrets.filter { !$0.isEmpty }
        guard !fresh.isEmpty else { return }
        lock.lock()
        var added = false
        for secret in fresh where !typed.contains(secret) {
            typed.append(secret)
            added = true
        }
        if added {
            index = nil
            generation += 1
        }
        lock.unlock()
    }

    /// When the vault last couldn't be read: asked again a second later at the soonest, so a locked Keychain isn't
    /// asked once per control petal_ui reads.
    nonisolated(unsafe) private static var failedAt: Date?

    private static var now: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// The index for the vault and what Petal typed as they are now: made again (a few times at most) while a save,
    /// a removal or a secret Petal is about to type changed them under it, so no reader gets one that misses it.
    /// `unavailable` when the vault can't be read, or kept changing.
    /// The index if it's already made (never reads the Keychain): for a check that may run on the main thread.
    static func cached() -> UIMap.SecretIndex? {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    nonisolated(unsafe) private static var warming = false

    /// The index made in the background when there's none yet, one read at a time: so a line that couldn't be checked
    /// without waiting (`cached` nil) can be the next time. Nobody waits for it.
    static func warm() {
        guard !Headless.on else { return }
        lock.lock()
        let start = index == nil && !warming
        if start { warming = true }
        lock.unlock()
        guard start else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = current()
            lock.lock()
            warming = false
            lock.unlock()
        }
    }

    static func current() -> UIMap.SecretIndex {
        lock.lock()
        if let index { lock.unlock(); return index }
        if let failedAt, Date().timeIntervalSince(failedAt) < 1 { lock.unlock(); return .unavailable }
        lock.unlock()
        let made = UIMap.settled(generation: { now }) { () -> UIMap.SecretIndex? in
            lock.lock()
            let extra = typed
            lock.unlock()
            guard let items = try? VaultStore.items() else { return nil }
            return UIMap.SecretIndex(items.flatMap(Vault.secrets) + extra, words: items.flatMap(Vault.noteCodes))
        }
        lock.lock()
        defer { lock.unlock() }
        guard let made, let built = made.value else {
            // Never a shorter index: what can't be checked isn't shown. The Keychain is asked again next time.
            if let made, made.value == nil { failedAt = Date() }
            return .unavailable
        }
        failedAt = nil
        if generation == made.generation { index = built }   // a change since is read next time
        return built
    }

    /// `work` with the current index, done again (a few times at most) if the vault or what Petal typed changed
    /// while it ran, so redacted text never goes out with an index that misses a secret; nil when it kept changing.
    static func settled<T>(_ work: (UIMap.SecretIndex) -> T) -> T? {
        UIMap.settled(generation: { now }) { work(current()) }?.value
    }

    /// `settled`, with the generation it was made under: `unchanged(since:)` then says whether the vault and what
    /// Petal typed are still as they were (a prompt built a moment ago is still built with every secret there is).
    static func stamped<T>(_ work: (UIMap.SecretIndex) -> T) -> (value: T, stamp: Int)? {
        UIMap.settled(generation: { now }) { work(current()) }.map { ($0.value, $0.generation) }
    }

    static func unchanged(since stamp: Int) -> Bool { now == stamp }
}
