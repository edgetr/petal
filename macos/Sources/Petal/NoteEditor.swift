import AppKit
import ImageIO
import Observation
import SwiftUI

/// A link's card: its page's title and site, and the site's icon (Sites.swift). A card only shows what's cached;
/// a page is fetched only for an address the person pasted or typed themselves (`requested`, NoteShelf.linkFetch),
/// never for one merely shown in a note (opened from sync, say). The fetch streams: anything that isn't an HTML page
/// is refused from its content type before any of it is read, and reading stops at a fixed size or time. Off the
/// main thread; nothing is fetched while snapshotting.
@MainActor @Observable
final class LinkPreviews {
    static let shared = LinkPreviews()
    private(set) var titles: [String: String] = [:]
    @ObservationIgnored private var asked: Set<String> = []

    /// What's cached for an address; never a fetch.
    func title(_ url: String) -> String? { titles[url] }

    /// The person pasted or typed this address: its page's title is fetched, once.
    func requested(_ address: String) {
        guard !Headless.on, NoteShelf.linkFetch(address, own: true, cached: titles[address] != nil || asked.contains(address)),
              let url = URL(string: address) else { return }
        asked.insert(address)
        // Its site's icon with it (the same rule: a link the person added).
        Sites.shared.requestIcon(address)
        Task.detached(priority: .utility) {
            let title = await Self.fetchTitle(url)
            await MainActor.run { if let title { LinkPreviews.shared.titles[address] = title } }
        }
    }

    /// The page's title, read as a stream: a 200 HTML page only (its content type checked first), its first
    /// `NoteShelf.linkLimit` bytes at most (less once its head is in), within 10 seconds.
    nonisolated static func fetchTitle(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Petal", forHTTPHeaderField: "User-Agent")
        let deadline = Date().addingTimeInterval(10)
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request) else { return nil }
        let http = response as? HTTPURLResponse
        guard NoteShelf.linkResponse(status: http?.statusCode ?? 0, contentType: http?.value(forHTTPHeaderField: "Content-Type")) else {
            bytes.task.cancel()
            return nil
        }
        var data = Data()
        data.reserveCapacity(32_768)
        let headEnd = Data("</head>".utf8)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= NoteShelf.linkLimit || Date() > deadline { break }
                if data.count % 4096 == 0, data.range(of: headEnd, options: [], in: max(0, data.count - 4103)..<data.count) != nil { break }
            }
        } catch {}
        bytes.task.cancel()
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return title(in: html)
    }

    /// A page's title: its og:title, else its <title>.
    nonisolated static func title(in html: String) -> String? {
        let patterns = [#"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#, #"<title[^>]*>([^<]+)</title>"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let title = String(html[range]).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return String(title.prefix(120)) }
        }
        return nil
    }

    func preview(_ url: String, title: String) { titles[url] = title }
}

