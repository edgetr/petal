import AppKit

// Checks PaperNotes.swift's file work on throwaway folders in the temporary folder (never the person's notes, never
// the Trash): a save over a file changed elsewhere keeps both, new files never go over another, unidentified files in
// two notebooks stay two notes, nothing is written through a symbolic link, and a file's moved file is followed
// through its bookmark. Stand-ins below for the parts of Petal it would reach. Run with macos/checks/run.sh.
enum Headless { nonisolated(unsafe) static var on = true }
extension NSColor { convenience init?(hex: String?) { nil } }
enum Config { static let supportFolder = FileManager.default.temporaryDirectory.appending(path: "petal-check-support-\(UUID().uuidString)") }

@main
struct NoteStoreCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @MainActor static func main() {
        // File names from titles as they are (nothing here is a secret), except where a check says otherwise.
        NoteStore.nameRedactor = { $0 }
        // Never the person's Trash: what notes would trash is removed here, in the throwaway folders.
        NoteStore.toTrash = { (try? FileManager.default.removeItem(at: $0)) != nil }
        let fm = FileManager.default
        let top = fm.temporaryDirectory.appending(path: "petal-notes-check-\(UUID().uuidString)")
        let root = top.appending(path: "Notes")
        defer { try? fm.removeItem(at: top) }
        try? fm.createDirectory(at: root.appending(path: "Work"), withIntermediateDirectories: true)

        // Saving: over the file as the edit began, else both kept.
        let file = root.appending(path: "Work/Talk.md")
        expect(NoteStore.create("A", at: file, root: root), "a new file is made")
        expect(!NoteStore.create("other", at: file, root: root) && text(file) == "A", "never over a file that's there")
        expect(NoteStore.save("B", to: file, base: "A", root: root) == .written && text(file) == "B", "a save over the file as it began")
        try? Data("C, from another editor".utf8).write(to: file)
        let kept = NoteStore.save("D", to: file, base: "B", root: root)
        guard case .keptBoth(let copy) = kept else { expect(false, "a file changed elsewhere keeps both", "\(kept)"); return finish() }
        expect(text(file) == "C, from another editor" && text(copy) == "D", "the other editor's words stay; the edit goes beside them")
        expect(NoteShelf.isCopyName(copy.lastPathComponent), "as a copy", copy.lastPathComponent)
        _ = NoteStore.save("E", to: file, base: "B", root: root)
        let copies = (try? fm.contentsOfDirectory(atPath: root.appending(path: "Work").path))?.filter { $0.contains("conflicted copy") } ?? []
        expect(copies.count == 2 && text(copy) == "D", "the same edit again gets a copy of its own, never over the first", "\(copies)")

        // A copy changed elsewhere since Petal wrote it is never written over: the next edit makes another.
        try? Data("the copy, edited elsewhere".utf8).write(to: copy)
        let again = NoteStore.save("F", to: file, base: "B", root: root)
        if case .keptBoth(let next) = again {
            expect(next != copy && text(copy) == "the copy, edited elsewhere" && text(next) == "F", "a copy changed since gets a new copy beside it")
        } else { expect(false, "a copy changed since gets a new copy beside it", "\(again)") }

        // A write that failed (a folder Petal can't write to) leaves the file as it was. (Edits made on a failed one
        // are a session's to chain: see `sessions`.)
        let locked = root.appending(path: "Locked")
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let held = locked.appending(path: "Held.md")
        _ = NoteStore.create("G", at: held, root: root)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        expect(NoteStore.save("H", to: held, base: "G", root: root) == .failed && text(held) == "G", "a failed write leaves the file as it was")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        expect(NoteStore.save("I", to: held, base: "G", root: root) == .written && text(held) == "I", "and the next, made on the file as it is, is written")

        // New names come from the disk, and a name taken first is passed over.
        let made = NoteStore.createNamed("new", stem: "Talk", in: root.appending(path: "Work"), root: root)
        expect(made?.lastPathComponent == "Talk 2.md" && text(file) == "C, from another editor", "a new note never takes a file's name", made?.lastPathComponent ?? "nil")

