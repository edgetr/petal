import AppKit

/// `Petal --bench`: times the work behind the dock's slow moments (listing apps, a search keystroke, the window
/// list, reading windows through Accessibility, now playing) without showing or changing anything, so a change can
/// be measured before and after. Read-only.
@MainActor
enum Bench {
    static func run() -> Never {
        func time(_ name: String, runs: Int = 10, _ work: () -> Void) {
            var samples: [Double] = []
            for _ in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                work()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            samples.sort()
            let median = samples[samples.count / 2]
            print(String(format: "%-34@ median %8.2f ms   worst %8.2f ms   (%d runs)", name as NSString, median, samples.last ?? 0, runs))
        }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        print("Petal bench: \(running.count) apps running, Accessibility \(Windows.trusted ? "on" : "off")")

        time("installed apps (first scan)", runs: 1) { _ = Apps.installed() }
        time("installed apps (cached)") { _ = Apps.installed() }
        for query in ["", "s", "sa", "saf", "zzz"] {
            time("search \"\(query)\"") { _ = Apps.search(query) }
        }
        time("window list (CGWindowList)") { _ = WindowList.current() }
        time("windows of every app (AX)", runs: 3) {
            for app in running { _ = Windows.windows(of: app.processIdentifier) }
        }
        var slowest: (String, Double) = ("", 0)
        for app in running {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = Windows.windows(of: app.processIdentifier)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if ms > slowest.1 { slowest = (app.localizedName ?? app.bundleIdentifier ?? "?", ms) }
        }
        print(String(format: "%-34@ %8.2f ms", "slowest app to read (AX)" as NSString, slowest.1), slowest.0)
        time("front window title (AX)") { _ = Windows.frontTitle() }
        time("AXIsProcessTrusted") { _ = AXIsProcessTrusted() }
        time("Petal shortcut installed?", runs: 3) { _ = Quiet.shortcutIsInstalled() }
        time("Desktop of the main screen") { _ = Spaces.desktop(on: NSScreen.main ?? NSScreen.screens[0]) }
        time("app names, every running app") { for app in running { _ = Apps.name(app.bundleIdentifier ?? "") } }
        time("now playing (AppleScript)", runs: 3) { _ = NowPlaying.current() }
        time("config files read") {
            for file in [Config.folder.appending(path: "modes.json"), Config.folder.appending(path: "settings.json")] {
                _ = Config.parse(file)
            }
        }
        exit(0)
    }
}

/// `petal bench` (IPC "bench"): the same code a click runs, timed inside the running Petal: bringing the dock's apps
/// forward, switching between the modes that don't wait, typing in the "+" search, and the dock's refresh. Each
/// time includes drawing the result. It ends where it started (same mode, same app in front) and writes
/// ~/Library/Logs/Petal/bench.json.
@MainActor
enum LiveBench {
    static let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Petal/bench.json")
    private(set) static var running = false

    static func start() -> String {
        guard !running else { return "already running" }
        running = true
        Perf.spans = [:]
        Task { await run(); running = false }
        return "started"
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func ms(_ start: UInt64) -> Double { Double(now() - start) / 1_000_000 }

    /// Lays out and draws a window now, so its time counts.
    private static func draw(_ window: NSWindow?) {
        guard let window, let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    private static func waitFor(_ timeout: Double = 2, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return done()
    }

    private static func summary(_ samples: [Double]) -> [String: Double] {
        guard !samples.isEmpty else { return [:] }
        let sorted = samples.sorted()
        return ["median": (sorted[sorted.count / 2] * 10).rounded() / 10, "worst": ((sorted.last ?? 0) * 10).rounded() / 10,
                "runs": Double(sorted.count)]
    }

    private static func run() async {
        let app = PetalApp.shared
        var results: [String: Any] = [:]
        guard let dock = app.docks.focusedDock, let panel = dock.panel, let desktop = dock.desktop else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let startMode = dock.mode?.id

        // 1. Bringing a running app forward, as a click on its icon does: until it's the app in front.
        var activate: [Double] = []
        let targets = dock.items.filter { $0.running && $0.windows > 0 && $0.id != front?.bundleIdentifier }.prefix(4)
        for _ in 0..<2 {
            for item in targets {
                let start = now()
                app.docks.activate(item)
                if await waitFor(2, { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == item.id }) { activate.append(ms(start)) }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        results["bring app forward"] = summary(activate)

        // 2. Switching mode (modes without a wait), until the dock has drawn it.
        var switching: [Double] = []
        let modes = app.config.modes.filter { !$0.isDistracting }.map(\.id)
        for _ in 0..<3 {
            for id in modes {
                let start = now()
                Perf.span("switch: state") { app.requestMode(id, desktop: desktop) }
                Perf.span("switch: layout + draw") { draw(panel) }
                switching.append(ms(start))
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        if let startMode { app.setModeNow(startMode, desktop: desktop) }
        results["switch mode"] = summary(switching)

        // 3. The "+" search: opening it, then each keystroke until its results are drawn.
        var opening: [Double] = []
        var typing: [Double] = []
        for _ in 0..<3 {
            let start = now()
            Perf.span("search open: state") { app.search.open(in: dock) }
            Perf.span("search open: layout + draw") { draw(app.search.window) }
            opening.append(ms(start))
            for query in ["s", "sa", "saf", "safa", "safar", "", "t", "te", "ter"] {
                let start = now()
                Perf.span("search: state") { app.search.query = query }
                Perf.span("search: layout + draw") { draw(app.search.window) }
                typing.append(ms(start))
            }
            app.search.close()
            try? await Task.sleep(for: .milliseconds(120))
        }
        results["open + search"] = summary(opening)
        results["search keystroke"] = summary(typing)

        // 4. The dock's own refresh (once a second): what the main thread does with a look at the windows taken off
        // it, with drawing.
        var refresh: [Double] = []
        for _ in 0..<10 {
            let snapshot = WindowList.current()
            let start = now()
            Perf.span("refresh: total state") { app.docks.refresh(with: snapshot) }
            Perf.span("refresh: layout + draw") { draw(panel) }
            refresh.append(ms(start))
        }
        results["dock refresh (main thread)"] = summary(refresh)

        // 5. An app coming forward, as the dock sees it (its icon turns active).
        var quick: [Double] = []
        for _ in 0..<10 {
            let start = now()
            app.docks.refresh(quick: true)
            draw(panel)
            quick.append(ms(start))
        }
        results["dock update when an app comes forward"] = summary(quick)

        if let front { _ = front.activate() ; Windows.bringForward(front) }
        results["at"] = ISO8601DateFormatter().string(from: Date())
        results["steps"] = Perf.spans.mapValues(summary)
        Perf.spans = [:]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: file) }
    }
}

/// Timing a step inside the code while `petal bench` runs (free otherwise).
@MainActor
enum Perf {
    static var spans: [String: [Double]] = [:]

    @discardableResult
    static func span<T>(_ name: String, _ work: () -> T) -> T {
        guard LiveBench.running else { return work() }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = work()
        spans[name, default: []].append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        return result
    }
}
