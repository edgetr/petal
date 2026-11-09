import AppKit
import Observation
import PDFKit
import SwiftUI
import WebKit

/// Petal's viewer (Petal Notes' fourth phase): a window of Petal's own for a document, with the notes on that file
/// in a real margin. A PDF through PDFKit (its pages on the left, the page in the middle, notes lined up with their
/// passages and a dashed line to each passage's highlight); Word, PowerPoint, Keynote, Excel and every other
/// document through macOS's own Quick Look preview (its pages exported, else Quick Look's own view), with notes per
/// page or slide; never an Office engine of Petal's. Opening a file never moves or changes it, and nothing of it
/// is read or drawn on the main thread: reading, Quick Look, pages and thumbnails happen off it. The viewer
/// reloads when the file changes on disk ("Updated just now"). Its margin papers are the notes themselves, edited
/// through their sessions as on any window (the desk's `write`); a note open here is open nowhere else.
@MainActor @Observable
final class Viewers {
    static let tools: Set<String> = ["petal_view", "petal_view_versions", "petal_view_pick", "petal_note_pdf_comments"]
    /// Reading files, Quick Look, thumbnails and copies: never the main thread.
    nonisolated static let queue = DispatchQueue(label: "petal.viewer", qos: .userInitiated, attributes: .concurrent)

    private(set) var open: [ViewerModel] = []
    @ObservationIgnored private var windows: [UUID: ViewerWindow] = [:]
    /// Every set of versions made, by id: the copies, who asked, and the pick once made (for `petal_view_pick`).
    @ObservationIgnored var versionSets: [String: ViewerVersionSet] = [:]

    var app: PetalApp { PetalApp.shared }

    /// Opens `path` (a note's file, a drop, an agent's path): checked off the main thread (ViewerPath: a regular file
    /// the person owns, never through a link out of the home folder, of a kind the viewer shows), then shown in its
    /// own window, or the one already showing it brought forward. `page`: counted from 1.
    func open(path: String, page: Int? = nil, show: Bool = true, done: @escaping @MainActor (Result<ViewerModel, ViewerPath.Refusal>) -> Void = { _ in }) {
        let home = NSHomeDirectory()
        Self.queue.async {
            let checked = ViewerPath.check(path, home: home)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch checked {
                    case .failure(let refusal): done(.failure(refusal))
                    case .success(let url): done(.success(self.show(url, page: page, front: show)))
                    }
                }
            }
        }
    }

    /// The model for a checked file, made or found, and its window shown.
    @discardableResult
    func show(_ url: URL, page: Int? = nil, front: Bool = true) -> ViewerModel {
        if let model = open.first(where: { $0.url.path == url.path }) {
            if let page { model.go(to: page - 1) }
            if front, let window = windows[model.id] { PetalWindow.bringForward(window) }
            return model
        }
        let model = ViewerModel(url: url, kind: ViewerKind.of(url.path) ?? .quickLook(.page))
        model.wanted = page.map { $0 - 1 }
        open.append(model)
        if !Headless.on {
            let window = ViewerWindow(model: model)
            windows[model.id] = window
            window.onClose = { [weak self] in self?.closed(model) }
            if front { PetalWindow.bringForward(window) }
        }
        model.load()
        return model
    }

    /// The model showing `path` (as opened, or as the disk spells it).
    func model(for path: String) -> ViewerModel? {
        open.first { $0.url.path == path || $0.opened == path }
    }

    private func closed(_ model: ViewerModel) {
        model.close()
        open.removeAll { $0 === model }
        windows[model.id] = nil
    }

    /// Files dropped on the Petal Notes area (or on a viewer): each opens in the viewer. True when any could be.
    @discardableResult
    func dropped(_ urls: [URL]) -> Bool {
        let files = urls.filter { $0.isFileURL && ViewerKind.of($0.path) != nil }
        for file in files { open(path: file.path) { result in if case .failure(let refusal) = result { self.app.paper.tell(refusal.description) } } }
        return !files.isEmpty
    }

    /// For Petal --snapshot: a model with made-up pages, never a file read.
    func preview(_ model: ViewerModel) { open = [model] }
}

/// What a selection in a PDF offers a note: its page, bounds on it, words and the words around them.
struct ViewerSelection: Equatable {
    var page: Int
    var bounds: CGRect
    var quote: String
    var before: String
    var after: String
    /// Where its end is in the window (top-left origin), for the Note button.
    var anchor: CGPoint
}

/// One version made on a copy: its label ("Shorter"), the copy, and its picture of the page shown.
struct ViewerVersion: Identifiable, Equatable {
    var label: String
    var url: URL
    var thumb: NSImage?
    var id: String { label }

    static func == (a: ViewerVersion, b: ViewerVersion) -> Bool { a.label == b.label && a.url == b.url && a.thumb === b.thumb }
}

