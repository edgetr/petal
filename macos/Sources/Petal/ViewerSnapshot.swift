import AppKit
import PDFKit
import SwiftUI

/// `Petal --snapshot`'s viewer: made-up documents drawn here (nothing of the person's is read), with made-up notes
/// in the margin, as the sketch's Viewer scene has them: a PDF with margin notes and highlights, a slide deck with
/// notes per slide, and versions on copies under the document.
extension Snapshot {
    @MainActor static func viewer(app: PetalApp, folder: String) {
        let root = FileManager.default.temporaryDirectory.appending(path: "petal-snapshot-notes")
        let day = Date().addingTimeInterval(-86400)
        let blue = "#007aff", green = "#62ba46", purple = "#a550a7"
        let books = [Notebook(name: "Inbox", folder: root.appending(path: "Inbox"), color: blue, cover: nil, count: 2),
                     Notebook(name: "Reading", folder: root.appending(path: "Reading"), color: green, cover: nil, count: 2),
                     Notebook(name: "Team", folder: root.appending(path: "Team"), color: purple, cover: nil, count: 3)]
        let size = ViewerLook.size

        // A PDF: notes lined up with their passages, a dashed line to each highlight.
        let pdf = ViewerModel(url: URL(fileURLWithPath: "/Users/someone/Documents/Field guide.pdf"), kind: .pdf)
        pdf.preview(pages: (0..<6).map { samplePage($0) }, current: 0)
        // Made-up places, nothing on disk to resolve: taken as on the file by their path (snapshots only).
        let pdfPath = pdf.url.path
        pdf.previewOnFile = { $0.path == pdfPath }
        func file(_ model: ViewerModel, page: Int? = nil, slide: Int? = nil, bounds: [Double]? = nil, quote: String = "") -> NoteStick {
            var stick = NoteStick(kind: .file)
            stick.path = model.url.path
            stick.page = page
            stick.slide = slide
            stick.bounds = bounds
            stick.quote = quote
            return stick
        }
        var first = NoteFile(id: "V1", created: day, body: "Check this against last year's numbers before the review.\n- [ ] Ask for the source table")
        first.places = [file(pdf, page: 1, bounds: [72, 560, 300, 16], quote: "Growth held steady through the second half")]
        var second = NoteFile(id: "V2", created: day, body: "Good summary to quote in the intro")
        second.places = [file(pdf, page: 1, bounds: [72, 380, 260, 16], quote: "Three changes made the difference")]
        var whole = NoteFile(id: "V3", created: day, body: "Read before Thursday")
        whole.places = [file(pdf)]
        let notesPDF = [PaperNote(file: first, url: root.appending(path: "Reading/Numbers.md"), notebook: "Reading"),
                        PaperNote(file: second, url: root.appending(path: "Reading/Intro.md"), notebook: "Reading"),
                        PaperNote(file: whole, url: root.appending(path: "Inbox/Thursday.md"), notebook: "Inbox")]
        app.paper.store.preview(notesPDF, notebooks: books)
        // The passages as the viewer finds them again by their words on the page drawn above.
        pdf.preview(pages: (0..<6).map { samplePage($0) }, current: 0,
                    passages: [notesPDF[0].key: .found(page: 0, bounds: CGRect(x: 72, y: 558, width: 300, height: 16), lines: [CGRect(x: 72, y: 558, width: 300, height: 16)]),
                               notesPDF[1].key: .found(page: 0, bounds: CGRect(x: 72, y: 378, width: 260, height: 16), lines: [CGRect(x: 72, y: 378, width: 260, height: 16)])])
        pdf.openKey = notesPDF[0].key
        pdf.heights = [notesPDF[0].key: 214, notesPDF[1].key: PaperLook.folded, notesPDF[2].key: PaperLook.folded]
        lay(pdf, size: size, strip: false)
        write(render(AnyView(ViewerView(model: pdf)), app: app, size: size), name: "viewer-pdf", folder: folder)

        // A slide deck through Quick Look: notes per slide, the one shown open.
        let deck = ViewerModel(url: URL(fileURLWithPath: "/Users/someone/Documents/Quarterly plan.pptx"), kind: .quickLook(.slide))
        deck.preview(pages: (0..<9).map { sampleSlide($0) }, current: 2, app: "PowerPoint")
        let deckPath = deck.url.path
        deck.previewOnFile = { $0.path == deckPath }
        var three = NoteFile(id: "D1", created: day, body: "Make the title shorter and give the chart room\n> Two versions are below the slide, made on copies.")
        three.places = [file(deck, slide: 3)]
        var five = NoteFile(id: "D2", created: day, body: "The chart still has last quarter's figures")
        five.places = [file(deck, slide: 5)]
        var seven = NoteFile(id: "D3", created: day, body: "Swap in the new screenshot")
        seven.places = [file(deck, slide: 7)]
        let notesDeck = [PaperNote(file: three, url: root.appending(path: "Team/Slide three.md"), notebook: "Team"),
                         PaperNote(file: five, url: root.appending(path: "Team/Chart.md"), notebook: "Team"),
                         PaperNote(file: seven, url: root.appending(path: "Team/Screenshot.md"), notebook: "Team")]
        app.paper.store.preview(notesDeck, notebooks: books)
        deck.openKey = notesDeck[0].key
        deck.heights = [notesDeck[0].key: 190, notesDeck[1].key: PaperLook.folded, notesDeck[2].key: PaperLook.folded]
        lay(deck, size: size, strip: false)
        write(render(AnyView(ViewerView(model: deck)), app: app, size: size), name: "viewer-slides", folder: folder)

        // Versions on copies under the slide, each with Use this.
        let set = ViewerVersionSet(id: "sample", asker: "snapshot", folder: root, versions: [
            ViewerVersion(id: "v1", label: "Short title", url: root.appending(path: "Quarterly plan (Short title).pptx"), thumb: sampleSlide(2, title: "Plan: faster")),
            ViewerVersion(id: "v2", label: "With figures", url: root.appending(path: "Quarterly plan (With figures).pptx"), thumb: sampleSlide(2, title: "Plan: five wins in a row", dark: true)),
        ])
        deck.versions = set
        lay(deck, size: size, strip: true)
        write(render(AnyView(ViewerView(model: deck)), app: app, size: size), name: "viewer-versions", folder: folder)
    }

    /// Where the snapshot's pages, highlights and page tops are (PDFKit's view draws nothing in a snapshot): the same
    /// layout ViewerPagesPicture draws.
    @MainActor private static func lay(_ model: ViewerModel, size: CGSize, strip: Bool) {
        let origin = CGPoint(x: ViewerLook.rail, y: ViewerLook.bar)
        let area = CGSize(width: size.width - ViewerLook.rail - ViewerLook.margin, height: size.height - ViewerLook.bar - (strip ? 170 : 0))
        let frames = ViewerSnapshotPages.frames(model, area: area).mapValues { $0.offsetBy(dx: origin.x, dy: origin.y) }
        model.documentFrame = CGRect(origin: origin, size: area)
        model.pageTops = frames.mapValues(\.minY)
        var highlights: [String: CGRect] = [:]
        for (paper, place) in model.notes {
            let spot = model.spot(paper, place)
            guard let index = spot.page, let frame = frames[index], let b = spot.bounds else { continue }
            let scale = frame.width / 612
            highlights[paper.key] = CGRect(x: frame.minX + b.minX * scale, y: frame.minY + (792 - b.maxY) * scale, width: b.width * scale, height: b.height * scale)
        }
        model.highlights = highlights
        model.highlightLines = highlights.mapValues { [$0] }
    }

    /// A made-up page of a report: a heading and lines of grey "text", with the passages the notes are on in dark.
    static func samplePage(_ index: Int) -> NSImage {
        NSImage(size: NSSize(width: 1224, height: 1584), flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            let scale: CGFloat = 2
            let ink = NSColor(white: 0.12, alpha: 1)
            let title = index == 0 ? "Field guide" : "Part \(index + 1)"
            (title as NSString).draw(at: NSPoint(x: 72 * scale, y: 72 * scale), withAttributes: [.font: NSFont.systemFont(ofSize: 22 * scale, weight: .bold), .foregroundColor: ink])
            var y: CGFloat = 130
            var row = 0
            while y < 740 {
                if index == 0, y >= 216, y < 236 {
                    ("Growth held steady through the second half" as NSString).draw(at: NSPoint(x: 72 * scale, y: 218 * scale), withAttributes: [.font: NSFont.systemFont(ofSize: 11 * scale), .foregroundColor: ink])
                } else if index == 0, y >= 396, y < 416 {
                    ("Three changes made the difference" as NSString).draw(at: NSPoint(x: 72 * scale, y: 398 * scale), withAttributes: [.font: NSFont.systemFont(ofSize: 11 * scale), .foregroundColor: ink])
                } else {
                    NSColor(white: 0.9, alpha: 1).setFill()
                    let width: CGFloat = row % 5 == 4 ? 260 : 468 - CGFloat((row * 37) % 60)
                    NSBezierPath(roundedRect: NSRect(x: 72 * scale, y: (y + 4) * scale, width: width * scale, height: 7 * scale), xRadius: 6, yRadius: 6).fill()
                }
                y += row % 6 == 5 ? 30 : 18
                row += 1
            }
            return true
        }
    }

    /// A made-up slide: a title, a line under it and a bar chart in the Mac's accent color.
    static func sampleSlide(_ index: Int, title: String? = nil, dark: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: 1280, height: 720), flipped: true) { rect in
            (dark ? NSColor(white: 0.07, alpha: 1) : NSColor.white).setFill()
            rect.fill()
            let ink = dark ? NSColor.white : NSColor(white: 0.07, alpha: 1)
            let titles = ["Quarterly plan", "Where we are", "Plan: faster everywhere", "What we heard", "The numbers", "Next quarter", "Screens", "Team", "Thank you"]
            ((title ?? titles[index % titles.count]) as NSString).draw(at: NSPoint(x: 80, y: 68), withAttributes: [.font: NSFont.systemFont(ofSize: 52, weight: .bold), .foregroundColor: ink])
            ("Slide \(index + 1)" as NSString).draw(at: NSPoint(x: 80, y: 140), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor(white: 0.45, alpha: 1)])
            for bar in 0..<5 {
                (bar < 3 ? NSColor.controlAccentColor : NSColor(srgbRed: 0.79, green: 0.79, blue: 0.81, alpha: 1)).setFill()
                let height = CGFloat(120 + bar * 80 + (index * 23) % 40)
                NSBezierPath(roundedRect: NSRect(x: 100 + CGFloat(bar) * 200, y: 640 - height, width: 120, height: height), xRadius: 8, yRadius: 8).fill()
            }
            return true
        }
    }
}

