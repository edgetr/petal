import Foundation

/// Petal's own bookkeeping on this Mac (state.json in Application Support): what its AI runs spent on an API key
/// this month (`aiSpend`), when each stack was last opened (`stacksSeen`), and the version Petal last ran as
/// (`lastVersion`: What's New opens once after an update, `ReleaseNotes.afterLaunch`).
enum PetalState {
    static let file = Config.supportFolder.appending(path: "state.json")

    static func read() -> [String: Any] { MCP.read(file) ?? [:] }

    /// One writer at a time: the AI's spending and the stacks' last opening each read, change and write it.
    private static let lock = NSLock()

    static func set(_ key: String, _ value: Any) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? MCP.update(file) { $0[key] = value }
    }
}
