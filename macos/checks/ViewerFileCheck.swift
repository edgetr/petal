import CoreGraphics
import Foundation

// Checks ViewerFile.swift, the pure side of Petal's viewer: a file anchor's page, slide and passage bounds round
// trip (and stay a file anchor), which files it shows and how, the path an agent names (on throwaway folders in the
// temporary folder: a regular file the person owns, never through a link out of the home folder), which note sits
// where in the margin, a preview cut into pages, the names of copies, what a comment says, and the reading lens's
// paragraph. Run with macos/checks/run.sh.
@main
struct ViewerFileCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static func main() {
        let when = NoteFile.date("2026-11-08T09:30:00Z")!

        // MARK: A file anchor with a spot in it

        var passage = NoteStick(kind: .file)
        passage.path = "/Users/someone/Report.pdf"
        passage.bookmark = "Ym9va21hcms="
        passage.page = 3
        passage.bounds = [72, 540.5, 200, 14]
        passage.quote = "Growth held steady"
        passage.before = "In short: "
        passage.after = " through the year."
        var slide = NoteStick(kind: .file)
        slide.path = "/Users/someone/Deck.pptx"
        slide.slide = 5
        var note = NoteFile(id: "V1", created: when, body: "Check the source")
        note.places = [passage, slide]
        let text = note.serialized()
        let back = NoteFile.parse(text, fallbackID: "x", fallbackDate: when)
        expect(back == note, "a file anchor's page, slide and bounds round trip", text)
        expect(text.contains("    page: 3") && text.contains("    slide: 5") && text.contains("bounds: 72 540.5 200 14"), "written as the contract says", text)
        expect(back.places[0].kind == .file, "a passage in the viewer stays a file anchor")
        // Unreadable spots are kept as written, never dropped.
        let odd = NoteFile.parse("---\nid: V2\nplaces:\n  - kind: file\n    path: /a.pdf\n    page: zero\n    bounds: 1 2 three 4\n---\n", fallbackID: "x", fallbackDate: when)
        expect(odd.places[0].page == nil && odd.places[0].bounds == nil && odd.places[0].extra.map(\.key) == ["page", "bounds"], "unreadable spots kept as written")
        expect(odd.serialized().contains("page: zero") && odd.serialized().contains("bounds: 1 2 three 4"), "and written back as they were")
        expect(ViewerSpots.bounds("1 2 0 4") == nil && ViewerSpots.bounds("1 2 3") == nil && ViewerSpots.bounds("nan 2 3 4") == nil, "bounds need four numbers and a size")
        // Numbers no page has: no bounds, never a trap (Int of 1e20 would stop Petal on every load).
        expect(ViewerSpots.bounds("1e20 2 3 4") == nil && ViewerSpots.bounds("1 2 3 1e300") == nil && ViewerSpots.bounds("-2000000 2 3 4") == nil
               && ViewerSpots.bounds("inf 2 3 4") == nil, "out-of-range bounds are no bounds")
        expect(ViewerSpots.boundsText([1e20, 2, 3, 4]) == nil && ViewerSpots.boundsText([1, 2, 3, .infinity]) == nil
               && ViewerSpots.boundsText([14400, -14400, 999_999.5, 0.5]) == "14400 -14400 999999.5 0.5", "only what a page can have is written")
        let huge = NoteFile.parse("---\nid: V3\nplaces:\n  - kind: file\n    path: /a.pdf\n    bounds: 1e20 2 3 4\n---\n", fallbackID: "x", fallbackDate: when)
        expect(huge.places[0].bounds == nil && huge.serialized().contains("bounds: 1e20 2 3 4"), "kept as written, as unknown")
        // In other apps it's the file: Phase 1's AXDocument match is unchanged.
        expect(NoteMatch.fits(passage, NoteScene(file: "/Users/someone/Report.pdf")), "fits the file in Preview or Acrobat")
        expect(!NoteMatch.fits(passage, NoteScene(file: "/Users/someone/Other.pdf")), "never another file")
        var samePage = passage
        samePage.bookmark = "b3RoZXI="
        var otherPage = passage
        otherPage.page = 4
        expect(passage.samePlace(samePage) && !passage.samePlace(otherPage), "the same spot only on the same page and words")
        expect(slide.label() == "Deck.pptx · slide 5" && passage.spot == "page 3", "the letterhead says where in the file", slide.label())
        expect(passage.words.hasPrefix("“Growth held steady” on Report.pdf, page 3"), "in words", passage.words)
        expect(passage.scrubbed.page == nil && passage.scrubbed.quote.isEmpty, "a private app's spot isn't told")

        // MARK: What the viewer shows

        expect(ViewerKind.of("/a/b.PDF") == .pdf, "a PDF through PDFKit")
        expect(ViewerKind.of("/a/b.pptx") == .quickLook(.slide) && ViewerKind.of("/a/b.key") == .quickLook(.slide), "decks have slides")
        expect(ViewerKind.of("/a/b.docx") == .quickLook(.page) && ViewerKind.of("/a/b.xlsx") == .quickLook(.page), "documents have pages")
        expect(ViewerKind.of("/a/id_rsa") == nil && ViewerKind.of("/a/b.html") == nil && ViewerKind.of("/a/b.app") == nil, "nothing else")

        // MARK: The path rule: where the file is, by canonical path