/// Notes' pictures, read off the main thread and kept while Petal runs, by where their link leads
/// (NoteShelf.pictureTarget). A link that leads out of the notes' root, through a symbolic link or to nothing that
/// reads as a picture is broken: a placeholder shows, never another file. Every arrival (a picture, or that it's
/// broken) is said with `arrived`, so the editors showing it lay it out and draw it again. A missing picture is read
/// again when the notes' folder watcher says a file it leads to appeared or changed, and on a 10-second timer that
/// runs only while a missing picture is on screen (NoteShelf.pictureRetry); drawing never asks again by itself.
/// Images are decoded off the main thread at the size they're shown (the paper's width at the screen's scale), and
/// live in a cache with a cost limit (`costLimit`); one evicted is read again when it's drawn, and since its size is
/// known that only draws its cell again (`redraw`: no layout, no arrival). Raw bytes follow one rule
/// (NoteShelf.keepBytes), weighed at every event: held while the picture's write is pending, or an open editor
/// contains it; a read checks it before keeping its bytes.
@MainActor @Observable
final class NotePictures {
    static let shared = NotePictures()
    static let arrived = Notification.Name("petal.notePictureArrived")
    /// A picture read again after its image was evicted: its cell is drawn again, nothing laid out.
    static let redraw = Notification.Name("petal.notePictureRedraw")
    /// About 200 MB of decoded pixels.
    static let costLimit = 200 * 1024 * 1024
    @ObservationIgnored private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = NotePictures.costLimit
        return cache
    }()
    /// Bumped whenever a picture comes in or turns broken, so views drawing pictures are drawn again.
    private(set) var version = 0
    /// Every picture put in the cache (it may have been evicted since), and its size: what the folder watcher reads
    /// again, and how big its cell is while its image is evicted.
    @ObservationIgnored private var sizes: [String: CGSize] = [:]
    var cacheLimit: Int { cache.totalCostLimit }

    func cached(_ key: String) -> NSImage? {
        _ = version
        return cache.object(forKey: key as NSString)
    }

    /// A picture's size as last decoded (its cell keeps it while the image is evicted).
    func size(_ key: String) -> CGSize? { sizes[key] }

    /// For checks: the cache let go of one image, as under memory pressure.
    func evict(_ key: String) { cache.removeObject(forKey: key as NSString) }

    private func put(_ image: NSImage, _ key: String) {
        let pixels = image.representations.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }.max { $0.width * $0.height < $1.width * $1.height }
            ?? image.size
        cache.setObject(image, forKey: key as NSString, cost: NoteShelf.imageCost(width: Int(pixels.width), height: Int(pixels.height)))
        sizes[key] = image.size
    }

    /// The pixels a picture is decoded at: the paper's width at the screen's scale.
    nonisolated static var shownPixels: Int { NoteShelf.shownPixels(width: 360, scale: 2) }

    /// A picture decoded at most `maxPixels` on its longer side (never its full size in memory), off the main thread.
    nonisolated static func downsample(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Broken, and when it was last tried.
    private(set) var broken: [String: Date] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    /// What each picture was asked for with (its link and the note's folder), to ask again.
    @ObservationIgnored private var sources: [String: (link: String, folder: URL)] = [:]
    /// The one visibility signal: the pictures of papers revealed and open now (the desk's, NoteShelf.picturesOnScreen).
    @ObservationIgnored var visible: () -> Set<String> = { [] }
    @ObservationIgnored private var retryTimer: Timer?
    /// Whether missing pictures are being retried (the timer runs, except headless).
    @ObservationIgnored private(set) var retrying = false
    @ObservationIgnored private var reconsidering = false
    @ObservationIgnored private var watching: NSObjectProtocol?
    @ObservationIgnored private var writes: NSObjectProtocol?
    @ObservationIgnored private var retired: NSObjectProtocol?

    init() {
        watching = NotificationCenter.default.addObserver(forName: NoteStore.filesChanged, object: nil, queue: .main) { [weak self] note in
            guard let paths = note.userInfo?["paths"] as? [String] else { return }
            MainActor.assumeIsolated { self?.filesChanged(paths) }
        }
        writes = NotificationCenter.default.addObserver(forName: NoteStore.picturesWritten, object: nil, queue: .main) { [weak self] note in
            guard let paths = note.userInfo?["paths"] as? [String] else { return }
            MainActor.assumeIsolated { self?.written(paths) }
        }
        retired = NotificationCenter.default.addObserver(forName: NoteStore.picturesRetired, object: nil, queue: .main) { [weak self] note in
            guard let paths = note.userInfo?["paths"] as? [String] else { return }
            MainActor.assumeIsolated { self?.written(paths) }
        }
    }

    /// Where a link leads from a note's folder, by the words alone: nil never reads anything.
    nonisolated static func target(_ link: String, in folder: URL) -> String? { NoteShelf.pictureTarget(link, noteFolder: folder.path) }

    func image(_ link: String, in folder: URL) -> NSImage? {
        guard let key = Self.target(link, in: folder) else { return nil }
        // Recorded first, even for a picture already in memory (a paste's): the watcher reads it again from it.
        sources[key] = (link, folder)
        if let image = cached(key) {
            // Shown by an open editor whose bytes aren't held yet (its image came from the cache): read once, off the
            // main thread, so a copy has them; its size is known, so that only draws its cell again.
            if held[key] == nil, holds(key) { read(key) }
            return image
        }
        // Broken: asked again only by the watcher or the retry timer, never by drawing (which would loop).
        guard broken[key] == nil else { return nil }
        read(key)
        return nil
    }

    func isBroken(_ link: String, in folder: URL) -> Bool { Self.target(link, in: folder).map { broken[$0] != nil } ?? true }

    /// A picture shown from an image already made (the sketch's, checks).
    func preview(_ file: URL, _ image: NSImage, data: Data? = nil) { previewBatch([(file, image, data)]) }

    // MARK: Raw bytes: one holding rule

    /// A picture's bytes while they're held, by where its link leads: what a copy carries without the disk.
    func bytes(_ key: String) -> Data? { held[key] }
    @ObservationIgnored private var held: [String: Data] = [:]
    /// Pictures whose files aren't written yet (accepted bytes): held until their write lands or is retired.
    @ObservationIgnored private var pendingWrites: Set<String> = []
    /// Open editors (weak); the pictures they contain, worked out again only after they change.
    @ObservationIgnored private let editors = NSHashTable<NSView>.weakObjects()
    @ObservationIgnored private var shownCache: Set<String>?

    private var shown: Set<String> {
        if let shownCache { return shownCache }
        var keys: Set<String> = []
        for case let editor as NoteTextView in editors.allObjects { keys.formUnion(editor.pictureKeys) }
        shownCache = keys
        return keys
    }

    /// The holding rule (NoteShelf.keepBytes): its write pending, or an open editor contains it.
    func holds(_ key: String) -> Bool { NoteShelf.keepBytes(key, pending: pendingWrites, shown: shown) }

    /// Every held byte weighed again by the rule.
    func release() { held = held.filter { holds($0.key) } }

    /// An editor opened.
    func register(_ editor: NSView) {
        editors.add(editor)
        editorChanged()
    }

    /// An editor closed: the bytes nothing needs any more go.
    func unregister(_ editor: NSView) {
        editors.remove(editor)
        editorChanged()
    }

    /// An open editor's text changed (pictures may have come or gone).
    func editorChanged() {
        shownCache = nil
        release()
    }

    /// Files written, or pictures removed for good (their write retired): the bytes held for them go unless an open
    /// editor contains them.
    func written(_ paths: [String]) {
        pendingWrites.subtract(paths)
        release()
    }

    /// Bytes accepted for pictures whose files aren't written yet (a paste, an import): held until their write
    /// lands; their images decoded from these bytes off the main thread when they're drawn.
    func accepted(_ items: [(file: URL, data: Data)]) {
        for item in items {
            held[item.file.path] = item.data
            pendingWrites.insert(item.file.path)
            broken[item.file.path] = nil
        }
    }

    var heldCount: Int { held.count }

    /// Read (again) what `key` was asked for with, decoded at the size it's shown: from its bytes when they're held,
    /// else from its file through the one link rule. An image already shown stays until the new one is in.
    /// `fromDisk`: a change the folder watcher reported, or a missing picture tried again: always the file (its
    /// held bytes and cached image both replaced). Only a re-read after eviction may use the held bytes.
    private func read(_ key: String, fromDisk: Bool = false) {
        guard let source = sources[key], !asked.contains(key) else { return }
        asked.insert(key)
        let inMemory = fromDisk ? nil : held[key], pixels = Self.shownPixels
        NoteStore.io.async {
            let file = inMemory == nil ? NoteStore.pictureFile(source.link, noteFolder: source.folder) : nil
            let data = inMemory ?? file.flatMap { NoteStore.coordinatedData($0) }
            let image = data.flatMap { Self.downsample($0, maxPixels: pixels) }
            // What a failed read means: gone (no file, refused, or not a picture) or unreadable for now.
            let outcome = NoteShelf.readOutcome(exists: file.map { FileManager.default.fileExists(atPath: $0.path) } ?? (inMemory != nil),
                                                read: data != nil, picture: image != nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.asked.remove(key)
                    if outcome == .gone, fromDisk, self.cached(key) != nil {
                        // Confirmed gone (or not a picture) on a refresh: its image and bytes dropped, the broken mark
                        // shown (and retried as usual).
                        self.evict(key)
                        self.held[key] = nil
                        self.broken[key] = Date()
                        self.version += 1
                        self.announce([key])
                        self.reconsider()
                    } else if outcome == .transient, self.cached(key) != nil {
                        // Unreadable for now: the old image kept, and the retry path asks again.
                        self.broken[key] = Date()
                        self.reconsider()
                    } else if let data, let image {
                        // Its bytes kept only by the rule (an open editor contains it, or its write is pending).
                        if self.holds(key) { self.held[key] = data } else { self.held[key] = nil }
                        let known = self.sizes[key] == image.size
                        self.put(image, key)
                        self.broken[key] = nil
                        self.version += 1
                        // Its size already known (read again after eviction): only its cell drawn again.
                        if known { NotificationCenter.default.post(name: Self.redraw, object: nil, userInfo: ["targets": [key]]) } else { self.announce([key]) }
                    } else if self.cached(key) == nil {
                        // Said once, when it turns broken: a redraw never asks again by itself.
                        let fresh = self.broken[key] == nil
                        self.broken[key] = Date()
                        self.version += 1
                        if fresh { self.announce([key]) }
                        self.reconsider()
                    }
                }
            }
        }
    }

    /// Arrivals said together: every one that comes within a short while (imports finishing one by one, reads)
    /// goes out as one notification, so each editor scans its pictures once for all of them.
    @ObservationIgnored private var announcing: Set<String> = []
    @ObservationIgnored private var announceScheduled = false

    private func announce(_ keys: [String]) {
        announcing.formUnion(keys)
        guard !announceScheduled else { return }
        announceScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated {
                self.announceScheduled = false
                let keys = self.announcing
                self.announcing = []
                NotificationCenter.default.post(name: Self.arrived, object: nil, userInfo: ["targets": Array(keys)])
            }
        }
    }

    /// Images already made (the sketch's, checks), stored together and said with one arrival. Bytes given with them
    /// are accepted bytes (held until written).
    func previewBatch(_ items: [(file: URL, image: NSImage, data: Data?)]) {
        guard !items.isEmpty else { return }
        for item in items {
            if let data = item.data {
                held[item.file.path] = data
                pendingWrites.insert(item.file.path)
            }
            put(item.image, item.file.path)
            broken[item.file.path] = nil
        }
        version += 1
        announce(items.map(\.file.path))
    }

    /// Files that appeared or changed under the notes' folder: every picture they touch is read again.
    func filesChanged(_ paths: [String]) {
        for key in NoteShelf.picturesTouched(events: paths, keys: Array(Set(sizes.keys).union(broken.keys))) where sources[key] != nil { read(key, fromDisk: true) }
    }

    /// A paper was revealed, hidden, opened or folded: the retry timer weighed again on the next turn (once for
    /// however many changes came together).
    func visibilityChanged() {
        guard !reconsidering else { return }
        reconsidering = true
        DispatchQueue.main.async { MainActor.assumeIsolated { self.reconsidering = false; self.reconsider() } }
    }

    /// The retry timer runs while some missing picture is on screen (NoteShelf.pictureRetry), and only then.
    private func reconsider() {
        retrying = NoteShelf.pictureRetry(broken: broken, onScreen: visible(), now: Date()).keepTimer
        if !retrying {
            retryTimer?.invalidate()
            retryTimer = nil
        } else if retryTimer == nil, !Headless.on {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.retryTick(now: Date()) }
            }
        }
    }

    /// One tick: the missing pictures on screen asked for again; none on screen, the timer stops. Returns what it
    /// asked for again.
    @discardableResult
    func retryTick(now: Date, onScreen given: Set<String>? = nil) -> [String] {
        let rule = NoteShelf.pictureRetry(broken: broken, onScreen: given ?? visible(), now: now)
        if !rule.keepTimer {
            retrying = false
            retryTimer?.invalidate()
            retryTimer = nil
        }
        for key in rule.retry { read(key, fromDisk: true) }
        return rule.retry
    }
}

extension NoteStore {
    nonisolated static func coordinatedData(_ url: URL) -> Data? {
        var data: Data?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { data = try? Data(contentsOf: $0) }
        return data
    }
}

// MARK: - The paper's text

/// The note's writing as the editor holds it: one paragraph per line of the file. Each paragraph says what it is
/// (`NoteRich.line`): a heading, a checkbox (with its box as the first character), a link's card or a picture (one
/// attachment), Petal's ink, or words. Inline links are link runs. `blocks` turns it back into the same Markdown.
enum NoteRich {
    static let line = NSAttributedString.Key("petal.noteLine")

    struct Style {
        var ink: NSColor          // the words
        var dim: NSColor          // the site under a card
        var petal: NSColor        // Petal's ink
        var accent: NSColor       // the notebook's color