/// Versions made on copies, for whoever asked (a helper, an agent): the original is never changed by the viewer;
/// "Use this" only reports the pick back.
@MainActor @Observable
final class ViewerVersionSet {
    let id: String
    let asker: String
    let folder: URL
    var versions: [ViewerVersion]
    var picked: String?
    /// Waiting for the pick (`petal_view_pick` with `wait`, or Phase 2's helper): told once it's made or the
    /// viewer closes.
    @ObservationIgnored var waiting: [(ViewerVersion?) -> Void] = []
    var closed = false

    init(id: String, asker: String, folder: URL, versions: [ViewerVersion]) {
        self.id = id
        self.asker = asker
        self.folder = folder
        self.versions = versions
    }

    /// Phase 2's helpers: `done` once the person picks a version (nil: the viewer closed first, or newer versions
    /// replaced these). At once when that's already so.
    func whenPicked(_ done: @escaping (ViewerVersion?) -> Void) {
        if let picked, let version = versions.first(where: { $0.label == picked }) { return done(version) }
        if closed { return done(nil) }
        waiting.append(done)
    }

    func settle(_ version: ViewerVersion?) {
        let told = waiting
        waiting = []
        for wait in told { wait(version) }
    }
}

/// What the reading lens asks: the paragraph the person's selection is in (its words already through the vault's
/// redaction), for a note in the margin that follows the selection. Phase 2 answers it with `answerLens`.
struct ViewerLensRequest: Equatable, Sendable {
    var id = UUID()
    var noteID: String
    /// Counted from 1.
    var page: Int
    var paragraph: String
    var selected: String
    /// The paragraph's bounds on its page (the page's points).
    var bounds: CGRect
}

/// The answer beside the paragraph it's about.
struct ViewerLensAnswer: Equatable {
    var request: ViewerLensRequest
    var text: String
}

@MainActor @Observable
final class ViewerModel: Identifiable {
    let id = UUID()
    /// The file as the disk spells it (every link followed), and the path it was opened by.
    private(set) var url: URL
    @ObservationIgnored var opened: String
    let kind: ViewerKind
    var unit: ViewerUnit { kind.unit }
    var name: String { url.lastPathComponent }

    /// Its pages: the PDF, or what Quick Look exported. Only ever used on the main thread; the data is kept to make
    /// thumbnails from its own copy off it.
    private(set) var document: PDFDocument?
    @ObservationIgnored private(set) var data: Data?
    /// Quick Look's own view, when no pages could be exported: notes are on the file (or the page they say).
    private(set) var live = false
    private(set) var pageCount = 0
    var current = 0
    /// The page to show once loaded (0-based).
    @ObservationIgnored var wanted: Int?
    private(set) var thumbs: [Int: NSImage] = [:]
    private(set) var loading = true
    private(set) var problem: String?
    /// When the file last changed on disk while it was showing ("Updated just now").
    private(set) var updated: Date?
    /// The app that opens it ("Open in PowerPoint"), found off the main thread.
    private(set) var appName = ""
    @ObservationIgnored private var appURL: URL?

    /// A PDF selection that may become a note's passage.
    var selection: ViewerSelection?
    /// The margin note open for writing (by note id), and turned over or not.
    var openNote: String?
    var face: PaperFace = .open
    /// Where each margin note's passage is (by note id), and each page shown's top, in the window (top-left origin).
    var highlights: [String: CGRect] = [:]
    var pageTops: [Int: CGFloat] = [:]
    /// The document's area in the window.
    var documentFrame: CGRect = .zero
    /// Each margin paper's height, as drawn.
    var heights: [String: CGFloat] = [:]
    /// Versions on copies under the document.
    var versions: ViewerVersionSet?

    // MARK: The reading lens

    /// The margin note that follows the selection (by note id), and the answer beside the current paragraph.
    var lensNote: String?
    var lensAnswer: ViewerLensAnswer?
    /// Where the paragraph a lens request is about is, in the window.
    var lensSpot: CGRect?
    /// Phase 2 (or Phase 5) connects the AI here: called with each paragraph the selection settles in while a note
    /// follows it; answered with `answerLens`.
    @ObservationIgnored var onLens: ((ViewerLensRequest) -> Void)?
    @ObservationIgnored private(set) var lensRequest: ViewerLensRequest?

    @ObservationIgnored weak var pdfView: PDFView?
    @ObservationIgnored private var watcher: ViewerWatch?
    @ObservationIgnored private var stamp: ViewerUpdated.Stamp?
    @ObservationIgnored private var loads = 0
    @ObservationIgnored private var closedNow = false
    @ObservationIgnored private var lensSoon: DispatchWorkItem?

    init(url: URL, kind: ViewerKind) {
        self.url = url
        opened = url.path
        self.kind = kind
    }

    var app: PetalApp { PetalApp.shared }
    var desk: NoteDesk { app.paper }

