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

/// Petal Notes' files: one Markdown file per note, a folder per notebook, Inbox by default. They live in iCloud
/// Drive's "Petal Notes" when iCloud Drive is on, else in Petal's own folder (`notesFolder` picks another;
/// `PETAL_NOTES` points tests and snapshots elsewhere). Everything that touches a file runs on `io`, never the main
/// thread: an iCloud file may not be downloaded yet, and reading it waits for that. The folder is watched (FSEvents)
/// and read again when anything changes, from this Mac or another.
///
/// Nothing is written over: a save checks the file still says what the edit was made on (`PaperNote.revision`) and
/// otherwise keeps both; a new file is made only where no file is; every write, move and trash stays inside the
/// notes' folder, through no symbolic link. A read of the folder that comes back after a change made here never
/// undoes it (`NoteShelf.fenced`).
@MainActor @Observable
final class NoteStore {
    private(set) var notes: [PaperNote] = []
    private(set) var notebooks: [Notebook] = []
    /// Notes with more than one paper (iCloud conflicts, or an edit kept beside a file changed elsewhere), by note id.
    private(set) var conflicts: [String: [PaperNote]] = [:]
    private(set) var loaded = false
    @ObservationIgnored private(set) var root: URL
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var reloadSoon: DispatchWorkItem?
    @ObservationIgnored private var generation = 0
    /// Changes made here, on one clock with the reads of the folder: what a read that began before them must keep.
    @ObservationIgnored private var clock = 0
    @ObservationIgnored private var changedAt: [String: Int] = [:]
    @ObservationIgnored private var removedAt: [String: Int] = [:]
    /// Called on the main thread after every read of the folder.
    @ObservationIgnored var onChange: () -> Void = {}
    /// A new note's file got another name than the one it was given (a file had it on disk): old key, new paper.
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

    func use(root: URL) {
        guard root != self.root else { return }
        self.root = root
        stopWatching()
        start()
    }

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

    // MARK: Reading