        static let body = NSFont.systemFont(ofSize: 13.5)
        static func heading(_ level: Int) -> NSFont {
            NSFont.systemFont(ofSize: level == 1 ? 17 : level == 2 ? 15 : 14, weight: .bold)
        }
    }

    static func paragraph(_ level: Int = 0, ink: Bool = false) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        // The sketch's 1.45 line height for the words, tighter for headings.
        style.lineHeightMultiple = level > 0 ? 1.05 : 1.12
        style.paragraphSpacing = level > 0 ? 4 : 1
        if ink { style.firstLineHeadIndent = 11; style.headIndent = 11; style.paragraphSpacingBefore = 4; style.paragraphSpacing = 4 }
        return style
    }

    static func attributes(_ kind: String, _ style: Style) -> [NSAttributedString.Key: Any] {
        switch kind {
        case "h1", "h2", "h3":
            let level = Int(kind.dropFirst()) ?? 1
            return [.font: Style.heading(level), .foregroundColor: style.ink, .paragraphStyle: paragraph(level), .kern: -0.17, line: kind]
        case "ink":
            return [.font: Style.body, .foregroundColor: style.petal, .paragraphStyle: paragraph(ink: true), line: kind]
        default:
            return [.font: Style.body, .foregroundColor: style.ink, .paragraphStyle: paragraph(), line: kind]
        }
    }

    /// The ranges of the pictures in `text` whose link leads to one of `targets`: what an arrival lays out again,
    /// found in one pass however many arrived.
    static func pictureRanges(in text: NSAttributedString, targets: Set<String>) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let cell = (value as? NSTextAttachment)?.attachmentCell as? PictureCell, let to = cell.leadsTo, targets.contains(to) { ranges.append(range) }
        }
        return ranges
    }

    static func pictureRanges(in text: NSAttributedString, target: String) -> [NSRange] { pictureRanges(in: text, targets: [target]) }

    /// The editor's text for a note's body. `base`: the note's folder, for its pictures.
    @MainActor static func attributed(_ blocks: [NoteBlock], base: URL, style: Style) -> NSAttributedString {
        attributed(blocks, folder: NoteFolder(base), style: style)
    }

    /// The same, its pictures reading their links through `folder` (the editor's own: a move rebinds them all).
    @MainActor static func attributed(_ blocks: [NoteBlock], folder: NoteFolder, style: Style) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: attributes(kind(of: blocks[index - 1]), style))) }
            switch block {
            case .heading(let level, let text):
                result.append(inline(text, attributes(["h1", "h2", "h3"][min(2, max(0, level - 1))], style)))
            case .check(let done, let text):
                let attrs = attributes(done ? "check1" : "check0", style)
                result.append(attachment(CheckCell(done: done, color: style.accent), attrs))
                result.append(NSAttributedString(string: " ", attributes: attrs))
                result.append(inline(text, attrs))
            case .link(let url):
                result.append(attachment(LinkCell(url: url), attributes("link", style)))
            case .image(let path, let caption):
                result.append(attachment(PictureCell(path: path, folder: folder, caption: caption), attributes("image", style)))
            case .ink(let text):
                result.append(inline(text, attributes("ink", style)))
            case .bullet(let text):
                result.append(inline("- " + text, attributes("text", style)))
            case .text(let text):
                result.append(inline(text, attributes("text", style)))
            }
        }
        return result
    }

    static func kind(of block: NoteBlock) -> String {
        switch block {
        case .heading(let level, _): "h\(min(3, max(1, level)))"
        case .check(let done, _): done ? "check1" : "check0"
        case .link: "link"
        case .image: "image"
        case .ink: "ink"
        case .bullet, .text: "text"
        }
    }

    private static func attachment(_ cell: NSTextAttachmentCell, _ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = cell
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(attrs, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// Words with their inline links ([words](address), or a bare address) as link runs.
    static func inline(_ text: String, _ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)|(https?://[^\s)]+)"#) else {
            return NSAttributedString(string: text, attributes: attrs)
        }
        let ns = text as NSString
        var at = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > at { result.append(NSAttributedString(string: ns.substring(with: NSRange(location: at, length: match.range.location - at)), attributes: attrs)) }
            let words = match.range(at: 1).location != NSNotFound ? ns.substring(with: match.range(at: 1)) : ns.substring(with: match.range(at: 3))
            let address = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : words
            var linked = attrs
            if let url = URL(string: address) { linked[.link] = url }
            result.append(NSAttributedString(string: words, attributes: linked))
            at = match.range.location + match.range.length
        }
        if at < ns.length { result.append(NSAttributedString(string: ns.substring(from: at), attributes: attrs)) }
        return result
    }

    /// The editor's text back as the note's lines.
    /// A note's own pasteboard type: a selection copied or cut from a note, as the note's Markdown (cards as their
    /// link lines, pictures as their picture lines) with the note's folder and id, so a paste into a note rebuilds
    /// them. Other apps get plain text (`plainText`) beside it.
    static let fragmentType = NSPasteboard.PasteboardType("tech.edgetr.petal.note-fragment")

    /// A copied selection: its Markdown, the folder, id and notes root of the note it came from, and every
    /// picture's bytes in the order of its picture lines (pictures travel as bytes, like a pasted screenshot).
    /// Written as a binary property list, only when asked for (FragmentProvider), at most `fragmentLimit` bytes.
    struct Fragment: Codable, Equatable {
        var markdown: String
        var folder: String
        var note: String
        var root: String = ""
        var pictures: [Data] = []
    }

    /// About 100 MB: past it, the copy is refused (a cut deletes nothing). Lowered by checks.
    nonisolated(unsafe) static var fragmentLimit = 100 * 1024 * 1024

    nonisolated static func encode(_ fragment: Fragment) -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(fragment)
    }

    nonisolated static func decode(_ data: Data) -> Fragment? { try? PropertyListDecoder().decode(Fragment.self, from: data) }

    /// What a picture that can't be pasted becomes: a short line of words, never a link to something else.
    static func unpasted(_ caption: String) -> NoteBlock { .text(NoteText.unpasted(caption)) }

    /// What other apps get for a copied selection: its words, a card as its address, a picture as its caption (or
    /// nothing); never a picture's folder or file name.
    static func plainText(_ blocks: [NoteBlock]) -> String {
        blocks.compactMap { block -> String? in
            switch block {
            case .image(_, let caption): caption.isEmpty ? nil : caption
            case .link(let url): url
            default: block.markdown
            }
        }.joined(separator: "\n")
    }

    @MainActor static func blocks(_ text: NSAttributedString) -> [NoteBlock] {
        let ns = text.string as NSString
        var blocks: [NoteBlock] = []
        var location = 0
        repeat {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            var content = range
            if content.length > 0, ns.character(at: content.location + content.length - 1) == 10 { content.length -= 1 }
            blocks.append(contentsOf: split(text, content))
            location = range.location + range.length
        } while location < ns.length
        // A last line ending in a newline: one more, empty line.
        if ns.length > 0, ns.character(at: ns.length - 1) == 10 { blocks.append(.text("")) }
        return blocks
    }

    /// One line of the editor as the note's lines: a card or picture is a line of its own, so words typed before or
    /// after one (or a line joined to it by deleting the newline between) become lines of their own beside it,
    /// never lost.
    @MainActor private static func split(_ text: NSAttributedString, _ range: NSRange) -> [NoteBlock] {
        var cards: [(at: Int, block: NoteBlock)] = []
        text.enumerateAttribute(.attachment, in: range) { value, run, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            for at in run.location..<run.location + run.length {
                if let link = attachment.attachmentCell as? LinkCell { cards.append((at, .link(link.url))) }
                if let picture = attachment.attachmentCell as? PictureCell { cards.append((at, .image(path: picture.path, caption: picture.caption))) }
            }
        }
        guard !cards.isEmpty else { return [block(text, range)] }
        var out: [NoteBlock] = []
        var start = range.location
        func words(upTo end: Int) {
            let piece = NSRange(location: start, length: end - start)
            guard piece.length > 0 else { return }
            let string = (text.string as NSString).substring(with: piece).replacingOccurrences(of: "\u{FFFC}", with: "")
            if !string.trimmingCharacters(in: .whitespaces).isEmpty { out.append(block(text, piece)) }
        }
        for card in cards {
            words(upTo: card.at)
            out.append(card.block)
            start = card.at + 1
        }
        words(upTo: range.location + range.length)
        return out
    }

    @MainActor private static func block(_ text: NSAttributedString, _ range: NSRange) -> NoteBlock {
        // An empty line: its own newline says whether it's Petal's ink; anything else empty is an empty line.
        guard range.length > 0 else {
            let own = range.location < text.length ? text.attribute(line, at: range.location, effectiveRange: nil) as? String : nil
            return own == "ink" ? .ink("") : .text("")
        }
        let kind = text.attribute(line, at: range.location, effectiveRange: nil) as? String ?? "text"
        // The attachment that makes the line what it is.
        var cell: NSTextAttachmentCellProtocol?
        if range.length > 0, let attachment = text.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment {
            cell = attachment.attachmentCell
        }
        if let link = cell as? LinkCell { return .link(link.url) }
        if let picture = cell as? PictureCell { return .image(path: picture.path, caption: picture.caption) }
        var words = range
        if let check = cell as? CheckCell {
            words = NSRange(location: range.location + 1, length: max(0, range.length - 1))
            let string = text.attributedSubstring(from: words).string
            if string.hasPrefix(" ") { words = NSRange(location: words.location + 1, length: words.length - 1) }
            return .check(check.done, markdown(text, words))
        }
        let written = markdown(text, words)
        switch kind {
        case "h1": return .heading(1, written)
        case "h2": return .heading(2, written)
        case "h3": return .heading(3, written)
        case "ink": return .ink(written)
        default: return NoteBlock.parse(written).isPlainLine ? .text(written) : NoteBlock.parse(written)
        }
    }

    /// A range's words with its link runs as Markdown links (a bare address stays bare). Stray attachments drop out.
    private static func markdown(_ text: NSAttributedString, _ range: NSRange) -> String {
        var out = ""
        text.enumerateAttributes(in: range) { attrs, run, _ in
            var words = (text.string as NSString).substring(with: run).replacingOccurrences(of: "\u{FFFC}", with: "")
            if let url = (attrs[.link] as? URL)?.absoluteString ?? attrs[.link] as? String, !words.isEmpty, words != url {
                words = "[\(words)](\(url))"
            }
            out += words
        }
        return out
    }
}

