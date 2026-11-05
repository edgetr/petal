import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// A mode switch waiting out the mode's focusDelay (the countdown setting).
struct PendingMode: Equatable {
    let desktop: Int
    let mode: String
    var deadline: Date
    var total: Double
}

/// Petal for macOS: everything the dock, its popups, Claude and the settings window share.
@MainActor @Observable
final class PetalApp {
    private static var instance: PetalApp?
    static var shared: PetalApp { instance! }
    static var started: Bool { instance != nil }

    let config = Config()
    let usage = Usage()
    let signals = Signals()
    let popups = Popups()
    let previews = Previews()
    let claude = ClaudePanel()
    let search = AppSearch()
    let updater = Updater()
    let aiSetup = AISetup()
    @ObservationIgnored let tooltips = Tooltips()
    @ObservationIgnored let settings = SettingsWindow()
    @ObservationIgnored let welcome = Welcome()
    @ObservationIgnored private(set) var docks: DockController!
    @ObservationIgnored private(set) var focus: FocusGuard!
    @ObservationIgnored let ipc = IPC()

    var launching: [String: (start: Date, windows: Int)] = [:]
    var pendingMode: PendingMode?
    @ObservationIgnored private var countdown: Timer?
    /// Where each AI app is installed, when it is.
    private(set) var paths: [Provider: String] = [:]

    /// The AIs the person chose (none is fine: Petal is a whole dock without them).
    var providers: [Provider] { config.strings("aiProviders").compactMap(Provider.init(rawValue:)) }

    /// The one the chat, the usage ring and sorting use.
    var chatProvider: Provider? {
        Provider(rawValue: config.string("chatProvider")).flatMap { providers.contains($0) ? $0 : nil } ?? providers.first
    }

    init() {
        PetalApp.instance = self
        docks = DockController()
        focus = FocusGuard()
        Task { for provider in Provider.allCases { await lookFor(provider) } }
    }

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    var accent: NSColor { NSColor(hex: config.string("accentColor")) ?? NSColor(hex: "#d9367f")! }

    /// A Claude panel, menu or search is open: an auto-hiding dock stays out.
    var overlayOpen: Bool { claude.isOpen || popups.card != nil }

    func start() {
        Windows.limitWaiting()
        config.onChange = { [weak self] in
            guard let self else { return }
            docks.refresh()
            signals.watch(Stacks.resolve(config.strings("stackFolders")))
        }
        registerIPC()
        ipc.start()
        usage.start { [weak self] in self?.config.bool("claudeUsage") ?? false }
        signals.start(watchFolders: Stacks.resolve(config.strings("stackFolders")))
        updater.start()
        aiSetup.refreshAll()
        Skill.install()
        if !config.welcomed {
            welcome.show()
        } else {
            useDock(config.whichDock)
        }
    }

    func stop() {
        ipc.stop()
        claude.agent.stop()
        SystemDock.restore()
    }

    // MARK: Which dock

