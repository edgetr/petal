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
                    passages: [notesPDF[0].key: .found(page: 0, bounds: CGRect(x: 72, y: 558, width: 300, height: 16)),
                               notesPDF[1].key: .found(page: 0, bounds: CGRect(x: 72, y: 378, width: 260, height: 16))])
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
            let model = ViewerModel(url: url, kind: .pdf)
            model.refreshPlaces()
            wait(3) { !model.notes.isEmpty }
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
        print("window: " + (ok ? "PDF view, selection read off the main thread, passages found by their words, highlight, margin and pages in step, a link's note, ownership across an id change, the old selection cleared at once, an empty draft kept across a hand-off, notes off closing the margin" : "failed"))
        window.close()
        return ok
    }
}
