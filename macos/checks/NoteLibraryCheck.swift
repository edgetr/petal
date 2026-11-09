import CoreGraphics
import Foundation

// Checks NoteLibrary.swift: the shared contract's fields read from a note's front matter (and written back as they
// were), the Petal Notes window's views and search, the grid with its cover, a cover's two parts, the line under a
// note, Private notebooks, notes on people (one person or none, never a guess), the canvas's edits and its based
// write, a notebook's fan, and what dropping a note on an app does. No file, no window. Run with macos/checks/run.sh.
@main
struct NoteLibraryCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static func main() {
        let now = NoteFile.date("2026-11-09T10:00:00Z")!

        // MARK: The contract's fields

        let text = """
            ---
            id: W1
            created: 2026-11-01T09:00:00Z
            modified: 2026-11-08T09:00:00Z
            back: 2026-11-14T09:00:00Z
            watch: { every: 1d, line: "under 90, or less", last: "96", history: ["98", "99"], mac: m1, paused: false }
            helper:
              state: working
              who: Petal
              step: Reading the page
            task:
              - kind: tab
                title: One
              - kind: file
                title: Two
            from: petal
            later: kept as written
            ---
            # A watched price
            """
        let file = NoteFile.parse(text, fallbackID: "x", fallbackDate: now)
        expect(NoteContract.back(file) == NoteFile.date("2026-11-14T09:00:00Z"), "back: read")
        let watch = NoteContract.watch(file)
        expect(watch?.every == "1d" && watch?.line == "under 90, or less" && watch?.last == "96" && watch?.history == ["98", "99"] && watch?.paused == false,
               "watch: a one-line map, commas inside quotes kept", "\(String(describing: watch))")
        let helper = NoteContract.helper(file)
        expect(helper?.state == .working && helper?.who == "Petal" && helper?.step == "Reading the page", "helper: fields on lines of their own")
        expect(NoteContract.tasks(file) == 2, "task: its items counted", "\(NoteContract.tasks(file))")
        expect(NoteContract.fromPetal(file), "from: petal")
        expect(file.serialized() == text.replacingOccurrences(of: "\r\n", with: "\n"), "every one written back exactly as it was")
        var blockWatch = NoteFile(id: "W2", body: "")
        blockWatch.extra = [(key: "watch", lines: ["watch:", "  every: 6h", "  last: 12", "  history:", "    - 13", "    - 14", "  paused: true"])]
        let block = NoteContract.watch(blockWatch)
        expect(block?.every == "6h" && block?.history == ["13", "14"] && block?.paused == true, "watch: written as a block with a list", "\(String(describing: block))")
        var cover = NoteFile(id: "C1", body: "# About this notebook")
        cover.cover = true
        expect(!NoteContract.isPrivate(cover) && NoteContract.view(cover) == .grid, "a cover is neither private nor a canvas until it says so")
        cover.setScalar("private", "true")
        cover.setScalar("view", "canvas")
        cover.setScalar("morning", "weekdays at 8")
        let reread = NoteFile.parse(cover.serialized(), fallbackID: "", fallbackDate: now)
        expect(NoteContract.isPrivate(reread) && NoteContract.view(reread) == .canvas && reread.scalarValue("morning") == "weekdays at 8",
               "private, view and Phase 2's morning on a cover, read back")
        cover.setScalar("private", nil)
        expect(!NoteContract.isPrivate(cover) && cover.frontMatter("private") == nil && cover.scalarValue("view") == "canvas", "private taken off, the rest kept")

        // MARK: The window's views

