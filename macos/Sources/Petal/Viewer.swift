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

    init() {
        // Only the dock itself sweeps at launch (never a snapshot, bench, check or command, which may run beside it):
        // Quick Look exports a Petal before this one left behind (it quit or crashed mid-load), and version sets
        // older than a day (a Petal that quit or crashed with a viewer open).
        guard Self.sweepsAtLaunch(arguments: CommandLine.arguments, headless: Headless.on) else { return }
        Self.queue.async {
            ViewerExport.sweep()
            ViewerVersionStore.shared?.sweep()
        }
    }

    /// Whether this process sweeps what a Petal before it left behind: only the real dock (`PetalProcess`), never
    /// a headless run.
    nonisolated static func sweepsAtLaunch(arguments: [String], headless: Bool) -> Bool {
        !headless && PetalProcess.isDock(arguments: arguments)
    }

    /// Opens `path` (a note's file, a drop, an agent's path): checked off the main thread (ViewerPath: a regular file
    /// the person owns, never through a link out of the home folder, of a kind the viewer shows), then shown in its
    /// own window, or the one already showing it brought forward. `page`: counted from 1. `live`: whoever asked is
    /// still there (an agent's request), checked right before anything is shown: gone, nothing opens and `done`
    /// isn't called.
    func open(path: String, page: Int? = nil, show: Bool = true, live: @escaping @Sendable () -> Bool = { true },
              done: @escaping @MainActor (Result<ViewerModel, ViewerPath.Refusal>) -> Void = { _ in }) {
        guard live() else { return }
        Self.queue.async {
            let checked = ViewerPath.check(path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard live() else { return }
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
            model.ask(page: page)
            if front, let window = windows[model.id] { PetalWindow.bringForward(window) }
            return model
        }
        let model = ViewerModel(url: url, kind: ViewerKind.of(url.path) ?? .quickLook(.page))
        // Checked against the document once it's read (ViewerPages.index).
        model.wantedPage = page
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

    /// The viewer whose window has the keyboard, by its model's id (ViewerWindow): while it does, it's the desk's
    /// current place (NoteDesk.hereNow, stickHere, ⌃⌥N).
    @ObservationIgnored var keyID: UUID?

    /// The viewer that's the desk's current place now: the one with the keyboard, still open.
    var front: ViewerModel? { keyID.flatMap { id in open.first { $0.id == id } } }

    /// The model showing `path` (as opened, or as the disk spells it).
    func model(for path: String) -> ViewerModel? {
        open.first { $0.url.path == path || $0.opened == path }
    }

    /// A viewer's window closed (or `--viewer-check` done with it): the model closes and is let go.
    func closed(_ model: ViewerModel) {
        if keyID == model.id { keyID = nil }
        model.close()
        open.removeAll { $0 === model }
        windows[model.id] = nil
    }

    /// The notes' folder being switched: margins read only meanwhile (nothing in them takes typing the store would
    /// refuse).
    private(set) var switchingFolder = false

    /// The notes' folder switching (`true`, before the store stops taking changes): every margin's editor saved and
    /// closed; switched (`false`), the margins take typing again.
    func folderSwitching(_ now: Bool) {
        if now { for model in open { model.closeEditor() } }
        switchingFolder = now
    }

    /// Petal Notes turned on or off: every viewer's margin follows (ViewerModel.notesChanged).
    func notesChanged() {
        for model in open { model.notesChanged() }
    }

    /// The papers open in every viewer's margin whose window is on screen, as NoteShelf.picturesOnScreen counts papers
    /// (the pictures' retry and memory follow them as they do the desk's).
    func picturesShown() -> [(revealed: Bool, open: Bool, folder: String, body: String)] {
        open.flatMap { $0.picturesShown(visible: windows[$0.id]?.occlusionState.contains(.visible) == true) }
    }

    /// A note's file got another name (NoteStore's rekey): every viewer's records of that paper follow it.
    func rekeyed(_ old: String, _ new: String) {
        for model in open { model.rekeyed(old, new) }
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

/// What a selection in a PDF offers a note: its page and bounds on it, its words as shown, and the page's whole text
/// with where the selection is in it (UTF-16), so the passage is cut from the page's text only after all of it was
/// checked against the vault.
struct ViewerSelection: Equatable {
    var page: Int
    var bounds: CGRect
    var quote: String
    var pageText: String
    var range: NSRange
    /// Where its end is in the window (top-left origin), for the Note button.
    var anchor: CGPoint
}

/// A page's text read off the main thread from a copy of the document of its own (one per load, its pages' text
/// kept once read): what a selection or a passage needs of a page is never extracted on the main thread.
final class ViewerText: @unchecked Sendable {
    private let queue = DispatchQueue(label: "petal.viewer.text", qos: .userInitiated)
    private let data: Data
    private var document: PDFDocument?
    private var texts: [Int: String] = [:]

    init(_ data: Data) { self.data = data }

    /// A page's text, the words in `selected` (trimmed; empty when there are none: no selection to offer) and, for
    /// `paragraph` in it, its bounds on the page; all off the main thread, then `done` on it.
    func read(page: Int, selected: NSRange, paragraph: @escaping @Sendable (String) -> NSRange?,
              _ done: @escaping @MainActor (_ text: String?, _ words: String, _ box: CGRect?) -> Void) {
        queue.async {
            if self.document == nil { self.document = PDFDocument(data: self.data) }
            guard let document = self.document, let page = document.page(at: page) else {
                return DispatchQueue.main.async { MainActor.assumeIsolated { done(nil, "", nil) } }
            }
            let index = document.index(for: page)
            let text = self.texts[index] ?? (page.string ?? "")
            self.texts[index] = text
            let words = ViewerText.words(text, selected)
            let box = paragraph(text).flatMap { page.selection(for: $0)?.bounds(for: page) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(text, words, box) } }
        }
    }

    /// The selected words in a page's text: its range there, trimmed; empty when the range isn't in it.
    static func words(_ text: String, _ range: NSRange) -> String {
        let ns = text as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return "" }
        return ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Where a margin note's passage is in the document now: found again by its words (its page and bounds there), or
/// moved (it shows on the file, with no highlight).
enum ViewerFound: Equatable {
    /// Found: its page, its lines' union (where its note lines up) and each line's own rectangle (what's highlighted).
    case found(page: Int, bounds: CGRect, lines: [CGRect])
    case moved
}

/// One version made on a copy: its id in its set ("v2", what files, pictures and picks go by), its label for the
/// person ("Shorter", "Draft (2)"), the copy, and its picture of the page shown.
struct ViewerVersion: Identifiable, Equatable {
    var id: String
    var label: String
    var url: URL
    var thumb: NSImage?
    /// Its copy can't be read through its set's pinned folder (ViewerVersionStore): shown as "can't be shown".
    var refused = false

    static func == (a: ViewerVersion, b: ViewerVersion) -> Bool {
        a.id == b.id && a.label == b.label && a.url == b.url && a.thumb === b.thumb && a.refused == b.refused
    }
}

/// Versions made on copies, for whoever asked (a helper, an agent): the original is never changed by the viewer;
/// "Use this" only reports the pick back.
@MainActor @Observable
final class ViewerVersionSet {
    let id: String
    let asker: String
    let folder: URL
    var versions: [ViewerVersion]
    /// The id of the version picked.
    var picked: String?
    /// Waiting for the pick (`petal_view_pick` with `wait`, or Phase 2's helper): told once it's made or the
    /// viewer closes.
    @ObservationIgnored var waiting: [(ViewerVersion?) -> Void] = []
    var closed = false
    /// Its folder, pinned when it was made (ViewerVersionStore): every copy is read through it, never by its path.
    var pin: ViewerVersionStore.Pin?
    /// The original it was made from: its incarnation and stamp. Picks are offered and settle only while the
    /// viewer's loaded document is that very file, unchanged.
    var base: (id: ViewerFileID, stamp: ViewerUpdated.Stamp)?
    /// The viewer showing it (what's loaded there now is checked against `base`).
    @ObservationIgnored weak var viewer: ViewerModel?

    /// Where a pick stands: made, waiting, held back with why (the original changed, gone, refused or being read
    /// again), or closed.
    enum PickState { case picked(ViewerVersion), waiting, suspended(String), closed }

    var pickState: PickState {
        if closed { return .closed }
        if let reason = viewer?.pickSuspended(self) ?? (viewer == nil ? ViewerModel.originalChangedText : nil) { return .suspended(reason) }
        if let picked, let version = versions.first(where: { $0.id == picked }) { return .picked(version) }
        return .waiting
    }

    /// Its copies read one load at a time (the document's own lifecycle); closed when the set is retired.
    @ObservationIgnored let loads = ViewerLoads()
    /// Each version's picture drawn one at a time (by version id); closed with the set.
    @ObservationIgnored private var drawings: [String: ViewerLoads] = [:]

    func drawing(_ id: String) -> ViewerLoads {
        if let made = drawings[id] { return made }
        let made = ViewerLoads()
        drawings[id] = made
        return made
    }

    /// Retired or its viewer closed: its reading and every drawing stop at their next step, and nothing starts.
    func shut() {
        loads.close()
        for drawing in drawings.values { drawing.close() }
    }
    /// Each copy as it was when last read (by version id): unchanged, it isn't read again.
    @ObservationIgnored var seen: [String: ViewerVersionStore.Made] = [:]

    init(id: String, asker: String, folder: URL, versions: [ViewerVersion]) {
        self.id = id
        self.asker = asker
        self.folder = folder
        self.versions = versions
    }

    /// Phase 2's helpers: `done` once the person picks a version (nil: the viewer closed first, or newer versions
    /// replaced these). At once when that's already so.
    func whenPicked(_ done: @escaping (ViewerVersion?) -> Void) {
        switch pickState {
        case .picked(let version): done(version)
        case .closed, .suspended: done(nil)
        case .waiting: waiting.append(done)
        }
    }

    func settle(_ version: ViewerVersion?) {
        let told = waiting
        waiting = []
        for wait in told { wait(version) }
    }
}

/// What the reading lens asks: the paragraph the person's selection is in (its words through the vault's redaction,
/// the whole page checked first), for a note in the margin that follows the selection. Phase 2 answers it with
/// `answerLens`.
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

    /// Its pages: the PDF, or what Quick Look exported. Only ever used on the main thread; its bytes are kept to
    /// make thumbnails and find passages from a copy of their own off it.
    private(set) var document: PDFDocument?
    @ObservationIgnored private(set) var data: Data?
    /// Quick Look's own view, when no pages could be exported: notes are on the file (or the page they say).
    private(set) var live = false
    private(set) var pageCount = 0
    var current = 0 {
        didSet { if current != oldValue, let set = versions { drawVersions(set) } }
    }
    /// The PDF view being given a new document and sent to its page (ViewerPDF): its own page-change callbacks then
    /// aren't the person's scrolling and never write `current`.
    @ObservationIgnored var rebinding = false
    /// The page or slide asked for (from 1), shown once the document is read and only if it has it.
    @ObservationIgnored var wantedPage: Int?
    /// The notes' places that name this file (by ViewerFiles.key), each resolved on its own by the one resolver (its
    /// own file wherever it went, else its bookmark's, else its path's: never a path's spelling alone), and the file
    /// they were resolved for.
    private(set) var onFile: Set<String> = []
    /// Snapshots only: made-up places taken as on this file (nothing on disk to resolve).
    @ObservationIgnored var previewOnFile: ((NoteStick) -> Bool)?
    /// What a page's text is read from, off the main thread (ViewerText), for the pages shown now.
    @ObservationIgnored private(set) var text: ViewerText?
    /// Selections read and pictures drawn, the latest of each kept.
    @ObservationIgnored private var turns = ViewerTurns()
    private(set) var thumbs: [Int: NSImage] = [:]
    private(set) var loading = true {
        didSet {
            guard !loading, oldValue else { return }
            // The load is over: whoever waited for it, or for the file's identity (with it or without), goes on.
            settle(.load)
            settle(.identity)
        }
    }

    // MARK: Waiting

    /// How a wait ended: what it waited for is in, or the viewer closed first.
    enum Settled: Equatable { case ready, closed }
    /// What can be waited for. Every waiter is in one registry, so closing settles them all (`settleAll`) and a new
    /// kind can't be missed.
    enum WaitKind: Hashable, CaseIterable { case load, selection, identity, place }
    @ObservationIgnored private var waiters: [WaitKind: [(id: Int, then: @MainActor (Settled) -> Void)]] = [:]
    @ObservationIgnored private var waiterIDs = 0

    /// `then` once `kind` settles; at once (closed) when the viewer already is. Returns its registration, which
    /// `unwait` takes back once what it waited for finished on its own.
    @discardableResult
    private func wait(for kind: WaitKind, _ then: @escaping @MainActor (Settled) -> Void) -> Int {
        waiterIDs += 1
        guard !closedNow else { then(.closed); return waiterIDs }
        waiters[kind, default: []].append((waiterIDs, then))
        return waiterIDs
    }

    private func unwait(_ kind: WaitKind, _ id: Int) {
        waiters[kind]?.removeAll { $0.id == id }
    }

    private func settle(_ kind: WaitKind, _ outcome: Settled = .ready) {
        let told = waiters.removeValue(forKey: kind) ?? []
        for waiter in told { waiter.then(outcome) }
    }

    /// Every waiter told at once (closing: `.closed`).
    func settleAll(_ outcome: Settled) {
        for kind in WaitKind.allCases { settle(kind, outcome) }
    }

    /// How `whenLoaded` ended.
    enum LoadAnswer: Equatable { case loaded, stillLoading, closed }

    /// `.loaded` once the document is read (its pages, Quick Look's own view, or what went wrong), at once when it
    /// already is; `.stillLoading` if it's still being read after `seconds`; `.closed` when the viewer closes
    /// first. Told once.
    func whenLoaded(within seconds: Double, _ done: @escaping @MainActor (LoadAnswer) -> Void) {
        guard !closedNow else { return done(.closed) }
        guard loading else { return done(.loaded) }
        var answered = false
        let once: @MainActor (LoadAnswer) -> Void = { answer in
            guard !answered else { return }
            answered = true
            done(answer)
        }
        wait(for: .load) { once($0 == .closed ? .closed : .loaded) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { once(.stillLoading) }
    }
    private(set) var problem: String?
    /// When the file last changed on disk while it was showing ("Updated just now").
    private(set) var updated: Date?
    /// The app that opens it ("Open in PowerPoint"), found off the main thread.
    private(set) var appName = ""
    @ObservationIgnored private var appURL: URL?

    /// A PDF selection that may become a note's passage.
    var selection: ViewerSelection?
    /// The margin paper open for writing (by paper key: one of a conflict's papers is its own), turned over or not.
    var openKey: String? { didSet { if openKey != oldValue { NotePictures.shared.visibilityChanged() } } }
    var face: PaperFace = .open { didSet { if face != oldValue { NotePictures.shared.visibilityChanged() } } }
    /// Each margin note's passage, found again by its words in the pages shown (by paper key).
    private(set) var passages: [String: ViewerFound] = [:]
    /// Where each passage's highlight and each page shown's top are, in the window (top-left origin), by paper key and
    /// page.
    var highlights: [String: CGRect] = [:]
    /// Each passage's lines in the window (what's drawn: one rectangle per line), by paper key.
    var highlightLines: [String: [CGRect]] = [:]
    var pageTops: [Int: CGFloat] = [:]
    /// The document's area in the window.
    var documentFrame: CGRect = .zero
    /// How far the pages have scrolled from their top, and how tall they are (the window's points): the margin
    /// scrolls in step with them (pages scrolling; one slide at a time doesn't scroll).
    var docScroll: CGFloat = 0
    var docHeight: CGFloat = 0
    /// How far the margin is scrolled, as it says.
    var marginOffset: CGFloat = 0
    /// Each margin paper's height, as drawn (by paper key).
    var heights: [String: CGFloat] = [:]
    /// Versions on copies under the document.
    var versions: ViewerVersionSet?

    /// The pages scroll (a document), so the margin moves with them.
    var scrolls: Bool { unit == .page && !live }

    /// The margin shows (with its notes, highlights, New note and Note) only while Petal Notes is on; the document
    /// itself shows either way.
    var marginOn: Bool { app.config.bool("notes") }

    /// The paper open in this margin as a picture's visibility counts it: revealed while the window is on screen and
    /// the margin shows, open while it's turned face up.
    func picturesShown(visible: Bool) -> [(revealed: Bool, open: Bool, folder: String, body: String)] {
        guard let key = openKey, let paper = desk.store.paper(key) else { return [] }
        return [(visible && marginOn, face == .open, paper.url.deletingLastPathComponent().path, paper.file.body)]
    }

    /// The margin takes typing: Petal Notes on, its folder not being switched, and notes ready to take a change
    /// (NoteDesk.acceptsChanges: the folder entered, at launch and after a switch alike).
    var marginEditable: Bool { marginOn && !app.viewers.switchingFolder && desk.acceptsChanges }

    /// The paper open in the margin saved and closed (its editor goes; never let go of).
    func closeEditor() {
        if let key = openKey { close(key, .transfer) }
    }

    /// Petal Notes turned off: the paper open in the margin is saved and closed (its editor goes with the margin;
    /// never let go of), the selection's Note and the lens with it. On again, the margin shows again by itself.
    func notesChanged() {
        guard !marginOn else { return }
        if let key = openKey { close(key, .transfer) }
        unselected()
        follow(nil)
    }

    // MARK: The reading lens

    /// The margin note that follows the selection (by paper key), and the answer beside the current paragraph.
    var lensKey: String?
    var lensAnswer: ViewerLensAnswer?
    /// Where the paragraph a lens request is about is, in the window.
    var lensSpot: CGRect?
    /// Phase 2 (or Phase 5) connects the AI here: called with each paragraph the selection settles in while a note
    /// follows it; answered with `answerLens`.
    @ObservationIgnored var onLens: ((ViewerLensRequest) -> Void)?
    @ObservationIgnored private(set) var lensRequest: ViewerLensRequest?

    @ObservationIgnored weak var pdfView: PDFView?
    /// Scrolls the pages to a margin offset (PDFKit's view, set by its coordinator).
    @ObservationIgnored var scrollDocument: ((CGFloat) -> Void)?
    @ObservationIgnored private var watcher: ViewerWatch?
    @ObservationIgnored private var stamp: ViewerUpdated.Stamp?
    /// A bookmark to the file, made with each read (the file replaced: made again), so a move or rename is followed.
    @ObservationIgnored private var bookmark: Data?
    /// The file's incarnation as last read: a change follows it first (a renamed file stays the one shown, whatever
    /// took its old path).
    @ObservationIgnored private(set) var fileID: ViewerFileID?
    @ObservationIgnored private var loads = 0
    @ObservationIgnored private var closedNow = false
    /// `closedNow` as work off the main thread sees it.
    @ObservationIgnored private let closing = ViewerFlag()
    @ObservationIgnored private var lensSoon: DispatchWorkItem?

    init(url: URL, kind: ViewerKind) {
        self.url = url
        opened = url.path
        self.kind = kind
    }

    var app: PetalApp { PetalApp.shared }
    var desk: NoteDesk { app.paper }

    /// For Petal --snapshot: made-up pages (drawn, never read from a file).
    func preview(pages: [NSImage], current: Int, app: String = "Preview", passages: [String: ViewerFound] = [:]) {
        thumbs = Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($0, $1) })
        // A made-up loaded document: its own made-up identity (what a snapshot's versions are made from).
        previewing = true
        fileID = ViewerFileID(volume: "snapshot", inode: 1, created: 0)
        stamp = ViewerUpdated.Stamp(size: 0, modified: 0, inode: 1)
        pageCount = pages.count
        self.current = current
        appName = app
        loading = false
        self.passages = passages
    }

    // MARK: Loading

    /// Reads the file off the main thread (coordinated, so a file iCloud hasn't downloaded comes down first): a PDF
    /// as it is, anything else through Quick Look's preview, exported as pages where Quick Look gives them. Never
    /// writes it. A newer load (the file changed again) makes an older one stand down; what it exported is cleaned
    /// up all the same (ViewerExport).
    /// A reload (the file changed on disk, followed to where it went) is a load like the first: the viewer is
    /// loading again (whoever waits for it, `whenLoaded`, `whenIdentified`, waits for this one), and nothing about the
    /// file is kept from the load before as anchor state: no identity, bookmark or selection until this load's own
    /// checked read is in. The pages already shown stay on screen meanwhile.
    func load() {
        // Watched before anything is read: the read starts only once the watch is armed (ViewerWatch.whenArmed),
        // so a change while it loads always starts a reload.
        if watcher == nil { watch() }
        transition(.loading)
        // One read at a time per viewer (ViewerLoads, Phase 1's ScanGate): changes while one runs make exactly one
        // follow-up, which reads the file as it is then; an older one's work stops at its next step.
        loads = documentLoads.request { [weak self] unit in self?.read(unit) }
    }

    /// The document's loads, one at a time (the same lifecycle each set of versions has).
    @ObservationIgnored private let documentLoads = ViewerLoads()
    /// Petal --viewer-check only: told as each thumbnail is drawn, with the load it's for.
    nonisolated(unsafe) static var thumbnailDrawn: ((Int) -> Void)?
    /// Reads started (Petal --viewer-check: changes during a slow load make at most one follow-up).
    var readsStarted: Int { documentLoads.started }

    /// The read, off the main thread once the watch is armed; then `loaded` carries the unit on through
    /// conversion and parsing to the accepted result, and finishes it whatever happens.
    private func read(_ unit: ViewerLoadUnit) {
        let url = url
        let kind = kind
        let current = unit.current
        let finish: @Sendable (ViewerLoader.Read?) -> Void = { read in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard current() else { return unit.finish() }
                    if let read { return self.loaded(read, unit) }
                    unit.accept { self.transition(.failed(Self.cantShowText)) }
                    unit.finish()
                }
            }
        }
        let work: @Sendable () -> Void = {
            // Superseded before it began: straight to the follow-up.
            guard current() else { return finish(nil) }
            // The one path rule again at every load and reload (a file swapped for a link out of the home folder,
            // say): refused, nothing of it is read.
            guard case .success = ViewerPath.check(url.path) else { return finish(nil) }
            finish(ViewerLoader.read(url, kind: kind, current: current))
        }
        if let watcher { watcher.whenArmed(work) } else { Viewers.queue.async(execute: work) }
    }

    static let cantShowText = "This file can't be shown."

    /// The file shown no longer passes the path rule: nothing of it is shown or kept.
    static let notFoundText = "This file isn't there any more (moved somewhere Petal can't follow, or deleted)."

    // MARK: The document's state

    /// Every way the document's state changes. Only `transition` changes it.
    enum DocumentOutcome {
        /// A load or reload begins (the pages shown stay on screen meanwhile).
        case loading
        /// A load's pages accepted: only from the current generation (`unit`).
        case loaded(PDFDocument, Data, ViewerLoader.Read, ViewerLoadUnit)
        /// A load accepted as Quick Look's own view (nothing exported): only from the current generation.
        case live(ViewerLoader.Read, ViewerLoadUnit)
        /// It can't be shown: refused by the path rule, not found, unreadable, kept changing.
        case failed(String)
        /// The viewer closed.
        case closed
    }

    /// The one function that owns the document's state. Entering "loaded" (or Quick Look's own view) takes the
    /// current generation's unit and happens only through its `accept`. Leaving it for anything else (a failure, a
    /// refusal, not found, closing) invalidates every outstanding load and drawing generation, clears the pages,
    /// the selection and all anchor state (identity, bookmark, stamp), and settles every waiter with that outcome.
    private func transition(_ outcome: DocumentOutcome) {
        defer { picksFollowOriginal() }
        switch outcome {
        case .loading:
            if !loading { loading = true }
            keepFollowing()
            fileID = nil
            bookmark = nil
            unselected()
        case .loaded(let document, let data, let read, let unit):
            unit.accept {
                self.adopt(read)
                self.present(document, data)
            }
        case .live(let read, let unit):
            unit.accept {
                self.adopt(read)
                self.goLive(read.copy)
            }
        case .failed(let text):
            leaveLoaded()
            problem = text
            // Ends the load: whoever waits for it, or for the file's identity, is told (and finds no identity).
            loading = false
            settle(.load)
            settle(.identity)
            settle(.selection)
        case .closed:
            closedNow = true
            closing.on = true
            leaveLoaded()
            // Every waiter (a load, a selection, the file's identity, a place on its way) told at once: closed.
            settleAll(.closed)
        }
    }

    /// What finds the file again if it moves (fileChanged), never anchor state: the last accepted identity.
    private func keepFollowing() {
        if let fileID { lastSeen = (fileID, bookmark) }
    }

    /// Out of "loaded": every outstanding document load and thumbnail pass made stale (a load still under way can
    /// never be accepted over what this says), and the pages, selection and all anchor state gone.
    private func leaveLoaded() {
        documentLoads.invalidate()
        thumbLoads.invalidate()
        keepFollowing()
        liveCopy = nil
        liveURL = nil
        document = nil
        data = nil
        text = nil
        live = false
        pageCount = 0
        thumbs = [:]
        passages = [:]
        unselected()
        selectionPending = false
        fileID = nil
        bookmark = nil
        stamp = nil
    }

    /// A read in: its pages converted (WebKit, for Quick Look's HTML) and parsed, each step checking the unit is
    /// still wanted; the result accepted (`adopt` and what's shown) only at the end, and the unit finished on every
    /// path.
    private func loaded(_ read: ViewerLoader.Read, _ unit: ViewerLoadUnit) {
        switch read.pages {
        case .failed(let text):
            unit.accept { self.transition(.failed(text)) }
            unit.finish()
        case .pdf(let data): show(data, read, unit)
        case .web(let preview):
            // Quick Look's HTML preview made into pages: WebKit lays it out (out of process), the pages are cut
            // off the main thread; stopped at its next step once superseded.
            ViewerLoads.converting?(1)
            ViewerWeb.pages(preview, current: unit.current) { data in
                ViewerLoads.converting?(-1)
                if let data { return self.show(data, read, unit) }
                self.transition(.live(read, unit))
                unit.finish()
            }
        case .live:
            transition(.live(read, unit))
            unit.finish()
        }
    }

    /// What an accepted read tells about the file: its stamp, and its identity and bookmark (only ever from the
    /// current accepted read, never one kept from a read before it).
    private func adopt(_ read: ViewerLoader.Read) {
        if appName.isEmpty { appName = read.appName; appURL = read.appURL }
        let first = stamp == nil
        stamp = read.stamp
        if !first { updated = Date() }
        let changed = fileID != read.fileID
        bookmark = read.bookmark
        fileID = read.fileID
        // Which notes are on this file, worked out again for the file as it is now (refreshPlaces is fenced by
        // this load).
        if changed { refreshPlaces() }
    }

    /// The pages parsed off the main thread, then accepted and shown.
    private func show(_ data: Data, _ read: ViewerLoader.Read, _ unit: ViewerLoadUnit) {
        let current = unit.current
        Viewers.queue.async {
            let parsed = ViewerCarry(current() ? PDFDocument(data: data) : nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let document = parsed.value as? PDFDocument {
                        self.transition(.loaded(document, data, read, unit))
                    } else {
                        self.transition(.live(read, unit))
                    }
                    unit.finish()
                }
            }
        }
    }

    private func present(_ document: PDFDocument, _ data: Data) {
        // The page asked for while it loaded, against the finished document (clamped to the pages it has).
        let keep = ViewerPages.clamped(wantedPage, count: document.pageCount) ?? min(current, max(0, document.pageCount - 1))
        wantedPage = nil
        self.data = data
        text = ViewerText(data)
        self.document = document
        liveCopy = nil
        liveURL = nil
        live = false
        pageCount = document.pageCount
        current = max(0, keep)
        problem = nil
        loading = false
        thumbs = [:]
        renderThumbs(data)
        resolvedFor = nil
        resolvePassages()
        // The PDF view is bound to the new document by ViewerPDF (rebinding), which goes to `current` itself.
        // The copies are their own files: only their pictures of the page shown are drawn again.
        versions.map { drawVersions($0) }
    }

    /// Quick Look's own view of Petal's private copy (`copy`: from this load's read; without one there's nothing
    /// Quick Look may be given).
    private func goLive(_ copy: ViewerLive?) {
        guard let copy else { return transition(.failed("Petal can't show this file.")) }
        liveCopy = copy
        liveURL = copy.url
        document = nil
        data = nil
        text = nil
        live = true
        pageCount = 0
        problem = nil
        loading = false
        passages = [:]
    }

    /// The pages' thumbnails from a copy of the document of their own, off the main thread, a few at a time.
    /// A drawing unit of its own (`thumbLoads`): one pass at a time, a newer one coalesced; a pass stops between
    /// pages once a newer pass or load is asked for, or the viewer closes.
    private func renderThumbs(_ data: Data) {
        let document = documentLoads.token.current(loads)
        thumbLoads.request { unit in
            let wanted: @Sendable () -> Bool = { unit.current() && document() }
            let ticket = unit.generation
            Viewers.queue.async {
                defer { unit.finish() }
                guard wanted(), let pdf = PDFDocument(data: data) else { return }
                var batch: [Int: NSImage] = [:]
                for index in 0..<min(pdf.pageCount, 400) {
                    // A newer pass or load since, or the viewer closed: this pass stops between pages.
                    guard wanted() else { return }
                    guard let page = pdf.page(at: index) else { continue }
                    ViewerModel.thumbnailDrawn?(ticket)
                    batch[index] = page.thumbnail(of: CGSize(width: 300, height: 170), for: .cropBox)
                    if batch.count == 8 || index == pdf.pageCount - 1 {
                        let sent = batch
                        batch = [:]
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard wanted() else { return }
                                self.thumbs.merge(sent) { $1 }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The thumbnails' passes, one at a time (their own unit, apart from the document's loads).
    @ObservationIgnored private let thumbLoads = ViewerLoads()

    // MARK: Passages, found again by their words

    /// What the passages were last found for: the load and the notes' passages (their keys and words).
    @ObservationIgnored private var resolvedFor: (load: Int, passages: [String])?

    /// Every margin note's passage found again in the pages shown by its whole quote and the words around it
    /// (ViewerPassages, off the main thread, from a copy of the document of its own), never by the coordinates it
    /// was saved with; not found: moved. Again whenever the pages or the notes' passages change.
    func resolvePassages() {
        guard let data, !live else { return }
        let wanted = notes.filter { !$0.place.quote.isEmpty }.map { ($0.paper.key, $0.place) }
        let signature = wanted.map { "\($0.0)\u{1}\($0.1.quote)\u{1}\($0.1.before)\u{1}\($0.1.after)" }
        if let resolvedFor, resolvedFor.load == loads, resolvedFor.passages == signature { return }
        resolvedFor = (loads, signature)
        let ticket = loads
        let sticks = wanted
        Viewers.queue.async {
            let found = ViewerModel.find(sticks, in: data)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ticket == self.loads, self.resolvedFor?.passages == signature else { return }
                    if self.passages != found { self.passages = found }
                }
            }
        }
    }

    /// Off the main thread: each passage's page and bounds in `data`'s pages, or moved.
    nonisolated static func find(_ sticks: [(String, NoteStick)], in data: Data) -> [String: ViewerFound] {
        guard !sticks.isEmpty, let document = PDFDocument(data: data) else { return [:] }
        let texts = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        var out: [String: ViewerFound] = [:]
        for (key, stick) in sticks {
            guard let spot = ViewerPassages.find(stick, in: texts), let page = document.page(at: spot.page),
                  let lines = ViewerModel.lines(page, spot.range), let bounds = ViewerComments.union(lines) else {
                out[key] = .moved
                continue
            }
            out[key] = .found(page: spot.page, bounds: bounds, lines: lines)
        }
        return out
    }

    /// A passage's lines on its page: one rectangle per line of the selection (PDFKit's `selectionsByLine`).
    nonisolated static func lines(_ page: PDFPage, _ range: NSRange) -> [CGRect]? {
        guard let selection = page.selection(for: range) else { return nil }
        let lines = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { $0.width > 0 && $0.height > 0 }
        return lines.isEmpty ? nil : lines
    }

    /// Each line of a found passage on its page (what's highlighted); empty for any other note.
    func passageLines(_ paper: PaperNote) -> [CGRect] {
        if case .found(_, _, let lines)? = passages[paper.key] { return lines }
        return []
    }

    /// Where a margin note is in the document: its passage's page and bounds as found now, else its page or slide; a
    /// passage that moved is on the file (no page, no highlight).
    func spot(_ paper: PaperNote, _ place: NoteStick) -> (page: Int?, bounds: CGRect?, moved: Bool) {
        guard !place.quote.isEmpty else { return (ViewerMatch.pageIndex(place, count: pageCount), nil, false) }
        switch passages[paper.key] {
        case .found(let page, let bounds, _)?: return (page, bounds, false)
        case .moved?: return (nil, nil, true)
        case nil: return (nil, nil, false)
        }
    }

    // MARK: Keeping up with the file

    /// The file and its folder watched (the descriptors opened off the main thread): a change (saved in place, or
    /// replaced as PowerPoint and Keynote save) is read again once it settles; a file moved or renamed is followed
    /// by its bookmark.
    private func watch() {
        guard !Headless.on else { return }
        watcher = ViewerWatch(url: url) { [weak self] in self?.fileChanged() }
    }

    /// The file or its folder changed: the file shown is found again (ViewerFiles' rule for the open file): its own
    /// incarnation wherever it is now (renamed or moved, whatever file took its old path); that incarnation gone (a
    /// save that made a new file), the file now at its path; nothing there, the file its bookmark finds.
    /// The identity and bookmark of the last successful read, only to find the file again while a load is under way.
    @ObservationIgnored private var lastSeen: (id: ViewerFileID, bookmark: Data?)?

    func fileChanged() {
        let url = url
        let before = stamp
        let kept = bookmark ?? lastSeen?.bookmark
        let own = fileID ?? lastSeen?.id
        Viewers.queue.async {
            let found = ViewerModel.follow(url: url, own: own, bookmark: kept)
            // The file followed passes the path rule before it's adopted or loaded.
            let allowed = found.map { ViewerPath.check($0.path) }
            let refused = { if case .failure? = allowed { return true } else { return false } }()
            let now = found.flatMap { ViewerLoader.stamp($0) }
            let moved = found.flatMap { $0.path != url.path ? $0 : nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !self.closedNow else { return }
                    // Refused by the path rule, or nowhere to be found (its identity, its bookmark and its path all
                    // fail): a failed load, through the one transition.
                    if refused { return self.transition(.failed(Self.cantShowText)) }
                    if found == nil { return self.transition(.failed(Self.notFoundText)) }
                    if let moved { self.url = moved }
                    guard let now, now != before else { return }
                    // Replaced (a new file swapped in, as most apps save): the new one is watched from now on, and
                    // the load makes its bookmark again.
                    if moved != nil || now.inode != before?.inode { self.watcher = nil; self.watch() }
                    self.load()
                }
            }
        }
    }

    /// Off the main thread: where the open file is now (ViewerFiles.way's order for it).
    nonisolated static func follow(url: URL, own: ViewerFileID?, bookmark: Data?) -> URL? {
        // Still where it was (spelled as it was opened).
        if let own, ViewerFileID.of(url.path) == own { return url }
        let ownPath = own.flatMap { $0.path() }
        let atPath = ViewerLoader.stamp(url) != nil
        let viaBookmark = ownPath == nil && !atPath ? bookmark.flatMap(ViewerLoader.follow) : nil
        switch ViewerFiles.way(ownFound: ownPath != nil, hasBookmark: false, bookmarkFound: false, pathFound: atPath) {
        case .own: return ownPath.map { URL(fileURLWithPath: $0) }
        case .path: return url
        default: return viaBookmark
        }
    }

    func close() {
        defer { NotePictures.shared.visibilityChanged() }
        // Whatever the document's loads and its thumbnails still have going stops at its next step, and nothing
        // more starts.
        documentLoads.close()
        thumbLoads.close()
        transition(.closed)
        watcher = nil
        versionWatch = nil
        lensSoon?.cancel()
        if let key = openKey { fold(key) }
        // Every set this viewer made goes with it: told, its pictures dropped, its copies removed (the picked one
        // too: the asker reads it while the viewer is open).
        for set in (versions.map { [$0] } ?? []) + keptSets { retire(set, keepPick: false) }
        keptSets = []
    }

    // MARK: Pages

    /// A page or slide asked for (from 1, checked a whole number): while the document loads or reloads it waits for
    /// the finished document (`wantedPage`, never checked against a page count that isn't this load's); once shown,
    /// the nearest page it has.
    func ask(page: Int?) {
        guard let page else { return }
        if loading || document == nil { wantedPage = page; return }
        if let index = ViewerPages.clamped(page, count: pageCount) { go(to: index) }
    }

    func go(to index: Int) {
        guard index >= 0 else { return }
        guard let document else { wantedPage = index + 1; return }
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

    /// The margin scrolled by the person: the pages follow (as far as they go), so its notes stay lined up.
    func marginScrolled(_ offset: CGFloat) {
        marginOffset = offset
        if scrolls, abs(offset - docScroll) > 0.5 { scrollDocument?(offset) }
    }

    // MARK: Notes in the margin

    /// The notes on this file, every paper of each (one of a conflict's papers too), and where each is (its place),
    /// most specific place first.
    var notes: [(paper: PaperNote, place: NoteStick)] {
        let on = previewOnFile ?? { [onFile] in onFile.contains(ViewerFiles.key($0)) }
        return desk.store.notes.compactMap { paper in
            guard let index = ViewerMatch.place(paper.file.places, onFile: on) else { return nil }
            return (paper, paper.file.places[index])
        }
    }

    /// The notes' places that name a file: what `onFile` is worked out from, again whenever they or the file change.
    var anchorSignature: String {
        let keys = Set(desk.store.notes.flatMap { $0.file.places.filter(ViewerFiles.namesFile).map(ViewerFiles.key) })
        return url.path + "\u{2}" + (stamp.map { "\($0.inode)" } ?? "") + "\u{2}" + keys.sorted().joined(separator: "\u{2}")
    }

    /// Which of the notes' places name this file, each resolved on its own off the main thread (ViewerFiles): a
    /// note made through a link, on a file since renamed, or a sentence noted in Preview shows; a note on a file
    /// whose path this one took doesn't.
    /// Each read is a turn ("places") of one document load, for the file's checked identity (its load's `fileID`);
    /// only the newest turn's answer, for the load still shown, is taken: an older read finishing last never
    /// replaces it, and one from a load since replaced runs again for the file as it is now.
    /// `late`: Petal --viewer-check only, its answer held back that long (a slow read finishing last).
    func refreshPlaces(late: Double = 0) {
        guard !closedNow, let id = fileID else { return }
        let mac = desk.local.mac
        let places = desk.store.notes.flatMap { $0.file.places.filter(ViewerFiles.namesFile) }
        let turn = turns.begin("places")
        let load = loads
        Viewers.queue.async {
            let found = ViewerFiles.on(id, places, mac: mac, follow: ViewerLoader.follow)
            DispatchQueue.main.asyncAfter(deadline: .now() + late) {
                MainActor.assumeIsolated {
                    guard self.turns.isLatest("places", turn), !self.closedNow else { return }
                    guard load == self.loads, id == self.fileID else { return self.refreshPlaces() }
                    guard found != self.onFile else { return }
                    self.onFile = found
                    self.resolvePassages()
                }
            }
        }
    }

    /// A selection made in PDFKit's view: its page's text read off the main thread (ViewerText), then offered as a
    /// Note; an older selection's answer, or one from pages since replaced, is dropped.
    func selected(page: Int, bounds: CGRect, range: NSRange, anchor: CGPoint) {
        // The selection before is gone at once (its Note with it); the new one is offered only once its read is in.
        let turn = turns.begin("selection")
        if selection != nil { selection = nil }
        // Text selected on the pages of the load before, while the file is read again, is never offered: a passage
        // only ever from the pages of the current load.
        guard !loading, let source = text else { return settleSelection() }
        // Being read: never taken for no selection (herePlace waits for it).
        selectionPending = true
        let lens = lensKey != nil
        source.read(page: page, selected: range, paragraph: { text in
            guard lens, NSMaxRange(range) <= (text as NSString).length, let swift = Range(range, in: text) else { return nil }
            return NSRange(ViewerLens.paragraph(text, around: swift), in: text)
        }) { pageText, words, box in
            // A newer selection (or none) took over: that one settles it.
            guard self.turns.isLatest("selection", turn) else { return }
            defer { self.settleSelection() }
            // Only words offer a Note: whitespace alone is no selection.
            guard source === self.text, let pageText, !words.isEmpty, NSMaxRange(range) <= (pageText as NSString).length else { return }
            self.selection = ViewerSelection(page: page, bounds: bounds, quote: words, pageText: pageText, range: range, anchor: anchor)
            // The reading lens: the paragraph the selection is in, for the note that follows it.
            if lens, let swift = Range(range, in: pageText) {
                let paragraph = NSRange(ViewerLens.paragraph(pageText, around: swift), in: pageText)
                self.selectionSettled(page: page, text: pageText, paragraph: paragraph, selected: range, bounds: box ?? bounds)
            }
        }
    }

    /// No selection (or one the viewer doesn't offer a Note for): an answer still on its way is dropped.
    func unselected() {
        _ = turns.begin("selection")
        if selection != nil { selection = nil }
        settleSelection()
    }

    /// A selection being read (its page's text, off the main thread): what's here waits for it.
    @ObservationIgnored private(set) var selectionPending = false

    /// The selection's read is in (or replaced by none): whoever waited goes on.
    private func settleSelection() {
        selectionPending = false
        settle(.selection)
    }

    /// `then` once the current load is over (a first load or a reload: its pages, page count and checked identity
    /// all from it), or `.closed` when the viewer closes first: a file place is offered only from a finished load
    /// (`fileAnchor`), never with a load's identity and the pages or selection of the load before it.
    func whenIdentified(_ then: @escaping @MainActor (Settled) -> Void) {
        guard loading || closedNow else { return then(.ready) }
        wait(for: .identity, then)
    }

    /// `then` once no selection is being read: at once, when the newest selection's read is in, or `.closed`.
    func whenSelectionSettled(_ then: @escaping @MainActor (Settled) -> Void) {
        guard selectionPending || closedNow else { return then(.ready) }
        wait(for: .selection, then)
    }

    /// What a place made here was made for: this document (its load) and this selection (its turn). Anything else by
    /// the time the place is ready (the viewer closed, the file reloaded, another selection or none) and it's not used.
    struct HereContext: Equatable { var load: Int; var selection: Int }
    var hereContext: HereContext { HereContext(load: loads, selection: turns.current("selection")) }

    /// What `herePlace` found.
    enum HereOutcome {
        /// The place, and whether it's the selection's passage.
        case place(NoteStick, selection: Bool)
        /// The selection holds something from the vault, or the vault can't be read: no place.
        case refused
        /// The viewer closed, its document reloaded or its selection changed meanwhile: nothing used.
        case changed
        /// The file's checked identity isn't in (its load failed or was refused): no file place without it.
        case unidentified
        /// The viewer closed before the place was made.
        case closed
    }

    /// A paper's file got another name: what's kept about it here follows.
    func rekeyed(_ old: String, _ new: String) {
        if openKey == old { openKey = new }
        if lensKey == old { lensKey = new }
        heights = NoteShelf.rekeyed(heights, old, new)
        highlights = NoteShelf.rekeyed(highlights, old, new)
        passages = NoteShelf.rekeyed(passages, old, new)
        resolvedFor = nil
    }

    /// Opens a margin paper here: closed wherever else it was open (one editor per note), and this one let go if the
    /// desk opens it (`heldByViewer`).
    func openPaper(_ paper: PaperNote) {
        // Read only while the notes' folder is switched (the store takes no changes then).
        guard marginEditable else { return }
        if let key = openKey, key != paper.key { fold(key) }
        // Open in another viewer (a note on two files) or on the desk: handed over from there, never let go of (a
        // transfer, not a fold: an empty new note stays).
        desk.releaseFromViewer(paper)
        if desk.faces[paper.key] == .open || desk.faces[paper.key] == .back { desk.handOff(paper.key) }
        openKey = paper.key
        face = .open
        // Held by the note's identity, which follows an id given to an id-less note (NoteDesk.identityChanged); the
        // desk taking it is a transfer too.
        desk.heldByViewer[paper.holder] = { [weak self] in
            guard let self, let key = self.openKey else { return }
            self.close(key, .transfer)
        }
        if let item = notes.first(where: { $0.paper.key == paper.key }), let index = spot(item.paper, item.place).page, index != current {
            go(to: index)
        }
    }

    /// Folds the paper open here: what's typed saved first, and a note made here and left empty let go of.
    func fold(_ key: String) { close(key, .fold) }

    /// The paper open here stops being open here: what's typed saved first; folded, a note made here and left empty
    /// is let go of; handed to its other editor (`.transfer`), never (ViewerClose).
    func close(_ key: String, _ how: ViewerClose) {
        guard key == openKey else { return }
        desk.editors[key]?.flush()
        if let paper = desk.store.paper(key) { desk.heldByViewer[paper.holder] = nil }
        openKey = nil
        if how.letsGoIfEmpty { desk.letGoIfEmpty(key) }
    }

    /// The corner of `paper` used: that paper turned over (opened here first, or handed over from the desk, when it
    /// isn't the one open here), or back again.
    func flip(_ paper: PaperNote) {
        if openKey == paper.key {
            face = face == .back ? .open : .back
            return
        }
        openPaper(paper)
        face = .back
    }

    /// A margin paper's identity for its view (ViewerPaperID): an editable one by its note's identity, so a rename
    /// keeps its editor and what's typed in it.
    func paperID(_ paper: PaperNote) -> String {
        ViewerPaperID.of(key: paper.key, holder: paper.holder, readOnly: desk.store.readOnly(paper))
    }

    /// A new note here: on the selection's passage (its page and words; found again by them wherever it moves),
    /// else on the page or slide shown, else on the file. A file anchor all the same, so Preview and Acrobat show it
    /// on the file (AXDocument). The page's whole text is checked against the vault before the passage is cut from
    /// it (off the main thread): a selection touching a secret, or a vault that can't be read, makes no note.
    func newNote() {
        // The viewer's New note button and ⌃⌥N in a viewer: through the one readiness gate, before anything is read
        // for it (NoteDesk.takesChanges says "getting ready").
        guard desk.on else { return desk.tell("Petal Notes is off.") }
        guard desk.takesChanges() else { return }
        herePlace { outcome in
            switch outcome {
            case .refused: self.desk.tell("That selection holds something from your vault, or the vault can't be read: Petal makes no note on it.")
            case .changed: if !self.closedNow { self.desk.tell("What's in the viewer changed while Petal looked, so no note was made.") }
            case .unidentified: self.desk.tell("Petal can't tell which file this is yet, so no note was made.")
            case .closed: break
            case .place(let stick, let used):
                if used { self.selection = nil }
                self.make(stick)
            }
        }
    }

    /// This viewer's file as a note's place: a file anchor with the incarnation and bookmark its latest read made,
    /// at the page or slide shown. The one place the viewer offers as "here" (herePlace, the letterhead's menu), and
    /// only with the file's checked identity: nil until its load has read it (a path alone could later be another
    /// file's), so no file place without one is ever saved from the viewer.
    func fileAnchor() -> NoteStick? {
        // Only from a finished load: while one is under way its identity, pages and page shown aren't all its own yet.
        guard !loading, let fileID else { return nil }
        var stick = NoteStick(kind: .file)
        stick.path = url.path
        stick.title = name
        if !live, pageCount > 0 {
            if unit == .slide { stick.slide = current + 1 } else { stick.page = current + 1 }
        }
        stick.bookmark = bookmark?.base64EncodedString() ?? ""
        stick.fileID = fileID.record(mac: desk.local.mac)
        return stick
    }

    /// Whether the margin shows `key`'s paper now (the notes on this file).
    func shows(_ key: String) -> Bool { marginOn && notes.contains { $0.paper.key == key } }

    /// The desk's current place while this viewer has the keyboard (Viewers.front): its file anchor (`fileAnchor`)
    /// and, with `passage` and a selection, that selection as a passage. A selection still being read is waited for,
    /// never taken for none. The selection is checked as petal_look's rule checks a selected field's text
    /// (Assist.selectionInSecret): the whole text it's in, here its page's, against the vault, before anything is cut
    /// (ViewerSecrets), off the main thread; a secret touching it, or a vault that can't be read, is `refused`. The
    /// place is used only while the viewer is open with the same document and selection it was made for
    /// (`hereContext`); else `changed`.
    func herePlace(passage: Bool = true, _ answer: @escaping @MainActor (HereOutcome) -> Void) {
        // Registered as a waiter until it's answered (`.place`), so closing answers it at once (closed); answered
        // exactly once, so a late result (a slow vault check) is ignored.
        var answered = false
        var registration: Int?
        let done: @MainActor (HereOutcome) -> Void = { outcome in
            guard !answered else { return }
            answered = true
            if let registration { self.unwait(.place, registration) }
            answer(outcome)
        }
        registration = wait(for: .place) { settled in if settled == .closed { done(.closed) } }
        guard !answered else { return }
        // The selection's read and the file's identity both in first: never a page note for a pending selection,
        // never a place without the file's identity.
        whenSelectionSettled { settled in
            guard settled == .ready, !self.closedNow else { return done(.closed) }
            self.whenIdentified { settled in
                guard settled == .ready, !self.closedNow else { return done(.closed) }
                self.placeNow(passage: passage, done)
            }
        }
    }

    private func placeNow(passage: Bool, _ done: @escaping @MainActor (HereOutcome) -> Void) {
        guard var stick = fileAnchor() else { return done(.unidentified) }
        let context = hereContext
        guard let chosen = passage ? selection : nil else { return done(.place(stick, selection: false)) }
        Viewers.queue.async {
            ViewerModel.vaultChecking?()
            let cut = VaultIndex.settled { index -> (quote: String, before: String, after: String)? in
                guard !index.unreadable else { return nil }
                return ViewerSecrets.passage(chosen.pageText, range: chosen.range, secrets: index.spans(chosen.pageText))
            } ?? nil
            let refused = cut == nil
            if let cut {
                stick.page = chosen.page + 1
                stick.slide = nil
                stick.bounds = [chosen.bounds.minX, chosen.bounds.minY, chosen.bounds.width, chosen.bounds.height]
                stick.quote = cut.quote
                stick.before = cut.before
                stick.after = cut.after
            }
            let made = stick
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Made for this viewer as it was: closed, reloaded or another selection since, nothing is used.
                    guard !self.closedNow else { return done(.closed) }
                    guard self.hereContext == context else { return done(.changed) }
                    done(refused ? .refused : .place(made, selection: true))
                }
            }
        }
    }

    private func make(_ stick: NoteStick) {
        guard !closedNow else { return }
        guard desk.on else { return desk.tell("Petal Notes is off.") }
        // Checked again as the note is made (the place took a moment to work out): the same gate.
        guard desk.takesChanges() else { return }
        guard marginEditable else { return desk.tell("Your notes' folder is being switched: try again in a moment.") }
        guard let paper = desk.make(on: stick, open: false) else { return }
        openPaper(paper)
        resolvePassages()
    }

    // MARK: The reading lens (Phase 2 connects the AI)

    /// Marks a margin paper to follow the selection (nil: none does).
    func follow(_ key: String?) {
        lensKey = key
        lensAnswer = nil
        lensSpot = nil
        lensRequest = nil
    }

    /// The selection settled in a paragraph: while a note follows it, that paragraph is asked about, cut from the
    /// page's text only after all of it was checked against the vault (off the main thread; the vault unreadable,
    /// nothing is asked). `paragraph` and `selected`: UTF-16 ranges in `text`.
    func selectionSettled(page: Int, text: String, paragraph: NSRange, selected: NSRange, bounds: CGRect) {
        guard let key = lensKey, let noteID = desk.store.paper(key)?.noteID else { return }
        lensSoon?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Viewers.queue.async {
                let told = VaultIndex.settled { index -> (String, String)? in
                    guard !index.unreadable else { return nil }
                    let secrets = index.spans(text)
                    guard let words = ViewerSecrets.cut(text, range: paragraph, secrets: secrets, hidden: UIMap.hidden),
                          let chosen = ViewerSecrets.cut(text, range: selected, secrets: secrets, hidden: UIMap.hidden) else { return nil }
                    return (words, chosen)
                } ?? nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let told, self.lensKey == key else { return }
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
        guard request.id == lensRequest?.id, lensKey.flatMap({ desk.store.paper($0)?.noteID }) == request.noteID else { return }
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
    /// pictures follow the copies as they change, and the page shown. The original is never touched.
    /// `live`: its asker still there; gone (or the viewer closed) while the copies are made, nothing more is copied,
    /// what was is removed, and nothing is shown.
    func makeVersions(_ labels: [String], asker: String, live: @escaping @Sendable () -> Bool = { true },
                      then done: @escaping @MainActor (Result<ViewerVersionSet, ViewerCopyError>) -> Void) {
        let labels = ViewerCopies.labels(labels)
        guard !labels.isEmpty else { return done(.failure(.noLabels)) }
        guard live(), !closedNow else { return done(.failure(.cancelled)) }
        // Made only from the document as the viewer has it loaded: its incarnation and stamp are the set's base.
        guard !loading, document != nil || self.live, let baseID = fileID, let baseStamp = stamp else { return done(.failure(.notLoaded)) }
        // Each request a generation, from when it starts: only the newest may replace the set shown.
        let generation = turns.begin("versions")
        let url = url
        let id = UUID().uuidString.prefix(8).lowercased()
        let closing = closing
        let going: @Sendable () -> Bool = { !live() || closing.on }
        Viewers.queue.async {
            // The copies' names from the file's whole name and each label redacted first (Phase 1's safeStem), the
            // stem taken from the redacted name only then: a name, and the path an agent is given, never holds a
            // secret. The vault unreadable: nothing is made.
            let names = VaultIndex.settled { index -> (stem: String, labels: [String])? in
                guard !index.unreadable else { return nil }
                let stem = NoteShelf.safeStem(redacted: ViewerCopies.stem(redactedName: index.redacted(url.lastPathComponent), ext: url.pathExtension),
                                              fallback: "Document")
                return (stem, labels.enumerated().map { NoteShelf.safeStem(redacted: index.redacted($1), fallback: "Version \($0 + 1)") })
            } ?? nil
            guard let names else {
                return DispatchQueue.main.async { MainActor.assumeIsolated { done(.failure(.vault)) } }
            }
            let ext = url.pathExtension
            // The original read first, the one way it's read (ViewerLoader.readPinned, inside a coordinated read):
            // the path rule and its identity checked right before, through a pinned descriptor, and only the very
            // incarnation and state the viewer has loaded. Anything else: nothing is made or copied.
            var pinned: ViewerLoader.PinnedRead = .unreadable
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &error) { readable in
                ViewerModel.versionsSourceRead?(readable)
                pinned = ViewerLoader.readPinned(readable, expected: baseID)
            }
            let original: Data
            switch pinned {
            case .read(let bytes, _, let stamp) where stamp == baseStamp: original = bytes
            case .read, .changed: return DispatchQueue.main.async { MainActor.assumeIsolated { done(.failure(.originalChanged)) } }
            case .refused: return DispatchQueue.main.async { MainActor.assumeIsolated { done(.failure(.refused)) } }
            case .unreadable: return DispatchQueue.main.async { MainActor.assumeIsolated { done(.failure(.copy)) } }
            }
            // The set's folder made and pinned in Petal's own versions root (ViewerVersionStore): the copies are
            // written and read through its descriptor, never through a path that could be swapped.
            guard let store = ViewerVersionStore.shared, let pin = store.makeSet(String(id)) else {
                return DispatchQueue.main.async { MainActor.assumeIsolated { done(.failure(.copy)) } }
            }
            let folder = store.path(pin)
            var made: [ViewerVersion] = []
            var failure: ViewerCopyError?
            do {
                var taken: Set<String> = []
                for (index, label) in labels.enumerated() {
                    // Its asker gone or the viewer closed: no more copies.
                    if going() { failure = .cancelled; break }
                    let name = ViewerCopies.version(original: names.stem + (ext.isEmpty ? "" : "." + ext), label: names.labels[index], taken: taken)
                    taken.insert(name.lowercased())
                    guard store.write(pin, file: name, data: original) else { failure = .copy; break }
                    made.append(ViewerVersion(id: ViewerCopies.versionID(index), label: label, url: folder.appending(path: name)))
                }
            }
            let versions = made
            let failed = failure ?? (going() ? .cancelled : nil)
            // Nothing made shown: whatever was copied goes, through the set's pinned folder (never its path).
            if failed != nil { store.remove(pin) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let failed { return done(.failure(failed)) }
                    // A newer request started meanwhile: this one removes only its own copies (handed to no one
                    // yet), and never replaces or retires the newer set.
                    guard self.turns.isLatest("versions", generation) else {
                        Viewers.queue.async { store.remove(pin) }
                        return done(.failure(.superseded))
                    }
                    // Closed or hung up after the copies were made: they go, and nothing is shown.
                    guard !self.closedNow, live() else {
                        Viewers.queue.async { store.remove(pin) }
                        return done(.failure(.cancelled))
                    }
                    // Only the newest set per viewer: the one it replaces is told, its pictures dropped at once, and
                    // its copies removed (but the one picked, which its asker may still read, until the viewer closes).
                    if let older = self.versions {
                        if self.retire(older, keepPick: true) { self.keptSets.append(older) }
                    }
                    let set = ViewerVersionSet(id: String(id), asker: asker, folder: folder, versions: versions)
                    set.pin = pin
                    set.base = (baseID, baseStamp)
                    set.viewer = self
                    self.versions = set
                    self.versionPages = [:]
                    self.app.viewers.versionSets[set.id] = set
                    // Read once its watch is armed.
                    self.watchVersions(set)
                    done(.success(set))
                }
            }
        }
    }

    @ObservationIgnored private var versionWatch: ViewerWatch?
    /// Sets replaced by newer ones whose picked copy is still kept for their asker (removed when the viewer closes).
    @ObservationIgnored private(set) var keptSets: [ViewerVersionSet] = []

    /// A set no longer shown (replaced, or the viewer closing): whoever waits for its pick told (nil), its pictures
    /// dropped, and its copies removed through its pinned folder (ViewerVersionStore.remove), all but the picked one
    /// when `keepPick` and there is one. Without a copy kept it's forgotten (`petal_view_pick` no longer knows it).
    /// Returns whether a picked copy was kept.
    @discardableResult
    func retire(_ set: ViewerVersionSet, keepPick: Bool) -> Bool {
        // Whatever reading or drawing of its copies is under way stops at its next step, and none starts.
        set.shut()
        set.closed = true
        set.settle(nil)
        let picked = keepPick ? set.picked.flatMap { id in set.versions.first { $0.id == id } } : nil
        set.versions = picked.map { [ViewerVersion(id: $0.id, label: $0.label, url: $0.url)] } ?? set.versions.map {
            ViewerVersion(id: $0.id, label: $0.label, url: $0.url)
        }
        if set === versions { versionPages = [:] }
        let pin = set.pin
        let keeping = picked?.url.lastPathComponent
        Viewers.queue.async { if let pin { ViewerVersionStore.shared?.remove(pin, keeping: keeping) } }
        if picked == nil { app.viewers.versionSets[set.id] = nil }
        return picked != nil
    }

    /// The set's folder and every copy in it watched; after any change the watches are opened again, so a copy
    /// replaced by an atomic save (a new file) is watched as it is now, and every later write to it is seen.
    /// Its copies are read again only once that watch is armed (ViewerWatch.whenArmed), at the start and after every
    /// change, so an edit right after a read is never missed.
    private func watchVersions(_ set: ViewerVersionSet) {
        guard !closedNow, set === versions else { return }
        let watch = ViewerWatch(paths: [set.folder.path] + set.versions.map(\.url.path)) { [weak model = self, weak set] in
            guard let model, let set else { return }
            model.watchVersions(set)
        }
        versionWatch = watch
        watch.whenArmed { [weak model = self, weak set, weak watch] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let model, let set, let watch, model.versionWatch === watch else { return }
                    model.refreshVersions(set)
                }
            }
        }
    }

    /// How many pages a version's copy had when it was last read (Petal --viewer-check: its preview follows edits).
    func versionPageCount(_ id: String) -> Int? { versionPages[id].flatMap { PDFDocument(data: $0)?.pageCount } }
    /// Each copy's pages as last read (by version id), and the read they came from: a newer read makes an older one
    /// stand down; each picture drawn is fenced by its version's latest drawing (`turns`), which always uses the
    /// newest pages, and by the page shown.
    @ObservationIgnored private var versionPages: [String: Data] = [:]

    /// Each copy read again (through the same loader: Quick Look for decks), off the main thread, then its picture
    /// of the page shown drawn.
    func refreshVersions(_ set: ViewerVersionSet) {
        // One read of the copies at a time per set (ViewerLoads, the document's own lifecycle): saves while one
        // runs make one follow-up; a set closed or retired stops at its next step.
        set.loads.request { [weak self, weak set] unit in
            guard let self, let set else { return unit.finish() }
            self.readVersions(set, unit)
        }
    }

    /// Off the main thread, each copy whose file changed since it was last read (its inode, size and time through
    /// the set's pinned folder): its bytes read, then its pages (a PDF's as they are; anything else through Quick
    /// Look from a copy of those bytes, never the path in the set, then WebKit), `current` checked before each read,
    /// each export and the WebKit conversion. `finished` once all of it is in, or it stopped.
    /// The unit runs until every changed copy's pages are in (WebKit's conversions too) or it stopped; what it
    /// learned about each copy (`seen`, its pages) is committed only when accepted, so a conversion cut short leaves
    /// that copy to be read again by the follow-up.
    private func readVersions(_ set: ViewerVersionSet, _ unit: ViewerLoadUnit) {
        let current = unit.current
        let kind = kind
        let pin = set.pin
        let versions = set.versions.map { (id: $0.id, name: $0.url.lastPathComponent) }
        let seen = set.seen
        Viewers.queue.async {
            var results: [(id: String, made: ViewerVersionStore.Made?, pages: ViewerLoader.Pages?)] = []
            for version in versions {
                guard current() else { break }
                // Every read through the set's pinned folder (ViewerVersionStore): the folder still the one made, the
                // copy a regular file there, never a link; else nothing of it is read ("can't be shown").
                guard let pin, let store = ViewerVersionStore.shared, let made = store.state(pin, file: version.name) else {
                    results.append((version.id, nil, nil))
                    continue
                }
                // Unchanged since it was last read: nothing to do.
                if seen[version.id] == made { continue }
                ViewerModel.versionRead?(version.name)
                guard let bytes = store.read(pin, file: version.name) else {
                    results.append((version.id, nil, nil))
                    continue
                }
                if kind == .pdf {
                    results.append((version.id, made, PDFDocument(data: bytes) != nil ? .pdf(bytes) : .failed("Petal can't read this PDF.")))
                } else {
                    guard current() else { break }
                    ViewerModel.versionExport?(version.name)
                    results.append((version.id, made, ViewerQuickLook.export(bytes: bytes, name: version.name, unit: kind.unit).pages))
                }
            }
            let read = results
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard current(), set === self.versions else { return unit.finish() }
                    var waiting = 0
                    let done = { waiting -= 1; if waiting == 0 { unit.finish() } }
                    // A copy's result accepted: its pages kept, its state recorded as seen, its picture drawn.
                    let keep: @MainActor (String, ViewerVersionStore.Made, Data?) -> Void = { id, made, data in
                        unit.accept {
                            guard set === self.versions, let index = set.versions.firstIndex(where: { $0.id == id }) else { return }
                            set.seen[id] = made
                            set.versions[index].refused = false
                            self.versionPages[id] = data
                            self.drawVersion(set, id)
                        }
                    }
                    for result in read {
                        guard let made = result.made, let pages = result.pages else {
                            unit.accept {
                                guard let index = set.versions.firstIndex(where: { $0.id == result.id }) else { return }
                                set.seen[result.id] = nil
                                self.versionPages[result.id] = nil
                                set.versions[index].thumb = nil
                                set.versions[index].refused = true
                            }
                            continue
                        }
                        switch pages {
                        case .pdf(let data): keep(result.id, made, data)
                        case .web(let preview):
                            waiting += 1
                            ViewerLoads.converting?(1)
                            ViewerWeb.pages(preview, current: current) { data in
                                ViewerLoads.converting?(-1)
                                keep(result.id, made, data)
                                done()
                            }
                        default: keep(result.id, made, nil)
                        }
                    }
                    if waiting == 0 { unit.finish() }
                }
            }
        }
    }

    /// Petal --viewer-check only: told as a version's copy is read, and as it goes to Quick Look (its name).
    nonisolated(unsafe) static var versionRead: ((String) -> Void)?
    nonisolated(unsafe) static var versionExport: ((String) -> Void)?

    /// Every copy's picture of the page shown now (another page shown: drawn again from what was read).
    private func drawVersions(_ set: ViewerVersionSet) {
        for version in set.versions { drawVersion(set, version.id) }
    }

    /// One copy's picture of the page shown, drawn off the main thread from its newest pages; kept only if it's that
    /// version's latest drawing (never an older read's or another page's over a newer one) and that page and these
    /// copies are still the ones shown.
    /// A drawing unit of its own per version (`ViewerVersionSet.drawing`): one at a time, page changes while it
    /// draws coalesced into one follow-up for the page shown then, its generation and the set's closing checked
    /// before parsing and before drawing; the picture kept only when accepted.
    private func drawVersion(_ set: ViewerVersionSet, _ id: String) {
        guard !set.closed else { return }
        set.drawing(id).request { [weak self, weak set] unit in
            guard let self, let set, set === self.versions else { return unit.finish() }
            let page = self.current
            let carried = ViewerCarry(self.versionPages[id])
            let current = unit.current
            Viewers.queue.async {
                var image: NSImage?
                if current(), let data = carried.value as? Data, let pdf = PDFDocument(data: data), current() {
                    ViewerModel.versionDrawing?(1)
                    image = pdf.page(at: min(page, pdf.pageCount - 1))?.thumbnail(of: CGSize(width: 400, height: 224), for: .cropBox)
                    ViewerModel.versionDrawing?(-1)
                }
                let picture = ViewerCarry(image)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        unit.accept {
                            guard page == self.current, set === self.versions, let index = set.versions.firstIndex(where: { $0.id == id }) else { return }
                            set.versions[index].thumb = picture.value as? NSImage
                        }
                        unit.finish()
                    }
                }
            }
        }
    }

    /// Petal --viewer-check only: run inside the coordinated read, just before the original is read for versions.
    nonisolated(unsafe) static var versionsSourceRead: ((URL) -> Void)?

    /// Petal --viewer-check only: run just before a passage is checked against the vault (off the main thread).
    nonisolated(unsafe) static var vaultChecking: (() -> Void)?

    /// Petal --viewer-check only: a version's picture starting (+1) and ending (-1) its drawing.
    nonisolated(unsafe) static var versionDrawing: ((Int) -> Void)?

    /// "Use this": the pick reported to whatever asked for it. Nothing is changed by the viewer itself.
    /// Why a pick from `set` is held back now (nil: it isn't): only while the document loaded here is the very
    /// incarnation, unchanged, the set was made from. The copies are kept either way.
    func pickSuspended(_ set: ViewerVersionSet) -> String? {
        guard let base = set.base else { return Self.originalChangedText }
        if closedNow { return Self.originalChangedText }
        if loading { return "The original is being read again: pick once it's back." }
        guard document != nil || live || previewing, fileID == base.id, stamp == base.stamp else { return Self.originalChangedText }
        return nil
    }

    /// Petal's private copy Quick Look's own view shows (kept while it's shown), and where it is.
    @ObservationIgnored private var liveCopy: ViewerLive?
    private(set) var liveURL: URL?

    /// Closed (its window gone): nothing of it is told any more.
    var isClosed: Bool { closedNow }

    /// The viewer's state behind a tool's answer (`Viewers.Told`'s mark): closed or not, the file's name and path,
    /// the document loaded (its incarnation and stamp), whether it's loading, what went wrong, and its pages and
    /// the page shown. Anything else by the time the answer is delivered, and it's told again as it is then.
    var shownState: [String] {
        let base = loadedBase.map { "\($0.id.volume)|\($0.id.inode)|\($0.id.created)|\($0.stamp.size)|\($0.stamp.modified)" } ?? "none"
        return [closedNow ? "closed" : "open", name, url.path, base, loading ? "loading" : "loaded", problem ?? "", "\(live)", "\(pageCount)", "\(current)",
                "\(notes.count)"]
    }

    /// Snapshots only: the made-up document `preview` loads.
    @ObservationIgnored private var previewing = false
    /// The loaded document's incarnation and stamp (what a set of versions records as its base).
    var loadedBase: (id: ViewerFileID, stamp: ViewerUpdated.Stamp)? {
        guard let fileID, let stamp else { return nil }
        return (fileID, stamp)
    }

    nonisolated static let originalChangedText = "The original changed — make versions again."

    /// The document's state changed: a set whose original isn't the loaded document any more holds its picks back,
    /// and whoever waits for one is told (with why, `pickState`).
    private func picksFollowOriginal() {
        guard let set = versions, pickSuspended(set) != nil else { return }
        set.settle(nil)
    }

    func use(_ version: ViewerVersion) {
        guard let set = versions, set.picked == nil, set.versions.contains(where: { $0.id == version.id }),
              pickSuspended(set) == nil else { return }
        set.picked = version.id
        set.settle(version)
    }
}

