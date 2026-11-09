import AppKit

/// What can't be lost at quit, on this Mac's own disk: a small per-note journal (Application Support's "Notes
/// journal", never iCloud), on a queue of its own. Each entry is a whole snapshot, never a patch: the note's id, the
/// text the note's oldest write not yet landed was made on (`base`), the person's full text at that moment, and the
/// bytes of every picture that text references whose bytes aren't in the note's pictures' folder yet. Each new
/// snapshot replaces the note's last one, atomically. A snapshot goes once a write of its text landed (or its
/// conflict copy did). At launch, what's left is put back entry by entry (`recover`), and an entry goes only once its
/// recovery wrote it somewhere safe. So quitting only waits for this queue, which is local and quick.
enum NoteJournal {
    nonisolated static let queue = DispatchQueue(label: "petal.notes.journal", qos: .userInitiated)

    /// `PETAL_SUPPORT_DIR` moves it with the rest of Petal's own state (tests, snapshots).
    nonisolated static var folder: URL { Config.supportFolder.appending(path: "Notes journal") }

    struct Entry: Codable, Equatable {
        var noteID: String
        /// Where the note was when the snapshot was taken: a hint for where a new note goes, never how it's found.
        var path: String
        var base: String?
        var text: String
        var pictures: [Picture] = []
        /// An edit kept beside a paper that turned read only: always a conflict copy.
        var aside = false
        /// Its text landed, but pictures it references weren't saved: kept for their bytes until they are.
        var landed: Bool? = nil
        /// Pictures pasted or dropped and still being read when it was taken: their sources (a file's path, or the
        /// pasteboard's bytes), put in at the next launch when a quit came first.
        var imports: [Import]? = nil
        /// Where its text already landed when part of it was put back and the rest waits (the note, a copy beside
        /// it, a file of its own, or one in "Unsaved notes"): the rest continues there, never somewhere else.
        var landedAt: String? = nil
    }

    /// A paste or drop not read yet: a file (`path`) or bytes from the pasteboard (`data`, TIFF turned into PNG
    /// when it's put in).
    struct Import: Codable, Equatable {
        var token: Int
        var path: String? = nil
        var data: Data? = nil
        var ext: String
        var caption = ""
    }

    /// What reading one source gives: its bytes (a picture), still there but not readable yet (waiting), or gone.
    enum SourceRead: Equatable { case bytes(Data), waiting, gone }

    /// One dropped or pasted source read, live and in recovery: a file by its path, or bytes. A file that's there
    /// but isn't a picture yet (still downloading) waits; one that isn't there is gone.
    nonisolated static func read(_ source: Import) -> SourceRead {
        if let data = source.data { return NSImage(data: data) != nil ? .bytes(data) : .gone }
        guard let path = source.path else { return .gone }
        let url = URL(fileURLWithPath: path)
        if let data = try? Data(contentsOf: url), NSImage(data: data) != nil { return .bytes(data) }
        return FileManager.default.fileExists(atPath: url.path) ? .waiting : .gone
    }

    /// A picture's bytes, as the editor accepted them (from memory, never read from its source here).
    struct Picture: Codable, Equatable {
        var name: String
        var data: Data
    }

