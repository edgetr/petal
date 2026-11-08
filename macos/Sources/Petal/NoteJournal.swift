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
        if NoteShelf.journalClears(snapshot: entry.text, landed: text, referenced: entry.pictures.map(\.name), unsaved: unsaved) {
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
        if entry.landed == true && entry.pictures.isEmpty { try? FileManager.default.removeItem(at: url) } else { snapshot(entry, in: folder) }
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
            guard let entry = read(url) else { try? fm.removeItem(at: url); continue }
            if recoverEntry(entry, notes: notes, root: root) { try? fm.removeItem(at: url) }
        }
        if (((try? fm.contentsOfDirectory(atPath: holding.path)) ?? []).filter { $0.hasSuffix(".json") }).isEmpty { try? fm.removeItem(at: holding) }
    }

    /// One entry put back somewhere safe: true once it's written and said so.
    nonisolated static func recoverEntry(_ entry: Entry, notes: [PaperNote], root: URL) -> Bool {
        let found = notes.filter { $0.noteID == entry.noteID && $0.version == nil }.map(\.url.path)
        let pictures = entry.pictures.map { NotePictureBytes(name: $0.name, data: $0.data, caption: "") }
        func picturesBeside(_ note: URL) -> Bool {
            pictures.isEmpty || NoteStore.writePictures(pictures, into: note.deletingLastPathComponent().appending(path: NoteShelf.assetsFolder(id: entry.noteID)),
                                                         root: root).count == pictures.count
        }
        switch NoteShelf.journalTarget(found: found) {
        case .note(let path):
            let note = URL(fileURLWithPath: path)
            let disk = NoteStore.coordinatedRead(note)
            guard picturesBeside(note) else { break }
            switch NoteShelf.journalRecovery(disk: disk, base: entry.base, text: entry.text, aside: entry.aside) {
            case .nothing: return true
            case .write: if NoteStore.save(entry.text, to: note, base: entry.base, root: root) == .written { return true }
            case .copy: if case .keptBoth = NoteStore.keepBeside(entry.text, original: note, root: root) { return true }
            }
        case .separate:
            // A file of its own in the notebook it was in: never into a note that isn't it.
            let hint = URL(fileURLWithPath: entry.path)
            let folder = hint.deletingLastPathComponent()
            let note = NoteFile.parse(entry.text, fallbackID: entry.noteID, fallbackDate: Date())
            let stem = NoteText.fileName(note.title.isEmpty ? hint.deletingPathExtension().lastPathComponent : note.title)
            if NoteStore.safe(folder, root: root), picturesBeside(hint),
               NoteStore.createNamed(entry.text, stem: entry.base == nil ? stem : stem + " (recovered)", in: folder, root: root) != nil {
                return true
            }
        }
        return NoteStore.rescue(entry.text, noteID: entry.noteID, pictures: pictures)
    }
}
