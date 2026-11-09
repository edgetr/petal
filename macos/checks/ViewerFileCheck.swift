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

        // MARK: The path an agent names

        let home = "/Users/someone"
        expect(ViewerPath.standardized("~/Docs/../a.pdf", home: home) == "/Users/someone/a.pdf", "~ and .. resolved")
        expect(ViewerPath.standardized("Docs/a.pdf", home: home) == nil, "a relative path isn't taken")
        func decide(_ path: String, _ resolved: String?, regular: Bool = true, owner: UInt32 = 501) -> Result<String, ViewerPath.Refusal> {
            ViewerPath.decide(standardized: path, resolved: resolved, homes: [home], regular: regular, owner: owner, me: 501)
        }
        expect(decide("/Users/someone/a.pdf", "/Users/someone/a.pdf") == .success("/Users/someone/a.pdf"), "the person's own file")
        expect(decide("/Users/someone/link.pdf", "/etc/secret.pdf") == .failure(.linkOutOfHome), "never through a link out of the home folder")
        expect(decide("/Users/someone/link.pdf", "/Users/someone/real.pdf") == .success("/Users/someone/real.pdf"), "a link inside it is fine")
        expect(decide("/private/tmp/a.pdf", "/private/tmp/a.pdf") == .success("/private/tmp/a.pdf"), "the system's own folders are the system's")
        expect(decide("/Users/someone/a.pdf", "/Users/someone/a.pdf", owner: 0) == .failure(.notOwned), "someone else's file isn't opened")
        expect(decide("/Users/someone/a.pdf", "/Users/someone/a.pdf", regular: false) == .failure(.notRegular), "a folder or package isn't a file")
        expect(decide("/Users/someone/a.pdf", nil) == .failure(.missing), "nothing there")
        expect(decide("/Users/someone/a.txt.exe", "/Users/someone/a.txt.exe") == .failure(.notShown), "only what the viewer shows")
        // On the disk, in a throwaway folder standing in for the home folder.
        let base = FileManager.default.temporaryDirectory.appending(path: "petal-viewer-check-\(UUID().uuidString)")
        let fakeHome = base.appending(path: "home")
        let outside = base.appending(path: "outside")
        try? FileManager.default.createDirectory(at: fakeHome.appending(path: "Docs"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try? Data("%PDF-1.4".utf8).write(to: fakeHome.appending(path: "Docs/Report.pdf"))
        try? Data("%PDF-1.4".utf8).write(to: outside.appending(path: "Elsewhere.pdf"))
        try? FileManager.default.createDirectory(at: fakeHome.appending(path: "Docs/Folder.pdf"), withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: fakeHome.appending(path: "Docs/Out.pdf").path, withDestinationPath: outside.appending(path: "Elsewhere.pdf").path)
        try? FileManager.default.createSymbolicLink(atPath: fakeHome.appending(path: "Docs/In.pdf").path, withDestinationPath: fakeHome.appending(path: "Docs/Report.pdf").path)
        try? FileManager.default.createSymbolicLink(atPath: fakeHome.appending(path: "Away").path, withDestinationPath: outside.path)
        let h = fakeHome.path
        expect((try? ViewerPath.check(h + "/Docs/Report.pdf", home: h).get())?.lastPathComponent == "Report.pdf", "a regular file of the person's opens")
        expect((try? ViewerPath.check("~/Docs/Report.pdf", home: h).get())?.lastPathComponent == "Report.pdf", "~/ is the home folder")
        expect((try? ViewerPath.check(h + "/Docs/In.pdf", home: h).get())?.lastPathComponent == "Report.pdf", "a link inside the home folder is followed")
        expect(ViewerPath.check(h + "/Docs/Out.pdf", home: h).failureValue == .linkOutOfHome, "a link out of it isn't")
        expect(ViewerPath.check(h + "/Away/Elsewhere.pdf", home: h).failureValue == .linkOutOfHome, "nor a linked folder out of it")
        expect(ViewerPath.check(h + "/Docs/Folder.pdf", home: h).failureValue == .notRegular, "a folder named like a PDF isn't a file")
        expect(ViewerPath.check(h + "/Docs/Missing.pdf", home: h).failureValue == .missing, "a missing file")
        expect(ViewerPath.check("Docs/Report.pdf", home: h).failureValue == .notAbsolute, "a relative path")
        try? FileManager.default.removeItem(at: base)

        // MARK: Notes in the margin

        var plain = NoteStick(kind: .file)
        plain.path = "/Users/someone/Report.pdf"
        var paged = plain
        paged.page = 2
        var other = plain
        other.path = "/Users/someone/Other.pdf"
        var tab = NoteStick(kind: .tab)
        tab.url = "https://example.com"
        expect(ViewerMatch.place([tab, plain, paged, passage], path: "/Users/someone/Report.pdf") == 3, "a passage first, then a page, then the file")
        expect(ViewerMatch.place([tab, plain, paged], path: "/Users/someone/Report.pdf") == 2, "a page before the file")
        expect(ViewerMatch.place([tab, other], path: "/Users/someone/Report.pdf") == nil, "a note on another file isn't in this margin")
        expect(ViewerMatch.place([other], path: "/private/var/x.pdf", also: ["/Users/someone/Other.pdf"]) == 0, "the file under the path it was opened by")
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
        let spot = ViewerComments.spot(passage, pages: 5, pageSize: size)
        expect(spot?.page == 2 && spot?.bounds == CGRect(x: 72, y: 540.5, width: 200, height: 14), "a passage's comment on its highlight")
        expect(ViewerComments.spot(plain, pages: 5, pageSize: size)?.page == 0 && ViewerComments.spot(plain, pages: 5, pageSize: size)?.bounds == nil,
               "a note on the file: a sticky note on the first page")
        expect(ViewerComments.spot(passage, pages: 1, pageSize: size)?.page == 0 && ViewerComments.spot(passage, pages: 1, pageSize: size)?.bounds == nil,
               "a page the PDF hasn't any more: a sticky note on the first, never a highlight in the wrong place")

        // MARK: Keeping up, the lens

        expect(ViewerUpdated.label(when, now: when.addingTimeInterval(5)) == "Updated just now"
               && ViewerUpdated.label(when, now: when.addingTimeInterval(300)) == "Updated 5 min ago"
               && ViewerUpdated.label(when, now: when.addingTimeInterval(7200)) == nil && ViewerUpdated.label(nil, now: when) == nil, "Updated just now")
        let page = "Heading\nThe first paragraph has words.\nThe second one too."
        let range = page.range(of: "paragraph")!
        expect(String(page[ViewerLens.paragraph(page, around: range)]) == "The first paragraph has words.", "the paragraph a selection is in")
        expect(ViewerLens.short(String(repeating: "a", count: 400)).count == 280, "an answer kept short")

        print("viewer: \(passed) passed" + (failures > 0 ? ", \(failures) failed" : ""))
        if failures > 0 { exit(1) }
    }
}

extension Result {
    var failureValue: Failure? { if case .failure(let error) = self { error } else { nil } }
}