        func item(_ book: String, _ body: String, modified: TimeInterval, extra: [(String, [String])] = [], isCover: Bool = false) -> NoteLibrary.Item {
            var f = NoteFile(id: UUID().uuidString, created: now, modified: now.addingTimeInterval(modified), body: body)
            f.extra = extra.map { (key: $0.0, lines: $0.1) }
            f.cover = isCover
            return NoteLibrary.Item(notebook: book, file: f)
        }
        let items = [
            item("Garden", "# About", modified: -10, isCover: true),
            item("Garden", "old", modified: -500),
            item("garden", "new", modified: -5),
            item("Work", "comes back later", modified: -50, extra: [("back", ["back: 2026-11-20T09:00:00Z"])]),
            item("Work", "comes back sooner", modified: -40, extra: [("back", ["back: 2026-11-10T09:00:00Z"])]),
            item("Work", "came back already", modified: -30, extra: [("back", ["back: 2026-11-01T09:00:00Z"])]),
            item("Work", "watched", modified: -20, extra: [("watch", ["watch: { every: 1d, last: \"3\" }"])]),
            item("Work", "helped", modified: -10, extra: [("helper", ["helper: { state: waiting, who: Petal }"])]),
            item("Work", "helped, done", modified: -9, extra: [("helper", ["helper: { state: done }"])]),
        ]
        expect(NoteLibrary.listed(.notebook("Garden"), items, now: now) == [2, 1], "a notebook: its notes (any case), the cover left out, newest first")
        expect(NoteLibrary.listed(.comingBack, items, now: now) == [4, 3], "coming back: from now on, soonest first")
        expect(NoteLibrary.listed(.watching, items, now: now) == [6], "watching")
        expect(NoteLibrary.listed(.helpers, items, now: now) == [7], "helpers at work: not the ones done")
        expect(NoteLibrary.search("SOONER", items) == [4] && NoteLibrary.search("garden", items).count == 3 && NoteLibrary.search("  ", items).isEmpty,
               "search: words and notebook, any case; nothing for nothing")

        // The grid: the cover first, two rows tall.
        let slots = NoteLibrary.gridSlots(count: 6, columns: 5, cover: true)
        expect(slots.map(\.column) == [1, 2, 3, 4, 1, 2] && slots.map(\.row) == [0, 0, 0, 0, 1, 1], "the grid leaves the cover's two cells", "\(slots)")
        expect(NoteLibrary.gridSlots(count: 3, columns: 5, cover: false).map(\.column) == [0, 1, 2], "no cover: from the first cell")
        expect(NoteLibrary.gridRows(count: 1, columns: 5, cover: true) == 2 && NoteLibrary.gridRows(count: 9, columns: 5, cover: true) == 3, "rows")
        let narrow = NoteLibrary.gridSlots(count: 3, columns: 1, cover: true)
        expect(narrow.map(\.column) == [1, 1, 0] && narrow.map(\.row) == [0, 1, 2], "too narrow: beside the cover, then under it", "\(narrow)")
        expect(NoteLibrary.columns(width: 800, cell: 150, gap: 14) == 4, "columns that fit")

        let parts = NoteLibrary.cover("# About this notebook\nThe beds and the balcony.\n## Petal remembers\n- The south bed gets sun\n- Seeds in the blue box\n")
        expect(parts.about == "The beds and the balcony." && parts.remembers == ["The south bed gets sun", "Seeds in the blue box"], "a cover's two parts", "\(parts)")

        let footerBack = NoteLibrary.footer(items[4].file, place: "example.com", now: now)
        expect(footerBack.dot && footerBack.text.hasPrefix("Back "), "the line under a note: what's coming first", footerBack.text)
        expect(NoteLibrary.footer(items[1].file, place: "example.com", now: now).text == "example.com", "else where it's stuck")
        expect(NoteLibrary.footer(items[1].file, place: nil, now: now).text == "Not stuck anywhere", "else that it's on no place")
        expect(NoteLibrary.footer(items[7].file, place: nil, now: now).text == "Petal needs you", "a helper waiting for the person")
        expect(NoteLibrary.whereWords(root: "/Users/a/Library/Mobile Documents/com~apple~CloudDocs/Petal Notes", notebook: "Garden", home: "/Users/a")
               == "iCloud Drive › Petal Notes › Garden", "where the files live, in words")

        // MARK: Private notebooks

        let books: Set<String> = ["Health"]
        expect(NotePrivacy.readable(notebook: "Garden", privateBooks: books, asker: nil), "any other notebook: readable")
        expect(!NotePrivacy.readable(notebook: "Health", privateBooks: books, asker: nil), "a Private one: not from no note")
        expect(!NotePrivacy.readable(notebook: "health", privateBooks: books, asker: "Garden"), "nor from another notebook's note (any case)")
        expect(NotePrivacy.readable(notebook: "Health", privateBooks: books, asker: "HEALTH"), "only from inside it")

