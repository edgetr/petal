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

    static func tabForRebase() -> NoteStick {
        var stick = NoteStick(kind: .tab)
        stick.url = "https://example.com/next"
        return stick
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
        window.extra = [(key: "later", lines: ["    later: \"kept\""]), (key: "watch", lines: ["    watch:", "      every: morning", "      - at: 9"])]
        note.places = [passage, file, window]
        note.chat = "8E1C-chat"
        note.extra = [(key: "watch", lines: ["watch:", "  every: morning"])]
        let text = note.serialized()
        let back = NoteFile.parse(text, fallbackID: "X", fallbackDate: Date())
        expect(back == note, "a note reads back as it was written", "\n\(text)")
        expect(back.serialized() == text, "and writes the same text again")
        expect(back.places[2].extra.first?.key == "later", "a place's unknown key is kept")
        expect(back.places[2].extra.last?.lines == ["    watch:", "      every: morning", "      - at: 9"], "and the lines nested under one, exactly", "\(back.places[2].extra)")
        let nested = NoteFile.parse("---\nid: N\nplaces:\n  - kind: app\n    app: com.example\n    rule:\n      - when: open\n        do: show\n---\nhi", fallbackID: "", fallbackDate: when)
        expect(nested.places.first?.app == "com.example" && nested.serialized().contains("    rule:\n      - when: open\n        do: show\n"),
               "a later Petal's nested place block reads back verbatim", nested.serialized())
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

        // Files with no id of their own: known by where they are, never by their name alone.
        let todoA = NoteShelf.fallbackID(relativePath: "Work/Todo.md"), todoB = NoteShelf.fallbackID(relativePath: "Home/Todo.md")
        expect(todoA != todoB && NoteShelf.conflicts([NoteShelf.Copy(id: todoA, file: "Todo.md", modified: when),
                                                      NoteShelf.Copy(id: todoB, file: "Todo.md", modified: when)]).isEmpty,
               "two Todo.md in two notebooks are two notes, never a conflict")
        expect(NoteFile.parse("words", fallbackID: todoA, fallbackDate: when).id == todoA, "a file with no front matter takes its place's id")

        // Saving over a file changed elsewhere keeps both.
        expect(NoteShelf.save(disk: "A", base: "A") == .write && NoteShelf.save(disk: nil, base: "A") == .write && NoteShelf.save(disk: nil, base: nil) == .write,
               "a file as the edit began, or none, is written")
        expect(NoteShelf.save(disk: "B", base: nil) == .keepBoth, "a new note never goes over a file that's there")
        var placed = NoteFile(id: "R", created: when, body: "my words")
        let editorBase = placed.serialized()
        placed.places = [tabForRebase()]
        let petalChanged = placed.serialized()
        expect(NoteShelf.rebase(editor: editorBase, current: petalChanged, currentBody: "my words") == petalChanged,
               "Petal's own change of a note's places is no reason to keep both")
        expect(NoteShelf.rebase(editor: editorBase, current: petalChanged, currentBody: "words from elsewhere") == editorBase,
               "words changed elsewhere are")
        expect(NoteShelf.save(disk: "B", base: "A") == .keepBoth, "a file changed since the edit began: both are kept")
        expect(NoteShelf.conflictName("Talk", taken: []) == "Talk (conflicted copy).md"
               && NoteShelf.conflictName("Talk", taken: ["talk (conflicted copy).md"]) == "Talk (conflicted copy 2).md", "the copy's name")
        expect(NoteShelf.isCopyName(NoteShelf.conflictName("Talk", taken: [])), "and it reads as a copy")

        // A read of the folder never undoes what changed here since it began.
        struct Item: Equatable { var key: String; var body: String }
        let read = [Item(key: "a", body: "A on disk"), Item(key: "b", body: "B on disk"), Item(key: "gone", body: "x")]
        let memory = [Item(key: "a", body: "A typed"), Item(key: "b", body: "B old"), Item(key: "new", body: "made")]
        let fenced = NoteShelf.fenced(read: read, memory: memory, key: \.key, started: 10, changed: ["a": 11, "b": 9, "new": 12], removed: ["gone": 13])
        expect(fenced == [Item(key: "a", body: "A typed"), Item(key: "b", body: "B on disk"), Item(key: "new", body: "made")],
               "changed since: kept; before: the disk's; made since: kept; removed since: gone", "\(fenced)")

        // Pictures' folders by the note's id: stable through moves, never shared.
        expect(NoteShelf.assetsFolder(id: "5F3A-1") == "5F3A-1.assets" && NoteShelf.assetsFolder(id: "file:Work/Todo.md") == "file-Work-Todo-md.assets",
               "a note's pictures' folder")

        // Writes stay inside the notes' folder.
        expect(NoteShelf.within("/n/Inbox/a.md", "/n") == "Inbox/a.md", "inside")
        expect(NoteShelf.within("/n2/a.md", "/n") == nil && NoteShelf.within("/n", "/n") == nil && NoteShelf.within("/n/../etc/x", "/n") == nil
               && NoteShelf.within("relative/a.md", "/n") == nil, "never beside it, the folder itself, out by .., or relative")

        // MARK: Which place fits

        var scene = NoteScene(mac: "mac-1", app: "com.google.Chrome", pid: 50, window: 9, title: "Guide", titleTwins: 1,
                              tab: NoteTab(id: "t1", shared: 1, url: "https://example.com/guide#top", title: "Guide"), file: "")
        var tab = NoteStick(kind: .tab)
        tab.app = "com.google.Chrome"
        tab.url = "https://example.com/guide#top"
        tab.mac = "mac-1"
        tab.pid = 50
        tab.tabID = "t1"
        tab.shared = 1
        var app = NoteStick(kind: .app)
        app.app = "com.google.Chrome"
        expect(NoteMatch.best([app, tab, passage], scene) == 2, "the passage first, on its page (the fragment doesn't count)")
        expect(NoteMatch.best([app, tab], scene) == 1, "then its tab")
        scene.tab?.url = "https://example.com/other"
        expect(NoteMatch.fits(tab, scene), "a tab's note follows its own tab to another address")
        expect(NoteMatch.best([app, tab, passage], scene) == 1, "and a passage elsewhere falls back to its tab")
        // Two tabs on one address are two tabs: never each other's note.
        let twin = NoteScene(mac: "mac-1", app: "com.google.Chrome", pid: 50, window: 9, tab: NoteTab(id: "t2", shared: 2, url: tab.url, title: "Guide"))
        expect(!NoteMatch.fits(tab, twin), "a duplicate tab with another id doesn't get its note")
        expect(NoteMatch.best([app, tab], twin) == 0, "it falls back to the app")
        // After the browser restarted (new ids, another process): by address only when it's the one tab with it.
        var browserBack = NoteScene(mac: "mac-1", app: "com.google.Chrome", pid: 77, window: 3, tab: NoteTab(id: "n9", shared: 1, url: tab.url, title: "Guide"))
        expect(NoteMatch.fits(tab, browserBack), "a Chromium tab found again by its address when it's the only tab with it")
        browserBack.tab?.shared = 2
        expect(!NoteMatch.fits(tab, browserBack), "never when two tabs have it")
        var wasShared = tab
        wasShared.shared = 2
        browserBack.tab?.shared = 1
        expect(!NoteMatch.fits(wasShared, browserBack), "nor when it wasn't the only one when stuck")
        // Safari, Firefox, Zen: their tab-strip button while the browser runs, never the address.
        var safari = NoteStick(kind: .tab)
        safari.app = "com.apple.Safari"
        safari.url = "https://example.com/a"
        safari.mac = "mac-1"
        safari.pid = 60
        safari.tabElement = 4
        let strip = NoteScene(mac: "mac-1", app: "com.apple.Safari", pid: 60, window: 2, tab: NoteTab(element: 4, url: "https://example.com/b", title: ""))
        expect(NoteMatch.fits(safari, strip), "a Safari tab by its button, whatever page it shows")
        let other = NoteScene(mac: "mac-1", app: "com.apple.Safari", pid: 60, window: 2, tab: NoteTab(element: 5, url: safari.url, title: ""))
        expect(!NoteMatch.fits(safari, other), "never another Safari tab on the same address")
        var lost = safari
        lost.tabElement = nil
        expect(!NoteMatch.fits(lost, NoteScene(mac: "mac-1", app: "com.apple.Safari", pid: 61, window: 2, tab: NoteTab(element: 1, url: safari.url, title: ""))),
               "a Safari tab after a restart is never found by address")
        var elsewhere = tab
        elsewhere.mac = "mac-2"
        expect(!NoteMatch.fits(elsewhere, NoteScene(mac: "mac-1", app: "com.google.Chrome", pid: 50, window: 9, tab: NoteTab(id: "t1", shared: 2, url: "https://x.example", title: ""))),
               "another Mac's tab id means nothing here")
        expect(tab.samePlace(tab) && !tab.samePlace(NoteStick(kind: .tab)), "a tab is the same place only by its own identity")
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

        // The whole quote, told apart across a window's texts by the words before and after it.
        let texts = ["Registration is in the hall. Doors open at 8. Talks start at 9.", "Day two: Doors open at 8. Lunch at noon."]
        expect(NoteMatch.pick(quote: "Doors open at 8.", before: "Registration is in the hall. ", after: " Talks start at 9.", in: texts)?.text == 0,
               "a quote in two texts, the one whose words around it fit")
        expect(NoteMatch.pick(quote: "Doors open at 8.", before: "", after: "", in: texts) == nil, "nothing to tell them apart: passage moved")
        expect(NoteMatch.pick(quote: "Doors open at 8. Talks start at 10.", before: "", after: "", in: texts) == nil,
               "the whole quote, never its first words alone")
        expect(NoteMatch.pick(quote: "Lunch at noon.", before: "", after: "", in: texts)?.text == 1, "once: there")

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

        // Room: one path for every change; a narrowing cut short is still put back.
        expect(NoteRoom.reconcile(narrowed: [3, 5], wanted: 5) == ([3], nil), "the window in front keeps its room, the others get theirs back")
        expect(NoteRoom.reconcile(narrowed: [3], wanted: 7) == ([3], 7), "and a new one narrows")
        expect(NoteRoom.reconcile(narrowed: [3, 7], wanted: nil) == ([3, 7], nil), "no note open (notes off, quitting): all back")
        let before = CGRect(x: 40, y: 60, width: 1380, height: 700), given = CGRect(x: 40, y: 60, width: 1036, height: 700)
        expect(NoteRoom.restore(before: before, given: given, now: given), "the frame Petal gave it goes back")
        expect(NoteRoom.restore(before: before, given: CGRect(x: 300, y: 60, width: 1036, height: 700), now: CGRect(x: 40, y: 60, width: 1036, height: 700)),
               "a change cut short (only its size Petal's) goes back")
        expect(!NoteRoom.restore(before: before, given: given, now: before), "already as it was: nothing to do")
        expect(!NoteRoom.restore(before: before, given: given, now: CGRect(x: 200, y: 100, width: 800, height: 500)), "moved and resized by the person: theirs")

        // A tab note seen on its own tab keeps the address it shows now.
        var followed = NoteStick(kind: .tab)
        followed.mac = "mac-1"; followed.pid = 50; followed.tabID = "t1"; followed.url = "https://a.example/one"; followed.shared = 1
        let moved = NoteScene(mac: "mac-1", app: "com.google.Chrome", pid: 50, window: 9, tab: NoteTab(id: "t1", shared: 1, url: "https://a.example/two", title: "Two"))
        expect(NoteMatch.followTab(followed, moved, keepWords: true)?.url == "https://a.example/two", "its tab's new address is saved")
        expect(NoteMatch.followTab(followed, moved, keepWords: false) == nil || NoteMatch.followTab(followed, moved, keepWords: false)?.url == followed.url,
               "a private app's address is never kept")
        expect(NoteMatch.followTab(followed, NoteScene(mac: "mac-1", pid: 50, tab: NoteTab(id: "t2", url: "https://a.example/two", title: "")), keepWords: true) == nil,
               "only on its own tab, surely")
        expect(NoteMatch.followTab(followed, NoteScene(mac: "mac-1", pid: 51, tab: NoteTab(id: "t1", url: "https://a.example/two", title: "")), keepWords: true) == nil,
               "never on another run of the browser")
        var same = followed
        same.url = "https://a.example/two"; same.title = "Two"
        expect(NoteMatch.followTab(same, moved, keepWords: true) == nil, "nothing changed: nothing saved")

        // MARK: Paper colors (the sketch's color-mix)

        let blue = NoteInk.hex("#007aff")!
        expect(NoteInk.hex(NoteInk.mix(blue, 1, NoteInk.paper)) == "#007aff" && NoteInk.hex(NoteInk.mix(blue, 0, NoteInk.paper)) == "#fffef9", "mixing ends")
        let paper = NoteInk.paper(blue)
        expect(paper.b > paper.r && paper.r > 0.85, "blue paper is a pale blue", NoteInk.hex(paper))

        print("notes: \(passed) passed" + (failures > 0 ? ", \(failures) failed" : ""))
        if failures > 0 { exit(1) }
    }
}
