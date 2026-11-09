import AppKit
import PDFKit
import Quartz
import SwiftUI

/// The viewer's look, as the sketch's Viewer scene has it (notes-round2.html): a #ececf0 window, a 50-point bar,
/// pages on the left as 150-point thumbnails, the document in the middle, and a 350-point margin on the right
/// where the notes on this file rest, lined up with what they're about.
enum ViewerLook {
    static let size = CGSize(width: 1220, height: 748)
    static let bar: CGFloat = 50
    static let thumbs: CGFloat = 150
    static let rail: CGFloat = 190   // the thumbnails' column: 20 + 150 + 20
    static let margin: CGFloat = 350
    static let openWidth: CGFloat = 310
    static let marginTop: CGFloat = 20
    static let window = Color(.sRGB, red: 0xec / 255.0, green: 0xec / 255.0, blue: 0xf0 / 255.0)
    static let windowNS = NSColor(srgbRed: 0xec / 255.0, green: 0xec / 255.0, blue: 0xf0 / 255.0, alpha: 1)
    static let barFill = Color(.sRGB, red: 0xf5 / 255.0, green: 0xf5 / 255.0, blue: 0xf7 / 255.0)
    static let line = Color(.sRGB, red: 0xdc / 255.0, green: 0xdc / 255.0, blue: 0xe0 / 255.0)
    static let gray = Color(white: 0x88 / 255.0)
    static let caption = Color(white: 0x66 / 255.0)
}

/// The viewer's window: a plain window of Petal's own (macOS's title bar hidden under the viewer's own bar).
@MainActor
final class ViewerWindow: NSWindow, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let modelID: UUID

    init(model: ViewerModel) {
        modelID = model.id
        super.init(contentRect: NSRect(origin: .zero, size: ViewerLook.size),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = model.name
        minSize = NSSize(width: 860, height: 520)
        backgroundColor = ViewerLook.windowNS
        contentView = NSHostingView(rootView: ViewerView(model: model).environment(PetalApp.shared))
        delegate = self
        center()
    }

    override var canBecomeKey: Bool { true }

    /// The Edit menu's keys (⌘C, ⌘V, ⌘Z…) in the margin's editor, whether or not Petal's hidden menu gets them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" { performClose(nil); return true }
        return EditMenu.keyEquivalent(event, window: self, viewsHandled: super.performKeyEquivalent(with: event))
    }

    /// With the keyboard, this viewer is the desk's current place (Viewers.front: "here", sticking and ⌃⌥N go to it);
    /// the notes on the window left behind are hidden.
    func windowDidBecomeKey(_ notification: Notification) {
        PetalApp.shared.viewers.keyID = modelID
        PetalApp.shared.paper.viewerFront()
    }

    func windowDidResignKey(_ notification: Notification) {
        if PetalApp.shared.viewers.keyID == modelID { PetalApp.shared.viewers.keyID = nil }
    }

    /// Shown, hidden, covered or minimized: the margin's pictures count as on screen or not (NotePictures' retry).
    func windowDidChangeOcclusionState(_ notification: Notification) { NotePictures.shared.visibilityChanged() }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

// MARK: - The viewer

struct ViewerView: View {
    let model: ViewerModel
    @Environment(\.snapshotting) private var snapshotting

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                ViewerLook.window
                VStack(spacing: 0) {
                    ViewerBar(model: model)
                    HStack(spacing: 0) {
                        if !model.live { ViewerRail(model: model).frame(width: ViewerLook.rail) }
                        VStack(spacing: 0) {
                            ViewerDocument(model: model)
                            if let set = model.versions { ViewerVersionsStrip(model: model, set: set) }
                        }
                        if model.marginOn { Color.clear.frame(width: ViewerLook.margin) }
                    }
                }
                // The margin: its own paper-white column with the notes on this file, only while Petal Notes is on.
                if model.marginOn {
                    ViewerMarginView(model: model, size: size)
                        .frame(width: ViewerLook.margin, height: size.height - ViewerLook.bar)
                        .offset(x: size.width - ViewerLook.margin, y: ViewerLook.bar)
                    // Highlights and the dashed lines to their notes, over everything, never in the way of a click.
                    ViewerInk(model: model, size: size).allowsHitTesting(false)
                }
                if let selection = model.selection, model.marginOn, !snapshotting {
                    Button("Note") { model.newNote() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .help("A note on this passage")
                        .offset(x: min(max(selection.anchor.x - 30, 10), size.width - ViewerLook.margin - 70), y: max(ViewerLook.bar + 4, selection.anchor.y - 34))
                }
            }
        }
        .environment(\.colorScheme, .light)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in ViewerDrop.take(providers) }
        // The notes' file places that are this file by its identity (a link, another spelling), again whenever they
        // or the file's path change.
        .task(id: model.anchorSignature) { model.refreshPlaces() }
    }
}