/// `Petal --viewer-check <file>… [--out <folder>]`: the viewer's loading as the window does it, without showing
/// anything: each file checked (ViewerPath), read off the main thread, its pages exported through Quick Look where
/// it isn't a PDF, and for a PDF its notes written as comments into a copy beside it (made-up notes). Then, on
/// throwaway copies in a folder of its own: a comment write refused when the PDF changed under it (into a copy and
/// into the original) and when its asker hung up; a Quick Look export cleaned up when its result is dropped; a
/// preview with a remote picture loading nothing from the network (and, without the rule list, a request seen, so
/// the check means something); and an off-screen viewer window (a selection, a passage found again by its words
/// whatever coordinates it was saved with, its highlight on them, its paper lined up, the margin and pages in step).
/// Run it on throwaway files only: it writes beside a PDF it's given.
@MainActor
enum ViewerCheck {
    static func run(_ arguments: [String]) {
        Headless.on = true
        VaultStore.standIn([])
        // The throwaway files (the samples, the checks' own folders) stand outside the real home folder: one folder
        // above both stands in for it (the path rule's own checks point it at their folders).
        ViewerPath.home = "/private"
        var files: [String] = []
        var out: String?
        var words = arguments.drop { $0 != "--viewer-check" }.dropFirst().makeIterator()
        while let word = words.next() {
            if word == "--out" { out = words.next() } else { files.append(word) }
        }
        var failed = false
        for file in files {
            var done = false
            check(file, out: out) { ok in
                failed = failed || !ok
                done = true
            }
            wait(90) { done }
            if !done { print("\(file): timed out"); failed = true }
        }
        if let pdf = files.first(where: { ViewerKind.of($0) == .pdf }), case .success(let url) = ViewerPath.check(pdf) {
            let app = PetalApp()
            failed = !writes(url) || failed
            failed = !places(url, app: app) || failed
            failed = !opening(url, app: app) || failed
            failed = !answers(url, app: app) || failed
            failed = !versions(url, app: app) || failed
            failed = !sixth(url, app: app) || failed
            failed = !seventh(url, app: app) || failed
            failed = !eighth(url, app: app) || failed
            failed = !ninth(url, app: app) || failed
            failed = !tenth(url, app: app) || failed
            failed = !eleventh(url, app: app) || failed
            failed = !twelfth(url, app: app) || failed
            failed = !thirteenth(url, app: app) || failed
            failed = !fourteenth(url, app: app) || failed
            failed = !window(url, app: app) || failed
        }
        if let deck = files.first(where: { ViewerKind.of($0) == .quickLook(.slide) }), case .success(let url) = ViewerPath.check(deck) {
            failed = !cleanup(url) || failed
        }
        failed = !remote() || failed
        exit(failed ? 1 : 0)
    }

