import CoreGraphics
import Foundation

// The pure side of Petal Notes (PaperNotes.swift and the files beside it): the note file's format, where a note is
// stuck and which of its places fits what's in front, the tabs notes rest as on a window's edge, fading, iCloud's
// conflict copies, and the room an open note needs beside its window. No AppKit, so macos/checks/run.sh checks it on
// its own (with NoteLayout.swift, whose NoteTab and NoteRules it reuses for tabs).

/// Pictures to bring into a note: files, or a screenshot's data, and where the cursor was.
struct NoteImport: @unchecked Sendable {
    var files: [URL]
    var png: Data?
    var tiff: Data?
    var at: Int
}

// MARK: - Places

/// One place a note is stuck to. A note may have several; the most specific that fits what's in front wins
/// (`NoteMatch`). What only means something on this Mac while its apps run (a window's number, a process, a tab's
/// own id) is said with `mac`, this Mac's own id, so another Mac reading the synced file never takes it for its own.
struct NoteStick: Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        /// A sentence: the quote, a little text before and after it, and the page (url) or file (path) it's on.
        case passage
        /// A browser tab: its own id (Chromium) or its tab-strip button (Safari, Firefox, Zen) while the browser
        /// runs, and its page (url) after.
        case tab
        /// A file open in any app: its path (AXDocument), kept with a bookmark so moves and renames follow.
        case file
        /// One window: its number while its app runs; after, its app and title when only one window has it.
        case window
        /// Every window of an app.
        case app
        /// A Desktop (and its mode): the note sits on that Desktop.
        case desktop

        /// The ranked fallback: a passage, then its page, its file, its window, its app. Lower is more specific.
        var rank: Int {
            switch self {
            case .passage: 0
            case .tab: 1
            case .file: 2
            case .window: 3
            case .app: 4
            case .desktop: 5
            }
        }
    }

    var kind: Kind
    var app = ""
    var appName = ""
    var url = ""
    var title = ""
    var path = ""
    /// A bookmark to the file (base64), so it's found again after a move or rename.
    var bookmark = ""
    var quote = ""
    var before = ""
    var after = ""
    /// The Mac whose window, process and tab the next fields name.
    var mac = ""
    var pid: Int32? = nil
    var window: UInt32? = nil
    var tabID: String? = nil
    /// How many of the browser's tabs had its address when it was stuck (Chromium; nil when unknown): only a tab
    /// that was the one with its address is found again by it after the browser restarts (NoteRules.byAddress).
    var shared: Int? = nil
    /// Safari's, Firefox's and Zen's tab: its tab-strip button (NoteTab.element), meaningful only to the Petal that
    /// saw it, so never written.
    var tabElement: Int? = nil
    var desktop: Int? = nil
    var mode = ""
    /// Keys this Petal doesn't know (a later one's, or the person's own), each with its lines exactly as written
    /// (nested ones too), written back as they were.
    var extra: [(key: String, lines: [String])] = []

    static func == (a: NoteStick, b: NoteStick) -> Bool {
        a.kind == b.kind && a.app == b.app && a.appName == b.appName && a.url == b.url && a.title == b.title && a.path == b.path
            && a.bookmark == b.bookmark && a.quote == b.quote && a.before == b.before && a.after == b.after && a.mac == b.mac
            && a.pid == b.pid && a.window == b.window && a.tabID == b.tabID && a.shared == b.shared && a.tabElement == b.tabElement
            && a.desktop == b.desktop && a.mode == b.mode
            && a.extra.map(\.key) == b.extra.map(\.key) && a.extra.map(\.lines) == b.extra.map(\.lines)
    }

    /// As the AI may see it from an app kept private: what it is and the app, never its words, address or file.
    var scrubbed: NoteStick {
        var s = NoteStick(kind: kind)
        s.app = app
        s.appName = appName
        s.desktop = desktop
        s.mode = mode
        return s
    }

    /// The tab as NoteRules knows tabs.
    var noteTab: NoteTab { NoteTab(id: tabID, element: tabElement, shared: shared, url: url, title: title) }

    /// The same place, whatever was learned about it since (a new window number, a title).
    func samePlace(_ other: NoteStick) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .passage: return quote == other.quote && (url.isEmpty ? path == other.path : NoteRules.sameURL(url, other.url))
        case .tab:
            if mac == other.mac, let a = pid, let b = other.pid { return NoteRules.sameTab(noteTab, pid: a, other.noteTab, pid: b) }
            return NoteRules.byAddress(noteTab, other.noteTab)
        case .file: return path == other.path
        case .window: return app == other.app && (window != nil && window == other.window && mac == other.mac || title == other.title)
        case .app: return app == other.app
        case .desktop: return desktop == other.desktop
        }
    }

    /// What the letterhead says for this place, in a few words.
    func label(found: Bool = true) -> String {
        switch kind {
        case .passage: return found ? "this sentence" : "passage moved"
        case .tab: return NoteText.shortAddress(url).isEmpty ? (title.isEmpty ? "a tab" : title) : NoteText.shortAddress(url)
        case .file: return (path as NSString).lastPathComponent.isEmpty ? "a file" : (path as NSString).lastPathComponent
        case .window: return title.isEmpty ? (appName.isEmpty ? "a window" : "\(appName) window") : title
        case .app: return "all of \(appName.isEmpty ? app : appName)"
        case .desktop: return desktop.map { "Desktop \($0)" } ?? "the Desktop"
        }
    }
}