private extension NoteBlock {
    /// Typed as words, a line that reads as a heading, checkbox or card stays words until the editor makes it one.
    var isPlainLine: Bool {
        switch self {
        case .text, .bullet: true
        default: false
        }
    }
}

// MARK: - Attachments

/// A checkbox at the start of a line; clicking it ticks it.
final class CheckCell: NSTextAttachmentCell {
    var done: Bool
    let color: NSColor

    init(done: Bool, color: NSColor) {
        self.done = done
        self.color = color
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError() }

    override func cellSize() -> NSSize { NSSize(width: 15, height: 15) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -2.5) }

    override func draw(withFrame frame: NSRect, in view: NSView?) {
        let box = NSRect(x: frame.minX + 0.5, y: frame.minY + 1, width: 13, height: 13)
        let path = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
        if done {
            color.setFill()
            path.fill()
            let tick = NSBezierPath()
            let flip: CGFloat = view?.isFlipped == true ? 1 : -1
            tick.move(to: NSPoint(x: box.minX + 3.2, y: box.midY))
            tick.line(to: NSPoint(x: box.minX + 5.6, y: box.midY + 2.6 * flip))
            tick.line(to: NSPoint(x: box.maxX - 3, y: box.midY - 3 * flip))
            tick.lineWidth = 1.7
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            NSColor(white: 0, alpha: 0.32).setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }
    }

    override func wantsToTrackMouse() -> Bool { true }

    override func trackMouse(with event: NSEvent, in frame: NSRect, of view: NSView?, atCharacterIndex index: Int, untilMouseUp flag: Bool) -> Bool {
        guard event.type == .leftMouseDown, let text = view as? NoteTextView else { return false }
        text.toggleCheck(at: index)
        return true
    }
}

/// A link alone on its line, as a card: the page's title, its site and the site's icon.
final class LinkCell: NSTextAttachmentCell {
    let url: String
    init(url: String) {
        self.url = url
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError() }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint,
                            characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: -6, width: max(120, textContainer.size.width - textContainer.lineFragmentPadding * 2 - 2), height: 46)
    }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -6) }

    override func draw(withFrame frame: NSRect, in view: NSView?) {
        let card = frame.insetBy(dx: 0.5, dy: 2)
        let shape = NSBezierPath(roundedRect: card, xRadius: 9, yRadius: 9)
        NSColor(white: 1, alpha: 0.75).setFill()
        shape.fill()
        NSColor(white: 0, alpha: 0.12).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        let icon = NSRect(x: card.minX + 9, y: card.midY - 15, width: 30, height: 30)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: icon, xRadius: 7, yRadius: 7).addClip()
        if let image = MainActor.assumeIsolated({ Sites.shared.cachedIcon(url) }) {
            NSColor.white.setFill()
            icon.fill()
            image.draw(in: icon.insetBy(dx: 3, dy: 3), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSColor(white: 0.85, alpha: 1).setFill()
            icon.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let title = MainActor.assumeIsolated { LinkPreviews.shared.title(url) } ?? NoteText.shortAddress(url)
        let host = NoteText.host(url)
        let left = icon.maxX + 9
        let words = NSRect(x: left, y: card.minY, width: card.maxX - left - 9, height: card.height)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(white: 0.13, alpha: 1)]
        let siteAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.53, alpha: 1)]
        let flipped = view?.isFlipped ?? true
        let top = flipped ? words.midY - 15 : words.midY + 1
        let bottom = flipped ? words.midY + 1 : words.midY - 15
        (title as NSString).draw(with: NSRect(x: left, y: top, width: words.width, height: 15), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: titleAttrs)
        (host as NSString).draw(with: NSRect(x: left, y: bottom, width: words.width, height: 15), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: siteAttrs)
    }

    override func wantsToTrackMouse() -> Bool { true }
    override func trackMouse(with event: NSEvent, in frame: NSRect, of view: NSView?, atCharacterIndex index: Int, untilMouseUp flag: Bool) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 1, let address = URL(string: url) else { return false }
        NSWorkspace.shared.open(address)
        return true
    }
}

/// A picture beside the note (pasted or dropped), with its caption.
/// The folder a note's file is in, shared by its editor and every picture in it: when the note moves, the editor
/// changes it once and every picture reads its link from the new folder (nothing is stored per picture).
final class NoteFolder {
    var url: URL
    init(_ url: URL) { self.url = url }
}

final class PictureCell: NSTextAttachmentCell {
    let path: String
    /// The note's folder its link is read from, as it is now (shared with its editor).
    let note: NoteFolder
    let caption: String
    var folder: URL { note.url }
    /// Where its link leads now (nil: out of the notes' root, absolute, or a web address; never read).
    var leadsTo: String? { NotePictures.target(path, in: note.url) }
    init(path: String, folder: NoteFolder, caption: String) {
        self.path = path
        self.note = folder
        self.caption = caption
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError() }

    private var picture: NSImage? { MainActor.assumeIsolated { NotePictures.shared.image(path, in: folder) } }

    private func size(width: CGFloat) -> NSSize {
        // The image, or its size as last decoded while it's evicted (so a re-read never changes the layout).
        let known = picture?.size ?? leadsTo.flatMap { key in MainActor.assumeIsolated { NotePictures.shared.size(key) } }
        guard let known, known.width > 0 else { return NSSize(width: width, height: 96) }
        return NSSize(width: width, height: min(200, max(60, width * known.height / known.width)))
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint,
                            characterIndex charIndex: Int) -> NSRect {
        let size = size(width: max(120, textContainer.size.width - textContainer.lineFragmentPadding * 2 - 2))
        return NSRect(x: 0, y: -6, width: size.width, height: size.height + 12)
    }

    override func draw(withFrame frame: NSRect, in view: NSView?) {
        let rect = frame.insetBy(dx: 0, dy: 6)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if let image = picture {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            NSColor(white: 0, alpha: 0.06).setFill()
            rect.fill()
            // Broken (it leads out of the notes, or isn't there): a mark, never another file.
            if MainActor.assumeIsolated({ NotePictures.shared.isBroken(path, in: folder) }),
               let mark = NSImage(systemSymbolName: "photo.badge.exclamationmark", accessibilityDescription: "Picture can't be shown") {
                let size = NSSize(width: 22, height: 18)
                mark.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                          from: .zero, operation: .sourceOver, fraction: 0.35, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0, alpha: 0.15).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        guard !caption.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.white]
        let size = (caption as NSString).size(withAttributes: attrs)
        let flipped = view?.isFlipped ?? true
        let chip = NSRect(x: rect.minX + 8, y: flipped ? rect.maxY - 6 - size.height - 2 : rect.minY + 6, width: min(rect.width - 16, size.width + 12), height: size.height + 2)
        NSColor(white: 0, alpha: 0.38).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        (caption as NSString).draw(with: chip.insetBy(dx: 6, dy: 1), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attrs)
    }
}

