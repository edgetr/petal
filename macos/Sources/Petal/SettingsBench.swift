import AppKit
import Combine
import Darwin
import SwiftUI

/// Set by `--bench-settings`, `--bench-windows`, `--bench-dock` and `--snapshot`: Petal runs nothing in the
/// background (no looking at what's in front, no AI apps started, no Keychain, no chats saved), so a benchmark only
/// measures and never touches the person's things.
enum Headless {
    nonisolated(unsafe) static var on = false
}

/// How many times key views' bodies ran, while a bench counts (a debug counter: nothing otherwise).
@MainActor
enum BodyCount {
    static var on = false
    static var counts: [String: Int] = [:]
    static func hit(_ name: String) { if on { counts[name, default: 0] += 1 } }
    static var total: Int { counts.values.reduce(0, +) }
}

/// The settings window's part of the bench, and the hook its clicks go through.
@MainActor
enum SettingsBench {
    enum Command { case select(SettingsSection), type(String), open(SettingsSection) }
    /// The bench's clicks: the same state changes the sidebar's buttons and the ask field make; and `open`, the
    /// window's own: a view made ahead opening on another page.
    static let commands = PassthroughSubject<Command, Never>()

    /// Before anything reads the settings: a copy of them in a temporary folder, unless `PETAL_CONFIG_DIR` already
    /// points somewhere. Only reads the real folder.
    static func isolate() {
        Headless.on = true
        if let dir = ProcessInfo.processInfo.environment["PETAL_CONFIG_DIR"], !dir.isEmpty { return }
        let real = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".config/petal")
        let copy = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "petal-bench-\(getpid())")
        try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        for name in ["modes.json", "settings.json", "dock.json", "instructions.md", "routines.json", "memory.json"] {
            try? FileManager.default.copyItem(at: real.appending(path: name), to: copy.appending(path: name))
        }
        setenv("PETAL_CONFIG_DIR", copy.path, 1)
        temporary = copy
    }
    private static var temporary: URL?

    /// A folder for headless runs' own files (chats, a stack), removed at the end.
    nonisolated static let scratch: URL = {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "petal-bench-files-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// Removes the copies `isolate` and the bench made.
    static func cleanUp() {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "petal-bench-files-\(getpid())"))
    }
}

/// `Petal --bench-settings` and `Petal --bench-windows` (`[--runs N] [--json file]`): every Petal window and panel
/// timed as the person uses it, headless. Each is made as Petal makes it (the settings window through
/// `SettingsWindow.prepare`, the others as their own window or panel hosts them) but never shown: it sits off every
/// screen, unordered, and each measurement lays it out and draws it (`layoutSubtreeIfNeeded`, `displayIfNeeded`, a
/// Core Animation commit), as `--bench-dock` does. Nothing runs in the background (`Headless`), the vault is made-up
/// items, the Keychain is never read, no socket is opened, chats and stacks are made-up files in a temporary folder,
/// and the settings are a copy in a temporary folder (`PETAL_CONFIG_DIR`), so a switch never changes the person's Petal.
///
/// - Cold: a fresh process per run (`--bench-windows-child`): each window opened first in its process.
/// - Warm, in one process: opening again, switching pages, typing, a switch, a slider, scrolling every scrollable
///   window top to bottom and back in 8 pt steps, and the CPU an open window uses while nobody touches it.
/// Each action is followed by think time on the run loop (300 ms; a person can't click faster), whose CPU is
/// reported too, so work moved out of the measured frame still counts.
@MainActor
enum WindowBench {
    // MARK: Measuring

    struct Sample: Codable {
        var ms: Double          // the action to its first laid-out, drawn frame (wall clock)
        var update: Double      // SwiftUI's update and layout (bodies run here)
        var draw: Double        // drawing and the Core Animation commit
        var cpu: Double         // main-thread CPU for the frame
        var bodies: Int         // key views' bodies run for the frame
        var settleCPU: Double   // process CPU in the think time after it (animations, work done later)
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(to - from) / 1_000_000 }

