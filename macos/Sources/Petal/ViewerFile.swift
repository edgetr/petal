import CoreGraphics
import Foundation

// The pure side of Petal's viewer (Viewer.swift and the files beside it): which files it shows and how (PDFKit, or
// macOS's own Quick Look preview), the path an agent names (a regular file the person owns, never through a link
// out of the home folder), which note sits where in the margin, a preview's pages, the names of copies (versions
// and a PDF with its notes as comments), what a comment says, and the reading lens's paragraph. No AppKit, so
// macos/checks/run.sh checks it on its own (with NoteFile.swift for the notes' places).

/// What a page of a document is called: a deck's slides, every other document's pages.
enum ViewerUnit: String, Sendable {
    case page, slide

    var word: String { rawValue }
    var title: String { self == .slide ? "Slide" : "Page" }
}

/// How the viewer shows a file: PDFKit for a PDF; anything else through macOS's own Quick Look preview (its pages
/// exported when Quick Look gives them, else Quick Look's own view), never an Office engine of Petal's.
enum ViewerKind: Equatable, Sendable {
    case pdf
    case quickLook(ViewerUnit)

    var unit: ViewerUnit {
        switch self {
        case .pdf: .page
        case .quickLook(let unit): unit
        }
    }

    static let slides: Set<String> = ["pptx", "ppt", "pptm", "pps", "ppsx", "potx", "key", "kth", "odp"]
    static let pages: Set<String> = ["docx", "doc", "docm", "dotx", "rtf", "odt", "pages", "xlsx", "xls", "xlsm", "csv", "numbers", "ods",
                                     "txt", "md", "markdown", "png", "jpg", "jpeg", "heic", "tiff", "tif", "gif"]

    /// By the file's extension; nil for a file the viewer doesn't show.
    static func of(_ path: String) -> ViewerKind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if slides.contains(ext) { return .quickLook(.slide) }
        if pages.contains(ext) { return .quickLook(.page) }
        return nil
    }

    static let shows = "Petal's viewer shows PDFs and documents: Word, PowerPoint, Keynote, Excel, Pages, Numbers, text and pictures."
}

// MARK: - The path an agent names

/// A path an agent names for the viewer (`petal_view`, the PDF comments tool): only a regular file the person owns,
/// and never one reached through a symbolic link from inside the home folder to outside it.
enum ViewerPath {
    enum Refusal: Error, Equatable, CustomStringConvertible {
        case notAbsolute, missing, notRegular, notOwned, linkOutOfHome, notShown

        var description: String {
            switch self {
            case .notAbsolute: "Give the file's full path (it starts with / or ~/)."
            case .missing: "There's no file there."
            case .notRegular: "That isn't a file Petal's viewer can open (a folder, a package or something else)."
            case .notOwned: "That file isn't the person's own: Petal's viewer opens only their files."
            case .linkOutOfHome: "That path goes through a link out of the home folder: Petal doesn't follow it."
            case .notShown: ViewerKind.shows
            }
        }
    }

    /// The path as written, "~/" for the home folder, standardized ("..", "."); nil when it isn't absolute.
    static func standardized(_ given: String, home: String) -> String? {
        var path = given.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + String(path.dropFirst(1)) }
        guard path.hasPrefix("/") else { return nil }
        return (path as NSString).standardizingPath
    }

    static func within(_ path: String, _ folder: String) -> Bool {
        let folder = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == folder || path.hasPrefix(folder + "/")
    }

    /// The decision, from what the disk said: `resolved` is the path with every link followed (nil: nothing there),
    /// `regular` and `owner` what the file it leads to is. A path inside the home folder must stay inside it once its
    /// links are followed (a link there never leads Petal out); a path outside it is the system's own (/tmp, /var).
    /// `homes`: the home folder as written and as the disk spells it (a home under a link).
    static func decide(standardized: String, resolved: String?, homes: [String], regular: Bool, owner: UInt32, me: UInt32) -> Result<String, Refusal> {
        guard let resolved else { return .failure(.missing) }
        let inside = { (path: String) in homes.contains { within(path, $0) } }
        if inside(standardized), !inside(resolved) { return .failure(.linkOutOfHome) }
        guard regular else { return .failure(.notRegular) }
        guard owner == me else { return .failure(.notOwned) }
        guard ViewerKind.of(resolved) != nil else { return .failure(.notShown) }
        return .success(resolved)
    }

    /// Checks `given` on the disk (off the main thread): the file it leads to, every link followed, or why not.
    static func check(_ given: String, home: String = NSHomeDirectory()) -> Result<URL, Refusal> {
        guard let path = standardized(given, home: home) else { return .failure(.notAbsolute) }
        let resolved: String? = path.withCString { pointer in
            guard let real = realpath(pointer, nil) else { return nil }
            defer { free(real) }
            return String(cString: real)
        }
        // The home folder as the disk spells it too (a home under a link): compared both ways.
        let realHome: String = home.withCString { pointer in
            guard let real = realpath(pointer, nil) else { return home }
            defer { free(real) }
            return String(cString: real)
        }
        var info = stat()
        let found = resolved.map { stat($0, &info) == 0 } ?? false
        let regular = found && (info.st_mode & S_IFMT) == S_IFREG
        let decided = decide(standardized: path, resolved: found ? resolved : nil, homes: [home, realHome],
                             regular: regular, owner: info.st_uid, me: getuid())
        return decided.map { URL(fileURLWithPath: $0) }
    }
}

