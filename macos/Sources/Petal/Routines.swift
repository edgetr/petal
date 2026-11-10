import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Routines: what Petal does by itself, made from the person's own words ("keep my Downloads tidy", "when a PDF
/// lands in Downloads, file it under Receipts", "when I open Xcode, hide Messages"). Petal AI turns the words into
/// a trigger and actions once, when the routine is made (`petal_routine_save`), so running one costs nothing; only
/// sorting files by what they are asks the quick AI (Claude Haiku, Codex's Luna), and its answers are kept by the
/// file's name pattern, so similar files after the first cost nothing either.
///
/// Triggers: a file lands in a folder (settled first: its size has stopped changing, and partial downloads are left
/// to finish), an app opens or comes to the front, a time of day. Actions: sort files into subfolders (by what they
/// are, or by kind with no AI), move them to a folder, open or hide apps, run a Shortcut. Files are only ever moved,
/// never deleted, and every move is in the history, which puts them back.
///
/// The Mac had modes once, and a routine could start when a Desktop entered one, or switch to one. One saved then is
/// kept as it was written, listed with a line saying so, and never runs (`usesModes`).
///
/// `~/.config/petal/routines.json` holds the routines; `~/Library/Application Support/Petal/routines-log.json` what
/// they did and `routines-sorted.json` the folder each name pattern went to (`PETAL_ROUTINES` points all three at
/// another folder, for testing).
@MainActor @Observable
final class Routines {
    // MARK: What a routine is

    struct Trigger: Equatable {
        var on = ""              // "file", "app" or "time" ("mode" in a routine from when the Mac had modes)
        var folder = ""          // file: the folder watched (~/Downloads)
        var types: [String] = [] // file: kinds (pdf, image, video, audio, archive, installer, document, code) or extensions; empty: any
        var named: [String] = [] // file: words in its name; empty: any
        var app = ""             // app: its bundle id
        var when = "opens"       // app: "opens" (launches) or "front" (comes to the front)
        var mode = ""            // mode: the mode's id, kept only so such a routine is written back as it was
        var at = ""              // time: "HH:MM"
        var days: [Int] = []     // time: 1 = Monday … 7 = Sunday; empty: every day

        init() {}

        init(_ o: [String: Any]) {
            on = (o["on"] as? String ?? o["kind"] as? String ?? "").lowercased()
            folder = o["folder"] as? String ?? ""
            types = Routines.list(o["types"]).map { $0.lowercased() }
            named = Routines.list(o["named"])
            app = o["app"] as? String ?? ""
            when = (o["when"] as? String)?.lowercased() == "front" ? "front" : "opens"
            mode = o["mode"] as? String ?? ""
            at = o["at"] as? String ?? ""
            days = (o["days"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }.filter { (1...7).contains($0) }
        }

        var json: [String: Any] {
            switch on {
            case "file": ["on": on, "folder": folder, "types": types, "named": named]
            case "app": ["on": on, "app": app, "when": when]
            case "mode": ["on": on, "mode": mode]
            case "time": ["on": on, "at": at, "days": days.sorted()]
            default: ["on": on]
            }
        }
    }

    struct Action: Equatable {
        var kind = ""            // "sort", "move", "open", "hide" or "shortcut" ("mode" from when the Mac had modes)
        var folder = ""          // sort, move: the files' folder (the trigger's by default)
        var into = ""            // sort: where the subfolders go (the files' folder by default)
        var by = "ai"            // sort: "ai" (what each file is) or "kind" (Images, PDFs, …; no AI)
        var to = ""              // move: the folder they go into
        var mode = ""            // mode: kept only so such a routine is written back as it was
        var apps: [String] = []  // open, hide: bundle ids (open also takes addresses and files)
        var name = ""            // shortcut: its name in the Shortcuts app

        init(_ o: [String: Any]) {
            kind = (o["do"] as? String ?? o["kind"] as? String ?? "").lowercased()
            folder = o["folder"] as? String ?? ""
            into = o["into"] as? String ?? ""
            by = (o["by"] as? String)?.lowercased() == "kind" ? "kind" : "ai"
            to = o["to"] as? String ?? ""
            mode = o["mode"] as? String ?? ""
            apps = Routines.list(o["apps"] ?? o["app"])
            name = o["name"] as? String ?? o["shortcut"] as? String ?? ""
        }

        var json: [String: Any] {
            switch kind {
            case "sort": ["do": kind, "folder": folder, "into": into, "by": by]
            case "move": ["do": kind, "folder": folder, "to": to]
            case "mode": ["do": kind, "mode": mode]
            case "open", "hide": ["do": kind, "apps": apps]
            case "shortcut": ["do": kind, "name": name]
            default: ["do": kind]
            }
        }

        var movesFiles: Bool { kind == "sort" || kind == "move" }
    }

    struct Routine: Identifiable, Equatable {
        var id: String
        var name: String
        var words: String
        var on = true
        var trigger: Trigger
        var actions: [Action]
        var lastRun: Date?
        var lastResult = ""

        init(id: String, name: String, words: String, on: Bool, trigger: Trigger, actions: [Action]) {
            self.id = id; self.name = name; self.words = words; self.on = on; self.trigger = trigger; self.actions = actions
        }

