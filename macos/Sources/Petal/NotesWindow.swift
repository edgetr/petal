import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A note dragged out of the Petal Notes window or a notebook's stack: its id (declared in build.sh's Info.plist).
    static let petalNote = UTType(exportedAs: "tech.edgetr.petal.note")
}

extension NSPasteboard.PasteboardType {
    static let petalNote = NSPasteboard.PasteboardType(UTType.petalNote.identifier)
}

/// A note as something to drag: its id, and its words for anything else that takes text.
@MainActor
enum NoteDrag {
    static func provider(_ paper: PaperNote) -> NSItemProvider {
        let provider = NSItemProvider()
        let id = Data(paper.noteID.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.petalNote.identifier, visibility: .ownProcess) { done in
            done(id, nil)
            return nil
        }
        return provider
    }
}

/// The Petal Notes window: every note, by notebook (its cover first, then a grid of its notes, or its canvas), the
/// views across notebooks (Coming back, Watching, Helpers at work) and search. A window of Liquid Glass like the
/// settings, opened from the menu bar's mark and from a notebook's stack in the dock. Everything it changes goes
/// through the notes' own paths (each note's session, the one move, a notebook's cover); nothing here writes a file.
@MainActor
final class NotesWindow {
    private(set) var window: NSWindow?
    let model = NotesModel()

    var isOpen: Bool { window?.isVisible ?? false }

    func show(_ shelf: NoteLibrary.Shelf? = nil) {
        // An explicit shelf (a notebook's stack, its link) is shown as asked: never an earlier search over it.
        if let shelf {
            model.shelf = shelf
            model.query = ""
        }
        let window = self.window ?? make()
        if !window.isVisible { window.setGlassContent(NotesWindowView(model: model).environment(PetalApp.shared)) }
        PetalWindow.bringForward(window)
    }

    /// Whether a Private notebook's note shows in it (Petal's own pictures leave it out then).
    /// The window shows a Private notebook's note now (its page, a search hit, a view): Petal's own pictures leave it
    /// out (NotePrivacy.excludedWindows), and, as a best effort only, macOS is asked not to share it.
    func showingPrivate(_ hidden: Bool) {
        showsPrivate = hidden
        window?.sharingType = hidden ? .none : .readOnly
    }

    private(set) var showsPrivate = false

    private func make() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 748),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 560)
        window.title = "Petal Notes"
        window.center()
        window.letContentGoWhenClosed()
        self.window = window
        return window
    }
}

/// What the window shows: which shelf, the search, and the notebook's canvas as last read.
@MainActor @Observable
final class NotesModel {
    var shelf: NoteLibrary.Shelf = .notebook(NoteShelf.inbox)
    var query = ""
    /// The canvas showing (its notebook and what its file says), read off the main thread: only while the folder's
    /// session it was read in is the one in use (a switch shows nothing of another folder's canvas).
    private var shownCanvas: (session: RootSession, notebook: String, layout: NoteCanvas?)?
    var canvas: (notebook: String, layout: NoteCanvas?)? {
        get { shownCanvas.flatMap { store.current($0.session) ? ($0.notebook, $0.layout) : nil } }
        set { shownCanvas = newValue.map { (store.session, $0.notebook, $0.layout) } }
    }
    /// While a note, area or words are dragged: where they are now, not written until the drag ends.
    var dragging: [String: NoteCanvas.Spot] = [:]
    /// The sidebar, hidden in a canvas to give it the whole window.
    var sidebar = true

    var desk: NoteDesk { PetalApp.shared.paper }
    var store: NoteStore { desk.store }

    /// Every note as the window weighs them (iCloud's other versions left out: their paper shows them), with what
    /// its search looks through folded once. Worked out for the notes as they are and kept until they change, so a
    /// character typed in the search, a notebook picked or a row hovered never goes through every note's words again.
    struct Index {
        var papers: [PaperNote] = []
        var items: [NoteLibrary.Item] = []
        var folded: [NoteText.Folded] = []
        var modified: [Date] = []
    }
    @ObservationIgnored private var kept: (session: ObjectIdentifier, version: Int, index: Index)?

    var index: Index {
        // (`notes` read first, so the window is drawn again when they change.)
        let notes = store.notes
        let session = ObjectIdentifier(store.session), version = store.notesVersion
        if let kept, kept.session == session, kept.version == version { return kept.index }
        var made = Index()
        made.papers = notes.filter { $0.version == nil }
        made.items = made.papers.map { NoteLibrary.Item(notebook: $0.notebook, file: $0.file) }
        made.folded = made.items.map(NoteLibrary.searched)
        made.modified = made.items.map(\.file.modified)
        kept = (session, version, made)
        return made
    }

    /// The person's search over every note (NoteLibrary.search), newest first.
    func found(_ query: String) -> [PaperNote] {
        let index = index
        return NoteLibrary.search(query, folded: index.folded, modified: index.modified).map { index.papers[$0] }
    }

    /// The canvas of `notebook`, read again (after any read of the notes' folder: another Mac may have moved things).
    func loadCanvas(_ notebook: String) {
        let captured = store.session
        store.canvas(notebook) { [weak self] layout in
            guard let self, self.store.current(captured), case .notebook(let now) = self.shelf, NoteLibrary.same(now, notebook) else { return }
            self.canvas = (notebook, layout)
        }
    }

    /// One change to the canvas, made on its file as it is then (NoteStore.editCanvas); shown at once.
    /// `at`: when the person made it (kept through any wait for a note's id).
    func edit(_ notebook: String, _ edit: NoteCanvas.Edit, at: Double = Date().timeIntervalSince1970) {
        guard desk.takesChanges() else { return }
        // A notebook not here yet (its folder not read): nothing changes on screen that couldn't be kept.
        guard store.canvasEditable(notebook) else { return desk.tell("Waiting for \(notebook) to download: its canvas can be changed once it's here.") }
        if let current = canvas, NoteLibrary.same(current.notebook, notebook), let layout = current.layout {
            canvas = (notebook, layout.applyingMerged([NoteCanvas.Stamped(edit, at: at)]))
        }
        let captured = store.session
        store.editCanvas(notebook, edit, at: at) { [weak self] saved in
            guard let self, self.store.current(captured), let saved, let current = self.canvas, NoteLibrary.same(current.notebook, notebook) else { return }
            self.canvas = (notebook, saved)
        }
    }

    /// An area moved with the notes in it, saved as one: every note by its own id (an id-less one given its id first,
    /// as a single move is); when any can't get one, nothing is saved and the preview snaps back.
    func moveGroup(_ notebook: String, area: NoteCanvas.Area, notes moves: [String: NoteCanvas.Spot]) {
        final class Waiting { var resolved: [String: String] = [:]; var left = 0 }
        let waiting = Waiting()
        let at = Date().timeIntervalSince1970   // the gesture's own time, kept through the wait
        // Any id not landed in its file yet (none, being written, or its write failed) is waited for.
        let idless = moves.keys.filter { !NoteShelf.lasting($0, pending: store.pendingIDs) }
        let captured = store.session
        let finish = { [weak self] in
            guard let self, self.store.current(captured) else { return }
            for id in moves.keys { self.dragging[id] = nil }
            guard let ids = CanvasQueue.groupMove(Array(moves.keys), resolved: waiting.resolved, pending: self.store.pendingIDs) else {
                return self.desk.tell("Petal couldn't give every note in that area an id of its own yet, so the area stayed where it was.")
            }
            self.edit(notebook, .area(area), at: at)
            for (old, spot) in moves { if let id = ids[old] { self.edit(notebook, .move(id, spot), at: at) } }
        }
        guard !idless.isEmpty else { return finish() }
        waiting.left = idless.count
        for id in idless {
            let done = { (new: String?) in
                if let new { waiting.resolved[id] = new }
                waiting.left -= 1
                if waiting.left == 0 { finish() }
            }
            guard let paper = store.notes.first(where: { $0.noteID == id && $0.version == nil }) else { done(nil); continue }
            store.ensureID(paper.key) { done($0) }
        }
    }

