import CoreGraphics
import Foundation

// Checks NoteFile.swift: the note file's round trip, iCloud's conflict copies, which of a note's places fits what's
// in front (the ranked fallback, never a guess), the tabs on a window's edge (lines, counts, stacking), fading, and
// the room beside a window. Run with macos/checks/run.sh.
@main
struct NotesCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static func main() {
        let when = NoteFile.date("2026-11-08T09:30:00Z")!

        // MARK: The file

        var note = NoteFile(id: "A1", created: when, modified: when.addingTimeInterval(60), body: "# Talk\n\n- [ ] print the handout\n- [x] slides\nhttps://example.com/rooms\n![Crop of example.com](Talk.assets/crop-1.png)\n> Petal's answer\nplain words with: a colon")
        var passage = NoteStick(kind: .passage)
        passage.url = "https://example.com/guide"
        passage.quote = "Doors open at 8."
        passage.before = "Registration is in the hall. "
        passage.after = " Talks start at 9."
        var file = NoteStick(kind: .file)
        file.path = "/Users/someone/Booking.pdf"
        file.bookmark = "Ym9va21hcms="
        var window = NoteStick(kind: .window)
        window.app = "com.apple.TextEdit"
        window.title = "Draft: \"quotes\" and # marks"
        window.mac = "mac-1"
        window.pid = 42
        window.window = 7
        window.extra = [(key: "later", value: "\"kept\"")]
        note.places = [passage, file, window]
        note.chat = "8E1C-chat"
        note.extra = [(key: "watch", lines: ["watch:", "  every: morning"])]
        let text = note.serialized()
        let back = NoteFile.parse(text, fallbackID: "X", fallbackDate: Date())
        expect(back == note, "a note reads back as it was written", "\n\(text)")
        expect(back.serialized() == text, "and writes the same text again")
        expect(back.places[2].extra.first?.key == "later", "a place's unknown key is kept")
        expect(text.contains("  every: morning"), "a later Petal's keys are kept as they were")
        expect(back.title == "Talk", "the title is its first heading")
        expect(back.preview.hasPrefix("☐ print the handout ☑ slides example.com"), "a folded note shows its lines after the title", back.preview)

        let handWritten = NoteFile.parse("Just words\nmore", fallbackID: "F", fallbackDate: when)
        expect(handWritten.id == "F" && handWritten.body == "Just words\nmore" && handWritten.places.isEmpty, "a file with no front matter is a note")
        let broken = NoteFile.parse("---\nid: B\nno end", fallbackID: "F", fallbackDate: when)
        expect(broken.body == "---\nid: B\nno end", "a front matter that never ends is kept as words")
        let windowsLines = NoteFile.parse("---\r\nid: W\r\n---\r\nhi", fallbackID: "F", fallbackDate: when)
        expect(windowsLines.id == "W" && windowsLines.body == "hi", "Windows line ends read")
        var cover = NoteFile(id: "C", created: when, body: "What this notebook is for")
        cover.cover = true
        cover.color = "accent"
        let coverBack = NoteFile.parse(cover.serialized(), fallbackID: "", fallbackDate: when)
        expect(coverBack.cover && coverBack.color == "accent", "a cover keeps its color")
        expect(NoteFile.quoted("yes") == "\"yes\"" && NoteFile.quoted("#ff0000") == "\"#ff0000\"" && NoteFile.quoted("Work notes") == "Work notes",
               "values that could be misread are quoted")
        expect(NoteFile.scalar("\"a \\\"b\\\"\"") == "a \"b\"", "a quoted value reads back")

        // The blocks, line for line.
        for line in ["# H", "## H2", "### H3", "- [ ] a", "- [x] b", "- c", "https://example.com/x", "![cap](a.png)", "![two words](<my file.png>)", "> ink", ">", "words", "", "#no space"] {
            expect(NoteBlock.parse(line).markdown == line, "\"\(line)\" round trips", NoteBlock.parse(line).markdown)
        }
        expect(NoteBlock.parse("- [X] done") == .check(true, "done"), "a capital X is done too")
        expect(NoteBlock.parse("see https://example.com") == .text("see https://example.com"), "an address inside words is words")
        expect(NoteText.plain("go [here](https://a.b) now") == "go here now", "inline links read as their words")
        expect(NoteText.fileName("a/b: c?") == "a b c", "a file name is made safe")
        expect(NoteText.shortAddress("https://www.example.com/rooms/") == "example.com/rooms", "the letterhead's address")
        expect(NoteText.site("example.com/rooms") == "example.com" && NoteText.site("this sentence") == "this sentence" && NoteText.site("a/b c") == "a/b c",
               "a folded note's letterhead names the site alone")
        expect(NoteText.matches("outline TALK", "Talk outline"), "search ignores case and order")
        expect(NoteText.matches("cafe", "Café near the station"), "and accents")