/// What's in front, as notes see it: the app and its focused window, its browser tab (identity from NoteTab), the
/// file it shows, and the Desktop. `titleTwins`: how many of the app's windows have the front window's title (1:
/// only it), for a window's note found again after its app restarted; nil when unknown.
struct NoteScene: Equatable, Sendable {
    var mac = ""
    var app = ""
    var pid: Int32 = 0
    var window: UInt32? = nil
    var title = ""
    var titleTwins: Int? = nil
    var tab: NoteTab? = nil
    var file = ""
    /// A bookmark to `file` (base64), made with the read off the main thread, for a note stuck to it.
    var fileBookmark = ""
    var desktop: Int? = nil
}

extension NoteScene {
    /// What's in front as Petal may use it from an app kept private: the app and its window, never the window's
    /// title, the tab (its address or title), the file it shows, or how many windows share a title.
    var privately: NoteScene {
        var s = self
        s.title = ""
        s.titleTwins = nil
        s.tab = nil
        s.file = ""
        s.fileBookmark = ""
        return s
    }
}

enum NoteMatch {
    enum TabMatch: Equatable { case identity, address }

    /// How a tab's note fits the tab in front: by its own tab's identity (its id or tab-strip button, this run of
    /// the browser), or by address only (a Chromium tab after a restart, the one tab with that address).
    static func tabMatch(_ stick: NoteStick, _ scene: NoteScene) -> TabMatch? {
        guard stick.kind == .tab, fits(stick, scene), let now = scene.tab else { return nil }
        let samePlace = stick.mac == scene.mac && stick.pid == scene.pid
        let sure = samePlace && ((stick.tabID != nil && stick.tabID == now.id) || (stick.tabElement != nil && stick.tabElement == now.element))
        return sure ? .identity : .address
    }

    /// Notes found on one tab by address alone, decided together: they may take it only when they all come from
    /// one tab before (the same Mac and tab id), so notes from two old tabs that showed the same page are never
    /// guessed onto one. Never a guess between candidates.
    static func recover(_ sticks: [NoteStick]) -> Bool {
        guard let first = sticks.first, first.tabID != nil else { return false }
        return sticks.allSatisfy { $0.tabID == first.tabID && $0.mac == first.mac }
    }

    /// A tab's note recovered onto a tab after its browser restarted: from now on it's that tab's (its id, process
    /// and address).
    static func adopt(_ stick: NoteStick, _ scene: NoteScene) -> NoteStick {
        guard let now = scene.tab else { return stick }
        var next = stick
        next.mac = scene.mac
        next.pid = scene.pid
        next.tabID = now.id
        next.tabElement = now.element
        next.shared = now.shared
        next.url = now.url
        if !now.title.isEmpty { next.title = now.title }
        return next
    }

    /// The most specific place that fits, leaving out some (address matches that couldn't be decided).
    static func best(_ places: [NoteStick], _ scene: NoteScene, excluding: Set<Int>) -> Int? {
        places.indices.filter { !excluding.contains($0) && fits(places[$0], scene) }.min { places[$0].kind.rank < places[$1].kind.rank }
    }

    /// A tab's note seen on its own tab, surely (this Mac, the same browser process, the same id or tab-strip
    /// button): the place as it is now (its address, title and whether it's the one tab with that address), so after
    /// a restart it's found by the address it last had, never the one it was stuck on. nil when it isn't surely its
    /// tab, or nothing changed. `keepWords` false (a private app): its address and title aren't kept.
    static func followTab(_ stick: NoteStick, _ scene: NoteScene, keepWords: Bool) -> NoteStick? {
        guard stick.kind == .tab, let now = scene.tab, stick.mac == scene.mac, stick.pid == scene.pid else { return nil }
        let sure = (stick.tabID != nil && stick.tabID == now.id) || (stick.tabElement != nil && stick.tabElement == now.element)
        guard sure else { return nil }
        let followed = NoteRules.follow(stick.noteTab, to: now, keepWords: keepWords)
        var next = stick
        next.url = followed.url
        next.title = followed.title
        next.shared = followed.shared
        next.tabID = followed.id
        next.tabElement = followed.element
        return next == stick ? nil : next
    }

    /// Whether one place fits what's in front.
    static func fits(_ stick: NoteStick, _ scene: NoteScene) -> Bool {
        switch stick.kind {
        case .passage:
            if !stick.url.isEmpty, let tab = scene.tab { return NoteRules.samePage(stick.url, tab.url) }
            return !stick.path.isEmpty && stick.path == scene.file
        case .tab:
            // NoteTab's rules exactly: its own tab while the browser runs (its id, or its tab-strip button), wherever
            // it moved and whatever it shows, never another tab on the same address; after the browser restarted
            // (or on another Mac), a Chromium tab by its address only when it's the one tab of the browser with it,
            // then and now. Safari's, Firefox's and Zen's tabs never by address.
            guard let now = scene.tab, stick.app.isEmpty || stick.app == scene.app else { return false }
            let pid = stick.mac == scene.mac ? stick.pid ?? -1 : -1
            return NoteRules.sameTab(stick.noteTab, pid: pid, now, pid: scene.pid)
        case .file:
            return !stick.path.isEmpty && stick.path == scene.file
        case .window:
            guard !stick.app.isEmpty, stick.app == scene.app, scene.window != nil else { return false }
            if stick.mac == scene.mac, let pid = stick.pid, pid == scene.pid { return stick.window == scene.window }
            // Its app restarted (or another Mac): by its title, only when one window has it. Two alike: no guess.
            return !stick.title.isEmpty && stick.title == scene.title && scene.titleTwins == 1
        case .app:
            return !stick.app.isEmpty && stick.app == scene.app
        case .desktop:
            return false   // Desktop notes sit on their Desktop, never on a window
        }
    }

    /// The most specific of a note's places that fits what's in front (its index), or nil. Two places of one rank
    /// that both fit are the same thing seen twice, never a guess: the first is taken.
    static func best(_ places: [NoteStick], _ scene: NoteScene) -> Int? {
        places.indices.filter { fits(places[$0], scene) }.min { places[$0].kind.rank < places[$1].kind.rank }
    }