    /// An arrow between two notes, by their own ids (each given one first when its file has none).
    func arrow(from: PaperNote, to: PaperNote) {
        let notebook = from.notebook
        let at = Date().timeIntervalSince1970   // the gesture's own time, kept through the waits
        withID(from) { [weak self] a in
            self?.withID(to) { b in self?.edit(notebook, .arrow(.init(id: UUID().uuidString, from: a, to: b)), at: at) }
        }
    }

    /// A note's own id once it's in its file: at once when it is, else after `ensureID` (an id-less note given one, or
    /// an id still being written, or whose write failed, waited for until it lands); never an id-less note's path.
    private func withID(_ paper: PaperNote, _ then: @escaping @MainActor (String) -> Void) {
        guard !NoteShelf.lasting(paper.noteID, pending: store.pendingIDs) else { return then(paper.noteID) }
        let captured = store.session
        store.ensureID(paper.key) { [weak self] id in
            guard let self, self.store.current(captured), let id, !NoteShelf.needsID(id) else { return }
            then(id)
        }
    }

    /// A note's spot moved on the canvas: kept by its own id, given one first when its file has none (nothing lasting
    /// is kept by an id-less note's path).
    func move(_ paper: PaperNote, to spot: NoteCanvas.Spot) {
        let notebook = paper.notebook
        let at = Date().timeIntervalSince1970   // the gesture's own time: a later move always wins, whatever waited
        withID(paper) { [weak self] id in self?.edit(notebook, .move(id, spot), at: at) }
    }

    // MARK: Notebooks

    func newNotebook() {
        words(about: nil, "New notebook", "What's it for? Its name:", value: "") { name, _ in
            let colors = ["#a550a7", "#f74f9e", "#f7821b", "#ffc600", "#62ba46", "#8c8c8c", "#007aff"]
            let made = self.store.ensureNotebook(name, color: colors[self.store.notebooks.count % colors.count])
            self.shelf = .notebook(made)
        }
    }

    /// What a dialog was opened about: the notes' folder's session it was opened in, and the notebook (its binding
    /// then, and its name now) when it's about one.
    struct Asked {
        let session: RootSession
        let binding: NotebookBinding?
        let notebook: String
    }

    /// The one way the window asks the person anything (every dialog, alert or sheet): the folder's session and the
    /// notebook's binding are captured before it opens, and its answer is applied only while both still hold (the
    /// same folder in use, and the binding still finding that notebook, by its name now); else nothing is done, and
    /// the person is told. A notebook not read yet asks nothing.
    func dialog<Answer>(about notebook: String?, _ show: () -> Answer?, then apply: (Answer, Asked) -> Void) {
        guard desk.takesChanges() else { return }
        let session = store.session
        let binding = notebook.flatMap { store.binding($0) }
        if let notebook, binding == nil { return desk.tell("\(notebook) isn't read yet. Try again in a moment.") }
        guard let answer = show() else { return }
        guard store.current(session) else { return desk.tell("The notes folder changed meanwhile, so nothing was done.") }
        guard let binding, let notebook else { return apply(answer, Asked(session: session, binding: nil, notebook: "")) }
        guard case .found(let now) = store.resolve(binding) else {
            return desk.tell("\(notebook) changed meanwhile (it isn't the same notebook now), so nothing was done.")
        }
        apply(answer, Asked(session: session, binding: binding, notebook: now))
    }

    /// A few words asked for, through `dialog`.
    func words(about notebook: String?, _ title: String, _ message: String, value: String, then apply: (String, Asked) -> Void) {
        dialog(about: notebook, { Self.askWords(title, message, value: value) }, then: apply)
    }

    func rename(_ book: Notebook) {
        // Inbox is where notes go first, and Petal makes it again when it's gone: it keeps its name.
        guard !NoteLibrary.same(book.name, NoteShelf.inbox) else { return desk.tell("Inbox keeps its name: it's where notes go first.") }
        words(about: book.name, "Rename \(book.name)", "Its new name:", value: book.name) { name, asked in
            guard name != book.name, let binding = asked.binding else { return }
            self.renameAsked(book, to: name, as: (asked.session, binding))
        }
    }

    private func renameAsked(_ book: Notebook, to name: String, as captured: (session: RootSession, binding: NotebookBinding)) {
        // What's typed in its notes is saved first, and the rename waits for it (and anything else being written).
        for paper in store.notes where NoteLibrary.same(paper.notebook, book.name) { desk.editors[paper.key]?.flush() }
        let wasDefault = NoteLibrary.same(desk.defaultNotebook, book.name)
        let oldStack = Self.stackPath(book.folder)
        whenSettled(book.name, as: captured) { [weak self] now, binding in self?.store.renameNotebook(now, to: name, binding: binding) { [weak self] made in
            guard let self, let made else { return }
            let config = PetalApp.shared.config
            if wasDefault { config.set("notesNotebook", made) }
            let stacks = config.strings("stackFolders")
            if stacks.contains(oldStack) {
                config.set("stackFolders", stacks.map { $0 == oldStack ? Self.stackPath(self.store.root.appending(path: made)) : $0 })
            }
            self.desk.renamedNotebook(book.name, to: made)
            if case .notebook(let now) = self.shelf, NoteLibrary.same(now, book.name) { self.shelf = .notebook(made) }
        } }
    }

    /// `then` once none of a notebook's notes has work under way (looked at again for up to five seconds, never
    /// waited on); still busy by then, it runs anyway and the store says why it can't. The notebook is captured as
    /// it is now (the folder's session and its NotebookBinding): if the folder in use or the notebook's identity
    /// changes meanwhile, nothing is done, and the person is told.
    func whenSettled(_ notebook: String, as captured: (session: RootSession, binding: NotebookBinding)?,
                     then: @escaping @MainActor (String, NotebookBinding) -> Void) {
        guard let captured else { return desk.tell("\(notebook) isn't read yet. Try again in a moment.") }
        settle(notebook, captured.binding, captured.session, tries: 25, then: then)
    }


    private func settle(_ notebook: String, _ binding: NotebookBinding, _ captured: RootSession, tries: Int,
                        then: @escaping @MainActor (String, NotebookBinding) -> Void) {
        guard store.current(captured), case .found(let now) = store.resolve(binding) else {
            return desk.tell("\(notebook) changed meanwhile (another notes folder, or it isn't the same notebook), so nothing was done.")
        }
        guard tries > 0, store.notebookBusy(now) else { return then(now, binding) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated { self.settle(notebook, binding, captured, tries: tries - 1, then: then) }
        }
    }

    func makeDefault(_ book: Notebook) { PetalApp.shared.config.set("notesNotebook", book.name) }

    func setPrivate(_ book: Notebook, _ on: Bool) {
        guard desk.takesChanges() else { return }
        store.setCover(book.name, fields: ["private": on ? "true" : ""])
        desk.refreshPanels()
    }

    func setView(_ book: Notebook, _ view: NoteLibrary.View) {
        guard desk.takesChanges() else { return }
        store.setCover(book.name, fields: ["view": view == .canvas ? "canvas" : ""])
        if view == .canvas { loadCanvas(book.name) }
    }

    /// In the dock as a stack: the notebook's folder among the dock's folder stacks (the setting every stack uses).
    func inDock(_ book: Notebook) -> Bool { PetalApp.shared.config.strings("stackFolders").contains(Self.stackPath(book.folder)) }

    func toggleDock(_ book: Notebook) {
        let config = PetalApp.shared.config
        let path = Self.stackPath(book.folder)
        var stacks = config.strings("stackFolders")
        if stacks.contains(path) { stacks.removeAll { $0 == path } } else {
            stacks.append(path)
            if !config.bool("stacks") { config.set("stacks", true) }
        }
        config.set("stackFolders", stacks)
    }

    /// Asked first; all of it to the Trash (never deleted), its notes put away first. The default notebook stays.
    func trash(_ book: Notebook) {
        guard !NoteLibrary.same(desk.defaultNotebook, book.name), !NoteLibrary.same(book.name, NoteShelf.inbox) else {
            return desk.tell(NoteLibrary.same(book.name, NoteShelf.inbox) ? "Inbox stays: it's where notes go first."
                             : "\(book.name) is your default notebook: make another the default first.")
        }
        // The notebook as the person sees it now: what's confirmed is this one, in this notes folder.
        dialog(about: book.name, { Self.confirmTrash(book) }) { _, asked in
            guard let binding = asked.binding else { return }
            self.trashAsked(book, as: (asked.session, binding))
        }
    }