        // Symbolic links: nothing written through one, and its notebook isn't read.
        let outside = top.appending(path: "Outside")
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: root.appending(path: "Linked"), withDestinationURL: outside)
        expect(!NoteStore.safe(root.appending(path: "Linked/x.md"), root: root), "a path through a link isn't safe")
        expect(!NoteStore.create("x", at: root.appending(path: "Linked/x.md"), root: root) && !fm.fileExists(atPath: outside.appending(path: "x.md").path),
               "and nothing is written there")
        expect(NoteStore.createNamed("x", stem: "x", in: root.appending(path: "Linked"), root: root) == nil, "nor made there")
        expect(!NoteStore.safe(top.appending(path: "elsewhere.md"), root: root) && !NoteStore.trash(top.appending(path: "elsewhere.md"), root: root),
               "nothing outside the notes' folder is touched")

        // Reading: files without front matter, one name in two notebooks, are two notes.
        try? fm.createDirectory(at: root.appending(path: "Home"), withIntermediateDirectories: true)
        try? Data("work list".utf8).write(to: root.appending(path: "Work/Todo.md"))
        try? Data("home list".utf8).write(to: root.appending(path: "Home/Todo.md"))
        try? Data("not mine".utf8).write(to: outside.appending(path: "Secret.md"))
        let read = NoteStore.read(root)
        let todos = read.notes.filter { $0.url.lastPathComponent == "Todo.md" }
        expect(todos.count == 2 && Set(todos.map(\.noteID)).count == 2, "two Todo.md are two notes", "\(todos.map(\.noteID))")
        expect(!read.notes.contains { $0.url.lastPathComponent == "Secret.md" } && !read.notebooks.contains { $0.name == "Linked" },
               "a linked notebook isn't read")
        expect(read.notes.allSatisfy { $0.version != nil || $0.revision != nil }, "every paper knows what it was read as")
        expect(read.notebooks.contains { $0.name == "Inbox" }, "Inbox is made")

        // Bookmarks: a file moved keeps its note.
        let doc = top.appending(path: "Doc.txt")
        try? Data("doc".utf8).write(to: doc)
        var note = NoteFile(id: "B1", body: "about the doc")
        var place = NoteStick(kind: .file)
        place.path = doc.path
        place.bookmark = (try? doc.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))?.base64EncodedString() ?? ""
        note.places = [place]
        let renamed = top.appending(path: "Doc renamed.txt")
        try? fm.moveItem(at: doc, to: renamed)
        expect(NoteStore.followBookmarks(&note) && URL(fileURLWithPath: note.places[0].path).resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath(), "a renamed file keeps its note", note.places[0].path)
        expect(!NoteStore.followBookmarks(&note), "and nothing changes once it's followed")
        sessions(root: root)
        journal(root: root)
        toolCancelled(root: root)
        concurrentMakes(root: root)
        renamedMakes(root: root)
        identity(root: root)
        idBeforeChange(root: root)
        identityFollowed(root: root)
        idFirst(root: root)
        moveAfterConflict(root: root)
        copyThenCommit(root: root)
        versionGroups(root: root)
        try? fm.removeItem(at: Config.supportFolder)
        finish()
    }

    /// A note's session's work, as the file queue does it (NoteStore.perform) and as quitting drains it.
    @MainActor static func sessions(root: URL) {
        let fm = FileManager.default
        let work = root.appending(path: "Sessions")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let item = { (id: Int, w: NoteWork) in NoteSession.Item(id: 1_000_000 + id, work: w, done: []) }   // far from the stores' own numbers
        // The note a file is (a file with no id of its own is its path's), as a session for it knows it.
        let idOf = { (url: URL) in NoteStore.noteID(of: text(url) ?? "", at: url, root: root) }

        // A write that fails stays first and is tried again; once it lands, the next (made on it) lands too.
        let held = work.appending(path: "Held.md")
        _ = NoteStore.create("v0", at: held, root: root)
        NoteDisk.states[1] = NoteDisk.State(url: held, noteID: idOf(held), revision: "v0")
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: work.path)
        expect(NoteStore.perform(.write(text: "v1", base: "v0"), session: 1, root: root).outcome == .failed, "a write that can't land fails")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.path)
        expect(NoteStore.perform(.write(text: "v1", base: "v0"), session: 1, root: root).outcome == .written, "tried again, it lands")
        expect(NoteStore.perform(.write(text: "v2", base: "v1"), session: 1, root: root).outcome == .written && text(held) == "v2", "and the next, made on it")
        expect(NoteStore.perform(.write(text: "v2", base: "elsewhere"), session: 1, root: root).outcome == .written, "a file that already says it is done")
        // A tool's write whose asker went: nothing changes.
        expect(NoteStore.perform(.write(text: "v3", base: "v2"), session: 1, root: root, live: { false }).outcome == .cancelled && text(held) == "v2",
               "a cancelled request changes nothing")

        // Picture bytes: a file of their own, the same name again is the same file; the note's Markdown untouched.
        let pictureNote = work.appending(path: "Pictures.md")
        let p0 = NoteFile(id: "P5", body: "p0").serialized()
        _ = NoteStore.create(p0, at: pictureNote, root: root)
        NoteDisk.states[5] = NoteDisk.State(url: pictureNote, noteID: "P5", revision: p0)
        let bytes = NotePictureBytes(name: "picture-1.png", data: Data("png".utf8), caption: "")
        let first = NoteStore.perform(.pictureBytes([bytes], noteID: "P5"), session: 5, root: root)
        let again = NoteStore.perform(.pictureBytes([bytes], noteID: "P5"), session: 5, root: root)
        expect(first.outcome == .written && again.outcome == .written && first.pictures.first?.path == again.pictures.first?.path && text(pictureNote) == p0,
               "picture bytes written once, idempotent, the note untouched")

        // A handwritten note linking a picture outside its own folder: the move carries it, its link holds; another
        // picture by that name where it lands stops the move, and nothing is left behind.
        let handwritten = work.appending(path: "Handwritten.md")
        let tripAssets = work.appending(path: "Trip.assets")
        try? fm.createDirectory(at: tripAssets, withIntermediateDirectories: true)
        try? Data("photo".utf8).write(to: tripAssets.appending(path: "photo.png"))
        let handText = NoteFile(id: "HW", body: "# Trip\n![](Trip.assets/photo.png)").serialized()
        _ = NoteStore.create(handText, at: handwritten, root: root)
        let clash = root.appending(path: "Clash/Trip.assets")
        try? fm.createDirectory(at: clash, withIntermediateDirectories: true)
        try? Data("someone else's".utf8).write(to: clash.appending(path: "photo.png"))
        expect(NoteStore.move(handwritten, noteID: "HW", into: root.appending(path: "Clash"), root: root) == nil && text(handwritten) == handText
               && text(clash.appending(path: "photo.png")) == "someone else's", "another picture by that name where it lands: the move stops")
        let landedHW = NoteStore.move(handwritten, noteID: "HW", into: root.appending(path: "Carried"), root: root)
        expect(landedHW != nil && text(root.appending(path: "Carried/Trip.assets/photo.png")) == "photo" && text(landedHW!) == handText
               && text(tripAssets.appending(path: "photo.png")) == "photo", "moved with its picture copied along, its text unchanged, the original left for others")

        // Moving a note with pictures: the pictures go first and come along; one in the way stops it all.
        let assetsName = NoteShelf.assetsFolder(id: "P5")
        let moved = NoteStore.move(pictureNote, noteID: "P5", into: root.appending(path: "Away"), root: root)
        expect(moved != nil && fm.fileExists(atPath: root.appending(path: "Away/\(assetsName)/picture-1.png").path)
               && !fm.fileExists(atPath: work.appending(path: assetsName).path), "a moved note's pictures go with it")
        let blocked = work.appending(path: "Blocked.md")
        let b0 = NoteFile(id: "B6", body: "b0").serialized()
        _ = NoteStore.create(b0, at: blocked, root: root)
        let blockedAssets = NoteShelf.assetsFolder(id: "B6")
        try? fm.createDirectory(at: work.appending(path: blockedAssets), withIntermediateDirectories: true)
        try? Data("mine".utf8).write(to: work.appending(path: "\(blockedAssets)/picture-2.png"))
        try? fm.createDirectory(at: root.appending(path: "Away/\(blockedAssets)"), withIntermediateDirectories: true)
        try? Data("other".utf8).write(to: root.appending(path: "Away/\(blockedAssets)/picture-2.png"))
        expect(NoteStore.move(blocked, noteID: "B6", into: root.appending(path: "Away"), root: root) == nil && text(blocked) == b0
               && text(work.appending(path: "\(blockedAssets)/picture-2.png")) == "mine", "another picture in the way: nothing moves, nothing breaks")

        // A move, then writes made meanwhile, as quitting drains them: the writing lands where the note landed.
        let moving = work.appending(path: "Moving.md")
        _ = NoteStore.create("m0", at: moving, root: root)
        NoteDisk.states[2] = NoteDisk.State(url: moving, noteID: idOf(moving), revision: "m0")
        NoteStore.drain([(session: 2, items: [item(10, .move(folder: root.appending(path: "Elsewhere"))), item(11, .write(text: "m1", base: "m0"))])], root: root)
        let landed = root.appending(path: "Elsewhere/Moving.md")
        expect(text(landed) == "m1" && !fm.fileExists(atPath: moving.path), "a move and the typing after it, drained at quit", text(landed) ?? "nil")

        // Exactly once: a write the queue did whose answer never reached the main thread, then the drain, then the
        // queue's next turn (or a secondWrite drain): each piece is done once.
        let once = work.appending(path: "Once.md")
        _ = NoteStore.create("e0", at: once, root: root)
        NoteDisk.states[7] = NoteDisk.State(url: once, noteID: idOf(once), revision: "e0")
        let firstWrite = item(30, .write(text: "e1", base: "e0")), secondWrite = item(31, .write(text: "e2", base: "e1"))
        expect(NoteDisk.once(firstWrite, session: 7, root: root)?.outcome == .written, "the queue writes the firstWrite")
        NoteStore.drain([(session: 7, items: [firstWrite, secondWrite])], root: root)
        expect(text(once) == "e2", "the drain takes the firstWrite as done and writes the secondWrite", text(once) ?? "nil")
        try? Data("changed elsewhere".utf8).write(to: once)
        expect(NoteDisk.once(secondWrite, session: 7, root: root) == nil && NoteDisk.once(firstWrite, session: 7, root: root) == nil,
               "the queue's next turn after the drain: nothing done again")
        NoteStore.drain([(session: 7, items: [firstWrite, secondWrite])], root: root)
        expect(text(once) == "changed elsewhere", "a secondWrite drain does nothing again either", text(once) ?? "nil")

        // Writing that still can't land at quit goes to "Unsaved notes" with the pictures it references, laid out as
        // in the notes' folder so its references hold.
        let stuck = work.appending(path: "Stuck.md")
        let s0 = NoteFile(id: "S3", body: "s0").serialized()
        _ = NoteStore.create(s0, at: stuck, root: root)
        NoteDisk.states[3] = NoteDisk.State(url: stuck, noteID: "S3", revision: s0)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: work.path)
        let reference = NoteShelf.assetsFolder(id: "S3") + "/picture-u.png"
        let kept = NoteFile(id: "S3", body: "# Rescued words\nkeep me\n![](\(reference))")
        NoteStore.drain([(session: 3, items: [item(21, .pictureBytes([NotePictureBytes(name: "picture-u.png", data: Data("u".utf8), caption: "")], noteID: "S3")),
                                              item(20, .write(text: kept.serialized(), base: s0))])], root: root)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.path)
        // Each rescue in a folder of its own in Unsaved notes.
        let unsaved = Config.supportFolder.appending(path: "Unsaved notes")
        let rescuedFile = ((try? fm.contentsOfDirectory(atPath: unsaved.path)) ?? []).map { unsaved.appending(path: $0 + "/Rescued words.md") }
            .first { fm.fileExists(atPath: $0.path) }
        expect(rescuedFile.flatMap(text)?.contains("keep me") == true, "writing that can't land by quit is kept in Unsaved notes, in a folder of its own")
        expect(rescuedFile.map { fm.fileExists(atPath: $0.deletingLastPathComponent().appending(path: reference).path) } == true,
               "with the pictures it references, where its references point")
        expect(text(stuck) == s0, "and the file is as it was")

        // Keep this one: checked again inside each coordinated step; a file edited since stops it.
        let keepA = work.appending(path: "Keep.md"), keepB = work.appending(path: "Keep 2.md")
        _ = NoteStore.create("ka", at: keepA, root: root)
        _ = NoteStore.create("kb", at: keepB, root: root)
        try? Data("kb edited".utf8).write(to: keepB)
        let plan = NoteKeep(snapshot: ["file:" + keepA.path: "ka", "file:" + keepB.path: "kb"], kept: keepA, keptText: nil, files: [keepA, keepB])
        expect(!NoteStore.keep(plan, root: root) && text(keepB) == "kb edited", "a paper edited since it was shown: nothing removed")
        expect(NoteWork.keepAside(text: "x").keeps && !NoteWork.trash(revision: nil).keeps, "writing is kept until it lands; a trash isn't")

        // Keeping an iCloud version (here, with another id than the current file): never over a current file the
        // plan didn't check, and only while it's exactly as shown and still that note.
        let current = work.appending(path: "Versioned.md")
        let mine = NoteFile(id: "MAC-A", body: "mine").serialized()
        _ = NoteStore.create(mine, at: current, root: root)
        let theirs = NoteFile(id: "MAC-B", body: "theirs").serialized()
        let unchecked = NoteKeep(snapshot: [:], kept: current, keptText: theirs, files: [current])
        expect(!NoteStore.keep(unchecked, root: root) && text(current) == mine, "a plan without the current file: nothing written")
        guard let made = NoteShelf.keepSnapshot(papers: [(current.path, nil, mine)], current: [current.path: (mine, "MAC-A")]) else { return expect(false, "a plan") }
        var checked = NoteKeep(snapshot: made.snapshot, kept: current, keptText: theirs, files: [current])
        checked.ids = made.ids
        try? Data(NoteFile(id: "MAC-A", body: "mine, edited").serialized().utf8).write(to: current)
        expect(!NoteStore.keep(checked, root: root) && text(current)?.contains("edited") == true, "the current file changed since: nothing written")
        try? Data(mine.utf8).write(to: current)
        expect(NoteStore.keep(checked, root: root) && text(current) == theirs, "exactly as shown: the kept version written")
    }

    /// The journal: accepted writing put back at launch after the notes' queue never got to it.
    @MainActor static func journal(root: URL) {
        let fm = FileManager.default
        let journal = Config.supportFolder.appending(path: "Notes journal")
        let notes = root.appending(path: "Journal")
        try? fm.createDirectory(at: notes, withIntermediateDirectories: true)
        let snap = { (id: String, path: URL, base: String?, text: String, pictures: [NoteJournal.Picture]) in
            NoteJournal.snapshot(NoteJournal.Entry(noteID: id, path: path.path, base: base, text: text, pictures: pictures), in: journal)
        }

        // A paste still being read when Petal quit: its source is in the snapshot; at the next launch it's read and
        // put in the note (whose text was already there), and one whose file can't be read yet waits.
        let pasted = notes.appending(path: "Pasted.md")
        let pastedText = NoteFile(id: "JI", body: "words").serialized()
        _ = NoteStore.create(pastedText, at: pasted, root: root)
        let source = root.appending(path: "source.png")
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:])
        try? png?.write(to: source)
        var loading = NoteJournal.Entry(noteID: "JI", path: pasted.path, base: nil, text: pastedText)
        loading.landed = true
        loading.imports = [NoteJournal.Import(token: 1, path: source.path, ext: "png", caption: "source")]
        NoteJournal.importsDone(noteID: "JI", token: 2, in: journal)   // another paste's end: nothing to do
        NoteJournal.snapshot(loading, in: journal)
        NoteJournal.landed(noteID: "JI", text: pastedText, in: journal)
        expect(NoteJournal.read(NoteJournal.file("JI", in: journal))?.imports?.count == 1, "its text landing keeps a paste still being read")
        let (withPicture, waiting) = NoteJournal.readImports(loading)
        expect(waiting.isEmpty && withPicture.pictures.count == 1 && withPicture.base == pastedText
               && withPicture.text.contains(NoteShelf.assetsFolder(id: "JI") + "/" + (withPicture.pictures.first?.name ?? "?")),
               "read at the next launch: a picture and its line, on the text that was there")
        expect(NoteJournal.recoverEntry(withPicture, notes: NoteStore.read(root).notes, root: root) != nil
               && text(pasted) == withPicture.text
               && fm.fileExists(atPath: notes.appending(path: NoteShelf.assetsFolder(id: "JI") + "/" + (withPicture.pictures.first?.name ?? "?")).path),
               "put back: the note has the picture", text(pasted) ?? "nil")
        var gone = loading
        gone.imports = [NoteJournal.Import(token: 3, path: root.appending(path: "nowhere.png").path, ext: "png")]
        expect(NoteJournal.readImports(gone).waiting.isEmpty && NoteJournal.readImports(gone).entry.text == pastedText, "a paste whose file is gone is let go")
        NoteJournal.importsDone(noteID: "JI", token: 1, in: journal)
        expect(!fm.fileExists(atPath: NoteJournal.file("JI", in: journal).path), "the paste done and the text landed: the snapshot goes")

        // A paste its note couldn't take (or one finished after the notes folder changed): put in from the journal
        // into that note in its own folder, and out of the journal only then.
        let rejected = notes.appending(path: "Rejected.md")
        let rejectedText = NoteFile(id: "JR", body: "kept words").serialized()
        _ = NoteStore.create(rejectedText, at: rejected, root: root)
        var held = NoteJournal.Entry(noteID: "JR", path: rejected.path, base: nil, text: rejectedText)
        held.landed = true
        held.imports = [NoteJournal.Import(token: 7, path: source.path, ext: "png", caption: "source")]
        NoteJournal.snapshot(held, in: journal)
        let unreadable = root.appending(path: "later.png")
        try? Data("not yet".utf8).write(to: unreadable)
        var notYet = held
        notYet.imports = [NoteJournal.Import(token: 8, path: unreadable.path, ext: "png")]
        expect(!NoteJournal.putIn(notYet, token: 8, root: root).stored && text(rejected) == rejectedText,
               "a paste whose file can't be read yet: nothing written, kept")
        expect(NoteJournal.putIn(held, token: 7, root: root).stored && text(rejected)?.contains(NoteShelf.assetsFolder(id: "JR")) == true,
               "put in from the journal: the note has the picture", text(rejected) ?? "nil")
        expect(NoteJournal.read(NoteJournal.file("JR", in: journal))?.imports?.count == 1, "and the journal still has it until it's said stored")
        NoteJournal.importsDone(noteID: "JR", token: 7, in: journal)
        expect(!fm.fileExists(atPath: NoteJournal.file("JR", in: journal).path), "stored: out of the journal")

        // A paste of two files, one read and one not downloaded yet: the read one goes in, the other stays in the
        // journal for its own next try.
        let partial = notes.appending(path: "Partial.md")
        let partialText = NoteFile(id: "JQ", body: "two pictures").serialized()
        _ = NoteStore.create(partialText, at: partial, root: root)
        let notDownloaded = root.appending(path: "cloud.png")
        try? Data("not yet".utf8).write(to: notDownloaded)
        var both = NoteJournal.Entry(noteID: "JQ", path: partial.path, base: nil, text: partialText)
        both.landed = true
        let waitingOne = NoteJournal.Import(token: 9, path: notDownloaded.path, ext: "png")
        both.imports = [NoteJournal.Import(token: 9, path: source.path, ext: "png", caption: "source"), waitingOne]
        NoteJournal.snapshot(both, in: journal)
        let (stored, left, landedText, _) = NoteJournal.putIn(both, token: 9, root: root)
        expect(stored && left == [waitingOne] && text(partial)?.contains(NoteShelf.assetsFolder(id: "JQ")) == true && landedText == text(partial),
               "the read file goes in, the waiting one is said, and what landed in the note too", "\(left)")
        // The snapshot advances to what landed, keeping only the waiting file.
        if let landedText { NoteJournal.advance(noteID: "JQ", from: partialText, to: landedText, token: 9, keeping: left, in: journal) }
        let advanced = NoteJournal.read(NoteJournal.file("JQ", in: journal))
        expect(advanced?.text == landedText && advanced?.base == nil && advanced?.imports == [waitingOne],
               "the snapshot's text is what landed, with only the waiting file")
        // The waiting file arrives: recovered on what landed, both pictures in the note, no competing copy.
        try? png?.write(to: notDownloaded)
        if let advanced {
            let again = NoteJournal.putIn(advanced, token: 9, root: root)
            let names = (try? fm.contentsOfDirectory(atPath: notes.path)) ?? []
            expect(again.stored && again.landed == text(partial) && (text(partial)?.components(separatedBy: "![").count ?? 0) == 3
                   && !names.contains { $0.hasPrefix("Partial") && $0.contains("conflicted") },
                   "the second picture goes in beside the first, never as a competing version", text(partial) ?? "nil")
        }
        // A newer snapshot is never overwritten by an advance.
        var newer = both
        newer.text = NoteFile(id: "JQ", body: "typed since").serialized()
        NoteJournal.snapshot(newer, in: journal)
        NoteJournal.advance(noteID: "JQ", from: partialText, to: landedText ?? "", token: 9, keeping: [waitingOne], in: journal)
        expect(NoteJournal.read(NoteJournal.file("JQ", in: journal))?.text == newer.text, "a newer snapshot keeps its text")
        NoteJournal.importsDone(noteID: "JQ", token: 9, in: journal)
        NoteJournal.forget(noteID: "JQ", in: journal)
        expect(!fm.fileExists(atPath: NoteJournal.file("JQ", in: journal).path), "once it's in (or removed): out")

        // A partial recovery that could only land in Unsaved notes: the rest continues there, with every picture's
        // bytes kept until it's stored there too (never assumed to be in the notes' folder).
        let lockedNotes = root.appending(path: "Unwritable")
        try? fm.createDirectory(at: lockedNotes, withIntermediateDirectories: true)
        let lockedNote = lockedNotes.appending(path: "Trip.md")
        let tripText = NoteFile(id: "JU", body: "trip").serialized()
        _ = NoteStore.create(tripText, at: lockedNote, root: root)
        let later = root.appending(path: "later-pic.png")
        try? Data("not downloaded".utf8).write(to: later)
        var trip = NoteJournal.Entry(noteID: "JU", path: lockedNote.path, base: nil, text: tripText)
        trip.landed = true
        trip.imports = [NoteJournal.Import(token: 1, path: source.path, ext: "png"), NoteJournal.Import(token: 1, path: later.path, ext: "png")]
        let holding = Config.supportFolder.appending(path: "Notes journal, recovering 1")
        try? fm.createDirectory(at: holding, withIntermediateDirectories: true)
        NoteJournal.snapshot(trip, in: holding)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedNotes.path)
        NoteJournal.recover(holding, root: root)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedNotes.path)
        let rest = NoteJournal.read(NoteJournal.file("JU", in: holding))
        let unsavedFolder = rest?.landedAt.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? Config.supportFolder
        expect(rest?.landedAt?.contains("Unsaved notes") == true && rest?.pictures.count == 1 && rest?.imports?.count == 1 && text(lockedNote) == tripText,
               "landed in Unsaved notes: the rest continues there, the first picture's bytes kept", "\(String(describing: rest?.landedAt))")
        try? png?.write(to: later)
        NoteJournal.recover(holding, root: root)
        let continued = rest?.landedAt.flatMap { text(URL(fileURLWithPath: $0)) } ?? ""
        let pictureFiles = (try? fm.contentsOfDirectory(atPath: unsavedFolder.appending(path: NoteShelf.assetsFolder(id: "JU")).path)) ?? []
        expect(continued.components(separatedBy: "![").count == 3 && pictureFiles.count == 2 && text(lockedNote) == tripText,
               "the rest continues in that same file, both pictures beside it, the note untouched", "\(pictureFiles) \(continued)")
        expect(!fm.fileExists(atPath: NoteJournal.file("JU", in: holding).path), "and the entry goes once it's all there")

        // A rescue into Unsaved notes carries the note's older pictures too (copied from beside it), and isn't
        // complete without them.
        let illustratedFolder = root.appending(path: "Illustrated")
        let oldAssets = illustratedFolder.appending(path: NoteShelf.assetsFolder(id: "RS"))
        try? fm.createDirectory(at: oldAssets, withIntermediateDirectories: true)
        try? png?.write(to: oldAssets.appending(path: "old.png"))
        let rescuedText = NoteFile(id: "RS", body: "# Illustrated\n![](\(NoteShelf.assetsFolder(id: "RS"))/old.png)\n![](\(NoteShelf.assetsFolder(id: "RS"))/new.png)").serialized()
        let newBytes = NotePictureBytes(name: "new.png", data: png ?? Data(), caption: "")
        let rescuedTo = NoteStore.rescued(rescuedText, noteID: "RS", pictures: [newBytes], from: illustratedFolder)
        let rescueAssets = (rescuedTo?.deletingLastPathComponent() ?? Config.supportFolder).appending(path: NoteShelf.assetsFolder(id: "RS"))
        expect(rescuedTo != nil && fm.fileExists(atPath: rescueAssets.appending(path: "old.png").path) && fm.fileExists(atPath: rescueAssets.appending(path: "new.png").path),
               "the older picture copied with the new one")
        // Two notes with the same relative picture (`Trip.assets/photo.png`, different pictures): each rescue in its own
        // folder, each with its own picture.
        let workTrip = root.appending(path: "WorkTrip"), homeTrip = root.appending(path: "HomeTrip")
        for (folder, bytes) in [(workTrip, "work photo"), (homeTrip, "home photo")] {
            try? fm.createDirectory(at: folder.appending(path: "Trip.assets"), withIntermediateDirectories: true)
            try? Data(bytes.utf8).write(to: folder.appending(path: "Trip.assets/photo.png"))
        }
        let workRescue = NoteStore.rescued(NoteFile(id: "W1", body: "# Work\n![](Trip.assets/photo.png)").serialized(), noteID: "W1", pictures: [], from: workTrip)
        let homeRescue = NoteStore.rescued(NoteFile(id: "H1", body: "# Home\n![](Trip.assets/photo.png)").serialized(), noteID: "H1", pictures: [], from: homeTrip)
        expect(workRescue?.deletingLastPathComponent() != homeRescue?.deletingLastPathComponent()
               && workRescue.flatMap { text($0.deletingLastPathComponent().appending(path: "Trip.assets/photo.png")) } == "work photo"
               && homeRescue.flatMap { text($0.deletingLastPathComponent().appending(path: "Trip.assets/photo.png")) } == "home photo",
               "two notes' pictures of one name: each rescue its own folder and its own picture")
        expect(NoteShelf.acceptExisting(existing: Data("a".utf8), wanted: Data("a".utf8)) && !NoteShelf.acceptExisting(existing: Data("a".utf8), wanted: Data("b".utf8))
               && !NoteShelf.acceptExisting(existing: nil, wanted: Data("a".utf8)), "an existing picture counts only when it's the same bytes")
        // A picture already where a recovery puts its own, with other bytes: never taken for it.
        let taken = root.appending(path: "Taken/" + NoteShelf.assetsFolder(id: "TK"))
        try? fm.createDirectory(at: taken, withIntermediateDirectories: true)
        try? Data("someone else's".utf8).write(to: taken.appending(path: "p.png"))
        expect(NoteStore.writePictures([NotePictureBytes(name: "p.png", data: Data("mine".utf8), caption: "")], into: taken, root: root).isEmpty
               && text(taken.appending(path: "p.png")) == "someone else's", "another picture by that name: not counted as written, and not written over")

        let gapText = NoteFile(id: "RG", body: "# Gap\n![](\(NoteShelf.assetsFolder(id: "RG"))/nowhere.png)").serialized()
        expect(NoteStore.rescued(gapText, noteID: "RG", pictures: [], from: illustratedFolder) == nil, "a picture it references that isn't anywhere: not complete (the journal keeps it)")

        // Continuing at a destination that can't be read: kept, the rest written to a file of its own.
        let unreadableDest = Config.supportFolder.appending(path: "Unsaved notes/Locked.md")
        try? Data("locked".utf8).write(to: unreadableDest)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableDest.path)
        var cont = NoteJournal.Entry(noteID: "RC", path: unreadableDest.path, base: "locked", text: NoteFile(id: "RC", body: "# Continued\nmore").serialized())
        cont.landedAt = unreadableDest.path
        let elsewhere = NoteJournal.continueAt(cont, unreadableDest, root: root)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadableDest.path)
        expect(elsewhere != nil && elsewhere?.path != unreadableDest.path && text(unreadableDest) == "locked",
               "an unreadable destination kept as it was; the rest in a file of its own")

        // Continuing at a copy `save` made: it landed there, and the rest continues there.
        let saved = notes.appending(path: "SaveCopy.md")
        let savedBase = NoteFile(id: "SC", body: "base").serialized()
        _ = NoteStore.create(savedBase, at: saved, root: root)
        try? Data(NoteFile(id: "SC", body: "changed at the last moment").serialized().utf8).write(to: saved)
        let outcome = NoteStore.save(NoteFile(id: "SC", body: "recovered").serialized(), to: saved, base: savedBase, root: root, noteID: "SC")
        if case .keptBoth(let copy) = outcome {
            expect(NoteJournal.landing(outcome, at: saved) == copy && text(copy)?.contains("recovered") == true, "a keptBoth copy is where it landed")
        } else { expect(false, "save kept both", "\(outcome)") }
        expect(NoteJournal.landing(.failed, at: saved) == nil && NoteJournal.landing(.written, at: saved) == saved, "written: the file; failed: nowhere")

        // A text that landed while a picture it references failed: the snapshot stays with that picture's bytes,
        // and goes once the picture is saved.
        let pic = NoteJournal.Picture(name: "picture-f.png", data: Data("f".utf8))
        snap("JP", notes.appending(path: "Pic.md"), nil, "words ![](x/picture-f.png)", [pic])
        NoteJournal.landed(noteID: "JP", text: "words ![](x/picture-f.png)", unsaved: ["picture-f.png"], in: journal)
        let kept = NoteJournal.read(NoteJournal.file("JP", in: journal))
        expect(kept?.landed == true && kept?.pictures == [pic], "text landed, picture failed: the snapshot keeps the picture")
        NoteJournal.picturesSaved(noteID: "JP", names: ["picture-f.png"], in: journal)
        expect(!fm.fileExists(atPath: NoteJournal.file("JP", in: journal).path), "the picture saved: the snapshot goes")

        // An accepted edit (with a picture its text references), then the notes' queue hangs: its write never happens.
        let hung = notes.appending(path: "Hung.md")
        let hungBase = NoteFile(id: "J1", body: "before").serialized()
        _ = NoteStore.create(hungBase, at: hung, root: root)
        let picture = NoteShelf.assetsFolder(id: "J1") + "/picture-j.png"
        let typed = NoteFile(id: "J1", body: "typed just before quit\n![](\(picture))").serialized()
        snap("J1", hung, hungBase, typed, [NoteJournal.Picture(name: "picture-j.png", data: Data("jpg".utf8))])

        // Renamed since (found by its id), and changed elsewhere (a copy beside it).
        let renamedFrom = notes.appending(path: "Old name.md"), renamedTo = notes.appending(path: "New name.md")
        let renameBase = NoteFile(id: "J2", body: "start").serialized()
        _ = NoteStore.create(renameBase, at: renamedTo, root: root)
        let typed2 = NoteFile(id: "J2", body: "mine").serialized()
        snap("J2", renamedFrom, renameBase, typed2, [])

        // Its old path now holds another note: never into it.
        let reused = notes.appending(path: "Reused.md")
        _ = NoteStore.create(NoteFile(id: "OTHER", body: "someone else's").serialized(), at: reused, root: root)
        let typed3 = NoteFile(id: "J3", body: "the gone note's words").serialized()
        snap("J3", reused, NoteFile(id: "J3", body: "was here").serialized(), typed3, [])

        // A landed edit leaves; an undone paste's bytes leave with the next snapshot.
        snap("J4", notes.appending(path: "Landed.md"), nil, "landed text", [])
        NoteJournal.landed(noteID: "J4", text: "landed text", in: journal)
        expect(!fm.fileExists(atPath: NoteJournal.file("J4", in: journal).path), "a landed edit leaves the journal")

        // Launch: the journal moves aside, and a recovery a launch before left part way is resumed too.
        let earlier = Config.supportFolder.appending(path: "Notes journal, recovering 1")
        try? fm.createDirectory(at: earlier, withIntermediateDirectories: true)
        let resumedNote = notes.appending(path: "Resumed.md")
        let resumedBase = NoteFile(id: "J5", body: "r0").serialized()
        _ = NoteStore.create(resumedBase, at: resumedNote, root: root)
        NoteJournal.snapshot(NoteJournal.Entry(noteID: "J5", path: resumedNote.path, base: resumedBase, text: NoteFile(id: "J5", body: "r1").serialized()), in: earlier)
        let leftovers = NoteJournal.leftovers(in: journal)
        expect(leftovers.count == 2 && leftovers.first?.lastPathComponent == "Notes journal, recovering 1" && !fm.fileExists(atPath: journal.path),
               "the journal and an unfinished recovery, oldest first", "\(leftovers.map(\.lastPathComponent))")
        for holding in leftovers { NoteJournal.recover(holding, root: root) }
        expect(text(hung) == typed && fm.fileExists(atPath: notes.appending(path: picture).path), "an accepted edit and its picture, written at launch",
               text(hung) ?? "nil")
        expect(text(renamedTo) == typed2, "a note renamed since: found by its id and written there")
        let reusedCopies = ((try? fm.contentsOfDirectory(atPath: notes.path)) ?? []).filter { (try? String(contentsOf: notes.appending(path: $0), encoding: .utf8)) == typed3 }
        expect(text(reused)?.contains("someone else's") == true && reusedCopies.count == 1, "another note at its old path: untouched, the words in a file of their own")
        expect(NoteFile.parse(text(resumedNote) ?? "", fallbackID: "", fallbackDate: Date()).body == "r1", "a resumed recovery finishes")
        expect(leftovers.allSatisfy { !fm.fileExists(atPath: $0.path) }, "recovered folders go once empty")

        // An entry is kept until its recovery wrote somewhere: with the notes' folder and Unsaved notes both shut, it stays.
        let shut = root.appending(path: "Shut")
        try? fm.createDirectory(at: shut, withIntermediateDirectories: true)
        let shutNote = shut.appending(path: "Shut.md")
        let shutBase = NoteFile(id: "J6", body: "s").serialized()
        _ = NoteStore.create(shutBase, at: shutNote, root: root)
        snap("J6", shutNote, shutBase, NoteFile(id: "J6", body: "s2").serialized(), [])
        let unsaved = Config.supportFolder.appending(path: "Unsaved notes")
        try? fm.createDirectory(at: unsaved, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: shut.path)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: unsaved.path)
        let again = NoteJournal.leftovers(in: journal)
        for holding in again { NoteJournal.recover(holding, root: root) }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shut.path)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unsaved.path)
        expect(again.count == 1 && fm.fileExists(atPath: again[0].path), "an entry whose recovery couldn't write anywhere is kept")
        for holding in NoteJournal.leftovers(in: journal) { NoteJournal.recover(holding, root: root) }
        expect(NoteFile.parse(text(shutNote) ?? "", fallbackID: "", fallbackDate: Date()).body == "s2", "and written on the next launch", text(shutNote) ?? "nil")
    }

    /// Two notes of one title made at once by tools: each its own file and its own answer.
    /// A new note whose name is taken on disk lands under another; it never takes the name another note being made
    /// was shown with, so each keeps its own session and answer.
    @MainActor static func renamedMakes(root: URL) {
        let folder = root.appending(path: "Renamed")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("someone else's".utf8).write(to: folder.appending(path: "Renamed.md"))
        let store = NoteStore(root: root)
        store.preview([], notebooks: [Notebook(name: "Renamed", folder: folder, color: "", cover: nil, count: 0)])
        var answers: [(name: String, id: String)] = []
        var ids: [String] = []
        for _ in 0..<2 {
            let file = NoteFile(body: "# Renamed")
            ids.append(file.id)
            _ = store.make(file, in: "Renamed", live: { true }) { made in answers.append((made?.url.lastPathComponent ?? "none", made?.noteID ?? "")) }
        }
        let until = Date().addingTimeInterval(5)
        while answers.count < 2 && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        expect(Set(answers.map(\.name)) == ["Renamed 2.md", "Renamed 3.md"] && Set(answers.map(\.id)) == Set(ids),
               "a name taken on disk: each note lands on its own name, with its own answer", "\(answers)")
        expect(NoteReservations.names(in: folder.path.lowercased(), except: nil).isEmpty, "and their names are free again")

        // A conflict copy for an asker who went: nothing is made.
        let original = folder.appending(path: "Renamed.md")
        let before = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count
        expect(NoteStore.keepBeside("late", original: original, root: root, live: { false }) == .cancelled
               && (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count == before, "a copy for a request that ended: none")
    }

    /// Every change checks the file is still the note it means: a path another note now has is never written,
    /// moved, stuck or trashed. And file names are made from titles only after redaction.
    @MainActor static func identity(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Identity")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // A's file was renamed elsewhere, and B now has A's old path; A's session still points there.
        let reused = folder.appending(path: "Reused.md")
        let theirs = NoteFile(id: "B", body: "# B\nB's words").serialized()
        _ = NoteStore.create(theirs, at: reused, root: root)
        NoteDisk.states[901] = NoteDisk.State(url: reused, noteID: "A", revision: theirs)
        let live: @Sendable () -> Bool = { true }
        let mine = NoteFile(id: "A", body: "# A\nA's words").serialized()
        expect(NoteStore.perform(.write(text: mine, base: theirs), session: 901, root: root, live: live).outcome == .notThisNote && text(reused) == theirs,
               "a tool's write to a reused path: refused, the other note untouched")
        var stuck = NoteFile.parse(mine, fallbackID: "A", fallbackDate: Date())
        stuck.places = [NoteStick(kind: .desktop)]
        expect(NoteStore.perform(.write(text: stuck.serialized(), base: theirs), session: 901, root: root, live: live).outcome == .notThisNote
               && text(reused) == theirs, "sticking it somewhere (its places written) at a reused path: refused")
        let person = NoteStore.perform(.write(text: mine, base: theirs), session: 901, root: root)
        if case .keptBoth(let copy) = person.outcome {
            expect(text(reused) == theirs && text(copy) == mine, "the person's typing at a reused path: kept beside, the other note untouched")
        } else { expect(false, "the person's typing at a reused path: kept beside", "\(person.outcome)") }
        expect(NoteStore.perform(.move(folder: root.appending(path: "Elsewhere")), session: 901, root: root).outcome != .written
               && text(reused) == theirs && !fm.fileExists(atPath: root.appending(path: "Elsewhere/Reused.md").path), "a move of a reused path: refused, nothing moved")
        _ = NoteStore.perform(.trash(revision: theirs), session: 901, root: root)
        expect(text(reused) == theirs, "a trash of a reused path: refused")

        // File names never hold a secret: made from the redacted title; unreadable, a plain name; and recorded.
        NoteStore.nameRedactor = { $0.replacingOccurrences(of: "4111111111111111", with: "(hidden)") }
        let card = NoteFile(id: "C1", body: "# Card 4111111111111111 for travel").serialized()
        let named = NoteStore.createNamed(card, stem: NoteStore.safeStem(for: card, fallback: "Note 1"), in: folder, root: root)
        expect(named?.lastPathComponent == "Card (hidden) for travel.md", "a title holding a secret: the file named after redaction", named?.lastPathComponent ?? "nil")
        NoteStore.nameRedactor = { _ in nil }
        let plain = NoteStore.createNamed(card, stem: NoteStore.safeStem(for: card, fallback: "Note 1"), in: folder, root: root)
        expect(plain?.lastPathComponent == "Note 1.md", "the vault unreadable: a plain name", plain?.lastPathComponent ?? "nil")
        if case .keptBoth(let copy) = NoteStore.keepBeside(card, original: reused, root: root) {
            expect(!copy.lastPathComponent.contains("4111") && !copy.lastPathComponent.contains("Reused"), "a conflict copy named from its own redacted title", copy.lastPathComponent)
        }
        expect(!((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.contains("4111") }, "no file name anywhere holds the card number")
        NoteStore.nameRedactor = { $0 }

        // A trash never of an existing file Petal can't read to check (absence and unreadability told apart).
        let locked = folder.appending(path: "Locked.md")
        let lockedText = NoteFile(id: "L1", body: "# Locked").serialized()
        _ = NoteStore.create(lockedText, at: locked, root: root)
        NoteDisk.states[902] = NoteDisk.State(url: locked, noteID: "L1", revision: lockedText)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        _ = NoteStore.perform(.trash(revision: lockedText), session: 902, root: root)
        let stillThere = fm.fileExists(atPath: locked.path)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        expect(stillThere && text(locked) == lockedText, "an unreadable file at a note's path: never trashed")

        // A tool's handle: kept per note id, the same when the note's file is renamed or moved, and when an id-less
        // note is given its own id.
        var local = NoteLocal()
        let handle = local.handle("H1")
        expect(handle.hasPrefix("n") && !handle.contains("H1") && local.handle("H1") == handle, "a note's handle: a token, the same each time")
        expect(handle.dropFirst().allSatisfy { $0.isLetter }, "a handle is letters only", handle)
        let plainHolder = NoteShelf.holderKey(id: "file:Inbox/Plain.md", instance: "1:10")
        let firstLook = local.handle(plainHolder)
        expect(local.handle(NoteShelf.holderKey(id: "file:Inbox/Plain.md", instance: "1:22")) != firstLook,
               "a new file at an id-less note's path gets a handle of its own")
        local.rekeyID("file:Inbox/Plain.md", holder: plainHolder, "U2")
        expect(local.handle("U2") == firstLook && local.handles?[plainHolder] == nil, "an id-less note given its id keeps its handle, and its path's is retired")
    }

    /// Moves copy then commit: Petal stopping after any step leaves no broken link; a listing or read failure refuses
    /// the move; leftovers are swept only once verified; a folder is trashed only when verified empty.
    @MainActor static func copyThenCommit(root: URL) {
        let fm = FileManager.default
        func linksHold(_ note: URL) -> Bool {
            guard let text = text(note) else { return false }
            return NoteShelf.referencedPictures(text).allSatisfy { fm.fileExists(atPath: note.deletingLastPathComponent().appending(path: $0).path) }
        }
        func make(_ name: String, id: String) -> (note: URL, assets: URL) {
            let folder = root.appending(path: name)
            let assets = folder.appending(path: NoteShelf.assetsFolder(id: id))
            try? fm.createDirectory(at: assets, withIntermediateDirectories: true)
            try? Data("pic-\(id)".utf8).write(to: assets.appending(path: "p.png"))
            let note = folder.appending(path: "Note.md")
            _ = NoteStore.create(NoteFile(id: id, body: "# \(id)\n![](\(assets.lastPathComponent)/p.png)").serialized(), at: note, root: root)
            return (note, assets)
        }
        // Stopped right after the copy: the note where it was, its links holding (a duplicate where it was going).
        let a = make("CTC-A", id: "CA")
        expect(NoteStore.move(a.note, noteID: "CA", into: root.appending(path: "CTC-Dest-A"), root: root, stop: { $0 == .copied }) == nil
               && linksHold(a.note), "stopped after the copy: the note where it was, its pictures there")
        // Stopped right after the Markdown moved: the note where it went, its links holding (the originals left behind).
        let b = make("CTC-B", id: "CB")
        let landed = NoteStore.move(b.note, noteID: "CB", into: root.appending(path: "CTC-Dest-B"), root: root, stop: { $0 == .committed })
        expect(landed.map(linksHold) == true && fm.fileExists(atPath: b.assets.appending(path: "p.png").path),
               "stopped after the commit: the note where it went, its pictures there, the originals still behind")
        // The next launch's sweep: the leftovers go once their note is verifiably elsewhere with its own copy.
        NoteStore.sweepLeftovers(root: root)
        expect(!fm.fileExists(atPath: b.assets.path) && landed.map(linksHold) == true, "swept: the leftover folder gone, the note's links still holding")
        // A leftover whose note's copy has other bytes: kept.
        let c = make("CTC-C", id: "CC")
        let landedC = NoteStore.move(c.note, noteID: "CC", into: root.appending(path: "CTC-Dest-C"), root: root, stop: { $0 == .committed })
        try? Data("changed".utf8).write(to: (landedC ?? c.note).deletingLastPathComponent().appending(path: c.assets.lastPathComponent + "/p.png"))
        NoteStore.sweepLeftovers(root: root)
        expect(fm.fileExists(atPath: c.assets.appending(path: "p.png").path), "a leftover not verified (other bytes elsewhere): kept")
        // The whole move: the originals and their folder go only after the commit, the folder only when verified empty.
        let d = make("CTC-D", id: "CD")
        let landedD = NoteStore.move(d.note, noteID: "CD", into: root.appending(path: "CTC-Dest-D"), root: root)
        expect(landedD.map(linksHold) == true && !fm.fileExists(atPath: d.assets.path), "a whole move: the note and its pictures there, nothing left behind")
        // A pictures' folder that can't be listed, or a picture that can't be read: the move refused.
        let e = make("CTC-E", id: "CE")
        try? fm.setAttributes([.posixPermissions: 0o311], ofItemAtPath: e.assets.path)
        let unlisted = NoteStore.move(e.note, noteID: "CE", into: root.appending(path: "CTC-Dest-E"), root: root) == nil
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: e.assets.path)
        expect(unlisted && linksHold(e.note) && fm.fileExists(atPath: e.assets.appending(path: "p.png").path), "its pictures can't be listed: refused, nothing moved")
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: e.assets.appending(path: "p.png").path)
        let unread = NoteStore.move(e.note, noteID: "CE", into: root.appending(path: "CTC-Dest-E"), root: root) == nil
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: e.assets.appending(path: "p.png").path)
        expect(unread && linksHold(e.note), "a picture that can't be read: refused, nothing moved")
    }

    /// A move queued after a flush that was kept beside the file (changed elsewhere meanwhile): stopped and said; and a
    /// pictures' folder another paper beside it links never moves away from it.
    @MainActor static func moveAfterConflict(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "MoveConflict")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Shared.md")
        let original = NoteFile(id: "MC1", body: "# Shared\nmine").serialized()
        _ = NoteStore.create(original, at: file, root: root)
        let store = NoteStore(root: root)
        let read = NoteStore.read(root)
        store.preview(read.notes, notebooks: read.notebooks)
        var said = ""
        store.onProblem = { said = $0 }
        guard let paper = store.notes.first(where: { $0.noteID == "MC1" }) else { return expect(false, "read") }
        // Changed elsewhere after it was read: the next save keeps both.
        try? Data(NoteFile(id: "MC1", body: "# Shared\ntheirs").serialized().utf8).write(to: file)
        _ = store.change(paper.key) { $0.body += "\nmore" }
        var moved: PaperNote?? = .none
        store.move(paper.key, to: "Elsewhere", then: { moved = .some($0) })
        let until = Date().addingTimeInterval(5)
        while moved == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        expect((moved ?? nil) == nil && fm.fileExists(atPath: file.path) && !fm.fileExists(atPath: root.appending(path: "Elsewhere/Shared.md").path)
               && said.contains("wasn't moved"), "the move stops after the flush was kept beside, and says so", said)

        // A conflict copy beside it links its pictures' folder: the note's move never takes the folder away.
        let assets = folder.appending(path: NoteShelf.assetsFolder(id: "MC2"))
        try? fm.createDirectory(at: assets, withIntermediateDirectories: true)
        try? Data("p".utf8).write(to: assets.appending(path: "p.png"))
        let note = folder.appending(path: "Pictured.md")
        _ = NoteStore.create(NoteFile(id: "MC2", body: "![](\(assets.lastPathComponent)/p.png)").serialized(), at: note, root: root)
        _ = NoteStore.create(NoteFile(id: "MC2", body: "copy ![](\(assets.lastPathComponent)/p.png)").serialized(), at: folder.appending(path: "Pictured (conflicted copy).md"), root: root)
        expect(NoteStore.move(note, noteID: "MC2", into: root.appending(path: "Elsewhere"), root: root) == nil && fm.fileExists(atPath: assets.appending(path: "p.png").path),
               "a pictures' folder another paper links: not moved")

        // The same with the other paper named `.MD`, and with a sibling that can't be read.
        let upper = root.appending(path: "UpperCase")
        let upperAssets = upper.appending(path: NoteShelf.assetsFolder(id: "MC3"))
        try? fm.createDirectory(at: upperAssets, withIntermediateDirectories: true)
        try? Data("p".utf8).write(to: upperAssets.appending(path: "p.png"))
        let upperNote = upper.appending(path: "Pictured.md")
        _ = NoteStore.create(NoteFile(id: "MC3", body: "![](\(upperAssets.lastPathComponent)/p.png)").serialized(), at: upperNote, root: root)
        let shouty = upper.appending(path: "Copy.MD")
        _ = NoteStore.create(NoteFile(id: "MC3", body: "copy ![](\(upperAssets.lastPathComponent)/p.png)").serialized(), at: shouty, root: root)
        expect(NoteStore.move(upperNote, noteID: "MC3", into: root.appending(path: "Elsewhere"), root: root) == nil && fm.fileExists(atPath: upperAssets.appending(path: "p.png").path),
               "a `.MD` sibling linking its pictures: not moved")
        try? fm.removeItem(at: shouty)
        let locked = upper.appending(path: "Locked.md")
        try? Data("unrelated".utf8).write(to: locked)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let stopped = NoteStore.move(upperNote, noteID: "MC3", into: root.appending(path: "Elsewhere"), root: root) == nil
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        expect(stopped && fm.fileExists(atPath: upperNote.path), "a sibling that can't be read: the move stops safely")
        try? fm.removeItem(at: locked)
        expect(NoteStore.move(upperNote, noteID: "MC3", into: root.appending(path: "Elsewhere"), root: root) != nil, "nothing else beside it: it moves")

        // Its folder can't be listed (readable files, no listing): the move is refused, nothing moves.
        let unlisted = root.appending(path: "Unlisted")
        let unlistedAssets = unlisted.appending(path: NoteShelf.assetsFolder(id: "MC4"))
        try? fm.createDirectory(at: unlistedAssets, withIntermediateDirectories: true)
        try? Data("p".utf8).write(to: unlistedAssets.appending(path: "p.png"))
        let unlistedNote = unlisted.appending(path: "Hidden.md")
        _ = NoteStore.create(NoteFile(id: "MC4", body: "![](\(unlistedAssets.lastPathComponent)/p.png)").serialized(), at: unlistedNote, root: root)
        try? fm.setAttributes([.posixPermissions: 0o311], ofItemAtPath: unlisted.path)
        let refused = NoteStore.move(unlistedNote, noteID: "MC4", into: root.appending(path: "Elsewhere"), root: root) == nil
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unlisted.path)
        expect(refused && fm.fileExists(atPath: unlistedNote.path) && fm.fileExists(atPath: unlistedAssets.appending(path: "p.png").path),
               "siblings that can't be listed: the move refused, nothing moved")
    }

    /// A file and its iCloud version with another id: one conflict, both papers read only with Keep this one.
    @MainActor static func versionGroups(root: URL) {
        let url = root.appending(path: "Groups/T.md")
        let current = PaperNote(file: NoteFile(id: "MAC-A", body: "mine"), url: url, notebook: "Groups", revision: "mine")
        var version = PaperNote(file: NoteFile(id: "MAC-B", body: "theirs"), url: url, notebook: "Groups", revision: "theirs")
        version.version = "v1"
        let other = PaperNote(file: NoteFile(id: "MAC-C", body: "other"), url: root.appending(path: "Groups/U.md"), notebook: "Groups", revision: "other")
        let store = NoteStore(root: root)
        store.preview([current, version, other], notebooks: [])
        expect(store.conflict(of: current)?.count == 2 && store.conflict(of: version)?.count == 2, "the file and its version: one group")
        expect(store.readOnly(current) && store.readOnly(version) && !store.readOnly(other), "both shown read only with Keep this one; others not")
    }

    /// Nothing lasting for an id-less note before its own id is in its file: a paste waits for it, records of it stay
    /// in memory, and a write that can't land fails closed.
    @MainActor static func idFirst(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "IdFirst")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Plain.md")
        try? Data("# Plain\nwords".utf8).write(to: file)
        let store = NoteStore(root: root)
        var read = NoteStore.read(root)
        store.preview(read.notes, notebooks: read.notebooks)
        guard let paper = store.notes.first(where: { $0.notebook == "IdFirst" && $0.url.lastPathComponent == "Plain.md" }) else { return expect(false, "read") }
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        expect(store.beginImport(paper.key, NoteImport(files: [], png: png, tiff: nil, at: -1)) == nil, "a paste on an id-less note isn't recorded by its path's id")
        var given: String??
        store.ensureID(paper.key) { given = .some($0) }
        let until = Date().addingTimeInterval(5)
        while given == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let id = given ?? nil
        let written = text(file).map { NoteFile.parse($0, fallbackID: "?", fallbackDate: Date()).id }
        expect(id != nil && written == id && store.pendingIDs.isEmpty, "its id written into its file first, then told", "\(String(describing: id)) \(String(describing: written))")
        if let now = store.notes.first(where: { $0.noteID == id }) {
            let begun = store.beginImport(now.key, NoteImport(files: [], png: png, tiff: nil, at: -1))
            expect(begun != nil, "then the paste is recorded, by the real id")
            if let begun, let id { store.endImport(id, begun.token, journal: true) }
        }

        // A write that can't land: fail closed (no id told, nothing lasting kept by it).
        let locked = root.appending(path: "IdLocked")
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try? Data("# Locked\nwords".utf8).write(to: locked.appending(path: "Stuck.md"))
        read = NoteStore.read(root)
        store.preview(read.notes, notebooks: read.notebooks)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.appending(path: "Stuck.md").path)
        var refused: String??
        if let stuck = store.notes.first(where: { $0.notebook == "IdLocked" }) {
            store.ensureID(stuck.key) { refused = .some($0) }
            let until = Date().addingTimeInterval(5)
            while refused == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.appending(path: "Stuck.md").path)
        let pendingID = store.notes.first(where: { $0.notebook == "IdLocked" })?.noteID ?? ""
        expect(refused != nil && (refused ?? "x") == nil && store.pendingIDs.contains(pendingID), "its id couldn't be written: none told, still pending")
        var local = NoteLocal()
        _ = local.handle(pendingID)
        _ = local.handle(NoteShelf.holderKey(id: "file:Inbox/x.md", instance: "1:2"))
        local.shown = [pendingID, "file:Inbox/x.md", "REAL"]
        _ = local.handle("REAL")
        let kept = local.persisted(pending: store.pendingIDs)
        expect(kept.handles?.keys.sorted() == ["REAL"] && kept.shown == ["REAL"], "only records by a real id in its file are written to disk",
               "\(String(describing: kept.handles?.keys.sorted())) \(kept.shown)")
    }

    /// An id given to an id-less note is an event every holder follows: a paste being read, the journal, the store's
    /// lookups (the editor's rule is NoteShelf.editorKeeps, checked pure).
    @MainActor static func identityFollowed(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Follow")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Loose.md")
        try? Data("# Loose\nwords".utf8).write(to: file)
        let store = NoteStore(root: root)
        let read = NoteStore.read(root)
        store.preview(read.notes, notebooks: read.notebooks)
        guard let paper = store.notes.first(where: { $0.url.lastPathComponent == "Loose.md" }) else { return expect(false, "the id-less note is read") }
        let old = paper.noteID
        // A paste on it is refused until its id is in; the note is changed (and so given its id).
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:])
        let begun = store.beginImport(paper.key, NoteImport(files: [], png: png, tiff: nil, at: -1))
        _ = store.change(paper.key) { $0.body += "\nmore" }
        let new = store.currentID(old, instance: paper.instance)
        NoteJournal.queue.sync {}
        let entry = NoteJournal.read(NoteJournal.file(new))
        expect(begun == nil, "a paste on an id-less note waits for its id (never recorded by its path's id)")
        expect(new != old && !NoteShelf.needsID(new), "the note is given its own id", new)
        expect(!fm.fileExists(atPath: NoteJournal.file(old).path) && entry?.text.contains("more") == true, "the journal entry is the new id's, with the typing")
        expect(store.sameNote(old, instance: paper.instance, new), "an editor holding the old id keeps its typing")
        if let begun { store.endImport(new, begun.token, journal: true) }
        NoteJournal.queue.sync {}
        expect(!paper.instance.isEmpty, "the file's instance is read with the folder")

        // The note moves away; a new id-less file appears at its old path: never the moved note.
        var answered = false
        store.move(paper.key, to: "Away", then: { _ in answered = true })
        let until = Date().addingTimeInterval(5)
        while !answered && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        try? Data("# Loose\nsomeone else's".utf8).write(to: file)
        let again = NoteStore.read(root).notes.first { $0.notebook == "Follow" && $0.url.lastPathComponent == "Loose.md" }
        expect(again != nil && again?.noteID == old && again?.instance != paper.instance, "a new file at the old path, with the old path's id",
               "\(String(describing: again?.noteID)) \(String(describing: again?.instance)) was \(old) \(paper.instance); moved: \(FileManager.default.fileExists(atPath: root.appending(path: "Away/Loose.md").path))")
        expect(store.currentID(old, instance: again?.instance ?? "") == old, "its id never resolves to the moved note")
    }

    /// An id-less note (a Markdown file made elsewhere) gets its own id in its file before Petal moves or changes it.
    @MainActor static func idBeforeChange(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Plain")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Shopping.md")
        try? Data("# Shopping\nmilk".utf8).write(to: file)
        let store = NoteStore(root: root)
        let read = NoteStore.read(root)
        store.preview(read.notes, notebooks: read.notebooks)
        guard let paper = store.notes.first(where: { $0.url.lastPathComponent == "Shopping.md" }) else { return expect(false, "the id-less note is read") }
        expect(NoteShelf.needsID(paper.noteID), "read with an id taken from its path", paper.noteID)
        var renamed: (String, String)?
        store.onIdentity = { old, _, new in renamed = (old, new) }
        var moved: PaperNote?
        var answered = false
        store.move(paper.key, to: "Elsewhere", then: { moved = $0; answered = true })
        let until = Date().addingTimeInterval(5)
        while !answered && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let landed = root.appending(path: "Elsewhere/Shopping.md")
        let written = text(landed).map { NoteFile.parse($0, fallbackID: "?", fallbackDate: Date()) }
        expect(moved != nil && written != nil && !NoteShelf.needsID(written?.id ?? "file:") && written?.body.contains("milk") == true,
               "moved with its own id written in its file first", text(landed) ?? "nil")
        expect(renamed?.0 == paper.noteID && renamed?.1 == written?.id && store.notes.contains { $0.noteID == written?.id },
               "and every owner knows it by that id", "\(String(describing: renamed))")
    }

    @MainActor static func concurrentMakes(root: URL) {
        let store = NoteStore(root: root)
        store.preview([], notebooks: [Notebook(name: "Same", folder: root.appending(path: "Same"), color: "", cover: nil, count: 0)])
        var answers: [String] = []
        for _ in 0..<2 {
            _ = store.make(NoteFile(body: "# Same title"), in: "Same", live: { true }) { made in answers.append(made?.url.lastPathComponent ?? "none") }
        }
        let until = Date().addingTimeInterval(5)
        while answers.count < 2 && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        expect(Set(answers) == ["Same title.md", "Same title 2.md"], "two at once: two files, two answers", "\(answers)")
    }

    /// A tool's change whose asker went: nothing in memory, nothing on disk.
    @MainActor static func toolCancelled(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Tools")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Tool.md")
        let base = NoteFile(id: "T1", body: "the person's words").serialized()
        _ = NoteStore.create(base, at: file, root: root)
        let store = NoteStore(root: root)
        store.preview([PaperNote(file: NoteFile.parse(base, fallbackID: "", fallbackDate: Date()), url: file, notebook: "Tools", revision: base)], notebooks: [])
        let returned = store.change(file.path, live: { false }) { $0.body = "from a tool that went away" }
        expect(returned != nil && store.paper(file.path)?.file.body == "the person's words", "a tool's change shows nothing until it lands")
        NoteStore.io.sync {}
        NoteStore.io.sync {}
        expect(text(file) == base, "and, cancelled, leaves the file as it was")
    }

    static func finish() {
        print("note files: \(passed) passed" + (failures > 0 ? ", \(failures) failed" : ""))
        if failures > 0 { exit(1) }
    }
}