    /// For Petal --snapshot: made-up pages (drawn, never read from a file).
    func preview(pages: [NSImage], current: Int, app: String = "Preview") {
        thumbs = Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($0, $1) })
        pageCount = pages.count
        self.current = current
        appName = app
        loading = false
    }

    // MARK: Loading

    /// Reads the file off the main thread (coordinated, so a file iCloud hasn't downloaded comes down first): a PDF
    /// as it is, anything else through Quick Look's preview, exported as pages where Quick Look gives them. Never
    /// writes it. A newer load (the file changed again) makes an older one stand down.
    func load() {
        loads += 1
        let ticket = loads
        let url = url
        let kind = kind
        Viewers.queue.async {
            let read = ViewerLoader.read(url, kind: kind)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ticket == self.loads, !self.closedNow else { return }
                    self.loaded(read, ticket: ticket)
                }
            }
        }
    }

    private func loaded(_ read: ViewerLoader.Read, ticket: Int) {
        if appName.isEmpty { appName = read.appName; appURL = read.appURL }
        let first = stamp == nil
        stamp = read.stamp
        if !first { updated = Date() }
        switch read.pages {
        case .pdf(let data): show(data, ticket: ticket)
        case .web(let preview):
            // Quick Look's HTML preview made into pages: WebKit lays it out (out of process), the pages are cut
            // off the main thread.
            ViewerWeb.pages(preview) { data in
                guard ticket == self.loads, !self.closedNow else { return }
                if let data { self.show(data, ticket: ticket) } else { self.goLive() }
            }
        case .live: goLive()
        case .failed(let text):
            loading = false
            problem = text
        }
        if watcher == nil { watch() }
    }

    /// The pages parsed off the main thread, then shown.
    private func show(_ data: Data, ticket: Int) {
        Viewers.queue.async {
            let parsed = ViewerCarry(PDFDocument(data: data))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ticket == self.loads, !self.closedNow else { return }
                    guard let document = parsed.value as? PDFDocument else { return self.goLive() }
                    self.present(document, data)
                }
            }
        }
    }

    private func present(_ document: PDFDocument, _ data: Data) {
        let keep = document.pageCount > 0 ? min(wanted ?? current, document.pageCount - 1) : 0
        wanted = nil
        self.data = data
        self.document = document
        live = false
        pageCount = document.pageCount
        current = max(0, keep)
        loading = false
        problem = nil
        thumbs = [:]
        renderThumbs(data)
        if let page = document.page(at: current) { pdfView?.go(to: page) }
        versions.map { refreshVersions($0) }
    }

    private func goLive() {
        document = nil
        data = nil
        live = true
        pageCount = 0
        loading = false
        problem = nil
    }

    /// The pages' thumbnails from a copy of the document of their own, off the main thread, a few at a time.
    private func renderThumbs(_ data: Data) {
        let ticket = loads
        Viewers.queue.async {
            guard let document = PDFDocument(data: data) else { return }
            var batch: [Int: NSImage] = [:]
            for index in 0..<min(document.pageCount, 400) {
                guard let page = document.page(at: index) else { continue }
                batch[index] = page.thumbnail(of: CGSize(width: 300, height: 170), for: .cropBox)
                if batch.count == 8 || index == document.pageCount - 1 {
                    let sent = batch
                    batch = [:]
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard ticket == self.loads else { return }
                            self.thumbs.merge(sent) { $1 }
                        }
                    }
                }
            }
        }
    }

    // MARK: Keeping up with the file

    /// The file and its folder watched: a change (saved in place, or replaced as PowerPoint and Keynote save) is
    /// read again once it settles; a file moved or renamed is followed by its bookmark.
    private func watch() {
        guard !Headless.on else { return }
        watcher = ViewerWatch(url: url) { [weak self] in self?.changed() }
    }

    @ObservationIgnored private var bookmark: Data?

    private func changed() {
        let url = url
        let before = stamp
        let kept = bookmark
        Viewers.queue.async {
            let bookmark = kept ?? ViewerLoader.bookmark(url)
            var now = ViewerLoader.stamp(url)
            var moved: URL?
            if now == nil, let bookmark, let found = ViewerLoader.follow(bookmark), found.path != url.path {
                moved = found
                now = ViewerLoader.stamp(found)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !self.closedNow else { return }
                    if self.bookmark == nil { self.bookmark = bookmark }
                    if let moved { self.url = moved }
                    guard let now, now != before else { return }
                    // Replaced (a new file swapped in, as most apps save): the new one is watched from now on.
                    if moved != nil || now.inode != before?.inode { self.watcher = nil; self.watch() }
                    self.load()
                }
            }
        }
    }

    func close() {
        closedNow = true
        watcher = nil
        lensSoon?.cancel()
        if let key = openKey { fold(key) }
        if let set = versions {
            set.closed = true
            set.settle(nil)
        }
    }

    // MARK: Pages

    func go(to index: Int) {
        guard index >= 0 else { return }
        guard let document else { wanted = index; return }
        guard index < document.pageCount, let page = document.page(at: index) else { return }
        current = index
        pdfView?.go(to: page)
    }

    /// Open in the app that opens it ("Open in PowerPoint"): the person's own app, the file as it is.
    func openInApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        if let appURL { NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) }
        else { NSWorkspace.shared.open(url) }
    }

    // MARK: Notes in the margin

    /// The notes on this file and where each is (its place's index), most specific place first.
    var notes: [(paper: PaperNote, place: NoteStick)] {
        desk.store.notes.compactMap { paper in
            guard paper.version == nil, let index = ViewerMatch.place(paper.file.places, path: url.path, also: [opened]) else { return nil }
            return (paper, paper.file.places[index])
        }
    }

    /// The paper key of the note open here.
    var openKey: String? { openNote.flatMap { id in desk.store.notes.first { $0.noteID == id }?.key } }

    /// Opens a margin note for writing here: closed wherever else it was open (one editor per note), and this one
    /// let go if the desk opens it (`heldByViewer`).
    func openPaper(_ paper: PaperNote) {
        if let key = openKey, key != paper.key { fold(key) }
        // Open in another viewer (a note on two files): closed there first.
        desk.heldByViewer.removeValue(forKey: paper.noteID)?()
        if desk.faces[paper.key] == .open || desk.faces[paper.key] == .back { desk.fold(paper.key) }
        openNote = paper.noteID
        face = .open
        desk.heldByViewer[paper.noteID] = { [weak self] in
            guard let self, let key = self.openKey else { return }
            self.fold(key)
        }
        if let index = notes.first(where: { $0.paper.noteID == paper.noteID }).flatMap({ ViewerMatch.pageIndex($0.place, count: pageCount) }), index != current {
            go(to: index)
        }
    }

    /// Folds the note open here: what's typed saved first, and a note made here and left empty let go of.
    func fold(_ key: String) {
        guard let paper = desk.store.paper(key), paper.noteID == openNote else { return }
        desk.editors[key]?.flush()
        desk.heldByViewer[paper.noteID] = nil
        openNote = nil
        desk.letGoIfEmpty(key)
    }

    func flip() { face = face == .back ? .open : .back }

    /// A new note here: on the selection's passage (exact: its page and bounds), else on the page or slide shown,
    /// else on the file. A file anchor all the same, so Preview and Acrobat show it on the file (AXDocument). Its
    /// words are checked against the vault first (off the main thread): a selection holding a secret makes no note.
    func newNote() {
        var stick = NoteStick(kind: .file)
        stick.path = url.path
        stick.title = name
        let chosen = selection
        if !live, pageCount > 0 {
            if unit == .slide { stick.slide = current + 1 } else { stick.page = current + 1 }
        }
        if let chosen {
            stick.page = chosen.page + 1
            stick.slide = nil
            stick.bounds = [chosen.bounds.minX, chosen.bounds.minY, chosen.bounds.width, chosen.bounds.height]
            stick.quote = String(chosen.quote.prefix(500))
            stick.before = String(chosen.before.suffix(80))
            stick.after = String(chosen.after.prefix(80))
        }
        let words = [stick.quote, stick.before, stick.after].filter { !$0.isEmpty }
        let url = url
        Viewers.queue.async {
            // A bookmark, so the note follows the file when it's moved or renamed (made off the main thread).
            stick.bookmark = ViewerLoader.bookmark(url)?.base64EncodedString() ?? ""
            // A passage's words checked against the vault; unreadable, nothing counts as checked, so no note on it.
            let secret = words.isEmpty ? false : VaultIndex.settled { index in index.unreadable ? true : words.contains { index.redacted($0) != $0 } } ?? true
            let made = stick
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if secret { return self.desk.tell("That selection holds something from your vault: Petal makes no note on it.") }
                    if chosen != nil { self.selection = nil }
                    self.make(made)
                }
            }
        }
    }

    private func make(_ stick: NoteStick) {
        guard desk.on else { return desk.tell("Petal Notes is off.") }
        guard let paper = desk.make(on: stick, open: false) else { return }
        openPaper(paper)
    }

    // MARK: The reading lens (Phase 2 connects the AI)

    /// Marks a margin note to follow the selection (nil: none does).
    func follow(_ noteID: String?) {
        lensNote = noteID
        lensAnswer = nil
        lensSpot = nil
        lensRequest = nil
    }

    /// The selection settled: while a note follows it, the paragraph it's in is asked about (redacted with the
    /// vault's index off the main thread; the vault unreadable, nothing is asked).
    func selectionSettled(page: Int, paragraph: String, selected: String, bounds: CGRect) {
        guard let noteID = lensNote else { return }
        lensSoon?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Viewers.queue.async {
                let told = VaultIndex.settled { index in index.unreadable ? nil : (index.redacted(paragraph), index.redacted(selected)) } ?? nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let told, self.lensNote == noteID else { return }
                        let request = ViewerLensRequest(noteID: noteID, page: page + 1, paragraph: told.0, selected: told.1, bounds: bounds)
                        self.lensRequest = request
                        self.onLens?(request)
                    }
                }
            }
        }
        lensSoon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// A short answer beside the paragraph `request` is about (only while it's still the one asked about).
    func answerLens(_ text: String, for request: ViewerLensRequest) {
        guard request.id == lensRequest?.id, lensNote == request.noteID else { return }
        lensAnswer = ViewerLensAnswer(request: request, text: ViewerLens.short(text))
        lensPlaced()
    }

    /// Where the lens's paragraph is now, in the window.
    func lensPlaced() {
        guard let answer = lensAnswer, let view = pdfView, let page = document?.page(at: answer.request.page - 1) else { lensSpot = nil; return }
        lensSpot = ViewerGeometry.window(view.convert(answer.request.bounds, from: page), in: view)
    }

    // MARK: Versions on copies

    /// Makes a copy of the file for each label in a temporary folder of its own ("Roadmap (Shorter).pptx"), off
    /// the main thread, and shows them under the document with "Use this". Whoever asked edits the copies; their
    /// pictures follow the copies as they change. The original is never touched.
    func makeVersions(_ labels: [String], asker: String, then done: @escaping @MainActor (Result<ViewerVersionSet, ViewerCopyError>) -> Void) {
        let labels = ViewerCopies.labels(labels)
        guard !labels.isEmpty else { return done(.failure(.noLabels)) }
        let url = url
        let id = UUID().uuidString.prefix(8).lowercased()
        Viewers.queue.async {
            let folder = FileManager.default.temporaryDirectory.appending(path: "Petal Versions").appending(path: String(id))
            var made: [ViewerVersion] = []
            var failure: ViewerCopyError?
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var taken: Set<String> = []
                for label in labels {
                    let name = ViewerCopies.version(original: url.lastPathComponent, label: label, taken: taken)
                    taken.insert(name.lowercased())
                    let copy = folder.appending(path: name)
                    var error: NSError?
                    var copied = false
                    // Read coordinated (a file iCloud hasn't downloaded comes down first); the copy is the viewer's own.
                    NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &error) { readable in
                        copied = (try? FileManager.default.copyItem(at: readable, to: copy)) != nil
                    }
                    guard copied else { failure = .copy; break }
                    made.append(ViewerVersion(label: label, url: copy))
                }
            } catch { failure = .copy }
            let versions = made
            let failed = failure
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let failed { return done(.failure(failed)) }
                    if let older = self.versions {
                        older.closed = true
                        older.settle(nil)
                    }
                    let set = ViewerVersionSet(id: String(id), asker: asker, folder: folder, versions: versions)
                    self.versions = set
                    self.app.viewers.versionSets[set.id] = set
                    // The copies (edited in place, or replaced) and their folder: each change draws their pictures again.
                    self.versionWatch = ViewerWatch(paths: [folder.path] + versions.map(\.url.path)) { [weak model = self, weak set] in
                        guard let model, let set else { return }
                        model.refreshVersions(set)
                    }
                    self.refreshVersions(set)
                    done(.success(set))
                }
            }
        }
    }

    @ObservationIgnored private var versionWatch: ViewerWatch?

    /// Each copy's picture of the page shown, off the main thread (through the same loader: Quick Look for decks).
    func refreshVersions(_ set: ViewerVersionSet) {
        let page = current
        let kind = kind
        for version in set.versions {
            Viewers.queue.async {
                let read = ViewerLoader.read(version.url, kind: kind)
                let finish: @MainActor (Data?) -> Void = { data in
                    let carried = ViewerCarry(data)
                    Viewers.queue.async {
                        let image = (carried.value as? Data).flatMap { PDFDocument(data: $0) }.flatMap { $0.page(at: min(page, $0.pageCount - 1)) }?
                            .thumbnail(of: CGSize(width: 400, height: 224), for: .cropBox)
                        let picture = ViewerCarry(image)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let index = set.versions.firstIndex(where: { $0.label == version.label }) else { return }
                                set.versions[index].thumb = picture.value as? NSImage
                            }
                        }
                    }
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch read.pages {
                        case .pdf(let data): finish(data)
                        case .web(let preview): ViewerWeb.pages(preview) { finish($0) }
                        default: finish(nil)
                        }
                    }
                }
            }
        }
    }

    /// "Use this": the pick reported to whatever asked for it. Nothing is changed by the viewer itself.
    func use(_ version: ViewerVersion) {
        guard let set = versions, set.picked == nil else { return }
        set.picked = version.label
        set.settle(version)
    }
}

