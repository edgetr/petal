import AppKit

/// A private, local history of which app is in front, for suggested modes and the weekly summary (the contract's
/// Activity): one line a minute while the person is active (any input in the last 2 minutes), and one per focus card
/// answer, in ~/Library/Application Support/Petal/activity.jsonl. Never window titles, URLs or file names; kept 30
/// days; nothing leaves the Mac. Off with `activityLog`.
@MainActor
final class ActivityLog {
    nonisolated static let folder = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support/Petal")
    /// PETAL_ACTIVITY points somewhere else, for trying the suggestions on a made-up history.
    nonisolated static let file = ProcessInfo.processInfo.environment["PETAL_ACTIVITY"].map { URL(fileURLWithPath: $0) }
        ?? folder.appending(path: "activity.jsonl")
    /// The Mac's own bookkeeping: when a suggestion or the weekly summary was last shown.
    nonisolated static let stateFile = folder.appending(path: "state.json")

    /// Writing happens off the main thread, one line at a time, in order.
    private let queue = DispatchQueue(label: "tech.edgetr.petal.activity", qos: .utility)
    private var timer: Timer?
    private var startedAt = Date()
    private var lastAnalysis = Date.distantPast

    var app: PetalApp { PetalApp.shared }
    var config: Config { app.config }

    func start() {
        startedAt = Date()
        queue.async { Self.prune() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Seconds since the last keyboard, mouse or trackpad input anywhere.
    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func tick() {
        guard config.bool("activityLog"), Self.idleSeconds < 120 else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front.activationPolicy == .regular,
           let id = front.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            let desktop = app.docks.focusedDock?.desktop ?? Spaces.desktop(on: NSScreen.main ?? NSScreen.screens[0])
            let mode = config.mode(forDesktop: desktop ?? 1)?.id ?? config.defaultMode
            append(["t": Int(Date().timeIntervalSince1970), "app": id, "mode": mode, "ws": desktop ?? 0])
        }
        app.insights.tick(sinceLaunch: Date().timeIntervalSince(startedAt))
    }

    /// A focus card answer: "back", "switch" or "close".
    func recordCard(_ answer: String, app bundleID: String, mode: String) {
        guard config.bool("activityLog") else { return }
        append(["t": Int(Date().timeIntervalSince1970), "card": answer, "app": bundleID, "mode": mode])
    }

    /// Forgets everything recorded so far.
    func forget() {
        queue.async { try? FileManager.default.removeItem(at: Self.file) }
    }

    private func append(_ line: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        queue.async {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: Self.file) {
                handle.seekToEndOfFile()
                handle.write(data + Data("\n".utf8))
                try? handle.close()
            } else {
                try? (data + Data("\n".utf8)).write(to: Self.file, options: .atomic)
            }
        }
    }

    /// Drops what's older than 30 days, on start.
    nonisolated private static func prune() {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let cutoff = Date().timeIntervalSince1970 - 30 * 86400
        let lines = text.split(separator: "\n")
        let kept = lines.filter { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let t = (object["t"] as? NSNumber)?.doubleValue else { return false }
            return t >= cutoff
        }
        guard kept.count != lines.count else { return }
        try? (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: State

    nonisolated static func state() -> [String: Any] { MCP.read(stateFile) ?? [:] }

    nonisolated static func setState(_ key: String, _ value: Any) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? MCP.update(stateFile) { $0[key] = value }
    }
}

/// Reading the history: suggested modes and the summary. Plain functions over the files, so the dock, `Petal --mcp`
/// and the `petal` command all answer the same.
enum Insights {
    struct Entry: Sendable {
        let t: Double
        let app: String
        let mode: String
        let ws: Int
        let card: String?
    }

    /// Apps that are everywhere and say nothing about what someone is doing.
    static let ignored: Set<String> = ["com.apple.finder", "tech.edgetr.petal", "com.apple.systempreferences", "com.apple.loginwindow",
                                       "com.apple.ScreenSaver.Engine"]

    static func entries(since: Double) -> [Entry] {
        guard let text = try? String(contentsOf: ActivityLog.file, encoding: .utf8) else { return [] }
        var out: [Entry] = []
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let t = (object["t"] as? NSNumber)?.doubleValue, t >= since, let app = object["app"] as? String else { continue }
            out.append(Entry(t: t, app: app, mode: object["mode"] as? String ?? "", ws: (object["ws"] as? NSNumber)?.intValue ?? 0,
                             card: object["card"] as? String))
        }
        return out
    }

    static var modes: [[String: Any]] { MCP.read(MCP.modesFile)?["modes"] as? [[String: Any]] ?? [] }

