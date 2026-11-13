import AppKit

/// `Petal --notes-desk-check`: the notes on the screen driven as the person uses them, headless, on throwaway folders
/// (its own settings, Application Support and notes' folder; a made-up empty vault; no socket; the Trash replaced by
/// a folder of its own). The real desk (`NoteDesk`, started as `--helpers-check` starts it) with made-up windows in
/// front (`previewScene`, then the desk's own `refresh`, which applies them as a read of what's in front), notes made
/// through the desk as ⌃⌥N makes them, typed into with each paper's own editor (in its panel, never ordered in), and
/// laid out by the real `layout`. Nothing is shown, read from the person's apps, narrowed or moved.
///
/// One line per step; exits non-zero when any fails.
@MainActor
enum NotesDeskCheck {
    static func run() -> Never {
        Headless.on = true
        let checker = DeskChecker()
        exit(checker.run() == 0 ? 0 : 1)
    }
}

@MainActor
private final class DeskChecker {
    let fm = FileManager.default
    let root: URL, config: URL, support: URL, notes: URL, trash: URL
    let app: PetalApp
    var failures = 0
    private var problems: [String] = []

    var desk: NoteDesk { app.paper }

    init() {
        let made = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "petal-notes-desk-check-\(getpid())")
        try? FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        let real = made.path.withCString { realpath($0, nil) }.map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? made.path
        root = URL(fileURLWithPath: real)
        config = root.appending(path: "config")
        support = root.appending(path: "support")
        notes = root.appending(path: "notes")
        trash = root.appending(path: "trash")
        for folder in [config, support, notes, trash] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        // Its own folders, before anything reads a setting or a file of Petal's.
        setenv("PETAL_CONFIG_DIR", config.path, 1)
        setenv("PETAL_SUPPORT_DIR", support.path, 1)
        setenv("PETAL_NOTES", notes.path, 1)
        guard Config.folder.path == config.path, Config.supportFolder.path == support.path else {
            print("FAIL  set up: Petal's folders were read before the check could point them at its own; nothing was run")
            exit(1)
        }
        let settings: [String: Any] = ["aiProviders": [String](), "notes": true]
        try? JSONSerialization.data(withJSONObject: settings).write(to: config.appending(path: "settings.json"))
        VaultStore.standIn([])
        // A note let go goes to a Trash of the check's own, never the person's.
        let trash = self.trash
        NoteStore.toTrash = { url in
            (try? FileManager.default.moveItem(at: url, to: trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent))) != nil
        }
        app = PetalApp()
    }

    @discardableResult
    func wait(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while true {
            if done() { return true }
            if Date() >= end { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        if !ok { problems.append(what()) }
    }

    func step(_ number: String, _ title: String, _ body: () -> String) {
        problems = []
        let detail = body()
        let shown = NSApp.windows.filter(\.isVisible)
        expect(shown.isEmpty, "a window came on screen: " + shown.map { "\(Swift.type(of: $0)) \($0.frame)" }.joined(separator: ", "))
        if problems.isEmpty {
            print("ok    \(number)  \(title): \(detail)")
        } else {
            failures += 1
            print("FAIL  \(number)  \(title): " + problems.joined(separator: "; "))
        }
    }

    // MARK: Made-up windows

    /// A made-up window of a made-up app, in front.
    func front(_ window: CGWindowID, frame: CGRect) {
        let scene = NoteScene(mac: desk.local.mac, app: "com.example.editor", pid: 4242, window: window, title: "A made-up window \(window)")
        var read = ClaudePanel.FrontRead()
        read.window = window
        read.title = scene.title
        read.frame = frame
        desk.previewScene(scene, read: read)
        desk.refresh()
    }

    func stick(_ window: CGWindowID) -> NoteStick {
        var stick = NoteStick(kind: .window)
        stick.mac = desk.local.mac
        stick.app = "com.example.editor"
        stick.pid = 4242
        stick.window = window
        stick.title = "A made-up window \(window)"
        return stick
    }

    /// The editor in a paper's own panel, once SwiftUI made it.
    func editor(_ key: String) -> NoteTextView? {
        func find(_ view: NSView?) -> NoteTextView? {
            guard let view else { return nil }
            if let text = view as? NoteTextView { return text }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return find(desk.benchPanel(key)?.contentView)
    }

    func trashed() -> Int { ((try? fm.contentsOfDirectory(atPath: trash.path)) ?? []).count }

    /// The main screen's visible area in Accessibility's coordinates (y down from the main screen's top), less
    /// Petal's dock (none in a headless run).
    var screen: CGRect {
        let main = Screens.all.first
        let visible = main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
        let height = main?.frame.height ?? 900
        return CGRect(x: visible.minX, y: height - visible.maxY, width: visible.width, height: visible.height)
    }

    // MARK: Steps

    func run() -> Int {
        defer { try? fm.removeItem(at: root) }
        var entered = false
        desk.startHeadless(root: notes) { entered = true }
        guard wait(30, until: { entered && self.desk.acceptsChanges }) else {
            print("FAIL  set up: the notes' folder never became ready")
            return 1
        }
        typedThenLeft()
        roomMade()
        return failures
    }

    /// 1. A new note written in just before its window is left (within the editor's half second): kept, with what
    /// was typed. One left empty goes (to the check's own Trash).
    func typedThenLeft() {
        step("1", "a new note written in just before its window is left") {
            let frame = CGRect(x: screen.minX + 60, y: screen.minY + 40, width: 700, height: 500)
            front(81, frame: frame)
            guard let paper = desk.make(on: stick(81)) else { expect(false, "no note was made"); return "" }
            let key = paper.key
            wait(5) { self.editor(key) != nil }
            guard let text = editor(key) else { expect(false, "its editor was never made"); return "" }
            text.setSelectedRange(NSRange(location: 0, length: 0))
            text.insertText("Milk", replacementRange: text.selectedRange())
            // Straight away, before its save: another window in front.
            front(82, frame: frame.offsetBy(dx: 40, dy: 0))
            wait(1.5)
            let kept = desk.store.notes.first { $0.noteID == paper.noteID }
            expect(kept != nil, "the note written in went to the Trash")
            expect(kept?.file.body.contains("Milk") == true, "what was typed isn't in it: \(kept?.file.body ?? "(gone)")")
            // The same with nothing typed: it goes.
            front(81, frame: frame)
            let before = trashed()
            guard let empty = desk.make(on: stick(81)) else { expect(false, "no second note was made"); return "" }
            wait(0.3)
            front(82, frame: frame.offsetBy(dx: 40, dy: 0))
            wait(5) { self.trashed() > before }
            expect(desk.store.notes.first { $0.noteID == empty.noteID } == nil && trashed() == before + 1, "an empty new note left behind wasn't let go")
            return "kept with its words; an empty one let go"
        }
    }

    /// 2. A note opened on a window as wide as the screen, then the window narrowed for it (as Petal narrows it, the
    /// desk reading the window again): the paper sits in the room made, beside the window, where it was before the
    /// window narrowed. Then folded, opened again, and the window given back its width.
    func roomMade() {
        step("2", "a note on a full-width window, then the window narrowed for it") {
            let wide = CGRect(x: screen.minX, y: screen.minY + 5, width: screen.width, height: screen.height - 10)
            front(91, frame: wide)
            guard let paper = desk.make(on: stick(91)) else { expect(false, "no note was made"); return "" }
            let key = paper.key
            wait(0.3)
            guard let first = paperFrame(key) else { expect(false, "it was never placed"); return "" }
            guard let target = NoteRoom.narrowed(window: wide, visible: screen, note: PaperLook.openWidth, margin: PaperLook.margin) else {
                expect(false, "a full-width window wasn't to be narrowed")
                return ""
            }
            front(91, frame: target)
            wait(0.3)
            guard let after = paperFrame(key) else { expect(false, "it was no longer placed"); return "" }
            expect(abs(after.minX - (target.maxX + NoteRoom.gap)) < 1, "not beside the narrowed window: paper at \(after.minX), window ends at \(target.maxX)")
            expect(abs(after.minX - first.minX) < 1, "it moved sideways as the window narrowed: \(first.minX) → \(after.minX)")
            desk.fold(key)
            wait(0.3)
            let folded = paperFrame(key)
            expect(folded.map { abs($0.minX - (target.maxX + NoteRoom.gap)) < 1 } == true, "folded, it isn't beside the window: \(String(describing: folded))")
            desk.faces[key] = .open
            desk.layout()
            wait(0.3)
            let reopened = paperFrame(key)
            expect(reopened.map { abs($0.minX - (target.maxX + NoteRoom.gap)) < 1 } == true, "opened again, it isn't beside the window: \(String(describing: reopened))")
            desk.hide(key)
            front(91, frame: wide)
            return "beside the window at \(Int(after.minX)), as before it narrowed"
        }
    }

    /// Where a paper is placed (Accessibility's coordinates), from its panel less the shadow's margin (headless, a
    /// panel is placed and never ordered in).
    func paperFrame(_ key: String) -> CGRect? {
        guard let panel = desk.benchPanel(key), desk.faces[key] != nil, panel.alphaValue > 0 else { return nil }
        let height = Screens.all.first?.frame.height ?? 0
        let paper = panel.frame.insetBy(dx: PaperLook.margin, dy: PaperLook.margin)
        return CGRect(x: paper.minX, y: height - paper.maxY, width: paper.width, height: paper.height)
    }
}