    /// Where a quote is in a text: the one place it is, told apart by the words around it when it's there more than
    /// once. nil when it isn't there, or two places fit as well as each other (never a guess).
    static func locate(quote: String, before: String, after: String, in text: String) -> Range<String.Index>? {
        guard !quote.isEmpty else { return nil }
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let range = text.range(of: quote, range: from..<text.endIndex) {
            found.append(range)
            from = text.index(after: range.lowerBound)
        }
        if found.count <= 1 { return found.first }
        func score(_ range: Range<String.Index>) -> Int {
            let head = String(text[..<range.lowerBound].suffix(before.count))
            let tail = String(text[range.upperBound...].prefix(after.count))
            return common(suffixOf: head, before) + common(prefixOf: tail, after)
        }
        let scored = found.map { ($0, score($0)) }.sorted { $0.1 > $1.1 }
        return scored[0].1 > scored[1].1 ? scored[0].0 : nil
    }

    /// Where a passage is among a window's texts: every place its whole quote is, in any of them, told apart by
    /// the words before and after it. The one that fits them best, by the number of matching characters; nil when
    /// it isn't there, or two places fit as well as each other (never a guess: "passage moved").
    static func pick(quote: String, before: String, after: String, in texts: [String]) -> (text: Int, range: Range<String.Index>)? {
        guard !quote.isEmpty else { return nil }
        var found: [(Int, Range<String.Index>, Int)] = []
        for (index, text) in texts.enumerated() {
            var from = text.startIndex
            while from < text.endIndex, let range = text.range(of: quote, range: from..<text.endIndex) {
                let head = String(text[..<range.lowerBound].suffix(before.count))
                let tail = String(text[range.upperBound...].prefix(after.count))
                found.append((index, range, common(suffixOf: head, before) + common(prefixOf: tail, after)))
                from = text.index(after: range.lowerBound)
            }
        }
        guard !found.isEmpty else { return nil }
        let sorted = found.sorted { $0.2 > $1.2 }
        if sorted.count > 1, sorted[0].2 == sorted[1].2 { return nil }
        return (sorted[0].0, sorted[0].1)
    }

    private static func common(suffixOf a: String, _ b: String) -> Int {
        zip(a.reversed(), b.reversed()).prefix { $0 == $1 }.count
    }

    private static func common(prefixOf a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }
}

// MARK: - The file

/// One note: a Markdown file with a small front matter. Its notebook is the folder it's in; the file's own name
/// is only for the person (the id says which note it is, so a copy iCloud made in a conflict is the same note).
struct NoteFile: Equatable, Sendable {
    var id: String
    var created: Date
    var modified: Date
    var places: [NoteStick] = []
    /// A notebook's cover ("About this notebook"): its color, and what the notebook is for.
    var cover = false
    /// The notebook's color, on its cover: "#rrggbb", or "accent" for the Mac's accent color.
    var color = ""
    /// The quick question it came from (Stick here), so a later Petal can carry the conversation on.
    var chat = ""
    var body = ""
    /// Keys this Petal doesn't know, written back as they were (each with its own lines).
    var extra: [(key: String, lines: [String])] = []

    init(id: String = UUID().uuidString, created: Date = Date(), modified: Date? = nil, body: String = "") {
        self.id = id
        self.created = created
        self.modified = modified ?? created
        self.body = body
    }

    static func == (a: NoteFile, b: NoteFile) -> Bool {
        a.id == b.id && a.created == b.created && a.modified == b.modified && a.places == b.places && a.cover == b.cover
            && a.color == b.color && a.chat == b.chat && a.body == b.body
            && a.extra.map(\.key) == b.extra.map(\.key) && a.extra.map(\.lines) == b.extra.map(\.lines)
    }

    /// The title: its first heading, else its first line of words.
    var title: String { NoteText.title(body) }

    /// What a folded note shows under its title.
    var preview: String { NoteText.preview(body) }

    // MARK: Reading and writing

