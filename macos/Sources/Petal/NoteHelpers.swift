import AppKit
import Observation

/// Petal Notes' helpers (Phase 2): @Petal in a note, run only when the person presses Return on that line in that
/// note (never from pasted, imported, synced or tool-written text). It runs the person's chat AI (Claude Code or
/// Codex) with Petal's tools on the note's place, as the old AI notes' agents did (background acting, the AI button's
/// preview, no more than `ClaudePanel.atOnce` at once); its answer is one block of ink on the note's front (the next
/// answer replaces it), its steps and the stamps for what was allowed on the back. Things said in words (bring this
/// back Friday, remember, put this away, check this every morning, recalculate, chains, morning notes) are done here,
/// most without any AI.
///
/// Two rules hold it together:
/// - **Every helper run is one operation** (`Run`, its `NoteHelp.Gate`), registered before any setup (a git fetch,
///   a worktree, an Allow card); every continuation asks `live(run)` first. Stop, Pause, a stamp taken back and a
///   watcher's pause or stop all go through it. Pause keeps it paused (Go on carries it on); only a run that ends
///   while running, with an answer, advances anything (a reviewer, a chain's next step).
/// - **Everything a helper tells an AI goes through NoteShield first** (`shield`, `NoteHelp.Shielded`): the line
///   asked, the note, the notebook's name and cover, the place's words, a chained or reviewed answer, a page's words.
///   Redacted whole, then derived or cut; nothing runs while the vault can't be read.
///
/// Every change a helper makes to a note goes through the note's session as a tool's change (it shows once it
/// landed), one at a time per note, and never while the person's editor there has typing not saved yet. A helper
/// only ever writes the front matter (`helper`, `ink`, `steps`, `stamps`, `back`, `watch`, `task`, `calc`, `chain`,
/// `worktree`), never the person's words, except "remember" and "forget", which edit the cover's "Petal remembers"
/// lines.
@MainActor @Observable
final class NoteHelpers {
    @ObservationIgnored weak var desk: NoteDesk?
    var app: PetalApp { PetalApp.shared }

    /// One helper run on a note: its gate, and what it needs once its agent answers.
    @MainActor @Observable
    final class Run {
        enum Kind: Equatable { case petal, code(folder: String), holes(folder: String?), quick }
        var gate: NoteHelp.Gate
        let noteID: String
        let asked: String
        var who: String
        var kind: Kind = .petal
        /// Its agent, once it has one (setup comes first).
        var sticky: StickyNote?
        /// Where this run's messages begin in its chat.
        var from = 0
        /// "and have <model> look for holes": run once this one succeeded.
        var holes: NoteHelp.Model?
        var finish: String?
        /// Waiting for the note's own place to be in front (never looking at whatever else is), and what goes on then.
        var awaitingPlace = false
        @ObservationIgnored var placedResume: (() -> Void)?
        /// Its agent was started (a turn sent): Go on carries that session on; before it, the request begins again.
        var launched = false
        /// Go on for a run paused before its agent started: the request is begun again.
        @ObservationIgnored var restart: (() -> Void)?

        init(id: Int, noteID: String, asked: String, who: String) {
            gate = NoteHelp.Gate(id: id)
            self.noteID = noteID
            self.asked = asked
            self.who = who
        }

        var paused: Bool { gate.paused }
    }

    private(set) var runs: [String: Run] = [:]
    @ObservationIgnored private var nextRun = 0
    /// Notes summoned to the screen (coming back, a watcher's hit, a source chip): shown on their place, or on the
    /// Desktop showing when their place isn't open, until the person puts them away.
    private(set) var summoned: Set<String> = []
    /// Morning notes made this run, by their id: never made twice while the file lands.
    @ObservationIgnored private var mornings: Set<String> = []
    /// Watchers looking now (by note id), and chains firing: one at a time each.
    @ObservationIgnored private var looking: Set<String> = []
    /// When each note's worktree was last checked for its PR having merged.
    @ObservationIgnored private var mergeChecked: [String: Date] = [:]
    @ObservationIgnored private var timer: Timer?
    /// Each note's helper writes, one at a time (a tool's change shows once it landed: the next is made on it).
    @ObservationIgnored private var writing: Set<String> = []
    @ObservationIgnored private var queued: [String: [(edit: (inout NoteFile) -> Void, touch: Bool, done: ((Bool) -> Void)?)]] = [:]
    /// The last step written into a note's `helper` (written at most every few seconds; the paper shows it live).
    @ObservationIgnored private var stepWritten: [String: Date] = [:]

    nonisolated static let petalWho = NoteHelp.mark + " " + NoteHelp.petal