    nonisolated static func file(_ noteID: String, aside: Bool = false, in folder: URL = folder) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in noteID.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return folder.appending(path: String(format: "%016llx", hash) + (aside ? "-aside" : "") + ".json")
    }

    nonisolated static func read(_ url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    // MARK: On the journal's queue

    /// A whole snapshot, replacing the note's last one in one atomic write.
    nonisolated static func snapshot(_ entry: Entry, in folder: URL = folder) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: file(entry.noteID, aside: entry.aside, in: folder), options: .atomic)
    }

    /// A text landed (in the note, or in its conflict copy): the snapshot holding exactly it goes once every picture
    /// it references is saved (`NoteShelf.journalClears`; `unsaved`: pictures whose bytes aren't in the note's folder
    /// yet, a failed one too). Until then it stays, keeping only those pictures; a newer snapshot stays as it is.
    nonisolated static func landed(noteID: String, text: String, aside: Bool = false, unsaved: Set<String> = [], in folder: URL = folder) {
        let url = file(noteID, aside: aside, in: folder)
        guard var entry = read(url), entry.text == text else { return }
        if NoteShelf.journalClears(snapshot: entry.text, landed: text, referenced: entry.pictures.map(\.name), unsaved: unsaved,
                                   importing: !(entry.imports ?? []).isEmpty) {
            try? FileManager.default.removeItem(at: url)
            return
        }
        entry.landed = true
        entry.pictures = entry.pictures.filter { unsaved.contains($0.name) }
        snapshot(entry, in: folder)
    }

    /// Pictures saved into the note's folder (or removed by the person): out of its snapshot; a snapshot whose text
    /// landed goes once none of its pictures is left.
    nonisolated static func picturesSaved(noteID: String, names: Set<String>, in folder: URL = folder) {
        let url = file(noteID, in: folder)
        guard var entry = read(url) else { return }
        entry.pictures.removeAll { names.contains($0.name) }
        settle(entry, at: url, in: folder)
    }

    /// A note known by a new id from now on (an id-less note given its own): its old snapshot goes (the new one,
    /// taken just before on this queue, holds all of it).
    nonisolated static func forget(noteID: String, in folder: URL = folder) {
        try? FileManager.default.removeItem(at: file(noteID, in: folder))
    }

    /// A paste's read is over (put in, or nothing in it could be read): its sources leave the snapshot.
    /// `keeping`: the files of it that weren't read yet and are still there: they stay, for Try again or the next
    /// launch.
    nonisolated static func importsDone(noteID: String, token: Int, keeping: [Import] = [], in folder: URL = folder) {
        let url = file(noteID, in: folder)
        guard var entry = read(url), entry.imports?.contains(where: { $0.token == token }) == true else { return }
        entry.imports?.removeAll { $0.token == token && !keeping.contains($0) }
        if entry.imports?.isEmpty == true { entry.imports = nil }
        settle(entry, at: url, in: folder)
    }

    /// A snapshot whose text landed goes once nothing of it is left to save (pictures, pastes); else it's kept.
    private nonisolated static func settle(_ entry: Entry, at url: URL, in folder: URL) {
        if entry.landed == true && entry.pictures.isEmpty && (entry.imports ?? []).isEmpty { try? FileManager.default.removeItem(at: url) }
        else { snapshot(entry, in: folder) }
    }

    /// The pastes a snapshot kept, read now: each one read becomes a picture (its bytes, a new name) and a line
    /// for it at the end of the text; one whose file is there but can't be read yet stays for the next launch; one
    /// whose file is gone is let go. Returns the entry to put back and the pastes still waiting.
    nonisolated static func readImports(_ entry: Entry) -> (entry: Entry, waiting: [Import]) {
        guard let imports = entry.imports, !imports.isEmpty else { return (entry, []) }
        var entry = entry
        var lines: [String] = []
        var waiting: [Import] = []
        for source in imports {
            let outcome = read(source)
            guard case .bytes(var data) = outcome else {
                if outcome == .waiting { waiting.append(source) }
                continue
            }
            var ext = source.ext.isEmpty ? "png" : source.ext
            if ext == "tiff" || ext == "tif", let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
                data = png
                ext = "png"
            }
            let name = "picture-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
            entry.pictures.append(Picture(name: name, data: data))
            lines.append(NoteBlock.image(path: NoteShelf.pictureLink(id: entry.noteID, name: name), caption: source.caption).markdown)
        }
        if !lines.isEmpty {
            // A text already in its file is the base the pictures' lines are written on.
            if entry.landed == true { entry.base = entry.text }
            entry.text += (entry.text.isEmpty || entry.text.hasSuffix("\n") ? "" : "\n") + lines.joined(separator: "\n")
            entry.landed = nil
        }
        entry.imports = nil
        return (entry, waiting)
    }

    /// At launch, on the journal's queue: the journal as it is moves aside into a "recovering" folder of its own
    /// (new snapshots never mix with it), and every "recovering" folder a launch before left (stopped part way) is
    /// handed back too, to resume. Returns them oldest first.
    nonisolated static func leftovers(in folder: URL = folder) -> [URL] {
        let fm = FileManager.default
        let parent = folder.deletingLastPathComponent()
        let entries = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }
        if !entries.isEmpty {
            let stamp = String(format: "%.0f", Date().timeIntervalSince1970 * 1000)
            _ = try? fm.moveItem(at: folder, to: parent.appending(path: "Notes journal, recovering \(stamp)"))
        }
        let names = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        return NoteShelf.journalFolders(names).map { parent.appending(path: $0) }
    }

    // MARK: Recovery (on the notes' queue)

    /// Puts back each entry of a recovering folder, one at a time: found by its note's id in the notes' folder as it
    /// is now (`NoteShelf.journalTarget`), written into that note while it still says what the snapshot was made on,
    /// else beside it as a conflict copy; with no single note of that id, a file of its own; and when the notes'
    /// folder can't take it, into "Unsaved notes" with its pictures. An entry is deleted only once one of those
    /// wrote and said so; one that couldn't is kept for the next launch. The folder goes once it's empty.
    nonisolated static func recover(_ holding: URL, root: URL) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: holding.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        guard !names.isEmpty else { try? fm.removeItem(at: holding); return }
        let notes = NoteStore.read(root).notes
        for name in names {
            let url = holding.appending(path: name)
            guard let kept = read(url) else { try? fm.removeItem(at: url); continue }
            let (entry, waiting) = readImports(kept)
            guard let at = land(entry, notes: notes, root: root) else { continue }
            if waiting.isEmpty { try? fm.removeItem(at: url); continue }
            // Put back, but a paste's file couldn't be read yet (iCloud still downloading it): the rest continues
            // where this landed (NoteShelf.continuation), on what landed there, with the bytes of every picture its
            // text references kept until they're stored there too.
            let notePaths = notes.filter { $0.noteID == entry.noteID && $0.version == nil }.map(\.url.path)
            let rest = continuation(entry, at: NoteShelf.continuation(landedAt: at.path, notePaths: notePaths), waiting: waiting)
            if let data = try? JSONEncoder().encode(rest) { try? data.write(to: url, options: .atomic) }
        }
        if (((try? fm.contentsOfDirectory(atPath: holding.path)) ?? []).filter { $0.hasSuffix(".json") }).isEmpty { try? fm.removeItem(at: holding) }
    }

    /// One paste of an entry (`token`) put into its note now, on what the entry says the note was: true once its
    /// pictures and their lines are written. Its other pastes and pictures wait for theirs.
    /// `waiting`: its files not read yet and still there, each kept for its own next try (the ones read go in
    /// now, whatever the rest do).
    /// `landed`: the text now in the note itself when it went there (not into a copy beside it or a file of its own):
    /// what the journal's snapshot advances to (`advance`).
    nonisolated static func putIn(_ entry: Entry, token: Int, root: URL) -> (stored: Bool, waiting: [Import], landed: String?, at: URL?) {
        guard let mine = entry.imports?.filter({ $0.token == token }), !mine.isEmpty else { return (false, [], nil, nil) }
        var one = Entry(noteID: entry.noteID, path: entry.path, base: entry.base, text: entry.text)
        one.landed = entry.landed
        one.imports = mine
        let (ready, waiting) = readImports(one)
        guard !ready.pictures.isEmpty else { return (false, waiting, nil, nil) }
        let notes = NoteStore.read(root).notes
        var placed = ready
        placed.landedAt = entry.landedAt
        guard let at = land(placed, notes: notes, root: root) else { return (false, waiting, nil, nil) }
        // What's in that file now, when it's what was put there: the snapshot advances to it, continuing at that
        // file unless it's the note itself (NoteShelf.continuation).
        let there = NoteShelf.within(at.path, root.path) != nil ? NoteStore.coordinatedRead(at) : (try? String(contentsOf: at, encoding: .utf8))
        let notePaths = notes.filter { $0.noteID == entry.noteID && $0.version == nil }.map(\.url.path)
        let continues = NoteShelf.continuation(landedAt: at.path, notePaths: notePaths).map { URL(fileURLWithPath: $0) }
        return (true, waiting, there == ready.text ? ready.text : nil, continues)
    }

    /// Part of a paste put into its note: the snapshot's whole text (and base) advance to what landed, with only the
    /// sources still waiting, while it's still the snapshot that put-in was made from (NoteShelf.advancedSnapshot);
    /// a newer snapshot keeps its text and only loses this paste's sources that went in.
    nonisolated static func advance(noteID: String, from used: String, to landed: String, at: URL? = nil, token: Int, keeping: [Import], in folder: URL = folder) {
        let url = file(noteID, in: folder)
        guard var entry = read(url) else { return }
        guard let next = NoteShelf.advancedSnapshot(current: entry.text, used: used, landed: landed) else {
            return importsDone(noteID: noteID, token: token, keeping: keeping, in: folder)
        }
        entry.text = next
        entry.base = nil
        entry.landed = true
        // The rest continues at the file it landed in (its pictures' bytes kept until stored there).
        if let at { entry.landedAt = at.path }
        let rest = (entry.imports ?? []).filter { $0.token != token } + keeping
        entry.imports = rest.isEmpty ? nil : rest
        settle(entry, at: url, in: folder)
    }

    /// What's left of an entry put back in part: its text as it landed at `at`, the sources still waiting, and every
    /// picture's bytes it had (they're stored again where it continues, never assumed to be).
    nonisolated static func continuation(_ entry: Entry, at: String?, waiting: [Import]) -> Entry {
        var rest = Entry(noteID: entry.noteID, path: entry.path, base: nil, text: entry.text)
        rest.landed = true
        rest.imports = waiting.isEmpty ? nil : waiting
        rest.pictures = entry.pictures
        rest.landedAt = at
        return rest
    }

    /// An entry put back: where it continues when part of it landed before (`landedAt`), else found as usual
    /// (`recoverEntry`). The file its text is in now, or nil when it couldn't be written.
    nonisolated static func land(_ entry: Entry, notes: [PaperNote], root: URL) -> URL? {
        if NoteShelf.continueAt(entry.landedAt, exists: entry.landedAt.map { FileManager.default.fileExists(atPath: $0) } ?? false), let at = entry.landedAt {
            return continueAt(entry, URL(fileURLWithPath: at), root: root)
        }
        return recoverEntry(entry, notes: notes, root: root)
    }

    /// The rest of an entry, at the file where its first part landed: its pictures where its links lead from that file
    /// (the notes' Pictures, or "Unsaved notes"' laid out the same), then its text over that file while it
    /// still says what landed there (`base`) or already says it; changed since, a copy beside it (in the notes'
    /// folder) or a new file in "Unsaved notes".
    nonisolated static func continueAt(_ entry: Entry, _ file: URL, root: URL) -> URL? {
        let fm = FileManager.default
        let pictures = entry.pictures.map { NotePictureBytes(name: $0.name, data: $0.data, caption: "") }
        if NoteShelf.within(file.path, root.path) != nil {
            guard NoteStore.restorePictures(pictures, text: entry.text, noteFile: file, noteID: entry.noteID, root: root) else { return nil }
            return landing(NoteStore.save(entry.text, to: file, base: entry.base, root: root, noteID: entry.noteID), at: file)
        }
        // In "Unsaved notes" (outside the notes' folder): the same, inside that rescue's own folder. Another picture
        // in the way (never taken for this one), or a link that leads out: the rest goes to a rescue of its own.
        let rescueFolder = file.deletingLastPathComponent().deletingLastPathComponent()
        if !NoteStore.restorePictures(pictures, text: entry.text, noteFile: file, noteID: entry.noteID, root: rescueFolder) {
            return NoteStore.rescued(entry.text, noteID: entry.noteID, pictures: pictures, from: file.deletingLastPathComponent())
        }
        // Nothing there, or what landed there: written; a file that can't be read, or changed since: kept, and the
        // rest goes to a file of its own (NoteShelf.continueWrite).
        let disk: NoteShelf.Disk = !fm.fileExists(atPath: file.path) ? .missing
            : (try? String(contentsOf: file, encoding: .utf8)).map { .text($0) } ?? .unreadable
        if NoteShelf.continueWrite(disk, base: entry.base, text: entry.text) == .write {
            return (try? Data(entry.text.utf8).write(to: file, options: .atomic)) != nil ? file : nil
        }
        return NoteStore.rescued(entry.text, noteID: entry.noteID, pictures: pictures, from: file.deletingLastPathComponent())
    }

    /// Where a save put a recovery's text: the file itself, or the copy `save` kept beside it (the rest continues
    /// there); nowhere for anything else.
    nonisolated static func landing(_ outcome: NoteStore.Outcome, at file: URL) -> URL? {
        switch outcome {
        case .written: return file
        case .keptBoth(let copy): return copy
        default: return nil
        }
    }

    /// One entry put back somewhere safe: the file it's in now once it's written and said so (the note, a copy
    /// beside it, a file of its own, or one in "Unsaved notes"); nil when nothing could take it.
    nonisolated static func recoverEntry(_ entry: Entry, notes: [PaperNote], root: URL) -> URL? {
        let found = notes.filter { $0.noteID == entry.noteID && $0.version == nil }.map(\.url.path)
        let pictures = entry.pictures.map { NotePictureBytes(name: $0.name, data: $0.data, caption: "") }
        // Its pictures' bytes exactly where its saved links point from that note (NoteStore.restorePictures).
        func picturesBeside(_ note: URL) -> Bool {
            NoteStore.restorePictures(pictures, text: entry.text, noteFile: note, noteID: entry.noteID, root: root)
        }
        switch NoteShelf.journalTarget(found: found) {
        case .note(let path):
            let note = URL(fileURLWithPath: path)
            let disk = NoteStore.coordinatedRead(note)
            guard picturesBeside(note) else { break }
            switch NoteShelf.journalRecovery(disk: disk, base: entry.base, text: entry.text, aside: entry.aside) {
            case .nothing: return note
            case .write:
                // Written, or kept beside it by `save` itself (the file changed at the last moment): it landed there.
                if let at = landing(NoteStore.save(entry.text, to: note, base: entry.base, root: root, noteID: entry.noteID), at: note) { return at }
            case .copy: if case .keptBoth(let copy) = NoteStore.keepBeside(entry.text, original: note, root: root) { return copy }
            }
        case .separate:
            // A file of its own in the notebook it was in: never into a note that isn't it.
            let hint = URL(fileURLWithPath: entry.path)
            let folder = hint.deletingLastPathComponent()
            let note = NoteFile.parse(entry.text, fallbackID: entry.noteID, fallbackDate: Date())
            // Named from its redacted title (never the old file's name, which may not be Petal's).
            _ = note
            let stem = NoteStore.safeStem(for: entry.text, fallback: NoteStore.plainStem)
            if NoteStore.safe(folder, root: root), picturesBeside(hint),
               let made = NoteStore.createNamed(entry.text, stem: entry.base == nil ? stem : stem + " (recovered)", in: folder, root: root) {
                return made
            }
        }
        // Into "Unsaved notes", every picture it references with it (from where the note's links lead).
        let beside = found.count == 1 ? URL(fileURLWithPath: found[0]).deletingLastPathComponent() : URL(fileURLWithPath: entry.path).deletingLastPathComponent()
        return NoteStore.rescued(entry.text, noteID: entry.noteID, pictures: pictures, from: beside)
    }
}

