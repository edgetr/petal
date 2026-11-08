import AppKit
import CoreServices
import Observation

/// One note as Petal holds it: its file's contents, where the file is, and its notebook (the folder it's in).
/// `key` (the file's path) tells papers apart: two files holding the same note (an iCloud conflict) are two papers.
struct PaperNote: Identifiable, Equatable {
    var file: NoteFile
    var url: URL
    var notebook: String
    /// One of the versions iCloud kept when the file changed on two Macs at once (NSFileVersion): shown beside the
    /// file until one is kept.
    var version: String? = nil
    /// The file's text as Petal last read or wrote it: what an edit is made on. A save finds the file changed since
    /// (another editor, another Mac) when it no longer says this, and keeps both.
    var revision: String? = nil
    /// Read from the folder with places that followed their files' bookmarks: worth writing back (through its
    /// session, fenced by `revision`).
    var followed = false

    var key: String { version.map { url.path + "#" + $0 } ?? url.path }
    var id: String { key }
    var noteID: String { file.id }
    /// Its pictures' folder, beside it, named for the note's id: it keeps its name wherever the note moves.
    var assets: URL { url.deletingLastPathComponent().appending(path: NoteShelf.assetsFolder(id: file.id)) }

    func resolve(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.deletingLastPathComponent().appending(path: path)
    }
}

/// A notebook: a folder of notes with a color (on its cover, "About this notebook").
struct Notebook: Identifiable, Equatable {
    var name: String
    var folder: URL
    var color: String
    var cover: String?
    var count: Int
    var id: String { name }
}

/// One picture pasted or dropped on a note, its bytes in memory (read and decoded before the paste was accepted):
/// its name in the note's pictures' folder (chosen when it was accepted, so writing it again is the same file).
struct NotePictureBytes: @unchecked Sendable {
    var name: String
    var data: Data
    var caption: String
}

/// Keep this one, as session work: the papers exactly as shown (`snapshot`: a file by "file:" + its path, a version
/// by "version:" + its name, each with its text then), the file kept and, when it was a version iCloud kept, its
/// text to write there; the other files to go to the Trash.
struct NoteKeep: @unchecked Sendable {
    var snapshot: [String: String]
    var kept: URL
    var keptText: String?
    var files: [URL]
}

/// Work waiting to reach a note's file, done in order by its session.
enum NoteWork: @unchecked Sendable {
    /// A new note's file, under the first name free in `folder`; `exact`: only at that one place (a notebook's
    /// cover), and a file already there is the one.
    case create(text: String, stem: String, folder: URL, exact: URL? = nil)
    /// The note's text, made on `base`: the exact text of the file it was made on (nil: a new note). It lands only
    /// while the file still says `base`, or already says `text`; else it's kept beside the file as a conflict copy.
    case write(text: String, base: String?)
    /// An edit to a paper that turned read only as it was typed: kept beside the file as a conflict copy.
    case keepAside(text: String)
    /// Into another notebook (made if it's new), its pictures' folder first.
    case move(folder: URL)
    /// A picture's bytes, step one: into the note's pictures' folder, a file of its own; the Markdown is untouched.
    /// Step two, its reference, is ordinary text (the editor, or a based write).
    case pictureBytes([NotePictureBytes], noteID: String)
    /// To the Trash, only while the file still says `revision`.
    case trash(revision: String?)
    /// Keep this one: checked against the papers as shown inside each coordinated write or trash.
    case keep(NoteKeep)

    /// Carries the person's writing: tried again until it lands, and kept in "Unsaved notes" if it can't by quit.
    var keeps: Bool {
        switch self {
        case .create, .write, .keepAside: true
        case .move, .trash, .keep, .pictureBytes: false
        }
    }

    /// The person's own text it carries, for "Unsaved notes".
    var text: String? {
        switch self {
        case .create(let text, _, _, _), .write(let text, _), .keepAside(let text): text
        default: nil
        }
    }
}

/// What a piece of work did: its outcome, where the note's file is now, and pictures written.
struct NoteWorkResult: @unchecked Sendable {
    var outcome: NoteStore.Outcome
    var url: URL?
    var pictures: [(path: String, file: URL, caption: String)] = []
}

/// One note's work not yet on disk: typed text, keep-asides, pictures, a move, a new file, a trash, a conflict
/// settled. Every path (the editor's saves, the tools, a place followed, a picture, a move from the letterhead or
/// the socket) goes through it, in order; quitting, trying again and switching the notes' folder drain the same list
/// the same way (`NoteStore.drain`). Its paper is never replaced by a read of the folder while it has work.
@MainActor
final class NoteSession {
    struct Item {
        let id: Int
        var work: NoteWork
        var done: [@MainActor (NoteStore.Outcome) -> Void]
        /// The asker is still there (a tool's request): checked right before the work is done, retries and drains too.
        var live: (@Sendable () -> Bool)? = nil
        /// Where the cursor was when pictures were pasted (their reference goes there in an open editor).
        var at = -1
    }

    let id: Int
    var key: String
    var noteID = ""
    /// The provisional path (lowercased) a new note was shown with: reserved until its file is made, or its making
    /// ends (a failed one stays reserved while it's tried again).
    var reservation: String?
    var pending: [Item] = []
    var running = false
    /// The first piece of work couldn't be done: it's tried again in a few seconds.
    var failing = false

    init(id: Int, key: String) {
        self.id = id
        self.key = key
    }

    var busy: Bool { running || !pending.isEmpty }
    var picturesPending: Bool { pending.contains { if case .pictureBytes = $0.work { true } else { false } } }
}

/// What the file queue knows of each session's file: where it is, the note's id, and the text that last landed
/// there through this session (or was read: what a picture's reference is written on at quit). Each piece of
/// work's result. Only ever touched on `NoteStore.io`.
enum NoteDisk {
    struct State {
        var url: URL
        var noteID: String
        var revision: String?
    }

    nonisolated(unsafe) static var states: [Int: State] = [:]
    nonisolated(unsafe) static var results: [Int: NoteWorkResult] = [:]
    /// Pieces of work being done or done, by item id: the queue and the quit drain each claim a piece before doing
    /// it (`NoteShelf.claim`), so none is done twice; a failed one is given back for its next try.
    nonisolated(unsafe) static var claimed: Set<Int> = []

    /// One piece of work, done only by whoever claims it first; nil when it was someone else's.
    nonisolated static func once(_ item: NoteSession.Item, session: Int, root: URL) -> NoteWorkResult? {
        guard let next = NoteShelf.claim(item.id, claimed) else { return nil }
        claimed = next
        let result = NoteStore.perform(item.work, session: session, root: root, live: item.live)
        if result.outcome == .failed { claimed.remove(item.id) }
        results[item.id] = result
        return result
    }
}

/// Petal Notes' files: one Markdown file per note, a folder per notebook, Inbox by default. They live in iCloud
/// Drive's "Petal Notes" when iCloud Drive is on, else in Petal's own folder (`notesFolder` picks another;
/// `PETAL_NOTES` points tests and snapshots elsewhere). Everything that touches a file runs on `io`, never the main
/// thread: an iCloud file may not be downloaded yet, and reading it waits for that. The folder is watched (FSEvents)
/// and read again when anything changes, from this Mac or another.
///
/// Nothing is written over: a save checks the file still says what the edit was made on and otherwise keeps both;
/// a new file is made only where no file is; every write, move and trash stays inside the notes' folder, through no
/// symbolic link. Every change to a note goes through its `NoteSession`.
@MainActor @Observable
final class NoteStore {
    private(set) var notes: [PaperNote] = []
    private(set) var notebooks: [Notebook] = []
    /// Notes with more than one paper (iCloud conflicts, or an edit kept beside a file changed elsewhere), by note id.
    private(set) var conflicts: [String: [PaperNote]] = [:]
    private(set) var loaded = false
    /// Papers whose work keeps failing: the paper says it isn't saved yet.
    private(set) var failed: Set<String> = []
    @ObservationIgnored private(set) var root: URL
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var reloadSoon: DispatchWorkItem?
    @ObservationIgnored private var generation = 0
    /// Changes made here, on one clock with the reads of the folder: what a read that began before them must keep.
    @ObservationIgnored private var clock = 0
    @ObservationIgnored private var changedAt: [String: Int] = [:]
    @ObservationIgnored private var removedAt: [String: Int] = [:]
    /// Each note's session by its own id, never by its path: a new note's file may land under another name than the
    /// one it was shown with, and a move renames it. `keys` finds a paper's session; it changes only through
    /// `NoteShelf.rekey`, which never takes a name another session holds.
    @ObservationIgnored private var sessions: [Int: NoteSession] = [:]
    @ObservationIgnored private var keys: [String: Int] = [:]
    /// Sessions, pieces of work and pastes are numbered on one clock for the whole run (never per store), so a
    /// piece's claim on the file queue (`NoteDisk.claimed`) is never mistaken for another's.
    private static var counter = 0
    private var nextID: Int {
        get { Self.counter }
        set { Self.counter = newValue }
    }
    @ObservationIgnored private var retrying = false
    /// Switching to another notes folder: the old one's work is drained and nothing new starts there.
    @ObservationIgnored private(set) var switching = false
    /// Papers being written in (an open editor): never dropped by a read of the folder.
    @ObservationIgnored var keepAlive: (String) -> Bool = { _ in false }
    /// Called on the main thread after every read of the folder.
    @ObservationIgnored var onChange: () -> Void = {}
    /// A paper's file is somewhere else now (a move, a new note's name on disk): old key, the paper now.
    @ObservationIgnored var onRekey: (String, PaperNote) -> Void = { _, _ in }
    /// Something couldn't be done to the files: in plain words.
    @ObservationIgnored var onProblem: (String) -> Void = { _ in }