    private func trashAsked(_ book: Notebook, as captured: (session: RootSession, binding: NotebookBinding)) {
        for paper in store.notes where NoteLibrary.same(paper.notebook, book.name) {
            desk.editors[paper.key]?.flush()
            desk.hide(paper.key)
        }
        let path = Self.stackPath(book.folder)
        whenSettled(book.name, as: captured) { [weak self] now, binding in self?.store.trashNotebook(now, binding: binding) { [weak self] done in
            guard let self, done else { return }
            let config = PetalApp.shared.config
            if config.strings("stackFolders").contains(path) { config.set("stackFolders", config.strings("stackFolders").filter { $0 != path }) }
            if case .notebook(let now) = self.shelf, NoteLibrary.same(now, book.name) { self.shelf = .notebook(self.desk.defaultNotebook) }
        } }
    }

    /// A folder as the dock's stacks name it ("~/…").
    static func stackPath(_ folder: URL) -> String {
        let path = folder.standardizedFileURL.path, home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Only through `dialog`: never opened on its own. True when the person said Move to Trash.
    private static func confirmTrash(_ book: Notebook) -> Bool? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move “\(book.name)” to the Trash?"
        alert.informativeText = book.count == 0 ? "It has no notes." : "Its \(book.count == 1 ? "note goes" : "\(book.count) notes go") with it. You can put it back from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? true : nil
    }

    /// Only through `words` (and so `dialog`): never opened on its own.
    private static func askWords(_ title: String, _ message: String, value: String) -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: value.isEmpty ? "Make" : "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let name = alert.runModal() == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespaces) : ""
        return name.isEmpty ? nil : name
    }
}

// MARK: - The look

/// The window's colors: the sketch's in light, their dark counterparts in dark. Paper stays paper.
struct NotesLook: Equatable {
    let dark: Bool
    var sidebar: Color { dark ? Color(white: 0.16) : Color(.sRGB, red: 0xf1 / 255.0, green: 0xf1 / 255.0, blue: 0xf4 / 255.0) }
    var main: Color { dark ? Color(white: 0.11) : .white }
    var line: Color { dark ? Color(white: 0.24) : Color(.sRGB, red: 0xe2 / 255.0, green: 0xe2 / 255.0, blue: 0xe6 / 255.0) }
    var text: Color { dark ? Color(white: 0.9) : Color(white: 0.2) }
    var dim: Color { dark ? Color(white: 0.55) : Color(white: 0.6) }
    var header: Color { dark ? Color(white: 0.5) : Color(.sRGB, red: 0x8a / 255.0, green: 0x8a / 255.0, blue: 0x8f / 255.0) }
    var field: Color { dark ? Color(white: 0.22) : Color(.sRGB, red: 0xe4 / 255.0, green: 0xe4 / 255.0, blue: 0xe9 / 255.0) }
    var picked: Color { dark ? Color.white.opacity(0.09) : Color.black.opacity(0.07) }
    var toggle: Color { dark ? Color(white: 0.2) : Color(.sRGB, red: 0xec / 255.0, green: 0xec / 255.0, blue: 0xf0 / 255.0) }
    var toggleOn: Color { dark ? Color(white: 0.34) : .white }
    var canvas: Color { dark ? Color(white: 0.13) : Color(.sRGB, red: 0xfa / 255.0, green: 0xfa / 255.0, blue: 0xfa / 255.0) }
    var dots: Color { dark ? Color(white: 0.24) : Color(.sRGB, red: 0xdc / 255.0, green: 0xdc / 255.0, blue: 0xe2 / 255.0) }
    var faded: Color { dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05) }
}

// MARK: - The window's view

struct NotesWindowView: View {
    @Environment(PetalApp.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.snapshotting) private var snapshotting
    let model: NotesModel
    var now = Date()
    /// Snapshots: where the files live, as words (live: the notes' folder).
    var rootPath: String? = nil
    /// The page's scroll view, put back at its top when it shows other notes.
    @State private var top = ScrollPosition(edge: .top)

    private var look: NotesLook { NotesLook(dark: scheme == .dark) }
    private var store: NoteStore { app.paper.store }


    private var book: Notebook? {
        guard case .notebook(let name) = model.shelf else { return nil }
        return store.notebook(name) ?? store.notebook(app.paper.defaultNotebook) ?? store.notebooks.first
    }

    private var canvasShowing: Bool { model.query.isEmpty && book?.view == .canvas }

    /// Whether a Private notebook's note is showing (its page, a search hit, a view across notebooks): the window is
    /// left out of Petal's own pictures while it is (and macOS asked not to share it, a best effort only).
    private var showingPrivate: Bool {
        let books = store.privateBooks
        guard !books.isEmpty else { return false }
        let all = model.index
        let shown: [PaperNote]
        if !model.query.isEmpty { shown = model.found(model.query) }
        else if let book { return book.isPrivate }
        else { shown = NoteLibrary.listed(model.shelf, all.items, now: now).map { all.papers[$0] } }
        return shown.contains { paper in books.contains { NoteLibrary.same($0, paper.notebook) } }
    }

