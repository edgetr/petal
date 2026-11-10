import Foundation

/// Petal for macOS had focus modes (a dock per mode, in modes.json) and now has one dock, kept in dock.json as
/// `apps`. The first launch of this Petal moves the person's dock over, once: the default mode's apps become the
/// dock's, then modes.json goes. The other modes' apps are dropped, and no copy of anything is kept. Settings that
/// only meant something with modes, and six looks Petal never drew, leave settings.json, and the files only the
/// removed features read are removed.
/// Foundation only, so `macos/checks/run.sh` runs it on throwaway folders.
enum ModesMigration {
    enum Outcome: Equatable {
        /// modes.json's default mode became the dock (this many apps), and modes.json is gone.
        case moved(Int)
        /// modes.json is there but can't be read as modes: left as it is, and the dock starts empty.
        case unreadable
        /// No modes.json (a new install, or done before).
        case nothing
    }

    /// settings.json keys that only meant something with modes, focus cards, held notifications, the activity
    /// history or the schedule, and six for looks the dock's glass and Petal's panels never had (a rim, a sheen, a
    /// popup color, a font): nothing reads any of them.
    static let settings = ["modes", "countdown", "focusGuard", "blockDistractions", "peeks", "holdNotifications",
                           "urgentNotifications", "modeWindows", "aiLearns", "dailySummary", "replyDrafts", "schedule",
                           "activityLog", "suggestModes", "summary",
                           "dockBorderColor", "dockBorderOpacity", "dockSheen", "popupColor", "popupOpacity", "font"]

    /// What the removed features kept, by folder: the suggestions answered (config), and the activity history, what
    /// the AI sorted, and the writing style of drafted replies (support).
    static let configLeftovers = ["suggestions.json"]
    static let supportLeftovers = ["activity.jsonl", "sorted.json", "writing-style.json", "quiet-on.txt", "quiet-off.txt"]
    /// state.json keys of the suggestion and summary cards.
    static let stateKeys = ["summaryWeek", "suggestionShown"]

    /// `config`: ~/.config/petal; `support`: Petal's folder in Application Support. Safe to run at every launch:
    /// once done there's nothing left for it to do, and it writes nothing.
    @discardableResult
    static func run(config: URL, support: URL) -> Outcome {
        let outcome = moveDock(in: config)
        scrub(config.appending(path: "settings.json"), keys: settings)
        scrub(support.appending(path: "state.json"), keys: stateKeys)
        let files = FileManager.default
        for name in configLeftovers { try? files.removeItem(at: config.appending(path: name)) }
        for name in supportLeftovers { try? files.removeItem(at: support.appending(path: name)) }
        return outcome
    }

    /// The dock first, read back, and only then is modes.json removed: stopped anywhere, the next launch finishes it.
    private static func moveDock(in config: URL) -> Outcome {
        let files = FileManager.default
        let modesFile = config.appending(path: "modes.json"), dockFile = config.appending(path: "dock.json")
        guard files.fileExists(atPath: modesFile.path) else { return .nothing }
        // A dock.json that's there but can't be read is never written over.
        let dockThere = files.fileExists(atPath: dockFile.path)
        guard let dock = dockThere ? object(dockFile) : [:] else { return .unreadable }
        if let apps = dock["apps"] as? [String] {
            // The dock is already there (this stopped before its last step, or the person made a dock since).
            try? files.removeItem(at: modesFile)
            return .moved(apps.count)
        }
        guard let root = object(modesFile), let modes = root["modes"] as? [[String: Any]] else { return .unreadable }
        let wanted = root["defaultMode"] as? String
        let mode = modes.first { $0["id"] as? String == wanted } ?? modes.first
        var seen = Set<String>()
        let apps = (mode?["apps"] as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        var next = dock
        next["apps"] = apps
        guard write(next, to: dockFile), object(dockFile)?["apps"] as? [String] == apps else { return .unreadable }
        try? files.removeItem(at: modesFile)
        return .moved(apps.count)
    }

    /// Takes `keys` out of a JSON file; one that isn't there, can't be read or has none of them isn't touched.
    private static func scrub(_ file: URL, keys: [String]) {
        guard var root = object(file), keys.contains(where: { root[$0] != nil }) else { return }
        for key in keys { root[key] = nil }
        write(root, to: file)
    }

    private static func object(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// As Config writes its files: pretty, sorted, replaced whole.
    @discardableResult
    private static func write(_ root: [String: Any], to file: URL) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        return (try? (data + Data("\n".utf8)).write(to: file, options: .atomic)) != nil
    }
}