    func start(_ desk: NoteDesk) {
        self.desk = desk
        guard timer == nil, !Headless.on else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { self.tick() } }
    }

    private var store: NoteStore? { desk?.store }
    private var mac: String { desk?.local.mac ?? "" }

    /// The note's one paper (never a conflict's copy).
    func paper(_ noteID: String) -> PaperNote? {
        let found = store?.notes.filter { $0.noteID == noteID && $0.version == nil } ?? []
        return found.count == 1 ? found[0] : nil
    }

    // MARK: Writing to a note

    /// Changes a note's front matter (or a cover's memory, `touch`) as a tool's change through its session: one at a
    /// time per note, each made on the note as the last one left it, and only once the person's editor there has
    /// nothing unsaved. `done`: whether it landed.
    func write(_ noteID: String, touch: Bool = false, _ edit: @escaping (inout NoteFile) -> Void, done: ((Bool) -> Void)? = nil) {
        queued[noteID, default: []].append((edit, touch, done))
        drain(noteID)
    }

    private func drain(_ noteID: String, tries: Int = 0) {
        guard !writing.contains(noteID), let waiting = queued[noteID], !waiting.isEmpty else { return }
        guard let desk, let paper = paper(noteID), !desk.store.readOnly(paper) else {
            queued[noteID] = nil
            for job in waiting { job.done?(false) }
            return
        }
        // Typing not saved yet: never written under it; tried again shortly.
        if desk.editors[paper.key]?.busy() == true {
            guard tries < 240 else { queued[noteID] = nil; for job in waiting { job.done?(false) }; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self.drain(noteID, tries: tries + 1) } }
            return
        }
        // Everything waiting goes in one write, in order.
        queued[noteID] = nil
        writing.insert(noteID)
        let touch = waiting.contains { $0.touch }
        let made = desk.store.change(paper.key, touch: touch, live: { true }, edit: { file in for job in waiting { job.edit(&file) } }) { outcome in
            self.writing.remove(noteID)
            for job in waiting { job.done?(outcome == .written) }
            self.drain(noteID)
        }
        if made == nil {
            writing.remove(noteID)
            for job in waiting { job.done?(false) }
        }
    }

    /// A helper's answer: one block of ink (replacing the last), the helper done.
    private func answer(_ noteID: String, _ ink: [NoteHelp.Ink], who: String, asked: String, steps: [String]? = nil) {
        let mac = self.mac
        write(noteID) { file in
            file.ink = ink
            if let steps { file.steps = steps }
            file.helper = NoteHelp.Helper(state: .done, who: who, step: "", asked: asked, mac: mac, at: Date())
        }
    }

    private func say(_ noteID: String, _ text: String, asked: String) {
        answer(noteID, [NoteHelp.Ink(who: Self.petalWho, text: text)], who: Self.petalWho, asked: asked)
    }

    /// A run that ended without an answer that counts (refused, failed, nothing found): its words on the note, and no
    /// helper left at work (so nothing waiting on it moves).
    private func ended(_ run: Run, _ text: String) {
        guard runs[run.noteID] === run else { return }
        run.gate.stop()
        runs[run.noteID] = nil
        if let sticky = run.sticky, sticky !== mainSticky(run.noteID) { drop(sticky) }
        write(run.noteID) { file in
            file.ink = [NoteHelp.Ink(who: run.who, text: text)]
            file.helper = nil
        }
    }

    // MARK: Runs (rule A)

    /// A run, registered before anything is set up: what was there before it on this note is stopped first.
    private func begin(_ paper: PaperNote, asked: String, step: String, who: String = NoteHelpers.petalWho) -> Run {
        if let old = runs[paper.noteID] { halt(old) }
        nextRun += 1
        let run = Run(id: nextRun, noteID: paper.noteID, asked: asked, who: who)
        runs[paper.noteID] = run
        working(paper.noteID, step: step, asked: asked, who: who)
        return run
    }

    /// Whether a continuation of `run` may go on: it's still the note's run, and running.
    private func live(_ run: Run) -> Bool { runs[run.noteID] === run && run.gate.live }

    /// Stops a run where it is: its agent, its card (answered Don't), what it did in apps.
    private func halt(_ run: Run) {
        run.gate.stop()
        if runs[run.noteID] === run { runs[run.noteID] = nil }
        if let sticky = run.sticky {
            app.assist.decline(owner: sticky.id.uuidString)
            if sticky.agent.running { app.claude.stop(sticky) } else { _ = sticky.agent.withdrawWaiting() }
            if sticky !== mainSticky(run.noteID) { drop(sticky) }
        }
    }

    /// Stop on the note: the run ends where it is, and says so. Nothing waiting on it moves.
    func stop(_ noteID: String) {
        if let run = runs[noteID] {
            halt(run)
            write(noteID) { file in
                file.helper = nil
                if run.sticky == nil || run.kind == .quick { return }
                file.ink = [NoteHelp.Ink(who: run.who, text: "Stopped.")]
            }
            return
        }
        // No run here (a chain waiting, or a helper left at work by a Petal that quit): its waiting ends.
        if paper(noteID)?.file.helper?.state != .done { write(noteID) { $0.helper = nil; $0.chain = nil } }
    }

    /// Pause: the run stops where it is and stays paused; Go on (or Return on a line) carries it on. A watcher's
    /// Pause pauses its looks (a look under way writes nothing back).
    func pause(_ noteID: String) {
        guard let run = runs[noteID] else {
            guard paper(noteID)?.file.watch != nil else { return }
            write(noteID) { file in
                guard var watch = file.watch else { return }
                watch.paused.toggle()
                watch.gen += 1
                file.watch = watch
            }
            looking.remove(noteID)
            return
        }
        if run.gate.paused { return goOn(run) }
        guard run.gate.pause() else { return }
        if let sticky = run.sticky {
            app.assist.decline(owner: sticky.id.uuidString)
            if sticky.agent.running { sticky.agent.stop() }
        }
        write(noteID) { file in file.helper?.state = .waiting; file.helper?.step = "Paused" }
    }

    private func goOn(_ run: Run, saying words: String = "Go on where you stopped.") {
        guard run.gate.goOn() else { return }
        write(run.noteID) { file in file.helper?.state = .working; file.helper?.step = "Going on" }
        if run.launched, let sticky = run.sticky {
            sticky.agent.send(words)
        } else if let restart = run.restart {
            // Paused before its agent started: begun again from the line.
            runs[run.noteID] = nil
            restart()
        }
    }

    // MARK: Return on an @ line

    /// The person pressed Return at the end of `line` in the note `key`: what it asks is done (once per line: Return
    /// on a line already answered only makes a new line).
    func returned(_ key: String, line: String) {
        guard let desk, let paper = desk.store.paper(key), paper.version == nil, NoteHelp.calls(line) else { return }
        guard !desk.store.readOnly(paper) else { return desk.tell("This note has two versions: keep one before asking a helper.") }
        let noteID = paper.noteID
        // An id-less note (a file written by hand) gets its own id first: nothing lasting is kept by a path.
        guard !NoteShelf.needsID(noteID) else {
            return desk.store.ensureID(key) { id in if id != nil, let paper = desk.store.notes.first(where: { $0.noteID == id }) { self.returned(paper.key, line: line) } }
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let helper = paper.file.helper, helper.asked == trimmed, helper.state == .done || runs[noteID] != nil { return }
        if let run = runs[noteID], run.launched, let sticky = run.sticky {
            // At work (or paused): what's said now steers it in the same session.
            if run.gate.paused { return goOn(run, saying: NoteHelp.spoken(trimmed)) }
            if run.gate.live { return sticky.agent.send(NoteHelp.spoken(trimmed)) }
        }
        let request = NoteHelp.request(trimmed, now: Date())
        switch request {
        case .bringBack(let date, _, let others): bringBack(paper, date: date, others: others, asked: trimmed)
        case .remember(let item): remember(paper, item, asked: trimmed)
        case .forget(let words): forget(paper, words, asked: trimmed)
        case .putAway: putAway(paper, asked: trimmed)
        case .watch(let every, let at, let line): watch(paper, every: every, at: at, line: line, asked: trimmed)
        case .stopWatching:
            write(noteID) { file in
                if var watch = file.watch { watch.gen += 1; file.watch = watch }
                file.watch = nil
            }
            looking.remove(noteID)
            say(noteID, "Stopped watching.", asked: trimmed)
        case .recalculate: recalculate(paper, asked: trimmed)
        case .chain(let after, let ask, let then): chain(paper, after: after, ask: ask, then: then, asked: trimmed)
        case .check(let against): check(paper, against: against, asked: trimmed)
        case .morning(let time): morning(paper, time: time, asked: trimmed)
        case .stopMorning:
            guard let cover = cover(of: paper.notebook) else { return say(noteID, "This notebook has no cover to keep that on.", asked: trimmed) }
            write(cover.noteID) { $0.morning = nil }
            say(noteID, "No more morning notes from \(paper.notebook).", asked: trimmed)
        case .done where paper.file.worktree != nil: removeWorktree(paper, why: "you said it's done", asked: trimmed)
        case .done: ask(paper, NoteHelp.spoken(trimmed), asked: trimmed)
        case .ask(let text): ask(paper, text, asked: trimmed)
        }
    }

    // MARK: Things said in words, done without an AI

    private func bringBack(_ paper: PaperNote, date: Date, others: [String], asked: String) {
        var names: [String] = []
        for name in others {
            guard let other = note(named: name, from: paper) else { continue }
            names.append(other.file.title)
            write(other.noteID) { $0.back = date }
        }
        write(paper.noteID) { $0.back = date }
        let when = NoteHelp.backLine(date, now: Date()).dropFirst(5)
        let who = names.isEmpty ? "This note" : "This note and " + names.joined(separator: ", ")
        say(paper.noteID, "\(who) will be in front of you \(when).", asked: asked)
    }

    private func remember(_ paper: PaperNote, _ item: String, asked: String) {
        guard !item.isEmpty else { return say(paper.noteID, "Remember what? Say it after “remember”.", asked: asked) }
        guard let cover = cover(of: paper.notebook) else { return say(paper.noteID, "\(paper.notebook) has no cover yet to remember it on.", asked: asked) }
        write(cover.noteID, touch: true, { $0.body = NoteHelp.remember($0.body, item) }) { landed in
            self.say(paper.noteID, landed ? "Remembered in \(paper.notebook): \(item)." : "Petal couldn't write it on \(paper.notebook)'s cover just now.", asked: asked)
        }
    }

    private func forget(_ paper: PaperNote, _ words: String, asked: String) {
        guard let cover = cover(of: paper.notebook) else { return say(paper.noteID, "\(paper.notebook) has no cover, so there's nothing to forget.", asked: asked) }
        let removed = NoteHelp.forget(cover.file.body, words).removed
        guard !removed.isEmpty else { return say(paper.noteID, "Nothing in \(paper.notebook)'s memory says “\(words)”.", asked: asked) }
        write(cover.noteID, touch: true, { $0.body = NoteHelp.forget($0.body, words).cover }) { landed in
            self.say(paper.noteID, landed ? "Forgot: " + removed.joined(separator: "; ") + "." : "Petal couldn't change \(paper.notebook)'s cover just now.", asked: asked)
        }
    }

    private func watch(_ paper: PaperNote, every: String, at: String, line: String, asked: String) {
        guard let url = page(of: paper) else {
            return say(paper.noteID, "Watch what? Stick this note to the page to watch first.", asked: asked)
        }
        var watch = NoteHelp.Watch(every: every, line: line, mac: mac, at: at, url: url)
        // Its clock is the one it was said in.
        watch.tz = TimeZone.current.identifier
        if let old = paper.file.watch {
            watch.gen = old.gen + 1
            if old.url == url { watch.last = old.last; watch.history = old.history; watch.hint = old.hint }
        }
        looking.remove(paper.noteID)
        write(paper.noteID) { $0.watch = watch }
        say(paper.noteID, "Watching \(NoteText.host(url)) \(NoteHelp.cadence(every: every, at: at).lowercased()) on this Mac. Petal tells you here when it's \(line).", asked: asked)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self.look(paper.noteID) } }
    }

    private func morning(_ paper: PaperNote, time: String, asked: String) {
        guard let cover = cover(of: paper.notebook) else { return say(paper.noteID, "\(paper.notebook) has no cover to keep that on.", asked: asked) }
        let mac = self.mac
        write(cover.noteID) { $0.morning = (time, mac) }
        say(paper.noteID, "Every morning at \(time), \(paper.notebook) leaves you a note on this Mac.", asked: asked)
    }

    private func chain(_ paper: PaperNote, after: String, ask: String, then: String?, asked: String) {
        guard let first = note(named: after, from: paper) else {
            return say(paper.noteID, "Petal couldn't find one note called “\(after)”.", asked: asked)
        }
        guard let target = then.map({ note(named: $0, from: paper) }) ?? paper else {
            return say(paper.noteID, "Petal couldn't find one note called “\(then ?? "")”.", asked: asked)
        }
        // Never a loop: no note ends up waiting, through others, for itself.
        let edges = (store?.notes ?? []).compactMap { note in note.file.chain.map { (waiting: note.noteID, on: $0.after) } }
            .filter { $0.waiting != target.noteID }
        guard !NoteHelp.loops(edges, adding: (waiting: target.noteID, on: first.noteID)) else {
            return say(paper.noteID, "That would make notes wait for each other in a circle, so nothing was set up.", asked: asked)
        }
        let chain = NoteHelp.Chain(after: first.noteID, afterTitle: first.file.title, then: target.noteID, ask: ask, mac: mac, since: Date())
        let mac = self.mac
        write(target.noteID) { file in
            file.chain = chain
            file.helper = NoteHelp.Helper(state: .waiting, who: Self.petalWho, step: "Waiting for \(first.file.title)", mac: mac, at: Date())
        }
        if target.noteID != paper.noteID {
            say(paper.noteID, "When \(first.file.title) is done, Petal will \(ask) on \(target.file.title).", asked: asked)
        } else {
            write(paper.noteID) { $0.helper?.asked = asked }
        }
    }

    // MARK: Rule B: everything told to an AI, shielded first

    /// `raw` with every field redacted whole by the vault's index (off the main thread); nil while the vault can't
    /// be read (the run ends saying so; nothing is sent).
    static func shield(_ raw: NoteHelp.Context, _ done: @escaping @MainActor (NoteHelp.Shielded?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = VaultIndex.settled { index -> NoteHelp.Shielded? in index.unreadable ? nil : NoteHelp.shield(raw, redact: { index.redacted($0) }) } ?? nil
            let carried = ShieldedBox(out)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(carried.value) } }
        }
    }

    private final class ShieldedBox: @unchecked Sendable {
        let value: NoteHelp.Shielded?
        init(_ value: NoteHelp.Shielded?) { self.value = value }
    }

    /// Shielded for `run`, then `then` while it's still live; the vault unreadable ends it saying so.
    private func shielded(_ run: Run, _ raw: NoteHelp.Context, _ then: @escaping @MainActor (NoteHelp.Shielded) -> Void) {
        Self.shield(raw) { shown in
            guard self.live(run) else { return }
            guard let shown else { return self.ended(run, NoteShield.unreadable) }
            then(shown)
        }
    }

    // MARK: Quick helpers (the quick AI once, then plain arithmetic or words)

    private func recalculate(_ paper: PaperNote, asked: String) {
        let values = NoteHelp.values(paper.file.body)
        guard !values.isEmpty else { return say(paper.noteID, "There's nothing to add up yet: write lines like “Flights: 412”.", asked: asked) }
        // The AI proposes the formula once (from the labels only, never the note's other words); arithmetic keeps it.
        let run = begin(paper, asked: asked, step: "Working out the formula")
        run.kind = .quick
        var raw = NoteHelp.Context()
        raw.labels = values.map(\.label)
        raw.ask = NoteHelp.spoken(asked)
        shielded(run, raw) { shown in
            self.app.focus.brain.ask(NoteHelp.formulaRequest(shown), key: "calc|\(paper.noteID)|\(run.gate.id)") { reply in
                guard self.live(run) else { return }
                let label = (reply?["label"] as? String).map { String($0.prefix(30)) } ?? "Total"
                let proposed = reply?["formula"] as? String ?? "sum()"
                // The formula names the labels as shown (redacted); one that doesn't add up on the note's own is sum().
                let formula = NoteHelp.evaluate(proposed, values: values) != nil ? proposed : "sum()"
                _ = run.gate.end(.succeeded)
                self.runs[paper.noteID] = nil
                self.write(paper.noteID) { $0.calc = NoteHelp.Calc(label: label, formula: formula) }
                self.answer(paper.noteID, [], who: Self.petalWho, asked: asked)
            }
        }
    }

    /// "Put this away": the window in front's tabs, the file it shows and the mail it came from become the note's
    /// task (Open all brings them back), with a short line of where the person stopped and what's next.
    private func putAway(_ paper: PaperNote, asked: String) {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
              !app.assist.neverLook(front.bundleIdentifier ?? "") else {
            return say(paper.noteID, "Petal couldn't tell what you were working on (or it's an app you keep private).", asked: asked)
        }
        let run = begin(paper, asked: asked, step: "Putting the task away")
        run.kind = .quick
        let bundle = front.bundleIdentifier ?? ""
        let pid = front.processIdentifier
        let file = desk?.scene?.file ?? ""
        NoteDesk.queue.async {
            var items = Self.windowTabs(bundle).map { NoteHelp.TaskItem(kind: .tab, title: $0.title, target: $0.url) }
            if !file.isEmpty { items.append(NoteHelp.TaskItem(kind: .file, title: (file as NSString).lastPathComponent, target: file)) }
            if bundle == "com.apple.mail", let mail = Self.selectedMail() { items.append(NoteHelp.TaskItem(kind: .mail, title: mail.subject, target: mail.url)) }
            if items.isEmpty, let title = Self.windowTitle(pid), !title.isEmpty { items.append(NoteHelp.TaskItem(kind: .window, title: title, target: bundle)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.live(run) else { return }
                    guard !items.isEmpty else { return self.ended(run, "There was nothing to put away in that window.") }
                    self.write(paper.noteID) { $0.task = items }
                    let plain = "Put away: \(NoteHelp.taskChips(items).joined(separator: ", ")). Open all brings them back."
                    let finish = { (line: String) in
                        guard self.live(run) else { return }
                        _ = run.gate.end(.succeeded)
                        self.runs[paper.noteID] = nil
                        let who = Self.petalWho + " · put away " + NoteHelp.dayLabel(Date(), now: Date())
                        self.answer(paper.noteID, [NoteHelp.Ink(who: who, text: line)], who: who, asked: asked)
                    }
                    guard self.app.focus.brain.enabled else { return finish(plain) }
                    // Where they stopped, from the titles only (shielded), by the quick AI.
                    var raw = NoteHelp.Context()
                    raw.labels = items.map(\.title)
                    raw.body = paper.file.body
                    self.shielded(run, raw) { shown in
                        self.app.focus.brain.ask(NoteHelp.awayRequest(shown), key: "away|\(paper.noteID)|\(run.gate.id)") { reply in
                            finish((reply?["line"] as? String).map { String($0.prefix(240)) } ?? plain)
                        }
                    }
                }
            }
        }
    }

    /// Open all: a task's tabs, files and mail, back.
    func openAll(_ key: String) {
        guard let paper = store?.paper(key) else { return }
        for item in paper.file.task {
            switch item.kind {
            case .tab, .mail: if let url = URL(string: item.target), ["http", "https", "message"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            case .file: NSWorkspace.shared.open(URL(fileURLWithPath: item.target))
            case .window: if let app = NotePlace.running(item.target) { app.activate() }
            }
        }
    }

    // MARK: Helpers that think: the chat AI, or the person's own coding AI

    /// Anything else asked: a run registered at once; then, on a page tied to a repository or a file in a checkout,
    /// the person's own coding AI in a worktree; else the chat AI on the note's place.
    private func ask(_ paper: PaperNote, _ text: String, asked: String, extra: String = "") {
        let models = NoteHelp.models(asked)
        let pick = models.first { !$0.holes }
        let run = begin(paper, asked: asked, step: "Starting", who: pick.map { "\(Self.petalWho) · \($0.name)" } ?? Self.petalWho)
        run.holes = models.first { $0.holes }
        run.restart = { [weak self] in
            guard let self, let paper = self.paper(paper.noteID) else { return }
            self.ask(paper, text, asked: asked, extra: extra)
        }
        let stick = desk?.here[paper.key].flatMap { paper.file.places.indices.contains($0) ? paper.file.places[$0] : nil } ?? paper.file.places.first
        if extra.isEmpty, let stick, let repo = NoteHelp.repository(url: stick.url) {
            return code(run, paper, text, slug: repo.slug, number: repo.number, file: nil, pick: pick)
        }
        if extra.isEmpty, let stick, stick.kind == .file || stick.kind == .passage, !stick.path.isEmpty {
            let path = stick.path
            return Self.checkouts { all in
                guard self.live(run) else { return }
                if let folder = NoteHelp.checkout(holding: path, among: all.map(\.path)) {
                    self.code(run, paper, text, slug: nil, number: nil, file: folder, pick: pick)
                } else {
                    self.think(run, paper, text, pick: pick, extra: extra)
                }
            }
        }
        think(run, paper, text, pick: pick, extra: extra)
    }

    /// @Petal: the chat AI with Petal's tools, on the note's own place (never what happens to be in front: a note
    /// away from its window waits for it), the notebook's cover read first.
    private func think(_ run: Run, _ paper: PaperNote, _ text: String, pick: NoteHelp.Model?, extra: String) {
        guard live(run) else { return }
        guard let provider = provider(for: pick) else { return ended(run, "Choose an AI in Petal's settings first (Claude Code or Codex).") }
        let paper = self.paper(run.noteID) ?? paper
        let anchor = NoteHelp.anchor(paper.file.places, here: desk?.here[paper.key])
        if case .away(let label) = anchor {
            run.awaitingPlace = true
            run.placedResume = { [weak self] in self?.think(run, paper, text, pick: pick, extra: extra) }
            write(run.noteID) { file in file.helper?.state = .waiting; file.helper?.step = "Waiting for \(label) to be in front" }
            return
        }
        run.awaitingPlace = false
        var raw = NoteHelp.Context()
        raw.ask = text
        raw.body = paper.file.body
        raw.notebook = paper.notebook
        raw.cover = mayRead(paper.notebook, from: paper) ? cover(of: paper.notebook)?.file.body ?? "" : ""
        raw.extra = extra
        if case .placed(let index) = anchor {
            raw.place = paper.file.places[index].words
            raw.quote = paper.file.places[index].quote
        }
        shielded(run, raw) { shown in
            self.launch(run, paper, prompt: shown.context.ask, kind: .petal, provider: provider, model: pick?.id ?? "",
                        brief: NoteHelp.brief(shown), folder: nil, finish: nil, placed: true)
        }
    }

    /// Layout placed notes: a run waiting for its note's place goes on once its note is on the window in front.
    func placedNow() {
        for run in runs.values where run.awaitingPlace && run.gate.live {
            guard let paper = paper(run.noteID), case .placed = NoteHelp.anchor(paper.file.places, here: desk?.here[paper.key]) else { continue }
            run.awaitingPlace = false
            run.placedResume?()
        }
    }

    /// A coding helper: the person's own Claude Code or Codex in their checkout, in the note's own worktree (made
    /// once, reused for its follow-ups), after Allow on the note once per project.
    private func code(_ run: Run, _ paper: PaperNote, _ text: String, slug: String?, number: Int?, file folder: String?, pick: NoteHelp.Model?) {
        Self.checkouts { all in
            guard self.live(run) else { return }
            var candidates = folder.map { [$0] } ?? slug.map { NoteHelp.checkouts(for: $0, among: all) } ?? []
            // "in ~/garden" picks among several: its whole path, exactly one.
            if candidates.count > 1, let named = NoteHelp.named(candidates, in: run.asked, home: NSHomeDirectory()) { candidates = [named] }
            guard let checkout = candidates.first else {
                return self.ended(run, "Petal couldn't find a checkout of \(slug ?? "this repository") in your home folder.")
            }
            guard candidates.count == 1 else {
                let names = candidates.map { ($0 as NSString).abbreviatingWithTildeInPath }
                return self.ended(run, "Which checkout: " + names.joined(separator: " or ") + "? Say “@Petal … in \(names[0])”.")
            }
            let remotes = all.first { $0.path == checkout }?.remotes ?? []
            let remote = slug.flatMap { NoteHelp.remote(for: $0, in: remotes) } ?? remotes.first { $0.name == "origin" }?.name ?? remotes.first?.name ?? ""
            guard let provider = self.provider(for: pick) else { return self.ended(run, "Choose an AI in Petal's settings first (Claude Code or Codex).") }
            run.who = pick?.name ?? provider.name
            let short = (checkout as NSString).abbreviatingWithTildeInPath
            let kind = "code:" + checkout
            self.working(run.noteID, step: "Asking to work in \(short)", asked: run.asked, who: run.who)
            // The note's helper owns the card, so Stop and the card's answer are this run's.
            let sticky = self.sticky(for: paper)
            run.sticky = sticky
            run.from = sticky.agent.messages.count + 1
            let already = self.app.config.strings("aiAllowed").contains(kind) || self.app.config.string("claudeAccess") == "full"
            self.app.assist.ask(kind, "\(provider.appName) wants to work in \(short)",
                                detail: "In a worktree of its own, on a new branch. It may commit, push and open a pull request.",
                                owner: sticky.id.uuidString) { allowed in
                guard self.live(run) else { return }
                guard allowed else { return self.ended(run, "Not allowed: nothing was changed in \(short).") }
                let always = self.app.config.strings("aiAllowed").contains(kind)
                let grant = always ? "always:" + kind : "reply"
                if !already { self.stamp(run.noteID, label: "ALLOWED · \(provider.name.uppercased()) · \(short.uppercased())", grant: grant) }
                // The authorization this run works under: taking it back stops it.
                run.gate.hold(grant)
                if always { run.gate.hold("always:" + kind) }
                self.working(run.noteID, step: "Worktree of \(short)", asked: run.asked, who: run.who)
                let kept = paper.file.worktree.flatMap { $0.checkout == checkout ? $0 : nil }
                let branch = kept?.branch ?? NoteHelp.branch(noteID: run.noteID, words: NoteHelp.spoken(run.asked))
                Self.worktree(checkout, noteID: run.noteID, branch: branch, remote: remote, pull: number) { tree, problem in
                    guard self.live(run) else { return }
                    guard let tree else { return self.ended(run, "Petal couldn't set up a worktree of \(short): \(problem ?? "git said no").") }
                    self.write(run.noteID) { $0.worktree = NoteHelp.Worktree(path: tree, branch: branch, checkout: checkout, remote: remote) }
                    var raw = NoteHelp.Context()
                    raw.ask = text
                    raw.body = paper.file.body
                    self.shielded(run, raw) { shown in
                        let from = number.map { "\(slug ?? "")'s #\($0) (fetched from \(remote))" } ?? ""
                        let prompt = NoteHelp.codeRequest(shown, checkout: short, tree: tree, branch: branch, from: from, finish: NoteHelp.finishLine(shown.context.ask))
                        run.finish = NoteHelp.finishLine(shown.context.ask)
                        self.launch(run, paper, prompt: prompt, kind: .code(folder: tree), provider: provider, model: pick?.id ?? "",
                                    brief: NoteHelp.codeBrief(shown), folder: tree, finish: run.finish, placed: false)
                    }
                }
            }
        }
    }

    /// "check this against @Notebook": the notebook's notes read (never a Private notebook's from outside it), and
    /// contradictions flagged as questions.
    private func check(_ paper: PaperNote, against name: String, asked: String) {
        guard let book = store?.notebook(name) else { return say(paper.noteID, "There's no notebook called “\(name)”.", asked: asked) }
        guard mayRead(book.name, from: paper) else { return say(paper.noteID, "That notebook is private: only a note inside it can read it.", asked: asked) }
        let notes = (store?.notes ?? []).filter { $0.notebook == book.name && $0.version == nil && $0.noteID != paper.noteID }.prefix(40)
        let text = notes.map { "## " + $0.file.title + "\n" + $0.file.body }.joined(separator: "\n\n")
        ask(paper, "Check this note against my notebook \(book.name), below. Flag anything that contradicts it, each as a short question (\"Is it … or …?\"). If nothing does, say so in one line.",
            asked: asked, extra: "The notebook \(book.name):\n" + String(text.prefix(30_000)))
    }

    // MARK: Running

    private func provider(for pick: NoteHelp.Model?) -> Provider? {
        let installed = app.providers.filter { app.paths[$0] != nil }
        if let pick, let wanted = Provider(rawValue: pick.provider.rawValue), installed.contains(wanted) { return wanted }
        return app.chatProvider.flatMap { installed.contains($0) ? $0 : nil } ?? installed.first
    }

    /// The note's own helper agent (one per note while Petal runs): its tools look at the note's place. A Private
    /// notebook's is marked so (and checked again when shown): it never shows in the AI button's previews.
    private func sticky(for paper: PaperNote) -> StickyNote {
        if let kept = mainSticky(paper.noteID) {
            kept.secret = isPrivate(paper)
            return kept
        }
        let sticky = StickyNote()
        sticky.paper = paper.noteID
        sticky.secret = isPrivate(paper)
        sticky.agent.keeps = false
        app.claude.notes.append(sticky)
        return sticky
    }

    private func mainSticky(_ noteID: String) -> StickyNote? { app.claude.notes.first { $0.paper == noteID && !$0.reviewer } }

    private func drop(_ sticky: StickyNote) {
        guard !sticky.agent.running else { return }
        app.claude.notes.removeAll { $0 === sticky }
    }

    /// Whether a helper of this note may show in the AI button's previews: never one in a Private notebook.
    func previewable(_ sticky: StickyNote) -> Bool {
        guard let noteID = sticky.paper else { return true }
        if sticky.secret { return false }
        return paper(noteID).map { !isPrivate($0) } ?? false
    }

    private func isPrivate(_ paper: PaperNote) -> Bool { cover(of: paper.notebook)?.file.coverPrivate == true }

    /// Where the note is now, as its helper's tools see it (NotePlace): the window in front when the note is on it,
    /// its tab, or all of its app; nil when it isn't placed on a window now.
    private func place(of paper: PaperNote) -> NotePlace? {
        guard let desk, let scene = desk.scene, let index = desk.here[paper.key], paper.file.places.indices.contains(index) else { return nil }
        let stick = paper.file.places[index]
        let scope: NoteScope = stick.kind == .app ? .app : (stick.kind == .tab || stick.kind == .passage) && scene.tab != nil ? .tab : .window
        let name = NSRunningApplication(processIdentifier: scene.pid)?.localizedName ?? stick.appName
        return NotePlace(pid: scene.pid, app: scene.app, appName: name, window: scene.window, title: scene.title,
                         mode: desk.modeID(desktop: scene.desktop), desktop: scene.desktop, scope: scope, tab: scope == .tab ? scene.tab : nil)
    }

    /// The run's agent starts, with what it was told already shielded.
    private func launch(_ run: Run, _ paper: PaperNote, prompt: String, kind: Run.Kind, provider: Provider, model: String, brief: String,
                        folder: String?, finish: String?, placed: Bool, sticky given: StickyNote? = nil) {
        guard live(run) else { return }
        let sticky = given ?? run.sticky ?? sticky(for: paper)
        let agent = sticky.agent
        // Only the note's own place: when it isn't on a window now, none (the brief says not to look at what's in front).
        agent.place = placed ? place(of: paper) : nil
        agent.helperBrief = brief
        agent.folder = folder.map { URL(fileURLWithPath: $0) }
        agent.pinned = (provider, model)
        run.sticky = sticky
        run.kind = kind
        run.from = agent.messages.count
        run.launched = true
        working(run.noteID, step: "Starting", asked: run.asked, who: run.who)
        agent.send(prompt)
    }

    /// The note says a helper is at work (`helper: working`).
    private func working(_ noteID: String, step: String, asked: String, who: String = NoteHelpers.petalWho) {
        let mac = self.mac
        stepWritten[noteID] = Date()
        write(noteID) { $0.helper = NoteHelp.Helper(state: .working, who: who, step: step, asked: asked, mac: mac, at: Date()) }
    }

    /// A step: shown on the paper at once (its agent's activity), written into the note now and then.
    func stepped(_ sticky: StickyNote) {
        guard let noteID = sticky.paper, let run = runs[noteID], run.sticky === sticky, run.gate.live,
              Date().timeIntervalSince(stepWritten[noteID] ?? .distantPast) > 8 else { return }
        // Being written in: the paper shows the step live; nothing is written under the person's typing.
        if let key = paper(noteID)?.key, desk?.keyboard == key { return }
        stepWritten[noteID] = Date()
        let step = sticky.agent.activity
        write(noteID) { file in if file.helper?.state == .working { file.helper?.step = step } }
    }

    /// A helper's turn ended (ClaudePanel.finished). Its gate says what that means: still asking the person, paused
    /// (kept, with Go on), stopped (nothing), failed (said, nothing advances), or succeeded: its answer becomes the
    /// note's ink, its steps go on the back, and only then a reviewer or a chain's next step may run.
    func finished(_ sticky: StickyNote) {
        // Only the run that launched this turn: an older run's turn ending while a new one is still being set up
        // (the same agent) is nothing to it.
        guard let noteID = sticky.paper, let run = runs[noteID], run.sticky === sticky, run.launched else { return }
        let agent = sticky.agent
        let messages = Array(agent.messages.dropFirst(min(run.from, agent.messages.count)))
        let reply = messages.last { $0.kind == .claude }?.text
        let ending = run.gate.ending(answered: reply != nil, asking: !agent.pendingAsk.isEmpty)
        switch ending {
        case .waitingOnPerson:
            write(noteID) { $0.helper?.state = .waiting; $0.helper?.step = "Waiting for you: Allow or Don't" }
            return
        case .paused:
            write(noteID) { $0.helper?.state = .waiting; $0.helper?.step = "Paused" }
            return
        case .stopped:
            return
        case .failed:
            return ended(run, messages.last { $0.kind == .error }?.text ?? "It stopped without an answer.")
        case .succeeded:
            break
        }
        guard run.gate.end(.succeeded), let answer = reply else { return }
        runs[noteID] = nil
        let steps = messages.filter { $0.kind == .step }.map(\.text)
        if case .holes = run.kind {
            let ink = NoteHelp.Ink(who: run.who, text: NoteHelp.inkText(answer), objections: NoteHelp.objections(in: answer))
            let mac = self.mac
            drop(sticky)
            write(noteID) { file in
                file.ink = file.ink.filter { $0.objections == nil } + [ink]
                file.steps = file.steps + steps.map { "\(run.who): \($0)" }
                file.helper = NoteHelp.Helper(state: .done, who: run.who, step: "", asked: run.asked, mac: mac, at: Date())
            }
            return
        }
        var ink = NoteHelp.Ink(who: run.who, text: NoteHelp.inkText(answer))
        if case .code = run.kind {
            ink.proof = NoteHelp.proof(in: answer)
            ink.link = NoteHelp.pullRequest(in: answer) ?? ""
            if ink.proof.isEmpty, let finish = run.finish { ink.proof = [String(finish.prefix(18))] }
        }
        // The next answer replaces the last: one block of ink (a second opinion's comes after it).
        self.answer(noteID, [ink], who: run.who, asked: run.asked, steps: steps)
        if let holes = run.holes, let paper = paper(noteID) { secondOpinion(paper, holes, after: run, answer: answer) }
    }

    /// "and have <model> look for holes": a run of its own, after the first succeeded, reading its answer (and in a
    /// worktree, the change) and listing objections as its own ink with a count.
    private func secondOpinion(_ paper: PaperNote, _ model: NoteHelp.Model, after first: Run, answer: String) {
        guard let provider = provider(for: model) else { return }
        nextRun += 1
        let who = model.name.isEmpty ? provider.name : model.name
        let run = Run(id: nextRun, noteID: paper.noteID, asked: first.asked, who: who)
        runs[paper.noteID] = run
        var tree: String?
        if case .code(let folder) = first.kind { tree = folder }
        let reviewer = StickyNote()
        reviewer.paper = paper.noteID
        reviewer.reviewer = true
        reviewer.secret = isPrivate(paper)
        reviewer.agent.keeps = false
        app.claude.notes.append(reviewer)
        run.sticky = reviewer
        working(paper.noteID, step: "Looking for holes", asked: first.asked, who: who)
        var raw = NoteHelp.Context()
        raw.body = paper.file.body
        raw.answer = answer
        shielded(run, raw) { shown in
            self.launch(run, paper, prompt: NoteHelp.reviewRequest(shown, tree: tree), kind: .holes(folder: tree), provider: provider, model: model.id,
                        brief: NoteHelp.reviewBrief(shown), folder: tree, finish: nil, placed: false, sticky: reviewer)
        }
    }

    // MARK: Cards and stamps on the note

    /// Whether `owner` (a card's) is a note's helper.
    func owns(_ owner: String) -> Bool { app.claude.note(withID: owner)?.paper != nil }

    /// The note whose helper asks shows (open) so its card can be answered there.
    func asking(_ owner: String) {
        guard let noteID = app.claude.note(withID: owner)?.paper else { return }
        summon(noteID, open: true)
        write(noteID) { file in if file.helper != nil { file.helper?.state = .waiting; file.helper?.step = "Waiting for you" } }
    }

    /// The card a note's helper asks with (Allow, Don't, Buy): Assist's question, when it's that helper's.
    func card(_ noteID: String) -> Assist.Request? {
        guard let request = app.assist.pending, let owner = request.owner, app.claude.note(withID: owner)?.paper == noteID else { return nil }
        return request
    }

    /// A question was answered on a helper's card: allowed, a stamp on the note's back, held by the run asking.
    func answered(_ request: Assist.Request, _ choice: Assist.Choice) {
        guard choice != .no, let owner = request.owner, let noteID = app.claude.note(withID: owner)?.paper else { return }
        // The coding helper's own Allow is stamped by its run.
        guard !request.kind.hasPrefix("code:") else { return }
        let always = choice == .always && !request.every
        let label = (always ? "ALWAYS · " : "ALLOWED · ") + request.title.uppercased()
        stamp(noteID, label: String(label.prefix(48)), grant: always ? "always:" + request.kind : "reply")
        write(noteID) { file in if file.helper?.state == .waiting { file.helper?.state = .working } }
    }

    /// Claude asked to run something it may not (its denials): Allow on the note re-runs with per-part rules, held by
    /// the run.
    func allowDenials(_ noteID: String) {
        guard let run = runs[noteID], let sticky = run.sticky, run.gate.live else { return }
        let agent = sticky.agent
        let rules = agent.pendingAsk.flatMap(\.rules)
        let label = agent.pendingAsk.map(\.label).first.map { String($0.prefix(30)) } ?? "a command"
        stamp(noteID, label: "ALLOWED · " + label.uppercased(), grant: "rules:" + rules.joined(separator: "\n"))
        write(noteID) { file in file.helper?.state = .working; file.helper?.step = "Allowed" }
        agent.allow()
    }

    func denyDenials(_ noteID: String) {
        guard let run = runs[noteID], let sticky = run.sticky else { return }
        sticky.agent.deny()
        ended(run, "Not allowed: it stopped there.")
    }

    private func stamp(_ noteID: String, label: String, grant: String) {
        let stamp = NoteHelp.Stamp(label: label, grant: grant, mac: mac)
        runs[noteID]?.gate.hold(grant)
        write(noteID) { file in if !file.stamps.contains(stamp) { file.stamps.append(stamp) } }
    }

    /// Tapping a stamp takes its grant back (on the Mac it was given on) and the stamp goes; a run working under it
    /// stops (its gate holds the grant).
    func revoke(_ noteID: String, _ stamp: NoteHelp.Stamp) {
        guard stamp.mac == mac else { desk?.tell("That was allowed on another Mac: take it back there."); return }
        switch stamp.parsed {
        case .always(let kind):
            app.config.set("aiAllowed", app.config.strings("aiAllowed").filter { $0 != kind })
        case .rules(let rules):
            mainSticky(noteID)?.agent.revoke(rules)
        case .project(let id):
            AgentGrants.shared.remove(id)
        case .reply:
            if let sticky = mainSticky(noteID) { app.assist.computer.end(sticky.id.uuidString) }
        }
        if let run = runs[noteID], run.gate.grants.contains(stamp.grant) {
            halt(run)
            write(noteID) { file in
                file.helper = nil
                file.ink = [NoteHelp.Ink(who: run.who, text: "Stopped: you took back what it was allowed.")]
            }
        }
        write(noteID) { $0.stamps.removeAll { $0 == stamp } }
    }

    // MARK: Showing a note

    /// Shows a note now: on its place when that's in front, else on the Desktop showing (until it's put away).
    func summon(_ noteID: String, open: Bool) {
        guard let desk, let paper = paper(noteID) else { return }
        summoned.insert(paper.key)
        desk.faces[paper.key] = open ? .open : (desk.faces[paper.key] ?? .folded)
        desk.summoned()
    }

    /// A summoned note was put away (or moved): it no longer stays out.
    func dismissed(_ key: String) { summoned.remove(key) }

    func rekeyed(_ old: String, _ new: String) {
        if summoned.remove(old) != nil { summoned.insert(new) }
    }

    /// A note picked from the AI button's preview, or a quick question's source chip.
    func show(_ sticky: StickyNote) { if let noteID = sticky.paper { summon(noteID, open: true) } }

    // MARK: The clock: coming back, watchers, chains, morning notes, merged worktrees

    private func tick() {
        guard let desk, desk.on else { return }
        let now = Date()
        for paper in desk.store.notes where paper.version == nil {
            let file = paper.file
            if let back = file.back, back <= now {
                summon(paper.noteID, open: false)
                write(paper.noteID) { $0.back = nil }
            }
            if let watch = file.watch, watch.mac == mac, NoteHelp.due(watch, now: now) { look(paper.noteID) }
            if let chain = file.chain, chain.ready(mac: mac, after: self.paper(chain.after)?.file.helper) { fire(paper) }
            if file.cover, let morning = file.morning, morning.mac == mac { leaveMorning(paper, at: morning.time, now: now) }
            if file.worktree != nil, let link = file.ink.first(where: { !$0.link.isEmpty })?.link, runs[paper.noteID] == nil,
               now.timeIntervalSince(mergeChecked[paper.noteID] ?? .distantPast) > 600 {
                mergeChecked[paper.noteID] = now
                Self.merged(link) { merged in
                    if merged, let paper = self.paper(paper.noteID), paper.file.worktree != nil, self.runs[paper.noteID] == nil {
                        self.removeWorktree(paper, why: "its pull request merged", asked: paper.file.helper?.asked ?? "")
                    }
                }
            }
        }
    }

    /// A chain's note is done: `fired` is written first (landed, on this Mac only), then its helper is asked through
    /// `ask` like any run (a coding page gets its worktree and its project's Allow), so a restart or a sync never runs
    /// it twice.
    private func fire(_ paper: PaperNote) {
        guard var chain = paper.file.chain, runs[paper.noteID] == nil, !looking.contains("chain:" + paper.noteID) else { return }
        looking.insert("chain:" + paper.noteID)
        chain.fired = Date()
        write(paper.noteID, { $0.chain = chain }) { landed in
            self.looking.remove("chain:" + paper.noteID)
            guard landed, let now = self.paper(paper.noteID) else { return }
            let asked = "when @" + chain.afterTitle + " is done, " + chain.ask
            self.ask(now, chain.ask + " (\(chain.afterTitle) is done; read it with petal_note_read, its helper's answer included.)", asked: asked)
        }
    }

    /// A notebook's morning note, once a day at its time, written by Petal (`from: petal`) and left on the Desktop
    /// showing: what its helpers did since yesterday, its watchers' numbers, what comes back today. No AI.
    private func leaveMorning(_ cover: PaperNote, at time: String, now: Date) {
        guard let clock = NoteHelp.clock(time), let due = Calendar.current.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: now),
              now >= due, now.timeIntervalSince(due) < 6 * 3600 else { return }
        let day = NoteFile.stamp(Calendar.current.startOfDay(for: now)).prefix(10)
        let stable = "morning-" + NoteShelf.pictureFolder(id: cover.notebook).suffix(12) + "-" + day
        guard !mornings.contains(stable), store?.notes.contains(where: { $0.noteID == stable }) == false else { return }
        mornings.insert(stable)
        let notes = (store?.notes ?? []).filter { $0.notebook == cover.notebook && !$0.file.cover && $0.version == nil }
        let since = now.addingTimeInterval(-86400)
        var lines: [String] = []
        for note in notes {
            if let helper = note.file.helper, helper.state == .done, let at = helper.at, at > since, let ink = note.file.ink.first {
                lines.append("\(note.file.title): " + (ink.text.components(separatedBy: CharacterSet(charactersIn: ".\n")).first ?? ink.text) + ".")
            }
            if let watch = note.file.watch, !watch.last.isEmpty { lines.append("\(note.file.title): \(watch.last)" + (watch.history.first.map { ", was \($0)" } ?? "") + ".") }
            if let back = note.file.back, Calendar.current.isDate(back, inSameDayAs: now) { lines.append("\(note.file.title) comes back at " + NoteHelp.backLine(back, now: now).components(separatedBy: " ").last! + ".") }
        }
        if lines.isEmpty { lines.append("Nothing needs you.") }
        var file = NoteFile(id: stable, body: lines.prefix(6).joined(separator: " "))
        file.fromPetal = true
        desk?.resolveDesktop { number in
            if let place = NoteShelf.desktopAnchor(number: number, mode: self.desk?.modeID(desktop: number) ?? "") { file.places = [place] }
            self.store?.make(file, in: cover.notebook) { made in if made == nil { self.mornings.remove(stable) } }
        }
    }

    /// A watcher looks once: the page fetched plainly (bounded), its value found with no AI when it can be; the AI
    /// only when it can't, or when the line is crossed. Nothing is ever bought. What it finds is written back only
    /// into the look's own fields, and only while the watcher is the one it began under (`gen`: a pause, a stop or a
    /// new watcher meanwhile keeps it out).
    func look(_ noteID: String) {
        guard let paper = paper(noteID), let watch = paper.file.watch, watch.mac == mac, !watch.paused, !looking.contains(noteID),
              let url = URL(string: watch.url), ["http", "https"].contains(url.scheme ?? "") else { return }
        looking.insert(noteID)
        let gen = watch.gen
        Task.detached {
            let data = await Sites.get(url, .page)
            let html = data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) } ?? ""
            let text = NoteHelp.pageText(html)
            await MainActor.run { self.read(noteID, gen: gen, text: text) }
        }
    }

    /// Whether a look begun under `gen` may still go on.
    private func current(_ noteID: String, _ gen: Int) -> NoteHelp.Watch? {
        guard let watch = paper(noteID)?.file.watch, watch.gen == gen, !watch.paused else { return nil }
        return watch
    }

    private func read(_ noteID: String, gen: Int, text: String) {
        guard let watch = current(noteID, gen) else { looking.remove(noteID); return }
        let line = NoteHelp.line(watch.line)
        let last = NoteHelp.amounts(watch.last, needCurrency: false).first?.value
        let finish = { (value: Double?, hint: String?, said: String?) in
            self.looking.remove(noteID)
            guard self.current(noteID, gen) != nil else { return }
            let shown = value.map { NoteHelp.format($0, currency: line?.currency ?? "", thousands: line?.thousands ?? false) }
            let crossed = value.map { NoteHelp.crossed($0, line: watch.line) } ?? false
            let now = Date()
            self.write(noteID, { file in
                var current = file.watch
                guard NoteHelp.applyLook(&current, gen: gen, shown: shown, hint: hint, crossed: crossed, at: now) != nil else { return }
                file.watch = current
            }) { landed in
                // Said only when this look's own write newly crossed the line.
                guard landed, crossed, let shown, let file = self.paper(noteID)?.file, let now = file.watch, now.gen == gen, now.last == shown,
                      file.ink.first?.text.contains(shown) != true else { return }
                let words = said ?? "Now \(shown): \(watch.line). Petal never buys by itself: say “@Petal buy it” and you'll see a Buy card first."
                self.answer(noteID, [NoteHelp.Ink(who: Self.petalWho + " · " + NoteHelp.dayLabel(Date(), now: Date()), text: words)],
                            who: Self.petalWho, asked: file.helper?.asked ?? "")
                self.summon(noteID, open: true)
            }
        }
        // The page's words go to the quick AI only shielded (rule B).
        var raw = NoteHelp.Context()
        raw.extra = text
        if !text.isEmpty, let found = NoteHelp.pick(text, line: watch.line, hint: watch.hint, last: last) {
            let hint = NoteHelp.hint(before: found, in: text)
            guard NoteHelp.crossed(found.value, line: watch.line), !watch.hit, app.focus.brain.enabled else { return finish(found.value, hint, nil) }
            // Crossed: the quick AI checks it's really the thing's price before the note says so.
            return Self.shield(raw) { shown in
                guard let shown, self.current(noteID, gen) != nil else { self.looking.remove(noteID); return }
                self.app.focus.brain.ask(NoteHelp.watchConfirm(shown, line: watch.line, found: found.text, hint: hint), key: "watch|\(noteID)|\(gen)|\(found.text)|\(Date().timeIntervalSince1970)") { reply in
                    if reply?["yes"] as? Bool == false { return finish(nil, nil, nil) }
                    finish(found.value, hint, (reply?["say"] as? String).map { String($0.prefix(240)) })
                }
            }
        }
        guard !text.isEmpty, app.focus.brain.enabled else { return finish(nil, nil, nil) }
        // Couldn't tell plainly: the quick AI finds it once, and the words before it for next time.
        Self.shield(raw) { shown in
            guard let shown, self.current(noteID, gen) != nil else { self.looking.remove(noteID); return }
            self.app.focus.brain.ask(NoteHelp.watchFind(shown, line: watch.line, last: watch.last), key: "watchfind|\(noteID)|\(gen)|\(Date().timeIntervalSince1970)") { reply in
                finish((reply?["value"] as? NSNumber)?.doubleValue, reply?["before"] as? String, nil)
            }
        }
    }

    // MARK: Worktrees

    /// The note's worktree goes (its PR merged, or the person said it's done), and the note says so. One with changes
    /// not committed stays, and the note says that instead.
    private func removeWorktree(_ paper: PaperNote, why: String, asked: String) {
        guard let tree = paper.file.worktree else { return }
        let short = (tree.checkout as NSString).abbreviatingWithTildeInPath
        DispatchQueue.global(qos: .utility).async {
            let gone = Self.git(tree.checkout, ["worktree", "remove", tree.path])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard gone.status == 0 || !FileManager.default.fileExists(atPath: tree.path) else {
                        return self.say(paper.noteID, "The worktree of \(short) has changes not committed, so Petal left it at \(tree.path).", asked: asked)
                    }
                    self.write(paper.noteID) { file in
                        file.worktree = nil
                        file.ink = file.ink.filter { $0.who != Self.petalWho } + [NoteHelp.Ink(who: Self.petalWho, text: "Removed the worktree of \(short): \(why). The branch \(tree.branch) stays.")]
                    }
                }
            }
        }
    }

    /// Whether a pull request merged (gh, off the main thread).
    static func merged(_ link: String, _ done: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh", "pr", "view", link, "--json", "state", "-q", ".state"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            environment["GH_PROMPT_DISABLED"] = "1"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var state = ""
            if (try? process.run()) != nil {
                state = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                process.waitUntilExit()
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(state == "MERGED") } }
        }
    }

    // MARK: Reading the person's things off the main thread

    /// The person's checkouts: the home folder's git repositories (and one level into ~/Projects, ~/Developer and
    /// ~/Code), each with its remotes by name, read from their own .git/config (no git run). Off the main thread.
    static func checkouts(_ done: @escaping @MainActor ([(path: String, remotes: [(name: String, url: String)])]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let home = FileManager.default.homeDirectoryForCurrentUser
            var folders: [URL] = []
            for base in [home, home.appending(path: "Projects"), home.appending(path: "Developer"), home.appending(path: "Code")] {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
                for name in names where !name.hasPrefix(".") && !["Library", "Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies"].contains(name) {
                    folders.append(base.appending(path: name))
                }
            }
            var found: [(path: String, remotes: [(name: String, url: String)])] = []
            for folder in folders {
                var isDirectory: ObjCBool = false
                // A main checkout only: its .git is a folder (a worktree's is a file).
                guard FileManager.default.fileExists(atPath: folder.appending(path: ".git").path, isDirectory: &isDirectory), isDirectory.boolValue,
                      let config = try? String(contentsOf: folder.appending(path: ".git/config"), encoding: .utf8) else { continue }
                found.append((NoteHelp.standard(folder.path), NoteHelp.remotes(config: config)))
            }
            nonisolated(unsafe) let result = found
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    /// The note's worktree of `checkout` (one per note, in Petal's own folder, never inside the person's checkout),
    /// reused when it's there. A new one starts from the pull request's head fetched from `remote` (the remote that is
    /// that repository; when that fetch fails, nothing is made: never the default branch instead), or else from
    /// `remote`'s default branch. Off the main thread.
    static func worktree(_ checkout: String, noteID: String, branch: String, remote: String, pull: Int?, _ done: @escaping @MainActor (String?, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tree = Config.supportFolder.appending(path: "Worktrees").appending(path: NoteHelp.worktreeName(checkout: checkout, noteID: noteID)).path
            let finish = { (path: String?, problem: String?) in DispatchQueue.main.async { MainActor.assumeIsolated { done(path, problem) } } }
            // Its follow-ups work where it did.
            if FileManager.default.fileExists(atPath: tree + "/.git") { return finish(tree, nil) }
            try? FileManager.default.createDirectory(atPath: (tree as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            var base: String
            if let pull {
                guard !remote.isEmpty, git(checkout, ["fetch", "--quiet", remote, "pull/\(pull)/head"]).status == 0 else {
                    return finish(nil, "couldn't fetch #\(pull) from \(remote.isEmpty ? "its remote" : remote)")
                }
                base = "FETCH_HEAD"
            } else {
                base = "HEAD"
                if !remote.isEmpty, git(checkout, ["fetch", "--quiet", remote]).status == 0,
                   git(checkout, ["rev-parse", "--verify", "--quiet", "\(remote)/HEAD"]).status == 0 { base = "\(remote)/HEAD" }
            }
            // The branch may be left from a worktree removed earlier: it's the note's own, so it's used again.
            let exists = git(checkout, ["rev-parse", "--verify", "--quiet", "refs/heads/" + branch]).status == 0
            let made = exists ? git(checkout, ["worktree", "add", tree, branch]) : git(checkout, ["worktree", "add", "-b", branch, tree, base])
            finish(made.status == 0 ? tree : nil, made.status == 0 ? nil : String(made.output.suffix(200)))
        }
    }

    nonisolated static func git(_ folder: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "git couldn't start") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The tabs of a browser's front window (title and address), for putting a task away; none for another app or a
    /// browser Petal may not script.
    nonisolated static func windowTabs(_ bundle: String) -> [(title: String, url: String)] {
        guard let kind = Browsers.kind(bundle), Browsers.access(bundle) == .allowed else { return [] }
        guard kind != .gecko else { return [] }
        let tab = "tabs"
        let title = kind == .safari ? "name" : "title"
        let source = """
        set out to ""
        tell application id "\(bundle)"
        repeat with t in \(tab) of front window
        set out to out & (\(title) of t) & tab & (URL of t) & linefeed
        end repeat
        end tell
        return out
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue ?? ""
        return result.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2, parts[1].hasPrefix("http") else { return nil }
            return (parts[0], parts[1])
        }.prefix(20).map { $0 }
    }

    /// Mail's selected message: its subject and a link that opens it.
    nonisolated static func selectedMail() -> (subject: String, url: String)? {
        let source = """
        tell application id "com.apple.mail"
        set m to item 1 of (get selection)
        return (subject of m) & tab & (message id of m)
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else { return nil }
        let parts = result.components(separatedBy: "\t")
        guard parts.count == 2 else { return nil }
        let id = parts[1].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? parts[1]
        return (parts[0], "message://%3C\(id)%3E")
    }

    nonisolated static func windowTitle(_ pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String
    }

    // MARK: Notes by name

    /// A notebook's cover.
    func cover(of notebook: String) -> PaperNote? {
        guard let key = store?.notebook(notebook)?.cover else { return nil }
        return store?.paper(key)
    }

    /// Whether a note may read `notebook`: always its own; a Private one never from outside it.
    func mayRead(_ notebook: String, from paper: PaperNote?) -> Bool {
        guard let cover = cover(of: notebook), cover.file.coverPrivate else { return true }
        return paper?.notebook == notebook
    }

    /// The one note titled `name` (never a guess between two), not in a Private notebook the asking note isn't in.
    func note(named name: String, from paper: PaperNote) -> PaperNote? {
        let found = (store?.notes ?? []).filter {
            $0.version == nil && $0.file.title.caseInsensitiveCompare(name) == .orderedSame && mayRead($0.notebook, from: paper)
        }
        return found.count == 1 ? found[0] : nil
    }

    /// The page a note is on: its tab's or sentence's address.
    private func page(of paper: PaperNote) -> String? {
        let places = paper.file.places
        let index = desk?.here[paper.key]
        let ordered = (index.flatMap { places.indices.contains($0) ? [places[$0]] : nil } ?? []) + places
        return ordered.first { ($0.kind == .tab || $0.kind == .passage) && $0.url.hasPrefix("http") }?.url
    }

    /// What the @ menu offers: notes and notebooks by name (a Private notebook's only inside it).
    func names(for key: String) -> (notes: [String], notebooks: [String], place: String) {
        guard let store, let desk else { return ([], [], "") }
        let paper = store.paper(key)
        let notes = store.notes.filter { $0.version == nil && $0.key != key && !$0.file.cover && mayRead($0.notebook, from: paper) }
            .map(\.file.title).filter { !$0.isEmpty }
        let books = store.notebooks.map(\.name).filter { mayRead($0, from: paper) }
        return (Array(Set(notes)).sorted(), books, paper.map { NoteText.site(desk.letterhead($0).place) } ?? "")
    }
}

/// A note a chat's answer used (a quick question's source chip).
struct NoteSource: Equatable, Identifiable {
    let noteID: String
    let title: String
    var id: String { noteID }
}