// MARK: - The editor

/// The note's text view: Markdown made paper. "# " at the start of a line makes a heading, "[] " a checkbox; Return on
/// a checkbox line starts another (on an empty one, it ends the list); an address pasted alone becomes a card;
/// pictures pasted or dropped are saved beside the note. Petal's ink has a line down its left.
final class NoteTextView: NSTextView {
    var style = NoteRich.Style(ink: .black, dim: .gray, petal: .black, accent: .systemBlue)
    var changed: () -> Void = {}
    /// Helpers (NoteHelpers): Return at the end of a line that calls one runs it; the names the @ menu offers and
    /// chips bind to; the notebook's color the mentions are drawn in. The @ menu and the chips' state.
    var helperReturn: (String) -> Void = { _ in }
    var mentionNames: () -> (notes: [String], notebooks: [String], place: String) = { ([], [], "") }
    var tint = NoteInk.RGB(r: 0, g: 0.48, b: 1)
    let mentions = MentionState()
    var escape: () -> Void = {}
    /// The note's folder, which its picture links are read from.
    /// Shared with every picture in this editor's text (NoteFolder).
    let folderRef = NoteFolder(URL(fileURLWithPath: "/"))
    var noteFolder: URL {
        get { folderRef.url }
        set {
            guard newValue != folderRef.url else { return }
            folderRef.url = newValue
            // The note moved: its pictures lead somewhere else now; the holding rule weighed again first, then they're
            // laid out and drawn again, the text and the selection untouched.
            MainActor.assumeIsolated { NotePictures.shared.editorChanged() }
            repictured()
        }
    }
    /// This editor's own undo history (never the window's, shared with other papers), cleared whenever its text
    /// comes from outside. The Edit menu's Undo and Redo reach it through the delegate (`undo(for:)`).
    let history = UndoManager()

    /// What a note editor's delegate answers for `undoManager(for:)`: the editor's own history.
    static func undo(for view: NSTextView) -> UndoManager? { (view as? NoteTextView)?.history }

    /// Text that came from outside (a sync, a tool, a reload): it replaces what's here and the undo history goes, so
    /// ⌘Z never applies an old range to new text.
    func replaceFromOutside(_ text: NSAttributedString) {
        textStorage?.setAttributedString(text)
        history.removeAllActions()
        MainActor.assumeIsolated { NotePictures.shared.editorChanged() }
    }

    /// Typed, pasted, undone: the pictures it contains may have changed (the holding rule weighs them again).
    override func didChangeText() {
        super.didChangeText()
        MainActor.assumeIsolated {
            NotePictures.shared.editorChanged()
            decorateMentions()
            updateMentionMenu()
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        MainActor.assumeIsolated { if mentions.menu?.isVisible == true { updateMentionMenu() } }
    }

    /// The @ menu takes the arrows, Tab and Escape while it's open (Return picks, in insertNewline).
    override func doCommand(by selector: Selector) {
        let handled = MainActor.assumeIsolated { mentionCommand(selector) }
        if !handled { super.doCommand(by: selector) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        MainActor.assumeIsolated { drawMentionChips() }
    }

    /// Remove on the paper, while this editor is open: those pictures' attachments deleted here, as an edit saved
    /// like any typing (so nothing typed and not saved yet brings them back): only the attachment, and its line's
    /// break only when nothing else is on that line (NoteShelf.removalRange). One undoable change: its undo puts
    /// them back and calls `restore` (their unsaved bytes accepted again), its redo removes them again and calls
    /// `retire`. Returns how many it removed.
    @discardableResult
    func removePictures(named names: Set<String>, restore: @escaping (String) -> Void = { _ in }, retire: @escaping (String) -> Void = { _ in }) -> Int {
        guard let storage = textStorage else { return 0 }
        var ranges: [NSRange] = []
        let ns = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let cell = (value as? NSTextAttachment)?.attachmentCell as? PictureCell, names.contains((cell.path as NSString).lastPathComponent) else { return }
            let line = ns.lineRange(for: range)
            ranges.append(NoteShelf.removalRange(attachment: range, line: line, lineText: ns.substring(with: line)))
        }
        guard !ranges.isEmpty else { return 0 }
        let undo = undoManager ?? history
        undo.beginUndoGrouping()
        // Registered first, so it runs last on undo (after the text is back): the bytes accepted again.
        Self.registerRestore(undo, target: self, restore: restore, retire: retire)
        // From the end, so earlier ranges stay where they are.
        for range in ranges.reversed() where shouldChangeText(in: range, replacementString: "") {
            storage.replaceCharacters(in: range, with: "")
            didChangeText()
        }
        undo.setActionName("Remove Picture")
        undo.endUndoGrouping()
        changed()
        return ranges.count
    }

    /// Undo of a Remove: `restore` (the pictures' bytes accepted again); its redo: `retire`, and so on. Each is given
    /// the editor's note id as it is when it runs (the note may have moved, or been given its own id, meanwhile),
    /// never a path captured when it was removed.
    private static func registerRestore(_ undo: UndoManager, target: NoteTextView, restore: @escaping (String) -> Void, retire: @escaping (String) -> Void) {
        undo.registerUndo(withTarget: target) { view in
            MainActor.assumeIsolated { restore(view.noteID) }
            let again = view.undoManager ?? view.history
            again.registerUndo(withTarget: view) { view in
                MainActor.assumeIsolated {
                    retire(view.noteID)
                    registerRestore(view.undoManager ?? view.history, target: view, restore: restore, retire: retire)
                }
            }
        }
    }

    /// Every picture laid out and drawn again (its folder changed); the paper measured again.
    func repictured() {
        guard let storage = textStorage, let layoutManager else { return }
        var any = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard (value as? NSTextAttachment)?.attachmentCell is PictureCell else { return }
            any = true
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
        if any { needsDisplay = true; remeasure() }
    }
    /// Measures the paper again (a picture that arrived changes its height).
    var remeasure: () -> Void = {}
    private var pictureObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let pictureObserver { NotificationCenter.default.removeObserver(pictureObserver) }
        if let redrawObserver { NotificationCenter.default.removeObserver(redrawObserver) }
        pictureObserver = nil
        redrawObserver = nil
        guard window != nil else { return }
        pictureObserver = NotificationCenter.default.addObserver(forName: NotePictures.arrived, object: nil, queue: .main) { [weak self] note in
            guard let targets = note.userInfo?["targets"] as? [String] else { return }
            MainActor.assumeIsolated { _ = self?.pictureArrived(Set(targets)) }
        }
        redrawObserver = NotificationCenter.default.addObserver(forName: NotePictures.redraw, object: nil, queue: .main) { [weak self] note in
            guard let targets = note.userInfo?["targets"] as? [String] else { return }
            MainActor.assumeIsolated { self?.pictureRedrawn(Set(targets)) }
        }
    }
    private var redrawObserver: NSObjectProtocol?

    /// Pictures read again after eviction: their cells drawn again only (their size is known; nothing laid out).
    func pictureRedrawn(_ targets: Set<String>) {
        guard let storage = textStorage, let layoutManager else { return }
        for range in NoteRich.pictureRanges(in: storage, targets: targets) { layoutManager.invalidateDisplay(forCharacterRange: range) }
    }

    /// A picture this editor shows arrived (or turned out broken): its attachment laid out, measured and drawn again,
    /// and the paper measured again. Returns the ranges it did that for.
    @discardableResult
    func pictureArrived(_ target: String) -> [NSRange] { pictureArrived([target]) }