        init?(_ o: [String: Any]) {
            guard let id = o["id"] as? String else { return nil }
            self.init(id: id, name: o["name"] as? String ?? "", words: o["words"] as? String ?? "", on: o["on"] as? Bool ?? true,
                      trigger: Trigger(o["trigger"] as? [String: Any] ?? [:]),
                      actions: (o["actions"] as? [[String: Any]] ?? []).map(Action.init))
            lastRun = (o["lastRun"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            lastResult = o["lastResult"] as? String ?? ""
        }

        var json: [String: Any] {
            var o: [String: Any] = ["id": id, "name": name, "words": words, "on": on, "trigger": trigger.json,
                                    "actions": actions.map(\.json), "lastResult": lastResult]
            if let lastRun { o["lastRun"] = lastRun.timeIntervalSince1970 }
            return o
        }

        /// The folder its file actions take files from.
        func source(_ action: Action) -> String { action.folder.isEmpty ? trigger.folder : action.folder }

        /// Made when the Mac had modes, to start with one or switch to one: it can't do what it says any more, so it
        /// doesn't run at all.
        var usesModes: Bool { trigger.on == "mode" || actions.contains { $0.kind == "mode" } }
        static let modesGone = "It used modes, which Petal for macOS no longer has, so it doesn't run."
    }

    struct Move: Equatable, Sendable {
        let from: String
        let to: String
    }

    /// One thing a routine did, in the history; its moves can be put back.
    struct Entry: Identifiable, Equatable {
        let id: String
        let routine: String
        let name: String
        let text: String
        let at: Date
        var moves: [Move]
        var made: [String]        // folders Petal made for them, taken away again when empty after putting back
        var undone = false

        var canUndo: Bool { !undone && !moves.isEmpty }

        init(id: String, routine: String, name: String, text: String, at: Date, moves: [Move], made: [String], undone: Bool = false) {
            self.id = id; self.routine = routine; self.name = name; self.text = text; self.at = at
            self.moves = moves; self.made = made; self.undone = undone
        }

        init?(_ o: [String: Any]) {
            guard let id = o["id"] as? String, let text = o["text"] as? String else { return nil }
            self.init(id: id, routine: o["routine"] as? String ?? "", name: o["name"] as? String ?? "", text: text,
                      at: Date(timeIntervalSince1970: (o["at"] as? NSNumber)?.doubleValue ?? 0),
                      moves: (o["moves"] as? [[String: String]] ?? []).compactMap { m in m["from"].flatMap { f in m["to"].map { Move(from: f, to: $0) } } },
                      made: o["made"] as? [String] ?? [], undone: o["undone"] as? Bool ?? false)
        }

        var json: [String: Any] {
            ["id": id, "routine": routine, "name": name, "text": text, "at": at.timeIntervalSince1970,
             "moves": moves.map { ["from": $0.from, "to": $0.to] }, "made": made, "undone": undone]
        }
    }

    /// What sorting a folder's files would do.
    struct Plan {
        struct Item {
            let file: URL
            let folder: URL
            let new: Bool
        }
        let routine: String
        let source: URL
        var items: [Item] = []
        var total = 0
        var later = 0            // past the most one run handles
        var leftAlone: [String] = []
        /// Sorted by what they are, with no AI to ask and no answer learned for names like theirs: left where they are.
        var waitingForAI: [String] = []
        let at = Date()
    }

    private(set) var list: [Routine] = []
    private(set) var log: [Entry] = []

    /// The check (`Petal --routines-check`) runs routines without the rest of Petal: no dock, no settings, no
    /// asking; `quickCall` stands in for the quick AI (nil: sorting by kind).
    @ObservationIgnored var standalone = false
    @ObservationIgnored var quickCall: ((String, String, @escaping ([String: Any]?) -> Void) -> Void)?

    @ObservationIgnored private var watches: [String: FolderWatch] = [:]
    /// `stop`: a run asked for by a chat or AI session (petal_routine_run) stops once its asker hangs up, even while queued.
    @ObservationIgnored private var jobs: [(id: String, file: URL?, stop: RoutineStop)] = []
    @ObservationIgnored private var working = false
    @ObservationIgnored private var learned: [String: [String: String]] = [:]
    /// Bumped when a routine's rule changes, and part of its quick-AI key, so an answer the quick AI gave for the
    /// old rule (kept for the session) isn't reused for the new one.
    @ObservationIgnored private var ruleVersion: [String: Int] = [:]
    @ObservationIgnored private var plans: [String: Plan] = [:]
    /// Each run under way, by routine: stopped when the routine changes, goes or is turned off, so its moves off the
    /// main thread stop too.
    @ObservationIgnored private var runs: [(id: String, stop: RoutineStop)] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var stamp: Date?
    nonisolated static let io = DispatchQueue(label: "petal.routines", qos: .utility)
    nonisolated static let mostFiles = 120

    // MARK: Files

    nonisolated static var stateFolder: URL {
        if let dir = ProcessInfo.processInfo.environment["PETAL_ROUTINES"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return Config.supportFolder
    }
    nonisolated static var file: URL {
        if ProcessInfo.processInfo.environment["PETAL_ROUTINES"]?.isEmpty == false { return stateFolder.appending(path: "routines.json") }
        return Config.folder.appending(path: "routines.json")
    }
    nonisolated static var logFile: URL { stateFolder.appending(path: "routines-log.json") }
    /// Each move as it happens, before the history has it: Petal quitting mid-batch never loses a way back.
    nonisolated static var journalFile: URL { stateFolder.appending(path: "routines-moving.json") }

    /// Drops from the journal only the moves the history on disk has; anything else (a run still going, a history
    /// that didn't save) stays for the next launch to recover. On `io`.
    nonisolated static func pruneJournal() {
        guard var list = Config.parse(journalFile)?["moves"] as? [[String: String]] else { return }
        // Moves in an entry that was put back don't count: the same move made again since is a new one.
        let saved = Set((Config.parse(logFile)?["entries"] as? [[String: Any]] ?? []).filter { $0["undone"] as? Bool != true }.flatMap { entry in
            (entry["moves"] as? [[String: String]] ?? []).map { ($0["from"] ?? "") + "→" + ($0["to"] ?? "") }
        })
        list.removeAll { saved.contains(($0["from"] ?? "") + "→" + ($0["to"] ?? "")) }
        if list.isEmpty { try? FileManager.default.removeItem(at: journalFile) } else { Config.writeObject(["moves": list], to: journalFile) }
    }

    nonisolated static func journal(_ move: Move) {
        var list = (Config.parse(journalFile)?["moves"] as? [[String: String]]) ?? []
        list.append(["from": move.from, "to": move.to])
        try? FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        Config.writeObject(["moves": list], to: journalFile)
    }
    nonisolated static var learnedFile: URL { stateFolder.appending(path: "routines-sorted.json") }

    nonisolated private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Makes `change` to the routines and writes them. If routines.json was edited by hand since Petal last read
    /// it, the change is made to what's in the file instead, so that edit is never written over (a routine finishing
    /// and noting its last run mustn't bring back one deleted in the file, or undo an edit there).
    private func saveRoutines(_ change: @escaping (inout [Routine]) -> Void) {
        change(&list)
        let mine = list
        let known = stamp
        let url = Self.file
        Self.io.async {
            var routines = mine
            var outside = false
            if let now = Self.modified(url), now != known {
                // Edited by hand but not readable (a typo): left as it is, for the person to fix; memory keeps the
                // change until then.
                guard let disk = (Config.parse(url)?["routines"] as? [[String: Any]])?.compactMap(Routine.init) else { return }
                routines = disk
                change(&routines)
                outside = true
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            Config.writeObject(["routines": routines.map(\.json)], to: url)
            let stamp = Self.modified(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.stamp = stamp
                    if outside { self.adopt(routines) }
                }
            }
        }
    }

    /// The routines as they are in the file now. One whose rule changed there (or that's gone) drops what was
    /// decided under the old one, as when it's saved through Petal.
    private func adopt(_ routines: [Routine]) {
        for old in list {
            let new = routines.first { $0.id == old.id }
            if new == nil || new!.words != old.words || new!.actions != old.actions || new!.trigger != old.trigger {
                ruleChanged(old.id, gone: new == nil)
            } else if old.on, new?.on == false {
                stopped(old.id)
            }
        }
        list = routines
        watch()
    }

    private func saveLog() {
        let object: [String: Any] = ["entries": log.prefix(300).map(\.json)]
        Self.io.async {
            try? FileManager.default.createDirectory(at: Self.stateFolder, withIntermediateDirectories: true)
            Config.writeObject(object, to: Self.logFile)
        }
    }

    private func saveLearned() {
        let object: [String: Any] = learned
        Self.io.async {
            try? FileManager.default.createDirectory(at: Self.stateFolder, withIntermediateDirectories: true)
            Config.writeObject(object, to: Self.learnedFile)
        }
    }

    /// Every write still under way (on quit).
    nonisolated static func flush() { io.sync {} }

    // MARK: Running

    var isOn: Bool { standalone || PetalApp.shared.config.bool("routines") }

    func start(_ ready: (() -> Void)? = nil) {
        Self.io.async {
            let parsed = Config.parse(Self.file)?["routines"] as? [[String: Any]]
            let routines = (parsed ?? []).compactMap(Routine.init)
            let log = (Config.parse(Self.logFile)?["entries"] as? [[String: Any]] ?? []).compactMap(Entry.init)
            let learned = (Config.parse(Self.learnedFile) ?? [:]).compactMapValues { $0 as? [String: String] }
            // Not readable (a typo): no stamp is taken, so nothing writes over it until it's fixed and read.
            let stamp = parsed == nil && FileManager.default.fileExists(atPath: Self.file.path) ? nil : Self.modified(Self.file)
            // Moves from a batch Petal quit in the middle of, not in the history yet: kept so they can be put back.
            let known = Set(log.filter { !$0.undone }.flatMap { $0.moves.map { $0.from + "→" + $0.to } })   // put back: not these
            let unrecorded = ((Config.parse(Self.journalFile)?["moves"] as? [[String: String]]) ?? [])
                .compactMap { m in m["from"].flatMap { from in m["to"].map { Move(from: from, to: $0) } } }
                .filter { !known.contains($0.from + "→" + $0.to) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.list = routines
                    var log = log
                    if !unrecorded.isEmpty {
                        log.insert(Entry(id: String(UUID().uuidString.prefix(8)).lowercased(), routine: "", name: "A routine",
                                         text: "Moved \(unrecorded.count) file\(unrecorded.count == 1 ? "" : "s") just before Petal quit",
                                         at: Date(), moves: unrecorded, made: []), at: 0)
                    }
                    self.log = log
                    if !unrecorded.isEmpty { self.saveLog() }
                    Self.io.async { Self.pruneJournal() }
                    self.learned = learned
                    self.stamp = stamp
                    self.watch()
                    ready?()
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        guard !standalone else { return }
        let center = NSWorkspace.shared.notificationCenter
        for (name, event) in [(NSWorkspace.didLaunchApplicationNotification, "opens"), (NSWorkspace.didActivateApplicationNotification, "front")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.appEvent(running, event) }
            })
        }
    }

    func stop() {
        timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        for watch in watches.values { watch.stop() }
        watches = [:]
    }

    /// A watcher on every folder a file routine watches, and none on any other.
    private func watch() {
        var folders: [String: String] = [:]   // path → as written
        for routine in list where routine.on && routine.trigger.on == "file" {
            if let url = Self.url(routine.trigger.folder) { folders[url.path] = routine.trigger.folder }
        }
        for (path, watch) in watches where folders[path] == nil {
            watch.stop()
            watches[path] = nil
        }
        for path in folders.keys where watches[path] == nil {
            let watch = FolderWatch(URL(fileURLWithPath: path)) { [weak self] file in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.arrived(file, in: path) } }
            }
            watch.start()
            watches[path] = watch
        }
    }

    /// Every 30 seconds: routines at a time of day, and routines.json changed by hand.
    private func tick() {
        if isOn {
            let now = Date()
            for routine in list where routine.on && routine.trigger.on == "time" && Self.due(routine.trigger, now: now, last: routine.lastRun) {
                setLastRun(routine.id, now)   // once, even while it's still running
                run(routine, file: nil)
            }
        }
        let known = stamp
        Self.io.async {
            let now = Self.modified(Self.file)
            guard now != known else { return }
            // Not readable (a typo mid-edit): the routines Petal has stay until it is; a file that's gone is none.
            let routines: [Routine]
            if let list = Config.parse(Self.file)?["routines"] as? [[String: Any]] {
                routines = list.compactMap(Routine.init)
            } else if FileManager.default.fileExists(atPath: Self.file.path) {
                return
            } else {
                routines = []
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.stamp = now
                    self.adopt(routines)   // edited in the file
                }
            }
        }
    }

