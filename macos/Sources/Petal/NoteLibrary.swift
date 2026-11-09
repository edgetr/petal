import CoreGraphics
import Foundation
import UniformTypeIdentifiers

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
    static func tasks(_ file: NoteFile) -> Int { taskItems(file).count }

    /// One thing a note holds as a task: a tab, a file, a window or a mail, its title, and its address or path.
    struct TaskItem: Equatable, Sendable {
        var kind: String
        var title: String
        var target: String
    }

    /// The note's `task:` items, written on one line (`task: [ { kind: tab, title: …, url_or_path: … } ]`) or as a
    /// list with each item's fields on lines of their own.
    static func taskItems(_ file: NoteFile) -> [TaskItem] {
        guard let lines = file.frontMatter("task"), let first = lines.first, let colon = first.firstIndex(of: ":") else { return [] }
        let raw = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        var maps: [[String: String]] = []
        if raw.hasPrefix("[") {
            maps = flowList(raw).map { item in flowMap(item).compactMapValues(\.first) }
        } else {
            for line in lines.dropFirst() {
                var text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("- ") { maps.append([:]); text = String(text.dropFirst(2)) }
                guard !maps.isEmpty, let at = text.firstIndex(of: ":") else { continue }
                let key = String(text[..<at]).trimmingCharacters(in: .whitespaces)
                maps[maps.count - 1][key] = NoteFile.scalar(String(text[text.index(after: at)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return maps.compactMap { map in
            guard let kind = map["kind"], !kind.isEmpty else { return nil }
            return TaskItem(kind: kind, title: map["title"] ?? "", target: map["url_or_path"] ?? map["url"] ?? map["path"] ?? "")
        }
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

extension NoteLibrary {
    /// A notebook's cover, by its file's name only: "About this notebook.md", its iCloud versions (the same name) and
    /// its conflict copies (any name starting "About this notebook" and ending ".md"). `cover: true` in any other note
    /// counts for nothing: not its privacy, color or view.
    static func isCoverName(_ fileName: String) -> Bool {
        let name = fileName.lowercased()
        return name.hasPrefix("about this notebook") && name.hasSuffix(".md")
    }

    static func isCover(fileName: String, file: NoteFile) -> Bool { isCoverName(fileName) }

    /// A note that isn't cover-named but says `cover: true` and `private: true`: a sign a cover lost its name (a copy
    /// named from its heading, a rename). Its notebook's privacy is unknown, so Private, until the person resolves it.
    static func strayPrivateCover(fileName: String, file: NoteFile) -> Bool {
        file.cover && !isCoverName(fileName) && NoteContract.isPrivate(file)
    }

    /// A note as read: a cover by its name only. Another note's own `cover: true` is kept as written (as a key this
    /// Petal doesn't use), never taken for a cover.
    static func coverFlag(_ file: inout NoteFile, fileName: String) {
        let named = isCoverName(fileName)
        if file.cover && !named { file.extra.append((key: "cover", lines: ["cover: true"])) }
        file.cover = named
    }

    /// Whether a notebook's cover is unknown: its file is there and wasn't read (not downloaded, unreadable), or a
    /// version of it wasn't. Unknown counts as Private.
    static func coverUnknown(fileThere: Bool, fileRead: Bool, versionsUnread: Bool) -> Bool { (fileThere && !fileRead) || versionsUnread }

    /// Whether a notebook's privacy is unknown (so Private): its folder couldn't be listed, or one of its cover files
    /// (`isCoverName`: the cover, a version or a conflict copy of it) wasn't read (dataless, unreadable, its details
    /// not read). Other notes still downloading don't count. Public only once every cover file was read and none says
    /// Private.
    static func notebookUnknown(listed: Bool, unreadCovers: Int) -> Bool { !listed || unreadCovers > 0 }

    /// Whether a notebook is Private, counted across every version of its cover: Private when any says so, or while
    /// its cover is there and not read yet (unknown).
    static func privateNotebook(covers: [NoteFile], unread: Bool) -> Bool { unread || covers.contains(where: NoteContract.isPrivate) }
}

/// A Private notebook (`private: true` on its cover) stays out of Petal's own pictures, the AI button's previews and every other
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

extension NotePrivacy {
    /// One of Petal's own windows, as Petal's pictures weigh it: its window number, and whether it shows a Private
    /// notebook's note (a paper, an edge tab, a notebook's fan, the Petal Notes window on a Private notebook).
    struct Surface: Equatable {
        var window: Int
        var showsPrivate: Bool
    }

    /// The windows every picture Petal takes leaves out (petal_look's, the AI button's previews, any SCContentFilter
    /// Petal builds): all those showing a Private notebook's note.
    static func excludedWindows(_ surfaces: [Surface]) -> Set<Int> { Set(surfaces.filter(\.showsPrivate).map(\.window)) }

    /// Whether a picture of one window may be taken: never of one left out (then there's no picture at all).
    static func mayCapture(window: Int, excluded: Set<Int>) -> Bool { !excluded.contains(window) }

    /// The notebooks counted Private: those whose cover says so (or is unknown), and any notebook a note is held in
    /// that the latest read of the folder didn't find (gone, renamed, not read): unknown, so Private, never readable.
    static func privateBooks(notebooks: [(name: String, isPrivate: Bool)], held: [String]) -> Set<String> {
        var out = Set(notebooks.filter(\.isPrivate).map(\.name))
        for name in held where !notebooks.contains(where: { NoteLibrary.same($0.name, name) }) { out.insert(name) }
        return out
    }

    /// Whether a tool's answer may still be given, right before it's handed over (after the vault's redaction, a
    /// wait): every notebook it tells of is still readable by its asker as things are now.
    static func deliverable(notebooks: Set<String>, privateBooks: Set<String>, asker: String?) -> Bool {
        notebooks.allSatisfy { readable(notebook: $0, privateBooks: privateBooks, asker: asker) }
    }
}

extension NotePrivacy {
    /// The notebooks the notes an answer returns are in now, by each note's identity (its id): a note moved into a
    /// Private notebook while the answer was made is checked where it is, not where it was.
    static func currentNotebooks(of ids: Set<String>, notes: [(id: String, notebook: String)]) -> Set<String> {
        Set(notes.filter { ids.contains($0.id) }.map(\.notebook))
    }
}

extension NoteShelf {
    /// The name stem of a copy kept beside a note (a conflicted copy, a recovery): a cover's is always "About this
    /// notebook", so it stays a cover by its name; any other note's comes from its own title.
    static func copyStem(original fileName: String, title: String) -> String {
        NoteLibrary.isCoverName(fileName) ? "About this notebook" : title
    }

    /// Where Keep this one writes the version kept: a cover's conflict always lands on "About this notebook.md" (the
    /// kept text written there and read back before anything is trashed), so the notebook never loses its cover;
    /// any other note's, where the chosen paper is.
    static func keepTarget(chosen: String, group: [String]) -> String {
        // Only within the chosen paper's own notebook folder: never another notebook's cover.
        let folder = (chosen as NSString).deletingLastPathComponent
        guard NoteLibrary.isCoverName((chosen as NSString).lastPathComponent),
              let canonical = group.first(where: { ($0 as NSString).lastPathComponent == NoteShelf.coverName && ($0 as NSString).deletingLastPathComponent == folder })
        else { return chosen }
        return canonical
    }

    /// What papers are grouped by as one note's conflict: a cover-named file (`NoteLibrary.isCoverName`: the cover,
    /// its versions, conflict copies, recoveries) by its notebook folder, whatever its id, so a notebook's cover
    /// files are one group and two notebooks' covers never are (a notebook duplicated in Finder keeps its cover's id);
    /// any other note by its id.
    static func conflictKey(id: String, path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return NoteLibrary.isCoverName(name) ? "cover-folder|" + (path as NSString).deletingLastPathComponent : id
    }

    /// A note opened on its own, with every paper of its conflict (iCloud's versions, a conflicted copy) beside it:
    /// the note first, then the others in the group's order.
    static func standaloneGroup(_ key: String, group: [String]) -> [String] {
        [key] + group.filter { $0 != key }
    }

    /// Where each paper of a group opened on its own goes (AppKit's coordinates: each paper's top-left corner): side
    /// by side from `corner`, wrapping to another row below when the next wouldn't fit the visible screen, the whole
    /// group moved in to fit it.
    static func groupLayout(count: Int, corner: CGPoint, paper: CGSize, gap: CGFloat = 16, visible: CGRect) -> [CGPoint] {
        guard count > 0 else { return [] }
        let across = max(1, min(count, Int((visible.width + gap) / (paper.width + gap))))
        let rows = (count + across - 1) / across
        let width = CGFloat(across) * paper.width + CGFloat(across - 1) * gap
        let height = CGFloat(rows) * paper.height + CGFloat(rows - 1) * gap
        let x = min(max(corner.x, visible.minX), max(visible.minX, visible.maxX - width))
        let top = max(min(corner.y, visible.maxY), min(visible.maxY, visible.minY + height))
        return (0..<count).map { n in
            CGPoint(x: x + CGFloat(n % across) * (paper.width + gap), y: top - CGFloat(n / across) * (paper.height + gap))
        }
    }

    /// A note opened on its own and put away: the keyboard goes back to the Petal Notes window only on Escape, when
    /// it was opened from there and the window is still open; folded by a click elsewhere, the keyboard stays where
    /// the person clicked.
    static func standaloneKeyboard(escape: Bool, fromLibrary: Bool, libraryOpen: Bool) -> Bool { escape && fromLibrary && libraryOpen }
}

extension NoteRoom {
    /// Whether the window in front needs room beside it: only for a note open there by its window placement (one
    /// opened on its own, on a Desktop, or moved off by the person never narrows it).
    static func wanted(_ notes: [(placement: NoteShelf.Placement, open: Bool, moved: Bool)]) -> Bool {
        notes.contains { note in
            guard case .window = note.placement else { return false }
            return note.open && !note.moved
        }
    }
}

/// A task a note holds (`task:`): its parts as chips, and Open all, which brings them back through the normal open
/// paths (a tab by its address, a file by its path, a mail by its message address), never moving the pointer. The
/// one place that opens a task's parts, for the Petal Notes window and the note itself alike.
enum NoteTasks {
    /// A part in a few words: a tab's site (or title), a file's name, "Mail · title", a window's title.
    static func chip(_ item: NoteContract.TaskItem) -> String {
        switch item.kind {
        case "tab":
            let host = NoteText.host(item.target)
            return host.isEmpty ? (item.title.isEmpty ? "A tab" : item.title) : host
        case "file": return item.target.isEmpty ? (item.title.isEmpty ? "A file" : item.title) : (item.target as NSString).lastPathComponent
        case "mail": return "Mail" + (item.title.isEmpty ? "" : " · " + item.title)
        default: return item.title.isEmpty ? "A window" : item.title
        }
    }

    /// Where a part opens: a tab only at a web address (http or https), a file only at an absolute path, a mail only
    /// by its message address (`message:`, or a Message-ID in angle brackets); a window has nothing to open (nil).
    static func url(_ item: NoteContract.TaskItem) -> URL? {
        let target = item.target.trimmingCharacters(in: .whitespaces)
        switch item.kind {
        case "tab":
            guard let url = URL(string: target), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        case "file":
            if target.hasPrefix("file://") { return URL(string: target).flatMap { $0.isFileURL ? $0 : nil } }
            let path = (target as NSString).expandingTildeInPath
            return path.hasPrefix("/") && !path.contains("\0") ? URL(fileURLWithPath: path) : nil
        case "mail":
            if target.lowercased().hasPrefix("message:") { return URL(string: target) }
            guard target.hasPrefix("<"), target.hasSuffix(">"),
                  let id = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".@-_"))) else { return nil }
            return URL(string: "message://" + id)
        default:
            return nil
        }
    }

    /// The parts Open all opens, in order (a file still to be checked by `fileAction` once it's resolved).
    static func openable(_ items: [NoteContract.TaskItem]) -> [URL] { items.compactMap(url) }

    /// What Open all (or a note dropped on an app) may do with a file, decided on what it really is once its aliases
    /// and symbolic links are resolved: opened only when it's a document (conforms to `UTType.content`) and nothing
    /// that runs or points elsewhere (an app, an executable or script of any kind, a `.command`, `.tool`, `.workflow`
    /// or `.terminal` file, an installer package, a disk image, an alias or link, a web, internet or file location).
    /// Anything else is shown in Finder, selected, never opened.
    enum FileAction: Equatable { case open, reveal }

    static let neverOpened: Set<String> = ["app", "command", "tool", "workflow", "terminal", "pkg", "mpkg", "dmg", "sparseimage", "sparsebundle",
                                            "webloc", "inetloc", "fileloc", "sh", "zsh", "bash", "csh", "ksh", "py", "rb", "pl", "scpt", "scptd",
                                            "applescript", "action", "jar", "prefpane", "kext", "plugin", "bundle", "service", "framework", "dylib",
                                            "so", "osax", "mobileconfig", "xpc", "appex", "url", "alias", "saver", "qlgenerator", "mdimporter"]

    static let neverTypes: [String] = ["com.apple.application", "com.apple.application-bundle", "public.executable", "public.unix-executable",
                                       "public.script", "public.shell-script", "com.apple.applescript.script", "com.apple.applescript.text",
                                       "com.apple.terminal.shell-script", "com.apple.automator-workflow", "com.apple.terminal.session",
                                       "com.apple.installer-package-archive", "com.apple.disk-image", "public.disk-image", "com.apple.alias-file",
                                       "public.symlink", "com.apple.web-internet-location", "com.apple.internet-location",
                                       "com.apple.file-internet-location"]

    /// A file as it really is: its alias or symbolic links resolved, then what it is (`fileAction`). The resolved file
    /// is what's opened or shown. Off the main thread.
    nonisolated static func decide(_ url: URL) -> (URL, FileAction) {
        let resolved = (try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])) ?? url
        let real = resolved.resolvingSymlinksInPath()
        let values = try? real.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey])
        guard FileManager.default.fileExists(atPath: real.path), values?.isSymbolicLink != true, values?.isAliasFile != true else { return (real, .reveal) }
        return (real, fileAction(type: values?.contentType, ext: real.pathExtension, isDirectory: values?.isDirectory == true))
    }

    /// `type`: the resolved file's type; `isDirectory`: it's a folder (a document package, like Keynote's, is one).
    static func fileAction(type: UTType?, ext: String, isDirectory: Bool) -> FileAction {
        guard let type, type.conforms(to: .content), !neverOpened.contains(ext.lowercased()) else { return .reveal }
        for id in neverTypes { if let never = UTType(id), type.conforms(to: never) { return .reveal } }
        if isDirectory && !type.conforms(to: .package) { return .reveal }   // a folder is shown, never opened
        return .open
    }
}