        // MARK: Conflicts

        let copies = [NoteShelf.Copy(id: "A", file: "Talk 2.md", modified: when), NoteShelf.Copy(id: "A", file: "Talk.md", modified: when.addingTimeInterval(9)),
                      NoteShelf.Copy(id: "B", file: "Other.md", modified: when)]
        let groups = NoteShelf.conflicts(copies)
        expect(groups.count == 1 && groups[0].map(\.file) == ["Talk.md", "Talk 2.md"], "iCloud's copy shows beside the original", "\(groups)")
        expect(NoteShelf.conflicts([NoteShelf.Copy(id: "A", file: "x.md", modified: when.addingTimeInterval(5)),
                                    NoteShelf.Copy(id: "A", file: "y.md", modified: when)])[0][0].file == "y.md", "else the older first")
        expect(NoteShelf.isCopyName("Talk (conflicted copy 2026-11-08).md") && !NoteShelf.isCopyName("Day 1.md") && NoteShelf.isCopyName("Day 2.md"),
               "copy names (a note called \"Day 2\" only counts beside its twin)")
        expect(NoteShelf.freeName("Talk", taken: ["talk.md", "talk 2.md"]) == "Talk 3.md", "a new file never takes another's name")

        // MARK: Which place fits

        var scene = NoteScene(mac: "mac-1", app: "com.google.Chrome", pid: 50, window: 9, title: "Guide", titleTwins: 1,
                              tab: NoteTab(id: "t1", url: "https://example.com/guide#top", title: "Guide"), file: "")
        var tab = NoteStick(kind: .tab)
        tab.app = "com.google.Chrome"
        tab.url = "https://example.com/guide"
        var app = NoteStick(kind: .app)
        app.app = "com.google.Chrome"
        expect(NoteMatch.best([app, tab, passage], scene) == 2, "the passage first, on its page (the fragment doesn't count)")
        expect(NoteMatch.best([app, tab], scene) == 0, "a tab's note by address counts the fragment (an app's own pages differ by it)")
        scene.tab?.url = "https://example.com/guide/"
        expect(NoteMatch.best([app, tab], scene) == 1, "then its tab")
        scene.tab?.url = "https://example.com/other"
        expect(NoteMatch.best([app, tab, passage], scene) == 0, "then its app")
        var ownTab = tab
        ownTab.mac = "mac-1"
        ownTab.pid = 50
        ownTab.tabID = "t1"
        expect(NoteMatch.fits(ownTab, scene), "a tab's note follows its own tab to another address")
        ownTab.mac = "mac-2"
        expect(!NoteMatch.fits(ownTab, scene), "another Mac's tab id means nothing here")
        expect(NoteMatch.fits(file, NoteScene(app: "com.apple.Preview", file: "/Users/someone/Booking.pdf")), "a file's note in any app")
        var filePassage = NoteStick(kind: .passage)
        filePassage.path = "/Users/someone/Booking.pdf"
        filePassage.quote = "x"
        expect(NoteMatch.best([window, filePassage], NoteScene(mac: "mac-1", app: "com.apple.Preview", pid: 3, window: 1, file: "/Users/someone/Booking.pdf")) == 1,
               "a passage in a file")
        let editor = NoteScene(mac: "mac-1", app: "com.apple.TextEdit", pid: 42, window: 7, title: "x")
        expect(NoteMatch.fits(window, editor), "a window's note on its window")
        expect(!NoteMatch.fits(window, NoteScene(mac: "mac-1", app: "com.apple.TextEdit", pid: 42, window: 8, title: window.title, titleTwins: 1)),
               "never another window while its app runs, even titled alike")
        let restarted = NoteScene(mac: "mac-1", app: "com.apple.TextEdit", pid: 77, window: 3, title: window.title, titleTwins: 1)
        expect(NoteMatch.fits(window, restarted), "after its app restarted: the one window with its title")
        var twins = restarted
        twins.titleTwins = 2
        expect(!NoteMatch.fits(window, twins), "two windows with that title: no guess")
        twins.titleTwins = nil
        expect(!NoteMatch.fits(window, twins), "nor when Petal can't count them")
        var desk = NoteStick(kind: .desktop)
        desk.desktop = 2
        expect(!NoteMatch.fits(desk, scene), "a Desktop's note never sits on a window")
        expect(passage.label() == "this sentence" && passage.label(found: false) == "passage moved" && tab.label() == "example.com/guide"
               && app.label() == "all of com.google.Chrome", "the letterhead's words")

