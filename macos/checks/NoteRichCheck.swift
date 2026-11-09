import AppKit

// Checks NoteEditor.swift's text for a note: every kind of line (headings, checkboxes, a link's card, a picture,
// Petal's ink, inline links, list items, empty lines) goes into the editor and comes back as the same Markdown.
// AppKit only: stand-ins below for the parts of Petal it would reach (nothing is fetched or read). Run with
// macos/checks/run.sh.
enum Headless { nonisolated(unsafe) static var on = true }
final class NoteStore {
    nonisolated static let io = DispatchQueue(label: "petal.check.notes")
    static let filesChanged = Notification.Name("petal.check.notesFilesChanged")
    // Where a link leads, as the check says (nil: "not there"); every read is counted.
    nonisolated(unsafe) static var files: [String: URL] = [:]
    nonisolated(unsafe) static var reads = 0
    nonisolated static func pictureFile(_ link: String, noteFolder: URL, root: URL? = nil) -> URL? {
        reads += 1
        return NoteShelf.pictureTarget(link, noteFolder: noteFolder.path).flatMap { files[$0] }
    }
}
// Only what a card may use: what's cached, and a fetch for a link the person added. No `icon` (which fetches), so
// drawing a card through it wouldn't compile.
@MainActor final class Sites { static let shared = Sites(); func cachedIcon(_ id: String) -> NSImage? { nil }; func requestIcon(_ id: String) {} }
struct PaperNote { var file: NoteFile; var url: URL; var revision: String? = nil; var instance = ""; var key: String { url.path }; var noteID: String { file.id } }

/// What the note editor's coordinator answers for undo (NoteTextView.undo(for:)).
final class UndoDelegate: NSObject, NSTextViewDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? { NoteTextView.undo(for: view) }
}