enum ViewerCopyError: Error, CustomStringConvertible {
    case noLabels, copy
    var description: String {
        switch self {
        case .noLabels: "Name each version (names: [\"Shorter\", \"With numbers\"])."
        case .copy: "Petal couldn't copy the file into a temporary folder: nothing was made."
        }
    }
}

final class ViewerCarry: @unchecked Sendable {
    let value: Any?
    init(_ value: Any?) { self.value = value }
}

// MARK: - Reading

/// What the viewer reads, off the main thread: the file's stamp, its pages (a PDF's bytes, or Quick Look's
/// preview), and the app that opens it.
enum ViewerLoader {
    enum Pages {
        case pdf(Data)
        case web(ViewerWeb.Preview)
        case live
        case failed(String)
    }

    struct Read {
        var pages: Pages
        var stamp: ViewerUpdated.Stamp?
        var appName: String
        var appURL: URL?
    }

    static func stamp(_ url: URL) -> ViewerUpdated.Stamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return ViewerUpdated.Stamp(size: Int64(info.st_size), modified: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9,
                                   inode: UInt64(info.st_ino))
    }

    static func bookmark(_ url: URL) -> Data? { try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }

    static func follow(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Off the main thread only.
    static func read(_ url: URL, kind: ViewerKind) -> Read {
        let app = NSWorkspace.shared.urlForApplication(toOpen: url)
        let appName = app.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? ""
        let stamp = stamp(url)
        guard stamp != nil else { return Read(pages: .failed("The file isn't there any more."), stamp: nil, appName: appName, appURL: app) }
        switch kind {
        case .pdf:
            var data: Data?
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &error) { readable in
                data = try? Data(contentsOf: readable)
            }
            guard let data, PDFDocument(data: data) != nil else { return Read(pages: .failed("Petal can't read this PDF."), stamp: stamp, appName: appName, appURL: app) }
            return Read(pages: .pdf(data), stamp: stamp, appName: appName, appURL: app)
        case .quickLook(let unit):
            return Read(pages: ViewerQuickLook.export(url, unit: unit), stamp: stamp, appName: appName, appURL: app)
        }
    }
}

