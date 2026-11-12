import AppKit
import PDFKit
import SwiftUI

/// `Petal --helpers-check [--ai]`: helpers in notes run end to end, without showing anything.
///
/// Headless (`Headless`), on throwaway folders it makes itself in the temporary folder (`PETAL_CONFIG_DIR`,
/// `PETAL_SUPPORT_DIR`, `PETAL_NOTES`), with a made-up vault and no socket: never the person's settings, notes, state
/// or Keychain. It builds the real `PetalApp` with its `NoteStore`, `NoteDesk`, `NoteHelpers`, `Agent` and `Brain`,
/// and drives them as the person does: each note has the real editor (`NoteEditorView` in a window that's never
/// ordered in), a line is typed into it (`insertText`), and Return is the editor's own `insertNewline`, which hands
/// the line to `NoteHelpers.returned`.
///
/// Without `--ai` the AI app is a stand-in: a small script the check writes into its throwaway folder, which speaks
/// Claude Code's formats (stream-json for a chat turn, one JSON result for a quick call) and plays a fixed
/// transcript. Everything on Petal's side of that process is the real thing: `start`, the gate, `Agent`, its ingestion
/// queue and shielding, `end`, the helpers' journal and the store's write. With `--ai`, steps 1 and 6 run once more
/// against the person's own Claude Code (Haiku at low effort) or Codex, when it's installed and signed in: a few
/// short calls.
///
/// One line per step; exits non-zero when any fails.
@MainActor
enum HelpersCheck {
    static func run(ai: Bool) -> Never {
        Headless.on = true
        let checker = HelpersChecker()
        let failed = checker.run(ai: ai)
        exit(failed == 0 ? 0 : 1)
    }
}

@MainActor
private final class HelpersChecker {
    let fm = FileManager.default
    let root: URL
    let config: URL, support: URL, notesA: URL, notesB: URL, provider: URL, papers: URL
    let app: PetalApp
    let script: String
    /// A made-up secret in the made-up vault (no real service's key looks like this).
    let secret = "petalcheck7Q2v9Lr4Xs8Tn"
    var failures = 0
    private var problems: [String] = []
    private var planned = 0
    /// The last call the stand-in got before this step began: a step counts only its own.
    private var callBase = 0
    private var seenWindows: Set<ObjectIdentifier> = []
    private var editors: [String: HelperEditor] = [:]

    var helpers: NoteHelpers { app.paper.helpers }

    init() {
        let made = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "petal-helpers-check-\(getpid())")
        try? FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // The folder as the disk spells it (the viewer's path rule compares real paths).
        let real = made.path.withCString { realpath($0, nil) }.map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? made.path
        root = URL(fileURLWithPath: real)
        config = root.appending(path: "config")
        support = root.appending(path: "support")
        notesA = root.appending(path: "notes")
        notesB = root.appending(path: "notes-other")
        provider = root.appending(path: "provider")
        papers = root.appending(path: "papers")
        for folder in [config, support, notesA, notesB, papers, provider.appending(path: "calls"),
                       provider.appending(path: "plans/chat"), provider.appending(path: "plans/quick")] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // Its own folders, before anything reads a setting or a file of Petal's.
        setenv("PETAL_CONFIG_DIR", config.path, 1)
        setenv("PETAL_SUPPORT_DIR", support.path, 1)
        setenv("PETAL_NOTES", notesA.path, 1)
        guard Config.folder.path == config.path, Config.supportFolder.path == support.path else {
            print("FAIL  set up: Petal's folders were read before the check could point them at its own; nothing was run")
            exit(1)
        }
        let settings: [String: Any] = ["aiProviders": ["claude"], "chatProvider": "claude", "ai": true, "notes": true,
                                       "chatModel": "haiku", "chatEffort": "low", "computerUse": false]
        try? JSONSerialization.data(withJSONObject: settings).write(to: config.appending(path: "settings.json"))
        var key = VaultItem(kind: .apiKey, title: "Check key", sites: ["example.com"])
        key[.value] = secret
        VaultStore.standIn([key])
        // The viewer shows files in the home folder; the check's are in the temporary folder, so one folder above
        // them stands in for it (as `--viewer-check` does), and its versions' copies have a root of their own.
        ViewerPath.home = "/private"
        ViewerVersionStore.location = root.appending(path: "versions")
        script = provider.appending(path: "stand-in").path
        try? Self.standIn.write(toFile: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        app = PetalApp()
        app.standIn(.claude, at: script)
    }

    // MARK: The stand-in AI app