// MARK: - Notes in the margin

/// Which of a note's places puts it in the viewer's margin for a file, and where.
enum ViewerMatch {
    /// The most specific file anchor on `path` (or the same file under another spelling, `also`): a passage with
    /// its bounds, then a page or slide, then the file. nil when none is on it.
    static func place(_ places: [NoteStick], path: String, also: [String] = []) -> Int? {
        let paths = Set([path] + also)
        func rank(_ stick: NoteStick) -> Int {
            if stick.bounds != nil, stick.page != nil { return 0 }
            if stick.page != nil || stick.slide != nil { return 1 }
            return 2
        }
        let fitting: [Int] = places.indices.filter { places[$0].kind == .file && paths.contains(places[$0].path) }
        return fitting.min { rank(places[$0]) < rank(places[$1]) }
    }

    /// The page a file anchor is on (0-based), when it says one and the document has it.
    static func pageIndex(_ stick: NoteStick, count: Int) -> Int? {
        guard let number = stick.page ?? stick.slide, number >= 1, number <= count else { return nil }
        return number - 1
    }

    /// The margin's order: notes on the page shown first (by where on it), then those on other pages in page order,
    /// then those on the whole file. `page` nil: one continuous document, all in page order.
    static func order(_ items: [(id: String, page: Int?, top: Double)], current: Int?) -> [String] {
        items.sorted { a, b in
            func group(_ item: (id: String, page: Int?, top: Double)) -> Int {
                guard let page = item.page else { return 2 }
                return current == nil || page == current ? 0 : 1
            }
            let (ga, gb) = (group(a), group(b))
            if ga != gb { return ga < gb }
            if (a.page ?? 0) != (b.page ?? 0) { return (a.page ?? 0) < (b.page ?? 0) }
            if a.top != b.top { return a.top < b.top }
            return a.id < b.id
        }.map(\.id)
    }
}

/// The margin's papers lined up with their passages: each at its passage's height where it can be, pushed down
/// below the one above when they'd overlap, never above `top`.
enum ViewerMargin {
    static func layout(_ wanted: [(id: String, y: CGFloat, height: CGFloat)], top: CGFloat, gap: CGFloat = 12) -> [String: CGFloat] {
        var placed: [String: CGFloat] = [:]
        var floor = top
        for item in wanted.sorted(by: { ($0.y, $0.id) < ($1.y, $1.id) }) {
            let y = max(item.y, floor)
            placed[item.id] = y
            floor = y + item.height + gap
        }
        return placed
    }

    /// The sketch's dashed line from a passage's highlight (its right edge, halfway down) to its paper (its left
    /// edge, 28 points down), as a curve's four points.
    static func pin(from words: CGRect, to paper: CGRect) -> [CGPoint] {
        let start = CGPoint(x: words.maxX, y: words.midY)
        let end = CGPoint(x: paper.minX, y: paper.minY + 28)
        let reach = max(30, (end.x - start.x) / 2)
        return [start, CGPoint(x: start.x + reach, y: start.y), CGPoint(x: end.x - reach, y: end.y), end]
    }
}

// MARK: - A preview's pages

/// A document Quick Look shows as one long page (Word's, a spreadsheet's) cut into pages at the ends of its blocks,
/// never through a line.
enum ViewerPages {
    /// Each page's top and bottom: as much as fits in `height`, ending where a block ends; a block taller than a
    /// page is cut at the page's height. At most `limit` pages.
    static func cut(bottoms: [CGFloat], height: CGFloat, total: CGFloat, limit: Int = 500) -> [(top: CGFloat, bottom: CGFloat)] {
        guard height > 1, total > 0 else { return [] }
        let ends = bottoms.filter { $0 > 0 && $0 <= total }.sorted()
        var pages: [(top: CGFloat, bottom: CGFloat)] = []
        var top: CGFloat = 0
        while top < total - 0.5, pages.count < limit {
            let room = top + height
            var bottom = room >= total ? total : (ends.last { $0 > top + 1 && $0 <= room } ?? room)
            bottom = min(bottom, total)
            pages.append((top, bottom))
            top = bottom
        }
        return pages
    }