/// Files dropped on the Petal Notes area open in the viewer: `.onDrop(of: [.fileURL], …) { ViewerDrop.take($0) }`.
@MainActor
enum ViewerDrop {
    static func take(_ providers: [NSItemProvider]) -> Bool {
        let wanted = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !wanted.isEmpty else { return false }
        for provider in wanted {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { _ = PetalApp.shared.viewers.dropped([url]) } }
            }
        }
        return true
    }
}

/// The bar: the file's name and where in it ("Roadmap.pptx · Slide 3 of 9"), "Updated just now" after it changed
/// on disk, a new note, and Open in <app>, one click away.
struct ViewerBar: View {
    let model: ViewerModel

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Text(model.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(white: 0.114))
                if model.pageCount > 0 {
                    Text(" · \(model.unit.title) \(model.current + 1) of \(model.pageCount)").font(.system(size: 13)).foregroundStyle(ViewerLook.gray)
                }
                TimelineView(.periodic(from: .now, by: 20)) { time in
                    if let updated = ViewerUpdated.label(model.updated, now: time.date) {
                        Text(" · " + updated).font(.system(size: 13)).foregroundStyle(ViewerLook.gray)
                    }
                }
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            if model.marginOn {
                ViewerBarButton(title: "New note") { model.newNote() }
                    .help(model.unit == .slide ? "A note on this slide (or the passage you selected)" : "A note on this page (or the passage you selected)")
            }
            ViewerBarButton(title: model.appName.isEmpty ? "Open" : "Open in \(model.appName)") { model.openInApp() }
        }
        .padding(.leading, 96).padding(.trailing, 16)
        .frame(height: ViewerLook.bar)
        .background(ViewerLook.barFill)
        .overlay(alignment: .bottom) { ViewerLook.line.frame(height: 1) }
    }
}

struct ViewerBarButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(Color(white: 0.114))
                .padding(.vertical, 4).padding(.horizontal, 10)
                .background(.white, in: .rect(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(.black.opacity(0.18), lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
    }
}

/// The pages on the left: each as a thumbnail (drawn off the main thread), the one shown outlined in the accent.
struct ViewerRail: View {
    let model: ViewerModel
    @Environment(\.snapshotting) private var snapshotting

    var body: some View {
        if snapshotting {
            VStack(spacing: 14) {
                ForEach(0..<min(model.pageCount, 8), id: \.self) { index in
                    ViewerThumb(image: model.thumbs[index], on: index == model.current, ratio: ratio(index))
                }
            }
            .padding(.top, 20).padding(.horizontal, 20)
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
        } else {
            scrolling
        }
    }

    private var scrolling: some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical) {
                LazyVStack(spacing: 14) {
                    ForEach(0..<max(model.pageCount, 0), id: \.self) { index in
                        ViewerThumb(image: model.thumbs[index], on: index == model.current, ratio: ratio(index))
                            .id(index)
                            .onTapGesture { model.go(to: index) }
                    }
                }
                .padding(.top, 20).padding(.horizontal, 20).padding(.bottom, 20)
            }
            .scrollIndicators(.never)
            .onChange(of: model.current) { _, now in withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(now) } }
        }
    }

    private func ratio(_ index: Int) -> CGFloat {
        guard let image = model.thumbs[index] ?? model.thumbs.values.first, image.size.width > 0 else { return model.unit == .slide ? 84 / 150 : 1.29 }
        return image.size.height / image.size.width
    }
}