    private static let dates: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format
    }()

    static func date(_ text: String) -> Date? { dates.date(from: text) }
    static func stamp(_ date: Date) -> String { dates.string(from: date) }

    /// Reads a note file. A file with no front matter is a note too (one the person wrote by hand): `fallbackID` and
    /// the file's dates stand in. Never fails: anything unreadable is kept as the body.
    static func parse(_ text: String, fallbackID: String, fallbackDate: Date) -> NoteFile {
        var note = NoteFile(id: fallbackID, created: fallbackDate, modified: fallbackDate)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            note.body = normalized
            return note
        }
        let head = Array(lines[1..<end])
        lines.removeFirst(end + 1)
        note.body = lines.joined(separator: "\n")
        var index = 0
        while index < head.count {
            let line = head[index]
            index += 1
            guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { note.extra.append((key: "", lines: [line])) }
                continue
            }
            let key = String(line[..<colon])
            let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // The lines that belong to it (indented, or list items under it).
            var block: [String] = []
            while index < head.count, head[index].hasPrefix(" ") || head[index].hasPrefix("-") {
                block.append(head[index])
                index += 1
            }
            switch key {
            case "id": note.id = scalar(raw).isEmpty ? fallbackID : scalar(raw)
            case "created": note.created = date(scalar(raw)) ?? fallbackDate
            case "modified": note.modified = date(scalar(raw)) ?? fallbackDate
            case "cover": note.cover = scalar(raw) == "true"
            case "color": note.color = scalar(raw)
            case "chat": note.chat = scalar(raw)
            case "places": note.places = places(block)
            default: note.extra.append((key: key, lines: [line] + block))
            }
        }
        return note
    }

    /// The file as text: the front matter, then the body as the person wrote it.
    func serialized() -> String {
        var head = ["---", "id: \(id)", "created: \(Self.stamp(created))", "modified: \(Self.stamp(modified))"]
        if cover { head.append("cover: true") }
        if !color.isEmpty { head.append("color: \(Self.quoted(color))") }
        if !chat.isEmpty { head.append("chat: \(Self.quoted(chat))") }
        if !places.isEmpty {
            head.append("places:")
            for place in places {
                var fields: [(String, String)] = [("kind", place.kind.rawValue)]
                let strings: [(String, String)] = [("app", place.app), ("appName", place.appName), ("url", place.url), ("title", place.title),
                                                   ("path", place.path), ("bookmark", place.bookmark), ("quote", place.quote),
                                                   ("before", place.before), ("after", place.after), ("mac", place.mac), ("mode", place.mode)]
                for (key, value) in strings where !value.isEmpty { fields.append((key, Self.quoted(value))) }
                if let pid = place.pid { fields.append(("pid", "\(pid)")) }
                if let window = place.window { fields.append(("window", "\(window)")) }
                if let tab = place.tabID { fields.append(("tab", Self.quoted(tab))) }
                if let shared = place.shared { fields.append(("shared", "\(shared)")) }
                if let desktop = place.desktop { fields.append(("desktop", "\(desktop)")) }
                for (offset, field) in fields.enumerated() {
                    head.append((offset == 0 ? "  - " : "    ") + "\(field.0): \(field.1)")
                }
                for item in place.extra { head.append(contentsOf: item.lines) }
            }
        }
        for item in extra { head.append(contentsOf: item.lines) }
        head.append("---")
        return head.joined(separator: "\n") + "\n" + body
    }

    /// A value as the front matter writes it: plain when it can't be misread, else a JSON string.
    static func quoted(_ value: String) -> String {
        let plain = value.range(of: #"^[A-Za-z0-9][A-Za-z0-9 ._/@+\-]*$"#, options: .regularExpression) != nil && !value.hasSuffix(" ")
            && !["true", "false", "null", "yes", "no"].contains(value.lowercased())
        if plain { return value }
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// A value as written: a JSON string, or plain text.
    static func scalar(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("\""), let data = "[\(text)]".data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String], let value = array.first else { return text }
        return value
    }

    /// The places list: items ("  - kind: tab"), each field on a line of its own one step in. A field this Petal
    /// doesn't know keeps its lines exactly as written, and so do the lines nested under it.
    private static func places(_ lines: [String]) -> [NoteStick] {
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        var items: [[(key: String, raw: String, lines: [String])]] = []
        var fieldIndent = Int.max
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let at = indent(line)
            if trimmed.hasPrefix("- ") && at < fieldIndent {
                // A new item; its first field is on the same line.
                items.append([])
                fieldIndent = at + 2
                let field = String(trimmed.dropFirst(2))
                if let colon = field.firstIndex(of: ":") {
                    items[items.count - 1].append((String(field[..<colon]), String(field[field.index(after: colon)...]).trimmingCharacters(in: .whitespaces),
                                                   [String(repeating: " ", count: fieldIndent) + field]))
                }
                continue
            }
            guard !items.isEmpty else { continue }
            if at > fieldIndent, !items[items.count - 1].isEmpty {
                // Nested under the field before: kept with it, as written.
                items[items.count - 1][items[items.count - 1].count - 1].lines.append(line)
            } else if let colon = trimmed.firstIndex(of: ":") {
                items[items.count - 1].append((String(trimmed[..<colon]), String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces), [line]))
            }
        }
        return items.compactMap { fields in
            guard let kind = fields.first(where: { $0.key == "kind" }).flatMap({ NoteStick.Kind(rawValue: scalar($0.raw)) }) else { return nil }
            var stick = NoteStick(kind: kind)
            for field in fields {
                let value = scalar(field.raw)
                // A known key with lines nested under it isn't one this Petal wrote: kept as written.
                if field.lines.count > 1 { stick.extra.append((key: field.key, lines: field.lines)); continue }
                switch field.key {
                case "kind": break
                case "app": stick.app = value
                case "appName": stick.appName = value
                case "url": stick.url = value
                case "title": stick.title = value
                case "path": stick.path = value
                case "bookmark": stick.bookmark = value
                case "quote": stick.quote = value
                case "before": stick.before = value
                case "after": stick.after = value
                case "mac": stick.mac = value
                case "mode": stick.mode = value
                case "pid": stick.pid = Int32(value)
                case "window": stick.window = UInt32(value)
                case "tab": stick.tabID = value
                case "shared": stick.shared = Int(value)
                case "desktop": stick.desktop = Int(value)
                default: stick.extra.append((key: field.key, lines: field.lines))
                }
            }
            return stick
        }
    }
}

// MARK: - The writing

/// One line of a note, as the paper shows it: headings, checkboxes, a link alone on its line (a card), a picture,
/// Petal's ink (a quote), list items and plain text. Lines are kept one for one, so the file is the person's own
/// Markdown and reads the same in any editor.
enum NoteBlock: Equatable, Sendable {
    case heading(Int, String)
    case check(Bool, String)
    case bullet(String)
    case link(String)
    case image(path: String, caption: String)
    case ink(String)
    case text(String)