    private static func wait(_ seconds: Double, until done: () -> Bool) {
        let until = Date().addingTimeInterval(seconds)
        while !done() && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private static func check(_ file: String, out: String?, _ done: @escaping @MainActor (Bool) -> Void) {
        let checked = ViewerPath.check(file)
        guard case .success(let url) = checked else {
            if case .failure(let refusal) = checked { print("\(file): refused: \(refusal.description)") }
            return done(false)
        }
        let kind = ViewerKind.of(url.path) ?? .quickLook(.page)
        Viewers.queue.async {
            let read = ViewerLoader.read(url, kind: kind)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let report = { (data: Data?, how: String) in
                        guard read.bookmark != nil else { print("\(url.lastPathComponent): FAIL no bookmark made with the read"); return done(false) }
                        guard let data, let document = PDFDocument(data: data) else {
                            print("\(url.lastPathComponent): \(how), no pages (shown through Quick Look's own view); opens in \(read.appName)")
                            return done(how == "live")
                        }
                        let text = (document.page(at: 0)?.string ?? "").replacingOccurrences(of: "\n", with: " ").prefix(60)
                        print("\(url.lastPathComponent): \(how), \(document.pageCount) \(kind.unit.word)s, first: “\(text)”; opens in \(read.appName.isEmpty ? "—" : read.appName)")
                        if let out {
                            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
                            try? data.write(to: URL(fileURLWithPath: out).appending(path: url.lastPathComponent + ".pages.pdf"))
                        }
                        guard kind == .pdf else { return done(true) }
                        // Comments into a copy beside it: a made-up note on page 1's first words (found by them), one on
                        // the file.
                        ViewerPDFComments.write(url, comments: comments(url, document), intoOriginal: false, author: "Petal check") { outcome in
                            switch outcome {
                            case .wrote(let copy, let count):
                                let annotations = PDFDocument(url: copy).map { doc in (0..<doc.pageCount).reduce(0) { $0 + (doc.page(at: $1)?.annotations.count ?? 0) } } ?? 0
                                let highlights = PDFDocument(url: copy)?.page(at: 0)?.annotations.filter { $0.type == "Highlight" }.count ?? 0
                                print("  comments: \(count) notes into \(copy.lastPathComponent) (\(annotations) annotations, \(highlights) highlight on its words)")
                                try? FileManager.default.removeItem(at: copy)
                                done(count == 2 && annotations == 3 && highlights == 1)
                            case .failed(let text):
                                print("  comments failed: \(text)")
                                done(false)
                            }
                        }
                    }
                    switch read.pages {
                    case .pdf(let data): report(data, kind == .pdf ? "PDF" : "Quick Look's PDF")
                    case .web(let preview): ViewerWeb.pages(preview) { report($0, preview.slides ? "Quick Look's slides" : "Quick Look's pages") }
                    case .live: report(nil, "live")
                    case .failed(let text): print("\(url.lastPathComponent): \(text)"); done(false)
                    }
                }
            }
        }
    }

    /// Made-up notes on a PDF: one on page 1's first words (with coordinates that are wrong on purpose: the passage
    /// is found by its words), one on the file.
    private static func comments(_ url: URL, _ document: PDFDocument) -> [ViewerPDFComments.Comment] {
        let text = document.page(at: 0)?.string ?? ""
        var passage = NoteStick(kind: .file)
        passage.path = url.path
        passage.page = 1
        passage.bounds = [1, 1, 5, 5]
        passage.quote = String(text.prefix(15))
        passage.after = String(text.dropFirst(15).prefix(20))
        var whole = NoteStick(kind: .file)
        whole.path = url.path
        return [ViewerPDFComments.Comment(stick: passage, body: "A made-up note on a passage", color: PaperLook.rgb(.systemBlue)),
                ViewerPDFComments.Comment(stick: whole, body: "A made-up note on the file", color: PaperLook.rgb(.systemGreen))]
    }

    /// A folder of the check's own, removed when it's done.
    private static func scratch() -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "petal-viewer-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Comment writes land only on the PDF they were made from, and only while their asker is there.
    private static func writes(_ source: URL) -> Bool {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appending(path: "Report.pdf")
        try? FileManager.default.copyItem(at: source, to: pdf)
        guard let document = PDFDocument(url: pdf) else { return false }
        let notes = comments(pdf, document)
        var ok = true
        func expect(_ condition: Bool, _ what: String) { if !condition { print("writes: FAIL \(what)"); ok = false } }
        func run(original: Bool, expected: ViewerFileID? = nil, live: @escaping @Sendable () -> Bool = { true }, meanwhile: (@Sendable () -> Void)? = nil,
                 afterRead: (@Sendable () -> Void)? = nil, lastMoment: (@Sendable () -> Void)? = nil) -> ViewerPDFComments.Outcome? {
            var outcome: ViewerPDFComments.Outcome?
            ViewerPDFComments.write(pdf, comments: notes, intoOriginal: original, author: "Petal check", expected: expected, live: live, meanwhile: meanwhile,
                                    afterRead: afterRead, lastMoment: lastMoment) { outcome = $0 }
            wait(20) { outcome != nil }
            return outcome
        }
        let names = { Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []) }
        // The PDF changed after it was read: refused, and the change kept.
        let edit: @Sendable () -> Void = {
            guard let handle = try? FileHandle(forWritingTo: pdf) else { return }
            handle.seekToEndOfFile()
            handle.write(Data("\n% an edit made meanwhile\n".utf8))
            try? handle.close()
        }
        expect(run(original: false, meanwhile: edit) == .failed(ViewerPDFComments.changed) && names() == ["Report.pdf"], "a copy refused on a changed base")
        let edited = try? Data(contentsOf: pdf)
        expect(run(original: true, meanwhile: edit) == .failed(ViewerPDFComments.changed), "the original refused on a changed base")
        expect((try? Data(contentsOf: pdf)) != edited && (try? Data(contentsOf: pdf))?.count ?? 0 > edited?.count ?? 0 && names() == ["Report.pdf"],
               "the newer edits kept, nothing written over them")
        // Its asker gone (before or while it worked): nothing written.
        expect(run(original: true, live: { false }) == .failed(ViewerPDFComments.hungUp) && names() == ["Report.pdf"], "a hung-up request writes nothing")
        let flag = HangUp()
        expect(run(original: true, live: { !flag.gone }, meanwhile: { flag.gone = true }) == .failed(ViewerPDFComments.hungUp) && names() == ["Report.pdf"],
               "hung up mid-way: nothing written")
        // Hung up at the last moment: after the PDF was read again and checked (and, into the original, its backup
        // made), right before the change: still nothing written, the backup Petal made gone.
        let unchanged = try? Data(contentsOf: pdf)
        let late = HangUp()
        expect(run(original: true, live: { !late.gone }, lastMoment: { late.gone = true }) == .failed(ViewerPDFComments.hungUp)
               && names() == ["Report.pdf"] && (try? Data(contentsOf: pdf)) == unchanged, "hung up after the backup: the PDF as it was, no backup left")
        let later = HangUp()
        expect(run(original: false, live: { !later.gone }, lastMoment: { later.gone = true }) == .failed(ViewerPDFComments.hungUp) && names() == ["Report.pdf"],
               "hung up after the check: no copy made")
        // Hung up during the final read itself: asked right after it, before any backup is made.
        let reading = HangUp()
        let reached = HangUp()
        expect(run(original: true, live: { !reading.gone }, afterRead: { reading.gone = true }, lastMoment: { reached.gone = true }) == .failed(ViewerPDFComments.hungUp)
               && !reached.gone && names() == ["Report.pdf"], "hung up during the final read: no backup ever made")
        // Allowed for one file, and another took its place since (the very same bytes): nothing written.
        let allowed = ViewerFileID.of(pdf.path)
        let same = try? Data(contentsOf: pdf)
        let swapped = folder.appending(path: "swap.tmp")
        try? same?.write(to: swapped)
        _ = try? FileManager.default.replaceItemAt(pdf, withItemAt: swapped)
        expect(allowed != nil && ViewerFileID.of(pdf.path) != allowed && (try? Data(contentsOf: pdf)) == same, "a replacement with the same bytes (set up)")
        expect(run(original: true, expected: allowed) == .failed(ViewerPDFComments.changed) && names() == ["Report.pdf"],
               "the PDF allowed was replaced since: the replacement isn't written")
        // Unchanged: into the original, the original kept beside it.
        let before = try? Data(contentsOf: pdf)
        if case .wrote(_, let count)? = run(original: true) {
            expect(count == 2 && names() == ["Report.pdf", "Report (before notes).pdf"], "written into the original")
            expect((try? Data(contentsOf: folder.appending(path: "Report (before notes).pdf"))) == before, "the original kept as it was")
        } else { expect(false, "written into the original") }
        print("writes: " + (ok ? "refused on a changed PDF or a hung-up asker, the original kept when written into" : "failed"))
        return ok
    }

    final class HangUp: @unchecked Sendable { var gone = false }

    /// The ninth review: a version's copy swapped for a link isn't read ("can't be shown"); a refused save keeps the
    /// pastes still being read for its note, and undo retiring its snapshot keeps them too.
    private static func ninth(_ source: URL, app: PetalApp) -> Bool {
        var ok = true
        func expect(_ condition: Bool, _ what: String) { if !condition { print("ninth: FAIL \(what)"); ok = false } }
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appending(path: "Home")
        let outside = folder.appending(path: "Outside")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let kept = ViewerPath.home
        ViewerPath.home = home.path
        defer { ViewerPath.home = kept }
        let a = home.appending(path: "Deck.pdf")
        try? FileManager.default.copyItem(at: source, to: a)
        try? FileManager.default.copyItem(at: source, to: outside.appending(path: "Private.pdf"))
        let model = ViewerModel(url: URL(fileURLWithPath: ViewerPath.canonical(a.path) ?? a.path), kind: .pdf)
        model.load()
        wait(20) { !model.loading }
        var made: ViewerVersionSet?
        model.makeVersions(["One", "Two"], asker: "check") { if case .success(let set) = $0 { made = set } }
        wait(20) { made != nil }
        wait(20) { made?.versions.allSatisfy { $0.thumb != nil } == true }
        guard let set = made else { expect(false, "versions made (set up)"); return false }
        expect(set.versions.allSatisfy { $0.thumb != nil && !$0.refused }, "Petal's own copies are read")
        let swapped = set.versions[0].url
        try? FileManager.default.removeItem(at: swapped)
        try? FileManager.default.createSymbolicLink(atPath: swapped.path, withDestinationPath: outside.appending(path: "Private.pdf").path)
        model.refreshVersions(set)
        wait(10) { set.versions[0].refused }
        expect(set.versions[0].refused && set.versions[0].thumb == nil && !set.versions[1].refused, "a copy swapped for a link: can't be shown, nothing of it read")
        try? FileManager.default.removeItem(at: set.folder)
        model.close()

        // A refused save's snapshot keeps the pastes still being read; retiring it keeps them too.
        let loading = [NoteJournal.Import(token: 7, path: "/Users/someone/Desktop/Shot.png", ext: "png")]
        let entry = NoteStore.unsavedEntry(noteID: "P1", path: "/n/Inbox/P.md", base: "---\nid: P1\n---\nBefore", text: "---\nid: P1\n---\nBefore, typed",
                                           pending: [:], loading: loading)
        expect(entry.imports == loading, "a refused save keeps the pastes still being read for its note")
        let journal = folder.appending(path: "journal")
        NoteJournal.snapshot(entry, in: journal)
        NoteJournal.retire(noteID: "P1", current: "---\nid: P1\n---\nBefore", in: journal)
        let after = NoteJournal.read(NoteJournal.file("P1", in: journal))
        expect(after?.imports == loading && after?.text == "---\nid: P1\n---\nBefore", "undone: the typing goes, the pastes' recovery stays")
        print("ninth: " + (ok ? "a version's copy swapped for a link isn't read; refused saves and undo keep pending pastes" : "failed"))
        return ok
    }

    /// A PDF of `count` pages copied from `source`'s first page (a version's copy edited by an agent, say).
    private static func pages(_ count: Int, from source: URL) -> Data? {
        guard let document = PDFDocument(url: source), let page = document.page(at: 0) else { return nil }
        let out = PDFDocument()
        for index in 0..<count { if let copy = page.copy() as? PDFPage { out.insert(copy, at: index) } }
        return withExtendedLifetime(document) { out.dataRepresentation() }
    }

    /// A one-page PDF with two lines of text drawn as text (CoreText), so PDFKit finds its words and lines.
    private static func twoLines(_ first: String, _ second: String, to url: URL) -> Bool {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for (line, y) in [(first, 700.0), (second, 680.0)] {
            let text = NSAttributedString(string: line, attributes: [.font: font])
            context.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        context.endPDFPage()
        context.closePDF()
        return true
    }

    /// The tenth review: versions read through their set's pinned folder (swapped for a link: refused); a version's
    /// preview keeps following edits after an atomic replace; a passage over two lines is highlighted line by line,
    /// in the viewer and in the comments written, never one box over the words either side.
    private static func tenth(_ source: URL, app: PetalApp) -> Bool {
        var ok = true
        func expect(_ condition: Bool, _ what: String) { if !condition { print("tenth: FAIL \(what)"); ok = false } }
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appending(path: "Home")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let kept = ViewerPath.home
        ViewerPath.home = home.path
        defer { ViewerPath.home = kept }
        let deck = home.appending(path: "Deck.pdf")
        try? FileManager.default.copyItem(at: source, to: deck)
        let start = PDFDocument(url: source)?.pageCount ?? 1

        // Edits after an atomic replace still refresh the preview.
        let model = ViewerModel(url: URL(fileURLWithPath: ViewerPath.canonical(deck.path) ?? deck.path), kind: .pdf)
        model.load()
        wait(20) { !model.loading }
        var made: ViewerVersionSet?
        model.makeVersions(["One", "Two"], asker: "check") { if case .success(let set) = $0 { made = set } }
        wait(20) { made != nil }
        guard let set = made else { expect(false, "versions made (set up)"); return false }
        let one = set.versions[0]
        wait(20) { model.versionPageCount(one.id) == start }
        expect(model.versionPageCount(one.id) == start, "a copy's preview read (set up)")
        let temp = set.folder.appending(path: ".saving")
        try? pages(start + 1, from: source)?.write(to: temp)
        _ = rename(temp.path, one.url.path)
        wait(10) { model.versionPageCount(one.id) == start + 1 }
        expect(model.versionPageCount(one.id) == start + 1, "an atomic replace refreshes the preview")
        if let handle = try? FileHandle(forWritingTo: one.url), let data = pages(start + 2, from: source) {
            try? handle.truncate(atOffset: 0)
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
        wait(10) { model.versionPageCount(one.id) == start + 2 }
        expect(model.versionPageCount(one.id) == start + 2, "an edit in place after the atomic replace refreshes it too")
        try? pages(start + 3, from: source)?.write(to: temp)
        _ = rename(temp.path, one.url.path)
        wait(10) { model.versionPageCount(one.id) == start + 3 }
        expect(model.versionPageCount(one.id) == start + 3, "and a second atomic replace")

        // The set's folder swapped for a link to a folder holding files of the same names: refused through the pin.
        let decoy = folder.appending(path: "Decoy")
        try? FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        for version in set.versions { try? FileManager.default.copyItem(at: source, to: decoy.appending(path: version.url.lastPathComponent)) }
        let moved = folder.appending(path: "Moved set")
        try? FileManager.default.moveItem(at: set.folder, to: moved)
        try? FileManager.default.createSymbolicLink(atPath: set.folder.path, withDestinationPath: decoy.path)
        model.refreshVersions(set)
        wait(10) { set.versions.allSatisfy(\.refused) }
        expect(set.versions.allSatisfy { $0.refused && $0.thumb == nil }, "the set's folder swapped for a link: every copy refused through the pinned descriptor")
        try? FileManager.default.removeItem(at: set.folder)
        try? FileManager.default.removeItem(at: moved)
        model.close()

        // A passage over two lines: one rectangle per line, in the viewer and as the comment's quadrilaterals.
        let lines = home.appending(path: "Lines.pdf")
        guard twoLines("Alpha beta gamma delta", "epsilon zeta eta theta", to: lines), let document = PDFDocument(url: lines),
              let page = document.page(at: 0), let text = page.string else { expect(false, "a two-line PDF (set up)"); return false }
        let ns = text as NSString
        let quoteRange = NSRange(location: ns.range(of: "gamma").location, length: NSMaxRange(ns.range(of: "zeta")) - ns.range(of: "gamma").location)
        let quote = ns.substring(with: quoteRange)
        let unselected = ["Alpha beta", "eta theta"].compactMap { word -> CGRect? in
            let range = ns.range(of: word, options: .backwards)
            return range.location == NSNotFound ? nil : page.selection(for: range)?.bounds(for: page)
        }
        expect(unselected.count == 2, "the words either side found (set up)")
        let viewerLines = ViewerModel.lines(page, quoteRange) ?? []
        let union = ViewerComments.union(viewerLines) ?? .zero
        expect(viewerLines.count == 2, "the viewer's highlight: two lines, one rectangle each")
        expect(!viewerLines.contains { line in unselected.contains { $0.insetBy(dx: 1, dy: 1).intersects(line) } } && unselected.contains { union.intersects($0) },
               "the viewer's lines miss the unselected words their union would cover")
        var stick = NoteStick(kind: .file)
        stick.path = lines.path
        stick.page = 1
        stick.quote = quote
        stick.before = ns.substring(to: quoteRange.location)
        stick.after = ns.substring(from: NSMaxRange(quoteRange))
        var outcome: ViewerPDFComments.Outcome?
        ViewerPDFComments.write(lines, comments: [.init(stick: stick, body: "Two lines", color: NoteInk.RGB(r: 0.9, g: 0.7, b: 0.2))], intoOriginal: false,
                                author: "Petal check", expected: nil, live: { true }) { outcome = $0 }
        wait(20) { outcome != nil }
        guard case .wrote(let written, _)? = outcome, let back = PDFDocument(url: written)?.page(at: 0),
              let mark = back.annotations.first(where: { $0.type == "Highlight" }) else { expect(false, "the comment written as a highlight"); return false }
        let points = (mark.quadrilateralPoints ?? []).map(\.pointValue)
        // PDFKit gives them relative to the annotation's bounds.
        let quads = stride(from: 0, to: points.count - points.count % 4, by: 4).map { i -> CGRect in
            let xs = points[i..<i + 4].map { $0.x + mark.bounds.minX }, ys = points[i..<i + 4].map { $0.y + mark.bounds.minY }
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        expect(quads.count == 2, "exported: two quadrilaterals (\(quads.count))")
        expect(!quads.contains { quad in unselected.contains { $0.insetBy(dx: 1, dy: 1).intersects(quad) } },
               "exported quadrilaterals don't cover the unselected words")
        expect(zip(quads, viewerLines).allSatisfy { abs($0.midY - $1.midY) < 2 && abs($0.minX - $1.minX) < 2 }, "each quadrilateral is its line")
        print("tenth: " + (ok ? "versions read through their pinned folder and followed after a replace; two-line passages marked line by line" : "failed"))
        return ok
    }

    /// The eleventh review: only the newest set of versions per viewer (one it replaces told, its pictures dropped and
    /// its copies removed, all but a picked one, which goes when the viewer closes); a request that hangs up before
    /// its file is checked opens nothing.
    private static func eleventh(_ source: URL, app: PetalApp) -> Bool {
        var ok = true
        func expect(_ condition: Bool, _ what: String) { if !condition { print("eleventh: FAIL \(what)"); ok = false } }
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appending(path: "Home")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let kept = ViewerPath.home
        ViewerPath.home = home.path
        defer { ViewerPath.home = kept }
        let deck = home.appending(path: "Deck.pdf")
        try? FileManager.default.copyItem(at: source, to: deck)
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }

        let model = ViewerModel(url: URL(fileURLWithPath: ViewerPath.canonical(deck.path) ?? deck.path), kind: .pdf)
        model.load()
        wait(20) { !model.loading }
        func make(_ labels: [String]) -> ViewerVersionSet? {
            var made: ViewerVersionSet?
            model.makeVersions(labels, asker: "check") { if case .success(let set) = $0 { made = set } }
            wait(20) { made != nil }
            wait(20) { made?.versions.allSatisfy { $0.thumb != nil } == true }
            return made
        }
        guard let first = make(["One", "Two"]) else { expect(false, "versions made (set up)"); return false }
        var told = false
        var toldWith: ViewerVersion?? = .none
        first.whenPicked { told = true; toldWith = .some($0) }
        guard let second = make(["Three", "Four"]) else { expect(false, "newer versions made (set up)"); return false }
        wait(5) { exists(first.folder) == false }
        expect(model.versions === second && app.viewers.versionSets[first.id] == nil && app.viewers.versionSets[second.id] === second,
               "only the newest set is kept; the one it replaced is forgotten")
        expect(told && toldWith == .some(nil), "whoever waited on the replaced set's pick is told: none")
        expect(first.versions.allSatisfy { $0.thumb == nil }, "the replaced set's pictures dropped at once")
        expect(!exists(first.folder), "the replaced set's copies removed (no pick pending)")
        // Picked, then replaced: only the picked copy stays (its asker may still read it), until the viewer closes.
        let picked = second.versions[1]
        model.use(picked)
        guard let third = make(["Five"]) else { expect(false, "a third set (set up)"); return false }
        wait(5) { ((try? FileManager.default.contentsOfDirectory(atPath: second.folder.path)) ?? []).count == 1 }
        expect(app.viewers.versionSets[second.id] === second && second.versions.map(\.id) == [picked.id] && second.versions.allSatisfy { $0.thumb == nil },
               "a replaced set with a pick: kept for its asker with only the picked version, pictures dropped")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: second.folder.path)) ?? []
        expect(left == [picked.url.lastPathComponent], "its other copies removed, the picked one kept (\(left))")
        // The viewer closes: every set's copies go, picked or not.
        model.close()
        wait(5) { !exists(second.folder) && !exists(third.folder) }
        expect(!exists(second.folder) && !exists(third.folder), "the viewer closed: every set's copies removed")
        expect(app.viewers.versionSets[second.id] == nil && app.viewers.versionSets[third.id] == nil, "and forgotten")

        // A cancelled request opens nothing: hung up before it's asked, or while its file is being checked.
        let shown = { app.viewers.open.contains { $0.url.lastPathComponent == "Deck.pdf" } }
        var answered = false
        app.viewers.open(path: deck.path, live: { false }) { _ in answered = true }
        wait(2) { answered || shown() }
        expect(!answered && !shown(), "a request already gone: nothing opened")
        let gone = HangUp()
        app.viewers.open(path: deck.path, live: { !gone.gone }) { _ in answered = true }
        gone.gone = true
        wait(3) { answered || shown() }
        expect(!answered && !shown(), "hung up while its file was checked: no window")
        var opened: ViewerModel?
        app.viewers.open(path: deck.path, live: { true }) { if case .success(let model) = $0 { opened = model } }
        wait(5) { opened != nil }
        expect(opened != nil && shown(), "still there: it opens")
        for model in app.viewers.open where model.url.lastPathComponent == "Deck.pdf" { app.viewers.closed(model) }
        print("eleventh: " + (ok ? "only the newest versions kept (a picked copy until the viewer closes, all gone then); a cancelled open shows nothing" : "failed"))
        return ok
    }

    /// The twelfth review: a corrupt PDF reports its error to whoever waited for the load (never a success with 0
    /// pages); Petal's viewer with the keyboard is the desk's current place: "here" lists its margin notes,
    /// `stick: "here"` attaches to its file and page, and ⌃⌥N makes a note in its margin.
    private static func twelfth(_ source: URL, app: PetalApp) -> Bool {
        var ok = true
        func expect(_ condition: Bool, _ what: String) { if !condition { print("twelfth: FAIL \(what)"); ok = false } }
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appending(path: "Home")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let kept = ViewerPath.home
        ViewerPath.home = home.path
        defer { ViewerPath.home = kept }
        let canonical = { (url: URL) in URL(fileURLWithPath: ViewerPath.canonical(url.path) ?? url.path) }

        // A corrupt PDF: its error is there when the load is answered.
        let broken = home.appending(path: "Broken.pdf")
        try? Data("%PDF-1.4\nnot a PDF at all".utf8).write(to: broken)
        let bad = app.viewers.show(canonical(broken), front: false)
        var answer: (problem: String?, told: [String: Any])?
        bad.whenLoaded(within: 20) { _ in answer = (bad.problem, app.viewers.told(bad)) }
        wait(20) { answer != nil }
        expect(answer?.problem == "Petal can't read this PDF." && answer?.told["note"] as? String == "Petal can't read this PDF."
               && answer?.told["pages"] == nil && answer?.told["loading"] == nil, "a corrupt PDF: its error told, never 0 pages (\(String(describing: answer?.told)))")
        app.viewers.closed(bad)

        // The viewer with the keyboard is "here".
        let guide = home.appending(path: "Guide.pdf")
        try? FileManager.default.copyItem(at: source, to: guide)
        let model = app.viewers.show(canonical(guide), front: false)
        wait(20) { !model.loading }
        model.go(to: 1)
        app.viewers.keyID = model.id
        defer { app.viewers.keyID = nil }
        // ⌃⌥N: a note on its page, open in its margin.
        app.paper.newHere()
        wait(10) { model.openKey != nil }
        guard let key = model.openKey, let made = app.paper.store.paper(key), let place = made.file.places.first else {
            expect(false, "⌃⌥N in the viewer makes a margin note"); app.viewers.closed(model); return false
        }
        expect(place.kind == .file && place.path == model.url.path && place.page == 2 && !place.fileID.isEmpty && !place.bookmark.isEmpty,
               "⌃⌥N in the viewer: a note on its file (with its incarnation) and page")
        model.refreshPlaces()
        wait(5) { model.shows(key) }
        expect(model.shows(key) && model.face == .open, "and it opens in the viewer's margin")
        func notesHere() -> [String: Any]? {
            var listed: [String: Any]?
            var refused: String?
            app.paper.handle("petal_notes", ["here": true], live: { true }, { listed = $0 as? [String: Any] }, { refused = $0 })
            wait(10) { listed != nil || refused != nil }
            if let refused { print("twelfth: petal_notes refused: \(refused)") }
            return listed
        }
        let listed = notesHere()
        expect((listed?["count"] as? Int) == 1 && ((listed?["notes"] as? [[String: Any]])?.first?["onScreen"] as? Bool) == true,
               "petal_notes here: the viewer's margin note, on screen (\(String(describing: listed?["count"])))")
        app.viewers.keyID = nil
        expect((notesHere()?["count"] as? Int) == 0, "the viewer without the keyboard: not here")
        app.viewers.keyID = model.id
        // stick: "here" from an agent: attached to the file and page.
        var wrote: Any?
        var refused: String?
        app.paper.handle("petal_note_write", ["text": "Stuck from the viewer twelve", "stick": "here"], live: { true }, { wrote = $0 }, { refused = $0 })
        wait(20) { wrote != nil || refused != nil }
        wait(5) { app.paper.store.notes.contains { $0.file.body == "Stuck from the viewer twelve" } }
        let stuck = app.paper.store.notes.first { $0.file.body == "Stuck from the viewer twelve" }?.file.places.first
        expect(refused == nil && stuck?.kind == .file && stuck?.path == model.url.path && stuck?.page == 2 && stuck?.fileID.isEmpty == false,
               "stick: \"here\" attaches to the viewer's file and page (\(refused ?? ""))")
        // Nothing stuck to a window or tab of Petal's own.
        var nowhere: Any?
        app.paper.handle("petal_note_write", ["text": "Not on a window twelve", "stick": "here", "to": "window"], live: { true }, { nowhere = $0 }, { nowhere = $0 })
        wait(20) { nowhere != nil }
        expect(app.paper.store.notes.first { $0.file.body == "Not on a window twelve" }?.file.places.isEmpty ?? true, "a window asked for in the viewer: stuck nowhere")
        // Not left empty for the Trash: the ⌃⌥N note keeps its file.
        app.paper.fresh.remove(key)
        app.viewers.closed(model)
        print("twelfth: " + (ok ? "a corrupt PDF reports its error; the viewer with the keyboard is here (listed, stuck to its file and page, ⌃⌥N in its margin)" : "failed"))
        return ok
    }

    /// The thirteenth review: the letterhead's "Stick it here" in Petal's viewer offers the viewer's own file and page,
    /// never the last document seen in another app; ⌃⌥N right after a selection waits for its passage (and its
    /// vault check); a place made for a selection that changed, or a viewer that closed, is never used.
    private static func thirteenth(_ source: URL, app: PetalApp) -> Bool {
        var ok = true
        func expect(_ condition: Bool, _ what: String) { if !condition { print("thirteenth: FAIL \(what)"); ok = false } }
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appending(path: "Home")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let kept = ViewerPath.home
        ViewerPath.home = home.path
        defer { ViewerPath.home = kept }
        let canonical = { (url: URL) in URL(fileURLWithPath: ViewerPath.canonical(url.path) ?? url.path) }
        let other = home.appending(path: "Document A.pdf")
        let shown = home.appending(path: "Document B.pdf")
        try? FileManager.default.copyItem(at: source, to: other)
        try? FileManager.default.copyItem(at: source, to: shown)
        let model = app.viewers.show(canonical(shown), front: false)
        wait(20) { !model.loading }
        app.viewers.keyID = model.id
        defer { app.viewers.keyID = nil }
        let notesNow = { app.paper.store.notes.count }

        // The letterhead's menu: B's own file and page, never A seen before in another app.
        var onA = NoteStick(kind: .file)
        onA.path = canonical(other).path
        app.paper.previewScene(NoteScene(mac: app.paper.local.mac, app: "com.apple.Preview", pid: 4242, window: 77, title: "Document A.pdf", file: canonical(other).path))
        var first = NoteStick(kind: .file)
        first.path = model.url.path
        first.page = 1
        guard let paper = app.paper.make(on: first, body: "On B", open: false) else { expect(false, "a note on B (set up)"); return false }
        model.go(to: 1)
        let offers = app.paper.stickOffers(paper.key)
        expect(offers.count == 1 && offers[0].kind == .file && offers[0].path == model.url.path && offers[0].page == 2 && !offers[0].fileID.isEmpty,
               "the viewer with the keyboard: Stick it here offers its own file and page (\(offers.map { "\($0.kind) \($0.path) \($0.spot)" }))")
        expect(!offers.contains { $0.path == onA.path || $0.kind == .window || $0.kind == .app }, "never the document, window or app seen before in another app")
        app.viewers.keyID = nil
        expect(app.paper.stickOffers(paper.key).contains { $0.path == onA.path }, "without the viewer in front: what the last look found")
        app.viewers.keyID = model.id
        model.go(to: 0)

        // ⌃⌥N straight after selecting: waits for the passage, never a page note.
        let pageText = PDFDocument(url: canonical(shown))?.page(at: 0)?.string ?? ""
        let word = (pageText as NSString).range(of: "sample")
        guard word.location != NSNotFound else { expect(false, "a word to select (set up)"); return false }
        model.selected(page: 0, bounds: CGRect(x: 72, y: 700, width: 60, height: 14), range: word, anchor: .zero)
        expect(model.selectionPending, "a selection being read is pending, not none")
        app.paper.newHere()
        wait(10) { model.openKey != nil }
        let made = model.openKey.flatMap { app.paper.store.paper($0) }
        expect(made?.file.places.first?.quote == "sample", "⌃⌥N right after selecting: a note on the passage, its words checked (\(made?.file.places.first?.quote ?? "none"))")
        if let made {
            app.paper.fresh.remove(made.key)
            model.close(made.key, .transfer)
        }

        // A selection replaced while its place was being made: nothing made.
        model.selected(page: 0, bounds: CGRect(x: 72, y: 700, width: 60, height: 14), range: word, anchor: .zero)
        wait(5) { model.selection != nil }
        var before = notesNow()
        model.newNote()
        model.unselected()
        wait(1.5) { false }
        expect(notesNow() == before, "the selection gone while its place was made: no note")
        // The viewer closed meanwhile: nothing made, nothing opened.
        model.selected(page: 0, bounds: CGRect(x: 72, y: 700, width: 60, height: 14), range: word, anchor: .zero)
        wait(5) { model.selection != nil }
        before = notesNow()
        model.newNote()
        app.viewers.closed(model)
        wait(1.5) { false }
        expect(notesNow() == before && model.openKey == nil, "the viewer closed while its place was made: no note")
        print("thirteenth: " + (ok ? "Stick it here from the viewer's own file and page; a pending selection waited for; a changed selection or closed viewer makes nothing" : "failed"))
        return ok
    }

    /// The fourteenth review: a file place is offered only with the document's checked identity (waited for while
    /// it loads, refused when it can't be shown); "also" never merges another file's anchor that took a path; a
    /// slow membership read finishing last never replaces the newest.
    private static func fourteenth(_ source: URL, app: PetalApp) -> Bool {
        var ok = true
        func expect(_ condition: Bool, _ what: String) { if !condition { print("fourteenth: FAIL \(what)"); ok = false } }
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appending(path: "Home")
        let outside = folder.appending(path: "Outside")
        for made in [home, outside] { try? FileManager.default.createDirectory(at: made, withIntermediateDirectories: true) }
        let kept = ViewerPath.home
        ViewerPath.home = home.path
        defer { ViewerPath.home = kept }
        let canonical = { (url: URL) in URL(fileURLWithPath: ViewerPath.canonical(url.path) ?? url.path) }

        // Asked while it loads: waited for, and the place carries the file's identity.
        let report = home.appending(path: "Report.pdf")
        try? FileManager.default.copyItem(at: source, to: report)
        let model = app.viewers.show(canonical(report), front: false)
        app.viewers.keyID = model.id
        defer { app.viewers.keyID = nil }
        expect(model.fileAnchor() == nil, "no file place before the document's identity is in")
        var early: ViewerModel.HereOutcome?
        model.herePlace(passage: false) { early = $0 }
        wait(20) { early != nil }
        if case .place(let stick, _)? = early {
            expect(!stick.fileID.isEmpty && !stick.bookmark.isEmpty, "asked while loading: waited for, the place has the file's identity and bookmark")
        } else { expect(false, "asked while loading: a place once it's in") }
        // A file the viewer refuses: no identity, no place.
        let away = outside.appending(path: "Away.pdf")
        try? FileManager.default.copyItem(at: source, to: away)
        let refused = app.viewers.show(canonical(away), front: false)
        var none: ViewerModel.HereOutcome?
        refused.herePlace(passage: false) { none = $0 }
        wait(20) { none != nil }
        if case .unidentified? = none {} else { expect(false, "a file that can't be shown: no place (\(String(describing: none)))") }
        expect(refused.fileAnchor() == nil, "and no file anchor to offer")
        app.viewers.closed(refused)

        // A note on A's page 1; A renamed, B takes its path, shown in the viewer: "also" keeps A and adds B.
        let a = home.appending(path: "Shared.pdf")
        try? FileManager.default.copyItem(at: source, to: a)
        let onA = app.viewers.show(canonical(a), front: false)
        wait(20) { !onA.loading }
        app.viewers.keyID = onA.id
        var anchorA: NoteStick?
        onA.herePlace(passage: false) { if case .place(let stick, _) = $0 { anchorA = stick } }
        wait(10) { anchorA != nil }
        app.viewers.closed(onA)
        guard let anchorA, let paper = app.paper.make(on: anchorA, body: "On A fourteen", open: false) else { expect(false, "a note on A (set up)"); return false }
        try? FileManager.default.moveItem(at: a, to: home.appending(path: "Shared renamed.pdf"))
        try? FileManager.default.copyItem(at: source, to: a)
        let onB = app.viewers.show(canonical(a), front: false)
        wait(20) { !onB.loading }
        app.viewers.keyID = onB.id
        var listed: [String: Any]?
        app.paper.handle("petal_notes", ["query": "On A fourteen"], live: { true }, { listed = $0 as? [String: Any] }, { _ in listed = [:] })
        wait(10) { listed != nil }
        let handle = (listed?["notes"] as? [[String: Any]])?.first?["id"] as? String ?? ""
        var stuck: Any?
        app.paper.handle("petal_note_stick", ["id": handle, "to": "file", "also": true], live: { true }, { stuck = $0 }, { stuck = $0 })
        wait(20) { stuck != nil }
        wait(5) { (app.paper.store.paper(paper.key)?.file.places.count ?? 0) == 2 }
        let places = app.paper.store.paper(paper.key)?.file.places ?? []
        expect(places.count == 2 && places[0].fileID == anchorA.fileID && places[1].fileID != anchorA.fileID && places[1].path == anchorA.path,
               "also: A's anchor kept, B's added at the same path and page (\(places.map(\.fileID)))")

        // Membership reads: the newest wins even when an older one finishes last.
        app.paper.store.preview(app.paper.store.notes.filter { $0.key != paper.key }, notebooks: app.paper.store.notebooks)
        let withB = app.paper.store.notes
        var onBNote = NoteStick(kind: .file)
        if let anchorB = places.last { onBNote = anchorB }
        let noteB = PaperNote(file: { var f = NoteFile(id: "F14", body: "On B fourteen"); f.places = [onBNote]; return f }(),
                              url: folder.appending(path: "F14.md"), notebook: "Inbox")
        app.paper.store.preview(withB + [noteB], notebooks: app.paper.store.notebooks)
        onB.refreshPlaces(late: 1.0)
        app.paper.store.preview(withB, notebooks: app.paper.store.notebooks)
        onB.refreshPlaces()
        wait(2.5) { false }
        expect(!onB.onFile.contains(onBNote.fileKey), "an older read finishing last never replaces the newest")
        app.viewers.closed(onB)
        app.viewers.closed(model)
        print("fourteenth: " + (ok ? "file places only with the file's identity; also keeps another file's anchor; the newest membership read wins" : "failed"))
        return ok
    }

    /// The eighth review: one path rule at every load and follow (a reload swapped to a link out of the home folder
    /// shows nothing); a refused save's snapshot is the whole note and comes back with its front matter; undoing the
    /// refused typing retires its snapshot.
    private static func eighth(_ source: URL, app: PetalApp) -> Bool {
        var ok = true
        func expect(_ condition: Bool, _ what: String) { if !condition { print("eighth: FAIL \(what)"); ok = false } }
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        // A file in the home folder, swapped for a link to one outside it: the reload refuses, nothing is shown.
        let home = folder.appending(path: "Home")
        let outside = folder.appending(path: "Outside")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let kept = ViewerPath.home
        ViewerPath.home = home.path
        defer { ViewerPath.home = kept }
        let a = home.appending(path: "A.pdf")
        try? FileManager.default.copyItem(at: source, to: a)
        try? FileManager.default.copyItem(at: source, to: outside.appending(path: "X.pdf"))
        let model = ViewerModel(url: URL(fileURLWithPath: ViewerPath.canonical(a.path) ?? a.path), kind: .pdf)
        model.load()
        wait(20) { !model.loading }
        expect(model.pageCount > 0 && model.problem == nil, "a file in the home folder shows (set up)")
        try? FileManager.default.removeItem(at: a)
        try? FileManager.default.createSymbolicLink(atPath: a.path, withDestinationPath: outside.appending(path: "X.pdf").path)
        model.fileChanged()
        wait(5) { model.problem != nil }
        expect(model.problem == ViewerModel.cantShowText && model.document == nil && model.pageCount == 0, "swapped for a link out of home: \"This file can't be shown\", nothing loaded")
        model.load()
        wait(5) { model.loading == false }
        expect(model.problem == ViewerModel.cantShowText && model.document == nil, "and a reload refuses it too")
        model.close()
        ViewerPath.home = kept

        // A refused save: the whole note in the journal (its front matter too), and back with it after recovery.
        let noteID = "R-\(UUID().uuidString.prefix(6))"
        var file = NoteFile(id: noteID, created: Date().addingTimeInterval(-3600), body: "Before")
        var stick = NoteStick(kind: .file)
        stick.path = source.path
        file.places = [stick]
        let paper = PaperNote(file: file, url: folder.appending(path: "Notes/Inbox/Full.md"), notebook: "Inbox")
        app.paper.store.preview([], notebooks: [])
        func editor() -> (NoteEditorView.Coordinator, NoteTextView) {
            let view = NoteEditorView(paper: paper, style: NoteRich.Style(ink: .black, dim: .gray, petal: .systemPink, accent: .systemBlue), focus: false,
                                      height: { _ in }, save: { app.paper.write(paper.key, noteID: noteID, instance: "", body: $0, base: $1) },
                                      register: { _ in }, importPictures: { _ in }, escape: {},
                                      settled: { app.paper.settleUnsaved(paper.key, noteID: noteID, instance: "", saved: $0) })
            let coordinator = view.makeCoordinator()
            coordinator.body = "Before"
            coordinator.base = file.serialized()
            return (coordinator, NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200)))
        }
        let journal = NoteJournal.file(noteID)
        let entry = { () -> NoteJournal.Entry? in
            var read: NoteJournal.Entry?
            NoteJournal.queue.sync { read = NoteJournal.read(journal) }
            return read
        }
        let (coordinator, text) = editor()
        text.string = "Before, typed"
        coordinator.flush(text)
        coordinator.marker.typed()
        coordinator.flush(text)
        let snapshot = entry().map { NoteFile.parse($0.text, fallbackID: "x", fallbackDate: Date()) }
        expect(snapshot?.id == noteID && snapshot?.places == file.places && snapshot?.body == "Before, typed", "refused: the whole note in the journal, front matter and all")
        let root = folder.appending(path: "Notes")
        try? FileManager.default.createDirectory(at: root.appending(path: "Inbox"), withIntermediateDirectories: true)
        let holding = folder.appending(path: "recovering")
        try? FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
        NoteJournal.queue.sync { try? FileManager.default.copyItem(at: journal, to: holding.appending(path: journal.lastPathComponent)) }
        NoteJournal.recover(holding, root: root)
        let recovered = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "md" }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { NoteFile.parse($0, fallbackID: "x", fallbackDate: Date()) }
        expect(recovered.contains { $0.id == noteID && $0.places == file.places && $0.body == "Before, typed" }, "put back with its front matter (its id and places)")

        // Undone back to what's saved: the refused typing's snapshot is retired.
        text.string = "Before"
        coordinator.marker.typed()
        coordinator.flush(text)
        expect(entry() == nil && !coordinator.marker.dirty, "undone to what's saved: its snapshot retired")
        print("eighth: " + (ok ? "one path rule at every load and follow, a refused save journaled whole and recovered with its front matter, an undo retiring it" : "failed"))
        return ok
    }

    /// The seventh review: refused typing in the journal at once and after a close or a quit (an editor dirty with no
    /// save waiting still hands its text over), put back by the next launch's recovery; and the open file following its
    /// own incarnation, whatever took its old path.
    private static func seventh(_ source: URL, app: PetalApp) -> Bool {
        var ok = true
        func expect(_ condition: Bool, _ what: String) { if !condition { print("seventh: FAIL \(what)"); ok = false } }
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        // A note whose save is refused (its paper gone from the store meanwhile): what's typed goes into the journal.
        let noteID = "J-\(UUID().uuidString.prefix(6))"
        let paper = PaperNote(file: NoteFile(id: noteID, body: "Before"), url: folder.appending(path: "Notes/Inbox/Journal.md"), notebook: "Inbox")
        app.paper.store.preview([], notebooks: [])
        let editor = NoteEditorView(paper: paper, style: NoteRich.Style(ink: .black, dim: .gray, petal: .systemPink, accent: .systemBlue), focus: false,
                                    height: { _ in }, save: { app.paper.write(paper.key, noteID: noteID, instance: "", body: $0, base: $1) },
                                    register: { _ in }, importPictures: { _ in }, escape: {})
        let coordinator = editor.makeCoordinator()
        coordinator.body = "Before"
        coordinator.base = "---\nid: \(noteID)\n---\nBefore"
        let text = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        text.string = "Before, typed"
        coordinator.schedule(text)
        wait(1.2) { false }
        let journal = NoteJournal.file(noteID)
        // The snapshot is the whole note (its front matter too): its body is what's compared here.
        let flushedJournal = { () -> String? in
            var entry: NoteJournal.Entry?
            NoteJournal.queue.sync { entry = NoteJournal.read(journal) }
            return entry.map { NoteFile.parse($0.text, fallbackID: "x", fallbackDate: Date()).body }
        }
        expect(coordinator.marker.dirty && flushedJournal() == "Before, typed", "refused: in the journal at once, under its note's id")
        // More typed, then the editor closes before its next try (nothing waiting, still dirty): handed over now.
        text.string = "Before, typed, and more"
        coordinator.flush(text)
        expect(flushedJournal() == "Before, typed, and more", "closing: the dirty text handed to the journal, though no save was waiting")
        // Quitting (the desk flushes every editor's handle the same way).
        text.string = "Before, typed, and more, then quit"
        coordinator.flush(text)
        expect(flushedJournal() == "Before, typed, and more, then quit", "quitting: the same")
        // The next launch: put back from the journal into the notes' folder (a file of its own: its note isn't there).
        let root = folder.appending(path: "Notes")
        try? FileManager.default.createDirectory(at: root.appending(path: "Inbox"), withIntermediateDirectories: true)
        let holding = folder.appending(path: "recovering")
        try? FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
        NoteJournal.queue.sync { try? FileManager.default.moveItem(at: journal, to: holding.appending(path: journal.lastPathComponent)) }
        NoteJournal.recover(holding, root: root)
        let recovered = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "md" }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        expect(recovered.contains { $0.contains("Before, typed, and more, then quit") }, "and put back by the next launch's recovery")

        // The open file follows its own incarnation: renamed, and a new file at its old path, it stays the one shown.
        let a = folder.appending(path: "A.pdf")
        try? FileManager.default.copyItem(at: source, to: a)
        let model = ViewerModel(url: a, kind: .pdf)
        model.load()
        wait(20) { !model.loading }
        let pages = model.pageCount
        let b = folder.appending(path: "B.pdf")
        try? FileManager.default.moveItem(at: a, to: b)
        if let one = PDFDocument(url: b) {
            one.removePage(at: 0)
            _ = one.write(to: a)
        }
        model.fileChanged()
        wait(3) { model.url.lastPathComponent == "B.pdf" }
        wait(1) { false }
        expect(model.url.lastPathComponent == "B.pdf" && model.pageCount == pages, "renamed: it follows the file, not the new one at its old path")
        // The original gone: the file at its path is accepted (as after a save that made a new file).
        try? FileManager.default.removeItem(at: b)
        let fresh = ViewerModel(url: a, kind: .pdf)
        fresh.load()
        wait(20) { !fresh.loading }
        try? FileManager.default.removeItem(at: a)
        try? FileManager.default.copyItem(at: source, to: a)
        fresh.fileChanged()
        wait(5) { fresh.pageCount == pages }
        expect(fresh.url.lastPathComponent == "A.pdf" && fresh.pageCount == pages, "its own file gone: the file at its path")
        model.close()
        fresh.close()
        print("seventh: " + (ok ? "refused typing journaled at once, after a close and a quit, and recovered; the open file follows its incarnation" : "failed"))
        return ok
    }

    /// The sixth review: a refused save keeping the real editor dirty until it lands; a folder switch saving and
    /// closing margin editors, the margin read only until it's done; viewer papers counted for picture retries; and
    /// a document still being read told as still loading, never as 0 pages.
    private static func sixth(_ source: URL, app: PetalApp) -> Bool {
        var ok = true
        func expect(_ condition: Bool, _ what: String) { if !condition { print("sixth: FAIL \(what)"); ok = false } }
        // The editor: its save refused (the folder switching), then taken.
        let accept = HangUp()
        var saved: [String] = []
        let paper = PaperNote(file: NoteFile(id: "E1", body: "Before"), url: FileManager.default.temporaryDirectory.appending(path: "E1.md"), notebook: "Inbox")
        let editor = NoteEditorView(paper: paper, style: NoteRich.Style(ink: .black, dim: .gray, petal: .systemPink, accent: .systemBlue), focus: false,
                                    height: { _ in }, save: { body, _ in
                                        guard accept.gone else { return nil }
                                        saved.append(body)
                                        return "landed"
                                    }, register: { _ in }, importPictures: { _ in }, escape: {})
        let coordinator = editor.makeCoordinator()
        coordinator.body = "Before"
        let text = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        text.string = "Before and typed"
        coordinator.schedule(text)
        wait(1.2) { false }
        expect(coordinator.marker.dirty && coordinator.body == "Before" && saved.isEmpty, "a refused save keeps the editor dirty, its words not taken as saved")
        accept.gone = true
        wait(4) { !saved.isEmpty }
        expect(saved == ["Before and typed"] && !coordinator.marker.dirty && coordinator.body == "Before and typed", "tried again, it lands")

        // The notes' folder switching: the margin's editor saved and closed first, the margin read only meanwhile.
        let model = app.viewers.show(source, front: false)
        var stick = NoteStick(kind: .file)
        stick.path = source.path
        var file = NoteFile(id: "S1", body: "A note with a picture\n![x](../Pictures/abc/p.png)")
        file.places = [stick]
        let note = PaperNote(file: file, url: FileManager.default.temporaryDirectory.appending(path: "Inbox/S1.md"), notebook: "Inbox")
        app.paper.store.preview([note], notebooks: [])
        model.openPaper(note)
        let flushed = HangUp()
        let handle = NoteEditorHandle()
        handle.flush = { flushed.gone = true }
        app.paper.editors[note.key] = handle
        expect(model.openKey == note.key && model.marginEditable, "open in the margin (set up)")
        // Pictures: the paper open in a margin on screen counts; covered, or turned over, it doesn't.
        expect(!NoteShelf.picturesOnScreen(model.picturesShown(visible: true)).isEmpty, "a viewer paper on screen counts for picture retries")
        expect(NoteShelf.picturesOnScreen(model.picturesShown(visible: false)).isEmpty, "covered or closed, it doesn't")
        model.face = .back
        expect(NoteShelf.picturesOnScreen(model.picturesShown(visible: true)).isEmpty, "turned over, its pictures aren't showing")
        model.face = .open
        app.viewers.folderSwitching(true)
        expect(flushed.gone && model.openKey == nil && !model.marginEditable, "a folder switch saves and closes the margin's editor first")
        model.openPaper(note)
        expect(model.openKey == nil, "read only until the new folder is ready")
        app.viewers.folderSwitching(false)
        model.openPaper(note)
        expect(model.openKey == note.key, "then it takes typing again")
        model.close(note.key, .transfer)
        app.paper.editors[note.key] = nil

        // Still being read: told so, never as 0 pages.
        let slow = ViewerModel(url: source, kind: .pdf)
        var ready: Bool?
        slow.whenLoaded(within: 0.3) { ready = $0 }
        wait(1) { ready != nil }
        let told = app.viewers.told(slow)
        expect(ready == false && told["loading"] as? Bool == true && told["pages"] == nil && told["slides"] == nil, "still loading at the limit: said so, no page count")
        model.whenLoaded(within: 20) { ready = $0 }
        wait(20) { ready == true }
        let done = app.viewers.told(model)
        expect(done["loading"] == nil && (done["pages"] as? Int ?? 0) > 0, "read: its pages")
        model.close()
        print("sixth: " + (ok ? "a refused save stays dirty until it lands, a folder switch closes margin editors, viewer papers count for pictures, still loading is said" : "failed"))
        return ok
    }

    /// Versions made only while their asker is there and the viewer open: a hang-up or the viewer closing makes
    /// nothing show, and the copies go.
    private static func versions(_ source: URL, app: PetalApp) -> Bool {
        var ok = true
        func expect(_ condition: Bool, _ what: String) { if !condition { print("versions: FAIL \(what)"); ok = false } }
        let root = FileManager.default.temporaryDirectory.appending(path: "Petal Versions")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        func make(_ model: ViewerModel, live: @escaping @Sendable () -> Bool = { true }, closeAtOnce: Bool = false) -> Result<ViewerVersionSet, ViewerCopyError>? {
            var result: Result<ViewerVersionSet, ViewerCopyError>?
            model.makeVersions(["One", "Two"], asker: "check", live: live) { result = $0 }
            if closeAtOnce { model.close() }
            wait(20) { result != nil }
            wait(0.5) { false }
            return result
        }
        let left = { Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).subtracting(before) }
        if case .failure(.cancelled)? = make(ViewerModel(url: source, kind: .pdf), live: { false }) {} else { expect(false, "a hung-up asker: nothing made") }
        let late = HangUp()
        let model = ViewerModel(url: source, kind: .pdf)
        DispatchQueue.main.async { late.gone = true }
        if case .failure(.cancelled)? = make(model, live: { !late.gone }) {} else { expect(false, "hung up while copying: nothing shown") }
        expect(model.versions == nil && left().isEmpty, "and its copies gone")
        let closed = ViewerModel(url: source, kind: .pdf)
        if case .failure(.cancelled)? = make(closed, closeAtOnce: true) {} else { expect(false, "the viewer closed while copying: nothing shown") }
        expect(closed.versions == nil && left().isEmpty, "and its copies gone")
        let open = ViewerModel(url: source, kind: .pdf)
        if case .success(let set)? = make(open) {
            expect(set.versions.count == 2 && open.versions === set, "made and shown while it's open")
            try? FileManager.default.removeItem(at: set.folder)
            open.close()
        } else { expect(false, "made and shown while it's open") }
        print("versions: " + (ok ? "made only while asked and open; a hang-up or a closed viewer leaves nothing" : "failed"))
        return ok
    }

    /// "Open in Petal's viewer" goes through the one resolver: a place whose bookmark finds nothing opens nothing,
    /// even with a file at its old path.
    private static func opening(_ source: URL, app: PetalApp) -> Bool {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var ok = true
        func expect(_ condition: Bool, _ what: String) { if !condition { print("opening: FAIL \(what)"); ok = false } }
        let present = folder.appending(path: "Here.pdf")
        try? FileManager.default.copyItem(at: source, to: present)
        let gone = folder.appending(path: "Gone.pdf")
        try? FileManager.default.copyItem(at: source, to: gone)
        var broken = NoteStick(kind: .file)
        broken.path = present.path
        broken.bookmark = ViewerLoader.bookmark(gone)?.base64EncodedString() ?? ""
        try? FileManager.default.removeItem(at: gone)
        var good = NoteStick(kind: .file)
        good.path = present.path
        good.bookmark = ViewerLoader.bookmark(present)?.base64EncodedString() ?? ""
        func open(_ stick: NoteStick) -> Bool? {
            var opened: Bool?
            app.paper.openInViewer(stick) { opened = $0 }
            wait(20) { opened != nil }
            return opened
        }
        expect(open(broken) == false, "a bookmark that finds nothing: nothing opened, never the old path")
        expect(open(good) == true, "a place that resolves opens")
        print("opening: " + (ok ? "Open in Petal's viewer goes through the resolver" : "failed"))
        return ok
    }

    /// The viewer's tool answers through the vault's redaction: a file whose name holds a secret, opened through a
    /// link with an innocent name, is never named whole; version copies are named from redacted names; and nothing is
    /// told while the vault can't be read.
    private static func answers(_ source: URL, app: PetalApp) -> Bool {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var ok = true
        func expect(_ condition: Bool, _ what: String) { if !condition { print("answers: FAIL \(what)"); ok = false } }
        let secret = "petalcheck7Q2v9Lr4Xs"
        var key = VaultItem(kind: .apiKey, title: "Check key", sites: ["example.com"])
        key[.value] = secret
        VaultStore.standIn([key])
        defer { VaultStore.standUnreadable = false; VaultStore.standIn([]) }
        app.paper.previewReady()
        let named = folder.appending(path: "Report \(secret).pdf")
        try? FileManager.default.copyItem(at: source, to: named)
        let link = folder.appending(path: "Innocent.pdf")
        try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: named.path)
        func call(_ tool: String, _ args: [String: Any]) -> (answer: String?, refusal: String?) {
            var answer: String?
            var refusal: String?
            var done = false
            app.viewers.handle(tool, args, caller: "check", live: { true }, { value in
                answer = (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
                done = true
            }, { text in refusal = text; done = true })
            wait(60) { done }
            return (answer, refusal)
        }
        let viewed = call("petal_view", ["path": link.path])
        expect(viewed.answer != nil && viewed.answer?.contains(secret) == false && viewed.answer?.contains("(hidden)") == true,
               "petal_view through a link: the file's name told redacted (\(viewed.answer ?? viewed.refusal ?? "nothing"))")
        let made = call("petal_view_versions", ["path": link.path, "names": ["Draft \(secret)", "Short"]])
        expect(made.answer != nil && made.answer?.contains(secret) == false, "versions: labels and paths told redacted (\(made.answer ?? made.refusal ?? "nothing"))")
        let copies = (try? FileManager.default.subpathsOfDirectory(atPath: FileManager.default.temporaryDirectory.appending(path: "Petal Versions").path)) ?? []
        expect(!copies.contains { $0.contains(secret) } && copies.contains { $0.contains("(hidden)") }, "the copies' names never hold the secret")
        VaultStore.standUnreadable = true
        VaultStore.standIn([key])
        let closed = call("petal_view", ["path": link.path])
        expect(closed.answer == nil && closed.refusal == NoteShield.unreadable, "the vault unreadable: nothing told (\(closed.answer ?? closed.refusal ?? "nothing"))")
        let unmade = call("petal_view_versions", ["path": link.path, "names": ["Another"]])
        expect(unmade.answer == nil, "and no versions made")
        for model in app.viewers.open {
            if let folder = model.versions?.folder { try? FileManager.default.removeItem(at: folder) }
            model.close()
        }
        print("answers: " + (ok ? "redacted (a secret file name through a link, version labels and copies), nothing while the vault can't be read" : "failed"))
        return ok
    }

    /// The one file resolver, on throwaway copies: a note on a file whose path a new file took isn't on the new one;
    /// a sentence noted in Preview (Phase 1's passage on a file) is in the margin and the comments; a note on a file
    /// renamed since is exported with it.
    private static func places(_ source: URL, app: PetalApp) -> Bool {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var ok = true
        func expect(_ condition: Bool, _ what: String) { if !condition { print("places: FAIL \(what)"); ok = false } }
        let a = folder.appending(path: "A.pdf")
        try? FileManager.default.copyItem(at: source, to: a)
        /// A place as Petal makes one: its path, bookmark and the file's own identity.
        func place(_ kind: NoteStick.Kind, _ file: URL) -> NoteStick {
            var stick = NoteStick(kind: kind)
            stick.path = file.path
            stick.bookmark = ViewerLoader.bookmark(file)?.base64EncodedString() ?? ""
            stick.fileID = ViewerFileID.of(file.path)?.record(mac: app.paper.local.mac) ?? ""
            return stick
        }
        func paper(_ id: String, _ places: [NoteStick]) -> PaperNote {
            var file = NoteFile(id: id, body: "A made-up note \(id)")
            file.places = places
            return PaperNote(file: file, url: folder.appending(path: id + ".md"), notebook: "Inbox")
        }
        func margin(_ url: URL) -> [String] {
            // Loaded as the viewer loads it: membership is worked out for the file's checked identity.
            let model = ViewerModel(url: URL(fileURLWithPath: ViewerPath.canonical(url.path) ?? url.path), kind: .pdf)
            model.load()
            wait(20) { !model.loading }
            model.refreshPlaces()
            wait(3) { !model.notes.isEmpty }
            defer { model.close() }
            wait(0.3) { false }
            return model.notes.map(\.paper.noteID).sorted()
        }
        func export(_ url: URL) -> ViewerPDFComments.Outcome? {
            var result: ViewerPDFComments.Outcome?
            app.viewers.comments(url, opened: url.path, intoOriginal: false, caller: nil, { value in
                let wrote = (value as? [String: Any])?["wrote"] as? Int ?? 0
                let name = (value as? [String: Any])?["file"] as? String ?? ""
                result = .wrote(url.deletingLastPathComponent().appending(path: name), wrote)
            }, { result = .failed($0) })
            wait(20) { result != nil }
            return result
        }
        // A sentence noted in Preview: a passage on the file (no page), as Phase 1 makes it (its path, bookmark and
        // the file's identity, read with the window).
        let text = PDFDocument(url: a)?.page(at: 0)?.string ?? ""
        var sentence = place(.passage, a)
        sentence.quote = "Growth held steady"
        if let range = text.range(of: "Growth held steady") { sentence.after = String(text[range.upperBound...].prefix(20)) }
        let onA = place(.file, a)
        app.paper.store.preview([paper("P1", [sentence]), paper("P2", [onA])], notebooks: [])
        expect(margin(a) == ["P1", "P2"], "a Preview sentence and a file note are in the margin")
        if case .wrote(let copy, let count)? = export(a) {
            let highlights = PDFDocument(url: copy)?.page(at: 0)?.annotations.filter { $0.type == "Highlight" }.count ?? 0
            expect(count == 2 && highlights == 1, "both exported, the Preview sentence highlighted on its words")
            try? FileManager.default.removeItem(at: copy)
        } else { expect(false, "both exported") }
        // Renamed, then exported: its notes go with it.
        let b = folder.appending(path: "B.pdf")
        try? FileManager.default.moveItem(at: a, to: b)
        expect(margin(b) == ["P1", "P2"], "renamed: its notes follow it")
        if case .wrote(let copy, let count)? = export(b) {
            expect(count == 2, "renamed, then exported: both notes")
            try? FileManager.default.removeItem(at: copy)
        } else { expect(false, "renamed, then exported") }
        // Its old path taken by a new file: the notes stay with the renamed one, never on the new one.
        try? FileManager.default.copyItem(at: source, to: a)
        expect(margin(a).isEmpty, "a new file at the old path gets none of them")
        if case .failed? = export(a) {} else { expect(false, "and none of them are exported into it") }
        expect(margin(b) == ["P1", "P2"], "they're still on the file itself")
        print("places: " + (ok ? "one resolver: a Preview sentence, a renamed file and a reused path, in the margin and the comments" : "failed"))
        return ok
    }

    /// A Quick Look export whose result is dropped unused (a newer load) is cleaned up all the same.
    private static func cleanup(_ deck: URL) -> Bool {
        var folder: URL?
        var exported = false
        Viewers.queue.async {
            let pages = ViewerQuickLook.export(deck, unit: .slide)
            if case .web(let preview) = pages { folder = preview.export?.folder; exported = true }
            // Dropped here, unused.
        }
        wait(60) { exported }
        guard let folder else { print("cleanup: FAIL the deck didn't export"); return false }
        wait(5) { !FileManager.default.fileExists(atPath: folder.path) }
        let ok = !FileManager.default.fileExists(atPath: folder.path)
        print("cleanup: " + (ok ? "an export dropped unused is removed" : "FAIL an export dropped unused was left behind"))
        return ok
    }

    /// A preview with a picture from the network loads nothing from it (a local server counts what reaches it);
    /// without the rule list the same preview does reach it, so the check means something.
    private static func remote() -> Bool {
        let server = LocalServer()
        guard let port = server.start() else { print("remote: FAIL no local server"); return false }
        func preview() -> ViewerWeb.Preview {
            let export = ViewerExport()
            let folder = export.folder.appending(path: "Sample.qlpreview")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let html = "<html><body><p>Words of a sample document.</p><img src=\"http://127.0.0.1:\(port)/picture.png\" width=\"40\" height=\"40\"><p>More words.</p></body></html>"
            try? Data(html.utf8).write(to: folder.appending(path: "Preview.html"))
            return ViewerWeb.Preview(folder: folder, export: export, slides: false, width: 600, height: 800)
        }
        func pages(localOnly: Bool) -> Data?? {
            var result: Data??
            ViewerWeb.pages(preview(), localOnly: localOnly) { result = .some($0) }
            wait(40) { result != nil }
            return result
        }
        let blocked = pages(localOnly: true)
        wait(1) { false }
        let reachedBlocked = server.hits
        _ = pages(localOnly: false)
        wait(2) { server.hits > reachedBlocked }
        let reachedOpen = server.hits - reachedBlocked
        server.stop()
        let ok = (blocked ?? nil) != nil && reachedBlocked == 0 && reachedOpen > 0
        print("remote: " + (ok ? "nothing loaded from the network (without the rule list: \(reachedOpen) reached it)" : "FAIL \(reachedBlocked) requests reached the network with the rule list, \(reachedOpen) without; pages \(blocked.map { $0 != nil } ?? false)"))
        return ok
    }

    /// A TCP listener on 127.0.0.1 that counts connections (the check's stand-in for the network).
    final class LocalServer: @unchecked Sendable {
        private var socketFD: Int32 = -1
        private let lock = NSLock()
        private var count = 0
        var hits: Int { lock.withLock { count } }

        func start() -> UInt16? {
            socketFD = socket(AF_INET, SOCK_STREAM, 0)
            guard socketFD >= 0 else { return nil }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0, listen(socketFD, 8) == 0 else { return nil }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } }
            let fd = socketFD
            Thread.detachNewThread { [self] in
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 { return }
                    lock.withLock { count += 1 }
                    close(client)
                }
            }
            return UInt16(bigEndian: address.sin_port)
        }

        func stop() { if socketFD >= 0 { close(socketFD); socketFD = -1 } }
    }

    /// An off-screen viewer window on a throwaway PDF whose first page has "Growth held steady" (never ordered in).
    private static func window(_ url: URL, app: PetalApp) -> Bool {
        let model = ViewerModel(url: url, kind: .pdf)
        let window = ViewerWindow(model: model)
        window.setFrame(NSRect(origin: CGPoint(x: -4000, y: -4000), size: ViewerLook.size), display: false)
        model.load()
        wait(20) { !model.loading && model.pdfView != nil }
        window.contentView?.layoutSubtreeIfNeeded()
        wait(1) { false }
        guard let view = model.pdfView, let page = view.document?.page(at: 0), let text = page.string,
              let found = text.range(of: "Growth held steady") else {
            print("window: the PDF view didn't come up (\(model.pageCount) pages)")
            return false
        }
        var ok = true
        func expect(_ condition: Bool, _ what: String) { if !condition { print("window: FAIL \(what)"); ok = false } }
        expect(model.pageCount == 2 && model.current == 0, "two pages, the first shown")
        // A selection offers a Note with its page, bounds, and the page's whole text, read off the main thread; an
        // older selection's answer never lands over a newer one's.
        if let other = text.range(of: "A sample report") {
            view.setCurrentSelection(page.selection(for: NSRange(other, in: text)), animate: false)
        }
        let selection = page.selection(for: NSRange(found, in: text))
        view.setCurrentSelection(selection, animate: false)
        expect(model.selection == nil, "the page's text isn't read on the main thread (the selection waits for it)")
        wait(3) { model.selection != nil }
        wait(0.5) { false }
        expect(model.selection?.page == 0 && model.selection?.quote == "Growth held steady" && model.selection?.pageText == text, "the selection's page and words")
        // A new selection starting: the one before (and its Note) gone at once, the new one only once its read is in.
        if let other = text.range(of: "second half") {
            view.setCurrentSelection(page.selection(for: NSRange(other, in: text)), animate: false)
            expect(model.selection == nil, "the old selection cleared at once, its Note hidden")
            wait(3) { model.selection != nil }
            expect(model.selection?.quote == "second half", "the new one offered once read")
            view.setCurrentSelection(selection, animate: false)
            wait(3) { model.selection?.quote == "Growth held steady" }
        }
        // The passage as the vault check cuts it from the whole page.
        if let chosen = model.selection, let cut = ViewerSecrets.passage(chosen.pageText, range: chosen.range, secrets: []) {
            expect(cut.quote == "Growth held steady" && cut.after.hasPrefix(" through"), "the passage cut from the page's text")
        } else { expect(false, "the passage cut from the page's text") }
        // A note on those words, saved with coordinates that are wrong now: its highlight is where the words are.
        guard let bounds = model.selection?.bounds else { return false }
        var stick = NoteStick(kind: .file)
        stick.path = url.path
        stick.page = 1
        stick.bounds = [5, 5, 40, 10]
        stick.quote = "Growth held steady"
        stick.after = " through the second half."
        var file = NoteFile(id: "W1", body: "A made-up note")
        file.places = [stick]
        var gone = NoteStick(kind: .file)
        gone.path = url.path
        gone.page = 1
        gone.bounds = [72, 600, 100, 14]
        gone.quote = "Words this page doesn't have"
        var lost = NoteFile(id: "W2", body: "A note whose passage moved")
        lost.places = [gone]
        let notes = [PaperNote(file: file, url: FileManager.default.temporaryDirectory.appending(path: "W1.md"), notebook: "Inbox"),
                     PaperNote(file: lost, url: FileManager.default.temporaryDirectory.appending(path: "W2.md"), notebook: "Inbox")]
        app.paper.store.preview(notes, notebooks: [])
        model.selection = nil
        // Places with a path and nothing else (written by hand): the file at that path (the one resolver).
        model.refreshPlaces()
        wait(3) { model.notes.count == 2 }
        model.resolvePassages()
        window.contentView?.layoutSubtreeIfNeeded()
        wait(3) { model.highlights[notes[0].key] != nil && model.passages[notes[1].key] != nil }
        let words = ViewerGeometry.window(view.convert(bounds, from: page), in: view)
        let mark = model.highlights[notes[0].key] ?? .zero
        expect(abs(mark.minX - words.minX) < 1 && abs(mark.minY - words.minY) < 1 && mark.width > 10, "the highlight is on the passage's words, not its old coordinates")
        expect(model.passages[notes[1].key] == .moved && model.highlights[notes[1].key] == nil && model.spot(notes[1], gone).page == nil,
               "a passage that isn't there any more: moved, on the file, no highlight")
        expect(model.documentFrame.contains(mark), "inside the document")
        let layout = ViewerMarginView.placed(model, model.notes, visible: ViewerLook.size.height - ViewerLook.bar)
        expect(layout.spots[notes[0].key].map { abs($0.y + ViewerLook.bar - model.docScroll - (mark.midY - 28)) < 1 || $0.y == ViewerLook.marginTop } == true,
               "lined up with its passage")
        expect(layout.spots[notes[1].key] != nil, "the moved one still in the margin")
        // The margin scrolled moves the pages with it (as far as they had scrolled already: PDFKit shows the first
        // page's top, past the break above it), and back.
        let start = model.docScroll
        model.marginScrolled(120)
        wait(1) { abs(model.docScroll - 120) < 1 }
        expect(abs(model.docScroll - 120) < 1, "the pages follow the margin (\(model.docScroll))")
        let moved = model.highlights[notes[0].key] ?? .zero
        expect(abs((mark.minY - moved.minY) - (120 - start)) < 1.5, "the passage moved up with them (\(mark.minY) → \(moved.minY), from \(start))")
        model.marginScrolled(0)
        wait(1) { model.docScroll < 1 }
        // A note made through a link to the PDF is on this file (by its identity, never its path's spelling).
        let linkFolder = scratch()
        defer { try? FileManager.default.removeItem(at: linkFolder) }
        let link = linkFolder.appending(path: "Linked.pdf")
        try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: url.path)
        var linked = NoteStick(kind: .file)
        linked.path = link.path
        var throughLink = NoteFile(id: "W3", body: "A note made through a link")
        throughLink.places = [linked]
        // An id-less note (a Markdown file made elsewhere): open in the margin, then given its own id.
        var idless = NoteFile(id: NoteShelf.fallbackID(relativePath: "Inbox/Handwritten.md"), body: "Written by hand")
        idless.places = [linked]
        var handwritten = PaperNote(file: idless, url: FileManager.default.temporaryDirectory.appending(path: "Handwritten.md"), notebook: "Inbox")
        handwritten.instance = "1:42"
        // An empty note just made (in the viewer or on the desk): handed between them, never let go of.
        let draft = PaperNote(file: { var f = NoteFile(id: "W5", body: ""); f.places = [linked]; return f }(),
                              url: FileManager.default.temporaryDirectory.appending(path: "W5.md"), notebook: "Inbox")
        app.paper.store.preview(notes + [PaperNote(file: throughLink, url: FileManager.default.temporaryDirectory.appending(path: "W3.md"), notebook: "Inbox"), handwritten, draft],
                                notebooks: [])
        model.refreshPlaces()
        wait(3) { model.notes.contains { $0.paper.noteID == "W3" } }
        expect(model.notes.contains { $0.paper.noteID == "W3" }, "a note made through a link shows")
        app.paper.fresh.insert(draft.key)
        model.openPaper(draft)
        app.paper.releaseFromViewer(draft)
        expect(model.openKey == nil && app.paper.fresh.contains(draft.key) && app.paper.store.paper(draft.key) != nil,
               "handed from the viewer to the desk: the empty draft stays")
        app.paper.faces[draft.key] = .open
        model.openPaper(draft)
        expect(model.openKey == draft.key && app.paper.faces[draft.key] == .folded && app.paper.fresh.contains(draft.key) && app.paper.store.paper(draft.key) != nil,
               "handed from the desk to the viewer: the empty draft stays")
        model.close(draft.key, .transfer)
        app.paper.faces[draft.key] = nil
        app.paper.fresh.remove(draft.key)
        // Notes turned off: the paper open in the margin is saved and closed, the margin gone; on again, it's back.
        model.openPaper(handwritten)
        app.config.set("notes", false)
        model.notesChanged()
        expect(model.openKey == nil && !model.marginOn && app.paper.heldByViewer.isEmpty, "notes off: the margin and its editor closed")
        app.config.set("notes", true)
        model.notesChanged()
        expect(model.marginOn, "notes on again: the margin shows")
        model.openPaper(handwritten)
        expect(model.openKey == handwritten.key && app.paper.heldByViewer[handwritten.holder] != nil, "open in the margin, held by its identity")
        app.paper.identityChanged(holder: handwritten.holder, "W4")
        var given = handwritten
        given.file.id = "W4"
        app.paper.releaseFromViewer(given)
        expect(model.openKey == nil && app.paper.heldByViewer.isEmpty, "given its own id, the desk opening it still closes it in the margin")
        // A folded paper's corner turns that paper over (opened first), never the one open.
        let linkPaper = PaperNote(file: throughLink, url: FileManager.default.temporaryDirectory.appending(path: "W3.md"), notebook: "Inbox")
        model.openPaper(handwritten)
        model.flip(linkPaper)
        expect(model.openKey == linkPaper.key && model.face == .back, "the corner used turns its own paper over")
        model.flip(linkPaper)
        expect(model.openKey == linkPaper.key && model.face == .open, "and back")
        model.close(linkPaper.key, .transfer)
        // Renamed while its editor is open: the same margin paper (its editor and typing kept), and its last save
        // lands on the note as it is now.
        let before = model.paperID(linkPaper)
        var renamedPaper = linkPaper
        renamedPaper.url = FileManager.default.temporaryDirectory.appending(path: "W3 renamed.md")
        app.paper.store.preview([renamedPaper, handwritten], notebooks: [])
        expect(model.paperID(renamedPaper) == before, "renamed: the same margin paper, so its editor and what's typed stay")
        let target = NoteShelf.saveTarget(key: linkPaper.key, noteID: "W3", instance: "", papers: app.paper.store.notes.map { ($0.key, $0.noteID, $0.instance, $0.version) },
                                          current: app.paper.store.currentID)
        expect(target == renamedPaper.key, "the editor's final save goes to the renamed note")
        print("window: " + (ok ? "PDF view, selection read off the main thread, passages found by their words, highlight, margin and pages in step, a link's note, ownership across an id change, the old selection cleared at once, an empty draft kept across a hand-off, notes off closing the margin, the right paper flipped, a rename keeping its editor" : "failed"))
        window.close()
        return ok
    }
}