        let home = "/Users/someone"
        expect(ViewerPath.absolute("~/Docs/a.pdf", home: home) == "/Users/someone/Docs/a.pdf" && ViewerPath.absolute("Docs/a.pdf", home: home) == nil,
               "~/ is the home folder; a relative path isn't taken")
        expect(ViewerPath.inside("/Users/someone/Docs/a.pdf", home) && !ViewerPath.inside("/Users/someoneelse/a.pdf", home) && !ViewerPath.inside("/etc/a.pdf", home),
               "inside by components, never by a prefix of characters")
        func decide(_ destination: String?, regular: Bool = true, owner: UInt32 = 501, readable: Bool = true) -> Result<String, ViewerPath.Refusal> {
            ViewerPath.decide(destination: destination, home: home, volumes: "/Volumes", regular: regular, owner: owner, me: 501, readable: readable)
        }
        // Mounted volumes (external drives, network shares): a file the person can read, whoever the disk says owns it.
        expect(decide("/Volumes/Drive/Report.pdf", owner: 0) == .success("/Volumes/Drive/Report.pdf"), "a file on an external drive the person can read")
        expect(decide("/Volumes/Share/Team/Deck.pptx", owner: 99) == .success("/Volumes/Share/Team/Deck.pptx"), "on a network share too")
        expect(decide("/Volumes/Drive/Report.pdf", readable: false) == .failure(.notReadable), "one they can't read: refused")
        expect(decide("/Volumes/Report.pdf") == .failure(.outsideRoots), "/Volumes itself isn't a volume")
        expect(decide("/Users/someone/a.pdf", owner: 0, readable: true) == .failure(.notOwned), "in the home folder it must still be their own")
        expect(decide("/System/Library/a.pdf") == .failure(.outsideRoots) && decide("/Library/a.pdf") == .failure(.outsideRoots)
               && decide("/Users/someoneelse/a.pdf") == .failure(.outsideRoots), "/System, /Library and other people's homes: refused")
        expect(decide("/Users/someone/a.pdf") == .success("/Users/someone/a.pdf"), "the person's own file in the home folder")
        expect(decide("/etc/secret.pdf") == .failure(.outsideRoots) && decide("/private/tmp/a.pdf") == .failure(.outsideRoots), "a destination outside it: refused")
        expect(decide("/Users/someone/a.pdf", owner: 0) == .failure(.notOwned), "someone else's file isn't opened")
        expect(decide("/Users/someone/a.pdf", regular: false) == .failure(.notRegular), "a folder or package isn't a file")
        expect(decide(nil) == .failure(.missing), "nothing there")
        expect(decide("/Users/someone/a.txt.exe") == .failure(.notShown), "only what the viewer shows")
        // On the disk, in a throwaway folder standing in for the home folder.
        let base = FileManager.default.temporaryDirectory.appending(path: "petal-viewer-check-\(UUID().uuidString)")
        let fakeHome = base.appending(path: "Home")
        let outside = base.appending(path: "outside")
        try? FileManager.default.createDirectory(at: fakeHome.appending(path: "Docs"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try? Data("%PDF-1.4".utf8).write(to: fakeHome.appending(path: "Docs/Report.pdf"))
        try? Data("%PDF-1.4".utf8).write(to: outside.appending(path: "Elsewhere.pdf"))
        try? FileManager.default.createDirectory(at: fakeHome.appending(path: "Docs/Folder.pdf"), withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: fakeHome.appending(path: "Docs/Out.pdf").path, withDestinationPath: outside.appending(path: "Elsewhere.pdf").path)
        try? FileManager.default.createSymbolicLink(atPath: fakeHome.appending(path: "Docs/In.pdf").path, withDestinationPath: fakeHome.appending(path: "Docs/Report.pdf").path)
        try? FileManager.default.createSymbolicLink(atPath: fakeHome.appending(path: "Away").path, withDestinationPath: outside.path)
        try? FileManager.default.createSymbolicLink(atPath: outside.appending(path: "Back").path, withDestinationPath: fakeHome.appending(path: "Docs").path)
        let h = fakeHome.path
        let report = ViewerPath.canonical(fakeHome.appending(path: "Docs/Report.pdf").path)
        expect((try? ViewerPath.check(h + "/Docs/Report.pdf", home: h).get())?.path == report, "a regular file of the person's opens, by its canonical path")
        expect((try? ViewerPath.check("~/Docs/Report.pdf", home: h).get())?.path == report, "~/ is the home folder")
        expect((try? ViewerPath.check(h + "/Docs/In.pdf", home: h).get())?.path == report, "a link to a file in the home folder is followed")
        expect((try? ViewerPath.check(h + "/Away/Back/Report.pdf", home: h).get())?.path == report, "a link out and back in: it's where the file is that counts")
        expect((try? ViewerPath.check(h + "/Docs/../Docs/Report.pdf", home: h).get())?.path == report, "a .. inside the home folder is fine")
        // ".." after a link out of home goes up from where the link leads (outside): a file there is outside, refused.
        try? FileManager.default.createDirectory(at: base.appending(path: "Docs"), withIntermediateDirectories: true)
        try? Data("%PDF-1.4".utf8).write(to: base.appending(path: "Docs/Report.pdf"))
        expect(ViewerPath.check(h + "/Away/../Docs/Report.pdf", home: h).failureValue == .outsideRoots, "a .. through a link out of home: where it really leads, outside, refused")
        expect(ViewerPath.check(h + "/Docs/Out.pdf", home: h).failureValue == .outsideRoots, "a link out of it: the destination is outside, refused")
        expect(ViewerPath.check(h + "/Away/Elsewhere.pdf", home: h).failureValue == .outsideRoots, "nor through a linked folder")
        expect(ViewerPath.check(outside.appending(path: "Elsewhere.pdf").path, home: h).failureValue == .outsideRoots, "nor named directly")
        // Other casing (macOS's disks don't care; the canonical path is the file system's own spelling).
        let otherCasing = base.appending(path: "home/docs/REPORT.pdf").path
        expect(FileManager.default.fileExists(atPath: otherCasing), "(a disk that ignores case, as macOS's do)")
        if FileManager.default.fileExists(atPath: otherCasing) {
            expect((try? ViewerPath.check(otherCasing, home: h).get())?.path == report, "the path in other casing: the same file, inside")
            expect((try? ViewerPath.check(h + "/Docs/Report.pdf", home: base.appending(path: "HOME").path).get())?.path == report, "the home folder in other casing too")
        }
        expect(ViewerPath.check(h + "/Docs/Folder.pdf", home: h).failureValue == .notRegular, "a folder named like a PDF isn't a file")
        expect(ViewerPath.check(h + "/Docs/Missing.pdf", home: h).failureValue == .missing, "a missing file")
        expect(ViewerPath.check("Docs/Report.pdf", home: h).failureValue == .notAbsolute, "a relative path")
        // A stand-in for /Volumes: a drive's file the person can read opens, one they can't is refused.
        let volumes = base.appending(path: "Volumes")
        try? FileManager.default.createDirectory(at: volumes.appending(path: "Drive"), withIntermediateDirectories: true)
        let onDrive = volumes.appending(path: "Drive/Report.pdf")
        try? Data("%PDF-1.4".utf8).write(to: onDrive)
        expect((try? ViewerPath.check(onDrive.path, home: h, volumes: volumes.path).get()) != nil, "a /Volumes path: a file on a mounted drive opens")
        let locked = volumes.appending(path: "Drive/Locked.pdf")
        try? Data("%PDF-1.4".utf8).write(to: locked)
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        expect(ViewerPath.check(locked.path, home: h, volumes: volumes.path).failureValue == .notReadable, "one the person can't read: refused")
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        expect(ViewerPath.check(outside.appending(path: "Elsewhere.pdf").path, home: h, volumes: volumes.path).failureValue == .outsideRoots,
               "anywhere else still refused with volumes allowed")
        try? FileManager.default.removeItem(at: base)
        // The real rule (the person's home folder and /Volumes): a file in /private/tmp is refused.
        let inTmp = URL(fileURLWithPath: "/private/tmp/petal-viewer-check-\(UUID().uuidString).pdf")
        try? Data("%PDF-1.4".utf8).write(to: inTmp)
        if FileManager.default.fileExists(atPath: inTmp.path) {
            expect(ViewerPath.check(inTmp.path, home: NSHomeDirectory(), volumes: "/Volumes").failureValue == .outsideRoots, "a /private/tmp path: refused")
            expect(ViewerPath.check("/tmp/" + inTmp.lastPathComponent, home: NSHomeDirectory(), volumes: "/Volumes").failureValue == .outsideRoots,
                   "and through /tmp, which leads there")
            try? FileManager.default.removeItem(at: inTmp)
        } else {
            expect(false, "a throwaway file in /private/tmp (couldn't be made)")
        }

        // MARK: Notes in the margin

        var plain = NoteStick(kind: .file)
        plain.path = "/Users/someone/Report.pdf"
        var paged = plain
        paged.page = 2
        var other = plain
        other.path = "/Users/someone/Other.pdf"
        var tab = NoteStick(kind: .tab)
        tab.url = "https://example.com"
        let onReport = { (stick: NoteStick) in stick.path == "/Users/someone/Report.pdf" }
        expect(ViewerMatch.place([tab, plain, paged, passage], onFile: onReport) == 3, "a passage first, then a page, then the file")
        expect(ViewerMatch.place([tab, plain, paged], onFile: onReport) == 2, "a page before the file")
        expect(ViewerMatch.place([tab, other], onFile: onReport) == nil, "a note on another file isn't in this margin")
        expect(ViewerMatch.place([tab], onFile: { _ in true }) == nil, "a tab never names a file")
        var sentence = NoteStick(kind: .passage)
        sentence.path = "/Users/someone/Report.pdf"
        sentence.quote = "Growth held steady"
        var pageSentence = NoteStick(kind: .passage)
        pageSentence.url = "https://example.com/report"
        pageSentence.quote = "Growth held steady"
        expect(ViewerFiles.namesFile(sentence) && !ViewerFiles.namesFile(pageSentence) && ViewerFiles.namesFile(plain) && !ViewerFiles.namesFile(tab),
               "Phase 1's sentence in a file names it; a sentence on a page doesn't")
        expect(ViewerMatch.place([plain, sentence], onFile: onReport) == 1, "a Preview sentence is a passage in the margin")

        // MARK: The one file resolver

        expect(ViewerFiles.way(ownFound: true, hasBookmark: true, bookmarkFound: true, pathFound: true) == .own,
               "its own file, wherever it went: a new file at its path (or a bookmark that found that one) is never it")
        expect(ViewerFiles.way(ownFound: false, hasBookmark: true, bookmarkFound: true, pathFound: true) == .bookmark,
               "its own file not found as that incarnation (gone, its inode reused, another Mac's): the file its bookmark finds")
        expect(ViewerFiles.way(ownFound: false, hasBookmark: true, bookmarkFound: false, pathFound: true) == .none,
               "a bookmark that finds nothing is never replaced by the path alone")
        expect(ViewerFiles.way(ownFound: false, hasBookmark: false, bookmarkFound: false, pathFound: true) == .path,
               "a place with only a path (written by hand): the file there")
        let record = ViewerFileID(volume: "6D2A-UUID", inode: 370023497, created: 1_762_000_000_123).record(mac: "MAC-1")
        expect(record == "MAC-1|6D2A-UUID|370023497|1762000000123" && ViewerFileID.parse(record)?.mac == "MAC-1"
               && ViewerFileID.parse(record)?.id == ViewerFileID(volume: "6D2A-UUID", inode: 370023497, created: 1_762_000_000_123),
               "a file's incarnation as a place records it: this Mac, the volume's UUID, the inode, the creation date")
        expect(ViewerFileID.parse("16777234:370023497") == nil && ViewerFileID.parse("M|V|x|1") == nil && ViewerFileID.parse("|V|1|1") == nil,
               "anything else isn't one (an older device:inode goes by its bookmark)")
        var withID = plain
        withID.fileID = record
        var idNote = NoteFile(id: "V9", created: when, body: "")
        idNote.places = [withID]
        expect(NoteFile.parse(idNote.serialized(), fallbackID: "x", fallbackDate: when).places[0].fileID == withID.fileID, "kept in the file")
        expect(!ViewerClose.transfer.letsGoIfEmpty && ViewerClose.fold.letsGoIfEmpty, "a note handed to its other editor is never let go of")
        expect(ViewerMatch.pageIndex(paged, count: 5) == 1 && ViewerMatch.pageIndex(paged, count: 1) == nil && ViewerMatch.pageIndex(plain, count: 5) == nil,
               "a page the document has, counted from 1")
        let order = ViewerMatch.order([("file", nil, 0), ("p3", 2, 100), ("p1b", 0, 400), ("p1a", 0, 100)], current: 0)
        expect(order == ["p1a", "p1b", "p3", "file"], "the page shown first, then other pages, then the whole file", "\(order)")

        let laid = ViewerMargin.layout([("a", 100, 170), ("b", 150, 170), ("c", 600, 170), ("d", -50, 170)], top: 20)
        expect(laid["d"] == 20 && laid["a"] == 202 && laid["b"] == 384 && laid["c"] == 600, "lined up, pushed below the one above, never above the top", "\(laid)")
        let pin = ViewerMargin.pin(from: CGRect(x: 100, y: 200, width: 50, height: 10), to: CGRect(x: 500, y: 300, width: 310, height: 200))
        expect(pin.first == CGPoint(x: 150, y: 205) && pin.last == CGPoint(x: 500, y: 328), "the dashed line: highlight's right edge to the paper's side")

        // MARK: A preview cut into pages

        let pages = ViewerPages.cut(bottoms: [100, 380, 420, 790, 900, 1500], height: 400, total: 1500)
        expect(pages.map(\.top) == [0, 380, 420, 790, 900, 1300] && pages.last?.bottom == 1500, "pages end where a block ends, never through a line",
               "\(pages)")
        expect(ViewerPages.cut(bottoms: [], height: 0, total: 100).isEmpty && ViewerPages.cut(bottoms: [], height: 50, total: 120, limit: 2).count == 2, "bounded")
        expect(ViewerPages.shape(mime: "text/html", html: "<img src=\"Attachment1.pdf\" width=\"100%\">") == .pdf("Attachment1.pdf"), "iWork's preview is a PDF")
        expect(ViewerPages.shape(mime: "text/html", html: "<div class=\"slide\" style=\"\">") == .slides, "Office's deck: slides")
        expect(ViewerPages.shape(mime: "text/html", html: "<p>words</p>") == .flowing && ViewerPages.shape(mime: "image/png", html: "") == .none, "a document flows")

        // MARK: Copies

        let taken: Set<String> = ["deck (shorter).pptx"]
        expect(ViewerCopies.version(original: "Deck.pptx", label: "Shorter", taken: taken) == "Deck (Shorter) 2.pptx", "a version never takes a name already there")
        expect(ViewerCopies.version(original: "Deck.pptx", label: "a/b: c", taken: []) == "Deck (a b c).pptx", "a label made safe for a name")
        expect(ViewerCopies.withNotes(original: "Report.pdf", taken: []) == "Report (with notes).pdf"
               && ViewerCopies.beforeNotes(original: "Report.pdf", taken: ["report (before notes).pdf"]) == "Report (before notes) 2.pdf", "comments' copies")
        expect(ViewerCopies.labels(["  A ", "", "B", "C", "D", "E", "F", "G"]) == ["A", "B", "C", "D", "E", "F"], "at most six named versions")

        // MARK: Comments

        expect(ViewerComments.text("# Title\n- [ ] one\n- [x] two\n![shot](a.png)\nsee [the page](https://example.com)") == "Title\n☐ one\n☑ two\n(picture)\nsee the page",
               "a note's words as plain text")
        let size = { (_: Int) in CGSize(width: 612, height: 792) }
        let now = CGRect(x: 90, y: 300, width: 180, height: 14)
        let spot = ViewerComments.spot(passage, passage: (1, now), pages: 5, pageSize: size)
        expect(spot?.page == 1 && spot?.bounds == now, "a passage's comment where its words are now, not where they were saved")
        expect(ViewerComments.spot(passage, passage: nil, pages: 5, pageSize: size).map { $0.page == 0 && $0.bounds == nil } == true,
               "a passage that moved: a sticky note on the first page, no highlight from old coordinates")
        expect(ViewerComments.spot(plain, passage: nil, pages: 5, pageSize: size)?.page == 0 && ViewerComments.spot(paged, passage: nil, pages: 5, pageSize: size)?.page == 1,
               "a note on the file: the first page; on a page: that page")
        expect(ViewerComments.spot(paged, passage: nil, pages: 1, pageSize: size)?.page == 0, "a page the PDF hasn't any more: the first")

        // Whole-text redaction: the note's words redacted whole before they're made plain or cut.
        let secret = "sk-live-0123456789abcdef"
        let redact = { (text: String) in text.replacingOccurrences(of: secret, with: "(hidden)") }
        let long = String(repeating: "a", count: 1990) + " " + secret
        expect(!ViewerComments.text(long, redact: redact).contains("sk-live") && ViewerComments.text(long, redact: redact).hasSuffix("(hidden)"),
               "a secret across the cut is hidden whole, never cut in two first")
        expect(ViewerComments.text("see [\(secret)](https://example.com)", redact: redact) == "see (hidden)", "a secret inside a link's words")

        // MARK: Passages found again by their words

        var moved = NoteStick(kind: .file)
        moved.quote = "the second half"
        moved.before = "steady through "
        moved.after = "."
        let pagesNow = ["Intro words.", "Growth held steady through the second half. Then more."]
        let again = ViewerPassages.find(moved, in: pagesNow)
        expect(again?.page == 1 && again.map { (pagesNow[1] as NSString).substring(with: $0.range) } == "the second half", "found on the page it moved to")
        expect(ViewerPassages.find(moved, in: ["Growth held steady through the first half."]) == nil, "its words gone: moved")
        expect(ViewerPassages.find(moved, in: ["x the second half y", "z the second half w"]) == nil, "two places as likely: no guess")
        moved.before = "through "
        expect(ViewerPassages.find(moved, in: ["x the second half y", "through the second half."])?.page == 1, "told apart by the words around it")
        var noWords = NoteStick(kind: .file)
        noWords.bounds = [1, 2, 3, 4]
        noWords.page = 1
        expect(ViewerPassages.find(noWords, in: pagesNow) == nil, "coordinates alone are never a passage")
        let emoji = ["👋🏽 hi there, the quote"]
        var wide = NoteStick(kind: .file)
        wide.quote = "the quote"
        expect(ViewerPassages.find(wide, in: emoji).map { (emoji[0] as NSString).substring(with: $0.range) } == "the quote", "a range PDFKit can use (UTF-16)")

        // MARK: Secrets looked for in the whole text

        let pageText = "Before words. The passage here. Key: SECRET123 after."
        let selected = NSRange(pageText.range(of: "The passage here.")!, in: pageText)
        let secretSpan = { (text: String) -> [Range<Int>] in
            guard let r = text.range(of: "SECRET123") else { return [] }
            let start = text.distance(from: text.startIndex, to: r.lowerBound)
            return [start..<(start + 9)]
        }
        expect(ViewerSecrets.passage(pageText, range: selected, secrets: secretSpan(pageText), context: 80) == nil,
               "a secret in the words kept around a passage: no note")
        let cutNear = ViewerSecrets.passage(pageText, range: selected, secrets: secretSpan(pageText), context: 4)
        expect(cutNear?.quote == "The passage here." && cutNear?.before == "ds. " && cutNear?.after == " Key", "kept clear of it: the passage and its words")
        expect(ViewerSecrets.passage(pageText, range: NSRange(location: 0, length: (pageText as NSString).length), secrets: secretSpan(pageText), limit: 5) == nil,
               "the whole selection is checked, even past what's kept of it")
        expect(ViewerSecrets.cut(pageText, range: NSRange(location: 32, length: 21), secrets: secretSpan(pageText), hidden: "(hidden)") == "Key: (hidden) after.",
               "the lens's words: secrets hidden, found in the whole page first")
        expect(ViewerSecrets.cut(pageText, range: NSRange(location: 37, length: 4), secrets: secretSpan(pageText), hidden: "(hidden)") == "(hidden)",
               "part of a secret is still hidden")

        // MARK: Writes land only on their base

        let stamp = ViewerUpdated.Stamp(size: 10, modified: 1, inode: 7)
        let bytes = Data("%PDF-1.4 a".utf8)
        let allowed = ViewerFileID(volume: "V", inode: 7, created: 1), replacement = ViewerFileID(volume: "V", inode: 9, created: 2)
        expect(ViewerWrites.land(live: true, base: (stamp, bytes), expected: allowed, now: (stamp, bytes, allowed)) == .land, "unchanged: it lands")
        expect(ViewerWrites.land(live: false, base: (stamp, bytes), expected: allowed, now: (stamp, bytes, allowed)) == .hungUp, "its asker gone: nothing")
        var replaced = stamp
        replaced.inode = 8
        expect(ViewerWrites.land(live: true, base: (stamp, bytes), expected: nil, now: (replaced, bytes, nil)) == .changed, "the file replaced: refused")
        expect(ViewerWrites.land(live: true, base: (stamp, bytes), expected: allowed, now: (stamp, bytes, replacement)) == .changed,
               "another file than the one the person allowed, even with the same bytes: refused")
        expect(ViewerWrites.land(live: true, base: (stamp, bytes), expected: nil, now: (stamp, Data("%PDF-1.4 b".utf8), nil)) == .changed, "same stamp, other bytes: refused")
        expect(ViewerWrites.land(live: true, base: (stamp, bytes), expected: nil, now: (nil, nil, nil)) == .changed, "gone: refused")

        // MARK: Keeping up, the lens

        expect(ViewerUpdated.label(when, now: when.addingTimeInterval(5)) == "Updated just now"
               && ViewerUpdated.label(when, now: when.addingTimeInterval(300)) == "Updated 5 min ago"
               && ViewerUpdated.label(when, now: when.addingTimeInterval(7200)) == nil && ViewerUpdated.label(nil, now: when) == nil, "Updated just now")
        let page = "Heading\nThe first paragraph has words.\nThe second one too."
        let range = page.range(of: "paragraph")!
        expect(String(page[ViewerLens.paragraph(page, around: range)]) == "The first paragraph has words.", "the paragraph a selection is in")
        expect(ViewerLens.short(String(repeating: "a", count: 400)).count == 280, "an answer kept short")

        // MARK: Versions, the margin's open paper, fences, pages, a file's other names

        let labels = ViewerCopies.labels(["Draft", "Draft", "draft", "Other"])
        expect(labels == ["Draft", "Draft (2)", "draft (3)", "Other"], "the same label twice is told apart for the person", "\(labels)")
        let ids = labels.indices.map(ViewerCopies.versionID)
        expect(Set(ids).count == ids.count && ids == ["v1", "v2", "v3", "v4"], "every version has an id of its own, never its label")
        let copies = labels.reduce(into: [String]()) { names, label in names.append(ViewerCopies.version(original: "Deck.pptx", label: label, taken: Set(names.map { $0.lowercased() }))) }
        expect(Set(copies.map { $0.lowercased() }).count == copies.count, "and a file of its own", "\(copies)")

        let laidOut = ViewerMargin.cascade([("a", 170, false), ("open", 300, true), ("b", 170, false), ("c", 170, false)], floor: 100)
        let open = laidOut["open"]!
        expect(open.x == 18 && open.x + 310 <= 350 && open.tilt == 0, "an open paper is at the margin's full width, never in the right column")
        expect(open.y >= laidOut["a"]!.y + 170 && laidOut["b"]!.y >= open.y + 300, "on a row of its own, clear of the papers around it", "\(laidOut)")
        expect(laidOut["b"]!.x == 30 && laidOut["c"]!.x == 165 && laidOut["c"]!.y == laidOut["b"]!.y + 70, "folded ones still cascade")
        let second = ViewerMargin.cascade([("a", 170, false), ("open", 300, true)], floor: 0)
        expect(second["open"]!.x == 18, "even where a right-column paper would have gone")

        var turns = ViewerTurns()
        let older = turns.begin("version:s:v1")
        let newer = turns.begin("version:s:v1")
        let otherTurn = turns.begin("version:s:v2")
        expect(turns.isLatest("version:s:v1", newer) && !turns.isLatest("version:s:v1", older) && turns.isLatest("version:s:v2", otherTurn),
               "an older drawing never lands over a newer one; each version its own")

        expect(ViewerPages.index(Int.min, count: 5) == nil && ViewerPages.index(0, count: 5) == nil && ViewerPages.index(6, count: 5) == nil
               && ViewerPages.index(Int.max, count: 5) == nil && ViewerPages.index(5, count: 5) == 4 && ViewerPages.index(nil, count: 5) == nil,
               "only a page the document has, checked before any arithmetic")
        expect(ViewerPages.requested(NSNumber(value: 3)) == 3 && ViewerPages.requested(NSNumber(value: Int.min)) == nil && ViewerPages.requested(NSNumber(value: 0)) == nil
               && ViewerPages.requested(NSNumber(value: 1e300)) == nil && ViewerPages.requested(NSNumber(value: 2.5)) == nil && ViewerPages.requested("3") == nil,
               "a page an agent gives: a whole number from 1")

        let aliasBase = FileManager.default.temporaryDirectory.appending(path: "petal-viewer-alias-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: aliasBase.appending(path: "Real"), withIntermediateDirectories: true)
        let realPDF = aliasBase.appending(path: "Real/Report.pdf")
        try? Data("%PDF-1.4".utf8).write(to: realPDF)
        try? Data("%PDF-1.4".utf8).write(to: aliasBase.appending(path: "Real/Other.pdf"))
        try? FileManager.default.createSymbolicLink(atPath: aliasBase.appending(path: "Link.pdf").path, withDestinationPath: realPDF.path)
        try? FileManager.default.createSymbolicLink(atPath: aliasBase.appending(path: "Folder").path, withDestinationPath: aliasBase.appending(path: "Real").path)
        let mac = "MAC-CHECK"
        func onDisk(_ path: String, recorded: Bool = false) -> NoteStick {
            var stick = NoteStick(kind: .file)
            stick.path = aliasBase.appending(path: path).path
            if recorded {
                stick.bookmark = (try? URL(fileURLWithPath: stick.path).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))?.base64EncodedString() ?? ""
                stick.fileID = ViewerFileID.of(stick.path)?.record(mac: mac) ?? ""
            }
            return stick
        }
        let follow = { (data: Data) -> URL? in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        let byHand = ["Real/Report.pdf", "Link.pdf", "Folder/Report.pdf", "Real/Other.pdf", "Missing.pdf"].map { onDisk($0) }
        if let report = ViewerFileID.of(realPDF.path) {
            let found = ViewerFiles.on(report, byHand, mac: mac, follow: follow)
            expect(found == Set(byHand.prefix(3).map(ViewerFiles.key)), "a note's path through a link is the same file; another file isn't", "\(found.count)")
            expect(report.path().map { ViewerFileID.of($0) == report } == true, "a file found again by its incarnation")
            // Renamed: its notes follow it; a new file at the old path gets none of them.
            let made = onDisk("Real/Report.pdf", recorded: true)
            let renamed = aliasBase.appending(path: "Real/Renamed.pdf")
            try? FileManager.default.moveItem(at: realPDF, to: renamed)
            expect(ViewerFiles.on(report, [made], mac: mac, follow: follow) == [ViewerFiles.key(made)], "renamed: still on it")
            expect(ViewerFiles.locate(made, mac: mac, follow: follow)?.path.hasSuffix("Renamed.pdf") == true, "found where it is now")
            try? Data("%PDF-1.4 new".utf8).write(to: realPDF)
            let reused = ViewerFileID.of(realPDF.path)
            expect(reused != nil && reused != report && ViewerFiles.on(reused!, [made], mac: mac, follow: follow).isEmpty
                   && ViewerFiles.on(report, [made], mac: mac, follow: follow).count == 1, "a reused path never attaches notes; they stay on the renamed file")
            // The desk, as its read works it out: the new file at the old path in front doesn't get the note; the
            // renamed file in front does.
            var reusedScene = NoteScene(file: realPDF.path)
            reusedScene.onFile = reused.map { ViewerFiles.on($0, [made], mac: mac, follow: follow) }
            var renamedScene = NoteScene(file: renamed.path)
            renamedScene.onFile = ViewerFiles.on(report, [made], mac: mac, follow: follow)
            expect(!NoteMatch.fits(made, reusedScene) && NoteMatch.fits(made, renamedScene), "the desk matches by incarnation: a reused path doesn't, the renamed file does")
            // A record that isn't this very incarnation (its inode reused: another creation date; or another Mac's):
            // never taken for it, the bookmark decides instead.
            var recycled = made
            if let own = ViewerFileID.parse(made.fileID) {
                var other = own.id
                other.created += 1
                recycled.fileID = other.record(mac: mac)
                expect(other.path() == nil, "an inode with another creation date isn't that file")
            }
            recycled.bookmark = (try? realPDF.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))?.base64EncodedString() ?? ""
            expect(ViewerFiles.locate(recycled, mac: mac, follow: follow)?.id == reused, "an incarnation mismatch falls through to the bookmark")
            var elsewhere = made
            elsewhere.bookmark = recycled.bookmark
            expect(ViewerFiles.locate(elsewhere, mac: "ANOTHER-MAC", follow: follow)?.id == reused, "another Mac's record isn't looked up here: the bookmark")
            // A place Phase 1 made (no fileID) on another Mac, whose bookmark finds nothing here: its path decides; made
            // on this Mac: nothing (by the Mac the place records).
            let lost = aliasBase.appending(path: "Lost.pdf")
            try? Data("%PDF-1.4 lost".utf8).write(to: lost)
            var phaseOne = NoteStick(kind: .file)
            phaseOne.path = realPDF.path
            phaseOne.bookmark = (try? lost.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))?.base64EncodedString() ?? ""
            try? FileManager.default.removeItem(at: lost)
            phaseOne.mac = "ANOTHER-MAC"
            expect(ViewerFiles.locate(phaseOne, mac: mac, follow: follow)?.id == reused, "another Mac's Phase 1 place: its path, by the Mac it records")
            phaseOne.mac = mac
            expect(ViewerFiles.locate(phaseOne, mac: mac, follow: follow) == nil, "this Mac's: a bookmark that finds nothing finds nothing")
        } else { expect(false, "a throwaway file") }
        try? FileManager.default.removeItem(at: aliasBase)

        // MARK: Fifth review: identity of papers and saves, names, the desk's match, the viewer offered

        let papersNow = [(key: "/n/Inbox/Renamed.md", id: "N1", version: String?.none), (key: "/n/Inbox/Other.md", id: "N2", version: nil),
                         (key: "/n/Inbox/Twin.md", id: "N3", version: nil), (key: "/n/Work/Twin.md", id: "N3", version: nil)]
        let same = { (id: String, _: String) in id }
        expect(NoteShelf.saveTarget(key: "/n/Inbox/Other.md", noteID: "N2", instance: "", papers: papersNow, current: same) == "/n/Inbox/Other.md", "its own paper")
        expect(NoteShelf.saveTarget(key: "/n/Inbox/Old name.md", noteID: "N1", instance: "", papers: papersNow, current: same) == "/n/Inbox/Renamed.md",
               "renamed while the editor was open: the final save lands on the note as it is now")
        expect(NoteShelf.saveTarget(key: "/n/Inbox/Gone.md", noteID: "N3", instance: "", papers: papersNow, current: same) == nil, "two papers of one id: never a guess")
        expect(NoteShelf.saveTarget(key: "/n/Inbox/Handwritten.md", noteID: "file:Inbox/Handwritten.md", instance: "1:2", papers: papersNow,
                                    current: { id, _ in id == "file:Inbox/Handwritten.md" ? "N1" : id }) == "/n/Inbox/Renamed.md", "an id given meanwhile, followed")
        expect(ViewerPaperID.of(key: "/n/Old.md", holder: "N1", readOnly: false) == ViewerPaperID.of(key: "/n/New.md", holder: "N1", readOnly: false)
               && ViewerPaperID.of(key: "/n/A.md", holder: "N3", readOnly: true) != ViewerPaperID.of(key: "/n/B.md", holder: "N3", readOnly: true),
               "a margin paper's editor kept across a rename; each read-only copy its own")

        let secretName = "ab9Xq.pdf"
        let redactName = { (text: String) in text.replacingOccurrences(of: secretName, with: "(hidden)") }
        let whole = "Plan ab9Xq.pdf"
        expect(!ViewerCopies.stem(redactedName: redactName(whole), ext: "pdf").contains("ab9Xq") && ViewerCopies.stem(redactedName: redactName(whole), ext: "pdf") == "Plan (hidden)",
               "the whole name redacted before the stem is taken")
        let cutFirst = redactName((whole as NSString).deletingPathExtension)
        expect(cutFirst.contains("ab9Xq"), "(cutting first would have kept part of it)")
        expect(ViewerCopies.stem(redactedName: "Report.PDF", ext: "pdf") == "Report" && ViewerCopies.stem(redactedName: "Report (hidden)", ext: "pdf") == "Report (hidden)",
               "the extension taken off only when it's still there")

        var front = NoteScene(file: "/Users/someone/Report.pdf")
        var onPath = NoteStick(kind: .file)
        onPath.path = "/Users/someone/Report.pdf"
        onPath.bookmark = "b2xk"
        var renamedHere = NoteStick(kind: .file)
        renamedHere.path = "/Users/someone/Old name.pdf"
        renamedHere.bookmark = "cmVu"
        front.onFile = [renamedHere.fileKey]
        expect(!NoteMatch.fits(onPath, front), "the desk: a path another file took is never it")
        expect(NoteMatch.fits(renamedHere, front), "the desk: a file renamed since is, by the resolver")
        var previewSentence = NoteStick(kind: .passage)
        previewSentence.path = "/Users/someone/Report.pdf"
        previewSentence.quote = "Growth"
        expect(!NoteMatch.fits(previewSentence, front), "a sentence in a file goes by the resolver too")
        front.onFile = nil
        expect(NoteMatch.fits(onPath, front) && NoteMatch.fits(previewSentence, front), "not worked out: Phase 1's path rule")
        var madeNow = onPath
        madeNow.fileID = "MAC|VOL|1|2"
        front.fileID = madeNow.fileID
        front.onFile = []
        expect(NoteMatch.fits(madeNow, front), "made from this very read: the same incarnation")
        expect(ViewerFiles.way(ownFound: false, foreign: true, hasBookmark: true, bookmarkFound: false, pathFound: true) == .path
               && ViewerFiles.way(ownFound: false, foreign: false, hasBookmark: true, bookmarkFound: false, pathFound: true) == .none,
               "another Mac's bookmark says nothing here (its path decides, Phase 1's rule); this Mac's that finds nothing, nothing")

        var sentenceInPDF = NoteStick(kind: .passage)
        sentenceInPDF.path = "/Users/someone/Report.pdf"
        var sentenceOnPage = NoteStick(kind: .passage)
        sentenceOnPage.url = "https://example.com/report.pdf"
        var unknownKind = NoteStick(kind: .file)
        unknownKind.path = "/Users/someone/run.sh"
        expect(ViewerFiles.offersViewer(sentenceInPDF) && ViewerFiles.offersViewer(onPath) && !ViewerFiles.offersViewer(sentenceOnPage)
               && !ViewerFiles.offersViewer(unknownKind) && !ViewerFiles.offersViewer(tab), "Open in Petal's viewer offered for a sentence noted in Preview")

        // MARK: Eighth review: a refused save's snapshot is the whole note

        var full = NoteFile(id: "R1", created: when, body: "Before")
        var place = NoteStick(kind: .file)
        place.path = "/Users/someone/Report.pdf"
        full.places = [place]
        let journaled = NoteShelf.unsavedText(current: nil, base: full.serialized(), noteID: "R1", body: "Before, typed", now: when.addingTimeInterval(60))
        let parsedBack = NoteFile.parse(journaled, fallbackID: "x", fallbackDate: when)
        expect(parsedBack.id == "R1" && parsedBack.places == full.places && parsedBack.created == when && parsedBack.body == "Before, typed" && journaled.hasPrefix("---"),
               "a refused save's snapshot is the whole note: its front matter kept, its body edited")
        expect(NoteShelf.unsavedText(current: full, base: nil, noteID: "R1", body: "x", now: when).contains("places:"), "from the note as the store has it too")
        expect(NoteShelf.unsavedText(current: nil, base: "Written by hand", noteID: "file:Inbox/Hand.md", body: "Written by hand, typed", now: when) == "Written by hand, typed",
               "a note with no id of its own: its text is its body, as its file is")

        // MARK: Ninth review: versions' copies gated, volumes with no UUID

        let gateBase = FileManager.default.temporaryDirectory.appending(path: "petal-viewer-gate-\(UUID().uuidString)")
        let setFolder = gateBase.appending(path: "Petal Versions/abc")
        let elsewhere = gateBase.appending(path: "elsewhere")
        try? FileManager.default.createDirectory(at: setFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let copy = setFolder.appending(path: "Deck (Short).pdf")
        try? Data("%PDF-1.4".utf8).write(to: copy)
        try? Data("%PDF-1.4 other".utf8).write(to: elsewhere.appending(path: "Private.pdf"))
        expect(ViewerVersionGate.allowed(copy.path, folder: setFolder.path), "Petal's own copy in its set's folder is read")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.createSymbolicLink(atPath: copy.path, withDestinationPath: elsewhere.appending(path: "Private.pdf").path)
        expect(!ViewerVersionGate.allowed(copy.path, folder: setFolder.path), "a copy swapped for a link (to a file outside the allowed roots): refused")
        expect(!ViewerVersionGate.allowed(elsewhere.appending(path: "Private.pdf").path, folder: setFolder.path), "a file outside its set's folder: refused")
        expect(!ViewerVersionGate.allowed(setFolder.path, folder: setFolder.path), "the folder itself isn't a copy")
        try? FileManager.default.removeItem(at: gateBase)

        let fallbackBase = FileManager.default.temporaryDirectory.appending(path: "petal-viewer-local-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: fallbackBase, withIntermediateDirectories: true)
        let onShare = fallbackBase.appending(path: "Report.pdf")
        let otherFile = fallbackBase.appending(path: "Other.pdf")
        try? Data("%PDF-1.4".utf8).write(to: onShare)
        try? Data("%PDF-1.4 other".utf8).write(to: otherFile)
        if let local = ViewerFileID.of(onShare.path, uuid: false) {
            expect(local.isLocalOnly && local.localMount != nil && local.inode > 0, "a volume with no UUID: this Mac's device and mount path stand in")
            expect(ViewerFileID.parse(local.record(mac: "MAC-A"))?.id == local, "recorded with this Mac's id, read back")
            expect(local.path().map { ViewerFileID.of($0, uuid: false) == local } == true, "found again on this Mac by its mount and inode")
            var placeOnShare = NoteStick(kind: .file)
            placeOnShare.path = otherFile.path
            placeOnShare.fileID = local.record(mac: "MAC-A")
            let nobody = { (_: Data) -> URL? in nil }
            expect(ViewerFiles.locate(placeOnShare, mac: "MAC-A", follow: nobody)?.path.hasSuffix("Report.pdf") == true, "on the Mac that recorded it: its own file")
            expect(ViewerFiles.locate(placeOnShare, mac: "MAC-B", follow: nobody)?.path.hasSuffix("Other.pdf") == true,
                   "another Mac never trusts it: its path decides there (no bookmark)")
            var otherLocal = local
            otherLocal.volume = ViewerFileID.localVolume(device: (local.localMount?.device ?? 0) &+ 1, mount: local.localMount?.path ?? "/")
            expect(otherLocal.path() == nil, "another device at that mount path isn't that volume")
        } else { expect(false, "a fallback identity for a throwaway file") }
        try? FileManager.default.removeItem(at: fallbackBase)

        // MARK: Sixth review

        var marker = NoteShelf.EditorMarker()
        marker.typed()
        expect(!marker.saved(landed: false) && marker.dirty, "a refused save keeps the editor dirty")
        expect(!marker.newer() && marker.dirty, "and no newer version replaces what's typed meanwhile")
        expect(marker.saved(landed: true) && !marker.dirty, "landed: clean, and the version that waited is taken")
        var foreignPlace = NoteStick(kind: .file)
        foreignPlace.mac = "OTHER"
        expect(ViewerFiles.isForeign(foreignPlace, mac: "ME"), "a place recording another Mac is that Mac's")
        foreignPlace.mac = "ME"
        expect(!ViewerFiles.isForeign(foreignPlace, mac: "ME"), "this Mac's")
        foreignPlace.mac = ""
        expect(!ViewerFiles.isForeign(foreignPlace, mac: "ME"), "recording none: taken as this Mac's (strict)")
        foreignPlace.mac = "ME"
        foreignPlace.fileID = ViewerFileID(volume: "V", inode: 1, created: 1).record(mac: "OTHER")
        expect(ViewerFiles.isForeign(foreignPlace, mac: "ME"), "its file's record decides first")

        print("viewer: \(passed) passed" + (failures > 0 ? ", \(failures) failed" : ""))
        if failures > 0 { exit(1) }
    }
}

extension Result {
    var failureValue: Failure? { if case .failure(let error) = self { error } else { nil } }
}