    /// Whether a time routine is due: its time has come today (within two hours, for a Mac that was asleep) and it
    /// hasn't run since.
    nonisolated static func due(_ trigger: Trigger, now: Date, last: Date?) -> Bool {
        let parts = trigger.at.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return false }
        let weekday = (Calendar.current.component(.weekday, from: now) + 5) % 7 + 1   // 1 = Monday
        guard trigger.days.isEmpty || trigger.days.contains(weekday) else { return false }
        let start = Calendar.current.startOfDay(for: now).addingTimeInterval(Double(parts[0] * 3600 + parts[1] * 60))
        return now >= start && now < start.addingTimeInterval(7200) && (last ?? .distantPast) < start
    }

    /// An app opening or coming forward is the person's doing: never Petal's own process, never a browser Petal
    /// started for a run (the same app as the person's, as a second process, from the moment it's started).
    nonisolated static func personsEvent(pid: pid_t) -> Bool {
        pid != ProcessInfo.processInfo.processIdentifier && !RunApps.isRun(pid)
    }

    private func appEvent(_ running: NSRunningApplication?, _ event: String) {
        guard isOn, let running, Self.personsEvent(pid: running.processIdentifier) else { return }
        let id = running.bundleIdentifier ?? ""
        for routine in list where routine.on && routine.trigger.on == "app" && routine.trigger.when == event {
            let wanted = routine.trigger.app
            if wanted.caseInsensitiveCompare(id) == .orderedSame || wanted.caseInsensitiveCompare(running.localizedName ?? "") == .orderedSame {
                run(routine, file: nil)
            }
        }
    }

    /// A file settled in a watched folder: every routine for that folder that wants it, the pickiest first.
    private func arrived(_ file: URL, in folder: String) {
        guard isOn else { return }
        let wanting = list.filter { r in
            r.on && r.trigger.on == "file" && Self.url(r.trigger.folder)?.path == folder && Self.wants(r.trigger, file)
        }
        for routine in wanting.sorted(by: { ($0.trigger.types.count + $0.trigger.named.count) > ($1.trigger.types.count + $1.trigger.named.count) }) {
            run(routine, file: file)
        }
    }

    /// One routine at a time, in order, so two files never make two folders for the same thing.
    private func run(_ routine: Routine, file: URL?, stop: RoutineStop = RoutineStop()) {
        jobs.append((routine.id, file, stop))
        next()
    }

    private func next() {
        guard !working, !jobs.isEmpty else { return }
        let job = jobs.removeFirst()
        // Routines turned off meanwhile ("Run my routines", or this one): what's still queued is dropped.
        guard isOn else { jobs = []; return }
        guard let routine = list.first(where: { $0.id == job.id }), routine.on, !routine.usesModes, !job.stop.isStopped else { return next() }
        working = true
        execute(routine, file: job.file, stop: job.stop) { [weak self] _ in
            self?.working = false
            self?.next()
        }
    }

    /// A routine's actions in order. With a file (it just arrived), the file actions move that file; without (a time,
    /// an app), they tidy their folder's files.
    /// `approved`: how many files the person already allowed for the routine's first file action (from the plan they
    /// saw). Each file action is planned when the run reaches it, after the actions before it are done (a Shortcut's
    /// export is there by then); it asks again only when there are more files than they allowed.
    /// `rule`: the rule version the run was decided under (a manual run's card may wait while the routine changes).
    /// `caller`, `live`, `stop`: the chat or AI session that ran it by hand, whose cards these are; once it hangs up
    /// (`stop` is set then, off the main thread too) the rest doesn't happen, not even the rest of a tidy under way.
    private func execute(_ routine: Routine, file: URL?, approved: Int? = nil, rule: Int? = nil, caller: String? = nil,
                         live: @escaping () -> Bool = { true }, stop: RoutineStop = RoutineStop(), done: @escaping ([Move]) -> Void) {
        var said: [String] = []
        var moves: [Move] = []
        var made: [String] = []
        var approved = approved
        let rule = rule ?? ruleVersion[routine.id, default: 0]
        runs.append((routine.id, stop))
        /// Deleted or changed while it ran (a Shortcut exporting, a card waiting), or its asker hung up: the rest of
        /// it doesn't happen.
        func current() -> Bool {
            let still = !stop.isStopped && live() && isOn && rule == ruleVersion[routine.id, default: 0] && list.contains { $0.id == routine.id }
            if !still { stop.stop() }
            return still
        }
        func finish() {
            runs.removeAll { $0.stop === stop }
            if !said.isEmpty { record(routine, said: said, moves: moves, made: made) }
            done(moves)
        }
        func step(_ index: Int) {
            guard index < routine.actions.count, current() else { return finish() }
            let action = routine.actions[index]
            guard action.movesFiles else {
                // The next step waits for this one (opening, hiding: off the main thread) to finish.
                return perform(action, stop: stop) { text in
                    if let text { said.append(text) }
                    step(index + 1)
                }
            }
            if let file {
                guard moves.isEmpty else { return step(index + 1) }   // already moved by an earlier action
                place(routine, action, file) { move, folder, new, waits in
                    if let move {
                        moves.append(move)
                        if new { made.append(folder.path) }
                        said.append("moved “\(file.lastPathComponent)” to \(folder.lastPathComponent)" + (new ? " (a new folder)" : ""))
                    } else if waits {
                        said.append("left “\(file.lastPathComponent)” where it is, waiting for the AI")
                    }
                    step(index + 1)
                }
            } else {
                let use = { (plan: Plan, allowed: Bool) in
                    // Its asker hung up, or the routine changed, while this folder was planned: no card goes up.
                    guard current() else { return finish() }
                    // Many files ask first, however the routine was started (a time, an app, or by hand).
                    self.confirm(!allowed && plan.items.count >= 10, "Tidy \(plan.items.count) files in \(plan.source.lastPathComponent)",
                                 "\(routine.name). You can put them back.", owner: caller) { yes in
                        guard yes else {
                            said.append("left \(plan.items.count) files in \(plan.source.lastPathComponent) (not allowed)")
                            return step(index + 1)
                        }
                        guard current() else { return finish() }
                        self.apply(plan, stop: stop) { done, folders, cut in
                            moves += done
                            made += folders
                            if !done.isEmpty { said.append(Self.tidied(done, in: plan.source)) }
                            if cut { said.append("stopped before the rest of \(plan.source.lastPathComponent)") }
                            if !plan.waitingForAI.isEmpty {
                                said.append("left \(plan.waitingForAI.count) file\(plan.waitingForAI.count == 1 ? "" : "s") waiting for the AI")
                            }
                            step(index + 1)
                        }
                    }
                }
                let allowance = approved
                approved = nil
                plan(routine, action) { plan in
                    guard let plan, !plan.items.isEmpty else {
                        if let waiting = plan?.waitingForAI, !waiting.isEmpty {
                            said.append("left \(waiting.count) file\(waiting.count == 1 ? "" : "s") waiting for the AI")
                        }
                        return step(index + 1)
                    }
                    use(plan, allowance.map { plan.items.count <= $0 } ?? false)
                }
            }
        }
        step(0)
    }

    nonisolated static func tidied(_ moves: [Move], in source: URL) -> String {
        let folders = Set(moves.map { URL(fileURLWithPath: $0.to).deletingLastPathComponent().lastPathComponent })
        return "tidied \(moves.count) file\(moves.count == 1 ? "" : "s") in \(source.lastPathComponent)"
            + (folders.count > 1 ? " into \(folders.count) folders" : folders.first.map { " into \($0)" } ?? "")
    }

    private func setLastRun(_ id: String, _ date: Date, result: String? = nil) {
        guard list.contains(where: { $0.id == id }) else { return }
        saveRoutines { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].lastRun = date
            if let result { list[index].lastResult = result }
        }
    }

    private func record(_ routine: Routine, said: [String], moves: [Move], made: [String]) {
        var text = said.joined(separator: "; ")
        text = text.prefix(1).uppercased() + text.dropFirst()
        log.insert(Entry(id: String(UUID().uuidString.prefix(8)).lowercased(), routine: routine.id, name: routine.name, text: text,
                         at: Date(), moves: moves, made: made), at: 0)
        if log.count > 300 { log.removeLast(log.count - 300) }
        saveLog()
        // In the history now (written first, on the same queue): its moves leave the journal once the file has them.
        Self.io.async { Self.pruneJournal() }
        setLastRun(routine.id, Date(), result: text)
    }

    /// Opening, hiding, a Shortcut: decided when the routine was made, so it costs nothing now.
    /// One action that isn't moving files; `done` hears what it did (nil: nothing to do). Opening addresses and
    /// files and hiding apps wait on Launch Services and the apps: off the main thread, the answer back on it, each
    /// change there right after reading `stop` (its asker hung up, the routine changed or went).
    private func perform(_ action: Action, stop: RoutineStop, done: @escaping (String?) -> Void) {
        guard !standalone else { return done(nil) }
        let app = PetalApp.shared
        switch action.kind {
        case "open":
            var opened: [String] = []
            var urls: [URL] = []
            var launched: [String] = []
            for item in action.apps {
                if item.contains("://"), let url = URL(string: item) {
                    urls.append(url)
                    opened.append(url.host ?? item)
                } else if item.hasPrefix("/") || item.hasPrefix("~") {
                    urls.append(URL(fileURLWithPath: (item as NSString).expandingTildeInPath))
                    opened.append((item as NSString).lastPathComponent)
                } else if !NSWorkspace.shared.personsApplications.contains(where: { $0.bundleIdentifier == item }) {
                    app.docks.launch(item)   // Launch Services' own asynchronous open (and the dock's launch pulse)
                    launched.append(item)
                    opened.append(Apps.name(item))
                }
            }
            let said = opened.isEmpty ? nil : "opened " + Apps.listed(opened)
            guard !urls.isEmpty || !launched.isEmpty else { return done(said) }
            // The next step waits until the apps are running (30 s at most) and the addresses and files are opened.
            Assist.off({ !stop.isStopped }, {
                for url in urls {
                    guard !stop.isStopped else { return }
                    NSWorkspace.shared.open(url)
                }
                let end = Date().addingTimeInterval(30)
                while Date() < end, !stop.isStopped, !launched.allSatisfy({ !NSRunningApplication.persons(withBundleIdentifier: $0).isEmpty }) {
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }) { ran in done(ran || !launched.isEmpty ? said : nil) }
        case "hide":
            let running = NSWorkspace.shared.personsApplications.filter { r in action.apps.contains { $0 == r.bundleIdentifier } && !r.isHidden }
            guard !running.isEmpty else { return done(nil) }
            let said = "hid " + Apps.listed(running.compactMap(\.localizedName))
            Assist.off({ !stop.isStopped }, {
                for app in running {
                    guard !stop.isStopped else { return }
                    app.hide()
                }
            }) { ran in done(ran ? said : nil) }
        case "shortcut":
            guard !action.name.isEmpty else { return done(nil) }
            // The next step waits for it to finish (5 minutes at most): an export it makes is there before filing.
            Shortcuts.run(action.name, timeout: 300) { ok in
                done(ok ? "ran the Shortcut “\(action.name)”" : "ran the Shortcut “\(action.name)”, which didn't finish cleanly")
            }
        default:
            done(nil)
        }
    }

    // MARK: Sorting files

    private var quick: ((String, String, @escaping ([String: Any]?) -> Void) -> Void)? {
        if let quickCall { return quickCall }
        guard !standalone else { return nil }
        let app = PetalApp.shared
        guard app.chatProvider.flatMap({ app.paths[$0] }) != nil else { return nil }
        return { prompt, key, done in app.brain.ask(prompt, key: key, done: done) }
    }

    /// One file that just arrived: where it goes (the AI's answer for files named like it, if there is one), then
    /// the move, off the main thread. `done(move, folder, made, waitsForAI)`; no move when it stays.
    private func place(_ routine: Routine, _ action: Action, _ file: URL, done: @escaping (Move?, URL, Bool, Bool) -> Void) {
        let base = Self.url(routine.source(action)) ?? file.deletingLastPathComponent()
        let finish = { (folder: URL?) in
            guard let folder else { return done(nil, base, false, false) }
            Self.io.async {
                let result = Self.move(file, into: folder)
                DispatchQueue.main.async { MainActor.assumeIsolated { done(result?.move, folder, result?.made ?? false, false) } }
            }
        }
        if action.kind == "move" {
            return finish(Self.url(action.to, base: base))
        }
        let into = action.into.isEmpty ? base : (Self.url(action.into, base: base) ?? base)
        // Kind folders (Images, PDFs, …) only for a routine set to sort by kind: one in the person's own words keeps
        // its own rules, with or without the AI.
        guard action.by == "ai" else { return finish(into.appending(path: Self.kind(of: file))) }
        let key = Self.pattern(file.lastPathComponent)
        // What the AI answered before for names like this one comes first; with no AI and no answer, it stays put.
        if let folder = learned[routine.id]?[key] { return finish(into.appending(path: folder)) }
        guard let quick else { return done(nil, base, false, true) }
        let words = routine.words
        let rule = ruleVersion[routine.id, default: 0]
        Self.io.async {
            // Moved already by a pickier routine: nothing to ask.
            guard FileManager.default.fileExists(atPath: file.path) else {
                return DispatchQueue.main.async { MainActor.assumeIsolated { done(nil, base, false, false) } }
            }
            let folders = Self.survey(into)
            let prompt = Self.prompt(words: words, into: into, folders: folders, files: [(file.lastPathComponent, Self.facts(file, peek: true))])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    quick(prompt, "r|\(routine.id)|\(rule)|\(key)") { answer in
                        // The rule changed while the AI answered: its answer is for the old rule, so nothing is
                        // learned or moved by it.
                        guard self.isOn, rule == self.ruleVersion[routine.id, default: 0] else { return finish(nil) }
                        let picked = (answer?["folders"] as? [String: Any])?["1"] ?? answer?["folder"]
                        guard let name = Self.folderName(picked, among: folders.map(\.name)) else { return finish(nil) }
                        self.learn(routine.id, [key: name])
                        finish(into.appending(path: name))
                    }
                }
            }
        }
    }

    func learn(_ routine: String, _ patterns: [String: String]) {
        guard !patterns.isEmpty else { return }
        learned[routine, default: [:]].merge(patterns) { old, _ in old }
        saveLearned()
    }

    /// What tidying a folder's files would do: every file there (up to `mostFiles`), the AI asked about 40 at a time
    /// for the ones whose names it hasn't seen.
    func plan(_ routine: Routine, _ action: Action, done: @escaping (Plan?) -> Void) {
        guard let source = Self.url(routine.source(action)) else { return done(nil) }
        let rule = ruleVersion[routine.id, default: 0]   // what's learned below is for this rule
        let trigger = routine.trigger
        let into = action.kind == "move" ? (Self.url(action.to, base: source) ?? source)
            : (action.into.isEmpty ? source : (Self.url(action.into, base: source) ?? source))
        // Sorting in the person's own words (by: ai) never falls back to kind folders: with no AI, only the answers
        // learned before are used, and the rest wait for the AI.
        let inWords = action.kind == "sort" && action.by == "ai"
        let byAI = inWords && quick != nil
        let known = learned[routine.id] ?? [:]
        Self.io.async {
            let all = Self.files(in: source).filter { Self.wants(trigger, $0) }
            var plan = Plan(routine: routine.id, source: source)
            plan.total = all.count
            plan.later = max(0, all.count - Self.mostFiles)
            let files = Array(all.prefix(Self.mostFiles))
            let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
            if action.kind == "move" {
                plan.items = files.map { Plan.Item(file: $0, folder: into, new: !exists(into)) }
            } else if !inWords {
                plan.items = files.map { let f = into.appending(path: Self.kind(of: $0)); return Plan.Item(file: $0, folder: f, new: !exists(f)) }
            } else if !byAI {
                for file in files {
                    if let name = known[Self.pattern(file.lastPathComponent)] {
                        let f = into.appending(path: name)
                        plan.items.append(Plan.Item(file: file, folder: f, new: !exists(f)))
                    } else {
                        plan.waitingForAI.append(file.lastPathComponent)
                    }
                }
            }
            guard byAI else { return DispatchQueue.main.async { done(plan) } }
            let folders = Self.survey(into)
            var asking: [(url: URL, name: String, facts: String)] = []
            for file in files {
                if let name = known[Self.pattern(file.lastPathComponent)] {
                    let f = into.appending(path: name)
                    plan.items.append(Plan.Item(file: file, folder: f, new: !exists(f)))
                } else {
                    asking.append((file, file.lastPathComponent, Self.facts(file, peek: false)))
                }
            }
            let chunks = stride(from: 0, to: asking.count, by: 40).map { Array(asking[$0..<min($0 + 40, asking.count)]) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.ask(chunks, routine: routine, rule: rule, into: into, folders: folders, plan: plan, done: done)
                }
            }
        }
    }

    private func ask(_ chunks: [[(url: URL, name: String, facts: String)]], routine: Routine, rule: Int, into: URL,
                     folders: [(name: String, samples: [String])], plan: Plan, done: @escaping (Plan?) -> Void) {
        // The rule changed meanwhile, or routines were turned off: no more is asked.
        guard isOn, rule == ruleVersion[routine.id, default: 0] else { return done(nil) }
        guard let chunk = chunks.first, let quick else { return done(plan) }
        var plan = plan
        // Folders this plan makes count as there for the next chunk, so similar files share them.
        var seen = folders
        for item in plan.items where !seen.contains(where: { $0.name.caseInsensitiveCompare(item.folder.lastPathComponent) == .orderedSame }) {
            seen.append((item.folder.lastPathComponent, [item.file.lastPathComponent]))
        }
        let prompt = Self.prompt(words: routine.words, into: into, folders: seen, files: chunk.map { ($0.name, $0.facts) })
        let key = "rb|\(routine.id)|\(rule)|" + chunk.map(\.name).joined(separator: "|")
        quick(prompt, key) { answer in
            // The rule changed while the AI answered: this plan is for the old rule, so nothing in it is learned or
            // moved.
            guard self.isOn, rule == self.ruleVersion[routine.id, default: 0] else { return done(nil) }
            let picks = answer?["folders"] as? [String: Any] ?? [:]
            var patterns: [String: String] = [:]
            for (index, file) in chunk.enumerated() {
                guard let name = Self.folderName(picks[String(index + 1)], among: seen.map(\.name)) else {
                    plan.leftAlone.append(file.name)
                    continue
                }
                let folder = into.appending(path: name)
                let new = !seen.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                plan.items.append(Plan.Item(file: file.url, folder: folder, new: new))
                if new { seen.append((name, [file.name])) }
                patterns[Self.pattern(file.name)] = name
            }
            if answer != nil { self.learn(routine.id, patterns) }
            self.ask(Array(chunks.dropFirst()), routine: routine, rule: rule, into: into, folders: seen, plan: plan, done: done)
        }
    }

    /// Does a plan's moves off the main thread, asking `stop` before each (each move is in the journal as it's
    /// made). `done(moves, folders made, stopped before the end)`.
    private func apply(_ plan: Plan, stop: RoutineStop, done: @escaping ([Move], [String], Bool) -> Void) {
        let items = plan.items
        Self.io.async {
            let result = RoutineStop.each(items, stop: stop) { item -> (move: Move, made: String?)? in
                Self.move(item.file, into: item.folder).map { ($0.move, $0.made ? item.folder.path : nil) }
            }
            let moves = result.done.map(\.move), made = result.done.compactMap(\.made)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(moves, made, result.stopped) } }
        }
    }

    /// Puts a history entry's files back where they were (the newest that can be, without an id), and takes away
    /// the folders made for them if they're empty now. `done(paths put back)`.
    /// `stop`: the chat or AI session that asked (petal_routine_undo) hung up: the files not yet back stay put, read
    /// before each move.
    func undo(_ id: String? = nil, stop: RoutineStop = RoutineStop(), done: @escaping ([String]) -> Void = { _ in }) {
        guard let index = id.flatMap({ id in log.firstIndex { $0.id == id } }) ?? (id == nil ? log.firstIndex(where: \.canUndo) : nil),
              log[index].canUndo else { return done([]) }
        let entry = log[index]
        log[index].undone = true   // in memory for now; saved once the files are back (what can't come back keeps it open)
        // The watchers leave the files coming back alone, and the AI asks again about names like these.
        for move in entry.moves {
            let from = URL(fileURLWithPath: move.from)
            watches[from.deletingLastPathComponent().path]?.ignore(from.lastPathComponent)
        }
        if var patterns = learned[entry.routine] {
            for move in entry.moves { patterns[Self.pattern(URL(fileURLWithPath: move.from).lastPathComponent)] = nil }
            learned[entry.routine] = patterns
            saveLearned()
        }
        Self.io.async {
            let fm = FileManager.default
            var back: [String] = []
            var stuck: [Move] = []
            for move in entry.moves.reversed() {
                // Its asker gone meanwhile: the rest stays where the routine put it, to put back another time.
                guard !stop.isStopped else { stuck.append(move); continue }
                // Something is in its old place now, or it's gone from where it was put: it stays to try again.
                guard fm.fileExists(atPath: move.to), !fm.fileExists(atPath: move.from),
                      (try? fm.moveItem(atPath: move.to, toPath: move.from)) != nil else {
                    if fm.fileExists(atPath: move.to) { stuck.append(move) }
                    continue
                }
                back.append(move.from)
            }
            for folder in Set(entry.made) where !stop.isStopped {
                // rmdir only takes an empty folder, so a file that arrived a moment ago is never deleted with it.
                try? fm.removeItem(atPath: folder + "/.DS_Store")
                rmdir(folder)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !stuck.isEmpty, let index = self.log.firstIndex(where: { $0.id == entry.id }) {
                        self.log[index].undone = false
                        self.log[index].moves = stuck
                    }
                    self.saveLog()
                    done(back)
                }
            }
        }
    }

    // MARK: Changing them (the settings window, and Petal AI's tools)

    func setOn(_ id: String, _ on: Bool) {
        guard list.contains(where: { $0.id == id }) else { return }
        if !on { stopped(id) }
        saveRoutines { list in
            if let index = list.firstIndex(where: { $0.id == id }) { list[index].on = on }
        }
        watch()
    }

    func delete(_ id: String) {
        ruleChanged(id, gone: true)
        saveRoutines { $0.removeAll { $0.id == id } }
        watch()
    }

    /// Turned off (the settings switch, the chat, the file): an AI answer or a card still on its way doesn't move
    /// anything, and its queued files are dropped.
    private func stopped(_ id: String) {
        ruleVersion[id, default: 0] += 1
        plans[id] = nil
        jobs.removeAll { $0.id == id }
        stopRuns(id)
    }

    private func stopRuns(_ id: String) {
        for run in runs where run.id == id { run.stop.stop() }
    }

    /// A routine's rule changed, or it's gone: whatever was decided under the old rule (an AI answer on its way, a
    /// dry run's plan, a card waiting, what the AI learned) no longer holds; a deleted one's queued files are dropped.
    private func ruleChanged(_ id: String, gone: Bool) {
        ruleVersion[id, default: 0] += 1
        plans[id] = nil
        if gone { jobs.removeAll { $0.id == id } }
        stopRuns(id)
        if learned[id] != nil {
            learned[id] = nil
            saveLearned()
        }
    }

    /// Adds or replaces a routine (checked first); in the check, without the rest of Petal.
    func save(_ routine: Routine) {
        if let index = list.firstIndex(where: { $0.id == routine.id }) {
            // Its rule changed (its words, where it acts, where files go): what the AI answered for the old rule
            // doesn't hold any more, so names like those are asked about again.
            let old = list[index]
            if old.words != routine.words || old.actions != routine.actions || old.trigger != routine.trigger {
                ruleChanged(routine.id, gone: false)
            } else if old.on, !routine.on {
                stopped(routine.id)
            }
        }
        plans[routine.id] = nil
        saveRoutines { list in
            if let index = list.firstIndex(where: { $0.id == routine.id }) {
                var routine = routine
                routine.lastRun = list[index].lastRun
                routine.lastResult = list[index].lastResult
                list[index] = routine
            } else {
                list.append(routine)
            }
        }
        watch()
    }

    /// Petal AI's routine tools (`petal_routines`, `petal_routine_save`, `petal_routine_run`, `petal_routine_undo`,
    /// `petal_routine_delete`), from Assist.handle. `caller`: the chat or AI session asking, whose card a tidy's is;
    /// `live`: false once it hung up, and then a run it started neither asks nor goes on; `stop` is set then too, so
    /// moves under way off the main thread stop.
    func handle(_ name: String, _ args: [String: Any], _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void,
                caller: String? = nil, live: @escaping () -> Bool = { true }, stop: RoutineStop = RoutineStop()) {
        switch name {
        case "petal_routines":
            send(["on": isOn, "routines": list.map { r -> [String: Any] in
                var o = r.json
                o["does"] = summary(r)
                if r.usesModes { o["skipped"] = Routine.modesGone + " Delete it, or save it again with another trigger and actions." }
                return o
            }, "history": log.prefix(15).map { e -> [String: Any] in
                ["id": e.id, "routine": e.name, "text": e.text, "at": e.at.timeIntervalSince1970, "canPutBack": e.canUndo]
            }])
        case "petal_routine_save": saveTool(args, live: live, send, fail)
        case "petal_routine_delete":
            let id = args["id"] as? String ?? ""
            guard list.contains(where: { $0.id == id }) else { return fail("No routine with id \(id); petal_routines lists them.") }
            delete(id)
            send(["deleted": id])
        case "petal_routine_run": runTool(args, caller: caller, live: live, stop: stop, send, fail)
        case "petal_routine_undo":
            undo(args["entry"] as? String, stop: stop, done: { (back: [String]) in
                let reply: [String: Any] = back.isEmpty ? ["putBack": [String](), "note": "Nothing to put back."] : ["putBack": back]
                send(reply)
            })
        default: fail("Unknown tool \(name)")
        }
    }

    private func saveTool(_ args: [String: Any], live: @escaping () -> Bool, _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        let old = list.first { $0.id == (args["id"] as? String ?? "") }
        var trigger = (args["trigger"] as? [String: Any]).map(Trigger.init) ?? old?.trigger ?? Trigger()
        var actions = (args["actions"] as? [[String: Any]])?.map(Action.init) ?? old?.actions ?? []
        let words = ((args["words"] as? String) ?? old?.words ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return fail("words: what the person asked for, in their own words") }
        guard ["file", "app", "time"].contains(trigger.on) else { return fail("trigger.on is file, app or time") }
        guard !actions.isEmpty else { return fail("actions: at least one") }
        for action in actions {
            switch action.kind {
            case "sort", "move":
                if action.folder.isEmpty && trigger.on != "file" { return fail("\(action.kind) needs folder: the folder whose files it takes") }
                if action.kind == "move" && action.to.isEmpty { return fail("move needs to: the folder files go into") }
            case "open", "hide": if action.apps.isEmpty { return fail("\(action.kind) needs apps") }
            case "shortcut": if action.name.isEmpty { return fail("shortcut needs name") }
            default: return fail("Each action's do is sort, move, open, hide or shortcut")
            }
        }
        if trigger.on == "time", Self.minutes(trigger.at) == nil { return fail("trigger.at is \"HH:MM\"") }
        let id = old?.id ?? String(UUID().uuidString.prefix(8)).lowercased()
        let name = (args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? old?.name ?? String(words.prefix(40))
        let on = args["on"] as? Bool ?? old?.on ?? true
        // Off the main thread: folders checked (in the home folder, never all of it or its Library), app names made
        // bundle ids, the files already there counted.
        Self.io.async {
            func check(_ text: String, base: URL? = nil, mustExist: Bool) -> String? {
                guard let url = Self.url(text, base: base), Self.allowed(url) else { return nil }
                if mustExist && !FileManager.default.fileExists(atPath: url.path) { return nil }
                return Self.tilde(url)
            }
            var problem: String?
            var source: URL?
            if trigger.on == "file" {
                if let folder = check(trigger.folder, mustExist: true) { trigger.folder = folder; source = Self.url(folder) }
                else { problem = "trigger.folder must be a folder there is in the home folder (not the home folder itself or Library)" }
            }
            if trigger.on == "app" { trigger.app = Self.bundleID(trigger.app) }
            for index in actions.indices {
                let base = Self.url(actions[index].folder.isEmpty ? trigger.folder : actions[index].folder)
                switch actions[index].kind {
                case "sort", "move":
                    if !actions[index].folder.isEmpty {
                        if let folder = check(actions[index].folder, mustExist: true) { actions[index].folder = folder } else { problem = "folder \(actions[index].folder) isn't a folder Petal can tidy" }
                    }
                    if source == nil { source = Self.url(actions[index].folder) }
                    if !actions[index].into.isEmpty {
                        if let into = check(actions[index].into, base: base, mustExist: false) { actions[index].into = into } else { problem = "into must be in the home folder" }
                    }
                    if actions[index].kind == "move" {
                        if let to = check(actions[index].to, base: base, mustExist: false) { actions[index].to = to } else { problem = "to must be in the home folder" }
                    }
                case "open", "hide":
                    actions[index].apps = actions[index].apps.map { $0.contains("://") || $0.hasPrefix("/") || $0.hasPrefix("~") ? $0 : Self.bundleID($0) }
                default: break
                }
            }
            let existing = source.map { folder in Self.files(in: folder).filter { Self.wants(trigger, $0) }.count } ?? 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let problem { return fail(problem) }
                    // Its asker gone while the folders were checked: nothing is saved for it.
                    guard live() else { return }
                    let routine = Routine(id: id, name: name, words: words, on: on, trigger: trigger, actions: actions)
                    self.save(routine)
                    var reply: [String: Any] = ["saved": routine.json, "does": self.summary(routine)]
                    if !self.isOn { reply["note"] = "Routines are off in Petal's settings (routines); it runs once they're on." }
                    if existing > 0, routine.actions.contains(where: \.movesFiles) {
                        reply["filesThereNow"] = existing
                        reply["next"] = "It only acts on new files. petal_routine_run with dryRun: true shows what it would do with the \(existing) there now; without dryRun it does it (Petal asks the person first when it's many)."
                    }
                    send(reply)
                }
            }
        }
    }

    private func runTool(_ args: [String: Any], caller: String?, live: @escaping () -> Bool, stop: RoutineStop,
                         _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        let id = args["id"] as? String ?? ""
        guard let routine = list.first(where: { $0.id == id }) else { return fail("No routine with id \(id); petal_routines lists them.") }
        guard !routine.usesModes else { return fail(Routine.modesGone) }
        let dry = args["dryRun"] as? Bool ?? false
        let rule = ruleVersion[id, default: 0]   // the routine as it is now; a change while its card waits stops it
        let changed = { send(["note": "The routine changed while it waited; nothing moved. Run it again."]) }
        guard let action = routine.actions.first(where: \.movesFiles) else {
            if dry { return send(["wouldDo": summary(routine)]) }
            run(routine, file: nil, stop: stop)
            return send(["ran": summary(routine)])
        }
        let go = { (plan: Plan) in
            // Its asker gone while the plan was made (the AI sorting): nothing is asked or moved for it.
            guard live(), !stop.isStopped else { return }
            let n = plan.items.count
            // Nothing to move there: the routine's other actions still run.
            guard n > 0 else {
                self.plans[id] = nil
                return self.execute(routine, file: nil, approved: 0, rule: rule, caller: caller, live: live, stop: stop) { moves in
                    send(["moved": moves.count, "waitingForAI": plan.waitingForAI.count,
                          "note": "Nothing to move in its first folder; its other actions ran."])
                }
            }
            let where_ = plan.source.lastPathComponent
            let counts = Self.counts(plan)
            let detail = counts.prefix(4).map { "\($0.name) \($0.count)" }.joined(separator: ", ") + (counts.count > 4 ? " and more" : "") + ". You can put them back."
            self.confirm(n >= 10, "Tidy \(n) files in \(where_)", detail, owner: caller) { allowed in
                guard allowed, live() else { return send(["declined": "The person didn't allow it."]) }
                guard rule == self.ruleVersion[id, default: 0] else { return changed() }
                self.plans[id] = nil
                // Every action of the routine, in order; its first file action may move up to this many unasked.
                self.execute(routine, file: nil, approved: n, rule: rule, caller: caller, live: live, stop: stop) { moves in
                    let into = Dictionary(moves.map { (URL(fileURLWithPath: $0.to).deletingLastPathComponent().lastPathComponent, 1) }, uniquingKeysWith: +)
                    send(["moved": moves.count, "into": into,
                          "leftAlone": plan.leftAlone.count, "waitingForAI": plan.waitingForAI.count, "notYet": plan.later,
                          "undo": "petal_routine_undo puts them back (or Put back in Petal's settings, Routines)"])
                }
            }
        }
        // A dry run's plan from the last ten minutes is used as shown.
        if !dry, let plan = plans[id], plan.at.timeIntervalSinceNow > -600 { return go(plan) }
        plan(routine, action) { plan in
            guard let plan else { return fail("Its folder isn't there.") }
            guard dry else { return go(plan) }
            self.plans[id] = plan
            send(["files": plan.total, "wouldMove": plan.items.count,
                  "into": Self.counts(plan).map { $0.name + ($0.new ? " (new)" : "") + ": \($0.count)" },
                  "examples": plan.items.prefix(15).map { "\($0.file.lastPathComponent) → \($0.folder.lastPathComponent)" },
                  "leftAlone": plan.leftAlone.prefix(15).map { $0 }, "waitingForAI": plan.waitingForAI.prefix(15).map { $0 }, "notYet": plan.later,
                  "note": "Nothing moved yet. petal_routine_run without dryRun does it."])
        }
    }

    /// Asked first with Petal AI's card when it's many files; the check never asks. `owner`: the chat or AI session
    /// that ran it (nil for a routine's own trigger).
    private func confirm(_ many: Bool, _ title: String, _ detail: String, owner: String?, done: @escaping (Bool) -> Void) {
        guard many, !standalone else { return done(true) }
        PetalApp.shared.assist.ask("tidy", title, detail: detail, owner: owner, done: done)
    }

    nonisolated static func counts(_ plan: Plan) -> [(name: String, count: Int, new: Bool)] {
        var counts: [String: (Int, Bool)] = [:]
        for item in plan.items {
            let name = item.folder.lastPathComponent
            counts[name] = ((counts[name]?.0 ?? 0) + 1, item.new)
        }
        return counts.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.count > $1.count }
    }

    // MARK: In words

    /// "When a file lands in Downloads (PDFs): moves it to Receipts".
    func summary(_ routine: Routine) -> String {
        let t = routine.trigger
        var when: String
        switch t.on {
        case "file":
            when = "When a file lands in \(Self.short(t.folder))"
            let only = t.types + t.named.map { "“\($0)”" }
            if !only.isEmpty { when += " (\(only.joined(separator: ", ")))" }
        case "app": when = "When \(standalone ? t.app : Apps.name(t.app)) " + (t.when == "front" ? "comes to the front" : "opens")
        case "mode": when = "When a Desktop entered the mode “\(t.mode)”"
        case "time":
            let days: String
            switch t.days.sorted() {
            case [], [1, 2, 3, 4, 5, 6, 7]: days = "every day"
            case [1, 2, 3, 4, 5]: days = "on weekdays"
            case [6, 7]: days = "at weekends"
            default: days = "on " + t.days.sorted().map { ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][$0 - 1] }.joined(separator: ", ")
            }
            when = "At \(t.at) \(days)"
        default: when = "Never"
        }
        let what = routine.actions.map { a -> String in
            let them = t.on == "file" ? "it" : "the files in \(Self.short(routine.source(a)))"
            switch a.kind {
            case "sort": return "sorts \(them) into folders" + (a.by == "kind" ? " by kind" : "") + (a.into.isEmpty ? "" : " in \(Self.short(a.into))")
            case "move": return "moves \(them) to \(Self.short(a.to))"
            case "mode": return "switched to the mode “\(a.mode)”"
            case "open": return "opens " + Apps.listed(a.apps.map { $0.contains("://") || $0.hasPrefix("/") || $0.hasPrefix("~") ? $0 : (standalone ? $0 : Apps.name($0)) })
            case "hide": return "hides " + Apps.listed(a.apps.map { standalone ? $0 : Apps.name($0) })
            case "shortcut": return "runs the Shortcut “\(a.name)”"
            default: return a.kind
            }
        }
        return when + ": " + what.joined(separator: ", then ")
    }

    // MARK: Helpers (off the main thread)

    nonisolated static func list(_ value: Any?) -> [String] {
        if let array = value as? [Any] { return array.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if let text = value as? String { return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return []
    }

    nonisolated static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    /// A folder as written: "~/Downloads", an absolute path, a bare Downloads, Desktop, Documents…, "screenshots"
    /// (where macOS saves them), or a name inside `base`.
    nonisolated static func url(_ text: String, base: URL? = nil) -> URL? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if text.lowercased() == "screenshots" {
            let saved = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") ?? ""
            return saved.isEmpty ? home.appending(path: "Desktop") : URL(fileURLWithPath: (saved as NSString).expandingTildeInPath)
        }
        if text.hasPrefix("~") || text.hasPrefix("/") { return URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL }
        if ["downloads", "desktop", "documents", "pictures", "movies", "music"].contains(text.lowercased()) && base == nil {
            return home.appending(path: text.prefix(1).uppercased() + text.dropFirst().lowercased())
        }
        return (base ?? home).appending(path: text).standardizedFileURL
    }

    /// Inside the home folder, and not all of it, its Library or a hidden folder. (Testing with `PETAL_ROUTINES`
    /// also allows the temporary folders.)
    nonisolated static func allowed(_ url: URL) -> Bool {
        let home = NSHomeDirectory()
        let path = url.standardizedFileURL.path
        if ProcessInfo.processInfo.environment["PETAL_ROUTINES"]?.isEmpty == false,
           ["/tmp/", "/private/tmp/", "/private/var/folders/", "/var/folders/"].contains(where: path.hasPrefix) { return true }
        guard path.hasPrefix(home + "/") else { return false }
        let parts = path.dropFirst(home.count + 1).split(separator: "/")
        return !parts.isEmpty && parts[0] != "Library" && !parts.contains { $0.hasPrefix(".") }
    }

    nonisolated static func tilde(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(NSHomeDirectory() + "/") ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }

    nonisolated static func short(_ text: String) -> String {
        text.hasPrefix("~/") && text.dropFirst(2).split(separator: "/").count == 1 ? String(text.dropFirst(2)) : text
    }

    /// A bundle id for an app's name (or the id itself).
    nonisolated static func bundleID(_ name: String) -> String {
        if name.contains(".") && !name.contains(" ") { return name }
        let apps = MCP.apps(matching: name)
        return apps.first { ($0["name"] ?? "").caseInsensitiveCompare(name) == .orderedSame }?["id"] ?? apps.first?["id"] ?? name
    }

    /// The files at the top of a folder, newest first: no folders, hidden files or downloads still under way.
    nonisolated static func files(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .addedToDirectoryDateKey, .contentModificationDateKey]
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let files = all.compactMap { url -> (URL, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  !FolderWatch.partial.contains(url.pathExtension.lowercased()),
                  // Still downloading: a partial file beside it (Firefox's song.mp3 beside song.mp3.part).
                  !FolderWatch.partial.contains(where: { FileManager.default.fileExists(atPath: url.path + "." + $0) }) else { return nil }
            return (url, values.addedToDirectoryDate ?? values.contentModificationDate ?? .distantPast)
        }
        // As the folder is written (/var, not /private/var), so a put-back file's folder is the one being watched.
        return files.sorted { $0.1 > $1.1 }.map { folder.appending(path: $0.0.lastPathComponent) }
    }

    /// Whether a file is one a file routine is for: its kinds or extensions, and words in its name.
    nonisolated static func wants(_ trigger: Trigger, _ file: URL) -> Bool {
        let name = file.lastPathComponent
        if !trigger.named.isEmpty && !trigger.named.contains(where: { name.localizedCaseInsensitiveContains($0) }) { return false }
        guard !trigger.types.isEmpty else { return true }
        let ext = file.pathExtension.lowercased()
        let kind = kind(of: file)
        return trigger.types.contains { type in
            let word = type.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
            switch word {
            case "image", "images", "photo", "photos", "picture", "pictures", "screenshot", "screenshots": return kind == "Images"
            case "pdf", "pdfs": return kind == "PDFs"
            case "video", "videos", "movie", "movies": return kind == "Videos"
            case "audio", "music", "sound", "sounds": return kind == "Audio"
            case "archive", "archives": return kind == "Archives"
            case "installer", "installers", "app", "apps": return kind == "Installers"
            case "code": return kind == "Code"
            case "document", "documents", "doc", "docs": return kind == "Documents" || kind == "PDFs"
            case "font", "fonts": return kind == "Fonts"
            default: return ext == word
            }
        }
    }

    /// A folder for a file by its kind alone: sorting with no AI.
    nonisolated static func kind(of file: URL) -> String {
        let ext = file.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        func is_(_ other: UTType) -> Bool { type?.conforms(to: other) ?? false }
        if is_(.pdf) { return "PDFs" }
        if is_(.image) { return "Images" }
        if is_(.movie) || is_(.video) { return "Videos" }
        if is_(.audio) { return "Audio" }
        if ["dmg", "pkg", "mpkg", "iso"].contains(ext) || is_(.diskImage) { return "Installers" }
        if is_(.archive) || ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"].contains(ext) { return "Archives" }
        if is_(.font) { return "Fonts" }
        if is_(.sourceCode) || is_(.script) || ["json", "yaml", "yml", "toml", "xml", "html", "css", "js", "ts", "swift", "py", "sh"].contains(ext) { return "Code" }
        if is_(.spreadsheet) || is_(.presentation) || is_(.text) || is_(.rtf)
            || ["doc", "docx", "pages", "odt", "key", "numbers", "xls", "xlsx", "ppt", "pptx", "csv", "md", "txt", "epub"].contains(ext) { return "Documents" }
        return "Other"
    }

    /// What a file's name looks like with its numbers and ids taken out ("Screenshot 2026-11-06 at 10.22.33.png" →
    /// "screenshot #-#-# at #.#.#.png"), so the AI's answer for one serves the files named like it. Too few letters
    /// left to mean anything: the name itself.
    nonisolated static func pattern(_ name: String) -> String {
        var text = name.lowercased()
        text = text.replacingOccurrences(of: "(?=[0-9a-f]*[0-9])[0-9a-f]{8,}", with: "~", options: .regularExpression)
        text = text.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
        text = text.replacingOccurrences(of: " ?\\(#\\)", with: "", options: .regularExpression)
        let stem = (text as NSString).deletingPathExtension
        return stem.filter(\.isLetter).count >= 3 ? text : name.lowercased()
    }

    /// The subfolders where sorted files go, with a few of each one's files: what the AI chooses among.
    nonisolated static func survey(_ folder: URL) -> [(name: String, samples: [String])] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let folders = all.compactMap { url -> (URL, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true, values.isPackage != true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        return folders.sorted { $0.1 > $1.1 }.prefix(40).map { url, _ in
            let inside = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }
            return (url.lastPathComponent, Array(inside.prefix(4)))
        }
    }

    /// A line about a file for the AI: its kind and size, the site it was downloaded from, and with `peek` a PDF's
    /// title. Never its contents.
    nonisolated static func facts(_ file: URL, peek: Bool) -> String {
        var parts: [String] = []
        let type = UTType(filenameExtension: file.pathExtension)
        parts.append(type?.localizedDescription ?? (file.pathExtension.isEmpty ? "a file" : file.pathExtension.uppercased() + " file"))
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let host = whereFrom(file) { parts.append("downloaded from \(host)") }
        guard peek else { return parts.joined(separator: ", ") }
        if type?.conforms(to: .pdf) == true, let document = CGPDFDocument(file as CFURL), let info = document.info {
            var value: CGPDFStringRef?
            if CGPDFDictionaryGetString(info, "Title", &value), let value, let title = CGPDFStringCopyTextString(value) as String?,
               !title.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append("titled “\(title.prefix(80))”")
            }
        }
        // Never what's inside a file: sorting runs unattended, and a text file can be a password export.
        return parts.joined(separator: ", ")
    }

    /// The site a download came from (its host only), from the file's "where from".
    nonisolated static func whereFrom(_ file: URL) -> String? {
        let key = "com.apple.metadata:kMDItemWhereFroms"
        let length = getxattr(file.path, key, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(file.path, key, $0.baseAddress, length, 0, 0) }
        guard read > 0, let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return nil }
        return list.compactMap { URL(string: $0)?.host }.first.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }

    nonisolated static func prompt(words: String, into: URL, folders: [(name: String, samples: [String])], files: [(name: String, facts: String)]) -> String {
        let there = folders.isEmpty ? "(none yet)" : folders.map { f in
            "- \(f.name)" + (f.samples.isEmpty ? " (empty)" : ": " + f.samples.map { "\"\($0)\"" }.joined(separator: ", "))
        }.joined(separator: "\n")
        let list = files.enumerated().map { "\($0.offset + 1). \"\($0.element.name)\" (\($0.element.facts))" }.joined(separator: "\n")
        return """
        You keep a folder tidy for someone by sorting its files into subfolders, so similar things end up together.
        What they asked, in their words: "\(words)"
        The folder: \(tilde(into)). Its subfolders now, with a few of the files in each:
        \(there)

        \(files.count == 1 ? "A new file" : "Files to sort"):
        \(list)

        For each file, pick the subfolder it belongs in. Use one that's there when it fits. Otherwise name a new one for the kind of thing it is, which similar files will share later: 1 to 3 plain words in Title Case (like Receipts, Screenshots, Installers, Design Assets), never the file's own name or a date; give files that belong together the same new name, and keep new folders few. If their words say to leave a file like this where it is, use null.
        Reply with ONLY JSON: {"folders": {"1": "<subfolder>"|null\(files.count > 1 ? ", \"2\": …" : "")}}
        """
    }

    /// The AI's folder name, made safe (no slashes, not hidden, short), and spelled as the folder that's there.
    nonisolated static func folderName(_ value: Any?, among existing: [String]) -> String? {
        guard var name = value as? String else { return nil }
        name = name.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ":", with: " ")
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(40)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != "..", name.lowercased() != "null" else { return nil }
        return existing.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
    }

    /// Moves a file into a folder (made if it isn't there), never over another file: "name 2.pdf" instead.
    nonisolated static func move(_ file: URL, into folder: URL) -> (move: Move, made: Bool)? {
        let result = moveOnly(file, into: folder)
        if let result { journal(result.move) }
        return result
    }

    nonisolated private static func moveOnly(_ file: URL, into folder: URL) -> (move: Move, made: Bool)? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path),
              file.deletingLastPathComponent().standardizedFileURL.path != folder.standardizedFileURL.path else { return nil }
        var isFolder: ObjCBool = false
        let made = !fm.fileExists(atPath: folder.path, isDirectory: &isFolder)
        if !made && !isFolder.boolValue { return nil }   // a file is in the way
        if made { guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil } }
        var target = folder.appending(path: file.lastPathComponent)
        let stem = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appending(path: "\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        guard (try? fm.moveItem(at: file, to: target)) != nil else { return nil }
        return (Move(from: file.path, to: target.path), made)
    }
}