        // MARK: Notes on people

        expect(PersonRead.person(app: "com.tinyspeck.slackmacgap", appName: "Slack", title: "Alex Kim (DM) - Acme - Slack", headings: ["general"]) == "Alex Kim",
               "Slack: the person in a DM's title")
        expect(PersonRead.person(app: "com.tinyspeck.slackmacgap", appName: "Slack", title: "#general (Channel) - Acme - Slack", headings: ["Alex"]) == nil,
               "a channel is no person (its headings aren't read)")
        expect(PersonRead.person(app: "com.tinyspeck.slackmacgap", appName: "Slack", title: "Alex, Sam (DM) - Acme - Slack", headings: []) == nil,
               "a group of several is no one person")
        expect(PersonRead.person(app: "net.whatsapp.WhatsApp", appName: "WhatsApp", title: "WhatsApp", headings: ["Chats", "Alex (3)"]) == "Alex",
               "WhatsApp: the header, an unread count off, the app's own words left out")
        expect(PersonRead.person(app: "com.apple.MobileSMS", appName: "Messages", title: "Alex", headings: ["Sam"]) == nil,
               "two people that disagree: never a guess")
        expect(PersonRead.person(app: "com.apple.MobileSMS", appName: "Messages", title: "Álex", headings: ["alex"]) == "Álex",
               "the same person spelled two ways is one")
        expect(PersonRead.person(app: "com.apple.Safari", appName: "Safari", title: "Alex", headings: []) == nil, "only chat apps")
        expect(PersonRead.person(app: "com.apple.mail", appName: "Mail", title: "Inbox – 12 messages", headings: ["Alex Kim"]) == "Alex Kim",
               "Mail: the message's header, never the mailbox's title")
        expect(PersonRead.contact("alex kim", contacts: [("c1", "Alex Kim"), ("c2", "Sam")]) == "c1", "a vault contact by name")
        expect(PersonRead.contact("Alex", contacts: [("c1", "Alex"), ("c2", "alex")]) == nil, "two contacts of one name: neither")
        var personPlace = NoteStick(kind: .person)
        personPlace.title = "Alex Kim"
        personPlace.contact = "c1"
        var personNote = NoteFile(id: "P1", body: "Size M")
        personNote.places = [personPlace]
        let personBack = NoteFile.parse(personNote.serialized(), fallbackID: "", fallbackDate: now)
        expect(personBack.places == [personPlace], "a person's place round-trips, with its contact's id")
        var chat = NoteScene(app: "net.whatsapp.WhatsApp", pid: 3, window: 9)
        chat.person = "alex kim"
        chat.personContact = "c1"
        var windowPlace = NoteStick(kind: .window)
        windowPlace.app = "net.whatsapp.WhatsApp"
        windowPlace.pid = 3
        windowPlace.window = 9
        expect(NoteMatch.best([windowPlace, personPlace], chat) == 1, "beside their conversation: the person before the window")
        expect(NoteMatch.best([personPlace], chat.privately) == nil, "an app kept private: no person")
        chat.person = ""
        chat.personContact = ""
        expect(NoteMatch.best([personPlace], chat) == nil, "no one person in front: no note")

