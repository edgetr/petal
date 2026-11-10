import AppKit
import SwiftUI
import WebKit

/// Markdown as AI replies write it: headings, paragraphs, lists, quotes, code, tables, rules, and inline bold,
/// italic, code and links. The chat draws it natively (`MarkdownView`); pages (`Pages`) draw it as HTML.
enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case list(ordered: Bool, items: [String])
    case code(String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
}

enum Markdown {
    static func blocks(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                out.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }
            if line.isEmpty { flush(); i += 1; continue }
            if let heading = heading(line) { flush(); out.append(heading); i += 1; continue }
            if ["---", "***", "___"].contains(line) { flush(); out.append(.rule); i += 1; continue }
            if line.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append(.quote(quote.joined(separator: "\n")))
                continue
            }
            if line.hasPrefix("|"), i + 1 < lines.count, separator(lines[i + 1]) {
                flush()
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                out.append(.table(header: header, rows: rows))
                continue
            }
            if let first = item(line) {
                flush()
                var items = [first.text]
                i += 1
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    if let more = item(next), more.ordered == first.ordered { items.append(more.text); i += 1 }
                    else if !next.isEmpty, lines[i].hasPrefix("  "), item(next) == nil { items[items.count - 1] += " " + next; i += 1 }
                    else { break }
                }
                out.append(.list(ordered: first.ordered, items: items))
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flush()
        return out
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func item(_ line: String) -> (ordered: Bool, text: String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { return (false, String(line.dropFirst(2))) }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < 4 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (true, String(rest.dropFirst(2)))
    }

    private static func separator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Inline markdown (bold, italic, code, links) for SwiftUI text.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    // MARK: HTML

    static func html(_ text: String) -> String {
        blocks(text).map { block in
            switch block {
            case .heading(let level, let text): "<h\(level)>\(inlineHTML(text))</h\(level)>"
            case .paragraph(let text): "<p>\(inlineHTML(text).replacingOccurrences(of: "\n", with: "<br>"))</p>"
            case .list(let ordered, let items):
                "<\(ordered ? "ol" : "ul")>" + items.map { "<li>\(inlineHTML($0))</li>" }.joined() + "</\(ordered ? "ol" : "ul")>"
            case .code(let code): "<pre><code>\(escape(code))</code></pre>"
            case .quote(let text): "<blockquote>\(inlineHTML(text).replacingOccurrences(of: "\n", with: "<br>"))</blockquote>"
            case .table(let header, let rows):
                "<table><thead><tr>" + header.map { "<th>\(inlineHTML($0))</th>" }.joined() + "</tr></thead><tbody>"
                    + rows.map { "<tr>" + $0.map { "<td>\(inlineHTML($0))</td>" }.joined() + "</tr>" }.joined() + "</tbody></table>"
            case .rule: "<hr>"
            }
        }.joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inlineHTML(_ text: String) -> String {
        var s = escape(text)
        let rules: [(String, String)] = [
            ("`([^`]+)`", "<code>$1</code>"),
            ("\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>"),
            ("__([^_]+)__", "<strong>$1</strong>"),
            ("(?<![*\\w])\\*([^*]+)\\*(?![*\\w])", "<em>$1</em>"),
            ("(?<![_\\w])_([^_]+)_(?![_\\w])", "<em>$1</em>"),
            ("\\[([^\\]]+)\\]\\((https?://[^)\\s]+)\\)", "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }
}

/// A text's markdown, parsed once: its blocks with their inline markdown made into attributed text. Kept per text
/// (a reply is drawn again and again as the chat changes and scrolls; parsing it every time cost the most there).
@MainActor
final class ParsedMarkdown {
    let blocks: [MarkdownBlock]
    private var inline: [String: AttributedString] = [:]

    private init(_ text: String) { blocks = Markdown.blocks(text) }

    /// `Markdown.inline`, kept.
    func text(_ source: String) -> AttributedString {
        if let known = inline[source] { return known }
        let made = Markdown.inline(source)
        inline[source] = made
        return made
    }

    private static var kept: [String: ParsedMarkdown] = [:]
    private static var order: [String] = []

    static func of(_ text: String) -> ParsedMarkdown {
        if let known = kept[text] { return known }
        let parsed = ParsedMarkdown(text)
        kept[text] = parsed
        order.append(text)
        if order.count > 400 { kept[order.removeFirst()] = nil }   // a reply streaming in passes through many texts
        return parsed
    }
}

/// Markdown drawn natively in the chat: headings, lists, code, quotes and tables, not raw symbols.
struct MarkdownView: View {
    let text: String

    var body: some View {
        let parsed = ParsedMarkdown.of(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parsed.blocks.enumerated()), id: \.offset) { _, block in
                view(block, parsed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ block: MarkdownBlock, _ parsed: ParsedMarkdown) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(parsed.text(text)).font(.system(size: level <= 1 ? TextSize.subtitle : level == 2 ? TextSize.heading : TextSize.body, weight: .semibold))
                .padding(.top, 2)
        case .paragraph(let text):
            Text(parsed.text(text)).font(.system(size: TextSize.body)).lineSpacing(2)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "•").font(.system(size: TextSize.body)).foregroundStyle(.secondary)
                            .frame(minWidth: ordered ? 16 : 8, alignment: .trailing)
                        Text(parsed.text(item)).font(.system(size: TextSize.body)).lineSpacing(2)
                    }
                }
            }
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code).font(.system(size: TextSize.callout, design: .monospaced)).padding(10)
            }
            .scrollIndicators(.never)
            .background(.white.opacity(0.06), in: .rect(cornerRadius: Radius.tile))
        case .quote(let text):
            HStack(spacing: 8) {
                Capsule().fill(.secondary.opacity(0.5)).frame(width: 3)
                Text(parsed.text(text)).font(.system(size: TextSize.body)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow { ForEach(Array(header.enumerated()), id: \.offset) { Text(parsed.text($0.element)).font(.system(size: TextSize.callout, weight: .semibold)) } }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { Text(parsed.text($0.element)).font(.system(size: TextSize.callout)) } }
                }
            }
            .padding(10)
            .background(.white.opacity(0.05), in: .rect(cornerRadius: Radius.tile))
        case .rule:
            Divider()
        }
    }
}

