import CoreGraphics
import Foundation

// Petal Notes' library, its pure side (checked by macos/checks/run.sh, no file or window): what the Petal Notes
// window shows (its views, search, the grid, a notebook's cover), the shared contract's fields read from a note's
// front matter, Private notebooks, notes on people, the canvas's layout file, a notebook's fan in the dock, and what
// dropping a note on an app does there.

// MARK: - The shared contract's fields

/// The front matter keys other phases write and this one reads (back, watch, helper, task, from) and a cover's own
/// (private, view, morning). Phase 1's parser keeps every key it doesn't know in `extra`, exactly as written, so they're
/// read from there and written back there: one line each, never another key's.
extension NoteFile {
    /// A top-level key's lines as written, nil when it isn't there.
    func frontMatter(_ key: String) -> [String]? { extra.first { $0.key == key }?.lines }

    /// A top-level key's value on its own line ("private: true"), as text.
    func scalarValue(_ key: String) -> String? {
        guard let first = frontMatter(key)?.first, let colon = first.firstIndex(of: ":") else { return nil }
        let raw = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : NoteFile.scalar(raw)
    }

    /// A top-level map, written on one line (`watch: { every: 1d, line: "…" }`) or with its fields on lines of their
    /// own one step in. Lists (`history: [a, b]`, or `- a` lines under it) come back as their items.
    func mapValue(_ key: String) -> [String: [String]]? {
        guard let lines = frontMatter(key), let first = lines.first, let colon = first.firstIndex(of: ":") else { return nil }
        let raw = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("{") { return NoteContract.flowMap(raw) }
        var out: [String: [String]] = [:]
        var last: String?
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("- "), let last {
                out[last, default: []].append(NoteFile.scalar(String(trimmed.dropFirst(2))))
                continue
            }
            guard let at = trimmed.firstIndex(of: ":") else { continue }
            let field = String(trimmed[..<at]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: at)...]).trimmingCharacters(in: .whitespaces)
            last = field
            out[field] = value.isEmpty ? [] : value.hasPrefix("[") ? NoteContract.flowList(value) : [NoteFile.scalar(value)]
        }
        return out
    }

    /// Sets (or with nil, removes) a top-level key's one-line value, in its place among the others.
    mutating func setScalar(_ key: String, _ value: String?) {
        let line = value.map { "\(key): \(NoteFile.quoted($0))" }
        if let index = extra.firstIndex(where: { $0.key == key }) {
            if let line { extra[index] = (key: key, lines: [line]) } else { extra.remove(at: index) }
        } else if let line {
            extra.append((key: key, lines: [line]))
        }
    }
}

/// The shared contract's fields, read (phase-common.md): what the window's views list.
enum NoteContract {
    struct Watch: Equatable {
        var every = ""
        var line = ""
        var last = ""
        var history: [String] = []
        var paused = false
    }

    struct Helper: Equatable {
        enum State: String { case working, waiting, done }
        var state: State
        var who = ""
        var step = ""
    }

    /// When the note comes back (`back:`).
    static func back(_ file: NoteFile) -> Date? { file.scalarValue("back").flatMap(NoteFile.date) }

    static func watch(_ file: NoteFile) -> Watch? {
        guard let map = file.mapValue("watch") else { return nil }
        return Watch(every: map["every"]?.first ?? "", line: map["line"]?.first ?? "", last: map["last"]?.first ?? "",
                     history: Array((map["history"] ?? []).prefix(5)), paused: map["paused"]?.first == "true")
    }

    static func helper(_ file: NoteFile) -> Helper? {
        guard let map = file.mapValue("helper"), let state = map["state"]?.first.flatMap(Helper.State.init(rawValue:)) else { return nil }
        return Helper(state: state, who: map["who"]?.first ?? "", step: map["step"]?.first ?? "")
    }

    /// Written by Petal itself (a morning note).
    static func fromPetal(_ file: NoteFile) -> Bool { file.scalarValue("from") == "petal" }

