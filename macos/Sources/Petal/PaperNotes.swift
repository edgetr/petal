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
    /// The file itself (its volume and inode, read with the folder): what an id-less note's path-derived id is
    /// scoped to, since another file can take its path later.
    var instance = ""

    /// What a holder keeps to name this note (NoteShelf.holderKey).
    var holder: String { NoteShelf.holderKey(id: noteID, instance: instance) }

    var key: String { version.map { url.path + "#" + $0 } ?? url.path }
    var id: String { key }
    var noteID: String { file.id }
    /// Where one of its picture links leads, by the words alone (NoteShelf.pictureTarget: inside the notes' root,
    /// never absolute or out by ".."); nil is a broken picture. The disk's check is NoteStore.pictureFile.
    func picture(_ link: String) -> URL? {
        NoteShelf.pictureTarget(link, noteFolder: url.deletingLastPathComponent().path).map { URL(fileURLWithPath: $0) }
    }
}

/// A notebook: a folder of notes with a color (on its cover, "About this notebook").
struct Notebook: Identifiable, Equatable {
    var name: String
    var folder: URL
    var color: String
    var cover: String?
    var count: Int
    /// A Private notebook (`private: true` on its cover): kept from Petal AI, previews, other notebooks' memory and
    /// Petal's own pictures.
    var isPrivate = false
    /// Its view in the Petal Notes window (`view:` on its cover).
    var view: NoteLibrary.View = .grid
    /// Its cover file is there but wasn't read (not downloaded yet, unreadable), or one of its versions wasn't:
    /// Private until it is, and not changed.
    var coverUnread = false
    /// Its folder itself (volume and inode): what a waiting cover change is bound to, never its name.
    var instance = ""
    /// Its privacy isn't known (its folder couldn't be listed, or a cover file wasn't read): counted Private.
    var privacyUnknown = false
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
    /// Each path's current file's note id as shown (NoteShelf.keepSnapshot): checked with its text before any write.
    var ids: [String: String] = [:]
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
    /// Into another notebook (made if it's new): only its Markdown (and copies of a handwritten note's pictures beside it).
    case move(folder: URL)
    /// A picture's bytes, step one: into the note's folder in the notes' Pictures, a file of its own; the Markdown is untouched.
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
    /// An id given to an id-less note, whose write hasn't landed yet.
    var idPending: String?
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
    /// Notes with more than one paper (iCloud conflicts, or an edit kept beside a file changed elsewhere), by paper key:
    /// each paper's whole group (NoteShelf.conflictGroups).
    private(set) var conflicts: [String: [PaperNote]] = [:]
    private(set) var loaded = false
    /// Counts reads of the folder: anything else kept in it (a notebook's canvas) is read again after each.
    private(set) var reads = 0
    /// Cover changes made in memory (a notebook made Private, its view, its color) shown over reads of the folder
    /// until its cover says them; and changes waiting for a cover to be made, downloaded or settled.
    @ObservationIgnored var coverPending: [String: CoverFields] = [:]
    @ObservationIgnored var coverLanding: Set<String> = []
    @ObservationIgnored var coverMaking: Set<String> = []
    /// Notebooks whose canvas edits aren't saved yet (tried again): the canvas says so.
    var canvasUnsaved: Set<String> = []
    /// Canvas edits not saved yet, by their notebook's cover id (journaled: NoteJournal.keepCanvas).
    @ObservationIgnored var canvasWaiting: [String: CanvasEntry] = [:]
    @ObservationIgnored var canvasDone: [String: [@MainActor (NoteCanvas?) -> Void]] = [:]
    @ObservationIgnored var canvasWriting: Set<String> = []
    /// The last read of the folder read every note file (none still downloading or unreadable).
    @ObservationIgnored var readComplete = false
    /// Bumped by every drain: a canvas write's completion from before one touches nothing.
    @ObservationIgnored var canvasGeneration = 0
    @ObservationIgnored var canvasFailures: [String: Int] = [:]
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

    /// Every move to the Trash notes make (never a deletion): one place, so checks on throwaway folders never touch
    /// the person's Trash (they replace it with a plain removal there).
    nonisolated(unsafe) static var toTrash: (URL) -> Bool = { (try? FileManager.default.trashItem(at: $0, resultingItemURL: nil)) != nil }

    /// Until the notes folder is resolved (off the main thread: `rootFolder` may look at iCloud Drive), a path only,
    /// nothing read or written there.
    init(root: URL? = nil) { self.root = root ?? Self.unresolvedRoot }