    static func parse(_ line: String) -> NoteBlock {
        for level in 1...3 {
            let mark = String(repeating: "#", count: level) + " "
            if line.hasPrefix(mark) { return .heading(level, String(line.dropFirst(mark.count))) }
        }
        let lower = line.lowercased()
        if lower.hasPrefix("- [ ] ") { return .check(false, String(line.dropFirst(6))) }
        if lower.hasPrefix("- [x] ") { return .check(true, String(line.dropFirst(6))) }
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return .bullet(String(line.dropFirst(2))) }
        if line.hasPrefix("> ") { return .ink(String(line.dropFirst(2))) }
        if line == ">" { return .ink("") }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == line, NoteText.isAddress(line) { return .link(line) }
        if line.hasPrefix("!["), line.hasSuffix(")"), let close = line.range(of: "]("),
           !line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound].contains("]") {
            let caption = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
            let path = String(line[close.upperBound..<line.index(before: line.endIndex)])
            if !path.isEmpty, !path.contains(")") {
                return .image(path: path.hasPrefix("<") && path.hasSuffix(">") ? String(path.dropFirst().dropLast()) : path, caption: caption)
            }
        }
        return .text(line)
    }

    var markdown: String {
        switch self {
        case .heading(let level, let text): String(repeating: "#", count: min(3, max(1, level))) + " " + text
        case .check(let done, let text): (done ? "- [x] " : "- [ ] ") + text
        case .bullet(let text): "- " + text
        case .link(let url): url
        case .image(let path, let caption): "![\(caption)](\(path.contains(" ") ? "<\(path)>" : path))"
        case .ink(let text): text.isEmpty ? ">" : "> " + text
        case .text(let text): text
        }
    }

    static func blocks(_ body: String) -> [NoteBlock] {
        body.isEmpty ? [] : body.components(separatedBy: "\n").map(parse)
    }

    static func body(_ blocks: [NoteBlock]) -> String { blocks.map(\.markdown).joined(separator: "\n") }

    /// The words of the line, without its marks.
    var words: String {
        switch self {
        case .heading(_, let text), .check(_, let text), .bullet(let text), .ink(let text), .text(let text): text
        case .link(let url): url
        case .image(_, let caption): caption
        }
    }
}

enum NoteText {
    static func isAddress(_ text: String) -> Bool {
        (text.hasPrefix("https://") || text.hasPrefix("http://")) && !text.contains(" ") && text.count > 10
    }