enum ViewerCopyError: Error, CustomStringConvertible {
    case noLabels, copy, vault, cancelled, superseded, notLoaded, refused, originalChanged
    var description: String {
        switch self {
        case .notLoaded: "The document isn't read yet: ask again once it shows."
        case .refused: "This file can't be read here (it's outside the places Petal's viewer opens): nothing was made."
        case .originalChanged: "The original changed while the versions were being made: nothing was made. Ask again."
        case .superseded: "Newer versions of this file were asked for while these were being made: these weren't made, and the newer ones are shown."
        case .cancelled: "The viewer was closed, or the request ended, before the versions were made: nothing was made."
        case .vault: VaultStore.unreadableText + " Nothing was made (the copies' names are checked first)."
        case .noLabels: "Name each version (names: [\"Shorter\", \"With numbers\"])."
        case .copy: "Petal couldn't copy the file into a temporary folder: nothing was made."
        }
    }
}

/// A flag work on another thread reads (the viewer closed).
/// The newest load asked for and whether its owner closed, as work on another thread reads them.
final class ViewerLoadToken: @unchecked Sendable {
    private let lock = NSLock()
    private var newest = 0
    private var shut = false

    var generation: Int { lock.withLock { newest } }
    var closed: Bool { lock.withLock { shut } }
    func bump() -> Int { lock.withLock { newest += 1; return newest } }
    func close() { lock.withLock { shut = true } }

