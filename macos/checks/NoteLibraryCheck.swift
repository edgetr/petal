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
        // A task's parts and Open all.
        var task = NoteFile(id: "T1", body: "")
        task.extra = [(key: "task", lines: [#"task: [ { kind: tab, title: "Quote A", url_or_path: "https://insure.example/a" }, { kind: file, title: Quote, url_or_path: "/Users/someone/Quote B.pdf" }, { kind: mail, title: Agent, url_or_path: "<abc@mail.example>" }, { kind: window, title: Notes } ]"#])]
        let taskParts = NoteContract.taskItems(task)
        expect(taskParts.map(\.kind) == ["tab", "file", "mail", "window"] && taskParts[1].target == "/Users/someone/Quote B.pdf", "task items on one line", "\(taskParts)")
        expect(taskParts.map(NoteTasks.chip) == ["insure.example", "Quote B.pdf", "Mail · Agent", "Notes"], "its chips", "\(taskParts.map(NoteTasks.chip))")
        let opens = NoteTasks.openable(taskParts)
        expect(opens.map(\.absoluteString) == ["https://insure.example/a", "file:///Users/someone/Quote%20B.pdf", "message://%3Cabc@mail.example%3E"],
               "Open all: the tab, the file and the mail by its message address; a window has nothing to open", "\(opens)")
        let blockTask = NoteContract.taskItems(file)
        expect(blockTask.map(\.title) == ["One", "Two"], "task items as a list on lines of their own")
        let unsafe = [NoteContract.TaskItem(kind: "tab", title: "", target: "file:///etc/passwd"), NoteContract.TaskItem(kind: "tab", title: "", target: "javascript:alert(1)"),
                      NoteContract.TaskItem(kind: "file", title: "", target: "relative/path"), NoteContract.TaskItem(kind: "mail", title: "", target: "https://evil.example")]
        expect(NoteTasks.openable(unsafe).isEmpty, "a tab only at a web address, a file only at a full path, a mail only by its message address")

        // Open all's file rule, on real files in a throwaway folder: only documents open, as they really are.
        let fm = FileManager.default
        let things = fm.temporaryDirectory.appending(path: "petal-openall-\(UUID().uuidString)")
        try? fm.createDirectory(at: things.appending(path: "Thing.app/Contents/MacOS"), withIntermediateDirectories: true)
        try? Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>Thing</string></dict></plist>".utf8)
            .write(to: things.appending(path: "Thing.app/Contents/Info.plist"))
        try? Data("#!/bin/sh\necho hi\n".utf8).write(to: things.appending(path: "Run me.command"))
        try? fm.createSymbolicLink(at: things.appending(path: "Report.pdf"), withDestinationURL: things.appending(path: "Thing.app"))
        try? Data(#"<?xml version="1.0"?><plist version="1.0"><dict><key>URL</key><string>https://example.com</string></dict></plist>"#.utf8)
            .write(to: things.appending(path: "Link.webloc"))
        try? Data("%PDF-1.4\n%%EOF\n".utf8).write(to: things.appending(path: "Real.pdf"))
        try? Data("plain words".utf8).write(to: things.appending(path: "Words.txt"))
        func action(_ name: String) -> NoteTasks.FileAction { NoteTasks.decide(things.appending(path: name)).1 }
        expect(action("Thing.app") == .reveal, "an app: shown in Finder, never opened")
        expect(action("Run me.command") == .reveal, "a .command: shown, never run")
        expect(action("Report.pdf") == .reveal && NoteTasks.decide(things.appending(path: "Report.pdf")).0.lastPathComponent == "Thing.app",
               "a link named like a PDF to an app: resolved first, and shown, never opened")
        expect(action("Link.webloc") == .reveal, "a .webloc shortcut: shown, never followed")
        expect(action("Real.pdf") == .open && action("Words.txt") == .open, "a PDF and a text file: opened")
        expect(action("Missing.pdf") == .reveal, "a file that isn't there: nothing opened")
        try? fm.removeItem(at: things)
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
        // A vault contact only by the address the chat shows, never by a name, however unique.
        let book: [(id: String, addresses: [String])] = [("c1", ["Alex.Kim@Example.com", "+90 555 111 22 33"]), ("c2", ["sam@example.com"]), ("c3", ["shared@example.com"]), ("c4", ["shared@example.com"])]
        expect(PersonRead.contact(handle: "alex.kim@example.com", contacts: book) == "c1" && PersonRead.contact(handle: "+905551112233", contacts: book) == "c1",
               "a contact by the chat's address (email in any case, phone by its digits)")
        expect(PersonRead.contact(handle: "", contacts: book) == nil && PersonRead.contact(handle: "shared@example.com", contacts: book) == nil,
               "no address, or one two contacts share: no contact")
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
        expect(PersonRead.identity(name: "Sam", handle: "", contacts: book) == nil, "a name alone, even one unique in the vault: no person place (the window instead)")
        let byHandle = PersonRead.identity(name: "Alex", handle: "Alex.Kim@example.com", contacts: book)
        expect(byHandle?.contact == "c1" && byHandle?.handle == "alex.kim@example.com", "the chat's address: the place, and its contact when one has it")
        let unknownAddress = PersonRead.identity(name: "Alex", handle: "other.alex@example.com", contacts: book)
        expect(unknownAddress?.contact == "" && unknownAddress?.handle == "other.alex@example.com", "an address no contact has: the place by address alone")
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
        // Merging versions keeps what this Petal doesn't know from each, at the top and on each item; a version whose
        // unknown keys can't all be kept isn't whole (left unresolved).
        let fileV = #"{"notes":{"n1":{"x":1,"y":1,"at":1,"pin":"a"}},"future":1}"#
        let versionV = #"{"notes":{"n1":{"x":5,"y":5,"at":9,"glow":true},"n2":{"x":2,"y":2,"at":3,"tag":"v"}},"later":{"k":2}}"#
        let clashV = #"{"notes":{"n1":{"x":1,"y":1,"at":1,"pin":"b"}},"future":1}"#
        let keptAll = NoteCanvas.merge([], disk: fileV, versions: [versionV, clashV, "not json"])
        let keptObject = keptAll.flatMap { try? JSONSerialization.jsonObject(with: Data($0.text.utf8)) as? [String: Any] }
        let n1 = (keptObject?["notes"] as? [String: [String: Any]])?["n1"], n2 = (keptObject?["notes"] as? [String: [String: Any]])?["n2"]
        expect(keptObject?["future"] as? Int == 1 && (keptObject?["later"] as? [String: Int])?["k"] == 2, "top-level keys from the file and each version kept")
        expect(n1?["pin"] as? String == "a" && n1?["glow"] as? Bool == true && n1?["x"] as? Double == 5 && n2?["tag"] as? String == "v",
               "each item keeps every version's unknown keys, the newer known ones winning", "\(String(describing: n1))")
        expect(keptAll?.whole == [true, false, false], "a version with a clashing unknown key, or unreadable, isn't whole", "\(String(describing: keptAll?.whole))")

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
        expect(CanvasQueue.after(waiting, wrote: [waiting[0].id, waiting[1].id], ok: false) == waiting, "a failed write keeps every edit")
        expect(CanvasQueue.after(waiting, wrote: [waiting[0].id, waiting[1].id], ok: true) == [waiting[2]], "a write that landed leaves the ones added meanwhile")
        expect(CanvasQueue.after([waiting[2]], wrote: [waiting[0].id, waiting[1].id], ok: true) == [waiting[2]],
               "a write acknowledges only the edits it wrote, by id, whatever else is waiting now")
        expect(!CanvasQueue.current(started: 1, now: 2) && CanvasQueue.current(started: 2, now: 2), "a completion from before a drain touches nothing")
        let decoded = try? JSONDecoder().decode(NoteCanvas.Stamped.self, from: JSONEncoder().encode(waiting[0]))
        expect(decoded?.id == waiting[0].id, "an edit's id is kept in the journal")
        expect(CanvasQueue.retry(after: 1) == 2 && CanvasQueue.retry(after: 3) == 8 && CanvasQueue.retry(after: 20) == 60, "tried again sooner, then less often")
        expect(NoteCanvas().applying(waiting).zoom == 1.5 && NoteCanvas().applying(waiting).zoomAt == 3, "edits kept with their own times")
        let newerThere = NoteCanvas().applying(.move("n1", .init(x: 9, y: 9)), at: 100).applying(.removeArea("gone"), at: 100)
        let retried = newerThere.applyingMerged([NoteCanvas.Stamped(.move("n1", .init(x: 1, y: 1)), at: 50),
                                                 NoteCanvas.Stamped(.area(.init(id: "gone", label: "Old", x: 0, y: 0, w: 1, h: 1)), at: 60),
                                                 NoteCanvas.Stamped(.move("n2", .init(x: 2, y: 2)), at: 70)])
        expect(at(retried.notes["n1"], 9, 9) && retried.areas.isEmpty && at(retried.notes["n2"], 2, 2) && retried.zoom == newerThere.zoom,
               "a waiting edit goes through the merge: older than what's there, it doesn't win (nor bring back what was removed later)")
        expect(CanvasQueue.notebook(coverID: "c", covers: [("c", "Trip"), ("c", "Trip"), ("d", "Work")]) == "Trip"
               && CanvasQueue.notebook(coverID: "c", covers: [("c", "Trip"), ("c", "Work")]) == nil && CanvasQueue.notebook(coverID: "x", covers: []) == nil,
               "an entry's notebook by its cover id; gone or in two notebooks: none (rescued)")

        expect(NoteCanvas.zoomIn(1) == 1.25 && NoteCanvas.zoomOut(1) == 0.8 && NoteCanvas.zoomIn(2) == 2 && NoteCanvas.zoomOut(0.5) == 0.5, "zoom steps")

        // MARK: Room, the keyboard and delivery

        expect(NoteRoom.wanted([(.window(0), true, false)]), "a note open on the window by its placement wants room")
        expect(!NoteRoom.wanted([(.standalone, true, false), (.desktop, true, false), (.window(0), false, false), (.window(1), true, true)]),
               "never one opened on its own, on a Desktop, folded or moved off by the person")
        expect(NoteShelf.standaloneKeyboard(escape: true, fromLibrary: true, libraryOpen: true) == .library, "Escape: back to the Petal Notes window it came from")
        expect(NoteShelf.standaloneKeyboard(escape: false, fromLibrary: true, libraryOpen: true) == .stay, "a click elsewhere: the keyboard stays there")
        expect(NoteShelf.standaloneKeyboard(escape: true, fromLibrary: false, libraryOpen: true) == .app, "opened from the dock: back to the app, not the window")
        expect(NotePrivacy.deliverable(notebooks: ["Garden"], privateBooks: ["Health"], asker: nil), "an answer about public notebooks is given")
        expect(!NotePrivacy.deliverable(notebooks: ["Garden", "health"], privateBooks: ["Health"], asker: nil),
               "one turned Private before it's handed over: not given")
        expect(NotePrivacy.deliverable(notebooks: ["Health"], privateBooks: ["Health"], asker: "Health"), "still from inside it: given")
        // A note read in Garden and moved into Health before the answer is handed over: checked where it is now.
        let movedNow = NotePrivacy.currentNotebooks(of: ["N1"], notes: [("N1", "Health"), ("N2", "Garden")])
        expect(movedNow == ["Health"] && !NotePrivacy.deliverable(notebooks: Set(["Garden"]).union(movedNow), privateBooks: ["Health"], asker: nil),
               "a note moved into a Private notebook mid-read: not given")
        expect(NoteShelf.standaloneGroup("b", group: ["a", "b", "c"]) == ["b", "a", "c"] && NoteShelf.standaloneGroup("x", group: []) == ["x"],
               "a note in a conflict opens with every other paper of it beside it")
        // The group fits the visible screen: from near its right edge, three papers wrap and move in.
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 900)
        let paper = CGSize(width: 360, height: 380)
        let laid = NoteShelf.groupLayout(count: 3, corner: CGPoint(x: 900, y: 850), paper: paper, visible: visible)
        expect(laid.allSatisfy { $0.x >= visible.minX && $0.x + paper.width <= visible.maxX && $0.y <= visible.maxY && $0.y - paper.height >= visible.minY },
               "every paper of the group on the screen", "\(laid)")
        expect(Set(laid.map { "\($0.x),\($0.y)" }).count == 3 && laid[0].y == laid[1].y && laid[2].y < laid[0].y,
               "side by side, the third wrapping to a row below, none overlapping", "\(laid)")
        expect(!NoteDrop.allowed(versions: 2) && NoteDrop.allowed(versions: 1), "a note with two versions isn't dropped on an app until one is kept")
        // Privacy across the cover's versions; a cover is its file whatever its front matter.
        var publicCover = NoteFile(id: "C", body: "")
        publicCover.cover = true
        var privateVersion = publicCover
        privateVersion.setScalar("private", "true")
        expect(NoteLibrary.privateNotebook(covers: [publicCover, privateVersion], unread: false), "Private when any version of the cover says so")
        expect(NoteLibrary.privateNotebook(covers: [], unread: true) && !NoteLibrary.privateNotebook(covers: [publicCover], unread: false),
               "unknown counts as Private; one public cover is public")
        expect(NoteLibrary.isCover(fileName: NoteShelf.coverName, file: NoteFile(id: "file:x", body: "hand written")), "a cover version without front matter is the cover")
        // Only cover-named files are covers: another note's `cover: true` counts for nothing, and is kept as written.
        expect(NoteLibrary.isCoverName("About this notebook (conflicted copy).md") && NoteLibrary.isCoverName("about this notebook 2.md")
               && !NoteLibrary.isCoverName("Trip.md") && !NoteLibrary.isCoverName("About this notebook.txt"), "the cover, its conflict copies; nothing else")
        var stray = NoteFile.parse("---\nid: S1\ncover: true\nprivate: true\n---\nnot a cover", fallbackID: "", fallbackDate: Date())
        NoteLibrary.coverFlag(&stray, fileName: "Trip.md")
        expect(!stray.cover && stray.serialized().contains("cover: true"), "a stray cover: true isn't a cover, and stays in its file")
        var coverNamed = NoteFile(id: "C9", body: "")
        NoteLibrary.coverFlag(&coverNamed, fileName: NoteShelf.coverName)
        expect(coverNamed.cover, "the cover file is the cover, front matter or not")
        // Cover changes recovered: each field's newest value, whichever copy it came from.
        var older = CoverFields(notebook: "G", root: "/r", coverID: "c")
        older.set("private", "true", at: 100)
        older.set("color", "#111111", at: 300)
        var newer = CoverFields(notebook: "G", root: "/r", coverID: "c")
        newer.set("private", "", at: 200)
        newer.set("view", "canvas", at: 50)
        let mergedFields = older.merged(with: newer)
        expect(mergedFields.fields == ["private": "", "color": "#111111", "view": "canvas"], "newest per field across copies", "\(mergedFields.fields)")
        expect(newer.merged(with: older).fields == mergedFields.fields, "whichever copy comes first")
        let roundTrip = try? JSONDecoder().decode(CoverFields.self, from: JSONEncoder().encode(mergedFields))
        expect(roundTrip?.times["private"] == 200, "each field's time is journaled with it")
        // An area moved with its notes: every note by its own id; one that can't get one, and the move is refused.
        expect(CanvasQueue.groupMove(["a", "file:n.md"], resolved: ["file:n.md": "N1"]) == ["a": "a", "file:n.md": "N1"], "an id-less note moves by the id it was given")
        expect(CanvasQueue.groupMove(["a", "file:n.md"], resolved: [:]) == nil && CanvasQueue.groupMove(["file:n.md"], resolved: ["file:n.md": "file:n.md"]) == nil,
               "one without an id: the whole group's move is refused")
        expect(CanvasQueue.groupMove(["P1"], resolved: [:], pending: ["P1"]) == nil && CanvasQueue.groupMove(["P1"], resolved: ["P1": "P1"], pending: []) == ["P1": "P1"],
               "an id still being written is waited for, and used once it lands")
        // Gestures keep their own time through any wait: the later gesture wins, whichever lands first.
        let firstGesture = NoteCanvas.Stamped(.move("n1", .init(x: 1, y: 1)), at: 10)
        let laterGesture = NoteCanvas.Stamped(.move("n1", .init(x: 2, y: 2)), at: 20)
        let landedLateFirst = NoteCanvas().applyingMerged([laterGesture, firstGesture])
        expect(landedLateFirst.notes["n1"]?.x == 2, "a gesture that waited for an id lands after a later one: the later one still wins")
        // A cover id in two notebook folders (a notebook duplicated in Finder): the later folder by name gets a new id,
        // the same on every Mac.
        // Privacy by a notebook's actual folder: a Private folder renamed "Health." is that folder, never cleaned up.
        expect(!NotePrivacy.readable(notebook: "Health.", privateBooks: ["Health."], asker: nil)
               && !NotePrivacy.destinationReadable("Health.", existing: ["Health.", "Garden"], privateBooks: ["Health."], asker: nil)
               && !NotePrivacy.destinationReadable("health.", existing: ["Health.", "Garden"], privateBooks: ["Health."], asker: nil),
               "a renamed Private folder stays Private, and a move into it is refused")
        expect(!NotePrivacy.destinationReadable("Secret.", existing: ["Secret"], privateBooks: ["Secret"], asker: nil)
               && NotePrivacy.destinationReadable("Garden", existing: ["Health.", "Garden"], privateBooks: ["Health."], asker: nil),
               "a destination cleaned into a Private notebook is refused; another is fine")
        expect(NoteShelf.standaloneKeyboard(escape: true, fromLibrary: false, libraryOpen: true) == .app
               && NoteShelf.standaloneKeyboard(escape: true, fromLibrary: true, libraryOpen: true) == .library
               && NoteShelf.standaloneKeyboard(escape: true, fromLibrary: true, libraryOpen: false) == .app
               && NoteShelf.standaloneKeyboard(escape: false, fromLibrary: false, libraryOpen: true) == .stay,
               "Escape on a note opened from the dock gives the keyboard back to the app; a click elsewhere leaves it there")
        expect(NoteShelf.alreadyLanded(disk: "same", text: "same") && !NoteShelf.alreadyLanded(disk: "other", text: "same"),
               "a file already saying a write's text: landed")
        expect(NoteShelf.reconcileID(pending: "NEW", diskID: "NEW") == .landed && NoteShelf.reconcileID(pending: "NEW", diskID: "OLD") == .dropped("OLD")
               && NoteShelf.reconcileID(pending: "NEW", diskID: nil) == .wait, "a pending id reconciled with its file")
        let dupes = NoteLibrary.duplicateCovers([("SAME", "Trip"), ("SAME", "Trip copy"), ("ONLY", "Work")])
        expect(dupes.keys.sorted() == ["Trip copy"] && dupes["Trip copy"] == NoteLibrary.renewedID("SAME", folder: "Trip copy"),
               "only the later folder's cover is renewed", "\(dupes)")
        let renewed = NoteLibrary.renewedID("SAME", folder: "Trip copy")
        expect(renewed == NoteLibrary.renewedID("SAME", folder: "Trip copy") && renewed != NoteLibrary.renewedID("SAME", folder: "Trip copy 2")
               && UUID(uuidString: renewed) != nil && renewed != "SAME", "the new id: a UUID made from the old id and the folder, the same on both Macs")
        expect(NoteLibrary.isCanonicalCover("about this notebook.md") && NoteLibrary.isCanonicalCover("About This Notebook.MD") && !NoteLibrary.isCanonicalCover("About this notebook (recovered).md"),
               "the cover's name matched as the file system does, case-insensitive")
        expect(NoteDrop.waitForPictures(saving: false, importing: 1) && NoteDrop.waitForPictures(saving: true, importing: 0) && !NoteDrop.waitForPictures(saving: false, importing: 0),
               "Mail waits for pictures being saved and pictures still being read in")
        expect(CanvasQueue.ambiguous(key: "SAME", covers: [("SAME", "Trip"), ("SAME", "Trip copy")]) && !CanvasQueue.ambiguous(key: "SAME", covers: [("SAME", "Trip")]),
               "a cover id two notebooks share: canvas edits wait, never rescued as gone")

        // Cover conflicts are per notebook folder, by file name, never by id.
        let coverPapers: [(id: String, path: String)] = [("SAME", "/n/A/About this notebook.md"), ("SAME", "/n/B/About this notebook.md"),
                                                         ("OTHER", "/n/A/About this notebook (recovered).md"), ("N1", "/n/A/Trip.md"), ("N1", "/n/B/Trip (conflicted copy).md")]
        let grouped = NoteShelf.conflictGroups(coverPapers.map { (NoteShelf.conflictKey(id: $0.id, path: $0.path), $0.path) })
        expect(grouped.contains([0, 2]) && !grouped.contains { $0.contains(0) && $0.contains(1) } && grouped.contains([3, 4]),
               "a notebook's cover files group by folder (a recovered one with another id too); two notebooks' covers never; other notes by id", "\(grouped)")
        expect(NoteShelf.keepTarget(chosen: "/n/A/About this notebook (recovered).md", group: ["/n/B/About this notebook.md", "/n/A/About this notebook (recovered).md"])
               == "/n/A/About this notebook (recovered).md", "Keep never promotes into another notebook's cover")
        expect(NoteShelf.copyStem(original: NoteShelf.coverName, title: "Health") == "About this notebook" && NoteShelf.copyStem(original: "Trip.md", title: "Trip") == "Trip",
               "a cover's copy is named for the cover; others from their title")
        var strayCover = NoteFile(id: "S", body: "")
        strayCover.cover = true
        strayCover.setScalar("private", "true")
        expect(NoteLibrary.strayPrivateCover(fileName: "Health.md", file: strayCover) && !NoteLibrary.strayPrivateCover(fileName: NoteShelf.coverName, file: strayCover),
               "a private cover-flagged note without a cover's name is a warning sign")
        expect(NoteLibrary.coverUnknown(fileThere: true, fileRead: true, versionsUnread: true)
               && NoteLibrary.privateNotebook(covers: [publicCover], unread: NoteLibrary.coverUnknown(fileThere: true, fileRead: true, versionsUnread: true)),
               "a cover version not read: unknown, so Private, even when the file read says public")
        expect(!NoteLibrary.coverUnknown(fileThere: true, fileRead: true, versionsUnread: false) && NoteLibrary.coverUnknown(fileThere: true, fileRead: false, versionsUnread: false)
               && !NoteLibrary.coverUnknown(fileThere: false, fileRead: false, versionsUnread: false), "known only once the file and every version are read")

        expect(NoteLibrary.notebookUnknown(listed: false, unreadCovers: 0) && NoteLibrary.notebookUnknown(listed: true, unreadCovers: 1)
               && !NoteLibrary.notebookUnknown(listed: true, unreadCovers: 0), "a notebook is known only once listed and every cover file in it read")
        // Mail's staging folders: swept at launch once older than an hour.
        let launch = Date()
        expect(NoteDrop.staleStaging([("old", launch.addingTimeInterval(-7200)), ("new", launch.addingTimeInterval(-60))], now: launch) == ["old"],
               "only staging folders older than an hour are swept")
        let sweepRoot = FileManager.default.temporaryDirectory.appending(path: "petal-sweep-\(UUID().uuidString)")
        for name in ["old", "new"] { try? FileManager.default.createDirectory(at: sweepRoot.appending(path: name), withIntermediateDirectories: true) }
        try? FileManager.default.setAttributes([.modificationDate: launch.addingTimeInterval(-7200)], ofItemAtPath: sweepRoot.appending(path: "old").path)
        expect(NoteDrop.sweepStaging(in: sweepRoot, now: launch) == 1 && !FileManager.default.fileExists(atPath: sweepRoot.appending(path: "old").path)
               && FileManager.default.fileExists(atPath: sweepRoot.appending(path: "new").path), "the launch sweep removes the old folder, keeps the new")
        try? FileManager.default.removeItem(at: sweepRoot)

        // Petal's own pictures leave out every window showing a Private notebook's note.
        let surfaces = [NotePrivacy.Surface(window: 11, showsPrivate: true), NotePrivacy.Surface(window: 12, showsPrivate: false),
                        NotePrivacy.Surface(window: 13, showsPrivate: true)]
        let excluded = NotePrivacy.excludedWindows(surfaces)
        expect(excluded == [11, 13], "the exclusion list: the papers, tabs, fan and window showing a Private note")
        expect(!NotePrivacy.mayCapture(window: 11, excluded: excluded) && NotePrivacy.mayCapture(window: 12, excluded: excluded) && NotePrivacy.mayCapture(window: 99, excluded: excluded),
               "no picture of one of them; any other window may be pictured")

        // Cover changes bound to their root and their cover id or folder, never the name.
        let bound = CoverFields(notebook: "Same", root: "/A", coverID: "cov-1", folderID: "1:100", fields: ["private": "true"])
        let inA: [(name: String, coverID: String, folderID: String)] = [("Same renamed", "cov-1", "1:100"), ("Other", "cov-2", "1:200")]
        let inB: [(name: String, coverID: String, folderID: String)] = [("Same", "cov-9", "2:100")]
        expect(bound.target(root: "/A", notebooks: inA) == "Same renamed", "in its own root: its notebook by cover id, whatever its name now")
        expect(bound.target(root: "/B", notebooks: inB) == nil, "another root's notebook of the same name: never")
        let coverless = CoverFields(notebook: "Bare", root: "/A", folderID: "1:300", fields: ["private": "true"])
        expect(coverless.target(root: "/A", notebooks: [("Bare now", "cov-new", "1:300")]) == "Bare now", "no cover id: its folder")
        expect(coverless.target(root: "/A", notebooks: [("Bare", "", "1:301")]) == nil, "a folder of the same name that isn't it: never")
        expect(bound.key != CoverFields(notebook: "Same", root: "/B", coverID: "cov-1").key, "kept per root")
        // A note held in memory whose notebook the latest read didn't find: unknown, so Private, never readable.
        let counted = NotePrivacy.privateBooks(notebooks: [("Health", true), ("Garden", false)], held: ["Garden", "Gone", "health"])
        expect(counted.contains("Gone") && counted.contains("Health") && !counted.contains("Garden"), "a held note's missing notebook counts as Private", "\(counted)")
        expect(!NotePrivacy.readable(notebook: "Gone", privateBooks: counted, asker: nil), "and its notes aren't readable from outside it")
        // Canvas keys: by cover id, else the notebook's folder; a folder key follows the folder, never a name.
        expect(CanvasQueue.notebook(key: CanvasQueue.folderKey("1:42"), covers: [], folders: [("1:42", "Trip renamed"), ("1:43", "Trip")]) == "Trip renamed"
               && CanvasQueue.notebook(key: CanvasQueue.folderKey("1:44"), covers: [], folders: [("1:42", "Trip")]) == nil
               && CanvasQueue.notebook(key: "cov", covers: [("cov", "Work")], folders: []) == "Work",
               "a canvas entry's notebook by its cover id, or its folder while the cover id isn't known")
        // Mail: a picture's file, else its held bytes staged, else missing and said.
        expect(NoteDrop.attachment(onDisk: true, held: true) == .file && NoteDrop.attachment(onDisk: false, held: true) == .stage
               && NoteDrop.attachment(onDisk: false, held: false) == .missing, "a picture for Mail: its file, its held bytes, or missing")
        let stageFolder = FileManager.default.temporaryDirectory.appending(path: "petal-mail-check-\(UUID().uuidString)")
        let staged = NoteDrop.stage(Data([0x89, 0x50, 0x4e, 0x47]), name: "shot.png", in: stageFolder)
        expect(staged.map { (try? Data(contentsOf: $0)) == Data([0x89, 0x50, 0x4e, 0x47]) && $0.deletingLastPathComponent().standardizedFileURL.path == stageFolder.standardizedFileURL.path } == true,
               "held bytes staged in a temporary file of their own")
        expect(NoteDrop.stage(Data([1]), name: "..", in: stageFolder) == nil && NoteDrop.stage(Data([1]), name: "shot.png", in: stageFolder) == nil,
               "never a name that leaves the folder, never over a file")
        try? FileManager.default.removeItem(at: stageFolder)
        expect(NoteDrop.missingWords(0) == nil && NoteDrop.missingWords(1) == "1 picture couldn't be attached." && NoteDrop.missingWords(2) == "2 pictures couldn't be attached.",
               "what's said when pictures couldn't go along")
        expect(!CanvasQueue.gone(found: false, complete: false) && CanvasQueue.gone(found: false, complete: true) && !CanvasQueue.gone(found: true, complete: true),
               "a canvas entry is rescued only when its notebook isn't found in a folder read completely")

        // Cover fields, one by one: a field never carries an old value of another.
        var synced = NoteFile(id: "C2", body: "")
        synced.cover = true
        synced.setScalar("private", "true")   // synced from another Mac
        var waitingColor = CoverFields(notebook: "Garden")
        waitingColor.fields["color"] = "#62ba46"
        CoverFields.apply(waitingColor.fields, to: &synced)
        expect(NoteContract.isPrivate(synced) && synced.color == "#62ba46", "a waiting color lands without touching a synced Private")
        let shown = waitingColor.shown(isPrivate: true, unknown: false, color: "#007aff", view: .canvas)
        expect(shown.isPrivate && shown.color == "#62ba46" && shown.view == .canvas, "shown: only the waiting field over what the cover says")
        var waitingPrivate = CoverFields(notebook: "Garden")
        waitingPrivate.fields["private"] = "true"
        expect(waitingPrivate.shown(isPrivate: false, unknown: false, color: "", view: .grid).isPrivate, "Private shown at once")
        var twice = waitingPrivate
        twice.fields["private"] = ""
        expect(twice.after(wrote: ["private": "true"]).fields["private"] == "" && waitingPrivate.after(wrote: ["private": "true"]).isEmpty,
               "a write acknowledges a field only while it still holds what it wrote")

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