    /// An address as the letterhead says it: its host and path, without "www." or a trailing slash.
    static func shortAddress(_ url: String) -> String {
        guard let parts = URLComponents(string: url), var host = parts.host else { return "" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        let short = host + path
        return short.count > 40 ? String(short.prefix(39)) + "…" : short
    }

    /// A short address ("example.com/rooms") as its site alone; anything else as it is.
    static func site(_ label: String) -> String {
        guard let slash = label.firstIndex(of: "/"), label[..<slash].contains("."), !label.contains(" ") else { return label }
        return String(label[..<slash])
    }

    static func host(_ url: String) -> String {
        guard var host = URLComponents(string: url)?.host else { return "" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// Inline Markdown links ([words](address)) as their words.
    static func plain(_ text: String) -> String {
        guard text.contains("](") else { return text }
        return text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    }

    static func title(_ body: String) -> String {
        let blocks = NoteBlock.blocks(body)
        if let first = blocks.first(where: { if case .heading = $0 { true } else { false } }), blocks.prefix(3).contains(first) {
            return plain(first.words).trimmingCharacters(in: .whitespaces)
        }
        for block in blocks {
            if case .image = block { continue }
            let words = plain(block.words).trimmingCharacters(in: .whitespaces)
            if !words.isEmpty { return words.count > 80 ? String(words.prefix(79)) + "…" : words }
        }
        return ""
    }

    /// The lines after the title, for a folded note.
    static func preview(_ body: String) -> String {
        let title = self.title(body)
        var lines: [String] = []
        var skipped = false
        for block in NoteBlock.blocks(body) {
            let words = plain(block.words).trimmingCharacters(in: .whitespaces)
            if words.isEmpty { continue }
            if !skipped, words == title || title.hasPrefix(words.prefix(60)) { skipped = true; continue }
            switch block {
            case .check(let done, _): lines.append((done ? "☑ " : "☐ ") + words)
            case .image: continue
            case .link: lines.append(host(words))
            default: lines.append(words)
            }
            if lines.count == 6 { break }
        }
        return lines.joined(separator: " ")
    }

    /// A file name for a new note: its first words, made safe, never over 60 characters.
    static func fileName(_ title: String) -> String {
        let allowed = title.unicodeScalars.map { CharacterSet(charactersIn: "/:\\\n\r\t\"*?<>|").contains($0) ? " " : String($0) }.joined()
        let squeezed = allowed.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let trimmed = squeezed.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).prefix(60)
        return trimmed.isEmpty ? "Note" : String(trimmed)
    }

    /// Matches a search: every word of `query` somewhere in the note (title, body, notebook), ignoring case and accents.
    static func matches(_ query: String, _ haystack: String) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        let folded = haystack.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return words.allSatisfy { folded.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
    }
}

// MARK: - Notebooks, conflicts and fading

enum NoteShelf {
    /// The notebook new notes go to unless the person chose one for that place.
    static let inbox = "Inbox"
    /// A notebook's cover note's file name.
    static let coverName = "About this notebook.md"
    /// Pictures pasted or dropped on a note live in a folder beside it: "<note's file name>.assets".
    static let assets = ".assets"

    /// Untouched this long, a note rests as a faint line.
    static let fadeAfter: TimeInterval = 30 * 86400

    static func faded(modified: Date, now: Date) -> Bool { now.timeIntervalSince(modified) > fadeAfter }

    /// A notebook's name as a folder name: no slashes, no leading dots.
    static func folderName(_ name: String) -> String {
        let cleaned = NoteText.fileName(name)
        return cleaned == "Note" && name.trimmingCharacters(in: .whitespaces).isEmpty ? inbox : cleaned
    }

    /// A name for a new file in a folder holding `taken` (lowercased names): "Name.md", else "Name 2.md", ….
    static func freeName(_ stem: String, taken: Set<String>) -> String {
        if !taken.contains((stem + ".md").lowercased()) { return stem + ".md" }
        var n = 2
        while taken.contains("\(stem) \(n).md".lowercased()) { n += 1 }
        return "\(stem) \(n).md"
    }

    /// The id of a note whose file has none (written by hand, or by another app): where it is under the notes'
    /// folder, so two files with one name in two notebooks are never taken for one note. Written into the file the
    /// first time Petal saves it.
    static func fallbackID(relativePath: String) -> String { "file:" + relativePath }

    /// A file's path under `root`, or nil when it isn't under it.
    static func relative(_ path: String, to root: String) -> String? {
        guard let inside = within(path, root) else { return nil }
        return inside
    }

    /// `path` inside `root` (both absolute): the part under it, or nil when it's `root` itself, outside it, or gets
    /// out with "..". Petal writes, moves and trashes note files only where this says yes (with every part of the
    /// path checked for a symbolic link first).
    static func within(_ path: String, _ root: String) -> String? {
        let parts = (path as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: true)
        let base = (root as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"), root.hasPrefix("/"), parts.count > base.count, Array(parts.prefix(base.count)) == base,
              !parts.contains(".."), !parts.contains(".") else { return nil }
        return parts.dropFirst(base.count).joined(separator: "/")
    }

    /// What saving a note does with its file as it is on disk now (`disk`, nil when there's none), when the person's
    /// edit was made on `base` (the file as Petal last read or wrote it; nil for a new note): write it, or, when
    /// someone changed the file since (another editor, another Mac), keep both: the edit goes to a copy beside it,
    /// and the two show as one note's papers until one is kept.
    enum Save: Equatable { case write, already, keepBoth }

    static func save(disk: String?, text: String, base: String?) -> Save {
        guard let disk else { return .write }
        // The file says it already (a write that landed before its answer came back, a quit's last try): done.
        if disk == text { return .already }
        // A new note (no base) never goes over a file that's there.
        guard let base else { return .keepBoth }
        return disk == base ? .write : .keepBoth
    }

    /// What an edit was really made on: an edit made on a text this note's own writes put there (or tried to: a
    /// write that failed) was made on what the file said when those began, or after the last of them that landed
    /// (`anchor`). Any other base is the file as it was read. `ours`: hashes of the texts this note's writes carried.
    static func effectiveBase(_ base: String?, ours: Set<Int>, anchor: String?) -> String? {
        guard let base else { return nil }
        return ours.contains(base.hashValue) ? anchor : base
    }

    /// Keep this one, on the papers exactly as they were shown: each candidate (a file's path, or a version iCloud
    /// kept) as it was then (`shown`: its text) and as it is now (`now`: its text, nil when it's gone). Only when
    /// every one shown is still there and unchanged, and nothing new arrived (a version iCloud delivered since).
    static func keepAllowed(shown: [String: String], now: [String: String?]) -> Bool {
        guard Set(shown.keys) == Set(now.keys) else { return false }
        return shown.allSatisfy { key, text in now[key] == .some(text) }
    }

    /// The base an editor's save is made on, when Petal itself changed the note since the editor last had it (a
    /// tab's address followed, a file's bookmark followed, a place added): those changes leave the words alone, so
    /// the edit is on the note as it is now. Words changed since (another editor, another Mac): its own base, and
    /// the save keeps both.
    static func rebase(editor base: String?, current: String?, currentBody: String) -> String? {
        guard let base, let current, base != current else { return base }
        return NoteFile.parse(base, fallbackID: "", fallbackDate: Date()).body == currentBody ? current : base
    }

    /// The copy's name for an edit kept beside a file changed elsewhere: "Name (conflicted copy).md", then
    /// "Name (conflicted copy 2).md", … (iCloud's own words, so it reads as one).
    static func conflictName(_ stem: String, taken: Set<String>) -> String {
        var name = "\(stem) (conflicted copy).md"
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "\(stem) (conflicted copy \(n)).md"
            n += 1
        }
        return name
    }

    /// The notes after a read of the folder that began at `started`: what was read, except notes changed in memory
    /// since it began (`changed`: key → when, on the same clock), which keep their newer selves, and notes made
    /// since, which the read can't have seen yet. Removed since (`removed`): left out.
    static func fenced<T>(read: [T], memory: [T], key: (T) -> String, started: Int, changed: [String: Int], removed: [String: Int]) -> [T] {
        let newer = { (k: String) in (changed[k] ?? Int.min) >= started }
        let gone = { (k: String) in (removed[k] ?? Int.min) >= started }
        let mine = Dictionary(memory.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        var out: [T] = []
        var seen: Set<String> = []
        for item in read {
            let k = key(item)
            seen.insert(k)
            if gone(k) { continue }
            out.append(newer(k) ? mine[k] ?? item : item)
        }
        for item in memory where !seen.contains(key(item)) && newer(key(item)) && !gone(key(item)) { out.append(item) }
        return out
    }

    /// A note's pictures' folder, named for the note's id (never its file's name), so it keeps its name wherever the
    /// note moves and two notes never share one: "<id>.assets".
    static func assetsFolder(id: String) -> String {
        // Readable, then a stable hash of the whole id, so ids that read alike ("My notes", "My-notes") never share.
        let safe = id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "-" }.joined()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a, 64 bits: the same on every Mac and every run
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return (safe.isEmpty ? "note" : String(safe.prefix(40))) + "-" + String(format: "%016llx", hash) + assets
    }

    /// A copy iCloud Drive made of a file that changed on two Macs at once: "Name 2.md" beside "Name.md" (or
    /// "Name (conflicted copy …).md"), holding the same note. Notes are grouped by id: a group of more than one file
    /// is a conflict, shown as both papers until one is kept. The first of each group is the original: the file
    /// whose name isn't a copy's, else the oldest.
    struct Copy: Equatable, Sendable {
        var id: String
        var file: String
        var modified: Date
    }

    static func conflicts(_ copies: [Copy]) -> [[Copy]] {
        var groups: [String: [Copy]] = [:]
        var order: [String] = []
        for copy in copies {
            if groups[copy.id] == nil { order.append(copy.id) }
            groups[copy.id, default: []].append(copy)
        }
        return order.compactMap { id in
            guard let group = groups[id], group.count > 1 else { return nil }
            return group.sorted { a, b in
                let ca = isCopyName(a.file), cb = isCopyName(b.file)
                if ca != cb { return !ca }
                if a.modified != b.modified { return a.modified < b.modified }
                return a.file < b.file
            }
        }
    }

    /// A name iCloud gives a conflict's copy: "Name 2.md", "Name (conflicted copy).md".
    static func isCopyName(_ file: String) -> Bool {
        let stem = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        if stem.lowercased().contains("conflicted copy") { return true }
        guard let space = stem.lastIndex(of: " ") else { return false }
        return Int(stem[stem.index(after: space)...]).map { $0 >= 2 } ?? false
    }
}

// MARK: - Resting on a window's edge

/// A note as it rests on its window: its id, where its line is (points down from the window's top; nil when the app
/// doesn't say), its notebook's color, and whether it's faded.
struct EdgeNote: Equatable, Sendable {
    var id: String
    var line: CGFloat?
    var color: String
    var faded: Bool
}

/// One tab on a window's edge: one note, or several on one line (with their count).
struct EdgeTab: Equatable, Sendable {
    var ids: [String]
    var y: CGFloat
    var height: CGFloat
    var color: String
    var faded: Bool
    var count: Int { ids.count }
}

enum EdgeLayout {
    static let tab: CGFloat = 34
    static let fadedTab: CGFloat = 14
    static let gap: CGFloat = 6
    /// Notes whose lines are this close are on one line: one tab with a count.
    static let sameLine: CGFloat = 18
    /// Notes the app gives no line for are stacked from here (below the window's title bar).
    static let top: CGFloat = 52

    /// The tabs on a window `height` points tall. Notes at their lines first (in order down the window, several on
    /// one line together), then the rest stacked from the top into the room left; never overlapping, never past the
    /// bottom (what doesn't fit joins the last tab).
    static func tabs(_ notes: [EdgeNote], height: CGFloat) -> [EdgeTab] {
        let placed = notes.filter { $0.line != nil }.sorted { ($0.line ?? 0) < ($1.line ?? 0) }
        var groups: [[EdgeNote]] = []
        for note in placed {
            if let first = groups.last?.first?.line, let line = note.line, line - first <= sameLine { groups[groups.count - 1].append(note) }
            else { groups.append([note]) }
        }
        var tabs = groups.map { group in
            EdgeTab(ids: group.map(\.id), y: max(top, (group[0].line ?? top) - tab / 2 + 8), height: group.allSatisfy(\.faded) ? fadedTab : tab,
                    color: group.first { !$0.faded }?.color ?? group[0].color, faded: group.allSatisfy(\.faded))
        }
        // Stacked ones go into the gaps from the top down.
        for note in notes where note.line == nil {
            let height = note.faded ? fadedTab : tab
            var y = top
            for other in tabs.sorted(by: { $0.y < $1.y }) where y + height + gap > other.y && y < other.y + other.height + gap {
                y = other.y + other.height + gap
            }
            tabs.append(EdgeTab(ids: [note.id], y: y, height: height, color: note.color, faded: note.faded))
        }
        tabs.sort { $0.y < $1.y }
        // Pushed apart, top to bottom.
        for index in tabs.indices.dropFirst() {
            let above = tabs[index - 1]
            tabs[index].y = max(tabs[index].y, above.y + above.height + gap)
        }
        // Past the bottom: joins the last tab that fits.
        let limit = height - gap
        while tabs.count > 1, let last = tabs.last, last.y + last.height > limit {
            tabs.removeLast()
            tabs[tabs.count - 1].ids += last.ids
            if !last.faded { tabs[tabs.count - 1].faded = false; tabs[tabs.count - 1].height = tab }
        }
        if let last = tabs.last, last.y + last.height > limit { tabs[tabs.count - 1].y = max(0, limit - last.height) }
        return tabs
    }
}

// MARK: - Room beside the window

/// An open note sits beside its window's right edge. When there's no room there, Petal narrows the window while
/// the note is open and gives the width back after, as keepWindowsClear does: it remembers the frame from before,
/// and a window the person moved or resized since is theirs. All frames in one coordinate space (x grows right).
enum NoteRoom {
    static let gap: CGFloat = 12
    /// Never narrowed below this.
    static let minimumWidth: CGFloat = 480

    /// The room right of the window, within the screen's visible area.
    static func room(window: CGRect, visible: CGRect) -> CGFloat { visible.maxX - window.maxX }

    /// The window's frame with room for a note `width` wide on its right, or nil when it has room already or can't
    /// make it (narrowed below its minimum: the note then sits over the window's edge instead). It keeps its left
    /// edge and shrinks; when that's too narrow it moves left first.
    static func narrowed(window: CGRect, visible: CGRect, note width: CGFloat) -> CGRect? {
        let needed = width + gap * 2
        guard room(window: window, visible: visible) < needed else { return nil }
        let right = visible.maxX - needed
        if right - window.minX >= minimumWidth {
            return CGRect(x: window.minX, y: window.minY, width: right - window.minX, height: window.height)
        }
        // Moved left as far as the screen allows, then narrowed to fit.
        let left = max(visible.minX, right - window.width)
        let fitted = right - left
        guard fitted >= minimumWidth else { return nil }
        return CGRect(x: left, y: window.minY, width: fitted, height: window.height)
    }

    /// The frame to give back once the note closes: the one from before, while the window still has the frame Petal
    /// gave it (within a few points: an app may round it); nil once the person moved or resized it.
    static func giveBack(before: CGRect, given: CGRect, now: CGRect) -> CGRect? {
        close(now, given) ? before : nil
    }

    static func close(_ a: CGRect, _ b: CGRect, within slack: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) <= slack && abs(a.minY - b.minY) <= slack && abs(a.width - b.width) <= slack && abs(a.height - b.height) <= slack
    }

    /// What to do with the windows narrowed for notes (`narrowed`) when the window that wants room now is `wanted`
    /// (nil: none): every other one gets its width back, and `wanted` is narrowed unless it is already. One path for
    /// every change (a note opened, folded, hidden, moved to the Desktop, notes off, quitting with `wanted` nil).
    static func reconcile(narrowed: Set<UInt32>, wanted: UInt32?) -> (giveBack: [UInt32], narrow: UInt32?) {
        (narrowed.filter { $0 != wanted }.sorted(), wanted.flatMap { narrowed.contains($0) ? nil : $0 })
    }

    /// What happens to a narrowed window's record when its width is to come back: `found` (the window is still
    /// there), `now` (its frame, nil when it couldn't be read). The record goes only once the window is gone, the
    /// person changed it, or it's back as it was; a window that couldn't be read keeps it, for the next try.
    static func giveBackPlan(found: Bool, now: CGRect?, before: CGRect, given: CGRect) -> (restore: Bool, forget: Bool) {
        guard found else { return (false, true) }
        guard let now else { return (false, false) }
        if restore(before: before, given: given, now: now) { return (true, false) }
        return (false, true)
    }

    /// Whether a window narrowed for a note gets its frame from before: while it still has the frame Petal gave it,
    /// or is part way there (a change cut short, the app holding its size), never once the person moved or resized
    /// it to something else.
    static func restore(before: CGRect, given: CGRect, now: CGRect) -> Bool {
        if close(now, before) { return false }   // already as it was
        if close(now, given) { return true }
        // Part way: one of its size or position is Petal's, the other still the one from before.
        let sizeOurs = abs(now.width - given.width) <= 4 && abs(now.height - given.height) <= 4
        let sizeBefore = abs(now.width - before.width) <= 4 && abs(now.height - before.height) <= 4
        let placeOurs = abs(now.minX - given.minX) <= 4 && abs(now.minY - given.minY) <= 4
        let placeBefore = abs(now.minX - before.minX) <= 4 && abs(now.minY - before.minY) <= 4
        return (sizeOurs && placeBefore) || (placeOurs && sizeBefore)
    }

    /// Where an open note sits: right of the window at its line (`top`: points down from the window's top), kept on
    /// the screen's visible area. Frames here are top-left origin (Accessibility's): y grows down.
    static func beside(window: CGRect, visible: CGRect, size: CGSize, top: CGFloat) -> CGRect {
        var x = window.maxX + gap
        if x + size.width > visible.maxX { x = visible.maxX - size.width - gap }
        let y = min(max(window.minY + top, visible.minY + gap), visible.maxY - size.height - gap)
        return CGRect(x: x, y: max(visible.minY, y), width: size.width, height: size.height)
    }
}

// MARK: - Color

/// Petal Notes' paper colors: mixed as the sketch mixes them (CSS color-mix in Oklab).
enum NoteInk {
    struct RGB: Equatable, Sendable { var r, g, b: Double }

