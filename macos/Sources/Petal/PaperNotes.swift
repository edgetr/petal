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

/// Work waiting to reach a note's file, done in order by its session.
enum NoteWork: @unchecked Sendable {
    /// A new note's file, under the first name free in `folder`.
    case create(text: String, stem: String, folder: URL)
    /// The note's text, made on `base` (what the file said when the edit began).
    case write(text: String, base: String?)
    /// An edit to a paper that turned read only as it was typed: kept beside the file as a conflict copy.
    case keepAside(text: String)
    /// Into another notebook (made if it's new), its pictures' folder with it.
    case move(folder: URL)
    /// Pictures pasted or dropped, saved into the note's pictures' folder.
    case pictures(NoteImport, noteID: String)
    /// To the Trash, only while the file still says `revision`.
    case trash(revision: String?)

    /// Carries the person's writing: tried again until it lands, and kept in "Unsaved notes" if it can't by quit.
    var keeps: Bool {
        switch self {
        case .create, .write, .keepAside, .pictures: true
        case .move, .trash: false
        }
    }
}

/// What a piece of work did: its outcome, where the note's file is now, and pictures saved.
struct NoteWorkResult: @unchecked Sendable {
    var outcome: NoteStore.Outcome
    var url: URL?
    var pictures: [(path: String, file: URL, caption: String)] = []
}

/// One note's work not yet on disk: typed text, keep-asides, pictures, a move, a new file, a trash. Every path
/// (the editor's saves, the tools, a place followed, a picture import, a move from the letterhead or the socket)
/// goes through it, in order; quitting, trying again and switching the notes' folder drain the same list the same
/// way (`NoteStore.drain`). Its paper is never replaced by a read of the folder while it has work.
@MainActor
final class NoteSession {
    struct Item {
        let id: Int
        var work: NoteWork
        var done: [@MainActor (NoteStore.Outcome) -> Void]
    }

    let id: Int
    var key: String
    var pending: [Item] = []
    var running = false
    /// The first piece of work couldn't be done: it's tried again in a few seconds.
    var failing = false

    init(id: Int, key: String) {
        self.id = id
        self.key = key
    }

    var busy: Bool { running || !pending.isEmpty }
}

/// What the file queue knows of each session's file: where it is, what it said when this Mac's chain of writes
/// began or after the last that landed (`anchor`), the texts this session's writes carried (`ours`, hashes), the
/// newest of them (`latest`), and each piece of work's result. Only ever touched on `NoteStore.io`.
enum NoteDisk {
    struct State {
        var url: URL
        var noteID: String
        var anchor: String?
        var ours: Set<Int> = []
        var latest: String?
    }

    nonisolated(unsafe) static var states: [Int: State] = [:]
    nonisolated(unsafe) static var results: [Int: NoteWorkResult] = [:]
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
    @ObservationIgnored private var sessions: [String: NoteSession] = [:]
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var retrying = false
    /// Switching to another notes folder: the old one's work is drained and nothing new starts there.
    @ObservationIgnored private(set) var switching = false
    /// Papers being written in (an open editor): never dropped by a read of the folder.
    @ObservationIgnored var keepAlive: (String) -> Bool = { _ in false }
    /// Called on the main thread after every read of the folder.
    @ObservationIgnored var onChange: () -> Void = {}
    /// A paper's file is somewhere else now (a move, a new note's name on disk): old key, the paper now.
    @ObservationIgnored var onRekey: (String, PaperNote) -> Void = { _, _ in }
    /// Pictures saved for a note: put in its open editor at `at` (true), or nowhere open (false: they go at the end).
    @ObservationIgnored var onPictures: (String, [(path: String, file: URL, caption: String)], Int) -> Bool = { _, _, _ in false }
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

