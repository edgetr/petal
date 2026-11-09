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
/// Two rules hold it together, each one that nothing can go around:
/// - **Every helper run is one `RunToken`**, made before any setup and carried by everything the run starts:
///   Brain's queue, the chat's waiting queue, each git step and each process are admitted only while it runs and
///   end when it's paused or stopped. Every Stop (the note's, the AI button's preview, the pointer's) goes through
///   `stop`; a stamp taken back cancels a run holding it (a run holds every authorization its note was given); only
///   the agent's explicit successful outcome finishes a run, and only a finished run advances anything.
/// - **What a helper tells an AI is `Shielded`**, a type only NoteShield makes (redacted whole, places filtered for
///   private apps first); `Agent.send`, Brain's helper calls and every prompt builder take nothing else.
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

    /// One helper run on a note: its token, and what it needs once its agent answers.
    @MainActor @Observable
    final class Run {
        enum Kind: Equatable { case petal, code(folder: String), holes(folder: String?), quick }
        let token: RunToken
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
        /// What a coding helper's reviewer and follow-ups read: the note's worktree.
        var tree: String?
        /// Waiting for the note's own place to be in front (never looking at whatever else is), and what goes on then.
        var awaitingPlace = false
        @ObservationIgnored var placedResume: (() -> Void)?
        /// Its agent was started (a turn sent): Go on carries that session on; before it, the request begins again.
        var launched = false
        /// Go on for a run paused before its agent started: the request is begun again.
        @ObservationIgnored var restart: (() -> Void)?

        init(token: RunToken, noteID: String, asked: String, who: String) {
            self.token = token
            self.noteID = noteID
            self.asked = asked
            self.who = who
        }

        var paused: Bool { token.paused }
    }

    private(set) var runs: [String: Run] = [:]
    /// Every run's token by its note, and every watcher look's: starting one cancels the one before; taking back a
    /// grant cancels every run holding it, whichever note it's on.
    @ObservationIgnored private let tokens = TokenTable()
    @ObservationIgnored private let looks = TokenTable()
    /// The places each running helper's note had when it was last told its place: a change is followed.
    @ObservationIgnored private var placesSeen: [String: [NoteStick]] = [:]
    /// Notes summoned to the screen (coming back, a watcher's hit, a source chip): shown on their place, or on the
    /// Desktop showing when their place isn't open, until the person puts them away.
    private(set) var summoned: Set<String> = []
    /// Morning notes made this run, by their id: never made twice while the file lands.
    @ObservationIgnored private var mornings: Set<String> = []
    /// Watchers looking now (by note id): one look at a time each.
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

    /// Changes a note's front matter (or a cover's memory, `touch`) through its session, behind any save the
    /// person's editor has waiting (never under typing not saved), as Petal's own change: in memory at once, so the
    /// editor's next save is made on it (NoteShelf.rebase: a change of metadata only never makes a conflict with the
    /// person's words). One at a time per note. `done`: whether it landed.
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
        let made = desk.store.change(paper.key, touch: touch, edit: { file in for job in waiting { job.edit(&file) } }) { outcome in
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

    /// A run that failed (a refusal, a launch error, a guard, nothing found): its reason as failure ink on the paper
    /// and `helper.state = failed`, reported once through its token (nothing waiting on it moves).
    private func fail(_ run: Run, _ reason: String) {
        guard runs[run.noteID] === run, run.token.complete(.failed(reason)) else { return }
        runs[run.noteID] = nil
        tokens.finish(run.noteID, run.token)
        if let sticky = run.sticky, sticky.reviewer { drop(sticky) }
        let mac = self.mac
        write(run.noteID) { file in
            file.ink = [NoteHelp.Ink(who: run.who + " · couldn't finish", text: reason)]
            file.helper = NoteHelp.Helper(state: .failed, who: run.who, step: reason, asked: run.asked, mac: mac, at: Date())
        }
    }

    // MARK: Runs (rule A)

    /// A run, registered before anything is set up. It holds every grant its note was given on this Mac (follow-ups
    /// use them too), so taking any of them back stops it. What was running on the note before is stopped first.
    private func begin(_ paper: PaperNote, asked: String, step: String, who: String = NoteHelpers.petalWho) -> Run {
        if let old = runs[paper.noteID] { halt(old) }
        let run = Run(token: tokens.start(paper.noteID), noteID: paper.noteID, asked: asked, who: who)
        for stamp in paper.file.stamps where stamp.mac == mac { run.token.hold(stamp.grant) }
        runs[paper.noteID] = run
        working(paper.noteID, step: step, asked: asked, who: who)
        return run
    }

    /// Whether a continuation of `run` may go on: it's still the note's run, and its token admits.
    private func live(_ run: Run) -> Bool { runs[run.noteID] === run && run.token.admits }

    /// Stops a run where it is: its token cancelled (its processes ended, nothing of it admitted again), its card
    /// answered Don't, its turn still waiting withdrawn.
    private func halt(_ run: Run) {
        run.token.complete(.stopped)
        tokens.finish(run.noteID, run.token)
        if runs[run.noteID] === run { runs[run.noteID] = nil }
        if let sticky = run.sticky {
            app.assist.decline(owner: sticky.id.uuidString)
            _ = sticky.agent.withdrawWaiting()
            if sticky.agent.running { sticky.agent.stop() }
            if sticky.reviewer { drop(sticky) }
        }
        app.focus.brain.resume()
    }

    /// A run stopped (its turn interrupted, its chain's start not recorded): ended as stopped, and the note says
    /// no helper is at work.
    private func stopped(_ run: Run, saying words: String? = nil) {
        guard runs[run.noteID] === run else { return }
        halt(run)
        write(run.noteID) { file in
            file.helper = nil
            if let words { file.ink = [NoteHelp.Ink(who: run.who, text: words)] }
        }
    }

    /// Stop, wherever it's pressed (the note, the AI button's preview, the pointer's Stop): the run ends where it is,
    /// and says so. Nothing waiting on it moves.
    func stop(_ noteID: String) {
        looks.cancel(noteID)
        if let run = runs[noteID] {
            halt(run)
            write(noteID) { file in
                file.helper = nil
                if run.kind != .quick { file.ink = [NoteHelp.Ink(who: run.who, text: "Stopped.")] }
            }
            return
        }
        // No run here (a chain waiting, or a helper left at work by a Petal that quit): its waiting ends.
        if paper(noteID)?.file.helper?.state != .done { write(noteID) { $0.helper = nil; $0.chain = nil } }
    }

    /// Pause: the run's token pauses (its processes end; nothing of it is admitted) and it stays paused; Go on (or
    /// Return on a line) carries it on. A watcher's Pause pauses its looks: a new id, so a look under way writes
    /// nothing back.
    func pause(_ noteID: String) {
        guard let run = runs[noteID] else {
            guard paper(noteID)?.file.watch != nil else { return }
            looks.cancel(noteID)
            looking.remove(noteID)
            write(noteID) { file in
                guard var watch = file.watch else { return }
                watch.paused.toggle()
                watch.id = UUID().uuidString
                file.watch = watch
            }
            return
        }
        if run.token.paused { return goOn(run) }
        // One that can't be begun again (nothing to carry on) isn't paused: Pause stops it, and says so.
        if NoteHelp.goOn(launched: run.launched, waitingTurn: false, restartable: run.restart != nil) == .stopped {
            halt(run)
            write(noteID) { file in
                file.helper = nil
                file.ink = [NoteHelp.Ink(who: run.who, text: "Stopped: this can't be paused. Ask again to start it over.")]
            }
            return
        }
        guard run.token.pause() else { return }
        if let sticky = run.sticky { app.assist.decline(owner: sticky.id.uuidString) }
        write(noteID) { file in file.helper?.state = .waiting; file.helper?.step = "Paused" }
    }

    /// Go on: the token admits again; a turn that waited is started, a call that waited goes, and a turn the pause
    /// ended goes on in the same session (with `words`, shielded, when the person said something).
    private func goOn(_ run: Run, saying words: Shielded? = nil) {
        let action = NoteHelp.goOn(launched: run.launched && run.sticky != nil, waitingTurn: run.sticky?.agent.waiting.isEmpty == false,
                                   restartable: run.restart != nil)
        switch action {
        case .restart, .stopped:
            // Its agent never started (a quick run, or one paused in setup): begun again from its line, as a new run.
            let restart = run.restart
            halt(run)
            restart?()
        case .startWaiting:
            guard run.token.goOn() else { return }
            write(run.noteID) { file in file.helper?.state = .working; file.helper?.step = "Going on" }
            app.focus.brain.resume()
            app.claude.startWaiting()
            if let words { run.sticky?.agent.send(words) }
        case .carryOn:
            guard run.token.goOn(), let sticky = run.sticky else { return }
            write(run.noteID) { file in file.helper?.state = .working; file.helper?.step = "Going on" }
            app.focus.brain.resume()
            if sticky.agent.running { if let words { sticky.agent.send(words) } } else { sticky.agent.send(words ?? "Go on where you stopped.") }
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
        if let run = runs[noteID], run.launched, run.sticky != nil, run.token.admits || run.token.paused {
            // At work (or paused): what's said now steers it in the same session, shielded first.
            var raw = Raw()
            raw.ask = NoteHelp.spoken(trimmed)
            return Self.tell(raw) { told in
                guard let told, self.runs[noteID] === run else { return }
                if run.token.paused { return self.goOn(run, saying: told.ask) }
                if run.token.admits { run.sticky?.agent.send(told.ask) }
            }
        }
        let request = NoteHelp.request(trimmed, now: Date())
        switch request {
        case .bringBack(let date, _, let others): bringBack(paper, date: date, others: others, asked: trimmed)
        case .remember(let item): remember(paper, item, asked: trimmed)
        case .forget(let words): forget(paper, words, asked: trimmed)
        case .putAway: putAway(paper, asked: trimmed)
        case .watch(let every, let at, let line): watch(paper, every: every, at: at, line: line, asked: trimmed)
        case .stopWatching:
            looks.cancel(noteID)
            looking.remove(noteID)
            write(noteID) { $0.watch = nil }
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
        // Its clock is the one it was said in; its id is new (a look of an older watcher writes nothing back).
        watch.tz = TimeZone.current.identifier
        watch.id = UUID().uuidString
        if let old = paper.file.watch, old.url == url { watch.last = old.last; watch.history = old.history; watch.hint = old.hint }
        looks.cancel(paper.noteID)
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

    // MARK: Rule B: what a helper tells an AI, shielded first

    /// The raw parts a helper gathers; only `tell` turns them into `NoteHelp.Told` (through NoteShield).
    struct Raw {
        var ask = ""
        var body = ""
        var notebook = ""
        var cover = ""
        var extra = ""
        var answer = ""
        var labels: [String] = []
        var line = ""
        var last = ""
        var paths: [String] = []
        var instructions = ""
        var memory = ""
        var sourceBook = ""
        var sources: [String] = []
        /// The note's place, and whether its app is kept private (then only what it is is told).
        var place: NoteStick?
        var placePrivate = false
    }

    /// `raw` through NoteShield, off the main thread: every part redacted whole (the place filtered for a private
    /// app first, then its words and sentence derived); nil while the vault can't be read.
    static func tell(_ raw: Raw, _ done: @escaping @MainActor (NoteHelp.Told?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let made = VaultIndex.settled { index -> NoteHelp.Told? in
                let parts = [raw.ask, raw.body, raw.notebook, raw.cover, raw.extra, raw.answer, raw.line, raw.last, raw.instructions, raw.memory, raw.sourceBook]
                guard let shown = NoteShield.shield(parts, index: index), let labels = NoteShield.shield(raw.labels, index: index),
                      let paths = NoteShield.shield(raw.paths, index: index), let sources = NoteShield.shield(raw.sources, index: index) else { return nil }
                var told = NoteHelp.Told(ask: shown[0], body: shown[1], notebook: shown[2], cover: shown[3], extra: shown[4], answer: shown[5],
                                         labels: labels, line: shown[6], last: shown[7], paths: paths, instructions: shown[8], memory: shown[9],
                                         sourceBook: shown[10], sources: sources)
                if let stick = raw.place {
                    guard let place = NoteShield.place(stick, appPrivate: raw.placePrivate, index: index) else { return nil }
                    told.place = place.words
                    told.quote = place.quote
                }
                return told
            } ?? nil
            let carried = ToldBox(made)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(carried.value) } }
        }
    }

    private final class ToldBox: @unchecked Sendable {
        let value: NoteHelp.Told?
        init(_ value: NoteHelp.Told?) { self.value = value }
    }

    /// Told for `run`, then `then` while it's still live; the vault unreadable ends it saying so.
    private func told(_ run: Run, _ raw: Raw, _ then: @escaping @MainActor (NoteHelp.Told) -> Void) {
        Self.tell(raw) { told in
            guard self.live(run) else { return }
            guard let told else { return self.fail(run, NoteShield.unreadable) }
            then(told)
        }
    }

    /// The note and its notebook's cover (only when the note may read it), as every helper reads them first.
    private func raw(_ paper: PaperNote) -> Raw {
        var raw = Raw()
        raw.body = paper.file.body
        raw.notebook = paper.notebook
        raw.cover = mayRead(paper.notebook, from: paper) ? cover(of: paper.notebook)?.file.body ?? "" : ""
        // The person's own notes for the AI and what Petal remembers: shielded too, in the helper's own system prompt.
        raw.instructions = (try? String(contentsOf: app.config.instructionsFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        raw.memory = app.assist.memoryBrief(mode: nil)
        return raw
    }

    // MARK: Quick helpers (the quick AI once, then plain arithmetic or words)

    private func recalculate(_ paper: PaperNote, asked: String) {
        let values = NoteHelp.values(paper.file.body)
        guard !values.isEmpty else { return say(paper.noteID, "There's nothing to add up yet: write lines like “Flights: 412”.", asked: asked) }
        // The AI proposes the formula once (from the labels only, never the note's other words); arithmetic keeps it.
        let run = begin(paper, asked: asked, step: "Working out the formula")
        run.kind = .quick
        run.restart = { [weak self] in if let self, let paper = self.paper(paper.noteID) { self.recalculate(paper, asked: asked) } }
        var raw = Raw()
        raw.labels = values.map(\.label)
        raw.ask = NoteHelp.spoken(asked)
        told(run, raw) { told in
            self.app.focus.brain.ask(NoteHelp.formulaRequest(told), key: "calc|\(paper.noteID)|\(run.token.id)", token: run.token) { reply in
                guard self.live(run) else { return }
                let label = (reply?["label"] as? String).map { String($0.prefix(30)) } ?? "Total"
                let proposed = reply?["formula"] as? String ?? "sum()"
                // The formula names the labels as shown (redacted); one that doesn't add up on the note's own is sum().
                let formula = NoteHelp.evaluate(proposed, values: values) != nil ? proposed : "sum()"
                guard run.token.complete(.succeeded) else { return }
                self.runs[paper.noteID] = nil
                self.tokens.finish(paper.noteID, run.token)
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
        run.restart = { [weak self] in if let self, let paper = self.paper(paper.noteID) { self.putAway(paper, asked: asked) } }
        let bundle = front.bundleIdentifier ?? ""
        let pid = front.processIdentifier
        let file = desk?.scene?.file ?? ""
        let token = run.token
        NoteDesk.queue.async {
            guard token.admits else { return }
            var items = Self.windowTabs(bundle).map { NoteHelp.TaskItem(kind: .tab, title: $0.title, target: $0.url) }
            if !file.isEmpty { items.append(NoteHelp.TaskItem(kind: .file, title: (file as NSString).lastPathComponent, target: file)) }
            if bundle == "com.apple.mail", let mail = Self.selectedMail() { items.append(NoteHelp.TaskItem(kind: .mail, title: mail.subject, target: mail.url)) }
            if items.isEmpty, let title = Self.windowTitle(pid), !title.isEmpty { items.append(NoteHelp.TaskItem(kind: .window, title: title, target: bundle)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.live(run) else { return }
                    guard !items.isEmpty else { return self.fail(run, "There was nothing to put away in that window.") }
                    self.write(paper.noteID) { $0.task = items }
                    let plain = "Put away: \(NoteHelp.taskChips(items).joined(separator: ", ")). Open all brings them back."
                    let finish = { (line: String) in
                        guard self.live(run), run.token.complete(.succeeded) else { return }
                        self.runs[paper.noteID] = nil
                        self.tokens.finish(paper.noteID, run.token)
                        let who = Self.petalWho + " · put away " + NoteHelp.dayLabel(Date(), now: Date())
                        self.answer(paper.noteID, [NoteHelp.Ink(who: who, text: line)], who: who, asked: asked)
                    }
                    guard self.app.focus.brain.enabled else { return finish(plain) }
                    // Where they stopped, from the titles only (shielded), by the quick AI.
                    var raw = Raw()
                    raw.labels = items.map(\.title)
                    raw.body = paper.file.body
                    self.told(run, raw) { told in
                        self.app.focus.brain.ask(NoteHelp.awayRequest(told), key: "away|\(paper.noteID)|\(run.token.id)", token: run.token) { reply in
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

    /// Anything else asked: a run registered at once (or the one a chain made before it fired); then, on a page tied
    /// to a repository or a file in a checkout, the person's own coding AI in a worktree; else the chat AI on the
    /// note's place.
    private func ask(_ paper: PaperNote, _ text: String, asked: String, compare: (book: String, notes: [String])? = nil, run given: Run? = nil) {
        let models = NoteHelp.models(asked)
        let pick = models.first { !$0.holes }
        let run = given ?? begin(paper, asked: asked, step: "Starting", who: pick.map { "\(Self.petalWho) · \($0.name)" } ?? Self.petalWho)
        run.holes = models.first { $0.holes }
        run.restart = { [weak self] in
            guard let self, let paper = self.paper(paper.noteID) else { return }
            self.ask(paper, text, asked: asked, compare: compare)
        }
        let stick = desk?.here[paper.key].flatMap { paper.file.places.indices.contains($0) ? paper.file.places[$0] : nil } ?? paper.file.places.first
        if compare == nil, let stick, let repo = NoteHelp.repository(url: stick.url) {
            return code(run, paper, text, slug: repo.slug, number: NoteHelp.pullNumber(repo), file: nil, pick: pick)
        }
        if compare == nil, let stick, stick.kind == .file || stick.kind == .passage, !stick.path.isEmpty {
            let path = stick.path
            return Self.checkouts { all in
                guard self.live(run) else { return }
                if let folder = NoteHelp.checkout(holding: path, among: all.map(\.path)) {
                    self.code(run, paper, text, slug: nil, number: nil, file: folder, pick: pick)
                } else {
                    self.think(run, paper, text, pick: pick, compare: compare)
                }
            }
        }
        think(run, paper, text, pick: pick, compare: compare)
    }

    /// @Petal: the chat AI with Petal's tools, on the note's own place (never what happens to be in front: a note
    /// away from its window waits for it), the notebook's cover read first.
    private func think(_ run: Run, _ paper: PaperNote, _ text: String, pick: NoteHelp.Model?, compare: (book: String, notes: [String])?) {
        guard live(run) else { return }
        guard let provider = provider(for: pick) else { return fail(run, "Choose an AI in Petal's settings first (Claude Code or Codex).") }
        let paper = self.paper(run.noteID) ?? paper
        let anchor = NoteHelp.anchor(paper.file.places, here: desk?.here[paper.key])
        if case .away(let label) = anchor {
            run.awaitingPlace = true
            run.placedResume = { [weak self] in self?.think(run, paper, text, pick: pick, compare: compare) }
            write(run.noteID) { file in file.helper?.state = .waiting; file.helper?.step = "Waiting for \(label) to be in front" }
            return
        }
        run.awaitingPlace = false
        var raw = raw(paper)
        raw.ask = text
        // A notebook to check against: each of its notes shielded whole, its titles derived after (NoteHelp.comparison).
        raw.sourceBook = compare?.book ?? ""
        raw.sources = compare?.notes ?? []
        if case .placed(let index) = anchor {
            raw.place = paper.file.places[index]
            raw.placePrivate = app.assist.neverLook(paper.file.places[index].app)
        }
        told(run, raw) { told in
            self.launch(run, paper, prompt: told.ask, kind: .petal, provider: provider, model: pick?.id ?? "",
                        told: told, brief: NoteHelp.brief(told), folder: nil, placed: true)
        }
    }

    /// The notes changed (read again, re-stuck, a place taken off or added): a running helper whose note's places
    /// moved follows them. Its tools look at the new place (none when it isn't on a window in front now), and what
    /// it read or queued for the old one is dropped (ComputerUse.placeChanged).
    func placesFollow() {
        for (noteID, run) in runs where run.launched {
            guard let paper = paper(noteID), let sticky = run.sticky, let seen = placesSeen[noteID],
                  NoteHelp.placesMoved(seen, paper.file.places) else { continue }
            placesSeen[noteID] = paper.file.places
            if case .placed = run.kind == .petal ? NoteHelp.anchor(paper.file.places, here: desk?.here[paper.key]) : .free {
                sticky.agent.place = place(of: paper)
            } else {
                sticky.agent.place = nil
            }
            app.assist.computer.placeChanged(sticky.id.uuidString)
        }
        for noteID in placesSeen.keys where runs[noteID] == nil { placesSeen[noteID] = nil }
    }

    /// Layout placed notes: a run waiting for its note's place goes on once its note is on the window in front.
    func placedNow() {
        for run in runs.values where run.awaitingPlace && run.token.admits {
            guard let paper = paper(run.noteID), case .placed = NoteHelp.anchor(paper.file.places, here: desk?.here[paper.key]) else { continue }
            run.awaitingPlace = false
            run.placedResume?()
        }
    }

    /// A coding helper: the person's own Claude Code or Codex in their checkout, in the note's own worktree (made
    /// once, reused for its follow-ups once it's verified to be that checkout's on the note's branch), after Allow
    /// on the note once per project. `number`: a pull request's only (an issue starts from the default branch).
    private func code(_ run: Run, _ paper: PaperNote, _ text: String, slug: String?, number: Int?, file folder: String?, pick: NoteHelp.Model?) {
        Self.checkouts { all in
            guard self.live(run) else { return }
            var candidates = folder.map { [$0] } ?? slug.map { NoteHelp.checkouts(for: $0, among: all) } ?? []
            // "in ~/garden" picks among several: its whole path, exactly one.
            if candidates.count > 1, let named = NoteHelp.named(candidates, in: run.asked, home: NSHomeDirectory()) { candidates = [named] }
            guard let checkout = candidates.first else {
                return self.fail(run, "Petal couldn't find a checkout of \(slug ?? "this repository") in your home folder.")
            }
            guard candidates.count == 1 else {
                let names = candidates.map { ($0 as NSString).abbreviatingWithTildeInPath }
                return self.fail(run, "Which checkout: " + names.joined(separator: " or ") + "? Say “@Petal … in \(names[0])”.")
            }
            let remotes = all.first { $0.path == checkout }?.remotes ?? []
            let remote = slug.flatMap { NoteHelp.remote(for: $0, in: remotes) } ?? remotes.first { $0.name == "origin" }?.name ?? remotes.first?.name ?? ""
            guard let provider = self.provider(for: pick) else { return self.fail(run, "Choose an AI in Petal's settings first (Claude Code or Codex).") }
            run.who = pick?.name ?? provider.name
            let short = (checkout as NSString).abbreviatingWithTildeInPath
            let kind = "code:" + checkout
            self.working(run.noteID, step: "Asking to work in \(short)", asked: run.asked, who: run.who)
            // The note's helper owns the card, so Stop and the card's answer are this run's.
            let sticky = self.sticky(for: paper)
            run.sticky = sticky
            let already = self.app.config.strings("aiAllowed").contains(kind) || self.app.config.string("claudeAccess") == "full"
            self.app.assist.ask(kind, "\(provider.appName) wants to work in \(short)",
                                detail: "In a worktree of its own, on a new branch. It may commit, push and open a pull request.",
                                owner: sticky.id.uuidString) { allowed in
                guard self.live(run) else { return }
                guard allowed else { return self.fail(run, "Not allowed: nothing was changed in \(short).") }
                let always = self.app.config.strings("aiAllowed").contains(kind)
                let grant = always ? "always:" + kind : "reply"
                if !already { self.stamp(run.noteID, label: "ALLOWED · \(provider.name.uppercased()) · \(short.uppercased())", grant: grant) }
                // The authorization this run works under: taking it back stops it.
                run.token.hold(grant)
                if always { run.token.hold("always:" + kind) }
                self.working(run.noteID, step: "Worktree of \(short)", asked: run.asked, who: run.who)
                // The branch stored when the note's worktree was first made (follow-ups are verified against it).
                let branch = NoteHelp.branch(stored: self.paper(run.noteID)?.file.worktree, checkout: checkout, noteID: run.noteID, words: NoteHelp.spoken(run.asked))
                Self.worktree(checkout, noteID: run.noteID, branch: branch, remote: remote, pull: number, token: run.token) { made in
                    guard self.live(run) else { return }
                    guard case .made(let tree, let branch) = made else {
                        if case .failed(let problem) = made { self.fail(run, "Petal couldn't set up a worktree of \(short): \(problem).") }
                        return
                    }
                    run.tree = tree
                    self.write(run.noteID) { $0.worktree = NoteHelp.Worktree(path: tree, branch: branch, checkout: checkout, remote: remote) }
                    // The coding helper reads the cover first, as every helper does.
                    var raw = self.raw(paper)
                    raw.ask = text
                    raw.paths = [short, tree, branch, number.map { "\(slug ?? "")'s #\($0) (fetched from \(remote))" } ?? ""]
                    self.told(run, raw) { told in
                        self.launch(run, paper, prompt: NoteHelp.codeRequest(told), kind: .code(folder: tree), provider: provider, model: pick?.id ?? "",
                                    told: told, brief: NoteHelp.codeBrief(told), folder: tree, placed: false)
                    }
                }
            }
        }
    }

    /// "check this against @Notebook": the notebook's notes read (never one not known to be open, from outside it),
    /// and contradictions flagged as questions.
    private func check(_ paper: PaperNote, against name: String, asked: String) {
        guard let book = store?.notebook(name) else { return say(paper.noteID, "There's no notebook called “\(name)”.", asked: asked) }
        guard mayRead(book.name, from: paper) else { return say(paper.noteID, "That notebook is private (or its cover isn't here yet): only a note inside it can read it.", asked: asked) }
        let notes = (store?.notes ?? []).filter { $0.notebook == book.name && $0.version == nil && $0.noteID != paper.noteID }.prefix(40)
        // Each note's whole text: shielded one by one before any title is taken or anything is cut.
        ask(paper, "Check this note against the notebook below. Flag anything that contradicts it, each as a short question (\"Is it … or …?\"). If nothing does, say so in one line.",
            asked: asked, compare: (book.name, notes.map(\.file.body)))
    }

    // MARK: Running

    private func provider(for pick: NoteHelp.Model?) -> Provider? {
        let installed = app.providers.filter { app.paths[$0] != nil }
        if let pick, let wanted = Provider(rawValue: pick.provider.rawValue), installed.contains(wanted) { return wanted }
        return app.chatProvider.flatMap { installed.contains($0) ? $0 : nil } ?? installed.first
    }

    /// The note's own helper agent (one per note while Petal runs): its tools look at the note's place. A note in a
    /// notebook not known to be open is marked so (and checked again when shown): it never shows in the previews.
    private func sticky(for paper: PaperNote) -> StickyNote {
        if let kept = mainSticky(paper.noteID) {
            kept.secret = privacy(of: paper.notebook) != .open
            return kept
        }
        let sticky = StickyNote()
        sticky.paper = paper.noteID
        sticky.secret = privacy(of: paper.notebook) != .open
        sticky.agent.keeps = false
        app.claude.notes.append(sticky)
        return sticky
    }

    private func mainSticky(_ noteID: String) -> StickyNote? { app.claude.notes.first { $0.paper == noteID && !$0.reviewer } }

    private func drop(_ sticky: StickyNote) {
        guard !sticky.agent.running else { return }
        app.claude.notes.removeAll { $0 === sticky }
    }

    /// Whether a helper of this note may show in the AI button's previews: only one in a notebook known to be open.
    func previewable(_ sticky: StickyNote) -> Bool {
        guard let noteID = sticky.paper else { return true }
        if sticky.secret { return false }
        return paper(noteID).map { privacy(of: $0.notebook) == .open } ?? false
    }

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

    /// The run's agent starts: its brief and prompt `Shielded`, its turns carried by the run's token.
    private func launch(_ run: Run, _ paper: PaperNote, prompt: Shielded, kind: Run.Kind, provider: Provider, model: String, told: NoteHelp.Told,
                        brief: Shielded, folder: String?, placed: Bool, sticky given: StickyNote? = nil) {
        guard live(run) else { return }
        let sticky = given ?? run.sticky ?? sticky(for: paper)
        let agent = sticky.agent
        // Only the note's own place: when it isn't on a window now, none (the brief says not to look at what's in front).
        agent.place = placed ? place(of: paper) : nil
        // Its whole system prompt, made only of Shielded parts (no window or tab title, no raw text).
        agent.helperSystem = NoteHelp.system(told, provider: provider == .claude ? "Claude" : "Codex", computerUse: app.config.bool("computerUse"), brief: brief)
        agent.token = run.token
        agent.folder = folder.map { URL(fileURLWithPath: $0) }
        agent.pinned = (provider, model)
        run.sticky = sticky
        run.kind = kind
        run.from = agent.messages.count
        run.launched = true
        placesSeen[run.noteID] = paper.file.places
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
        guard let noteID = sticky.paper, let run = runs[noteID], run.sticky === sticky, run.token.admits,
              Date().timeIntervalSince(stepWritten[noteID] ?? .distantPast) > 8 else { return }
        // Being written in: the paper shows the step live; nothing is written under the person's typing.
        if let key = paper(noteID)?.key, desk?.keyboard == key { return }
        stepWritten[noteID] = Date()
        let step = sticky.agent.activity
        write(noteID) { file in if file.helper?.state == .working { file.helper?.step = step } }
    }

    /// A helper's turn ended (ClaudePanel.finished). Its token says what that means, from the agent's explicit
    /// outcome: still asking the person, paused (kept, with Go on), stopped (nothing), failed (said, nothing
    /// advances), or succeeded: the whole answer becomes the note's ink, its steps go on the back, and only then a
    /// reviewer or a chain's next step may run.
    func finished(_ sticky: StickyNote) {
        // Only the run that launched this turn: an older run's turn ending while a new one is still being set up
        // (the same agent) is nothing to it.
        guard let noteID = sticky.paper, let run = runs[noteID], run.sticky === sticky, run.launched else { return }
        let agent = sticky.agent
        let messages = Array(agent.messages.dropFirst(min(run.from, agent.messages.count)))
        let ending = run.token.ending(outcome: agent.outcome, asking: !agent.pendingAsk.isEmpty)
        switch ending {
        case .waitingOnPerson:
            write(noteID) { $0.helper?.state = .waiting; $0.helper?.step = "Waiting for you: Allow or Don't" }
            return
        case .paused:
            write(noteID) { $0.helper?.state = .waiting; $0.helper?.step = "Paused" }
            return
        case .stopped:
            return stopped(run, saying: "Stopped.")
        case .failed:
            return fail(run, agent.failure ?? messages.last { $0.kind == .error }?.text ?? "It stopped without finishing.")
        case .succeeded:
            break
        }
        guard run.token.complete(.succeeded) else { return }
        runs[noteID] = nil
        tokens.finish(noteID, run.token)
        let answer = messages.last { $0.kind == .claude }?.text ?? "Done."
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
            if ink.proof.isEmpty, let finish = NoteHelp.finishLine(run.asked) { ink.proof = [String(finish.prefix(18))] }
        }
        // The next answer replaces the last: one block of ink (a second opinion's comes after it).
        self.answer(noteID, [ink], who: run.who, asked: run.asked, steps: steps)
        if let holes = run.holes, let paper = paper(noteID) { secondOpinion(paper, holes, after: run, answer: answer) }
    }

    /// "and have <model> look for holes": a run of its own, after the first succeeded, reading the cover and the note
    /// first, then its answer (and in a worktree, the change), listing objections as its own ink with a count.
    private func secondOpinion(_ paper: PaperNote, _ model: NoteHelp.Model, after first: Run, answer: String) {
        guard let provider = provider(for: model) else {
            // Asked for, but no AI to give it: said under the answer (the answer stands).
            return write(paper.noteID) { $0.ink.append(NoteHelp.Ink(who: Self.petalWho, text: "No second opinion: \(model.name) isn't set up in Petal's settings.")) }
        }
        let who = model.name.isEmpty ? provider.name : model.name
        let run = begin(paper, asked: first.asked, step: "Looking for holes", who: who)
        let tree = first.tree
        let reviewer = StickyNote()
        reviewer.paper = paper.noteID
        reviewer.reviewer = true
        reviewer.secret = privacy(of: paper.notebook) != .open
        reviewer.agent.keeps = false
        app.claude.notes.append(reviewer)
        run.sticky = reviewer
        var raw = raw(paper)
        raw.answer = answer
        raw.paths = tree.map { [$0] } ?? []
        told(run, raw) { told in
            self.launch(run, paper, prompt: NoteHelp.reviewRequest(told, tree: told.paths.first), kind: .holes(folder: tree), provider: provider, model: model.id,
                        told: told, brief: NoteHelp.reviewBrief(told), folder: tree, placed: false, sticky: reviewer)
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
        guard let run = runs[noteID], let sticky = run.sticky, run.token.admits else { return }
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
        fail(run, "Not allowed: it stopped there.")
    }

    private func stamp(_ noteID: String, label: String, grant: String) {
        let stamp = NoteHelp.Stamp(label: label, grant: grant, mac: mac)
        runs[noteID]?.token.hold(grant)
        write(noteID) { file in if !file.stamps.contains(stamp) { file.stamps.append(stamp) } }
    }

    /// Tapping a stamp takes its grant back (on the Mac it was given on) and the stamp goes; a run holding it (every
    /// run holds its note's grants) is cancelled, which ends its processes.
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
        // Every run holding it is cancelled, whichever note it's on (an Always for a checkout is shared).
        for held in tokens.revoke(stamp.grant) {
            guard let run = runs[held] else { continue }
            halt(run)
            write(held) { file in
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

    /// A chain's note is done: its run is registered first, then `fired` is written (landed, on this Mac only), then
    /// checked again (still that run, still that chain, fired by it) before the helper is asked through `ask`, like
    /// any run (a coding page gets its worktree and its project's Allow). A restart or a sync never runs it twice.
    private func fire(_ paper: PaperNote) {
        guard var chain = paper.file.chain, runs[paper.noteID] == nil else { return }
        let asked = "when @" + chain.afterTitle + " is done, " + chain.ask
        let run = begin(paper, asked: asked, step: "\(chain.afterTitle) is done: starting")
        let fired = Date()
        chain.fired = fired
        write(paper.noteID, { $0.chain = chain }) { landed in
            guard landed, self.live(run), let now = self.paper(paper.noteID), let mine = now.file.chain,
                  mine.after == chain.after, mine.fired.map({ abs($0.timeIntervalSince(fired)) < 1 }) == true else {
                return self.stopped(run, saying: "Petal couldn't record that this chain started, so it didn't.")
            }
            self.ask(now, chain.ask + " (\(chain.afterTitle) is done; read it with petal_note_read, its helper's answer included.)", asked: asked, run: run)
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

    /// A watcher looks once: the page fetched plainly (bounded) and shielded with its line and last value before
    /// anything reads it; its value found with no AI when it can be; the AI only when it can't, or when the line is
    /// crossed. Nothing is ever bought. What it finds is written back only into the look's own fields and only while
    /// the watcher is the one it began under (its id) and not paused; the note says a crossing only when that write
    /// newly crossed the line.
    func look(_ noteID: String) {
        guard let paper = paper(noteID), let watch = paper.file.watch, watch.mac == mac, !watch.paused, !looking.contains(noteID),
              let url = URL(string: watch.url), ["http", "https"].contains(url.scheme ?? "") else { return }
        looking.insert(noteID)
        let id = watch.id
        // The look's own token, kept with the watcher: pausing, stopping or changing it cancels the fetch and its
        // quick calls.
        let token = looks.start(noteID)
        let task = Task.detached {
            guard token.admits else { return }
            let data = await Sites.get(url, .page)
            let html = data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) } ?? ""
            let text = NoteHelp.pageText(html)
            await MainActor.run {
                guard token.admits else { self.looking.remove(noteID); return }
                var raw = Raw()
                raw.extra = text
                raw.line = watch.line
                raw.last = watch.last
                Self.tell(raw) { told in
                    guard let told, token.admits else { self.looking.remove(noteID); return }
                    self.read(noteID, id: id, told: told, token: token)
                }
            }
        }
        if token.bind({ task.cancel() }) == nil { task.cancel() }
    }

    /// The watcher as it is now, while it's the one a look began under (`id`) and not paused.
    private func current(_ noteID: String, _ id: String) -> NoteHelp.Watch? {
        guard let watch = paper(noteID)?.file.watch, watch.id == id, !watch.paused else { return nil }
        return watch
    }

    private func read(_ noteID: String, id: String, told: NoteHelp.Told, token: RunToken) {
        guard let watch = current(noteID, id), token.admits else { looking.remove(noteID); return }
        let text = told.extra.text
        let line = NoteHelp.line(watch.line)
        let last = NoteHelp.amounts(watch.last, needCurrency: false).first?.value
        let finish = { (value: Double?, hint: String?, said: String?) in
            self.looking.remove(noteID)
            guard self.current(noteID, id) != nil, token.admits else { return }
            // This look's own end: only a look that succeeded (its write newly crossing the line) says a crossing.
            token.complete(.succeeded)
            self.looks.finish(noteID, token)
            let shown = value.map { NoteHelp.format($0, currency: line?.currency ?? "", thousands: line?.thousands ?? false) }
            let crossed = value.map { NoteHelp.crossed($0, line: watch.line) } ?? false
            let now = Date()
            let newly = Flag()
            self.write(noteID, { file in
                var current = file.watch
                guard let result = NoteHelp.applyLook(&current, id: id, shown: shown, hint: hint, crossed: crossed, at: now) else { return }
                file.watch = current
                newly.value = result
            }) { landed in
                // Said only from this write's own result: newly crossed, and landed.
                guard landed, newly.value, let shown else { return }
                let words = said ?? "Now \(shown): \(watch.line). Petal never buys by itself: say “@Petal buy it” and you'll see a Buy card first."
                self.answer(noteID, [NoteHelp.Ink(who: Self.petalWho + " · " + NoteHelp.dayLabel(Date(), now: Date()), text: words)],
                            who: Self.petalWho, asked: self.paper(noteID)?.file.helper?.asked ?? "")
                self.summon(noteID, open: true)
            }
        }
        if !text.isEmpty, let found = NoteHelp.pick(text, line: watch.line, hint: watch.hint, last: last) {
            let hintWords = NoteHelp.hint(before: found, in: text)
            guard NoteHelp.crossed(found.value, line: watch.line), !watch.hit, app.focus.brain.enabled else { return finish(found.value, hintWords, nil) }
            // Crossed: the quick AI checks it's really the thing's price before the note says so; what it's told is
            // the shielded page and ranges of it.
            let ns = text as NSString
            let hintRange = ns.range(of: hintWords, options: .backwards, range: NSRange(location: 0, length: found.range.location))
            let hint = hintRange.location == NSNotFound ? Shielded("") : told.extra.substring(hintRange)
            let prompt = NoteHelp.watchConfirm(told, found: told.extra.substring(found.range), hint: hint)
            let key = "watch|\(noteID)|\(id)|\(found.text)|\(Date().timeIntervalSince1970)"
            app.focus.brain.ask(prompt, key: key, token: token) { reply in
                if reply?["yes"] as? Bool == false { return finish(nil, nil, nil) }
                finish(found.value, hintWords, (reply?["say"] as? String).map { String($0.prefix(240)) })
            }
            return
        }
        guard !text.isEmpty, app.focus.brain.enabled else { return finish(nil, nil, nil) }
        // Couldn't tell plainly: the quick AI finds it once, and the words before it for next time.
        app.focus.brain.ask(NoteHelp.watchFind(told), key: "watchfind|\(noteID)|\(id)|\(Date().timeIntervalSince1970)", token: token) { reply in
            finish((reply?["value"] as? NSNumber)?.doubleValue, reply?["before"] as? String, nil)
        }
    }

    private final class Flag { var value = false }

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
    /// ~/Code), each by its canonical path (links resolved) with its remotes by name, read from its own .git/config
    /// (no git run). Off the main thread.
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
            var seen: Set<String> = []
            for folder in folders {
                var isDirectory: ObjCBool = false
                // A main checkout only: its .git is a folder (a worktree's is a file).
                guard FileManager.default.fileExists(atPath: folder.appending(path: ".git").path, isDirectory: &isDirectory), isDirectory.boolValue,
                      let config = try? String(contentsOf: folder.appending(path: ".git/config"), encoding: .utf8) else { continue }
                let canonical = NoteHelp.standard(folder.resolvingSymlinksInPath().path)
                guard seen.insert(canonical).inserted else { continue }
                found.append((canonical, NoteHelp.remotes(config: config)))
            }
            nonisolated(unsafe) let result = found
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    enum Worktree { case made(String, branch: String), failed(String), stopped }

    /// The note's worktree of `checkout` (one per note, keyed by the checkout's canonical path and the note, in
    /// Petal's own folder, never inside the person's checkout). Reused only when git says it's still that checkout's
    /// on the note's branch. A new one starts from the pull request's head, fetched from `remote` (the remote that is
    /// that repository) into a ref of this run's own (never FETCH_HEAD, which runs side by side would share; the ref
    /// goes once the worktree is made; the fetch failing makes nothing), or else from `remote`'s default branch. Every
    /// git step runs under the run's token: paused or stopped, the step ends and nothing more is done. Off the main
    /// thread.
    static func worktree(_ checkout: String, noteID: String, branch: String, remote: String, pull: Int?, token: RunToken,
                         _ done: @escaping @MainActor (Worktree) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let canonical = NoteHelp.standard(URL(fileURLWithPath: checkout).resolvingSymlinksInPath().path)
            let tree = Config.supportFolder.appending(path: "Worktrees").appending(path: NoteHelp.worktreeName(checkout: canonical, noteID: noteID)).path
            let finish = { (result: Worktree) in DispatchQueue.main.async { MainActor.assumeIsolated { done(token.admits ? result : .stopped) } } }
            let step = { (folder: String, arguments: [String]) -> (status: Int32, output: String)? in
                guard token.admits else { return nil }
                return git(folder, arguments, token: token)
            }
            if FileManager.default.fileExists(atPath: tree + "/.git") {
                // Its follow-ups work where it did, once it's verified to be this checkout's, on the note's branch.
                guard let common = step(tree, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
                      let head = step(tree, ["rev-parse", "--abbrev-ref", "HEAD"]) else { return finish(.stopped) }
                let expected = canonical + "/.git"
                let actual = URL(fileURLWithPath: common.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
                guard common.status == 0, head.status == 0,
                      NoteHelp.reusable(expectedCommon: expected, actualCommon: actual, branch: branch, actualBranch: head.output.trimmingCharacters(in: .whitespacesAndNewlines))
                else { return finish(.failed("a worktree for this note is there but belongs to something else; Petal left it at \(tree)")) }
                return finish(.made(tree, branch: branch))
            }
            try? FileManager.default.createDirectory(atPath: (tree as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            var base = ""
            var ref: String?
            if let pull {
                guard !remote.isEmpty else { return finish(.failed("no remote of that repository to fetch #\(pull) from")) }
                let own = NoteHelp.fetchRef(token.id)
                guard let fetched = step(canonical, ["fetch", "--quiet", remote, "+pull/\(pull)/head:\(own)"]) else { return finish(.stopped) }
                guard fetched.status == 0 else { return finish(.failed("couldn't fetch #\(pull) from \(remote)")) }
                base = own
                ref = own
            } else {
                // The remote's own default branch (never the checkout's HEAD): asked of the remote, then fetched into
                // this run's own ref; when it can't be told, nothing is made.
                guard !remote.isEmpty else { return finish(.failed("no remote to start from")) }
                guard let listed = step(canonical, ["ls-remote", "--symref", remote, "HEAD"]) else { return finish(.stopped) }
                guard listed.status == 0, let main = NoteHelp.defaultBranch(lsRemote: listed.output) else {
                    return finish(.failed("couldn't tell \(remote)'s default branch"))
                }
                let own = NoteHelp.fetchRef(token.id)
                guard let fetched = step(canonical, ["fetch", "--quiet", remote, "+refs/heads/\(main):\(own)"]) else { return finish(.stopped) }
                guard fetched.status == 0 else { return finish(.failed("couldn't fetch \(main) from \(remote)")) }
                base = own
                ref = own
            }
            defer { if let ref { _ = git(canonical, ["update-ref", "-d", ref]) } }
            // The branch may be left from a worktree removed earlier: it's the note's own, so it's used again.
            guard let exists = step(canonical, ["rev-parse", "--verify", "--quiet", "refs/heads/" + branch]) else { return finish(.stopped) }
            guard let made = step(canonical, exists.status == 0 ? ["worktree", "add", tree, branch] : ["worktree", "add", "-b", branch, tree, base]) else { return finish(.stopped) }
            finish(made.status == 0 ? .made(tree, branch: branch) : .failed(String(made.output.suffix(200))))
        }
    }

    /// One git step: bound to `token` when given (paused or stopped, it's ended).
    nonisolated static func git(_ folder: String, _ arguments: [String], token: RunToken? = nil) -> (status: Int32, output: String) {
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
        var handle: Int?
        if let token {
            nonisolated(unsafe) let running = process
            handle = token.bind { running.terminate() }
            if handle == nil { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        token?.unbind(handle)
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

    /// A notebook's privacy by its cover: open, private, or unknown (no cover read: missing, not downloaded, or
    /// two of them), which counts as private for outside reads, search and previews until its one cover is read.
    func privacy(of notebook: String) -> NoteHelp.Privacy {
        NoteHelp.privacy(covers: (store?.notes ?? []).filter { $0.notebook == notebook && $0.file.cover }.map(\.file))
    }

    /// Whether a note may read `notebook`: always its own; one not known to be open never from outside it.
    func mayRead(_ notebook: String, from paper: PaperNote?) -> Bool {
        NoteHelp.mayRead(privacy(of: notebook), notebook: notebook, asking: paper?.notebook)
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