    nonisolated static let io = DispatchQueue(label: "petal.notes.files", qos: .userInitiated)

    init(root: URL? = nil) { self.root = root ?? Self.rootFolder(setting: "") }

    /// Where notes live: `PETAL_NOTES`; else the `notesFolder` setting; else iCloud Drive's "Petal Notes" when iCloud
    /// Drive is there; else Application Support's Notes. Never Documents or the Desktop.
    nonisolated static func rootFolder(setting: String) -> URL {
        if let dir = ProcessInfo.processInfo.environment["PETAL_NOTES"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        let chosen = (setting as NSString).expandingTildeInPath
        if !chosen.isEmpty, chosen.hasPrefix("/") { return URL(fileURLWithPath: chosen) }
        let drive = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        var folder: ObjCBool = false
        if FileManager.default.fileExists(atPath: drive.path, isDirectory: &folder), folder.boolValue { return drive.appending(path: "Petal Notes") }
        return Config.supportFolder.appending(path: "Notes")
    }

    var inICloud: Bool { root.path.contains("/Mobile Documents/") }

    /// Reading and watching the notes folder as it is now: called once the first folder is settled, and again after
    /// every switch (the watcher always follows the folder in use).
    func start() {
        guard !switching else { return }
        reload()
        watch()
    }

    private func touch(_ key: String) {
        clock += 1
        changedAt[key] = clock
    }

    private func gone(_ key: String) {
        clock += 1
        removedAt[key] = clock
    }

    // MARK: Switching folders

    /// Another notes folder: the old one's work is drained off the main thread (what can't be written goes to
    /// "Unsaved notes"), then its notes go and the new folder's come. Nothing new starts in the old folder meanwhile.
    func switchRoot(to newRoot: URL, then done: @escaping @MainActor () -> Void = {}) {
        guard newRoot != root, !switching else { return }
        switching = true
        stopWatching()
        let jobs = drainJobs()
        let unsaved = drainUnsaved()
        let oldRoot = root
        Self.io.async {
            Self.drain(jobs, unsaved: unsaved, root: oldRoot)
            NoteDisk.states = [:]
            NoteDisk.results = [:]
            NoteDisk.claimed = []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.sessions = [:]
                    self.keys = [:]
                    self.failed = []
                    self.notes = []
                    self.notebooks = []
                    self.conflicts = [:]
                    self.changedAt = [:]
                    self.removedAt = [:]
                    self.root = newRoot
                    self.switching = false
                    self.start()
                    done()
                }
            }
        }
    }

    // MARK: Reading

    /// Reads the whole folder again, off the main thread; a newer read wins, and changes made here meanwhile stay.
    func reload() {
        guard !switching else { return }
        generation += 1
        let mine = generation
        clock += 1
        let started = clock
        let root = self.root
        Self.io.async {
            let read = Self.read(root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard mine == self.generation, !self.switching, root == self.root else { return }
                    // Notes renamed or moved elsewhere meanwhile: followed first, editor, session and work along.
                    self.followRenamed(read.notes)
                    // Papers with work under way, or open in an editor, count as changed now: never replaced by a read.
                    var changed = self.changedAt
                    for session in self.sessions.values where session.busy { changed[session.key] = Int.max }
                    for paper in self.notes where self.keepAlive(paper.key) && NoteShelf.within(paper.url.path, root.path) != nil {
                        changed[paper.key] = Int.max
                    }
                    var merged = NoteShelf.fenced(read: read.notes, memory: self.notes, key: \.key, started: started,
                                                  changed: changed, removed: self.removedAt)
                    // A Safari, Firefox or Zen tab's button is never written: it stays with the note while Petal runs.
                    let before = Dictionary(self.notes.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                    for index in merged.indices {
                        guard let old = before[merged[index].key] else { continue }
                        for place in merged[index].file.places.indices where place < old.file.places.count {
                            let was = old.file.places[place]
                            if merged[index].file.places[place].kind == .tab, was.kind == .tab, merged[index].file.places[place].pid == was.pid,
                               merged[index].file.places[place].mac == was.mac {
                                merged[index].file.places[place].tabElement = was.tabElement
                            }
                        }
                    }
                    self.changedAt = self.changedAt.filter { $0.value >= started }
                    self.removedAt = self.removedAt.filter { $0.value >= started }
                    if merged != self.notes { self.notes = merged }
                    if read.notebooks != self.notebooks { self.notebooks = read.notebooks }
                    self.regroup()
                    self.rebindSessions()
                    self.loaded = true
                    // Places that followed their files' bookmarks: written back through each note's session, only
                    // while the note is still what was read.
                    for paper in merged where paper.followed {
                        if let index = self.notes.firstIndex(where: { $0.key == paper.key }) { self.notes[index].followed = false }
                        self.change(paper.key, expect: paper.revision, touch: false) { _ in }
                    }
                    self.onChange()
                }
            }
        }
    }

    /// A note renamed or moved elsewhere (Finder, another Mac): the paper in memory takes its new path, and its open
    /// editor and panel (`onRekey`), its session and the work waiting in it go along (`NoteShelf.follow`), so it
    /// never becomes a second paper of the same id beside its old self.
    private func followRenamed(_ read: [PaperNote]) {
        let moves = NoteShelf.follow(memory: notes.filter { $0.version == nil }.map { ($0.key, $0.noteID) },
                                     read: read.filter { $0.version == nil }.map { ($0.key, $0.noteID) })
        guard !moves.isEmpty else { return }
        let found = Dictionary(read.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for (old, new) in moves {
            guard let index = notes.firstIndex(where: { $0.key == old }), let there = found[new] else { continue }
            var paper = notes[index]
            paper.url = there.url
            paper.notebook = there.notebook
            notes[index] = paper
            if let at = changedAt.removeValue(forKey: old) { changedAt[new] = at }
            if let session = sessionAt(old, noteID: paper.noteID), let next = NoteShelf.rekey(keys, session: session.id, from: old, to: new) {
                keys = next
                session.key = new
                let id = session.id, url = there.url
                // After whatever is under way; everything waiting goes to the new path.
                Self.io.async { NoteDisk.states[id]?.url = url }
            }
            if failed.remove(old) != nil { failed.insert(new) }
            if let trouble = pictureTrouble.removeValue(forKey: old) { pictureTrouble[new] = trouble }
            touch(new)
            onRekey(old, paper)
        }
    }

    private func regroup() {
        let groups = Dictionary(grouping: notes, by: \.noteID).filter { $0.value.count > 1 }
        if groups != conflicts { conflicts = groups }
    }

    /// Every notebook and note under `root`, with Inbox (and its cover) made the first time. Files iCloud hasn't
    /// downloaded yet are asked for and read once they arrive (the folder changes then). Symbolic links (a notebook
    /// or note that points elsewhere) are left out. Places whose files moved (their bookmarks) are followed in memory
    /// (`followed`), never written here.
    nonisolated static func read(_ root: URL) -> (notes: [PaperNote], notebooks: [Notebook]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let inbox = root.appending(path: NoteShelf.inbox)
        if !fm.fileExists(atPath: inbox.path), safe(inbox, root: root) {
            try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
            var cover = NoteFile(body: "# About this notebook\n\nNotes go here unless you choose another notebook. Write here what this notebook is for.")
            cover.cover = true
            cover.color = "accent"
            create(cover.serialized(), at: inbox.appending(path: NoteShelf.coverName), root: root)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey,
                                      .ubiquitousItemHasUnresolvedConflictsKey, .isUbiquitousItemKey]
        let folders = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true && url.pathExtension != "assets"
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var notes: [PaperNote] = []
        var notebooks: [Notebook] = []
        for folder in folders {
            let name = folder.lastPathComponent
            let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension.lowercased() == "md" }
            var here: [PaperNote] = []
            for url in files {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
                if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try? fm.startDownloadingUbiquitousItem(at: url)
                    continue
                }
                let date = values.contentModificationDate ?? Date()
                guard let text = coordinatedRead(url) else { continue }
                // A file with no id of its own is known by where it is under the notes' folder, never its name alone.
                let fallback = NoteShelf.fallbackID(relativePath: NoteShelf.relative(url.path, to: root.path) ?? name + "/" + url.lastPathComponent)
                var paper = PaperNote(file: NoteFile.parse(text, fallbackID: fallback, fallbackDate: date), url: url, notebook: name, revision: text)
                paper.followed = followBookmarks(&paper.file)
                here.append(paper)
                // The versions iCloud kept from a change made on two Macs at once: each one a paper of its own.
                if values.ubiquitousItemHasUnresolvedConflicts == true {
                    for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                        guard let text = try? String(contentsOf: version.url, encoding: .utf8) else { continue }
                        var paper = PaperNote(file: NoteFile.parse(text, fallbackID: fallback, fallbackDate: version.modificationDate ?? date), url: url,
                                              notebook: name, revision: text)
                        paper.version = version.url.lastPathComponent
                        here.append(paper)
                    }
                }
            }
            here.sort { a, b in
                if a.file.cover != b.file.cover { return a.file.cover }
                return a.file.modified > b.file.modified
            }
            let cover = here.first { $0.file.cover }
            notebooks.append(Notebook(name: name, folder: folder, color: cover?.file.color ?? "", cover: cover?.key,
                                      count: here.filter { !$0.file.cover }.count))
            notes += here
        }
        return (notes, notebooks)
    }

    /// The files a note is stuck to, found again through their bookmarks: a file moved or renamed takes its notes
    /// with it, and a bookmark gone stale is made again. True when anything changed. Off the main thread.
    nonisolated static func followBookmarks(_ file: inout NoteFile) -> Bool {
        var changed = false
        for index in file.places.indices where !file.places[index].bookmark.isEmpty {
            guard let data = Data(base64Encoded: file.places[index].bookmark) else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            // The same file however its path is spelled (/var is /private/var): nothing to change.
            if url.resolvingSymlinksInPath().path != URL(fileURLWithPath: file.places[index].path).resolvingSymlinksInPath().path {
                file.places[index].path = url.path
                if file.places[index].kind == .file { file.places[index].title = url.lastPathComponent }
                changed = true
            }
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                file.places[index].bookmark = fresh.base64EncodedString()
                changed = true
            }
        }
        return changed
    }

    /// A file's text, read the way iCloud Drive wants (it may need to bring the file down first). Off the main thread.
    nonisolated static func coordinatedRead(_ url: URL) -> String? {
        var text: String?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { url in
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        return text
    }

    // MARK: Safe writing (off the main thread)

    /// `url` is inside the notes' folder and no part of its path from there is a symbolic link (a notebook made a
    /// link to elsewhere never takes a note's writing out of the folder). Checked right before each write, move and
    /// trash. Off the main thread.
    nonisolated static func safe(_ url: URL, root: URL) -> Bool {
        // The notes' folder however its own path is spelled (/var is /private/var); every part inside it is still
        // checked for a link below.
        // realpath(3): the one spelling with every link resolved (URL's own resolving drops a leading /private).
        let spelled = root
        let real = realpath(root.path, nil).map { pointer in
            defer { free(pointer) }
            return URL(fileURLWithPath: String(cString: pointer))
        } ?? root
        let path = url.path
        guard let (inside, base) = NoteShelf.within(path, spelled.path).map({ ($0, spelled) }) ?? NoteShelf.within(path, real.path).map({ ($0, real) })
        else { return false }
        var at = base
        for part in inside.split(separator: "/") {
            at = at.appending(path: String(part))
            var info = stat()
            if lstat(at.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { return false }
        }
        return true
    }

    /// `notThisNote`: the file there is another note's now (its path reused): a tool's change refused, nothing done.
    enum Outcome: Equatable { case written, keptBoth(URL), failed, cancelled, notThisNote }

    /// The note id a file's text says: its own, or, for one with none, its path's (as the folder's read knows it).
    nonisolated static func noteID(of text: String, at url: URL, root: URL) -> String {
        let fallback = NoteShelf.fallbackID(relativePath: NoteShelf.relative(url.path, to: root.path)
                                            ?? url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent)
        return NoteFile.parse(text, fallbackID: fallback, fallbackDate: Date()).id
    }

    /// The vault's redaction for file names, set by the app (`VaultIndex`); nil back while the vault can't be read.
    /// Never a secret in a file name: names are made from titles only after it (`NoteShelf.safeStem`).
    nonisolated(unsafe) static var nameRedactor: @Sendable (String) -> String? = { _ in nil }

    /// A file name for `text` with nothing of a secret in it: its redacted title, else `fallback`.
    nonisolated static func safeStem(for text: String, fallback: String) -> String {
        let body = NoteFile.parse(text, fallbackID: "", fallbackDate: Date()).body
        return NoteShelf.safeStem(redacted: nameRedactor(body), fallback: fallback)
    }

    /// The fallback name for a note whose title can't be checked: holds nothing of it.
    nonisolated static var plainStem: String { "Note " + String(Int(Date().timeIntervalSince1970) % 100_000) }

    /// Writes `text` over the file at `url` only while it still says `base` (what the edit was made on); changed
    /// since, the edit goes to a copy beside it instead ("Name (conflicted copy).md"), and both show as the note's
    /// papers. A file that already says `text` is done. Read and written in one coordinated step. Off the main thread.
    /// `noteID`: the note this write is for. The file there saying another note (its path reused) is never written:
    /// a tool's change is refused (`notThisNote`), the person's typing is kept beside it as a copy of its own note.
    nonisolated static func save(_ text: String, to url: URL, base: String?, root: URL, live: (@Sendable () -> Bool)? = nil,
                                 noteID: String? = nil) -> Outcome {
        guard safe(url, root: root) else { return .failed }
        var outcome = Outcome.failed
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { url in
            let there = FileManager.default.fileExists(atPath: url.path)
            let disk = there ? (try? String(contentsOf: url, encoding: .utf8)) : nil
            if there, disk == nil { return }   // there, but unreadable: never written over
            // A tool's asker gone by now: nothing changes (checked right before the change, inside the coordination).
            if let live, !live() { outcome = .cancelled; return }
            if let noteID, !NoteShelf.stillNote(found: disk.map { Self.noteID(of: $0, at: url, root: root) }, expected: noteID, missing: true) {
                outcome = live != nil ? .notThisNote : keepBeside(text, original: url, root: root)
                return
            }
            switch NoteShelf.save(disk: disk, text: text, base: base) {
            case .already: outcome = .written
            case .write: outcome = (try? Data(text.utf8).write(to: url, options: .atomic)) != nil ? .written : .failed
            case .keepBoth: outcome = keepBeside(text, original: url, root: root, live: live)
            }
        }
        return outcome
    }

    /// An edit kept beside a file: always a new conflict copy, never over one (a copy may hold words typed after
    /// it was made, or by another Mac). A tool's asker (`live`) is checked inside each copy's coordinated create:
    /// gone, nothing is made.
    nonisolated static func keepBeside(_ text: String, original: URL, root: URL, live: (@Sendable () -> Bool)? = nil) -> Outcome {
        let folder = original.deletingLastPathComponent()
        // Named from the copy's own redacted title, never the file it's beside (that name may not be Petal's).
        let stem = safeStem(for: text, fallback: plainStem)
        for _ in 0..<20 {
            if let live, !live() { return .cancelled }
            let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
            let copy = folder.appending(path: NoteShelf.conflictName(stem, taken: taken))
            if create(text, at: copy, root: root, live: live) {
                NoteNames.vouch(noteID(of: text, at: copy, root: root), copy.lastPathComponent)
                return .keptBoth(copy)
            }
        }
        return live.map { $0() } == false ? .cancelled : .failed
    }

    /// Makes a file where none is: never over another (created exclusively, coordinated). Off the main thread.
    @discardableResult
    nonisolated static func create(_ text: String, at url: URL, root: URL, live: (@Sendable () -> Bool)? = nil) -> Bool {
        guard safe(url, root: root) else { return false }
        var ok = false
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { url in
            // A tool's asker gone by now: nothing is made (checked right before, inside the coordination).
            if let live, !live() { return }
            ok = (try? Data(text.utf8).write(to: url, options: .withoutOverwriting)) != nil
        }
        return ok
    }

    /// A new file in `folder` named for `stem`: the first name free on disk and not reserved by another note being
    /// made (`NoteReservations`; `own`: this note's own provisional path), made exclusively, tried again when another
    /// file takes that name first. Off the main thread.
    nonisolated static func createNamed(_ text: String, stem: String, in folder: URL, root: URL, live: (@Sendable () -> Bool)? = nil,
                                        own: String? = nil) -> URL? {
        guard safe(folder, root: root) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var tried: Set<String> = []
        for _ in 0..<20 {
            let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() }).union(tried)
                .union(NoteReservations.names(in: folder.path.lowercased(), except: own))
            let name = NoteShelf.freeName(stem, taken: taken)
            let url = folder.appending(path: name)
            if let live, !live() { return nil }
            if create(text, at: url, root: root, live: live) {
                NoteNames.vouch(noteID(of: text, at: url, root: root), url.lastPathComponent)
                return url
            }
            tried.insert(name.lowercased())
        }
        return nil
    }

    /// Moves a file to the Trash, only inside the notes' folder. Off the main thread.
    @discardableResult
    nonisolated static func trash(_ url: URL, root: URL) -> Bool {
        guard safe(url, root: root) else { return false }
        return (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
    }

    // MARK: Doing a session's work (off the main thread)

    /// One piece of a session's work, on `io`, with what the queue knows of its file. `live`: the asker (a tool's
    /// request) is still there, checked right before anything changes.
    nonisolated static func perform(_ work: NoteWork, session: Int, root: URL, live: (@Sendable () -> Bool)? = nil) -> NoteWorkResult {
        guard var state = NoteDisk.states[session] else { return NoteWorkResult(outcome: .failed) }
        defer { NoteDisk.states[session] = state }
        if let live, !live() { return NoteWorkResult(outcome: .cancelled, url: state.url) }
        switch work {
        case .create(let text, let stem, let folder, let exact):
            if let exact {
                // A cover: only there; one already there is the cover (never a second).
                guard create(text, at: exact, root: root) || FileManager.default.fileExists(atPath: exact.path) else { return NoteWorkResult(outcome: .failed) }
                state.url = exact
                state.revision = coordinatedRead(exact)
                return NoteWorkResult(outcome: .written, url: exact)
            }
            guard let made = createNamed(text, stem: safeStem(for: text, fallback: stem), in: folder, root: root, live: live, own: state.url.path.lowercased()) else {
                return NoteWorkResult(outcome: live.map { $0() } == false ? .cancelled : .failed)
            }
            state.url = made
            state.revision = text
            return NoteWorkResult(outcome: .written, url: made)
        case .write(let text, let base):
            let outcome = save(text, to: state.url, base: base, root: root, live: live, noteID: state.noteID)
            if outcome == .written { state.revision = text }
            return NoteWorkResult(outcome: outcome, url: state.url)
        case .keepAside(let text):
            return NoteWorkResult(outcome: keepBeside(text, original: state.url, root: root, live: live), url: state.url)
        case .move(let folder):
            guard let target = move(state.url, noteID: state.noteID, into: folder, root: root, live: live) else {
                return NoteWorkResult(outcome: live.map { $0() } == false ? .cancelled : .failed, url: state.url)
            }
            state.url = target
            // A note with no id of its own is known by its path: moved, it's known by its new one from now on.
            if state.noteID.hasPrefix("file:"), let moved = coordinatedRead(target) { state.noteID = noteID(of: moved, at: target, root: root) }
            return NoteWorkResult(outcome: .written, url: target)
        case .pictureBytes(let pictures, let noteID):
            let written = writePictures(pictures, into: state.url.deletingLastPathComponent().appending(path: NoteShelf.assetsFolder(id: noteID)), root: root)
            guard written.count == pictures.count else { return NoteWorkResult(outcome: .failed, url: state.url) }
            return NoteWorkResult(outcome: .written, url: state.url, pictures: written)
        case .trash(let revision):
            // Only while it still says what Petal last saw there, checked inside the coordinated trash.
            let url = state.url, noteID = state.noteID
            trash(state.url, root: root) { disk in
                guard let disk else { return true }
                return NoteShelf.stillNote(found: Self.noteID(of: disk, at: url, root: root), expected: noteID, missing: true)
                    && (disk == revision || disk == state.revision)
            }
            return NoteWorkResult(outcome: .written, url: state.url)
        case .keep(let plan):
            return NoteWorkResult(outcome: keep(plan, root: root) ? .written : .failed, url: state.url)
        }
    }

    /// Step one of a picture: its bytes into `folder` under the name chosen when it was accepted. The same picture
    /// written again is the same file (a retry, a drain). Never the Markdown. Off the main thread.
    nonisolated static func writePictures(_ pictures: [NotePictureBytes], into folder: URL, root: URL) -> [(path: String, file: URL, caption: String)] {
        guard safe(folder, root: root) else { return [] }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [(path: String, file: URL, caption: String)] = []
        for picture in pictures {
            let file = folder.appending(path: picture.name)
            guard safe(file, root: root) else { return written }
            if !FileManager.default.fileExists(atPath: file.path) {
                guard (try? picture.data.write(to: file, options: .withoutOverwriting)) != nil else { return written }
            }
            written.append((folder.lastPathComponent + "/" + picture.name, file, picture.caption))
        }
        return written
    }

    /// Moves a file to the Trash inside one coordinated step, only while `still` says yes to what it holds then.
    @discardableResult
    nonisolated static func trash(_ url: URL, root: URL, still: (String?) -> Bool) -> Bool {
        guard safe(url, root: root) else { return false }
        var done = false
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &error) { url in
            let disk = FileManager.default.fileExists(atPath: url.path) ? (try? String(contentsOf: url, encoding: .utf8)) : nil
            guard still(disk) else { return }
            done = (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
        }
        return done
    }

    /// Keep this one, on `io`: first, every paper as shown, checked (`NoteShelf.keepAllowed`); then the kept version
    /// written over the file, inside its coordinated write and only while the file still says what was shown, and
    /// read back; then the shown versions marked resolved; then each other file trashed, inside its coordinated
    /// trash and only while it still says what was shown. Any change found on the way stops it there.
    nonisolated static func keep(_ plan: NoteKeep, root: URL) -> Bool {
        var now: [String: String?] = [:]
        for url in plan.files {
            if plan.snapshot["file:" + url.path] != nil {
                now["file:" + url.path] = FileManager.default.fileExists(atPath: url.path) ? coordinatedRead(url) : String?.none
            }
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                now["version:" + version.url.lastPathComponent] = try? String(contentsOf: version.url, encoding: .utf8)
            }
        }
        guard NoteShelf.keepAllowed(shown: plan.snapshot, now: now), safe(plan.kept, root: root) else { return false }
        if let text = plan.keptText {
            var ok = false
            var error: NSError?
            let shown = plan.snapshot["file:" + plan.kept.path]
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: plan.kept, options: [], error: &error) { url in
                let disk = try? String(contentsOf: url, encoding: .utf8)
                guard shown == nil || disk == shown else { return }
                ok = (try? Data(text.utf8).write(to: url, options: .atomic)) != nil && (try? String(contentsOf: url, encoding: .utf8)) == text
            }
            guard ok else { return false }
        }
        for url in plan.files {
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] where plan.snapshot["version:" + version.url.lastPathComponent] != nil {
                version.isResolved = true
            }
        }
        for url in plan.files where url != plan.kept {
            let shown = plan.snapshot["file:" + url.path]
            trash(url, root: root) { disk in disk == shown }
        }
        return true
    }

    /// Moves a note's file (and first its pictures' folder) into `folder`, under the first name free there on disk,
    /// never over a file. The pictures go first, merged into a folder of the same name already there only where it
    /// holds the same pictures (`NoteShelf.assetPlan`); a picture in the way, or a note that then can't move, puts
    /// everything back: never a note whose pictures stayed behind. Off the main thread.
    nonisolated static func move(_ from: URL, noteID: String, into folder: URL, root: URL, live: (@Sendable () -> Bool)? = nil) -> URL? {
        guard safe(from, root: root), safe(folder, root: root) else { return nil }
        let going = { live?() ?? true }   // a tool's asker, checked before each step
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // The file must be this note, before its pictures go and again inside the coordinated move.
        let isNote = { (url: URL) in
            NoteShelf.stillNote(found: (try? String(contentsOf: url, encoding: .utf8)).map { Self.noteID(of: $0, at: url, root: root) },
                                expected: noteID, missing: false)
        }
        guard isNote(from) else { return nil }
        let assets = from.deletingLastPathComponent().appending(path: NoteShelf.assetsFolder(id: noteID))
        let newAssets = folder.appending(path: assets.lastPathComponent)
        var movedPictures: [String] = []
        if fm.fileExists(atPath: assets.path) {
            guard safe(assets, root: root), safe(newAssets, root: root) else { return nil }
            func hashes(_ dir: URL) -> [String: Int] {
                var out: [String: Int] = [:]
                for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] { out[name] = (try? Data(contentsOf: dir.appending(path: name)))?.hashValue ?? 0 }
                return out
            }
            guard case .move(let names) = NoteShelf.assetPlan(source: hashes(assets), destination: hashes(newAssets)) else { return nil }
            try? fm.createDirectory(at: newAssets, withIntermediateDirectories: true)
            for name in names {
                guard going(), (try? fm.moveItem(at: assets.appending(path: name), to: newAssets.appending(path: name))) != nil else {
                    for back in movedPictures { try? fm.moveItem(at: newAssets.appending(path: back), to: assets.appending(path: back)) }
                    return nil
                }
                movedPictures.append(name)
            }
        }
        let stem = from.deletingPathExtension().lastPathComponent
        var target: URL?
        for _ in 0..<20 where target == nil {
            let taken = Set(((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
            let candidate = folder.appending(path: NoteShelf.freeName(stem, taken: taken))
            guard safe(candidate, root: root) else { break }
            var error: NSError?
            var moved = false
            var cancelled = false
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: from, options: .forMoving, writingItemAt: candidate, options: .forReplacing, error: &error) { a, b in
                guard !fm.fileExists(atPath: b.path) else { return }
                guard going() else { cancelled = true; return }
                guard isNote(a) else { cancelled = true; return }
                moved = (try? fm.moveItem(at: a, to: b)) != nil
            }
            if moved { target = candidate } else if error != nil || cancelled { break }
        }
        guard let target else {
            // The note couldn't move: its pictures go back where they were.
            for back in movedPictures { try? fm.moveItem(at: newAssets.appending(path: back), to: assets.appending(path: back)) }
            return nil
        }
        if NoteNames.vouched(noteID, from.lastPathComponent) { NoteNames.vouch(noteID, target.lastPathComponent) }
        // The old pictures' folder, now empty, goes (to the Trash, never deleted outright).
        if fm.fileExists(atPath: assets.path), ((try? fm.contentsOfDirectory(atPath: assets.path)) ?? []).filter({ !$0.hasPrefix(".") }).isEmpty {
            try? fm.trashItem(at: assets, resultingItemURL: nil)
        }
        return target
    }

    // MARK: Sessions

    private func session(for key: String) -> NoteSession? {
        guard let paper = paper(key), paper.version == nil else { return nil }
        if let session = sessionAt(key, noteID: paper.noteID) { return session }
        return makeSession(key: key, url: paper.url, noteID: paper.noteID, revision: paper.revision)
    }

    /// The session at `key`, only when it's that same note's (`NoteShelf.session`). A session another note left at
    /// this path is let go from it: retired when it has nothing under way, else it keeps its work, unreachable here.
    private func sessionAt(_ key: String, noteID: String) -> NoteSession? {
        let ids = sessions.mapValues(\.noteID)
        if let id = NoteShelf.session(at: key, noteID: noteID, keys: keys, noteIDs: ids) { return sessions[id] }
        if let stale = keys[key] {
            keys[key] = nil
            retireIfIdle(stale)
        }
        return nil
    }

    private func retireIfIdle(_ id: Int) {
        guard let session = sessions[id], !session.busy, (importsLoading[session.noteID] ?? [:]).isEmpty else { return }
        sessions[id] = nil
        if keys[session.key] == id { keys[session.key] = nil }
        Self.io.async { NoteDisk.states[id] = nil }
    }

    /// After a read of the folder: each idle session follows its note to where it is now (renamed or moved
    /// elsewhere), when that's one paper and its path isn't another session's; a session whose note isn't found is
    /// retired. A busy one is left as it is: its work finishes where it began.
    private func rebindSessions() {
        let byID = Dictionary(grouping: notes.filter { $0.version == nil }, by: \.noteID)
        for session in Array(sessions.values) where !session.busy {
            let paths = (byID[session.noteID] ?? []).map(\.url.path)
            if paths.isEmpty { retireIfIdle(session.id); continue }
            guard let path = NoteShelf.rebind(key: session.key, at: paths),
                  let next = NoteShelf.rekey(keys, session: session.id, from: session.key, to: path) else { continue }
            keys = next
            session.key = path
            let id = session.id, url = URL(fileURLWithPath: path)
            let revision = byID[session.noteID]?.first?.revision
            Self.io.async {
                NoteDisk.states[id]?.url = url
                NoteDisk.states[id]?.revision = revision
            }
        }
    }

    private func makeSession(key: String, url: URL, noteID: String, revision: String?) -> NoteSession {
        nextID += 1
        let session = NoteSession(id: nextID, key: key)
        session.noteID = noteID
        sessions[session.id] = session
        keys[key] = session.id
        let state = NoteDisk.State(url: url, noteID: noteID, revision: revision)
        let id = session.id
        Self.io.async { NoteDisk.states[id] = state }
        return session
    }

    private func enqueue(_ session: NoteSession, _ work: NoteWork, live: (@Sendable () -> Bool)? = nil, at: Int = -1,
                         done: (@MainActor (Outcome) -> Void)?) {
        // A write joins the last one waiting (not started, from the same asker): the newest text, on the base the
        // first was made on (the file it will find).
        let lastWaiting = session.pending.count > (session.running ? 1 : 0)
        if case .write(let text, _) = work, lastWaiting, live == nil, let last = session.pending.last, last.live == nil,
           case .write(_, let base) = last.work {
            session.pending[session.pending.count - 1].work = .write(text: text, base: base)
            if let done { session.pending[session.pending.count - 1].done.append(done) }
        } else {
            nextID += 1
            session.pending.append(NoteSession.Item(id: nextID, work: work, done: done.map { [$0] } ?? [], live: live, at: at))
        }
        pump(session)
    }

    /// Quitting: the drain has taken every session's work; nothing more is started here.
    @ObservationIgnored private var draining = false

    private func pump(_ session: NoteSession) {
        guard !session.running, !session.failing, !switching, !draining, let item = session.pending.first else { return }
        session.running = true
        let id = session.id, root = self.root
        Self.io.async {
            NoteDisk.results[item.id] = nil
            // Claimed by the quit drain first: it's the drain's (done once, by it).
            guard let result = NoteDisk.once(item, session: id, root: root) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finished(session, item, result) } }
        }
    }

    private func finished(_ session: NoteSession, _ item: NoteSession.Item, _ result: NoteWorkResult) {
        session.running = false
        guard !switching, !draining, sessions[session.id] === session else { return }
        if result.outcome == .failed && item.work.keeps {
            // Kept (in the journal too), said on the paper, tried again: never dropped.
            session.failing = true
            failed.insert(session.key)
            onProblem("Petal couldn't save a note: it's kept here and tried again.")
            for done in item.done { done(.failed) }
            session.pending[0].done = []
            retryLater()
            return
        }
        session.pending.removeFirst()
        // A new note's making is over (made, or its asker went): its provisional name is free again, after its key
        // moved to the name it landed under (below).
        defer {
            if case .create(_, _, _, nil) = item.work, let reservation = session.reservation {
                session.reservation = nil
                reserved.remove(reservation)
                NoteReservations.remove(reservation)
            }
        }
        let itemID = item.id
        Self.io.async {
            NoteDisk.results[itemID] = nil
            NoteDisk.claimed.remove(itemID)
        }
        failed.remove(session.key)
        let noteID = session.noteID
        // Where the file is now: a new note's name on disk, a move.
        // A name another session holds is never taken (its paper and answer stay its own): this one keeps its key.
        if let url = result.url, url.path != session.key, let next = NoteShelf.rekey(keys, session: session.id, from: session.key, to: url.path) {
            let old = session.key
            keys = next
            session.key = url.path
            if let index = notes.firstIndex(where: { $0.key == old }) {
                var paper = notes[index]
                gone(old)
                paper.url = url
                if case .move(let folder) = item.work { paper.notebook = folder.lastPathComponent }
                notes[index] = paper
                touch(paper.key)
                onRekey(old, paper)
            }
        }
        // What landed (in the note, or in a conflict copy beside it) is safe: out of the journal.
        switch (item.work, result.outcome) {
        case (.write(let text, _), .written), (.write(let text, _), .keptBoth), (.create(let text, _, _, _), .written):
            // Pictures not saved yet (still on their way, or failed and set aside) keep the snapshot.
            let unsaved = Set(pendingPictures[noteID]?.keys.map { $0 } ?? [])
            NoteJournal.queue.async { NoteJournal.landed(noteID: noteID, text: text, unsaved: unsaved) }
        case (.keepAside(let text), .keptBoth):
            let unsaved = Set(pendingPictures[noteID]?.keys.map { $0 } ?? [])
            NoteJournal.queue.async { NoteJournal.landed(noteID: noteID, text: text, aside: true, unsaved: unsaved) }
        default: break
        }
        // A tool's write shows only once it landed (and nothing of the person's is waiting behind it).
        if case .write(let text, _) = item.work, item.live != nil, result.outcome == .written,
           !session.pending.contains(where: { if case .write = $0.work { $0.live == nil } else { false } }),
           let index = notes.firstIndex(where: { $0.key == session.key }) {
            notes[index].file = NoteFile.parse(text, fallbackID: notes[index].noteID, fallbackDate: notes[index].file.created)
            notes[index].revision = text
            touch(session.key)
        }
        if result.outcome == .failed { onProblem(Self.words(item.work)) }
        // A picture's bytes in its folder: out of memory (the next snapshot doesn't carry them). Bytes that couldn't
        // be written are set aside on the paper (Try again, Remove); nothing waits on them, and the journal keeps
        // them while the text references them.
        if case .pictureBytes(let pictures, _) = item.work {
            if result.outcome == .written {
                for picture in pictures { pendingPictures[noteID]?[picture.name] = nil }
                let names = Set(pictures.map(\.name))
                NoteJournal.queue.async { NoteJournal.picturesSaved(noteID: noteID, names: names) }
            } else {
                pictureTrouble[session.key, default: []] += pictures
            }
        }
        for done in item.done { done(result.outcome) }
        switch item.work {
        case .move, .trash, .keep: reload()
        default:
            // A copy made, or the file found to be another note's now: read again (the note is followed by its id).
            if case .keptBoth = result.outcome { reload() }
            if result.outcome == .notThisNote { reload() }
        }
        pump(session)
    }

    /// Pictures whose bytes couldn't be written (a file that couldn't be read, a folder that couldn't be written),
    /// by paper: the paper says "Picture couldn't be saved" with Try again and Remove; nothing waits on them.
    private(set) var pictureTrouble: [String: [NotePictureBytes]] = [:]

    func retryPictures(_ key: String) {
        guard let pictures = pictureTrouble.removeValue(forKey: key), let paper = paper(key), let session = session(for: key) else { return }
        enqueue(session, .pictureBytes(pictures, noteID: paper.noteID), done: nil)
    }

    /// Remove: the pictures that couldn't be saved leave the note (their references too) and memory.
    func dropPictures(_ key: String) {
        guard let pictures = pictureTrouble.removeValue(forKey: key), let paper = paper(key) else { return }
        let names = Set(pictures.map(\.name))
        for name in names { pendingPictures[paper.noteID]?[name] = nil }
        let noteID = paper.noteID
        NoteJournal.queue.async { NoteJournal.picturesSaved(noteID: noteID, names: names) }
        change(key) { file in
            file.body = NoteBlock.blocks(file.body).filter { block in
                if case .image(let path, _) = block { return !names.contains((path as NSString).lastPathComponent) }
                return true
            }.map(\.markdown).joined(separator: "\n")
        }
    }

    /// Picture bytes accepted and not in their notes' pictures' folders yet, by note id: what each snapshot carries
    /// for the pictures its text references.
    @ObservationIgnored private var pendingPictures: [String: [String: Data]] = [:]

    /// The journal's whole snapshot of a note as the person has it now: its text, the base of its oldest write not
    /// landed yet, and the bytes of the pictures that text references and that aren't in its folder yet.
    private func snapshot(_ paper: PaperNote, text: String, session: NoteSession, aside: Bool = false) {
        let firstBase: String?? = session.pending.lazy.compactMap { item -> String?? in
            switch item.work {
            case .write(_, let base): .some(base)
            case .create: .some(nil)
            default: nil
            }
        }.first
        let base = firstBase ?? paper.revision
        let pending = pendingPictures[paper.noteID] ?? [:]
        let pictures = NoteShelf.journalPictures(text: text, pending: Array(pending.keys)).compactMap { name in
            pending[name].map { NoteJournal.Picture(name: name, data: $0) }
        }
        var entry = NoteJournal.Entry(noteID: paper.noteID, path: paper.url.path, base: aside ? nil : base, text: text, pictures: pictures, aside: aside)
        if !aside {
            // Pictures still being read for it: their sources, so a quit before they're in loses none.
            let loading = (importsLoading[paper.noteID] ?? [:]).sorted { $0.key < $1.key }.flatMap(\.value)
            if !loading.isEmpty { entry.imports = loading }
            // Nothing waiting to be written: this text is the file's already.
            if firstBase == nil, text == paper.revision { entry.landed = true }
        }
        NoteJournal.queue.async { NoteJournal.snapshot(entry) }
    }

    private static func words(_ work: NoteWork) -> String {
        switch work {
        case .move: "Petal couldn't move that note (or its pictures): it's where it was."
        case .keep: "Something changed since these were shown (a version arrived, or one was edited): nothing was removed."
        default: "Petal couldn't finish something for a note."
        }
    }

    private func retryLater() {
        guard !retrying else { return }
        retrying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.retrying = false
            for session in self.sessions.values where session.failing {
                session.failing = false
                self.pump(session)
            }
        }
    }

    /// Every session's work, as a drain sees it.
    /// Pictures set aside on a paper (Try again) are tried once more.
    private func drainJobs() -> [(session: Int, items: [NoteSession.Item])] {
        sessions.values.compactMap { session in
            var items = session.pending
            if let trouble = pictureTrouble[session.key], !trouble.isEmpty, let paper = paper(session.key) {
                nextID += 1
                items.append(NoteSession.Item(id: nextID, work: .pictureBytes(trouble, noteID: paper.noteID), done: []))
            }
            return items.isEmpty ? nil : (session.id, items)
        }
    }

    /// Picture bytes not in their folders yet, by session: a snapshot whose text lands keeps them until they are.
    private func drainUnsaved() -> [Int: Set<String>] {
        var unsaved: [Int: Set<String>] = [:]
        for session in sessions.values {
            guard let paper = paper(session.key), let pending = pendingPictures[paper.noteID], !pending.isEmpty else { continue }
            unsaved[session.id] = Set(pending.keys)
        }
        return unsaved
    }

    /// Petal quits: every session's work is done on the file queue, in order, after whatever is under way there;
    /// what still can't be written goes to "Unsaved notes". Never waits on the main thread: `done` is called (on any
    /// thread) once it's finished.
    func drain(then done: @escaping @Sendable () -> Void) {
        // Nothing new is started (or answered) here from now: what's under way finishes on the file queue, and the
        // drain does each piece left exactly once.
        draining = true
        let jobs = drainJobs()
        let unsaved = drainUnsaved()
        let root = self.root
        Self.io.async {
            Self.drain(jobs, unsaved: unsaved, root: root)
            done()
        }
    }

    /// The one way a session's work is finished without the main thread (quit, switching folders): each piece not
    /// done yet is done (a tool's, only while its asker is there); one done whose answer the main thread never saw is
    /// taken as it was. Pictures whose bytes are in get their references, at the end of the note, in one based write
    /// after the rest; bytes that can't be written, and writing that fails once more, go to "Unsaved notes". Only on
    /// `io`.
    ///
    /// The journal hears of it only once every piece is done, so a text that landed while a picture it references
    /// didn't (`unsaved`, from memory, and any picture that fails here) keeps its snapshot, with those pictures' bytes,
    /// for the next launch's recovery (`NoteShelf.journalClears`).
    nonisolated static func drain(_ jobs: [(session: Int, items: [NoteSession.Item])], unsaved: [Int: Set<String>] = [:], root: URL) {
        for job in jobs {
            let noteID = NoteDisk.states[job.session]?.noteID ?? ""
            // The bytes of pictures this session was writing: a rescued text keeps the ones it references.
            let pictures = job.items.flatMap { item -> [NotePictureBytes] in if case .pictureBytes(let p, _) = item.work { p } else { [] } }
            var stillUnsaved = unsaved[job.session] ?? []
            var saved = Set<String>()
            var landed: [(text: String, aside: Bool)] = []
            for item in job.items {
                // Done by the queue already (its answer never reached the main thread): taken as it was. Else done
                // here, once (a failed one again).
                var result = NoteDisk.results[item.id]
                if result == nil || result?.outcome == .failed { result = NoteDisk.once(item, session: job.session, root: root) }
                NoteDisk.results[item.id] = nil
                guard let result else { continue }
                switch (item.work, result.outcome) {
                case (.write(let text, _), .written), (.write(let text, _), .keptBoth), (.create(let text, _, _, _), .written):
                    landed.append((text, false))
                case (.keepAside(let text), .keptBoth):
                    landed.append((text, true))
                case (.pictureBytes(let written, _), .written):
                    for picture in written { stillUnsaved.remove(picture.name); saved.insert(picture.name) }
                case (.pictureBytes(let failed, _), _):
                    for picture in failed { stillUnsaved.insert(picture.name) }
                case (_, .failed) where item.work.keeps:
                    // Still can't land: "Unsaved notes", with the pictures it references (the journal keeps it too).
                    if let text = item.work.text {
                        let referenced = pictures.filter { text.contains($0.name) }
                        if rescue(text, noteID: noteID, pictures: referenced) { landed.append((text, false)) }
                    }
                default: break
                }
            }
            let unsavedNow = stillUnsaved.subtracting(saved)
            let texts = landed, written = saved
            NoteJournal.queue.async {
                for (text, aside) in texts { NoteJournal.landed(noteID: noteID, text: text, aside: aside, unsaved: unsavedNow) }
                if !written.isEmpty { NoteJournal.picturesSaved(noteID: noteID, names: written) }
            }
        }
    }

    /// Writing that couldn't reach its file, kept in Application Support's "Unsaved notes", named for the note, its
    /// pictures in a pictures' folder beside it laid out as in the notes' folder, so its references hold. True once
    /// the text and every picture are written there.
    @discardableResult
    nonisolated static func rescue(_ text: String, noteID: String, pictures: [NotePictureBytes]) -> Bool {
        let fm = FileManager.default
        let folder = Config.supportFolder.appending(path: "Unsaved notes")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if !pictures.isEmpty {
            let assets = folder.appending(path: NoteShelf.assetsFolder(id: noteID))
            try? fm.createDirectory(at: assets, withIntermediateDirectories: true)
            for picture in pictures {
                let file = assets.appending(path: picture.name)
                if !fm.fileExists(atPath: file.path), (try? picture.data.write(to: file, options: .withoutOverwriting)) == nil { return false }
            }
        }
        let stem = safeStem(for: text, fallback: plainStem)
        for n in 0..<100 {
            let file = folder.appending(path: (n == 0 ? stem : "\(stem) \(n + 1)") + ".md")
            if (try? Data(text.utf8).write(to: file, options: .withoutOverwriting)) != nil { return true }
        }
        return false
    }

    // MARK: Watching

    @ObservationIgnored private var watched: URL?

    private func watch() {
        guard !Headless.on, !switching else { return }
        if stream != nil, watched == root { return }
        stopWatching()
        watched = root
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let store = Unmanaged<NoteStore>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { store.changed() } }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, Self.io)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watched = nil
    }

    private func changed() {
        reloadSoon?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadSoon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: Finding

    func paper(_ key: String) -> PaperNote? { notes.first { $0.key == key } }

    /// The note with this id (its first paper, when iCloud made two), or a word of its title.
    func find(_ idOrTitle: String) -> PaperNote? {
        notes.first { $0.noteID == idOrTitle && $0.version == nil } ?? notes.first { $0.key == idOrTitle }
            ?? notes.first { $0.version == nil && $0.file.title.localizedCaseInsensitiveCompare(idOrTitle) == .orderedSame }
    }

    func notebook(_ name: String) -> Notebook? { notebooks.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame } }

    /// A paper that can't be written: a version iCloud kept, or one of a note's papers while it has two. Each shows
    /// read only, with Keep this one.
    func readOnly(_ paper: PaperNote) -> Bool { paper.version != nil || (conflicts[paper.noteID]?.count ?? 0) > 1 }

    // MARK: Changing notes (every path comes here)

    /// The one way to change a note: `edit` applied to it in memory at once, then written through its session.
    /// `base`: the exact text of the file the edit was made on (an editor's own: what it last loaded or wrote; a
    /// tool's or Petal's: the note as it is now); the write lands only while the file still says it, or already says
    /// the new text, else it's kept beside it. `expect`: only while the note is still this revision (a completion that
    /// started from an older one: nothing changes). `touch`: a change of the person's words (its modified time).
    /// `live`: a tool's asker, checked right before the write. Returns the note's text as it will be written, the
    /// base for the editor's next edit; nil when nothing changed (read only, gone, fenced, switching folders).
    @discardableResult
    func change(_ key: String, base: String? = nil, expect: String?? = nil, touch stamp: Bool = true, live: (@Sendable () -> Bool)? = nil,
                edit: (inout NoteFile) -> Void, done: (@MainActor (Outcome) -> Void)? = nil) -> String? {
        guard !switching, var paper = paper(key), !readOnly(paper) else { return nil }
        if let expect, paper.revision != expect { return nil }
        guard let session = session(for: key) else { return nil }
        let since = base ?? paper.revision
        edit(&paper.file)
        if stamp { paper.file.modified = Date() }
        let text = paper.file.serialized()
        if live == nil {
            // The person's own (or Petal's): shown at once.
            paper.revision = text
            if let index = notes.firstIndex(where: { $0.key == key }) { notes[index] = paper }
            touch(key)
        }
        // A tool's: nothing changes here until it landed (`finished`); cancelled, it leaves nothing behind.
        enqueue(session, .write(text: text, base: since), live: live, done: done)
        // The person's: a whole snapshot in the journal, as the queue now holds it.
        if live == nil { snapshot(paper, text: text, session: session) }
        return text
    }

    /// What was typed into a paper that turned read only as the person typed: kept beside its file, never lost.
    func keepAside(_ key: String, body: String) {
        guard !switching, var paper = paper(key), paper.version == nil, let session = session(for: key) else { return }
        paper.file.body = body
        paper.file.modified = Date()
        let text = paper.file.serialized()
        snapshot(paper, text: text, session: session, aside: true)
        enqueue(session, .keepAside(text: text), done: { _ in self.reload() })
    }

    /// A new note in `notebook` (made, cover and all, if it's new), its file named for its first words: shown at
    /// once, its file made through its session under the first name free on disk (`onRekey` when that isn't the one
    /// it was shown with). `done`: the note once its file is there, or nil when it couldn't be made yet (kept, tried
    /// again) or its asker went.
    @discardableResult
    func make(_ file: NoteFile, in notebook: String, live: (@Sendable () -> Bool)? = nil, then done: (@MainActor (PaperNote?) -> Void)? = nil) -> PaperNote? {
        guard !switching else { done?(nil); return nil }
        let name = ensureNotebook(notebook, color: "")
        let folder = root.appending(path: name)
        // Names shown here or still being made (another note of the same title on its way, a tool's not shown yet)
        // are taken: two notes never share a provisional name, so each has its own session and answer.
        let taken = Set(notes.filter { $0.notebook == name }.map { $0.url.lastPathComponent.lowercased() })
            .union(reserved.filter { $0.hasPrefix(folder.path.lowercased() + "/") }.map { ($0 as NSString).lastPathComponent })
        // Shown at once under a plain name (never its title: the file's name is made on the file queue from the
        // title after the vault's redaction, NoteStore.safeStem), which is also the name when that can't be checked.
        let stem = NoteText.fileName("Note \(Self.shortDate.string(from: file.created))")
        let text = file.serialized()
        let paper = PaperNote(file: file, url: folder.appending(path: NoteShelf.freeName(stem, taken: taken)), notebook: name, revision: text)
        let provisional = paper.url.path.lowercased()
        reserved.insert(provisional)
        NoteReservations.add(provisional)
        if live == nil {
            notes.insert(paper, at: 0)
            touch(paper.key)
        }
        let session = makeSession(key: paper.key, url: paper.url, noteID: paper.noteID, revision: nil)
        session.reservation = provisional
        enqueue(session, .create(text: text, stem: stem, folder: folder), live: live) { outcome in
            // A tool's note shows once its file is made; cancelled, nothing of it is left.
            if live != nil, outcome == .written, self.paper(session.key) == nil {
                var made = paper
                made.url = URL(fileURLWithPath: session.key)
                self.notes.insert(made, at: 0)
                self.touch(made.key)
            }
            done?(outcome == .written ? self.paper(session.key) : nil)
        }
        if live == nil { snapshot(paper, text: text, session: session) }
        return live == nil ? paper : nil
    }

    /// Provisional paths of notes being made (lowercased): reserved until their files are.
    @ObservationIgnored private var reserved: Set<String> = []

    private static let shortDate: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "d MMM HH.mm"
        return format
    }()

    /// The one way a notebook is made, for every path (a new note in it, a new default notebook, a move into it,
    /// New notebook…, its color): its folder and its cover ("About this notebook", with its color), the cover made
    /// through a session of its own and only where no cover is. Returns the notebook's folder name.
    @discardableResult
    func ensureNotebook(_ name: String, color: String) -> String {
        let folderName = NoteShelf.folderName(name)
        guard notebook(folderName) == nil, !switching else { return folderName }
        let folder = root.appending(path: folderName)
        var cover = NoteFile(body: "# About this notebook\n\nWhat \(folderName) is for.")
        cover.cover = true
        cover.color = color
        let url = folder.appending(path: NoteShelf.coverName)
        let paper = PaperNote(file: cover, url: url, notebook: folderName, revision: cover.serialized())
        notebooks.append(Notebook(name: folderName, folder: folder, color: color, cover: paper.key, count: 0))
        if self.paper(paper.key) == nil { notes.append(paper) }
        touch(paper.key)
        let session = sessionAt(paper.key, noteID: cover.id) ?? makeSession(key: paper.key, url: url, noteID: cover.id, revision: nil)
        enqueue(session, .create(text: cover.serialized(), stem: "About this notebook", folder: folder, exact: url)) { _ in self.reload() }
        return folderName
    }

    /// The one move: a note (and first its pictures) into another notebook, made if it's new, through its session,
    /// after whatever is waiting there and before whatever comes next (saves and pictures made meanwhile land where
    /// it lands). `done`: the note where it is now, or nil when it couldn't be moved (or its asker went).
    func move(_ key: String, to notebook: String, live: (@Sendable () -> Bool)? = nil, then done: @escaping @MainActor (PaperNote?) -> Void = { _ in }) {
        guard let paper = paper(key) else { return done(nil) }
        let name = NoteShelf.folderName(notebook)
        guard name != paper.notebook else { return done(paper) }
        guard !switching, !readOnly(paper), let session = session(for: key) else { return done(nil) }
        ensureNotebook(name, color: "")
        enqueue(session, .move(folder: root.appending(path: name)), live: live) { outcome in
            done(outcome == .written ? self.paper(session.key) : nil)
        }
    }

    /// Pictures pasted or dropped on a note, their bytes already read and decoded (never from their source here):
    /// accepted now, in memory, their bytes written beside the note through its session (after whatever is waiting,
    /// a move too). Returns each one's reference (as the note writes it), for the editor to put in as ordinary text;
    /// nil when the note can't take them.
    func acceptPictures(_ key: String, _ items: [(ext: String, data: Data, caption: String)]) -> [(path: String, file: URL, caption: String)]? {
        guard !switching, let paper = paper(key), !readOnly(paper), let session = session(for: key), !items.isEmpty else { return nil }
        let folder = NoteShelf.assetsFolder(id: paper.noteID)
        let pictures = items.map { NotePictureBytes(name: "picture-\(UUID().uuidString.prefix(8).lowercased()).\($0.ext)", data: $0.data, caption: $0.caption) }
        for picture in pictures { pendingPictures[paper.noteID, default: [:]][picture.name] = picture.data }
        enqueue(session, .pictureBytes(pictures, noteID: paper.noteID), done: nil)
        return pictures.map { (folder + "/" + $0.name, paper.url.deletingLastPathComponent().appending(path: folder + "/" + $0.name), $0.caption) }
    }

    /// Pictures pasted or dropped and still being read (a file iCloud is downloading), by note id and paste: what
    /// keeps a new note from being put away as empty, and what each snapshot carries so a quit loses none of them.
    @ObservationIgnored private var importsLoading: [String: [Int: [NoteJournal.Import]]] = [:]

    /// A paste or drop on `key`, recorded before anything is read: its sources go into the journal at once. Nil when
    /// the note can't take pictures now.
    func beginImport(_ key: String, _ items: NoteImport) -> (token: Int, sources: [NoteJournal.Import])? {
        guard !switching, !draining, let paper = paper(key), !readOnly(paper), let session = session(for: key) else { return nil }
        nextID += 1
        let token = nextID
        var sources = items.files.map { NoteJournal.Import(token: token, path: $0.path, ext: $0.pathExtension.lowercased(), caption: $0.deletingPathExtension().lastPathComponent) }
        if let png = items.png { sources.append(NoteJournal.Import(token: token, data: png, ext: "png")) }
        if let tiff = items.tiff { sources.append(NoteJournal.Import(token: token, data: tiff, ext: "tiff")) }
        importsLoading[paper.noteID, default: [:]][token] = sources
        snapshot(paper, text: paper.file.serialized(), session: session)
        return (token, sources)
    }

    /// A paste that couldn't go in after all: its sources stay with the note (and in every snapshot) until it's
    /// put in from the journal, or the next launch does.
    func holdImport(_ noteID: String, _ token: Int, _ sources: [NoteJournal.Import]) {
        importsLoading[noteID, default: [:]][token] = sources
    }

    /// A paste's read is over. `journal`: its sources leave the journal too (it was accepted and its references
    /// are in a snapshot now, or nothing in it could be read); false while quitting, so the journal keeps them.
    func endImport(_ noteID: String, _ token: Int, journal: Bool) {
        importsLoading[noteID]?[token] = nil
        if importsLoading[noteID]?.isEmpty == true { importsLoading[noteID] = nil }
        if journal { NoteJournal.queue.async { NoteJournal.importsDone(noteID: noteID, token: token) } }
    }

    /// A paste that couldn't go in through the note's session (the notes folder changed, or the note couldn't take
    /// it): put in from its journal entry, into its note in the folder it was pasted in (found by id; a copy beside
    /// it or a file of its own when that's what's safe: NoteJournal.recoverEntry), and out of the journal only once
    /// its bytes and reference are stored. Else it stays for the next launch.
    func putIn(_ noteID: String, _ token: Int, root: URL, then done: @escaping @MainActor (Bool, [NoteJournal.Import]) -> Void) {
        NoteJournal.queue.async {
            let entry = NoteJournal.read(NoteJournal.file(noteID))
            Self.io.async {
                var stored = false
                var waiting: [NoteJournal.Import] = entry?.imports?.filter { $0.token == token } ?? []
                if var entry {
                    // Its text already in its note (the folder switch's drain wrote it): the base its lines go on.
                    let found = NoteStore.read(root).notes.filter { $0.noteID == noteID && $0.version == nil }
                    if found.count == 1, NoteStore.coordinatedRead(found[0].url) == entry.text { entry.landed = true }
                    (stored, waiting) = NoteJournal.putIn(entry, token: token, root: root)
                }
                // Out of the journal: what went in; a file not read yet stays for its own next try.
                let keeping = waiting
                if stored { NoteJournal.queue.async { NoteJournal.importsDone(noteID: noteID, token: token, keeping: keeping) } }
                DispatchQueue.main.async { MainActor.assumeIsolated { if stored, root == self.root { self.reload() }; done(stored, keeping) } }
            }
        }
    }

    /// Files of pastes that weren't read yet (iCloud still downloading them), by note id and paste: kept in the
    /// journal and in every snapshot, and said on the paper with Try again and Remove until their pictures and links
    /// are stored.
    private(set) var importTrouble: [String: [Int: [NoteJournal.Import]]] = [:]

    /// What of a paste is still waiting after its read: kept with the note (and in its snapshots), and on its paper.
    func keepWaiting(_ noteID: String, _ token: Int, _ waiting: [NoteJournal.Import]) {
        importsLoading[noteID]?[token] = nil
        importTrouble[noteID]?[token] = nil
        if !waiting.isEmpty {
            importsLoading[noteID, default: [:]][token] = waiting
            importTrouble[noteID, default: [:]][token] = waiting
        }
        if importsLoading[noteID]?.isEmpty == true { importsLoading[noteID] = nil }
        if importTrouble[noteID]?.isEmpty == true { importTrouble[noteID] = nil }
    }

    /// Try again: the waiting files of a note's pastes, taken off its paper to be read again (a new paste each);
    /// their old pastes leave the journal once the new ones are recorded.
    func takeWaiting(_ noteID: String) -> [(token: Int, sources: [NoteJournal.Import])] {
        guard let trouble = importTrouble.removeValue(forKey: noteID) else { return [] }
        return trouble.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Remove: a note's waiting files let go (out of memory and the journal).
    func dropWaiting(_ noteID: String) {
        for token in (importTrouble.removeValue(forKey: noteID) ?? [:]).keys { endImport(noteID, token, journal: true) }
    }

    /// Pictures still being read for the note: it isn't empty.
    func importing(_ key: String) -> Bool { paper(key).map { importsLoading[$0.noteID]?.isEmpty == false } ?? false }

    /// Quitting: a paste finishing now is left in the journal for the next launch.
    var quitting: Bool { draining }

    /// Pictures accepted for the note and not in it yet: it isn't empty.
    func picturesPending(_ key: String) -> Bool { paper(key).flatMap { sessionAt(key, noteID: $0.noteID) }?.picturesPending ?? false }

    /// A note made and put away empty goes to the Trash (never deleted outright), after its own work, and only while
    /// its file still says what Petal last saw there; never one with pictures on the way.
    func trash(_ key: String) {
        guard let paper = paper(key), let session = session(for: key),
              NoteShelf.mayTrash(bodyEmpty: paper.file.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, picturesPending: session.picturesPending,
                                 importing: importing(key))
        else { return }
        notes.removeAll { $0.key == key }
        gone(key)
        enqueue(session, .trash(revision: paper.revision), done: nil)
    }

    /// A conflict settled, through the session of the note's file, on the papers exactly as they were shown: each
    /// candidate checked again inside its own coordinated write or trash (`NoteStore.keep`).
    func keep(_ kept: PaperNote) {
        let shown = conflicts[kept.noteID] ?? [kept]
        var snapshot: [String: String] = [:]
        for paper in shown { snapshot[paper.version.map { "version:" + $0 } ?? "file:" + paper.url.path] = paper.revision ?? "" }
        let plan = NoteKeep(snapshot: snapshot, kept: kept.url, keptText: kept.version == nil ? nil : kept.file.serialized(),
                            files: Array(Set(shown.map(\.url))))
        let key = kept.url.path
        let session = sessionAt(key, noteID: kept.noteID) ?? makeSession(key: key, url: kept.url, noteID: kept.noteID, revision: kept.revision)
        enqueue(session, .keep(plan), done: nil)
    }

    /// A notebook's color, kept on its cover (made where there's none).
    func recolor(_ notebook: String, _ value: String) {
        if let book = self.notebook(notebook), let key = book.cover, let cover = paper(key), !readOnly(cover) {
            change(key, touch: false) { $0.color = value }
            if let index = notebooks.firstIndex(where: { $0.name == book.name }) { notebooks[index].color = value }
            return
        }
        if self.notebook(notebook) == nil { ensureNotebook(notebook, color: value); return }
        // A notebook with no cover yet (a folder made elsewhere): its cover, through a session, never over one.
        var cover = NoteFile(body: "# About this notebook\n\nWhat \(notebook) is for.")
        cover.cover = true
        cover.color = value
        let folder = root.appending(path: notebook)
        let url = folder.appending(path: NoteShelf.coverName)
        let paper = PaperNote(file: cover, url: url, notebook: notebook, revision: cover.serialized())
        if self.paper(paper.key) == nil { notes.append(paper) }
        let session = sessionAt(paper.key, noteID: cover.id) ?? makeSession(key: paper.key, url: url, noteID: cover.id, revision: nil)
        enqueue(session, .create(text: cover.serialized(), stem: "About this notebook", folder: folder, exact: url)) { _ in self.reload() }
    }

    /// The notebook's color: its cover's ("accent" is the Mac's accent color), else the Mac's accent color.
    func color(of notebook: String) -> NSColor {
        let hex = self.notebook(notebook)?.color ?? ""
        if hex.isEmpty || hex == "accent" { return NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue }
        return NSColor(hex: hex) ?? NSColor.controlAccentColor
    }

    /// For snapshots: notes as given, nothing read or written.
    func preview(_ notes: [PaperNote], notebooks: [Notebook]) {
        self.notes = notes
        self.notebooks = notebooks
        regroup()
        loaded = true
    }
}