    /// Whether load `generation` is still wanted: the newest asked for, and its owner open. Checked by work off
    /// the main thread before each step (a read, a retry, an export, WebKit's conversion, a thumbnail).
    func current(_ generation: Int) -> @Sendable () -> Bool { { [self] in lock.withLock { !shut && newest == generation } } }
}

extension ViewerVersionStore {
    /// Where versions' copies are kept: Petal's own support folder (`Config.supportFolder`, so `PETAL_SUPPORT_DIR`
    /// isolates it as it does everything else Petal keeps). `Petal --viewer-check` sets a throwaway root of its own
    /// before anything uses it.
    nonisolated(unsafe) static var location = Config.supportFolder.appending(path: "Versions")

    /// The versions root, opened once (at its first use).
    static let shared = ViewerVersionStore(root: location)
}

/// One load: one unit of work, from the read through export, WebKit's conversion or parsing, to the accepted
/// result. `finish` releases the load's gate exactly once, whatever ends it (success, failure, cancellation,
/// closure; or the unit simply let go of, which finishes it too). What a load learns (a cache, a seen state, an
/// identity) is committed only through `accept`, which runs only while this is still the newest load and its owner
/// open.
final class ViewerLoadUnit: @unchecked Sendable {
    let generation: Int
    /// Still wanted: the newest load asked for, and its owner open (any thread).
    let current: @Sendable () -> Bool
    private let lock = NSLock()
    private var ended = false
    private let release: @Sendable () -> Void

