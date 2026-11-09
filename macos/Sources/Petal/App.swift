import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// A switch into a distracting mode, waiting out its wait (the countdown setting).
struct PendingMode: Equatable {
    let desktop: Int
    let mode: String
    var deadline: Date
    var total: Double

    /// Another click halves the time left; under 1.5 s it's nil: switch now.
    static func halved(_ left: Double) -> Double? {
        left / 2 < 1.5 ? nil : left / 2
    }
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
    /// API keys saved in the Keychain, and checking that one works (APIKeys.swift).
    let apiKeyCheck = APIKeyCheck()
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
    @ObservationIgnored private var arrival: (() -> Void)?
    /// Held notifications, Do Not Disturb while holding, and Petal's own banners (Notifications.swift).
    let notes = Notes()
    /// Petal AI's powers on the Mac: looking, acting (asked first), the Trash, memory, the day's summary.
    let assist = Assist()
    /// Replies drafted for held messages, in the person's own style.
    let drafts = Drafts()
    /// "Ask Petal AI" by any selected text.
    @ObservationIgnored let selection = SelectionAsk()
    /// Routines in the person's own words: what Petal does by itself when a file lands, an app opens, a mode starts.
    let routines = Routines()
    /// Petal Notes: the person's own notes on paper, stuck to places (NoteDesk.swift).
    let paper = NoteDesk()
    /// The Petal Notes window: every note, its notebooks, their grid and canvas (NotesWindow.swift).
    @ObservationIgnored let notesWindow = NotesWindow()
    /// Petal's viewer: documents with their notes in a margin (Viewer.swift).
    let viewers = Viewers()
    /// Reading and closing browser tabs (Browsers.swift).
    @ObservationIgnored let browsers = Browsers()
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
        connectWindowsToGuard()
        refreshSystemFacts()
        if !Headless.on {
            // Back from System Settings (or anywhere): what changed there shows in the windows still open.
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let app = PetalApp.shared
                    if app.settings.isOpen || app.welcome.isOpen || app.overview.isOpen { app.refreshSystemFacts() }
                }
            }
            Task {
                for provider in Provider.allCases { await lookFor(provider) }
                loadCodexModels()
                // The person's other AI sessions get Petal's tools, skill and command too.
                if config.bool("otherAgents") { OtherAgents.connect(paths: paths) }
            }
        }
    }

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    var accent: NSColor { NSColor(hex: config.string("accentColor")) ?? NSColor(hex: "#d9367f")! }

    /// A Claude panel, menu or search is open: an auto-hiding dock stays out.
    var overlayOpen: Bool { claude.isOpen || popups.card != nil }

    func start() {
        MCP.inPetal = true
        Windows.limitWaiting()
        config.onChange = { [weak self] in
            guard let self else { return }
            // The last look at the windows, at once; a fresh one off the main thread.
            Perf.span("onChange: docks.refresh") { self.docks.refresh(quick: true) }
            Perf.span("onChange: look") { self.docks.refreshInBackground() }
            Perf.span("onChange: signals.watch") { self.signals.watch(Stacks.resolve(self.config.strings("stackFolders"))) }
            Perf.span("onChange: hotkeys") { self.hotkeys.refresh() }
            Perf.span("onChange: menuBar") { self.menuBar.refresh() }
            self.claude.notesSettingChanged()   // sticky notes turned off: no listening, nudges or taking app clicks
            self.paper.settingsChanged()   // Petal Notes on or off, its look or its folder
            self.assist.computer.settingsChanged()   // using apps turned off, or an app made private: what's under way stops

        }
        // The notes for the AI, while the settings show them: a change made elsewhere comes in.
        config.everySecond = { [weak self] in self?.instructions.tick() }
        registerIPC()
        ipc.start()
        usage.start { [weak self] in self?.config.bool("claudeUsage") ?? false }
        signals.start(watchFolders: Stacks.resolve(config.strings("stackFolders")))
        updater.start()
        activity.start()
        automation.start()
        menuBar.start()
        paper.start()
        aiSetup.refreshAll()
        Apps.warm()
        // Codex's default model, as Codex's own settings change (read off the main thread).
        codexTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.config.string(Provider.codex.modelSetting).isEmpty else { return }
                self.refreshCodexDefault()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.search.prepare()
            self?.settings.makeAhead()   // the settings open at once
        }
        notes.start()
        assist.start()
        claude.startNotes()
        selection.start()
        routines.start()
        Skill.install()
        Windows.startManaging()
        if !config.welcomed {
            welcome.show()
        } else {
            useDock(config.whichDock)
        }
    }

    func stop() {
        paper.stop()   // what's typed in notes is written, and windows narrowed for a note get their width back
        config.flush()
        InstructionsText.flush()
        Chats.flush()
        Assist.flushHistory()
        AgentGrants.flush()
        Routines.flush()
        Windows.stopManaging()
        notes.stop()
        ipc.stop()
        claude.stopAll()
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
        get { loginItem }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            loginItem = newValue
            config.setDock("openAtLogin", newValue)
            refreshSystemFacts()   // what macOS made of it
        }
    }

    // MARK: What the windows show of macOS, read ahead

    /// Whether Petal opens at login, as macOS's login items say.
    private(set) var loginItem = false
    /// The apps in macOS's Dock (SystemDock.apps), for Import Dock and the sketches.
    private(set) var systemDockApps: [String] = []
    /// How many Desktops there are, across every display.
    private(set) var desktopCount = 0
    /// The person's notes for the AI (~/.config/petal/instructions.md), as the settings window edits them.
    @ObservationIgnored let instructions = InstructionsText()

    /// Reads what the settings, welcome and overview windows show of macOS and of files off the main thread, so those
    /// windows never wait on them while they draw: the login item (an XPC call to macOS's service manager), macOS's
    /// Dock (its preferences), the Desktops (the window server), Codex's default model and the notes for the AI.
    /// Called at launch and as each of them opens. Reads go one after another, and only the newest one asked for is
    /// used: one begun before another (or before the login item was changed here) never overwrites it. `wait` reads
    /// it all before returning (snapshots).
    func refreshSystemFacts(wait: Bool = false) {
        factsAsked += 1
        let asked = factsAsked
        let read = { () -> (login: Bool, dock: [String], desktops: Int) in
            (SMAppService.mainApp.status == .enabled, SystemDock.readApps(), Spaces.count())
        }
        let apply = { (facts: (login: Bool, dock: [String], desktops: Int)) in
            guard asked == self.factsAsked else { return }
            if facts.login != self.loginItem { self.loginItem = facts.login }
            if facts.dock != self.systemDockApps { self.systemDockApps = facts.dock }
            if facts.desktops != self.desktopCount { self.desktopCount = facts.desktops }
        }
        refreshCodexDefault(wait: wait)
        instructions.refresh(wait: wait)
        if wait { apply(Self.factsQueue.sync { read() }); return }
        Self.factsQueue.async {
            let facts = read()
            DispatchQueue.main.async { MainActor.assumeIsolated { apply(facts) } }
        }
    }

    /// Where `refreshSystemFacts` and `refreshCodexDefault` read, one at a time.
    nonisolated private static let factsQueue = DispatchQueue(label: "petal.facts", qos: .userInitiated)
    /// How many reads were asked for: only the newest one's answer is used.
    @ObservationIgnored private var factsAsked = 0
    @ObservationIgnored private var codexAsked = 0

    /// Reads Codex's default model (~/.codex/config.toml) off the main thread: as the windows open, and every 10 s
    /// while no Codex model is chosen, so a change to Codex's own default shows (with its efforts) as it did.
    func refreshCodexDefault(wait: Bool = false) {
        codexAsked += 1
        let asked = codexAsked
        let apply = { (model: String?) in
            guard asked == self.codexAsked, model != self.codexDefault else { return }
            self.codexDefault = model
        }
        if wait { apply(Self.factsQueue.sync { PetalApp.readCodexDefault() }); return }
        Self.factsQueue.async {
            let model = PetalApp.readCodexDefault()
            DispatchQueue.main.async { MainActor.assumeIsolated { apply(model) } }
        }
    }

    // MARK: Modes

    /// Puts a Desktop in a mode. Getting into a distracting mode (with countdown on) waits out its wait; each
    /// extra ask halves what's left, and under 1.5 s it switches now. `then` runs once the Desktop is in the mode
    /// (opening a held notification's app); Stay drops it.
    func requestMode(_ id: String, desktop: Int, then: (() -> Void)? = nil) {
        let current = config.mode(forDesktop: desktop)
        if current?.id == id { stay(); then?(); return }
        guard let target = config.modes.first(where: { $0.id == id }) else { return }
        if var pending = pendingMode, pending.desktop == desktop, pending.mode == id {
            if let then { arrival = then }
            guard let left = PendingMode.halved(pending.deadline.timeIntervalSinceNow) else { apply(id, desktop: desktop); return }
            pending.deadline = Date().addingTimeInterval(left)
            pendingMode = pending
            return
        }
        if config.bool("countdown") && target.isDistracting {
            stay()
            arrival = then
            pendingMode = PendingMode(desktop: desktop, mode: id, deadline: Date().addingTimeInterval(target.wait), total: target.wait)
            // No card about the mode while its countdown runs.
            if let card = popups.card, card.target?.id == id { popups.dismissCard() }
            countdown = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let pending = self.pendingMode else { return }
                    if pending.deadline <= Date() { self.apply(pending.mode, desktop: pending.desktop) }
                }
            }
        } else {
            arrival = then
            apply(id, desktop: desktop)
        }
    }

    func stay() {
        pendingMode = nil
        arrival = nil
        countdown?.invalidate()
    }

    /// Puts a Desktop in a mode at once, with no countdown (the schedule).
    func setModeNow(_ id: String, desktop: Int) { apply(id, desktop: desktop) }

    /// Per-mode windows and the focus guard: "Move to Design" takes the window (or, in a browser, just the tab) to
    /// Design before switching, and a parked window brought forward (⌘-Tab, its app showing it) asks for its own
    /// mode, so a distracting one still waits.
    private func connectWindowsToGuard() {
        focus.mover = { [unowned self] front, target, desktop in
            guard Parking.active, let window = Windows.focused(), window.pid == front.pid else {
                requestMode(target.id, desktop: desktop)
                return
            }
            let running = NSRunningApplication(processIdentifier: front.pid)
            if front.isBrowser, let running {
                browsers.frontURL(of: running) { [unowned self] url in
                    if let url { Parking.moveTab(url: url, from: window.element, to: target.id) }
                    else { Parking.moveWindow(window.element, to: target.id) }
                    requestMode(target.id, desktop: desktop)
                }
            } else {
                Parking.moveWindow(window.element, to: target.id)
                requestMode(target.id, desktop: desktop)
            }
        }
        Parking.parkedWindowFocused = { [unowned self] window, mode in requestMode(mode, desktop: window.desktop) }
    }

    private func apply(_ id: String, desktop: Int) {
        let then = arrival
        stay()
        Perf.span("apply: config.setMode") { self.config.setMode(id, forDesktop: desktop) }
        Perf.span("apply: parking") { Parking.modeChanged(desktop: desktop) }
        Perf.span("apply: tiling") { Tiling.modeChanged(desktop: desktop) }
        if let card = popups.card, card.target?.id == id, card.kind != .note { popups.dismissCard() }
        Perf.span("apply: docks.refresh") { self.docks.refresh(quick: true) }
        then?()
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
            + (usage.spentText.map { " · " + $0 } ?? "")
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

    /// The models to offer for an AI: Claude's aliases, or Codex's newest of each family.
    func models(for provider: Provider) -> [(String, String)] {
        provider == .codex ? latestCodex() : provider.models
    }

    /// The model an AI uses now: the one chosen, else (Codex) the one Codex uses by default: its own config's
    /// `model` (~/.codex/config.toml, top level), else the first model it lists.
    func currentModel(for provider: Provider) -> String {
        let chosen = config.string(provider.modelSetting)
        guard provider == .codex, chosen.isEmpty else { return chosen }
        // Read off the main thread (refreshCodexDefault), at launch, as the settings open and every 10 s: never while
        // they draw.
        return codexDefault ?? codexModels.first?.id ?? ""
    }
    /// The `model` at the top of ~/.codex/config.toml, if it has one.
    private var codexDefault: String?
    @ObservationIgnored private var codexTimer: Timer?

    nonisolated private static func readCodexDefault() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/config.toml")
        let top = ((try? String(contentsOf: path, encoding: .utf8)) ?? "").components(separatedBy: "\n[").first ?? ""
        for line in top.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "model" { return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return nil
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
        let chosen = currentModel(for: .codex)
        if !chosen.isEmpty, !out.contains(where: { $0.0 == chosen }), let mine = codexModels.first(where: { $0.id == chosen }) {
            out.append((mine.id, parts(mine).label))
        }
        return out
    }

    /// The efforts the chosen model takes.
    func efforts(for provider: Provider) -> [String] {
        guard provider == .codex, let model = codexModels.first(where: { $0.id == currentModel(for: .codex) }), !model.efforts.isEmpty
        else { return provider.efforts }
        return model.efforts
    }

    /// Asking the login shell can take a moment; the dock doesn't wait for it.
    func lookFor(_ provider: Provider) async {
        guard !Headless.on else { return }   // a benchmark starts no shell
        let setting = config.string(provider.pathSetting)
        paths[provider] = await Task.detached { PetalApp.find(provider, setting: setting) }.value
    }

    // MARK: Restarting

    /// Quits, and opens Petal again a moment later (the new version, after an update).
    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Quitting can take a while now (notes saved, windows given back: up to 10 s), so the helper waits for this
        // very process to be gone, by its pid, before opening Petal again; still there after a minute, it opens
        // nothing (a second Petal would only step aside for this one).
        process.arguments = ["-c", "i=0; while /bin/kill -0 \"$1\" 2>/dev/null && [ $i -lt 300 ]; do sleep 0.2; i=$((i+1)); done; "
                             + "/bin/kill -0 \"$1\" 2>/dev/null || /usr/bin/open \"$0\"", path, String(getpid())]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: IPC

    /// What `bin/petal` and Claude's tools can ask the running Petal (IpcHandler in Dock.qml).
    private func registerIPC() {
        ipc.on("current") { [unowned self] _ in docks.focusedDock?.mode?.id ?? config.defaultMode }
        // Petal AI's tools (`Petal --mcp` asks here): ["assist", tool, json]; one that changes something waits for the
        // person to allow it.
        // Petal's tools changing settings, modes or the dock (`Petal --mcp`, petal-mcp.py): done here, in order.
        ipc.onLater("mcpCall") { args, reply in
            let name = args.first ?? "", json = args.dropFirst().first ?? "{}"
            guard name == "petal_import_recipe" else { return reply(MCP.answer(name, json)) }
            // Reading the recipe and finding its apps (a scan of the Applications folders, Launch Services) happen
            // off the main thread; the modes it brings are made here, in order with every other change.
            DispatchQueue.global(qos: .userInitiated).async {
                let plan = Result { try MCP.importPlan(json) }
                DispatchQueue.main.async { MainActor.assumeIsolated { reply(MCP.answer(name, json, plan: plan)) } }
            }
        }
        ipc.onFrom("assist") { [unowned self] args, who, request, reply in
            // Which chat asks: a note's id only from Petal's own chats (Petal started them); any other caller is the
            // process that connected, whatever it says, so it never stands in for a note or another session.
            let claimed = args.dropFirst(2).first ?? ""
            let caller = who.agent == .petal && !claimed.isEmpty ? claimed : "mcp-\(who.pid)"
            // Its card keeps it waiting however long the person takes; its asker gone, what it had going stops.
            request.waiting = { [unowned self] in assist.pending?.owner == caller }
            request.onHangUp { [unowned self] in assist.hungUp(caller) }
            // Who it is goes with the request itself, never looked up again later.
            assist.handle(args.first ?? "", args.dropFirst().first ?? "{}", note: caller, who: who, request: request, reply: reply)
        }
        // `petal run` asking for API keys (AgentCallers.swift).
        ipc.onFrom("agentKeys") { [unowned self] args, who, request, reply in
            assist.agentKeys(args.first ?? "{}", from: who, request: request, reply: reply)
        }
        // The kept chats, open in the AI panel.
        ipc.on("chats") { [unowned self] _ in claude.open(asking: nil); claude.chatsOpen = true; return "ok" }
        ipc.on("bench") { args in LiveBench.start(quiet: args.first == "quiet") }

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
            case "move", "peek", "note":
                guard let card = FocusCard.sample(args[0], app: self) else { return "no such mode" }
                popups.show(card)
            default:
                guard let card = FocusCard.sample("block", app: self) else { return "no such mode" }
                popups.show(card)
            }
            return "ok"
        }
        ipc.on("testBanner") { [unowned self] _ in notes.banners.sample(); return "ok" }
        ipc.on("held") { [unowned self] _ in
            config.modes.map { "\($0.id) \(notes.held(in: $0.id).count)" }.joined(separator: "\n")
        }
        ipc.on("holding") { [unowned self] _ in notes.status.json }
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

    let services = TextServices()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = PetalApp()
        app.start()
        // "Ask Petal AI" and "Add to Petal AI" on selected text, in every app's right-click menu (Services).
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
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

    /// Notes first: what's typed is written and narrowed windows get their width back, off the main thread (up to
    /// 10 seconds), then Petal goes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard PetalApp.started else { return .terminateNow }
        PetalApp.shared.paper.prepareToQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if PetalApp.started { PetalApp.shared.stop() }
    }
}