    /// Reads the whole folder again, off the main thread; a newer read wins, and changes made here meanwhile stay.
    func reload() {
        generation += 1
        let mine = generation
        clock += 1
        let started = clock
        let root = self.root
        Self.io.async {
            let read = Self.read(root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard mine == self.generation else { return }
                    var merged = NoteShelf.fenced(read: read.notes, memory: self.notes, key: \.key, started: started,
                                                  changed: self.changedAt, removed: self.removedAt)
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
    /// or note that points elsewhere) are left out. A file's moved or renamed files (its bookmarks) are followed and
    /// written back.
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
                if followBookmarks(&paper.file) {
                    // A file it's stuck to moved or was renamed: the note says where it is now.
                    let updated = paper.file.serialized()
                    if save(updated, to: url, base: text, root: root) == .written { paper.revision = updated }
                }
                here.append(paper)
                // The versions iCloud kept from a change made on two Macs at once: each one a paper of its own.
                if values.ubiquitousItemHasUnresolvedConflicts == true {
                    for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                        guard let text = try? String(contentsOf: version.url, encoding: .utf8) else { continue }
                        var paper = PaperNote(file: NoteFile.parse(text, fallbackID: fallback, fallbackDate: version.modificationDate ?? date), url: url, notebook: name)
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
    /// papers. The file is read and written in one coordinated step. Off the main thread.
    nonisolated static func save(_ text: String, to url: URL, base: String?, root: URL) -> Outcome {
        guard safe(url, root: root) else { return .failed }
        var outcome = Outcome.failed
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { url in
            let disk = FileManager.default.fileExists(atPath: url.path) ? (try? String(contentsOf: url, encoding: .utf8)) : nil
            if FileManager.default.fileExists(atPath: url.path), disk == nil { return }   // there, but unreadable: never written over
            switch NoteShelf.save(disk: disk, base: base) {
            case .write:
                outcome = (try? Data(text.utf8).write(to: url, options: .atomic)) != nil ? .written : .failed
            case .keepBoth:
                outcome = keepBeside(text, original: url, root: root)
            }
        }
        return outcome
    }

    /// The same edit kept beside one file again overwrites the copy it made before, rather than making another.
    nonisolated(unsafe) private static var copies: [String: URL] = [:]

    /// An edit to a paper that became read only (its note has two papers now) as the person typed: kept in the copy
    /// beside the file rather than lost; the same copy as that edit's before.
    func keepAside(_ paper: PaperNote) {
        var paper = paper
        paper.file.modified = Date()
        let text = paper.file.serialized(), url = paper.url, root = self.root
        Self.io.async {
            _ = Self.keepBeside(text, original: url, root: root)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.reload() } }
        }
    }

    nonisolated private static func keepBeside(_ text: String, original: URL, root: URL) -> Outcome {
        let mark = original.path + "\n" + (NoteFile.parse(text, fallbackID: "", fallbackDate: Date()).id)
        if let copy = copies[mark], FileManager.default.fileExists(atPath: copy.path), safe(copy, root: root),
           (try? Data(text.utf8).write(to: copy, options: .atomic)) != nil {
            return .keptBoth(copy)
        }
        let folder = original.deletingLastPathComponent()
        let stem = original.deletingPathExtension().lastPathComponent
        for _ in 0..<20 {
            let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
            let copy = folder.appending(path: NoteShelf.conflictName(stem, taken: taken))
            if create(text, at: copy, root: root) {
                copies[mark] = copy
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

    /// Waits for every write of notes under way (on quit).
    nonisolated static func flush() { io.sync {} }

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

    // MARK: Writing

    /// Changes a note in memory at once and writes it off the main thread (with its modified time now), only over
    /// the file as it was when the edit began (`base`; the paper's own revision unless the editor says otherwise).
    /// Returns the note's text as written, the base for the next edit; nil when it can't be written (read only).
    @discardableResult
    func save(_ paper: PaperNote, base: String? = nil, touch stamp: Bool = true) -> String? {
        guard !readOnly(paper) else { return nil }
        var paper = paper
        if stamp { paper.file.modified = Date() }
        let text = paper.file.serialized()
        let since = base ?? paper.revision
        paper.revision = text
        if let index = notes.firstIndex(where: { $0.key == paper.key }) { notes[index] = paper } else { notes.append(paper) }
        touch(paper.key)
        let url = paper.url, root = self.root
        Self.io.async {
            let outcome = Self.save(text, to: url, base: since, root: root)
            guard outcome != .written else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if outcome == .failed { self.onProblem("Petal couldn't save “\(paper.file.title)”.") }
                    self.reload()
                }
            }
        }
        return text
    }

    /// A new note in `notebook` (made if it's new), its file named for its first words: shown at once, its file made
    /// off the main thread under the first name free on disk (`onRekey` when that isn't the one it was shown with).
    func make(_ file: NoteFile, in notebook: String) -> PaperNote {
        let name = NoteShelf.folderName(notebook)
        let folder = root.appending(path: name)
        let taken = Set(notes.filter { $0.notebook == name }.map { $0.url.lastPathComponent.lowercased() })
        let stem = NoteText.fileName(file.title.isEmpty ? "Note \(Self.shortDate.string(from: file.created))" : file.title)
        let text = file.serialized()
        var paper = PaperNote(file: file, url: folder.appending(path: NoteShelf.freeName(stem, taken: taken)), notebook: name, revision: text)
        notes.insert(paper, at: 0)
        touch(paper.key)
        if self.notebook(name) == nil { notebooks.append(Notebook(name: name, folder: folder, color: "", cover: nil, count: 1)) }
        let tentative = paper.key, root = self.root
        Self.io.async {
            let made = Self.createNamed(text, stem: stem, in: folder, root: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let made else {
                        self.onProblem("Petal couldn't make the note's file in \(name).")
                        return
                    }
                    guard made.path != tentative, let index = self.notes.firstIndex(where: { $0.key == tentative }) else { return }
                    self.gone(tentative)
                    paper = self.notes[index]
                    paper.url = made
                    self.notes[index] = paper
                    self.touch(paper.key)
                    self.onRekey(tentative, paper)
                }
            }
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

    /// Moves a note (and its pictures' folder) into another notebook, made if it's new, under the first name free
    /// there on disk. Coordinated, off the main thread. The pictures' folder is named for the note's id, so the
    /// note's references to its pictures hold.
    func move(_ paper: PaperNote, to notebook: String, then done: @escaping @MainActor (PaperNote?) -> Void = { _ in }) {
        let name = makeNotebook(notebook, color: "")
        guard name != paper.notebook, !readOnly(paper) else { return done(paper) }
        let folder = root.appending(path: name)
        let from = paper.url, assets = paper.assets, root = self.root
        let stem = paper.url.deletingPathExtension().lastPathComponent
        Self.io.async {
            var target: URL?
            if Self.safe(from, root: root), Self.safe(folder, root: root) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for _ in 0..<20 where target == nil {
                    let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
                    let candidate = folder.appending(path: NoteShelf.freeName(stem, taken: taken))
                    guard Self.safe(candidate, root: root) else { break }
                    var error: NSError?
                    var moved = false
                    NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: from, options: .forMoving, writingItemAt: candidate, options: .forReplacing, error: &error) { a, b in
                        // Never over a file that came there meanwhile.
                        guard !FileManager.default.fileExists(atPath: b.path) else { return }
                        moved = (try? FileManager.default.moveItem(at: a, to: b)) != nil
                    }
                    if moved { target = candidate } else if error != nil { break }
                }
                let newAssets = folder.appending(path: assets.lastPathComponent)
                if target != nil, FileManager.default.fileExists(atPath: assets.path), !FileManager.default.fileExists(atPath: newAssets.path),
                   Self.safe(assets, root: root), Self.safe(newAssets, root: root) {
                    try? FileManager.default.moveItem(at: assets, to: newAssets)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let target, let index = self.notes.firstIndex(where: { $0.key == paper.key }) else {
                        if target == nil { self.onProblem("Petal couldn't move “\(paper.file.title)” to \(name).") }
                        done(nil)
                        return
                    }
                    var moved = self.notes[index]
                    self.gone(moved.key)
                    moved.url = target
                    moved.notebook = name
                    self.notes[index] = moved
                    self.touch(moved.key)
                    done(moved)
                    self.reload()
                }
            }
        }
    }

    /// A conflict settled: `kept` becomes the note's file, and only once it's written there and reads back the same
    /// do the other papers go (a version iCloud kept is marked resolved; a copy goes to the Trash, never deleted).
    func keep(_ kept: PaperNote) {
        let others = (conflicts[kept.noteID] ?? []).filter { $0.key != kept.key }
        let keptURL = kept.url, keptVersion = kept.version, root = self.root
        let text = kept.version == nil ? nil : kept.file.serialized()
        let files = others.filter { $0.version == nil && $0.url != keptURL }.map(\.url)
        let originals = Set(others.filter { $0.version != nil }.map(\.url))
        Self.io.async {
            var ok = true
            if let text, keptVersion != nil {
                // The version kept becomes the file: written, then read back, before anything else changes.
                ok = Self.safe(keptURL, root: root)
                if ok {
                    var error: NSError?
                    var written = false
                    NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: keptURL, options: [], error: &error) { url in
                        written = (try? Data(text.utf8).write(to: url, options: .atomic)) != nil
                    }
                    ok = written && Self.coordinatedRead(keptURL) == text
                }
            }
            if ok {
                for url in Set([keptURL]).union(originals) {
                    for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] { version.isResolved = true }
                    try? NSFileVersion.removeOtherVersionsOfItem(at: url)
                }
                for file in files { Self.trash(file, root: root) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !ok { self.onProblem("Petal couldn't keep that version: nothing was changed.") }
                    self.reload()
                }
            }
        }
    }

    /// A note made and put away empty goes to the Trash (never deleted outright).
    func trash(_ paper: PaperNote) {
        notes.removeAll { $0.key == paper.key }
        gone(paper.key)
        let url = paper.url, root = self.root
        Self.io.async {
            Self.trash(url, root: root)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.reload() } }
        }
    }

    /// A notebook's color, kept on its cover (made where there's none).
    func recolor(_ notebook: String, _ value: String) {
        if let book = self.notebook(notebook), let key = book.cover, var cover = paper(key), !readOnly(cover) {
            cover.file.color = value
            save(cover)
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

    /// Saves a picture (pasted or dropped) in the note's pictures' folder, off the main thread. Returns its path as
    /// the note writes it (relative to the note's folder) and where it will be.
    func addPicture(_ data: Data, ext: String, to paper: PaperNote) -> (path: String, file: URL) {
        let folder = paper.assets, root = self.root
        let name = "picture-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
        let file = folder.appending(path: name)
        Self.io.async {
            guard Self.safe(folder, root: root), Self.safe(file, root: root) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .withoutOverwriting)
        }
        return (folder.lastPathComponent + "/" + name, file)
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