    init(generation: Int, current: @escaping @Sendable () -> Bool, release: @escaping @Sendable () -> Void) {
        self.generation = generation
        self.current = current
        self.release = release
    }

    /// `commit` run (on the main thread) only when this load's result is accepted: still the newest, its owner
    /// open. Returns whether it ran.
    @MainActor @discardableResult
    func accept(_ commit: () -> Void) -> Bool {
        guard current() else { return false }
        commit()
        return true
    }

    /// The unit is over: its gate released, once (any later call does nothing).
    func finish() {
        let first = lock.withLock { () -> Bool in
            if ended { return false }
            ended = true
            return true
        }
        if first { release() }
    }

    deinit { finish() }
}

/// One load at a time for one thing the viewer shows (the document, a set of versions, a version's picture, the
/// thumbnails; the same lifecycle for each): each request is a generation; one asked for while a unit runs is
/// coalesced into exactly one follow-up (Phase 1's `NoteShelf.ScanGate`), which runs once that unit finishes, with
/// the newest request's work. Closing marks the token closed, so whatever's under way stops at its next step, and
/// nothing more starts.
@MainActor
final class ViewerLoads {
    typealias Run = @MainActor (ViewerLoadUnit) -> Void

    let token = ViewerLoadToken()
    private var gate = NoteShelf.ScanGate()
    private var run: Run?
    /// Petal --viewer-check only: told (on the main thread) as a WebKit conversion starts (+1) and ends (-1).
    nonisolated(unsafe) static var converting: ((Int) -> Void)?
    /// Units started (not requests): Petal --viewer-check counts them.
    private(set) var started = 0