        // The person-identifier rule: a name alone never sticks a note to a person, nor finds one.
        let twoAlexes: [(id: String, name: String)] = [("c1", "Alex"), ("c2", "alex")]
        expect(PersonRead.identity(name: "Alex", handle: "", contacts: twoAlexes) == nil, "two contacts of one name and no address: no person place")
        expect(PersonRead.identity(name: "Alex", handle: "", contacts: []) == nil, "a name alone: no person place (the window instead)")
        let byHandle = PersonRead.identity(name: "Alex", handle: "alex@example.com", contacts: twoAlexes)
        expect(byHandle?.contact == "" && byHandle?.handle == "alex@example.com", "two contacts of one name: the chat's address tells them apart")
        let byContact = PersonRead.identity(name: "Sam", handle: "", contacts: [("c3", "Sam")])
        expect(byContact?.contact == "c3", "exactly one contact of that name: their contact")
        var nameOnly = NoteStick(kind: .person)
        nameOnly.title = "Alex"
        var anotherAlex = NoteScene(app: "com.apple.MobileSMS", pid: 4, window: 2)
        anotherAlex.person = "Alex"
        expect(!PersonRead.matches(nameOnly, anotherAlex), "a place with only a name matches no one")
        var alexByMail = nameOnly
        alexByMail.handle = "alex@example.com"
        anotherAlex.personHandle = "other.alex@example.com"
        expect(!PersonRead.matches(alexByMail, anotherAlex), "the same name with another address is another person")
        anotherAlex.personHandle = "alex@example.com"
        expect(PersonRead.matches(alexByMail, anotherAlex), "the same address is the same person, in any chat app")
        expect(!PersonRead.samePerson(nameOnly, nameOnly) && PersonRead.samePerson(alexByMail, alexByMail), "one person by contact or address, never by name")
        expect(PersonRead.handle(title: "Alex Kim", headings: ["Alex Kim <ALEX@example.com>"]) == "alex@example.com", "an address in the header")
        expect(PersonRead.handle(title: "", headings: ["+90 555 123 45 67"]) == "+905551234567", "a phone number in the header")
        expect(PersonRead.handle(title: "a@example.com", headings: ["b@example.com"]) == nil, "two addresses: none")
        var withHandle = NoteFile(id: "P2", body: "x")
        withHandle.places = [alexByMail]
        expect(NoteFile.parse(withHandle.serialized(), fallbackID: "", fallbackDate: now).places == [alexByMail], "a person's address round-trips")

        // MARK: Canvas

