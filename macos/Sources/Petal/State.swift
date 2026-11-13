import Foundation

/// Petal's own bookkeeping on this Mac (state.json in Application Support): what its AI runs spent on an API key
/// this month (`aiSpend`), when each stack was last opened (`stacksSeen`), and the version Petal last ran as
/// (`lastVersion`: What's New opens once after an update, `ReleaseNotes.afterLaunch`).
enum PetalState {
    static let file = Config.supportFolder.appending(path: "state.json")

    static func read() -> [String: Any] { MCP.read(file) ?? [:] }

    /// One writer at a time: the AI's spending and the stacks' last opening each read, change and write it.
    private static let lock = NSLock()

    /// True once the value is on disk. A file that's there but doesn't read as JSON is Petal's own bookkeeping, not
    /// the person's: it starts again with this value, so nothing kept here is stuck unwritten from then on.
    @discardableResult
    static func set(_ key: String, _ value: Any) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? MCP.update(file, { $0[key] = value })) != nil { return true }
        guard FileManager.default.fileExists(atPath: file.path), MCP.read(file) == nil,
              let data = try? JSONSerialization.data(withJSONObject: [key: value], options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? (data + Data("\n".utf8)).write(to: file, options: .atomic)) != nil
    }
}