struct ViewerThumb: View {
    let image: NSImage?
    let on: Bool
    let ratio: CGFloat

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) } else { Color.white }
        }
        .frame(width: ViewerLook.thumbs, height: ViewerLook.thumbs * ratio)
        .background(.white)
        .clipShape(.rect(cornerRadius: 3))
        .overlay { RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.2), lineWidth: 0.5) }
        .overlay { if on { RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .controlAccentColor), lineWidth: 3).padding(-3.5) } }
    }
}

/// The document: PDFKit's view of the pages (a PDF's, or Quick Look's exported), or Quick Look's own view when no
/// pages could be exported. Drawn as pictures in snapshots.
struct ViewerDocument: View {
    let model: ViewerModel
    @Environment(\.snapshotting) private var snapshotting

    var body: some View {
        Group {
            if snapshotting {
                ViewerPagesPicture(model: model)
            } else if model.loading && model.document == nil && !model.live {
                // The first load only: a reload keeps the pages shown until its own are in.
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let problem = model.problem {
                Text(problem).font(.system(size: 13)).foregroundStyle(ViewerLook.caption).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.live {
                // Quick Look's own view is given Petal's private copy of the checked bytes, never the original's path.
                if let copy = model.liveURL { ViewerQuickLookView(url: copy, version: model.updated) }
            } else if model.document != nil {
                ViewerPDF(model: model, signature: signature)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What the margin's highlights depend on: the notes on this file, their places and where their passages are.
    private var signature: String {
        model.notes.map { "\($0.paper.key):\($0.place.page ?? 0):\($0.place.slide ?? 0):\($0.place.quote.count)" }.joined(separator: ",")
            + "|\(model.passages.count)|\(model.passages.values.map { "\($0)" }.sorted().joined())"
    }
}

/// Quick Look's own view of a document (out of process; nothing of it on the main thread).
struct ViewerQuickLookView: NSViewRepresentable {
    let url: URL
    let version: Date?

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // Renamed or moved: Quick Look shows the file where it is now, then it's read again.
        if context.coordinator.url != url {
            context.coordinator.url = url
            view.previewItem = url as NSURL
        }
        if context.coordinator.version != version {
            context.coordinator.version = version
            view.refreshPreviewItem()
        }
    }

    func makeCoordinator() -> Holder { Holder(url: url) }
    final class Holder {
        var url: URL
        var version: Date?
        init(url: URL) { self.url = url }
    }
}

/// PDFKit's view: one slide at a time for a deck, the pages scrolling for anything else. It tells the model the page
/// shown, the selection (a Note), where each passage (found again by its words) and each page is as it scrolls and
/// zooms, and how far the pages have scrolled, so the margin moves in step; the margin scrolled moves the pages.
struct ViewerPDF: NSViewRepresentable {
    let model: ViewerModel
    let signature: String

    func makeNSView(context: Context) -> PDFView {
        let view = ViewerPDFView()
        view.autoScales = true
        view.displayMode = model.unit == .slide ? .singlePage : .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        view.backgroundColor = ViewerLook.windowNS
        view.pageShadowsEnabled = true
        view.document = model.document
        view.clicked = { [weak model] in
            guard let model, let key = model.openKey else { return }
            model.fold(key)
        }
        model.pdfView = view
        if let page = model.document?.page(at: model.current) { view.go(to: page) }
        context.coordinator.attach(view, model: model)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== model.document {
            // The page to show taken first: assigning the document resets PDFKit's page and posts page changes,
            // which aren't the person's and are ignored until it's at that page (`rebinding`).
            let target = model.current
            model.rebinding = true
            view.document = model.document
            if let page = model.document?.page(at: target) { view.go(to: page) }
            if model.current != target { model.current = target }
            DispatchQueue.main.async { [weak model] in model?.rebinding = false }
        }
        // A note added, moved or re-stuck: its passage found again (only when the notes' passages changed).
        model.resolvePassages()
        context.coordinator.relayoutSoon()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: PDFView?
        weak var model: ViewerModel?
        private var soon = false

        func attach(_ view: PDFView, model: ViewerModel) {
            self.view = view
            self.model = model
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
            center.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
            center.addObserver(self, selector: #selector(moved), name: .PDFViewScaleChanged, object: view)
            center.addObserver(self, selector: #selector(moved), name: NSView.frameDidChangeNotification, object: view)
            model.scrollDocument = { [weak self] offset in self?.scroll(to: offset) }
            DispatchQueue.main.async { [weak self] in self?.watchScrolling() }
        }

        private var scroller: NSScrollView? { view?.documentView?.enclosingScrollView }

        private func watchScrolling() {
            guard let clip = scroller?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSView.boundsDidChangeNotification, object: clip)
            relayout()
        }

        @objc private func pageChanged() {
            // Only the person's own scrolling moves `current` (never PDFKit resetting its page on a new document).
            guard let view, let model, !model.rebinding, let page = view.currentPage, let document = view.document else { return }
            let index = document.index(for: page)
            if model.current != index { model.current = index }
            relayout()
        }

        @objc private func moved() { relayout() }

        func relayoutSoon() {
            guard !soon else { return }
            soon = true
            DispatchQueue.main.async { [weak self] in
                self?.soon = false
                self?.relayout()
            }
        }

        /// How far the pages have scrolled from their top and how tall they are, in the window's points.
        private func scrolled() -> (offset: CGFloat, height: CGFloat)? {
            guard let scroller, let doc = scroller.documentView else { return nil }
            let visible = scroller.documentVisibleRect
            let fromTop = doc.isFlipped ? visible.minY : doc.bounds.height - visible.maxY
            let scale = scroller.magnification
            return (max(0, fromTop * scale), doc.bounds.height * scale)
        }

        /// The pages scrolled so that `offset` (the margin's) is how far they are from their top, as far as they go.
        func scroll(to offset: CGFloat) {
            guard let scroller, let doc = scroller.documentView else { return }
            let clip = scroller.contentView
            let visible = scroller.documentVisibleRect
            let scale = max(scroller.magnification, 0.01)
            let target = min(max(0, offset / scale), max(0, doc.bounds.height - visible.height))
            let y = doc.isFlipped ? target : doc.bounds.height - target - visible.height
            clip.scroll(to: NSPoint(x: visible.minX, y: y))
            scroller.reflectScrolledClipView(clip)
        }

        /// Where each passage's highlight and each page's top are now, in the window, and how far the pages have
        /// scrolled: the margin lines its notes up with them.
        func relayout() {
            guard let view, let model, let document = view.document, view.window != nil else { return }
            var highlights: [String: CGRect] = [:]
            var lines: [String: [CGRect]] = [:]
            var tops: [Int: CGFloat] = [:]
            let single = view.displayMode == .singlePage
            for (paper, place) in model.notes {
                let spot = model.spot(paper, place)
                guard let index = spot.page, let page = document.page(at: index) else { continue }
                if single, index != model.current { continue }
                tops[index] = ViewerGeometry.window(view.convert(page.bounds(for: .cropBox), from: page), in: view).minY
                // Only a passage found again by its words now is highlighted.
                if let bounds = spot.bounds {
                    highlights[paper.key] = ViewerGeometry.window(view.convert(bounds, from: page), in: view)
                    lines[paper.key] = model.passageLines(paper).map { ViewerGeometry.window(view.convert($0, from: page), in: view) }
                }
            }
            if let page = document.page(at: model.current) {
                tops[model.current] = ViewerGeometry.window(view.convert(page.bounds(for: .cropBox), from: page), in: view).minY
            }
            let frame = ViewerGeometry.window(view.bounds, in: view)
            if model.highlights != highlights { model.highlights = highlights }
            if model.highlightLines != lines { model.highlightLines = lines }
            if model.pageTops != tops { model.pageTops = tops }
            if model.documentFrame != frame { model.documentFrame = frame }
            if model.scrolls, let scrolled = scrolled() {
                if abs(model.docScroll - scrolled.offset) > 0.5 { model.docScroll = scrolled.offset }
                if abs(model.docHeight - scrolled.height) > 0.5 { model.docHeight = scrolled.height }
            }
            if let selection = view.currentSelection, let page = selection.pages.first, model.selection != nil {
                let rect = ViewerGeometry.window(view.convert(selection.bounds(for: page), from: page), in: view)
                model.selection?.anchor = CGPoint(x: rect.maxX, y: rect.minY)
            }
            if model.lensAnswer != nil { model.lensPlaced() }
        }

        /// A selection on one page offers a Note: its page, bounds and where it is in the page's text; the page's
        /// text itself, and from it the selected words and whether there are any, is read off the main thread
        /// (ViewerModel.selected; never the selection's own string here), so the passage is cut only after the whole
        /// page was checked, and, while a note follows the selection, the lens is asked about its paragraph.
        @objc private func selectionChanged() {
            guard let view, let model else { return }
            guard let selection = view.currentSelection, selection.pages.count == 1, let page = selection.pages.first, let document = view.document else {
                return model.unselected()
            }
            let range = selection.range(at: 0, on: page)
            guard range.location != NSNotFound, range.length > 0 else { return model.unselected() }
            let bounds = selection.bounds(for: page)
            let rect = ViewerGeometry.window(view.convert(bounds, from: page), in: view)
            if let key = model.openKey { model.fold(key) }
            model.selected(page: document.index(for: page), bounds: bounds, range: range, anchor: CGPoint(x: rect.maxX, y: rect.minY))
        }
    }
}

/// The PDF view, telling the model when the person clicks in the document (a margin note open there folds).
final class ViewerPDFView: PDFView {
    var clicked: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        clicked?()
        super.mouseDown(with: event)
    }
}

/// The pages as pictures, for snapshots (PDFKit's own view draws nothing there): one slide, or the pages
/// scrolling, where PDFKit puts them.
struct ViewerPagesPicture: View {
    let model: ViewerModel

    var body: some View {
        GeometryReader { geometry in
            let frames = ViewerSnapshotPages.frames(model, area: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(frames.keys.sorted(), id: \.self) { index in
                    let frame = frames[index]!
                    Group {
                        if let image = model.thumbs[index] { Image(nsImage: image).resizable() } else { Color.white }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .background(.white)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .clipped()
    }
}

/// Where PDFKit's view would put each page in an area (snapshots): a slide fitted and centered, pages at most 600
/// points wide, 20 points apart.
@MainActor
enum ViewerSnapshotPages {
    static func frames(_ model: ViewerModel, area: CGSize) -> [Int: CGRect] {
        guard model.pageCount > 0, let first = model.thumbs[0], first.size.width > 0 else { return [:] }
        let ratio = first.size.height / first.size.width
        if model.unit == .slide {
            // Fitted with 20 points around it and centered, as PDFKit's single page.
            let width = min(area.width - 40, (area.height - 40) / ratio)
            return [model.current: CGRect(x: (area.width - width) / 2, y: (area.height - width * ratio) / 2, width: width, height: width * ratio)]
        }
        let width = min(area.width - 80, 600)
        var frames: [Int: CGRect] = [:]
        var y: CGFloat = 20
        for index in 0..<model.pageCount {
            frames[index] = CGRect(x: (area.width - width) / 2, y: y, width: width, height: width * ratio)
            y += width * ratio + 20
            if y > area.height { break }
        }
        return frames
    }
}

// MARK: - The margin

/// The notes on this file, in the margin: those on a page shown lined up with their passage (found again by its
/// words) or their page's top, the one open with the keyboard, those on other pages folded below in page order,
/// and those on the whole file (or whose passage moved) stacked below them. The margin scrolls in step with the
/// pages (scrolling either scrolls both), so nothing is out of reach and everything lined up stays lined up; with
/// one slide at a time it scrolls on its own. Every paper of a note shows, one of a conflict's read only with Keep
/// this one, as on the desk. Clicking a folded one opens it (and goes to its page); right-click: follow the
/// selection (the reading lens).
struct ViewerMarginView: View {
    let model: ViewerModel
    let size: CGSize
    @Environment(\.snapshotting) private var snapshotting
    @State private var position = ScrollPosition(edge: .top)

    var body: some View {
        let notes = model.notes
        let layout = Self.placed(model, notes, visible: size.height - ViewerLook.bar)
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.5)
            ViewerLook.line.frame(width: 1).frame(maxHeight: .infinity)
            if snapshotting {
                content(notes, layout)
            } else {
                ScrollView(.vertical) { content(notes, layout) }
                    .scrollIndicators(.automatic)
                    .scrollPosition($position)
                    .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, offset in model.marginScrolled(offset) }
                    // The pages scrolled: the margin follows them.
                    .onChange(of: model.docScroll) { _, offset in
                        if model.scrolls, abs(offset - model.marginOffset) > 0.5 { position.scrollTo(y: offset) }
                    }
            }
        }
        // Its content from the top, however tall (never centered up over the bar).
        .frame(width: ViewerLook.margin, height: max(0, size.height - ViewerLook.bar), alignment: .topLeading)
        .clipped()
    }

    private func content(_ notes: [(paper: PaperNote, place: NoteStick)], _ layout: (spots: [String: Spot], height: CGFloat)) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: ViewerLook.margin, height: layout.height)
            // By the note's identity, so a rename keeps the same editor and what's typed in it (ViewerPaperID).
            ForEach(notes.map { (id: model.paperID($0.paper), item: $0) }, id: \.id) { entry in
                let item = entry.item
                if let spot = layout.spots[item.paper.key] {
                    paper(item.paper, item.place)
                        .rotationEffect(.degrees(spot.tilt))
                        .offset(x: spot.x, y: spot.y)
                        .zIndex(model.openKey == item.paper.key ? 2 : 1)
                }
            }
            if let answer = model.lensAnswer, let spot = model.lensSpot {
                ViewerLensSlot(answer: answer, color: color(answer.request.noteID))
                    .offset(x: 18, y: max(8, spot.minY - ViewerLook.bar + (model.scrolls ? model.docScroll : 0)))
                    .zIndex(3)
            }
        }
    }

    struct Spot { var x: CGFloat; var y: CGFloat; var tilt: Double }

    func color(_ noteID: String) -> NSColor {
        model.desk.store.notes.first { $0.noteID == noteID }.map { model.desk.store.color(of: $0.notebook) } ?? .controlAccentColor
    }

    /// Each paper's spot in the margin's content (its top-left corner) and the content's height: the one layout the
    /// papers and the lines to their passages both use. The content is the pages' own length when they scroll (a
    /// spot there is its place in the window plus how far the pages have scrolled), so the two move in step.
    static func placed(_ model: ViewerModel, _ notes: [(paper: PaperNote, place: NoteStick)], visible: CGFloat) -> (spots: [String: Spot], height: CGFloat) {
        let top = ViewerLook.marginTop
        let single = !model.scrolls
        let shift = model.scrolls ? model.docScroll : 0
        var aligned: [(id: String, y: CGFloat, height: CGFloat)] = []
        var others: [(id: String, page: Int?, top: Double)] = []
        for (paper, place) in notes {
            let key = paper.key
            let height = model.heights[key] ?? PaperLook.folded
            let spot = model.spot(paper, place)
            if let highlight = model.highlights[key] {
                aligned.append((key, highlight.midY - 28 - ViewerLook.bar + shift, height))
            } else if let index = spot.page, let pageTop = model.pageTops[index], !(single && index != model.current) {
                aligned.append((key, pageTop - ViewerLook.bar + shift, height))
            } else {
                others.append((key, spot.page, Double(spot.bounds?.minY ?? 0)))
            }
        }
        var spots: [String: Spot] = [:]
        for (id, y) in ViewerMargin.layout(aligned.map { ($0.id, max($0.y, top), $0.height) }, top: top) { spots[id] = Spot(x: 18, y: y, tilt: 0) }
        // The rest below, as paper on a desk: a cascade of two columns, notes on other pages first, then those on
        // the whole file; an open one at the margin's full width on a row of its own (ViewerMargin.cascade).
        let floor = (aligned.compactMap { item in spots[item.id].map { $0.y + item.height } }.max() ?? top) + (aligned.isEmpty ? 0 : 40)
        let rest = ViewerMatch.order(others, current: single ? model.current : nil)
        for (id, spot) in ViewerMargin.cascade(rest.map { ($0, model.heights[$0] ?? PaperLook.folded, model.openKey == $0) }, floor: floor) {
            spots[id] = Spot(x: spot.x, y: spot.y, tilt: spot.tilt)
        }
        let notesEnd = (spots.map { id, spot in spot.y + (model.heights[id] ?? PaperLook.folded) }.max() ?? 0) + 40
        return (spots, max(notesEnd, model.scrolls ? model.docHeight : 0, visible))
    }

    @ViewBuilder
    private func paper(_ paper: PaperNote, _ place: NoteStick) -> some View {
        let desk = model.desk
        let open = model.openKey == paper.key
        let face: PaperFace = open ? model.face : .folded
        let color = desk.store.color(of: paper.notebook)
        let spot = model.spot(paper, place)
        let others = paper.file.places.count - 1
        let shortWhere = spot.moved ? "passage moved" : !place.quote.isEmpty ? (spot.page.map { "\(model.unit.word) \($0 + 1)" } ?? "this file")
            : place.spot.isEmpty ? "this file" : place.spot
        let longWhere = spot.moved ? place.label() + " · passage moved" : place.label()
        PaperView(paper: paper, color: color, glass: desk.glass, face: face, place: open ? longWhere : shortWhere, notebook: paper.notebook,
                  others: others == 1 ? paper.file.places.first { !$0.samePlace(place) }?.label() ?? "" : others > 1 ? "\(others) places" : "",
                  footer: model.lensKey == paper.key ? "Follows your selection" : desk.footer(paper),
                  keyboard: open, editorHeight: desk.heights[paper.key] ?? 0, desk: snapshotting || !model.marginEditable ? nil : desk,
                  conflict: desk.store.readOnly(paper), unsaved: desk.store.failed.contains(paper.key), pictureTrouble: desk.troubleCount(paper),
                  width: ViewerLook.openWidth, flipped: { model.flip(paper) }, folded: { model.fold(paper.key) })
            .background(GeometryReader { box in
                Color.clear.onAppear { model.heights[paper.key] = box.size.height }
                    .onChange(of: box.size.height) { _, height in model.heights[paper.key] = height }
            })
            .modifier(ViewerFolded(folded: !open, open: { model.openPaper(paper) }) {
                if model.lensKey == paper.key {
                    Button("Stop following my selection") { model.follow(nil) }
                } else {
                    Button("Follow my selection") { model.follow(paper.key) }
                }
                if let index = spot.page {
                    Button("Go to its \(model.unit.word)") { model.go(to: index) }
                }
            })
    }
}

/// A folded margin paper opens with a click and has its menu on a right-click; an open one leaves its clicks and
/// its menu to the editor.
struct ViewerFolded<Menu: View>: ViewModifier {
    let folded: Bool
    let open: () -> Void
    @ViewBuilder let menu: () -> Menu

    func body(content: Content) -> some View {
        if folded {
            content.contentShape(.rect).onTapGesture(perform: open).contextMenu { menu() }
        } else {
            content
        }
    }
}

/// The reading lens's slot: a short answer in Petal's ink beside the paragraph the selection is in.
struct ViewerLensSlot: View {
    let answer: ViewerLensAnswer
    let color: NSColor

    var body: some View {
        let tint = PaperLook.rgb(color)
        VStack(alignment: .leading, spacing: 1) {
            Text("✦ Petal").font(.system(size: 11, weight: .semibold)).opacity(0.85)
            Text(answer.text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(PaperLook.color(NoteInk.ink(tint)))
        .padding(.leading, 9)
        .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: color).opacity(0.4)).frame(width: 2) }
        .padding(10)
        .frame(width: ViewerLook.openWidth, alignment: .leading)
        .background(PaperLook.color(NoteInk.paper(tint)), in: .rect(cornerRadius: 10))
        .shadow(color: .black.opacity(0.1), radius: 6, y: 4)
    }
}

/// Each passage's highlight in its notebook's color (only a passage found again by its words), and the sketch's
/// dashed line from it to its note, wherever the margin has scrolled.
struct ViewerInk: View {
    let model: ViewerModel
    let size: CGSize