    func start() {
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
        let oldRoot = root
        Self.io.async {
            Self.drain(jobs, root: oldRoot)
            NoteDisk.states = [:]
            NoteDisk.results = [:]
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.sessions = [:]
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
        guard let inside = NoteShelf.within(url.standardizedFileURL.path, root.standardizedFileURL.path) else { return false }
        var at = root.standardizedFileURL
        for part in inside.split(separator: "/") {
            at = at.appending(path: String(part))
            var info = stat()
            if lstat(at.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { return false }
        }
        return true
    }

    enum Outcome: Equatable { case written, keptBoth(URL), failed }

    /// Writes `text` over the file at `url` only while it still says `base` (what the edit was made on); changed
    /// since, the edit goes to a copy beside it instead ("Name (conflicted copy).md"), and both show as the note's
    /// papers. A file that already says `text` is done. Read and written in one coordinated step. Off the main thread.
    nonisolated static func save(_ text: String, to url: URL, base: String?, root: URL) -> Outcome {
        guard safe(url, root: root) else { return .failed }
        var outcome = Outcome.failed
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { url in
            let there = FileManager.default.fileExists(atPath: url.path)
            let disk = there ? (try? String(contentsOf: url, encoding: .utf8)) : nil
            if there, disk == nil { return }   // there, but unreadable: never written over
            switch NoteShelf.save(disk: disk, text: text, base: base) {
            case .already: outcome = .written
            case .write: outcome = (try? Data(text.utf8).write(to: url, options: .atomic)) != nil ? .written : .failed
            case .keepBoth: outcome = keepBeside(text, original: url, root: root)
            }
        }
        return outcome
    }

    /// The same edit kept beside one file again overwrites the copy it made before, rather than making another,
    /// with what Petal last wrote there: a copy changed since (another editor, another Mac) is never written over.
    /// Only on `io`.
    nonisolated(unsafe) private static var copies: [String: (url: URL, text: String)] = [:]

    nonisolated static func keepBeside(_ text: String, original: URL, root: URL) -> Outcome {
        let mark = original.path + "\n" + (NoteFile.parse(text, fallbackID: "", fallbackDate: Date()).id)
        // Its copy from before, while it still says what Petal wrote there; changed since, a new copy.
        if let copy = copies[mark], safe(copy.url, root: root) {
            var reused = false
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: copy.url, options: [], error: &error) { url in
                let disk = try? String(contentsOf: url, encoding: .utf8)
                guard disk == copy.text || disk == text else { return }
                reused = disk == text || (try? Data(text.utf8).write(to: url, options: .atomic)) != nil
            }
            if reused {
                copies[mark] = (copy.url, text)
                return .keptBoth(copy.url)
            }
            copies[mark] = nil
        }
        let folder = original.deletingLastPathComponent()
        let stem = original.deletingPathExtension().lastPathComponent
        for _ in 0..<20 {
            let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
            let copy = folder.appending(path: NoteShelf.conflictName(stem, taken: taken))
            if create(text, at: copy, root: root) {
                copies[mark] = (copy, text)
                return .keptBoth(copy)
            }
        }
        return .failed
    }

    /// Makes a file where none is: never over another (created exclusively, coordinated). Off the main thread.
    @discardableResult
    nonisolated static func create(_ text: String, at url: URL, root: URL) -> Bool {
        guard safe(url, root: root) else { return false }
        var ok = false
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { url in
            ok = (try? Data(text.utf8).write(to: url, options: .withoutOverwriting)) != nil
        }
        return ok
    }

    /// A new file in `folder` named for `stem`: the first free name on disk, made exclusively, tried again when
    /// another file takes that name first. Off the main thread.
    nonisolated static func createNamed(_ text: String, stem: String, in folder: URL, root: URL) -> URL? {
        guard safe(folder, root: root) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var tried: Set<String> = []
        for _ in 0..<20 {
            let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() }).union(tried)
            let name = NoteShelf.freeName(stem, taken: taken)
            let url = folder.appending(path: name)
            if create(text, at: url, root: root) { return url }
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

    /// One piece of a session's work, on `io`, with what the queue knows of its file.
    nonisolated static func perform(_ work: NoteWork, session: Int, root: URL) -> NoteWorkResult {
        guard var state = NoteDisk.states[session] else { return NoteWorkResult(outcome: .failed) }
        defer { NoteDisk.states[session] = state }
        switch work {
        case .create(let text, let stem, let folder):
            guard let made = createNamed(text, stem: stem, in: folder, root: root) else { return NoteWorkResult(outcome: .failed) }
            state.url = made
            state.anchor = text
            state.ours.insert(text.hashValue)
            state.latest = text
            return NoteWorkResult(outcome: .written, url: made)
        case .write(let text, let base):
            let outcome = save(text, to: state.url, base: NoteShelf.effectiveBase(base, ours: state.ours, anchor: state.anchor), root: root)
            state.ours.insert(text.hashValue)
            state.latest = text
            if outcome == .written { state.anchor = text }
            return NoteWorkResult(outcome: outcome, url: state.url)
        case .keepAside(let text):
            return NoteWorkResult(outcome: keepBeside(text, original: state.url, root: root), url: state.url)
        case .move(let folder):
            guard let target = move(state.url, noteID: state.noteID, into: folder, root: root) else { return NoteWorkResult(outcome: .failed, url: state.url) }
            state.url = target
            return NoteWorkResult(outcome: .written, url: target)
        case .pictures(let items, let noteID):
            var saved: [(path: String, file: URL, caption: String)] = []
            let folder = state.url.deletingLastPathComponent().appending(path: NoteShelf.assetsFolder(id: noteID))
            guard safe(folder, root: root) else { return NoteWorkResult(outcome: .failed, url: state.url) }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var found: [(Data, String, String)] = []
            for file in items.files { if let data = try? Data(contentsOf: file) { found.append((data, file.pathExtension.lowercased(), file.deletingPathExtension().lastPathComponent)) } }
            if let png = items.png { found.append((png, "png", "")) }
            if let tiff = items.tiff, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) { found.append((data, "png", "")) }
            for (data, ext, caption) in found {
                let name = "picture-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
                let file = folder.appending(path: name)
                guard safe(file, root: root), (try? data.write(to: file, options: .withoutOverwriting)) != nil else {
                    return NoteWorkResult(outcome: .failed, url: state.url, pictures: saved)
                }
                saved.append((folder.lastPathComponent + "/" + name, file, caption))
            }
            return NoteWorkResult(outcome: .written, url: state.url, pictures: saved)
        case .trash(let revision):
            // Only while it still says what Petal last saw there: words written into it elsewhere keep it.
            let disk = coordinatedRead(state.url)
            if disk == nil || disk == revision || disk == state.latest { trash(state.url, root: root) }
            return NoteWorkResult(outcome: .written, url: state.url)
        }
    }