/// macOS's own Quick Look preview of a document, exported to a temporary folder by Quick Look itself (qlmanage),
/// off the main thread: a PDF it gives (iWork's) is the pages; an HTML preview (Office's) is laid out by WebKit and
/// cut into slides or pages; nothing exported, Quick Look's own view shows it instead.
enum ViewerQuickLook {
    static func export(_ url: URL, unit: ViewerUnit) -> ViewerLoader.Pages {
        let out = FileManager.default.temporaryDirectory.appending(path: "Petal Viewer").appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Quick Look reads the file where it is. A file iCloud hasn't downloaded comes down first (a coordinated
        // read); Quick Look runs after it, so an app saving the file never waits on Petal.
        var error: NSError?
        var readable = url
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &error) { readable = $0 }
        let ran = error == nil && run(["/usr/bin/qlmanage", "-p", "-o", out.path, readable.path], timeout: 40)
        guard ran, let folder = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "qlpreview" }) else {
            try? FileManager.default.removeItem(at: out)
            return .live
        }
        let properties = (try? Data(contentsOf: folder.appending(path: "PreviewProperties.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let mime = properties["MimeType"] as? String ?? ""
        let html = (try? String(contentsOf: folder.appending(path: "Preview.html"), encoding: .utf8)) ?? ""
        switch ViewerPages.shape(mime: mime, html: html) {
        case .pdf(let name):
            let file = name.isEmpty ? folder.appending(path: "Preview.pdf") : folder.appending(path: name)
            let data = try? Data(contentsOf: file)
            try? FileManager.default.removeItem(at: out)
            guard let data, PDFDocument(data: data) != nil else { return .live }
            return .pdf(data)
        case .slides, .flowing:
            let width = (properties["Width"] as? NSNumber)?.doubleValue ?? 800
            let height = (properties["Height"] as? NSNumber)?.doubleValue ?? 1000
            return .web(ViewerWeb.Preview(folder: folder, cleanup: out, slides: html.contains("class=\"slide\"") || unit == .slide,
                                          width: width, height: height))
        case .none:
            try? FileManager.default.removeItem(at: out)
            return .live
        }
    }

    /// Runs a tool and waits for it (off the main thread), stopping it after `timeout` seconds.
    private static func run(_ arguments: [String], timeout: Double) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { return false }
        if ended.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
}

/// Quick Look's HTML preview made into pages: laid out by WebKit (in its own process), measured (each slide's box,
/// or where each block ends), drawn once as one long PDF, and cut into a page per slide or per page height off the
/// main thread. Its words stay text, so a passage there can be exact too.
@MainActor
final class ViewerWeb: NSObject, WKNavigationDelegate {
    struct Preview: @unchecked Sendable {
        var folder: URL
        var cleanup: URL
        var slides: Bool
        var width: Double
        var height: Double
    }

    private let preview: Preview
    private let web: WKWebView
    private let done: @MainActor (Data?) -> Void
    private var finished = false
    private static var running: Set<ViewerWeb> = []

    static func pages(_ preview: Preview, done: @escaping @MainActor (Data?) -> Void) {
        let job = ViewerWeb(preview, done: done)
        running.insert(job)
        job.start()
    }

    private init(_ preview: Preview, done: @escaping @MainActor (Data?) -> Void) {
        self.preview = preview
        self.done = done
        let configuration = WKWebViewConfiguration()
        // Quick Look's preview is the file's own content: nothing it says reaches the network or runs scripts of
        // its own beyond the measuring Petal does.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: max(320, preview.width), height: max(320, preview.height)), configuration: configuration)
        super.init()
        web.navigationDelegate = self
    }

    private func start() {
        web.loadFileURL(preview.folder.appending(path: "Preview.html"), allowingReadAccessTo: preview.folder)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.finish(nil) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only the preview's own files.
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let measure = preview.slides
            // A slide with no background of its own is white, as in its app (not Quick Look's grey page).
            ? "Array.from(document.querySelectorAll('div.slide')).map(function(e){if(getComputedStyle(e).backgroundColor==='rgba(0, 0, 0, 0)'){e.style.backgroundColor='white';}var r=e.getBoundingClientRect();return [r.left+window.scrollX,r.top+window.scrollY,r.width,r.height];})"
            : "[document.documentElement.scrollWidth, document.documentElement.scrollHeight].concat(Array.from(document.body.querySelectorAll('p,li,tr,h1,h2,h3,h4,img,table,div')).map(function(e){return e.getBoundingClientRect().bottom+window.scrollY;}))"
        webView.evaluateJavaScript(measure, in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            guard case .success(let value) = result else { return self.finish(nil) }
            self.measured(value)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(nil) }

    private func measured(_ value: Any) {
        var boxes: [CGRect] = []
        var size = CGSize(width: preview.width, height: preview.height)
        var bottoms: [CGFloat] = []
        if preview.slides {
            for item in value as? [[NSNumber]] ?? [] where item.count == 4 {
                boxes.append(CGRect(x: item[0].doubleValue, y: item[1].doubleValue, width: item[2].doubleValue, height: item[3].doubleValue))
            }
            guard !boxes.isEmpty else { return finish(nil) }
            size = CGSize(width: max(size.width, boxes.map(\.maxX).max() ?? 0), height: boxes.map(\.maxY).max() ?? size.height)
        } else {
            let numbers = (value as? [NSNumber] ?? []).map { CGFloat($0.doubleValue) }
            guard numbers.count >= 2 else { return finish(nil) }
            size = CGSize(width: max(numbers[0], 320), height: max(numbers[1], 320))
            bottoms = Array(numbers.dropFirst(2))
        }
        // The whole preview, laid out at its full height so every part is in the drawing.
        web.frame = NSRect(origin: .zero, size: size)
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        let pageHeight = preview.slides ? 0 : CGFloat(preview.width > 0 ? size.width * preview.height / preview.width : size.height)
        web.createPDF(configuration: configuration) { [weak self] result in
            guard let self else { return }
            guard case .success(let whole) = result else { return self.finish(nil) }
            let slides = boxes
            let ends = bottoms
            let total = size
            Viewers.queue.async {
                let data = ViewerWeb.cut(whole, slides: slides, bottoms: ends, size: total, pageHeight: pageHeight)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(data) } }
            }
        }
    }

    /// One long PDF page cut into pages, off the main thread: a page per slide box, or per page height at the ends
    /// of blocks (ViewerPages.cut).
    nonisolated static func cut(_ whole: Data, slides: [CGRect], bottoms: [CGFloat], size: CGSize, pageHeight: CGFloat) -> Data? {
        guard let source = PDFDocument(data: whole), let long = source.page(at: 0) else { return nil }
        let media = long.bounds(for: .mediaBox)
        // Points in the drawing per CSS pixel (createPDF draws at 1:1; any other scale is followed).
        let scale = media.height / max(1, size.height)
        let boxes: [CGRect] = slides.isEmpty
            ? ViewerPages.cut(bottoms: bottoms, height: pageHeight, total: size.height).map { CGRect(x: 0, y: $0.top, width: size.width, height: $0.bottom - $0.top) }
            : slides
        guard !boxes.isEmpty else { return nil }
        let out = PDFDocument()
        for (index, box) in boxes.enumerated() {
            guard let page = long.copy() as? PDFPage else { continue }
            let rect = CGRect(x: media.minX + box.minX * scale, y: media.maxY - box.maxY * scale, width: box.width * scale, height: box.height * scale)
            page.setBounds(rect, for: .mediaBox)
            page.setBounds(rect, for: .cropBox)
            out.insert(page, at: index)
        }
        return out.pageCount > 0 ? out.dataRepresentation() : nil
    }

    private func finish(_ data: Data?) {
        guard !finished else { return }
        finished = true
        web.stopLoading()
        let cleanup = preview.cleanup
        Viewers.queue.async { try? FileManager.default.removeItem(at: cleanup) }
        Self.running.remove(self)
        done(data)
    }
}