// MARK: - A notebook's cover, field by field

/// Changes to a notebook's cover waiting to land, field by field (`private`, `color`, `view`), journaled on this Mac
/// at once like canvas edits, and made on whatever the cover is on disk when they land: a field never carries an old
/// value of another. Shown in memory at once (Private first), and an unknown cover counts as Private.
struct CoverFields: Codable, Equatable, Sendable {
    /// Its notebook's name when the change was made: only for saying so, never how it's found.
    var notebook: String
    /// What it's bound to: the notes' folder it was made in, and its notebook's cover id (when it had one) and folder
    /// itself (volume and inode). Applied only in that root, to the notebook that is that cover or that folder.
    var root = ""
    var coverID = ""
    var folderID = ""
    /// Each field's value ("" takes `private` or `view` off).
    var fields: [String: String] = [:]
    /// When each field was set (seconds since 1970): copies of one change merge newest per field.
    var times: [String: Double] = [:]

    var isEmpty: Bool { fields.isEmpty }

    enum CodingKeys: String, CodingKey { case notebook, root, coverID, folderID, fields, times }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notebook = try c.decode(String.self, forKey: .notebook)
        root = try c.decodeIfPresent(String.self, forKey: .root) ?? ""
        coverID = try c.decodeIfPresent(String.self, forKey: .coverID) ?? ""
        folderID = try c.decodeIfPresent(String.self, forKey: .folderID) ?? ""
        fields = try c.decodeIfPresent([String: String].self, forKey: .fields) ?? [:]
        times = try c.decodeIfPresent([String: Double].self, forKey: .times) ?? [:]
    }

    /// One field set now (or at `at`).
    mutating func set(_ field: String, _ value: String, at: Double = Date().timeIntervalSince1970) {
        fields[field] = value
        times[field] = at
    }

    /// Two copies of the waiting changes for one notebook as one: each field's newest value (a tie keeps this one's).
    func merged(with other: CoverFields) -> CoverFields {
        var out = self
        for (field, value) in other.fields where (other.times[field] ?? 0) > (out.times[field] ?? (out.fields[field] == nil ? -1 : 0)) {
            out.fields[field] = value
            out.times[field] = other.times[field]
        }
        return out
    }

    /// Its key, the same through renames: its root, then its cover id, else its folder.
    var key: String { root + "|" + (coverID.isEmpty ? "folder:" + folderID : coverID) }

    init(notebook: String, root: String = "", coverID: String = "", folderID: String = "", fields: [String: String] = [:]) {
        self.notebook = notebook
        self.root = root
        self.coverID = coverID
        self.folderID = folderID
        self.fields = fields
    }

    /// The notebook it's for in `root` now: the one whose cover has its id, else the one that is its folder; nil when
    /// it's another root's, or neither is found (or found twice: never a guess).
    func target(root now: String, notebooks: [(name: String, coverID: String, folderID: String)]) -> String? {
        guard root == now else { return nil }
        if !coverID.isEmpty {
            let byCover = notebooks.filter { $0.coverID == coverID }
            if byCover.count == 1 { return byCover[0].name }
        }
        guard !folderID.isEmpty else { return nil }
        let byFolder = notebooks.filter { $0.folderID == folderID }
        return byFolder.count == 1 ? byFolder[0].name : nil
    }

    static let names: Set<String> = ["private", "color", "view"]

    /// The cover with these fields made on it, and nothing else.
    static func apply(_ fields: [String: String], to file: inout NoteFile) {
        for (field, value) in fields {
            switch field {
            case "private": file.setScalar("private", value == "true" ? "true" : nil)
            case "view": file.setScalar("view", value == "canvas" ? "canvas" : nil)
            case "color": file.color = value
            default: break
            }
        }
        file.cover = true
    }

    /// A notebook as shown: what its cover says, with each waiting field over it (only those), and an unknown cover
    /// counting as Private.
    func shown(isPrivate read: Bool, unknown: Bool, color: String, view: NoteLibrary.View) -> (isPrivate: Bool, color: String, view: NoteLibrary.View) {
        let isPrivate = fields["private"].map { $0 == "true" } ?? read
        let shownColor = fields["color"] ?? color
        let shownView = fields["view"].map { $0 == "canvas" ? NoteLibrary.View.canvas : .grid } ?? view
        return (isPrivate || unknown, shownColor, shownView)
    }

    /// After a write of `wrote` landed: the fields still waiting (one changed again meanwhile stays).
    func after(wrote: [String: String]) -> CoverFields {
        var next = self
        for (field, value) in wrote where next.fields[field] == value {
            next.fields[field] = nil
            next.times[field] = nil
        }
        return next
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

    /// The vault contact a person is: only by the address the chat shows for them (an email or phone number), and only
    /// when exactly one contact has it; a name, however unique in the vault, never.
    static func contact(handle: String, contacts: [(id: String, addresses: [String])]) -> String? {
        let wanted = normalized(handle)
        guard !wanted.isEmpty else { return nil }
        let hits = contacts.filter { $0.addresses.map(normalized).contains(wanted) }
        return hits.count == 1 ? hits[0].id : nil
    }

    /// An address as compared: an email in lower case, a phone number as its digits (and a leading +).
    static func normalized(_ address: String) -> String {
        let text = address.trimmingCharacters(in: .whitespaces)
        if text.contains("@") { return text.lowercased() }
        let digits = text.filter { $0.isNumber || $0 == "+" }
        return digits.filter(\.isNumber).count >= 7 ? digits : ""
    }

    /// The chat's own address for the person in front (an email or a phone number) when its header shows exactly
    /// one; nil when it shows none or several.
    static func handle(title: String, headings: [String]) -> String? {
        var found: [String] = []
        for text in [title] + headings {
            let range = NSRange(text.startIndex..., in: text)
            if let email = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#) {
                for match in email.matches(in: text, range: range) { found.append((text as NSString).substring(with: match.range).lowercased()) }
            }
            if let phone = try? NSRegularExpression(pattern: #"\+?\d[\d \-().]{6,}\d"#) {
                for match in phone.matches(in: text, range: range) {
                    let digits = (text as NSString).substring(with: match.range).filter { $0.isNumber || $0 == "+" }
                    if digits.filter(\.isNumber).count >= 7 { found.append(digits) }
                }
            }
        }
        let distinct = Set(found)
        return distinct.count == 1 ? distinct.first : nil
    }

    /// What a note on the person in front is stuck to: their name with what tells them apart, their vault contact
    /// (exactly one contact of that name) or else the chat's address for them. Nil, and no note on a person, when
    /// there's only a name: two people of one name would share it, so the note goes on the conversation's window.
    static func identity(name: String, handle: String, contacts: [(id: String, addresses: [String])]) -> (contact: String, handle: String)? {
        // Only with the chat's own address for them: without one, the note stays on the conversation's window.
        guard !name.isEmpty, !normalized(handle).isEmpty else { return nil }
        return (contact(handle: handle, contacts: contacts) ?? "", normalized(handle))
    }

    /// Whether a person's note is on the person in front: the same vault contact, or the same address; a name alone
    /// never matches.
    static func matches(_ stick: NoteStick, _ scene: NoteScene) -> Bool {
        guard stick.kind == .person else { return false }
        if !stick.contact.isEmpty, stick.contact == scene.personContact { return true }
        return !stick.handle.isEmpty && stick.handle == scene.personHandle
    }

    /// Two person places are one person by their contact or their address, never by a name alone.
    static func samePerson(_ a: NoteStick, _ b: NoteStick) -> Bool {
        (!a.contact.isEmpty && a.contact == b.contact) || (!a.handle.isEmpty && a.handle == b.handle)
    }
}