    /// Moves a note's file (and its pictures' folder) into `folder`, under the first name free there on disk, never
    /// over a file. Off the main thread.
    nonisolated static func move(_ from: URL, noteID: String, into folder: URL, root: URL) -> URL? {
        guard safe(from, root: root), safe(folder, root: root) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = from.deletingPathExtension().lastPathComponent
        var target: URL?
        for _ in 0..<20 where target == nil {
            let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
            let candidate = folder.appending(path: NoteShelf.freeName(stem, taken: taken))
            guard safe(candidate, root: root) else { break }
            var error: NSError?
            var moved = false
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: from, options: .forMoving, writingItemAt: candidate, options: .forReplacing, error: &error) { a, b in
                guard !FileManager.default.fileExists(atPath: b.path) else { return }
                moved = (try? FileManager.default.moveItem(at: a, to: b)) != nil
            }
            if moved { target = candidate } else if error != nil { break }
        }
        guard let target else { return nil }
        let assets = from.deletingLastPathComponent().appending(path: NoteShelf.assetsFolder(id: noteID))
        let newAssets = folder.appending(path: assets.lastPathComponent)
        if FileManager.default.fileExists(atPath: assets.path), !FileManager.default.fileExists(atPath: newAssets.path),
           safe(assets, root: root), safe(newAssets, root: root) {
            try? FileManager.default.moveItem(at: assets, to: newAssets)
        }
        return target
    }

    // MARK: Sessions

    private func session(for key: String) -> NoteSession? {
        if let session = sessions[key] { return session }
        guard let paper = paper(key), paper.version == nil else { return nil }
        nextID += 1
        let session = NoteSession(id: nextID, key: key)
        sessions[key] = session
        let state = NoteDisk.State(url: paper.url, noteID: paper.noteID, anchor: paper.revision, latest: paper.revision)
        let id = session.id
        Self.io.async { NoteDisk.states[id] = state }
        return session
    }

    private func enqueue(_ session: NoteSession, _ work: NoteWork, done: (@MainActor (Outcome) -> Void)?) {
        // A write joins the last one waiting (not started): the newest text, on the base the first was made on.
        let lastWaiting = session.pending.count > (session.running ? 1 : 0)
        if case .write(let text, _) = work, lastWaiting, let last = session.pending.last, case .write(_, let base) = last.work {
            session.pending[session.pending.count - 1].work = .write(text: text, base: base)
            if let done { session.pending[session.pending.count - 1].done.append(done) }
        } else {
            nextID += 1
            session.pending.append(NoteSession.Item(id: nextID, work: work, done: done.map { [$0] } ?? []))
        }
        pump(session)
    }

    private func pump(_ session: NoteSession) {
        guard !session.running, !session.failing, !switching, let item = session.pending.first else { return }
        session.running = true
        let id = session.id, root = self.root
        Self.io.async {
            NoteDisk.results[item.id] = nil
            let result = Self.perform(item.work, session: id, root: root)
            NoteDisk.results[item.id] = result
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finished(session, item, result) } }
        }
    }

    private func finished(_ session: NoteSession, _ item: NoteSession.Item, _ result: NoteWorkResult) {
        session.running = false
        guard !switching, sessions[session.key] === session else { return }
        let failedWork = result.outcome == .failed
        if failedWork && item.work.keeps {
            // Kept, said on the paper, tried again: never dropped.
            session.failing = true
            failed.insert(session.key)
            onProblem("Petal couldn't save a note: it's kept here and tried again.")
            for done in item.done { done(.failed) }
            session.pending[0].done = []
            retryLater()
            return
        }
        session.pending.removeFirst()
        let itemID = item.id
        Self.io.async { NoteDisk.results[itemID] = nil }
        failed.remove(session.key)
        // Where the file is now: a new note's name on disk, a move.
        if let url = result.url, url.path != session.key, let index = notes.firstIndex(where: { $0.key == session.key }) {
            let old = session.key
            var paper = notes[index]
            gone(old)
            paper.url = url
            if case .move(let folder) = item.work { paper.notebook = folder.lastPathComponent }
            notes[index] = paper
            touch(paper.key)
            sessions[old] = nil
            session.key = paper.key
            sessions[paper.key] = session
            onRekey(old, paper)
        }
        if failedWork { onProblem(Self.words(item.work)) }
        if case .pictures(let items, _) = item.work, !result.pictures.isEmpty, !onPictures(session.key, result.pictures, items.at) {
            // No editor open on it: at the end of the note, through its session like any change.
            let lines = result.pictures.map { NoteBlock.image(path: $0.path, caption: $0.caption).markdown }
            change(session.key) { file in
                file.body += (file.body.isEmpty || file.body.hasSuffix("\n") ? "" : "\n") + lines.joined(separator: "\n")
            }
        }
        for done in item.done { done(result.outcome) }
        switch item.work {
        case .move, .trash: reload()
        default: if case .keptBoth = result.outcome { reload() }
        }
        pump(session)
    }

    private static func words(_ work: NoteWork) -> String {
        switch work {
        case .move: "Petal couldn't move that note: it's where it was."
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
    private func drainJobs() -> [(session: Int, items: [NoteSession.Item])] {
        sessions.values.filter { !$0.pending.isEmpty }.map { ($0.id, $0.pending) }
    }

    /// Petal quits: every session's work is done now, in order, on the file queue (after whatever is under way
    /// there); what still can't be written goes to "Unsaved notes". Waits for it.
    func drain() {
        let jobs = drainJobs()
        let root = self.root
        Self.io.sync { Self.drain(jobs, root: root) }
    }

    /// The one way a session's work is finished without the main thread (quit, switching folders): each piece not
    /// done yet is done; one done whose answer the main thread never saw is taken as it was (pictures saved but not
    /// put in the note go at the end of its text); work that carries writing and fails once more is kept in
    /// "Unsaved notes". Only on `io`.
    nonisolated static func drain(_ jobs: [(session: Int, items: [NoteSession.Item])], root: URL) {
        for job in jobs {
            for item in job.items {
                var result = NoteDisk.results[item.id]
                if result == nil || result?.outcome == .failed { result = perform(item.work, session: job.session, root: root) }
                NoteDisk.results[item.id] = nil
                guard let result else { continue }
                if case .pictures = item.work, !result.pictures.isEmpty, let latest = NoteDisk.states[job.session]?.latest {
                    var file = NoteFile.parse(latest, fallbackID: "", fallbackDate: Date())
                    file.body += (file.body.isEmpty || file.body.hasSuffix("\n") ? "" : "\n")
                        + result.pictures.map { NoteBlock.image(path: $0.path, caption: $0.caption).markdown }.joined(separator: "\n")
                    let text = file.serialized()
                    if perform(.write(text: text, base: latest), session: job.session, root: root).outcome == .failed { rescue(text) }
                    continue
                }
                guard result.outcome == .failed, item.work.keeps else { continue }
                switch item.work {
                case .create(let text, _, _), .write(let text, _), .keepAside(let text): rescue(text)
                default: break
                }
            }
        }
    }

    /// Writing that couldn't reach its file, kept in Application Support's "Unsaved notes", named for the note.
    nonisolated private static func rescue(_ text: String) {
        let folder = Config.supportFolder.appending(path: "Unsaved notes")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let note = NoteFile.parse(text, fallbackID: "", fallbackDate: Date())
        let stem = NoteText.fileName(note.title.isEmpty ? "Note" : note.title)
        for n in 0..<100 {
            let file = folder.appending(path: n == 0 ? stem + ".md" : "\(stem) \(n + 1).md")
            if (try? Data(text.utf8).write(to: file, options: .withoutOverwriting)) != nil { return }
        }
    }

    // MARK: Watching

    private func watch() {
        guard stream == nil, !Headless.on else { return }
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
    /// `base`: what the file said when the edit began (the editor's own); `expect`: only while the note is still
    /// this revision (a completion that started from an older one: nothing changes); `touch`: a change of the
    /// person's words (its modified time). Returns the note's text as it will be written, the base for the next
    /// edit; nil when nothing changed (read only, gone, fenced, switching folders).
    @discardableResult
    func change(_ key: String, base: String? = nil, expect: String?? = nil, touch stamp: Bool = true,
                edit: (inout NoteFile) -> Void, done: (@MainActor (Outcome) -> Void)? = nil) -> String? {
        guard !switching, var paper = paper(key), !readOnly(paper) else { return nil }
        if let expect, paper.revision != expect { return nil }
        guard let session = session(for: key) else { return nil }
        let since = base ?? paper.revision
        edit(&paper.file)
        if stamp { paper.file.modified = Date() }
        let text = paper.file.serialized()
        paper.revision = text
        if let index = notes.firstIndex(where: { $0.key == key }) { notes[index] = paper }
        touch(key)
        enqueue(session, .write(text: text, base: since), done: done)
        return text
    }

    /// What was typed into a paper that turned read only as the person typed: kept beside its file, never lost.
    func keepAside(_ key: String, body: String) {
        guard !switching, var paper = paper(key), paper.version == nil, let session = session(for: key) else { return }
        paper.file.body = body
        paper.file.modified = Date()
        enqueue(session, .keepAside(text: paper.file.serialized()), done: { _ in self.reload() })
    }

    /// A new note in `notebook` (made if it's new), its file named for its first words: shown at once, its file made
    /// through its session under the first name free on disk (`onRekey` when that isn't the one it was shown with).
    /// `done`: the note once its file is there, or nil when it couldn't be made yet (kept, tried again).
    @discardableResult
    func make(_ file: NoteFile, in notebook: String, then done: (@MainActor (PaperNote?) -> Void)? = nil) -> PaperNote? {
        guard !switching else { done?(nil); return nil }
        let name = NoteShelf.folderName(notebook)
        let folder = root.appending(path: name)
        let taken = Set(notes.filter { $0.notebook == name }.map { $0.url.lastPathComponent.lowercased() })
        let stem = NoteText.fileName(file.title.isEmpty ? "Note \(Self.shortDate.string(from: file.created))" : file.title)
        let text = file.serialized()
        let paper = PaperNote(file: file, url: folder.appending(path: NoteShelf.freeName(stem, taken: taken)), notebook: name, revision: text)
        notes.insert(paper, at: 0)
        touch(paper.key)
        if self.notebook(name) == nil { notebooks.append(Notebook(name: name, folder: folder, color: "", cover: nil, count: 1)) }
        guard let session = session(for: paper.key) else { done?(nil); return paper }
        enqueue(session, .create(text: text, stem: stem, folder: folder)) { outcome in
            done?(outcome == .written ? self.paper(session.key) : nil)
        }
        return paper
    }

    private static let shortDate: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "d MMM HH.mm"
        return format
    }()

    /// A new notebook: its folder and its cover with its color (never over a cover already there).
    func makeNotebook(_ name: String, color: String) -> String {
        let folderName = NoteShelf.folderName(name)
        let folder = root.appending(path: folderName)
        guard notebook(folderName) == nil else { return folderName }
        notebooks.append(Notebook(name: folderName, folder: folder, color: color, cover: nil, count: 0))
        var cover = NoteFile(body: "# About this notebook\n\nWhat \(folderName) is for.")
        cover.cover = true
        cover.color = color
        let text = cover.serialized(), root = self.root
        Self.io.async {
            guard Self.safe(folder, root: root) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Self.create(text, at: folder.appending(path: NoteShelf.coverName), root: root)
        }
        return folderName
    }

    /// The one move: a note (and its pictures' folder) into another notebook, made if it's new, through its
    /// session, after whatever is waiting there and before whatever comes next (saves and pictures made meanwhile
    /// land where it lands). `done`: the note where it is now, or nil when it couldn't be moved.
    func move(_ key: String, to notebook: String, then done: @escaping @MainActor (PaperNote?) -> Void = { _ in }) {
        guard let paper = paper(key) else { return done(nil) }
        let name = NoteShelf.folderName(notebook)
        guard name != paper.notebook else { return done(paper) }
        guard !switching, !readOnly(paper), let session = session(for: key) else { return done(nil) }
        _ = makeNotebook(name, color: "")
        enqueue(session, .move(folder: root.appending(path: name))) { outcome in
            done(outcome == .written ? self.paper(session.key) : nil)
        }
    }

    /// Pictures pasted or dropped on a note: read, decoded and saved beside it through its session (so a move or a
    /// fold meanwhile changes nothing), then put in its editor or at the end of its text.
    func importPictures(_ key: String, _ items: NoteImport) -> Bool {
        guard !switching, let paper = paper(key), !readOnly(paper), let session = session(for: key) else { return false }
        enqueue(session, .pictures(items, noteID: paper.noteID), done: nil)
        return true
    }

    /// A note made and put away empty goes to the Trash (never deleted outright), after its own work, and only while
    /// its file still says what Petal last saw there.
    func trash(_ key: String) {
        guard let paper = paper(key), let session = session(for: key) else { return }
        notes.removeAll { $0.key == key }
        gone(key)
        enqueue(session, .trash(revision: paper.revision), done: nil)
    }

    /// A conflict settled, on the papers exactly as they were shown: only while every one of them is still there and
    /// unchanged, and no other version arrived since (`NoteShelf.keepAllowed`), the one kept becomes the note's file
    /// (written and read back when it was a version iCloud kept), then the shown versions are marked resolved and the
    /// other files go to the Trash (never deleted).
    func keep(_ kept: PaperNote) {
        let shown = conflicts[kept.noteID] ?? [kept]
        let root = self.root
        let keptURL = kept.url
        // Each candidate as it was shown: a file by its path, a version by its name.
        var snapshot: [String: String] = [:]
        for paper in shown { snapshot[paper.version.map { "version:" + $0 } ?? "file:" + paper.url.path] = paper.revision ?? "" }
        let files = Set(shown.map(\.url))
        let keptText = kept.version == nil ? nil : kept.file.serialized()
        let keptVersion = kept.version
        Self.io.async {
            var now: [String: String?] = [:]
            for url in files {
                if snapshot["file:" + url.path] != nil {
                    now["file:" + url.path] = FileManager.default.fileExists(atPath: url.path) ? Self.coordinatedRead(url) : String?.none
                }
                for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                    now["version:" + version.url.lastPathComponent] = try? String(contentsOf: version.url, encoding: .utf8)
                }
            }
            var ok = NoteShelf.keepAllowed(shown: snapshot, now: now) && Self.safe(keptURL, root: root)
            if ok, let keptText, keptVersion != nil {
                var error: NSError?
                var written = false
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: keptURL, options: [], error: &error) { url in
                    written = (try? Data(keptText.utf8).write(to: url, options: .atomic)) != nil
                }
                ok = written && Self.coordinatedRead(keptURL) == keptText
            }
            if ok {
                for url in files {
                    for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] where snapshot["version:" + version.url.lastPathComponent] != nil {
                        version.isResolved = true
                    }
                }
                for url in files where url != keptURL { Self.trash(url, root: root) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !ok { self.onProblem("Something changed since these were shown (a version arrived, or one was edited): nothing was removed.") }
                    self.reload()
                }
            }
        }
    }

    /// A notebook's color, kept on its cover (made where there's none).
    func recolor(_ notebook: String, _ value: String) {
        if let book = self.notebook(notebook), let key = book.cover, let cover = paper(key), !readOnly(cover) {
            change(key, touch: false) { $0.color = value }
            if let index = notebooks.firstIndex(where: { $0.name == book.name }) { notebooks[index].color = value }
            return
        }
        var cover = NoteFile(body: "# About this notebook\n\nWhat \(notebook) is for.")
        cover.cover = true
        cover.color = value
        let text = cover.serialized(), folder = root.appending(path: notebook), root = self.root
        Self.io.async {
            Self.create(text, at: folder.appending(path: NoteShelf.coverName), root: root)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.reload() } }
        }
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