/// What Petal Notes keeps on this Mac only (never synced): this Mac's id, which notes are open, where notes were
/// moved to, the last notebook used on each site or app. `Application Support/Petal/notes-state.json`, written off
/// the main thread.
struct NoteLocal: Codable, Equatable {
    var mac = UUID().uuidString
    /// Notes showing (folded or open) on their window or Desktop, by note id.
    var shown: [String] = []
    /// Where the person left a note: tied to its window's nearest corner (NoteSpot), or on the Desktop a point on
    /// the screen (AppKit's coordinates).
    var spots: [String: NoteSpot] = [:]
    var desk: [String: [Double]] = [:]
    /// The notebook last used on each site or app.
    var lastNotebook: [String: String] = [:]

    static var file: URL { Config.supportFolder.appending(path: "notes-state.json") }

    static func load() -> NoteLocal {
        guard let data = try? Data(contentsOf: file), let local = try? JSONDecoder().decode(NoteLocal.self, from: data) else { return NoteLocal() }
        return local
    }

    func save() {
        guard !Headless.on, let data = try? JSONEncoder().encode(self) else { return }
        NoteStore.io.async {
            try? FileManager.default.createDirectory(at: Config.supportFolder, withIntermediateDirectories: true)
            try? data.write(to: Self.file, options: .atomic)
        }
    }
}