// MARK: - Canvas

/// A notebook's canvas (`view: canvas` on its cover): the same notes laid out freely, labeled areas around them,
/// arrows between them and words written on it. Kept in the notebook's `.canvas.json`, synced like its notes. Every
/// element (a note's spot, an area, an arrow, words) has a stable id and the time it was last changed (`at`), and a
/// removal leaves a tombstone (`removed`), so two Macs' files, or iCloud's versions of one, merge element by element
/// (`merge`: the union, the newer winning on one id, a removal winning over anything older). A change is made only
/// as an edit on the file as it is right then, merged with every version iCloud kept (`write`).
struct NoteCanvas: Codable, Equatable, Sendable {
    struct Spot: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var at: Double? = nil
    }

    struct Area: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var label: String
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var at: Double? = nil
    }

    struct Arrow: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var from: String
        var to: String
        var dashed = false
        var at: Double? = nil
    }

    struct Words: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var text: String
        var x: Double
        var y: Double
        var at: Double? = nil
    }

    var version = 2
    /// Each note's spot, by its id (only a note with an id of its own in its file: NoteShelf.lasting).
    var notes: [String: Spot] = [:]
    var areas: [Area] = []
    var arrows: [Arrow] = []
    var texts: [Words] = []
    var zoom: Double = 1
    var zoomAt: Double? = nil
    /// What was taken away and when ("area:<id>", "arrow:<id>", "words:<id>"): anything older under that id stays
    /// away whichever version it comes from; something changed after it comes back.
    var removed: [String: Double] = [:]

    enum Edit: Codable, Equatable, Sendable {
        case move(String, Spot)
        case area(Area)
        case removeArea(String)
        case arrow(Arrow)
        case removeArrow(String)
        case words(Words)
        case removeWords(String)
        case zoom(Double)
    }

    /// An edit with the time it was made (kept with it while it waits to be saved, so a retry is as old as the edit).
    struct Stamped: Codable, Equatable, Sendable {
        var edit: Edit
        var at: Double
        /// Its own id: a write acknowledges exactly the edits it wrote, by id.
        var id: String

        init(_ edit: Edit, at: Double = Date().timeIntervalSince1970, id: String = UUID().uuidString) {
            self.edit = edit
            self.at = at
            self.id = id
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            edit = try c.decode(Edit.self, forKey: .edit)
            at = try c.decode(Double.self, forKey: .at)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        }
    }

    /// The canvas with one edit made on it at `at`: an area, arrow or words by their id (added or replaced, stamped),
    /// a removal leaving its tombstone.
    func applying(_ edit: Edit, at: Double = Date().timeIntervalSince1970) -> NoteCanvas {
        var next = self
        switch edit {
        case .move(let id, var spot):
            spot.at = at
            next.notes[id] = spot
        case .area(var area):
            area.at = at
            if let index = next.areas.firstIndex(where: { $0.id == area.id }) { next.areas[index] = area } else { next.areas.append(area) }
        case .removeArea(let id):
            next.areas.removeAll { $0.id == id }
            next.removed["area:" + id] = at
        case .arrow(var arrow):
            guard arrow.from != arrow.to else { return next }
            arrow.at = at
            if let index = next.arrows.firstIndex(where: { $0.id == arrow.id }) { next.arrows[index] = arrow } else { next.arrows.append(arrow) }
        case .removeArrow(let id):
            next.arrows.removeAll { $0.id == id }
            next.removed["arrow:" + id] = at
        case .words(var words):
            words.at = at
            if let index = next.texts.firstIndex(where: { $0.id == words.id }) { next.texts[index] = words } else { next.texts.append(words) }
        case .removeWords(let id):
            next.texts.removeAll { $0.id == id }
            next.removed["words:" + id] = at
        case .zoom(let zoom):
            next.zoom = Self.clampZoom(zoom)
            next.zoomAt = at
        }
        return next
    }

    func applying(_ edits: [Stamped]) -> NoteCanvas { edits.reduce(self) { $0.applying($1.edit, at: $1.at) } }

    /// Edits made on this canvas through the same merge as versions, never over it: each edit is a canvas of its own
    /// (its element stamped with its time, or its tombstone) merged in, so an edit older than what's there now (a
    /// retry, a recovery, another Mac's newer change) never wins.
    func applyingMerged(_ edits: [Stamped]) -> NoteCanvas {
        edits.reduce(self) { canvas, stamped in
            let alone = NoteCanvas().applying(stamped.edit, at: stamped.at)
            var merged = Self.merge(canvas, alone)
            // A zoom of its own only when the edit is one (an empty canvas's zoom says nothing).
            if case .zoom = stamped.edit {} else { merged.zoom = canvas.zoom; merged.zoomAt = canvas.zoomAt }
            return merged
        }
    }

    /// Two versions of one canvas as one: every element of both by its id, the newer winning on the same id (a tie
    /// keeps `a`'s), every tombstone of both, and an element only while it's newer than its tombstone.
    static func merge(_ a: NoteCanvas, _ b: NoteCanvas) -> NoteCanvas {
        var out = NoteCanvas()
        out.version = max(a.version, b.version)
        out.removed = a.removed.merging(b.removed) { max($0, $1) }
        func newer<T>(_ x: T?, _ y: T?, _ at: (T) -> Double?) -> T? {
            guard let x else { return y }
            guard let y else { return x }
            return (at(y) ?? 0) > (at(x) ?? 0) ? y : x
        }
        for id in Set(a.notes.keys).union(b.notes.keys) { out.notes[id] = newer(a.notes[id], b.notes[id], \.at) }
        func union<T: Identifiable>(_ x: [T], _ y: [T], kind: String, _ at: (T) -> Double?) -> [T] where T.ID == String {
            var order = x.map(\.id)
            for item in y where !order.contains(item.id) { order.append(item.id) }
            return order.compactMap { id in
                guard let item = newer(x.first { $0.id == id }, y.first { $0.id == id }, at) else { return nil }
                if let gone = out.removed[kind + ":" + id], (at(item) ?? 0) <= gone { return nil }
                return item
            }
        }
        out.areas = union(a.areas, b.areas, kind: "area", \.at)
        out.arrows = union(a.arrows, b.arrows, kind: "arrow", \.at)
        out.texts = union(a.texts, b.texts, kind: "words", \.at)
        let zoomFromB = (b.zoomAt ?? 0) > (a.zoomAt ?? 0)
        out.zoom = zoomFromB ? b.zoom : a.zoom
        out.zoomAt = zoomFromB ? b.zoomAt : a.zoomAt
        return out
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

    /// Missing keys take their defaults; one that's there and can't be read makes the whole file unreadable (never
    /// taken for empty, so never written over). Keys this Petal doesn't know are kept by `write`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        notes = try c.decodeIfPresent([String: Spot].self, forKey: .notes) ?? [:]
        areas = try c.decodeIfPresent([Area].self, forKey: .areas) ?? []
        arrows = try c.decodeIfPresent([Arrow].self, forKey: .arrows) ?? []
        texts = try c.decodeIfPresent([Words].self, forKey: .texts) ?? []
        zoom = Self.clampZoom(try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1)
        zoomAt = try c.decodeIfPresent(Double.self, forKey: .zoomAt)
        removed = try c.decodeIfPresent([String: Double].self, forKey: .removed) ?? [:]
    }

    /// The canvas as it is: the file merged with every version iCloud kept of it (`versions`; one Petal can't read is
    /// left out, and left unresolved by the caller).
    static func merged(disk: String?, versions: [String]) -> NoteCanvas? {
        guard let current = decode(disk) else { return nil }
        return versions.compactMap { decode($0) }.reduce(current, merge)
    }

    /// What a based write puts in the file now on disk (`disk`, nil when there's none): the file merged with iCloud's
    /// versions of it, then the edits (each at its own time), so what changed elsewhere meanwhile stays; everything
    /// this Petal doesn't know (a later Petal's keys, at the top or on an item) is kept, from the file and from every
    /// version merged. `whole`: for each version, whether all of it is kept (one it can't read, or a key it doesn't
    /// know holding another value than the file's, isn't): only those may be marked resolved. Nil when the file isn't
    /// a canvas Petal can read.
    static func merge(_ edits: [Stamped], disk: String?, versions: [String] = []) -> (text: String, whole: [Bool])? {
        guard let current = decode(disk) else { return nil }
        let readable = versions.map { decode($0) != nil }
        let base = versions.indices.filter { readable[$0] }.compactMap { decode(versions[$0]) }.reduce(current, merge)
        let next = base.applyingMerged(edits)
        var whole = readable
        func object(_ text: String?) -> [String: Any]? {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
            return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
        guard var raw = object(disk) else { return nil }
        let others: [[String: Any]?] = versions.indices.map { readable[$0] ? object(versions[$0]) : nil }
        let known: Set<String> = ["version", "notes", "areas", "arrows", "texts", "zoom", "zoomAt", "removed"]
        for (i, other) in others.enumerated() {
            guard let other else { continue }
            for (key, value) in other where !known.contains(key) {
                if let have = raw[key] { if !same(have, value) { whole[i] = false } } else { raw[key] = value }
            }
        }
        guard let fresh = try? JSONSerialization.jsonObject(with: Data(next.encoded().utf8)) as? [String: Any] else { return nil }
        let own: [String: Set<String>] = ["notes": ["x", "y", "at"], "areas": ["id", "label", "x", "y", "w", "h", "at"],
                                          "arrows": ["id", "from", "to", "dashed", "at"], "texts": ["id", "text", "x", "y", "at"]]
        /// One source's raw items by id.
        func items(_ key: String, _ source: [String: Any]?) -> [String: [String: Any]] {
            guard let source else { return [:] }
            if key == "notes" { return (source[key] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] } }
            return Dictionary((source[key] as? [[String: Any]] ?? []).compactMap { item in (item["id"] as? String).map { ($0, item) } },
                              uniquingKeysWith: { a, _ in a })
        }
        for (key, value) in fresh {
            guard let ownKeys = own[key] else { raw[key] = value; continue }
            // The file's items first, then each version's: every key this Petal doesn't know kept, the known ones fresh.
            let sources = [items(key, raw)] + others.map { items(key, $0) }
            func kept(_ id: String, _ item: [String: Any]) -> [String: Any] {
                var out: [String: Any] = [:]
                for (n, source) in sources.enumerated() {
                    guard let found = source[id] else { continue }
                    for (field, v) in found where !ownKeys.contains(field) {
                        if let have = out[field] { if !same(have, v), n > 0 { whole[n - 1] = false } } else { out[field] = v }
                    }
                }
                for (field, v) in item { out[field] = v }
                return out
            }
            if key == "notes" {
                var merged: [String: Any] = [:]
                for (id, spot) in value as? [String: Any] ?? [:] { merged[id] = kept(id, spot as? [String: Any] ?? [:]) }
                raw[key] = merged
            } else {
                raw[key] = (value as? [[String: Any]] ?? []).map { item in kept(item["id"] as? String ?? "", item) }
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return (String(decoding: data, as: UTF8.self) + "\n", whole)
    }

    /// The text alone (see `merge`); the file as it is when nothing changes it.
    static func write(_ edits: [Stamped], disk: String?, versions: [String] = []) -> String? {
        if versions.isEmpty, let current = decode(disk), disk != nil, current.applyingMerged(edits) == current { return disk }
        return merge(edits, disk: disk, versions: versions)?.text
    }

    static func write(_ edit: Edit, disk: String?, versions: [String] = [], at: Double = Date().timeIntervalSince1970) -> String? {
        write([Stamped(edit, at: at)], disk: disk, versions: versions)
    }

    /// Two JSON values alike.
    private static func same(_ a: Any, _ b: Any) -> Bool {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        return (try? JSONSerialization.data(withJSONObject: a, options: options)) == (try? JSONSerialization.data(withJSONObject: b, options: options))
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

/// A notebook's canvas edits not saved yet, as the notes journal keeps them on this Mac's own disk: by the notebook's
/// cover id (never its name, so a renamed notebook keeps them), with its name when they were made (for a rescue's
/// file name), in order with their own times.
struct CanvasEntry: Codable, Equatable, Sendable {
    /// Its key: the notebook's cover id, or, while that isn't known, its folder (CanvasQueue.folderKey).
    var coverID: String
    var notebook: String
    var edits: [NoteCanvas.Stamped]
}

/// A notebook's canvas edits not saved yet: kept in memory in order, journaled, written together on the next try,
/// and kept (never dropped) until a write takes them or, their notebook gone, a rescue does.
enum CanvasQueue {
    /// A group of notes moved together (an area and the notes in it): each note's own id for the move, an id-less one by
    /// the id it was given (`resolved`); nil, and the whole move refused, when any couldn't get one.
    /// `pending`: ids still being written (or whose write failed): waited for like an id-less note's.
    static func groupMove(_ ids: [String], resolved: [String: String], pending: Set<String> = []) -> [String: String]? {
        var out: [String: String] = [:]
        for id in ids {
            if NoteShelf.lasting(id, pending: pending) { out[id] = id; continue }
            guard let real = resolved[id], NoteShelf.lasting(real, pending: pending) else { return nil }
            out[id] = real
        }
        return out
    }

    /// Whether a canvas entry's notebook is gone, to be rescued: only when no notebook's cover has its id and the
    /// notes' folder was read completely (no cover still downloading or unreadable, which could be it).
    static func gone(found: Bool, complete: Bool) -> Bool { !found && complete }

    /// A notebook's folder as a canvas key (its volume and inode): while its cover's id isn't known.
    static func folderKey(_ instance: String) -> String { "folder:" + instance }
    static func isFolderKey(_ key: String) -> Bool { key.hasPrefix("folder:") }

    /// Where a canvas entry goes now: by its cover id, or (a folder key) the one notebook that is that folder.
    static func notebook(key: String, covers: [(id: String, notebook: String)], folders: [(instance: String, notebook: String)]) -> String? {
        guard isFolderKey(key) else { return notebook(coverID: key, covers: covers) }
        let instance = String(key.dropFirst("folder:".count))
        let found = folders.filter { !instance.isEmpty && $0.instance == instance }
        return found.count == 1 ? found[0].notebook : nil
    }

    /// Where a canvas entry goes now: the one notebook whose cover has its id (a cover's conflict copies are in one
    /// notebook), else nil: the notebook is gone and its edits are rescued.
    static func notebook(coverID: String, covers: [(id: String, notebook: String)]) -> String? {
        let found = Set(covers.filter { $0.id == coverID }.map { $0.notebook.lowercased() })
        guard found.count == 1 else { return nil }
        return covers.first { $0.id == coverID }?.notebook
    }

    /// After a write: what's still waiting. Only the exact edits it wrote go (by id): the ones added meanwhile, and
    /// everything when it failed, stay.
    static func after(_ waiting: [NoteCanvas.Stamped], wrote ids: Set<String>, ok: Bool) -> [NoteCanvas.Stamped] {
        ok ? waiting.filter { !ids.contains($0.id) } : waiting
    }

    /// Whether a write's completion may touch what's waiting (and the journal): only when nothing drained or switched
    /// folders since it started.
    static func current(started: Int, now: Int) -> Bool { started == now }

    /// How long to wait before trying again after `failures` failed tries in a row (2 s, doubling, at most a minute).
    static func retry(after failures: Int) -> TimeInterval { min(60, 2 * pow(2, Double(max(0, failures - 1)))) }
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

    /// A picture for a Mail draft: its file in the note's folder, else the bytes Petal holds for it (staged in a
    /// temporary file), else missing.
    enum Attachment: Equatable { case file, stage, missing }

    static func attachment(onDisk: Bool, held: Bool) -> Attachment { onDisk ? .file : held ? .stage : .missing }

    /// Where Mail drafts' staged pictures go: a folder per draft inside it.
    static var stagingRoot: URL { FileManager.default.temporaryDirectory.appending(path: "Petal Mail") }

    /// The staging folders to sweep: those older than an hour (a draft's pictures are long taken in by then).
    static func staleStaging(_ folders: [(name: String, modified: Date)], now: Date, after: TimeInterval = 3600) -> [String] {
        folders.filter { now.timeIntervalSince($0.modified) > after }.map(\.name)
    }

    /// At launch, off the main thread: staging folders a Petal before left (it quit before cleaning up) and older
    /// than an hour, removed. Returns how many.
    @discardableResult
    static func sweepStaging(in root: URL = stagingRoot, now: Date = Date()) -> Int {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []).compactMap { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (name: url.lastPathComponent, modified: $0) }
        }
        let stale = staleStaging(folders, now: now)
        for name in stale { try? fm.removeItem(at: root.appending(path: name)) }
        return stale.count
    }

    /// Held bytes written to a file of their own in `folder` (made for this draft), by the picture's name only.
    static func stage(_ data: Data, name: String, in folder: URL) -> URL? {
        let safe = (name as NSString).lastPathComponent
        guard !safe.isEmpty, safe != ".", safe != "..", !safe.contains("/") else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: safe)
        return (try? data.write(to: url, options: .withoutOverwriting)) != nil ? url : nil
    }

    /// What the person is told when pictures couldn't go along.
    static func missingWords(_ count: Int) -> String? {
        count == 0 ? nil : count == 1 ? "1 picture couldn't be attached." : "\(count) pictures couldn't be attached."
    }

    /// A note with two versions or more (a conflict not kept yet) isn't used anywhere until one is kept: which
    /// version's words would go is the person's to pick.
    static func allowed(versions: Int) -> Bool { versions <= 1 }

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
