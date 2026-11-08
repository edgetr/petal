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

    var key: String { version.map { url.path + "#" + $0 } ?? url.path }
    var id: String { key }
    var noteID: String { file.id }
    /// Its pictures' folder, beside it.
    var assets: URL { url.deletingPathExtension().appendingPathExtension("assets") }

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
@MainActor @Observable
final class NoteStore {
    private(set) var notes: [PaperNote] = []
    private(set) var notebooks: [Notebook] = []
    /// Notes with more than one paper (iCloud conflicts), by note id.
    private(set) var conflicts: [String: [PaperNote]] = [:]
    private(set) var loaded = false
    @ObservationIgnored private(set) var root: URL
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var reloadSoon: DispatchWorkItem?
    @ObservationIgnored private var generation = 0
    /// Called on the main thread after every read of the folder.
    @ObservationIgnored var onChange: () -> Void = {}

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

    // MARK: Reading

    /// Reads the whole folder again, off the main thread; a newer read wins.
    func reload() {
        generation += 1
        let mine = generation
        let root = self.root
        Self.io.async {
            let read = Self.read(root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard mine == self.generation else { return }
                    if read.notes != self.notes { self.notes = read.notes }
                    if read.notebooks != self.notebooks { self.notebooks = read.notebooks }
                    let groups = Dictionary(grouping: read.notes, by: \.noteID).filter { $0.value.count > 1 }
                    if groups != self.conflicts { self.conflicts = groups }
                    self.loaded = true
                    self.onChange()
                }
            }
        }
    }

    /// Every notebook and note under `root`, with Inbox (and its cover) made the first time. Files iCloud hasn't
    /// downloaded yet are asked for and read once they arrive (the folder changes then).
    nonisolated static func read(_ root: URL) -> (notes: [PaperNote], notebooks: [Notebook]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let inbox = root.appending(path: NoteShelf.inbox)
        if !fm.fileExists(atPath: inbox.path) {
            try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
            var cover = NoteFile(body: "# About this notebook\n\nNotes go here unless you choose another notebook. Write here what this notebook is for.")
            cover.cover = true
            cover.color = "accent"
            write(cover, to: inbox.appending(path: NoteShelf.coverName))
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey,
                                      .ubiquitousItemHasUnresolvedConflictsKey, .isUbiquitousItemKey]
        let folders = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.pathExtension != "assets" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var notes: [PaperNote] = []
        var notebooks: [Notebook] = []
        for folder in folders {
            let name = folder.lastPathComponent
            let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension.lowercased() == "md" }
            var here: [PaperNote] = []
            for url in files {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try? fm.startDownloadingUbiquitousItem(at: url)
                    continue
                }
                let date = values.contentModificationDate ?? Date()
                guard let text = coordinatedRead(url) else { continue }
                let fallback = "file:" + url.lastPathComponent
                here.append(PaperNote(file: NoteFile.parse(text, fallbackID: fallback, fallbackDate: date), url: url, notebook: name))
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

    /// A file's text, read the way iCloud Drive wants (it may need to bring the file down first). Off the main thread.
    nonisolated static func coordinatedRead(_ url: URL) -> String? {
        var text: String?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { url in
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        return text
    }

    /// Writes a note's file, atomically and coordinated. Off the main thread.
    @discardableResult
    nonisolated static func write(_ note: NoteFile, to url: URL) -> Bool {
        var ok = false
        var error: NSError?
        let data = Data(note.serialized().utf8)
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { url in
            ok = (try? data.write(to: url, options: .atomic)) != nil
        }
        return ok
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

    // MARK: Writing

    /// Changes a note in memory at once and writes it off the main thread (with its modified time now).
    func save(_ paper: PaperNote, touch: Bool = true) {
        var paper = paper
        if touch { paper.file.modified = Date() }
        if let index = notes.firstIndex(where: { $0.key == paper.key }) { notes[index] = paper } else { notes.append(paper) }
        guard paper.version == nil else { return }
        let file = paper.file, url = paper.url
        Self.io.async { Self.write(file, to: url) }
    }

    /// A new note in `notebook` (made if it's new), its file named for its first words. Returns it at once; the file
    /// is written off the main thread.
    func make(_ file: NoteFile, in notebook: String) -> PaperNote {
        let name = NoteShelf.folderName(notebook)
        let folder = root.appending(path: name)
        let taken = Set(notes.filter { $0.notebook == name }.map { $0.url.lastPathComponent.lowercased() })
        let stem = NoteText.fileName(file.title.isEmpty ? "Note \(Self.shortDate.string(from: file.created))" : file.title)
        let url = folder.appending(path: NoteShelf.freeName(stem, taken: taken))
        let paper = PaperNote(file: file, url: url, notebook: name)
        notes.insert(paper, at: 0)
        if self.notebook(name) == nil { notebooks.append(Notebook(name: name, folder: folder, color: "", cover: nil, count: 1)) }
        Self.io.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Self.write(file, to: url)
        }
        return paper
    }

    private static let shortDate: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "d MMM HH.mm"
        return format
    }()

    /// A new notebook: its folder and its cover with its color.
    func makeNotebook(_ name: String, color: String) -> String {
        let folderName = NoteShelf.folderName(name)
        let folder = root.appending(path: folderName)
        guard notebook(folderName) == nil else { return folderName }
        notebooks.append(Notebook(name: folderName, folder: folder, color: color, cover: nil, count: 0))
        var cover = NoteFile(body: "# About this notebook\n\nWhat \(folderName) is for.")
        cover.cover = true
        cover.color = color
        Self.io.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: NoteShelf.coverName)
            if !FileManager.default.fileExists(atPath: url.path) { Self.write(cover, to: url) }
        }
        return folderName
    }

    /// Moves a note (and its pictures) into another notebook, made if it's new. Coordinated, off the main thread.
    func move(_ paper: PaperNote, to notebook: String, then done: @escaping @MainActor (PaperNote?) -> Void = { _ in }) {
        let name = makeNotebook(notebook, color: "")
        guard name != paper.notebook, paper.version == nil else { return done(paper) }
        let folder = root.appending(path: name)
        let taken = Set(notes.filter { $0.notebook == name }.map { $0.url.lastPathComponent.lowercased() })
        let target = folder.appending(path: NoteShelf.freeName(paper.url.deletingPathExtension().lastPathComponent, taken: taken))
        var moved = paper
        moved.url = target
        moved.notebook = name
        if let index = notes.firstIndex(where: { $0.key == paper.key }) { notes[index] = moved }
        let from = paper.url, assets = paper.assets, newAssets = moved.assets
        Self.io.async {
            var ok = false
            var error: NSError?
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: from, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &error) { a, b in
                ok = (try? FileManager.default.moveItem(at: a, to: b)) != nil
            }
            if ok, FileManager.default.fileExists(atPath: assets.path) { try? FileManager.default.moveItem(at: assets, to: newAssets) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok ? moved : nil); self.reload() } }
        }
    }

    /// A conflict settled: `kept` stays, the other papers of its note go to the Trash (a version iCloud kept is
    /// marked resolved; never deleted outright).
    func keep(_ kept: PaperNote) {
        let others = (conflicts[kept.noteID] ?? []).filter { $0.key != kept.key }
        let keptURL = kept.url, keptVersion = kept.version, keptFile = kept.file
        let files = others.filter { $0.version == nil && $0.url != keptURL }.map(\.url)
        Self.io.async {
            if keptVersion != nil { Self.write(keptFile, to: keptURL) }
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: keptURL) ?? [] { version.isResolved = true }
            try? NSFileVersion.removeOtherVersionsOfItem(at: keptURL)
            for file in files { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.reload() } }
        }
    }

    /// The notebook's color: its cover's ("accent" is the Mac's accent color), else the Mac's accent color.
    func color(of notebook: String) -> NSColor {
        let hex = self.notebook(notebook)?.color ?? ""
        if hex.isEmpty || hex == "accent" { return NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue }
        return NSColor(hex: hex) ?? NSColor.controlAccentColor
    }

    /// Saves a picture (pasted or dropped) beside the note: "<note>.assets/<name>". Returns its path as the note
    /// writes it, relative to the note's folder.
    func addPicture(_ data: Data, ext: String, to paper: PaperNote) -> String {
        let folder = paper.assets
        let name = "picture-\(Int(Date().timeIntervalSince1970 * 1000) % 100_000_000).\(ext)"
        Self.io.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appending(path: name), options: .atomic)
        }
        return folder.lastPathComponent + "/" + name
    }

    /// For snapshots: notes as given, nothing read or written.
    func preview(_ notes: [PaperNote], notebooks: [Notebook]) {
        self.notes = notes
        self.notebooks = notebooks
        loaded = true
    }
}

/// What Petal Notes keeps on this Mac only (never synced): this Mac's id, which notes are open, where notes were
/// moved to, the last notebook used on each site, and windows narrowed for a note. `Application Support/Petal/
/// notes-state.json`, written off the main thread.
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