/// Provisional paths (lowercased) of notes being made, shared between the main thread (which reserves one when a
/// note is shown) and the file queue (where its file's name is picked): a name picked on disk never takes another
/// note's reservation.
enum NoteReservations {
    nonisolated(unsafe) private static var paths: Set<String> = []
    nonisolated private static let lock = NSLock()

    nonisolated static func add(_ path: String) { lock.withLock { _ = paths.insert(path) } }
    nonisolated static func remove(_ path: String) { lock.withLock { _ = paths.remove(path) } }

    /// The file names reserved in `folder` (lowercased), but `own`.
    nonisolated static func names(in folder: String, except own: String?) -> Set<String> {
        lock.withLock {
            Set(paths.filter { $0 != own && ($0 as NSString).deletingLastPathComponent == folder }.map { ($0 as NSString).lastPathComponent })
        }
    }
}

/// The file names Petal made from a redacted title, by note id (Application Support's notes-named.json): only these
/// are told to agents as they are; any other name is told opaquely (NoteTold.path). Loaded and saved off the main
/// thread; read anywhere.
enum NoteNames {
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var names: [String: Set<String>] = [:]
    nonisolated private static var file: URL { Config.supportFolder.appending(path: "notes-named.json") }

    nonisolated static func load() {
        guard let data = try? Data(contentsOf: file), let read = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        lock.withLock { for (id, list) in read { names[id, default: []].formUnion(list.map { $0.lowercased() }) } }
    }

    nonisolated static func vouch(_ noteID: String, _ name: String) {
        let all: [String: [String]] = lock.withLock {
            names[noteID, default: []].insert(name.lowercased())
            return names.mapValues { Array($0).sorted() }
        }
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: file, options: .atomic) }
    }

    nonisolated static func vouched(_ noteID: String, _ name: String) -> Bool {
        lock.withLock { names[noteID]?.contains(name.lowercased()) == true }
    }
}