    /// A new request: its generation. `run` starts now, or as the one follow-up after the unit under way.
    @discardableResult
    func request(_ run: @escaping Run) -> Int {
        let generation = token.bump()
        self.run = run
        if gate.request() { start() }
        return generation
    }

    func close() {
        token.close()
        run = nil
    }

    /// Every outstanding unit made stale (a newer generation that starts nothing): what it would accept never is.
    func invalidate() {
        _ = token.bump()
        run = nil
    }

    private func start() {
        guard let run, !token.closed else { gate = NoteShelf.ScanGate(); return }
        started += 1
        let generation = token.generation
        let unit = ViewerLoadUnit(generation: generation, current: token.current(generation)) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended() } }
        }
        run(unit)
    }

    private func ended() {
        if gate.finished() { start() }
    }
}

final class ViewerFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var on: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

final class ViewerCarry: @unchecked Sendable {
    let value: Any?
    init(_ value: Any?) { self.value = value }
}

// MARK: - Reading

/// What the viewer reads, off the main thread: the file's stamp and bookmark, its pages (a PDF's bytes, or Quick
/// Look's preview), and the app that opens it.
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
        var bookmark: Data?
        /// The file's incarnation as read: what a change follows first.
        var fileID: ViewerFileID? = nil
        var appName: String
        var appURL: URL?
        /// Petal's private copy of the checked bytes (anything Quick Look shows): what Quick Look's own view is
        /// given, never the original's path.
        var copy: ViewerLive? = nil
    }

    /// The original as it is now through the one pinned read (its stamp, bytes and identity; all nil when it isn't
    /// readable that way): what a write is checked against.
    static func pinnedNow(_ url: URL) -> (stamp: ViewerUpdated.Stamp?, bytes: Data?, id: ViewerFileID?) {
        if case .read(let bytes, let id, let stamp) = readPinned(url, expected: nil) { return (stamp, bytes, id) }
        return (nil, nil, nil)
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

    /// Off the main thread only. The bookmark is made with every read that finds the file, so the first move or
    /// rename is followed, and a replaced file's bookmark is its own.
    /// How many times a read is tried while the file keeps changing under it before the load fails.
    static let attempts = 3
    static let keptChanging = "The file kept changing while Petal read it. It's read again once it settles."
    /// A read stopped for a newer one (never shown: its follow-up is).
    static let superseded = "A newer read of the file took over."
    /// `Petal --viewer-check` only: run inside each read, between the identity read before and the bytes (a save
    /// that replaces the file then).
    nonisolated(unsafe) static var duringRead: ((URL, Int) -> Void)?

    /// The file read whole, its pages paired only with the incarnation they came from: inside one coordinated read
    /// (a file iCloud hasn't downloaded comes down first), its identity, stamp and bookmark are read before the
    /// bytes and its identity and stamp again after them (and again after a Quick Look export, which reads the file
    /// itself); the load is used only when both agree. A save in between (a new file swapped in, or a write in
    /// place) is read again, `attempts` times at most, then the load fails (`keptChanging`).
    /// What a pinned read of the original found.
    enum PinnedRead {
        case read(Data, ViewerFileID, ViewerUpdated.Stamp)
        /// Not a file the viewer may read (the path rule, or a link where the file was).
        case refused
        /// Another file, or this one changed, between its checks and its bytes (or not the incarnation expected).
        case changed
        case unreadable
    }

    /// The original's bytes, the one way they're read (the document's load and the versions made from it): the path
    /// rule checked right before (`ViewerPath.check`), its identity read, then the file opened with `O_NOFOLLOW`
    /// (never through a link swapped in) and that descriptor checked to be that very file (`fstat`: a regular file,
    /// the same inode and size) before its bytes are read from it; afterwards the path still allowed and still that
    /// file, unchanged. `expected`: the incarnation it must be (the one the viewer has loaded). Off the main thread,
    /// inside the caller's coordinated read.
    nonisolated static func readPinned(_ url: URL, expected: ViewerFileID?) -> PinnedRead {
        guard case .success(let checked) = ViewerPath.check(url.path) else { return .refused }
        guard let id = ViewerFileID.of(checked.path), let before = stamp(checked) else { return .unreadable }
        if let expected, id != expected { return .changed }
        let fd = open(checked.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return errno == ELOOP ? .refused : .unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, UInt64(info.st_ino) == id.inode, Int64(info.st_size) == before.size else {
            return .changed
        }
        guard let bytes = try? handle.readToEnd() else { return .unreadable }
        guard case .success = ViewerPath.check(url.path) else { return .refused }
        guard ViewerFileID.of(checked.path) == id, stamp(checked) == before else { return .changed }
        return .read(bytes ?? Data(), id, before)
    }

    /// `current`: still the newest load asked for; checked before each try and before a Quick Look export, and a
    /// superseded read stops there (`superseded`).
    static func read(_ url: URL, kind: ViewerKind, current: @Sendable () -> Bool = { true }) -> Read {
        let app = NSWorkspace.shared.urlForApplication(toOpen: url)
        let appName = app.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? ""
        for attempt in 0..<attempts {
            guard current() else { return Read(pages: .failed(superseded), stamp: nil, appName: appName, appURL: app) }
            var gone = false
            var mark: Data?
            var pinned: PinnedRead = .unreadable
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &error) { readable in
                guard let before = ViewerFileID.of(readable.path) else { gone = true; return }
                mark = bookmark(readable)
                duringRead?(readable, attempt)
                // The one way any original is read, on every try (never only the first): the path rule and its
                // identity right before, through a pinned descriptor (readPinned).
                pinned = readPinned(readable, expected: before)
            }
            if gone { return Read(pages: .failed("The file isn't there any more."), stamp: nil, appName: appName, appURL: app) }
            switch pinned {
            case .refused: return Read(pages: .failed(ViewerModel.cantShowText), stamp: nil, appName: appName, appURL: app)
            case .changed: continue
            case .unreadable:
                return Read(pages: .failed(kind == .pdf ? "Petal can't read this PDF." : "Petal can't read this file."), stamp: nil, appName: appName, appURL: app)
            case .read(let bytes, let id, let stamp):
                switch kind {
                case .pdf:
                    guard PDFDocument(data: bytes) != nil else {
                        return Read(pages: .failed("Petal can't read this PDF."), stamp: stamp, appName: appName, appURL: app)
                    }
                    return Read(pages: .pdf(bytes), stamp: stamp, bookmark: mark, fileID: id, appName: appName, appURL: app)
                case .quickLook(let unit):
                    guard current() else { return Read(pages: .failed(superseded), stamp: nil, appName: appName, appURL: app) }
                    // Quick Look never gets the original's path: it previews a private copy of the checked bytes.
                    let made = ViewerQuickLook.export(bytes: bytes, name: url.lastPathComponent, unit: unit)
                    return Read(pages: made.pages, stamp: stamp, bookmark: mark, fileID: id, appName: appName, appURL: app, copy: made.copy)
                }
            }
        }
        return Read(pages: .failed(keptChanging), stamp: nil, appName: appName, appURL: app)
    }
}