/// A file (and its folder) watched for changes, on the viewer's queue: saved in place, replaced (PowerPoint,
/// Keynote and most apps save a new file and swap it in), renamed or moved. Each burst is one call, once settled.
final class ViewerWatch: @unchecked Sendable {
    private var sources: [DispatchSourceFileSystemObject] = []
    private let changed: @MainActor () -> Void
    private var soon: DispatchWorkItem?
    private let lock = NSLock()

    convenience init(url: URL, changed: @escaping @MainActor () -> Void) {
        self.init(paths: [url.path, url.deletingLastPathComponent().path], changed: changed)
    }

    init(paths: [String], changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib, .link],
                                                                   queue: Viewers.queue)
            source.setEventHandler { [weak self] in self?.fire() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    private func fire() {
        lock.withLock {
            soon?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.changed() } }
            }
            soon = work
            Viewers.queue.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    deinit {
        soon?.cancel()
        for source in sources { source.cancel() }
    }
}

/// Converting between the PDF view's coordinates and the window's (top-left origin), for the margin, highlights
/// and pins.
@MainActor
enum ViewerGeometry {
    static func window(_ rect: CGRect, in view: NSView) -> CGRect {
        guard let content = view.window?.contentView else { return rect }
        let converted = view.convert(rect, to: content)
        return content.isFlipped ? converted : CGRect(x: converted.minX, y: content.bounds.height - converted.maxY, width: converted.width, height: converted.height)
    }
}

