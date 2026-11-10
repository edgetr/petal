import AppKit
import SwiftUI

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
        // What the dock's timer did once a second before events, and now does every 5 s (or once a second without
        // Accessibility): a look at the windows, off the main thread.
        time("a look (windows + running apps)") { _ = WindowList.current(); _ = DockController.runningApps() }
        time("minimized windows, every app (AX)", runs: 3) {
            for app in running { _ = Windows.windows(of: app.processIdentifier).filter(\.minimized) }
        }
        if Windows.trusted {
            // Watching every app's windows: the observers are added on their own thread; the main thread only asks.
            let start = DispatchTime.now().uptimeNanoseconds
            AXWatcher.shared.start()
            var counts = AXWatcher.shared.counts()   // waits for the observers to be added
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            print(String(format: "%-34@ %8.2f ms   (%d apps, %d windows, off the main thread)", "watching every app (AX observers)" as NSString,
                         ms, counts.apps, counts.windows))
            AXWatcher.shared.stop()
            counts = AXWatcher.shared.counts()
            print("stopped watching: \(counts.apps) apps, \(counts.windows) windows")
        }
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
        time("AXIsProcessTrusted") { _ = AXIsProcessTrusted() }
        time("Desktop of the main screen") { _ = Spaces.desktop(on: NSScreen.main ?? NSScreen.screens[0]) }
        time("app names, every running app") { for app in running { _ = Apps.name(app.bundleIdentifier ?? "") } }
        time("now playing (AppleScript)", runs: 3) { _ = NowPlaying.current() }
        time("config files read") {
            for file in [Config.folder.appending(path: "dock.json"), Config.folder.appending(path: "settings.json")] {
                _ = Config.parse(file)
            }
        }
        exit(0)
    }
}

/// `petal bench` (IPC "bench"): the same code a click runs, timed inside the running Petal: bringing the dock's apps
/// forward, the dock's update as one does (with the apps drawn by SwiftUI and by layers), typing in the "+" search,
/// and the dock's refresh. Each time includes drawing the result. It ends where it started (the same app in front)
/// and writes ~/Library/Logs/Petal/bench.json.
@MainActor
enum LiveBench {
    static let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Petal/bench.json")
    private(set) static var running = false