/// Pages Petal AI makes: a summary of the month, a report, a table, a chart. Each opens in Petal's own glass
/// window (never another app), drawn from markdown or HTML (with inline SVG for charts), and is kept in
/// ~/Library/Application Support/Petal/pages so it can be opened again.
@MainActor
enum Pages {
    private static var windows: [String: PageWindow] = [:]
    static let folder = Config.supportFolder.appending(path: "pages")

    /// Shows a page: `markdown`, or `html` (a whole document, or a body), or a file at `path`. Returns its file.
    /// Each page is a new file (its title, and a few letters of its own, so two pages called the same never meet);
    /// `update`, a page's file returned before, changes that page in place.
    static func show(title: String, markdown: String?, html: String?, path: String?, update: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file: URL
        if let path, !path.isEmpty {
            let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: source.path) else { throw MCP.Failure("No file at \(path).") }
            let text = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
            let isHTML = ["html", "htm"].contains(source.pathExtension.lowercased())
            return try show(title: title, markdown: isHTML ? nil : text, html: isHTML ? text : nil, path: nil, update: update)
        }
        let body = html ?? Markdown.html(markdown ?? "")
        // A whole page keeps its own look, inside Petal's window; a body gets Petal's.
        let document = body.lowercased().contains("<html") ? body : template(title: title, body: body)
        let slug = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
            .split(separator: "-").joined(separator: "-")
        let same = update.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        if let same, same.deletingLastPathComponent().path == folder.standardizedFileURL.path, same.pathExtension == "html",
           FileManager.default.fileExists(atPath: same.path) {
            file = same
        } else {
            let unique = UUID().uuidString.prefix(6).lowercased()
            file = folder.appending(path: (slug.isEmpty ? "page" : String(slug.prefix(60))) + "-\(unique).html")
        }
        try document.write(to: file, atomically: true, encoding: .utf8)
        open(file, title: title)
        return file
    }

    static func open(_ file: URL, title: String) {
        let window = windows[file.path] ?? PageWindow()
        windows[file.path] = window
        window.load(file, title: title)
    }

    /// A page's whole document: `body` in Petal's look.
    static func document(title: String, body: String) -> String { template(title: title, body: body) }

    /// A step of the scale as CSS.
    private static func px(_ step: CGFloat) -> String { "\(Int(step))px" }

    private static func template(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>\(Markdown.escape(title))</title>
        <style>
        :root { color-scheme: light dark; --accent: #d9367f; --line: color-mix(in srgb, CanvasText 14%, transparent); }
        html, body { background: transparent; }
        body { font: \(px(TextSize.heading))/1.6 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; max-width: 720px; margin: 8px auto 40px; padding: 0 30px; color: CanvasText; -webkit-font-smoothing: antialiased; }
        h1 { font-size: \(px(TextSize.title)); margin: 0 0 14px; letter-spacing: -0.01em; } h2 { font-size: \(px(TextSize.subtitle)); margin: 26px 0 8px; } h3 { font-size: \(px(TextSize.heading)); margin: 20px 0 6px; }
        a { color: var(--accent); } code { font: \(px(TextSize.body)) ui-monospace, SFMono-Regular, monospace; background: color-mix(in srgb, CanvasText 8%, transparent); padding: 1px 5px; border-radius: \(px(Radius.chip)); }
        pre { background: color-mix(in srgb, CanvasText 7%, transparent); padding: 12px 14px; border-radius: \(px(Radius.tile)); overflow-x: auto; } pre code { background: none; padding: 0; }
        table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: \(px(TextSize.body)); } th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid var(--line); } th { font-weight: 600; }
        blockquote { margin: 12px 0; padding: 2px 14px; border-left: 3px solid var(--accent); color: color-mix(in srgb, CanvasText 72%, transparent); }
        hr { border: none; border-top: 1px solid var(--line); margin: 22px 0; } li { margin: 3px 0; } svg { max-width: 100%; height: auto; }
        </style></head><body>
        \(body)
        </body></html>
        """
    }
}

/// A page in Petal's look: macOS's own glass, a calm header with the title, Open in Browser and close, and the
/// page drawn over the glass.
@MainActor
final class PageWindow: NSWindow, WKNavigationDelegate {
    let web: WKWebView
    private let titleLabel = NSTextField(labelWithString: "")
    private var file: URL?

    init() {
        let configuration = WKWebViewConfiguration()
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        web.setValue(false, forKey: "drawsBackground")   // the glass shows through the page
        web.navigationDelegate = self

        titleLabel.font = .systemFont(ofSize: TextSize.body, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        let browser = NSButton(title: "Open in Browser", target: nil, action: nil)
        browser.bezelStyle = .glass
        browser.controlSize = .small
        browser.target = self
        browser.action = #selector(openInBrowser)

        let content = NSView()
        for view in [titleLabel, browser, web] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 84),
            titleLabel.centerYAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: browser.leadingAnchor, constant: -12),
            browser.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            browser.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            web.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        let glass = NSGlassEffectView()
        glass.cornerRadius = Radius.panel
        glass.contentView = content
        contentView = glass
        center()
    }

    func load(_ file: URL, title: String, show: Bool = true) {
        self.file = file
        self.title = title
        titleLabel.stringValue = title
        web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        // In front, without taking the keyboard from the chat (which closes when it loses it).
        if show { orderFrontRegardless() }
    }

    @objc private func openInBrowser() {
        if let file { NSWorkspace.shared.open(file) }
    }

    override var canBecomeKey: Bool { true }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("Petal page failed: %@", error.localizedDescription)
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("Petal page failed to load: %@", error.localizedDescription)
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("Petal page: the web content process ended; reloading")
        DispatchQueue.main.async { webView.reload() }
    }
}