    /// How many things the note holds as a task (`task:` items).
    static func tasks(_ file: NoteFile) -> Int {
        guard let lines = file.frontMatter("task") else { return 0 }
        if let first = lines.first, let colon = first.firstIndex(of: ":") {
            let raw = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("[") { return raw.components(separatedBy: "kind").count - 1 }
        }
        return lines.dropFirst().filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }.count
    }

    /// A Private notebook's cover (`private: true`).
    static func isPrivate(_ cover: NoteFile) -> Bool { cover.scalarValue("private") == "true" }

    /// A notebook's view, on its cover (`view: grid | canvas`): grid unless it says canvas.
    static func view(_ cover: NoteFile) -> NoteLibrary.View { cover.scalarValue("view") == "canvas" ? .canvas : .grid }

    /// `{ a: 1, b: "x, y", c: [p, q] }` as its fields.
    static func flowMap(_ raw: String) -> [String: [String]] {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("{"), text.hasSuffix("}") else { return [:] }
        text = String(text.dropFirst().dropLast())
        var out: [String: [String]] = [:]
        for part in split(text) {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = String(part[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(part[part.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            out[NoteFile.scalar(key)] = value.hasPrefix("[") ? flowList(value) : value.isEmpty ? [] : [NoteFile.scalar(value)]
        }
        return out
    }

    /// `[a, "b, c"]` as its items.
    static func flowList(_ raw: String) -> [String] {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("["), text.hasSuffix("]") else { return [] }
        text = String(text.dropFirst().dropLast())
        return split(text).map { NoteFile.scalar($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    /// Splits at commas outside quotes, brackets and braces.
    private static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quoted = false
        var escaped = false
        for c in text {
            if escaped { escaped = false; current.append(c); continue }
            if c == "\\" && quoted { escaped = true; current.append(c); continue }
            if c == "\"" { quoted.toggle() }
            if !quoted {
                if c == "[" || c == "{" { depth += 1 }
                if c == "]" || c == "}" { depth -= 1 }
                if c == "," && depth == 0 { parts.append(current); current = ""; continue }
            }
            current.append(c)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }
}

// MARK: - The window's views

enum NoteLibrary {
    /// A notebook's two views of the same files.
    enum View: String, Equatable, Sendable { case grid, canvas }

    /// What the sidebar picks: a notebook, or one of the views across them (they're only views).
    enum Shelf: Hashable, Sendable {
        case notebook(String)
        case comingBack, watching, helpers
    }

    /// A note as the window weighs it.
    struct Item: Equatable {
        var notebook: String
        var file: NoteFile
    }

    /// The notes a shelf lists, in its order (indices into `items`). A notebook: its notes, the cover left out
    /// (it's shown on its own), newest first, the faded ones after. Coming back: what comes back from now on,
    /// soonest first. Watching: every watcher. Helpers at work: working or waiting for the person.
    static func listed(_ shelf: Shelf, _ items: [Item], now: Date) -> [Int] {
        let all = items.indices
        switch shelf {
        case .notebook(let name):
            return all.filter { !items[$0].file.cover && same(items[$0].notebook, name) }
                .sorted { items[$0].file.modified > items[$1].file.modified }
        case .comingBack:
            return all.compactMap { i in NoteContract.back(items[i].file).flatMap { $0 >= now ? (i, $0) : nil } }
                .sorted { $0.1 < $1.1 }.map(\.0)
        case .watching:
            return all.filter { NoteContract.watch(items[$0].file) != nil }.sorted { items[$0].file.modified > items[$1].file.modified }
        case .helpers:
            return all.filter { NoteContract.helper(items[$0].file).map { $0.state != .done } ?? false }
                .sorted { items[$0].file.modified > items[$1].file.modified }
        }
    }

    /// The person's own search: every note's words, its title and notebook, plain (this is the person's view; what
    /// reaches a tool is searched only on redacted text, NoteShield.search).
    static func search(_ query: String, _ items: [Item]) -> [Int] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return [] }
        return items.indices.filter { NoteText.matches(words, items[$0].file.body + "\n" + items[$0].notebook) }
            .sorted { items[$0].file.modified > items[$1].file.modified }
    }

    /// Notebook names are one notebook whatever their case (as NoteShelf.canonicalNotebook has them).
    static func same(_ a: String, _ b: String) -> Bool { a.compare(b, options: .caseInsensitive) == .orderedSame }

    // MARK: The grid

    /// The grid's cells: `columns` across, the cover (when there is one) first, two rows tall, in the first column.
    /// Each note's (column, row), in order.
    static func gridSlots(count: Int, columns: Int, cover: Bool) -> [(column: Int, row: Int)] {
        let columns = max(cover ? 2 : 1, columns)
        var slots: [(column: Int, row: Int)] = []
        var cell = 0
        while slots.count < count {
            let row = cell / columns, column = cell % columns
            cell += 1
            if cover && column == 0 && row < 2 { continue }
            slots.append((column, row))
        }
        return slots
    }

    /// How many rows the grid takes.
    static func gridRows(count: Int, columns: Int, cover: Bool) -> Int {
        let rows = (gridSlots(count: count, columns: columns, cover: cover).map(\.row).max() ?? -1) + 1
        return cover ? max(2, rows) : rows
    }

    /// Columns of `cell` points with `gap` between them in `width`.
    static func columns(width: CGFloat, cell: CGFloat, gap: CGFloat) -> Int { max(1, Int((width + gap) / (cell + gap))) }

    /// A cover's two parts: what the notebook is for (its words, its "About this notebook" heading left out), and
    /// what Petal remembers there: the items under a "Petal remembers" heading (Phase 2 writes them; the person edits
    /// them like any note).
    static func cover(_ body: String) -> (about: String, remembers: [String]) {
        var about: [String] = []
        var remembers: [String] = []
        var inMemory = false
        for line in body.components(separatedBy: "\n") {
            let block = NoteBlock.parse(line)
            if case .heading(_, let text) = block {
                let title = text.trimmingCharacters(in: .whitespaces)
                inMemory = title.compare("Petal remembers", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                if inMemory || title.compare("About this notebook", options: .caseInsensitive) == .orderedSame { continue }
            }
            let words = block.words.trimmingCharacters(in: .whitespaces)
            if inMemory { if !words.isEmpty { remembers.append(words) } } else { about.append(words) }
        }
        return (about.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), remembers)
    }

    /// The one line a note in the grid says under its words: what's coming (it comes back; a helper's step), else
    /// where it's stuck (`place`: the letterhead's words for its first place), else that it's on no place.
    struct Footer: Equatable {
        var text: String
        var dot = false
        var working = false
    }

    static func footer(_ file: NoteFile, place: String?, now: Date) -> Footer {
        if let helper = NoteContract.helper(file), helper.state != .done {
            let who = helper.who.isEmpty ? "A helper" : helper.who
            return Footer(text: helper.state == .waiting ? "\(who) needs you" : helper.step.isEmpty ? "\(who) is at work" : helper.step,
                          dot: true, working: helper.state == .working)
        }
        if let back = NoteContract.back(file), back >= now { return Footer(text: "Back " + backWords(back, now: now), dot: true) }
        if let watch = NoteContract.watch(file) { return Footer(text: watch.paused ? "Watching · paused" : watch.every.isEmpty ? "Watching" : "Watching · every \(watch.every)") }
        if let place, !place.isEmpty { return Footer(text: place) }
        return Footer(text: "Not stuck anywhere")
    }

    /// "Friday 9:00", "today 15:30", "12 Dec 9:00".
    static func backWords(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = calendar.timeZone
        format.dateFormat = "H:mm"
        let time = format.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow \(time)" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day, days < 7 {
            format.dateFormat = "EEEE"
            return format.string(from: date) + " " + time
        }
        format.dateFormat = "d MMM"
        return format.string(from: date) + " " + time
    }

    /// Where a notebook's files live, in the person's words: "iCloud Drive › Petal Notes › Tokyo trip".
    static func whereWords(root: String, notebook: String, home: String) -> String {
        let drive = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        var parts: [String]
        if root.hasPrefix(drive + "/") {
            parts = ["iCloud Drive"] + root.dropFirst(drive.count + 1).split(separator: "/").map(String.init)
        } else if root.hasPrefix(home + "/Library/Application Support/") {
            parts = ["On this Mac", "Petal"] + [(root as NSString).lastPathComponent]
        } else if root.hasPrefix(home + "/") {
            parts = ["Home"] + root.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        } else {
            parts = root.split(separator: "/").map(String.init)
        }
        return (parts + [notebook]).joined(separator: " › ")
    }
}

// MARK: - Private notebooks

/// A Private notebook (`private: true` on its cover) stays out of pictures, the AI button's previews and every other
/// notebook's memory; tools read its notes only when asked from inside it (an @ in one of its notes).
enum NotePrivacy {
    /// Whether a tool or a helper asking from `asker` (the notebook of the note it's in; nil: from no note) may read
    /// a note in `notebook`.
    static func readable(notebook: String, privateBooks: Set<String>, asker: String?) -> Bool {
        guard privateBooks.contains(where: { NoteLibrary.same($0, notebook) }) else { return true }
        guard let asker else { return false }
        return NoteLibrary.same(asker, notebook)
    }
}

// MARK: - Notes on people

/// A person, worked out from the conversation in front: the chat's header or recipient in Messages, WhatsApp,
/// Telegram, Slack and Mail, read through Accessibility (never from an app kept private). Exactly one person or none:
/// two candidates that disagree are never guessed between.
enum PersonRead {
    /// The chat apps Petal reads a person from.
    static let apps: [String: String] = [
        "com.apple.MobileSMS": "Messages",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "desktop.WhatsApp": "WhatsApp",
        "ru.keepcoder.Telegram": "Telegram",
        "org.telegram.desktop": "Telegram",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.mail": "Mail",
    ]

    static func isChat(_ bundle: String) -> Bool { apps[bundle] != nil }

    /// Words that name a place in a chat app, never a person.
    private static let places: Set<String> = [
        "messages", "message", "chats", "chat", "inbox", "whatsapp", "telegram", "slack", "mail", "search", "archived", "new message",
        "new chat", "threads", "activity", "home", "dms", "direct messages", "later", "unread", "all mail", "sent", "drafts", "contacts",
        "settings", "calls", "status", "communities", "updates", "channels", "favourites", "favorites", "saved messages", "files",
        "flagged", "junk", "trash", "archive", "vip", "conversation", "conversations", "to", "from", "cc", "subject", "no conversation selected",
    ]

    /// A name as Petal keeps it: trimmed, an unread count or "To:" taken off; nil for a place, a channel, a group of
    /// several, or anything too long to be a name.
    static func name(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: "\u{200E}", with: "").replacingOccurrences(of: "\u{200F}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["To:", "From:"] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        if let open = text.range(of: #"\s*\(\d+\)$"#, options: .regularExpression) { text.removeSubrange(open) }
        text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty, text.count <= 60, !places.contains(text.lowercased()), !text.hasPrefix("#"),
              !text.contains(","), !text.contains(" & "), !text.contains("\n") else { return nil }
        return text
    }

    /// The person in the conversation in front, or nil. `title`: the window's title; `headings`: the conversation's
    /// header (Accessibility headings and the toolbar's title), in order.
    static func person(app bundle: String, appName: String, title: String, headings: [String]) -> String? {
        guard let kind = apps[bundle] else { return nil }
        var found: [String] = []
        switch kind {
        case "Slack":
            // Slack says the conversation in its title: "Name (DM) - Workspace - Slack"; a channel or a group is no person.
            guard let match = title.range(of: #"^(.+?) \(DM\)"#, options: .regularExpression) else { return nil }
            found = [String(title[match].dropLast(5))]
        case "Mail":
            found = headings
        default:
            found = [title] + headings
        }
        let names = found.compactMap(name).filter { $0.compare(appName, options: .caseInsensitive) != .orderedSame }
        var distinct: [String] = []
        for n in names where !distinct.contains(where: { same($0, n) }) { distinct.append(n) }
        return distinct.count == 1 ? distinct[0] : nil
    }

    /// One person by name, however it's spelled (case, accents, spaces).
    static func same(_ a: String, _ b: String) -> Bool {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
        let x = fold(a), y = fold(b)
        return !x.isEmpty && x == y
    }

    /// The vault contact a person is, when exactly one contact has their name (never a guess between two).
    static func contact(_ person: String, contacts: [(id: String, name: String)]) -> String? {
        let hits = contacts.filter { same($0.name, person) }
        return hits.count == 1 ? hits[0].id : nil
    }
}

// MARK: - Canvas

/// A notebook's canvas (`view: canvas` on its cover): the same notes laid out freely, labeled areas around them,
/// arrows between them and words written on it. Kept in the notebook's `.canvas.json`, synced like its notes, and
/// changed only as an edit applied to the file as it is right then (a based write: NoteCanvasFile), so two Macs
/// moving different notes both keep their moves.
struct NoteCanvas: Codable, Equatable, Sendable {
    struct Spot: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
    }

    struct Area: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var label: String
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }

    struct Arrow: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var from: String
        var to: String
        var dashed = false
    }

    struct Words: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var text: String
        var x: Double
        var y: Double
    }

    var version = 1
    /// Each note's spot, by its id (only a note with an id of its own in its file: NoteShelf.lasting).
    var notes: [String: Spot] = [:]
    var areas: [Area] = []
    var arrows: [Arrow] = []
    var texts: [Words] = []
    var zoom: Double = 1

    enum Edit: Equatable, Sendable {
        case move(String, Spot)
        case area(Area)
        case removeArea(String)
        case arrow(Arrow)
        case removeArrow(String)
        case words(Words)
        case removeWords(String)
        case zoom(Double)
    }

    /// The canvas with one edit made on it: an area, arrow or words by their id (added or replaced).
    func applying(_ edit: Edit) -> NoteCanvas {
        var next = self
        switch edit {
        case .move(let id, let spot): next.notes[id] = spot
        case .area(let area):
            if let at = next.areas.firstIndex(where: { $0.id == area.id }) { next.areas[at] = area } else { next.areas.append(area) }
        case .removeArea(let id): next.areas.removeAll { $0.id == id }
        case .arrow(let arrow):
            guard arrow.from != arrow.to else { return next }
            if let at = next.arrows.firstIndex(where: { $0.id == arrow.id }) { next.arrows[at] = arrow } else { next.arrows.append(arrow) }
        case .removeArrow(let id): next.arrows.removeAll { $0.id == id }
        case .words(let words):
            if let at = next.texts.firstIndex(where: { $0.id == words.id }) { next.texts[at] = words } else { next.texts.append(words) }
        case .removeWords(let id): next.texts.removeAll { $0.id == id }
        case .zoom(let zoom): next.zoom = Self.clampZoom(zoom)
        }
        return next
    }

    /// The file's text: nil (no file yet) is an empty canvas; a file Petal can't read as a canvas is nil, and is
    /// never written over.
    static func decode(_ text: String?) -> NoteCanvas? {
        guard let text else { return NoteCanvas() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return NoteCanvas() }
        return try? JSONDecoder().decode(NoteCanvas.self, from: Data(text.utf8))
    }

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) + "\n" } ?? "{}\n"
    }

    init() {}

    /// Unknown keys are left out and missing ones take their defaults: a later Petal's file still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        notes = (try? c.decode([String: Spot].self, forKey: .notes)) ?? [:]
        areas = (try? c.decode([Area].self, forKey: .areas)) ?? []
        arrows = (try? c.decode([Arrow].self, forKey: .arrows)) ?? []
        texts = (try? c.decode([Words].self, forKey: .texts)) ?? []
        zoom = Self.clampZoom((try? c.decode(Double.self, forKey: .zoom)) ?? 1)
    }

    /// What a based write puts in the file now on disk (`disk`, nil when there's none): the edit made on it as it
    /// is, so moves made elsewhere meanwhile stay. Nil when the file isn't a canvas Petal can read (kept as it is).
    static func write(_ edit: Edit, disk: String?) -> String? {
        guard let canvas = decode(disk) else { return nil }
        let next = canvas.applying(edit)
        return next == canvas && disk != nil ? disk : next.encoded()
    }

    static let zoomSteps: [Double] = [0.5, 0.67, 0.8, 1, 1.25, 1.5, 2]
    static func clampZoom(_ zoom: Double) -> Double { min(2, max(0.5, zoom.isFinite ? zoom : 1)) }
    static func zoomIn(_ zoom: Double) -> Double { zoomSteps.first { $0 > zoom + 0.001 } ?? zoomSteps.last! }
    static func zoomOut(_ zoom: Double) -> Double { zoomSteps.last { $0 < zoom - 0.001 } ?? zoomSteps.first! }

    static let cell: Double = 150
    static let gap: Double = 40
    static let origin = Spot(x: 60, y: 60)

    /// Where each note sits: its saved spot, else a free place in rows below everything else on the canvas (not
    /// written until the person moves it). `columns`: how many fit across.
    func spots(for ids: [String], columns: Int) -> [String: Spot] {
        var out: [String: Spot] = [:]
        var bottom = Self.origin.y
        for id in ids { if let spot = notes[id] { out[id] = spot; bottom = max(bottom, spot.y + Self.cell + Self.gap) } }
        for area in areas { bottom = max(bottom, area.y + area.h + Self.gap) }
        for words in texts { bottom = max(bottom, words.y + 40) }
        let fresh = ids.filter { notes[$0] == nil }
        let across = max(1, columns)
        for (n, id) in fresh.enumerated() {
            out[id] = Spot(x: Self.origin.x + Double(n % across) * (Self.cell + Self.gap),
                           y: bottom + Double(n / across) * (Self.cell + Self.gap))
        }
        return out
    }

    /// The notes inside an area (their middle in it), for moving them with it.
    func inside(_ area: Area, spots: [String: Spot]) -> [String] {
        spots.filter { _, spot in
            let mx = spot.x + Self.cell / 2, my = spot.y + Self.cell / 2
            return mx >= area.x && mx <= area.x + area.w && my >= area.y && my <= area.y + area.h
        }.map(\.key).sorted()
    }
}

