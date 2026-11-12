import Foundation

// Checks SiteLoads.swift: a website shortcut's cached icon is read once, and a second ask while it's read waits for
// that read's answer instead of being told there's none (which fetched the icon from the site again at every launch).
// Run with macos/checks/run.sh.
@main
struct SiteLoadsCheck {
    @MainActor static func main() {
        var failures = 0
        func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL \(what)") } }
        var loads = SiteLoads()
        var heard: [String] = []
        // Drawing the shortcut asks for the cached icon (nothing waits), then asks again to fetch it if there's none.
        expect(loads.ask("example.com", then: nil), "the first ask starts the read")
        expect(!loads.ask("example.com", then: { found in heard.append("second: \(found)") }), "a second ask doesn't start another read")
        expect(heard.isEmpty, "the second ask isn't answered before the read is done")
        expect(loads.ask("other.example", then: { found in heard.append("other: \(found)") }), "another site's read is its own")
        for waiting in loads.answered("example.com") { waiting(true) }
        expect(heard == ["second: true"], "the read's answer reaches whoever waited: the icon was in the cache")
        expect(loads.answered("example.com").isEmpty, "answered once")
        expect(loads.ask("example.com", then: nil), "after the answer, a new ask starts a new read")
        for waiting in loads.answered("other.example") { waiting(false) }
        expect(heard == ["second: true", "other: false"], "no icon in the cache is said too")
        if failures > 0 { print("site loads: \(failures) failed"); exit(1) }
        print("site loads: a second ask waits for the read under way")
    }
}
