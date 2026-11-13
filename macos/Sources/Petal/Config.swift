import AppKit
import Observation

/// Petal's files in ~/.config/petal:
/// - settings.json: the settings (`Settings` lists every one, with its default and what it does).
/// - dock.json: the dock itself. Its apps in the order they show (`apps`: bundle identifiers and https://
///   addresses), where the dock sits and whether it hides, and the person's other choices: which dock (Petal or
///   macOS's), opening at login, whether the first-run welcome was seen.
/// Each is read again within a second of changing on disk, whoever changed it (the settings window, Claude, an editor).
/// A modes.json from when Petal had focus modes is moved over once, at launch (ModesMigration).
@MainActor @Observable
final class Config {
    /// `PETAL_CONFIG_DIR` points Petal at another folder, for benchmarks and tests that must never touch the real one.
    nonisolated static let folder: URL = {
        if let dir = ProcessInfo.processInfo.environment["PETAL_CONFIG_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".config/petal")
    }()
    /// Petal's own state, ~/Library/Application Support/Petal. `PETAL_SUPPORT_DIR` points it at another folder, so a
    /// benchmark or snapshot never reads or writes the person's.
    nonisolated static let supportFolder: URL = {
        if let dir = ProcessInfo.processInfo.environment["PETAL_SUPPORT_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support/Petal")
    }()
    @ObservationIgnored let settingsFile = folder.appending(path: "settings.json")
    @ObservationIgnored let dockFile = folder.appending(path: "dock.json")
    @ObservationIgnored let instructionsFile = folder.appending(path: "instructions.md")

    /// settings.json as Petal has it. Reading it whole watches every setting; `bool`, `string` and the rest watch
    /// only their own, so a switch changing draws again only what shows that setting.
    private(set) var settings: [String: Any] {
        get {
            access(keyPath: \.settings)
            return values
        }
        set {
            let changed = Set(values.keys).union(newValue.keys).filter { !Self.same(values[$0], newValue[$0]) }
            values = newValue
            guard !changed.isEmpty else { return }
            withMutation(keyPath: \.settings) {}
            for key in changed { withMutation(keyPath: \.[setting: key]) {} }
        }
    }
    @ObservationIgnored private var values: [String: Any] = [:]

    /// What watching one setting is keyed by (Observation's key path); never read.
    nonisolated subscript(setting key: String) -> Int { 0 }

    private func watch(_ key: String) { access(keyPath: \.[setting: key]) }

    nonisolated private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): (a as AnyObject).isEqual(b as AnyObject)
        default: false
        }
    }
    private(set) var dock: [String: Any] = [:]

    @ObservationIgnored var onChange: (() -> Void)?
    /// Runs with the watcher, once a second: other files Petal follows look for changes then too.
    @ObservationIgnored var everySecond: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var stamps: [Date?] = []

    init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        // A dock from when the Mac had modes, moved over before anything is read.
        ModesMigration.run(config: Self.folder, support: Self.supportFolder)
        reload()
        watch()
    }

    // MARK: Settings

    func bool(_ key: String) -> Bool { watch(key); return values[key] as? Bool ?? Settings.defaults[key] as? Bool ?? false }
    func number(_ key: String) -> Double {
        watch(key)
        return (values[key] as? NSNumber)?.doubleValue ?? (Settings.defaults[key] as? NSNumber)?.doubleValue ?? 0
    }
    func string(_ key: String) -> String { watch(key); return values[key] as? String ?? Settings.defaults[key] as? String ?? "" }
    func strings(_ key: String) -> [String] { watch(key); return values[key] as? [String] ?? Settings.defaults[key] as? [String] ?? [] }
    func value(_ key: String) -> Any? { watch(key); return values[key] ?? Settings.defaults[key] }

    /// Changes one setting; everything else in settings.json stays as it was.
    func set(_ key: String, _ value: Any) {
        update(settingsFile) { $0[key] = value }
    }

    // MARK: The dock's place, and the Mac's own choices

    var position: String {
        let place = (dock["position"] as? String ?? "bottom").lowercased()
        return ["bottom", "left", "right"].contains(place) ? place : "bottom"   // the menu bar holds the top
    }
    var autoHide: Bool { dock["autoHide"] as? Bool ?? false }
    /// "petal" shows Petal and hides macOS's Dock; "macos" keeps macOS's Dock and turns Petal's off.
    var whichDock: String { dock["dock"] as? String ?? "petal" }
    var welcomed: Bool { dock["welcomed"] as? Bool ?? false }
    /// Windows end above the dock instead of running under it (while auto-hide is off).
    var keepWindowsClear: Bool { dock["keepWindowsClear"] as? Bool ?? true }

    func setDock(_ key: String, _ value: Any) {
        update(dockFile) { $0[key] = value }
    }

    // MARK: The dock's apps

    /// The dock's apps, in the order they show: bundle identifiers, and https:// addresses for website shortcuts.
    var apps: [String] {
        ConfigRules.apps(dock["apps"])
    }

    func setApps(_ apps: [String]) {
        setDock("apps", apps)
    }

    func addApp(_ app: String) {
        guard !apps.contains(app) else { return }
        setApps(apps + [app])
    }

    func removeApp(_ app: String) {
        setApps(apps.filter { $0 != app })
    }

    /// "Import macOS's Dock". Into an empty dock (the first run), macOS's Dock becomes Petal's: its apps in its order,
    /// and its folders as Petal's stacks. Into a dock that has apps, it only adds: macOS's Dock's apps and folders that
    /// Petal's doesn't have yet go after the ones it has, so nothing the person arranged is lost.
    func importSystemDock() {
        let imported = SystemDock.apps(), folders = SystemDock.folders()
        guard !apps.isEmpty else {
            setApps(imported)
            if !folders.isEmpty { set("stackFolders", folders) }
            return
        }
        let added = imported.filter { !apps.contains($0) }
        if !added.isEmpty { setApps(apps + added) }
        let stacks = strings("stackFolders")
        // By the folder each stack really shows (Screenshots may stand for the Desktop), so none comes twice.
        let have = Set(stacks.map { Stacks.url(Stacks.resolve([$0]).first ?? $0).standardizedFileURL.path })
        let newFolders = folders.filter { !have.contains(Stacks.url($0).standardizedFileURL.path) }
        if !newFolders.isEmpty { set("stackFolders", stacks + newFolders) }
    }

    // MARK: Files

    /// Both files as they are on disk now (on the writer's queue, after a write), with the stamps they had when
    /// read: a change landing after this is newer than those stamps, so the watcher still sees it.
    nonisolated private static func snapshot(_ files: [URL]) -> (contents: [NSDictionary], stamps: [Date?]) {
        let stamps = files.map { stamp($0) }
        return (files.map { readObject($0) as NSDictionary }, stamps)
    }

    nonisolated private static func stamp(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// One of Petal's writes is done. Once none is still on its way, memory must match both files: one that
    /// doesn't (someone else's change landed meanwhile, in that file or another) is loaded, and the files' stamps
    /// are taken as they are now, so the watcher never mistakes an unseen change for one already read.
    private func written(_ disk: (contents: [NSDictionary], stamps: [Date?]), valid: Bool, stale: Bool) {
        writing -= 1
        if !valid { NSSound.beep() }
        guard writing == 0 else { return }   // the last write's check covers this one's
        let mine = [settings as NSDictionary, dock as NSDictionary]
        if !valid || stale || !zip(disk.contents, mine).allSatisfy({ $0.isEqual($1) }) {
            reload()   // what's on disk stands
            onChange?()
            stamps = currentStamps()
        } else {
            stamps = disk.stamps   // what was read matches memory; anything written since is still news to the watcher
        }
    }

    private var files: [URL] { [settingsFile, dockFile] }

    /// Petal's writes, one after another, in order.
    nonisolated private static let writer = DispatchQueue(label: "petal.config.write", qos: .userInitiated)
    /// Writes not finished yet: the watcher waits for them, so Petal's own write isn't read back as someone's change.
    @ObservationIgnored private var writing = 0

    /// A change takes effect at once, in memory: the dock, the settings window and the menus show it in the same
    /// frame. The file is written a moment later, off the main thread, in order with every other write (reading,
    /// changing and writing a file took the main thread several milliseconds, and the settings window stuttered).
    private func update(_ file: URL, _ change: @escaping (inout [String: Any]) -> Void) {
        var root = file == settingsFile ? settings : dock
        change(&root)
        Perf.span("config: in memory") {
            if file == settingsFile { settings = root } else { dock = root }
        }
        // Someone else changed a file in the last second, before the watcher read it: read it once this is written.
        let stale = writing == 0 && currentStamps() != stamps
        let files = self.files
        writing += 1
        Self.writer.async {
            // A file that's there but isn't valid JSON (half-written by an editor, say) is left alone, not replaced
            // by the one key being changed.
            let valid = !FileManager.default.fileExists(atPath: file.path) || Self.parse(file) != nil
            if valid {
                var disk = Self.readObject(file)
                change(&disk)
                Self.writeObject(disk, to: file)
            }
            // What's on disk now: someone else's change may have landed with ours.
            let disk = Self.snapshot(files)
            DispatchQueue.main.async { MainActor.assumeIsolated { PetalApp.shared.config.written(disk, valid: valid, stale: stale) } }
        }
        Perf.span("config: onChange") { onChange?() }
    }

    /// Waits for every write still under way (on quit).
    func flush() { Self.writer.sync {} }

    /// settings.json or dock.json as Petal has it now (its own changes included, before they're written).
    func root(of file: URL) -> [String: Any] {
        file.path == settingsFile.path ? settings : file.path == dockFile.path ? dock : [:]
    }

    /// A change from Petal's tools (MCP.swift), in order with every other: tried on what Petal has first (so one
    /// that refuses changes nothing), then made as Petal's own changes are, in memory and then on disk.
    func change(_ file: URL, fallback: [String: Any], _ edit: @escaping (inout [String: Any]) throws -> Void) throws {
        var probe = root(of: file)
        if probe.isEmpty { probe = fallback }
        try edit(&probe)
        update(file) { root in
            if root.isEmpty { root = fallback }
            try? edit(&root)
        }
    }

    /// Both files as they are on disk. One that's there but doesn't read as JSON (an editor halfway through writing
    /// it, a typo) keeps what was read before until it does: the dock never loses its apps to a file being edited.
    /// Once Petal runs, what Petal AI may do grows only in Petal itself (`ConfigRules.taken`): a change in the file
    /// that would turn on Full access or using apps, allow more without asking or take an app off the private list
    /// isn't taken, and the file is written to say what Petal goes by again. One that narrows any of them is taken.
    private func reload() {
        let parsed = Self.parse(settingsFile), exists = FileManager.default.fileExists(atPath: settingsFile.path)
        var read = ConfigRules.reread(parsed, exists: exists, before: settings)
        var refused: [String] = []
        if loaded { (read, refused) = ConfigRules.taken(read, over: settings, defaults: Settings.defaults) }
        settings = read
        dock = ConfigRules.reread(Self.parse(dockFile), exists: FileManager.default.fileExists(atPath: dockFile.path), before: dock)
        // Only a read that said what the person chose counts as the first: one that couldn't read the file (a typo at
        // launch) leaves the next good read to be taken as it is.
        if parsed != nil || !exists { loaded = true }
        guard !refused.isEmpty else { return }
        // Once for the file as it is now: one that can't be written is left, and Petal goes by what it has.
        let stamp = Self.stamp(settingsFile) ?? .distantPast
        guard stamp != putBack else { return }
        putBack = stamp
        NSLog("Petal settings: %@ changed in settings.json would let Petal AI do more, so it wasn't taken; that changes only in Petal's settings.",
              refused.joined(separator: ", "))
        update(settingsFile) { root in
            for key in refused { root[key] = read[key] }
        }
    }

    /// The files were read once (at launch, as they are: the person's own choices from before). From then on
    /// `reload` keeps what Petal AI may do from growing through the file.
    @ObservationIgnored private var loaded = false
    /// settings.json's date when it was last written to say what Petal goes by.
    @ObservationIgnored private var putBack: Date?

    /// Looks for changes once a second. Modification times catch both ways a file gets written: replaced whole (as
    /// Petal and many editors do) and rewritten in place.
    private func watch() {
        stamps = currentStamps()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.everySecond?()
                guard self.writing == 0 else { return }
                let now = self.currentStamps()
                guard now != self.stamps else { return }
                self.stamps = now
                self.reload()
                self.onChange?()
            }
        }
    }

    private func currentStamps() -> [Date?] {
        files.map { Self.stamp($0) }
    }

    nonisolated static func readObject(_ url: URL) -> [String: Any] { parse(url) ?? [:] }

    nonisolated static func parse(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated static func writeObject(_ object: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}

extension NSColor {
    convenience init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), text.hasPrefix("#") else { return nil }
        text.removeFirst()
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