    nonisolated static var unresolvedRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["PETAL_NOTES"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return Config.supportFolder.appending(path: "Notes")
    }

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
        drainCanvas()
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
                    self.canvasUnsaved = []
                    self.canvasFailures = [:]
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
                        // A newer version held off while its editor has typing not saved: taken once it's saved.
                        if let fresh = read.notes.first(where: { $0.key == paper.key }), fresh.revision != paper.revision { self.deferred.insert(paper.key) }
                    }
                    var merged = NoteShelf.fenced(read: read.notes, memory: self.notes, key: \.key, started: started,
                                                  changed: changed, removed: self.removedAt)
                    // A Safari, Firefox or Zen tab's button is never written: it stays with the note while Petal runs, but
                    // only on an anchor that's unchanged and matches exactly one (NoteShelf.carryTabElements), never by
                    // its position among the note's places.
                    let before = Dictionary(self.notes.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                    for index in merged.indices {
                        guard let old = before[merged[index].key] else { continue }
                        merged[index].file.places = NoteShelf.carryTabElements(from: old.file.places, to: merged[index].file.places)
                    }
                    self.changedAt = self.changedAt.filter { $0.value >= started }
                    self.removedAt = self.removedAt.filter { $0.value >= started }
                    if merged != self.notes { self.notes = merged }
                    if read.notebooks != self.notebooks { self.notebooks = read.notebooks }
                    self.readComplete = read.complete
                    // Ids whose write ended without landing (kept beside as a conflict, a conflict since kept): the
                    // session knows its note by what its file holds now, and nothing waits for an id that won't land.
                    self.reconcileIdentities(read.notes)
                    // A cover id found in two notebook folders (a notebook duplicated in Finder): the later folder's
                    // cover gets its own id, through its session; that notebook is Private until it lands.
                    self.renewDuplicateCovers()
                    self.regroup()
                    // Cover changes waiting are replayed only now, with the conflicts this read found rebuilt: never
                    // onto a cover in conflict.
                    self.settleCovers()
                    self.rebindSessions()
                    self.loaded = true
                    self.reads += 1
                    // Canvas edits waiting go where their notebook is now (renamed), or are rescued (gone).
                    self.pumpAllCanvas()
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
            paper.instance = there.instance
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

    /// Conflicts by paper key (NoteShelf.conflictGroups): papers with one id, and each file with all its iCloud
    /// versions whatever their ids, so every paper of the group shows Keep this one and a keep plan holds it all.
    private func regroup() {
        // Cover files by their notebook folder (whatever their ids), every other note by its id (NoteShelf.conflictKey).
        let groups = NoteShelf.conflictGroups(notes.map { (NoteShelf.conflictKey(id: $0.noteID, path: $0.url.path), $0.url.path) })
        var next: [String: [PaperNote]] = [:]
        for group in groups {
            let papers = group.map { notes[$0] }
            for paper in papers { next[paper.key] = papers }
        }
        if next != conflicts { conflicts = next }
    }

    /// The conflict a paper is in (two papers or more), or nil.
    func conflict(of paper: PaperNote) -> [PaperNote]? { conflicts[paper.key] }

    /// Every notebook and note under `root`, with Inbox (and its cover) made the first time. Files iCloud hasn't
    /// downloaded yet are asked for and read once they arrive (the folder changes then). Symbolic links (a notebook
    /// or note that points elsewhere) are left out. Places whose files moved (their bookmarks) are followed in memory
    /// (`followed`), never written here.
    /// `complete`: every note file there was read (none still downloading from iCloud, none unreadable): only then
    /// can a notebook or cover not found be taken for gone.
    nonisolated static func read(_ root: URL) -> (notes: [PaperNote], notebooks: [Notebook], complete: Bool) {
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
        // Complete only when every listing and every file's details were read: a folder that couldn't be listed, or an
        // entry whose details couldn't be read, is never taken for an empty one (NoteShelf.readComplete).
        var complete = true
        let listed = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        if listed == nil { complete = false }
        let folders = (listed ?? [])
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { complete = false; return false }
                // Petal's pictures (NoteShelf.picturesRoot) are no notebook.
                return values.isDirectory == true && values.isSymbolicLink != true
                    && url.lastPathComponent.compare(NoteShelf.picturesRoot, options: .caseInsensitive) != .orderedSame
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var notes: [PaperNote] = []
        var notebooks: [Notebook] = []
        for folder in folders {
            let name = folder.lastPathComponent
            let inFolder = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            if inFolder == nil { complete = false }
            let files = (inFolder ?? []).filter { $0.pathExtension.lowercased() == "md" }
            var here: [PaperNote] = []
            var coverVersionUnread = false
            // A note saying `cover: true` and `private: true` that isn't cover-named: privacy unknown until resolved.
            var strayPrivate = false
            // Cover files here that weren't read (`NoteLibrary.isCoverName`: the cover, a conflict copy, a version of it):
            // while there's one, or the folder couldn't be listed, its privacy is unknown. Other notes don't count.
            var unreadCovers = 0
            for url in files {
                let coverNamed = NoteLibrary.isCoverName(url.lastPathComponent)
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { complete = false; if coverNamed { unreadCovers += 1 }; continue }
                guard values.isSymbolicLink != true else { continue }
                if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try? fm.startDownloadingUbiquitousItem(at: url)
                    complete = false
                    if coverNamed { unreadCovers += 1 }
                    continue
                }
                let date = values.contentModificationDate ?? Date()
                guard let text = coordinatedRead(url) else { complete = false; if coverNamed { unreadCovers += 1 }; continue }
                // A file with no id of its own is known by where it is under the notes' folder, never its name alone.
                let fallback = NoteShelf.fallbackID(relativePath: NoteShelf.relative(url.path, to: root.path) ?? name + "/" + url.lastPathComponent)
                var paper = PaperNote(file: NoteFile.parse(text, fallbackID: fallback, fallbackDate: date), url: url, notebook: name, revision: text)
                // A cover by its name only (front matter or not); another note's own `cover: true` is kept as written,
                // never taken for one, but with `private: true` it makes the notebook's privacy unknown.
                if NoteLibrary.strayPrivateCover(fileName: url.lastPathComponent, file: paper.file) { strayPrivate = true }
                NoteLibrary.coverFlag(&paper.file, fileName: url.lastPathComponent)
                paper.instance = instance(of: url)
                paper.followed = followBookmarks(&paper.file)
                here.append(paper)
                // The versions iCloud kept from a change made on two Macs at once: each one a paper of its own.
                if values.ubiquitousItemHasUnresolvedConflicts == true {
                    for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                        guard let text = try? String(contentsOf: version.url, encoding: .utf8) else {
                            // A version not read: the notebook's cover (and so its privacy) isn't known until it is.
                            if coverNamed { coverVersionUnread = true; unreadCovers += 1 }
                            complete = false
                            continue
                        }
                        var paper = PaperNote(file: NoteFile.parse(text, fallbackID: fallback, fallbackDate: version.modificationDate ?? date), url: url,
                                              notebook: name, revision: text)
                        paper.version = version.url.lastPathComponent
                        // The cover's own versions are the cover too, front matter or not: its privacy counts across all.
                        if NoteLibrary.strayPrivateCover(fileName: url.lastPathComponent, file: paper.file) { strayPrivate = true }
                        NoteLibrary.coverFlag(&paper.file, fileName: url.lastPathComponent)
                        here.append(paper)
                    }
                }
            }
            here.sort { a, b in
                if a.file.cover != b.file.cover { return a.file.cover }
                return a.file.modified > b.file.modified
            }
            let cover = here.first { NoteLibrary.isCanonicalCover($0.url.lastPathComponent) && $0.version == nil }
                ?? here.first { $0.file.cover && $0.version == nil } ?? here.first { $0.file.cover }
            // Ready to be written: the cover file itself and every version of it read (its conflicts are the store's
            // to see). Kept apart from privacy: other notes still downloading never hold a cover's write back.
            let coverFile = folder.appending(path: NoteShelf.coverName)
            let coverUnread = NoteLibrary.coverUnknown(fileThere: fm.fileExists(atPath: coverFile.path),
                                                       fileRead: here.contains { NoteLibrary.isCanonicalCover($0.url.lastPathComponent) && $0.version == nil },
                                                       versionsUnread: coverVersionUnread)
            // Privacy unknown (so Private) while the folder couldn't be listed or any cover file wasn't read.
            let privacyUnknown = coverUnread || strayPrivate || NoteLibrary.notebookUnknown(listed: inFolder != nil, unreadCovers: unreadCovers)
            notebooks.append(Notebook(name: name, folder: folder, color: cover?.file.color ?? "", cover: cover?.key,
                                      count: here.filter { !$0.file.cover }.count,
                                      isPrivate: NoteLibrary.privateNotebook(covers: here.filter { $0.file.cover }.map(\.file), unread: privacyUnknown),
                                      view: cover.map { NoteContract.view($0.file) } ?? .grid, coverUnread: coverUnread, instance: instance(of: folder),
                                      privacyUnknown: privacyUnknown))
            notes += here
        }
        return (notes, notebooks, complete)
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

    /// A file's own identity on this Mac: its volume and inode ("dev:ino"); empty when it can't be read.
    nonisolated static func instance(of url: URL) -> String {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return "" }
        return "\(info.st_dev):\(info.st_ino)"
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

    /// The one rule for a picture link, wherever it's read or written (the editor, the read-only paper, journal
    /// recovery, rescue): resolved from the note's folder and standardized (NoteShelf.pictureTarget), inside `root`
    /// (else the folder above the note's notebook), and no symbolic link on the way (`safe`). Nil: never read or
    /// written; a broken picture shows instead. Off the main thread (it looks at the disk).
    nonisolated static func pictureFile(_ link: String, noteFolder: URL, root: URL? = nil) -> URL? {
        let base = root ?? noteFolder.deletingLastPathComponent()
        // The folder and the root however each is spelled (/var is /private/var): the link must stay inside the
        // root in one consistent spelling; `safe` then checks every part for a symbolic link.
        let real = { (path: String) in realpath(path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? path }
        for folder in [noteFolder.path, real(noteFolder.path)] {
            for rootPath in [base.path, real(base.path)] {
                guard let path = NoteShelf.pictureTarget(link, noteFolder: folder, root: rootPath) else { continue }
                let url = URL(fileURLWithPath: path)
                return safe(url, root: base) ? url : nil
            }
        }
        return nil
    }

    /// A journal's picture bytes put back exactly where its saved text's links point, whatever layout wrote them (an
    /// older `pictures-….assets/p.png` too), each place checked by `pictureFile`; bytes no link names go to the
    /// note's own folder in Pictures. One already there counts only with the same bytes. True once all are there.
    nonisolated static func restorePictures(_ pictures: [NotePictureBytes], text: String, noteFile: URL, noteID: String, root: URL) -> Bool {
        guard !pictures.isEmpty else { return true }
        let fm = FileManager.default
        let folder = noteFile.deletingLastPathComponent()
        let links = NoteShelf.referencedPictures(text)
        for picture in pictures {
            let named = links.filter { ($0 as NSString).lastPathComponent == picture.name }
            // A link that leads out of the notes' root (or through a symbolic link) is never written to: those
            // bytes go to the note's own folder in Pictures instead, so nothing is lost.
            let allowed = named.filter { pictureFile($0, noteFolder: folder, root: root) != nil }
            for link in allowed.isEmpty ? [NoteShelf.pictureLink(id: noteID, name: picture.name)] : allowed {
                guard let into = pictureFile(link, noteFolder: folder, root: root) else { return false }
                if fm.fileExists(atPath: into.path) {
                    guard NoteShelf.acceptExisting(existing: try? Data(contentsOf: into), wanted: picture.data) else { return false }
                    continue
                }
                try? fm.createDirectory(at: into.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard (try? picture.data.write(to: into, options: .withoutOverwriting)) != nil else { return false }
            }
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
            // The file already says exactly this (another Mac made the same change, as two renewing one cover's id
            // at once do): landed, whatever id the session expected; nothing is written and nothing kept beside it.
            if NoteShelf.alreadyLanded(disk: disk, text: text) { outcome = .written; return }
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
        // Named from the copy's own redacted title, never the file it's beside (that name may not be Petal's); a cover's
        // copy keeps the cover's name, so it's still a cover (NoteShelf.copyStem).
        let stem = NoteShelf.copyStem(original: original.lastPathComponent, title: safeStem(for: text, fallback: plainStem))
        for _ in 0..<20 {
            if let live, !live() { return .cancelled }
            let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
            let copy = folder.appending(path: NoteShelf.conflictName(stem, taken: taken))
            if create(text, at: copy, root: root, live: live) { return .keptBoth(copy) }
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

    /// A notebook's folder, made where it's missing: only inside the notes' root, through no symbolic link, checked
    /// again once it's there. Off the main thread (the file queue).
    nonisolated static func makeFolder(_ folder: URL, root: URL) -> Bool {
        guard safe(folder, root: root) else { return false }
        var directory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory) && directory.boolValue && safe(folder, root: root)
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
            if create(text, at: url, root: root, live: live) { return url }
            tried.insert(name.lowercased())
        }
        return nil
    }

    /// Moves a file to the Trash, only inside the notes' folder. Off the main thread.
    @discardableResult
    nonisolated static func trash(_ url: URL, root: URL) -> Bool {
        guard safe(url, root: root) else { return false }
        return toTrash(url)
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
                // A cover: its notebook's folder made first, in this same step (contained, through no link), then
                // the cover only there; one already there is the cover (never a second).
                guard makeFolder(exact.deletingLastPathComponent(), root: root),
                      create(text, at: exact, root: root) || FileManager.default.fileExists(atPath: exact.path) else { return NoteWorkResult(outcome: .failed) }
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
            if outcome == .written {
                state.revision = text
                // An id-less note given its id by this write: known by that id from now on.
                // Known by the id in the text it wrote from now on (an id-less note given one, a duplicated cover given
                // its own).
                state.noteID = noteID(of: text, at: state.url, root: root)
            }
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
            let written = writePictures(pictures, noteID: noteID, root: root)
            guard written.count == pictures.count else { return NoteWorkResult(outcome: .failed, url: state.url) }
            return NoteWorkResult(outcome: .written, url: state.url, pictures: written)
        case .trash(let revision):
            // Only while it still says what Petal last saw there, checked inside the coordinated trash.
            let url = state.url, noteID = state.noteID
            trash(state.url, root: root) { disk in
                let found: String? = if case .text(let text) = disk { Self.noteID(of: text, at: url, root: root) } else { nil }
                return NoteShelf.mayTrashFile(disk, foundID: found, expected: noteID, texts: [revision, state.revision])
            }
            return NoteWorkResult(outcome: .written, url: state.url)
        case .keep(let plan):
            return NoteWorkResult(outcome: keep(plan, root: root) ? .written : .failed, url: state.url)
        }
    }

    /// Step one of a picture: its bytes into its note's folder in the notes' Pictures (NoteShelf.pictureFolder), under
    /// the name chosen when it was accepted. The same picture written again is the same file (a retry, a drain).
    /// Never the Markdown. Off the main thread.
    nonisolated static func writePictures(_ pictures: [NotePictureBytes], noteID: String, root: URL) -> [(path: String, file: URL, caption: String)] {
        let folder = root.appending(path: NoteShelf.pictureFolder(id: noteID))
        guard safe(folder, root: root) else { return [] }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [(path: String, file: URL, caption: String)] = []
        for picture in pictures {
            let file = folder.appending(path: picture.name)
            guard safe(file, root: root) else { return written }
            if !FileManager.default.fileExists(atPath: file.path) {
                guard (try? picture.data.write(to: file, options: .withoutOverwriting)) != nil else { return written }
            } else if !NoteShelf.acceptExisting(existing: try? Data(contentsOf: file), wanted: picture.data) {
                // Another picture by that name: never taken for this one (and never written over).
                return written
            }
            written.append((NoteShelf.pictureLink(id: noteID, name: picture.name), file, picture.caption))
        }
        return written
    }

    /// Moves a file to the Trash inside one coordinated step, only while `still` says yes to what it holds then.
    @discardableResult
    /// What's there is told apart: nothing, a file that can't be read (never taken for nothing), or its text.
    nonisolated static func trash(_ url: URL, root: URL, still: (NoteShelf.Disk) -> Bool) -> Bool {
        guard safe(url, root: root) else { return false }
        var done = false
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &error) { url in
            let disk: NoteShelf.Disk
            if !FileManager.default.fileExists(atPath: url.path) { disk = .missing }
            else if let text = try? String(contentsOf: url, encoding: .utf8) { disk = .text(text) }
            else { disk = .unreadable }
            guard disk != .missing, still(disk) else { return }
            done = toTrash(url)
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
            let shownID = plan.ids[plan.kept.path]
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: plan.kept, options: [], error: &error) { url in
                let disk = try? String(contentsOf: url, encoding: .utf8)
                // Only over the current file exactly as shown, and still that note (NoteShelf.keepWrite).
                guard NoteShelf.keepWrite(disk: disk, shown: shown, diskID: disk.map { Self.noteID(of: $0, at: url, root: root) }, shownID: shownID) else { return }
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
            trash(url, root: root) { disk in if case .text(let text) = disk { text == shown } else { false } }
        }
        return true
    }

    /// Moves a note's file into `folder`, under the first name free there on disk, never over a file. Petal's own
    /// pictures stay where they are (the notes' Pictures, linked the same from every notebook). Pictures a
    /// handwritten note links beside it (`Trip.assets/photo.png`) are copied to the same place where it lands, so
    /// its links hold, and never deleted where they were: a duplicate at worst, never a broken link. A different
    /// picture already at that place refuses the move. Off the main thread.
    nonisolated static func move(_ from: URL, noteID: String, into folder: URL, root: URL, live: (@Sendable () -> Bool)? = nil) -> URL? {
        guard safe(from, root: root), safe(folder, root: root) else { return nil }
        let going = { live?() ?? true }   // a tool's asker, checked before each step
        let fm = FileManager.default
        // The file must be this note, before anything is copied and again inside the coordinated move.
        let isNote = { (url: URL) in
            NoteShelf.stillNote(found: (try? String(contentsOf: url, encoding: .utf8)).map { Self.noteID(of: $0, at: url, root: root) },
                                expected: noteID, missing: false)
        }
        guard isNote(from), let text = try? String(contentsOf: from, encoding: .utf8) else { return nil }
        // The folder it's in already (the same folder by the file system's identity, whatever its name's case or
        // spelling): nothing to do.
        if NoteShelf.sameItem(instance(of: from.deletingLastPathComponent()), instance(of: folder)) { return from }
        // Its handwritten pictures, all decided before anything is copied: copy (none there), already there (the
        // same bytes), or stop (another picture there: never over it, and the move is refused).
        let source = from.deletingLastPathComponent()
        var copies: [(from: URL, to: URL)] = []
        for path in NoteShelf.carried(NoteShelf.referencedPictures(text)) {
            guard let picturePath = NoteShelf.resolvedLink(path, from: source.path), NoteShelf.within(picturePath, source.path) != nil,
                  case let picture = URL(fileURLWithPath: picturePath), safe(picture, root: root), fm.fileExists(atPath: picture.path) else { continue }
            guard let intoPath = NoteShelf.resolvedLink(path, from: folder.path), NoteShelf.within(intoPath, folder.path) != nil,
                  case let into = URL(fileURLWithPath: intoPath), safe(into, root: root) else { return nil }
            // The very same file (by identity): nothing to carry.
            if NoteShelf.sameItem(instance(of: picture), instance(of: into)) { continue }
            let there = fm.fileExists(atPath: into.path)
            let bytes = there ? (try? Data(contentsOf: picture)) : nil
            switch NoteShelf.carry(destinationExists: there, same: there && bytes != nil && (try? Data(contentsOf: into)) == bytes) {
            case .already: continue
            case .stop: return nil
            case .copy: copies.append((picture, into))
            }
        }
        guard going() else { return nil }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Copied (never moved), each read back. One there by now (two links spelled in different cases on a
        // volume that doesn't tell them apart, or a picture that arrived meanwhile) counts only with the same bytes;
        // anything else refuses the move, and the copies made stay (a duplicate is fine).
        for copy in copies {
            guard going(), let wanted = try? Data(contentsOf: copy.from) else { return nil }
            if fm.fileExists(atPath: copy.to.path) {
                guard NoteShelf.acceptExisting(existing: try? Data(contentsOf: copy.to), wanted: wanted) else { return nil }
                continue
            }
            try? fm.createDirectory(at: copy.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: copy.from, to: copy.to)) == nil || (try? Data(contentsOf: copy.to)) != wanted { return nil }
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
        // A flush kept beside the file (the note changed elsewhere: a conflict copy now shares its pictures): a move
        // queued after it stops, said on the paper; it can be moved again once the conflict is settled.
        if case .write = item.work, case .keptBoth = result.outcome, NoteShelf.stopMove(afterFlush: true),
           let next = session.pending.first, case .move = next.work, !session.running {
            session.pending.removeFirst()
            for done in next.done { done(.failed) }
            onProblem("This note changed in two places at once, so it wasn't moved: keep one, then move it again.")
        }
        // An id write that failed before and landed on a retry: lasting now.
        if case .write = item.work, result.outcome == .written, let id = session.idPending {
            session.idPending = nil
            idWritten(id, landed: true)
        }
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
                // Their files are in: the bytes held for them in memory can go (NotePictures.written).
                let folder = root.appending(path: NoteShelf.pictureFolder(id: noteID))
                NotificationCenter.default.post(name: Self.picturesWritten, object: nil, userInfo: ["paths": pictures.map { folder.appending(path: $0.name).path }])
            } else {
                setAside(session.key, pictures)
            }
        }
        // A write that landed without the references of pictures being removed (Remove): their recovery bytes go
        // now, never before (in memory, the journal, and NotePictures' pending writes).
        if case .write(let text, _) = item.work, let removing = retiring[noteID], !removing.isEmpty {
            let landed: Bool = switch result.outcome { case .written, .keptBoth: true; default: false }
            if landed { finishRetiring(noteID, text: text) }
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

    /// Remove, the paper's button: the pictures that couldn't be saved leave the note. Refused on a read-only
    /// paper. Off the paper at once; their recovery bytes (in memory, the journal, NotePictures' pending writes) go
    /// only once a write of the note without their references has landed (`finishRetiring`). With an editor open,
    /// the removal is an edit there, saved like any typing (the desk's); else a based write here (`write: true`).
    /// Their names, or nil when nothing was done.
    @discardableResult
    func retirePictures(_ key: String, write: Bool) -> Set<String>? {
        guard let paper = paper(key), !readOnly(paper), let pictures = pictureTrouble[key], !pictures.isEmpty else { return nil }
        let names = Set(pictures.map(\.name))
        pictureTrouble[key] = nil
        retiring[paper.noteID, default: []].formUnion(names)
        if write {
            change(key) { file in
                file.body = NoteBlock.blocks(file.body).filter { block in
                    if case .image(let path, _) = block { return !names.contains((path as NSString).lastPathComponent) }
                    return true
                }.map(\.markdown).joined(separator: "\n")
            }
        }
        return names
    }

    /// A note's paper as it is now, found by its id (the editor keeps its note's id current through moves, renames and
    /// an id given): where an undo or a completion acts, never a key captured before a move or a rename.
    func current(_ noteID: String) -> PaperNote? { notes.first { $0.noteID == noteID && $0.version == nil } }

    /// The pictures set aside on a paper right now (their bytes), for Remove's undo.
    func asideBytes(_ key: String) -> [NotePictureBytes] { pictureTrouble[key] ?? [] }

    /// Undo of Remove: the removed pictures' bytes accepted again under their own names (journaled with the next
    /// snapshot, written in the background), no longer being retired.
    func reaccept(_ key: String, _ pictures: [NotePictureBytes]) {
        guard !pictures.isEmpty, let paper = paper(key), !readOnly(paper), let session = session(for: key) else { return }
        for picture in pictures { pendingPictures[paper.noteID, default: [:]][picture.name] = picture.data }
        retiring[paper.noteID]?.subtract(pictures.map(\.name))
        enqueue(session, .pictureBytes(pictures, noteID: paper.noteID), done: nil)
    }

    /// Redo of Remove: those pictures being removed again (their bytes go once a write without them lands).
    func retireAgain(_ key: String, names: Set<String>) {
        guard let paper = paper(key) else { return }
        pictureTrouble[key] = pictureTrouble[key]?.filter { !names.contains($0.name) }
        retiring[paper.noteID, default: []].formUnion(names)
    }

    /// Kept for the paper's Remove without an editor (a based write).
    @discardableResult
    func dropPictures(_ key: String) -> Bool { retirePictures(key, write: true) != nil }

    /// Pictures being removed, by note id: their recovery bytes go once a write without their references lands.
    @ObservationIgnored private var retiring: [String: Set<String>] = [:]

    private func finishRetiring(_ noteID: String, text: String) {
        guard let removing = retiring[noteID] else { return }
        let referenced = Set(NoteShelf.referencedPictures(text).map { ($0 as NSString).lastPathComponent })
        let gone = removing.subtracting(referenced)
        guard !gone.isEmpty else { return }
        retiring[noteID] = removing.subtracting(gone)
        if retiring[noteID]?.isEmpty == true { retiring[noteID] = nil }
        for name in gone { pendingPictures[noteID]?[name] = nil }
        NoteJournal.queue.async { NoteJournal.picturesSaved(noteID: noteID, names: gone) }
        let folder = root.appending(path: NoteShelf.pictureFolder(id: noteID))
        NotificationCenter.default.post(name: Self.picturesRetired, object: nil, userInfo: ["paths": gone.map { folder.appending(path: $0).path }])
    }

    /// Whether a picture's recovery bytes are still kept for a note (for checks).
    func keepsBytes(_ noteID: String, _ name: String) -> Bool { pendingPictures[noteID]?[name] != nil }

    /// A picture's bytes Petal still holds (not stored in its folder yet, or set aside after a failed save).
    func heldPicture(_ noteID: String, _ name: String) -> Data? {
        if let data = pendingPictures[noteID]?[name] { return data }
        return notes.filter { $0.noteID == noteID }.lazy.compactMap { self.pictureTrouble[$0.key]?.first { $0.name == name }?.data }.first
    }

    /// Pictures set aside on a paper (their bytes couldn't be written): said with Try again and Remove.
    func setAside(_ key: String, _ pictures: [NotePictureBytes]) { pictureTrouble[key, default: []] += pictures }

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
        drainCanvas()
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
            var keptBeside = false
            for item in job.items {
                // A move after a flush that was kept beside the file: not done (NoteShelf.stopMove).
                if case .move = item.work, NoteShelf.stopMove(afterFlush: keptBeside) { keptBeside = false; continue }
                // Done by the queue already (its answer never reached the main thread): taken as it was. Else done
                // here, once (a failed one again).
                var result = NoteDisk.results[item.id]
                if result == nil || result?.outcome == .failed { result = NoteDisk.once(item, session: job.session, root: root) }
                NoteDisk.results[item.id] = nil
                guard let result else { continue }
                switch (item.work, result.outcome) {
                case (.write(let text, _), .written), (.write(let text, _), .keptBoth), (.create(let text, _, _, _), .written):
                    landed.append((text, false))
                    if case .keptBoth = result.outcome { keptBeside = true } else { keptBeside = false }
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
                        let beside = NoteDisk.states[job.session]?.url.deletingLastPathComponent()
                        if rescue(text, noteID: noteID, pictures: referenced, from: beside) { landed.append((text, false)) }
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
    /// pictures laid out beside it as in the notes' folder, so its references hold. True once
    /// the text and every picture are written there.
    @discardableResult
    nonisolated static func rescue(_ text: String, noteID: String, pictures: [NotePictureBytes], from noteFolder: URL? = nil) -> Bool {
        rescued(text, noteID: noteID, pictures: pictures, from: noteFolder) != nil
    }

    /// A picture's bytes, read the way iCloud Drive wants (it may bring the file down first).
    nonisolated private static func picture(at url: URL) -> Data? {
        var data: Data?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { data = try? Data(contentsOf: $0) }
        return data
    }

    /// The same, saying the file it wrote. Every picture its text references goes with it, laid out as in the notes'
    /// folder (the note in "Note", Petal's pictures in "Pictures/<hash>" beside it, a handwritten one beside the
    /// note), so its links hold: bytes still in memory (`pictures`), else copied from where the note's links lead
    /// (`noteFolder`: the folder its file is in, inside the notes' folder). Complete only once all of them are there
    /// (NoteShelf.rescueComplete); else nothing is written and the journal keeps it.
    nonisolated static func rescued(_ text: String, noteID: String, pictures: [NotePictureBytes], from noteFolder: URL? = nil) -> URL? {
        let fm = FileManager.default
        // A folder of its own (NoteShelf.rescueFolder): another note's pictures are never met there. The note sits a
        // level down, as in a notebook, so "../Pictures/..." means the same there.
        let folder = Config.supportFolder.appending(path: "Unsaved notes").appending(path: NoteShelf.rescueFolder(noteID: noteID, at: Date()))
        let noteDir = folder.appending(path: "Note")
        try? fm.createDirectory(at: noteDir, withIntermediateDirectories: true)
        // Every picture the text references, there too: bytes still in memory, else copied from where its link
        // leads now; one already there counts only when it's the same bytes.
        let referenced = NoteShelf.referencedPictures(text)
        var present = Set<String>()
        for path in referenced {
            // Both ends by the one rule (pictureFile): the copy inside the rescue's folder, the source inside the
            // notes' root, never through a symbolic link.
            // A link that leads out of where its note is shows a broken picture anywhere: nothing to carry for it.
            guard let into = pictureFile(path, noteFolder: noteDir, root: folder) else { present.insert(path); continue }
            let wanted: Data?
            if let bytes = pictures.first(where: { $0.name == (path as NSString).lastPathComponent }) { wanted = bytes.data }
            else if let noteFolder, let source = pictureFile(path, noteFolder: noteFolder) {
                wanted = picture(at: source)
            } else { wanted = nil }
            guard let wanted else { continue }
            if fm.fileExists(atPath: into.path) {
                if NoteShelf.acceptExisting(existing: try? Data(contentsOf: into), wanted: wanted) { present.insert(path) }
                continue
            }
            try? fm.createDirectory(at: into.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? wanted.write(to: into, options: .withoutOverwriting)) != nil { present.insert(path) }
        }
        // Bytes it carries that its text doesn't (yet) reference: kept with it too, where its links would lead.
        if !pictures.isEmpty {
            let own = folder.appending(path: NoteShelf.pictureFolder(id: noteID))
            try? fm.createDirectory(at: own, withIntermediateDirectories: true)
            for picture in pictures where !fm.fileExists(atPath: own.appending(path: picture.name).path) {
                if (try? picture.data.write(to: own.appending(path: picture.name), options: .withoutOverwriting)) == nil { return nil }
            }
        }
        guard NoteShelf.rescueComplete(referenced: referenced, present: present) else { return nil }
        let stem = safeStem(for: text, fallback: plainStem)
        for n in 0..<100 {
            let file = noteDir.appending(path: (n == 0 ? stem : "\(stem) \(n + 1)") + ".md")
            if (try? Data(text.utf8).write(to: file, options: .withoutOverwriting)) != nil { return file }
        }
        return nil
    }

    // MARK: Watching

    @ObservationIgnored private var watched: URL?
    /// Files under the notes' folder appeared or changed (userInfo "paths"): what makes a missing picture show.
    static let filesChanged = Notification.Name("petal.notesFilesChanged")
    /// Pictures' files written (userInfo "paths"): their bytes needn't stay in memory for them.
    static let picturesWritten = Notification.Name("petal.notesPicturesWritten")
    /// Pictures removed for good (userInfo "paths"): their pending writes are retired.
    static let picturesRetired = Notification.Name("petal.notesPicturesRetired")

    private func watch() {
        guard !Headless.on, !switching else { return }
        if stream != nil, watched == root { return }
        stopWatching()
        watched = root
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let store = Unmanaged<NoteStore>.fromOpaque(info).takeUnretainedValue()
            // The files that appeared or changed (C strings, the stream's default): pictures among them are said to
            // the editors showing them (NotePictures), which read them again.
            let list = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let changed = (0..<count).map { String(cString: list[$0]) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    store.changed()
                    NotificationCenter.default.post(name: NoteStore.filesChanged, object: nil, userInfo: ["paths": changed])
                }
            }
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
    func readOnly(_ paper: PaperNote) -> Bool { paper.version != nil || (conflicts[paper.key]?.count ?? 0) > 1 }

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
        guard !switching, let before = paper(key), !readOnly(before) else { return nil }
        if let expect, before.revision != expect { return nil }
        // An id-less note gets its id first (written through its session); an edit made on the file as it was is
        // made on it as it is once the id is in.
        ensureID(key)
        guard var paper = paper(key), let session = session(for: key) else { return nil }
        let since = base.map { $0 == before.revision ? paper.revision : $0 } ?? paper.revision
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

    /// Notes whose newer version was held off while their editor had typing not saved yet.
    @ObservationIgnored private var deferred: Set<String> = []

    /// Its editor's typing saved: a version held off meanwhile is taken now (the folder read again).
    func takeDeferred(_ key: String) {
        if deferred.remove(key) != nil { reload() }
    }

    /// A note with no id of its own (known by its path) gets one before Petal writes, moves or sticks it: a new id in
    /// its front matter, written through its session (after whatever is waiting there), and taken at once by every
    /// owner: the paper, the session, what waits for it in memory, and the desk's records (`onIdentity`). The
    /// journal's snapshot moves to the new id. Nothing for a note that has one.
    ///
    /// `then`: the note's id once it's in its file (now, for a note that has one), or nil when it couldn't be
    /// written (fail closed: nothing lasting is kept for it).
    func ensureID(_ key: String, then: (@MainActor (String?) -> Void)? = nil) {
        guard let index = notes.firstIndex(where: { $0.key == key }), notes[index].version == nil else { then?(nil); return }
        let current = notes[index].noteID
        if !NoteShelf.needsID(current) {
            // Its id being written still: told once it's in.
            if pendingIDs.contains(current), let then { idWaiters[current, default: []].append(then) } else { then?(current) }
            return
        }
        guard !readOnly(notes[index]), let session = session(for: key) else { then?(nil); return }
        var paper = notes[index]
        let old = paper.noteID
        let base = paper.revision
        paper.file.id = UUID().uuidString
        let new = paper.noteID
        let text = paper.file.serialized()
        paper.revision = text
        notes[index] = paper
        session.noteID = new
        if let bytes = pendingPictures.removeValue(forKey: old) { pendingPictures[new] = bytes }
        if let loading = importsLoading.removeValue(forKey: old) { importsLoading[new] = loading }
        if let trouble = importTrouble.removeValue(forKey: old) { importTrouble[new] = trouble }
        touch(key)
        // Followed only from this very file: its path's id is retired (another file there later is another note).
        let oldHolder = NoteShelf.holderKey(id: old, instance: paper.instance)
        aliases[oldHolder] = new
        pendingIDs.insert(new)
        session.idPending = new
        if let then { idWaiters[new, default: []].append(then) }
        onIdentity(old, oldHolder, new)
        enqueue(session, .write(text: text, base: base), done: { outcome in self.idWritten(new, landed: outcome == .written) })
        snapshot(paper, text: text, session: session)
        NoteJournal.queue.async { NoteJournal.forget(noteID: old) }
    }

    /// A note given its own id (`ensureID`): old id, new id. Published to every holder (the desk's records and
    /// handles) and kept in `aliases`, which the editor, a paste being read and a tool's request follow.
    /// (old id, old holder key, new id).
    @ObservationIgnored var onIdentity: @MainActor (String, String, String) -> Void = { _, _, _ in }

    /// Ids given to id-less notes whose write hasn't landed yet: nothing lasting is kept by them until it has.
    @ObservationIgnored private(set) var pendingIDs: Set<String> = []
    @ObservationIgnored private var idWaiters: [String: [@MainActor (String?) -> Void]] = [:]

    /// A note's id is in its file now (its own, given by `ensureID`).
    @ObservationIgnored var onIDLanded: @MainActor (String) -> Void = { _ in }

    /// An id write ended: landed, it's lasting (and said); not, those waiting are told nil (a failed write is still
    /// tried again, and said when it lands).
    private func idWritten(_ id: String, landed: Bool) {
        if landed, pendingIDs.remove(id) != nil { onIDLanded(id) }
        for waiter in idWaiters.removeValue(forKey: id) ?? [] { waiter(landed ? id : nil) }
    }

    /// Ids notes had before they were given their own: old → new, for this run.
    @ObservationIgnored private(set) var aliases: [String: String] = [:]

    /// A note's id as it is now, from the id and file instance a holder kept (NoteShelf.current).
    func currentID(_ id: String, instance: String) -> String { NoteShelf.current(id, instance: instance, aliases: aliases) }

    /// Whether an editor that has `a` from file `instance` still has the note `b`.
    func sameNote(_ a: String, instance: String, _ b: String) -> Bool { NoteShelf.editorKeeps(typedIn: a, instance: instance, paper: b, aliases: aliases) }

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
        // A notebook already there by another case ("inbox" for Inbox) is that notebook, by its own name.
        let folderName = NoteShelf.canonicalNotebook(NoteShelf.folderName(name), existing: notebooks.map(\.name))
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
        // The notebook as it exists, whatever its case ("inbox" is Inbox): the same one, nothing to do.
        let name = NoteShelf.canonicalNotebook(NoteShelf.folderName(notebook), existing: notebooks.map(\.name))
        guard name.compare(paper.notebook, options: .caseInsensitive) != .orderedSame else { return done(paper) }
        guard !switching, !readOnly(paper), let session = session(for: key) else { return done(nil) }
        ensureNotebook(name, color: "")
        // Its id in its file first (an id-less note's is its path, which the move changes).
        ensureID(key)
        enqueue(session, .move(folder: root.appending(path: name)), live: live) { outcome in
            done(outcome == .written ? self.paper(session.key) : nil)
        }
    }

    /// Pictures pasted or dropped on a note, their bytes already read and decoded (never from their source here):
    /// accepted now, in memory, their bytes written to the note's folder in the notes' Pictures through its session (after whatever is waiting,
    /// a move too). Returns each one's reference (as the note writes it), for the editor to put in as ordinary text;
    /// nil when the note can't take them.
    func acceptPictures(_ key: String, _ items: [(ext: String, data: Data, caption: String)]) -> [(path: String, file: URL, caption: String)]? {
        guard !switching, let before = paper(key), !readOnly(before), !items.isEmpty else { return nil }
        // The pictures' folder is named for the note's id: an id-less note gets its own first.
        ensureID(key)
        guard let paper = paper(key), let session = session(for: key) else { return nil }
        let pictures = items.map { NotePictureBytes(name: "picture-\(UUID().uuidString.prefix(8).lowercased()).\($0.ext)", data: $0.data, caption: $0.caption) }
        for picture in pictures { pendingPictures[paper.noteID, default: [:]][picture.name] = picture.data }
        enqueue(session, .pictureBytes(pictures, noteID: paper.noteID), done: nil)
        return pictures.map { (NoteShelf.pictureLink(id: paper.noteID, name: $0.name),
                               root.appending(path: NoteShelf.pictureFolder(id: paper.noteID)).appending(path: $0.name), $0.caption) }
    }

    /// Pictures pasted or dropped and still being read (a file iCloud is downloading), by note id and paste: what
    /// keeps a new note from being put away as empty, and what each snapshot carries so a quit loses none of them.
    @ObservationIgnored private var importsLoading: [String: [Int: [NoteJournal.Import]]] = [:]

    /// A paste or drop on `key`, recorded before anything is read: its sources go into the journal at once. Nil when
    /// the note can't take pictures now.
    func beginImport(_ key: String, _ items: NoteImport) -> (token: Int, sources: [NoteJournal.Import])? {
        // Only a note whose own id is in its file: a paste is journaled by it (never by a path's id).
        guard !switching, !draining, let paper = paper(key), !readOnly(paper), NoteShelf.lasting(paper.noteID, pending: pendingIDs),
              let session = session(for: key) else { return nil }
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
                var landed: String?
                var landedAt: URL?
                var waiting: [NoteJournal.Import] = entry?.imports?.filter { $0.token == token } ?? []
                if var entry {
                    // Its text already in its note (the folder switch's drain wrote it): the base its lines go on.
                    let found = NoteStore.read(root).notes.filter { $0.noteID == noteID && $0.version == nil }
                    if found.count == 1, NoteStore.coordinatedRead(found[0].url) == entry.text { entry.landed = true }
                    (stored, waiting, landed, landedAt) = NoteJournal.putIn(entry, token: token, root: root)
                }
                // Out of the journal: what went in; a file not read yet stays for its own next try. Landed in the note,
                // the snapshot's text advances to it (never a newer one's), so that try builds on it.
                let keeping = waiting, used = entry?.text, now = landed, at = landedAt
                if stored {
                    NoteJournal.queue.async {
                        if let used, let now { NoteJournal.advance(noteID: noteID, from: used, to: now, at: at, token: token, keeping: keeping) }
                        else { NoteJournal.importsDone(noteID: noteID, token: token, keeping: keeping) }
                    }
                }
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

    /// How many pictures pasted or dropped on a note are still being read in.
    func importingCount(_ key: String) -> Int { paper(key).map { (importsLoading[$0.noteID] ?? [:]).values.reduce(0) { $0 + $1.count } } ?? 0 }

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
        let shown = conflicts[kept.key] ?? [kept]
        // Always the current file at every path shown (a version's own id may differ from it): its text and id, as
        // last read; one not known, nothing is done.
        var current: [String: (revision: String?, id: String)] = [:]
        for url in Set(shown.map(\.url)) {
            if let file = notes.first(where: { $0.url == url && $0.version == nil }) { current[url.path] = (file.revision, file.noteID) }
        }
        guard let (snapshot, ids) = NoteShelf.keepSnapshot(papers: shown.map { ($0.url.path, $0.version, $0.revision) }, current: current) else {
            return onProblem("Petal couldn't check that note's file as it is now, so nothing was kept or removed. Try again in a moment.")
        }
        // A cover's conflict lands on "About this notebook.md": the kept text written there and read back first, then
        // the others trashed (NoteShelf.keepTarget).
        let target = URL(fileURLWithPath: NoteShelf.keepTarget(chosen: kept.url.path, group: shown.map(\.url.path)))
        let promote = target.path != kept.url.path
        var plan = NoteKeep(snapshot: snapshot, kept: target,
                            keptText: promote ? (kept.revision ?? kept.file.serialized()) : kept.version == nil ? nil : kept.file.serialized(),
                            files: Array(Set(shown.map(\.url))))
        plan.ids = ids
        let key = target.path
        let session = sessionAt(key, noteID: kept.noteID) ?? makeSession(key: key, url: kept.url, noteID: kept.noteID, revision: kept.revision)
        enqueue(session, .keep(plan), done: nil)
    }

    /// A notebook's color, kept on its cover (made where there's none).
    func recolor(_ notebook: String, _ value: String) { setCover(notebook, fields: ["color": value]) }

    /// Something kept on a notebook's cover (its color, `private`, `view`): changed through the cover's session, or,
    /// with no cover yet (a folder made elsewhere), a cover made with it, never over one. `book`: the same change on
    /// the notebook in memory, shown at once.
    func setCover(_ notebook: String, fields: [String: String]) {
        let name = self.notebook(notebook)?.name ?? ensureNotebook(notebook, color: "")
        guard let book = self.notebook(name) else { return }
        // Bound to this root and to the notebook's cover id or folder, never its name.
        // Its cover's id only once it's landed and its own (not one shared with a duplicated notebook): else its folder.
        let landedID = book.cover.flatMap { paper($0) }.map(\.noteID).flatMap { id in
            NoteShelf.lasting(id, pending: pendingIDs) && renewing[name] == nil
                && notes.filter({ $0.noteID == id && $0.version == nil && NoteLibrary.isCanonicalCover($0.url.lastPathComponent) }).count == 1 ? id : nil
        }
        let bound = CoverFields(notebook: name, root: root.path, coverID: landedID ?? "", folderID: book.instance)
        guard !bound.coverID.isEmpty || !bound.folderID.isEmpty else {
            return onProblem("Petal couldn't tell which notebook \(name) is on disk yet, so nothing was changed. Try again in a moment.")
        }
        var pending = coverPending[bound.key] ?? bound
        for (field, value) in fields where CoverFields.names.contains(field) { pending.set(field, value) }
        coverPending[bound.key] = pending
        // Journaled on this Mac at once (a quit before it lands loses nothing), and shown at once.
        NoteJournal.queue.async { NoteJournal.keepCover(pending) }
        showCovers()
        landCover(bound.key)
    }

    /// A notebook's cover made when it has none (a plain one, through a session of its own, never over a file: one
    /// already there is read, not taken for this one); the next read finds whatever cover is there.
    func ensureCover(_ notebook: String) {
        guard let found = self.notebook(notebook), found.cover == nil, !found.coverUnread, !coverMaking.contains(found.name) else { return }
        coverMaking.insert(found.name)
        var cover = NoteFile(body: "# About this notebook\n\nWhat \(found.name) is for.")
        cover.cover = true
        let url = found.folder.appending(path: NoteShelf.coverName)
        let session = makeSession(key: url.path + "#new-cover", url: url, noteID: cover.id, revision: nil)
        enqueue(session, .create(text: cover.serialized(), stem: "About this notebook", folder: found.folder, exact: url)) { _ in
            self.coverMaking.remove(found.name)
            self.reload()
        }
    }

    /// The notebooks as cover changes find them (name, cover id, folder).
    private var coverTargets: [(name: String, coverID: String, folderID: String)] {
        notebooks.map { book in (book.name, book.cover.flatMap { paper($0) }.map(\.noteID) ?? "", book.instance) }
    }

    /// The fields waiting under `key`, made on their notebook's cover as it is now through the cover's session (a
    /// cover with no front matter gets its id and front matter first), only in their own root; with no cover, one is
    /// made first; a cover not read yet or in conflict keeps them waiting. Once the write lands, the fields it wrote
    /// leave the journal.
    private func landCover(_ key: String) {
        guard let pending = coverPending[key], !pending.isEmpty, !coverLanding.contains(key), !switching,
              let name = pending.target(root: root.path, notebooks: coverTargets), let found = notebook(name) else { return }
        if found.cover == nil, !found.coverUnread { return ensureCover(name) }
        // Never onto a cover not read, or in conflict (its versions read only until one is kept).
        // Not while its id is being written (a duplicated cover renewed); an id-less cover gets its id through `change`.
        guard !found.coverUnread, renewing[name] == nil, let coverKey = found.cover, let cover = paper(coverKey), !readOnly(cover),
              !pendingIDs.contains(cover.noteID) else { return }
        let wrote = pending.fields
        coverLanding.insert(key)
        let changed = change(coverKey, touch: false, edit: { CoverFields.apply(wrote, to: &$0) }) { outcome in
            self.coverLanding.remove(key)
            guard outcome == .written else { return }
            if let now = self.coverPending[key] {
                let next = now.after(wrote: wrote)
                self.coverPending[key] = next.isEmpty ? nil : next
                NoteJournal.queue.async { NoteJournal.ackCover(now, wrote: wrote) }
            }
            self.landCover(key)
        }
        if changed == nil { coverLanding.remove(key) }
    }

    /// After a read: every idle session still waiting for an id to land checked against its file as read
    /// (NoteShelf.reconcileID): the id there, it's landed; another id there, it won't (its write was kept beside the
    /// file, or a conflict was kept with the other version): dropped, its waiters told, and the session, the files
    /// queue and the paper know the note by the id its file holds.
    private func reconcileIdentities(_ read: [PaperNote]) {
        for session in Array(sessions.values) where !session.busy {
            guard let pending = session.idPending else { continue }
            let onDisk = read.first { $0.key == session.key && $0.version == nil }
            switch NoteShelf.reconcileID(pending: pending, diskID: onDisk?.noteID) {
            case .wait: continue
            case .landed:
                session.idPending = nil
                idWritten(pending, landed: true)
            case .dropped(let id):
                session.idPending = nil
                pendingIDs.remove(pending)
                idWritten(pending, landed: false)
                for (name, renewed) in renewing where renewed == pending { renewing[name] = nil }
                // An id-less note's old path no longer points at an id that never landed.
                aliases = aliases.filter { $0.value != pending }
                session.noteID = id
                let sessionID = session.id, url = URL(fileURLWithPath: session.key), revision = onDisk?.revision
                Self.io.async {
                    NoteDisk.states[sessionID]?.noteID = id
                    NoteDisk.states[sessionID]?.url = url
                    NoteDisk.states[sessionID]?.revision = revision
                }
                if let onDisk, let index = notes.firstIndex(where: { $0.key == session.key && $0.version == nil }) { notes[index] = onDisk }
            }
        }
    }

    /// Notebooks whose cover is being given its own id (a duplicated cover), by name: Private until it lands.
    @ObservationIgnored var renewing: [String: String] = [:]

    /// Covers sharing one id across notebook folders: every folder but the first by name (NoteLibrary.duplicateCovers)
    /// gets a new, deterministic id written into its cover through the cover's session (its front matter only).
    private func renewDuplicateCovers() {
        let covers = notes.filter { $0.version == nil && NoteLibrary.isCanonicalCover($0.url.lastPathComponent) && !NoteShelf.needsID($0.noteID) }
        for (folder, newID) in NoteLibrary.duplicateCovers(covers.map { (id: $0.noteID, folder: $0.notebook) }) where renewing[folder] == nil {
            guard let paper = covers.first(where: { $0.notebook == folder }) else { continue }
            reidentify(paper.key, to: newID)
        }
        markRenewing()
    }

    /// A note given a new id of its own (not an id-less note's first: the old id stays with the other note that has
    /// it, so nothing kept by it moves): written through its session, waited for like any id being written.
    private func reidentify(_ key: String, to new: String) {
        guard !switching, let index = notes.firstIndex(where: { $0.key == key }), notes[index].version == nil, !readOnly(notes[index]),
              let session = session(for: key) else { return }
        var paper = notes[index]
        let base = paper.revision
        paper.file.id = new
        let text = paper.file.serialized()
        paper.revision = text
        notes[index] = paper
        session.noteID = new
        touch(key)
        pendingIDs.insert(new)
        session.idPending = new
        let notebook = paper.notebook
        renewing[notebook] = new
        enqueue(session, .write(text: text, base: base), done: { outcome in
            if self.renewing[notebook] == new { self.renewing[notebook] = nil }
            self.idWritten(new, landed: outcome == .written)
            self.reload()
        })
        snapshot(paper, text: text, session: session)
    }

    /// A notebook whose cover is getting its own id counts as Private (unknown) until it lands.
    private func markRenewing() {
        for name in renewing.keys {
            guard let index = notebooks.firstIndex(where: { $0.name == name }) else { continue }
            notebooks[index].isPrivate = true
            notebooks[index].privacyUnknown = true
        }
    }

    /// Every notebook as shown: what its cover says, with only the fields still waiting for it (in this root) over it;
    /// an unknown cover counts as Private.
    private func showCovers() {
        let targets = coverTargets
        for pending in coverPending.values {
            guard let name = pending.target(root: root.path, notebooks: targets), let index = notebooks.firstIndex(where: { $0.name == name }) else { continue }
            let book = notebooks[index]
            let shown = pending.shown(isPrivate: book.isPrivate, unknown: book.privacyUnknown, color: book.color, view: book.view)
            notebooks[index].isPrivate = shown.isPrivate
            notebooks[index].color = shown.color
            notebooks[index].view = shown.view
        }
        markRenewing()
    }

    /// After a read of the folder (its conflicts rebuilt): what's waiting shown over what the covers say, and landed
    /// where a cover is ready.
    private func settleCovers() {
        showCovers()
        for key in coverPending.keys { landCover(key) }
    }

    /// Cover fields a launch before kept (NoteJournal.coverLeftovers), of every root: waiting again, each only for its
    /// own root, shown at once (Private first).
    /// Returns the entries as they wait now, for the journal (NoteJournal.rejournalCovers).
    @discardableResult
    func recoverCovers(_ entries: [CoverFields]) -> [CoverFields] {
        var out: [CoverFields] = []
        // Each field's newest value wins, across every recovered copy and this session's own changes.
        for entry in entries where !entry.isEmpty {
            let pending = coverPending[entry.key].map { $0.merged(with: entry) } ?? entry
            coverPending[entry.key] = pending
        }
        let keys = Set(entries.map(\.key))
        out = coverPending.filter { keys.contains($0.key) }.map(\.value)
        showCovers()
        if loaded { for key in coverPending.keys { landCover(key) } }
        return out
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

// MARK: - Notebooks as a whole (the Petal Notes window)

extension NoteStore {
    /// The Private notebooks' names.
    /// The Private notebooks' names, and every notebook a note held here is in that the latest read didn't find
    /// (a note kept while it's open or being written, its notebook gone or not read): unknown, so Private.
    var privateBooks: Set<String> {
        NotePrivacy.privateBooks(notebooks: notebooks.map { ($0.name, $0.isPrivate) }, held: notes.map(\.notebook))
    }

    /// A notebook's notes busy now (a write, a move, pictures, a paste on the way): a rename or trash waits for them.
    func notebookBusy(_ name: String) -> Bool {
        let keysHere = Set(notes.filter { NoteLibrary.same($0.notebook, name) }.map(\.key))
        return sessions.values.contains { keysHere.contains($0.key) && $0.busy }
            || notes.contains { NoteLibrary.same($0.notebook, name) && (importsLoading[$0.noteID]?.isEmpty == false) }
    }

    /// Renames a notebook's folder (its notes, cover and canvas go with it), coordinated, on the files' queue, only
    /// while none of its notes has work under way and no other notebook has the name. Its notes are followed to
    /// their new paths by id on the read that follows (`followRenamed`), with their editors, panels and sessions.
    /// `done`: the name it has now, or nil (nothing changed, said why through `onProblem`).
    func renameNotebook(_ old: String, to wanted: String, then done: @escaping @MainActor (String?) -> Void) {
        let name = NoteShelf.folderName(wanted)
        guard !switching, let book = notebook(old), !name.isEmpty else { return done(nil) }
        guard book.name != name else { return done(name) }
        if let other = notebook(name), other.name != book.name {
            onProblem("There's already a notebook called \(other.name).")
            return done(nil)
        }
        guard !notebookBusy(book.name) else {
            onProblem("A note in \(book.name) is still being saved. Try again in a moment.")
            return done(nil)
        }
        let root = self.root, from = book.folder, to = root.appending(path: name)
        // Its notes' sessions (all idle now): pointed at the new folder in the same step as the move, so anything
        // queued for them after it lands there (the read that follows rekeys them for good).
        let prefix = from.standardizedFileURL.path + "/"
        let moving = sessions.values.filter { $0.key.hasPrefix(prefix) }.map { (id: $0.id, url: to.appending(path: String($0.key.dropFirst(prefix.count)))) }
        Self.io.async {
            let moved = Self.moveFolder(from, to: to, root: root)
            if moved { for session in moving { NoteDisk.states[session.id]?.url = session.url } }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard moved else {
                        self.onProblem("Petal couldn't rename \(book.name). Nothing was changed.")
                        return done(nil)
                    }
                    self.reload()
                    done(name)
                }
            }
        }
    }

    /// A notebook to the Trash, all of it (its notes, cover and canvas), never deleted: only while none of its notes
    /// has work under way. Petal's pictures stay where they are (a note trashed leaves its pictures alone).
    func trashNotebook(_ name: String, then done: @escaping @MainActor (Bool) -> Void) {
        guard !switching, let book = notebook(name) else { return done(false) }
        guard !notebookBusy(book.name) else {
            onProblem("A note in \(book.name) is still being saved. Try again in a moment.")
            return done(false)
        }
        let root = self.root, folder = book.folder
        Self.io.async {
            var ok = false
            if Self.safe(folder, root: root), folder.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path {
                var error: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: folder, options: .forDeleting, error: &error) { url in
                    ok = Self.toTrash(url)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok {
                        // Its cover's waiting fields go with it (journal too): the ones bound to its cover or its folder.
                        let target = self.coverTargets.first { $0.name == book.name }
                        for (key, pending) in self.coverPending where pending.target(root: self.root.path, notebooks: target.map { [$0] } ?? []) != nil {
                            self.coverPending[key] = nil
                            var cleared = pending
                            cleared.fields = [:]
                            NoteJournal.queue.async { NoteJournal.keepCover(cleared) }
                        }
                        let gone = self.notes.filter { NoteLibrary.same($0.notebook, book.name) }.map(\.key)
                        for key in gone { self.gone(key) }
                        self.notes.removeAll { NoteLibrary.same($0.notebook, book.name) }
                        self.notebooks.removeAll { $0.name == book.name }
                        self.regroup()
                    } else {
                        self.onProblem("Petal couldn't move \(book.name) to the Trash. Nothing was changed.")
                    }
                    self.reload()
                    done(ok)
                }
            }
        }
    }

    /// Moves a notebook's folder inside the notes' folder, coordinated, through no symbolic link, never over another
    /// folder (a change of case only is the same folder). Off the main thread.
    nonisolated static func moveFolder(_ from: URL, to: URL, root: URL) -> Bool {
        let fm = FileManager.default
        guard safe(from, root: root), safe(to, root: root),
              to.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
              from.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else { return false }
        let caseOnly = from.lastPathComponent.compare(to.lastPathComponent, options: .caseInsensitive) == .orderedSame
        if fm.fileExists(atPath: to.path), !caseOnly { return false }
        var ok = false
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: from, options: .forMoving, writingItemAt: to, options: .forReplacing,
                                                         error: &error) { source, destination in
            if fm.fileExists(atPath: destination.path), !caseOnly { return }
            ok = (try? fm.moveItem(at: source, to: destination)) != nil
        }
        return ok
    }

    // MARK: Canvas

    /// A notebook's canvas file.
    nonisolated static let canvasName = ".canvas.json"

    /// A notebook's cover id, when its cover has one of its own in its file (what its canvas edits are kept by).
    func coverID(_ notebook: String) -> String? {
        guard let book = self.notebook(notebook), renewing[book.name] == nil, let key = book.cover, let cover = paper(key),
              NoteShelf.lasting(cover.noteID, pending: pendingIDs),
              coverTargetsForCanvas.filter({ $0.id == cover.noteID }).map({ $0.notebook.lowercased() }).uniqued().count == 1 else { return nil }
        return cover.noteID
    }

    /// The notebook whose cover has `id` now (followed through renames), or nil when it's gone.
    /// The key a notebook's canvas edits are kept by: its cover's id once it has one, else its folder itself
    /// (`folder:` and its volume and inode); nil when neither is known yet (its folder not read).
    func canvasKey(_ notebook: String) -> String? {
        if let id = coverID(notebook) { return id }
        guard let book = self.notebook(notebook), !book.instance.isEmpty else { return nil }
        return CanvasQueue.folderKey(book.instance)
    }

    /// The notebook a canvas key names now: by its cover's id, or its folder (followed through renames), or nil.
    func notebook(canvasKey key: String) -> Notebook? {
        CanvasQueue.notebook(key: key, covers: coverTargetsForCanvas, folders: notebooks.map { (instance: $0.instance, notebook: $0.name) })
            .flatMap { notebook($0) }
    }

    private var coverTargetsForCanvas: [(id: String, notebook: String)] {
        notes.filter { $0.file.cover && $0.version == nil }.map { (id: $0.noteID, notebook: $0.notebook) }
    }

    func notebook(coverID id: String) -> Notebook? {
        let covers = notes.filter { $0.file.cover && $0.version == nil }.map { (id: $0.noteID, notebook: $0.notebook) }
        return CanvasQueue.notebook(coverID: id, covers: covers).flatMap { notebook($0) }
    }

    /// A notebook's canvas as it is (the file merged with the versions iCloud kept of it, and the edits still waiting
    /// merged in), read off the main thread (nil: a file Petal can't read as a canvas). Versions waiting are merged
    /// into the file (a based write) and marked resolved.
    func canvas(_ notebook: String, _ done: @escaping @MainActor (NoteCanvas?) -> Void) {
        guard let book = self.notebook(notebook) else { return done(NoteCanvas()) }
        let file = book.folder.appending(path: Self.canvasName), root = self.root
        let name = book.name
        Self.io.async {
            let read = Self.readCanvas(file, root: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(read.map { $0.applyingMerged(self.canvasPending(name)) }) }
            }
        }
    }

    /// One change to a notebook's canvas, made as notes are: journaled first on this Mac's own disk, by the notebook's
    /// cover id (NoteJournal.keepCanvas), and kept in memory; then written with every other edit waiting, on the
    /// file as it is merged with iCloud's versions of it, through the same merge (never over anything newer), in one
    /// coordinated, atomic write (`writeCanvas`). A write that fails keeps them and tries again (2 s, doubling, at
    /// most a minute), the canvas saying "Not saved yet"; its notebook gone, they're rescued into "Unsaved notes".
    /// A notebook whose cover has no id of its own yet gets one first. `done`: the canvas once saved.
    /// `at`: when the person made the change (a gesture that waited for a note's id keeps its own time, so a later
    /// gesture always wins).
    func editCanvas(_ notebook: String, _ edit: NoteCanvas.Edit, at: Double = Date().timeIntervalSince1970,
                    then done: @escaping @MainActor (NoteCanvas?) -> Void = { _ in }) {
        guard !switching, !draining, let book = self.notebook(notebook) else { return done(nil) }
        // Journaled at once, by its cover's id or, while that isn't known (a cover still downloading, or none yet), by
        // its folder; re-keyed by cover id once it is (`rekeyCanvas`). Only a notebook whose folder isn't read yet
        // can't take edits: the canvas waits for it (`canvasEditable`), and nothing shown is left unjournaled.
        guard let key = canvasKey(book.name) else {
            onProblem("Waiting for \(book.name) to download: its canvas can be changed once it's here.")
            return done(nil)
        }
        queueCanvas(key, notebook: book.name, NoteCanvas.Stamped(edit, at: at), done)
    }

    private func queueCanvas(_ id: String, notebook: String, _ stamped: NoteCanvas.Stamped, _ done: @escaping @MainActor (NoteCanvas?) -> Void) {
        var entry = canvasWaiting[id] ?? CanvasEntry(coverID: id, notebook: notebook, edits: [])
        entry.notebook = notebook
        entry.edits.append(stamped)
        canvasWaiting[id] = entry
        canvasDone[id, default: []].append(done)
        journalCanvas(id)
        pumpCanvas(id)
    }

    /// The entry as it is now, journaled (in order with every other change on the journal's queue).
    private func journalCanvas(_ id: String) {
        let entry = canvasWaiting[id] ?? CanvasEntry(coverID: id, notebook: "", edits: [])
        NoteJournal.queue.async { NoteJournal.keepCanvas(entry) }
    }

    /// The edits of a notebook's canvas not saved yet.
    func canvasPending(_ notebook: String) -> [NoteCanvas.Stamped] {
        guard let book = self.notebook(notebook) else { return [] }
        let keys = [coverID(book.name), book.instance.isEmpty ? nil : CanvasQueue.folderKey(book.instance)].compactMap { $0 }
        return keys.flatMap { canvasWaiting[$0]?.edits ?? [] }
    }

    /// Whether a notebook's canvas can take an edit now (its cover id or folder known), else it says it's waiting.
    func canvasEditable(_ notebook: String) -> Bool { canvasKey(notebook) != nil }

    /// Edits kept by a notebook's folder whose cover now has an id: moved to the cover id's entry, journaled there
    /// first, then out of the folder's (never while a write of them is under way).
    private func rekeyCanvas() {
        for (key, entry) in canvasWaiting where CanvasQueue.isFolderKey(key) && !canvasWriting.contains(key) {
            guard let book = notebook(canvasKey: key), let id = coverID(book.name) else { continue }
            var target = canvasWaiting[id] ?? CanvasEntry(coverID: id, notebook: book.name, edits: [])
            target.edits += entry.edits.filter { edit in !target.edits.contains { $0.id == edit.id } }
            canvasWaiting[id] = target
            canvasWaiting[key] = nil
            canvasDone[id, default: []] += canvasDone.removeValue(forKey: key) ?? []
            let moved = Set(entry.edits.map(\.id))
            // The old entry loses them only once the new one holds them (NoteJournal.moveCanvas).
            NoteJournal.queue.async { NoteJournal.moveCanvas(target, from: key, ids: moved) }
        }
    }

    private func pumpCanvas(_ id: String) {
        guard !canvasWriting.contains(id), !switching, !draining, let entry = canvasWaiting[id], !entry.edits.isEmpty, loaded else { return }
        guard let book = notebook(canvasKey: id) else {
            // Not found while the folder isn't read completely (a cover still downloading could be it): it waits for
            // the next read.
            guard CanvasQueue.gone(found: false, complete: readComplete),
                  !CanvasQueue.ambiguous(key: id, covers: coverTargetsForCanvas) else { return }
            // Its notebook is gone (trashed, or its cover with it): rescued into Unsaved notes, never dropped.
            canvasWaiting[id] = nil
            canvasDone[id] = nil
            canvasWriting.insert(id)
            NoteJournal.queue.async {
                let kept = NoteJournal.rescueCanvas(entry) != nil
                if kept { NoteJournal.ackCanvas(id, wrote: Set(entry.edits.map(\.id))) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.canvasWriting.remove(id)
                        self.onProblem(kept ? "\(entry.notebook)'s canvas changes are kept in Unsaved notes: the notebook is gone."
                                            : "\(entry.notebook)'s canvas changes are kept on this Mac until Petal can save them.")
                    }
                }
            }
            return
        }
        canvasWriting.insert(id)
        let batch = entry.edits
        let started = canvasGeneration
        let callbacks = canvasDone[id] ?? []
        canvasDone[id] = []
        let file = book.folder.appending(path: Self.canvasName), root = self.root
        Self.io.async {
            let saved = Self.writeCanvas(batch, to: file, root: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.canvasWriting.remove(id)
                    // A drain (quit, a switch of folder) since it started: what's waiting is the journal's now, and this
                    // completion touches neither.
                    guard CanvasQueue.current(started: started, now: self.canvasGeneration) else { return }
                    let wrote = Set(batch.map(\.id))
                    if var now = self.canvasWaiting[id] {
                        now.edits = CanvasQueue.after(now.edits, wrote: wrote, ok: saved != nil)
                        self.canvasWaiting[id] = now.edits.isEmpty ? nil : now
                    }
                    if let saved {
                        // Only the exact edits it wrote leave the journal (by id); newer ones stay there.
                        NoteJournal.queue.async { NoteJournal.ackCanvas(id, wrote: wrote) }
                        self.canvasFailures[id] = nil
                        if self.canvasUnsaved.contains(book.name) { self.canvasUnsaved.remove(book.name) }
                        let shown = saved.applyingMerged(self.canvasWaiting[id]?.edits ?? [])
                        for callback in callbacks { callback(shown) }
                        self.pumpCanvas(id)
                    } else {
                        // Kept (in memory and the journal), said, and tried again.
                        self.canvasDone[id] = callbacks + (self.canvasDone[id] ?? [])
                        let failures = (self.canvasFailures[id] ?? 0) + 1
                        self.canvasFailures[id] = failures
                        self.canvasUnsaved.insert(book.name)
                        DispatchQueue.main.asyncAfter(deadline: .now() + CanvasQueue.retry(after: failures)) {
                            MainActor.assumeIsolated { self.pumpCanvas(id) }
                        }
                    }
                }
            }
        }
    }

    /// Edits waiting, after a read of the folder: each tried again where its notebook is now (renamed, gone).
    func pumpAllCanvas() {
        rekeyCanvas()
        for id in canvasWaiting.keys { pumpCanvas(id) }
    }

    /// A drain (quit, or a switch of folder): the edits waiting are already in the journal, on this Mac's own disk;
    /// nothing is written to the notes' folder here (quit never waits on iCloud for them). The next launch puts them
    /// back (NoteJournal.recoverCanvas).
    func drainCanvas() {
        canvasGeneration += 1
        canvasWaiting = [:]
        canvasDone = [:]
    }

    /// The canvas file merged with iCloud's versions of it; with `resolve`, versions there are merged into the file
    /// (a based write) and marked resolved. Off the main thread.
    nonisolated static func readCanvas(_ file: URL, root: URL, resolve: Bool = true) -> NoteCanvas? {
        guard safe(file, root: root) else { return nil }
        guard FileManager.default.fileExists(atPath: file.path) else { return NoteCanvas() }
        if resolve, !(NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []).isEmpty { return writeCanvas([], to: file, root: root) }
        guard let text = coordinatedRead(file) else { return nil }
        let versions = (NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []).compactMap { try? String(contentsOf: $0.url, encoding: .utf8) }
        return NoteCanvas.merged(disk: text, versions: versions)
    }

    /// Canvas edits on the file at `file`, coordinated and atomic: made on the file as it is merged with every
    /// version iCloud kept of it (one Petal can't read is left out and left unresolved), and the versions merged are
    /// marked resolved once the merge is written. Nil (nothing written) when the file isn't a canvas Petal can read,
    /// its folder is gone or the write failed. Off the main thread.
    nonisolated static func writeCanvas(_ edits: [NoteCanvas.Stamped], to file: URL, root: URL) -> NoteCanvas? {
        guard safe(file, root: root), safe(file.deletingLastPathComponent(), root: root),
              FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) else { return nil }
        var result: NoteCanvas?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: .forMerging, error: &error) { url in
            let there = FileManager.default.fileExists(atPath: url.path)
            let disk = there ? (try? String(contentsOf: url, encoding: .utf8)) : nil
            // A file there that can't be read is never taken for no file.
            if there, disk == nil { return }
            let versions = there ? (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []) : []
            let readable = versions.compactMap { version in
                (try? String(contentsOf: version.url, encoding: .utf8)).flatMap { NoteCanvas.decode($0) == nil ? nil : (version, $0) }
            }
            let text: String
            var whole: [Bool] = []
            if readable.isEmpty {
                guard let written = NoteCanvas.write(edits, disk: disk) else { return }
                text = written
            } else {
                guard let merged = NoteCanvas.merge(edits, disk: disk, versions: readable.map(\.1)) else { return }
                (text, whole) = merged
            }
            if text != disk {
                guard (try? Data(text.utf8).write(to: url, options: .atomic)) != nil else { return }
            }
            // Only versions kept whole (everything in them merged, keys this Petal doesn't know too) are resolved; the
            // others stay for the person, or a later Petal, to merge.
            for (index, (version, _)) in readable.enumerated() where whole.indices.contains(index) && whole[index] { version.isResolved = true }
            result = NoteCanvas.decode(text)
        }
        return result
    }

    nonisolated static func writeCanvas(_ edit: NoteCanvas.Edit, to file: URL, root: URL) -> NoteCanvas? {
        writeCanvas([NoteCanvas.Stamped(edit)], to: file, root: root)
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
    /// Each note's handle for tools, by note id: a random token, so a tool never sees a file name, path or id taken
    /// from one, and the same note keeps its handle when it's renamed or moved.
    var handles: [String: String]? = nil

    /// Each paper of a conflict's own part of its handle (the note's handle, a dot, then this), by the paper's key:
    /// kept across restarts and moved with its file; once the conflict is settled, the note's handle names the one
    /// left (NoteShield.find).
    var copies: [String: String]? = nil

    mutating func copyHandle(_ key: String, redact: ((String) -> String)? = nil) -> String {
        if let made = copies?[key] { return made }
        let made = Self.fresh(6, redact: redact)
        copies = (copies ?? [:]).merging([key: made]) { a, _ in a }
        return made
    }

    /// The note's handle, made the first time it's asked for.
    /// Letters only, and checked against the vault's redaction when it's at hand (`redact`): made again until it
    /// passes untouched (NoteShelf.handleSurvives), so a handle is never told as "(hidden)".
    static func fresh(_ count: Int, prefix: String = "", redact: ((String) -> String)?) -> String {
        var made = ""
        for _ in 0..<8 {
            made = prefix + NoteShelf.handleLetters(count) { Int.random(in: 0..<26) }
            if NoteShelf.handleSurvives(made, redact: redact ?? { $0 }) { break }
        }
        return made
    }

    mutating func handle(_ noteID: String, redact: ((String) -> String)? = nil) -> String {
        if let made = handles?[noteID] { return made }
        let made = Self.fresh(12, prefix: "n", redact: redact)
        handles = (handles ?? [:]).merging([noteID: made]) { a, _ in a }
        return made
    }

    /// A note known by a new id (an id-less note given its own): everything kept for it follows; its handle (kept by
    /// its holder key: the old id and that file) too, so the old path's id never names it again.
    mutating func rekeyID(_ old: String, holder: String, _ new: String) {
        if let spot = spots.removeValue(forKey: old) { spots[new] = spot }
        if let point = desk.removeValue(forKey: old) { desk[new] = point }
        shown = shown.map { $0 == old ? new : $0 }
        if let handle = handles?.removeValue(forKey: holder) { handles?[new] = handle }
    }

    static var file: URL { Config.supportFolder.appending(path: "notes-state.json") }

    static func load() -> NoteLocal {
        guard let data = try? Data(contentsOf: file), let local = try? JSONDecoder().decode(NoteLocal.self, from: data) else { return NoteLocal() }
        return local
    }

    /// What's written to disk: only what's kept by a real id that's in its file (NoteShelf.lasting); records of id-less
    /// notes, or of ids still being written, stay in memory for this run.
    func persisted(pending: Set<String>) -> NoteLocal {
        var out = self
        let keep = { (id: String) in NoteShelf.lasting(id, pending: pending) }
        out.shown = shown.filter(keep)
        out.spots = spots.filter { keep($0.key) }
        out.desk = desk.filter { keep($0.key) }
        out.handles = handles?.filter { keep($0.key) }
        out.copies = copies?.filter { keep(String($0.key.split(separator: "#").first ?? "")) }
        return out
    }

    func save(pending: Set<String> = []) {
        guard !Headless.on, let data = try? JSONEncoder().encode(persisted(pending: pending)) else { return }
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