// MARK: - A notebook in the dock

/// A notebook's stack fanned up from its dock icon: up to `limit` papers, newest at the bottom, rising in a gentle
/// curve away from the dock, each turned a little.
enum NoteFan {
    static let limit = 8
    static let paper: CGFloat = 112

    /// Each paper's offset from the fan's bottom centre (y up), and its turn in degrees (leaning with the curve).
    static func spots(count: Int) -> [(x: CGFloat, y: CGFloat, angle: Double)] {
        (0..<min(count, limit)).map { n in
            let t = CGFloat(n)
            return (x: t * t * 2.4, y: t * (paper * 0.62), angle: Double(t) * 2.2)
        }
    }

    /// The fan's width: the bottom paper centred over the stack, the rest leaning right from it.
    static func width(count: Int) -> CGFloat { paper + 2 * (spots(count: count).last?.x ?? 0) + 24 }
}

// MARK: - Dropping a note on an app

/// What dropping a note on an app in the dock does there. Nothing is ever sent: Mail gets a new message left as a
/// draft, Calendar a new event (asked first), every other app the note's text on the clipboard, said so.
enum NoteDrop {
    enum Action: Equatable { case mail, calendar, clipboard }

    static func action(_ bundle: String) -> Action {
        switch bundle {
        case "com.apple.mail": .mail
        case "com.apple.iCal": .calendar
        default: .clipboard
        }
    }