    /// Which rendering Quick Look gave, by what the preview holds: one PDF (iWork's), slides as blocks of their
    /// own (Office's decks), or one long page (Office's documents).
    enum Shape: Equatable { case pdf(String), slides, flowing, none }

    static func shape(mime: String, html: String) -> Shape {
        if mime == "application/pdf" { return .pdf("") }
        guard mime == "text/html" else { return .none }
        // iWork: an image of a PDF attachment, the whole document.
        if let range = html.range(of: #"<img src="(Attachment[0-9]+\.pdf)""#, options: .regularExpression) {
            let match = html[range]
            let name = match.dropFirst("<img src=\"".count).dropLast()
            return .pdf(String(name))
        }
        if html.contains("class=\"slide\"") { return .slides }
        return .flowing
    }
}

// MARK: - Copies

/// The names of the copies the viewer makes: versions in a temporary folder, a PDF with its notes as comments beside
/// the original. A name never takes one already there.
enum ViewerCopies {
    static func free(_ stem: String, ext: String, taken: Set<String>) -> String {
        let tail = ext.isEmpty ? "" : "." + ext
        var name = stem + tail
        var n = 2
        while taken.contains(name.lowercased()) || taken.contains(name) {
            name = "\(stem) \(n)\(tail)"
            n += 1
        }
        return name
    }

    static func version(original: String, label: String, taken: Set<String>) -> String {
        let ext = (original as NSString).pathExtension
        let stem = ((original as NSString).deletingPathExtension as NSString).lastPathComponent
        return free(stem + " (" + NoteText.fileName(label) + ")", ext: ext, taken: taken)
    }

    static func withNotes(original: String, taken: Set<String>) -> String {
        let stem = ((original as NSString).deletingPathExtension as NSString).lastPathComponent
        return free(stem + " (with notes)", ext: "pdf", taken: taken)
    }

    static func beforeNotes(original: String, taken: Set<String>) -> String {
        let stem = ((original as NSString).deletingPathExtension as NSString).lastPathComponent
        return free(stem + " (before notes)", ext: "pdf", taken: taken)
    }

    /// At most 6 versions, each with a label (its name in a few words).
    static func labels(_ wanted: [String]) -> [String] {
        Array(wanted.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(6))
    }
}

/// What a note says as a comment in a PDF: its words as plain text (checkboxes as ☐ and ☑, a link as its address,
/// a picture as "(picture)"), at most 2,000 characters.
enum ViewerComments {
    static func text(_ body: String) -> String {
        let lines = NoteBlock.blocks(body).map { block -> String in
            switch block {
            case .check(let done, let words): (done ? "☑ " : "☐ ") + NoteText.plain(words)
            case .image: "(picture)"
            case .bullet(let words): "• " + NoteText.plain(words)
            default: NoteText.plain(block.words)
            }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 2000 ? String(text.prefix(1999)) + "…" : text
    }

    /// Where a note's comment goes: a passage where it is in the PDF now (`passage`, found again by its words:
    /// ViewerPassages), highlighted; else a sticky note at its page's top-left corner, or the first page's for a note
    /// on the whole file, a passage that moved, or a page the PDF hasn't any more. Never a highlight from coordinates
    /// alone.
    static func spot(_ stick: NoteStick, passage: (page: Int, bounds: CGRect)?, pages: Int, pageSize: (Int) -> CGSize) -> (page: Int, bounds: CGRect?, corner: CGPoint)? {
        guard pages > 0 else { return nil }
        if let passage, passage.page >= 0, passage.page < pages {
            let b = passage.bounds
            return (passage.page, b, CGPoint(x: max(0, b.minX - 22), y: b.maxY))
        }
        let page = stick.quote.isEmpty ? ViewerMatch.pageIndex(stick, count: pages) ?? 0 : 0
        let size = pageSize(page)
        return (page, nil, CGPoint(x: 18, y: max(0, size.height - 40)))
    }

    /// A note's words as a comment says them: redacted whole first (`redact`: the vault's redaction), then made
    /// plain and cut, so a secret is never cut in two before it's looked for.
    static func text(_ body: String, redact: (String) -> String) -> String { text(redact(body)) }
}

// MARK: - Passages, found again by their words

/// A passage in a document, found again by its words, never by the coordinates it was saved with: the one place in
/// the document's pages its whole quote is, told apart by the words before and after it (Phase 1's rule,
/// NoteMatch.pick). Not there, or two places as likely: it moved (no highlight, on the file).
enum ViewerPassages {
    /// The page (0-based) and the quote's range in that page's text (UTF-16, as PDFKit counts), or nil.
    static func find(_ stick: NoteStick, in pages: [String]) -> (page: Int, range: NSRange)? {
        guard !stick.quote.isEmpty, let found = NoteMatch.pick(quote: stick.quote, before: stick.before, after: stick.after, in: pages) else { return nil }
        return (found.text, NSRange(found.range, in: pages[found.text]))
    }
}

// MARK: - Secrets, looked for in the whole text

/// What's taken from a page's text (a passage and the words around it, the lens's paragraph) is cut only after the
/// whole page was checked against the vault: `secrets` are the character ranges the vault's index finds in the
/// whole text (UIMap.SecretIndex.spans), so a secret is never cut in two before it's looked for.
enum ViewerSecrets {
    /// A passage (at most `limit` characters) and the words around it (`context` each side), from a page's text:
    /// nil when any secret touches the passage or the words kept with it. `range`: the selection, UTF-16.
    static func passage(_ text: String, range: NSRange, secrets: [Range<Int>], context: Int = 80, limit: Int = 500) -> (quote: String, before: String, after: String)? {
        guard let span = characters(text, range), !span.isEmpty else { return nil }
        let all = Array(text)
        let end = min(span.upperBound, span.lowerBound + limit)
        let kept = max(0, span.lowerBound - context)..<min(all.count, end + context)
        // The whole selection is checked, even past what's kept of it.
        let checked = kept.lowerBound..<max(kept.upperBound, span.upperBound)
        guard !secrets.contains(where: { $0.overlaps(checked) }) else { return nil }
        return (String(all[span.lowerBound..<end]), String(all[kept.lowerBound..<span.lowerBound]), String(all[end..<kept.upperBound]))
    }