    var body: some View {
        let showingPrivate = self.showingPrivate
        HStack(spacing: 0) {
            if model.sidebar || !canvasShowing {
                sidebar.frame(width: 240)
                Rectangle().fill(look.line).frame(width: 1)
            }
            main
        }
        .background(look.main)
        .ignoresSafeArea()
        .onAppear { app.notesWindow.showingPrivate(showingPrivate) }
        .onChange(of: showingPrivate) { _, on in app.notesWindow.showingPrivate(on) }
        .onChange(of: store.reads) { _, _ in if canvasShowing, let book { model.loadCanvas(book.name) } }
        .onChange(of: book?.name) { _, name in if canvasShowing, let name { model.loadCanvas(name) } }
        .onChange(of: canvasShowing) { _, on in if on, let book { model.loadCanvas(book.name) } }
        .onAppear { if canvasShowing, let book { model.loadCanvas(book.name) } }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let files = model.index.items
        let books = store.notebooks
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(look.dim)
                if snapshotting {
                    Text(model.query.isEmpty ? "Search every note" : model.query).font(.system(size: 12.5)).foregroundStyle(look.dim)
                    Spacer(minLength: 0)
                } else {
                    TextField("Search every note", text: Bindable(model).query).textFieldStyle(.plain).font(.system(size: 12.5))
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(look.field, in: .rect(cornerRadius: 8))
            .padding(.bottom, 4)

            header("Coming up")
            shelfRow(.comingBack, symbol: "alarm", title: "Coming back", count: NoteLibrary.listed(.comingBack, files, now: now).count)
            shelfRow(.watching, symbol: "smallcircle.filled.circle", title: "Watching", count: NoteLibrary.listed(.watching, files, now: now).count)
            shelfRow(.helpers, symbol: "sparkle", title: "Helpers at work", count: NoteLibrary.listed(.helpers, files, now: now).count)

            header("Notebooks")
            // The notebooks scroll when there are more than fit (many of them, or the window at its smallest), and
            // "+ Notebook" stays pinned under the list, always in reach.
            notebookList(books)
            Button { model.newNotebook() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 10)
                    Text("Notebook")
                    Spacer()
                }
                .font(.system(size: 13.5)).foregroundStyle(look.dim)
                .padding(.horizontal, 8).padding(.vertical, 6).contentShape(.rect)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.top, 50).padding(.horizontal, 12).padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(look.sidebar.opacity(snapshotting ? 1 : 0.62))
    }

    /// The notebooks, in a vertical scroll view: as tall as its rows while they fit (so "+ Notebook" sits right under
    /// them), else as tall as the room that's left, scrolling. The rows are an eager stack (a lazy one in this
    /// window's glass misbehaves as a settings page's does). While snapshotting, where scroll views draw as
    /// placeholders, a stand-in of the same size: the rows from the top, cut where the scroll view ends.
    @ViewBuilder private func notebookList(_ books: [Notebook]) -> some View {
        let stacks = Set(app.config.strings("stackFolders"))
        let rows = VStack(alignment: .leading, spacing: 1) {
            ForEach(books) { book in
                // Drawn again only when something it shows changed (not for every character typed in the search).
                NotebookRow(book: book, on: model.query.isEmpty && model.shelf == .notebook(book.name),
                            isDefault: NoteLibrary.same(app.paper.defaultNotebook, book.name), color: store.color(of: book.name),
                            inDock: stacks.contains(NotesModel.stackPath(book.folder)), look: look, droppable: !snapshotting, model: model)
                    .equatable()
            }
        }
        if snapshotting {
            ViewThatFits(in: .vertical) {
                rows
                Color.clear.overlay(alignment: .top) { rows.fixedSize(horizontal: false, vertical: true) }.clipped()
            }
        } else {
            ViewThatFits(in: .vertical) {
                ScrollView(.vertical) { rows }.fixedSize(horizontal: false, vertical: true)
                ScrollView(.vertical) { rows }
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(look.header)
            .padding(.top, 12).padding(.horizontal, 8).padding(.bottom, 5)
    }

    private func shelfRow(_ shelf: NoteLibrary.Shelf, symbol: String, title: String, count: Int) -> some View {
        let on = model.query.isEmpty && model.shelf == shelf
        return Button { model.query = ""; model.shelf = shelf } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 11.5)).frame(width: 14)
                Text(title).fontWeight(on ? .semibold : .regular)
                Spacer(minLength: 4)
                if count > 0 { Text("\(count)").foregroundStyle(look.dim) }
            }
            .font(.system(size: 13.5)).foregroundStyle(look.text)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(on ? look.picked : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Main

    /// What the main area shows: a search's hits, a notebook's notes (its cover first), or a view across notebooks.
    private struct Shown {
        var title: String, subtitle: String
        var book: Notebook?
        var papers: [PaperNote]
        var cover: PaperNote?
        var across: Bool
    }

    private var shown: Shown {
        if !model.query.isEmpty {
            let hits = model.found(model.query)
            return Shown(title: "Search", subtitle: hits.count == 1 ? "1 note" : "\(hits.count) notes", book: nil, papers: hits, cover: nil, across: true)
        }
        let all = model.index
        if let book {
            let listed = NoteLibrary.listed(.notebook(book.name), all.items, now: now).map { all.papers[$0] }
            return Shown(title: book.name, subtitle: subtitle(book), book: book, papers: listed, cover: book.cover.flatMap { store.paper($0) }, across: false)
        }
        let listed = NoteLibrary.listed(model.shelf, all.items, now: now).map { all.papers[$0] }
        let (title, empty) = shelfWords
        return Shown(title: title, subtitle: listed.isEmpty ? empty : listed.count == 1 ? "1 note" : "\(listed.count) notes", book: nil, papers: listed, cover: nil, across: true)
    }

    /// One page for a search, a notebook and a view alike: typing in the search or picking another notebook puts new
    /// notes in the page that's there (its papers reused, NotesGrid), never a new page built from nothing.
    @ViewBuilder private var main: some View {
        let shown = self.shown
        if canvasShowing, let book = shown.book {
            NotesCanvasView(model: model, book: book, papers: shown.papers, look: look)
        } else {
            page(title: shown.title, subtitle: shown.subtitle, book: shown.book, papers: shown.papers, cover: shown.cover, across: shown.across)
                // Other notes to show: from their top.
                .onChange(of: "\(model.shelf)\n\(model.query)") { _, _ in top = ScrollPosition(edge: .top) }
        }
    }

    private var shelfWords: (String, String) {
        switch model.shelf {
        case .comingBack: ("Coming back", "Nothing is coming back. Ask @Petal in a note to bring it back at a time.")
        case .watching: ("Watching", "Nothing is being watched.")
        case .helpers: ("Helpers at work", "No helper is at work.")
        case .notebook(let name): (name, "")
        }
    }

    private func subtitle(_ book: Notebook) -> String {
        var parts = [book.count == 1 ? "1 note" : "\(book.count) notes",
                     NoteLibrary.whereWords(root: rootPath ?? store.root.path, notebook: book.name, home: NSHomeDirectory())]
        if model.inDock(book) { parts.append("in the dock as a stack") }
        if book.isPrivate { parts.append("private: kept from Petal AI, previews, other notebooks and Petal's pictures") }
        return parts.joined(separator: " · ")
    }

    private func page(title: String, subtitle: String, book: Notebook?, papers: [PaperNote], cover: PaperNote?, across: Bool) -> some View {
        let fresh = papers.filter { !NoteShelf.faded(modified: $0.file.modified, now: now) }
        let faded = papers.filter { NoteShelf.faded(modified: $0.file.modified, now: now) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.26).foregroundStyle(look.dark ? Color.white : Color(white: 0.11))
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(look.dim).lineLimit(1)
                }
                Spacer()
                if let book { viewToggle(book) }
            }
            .padding(.top, 38).padding(.horizontal, 36).padding(.trailing, -16)
            ScrollDown {
                VStack(alignment: .leading, spacing: 14) {
                    NotesGrid(papers: fresh, cover: cover, across: across, now: now)
                    if !faded.isEmpty {
                        FlowRows(items: faded, width: 150, gap: 14) { paper in
                            FadedLine(paper: paper, look: look)
                        }
                    }
                    if papers.isEmpty && cover == nil {
                        Text("No notes here yet.").font(.system(size: 13)).foregroundStyle(look.dim).padding(.top, 20)
                    }
                }
                .padding(.horizontal, 36).padding(.top, 20).padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition($top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func viewToggle(_ book: Notebook) -> some View {
        NotesViewToggle(view: book.view, look: look) { model.setView(book, $0) }.padding(.top, 4)
    }
}

/// One notebook in the sidebar: its color, name, what it is (default, private) and how many notes; its menu on a
/// right-click; notes dropped on it are moved there. Drawn again only when something it shows changed (`==`), so a
/// character typed in the search doesn't build every notebook's row and menu again.
struct NotebookRow: View, Equatable {
    @Environment(PetalApp.self) private var app
    let book: Notebook
    let on: Bool
    let isDefault: Bool
    let color: NSColor
    let inDock: Bool
    let look: NotesLook
    let droppable: Bool
    let model: NotesModel

    static func == (a: NotebookRow, b: NotebookRow) -> Bool {
        a.book == b.book && a.on == b.on && a.isDefault == b.isDefault && a.color == b.color && a.inDock == b.inDock && a.look == b.look
            && a.droppable == b.droppable && a.model === b.model
    }

    var body: some View {
        Button { model.query = ""; model.shelf = .notebook(book.name) } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: color)).frame(width: 10, height: 10)
                Text(book.name).fontWeight(on ? .semibold : .regular).lineLimit(1)
                if isDefault { Text("default").font(.system(size: 11)).foregroundStyle(look.dim) }
                if book.isPrivate { Text("private").font(.system(size: 11)).foregroundStyle(look.dim) }
                Spacer(minLength: 4)
                Text("\(book.count)").foregroundStyle(look.dim)
            }
            .font(.system(size: 13.5)).foregroundStyle(look.text)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(on ? look.picked : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .modifier(NoteDropTarget(on: droppable) { drop($0, into: book.name) })
        .contextMenu { menu }
    }

    @ViewBuilder private var menu: some View {
        Button("Rename…") { model.rename(book) }.disabled(NoteLibrary.same(book.name, NoteShelf.inbox))
        Menu("Color") {
            ForEach(NotesColors.choices, id: \.value) { choice in
                Button(choice.name) { app.paper.recolor(book.name, choice.value) }
            }
        }
        Button(book.view == .canvas ? "Show as a grid" : "Show as a canvas") { model.setView(book, book.view == .canvas ? .grid : .canvas) }
        Divider()
        Button("Make it the default") { model.makeDefault(book) }.disabled(isDefault)
        Toggle("Private", isOn: Binding(get: { book.isPrivate }, set: { model.setPrivate(book, $0) }))
        Toggle("In the dock as a stack", isOn: Binding(get: { inDock }, set: { _ in model.toggleDock(book) }))
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([book.folder]) }
        Divider()
        Button("Move to Trash…") { model.trash(book) }.disabled(isDefault || NoteLibrary.same(book.name, NoteShelf.inbox))
    }

    /// Notes dropped on a notebook: each moved there (the one move: what's typed goes along).
    private func drop(_ providers: [NSItemProvider], into notebook: String) {
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.petalNote.identifier) { data, _ in
                guard let data else { return }
                let id = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let paper = app.paper.store.current(id) else { return }
                        app.paper.move(paper.key, to: notebook)
                    }
                }
            }
        }
    }
}