    /// Petal or macOS's own: choosing one turns the other off.
    func useDock(_ which: String) {
        config.setDock("dock", which)
        if which == "petal" {
            // PETAL_KEEP_DOCK=1 leaves macOS's Dock alone, for working on Petal next to it.
            DockGuard.install()
            if ProcessInfo.processInfo.environment["PETAL_KEEP_DOCK"] != "1" && !SystemDock.replace() {
                let alert = NSAlert()
                alert.messageText = "Petal couldn't save your Dock's settings"
                alert.informativeText = "So it left macOS's Dock as it is. Check that ~/.config/petal can be written to."
                NSApp.activate()
                alert.runModal()
            }
            docks.show(true)
        } else {
            docks.show(false)
            popups.closeAll()
            popups.dismissCard()
            SystemDock.restore()
        }
    }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            config.setDock("openAtLogin", newValue)
        }
    }

    // MARK: Modes

    /// Puts a Desktop in a mode. With countdown on, leaving a guarded mode waits out its delay; asking again
    /// halves what's left.
    func requestMode(_ id: String, desktop: Int) {
        let current = config.mode(forDesktop: desktop)
        if current?.id == id { stay(); return }
        if var pending = pendingMode, pending.desktop == desktop, pending.mode == id {
            let left = pending.deadline.timeIntervalSinceNow / 2
            if left < 1.5 { apply(id, desktop: desktop); return }
            pending.deadline = Date().addingTimeInterval(left)
            pendingMode = pending
            return
        }
        if config.bool("countdown"), let delay = current?.focusDelay, delay > 0 {
            pendingMode = PendingMode(desktop: desktop, mode: id, deadline: Date().addingTimeInterval(delay), total: delay)
            countdown?.invalidate()
            countdown = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let pending = self.pendingMode else { return }
                    if pending.deadline <= Date() { self.apply(pending.mode, desktop: pending.desktop) }
                }
            }
        } else {
            apply(id, desktop: desktop)
        }
    }

    func stay() {
        pendingMode = nil
        countdown?.invalidate()
    }

    private func apply(_ id: String, desktop: Int) {
        stay()
        config.setMode(id, forDesktop: desktop)
        if let card = popups.card, card.target?.id == id { popups.dismissCard() }
    }

    // MARK: Launching

    /// An app is launching until it has more windows than when it was asked to open, or for 10 seconds.
    func updateLaunching(_ snapshot: WindowList) {
        for (id, entry) in launching where (snapshot.count[id] ?? 0) > entry.windows || Date().timeIntervalSince(entry.start) > 10 {
            launching[id] = nil
        }
    }

    // MARK: Claude

    var usageTooltip: String {
        (chatProvider?.name ?? "AI") + usage.limits.map { " · \($0.label.replacingOccurrences(of: " (7-day)", with: "")) \(Int(((1 - $0.percent) * 100).rounded()))% left" }.joined()
    }

    static func until(_ date: Date) -> String {
        let minutes = Int(max(0, date.timeIntervalSinceNow) / 60)
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 48 * 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / 1440)d"
    }

    /// Apps opened from Finder or at login get a bare PATH; Claude Code and its tools need the usual places.
    var childEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = (extra + (environment["PATH"]?.split(separator: ":").map(String.init) ?? [])).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }.joined(separator: ":")
        environment["PETAL_SOCKET"] = IPC.path
        environment["PETAL_APP"] = Bundle.main.bundlePath
        // A source checkout, for Claude to change Petal itself when a setting can't (rebuilt with macos/build.sh).
        if let source = ["\(home)/petal", "\(home)/Projects/Petal"].first(where: {
            FileManager.default.fileExists(atPath: $0 + "/macos/Package.swift")
        }) {
            environment["PETAL_SOURCE"] = source + "/macos"
        }
        return environment
    }

    /// The path setting, else the one the person's own terminal runs (an interactive login shell, so .zshrc
    /// counts), else the places its installer puts it.
    nonisolated static func find(_ provider: Provider, setting: String) -> String? {
        let isTool = { (path: String) in !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) }
        if isTool(setting) { return setting }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        shell.arguments = ["-lic", "command -v \(provider.binary)"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        if (try? shell.run()) != nil {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            shell.waitUntilExit()
            if let path = output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { $0.hasPrefix("/") }),
               isTool(path) {
                return path
            }
        }
        return provider.knownPaths(home: NSHomeDirectory()).first(where: isTool)
    }

    /// Asking the login shell can take a moment; the dock doesn't wait for it.
    func lookFor(_ provider: Provider) async {
        let setting = config.string(provider.pathSetting)
        paths[provider] = await Task.detached { PetalApp.find(provider, setting: setting) }.value
    }

    // MARK: Restarting

    /// Quits, and opens Petal again a moment later (the new version, after an update).
    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: IPC

    /// What `bin/petal` and Claude's tools can ask the running Petal (IpcHandler in Dock.qml).
    private func registerIPC() {
        ipc.on("current") { [unowned self] _ in docks.focusedDock?.mode?.id ?? config.defaultMode }
        ipc.on("mode") { [unowned self] args in
            guard let id = args.first, config.modes.contains(where: { $0.id == id }) else { return "no such mode" }
            guard let desktop = docks.focusedDock?.desktop ?? Spaces.desktop(on: NSScreen.main ?? NSScreen.screens[0]) else {
                return "this Space is a full-screen app"
            }
            requestMode(id, desktop: desktop)
            return "ok"
        }
        ipc.on("stay") { [unowned self] _ in stay(); return "ok" }
        ipc.on("desktop") { [unowned self] _ in (docks.focusedDock?.desktop).map(String.init) ?? "" }
        ipc.on("ask") { [unowned self] _ in claude.open(asking: nil); return "ok" }
        ipc.on("chat") { [unowned self] args in claude.open(asking: args.joined(separator: " ")); return "ok" }
        ipc.on("options") { [unowned self] _ in claude.openOptions(); return "ok" }
        ipc.on("allow") { [unowned self] _ in claude.agent.allow(); return "ok" }
        ipc.on("newChat") { [unowned self] _ in claude.agent.reset(); return "ok" }
        ipc.on("search") { [unowned self] _ in search.open(in: nil); return "ok" }
        ipc.on("settings") { [unowned self] _ in settings.show(); return "ok" }
        ipc.on("reveal") { [unowned self] _ in docks.revealAll(); return "ok" }
        ipc.on("check") { [unowned self] _ in focus.check(); return "ok" }
        ipc.on("stack") { [unowned self] args in
            let folders = Stacks.resolve(config.strings("stackFolders"))
            guard let index = args.first.flatMap(Int.init), folders.indices.contains(index), let dock = docks.focusedDock else { return "no such stack" }
            dock.panel?.reveal()
            popups.toggleStack(folders[index], in: dock)
            return "ok"
        }
        ipc.on("testCard") { [unowned self] args in
            if args.first == "update" {
                popups.show(FocusCard(kind: .update, version: version))
            } else {
                popups.show(FocusCard(kind: .guardCard, bundleID: "net.imput.helium", title: "x.com",
                                      target: config.mode(id: "social"), here: docks.focusedDock?.mode,
                                      reason: "Social feed, not work", desktop: docks.focusedDock?.desktop))
            }
            return "ok"
        }
        ipc.on("testBounce") { [unowned self] args in
            guard let id = args.first else { return "which app?" }
            signals.bounce(id)
            return "ok"
        }
        ipc.on("emptyTrash") { _ in Stacks.emptyTrash(); return "ok" }
        ipc.on("close") { [unowned self] _ in
            claude.close(); search.close(); popups.closeAll(); popups.dismissCard()
            return "ok"
        }
        ipc.on("dock") { [unowned self] args in
            guard let which = args.first, ["petal", "macos"].contains(which) else { return config.whichDock }
            useDock(which)
            return "ok"
        }
        ipc.on("restart") { [unowned self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.relaunch() }
            return "Petal is restarting"
        }
        ipc.on("version") { [unowned self] _ in version }
        ipc.on("update") { [unowned self] _ in
            updater.check(manual: true)
            return updater.status
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signals: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = PetalApp()
        app.start()
        // Being killed (logout, `killall Petal`) gives macOS its Dock back too, not only quitting.
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signals.append(source)
        }
    }

    /// Opening Petal while it runs (Finder, Spotlight) opens its settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PetalApp.shared.settings.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if PetalApp.started { PetalApp.shared.stop() }
    }
}