    /// The part of a page's text at `range` (UTF-16) with every secret in it shown as `hidden`, the secrets found in
    /// the whole text first.
    static func cut(_ text: String, range: NSRange, secrets: [Range<Int>], hidden: String) -> String? {
        guard let span = characters(text, range) else { return nil }
        let all = Array(text)
        var out = ""
        var at = span.lowerBound
        while at < span.upperBound {
            if let secret = secrets.first(where: { $0.contains(at) }) {
                out += hidden
                at = secret.upperBound
            } else {
                out.append(all[at])
                at += 1
            }
        }
        return out
    }

    /// A UTF-16 range as characters.
    static func characters(_ text: String, _ range: NSRange) -> Range<Int>? {
        guard let found = Range(range, in: text) else { return nil }
        let start = text.distance(from: text.startIndex, to: found.lowerBound)
        return start..<(start + text.distance(from: found.lowerBound, to: found.upperBound))
    }
}

// MARK: - Writing into the person's files

/// A write into the person's folder (a PDF's comments) lands only on the file it was made from: its asker still
/// there, and the file the same (its identity, size, date and every byte) as when it was read. Decided inside the
/// coordinated write, right before the change.
enum ViewerWrites {
    enum Land: Equatable { case land, hungUp, changed }

    static func land(live: Bool, base: (stamp: ViewerUpdated.Stamp, bytes: Data), now: (stamp: ViewerUpdated.Stamp?, bytes: Data?)) -> Land {
        guard live else { return .hungUp }
        guard now.stamp == base.stamp, now.bytes == base.bytes else { return .changed }
        return .land
    }
}

// MARK: - Keeping up

/// "Updated just now" on the viewer's bar after the file changed on disk.
enum ViewerUpdated {
    static func label(_ changed: Date?, now: Date) -> String? {
        guard let changed else { return nil }
        let seconds = now.timeIntervalSince(changed)
        if seconds < 60 { return "Updated just now" }
        if seconds < 3600 { return "Updated \(Int(seconds / 60)) min ago" }
        return nil
    }

    /// The file as the disk has it (its size, date and identity): a different one is a change to show.
    struct Stamp: Equatable, Sendable {
        var size: Int64
        var modified: TimeInterval
        var inode: UInt64
    }
}

// MARK: - The reading lens

/// A note in the margin that follows the selection: the paragraph a selection is in, and an answer kept short.
enum ViewerLens {
    /// The paragraph holding `range` in a page's text: from the line break before it to the one after it.
    static func paragraph(_ text: String, around range: Range<String.Index>) -> Range<String.Index> {
        let start = text[..<range.lowerBound].lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
        let end = text[range.upperBound...].firstIndex(where: \.isNewline) ?? text.endIndex
        return start..<end
    }

    /// An answer as the lens shows it beside a paragraph: a few lines, at most `limit` characters.
    static func short(_ answer: String, limit: Int = 280) -> String {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