    /// Where its pictures' links lead now: what keeps their bytes held while it's open.
    var pictureKeys: Set<String> {
        guard let storage = textStorage else { return [] }
        var keys: Set<String> = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let key = ((value as? NSTextAttachment)?.attachmentCell as? PictureCell)?.leadsTo { keys.insert(key) }
        }
        return keys
    }

    /// How many times this editor scanned its pictures for arrivals (one scan per batch).
    private(set) var scans = 0

    @discardableResult
    func pictureArrived(_ targets: Set<String>) -> [NSRange] {
        guard let storage = textStorage, let layoutManager else { return [] }
        scans += 1
        let ranges = NoteRich.pictureRanges(in: storage, targets: targets)
        guard !ranges.isEmpty else { return [] }
        for range in ranges {
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
        if let textContainer { layoutManager.ensureLayout(for: textContainer) }
        needsDisplay = true
        remeasure()
        return ranges
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return }
        style.accent.withAlphaComponent(0.4).setFill()
        storage.enumerateAttribute(NoteRich.line, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value as? String == "ink" else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            NSRect(x: textContainerOrigin.x + textContainer.lineFragmentPadding, y: bounds.minY + textContainerOrigin.y + 1, width: 2, height: bounds.height - 2).fill()
        }
    }

    /// A checkbox ticked or unticked: an undoable change (its undo toggles it back and registers the redo), saved and
    /// drawn again whichever way it goes.
    func toggleCheck(at index: Int) {
        guard let storage = textStorage, index < storage.length,
              let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment,
              let cell = attachment.attachmentCell as? CheckCell else { return }
        cell.done.toggle()
        let line = (storage.string as NSString).lineRange(for: NSRange(location: index, length: 0))
        storage.addAttribute(NoteRich.line, value: cell.done ? "check1" : "check0", range: line)
        layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: index, length: 1))
        let undo = undoManager ?? history
        undo.registerUndo(withTarget: self) { view in MainActor.assumeIsolated { view.toggleCheck(at: index) } }
        undo.setActionName(cell.done ? "Tick" : "Untick")
        changed()
    }

    private var lineKind: String {
        guard let storage = textStorage else { return "text" }
        let ns = storage.string as NSString
        let line = ns.lineRange(for: NSRange(location: min(selectedRange().location, ns.length), length: 0))
        if line.location < storage.length { return storage.attribute(NoteRich.line, at: line.location, effectiveRange: nil) as? String ?? "text" }
        return typingAttributes[NoteRich.line] as? String ?? "text"
    }

    private var lineRange: NSRange {
        let ns = (textStorage?.string ?? "") as NSString
        return ns.lineRange(for: NSRange(location: min(selectedRange().location, ns.length), length: 0))
    }

    override func insertNewline(_ sender: Any?) {
        // The @ menu open: Return picks what's selected in it.
        if MainActor.assumeIsolated({ pickMention() }) { return }
        // Return at the very end of a line that calls a helper (only here, the person's own key): it's asked, once the
        // line is saved.
        let calling = MainActor.assumeIsolated { helperLine() }
        defer {
            if let calling {
                flushNow()
                let ask = helperReturn
                DispatchQueue.main.async { ask(calling) }
            }
        }
        let kind = lineKind
        let line = lineRange
        let words = ((textStorage?.string ?? "") as NSString).substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC}")))
        if kind.hasPrefix("check"), words.isEmpty {
            // Return on an empty checkbox ends the list: the line becomes words.
            replace(line: line, with: NSAttributedString(string: "", attributes: NoteRich.attributes("text", style)), kind: "text")
            return
        }
        super.insertNewline(sender)
        let next = kind.hasPrefix("check") ? "check0" : "text"
        typingAttributes = NoteRich.attributes(next, style)
        if next == "check0" {
            let box = NSTextAttachment()
            box.attachmentCell = CheckCell(done: false, color: style.accent)
            let start = NSMutableAttributedString(attachment: box)
            start.append(NSAttributedString(string: " "))
            start.addAttributes(NoteRich.attributes("check0", style), range: NSRange(location: 0, length: start.length))
            insertText(start, replacementRange: selectedRange())
        } else {
            // The new line is words, whatever the one before was (a heading).
            let here = lineRange
            if here.length == 0 || (textStorage?.string as NSString?)?.substring(with: here) == "\n" {
                textStorage?.addAttributes(NoteRich.attributes("text", style), range: NSRange(location: here.location, length: min(here.length, (textStorage?.length ?? 0) - here.location)))
            }
        }
        changed()
    }

    private func replace(line: NSRange, with text: NSAttributedString, kind: String) {
        var range = line
        if range.length > 0, ((textStorage?.string ?? "") as NSString).character(at: range.location + range.length - 1) == 10 { range.length -= 1 }
        guard shouldChangeText(in: range, replacementString: text.string) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + text.length, length: 0))
        // What's typed next keeps the line's kind, even on a line left empty ("# " typed alone is an empty heading).
        typingAttributes = NoteRich.attributes(kind, style)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard (string as? String) == " " else { return }
        // Markdown typed at the start of a line becomes what it says.
        let line = lineRange
        let text = ((textStorage?.string ?? "") as NSString).substring(with: line)
        let bare = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let marks: [(String, String)] = [("- [ ] ", "check0"), ("### ", "h3"), ("[ ] ", "check0"), ("## ", "h2"), ("[] ", "check0"), ("# ", "h1"), ("> ", "ink")]
        guard lineKind == "text",
              let (mark, kind) = marks.first(where: { bare.hasPrefix($0.0) && selectedRange().location == line.location + $0.0.utf16.count })
        else { return }
        let rest = String(bare.dropFirst(mark.count))
        let made = NSMutableAttributedString()
        if kind == "check0" {
            let box = NSTextAttachment()
            box.attachmentCell = CheckCell(done: false, color: style.accent)
            made.append(NSAttributedString(attachment: box))
            made.append(NSAttributedString(string: " "))
        }
        made.append(NSAttributedString(string: rest))
        made.addAttributes(NoteRich.attributes(kind, style), range: NSRange(location: 0, length: made.length))
        replace(line: line, with: made, kind: kind)
        changed()
    }

    // MARK: Pasting and dropping

    /// The note this editor shows (its id): whether a pasted picture is already its own.
    var noteID = ""

    /// What a copy did: written, nothing selected, or refused (its pictures past the size bound: nothing written,
    /// and a cut deletes nothing).
    enum CopyResult: Equatable { case copied, nothing, tooMany, loading }

    /// Said on the paper when a copy is refused.
    static let tooManyPictures = "Too many pictures to copy at once."
    /// Said when a cut is refused because a picture in it hasn't loaded (a copy writes it as a line instead).
    static let stillLoading = "A picture is still loading — try again in a moment."
    var say: (String) -> Void = { _ in }

    /// The selection, written at once as the note's own fragment and as plain text for other apps, with no disk
    /// access: each picture's bytes as held (an open editor holds those of every picture it contains once loaded);
    /// one not loaded yet is copied as "(A picture couldn't be copied.)". Past the size bound, nothing is written.
    /// The fragment is offered lazily (FragmentProvider), encoded from these bytes only when a note pastes it.
    /// `cutting`: a cut never takes a picture whose bytes aren't in memory yet (it would be lost): refused, nothing
    /// written.
    @discardableResult
    func copySelection(to board: NSPasteboard, cutting: Bool = false) -> CopyResult {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage, NSMaxRange(range) <= storage.length else { return .nothing }
        let blocks = NoteRich.blocks(storage.attributedSubstring(from: range))
        var bytes: [Int: Data] = [:]
        var pictures = 0
        for (index, block) in blocks.enumerated() {
            guard case .image(let path, _) = block else { continue }
            pictures += 1
            guard let key = NotePictures.target(path, in: noteFolder), let held = MainActor.assumeIsolated({ NotePictures.shared.bytes(key) }) else { continue }
            bytes[index] = held
        }
        if cutting, bytes.count < pictures { return .loading }
        guard let body = NoteShelf.fragmentBody(blocks, bytes: bytes, limit: NoteRich.fragmentLimit) else { return .tooMany }
        let fragment = NoteRich.Fragment(markdown: body.markdown, folder: noteFolder.path, note: noteID,
                                         root: noteFolder.deletingLastPathComponent().path, pictures: body.pictures)
        FragmentProvider.offer(fragment, plain: NoteRich.plainText(blocks), on: board)
        return .copied
    }

    override func copy(_ sender: Any?) {
        switch copySelection(to: .general) {
        case .copied: break
        case .tooMany: say(Self.tooManyPictures)
        case .loading: say(Self.stillLoading)
        case .nothing: super.copy(sender)
        }
    }

    override func cut(_ sender: Any?) {
        // Written, then the selection deleted, in the same step; refused (too much, or a picture still loading),
        // nothing is written or deleted.
        _ = performCut(to: .general)
    }

    /// A cut to `board`: what it did (for checks too).
    @discardableResult
    func performCut(to board: NSPasteboard) -> CopyResult {
        let result = copySelection(to: board, cutting: true)
        switch result {
        case .copied: delete(nil)
        case .tooMany: say(Self.tooManyPictures)
        case .loading: say(Self.stillLoading)
        case .nothing: super.cut(nil)
        }
        return result
    }

    /// How pictures pasted as bytes are taken by this note: the screenshot paste's path (the desk's accept: in
    /// memory and journaled at once, the file written in the background), giving each its line.
    var acceptPictures: ([(ext: String, data: Data, caption: String)]) -> [(path: String, file: URL, caption: String)]? = { _ in nil }
    /// Saves what's here now (and its journal snapshot), not a moment later.
    var flushNow: () -> Void = {}

    /// A note's fragment on the pasteboard, decoded (a binary property list of at most the size bound: its picture
    /// bytes are copied, not decoded) and put in at once over the selection, as one undoable change: its words,
    /// cards and pictures. Into the same note from the same notes folder, a picture line already pointing into this
    /// note's own folder stays as it is (NoteShelf.keepsOwnPicture); every other picture is taken from its bytes by
    /// the screenshot paste's path; their images are decoded off the main thread when drawn. Undo takes it out like
    /// any text; redo puts it back. False when there's no fragment.
    @discardableResult
    func pasteNote(from board: NSPasteboard) -> Bool {
        guard board.types?.contains(NoteRich.fragmentType) == true, let data = board.data(forType: NoteRich.fragmentType),
              let fragment = NoteRich.decode(data) else { return false }
        let range = selectedRange()
        let selected = NSMaxRange(range) <= (string as NSString).length ? (string as NSString).substring(with: range) : ""
        insertFragment(fragment, range: range, selected: selected)
        return true
    }

    private func insertFragment(_ fragment: NoteRich.Fragment, range: NSRange, selected: String) {
        var blocks = NoteBlock.blocks(fragment.markdown)
        var items: [(ext: String, data: Data, caption: String)] = []
        var at: [Int] = []
        var n = 0
        for (index, block) in blocks.enumerated() {
            guard case .image(let path, let caption) = block else { continue }
            let bytes = n < fragment.pictures.count ? fragment.pictures[n] : nil
            n += 1
            if let name = NoteShelf.keepsOwnPicture(path, noteFolder: noteFolder.path, noteID: noteID, fragmentNote: fragment.note, fragmentRoot: fragment.root) {
                blocks[index] = .image(path: NoteShelf.pictureLink(id: noteID, name: name), caption: caption)
            } else if let bytes {
                let ext = (path as NSString).pathExtension.lowercased()
                items.append((ext.isEmpty ? "png" : ext, bytes, caption))
                at.append(index)
            } else {
                blocks[index] = NoteRich.unpasted(caption)
            }
        }
        let accepted = items.isEmpty ? [] : acceptPictures(items).flatMap { $0.count == items.count ? $0 : nil }
        for (k, index) in at.enumerated() {
            guard case .image(_, let caption) = blocks[index] else { continue }
            blocks[index] = accepted.map { .image(path: $0[k].path, caption: caption) } ?? NoteRich.unpasted(caption)
        }
        let target = NoteShelf.pasteRange(at: range.location, length: range.length, selected: selected, text: string)
        insertText(NoteRich.attributed(blocks, folder: folderRef, style: style), replacementRange: target)
        if !items.isEmpty { flushNow() }
    }

    override func paste(_ sender: Any?) {
        if pasteNote(from: .general) { return }
        if pastePictures(NSPasteboard.general) { return }
        if let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), NoteText.isAddress(text), !text.contains("\n") {
            insertCard(text)
            return
        }
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if pastePictures(sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    /// Pictures on the pasteboard (a screenshot, a crop, image files): handed to the desk, which reads and decodes
    /// them off the main thread and puts each on its own line where the cursor was, here or, if this editor is gone
    /// by then, at the end of the note.
    var importPictures: ((NoteImport) -> Void)?

    private func pastePictures(_ board: NSPasteboard) -> Bool {
        let kinds = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp"]
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { kinds.contains($0.pathExtension.lowercased()) }
        let anyFiles = board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let png = files.isEmpty && !anyFiles ? board.data(forType: .png) : nil
        let tiff = files.isEmpty && !anyFiles && png == nil ? board.data(forType: .tiff) : nil
        guard !files.isEmpty || png != nil || tiff != nil, let importPictures else { return false }
        // The whole selection goes with it: replaced by the pictures when they're in, if it's still that text.
        let range = selectedRange()
        importPictures(NoteImport(files: files, png: png, tiff: tiff, at: range.location, length: range.length,
                                  selected: (string as NSString).substring(with: range)))
        return true
    }

    /// A picture saved for the note, on its own line at `at` (the end, past it; -1: at the cursor), replacing the
    /// `length` characters there when they still say `selected` (what was selected when it was pasted; text that
    /// changed meanwhile is never replaced: NoteShelf.pasteRange). False when it can't be.
    func insertPicture(path: String, file: URL, caption: String, at: Int, length: Int = 0, selected: String = "") -> Bool {
        guard let storage = textStorage else { return false }
        if at >= 0 { setSelectedRange(NoteShelf.pasteRange(at: at, length: length, selected: selected, text: storage.string)) }
        insertLine(PictureCell(path: path, folder: folderRef, caption: caption), kind: "image")
        return true
    }

    func insertCard(_ url: String) {
        // Pasted by the person: its page's title may be fetched.
        MainActor.assumeIsolated { LinkPreviews.shared.requested(url) }
        insertLine(LinkCell(url: url), kind: "link")
    }

    /// An attachment on a line of its own, at the cursor.
    private func insertLine(_ cell: NSTextAttachmentCell, kind: String) {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = cell
        let line = NSMutableAttributedString()
        let at = selectedRange().location
        let ns = (textStorage?.string ?? "") as NSString
        if at > 0, ns.character(at: at - 1) != 10 { line.append(NSAttributedString(string: "\n", attributes: NoteRich.attributes("text", style))) }
        let card = NSMutableAttributedString(attachment: attachment)
        card.addAttributes(NoteRich.attributes(kind, style), range: NSRange(location: 0, length: card.length))
        line.append(card)
        line.append(NSAttributedString(string: "\n", attributes: NoteRich.attributes(kind, style)))
        insertText(line, replacementRange: selectedRange())
        typingAttributes = NoteRich.attributes("text", style)
        changed()
    }

    override func cancelOperation(_ sender: Any?) {
        if MainActor.assumeIsolated({ mentions.menu?.isVisible == true }) { MainActor.assumeIsolated { closeMentionMenu() }; return }
        escape()
    }
}