    /// CPU time of this thread (the main thread), in ms.
    static func threadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) * 1000
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1000
    }

    /// CPU time of the whole process, in ms.
    static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }

    /// The process's memory as macOS counts it (Activity Monitor's Memory), now and at its peak, in MB.
    static func footprint() -> (now: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    /// Lays the window out and draws it now, as the display cycle does for a window on screen.
    @discardableResult
    static func frame(_ window: NSWindow) -> (update: Double, draw: Double) {
        let start = now()
        window.contentView?.layoutSubtreeIfNeeded()
        let laid = now()
        window.displayIfNeeded()
        CATransaction.flush()
        return (ms(start, laid), ms(laid, now()))
    }

    /// The time from an action to its first frame, then think time.
    static func measure(_ window: () -> NSWindow?, think: Double = 0.3, _ action: () -> Void) -> Sample {
        BodyCount.counts = [:]
        let cpu = threadCPU()
        let start = now()
        action()
        guard let window = window() else { fatalError("no window") }
        let parts = frame(window)
        let end = now()
        var sample = Sample(ms: ms(start, end), update: parts.update, draw: parts.draw, cpu: threadCPU() - cpu,
                            bodies: BodyCount.total, settleCPU: 0)
        if verbose && !BodyCount.counts.isEmpty { FileHandle.standardError.write(Data("bodies: \(BodyCount.counts)\n".utf8)) }
        sample.settleCPU = settle(window, seconds: think)
        return sample
    }

    /// Runs the run loop for a while, drawing what changed as the display cycle would; the process CPU it took.
    @discardableResult
    static func settle(_ window: NSWindow, seconds: Double) -> Double {
        let cpu = processCPU()
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: min(end, Date().addingTimeInterval(1.0 / 60)))
            frame(window)
        }
        return processCPU() - cpu
    }

    // MARK: Scrolling

    struct ScrollStat: Codable {
        let steps: Int, height: Double
        let median: Double, p95: Double, p99: Double, max: Double
        let over8: Int, over16: Int        // steps over a 120 Hz frame (8.3 ms) and a 60 Hz frame (16.7 ms)
        let jitter: Double                 // standard deviation of the steps' times
        let jump: Double                   // mean change from one step to the next
        let bodies: Double                 // key views' bodies run per step (mean)
    }

    /// The window's main vertical scroll view: the biggest one that can scroll.
    static func scrollView(in window: NSWindow) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.frame.height > scroll.contentView.bounds.height + 1 { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return found.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Scrolls the window's scroll view top to bottom and back in `step` pt steps, a frame each, as a trackpad does.
    static func scroll(_ window: NSWindow, step: CGFloat = 8, passes: Int = 1) -> ScrollStat? {
        frame(window)
        guard let scroll = scrollView(in: window), let document = scroll.documentView else { return nil }
        let clip = scroll.contentView
        var times: [Double] = []
        var bodies = 0
        func go(_ y: CGFloat) {
            BodyCount.counts = [:]
            let start = now()
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
            frame(window)
            times.append(ms(start, now()))
            bodies += BodyCount.total
        }
        let range = max(0, document.frame.height - clip.bounds.height)
        let top: CGFloat = document.isFlipped ? 0 : range
        let sign: CGFloat = document.isFlipped ? 1 : -1
        let count = Int(range / step)
        guard count > 0 else { return nil }
        for _ in 0..<(count > 400 ? 1 : passes) {
            for i in 1...count { go(top + sign * CGFloat(i) * step) }
            for i in stride(from: count - 1, through: 0, by: -1) { go(top + sign * CGFloat(i) * step) }
        }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: top))
        scroll.reflectScrolledClipView(clip)
        frame(window)
        let sorted = times.sorted()
        let mean = times.reduce(0, +) / Double(times.count)
        let deviation = (times.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(times.count)).squareRoot()
        let jump = zip(times, times.dropFirst()).map { abs($0 - $1) }.reduce(0, +) / Double(max(1, times.count - 1))
        return ScrollStat(steps: times.count, height: Double(document.frame.height), median: pick(sorted, 0.5), p95: pick(sorted, 0.95),
                          p99: pick(sorted, 0.99), max: sorted.last ?? 0, over8: times.filter { $0 > 8.333 }.count,
                          over16: times.filter { $0 > 16.667 }.count, jitter: deviation, jump: jump,
                          bodies: Double(bodies) / Double(times.count))
    }

    /// Closes a window the bench made for a panel and lets its views go. Petal shows each panel in one window it
    /// keeps, while the bench makes a new one for each opening: a closed one must not stay alive, watching the
    /// same things, or every later change would draw it too.
    static func release(_ window: NSWindow?) {
        window?.close()
        window?.contentView = nil
    }

    /// Closes a window as clicking its close button does. A window never put on screen gets no notice from AppKit
    /// that it's closing, so the bench sends it as AppKit would.
    static func closeAsAPerson(_ window: NSWindow?) {
        guard let window else { return }
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        window.close()
    }

    // MARK: Pictures

    /// `--png <folder>`: what the bench drew, as the window's own views draw it, for comparing before and after.
    static let pictures: String? = {
        let arguments = CommandLine.arguments
        return arguments.firstIndex(of: "--png").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }()

    /// The window's layers as Core Animation has them (SwiftUI's drawing included; a glass window's own glass, the
    /// blur of what's behind it, is the window server's, so the picture is what sits in it), at 2x, over a dark grey.
    static func capture(_ window: NSWindow, _ name: String) {
        guard let pictures, let content = window.contentView else { return }
        frame(window)
        let view = (content as? NSGlassEffectView)?.contentView ?? content
        guard let layer = view.layer else { return }
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        context.cgContext.setFillColor(NSColor(white: 0.16, alpha: 1).cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        context.cgContext.scaleBy(x: scale, y: scale)
        if view.isFlipped {
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context.cgContext)
        try? FileManager.default.createDirectory(atPath: pictures, withIntermediateDirectories: true)
        let file = name.map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: pictures).appending(path: file + ".png"))
    }

    // MARK: Stats

    struct Stat: Codable {
        let runs: Int
        let median: Double, p95: Double, min: Double, max: Double
        let update: Double, draw: Double, cpu: Double, bodies: Double, settleCPU: Double
    }

    static func pick(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }

    static func stat(_ samples: [Sample]) -> Stat {
        func median(_ values: [Double]) -> Double { pick(values.sorted(), 0.5) }
        let times = samples.map(\.ms).sorted()
        return Stat(runs: samples.count, median: pick(times, 0.5), p95: pick(times, 0.95), min: times.first ?? 0, max: times.last ?? 0,
                    update: median(samples.map(\.update)), draw: median(samples.map(\.draw)), cpu: median(samples.map(\.cpu)),
                    bodies: median(samples.map { Double($0.bodies) }), settleCPU: median(samples.map(\.settleCPU)))
    }

    // MARK: The windows

    /// A window or panel as Petal hosts it, made for the bench and never shown.
    struct Target {
        let name: String
        /// A titled glass window this size (`setGlassContent`), or nil: a borderless panel that fits its content.
        var size: CGSize?
        let view: @MainActor () -> AnyView
        /// What the person does in it (each timed to its first frame).
        var actions: [(String, @MainActor () -> Void)] = []
        /// What to put back before opening it again.
        var reset: @MainActor () -> Void = {}
    }

    /// A target's window, made as its Petal window is.
    static func host(_ target: Target, app: PetalApp) -> NSWindow {
        let view = target.view().environment(app)
        if let size = target.size {
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.setGlassContent(view)
            return window
        }
        // As GlassPanel and InputPanel: a borderless, clear panel its content's size.
        let panel = NSPanel(contentRect: NSRect(x: -20000, y: -20000, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        let hosting = NSHostingView(rootView: AnyView(view))
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.fittingSize)
        return panel
    }

    // MARK: Results

    struct WindowResult {
        var rows: [(String, Stat)] = []
        var scrolls: [(String, ScrollStat)] = []
        var idle: [(String, Double, Double)] = []   // name, ms CPU a second, bodies a second
    }

    struct Cold: Codable {
        var opens: [String: Sample] = [:]
        var firstVisit: [String: Sample] = [:]
        var cpu = 0.0              // the process's CPU from before the first window to after the last
        var footprint = 0.0        // MB at the end
        var peak = 0.0             // MB at the peak
    }

    static let verbose = ProcessInfo.processInfo.environment["PETAL_BENCH_DEBUG"] != nil
    static func step(_ name: String) { FileHandle.standardError.write(Data("bench: \(name)\n".utf8)) }

    static func makeApp() -> PetalApp {
        precondition(Config.folder.path != URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".config/petal").path,
                     "the bench must use a copy of the settings")
        let vault = Snapshot.sampleVault()
        VaultStore.standIn(vault)
        let app = PetalApp()
        app.refreshSystemFacts(wait: true)   // as long after launch: read ahead
        let home = NSHomeDirectory()
        AgentGrants.shared.preview([
            AgentAccess.Grant(item: vault.first { $0.kind == .apiKey }?.id ?? "", title: "OpenAI", project: home + "/petal", agent: .codex),
        ])
        // As at launch: the installed apps and their icons, read off the main thread, and the "+" search made ahead.
        Apps.warm()
        let until = Date().addingTimeInterval(10)
        while Apps.cachedIcon("com.apple.finder") == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        app.search.prepare()
        app.settings.makeAhead()
        return app
    }

    // MARK: Idle: one window alone in a fresh process

    /// Starts `--bench-windows-idle <name>` and reads its answer: the window's CPU a second and bodies a second,
    /// open and untouched for 3 s, with nothing else open before it.
    static func idleChild(_ name: String) -> (cpu: Double, bodies: Double)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        process.arguments = ["--bench-windows-idle", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last { $0.hasPrefix("{") } ?? ""
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Double],
              let cpu = object["cpu"], let bodies = object["bodies"] else { return nil }
        return (cpu, bodies)
    }

    static func idle(_ name: String) -> Never {
        let app = makeApp()
        BodyCount.on = true
        var window: NSWindow?
        if name.hasPrefix("Settings: "), let section = SettingsSection(rawValue: String(name.dropFirst(10))) {
            window = app.settings.prepare(section)
        } else if let target = BenchTargets.all(app: app).first(where: { $0.name == name }) {
            window = host(target, app: app)
        }
        guard let window else { print("{}"); exit(0) }
        settle(window, seconds: 0.6)
        BodyCount.counts = [:]
        let cpu = settle(window, seconds: 3) / 3
        if verbose { FileHandle.standardError.write(Data("\(name): \(BodyCount.counts)\n".utf8)) }
        print("{\"cpu\": \(cpu), \"bodies\": \(Double(BodyCount.total) / 3)}")
        SettingsBench.cleanUp()
        exit(0)
    }

    // MARK: Cold: one fresh process per run

    /// `--bench-windows-child [settings]`: each window opened first in this process (settings, then its pages once,
    /// then every other window). One JSON line.
    static func child(settingsOnly: Bool) -> Never {
        let app = makeApp()
        let targets = settingsOnly ? [] : BenchTargets.all(app: app)
        BodyCount.on = true
        var cold = Cold()
        let cpu = processCPU()
        cold.opens["Settings"] = measure({ app.settings.window }) { _ = app.settings.prepare(.dock) }
        for section in SettingsSection.allCases where section != .dock {
            cold.firstVisit[section.rawValue] = measure({ app.settings.window }) { SettingsBench.commands.send(.select(section)) }
        }
        for target in targets {
            var window: NSWindow?
            cold.opens[target.name] = measure({ window }) { window = host(target, app: app) }
            release(window)
            target.reset()
        }
        let memory = footprint()
        cold.cpu = processCPU() - cpu
        cold.footprint = memory.now
        cold.peak = memory.peak
        if let data = try? JSONEncoder().encode(cold) { print(String(decoding: data, as: UTF8.self)) }
        SettingsBench.cleanUp()
        exit(0)
    }

    // MARK: The run

    static func run(_ arguments: [String], settingsOnly: Bool) -> Never {
        let runs = arguments.firstIndex(of: "--runs").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 20
        let jsonPath = arguments.firstIndex(of: "--json").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let only = arguments.firstIndex(of: "--only").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let processStart = processCPU()
        print("Petal \(settingsOnly ? "settings" : "windows") bench: \(runs) runs, settings copied to \(Config.folder.path)")

        // Cold, in fresh processes.
        step("cold runs")
        var colds: [Cold] = []
        for index in 0..<(only == nil ? runs : 0) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            process.arguments = ["--bench-windows-child"] + (settingsOnly ? ["settings"] : [])
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { print("couldn't start a run: \(error)"); exit(1) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last { $0.hasPrefix("{") } ?? ""
            if let cold = try? JSONDecoder().decode(Cold.self, from: Data(line.utf8)) { colds.append(cold) } else { print("cold run \(index) failed") }
        }

        let app = makeApp()
        BodyCount.on = true
        var results: [(String, WindowResult)] = []
        if only == nil || only == "Settings" { results.append(("Settings", settings(app: app, runs: runs, colds: colds))) }
        if !settingsOnly {
            for target in BenchTargets.all(app: app) where only == nil || only == target.name {
                step(target.name)
                results.append((target.name, window(target, app: app, runs: runs, colds: colds)))
            }
        }

        if !settingsOnly && (only == nil || only == "Page"), let stat = BenchTargets.page(runs: runs) {
            step("Page")
            results.append(("Page (WebKit)", WindowResult(rows: [("open to a loaded page", stat)])))
        }
        // Every window closed again, as the person leaves Petal: what it still uses in the background.
        step("background")
        for window in NSApp.windows where window.isVisible { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let backgroundStart = processCPU()
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let background = (processCPU() - backgroundStart) / 3

        // The tables.
        func pad(_ text: String, _ width: Int) -> String { text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0) }
        for (name, result) in results {
            print("\n## \(name)")
            print(pad("ms, action to its first drawn frame", 40) + "   median      p95   update     draw main CPU  bodies  settle CPU")
            for (row, s) in result.rows {
                print(pad(row, 40) + String(format: " %8.2f %8.2f %8.2f %8.2f %8.2f %7.0f %11.1f", s.median, s.p95, s.update, s.draw, s.cpu, s.bodies, s.settleCPU))
            }
            if !result.scrolls.isEmpty {
                print(pad("scrolling, ms a step", 40) + "    steps   median      p95      p99      max  >8.3ms >16.7ms  jitter  bodies")
                for (row, s) in result.scrolls {
                    print(pad(row, 40) + String(format: " %8d %8.2f %8.2f %8.2f %8.2f %7d %7d %7.2f %7.1f", s.steps, s.median, s.p95, s.p99, s.max,
                                                s.over8, s.over16, s.jitter, s.bodies))
                }
            }
            for (row, cpu, bodies) in result.idle {
                print(pad("idle, \(row)", 40) + String(format: " %8.2f ms CPU a second, %.0f bodies a second", cpu, bodies))
            }
        }
        let coldCPU = colds.map(\.cpu).sorted(), coldPeak = colds.map(\.peak).sorted()
        print("")
        print(String(format: "every window opened once (cold process): %.0f ms CPU, %.1f MB peak (medians)", pick(coldCPU, 0.5), pick(coldPeak, 0.5)))
        print(String(format: "in the background after closing them all: %.1f ms CPU a second", background))
        let memory = footprint()
        let total = processCPU() - processStart
        print(String(format: "this run: %.0f ms CPU, %.1f MB now, %.1f MB peak", total, memory.now, memory.peak))

        if let jsonPath {
            var windows: [String: Any] = [:]
            for (name, result) in results {
                var metrics: [String: Any] = [:]
                for (row, s) in result.rows {
                    metrics[row.trimmingCharacters(in: .whitespaces)] = ["runs": s.runs, "median": s.median, "p95": s.p95, "min": s.min, "max": s.max,
                                                                         "update": s.update, "draw": s.draw, "mainCPU": s.cpu, "bodies": s.bodies,
                                                                         "settleCPU": s.settleCPU]
                }
                var scrolls: [String: Any] = [:]
                for (row, s) in result.scrolls {
                    scrolls[row] = ["steps": s.steps, "height": s.height, "median": s.median, "p95": s.p95, "p99": s.p99, "max": s.max,
                                    "over8ms": s.over8, "over16ms": s.over16, "jitter": s.jitter, "jump": s.jump, "bodies": s.bodies]
                }
                var idle: [String: Any] = [:]
                for (row, cpu, bodies) in result.idle { idle[row] = ["cpuMsPerSecond": cpu, "bodiesPerSecond": bodies] }
                windows[name] = ["metrics": metrics, "scroll": scrolls, "idle": idle]
            }
            let report: [String: Any] = [
                "commit": Bundle.main.object(forInfoDictionaryKey: "PetalSourceCommit") as? String ?? "",
                "machine": machine(), "runs": runs, "unit": "ms", "windows": windows,
                "coldProcess": ["cpuMedian": pick(coldCPU, 0.5), "peakMBMedian": pick(coldPeak, 0.5),
                                "footprintMBMedian": pick(colds.map(\.footprint).sorted(), 0.5)],
                "warmProcess": ["cpu": total, "footprintMB": memory.now, "peakMB": memory.peak, "backgroundCPUPerSecond": background],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: jsonPath))
                print("wrote \(jsonPath)")
            }
        }
        SettingsBench.cleanUp()
        exit(0)
    }

    // MARK: Settings

    static func settings(app: PetalApp, runs: Int, colds: [Cold]) -> WindowResult {
        var result = WindowResult()
        let window = { app.settings.window }
        let send = { (command: SettingsBench.Command) in SettingsBench.commands.send(command) }
        step("settings: warm open")
        _ = measure(window) { _ = app.settings.prepare(.dock) }
        for section in SettingsSection.allCases.dropFirst() + [.dock] { _ = measure(window) { send(.select(section)) } }
        // Opened again a moment after it was closed (as a person does), on the Dock page as Settings… opens it,
        // and on Modes as "Edit in Settings…" does.
        var opens: [Sample] = [], others: [Sample] = []
        for _ in 0..<runs {
            closeAsAPerson(app.settings.window)
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            opens.append(measure(window) { _ = app.settings.prepare(.dock) })
        }
        for _ in 0..<runs {
            closeAsAPerson(app.settings.window)
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            others.append(measure(window) { _ = app.settings.prepare(.modes) })
        }
        result.rows.append(("open, cold (first in a process)", stat(colds.compactMap { $0.opens["Settings"] })))
        result.rows.append(("open, warm (again)", stat(opens)))
        result.rows.append(("open on Modes (again)", stat(others)))
        // What opening costs before it: a fresh view made while the window is closed (nobody waits for it).
        var ahead: [Sample] = []
        for _ in 0..<runs {
            closeAsAPerson(app.settings.window)
            ahead.append(measure(window) { app.settings.makeAhead() })
            _ = measure(window) { _ = app.settings.prepare(.dock) }
        }
        result.rows.append(("made ahead while closed (not waited on)", stat(ahead)))

        step("settings: switching pages")
        var visits: [SettingsSection: [Sample]] = [:]
        for _ in 0..<runs {
            for section in SettingsSection.allCases.dropFirst() + [.dock] {
                visits[section, default: []].append(measure(window) { send(.select(section)) })
            }
        }
        result.rows.append(("page, first visit (every page)", stat(colds.flatMap { $0.firstVisit.values })))
        result.rows.append(("page, switch back (every page)", stat(visits.values.flatMap { $0 })))
        for section in SettingsSection.allCases {
            let first = colds.compactMap { $0.firstVisit[section.rawValue] }
            if !first.isEmpty { result.rows.append(("  \(section.title), first visit", stat(first))) }
            result.rows.append(("  \(section.title), switch back", stat(visits[section] ?? [])))
        }

        // Typing in the ask field, on the Dock page: a keystroke at a time.
        step("settings: typing")
        _ = measure(window) { send(.select(.dock)) }
        let words = "Make my dock icons a bit bigger please"
        var typing: [Sample] = []
        for round in 0...max(1, runs / 10) {
            var keys: [Sample] = []
            for length in 1...words.count { keys.append(measure(window, think: 0.02) { send(.type(String(words.prefix(length)))) }) }
            if round > 0 { typing += keys }   // the first round warms the field
            _ = measure(window) { send(.type("")) }
        }
        result.rows.append(("typing in the ask field (a key)", stat(typing)))

        // A switch on Apps & Extras, and a slider on Look: what their bindings do.
        step("settings: a switch, a slider")
        _ = measure(window) { send(.select(.apps)) }
        let badges = app.config.bool("badges")
        var toggles: [Sample] = []
        for index in 0..<runs { toggles.append(measure(window) { app.config.set("badges", index % 2 == 0 ? !badges : badges) }) }
        app.config.set("badges", badges)
        result.rows.append(("a switch (Apps & Extras)", stat(toggles)))
        _ = measure(window) { send(.select(.look)) }
        let size = app.config.number("iconSize")
        var slides: [Sample] = []
        for index in 0..<runs { slides.append(measure(window, think: 0.05) { app.config.set("iconSize", Double(Int(size) + (index % 2 == 0 ? 1 : 0))) }) }
        app.config.set("iconSize", size)
        result.rows.append(("dragging a slider (Look), a step", stat(slides)))

        // Scrolling every page that scrolls, top to bottom and back.
        step("settings: scrolling")
        for section in SettingsSection.allCases {
            _ = measure(window, think: 0.6) { send(.select(section)) }
            if let w = window() { capture(w, "settings-\(section.rawValue)") }
            if let w = window(), let stat = scroll(w, passes: max(1, runs / 10)) {
                result.scrolls.append((section.title, stat))
            } else if verbose { print("settings \(section.title): nothing to scroll") }
        }
        // The vault with 300 logins: its page, and scrolling it.
        step("settings: a big vault")
        VaultStore.standIn(Snapshot.sampleVault() + BenchTargets.logins(300))
        VaultModel.shared.load()
        _ = measure(window) { send(.select(.dock)) }
        var bigVault: [Sample] = []
        for _ in 0..<runs {
            bigVault.append(measure(window) { send(.select(.vault)) })
            _ = measure(window) { send(.select(.dock)) }
        }
        result.rows.append(("  Vault with 300 logins, switch back", stat(bigVault)))
        _ = measure(window, think: 0.6) { send(.select(.vault)) }
        if let w = window() { capture(w, "settings-vault-300") }
        if let w = window(), let stat = scroll(w, passes: 1) { result.scrolls.append(("Vault with 300 logins", stat)) }
        VaultStore.standIn(Snapshot.sampleVault())
        VaultModel.shared.load()

        // Doing nothing, each page alone in a fresh process.
        step("settings: idle")
        for section in [SettingsSection.dock, .claude, .focus, .permissions] {
            if let idle = idleChild("Settings: \(section.rawValue)") { result.idle.append((section.title, idle.cpu, idle.bodies)) }
        }
        // The person closes it.
        _ = measure(window) { send(.select(.dock)) }
        closeAsAPerson(app.settings.window)
        return result
    }

    // MARK: Any other window

    static func window(_ target: Target, app: PetalApp, runs: Int, colds: [Cold]) -> WindowResult {
        var result = WindowResult()
        var current: NSWindow?
        let window = { current }
        // Warm it once, then open it again and again.
        _ = measure(window) { current = host(target, app: app) }
        release(current)
        target.reset()
        var opens: [Sample] = []
        for _ in 0..<runs {
            opens.append(measure(window) { current = host(target, app: app) })
            release(current)
            target.reset()
        }
        result.rows.append(("open, cold (first in a process)", stat(colds.compactMap { $0.opens[target.name] })))
        result.rows.append(("open, warm (again)", stat(opens)))
        current = host(target, app: app)
        settle(current!, seconds: 0.6)
        capture(current!, target.name)
        for (name, action) in target.actions {
            step("\(target.name): \(name)")
            var samples: [Sample] = []
            for _ in 0..<runs { samples.append(measure(window, think: 0.1) { action() }) }
            result.rows.append((name, stat(samples)))
        }
        step("\(target.name): scrolling")
        if let w = current, let stat = scroll(w, passes: max(1, runs / 10)) { result.scrolls.append((target.name, stat)) }
        else if verbose { print("\(target.name): nothing to scroll") }
        release(current)
        target.reset()
        if let idle = idleChild(target.name) { result.idle.append((target.name, idle.cpu, idle.bodies)) }
        return result
    }

    private static func machine() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        return "\(String(cString: brand)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}
