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
        pdf.openNote = "V1"
        pdf.heights = ["V1": 214, "V2": PaperLook.folded, "V3": PaperLook.folded]
        lay(pdf, size: size, strip: false)
        write(render(AnyView(ViewerView(model: pdf)), app: app, size: size), name: "viewer-pdf", folder: folder)

        // A slide deck through Quick Look: notes per slide, the one shown open.
        let deck = ViewerModel(url: URL(fileURLWithPath: "/Users/someone/Documents/Quarterly plan.pptx"), kind: .quickLook(.slide))
        deck.preview(pages: (0..<9).map { sampleSlide($0) }, current: 2, app: "PowerPoint")
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
        deck.openNote = "D1"
        deck.heights = ["D1": 190, "D2": PaperLook.folded, "D3": PaperLook.folded]
        lay(deck, size: size, strip: false)
        write(render(AnyView(ViewerView(model: deck)), app: app, size: size), name: "viewer-slides", folder: folder)

        // Versions on copies under the slide, each with Use this.
        let set = ViewerVersionSet(id: "sample", asker: "snapshot", folder: root, versions: [
            ViewerVersion(label: "Short title", url: root.appending(path: "Quarterly plan (Short title).pptx"), thumb: sampleSlide(2, title: "Plan: faster")),
            ViewerVersion(label: "With figures", url: root.appending(path: "Quarterly plan (With figures).pptx"), thumb: sampleSlide(2, title: "Plan: five wins in a row", dark: true)),
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
            guard let index = ViewerMatch.pageIndex(place, count: model.pageCount), let frame = frames[index], let b = place.bounds else { continue }
            let scale = frame.width / 612
            highlights[paper.noteID] = CGRect(x: frame.minX + b[0] * scale, y: frame.minY + (792 - b[1] - b[3]) * scale, width: b[2] * scale, height: b[3] * scale)
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
/// it isn't a PDF, and for a PDF its notes written as comments into a copy beside it (a made-up note). Prints what
/// each became. Run it on throwaway files only: it writes beside a PDF it's given.
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
            let until = Date().addingTimeInterval(90)
            while !done && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            if !done { print("\(file): timed out"); failed = true }
        }
        // The window itself, never shown: PDFKit's view, a selection offering a Note, and a note's highlight where
        // the selection of the same words is.
        if let pdf = files.first(where: { ViewerKind.of($0) == .pdf }), case .success(let url) = ViewerPath.check(pdf) {
            failed = !window(url) || failed
        }
        exit(failed ? 1 : 0)
    }

    private static func wait(_ seconds: Double, until done: () -> Bool) {
        let until = Date().addingTimeInterval(seconds)
        while !done() && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// An off-screen viewer window on a throwaway PDF whose first page has "Growth held steady" (never ordered in).
    private static func window(_ url: URL) -> Bool {
        let app = PetalApp()
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
        // A selection offers a Note with its page, bounds, words and the words around them.
        let selection = page.selection(for: NSRange(found, in: text))
        view.setCurrentSelection(selection, animate: false)
        wait(1) { model.selection != nil }
        expect(model.selection?.page == 0 && model.selection?.quote == "Growth held steady" && model.selection?.after.hasPrefix(" through") == true,
               "the selection's page and words")
        // A note on those bounds: its highlight in the window is where the selection is.
        guard let bounds = model.selection?.bounds else { return false }
        var stick = NoteStick(kind: .file)
        stick.path = url.path
        stick.page = 1
        stick.bounds = [bounds.minX, bounds.minY, bounds.width, bounds.height]
        stick.quote = "Growth held steady"
        var file = NoteFile(id: "W1", body: "A made-up note")
        file.places = [stick]
        app.paper.store.preview([PaperNote(file: file, url: FileManager.default.temporaryDirectory.appending(path: "W1.md"), notebook: "Inbox")], notebooks: [])
        model.selection = nil
        window.contentView?.layoutSubtreeIfNeeded()
        wait(2) { model.highlights["W1"] != nil }
        let words = ViewerGeometry.window(view.convert(bounds, from: page), in: view)
        let mark = model.highlights["W1"] ?? .zero
        expect(abs(mark.minX - words.minX) < 0.5 && abs(mark.minY - words.minY) < 0.5 && mark.width > 10, "the highlight is on the passage's words")
        expect(model.documentFrame.contains(mark), "inside the document")
        expect(model.notes.count == 1 && ViewerMatch.place(model.notes[0].paper.file.places, path: url.path) == 0, "the note is in the margin")
        let spots = ViewerMarginView.placed(model, model.notes)
        expect(spots["W1"].map { abs($0.y + ViewerLook.bar - (mark.midY - 28)) < 1 || $0.y == ViewerLook.marginTop } == true, "lined up with its passage")
        print("window: " + (ok ? "PDF view, selection, highlight and margin line up" : "failed"))
        window.close()
        return ok
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
                        // Comments into a copy beside it: a made-up note on page 1's first words, one on the file.
                        var passage = NoteStick(kind: .file)
                        passage.path = url.path
                        passage.page = 1
                        let first = document.page(at: 0)
                        let box = first?.bounds(for: .cropBox) ?? .zero
                        passage.bounds = [Double(box.minX + 72), Double(box.maxY - 120), 200, 14]
                        var whole = NoteStick(kind: .file)
                        whole.path = url.path
                        let comments = [ViewerPDFComments.Comment(stick: passage, text: "A made-up note on a passage", color: PaperLook.rgb(.systemBlue)),
                                        ViewerPDFComments.Comment(stick: whole, text: "A made-up note on the file", color: PaperLook.rgb(.systemGreen))]
                        ViewerPDFComments.write(url, comments: comments, intoOriginal: false, author: "Petal check") { outcome in
                            switch outcome {
                            case .wrote(let copy, let count):
                                let annotations = PDFDocument(url: copy).map { doc in (0..<doc.pageCount).reduce(0) { $0 + (doc.page(at: $1)?.annotations.count ?? 0) } } ?? 0
                                print("  comments: \(count) notes into \(copy.lastPathComponent) (\(annotations) annotations)")
                                done(count == 2 && annotations >= 3)
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
}