    /// Plays one plan per call: the first in `plans/chat` or `plans/quick` (a quick call's arguments end in `json`)
    /// whose `#match` words are in what it was sent, and records what it was started with (`calls/<n>`: its mode,
    /// pid, arguments and input). Lines starting with # are its own: `#sleep`, `#mark`, `#stderr`, `#exit`; every
    /// other line is printed as it is. Ended by a signal, it ends its sleep and dies by that signal, as an AI app does.
    static let standIn = ##"""
    #!/bin/sh
    # Petal --helpers-check's stand-in for an AI app: it plays a fixed transcript. Made by the check, in its own
    # throwaway folder; it reads and writes nothing outside it.
    dir=$(cd "$(dirname "$0")" && pwd)
    mode=chat
    for a in "$@"; do [ "$a" = "json" ] && mode=quick; done
    n=1
    while ! mkdir "$dir/calls/$n" 2>/dev/null; do n=$((n+1)); done
    c="$dir/calls/$n"
    printf '%s\n' "$mode" > "$c/mode"
    echo $$ > "$c/pid"
    for a in "$@"; do printf '%s\n' "$a"; done > "$c/args"
    cat > "$c/prompt"
    plan=""
    for f in "$dir/plans/$mode"/*; do
      [ -f "$f" ] || continue
      first=$(head -n 1 "$f")
      case "$first" in
        "#match "*) grep -qF -- "${first#\#match }" "$c/prompt" || continue ;;
      esac
      if mv "$f" "$c/plan" 2>/dev/null; then plan="$c/plan"; break; fi
    done
    : > "$c/ready"
    if [ -z "$plan" ]; then echo "the check planned no $mode call here" >&2; exit 9; fi
    child=""
    trap 'if [ -n "$child" ]; then kill "$child" 2>/dev/null; fi; trap - TERM; kill -TERM $$' TERM
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "#match "*) ;;
        "#sleep "*) sleep "${line#\#sleep }" & child=$!; wait "$child"; child="" ;;
        "#stderr "*) printf '%s\n' "${line#\#stderr }" >&2 ;;
        "#mark "*) : > "$c/${line#\#mark }" ;;
        "#exit "*) exit "${line#\#exit }" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$plan"
    exit 0

    """##

    struct Call {
        let number: Int
        let folder: URL
        let mode: String
        let prompt: String
        let arguments: String
        let pid: Int32
        func marked(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appending(path: name).path) }
        var alive: Bool { pid > 0 && kill(pid, 0) == 0 }
    }

    /// Every call the stand-in got in this step so far, in the order they began.
    func calls(_ mode: String? = nil) -> [Call] {
        let folder = provider.appending(path: "calls")
        let numbers = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { Int($0) }.filter { $0 > callBase }.sorted()
        return numbers.compactMap { number -> Call? in
            let call = folder.appending(path: "\(number)")
            guard fm.fileExists(atPath: call.appending(path: "ready").path) else { return nil }
            let read = { (name: String) in (try? String(contentsOf: call.appending(path: name), encoding: .utf8)) ?? "" }
            let kind = read("mode").trimmingCharacters(in: .whitespacesAndNewlines)
            guard mode == nil || mode == kind else { return nil }
            return Call(number: number, folder: call, mode: kind, prompt: read("prompt"), arguments: read("args"),
                        pid: Int32(read("pid").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        }
    }

    func json(_ object: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// A chat turn's lines, as Claude Code's stream-json says them.
    func session(_ id: String = "check-session") -> String { json(["type": "system", "subtype": "init", "session_id": id]) }
    func says(_ text: String) -> String { json(["type": "assistant", "message": ["content": [["type": "text", "text": text]]]]) }
    func runs(_ command: String) -> String {
        json(["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash", "input": ["command": command]]]]])
    }
    func result(_ text: String, denied: [String] = [], session id: String = "check-session") -> String {
        json(["type": "result", "subtype": "success", "is_error": false, "result": text, "session_id": id,
              "permission_denials": denied.map { ["tool_name": "Bash", "tool_input": ["command": $0]] }])
    }
    /// A whole plain turn: it says `text` and ends well.
    func turn(_ text: String, sleep seconds: Double = 0, session id: String = "check-session") -> [String] {
        [session(id), "#mark started"] + (seconds > 0 ? ["#sleep \(seconds)"] : []) + [says(text), result(text, session: id)]
    }
    /// A quick call's answer, as `claude -p --output-format json` says it.
    func quick(_ answer: [String: Any]) -> [String] { [json(["type": "result", "is_error": false, "result": json(answer)])] }

    /// A call the stand-in is to get next (of those whose `match` words are in what it's sent).
    func plan(_ mode: String, _ lines: [String], match: String? = nil) {
        planned += 1
        let text = ((match.map { ["#match " + $0] } ?? []) + lines).joined(separator: "\n") + "\n"
        try? text.write(to: provider.appending(path: "plans/\(mode)/" + String(format: "%04d", planned)), atomically: true, encoding: .utf8)
    }

    var plansLeft: Int {
        ["chat", "quick"].reduce(0) { $0 + ((try? fm.contentsOfDirectory(atPath: provider.appending(path: "plans/\($1)").path))?.count ?? 0) }
    }

    func clearPlans() {
        for mode in ["chat", "quick"] {
            let folder = provider.appending(path: "plans/\(mode)")
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] { try? fm.removeItem(at: folder.appending(path: name)) }
        }
    }

    // MARK: Driving

    @discardableResult
    func wait(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while true {
            for editor in editors.values { editor.refresh() }
            if done() { return true }
            if Date() >= end { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        if !ok { problems.append(what()) }
    }

    /// One step: one line. Whatever it left running is stopped after it, and a call it planned that never came fails it.
    func step(_ number: String, _ title: String, _ body: () -> String) {
        problems = []
        callBase = ((try? fm.contentsOfDirectory(atPath: provider.appending(path: "calls").path)) ?? []).compactMap { Int($0) }.max() ?? 0
        let detail = body()
        expect(plansLeft == 0, "a call it expected never came")
        // Nothing is shown: no window of Petal's came on screen in this step.
        let shown = NSApp.windows.filter { $0.isVisible && !seenWindows.contains(ObjectIdentifier($0)) }
        for window in shown { seenWindows.insert(ObjectIdentifier(window)) }
        expect(shown.isEmpty, "a window came on screen: " + shown.map { "\(Swift.type(of: $0)) “\($0.title)” \($0.frame)" }.joined(separator: ", "))
        if problems.isEmpty {
            print("ok    \(number)  \(title): \(detail)")
        } else {
            failures += 1
            print("FAIL  \(number)  \(title): " + problems.joined(separator: "; "))
        }
        settle()
    }

    /// Nothing left at work or waiting between steps.
    func settle() {
        for noteID in Array(helpers.runs.keys) { helpers.stop(noteID) }
        clearPlans()
        wait(5) { self.helpers.runs.isEmpty && !self.calls().contains { $0.alive } }
    }

    /// A new note in the throwaway notes' folder, made through the store, with its editor.
    func note(_ body: String, places: [NoteStick] = [], in notebook: String = NoteShelf.inbox) -> String {
        let id = UUID().uuidString
        var file = NoteFile(id: id, body: body)
        file.places = places
        var made = false
        app.paper.store.make(file, in: notebook) { _ in made = true }
        wait(10) { made && self.helpers.paper(id).map { self.fm.fileExists(atPath: $0.url.path) } == true }
        guard let paper = helpers.paper(id) else { return id }
        let editor = HelperEditor(noteID: id, app: app)
        editors[id] = editor
        editor.show(paper)
        wait(5) { editor.text != nil }
        return id
    }

    /// The note as its file says it now (read from the disk, not from the store).
    func disk(_ noteID: String) -> NoteFile? {
        guard let url = helpers.paper(noteID)?.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return NoteFile.parse(text, fallbackID: "", fallbackDate: Date())
    }

    func diskText(_ noteID: String) -> String {
        helpers.paper(noteID).flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? ""
    }

    /// The person types a line at the end of the note. False: the editor isn't there, or the line isn't one Return runs.
    @discardableResult
    func type(_ noteID: String, _ line: String) -> Bool {
        guard let text = editors[noteID]?.text else { return false }
        let length = (text.string as NSString).length
        text.setSelectedRange(NSRange(location: length, length: 0))
        // A new line under what's there (the last line is plain words, or a line already asked: never one that would run).
        let last = (text.string as NSString).lineRange(for: NSRange(location: length, length: 0))
        if last.length > 0 {
            guard text.helperLine() == nil else { return false }
            text.insertNewline(nil)
        }
        text.insertText(line, replacementRange: text.selectedRange())
        return text.helperLine() != nil
    }

    /// Return, as the person presses it (the editor's own `insertNewline`).
    func pressReturn(_ noteID: String) {
        editors[noteID]?.text?.insertNewline(nil)
        wait(0.2)
    }

    /// Types a line and presses Return at its end.
    @discardableResult
    func ask(_ noteID: String, _ line: String) -> Bool {
        let runnable = type(noteID, line)
        pressReturn(noteID)
        return runnable
    }

    /// Whether Return at the end of `line` (as it is in the editor now) would run it.
    func runnable(_ noteID: String, _ line: String) -> Bool {
        guard let text = editors[noteID]?.text else { return false }
        let range = (text.string as NSString).range(of: line, options: .backwards)
        guard range.location != NSNotFound else { return false }
        text.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        return text.helperLine() != nil
    }

    func state(_ noteID: String) -> NoteHelp.Helper.State? { disk(noteID)?.helper?.state }

    // MARK: The steps

    func run(ai: Bool) -> Int {
        defer { try? fm.removeItem(at: root) }
        var entered = false
        app.paper.startHeadless(root: notesA) { entered = true }
        guard wait(30, until: { entered && self.app.paper.acceptsChanges }) else {
            print("FAIL  set up: the notes' folder never became ready")
            return 1
        }
        first()
        second()
        third()
        fourth()
        fifth()
        sixth(number: "6")
        let server = PageServer()
        seventh(server)
        server.stop()
        eighth()
        ninth()
        tenth()
        eleventh()
        twelfth()
        thirteenth()
        fourteenth(number: "14")
        fifteenth()
        sixteenth()
        seventeenth()
        eighteenth()
        if ai { real() }
        settle()
        print(failures == 0 ? "helpers-check: all passed" : "helpers-check: \(failures) failed")
        return failures
    }

    /// 1. A plain "@Petal …" line.
    func first() {
        step("1", "a plain @Petal line") {
            let id = note("Lisbon in spring")
            let line = "@Petal say hello in five words"
            plan("chat", [session(), runs("ls notes"), says("Hello from the stand-in helper."), result("Hello from the stand-in helper.")])
            expect(ask(id, line), "the typed line is one Return runs")
            expect(wait(20) { self.state(id) == .done }, "helper: done never landed (\(String(describing: state(id))))")
            let chats = calls("chat")
            let file = disk(id)
            expect(chats.count == 1, "one chat call (\(chats.count))")
            expect(chats.first?.prompt.contains("say hello in five words") == true && chats.first?.prompt.contains("@Petal") == false, "its words are the line without @Petal")
            expect(chats.first?.arguments.contains("stream-json") == true && chats.first?.arguments.contains("Lisbon in spring") == true, "asked as a chat turn, told the note")
            expect(file?.ink.count == 1 && file?.ink.first?.text == "Hello from the stand-in helper.", "the answer is the note's ink (\(file?.ink.map(\.text) ?? []))")
            expect(file?.steps.contains { $0.contains("ls notes") } == true, "its step is on the back (\(file?.steps ?? []))")
            expect(file?.body.contains(line) == true, "the person's line is still in the note")
            expect(helpers.runs[id] == nil, "the run is over")
            // Unchanged, the line doesn't run again.
            expect(!runnable(id, line), "the line isn't runnable once it ran")
            pressReturn(id)
            wait(1)
            expect(calls("chat").count == 1, "Return on it again started nothing")
            return "one call, the answer in the file as ink, helper: done, the line not runnable again"
        }
    }

    /// 2. The stand-in says a vault secret in a step and in its answer.
    func second() {
        step("2", "a vault secret in a step and the answer") {
            let id = note("Keys to rotate")
            let answer = "The key is \(secret), as it was."
            plan("chat", [session(), runs("echo \(secret)"), "#mark started", "#sleep 2", says(answer), result(answer)])
            ask(id, "@Petal which key is it")
            expect(wait(10) { self.calls("chat").last?.marked("started") == true }, "the run started")
            // While it works, the note gets a second version (as iCloud leaves one): its result is held in the
            // helpers' journal until one is kept.
            guard let paper = helpers.paper(id) else { expect(false, "the note is there"); return "" }
            let copy = paper.url.deletingLastPathComponent().appending(path: paper.url.deletingPathExtension().lastPathComponent + " (conflicted copy).md")
            try? diskText(id).write(to: copy, atomically: true, encoding: .utf8)
            app.paper.store.reload()
            expect(wait(10) { self.helpers.paper(id) == nil }, "the note has two versions")
            let journal = NoteHelpers.journalFile
            let held = { () -> String in
                NoteJournal.queue.sync {}
                return (try? String(contentsOf: journal, encoding: .utf8)) ?? ""
            }
            expect(wait(15) { self.helpers.runs[id] == nil && HelperJournal.load(journal).contains { $0.noteID == id } }, "the result is held in the journal")
            let kept = held()
            expect(!kept.contains(secret) && kept.contains(UIMap.hidden), "the journal holds it redacted")
            // One version kept (the other file gone): the held result lands.
            try? fm.removeItem(at: copy)
            app.paper.store.reload()
            expect(wait(15) { self.state(id) == .done }, "the held result landed once one version was kept")
            let text = diskText(id)
            let file = disk(id)
            expect(!text.contains(secret), "the file never holds the secret")
            expect(file?.ink.first?.text.contains(UIMap.hidden) == true, "the ink says it redacted (\(file?.ink.first?.text ?? "none"))")
            expect(file?.steps.contains { $0.contains(UIMap.hidden) } == true && file?.steps.contains { $0.contains(secret) } == false, "the back says it redacted (\(file?.steps ?? []))")
            expect(wait(5) { NoteJournal.queue.sync {}; return !HelperJournal.load(journal).contains { $0.noteID == id } }, "the journal lets it go once it landed")
            return "the file, the helpers' journal (held through two versions of the note) and the back hold \(UIMap.hidden), never the secret"
        }
    }

    /// 3. Stop mid-run.
    func third() {
        step("3", "Stop while it works") {
            let id = note("A long question")
            let line = "@Petal think about this for a while"
            plan("chat", [session(), says("Working on it."), "#mark started", "#sleep 30", says("AN ANSWER THAT CAME TOO LATE"), result("AN ANSWER THAT CAME TOO LATE")])
            ask(id, line)
            expect(wait(10) { self.calls("chat").last?.marked("started") == true && self.state(id) == .working }, "it's at work (helper: working)")
            let call = calls("chat").last
            // The note's Stop (and the AI button's, and the pointer's) call this.
            helpers.stop(id)
            expect(wait(5) { call?.alive == false }, "the AI app's process ended")
            expect(wait(5) { self.disk(id).map { $0.helper == nil } == true }, "the helper line cleared (\(String(describing: state(id))))")
            wait(1)
            let file = disk(id)
            expect(file?.ink.isEmpty == true && file?.steps.isEmpty == true, "nothing was written (ink \(file?.ink.map(\.text) ?? []), steps \(file?.steps ?? []))")
            expect(!diskText(id).contains("TOO LATE"), "nothing of what came after")
            expect(helpers.runs[id] == nil, "no run is left")
            expect(runnable(id, line), "the line is runnable again")
            return "its process ended, the helper line cleared, no ink or steps written, the line runnable again"
        }
    }

    /// 4. The AI app fails.
    func fourth() {
        step("4", "the AI app fails") {
            let id = note("A question that fails")
            let line = "@Petal try this"
            plan("chat", [session(), "#stderr boom: the stand-in gave up", "#exit 3"])
            ask(id, line)
            expect(wait(15) { self.state(id) == .failed }, "helper: failed never landed (\(String(describing: state(id))))")
            let file = disk(id)
            expect(file?.ink.first?.text.contains("boom: the stand-in gave up") == true, "its reason is on the note (\(file?.ink.first?.text ?? "none"))")
            expect(helpers.runs[id] == nil, "the run is over")
            expect(runnable(id, line), "the line is runnable again")
            return "helper: failed, its reason as ink (“\(file?.ink.first?.text ?? "")”), the line runnable again"
        }
    }

    /// 5. A follow-up typed while the first run works.
    func fifth() {
        step("5", "a follow-up typed while it works") {
            let id = note("A draft to shorten")
            plan("chat", turn("The first answer.", sleep: 2), match: "write a first answer")
            plan("chat", turn("The shorter answer."), match: "make it shorter")
            ask(id, "@Petal write a first answer")
            expect(wait(10) { self.calls("chat").last?.marked("started") == true }, "the first run started")
            expect(ask(id, "@Petal and make it shorter"), "the follow-up's line is one Return runs")
            expect(calls("chat").count == 1, "the follow-up waits while the first works")
            expect(wait(20) { self.state(id) == .done && self.disk(id)?.ink.first?.text == "The shorter answer." }, "the follow-up's answer landed (\(disk(id)?.ink.map(\.text) ?? []))")
            wait(1.5)
            let chats = calls("chat")
            expect(chats.count == 2, "two calls, no more (\(chats.count))")
            expect(chats.last?.prompt.contains("make it shorter") == true && chats.last?.arguments.contains("--resume\ncheck-session") == true,
                   "the second is the follow-up, in the same session")
            expect(!runnable(id, "@Petal and make it shorter"), "the follow-up's line ran")
            return "it ran after the first, once, in the same session; its answer is the ink"
        }
    }

    /// 6. Recalculate and "put this away" through the quick AI. `real`: the person's own quick AI answers.
    func sixth(number: String, real: Bool = false) {
        step(number, real ? "recalculate and put this away (the real quick AI)" : "recalculate and put this away") {
            let limit: Double = real ? 120 : 20
            let before = calls("quick").count
            let sums = note("Flights: 412\nHotel: 300")
            if !real { plan("quick", quick(["label": "Total", "formula": "sum()"])) }
            ask(sums, "@Petal make this recalculate")
            expect(wait(limit) { self.state(sums) == .done || self.state(sums) == .failed }, "the recalculation never ended")
            let calc = disk(sums)?.calc
            let values = [(label: "Flights", value: 412.0), (label: "Hotel", value: 300.0)]
            expect(state(sums) == .done && calc != nil, "its formula landed with done (\(String(describing: state(sums))), \(disk(sums)?.ink.first?.text ?? ""))")
            expect(calc.flatMap { NoteHelp.evaluate($0.formula, values: values) } != nil, "the formula adds up on the note's numbers (\(calc?.formula ?? "none"))")
            if !real {
                expect(calc?.formula == "sum()" && calc?.label == "Total", "the formula it was given (\(calc?.formula ?? "none"))")
                expect(calls("quick").count == before + 1 && calls("quick").last?.prompt.contains("[Flights]") == true, "one quick call, told the labels")
            }

            // Put this away: the window in front's parts. The app in front and its parts are made up here (asking
            // macOS, the browser and Mail would read the person's own windows); everything after is the real path.
            NoteHelpers.appInFront = { ("com.example.browser", 99_999) }
            NoteHelpers.partsInFront = { _, _ in
                [NoteHelp.TaskItem(kind: .tab, title: "Flights to Lisbon", target: "https://example.com/flights"),
                 NoteHelp.TaskItem(kind: .tab, title: "A hotel by the river", target: "https://example.com/hotel")]
            }
            defer { NoteHelpers.appInFront = nil; NoteHelpers.partsInFront = nil }
            let away = note("Trip planning")
            if !real { plan("quick", quick(["line": "You were comparing flights. Next: book the hotel."])) }
            ask(away, "@Petal put this away")
            expect(wait(limit) { self.state(away) == .done || self.state(away) == .failed }, "putting away never ended")
            let file = disk(away)
            expect(state(away) == .done && file?.task.count == 2, "its task landed with done (\(String(describing: state(away))), \(file?.task.count ?? 0) parts)")
            expect(file?.task.first?.target == "https://example.com/flights", "the task's parts are what was open")
            expect(file?.ink.first?.text.isEmpty == false, "its line is the ink")
            if !real { expect(file?.ink.first?.text == "You were comparing flights. Next: book the hotel.", "the line it was given (\(file?.ink.first?.text ?? "none"))") }
            return "calc “\(calc?.label ?? ""): \(calc?.formula ?? "")” landed with done; a task of \(file?.task.count ?? 0) parts landed with its line (“\(file?.ink.first?.text ?? "")”)"
        }
    }

    /// 7. A watcher on a page a local server serves.
    func seventh(_ server: PageServer) {
        step("7", "a watcher") {
            guard server.port > 0 else { expect(false, "the local server didn't start"); return "" }
            var stick = NoteStick(kind: .tab)
            stick.url = "http://127.0.0.1:\(server.port)/item"
            stick.title = "A flight"
            stick.app = "com.example.browser"
            let id = note("Flight prices", places: [stick])
            let page = { (price: String) in "<html><head><title>A flight</title></head><body><h1>Lisbon</h1><p>Price: \(price) today</p></body></html>" }
            // A reading that doesn't cross the line: no AI is asked.
            server.page = page("$312")
            let quickBefore = calls("quick").count
            ask(id, "@Petal check this every morning, tell me under $300")
            expect(wait(15) { self.disk(id)?.watch?.amount == 312 }, "the first look read $312 (\(String(describing: disk(id)?.watch)))")
            var watch = disk(id)?.watch
            expect(watch?.last == "$312" && watch?.unconfirmed == "" && watch?.hit == false, "the corner says $312")
            expect(calls("quick").count == quickBefore, "a reading that doesn't cross asks no AI")
            expect(disk(id)?.ink.isEmpty == true, "a look writes no ink")
            wait(1.5)

            // One that crosses, and is confirmed.
            server.page = page("$289")
            plan("quick", quick(["yes": true, "say": "The flight is $289 now."]))
            helpers.look(id)
            expect(wait(15) { self.disk(id)?.watch?.amount == 289 }, "the confirmed crossing was taken (\(String(describing: disk(id)?.watch)))")
            watch = disk(id)?.watch
            expect(watch?.last == "$289" && watch?.history.first == "$312" && watch?.unconfirmed == "", "the corner says $289, $312 struck")
            expect(calls("quick").count == quickBefore + 1 && calls("quick").last?.prompt.contains("$289") == true, "its crossing was confirmed by one quick call")
            wait(1.5)

            // One that crosses, and is refuted: not taken, nothing shown.
            server.page = page("$279")
            plan("quick", quick(["yes": false, "say": ""]))
            helpers.look(id)
            expect(wait(15) { self.calls("quick").count == quickBefore + 2 }, "the next crossing was asked about")
            wait(2)
            watch = disk(id)?.watch
            expect(watch?.amount == 289 && watch?.last == "$289" && watch?.unconfirmed == "", "a refuted reading isn't taken (\(String(describing: watch)))")

            // One that crosses, with no explicit yes: shown as not confirmed, never taken.
            server.page = page("$269")
            plan("quick", quick(["say": "Maybe."]))
            helpers.look(id)
            expect(wait(15) { self.disk(id)?.watch?.unconfirmed == "$269" }, "an unconfirmed crossing is shown as that (\(String(describing: disk(id)?.watch)))")
            watch = disk(id)?.watch
            expect(watch?.amount == 289 && watch?.last == "$289" && watch?.hit == false, "and isn't taken")
            expect(server.served >= 4, "each look fetched the page (\(server.served))")
            return "$312 read plainly (no AI asked); $289 confirmed and taken, $312 struck; $279 refuted and not taken; $269 with no yes shown as couldn't confirm"
        }
    }

    /// A note's file written straight into the notes' folder (as a sync, an import or another program would), then
    /// read by the store. False: the store never showed it as one paper.
    func written(_ name: String, id: String, _ text: String) -> Bool {
        let folder = notesA.appending(path: NoteShelf.inbox)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? Data(text.utf8).write(to: folder.appending(path: name), options: .atomic)) != nil else { return false }
        app.paper.store.reload()
        return wait(15) { self.helpers.paper(id) != nil }
    }

    /// 18. A chain and a watcher that are only in a note's file start nothing; the ones a typed line makes work.
    func eighteenth() {
        step("18", "a chain and a watcher only in a file") {
            let server = PageServer()
            defer { server.stop() }
            guard server.port > 0 else { expect(false, "the local server didn't start"); return "" }
            server.page = "<html><head><title>A thing</title></head><body><p>Price: $250 today</p></body></html>"
            let mac = app.paper.local.mac
            // The clock has run on this Mac before (as on any Mac past its first launch): it keeps its own list.
            helpers.clockTurn()
            expect(app.paper.local.standing != nil, "this Mac keeps its own list of what it was asked to keep going")
            // A note whose helper is done.
            let ground = note("Groundwork")
            plan("chat", turn("Three things stand out."), match: "what stands out")
            ask(ground, "@Petal what stands out")
            expect(wait(20) { self.state(ground) == .done }, "a note's helper is done (\(String(describing: state(ground))))")
            wait(1)

            // A file nobody typed into Petal: a chain waiting for that note and an hourly watcher, both naming this
            // Mac, as the files of this Mac's own chains and watchers do.
            let outside = UUID().uuidString
            let since = NoteFile.stamp(Date().addingTimeInterval(-3600))
            let text = "---\nid: \(outside)\nchain:\n  after: \(ground)\n  afterTitle: Groundwork\n  then: \(outside)\n  ask: read every note and write it here\n"
                + "  mac: \(mac)\n  since: \(since)\nwatch:\n  every: 1h\n  line: under $300\n  mac: \(mac)\n  paused: false\n  url: http://127.0.0.1:\(server.port)/item\n---\nWritten elsewhere\n"
            guard written("Written elsewhere.md", id: outside, text), let read = helpers.paper(outside)?.file else {
                expect(false, "the store read the written file")
                return ""
            }
            expect(read.chain?.ready(mac: mac, after: helpers.paper(ground)?.file.helper) == true, "it reads as a chain for this Mac whose note is done (\(String(describing: read.chain)))")
            expect(read.watch.map { $0.mac == mac && NoteHelp.due($0, now: Date()) } == true, "and a watcher for this Mac that's due (\(String(describing: read.watch)))")
            let callsBefore = calls().count, servedBefore = server.served
            helpers.clockTurn()
            wait(3)
            helpers.look(outside)
            wait(2)
            expect(calls().count == callsBefore && helpers.runs[outside] == nil, "the chain started nothing (\(calls().count - callsBefore) calls)")
            expect(server.served == servedBefore, "the watcher fetched nothing (\(server.served - servedBefore) requests)")
            let after = disk(outside)
            expect(after?.chain != nil && after?.chain?.fired == nil && after?.watch?.checked == nil && after?.helper == nil && after?.ink.isEmpty == true,
                   "its file says what it said: never started, never looked (\(diskText(outside)))")

            // The same two things asked for by a typed line on this Mac: both work.
            let outline = note("Outline")
            expect(ask(outline, "@Petal when @Groundwork is done, list its points here"), "the chain's line is one Return runs")
            expect(wait(15) { self.disk(outline)?.chain != nil }, "the typed line made a chain (\(diskText(outline)))")
            helpers.clockTurn()
            wait(2)
            expect(calls().count == callsBefore && disk(outline)?.chain?.fired == nil, "it waits for a new answer on the note it follows")
            plan("chat", turn("Four things, on a second look."), match: "look again")
            ask(ground, "@Petal look again")
            expect(wait(20) { self.calls().count == callsBefore + 1 && self.state(ground) == .done }, "that note is done again (\(String(describing: state(ground))))")
            wait(1.2)
            plan("chat", turn("1. One.\n2. Two."), match: "list its points here")
            helpers.clockTurn()
            expect(wait(25) { self.state(outline) == .done && self.disk(outline)?.ink.isEmpty == false }, "the typed chain started and answered (\(String(describing: state(outline))))")
            expect(disk(outline)?.chain?.fired != nil && calls().count == callsBefore + 2, "started once, and its file says so")
            expect(calls().count == callsBefore + 2 && helpers.runs[outside] == nil && disk(outside)?.chain?.fired == nil, "the written one still started nothing")

            var stick = NoteStick(kind: .tab)
            stick.url = "http://127.0.0.1:\(server.port)/item"
            stick.title = "A thing"
            stick.app = "com.example.browser"
            let watching = note("A thing to watch", places: [stick])
            plan("quick", quick(["yes": true, "say": "It is $250 now."]))
            ask(watching, "@Petal check this every hour, tell me under $300")
            expect(wait(20) { self.disk(watching)?.watch?.amount == 250 }, "the typed watcher looked (\(String(describing: disk(watching)?.watch)))")
            expect(server.served == servedBefore + 1 && disk(outside)?.watch?.checked == nil, "and only it fetched the page (\(server.served - servedBefore) requests)")

            // A Mac that kept none yet (a Petal from before this): the ones already going for it are taken once.
            // (The written note goes first: the check's own file, in its own folder.)
            if let url = helpers.paper(outside)?.url { try? fm.removeItem(at: url) }
            app.paper.store.reload()
            expect(wait(15) { self.helpers.paper(outside) == nil }, "the written note is gone")
            let earlier = UUID().uuidString
            let old = "---\nid: \(earlier)\nwatch:\n  every: 1h\n  line: under $100\n  mac: \(mac)\n  paused: false\n  url: http://127.0.0.1:\(server.port)/item\n---\nFrom before\n"
            expect(written("From before.md", id: earlier, old), "the store read a watcher from before")
            helpers.clockTurn()
            wait(2)
            expect(disk(earlier)?.watch?.checked == nil, "with this Mac's own list kept, a file's watcher isn't looked for")
            app.paper.local.standing = nil
            helpers.clockTurn()
            expect(wait(20) { self.disk(earlier)?.watch?.amount == 250 }, "a Mac that kept none yet goes on with the watcher it had (\(String(describing: disk(earlier)?.watch)))")
            expect(app.paper.local.standing?.contains { $0.note == earlier } == true, "and keeps it from then on")
            return "a chain and a watcher written into a file started nothing and fetched nothing; the same asked by a typed line started once and looked; a Mac that kept none yet took the watcher it had"
        }
    }

    /// 8. A second opinion asked while a run works.
    func eighth() {
        step("8", "a second opinion queued behind a run") {
            let id = note("A plan to check")
            plan("chat", turn("The plan holds.", sleep: 2), match: "is this plan sound")
            plan("chat", turn("1. The dates overlap.\n2. Nothing covers the return.", session: "review-session"))
            ask(id, "@Petal is this plan sound")
            expect(wait(10) { self.calls("chat").last?.marked("started") == true }, "the first run started")
            expect(ask(id, "@Petal have Opus 5.5 look for holes"), "the second opinion's line is one Return runs")
            expect(calls("chat").count == 1, "it waits for the run at work")
            expect(wait(25) { self.state(id) == .done && self.disk(id)?.ink.count == 2 }, "the opinion landed after the answer (\(disk(id)?.ink.map(\.text) ?? []))")
            wait(1)
            let chats = calls("chat")
            let ink = disk(id)?.ink ?? []
            expect(chats.count == 2, "two calls (\(chats.count))")
            expect(chats.last?.arguments.contains("claude-opus-5-5") == true && chats.last?.arguments.contains("--resume") == false, "the reviewer is its own run, on the model named")
            expect(chats.last?.prompt.contains("The plan holds.") == true, "it was told the answer it reviews")
            expect(ink.first?.text == "The plan holds." && ink.first?.opinion == false, "the answer stands as it was")
            expect(ink.count == 2 && ink.last?.opinion == true && ink.last?.text.contains("The dates overlap") == true, "its opinion is added after it")
            expect(ink.last?.reviewed == NoteHelp.inkHash(ink.first), "the opinion says which answer it reviewed")
            return "it started after the answer landed, on the model named, and added only its opinion (\(ink.last?.objections.map { "\($0) objections" } ?? "no count"))"
        }
    }

    /// 9. Notes not ready.
    func ninth() {
        step("9", "notes not ready") {
            let id = note("Asked while the folder switches")
            let line = "@Petal say hello"
            expect(type(id, line), "the typed line is one Return runs")
            wait(1)
            var said: [String] = []
            app.paper.heard = { said.append($0) }
            defer { app.paper.heard = nil }
            // The journal's queue held: a switch of the notes' folder can't get past its second step, so notes stay
            // not ready for as long as this holds it.
            let gate = DispatchSemaphore(value: 0)
            NoteJournal.queue.async { gate.wait() }
            app.paper.switchFolder(to: notesB)
            expect(!app.paper.acceptsChanges, "notes aren't ready during the switch")
            let before = calls().count
            pressReturn(id)
            wait(1)
            expect(said.contains(NoteStore.gettingReady), "Return was refused with “getting ready” (\(said))")
            expect(calls().count == before && helpers.runs.isEmpty, "nothing started")
            expect(runnable(id, line), "the line stays runnable")
            gate.signal()
            // Back in its own folder (the desk follows the setting back), the same line runs.
            expect(wait(30) { self.app.paper.acceptsChanges && self.helpers.paper(id) != nil }, "the notes came back ready")
            plan("chat", turn("Hello."))
            pressReturn(id)
            expect(wait(20) { self.state(id) == .done }, "the same line ran once notes were ready (\(String(describing: state(id))))")
            return "refused with “\(NoteStore.gettingReady)”, nothing started, the line stayed runnable and ran once notes were ready"
        }
    }

    /// 10. A Private source.
    func tenth() {
        step("10", "a Private source") {
            // A Private notebook, as its cover's file says it.
            let diary = notesA.appending(path: "Diary")
            try? fm.createDirectory(at: diary, withIntermediateDirectories: true)
            let cover = NoteFile(id: UUID().uuidString, body: "# About this notebook\nPrivate things.").serialized()
                .replacingOccurrences(of: "\n---\n", with: "\nprivate: true\n---\n", options: [], range: nil)
            try? cover.write(to: diary.appending(path: "About this notebook.md"), atomically: true, encoding: .utf8)
            try? NoteFile(id: UUID().uuidString, body: "Something only the diary knows.").serialized()
                .write(to: diary.appending(path: "Entry.md"), atomically: true, encoding: .utf8)
            app.paper.store.reload()
            expect(wait(10) { self.app.paper.store.privateBooks.contains("Diary") }, "the notebook reads as Private (\(app.paper.store.privateBooks))")
            let id = note("A note outside the diary")
            let line = "@Petal check this against @Diary"
            let before = calls().count
            expect(ask(id, line), "the typed line is one Return runs")
            expect(wait(5) { self.helpers.hints[id] != nil }, "the note says why")
            wait(1)
            expect(helpers.hints[id]?.contains("private") == true, "refused as private (\(helpers.hints[id] ?? "nothing said"))")
            expect(helpers.runs[id] == nil && disk(id)?.helper == nil && disk(id)?.ink.isEmpty == true, "no run was made, nothing written")
            expect(calls().count == before, "nothing was sent to any AI")
            expect(runnable(id, line), "the line stays runnable")
            return "refused on the note (“\(helpers.hints[id] ?? "")”) before any run or call was made"
        }
    }

    /// 11. The apps kept private changed, then a quick helper (the first review finding).
    func eleventh() {
        step("11", "a quick helper after the private apps changed") {
            // What a change of the apps kept private does (ClaudePanel's settings change): a new generation.
            ClaudePanel.privacy.cancel()
            let id = note("Rent: 900\nPower: 80")
            let before = calls("quick").count
            plan("quick", quick(["label": "Monthly", "formula": "[Rent] + [Power]"]))
            ask(id, "@Petal make this recalculate")
            expect(wait(15) { self.state(id) == .done }, "the recalculation ran (\(String(describing: state(id))))")
            wait(1.5)
            expect(calls("quick").count == before + 1, "it ran once (\(calls("quick").count - before) quick calls)")
            expect(disk(id)?.calc?.formula == "[Rent] + [Power]", "its formula landed (\(disk(id)?.calc?.formula ?? "none"))")
            expect(helpers.runs[id] == nil, "the run is over, not starting again")
            return "the private apps' generation moved on, then recalculate ran once and landed"
        }
    }

    /// 12. A note in the margin of Petal's viewer (the second review finding).
    func twelfth() {
        step("12", "a helper on a note in the viewer's margin") {
            let pdf = papers.appending(path: "Report.pdf")
            Self.writePDF("A made-up report: growth held steady in the second half.", to: pdf)
            var stick = NoteStick(kind: .file)
            stick.path = pdf.path
            let id = note("About the report", places: [stick])
            let line = "@Petal what does this page say"

            // Its document isn't open anywhere: the helper waits for it, and says so.
            let before = calls().count
            ask(id, line)
            expect(wait(15) { self.state(id) == .waiting }, "it waits for its document (\(String(describing: state(id))))")
            let waiting = disk(id)?.helper?.step ?? ""
            expect(waiting.contains("Petal's viewer"), "it says the document needs to be open in Petal's viewer (“\(waiting)”)")
            expect(calls().count == before, "nothing is sent while it waits")

            // Opened in Petal's viewer (its window made, never ordered in): the viewer is the note's place, and what
            // waited goes on.
            plan("chat", turn("It says growth held steady.", sleep: 2))
            let model = app.viewers.show(pdf, front: false, window: true)
            expect(wait(30) { !model.loading && model.fileID != nil }, "the viewer read the document")
            // (The margin follows the notes through its SwiftUI view, which isn't on screen here: asked directly.)
            model.refreshPlaces()
            expect(wait(10) { model.notes.contains { $0.paper.noteID == id } }, "the note is in the viewer's margin")
            expect(wait(15) { self.calls("chat").last?.marked("started") == true && self.calls().count == before + 1 }, "what waited went on once the viewer showed it")
            let place = helpers.runs[id]?.sticky?.agent.place
            let window = app.viewers.place(of: model)?.window
            expect(place != nil && place?.pid == getpid() && place?.window != nil && place?.window == window, "its tools' target is the viewer's own window (\(String(describing: place)))")
            expect(place?.title == "Report.pdf" && place?.kind == .window, "by that window, titled for the file")
            expect(helpers.runs[id]?.sticky.map { self.app.claude.placed($0.id.uuidString) == place && self.app.claude.helperWaiting($0.id.uuidString) == nil } == true,
                   "petal_look and petal_ui are given that window, not told to wait")
            expect(calls("chat").last?.arguments.contains("Petal's viewer") == true && calls("chat").last?.arguments.contains("petal_view") == true, "it's told the viewer is its place")
            expect(wait(20) { self.state(id) == .done }, "its answer landed (\(String(describing: state(id))))")

            // petal_view gives the words of the page shown.
            var answer: [String: Any]?
            app.viewers.handle("petal_view", ["path": pdf.path], caller: "check", live: { true }, { answer = $0 as? [String: Any] }, { answer = ["refused": $0] })
            wait(20) { answer != nil }
            expect((answer?["text"] as? String)?.contains("growth held steady") == true, "petal_view tells the page's words (\(answer ?? [:]))")

            // The viewer closed: a helper asked then waits again.
            app.viewers.closed(model)
            ask(id, "@Petal and the next page")
            expect(wait(15) { self.state(id) == .waiting && self.disk(id)?.helper?.step.contains("Petal's viewer") == true }, "with the viewer closed it waits for the document again")
            expect(calls().count == before + 1, "and nothing more is sent")
            return "with no viewer it waits (“\(waiting)”); opened in Petal's viewer, its place is that window (pid \(place?.pid ?? 0), window \(place?.window ?? 0)) and it runs; petal_view gives the page's words"
        }
    }

    /// 14. The reading lens: a note in the viewer's margin that follows the selection. Off until it's turned on for
    /// the note; then each selection that settles asks the quick AI to do what the note says to it, with its
    /// paragraph (an empty note: explain it plainly); the newest selection wins; a vault secret on the page never
    /// reaches the AI; the answer shows beside the paragraph, nothing is written on the note; off when the viewer closes.
    func fourteenth(number: String, real: Bool = false) {
        step(number, real ? "the reading lens (the real quick AI)" : "the reading lens") {
            let limit: Double = real ? 120 : 20
            let pdf = papers.appending(path: real ? "Lens real.pdf" : "Lens.pdf")
            let lines = ["A made-up report", "The committee deferred the decision until the spring.", "Its made-up key is \(secret) for now.",
                         "Costs fell a little, and nobody was hired."]
            guard ViewerSamples.pdf([lines], to: pdf) else { expect(false, "the document couldn't be made"); return "" }
            var stick = NoteStick(kind: .file)
            stick.path = pdf.path
            let wish = "Say it again in five words."
            let id = note(wish, places: [stick])
            let model = app.viewers.show(pdf, front: false, window: true)
            defer { app.viewers.closed(model) }
            expect(wait(30) { !model.loading && model.fileID != nil }, "the viewer read the document")
            model.refreshPlaces()
            expect(wait(10) { model.notes.contains { $0.paper.noteID == id } }, "the note is in the viewer's margin")
            guard let key = helpers.paper(id)?.key, let text = PDFDocument(url: pdf)?.page(at: 0)?.string else { expect(false, "the note and the page's words (set up)"); return "" }
            let select = { (words: String) in
                let range = (text as NSString).range(of: words)
                model.selected(page: 0, bounds: CGRect(x: 72, y: 660, width: 200, height: 14), range: range, anchor: .zero)
            }
            let sent = { (call: Call?) in (call?.prompt ?? "") + "\n" + (call?.arguments ?? "") }
            let before = calls("quick").count
            let diskBefore = diskText(id)

            // Off until the person turns it on for this note: a selection asks nothing.
            select("deferred the decision")
            wait(1.5)
            expect(calls("quick").count == before && model.lensAnswer == nil, "not following: a selection asks nothing")
            model.unselected()

            // On: a selection that settles is asked about, with the note's words and its paragraph; the answer shows
            // beside the paragraph.
            model.follow(key)
            if !real { plan("quick", quick(["answer": "Decision waits until spring."]), match: "deferred the decision") }
            select("deferred the decision")
            expect(model.lensAnswer == nil && (real || calls("quick").count == before), "nothing is asked the moment a selection is made (it may still be moving)")
            expect(wait(limit) { model.lensAnswer.map { !$0.text.isEmpty } == true }, "the lens never answered (\(model.lensAnswer?.text ?? "nothing"))")
            let first = calls("quick").last
            let answered = model.lensAnswer?.text ?? ""
            expect(model.lensAnswer?.faint == false && !answered.isEmpty, "its answer shows beside the paragraph (“\(answered)”)")
            if !real { expect(answered == "Decision waits until spring.", "the answer is the quick AI's (“\(answered)”)") }
            expect(diskText(id) == diskBefore && helpers.runs[id] == nil, "nothing is written on the note, and it has no helper at work")
            // (The person's own AI app keeps no record here of what it was sent: the rest is the stand-in's to show.)
            guard !real else { return "the real quick AI answered “\(answered.prefix(80))” beside the paragraph" }
            expect(calls("quick").count == before + 1, "one call for one selection (\(calls("quick").count - before))")
            expect(sent(first).contains(wish) && sent(first).contains("deferred the decision") && sent(first).contains("The committee deferred the decision until the spring."),
                   "it's sent the note's words, what was selected and its paragraph")
            expect(!sent(first).contains("Costs fell"), "and only that paragraph of the page")

            // A secret from the vault on the page never reaches the AI.
            plan("quick", quick(["answer": "A key is mentioned."]), match: "made-up key")
            select("made-up key")
            expect(wait(limit) { model.lensAnswer?.text == "A key is mentioned." }, "the second selection answered (\(model.lensAnswer?.text ?? "nothing"))")
            let second = calls("quick").last
            expect(!sent(second).contains(secret) && sent(second).contains("(hidden)"), "a vault secret in the paragraph is hidden from what's sent")

            // Still moving: two selections in a row ask once, about the last.
            let moving = calls("quick").count
            plan("quick", quick(["answer": "Cheaper, same team."]), match: "nobody was hired")
            select("Costs fell")
            select("nobody was hired")
            expect(wait(limit) { model.lensAnswer?.text == "Cheaper, same team." }, "the settled selection answered (\(model.lensAnswer?.text ?? "nothing"))")
            expect(calls("quick").count == moving + 1 && !sent(calls("quick").last).contains("<selected>\nCosts fell"), "a selection still moving asks nothing: one call, about where it settled")

            // Cleared before it settled: a selection made and let go asks nothing (no call for a selection that's gone).
            let cleared = calls("quick").count
            select("Costs fell")
            model.unselected()
            wait(1.5)
            expect(calls("quick").count == cleared, "a selection cleared before it settled asks nothing (\(calls("quick").count - cleared) call(s))")

            // The newest wins: a slow answer for an older selection never shows once a newer one was asked.
            let racing = calls("quick").count
            plan("quick", ["#sleep 4"] + quick(["answer": "The old answer."]), match: "<selected>\nA made-up report")
            plan("quick", quick(["answer": "The new answer."]), match: "<selected>\nuntil the spring")
            select("A made-up report")
            expect(wait(limit) { self.calls("quick").count == racing + 1 }, "the older selection was asked")
            let older = calls("quick").last
            select("until the spring")
            expect(wait(limit) { model.lensAnswer?.text == "The new answer." }, "the newer selection answered (\(model.lensAnswer?.text ?? "nothing"))")
            expect(wait(6) { older?.alive == false }, "the older call was ended")
            wait(1)
            expect(model.lensAnswer?.text == "The new answer.", "the older answer never shows (“\(model.lensAnswer?.text ?? "")”)")

            // A note with no words of its own: explain it plainly.
            let empty = note("", places: [stick])
            model.refreshPlaces()
            expect(wait(10) { model.notes.contains { $0.paper.noteID == empty } }, "the empty note is in the margin")
            if let emptyKey = helpers.paper(empty)?.key {
                model.follow(emptyKey)
                plan("quick", quick(["answer": "They put the decision off."]), match: "plain words")
                select("deferred the decision")
                expect(wait(limit) { model.lensAnswer?.text == "They put the decision off." }, "the empty note's lens answered (\(model.lensAnswer?.text ?? "nothing"))")
                expect(sent(calls("quick").last).contains("Explain what they selected in plain words"), "an empty note asks for it in plain words")
            }

            // While the vault can't be read nothing is asked.
            let unread = calls("quick").count
            VaultStore.standUnreadable = true
            VaultIndex.changed()
            select("Costs fell a little")
            wait(2)
            VaultStore.standUnreadable = false
            VaultIndex.changed()
            expect(calls("quick").count == unread, "the vault unreadable: nothing is asked")

            // The viewer closed: the lens is off, and nothing more is asked.
            let closing = calls("quick").count
            app.viewers.closed(model)
            expect(model.lensKey == nil, "closing the viewer turns the lens off")
            wait(1.5)
            expect(calls("quick").count == closing, "and nothing more is asked")
            return "off until turned on; a settled selection is asked about with the note's words and its paragraph, answered beside it (“\(answered)”); a vault secret hidden; the newest selection wins; an empty note asks for plain words; nothing asked while the vault can't be read or once the viewer closed"
        }
    }

    /// 13. Allow while every place is taken (the third review finding).
    func thirteenth() {
        step("13", "Allow with every place taken") {
            // One helper's turn ends asking to run a command: it waits for the person, keeping its place.
            let asker = note("Needs a command")
            plan("chat", [session("asker-session"), says("I need to run a command."), result("I need to run a command.", denied: ["ls /made-up"], session: "asker-session")],
                 match: "list the made-up folder")
            ask(asker, "@Petal list the made-up folder")
            expect(wait(15) { self.helpers.runs[asker]?.sticky?.agent.pendingAsk.isEmpty == false && self.helpers.runs[asker]?.sticky?.agent.running == false },
                   "its turn ended asking to run a command")
            expect(wait(5) { self.state(asker) == .waiting }, "the note waits for Allow or Don't")
            // Three more at work: with the one asking, every place is taken.
            var others: [String] = []
            for index in 1...3 {
                let id = note("Busy \(index)")
                plan("chat", turn("Busy \(index) is done.", sleep: 60, session: "busy-\(index)"), match: "keep busy \(index)")
                ask(id, "@Petal keep busy \(index)")
                others.append(id)
            }
            expect(wait(15) { self.calls("chat").filter { $0.alive }.count == 3 }, "three others are at work")
            expect(app.claude.working == ClaudePanel.atOnce, "every place is taken (\(app.claude.working) of \(ClaudePanel.atOnce))")
            // A fifth has no room: it waits.
            let fifth = note("The fifth")
            plan("chat", turn("The fifth is done.", session: "fifth-session"), match: "wait your turn")
            ask(fifth, "@Petal wait your turn")
            wait(2)
            expect(helpers.runs[fifth]?.sticky?.agent.waiting.isEmpty == false && !calls("chat").contains { $0.prompt.contains("wait your turn") }, "a fifth waits for room")
            // Allow: the continuation is the same run's, in the place it kept, ahead of the one waiting.
            plan("chat", turn("The folder is empty.", session: "asker-session"), match: "I approved that")
            helpers.allowDenials(asker)
            expect(wait(15) { self.calls("chat").contains { $0.prompt.contains("I approved that") } }, "Allow's continuation ran")
            let continued = calls("chat").first { $0.prompt.contains("I approved that") }
            expect(continued?.arguments.contains("--resume\nasker-session") == true && continued?.arguments.contains("Bash(ls /made-up)") == true,
                   "in the same session, with what was allowed")
            expect(wait(15) { self.state(asker) == .done && self.disk(asker)?.ink.first?.text == "The folder is empty." }, "its answer landed (\(disk(asker)?.ink.map(\.text) ?? []))")
            expect(calls("chat").filter { $0.alive }.count >= 3 || calls("chat").contains { $0.prompt.contains("wait your turn") }, "while the others were still at work")
            let order = calls("chat").map(\.prompt)
            let approved = order.firstIndex { $0.contains("I approved that") } ?? Int.max
            let waited = order.firstIndex { $0.contains("wait your turn") } ?? Int.max
            expect(approved < waited, "before the one that waited for room")
            // Its place free now, the fifth starts.
            expect(wait(15) { self.state(fifth) == .done }, "the fifth ran once a place was free (\(String(describing: state(fifth))))")
            expect(disk(asker)?.stamps.contains { $0.label.contains("ALLOWED") } == true, "the Allow is stamped on the note's back")
            return "the asker kept its place (\(ClaudePanel.atOnce) of \(ClaudePanel.atOnce) taken, a fifth waiting); Allow's continuation ran at once in the same session, then the fifth"
        }
    }

    /// 15. A hidden display for each run, with made-up displays (nothing real is made, nothing is arranged): a helper
    /// gets one only when it needs it, the next waits its turn and says so, and every ending removes it.
    func fifteenth() {
        step("15", "a hidden display for each run (made up)") {
            var made: [CGDirectDisplayID] = []
            var removed: [CGDirectDisplayID] = []
            var next: CGDirectDisplayID = 9000
            app.displays.useMadeUp({ _, _, _ in
                next += 1
                let id = next
                made.append(id)
                return RunDisplays.Made(id: id, hiDPI: true, remove: { removed.append(id) })
            }, placed: { id, size in
                RunDisplays.Placing(frame: CGRect(x: -20_000 - CGFloat(id - 9000) * 2000, y: -20_000, width: size.width, height: size.height), tried: [])
            })
            app.config.set("runDisplays", true)
            app.config.set("runDisplaysLimit", 1)
            expect(app.displays.on, "hidden displays are on")
            var callers: [String] = []
            var ids: [String] = []
            for name in ["first", "second"] {
                let id = note("Display \(name)")
                plan("chat", turn("\(name) is done.", sleep: 60, session: "display-\(name)"), match: "work on the \(name) thing")
                ask(id, "@Petal work on the \(name) thing")
                ids.append(id)
            }
            expect(wait(15) { ids.allSatisfy { self.helpers.runs[$0]?.sticky?.agent.running == true } }, "two helpers are at work")
            callers = ids.compactMap { helpers.runs[$0]?.sticky?.id.uuidString }
            guard callers.count == 2 else { expect(false, "both have an agent"); return "" }
            expect(made.isEmpty && app.displays.displays.isEmpty, "none is made before a run needs one (\(made.count))")
            expect(app.displays.place(for: callers[0], asked: nil) == .display, "a helper opens on its own display")
            expect(app.displays.place(for: callers[0], asked: "screen") == .screen, "unless it says the person's screen")
            // The first needs one: made, placed, ready.
            var firstGot: RunDisplays.Display?
            var firstFailed: String?
            app.displays.need(callers[0]) { result in
                switch result {
                case .success(let display): firstGot = display
                case .failure(let why): firstFailed = why.words
                }
            }
            expect(wait(5) { firstGot != nil }, "the first run got its display (\(firstFailed ?? "no answer"))")
            expect(made.count == 1 && app.displays.display(for: callers[0])?.number == made.first, "one display, the first run's")
            expect(Screens.runIDs.isEmpty, "nothing real was made: no display is marked as a run's")
            // The second is past the limit: it waits its turn, and says so where its state shows.
            var secondGot: RunDisplays.Display?
            var secondFailed: String?
            app.displays.need(callers[1]) { result in
                switch result {
                case .success(let display): secondGot = display
                case .failure(let why): secondFailed = why.words
                }
            }
            wait(0.5)
            expect(secondGot == nil && secondFailed == nil && made.count == 1, "the second waits (limit 1)")
            expect(app.displays.waits(callers[1]) && !app.displays.waits(callers[0]), "it's known to wait for a display")
            let waiting = app.claude.note(withID: callers[1])
            expect(waiting.map { NoteStatus.line(self.app.claude.facts($0)) } == NoteStatus.waitingForDisplay, "its line says Waiting for a display")
            expect(waiting?.agent.activity.text == NoteStatus.waitingForDisplay, "and so does its note's step")
            expect(HelperBar.line(run: helpers.runs[ids[1]], helper: nil, displays: app.displays).hasSuffix(NoteStatus.waitingForDisplay),
                   "and its note's bar (\(HelperBar.line(run: helpers.runs[ids[1]], helper: nil, displays: app.displays)))")
            // The first is stopped: its display goes, and the one waiting gets the next.
            helpers.stop(ids[0])
            expect(wait(5) { removed == Array(made.prefix(1)) }, "Stop removed the first run's display (\(removed))")
            expect(wait(5) { secondGot != nil }, "the second got the next one (\(secondFailed ?? "no answer"))")
            expect(made.count == 2 && !app.displays.waits(callers[1]), "a second display, nobody waiting")
            expect(waiting?.agent.activity.text != NoteStatus.waitingForDisplay, "it no longer says it waits")
            // Turned off while one exists: it goes at once.
            app.config.set("runDisplays", false)
            expect(wait(5) { removed.count == 2 && self.app.displays.displays.isEmpty }, "turning hidden displays off removed the last one (\(removed))")
            expect(app.displays.place(for: callers[1], asked: "display") == .screen, "off: everything opens on the person's screen")
            var offAnswer: String?
            app.displays.need(callers[1]) { result in if case .failure(let why) = result { offAnswer = why.words } }
            expect(offAnswer == RunDisplayRules.off && made.count == 2, "and asking for one says they're off")
            app.config.set("runDisplaysLimit", 0)
            return "none before it was needed, the second waited its turn and said so, Stop and the switch each removed theirs (\(made.count) made, \(removed.count) removed, none real)"
        }
    }

    /// A helper at work with a made-up display of its own: its note, its chat's name for Petal's tools, its display.
    /// `lines`: what the stand-in plays (else it works for a minute).
    func displayRun(_ name: String, lines: [String]? = nil) -> (id: String, caller: String, display: RunDisplays.Display)? {
        let id = note("Display \(name)")
        plan("chat", lines ?? turn("\(name) is done.", sleep: 60, session: "display-\(name)"), match: "work on the \(name) thing")
        ask(id, "@Petal work on the \(name) thing")
        guard wait(15, until: { self.helpers.runs[id]?.sticky?.agent.running == true }),
              let caller = helpers.runs[id]?.sticky?.id.uuidString else { return nil }
        var got: RunDisplays.Display?
        app.displays.need(caller) { result in if case .success(let display) = result { got = display } }
        guard wait(5, until: { got != nil }), let display = got else { return nil }
        return (id, caller, display)
    }

    /// A made-up window's place on a made-up display.
    func spot(on display: RunDisplays.Display, _ index: Int = 0) -> CGRect {
        CGRect(x: display.frame.minX + 40 + CGFloat(index) * 20, y: display.frame.minY + 40 + CGFloat(index) * 20, width: 700, height: 500)
    }

    /// 16. What a run leaves when its display goes, however it ends, with made-up displays, apps and windows (nothing
    /// real is read, moved, closed or quit): an app the run started is asked to quit only when nobody used it and
    /// nothing in it is unsaved, an app the person had is never quit, and every window is closed or brought back by
    /// the rule.
    func sixteenth() {
        step("16", "what a run leaves on its display (made up)") {
            let world = MadeUpApps()
            var made: [CGDirectDisplayID] = []
            var removed: [CGDirectDisplayID] = []
            var next: CGDirectDisplayID = 9100
            app.displays.useMadeUp({ _, _, _ in
                next += 1
                let id = next
                made.append(id)
                return RunDisplays.Made(id: id, hiDPI: true, remove: { removed.append(id) })
            }, placed: { id, size in
                RunDisplays.Placing(frame: CGRect(x: -40_000 - CGFloat(id - 9100) * 2000, y: -40_000, width: size.width, height: size.height), tried: [])
            }, hands: world.hands)
            app.config.set("runDisplays", true)
            app.config.set("runDisplaysLimit", 1)
            let displays = app.displays
            let area = RunDisplays.personArea()
            let back = { (window: CGWindowID) -> Bool in world.placed(window).map { area.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false }

            // Stop, with one of every kind on the display.
            guard let stopped = displayRun("stopped") else { expect(false, "a helper with a display"); return "" }
            let quiet = world.app(), used = world.app(), clicked = world.app(), dirty = world.app(unsaved: .yes)
            let unread = world.app(unsaved: .unknown), stubborn = world.app(refusesQuit: true), theirs = world.app()
            for (index, pid) in [quiet, used, clicked, dirty, unread, stubborn].enumerated() {
                displays.launched(pid, bundle: "com.example.started\(index)", name: "Started \(index)", by: stopped.caller)
            }
            expect(displays.launchedApps(for: stopped.caller).count == 6, "six apps the run started are known as its own")
            let place = { (index: Int) in self.spot(on: stopped.display, index) }
            let quietWindow = world.window(of: quiet, at: place(0))
            let usedWindow = world.window(of: used, at: place(1))
            let clickedWindow = world.window(of: clicked, at: place(2))
            let dirtyWindow = world.window(of: dirty, at: place(3), modified: .yes)
            let dirtyPanel = world.window(of: dirty, at: place(4))
            let unreadWindow = world.window(of: unread, at: place(5), modified: .unknown)
            let stubbornWindow = world.window(of: stubborn, at: place(6))
            let theirDocument = world.window(of: theirs, at: place(7), document: .yes)
            let theirBlank = world.window(of: theirs, at: place(8))
            displays.track([quietWindow, usedWindow, clickedWindow, unreadWindow, stubbornWindow].map(\.item), for: stopped.caller, bare: true)
            displays.track([dirtyWindow].map(\.item), for: stopped.caller, bare: false)
            displays.track([dirtyPanel].map(\.item), for: stopped.caller, bare: false, panels: [dirtyPanel.window])
            displays.track([theirDocument].map(\.item), for: stopped.caller, bare: false, app: ("com.example.theirs", "Theirs"))
            displays.track([theirBlank].map(\.item), for: stopped.caller, bare: true, app: ("com.example.theirs", "Theirs"))
            // The person switched to one (their click a moment before it came forward): theirs now.
            world.set(idle: 0.3)
            displays.cameForward(used)
            // One came forward by itself (their hands still), and they then clicked in it: theirs too.
            world.set(idle: 600)
            displays.cameForward(clicked)
            world.set(front: clicked)
            displays.sampleFront()
            expect(displays.launchedApps(for: stopped.caller).first { $0.pid == clicked }?.used == false, "an app in front by itself, untouched, isn't used")
            world.set(idle: 0)
            displays.sampleFront()
            // And one came forward by itself and was never touched: nobody's use.
            world.set(idle: 600)
            displays.cameForward(quiet)
            world.set(front: quiet)
            displays.sampleFront()
            world.set(front: nil)
            let usedNow = Set(displays.launchedApps(for: stopped.caller).filter(\.used).map(\.pid))
            expect(usedNow == [used, clicked], "the person used two of them (\(usedNow.count))")
            helpers.stop(stopped.id)
            expect(wait(10) { removed.contains(stopped.display.number) }, "Stop removed its display (\(removed))")
            expect(Set(world.askedToQuit) == [quiet, stubborn], "asked to quit: the two nobody used with nothing unsaved (\(world.askedToQuit.count))")
            expect(!world.isRunning(quiet), "the one that could go is gone")
            expect([used, clicked, dirty, unread, stubborn, theirs].allSatisfy(world.isRunning), "the used ones, the unsaved one, the unreadable one and the person's own still run")
            expect(Set(world.closed) == [stubbornWindow.window, dirtyPanel.window, theirBlank.window],
                   "closed: the blank window of the one that wouldn't quit, a dialog with no document, a blank window in the person's app (\(world.closed.count))")
            expect([usedWindow, clickedWindow, dirtyWindow, unreadWindow, theirDocument].allSatisfy { back($0.window) },
                   "brought back to the person's screen: the windows of apps that became theirs, the unsaved one, the unreadable one, their document")
            expect(world.placed(quietWindow.window) == nil && world.raised.isEmpty, "nothing of the app that quit was moved, nothing came forward")
            let last = displays.settled.last
            expect(last?.quit == [quiet] && last?.stayed == [stubborn] && Set(last?.kept ?? []) == [used, clicked, dirty, unread],
                   "settled as: one quit, one that wouldn't, four kept (\(String(describing: last)))")

            // Pause, after Show me: what the person took is theirs; what nobody used goes.
            guard let paused = displayRun("paused") else { expect(false, "a second helper with a display"); return "" }
            let seen = world.app(), tidy = world.app()
            displays.launched(seen, bundle: "com.example.seen", name: "Seen", by: paused.caller)
            displays.launched(tidy, bundle: "com.example.tidy", name: "Tidy", by: paused.caller)
            let seenWindow = world.window(of: seen, at: spot(on: paused.display))
            displays.track([seenWindow].map(\.item), for: paused.caller, bare: true)
            displays.showMe(caller: paused.caller)
            expect(wait(5) { back(seenWindow.window) && world.raised == [seenWindow.window] }, "Show me brought its window to the person's screen and forward")
            expect(displays.display(for: paused.caller) != nil && helpers.runs[paused.id]?.sticky?.agent.running == true, "its display stays, and the run goes on")
            let tidyWindow = world.window(of: tidy, at: spot(on: paused.display, 1))
            displays.track([tidyWindow].map(\.item), for: paused.caller, bare: true)
            expect(world.placed(tidyWindow.window) == nil, "what it opens next is still on its display")
            let movesBefore = world.moves
            helpers.pause(paused.id)
            expect(wait(10) { removed.contains(paused.display.number) }, "Pause removed its display (\(removed))")
            expect(!world.askedToQuit.contains(seen) && world.isRunning(seen), "the app the person was shown is left running")
            expect(world.askedToQuit.contains(tidy) && !world.isRunning(tidy), "the one nobody used was asked to quit and went")
            expect(world.moves == movesBefore && !world.closed.contains(seenWindow.window), "the window on their screen was left alone")

            // The run fails.
            let failing = [session("display-failed"), "#mark started", "#sleep 8", "#stderr boom: the stand-in gave up", "#exit 3"]
            guard let failed = displayRun("failed", lines: failing) else { expect(false, "a third helper with a display"); return "" }
            let orphan = world.app()
            displays.launched(orphan, bundle: "com.example.orphan", name: "Orphan", by: failed.caller)
            let orphanWindow = world.window(of: orphan, at: spot(on: failed.display))
            let keptDocument = world.window(of: theirs, at: spot(on: failed.display, 1), document: .yes)
            displays.track([orphanWindow].map(\.item), for: failed.caller, bare: true)
            displays.track([keptDocument].map(\.item), for: failed.caller, bare: false, app: ("com.example.theirs", "Theirs"))
            expect(wait(30) { self.state(failed.id) == .failed }, "the run failed (\(String(describing: state(failed.id))))")
            expect(wait(10) { removed.contains(failed.display.number) }, "a failed run's display is removed (\(removed))")
            expect(world.askedToQuit.contains(orphan) && back(keptDocument.window) && world.isRunning(theirs), "its app was asked to quit, the person's document came back, their app runs on")

            // The note is thrown away while its helper works (its file gone from the check's own folder; never the Trash).
            guard let thrown = displayRun("thrown") else { expect(false, "a fourth helper with a display"); return "" }
            let left = world.app()
            displays.launched(left, bundle: "com.example.left", name: "Left", by: thrown.caller)
            if let url = helpers.paper(thrown.id)?.url { try? fm.removeItem(at: url) }
            app.paper.store.reload()
            expect(wait(15) { self.helpers.paper(thrown.id) == nil }, "the note is gone")
            // What its next tool call meets: the gate, which ends a run whose note is gone.
            wait(10) { self.helpers.admitTool(thrown.caller) != nil && self.helpers.runs[thrown.id] == nil }
            expect(helpers.runs[thrown.id] == nil, "its run ended at its next tool call")
            expect(wait(10) { removed.contains(thrown.display.number) }, "the display of a note thrown away is removed (\(removed))")
            expect(world.askedToQuit.contains(left), "and its app was asked to quit")

            // Petal quits.
            guard let quitting = displayRun("quitting") else { expect(false, "a fifth helper with a display"); return "" }
            let last5 = world.app(), unsavedLast = world.app(unsaved: .yes)
            displays.launched(last5, bundle: "com.example.last", name: "Last", by: quitting.caller)
            displays.launched(unsavedLast, bundle: "com.example.unsaved", name: "Unsaved", by: quitting.caller)
            let unsavedWindow = world.window(of: unsavedLast, at: spot(on: quitting.display), modified: .yes)
            displays.track([unsavedWindow].map(\.item), for: quitting.caller, bare: true)
            displays.quit()
            expect(removed.contains(quitting.display.number) && displays.displays.isEmpty, "Petal quitting removes every display at once")
            expect(world.askedToQuit.contains(last5) && !world.askedToQuit.contains(unsavedLast), "the unused app was asked to quit, the one with unsaved changes wasn't")
            expect(back(unsavedWindow.window), "and its window was put on the person's screen first")
            expect(!world.askedToQuit.contains(theirs), "the person's own app was never asked to quit, through all of it")
            expect(Screens.runIDs.isEmpty, "nothing real was made")
            app.config.set("runDisplays", false)
            app.config.set("runDisplaysLimit", 0)
            return "Stop, Pause, a failed run, a note thrown away and Petal quitting each removed the display (\(removed.count) of \(made.count)); \(world.askedToQuit.count) apps asked to quit, never one the person used, was shown, had open, or with unsaved or unreadable changes; \(world.closed.count) empty windows closed, the rest brought back (none real)"
        }
    }

    /// 17. Two runs, one app, with made-up displays, apps and windows: the second waits its turn and says so, a run
    /// never has another's window, a circle is refused, and Show me hands an app back.
    func seventeenth() {
        step("17", "two runs take turns on an app (made up)") {
            let world = MadeUpApps()
            var removed: [CGDirectDisplayID] = []
            var next: CGDirectDisplayID = 9200
            app.displays.useMadeUp({ _, _, _ in
                next += 1
                let id = next
                return RunDisplays.Made(id: id, hiDPI: true, remove: { removed.append(id) })
            }, placed: { id, size in
                RunDisplays.Placing(frame: CGRect(x: -60_000 - CGFloat(id - 9200) * 2000, y: -60_000, width: size.width, height: size.height), tried: [])
            }, hands: world.hands)
            app.config.set("runDisplays", true)
            app.config.set("runDisplaysLimit", 0)
            let displays = app.displays
            // Whatever this Mac's memory allows, the check needs two at once.
            guard displays.limit >= 2 else {
                app.config.set("runDisplays", false)
                return "skipped: this Mac's memory allows one hidden display at a time, and turns need two runs with one each"
            }
            guard let one = displayRun("one"), let two = displayRun("two") else { expect(false, "two helpers with a display each"); return "" }
            let writer = "com.example.writer", sums = "com.example.sums"
            let writerApp = world.app(), sumsApp = world.app()
            // The first opens something in Writer: free, so it goes ahead and has it.
            var firstAnswer: RunDisplays.Failure?
            var firstAnswered = false
            displays.turn(one.caller, app: writer, name: "Writer", hold: true) { firstAnswer = $0; firstAnswered = true }
            expect(firstAnswered && firstAnswer == nil, "the first run opens in a free app at once")
            let oneWindow = world.window(of: writerApp, at: spot(on: one.display), document: .yes)
            displays.track([oneWindow].map(\.item), for: one.caller, bare: false, app: (writer, "Writer"))
            displays.finished(one.caller, app: writer)
            expect(displays.appTurns.holder(of: writer) == displays.group(of: one.caller), "and has it while its window is on its display")
            // The second asks to open there, and to act there: both wait, in order, and say so.
            var opens: [Bool] = []
            var acts: [Bool] = []
            displays.turn(two.caller, app: writer, name: "Writer", hold: true) { opens.append($0 == nil) }
            displays.turn(two.caller, app: writer, name: "Writer", hold: false) { acts.append($0 == nil) }
            expect(opens.isEmpty && acts.isEmpty, "the second run's open and its act both wait")
            expect(displays.waitsForApp(two.caller) == "Writer" && displays.waitsForApp(one.caller) == nil, "it's known to wait for Writer")
            let waiting = app.claude.note(withID: two.caller)
            expect(waiting.map { NoteStatus.line(self.app.claude.facts($0)) } == "Waiting for Writer", "the AI button's preview says Waiting for Writer")
            let bar = HelperBar.line(run: helpers.runs[two.id], helper: nil, displays: displays)
            expect(bar.hasSuffix("Waiting for Writer"), "and so does its note's bar (\(bar))")
            expect(!displays.waits(two.caller), "it isn't waiting for a display: it has one")
            // A run never has another's window.
            expect(displays.foreign(window: oneWindow.window, to: two.caller) && !displays.foreign(window: oneWindow.window, to: one.caller),
                   "the first run's window is none of the second's, and its own")
            expect(displays.foreign(oneWindow.frame, to: two.caller) && displays.holds(oneWindow.frame, for: one.caller), "by where it is, too")
            // A circle: the second has Sums and waits for Writer; the first asking for Sums would never end.
            var sumsAnswered = false
            displays.turn(two.caller, app: sums, name: "Sums", hold: true) { sumsAnswered = $0 == nil }
            let twoSums = world.window(of: sumsApp, at: spot(on: two.display))
            displays.track([twoSums].map(\.item), for: two.caller, bare: true, app: (sums, "Sums"))
            displays.finished(two.caller, app: sums)
            var circle: RunDisplays.Failure?
            displays.turn(one.caller, app: sums, name: "Sums", hold: true) { circle = $0 }
            expect(sumsAnswered && circle?.words == AppTurns.circularWords("Sums"), "a circle is refused in words, never waited on (\(circle?.words ?? "no answer"))")
            // The person's own use wins: a run that needs real keys in an app they're using says it waits for it.
            displays.personBusy(one.caller, app: "Writer")
            expect(app.claude.note(withID: one.caller).map { NoteStatus.line(self.app.claude.facts($0)) } == "Waiting for Writer",
                   "a run waiting for the person to leave an app says so the same way")
            displays.personBusy(one.caller, app: nil)
            expect(displays.waitsForApp(one.caller) == nil, "and no longer once they've left it")
            // The first ends: its window is put away, and the second gets the app.
            helpers.stop(one.id)
            expect(wait(10) { removed.contains(one.display.number) }, "the first run's display is removed (\(removed))")
            expect(wait(5) { opens == [true] && acts == [true] }, "the second run's open and act both go ahead (\(opens), \(acts))")
            expect(displays.waitsForApp(two.caller) == nil, "it no longer says it waits")
            expect(waiting.map { NoteStatus.line(self.app.claude.facts($0)) } != "Waiting for Writer", "nor does the preview")
            let twoWindow = world.window(of: writerApp, at: spot(on: two.display, 1), document: .yes)
            displays.track([twoWindow].map(\.item), for: two.caller, bare: false, app: (writer, "Writer"))
            displays.finished(two.caller, app: writer)
            expect(displays.appTurns.holder(of: writer) == displays.group(of: two.caller), "the second has Writer now")
            // Show me on the second: its windows are the person's from then on, the run goes on, and Writer is free.
            let area = RunDisplays.personArea()
            displays.showMe(caller: two.caller)
            expect(wait(5) { world.placed(twoWindow.window).map { area.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false },
                   "Show me moved its window to the person's screen")
            expect(displays.display(for: two.caller) != nil && helpers.runs[two.id]?.sticky?.agent.running == true, "its display stays, and the run goes on")
            expect(displays.appTurns.holder(of: writer) == nil && !displays.foreign(window: twoWindow.window, to: one.caller),
                   "what it showed is the person's: the app is nobody's alone")
            var third = false
            displays.turn(two.caller, app: writer, name: "Writer", hold: false) { third = $0 == nil }
            expect(third, "and anyone may act in it again")
            expect(Screens.runIDs.isEmpty && world.askedToQuit.isEmpty, "nothing real was made, and no app the runs didn't start was asked to quit")
            app.config.set("runDisplays", false)
            return "the second run waited for Writer and said so on its note and in the preview, never had the first's window, a circle was refused in words, it got Writer when the first ended, and Show me handed it back while the run went on (none real)"
        }
    }

    // MARK: --ai

    /// Steps 1 and 6 once more, against the person's own AI app's quick setting (Claude Haiku at low effort, or
    /// Codex's), when it's installed and signed in.
    func real() {
        guard let found = Self.signedIn() else {
            print("skip  1 (--ai), 6 (--ai), 14 (--ai): neither Claude Code nor Codex is installed and signed in here")
            return
        }
        let provider = found.provider
        app.config.set("aiProviders", [provider.rawValue])
        app.config.set("chatProvider", provider.rawValue)
        app.standIn(.claude, at: nil)
        app.standIn(provider, at: found.path)
        wait(1)
        step("1 (--ai)", "a plain @Petal line, answered by \(provider.appName)") {
            let id = note("A word to say")
            ask(id, "@Petal reply with the one word ready, and nothing else. Use no tools.")
            expect(wait(180) { self.state(id) == .done || self.state(id) == .failed }, "it never ended (\(String(describing: state(id))))")
            let file = disk(id)
            expect(state(id) == .done, "helper: done (\(String(describing: state(id))): \(file?.ink.first?.text ?? ""))")
            expect(file?.ink.first?.text.isEmpty == false, "its answer is the note's ink")
            return "\(provider.appName) answered “\((file?.ink.first?.text ?? "").prefix(80))”; helper: done"
        }
        sixth(number: "6 (--ai)", real: true)
        fourteenth(number: "14 (--ai)", real: true)
    }

    /// The person's own AI app, when it's installed and says someone is signed in (its own status command; nothing of
    /// who is read or printed).
    static func signedIn() -> (provider: Provider, path: String)? {
        let folders = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.claude/local"]
        for provider in [Provider.claude, .codex] {
            guard let path = folders.map({ $0 + "/" + provider.binary }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = provider.statusArguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let timer = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timer)
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            timer.cancel()
            if provider.signedIn(status: process.terminationStatus, output: text) != nil { return (provider, path) }
        }
        return nil
    }

    // MARK: Made-up things

    /// A one-page PDF with `words` on it.
    static func writePDF(_ words: String, to url: URL) {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: words, attributes: [.font: NSFont.systemFont(ofSize: 16)]))
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        try? (data as Data).write(to: url)
    }
}

/// A note's own editor, as its paper makes it (`NoteEditorView` with the desk's own callbacks), in a window that's
/// never ordered in: the real text view, its coordinator and its handle registered with the desk.
@MainActor
private final class HelperEditor {
    let noteID: String
    let app: PetalApp
    private let window: NSWindow
    private let host: NSHostingView<AnyView>
    private var shown: PaperNote?
    private let token = UUID()

    init(noteID: String, app: PetalApp) {
        self.noteID = noteID
        self.app = app
        host = NSHostingView(rootView: AnyView(EmptyView()))
        window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 360, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
    }

    /// The editor's text view, once SwiftUI made it.
    var text: NoteTextView? { Self.find(in: host) }

    private static func find(in view: NSView) -> NoteTextView? {
        if let text = view as? NoteTextView { return text }
        for child in view.subviews { if let found = find(in: child) { return found } }
        return nil
    }

    /// The note as the store has it now, shown as its paper shows it (the editor takes a newer version by its own rule).
    func refresh() {
        guard let paper = app.paper.helpers.paper(noteID), paper != shown else { return }
        show(paper)
    }

    func show(_ paper: PaperNote) {
        shown = paper
        let desk = app.paper
        let color = NSColor.systemPink
        let token = self.token
        host.rootView = AnyView(
            NoteEditorView(paper: paper, style: desk.style(color, glass: false), focus: false,
                           height: { _ in },
                           save: { desk.write(paper.key, noteID: paper.noteID, instance: paper.instance, body: $0, base: $1) },
                           register: { desk.editorRegistered(paper.key, $0, token: token) },
                           importPictures: { _ in },
                           idle: { desk.store.takeDeferred(paper.key) },
                           sameNote: { desk.store.sameNote($0, instance: $1, $2) },
                           say: { desk.tell($0) },
                           settled: { desk.settleUnsaved(paper.key, noteID: paper.noteID, instance: paper.instance, saved: $0) },
                           helperReturn: { desk.helpers.returned(paper.key, line: $0, at: $1) },
                           names: { desk.helpers.names(for: paper.key) },
                           accent: color, tint: PaperLook.rgb(color))
                .frame(width: 340, height: 280))
        host.layoutSubtreeIfNeeded()
    }
}

/// A page served on this Mac only (127.0.0.1, a port the system picks), for a watcher to read: whatever `page` says
/// now, as an HTML page.
private final class PageServer: @unchecked Sendable {
    private let lock = NSLock()
    private var body = ""
    private var count = 0
    private var socketFD: Int32 = -1
    private(set) var port: UInt16 = 0

    var page: String {
        get { lock.withLock { body } }
        set { lock.withLock { body = newValue } }
    }
    var served: Int { lock.withLock { count } }

    init() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        socketFD = fd
        let thread = Thread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                // The request, up to its blank line.
                var request = Data()
                var buffer = [UInt8](repeating: 0, count: 2048)
                while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                    let got = read(client, &buffer, buffer.count)
                    if got <= 0 { break }
                    request.append(buffer, count: got)
                }
                let page = Data((self?.page ?? "").utf8)
                self?.lock.withLock { self?.count += 1 }
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                let answer = Data(head.utf8) + page
                answer.withUnsafeBytes { _ = write(client, $0.baseAddress, answer.count) }
                close(client)
            }
        }
        thread.start()
    }

    func stop() {
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
    }
}

/// Made-up apps and windows for hidden displays (`RunDisplays.Hands`), for the steps that settle what a run leaves:
/// what the check says of them is all there is. Nothing real is read, moved, closed or quit, and none of their
/// numbers is a real process or window.
private final class MadeUpApps: @unchecked Sendable {
    typealias Told = RunDisplayRules.Told
    private let lock = NSLock()
    private var alive: Set<pid_t> = []
    private var changes: [pid_t: Told] = [:]
    private var refusing: Set<pid_t> = []
    private var owners: [CGWindowID: pid_t] = [:]
    private var frames: [CGWindowID: CGRect] = [:]
    private var states: [CGWindowID: (document: Told, modified: Told)] = [:]
    private var moved: [CGWindowID: CGRect] = [:]
    private var quits: [pid_t] = []
    private var closes: [CGWindowID] = []
    private var raises: [CGWindowID] = []
    private var moveCount = 0
    private var frontApp: pid_t?
    private var still: TimeInterval = 600
    private var nextApp: pid_t = 900_000
    private var nextWindow: CGWindowID = 800_000

    /// A made-up app that's running. `refusesQuit`: asked to quit, it stays (as one that asks to save).
    func app(unsaved: Told = .no, refusesQuit: Bool = false) -> pid_t {
        lock.withLock {
            nextApp += 1
            alive.insert(nextApp)
            changes[nextApp] = unsaved
            if refusesQuit { refusing.insert(nextApp) }
            return nextApp
        }
    }

    /// A made-up window of it, as `RunDisplays.track` takes one (its Accessibility element is never asked anything).
    func window(of pid: pid_t, at frame: CGRect, document: Told = .no, modified: Told = .no) -> MadeUpWindow {
        let number: CGWindowID = lock.withLock {
            nextWindow += 1
            owners[nextWindow] = pid
            frames[nextWindow] = frame
            states[nextWindow] = (document, modified)
            return nextWindow
        }
        return MadeUpWindow(window: number, pid: pid, frame: frame)
    }

    func set(idle: TimeInterval) { lock.withLock { still = idle } }
    func set(front: pid_t?) { lock.withLock { frontApp = front } }
    func isRunning(_ pid: pid_t) -> Bool { lock.withLock { alive.contains(pid) } }
    func placed(_ window: CGWindowID) -> CGRect? { lock.withLock { moved[window] } }
    var askedToQuit: [pid_t] { lock.withLock { quits } }
    var closed: [CGWindowID] { lock.withLock { closes } }
    var raised: [CGWindowID] { lock.withLock { raises } }
    var moves: Int { lock.withLock { moveCount } }

    var hands: RunDisplays.Hands {
        RunDisplays.Hands(
            frame: { tracked in self.lock.withLock { self.frames[tracked.window] } },
            exists: { tracked in self.lock.withLock { self.frames[tracked.window] != nil } },
            state: { tracked in self.lock.withLock { self.states[tracked.window] ?? (.unknown, .unknown) } },
            close: { tracked in
                self.lock.withLock {
                    self.closes.append(tracked.window)
                    self.frames[tracked.window] = nil
                }
            },
            place: { tracked, frame in
                self.lock.withLock {
                    guard self.frames[tracked.window] != nil else { return }
                    self.frames[tracked.window] = frame
                    self.moved[tracked.window] = frame
                    self.moveCount += 1
                }
            },
            raise: { tracked in self.lock.withLock { self.raises.append(tracked.window) } },
            unsaved: { pid in self.lock.withLock { self.changes[pid] ?? .unknown } },
            running: { pid in self.lock.withLock { self.alive.contains(pid) } },
            quit: { pid in
                self.lock.withLock {
                    self.quits.append(pid)
                    guard !self.refusing.contains(pid) else { return }
                    self.alive.remove(pid)
                    for (window, owner) in self.owners where owner == pid { self.frames[window] = nil }
                }
            },
            front: { self.lock.withLock { self.frontApp } },
            idle: { self.lock.withLock { self.still } },
            pause: { _ in usleep(5_000) })
    }
}

/// A made-up window, as `MadeUpApps` knows it.
private struct MadeUpWindow {
    let window: CGWindowID
    let pid: pid_t
    /// Where it was put at first (the window server's coordinates).
    let frame: CGRect
    /// As `RunDisplays.track` takes a window: its Accessibility element is this process's own, and never asked anything.
    var item: (window: CGWindowID, pid: pid_t, element: AXUIElement) { (window, pid, AXUIElementCreateApplication(getpid())) }
}