    static func hex(_ text: String) -> RGB? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return RGB(r: Double((value >> 16) & 255) / 255, g: Double((value >> 8) & 255) / 255, b: Double(value & 255) / 255)
    }

    static func hex(_ c: RGB) -> String {
        String(format: "#%02x%02x%02x", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    /// `a` at `amount` (0…1) mixed into `b`, in Oklab.
    static func mix(_ a: RGB, _ amount: Double, _ b: RGB) -> RGB {
        let x = oklab(a), y = oklab(b)
        let t = max(0, min(1, amount))
        return rgb((x.0 * t + y.0 * (1 - t), x.1 * t + y.1 * (1 - t), x.2 * t + y.2 * (1 - t)))
    }

    private static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private static func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    private static func oklab(_ c: RGB) -> (Double, Double, Double) {
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private static func rgb(_ lab: (Double, Double, Double)) -> RGB {
        let l = pow(lab.0 + 0.3963377774 * lab.1 + 0.2158037573 * lab.2, 3)
        let m = pow(lab.0 - 0.1055613458 * lab.1 - 0.0638541728 * lab.2, 3)
        let s = pow(lab.0 - 0.0894841775 * lab.1 - 1.2914855480 * lab.2, 3)
        let clamp = { (v: Double) in max(0, min(1, gamma(v))) }
        return RGB(r: clamp(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                   g: clamp(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                   b: clamp(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    static let paper = RGB(r: 1, g: 254 / 255, b: 249 / 255)       // #fffef9
    static let ink = RGB(r: 0x33 / 255.0, g: 0x33 / 255.0, b: 0x33 / 255.0)   // #333
    static let black = RGB(r: 0x11 / 255.0, g: 0x11 / 255.0, b: 0x11 / 255.0) // #111

    /// The paper of a notebook colored `c`: 15% of it in warm white.
    static func paper(_ c: RGB) -> RGB { mix(c, 0.15, paper) }
    /// The letterhead's words.
    static func letterhead(_ c: RGB) -> RGB { mix(c, 0.65, ink) }
    /// A tab showing its first line.
    static func tabPaper(_ c: RGB) -> RGB { mix(c, 0.18, paper) }
    /// Petal's ink on the paper.
    static func ink(_ c: RGB) -> RGB { mix(c, 0.62, black) }
}
