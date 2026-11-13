import Foundation

// Checks ThumbnailCache.swift: a stack's thumbnail is made once at a time, and made again when it's asked for after
// the cache let it go (once more than its limit were made, every thumbnail seen before stopped showing). Run with
// macos/checks/run.sh.
@main
struct ThumbnailCacheCheck {
    static func main() {
        var failures = 0
        func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL \(what)") } }
        var cache = ThumbnailCache<String>(limit: 3)
        let a = URL(fileURLWithPath: "/tmp/a.png")
        expect(cache.want(a) == (nil, true), "the first ask makes it")
        expect(cache.want(a) == (nil, false), "a second ask while it's made waits")
        cache.made(a, "A")
        expect(cache.want(a) == ("A", false), "made: it's there")
        for n in 0..<5 {
            let url = URL(fileURLWithPath: "/tmp/\(n).png")
            _ = cache.want(url)
            cache.made(url, "\(n)")
        }
        expect(cache.images.count <= 3, "never more than its limit")
        let again = cache.want(a)
        expect(again.image == nil && again.start, "one let go is made again when it's asked for")
        cache.made(a, "A2")
        expect(cache.want(a) == ("A2", false), "and shows again")
        if failures > 0 { print("thumbnails: \(failures) failed"); exit(1) }
        print("thumbnails: made again after the cache lets them go")
    }
}
