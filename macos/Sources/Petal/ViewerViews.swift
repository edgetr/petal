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

    init(model: ViewerModel) {
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
        setFrameAutosaveName("PetalViewer")
    }

    override var canBecomeKey: Bool { true }

    /// The Edit menu's keys (⌘C, ⌘V, ⌘Z…) in the margin's editor, whether or not Petal's hidden menu gets them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" { performClose(nil); return true }
        return EditMenu.keyEquivalent(event, window: self, viewsHandled: super.performKeyEquivalent(with: event))
    }

    func windowDidBecomeKey(_ notification: Notification) { PetalApp.shared.paper.viewerFront() }

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
                        Color.clear.frame(width: ViewerLook.margin)
                    }
                }
                // The margin: its own paper-white column with the notes on this file.
                ViewerMarginView(model: model, size: size)
                    .frame(width: ViewerLook.margin, height: size.height - ViewerLook.bar)
                    .offset(x: size.width - ViewerLook.margin, y: ViewerLook.bar)
                // Highlights and the dashed lines to their notes, over everything, never in the way of a click.
                ViewerInk(model: model, size: size).allowsHitTesting(false)
                if let selection = model.selection, !snapshotting {
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
            ViewerBarButton(title: "New note") { model.newNote() }
                .help(model.unit == .slide ? "A note on this slide (or the passage you selected)" : "A note on this page (or the passage you selected)")
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
            } else if model.loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let problem = model.problem {
                Text(problem).font(.system(size: 13)).foregroundStyle(ViewerLook.caption).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.live {
                ViewerQuickLookView(url: model.url, version: model.updated)
            } else if model.document != nil {
                ViewerPDF(model: model, signature: signature)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What the margin's highlights depend on: the notes on this file and their places.
    private var signature: String {
        model.notes.map { "\($0.paper.noteID):\($0.place.page ?? 0):\($0.place.slide ?? 0):\($0.place.bounds ?? [])" }.joined(separator: ",")
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
        if context.coordinator.version != version {
            context.coordinator.version = version
            view.refreshPreviewItem()
        }
    }

    func makeCoordinator() -> Holder { Holder() }
    final class Holder { var version: Date? }
}

/// PDFKit's view: one slide at a time for a deck, the pages scrolling for anything else. It tells the model the page
/// shown, the selection (a Note), and where each note's passage and each page are as it scrolls and zooms.
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
            view.document = model.document
            if let page = model.document?.page(at: model.current) { view.go(to: page) }
        }
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
            DispatchQueue.main.async { [weak self] in self?.watchScrolling() }
        }

        private func watchScrolling() {
            guard let clip = view?.documentView?.enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSView.boundsDidChangeNotification, object: clip)
            relayout()
        }

        @objc private func pageChanged() {
            guard let view, let model, let page = view.currentPage, let document = view.document else { return }
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

        /// Where each passage's highlight and each page's top are now, in the window: the margin lines its notes
        /// up with them.
        func relayout() {
            guard let view, let model, let document = view.document, view.window != nil else { return }
            var highlights: [String: CGRect] = [:]
            var tops: [Int: CGFloat] = [:]
            let single = view.displayMode == .singlePage
            for (paper, place) in model.notes {
                guard let index = ViewerMatch.pageIndex(place, count: document.pageCount), let page = document.page(at: index) else { continue }
                if single, index != model.current { continue }
                tops[index] = ViewerGeometry.window(view.convert(page.bounds(for: .cropBox), from: page), in: view).minY
                if let b = place.bounds, place.page != nil {
                    highlights[paper.noteID] = ViewerGeometry.window(view.convert(CGRect(x: b[0], y: b[1], width: b[2], height: b[3]), from: page), in: view)
                }
            }
            if let page = document.page(at: model.current) {
                tops[model.current] = ViewerGeometry.window(view.convert(page.bounds(for: .cropBox), from: page), in: view).minY
            }
            let frame = ViewerGeometry.window(view.bounds, in: view)
            if model.highlights != highlights { model.highlights = highlights }
            if model.pageTops != tops { model.pageTops = tops }
            if model.documentFrame != frame { model.documentFrame = frame }
            if let selection = view.currentSelection, let page = selection.pages.first, model.selection != nil {
                let rect = ViewerGeometry.window(view.convert(selection.bounds(for: page), from: page), in: view)
                model.selection?.anchor = CGPoint(x: rect.maxX, y: rect.minY)
            }
            if model.lensAnswer != nil { model.lensPlaced() }
        }

        /// A selection on one page offers a Note (its page, bounds, words and the words around them), and, while a
        /// note follows the selection, asks the lens about its paragraph.
        @objc private func selectionChanged() {
            guard let view, let model else { return }
            guard let selection = view.currentSelection, selection.pages.count == 1, let page = selection.pages.first, let document = view.document,
                  let words = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else {
                if model.selection != nil { model.selection = nil }
                return
            }
            let index = document.index(for: page)
            let bounds = selection.bounds(for: page)
            let text = (page.string ?? "") as NSString
            let range = selection.range(at: 0, on: page)
            var before = "", after = ""
            if range.location != NSNotFound, NSMaxRange(range) <= text.length {
                let head = max(0, range.location - 80)
                before = text.substring(with: NSRange(location: head, length: range.location - head))
                let tailLength = min(80, text.length - NSMaxRange(range))
                after = text.substring(with: NSRange(location: NSMaxRange(range), length: tailLength))
            }
            let rect = ViewerGeometry.window(view.convert(bounds, from: page), in: view)
            model.selection = ViewerSelection(page: index, bounds: bounds, quote: words, before: before, after: after, anchor: CGPoint(x: rect.maxX, y: rect.minY))
            if let key = model.openKey { model.fold(key) }
            // The reading lens: the paragraph the selection is in, for the note that follows it.
            if model.lensNote != nil, range.location != NSNotFound, let swift = Range(range, in: text as String) {
                let full = text as String
                let paragraph = ViewerLens.paragraph(full, around: swift)
                let nsParagraph = NSRange(paragraph, in: full)
                let box = page.selection(for: nsParagraph)?.bounds(for: page) ?? bounds
                model.selectionSettled(page: index, paragraph: String(full[paragraph]), selected: words, bounds: box)
            }
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

/// Where PDFKit's view would put each page in an area (snapshots): a slide fitted with 40 points around it, pages at
/// 82% of the width, 20 points apart.
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

/// The notes on this file, in the margin: those on the page shown lined up with their passage (or their page's
/// top), the one open with the keyboard, those on other pages folded below it in page order, those on the whole
/// file at the top. Clicking a folded one opens it (and goes to its page); right-click: follow the selection (the
/// reading lens).
struct ViewerMarginView: View {
    let model: ViewerModel
    let size: CGSize
    @Environment(\.snapshotting) private var snapshotting

    var body: some View {
        let desk = model.desk
        let notes = model.notes
        let spots = Self.placed(model, notes)
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.5)
            ViewerLook.line.frame(width: 1).frame(maxHeight: .infinity)
            ForEach(notes, id: \.paper.noteID) { item in
                if let spot = spots[item.paper.noteID] {
                    paper(item.paper, item.place, desk: desk)
                        .rotationEffect(.degrees(spot.tilt))
                        .offset(x: spot.x, y: spot.y)
                        .zIndex(model.openNote == item.paper.noteID ? 2 : 1)
                }
            }
            if let answer = model.lensAnswer, let spot = model.lensSpot {
                ViewerLensSlot(answer: answer, color: color(answer.request.noteID))
                    .offset(x: 18, y: max(8, spot.minY - ViewerLook.bar))
                    .zIndex(3)
            }
        }
        .clipped()
    }

    struct Spot { var x: CGFloat; var y: CGFloat; var tilt: Double }

    func color(_ noteID: String) -> NSColor {
        model.desk.store.notes.first { $0.noteID == noteID }.map { model.desk.store.color(of: $0.notebook) } ?? .controlAccentColor
    }

    /// Each paper's spot in the margin (its top-left corner, in the margin's own coordinates): the one layout the
    /// papers and the lines to their passages both use.
    static func placed(_ model: ViewerModel, _ notes: [(paper: PaperNote, place: NoteStick)]) -> [String: Spot] {
        let top = ViewerLook.marginTop
        let count = model.pageCount
        let single = model.unit == .slide || model.live
        var aligned: [(id: String, y: CGFloat, height: CGFloat)] = []
        var others: [(id: String, page: Int?, top: Double)] = []
        for (paper, place) in notes {
            let id = paper.noteID
            let height = model.heights[id] ?? PaperLook.folded
            let index = ViewerMatch.pageIndex(place, count: count)
            if let highlight = model.highlights[id] {
                aligned.append((id, highlight.midY - 28 - ViewerLook.bar, height))
            } else if let index, let pageTop = model.pageTops[index], !(single && index != model.current) {
                aligned.append((id, pageTop - ViewerLook.bar, height))
            } else if index == nil, model.openNote == id || !single {
                // On the whole file: at the top.
                aligned.append((id, top - 1, height))
            } else {
                others.append((id, index, Double(place.bounds?[1] ?? 0)))
            }
        }
        // Lined up where they can be; scrolled away above the margin, out of sight.
        var spots: [String: Spot] = [:]
        let visible = aligned.filter { $0.y + $0.height > 0 || $0.y == top - 1 }
        for (id, y) in ViewerMargin.layout(visible.map { ($0.id, max($0.y, top), $0.height) }, top: top) { spots[id] = Spot(x: 18, y: y, tilt: 0) }
        // The rest folded below, as paper on a desk: a cascade of two columns.
        var floor = (visible.compactMap { item in spots[item.id].map { $0.y + item.height } }.max() ?? top) + 40
        for (offset, id) in ViewerMatch.order(others, current: single ? model.current : nil).enumerated() {
            let right = offset % 2 == 1
            spots[id] = Spot(x: right ? 165 : 30, y: floor, tilt: right ? 2 : 0)
            floor += right ? PaperLook.folded + 12 : 70
        }
        return spots
    }

    @ViewBuilder
    private func paper(_ paper: PaperNote, _ place: NoteStick, desk: NoteDesk) -> some View {
        let open = model.openNote == paper.noteID
        let face: PaperFace = open ? model.face : .folded
        let color = desk.store.color(of: paper.notebook)
        let others = paper.file.places.count - 1
        let where_ = open ? place.label() : (place.spot.isEmpty ? (place.quote.isEmpty ? "this file" : "this passage") : place.spot)
        PaperView(paper: paper, color: color, glass: desk.glass, face: face, place: where_, notebook: paper.notebook,
                  others: others == 1 ? paper.file.places.first { !$0.samePlace(place) }?.label() ?? "" : others > 1 ? "\(others) places" : "",
                  footer: model.lensNote == paper.noteID ? "Follows your selection" : desk.footer(paper),
                  keyboard: open, editorHeight: desk.heights[paper.key] ?? 0, desk: snapshotting ? nil : desk,
                  conflict: desk.store.readOnly(paper), unsaved: desk.store.failed.contains(paper.key), pictureTrouble: desk.troubleCount(paper),
                  width: ViewerLook.openWidth, flipped: { model.flip() }, folded: { model.fold(paper.key) })
            .background(GeometryReader { box in
                Color.clear.onAppear { model.heights[paper.noteID] = box.size.height }
                    .onChange(of: box.size.height) { _, height in model.heights[paper.noteID] = height }
            })
            .modifier(ViewerFolded(folded: !open, open: { model.openPaper(paper) }) {
                if model.lensNote == paper.noteID {
                    Button("Stop following my selection") { model.follow(nil) }
                } else {
                    Button("Follow my selection") { model.follow(paper.noteID) }
                }
                if let index = ViewerMatch.pageIndex(place, count: model.pageCount) {
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

/// Each passage's highlight in its notebook's color, and the sketch's dashed line from it to its note.
struct ViewerInk: View {
    let model: ViewerModel
    let size: CGSize

    var body: some View {
        let notes = model.notes
        let spots = ViewerMarginView.placed(model, notes)
        Canvas { context, _ in
            let marginX = size.width - ViewerLook.margin
            let document = model.documentFrame == .zero ? CGRect(x: 0, y: ViewerLook.bar, width: marginX, height: size.height) : model.documentFrame
            for (paper, _) in notes {
                guard let words = model.highlights[paper.noteID], words.intersects(document) else { continue }
                let color = Color(nsColor: model.desk.store.color(of: paper.notebook))
                let mark = words.insetBy(dx: -2, dy: -2)
                context.fill(Path(roundedRect: mark, cornerRadius: 3), with: .color(color.opacity(0.24)))
                guard let spot = spots[paper.noteID] else { continue }
                let target = CGRect(x: marginX + spot.x, y: spot.y + ViewerLook.bar, width: ViewerLook.openWidth, height: model.heights[paper.noteID] ?? PaperLook.folded)
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

/// Versions made on copies, under the document: each copy's picture of the page shown, its name, and Use this.
/// Picking one only tells whoever asked; the file itself is never changed here.
struct ViewerVersionsStrip: View {
    let model: ViewerModel
    let set: ViewerVersionSet

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(set.versions) { version in
                VStack(alignment: .leading, spacing: 6) {
                    Group {
                        if let thumb = version.thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit) } else { Color.white }
                    }
                    .frame(width: 200, height: 112)
                    .background(.white)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .overlay {
                        if set.picked == version.label {
                            Rectangle().stroke(Color(nsColor: .controlAccentColor), lineWidth: 3).padding(-3)
                        }
                    }
                    HStack(spacing: 0) {
                        Text(version.label + " · ").foregroundStyle(ViewerLook.caption)
                        if set.picked == version.label {
                            Text("Picked").foregroundStyle(ViewerLook.caption).fontWeight(.semibold)
                        } else if set.picked == nil {
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
        .padding(.leading, 20).padding(.top, 14).padding(.bottom, 22)
    }
}
