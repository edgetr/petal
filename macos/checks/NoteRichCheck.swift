import AppKit

// Checks NoteEditor.swift's text for a note: every kind of line (headings, checkboxes, a link's card, a picture,
// Petal's ink, inline links, list items, empty lines) goes into the editor and comes back as the same Markdown.
// AppKit only: stand-ins below for the parts of Petal it would reach (nothing is fetched or read). Run with
// macos/checks/run.sh.
enum Headless { nonisolated(unsafe) static var on = true }
final class NoteStore {
    nonisolated static let io = DispatchQueue(label: "petal.check.notes")
    static let filesChanged = Notification.Name("petal.check.notesFilesChanged")
    static let picturesWritten = Notification.Name("petal.check.notesPicturesWritten")
    static let picturesRetired = Notification.Name("petal.check.notesPicturesRetired")
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
        let token = NotificationCenter.default.addObserver(forName: NotePictures.arrived, object: nil, queue: nil) { note in
            if (note.userInfo?["targets"] as? [String])?.contains("/tmp/petal-rich/Pictures/abc/p.png") == true { heard = "/tmp/petal-rich/Pictures/abc/p.png" }
        }
        NotePictures.shared.preview(URL(fileURLWithPath: "/tmp/petal-rich/Pictures/abc/p.png"), NSImage(size: NSSize(width: 4, height: 2)))
        let heardBy = Date().addingTimeInterval(2)
        while heard == nil && Date() < heardBy { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
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
        spin { NotePictures.shared.image("../Pictures/late/p.png", in: folder) != nil && said.last == missing }
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

        // Runnable @ lines: known by their identity in the editor (a mark on the line), set only by the person's own
        // typing or pasting; undo, redo and text from outside take it off and never give it; nothing about words is kept.
        let lines = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        lines.delegate = undoDelegate
        lines.allowsUndo = true
        lines.isRichText = true
        lines.replaceFromOutside(NoteRich.attributed(NoteBlock.blocks("intro"), folder: lines.folderRef, style: style))
        let toEnd = { lines.setSelectedRange(NSRange(location: (lines.string as NSString).length, length: 0)) }
        let atEnd = { () -> NoteLine? in toEnd(); return lines.helperLine()?.line }
        // Each as its own keystroke event (undo groups by event).
        let typeAtEnd = { (text: String) in
            lines.breakUndoCoalescing(); toEnd(); lines.insertText(text, replacementRange: lines.selectedRange())
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        typeAtEnd("\n@Petal summarize this")
        let typedLine = atEnd()
        expect(typedLine != nil, "a line the person typed may run")
        typedLine?.take()
        expect(atEnd() == nil, "once it ran, Return on it only makes a new line")
        typedLine?.again()
        expect(atEnd() != nil, "its run failed or was stopped: it may run again")
        atEnd()?.take()
        typeAtEnd(" page")
        let edited = atEnd()
        expect(edited != nil && edited?.mark != typedLine?.mark, "editing it makes it a new line that may run")
        edited?.take()
        lines.undoManager?.undo()
        expect(lines.string.hasSuffix("summarize this") && atEnd() == nil, "undo brings the earlier words back, never runnable", lines.string)
        lines.undoManager?.redo()
        expect(lines.string.hasSuffix("this page") && atEnd() == nil, "redo never makes a line runnable", lines.string)
        typedLine?.again()
        expect(atEnd() == nil, "an old line's identity isn't the line there now: it can't be made runnable again")
        typeAtEnd("!")
        expect(atEnd() != nil, "the person's edit (even one character) makes it runnable")
        lines.replaceFromOutside(NoteRich.attributed(NoteBlock.blocks("intro\n@Petal summarize this page!"), folder: lines.folderRef, style: style))
        expect(atEnd() == nil, "the same words from a sync, a reload or a tool never run")
        lines.replaceFromOutside(NoteRich.attributed(NoteBlock.blocks("intro\n@Petal summarize this"), folder: lines.folderRef, style: style))
        expect(atEnd() == nil, "words that ran before, brought back from outside, never run")
        // Backspace from a blank line onto an answered line, then Undo: neither makes the old command runnable.
        lines.replaceFromOutside(NoteRich.attributed(NoteBlock.blocks("intro"), folder: lines.folderRef, style: style))
        typeAtEnd("\n@Petal check the side door")
        atEnd()?.take()
        typeAtEnd("\n")
        lines.breakUndoCoalescing()
        toEnd()
        lines.deleteBackward(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(lines.string.hasSuffix("side door") && atEnd() == nil, "joining a blank line onto an answered line doesn't make it runnable", lines.string)
        lines.undoManager?.undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        lines.setSelectedRange(NSRange(location: (lines.string as NSString).length - 1, length: 0))
        expect(lines.string.hasSuffix("side door\n") && lines.helperLine() == nil, "undoing the join doesn't either", lines.string)

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
        // Copy is synchronous: the pasteboard has it when it returns.
        func copy(_ view: NoteTextView) -> Bool { view.copySelection(to: board) == .copied }
        let carded = editor("hello\nhttps://example.com/page\nafter", note: "N1", folder: inbox)
        carded.setSelectedRange(NSRange(location: 0, length: 7))   // "hello\n" and the card
        expect(copy(carded), "words and a card copied")
        carded.delete(nil)
        expect(!body(carded).contains("hello") && !body(carded).contains("example.com"), "cut: gone from the note", body(carded))
        expect(board.string(forType: .string) == "hello\nhttps://example.com/page", "another app gets plain text: the words and the address",
               board.string(forType: .string) ?? "nil")
        // Pictures travel as bytes, like a pasted screenshot. A paste takes them by the screenshot paste's path (here,
        // a stand-in recording what it was given) and goes in at once.
        var accepted: [[Data]] = []
        func paste(_ view: NoteTextView) {
            view.acceptPictures = { items in
                accepted.append(items.map(\.data))
                let own = NoteShelf.pictureFolder(id: view.noteID)
                return items.enumerated().map { n, item in
                    ("../\(own)/picture-new\(n).\(item.ext)", URL(fileURLWithPath: "/tmp/petal-rich/\(own)/picture-new\(n).\(item.ext)"), item.caption)
                }
            }
            // Paste is synchronous: in when it returns.
            expect(view.pasteNote(from: board), "a note's fragment on the pasteboard")
        }
        let pngData = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:]) ?? Data()
        carded.setSelectedRange(NSRange(location: (carded.string as NSString).length, length: 0))
        paste(carded)
        expect(NoteBlock.blocks(body(carded)).contains(.link("https://example.com/page")) && body(carded) == "\nafterhello\nhttps://example.com/page" && accepted.isEmpty,
               "the card comes back as a card at once, after the words", body(carded))

        // Another app gets the words and a picture's caption, never its path.
        let captioned = editor("caption line\n![shot](../Pictures/abc/p.png)", note: "N1", folder: inbox)
        captioned.selectAll(nil)
        copy(captioned)
        expect(board.string(forType: .string) == "caption line\nshot", "another app gets plain text, never a picture's path", board.string(forType: .string) ?? "nil")

        // A picture just pasted (its file not written yet) is cut and pasted into another note: its bytes travel with
        // the copy, and the picture comes out whole there. Copying reads nothing from disk.
        let ownN1 = NoteShelf.pictureFolder(id: "N1"), ownN2 = NoteShelf.pictureFolder(id: "N2")
        let fresh = URL(fileURLWithPath: "/tmp/petal-rich/\(ownN1)/picture-fresh.png")
        NotePictures.shared.preview(fresh, NSImage(data: pngData) ?? NSImage(), data: pngData)   // as an accepted paste is: bytes in memory, file not yet
        let cutFrom = editor("words\n![shot](../\(ownN1)/picture-fresh.png)", note: "N1", folder: inbox)
        cutFrom.selectAll(nil)
        let readsBeforeCopy = NoteStore.reads
        expect(copy(cutFrom), "copied")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expect(NoteStore.reads == readsBeforeCopy, "copy reads nothing from disk", "\(NoteStore.reads - readsBeforeCopy) reads")
        cutFrom.delete(nil)
        let other = editor("", note: "N2", folder: work)
        accepted = []
        paste(other)
        expect(body(other) == "words\n![shot](../\(ownN2)/picture-new0.png)" && accepted == [[pngData]],
               "cut before its file was saved, pasted into another note: the picture whole there", body(other))

        // Into the same note, a picture already its own keeps its line; nothing is copied.
        let mine = editor("![shot](../\(ownN1)/picture-fresh.png)", note: "N1", folder: work)
        mine.selectAll(nil)
        copy(mine)
        mine.setSelectedRange(NSRange(location: (mine.string as NSString).length, length: 0))
        accepted = []
        paste(mine)
        expect(body(mine).components(separatedBy: "![shot](../\(ownN1)/picture-fresh.png)").count == 3 && accepted.isEmpty,
               "the same note: its own picture's line again, no copy", body(mine))

        // A picture whose bytes aren't held is read off the main thread for the copy; one that never loaded (nothing to
        // read) copies as a line saying so.
        let unloaded = editor("before\n![](../\(ownN1)/never-loaded.png)", note: "N1", folder: inbox)
        unloaded.selectAll(nil)
        copy(unloaded)
        let unloadedFragment = board.data(forType: NoteRich.fragmentType).flatMap(NoteRich.decode)
        expect(unloadedFragment?.markdown == "before\n(A picture couldn't be copied.)" && unloadedFragment?.pictures.isEmpty == true,
               "a never-loaded picture: copied as a line saying so", unloadedFragment?.markdown ?? "nil")
        let unloadedTarget = editor("", note: "N2", folder: work)
        accepted = []
        paste(unloadedTarget)
        expect(body(unloadedTarget) == "before\n(A picture couldn't be copied.)" && accepted.isEmpty, "and pasted as that line", body(unloadedTarget))

        // Undo takes a paste with pictures out like any text; redo puts it back.
        let undoing = editor("start", note: "N2", folder: work)
        undoing.delegate = undoDelegate
        undoing.allowsUndo = true
        let withPictures = NoteRich.Fragment(markdown: "![a](../Pictures/x/a.png)\nmiddle\n![b](../Pictures/x/b.png)", folder: inbox.path, note: "N9",
                                             pictures: [pngData, pngData])
        board.declareTypes([NoteRich.fragmentType, .string], owner: nil)
        board.setData(NoteRich.encode(withPictures)!, forType: NoteRich.fragmentType)
        undoing.setSelectedRange(NSRange(location: 5, length: 0))
        accepted = []
        paste(undoing)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let afterPaste = body(undoing)
        expect(afterPaste == "start![a](../\(ownN2)/picture-new0.png)\nmiddle\n![b](../\(ownN2)/picture-new1.png)" || afterPaste.contains("picture-new1.png"),
               "pasted with both pictures at once", afterPaste)
        undoing.history.undo()
        expect(body(undoing) == "start", "undo: the paste and its pictures gone", body(undoing))
        undoing.history.redo()
        expect(body(undoing) == afterPaste, "redo: back, pictures and all", body(undoing))

        // 2,000 pictures pasted at once: taken in one go, and their arrivals coming one by one make one (or a few)
        // notifications, one scan each.
        let many = (0..<2000).map { "![](../Pictures/bulk/p\($0).png)" }.joined(separator: "\n")
        board.declareTypes([NoteRich.fragmentType, .string], owner: nil)
        board.setData(NoteRich.encode(NoteRich.Fragment(markdown: many, folder: inbox.path, note: "NB", pictures: Array(repeating: pngData, count: 2000)))!,
                      forType: NoteRich.fragmentType)
        let bulk = editor("", note: "N2", folder: work)
        accepted = []
        paste(bulk)
        expect(accepted.count == 1 && accepted.first?.count == 2000
               && NoteBlock.blocks(body(bulk)).filter { if case .image = $0 { true } else { false } }.count == 2000, "2,000 pictures: one accept, all in", "\(accepted.count)")
        let bulkShown = editor((0..<2000).map { "![](../Pictures/landed/p\($0).png)" }.joined(separator: "\n"), note: "N2", folder: work)
        let shownWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        let landedFiles = (0..<2000).map { (URL(fileURLWithPath: "/tmp/petal-rich/Pictures/landed/p\($0).png"), NSImage(size: NSSize(width: 2, height: 2)), Optional<Data>.none) }
        NotePictures.shared.previewBatch(landedFiles)
        shownWindow.contentView = bulkShown
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        var bulkArrivals = 0
        let bulkCounting = NotificationCenter.default.addObserver(forName: NotePictures.arrived, object: nil, queue: nil) { _ in bulkArrivals += 1 }
        let bulkScans = bulkShown.scans
        for file in landedFiles { NotePictures.shared.previewBatch([file]) }   // 2,000 arrivals, one by one
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        NotificationCenter.default.removeObserver(bulkCounting)
        expect(bulkArrivals >= 1 && bulkArrivals <= 3 && bulkShown.scans - bulkScans == bulkArrivals,
               "2,000 arrivals: one notification or a few, one scan each", "\(bulkArrivals) arrivals, \(bulkShown.scans - bulkScans) scans")

        // The fragment is offered lazily: nothing encoded when copying, encoded once a note asks for it.
        let lazySource = editor("lazy words\n![shot](../\(ownN1)/picture-fresh.png)", note: "N1", folder: inbox)
        lazySource.selectAll(nil)
        _ = copy(lazySource)
        let provider = FragmentProvider.current
        expect(provider?.encodes == 0 && board.string(forType: .string) == "lazy words\nshot", "copied: plain text there, the fragment not encoded yet")
        let asked = board.data(forType: NoteRich.fragmentType).flatMap(NoteRich.decode)
        expect(provider?.encodes == 1 && asked?.pictures == [pngData] && asked?.root == "/tmp/petal-rich",
               "encoded when asked, as a binary property list, with the notes root it came from")

        // Same note, another notes folder (another Mac): its picture lines are never kept; the bytes are taken.
        board.declareTypes([NoteRich.fragmentType, .string], owner: nil)
        board.setData(NoteRich.encode(NoteRich.Fragment(markdown: "![s](../\(ownN1)/picture-fresh.png)", folder: "/other/Inbox", note: "N1", root: "/other",
                                                        pictures: [pngData]))!, forType: NoteRich.fragmentType)
        let sameNoteElsewhere = editor("", note: "N1", folder: work)
        accepted = []
        paste(sameNoteElsewhere)
        expect(accepted == [[pngData]] && body(sameNoteElsewhere) == "![s](../\(ownN1)/picture-new0.png)", "another root: bytes accepted, never the old line", body(sameNoteElsewhere))

        // Bytes held only while needed: a write not landed, or an open editor showing it; the image cache has a cost limit.
        let releaseKey = "/tmp/petal-rich/Pictures/rel/p.png"
        NotePictures.shared.preview(URL(fileURLWithPath: releaseKey), NSImage(data: pngData) ?? NSImage(), data: pngData)
        let showing = editor("![](../Pictures/rel/p.png)", note: "N2", folder: work)
        NotePictures.shared.register(showing)
        expect(NotePictures.shared.bytes(releaseKey) == pngData, "accepted bytes held while their write is pending")
        NotePictures.shared.written([releaseKey])
        expect(NotePictures.shared.bytes(releaseKey) == pngData, "written, but an open editor shows it: still held")
        NotePictures.shared.unregister(showing)
        expect(NotePictures.shared.bytes(releaseKey) == nil, "written and its editor closed: let go")
        let otherKey = "/tmp/petal-rich/Pictures/rel/q.png"
        NotePictures.shared.preview(URL(fileURLWithPath: otherKey), NSImage(data: pngData) ?? NSImage(), data: pngData)
        NotePictures.shared.written([otherKey])
        expect(NotePictures.shared.bytes(otherKey) == nil, "written and shown nowhere: let go at once")
        expect(NotePictures.shared.cacheLimit == 200 * 1024 * 1024, "the image cache's cost limit: about 200 MB of decoded pixels")

        // Synchronous cut: refused past the size bound, with nothing written and nothing deleted, and said.
        let oversize = editor("big\n![](../\(ownN1)/picture-fresh.png)", note: "N1", folder: inbox)
        var told: [String] = []
        oversize.say = { told.append($0) }
        oversize.selectAll(nil)
        let countBefore = board.changeCount
        let limitBefore = NoteRich.fragmentLimit
        NoteRich.fragmentLimit = 10
        expect(oversize.copySelection(to: board) == .tooMany && board.changeCount == countBefore, "past the bound: refused, nothing written")
        oversize.cut(nil)
        NoteRich.fragmentLimit = limitBefore
        expect(body(oversize) == "big\n![](../\(ownN1)/picture-fresh.png)" && told == [NoteTextView.tooManyPictures], "a refused cut deletes nothing, and says why", body(oversize))

        // The holding rule, at each event: bytes held while their write is pending or an open editor contains them.
        func holdKey(_ name: String) -> String { "/tmp/petal-rich/Pictures/hold/\(name).png" }
        let image2 = NSImage(data: pngData) ?? NSImage()
        NotePictures.shared.preview(URL(fileURLWithPath: holdKey("a")), image2, data: pngData)                 // accepted: write pending
        expect(NotePictures.shared.bytes(holdKey("a")) == pngData, "accepted: held (write pending)")
        NotePictures.shared.written([holdKey("a")])                                                            // write lands, no editor
        expect(NotePictures.shared.bytes(holdKey("a")) == nil, "written, no editor contains it: let go")
        let holder = editor("![](../Pictures/hold/b.png)", note: "N2", folder: work)
        NotePictures.shared.register(holder)                                                                   // editor opens
        NotePictures.shared.preview(URL(fileURLWithPath: holdKey("b")), image2, data: pngData)
        NotePictures.shared.written([holdKey("b")])
        expect(NotePictures.shared.bytes(holdKey("b")) == pngData, "written, but an open editor contains it: held")
        holder.replaceFromOutside(NoteRich.attributed(NoteBlock.blocks("no pictures now"), folder: holder.folderRef, style: style))   // its text changes
        expect(NotePictures.shared.bytes(holdKey("b")) == nil, "its editor no longer contains it: let go")
        holder.replaceFromOutside(NoteRich.attributed(NoteBlock.blocks("![](../Pictures/hold/c.png)"), folder: holder.folderRef, style: style))
        NotePictures.shared.preview(URL(fileURLWithPath: holdKey("c")), image2, data: pngData)
        NotePictures.shared.written([holdKey("c")])
        NotePictures.shared.unregister(holder)                                                                 // editor closes
        expect(NotePictures.shared.bytes(holdKey("c")) == nil, "its editor closed: let go")
        NotePictures.shared.preview(URL(fileURLWithPath: holdKey("d")), image2, data: pngData)
        NotificationCenter.default.post(name: NoteStore.picturesRetired, object: nil, userInfo: ["paths": [holdKey("d")]])   // a removal lands
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(NotePictures.shared.bytes(holdKey("d")) == nil, "its removal landed: the pending write retired, let go")
        // A read completing keeps its bytes only by the rule.
        let readFile = FileManager.default.temporaryDirectory.appending(path: "petal-rich-read-\(UUID().uuidString).png")
        try? pngData.write(to: readFile)
        NoteStore.files["/tmp/petal-rich/Pictures/hold/e.png"] = readFile
        NoteStore.files["/tmp/petal-rich/Pictures/hold/f.png"] = readFile
        _ = NotePictures.shared.image("../Pictures/hold/e.png", in: work)                                     // nobody contains it
        let reader = editor("![](../Pictures/hold/f.png)", note: "N2", folder: work)
        NotePictures.shared.register(reader)
        _ = NotePictures.shared.image("../Pictures/hold/f.png", in: work)                                     // an open editor contains it
        spin { NotePictures.shared.cached(holdKey("e")) != nil && NotePictures.shared.cached(holdKey("f")) != nil }
        expect(NotePictures.shared.bytes(holdKey("e")) == nil && NotePictures.shared.bytes(holdKey("f")) == pngData,
               "a read keeps its bytes only for a picture an open editor contains")

        // Evicted and read again: only its cell drawn again (no arrival, no layout), and no loop.
        var evictArrivals = 0, redraws = 0
        let arrivalWatch = NotificationCenter.default.addObserver(forName: NotePictures.arrived, object: nil, queue: nil) { _ in evictArrivals += 1 }
        let redrawWatch = NotificationCenter.default.addObserver(forName: NotePictures.redraw, object: nil, queue: nil) { _ in redraws += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        evictArrivals = 0
        NotePictures.shared.evict(holdKey("e"))
        let readsBeforeEviction = NoteStore.reads
        expect(NotePictures.shared.size(holdKey("e")) != nil, "its size is known while it's evicted")
        _ = NotePictures.shared.image("../Pictures/hold/e.png", in: work)
        spin { NotePictures.shared.cached(holdKey("e")) != nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        for _ in 0..<5 { _ = NotePictures.shared.image("../Pictures/hold/e.png", in: work) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        NotificationCenter.default.removeObserver(arrivalWatch)
        NotificationCenter.default.removeObserver(redrawWatch)
        expect(NoteStore.reads - readsBeforeEviction == 1 && evictArrivals == 0 && redraws == 1,
               "read again once, its cell redrawn, no arrival, no loop", "\(NoteStore.reads - readsBeforeEviction) reads, \(evictArrivals) arrivals, \(redraws) redraws")
        NotePictures.shared.unregister(reader)
        try? FileManager.default.removeItem(at: readFile)
        // Decoded at the size it's shown, never full size.
        let large = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 1500, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:]) ?? Data()
        let small = NotePictures.downsample(large, maxPixels: NotePictures.shownPixels)
        expect(small.map { max($0.size.width, $0.size.height) <= CGFloat(NotePictures.shownPixels) } == true && NotePictures.shownPixels == 720,
               "a 3000-pixel picture decoded at the shown 720", "\(String(describing: small?.size))")

        // Remove with an editor open (typing not saved yet): an edit in that editor, the typing kept.
        let dirty = editor("typed and not saved\n![](../Pictures/x/bad.png)\nmore", note: "N2", folder: work)
        dirty.delegate = undoDelegate
        dirty.allowsUndo = true
        let removed = dirty.removePictures(named: ["bad.png"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(removed == 1 && body(dirty) == "typed and not saved\nmore" && dirty.history.canUndo, "Remove in the open editor: the picture gone, the typing kept, undoable", body(dirty))

        // Remove takes only the picture: words joined to it on its line stay; a line with nothing else goes whole.
        let joinedLine = editor("![](../Pictures/x/bad.png)\nnext", note: "N2", folder: work)
        joinedLine.insertText("words", replacementRange: NSRange(location: 1, length: 0))   // typed right after the picture
        joinedLine.removePictures(named: ["bad.png"])
        expect(body(joinedLine) == "words\nnext", "words on the picture's line stay", body(joinedLine))

        // Remove's undo brings the picture back and accepts its unsaved bytes again; redo removes it again.
        let undoRemove = editor("before\n![](../Pictures/x/lost.png)\nafter", note: "N2", folder: work)
        undoRemove.delegate = undoDelegate
        undoRemove.allowsUndo = true
        var restored = 0, retiredAgain = 0
        var restoredFor: [String] = []
        undoRemove.removePictures(named: ["lost.png"], restore: { restored += 1; restoredFor.append($0) }, retire: { _ in retiredAgain += 1 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(body(undoRemove) == "before\nafter", "removed", body(undoRemove))
        undoRemove.history.undo()
        expect(body(undoRemove) == "before\n![](../Pictures/x/lost.png)\nafter" && restored == 1, "undo: the picture back, its bytes accepted again", body(undoRemove))
        undoRemove.history.redo()
        expect(body(undoRemove) == "before\nafter" && retiredAgain == 1, "redo: removed again", body(undoRemove))
        // Moved (and given another id) before the undo: the undo acts on the note as it is now.
        undoRemove.noteFolder = inbox
        undoRemove.noteID = "N2-now"
        undoRemove.history.undo()
        expect(restored == 2 && body(undoRemove).contains("lost.png") && restoredFor == ["N2", "N2-now"],
               "undo again after a move: restored for the note as it is now, never a path from before", "\(restoredFor)")

        // A change the folder watcher reports is read from the file: the held bytes and the cached image replaced.
        let staleKey = "/tmp/petal-rich/Pictures/stale/p.png"
        let watcher = editor("![](../Pictures/stale/p.png)", note: "N2", folder: work)
        NotePictures.shared.register(watcher)
        NotePictures.shared.preview(URL(fileURLWithPath: staleKey), NSImage(data: pngData) ?? NSImage(), data: pngData)
        NotePictures.shared.written([staleKey])
        _ = NotePictures.shared.image("../Pictures/stale/p.png", in: work)   // its source recorded
        let newer = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:]) ?? Data()
        let newerFile = FileManager.default.temporaryDirectory.appending(path: "petal-rich-newer-\(UUID().uuidString).png")
        try? newer.write(to: newerFile)
        NoteStore.files[staleKey] = newerFile
        expect(NotePictures.shared.bytes(staleKey) == pngData, "held: the old bytes")
        NotePictures.shared.filesChanged([staleKey])
        spin { NotePictures.shared.bytes(staleKey) == newer }
        expect(NotePictures.shared.bytes(staleKey) == newer && NotePictures.shared.size(staleKey) == NSSize(width: 8, height: 4),
               "the watcher's change read from the file: bytes and image replaced", "\(String(describing: NotePictures.shared.size(staleKey)))")
        NotePictures.shared.unregister(watcher)
        try? FileManager.default.removeItem(at: newerFile)

        // A cut never takes a picture still loading: refused, nothing written or deleted, the selection as it was.
        let loadingCut = editor("words\n![](../Pictures/notyet/p.png)\nmore", note: "N2", folder: work)
        var loadingTold: [String] = []
        loadingCut.say = { loadingTold.append($0) }
        loadingCut.selectAll(nil)
        let selectionBefore = loadingCut.selectedRange(), boardBefore = board.changeCount
        expect(loadingCut.performCut(to: board) == .loading && body(loadingCut) == "words\n![](../Pictures/notyet/p.png)\nmore"
               && loadingCut.selectedRange() == selectionBefore && board.changeCount == boardBefore && loadingTold == [NoteTextView.stillLoading],
               "a cut with a picture still loading: refused, nothing deleted, the selection intact", body(loadingCut))
        expect(loadingCut.copySelection(to: board) == .copied, "a copy of it still goes, the picture as a line")

        // A refresh that finds the file gone drops the image and bytes and shows the broken mark; one that can't
        // read it for now keeps the old image and is tried again.
        let goneKey = "/tmp/petal-rich/Pictures/fresh/gone.png", busyKey = "/tmp/petal-rich/Pictures/fresh/busy.png"
        let refresher = editor("![](../Pictures/fresh/gone.png)\n![](../Pictures/fresh/busy.png)", note: "N2", folder: work)
        NotePictures.shared.register(refresher)
        for key in [goneKey, busyKey] {
            NotePictures.shared.preview(URL(fileURLWithPath: key), NSImage(data: pngData) ?? NSImage(), data: pngData)
            NotePictures.shared.written([key])
        }
        _ = NotePictures.shared.image("../Pictures/fresh/gone.png", in: work)
        _ = NotePictures.shared.image("../Pictures/fresh/busy.png", in: work)
        NoteStore.files[goneKey] = FileManager.default.temporaryDirectory.appending(path: "petal-rich-nowhere-\(UUID().uuidString).png")
        let busyFile = FileManager.default.temporaryDirectory.appending(path: "petal-rich-busy-\(UUID().uuidString).png")
        try? pngData.write(to: busyFile)
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: busyFile.path)
        NoteStore.files[busyKey] = busyFile
        NotePictures.shared.filesChanged([goneKey, busyKey])
        spin { NotePictures.shared.cached(goneKey) == nil && NotePictures.shared.isBroken("../Pictures/fresh/busy.png", in: work) }
        expect(NotePictures.shared.cached(goneKey) == nil && NotePictures.shared.bytes(goneKey) == nil && NotePictures.shared.isBroken("../Pictures/fresh/gone.png", in: work),
               "confirmed gone: image and bytes dropped, the broken mark shown")
        expect(NotePictures.shared.cached(busyKey) != nil && NotePictures.shared.retryTick(now: Date().addingTimeInterval(11), onScreen: [busyKey]) == [busyKey],
               "unreadable for now: the old image kept, and tried again")
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: busyFile.path)
        try? FileManager.default.removeItem(at: busyFile)
        NotePictures.shared.unregister(refresher)

        // A moved editor's pictures are weighed by the holding rule where they lead now.
        let movingHolder = editor("![](Trip.assets/held.png)", note: "N2", folder: inbox)
        NotePictures.shared.register(movingHolder)
        let movedKey = "/tmp/petal-rich/Work/Trip.assets/held.png"
        NotePictures.shared.preview(URL(fileURLWithPath: movedKey), NSImage(data: pngData) ?? NSImage(), data: pngData)   // pending
        movingHolder.noteFolder = work                                                                                    // moved
        NotePictures.shared.written([movedKey])
        expect(NotePictures.shared.bytes(movedKey) == pngData, "after the move, the editor contains its picture where it leads now: held")
        NotePictures.shared.unregister(movingHolder)

        // One arrival for a batch of pictures: each editor scans its pictures once.
        let batchFiles = (0..<50).map { (URL(fileURLWithPath: "/tmp/petal-rich/Pictures/batch/p\($0).png"), NSImage(size: NSSize(width: 2, height: 2)), Optional<Data>.none) }
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
