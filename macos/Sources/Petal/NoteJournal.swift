import AppKit

/// What can't be lost at quit, on this Mac's own disk: every accepted edit and paste, written to a small per-note
/// journal (Application Support's "Notes journal", never iCloud) on a queue of its own, before it goes to the notes'
/// folder. An entry is cleared once what it holds landed in the note (or its conflict copy did). At launch, anything
/// still there is put back (`recover`): as the note when its file still says what the edit was made on, else as a
/// conflict copy beside it, else (the folder can't be written) into "Unsaved notes". So quitting only waits for this
/// queue, which is local and quick; the notes' own queue (iCloud may be slow) needn't finish first.
enum NoteJournal {
    nonisolated static let queue = DispatchQueue(label: "petal.notes.journal", qos: .userInitiated)

    /// `PETAL_SUPPORT_DIR` moves it with the rest of Petal's own state (tests, snapshots).
    nonisolated static var folder: URL { Config.supportFolder.appending(path: "Notes journal") }

    /// One note's writing not known to have landed: where its file is, the exact text its first unlanded edit was
    /// made on (`base`, nil for a new note), its newest text, and pictures accepted for it (bytes beside the entry,
    /// in "<entry>.pictures") whose reference isn't in a landed text yet. `aside`: an edit kept beside a paper that
    /// turned read only, always a conflict copy.
    struct Entry: Codable, Equatable {
        var noteID: String
        var path: String
        var base: String?
        var text: String?
        var pictures: [Picture] = []
        var aside = false
    }

    struct Picture: Codable, Equatable {
        var name: String
        var caption: String
    }

    // MARK: On the journal's queue