@main
struct NoteRichCheck {
    @MainActor static func main() {
        var failures = 0
        let style = NoteRich.Style(ink: .black, dim: .gray, petal: .blue, accent: .blue)
        let bodies = [
            "# Title\n\nwords with [a link](https://a.b/c) and https://x.y/z\n- [ ] todo\n- [x] done\nhttps://example.com/page\n![cap](<a b.assets/p.png>)\n> ink line\n>\n## Sub\n- bullet\n",
            "",
            "one line",
            "### Small\n> answer\n> more\n\nafter",
        ]
        for body in bodies {
            let editor = NoteRich.attributed(NoteBlock.blocks(body), base: URL(fileURLWithPath: "/tmp"), style: style)
            let back = NoteBlock.body(NoteRich.blocks(editor))
            if back != body && !(body.isEmpty && back.isEmpty) {
                failures += 1
                print("FAIL the editor changed a note:\n---\n\(body)\n---\n\(back)\n---")
            }
        }
        // A card or picture joined to the words around it (the newline between deleted, or typed beside it): every
        // part stays, each on a line of its own.
        let joined = NSMutableAttributedString(attributedString: NoteRich.attributed(NoteBlock.blocks("before\nhttps://example.com/page\nafter\n![cap](p.png)"),
                                                                                     base: URL(fileURLWithPath: "/tmp"), style: style))
        let ns = joined.string as NSString
        joined.deleteCharacters(in: NSRange(location: ns.range(of: "after").location - 1, length: 1))   // the card's newline
        joined.deleteCharacters(in: NSRange(location: (joined.string as NSString).range(of: "before").location + 6, length: 1))   // before's newline
        let kept = NoteBlock.body(NoteRich.blocks(joined))
        if kept != "before\nhttps://example.com/page\nafter\n![cap](p.png)" {
            failures += 1
            print("FAIL words beside a card were lost:\n\(kept)")
        }
        let roundTrips = bodies.count + 1 - failures
        // A picture arriving: the editors showing it lay out, draw and measure it again; other pictures untouched.
        var checks = 0
        func expect(_ ok: Bool, _ what: String, _ detail: String = "") { checks += 1; if !ok { failures += 1; print("FAIL \(what) \(detail)") } }
        let folder = URL(fileURLWithPath: "/tmp/petal-rich/Inbox")
        let storage = NSTextStorage(), layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 400), textContainer: container)
        view.noteFolder = folder
        var measured = 0
        view.remeasure = { measured += 1 }
        storage.setAttributedString(NoteRich.attributed(NoteBlock.blocks("words\n![](../Pictures/abc/p.png)\nmore\n![](Trip.assets/q.png)"), base: folder, style: style))
        let arrived = view.pictureArrived("/tmp/petal-rich/Pictures/abc/p.png")
        expect(arrived.count == 1 && measured == 1, "a picture that arrived: its attachment laid out again and the paper measured again")
        expect(view.pictureArrived("/tmp/petal-rich/Pictures/other/p.png").isEmpty && measured == 1, "another picture's arrival: nothing done")
        var heard: String?
        let token = NotificationCenter.default.addObserver(forName: NotePictures.arrived, object: nil, queue: nil) { heard = ($0.userInfo?["targets"] as? [String])?.first }
        NotePictures.shared.preview(URL(fileURLWithPath: "/tmp/petal-rich/Pictures/abc/p.png"), NSImage(size: NSSize(width: 4, height: 2)))
        NotificationCenter.default.removeObserver(token)
        expect(heard == "/tmp/petal-rich/Pictures/abc/p.png" && NotePictures.shared.image("../Pictures/abc/p.png", in: folder) != nil,
               "a pasted picture's preview is said to the editors and shown by its link")
        // A link out of the notes' root, or absolute: never read, shown broken.
        expect(NotePictures.target("../../private.png", in: folder) == nil && NotePictures.target("/etc/hosts", in: folder) == nil
               && NotePictures.shared.image("../Pictures/../../private.png", in: folder) == nil && NotePictures.shared.isBroken("/etc/hosts", in: folder),
               "a picture link leading out: no target, nothing read, a broken picture")
        // A missing picture: said broken once, never asked again by drawing; a file appearing where it leads (the
        // folder watcher) reads it again and it arrives; the retry asks only for what's on screen.
        func spin(until done: () -> Bool) {
            let end = Date().addingTimeInterval(3)
            while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        var said: [String] = []
        let listen = NotificationCenter.default.addObserver(forName: NotePictures.arrived, object: nil, queue: nil) { note in
            said += note.userInfo?["targets"] as? [String] ?? []
        }
        let missing = "/tmp/petal-rich/Pictures/late/p.png"
        _ = NotePictures.shared.image("../Pictures/late/p.png", in: folder)
        spin { NotePictures.shared.isBroken("../Pictures/late/p.png", in: folder) }
        let readsWhenBroken = NoteStore.reads
        for _ in 0..<3 { _ = NotePictures.shared.image("../Pictures/late/p.png", in: folder) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        expect(NotePictures.shared.isBroken("../Pictures/late/p.png", in: folder) && said.filter({ $0 == missing }).count == 1 && NoteStore.reads == readsWhenBroken,
               "a missing picture: said broken once, and drawing it again never asks again")
        expect(NotePictures.shared.retryTick(now: Date().addingTimeInterval(11), onScreen: []).isEmpty,
               "not on screen: not asked again, and the timer stops")
        expect(NotePictures.shared.retryTick(now: Date(), onScreen: [missing]).isEmpty, "on screen but just tried: not yet")
        // The retry follows the one visibility signal: hidden, it stops; revealed again, it restarts.
        NotePictures.shared.visible = { [] }
        NotePictures.shared.visibilityChanged()
        spin { !NotePictures.shared.retrying }
        expect(!NotePictures.shared.retrying, "its paper hidden: no retrying")
        NotePictures.shared.visible = { [missing] }
        NotePictures.shared.visibilityChanged()
        spin { NotePictures.shared.retrying }
        expect(NotePictures.shared.retrying, "its paper revealed again: retrying restarts")
        NotePictures.shared.visible = { [] }
        NotePictures.shared.visibilityChanged()
        spin { !NotePictures.shared.retrying }
        expect(!NotePictures.shared.retrying, "folded or hidden again: stops")
        let png = FileManager.default.temporaryDirectory.appending(path: "petal-rich-\(UUID().uuidString).png")
        try? NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:])?.write(to: png)
        NoteStore.files[missing] = png
        NotePictures.shared.filesChanged(["/private/tmp/petal-rich/Pictures/late/p.png"])
        spin { NotePictures.shared.image("../Pictures/late/p.png", in: folder) != nil }
        expect(NotePictures.shared.image("../Pictures/late/p.png", in: folder) != nil && !NotePictures.shared.isBroken("../Pictures/late/p.png", in: folder)
               && said.last == missing, "the file appeared (watcher, another spelling): read again, shown, and said to the editors")
        // A pasted picture (shown from memory before any read): its source is recorded as it's drawn, so a change
        // on disk reads it again.
        let pasted = URL(fileURLWithPath: "/tmp/petal-rich/Pictures/paste/p.png")
        NotePictures.shared.preview(pasted, NSImage(size: NSSize(width: 2, height: 2)))
        expect(NotePictures.shared.image("../Pictures/paste/p.png", in: folder) != nil, "a paste shows from memory")
        NoteStore.files[pasted.path] = png
        let readsBefore = NoteStore.reads
        NotePictures.shared.filesChanged([pasted.path])
        spin { NoteStore.reads > readsBefore }
        expect(NoteStore.reads > readsBefore, "its file changed on disk: read again from the recorded source")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        NotificationCenter.default.removeObserver(listen)
        try? FileManager.default.removeItem(at: png)
        // Text from outside (a sync, a tool, a reload): the undo history goes with the old text; ⌘Z then changes nothing.
        let typing = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let undoDelegate = UndoDelegate()
        typing.delegate = undoDelegate
        typing.allowsUndo = true
        typing.isRichText = true
        typing.replaceFromOutside(NoteRich.attributed(NoteBlock.blocks("first words"), folder: typing.folderRef, style: style))
        typing.setSelectedRange(NSRange(location: 11, length: 0))
        typing.insertText(" and more typed here", replacementRange: typing.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(typing.history.canUndo, "the person's typing can be undone")
        typing.replaceFromOutside(NoteRich.attributed(NoteBlock.blocks("short"), folder: typing.folderRef, style: style))
        typing.undoManager?.undo()
        expect(!typing.history.canUndo && typing.string == "short", "after an outside load, nothing to undo and ⌘Z leaves the text as it is", typing.string)

        // The Edit menu, never shown: its items, selectors and keys; the app menu empty (nothing acts unexpectedly).
        let menu = EditMenu.make()
        let editItems = menu.items.count == 2 ? (menu.items[1].submenu?.items ?? []).filter { !$0.isSeparatorItem } : []
        let wanted: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("Undo", "undo:", "z", .command), ("Redo", "redo:", "z", [.command, .shift]), ("Cut", "cut:", "x", .command),
            ("Copy", "copy:", "c", .command), ("Paste", "paste:", "v", .command),
            ("Paste and Match Style", "pasteAsPlainText:", "v", [.command, .option, .shift]), ("Delete", "delete:", "", .command),
            ("Select All", "selectAll:", "a", .command), ("Find…", "performFindPanelAction:", "f", .command)]
        expect(editItems.count == wanted.count && zip(editItems, wanted).allSatisfy { item, want in
            item.title == want.0 && item.action.map(NSStringFromSelector) == want.1 && item.keyEquivalent == want.2 && item.keyEquivalentModifierMask == want.3
        }, "the Edit menu: its items, standard selectors and keys", editItems.map { "\($0.title) \($0.action.map(NSStringFromSelector) ?? "-") \($0.keyEquivalent)" }.joined(separator: ", "))
        expect(menu.items.first?.submenu?.items.isEmpty == true, "the app menu is empty: no Quit, Hide or Settings key")
        expect(editItems.last?.tag == Int(NSFindPanelAction.showFindPanel.rawValue), "Find… shows the find bar")

        // The menu's Undo, sent through the responder chain as a key would, uses the editor's own history.
        let menuEditor = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        menuEditor.delegate = undoDelegate
        menuEditor.allowsUndo = true
        let offscreen = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        offscreen.contentView = menuEditor
        offscreen.makeFirstResponder(menuEditor)
        expect(menuEditor.undoManager === menuEditor.history, "the editor's undo manager is its own history")
        menuEditor.insertText("typed", replacementRange: menuEditor.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(menuEditor.history.canUndo && offscreen.undoManager !== menuEditor.history, "typing undone in its own history, not the window's")
        expect(menuEditor.tryToPerform(Selector(("undo:")), with: nil) && menuEditor.string.isEmpty, "the menu's undo: undoes it", menuEditor.string)

        // A checkbox tick: undone and redone, saved and drawn each way.
        let ticking = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        ticking.delegate = undoDelegate
        var saves = 0
        ticking.changed = { saves += 1 }
        ticking.replaceFromOutside(NoteRich.attributed(NoteBlock.blocks("- [ ] buy milk"), folder: ticking.folderRef, style: style))
        let box = { (ticking.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell as? CheckCell }
        ticking.toggleCheck(at: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(box()?.done == true && saves == 1 && ticking.history.canUndo, "ticked: saved, and it can be undone")
        ticking.history.undo()
        expect(box()?.done == false && saves == 2 && NoteBlock.body(NoteRich.blocks(ticking.textStorage!)) == "- [ ] buy milk" && ticking.history.canRedo,
               "undone: unticked again, saved, and it can be redone")
        ticking.history.redo()
        expect(box()?.done == true && saves == 3 && NoteBlock.body(NoteRich.blocks(ticking.textStorage!)) == "- [x] buy milk", "redone: ticked again and saved")

        // A picture pasted over a selection replaces it when it's in, if the text there is still what was selected.
        let pasting = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        pasting.replaceFromOutside(NoteRich.attributed(NoteBlock.blocks("keep REPLACE end"), folder: pasting.folderRef, style: style))
        _ = pasting.insertPicture(path: "../Pictures/x/p.png", file: URL(fileURLWithPath: "/tmp/p.png"), caption: "", at: 5, length: 7, selected: "REPLACE")
        let pastedBody = NoteBlock.body(NoteRich.blocks(pasting.textStorage!))
        expect(!pastedBody.contains("REPLACE") && pastedBody.contains("keep") && pastedBody.contains("end") && pastedBody.contains("../Pictures/x/p.png"),
               "the selection replaced by the picture", pastedBody)
        let changedMeanwhile = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        changedMeanwhile.replaceFromOutside(NoteRich.attributed(NoteBlock.blocks("keep OTHERED end"), folder: changedMeanwhile.folderRef, style: style))
        _ = changedMeanwhile.insertPicture(path: "../Pictures/x/p.png", file: URL(fileURLWithPath: "/tmp/p.png"), caption: "", at: 5, length: 7, selected: "REPLACE")
        let keptBody = NoteBlock.body(NoteRich.blocks(changedMeanwhile.textStorage!))
        expect(keptBody.contains("OTHERED") && keptBody.contains("../Pictures/x/p.png"), "text changed meanwhile: nothing replaced, the picture still put in", keptBody)

        // Cut and paste keep cards and pictures: a note's own fragment beside plain text, on a private pasteboard here
        // (never the person's clipboard).
        let board = NSPasteboard(name: NSPasteboard.Name("petal-check-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let inbox = URL(fileURLWithPath: "/tmp/petal-rich/Inbox"), work = URL(fileURLWithPath: "/tmp/petal-rich/Work")
        func editor(_ body: String, note: String, folder: URL) -> NoteTextView {
            let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            view.noteID = note
            view.noteFolder = folder
            view.replaceFromOutside(NoteRich.attributed(NoteBlock.blocks(body), folder: view.folderRef, style: style))
            return view
        }
        func body(_ view: NoteTextView) -> String { NoteBlock.body(NoteRich.blocks(view.textStorage!)) }
        let carded = editor("hello\nhttps://example.com/page\nafter", note: "N1", folder: inbox)
        carded.setSelectedRange(NSRange(location: 0, length: 7))   // "hello\n" and the card
        expect(carded.copySelection(to: board), "words and a card copied")
        carded.delete(nil)
        expect(!body(carded).contains("hello") && !body(carded).contains("example.com"), "cut: gone from the note", body(carded))
        expect(board.string(forType: .string) == "hello\nhttps://example.com/page", "another app gets plain text: the words and the address",
               board.string(forType: .string) ?? "nil")
        var imports: [NoteImport] = []
        func paste(_ view: NoteTextView) {
            view.importPictures = { imports.append($0) }
            expect(view.pasteNote(from: board), "a note's fragment on the pasteboard")
        }
        carded.setSelectedRange(NSRange(location: (carded.string as NSString).length, length: 0))
        paste(carded)
        let cardBlocks = NoteBlock.blocks(body(carded))
        expect(cardBlocks.contains(.link("https://example.com/page")) && body(carded) == "\nafterhello\nhttps://example.com/page" && imports.isEmpty,
               "the card comes back as a card at once, after the words", body(carded))

        // Another app gets the words and a picture's caption, never its path.
        let captioned = editor("caption line\n![shot](../Pictures/abc/p.png)", note: "N1", folder: inbox)
        captioned.selectAll(nil)
        captioned.copySelection(to: board)
        expect(board.string(forType: .string) == "caption line\nshot", "another app gets plain text, never a picture's path", board.string(forType: .string) ?? "nil")

        // A paste into the same note after it moved (Inbox → Work): words and its own picture go in at once; the
        // picture beside it in the old notebook becomes an import owned by the note (its recorded file, its caption,
        // its spot), and lands there.
        let ownN1 = NoteShelf.pictureFolder(id: "N1")
        let source = editor("words\n![shot](../\(ownN1)/p.png)\n![trip](Trip.assets/q.png)", note: "N1", folder: inbox)
        source.selectAll(nil)
        source.copySelection(to: board)
        let moved = editor("", note: "N1", folder: work)
        imports = []
        paste(moved)
        expect(body(moved) == "words\n![shot](\(NoteShelf.pictureLink(id: "N1", name: "p.png")))" && imports.count == 1
               && imports.first?.files.map(\.path) == ["/tmp/petal-rich/Inbox/Trip.assets/q.png"] && imports.first?.captions == ["trip"],
               "same note after a move: its own picture at once, the old notebook's an import of its recorded file", body(moved))
        if let token = imports.first?.anchor {
            _ = moved.insertPicture(path: "../\(ownN1)/picture-new.png", file: URL(fileURLWithPath: "/tmp/x.png"), caption: "trip", at: -1, anchor: token)
            expect(body(moved) == "words\n![shot](\(NoteShelf.pictureLink(id: "N1", name: "p.png")))\n![trip](../\(ownN1)/picture-new.png)",
                   "it lands at its spot when it's read", body(moved))
        } else { expect(false, "the import has its spot") }

        // A fragment whose picture has no file recorded: a line saying so, no import, no link.
        let unrecorded = NoteRich.Fragment(markdown: "before\n![](../../../../outside.png)", folder: inbox.path, note: "N9", root: "/tmp/petal-rich", files: [nil])
        board.declareTypes([NoteRich.fragmentType, .string], owner: nil)
        board.setData(try! JSONEncoder().encode(unrecorded), forType: NoteRich.fragmentType)
        let target = editor("", note: "N2", folder: work)
        imports = []
        paste(target)
        expect(body(target) == "before\n(A picture couldn't be pasted.)" && imports.isEmpty, "no file for it: said in words, nothing linked", body(target))

        // From another root (another Mac, another notes folder), even with the same note's id: never kept as a link;
        // its pictures side by side are one import, landing in their order; one that can't be read is said in words.
        let foreign = NoteRich.Fragment(markdown: "![cap](../Pictures/x/p.png)\n![gone](../Pictures/x/q.png)", folder: "/other-mac/Notes/Inbox", note: "N1",
                                        root: "/other-mac/Notes", files: ["/other-mac/Notes/Pictures/x/p.png", "/other-mac/Notes/Pictures/x/q.png"])
        board.declareTypes([NoteRich.fragmentType, .string], owner: nil)
        board.setData(try! JSONEncoder().encode(foreign), forType: NoteRich.fragmentType)
        let local = editor("", note: "N1", folder: work)
        imports = []
        paste(local)
        expect(body(local).isEmpty && imports.count == 1 && imports.first?.files.map(\.path) == ["/other-mac/Notes/Pictures/x/p.png", "/other-mac/Notes/Pictures/x/q.png"]
               && imports.first?.captions == ["cap", "gone"], "another root: one import of both recorded files, nothing linked yet", body(local))
        if let token = imports.first?.anchor {
            _ = local.insertPicture(path: "../\(ownN1)/picture-a.png", file: URL(fileURLWithPath: "/tmp/x.png"), caption: "cap", at: -1, anchor: token)
            local.insertWords(NoteRich.unpasted("gone").markdown, anchor: token)
            expect(body(local) == "![cap](../\(ownN1)/picture-a.png)\n(The picture “gone” couldn't be pasted.)", "the one read goes in, the other is said in words after it", body(local))
        }

        // Spots follow the person's typing, landing never moves their cursor, and pictures land in their order
        // whichever is read first.
        let spaced = NoteRich.Fragment(markdown: "a\n![one](../Pictures/zz/1.png)\nmid\n![two](../Pictures/zz/2.png)\nb", folder: inbox.path, note: "N9",
                                       root: "/tmp/petal-rich", files: ["/tmp/petal-rich/Pictures/zz/1.png", "/tmp/petal-rich/Pictures/zz/2.png"])
        board.declareTypes([NoteRich.fragmentType, .string], owner: nil)
        board.setData(try! JSONEncoder().encode(spaced), forType: NoteRich.fragmentType)
        let typing2 = editor("", note: "N2", folder: work)
        imports = []
        paste(typing2)
        typing2.setSelectedRange(NSRange(location: 0, length: 0))
        typing2.insertText("TYPED ", replacementRange: typing2.selectedRange())
        let cursor = typing2.selectedRange()
        if imports.count == 2, let one = imports[0].anchor, let two = imports[1].anchor {
            _ = typing2.insertPicture(path: "../Pictures/n2/2.png", file: URL(fileURLWithPath: "/tmp/x.png"), caption: "two", at: -1, anchor: two)
            _ = typing2.insertPicture(path: "../Pictures/n2/1.png", file: URL(fileURLWithPath: "/tmp/x.png"), caption: "one", at: -1, anchor: one)
            expect(body(typing2) == "TYPED a\n![one](../Pictures/n2/1.png)\nmid\n![two](../Pictures/n2/2.png)\nb", "each at its spot after the typing, in order", body(typing2))
            expect(typing2.selectedRange() == cursor, "the person's cursor stays where it was")
        } else { expect(false, "two imports, one per spot", "\(imports.count)") }

        // 2,000 pictures side by side: one import (one journal record, one read, one batch), not 2,000.
        let many = (0..<2000).map { "![](../Pictures/bulk/p\($0).png)" }.joined(separator: "\n")
        board.declareTypes([NoteRich.fragmentType, .string], owner: nil)
        board.setData(try! JSONEncoder().encode(NoteRich.Fragment(markdown: many, folder: inbox.path, note: "NB", root: "/tmp/petal-rich",
                                                                    files: (0..<2000).map { "/tmp/petal-rich/Pictures/bulk/p\($0).png" })), forType: NoteRich.fragmentType)
        let bulk = editor("", note: "N2", folder: work)
        imports = []
        paste(bulk)
        expect(imports.count == 1 && imports.first?.files.count == 2000 && imports.first?.captions?.count == 2000, "2,000 pictures: one import", "\(imports.count)")

        // One arrival for a batch of pictures: each editor scans its pictures once.
        let batchFiles = (0..<50).map { (URL(fileURLWithPath: "/tmp/petal-rich/Pictures/batch/p\($0).png"), NSImage(size: NSSize(width: 2, height: 2))) }
        NotePictures.shared.previewBatch(batchFiles)   // in memory first, so drawing them reads nothing
        let batchEditor = editor((0..<50).map { "![](../Pictures/batch/p\($0).png)" }.joined(separator: "\n"), note: "N2", folder: work)
        let batchWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        batchWindow.contentView = batchEditor
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        var arrivals = 0
        let counting = NotificationCenter.default.addObserver(forName: NotePictures.arrived, object: nil, queue: nil) { _ in arrivals += 1 }
        let scansBefore = batchEditor.scans
        NotePictures.shared.previewBatch(batchFiles)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        NotificationCenter.default.removeObserver(counting)
        expect(arrivals == 1 && batchEditor.scans - scansBefore == 1, "a batch: one arrival, one scan", "\(arrivals) arrivals, \(batchEditor.scans - scansBefore) scans")

        // A note moved to another notebook: its open editor's pictures read their links from the new folder, the
        // text and selection untouched.
        let moving = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        moving.noteFolder = URL(fileURLWithPath: "/tmp/petal-rich/Inbox")
        var remeasured = 0
        moving.remeasure = { remeasured += 1 }
        moving.replaceFromOutside(NoteRich.attributed(NoteBlock.blocks("words\n![](Trip.assets/q.png)\nafter"), folder: moving.folderRef, style: style))
        moving.setSelectedRange(NSRange(location: 2, length: 3))
        let textBefore = moving.string
        moving.noteFolder = URL(fileURLWithPath: "/tmp/petal-rich/Work")
        let cells = NoteRich.pictureRanges(in: moving.textStorage!, target: "/tmp/petal-rich/Work/Trip.assets/q.png")
        expect(cells.count == 1 && NoteRich.pictureRanges(in: moving.textStorage!, target: "/tmp/petal-rich/Inbox/Trip.assets/q.png").isEmpty,
               "its picture now leads from the new notebook, not the old")
        expect(moving.string == textBefore && moving.selectedRange() == NSRange(location: 2, length: 3) && remeasured == 1,
               "the text and selection kept, the pictures laid out again")
        print("note editor: \(roundTrips) of \(bodies.count + 1) round trips, \(checks) editor checks" + (failures > bodies.count + 1 - roundTrips ? " (some failed)" : ""))
        if failures > 0 { exit(1) }
    }
}