/// An open editor, as the desk reaches it: save what's typed now; put a picture in.
@MainActor
final class NoteEditorHandle {
    var flush: () -> Void = {}
    /// Typed and not saved yet: the note is fenced against a read of the folder only then (NoteShelf.fenceEditor).
    var busy: () -> Bool = { false }
    var insert: (String, URL, String, Int, Int, String) -> Bool = { _, _, _, _, _, _ in false }
    /// Remove on the paper while this editor is open: those pictures deleted here, as typing is; undo calls the
    /// first closure (their bytes accepted again), redo the second (removed again).
    var removePictures: (Set<String>, @escaping (String) -> Void, @escaping (String) -> Void) -> Void = { _, _, _ in }
}

/// The editor in SwiftUI: the note's lines in, the note's lines out (saved a moment after the person stops typing).
struct NoteEditorView: NSViewRepresentable {
    let paper: PaperNote
    let style: NoteRich.Style
    var focus: Bool
    let height: (CGFloat) -> Void
    /// Saves what's typed, made on the given base; returns the next base (nil: it can't be written).
    let save: (String, String?) -> String?
    /// Hands the desk this editor (nil once it goes): to save what's typed now, and put pictures in.
    let register: (NoteEditorHandle?) -> Void
    /// Pictures pasted or dropped: the desk reads them and puts them in, here or (once this editor is gone) in the note.
    let importPictures: (NoteImport) -> Void
    let escape: () -> Void
    /// Its typing saved and nothing waits: a newer version deferred while it was dirty is taken now.
    var idle: () -> Void = {}

