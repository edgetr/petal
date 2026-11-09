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

    /// A snapshot of typing that was undone back to what's saved (`current`): gone, unless it still carries a picture's
    /// bytes or a paste's sources not stored yet, which stay (on the note as it is now, marked landed).
    nonisolated static func retire(noteID: String, current: String?, in folder: URL = folder) {
        let url = file(noteID, in: folder)
        guard var entry = read(url) else { return }
        guard let current, !entry.pictures.isEmpty || !(entry.imports ?? []).isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        entry.text = current
        entry.landed = true
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

    /// A switch back to a notes' folder, on the journal's queue: that folder's note entries (by where each note was)
    /// move aside into a "recovering" folder of their own, as a launch's do, so new snapshots never mix with them; the
    /// session puts them back (`recover`) before it reads the folder. Entries of other folders stay where they are.
    /// Nil when there are none.
    nonisolated static func leftovers(forRoot root: URL, in folder: URL = folder) -> URL? {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        // The folder however its path is spelled (/var and /private/var are one folder).
        let spellings = Set([root.path, root.standardizedFileURL.path, root.resolvingSymlinksInPath().path])
        let mine = names.filter { name in
            guard let entry = read(folder.appending(path: name)) else { return false }
            let paths = [entry.path, URL(fileURLWithPath: entry.path).resolvingSymlinksInPath().path]
            return paths.contains { path in spellings.contains { NoteShelf.within(path, $0) != nil } }
        }
        guard !mine.isEmpty else { return nil }
        let stamp = String(format: "%.0f", Date().timeIntervalSince1970 * 1000)
        let holding = folder.deletingLastPathComponent().appending(path: "Notes journal, recovering \(stamp)")
        try? fm.createDirectory(at: holding, withIntermediateDirectories: true)
        for name in mine { _ = try? fm.moveItem(at: folder.appending(path: name), to: holding.appending(path: name)) }
        return holding
    }

    /// What the journal holds for a notes' folder being entered (NoteStore.switchRoot's second step).
    struct Prepared {
        /// Recovering folders of note entries, oldest first: put back by `recover`.
        var notes: [URL] = []
        /// At launch: the canvas entries moved aside, put back by `recoverCanvas` after the notes.
        var canvases: [URL] = []
        /// Cover fields to wait again in the folder's session (at launch every folder's, with what to clear once
        /// they're journaled again: `rejournalCovers`).
        var covers: [CoverFields] = []
        var coverHolding: [URL] = []
        var coverSources: [(file: URL, key: String?)] = []
        /// On a switch: the canvas edits made in this folder, to wait again in its session.
        var canvas: [CanvasEntry] = []
    }

    /// On the journal's queue, as a folder is entered. At launch, the whole journal as a launch always took it: the
    /// canvas entries moved aside first (the notes' recovery removes its own folder once its notes are back), the
    /// cover fields, then the notes' journal as it was and any recovery a launch before didn't finish. On a switch,
    /// only what was made in that folder: its note entries moved aside, and its cover fields and canvas edits read
    /// where they are (they stay journaled until they land).
    nonisolated static func prepare(for root: URL, launch: Bool, in folder: URL = folder) -> Prepared {
        var out = Prepared()
        if launch {
            out.canvases = canvasLeftovers(in: folder)
            let covers = coverLeftovers(in: folder)
            out.covers = covers.entries
            out.coverHolding = covers.holding
            out.coverSources = covers.sources
            out.notes = leftovers(in: folder)
        } else {
            out.notes = leftovers(forRoot: root, in: folder).map { [$0] } ?? []
            let here = root.path
            out.covers = coverEntries(in: folder).filter { !$0.root.isEmpty && NotebookBinding.sameRoot($0.root, here) }
            out.canvas = canvasEntries(in: folder).filter { !$0.bound.root.isEmpty && NotebookBinding.sameRoot($0.bound.root, here) }
        }
        return out
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
            // A cover's recovery keeps the cover's name (NoteShelf.copyStem), so it's still a cover.
            let stem = NoteShelf.copyStem(original: hint.lastPathComponent, title: NoteStore.safeStem(for: entry.text, fallback: NoteStore.plainStem))
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
/// ("Notes journal/Canvas", one entry per notebook, bound to it by its NotebookBinding, with the whole canvas it makes, replaced atomically),
/// so quitting never waits on iCloud for them. An entry goes once a write took its edits; at launch what's left is
/// moved aside before the notes' journal is (`canvasLeftovers`: the notes' recovery removes its own folder) and put
/// back by its binding (`recoverCanvas`): into that notebook's canvas wherever it is now (a rename followed), through
/// the same merge, else, its notebook gone, into "Unsaved notes" with the whole canvas. Nothing is dropped.
extension NoteJournal {
    nonisolated static func canvasFolder(in folder: URL = folder) -> URL { folder.appending(path: "Canvas") }

    nonisolated static func canvasFile(_ coverID: String, in folder: URL = folder) -> URL {
        canvasFolder(in: folder).appending(path: file(coverID, in: folder).lastPathComponent)
    }

    /// The edits waiting in memory, added to the entry on disk (by id, in order): only an acknowledgement (`ackCanvas`)
    /// takes an edit out, so no write of what's in memory (emptied by a drain, say) ever drops one. On the journal's
    /// queue.
    /// True once the entry on disk holds them (an entry there that can't be read is never written over: false).
    @discardableResult
    nonisolated static func keepCanvas(_ entry: CanvasEntry, in folder: URL = folder) -> Bool {
        let url = canvasFile(entry.coverID, in: folder)
        var entry = entry
        if FileManager.default.fileExists(atPath: url.path) {
            guard let there = readCanvas(url) else { return false }
            let ids = Set(entry.edits.map(\.id))
            entry.edits = there.edits.filter { !ids.contains($0.id) } + entry.edits
            if entry.notebook.isEmpty { entry.notebook = there.notebook }
            // The binding and whole canvas in memory are the newer ones; else what's there is kept.
            entry.binding = entry.binding ?? there.binding
            if let mine = entry.snapshot, let theirs = there.snapshot { entry.snapshot = NoteCanvas.merge(mine, theirs) }
            else if entry.snapshot == nil { entry.snapshot = there.snapshot }
        }
        return write(entry, to: url, in: folder)
    }

    @discardableResult
    private nonisolated static func write(_ entry: CanvasEntry, to url: URL, in folder: URL) -> Bool {
        guard !entry.edits.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return !FileManager.default.fileExists(atPath: url.path)
        }
        try? FileManager.default.createDirectory(at: canvasFolder(in: folder), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entry) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// A write took these edits: only they leave the entry on disk (by id); the entry goes once none is left.
    @discardableResult
    nonisolated static func ackCanvas(_ coverID: String, wrote ids: Set<String>, in folder: URL = folder) -> Bool {
        let url = canvasFile(coverID, in: folder)
        guard var entry = readCanvas(url) else { return !FileManager.default.fileExists(atPath: url.path) }
        entry.edits.removeAll { ids.contains($0.id) }
        return write(entry, to: url, in: folder)
    }

    /// Edits moved from one key to another (re-keyed by a cover id once known): the old entry loses them only after
    /// the new one was written; until then both are kept, and it's tried again (every 2 s, a few minutes at most;
    /// after that both stay for the next launch, which puts each back by its key, merged). On the journal's queue.
    nonisolated static func moveCanvas(_ target: CanvasEntry, from old: String, ids: Set<String>, in folder: URL = folder, attempt: Int = 0) {
        if keepCanvas(target, in: folder) { ackCanvas(old, wrote: ids, in: folder); return }
        guard attempt < 90 else { return }
        queue.asyncAfter(deadline: .now() + 2) { moveCanvas(target, from: old, ids: ids, in: folder, attempt: attempt + 1) }
    }

    /// Every canvas entry the journal holds now (one that can't be read is left out, and left there).
    nonisolated static func canvasEntries(in folder: URL = folder) -> [CanvasEntry] {
        let dir = canvasFolder(in: folder)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
            .compactMap { readCanvas(dir.appending(path: $0)) }
    }

    /// Every cover entry the journal holds now (one that can't be read is left out, and left there).
    nonisolated static func coverEntries(in folder: URL = folder) -> [CoverFields] {
        let dir = coverFolder(in: folder)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().compactMap { name in
            (try? Data(contentsOf: dir.appending(path: name))).flatMap { try? JSONDecoder().decode(CoverFields.self, from: $0) }
        }
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

    /// Puts back a recovering folder's canvas entries, on the notes' queue: each into the notebook its binding finds (NoteStore.writeCanvas: merged, never over anything newer), else rescued into "Unsaved notes". An entry
    /// goes only once one of those wrote; one that couldn't stays for the next launch. The folder goes once empty.
    nonisolated static func recoverCanvas(_ holding: URL, root: URL) {
        let fm = FileManager.default
        // A folder that can't be listed is kept as it is, for the next launch.
        guard let listed = try? fm.contentsOfDirectory(atPath: holding.path) else { return }
        let names = listed.filter { $0.hasSuffix(".json") }.sorted()
        let read = NoteStore.read(root)
        let places = NoteStore.places(notes: read.notes, notebooks: read.notebooks)
        for name in names {
            let url = holding.appending(path: name)
            guard let entry = readCanvas(url) else { continue }
            if landCanvas(entry, places: places, notebooks: read.notebooks, complete: read.complete, root: root) { try? fm.removeItem(at: url) }
        }
        // Gone only once listed and empty: entries that couldn't be read stay, and so does their folder.
        dropIfEmpty(holding)
    }

    /// One entry put somewhere safe: its notebook's canvas (found by its binding, NoteShelf.notebookFor), or "Unsaved
    /// notes" with its whole canvas when, after a complete read, nothing matches it or it's still ambiguous (never
    /// written to a notebook it can't tell surely). True once written. The folder not read completely: it waits.
    nonisolated static func landCanvas(_ entry: CanvasEntry, places: [NotebookPlace], notebooks: [Notebook], complete: Bool, root: URL) -> Bool {
        switch NoteShelf.notebookFor(entry.bound, places: places, complete: complete, root: root.path) {
        case .found(let name):
            guard let book = notebooks.first(where: { $0.name == name }) else { return false }
            return NoteStore.writeCanvas(entry.edits, binding: entry.bound, in: book.folder, root: root) != nil
        case .otherRoot:
            // Made in another notes' folder than this launch's: never applied here; rescued whole at this launch.
            return rescueCanvas(entry) != nil
        case .gone:
            return rescueCanvas(entry) != nil
        case .ambiguous:
            // Still ambiguous at the next launch's recovery: never written to a notebook, rescued whole, after a
            // complete read (else it waits for the next launch).
            return complete && rescueCanvas(entry) != nil
        case .wait:
            return false
        }
    }

    // MARK: Cover fields

    nonisolated static func coverFolder(in folder: URL = folder) -> URL { folder.appending(path: "Covers") }

    nonisolated static func coverFile(_ key: String, in folder: URL = folder) -> URL {
        coverFolder(in: folder).appending(path: file("cover:" + key, in: folder).lastPathComponent)
    }

    /// A notebook's cover fields waiting, written over its entry (the latest value of each field). On the journal's
    /// queue.
    /// True once the entry on disk says it.
    @discardableResult
    nonisolated static func keepCover(_ entry: CoverFields, in folder: URL = folder) -> Bool {
        let url = coverFile(entry.key, in: folder)
        guard !entry.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return !FileManager.default.fileExists(atPath: url.path)
        }
        try? FileManager.default.createDirectory(at: coverFolder(in: folder), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entry) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Cover entries recovered at launch journaled again; each moved-aside file goes once the entry it held was
    /// written again (by its key). One that couldn't be read or decoded, or whose entry couldn't be written, stays for
    /// the next launch, and so does its folder. On the journal's queue.
    nonisolated static func rejournalCovers(_ entries: [CoverFields], sources: [(file: URL, key: String?)], holding: [URL], in folder: URL = folder) {
        let written = Set(entries.filter { keepCover($0, in: folder) }.map(\.key))
        for source in sources { if let key = source.key, written.contains(key) { try? FileManager.default.removeItem(at: source.file) } }
        for folder in holding { dropIfEmpty(folder) }
    }

    /// A write took these fields: each leaves the entry only while it still holds that value.
    nonisolated static func ackCover(_ entry: CoverFields, wrote: [String: String], in folder: URL = folder) {
        let url = coverFile(entry.key, in: folder)
        guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(CoverFields.self, from: data) else { return }
        keepCover(entry.after(wrote: wrote), in: folder)
    }

    /// At launch, on the journal's queue, before the notes' `leftovers`: the cover entries (and any a recovering
    /// folder of the notes' journal holds) read and moved into a folder of their own, which goes once they're
    /// journaled again by the store (`dropCoverLeftovers`).
    /// `sources`: each file read (with its entry's key; nil when it couldn't be read or decoded: it stays). `whole`:
    /// every moved-aside folder was listed.
    nonisolated static func coverLeftovers(in folder: URL = folder) -> (entries: [CoverFields], holding: [URL], sources: [(file: URL, key: String?)]) {
        let fm = FileManager.default
        let parent = folder.deletingLastPathComponent()
        let stamp = String(format: "%.0f", Date().timeIntervalSince1970 * 1000)
        let names = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        let sources = [coverFolder(in: folder)] + NoteShelf.journalFolders(names).map { coverFolder(in: parent.appending(path: $0)) }
        for (n, source) in sources.enumerated() where !(((try? fm.contentsOfDirectory(atPath: source.path)) ?? []).isEmpty) {
            _ = try? fm.moveItem(at: source, to: parent.appending(path: "Covers journal, recovering \(stamp)-\(n)"))
        }
        let holding = ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).filter { $0.hasPrefix("Covers journal, recovering ") }.sorted()
            .map { parent.appending(path: $0) }
        var entries: [CoverFields] = []
        var files: [(file: URL, key: String?)] = []
        for folder in holding {
            for name in ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() {
                let file = folder.appending(path: name)
                if let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(CoverFields.self, from: data) {
                    entries.append(entry)
                    files.append((file, entry.key))
                } else {
                    files.append((file, nil))
                }
            }
        }
        return (entries, holding, files)
    }

    /// A moved-aside folder goes only once it was listed and holds nothing (every file in it read and rewritten).
    nonisolated static func dropIfEmpty(_ folder: URL) {
        guard let left = try? FileManager.default.contentsOfDirectory(atPath: folder.path), left.isEmpty else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// A canvas entry whose notebook is gone, into "Unsaved notes": the whole canvas (the snapshot it journaled: the
    /// last canvas Petal read for it with its edits merged in), in a folder of its own.
    @discardableResult
    nonisolated static func rescueCanvas(_ entry: CanvasEntry, in support: URL = Config.supportFolder) -> URL? {
        let folder = support.appending(path: "Unsaved notes")
            .appending(path: NoteShelf.rescueFolder(noteID: "canvas:" + entry.coverID, at: Date()))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: NoteShelf.folderName(entry.notebook.isEmpty ? "A notebook" : entry.notebook) + " canvas.json")
        let whole = (entry.snapshot ?? NoteCanvas()).applyingMerged(entry.edits)
        guard (try? Data(whole.encoded().utf8).write(to: file, options: .withoutOverwriting)) != nil else { return nil }
        return file
    }
}
