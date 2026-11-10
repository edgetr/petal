import AppKit
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

    // MARK: --ai

    /// Steps 1 and 6 once more, against the person's own AI app's quick setting (Claude Haiku at low effort, or
    /// Codex's), when it's installed and signed in.
    func real() {
        guard let found = Self.signedIn() else {
            print("skip  1 (--ai), 6 (--ai): neither Claude Code nor Codex is installed and signed in here")
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
