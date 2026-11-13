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
        expect(NoteShelf.save(disk: "A", text: "T", base: "A") == .write && NoteShelf.save(disk: nil, text: "T", base: "A") == .write
               && NoteShelf.save(disk: nil, text: "T", base: nil) == .write,
               "a file as the edit began, or none, is written")
        expect(NoteShelf.save(disk: "B", text: "T", base: nil) == .keepBoth, "a new note never goes over a file that's there")
        expect(NoteShelf.save(disk: "T", text: "T", base: "A") == .already && NoteShelf.save(disk: "T", text: "T", base: nil) == .already,
               "a file that already says it (a write whose answer never came back, a quit's last try) is done, never a conflict")
        // The base rule: a write lands only on the exact text it was made on, or where its text already is.
        expect(NoteShelf.save(disk: "R1", text: "T2", base: "R1") == .write, "made on what's there: lands")
        expect(NoteShelf.save(disk: "R0", text: "T2", base: "T1") == .keepBoth, "made on a text that never landed (a write that failed): a copy, never over")
        expect(NoteShelf.save(disk: "R2", text: "T2", base: "R1") == .keepBoth, "made on an older one: a copy")

        // The journal, at launch: what a Petal before accepted and never saw land, found by its note's id.
        expect(NoteShelf.journalRecovery(disk: "T", base: "B", text: "T", aside: false) == .nothing, "landed after all: nothing")
        expect(NoteShelf.journalRecovery(disk: "B", base: "B", text: "T", aside: false) == .write, "the file as the edit began: written")
        expect(NoteShelf.journalRecovery(disk: "C", base: "B", text: "T", aside: false) == .copy, "changed elsewhere since: a copy beside it, never over")
        expect(NoteShelf.journalRecovery(disk: "B", base: "B", text: "T", aside: true) == .copy, "an edit kept aside: always a copy")
        expect(NoteShelf.journalTarget(found: ["/n/Work/Renamed.md"]) == .note("/n/Work/Renamed.md"), "found by its id after a rename: that note")
        expect(NoteShelf.journalTarget(found: []) == .separate, "its id gone (another note at its old path): a file of its own, never that note")
        expect(NoteShelf.journalTarget(found: ["/n/a.md", "/n/a 2.md"]) == .separate, "two papers of it: a file of its own")

        // A snapshot whose text landed goes only once every picture it references is saved.
        expect(NoteShelf.journalClears(snapshot: "t", landed: "t", referenced: ["p.png"], unsaved: []), "text landed, its picture saved: the snapshot goes")
        expect(!NoteShelf.journalClears(snapshot: "t", landed: "t", referenced: ["p.png"], unsaved: ["p.png"]),
               "text landed, its picture failed: the snapshot stays, with the picture's bytes")
        expect(NoteShelf.journalClears(snapshot: "t", landed: "t", referenced: ["p.png"], unsaved: ["other.png"]), "a failed picture it doesn't reference keeps nothing")
        expect(!NoteShelf.journalClears(snapshot: "t2", landed: "t", referenced: [], unsaved: []), "a newer snapshot stays")

        // The Desktop only when the app said it has no window in front; a window Petal couldn't read is no place.
        expect(NoteShelf.frontOffer(window: 7, none: false) == .window, "a window read: its places")
        expect(NoteShelf.frontOffer(window: nil, none: true) == .desktop, "no window, said so: the Desktop")
        expect(NoteShelf.frontOffer(window: nil, none: false) == .unknown, "a window that couldn't be read: no note, never the Desktop")

        // Windows: told apart by their live identity; two windows titled alike are two windows.
        var untitledA = NoteStick(kind: .window); untitledA.app = "com.apple.TextEdit"; untitledA.mac = "m"; untitledA.pid = 9; untitledA.window = 31; untitledA.title = "Untitled"
        var untitledB = untitledA; untitledB.window = 32
        expect(!untitledA.samePlace(untitledB), "two “Untitled” windows with different numbers are two places")
        var retitled = untitledA; retitled.title = "Renamed"
        expect(untitledA.samePlace(retitled), "the same window under a new title is the same place")
        var otherProcess = untitledA; otherProcess.pid = 10
        expect(!untitledA.samePlace(otherProcess), "another process's window of that number isn't it")
        var rememberedA = untitledA; rememberedA.window = nil; rememberedA.pid = nil
        var rememberedB = rememberedA
        expect(rememberedA.samePlace(rememberedB), "two remembered windows (no number) with the same title: told by title")
        rememberedB.title = ""; rememberedA.title = ""
        expect(!rememberedA.samePlace(rememberedB), "never by an empty title")
        expect(!rememberedA.samePlace(untitledA) || !untitledA.title.isEmpty, "one with a number isn't one without by title alone")
        rememberedA.title = "Untitled"
        expect(!rememberedA.samePlace(untitledA), "a live window and a remembered one: not the same by title alone")

        // A session belongs to one note: another note given a path a session still knows never gets it.
        expect(NoteShelf.session(at: "/n/A.md", noteID: "A", keys: ["/n/A.md": 1], noteIDs: [1: "A"]) == 1, "its own note: its session")
        expect(NoteShelf.session(at: "/n/A.md", noteID: "B", keys: ["/n/A.md": 1], noteIDs: [1: "A"]) == nil,
               "A renamed elsewhere, B now at A's old path: not A's session")
        expect(NoteShelf.rebind(key: "/n/A.md", at: ["/n/A renamed.md"]) == "/n/A renamed.md", "an idle session follows its note to its new name")
        expect(NoteShelf.rebind(key: "/n/A.md", at: ["/n/A.md"]) == nil && NoteShelf.rebind(key: "/n/A.md", at: ["/n/x.md", "/n/y.md"]) == nil,
               "where it was, or found twice: left alone")

        // A note renamed elsewhere while open: followed by its id, never left as a second paper.
        expect(NoteShelf.follow(memory: [("/n/A.md", "A")], read: [("/n/A renamed.md", "A")]) == ["/n/A.md": "/n/A renamed.md"],
               "renamed in Finder: the open note follows to its new path")
        expect(NoteShelf.follow(memory: [("/n/A.md", "A")], read: [("/n/A.md", "A")]).isEmpty, "where it was: nothing to follow")
        expect(NoteShelf.follow(memory: [("/n/A.md", "A")], read: [("/n/A.md", "A"), ("/n/A copy.md", "A")]).isEmpty,
               "its old path still there (a copy made elsewhere): not a rename")
        expect(NoteShelf.follow(memory: [("/n/A.md", "A")], read: [("/n/x.md", "A"), ("/n/y.md", "A")]).isEmpty, "two papers of that id read: no guess")
        expect(NoteShelf.follow(memory: [("/n/A.md", "A"), ("/n/B.md", "B")], read: [("/n/B.md", "A")]).isEmpty,
               "its new path is another note's in memory: not followed")
        expect(NoteShelf.follow(memory: [("/n/new.md", "N")], read: []).isEmpty, "a new note not on disk yet: left alone")

        // A paste's read ends: out of the journal only once its bytes and reference are stored, or nothing was read.
        expect(NoteShelf.importEnd(read: true, quitting: false, sameRoot: true, taken: true) == .accepted, "taken by its note: put in through its session")
        expect(NoteShelf.importEnd(read: true, quitting: false, sameRoot: true, taken: false) == .putIn, "rejected by its note: put in from the journal, never dropped")
        expect(NoteShelf.importEnd(read: true, quitting: false, sameRoot: false, taken: true) == .putIn, "the notes folder changed: into its note in its own folder")
        expect(NoteShelf.importEnd(read: true, quitting: true, sameRoot: true, taken: true) == .keepForLaunch, "quitting: kept for the next launch")
        expect(NoteShelf.importEnd(read: false, quitting: false, sameRoot: true, taken: true) == .nothingRead, "nothing readable: let go, and said")

        // Each file of a paste on its own: read, waiting (still there, not downloaded), or gone.
        expect(NoteShelf.sourceEnd(read: true, exists: false) == .taken && NoteShelf.sourceEnd(read: false, exists: true) == .waiting
               && NoteShelf.sourceEnd(read: false, exists: false) == .gone, "a paste's files end one by one")
        expect(NoteShelf.importEnd(read: true, waiting: true, quitting: false, sameRoot: true, taken: true) == .accepted,
               "one read, one waiting: the read one goes in (the waiting one stays, by SourceEnd)")
        expect(NoteShelf.importEnd(read: false, waiting: true, quitting: false, sameRoot: true, taken: true) == .waiting,
               "none read yet but still there: kept for Try again, never let go")

        // The latest notes folder asked for wins, even one asked for during a switch.
        let a = URL(fileURLWithPath: "/notes/A"), b = URL(fileURLWithPath: "/notes/B"), c = URL(fileURLWithPath: "/notes/C")
        expect(NoteShelf.nextRoot(wanted: b, current: a, switching: false) == b, "another folder asked for: switched to")
        expect(NoteShelf.nextRoot(wanted: c, current: a, switching: true) == nil, "asked again during a switch: waits for it")
        expect(NoteShelf.nextRoot(wanted: c, current: b, switching: false) == c, "once the switch to B is done, C (asked meanwhile) follows")
        expect(NoteShelf.nextRoot(wanted: b, current: b, switching: false) == nil, "the one in use: nothing")

        // The paper a lookup chose, kept: a conflict's copy stays that copy; a rename followed only when its id names
        // one paper; a path now another note's refused.
        let papers = [(key: "/n/A.md", id: "A"), (key: "/n/A (conflicted copy).md", id: "A"), (key: "/n/B.md", id: "B")]
        expect(NoteShelf.pick(key: "/n/A (conflicted copy).md", id: "A", now: papers) == 1, "reading a specific conflict copy reads that copy")
        expect(NoteShelf.pick(key: "/n/A gone.md", id: "A", now: papers) == nil, "gone, with its id on two papers: no guess")
        expect(NoteShelf.pick(key: "/n/B old.md", id: "B", now: papers) == 2, "renamed, its id on one paper: followed")
        expect(NoteShelf.pick(key: "/n/B.md", id: "C", now: papers) == nil, "its path now another note's: refused")

        // An id that named two papers when the request started is never followed by id, even if it names one now.
        expect(NoteShelf.pick(key: "/n/B old.md", id: "B", now: papers, unique: false) == nil, "ambiguous at the start: not followed")
        expect(NoteShelf.pick(key: "/n/B.md", id: "B", now: papers, unique: false) == 2, "its own file, still that note: kept")

        // Every change checks the file is still the note it means.
        expect(NoteShelf.stillNote(found: "A", expected: "A", missing: false), "the same note: changed")
        expect(!NoteShelf.stillNote(found: "B", expected: "A", missing: true), "another note at that path: never changed")
        expect(NoteShelf.stillNote(found: nil, expected: "A", missing: true) && !NoteShelf.stillNote(found: nil, expected: "A", missing: false),
               "no file there: a write makes it again, a move has nothing to move")

        // One placement per paper: the window in front first, the Desktop only when no window place fits.
        expect(NoteShelf.placement(window: 0, onDesktopShowing: true) == .window(0), "on a tab and the Desktop, the tab in front: by the window")
        expect(NoteShelf.placement(window: nil, onDesktopShowing: true) == .desktop, "nothing in front fits: the Desktop")
        expect(NoteShelf.placement(window: nil, onDesktopShowing: false) == .none, "neither: not shown")

        // File names from redacted titles only.
        expect(NoteShelf.safeStem(redacted: "# Card (hidden)\nmore", fallback: "Note 1") == "Card (hidden)", "a title holding a secret: named after redaction")
        expect(NoteShelf.safeStem(redacted: nil, fallback: "Note 1") == "Note 1", "the vault unreadable: a plain name")
        expect(NoteShelf.safeStem(redacted: "", fallback: "Note 1") == "Note 1", "no title: a plain name")

        // A trash never of an existing file Petal can't read to check.
        expect(!NoteShelf.mayTrashFile(.unreadable, foundID: nil, expected: "A", texts: ["x"]), "an unreadable file is never trashed")
        expect(NoteShelf.mayTrashFile(.missing, foundID: nil, expected: "A", texts: []), "nothing there: nothing to refuse")
        expect(NoteShelf.mayTrashFile(.text("x"), foundID: "A", expected: "A", texts: ["x"]) && !NoteShelf.mayTrashFile(.text("y"), foundID: "A", expected: "A", texts: ["x"])
               && !NoteShelf.mayTrashFile(.text("x"), foundID: "B", expected: "A", texts: ["x"]), "only that note, as Petal last saw it")
        expect(NoteShelf.needsID("file:Inbox/x.md") && !NoteShelf.needsID("5F3A-1"), "an id taken from a path needs a real one before a change")

        // An identity change is followed by every holder, scoped to the file: an id-less note's path id follows only
        // from that very file (its volume and inode), so a new file at that path never resolves to the moved note.
        let todo = "file:Inbox/Todo.md"
        let aliases = [NoteShelf.holderKey(id: todo, instance: "1:10"): "U1"]
        expect(NoteShelf.current(todo, instance: "1:10", aliases: aliases) == "U1", "from the file that was given its id: followed")
        expect(NoteShelf.current(todo, instance: "1:22", aliases: aliases) == todo, "from a new file at that path: not followed")
        expect(NoteShelf.current("U9", instance: "", aliases: aliases) == "U9" && NoteShelf.holderKey(id: "U9", instance: "1:10") == "U9",
               "a real id is never aliased or scoped")
        expect(NoteShelf.editorKeeps(typedIn: todo, instance: "1:10", paper: "U1", aliases: aliases), "the editor keeps its typing when its note is given an id")
        expect(!NoteShelf.editorKeeps(typedIn: todo, instance: "1:22", paper: "U1", aliases: aliases), "an editor on the new file at that path isn't that note")
        expect(!NoteShelf.editorKeeps(typedIn: "U2", instance: "", paper: "OTHER", aliases: aliases), "another note in the paper: saved first, then read")
        // A tool's request kept on the old file: follows it to where it moved; a request on the new file stays there.
        let nowPapers = [(key: "/n/Inbox/Todo.md", id: todo, instance: "1:22"), (key: "/n/Away/Todo.md", id: "U1", instance: "1:10")]
        expect(NoteShelf.follow(key: "/n/Inbox/Todo.md", id: todo, instance: "1:10", unique: true, aliases: aliases, now: nowPapers) == 1,
               "the moved note, given its id, followed from its own file")
        expect(NoteShelf.follow(key: "/n/Inbox/Todo.md", id: todo, instance: "1:22", unique: true, aliases: aliases, now: nowPapers) == 0,
               "the new file at the old path is itself")
        expect(NoteShelf.follow(key: "/n/Inbox/Todo.md", id: todo, instance: "1:10", unique: true, aliases: [:], now: [nowPapers[0]]) == nil,
               "the old file gone without an id given, a new one at its path: refused, never redirected")

        // An agent's picture number: only 1...count, never arithmetic on what it sent first.
        expect(NoteTold.pictureIndex(1, count: 2) == 0 && NoteTold.pictureIndex(2, count: 2) == 1, "pictures 1 and 2 of two")
        expect(NoteTold.pictureIndex(0, count: 2) == nil && NoteTold.pictureIndex(3, count: 2) == nil
               && NoteTold.pictureIndex(Int.min, count: 2) == nil && NoteTold.pictureIndex(Int.max, count: 2) == nil, "anything else is no picture")
        let invented = NoteTold.restorePictures("![picture -9223372036854775808]\n![picture 9223372036854775807]\n![picture 99999999999999999999]",
                                                from: "![](pictures-x.assets/p.png)")
        expect(invented == "![picture -9223372036854775808]\n![picture 9223372036854775807]\n![picture 99999999999999999999]",
               "invented numbers stay words, and nothing overflows")

        // A passage's tab follows its sentence as the page scrolls.
        let textShown = CGRect(x: 0, y: 100, width: 400, height: 300)
        expect(NoteShelf.passageSpot(words: CGRect(x: 10, y: 150, width: 100, height: 16), visible: textShown) == .line(CGRect(x: 10, y: 150, width: 100, height: 16)),
               "in view: at its line, with its pin")
        expect(NoteShelf.passageSpot(words: CGRect(x: 10, y: 60, width: 100, height: 16), visible: textShown) == .above, "scrolled up out of view: on the top edge")
        expect(NoteShelf.passageSpot(words: CGRect(x: 10, y: 420, width: 100, height: 16), visible: textShown) == .below, "scrolled down out of view: on the bottom edge")
        expect(NoteShelf.passageSpot(words: nil, visible: textShown) == .unknown, "not found: passage moved")
        expect(NoteShelf.passageSpot(words: CGRect(x: 10, y: 90, width: 100, height: 16), visible: textShown) == .line(CGRect(x: 10, y: 90, width: 100, height: 16)),
               "partly in view: at its line")

        // The passage watcher measures a remembered range only while it still holds the quote.
        let words = CGRect(x: 0, y: 10, width: 50, height: 14)
        expect(NoteShelf.passagePoll(read: "the sentence", quote: "the sentence", words: words, rescanned: false) == .still(words), "quote still there: at its words")
        expect(NoteShelf.passagePoll(read: "text put in b", quote: "the sentence", words: words, rescanned: false) == .relocate,
               "text put in before it: found again by quote and context")
        expect(NoteShelf.passagePoll(read: "the sentence", quote: "the sentence", words: nil, rescanned: false) == .relocate, "no bounds: found again")
        expect(NoteShelf.passagePoll(read: nil, quote: "the sentence", words: words, rescanned: true) == .moved,
               "found again and still not there: moved (no pin), never the text's frame")
        expect(NoteShelf.passagePoll(read: "the sentence", quote: "the sentence", words: words, rescanned: true) == .still(words), "found again: at its words")
        // And runs only while a passage note is here; a busy tick is skipped, never the end of watching.
        let tick = Date(timeIntervalSince1970: 1_000)
        expect(NoteShelf.passageWatch(wanted: [], anchored: ["a"], moved: [:], now: tick, busy: false) == .stop, "no passage note here: stop")
        expect(NoteShelf.passageWatch(wanted: ["a"], anchored: ["a"], moved: [:], now: tick, busy: true) == .skip, "a slow measurement: skip this tick, keep watching")
        expect(NoteShelf.passageWatch(wanted: ["a", "b"], anchored: ["a"], moved: [:], now: tick, busy: false) == .find, "a passage note not looked for yet: find it")
        expect(NoteShelf.passageWatch(wanted: ["a"], anchored: ["a"], moved: [:], now: tick, busy: false) == .measure, "all anchored: measure")
        expect(NoteShelf.passageWatch(wanted: [], anchored: [], moved: [:], now: tick, busy: true) == .stop, "the last passage note re-stuck elsewhere: stop, even mid-measure")
        // A moved passage is looked for again, every 2 seconds at most (Undo brings its sentence back).
        let movedA = ["a": tick.addingTimeInterval(-1)]
        expect(NoteShelf.passageWatch(wanted: ["a"], anchored: [], moved: movedA, now: tick, busy: false) == .skip, "moved a second ago: not yet")
        expect(NoteShelf.passageWatch(wanted: ["a"], anchored: [], moved: movedA, now: tick.addingTimeInterval(1), busy: false) == .find,
               "two seconds since: looked for again")
        expect(NoteShelf.passageWatch(wanted: ["a", "b"], anchored: ["b"], moved: movedA, now: tick, busy: false) == .measure,
               "the others measured meanwhile")
        expect(NoteShelf.passageWatch(wanted: ["a"], anchored: [], moved: ["a": tick.addingTimeInterval(-5)], now: tick, busy: true) == .skip,
               "a scan under way: the retry waits for the gate")
        expect(NoteShelf.retryMoved(lastTry: nil, now: tick) && !NoteShelf.retryMoved(lastTry: tick.addingTimeInterval(-1.9), now: tick)
               && NoteShelf.retryMoved(lastTry: tick.addingTimeInterval(-2), now: tick), "the retry schedule: 2 s")

        // Lasting records only by a real id that's in its file.
        expect(NoteShelf.lasting("U1", pending: []) && !NoteShelf.lasting("U1", pending: ["U1"]) && !NoteShelf.lasting("file:Inbox/a.md", pending: []),
               "a real id written: lasting; one still being written, or a path's id: memory only")
        let work = NoteShelf.copyKey(noteID: "U1", notebook: "Work", fileName: "Todo.md", version: nil)
        let home = NoteShelf.copyKey(noteID: "U1", notebook: "Home", fileName: "Todo.md", version: nil)
        let version = NoteShelf.copyKey(noteID: "U1", notebook: "Work", fileName: "Todo.md", version: "Todo.md")
        expect(work != home && work != version && home != version, "Work/Todo.md, Home/Todo.md and an iCloud version: three handles")
        expect(work == NoteShelf.copyKey(noteID: "U1", notebook: "Work", fileName: "Todo.md", version: nil), "the same paper, the same handle")
        expect(work.hasPrefix("U1#") && !work.contains("Todo") && !work.contains("Work"),
               "a conflict paper's key: its note's id and a hash of its file's name, no path")

        // A passage that moved is an explicit state: no line, no pin, not found.
        let pageWindow = CGRect(x: 0, y: 50, width: 800, height: 600)
        let pageText = CGRect(x: 0, y: 100, width: 800, height: 500)
        expect(NoteShelf.passagePlacement(.moved, window: pageWindow) == NoteShelf.PassagePlacement(line: nil, pin: nil, found: false),
               "moved: its old line and pin cleared, \"passage moved\"")
        let seen = CGRect(x: 20, y: 200, width: 200, height: 16)
        expect(NoteShelf.passagePlacement(.at(words: seen, visible: pageText), window: pageWindow) == NoteShelf.PassagePlacement(line: 150, pin: seen, found: true),
               "found: at its line, with its pin")
        expect(NoteShelf.passagePlacement(.at(words: CGRect(x: 20, y: 10, width: 200, height: 16), visible: pageText), window: pageWindow)
               == NoteShelf.PassagePlacement(line: 50, pin: nil, found: true), "scrolled above: on the top edge, no pin")

        // Scans of a window coalesce: one at a time, any number of requests meanwhile become one follow-up.
        var gate = NoteShelf.ScanGate()
        let starts = [gate.request(), gate.request(), gate.request(), gate.request()]
        expect(starts == [true, false, false, false], "one scan runs; the rest wait as one")
        expect(gate.finished() && gate.running, "it ends: the one follow-up starts")
        expect(!gate.finished() && !gate.running, "that ends: nothing more")
        expect(gate.request() && !gate.finished(), "a later request starts at once")

        // A folded note at the screen's right edge turned over (it grows) stays whole on its screen.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let flipped = NoteShelf.wholeOnScreen(CGRect(x: 1250, y: 600, width: 380, height: 420), visible: screen)
        expect(flipped == CGRect(x: 1060, y: 455, width: 380, height: 420), "it moves in from the edges it would cross", "\(flipped)")
        expect(NoteShelf.wholeOnScreen(CGRect(x: 100, y: 100, width: 190, height: 190), visible: screen) == CGRect(x: 100, y: 100, width: 190, height: 190),
               "one that fits stays where it is")
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        expect(NoteShelf.wholeOnScreen(CGRect(x: 3200, y: 100, width: 380, height: 420), visible: second).maxX == second.maxX, "on a second screen, its own edge")

        // Keep this one's plan always holds the current file at each path shown, its text and id.
        let mixed = NoteShelf.keepSnapshot(papers: [("/n/Inbox/T.md", "v1", "theirs")], current: ["/n/Inbox/T.md": ("mine", "MAC-A-ID")])
        expect(mixed?.snapshot["file:/n/Inbox/T.md"] == "mine" && mixed?.snapshot["version:v1"] == "theirs" && mixed?.ids["/n/Inbox/T.md"] == "MAC-A-ID",
               "a version with another id: the current file is in the plan anyway")
        expect(NoteShelf.keepSnapshot(papers: [("/n/Inbox/T.md", "v1", "theirs")], current: [:]) == nil, "the current file not known: no plan")
        expect(!NoteShelf.keepWrite(disk: "mine", shown: nil, diskID: "MAC-A-ID", shownID: nil), "never written over unchecked")
        expect(!NoteShelf.keepWrite(disk: "mine, edited", shown: "mine", diskID: "MAC-A-ID", shownID: "MAC-A-ID"), "changed since: refused")
        expect(!NoteShelf.keepWrite(disk: "mine", shown: "mine", diskID: "OTHER", shownID: "MAC-A-ID"), "another note now: refused")
        expect(NoteShelf.keepWrite(disk: "mine", shown: "mine", diskID: "MAC-A-ID", shownID: "MAC-A-ID"), "exactly as shown: written")

        // A link's page is fetched only for one the person added, only if it's an HTML page, and only its start.
        expect(NoteShelf.linkFetch("https://example.com/a", own: true, cached: false), "pasted or typed: fetched")
        expect(!NoteShelf.linkFetch("https://example.com/a", own: false, cached: false), "only shown in a note from sync: never")
        expect(!NoteShelf.linkFetch("https://example.com/a", own: true, cached: true) && !NoteShelf.linkFetch("file:///etc/hosts", own: true, cached: false),
               "already cached, or not http(s): not fetched")
        expect(NoteShelf.linkResponse(status: 200, contentType: "text/html; charset=utf-8") && NoteShelf.linkResponse(status: 200, contentType: "application/xhtml+xml"),
               "an HTML page: read")
        expect(!NoteShelf.linkResponse(status: 200, contentType: "video/mp4") && !NoteShelf.linkResponse(status: 200, contentType: "application/zip")
               && !NoteShelf.linkResponse(status: 200, contentType: nil) && !NoteShelf.linkResponse(status: 404, contentType: "text/html"),
               "a video, a download, no type, or not found: refused before any of it is read")
        expect(NoteShelf.linkLimit == 300_000, "read no more than 300 KB")

        // Conflicts by file and by id: a file and its iCloud versions are one group whatever their ids.
        let grouped = NoteShelf.conflictGroups([("MAC-A", "/n/Inbox/T.md"), ("MAC-B", "/n/Inbox/T.md"), ("MAC-C", "/n/Inbox/T.md"),
                                                ("U1", "/n/Work/Todo.md"), ("U1", "/n/Home/Todo.md"), ("U9", "/n/Inbox/Alone.md")])
        expect(grouped == [[0, 1, 2], [3, 4]], "a file with versions of other ids: one group (each shows Keep this one); one id in two files: one group",
               "\(grouped)")
        expect(NoteShelf.conflictGroups([("A", "/n/a.md"), ("B", "/n/b.md")]).isEmpty, "unrelated notes: no conflict")
        expect(NoteShelf.conflictGroups([("A", "/n/a.md"), ("B", "/n/a.md"), ("B", "/n/b.md")]) == [[0, 1, 2]], "joined through a version and an id")

        // A focus change hides the shown window's notes at once (until the new read is in).
        expect(NoteShelf.concealOnFocus(.activated, pid: 20, window: nil, shownPID: 10, shownWindow: 5, own: 1), "another app in front: hidden at once")
        expect(NoteShelf.concealOnFocus(.focused, pid: 10, window: 6, shownPID: 10, shownWindow: 5, own: 1), "another window of the app: hidden")
        expect(!NoteShelf.concealOnFocus(.focused, pid: 10, window: 5, shownPID: 10, shownWindow: 5, own: 1), "the same window again: stays")
        expect(NoteShelf.concealOnFocus(.gone, pid: 10, window: 5, shownPID: 10, shownWindow: 5, own: 1)
               && !NoteShelf.concealOnFocus(.gone, pid: 10, window: 9, shownPID: 10, shownWindow: 5, own: 1), "its own window closed: hidden; another closed: stays")
        expect(!NoteShelf.concealOnFocus(.activated, pid: 1, window: nil, shownPID: 10, shownWindow: 5, own: 1), "Petal's own windows: stay")
        expect(!NoteShelf.concealOnFocus(.activated, pid: 20, window: nil, shownPID: nil, shownWindow: nil, own: 1), "nothing shown on a window: nothing to hide")

        // Icons: fetched only with a link's allowed fetch (pasted or typed), streamed, images only, small.
        expect(!NoteShelf.linkFetch("https://example.com", own: false, cached: false), "drawing a card (not the person's adding): no fetch")
        expect(NoteShelf.fetchAccepts(.image, status: 200, contentType: "image/png") && NoteShelf.fetchAccepts(.image, status: 200, contentType: "image/x-icon"),
               "an image: read")
        expect(!NoteShelf.fetchAccepts(.image, status: 200, contentType: "text/html") && !NoteShelf.fetchAccepts(.image, status: 200, contentType: "video/mp4")
               && !NoteShelf.fetchAccepts(.image, status: 200, contentType: nil) && !NoteShelf.fetchAccepts(.image, status: 302, contentType: "image/png"),
               "a page, a video, no type, not 200: refused before reading")
        expect(NoteShelf.fetchLimit(.image) == 512_000 && NoteShelf.fetchLimit(.page) == 300_000, "an icon at most 512 KB, a page's start 300 KB")

        // A partial put-in advances its snapshot to what landed, never a newer one.
        expect(NoteShelf.advancedSnapshot(current: "t0", used: "t0", landed: "t0+p1") == "t0+p1", "the snapshot it was made from: advanced")
        expect(NoteShelf.advancedSnapshot(current: "t0, typed since", used: "t0", landed: "t0+p1") == nil, "a newer snapshot: left as it is")

        // Only a fresh read of the current look, of the app still in front, becomes the active scene.
        expect(NoteShelf.mayBecomeActive(.look, ticket: 7, current: 7, readPID: 10, frontPID: 10), "a fresh read of what's in front: active")
        expect(!NoteShelf.mayBecomeActive(.captured, ticket: 7, current: 7, readPID: 10, frontPID: 10),
               "Stick here's captured scene: only the new note's anchor, never active")
        expect(!NoteShelf.mayBecomeActive(.look, ticket: 7, current: 8, readPID: 10, frontPID: 10),
               "a read still under way when notes were hidden (a new look began): refused")
        expect(!NoteShelf.mayBecomeActive(.look, ticket: 7, current: 7, readPID: 10, frontPID: 20), "a late read of the app left behind: refused")
        expect(!NoteShelf.mayBecomeActive(.look, ticket: 7, current: 7, readPID: 10, frontPID: nil), "no app known in front: refused")

        // The rest of a partly recovered entry continues where its first part landed (unless that's the note itself).
        expect(NoteShelf.continuation(landedAt: "/n/Inbox/T.md", notePaths: ["/n/Inbox/T.md"]) == nil, "landed in the note: found by its id as usual")
        expect(NoteShelf.continuation(landedAt: "/support/Unsaved notes/T.md", notePaths: ["/n/Inbox/T.md"]) == "/support/Unsaved notes/T.md",
               "landed in Unsaved notes: continues there")
        expect(NoteShelf.continuation(landedAt: "/n/Inbox/T (conflicted copy).md", notePaths: ["/n/Inbox/T.md"]) == "/n/Inbox/T (conflicted copy).md",
               "landed in a copy beside it: continues there")
        expect(NoteShelf.continueAt("/support/Unsaved notes/T.md", exists: true) && !NoteShelf.continueAt("/support/Unsaved notes/T.md", exists: false)
               && !NoteShelf.continueAt(nil, exists: true), "only while that file is there; gone, found as usual")

        // A note is made only from a read that became active and is still active after the selection read.
        expect(NoteShelf.mayCreate(activated: true, activePID: 10, activeWindow: 5, readPID: 10, readWindow: 5, frontPID: 10), "still in front: made")
        expect(!NoteShelf.mayCreate(activated: false, activePID: 10, activeWindow: 5, readPID: 10, readWindow: 5, frontPID: 10), "the read was refused: no note")
        expect(!NoteShelf.mayCreate(activated: true, activePID: 20, activeWindow: 7, readPID: 10, readWindow: 5, frontPID: 20),
               "another app came in front during the selection read: no note")
        expect(!NoteShelf.mayCreate(activated: true, activePID: 10, activeWindow: 6, readPID: 10, readWindow: 5, frontPID: 10), "another window of it: no note")
        expect(NoteShelf.mayTakeKeyboard(shown: true) && !NoteShelf.mayTakeKeyboard(shown: false), "the keyboard only for a paper layout showed")

        // A rescue carries every picture its text references; complete only when they're all there.
        let illustrated = NoteFile(id: "R", body: "# Trip\n![](pictures-a.assets/old.png)\nwords\n![shot](pictures-a.assets/new.png)\n![](https://example.com/web.png)").serialized()
        expect(NoteShelf.referencedPictures(illustrated) == ["pictures-a.assets/old.png", "pictures-a.assets/new.png"], "its own pictures, not a web picture")
        expect(!NoteShelf.rescueComplete(referenced: ["a", "b"], present: ["b"]) && NoteShelf.rescueComplete(referenced: ["a", "b"], present: ["a", "b"]),
               "complete only with every picture")

        // The rest of a recovery over the file it continues at: never over one that can't be read, or changed.
        expect(NoteShelf.continueWrite(.missing, base: "t", text: "t2") == .write, "nothing there: written")
        expect(NoteShelf.continueWrite(.text("t"), base: "t", text: "t2") == .write && NoteShelf.continueWrite(.text("t2"), base: "t", text: "t2") == .write,
               "what landed there (or already it): written")
        expect(NoteShelf.continueWrite(.unreadable, base: "t", text: "t2") == .separate, "a file that can't be read: kept, the rest to a file of its own")
        expect(NoteShelf.continueWrite(.text("edited"), base: "t", text: "t2") == .separate, "changed since: kept")

        // A keyboard request waits for layout to show its paper.
        var keys = NoteShelf.KeyboardRequests()
        expect(!keys.request("desk", shown: false) && keys.pending == ["desk"], "the first Desktop note, not shown yet: waits")
        expect(keys.shown("desk") && keys.pending.isEmpty, "shown by layout: the keyboard, once")
        expect(!keys.shown("desk"), "shown again later: nothing more")
        expect(keys.request("w", shown: true) && keys.pending.isEmpty, "already shown: at once")
        _ = keys.request("x", shown: false)
        keys.cancelAll()
        expect(!keys.shown("x"), "the person clicked elsewhere first: dropped")

        // Captions with brackets, backslashes and parentheses (and paths with them) round-trip.
        for (path, caption) in [("pictures-a.assets/Screenshot [draft].png", "Screenshot [draft]"), ("x/(2).png", "back\\slash (and) [x]"),
                                ("a b/c.png", "]["), ("p.png", "plain"), ("q/r[1].png", "\\[")] {
            let line = NoteBlock.image(path: path, caption: caption).markdown
            expect(NoteBlock.parse(line) == .image(path: path, caption: caption), "a picture line round-trips", line)
        }
        expect(NoteBlock.parse("![a](b)c)") == .text("![a](b)c)") && NoteBlock.parse("![a[b](c)") == .text("![a[b](c)"), "a broken one stays words")
        expect(NoteBlock.parse("![cap](<a b.assets/p.png>)") == .image(path: "a b.assets/p.png", caption: "cap"), "older lines read as before")

        // A move carries only pictures linked beside the note (handwritten, or an older link), never Petal's own in
        // the notes' Pictures, and never over another picture.
        expect(NoteShelf.carried([NoteShelf.pictureLink(id: "X", name: "a.png"), "Trip.assets/photo.png", "pictures-x.assets/b.png", "../Other/c.png", "a/../../d.png"])
               == ["Trip.assets/photo.png", "pictures-x.assets/b.png"], "Petal's own and links that leave the notebook stay; the rest are carried")
        expect(NoteShelf.carry(destinationExists: false, same: false) == .copy && NoteShelf.carry(destinationExists: true, same: true) == .already
               && NoteShelf.carry(destinationExists: true, same: false) == .stop, "copied, already there, or the move stops")

        // A re-key moves every per-paper record, the pending keyboard request too.
        expect(NoteShelf.rekeyed(["/n/A.md": 1, "/n/B.md": 2], "/n/A.md", "/n/Away/A.md") == ["/n/Away/A.md": 1, "/n/B.md": 2], "a record follows its paper")
        expect(NoteShelf.rekeyed(["/n/B.md": 2], "/n/A.md", "/n/Away/A.md") == ["/n/B.md": 2], "none for it: nothing changes")
        var wanted = NoteShelf.KeyboardRequests()
        _ = wanted.request("/n/A.md", shown: false)
        wanted.rekey("/n/A.md", "/n/Away/A.md")
        expect(wanted.shown("/n/Away/A.md") && !wanted.shown("/n/A.md"), "a keyboard request waiting while its paper moved: kept")

        // A paper shows only where its one placement says it belongs right now.
        expect(NoteShelf.placementNow(window: nil, desktops: [2], showing: [1]) == .none, "its window anchor gone, its Desktop not showing: hidden")
        expect(NoteShelf.placementNow(window: nil, desktops: [2], showing: [1, 2]) == .desktop, "its Desktop showing: there")
        expect(NoteShelf.placementNow(window: 0, desktops: [2], showing: [2]) == .window(0), "its window in front: by the window")
        expect(NoteShelf.placementNow(window: nil, desktops: [nil], showing: [1]) == .none, "a Desktop place with no number: nowhere")

        // Mission Control hides every surface until it ends; nothing breaks when it's never said.
        expect(!NoteShelf.mayShow(.window(0), missionControl: true, awaitingRead: false) && !NoteShelf.mayShow(.desktop, missionControl: true, awaitingRead: false),
               "Mission Control open: nothing shows")
        expect(NoteShelf.mayShow(.window(0), missionControl: false, awaitingRead: false) && NoteShelf.mayShow(.desktop, missionControl: false, awaitingRead: false),
               "closed (or never said open): as placed")
        expect(!NoteShelf.mayShow(.window(0), missionControl: false, awaitingRead: true) && NoteShelf.mayShow(.desktop, missionControl: false, awaitingRead: true)
               && !NoteShelf.mayShow(.none, missionControl: false, awaitingRead: false), "a read awaited: the window's wait, Desktop notes stay; no placement: hidden")

        // Each rescue its own folder: by its note's id (hashed) and the moment.
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        expect(NoteShelf.rescueFolder(noteID: "W1", at: at) != NoteShelf.rescueFolder(noteID: "H1", at: at)
               && NoteShelf.rescueFolder(noteID: "W1", at: at) != NoteShelf.rescueFolder(noteID: "W1", at: at.addingTimeInterval(0.01))
               && !NoteShelf.rescueFolder(noteID: "file:Inbox/Card 4111.md", at: at).contains("4111"), "two notes, or two moments: two folders; nothing of the id")

        // A keyboard request for a paper on a window being brought forward survives that window's activation only.
        var tagged = NoteShelf.KeyboardRequests()
        _ = tagged.request("drop", shown: false, expecting: .init(pid: 30, window: 7))
        _ = tagged.request("plain", shown: false)
        tagged.focusMoved(pid: 30, window: nil)
        expect(tagged.pending == ["drop"], "the app brought forward activates: its request stays, an untagged one goes")
        tagged.focusMoved(pid: 30, window: 7)
        expect(tagged.shown("drop"), "its window focused: still waiting, then honored")
        _ = tagged.request("drop2", shown: false, expecting: .init(pid: 30, window: 7))
        tagged.focusMoved(pid: 30, window: 9)
        expect(tagged.pending.isEmpty, "another window of that app: dropped")
        _ = tagged.request("drop3", shown: false, expecting: .init(pid: 30, window: 7))
        tagged.focusMoved(pid: 44, window: nil)
        expect(tagged.pending.isEmpty, "another app: dropped")

        // The Mission Control watcher runs while anyone needs it: the notes alone keep it on.
        var users = NoteShelf.TrackerUsers()
        users.need("dock", true)
        users.need("notes", true)
        users.need("dock", false)
        expect(users.listening, "macOS's Dock chosen (Petal's dock off), notes on: still watching")
        users.need("notes", false)
        expect(!users.listening, "nobody needs it: stopped")

        // Accessibility is polled while anyone listens to windows: the notes or the Mission Control watcher alone too.
        expect(NoteShelf.permissionPoll(consumers: ["notes"]) && NoteShelf.permissionPoll(consumers: ["missioncontrol"]) && !NoteShelf.permissionPoll(consumers: []),
               "polled for whoever listens, without Petal's dock")

        // A window anchor confirmed by live identity takes the window's title as it is now.
        var untitled = NoteStick(kind: .window); untitled.mac = "m"; untitled.pid = 9; untitled.window = 31; untitled.title = "Untitled"; untitled.app = "com.apple.TextEdit"
        var saved = NoteScene(mac: "m", app: "com.apple.TextEdit", pid: 9, window: 31, title: "Trip plan.rtf")
        expect(NoteShelf.followedTitle(untitled, scene: saved) == "Trip plan.rtf", "saved since: the anchor takes its new title")
        saved.window = 32
        expect(NoteShelf.followedTitle(untitled, scene: saved) == nil, "another window (titled anything): never")
        saved.window = 31; saved.title = ""
        expect(NoteShelf.followedTitle(untitled, scene: saved) == nil, "no title read (a private app): never")
        var remembered = untitled; remembered.window = nil
        expect(NoteShelf.followedTitle(remembered, scene: NoteScene(mac: "m", app: "com.apple.TextEdit", pid: 9, window: 31, title: "X")) == nil,
               "an anchor not confirmed by its window number: never")

        // A tab switching in the browser window shown hides its tab and passage notes until the tab is read again.
        expect(NoteShelf.hiddenDuringTabRead(.tab) && NoteShelf.hiddenDuringTabRead(.passage) && !NoteShelf.hiddenDuringTabRead(.window)
               && !NoteShelf.hiddenDuringTabRead(.app), "tab and passage notes hide; the window's and the app's stay")
        expect(NoteShelf.tabReread(switched: true, eventPID: 5, eventWindow: 7, shownPID: 5, shownWindow: 7, browser: true), "its tab switched: hidden")
        expect(!NoteShelf.tabReread(switched: true, eventPID: 5, eventWindow: 8, shownPID: 5, shownWindow: 7, browser: true)
               && !NoteShelf.tabReread(switched: true, eventPID: 5, eventWindow: 7, shownPID: 5, shownWindow: 7, browser: false)
               && !NoteShelf.tabReread(switched: false, eventPID: 5, eventWindow: 7, shownPID: 5, shownWindow: 7, browser: true),
               "another window, not a browser, or not a switch: nothing hides")

        // Handles: letters only, and made again when the redaction would change one.
        var turn = 0
        let letters = NoteShelf.handleLetters(12) { turn += 1; return turn * 7 }
        expect(letters.count == 12 && letters.allSatisfy { $0.isLetter && $0.isLowercase }, "letters only, never digits", letters)
        expect(NoteShelf.handleSurvives("nabcdef", redact: { $0 }) && !NoteShelf.handleSurvives("nab737", redact: { $0.replacingOccurrences(of: "737", with: "(hidden)") }),
               "one the redaction changes is made again")

        // The Mission Control safety net: Mission Control's own Dock windows, or the bar while Petal hides it; never past a minute.
        let opened = Date(timeIntervalSince1970: 1_000)
        expect(!NoteShelf.missionControlOpen(dockWindows: [("Dock", true)], barHiddenByPetal: false, lastOpened: opened, now: opened.addingTimeInterval(3)),
               "macOS's Dock showing as usual (its bar): Mission Control closed")
        expect(NoteShelf.missionControlOpen(dockWindows: [("Dock", true)], barHiddenByPetal: true, lastOpened: opened, now: opened.addingTimeInterval(3)),
               "Petal hides macOS's Dock and its bar came out: Mission Control")
        expect(NoteShelf.missionControlOpen(dockWindows: [("Dock", true), ("", true)], barHiddenByPetal: false, lastOpened: opened, now: opened.addingTimeInterval(3)),
               "a Dock window that isn't its bar: Mission Control")
        expect(NoteShelf.missionControlOpen(dockWindows: [("", true)], barHiddenByPetal: false, lastOpened: opened, now: opened.addingTimeInterval(600)),
               "Mission Control's own window still up: open, however long (evidence beats the limit)")
        expect(!NoteShelf.missionControlOpen(dockWindows: [("Dock", true)], barHiddenByPetal: true, lastOpened: opened, now: opened.addingTimeInterval(61)),
               "only the bar while Petal hides it, a minute without a fresh opening: taken as closed")
        expect(!NoteShelf.missionControlOpen(dockWindows: [], barHiddenByPetal: true, lastOpened: opened, now: opened.addingTimeInterval(3)), "no Dock window: closed")
        // A note made from a selection whose place can't hold the sentence starts with the words selected.
        expect(NoteShelf.quoted("Growth held steady") == "> Growth held steady\n\n", "the words selected, as a quote to write under")
        expect(NoteShelf.quoted("one\n  two ") == "> one\n> two\n\n", "each line quoted")
        expect(NoteShelf.quoted(nil).isEmpty && NoteShelf.quoted("  \n").isEmpty, "nothing selected: an empty note")
        expect(NoteShelf.quoted(String(repeating: "a", count: 900)).count == 2 + 500 + 2, "never more than 500 characters of it")
        expect(NoteShelf.untouched("", madeWith: nil) && NoteShelf.untouched("> a word\n\n", madeWith: "> a word\n\n"), "a new note with nothing, or only its quote, is untouched")
        expect(!NoteShelf.untouched("> a word\n\nmine", madeWith: "> a word\n\n") && !NoteShelf.untouched("mine", madeWith: nil), "one the person wrote in isn't")
        // macOS's Dock is showing only when its bar sits on a screen (as read on macOS 27.3: hidden it waits at the edge).
        let dockScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        expect(NoteShelf.dockBarShowing(CGRect(x: 363, y: 1019, width: 1194, height: 51), screens: [dockScreen]), "its bar on the screen (Mission Control): showing")
        expect(!NoteShelf.dockBarShowing(CGRect(x: 363, y: 1080, width: 1194, height: 51), screens: [dockScreen]), "its bar just past the bottom edge: hidden")
        expect(!NoteShelf.dockBarShowing(.zero, screens: [dockScreen]), "a Dock that just started, its bar with no size yet: not showing")
        expect(!NoteShelf.dockBarShowing(CGRect(x: 363, y: 1060, width: 1194, height: 51), screens: [dockScreen]), "mostly past the edge (sliding away): not showing")
        expect(NoteShelf.dockBarShowing(CGRect(x: 1920, y: 300, width: 51, height: 600), screens: [dockScreen, CGRect(x: 1920, y: 0, width: 1440, height: 900)]), "on a second screen's edge: showing")
        // While Petal hides macOS's Dock, its window coming onto the screen is Mission Control (macOS 27 sends no event).
        expect(NoteShelf.missionControl(dockOut: true, fullScreen: false, open: false) == true, "macOS's Dock came out while Petal hides it: Mission Control opened")
        expect(NoteShelf.missionControl(dockOut: false, fullScreen: false, open: true) == false, "it left the screen: Mission Control closed")
        expect(NoteShelf.missionControl(dockOut: false, fullScreen: false, open: false) == nil, "gone while nothing was open: nothing to say")
        expect(NoteShelf.missionControl(dockOut: true, fullScreen: true, open: false) == nil, "in a full-screen app's Space the Dock comes out at the screen's edge: not Mission Control")
        expect(NoteShelf.missionControl(dockOut: false, fullScreen: true, open: true) == false, "and leaving still closes one that was open")

        // An open editor fences its note only while it has typing not saved yet; an idle one takes another Mac's version.
        expect(NoteShelf.fenceEditor(dirty: true) && !NoteShelf.fenceEditor(dirty: false), "fenced only while dirty")
        expect(NoteShelf.editorTakesNewer(bodyChanged: true, dirty: false), "idle (focused or not): the newer version at once")
        expect(!NoteShelf.editorTakesNewer(bodyChanged: true, dirty: true) && !NoteShelf.editorTakesNewer(bodyChanged: false, dirty: false),
               "typing waiting to be saved: kept (saved on the file it was made on); nothing new: nothing")
        expect(NoteShelf.keptSelection(location: 40, length: 5, newLength: 30) == (30, 0) && NoteShelf.keptSelection(location: 10, length: 5, newLength: 30) == (10, 5),
               "the cursor stays where it was, within the new text")

        // A title change anywhere is followed by the event's own process and window identity.
        var behind = NoteStick(kind: .window); behind.mac = "m"; behind.pid = 12; behind.window = 70; behind.title = "Untitled"
        expect(NoteShelf.followedTitle(behind, mac: "m", pid: 12, window: 70, title: "Budget.numbers") == "Budget.numbers", "a window behind, renamed: followed")
        expect(NoteShelf.followedTitle(behind, mac: "m", pid: 12, window: 71, title: "Budget.numbers") == nil
               && NoteShelf.followedTitle(behind, mac: "m", pid: 13, window: 70, title: "Budget.numbers") == nil
               && NoteShelf.followedTitle(behind, mac: "other", pid: 12, window: 70, title: "Budget.numbers") == nil
               && NoteShelf.followedTitle(behind, mac: "m", pid: 12, window: nil, title: "Budget.numbers") == nil,
               "another window, process, Mac, or no window: never")

        // A paper dragged out of the AI button: the real pointer is hit; only the paper's landing is offset.
        let drop = NoteShelf.dropPoints(pointer: CGPoint(x: 500, y: 300))
        expect(drop.hit == CGPoint(x: 500, y: 300) && drop.paper == CGPoint(x: 480, y: 320), "hit at the pointer, the paper at the ghost's corner")

        // Hiding notes for a tab switch starts a new look: an older read can't undo it.
        let lookBefore = 7, lookAfter = NoteShelf.hidingLook(7)
        expect(!NoteShelf.mayBecomeActive(.look, ticket: lookBefore, current: lookAfter, readPID: 5, frontPID: 5),
               "the read of the tab before the switch: refused")

        // An editor's dirty marker clears when its save runs; a version that waited is taken then.
        var marker = NoteShelf.EditorMarker()
        marker.typed()
        expect(marker.dirty && !marker.newer() && marker.deferred, "typed, not saved: another Mac's version waits")
        expect(marker.saved() && !marker.dirty && !marker.deferred, "the save ran: clean, and the version that waited is taken")
        expect(!marker.saved(), "saved again with nothing waiting: nothing to take")
        expect(marker.newer(), "clean: a newer version at once")

        // Shortcuts: the notes' (⌃⌥N) on its own, whichever dock.
        expect(NoteShelf.shortcutGroups(shortcuts: true, dockShown: false, notes: true) == (false, true), "macOS's Dock chosen, notes on: ⌃⌥N still")
        expect(NoteShelf.shortcutGroups(shortcuts: true, dockShown: true, notes: false) == (true, false), "notes off: the dock's only")
        expect(NoteShelf.shortcutGroups(shortcuts: false, dockShown: true, notes: true) == (false, false), "shortcuts off: none")

        // A queued move stops after its flush was kept beside the file.
        expect(NoteShelf.stopMove(afterFlush: true) && !NoteShelf.stopMove(afterFlush: false), "kept beside: the move stops; written: it goes")

        // A drop filtered again for privacy after its last wait.
        expect(NoteShelf.refilterDrop(readPrivacy: 3, nowPrivacy: 4, appPrivate: false) && NoteShelf.refilterDrop(readPrivacy: 3, nowPrivacy: 3, appPrivate: true)
               && !NoteShelf.refilterDrop(readPrivacy: 3, nowPrivacy: 3, appPrivate: false), "private apps changed, or the app private now: filtered again")

        // Accessibility taken away: window notes hide at once; given back: a fresh read first.
        expect(NoteShelf.onPermission(live: false) == (true, true) && NoteShelf.onPermission(live: true) == (false, true), "hide on revocation, read afresh on return")

        // A Desktop anchor only with the Desktop's number: unknown, refused (nothing changes).
        expect(NoteShelf.desktopAnchor(number: nil) == nil, "the Desktop showing unknown (macOS's Dock chosen, nothing read yet): refused")
        expect(NoteShelf.desktopAnchor(number: 3)?.desktop == 3, "known: the anchor, with its number")

        // Space and screen changes are followed while notes are on, with or without Accessibility.
        expect(NoteShelf.spaceSignals(notesOn: true, accessibility: false) && !NoteShelf.spaceSignals(notesOn: false, accessibility: true),
               "Accessibility taken away: Desktops still followed; notes off: not")

        // A place from when the Mac had modes still says `mode`: kept as written, on the place it was on, and read by
        // nothing (the note shows on its Desktop, whatever the mode said).
        let moded = "---\nid: 5F0C2A1E-0000-4000-8000-000000000001\nplaces:\n  - kind: desktop\n    mode: \"social\"\n    desktop: 2\n  - kind: app\n    app: \"com.apple.Safari\"\n---\nBuy milk\n"
        let old = NoteFile.parse(moded, fallbackID: "", fallbackDate: Date())
        expect(old.places.count == 2 && old.places[0].kind == .desktop && old.places[0].desktop == 2, "a Desktop place with a mode is still its Desktop's")
        expect(old.places[0].extra.map(\.key) == ["mode"] && old.places[1].extra.isEmpty, "the mode is kept on its own place, as a key Petal doesn't read")
        let again = old.serialized()
        expect(again.contains("    mode: \"social\"") && NoteFile.parse(again, fallbackID: "", fallbackDate: Date()).places == old.places, "and written back as it was")
        expect(old.places[0].label() == "Desktop 2", "its label is its Desktop")

        // Reads of what's in front: one at a time, one follow-up; a stale one asks the app nothing more.
        var readGate = NoteShelf.ReadGate()
        let readStarts = (0..<5).map { _ in readGate.request() }
        expect(readStarts == [true, false, false, false, false] && readGate.finished() && !readGate.finished(),
               "five looks while a slow browser answers: one read, then one follow-up")
        expect(NoteShelf.readCurrent(ticket: 4, now: 4) && !NoteShelf.readCurrent(ticket: 4, now: 5), "its look gone: stale")

        // Hiding a window's notes gives every narrowed window its width back at once.
        expect(NoteShelf.onHide() == (true, true), "narrowing cancelled, widths given back")

        // Stick here waits for the answer.
        expect(!NoteShelf.stickReady(running: true, queued: 0) && !NoteShelf.stickReady(running: false, queued: 1) && NoteShelf.stickReady(running: false, queued: 0),
               "a reply being written or a turn waiting: not yet; done: sticks")

        // The notes folder resolved off the main thread, kept until its setting changes.
        let resolved = URL(fileURLWithPath: "/notes/A")
        expect(NoteShelf.cachedRoot(setting: "", cached: ("", resolved)) == resolved, "the same setting: the folder already resolved, no probe")
        expect(NoteShelf.cachedRoot(setting: "~/Notes", cached: ("", resolved)) == nil && NoteShelf.cachedRoot(setting: "", cached: nil) == nil,
               "the setting changed, or nothing resolved yet: resolved again (off the main thread)")

        // The quick question's capture: only the latest opening's lands.
        expect(NoteShelf.captureCurrent(3, latest: 3) && !NoteShelf.captureCurrent(2, latest: 3), "an earlier opening's late capture: dropped")

        // A notebook by name whatever its case; places compared by the file system's identity.
        expect(NoteShelf.canonicalNotebook("inbox", existing: ["Inbox", "Work"]) == "Inbox" && NoteShelf.canonicalNotebook("Trips", existing: ["Inbox"]) == "Trips",
               "\"inbox\" is Inbox; a new name stays as asked")
        expect(NoteShelf.sameItem("1:5", "1:5") && !NoteShelf.sameItem("1:5", "1:6") && !NoteShelf.sameItem(nil, nil) && !NoteShelf.sameItem("", ""),
               "the same volume and inode: the same; unknown: never")

        // A piece of work is claimed once: the queue and the quit drain never both do it.
        let claimed = NoteShelf.claim(5, [])
        expect(claimed == [5] && NoteShelf.claim(5, claimed ?? []) == nil, "claimed once; the second asker leaves it")

        // A session's key follows its file, never onto a name another session holds.
        let made = NoteShelf.rekey(["/n/Foo.md": 1, "/n/Foo 2.md": 2], session: 1, from: "/n/Foo.md", to: "/n/Foo 3.md")
        expect(made == ["/n/Foo 2.md": 2, "/n/Foo 3.md": 1], "a new note landing under another name: its key moves, the other's stays", "\(String(describing: made))")
        expect(NoteShelf.rekey(["/n/Foo.md": 1, "/n/Foo 2.md": 2], session: 1, from: "/n/Foo.md", to: "/n/Foo 2.md") == nil,
               "the disk's name is another note's: refused, both keep their own")
        expect(NoteShelf.rekey(["/n/Foo.md": 1], session: 1, from: "/n/Foo.md", to: "/n/Foo.md") == ["/n/Foo.md": 1], "the same name: unchanged")
        expect(NoteShelf.journalPictures(text: "see ![](x.assets/picture-a.png)", pending: ["picture-a.png", "picture-b.png"]) == ["picture-a.png"],
               "a snapshot carries the bytes its text references")
        expect(NoteShelf.journalPictures(text: "undone", pending: ["picture-a.png"]).isEmpty, "a paste undone: its bytes leave with it")
        expect(NoteShelf.journalFolders(["Notes journal", "Notes journal, recovering 2", "Notes journal, recovering 1", "Other"])
               == ["Notes journal, recovering 1", "Notes journal, recovering 2"], "every recovery a launch before didn't finish is resumed, oldest first")

        // Pictures: bytes first, then their reference, as ordinary text.
        expect(NoteShelf.pictureReference(bytesWritten: true, editorOpen: true, quitting: false) == .editor, "bytes in, editor open: into the editor")
        expect(NoteShelf.pictureReference(bytesWritten: true, editorOpen: false, quitting: false) == .write,
               "folded before the import finished: a based write at the end of the note")
        expect(NoteShelf.pictureReference(bytesWritten: false, editorOpen: true, quitting: false) == .wait, "bytes not in yet: no reference, tried again")
        expect(NoteShelf.pictureReference(bytesWritten: true, editorOpen: true, quitting: true) == .write, "quitting with the bytes in: the reference is written")
        expect(NoteShelf.pictureReference(bytesWritten: false, editorOpen: false, quitting: true) == .unsaved,
               "quitting before the import: the pictures and the note go to Unsaved notes")
        expect(!NoteShelf.mayTrash(bodyEmpty: true, picturesPending: true, importing: false) && NoteShelf.mayTrash(bodyEmpty: true, picturesPending: false, importing: false)
               && !NoteShelf.mayTrash(bodyEmpty: false, picturesPending: false, importing: false), "a new note with a picture on its way is never trashed")
        expect(!NoteShelf.mayTrash(bodyEmpty: true, picturesPending: false, importing: true),
               "a new note with a pasted picture still being read (a slow iCloud file) isn't empty")
        expect(!NoteShelf.journalClears(snapshot: "t", landed: "t", referenced: [], unsaved: [], importing: true),
               "a snapshot with a paste still being read stays, with its source, when its text lands")

        // Keep this one: only on exactly what was shown.
        let shown = ["file:/n/A.md": "a", "version:v1": "b"]
        expect(NoteShelf.keepAllowed(shown: shown, now: ["file:/n/A.md": "a", "version:v1": "b"]), "unchanged: kept")
        expect(!NoteShelf.keepAllowed(shown: shown, now: ["file:/n/A.md": "a", "version:v1": "b", "version:v2": "c"]), "a version that arrived since: nothing removed")
        expect(!NoteShelf.keepAllowed(shown: shown, now: ["file:/n/A.md": "a edited", "version:v1": "b"]), "one edited since: nothing removed")
        expect(!NoteShelf.keepAllowed(shown: shown, now: ["file:/n/A.md": String?.none, "version:v1": "b"]), "one gone: nothing removed")
        var placed = NoteFile(id: "R", created: when, body: "my words")
        let editorBase = placed.serialized()
        placed.places = [tabForRebase()]
        let petalChanged = placed.serialized()
        expect(NoteShelf.rebase(editor: editorBase, current: petalChanged, currentBody: "my words") == petalChanged,
               "Petal's own change of a note's places is no reason to keep both")
        expect(NoteShelf.rebase(editor: editorBase, current: petalChanged, currentBody: "words from elsewhere") == editorBase,
               "words changed elsewhere are")
        expect(NoteShelf.save(disk: "B", text: "T", base: "A") == .keepBoth, "a file changed since the edit began: both are kept")
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

        // Petal's pictures: one folder per note at the notes' root, by the note's id; never shared, never beside notes.
        let ownFolder = NoteShelf.pictureFolder(id: "5F3A-1")
        expect(ownFolder.hasPrefix("Pictures/") && !ownFolder.contains("5F3A") && ownFolder.split(separator: "/").count == 2
               && ownFolder == NoteShelf.pictureFolder(id: "5F3A-1"), "a note's pictures' folder in Pictures, the same every time", ownFolder)
        expect(NoteShelf.pictureFolder(id: "file:Inbox/My notes.md") != NoteShelf.pictureFolder(id: "file:Inbox/My-notes.md"),
               "ids that read alike never share one", NoteShelf.pictureFolder(id: "file:Inbox/My notes.md"))
        let ownLink = NoteShelf.pictureLink(id: "5F3A-1", name: "p.png")
        expect(ownLink == "../" + ownFolder + "/p.png", "a note links its picture from its notebook", ownLink)
        expect(NoteShelf.resolvedLink(ownLink, from: "/n/Inbox") == "/n/" + ownFolder + "/p.png"
               && NoteShelf.resolvedLink(ownLink, from: "/n/Work") == "/n/" + ownFolder + "/p.png", "the same picture from every notebook")
        expect(NoteShelf.resolvedLink("Trip.assets/photo.png", from: "/n/Inbox") == "/n/Inbox/Trip.assets/photo.png"
               && NoteShelf.resolvedLink("./a/./b.png", from: "/n/Inbox") == "/n/Inbox/a/b.png", "a handwritten link: beside the note")
        expect(NoteShelf.resolvedLink("../../../../x.png", from: "/n/Inbox") == nil && NoteShelf.resolvedLink("/abs.png", from: "/n/Inbox") == nil,
               "above /, or absolute: none")
        // A pasted picture's line kept as it is only when it already points into this note's own folder (words alone).
        let ownN1 = NoteShelf.pictureFolder(id: "N1")
        expect(NoteShelf.ownPicture("../\(ownN1)/p.png", noteFolder: "/n/Work", noteID: "N1") == "p.png", "its own picture: kept, from any notebook")
        expect(NoteShelf.ownPicture("../\(NoteShelf.pictureFolder(id: "N2"))/p.png", noteFolder: "/n/Work", noteID: "N1") == nil
               && NoteShelf.ownPicture("Trip.assets/p.png", noteFolder: "/n/Work", noteID: "N1") == nil
               && NoteShelf.ownPicture("../\(ownN1)/sub/p.png", noteFolder: "/n/Work", noteID: "N1") == nil
               && NoteShelf.ownPicture("../\(ownN1)/p.png", noteFolder: "/n/Work", noteID: "") == nil,
               "another note's, a handwritten one, deeper, or no note: taken from its bytes")
        // The same note's own picture line is kept only from the same notes root (however spelled).
        expect(NoteShelf.keepsOwnPicture("../\(ownN1)/p.png", noteFolder: "/n/Work", noteID: "N1", fragmentNote: "N1", fragmentRoot: "/n") == "p.png"
               && NoteShelf.keepsOwnPicture("../\(ownN1)/p.png", noteFolder: "/private/var/n/Work", noteID: "N1", fragmentNote: "N1", fragmentRoot: "/var/n") == "p.png",
               "this note, this root: kept")
        expect(NoteShelf.keepsOwnPicture("../\(ownN1)/p.png", noteFolder: "/n/Work", noteID: "N1", fragmentNote: "N1", fragmentRoot: "/other") == nil
               && NoteShelf.keepsOwnPicture("../\(ownN1)/p.png", noteFolder: "/n/Work", noteID: "N1", fragmentNote: "N2", fragmentRoot: "/n") == nil,
               "another root or another note: never kept")
        // A copied fragment stays within its bound: pictures that don't fit (or have no bytes) become lines saying so.
        let blocksToCopy: [NoteBlock] = [.text("a"), .image(path: "p1.png", caption: ""), .image(path: "p2.png", caption: "")]
        let fitting = NoteShelf.fragmentBody(blocksToCopy, bytes: [1: Data(count: 40)], limit: 100)
        expect(fitting?.markdown == "a\n![](p1.png)\n(A picture couldn't be copied.)" && fitting?.pictures.count == 1,
               "a picture not loaded yet: copied as words; the rest with their bytes", fitting?.markdown ?? "nil")
        expect(NoteShelf.fragmentBody(blocksToCopy, bytes: [1: Data(count: 40), 2: Data(count: 40)], limit: 100) == nil, "past the bound: the whole copy refused")
        // "Here" for the note tools: placed now, by the window in front or on a Desktop showing.
        expect(!NoteShelf.isHere(NoteShelf.placementNow(window: 7, desktops: [], showing: [], windowValid: false))
               && NoteShelf.placementNow(window: 7, desktops: [3], showing: [3], windowValid: false) == .desktop,
               "a window placement awaiting a fresh read isn't here (a Desktop showing still is)")
        // A tab's runtime identity carried on a reload only to the same, unchanged anchor that matches once.
        func tabStick(_ address: String, _ element: Int? = nil) -> NoteStick {
            var stick = NoteStick(kind: .tab)
            stick.url = address
            stick.tabElement = element
            return stick
        }
        let firstTab = tabStick("https://a.example/one", 5), secondTab = tabStick("https://b.example/two", 9)
        let afterRemoval = NoteShelf.carryTabElements(from: [firstTab, secondTab], to: [tabStick("https://b.example/two")])
        expect(afterRemoval.map(\.tabElement) == [9], "an earlier anchor removed: the remaining tab keeps its own identity, never the removed one's",
               "\(afterRemoval.map(\.tabElement))")
        let reordered = NoteShelf.carryTabElements(from: [firstTab, secondTab], to: [tabStick("https://b.example/two"), tabStick("https://a.example/one")])
        expect(reordered.map(\.tabElement) == [9, 5], "reordered: each keeps its own")
        expect(NoteShelf.carryTabElements(from: [firstTab], to: [tabStick("https://a.example/changed")]).map(\.tabElement) == [nil], "changed: dropped")
        expect(NoteShelf.carryTabElements(from: [tabStick("https://a.example/one", 5), tabStick("https://a.example/one", 6)],
                                          to: [tabStick("https://a.example/one")]).map(\.tabElement) == [nil], "two alike before: uncertain, dropped")
        expect(NoteShelf.carryTabElements(from: [firstTab], to: [tabStick("https://a.example/one"), tabStick("https://a.example/one")]).map(\.tabElement) == [nil, nil],
               "two alike now: uncertain, dropped")
        expect(NoteShelf.onEnable() == (true, true), "notes turned on: what's in front read, and the Desktops read and placed")
        // A failed read: gone (no file, or not a picture) or unreadable for now (there, but couldn't be read).
        expect(NoteShelf.readOutcome(exists: true, read: true, picture: true) == .image && NoteShelf.readOutcome(exists: false, read: false, picture: false) == .gone
               && NoteShelf.readOutcome(exists: true, read: true, picture: false) == .gone && NoteShelf.readOutcome(exists: true, read: false, picture: false) == .transient,
               "gone, not a picture, or unreadable for now")
        // Remove: only the attachment when words share its line; the whole line when it's alone.
        expect(NoteShelf.removalRange(attachment: NSRange(location: 4, length: 1), line: NSRange(location: 4, length: 7), lineText: "\u{FFFC}words\n") == NSRange(location: 4, length: 1)
               && NoteShelf.removalRange(attachment: NSRange(location: 4, length: 1), line: NSRange(location: 4, length: 2), lineText: "\u{FFFC}\n") == NSRange(location: 4, length: 2),
               "words beside it stay; alone, its line goes")
        // The Desktop fallback: a note also stuck to the Desktop showing goes there while its window placement awaits a
        // fresh read, and back to its window once the read is in.
        expect(NoteShelf.onDesktop(window: 7, desktops: [3], screenDesktop: 3, windowValid: false)
               && !NoteShelf.onDesktop(window: 7, desktops: [3], screenDesktop: 3, windowValid: true)
               && !NoteShelf.onDesktop(window: nil, desktops: [2], screenDesktop: 3, windowValid: false)
               && NoteShelf.onDesktop(window: nil, desktops: [3], screenDesktop: 3, windowValid: true), "on the Desktop by the validated placement only")
        expect(NoteShelf.shownPixels(width: 360, scale: 2) == 720 && NoteShelf.shownPixels(width: 360, scale: 0) == 360, "decoded at the shown width × scale")
        expect(NoteShelf.isHere(NoteShelf.placementNow(window: nil, desktops: [3], showing: [3])) && NoteShelf.isHere(NoteShelf.placementNow(window: 7, desktops: [], showing: []))
               && !NoteShelf.isHere(NoteShelf.placementNow(window: nil, desktops: [3], showing: [2])), "a Desktop note on the Desktop showing is here; one elsewhere isn't")
        expect(NoteShelf.imageCost(width: 1000, height: 500) == 2_000_000, "an image's cost: its pixels, four bytes each")
        expect(NoteShelf.keepBytes("a", pending: ["a"], shown: []) && NoteShelf.keepBytes("a", pending: [], shown: ["a"]) && !NoteShelf.keepBytes("a", pending: [], shown: []),
               "bytes kept while a write is pending or an editor shows them")
        // A paste's range: the selection when it still holds what was selected; else no replacing, at that place.
        expect(NoteShelf.pasteRange(at: 5, length: 7, selected: "REPLACE", text: "keep REPLACE end") == NSRange(location: 5, length: 7), "still there: replaced")
        expect(NoteShelf.pasteRange(at: 5, length: 7, selected: "REPLACE", text: "keep OTHERED end") == NSRange(location: 5, length: 0)
               && NoteShelf.pasteRange(at: 50, length: 7, selected: "REPLACE", text: "short") == NSRange(location: 5, length: 0)
               && NoteShelf.pasteRange(at: 3, length: 0, selected: "", text: "short") == NSRange(location: 3, length: 0),
               "changed or gone: nothing replaced, at the place (within the text)")
        // Escape on the paper with the keyboard: the keyboard goes back to the person's app, never to Petal.
        expect(NoteShelf.keyboardBack(paperWasKey: true, frontmost: 400, petal: 100, lastOther: 300) == 400, "the app in front under the paper")
        expect(NoteShelf.keyboardBack(paperWasKey: true, frontmost: 100, petal: 100, lastOther: 300) == 300, "Petal in front: the last app used")
        expect(NoteShelf.keyboardBack(paperWasKey: false, frontmost: 400, petal: 100, lastOther: 300) == nil
               && NoteShelf.keyboardBack(paperWasKey: true, frontmost: 100, petal: 100, lastOther: nil) == nil, "a paper without the keyboard, or no app: nothing")

        // A missing picture is asked for again every 10 s, only while it's on screen.
        let t0 = Date()
        expect(NoteShelf.pictureRetry(broken: ["/n/P/a": t0], onScreen: ["/n/P/a"], now: t0.addingTimeInterval(10)) == (["/n/P/a"], true),
               "on screen, 10 s since: asked again")
        expect(NoteShelf.pictureRetry(broken: ["/n/P/a": t0], onScreen: ["/n/P/a"], now: t0.addingTimeInterval(4)) == ([], true), "on screen, too soon: waits")
        expect(NoteShelf.pictureRetry(broken: ["/n/P/a": t0], onScreen: ["/n/P/b"], now: t0.addingTimeInterval(60)) == ([], false), "not on screen: no timer")
        expect(NoteShelf.pictureRetry(broken: [:], onScreen: ["/n/P/a"], now: t0) == ([], false), "nothing missing: no timer")
        // What's on screen: pictures of papers revealed and open only; a hidden (clear) or folded paper shows none.
        let pictured = "# A\n![](../Pictures/h/p.png)"
        expect(NoteShelf.picturesOnScreen([(true, true, "/n/Inbox", pictured)]) == ["/n/Pictures/h/p.png"], "revealed and open: its pictures")
        expect(NoteShelf.picturesOnScreen([(false, true, "/n/Inbox", pictured)]).isEmpty, "a hidden paper (gone clear): none")
        expect(NoteShelf.picturesOnScreen([(true, false, "/n/Inbox", pictured)]).isEmpty, "a folded paper: none")
        expect(NoteShelf.picturesOnScreen([(true, true, "/n/Inbox", "![](../../out.png)")]).isEmpty, "a link leading out: nothing to retry")
        // The folder watcher's paths touch the pictures they hold, however they're spelled.
        expect(NoteShelf.picturesTouched(events: ["/private/var/n/Pictures/h/p.png"], keys: ["/var/n/Pictures/h/p.png", "/var/n/Pictures/h/q.png"]) == ["/var/n/Pictures/h/p.png"],
               "the file itself, in /private spelling")
        expect(NoteShelf.picturesTouched(events: ["/var/n/Pictures/h"], keys: ["/var/n/Pictures/h/p.png", "/var/n/Pictures/hh/p.png"]) == ["/var/n/Pictures/h/p.png"],
               "a folder: what's in it, never a folder that only starts alike")
        // A note re-stuck from a passage to elsewhere lets go of its line, pin and found state.
        expect(NoteShelf.passageGeometry(["a": CGRect(x: 1, y: 2, width: 3, height: 4), "b": .zero], passages: ["b"]) == ["b": .zero]
               && NoteShelf.passageGeometry(["a": false], passages: []).isEmpty, "only notes on a passage now keep a pin")

        // Where a picture link may be read or written: inside the notes' root, by the words alone.
        expect(NoteShelf.pictureTarget("../Pictures/abc/p.png", noteFolder: "/n/Inbox") == "/n/Pictures/abc/p.png"
               && NoteShelf.pictureTarget("Trip.assets/p.png", noteFolder: "/n/Inbox") == "/n/Inbox/Trip.assets/p.png"
               && NoteShelf.pictureTarget("../Work/x.png", noteFolder: "/n/Inbox") == "/n/Work/x.png", "inside the notes: allowed")
        expect(NoteShelf.pictureTarget("../Pictures/../../private.png", noteFolder: "/n/Inbox") == nil
               && NoteShelf.pictureTarget("../../etc/passwd", noteFolder: "/n/Inbox") == nil
               && NoteShelf.pictureTarget("..", noteFolder: "/n/Inbox") == nil, "out by .., however it's spelled: never")
        expect(NoteShelf.pictureTarget("/etc/hosts", noteFolder: "/n/Inbox") == nil && NoteShelf.pictureTarget("~/x.png", noteFolder: "/n/Inbox") == nil
               && NoteShelf.pictureTarget("https://example.com/x.png", noteFolder: "/n/Inbox") == nil && NoteShelf.pictureTarget("", noteFolder: "/n/Inbox") == nil,
               "absolute, home, an address or nothing: never")
        expect(NoteShelf.pictureTarget("../x.png", noteFolder: "/u/r1/Note", root: "/u/r1") == "/u/r1/x.png"
               && NoteShelf.pictureTarget("../../x.png", noteFolder: "/u/r1/Note", root: "/u/r1") == nil, "a rescue's own folder as its root")
        expect(NoteShelf.folderName("Pictures") == "Pictures notes" && NoteShelf.folderName("pictures") == "pictures notes" && NoteShelf.folderName("Trips") == "Trips",
               "a notebook is never called Pictures")

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

        // MARK: Papers beside a window, never over one another

        let foldedSize = CGSize(width: 170, height: 170), openSize = CGSize(width: 360, height: 420)
        func apart(_ placed: [NoteRoom.Placed]) -> Bool {
            for (i, a) in placed.enumerated() { for b in placed.dropFirst(i + 1) where a.frame.intersects(b.frame) { return false } }
            return true
        }
        func onScreen(_ placed: [NoteRoom.Placed]) -> Bool { placed.allSatisfy { visible.contains($0.frame) } }
        func frame(_ placed: [NoteRoom.Placed], _ id: String) -> CGRect { placed.first { $0.id == id }?.frame ?? .null }
        // Two notes with no line: their tabs stacked from the top (52 and 92 down the window).
        let two = NoteRoom.stack(window: roomy, visible: visible, papers: [
            NoteRoom.Paper(id: "a", size: foldedSize, top: 52), NoteRoom.Paper(id: "b", size: foldedSize, top: 92)])
        expect(apart(two) && onScreen(two), "two papers at the stacked tabs' heights never cover one another", "\(two)")
        expect(frame(two, "a").minY == roomy.minY + 52 && frame(two, "b").minY == frame(two, "a").maxY + NoteRoom.spacing,
               "the first at its line, the second right under it", "\(two)")
        expect(two.allSatisfy { $0.frame.minX == roomy.maxX + NoteRoom.gap }, "both beside the window")
        // One the person moved into the default place: it stays, the other goes around it.
        let spotted = CGRect(x: roomy.maxX + NoteRoom.gap + 20, y: roomy.minY + 60, width: 170, height: 170)
        let movedOne = NoteRoom.stack(window: roomy, visible: visible, papers: [
            NoteRoom.Paper(id: "a", size: foldedSize, top: 52, moved: spotted), NoteRoom.Paper(id: "b", size: foldedSize, top: 52)])
        expect(frame(movedOne, "a") == spotted, "a moved paper stays where it was left")
        expect(apart(movedOne), "a paper placed by default never lands on a moved one", "\(movedOne)")
        // A new paper takes free room: those already there don't move.
        let earlier = NoteRoom.stack(window: roomy, visible: visible, papers: [
            NoteRoom.Paper(id: "a", size: foldedSize, top: 52), NoteRoom.Paper(id: "b", size: foldedSize, top: 300)])
        func was(_ placed: [NoteRoom.Placed], _ id: String) -> NoteRoom.Was? {
            placed.first { $0.id == id }.map { NoteRoom.Was(top: $0.frame.minY - roomy.minY, column: $0.column) }
        }
        let added = NoteRoom.stack(window: roomy, visible: visible, papers: [
            NoteRoom.Paper(id: "a", size: foldedSize, top: 52, was: was(earlier, "a")), NoteRoom.Paper(id: "b", size: foldedSize, top: 300, was: was(earlier, "b")),
            NoteRoom.Paper(id: "new", size: openSize, top: 52)])
        expect(frame(added, "a") == frame(earlier, "a") && frame(added, "b") == frame(earlier, "b"), "a new paper moves nobody", "\(added)")
        expect(apart(added) && onScreen(added), "and covers nobody", "\(added)")
        // One that grows pushes the ones below it down, and they come back when it folds.
        let grown = NoteRoom.stack(window: roomy, visible: visible, papers: [
            NoteRoom.Paper(id: "a", size: openSize, top: 52, was: was(two, "a"), held: true), NoteRoom.Paper(id: "b", size: foldedSize, top: 92, was: was(two, "b"))])
        expect(frame(grown, "a").minY == frame(two, "a").minY, "the paper written in stays where it was")
        expect(apart(grown) && frame(grown, "b").minY > frame(two, "b").minY, "the one below it moves down", "\(grown)")
        let foldedBack = NoteRoom.stack(window: roomy, visible: visible, papers: [
            NoteRoom.Paper(id: "a", size: foldedSize, top: 52, was: was(grown, "a")), NoteRoom.Paper(id: "b", size: foldedSize, top: 92, was: was(grown, "b"))])
        expect(foldedBack == two, "folded again, it comes back up", "\(foldedBack)")
        // A paper held still keeps its place even when one above it grows: the one above goes around it.
        let still = NoteRoom.stack(window: roomy, visible: visible, papers: [
            NoteRoom.Paper(id: "a", size: openSize, top: 52, was: was(two, "a")), NoteRoom.Paper(id: "b", size: foldedSize, top: 92, was: was(two, "b"), held: true)])
        expect(frame(still, "b") == frame(two, "b") && apart(still), "a paper being written in never jumps", "\(still)")
        // More than fit below: a second column, never a pile.
        let many = (0..<9).map { NoteRoom.Paper(id: "p\($0)", size: foldedSize, top: 52 + CGFloat($0) * 40) }
        let crowdedBeside = NoteRoom.stack(window: roomy, visible: visible, papers: many)
        expect(crowdedBeside.count == 9 && apart(crowdedBeside) && onScreen(crowdedBeside), "more papers than fit: none covers another", "\(crowdedBeside)")
        expect(Set(crowdedBeside.map(\.column)).count >= 2, "they go on in another column")
        // A window with no room beside it: the first column on the screen's edge, the next to its left.
        let full = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let packed = NoteRoom.stack(window: full, visible: visible, papers: (0..<7).map { NoteRoom.Paper(id: "q\($0)", size: foldedSize, top: 52) })
        expect(apart(packed) && onScreen(packed), "no room beside the window: still none covers another", "\(packed)")
        expect(packed.first { $0.column == 0 }?.frame.maxX == visible.maxX - NoteRoom.gap, "the first column on the screen's edge")
        expect(packed.contains { $0.column == 1 && $0.frame.maxX <= visible.maxX - NoteRoom.gap - 170 }, "the next to its left")
        // A paper whose line is low on the screen is kept on it, not sent to another column.
        let lowOne = NoteRoom.stack(window: roomy, visible: visible, papers: [NoteRoom.Paper(id: "a", size: openSize, top: 690)])
        expect(lowOne.first.map { $0.column == 0 && visible.contains($0.frame) } == true, "a low paper moves up onto the screen", "\(lowOne)")

        // A Chromium tab after its browser restarted: found by address, decided over every note it could be.
        var oldTab = NoteStick(kind: .tab)
        oldTab.mac = "mac-1"; oldTab.pid = 50; oldTab.tabID = "t1"; oldTab.shared = 1; oldTab.url = "https://a.example/page"
        var otherOld = oldTab
        otherOld.tabID = "t7"
        let reopened = NoteScene(mac: "mac-1", app: "", pid: 90, window: 2, tab: NoteTab(id: "n4", shared: 1, url: "https://a.example/page", title: "Page"))
        expect(NoteMatch.tabMatch(oldTab, reopened) == .address && NoteMatch.tabMatch(oldTab, NoteScene(mac: "mac-1", pid: 50, tab: NoteTab(id: "t1", url: "x", title: ""))) == .identity,
               "how a tab's note fits")
        expect(NoteMatch.recover([oldTab]) && NoteMatch.recover([oldTab, oldTab]), "notes from one old tab take it")
        expect(!NoteMatch.recover([oldTab, otherOld]), "notes from two old tabs on one page: no guess")
        let adopted = NoteMatch.adopt(oldTab, reopened)
        expect(adopted.tabID == "n4" && adopted.pid == 90 && NoteMatch.tabMatch(adopted, reopened) == .identity, "recovered, it's that tab's from now on")
        expect(NoteMatch.best([oldTab, app], reopened, excluding: [0]) == 1 || NoteMatch.best([oldTab, app], reopened, excluding: [0]) == nil,
               "left out, it falls back to its other places")
        // Safari's only tab (no tab strip) can't be told apart: never offered as a tab.
        expect(!NoteTab(url: "https://a.example", title: "").known, "a tab with no id or button isn't known")

        // Windows found by title after their app restarted: decided over every candidate together.
        var newTab1 = NoteStick(kind: .window)
        newTab1.app = "com.example.browser"; newTab1.title = "New Tab"; newTab1.mac = "mac-1"; newTab1.pid = 10; newTab1.window = 1
        var newTab2 = newTab1
        newTab2.window = 2
        let restoredWindow = NoteScene(mac: "mac-1", app: "com.example.browser", pid: 99, window: 7, title: "New Tab", titleTwins: 1)
        expect(NoteMatch.windowMatch(newTab1, restoredWindow) == .address, "by title alone")
        expect(NoteMatch.recoverWindows([newTab1]) && NoteMatch.recoverWindows([newTab1, newTab1]), "notes from one old window take it")
        expect(!NoteMatch.recoverWindows([newTab1, newTab2]), "two old windows titled alike (\"New Tab\"): no guess")
        let adoptedWindow = NoteMatch.adoptWindow(newTab1, restoredWindow)
        expect(NoteMatch.windowMatch(adoptedWindow, restoredWindow) == .identity, "recovered, it's that window's from now on")

        // Anchors decided over every note before any picks: a note whose best place is elsewhere still counts.
        var tabA = NoteStick(kind: .tab)
        tabA.mac = "mac-1"; tabA.pid = 50; tabA.tabID = "t1"; tabA.shared = 1; tabA.url = "https://a.example/page"
        var tabB = tabA
        tabB.tabID = "t7"
        var appB = NoteStick(kind: .app)
        appB.app = "com.google.Chrome"
        let samePage = NoteScene(mac: "mac-1", app: "com.google.Chrome", pid: 90, window: 2, tab: NoteTab(id: "n4", shared: 1, url: "https://a.example/page", title: ""))
        let decided = NoteMatch.anchors([[tabA, appB], [appB, tabB]], samePage)
        expect(decided.adopt.isEmpty && decided.excluded.count == 2, "two old tabs' anchors on one page: both left out, whichever place each note picks")
        let single = NoteMatch.anchors([[tabA], [appB]], samePage)
        expect(single.adopt.count == 1 && single.adopt[0].note == 0 && single.excluded.isEmpty, "one old tab's: taken")

        // A private app's place and scene: nothing of their words.
        var secret = NoteStick(kind: .passage)
        secret.app = "com.example.vault"; secret.quote = "q"; secret.url = "https://bank.example"; secret.path = "/x"; secret.title = "t"
        let scrubbed = secret.scrubbed
        expect(scrubbed.quote.isEmpty && scrubbed.url.isEmpty && scrubbed.path.isEmpty && scrubbed.title.isEmpty && scrubbed.app == secret.app, "a private place, scrubbed")
        let privateScene = NoteScene(mac: "m", app: "x", pid: 1, window: 2, title: "Statement", titleTwins: 1,
                                     tab: NoteTab(id: "1", url: "https://bank.example", title: "Bank"), file: "/Users/x/a.pdf", fileBookmark: "b").privately
        expect(privateScene.title.isEmpty && privateScene.tab == nil && privateScene.file.isEmpty && privateScene.fileBookmark.isEmpty
               && privateScene.window == 2 && privateScene.titleTwins == nil, "a private app's scene: its window, nothing else")

        // Giving a window its width back: the record stays until it's surely done.
        let wasFrame = CGRect(x: 0, y: 0, width: 1000, height: 700), gave = CGRect(x: 0, y: 0, width: 600, height: 700)
        expect(NoteRoom.giveBackPlan(found: false, now: nil, before: wasFrame, given: gave) == (false, true), "the window's gone: forgotten")
        expect(NoteRoom.giveBackPlan(found: true, now: nil, before: wasFrame, given: gave) == (false, false), "couldn't be read: kept for the next try")
        expect(NoteRoom.giveBackPlan(found: true, now: gave, before: wasFrame, given: gave) == (true, false), "as Petal left it: put back (forgotten once it's back)")
        expect(NoteRoom.giveBackPlan(found: true, now: CGRect(x: 50, y: 50, width: 800, height: 500), before: wasFrame, given: gave) == (false, true),
               "changed by the person: theirs, forgotten")

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

        // MARK: A note on the screen itself

        // The file keeps it as written: its kind and the Mac it's on, and whatever a later Petal adds to it.
        let onScreen = NoteShelf.screenAnchor(mac: "mac-1")!
        expect(onScreen.kind == .screen && onScreen.mac == "mac-1", "the screen's anchor names this Mac")
        expect(NoteShelf.screenAnchor(mac: "") == nil, "this Mac's id unknown: nothing is stuck")
        var later = onScreen
        later.extra = [(key: "display", lines: ["    display: \"left\""])]
        var sticky = NoteFile(id: "SC1", created: when, modified: when, body: "Call back before noon")
        var itsWindow = NoteStick(kind: .window)
        itsWindow.app = "com.apple.TextEdit"; itsWindow.mac = "mac-1"; itsWindow.pid = 42; itsWindow.window = 7
        sticky.places = [itsWindow, later]
        let stickyText = sticky.serialized()
        let stickyBack = NoteFile.parse(stickyText, fallbackID: "X", fallbackDate: Date())
        expect(stickyText.contains("  - kind: screen\n    mac: mac-1\n    display: \"left\""), "the screen place as written", stickyText)
        expect(stickyBack == sticky && stickyBack.serialized() == stickyText, "a note on the screen reads back as it was written, and writes the same again")
        expect(stickyBack.places[1].kind == .screen && stickyBack.places[1].extra.first?.key == "display", "with a later Petal's key kept")

        // It ranks last, and never fits a window: a note also stuck to the window in front shows there.
        expect(NoteStick.Kind.allCases.allSatisfy { $0 == .screen || $0.rank < NoteStick.Kind.screen.rank }, "the screen is the last place tried")
        let textEdit = NoteScene(mac: "mac-1", app: "com.apple.TextEdit", pid: 42, window: 7, title: "Draft")
        expect(!NoteMatch.fits(onScreen, textEdit), "the screen is never a window's place")
        expect(NoteMatch.best([onScreen, itsWindow], textEdit) == 1, "also on the window in front: that place wins")
        expect(NoteMatch.best([onScreen], textEdit) == nil, "only on the screen: no place on a window")

        // Per Mac: this Mac's screen only; on another Mac it's kept and shows nowhere.
        expect(NoteShelf.onScreen([itsWindow, onScreen], mac: "mac-1"), "kept on this Mac's screen")
        expect(!NoteShelf.onScreen([itsWindow, onScreen], mac: "mac-2"), "another Mac's screen place means nothing here")
        expect(!NoteShelf.onScreen([itsWindow], mac: "mac-1") && !NoteShelf.onScreen([onScreen], mac: ""), "not on the screen; this Mac unknown: no")
        expect(onScreen.samePlace(NoteShelf.screenAnchor(mac: "mac-1")!) && !onScreen.samePlace(NoteShelf.screenAnchor(mac: "mac-2")!),
               "the same place only on the same Mac")

        // One placement: the window in front first, then the screen (on every Desktop), then its Desktop.
        expect(NoteShelf.placementNow(window: nil, desktops: [], showing: [], screen: true) == .screen, "nothing in front fits: on the screen, whichever Desktop shows")
        expect(NoteShelf.placementNow(window: nil, desktops: [2], showing: [2], screen: true) == .screen, "also on the Desktop showing: still the screen's")
        expect(NoteShelf.placementNow(window: 0, desktops: [], showing: [], screen: true) == .window(0), "its window in front: by the window")
        expect(NoteShelf.placementNow(window: 0, desktops: [], showing: [], windowValid: false, screen: true) == .screen,
               "its window's read awaited: on the screen meanwhile")
        expect(NoteShelf.placementNow(window: nil, desktops: [], showing: [], standalone: true, screen: true) == .standalone, "opened on its own: there")
        expect(NoteShelf.placementNow(window: nil, desktops: [2], showing: [2]) == .desktop, "not on the screen: its Desktop, as before")
        expect(!NoteShelf.onDesktop(window: nil, desktops: [2], screenDesktop: 2, windowValid: true, screen: true)
               && NoteShelf.onDesktop(window: nil, desktops: [2], screenDesktop: 2, windowValid: true), "a note kept on the screen is never placed twice, as a Desktop's too")
        // Shown through the one rule: hidden while Mission Control is open, there through a wait for a window's read.
        expect(!NoteShelf.mayShow(.screen, missionControl: true, awaitingRead: false), "Mission Control open: the screen's notes hidden too")
        expect(NoteShelf.mayShow(.screen, missionControl: false, awaitingRead: true) && NoteShelf.mayShow(.screen, missionControl: false, awaitingRead: false),
               "a read awaited: a note on the screen stays")
        expect(NoteShelf.isHere(.screen), "on the screen is here, for the note tools")
        expect(NoteShelf.restsOffWindow(.screen) && NoteShelf.restsOffWindow(.desktop) && NoteShelf.restsOffWindow(.standalone)
               && !NoteShelf.restsOffWindow(.window(0)) && !NoteShelf.restsOffWindow(.none), "which papers a focus change leaves where they are")
        // It never asks for room beside a window.
        expect(!NoteRoom.wanted([(placement: .screen, open: true, moved: false)]), "a note on the screen never narrows a window")
        expect(!NoteRoom.wanted([(placement: .window(0), open: true, moved: true)]) && NoteRoom.wanted([(placement: .window(0), open: true, moved: false)]),
               "nor does one the person left somewhere on its window; one still beside it does")

        // "Keep it on screen": added to its places, taken off again, never left stuck nowhere.
        expect(NoteShelf.screenToggled([itsWindow], mac: "mac-1") == [itsWindow, onScreen], "kept on screen: its window's place stays")
        expect(NoteShelf.screenToggled([itsWindow, onScreen], mac: "mac-1") == [itsWindow], "chosen again: taken off")
        expect(NoteShelf.screenToggled([onScreen], mac: "mac-1") == nil, "the screen its only place: it stays")
        expect(NoteShelf.screenToggled([itsWindow], mac: "") == nil, "this Mac unknown: nothing changes")
        let otherMac = NoteShelf.screenAnchor(mac: "mac-2")!
        expect(NoteShelf.screenToggled([otherMac], mac: "mac-1") == [otherMac, onScreen], "another Mac's screen place is kept beside this one's")

        // What it says: "On screen" in the letterhead, the back and to the tools; "also on the screen" after another place.
        expect(onScreen.label() == "On screen" && onScreen.words == "On screen" && onScreen.alsoLabel == "the screen", "its words")
        expect(itsWindow.alsoLabel == itsWindow.label(), "every other place says the same after \"also on\"")

        // With no spot of its own it rests down the main screen's right side, never two in one place.
        let visibleScreen = CGRect(x: 0, y: 0, width: 1440, height: 870)
        let rests = (0..<12).map { NoteShelf.screenRest(index: $0, visible: visibleScreen, paper: 170) }
        expect(Set(rests.map { "\($0.x),\($0.y)" }).count == 12, "each rests in its own place")
        expect(rests[0] == CGPoint(x: 1440 - 40 - 170, y: 870 - 40) && rests[1].x == rests[0].x && rests[1].y < rests[0].y, "from the top right, down")
        expect(rests[4].x < rests[0].x && rests[4].y == rests[0].y, "a column as tall as the screen has room for (four here), then the next one left")
        expect(rests.allSatisfy { visibleScreen.contains(CGRect(x: $0.x, y: $0.y - 170, width: 170, height: 170)) }, "all of them whole on the screen")

        // MARK: Paper colors (the sketch's color-mix)

        let blue = NoteInk.hex("#007aff")!
        expect(NoteInk.hex(NoteInk.mix(blue, 1, NoteInk.paper)) == "#007aff" && NoteInk.hex(NoteInk.mix(blue, 0, NoteInk.paper)) == "#fffef9", "mixing ends")
        let paper = NoteInk.paper(blue)
        expect(paper.b > paper.r && paper.r > 0.85, "blue paper is a pale blue", NoteInk.hex(paper))

        print("notes: \(passed) passed" + (failures > 0 ? ", \(failures) failed" : ""))
        if failures > 0 { exit(1) }
    }
}