    nonisolated static func file(_ noteID: String, aside: Bool = false, in folder: URL = folder) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in noteID.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return folder.appending(path: String(format: "%016llx", hash) + (aside ? "-aside" : "") + ".json")
    }

    nonisolated static func read(_ url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    nonisolated static func write(_ entry: Entry, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: url, options: .atomic) }
    }

    /// An accepted edit: its newest text, on the base of the first edit not yet landed.
    nonisolated static func record(noteID: String, path: String, base: String?, text: String, aside: Bool = false, in folder: URL = folder) {
        let url = file(noteID, aside: aside, in: folder)
        var entry = read(url) ?? Entry(noteID: noteID, path: path, base: base, aside: aside)
        if entry.text == nil && !aside { entry.base = base }
        entry.path = path
        entry.text = text
        write(entry, to: url)
    }

    /// Pictures accepted for a note: their bytes kept beside its entry until their reference has landed.
    nonisolated static func recordPictures(noteID: String, path: String, base: String?, pictures: [NotePictureBytes], in folder: URL = folder) {
        let url = file(noteID, in: folder)
        var entry = read(url) ?? Entry(noteID: noteID, path: path, base: base)
        let bytes = url.deletingPathExtension().appendingPathExtension("pictures")
        try? FileManager.default.createDirectory(at: bytes, withIntermediateDirectories: true)
        for picture in pictures {
            guard let data = NoteStore.pictureData(picture) else { continue }
            try? data.write(to: bytes.appending(path: picture.name), options: .atomic)
            if !entry.pictures.contains(where: { $0.name == picture.name }) { entry.pictures.append(Picture(name: picture.name, caption: picture.caption)) }
        }
        entry.path = path
        write(entry, to: url)
    }

    /// A text landed in the note (or its conflict copy): what it holds is safe. The entry goes once nothing newer
    /// is in it; else what's newer is now made on this.
    nonisolated static func landed(noteID: String, text: String, aside: Bool = false, in folder: URL = folder) {
        let url = file(noteID, aside: aside, in: folder)
        guard var entry = read(url) else { return }
        // Pictures whose reference is in what landed: safe.
        let bytes = url.deletingPathExtension().appendingPathExtension("pictures")
        for picture in entry.pictures where text.contains(picture.name) { try? FileManager.default.removeItem(at: bytes.appending(path: picture.name)) }
        entry.pictures.removeAll { text.contains($0.name) }
        if entry.text == text { entry.text = nil }
        entry.base = text
        if entry.text == nil && entry.pictures.isEmpty {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: bytes)
        } else {
            write(entry, to: url)
        }
    }

    /// The note's file is somewhere else now (a move, a new note's name on disk).
    nonisolated static func moved(noteID: String, path: String, in folder: URL = folder) {
        for aside in [false, true] {
            let url = file(noteID, aside: aside, in: folder)
            guard var entry = read(url) else { continue }
            entry.path = path
            write(entry, to: url)
        }
    }

    /// Pictures the person removed (a failed import they let go of): out of the journal too.
    nonisolated static func dropPictures(noteID: String, names: [String], in folder: URL = folder) {
        let url = file(noteID, in: folder)
        guard var entry = read(url) else { return }
        let bytes = url.deletingPathExtension().appendingPathExtension("pictures")
        for name in names { try? FileManager.default.removeItem(at: bytes.appending(path: name)) }
        entry.pictures.removeAll { names.contains($0.name) }
        if entry.text == nil && entry.pictures.isEmpty { try? FileManager.default.removeItem(at: url) } else { write(entry, to: url) }
    }

    /// At launch, on the journal's queue: the entries left behind are taken out of the journal (into a folder of
    /// their own, so new edits never mix with them) and handed to `recover` on the notes' queue.
    nonisolated static func takeLeftovers(in folder: URL = folder) -> URL? {
        let fm = FileManager.default
        let entries = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }
        guard !entries.isEmpty else { return nil }
        let holding = folder.deletingLastPathComponent().appending(path: "Notes journal, recovering \(UUID().uuidString.prefix(8))")
        guard (try? fm.moveItem(at: folder, to: holding)) != nil else { return nil }
        return holding
    }

    /// Puts back each entry left behind (`recovery`): written into the note, kept beside it as a conflict copy, or,
    /// when the notes' folder can't take it, kept in "Unsaved notes" with its pictures. Off the main thread, on the
    /// notes' queue. The folder of leftovers goes once everything in it is somewhere safe.
    nonisolated static func recover(_ holding: URL, root: URL) {
        let fm = FileManager.default
        for name in ((try? fm.contentsOfDirectory(atPath: holding.path)) ?? []).filter({ $0.hasSuffix(".json") }) {
            let url = holding.appending(path: name)
            guard let entry = read(url) else { continue }
            let note = URL(fileURLWithPath: entry.path)
            let bytes = url.deletingPathExtension().appendingPathExtension("pictures")
            let pictures = entry.pictures.map { NotePictureBytes(name: $0.name, file: bytes.appending(path: $0.name), caption: $0.caption) }
            // The pictures' bytes first, into the note's pictures' folder (the same names: never twice).
            let pictured = pictures.isEmpty || NoteStore.writePictures(pictures, into: note.deletingLastPathComponent().appending(path: NoteShelf.assetsFolder(id: entry.noteID)),
                                                                          root: root).count == pictures.count
            let disk = fm.fileExists(atPath: note.path) ? NoteStore.coordinatedRead(note) : nil
            guard let text = NoteShelf.journalText(text: entry.text, disk: disk, noteID: entry.noteID, pictures: entry.pictures.map { ($0.name, $0.caption) })
            else { continue }
            var safe = false
            // Pictures only (no edit after them): their references go on the file as it is.
            switch NoteShelf.journalRecovery(disk: disk, base: entry.text == nil ? disk : entry.base, text: text, aside: entry.aside) {
            case .nothing: safe = true
            case .write: safe = NoteStore.save(text, to: note, base: disk, root: root) != .failed
            case .copy: if case .keptBoth = NoteStore.keepBeside(text, original: note, root: root) { safe = true }
            }
            // Whatever couldn't go back into the notes' folder is kept in "Unsaved notes": safe either way.
            if !safe || !pictured { NoteStore.rescue(text, pictures: pictured ? [] : pictures) }
        }
        // Petal's own leftovers, all somewhere safe now.
        try? fm.removeItem(at: holding)
    }
}
