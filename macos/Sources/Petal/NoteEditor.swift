import AppKit
import Observation
import SwiftUI

/// A link's card: its page's title and site, and the site's icon (Sites.swift). Fetched once per address, off the
/// main thread; nothing is fetched for a private app's page or while snapshotting.
@MainActor @Observable
final class LinkPreviews {
    static let shared = LinkPreviews()
    private(set) var titles: [String: String] = [:]
    @ObservationIgnored private var asked: Set<String> = []

    func title(_ url: String) -> String? {
        if let title = titles[url] { return title }
        fetch(url)
        return nil
    }

    private func fetch(_ address: String) {
        guard !Headless.on, !asked.contains(address), let url = URL(string: address), ["http", "https"].contains(url.scheme ?? "") else { return }
        asked.insert(address)
        Task.detached(priority: .utility) {
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.setValue("Petal", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
                  let html = String(data: data.prefix(300_000), encoding: .utf8) ?? String(data: data.prefix(300_000), encoding: .isoLatin1) else { return }
            let title = Self.title(in: html)
            await MainActor.run { if let title { LinkPreviews.shared.titles[address] = title } }
        }
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

/// Pictures beside notes, read off the main thread and kept while Petal runs.
@MainActor @Observable
final class NotePictures {
    static let shared = NotePictures()
    private(set) var images: [URL: NSImage] = [:]
    @ObservationIgnored private var asked: Set<URL> = []

    func image(_ url: URL) -> NSImage? {
        if let image = images[url] { return image }
        guard !asked.contains(url) else { return nil }
        asked.insert(url)
        NoteStore.io.async {
            let data = NoteStore.coordinatedData(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let data, let image = NSImage(data: data) { self.images[url] = image } else { self.asked.remove(url) }
                }
            }
        }
        return nil
    }

    func preview(_ url: URL, _ image: NSImage) { images[url] = image }
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

    /// The editor's text for a note's body. `base`: the note's folder, for its pictures.
    @MainActor static func attributed(_ blocks: [NoteBlock], base: URL, style: Style) -> NSAttributedString {
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
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appending(path: path)
                result.append(attachment(PictureCell(path: path, file: url, caption: caption), attributes("image", style)))
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
    @MainActor static func blocks(_ text: NSAttributedString) -> [NoteBlock] {
        let ns = text.string as NSString
        var blocks: [NoteBlock] = []
        var location = 0
        repeat {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            var content = range
            if content.length > 0, ns.character(at: content.location + content.length - 1) == 10 { content.length -= 1 }
            blocks.append(block(text, content))
            location = range.location + range.length
        } while location < ns.length
        // A last line ending in a newline: one more, empty line.
        if ns.length > 0, ns.character(at: ns.length - 1) == 10 { blocks.append(.text("")) }
        return blocks
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
        if let image = MainActor.assumeIsolated({ Sites.shared.icon(url) }) {
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
final class PictureCell: NSTextAttachmentCell {
    let path: String
    let file: URL
    let caption: String
    init(path: String, file: URL, caption: String) {
        self.path = path
        self.file = file
        self.caption = caption
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError() }

    private func size(width: CGFloat) -> NSSize {
        let image = MainActor.assumeIsolated { NotePictures.shared.image(file) }
        guard let image, image.size.width > 0 else { return NSSize(width: width, height: 96) }
        return NSSize(width: width, height: min(200, max(60, width * image.size.height / image.size.width)))
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
        if let image = MainActor.assumeIsolated({ NotePictures.shared.image(file) }) {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            NSColor(white: 0, alpha: 0.06).setFill()
            rect.fill()
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
    /// Saves a picture beside the note and returns its path as the note writes it, and the file.
    var savePicture: ((Data, String) -> (path: String, file: URL)?)?
    var changed: () -> Void = {}
    var escape: () -> Void = {}

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

    func toggleCheck(at index: Int) {
        guard let storage = textStorage, index < storage.length,
              let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment,
              let cell = attachment.attachmentCell as? CheckCell else { return }
        cell.done.toggle()
        let line = (storage.string as NSString).lineRange(for: NSRange(location: index, length: 0))
        storage.addAttribute(NoteRich.line, value: cell.done ? "check1" : "check0", range: line)
        layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: index, length: 1))
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

    override func paste(_ sender: Any?) {
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

    /// Pictures on the pasteboard (a screenshot, a crop, image files) saved beside the note, each on its own line.
    /// The files are read and decoded off the main thread; they go in where the cursor was once they're ready.
    private func pastePictures(_ board: NSPasteboard) -> Bool {
        let kinds = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp"]
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { kinds.contains($0.pathExtension.lowercased()) }
        let anyFiles = board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let png = files.isEmpty && !anyFiles ? board.data(forType: .png) : nil
        let tiff = files.isEmpty && !anyFiles && png == nil ? board.data(forType: .tiff) : nil
        guard !files.isEmpty || png != nil || tiff != nil, savePicture != nil else { return false }
        let at = selectedRange()
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [(Data, String, String, NSImage?)] = []
            for file in files {
                if let data = try? Data(contentsOf: file) { found.append((data, file.pathExtension.lowercased(), file.deletingPathExtension().lastPathComponent, NSImage(data: data))) }
            }
            if let png { found.append((png, "png", "", NSImage(data: png))) }
            if let tiff, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) {
                found.append((data, "png", "", NSImage(data: data)))
            }
            let ready = found
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, let savePicture = self.savePicture else { return }
                    let length = self.textStorage?.length ?? 0
                    self.setSelectedRange(NSRange(location: min(at.location, length), length: 0))
                    for (data, ext, caption, image) in ready {
                        guard let saved = savePicture(data, ext) else { continue }
                        if let image { NotePictures.shared.preview(saved.file, image) }
                        self.insertLine(PictureCell(path: saved.path, file: saved.file, caption: caption), kind: "image")
                    }
                }
            }
        }
        return true
    }

    func insertCard(_ url: String) { insertLine(LinkCell(url: url), kind: "link") }

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

    override func cancelOperation(_ sender: Any?) { escape() }
}

/// The editor in SwiftUI: the note's lines in, the note's lines out (saved a moment after the person stops typing).
struct NoteEditorView: NSViewRepresentable {
    let paper: PaperNote
    let style: NoteRich.Style
    var focus: Bool
    let height: (CGFloat) -> Void
    /// Saves what's typed, made on the given base; returns the next base (nil: it can't be written).
    let save: (String, String?) -> String?
    /// Hands the desk a way to save what's typed now (nil once the editor goes).
    let register: ((() -> Void)?) -> Void
    let picture: (Data, String) -> (path: String, file: URL)?
    let escape: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var saveLater: DispatchWorkItem?
        var key = ""
        var noteID = ""
        var body = ""
        /// The note's file as this editor last had it: what its edits are made on.
        var base: String?
        var parent: NoteEditorView
        init(_ parent: NoteEditorView) { self.parent = parent }

        @MainActor func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NoteTextView else { return }
            schedule(view)
        }

        @MainActor func schedule(_ view: NoteTextView) {
            measure(view)
            saveLater?.cancel()
            let work = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view, let storage = view.textStorage else { return }
                let body = NoteBlock.body(NoteRich.blocks(storage))
                guard body != self.body else { return }
                self.body = body
                if let next = self.parent.save(body, self.base) { self.base = next }
            }
            saveLater = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }

        @MainActor func flush(_ view: NoteTextView) {
            guard let work = saveLater, !work.isCancelled else { return }
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
        text.savePicture = picture
        text.escape = escape
        text.changed = { [weak coordinator, weak text] in
            guard let coordinator, let text else { return }
            MainActor.assumeIsolated { coordinator.schedule(text) }
        }
        coordinator.key = paper.key
        coordinator.noteID = paper.noteID
        coordinator.body = paper.file.body
        coordinator.base = paper.revision
        register { [weak coordinator, weak text] in
            guard let coordinator, let text else { return }
            MainActor.assumeIsolated { coordinator.flush(text) }
        }
        let base = paper.url.deletingLastPathComponent()
        text.textStorage?.setAttributedString(NoteRich.attributed(NoteBlock.blocks(paper.file.body), base: base, style: style))
        text.typingAttributes = NoteRich.attributes("text", style)
        text.insertionPointColor = style.ink
        DispatchQueue.main.async { coordinator.measure(text) }
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NoteTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        // Another note in this paper, or the file changed elsewhere while the person isn't typing here: read again.
        let elsewhere = paper.file.body != coordinator.body && text.window?.firstResponder !== text
        if coordinator.key != paper.key, coordinator.noteID == paper.noteID, text.window?.firstResponder === text {
            // The same note, its file named again on disk while the person types: what's typed stays.
            coordinator.key = paper.key
        } else if coordinator.key != paper.key || elsewhere {
            load(text, coordinator)
        }
        if focus, let window = text.window, window.firstResponder !== text {
            DispatchQueue.main.async { window.makeFirstResponder(text) }
        }
        if !focus, coordinator.saveLater != nil { coordinator.flush(text) }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let text = scroll.documentView as? NoteTextView {
            MainActor.assumeIsolated {
                coordinator.flush(text)
                coordinator.parent.register(nil)
            }
        }
    }
}
