import AppKit
import Observation
import SQLite3
import SwiftUI

/// A notification macOS delivered, as Notification Center's database keeps it.
struct HeldNote: Identifiable, Equatable {
    let id: Int64
    /// The app's bundle id, as macOS records it (lowercased).
    let app: String
    var title: String
    var subtitle: String
    var body: String
    let date: Date
    /// Where the notification itself leads, when it says (a link or the app's own address).
    var target: String?
    /// The mode it waits on.
    var mode = ""
    var urgent = false
    var reason = ""
}

/// Notification Center's database (~/Library/Group Containers/group.com.apple.usernoted/db2/db), read-only. macOS lets
/// Petal read it once it has Full Disk Access. `record.data` is a binary plist with the title, subtitle and body
/// under `req`, and what the app attached (`usda`, a keyed archive) may hold where it leads.
enum NoteRecords {
    static let path = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"

    /// Whether Petal can read it (Full Disk Access).
    static func readable() -> Bool { query("SELECT max(rec_id) FROM record") { _ in } }

    /// The newest record's number, to start from.
    static func latest() -> Int64? {
        var latest: Int64?
        _ = query("SELECT max(rec_id) FROM record") { latest = sqlite3_column_int64($0, 0) }
        return latest
    }

    /// Every record newer than `after`, oldest first.
    static func records(after: Int64) -> [HeldNote] {
        var notes: [HeldNote] = []
        _ = query("SELECT r.rec_id, a.identifier, r.data FROM record r JOIN app a ON a.app_id = r.app_id WHERE r.rec_id > \(after) ORDER BY r.rec_id LIMIT 200") { row in
            let id = sqlite3_column_int64(row, 0)
            let app = sqlite3_column_text(row, 1).map { String(cString: $0) } ?? ""
            guard let bytes = sqlite3_column_blob(row, 2) else { return }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, 2)))
            if let note = parse(id: id, app: app, data: data) { notes.append(note) }
        }
        return notes
    }

    /// One record's plist: {app, date, req: {titl, subt, body, usda, …}}. The date counts from 2001, as Core Data does.
    static func parse(id: Int64, app: String, data: Data) -> HeldNote? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let request = root["req"] as? [String: Any] else { return nil }
        let title = request["titl"] as? String ?? ""
        let body = request["body"] as? String ?? ""
        guard !title.isEmpty || !body.isEmpty else { return nil }
        let seconds = (root["date"] as? NSNumber)?.doubleValue
        return HeldNote(id: id, app: (root["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? app, title: title,
                        subtitle: request["subt"] as? String ?? "", body: body,
                        date: seconds.map { Date(timeIntervalSinceReferenceDate: $0) } ?? Date(),
                        target: (request["usda"] as? Data).flatMap(target))
    }

    /// The first address in what the app attached: a web link, or the app's own (slack://…).
    static func target(_ archive: Data) -> String? {
        guard let root = try? PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any],
              let objects = root["$objects"] as? [Any] else { return nil }
        for case let text as String in objects {
            guard text.count < 2000, let colon = text.range(of: "://"), colon.lowerBound > text.startIndex,
                  let url = URL(string: text), let scheme = url.scheme, !scheme.hasPrefix("x-apple"), scheme != "file" else { continue }
            return text
        }
        return nil
    }

    /// Runs one statement on a fresh read-only connection; false when the database can't be opened or read.
    private static func query(_ sql: String, row: (OpaquePointer) -> Void) -> Bool {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return false }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { row(statement); continue }
            return step == SQLITE_DONE
        }
    }
}

/// Held notifications (`holdNotifications`, a mode's `hold`): in a mode that holds them, notifications from apps
/// outside it (and not in its allow list) don't show. macOS's banners are kept away with Do Not Disturb (Quiet), each
/// one Notification Center records waits on the mode it belongs to (its apps, else the AI), with a count on that
/// mode's button, and Petal shows the mode's own apps' notifications itself, in a small banner above the dock. One
/// that can't wait (the AI decides, with `urgentNotifications`) pops out of its mode's button as a card.
@MainActor @Observable
final class Notes {
    private(set) var all: [HeldNote] = []
    private(set) var canRead = false
    @ObservationIgnored let quiet = Quiet()
    @ObservationIgnored let banners = Banners()
    @ObservationIgnored private var last: Int64 = -1
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var sources: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var soon: DispatchWorkItem?
    @ObservationIgnored private var shownMode: String?
    @ObservationIgnored private var lastAccessCheck = Date.distantPast

    var app: PetalApp { PetalApp.shared }
    var config: Config { app.config }

    func held(in mode: String) -> [HeldNote] { all.filter { $0.mode == mode } }

    func start() {
        Quiet.recover()
        quiet.refresh()
        canRead = NoteRecords.readable()
        last = NoteRecords.latest() ?? -1
        watch()
        // A 2-second look as well, for when the files' own notices don't come.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        update()
    }

