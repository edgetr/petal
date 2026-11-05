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
    let insights = InsightsController()
    @ObservationIgnored let activity = ActivityLog()
    @ObservationIgnored let tooltips = Tooltips()
    @ObservationIgnored let settings = SettingsWindow()
    @ObservationIgnored let welcome = Welcome()
    @ObservationIgnored let recipes = RecipeWindow()
    @ObservationIgnored let automation = ModeAutomation()
    @ObservationIgnored let menuBar = MenuBar()
    @ObservationIgnored let overview = Overview()
    @ObservationIgnored let releaseNotes = ReleaseNotes()
    let hotkeys = Hotkeys()
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
        Task {
            for provider in Provider.allCases { await lookFor(provider) }
            loadCodexModels()
            // The person's other AI sessions get Petal's tools, skill and command too.
            if config.bool("otherAgents") { OtherAgents.connect(paths: paths) }
        }
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
            hotkeys.refresh()
            menuBar.refresh()
        }
        registerIPC()
        ipc.start()
        usage.start { [weak self] in self?.config.bool("claudeUsage") ?? false }
        signals.start(watchFolders: Stacks.resolve(config.strings("stackFolders")))
        updater.start()
        activity.start()
        automation.start()
        menuBar.start()
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
            hotkeys.refresh()
        } else {
            docks.show(false)
            hotkeys.refresh()
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

    /// Puts a Desktop in a mode at once, with no countdown (the schedule).
    func setModeNow(_ id: String, desktop: Int) { apply(id, desktop: desktop) }

    private func apply(_ id: String, desktop: Int) {
        stay()
        config.setMode(id, forDesktop: desktop)
        if let card = popups.card, card.target?.id == id { popups.dismissCard() }
    }

    // MARK: Describe your day

    /// The person says what they do; the chat builds their modes from it with Petal's tools.
    func describeDay(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !text.isEmpty, chatProvider != nil else { return }
        claude.open(asking: "Here's what I do on this computer: \(text). Build my focus modes from the apps I have installed (petal_list_apps): a few clear modes with fitting icons, colors and abouts, replacing the starter modes I haven't changed. Then tell me in two lines what you made.")
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

    /// Codex's own model list (`codex debug models`): listed models in its order, each with its efforts.
    struct CodexModel: Sendable { let id: String; let name: String; let efforts: [String] }
    private(set) var codexModels: [CodexModel] = []

    func loadCodexModels() {
        guard let codex = paths[.codex] else { return }
        let environment = childEnvironment
        Task {
            let result = await AISetup.run(codex, ["debug", "models"], environment: environment, timeout: 30)
            let json = result.output.firstIndex(of: "{").map { String(result.output[$0...]) } ?? ""
            guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
            codexModels = (root["models"] as? [[String: Any]] ?? [])
                .filter { $0["visibility"] as? String == "list" }
                .sorted { ($0["priority"] as? Int ?? 0) < ($1["priority"] as? Int ?? 0) }
                .compactMap { m in
                    guard let id = m["slug"] as? String else { return nil }
                    return CodexModel(id: id, name: m["display_name"] as? String ?? id,
                                      efforts: (m["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String })
                }
        }
    }

    /// The models to offer for an AI: Claude's aliases, or Default plus Codex's own list.
    func models(for provider: Provider) -> [(String, String)] {
        provider == .codex ? [("", "Default")] + latestCodex() : provider.models
    }

    /// The newest Codex model of each family (Sol, Astra, Terra, Luna), in Codex's order, named "6.1 Sol"; the model
    /// already chosen stays even when it's older.
    private func latestCodex() -> [(String, String)] {
        func parts(_ m: CodexModel) -> (family: String, version: [Int], label: String) {
            let pattern = try? NSRegularExpression(pattern: "^GPT-([\\d.]+)[- ](.+)$", options: .caseInsensitive)
            let name = m.name as NSString
            guard let match = pattern?.firstMatch(in: m.name, range: NSRange(location: 0, length: name.length)) else { return (m.id, [], m.name) }
            let version = name.substring(with: match.range(at: 1)), family = name.substring(with: match.range(at: 2))
            return (family.lowercased(), version.split(separator: ".").map { Int($0) ?? 0 }, "\(version) \(family)")
        }
        var best: [String: CodexModel] = [:]
        var order: [String] = []
        for model in codexModels {
            let p = parts(model)
            if let current = best[p.family] {
                if p.version.lexicographicallyPrecedes(parts(current).version) || p.version == parts(current).version { continue }
                best[p.family] = model
            } else {
                order.append(p.family)
                best[p.family] = model
            }
        }
        var out = order.compactMap { best[$0] }.map { ($0.id, parts($0).label) }
        let chosen = config.string("codexModel")
        if !chosen.isEmpty, !out.contains(where: { $0.0 == chosen }), let mine = codexModels.first(where: { $0.id == chosen }) {
            out.append((mine.id, parts(mine).label))
        }
        return out
    }

    /// The efforts the chosen model takes.
    func efforts(for provider: Provider) -> [String] {
        guard provider == .codex, let model = codexModels.first(where: { $0.id == config.string("codexModel") }), !model.efforts.isEmpty
        else { return provider.efforts }
        return model.efforts
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
            switch args.first {
            case "suggest": insights.showSuggestion(marking: false)
            case "summary": insights.showSummary()
            default:
                popups.show(FocusCard(kind: .guardCard, bundleID: "net.imput.helium", title: "x.com",
                                      target: config.mode(id: "social"), here: docks.focusedDock?.mode,
                                      reason: "Social feed, not work", desktop: docks.focusedDock?.desktop))
            }
            return "ok"
        }
        ipc.on("overview") { [unowned self] _ in overview.show(); return "ok" }
        ipc.on("summary") { [unowned self] _ in insights.showSummary(); return "ok" }
        ipc.on("recipe") { [unowned self] args in
            guard let path = args.first, FileManager.default.fileExists(atPath: path) else { return "no such file" }
            recipes.show(URL(fileURLWithPath: path))
            return "ok"
        }
        ipc.on("testBounce") { [unowned self] args in
            guard let id = args.first else { return "which app?" }
            signals.bounce(id)
            return "ok"
        }
        ipc.on("emptyTrash") { _ in Stacks.emptyTrash(); return "ok" }
        ipc.on("close") { [unowned self] _ in
            claude.close(); search.close(); popups.closeAll(); popups.dismissCard(); overview.close()
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
    private var opened: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = PetalApp()
        app.start()
        for url in opened { app.recipes.show(url) }
        opened = []
        // Being killed (logout, `killall Petal`) gives macOS its Dock back too, not only quitting.
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signals.append(source)
        }
    }

    /// Double-clicking a .petal file someone shared: what it adds, first.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "petal" {
            if PetalApp.started { PetalApp.shared.recipes.show(url) } else { opened.append(url) }
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