// MARK: - Canvas edits

/// A notebook canvas's edits not saved yet, journaled like notes: on the journal's queue, on this Mac's own disk
/// ("Notes journal/Canvas", one entry per notebook by its cover id, replaced whole and atomically with every change),
/// so quitting never waits on iCloud for them. An entry goes once a write took its edits; at launch what's left is
/// moved aside before the notes' journal is (`canvasLeftovers`: the notes' recovery removes its own folder) and put
/// back by cover id (`recoverCanvas`): into that notebook's canvas wherever it is now (a rename followed), through the
/// same merge, else, its notebook gone, into "Unsaved notes". Nothing is dropped.
extension NoteJournal {
    nonisolated static func canvasFolder(in folder: URL = folder) -> URL { folder.appending(path: "Canvas") }

    nonisolated static func canvasFile(_ coverID: String, in folder: URL = folder) -> URL {
        canvasFolder(in: folder).appending(path: file(coverID, in: folder).lastPathComponent)
    }

    /// The entry as it is now (edits left), replacing the last one; no edits left, it goes. On the journal's queue.
    nonisolated static func keepCanvas(_ entry: CanvasEntry, in folder: URL = folder) {
        let url = canvasFile(entry.coverID, in: folder)
        guard !entry.edits.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: canvasFolder(in: folder), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated static func readCanvas(_ url: URL) -> CanvasEntry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CanvasEntry.self, from: data)
    }

    /// At launch, on the journal's queue, before the notes' `leftovers`: the canvas entries (and any a recovering
    /// folder of the notes' journal still holds) moved into a folder of their own, and every such folder a launch
    /// before left. Oldest first.
    nonisolated static func canvasLeftovers(in folder: URL = folder) -> [URL] {
        let fm = FileManager.default
        let parent = folder.deletingLastPathComponent()
        let stamp = String(format: "%.0f", Date().timeIntervalSince1970 * 1000)
        let names = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        let sources = [canvasFolder(in: folder)] + NoteShelf.journalFolders(names).map { canvasFolder(in: parent.appending(path: $0)) }
        for (n, source) in sources.enumerated() {
            let entries = ((try? fm.contentsOfDirectory(atPath: source.path)) ?? []).filter { $0.hasSuffix(".json") }
            guard !entries.isEmpty else { continue }
            _ = try? fm.moveItem(at: source, to: parent.appending(path: "Canvas journal, recovering \(stamp)-\(n)"))
        }
        let after = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        return after.filter { $0.hasPrefix("Canvas journal, recovering ") }.sorted().map { parent.appending(path: $0) }
    }

    /// Puts back a recovering folder's canvas entries, on the notes' queue: each into the notebook whose cover has
    /// its id (NoteStore.writeCanvas: merged, never over anything newer), else rescued into "Unsaved notes". An entry
    /// goes only once one of those wrote; one that couldn't stays for the next launch. The folder goes once empty.
    nonisolated static func recoverCanvas(_ holding: URL, root: URL) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: holding.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        let read = NoteStore.read(root)
        let covers = read.notes.filter { $0.file.cover && !NoteShelf.needsID($0.noteID) }.map { (id: $0.noteID, notebook: $0.notebook) }
        for name in names {
            let url = holding.appending(path: name)
            guard let entry = readCanvas(url) else { continue }
            if landCanvas(entry, covers: covers, notebooks: read.notebooks, root: root) { try? fm.removeItem(at: url) }
        }
        if (((try? fm.contentsOfDirectory(atPath: holding.path)) ?? []).filter { $0.hasSuffix(".json") }).isEmpty { try? fm.removeItem(at: holding) }
    }

    /// One entry put somewhere safe: its notebook's canvas, or (gone) "Unsaved notes". True once written.
    nonisolated static func landCanvas(_ entry: CanvasEntry, covers: [(id: String, notebook: String)], notebooks: [Notebook], root: URL) -> Bool {
        if let name = CanvasQueue.notebook(coverID: entry.coverID, covers: covers), let book = notebooks.first(where: { $0.name == name }) {
            return NoteStore.writeCanvas(entry.edits, to: book.folder.appending(path: NoteStore.canvasName), root: root) != nil
        }
        return rescueCanvas(entry) != nil
    }

    /// A canvas entry whose notebook is gone, into "Unsaved notes": the canvas its edits make, in a folder of its own.
    @discardableResult
    nonisolated static func rescueCanvas(_ entry: CanvasEntry) -> URL? {
        let folder = Config.supportFolder.appending(path: "Unsaved notes")
            .appending(path: NoteShelf.rescueFolder(noteID: "canvas:" + entry.coverID, at: Date()))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: NoteShelf.folderName(entry.notebook.isEmpty ? "A notebook" : entry.notebook) + " canvas.json")
        guard (try? Data(NoteCanvas().applyingMerged(entry.edits).encoded().utf8).write(to: file, options: .withoutOverwriting)) != nil else { return nil }
        return file
    }
}