// MARK: - Notes as comments

/// "Write these notes into the PDF as comments": each note on the PDF as a comment where it's stuck (a passage's
/// highlight, else a sticky note at its page's top-left corner, the first page for one on the whole file). Into a
/// copy beside the original by default ("Report (with notes).pdf"); into the original only when asked, and then
/// the original is kept beside it first ("Report (before notes).pdf"). Every note's words go through the vault's
/// redaction (nothing from it is written while the vault can't be read). Off the main thread.
enum ViewerPDFComments {
    struct Comment: Sendable {
        var stick: NoteStick
        var text: String
        var color: NoteInk.RGB
    }

    enum Outcome { case wrote(URL, Int), failed(String) }

    static func write(_ pdf: URL, comments: [Comment], intoOriginal: Bool, author: String, _ done: @escaping @MainActor (Outcome) -> Void) {
        Viewers.queue.async {
            let outcome = make(pdf, comments: comments, intoOriginal: intoOriginal, author: author)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(outcome) } }
        }
    }

    private static func make(_ pdf: URL, comments: [Comment], intoOriginal: Bool, author: String) -> Outcome {
        guard !comments.isEmpty else { return .failed("No notes are on this PDF yet.") }
        let told = VaultIndex.settled { index in index.unreadable ? nil : comments.map { index.redacted($0.text) } } ?? nil
        guard let told else { return .failed("Your vault can't be read right now, so Petal wrote nothing (a note's words are checked first).") }
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: pdf, options: [.withoutChanges], error: &error) { readable in data = try? Data(contentsOf: readable) }
        guard let data, let document = PDFDocument(data: data), document.pageCount > 0 else { return .failed("Petal can't read this PDF.") }
        var written = 0
        for (comment, text) in zip(comments, told) where !text.isEmpty {
            guard let spot = ViewerComments.spot(comment.stick, pages: document.pageCount, pageSize: { document.page(at: $0)?.bounds(for: .cropBox).size ?? .zero }),
                  let page = document.page(at: spot.page) else { continue }
            let color = NSColor(srgbRed: comment.color.r, green: comment.color.g, blue: comment.color.b, alpha: 1)
            if let bounds = spot.bounds {
                let mark = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                mark.color = color.withAlphaComponent(0.35)
                mark.contents = text
                mark.userName = author
                page.addAnnotation(mark)
            }
            let note = PDFAnnotation(bounds: CGRect(origin: spot.corner, size: CGSize(width: 20, height: 20)), forType: .text, withProperties: nil)
            note.contents = text
            note.color = color
            note.userName = author
            page.addAnnotation(note)
            written += 1
        }
        guard written > 0 else { return .failed("No notes are on this PDF yet.") }
        let folder = pdf.deletingLastPathComponent()
        let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        let temp = folder.appending(path: ".petal-\(UUID().uuidString).pdf")
        guard document.write(to: temp) else { return .failed("Petal couldn't write beside the PDF (its folder may not be writable).") }
        if !intoOriginal {
            let copy = folder.appending(path: ViewerCopies.withNotes(original: pdf.lastPathComponent, taken: taken))
            do { try FileManager.default.moveItem(at: temp, to: copy) } catch {
                try? FileManager.default.removeItem(at: temp)
                return .failed("Petal couldn't write the copy beside the PDF.")
            }
            return .wrote(copy, written)
        }
        // Into the original: the original kept beside it first, then the new one put in its place, coordinated.
        let backup = folder.appending(path: ViewerCopies.beforeNotes(original: pdf.lastPathComponent, taken: taken))
        var failure: String?
        NSFileCoordinator().coordinate(writingItemAt: pdf, options: [.forReplacing], error: &error) { writable in
            do {
                try FileManager.default.copyItem(at: writable, to: backup)
                _ = try FileManager.default.replaceItemAt(writable, withItemAt: temp)
            } catch { failure = "Petal couldn't write into the PDF; it's as it was." }
        }
        if error != nil, failure == nil { failure = "Petal couldn't write into the PDF; it's as it was." }
        if let failure {
            try? FileManager.default.removeItem(at: temp)
            return .failed(failure)
        }
        return .wrote(pdf, written)
    }
}