/// The colors a notebook can have (the sketch's, and the Mac's accent).
enum NotesColors {
    static let choices: [(name: String, value: String)] = [("Mac's accent color", "accent"), ("Blue", "#007aff"), ("Purple", "#a550a7"), ("Pink", "#f74f9e"),
                                                           ("Orange", "#f7821b"), ("Yellow", "#ffc600"), ("Green", "#62ba46"), ("Graphite", "#8c8c8c")]
}

/// Grid | Canvas, as the sketch's small toggle.
struct NotesViewToggle: View {
    let view: NoteLibrary.View
    let look: NotesLook
    let pick: (NoteLibrary.View) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach([NoteLibrary.View.grid, .canvas], id: \.self) { option in
                Button { pick(option) } label: {
                    Text(option == .grid ? "Grid" : "Canvas").font(.system(size: 12))
                        .foregroundStyle(view == option ? (look.dark ? Color.white : Color(white: 0.07)) : look.dim)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background {
                            if view == option {
                                RoundedRectangle(cornerRadius: 6).fill(look.toggleOn).shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(look.toggle, in: .rect(cornerRadius: 8))
    }
}

/// A note dragged out (to a notebook in the sidebar, or an app in the dock).
struct NoteDragSource: ViewModifier {
    let paper: PaperNote
    let on: Bool

    func body(content: Content) -> some View {
        if on { content.onDrag { NoteDrag.provider(paper) } } else { content }
    }
}

/// Notes dropped here (a notebook in the sidebar). Left out of snapshots, which can't draw a drop target.
struct NoteDropTarget: ViewModifier {
    let on: Bool
    let dropped: ([NSItemProvider]) -> Void

    func body(content: Content) -> some View {
        if on { content.onDrop(of: [.petalNote], isTargeted: nil) { dropped($0); return true } } else { content }
    }
}

/// Rows of fixed-width items, wrapping.
struct FlowRows<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let width: CGFloat
    let gap: CGFloat
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width), spacing: gap, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items) { content($0) }
        }
    }
}

// MARK: - The grid

/// A notebook's notes as the sketch's grid: 150-point papers, 14 apart, the cover first and two rows tall.
/// Every paper has its place by arithmetic (NoteLibrary.gridSlots), so the grid is as tall as all its rows, but only
/// the rows in or near what its scroll view shows are made, and their views are reused as it scrolls and as its notes
/// change: a notebook of hundreds of notes, or a search that finds them all, opens and scrolls like one of twenty.
struct NotesGrid: View {
    @Environment(PetalApp.self) private var app
    @Environment(\.snapshotting) private var snapshotting
    /// The grid's width as laid out (its height follows the columns that fit in it), and the rows in sight.
    @State private var sight = Sight(width: 900, first: 0, count: 6)
    let papers: [PaperNote]
    let cover: PaperNote?
    /// Notes from several notebooks (a view, a search): each says its notebook.
    let across: Bool
    let now: Date

    static let cell: CGFloat = 150
    static let gap: CGFloat = 14

    /// The grid's width, and the rows made: `count` of them from `first`.
    struct Sight: Equatable {
        var width: CGFloat
        var first: Int, count: Int
    }

    struct Placed: Identifiable {
        let paper: PaperNote
        let column: Int, row: Int
        /// Which of the views made shows it (`reuse`).
        let id: Int
    }

    /// Rows made beyond what shows, above and below: there before they scroll in.
    static let ahead = 1
    /// Every row (no scroll view: a snapshot).
    static let everyRow = Int.max / 4

    /// Which view shows the paper at (`row`, `column`): one per place among the rows made, so a row scrolled out of
    /// them hands its views to the row scrolling in, and a search's hits are shown in the views that were there, as
    /// a table reuses its cells. With every row made (a snapshot), each paper its own.
    static func reuse(row: Int, column: Int, rows count: Int) -> Int { (count >= everyRow ? row : row % max(1, count)) * 4096 + column }

    /// The rows to make for what a scroll view shows of the grid (`visible`, in the grid's own coordinates): as many
    /// as it's tall and `ahead` more either side, the same number wherever it's scrolled to (so their views can be
    /// reused). No scroll view (a snapshot): every row.
    static func sight(width: CGFloat, showing visible: CGRect?) -> Sight {
        guard let visible, visible.height > 0 else { return Sight(width: width, first: 0, count: everyRow) }
        let pitch = cell + gap
        return Sight(width: width, first: max(0, Int((visible.minY / pitch).rounded(.down)) - ahead),
                     count: Int((visible.height / pitch).rounded(.up)) + 1 + 2 * ahead)
    }

    var body: some View {
        let columns = NoteLibrary.columns(width: sight.width, cell: Self.cell, gap: Self.gap)
        let slots = NoteLibrary.gridSlots(count: papers.count, columns: columns, cover: cover != nil)
        let rows = snapshotting ? Sight(width: sight.width, first: 0, count: Self.everyRow) : sight
        let made = papers.indices.compactMap { index -> Placed? in
            let slot = slots[index]
            guard slot.row >= rows.first, slot.row - rows.first < rows.count else { return nil }
            return Placed(paper: papers[index], column: slot.column, row: slot.row, id: Self.reuse(row: slot.row, column: slot.column, rows: rows.count))
        }
        // Each paper put where its slot is, at its own size: the grid never asks a paper how big it would like to
        // be or where its edges are (GridSlots), so laying it out costs the same however much each paper holds.
        GridSlots(height: height(columns: columns)) {
            if let cover {
                CoverPaper(paper: cover).layoutValue(key: GridSlots.Slot.self, value: GridSlots.Place(column: 0, row: 0, tall: true))
            }
            ForEach(made) { placed in
                GridPaper(paper: placed.paper, across: across, now: now).equatable()
                    .layoutValue(key: GridSlots.Slot.self, value: GridSlots.Place(column: placed.column, row: placed.row, tall: false))
            }
        }
        .onGeometryChange(for: Sight.self) { geometry in
            Self.sight(width: geometry.size.width, showing: geometry.bounds(of: .scrollView(axis: .vertical)))
        } action: { sight = $0 }
    }

    /// The grid's height: its rows at the columns that fit its width now.
    private func height(columns: Int) -> CGFloat {
        let rows = NoteLibrary.gridRows(count: papers.count, columns: columns, cover: cover != nil)
        return rows == 0 ? 0 : CGFloat(rows) * (Self.cell + Self.gap) - Self.gap + 4
    }
}

/// The grid's layout: as wide as it's offered and as tall as its rows, each paper placed at its slot (a cell of 150
/// points, the cover two rows tall) without being measured.
struct GridSlots: Layout {
    struct Place: Equatable {
        var column = 0, row = 0
        var tall = false
    }
    struct Slot: LayoutValueKey {
        static let defaultValue = Place()
    }
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 900, height: height)
    }

    // (No guides of its own: nothing that lines the grid up needs to place and measure its papers to find any.)
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let pitch = NotesGrid.cell + NotesGrid.gap
        for subview in subviews {
            let place = subview[Slot.self]
            let size = CGSize(width: NotesGrid.cell, height: place.tall ? NotesGrid.cell * 2 + NotesGrid.gap : NotesGrid.cell)
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(place.column) * pitch, y: bounds.minY + CGFloat(place.row) * pitch), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
        }
    }
}