    func stop() {
        quiet.set(false, wait: true)
    }

    // MARK: Holding

    /// Whether the mode in front holds notifications now.
    var holding: Bool {
        guard config.bool("holdNotifications"), config.bool("modes"), app.docks.shown, let mode = currentMode else { return false }
        return mode.hold && status.works
    }

    var currentMode: Mode? { app.docks.focusedDock?.mode }

    struct Status {
        let wanted: Bool
        let canRead: Bool
        let way: Quiet.Way?

        var works: Bool { canRead && way != nil }

        /// What's missing, in plain words; empty when holding works.
        var why: String {
            if !canRead { return "Petal can't see notifications yet: give it Full Disk Access in System Settings." }
            if way == nil { return "Petal can't keep macOS's banners away: add the Petal Do Not Disturb shortcut, or allow Accessibility." }
            return ""
        }

        var json: String {
            let object: [String: Any] = ["wanted": wanted, "canRead": canRead, "way": way?.rawValue ?? "", "works": works, "why": why]
            return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
    }

    var status: Status {
        Status(wanted: config.bool("holdNotifications") && config.modes.contains(where: \.hold), canRead: canRead, way: quiet.way)
    }

    /// Follows the mode in front and the settings: Do Not Disturb on while the mode holds, off when it doesn't.
    /// Entering a mode shows what was held for it.
    func update() {
        quiet.set(holding)
        let mode = currentMode?.id
        guard mode != shownMode else { return }
        shownMode = mode
        guard let mode, let current = currentMode else { return }
        let waiting = held(in: mode)
        guard !waiting.isEmpty else { return }
        all.removeAll { $0.mode == mode }
        banners.show(held: waiting, for: current)
    }

    private func tick() {
        if Date().timeIntervalSince(lastAccessCheck) > 10 || !canRead {
            lastAccessCheck = Date()
            let now = NoteRecords.readable()
            if now != canRead {
                canRead = now
                if now { last = NoteRecords.latest() ?? -1; watch() }
            }
        }
        if sources.isEmpty && canRead { watch() }
        read()
        update()
    }