    /// Whether two note ids are the same note now (an id-less note given its own is followed: NoteShelf.editorKeeps).
    var sameNote: (String, String, String) -> Bool = { a, _, b in a == b }
    /// Said on the paper (a copy refused).
    var say: (String) -> Void = { _ in }
    /// Pictures pasted as bytes (a copy from a note): taken by the screenshot paste's path.
    var acceptPictures: ([(ext: String, data: Data, caption: String)]) -> [(path: String, file: URL, caption: String)]? = { _ in nil }
    /// Return at the end of a line that calls a helper (@Petal): the line.
    var helperReturn: (String) -> Void = { _ in }
    /// What the @ menu offers and the chips bind to.
    var names: () -> (notes: [String], notebooks: [String], place: String) = { ([], [], "") }
    var accent: NSColor = .controlAccentColor
    var tint = NoteInk.RGB(r: 0, g: 0.48, b: 1)

    final class Coordinator: NSObject, NSTextViewDelegate {
        /// The Edit menu's Undo and Redo (and typing's undo) use the editor's own history.
        func undoManager(for view: NSTextView) -> UndoManager? { NoteTextView.undo(for: view) }

        var saveLater: DispatchWorkItem?
        var key = ""
        var noteID = ""
        /// The file it was read from (an id-less note's id means something only with it).
        var instance = ""
        var body = ""
        /// The note's file as this editor last had it: what its edits are made on.
        var base: String?
        var parent: NoteEditorView
        /// Typed and not saved yet (NoteShelf.EditorMarker): set as the person types, cleared when the save runs.
        var marker = NoteShelf.EditorMarker()
        init(_ parent: NoteEditorView) { self.parent = parent }

        @MainActor func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NoteTextView else { return }
            schedule(view)
        }

        @MainActor func schedule(_ view: NoteTextView) {
            measure(view)
            saveLater?.cancel()
            marker.typed()
            let work = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view, let storage = view.textStorage else { return }
                // The save runs: no longer dirty, then a version that waited meanwhile is taken (the folder read again).
                self.saveLater = nil
                let body = NoteBlock.body(NoteRich.blocks(storage))
                if body != self.body {
                    self.body = body
                    if let next = self.parent.save(body, self.base) { self.base = next }
                }
                _ = self.marker.saved()
                self.parent.idle()
            }
            saveLater = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }

        @MainActor func flush(_ view: NoteTextView) {
            guard let work = saveLater else { return }
            saveLater = nil
            guard !work.isCancelled else { return }
            work.perform()
            work.cancel()
        }

        @MainActor func measure(_ view: NoteTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + view.textContainerInset.height * 2
            parent.height(ceil(used))
        }

        @MainActor func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let text = NoteTextView(frame: .zero, textContainer: container)
        text.isRichText = true
        text.importsGraphics = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.isAutomaticLinkDetectionEnabled = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.delegate = context.coordinator
        text.linkTextAttributes = [.foregroundColor: style.accent, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        text.registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = text
        load(text, context.coordinator)
        return scroll
    }

    private func load(_ text: NoteTextView, _ coordinator: Coordinator) {
        coordinator.parent = self
        text.style = style
        text.escape = escape
        text.changed = { [weak coordinator, weak text] in
            guard let coordinator, let text else { return }
            MainActor.assumeIsolated { coordinator.schedule(text) }
        }
        coordinator.key = paper.key
        coordinator.noteID = paper.noteID
        coordinator.instance = paper.instance
        coordinator.body = paper.file.body
        coordinator.base = paper.revision
        text.importPictures = importPictures
        text.acceptPictures = acceptPictures
        text.noteID = paper.noteID
        let handle = NoteEditorHandle()
        handle.flush = { [weak coordinator, weak text] in
            guard let coordinator, let text else { return }
            MainActor.assumeIsolated { coordinator.flush(text) }
        }
        handle.busy = { [weak coordinator] in MainActor.assumeIsolated { coordinator?.marker.dirty == true } }
        handle.insert = { [weak text] path, file, caption, at, length, selected in
            guard let text else { return false }
            return MainActor.assumeIsolated { text.insertPicture(path: path, file: file, caption: caption, at: at, length: length, selected: selected) }
        }
        handle.removePictures = { [weak text] names, restore, retire in
            guard let text else { return }
            MainActor.assumeIsolated { _ = text.removePictures(named: names, restore: restore, retire: retire) }
        }
        text.say = say
        text.helperReturn = helperReturn
        text.mentionNames = names
        text.tint = tint
        text.flushNow = { [weak coordinator, weak text] in
            guard let coordinator, let text else { return }
            MainActor.assumeIsolated { coordinator.flush(text) }
        }
        register(handle)
        let base = paper.url.deletingLastPathComponent()
        text.noteFolder = base
        text.remeasure = { [weak coordinator, weak text] in
            guard let coordinator, let text else { return }
            MainActor.assumeIsolated { coordinator.measure(text) }
        }
        NotePictures.shared.register(text)
        // From outside (a sync, a tool, a reload, another note): its undo history goes with the old text.
        text.replaceFromOutside(NoteRich.attributed(NoteBlock.blocks(paper.file.body), folder: text.folderRef, style: style))
        text.decorateMentions()
        text.typingAttributes = NoteRich.attributes("text", style)
        text.insertionPointColor = style.ink
        DispatchQueue.main.async { coordinator.measure(text) }
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NoteTextView else { return }
        // The callbacks follow the note (moved, renamed on disk) on every update; the text is left alone.
        text.importPictures = importPictures
        text.acceptPictures = acceptPictures
        text.noteID = paper.noteID
        text.noteFolder = paper.url.deletingLastPathComponent()
        text.escape = escape
        text.helperReturn = helperReturn
        text.mentionNames = names
        text.tint = tint
        let coordinator = context.coordinator
        // Another note in this paper, or the file changed elsewhere while the person isn't typing here: read again.
        // A newer version (another Mac, another editor) taken at once by an idle editor, typing here or not; one with
        // typing not saved yet keeps it (it's saved on the file it was made on, NoteShelf.editorTakesNewer).
        let elsewhere = NoteShelf.editorTakesNewer(bodyChanged: paper.file.body != coordinator.body, dirty: coordinator.marker.dirty)
        // The same note, whatever happened to its identity since (moved, renamed, given its own id): what's typed
        // stays, and is saved through the note as it is now (this view's save), never through a key that's gone.
        let same = sameNote(coordinator.noteID, coordinator.instance, paper.noteID)
        if same {
            coordinator.parent = self
            coordinator.key = paper.key
            coordinator.noteID = paper.noteID
            if !paper.instance.isEmpty { coordinator.instance = paper.instance }
            if elsewhere {
                // The keyboard here: the cursor stays where it was (within the new text).
                let focused = text.window?.firstResponder === text
                let cursor = text.selectedRange()
                load(text, coordinator)
                if focused {
                    let kept = NoteShelf.keptSelection(location: cursor.location, length: cursor.length, newLength: (text.string as NSString).length)
                    text.setSelectedRange(NSRange(location: kept.location, length: kept.length))
                }
            }
        } else {
            // Another note: what's typed and not saved yet is saved first, into the note it was typed in and on the
            // file as it was then (a newer version on disk makes it the conflict copy beside it). Neither is lost.
            coordinator.flush(text)
            coordinator.parent = self
            load(text, coordinator)
        }
        if focus, let window = text.window, window.firstResponder !== text {
            DispatchQueue.main.async { window.makeFirstResponder(text) }
        }
        if !focus, coordinator.marker.dirty { coordinator.flush(text) }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let text = scroll.documentView as? NoteTextView {
            MainActor.assumeIsolated {
                text.closeMentionMenu()
                coordinator.flush(text)
                coordinator.parent.register(nil)
                // Closed: the pictures it showed let their bytes go once nothing else needs them.
                NotePictures.shared.unregister(text)
            }
        }
    }
}


/// A note fragment offered on the pasteboard lazily: plain text at once for other apps, the fragment itself encoded
/// (a binary property list) only when something asks for it, a note pasting it. Kept until the pasteboard is done
/// with it.
final class FragmentProvider: NSObject, NSPasteboardItemDataProvider {
    nonisolated(unsafe) static var current: FragmentProvider?
    let fragment: NoteRich.Fragment
    /// How many times it was encoded (for checks: never before something asks).
    private(set) var encodes = 0

    init(_ fragment: NoteRich.Fragment) { self.fragment = fragment }

    @MainActor static func offer(_ fragment: NoteRich.Fragment, plain: String, on board: NSPasteboard) {
        let provider = FragmentProvider(fragment)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [NoteRich.fragmentType])
        item.setString(plain, forType: .string)
        board.clearContents()
        board.writeObjects([item])
        current = provider
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == NoteRich.fragmentType, let data = NoteRich.encode(fragment) else { return }
        encodes += 1
        item.setData(data, forType: type)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        if Self.current === self { Self.current = nil }
    }
}
