import AppKit

/// Modes that change by themselves: the schedule (`schedule`: when a block starts, the Desktop in front goes into its
/// mode once, no countdown), and each mode's Shortcut (`shortcut`: run when the Desktop in front enters the mode,
/// say to turn on a macOS Focus).
@MainActor
final class ModeAutomation {
    private var timer: Timer?
    private var lastCheck = Date()
    private var shownMode: String?
    private var pendingShortcut: DispatchWorkItem?

    var app: PetalApp { PetalApp.shared }
    var config: Config { app.config }

    func start() {
        lastCheck = Date()   // a block already under way when Petal starts is left alone
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSchedule() }
        }
    }

    // MARK: Schedule

    struct Block: Identifiable, Equatable {
        var id = UUID()
        var mode: String
        var days: [Int]          // 1 = Monday … 7 = Sunday
        var from: String         // "HH:MM"
        var to: String

        init(id: UUID = UUID(), mode: String, days: [Int], from: String, to: String) {
            self.id = id; self.mode = mode; self.days = days; self.from = from; self.to = to
        }

        init?(_ object: [String: Any]) {
            guard let mode = object["mode"] as? String, let from = object["from"] as? String, let to = object["to"] as? String,
                  Block.minutes(from) != nil, Block.minutes(to) != nil else { return nil }
            self.init(mode: mode, days: (object["days"] as? [NSNumber] ?? []).map(\.intValue).filter { (1...7).contains($0) }, from: from, to: to)
        }

        var json: [String: Any] { ["mode": mode, "days": days.sorted(), "from": from, "to": to] }

        static func minutes(_ text: String) -> Int? {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
            return parts[0] * 60 + parts[1]
        }

        /// 1 = Monday, as the contract counts.
        static func day(_ date: Date) -> Int { (Calendar.current.component(.weekday, from: date) + 5) % 7 + 1 }

        /// Today's start and end, if it runs today ("to" before "from" ends the next day).
        func times(on date: Date) -> (start: Date, end: Date)? {
            guard days.contains(Block.day(date)), let from = Block.minutes(from), let to = Block.minutes(to) else { return nil }
            let midnight = Calendar.current.startOfDay(for: date)
            let start = midnight.addingTimeInterval(Double(from) * 60)
            var end = midnight.addingTimeInterval(Double(to) * 60)
            if end <= start { end = end.addingTimeInterval(86400) }
            return (start, end)
        }
    }

    var blocks: [Block] { (config.value("schedule") as? [[String: Any]] ?? []).compactMap(Block.init) }

    func save(_ blocks: [Block]) { config.set("schedule", blocks.map(\.json)) }

    /// A block that started since the last look (and hasn't ended) puts the Desktop in front in its mode.
    private func checkSchedule() {
        let now = Date()
        defer { lastCheck = now }
        guard app.docks.shown, config.bool("modes") else { return }
        for block in blocks where config.modes.contains(where: { $0.id == block.mode }) {
            // Yesterday's too, for a block that starts late and the Mac slept through midnight.
            for day in [now, now.addingTimeInterval(-86400)] {
                guard let times = block.times(on: day), times.start > lastCheck, times.start <= now, now < times.end else { continue }
                guard let desktop = app.docks.focusedDock?.desktop ?? Spaces.desktop(on: NSScreen.main ?? NSScreen.screens[0]) else { continue }
                app.setModeNow(block.mode, desktop: desktop)
            }
        }
    }

    // MARK: Shortcuts

    /// The Desktop in front shows `id` now: its Shortcut runs once the mode has held for a second (switching through
    /// Desktops quickly runs nothing). Not at launch.
    func modeShown(_ id: String?) {
        guard id != shownMode else { return }
        let first = shownMode == nil
        shownMode = id
        pendingShortcut?.cancel()
        guard !first, let id else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shownMode == id else { return }
            if let name = self.config.modes.first(where: { $0.id == id })?.shortcut, !name.isEmpty { Shortcuts.run(name) }
            self.app.routines.modeEntered(id)
        }
        pendingShortcut = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

/// The Shortcuts app's shortcuts, through its own command.
enum Shortcuts {
    /// Runs one, off the main thread. `done` (on the main thread) hears whether it finished within `timeout`
    /// seconds; one still running then is stopped.
    static func run(_ name: String, timeout: Double = 300, done: (@MainActor (Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            var finished = false
            if (try? process.run()) != nil {
                finished = exited.wait(timeout: .now() + timeout) == .success
                if !finished { process.terminate() }
            }
            let ok = finished && process.terminationStatus == 0
            if let done { DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } } }
        }
    }

    /// Every shortcut's name.
    static func list() async -> [String] {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }.value
    }
}