/// Watches the top of one folder for files that arrive, and hands each on once it has settled: its size and date
/// unchanged for two looks a second apart, and no download still under way (Chrome's .crdownload, Safari's
/// .download, Firefox's .part beside an empty file). Folders that arrive are left alone.
final class FolderWatch: @unchecked Sendable {
    static let partial: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "tmp", "aria2", "!qb"]

    let folder: URL
    private let arrived: (URL) -> Void
    private let queue = DispatchQueue(label: "petal.routines.watch", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var ticker: DispatchSourceTimer?
    private var known = Set<String>()
    private var waiting: [String: (size: Int, date: Date?, seen: Date, still: Int)] = [:]
    private var skip = Set<String>()
    private var stopped = false

    init(_ folder: URL, arrived: @escaping (URL) -> Void) {
        self.folder = folder
        self.arrived = arrived
    }

    func start() { queue.async { self.reopen() } }

    func stop() {
        queue.async {
            self.stopped = true
            self.source?.cancel()
            self.ticker?.cancel()
        }
    }

    /// A file coming back (put back from the history) isn't new.
    func ignore(_ name: String) { queue.async { self.skip.insert(name) } }

    private func names() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") && $0 != "Icon\r" })
    }

    /// What's there now is known, not new; then watching.
    private func reopen() {
        guard !stopped else { return }
        known = names()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.reopen() }   // not there (yet)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                source.cancel()
                self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.reopen() }
                return
            }
            self.scan()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func scan() {
        let now = names()
        known.formIntersection(now)
        for name in now where !known.contains(name) && waiting[name] == nil {
            waiting[name] = (-1, nil, Date(), 0)
        }
        guard !waiting.isEmpty, ticker == nil else { return }
        let ticker = DispatchSource.makeTimerSource(queue: queue)
        ticker.schedule(deadline: .now() + 1, repeating: 1)
        ticker.setEventHandler { [weak self] in self?.settle() }
        ticker.resume()
        self.ticker = ticker
    }

    private func settle() {
        let fm = FileManager.default
        for (name, var file) in waiting {
            let url = folder.appending(path: name)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
                waiting[name] = nil   // gone again
                continue
            }
            if values.isDirectory == true || Self.partial.contains(url.pathExtension.lowercased()) {
                known.insert(name)
                waiting[name] = nil
                continue
            }
            if Self.partial.contains(where: { fm.fileExists(atPath: url.path + "." + $0) }) {
                file.still = 0
                waiting[name] = file
                continue
            }
            let size = values.fileSize ?? 0
            if size == file.size && values.contentModificationDate == file.date {
                file.still += 1
            } else {
                file.size = size
                file.date = values.contentModificationDate
                file.still = 0
            }
            if file.still >= 2 && (size > 0 || Date().timeIntervalSince(file.seen) > 30) {
                waiting[name] = nil
                known.insert(name)
                if skip.remove(name) == nil { arrived(url) }
            } else {
                waiting[name] = file
            }
        }
        if waiting.isEmpty {
            ticker?.cancel()
            ticker = nil
        }
    }
}