/// One note in the grid: its words on its notebook's paper, and the one line of what's coming or where it's stuck.
/// Clicking it opens it on its own; it can be dragged to another notebook or onto an app in the dock.
struct GridPaper: View, Equatable {
    /// Drawn again only when the note or how it's shown changed (not whenever the grid around it is laid out again).
    static func == (a: GridPaper, b: GridPaper) -> Bool {
        a.paper == b.paper && a.across == b.across && a.now == b.now && a.size == b.size && a.draggable == b.draggable && a.words == b.words
    }

    @Environment(PetalApp.self) private var app
    let paper: PaperNote
    var across = false
    let now: Date
    var size: CGFloat = NotesGrid.cell
    /// Before it opens on its own (a stack's fan closes).
    var opening: () -> Void = {}
    /// Dragged out to another notebook or an app in the dock (not on a canvas, where dragging moves it).
    var draggable = true
    /// Its words' size: 12.5 points in the grid, a note's own 13.5 on a canvas (the sketch's).
    var words: CGFloat = 12.5

    var body: some View {
        let color = app.paper.store.color(of: paper.notebook)
        let tint = PaperLook.rgb(color)
        let watch = NoteContract.watch(paper.file)
        let footer = NoteLibrary.footer(paper.file, place: Self.place(paper), now: now)
        let titled = NoteText.titled(paper.file.body)
        VStack(alignment: .leading, spacing: 0) {
            if across {
                Text(paper.notebook).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(PaperLook.color(NoteInk.letterhead(tint)))
                    .lineLimit(1).padding(.bottom, 7)
            }
            VStack(alignment: .leading, spacing: 3) {
                if titled { Text(paper.file.title).font(.system(size: 14, weight: .bold)).lineLimit(2) }
                // (No more of its words than a paper this size can show: the rest would be laid out only to be cut off.)
                Text(String((titled ? paper.file.preview : [paper.file.title, paper.file.preview].filter { !$0.isEmpty }.joined(separator: " ")).prefix(Self.shownWords)))
                    .font(.system(size: words, weight: .medium)).lineLimit(Self.shownLines)
            }
            // The sketch's line height for a paper's words (1.32).
            .lineSpacing(words * (1.32 - 1.193))
            .foregroundStyle(PaperLook.words)
            .padding(.top, watch == nil ? 0 : watch?.history.isEmpty == false ? 46 : 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            let tasks = NoteContract.taskItems(paper.file)
            if !tasks.isEmpty { TaskChips(items: tasks, tint: tint).padding(.bottom, 6) }
            HStack(spacing: 6) {
                if footer.dot { Circle().fill(Color(nsColor: color)).frame(width: 7, height: 7).opacity(footer.working ? 0.6 : 1) }
                Text(footer.text).font(.system(size: 11)).foregroundStyle(PaperLook.footer).lineLimit(1)
            }
        }
        .padding(.top, 15).padding(.horizontal, 14).padding(.bottom, 12)
        .frame(width: size, height: size, alignment: .topLeading)
        .overlay(alignment: .topTrailing) { if let watch { WatchNumber(watch: watch, tint: tint).padding(14) } }
        .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: color)).frame(height: 5) }
        .clipShape(.rect(cornerRadius: 12))
        .background { PaperLook.color(NoteInk.paper(tint)).clipShape(.rect(cornerRadius: 12)).modifier(PaperShadow(glass: false)) }
        .environment(\.colorScheme, .light)
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture { opening(); Self.open(paper, app: app) }
        .contextMenu {
            Button("Open") { opening(); Self.open(paper, app: app) }
            Divider()
            Button("Move to Trash") { app.paper.throwAway(paper.key) }
        }
        .modifier(NoteDragSource(paper: paper, on: draggable))
    }

    /// More lines and characters than a 150-point paper shows at this size (seven lines of about twenty): what's
    /// past them is never set in type only to be cut off.
    static let shownLines = 8
    static let shownWords = 170

    /// Opens it on its own, its corner by the pointer.
    static func open(_ paper: PaperNote, app: PetalApp) {
        let mouse = NSEvent.mouseLocation
        app.paper.openStandalone(paper.key, at: CGPoint(x: mouse.x - 60, y: mouse.y + 60), fromLibrary: app.notesWindow.window?.isKeyWindow == true)
    }

    /// Where it's stuck, as the grid says it (its first place: a site, a file, a person, a Desktop).
    static func place(_ paper: PaperNote) -> String? {
        guard let first = paper.file.places.first else { return nil }
        switch first.kind {
        case .desktop: return first.desktop.map { "On Desktop \($0)" } ?? "On the Desktop"
        case .screen: return "On screen"
        case .window: return first.appName.isEmpty ? first.label() : first.appName + (first.title.isEmpty ? "" : " · " + first.title)
        case .person: return first.title + " · any chat app"
        default: return NoteText.site(first.label())
        }
    }
}

/// A task's parts as the sketch's chips, and Open all.
struct TaskChips: View {
    @Environment(PetalApp.self) private var app
    let items: [NoteContract.TaskItem]
    let tint: NoteInk.RGB

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                // The first part, and how many more: a 150-point paper has room for no more.
                if let first = items.first { chip(NoteTasks.chip(first)) }
                if items.count > 1 { chip("+\(items.count - 1)").fixedSize() }
            }
            Button { app.paper.openAll(items) } label: {
                Text("Open all \(items.count)").underline().font(.system(size: 10.5, weight: .medium)).foregroundStyle(PaperLook.color(NoteInk.letterhead(tint)))
            }
            .buttonStyle(.plain)
            .help("Brings back its tabs, files and mail")
        }
    }

    private func chip(_ words: String) -> some View {
        Text(words).font(.system(size: 10.5)).foregroundStyle(Color(white: 0.2)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(PaperLook.color(NoteInk.mix(tint, 0.12, NoteInk.paper)), in: .rect(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.12), lineWidth: 0.5) }
    }
}

/// A watcher's newest number, with the older ones struck (the sketch's corner).
struct WatchNumber: View {
    let watch: NoteContract.Watch
    let tint: NoteInk.RGB

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(watch.last.isEmpty ? "…" : watch.last).font(.system(size: 24, weight: .bold)).tracking(-0.48)
                .foregroundStyle(PaperLook.color(NoteInk.mix(tint, 0.65, NoteInk.black)))
            if !watch.history.isEmpty {
                Text(watch.history.prefix(2).joined(separator: " · ")).font(.system(size: 11)).strikethrough().foregroundStyle(Color(white: 0.6))
            }
            // A crossing that couldn't be confirmed: its number, faint, as on the note itself (WatchCorner); the last
            // accepted value stays above it.
            if !watch.unconfirmed.isEmpty {
                Text(watch.unconfirmed + " · couldn't confirm").font(.system(size: 9.5)).foregroundStyle(Color(white: 0.6)).lineLimit(1)
            }
        }
    }
}

/// The notebook's cover, first and taller: what it's for, what Petal remembers there.
struct CoverPaper: View {
    @Environment(PetalApp.self) private var app
    let paper: PaperNote

    var body: some View {
        let color = app.paper.store.color(of: paper.notebook)
        let tint = PaperLook.rgb(color)
        let parts = NoteLibrary.cover(paper.file.body)
        VStack(alignment: .leading, spacing: 0) {
            Text("About this notebook").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(PaperLook.color(NoteInk.letterhead(tint)))
                .padding(.bottom, 9)
            Text(parts.about.isEmpty ? "What this notebook is for." : parts.about).font(.system(size: 12.5)).foregroundStyle(PaperLook.words)
                .lineSpacing(12.5 * (1.32 - 1.193)).lineLimit(6)
            Text("PETAL REMEMBERS").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(white: 0.47)).padding(.top, 10).padding(.bottom, 2)
            if parts.remembers.isEmpty {
                Text("Nothing yet.").font(.system(size: 11.5)).foregroundStyle(Color(white: 0.55)).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .top) { Rectangle().fill(.black.opacity(0.07)).frame(height: 1) }
            }
            ForEach(Array(parts.remembers.prefix(6).enumerated()), id: \.offset) { _, memory in
                Text(memory).font(.system(size: 11.5)).foregroundStyle(PaperLook.words).lineLimit(1).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(.black.opacity(0.07)).frame(height: 1) }
            }
            Spacer(minLength: 6)
            Text("Helpers read this first. Edit it like any note.").font(.system(size: 11)).foregroundStyle(Color(white: 0.53))
                .padding(.trailing, 20)
        }
        .padding(.top, 15).padding(.horizontal, 14).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: color)).frame(height: 5) }
        .overlay(alignment: .bottomTrailing) { FoldCorner().fill(Color.black.opacity(0.13)).frame(width: 24, height: 24) }
        .clipShape(.rect(cornerRadius: 12))
        .background { PaperLook.color(NoteInk.paper(tint)).clipShape(.rect(cornerRadius: 12)).modifier(PaperShadow(glass: false)) }
        .environment(\.colorScheme, .light)
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture { GridPaper.open(paper, app: app) }
    }
}

