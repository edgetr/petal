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

    /// The files' queue held right after the first read of the folder a store is entering, before anything that
    /// read starts is done there: queued behind the entering sequence's own steps (the files' queue for the drain,
    /// the journal's queue, the files' queue again for the recovery and the read).
    static func holdAfterFirstRead(_ hold: DispatchSemaphore) {
        NoteStore.io.async { NoteJournal.queue.async { NoteStore.io.async { hold.wait() } } }
    }

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
        picturesStay(root: root)
        pictureLinks(root: root)
        removeRefusedReadOnly(root: root)
        helperAnswerDrained(root: root)
        carriedOntoCopy(root: root)
        heldThroughKeptBoth(root: root)
        resultThroughConflict(root: root)
        coverPrivacy(root: root)
        caseMove(root: root)
        versionGroups(root: root)
        canvasFile(root: root)
        canvasRetry(root: root)
        canvasDrain(root: root)
        privateCovers(root: root)
        coverQuit(root: root)
        coverConflict(root: root)
        canvasWaitsForCovers(root: root)
        coverRoots(top: root.deletingLastPathComponent())
        listingErrors(root: root)
        notebookUncertain(root: root)
        coverConflictNames(root: root)
        keepPromotes(root: root)
        coverGroupsByFolder(root: root)
        renewalKeepsCanvas(root: root)
        duplicatedNotebook(root: root)
        renamedPrivateFolder(root: root)
        identicalRenewal(root: root)
        reconcileAfterKeep(root: root)
        lowercaseCover(root: root)
        rekeyKeepsSource(root: root)
        canvasByFolder(root: root)
        folderReplaced(root: root)
        deletedNotebookRescue(root: root)
        ambiguousRescue(root: root)
        ambiguousCovers(root: root)
        writeRechecksBinding(root: root)
        canvasOtherRoot(root: root)
        switchBackSavesCover(root: root)
        renewalSkipsOtherRoot(root: root)
        trashAfterSwitch(root: root)
        renewalAcrossSwitch(root: root)
        picturesSurviveSwitch(root: root)
        notReadyDuringRecovery(root: root)
        recoveredCoverLands(root: root)
        lateSaveDrained(root: root)
        notebookFolders(root: root)
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

        // A handwritten note linking a picture beside it: the move copies it to the same place where it lands (its
        // link holds) and never deletes the original; a different picture already there refuses the move.
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
               && text(clash.appending(path: "photo.png")) == "someone else's" && text(tripAssets.appending(path: "photo.png")) == "photo",
               "a different picture where it lands: the move refused, both pictures as they were")
        // The same bytes there already: nothing to copy, the move goes.
        let sameThere = root.appending(path: "Same/Trip.assets")
        try? fm.createDirectory(at: sameThere, withIntermediateDirectories: true)
        try? Data("photo".utf8).write(to: sameThere.appending(path: "photo.png"))
        let sameMove = NoteStore.move(handwritten, noteID: "HW", into: root.appending(path: "Same"), root: root)
        expect(sameMove != nil && text(sameThere.appending(path: "photo.png")) == "photo" && text(tripAssets.appending(path: "photo.png")) == "photo",
               "the same picture there already: the move goes, nothing deleted")
        _ = sameMove.flatMap { NoteStore.move($0, noteID: "HW", into: work, root: root) }
        // Two links to one picture spelled in different cases (one file on this volume): one copy, the move goes,
        // and no picture anywhere is deleted.
        let caseText = NoteFile(id: "HC", body: "# Case\n![](Trip.assets/photo.png)\n![](trip.assets/Photo.png)").serialized()
        let caseNote = work.appending(path: "Case.md")
        _ = NoteStore.create(caseText, at: caseNote, root: root)
        let caseMove = NoteStore.move(caseNote, noteID: "HC", into: root.appending(path: "CaseLand"), root: root)
        expect(caseMove != nil && text(root.appending(path: "CaseLand/Trip.assets/photo.png")) == "photo" && text(tripAssets.appending(path: "photo.png")) == "photo",
               "case-variant links: copied once, the original kept")
        let landedHW = NoteStore.move(handwritten, noteID: "HW", into: root.appending(path: "Carried"), root: root)
        expect(landedHW != nil && text(root.appending(path: "Carried/Trip.assets/photo.png")) == "photo" && text(landedHW!) == handText
               && text(tripAssets.appending(path: "photo.png")) == "photo", "moved with its picture copied along, its text unchanged, the original left for others")

        // Petal's own pictures live in the notes' Pictures, one folder per note: a move takes only the Markdown, the
        // pictures stay exactly where they were, and the note's links resolve the same from its new notebook.
        let ownPicture = root.appending(path: NoteShelf.pictureFolder(id: "P5") + "/picture-1.png")
        expect(first.pictures.first?.path == NoteShelf.pictureLink(id: "P5", name: "picture-1.png") && first.pictures.first?.path.hasPrefix("../Pictures/") == true
               && text(ownPicture) == "png" && !fm.fileExists(atPath: work.appending(path: "Pictures").path),
               "a picture's bytes go to the notes' Pictures, never beside the note", first.pictures.first?.path ?? "nil")
        let illustrated = NoteFile(id: "P5", body: "p0\n![](\(NoteShelf.pictureLink(id: "P5", name: "picture-1.png")))").serialized()
        try? Data(illustrated.utf8).write(to: pictureNote)
        let picturesBefore = (try? fm.contentsOfDirectory(atPath: root.appending(path: NoteShelf.pictureFolder(id: "P5")).path)) ?? []
        let moved = NoteStore.move(pictureNote, noteID: "P5", into: root.appending(path: "Away"), root: root)
        let resolvesFrom = { (note: URL) in
            NoteShelf.referencedPictures(text(note) ?? "").allSatisfy { link in
                NoteShelf.resolvedLink(link, from: note.deletingLastPathComponent().path).map { fm.fileExists(atPath: $0) } == true
            }
        }
        expect(moved != nil && text(moved!) == illustrated && text(ownPicture) == "png"
               && ((try? fm.contentsOfDirectory(atPath: root.appending(path: NoteShelf.pictureFolder(id: "P5")).path)) ?? []) == picturesBefore
               && !fm.fileExists(atPath: root.appending(path: "Away/Pictures").path) && moved.map(resolvesFrom) == true,
               "a move leaves its pictures untouched, and its links still resolve from the new notebook")
        expect(!NoteStore.read(root).notebooks.contains { $0.name.compare("Pictures", options: .caseInsensitive) == .orderedSame },
               "the notes' Pictures is never a notebook")
        // Trashing a note leaves its pictures alone.
        if let moved {
            NoteDisk.states[55] = NoteDisk.State(url: moved, noteID: "P5", revision: illustrated)
            _ = NoteStore.perform(.trash(revision: illustrated), session: 55, root: root)
            expect(!fm.fileExists(atPath: moved.path) && text(ownPicture) == "png", "a trashed note's pictures stay")
        }

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
        let reference = NoteShelf.pictureLink(id: "S3", name: "picture-u.png")
        let kept = NoteFile(id: "S3", body: "# Rescued words\nkeep me\n![](\(reference))")
        NoteStore.drain([(session: 3, items: [item(21, .pictureBytes([NotePictureBytes(name: "picture-u.png", data: Data("u".utf8), caption: "")], noteID: "S3")),
                                              item(20, .write(text: kept.serialized(), base: s0))])], root: root)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.path)
        // Each rescue in a folder of its own in Unsaved notes.
        let unsaved = Config.supportFolder.appending(path: "Unsaved notes")
        let rescuedFile = ((try? fm.contentsOfDirectory(atPath: unsaved.path)) ?? []).map { unsaved.appending(path: $0 + "/Note/Rescued words.md") }
            .first { fm.fileExists(atPath: $0.path) }
        expect(rescuedFile.flatMap(text)?.contains("keep me") == true, "writing that can't land by quit is kept in Unsaved notes, in a folder of its own")
        expect(rescuedFile.flatMap { NoteShelf.resolvedLink(reference, from: $0.deletingLastPathComponent().path) }.map { text(URL(fileURLWithPath: $0)) == "u" } == true,
               "with the pictures it references, where its references point (its own Pictures beside it)")
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
               && withPicture.text.contains(NoteShelf.pictureLink(id: "JI", name: withPicture.pictures.first?.name ?? "?")),
               "read at the next launch: a picture and its line, on the text that was there")
        expect(NoteJournal.recoverEntry(withPicture, notes: NoteStore.read(root).notes, root: root) != nil
               && text(pasted) == withPicture.text
               && fm.fileExists(atPath: root.appending(path: NoteShelf.pictureFolder(id: "JI") + "/" + (withPicture.pictures.first?.name ?? "?")).path),
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
        expect(NoteJournal.putIn(held, token: 7, root: root).stored && text(rejected)?.contains(NoteShelf.pictureLink(id: "JR", name: "")) == true,
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
        expect(stored && left == [waitingOne] && text(partial)?.contains(NoteShelf.pictureLink(id: "JQ", name: "")) == true && landedText == text(partial),
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
        // The rescue's own folder: the note in "Note", its pictures in "Pictures/<hash>" beside it.
        let unsavedFolder = rest?.landedAt.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent() } ?? Config.supportFolder
        expect(rest?.landedAt?.contains("Unsaved notes") == true && rest?.pictures.count == 1 && rest?.imports?.count == 1 && text(lockedNote) == tripText,
               "landed in Unsaved notes: the rest continues there, the first picture's bytes kept", "\(String(describing: rest?.landedAt))")
        try? png?.write(to: later)
        NoteJournal.recover(holding, root: root)
        let continued = rest?.landedAt.flatMap { text(URL(fileURLWithPath: $0)) } ?? ""
        let pictureFiles = (try? fm.contentsOfDirectory(atPath: unsavedFolder.appending(path: NoteShelf.pictureFolder(id: "JU")).path)) ?? []
        expect(continued.components(separatedBy: "![").count == 3 && pictureFiles.count == 2 && text(lockedNote) == tripText,
               "the rest continues in that same file, both pictures where its links lead, the note untouched", "\(pictureFiles) \(continued)")
        expect(URL(fileURLWithPath: rest?.landedAt ?? "/").deletingLastPathComponent().lastPathComponent == "Note"
               && NoteShelf.referencedPictures(continued).allSatisfy { link in
                   NoteShelf.resolvedLink(link, from: URL(fileURLWithPath: rest?.landedAt ?? "/").deletingLastPathComponent().path).map { fm.fileExists(atPath: $0) } == true
               }, "every link of the rescued note resolves inside its rescue folder")
        expect(!fm.fileExists(atPath: NoteJournal.file("JU", in: holding).path), "and the entry goes once it's all there")

        // A rescue into Unsaved notes carries the note's older pictures too (copied from the notes' Pictures, where
        // its links lead), laid out the same beside it, and isn't complete without them.
        let illustratedFolder = root.appending(path: "Illustrated")
        try? fm.createDirectory(at: illustratedFolder, withIntermediateDirectories: true)
        let oldAssets = root.appending(path: NoteShelf.pictureFolder(id: "RS"))
        try? fm.createDirectory(at: oldAssets, withIntermediateDirectories: true)
        try? png?.write(to: oldAssets.appending(path: "old.png"))
        let rescuedText = NoteFile(id: "RS", body: "# Illustrated\n![](\(NoteShelf.pictureLink(id: "RS", name: "old.png")))\n![](\(NoteShelf.pictureLink(id: "RS", name: "new.png")))").serialized()
        let newBytes = NotePictureBytes(name: "new.png", data: png ?? Data(), caption: "")
        let rescuedTo = NoteStore.rescued(rescuedText, noteID: "RS", pictures: [newBytes], from: illustratedFolder)
        let rescueAssets = (rescuedTo?.deletingLastPathComponent().deletingLastPathComponent() ?? Config.supportFolder).appending(path: NoteShelf.pictureFolder(id: "RS"))
        expect(rescuedTo != nil && fm.fileExists(atPath: rescueAssets.appending(path: "old.png").path) && fm.fileExists(atPath: rescueAssets.appending(path: "new.png").path)
               && fm.fileExists(atPath: oldAssets.appending(path: "old.png").path),
               "the older picture copied with the new one, into the rescue's own Pictures; the original kept")
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
               && workRescue?.deletingLastPathComponent().lastPathComponent == "Note"
               && workRescue.flatMap { text($0.deletingLastPathComponent().appending(path: "Trip.assets/photo.png")) } == "work photo"
               && homeRescue.flatMap { text($0.deletingLastPathComponent().appending(path: "Trip.assets/photo.png")) } == "home photo",
               "two notes' pictures of one name: each rescue its own folder and its own picture")
        expect(NoteShelf.acceptExisting(existing: Data("a".utf8), wanted: Data("a".utf8)) && !NoteShelf.acceptExisting(existing: Data("a".utf8), wanted: Data("b".utf8))
               && !NoteShelf.acceptExisting(existing: nil, wanted: Data("a".utf8)), "an existing picture counts only when it's the same bytes")
        // A picture already where a recovery puts its own, with other bytes: never taken for it.
        let taken = root.appending(path: NoteShelf.pictureFolder(id: "TK"))
        try? fm.createDirectory(at: taken, withIntermediateDirectories: true)
        try? Data("someone else's".utf8).write(to: taken.appending(path: "p.png"))
        expect(NoteStore.writePictures([NotePictureBytes(name: "p.png", data: Data("mine".utf8), caption: "")], noteID: "TK", root: root).isEmpty
               && text(taken.appending(path: "p.png")) == "someone else's", "another picture by that name: not counted as written, and not written over")

        let gapText = NoteFile(id: "RG", body: "# Gap\n![](\(NoteShelf.pictureLink(id: "RG", name: "nowhere.png")))").serialized()
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
        let picture = NoteShelf.pictureLink(id: "J1", name: "picture-j.png")
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
        expect(text(hung) == typed && fm.fileExists(atPath: root.appending(path: NoteShelf.pictureFolder(id: "J1") + "/picture-j.png").path),
               "an accepted edit and its picture (in the notes' Pictures), written at launch",
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

    /// Remove (pictures that couldn't be saved) is refused on a read-only paper, its recovery bytes kept; on a
    /// note that can change, they go only once the note without their references has landed.
    /// A helper's answer (Petal's own change of metadata, NoteHelpers.write): in the notes journal the moment it's
    /// made, and on disk once quitting drains the session's work.
    @MainActor static func helperAnswerDrained(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Helped")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Helped.md")
        _ = NoteStore.create(NoteFile(id: "HJ1", body: "My words").serialized(), at: file, root: root)
        let store = NoteStore(root: root)
        let read = NoteStore.read(root)
        store.preview(read.notes, notebooks: read.notebooks)
        guard let paper = store.notes.first(where: { $0.noteID == "HJ1" }) else { return expect(false, "the note is read") }
        let made = store.change(paper.key, touch: false) { file in
            file.ink = [NoteHelp.Ink(who: "✦ Petal", text: "The answer")]
            file.helper = NoteHelp.Helper(state: .done, who: "✦ Petal", step: "", at: Date())
        }
        expect(made?.contains("The answer") == true && store.paper(paper.key)?.file.ink.first?.text == "The answer", "in memory at once")
        NoteJournal.queue.sync {}
        let journaled = NoteJournal.read(NoteJournal.file("HJ1"))
        expect(journaled?.text.contains("The answer") == true && journaled?.text.contains("My words") == true, "in the notes journal the moment it's made (a whole snapshot)")
        let drained = DispatchSemaphore(value: 0)
        store.drain { drained.signal() }
        let until = Date().addingTimeInterval(10)
        while drained.wait(timeout: .now()) == .timedOut && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        expect(text(file)?.contains("The answer") == true && text(file)?.contains("My words") == true, "drained at quit: the answer is on disk, with the person's words", text(file) ?? "nil")
    }

    /// A helper's output whose write was kept beside the file (`.keptBoth`) stays in the helpers' journal, held while
    /// the note is two papers, and is applied to the paper the person keeps; only a `.written` lets it go. A second
    /// opinion's result is held the same way.
    @MainActor static func heldThroughKeptBoth(root outer: URL) {
        let fm = FileManager.default
        let root = outer.appending(path: "HeldRoot")
        let folder = root.appending(path: "Held")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Held.md")
        _ = NoteStore.create(NoteFile(id: "HK1", body: "Mine").serialized(), at: file, root: root)
        let store = NoteStore(root: root)
        func reread() { let read = NoteStore.read(root); store.preview(read.notes, notebooks: read.notebooks) }
        func settle(_ until: () -> Bool) {
            let end = Date().addingTimeInterval(10)
            while !until() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        reread()
        guard let paper = store.notes.first(where: { $0.noteID == "HK1" }) else { return expect(false, "the note is read") }
        // The answer and a second opinion's result, journaled as made.
        var answer = paper.file
        answer.ink = [NoteHelp.Ink(who: "✦ Petal", text: "The answer"),
                      NoteHelp.Ink(who: "GPT", text: "A hole", objections: 1)]
        answer.helper = NoteHelp.Helper(state: .done, who: "✦ Petal", step: "", at: Date())
        let entry = HelperJournal.Entry(noteID: "HK1", answer: answer.serialized(), at: Date())
        var journal = HelperJournal.adding(entry, to: [])
        let held = NoteFile.parse(entry.answer, fallbackID: "HK1", fallbackDate: entry.at)
        // Changed on another Mac before it lands: the write is kept beside the file.
        try? Data(NoteFile(id: "HK1", body: "Elsewhere").serialized().utf8).write(to: file)
        var outcome: NoteStore.Outcome?
        _ = store.change(paper.key, edit: { NoteHelp.applyAnswer(held, to: &$0) }, done: { outcome = $0 })
        settle { outcome != nil }
        guard case .keptBoth(let copy)? = outcome else { return expect(false, "the answer's write was kept beside the file", "\(String(describing: outcome))") }
        // The rule NoteHelpers keeps: an entry goes only when its write landed on the paper meant (`.written`).
        if outcome == .written { journal.removeAll { $0 == entry } }
        expect(journal == [entry], "kept beside the file (.keptBoth): still held in the journal")
        reread()
        let papers = store.notes.filter { $0.noteID == "HK1" }
        expect(NoteHelp.answerTarget(papers: papers.count, readOnly: papers.first.map(store.readOnly) ?? true) == .hold,
               "two papers now: held, not written to either", "\(papers.count)")
        // The person keeps the file the other Mac wrote: the copy goes, the note is one paper again.
        try? fm.removeItem(at: copy)
        reread()
        guard let kept = store.notes.first(where: { $0.noteID == "HK1" }) else { return expect(false, "the kept paper is read") }
        expect(NoteHelp.answerTarget(papers: store.notes.filter { $0.noteID == "HK1" }.count, readOnly: store.readOnly(kept)) == .write,
               "one writable paper again: the held answer is applied")
        outcome = nil
        _ = store.change(kept.key, edit: { NoteHelp.applyAnswer(held, to: &$0) }, done: { outcome = $0 })
        settle { outcome != nil }
        if outcome == .written { journal.removeAll { $0 == entry } }
        expect(outcome == .written && journal.isEmpty, "landed on the kept paper (.written): let go", "\(String(describing: outcome))")
        let landed = text(file) ?? ""
        expect(landed.contains("Elsewhere") && landed.contains("The answer") && landed.contains("A hole"),
               "the kept paper has its own words, the answer and the second opinion's result", landed)
    }

    /// A run's result is one value through the journal and one based write (the store's own `change`, as NoteHelpers
    /// writes): a recalculation whose note went into conflict leaves no "done" without its formula, on either paper,
    /// and both land together on the paper kept. A reviewer's result, landing on a note whose answer changed on
    /// another Mac meanwhile, adds only its own opinion: the newer answer on disk stays as it is.
    @MainActor static func resultThroughConflict(root outer: URL) {
        let fm = FileManager.default
        let root = outer.appending(path: "ResultRoot")
        let folder = root.appending(path: "Results")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Sums.md")
        var working = NoteFile(id: "RS1", body: "Flights: 412\nHotel: 300")
        working.helper = NoteHelp.Helper(state: .working, who: "✦ Petal", step: "Working out the formula", at: Date())
        _ = NoteStore.create(working.serialized(), at: file, root: root)
        let store = NoteStore(root: root)
        func reread() { let read = NoteStore.read(root); store.preview(read.notes, notebooks: read.notebooks) }
        func settle(_ until: () -> Bool) {
            let end = Date().addingTimeInterval(10)
            while !until() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        reread()
        guard let paper = store.notes.first(where: { $0.noteID == "RS1" }) else { return expect(false, "the note is read") }
        // The recalculation's one result: its formula and `done`, journaled as one entry.
        let done = NoteHelp.Helper(state: .done, who: "✦ Petal", step: "", asked: "@Petal make this recalculate", at: Date())
        let result = NoteHelp.Result(answer: nil, calc: NoteHelp.Calc(label: "Total", formula: "sum()"), helper: .set(done))
        var journal = HelperJournal.adding(result, note: "RS1", notebook: "Results", sources: [], at: Date(), to: [])
        guard journal.count == 1 else { return expect(false, "a result is one journal entry") }
        let entry = journal[0]
        let held = NoteFile.parse(entry.answer, fallbackID: "RS1", fallbackDate: entry.at)
        // The note changes on another Mac before it lands: conflict.
        var elsewhere = working
        elsewhere.body = "Flights: 412\nHotel: 300\nTrain: 80"
        try? Data(elsewhere.serialized().utf8).write(to: file)
        var outcome: NoteStore.Outcome?
        _ = store.change(paper.key, edit: { NoteHelp.applyAnswer(held, to: &$0) }, done: { outcome = $0 })
        settle { outcome != nil }
        guard case .keptBoth(let copy)? = outcome else { return expect(false, "the result's write was kept beside the file", "\(String(describing: outcome))") }
        if outcome == .written { journal.removeAll { $0 == entry } }
        let original = NoteFile.parse(text(file) ?? "", fallbackID: "x", fallbackDate: Date())
        expect(original.calc == nil && original.helper?.state != .done, "in conflict: the note says neither done nor a formula", text(file) ?? "")
        let beside = NoteFile.parse(text(copy) ?? "", fallbackID: "x", fallbackDate: Date())
        expect((beside.calc != nil) == (beside.helper?.state == .done), "the copy kept beside it never has done without the formula either", text(copy) ?? "")
        expect(journal == [entry], "and the whole result is still held")
        // Keep this one (the other Mac's file): the held result lands whole, in one write.
        try? fm.removeItem(at: copy)
        reread()
        guard let kept = store.notes.first(where: { $0.noteID == "RS1" }) else { return expect(false, "the kept paper is read") }
        outcome = nil
        _ = store.change(kept.key, edit: { NoteHelp.applyAnswer(held, to: &$0) }, done: { outcome = $0 })
        settle { outcome != nil }
        let landed = NoteFile.parse(text(file) ?? "", fallbackID: "x", fallbackDate: Date())
        expect(outcome == .written && landed.calc?.formula == "sum()" && landed.helper?.state == .done && landed.body.contains("Train: 80"),
               "kept: the formula and done land together on the paper kept, its words as they were", text(file) ?? "")

        // A reviewer's result on a note whose answer was replaced from another Mac while it worked.
        let reviewedFile = folder.appending(path: "Reviewed.md")
        let first = NoteHelp.Ink(who: "✦ Petal", text: "It adds up to 712.")
        var before = NoteFile(id: "RS2", body: "Question")
        before.ink = [first]
        _ = NoteStore.create(before.serialized(), at: reviewedFile, root: root)
        reread()
        let opinion = NoteHelp.Result(opinion: NoteHelp.Ink(who: "GPT 6.1 Sol", text: "1. Is the train in it?", objections: 1), reviewed: NoteHelp.inkHash(first), helper: .keep)
        let newer = NoteHelp.Ink(who: "✦ Petal", text: "It adds up to 792, with the train.")
        var synced = before
        synced.ink = [newer]
        try? Data(synced.serialized().utf8).write(to: reviewedFile)
        reread()
        guard let reviewed = store.notes.first(where: { $0.noteID == "RS2" }) else { return expect(false, "the reviewed note is read") }
        outcome = nil
        _ = store.change(reviewed.key, edit: { opinion.apply(to: &$0) }, done: { outcome = $0 })
        settle { outcome != nil }
        let after = NoteFile.parse(text(reviewedFile) ?? "", fallbackID: "x", fallbackDate: Date()).ink
        expect(outcome == .written && after.count == 2 && after[0] == newer && after[1].who == "GPT 6.1 Sol" && after[1].opinion,
               "a reviewer's result on disk: the newer answer untouched, only its opinion added", text(reviewedFile) ?? "")
        expect(after.count == 2 && NoteHelp.reviewedEarlier(after[1], among: after) && after[1].heading(among: after).hasSuffix(NoteHelp.earlierWords),
               "and its opinion says it reviewed an earlier answer")
    }

    /// A session's writes after a conflict copy: the person's typing and a helper's metadata go in one snapshot (one
    /// based write: one copy, never two), and a later write made on it carries onto that copy, never a third paper.
    @MainActor static func carriedOntoCopy(root outer: URL) {
        let fm = FileManager.default
        // A notes folder of its own (nothing another check left behind).
        let root = outer.appending(path: "CarriedRoot")
        let folder = root.appending(path: "Carried")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Carried.md")
        _ = NoteStore.create(NoteFile(id: "CC1", body: "Before").serialized(), at: file, root: root)
        let store = NoteStore(root: root)
        let read = NoteStore.read(root)
        store.preview(read.notes, notebooks: read.notebooks)
        guard let paper = store.notes.first(where: { $0.noteID == "CC1" }), let base = paper.revision else { return expect(false, "the note is read") }
        // Changed on another Mac meanwhile.
        try? Data(NoteFile(id: "CC1", body: "Changed elsewhere").serialized().utf8).write(to: file)
        // The person's typing (on the base they typed on) and the helper's answer: one snapshot.
        _ = store.change(paper.key, base: base, edit: { file in
            file.body = "Typed here"
            file.ink = [NoteHelp.Ink(who: "✦ Petal", text: "First answer")]
        })
        // A later helper write, made on that snapshot.
        _ = store.change(paper.key, touch: false, edit: { file in file.helper = NoteHelp.Helper(state: .done, who: "✦ Petal", step: "", at: Date()) })
        let drained = DispatchSemaphore(value: 0)
        store.drain { drained.signal() }
        let until = Date().addingTimeInterval(10)
        while drained.wait(timeout: .now()) == .timedOut && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let papers = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
        expect(papers.count == 2, "one conflict copy, never a third paper", "\(papers)")
        let copy = papers.first { $0 != "Carried.md" }.map { folder.appending(path: $0) }
        expect(text(file)?.contains("Changed elsewhere") == true && text(file)?.contains("First answer") == false, "the other Mac's words stay in the file")
        expect(copy.flatMap(text)?.contains("Typed here") == true && copy.flatMap(text)?.contains("First answer") == true
               && copy.flatMap(text)?.contains("state: done") == true, "the typing, the answer and the later write all on the one copy", copy.flatMap(text) ?? "nil")
        // The rule itself.
        expect(NoteShelf.carryTarget(base: "t1", carried: ("/c.md", "t1", "C1"))?.path == "/c.md" && NoteShelf.carryTarget(base: "t1", carried: ("/c.md", "t1", "C1"))?.id == "C1"
               && NoteShelf.carryTarget(base: "t0", carried: ("/c.md", "t1", "C1")) == nil && NoteShelf.carryTarget(base: "t1", carried: nil) == nil,
               "a write made on what was kept beside the file goes there, checked against the copy's own id; any other, the file")
        // An identity write's conflict copy (a note with no id of its own given one, while its file changed elsewhere):
        // the next write carries onto that copy, checked against the copy's new id, never a third paper.
        let idless = root.appending(path: "Idless")
        try? fm.createDirectory(at: idless, withIntermediateDirectories: true)
        let handFile = idless.appending(path: "By hand.md")
        _ = NoteStore.create("Written by hand", at: handFile, root: root)
        let session = 9_000_001
        NoteDisk.states[session] = NoteDisk.State(url: handFile, noteID: NoteStore.noteID(of: "Written by hand", at: handFile, root: root), revision: "Written by hand")
        try? Data("Changed elsewhere".utf8).write(to: handFile)
        var given = NoteFile(id: "NEWID", body: "Written by hand")
        let withID = given.serialized()
        let identityWrite = NoteStore.perform(.write(text: withID, base: "Written by hand"), session: session, root: root)
        given.body = "Written by hand, and more"
        let next = NoteStore.perform(.write(text: given.serialized(), base: withID), session: session, root: root)
        let idlessPapers = ((try? fm.contentsOfDirectory(atPath: idless.path)) ?? []).filter { $0.hasSuffix(".md") }
        expect({ if case .keptBoth = identityWrite.outcome { return true } else { return false } }() && { if case .keptBoth = next.outcome { return true } else { return false } }()
               && idlessPapers.count == 2, "the identity write's copy takes the next write too: two papers, not three", "\(idlessPapers)")
        expect(idlessPapers.compactMap { text(idless.appending(path: $0)) }.contains { $0.contains("and more") && $0.contains("NEWID") } && text(handFile) == "Changed elsewhere",
               "the next write is on the copy (its new id); the file keeps what changed elsewhere")
        NoteDisk.states[session] = nil
    }

    /// Notebook privacy read from cover files only (Phase 3's rule), on real folders: the cover and its conflict copy
    /// count, `cover: true` in another file doesn't, an unreadable cover makes it unknown, another note doesn't.
    @MainActor static func coverPrivacy(root outer: URL) {
        let fm = FileManager.default
        let root = outer.appending(path: "CoverRoot")
        let write = { (book: String, name: String, file: NoteFile) in
            let folder = root.appending(path: book)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data(file.serialized().utf8).write(to: folder.appending(path: name))
        }
        var privateCover = NoteFile(id: "C1", body: "# About")
        privateCover.cover = true
        privateCover.set("private", .text("true"))
        var openCover = privateCover
        openCover.set("private", nil)
        write("Closed", "About this notebook.md", privateCover)
        write("Open", "About this notebook.md", openCover)
        write("Open", "Plan.md", NoteFile(id: "N1", body: "words"))
        write("Copy", "About this notebook.md", openCover)
        write("Copy", "About this notebook (conflicted copy).md", privateCover)
        write("Impostor", "About this notebook.md", openCover)
        write("Impostor", "Secret plan.md", privateCover)   // cover: true and private in another file: ignored
        write("Unreadable", "About this notebook.md", openCover)
        write("OtherUnread", "About this notebook.md", openCover)
        write("OtherUnread", "Locked note.md", NoteFile(id: "N2", body: "x"))
        let lockedCover = root.appending(path: "Unreadable/About this notebook.md")
        let lockedNote = root.appending(path: "OtherUnread/Locked note.md")
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedCover.path)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedNote.path)
        let books = NoteStore.read(root).notebooks
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedCover.path)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedNote.path)
        // Read by the store's one reading of a notebook's privacy (Phase 3's: isPrivate, privacyUnknown), which the
        // helpers ask through NotePrivacy.
        let isPrivate = { (name: String) in books.first { $0.name == name }?.isPrivate }
        let unknown = { (name: String) in books.first { $0.name == name }?.privacyUnknown }
        expect(isPrivate("Closed") == true && isPrivate("Open") == false, "a cover read: private or open")
        expect(isPrivate("Copy") == true, "a cover's conflict copy counts (one says private: private)")
        expect(isPrivate("Impostor") == true, "cover: true and private: true in a file that isn't the cover: not a cover, and its notebook isn't known to be open (it fails closed)",
               "\(String(describing: isPrivate("Impostor"))) \(String(describing: unknown("Impostor")))")
        expect(isPrivate("Unreadable") == true && unknown("Unreadable") == true, "an unreadable cover: unknown (private)")
        expect(isPrivate("OtherUnread") == false && unknown("OtherUnread") == false, "another note unreadable doesn't make it unknown")
        let privateBooks = NotePrivacy.privateBooks(notebooks: books.map { (name: $0.name, isPrivate: $0.isPrivate) }, held: ["Gone"])
        expect(!NotePrivacy.readable(notebook: "Closed", privateBooks: privateBooks, asker: "Open") && NotePrivacy.readable(notebook: "Closed", privateBooks: privateBooks, asker: "Closed")
               && NotePrivacy.readable(notebook: "Open", privateBooks: privateBooks, asker: nil) && !NotePrivacy.readable(notebook: "Gone", privateBooks: privateBooks, asker: nil),
               "what a helper may read follows: a Private (or unknown, or unread) notebook only from inside it")
    }

    @MainActor static func removeRefusedReadOnly(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Removal")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = "![](\(NoteShelf.pictureLink(id: "RM1", name: "bad.png")))"
        _ = NoteStore.create(NoteFile(id: "RM1", body: "words\n" + line).serialized(), at: folder.appending(path: "Kept.md"), root: root)
        _ = NoteStore.create(NoteFile(id: "RM1", body: "other words\n" + line).serialized(), at: folder.appending(path: "Kept (conflicted copy).md"), root: root)
        let line2 = "![](\(NoteShelf.pictureLink(id: "RM2", name: "bad.png")))"
        let single = folder.appending(path: "Single.md")
        _ = NoteStore.create(NoteFile(id: "RM2", body: "words\n" + line2).serialized(), at: single, root: root)
        let store = NoteStore(root: root)
        let read = NoteStore.read(root)
        store.preview(read.notes, notebooks: read.notebooks)
        let bad = NotePictureBytes(name: "bad.png", data: Data("bytes".utf8), caption: "")
        guard let conflicted = store.notes.first(where: { $0.noteID == "RM1" && $0.url.lastPathComponent == "Kept.md" }),
              let changeable = store.notes.first(where: { $0.noteID == "RM2" }) else { return expect(false, "the notes are read") }
        expect(store.readOnly(conflicted), "a conflict's paper is read only")
        store.setAside(conflicted.key, [bad])
        expect(!store.dropPictures(conflicted.key) && store.pictureTrouble[conflicted.key]?.count == 1
               && text(folder.appending(path: "Kept.md"))?.contains("bad.png") == true, "Remove refused on a read-only paper: nothing dropped")

        // A picture whose bytes can't be written (its folder is a file): set aside, its recovery bytes kept.
        let blocker = root.appending(path: NoteShelf.pictureFolder(id: "RM2"))
        try? fm.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("not a folder".utf8).write(to: blocker)
        guard let refs = store.acceptPictures(changeable.key, [("png", Data("bytes".utf8), "")]) else { return expect(false, "accepted") }
        let name = refs[0].file.lastPathComponent
        let until = Date().addingTimeInterval(5)
        while store.pictureTrouble[changeable.key] == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        expect(store.pictureTrouble[changeable.key]?.map(\.name) == [name] && store.keepsBytes("RM2", name), "set aside, its bytes kept for recovery")
        // Remove with an editor open: off the paper at once, no write of its own; the bytes go only when the editor's
        // save without the picture lands.
        let refLine = "![](\(refs[0].path))"
        _ = store.change(changeable.key) { $0.body += "\n" + refLine }
        let names = store.retirePictures(changeable.key, write: false)
        expect(names == [name] && store.pictureTrouble[changeable.key] == nil && store.keepsBytes("RM2", name), "Remove: off the paper, the bytes kept until it lands")
        _ = store.change(changeable.key) { $0.body = $0.body.replacingOccurrences(of: "\n" + refLine, with: "") }   // the editor's save
        while store.keepsBytes("RM2", name) && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        expect(!store.keepsBytes("RM2", name) && text(single)?.contains(name) == false, "the save without it landed: the reference gone from the file, then the bytes")
        // Undo of that Remove: its bytes accepted again (under its own name) and the line back; with the folder
        // writable now, the picture is written, and it's all there when the notes are read again.
        try? fm.removeItem(at: blocker)
        store.reaccept(changeable.key, [NotePictureBytes(name: name, data: Data("bytes".utf8), caption: "")])
        _ = store.change(changeable.key) { $0.body += "\n" + refLine }
        let pictureFile = root.appending(path: NoteShelf.pictureFolder(id: "RM2") + "/" + name)
        while (!fm.fileExists(atPath: pictureFile.path) || text(single)?.contains(name) != true) && Date() < until.addingTimeInterval(5) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let reopened = NoteStore.read(root).notes.first { $0.noteID == "RM2" }
        expect(reopened?.file.body.contains(refLine) == true && (try? Data(contentsOf: pictureFile)) == Data("bytes".utf8) && !store.keepsBytes("RM2", name),
               "Remove, saved, undone: the picture back, written, and there after a reopen")

        // Remove, then the note moves to another notebook, then undo: found by its id as it is now, never the key
        // from before the move; its bytes accepted again and written beside its new place's note.
        let blocker3 = root.appending(path: NoteShelf.pictureFolder(id: "RM3"))
        try? Data("not a folder".utf8).write(to: blocker3)
        _ = NoteStore.create(NoteFile(id: "RM3", body: "moving").serialized(), at: folder.appending(path: "Moving.md"), root: root)
        let read3 = NoteStore.read(root)
        store.preview(read3.notes, notebooks: read3.notebooks)
        guard let moving = store.notes.first(where: { $0.noteID == "RM3" }), let refs3 = store.acceptPictures(moving.key, [("png", Data("three".utf8), "")]) else {
            return expect(false, "the moving note's picture accepted")
        }
        let name3 = refs3[0].file.lastPathComponent
        while store.pictureTrouble[moving.key] == nil && Date() < until.addingTimeInterval(10) { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let bytes3 = store.asideBytes(moving.key)
        _ = store.retirePictures(moving.key, write: true)
        var movedThere = false
        store.move(moving.key, to: "Elsewhere", then: { _ in movedThere = true })
        while !movedThere && Date() < until.addingTimeInterval(15) { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        try? fm.removeItem(at: blocker3)
        let now3 = store.current("RM3")
        expect(now3 != nil && now3?.key != moving.key && store.paper(moving.key) == nil, "after the move, the note found by its id at its new place")
        if let now3 {
            store.reaccept(now3.key, bytes3)
            let written3 = root.appending(path: NoteShelf.pictureFolder(id: "RM3") + "/" + name3)
            while !fm.fileExists(atPath: written3.path) && Date() < until.addingTimeInterval(20) { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            expect((try? Data(contentsOf: written3)) == Data("three".utf8), "Remove, move, undo: its bytes accepted again and written")
        }
    }

    /// The one rule for picture links (NoteStore.pictureFile), journal recovery putting bytes exactly where each saved
    /// link points (an older layout too), and a new note's notebook named as the one already there.
    @MainActor static func pictureLinks(root: URL) {
        let fm = FileManager.default
        let inbox = root.appending(path: "Links")
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let inside = NoteStore.pictureFile("../Pictures/abc/p.png", noteFolder: inbox)
        expect(inside?.path == root.appending(path: "Pictures/abc/p.png").path, "a link inside the notes' root: allowed", inside?.path ?? "nil")
        expect(NoteStore.pictureFile("../Pictures/../../private.png", noteFolder: inbox) == nil, "out by .., however it's spelled: refused")
        expect(NoteStore.pictureFile("/etc/hosts", noteFolder: inbox) == nil && NoteStore.pictureFile("~/x.png", noteFolder: inbox) == nil
               && NoteStore.pictureFile("file:///etc/hosts", noteFolder: inbox) == nil, "absolute, home or an address: refused")
        // A symbolic link on the way (a folder in the notes that points elsewhere): refused, never read through.
        let outside = root.deletingLastPathComponent().appending(path: "Outside")
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try? Data("private".utf8).write(to: outside.appending(path: "secret.png"))
        try? fm.createSymbolicLink(at: inbox.appending(path: "linked"), withDestinationURL: outside)
        expect(NoteStore.pictureFile("linked/secret.png", noteFolder: inbox) == nil, "through a symbolic link: refused")
        expect(NoteStore.pictureFile("../Links/linked/secret.png", noteFolder: inbox) == nil, "a symbolic link reached by ..: refused too")

        // Recovering a journal written with older links ("pictures-….assets/p.png" beside the note): the bytes go back
        // exactly where the link points, so the link works.
        let journal = Config.supportFolder.appending(path: "Notes journal, links")
        try? fm.createDirectory(at: journal, withIntermediateDirectories: true)
        let note = inbox.appending(path: "Old layout.md")
        let base = NoteFile(id: "OLD1", body: "before").serialized()
        _ = NoteStore.create(base, at: note, root: root)
        let typed = NoteFile(id: "OLD1", body: "after\n![](pictures-feed.assets/p.png)").serialized()
        let entry = NoteJournal.Entry(noteID: "OLD1", path: note.path, base: base, text: typed, pictures: [NoteJournal.Picture(name: "p.png", data: Data("old pic".utf8))])
        let at = NoteJournal.recoverEntry(entry, notes: NoteStore.read(root).notes, root: root)
        expect(at?.lastPathComponent == note.lastPathComponent && text(note) == typed && text(inbox.appending(path: "pictures-feed.assets/p.png")) == "old pic"
               && !fm.fileExists(atPath: root.appending(path: NoteShelf.pictureFolder(id: "OLD1") + "/p.png").path),
               "an old journal's picture restored where its link points, not into Pictures", text(note) ?? "nil")
        // The same through continueAt, in the notes and in Unsaved notes.
        let cont = inbox.appending(path: "Continued.md")
        let contBase = NoteFile(id: "OLD2", body: "c0").serialized()
        _ = NoteStore.create(contBase, at: cont, root: root)
        var rest = NoteJournal.Entry(noteID: "OLD2", path: cont.path, base: contBase, text: NoteFile(id: "OLD2", body: "c1\n![](pictures-beef.assets/q.png)").serialized(),
                                     pictures: [NoteJournal.Picture(name: "q.png", data: Data("q".utf8))])
        expect(NoteJournal.continueAt(rest, cont, root: root)?.lastPathComponent == cont.lastPathComponent && text(inbox.appending(path: "pictures-beef.assets/q.png")) == "q",
               "continued in the notes: the picture where the old link points")
        let rescueNote = Config.supportFolder.appending(path: "Unsaved notes/note-old/Note/Continued.md")
        try? fm.createDirectory(at: rescueNote.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(contBase.utf8).write(to: rescueNote)
        rest.path = rescueNote.path
        expect(NoteJournal.continueAt(rest, rescueNote, root: root)?.lastPathComponent == rescueNote.lastPathComponent
               && text(rescueNote.deletingLastPathComponent().appending(path: "pictures-beef.assets/q.png")) == "q",
               "continued in Unsaved notes: the picture where the old link points there too")
        // A saved link that leads out is never written to: its bytes go to the note's own folder instead.
        let escapeNote = inbox.appending(path: "Escape.md")
        let escapeBase = NoteFile(id: "OLD3", body: "e0").serialized()
        _ = NoteStore.create(escapeBase, at: escapeNote, root: root)
        let escaping = NoteJournal.Entry(noteID: "OLD3", path: escapeNote.path, base: escapeBase, text: NoteFile(id: "OLD3", body: "e1\n![](../../escaped.png)").serialized(),
                                         pictures: [NoteJournal.Picture(name: "escaped.png", data: Data("e".utf8))])
        _ = NoteJournal.recoverEntry(escaping, notes: NoteStore.read(root).notes, root: root)
        expect(!fm.fileExists(atPath: root.deletingLastPathComponent().appending(path: "escaped.png").path)
               && text(root.appending(path: NoteShelf.pictureFolder(id: "OLD3") + "/escaped.png")) == "e",
               "a link leading out: nothing written there, the bytes kept in the note's own folder")

        // A new notebook's cover: its folder made first, in the same queued step; never through a link.
        let fresh = root.appending(path: "Fresh book")
        let cover = fresh.appending(path: NoteShelf.coverName)
        NoteDisk.states[77] = NoteDisk.State(url: cover, noteID: "COV", revision: nil)
        let made77 = NoteStore.perform(.create(text: "cover", stem: "About this notebook", folder: fresh, exact: cover), session: 77, root: root)
        expect(made77.outcome == .written && text(cover) == "cover", "a new notebook's cover written, its folder made first", "\(made77.outcome)")
        let away = root.deletingLastPathComponent().appending(path: "Away book")
        try? fm.createDirectory(at: away, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: root.appending(path: "Linked book"), withDestinationURL: away)
        let linkedCover = root.appending(path: "Linked book/" + NoteShelf.coverName)
        NoteDisk.states[78] = NoteDisk.State(url: linkedCover, noteID: "COV2", revision: nil)
        expect(NoteStore.perform(.create(text: "cover", stem: "About this notebook", folder: linkedCover.deletingLastPathComponent(), exact: linkedCover),
                                 session: 78, root: root).outcome == .failed && !fm.fileExists(atPath: away.appending(path: NoteShelf.coverName).path),
               "a notebook folder that is a link: no cover written through it")
        try? fm.removeItem(at: root.appending(path: "Linked book"))

        // A new note in "inbox" when Inbox exists: Inbox, never a second notebook.
        let store = NoteStore(root: root)
        let read = NoteStore.read(root)
        store.preview(read.notes, notebooks: read.notebooks)
        let before = store.notebooks.count
        let existing = store.notebooks.first { $0.name == "Links" }?.name
        expect(existing == "Links" && store.ensureNotebook("links", color: "") == "Links" && store.ensureNotebook("LINKS", color: "") == "Links"
               && store.notebooks.count == before, "a notebook by another case: the one already there, by its own name")
        let made = store.make(NoteFile(body: "# Case"), in: "links")
        expect(made?.notebook == "Links" && made?.url.deletingLastPathComponent().lastPathComponent == "Links" && store.notebooks.count == before,
               "a new note made in \"links\" goes in Links", made?.notebook ?? "nil")
    }

    /// A move that only changes a notebook's case does nothing (the same folder by identity).
    @MainActor static func caseMove(root: URL) {
        let fm = FileManager.default
        // A case-only move: Notebook to notebook, on this (by default case-insensitive) volume.
        let books = root.appending(path: "Casebook")
        let assets = root.appending(path: NoteShelf.pictureFolder(id: "CS"))
        try? fm.createDirectory(at: assets, withIntermediateDirectories: true)
        try? fm.createDirectory(at: books, withIntermediateDirectories: true)
        try? Data("mine".utf8).write(to: assets.appending(path: "p.png"))
        let note = books.appending(path: "Case.md")
        let text0 = NoteFile(id: "CS", body: "# Case\n![](\(NoteShelf.pictureLink(id: "CS", name: "p.png")))").serialized()
        _ = NoteStore.create(text0, at: note, root: root)
        let insensitive = fm.fileExists(atPath: root.appending(path: "casebook").path)
        let stayed = NoteStore.move(note, noteID: "CS", into: root.appending(path: "casebook"), root: root)
        let names = (try? fm.contentsOfDirectory(atPath: books.path)) ?? []
        expect(!insensitive || (stayed?.lastPathComponent == "Case.md" && text(assets.appending(path: "p.png")) == "mine" && !names.contains("Case 2.md")),
               "a case-only move on a case-insensitive volume: nothing copied, renamed or trashed", "\(names)")
        let store = NoteStore(root: root)
        let read = NoteStore.read(root)
        store.preview(read.notes, notebooks: read.notebooks)
        if let paper = store.notes.first(where: { $0.noteID == "CS" }) {
            var answer: PaperNote?
            store.move(paper.key, to: "casebook", then: { answer = $0 })
            expect(answer?.key == paper.key && text(assets.appending(path: "p.png")) == "mine", "the store too: \"casebook\" is Casebook, nothing to do")
        }
    }

    /// Petal's pictures stay put whatever moves: another paper linking the same pictures keeps them, a note with an
    /// older link beside it still shows its picture, and links resolve from wherever the note is.
    @MainActor static func picturesStay(root: URL) {
        let fm = FileManager.default
        func linksHold(_ note: URL) -> Bool {
            guard let text = text(note) else { return false }
            return NoteShelf.referencedPictures(text).allSatisfy { link in
                NoteShelf.resolvedLink(link, from: note.deletingLastPathComponent().path).map { fm.fileExists(atPath: $0) } == true
            }
        }
        // A note and its conflict copy beside it, both linking the note's pictures: the note moves, and both papers'
        // links still hold (nothing of the pictures moved).
        let folder = root.appending(path: "Stay")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let own = root.appending(path: NoteShelf.pictureFolder(id: "ST"))
        try? fm.createDirectory(at: own, withIntermediateDirectories: true)
        try? Data("p".utf8).write(to: own.appending(path: "p.png"))
        let link = NoteShelf.pictureLink(id: "ST", name: "p.png")
        let note = folder.appending(path: "Pictured.md"), copy = folder.appending(path: "Pictured (conflicted copy).md")
        _ = NoteStore.create(NoteFile(id: "ST", body: "![](\(link))").serialized(), at: note, root: root)
        _ = NoteStore.create(NoteFile(id: "ST", body: "copy ![](\(link))").serialized(), at: copy, root: root)
        let landed = NoteStore.move(note, noteID: "ST", into: root.appending(path: "Gone"), root: root)
        expect(landed.map(linksHold) == true && linksHold(copy) && text(own.appending(path: "p.png")) == "p",
               "a note moved away from its conflict copy: both still show the picture")
        // And back again: the same.
        let back = landed.flatMap { NoteStore.move($0, noteID: "ST", into: folder, root: root) }
        expect(back.map(linksHold) == true && linksHold(copy), "moved back: its links still hold")

        // A note with an older link beside it ("pictures-<hash>.assets/p.png", from before Pictures): it still shows
        // its picture where it is, and a move copies the picture along (a handwritten link), never deleting it.
        let older = root.appending(path: "Older")
        let oldFolder = older.appending(path: "pictures-0123456789abcdef.assets")
        try? fm.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try? Data("old".utf8).write(to: oldFolder.appending(path: "p.png"))
        let oldNote = older.appending(path: "Old.md")
        _ = NoteStore.create(NoteFile(id: "OL", body: "![](pictures-0123456789abcdef.assets/p.png)").serialized(), at: oldNote, root: root)
        let paper = NoteStore.read(root).notes.first { $0.noteID == "OL" }
        expect(paper.flatMap { $0.picture("pictures-0123456789abcdef.assets/p.png") }.map { text($0) == "old" } == true, "an older link still finds its picture")
        let oldLanded = NoteStore.move(oldNote, noteID: "OL", into: root.appending(path: "OlderMoved"), root: root)
        expect(oldLanded.map(linksHold) == true && text(oldFolder.appending(path: "p.png")) == "old", "moved: the older picture copied along, the original kept")
        // A note's own picture shows from the editor's base, the folder its file is in.
        if let paper = NoteStore.read(root).notes.first(where: { $0.noteID == "ST" }) {
            expect(paper.picture(link).flatMap { text($0) } == "p", "a paper resolves its own picture's link to the notes' Pictures")
        }
    }

    /// A move queued after a flush that was kept beside the file (changed elsewhere meanwhile): stopped and said.
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

    /// A notebook's canvas file: each edit made on the file as it is (another Mac's move meanwhile stays), written
    /// atomically; a file Petal can't read as a canvas, or one reached through a symbolic link, is never written.
    static func canvasFile(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Canvas")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: NoteStore.canvasName)
        func write(_ edit: NoteCanvas.Edit, in folder: URL) -> NoteCanvas? {
            NoteStore.writeCanvas(edit, binding: NoteStore.bindingNow(folder, root: root), in: folder, root: root)
        }
        let first = write(.move("n1", .init(x: 10, y: 10)), in: folder)
        expect(first?.notes["n1"]?.x == 10 && NoteCanvas.decode(text(file)) == first, "the first edit makes the file")
        // Another Mac moved another note meanwhile.
        let elsewhere = NoteCanvas.decode(text(file))!.applying(.move("n2", .init(x: 70, y: 70)), at: Date().timeIntervalSince1970 + 1)
        try? Data(elsewhere.encoded().utf8).write(to: file)
        let second = write(.move("n1", .init(x: 20, y: 20)), in: folder)
        expect(second?.notes["n1"]?.x == 20 && second?.notes["n2"]?.x == 70, "what moved elsewhere stays")
        try? Data("the person's own words".utf8).write(to: file)
        expect(write(.move("n1", .init(x: 1, y: 1)), in: folder) == nil && text(file) == "the person's own words",
               "a file that isn't a canvas is left as it is")
        let outside = root.deletingLastPathComponent().appending(path: "Outside-\(UUID().uuidString)")
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appending(path: "Linked")
        try? fm.createSymbolicLink(at: link, withDestinationURL: outside)
        expect(write(.move("n1", .init(x: 1, y: 1)), in: link) == nil
               && !fm.fileExists(atPath: outside.appending(path: NoteStore.canvasName).path), "never through a symbolic link")
        try? fm.removeItem(at: link)
        try? fm.removeItem(at: outside)
        expect(write(.move("n1", .init(x: 1, y: 1)), in: root.appending(path: "Never made \(UUID().uuidString)")) == nil,
               "no notebook folder: nothing made")
    }

    /// Canvas edits are journaled first, by their notebook's cover id; one whose write fails is kept, said ("Not
    /// saved yet") and tried again, merged (never over anything newer); and an entry left at quit is put back where its
    /// notebook is after a rename, or rescued into Unsaved notes when it's gone.
    @MainActor static func canvasRetry(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Board")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var coverFile = NoteFile(id: "COVER-BOARD", body: "# About this notebook")
        coverFile.cover = true
        let coverURL = folder.appending(path: NoteShelf.coverName)
        _ = NoteStore.create(coverFile.serialized(), at: coverURL, root: root)
        let store = NoteStore(root: root)
        store.preview([PaperNote(file: coverFile, url: coverURL, notebook: "Board", revision: coverFile.serialized())],
                      notebooks: [Notebook(name: "Board", folder: folder, color: "", cover: coverURL.path, count: 0, instance: NoteStore.instance(of: folder))])
        let boardKey = CanvasQueue.folderKey(NoteStore.instance(of: folder))
        // Something in the canvas file's place that can't be read (a folder): every write fails until it's gone.
        let canvasFile = folder.appending(path: NoteStore.canvasName)
        try? fm.createDirectory(at: canvasFile, withIntermediateDirectories: true)
        var saved: NoteCanvas?
        store.editCanvas("Board", .move("n1", .init(x: 3, y: 4))) { saved = $0 }
        store.editCanvas("Board", .move("n2", .init(x: 5, y: 6))) { _ in }
        var until = Date().addingTimeInterval(3)
        while !store.canvasUnsaved.contains("Board") && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        NoteJournal.queue.sync {}
        let journaled = NoteJournal.readCanvas(NoteJournal.canvasFile(boardKey))
        expect(store.canvasUnsaved.contains("Board") && store.canvasPending("Board").count == 2 && saved == nil
               && journaled?.edits.count == 2 && journaled?.coverID == boardKey,
               "a failed canvas save is kept, said, and journaled on this Mac by its notebook's own folder")
        // Meanwhile another Mac moved n1, later than the edit waiting here.
        try? fm.removeItem(at: canvasFile)
        let later = NoteCanvas().applying(.move("n1", .init(x: 900, y: 900)), at: Date().timeIntervalSince1970 + 3600)
        try? Data(later.encoded().utf8).write(to: canvasFile)
        until = Date().addingTimeInterval(8)
        while saved == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        NoteJournal.queue.sync {}
        let landed = NoteCanvas.decode(text(folder.appending(path: NoteStore.canvasName)))
        expect(landed?.notes["n1"]?.x == 900 && landed?.notes["n2"]?.x == 5, "tried again, merged: the newer move elsewhere stays, its own edit lands",
               "\(String(describing: landed?.notes))")
        expect(!store.canvasUnsaved.contains("Board") && store.canvasPending("Board").isEmpty
               && !fm.fileExists(atPath: NoteJournal.canvasFile(boardKey).path), "and its journal entry goes")

        // At the next launch: an entry left by a quit, its notebook renamed meanwhile, goes to where it is now.
        NoteJournal.keepCanvas(CanvasEntry(coverID: boardKey, notebook: "Board", edits: [NoteCanvas.Stamped(.words(.init(id: "w", text: "hi", x: 1, y: 1)))],
                                           binding: NotebookBinding(coverID: "COVER-BOARD", path: "Board", instance: NoteStore.instance(of: folder))))
        let renamed = root.appending(path: "Board renamed")
        expect(NoteStore.moveFolder(folder, to: renamed, root: root), "the notebook is renamed")
        // An entry whose notebook is gone.
        NoteJournal.keepCanvas(CanvasEntry(coverID: "COVER-GONE", notebook: "Gone board", edits: [NoteCanvas.Stamped(.move("n9", .init(x: 1, y: 2)))]))
        // The notes' journal moved aside too (with its own entry), as a launch does: the canvas entries aren't lost with it.
        NoteJournal.snapshot(NoteJournal.Entry(noteID: "N-JOURNAL", path: "", base: nil, text: "x"))
        let canvases = NoteJournal.canvasLeftovers()
        let notesLeft = NoteJournal.leftovers()
        expect(canvases.count == 1 && !fm.fileExists(atPath: NoteJournal.canvasFolder().path), "at launch the canvas entries move aside first")
        for holding in canvases { NoteJournal.recoverCanvas(holding, root: root) }
        for holding in notesLeft { try? fm.removeItem(at: holding) }
        expect(NoteCanvas.decode(text(renamed.appending(path: NoteStore.canvasName)))?.texts.first?.text == "hi",
               "an entry follows its notebook's rename, by its folder")
        let unsaved = Config.supportFolder.appending(path: "Unsaved notes")
        let rescued = (fm.enumerator(atPath: unsaved.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix("Gone board canvas.json") }
        expect(rescued.count == 1 && NoteCanvas.decode(rescued.first.flatMap { text(unsaved.appending(path: $0)) })?.notes["n9"]?.y == 2
               && canvases.allSatisfy { !fm.fileExists(atPath: $0.path) }, "its notebook gone: rescued into Unsaved notes, nothing dropped", "\(rescued)")
    }

    /// A write under way when the canvas drains (quit): its completion touches neither what's waiting nor the journal,
    /// so the edit queued after it stays journaled.
    @MainActor static func canvasDrain(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Drain board")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var coverFile = NoteFile(id: "COVER-DRAIN", body: "# About this notebook")
        coverFile.cover = true
        let coverURL = folder.appending(path: NoteShelf.coverName)
        _ = NoteStore.create(coverFile.serialized(), at: coverURL, root: root)
        let store = NoteStore(root: root)
        store.preview([PaperNote(file: coverFile, url: coverURL, notebook: "Drain board", revision: coverFile.serialized())],
                      notebooks: [Notebook(name: "Drain board", folder: folder, color: "", cover: coverURL.path, count: 0, instance: NoteStore.instance(of: folder))])
        let drainKey = CanvasQueue.folderKey(NoteStore.instance(of: folder))
        // Hold the files' queue so the first write is under way when the drain comes.
        let hold = DispatchSemaphore(value: 0)
        NoteStore.io.async { hold.wait() }
        store.editCanvas("Drain board", .move("first", .init(x: 1, y: 1))) { _ in }
        store.editCanvas("Drain board", .move("second", .init(x: 2, y: 2))) { _ in }
        NoteJournal.queue.sync {}
        store.drainCanvas()
        hold.signal()
        NoteStore.io.sync {}
        let until = Date().addingTimeInterval(1)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        NoteJournal.queue.sync {}
        var left: [String] = []
        for stamped in NoteJournal.readCanvas(NoteJournal.canvasFile(drainKey))?.edits ?? [] {
            if case .move(let id, _) = stamped.edit { left.append(id) }
        }
        expect(left.contains("second"), "an edit queued behind a write under way at quit stays journaled", "\(left)")
        try? fm.removeItem(at: NoteJournal.canvasFile(drainKey))
    }

    /// A coverless notebook made Private, then a quit before its cover is made: at the next launch it's Private at
    /// once (from the journal), and the field lands on the cover.
    @MainActor static func coverQuit(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Quit")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NoteStore.create("a note", at: folder.appending(path: "One.md"), root: root)
        // What a quit leaves: the field journaled, no cover yet.
        var pending = CoverFields(notebook: "Quit", root: root.path, folderID: NoteStore.instance(of: folder))
        pending.fields["private"] = "true"
        NoteJournal.keepCover(pending)
        let left = NoteJournal.coverLeftovers()
        expect(left.entries.map(\.notebook) == ["Quit"] && !fm.fileExists(atPath: NoteJournal.coverFolder().path), "at launch the cover fields move aside first")
        let store = NoteStore(root: root)
        let waiting = store.recoverCovers(left.entries)
        NoteJournal.rejournalCovers(waiting, sources: left.sources, holding: left.holding)
        expect(fm.fileExists(atPath: NoteJournal.coverFile(pending.key).path) && left.holding.allSatisfy { !fm.fileExists(atPath: $0.path) },
               "journaled again before the moved-aside copy goes")
        store.reload()
        var until = Date().addingTimeInterval(5)
        while store.notebook("Quit") == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        expect(store.notebook("Quit")?.isPrivate == true, "Private at once after the launch, before any cover")
        until = Date().addingTimeInterval(8)
        func onDisk() -> NoteFile? { text(folder.appending(path: NoteShelf.coverName)).map { NoteFile.parse($0, fallbackID: "", fallbackDate: Date()) } }
        while onDisk().map(NoteContract.isPrivate) != true && Date() < until {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            store.reload()
        }
        expect(onDisk().map(NoteContract.isPrivate) == true, "and it lands on the cover made for it")
        until = Date().addingTimeInterval(3)
        while fm.fileExists(atPath: NoteJournal.coverFile(pending.key).path) && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); NoteJournal.queue.sync {} }
        expect(!fm.fileExists(atPath: NoteJournal.coverFile(pending.key).path), "its journal entry goes once it landed")
    }

    /// A cover in conflict (its file and a conflicted copy of it): cover changes waiting from before a launch are
    /// replayed only after the read's conflicts are rebuilt, so neither paper is written.
    @MainActor static func coverConflict(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Torn")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var cover = NoteFile(id: "COVER-TORN", body: "# About this notebook\nOne side")
        cover.cover = true
        _ = NoteStore.create(cover.serialized(), at: folder.appending(path: NoteShelf.coverName), root: root)
        var other = cover
        other.body = "# About this notebook\nThe other side"
        _ = NoteStore.create(other.serialized(), at: folder.appending(path: "About this notebook (conflicted copy).md"), root: root)
        let before = [text(folder.appending(path: NoteShelf.coverName)), text(folder.appending(path: "About this notebook (conflicted copy).md"))]
        let store = NoteStore(root: root)
        // As a launch finds it: the change in this Mac's journal, the folder entered the one way.
        var torn = CoverFields(notebook: "Torn", root: root.path, coverID: "COVER-TORN", folderID: NoteStore.instance(of: folder), path: "Torn")
        torn.set("private", "true")
        NoteJournal.queue.sync { _ = NoteJournal.keepCover(torn) }
        store.switchRoot(to: root, launch: true)
        let until = Date().addingTimeInterval(3)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        NoteStore.io.sync {}
        let after = [text(folder.appending(path: NoteShelf.coverName)), text(folder.appending(path: "About this notebook (conflicted copy).md"))]
        expect(after == before && store.notebook("Torn")?.isPrivate == true, "a cover in conflict isn't written; the change shows and waits")
        try? fm.removeItem(at: folder)
    }

    /// Canvas recovery while a cover can't be read yet (as one still downloading from iCloud): kept, not rescued;
    /// once the cover reads, it lands in its notebook.
    @MainActor static func canvasWaitsForCovers(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Cloudy")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var cover = NoteFile(id: "COVER-CLOUDY", body: "# About this notebook")
        cover.cover = true
        let coverURL = folder.appending(path: NoteShelf.coverName)
        _ = NoteStore.create(cover.serialized(), at: coverURL, root: root)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: coverURL.path)
        NoteJournal.keepCanvas(CanvasEntry(coverID: "COVER-CLOUDY", notebook: "Cloudy", edits: [NoteCanvas.Stamped(.move("n1", .init(x: 4, y: 4)))]))
        let unsaved = Config.supportFolder.appending(path: "Unsaved notes")
        let rescuedBefore = (fm.enumerator(atPath: unsaved.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix("Cloudy canvas.json") }.count
        var holding = NoteJournal.canvasLeftovers()
        for folder in holding { NoteJournal.recoverCanvas(folder, root: root) }
        let rescued = (fm.enumerator(atPath: unsaved.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix("Cloudy canvas.json") }.count
        expect(rescued == rescuedBefore && holding.contains { fm.fileExists(atPath: $0.path) }, "a cover not read yet: the entry waits, never rescued")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: coverURL.path)
        holding = NoteJournal.canvasLeftovers()
        for folder in holding { NoteJournal.recoverCanvas(folder, root: root) }
        expect(NoteCanvas.decode(text(folder.appending(path: NoteStore.canvasName)))?.notes["n1"]?.x == 4, "once it reads, the entry lands in its notebook")
        try? fm.removeItem(at: folder)
    }

    /// Cover changes waiting in one notes folder never touch a notebook of the same name in another: kept per folder
    /// across a switch, and landed only back in their own.
    @MainActor static func coverRoots(top: URL) {
        let fm = FileManager.default
        let rootA = top.appending(path: "Root A"), rootB = top.appending(path: "Root B")
        for r in [rootA, rootB] { try? fm.createDirectory(at: r.appending(path: "Same"), withIntermediateDirectories: true) }
        // In A, the cover is there but can't be read yet: the change waits.
        var coverA = NoteFile(id: "COVER-A", body: "# About this notebook")
        coverA.cover = true
        let coverAURL = rootA.appending(path: "Same/\(NoteShelf.coverName)")
        _ = NoteStore.create(coverA.serialized(), at: coverAURL, root: rootA)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: coverAURL.path)
        var coverB = NoteFile(id: "COVER-B", body: "# About this notebook")
        coverB.cover = true
        let coverBURL = rootB.appending(path: "Same/\(NoteShelf.coverName)")
        _ = NoteStore.create(coverB.serialized(), at: coverBURL, root: rootB)
        let store = NoteStore(root: rootA)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        store.reload()
        settle(1)
        store.setCover("Same", fields: ["private": "true"])
        expect(store.notebook("Same")?.isPrivate == true, "Private at once in its own folder")
        var switched = false
        store.switchRoot(to: rootB) { switched = true }
        settle(2)
        store.reload()
        settle(1.5)
        let b = text(coverBURL).map { NoteFile.parse($0, fallbackID: "", fallbackDate: Date()) }
        expect(switched && b.map(NoteContract.isPrivate) == false && store.notebook("Same")?.isPrivate == false,
               "another folder's notebook of the same name: untouched, and not shown Private", text(coverBURL) ?? "nil")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: coverAURL.path)
        store.switchRoot(to: rootA) {}
        let until = Date().addingTimeInterval(8)
        while text(coverAURL).map({ NoteContract.isPrivate(NoteFile.parse($0, fallbackID: "", fallbackDate: Date())) }) != true && Date() < until {
            settle(0.2)
            store.reload()
        }
        expect(text(coverAURL).map { NoteContract.isPrivate(NoteFile.parse($0, fallbackID: "", fallbackDate: Date())) } == true, "back in its own folder, it lands there")
        for r in [rootA, rootB] { try? fm.removeItem(at: r) }
    }

    /// A notebook whose possible covers can't all be read is unknown, so Private: an unreadable conflicted copy of a
    /// public cover, or a folder that can't be listed. Public again once every file in it reads.
    static func notebookUncertain(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Uncertain")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var cover = NoteFile(id: "COVER-UNC", body: "# About this notebook")
        cover.cover = true
        _ = NoteStore.create(cover.serialized(), at: folder.appending(path: NoteShelf.coverName), root: root)
        var copy = cover
        copy.setScalar("private", "true")
        let copyURL = folder.appending(path: "About this notebook (conflicted copy).md")
        _ = NoteStore.create(copy.serialized(), at: copyURL, root: root)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: copyURL.path)
        expect(NoteStore.read(root).notebooks.first { $0.name == "Uncertain" }?.isPrivate == true, "an unreadable conflicted copy of the cover: unknown, so Private")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copyURL.path)
        expect(NoteStore.read(root).notebooks.first { $0.name == "Uncertain" }?.isPrivate == true, "read, the copy says Private: Private")
        try? fm.removeItem(at: copyURL)
        expect(NoteStore.read(root).notebooks.first { $0.name == "Uncertain" }?.isPrivate == false, "every possible cover read and none says so: public")
        // An unrelated note that can't be read yet (as one still downloading) changes nothing about the notebook's
        // privacy, nor whether its cover can be written; a note saying `cover: true` that isn't the cover counts for nothing.
        let other = folder.appending(path: "Unrelated.md")
        _ = NoteStore.create("hello", at: other, root: root)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: other.path)
        let withUnread = NoteStore.read(root).notebooks.first { $0.name == "Uncertain" }
        expect(withUnread?.isPrivate == false && withUnread?.coverUnread == false && withUnread?.privacyUnknown == false,
               "an unrelated unread note: not Private, and the cover can still be written")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: other.path)
        var pretender = NoteFile(id: "PRETEND", body: "not a cover")
        pretender.cover = true
        _ = NoteStore.create(pretender.serialized(), at: folder.appending(path: "Pretender.md"), root: root)
        expect(NoteStore.read(root).notebooks.first { $0.name == "Uncertain" }?.isPrivate == false, "another note's `cover: true` counts for nothing")
        // But a note saying `cover: true` and `private: true` without a cover's name is a cover that lost its name:
        // unknown, so Private, until the person resolves it.
        pretender.setScalar("private", "true")
        try? Data(pretender.serialized().utf8).write(to: folder.appending(path: "Pretender.md"))
        let warned = NoteStore.read(root).notebooks.first { $0.name == "Uncertain" }
        expect(warned?.isPrivate == true && warned?.privacyUnknown == true, "a stray private cover makes the notebook unknown, so Private")
        try? fm.removeItem(at: folder.appending(path: "Pretender.md"))
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        expect(NoteStore.read(root).notebooks.first { $0.name == "Uncertain" }?.isPrivate == true, "a folder that can't be listed: unknown, so Private")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? fm.removeItem(at: folder)
    }

    /// Re-keying canvas edits (a folder key to a cover id) never drops the source before its replacement is written:
    /// a failed write keeps both.
    static func rekeyKeepsSource(root: URL) {
        let fm = FileManager.default
        let journal = root.deletingLastPathComponent().appending(path: "Journal \(UUID().uuidString)")
        let source = CanvasEntry(coverID: CanvasQueue.folderKey("9:9"), notebook: "Moving", edits: [NoteCanvas.Stamped(.move("n1", .init(x: 1, y: 1)))])
        expect(NoteJournal.keepCanvas(source, in: journal), "the source entry is journaled")
        // The replacement can't be written: something unreadable already sits where it goes.
        let target = CanvasEntry(coverID: "COVER-MOVING", notebook: "Moving", edits: source.edits)
        try? fm.createDirectory(at: NoteJournal.canvasFile("COVER-MOVING", in: journal), withIntermediateDirectories: true)
        NoteJournal.moveCanvas(target, from: source.coverID, ids: Set(source.edits.map(\.id)), in: journal, attempt: 90)
        expect(NoteJournal.readCanvas(NoteJournal.canvasFile(source.coverID, in: journal))?.edits.count == 1, "the replacement failed: the source keeps its edits")
        try? fm.removeItem(at: NoteJournal.canvasFile("COVER-MOVING", in: journal))
        NoteJournal.moveCanvas(target, from: source.coverID, ids: Set(source.edits.map(\.id)), in: journal)
        expect(NoteJournal.readCanvas(NoteJournal.canvasFile("COVER-MOVING", in: journal))?.edits.count == 1
               && !fm.fileExists(atPath: NoteJournal.canvasFile(source.coverID, in: journal).path), "written, the source goes")
        // Cover leftovers: each moved-aside file goes only once its entry was journaled again; one that can't be read
        // stays, and so does its folder.
        let held = journal.appending(path: "held")
        try? fm.createDirectory(at: held, withIntermediateDirectories: true)
        let entry = CoverFields(notebook: "Moving", root: "/r", coverID: "COVER-MOVING", fields: ["private": "true"])
        let goodFile = held.appending(path: "good.json"), badFile = held.appending(path: "bad.json")
        try? JSONEncoder().encode(entry).write(to: goodFile)
        try? Data("not an entry".utf8).write(to: badFile)
        let sources: [(file: URL, key: String?)] = [(goodFile, entry.key), (badFile, nil)]
        try? fm.createDirectory(at: NoteJournal.coverFile(entry.key, in: journal), withIntermediateDirectories: true)
        NoteJournal.rejournalCovers([entry], sources: sources, holding: [held], in: journal)
        expect(fm.fileExists(atPath: goodFile.path), "a cover entry that couldn't be journaled again: its moved-aside file stays")
        try? fm.removeItem(at: NoteJournal.coverFile(entry.key, in: journal))
        NoteJournal.rejournalCovers([entry], sources: sources, holding: [held], in: journal)
        expect(!fm.fileExists(atPath: goodFile.path) && fm.fileExists(atPath: NoteJournal.coverFile(entry.key, in: journal).path),
               "journaled again, its file goes")
        expect(fm.fileExists(atPath: badFile.path) && fm.fileExists(atPath: held.path), "a file that couldn't be read stays, and so does its folder")
        try? fm.removeItem(at: badFile)
        NoteJournal.rejournalCovers([], sources: [], holding: [held], in: journal)
        expect(!fm.fileExists(atPath: held.path), "the folder goes once every file in it was read and rewritten")
        try? fm.removeItem(at: journal)
    }

    /// A cover's copy kept beside it (a conflict, a recovery) keeps the cover's name, never its heading's.
    static func coverConflictNames(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Named")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var cover = NoteFile(id: "COVER-NAMED", body: "# Health things\nPrivate stuff")
        cover.cover = true
        cover.setScalar("private", "true")
        let coverURL = folder.appending(path: NoteShelf.coverName)
        _ = NoteStore.create(cover.serialized(), at: coverURL, root: root)
        let kept = NoteStore.keepBeside(cover.serialized(), original: coverURL, root: root)
        guard case .keptBoth(let copy) = kept else { expect(false, "a cover's copy is kept beside it", "\(kept)"); return }
        expect(copy.lastPathComponent == "About this notebook (conflicted copy).md" && NoteLibrary.isCoverName(copy.lastPathComponent),
               "a cover's conflict copy keeps the cover's name", copy.lastPathComponent)
        let again = NoteStore.keepBeside(cover.serialized(), original: coverURL, root: root)
        if case .keptBoth(let second) = again { expect(second.lastPathComponent == "About this notebook (conflicted copy 2).md", "numbered when needed", second.lastPathComponent) }
        let plain = folder.appending(path: "Trip.md")
        _ = NoteStore.create("# Trip\nwords", at: plain, root: root)
        if case .keptBoth(let other) = NoteStore.keepBeside("# Trip\nother words", original: plain, root: root) {
            expect(other.lastPathComponent.hasPrefix("Trip"), "any other note's copy is named from its title", other.lastPathComponent)
        }
        try? fm.removeItem(at: folder)
    }

    /// Keep this one on a cover's conflict promotes the chosen version to "About this notebook.md" (written and read
    /// back) before the others are trashed.
    @MainActor static func keepPromotes(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Promote")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var cover = NoteFile(id: "COVER-PROMOTE", body: "# About this notebook\nOne side")
        cover.cover = true
        let coverURL = folder.appending(path: NoteShelf.coverName)
        _ = NoteStore.create(cover.serialized(), at: coverURL, root: root)
        var chosen = cover
        chosen.body = "# About this notebook\nThe side to keep"
        chosen.setScalar("private", "true")
        let copyURL = folder.appending(path: "About this notebook (conflicted copy).md")
        _ = NoteStore.create(chosen.serialized(), at: copyURL, root: root)
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        store.reload()
        let readBy = Date().addingTimeInterval(8)
        while store.notes.first(where: { $0.url.lastPathComponent == copyURL.lastPathComponent && $0.notebook == "Promote" }) == nil && Date() < readBy { settle(0.1) }
        guard let copyPaper = store.notes.first(where: { $0.url.lastPathComponent == copyURL.lastPathComponent && $0.notebook == "Promote" }) else {
            expect(false, "the conflict copy is read", "\(store.notes.filter { $0.notebook == "Promote" }.map(\.url.path))"); return
        }
        expect(store.conflict(of: copyPaper)?.count == 2, "a cover and its copy are one conflict")
        store.keep(copyPaper)
        let until = Date().addingTimeInterval(5)
        while fm.fileExists(atPath: copyURL.path) && Date() < until { settle(0.1) }
        let landed = (try? String(contentsOf: coverURL, encoding: .utf8)).map { NoteFile.parse($0, fallbackID: "", fallbackDate: Date()) }
        expect(landed?.body.contains("The side to keep") == true && landed.map(NoteContract.isPrivate) == true && !fm.fileExists(atPath: copyURL.path),
               "the kept copy is now the cover file itself, and only then the copy goes")
        expect(NoteShelf.keepTarget(chosen: "/n/B/About this notebook (conflicted copy).md", group: ["/n/B/About this notebook.md", "/n/B/About this notebook (conflicted copy).md"])
               == "/n/B/About this notebook.md" && NoteShelf.keepTarget(chosen: "/n/B/Trip (conflicted copy).md", group: ["/n/B/Trip.md", "/n/B/Trip (conflicted copy).md"])
               == "/n/B/Trip (conflicted copy).md", "a cover's Keep lands on the cover's name; another note's where it's chosen")
        try? fm.removeItem(at: folder)
    }

    /// Cover conflicts are per notebook folder: a notebook duplicated in Finder (its cover's id in two folders) stays
    /// two notebooks, Keep writes only within its own folder; a recovered cover with another id joins its notebook's
    /// group, shows as a conflict and keeps the notebook Private until it's resolved.
    @MainActor static func coverGroupsByFolder(root: URL) {
        let fm = FileManager.default
        let a = root.appending(path: "Original"), b = root.appending(path: "Original copy"), c = root.appending(path: "Recovered")
        for folder in [a, b, c] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        func make(_ folder: URL, _ name: String, id: String, body: String, isPrivate: Bool = false) -> URL {
            var file = NoteFile(id: id, body: body)
            file.cover = true
            if isPrivate { file.setScalar("private", "true") }
            let url = folder.appending(path: name)
            _ = NoteStore.create(file.serialized(), at: url, root: root)
            return url
        }
        let coverA = make(a, NoteShelf.coverName, id: "DUP", body: "# About this notebook\nA")
        let copyA = make(a, "About this notebook (conflicted copy).md", id: "DUP", body: "# About this notebook\nA, kept")
        let coverB = make(b, NoteShelf.coverName, id: "DUP", body: "# About this notebook\nB")
        let coverC = make(c, NoteShelf.coverName, id: "C-ONE", body: "# About this notebook\nC")
        let recovered = make(c, "About this notebook (recovered).md", id: "C-TWO", body: "# About this notebook\nC, recovered", isPrivate: true)
        let beforeB = text(coverB)
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        func paper(_ url: URL) -> PaperNote? { store.notes.first { $0.url.lastPathComponent == url.lastPathComponent && $0.notebook == url.deletingLastPathComponent().lastPathComponent } }
        store.reload()
        let readBy = Date().addingTimeInterval(8)
        while paper(recovered) == nil && Date() < readBy { settle(0.1) }
        guard let copyPaper = paper(copyA), let recoveredPaper = paper(recovered), let canonicalC = paper(coverC) else { expect(false, "the covers are read"); return }
        expect(store.conflict(of: copyPaper)?.map(\.notebook).allSatisfy { $0 == "Original" } == true && store.conflict(of: copyPaper)?.count == 2,
               "a duplicated notebook's covers never group with the original's")
        expect(store.conflict(of: recoveredPaper)?.count == 2 && store.readOnly(recoveredPaper) && store.readOnly(canonicalC),
               "a recovered cover with another id joins its notebook's group, both read only with Keep this one")
        expect(store.notebook("Recovered")?.isPrivate == true, "and counts for privacy while unresolved")
        store.keep(copyPaper)
        var until = Date().addingTimeInterval(5)
        while fm.fileExists(atPath: copyA.path) && Date() < until { settle(0.1) }
        // (The duplicated notebook's cover gets its own id meanwhile: only its id changes, never its words.)
        let coverBNow = text(coverB).map { NoteFile.parse($0, fallbackID: "", fallbackDate: Date()) }
        expect(text(coverA)?.contains("A, kept") == true && coverBNow?.body == beforeB.map { NoteFile.parse($0, fallbackID: "", fallbackDate: Date()).body }
               && fm.fileExists(atPath: coverB.path), "Keep writes only within its own notebook folder")
        store.keep(canonicalC)
        until = Date().addingTimeInterval(5)
        while fm.fileExists(atPath: recovered.path) && Date() < until { settle(0.1) }
        store.reload()
        settle(1.5)
        expect(!fm.fileExists(atPath: recovered.path) && store.notebook("Recovered")?.isPrivate == false, "resolved, the notebook is what its cover says")
        for folder in [a, b, c] { try? fm.removeItem(at: folder) }
    }

    /// A notebook with canvas edits waiting (its canvas can't be written yet) whose cover's id is renewed when a
    /// duplicate appears: its edits stay its own, keyed by its folder, and land in it, never in the other notebook.
    @MainActor static func renewalKeepsCanvas(root: URL) {
        let fm = FileManager.default
        let a = root.appending(path: "Alpha"), z = root.appending(path: "Zeta")
        try? fm.createDirectory(at: z, withIntermediateDirectories: true)
        var cover = NoteFile(id: "SHARED-COVER", body: "# About this notebook\nZeta")
        cover.cover = true
        _ = NoteStore.create(cover.serialized(), at: z.appending(path: NoteShelf.coverName), root: root)
        let zCanvas = z.appending(path: NoteStore.canvasName)
        try? fm.createDirectory(at: zCanvas, withIntermediateDirectories: true)   // Z's canvas can't be written for now
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        store.reload()
        var until = Date().addingTimeInterval(8)
        while store.notebook("Zeta") == nil && Date() < until { settle(0.05) }
        store.editCanvas("Zeta", .move("z1", .init(x: 9, y: 9))) { _ in }
        settle(0.5)
        let zInstance = store.notebook("Zeta")?.instance ?? ""
        // A duplicate named so it sorts first: Zeta's cover is the one renewed.
        try? fm.createDirectory(at: a, withIntermediateDirectories: true)
        _ = NoteStore.create(cover.serialized(), at: a.appending(path: NoteShelf.coverName), root: root)
        // A Private change for Zeta, made with the old id and waiting when the duplicate is first read.
        var privately = CoverFields(notebook: "Zeta", root: store.root.path, coverID: "SHARED-COVER", folderID: zInstance, path: "Zeta")
        privately.set("private", "true")
        store.coverPending[privately.key] = privately
        store.reload()
        until = Date().addingTimeInterval(8)
        let renewed = NoteLibrary.renewedID("SHARED-COVER", folder: "Zeta")
        func idOnDisk(_ folder: URL) -> String? { text(folder.appending(path: NoteShelf.coverName)).map { NoteFile.parse($0, fallbackID: "", fallbackDate: Date()).id } }
        while idOnDisk(z) != renewed && Date() < until { settle(0.1) }
        store.reload()
        settle(1)
        NoteJournal.queue.sync {}
        let journaled = NoteJournal.readCanvas(NoteJournal.canvasFile(CanvasQueue.folderKey(zInstance)))
        expect(journaled?.binding?.coverID == renewed && store.canvasWaiting.values.allSatisfy { $0.bound.coverID == renewed },
               "the renewal moved the waiting canvas edit's binding to the new id, in memory and in the journal")
        func privateOnDisk(_ folder: URL) -> Bool { text(folder.appending(path: NoteShelf.coverName)).map { NoteContract.isPrivate(NoteFile.parse($0, fallbackID: "", fallbackDate: Date())) } == true }
        until = Date().addingTimeInterval(8)
        while !privateOnDisk(z) && Date() < until { settle(0.2); store.reload() }
        expect(privateOnDisk(z) && !privateOnDisk(a), "the Private change lands on its own notebook, never on the duplicate that kept the old id")
        try? fm.removeItem(at: zCanvas)
        until = Date().addingTimeInterval(10)
        while NoteCanvas.decode(text(zCanvas))?.notes["z1"] == nil && Date() < until { settle(0.2) }
        expect(idOnDisk(z) == renewed && idOnDisk(a) == "SHARED-COVER", "the later folder's cover was renewed")
        expect(NoteCanvas.decode(text(zCanvas))?.notes["z1"]?.x == 9 && !fm.fileExists(atPath: a.appending(path: NoteStore.canvasName).path),
               "its waiting canvas edit lands in its own notebook, never in the one that now has its old cover id")
        for folder in [a, z] { try? fm.removeItem(at: folder) }
    }

    /// A notebook duplicated in Finder (its cover's id in two folders): the later folder's cover gets a new,
    /// deterministic id through its session, Private until it lands; then its cover fields and canvas stay its own.
    @MainActor static func duplicatedNotebook(root: URL) {
        let fm = FileManager.default
        let a = root.appending(path: "Trip"), b = root.appending(path: "Trip copy")
        for folder in [a, b] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        var cover = NoteFile(id: "TRIP-COVER", body: "# About this notebook\nTrips")
        cover.cover = true
        _ = NoteStore.create(cover.serialized(), at: a.appending(path: NoteShelf.coverName), root: root)
        _ = NoteStore.create(cover.serialized(), at: b.appending(path: NoteShelf.coverName), root: root)
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        // The read first, then the files' queue held, so the new id's write waits while the notebook is checked.
        store.reload()
        let hold = DispatchSemaphore(value: 0)
        holdAfterFirstRead(hold)
        var until = Date().addingTimeInterval(8)
        while store.notebook("Trip copy") == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let expected = NoteLibrary.renewedID("TRIP-COVER", folder: "Trip copy")
        expect(store.renewing["Trip copy"] == expected && store.notebook("Trip copy")?.isPrivate == true && store.notebook("Trip")?.isPrivate == false,
               "the later folder's cover is getting its new id, and that notebook is Private until it lands")
        expect(store.coverID("Trip copy") == nil, "while its new id is being written, the renewed notebook's cover id isn't used as a key")
        hold.signal()
        until = Date().addingTimeInterval(8)
        func idOnDisk(_ folder: URL) -> String? { text(folder.appending(path: NoteShelf.coverName)).map { NoteFile.parse($0, fallbackID: "", fallbackDate: Date()).id } }
        while idOnDisk(b) != expected && Date() < until { settle(0.1) }
        until = Date().addingTimeInterval(5)
        while store.renewing["Trip copy"] != nil && Date() < until { settle(0.1) }
        store.reload()
        settle(1.5)
        expect(idOnDisk(b) == expected && idOnDisk(a) == "TRIP-COVER" && text(b.appending(path: NoteShelf.coverName))?.contains("Trips") == true,
               "written: the later cover has its new id (its words kept), the first keeps its own")
        expect(store.coverID("Trip copy") == expected && store.coverID("Trip") == "TRIP-COVER" && store.notebook("Trip copy")?.isPrivate == false,
               "landed: each notebook's own id, and it's no longer Private")
        // Then everything kept by cover id stays separate.
        store.editCanvas("Trip copy", .move("n1", .init(x: 3, y: 3))) { _ in }
        until = Date().addingTimeInterval(5)
        while NoteCanvas.decode(text(b.appending(path: NoteStore.canvasName)))?.notes["n1"] == nil && Date() < until { settle(0.1) }
        expect(NoteCanvas.decode(text(b.appending(path: NoteStore.canvasName)))?.notes["n1"]?.x == 3 && !fm.fileExists(atPath: a.appending(path: NoteStore.canvasName).path),
               "a canvas edit lands only in its own notebook")
        store.setCover("Trip copy", fields: ["private": "true"])
        until = Date().addingTimeInterval(5)
        func privateOnDisk(_ folder: URL) -> Bool? { text(folder.appending(path: NoteShelf.coverName)).map { NoteContract.isPrivate(NoteFile.parse($0, fallbackID: "", fallbackDate: Date())) } }
        while privateOnDisk(b) != true && Date() < until { settle(0.1); store.reload() }
        expect(privateOnDisk(b) == true && privateOnDisk(a) == false, "a cover field lands only on its own notebook's cover")
        for folder in [a, b] { try? fm.removeItem(at: folder) }
    }

    /// A Private notebook's folder renamed in Finder with a trailing dot is still that Private notebook.
    static func renamedPrivateFolder(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Health.")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var cover = NoteFile(id: "HEALTH-DOT", body: "# About this notebook")
        cover.cover = true
        cover.setScalar("private", "true")
        _ = NoteStore.create(cover.serialized(), at: folder.appending(path: NoteShelf.coverName), root: root)
        let read = NoteStore.read(root)
        let books = read.notebooks.map(\.name)
        let privateBooks = NotePrivacy.privateBooks(notebooks: read.notebooks.map { ($0.name, $0.isPrivate) }, held: [])
        expect(privateBooks.contains("Health.") && !NotePrivacy.readable(notebook: "Health.", privateBooks: privateBooks, asker: nil)
               && !NotePrivacy.destinationReadable("Health.", existing: books, privateBooks: privateBooks, asker: nil),
               "a renamed Private folder stays Private to the tools, and a move into it is refused")
        try? fm.removeItem(at: folder)
    }

    /// Two Macs renewing one cover's id at once write the same text: the second write finds it there and counts it as
    /// landed (never a conflict copy), and a pending id that won't land is reconciled with the file after a read.
    @MainActor static func identicalRenewal(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Twice")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var cover = NoteFile(id: "OLD-ID", body: "# About this notebook\nTwice")
        cover.cover = true
        let url = folder.appending(path: NoteShelf.coverName)
        let base = cover.serialized()
        _ = NoteStore.create(base, at: url, root: root)
        var renewed = cover
        renewed.id = NoteLibrary.renewedID("OLD-ID", folder: "Twice")
        let text = renewed.serialized()
        // The other Mac's identical renewal is already there.
        try? Data(text.utf8).write(to: url)
        let outcome = NoteStore.save(text, to: url, base: base, root: root, noteID: "OLD-ID")
        let copies = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.contains("conflicted") }
        expect(outcome == .written && copies.isEmpty && (try? String(contentsOf: url, encoding: .utf8)) == text,
               "an identical renewal finds itself there: landed, no conflict copy", "\(outcome) \(copies)")
        try? fm.removeItem(at: folder)
    }

    /// A renewal whose write was kept beside the cover (its file changed meanwhile, as on another Mac): the pending id
    /// is reconciled with the file after the next read, the conflict shows, and after Keep the cover gets its id
    /// cleanly, with nothing left waiting.
    @MainActor static func reconcileAfterKeep(root: URL) {
        let fm = FileManager.default
        let a = root.appending(path: "Rec"), b = root.appending(path: "Rec copy")
        for folder in [a, b] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        var cover = NoteFile(id: "REC-COVER", body: "# About this notebook\nRec")
        cover.cover = true
        _ = NoteStore.create(cover.serialized(), at: a.appending(path: NoteShelf.coverName), root: root)
        let coverB = b.appending(path: NoteShelf.coverName)
        _ = NoteStore.create(cover.serialized(), at: coverB, root: root)
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        store.reload()
        let hold = DispatchSemaphore(value: 0)
        holdAfterFirstRead(hold)
        var until = Date().addingTimeInterval(8)
        while store.renewing["Rec copy"] == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let renewed = NoteLibrary.renewedID("REC-COVER", folder: "Rec copy")
        // Meanwhile the file changes elsewhere: the renewal's write is kept beside it.
        var elsewhere = cover
        elsewhere.body = "# About this notebook\nRec, edited elsewhere"
        try? Data(elsewhere.serialized().utf8).write(to: coverB)
        hold.signal()
        until = Date().addingTimeInterval(8)
        let copyB = b.appending(path: "About this notebook (conflicted copy).md")
        while !fm.fileExists(atPath: copyB.path) && Date() < until { settle(0.1) }
        store.reload()
        settle(1.5)
        expect(fm.fileExists(atPath: copyB.path) && !store.pendingIDs.contains(renewed) && store.renewing["Rec copy"] == nil,
               "a renewal kept beside the file: reconciled after a read, nothing left waiting for it")
        guard let canonical = store.notes.first(where: { $0.notebook == "Rec copy" && NoteLibrary.isCanonicalCover($0.url.lastPathComponent) && $0.version == nil }) else {
            return expect(false, "the cover is read")
        }
        expect(store.conflict(of: canonical)?.count == 2, "the copy shows as the cover's conflict")
        store.keep(canonical)
        until = Date().addingTimeInterval(10)
        func idOnDisk() -> String? { text(coverB).map { NoteFile.parse($0, fallbackID: "", fallbackDate: Date()).id } }
        while (fm.fileExists(atPath: copyB.path) || idOnDisk() != renewed) && Date() < until { settle(0.2); store.reload() }
        settle(1)
        expect(!fm.fileExists(atPath: copyB.path) && idOnDisk() == renewed && text(coverB)?.contains("edited elsewhere") == true
               && !store.pendingIDs.contains(renewed) && store.coverID("Rec copy") == renewed,
               "after Keep, the cover gets its own id cleanly (its words kept) and nothing waits", "\(idOnDisk() ?? "nil")")
        for folder in [a, b] { try? fm.removeItem(at: folder) }
    }

    /// A cover named in another case ("about this notebook.md") is the cover, read and known.
    static func lowercaseCover(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Lower")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var cover = NoteFile(id: "LOWER-COVER", body: "# About this notebook\nlower")
        cover.cover = true
        _ = NoteStore.create(cover.serialized(), at: folder.appending(path: "about this notebook.md"), root: root)
        let book = NoteStore.read(root).notebooks.first { $0.name == "Lower" }
        expect(book?.cover != nil && book?.coverUnread == false && book?.privacyUnknown == false && book?.isPrivate == false,
               "a lowercase cover name is read as the cover, known and public")
        try? fm.removeItem(at: folder)
    }

    /// A folder that can't be listed is never taken for an empty one: the read isn't complete.
    static func listingErrors(root: URL) {
        let fm = FileManager.default
        let locked = root.appending(path: "Unlistable")
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        _ = NoteStore.create("a note", at: locked.appending(path: "One.md"), root: root)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let read = NoteStore.read(root)
        expect(!read.complete, "a notebook folder that can't be listed: the read isn't complete")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        expect(NoteStore.read(root).notes.contains { $0.notebook == "Unlistable" }, "once it can be, its notes are there")
        try? fm.removeItem(at: locked)
        let gone = root.deletingLastPathComponent().appending(path: "No root \(UUID().uuidString)/Inner")
        try? fm.createDirectory(at: gone, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: gone.path)
        expect(!NoteStore.read(gone).complete, "a notes folder that can't be listed: not complete")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gone.path)
        try? fm.removeItem(at: gone.deletingLastPathComponent())
    }

    /// A canvas edit made while its notebook's cover id isn't known (its cover can't be read yet) is journaled at once
    /// by the notebook's folder, then re-keyed by the cover id once it's known, and lands.
    @MainActor static func canvasByFolder(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Downloading")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var cover = NoteFile(id: "COVER-DL", body: "# About this notebook")
        cover.cover = true
        let coverURL = folder.appending(path: NoteShelf.coverName)
        _ = NoteStore.create(cover.serialized(), at: coverURL, root: root)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: coverURL.path)
        let canvasFile = folder.appending(path: NoteStore.canvasName)
        try? fm.createDirectory(at: canvasFile, withIntermediateDirectories: true)   // writes fail for now
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        store.reload()
        settle(1)
        let instance = store.notebook("Downloading")?.instance ?? ""
        expect(store.coverID("Downloading") == nil && !instance.isEmpty && store.canvasEditable("Downloading"), "a cover not read: no cover id, but its folder is known")
        store.editCanvas("Downloading", .move("n1", .init(x: 7, y: 7))) { _ in }
        NoteJournal.queue.sync {}
        let byFolder = NoteJournal.readCanvas(NoteJournal.canvasFile(CanvasQueue.folderKey(instance)))
        expect(byFolder?.edits.count == 1, "journaled at once by the notebook's folder")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: coverURL.path)
        store.reload()
        settle(1.5)
        NoteJournal.queue.sync {}
        expect(store.coverID("Downloading") == "COVER-DL" && NoteJournal.readCanvas(NoteJournal.canvasFile(CanvasQueue.folderKey(instance)))?.edits.count == 1
               && !fm.fileExists(atPath: NoteJournal.canvasFile("COVER-DL").path), "its cover id known, the edit stays keyed by its own folder")
        try? fm.removeItem(at: canvasFile)
        let until = Date().addingTimeInterval(10)
        while NoteCanvas.decode(text(canvasFile))?.notes["n1"] == nil && Date() < until { settle(0.2) }
        NoteJournal.queue.sync {}
        expect(NoteCanvas.decode(text(canvasFile))?.notes["n1"]?.x == 7 && !fm.fileExists(atPath: NoteJournal.canvasFile(CanvasQueue.folderKey(instance)).path), "and lands")
        try? fm.removeItem(at: folder)
    }

    /// A notebook's folder replaced (iCloud writes a new folder at the same path: a new inode) while canvas edits wait:
    /// they're found by the same path and cover id, and land in that notebook's canvas, with what it held.
    @MainActor static func folderReplaced(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Replaced")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var cover = NoteFile(id: "COVER-RE", body: "# About this notebook")
        cover.cover = true
        _ = NoteStore.create(cover.serialized(), at: folder.appending(path: NoteShelf.coverName), root: root)
        let canvasFile = folder.appending(path: NoteStore.canvasName)
        try? fm.createDirectory(at: canvasFile, withIntermediateDirectories: true)   // writes fail for now
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        store.reload()
        settle(1)
        let before = store.notebook("Replaced")?.instance ?? ""
        store.editCanvas("Replaced", .move("r1", .init(x: 4, y: 4))) { _ in }
        settle(0.3)
        // The folder replaced: a new one (new inode) at the same path, its cover and a canvas of its own.
        let aside = root.appending(path: "Replaced-old")
        try? fm.moveItem(at: folder, to: aside)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NoteStore.create(cover.serialized(), at: folder.appending(path: NoteShelf.coverName), root: root)
        let held = NoteCanvas().applying(.area(.init(id: "kept", label: "Kept", x: 0, y: 0, w: 10, h: 10)), at: 1)
        try? Data(held.encoded().utf8).write(to: canvasFile)
        try? fm.removeItem(at: aside)
        store.reload()
        let until = Date().addingTimeInterval(12)
        while NoteCanvas.decode(text(canvasFile))?.notes["r1"] == nil && Date() < until { settle(0.2) }
        NoteJournal.queue.sync {}
        let landed = NoteCanvas.decode(text(canvasFile))
        expect(store.notebook("Replaced")?.instance != before && landed?.notes["r1"]?.x == 4 && landed?.areas.first?.id == "kept"
               && !fm.fileExists(atPath: NoteJournal.canvasFile(CanvasQueue.folderKey(before)).path),
               "a folder replaced at the same path: the waiting edit lands in that notebook's canvas, never declared gone")
        try? fm.removeItem(at: folder)
    }

    /// A notebook really deleted while canvas edits wait: rescued into Unsaved notes with the whole canvas (the last
    /// one Petal read, with the edits), never an empty one.
    @MainActor static func deletedNotebookRescue(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Deleted")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var cover = NoteFile(id: "COVER-DEL", body: "# About this notebook")
        cover.cover = true
        _ = NoteStore.create(cover.serialized(), at: folder.appending(path: NoteShelf.coverName), root: root)
        let canvasFile = folder.appending(path: NoteStore.canvasName)
        let held = NoteCanvas().applying(.area(.init(id: "kept", label: "Kept", x: 0, y: 0, w: 10, h: 10)), at: 1)
        try? Data(held.encoded().utf8).write(to: canvasFile)
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        store.reload()
        settle(1)
        var read: NoteCanvas?
        store.canvas("Deleted") { read = $0 }
        settle(0.5)
        expect(read?.areas.first?.id == "kept", "the canvas read")
        try? fm.removeItem(at: canvasFile)
        try? fm.createDirectory(at: canvasFile, withIntermediateDirectories: true)   // writes fail for now
        store.editCanvas("Deleted", .move("d1", .init(x: 3, y: 3))) { _ in }
        settle(0.3)
        try? fm.removeItem(at: folder)
        store.reload()
        let unsaved = Config.supportFolder.appending(path: "Unsaved notes")
        func rescued() -> NoteCanvas? {
            let folders = (try? fm.contentsOfDirectory(at: unsaved, includingPropertiesForKeys: nil)) ?? []
            for dir in folders {
                if let saved = text(dir.appending(path: "Deleted canvas.json")), let canvas = NoteCanvas.decode(saved) { return canvas }
            }
            return nil
        }
        let until = Date().addingTimeInterval(10)
        while rescued() == nil && Date() < until { settle(0.2) }
        let kept = rescued()
        expect(kept?.notes["d1"]?.x == 3 && kept?.areas.first?.id == "kept", "a notebook really deleted: rescued with the whole canvas, its areas and the edit",
               kept.map { $0.encoded() } ?? "nil")
    }

    /// A different notebook at the old path (and a copy elsewhere keeping the old cover id) while canvas edits wait:
    /// ambiguous, so they're written into neither; they wait, and once ambiguous for the limit over complete reads
    /// they're rescued whole into Unsaved notes and leave the journal. At a launch's recovery, an ambiguous entry is
    /// rescued the same way.
    @MainActor static func ambiguousRescue(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Unsure"), copy = root.appending(path: "Unsure elsewhere")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var cover = NoteFile(id: "COVER-UNSURE", body: "# About this notebook")
        cover.cover = true
        _ = NoteStore.create(cover.serialized(), at: folder.appending(path: NoteShelf.coverName), root: root)
        let canvasFile = folder.appending(path: NoteStore.canvasName)
        let held = NoteCanvas().applying(.area(.init(id: "kept", label: "Kept", x: 0, y: 0, w: 10, h: 10)), at: 1)
        try? Data(held.encoded().utf8).write(to: canvasFile)
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        store.reload()
        settle(1)
        var read: NoteCanvas?
        store.canvas("Unsure") { read = $0 }
        settle(0.5)
        expect(read?.areas.first?.id == "kept", "the canvas read")
        try? fm.removeItem(at: canvasFile)
        try? fm.createDirectory(at: canvasFile, withIntermediateDirectories: true)   // writes fail for now
        store.editCanvas("Unsure", .move("u1", .init(x: 6, y: 6))) { _ in }
        settle(0.3)
        let key = store.canvasWaiting.keys.first ?? ""
        // Replaced by a different notebook at the same path, and a copy elsewhere keeping the old cover id.
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var other = NoteFile(id: "COVER-OTHER", body: "# About this notebook")
        other.cover = true
        _ = NoteStore.create(other.serialized(), at: folder.appending(path: NoteShelf.coverName), root: root)
        try? fm.createDirectory(at: copy, withIntermediateDirectories: true)
        _ = NoteStore.create(cover.serialized(), at: copy.appending(path: NoteShelf.coverName), root: root)
        store.reload()
        settle(2)
        let unsaved = Config.supportFolder.appending(path: "Unsaved notes")
        func rescued(_ name: String) -> NoteCanvas? {
            for dir in (try? fm.contentsOfDirectory(at: unsaved, includingPropertiesForKeys: nil)) ?? [] {
                if let saved = text(dir.appending(path: name + " canvas.json")), let canvas = NoteCanvas.decode(saved) { return canvas }
            }
            return nil
        }
        func untouched() -> Bool {
            [folder, copy].allSatisfy { NoteCanvas.decode(text($0.appending(path: NoteStore.canvasName)))?.notes["u1"] == nil }
        }
        expect(store.readComplete && store.canvasWaiting[key] != nil && store.canvasAmbiguousSince[key] != nil && rescued("Unsure") == nil && untouched(),
               "ambiguous: written into neither notebook, and it waits")
        // Ten minutes of complete reads later.
        store.canvasAmbiguousSince[key] = Date().addingTimeInterval(-NoteShelf.ambiguityLimit - 1)
        store.reload()
        let until = Date().addingTimeInterval(10)
        while rescued("Unsure") == nil && Date() < until { settle(0.2) }
        NoteJournal.queue.sync {}
        let kept = rescued("Unsure")
        expect(kept?.notes["u1"]?.x == 6 && kept?.areas.first?.id == "kept" && untouched() && store.canvasWaiting[key] == nil
               && !fm.fileExists(atPath: NoteJournal.canvasFile(key).path),
               "still ambiguous after the limit: rescued whole into Unsaved notes, out of the journal, never written into either notebook")
        // At a launch's recovery: an ambiguous entry is rescued; one only waiting on an incomplete read is kept.
        let places = [NotebookPlace(name: "Unsure", path: "Unsure", instance: "1:2", coverID: "COVER-OTHER")]
        let entry = CanvasEntry(coverID: "folder:9:9", notebook: "Launch unsure", edits: [NoteCanvas.Stamped(.move("l1", .init(x: 1, y: 1)))],
                                binding: NotebookBinding(coverID: "COVER-LAUNCH", path: "Unsure", instance: "9:9"), snapshot: held)
        expect(!NoteJournal.landCanvas(entry, places: places, notebooks: [], complete: false, root: root) && rescued("Launch unsure") == nil,
               "at recovery, ambiguous on an incomplete read: kept for the next launch")
        expect(NoteJournal.landCanvas(entry, places: places, notebooks: [], complete: true, root: root)
               && rescued("Launch unsure")?.notes["l1"] != nil && rescued("Launch unsure")?.areas.first?.id == "kept",
               "at recovery, still ambiguous: rescued whole, never written into a notebook")
        for f in [folder, copy] { try? fm.removeItem(at: f) }
    }

    /// Cover changes that can't tell which notebook they're for: a Private one makes every candidate Private (fails
    /// closed) and is dropped and said after the limit over complete reads, or at once when a launch recovered it; one
    /// making a notebook public waits without changing anything.
    @MainActor static func ambiguousCovers(root: URL) {
        let fm = FileManager.default
        let here = root.appending(path: "Maybe"), there = root.appending(path: "Maybe elsewhere"), locked = root.appending(path: "Locked")
        for (folder, id, isPrivate) in [(here, "COVER-MAYBE", false), (there, "COVER-LOST", false), (locked, "COVER-LOCKED", true)] {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var cover = NoteFile(id: id, body: "# About this notebook")
            cover.cover = true
            if isPrivate { cover.setScalar("private", "true") }
            _ = NoteStore.create(cover.serialized(), at: folder.appending(path: NoteShelf.coverName), root: root)
        }
        let store = NoteStore(root: root)
        var said: [String] = []
        store.onProblem = { said.append($0) }
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        store.reload()
        settle(1)
        expect(store.notebook("Locked")?.isPrivate == true && store.notebook("Maybe")?.isPrivate == false, "the covers as written")
        // Made for a notebook whose folder is gone: another notebook now at its path, its cover id in a copy elsewhere.
        var privately = CoverFields(notebook: "Maybe", root: store.root.path, coverID: "COVER-LOST", folderID: "0:1", path: "Maybe")
        privately.set("private", "true")
        store.coverPending[privately.key] = privately
        NoteJournal.queue.async { NoteJournal.keepCover(privately) }
        // Making the Private one public, equally unsure.
        var publicly = CoverFields(notebook: "Locked", root: store.root.path, coverID: "COVER-LOCKED-OLD", folderID: "0:2", path: "Locked")
        publicly.set("private", "")
        store.coverPending[publicly.key] = publicly
        store.reload()
        settle(1.5)
        let books = store.privateBooks
        expect(store.notebook("Maybe")?.isPrivate == true && store.notebook("Maybe elsewhere")?.isPrivate == true
               && books.contains("Maybe") && books.contains("Maybe elsewhere")
               && !NotePrivacy.readable(notebook: "Maybe elsewhere", privateBooks: books, asker: nil),
               "an ambiguous Private change: every notebook it could mean is Private for everything Private covers")
        func privateOnDisk(_ folder: URL) -> Bool { text(folder.appending(path: NoteShelf.coverName)).map { NoteContract.isPrivate(NoteFile.parse($0, fallbackID: "", fallbackDate: Date())) } == true }
        expect(!privateOnDisk(here) && !privateOnDisk(there) && store.coverPending[privately.key] != nil && said.isEmpty,
               "written to neither, and it waits")
        expect(store.notebook("Locked")?.isPrivate == true && privateOnDisk(locked) && store.coverPending[publicly.key] != nil,
               "an ambiguous change making one public waits and changes nothing")
        // Ten minutes of complete reads later: dropped, said plainly, out of the journal, and the candidates as written.
        store.coverAmbiguousSince[privately.key] = Date().addingTimeInterval(-NoteShelf.ambiguityLimit - 1)
        store.reload()
        settle(1.5)
        NoteJournal.queue.sync {}
        expect(store.coverPending[privately.key] == nil && said.contains("Petal couldn't tell which notebook to make Private. Set it again.")
               && !fm.fileExists(atPath: NoteJournal.coverFile(privately.key).path)
               && store.notebook("Maybe")?.isPrivate == false && store.notebook("Maybe elsewhere")?.isPrivate == false && !privateOnDisk(here),
               "still ambiguous after the limit: dropped and said, never applied", "\(said)")
        // A launch recovering one that's still ambiguous: dropped on its first complete read, and its copy goes.
        said = []
        let waiting = store.recoverCovers([privately])
        settle(1)
        expect(store.coverPending[privately.key] == nil && said.contains("Petal couldn't tell which notebook to make Private. Set it again.")
               && waiting.allSatisfy(\.isEmpty), "recovered at launch and still ambiguous: dropped and said at once", "\(said)")
        store.coverPending[publicly.key] = nil
        for folder in [here, there, locked] { try? fm.removeItem(at: folder) }
    }

    /// A canvas write checks its binding again inside its coordinated step: the folder replaced by another notebook
    /// between the queue and the write, nothing is written and the edits stay waiting, in the journal too.
    @MainActor static func writeRechecksBinding(root: URL) {
        let fm = FileManager.default
        let folder = root.appending(path: "Recheck")
        func makeNotebook(_ id: String) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var cover = NoteFile(id: id, body: "# About this notebook")
            cover.cover = true
            _ = NoteStore.create(cover.serialized(), at: folder.appending(path: NoteShelf.coverName), root: root)
        }
        makeNotebook("COVER-RECHECK")
        let canvasFile = folder.appending(path: NoteStore.canvasName)
        // The function itself: a binding that no longer finds the folder writes nothing.
        let old = NoteStore.bindingNow(folder, root: root)
        expect(NoteStore.writeCanvas(.move("p", .init(x: 1, y: 1)), binding: old, in: folder, root: root)?.notes["p"] != nil, "its own folder: written")
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        store.reload()
        settle(1)
        // The files' queue held: the write is queued, and the folder is replaced by another notebook meanwhile.
        let hold = DispatchSemaphore(value: 0)
        NoteStore.io.async { hold.wait() }
        store.editCanvas("Recheck", .move("q1", .init(x: 8, y: 8))) { _ in }
        try? fm.removeItem(at: folder)
        makeNotebook("COVER-SOMEONE-ELSE")
        hold.signal()
        settle(1)
        NoteJournal.queue.sync {}
        let key = store.canvasWaiting.keys.first ?? ""
        expect(NoteCanvas.decode(text(canvasFile))?.notes["q1"] == nil && store.canvasWaiting[key]?.edits.count == 1
               && NoteJournal.readCanvas(NoteJournal.canvasFile(key))?.edits.count == 1,
               "the binding checked inside the write: another notebook there now, nothing written, the edit kept (journal too)")
        expect(NoteStore.writeCanvas(.move("p2", .init(x: 1, y: 1)), binding: old, in: folder, root: root) == nil
               && NoteCanvas.decode(text(canvasFile))?.notes["p2"] == nil, "and the function refuses a binding that no longer finds it")
        store.drainCanvas()
        NoteJournal.ackCanvas(key, wrote: Set(NoteJournal.readCanvas(NoteJournal.canvasFile(key))?.edits.map(\.id) ?? []))
        try? fm.removeItem(at: folder)
    }

    /// Canvas edits are bound to the notes' folder they were made in: after a switch to another (with a notebook of
    /// the same name and cover), they're never written there; they wait for their own folder, and are rescued whole
    /// under the same limit, or at the next launch.
    @MainActor static func canvasOtherRoot(root: URL) {
        let fm = FileManager.default
        let rootB = root.deletingLastPathComponent().appending(path: "petal-root-B-\(UUID().uuidString)")
        for base in [root, rootB] {
            let folder = base.appending(path: "Shared")
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var cover = NoteFile(id: "COVER-SHARED", body: "# About this notebook")
            cover.cover = true
            _ = NoteStore.create(cover.serialized(), at: folder.appending(path: NoteShelf.coverName), root: base)
        }
        let canvasA = root.appending(path: "Shared").appending(path: NoteStore.canvasName)
        let canvasB = rootB.appending(path: "Shared").appending(path: NoteStore.canvasName)
        try? fm.createDirectory(at: canvasA, withIntermediateDirectories: true)   // A's writes fail for now
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        store.reload()
        settle(1)
        store.editCanvas("Shared", .move("s1", .init(x: 5, y: 5))) { _ in }
        settle(0.3)
        let key = store.canvasWaiting.keys.first ?? ""
        var switched = false
        store.switchRoot(to: rootB) { switched = true }
        var until = Date().addingTimeInterval(8)
        while (!switched || !store.loaded) && Date() < until { settle(0.1) }
        store.reload()
        settle(1.5)
        NoteJournal.queue.sync {}
        expect(store.canvasWaiting[key] == nil && NoteCanvas.decode(text(canvasB))?.notes["s1"] == nil
               && NoteJournal.readCanvas(NoteJournal.canvasFile(key))?.edits.count == 1,
               "after a switch: the old folder's session is gone, the edit waits in the journal, never written into the other folder's notebook of the same name and cover")
        // Back in its own folder: a fresh session takes it from the journal, and it lands once the canvas can be written.
        var home = false
        store.switchRoot(to: root) { home = true }
        until = Date().addingTimeInterval(8)
        while (!home || !store.loaded) && Date() < until { settle(0.1) }
        settle(0.5)
        expect(store.canvasWaiting[key]?.edits.count == 1, "back in its folder: a fresh session takes it from the journal")
        try? fm.removeItem(at: canvasA)
        store.reload()
        until = Date().addingTimeInterval(10)
        while NoteCanvas.decode(text(canvasA))?.notes["s1"] == nil && Date() < until { settle(0.2) }
        NoteJournal.queue.sync {}
        expect(NoteCanvas.decode(text(canvasA))?.notes["s1"]?.x == 5 && !fm.fileExists(atPath: NoteJournal.canvasFile(key).path)
               && NoteCanvas.decode(text(canvasB))?.notes["s1"] == nil, "and lands in its own notebook, never the other folder's")
        let unsaved = Config.supportFolder.appending(path: "Unsaved notes")
        func rescued(_ name: String) -> NoteCanvas? {
            for dir in (try? fm.contentsOfDirectory(at: unsaved, includingPropertiesForKeys: nil)) ?? [] {
                if let saved = text(dir.appending(path: name + " canvas.json")), let canvas = NoteCanvas.decode(saved), !canvas.notes.isEmpty { return canvas }
            }
            return nil
        }
        // At a launch whose notes' folder is another: rescued, never written there.
        let read = NoteStore.read(rootB)
        let entry = CanvasEntry(coverID: "folder:launch", notebook: "Launch shared", edits: [NoteCanvas.Stamped(.move("l2", .init(x: 2, y: 2)))],
                                binding: NotebookBinding(coverID: "COVER-SHARED", path: "Shared", instance: "", root: root.path))
        expect(NoteJournal.landCanvas(entry, places: NoteStore.places(notes: read.notes, notebooks: read.notebooks), notebooks: read.notebooks,
                                      complete: read.complete, root: rootB)
               && rescued("Launch shared")?.notes["l2"] != nil && NoteCanvas.decode(text(canvasB))?.notes["l2"] == nil,
               "recovered at a launch in another notes folder: rescued, never written there")
        try? fm.removeItem(at: rootB)
        try? fm.removeItem(at: root.appending(path: "Shared"))
    }

    /// A switch of notes' folder with a cover write in flight: its completion never comes back, and the flags in
    /// flight go with the old folder; back in it, a Private change saves.
    @MainActor static func switchBackSavesCover(root: URL) {
        let fm = FileManager.default
        let rootB = root.deletingLastPathComponent().appending(path: "petal-root-B-\(UUID().uuidString)")
        try? fm.createDirectory(at: rootB, withIntermediateDirectories: true)
        let folder = root.appending(path: "Roundtrip")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var cover = NoteFile(id: "COVER-ROUND", body: "# About this notebook")
        cover.cover = true
        _ = NoteStore.create(cover.serialized(), at: folder.appending(path: NoteShelf.coverName), root: root)
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        func switchTo(_ next: URL) {
            var done = false
            store.switchRoot(to: next) { done = true }
            let until = Date().addingTimeInterval(8)
            while (!done || !store.loaded) && Date() < until { settle(0.05) }
            settle(1)
        }
        store.reload()
        settle(1)
        // A color change in flight when the folder switches.
        store.setCover("Roundtrip", fields: ["color": "#336699"])
        expect(!store.coverLanding.isEmpty, "a cover write in flight")
        switchTo(rootB)
        expect(store.coverLanding.isEmpty, "the switch ends what was in flight with the old folder")
        switchTo(root)
        store.setCover("Roundtrip", fields: ["private": "true"])
        func onDisk() -> NoteFile? { text(folder.appending(path: NoteShelf.coverName)).map { NoteFile.parse($0, fallbackID: "", fallbackDate: Date()) } }
        let until = Date().addingTimeInterval(8)
        while onDisk().map(NoteContract.isPrivate) != true && Date() < until { settle(0.2); store.reload() }
        expect(onDisk().map(NoteContract.isPrivate) == true && onDisk()?.color == "#336699" && store.coverPending.isEmpty,
               "back in its folder: the Private change saves, and the change from before lands too", text(folder.appending(path: NoteShelf.coverName)) ?? "nil")
        try? fm.removeItem(at: folder)
        try? fm.removeItem(at: rootB)
    }

    /// A cover renewed in another notes' folder never renews a waiting canvas edit made in this one, even for a
    /// notebook just like its own (same name, same cover id).
    @MainActor static func renewalSkipsOtherRoot(root: URL) {
        let fm = FileManager.default
        let rootB = root.deletingLastPathComponent().appending(path: "petal-root-B-\(UUID().uuidString)")
        func notebook(_ base: URL, _ name: String) {
            let folder = base.appending(path: name)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var cover = NoteFile(id: "COVER-TWIN", body: "# About this notebook")
            cover.cover = true
            _ = NoteStore.create(cover.serialized(), at: folder.appending(path: NoteShelf.coverName), root: base)
        }
        notebook(root, "Twin")
        // In B: "Twin" and a duplicate that sorts first, so B's "Twin" is the one renewed.
        notebook(rootB, "Twin")
        notebook(rootB, "Aaa twin")
        let canvasA = root.appending(path: "Twin").appending(path: NoteStore.canvasName)
        try? fm.createDirectory(at: canvasA, withIntermediateDirectories: true)   // A's writes fail for now
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        store.reload()
        settle(1)
        store.editCanvas("Twin", .move("t1", .init(x: 3, y: 3))) { _ in }
        settle(0.3)
        let key = store.canvasWaiting.keys.first ?? ""
        var done = false
        store.switchRoot(to: rootB) { done = true }
        var until = Date().addingTimeInterval(8)
        while (!done || !store.loaded) && Date() < until { settle(0.05) }
        let renewed = NoteLibrary.renewedID("COVER-TWIN", folder: "Twin")
        func idOnDisk(_ folder: URL) -> String? { text(folder.appending(path: NoteShelf.coverName)).map { NoteFile.parse($0, fallbackID: "", fallbackDate: Date()).id } }
        until = Date().addingTimeInterval(8)
        while idOnDisk(rootB.appending(path: "Twin")) != renewed && Date() < until { settle(0.1); store.reload() }
        settle(0.5)
        NoteJournal.queue.sync {}
        expect(idOnDisk(rootB.appending(path: "Twin")) == renewed && store.canvasWaiting[key] == nil
               && NoteJournal.readCanvas(NoteJournal.canvasFile(key))?.binding?.coverID == "COVER-TWIN",
               "a root A entry is never renewed by a notebook in root B: not in B's session, and unchanged in the journal")
        var back = false
        store.switchRoot(to: root) { back = true }
        until = Date().addingTimeInterval(8)
        while !back && Date() < until { settle(0.05) }
        store.drainCanvas()
        NoteJournal.ackCanvas(key, wrote: Set(NoteJournal.readCanvas(NoteJournal.canvasFile(key))?.edits.map(\.id) ?? []))
        try? fm.removeItem(at: root.appending(path: "Twin"))
        try? fm.removeItem(at: rootB)
    }

    /// A Trash confirmed for a notebook, the notes folder switched while it waits: the other folder's notebook of the
    /// same name is untouched (the session and binding were captured before the wait). And a notebook replaced on disk
    /// between the request and the Trash itself: untouched too (checked inside the coordinated step).
    @MainActor static func trashAfterSwitch(root: URL) {
        let fm = FileManager.default
        let rootB = root.deletingLastPathComponent().appending(path: "petal-root-B-\(UUID().uuidString)")
        for base in [root, rootB] {
            let folder = base.appending(path: "Doomed")
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var cover = NoteFile(id: base == root ? "COVER-DOOMED-A" : "COVER-DOOMED-B", body: "# About this notebook")
            cover.cover = true
            _ = NoteStore.create(cover.serialized(), at: folder.appending(path: NoteShelf.coverName), root: base)
            _ = NoteStore.create("keep me", at: folder.appending(path: "Kept.md"), root: base)
        }
        let store = NoteStore(root: root)
        var said: [String] = []
        store.onProblem = { said.append($0) }
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        store.reload()
        settle(1)
        // Confirmed in A: what NotesModel captures before asking and waiting.
        let session = store.session
        guard let binding = store.binding("Doomed") else { return expect(false, "the notebook's binding") }
        var done = false
        store.switchRoot(to: rootB) { done = true }
        var until = Date().addingTimeInterval(8)
        while (!done || !store.loaded) && Date() < until { settle(0.05) }
        settle(0.5)
        expect(!store.current(session) && store.notebook("Doomed") != nil, "after the switch: the session it was confirmed in is over")
        var trashed: Bool?
        store.trashNotebook("Doomed", binding: binding) { trashed = $0 }
        settle(0.5)
        expect(trashed == false && fm.fileExists(atPath: rootB.appending(path: "Doomed/Kept.md").path) && fm.fileExists(atPath: root.appending(path: "Doomed/Kept.md").path),
               "the other folder's notebook of the same name is untouched, and so is the one confirmed (in a folder not in use)", "\(said)")
        // Replaced on disk between the request and the Trash: the binding is checked inside the coordinated step.
        let inB = store.binding("Doomed")!
        let hold = DispatchSemaphore(value: 0)
        NoteStore.io.async { hold.wait() }
        trashed = nil
        store.trashNotebook("Doomed", binding: inB) { trashed = $0 }
        let doomedB = rootB.appending(path: "Doomed")
        try? fm.removeItem(at: doomedB)
        try? fm.createDirectory(at: doomedB, withIntermediateDirectories: true)
        var other = NoteFile(id: "COVER-SOMEONE-ELSE", body: "# About this notebook")
        other.cover = true
        _ = NoteStore.create(other.serialized(), at: doomedB.appending(path: NoteShelf.coverName), root: rootB)
        _ = NoteStore.create("someone else's", at: doomedB.appending(path: "Theirs.md"), root: rootB)
        hold.signal()
        until = Date().addingTimeInterval(5)
        while trashed == nil && Date() < until { settle(0.05) }
        expect(trashed == false && fm.fileExists(atPath: doomedB.appending(path: "Theirs.md").path),
               "another notebook there by the time the Trash runs: untouched")
        var back = false
        store.switchRoot(to: root) { back = true }
        until = Date().addingTimeInterval(8)
        while !back && Date() < until { settle(0.05) }
        try? fm.removeItem(at: root.appending(path: "Doomed"))
        try? fm.removeItem(at: rootB)
    }

    /// A switch while a duplicated cover's new id is being written, and back: the fresh session finds the renewal on
    /// disk (or makes it again), nothing from the old session blocks it, and cover changes save.
    @MainActor static func renewalAcrossSwitch(root: URL) {
        let fm = FileManager.default
        let rootB = root.deletingLastPathComponent().appending(path: "petal-root-B-\(UUID().uuidString)")
        try? fm.createDirectory(at: rootB, withIntermediateDirectories: true)
        for name in ["Aaa round", "Zed round"] {
            let folder = root.appending(path: name)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var cover = NoteFile(id: "COVER-ROUND-DUP", body: "# About this notebook")
            cover.cover = true
            _ = NoteStore.create(cover.serialized(), at: folder.appending(path: NoteShelf.coverName), root: root)
        }
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        func switchTo(_ next: URL) {
            var done = false
            store.switchRoot(to: next) { done = true }
            let until = Date().addingTimeInterval(8)
            while (!done || !store.loaded) && Date() < until { settle(0.05) }
            settle(1)
        }
        // The folder switches in the same turn the read starts the renewal: its write's completion never comes back.
        var underWay = false, done = false
        store.onChange = {
            guard !underWay, !store.renewing.isEmpty else { return }
            underWay = true
            store.switchRoot(to: rootB) { done = true }
        }
        store.reload()
        var until = Date().addingTimeInterval(5)
        while !underWay && Date() < until { settle(0.05) }
        store.onChange = {}
        expect(underWay, "a renewal under way when the folder switches")
        until = Date().addingTimeInterval(8)
        while (!done || !store.loaded) && Date() < until { settle(0.05) }
        expect(store.renewing.isEmpty && store.pendingIDs.isEmpty && store.coverLanding.isEmpty, "the new folder's session starts with nothing in flight")
        switchTo(root)
        let renewed = NoteLibrary.renewedID("COVER-ROUND-DUP", folder: "Zed round")
        func onDisk(_ name: String) -> NoteFile? {
            text(root.appending(path: name).appending(path: NoteShelf.coverName)).map { NoteFile.parse($0, fallbackID: "", fallbackDate: Date()) }
        }
        until = Date().addingTimeInterval(8)
        while onDisk("Zed round")?.id != renewed && Date() < until { settle(0.2); store.reload() }
        store.setCover("Zed round", fields: ["private": "true"])
        store.setCover("Aaa round", fields: ["color": "#112233"])
        until = Date().addingTimeInterval(10)
        while (onDisk("Zed round").map(NoteContract.isPrivate) != true || onDisk("Aaa round")?.color != "#112233") && Date() < until { settle(0.2); store.reload() }
        expect(onDisk("Zed round")?.id == renewed && onDisk("Zed round").map(NoteContract.isPrivate) == true
               && onDisk("Aaa round")?.id == "COVER-ROUND-DUP" && onDisk("Aaa round")?.color == "#112233" && !onDisk("Aaa round").map(NoteContract.isPrivate)!,
               "back after a switch during a renewal: the renewal is on disk, and cover changes save on the right notebooks")
        for name in ["Aaa round", "Zed round"] { try? fm.removeItem(at: root.appending(path: name)) }
        try? fm.removeItem(at: rootB)
    }

    /// A picture pasted while its folder in Pictures can't be written, the notes folder switched away and back, and
    /// the note edited: the fresh session first puts back that folder's journal entries as a launch does, so the
    /// picture's bytes survive (the note in Unsaved notes with its picture, or landed once writable), never replaced
    /// by a snapshot without them.
    @MainActor static func picturesSurviveSwitch(root: URL) {
        let fm = FileManager.default
        let rootB = root.deletingLastPathComponent().appending(path: "petal-root-B-\(UUID().uuidString)")
        try? fm.createDirectory(at: rootB, withIntermediateDirectories: true)
        let folder = root.appending(path: "Pics")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NoteStore.create(NoteFile(id: "PX-SWITCH", body: "words").serialized(), at: folder.appending(path: "Picture note.md"), root: root)
        // Its folder in Pictures can't be written: a file stands where it would be.
        let blocker = root.appending(path: NoteShelf.pictureFolder(id: "PX-SWITCH"))
        try? fm.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("not a folder".utf8).write(to: blocker)
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        func switchTo(_ next: URL) {
            var done = false
            store.switchRoot(to: next) { done = true }
            let until = Date().addingTimeInterval(10)
            while (!done || !store.loaded) && Date() < until { settle(0.05) }
            settle(0.5)
        }
        store.reload()
        settle(1)
        let bytes = Data("px-switch-bytes".utf8)
        guard let paper = store.notes.first(where: { $0.noteID == "PX-SWITCH" }),
              let refs = store.acceptPictures(paper.key, [("png", bytes, "")]) else { return expect(false, "the picture accepted") }
        let name = refs[0].file.lastPathComponent
        _ = store.change(paper.key) { $0.body += "\n![](\(refs[0].path))" }
        var until = Date().addingTimeInterval(6)
        while store.pictureTrouble[paper.key] == nil && Date() < until { settle(0.05) }
        NoteJournal.queue.sync {}
        expect(store.pictureTrouble[paper.key] != nil && NoteJournal.read(NoteJournal.file("PX-SWITCH"))?.pictures.contains { $0.data == bytes } == true,
               "the picture couldn't be saved: set aside, its bytes in the journal")
        switchTo(rootB)
        switchTo(root)
        // Edited after coming back.
        guard let back = store.notes.first(where: { $0.noteID == "PX-SWITCH" && $0.version == nil }) else { return expect(false, "the note is back") }
        _ = store.change(back.key) { $0.body += "\nmore words" }
        settle(1)
        NoteJournal.queue.sync {}
        // Where its bytes are now: in Unsaved notes with the note, in the journal (live or being recovered), or landed.
        let unsaved = Config.supportFolder.appending(path: "Unsaved notes")
        func rescuedWithNote() -> Bool {
            let all = (fm.enumerator(atPath: unsaved.path)?.allObjects as? [String]) ?? []
            for path in all where (path as NSString).lastPathComponent == name {
                guard (try? Data(contentsOf: unsaved.appending(path: path))) == bytes else { continue }
                // The note beside it in the same rescue, its link to the picture in it.
                let rescue = String(path.split(separator: "/").first ?? "")
                let notes = all.filter { $0.hasPrefix(rescue + "/") && $0.hasSuffix(".md") }
                if notes.contains(where: { (text(unsaved.appending(path: $0)) ?? "").contains(name) }) { return true }
            }
            return false
        }
        func inJournal() -> Bool {
            let parent = NoteJournal.folder.deletingLastPathComponent()
            let folders = [NoteJournal.folder] + NoteShelf.journalFolders((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).map { parent.appending(path: $0) }
            return folders.contains { dir in
                ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains { file in
                    NoteJournal.read(dir.appending(path: file))?.pictures.contains { $0.name == name && $0.data == bytes } == true
                }
            }
        }
        let landed = root.appending(path: NoteShelf.pictureFolder(id: "PX-SWITCH")).appending(path: name)
        expect(rescuedWithNote() || inJournal(), "after the switch back and an edit, the picture's bytes survive (Unsaved notes with the note, or the journal)")
        // Writable again: what the journal still holds lands at the next launch's recovery; a rescue already holds it.
        try? fm.removeItem(at: blocker)
        if !rescuedWithNote() {
            let leftovers = NoteJournal.queue.sync { NoteJournal.leftovers() }
            for holding in leftovers { NoteJournal.recover(holding, root: root) }
        }
        until = Date().addingTimeInterval(4)
        while !(rescuedWithNote() || (try? Data(contentsOf: landed)) == bytes) && Date() < until { settle(0.1) }
        expect(rescuedWithNote() || (try? Data(contentsOf: landed)) == bytes,
               "the picture's bytes land once writable, or the note is in Unsaved notes with its picture")
        try? fm.removeItem(at: folder)
        try? fm.removeItem(at: rootB)
    }

    /// Notes aren't ready until the folder was entered: its journal put back and its first read in. At launch (also
    /// when the folder resolved is the one the store began with) and on a switch back alike, nothing is made, written
    /// or changed meanwhile (⌃⌥N, the tools and every other way in are refused, and it's said); once it's entered,
    /// they work.
    @MainActor static func notReadyDuringRecovery(root: URL) {
        let fm = FileManager.default
        let rootB = root.deletingLastPathComponent().appending(path: "petal-root-B-\(UUID().uuidString)")
        try? fm.createDirectory(at: rootB, withIntermediateDirectories: true)
        let folder = root.appending(path: "Ready")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NoteStore.create(NoteFile(id: "READY-1", body: "there").serialized(), at: folder.appending(path: "There.md"), root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        func files() -> [String] { ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
        // Everything from outside tried while the folder isn't entered: all refused, nothing on disk, and it's said.
        func refusedAll(_ store: NoteStore) -> Bool {
            let before = files()
            let made = store.make(NoteFile(body: "made while getting ready"), in: "Ready")
            store.setCover("Ready", fields: ["private": "true"])
            var edited = false
            store.editCanvas("Ready", .move("r", .init(x: 1, y: 1))) { edited = $0 != nil }
            let changed = store.notes.first.map { store.change($0.key) { $0.body += "!" } }
            return !store.notesReady && made == nil && !edited && (changed ?? nil) == nil && files() == before
        }

        // At launch, the folder resolved being the one the store began with: the journal's queue held, so its
        // recovery can't start.
        let launching = NoteStore(root: root)
        var saidAtLaunch: [String] = []
        launching.onProblem = { saidAtLaunch.append($0) }
        expect(!launching.notesReady, "a store whose folder hasn't been entered isn't ready")
        var hold = DispatchSemaphore(value: 0)
        NoteJournal.queue.async { [hold] in hold.wait() }
        var launched = false
        launching.switchRoot(to: root, launch: true) { launched = true }
        settle(0.5)
        expect(!launched && refusedAll(launching) && saidAtLaunch.contains(NoteStore.gettingReady) && launching.notes.isEmpty,
               "at launch, the resolved folder the same as the first: nothing from outside until its recovery and first read are done",
               "\(saidAtLaunch)")
        hold.signal()
        var until = Date().addingTimeInterval(8)
        while !(launched && launching.notesReady) && Date() < until { settle(0.05) }
        expect(launched && launching.notesReady && launching.notes.contains { $0.noteID == "READY-1" }, "recovery done and the first read in: ready")

        // On a switch back: the same.
        let store = launching
        var said: [String] = []
        store.onProblem = { said.append($0) }
        var away = false
        store.switchRoot(to: rootB) { away = true }
        until = Date().addingTimeInterval(8)
        while !away && Date() < until { settle(0.05) }
        hold = DispatchSemaphore(value: 0)
        NoteJournal.queue.async { [hold] in hold.wait() }
        var back = false
        store.switchRoot(to: root) { back = true }
        settle(0.5)
        expect(!back && store.root == root && refusedAll(store) && said.contains(NoteStore.gettingReady),
               "a switch back, its recovery not done: notes aren't ready; nothing is made or changed, and it's said", "\(said)")
        hold.signal()
        until = Date().addingTimeInterval(8)
        while !(back && store.notesReady) && Date() < until { settle(0.05) }
        expect(store.notesReady, "recovery done and the first read in: ready")
        var landed: PaperNote?
        _ = store.make(NoteFile(body: "made once ready"), in: "Ready") { landed = $0 }
        until = Date().addingTimeInterval(5)
        while landed == nil && Date() < until { settle(0.05) }
        expect(landed.map { (text($0.url) ?? "").contains("made once ready") } == true, "once ready, a new note is made")
        try? fm.removeItem(at: folder)
        try? fm.removeItem(at: rootB)
    }

    /// A cover change recovered from the journal (a notebook made Private before a quit, or before a switch away)
    /// lands on its existing cover as part of entering the folder: replayed with the first read through Petal's own
    /// path, with no other file event or read needed.
    @MainActor static func recoveredCoverLands(root: URL) {
        let fm = FileManager.default
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        func privateOnDisk(_ folder: URL) -> Bool {
            text(folder.appending(path: NoteShelf.coverName)).map { NoteContract.isPrivate(NoteFile.parse($0, fallbackID: "", fallbackDate: Date())) } == true
        }
        func notebook(_ name: String, _ id: String) -> URL {
            let folder = root.appending(path: name)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var cover = NoteFile(id: id, body: "# About this notebook")
            cover.cover = true
            _ = NoteStore.create(cover.serialized(), at: folder.appending(path: NoteShelf.coverName), root: root)
            return folder
        }
        // At launch.
        let atLaunch = notebook("Stalled", "COVER-STALLED")
        var kept = CoverFields(notebook: "Stalled", root: root.path, coverID: "COVER-STALLED", folderID: NoteStore.instance(of: atLaunch), path: "Stalled")
        kept.set("private", "true")
        NoteJournal.queue.sync { _ = NoteJournal.keepCover(kept) }
        let store = NoteStore(root: root)
        var startedByEntering = false
        store.switchRoot(to: root, launch: true) { startedByEntering = store.reads == 1 && !store.coverLanding.isEmpty }
        var until = Date().addingTimeInterval(8)
        while !privateOnDisk(atLaunch) && Date() < until { settle(0.05) }
        NoteJournal.queue.sync {}
        expect(startedByEntering && privateOnDisk(atLaunch) && store.reads == 1,
               "a recovered Private change lands on its existing cover with the folder's first read, no other file event", "reads \(store.reads)")
        settle(0.3)
        NoteJournal.queue.sync {}
        expect(!fm.fileExists(atPath: NoteJournal.coverFile(kept.key).path), "and leaves the journal once written")
        // One recovered at launch that's ambiguous is dropped inside the folder's entering (and asks for a read
        // there): the folder is still entered once, by the one sequence.
        let confused = notebook("Confused", "COVER-CONFUSED-NOW")
        var unsure = CoverFields(notebook: "Confused", root: root.path, coverID: "COVER-CONFUSED-THEN", folderID: "0:9", path: "Confused")
        unsure.set("private", "true")
        NoteJournal.queue.sync { _ = NoteJournal.keepCover(unsure) }
        let again = NoteStore(root: root)
        var saidAgain: [String] = []
        again.onProblem = { saidAgain.append($0) }
        var entered = 0
        var enteredSession: RootSession?
        again.switchRoot(to: root, launch: true) { entered += 1; enteredSession = again.session }
        settle(1.5)
        NoteJournal.queue.sync {}
        expect(entered == 1 && again.session === enteredSession && again.notesReady && again.coverPending[unsure.key] == nil
               && saidAgain.contains(unsure.droppedWords) && !privateOnDisk(confused) && !fm.fileExists(atPath: NoteJournal.coverFile(unsure.key).path),
               "a change dropped while its folder is entered: the folder is entered once, and the read it asks for comes after",
               "entered \(entered), said \(saidAgain)")
        try? fm.removeItem(at: confused)
        // On a switch back to its folder.
        let rootB = root.deletingLastPathComponent().appending(path: "petal-root-B-\(UUID().uuidString)")
        try? fm.createDirectory(at: rootB, withIntermediateDirectories: true)
        let onSwitch = notebook("Stalled too", "COVER-STALLED-2")
        var away = false
        store.switchRoot(to: rootB) { away = true }
        until = Date().addingTimeInterval(8)
        while !away && Date() < until { settle(0.05) }
        var second = CoverFields(notebook: "Stalled too", root: root.path, coverID: "COVER-STALLED-2", folderID: NoteStore.instance(of: onSwitch), path: "Stalled too")
        second.set("private", "true")
        NoteJournal.queue.sync { _ = NoteJournal.keepCover(second) }
        var back = false
        let readsBefore = store.reads
        store.switchRoot(to: root) { back = true }
        until = Date().addingTimeInterval(8)
        while !(back && privateOnDisk(onSwitch)) && Date() < until { settle(0.05) }
        expect(back && privateOnDisk(onSwitch) && store.reads == 1 && readsBefore >= 1,
               "and on a switch back: replayed with that folder's first read", "reads \(store.reads)")
        for folder in [atLaunch, onSwitch] { try? fm.removeItem(at: folder) }
        try? fm.removeItem(at: rootB)
    }

    /// An editor's save that arrives after its folder's switch began (refused by the store, which is switching) goes
    /// to that folder's own drain: stored in its note, or, when it can't land there, in Unsaved notes. Never dropped.
    @MainActor static func lateSaveDrained(root: URL) {
        let fm = FileManager.default
        let rootB = root.deletingLastPathComponent().appending(path: "petal-root-B-\(UUID().uuidString)")
        try? fm.createDirectory(at: rootB, withIntermediateDirectories: true)
        let folder = root.appending(path: "Late")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let landsFile = folder.appending(path: "Lands.md"), blockedFile = folder.appending(path: "Blocked.md")
        _ = NoteStore.create(NoteFile(id: "LATE-1", body: "typed before").serialized(), at: landsFile, root: root)
        _ = NoteStore.create(NoteFile(id: "LATE-2", body: "typed before too").serialized(), at: blockedFile, root: root)
        let store = NoteStore(root: root)
        func settle(_ seconds: Double) { let until = Date().addingTimeInterval(seconds); while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        store.reload()
        var until = Date().addingTimeInterval(8)
        while !store.notesReady && Date() < until { settle(0.05) }
        guard let lands = store.notes.first(where: { $0.noteID == "LATE-1" }), let blocked = store.notes.first(where: { $0.noteID == "LATE-2" }) else {
            return expect(false, "the notes are read")
        }
        expect(store.drainLate(key: lands.key, body: "x", base: lands.revision) == nil, "in the folder in use, a save isn't the drain's: it goes through the note")
        var away = false
        store.switchRoot(to: rootB) { away = true }
        // The switch has begun: the store refuses a change from outside, and the text goes to the old folder's drain.
        let refusedByStore = store.change(lands.key, edit: { $0.body = "late words" }) == nil
        let taken = store.drainLate(key: lands.key, body: "late words", base: lands.revision) != nil
        // Its file can't take the text (a folder stands where it was): the drain rescues it.
        try? fm.removeItem(at: blockedFile)
        try? fm.createDirectory(at: blockedFile, withIntermediateDirectories: true)
        let takenToo = store.drainLate(key: blocked.key, body: "late and blocked", base: blocked.revision) != nil
        expect(refusedByStore && taken && takenToo, "a save after the switch began: refused by the store, taken by its folder's drain")
        expect(store.drainLate(key: "/nowhere/None.md", body: "x", base: nil) == nil, "a note no ended session holds: refused, the editor keeps it")
        let unsaved = Config.supportFolder.appending(path: "Unsaved notes")
        func rescued(_ words: String) -> Bool {
            ((fm.enumerator(atPath: unsaved.path)?.allObjects as? [String]) ?? []).contains { $0.hasSuffix(".md") && (text(unsaved.appending(path: $0)) ?? "").contains(words) }
        }
        until = Date().addingTimeInterval(8)
        while !(away && (text(landsFile) ?? "").contains("late words") && rescued("late and blocked")) && Date() < until { settle(0.1) }
        NoteJournal.queue.sync {}
        expect((text(landsFile) ?? "").contains("late words") && !fm.fileExists(atPath: NoteJournal.file("LATE-1").path),
               "its text is stored in its note, in the folder it was typed in")
        expect(rescued("late and blocked"), "one that can't land there is in Unsaved notes")
        var back = false
        store.switchRoot(to: root) { back = true }
        until = Date().addingTimeInterval(8)
        while !back && Date() < until { settle(0.05) }
        try? fm.removeItem(at: folder)
        try? fm.removeItem(at: rootB)
    }

    /// Making a notebook Private: shown at once, and written through its cover's session, also when it has no cover
    /// (one is made, never over a file) or a cover with no front matter (it gets its id and front matter).
    @MainActor static func privateCovers(root: URL) {
        let fm = FileManager.default
        let bare = root.appending(path: "Bare")
        let plain = root.appending(path: "Plain")
        try? fm.createDirectory(at: bare, withIntermediateDirectories: true)
        try? fm.createDirectory(at: plain, withIntermediateDirectories: true)
        _ = NoteStore.create("hello", at: bare.appending(path: "One.md"), root: root)
        try? Data("# About this notebook\nWritten by hand, no front matter.".utf8).write(to: plain.appending(path: NoteShelf.coverName))
        let store = NoteStore(root: root)
        store.reload()
        var until = Date().addingTimeInterval(5)
        while store.notebook("Plain") == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        expect(store.notebook("Plain")?.cover != nil && store.notebook("Bare")?.cover == nil, "a cover with no front matter is its notebook's cover")
        store.setCover("Bare", fields: ["private": "true"])
        store.setCover("Plain", fields: ["private": "true"])
        expect(store.notebook("Bare")?.isPrivate == true && store.notebook("Plain")?.isPrivate == true, "Private at once, in memory")
        until = Date().addingTimeInterval(8)
        func onDisk(_ folder: URL) -> NoteFile? { text(folder.appending(path: NoteShelf.coverName)).map { NoteFile.parse($0, fallbackID: "", fallbackDate: Date()) } }
        while (onDisk(bare).map(NoteContract.isPrivate) != true || onDisk(plain).map(NoteContract.isPrivate) != true) && Date() < until {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            store.reload()
        }
        expect(onDisk(bare).map(NoteContract.isPrivate) == true && onDisk(bare)?.cover == true, "no cover: one made, and it says private", text(bare.appending(path: NoteShelf.coverName)) ?? "nil")
        let written = onDisk(plain)
        expect(written.map(NoteContract.isPrivate) == true && written?.cover == true && !NoteShelf.needsID(written?.id ?? "file:")
               && written?.body.contains("Written by hand") == true, "a cover with no front matter gets its id and front matter, its words kept",
               text(plain.appending(path: NoteShelf.coverName)) ?? "nil")
        expect(store.notebook("Bare")?.isPrivate == true && store.notebook("Plain")?.isPrivate == true, "and stays Private through reads of the folder")
    }

    /// A notebook's folder renamed: its notes and canvas go with it, never over another notebook, only inside the
    /// notes' folder; a change of case only is the same folder.
    static func notebookFolders(root: URL) {
        let fm = FileManager.default
        let from = root.appending(path: "Trip")
        try? fm.createDirectory(at: from, withIntermediateDirectories: true)
        _ = NoteStore.create("a note", at: from.appending(path: "One.md"), root: root)
        _ = NoteStore.writeCanvas(.move("n1", .init(x: 1, y: 1)), binding: NoteStore.bindingNow(from, root: root), in: from, root: root)
        let to = root.appending(path: "Holiday")
        expect(NoteStore.moveFolder(from, to: to, root: root) && text(to.appending(path: "One.md")) == "a note"
               && fm.fileExists(atPath: to.appending(path: NoteStore.canvasName).path) && !fm.fileExists(atPath: from.path), "renamed, everything in it along")
        let other = root.appending(path: "Other")
        try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        expect(!NoteStore.moveFolder(to, to: other, root: root) && fm.fileExists(atPath: to.appending(path: "One.md").path), "never over another notebook")
        let lower = root.appending(path: "holiday")
        expect(NoteStore.moveFolder(to, to: lower, root: root) && ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).contains("holiday"),
               "a change of case only", "\((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])")
        expect(!NoteStore.moveFolder(lower, to: root.deletingLastPathComponent().appending(path: "Out-\(UUID().uuidString)"), root: root),
               "never out of the notes' folder")
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