// MARK: - Shortcuts

/// The Shortcuts app's shortcuts, through its own command.
enum Shortcuts {
    /// Runs one, off the main thread. `done` (on the main thread) hears whether it finished within `timeout`
    /// seconds; one still running then is stopped.
    static func run(_ name: String, timeout: Double, done: @escaping @MainActor (Bool) -> Void) {
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
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } }
        }
    }
}

// MARK: - Settings: Routines

struct RoutinesSettings: View {
    @Environment(PetalApp.self) private var app

    var body: some View {
        let _ = BodyCount.hit("RoutinesSettings")
        let routines = app.routines
        Card(title: "Routines", footer: "Ask Petal AI in your own words: “keep my Downloads tidy”, “when a PDF lands in Downloads, file it under Receipts”, “when I open Xcode, hide Messages”. Files are only moved into folders, never deleted, and everything a routine moves can be put back.") {
            SettingToggle(key: "routines", title: "Run my routines", detail: "Petal does them by itself, without asking each time.")
            Button("Make one with Petal AI") { app.claude.open(asking: "Make a routine: ", send: false) }.buttonStyle(.glass)
        }
        if !routines.list.isEmpty {
            Card(title: "Yours") {
                ForEach(routines.list) { routine in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(routine.words).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                            Text(routines.summary(routine)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if routine.usesModes {
                                Text(Routines.Routine.modesGone).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            } else if let last = routine.lastRun {
                                Text("Last ran \(last, format: .relative(presentation: .named))\(routine.lastResult.isEmpty ? "" : ": " + routine.lastResult.prefix(1).lowercased() + routine.lastResult.dropFirst())")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        if !routine.usesModes {
                            Toggle("", isOn: Binding(get: { routine.on }, set: { routines.setOn(routine.id, $0) }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                        }
                        RoundButton(symbol: "xmark") { routines.delete(routine.id) }
                    }
                }
            }
        }
        Card(title: "What they did", footer: "Put back returns a routine's files to where they were.") {
            if routines.log.isEmpty {
                Text("Nothing yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(routines.log.prefix(40)) { entry in
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.text).font(.system(size: 13)).lineLimit(2)
                        Text("\(entry.name.isEmpty ? "" : entry.name + " · ")\(entry.at, format: .relative(presentation: .named))")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if entry.canUndo {
                        Button("Put back") { routines.undo(entry.id) }.buttonStyle(.glass).controlSize(.small)
                    } else if entry.undone {
                        Text("Put back").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