/// Petal's private copy of a document's checked bytes, in an export folder of its own (which goes once nothing holds
/// it): what Quick Look is given, never the original's path.
final class ViewerLive: @unchecked Sendable {
    let url: URL
    let export: ViewerExport

    init(url: URL, export: ViewerExport) {
        self.url = url
        self.export = export
    }
}

/// A folder Quick Look exported a preview into: it owns that folder, which goes (off the main thread) once nothing
/// holds the export any more, whether its pages were used or a newer load made it stand down.
final class ViewerExport: @unchecked Sendable {
    /// Where every export goes, each in a folder of its own: the viewer's own folder under Petal's support folder
    /// (`PETAL_SUPPORT_DIR` isolates it), with the private copies Quick Look is given.
    static var root: URL { Config.supportFolder.appending(path: "Viewer") }

    let folder: URL

    init() {
        folder = Self.root.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        let folder = folder
        Viewers.queue.async { try? FileManager.default.removeItem(at: folder) }
    }

    /// At launch: exports a Petal before this one left behind (quit or crashed mid-load), older than ten minutes
    /// (another Petal process's export under way is left alone).
    static func sweep(now: Date = Date()) {
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let made = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(made) > 600 { try? fm.removeItem(at: folder) }
        }
    }
}

/// macOS's own Quick Look preview of a document, exported to a temporary folder by Quick Look itself (qlmanage),
/// off the main thread: a PDF it gives (iWork's) is the pages; an HTML preview (Office's) is laid out by WebKit and
/// cut into slides or pages; nothing exported, Quick Look's own view shows it instead.
enum ViewerQuickLook {
    /// A document's pages from its checked bytes: written as a private copy (under its own name) in an export
    /// folder of Petal's own, which is all Quick Look is ever given. The copy comes back too, for Quick Look's own
    /// view when nothing could be exported.
    static func export(bytes: Data, name: String, unit: ViewerUnit) -> (pages: ViewerLoader.Pages, copy: ViewerLive?) {
        let export = ViewerExport()
        let source = export.folder.appending(path: "original")
        let file = source.appending(path: (name as NSString).lastPathComponent)
        guard (try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)) != nil,
              (try? bytes.write(to: file)) != nil else { return (.failed("Petal couldn't make its copy to show this file."), nil) }
        ViewerQuickLook.exporting?(file)
        return (pages(of: file, into: export, unit: unit), ViewerLive(url: file, export: export))
    }

    /// Petal --viewer-check only: told the file Quick Look is about to be given.
    nonisolated(unsafe) static var exporting: ((URL) -> Void)?

    /// Quick Look's export of `file` (always a private copy of Petal's own) into `export`'s folder.
    private static func pages(of file: URL, into export: ViewerExport, unit: ViewerUnit) -> ViewerLoader.Pages {
        let ran = run(["/usr/bin/qlmanage", "-p", "-o", export.folder.path, file.path], timeout: 40)
        guard ran, let folder = (try? FileManager.default.contentsOfDirectory(at: export.folder, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "qlpreview" }) else { return .live }
        let properties = (try? Data(contentsOf: folder.appending(path: "PreviewProperties.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let mime = properties["MimeType"] as? String ?? ""
        let html = (try? String(contentsOf: folder.appending(path: "Preview.html"), encoding: .utf8)) ?? ""
        switch ViewerPages.shape(mime: mime, html: html) {
        case .pdf(let name):
            let file = name.isEmpty ? folder.appending(path: "Preview.pdf") : folder.appending(path: name)
            guard let data = try? Data(contentsOf: file), PDFDocument(data: data) != nil else { return .live }
            return .pdf(data)
        case .slides, .flowing:
            // Sizes from Quick Look's file, kept to what a page can be.
            let size = { (key: String, fallback: Double) -> Double in
                let value = (properties[key] as? NSNumber)?.doubleValue ?? fallback
                return value.isFinite ? min(max(value, 100), 20_000) : fallback
            }
            return .web(ViewerWeb.Preview(folder: folder, export: export, slides: html.contains("class=\"slide\"") || unit == .slide,
                                          width: size("Width", 800), height: size("Height", 1000)))
        case .none:
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
/// main thread. Its words stay text, so a passage there can be exact too. It loads nothing but local files: a
/// content rule list blocks every other load (an image or style from the network, a socket) before the preview
/// is loaded, and the page's own scripts are off.
@MainActor
final class ViewerWeb: NSObject, WKNavigationDelegate {
    struct Preview: @unchecked Sendable {
        var folder: URL
        /// The export the preview is in: kept while WebKit uses it, removed once nothing holds it.
        var export: ViewerExport?
        var slides: Bool
        var width: Double
        var height: Double
    }

    private let preview: Preview
    private var web: WKWebView?
    private let done: @MainActor (Data?) -> Void
    /// Still wanted (its load the newest, its owner open): checked before it starts, after the page is laid out,
    /// after it's drawn and before it's cut; not, it stops there with nothing.
    private let current: @Sendable () -> Bool
    private var finished = false
    private static var running: Set<ViewerWeb> = []

    /// `localOnly` false only for the check that proves the rule list matters (Petal --viewer-check).
    static func pages(_ preview: Preview, localOnly: Bool = true, current: @escaping @Sendable () -> Bool = { true },
                      done: @escaping @MainActor (Data?) -> Void) {
        guard current() else { return done(nil) }
        let job = ViewerWeb(preview, current: current, done: done)
        running.insert(job)
        guard localOnly else { return job.start(rules: nil) }
        rules { list in
            // No rule list, no load: nothing is loaded without it.
            guard let list else { return job.finish(nil) }
            job.start(rules: list)
        }
    }

    /// Every load blocked but local files (and data the page carries in itself).
    static let ruleSource = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]
        """
    private static var compiled: WKContentRuleList?

    private static func rules(_ done: @escaping @MainActor (WKContentRuleList?) -> Void) {
        if let compiled { return done(compiled) }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "petal.viewer.local-only", encodedContentRuleList: ruleSource) { list, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let list { compiled = list }
                    done(list)
                }
            }
        }
    }

    private init(_ preview: Preview, current: @escaping @Sendable () -> Bool, done: @escaping @MainActor (Data?) -> Void) {
        self.preview = preview
        self.current = current
        self.done = done
        super.init()
    }

    private func start(rules: WKContentRuleList?) {
        guard !finished else { return }
        guard current() else { return finish(nil) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        if let rules { configuration.userContentController.add(rules) }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: max(320, preview.width), height: max(320, preview.height)), configuration: configuration)
        web.navigationDelegate = self
        self.web = web
        web.loadFileURL(preview.folder.appending(path: "Preview.html"), allowingReadAccessTo: preview.folder)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.finish(nil) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only the preview's own files.
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard current() else { return finish(nil) }
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

    /// The tallest a preview is drawn (as many pages as the viewer shows, at most).
    static let tallest: CGFloat = 400_000

    private func measured(_ value: Any) {
        guard let web, current() else { return finish(nil) }
        var boxes: [CGRect] = []
        var size = CGSize(width: preview.width, height: preview.height)
        var bottoms: [CGFloat] = []
        let sane = { (number: NSNumber) -> CGFloat? in
            let value = number.doubleValue
            return value.isFinite && abs(value) <= Double(Self.tallest) ? CGFloat(value) : nil
        }
        if preview.slides {
            for item in value as? [[NSNumber]] ?? [] where item.count == 4 {
                let numbers = item.compactMap(sane)
                guard numbers.count == 4, numbers[2] > 1, numbers[3] > 1 else { continue }
                boxes.append(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
            }
            boxes = Array(boxes.prefix(500))
            guard !boxes.isEmpty else { return finish(nil) }
            size = CGSize(width: max(size.width, boxes.map(\.maxX).max() ?? 0), height: boxes.map(\.maxY).max() ?? size.height)
        } else {
            let numbers = (value as? [NSNumber] ?? []).compactMap(sane)
            guard numbers.count >= 2 else { return finish(nil) }
            size = CGSize(width: max(numbers[0], 320), height: min(max(numbers[1], 320), Self.tallest))
            bottoms = Array(numbers.dropFirst(2))
        }
        // The whole preview, laid out at its full height so every part is in the drawing.
        web.frame = NSRect(origin: .zero, size: size)
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        let pageHeight = preview.slides ? 0 : CGFloat(preview.width > 0 ? size.width * preview.height / preview.width : size.height)
        web.createPDF(configuration: configuration) { [weak self] result in
            guard let self else { return }
            guard case .success(let whole) = result, self.current() else { return self.finish(nil) }
            let slides = boxes
            let ends = bottoms
            let total = size
            let current = self.current
            Viewers.queue.async {
                let data = current() ? ViewerWeb.cut(whole, slides: slides, bottoms: ends, size: total, pageHeight: pageHeight) : nil
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
        web?.stopLoading()
        web = nil
        // The export goes once this job lets go of it (ViewerExport).
        Self.running.remove(self)
        done(data)
    }
}

/// A file (and its folder) watched for changes, on the viewer's queue: saved in place, replaced (PowerPoint,
/// Keynote and most apps save a new file and swap it in), renamed or moved. Each burst is one call, once settled.
/// The paths are opened off the main thread.
final class ViewerWatch: @unchecked Sendable {
    private var sources: [DispatchSourceFileSystemObject] = []
    private let changed: @MainActor () -> Void
    private var soon: DispatchWorkItem?
    private var stopped = false
    private let lock = NSLock()

    convenience init(url: URL, changed: @escaping @MainActor () -> Void) {
        self.init(paths: [url.path, url.deletingLastPathComponent().path], changed: changed)
    }

    init(paths: [String], changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        Viewers.queue.async { [weak self] in self?.start(paths) }
    }

    private func start(_ paths: [String]) {
        var made: [DispatchSourceFileSystemObject] = []
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib, .link],
                                                                   queue: Viewers.queue)
            source.setEventHandler { [weak self] in self?.fire() }
            source.setCancelHandler { close(fd) }
            made.append(source)
        }
        let ready: [@Sendable () -> Void] = lock.withLock {
            defer { armed = true; waiting = [] }
            // Let go of before it was set up: nothing is watched (a source is resumed before it's cancelled, so its
            // descriptor is closed).
            if stopped {
                for source in made { source.setEventHandler {}; source.resume(); source.cancel() }
                return waiting
            }
            sources = made
            for source in made { source.resume() }
            return waiting
        }
        for then in ready { Viewers.queue.async(execute: then) }
    }

    private var armed = false
    private var waiting: [@Sendable () -> Void] = []

    /// `then` (on Viewers.queue) once the watch is armed, its sources resumed: at once when it already is. A read
    /// started from here can't miss a change made after it began.
    func whenArmed(_ then: @escaping @Sendable () -> Void) {
        let now = lock.withLock { () -> Bool in
            if armed { return true }
            waiting.append(then)
            return false
        }
        if now { Viewers.queue.async(execute: then) }
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
        lock.withLock {
            stopped = true
            soon?.cancel()
            for source in sources { source.cancel() }
        }
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

/// "Write these notes into the PDF as comments": each note on the PDF as a comment where it's stuck (a passage found
/// again by its words, highlighted; else a sticky note at its page's top-left corner, the first page for one on the
/// whole file or whose passage moved). Into a copy beside the original by default ("Report (with notes).pdf"); into
/// the original only when asked, the original kept beside it first ("Report (before notes).pdf"). Every note's
/// words are redacted whole with the vault's index before they're made plain or cut (nothing is written while the
/// vault can't be read). The write lands only on the PDF it was made from, its asker still there: both checked
/// inside the coordinated write, right before each change (ViewerWrites). Off the main thread.
enum ViewerPDFComments {
    struct Comment: Sendable {
        var stick: NoteStick
        var body: String
        var color: NoteInk.RGB
    }

    enum Outcome: Equatable { case wrote(URL, Int), failed(String) }

    static let changed = "The PDF changed while Petal was writing its notes into it: nothing was written. Try again."
    static let hungUp = "The request ended before this was done: nothing was written."

    /// `expected`: the PDF the person allowed (its incarnation when they were asked): a file that replaced it since is
    /// never written. `meanwhile`, `afterRead` and `lastMoment`: for Petal --viewer-check only, between reading the
    /// PDF and writing, right after it's read again inside the write, and right before the last check ahead of each
    /// final change (the person's edit, or a hang-up, then).
    static func write(_ pdf: URL, comments: [Comment], intoOriginal: Bool, author: String, expected: ViewerFileID? = nil,
                      live: @escaping @Sendable () -> Bool = { true }, meanwhile: (@Sendable () -> Void)? = nil,
                      afterRead: (@Sendable () -> Void)? = nil, lastMoment: (@Sendable () -> Void)? = nil, _ done: @escaping @MainActor (Outcome) -> Void) {
        Viewers.queue.async {
            let outcome = make(pdf, comments: comments, intoOriginal: intoOriginal, author: author, expected: expected, live: live,
                               meanwhile: meanwhile, afterRead: afterRead, lastMoment: lastMoment)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(outcome) } }
        }
    }

    private static func make(_ pdf: URL, comments: [Comment], intoOriginal: Bool, author: String, expected: ViewerFileID?, live: @Sendable () -> Bool,
                             meanwhile: (@Sendable () -> Void)?, afterRead: (@Sendable () -> Void)?, lastMoment: (@Sendable () -> Void)?) -> Outcome {
        guard !comments.isEmpty else { return .failed("No notes are on this PDF yet.") }
        guard live() else { return .failed(hungUp) }
        // Each note's words redacted whole, before anything is cut from them; the copies' names made from the PDF's
        // name redacted whole too (Phase 1's safeStem: a file name never holds a secret).
        let told = VaultIndex.settled { index -> (texts: [String], stem: String)? in
            guard !index.unreadable else { return nil }
            // The whole name redacted first, the stem taken from it only then.
            let stem = NoteShelf.safeStem(redacted: ViewerCopies.stem(redactedName: index.redacted(pdf.lastPathComponent), ext: pdf.pathExtension),
                                          fallback: "Document")
            return (comments.map { ViewerComments.text($0.body, redact: index.redacted) }, stem)
        } ?? nil
        guard let told else { return .failed("Your vault can't be read right now, so Petal wrote nothing (a note's words are checked first).") }
        let named = told.stem + ".pdf"
        // The base: the PDF as read now (its bytes and identity); the write lands only on it.
        var base: Data?
        var baseStamp: ViewerUpdated.Stamp?
        var error: NSError?
        var baseID: ViewerFileID?
        NSFileCoordinator().coordinate(readingItemAt: pdf, options: [.withoutChanges], error: &error) { readable in
            // The one way an original is read (ViewerLoader.readPinned): the path rule and its identity right before.
            (baseStamp, base, baseID) = ViewerLoader.pinnedNow(readable)
        }
        // Already another file than the one the person allowed: nothing is written.
        if let expected, baseID != expected { return .failed(changed) }
        guard let base, let baseStamp, let document = PDFDocument(data: base), document.pageCount > 0 else { return .failed("Petal can't read this PDF.") }
        let texts = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        var written = 0
        for (comment, text) in zip(comments, told.texts) where !text.isEmpty {
            // A passage where its words are now, never where it was saved.
            let lines = ViewerPassages.find(comment.stick, in: texts).flatMap { spot -> (page: Int, lines: [CGRect])? in
                guard let page = document.page(at: spot.page), let lines = ViewerModel.lines(page, spot.range) else { return nil }
                return (spot.page, lines)
            }
            let found = lines.flatMap { found in ViewerComments.union(found.lines).map { (page: found.page, bounds: $0) } }
            guard let spot = ViewerComments.spot(comment.stick, passage: found, pages: document.pageCount, box: { index in
                      let page = document.page(at: index)
                      return (page?.bounds(for: .cropBox) ?? .zero, page?.rotation ?? 0)
                  }),
                  let page = document.page(at: spot.page) else { continue }
            let color = NSColor(srgbRed: comment.color.r, green: comment.color.g, blue: comment.color.b, alpha: 1)
            if let bounds = spot.bounds {
                let mark = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                // One quadrilateral per line, so only the passage's own words are marked.
                mark.quadrilateralPoints = ViewerComments.quads(lines?.lines ?? [bounds], within: bounds).map { NSValue(point: $0) }
                mark.color = color.withAlphaComponent(0.35)
                mark.contents = text
                mark.userName = author
                page.addAnnotation(mark)
            }
            let note = PDFAnnotation(bounds: spot.note, forType: .text, withProperties: nil)
            note.contents = text
            note.color = color
            note.userName = author
            page.addAnnotation(note)
            written += 1
        }
        guard written > 0 else { return .failed("No notes are on this PDF yet.") }
        // Written first in a folder of Petal's own on the PDF's volume (never beside it), then moved in.
        guard let scratch = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: pdf, create: true) else {
            return .failed("Petal couldn't write beside the PDF (its folder may not be writable).")
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temp = scratch.appending(path: pdf.lastPathComponent)
        guard document.write(to: temp) else { return .failed("Petal couldn't write the PDF with its notes.") }
        meanwhile?()
        let folder = pdf.deletingLastPathComponent()
        // Written only beside a file in an allowed root (the path rule), and only into a folder the person can write.
        guard case .success = ViewerPath.check(pdf.path) else { return .failed(ViewerModel.cantShowText) }
        guard ViewerPath.writable(folder.path) else { return .failed("The person can't write in the PDF's folder: nothing was written.") }
        var outcome: Outcome = .failed("Petal couldn't write beside the PDF; nothing changed.")
        if !intoOriginal {
            // A new copy beside it: the PDF read (it's still the one the notes were written on), the copy written.
            let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
            let copy = folder.appending(path: ViewerCopies.withNotes(original: named, taken: names))
            NSFileCoordinator().coordinate(readingItemAt: pdf, options: [.withoutChanges], writingItemAt: copy, options: [], error: &error) { readable, writable in
                // Read again first; its asker asked only after that blocking read.
                let now = ViewerLoader.pinnedNow(readable)
                afterRead?()
                switch ViewerWrites.land(live: live(), base: (baseStamp, base), expected: expected ?? baseID, now: now) {
                case .hungUp: outcome = .failed(hungUp)
                case .changed: outcome = .failed(changed)
                case .land:
                    // Its asker checked again after the blocking read of the PDF, right before the copy is made.
                    lastMoment?()
                    guard live() else { outcome = .failed(hungUp); return }
                    guard !FileManager.default.fileExists(atPath: writable.path), (try? FileManager.default.moveItem(at: temp, to: writable)) != nil else { return }
                    outcome = .wrote(writable, written)
                }
            }
            return outcome
        }
        // Into the original: the original kept beside it first, then the new one put in its place.
        NSFileCoordinator().coordinate(writingItemAt: pdf, options: [.forReplacing], error: &error) { writable in
            // Read again first (the very file the person allowed, unchanged); its asker asked only after that blocking
            // read, before any backup is made.
            let now = ViewerLoader.pinnedNow(writable)
            afterRead?()
            switch ViewerWrites.land(live: live(), base: (baseStamp, base), expected: expected ?? baseID, now: now) {
            case .hungUp: outcome = .failed(hungUp)
            case .changed: outcome = .failed(changed)
            case .land:
                let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
                let backup = folder.appending(path: ViewerCopies.beforeNotes(original: named, taken: names))
                do {
                    try FileManager.default.copyItem(at: writable, to: backup)
                    // Its asker checked again after the backup, right before the PDF itself changes; gone, the backup
                    // Petal just made goes and the PDF is as it was.
                    lastMoment?()
                    guard live() else {
                        try? FileManager.default.removeItem(at: backup)
                        outcome = .failed(hungUp)
                        return
                    }
                    _ = try FileManager.default.replaceItemAt(writable, withItemAt: temp)
                    outcome = .wrote(pdf, written)
                } catch {
                    outcome = .failed("Petal couldn't write into the PDF; it's as it was.")
                }
            }
        }
        return outcome
    }
}
