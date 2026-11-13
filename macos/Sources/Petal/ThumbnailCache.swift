import Foundation

/// The stacks' thumbnails kept in memory, as rules without AppKit (checked by checks/ThumbnailCacheCheck.swift): each
/// made once at a time, kept until there are too many, and made again when asked for after that.
struct ThumbnailCache<Image> {
    private(set) var images: [URL: Image] = [:]
    private var making: Set<URL> = []
    /// How many are kept: past that, all are let go and made again as they're asked for.
    let limit: Int

    init(limit: Int = 300) { self.limit = limit }

    /// The thumbnail if it's here; else nil, and `start` true when it should be made now (none is being made).
    mutating func want(_ url: URL) -> (image: Image?, start: Bool) {
        if let image = images[url] { return (image, false) }
        guard !making.contains(url) else { return (nil, false) }
        making.insert(url)
        return (nil, true)
    }

    /// One was made: kept, and no longer being made, so a later ask after the cache was emptied makes it again.
    mutating func made(_ url: URL, _ image: Image) {
        making.remove(url)
        if images.count >= limit { images = [:] }
        images[url] = image
    }
}
