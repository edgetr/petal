import AppKit
import Observation
import SwiftUI

/// Websites: the dock's apps can hold web addresses (website shortcuts). A shortcut opens in the default browser and
/// shows the site's own icon, fetched from the site itself (`/apple-touch-icon.png`, else the icon `<link>` in its
/// page, else `/favicon.ico`; never a third-party service) and kept in ~/Library/Caches/Petal/sites, with a small
/// globe at the bottom right, like macOS's web apps.
@MainActor @Observable
final class Sites {
    static let shared = Sites()
    /// Goes up when a fetched icon arrives, so the views showing a globe draw it.
    private var arrived = 0
    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var fetching: Set<String> = []
    @ObservationIgnored private var failed: [String: Date] = [:]
    /// Hosts whose cached icon is being read from disk (off the main thread), with whoever waits for that read.
    @ObservationIgnored private var loading = SiteLoads()

    nonisolated static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Petal/sites")

    // MARK: Addresses

    /// A dock entry that's a website, not an app.
    nonisolated static func isWeb(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }

    /// "x.com", "https://www.x.com/home" → "x.com": the host, lowercased, without "www.".
    nonisolated static func domain(_ text: String) -> String? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(" ") else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let host = URLComponents(string: raw)?.host?.lowercased(), host.contains(".") || host == "localhost" else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// What someone typed or pasted, as a website shortcut ("figma.com" → "https://figma.com"), or nil when it
    /// doesn't look like a web address.
    nonisolated static func address(_ typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" "), !text.hasPrefix("/"), !text.hasPrefix("~") else { return nil }
        if isWeb(text) { return domain(text) == nil ? nil : text }
        // A bare word isn't an address; a name with a dot and a 2+ letter ending is.
        let host = text.split(separator: "/").first.map(String.init) ?? text
        let parts = host.split(separator: ".")
        guard parts.count >= 2, let last = parts.last, last.count >= 2, last.allSatisfy(\.isLetter), domain(text) != nil else { return nil }
        return "https://" + text
    }

    static func open(_ id: String) {
        guard let url = URL(string: id) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Icons

    /// The site's icon, or a globe while it's fetched (or when it has none): a website shortcut the person put in
    /// their dock.
    func icon(_ id: String) -> NSImage? {
        if let image = cachedIcon(id) { return image }
        requestIcon(id)
        return nil
    }

    /// The site's icon only if it's already here (in memory or in Petal's cache): drawing a note's link card never
    /// fetches anything.
    /// Petal's cache on disk is read off the main thread; the icon shows once it's in.
    func cachedIcon(_ id: String) -> NSImage? {
        guard let host = Self.domain(id) else { return nil }
        _ = arrived
        if let image = images[host] { return image }
        loadCached(host)
        return nil
    }

    /// The cached icon's bytes read off the main thread; `then` says whether there was one.
    /// (A second ask while that read is under way waits for its answer: one that came in before the file was read
    /// would be told there's none, and the site would be asked again for an icon Petal already has.)
    private func loadCached(_ host: String, then: (@MainActor (Bool) -> Void)? = nil) {
        guard loading.ask(host, then: then) else { return }
        let file = Self.folder.appending(path: host + ".png")
        Task.detached(priority: .utility) {
            let data = try? Data(contentsOf: file)
            await MainActor.run {
                if let data, let image = NSImage(data: data) {
                    self.images[host] = image
                    self.arrived += 1
                }
                for waiting in self.loading.answered(host) { waiting(self.images[host] != nil) }
            }
        }
    }

    /// Fetches the site's icon (bounded, streamed): for a dock shortcut, or a link the person pasted or typed.
    func requestIcon(_ id: String) {
        guard let host = Self.domain(id), images[host] == nil else { return }
        // Petal's own cache first (read off the main thread), the site only when it has none.
        loadCached(host) { [weak self] found in
            if !found { self?.fetch(id, host: host, to: Self.folder.appending(path: host + ".png")) }
        }
    }

    private func fetch(_ id: String, host: String, to file: URL) {
        guard !fetching.contains(host), (failed[host].map { Date().timeIntervalSince($0) > 3600 } ?? true),
              let base = URL(string: id).flatMap({ URL(string: "\($0.scheme ?? "https")://\($0.host ?? host)") }) else { return }
        fetching.insert(host)
        Task.detached(priority: .utility) {
            let data = await Self.download(base)
            // Kept in Petal's cache (written here, off the main thread).
            if let data, let image = NSImage(data: data), image.isValid, let png = Self.png(image) {
                try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                try? png.write(to: file, options: .atomic)
            }
            await MainActor.run {
                self.fetching.remove(host)
                guard let data, let image = NSImage(data: data), image.isValid else { self.failed[host] = Date(); return }
                self.images[host] = image
                self.arrived += 1
            }
        }
    }

    /// The site's own icon, in the order a browser would look for a good one.
    nonisolated private static func download(_ base: URL) async -> Data? {
        if let data = await get(base.appending(path: "apple-touch-icon.png"), .image), isImage(data) { return data }
        if let page = await get(base, .page), let html = String(data: page, encoding: .utf8) ?? String(data: page, encoding: .isoLatin1) {
            for href in iconLinks(html).prefix(4) {
                guard let url = URL(string: href, relativeTo: base)?.absoluteURL, ["http", "https"].contains(url.scheme ?? "") else { continue }
                if let data = await get(url, .image), isImage(data) { return data }
            }
        }
        if let data = await get(base.appending(path: "favicon.ico"), .image), isImage(data) { return data }
        return nil
    }

    /// One response, streamed and bounded (NoteShelf.fetchAccepts, fetchLimit): an image or an HTML page by its
    /// content type before anything is read, no more than its limit (too big: nothing), within 10 seconds.
    nonisolated static func get(_ url: URL, _ kind: NoteShelf.FetchKind) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Petal", forHTTPHeaderField: "User-Agent")
        let deadline = Date().addingTimeInterval(10)
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request) else { return nil }
        let http = response as? HTTPURLResponse
        guard NoteShelf.fetchAccepts(kind, status: http?.statusCode ?? 0, contentType: http?.value(forHTTPHeaderField: "Content-Type")) else {
            bytes.task.cancel()
            return nil
        }
        let limit = NoteShelf.fetchLimit(kind)
        if let length = http?.expectedContentLength, length > Int64(limit), kind == .image { bytes.task.cancel(); return nil }
        var data = Data()
        var complete = true
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit || Date() > deadline { complete = false; break }
            }
        } catch { complete = false }
        bytes.task.cancel()
        // A page is read for its head (its start will do); an image only whole.
        return kind == .page || complete ? data : nil
    }

    nonisolated private static func isImage(_ data: Data) -> Bool {
        guard data.count > 64, let image = NSImage(data: data) else { return false }
        return image.isValid && image.size.width >= 8
    }

    /// The icons a page links to, best first: apple-touch-icon, then the largest declared size.
    nonisolated static func iconLinks(_ html: String) -> [String] {
        guard let tag = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive) else { return [] }
        func attribute(_ name: String, in text: String) -> String? {
            let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            for group in 1...3 {
                if let range = Range(match.range(at: group), in: text) { return String(text[range]) }
            }
            return nil
        }
        var found: [(href: String, score: Int)] = []
        for match in tag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let text = String(html[range])
            guard let rel = attribute("rel", in: text)?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
                  let href = attribute("href", in: text), !href.isEmpty, !href.lowercased().hasSuffix(".svg") else { continue }
            let size = attribute("sizes", in: text).flatMap { Int($0.lowercased().split(separator: "x").first ?? "") } ?? 16
            found.append((href.replacingOccurrences(of: "&amp;", with: "&"), (rel.contains("apple-touch") ? 1000 : 0) + size))
        }
        return found.sorted { $0.score > $1.score }.map(\.href)
    }

    /// A big square icon (an apple-touch-icon) fills its tile; a small favicon sits in the middle of it.
    nonisolated static func fullBleed(_ image: NSImage) -> Bool {
        let pixels = image.representations.map { CGFloat($0.pixelsWide) }.max() ?? image.size.width
        return pixels >= 114 && abs(image.size.width - image.size.height) < 1
    }

    nonisolated private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// A website shortcut's icon as one picture (for menus and places that want an NSImage): the site's icon on a
    /// tile, with the globe badge.
    func tile(_ id: String, size: CGFloat = 64) -> NSImage {
        let favicon = icon(id)
        let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size * 0.4, weight: .regular).applying(.init(paletteColors: [NSColor(white: 0.45, alpha: 1)])))
        let badgeGlobe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size * 0.2, weight: .semibold).applying(.init(paletteColors: [.white])))
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.insetBy(dx: size * 0.06, dy: size * 0.06)
            let tile = NSBezierPath(roundedRect: inset, xRadius: size * 0.22, yRadius: size * 0.22)
            NSColor(white: 0.97, alpha: 1).setFill()
            tile.fill()
            if let favicon, Self.fullBleed(favicon) {
                NSGraphicsContext.saveGraphicsState()
                tile.addClip()
                favicon.draw(in: inset, from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            } else if let favicon {
                favicon.draw(in: inset.insetBy(dx: size * 0.16, dy: size * 0.16), from: .zero, operation: .sourceOver, fraction: 1)
            } else if let globe {
                globe.draw(in: inset.insetBy(dx: size * 0.2, dy: size * 0.2))
            }
            let side = size * 0.36
            let badge = NSRect(x: rect.maxX - side, y: rect.minY, width: side, height: side)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: badge).fill()
            NSColor(red: 0.2, green: 0.5, blue: 1, alpha: 1).setFill()
            NSBezierPath(ovalIn: badge.insetBy(dx: side * 0.09, dy: side * 0.09)).fill()
            badgeGlobe?.draw(in: badge.insetBy(dx: side * 0.2, dy: side * 0.2))
            return true
        }
    }
}

/// A website shortcut in the dock: the site's icon on a light tile, with a globe badge at the bottom right.
struct SiteIcon: View {
    let id: String
    let size: CGFloat

    var body: some View {
        let image = Sites.shared.icon(id)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Color(white: 0.97))
                .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(.black.opacity(0.08)))
            if let image, Sites.fullBleed(image) {
                // A touch icon is a whole tile already, as on a phone's home screen.
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                    .clipShape(.rect(cornerRadius: size * 0.22, style: .continuous))
            } else if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(size * 0.17)
            } else {
                Image(systemName: "globe").font(.system(size: size * 0.46)).foregroundStyle(Color(white: 0.45))
            }
        }
        .frame(width: size * 0.88, height: size * 0.88)
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) { GlobeBadge(size: size * 0.36) }
    }
}

struct GlobeBadge: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "globe").font(.system(size: size * 0.6, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(red: 0.2, green: 0.5, blue: 1), in: .circle)
            .overlay(Circle().strokeBorder(.white, lineWidth: max(1, size * 0.09)))
    }
}