/// A note untouched for a month: a faint line with its first words (still there; clicking opens it).
struct FadedLine: View {
    @Environment(PetalApp.self) private var app
    let paper: PaperNote
    let look: NotesLook

    var body: some View {
        Text(paper.file.title.isEmpty ? "A note" : paper.file.title).font(.system(size: 11)).foregroundStyle(look.dim).lineLimit(1)
            .padding(.horizontal, 9).frame(width: 150, height: 22, alignment: .leading)
            .background(look.faded, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
            .onTapGesture { GridPaper.open(paper, app: app) }
            .onDrag { NoteDrag.provider(paper) }
    }
}

// MARK: - Canvas

/// A notebook's canvas: the same notes laid out freely, labeled areas, arrows between notes and words written on
/// it, zoomed with − 100% +. Every change is one edit on the notebook's `.canvas.json` (NotesModel.edit).
struct NotesCanvasView: View {
    @Environment(PetalApp.self) private var app
    @Environment(\.snapshotting) private var snapshotting
    let model: NotesModel
    let book: Notebook
    let papers: [PaperNote]
    let look: NotesLook

    private var layout: NoteCanvas? {
        guard let canvas = model.canvas, NoteLibrary.same(canvas.notebook, book.name) else { return snapshotting ? NoteCanvas() : nil }
        return canvas.layout
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 10) {
                    Button { model.sidebar.toggle() } label: { Image(systemName: "sidebar.left").font(.system(size: 13)) }
                        .buttonStyle(.plain).foregroundStyle(look.dim).padding(.leading, model.sidebar ? 16 : 84)
                    Text(book.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(look.text)
                    // Edits kept and tried again (NoteStore.editCanvas): never lost quietly.
                    if app.paper.store.canvasUnsaved.contains(book.name) {
                        Text("Not saved yet: Petal keeps your changes and tries again").font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.7, green: 0.15, blue: 0.12))
                    }
                    Spacer()
                }
                NotesViewToggle(view: .canvas, look: look) { model.setView(book, $0) }
            }
            .frame(height: 44)
            if let layout {
                CanvasBoard(model: model, book: book, papers: papers, layout: layout, look: look)
            } else if model.canvas != nil {
                Text("Petal can't read this notebook's canvas file, so it leaves it as it is.").font(.system(size: 13)).foregroundStyle(look.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                look.canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The board itself: dots, areas, arrows, words and papers, scrolled and zoomed.
struct CanvasBoard: View {
    @Environment(PetalApp.self) private var app
    let model: NotesModel
    let book: Notebook
    let papers: [PaperNote]
    let layout: NoteCanvas
    let look: NotesLook

    var body: some View {
        let ids = papers.map(\.noteID)
        let spots = layout.spots(for: ids, columns: 6).merging(model.dragging) { _, dragged in dragged }
        let zoom = CGFloat(layout.zoom)
        let extent = extent(spots)
        let tint = app.paper.store.color(of: book.name)
        ZStack(alignment: .bottomTrailing) {
            Scroll2D {
                ZStack(alignment: .topLeading) {
                    CanvasDots(color: look.dots).frame(width: extent.width, height: extent.height)
                        .contentShape(.rect)
                        .contextMenu { boardMenu() }
                    ForEach(layout.areas) { area in
                        CanvasArea(area: area, color: tint, look: look, model: model, book: book, notes: layout.inside(area, spots: spots), spots: spots)
                    }
                    CanvasArrows(arrows: layout.arrows, spots: spots).allowsHitTesting(false)
                    ForEach(layout.texts) { words in
                        CanvasWords(words: words, look: look, model: model, book: book)
                    }
                    ForEach(papers, id: \.key) { paper in
                        if let spot = spots[paper.noteID] {
                            CanvasPaper(paper: paper, spot: spot, model: model, others: papers.filter { $0.noteID != paper.noteID }, layout: layout)
                        }
                    }
                }
                .frame(width: extent.width, height: extent.height, alignment: .topLeading)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: extent.width * zoom, height: extent.height * zoom, alignment: .topLeading)
            }
            .background(look.canvas)
            HStack(spacing: 12) {
                Button { model.edit(book.name, .zoom(NoteCanvas.zoomOut(layout.zoom))) } label: { Text("−") }.buttonStyle(.plain)
                Text("\(Int((layout.zoom * 100).rounded()))%").monospacedDigit()
                Button { model.edit(book.name, .zoom(NoteCanvas.zoomIn(layout.zoom))) } label: { Text("+") }.buttonStyle(.plain)
            }
            .font(.system(size: 12)).foregroundStyle(Color(white: 0.53))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(look.dark ? Color(white: 0.2) : .white, in: .rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.black.opacity(0.15), lineWidth: 0.5) }
            .padding(.trailing, 20).padding(.bottom, 18)
        }
    }

    private func extent(_ spots: [String: NoteCanvas.Spot]) -> CGSize {
        var width = 1200.0, height = 760.0
        for spot in spots.values { width = max(width, spot.x + NoteCanvas.cell + 80); height = max(height, spot.y + NoteCanvas.cell + 80) }
        for area in layout.areas { width = max(width, area.x + area.w + 80); height = max(height, area.y + area.h + 80) }
        for words in layout.texts { width = max(width, words.x + 300); height = max(height, words.y + 80) }
        return CGSize(width: width, height: height)
    }

    @ViewBuilder private func boardMenu() -> some View {
        Button("Add an area") {
            model.words(about: book.name, "A new area", "What does it hold?", value: "") { label, asked in
                let x = 60 + Double(layout.areas.count % 3) * 40, y = 50 + Double(layout.areas.count % 3) * 40
                model.edit(asked.notebook, .area(.init(id: UUID().uuidString, label: label, x: x, y: y, w: 520, h: 330)))
            }
        }
        Button("Write on the canvas") {
            model.words(about: book.name, "Write on the canvas", "Your words:", value: "") { text, asked in
                model.edit(asked.notebook, .words(.init(id: UUID().uuidString, text: text, x: 80, y: 40 + Double(layout.texts.count) * 30)))
            }
        }
    }
}

/// Scrolls down; while snapshotting (scroll views draw as placeholders there), a stand-in of the scroll view's own
/// size: its content from the top, cut where the scroll view ends, so a window smaller than its notes is drawn as
/// the window shows it.
struct ScrollDown<Content: View>: View {
    @Environment(\.snapshotting) private var snapshotting
    @ViewBuilder var content: Content

    var body: some View {
        if snapshotting {
            Color.clear.overlay(alignment: .topLeading) { content.fixedSize(horizontal: false, vertical: true) }.clipped()
        } else {
            ScrollView { content }
        }
    }
}

/// Scrolls both ways; a plain stack while snapshotting.
struct Scroll2D<Content: View>: View {
    @Environment(\.snapshotting) private var snapshotting
    @ViewBuilder var content: Content

    var body: some View {
        // Its content never sizes the view (it's larger than the window): what fits shows, the rest is cut off.
        if snapshotting { Color.clear.overlay(alignment: .topLeading) { content }.clipped() }
        else { ScrollView([.horizontal, .vertical]) { content } }
    }
}

/// The canvas's dotted paper: a dot every 22 points.
struct CanvasDots: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 22
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)), with: .color(color))
                    x += step
                }
                y += step
            }
        }
    }
}