    /// The database's files change when a notification arrives: look then, a moment later.
    private func watch() {
        for source in sources { source.cancel() }
        sources = []
        guard canRead else { return }
        for file in [NoteRecords.path + "-wal", NoteRecords.path] {
            let fd = Darwin.open(file, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let source, !source.data.isDisjoint(with: [.delete, .rename]) {
                        source.cancel()
                        self.sources.removeAll { $0 === source }
                    }
                    self.soon?.cancel()
                    let work = DispatchWorkItem { [weak self] in self?.read() }
                    self.soon = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    private func read() {
        guard canRead else { return }
        if last < 0 { last = NoteRecords.latest() ?? -1; return }
        let fresh = NoteRecords.records(after: last)
        guard let newest = fresh.last?.id else { return }
        last = newest
        for note in fresh where Date().timeIntervalSince(note.date) < 120 { arrived(note) }
    }

    /// A new notification: shown by Petal if it belongs here, else held on its mode.
    private func arrived(_ incoming: HeldNote) {
        guard holding, let mode = currentMode else { return }   // not holding: macOS shows it as usual
        var note = incoming
        let id = Self.appID(note.app)
        if id == Bundle.main.bundleIdentifier { return }
        if Self.belongs(id, to: mode) { return banners.show(note) }
        note.mode = config.modes.first { $0.id != mode.id && Self.belongs(id, to: $0) }?.id ?? ""
        let brain = app.focus.brain
        guard brain.enabled else {
            hold(note, fallback: mode)
            return
        }
        brain.classifyNotification(app: Apps.name(id), title: [note.title, note.subtitle].filter { !$0.isEmpty }.joined(separator: " · "),
                                   body: note.body) { [weak self] answer in
            guard let self else { return }
            if note.mode.isEmpty, let chosen = answer?["mode"] as? String, self.config.modes.contains(where: { $0.id == chosen }) {
                // The AI says it belongs to the mode you're in: it's fine here.
                if chosen == self.currentMode?.id { return self.banners.show(note) }
                note.mode = chosen
            }
            note.urgent = answer?["urgent"] as? Bool ?? false
            note.reason = (answer?["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.hold(note, fallback: mode)
        }
    }

    /// Waits on its mode (with no mode of its own, the one you're in, where its right-click menu lists it). One that
    /// can't wait pops out of its mode's button.
    private func hold(_ incoming: HeldNote, fallback: Mode) {
        var note = incoming
        if note.mode.isEmpty { note.mode = fallback.id }
        all.append(note)
        if all.count > 200 { all.removeFirst(all.count - 200) }
        guard note.urgent, config.bool("urgentNotifications"), app.pendingMode?.mode != note.mode,
              let target = config.modes.first(where: { $0.id == note.mode }) else { return }
        app.popups.show(FocusCard(kind: .note, bundleID: Self.appID(note.app), title: note.title, target: target,
                                  here: currentMode, reason: note.reason, desktop: app.docks.focusedDock?.desktop, note: note))
    }

    // MARK: Opening

    /// Clicking a held notification: to its mode (with the wait, for a distracting one), then its app in front, at
    /// the notification's own target when it has one.
    func open(_ note: HeldNote) {
        all.removeAll { $0.id == note.id }
        if app.popups.card?.note?.id == note.id { app.popups.dismissCard() }
        let reveal = { Self.reveal(note) }
        guard let desktop = app.docks.focusedDock?.desktop, !note.mode.isEmpty else { return reveal() }
        app.requestMode(note.mode, desktop: desktop, then: reveal)
    }

    /// Later: it stays held.
    func later(_ card: FocusCard) {
        app.popups.dismissCard()
    }

    func clear(_ mode: String) { all.removeAll { $0.mode == mode } }

    /// For snapshots: a held notification, as if it had arrived.
    func preview(_ note: HeldNote) { all.append(note) }

    /// The notification's app in front, and the notification's own target opened when it has one.
    static func reveal(_ note: HeldNote) {
        let id = appID(note.app)
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            Windows.bringForward(running)
        } else if let url = Apps.url(id) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        if let target = note.target, let url = URL(string: target), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: Apps

    /// Notification Center keeps bundle ids lowercased; the app's own spelling, from the modes, what's running or
    /// what's installed.
    static func appID(_ recorded: String) -> String {
        let app = PetalApp.shared
        let same = { (id: String) in id.caseInsensitiveCompare(recorded) == .orderedSame }
        if let id = app.config.modes.flatMap({ $0.apps + $0.allow }).first(where: same) { return id }
        if let id = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).first(where: same) { return id }
        if let id = Apps.installed().map(\.id).first(where: same) { return id }
        return recorded
    }

    static func belongs(_ id: String, to mode: Mode) -> Bool {
        (mode.apps + mode.allow).contains { $0.caseInsensitiveCompare(id) == .orderedSame }
    }
}

// MARK: - Petal's own banner

/// While macOS's banners are kept away, Petal shows the mode's own apps' notifications itself: a small glass banner
/// above the dock that goes after a few seconds. Clicking it opens the app. Entering a mode shows what was held for it.
@MainActor
final class Banners {
    private let panel = GlassPanel(level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2))
    private var hide: DispatchWorkItem?

    func show(_ note: HeldNote) {
        present(BannerView(notes: [note], heading: nil, color: nil) { [weak self] in
            self?.close()
            Notes.reveal(note)
        }, seconds: 6)
    }

    func show(held notes: [HeldNote], for mode: Mode) {
        let heading = notes.count == 1 ? "1 notification held for \(mode.name)" : "\(notes.count) notifications held for \(mode.name)"
        present(BannerView(notes: Array(notes.suffix(3).reversed()), heading: heading, color: mode.color, open: { [weak self] in
            self?.close()
        }, openNote: { [weak self] note in
            self?.close()
            Notes.reveal(note)
        }), seconds: 8)
    }

    func sample() {
        let installed = Apps.installed().map(\.id)
        let id = ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "com.apple.mail"].first(where: installed.contains) ?? installed.first ?? ""
        show(HeldNote(id: 0, app: id, title: "Maya Chen", subtitle: "#launch", body: "The checklist is ready for you.", date: Date()))
    }

    private func present<Content: View>(_ view: Content, seconds: Double) {
        guard let dock = PetalApp.shared.docks.focusedDock?.panel else { return }
        hide?.cancel()
        let frame = dock.frame
        // Above the dock's middle, clear of a card that points at a mode button.
        GlassPanel.opaque(panel)
        panel.show(view, over: CGRect(x: frame.midX - 1, y: frame.minY, width: 2, height: frame.height), dock: dock)
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { self.close() } })
    }

    func close() {
        hide?.cancel()
        panel.hide()
        GlassPanel.opaque(panel)
    }
}

struct BannerView: View {
    let notes: [HeldNote]
    let heading: String?
    let color: NSColor?
    var open: () -> Void
    var openNote: ((HeldNote) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let heading {
                Text(heading).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(nsColor: color ?? PetalApp.shared.accent))
            }
            ForEach(notes) { note in
                NoteRow(note: note, lines: heading == nil ? 2 : 1)
                    .contentShape(.rect)
                    .onTapGesture { (openNote ?? { _ in open() })(note) }
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .contentShape(.rect)
        .onTapGesture { open() }
        .padding(6)
    }
}

/// A notification: its app's icon, who or what it's from, and its text.
struct NoteRow: View {
    let note: HeldNote
    var lines = 2

    var body: some View {
        let id = Notes.appID(note.app)
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: Apps.icon(id)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(([note.title, note.subtitle].filter { !$0.isEmpty }).joined(separator: " · "))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !note.body.isEmpty {
                    Text(note.body).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(lines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
