import AppKit
import Observation
import ServiceManagement
import SwiftUI

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
    @ObservationIgnored let tooltips = Tooltips()
    @ObservationIgnored let settings = SettingsWindow()
    @ObservationIgnored let welcome = Welcome()
    @ObservationIgnored let menuBar = MenuBar()
    @ObservationIgnored let releaseNotes = ReleaseNotes()
    /// The switches whose turning does something once (`followSwitches`), as they were last seen.
    @ObservationIgnored private var switches: [String: Bool] = [:]
    let hotkeys = Hotkeys()
    @ObservationIgnored private(set) var docks: DockController!
    /// Quick calls to the chosen AI's small model: routines' sorting and helpers in notes (Focus.swift).
    @ObservationIgnored let brain = Brain()
    @ObservationIgnored let ipc = IPC()

    var launching: [String: (start: Date, windows: Int)] = [:]
    /// Petal AI's powers on the Mac: looking, acting (asked first), the Trash, memory.
    let assist = Assist()
    /// "Ask Petal AI" by any selected text.
    @ObservationIgnored let selection = SelectionAsk()
    /// Routines in the person's own words: what Petal does by itself when a file lands, an app opens, at a time.
    let routines = Routines()
    /// Petal Notes: the person's own notes on paper, stuck to places (NoteDesk.swift).
    let paper = NoteDesk()
    /// The Petal Notes window: every note, its notebooks, their grid and canvas (NotesWindow.swift).
    @ObservationIgnored let notesWindow = NotesWindow()
    /// Petal's viewer: documents with their notes in a margin (Viewer.swift).
    let viewers = Viewers()
    /// A hidden display for each Petal AI run (RunDisplay.swift).
    let displays = RunDisplays()
    /// A browser of its own for each run that needs the web (RunBrowser.swift).
    @ObservationIgnored let runBrowsers = RunBrowsers()
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
        refreshSystemFacts()
        if !Headless.on {
            // Back from System Settings (or anywhere): what changed there shows in the windows still open.
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let app = PetalApp.shared
                    if app.settings.isOpen || app.welcome.isOpen { app.refreshSystemFacts() }
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
    var overlayOpen: Bool { claude.isOpen || popups.asking }

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
            self.displays.settingsChanged()   // hidden displays turned off: every one goes; the limit raised: the next waiting gets one
            self.followSwitches()   // other agents connected or taken back; the usage read at once
        }
        switches = ["otherAgents": config.bool("otherAgents"), "claudeUsage": config.bool("claudeUsage"), "autoUpdate": config.bool("autoUpdate")]
        // The notes for the AI, while the settings show them: a change made elsewhere comes in.
        config.everySecond = { [weak self] in self?.instructions.tick() }
        registerIPC()
        ipc.start()
        usage.start { [weak self] in self?.config.bool("claudeUsage") ?? false }
        signals.start(watchFolders: Stacks.resolve(config.strings("stackFolders")))
        updater.start()
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
        assist.start()
        claude.startNotes()
        selection.start()
        routines.start()
        if config.bool("otherAgents") { Skill.install() }
        Windows.startManaging()
        runBrowsers.sweep()   // browsers a Petal that crashed left for its runs are ended, their profiles removed
        let welcomed = config.welcomed
        if !welcomed {
            welcome.show()
        } else {
            useDock(config.whichDock)
        }
        // After an update, What's New opens by itself once, a moment after the dock is up (never on a first install).
        let running = version
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.releaseNotes.afterLaunch(running: running, welcomed: welcomed)
        }
        ModesLeftovers.settle()
    }

    /// What turning a switch does at once, rather than at the next start: other AI agents get Petal's tools, skill and
    /// command, or lose them (`OtherAgents`); the usage ring reads the usage instead of waiting for its next look; and
    /// updates turned on look for one now.
    private func followSwitches() {
        for (key, was) in switches {
            let now = config.bool(key)
            guard now != was else { continue }
            switches[key] = now
            switch key {
            case "otherAgents": now ? OtherAgents.connect(paths: paths) : OtherAgents.disconnect(paths: paths)
            case "claudeUsage": if now { Task { await usage.refreshAll() } }
            case "autoUpdate": if now { updater.check(manual: false) }
            default: break
            }
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
        ipc.stop()
        displays.quit()   // every hidden display goes, its windows put on the person's screen first
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
            popups.closeAsk()
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
    /// The person's notes for the AI (~/.config/petal/instructions.md), as the settings window edits them.
    @ObservationIgnored let instructions = InstructionsText()

    /// Reads what the settings and welcome windows show of macOS and of files off the main thread, so those
    /// windows never wait on them while they draw: the login item (an XPC call to macOS's service manager), macOS's
    /// Dock (its preferences), Codex's default model and the notes for the AI.
    /// Called at launch and as each of them opens. Reads go one after another, and only the newest one asked for is
    /// used: one begun before another (or before the login item was changed here) never overwrites it. `wait` reads
    /// it all before returning (snapshots).
    func refreshSystemFacts(wait: Bool = false) {
        factsAsked += 1
        let asked = factsAsked
        let read = { () -> (login: Bool, dock: [String]) in
            (SMAppService.mainApp.status == .enabled, SystemDock.readApps())
        }
        let apply = { (facts: (login: Bool, dock: [String])) in
            guard asked == self.factsAsked else { return }
            if facts.login != self.loginItem { self.loginItem = facts.login }
            if facts.dock != self.systemDockApps { self.systemDockApps = facts.dock }
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

    // MARK: Launching

    /// An app is launching until it has more windows than when it was asked to open, or for 10 seconds.
    func updateLaunching(_ snapshot: WindowList) {
        for (id, entry) in launching where (snapshot.count[id] ?? 0) > entry.windows || Date().timeIntervalSince(entry.start) > 10 {
            launching[id] = nil
        }
    }

    // MARK: Claude

    /// The AI button's tooltip: Petal AI, then whose usage the ring shows (the engine's own name: it's its plan).
    var usageTooltip: String {
        let used = !usage.limits.isEmpty || usage.spentText != nil
        return "Petal AI" + (used ? (chatProvider.map { " · " + $0.name } ?? "") : "") + usage.limits.map { " · \($0.label.replacingOccurrences(of: " (7-day)", with: "")) \(Int(((1 - $0.percent) * 100).rounded()))% left" }.joined()
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

    /// For `Petal --helpers-check` only (a headless run looks for no AI app by itself): where `provider` is, as the
    /// check says: its stand-in script, or with --ai the CLI it found.
    func standIn(_ provider: Provider, at path: String?) {
        guard Headless.on else { return }
        paths[provider] = path
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
        Self.quit()
    }

    /// Quits Petal, from the run loop and never from inside a block of the main dispatch queue. Quitting answers
    /// later (`applicationShouldTerminate`: notes are saved first), and AppKit waits for that answer inside
    /// `terminate`. Called from a main-queue block (a signal's handler, an `asyncAfter`), that wait would sit inside
    /// the block, the main queue could run nothing else, the notes' drain and the answer would never arrive, and
    /// Petal would never quit.
    static func quit() {
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }

    // MARK: IPC

    /// What `petal` and the AI's tools can ask the running Petal, over its socket (IPC.swift).
    private func registerIPC() {
        // Petal's tools changing settings or the dock (`Petal --mcp`): done here, in order. Only those (MCP.answer):
        // the rest of Petal AI's tools come in through `assist`, where who's asking is weighed.
        ipc.on("mcpCall") { args in MCP.answer(args.first ?? "", args.dropFirst().first ?? "{}") }
        // Petal AI's tools (`Petal --mcp` asks here): ["assist", tool, json]; one that changes something waits for the
        // person to allow it.
        ipc.onFrom("assist") { [unowned self] args, who, request, reply in
            // Which chat asks: one of Petal's own only by Petal's record of the AI process it started for that chat
            // (`who.note`, AgentCallers.started); any other caller is the process that connected. Never what the
            // caller says, so nobody stands in for a note or another session.
            let caller = who.note ?? "mcp-\(who.pid)"
            // Its card keeps it waiting however long the person takes; its asker gone, what it had going stops.
            // (Waiting its turn for a hidden display, or for an app another run or the person is using, keeps it
            // waiting the same way.)
            request.waiting = { [unowned self] in
                assist.pending?.owner == caller || displays.waits(caller) || displays.waitsForApp(caller) != nil
            }
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

        ipc.on("desktop") { [unowned self] _ in (docks.focusedDock?.desktop).map(String.init) ?? "" }
        ipc.on("ask") { [unowned self] _ in claude.open(asking: nil); return "ok" }
        // Words from another program are typed into the chat for the person to send (Return), never sent as theirs.
        ipc.on("chat") { [unowned self] args in claude.open(asking: args.joined(separator: " "), send: false); return "ok" }
        ipc.on("options") { [unowned self] _ in claude.openOptions(); return "ok" }
        ipc.on("newChat") { [unowned self] _ in claude.agent.reset(); return "ok" }
        ipc.on("search") { [unowned self] _ in search.open(in: nil); return "ok" }
        ipc.on("settings") { [unowned self] args in
            // `petal settings privacy` opens that page; a name it doesn't know opens Settings as it was.
            if let page = args.first.flatMap(SettingsSection.init(named:)) { settings.show(page) } else { settings.show() }
            return "ok"
        }
        ipc.on("reveal") { [unowned self] _ in docks.revealAll(); return "ok" }
        ipc.on("stack") { [unowned self] args in
            let folders = Stacks.resolve(config.strings("stackFolders"))
            guard let index = args.first.flatMap(Int.init), folders.indices.contains(index), let dock = docks.focusedDock else { return "no such stack" }
            dock.panel?.reveal()
            popups.toggleStack(folders[index], in: dock)
            return "ok"
        }
        ipc.on("testBounce") { [unowned self] args in
            guard let id = args.first else { return "which app?" }
            signals.bounce(id)
            return "ok"
        }
        ipc.on("close") { [unowned self] _ in
            claude.close(); search.close(); popups.closeAll(); popups.closeAsk()
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

    let services = TextServices()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = PetalApp()
        app.start()
        // "Ask Petal AI" and "Add to Petal AI" on selected text, in every app's right-click menu (Services).
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        // Being killed (logout, `killall Petal`) gives macOS its Dock back too, not only quitting.
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { PetalApp.quit() }
            source.resume()
            signals.append(source)
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