    /// `quiet`: only the steps that leave the apps alone (hovering icons, a setting back and forth).
    static func start(quiet: Bool = false) -> String {
        guard !running else { return "already running" }
        running = true
        Perf.spans = [:]
        Task { await run(quiet: quiet); running = false }
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

    private static func run(quiet: Bool) async {
        let app = PetalApp.shared
        var results: [String: Any] = [:]
        guard let dock = app.docks.focusedDock, let panel = dock.panel else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if !quiet {

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

        // 2. An app coming forward, as the dock sees it (its icon turns active), until the dock has drawn it: with
        // the apps drawn by SwiftUI, then by layers (DockStrip), each after a moment to settle.
        let strip = DockStrip.shared.layers
        for layers in [false, true] {
            DockStrip.shared.layers = layers
            app.docks.refresh(quick: true)
            draw(panel)
            try? await Task.sleep(for: .milliseconds(400))
            let name = layers ? "layers" : "SwiftUI"
            var quick: [Double] = []
            for _ in 0..<10 {
                let start = now()
                app.docks.refresh(quick: true)
                draw(panel)
                quick.append(ms(start))
            }
            results["dock update when an app comes forward (\(name))"] = summary(quick)
        }
        DockStrip.shared.layers = strip
        app.docks.refresh(quick: true)

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
        }

        // 5. Sweeping the pointer across the icons, as a quick move does: each icon's hover (its lift, tooltip and
        // preview swap) until drawn, 40 ms apart.
        if let strip = dock.strip {
            var hovering: [Double] = []
            for _ in 0..<2 {
                for id in strip.shownOrder.prefix(14) {
                    let start = now()
                    Perf.span("hover: state") { strip.benchHover(id) }
                    Perf.span("hover: draw") { draw(panel) }
                    hovering.append(ms(start))
                    try? await Task.sleep(for: .milliseconds(40))
                }
                strip.benchHover(nil)
                try? await Task.sleep(for: .milliseconds(300))
            }
            app.tooltips.hide()
            app.previews.close()
            results["hover an icon"] = summary(hovering)
        }

        // 6. A setting changing, as the settings window changes it: Claude and Codex for the chat, back and forth.
        if app.providers.count > 1, let chat = app.chatProvider {
            var setting: [Double] = []
            for _ in 0..<3 {
                for provider in app.providers + [chat] {
                    let start = now()
                    Perf.span("setting: state") { app.config.set("chatProvider", provider.rawValue) }
                    Perf.span("setting: draw") { draw(app.settings.window) }
                    setting.append(ms(start))
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            results["change a setting"] = summary(setting)
        }


        if !quiet, let front { _ = front.activate() ; Windows.bringForward(front) }
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

/// `Petal --bench-dock`: lays out and draws the dock off screen (a window that's never shown) with the person's own
/// apps, and times what the main thread does when the apps change, an app comes forward and a refresh changes
/// nothing. Nothing is shown, and no setting is changed.
@MainActor
enum DockBench {
    static func run() -> Never {
        let app = PetalApp()
        // The dock's own apps, or (an empty dock, as in a throwaway folder) the first installed ones; and a few
        // running apps that aren't among them, as the dock usually has.
        let installed = Apps.installed().map(\.id)
        var seen = Set<String>()
        let own = app.config.apps.filter { Apps.shows($0) && seen.insert($0).inserted }
        let apps = own.isEmpty ? Array(installed.prefix(12)) : own
        let loose = Array(installed.filter { !apps.contains($0) }.prefix(2))
        print("Petal dock bench: \(apps.count) apps, \(loose.count) more running")
        let was = DockStrip.shared.layers
        for layers in [false, true] {
            DockStrip.shared.layers = layers
            measure(app: app, apps: apps, loose: loose)
        }
        DockStrip.shared.layers = was
        SettingsBench.cleanUp()
        exit(0)
    }

    private static func measure(app: PetalApp, apps: [String], loose: [String]) {
        let dock = ScreenDock()
        dock.desktop = 1
        // As DockPanel: as wide as the screen, the dock centered in it.
        let width = NSScreen.main?.frame.width ?? 1512
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        let hosting = DockHostingView(rootView: AnyView(DockView(dock: dock).environment(app)))
        window.contentView = DockHostingView.container(hosting)
        var sizes: Set<String> = []

        /// As DockController.refresh does: the dock's apps (the first `count` of them), then the running ones.
        func show(_ count: Int, front: Int = 0) {
            let pinned = apps.prefix(count).enumerated().map { index, id in
                DockItem(id: id, pinned: true, running: index % 2 == 0, windows: index % 2 == 0 ? (index % 4 == 0 ? 2 : 1) : 0,
                         here: index % 4 == 0, active: index == front)
            }
            let now = pinned + loose.map { DockItem(id: $0, pinned: false, running: true, windows: 1, here: true, active: false) }
            if now != dock.items { dock.items = now }
            if dock.stageSlots != now.count + 1 { dock.stageSlots = now.count + 1 }
        }

        func draw() {
            let size = hosting.measure()
            sizes.insert("\(Int(size.width))×\(Int(size.height))")
            if window.frame.height != size.height { window.setContentSize(CGSize(width: width, height: size.height)) }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        func time(_ name: String, runs: Int, _ change: (Int) -> Void) {
            var samples: [Double] = []
            for run in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                change(run)
                draw()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                // Let animations started by the change run their course, as they would between clicks.
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            samples.sort()
            print(String(format: "  %-38@ median %7.2f ms   worst %7.2f ms   (%d runs)", name as NSString,
                         samples[samples.count / 2], samples.last ?? 0, runs))
        }

        print("strip: \(DockStrip.label)")
        show(apps.count)
        draw()
        // An app taken out of the dock and put back, as "+" and Remove from Dock do.
        time("an app added or removed", runs: 24) { run in show(apps.count - (run % 2 == 0 ? 1 : 0)) }
        // The layer strip must show the apps in the same pass that draws the change.
        if DockStrip.shared.layers {
            var late = 0
            for count in [apps.count - 1, apps.count] {
                show(count)
                draw()
                if dock.strip?.shownOrder != dock.items.map(\.id) { late += 1 }
            }
            print("  changes not shown in the same pass: \(late) of 2")
        }
        time("an app comes forward", runs: 20) { run in show(apps.count, front: run % 4) }
        time("refresh with nothing new", runs: 20) { _ in show(apps.count, front: 3) }
        // `--bench-dock <folder>`: the layer strip as a PNG (its layers as they rest, without the glass).
        if DockStrip.shared.layers, let index = CommandLine.arguments.firstIndex(of: "--bench-dock"),
           CommandLine.arguments.count > index + 1, let strip = dock.strip, let layer = strip.layer {
            let folder = CommandLine.arguments[index + 1]
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            show(apps.count, front: 0)
            draw()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let scale: CGFloat = 2
            let size = strip.bounds.size
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
               let context = NSGraphicsContext(bitmapImageRep: rep) {
                context.cgContext.setFillColor(NSColor(white: 0.2, alpha: 1).cgColor)
                context.cgContext.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
                context.cgContext.scaleBy(x: scale, y: scale)
                layer.render(in: context.cgContext)
                let path = (folder as NSString).appendingPathComponent("strip.png")
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("  " + path)
            }
        }
        print("  dock sizes seen: \(sizes.sorted().joined(separator: ", ")); window \(Int(window.frame.width))×\(Int(window.frame.height))")
        window.close()
    }
}