/// A note on the canvas: dragged to move it (written when the drag ends), turned a little as the sketch has them,
/// clicked to open it on its own. Its menu draws or takes away arrows to other notes.
struct CanvasPaper: View {
    @Environment(PetalApp.self) private var app
    let paper: PaperNote
    let spot: NoteCanvas.Spot
    let model: NotesModel
    let others: [PaperNote]
    let layout: NoteCanvas
    @State private var start: NoteCanvas.Spot?

    var body: some View {
        GridPaper(paper: paper, now: Date(), draggable: false, words: 13.5)
            .rotationEffect(.degrees(Self.turn(paper.noteID)))
            .offset(x: spot.x, y: spot.y)
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    let from = start ?? spot
                    if start == nil { start = spot }
                    let zoom = layout.zoom
                    model.dragging[paper.noteID] = .init(x: max(0, from.x + value.translation.width / zoom), y: max(0, from.y + value.translation.height / zoom))
                }
                .onEnded { _ in
                    if let moved = model.dragging.removeValue(forKey: paper.noteID) { model.move(paper, to: moved) }
                    start = nil
                })
            .contextMenu {
                Button("Open") { GridPaper.open(paper, app: app) }
                Menu("Draw an arrow to") {
                    ForEach(others, id: \.key) { other in
                        Button(other.file.title.isEmpty ? "A note" : other.file.title) { model.arrow(from: paper, to: other) }
                    }
                }
                let mine = layout.arrows.filter { $0.from == paper.noteID || $0.to == paper.noteID }
                if !mine.isEmpty {
                    Menu("Take an arrow away") {
                        ForEach(mine) { arrow in
                            let other = arrow.from == paper.noteID ? arrow.to : arrow.from
                            Button(others.first { $0.noteID == other }?.file.title ?? "A note") { model.edit(paper.notebook, .removeArrow(arrow.id)) }
                        }
                    }
                }
            }
    }

    /// The sketch's papers lie a little turned: by their id, so each keeps its own.
    static func turn(_ id: String) -> Double { [-2, 1.5, -1, 1, -1.5][id.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 5 }] }
}

/// An area: a dashed rounded frame in the notebook's color with its label on its edge; dragged by its label (its
/// notes come along), resized from its corner.
struct CanvasArea: View {
    let area: NoteCanvas.Area
    let color: NSColor
    let look: NotesLook
    let model: NotesModel
    let book: Notebook
    let notes: [String]
    let spots: [String: NoteCanvas.Spot]
    @State private var moving: (dx: Double, dy: Double) = (0, 0)
    @State private var start: [String: NoteCanvas.Spot] = [:]
    @State private var sizing: (dw: Double, dh: Double) = (0, 0)

    var body: some View {
        let tint = PaperLook.rgb(color)
        let w = max(160, area.w + sizing.dw), h = max(100, area.h + sizing.dh)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18)
                .fill(PaperLook.color(tint).opacity(0.05))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(PaperLook.color(tint).opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])) }
                .frame(width: w, height: h)
                .allowsHitTesting(false)
            Text(area.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(white: 0.33))
                .padding(.horizontal, 6).background(look.canvas)
                .offset(x: 14, y: -9)
                .gesture(DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if start.isEmpty { start = spots.filter { notes.contains($0.key) } }
                        moving = (value.translation.width / model.canvasZoom, value.translation.height / model.canvasZoom)
                        for (id, spot) in start { model.dragging[id] = .init(x: max(0, spot.x + moving.dx), y: max(0, spot.y + moving.dy)) }
                    }
                    .onEnded { _ in
                        var moved = area
                        moved.x = max(0, area.x + moving.dx)
                        moved.y = max(0, area.y + moving.dy)
                        // The area and its notes as one move: an id-less note gets its id first; one that can't, and the
                        // whole move is refused (everything snaps back).
                        var moves: [String: NoteCanvas.Spot] = [:]
                        for id in start.keys { if let spot = model.dragging[id] { moves[id] = spot } }
                        model.moveGroup(book.name, area: moved, notes: moves)
                        start = [:]
                        moving = (0, 0)
                    })
                .contextMenu {
                    Button("Rename…") {
                        model.words(about: book.name, "Rename the area", "What does it hold?", value: area.label) { label, asked in
                            var renamed = area
                            renamed.label = label
                            model.edit(asked.notebook, .area(renamed))
                        }
                    }
                    Button("Remove the area") { model.edit(book.name, .removeArea(area.id)) }
                }
            Image(systemName: "arrow.down.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(PaperLook.color(tint).opacity(0.5))
                .frame(width: 18, height: 18).contentShape(.rect)
                .offset(x: w - 20, y: h - 20)
                .gesture(DragGesture(coordinateSpace: .global)
                    .onChanged { value in sizing = (value.translation.width / model.canvasZoom, value.translation.height / model.canvasZoom) }
                    .onEnded { _ in
                        var sized = area
                        sized.w = w
                        sized.h = h
                        model.edit(book.name, .area(sized))
                        sizing = (0, 0)
                    })
        }
        .offset(x: area.x + moving.dx, y: area.y + moving.dy)
    }
}

/// Words written on the canvas.
struct CanvasWords: View {
    let words: NoteCanvas.Words
    let look: NotesLook
    let model: NotesModel
    let book: Notebook
    @State private var moving: (dx: Double, dy: Double) = (0, 0)

    var body: some View {
        Text(words.text).font(.custom("Georgia", size: 15).italic()).foregroundStyle(look.dark ? Color(white: 0.75) : Color(white: 0.33))
            .fixedSize()
            .offset(x: words.x + moving.dx, y: words.y + moving.dy)
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { value in moving = (value.translation.width / model.canvasZoom, value.translation.height / model.canvasZoom) }
                .onEnded { _ in
                    var moved = words
                    moved.x = max(0, words.x + moving.dx)
                    moved.y = max(0, words.y + moving.dy)
                    model.edit(book.name, .words(moved))
                    moving = (0, 0)
                })
            .contextMenu {
                Button("Edit…") {
                    model.words(about: book.name, "Edit the words", "Your words:", value: words.text) { text, asked in
                        var edited = words
                        edited.text = text
                        model.edit(asked.notebook, .words(edited))
                    }
                }
                Button("Remove") { model.edit(book.name, .removeWords(words.id)) }
            }
    }
}

/// Arrows between notes: a gentle curve from one paper's edge to the other's, with a head.
struct CanvasArrows: View {
    let arrows: [NoteCanvas.Arrow]
    let spots: [String: NoteCanvas.Spot]

    var body: some View {
        Canvas { context, _ in
            let half = NoteCanvas.cell / 2
            for arrow in arrows {
                guard let a = spots[arrow.from], let b = spots[arrow.to] else { continue }
                let from = CGPoint(x: a.x + half, y: a.y + half), to = CGPoint(x: b.x + half, y: b.y + half)
                let start = Self.edge(from, toward: to), end = Self.edge(to, toward: from)
                var path = Path()
                path.move(to: start)
                let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 20)
                path.addQuadCurve(to: end, control: mid)
                let style = StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: arrow.dashed ? [5, 5] : [])
                context.stroke(path, with: .color(Color(white: 0.33)), style: style)
                let angle = atan2(end.y - mid.y, end.x - mid.x)
                var head = Path()
                head.move(to: end)
                head.addLine(to: CGPoint(x: end.x - 9 * cos(angle - 0.45), y: end.y - 9 * sin(angle - 0.45)))
                head.addLine(to: CGPoint(x: end.x - 9 * cos(angle + 0.45), y: end.y - 9 * sin(angle + 0.45)))
                head.closeSubpath()
                context.fill(head, with: .color(Color(white: 0.33)))
            }
        }
    }

    /// Where the line from a paper's middle toward `other` leaves the paper.
    static func edge(_ middle: CGPoint, toward other: CGPoint) -> CGPoint {
        let half = NoteCanvas.cell / 2 + 6
        let dx = other.x - middle.x, dy = other.y - middle.y
        let scale = half / max(abs(dx), abs(dy), 0.001)
        return CGPoint(x: middle.x + dx * min(1, scale), y: middle.y + dy * min(1, scale))
    }
}

extension NotesModel {
    var canvasZoom: Double { canvas?.layout?.zoom ?? 1 }
}