        var canvas = NoteCanvas()
        canvas = canvas.applying(.move("n1", .init(x: 10, y: 20)))
        canvas = canvas.applying(.area(.init(id: "a", label: "Beds", x: 0, y: 0, w: 400, h: 300)))
        canvas = canvas.applying(.arrow(.init(id: "r", from: "n1", to: "n2")))
        canvas = canvas.applying(.arrow(.init(id: "self", from: "n1", to: "n1")))
        canvas = canvas.applying(.words(.init(id: "w", text: "first →", x: 5, y: 5)))
        canvas = canvas.applying(.zoom(9))
        func at(_ spot: NoteCanvas.Spot?, _ x: Double, _ y: Double) -> Bool { spot?.x == x && spot?.y == y }
        expect(at(canvas.notes["n1"], 10, 20) && canvas.areas.count == 1 && canvas.arrows.map(\.id) == ["r"] && canvas.texts.count == 1 && canvas.zoom == 2,
               "edits: a move, an area, an arrow (never to itself), words, a zoom kept in range")
        expect(NoteCanvas.decode(canvas.encoded()) == canvas, "the file round-trips")
        expect(NoteCanvas.decode(nil) == NoteCanvas() && NoteCanvas.decode("not json") == nil, "no file is an empty canvas; one Petal can't read is nil")
        expect(NoteCanvas.write(.move("n2", .init(x: 1, y: 1)), disk: "not json") == nil, "never written over a file Petal can't read")
        // Based: the edit is made on the file as it is, so another Mac's move meanwhile stays.
        let elsewhere = NoteCanvas().applying(.move("n9", .init(x: 300, y: 300))).encoded()
        let merged = NoteCanvas.decode(NoteCanvas.write(.move("n1", .init(x: 50, y: 50)), disk: elsewhere))
        expect(at(merged?.notes["n9"], 300, 300) && at(merged?.notes["n1"], 50, 50), "a based write keeps what changed elsewhere")
        expect(NoteCanvas.write([], disk: elsewhere) == elsewhere, "nothing to change writes the same")
        expect(at(NoteCanvas.decode(#"{"notes":{"x":{"x":1,"y":2}},"later":true}"#)?.notes["x"], 1, 2), "a later Petal's keys don't stop a read")
        let later = #"{"areas":[{"id":"a","label":"Beds","x":0,"y":0,"w":10,"h":10,"tint":"green"}],"later":{"k":1},"notes":{"x":{"x":1,"y":2,"pinned":true}}}"#
        let kept = NoteCanvas.write(.move("y", .init(x: 5, y: 5)), disk: later).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        expect((kept?["later"] as? [String: Int])?["k"] == 1 && ((kept?["areas"] as? [[String: Any]])?.first?["tint"] as? String) == "green"
               && ((kept?["notes"] as? [String: [String: Any]])?["x"]?["pinned"] as? Bool) == true && (kept?["notes"] as? [String: Any])?["y"] != nil,
               "a write keeps what this Petal doesn't know, on the file and on its items")
        expect(NoteCanvas.decode(#"{"areas":[{"id":"a"}]}"#) == nil && NoteCanvas.write(.move("y", .init(x: 1, y: 1)), disk: #"{"areas":[{"id":"a"}]}"#) == nil,
               "an area Petal can't read: the file isn't taken for empty, and isn't written")
        let placed = canvas.spots(for: ["n1", "n3", "n4"], columns: 2)
        expect(at(placed["n1"], 10, 20), "a note keeps its spot")
        expect((placed["n3"]?.y ?? 0) >= 300 + NoteCanvas.gap && placed["n3"]?.y == placed["n4"]?.y && placed["n3"] != placed["n4"],
               "new ones go below everything, side by side", "\(placed)")
        expect(canvas.inside(canvas.areas[0], spots: ["n1": .init(x: 10, y: 20), "far": .init(x: 900, y: 900)]) == ["n1"], "the notes in an area")
        // Merging iCloud's versions: two versions with independent edits, one element edited on both, a removal.
        let base = NoteCanvas()
            .applying(.area(.init(id: "beds", label: "Beds", x: 0, y: 0, w: 100, h: 100)), at: 10)
            .applying(.words(.init(id: "w1", text: "hello", x: 1, y: 1)), at: 10)
            .applying(.arrow(.init(id: "r1", from: "n1", to: "n2")), at: 10)
        let macA = base.applying(.move("n1", .init(x: 5, y: 5)), at: 20)
            .applying(.area(.init(id: "beds", label: "Beds A", x: 0, y: 0, w: 100, h: 100)), at: 30)
            .applying(.removeWords("w1"), at: 25)
        let macB = base.applying(.move("n2", .init(x: 9, y: 9)), at: 21)
            .applying(.area(.init(id: "beds", label: "Beds B", x: 0, y: 0, w: 100, h: 100)), at: 40)
            .applying(.removeArrow("r1"), at: 22)
        let both = NoteCanvas.merge(macA, macB)
        expect(at(both.notes["n1"], 5, 5) && at(both.notes["n2"], 9, 9), "independent edits on two versions: both kept")
        expect(both.areas.count == 1 && both.areas[0].label == "Beds B", "the same area edited on both: the newer wins")
        expect(both.texts.isEmpty && both.arrows.isEmpty && both.removed["words:w1"] == 25 && both.removed["arrow:r1"] == 22,
               "a removal on either side stays removed, its tombstone kept")
        expect(NoteCanvas.merge(macB, macA) == NoteCanvas.merge(macA, macB) || NoteCanvas.merge(macB, macA).areas == both.areas,
               "the merge comes out the same whichever version is first")
        let revived = NoteCanvas.merge(macA, base.applying(.words(.init(id: "w1", text: "hello again", x: 1, y: 1)), at: 50))
        expect(revived.texts.first?.text == "hello again", "an element changed after its removal comes back")
        let fromFile = NoteCanvas.decode(NoteCanvas.write([NoteCanvas.Stamped(.zoom(1.5), at: 60)], disk: macA.encoded(), versions: [macB.encoded(), "not json"]))
        expect(fromFile?.areas.first?.label == "Beds B" && at(fromFile?.notes["n2"], 9, 9) && fromFile?.zoom == 1.5 && fromFile?.texts.isEmpty == true,
               "a write merges the file with iCloud's versions (one it can't read left out), then makes its edit")

        // A save that failed keeps its edits, in order, until a write takes them.
        let waiting = [NoteCanvas.Stamped(.zoom(1), at: 1), NoteCanvas.Stamped(.zoom(2), at: 2), NoteCanvas.Stamped(.zoom(1.5), at: 3)]
        expect(CanvasQueue.after(waiting, wrote: 2, ok: false) == waiting, "a failed write keeps every edit")
        expect(CanvasQueue.after(waiting, wrote: 2, ok: true) == [waiting[2]], "a write that landed leaves the ones added meanwhile")
        expect(CanvasQueue.retry(after: 1) == 2 && CanvasQueue.retry(after: 3) == 8 && CanvasQueue.retry(after: 20) == 60, "tried again sooner, then less often")
        expect(NoteCanvas().applying(waiting).zoom == 1.5 && NoteCanvas().applying(waiting).zoomAt == 3, "edits kept with their own times")

        expect(NoteCanvas.zoomIn(1) == 1.25 && NoteCanvas.zoomOut(1) == 0.8 && NoteCanvas.zoomIn(2) == 2 && NoteCanvas.zoomOut(0.5) == 0.5, "zoom steps")

        // MARK: Room, the keyboard and delivery

        expect(NoteRoom.wanted([(.window(0), true, false)]), "a note open on the window by its placement wants room")
        expect(!NoteRoom.wanted([(.standalone, true, false), (.desktop, true, false), (.window(0), false, false), (.window(1), true, true)]),
               "never one opened on its own, on a Desktop, folded or moved off by the person")
        expect(NoteShelf.standaloneKeyboard(escape: true, fromLibrary: true, libraryOpen: true), "Escape: back to the Petal Notes window it came from")
        expect(!NoteShelf.standaloneKeyboard(escape: false, fromLibrary: true, libraryOpen: true), "a click elsewhere: the keyboard stays there")
        expect(!NoteShelf.standaloneKeyboard(escape: true, fromLibrary: false, libraryOpen: true), "opened from the dock: not to the window")
        expect(NotePrivacy.deliverable(notebooks: ["Garden"], privateBooks: ["Health"], asker: nil), "an answer about public notebooks is given")
        expect(!NotePrivacy.deliverable(notebooks: ["Garden", "health"], privateBooks: ["Health"], asker: nil),
               "one turned Private before it's handed over: not given")
        expect(NotePrivacy.deliverable(notebooks: ["Health"], privateBooks: ["Health"], asker: "Health"), "still from inside it: given")

        // MARK: The dock

        let fan = NoteFan.spots(count: 20)
        expect(fan.count == NoteFan.limit && fan[0].x == 0 && fan[0].y == 0 && zip(fan, fan.dropFirst()).allSatisfy { $0.y < $1.y && $0.x <= $1.x },
               "the fan: at most eight, rising and leaning one way")
        expect(NoteDrop.action("com.apple.mail") == .mail && NoteDrop.action("com.apple.iCal") == .calendar && NoteDrop.action("com.apple.Notes") == .clipboard,
               "dropped on Mail, Calendar, anything else")
        expect(NoteDrop.plain("# Title\n- [ ] one\n- [x] two\n![a picture](../Pictures/x/p.png)\n- item\nhttps://example.com") == "Title\n☐ one\n☑ two\n• item\nhttps://example.com",
               "a note's words for another app, its pictures left out", NoteDrop.plain("# Title\n- [ ] one\n- [x] two\n![a picture](../Pictures/x/p.png)\n- item\nhttps://example.com"))
        let tomorrow = NoteDrop.event(title: "Dentist", found: [], now: now)
        expect(tomorrow.guessed && tomorrow.end.timeIntervalSince(tomorrow.start) == 3600 && tomorrow.start > now, "no time named: tomorrow at 9, said so")
        let named = NoteDrop.event(title: "", found: [(now.addingTimeInterval(-86400), 0, false), (now.addingTimeInterval(3600), 1800, false)], now: now)
        expect(!named.guessed && named.start == now.addingTimeInterval(3600) && named.end == now.addingTimeInterval(5400) && named.title == "From a note",
               "the first time from now on, its length")
        expect(!NoteDrop.dates(in: "Lunch on 12 December 2027 at 13:00").isEmpty, "dates found in a note's words")

        print("note library: \(passed) passed" + (failures > 0 ? ", \(failures) failed" : ""))
        if failures > 0 { exit(1) }
    }
}