        // Locating a quote.
        let page = "Go early. The path is quiet. Lunch after. Then the path is quiet. Done."
        expect(NoteMatch.locate(quote: "the path is quiet", before: "Then ", after: ". Done", in: page) != nil, "a quote there twice, told apart by its words")
        let twice = "a b a b"
        expect(NoteMatch.locate(quote: "a", before: "", after: "", in: twice) == nil, "two alike with nothing to tell them apart: none")
        expect(NoteMatch.locate(quote: "Lunch", before: "", after: "", in: page).map { String(page[$0]) } == "Lunch", "once: there")
        expect(NoteMatch.locate(quote: "Dinner", before: "", after: "", in: page) == nil, "gone: none (passage moved)")

        // MARK: Edge tabs

        let notes = [EdgeNote(id: "a", line: 118, color: "#007aff", faded: false), EdgeNote(id: "b", line: 128, color: "#e0567a", faded: false),
                     EdgeNote(id: "c", line: 300, color: "#007aff", faded: false), EdgeNote(id: "d", line: nil, color: "#007aff", faded: false),
                     EdgeNote(id: "e", line: nil, color: "#007aff", faded: true)]
        let tabs = EdgeLayout.tabs(notes, height: 700)
        expect(tabs.count == 4, "two notes on one line are one tab", "\(tabs)")
        expect(tabs.first { $0.ids.contains("a") }?.count == 2, "with their count")
        expect(tabs.first { $0.ids == ["d"] }?.y == EdgeLayout.top, "a note with no line at the top")
        expect(tabs.first { $0.ids == ["e"] }.map { $0.faded && $0.height == EdgeLayout.fadedTab } == true, "a faded note is a faint line")
        for (a, b) in zip(tabs, tabs.dropFirst()) { expect(a.y + a.height + EdgeLayout.gap <= b.y + 0.001, "tabs never overlap", "\(a) \(b)") }
        let crowded = EdgeLayout.tabs((0..<30).map { EdgeNote(id: "\($0)", line: nil, color: "#000000", faded: false) }, height: 300)
        expect(crowded.reduce(0) { $0 + $1.count } == 30 && crowded.last.map { $0.y + $0.height <= 300 } == true, "too many: the last tab holds the rest")
        expect(NoteShelf.faded(modified: when, now: when.addingTimeInterval(31 * 86400)) && !NoteShelf.faded(modified: when, now: when.addingTimeInterval(29 * 86400)),
               "untouched for 30 days, a note fades")

        // MARK: Room

        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let roomy = CGRect(x: 100, y: 60, width: 900, height: 700)
        expect(NoteRoom.narrowed(window: roomy, visible: visible, note: 340) == nil, "room beside it: nothing changes")
        let wide = CGRect(x: 40, y: 60, width: 1380, height: 700)
        let narrowed = NoteRoom.narrowed(window: wide, visible: visible, note: 340)
        expect(narrowed == CGRect(x: 40, y: 60, width: 1440 - 364 - 40, height: 700), "a wide window keeps its left edge and narrows", "\(String(describing: narrowed))")
        let small = CGRect(x: 700, y: 60, width: 700, height: 700)
        expect(NoteRoom.narrowed(window: small, visible: visible, note: 340) == CGRect(x: 376, y: 60, width: 700, height: 700), "one that would be too narrow moves left")
        let tiny = CGRect(x: 0, y: 0, width: 600, height: 400)
        expect(NoteRoom.narrowed(window: tiny, visible: CGRect(x: 0, y: 0, width: 700, height: 500), note: 340) == nil, "never under its minimum")
        if let given = narrowed {
            expect(NoteRoom.giveBack(before: wide, given: given, now: given.insetBy(dx: 1, dy: 0)) == wide, "its width comes back")
            expect(NoteRoom.giveBack(before: wide, given: given, now: given.offsetBy(dx: 80, dy: 0)) == nil, "moved by the person since: theirs")
        }
        let spot = NoteRoom.beside(window: roomy, visible: visible, size: CGSize(width: 340, height: 300), top: 118)
        expect(spot.minX == roomy.maxX + NoteRoom.gap && spot.minY == roomy.minY + 118, "an open note beside its line")
        let low = NoteRoom.beside(window: roomy, visible: visible, size: CGSize(width: 340, height: 300), top: 690)
        expect(low.maxY <= visible.maxY, "and kept on the screen")

        // MARK: Paper colors (the sketch's color-mix)

        let blue = NoteInk.hex("#007aff")!
        expect(NoteInk.hex(NoteInk.mix(blue, 1, NoteInk.paper)) == "#007aff" && NoteInk.hex(NoteInk.mix(blue, 0, NoteInk.paper)) == "#fffef9", "mixing ends")
        let paper = NoteInk.paper(blue)
        expect(paper.b > paper.r && paper.r > 0.85, "blue paper is a pale blue", NoteInk.hex(paper))

        print("notes: \(passed) passed" + (failures > 0 ? ", \(failures) failed" : ""))
        if failures > 0 { exit(1) }
    }
}