    static var settings: [String: Any] { MCP.read(MCP.settingsFile) ?? [:] }

    static func setting(_ key: String) -> Bool { settings[key] as? Bool ?? MCP.schema[key]?.first as? Bool ?? true }

    /// Colors for new modes, in order.
    static let palette = ["#5fb8ff", "#ff9f5f", "#7ed38a", "#ffd25f", "#ff6fae", "#b18cff", "#5fe0d0", "#ff7a6b"]

    static let suggestionsFile = MCP.folder.appending(path: "suggestions.json")

    static var dismissed: Set<String> { Set(MCP.read(suggestionsFile)?["dismissed"] as? [String] ?? []) }

    static func dismiss(_ key: String) {
        try? MCP.update(suggestionsFile, fallback: ["dismissed": []]) { object in
            var list = object["dismissed"] as? [String] ?? []
            if !list.contains(key) { list.append(key) }
            object["dismissed"] = list
        }
    }

    // MARK: Names

    /// An app's name, from its bundle; if it isn't installed, the last part of its id ("dev.zed.Zed" → "Zed").
    static func name(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), let bundle = Bundle(url: url) else {
            let last = id.split(separator: ".").last.map(String.init) ?? id
            return last.prefix(1).uppercased() + last.dropFirst()
        }
        return plain(bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent)
    }

    /// Without invisible formatting marks (some apps put a left-to-right mark before their name).
    static func plain(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
            .trimmingCharacters(in: .whitespaces)
    }

    /// "Figma", "Figma and Linear", "Figma, Linear and Notion", "Figma, Linear and 2 more".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2, 3: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        default: return names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
        }
    }

    /// A name and symbol for a mode from what kind of apps they are (each app's App Store category), when they agree.
    static func guess(_ apps: [String]) -> (name: String, icon: String)? {
        let table: [String: (String, String)] = [
            "developer-tools": ("Building", "hammer"), "graphics-design": ("Design", "paintbrush"), "photography": ("Photos", "camera"),
            "video": ("Video", "film"), "music": ("Music", "music.note"), "social-networking": ("Social", "bubble.left.and.bubble.right"),
            "productivity": ("Work", "briefcase"), "business": ("Work", "briefcase"), "education": ("Study", "graduationcap"),
            "games": ("Games", "gamecontroller"), "finance": ("Money", "chart.line.uptrend.xyaxis"), "news": ("News", "newspaper"),
            "reference": ("Reading", "book"), "books": ("Reading", "book"), "entertainment": ("Fun", "sparkles"),
            "health-fitness": ("Health", "heart"), "lifestyle": ("Life", "leaf"), "travel": ("Travel", "airplane"),
        ]
        var votes: [String: Int] = [:]
        for id in apps {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
                  let category = Bundle(url: url)?.infoDictionary?["LSApplicationCategoryType"] as? String else { continue }
            let key = category.replacingOccurrences(of: "public.app-category.", with: "").replacingOccurrences(of: "action-games", with: "games")
            if let entry = table[key] { votes[entry.0, default: 0] += 1 }
        }
        guard let best = votes.max(by: { $0.value < $1.value }), best.value * 2 >= apps.count else { return nil }
        return table.values.first { $0.0 == best.key }.map { ($0.0, $0.1) }
    }

    // MARK: Suggestions

    struct Suggestion: Sendable, Identifiable {
        enum Kind: String, Sendable { case mode, add }
        let kind: Kind
        let key: String
        let apps: [String]
        var mode: String = ""          // add: the mode to keep it in
        let minutes: Int
        let days: Int
        var id: String { key }

        var names: [String] { apps.map(Insights.name) }
        var guess: (name: String, icon: String)? { kind == .mode ? Insights.guess(apps) : nil }

        func text(modeName: String) -> String {
            switch kind {
            case .mode:
                let ask = guess.map { "Make \($0.name.first.map { "AEIOU".contains($0) } == true ? "an" : "a") \($0.name) mode?" } ?? "Make a mode for them?"
                return "You often use \(Insights.list(names)) together. \(ask)"
            case .add:
                return "You use \(names.first ?? "") in \(modeName) most days. Keep it there?"
            }
        }

        var json: [String: Any] {
            var object: [String: Any] = ["kind": kind.rawValue, "key": key, "apps": apps, "names": names, "minutes": minutes, "days": days]
            if kind == .add { object["mode"] = mode }
            if let guess { object["name"] = guess.name; object["icon"] = guess.icon }
            let modeName = Insights.modes.first { $0["id"] as? String == mode }?["name"] as? String ?? mode
            object["text"] = text(modeName: modeName)
            return object
        }
    }

    /// From the last 14 days: sets of 2–6 apps used together (in the same half hours) on 3 or more days for 3 hours or
    /// more, that no one mode holds; and apps used in a mode's Desktops on 3 or more days that aren't in that mode.
    static func suggestions(now: Date = Date()) -> [Suggestion] {
        let since = now.timeIntervalSince1970 - 14 * 86400
        let entries = entries(since: since).filter { $0.card == nil && !ignored.contains($0.app) }
        return suggestions(entries, modes: modes, dismissed: dismissed)
    }

    static func suggestions(_ entries: [Entry], modes: [[String: Any]], dismissed: Set<String>) -> [Suggestion] {
        let calendar = Calendar.current
        func day(_ t: Double) -> Int {
            let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
            return (parts.year ?? 0) * 10000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
        }
        let modeApps: [String: Set<String>] = Dictionary(modes.compactMap { m in
            (m["id"] as? String).map { ($0, Set((m["apps"] as? [String] ?? []) + (m["allow"] as? [String] ?? []))) }
        }, uniquingKeysWith: { a, _ in a })
        var out: [Suggestion] = []

        // New modes: apps used together in the same half hours.
        var windows: [Int: [String: Int]] = [:]
        var windowDay: [Int: Int] = [:]
        for entry in entries {
            let window = Int(entry.t / 1800)
            windows[window, default: [:]][entry.app, default: 0] += 1
            windowDay[window] = day(entry.t)
        }
        // In a half hour, an app counts as used with 2 minutes or more; the 8 most used.
        let used: [Int: [String: Int]] = windows.mapValues { apps in
            Dictionary(uniqueKeysWithValues: apps.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) })
        }
        func stats(_ set: Set<String>) -> (days: Int, minutes: Int) {
            var days = Set<Int>(), minutes = 0
            for (window, apps) in used where set.allSatisfy({ apps[$0] != nil }) {
                days.insert(windowDay[window] ?? 0)
                minutes += set.reduce(0) { $0 + (apps[$1] ?? 0) }
            }
            return (days.count, minutes)
        }
        func qualifies(_ s: (days: Int, minutes: Int)) -> Bool { s.days >= 3 && s.minutes >= 180 }
        var pairs: [String: (a: String, b: String, minutes: Int)] = [:]
        for apps in used.values {
            let names = apps.keys.sorted()
            for i in names.indices {
                for j in names.indices where j > i {
                    let key = names[i] + "+" + names[j]
                    pairs[key, default: (names[i], names[j], 0)].minutes += apps[names[i]]! + apps[names[j]]!
                }
            }
        }
        let strong = pairs.values.filter { qualifies(stats([$0.a, $0.b])) }.sorted { $0.minutes > $1.minutes }
        var taken = Set<String>()
        var newModes: [(Suggestion, Int)] = []
        for pair in strong where !taken.contains(pair.a) && !taken.contains(pair.b) {
            var set: Set<String> = [pair.a, pair.b]
            let partners = strong.filter { set.contains($0.a) || set.contains($0.b) }.flatMap { [$0.a, $0.b] }
            for candidate in partners where set.count < 6 && !set.contains(candidate) && !taken.contains(candidate) {
                if qualifies(stats(set.union([candidate]))) { set.insert(candidate) }
            }
            taken.formUnion(set)
            if modeApps.values.contains(where: { set.isSubset(of: $0) }) { continue }
            let apps = set.sorted()
            let key = apps.joined(separator: "+")
            guard !dismissed.contains(key) else { continue }
            let s = stats(set)
            // Apps no mode has yet count most.
            let fresh = set.filter { app in !modeApps.values.contains { $0.contains(app) } }.count
            let ordered = apps.sorted { a, b in
                let ma = used.values.reduce(0) { $0 + ($1[a] ?? 0) }, mb = used.values.reduce(0) { $0 + ($1[b] ?? 0) }
                return ma > mb
            }
            newModes.append((Suggestion(kind: .mode, key: key, apps: ordered, minutes: s.minutes, days: s.days), fresh))
        }
        out += newModes.sorted { ($0.1, $0.0.minutes) > ($1.1, $1.0.minutes) }.map(\.0)

        // Apps to add: used in a mode's Desktops on 3 days or more, and not in it.
        var adds: [String: (days: Set<Int>, minutes: Int)] = [:]
        for entry in entries {
            guard let apps = modeApps[entry.mode], !apps.contains(entry.app) else { continue }
            let key = "add:\(entry.app):\(entry.mode)"
            adds[key, default: ([], 0)].days.insert(day(entry.t))
            adds[key, default: ([], 0)].minutes += 1
        }
        out += adds.filter { $0.value.days.count >= 3 && !dismissed.contains($0.key) }
            .sorted { ($0.value.days.count, $0.value.minutes) > ($1.value.days.count, $1.value.minutes) }
            .map { key, value in
                let parts = key.split(separator: ":", maxSplits: 2).map(String.init)
                return Suggestion(kind: .add, key: key, apps: [parts[1]], mode: parts[2], minutes: value.minutes, days: value.days.count)
            }
        return out
    }

    // MARK: Summary

    struct Summary: Sendable {
        struct ModeTime: Sendable { let id: String; let name: String; let minutes: Int; let apps: [(id: String, minutes: Int)] }
        let title: String
        let from: Date
        let to: Date
        let modes: [ModeTime]
        let cardsShown: Int
        let wentBack: Int

        var total: Int { modes.reduce(0) { $0 + $1.minutes } }

        static func duration(_ minutes: Int) -> String {
            if minutes < 60 { return "\(minutes) min" }
            let hours = Double(minutes) / 60
            if hours >= 5 { return "\(Int(hours.rounded())) h" }
            let half = (hours * 2).rounded() / 2
            return half == half.rounded() ? "\(Int(half)) h" : String(format: "%.1f h", half)
        }

        /// "12 h in Building, most of it in Ghostty."
        static func line(_ mode: ModeTime) -> String {
            var text = "\(duration(mode.minutes)) in \(mode.name)"
            if let top = mode.apps.first {
                if Double(top.minutes) >= Double(mode.minutes) * 0.4 {
                    text += ", most of it in \(Insights.name(top.id))"
                } else {
                    text += ", with \(Insights.list(mode.apps.map { Insights.name($0.id) }))"
                }
            }
            return text + "."
        }

        var cardsLine: String? {
            guard cardsShown > 0 else { return nil }
            let times = { (n: Int) in n == 1 ? "once" : n == 2 ? "twice" : "\(n) times" }
            return "Focus cards came up \(times(cardsShown))" + (wentBack > 0 ? "; you went back to what you were doing \(times(wentBack))." : ".")
        }

        var lines: [String] { modes.map(Self.line) + (cardsLine.map { [$0] } ?? []) }

        var json: [String: Any] {
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withFullDate]
            format.timeZone = .current
            return ["period": title, "from": format.string(from: from), "to": format.string(from: to.addingTimeInterval(-1)),
                    "minutes": total,
                    "modes": modes.map { m in ["id": m.id, "name": m.name, "minutes": m.minutes,
                                               "apps": m.apps.map { ["id": $0.id, "name": Insights.name($0.id), "minutes": $0.minutes] }] },
                    "focusCards": ["shown": cardsShown, "back": wentBack], "text": lines]
        }
    }

    /// Monday 00:00 of the week `date` is in.
    static func weekStart(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? Calendar.current.startOfDay(for: date)
    }

    /// Last calendar week (the weekly card), or the last 7 days (on demand).
    static func summary(lastWeek: Bool, now: Date = Date()) -> Summary {
        let to = lastWeek ? weekStart(now) : now
        let from = lastWeek ? to.addingTimeInterval(-7 * 86400) : now.addingTimeInterval(-7 * 86400)
        return summary(from: from, to: to, title: lastWeek ? "Last week" : "The last 7 days")
    }

    /// Any stretch of time (the day's summary is today's).
    static func summary(from: Date, to: Date, title: String) -> Summary {
        let entries = entries(since: from.timeIntervalSince1970).filter { $0.t < to.timeIntervalSince1970 }
        let names = Dictionary(modes.compactMap { m in (m["id"] as? String).map { ($0, m["name"] as? String ?? $0) } }, uniquingKeysWith: { a, _ in a })
        var perMode: [String: [String: Int]] = [:]
        var shown = 0, back = 0
        for entry in entries {
            if let card = entry.card {
                shown += 1
                if card == "back" { back += 1 }
            } else if !entry.mode.isEmpty {
                perMode[entry.mode, default: [:]][entry.app, default: 0] += 1
            }
        }
        let modes = perMode.map { id, apps in
            Summary.ModeTime(id: id, name: names[id] ?? id.capitalized, minutes: apps.values.reduce(0, +),
                             apps: apps.filter { !ignored.contains($0.key) }.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value) })
        }.filter { $0.minutes >= 5 }.sorted { $0.minutes > $1.minutes }
        return Summary(title: title, from: from, to: to, modes: modes, cardsShown: shown, wentBack: back)
    }
}
