import AppKit

// Checks PaperNotes.swift's file work on throwaway folders in the temporary folder (never the person's notes, never
// the Trash): a save over a file changed elsewhere keeps both, new files never go over another, unidentified files in
// two notebooks stay two notes, nothing is written through a symbolic link, and a file's moved file is followed
// through its bookmark. Stand-ins below for the parts of Petal it would reach. Run with macos/checks/run.sh.
enum Headless { nonisolated(unsafe) static var on = true }
extension NSColor { convenience init?(hex: String?) { nil } }
enum Config { static let supportFolder = FileManager.default.temporaryDirectory.appending(path: "petal-check-support") }

@main
struct NoteStoreCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    static func main() {
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
        expect(copies.count == 1 && text(copy) == "E", "the same edit again updates its copy, never another", "\(copies)")

        // A copy changed elsewhere since Petal wrote it is never written over: the next edit makes another.
        try? Data("the copy, edited elsewhere".utf8).write(to: copy)
        let again = NoteStore.save("F", to: file, base: "B", root: root)
        if case .keptBoth(let next) = again {
            expect(next != copy && text(copy) == "the copy, edited elsewhere" && text(next) == "F", "a copy changed since gets a new copy beside it")
        } else { expect(false, "a copy changed since gets a new copy beside it", "\(again)") }

        // A write that failed (a folder Petal can't write to) is no base for a conflict: the next save, made on it,
        // goes over the file as it was.
        let locked = root.appending(path: "Locked")
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let held = locked.appending(path: "Held.md")
        _ = NoteStore.create("G", at: held, root: root)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        expect(NoteStore.save("H", to: held, base: "G", root: root) == .failed && text(held) == "G", "a failed write leaves the file as it was")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        expect(NoteStore.save("I", to: held, base: "H", root: root) == .written && text(held) == "I", "and the next save, made on the failed one, is written")

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
        finish()
    }

    static func finish() {
        print("note files: \(passed) passed" + (failures > 0 ? ", \(failures) failed" : ""))
        if failures > 0 { exit(1) }
    }
}