    var body: some View {
        let notes = model.notes
        let layout = ViewerMarginView.placed(model, notes, visible: size.height - ViewerLook.bar)
        Canvas { context, _ in
            let marginX = size.width - ViewerLook.margin
            let document = model.documentFrame == .zero ? CGRect(x: 0, y: ViewerLook.bar, width: marginX, height: size.height) : model.documentFrame
            let margin = CGRect(x: marginX, y: ViewerLook.bar, width: ViewerLook.margin, height: size.height - ViewerLook.bar)
            for (paper, _) in notes {
                guard let words = model.highlights[paper.key], words.intersects(document) else { continue }
                let color = Color(nsColor: model.desk.store.color(of: paper.notebook))
                let mark = words.insetBy(dx: -2, dy: -2)
                // Each line on its own, never one box over words that weren't selected.
                for line in model.highlightLines[paper.key] ?? [words] {
                    context.fill(Path(roundedRect: line.insetBy(dx: -2, dy: -2), cornerRadius: 3), with: .color(color.opacity(0.24)))
                }
                guard let spot = layout.spots[paper.key] else { continue }
                let target = CGRect(x: marginX + spot.x, y: spot.y + ViewerLook.bar - model.marginOffset, width: ViewerLook.openWidth,
                                    height: model.heights[paper.key] ?? PaperLook.folded)
                guard target.intersects(margin) else { continue }
                let points = ViewerMargin.pin(from: mark, to: target)
                var line = Path()
                line.move(to: points[0])
                line.addCurve(to: points[3], control1: points[1], control2: points[2])
                context.stroke(line, with: .color(color.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Versions

/// Versions made on copies, under the document: each copy's picture of the page shown, its name, and Use this,
/// scrolling sideways when there are more than fit. Picking one only tells whoever asked; the file itself is never
/// changed here.
struct ViewerVersionsStrip: View {
    let model: ViewerModel
    let set: ViewerVersionSet
    @Environment(\.snapshotting) private var snapshotting

    var body: some View {
        if snapshotting {
            row
        } else {
            ScrollView(.horizontal) { row }.scrollIndicators(.automatic)
        }
    }

    private var row: some View {
        let held = model.pickSuspended(set)
        return VStack(alignment: .leading, spacing: 8) {
            // Picks held back while the original isn't the one these were made from (the copies stay).
            if let held {
                Text(held).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(ViewerLook.caption)
                    .padding(.leading, 20).padding(.top, 12)
            }
            copies(held: held != nil)
        }
    }

    private func copies(held: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(set.versions) { version in
                VStack(alignment: .leading, spacing: 6) {
                    Group {
                        if version.refused {
                            Text("Can't be shown").font(.system(size: 11.5)).foregroundStyle(ViewerLook.caption)
                                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white)
                        } else if let thumb = version.thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit) } else { Color.white }
                    }
                    .frame(width: 200, height: 112)
                    .background(.white)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .overlay {
                        if set.picked == version.id {
                            Rectangle().stroke(Color(nsColor: .controlAccentColor), lineWidth: 3).padding(-3)
                        }
                    }
                    HStack(spacing: 0) {
                        Text(version.label + " · ").foregroundStyle(ViewerLook.caption)
                        if set.picked == version.id {
                            Text("Picked").foregroundStyle(ViewerLook.caption).fontWeight(.semibold)
                        } else if set.picked == nil, !version.refused, !held {
                            Button { model.use(version) } label: { Text("Use this").underline().foregroundStyle(ViewerLook.caption) }
                                .buttonStyle(.plain)
                                .help("Tell whoever made these that this is the one (the file itself isn't changed here)")
                        }
                    }
                    .font(.system(size: 11.5))
                }
                .frame(width: 200, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 20).padding(.trailing, 20).padding(.top, 14).padding(.bottom, 22)
    }
}