    /// A note's text for another app: its words as a person reads them (headings without their marks, checkboxes as
    /// ☐ and ☑, cards as their addresses), its pictures left out (they go along as files, where they can).
    static func plain(_ body: String) -> String {
        NoteBlock.blocks(body).compactMap { block -> String? in
            switch block {
            case .heading(_, let text): return text
            case .check(let done, let text): return (done ? "☑ " : "☐ ") + text
            case .bullet(let text): return "• " + text
            case .link(let url): return url
            case .image: return nil
            case .ink(let text): return text
            case .text(let text): return text
            }
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An event from a note: its title, and the first date-time its words name from now on (an hour long), else
    /// tomorrow at 9:00. `found`: the dates the text names, in order (NSDataDetector's, with their durations).
    struct Event: Equatable {
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        /// The text named no time: Petal picked one, and the card says so.
        var guessed: Bool
    }

    static func event(title: String, found: [(date: Date, duration: TimeInterval, allDay: Bool)], now: Date, calendar: Calendar = .current) -> Event {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "From a note" : title
        if let hit = found.first(where: { $0.date >= now.addingTimeInterval(-3600) }) {
            let length = hit.duration > 0 ? hit.duration : hit.allDay ? 86400 : 3600
            return Event(title: name, start: hit.date, end: hit.date.addingTimeInterval(length), allDay: hit.allDay, guessed: false)
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        return Event(title: name, start: start, end: start.addingTimeInterval(3600), allDay: false, guessed: true)
    }

    /// The dates a text names (NSDataDetector, no network).
    static func dates(in text: String) -> [(date: Date, duration: TimeInterval, allDay: Bool)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let date = match.date else { return nil }
            let words = (text as NSString).substring(with: match.range)
            let hasTime = words.range(of: #"\d[:.]\d|\d\s?(am|pm)|noon|midnight"#, options: [.regularExpression, .caseInsensitive]) != nil
            return (date, match.duration, !hasTime)
        }
    }
}
