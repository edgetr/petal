import CoreGraphics
import Foundation

// The pure side of Petal Notes (PaperNotes.swift and the files beside it): the note file's format, where a note is
// stuck and which of its places fits what's in front, the tabs notes rest as on a window's edge, fading, iCloud's
// conflict copies, and the room an open note needs beside its window. No AppKit, so macos/checks/run.sh checks it on
// its own (with NoteLayout.swift, whose NoteTab and NoteRules it reuses for tabs).

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
    var desktop: Int? = nil
    var mode = ""
    /// Keys this Petal doesn't know (a later one's, or the person's own), written back as they were.
    var extra: [(key: String, value: String)] = []

    static func == (a: NoteStick, b: NoteStick) -> Bool {
        a.kind == b.kind && a.app == b.app && a.appName == b.appName && a.url == b.url && a.title == b.title && a.path == b.path
            && a.bookmark == b.bookmark && a.quote == b.quote && a.before == b.before && a.after == b.after && a.mac == b.mac
            && a.pid == b.pid && a.window == b.window && a.tabID == b.tabID && a.desktop == b.desktop && a.mode == b.mode
            && a.extra.map(\.key) == b.extra.map(\.key) && a.extra.map(\.value) == b.extra.map(\.value)
    }

    /// The same place, whatever was learned about it since (a new window number, a title).
    func samePlace(_ other: NoteStick) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .passage: return quote == other.quote && (url.isEmpty ? path == other.path : NoteRules.sameURL(url, other.url))
        case .tab: return tabID != nil && tabID == other.tabID ? true : NoteRules.sameURL(url, other.url)
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
    var desktop: Int? = nil
}

enum NoteMatch {
    /// Whether one place fits what's in front.
    static func fits(_ stick: NoteStick, _ scene: NoteScene) -> Bool {
        switch stick.kind {
        case .passage:
            if !stick.url.isEmpty, let tab = scene.tab { return NoteRules.samePage(stick.url, tab.url) }
            return !stick.path.isEmpty && stick.path == scene.file
        case .tab:
            guard let now = scene.tab, stick.app.isEmpty || stick.app == scene.app else { return false }
            // Its own tab while the browser runs (by its id, on this Mac), else its page, by its address.
            if let id = stick.tabID, stick.mac == scene.mac, stick.pid == scene.pid, let other = now.id { return id == other || NoteRules.sameURL(stick.url, now.url) }
            return NoteRules.sameURL(stick.url, now.url)
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
                if let desktop = place.desktop { fields.append(("desktop", "\(desktop)")) }
                for (key, value) in place.extra { fields.append((key, value)) }
                for (offset, field) in fields.enumerated() {
                    head.append((offset == 0 ? "  - " : "    ") + "\(field.0): \(field.1)")
                }
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

    private static func places(_ lines: [String]) -> [NoteStick] {
        var items: [[(String, String)]] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isItem = trimmed.hasPrefix("- ")
            let field = isItem ? String(trimmed.dropFirst(2)) : trimmed
            if isItem { items.append([]) }
            guard !items.isEmpty, let colon = field.firstIndex(of: ":") else { continue }
            items[items.count - 1].append((String(field[..<colon]), String(field[field.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
        return items.compactMap { fields in
            guard let kind = fields.first(where: { $0.0 == "kind" }).flatMap({ NoteStick.Kind(rawValue: scalar($0.1)) }) else { return nil }
            var stick = NoteStick(kind: kind)
            for (key, raw) in fields {
                let value = scalar(raw)
                switch key {
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
                case "desktop": stick.desktop = Int(value)
                default: stick.extra.append((key: key, value: raw))
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
