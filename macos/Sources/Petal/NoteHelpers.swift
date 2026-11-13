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
/// Four rules hold it together, each one that nothing can go around:
/// - **Every paid call starts through one function** (`start`): what waits (for room, its gate, Go on, the quick AI's
///   line) is the call's raw sources, never words; right before launch the vault is checked, the cover resolved, the
///   gate asked and the prompt built, in that order, from the sources as they are then (`prepare`, `NoteHelp.launch`).
/// - **Every helper run is one `RunToken`**, made before any setup and carried by everything the run starts:
///   Brain's queue, the chat's waiting queue, each git step and each process are admitted only while it runs and
///   end when it's paused or stopped, and what it does in the person's apps ends first on every change of its state.
///   Every Stop (the note's, the AI button's preview, the pointer's) goes through `stop`; a stamp taken back cancels
///   a run holding it (a run holds every authorization its note was given); only the agent's explicit successful
///   outcome finishes a run, and only a finished run advances anything.
/// - **Every run ends through `end`, with one result** (`NoteHelp.Result`: all it produced, one journal entry and
///   one based write, or nothing), after the gate is asked again right before it lands; a second opinion's holds only
///   its own opinion.
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
        enum Kind: Equatable {
            case petal, code(folder: String), holes(folder: String?), quick
            /// A watcher's look: not in `runs` (it never stops the helper at work there), it ends like any run.
            case look
            /// The reading lens's call (a margin note in Petal's viewer following the selection): not in `runs`
            /// either; its answer shows beside the paragraph, never on the note.
            case lens
            /// A run of its own, apart from the note's helper: never in `runs`, never writing ink or the helper line.
            var apart: Bool { self == .look || self == .lens }
            /// Bound to the note's place (NoteHelpers.bind), like any run that looks at apps: @Petal, and a second
            /// opinion that isn't in a worktree. A coding run works in its checkout.
            var placed: Bool {
                switch self {
                case .petal: true
                case .holes(let folder): folder == nil
                case .code, .quick, .look, .lens: false
                }
            }
        }
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
        /// A second opinion's (nil: not one): the answer it reviews, by the hash of the primary ink it was last told
        /// (`NoteHelp.inkHash`). Its result is only its own opinion, with this; never any ink it captured.
        var reviewed: String?
        /// A chain's run: the note it waited for (its whole body read again whenever a turn starts, shielded, its
        /// title derived after).
        var after: String?
        /// The line of the turn at work (the first, then each follow-up's once it's sent): runnable again if that turn
        /// fails or is stopped, so Return runs it again (its identity in the editor, NoteLine).
        var line: NoteLine?
        /// What a coding helper's reviewer and follow-ups read: the note's worktree, and the checkout it's bound to.
        var tree: String?
        var checkout: String?
        /// The AI and model it runs on: a follow-up naming another starts its own run.
        var provider = ""
        var model = ""
        /// What the admission gate re-derives against, held on the run (independent of `here`): the notebook the
        /// note was in when it began, the place it must be on, the source notes it compares against.
        var startNotebook = ""
        /// That notebook as pending work finds it (NotebookBinding), so a rename isn't a move and another notes'
        /// folder is never taken for it.
        var startBook: NotebookBinding?
        var requiredPlace: NoteStick?
        var sources: [String] = []
        /// The call it's starting or waiting to start (for room, for its gate, for Go on): its raw sources and how
        /// its words are made from them, never a finished prompt. Nil once that call began.
        @ObservationIgnored var call: Call?
        /// That call is being made now (`start`): asked again meanwhile, it isn't started twice.
        var starting = false
        /// The gate held that call (its place or document not showing): started again once it admits.
        var gateHeld = false
        /// What every turn of its agent is made from: its own sources read again each time (`gather`), and how its
        /// agent is launched (`launch`); set once its setup is done (`setUp`).
        @ObservationIgnored var gather: (@MainActor (PaperNote, inout Raw) -> String?)?
        @ObservationIgnored var launch: Launch?
        /// The private apps' generation what it was told was made under (a change rebuilds it, `admit`). Taken when
        /// the run is made (`init`), before anything can ask its gate: never a default that differs from now.
        var privacy: Int
        /// Parked by a tool's admission (its place or document not showing): paused, going on once the gate admits.
        var parked = false
        /// Its agent was started (a turn sent): Go on carries that session on; before it, the request begins again.
        var launched = false
        /// Go on for a run paused before its agent started: the request is begun again.
        @ObservationIgnored var restart: (() -> Void)?

        init(token: RunToken, noteID: String, asked: String, who: String) {
            self.token = token
            self.noteID = noteID
            self.asked = asked
            self.who = who
            self.privacy = ClaudePanel.privacy.now
        }

        var paused: Bool { token.paused }
    }

    private(set) var runs: [String: Run] = [:]
    /// Every run's token by its note, and every watcher look's: starting one cancels the one before; taking back a
    /// grant cancels every run holding it, whichever note it's on.
    @ObservationIgnored private let tokens = TokenTable()
    @ObservationIgnored private let looks = TokenTable()
    /// Notes summoned to the screen (coming back, a watcher's hit, a source chip): shown on their place, or on the
    /// Desktop showing when their place isn't open, until the person puts them away.
    private(set) var summoned: Set<String> = []
    /// Morning notes made this run, by their id: never made twice while the file lands.
    @ObservationIgnored private var mornings: Set<String> = []
    /// The line being taken now, for the run it begins (`begin`).
    @ObservationIgnored private var taking: NoteLine?
    /// A word on a note's helper bar: what Petal did there without a run (10 seconds), or why it didn't (kept until
    /// the person next edits that note).
    var hints: [String: String] = [:]
    /// Refusals kept until the note's next edit, with when they were said (`edited`).
    @ObservationIgnored private var keptHints: [String: Date] = [:]

    private func hint(_ noteID: String, _ words: Shielded, keep: Bool = false) {
        let text = words.text
        hints[noteID] = text
        if keep { keptHints[noteID] = Date(); return }
        keptHints[noteID] = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { MainActor.assumeIsolated { if self.hints[noteID] == text { self.hints[noteID] = nil } } }
    }

    /// The person edited the note `noteID` (its editor saved what they typed): a refusal said there goes. Not the
    /// save of the Return that asked (it lands half a second later), only an edit after the refusal was said.
    func edited(_ noteID: String) {
        guard let said = keptHints[noteID], Date().timeIntervalSince(said) > 1 else { return }
        keptHints[noteID] = nil
        hints[noteID] = nil
    }
    /// Watchers looking now (by note id): one look at a time each.
    @ObservationIgnored private var looking: Set<String> = []
    /// When each note's worktree was last checked for its PR having merged.
    @ObservationIgnored private var mergeChecked: [String: Date] = [:]
    @ObservationIgnored private var timer: Timer?
    /// What the person said to a run while it worked, each with that run's token (never sent in a later run).
    @ObservationIgnored private var followUps = FollowUpQueue<NoteLine>()
    /// The last step written into a note's `helper` (written at most every few seconds; the paper shows it live).
    @ObservationIgnored private var stepWritten: [String: Date] = [:]

    nonisolated static let petalWho = NoteHelp.mark + " " + NoteHelp.petal

    func start(_ desk: NoteDesk) {
        self.desk = desk
        guard timer == nil, !Headless.on else { return }
        // Answers held from before (a conflict when Petal quit): read off the main thread, applied once they can be.
        let file = Self.journalFile
        NoteJournal.queue.async {
            let held = HelperJournal.load(file)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.heldAnswers = held + self.heldAnswers.filter { !held.contains($0) }; self.applyHeld() } }
        }
        // Nothing is ever held unshown: a file an earlier Petal kept for that (it may hold text not yet shielded) is
        // deleted, here on this Mac only (the helpers' journal folder, never iCloud).
        let leftover = Self.leftoverUnshown
        NoteJournal.queue.async { try? FileManager.default.removeItem(at: leftover) }
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

    /// Changes a note's front matter (or a cover's memory, `touch`) through its session, as Petal's own change: in
    /// memory and in the notes journal at once (a metadata snapshot, so quitting or switching folders never loses a
    /// helper's answer: the session's work is drained like any other), and written behind any save the person's
    /// editor has waiting (that save is made first, never under it). The editor's next save is made on it
    /// (NoteShelf.rebase: a change of metadata only never makes a conflict with the person's words). Nothing waits
    /// anywhere else. `done`: whether it landed on that paper (`.written`; a conflict copy beside it isn't).
    /// Refused (notes not ready yet: their folder being entered or switched; the paper gone or read only): nothing is
    /// written and `done` hears false; a run's result stays in the helpers' journal and is tried again (`applyHeld`),
    /// never dropped.
    func write(_ noteID: String, touch: Bool = false, _ edit: @escaping (inout NoteFile) -> Void, done: ((Bool) -> Void)? = nil) {
        guard let desk, desk.acceptsChanges, let paper = paper(noteID), !desk.store.readOnly(paper) else { done?(false); return }
        // Typing not saved yet and the helper's metadata: one snapshot, one based write (on the base it was typed on),
        // never the typing's write and then the helper's (two papers when the file changed elsewhere meanwhile).
        if let editor = desk.editors[paper.key], let typed = editor.take() {
            // (`done` is always answered: saved, or refused. Refused, the typing is the desk's to keep: NoteDesk.write.)
            let made = desk.write(paper.key, body: typed.body, base: typed.base, also: edit) { outcome in
                done?(outcome == .written)
            }
            editor.landed(made)
            return
        }
        let made = desk.store.change(paper.key, touch: touch, edit: edit) { outcome in
            done?(outcome == .written)
        }
        if made == nil { done?(false) }
    }


    // MARK: Answers kept through a conflict

    /// Answers held in the helpers' journal (a conflict, or the note not here as one paper): applied once it is.
    @ObservationIgnored private var heldAnswers: [HelperJournal.Entry] = []
    @ObservationIgnored private var applying: Set<Date> = []
    nonisolated static var journalFile: URL { NoteJournal.folder.appending(path: "helper-answers.json") }

    /// A run's result (`NoteHelp.Result`: everything it produced, as one value): journaled the moment it's made,
    /// whatever the paper's state, as one entry (composed onto one still held for that note), then written to its
    /// note in one based write when that's one writable paper, and let go from the journal only once that write
    /// landed there (`.written`; a copy kept beside it, `.keptBoth`, isn't: it stays held); in conflict (or not
    /// here), held whole and applied to whichever paper the person keeps. All of it lands, or none of it does.
    private func keep(_ run: Run, _ result: NoteHelp.Result) {
        heldAnswers = HelperJournal.adding(result, note: run.noteID, notebook: startNotebook(run), book: run.startBook, sources: run.sources, at: Date(),
                                           to: heldAnswers, busy: applying)
        saveHeld()
        applyHeld()
    }

    /// A watcher's look, through the journal as its own kind of output: only its `watch` fields (never ink, never the
    /// helper line, so it can never release a chain), landing only on the watcher it was made for.
    private func keepWatch(_ noteID: String, _ edit: @escaping (inout NoteHelp.Watch?) -> Void) {
        // Made on the note as it is now, and on the latest look held for it.
        var answer = store?.notes.first(where: { $0.noteID == noteID && $0.version == nil })?.file ?? NoteFile(id: noteID, created: Date(timeIntervalSince1970: 0))
        if let held = heldAnswers.last(where: { $0.noteID == noteID && $0.of == .watch }) {
            NoteHelp.applyAnswer(NoteFile.parse(held.answer, fallbackID: noteID, fallbackDate: held.at), to: &answer, kind: .watch)
        }
        var watch = answer.watch
        edit(&watch)
        answer.watch = watch
        let book = paper(noteID).flatMap { store?.binding($0.notebook) }
        heldAnswers = HelperJournal.adding(HelperJournal.Entry(noteID: noteID, answer: answer.serialized(), at: Date(), kind: .watch, book: book), to: heldAnswers)
        saveHeld()
        applyHeld()
    }

    /// A note's ink as it will be: the paper's, with every result still held for it.
    private func latestInk(_ noteID: String) -> [NoteHelp.Ink] {
        var file = paper(noteID)?.file ?? NoteFile(id: noteID, created: Date(timeIntervalSince1970: 0))
        for entry in heldAnswers where entry.noteID == noteID && entry.of == .answer {
            NoteHelp.applyAnswer(NoteFile.parse(entry.answer, fallbackID: noteID, fallbackDate: entry.at), to: &file)
        }
        return file.ink
    }

    /// What a run made, as its one result. A second opinion's holds only its own opinion (with the answer it
    /// reviewed), applied onto the paper's ink as it is when it lands; any other run's answer becomes the note's ink.
    private func result(_ run: Run, ink: NoteHelp.Ink?, steps: [Shielded]? = nil, also: Made = Made(), helper: NoteHelp.HelperChange) -> NoteHelp.Result {
        if let reviewed = run.reviewed { return NoteHelp.Result(opinion: ink, reviewed: reviewed, steps: steps, helper: helper) }
        return NoteHelp.Result(answer: ink, steps: steps, calc: also.calc, task: also.task, helper: helper)
    }

    /// The admission gate again, on the main actor, right before something a run produced lands: its destination note
    /// and every source as they are now (a source moved into a Private notebook while the AI worked, the note moved,
    /// an app made private). Nil: it lands; else why not: the run ends failed with that, and what it produced is
    /// dropped. (A note in conflict isn't a refusal: its result is held whole, and asked about again when it's applied.)
    private func landing(_ run: Run) -> String? {
        switch admit(run, landing: true) {
        case .go, .wait: return nil
        case .fail(let reason): return reason
        case .rebuild: return "The apps you keep private changed while it worked. Ask again."
        }
    }

    /// A run's turn on the way (its answer so far): shielded whole before anything touches it, then through the gate
    /// and on the note, its helper line kept. While the vault can't be read nothing is held: the run fails (`end`),
    /// the output dropped unshown, its line runnable again.
    private func turnOutput(_ run: Run, _ said: Said) {
        Self.shieldSaid(said) { made in
            guard run.token.completion == nil, self.runs[run.noteID] === run else { return }
            guard let made else { return self.end(run, .failed(Self.vaultWords.text)) }
            if let refused = self.landing(run) { return self.end(run, .failed(refused)) }
            self.keep(run, self.result(run, ink: made.ink, steps: made.steps, helper: .keep))
        }
    }

    /// A failed run's reason on its note, shielded whole; while the vault can't be read only Petal's own words say
    /// why (the reason itself dropped unshown).
    private func failureOutput(_ run: Run, _ said: Said) {
        let mac = self.mac
        Self.shieldSaid(said) { made in
            var ink = made?.ink ?? NoteHelp.Ink(who: said.who, text: Self.vaultWords)
            if made == nil, said.settings { ink.link = NoteHelp.settingsLink }
            let failed = NoteHelp.Helper(state: .failed, who: run.who, step: ink.text, asked: run.asked, mac: mac, at: Date())
            self.keep(run, self.result(run, ink: ink, steps: made?.steps, helper: .set(failed)))
        }
    }

    /// What Petal says when the vault can't be read: no run starts, and one under way fails.
    static let vaultWords: Shielded = "Petal can't check for your saved passwords right now. Try again in a moment."
    nonisolated static var leftoverUnshown: URL { NoteJournal.folder.appending(path: "helper-unshown.json") }

    /// Whether the vault's redaction is settled and readable now (off the main thread): a run starts only then.
    static func vaultReady(_ done: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ready = VaultIndex.settled { !$0.unreadable } ?? false
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ready) } }
        }
    }

    /// A helper's output through the vault's redaction, off the main thread (nil while the vault can't be read).
    static func shieldSaid(_ said: Said, _ done: @escaping @MainActor ((ink: NoteHelp.Ink, steps: [Shielded])?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let made = VaultIndex.settled { index in NoteHelp.shielded(said, index: index) } ?? nil
            let box = MadeBox(made)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(box.value) } }
        }
    }

    private final class MadeBox: @unchecked Sendable {
        let value: (ink: NoteHelp.Ink, steps: [Shielded])?
        init(_ value: (ink: NoteHelp.Ink, steps: [Shielded])?) { self.value = value }
    }

    /// Held results whose note is one writable paper now: applied in order, each in one write, and let go once it
    /// landed. A run's result is asked about once more right before it lands here (it may have waited through a
    /// conflict): its note still in the notebook it ran in, every note it read still readable from there; else it's
    /// dropped, and the note says why.
    func applyHeld() {
        // Only once notes take changes (their folder entered, its first read in): until then everything stays held.
        guard let desk, desk.acceptsChanges else { return }
        var busy = Set(heldAnswers.filter { applying.contains($0.at) && $0.of == .answer }.map(\.noteID))
        for entry in heldAnswers where !applying.contains(entry.at) {
            // One at a time per note, in the order they were made.
            if entry.of == .answer, busy.contains(entry.noteID) { continue }
            // Made in another notes' folder than the one in use: it waits for its own, never applied here.
            if let book = entry.book, case .otherRoot = desk.store.resolve(book) { continue }
            let papers = store?.notes.filter { $0.noteID == entry.noteID } ?? []
            let readOnly = papers.first.map { desk.store.readOnly($0) } ?? true
            guard NoteHelp.answerTarget(papers: papers.count, readOnly: readOnly) == .write else { continue }
            if entry.of == .answer, let refused = heldRefusal(entry, on: papers[0]) {
                heldAnswers.removeAll { $0 == entry }
                saveHeld()
                refuseHeld(entry, refused)
                continue
            }
            let held = NoteFile.parse(entry.answer, fallbackID: entry.noteID, fallbackDate: entry.at)
            applying.insert(entry.at)
            if entry.of == .answer { busy.insert(entry.noteID) }
            write(entry.noteID, { NoteHelp.applyAnswer(held, to: &$0, kind: entry.of) }) { landed in
                self.applying.remove(entry.at)
                guard landed else { return }
                self.heldAnswers.removeAll { $0 == entry }
                self.saveHeld()
                // What was made after it for the same note goes next.
                if self.heldAnswers.contains(where: { $0.noteID == entry.noteID }) { self.applyHeld() }
            }
        }
    }

    /// Why a held result may not land on `paper` now (the same gate as at its run's end, from what's true now), or nil.
    private func heldRefusal(_ entry: HelperJournal.Entry, on paper: PaperNote) -> String? {
        var facts = NoteHelp.GateFacts()
        facts.landing = true
        facts.notebook = paper.notebook
        // Its notebook as it's named now (its binding followed through a rename); not surely found, the name it had.
        if let book = entry.book, case .found(let name)? = store?.resolve(book) {
            facts.startNotebook = name
        } else {
            facts.startNotebook = entry.notebook ?? paper.notebook
        }
        facts.privateBooks = store?.privateBooks ?? []
        facts.sources = (entry.sources ?? []).map { id in (id, self.paper(id)?.notebook) }
        if case .fail(let reason) = NoteHelp.admit(facts) { return reason }
        return nil
    }

    /// A held result refused at the last moment: dropped, the note saying why (Petal's own words) and that no helper
    /// is at work there any more.
    private func refuseHeld(_ entry: HelperJournal.Entry, _ reason: String) {
        let mac = self.mac
        let who = Self.petalWho + " · couldn't finish"
        Self.shieldSaid(Said(who: who, text: reason, form: .failure)) { made in
            let ink = made?.ink ?? NoteHelp.Ink(who: who, text: Self.vaultWords)
            let failed = NoteHelp.Helper(state: .failed, who: Self.petalWho, step: ink.text, asked: "", mac: mac, at: Date())
            self.write(entry.noteID) { NoteHelp.Result(answer: ink, helper: .set(failed)).apply(to: &$0) }
        }
    }

    private func saveHeld() {
        let entries = heldAnswers
        let file = Self.journalFile
        NoteJournal.queue.async { _ = HelperJournal.save(entries, to: file) }
    }

    /// The one way Petal replies on a note other than a run's end: a refusal, or something done there without a run
    /// (remembered, watching, put back). A faint word on the note; its ink, PR link, proof and helper line stay as
    /// they are (never `done`, so nothing waiting on the note starts). `giveBack`: the line refused, made runnable
    /// again so Return asks once it can be done (nil when it was done, or never taken).
    /// Its words are `Shielded` (the type takes nothing raw): Petal's own words as a literal, or made from `parts`
    /// (names, titles, words from the line, paths), each shielded whole first and derived after (a title from a
    /// note's whole body); the vault unreadable, it says only that.
    private func reply(_ noteID: String, giveBack line: NoteLine?, _ parts: [String] = [], _ words: @escaping @MainActor ([Shielded]) -> Shielded) {
        line?.again()
        let keep = line != nil
        guard !parts.isEmpty else { return hint(noteID, words([]), keep: keep) }
        Self.shield(parts) { shown in self.hint(noteID, shown.map(words) ?? Self.vaultWords, keep: keep) }
    }


    /// Whole texts through NoteShield, off the main thread (nil while the vault can't be read).
    static func shield(_ texts: [String], _ done: @escaping @MainActor ([Shielded]?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let made = VaultIndex.settled { index in NoteShield.shield(texts, index: index) } ?? nil
            DispatchQueue.main.async { MainActor.assumeIsolated { done(made) } }
        }
    }

    // MARK: How every run ends

    /// What a run made besides its words: a recalculation's formula, a task put away. Part of its one result.
    struct Made {
        var calc: NoteHelp.Calc?
        var task: [NoteHelp.TaskItem]?
    }

    /// How a run ends: what it said as it arrived (`Said`, shielded before anything touches it; nil: nothing to
    /// say) with whatever else it made, why it failed (shielded the same way), or Petal's own words when it was stopped.
    enum Ending {
        case succeeded(Said?, Made = Made())
        case failed(String, settings: Bool = false)
        case stopped(Shielded?)
    }

    /// The one way every run ends, whatever its kind (a chat helper, a coding one, a second opinion, a quick one:
    /// recalculate or put away, a watcher's look): its token completes exactly once; it's let go (its agent, its
    /// place in `runs` or among the looks); everything it produced lands as one result (`keep`: one journal entry,
    /// one based write, or nothing; a second opinion's is only its own opinion), with `helper: done` only on success,
    /// `failed` with its reason, cleared when stopped (a look writes only a hit, and never over another run at work
    /// there); and its lines are passed on: success keeps its own line used and hands on what was asked of it (a
    /// second opinion, with that one's line), while anything said to it and never sent gives its line back; a failure
    /// or stop gives its own line back too.
    private func end(_ run: Run, _ ending: Ending) {
        let noteID = run.noteID
        let look = run.kind.apart
        // Once per token: an end for a run that already ended returns at once.
        guard run.token.completion == nil, runs[noteID] === run || look else { return }
        switch ending {
        case .succeeded(let said, let also):
            // A run succeeds when its answer is accepted and shown, not when its AI finished: shielded first. While
            // the vault can't be read nothing is held: it fails, the answer dropped unshown, its line runnable again.
            guard !look, let said else { return complete(run, made: nil, also) }
            Self.shieldSaid(said) { made in
                guard run.token.completion == nil, self.runs[noteID] === run else { return }
                guard let made else { return self.end(run, .failed(Self.vaultWords.text)) }
                self.complete(run, made: made, also)
            }
        case .failed(let reason, let settings):
            guard run.token.complete(.failed(reason)) else { return }
            release(run)
            letGo(run)
            guard !look else { return }
            // Its reason is shielded like anything a helper produced (a key, a sign-in: Settings › Petal AI's button on it).
            let opinion = run.reviewed != nil
            failureOutput(run, Said(who: opinion ? run.who : run.who + " · couldn't finish", text: opinion ? "No second opinion: " + reason : reason,
                                    form: .failure, settings: settings))
        case .stopped(let words):
            halt(run)
            letGo(run)
            guard !look else { return }
            keep(run, result(run, ink: words.map { NoteHelp.Ink(who: run.who, text: $0) }, helper: .clear))
        }
    }

    /// The success completion, once its answer is shielded (`made`; nil: nothing to say), on the main actor: the gate
    /// is asked again from what's true now (`landing`: a source that went Private while the AI worked, the note
    /// moved: the run ends failed with a plain reason and nothing it produced is published); then its token
    /// completes, it's let go, its line stays used, and everything it made lands as one result with `helper: done`.
    /// A finished answer always lands, paused or not: Pause stops only what would happen next, so a paused run hands
    /// nothing on (every line asked of it is given back); otherwise what was asked of it is handed on (a second
    /// opinion, with its own line) while anything else asked of it gives its line back (`FollowUpQueue.settle`).
    private func complete(_ run: Run, made: (ink: NoteHelp.Ink, steps: [Shielded])?, _ also: Made) {
        let look = run.kind.apart
        guard run.token.completion == nil, runs[run.noteID] === run || look else { return }
        if !look, let refused = landing(run) { return end(run, .failed(refused)) }
        let paused = run.token.paused
        guard run.token.complete(.succeeded) else { return }
        release(run)
        run.line = nil
        let next = handOn(run, paused: paused)
        // A watcher's look never writes ink or the helper line (its output is its `watch`, `keepWatch`).
        guard !look else { return }
        let done = NoteHelp.Helper(state: .done, who: run.who, step: "", asked: run.asked, mac: mac, at: Date())
        keep(run, result(run, ink: made?.ink, steps: made?.steps, also: also, helper: .set(done)))
        next?()
    }

    /// A run that failed (a refusal, a launch error, a guard, nothing found): `end` with its reason.
    private func fail(_ run: Run, _ reason: String, settings: Bool = false) { end(run, .failed(reason, settings: settings)) }

    /// A run's name among the runs sharing its note's hidden display.
    nonisolated static func displayRun(_ token: RunToken) -> String { "run-" + token.id }

    /// A run no longer holds its note's hidden display (it ended, or was paused): with the note's last run the
    /// display goes. `after`: once whatever this run hands on has begun (a second opinion keeps the display).
    private func leaveDisplay(_ run: Run, after: Bool) {
        let names = [Self.displayRun(run.token)] + (run.sticky.map { [$0.id.uuidString] } ?? [])
        let leave = { for name in names { PetalApp.shared.displays.ended(name) } }
        if after { DispatchQueue.main.async { MainActor.assumeIsolated { leave() } } } else { leave() }
    }

    /// A run ended: out of `runs` (or the looks), its agent gone.
    private func release(_ run: Run) {
        if runs[run.noteID] === run {
            runs[run.noteID] = nil
            tokens.finish(run.noteID, run.token)
        }
        if run.kind == .look {
            looks.finish(run.noteID, run.token)
            looking.remove(run.noteID)
        }
        if run.kind == .lens {
            lenses.finish(run.noteID, run.token)
            if lensAt[run.noteID] === run { lensAt.removeValue(forKey: run.noteID) }
        }
        // Its hold on its note's hidden display goes, once whatever it hands on has begun.
        leaveDisplay(run, after: true)
        retire(run)
        // Its calls waiting in the quick queue are dropped on the next pass (asked later, never from inside one).
        app.brain.resume()
    }

    /// What was asked of a run while it worked, handed on once it succeeded: a second opinion asked meanwhile (with
    /// its own line, held by the reviewer's run until that succeeds), else the one its own line asked for. Taken now;
    /// started once the answer is on the note. `paused`: nothing is handed on, and every line asked of it is given back.
    private func handOn(_ run: Run, paused: Bool) -> (@MainActor () -> Void)? {
        // (A look has nothing asked of it; this only hands on, the run already ended.)
        let noteID = run.noteID
        if run.kind.apart { dropFollowUps(run.token); return nil }
        let settled = followUps.settle(note: noteID, token: run.token, succeeded: !paused)
        for line in settled.dropped { line.again() }
        guard !paused else { return nil }
        let asked = settled.review
        guard let model = asked?.model ?? run.holes else { return nil }
        let line = asked?.line
        let words = asked?.asked ?? run.asked
        return {
            guard let paper = self.paper(noteID) else { line?.again(); return }
            self.taking = line
            defer { self.taking = nil }
            self.secondOpinion(paper, model, asked: words, tree: run.tree)
        }
    }

    /// A run that failed or was stopped: its line is dirty again (Return runs it), and so are the lines of what was
    /// said to it and never sent.
    private func letGo(_ run: Run) {
        run.line?.again()
        run.line = nil
        dropFollowUps(run.token)
    }

    /// What was said to a run that ended, never sent: its lines may run again.
    private func dropFollowUps(_ token: RunToken) {
        for line in followUps.settle(note: "", token: token, succeeded: false).dropped { line.again() }
    }

    // MARK: Runs (rule A)

    /// A run, registered before anything is set up. It holds every grant its note was given on this Mac (follow-ups
    /// use them too), so taking any of them back stops it. What was running on the note before is stopped first.
    private func begin(_ paper: PaperNote, asked: String, step: String, who: String = NoteHelpers.petalWho) -> Run {
        if let old = runs[paper.noteID] { end(old, .stopped(nil)) }
        let run = Run(token: tokens.start(paper.noteID), noteID: paper.noteID, asked: asked, who: who)
        bindActions(run)
        run.line = taking
        taking = nil
        run.startNotebook = paper.notebook
        run.startBook = store?.binding(paper.notebook)
        for stamp in paper.file.stamps where stamp.mac == mac { run.token.hold(stamp.grant) }
        // Everything this note starts shares one hidden display (RunDisplays): a second opinion begun as the run it
        // reviews ends keeps the display that run had.
        let token = run.token
        app.displays.join(Self.displayRun(token), group: RunDisplayRules.group(caller: "", paper: paper.noteID)) { token.state == .running }
        runs[paper.noteID] = run
        working(paper.noteID, step: step, asked: asked, who: who)
        return run
    }

    /// What the run does in the person's apps ends first, synchronously, on every change of its token's state
    /// (`RunToken.actions`: Pause, a tool's park, Stop, a failure, its end), whichever path changed it: ComputerUse
    /// closes its turn there, fails what it had waiting and answers its card Don't. (Every press, key and fill of the
    /// run also reads the token itself right before it acts: `Acting.Cancel(run:)`.)
    private func bindActions(_ run: Run) {
        run.token.actions { [weak self, weak run] in
            // Synchronously where the state changed (the main thread, for Pause, park, Stop and every end); from
            // anywhere else, as soon as the main thread can (the token itself already stops every effect).
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.endActions(run) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.endActions(run) } }
            }
        }
    }

    private func endActions(_ run: Run?) {
        guard let caller = run?.sticky?.id.uuidString else { return }
        app.assist.computer.end(caller)
    }

    /// The notebook a run began in, as it's named now: its binding followed (NoteShelf.notebookFor, so a notebook
    /// renamed while it worked isn't a note moved); not surely found, the name it had.
    private func startNotebook(_ run: Run) -> String {
        if let book = run.startBook, case .found(let name)? = store?.resolve(book) { return name }
        return run.startNotebook
    }

    /// Whether a continuation of `run` may go on: it's still the note's run, and its token admits.
    private func live(_ run: Run) -> Bool { runs[run.noteID] === run && run.token.admits }

    /// Still that run (the note's, or a watcher's look), not ended: paused or not. What a finished answer needs to land.
    private func mine(_ run: Run) -> Bool { run.token.completion == nil && (runs[run.noteID] === run || run.kind.apart) }

    /// Stops a run where it is: its token cancelled (its processes ended, nothing of it admitted again), its card
    /// answered Don't, its turn still waiting withdrawn.
    private func halt(_ run: Run) {
        run.token.complete(.stopped)
        dropFollowUps(run.token)
        run.call = nil
        if let sticky = run.sticky {
            app.assist.decline(owner: sticky.id.uuidString)
            _ = sticky.agent.withdrawWaiting()
            if sticky.agent.running { sticky.agent.stop() }
            // What it was doing in apps, and what it was allowed there, go with it.
            app.assist.computer.end(sticky.id.uuidString, forget: true)
        }
        release(run)
    }

    /// A run stopped (its turn interrupted, its chain's start not recorded): ended as stopped, and the note says
    /// no helper is at work.
    private func stopped(_ run: Run, saying words: Shielded? = nil) { end(run, .stopped(words)) }

    /// Stop, wherever it's pressed (the note, the AI button's preview, the pointer's Stop): the run ends where it is,
    /// its helper line cleared and nothing else written (the note's ink stays as it was; a faint "Stopped." says so).
    /// Nothing waiting on it moves.
    func stop(_ noteID: String) {
        looks.cancel(noteID)
        if let run = runs[noteID] {
            let quick = run.kind == .quick
            end(run, .stopped(nil))
            if !quick { reply(noteID, giveBack: nil) { _ in "Stopped." } }
            return
        }
        // No run here (a chain waiting, or a helper left at work by a Petal that quit): its waiting ends.
        if paper(noteID)?.file.helper?.state != .done {
            letGo(NoteHelp.Standing.chain, on: noteID)
            write(noteID) { $0.helper = nil; $0.chain = nil }
        }
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
            return end(run, .stopped("Stopped: this can't be paused. Ask again to start it over."))
        }
        guard run.token.pause() else { return }
        // Paused, it holds no hidden display: Go on gets one again when it next opens something.
        leaveDisplay(run, after: false)
        if let sticky = run.sticky { app.assist.decline(owner: sticky.id.uuidString) }
        write(noteID) { file in file.helper?.state = .waiting; file.helper?.step = "Paused" }
    }

    /// A run begun again from its line (a rebuild, Go on before its agent started): the new run holds the same line.
    private func again(_ run: Run) {
        let restart = run.restart
        let line = run.line
        halt(run)
        taking = line
        defer { taking = nil }
        restart?()
    }

    /// Go on: the token admits again; a turn that never started (it waited for room or its gate, or was paused while
    /// it was being made) is started now, from its sources as they are now; a turn the pause ended goes on in the same
    /// session (with `words`, the person's line as written, when they said something).
    private func goOn(_ run: Run, saying words: String? = nil, line: NoteLine? = nil) {
        let action = NoteHelp.goOn(launched: run.launched && run.sticky != nil, waitingTurn: run.call != nil, restartable: run.restart != nil)
        switch action {
        case .restart, .stopped:
            // Its agent never started (a quick run, or one paused in setup): begun again from its line, as a new run.
            again(run)
        case .startWaiting:
            guard run.token.goOn(), let call = run.call else { return }
            write(run.noteID) { file in file.helper?.state = .working; file.helper?.step = "Going on" }
            app.brain.resume()
            // What's said now is said after the turn that waited.
            if let words { followUps.add(words, note: run.noteID, token: run.token, line: line) }
            start(run, call)
        case .carryOn:
            guard run.token.goOn(), let sticky = run.sticky else { return }
            write(run.noteID) { file in file.helper?.state = .working; file.helper?.step = "Going on" }
            app.brain.resume()
            if sticky.agent.running {
                if let words { followUps.add(words, note: run.noteID, token: run.token, line: line) }
            } else if let words {
                followUp(run, words, line: line)
            } else {
                start(run, turn(run, said: nil))
            }
        }
    }

    /// A follow-up's turn started: the run now holds its line, until that turn succeeds (runnable again if it fails).
    private func followUp(_ run: Run, _ words: String, line: NoteLine?) {
        if let line { run.line = line }
        start(run, turn(run, said: words))
    }

    // MARK: Return on an @ line

    /// The person pressed Return at the end of `line` in the note `key`, a line the person wrote or edited and that
    /// hasn't run since (`at`, its identity in the editor: NoteLine; the editor hands nothing else). Taking it marks
    /// it ran; a run that fails or is stopped, a local refusal, or a follow-up never sent makes it runnable again.
    func returned(_ key: String, line: String, at ticket: NoteLine) {
        guard let desk, NoteHelp.calls(line) else { return }
        // Notes not ready yet (their folder being entered or switched): no helper starts, said plainly; the line
        // stays runnable. Asked first: the note's paper isn't in the store until its folder's first read is in.
        guard desk.takesChanges() else { return }
        guard let paper = desk.store.paper(key), paper.version == nil else { return }
        let noteID = paper.noteID
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Refused here, before anything is taken: the line stays runnable.
        guard !desk.store.readOnly(paper) else { return reply(noteID, giveBack: nil) { _ in "This note has two versions: keep one before asking a helper." } }
        // A bare @Petal asks nothing: refused before any run is registered, with a faint hint.
        if NoteHelp.bare(trimmed) { return reply(noteID, giveBack: nil) { _ in NoteHelp.bareHint } }
        // A note whose id isn't lasting yet (written by hand, or its id still being written): its id lands first, and
        // only then is anything registered for it.
        guard NoteShelf.lasting(noteID, pending: desk.store.pendingIDs) else {
            return desk.store.ensureID(key) { id in
                guard let id, let paper = desk.store.notes.first(where: { $0.noteID == id }) else {
                    return self.reply(noteID, giveBack: nil) { _ in "Petal couldn't give this note its id yet. Press Return again in a moment." }
                }
                self.returned(paper.key, line: line, at: ticket)
            }
        }
        // Nothing starts unless the vault's redaction is settled and readable: refused, the line still runnable.
        Self.vaultReady { ready in
            guard ready else { return self.reply(noteID, giveBack: nil) { _ in Self.vaultWords } }
            guard let paper = desk.store.paper(key), paper.noteID == noteID, !desk.store.readOnly(paper) else { return }
            self.take(paper, trimmed, at: ticket)
        }
    }

    /// A line taken (the vault readable): it's used now, and whatever it asks begins holding it.
    private func take(_ paper: PaperNote, _ trimmed: String, at ticket: NoteLine) {
        let noteID = paper.noteID
        ticket.take()
        // The run this line begins holds it (runnable again if it fails or is stopped).
        taking = ticket
        defer { taking = nil }
        let request = NoteHelp.request(trimmed, now: Date())
        // Stop watching, pause, remember, forget, bring back, put away: done on the note at once, never a follow-up.
        if NoteHelp.isControl(request) { return control(paper, request, asked: trimmed) }
        // A coding helper's follow-up goes to its run only for its own checkout; naming another starts a new run (its
        // own checkout choice and Allow), never sent to the existing agent.
        // Any follow-up naming another AI or model than the run's (or another checkout) starts its own run (or fails
        // "not set up"), never steering the current one.
        if let run = runs[noteID], run.launched, run.sticky != nil, run.token.admits || run.token.paused,
           NoteHelp.followUpTarget(runCheckout: run.checkout, runProvider: run.provider, runModel: run.model, words: trimmed, home: NSHomeDirectory()) == .same {
            // At work (or paused): what's said now steers it in the same session. Kept as the person wrote it (a raw
            // source, like every waiting call's) and shielded only when its turn starts (`start`).
            if run.token.paused { return goOn(run, saying: trimmed, line: ticket) }
            guard let agent = run.sticky?.agent else { return ticket.again() }
            // While it works (or its turn waits to start), said after that turn, with its run's token and its line; else now.
            if agent.running || run.call != nil { followUps.add(trimmed, note: noteID, token: run.token, line: ticket) } else { followUp(run, trimmed, line: ticket) }
            return
        }
        // "Have <model> look for holes" is its own request: a second opinion against the run's work (scheduled after a
        // run at work, else now against its last answer and worktree), or "not set up"; never steering the agent.
        if let model = NoteHelp.models(trimmed).first(where: { $0.holes }), runs[noteID] != nil || !paper.file.ink.isEmpty {
            return review(paper, model, asked: trimmed)
        }
        switch request {
        case .watch: watch(paper, asked: trimmed)
        case .recalculate: recalculate(paper, asked: trimmed)
        case .chain(let after, _, let then): chain(paper, after: after, then: then, asked: trimmed)
        case .check(let against): check(paper, against: against, asked: trimmed)
        case .morning(let time): morning(paper, time: time, asked: trimmed)
        case .done where paper.file.worktree != nil: askToRemoveWorktree(paper, asked: trimmed)
        case .done, .ask: ask(paper, trimmed, asked: trimmed)
        case .bringBack, .askWhen, .remember, .forget, .putAway, .stopWatching, .stopMorning, .pause: control(paper, request, asked: trimmed)
        }
    }

    /// Requests done on the note at once (NoteHelp.isControl), also while a helper works there: never sent to it as a
    /// follow-up. What they say then shows faintly on the note, leaving the helper's ink and line alone (`say`).
    private func control(_ paper: PaperNote, _ request: NoteHelp.Request, asked: String) {
        let noteID = paper.noteID
        switch request {
        case .bringBack(let date, _, let others): bringBack(paper, date: date, others: others, asked: asked)
        case .askWhen: reply(noteID, giveBack: taking) { _ in "When? Say a day or a time, like “Friday 9:00” or “in 2 hours”." }
        case .remember(let item): remember(paper, item, asked: asked)
        case .forget(let words): forget(paper, words, asked: asked)
        case .putAway:
            // Its own quick run would stop the helper at work: refused while one works (the line stays dirty).
            if runs[noteID] != nil { return reply(noteID, giveBack: taking) { _ in "A helper is at work on this note: stop it first, then put this away." } }
            putAway(paper, asked: asked)
        case .stopWatching:
            looks.cancel(noteID)
            looking.remove(noteID)
            letGo(NoteHelp.Standing.watch, on: noteID)
            write(noteID) { $0.watch = nil }
            reply(noteID, giveBack: nil) { _ in "Stopped watching." }
        case .stopMorning:
            guard let cover = coverToChange(paper, none: { _ in "This notebook has no cover to keep that on." }) else { return }
            letGo(NoteHelp.Standing.morning, on: cover.noteID)
            write(cover.noteID) { $0.morning = nil }
            reply(noteID, giveBack: nil, [paper.notebook]) { "No more morning notes from \($0[0])." }
        case .pause:
            if let run = runs[noteID] {
                if !run.token.paused { pause(noteID) }
            } else if paper.file.watch.map({ !$0.paused }) == true {
                pause(noteID)
            } else {
                reply(noteID, giveBack: taking) { _ in "Nothing is at work on this note." }
            }
        default: break
        }
    }

    // MARK: Things said in words, done without an AI

    private func bringBack(_ paper: PaperNote, date: Date, others: [String], asked: String) {
        var bodies: [String] = []
        for name in others {
            guard let other = note(named: name, from: paper) else { continue }
            bodies.append(other.file.body)
            write(other.noteID) { $0.back = date }
        }
        write(paper.noteID) { $0.back = date }
        let when = String(NoteHelp.backLine(date, now: Date()).dropFirst(5))
        // Their titles derived from their whole bodies, shielded.
        reply(paper.noteID, giveBack: nil, [when] + bodies) { shown in
            let titles = Shielded.joined(shown.dropFirst().map(\.title), separator: ", ")
            return shown.count > 1 ? "This note and \(titles) will be in front of you \(shown[0])." : "This note will be in front of you \(shown[0])."
        }
    }

    private func remember(_ paper: PaperNote, _ item: String, asked: String) {
        guard !item.isEmpty else { return reply(paper.noteID, giveBack: taking) { _ in "Remember what? Say it after “remember”." } }
        guard let cover = coverToChange(paper, none: { "\($0) has no cover yet to remember it on." }) else { return }
        let line = taking
        write(cover.noteID, touch: true, { $0.body = NoteHelp.remember($0.body, item) }) { landed in
            // "remember to … Friday" is kept for the notebook, not a reminder: said so, with how to be reminded.
            let todo = item.lowercased().hasPrefix("to ") && NoteHelp.when(item, now: Date()) != nil
            self.reply(paper.noteID, giveBack: landed ? nil : line, [paper.notebook, item]) {
                !landed ? "Petal couldn't write it on \($0[0])'s cover just now."
                    : todo ? "Remembered for this notebook. To be reminded, say “remind me Friday”."
                    : "Remembered for \($0[0]): \($0[1])."
            }
        }
    }

    private func forget(_ paper: PaperNote, _ words: String, asked: String) {
        guard let cover = coverToChange(paper, none: { "\($0) has no cover, so there's nothing to forget." }) else { return }
        let removed = NoteHelp.forget(cover.file.body, words).removed
        guard !removed.isEmpty else { return reply(paper.noteID, giveBack: taking, [paper.notebook, words]) { "Nothing in \($0[0])'s memory says “\($0[1])”." } }
        let line = taking
        write(cover.noteID, touch: true, { $0.body = NoteHelp.forget($0.body, words).cover }) { landed in
            // What was forgotten, said from the words asked (shielded), never lines cut out of the cover.
            self.reply(paper.noteID, giveBack: landed ? nil : line, [paper.notebook, words]) {
                landed ? "Forgot what \($0[0]) remembered about “\($0[1])”." : "Petal couldn't change \($0[0])'s cover just now."
            }
        }
    }

    /// A watcher, read from the line only once it's shielded (what it watches for is derived from the redacted words,
    /// so what's kept and told later never holds part of a secret).
    private func watch(_ paper: PaperNote, asked: String) {
        guard let url = page(of: paper) else {
            return reply(paper.noteID, giveBack: taking) { _ in "Watch what? Stick this note to the page to watch first." }
        }
        let line = taking
        var raw = Raw()
        raw.ask = asked
        Self.tell(raw) { told, _ in
            guard let told else { return self.reply(paper.noteID, giveBack: line) { _ in Self.vaultWords } }
            guard let words = told.ask.watch else {
                return self.reply(paper.noteID, giveBack: line) { _ in "Petal couldn't tell what to watch for in those words." }
            }
            var watch = NoteHelp.Watch(every: words.every, line: words.line.text, mac: self.mac, at: words.at, url: url)
            // Its clock is the one it was said in; its id is new (a look of an older watcher writes nothing back).
            watch.tz = TimeZone.current.identifier
            watch.id = UUID().uuidString
            if let old = self.paper(paper.noteID)?.file.watch, old.url == url { watch.last = old.last; watch.history = old.history; watch.hint = old.hint }
            self.looks.cancel(paper.noteID)
            self.looking.remove(paper.noteID)
            // The person's own line set it up here: this Mac keeps it, and only then does its clock look.
            self.keepGoing(NoteHelp.Standing(watch, on: paper.noteID))
            self.write(paper.noteID) { $0.watch = watch }
            self.reply(paper.noteID, giveBack: nil, [NoteText.host(url), NoteHelp.cadence(every: words.every, at: words.at).lowercased()]) {
                "Watching \($0[0]) \($0[1]) on this Mac. Petal tells you here when it's \(words.line)."
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self.look(paper.noteID) } }
        }
    }

    private func morning(_ paper: PaperNote, time: String, asked: String) {
        guard let cover = coverToChange(paper, none: { "\($0) has no cover to keep that on." }) else { return }
        let mac = self.mac
        keepGoing(NoteHelp.Standing(morning: time, on: cover.noteID))
        write(cover.noteID) { $0.morning = (time, mac) }
        reply(paper.noteID, giveBack: nil, [time, paper.notebook]) { "Every morning at \($0[0]), \($0[1]) leaves you a note on this Mac." }
    }

    /// "when @Research is done, draft @Proposal": the notes are found by name here; what it asks is derived only from
    /// the shielded line (kept, and told when it fires, never holding part of a secret).
    private func chain(_ paper: PaperNote, after: String, then: String?, asked: String) {
        guard let first = note(named: after, from: paper) else {
            return reply(paper.noteID, giveBack: taking, [after]) { "Petal couldn't find one note called “\($0[0])”." }
        }
        guard let target = then.map({ note(named: $0, from: paper) }) ?? paper else {
            return reply(paper.noteID, giveBack: taking, [then ?? ""]) { "Petal couldn't find one note called “\($0[0])”." }
        }
        // The note that runs reads the one it waits for: only one it may read (the gate's rule, checked again when it fires).
        guard mayRead(first.notebook, from: target) else {
            return reply(paper.noteID, giveBack: taking) { _ in "The note that would run can't read the one it waits for (it's in a private notebook), so nothing was set up." }
        }
        // Never a loop: no note ends up waiting, through others, for itself.
        let edges = (store?.notes ?? []).compactMap { note in note.file.chain.map { (waiting: note.noteID, on: $0.after) } }
            .filter { $0.waiting != target.noteID }
        guard !NoteHelp.loops(edges, adding: (waiting: target.noteID, on: first.noteID)) else {
            return reply(paper.noteID, giveBack: taking) { _ in "That would make notes wait for each other in a circle, so nothing was set up." }
        }
        let line = taking
        // The line and both notes' whole bodies shielded; their titles derived after.
        var raw = Raw()
        raw.ask = asked
        raw.sources = [first.file.body, target.file.body]
        Self.tell(raw) { told, _ in
            guard let told, told.sources.count == 2 else { return self.reply(paper.noteID, giveBack: line) { _ in Self.vaultWords } }
            guard let ask = told.ask.chainAsk else { return self.reply(paper.noteID, giveBack: line) { _ in "Petal couldn't tell what to do then." } }
            let afterTitle = told.sources[0].title
            let thenTitle = told.sources[1].title
            let mac = self.mac
            let chain = NoteHelp.Chain(after: first.noteID, afterTitle: afterTitle.text, then: target.noteID, ask: ask.text, mac: mac, since: Date())
            self.keepGoing(NoteHelp.Standing(chain, on: target.noteID))
            self.write(target.noteID) { file in
                file.chain = chain
                file.helper = NoteHelp.Helper(state: .waiting, who: Self.petalWho, step: "Waiting for \(afterTitle.text)", mac: mac, at: Date())
            }
            if target.noteID != paper.noteID {
                self.reply(paper.noteID, giveBack: nil) { _ in "When \(afterTitle) is done, Petal will \(ask) on \(thenTitle)." }
            } else {
                self.write(paper.noteID) { $0.helper?.asked = asked }
            }
        }
    }

    // MARK: Rule B: what a helper tells an AI, shielded first

    /// The raw parts a helper gathers; only `tell` turns them into `NoteHelp.Told` (through NoteShield).
    /// What a helper is told, as whole sources only: the person's whole line, the note's whole body, a page's whole
    /// text, each title whole. Nothing is cut or parsed out of note text before it's shielded (Phase 1's rule,
    /// `derivable`): what a prompt needs of it (the line without its @Petal, a note's labelled numbers, what a watcher
    /// or a chain asks) is derived from the redacted text (`Shielded.spoken`, `.rows`, `.watch`, `.chainAsk`).
    struct Raw {
        var ask = ""
        var body = ""
        var notebook = ""
        var cover = ""
        var extra = ""
        var answer = ""
        var titles: [String] = []
        var line = ""
        var last = ""
        var paths: [String] = []
        var instructions = ""
        /// The person's notes for the AI: read with the rest, off the main thread.
        var instructionsFile: URL?
        var memory = ""
        var sourceBook = ""
        var sources: [String] = []
        var after = ""
        /// The notebook whose cover it reads first (resolved in `told`, never skipped when it can't be read yet).
        var coverOf: String?
        /// The note's place, and whether its app is kept private (then only what it is is told).
        var place: NoteStick?
        var placePrivate = false
    }

    /// `raw` through NoteShield, off the main thread: every part redacted whole (the place filtered for a private
    /// app first, then its words and sentence derived); nil while the vault can't be read.
    /// `stamp`: the vault's generation it was made under (`VaultIndex.unchanged(since:)` says whether it still is).
    static func tell(_ raw: Raw, _ done: @escaping @MainActor (NoteHelp.Told?, _ stamp: Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Off the main thread: the person's notes for the AI read from disk here, never on the main thread.
            let instructions = raw.instructionsFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? raw.instructions
            let made = VaultIndex.stamped { index -> NoteHelp.Told? in
                let parts = [raw.ask, raw.body, raw.notebook, raw.cover, raw.extra, raw.answer, raw.line, raw.last, instructions, raw.memory, raw.sourceBook, raw.after]
                guard let shown = NoteShield.shield(parts, index: index), let titles = NoteShield.shield(raw.titles, index: index),
                      let paths = NoteShield.shield(raw.paths, index: index), let sources = NoteShield.shield(raw.sources, index: index) else { return nil }
                // The line without its @Petal, derived after redaction.
                var told = NoteHelp.Told(ask: shown[0].spoken, body: shown[1], notebook: shown[2], cover: shown[3], extra: shown[4], answer: shown[5],
                                         titles: titles, line: shown[6], last: shown[7], paths: paths, instructions: shown[8], memory: shown[9],
                                         sourceBook: shown[10], sources: sources, after: shown[11])
                if let stick = raw.place {
                    guard let place = NoteShield.place(stick, appPrivate: raw.placePrivate, index: index) else { return nil }
                    told.place = place.words
                    told.quote = place.quote
                    told.placeIsFile = ViewerFiles.namesFile(stick)
                }
                return told
            }
            let carried = ToldBox(made?.value ?? nil)
            let stamp = made?.stamp ?? -1
            DispatchQueue.main.async { MainActor.assumeIsolated { done(carried.value, stamp) } }
        }
    }

    static let coverWait = 15

    /// A cover iCloud hasn't downloaded: asked for (off the main thread); the store reads it when it arrives.
    private func askForCover(_ notebook: String) {
        guard let folder = store?.notebooks.first(where: { $0.name == notebook })?.folder else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where NoteLibrary.isCoverName(name) || NoteHelp.isCoverPlaceholder(name) {
                let real = NoteHelp.isCoverPlaceholder(name) ? String(name.dropFirst().dropLast(7)) : name
                try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appending(path: real))
            }
        }
    }

    private final class ToldBox: @unchecked Sendable {
        let value: NoteHelp.Told?
        init(_ value: NoteHelp.Told?) { self.value = value }
    }

    // MARK: Starting (rule A): one way in for every paid call

    /// How a run's agent is launched: set once its setup is done (`setUp`), used by every turn of it.
    struct Launch {
        var kind: Run.Kind
        var provider: Provider
        var model: String
        /// Its brief, from what it's told when a turn starts.
        var brief: (NoteHelp.Told) -> Shielded
        var folder: String?
        var placed: Bool
    }

    /// A paid call as it waits (for its turn, for room, for its gate, for Go on): how its sources are read when it
    /// starts, and how its words are made from them once they're shielded. Never a finished prompt: nothing that
    /// waits holds words.
    final class Call {
        enum To {
            /// A turn of the run's own agent (`Run.launch`).
            case agent
            /// The quick AI, once: its answer, with what it was told (nil: it never started).
            case quick(key: String, provider: Provider?, done: @MainActor ([String: Any]?, NoteHelp.Told?) -> Void)
            /// No AI: only what it's made from, shielded (a quick run that says its words itself).
            case local(done: @MainActor (NoteHelp.Told) -> Void)
        }
        /// The call's own sources as they are now, on top of the note and its cover (`raw(paper)`). Nil: read; else why
        /// it can't go (one is gone).
        let sources: @MainActor (PaperNote, inout Raw) -> String?
        /// Its words, from what the sources were shielded into (nil: nothing to send).
        let words: (NoteHelp.Told) -> Shielded?
        let to: To

        init(sources: @escaping @MainActor (PaperNote, inout Raw) -> String?, words: @escaping (NoteHelp.Told) -> Shielded?, to: To) {
            self.sources = sources
            self.words = words
            self.to = to
        }
    }

    /// A turn of a run's agent (its first, a follow-up, Go on): the run's own sources read again (`Run.gather`), with
    /// what was said as the person wrote it. `words`: the first turn's request; else the line said, or Go on.
    private func turn(_ run: Run, said: String?, words: ((NoteHelp.Told) -> Shielded?)? = nil) -> Call {
        Call(sources: { [weak run] paper, raw in
            guard let run, let gather = run.gather else { return "This helper isn't running any more." }
            if let problem = gather(paper, &raw) { return problem }
            raw.ask = said ?? ""
            return nil
        }, words: words ?? { said == nil ? "Go on where you stopped." : $0.ask }, to: .agent)
    }

    /// The one way a paid call starts: a chat helper's turn (its first, a follow-up, Go on), a coding helper's, a
    /// second opinion's, a recalculation's, a task put away, a watcher's question, a chain's run. What waits is the
    /// call (`Run.call`, the agent's waiting mark, the quick AI's line), never words; right before launch `prepare`
    /// checks the vault, resolves the cover, asks the gate and builds the prompt, in that order, from the sources as
    /// they are then, and the call goes at once or not at all.
    private func start(_ run: Run, _ call: Call) {
        guard mine(run) else { return }
        run.call = call
        run.gateHeld = false
        // Paused: it waits as it is; Go on starts it. Being made already: not twice.
        guard run.token.admits, !run.starting else { return }
        switch call.to {
        case .agent:
            run.starting = true
            prepare(run, call) { prepared in
                run.starting = false
                guard self.mine(run), run.call === call, case .go(let words, let told) = prepared else { return }
                guard let launch = run.launch, let agent = run.sticky?.agent else { return self.fail(run, "Petal AI couldn't start. Ask again.") }
                // Nothing to say (an agent sends nothing empty): the run ends here, never left at work.
                guard !words.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self.fail(run, NoteHelp.bareHint.text + ".") }
                // Its whole system prompt, made only of Shielded parts (no window or tab title, no raw text), as told now.
                agent.helperSystem = NoteHelp.system(told, provider: launch.provider == .claude ? "Claude Code" : "Codex",
                                                     computerUse: self.app.config.bool("computerUse"), runDisplays: self.app.displays.on,
                                                     brief: launch.brief(told))
                if !run.launched {
                    run.from = agent.messages.count
                    run.launched = true
                    self.working(run.noteID, step: "Starting", asked: run.asked, who: run.who)
                }
                agent.send(words)
                // Begun: nothing waits. Else its agent kept only the wait (for room, or its gate at the very start),
                // and `again` starts it from its sources as they are then.
                if agent.running { run.call = nil }
            }
        case .local(let done):
            run.starting = true
            prepare(run, call) { prepared in
                run.starting = false
                guard self.mine(run), case .go(_, let told) = prepared else { return }
                run.call = nil
                done(told)
            }
        case .quick(let key, let provider, let done):
            // In the quick AI's line from here on, which holds how it's made (`make`), never its words: made when its
            // turn there comes.
            run.call = nil
            let told = ToldRef()
            app.brain.ask(key: key, token: run.token, provider: provider, gate: quickGate(run), make: { [weak self] ready in
                guard let self else { return ready(.over) }
                self.prepare(run, call) { prepared in
                    switch prepared {
                    case .go(let words, let made):
                        told.value = made
                        ready(.go(words))
                    case .wait: ready(.wait)
                    case .over(let made):
                        told.value = made
                        ready(.over)
                    }
                }
            }, done: { reply in done(reply, told.value) })
        }
    }

    private final class ToldRef { var value: NoteHelp.Told? }

    /// What `prepare` made of a call: its words (with what it was told), a wait (paused, or its gate; it's started
    /// again later), or nothing to send (the run ended, or its words came to nothing).
    private enum Prepared {
        case go(Shielded, NoteHelp.Told)
        case wait
        case over(NoteHelp.Told?)
    }

    /// Right before launch, in the one order `NoteHelp.launch` keeps, each step from what's true then; a step that
    /// fails refuses through `reply` or fails the run through `end`, and nothing after it happens:
    /// 1. the vault's redaction is settled and readable;
    /// 2. the call's sources are read, and its notebook's cover resolved through `raw(paper)` (`gather`);
    /// 3. the admission gate (rule C), on the run and its sources as they are now;
    /// 4. the prompt is built and shielded from those sources, and is still made under the vault as it is when it's
    ///    handed on (made again when a secret was saved meanwhile).
    private func prepare(_ run: Run, _ call: Call, _ then: @escaping @MainActor (Prepared) -> Void) {
        let steps = NoteHelp.LaunchSteps<Raw, NoteHelp.Told, Shielded>(
            live: { !self.mine(run) ? .gone : run.token.admits ? .running : .paused },
            vault: { ready in Self.vaultReady { ready($0) } },
            sources: { read in self.gather(run, call) { read($0) } },
            gate: {
                // What it's told is made under these private apps: a change before it's used (or lands) makes it again.
                if !run.launched { run.privacy = ClaudePanel.privacy.now }
                return self.admit(run)
            },
            build: { raw, built in
                let privacy = ClaudePanel.privacy.now
                Self.tell(raw) { told, stamp in
                    if told != nil { run.privacy = privacy }
                    built(told, VaultIndex.unchanged(since: stamp))
                }
            },
            words: call.words)
        NoteHelp.launch(steps) { launched in
            MainActor.assumeIsolated {
                switch launched {
                case .go(let words, let told): then(.go(words, told))
                case .paused: then(.wait)
                case .wait(let reason):
                    run.gateHeld = true
                    if !run.kind.apart { self.write(run.noteID) { file in file.helper?.state = .waiting; file.helper?.step = reason } }
                    then(.wait)
                case .gone, .refused: then(.over(nil))
                case .vaultUnreadable:
                    self.end(run, .failed(Self.vaultWords.text))
                    then(.over(nil))
                case .failed(let reason):
                    self.fail(run, reason, settings: reason.contains("isn't set up"))
                    then(.over(nil))
                case .rebuild:
                    self.rebuild(run)
                    then(.over(nil))
                case .nothing(let told): then(.over(told))
                }
            }
        }
    }

    /// Step 2: the call's sources as they are now, on top of the note and its notebook's cover (`raw(paper)`). No
    /// cover is none; one that's there but can't be read right now (not downloaded, unreadable, two versions) is asked
    /// of iCloud and waited for, at most `coverWait` seconds; still unreadable, the run is refused with a faint line
    /// and ends (its line given back), never run without it.
    private func gather(_ run: Run, _ call: Call, waited: Int = 0, _ done: @escaping @MainActor (NoteHelp.Gathered<Raw>) -> Void) {
        guard mine(run) else { return done(.refused) }
        guard let paper = paper(run.noteID) else { return done(.failed("This note has two versions, or was moved. Keep one, then ask again.")) }
        var raw = raw(paper)
        if let problem = call.sources(paper, &raw) { return done(.failed(problem)) }
        if let notebook = raw.coverOf {
            switch coverChoice(of: notebook) {
            case .none: raw.cover = ""
            case .one(let key): raw.cover = store?.paper(key)?.file.body ?? ""
            case .notHere, .conflict:
                guard waited < Self.coverWait else {
                    if !run.kind.apart { reply(run.noteID, giveBack: nil, [notebook]) { "Couldn't read \($0[0])'s cover yet." } }
                    end(run, .stopped(nil))
                    return done(.refused)
                }
                if waited == 0 { askForCover(notebook) }
                if !run.kind.apart { write(run.noteID) { file in if file.helper?.state == .working { file.helper?.step = "Waiting for the notebook's cover" } } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self.gather(run, call, waited: waited + 1, done) } }
                return
            }
            raw.coverOf = nil
        }
        done(.read(raw))
    }

    /// The note and its notebook's cover (only when the note may read it), as every helper reads them first.
    private func raw(_ paper: PaperNote) -> Raw {
        var raw = Raw()
        raw.body = paper.file.body
        raw.notebook = paper.notebook
        // Its cover is read when a call starts (`gather`): none, its words, or waited for when it can't be read yet.
        raw.coverOf = mayRead(paper.notebook, from: paper) ? paper.notebook : nil
        // The person's own notes for the AI and what Petal remembers: shielded too, in the helper's own system prompt.
        raw.instructionsFile = app.config.instructionsFile
        raw.memory = app.assist.memoryBrief()
        return raw
    }

    // MARK: Quick helpers (the quick AI once, then plain arithmetic or words)

    /// A quick run's AI: the one named in its line, only when it's set up ("not set up" otherwise, never another),
    /// else the chat's; held on the run, so the gate checks it again when its call starts.
    private func quickProviderOrFail(_ run: Run) -> Provider? {
        guard let provider = providerOrFail(run, for: NoteHelp.models(run.asked).first { !$0.holes }) else { return nil }
        run.provider = provider.rawValue
        return provider
    }

    /// A quick call's admission, asked by Brain right when the call would start: the same gate as every helper step
    /// (waiting: it stays queued and goes once admitted; failing: its run fails with the reason).
    private func quickGate(_ run: Run) -> () -> Bool {
        { [weak self, weak run] in
            guard let self, let run else { return false }
            switch self.admit(run) {
            case .go: return true
            case .wait: return false
            // Never ended from inside the queue's pass: later, outside it.
            case .fail(let reason):
                DispatchQueue.main.async { MainActor.assumeIsolated { self.fail(run, reason, settings: reason.contains("isn't set up")) } }
                return false
            case .rebuild:
                DispatchQueue.main.async { MainActor.assumeIsolated { self.rebuild(run) } }
                return false
            }
        }
    }

    private func recalculate(_ paper: PaperNote, asked: String) {
        let values = NoteHelp.values(paper.file.body)
        guard !values.isEmpty else { return reply(paper.noteID, giveBack: taking) { _ in "There's nothing to add up yet: write lines like “Flights: 412”." } }
        // The AI proposes the formula once from the labels of the note's redacted text only (a row that held a secret
        // left out, never the note's other words); arithmetic keeps it.
        let run = begin(paper, asked: asked, step: "Working out the formula")
        run.kind = .quick
        run.restart = { [weak self] in if let self, let paper = self.paper(paper.noteID) { self.recalculate(paper, asked: asked) } }
        guard let provider = quickProviderOrFail(run) else { return }
        // Through `start`, like every paid call: the vault, the cover, the gate, then its words from the note as it is then.
        start(run, Call(sources: { _, raw in
            raw.ask = asked
            return nil
        }, words: { $0.body.rows.isEmpty ? nil : NoteHelp.formulaRequest($0) },
        to: .quick(key: "calc|\(paper.noteID)|\(run.token.id)", provider: provider) { reply, told in
            guard self.mine(run), let told else { return }
            // Every row read from the redacted body: those left are the formula's only inputs.
            let rows = told.body.rows.map { (label: $0.label.text, value: $0.value) }
            guard !rows.isEmpty else { return self.fail(run, "Every labelled number here holds something from your vault, so nothing was sent.") }
            // Its own outcome: a formula that adds up on the note's values, else a failure with its reason.
            let outcome = NoteHelp.formulaOutcome(reply, values: rows)
            guard var calc = outcome.calc else { return self.fail(run, outcome.failure ?? "No formula came back.") }
            // What the quick AI produced is shielded whole before it's kept (its label too).
            Self.shield([calc.formula, calc.label]) { shown in
                guard self.mine(run) else { return }
                guard let shown, shown.allSatisfy({ !$0.text.contains(UIMap.hidden) }) else { return self.fail(run, "The formula couldn't be checked against your vault, so it wasn't kept.") }
                calc.formula = shown[0].text
                calc.label = shown[1].text
                // Part of the run's one result: the formula lands with `done`, in one write, or neither does.
                self.end(run, .succeeded(nil, Made(calc: calc)))
            }
        }))
    }

    /// "Put this away": the window in front's tabs, the file it shows and the mail it came from become the note's
    /// task (Open all brings them back), with a short line of where the person stopped and what's next.
    private func putAway(_ paper: PaperNote, asked: String) {
        guard let front = inFront(), front.pid != getpid(), !app.assist.neverLook(front.bundle) else {
            return reply(paper.noteID, giveBack: taking) { _ in "Petal couldn't tell what you were working on (or it's an app you keep private)." }
        }
        let run = begin(paper, asked: asked, step: "Putting the task away")
        run.kind = .quick
        run.restart = { [weak self] in if let self, let paper = self.paper(paper.noteID) { self.putAway(paper, asked: asked) } }
        guard let provider = quickProviderOrFail(run) else { return }
        let bundle = front.bundle
        let pid = front.pid
        let parts = Self.partsInFront
        let file = desk?.scene?.file ?? ""
        // The file as the disk knows it, read with the scene (its incarnation and a bookmark): what Open all finds again.
        let fileID = desk?.scene?.fileID ?? ""
        let fileBookmark = desk?.scene?.fileBookmark ?? ""
        let token = run.token
        NoteDesk.queue.async {
            guard token.admits else { return }
            var items = parts.map { $0(bundle, pid) } ?? Self.windowTabs(bundle).map { NoteHelp.TaskItem(kind: .tab, title: $0.title, target: $0.url) }
            if !file.isEmpty { items.append(NoteHelp.TaskItem(kind: .file, title: (file as NSString).lastPathComponent, target: file, bookmark: fileBookmark, fileID: fileID)) }
            if parts == nil, bundle == "com.apple.mail", let mail = Self.selectedMail() { items.append(NoteHelp.TaskItem(kind: .mail, title: mail.subject, target: mail.url)) }
            if parts == nil, items.isEmpty, let title = Self.windowTitle(pid), !title.isEmpty { items.append(NoteHelp.TaskItem(kind: .window, title: title, target: bundle)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.live(run) else { return }
                    guard !items.isEmpty else { return self.fail(run, "There was nothing to put away in that window.") }
                    // What was open (each whole: a tab's title, a file's path, a mail's subject), shielded when the
                    // call starts; the ink's chips derived from that, never from the raw titles.
                    let sources = { @MainActor (_: PaperNote, raw: inout Raw) -> String? in
                        raw.titles = items.map { $0.kind == .file ? $0.target : $0.title }
                        return nil
                    }
                    let finish = { (line: String?, told: NoteHelp.Told) in
                        guard self.mine(run) else { return }
                        let shown = zip(items, told.titles).map { item, words -> NoteHelp.TaskItem in
                            var item = item
                            if item.kind == .file { item.target = words.text } else { item.title = words.text }
                            return item
                        }
                        let plain = "Put away: \(NoteHelp.taskChips(shown).joined(separator: ", ")). Open all brings them back."
                        let who = Self.petalWho + " · put away " + NoteHelp.dayLabel(Date(), now: Date())
                        // The task is part of the run's one result: it lands with its line and `done`, or none does.
                        self.end(run, .succeeded(Said(who: who, text: line ?? plain, form: .words), Made(task: items)))
                    }
                    // With no quick AI (or none that answers): its own plain words, from the same shielded sources.
                    let plainly = { self.start(run, Call(sources: sources, words: { _ in "" }, to: .local { told in finish(nil, told) })) }
                    guard self.app.brain.enabled else { return plainly() }
                    // Where they stopped, from what was open only, by the quick AI.
                    self.start(run, Call(sources: sources, words: { NoteHelp.awayRequest($0) },
                                         to: .quick(key: "away|\(paper.noteID)|\(run.token.id)", provider: provider) { reply, told in
                        guard self.mine(run) else { return }
                        guard let told else { return self.live(run) ? plainly() : () }
                        finish(reply?["line"] as? String, told)
                    }))
                }
            }
        }
    }

    /// The app in front, whose window "put this away" puts away.
    private func inFront() -> (bundle: String, pid: pid_t)? {
        if let stand = Self.appInFront { return stand() }
        return NSWorkspace.shared.frontmostApplication.map { ($0.bundleIdentifier ?? "", $0.processIdentifier) }
    }

    /// For `Petal --helpers-check` only: a made-up app in front and the parts of its window, in place of asking
    /// macOS, the browser and Mail (a check never reads the person's own windows). Everything after is as always.
    nonisolated(unsafe) static var appInFront: (() -> (bundle: String, pid: pid_t)?)?
    nonisolated(unsafe) static var partsInFront: (@Sendable (String, pid_t) -> [NoteHelp.TaskItem])?

    /// Open all: a task's tabs, files and mail, back, by NoteTasks' rule (never an app or a script: a task can come
    /// from sync or a tool).
    func openAll(_ key: String) {
        guard let paper = store?.paper(key) else { return }
        desk?.openAll(NoteContract.taskItems(paper.file))
    }

    // MARK: Helpers that think: the chat AI, or the person's own coding AI

    /// Anything else asked: a run registered at once (or the one a chain made before it fired); then, on a page tied
    /// to a repository or a file in a checkout, the person's own coding AI in a worktree; else the chat AI on the
    /// note's place.
    private func ask(_ paper: PaperNote, _ text: String, asked: String, compare: (book: String, ids: [String])? = nil, run given: Run? = nil) {
        let models = NoteHelp.models(asked)
        let pick = models.first { !$0.holes }
        let run = given ?? begin(paper, asked: asked, step: "Starting", who: pick.map { "\(Self.petalWho) · \($0.name)" } ?? Self.petalWho)
        run.holes = models.first { $0.holes }
        run.restart = { [weak self] in
            guard let self, let paper = self.paper(paper.noteID) else { return }
            self.ask(paper, text, asked: asked, compare: compare)
        }
        let stick = here(paper).flatMap { paper.file.places.indices.contains($0) ? paper.file.places[$0] : nil } ?? paper.file.places.first
        if compare == nil, let stick, let repo = NoteHelp.repository(url: stick.url) {
            return code(run, paper, text, slug: repo.slug, number: NoteHelp.pullNumber(repo), file: nil, pick: pick)
        }
        if compare == nil, let stick, ViewerFiles.namesFile(stick) {
            // The file the place names now, by the one file resolver (its own file wherever it went, else its
            // bookmark's, else its path's), and that file's real git repository, as AgentAccess resolves a project:
            // the nearest one above it, a linked worktree's main checkout only when git made it one (so a file under
            // a T3 worktree of ~/petal is ~/petal's).
            return Self.repository(holding: stick, mac: mac) { found in
                guard self.live(run) else { return }
                if let found {
                    self.code(run, paper, text, slug: nil, number: nil, file: found, pick: pick)
                } else {
                    self.think(run, paper, text, pick: pick, compare: compare)
                }
            }
        }
        think(run, paper, text, pick: pick, compare: compare)
    }

    /// @Petal: the chat AI with Petal's tools, on the note's own place (never what happens to be in front: a note
    /// away from its window waits for it, at the gate), the notebook's cover read first.
    private func think(_ run: Run, _ paper: PaperNote, _ text: String, pick: NoteHelp.Model?, compare: (book: String, ids: [String])?) {
        guard live(run) else { return }
        guard let provider = providerOrFail(run, for: pick) else { return }
        let paper = self.paper(run.noteID) ?? paper
        // A notebook to check against: its notes' ids held on the run, so the gate checks each one's access again
        // right before anything goes, and again before anything lands. (A chain's run keeps its predecessor among them.)
        run.sources = (compare?.ids ?? []) + run.sources.filter { !(compare?.ids ?? []).contains($0) }
        // Its sources, read again whenever a turn of it starts: a chain's done note and a notebook's notes each whole,
        // as they are then, and only those this note may read then (shielded one by one before any title is taken or
        // anything cut: NoteHelp.comparison); the note's own place.
        run.gather = { [weak self, weak run] paper, raw in
            guard let self, let run else { return "This helper isn't running any more." }
            let readable = { (id: String) in self.paper(id).flatMap { self.mayRead($0.notebook, from: paper) ? $0.file.body : nil } }
            raw.after = run.after.flatMap(readable) ?? ""
            raw.sourceBook = compare?.book ?? ""
            raw.sources = (compare?.ids ?? []).compactMap(readable)
            if case .placed(let index) = NoteHelp.anchor(paper.file.places, here: self.here(paper)) {
                raw.place = paper.file.places[index]
                raw.placePrivate = self.app.assist.neverLook(paper.file.places[index].app)
            }
            return nil
        }
        setUp(run, paper, Launch(kind: .petal, provider: provider, model: pick?.id ?? "", brief: { NoteHelp.brief($0) }, folder: nil, placed: true))
        start(run, turn(run, said: text, words: { $0.ask }))
    }

    /// The notes or what's in front changed: each running helper's requirement and its tools' target are bound again
    /// in one step (`bind`): re-stuck, both follow; its place or document not showing now, its tools have no target
    /// and the gate waits (`waitingForPlace`). Called once `here` is recomputed (NoteDesk.apply), never before.
    func placesFollow() {
        for (noteID, run) in runs where run.launch != nil && run.kind.placed {
            guard let paper = paper(noteID), run.sticky != nil else { continue }
            bind(run, paper)
        }
    }

    /// Which of a note's places it's on now: its place on the file Petal's viewer shows, while the viewer has the
    /// keyboard and the note is on that file (it's the current place then, as for the note tools: NoteDesk.hereNow);
    /// else the one that fits the window in front (`here`); else its place on a file any open viewer shows (a note in
    /// a viewer's margin is on its document there, wherever the keyboard is).
    private func here(_ paper: PaperNote) -> Int? {
        let index = { (place: NoteStick?) in place.flatMap { shown in paper.file.places.firstIndex { $0.samePlace(shown) } } }
        if let front = app.viewers.front, let found = index(front.notes.first { $0.paper.key == paper.key }?.place) { return found }
        if let found = desk?.here[paper.key] { return found }
        return index(viewer(showing: paper.noteID, on: nil)?.place)
    }

    /// The open viewer whose margin holds the note (on `required`, when given: that very place, by `samePlace`), by
    /// the one file resolver's answer for the file it shows (`ViewerModel.notes`): the one with the keyboard first,
    /// then any other open one.
    private func viewer(showing noteID: String, on required: NoteStick?) -> (model: ViewerModel, place: NoteStick)? {
        let front = app.viewers.front
        for model in [front].compactMap({ $0 }) + app.viewers.open.filter({ $0 !== front }) {
            guard let place = model.notes.first(where: { $0.paper.noteID == noteID && $0.paper.version == nil })?.place else { continue }
            if required.map({ place.samePlace($0) }) ?? true { return (model, place) }
        }
        return nil
    }

    /// The run's requirement (the place it must be on) and its agent's tool target, set together from the note's
    /// places and what's in front now (NoteHelp.requirement); what it read or queued for an old target is dropped. A
    /// place is the same only by `samePlace` (a file's: the same file as the one file resolver knows it, never a path
    /// that reads alike).
    private func bind(_ run: Run, _ paper: PaperNote) {
        guard runs[run.noteID] === run, let sticky = run.sticky else { return }
        let required = run.kind.placed ? NoteHelp.requirement(paper.file.places, here: here(paper)) : nil
        let moved = !(run.requiredPlace.map { old in required.map { old.samePlace($0) } ?? false } ?? (required == nil))
        run.requiredPlace = required
        let showing = requirementShowing(run)
        let target = showing ? required.flatMap { place(of: paper, on: $0) } : nil
        let waiting = !showing && required != nil
        guard moved || sticky.agent.place != target || sticky.waitingForPlace != waiting else { return }
        sticky.agent.place = target
        sticky.waitingForPlace = waiting
        app.assist.computer.placeChanged(sticky.id.uuidString)
    }

    /// Whether the run's required place is the one showing now: from the run's own requirement, never `here`. A
    /// file's place (or a sentence in a file) by the one file resolver's answer for the window in front
    /// (`NoteMatch.fits`: the very file by its `fileID`, a file renamed is it, a path another file took isn't), or as
    /// the file an open viewer of Petal's shows (its margin's notes, resolved the same way): the document is open
    /// there, whichever window has the keyboard.
    private func requirementShowing(_ run: Run) -> Bool {
        guard let required = run.requiredPlace else { return true }
        if viewer(showing: run.noteID, on: required) != nil { return true }
        return desk?.scene.map { NoteMatch.fits(required, $0) } ?? false
    }

    /// The notes' folder is being switched away from: everything the helpers had going for its notes ends with it,
    /// whole (every run stopped, every look cancelled, nothing summoned). What a run had produced is in the helpers'
    /// journal, bound to that folder (its notebook's binding): never applied in another, waiting for its own.
    func folderSwitching() {
        for run in Array(runs.values) { end(run, .stopped(nil)) }
        for run in Array(lensAt.values) { end(run, .stopped(nil)) }
        for noteID in looking { looks.cancel(noteID) }
        looking = []
        firing = []
        summoned = []
        mornings = []
    }

    /// Petal's viewer took or gave up the keyboard, one opened or closed, or the notes on its file changed: a
    /// helper's place is what it shows now (bound again, and what waited for it goes on).
    func viewerChanged() {
        guard !runs.isEmpty else { return }
        placesFollow()
        placedNow()
    }

    /// Layout placed notes: a run waiting for its note's place goes on once its note is on the window in front.
    func placedNow() {
        // Runs parked by a tool's admission go on once it admits.
        for run in runs.values where run.parked && run.token.paused {
            if case .go = admit(run) { run.parked = false; goOn(run) }
        }
        // Quick calls waiting on their gate are asked again.
        app.brain.resume()
        // Calls the gate held, and turns that waited before their process started: once it admits, they start (and
        // are made then, from their sources as they are then).
        for run in runs.values where run.token.admits {
            if run.gateHeld, let call = run.call, case .go = admit(run) { start(run, call) }
            if run.sticky?.agent.waiting.isEmpty == false, !(run.sticky?.agent.running ?? true), case .go = admit(run) { app.claude.startWaiting() }
        }
    }

    /// A coding helper: the person's own Claude Code or Codex in their checkout, in the note's own worktree (made
    /// once, reused for its follow-ups once it's verified to be that checkout's on the note's branch), after Allow
    /// on the note once per project. `number`: a pull request's only (an issue starts from the default branch).
    private func code(_ run: Run, _ paper: PaperNote, _ text: String, slug: String?, number: Int?, file folder: (path: String, remotes: [(name: String, url: String)])?,
                      pick: NoteHelp.Model?) {
        Self.checkouts { all in
            guard self.live(run) else { return }
            let candidates = folder.map { [$0.path] } ?? slug.map { NoteHelp.checkouts(for: $0, among: all) } ?? []
            // A checkout named in the person's words is always checked, however many fit.
            let checkout: String
            switch NoteHelp.chooseCheckout(candidates, words: run.asked, home: NSHomeDirectory()) {
            case .one(let one): checkout = one
            case .none: return self.fail(run, "Petal couldn't find a checkout of \(slug ?? "this repository") in your home folder.")
            case .mismatch(let named):
                return self.fail(run, "\((named as NSString).abbreviatingWithTildeInPath) isn't a checkout of \(slug ?? "this repository") in your home folder.")
            case .ask(let several):
                let names = several.map { ($0 as NSString).abbreviatingWithTildeInPath }
                return self.fail(run, "Which folder: " + names.joined(separator: " or ") + "? Add “in \(names[0])” to your line.")
            }
            let remotes = folder.flatMap { $0.path == checkout ? $0.remotes : nil } ?? all.first { $0.path == checkout }?.remotes ?? []
            let remote = slug.flatMap { NoteHelp.remote(for: $0, in: remotes) } ?? remotes.first { $0.name == "origin" }?.name ?? remotes.first?.name ?? ""
            guard let provider = self.providerOrFail(run, for: pick) else { return }
            run.who = pick?.name ?? provider.name
            run.checkout = checkout
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
                // A real Always is shared; Allow once is this note's and this run's alone.
                let grant = always ? "always:" + kind : NoteHelp.onceGrant(kind: kind, note: run.noteID, run: run.token.id)
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
                    // The coding helper reads the cover first, as every helper does (`start`), then the note.
                    let paths = [short, tree, branch, number.map { "\(slug ?? "")'s #\($0) (fetched from \(remote))" } ?? ""]
                    run.gather = { _, raw in
                        raw.paths = paths
                        return nil
                    }
                    self.setUp(run, paper, Launch(kind: .code(folder: tree), provider: provider, model: pick?.id ?? "", brief: { NoteHelp.codeBrief($0) },
                                                  folder: tree, placed: false))
                    self.start(run, self.turn(run, said: text, words: { NoteHelp.codeRequest($0) }))
                }
            }
        }
    }

    /// "check this against @Notebook": the notebook's notes read (never one not known to be open, from outside it),
    /// and contradictions flagged as questions.
    private func check(_ paper: PaperNote, against name: String, asked: String) {
        guard let book = store?.notebook(name) else { return reply(paper.noteID, giveBack: taking, [name]) { "There's no notebook called “\($0[0])”." } }
        guard mayRead(book.name, from: paper) else { return reply(paper.noteID, giveBack: taking) { _ in "That notebook is private (or its cover isn't here yet): only a note inside it can read it." } }
        let notes = (store?.notes ?? []).filter { $0.notebook == book.name && $0.version == nil && $0.noteID != paper.noteID }.prefix(40)
        // Each note by its id: its whole text is read when the helper's turn starts, as it is then.
        ask(paper, "Check this note against the notebook below. Flag anything that contradicts it, each as a short question (\"Is it … or …?\"). If nothing does, say so in one line.",
            asked: asked, compare: (book.name, notes.map(\.noteID)))
    }

    // MARK: Running

    /// The AI a run uses: the one named, only when it's set up (never another instead); else the chat's.
    private func provider(for pick: NoteHelp.Model?) -> NoteHelp.ProviderChoice {
        let available = app.providers.filter { app.paths[$0] != nil && app.aiReady($0) }.map(\.rawValue)
        return NoteHelp.providerChoice(named: pick?.provider, available: available, chat: app.chatProvider?.rawValue)
    }

    /// The provider, or the run fails saying which isn't set up (with Settings › Petal AI's button).
    private func providerOrFail(_ run: Run, for pick: NoteHelp.Model?) -> Provider? {
        switch provider(for: pick) {
        case .use(let id): return Provider(rawValue: id)
        case .missing(let name): fail(run, "\(name) isn't set up in Petal.", settings: true); return nil
        case .none: fail(run, "Choose an AI in Petal's settings first (Claude Code or Codex).", settings: true); return nil
        }
    }

    /// A run's own helper agent: its tools look at the note's place. A note in a notebook not known to be open is
    /// marked so (and checked again when shown): it never shows in the previews. A fresh agent for every run: never one another run used (no late completion, no leftover state). It goes when
    /// its run ends (`retire`).
    private func sticky(for paper: PaperNote) -> StickyNote {
        let sticky = StickyNote()
        sticky.paper = paper.noteID
        sticky.secret = isPrivate(paper.notebook)
        sticky.agent.keeps = false
        app.claude.notes.append(sticky)
        return sticky
    }

    /// A run's agent, when it's that note's run now.
    private func runSticky(_ noteID: String) -> StickyNote? { runs[noteID]?.sticky }

    /// A run's agent goes with it (stopped first if it's still at work; its late end belongs to no one).
    private func drop(_ sticky: StickyNote) {
        if sticky.agent.running { sticky.agent.stop() }
        app.claude.notes.removeAll { $0 === sticky }
    }

    /// A run ended (any way): its agent goes.
    private func retire(_ run: Run) {
        if let sticky = run.sticky {
            // One that kept its place while it asked the person (Allow or Don't) frees it now: the next one waiting starts.
            let held = sticky.agent.holdsPlace && !sticky.agent.running
            drop(sticky)
            if held { DispatchQueue.main.async { MainActor.assumeIsolated { self.app.claude.startWaiting() } } }
        }
    }

    /// Whether a helper of this note may show in the AI button's previews: only one in a notebook known to be open.
    func previewable(_ sticky: StickyNote) -> Bool {
        guard let noteID = sticky.paper else { return true }
        if sticky.secret { return false }
        return paper(noteID).map { !isPrivate($0.notebook) } ?? false
    }

    /// Where the note is now, as its helper's tools see it (NotePlace): the window in front when the note is on it,
    /// its tab, or all of its app; nil when it isn't placed on a window now.
    /// `required`: the run's own place; the window in front is its tools' target only as that very place (on another
    /// of the note's places there's none: its tools then say what they look at). A note in the margin of Petal's
    /// viewer is on its document there: the viewer's own window showing that file is its tools' target (`petal_look`
    /// reads the viewer; `petal_ui` and `petal_act` never Petal's own windows), the one with the keyboard before the window in front, any other open one after.
    private func place(of paper: PaperNote, on required: NoteStick) -> NotePlace? {
        let viewing = viewer(showing: paper.noteID, on: required)?.model
        if let viewing, viewing === app.viewers.front, let place = app.viewers.place(of: viewing) { return place }
        if let desk, let scene = desk.scene, let index = desk.here[paper.key], paper.file.places.indices.contains(index) {
            let stick = paper.file.places[index]
            if stick.samePlace(required), NoteMatch.fits(required, scene) {
                let scope: NoteScope = stick.kind == .app ? .app : (stick.kind == .tab || stick.kind == .passage) && scene.tab != nil ? .tab : .window
                let name = NSRunningApplication(processIdentifier: scene.pid)?.localizedName ?? stick.appName
                return NotePlace(pid: scene.pid, app: scene.app, appName: name, window: scene.window, title: scene.title,
                                 desktop: scene.desktop, scope: scope, tab: scope == .tab ? scene.tab : nil)
            }
        }
        return viewing.flatMap { app.viewers.place(of: $0) }
    }

    /// A run's agent, set up once the run's own setup is done (its AI chosen, its worktree made): its token, its
    /// folder, its exact AI and model, its requirement and its tools' target bound together, its gate. Nothing is told
    /// yet: every turn's words, and its system prompt, are made when that turn starts (`start`).
    private func setUp(_ run: Run, _ paper: PaperNote, _ launch: Launch) {
        guard live(run) else { return }
        let sticky = run.sticky ?? sticky(for: paper)
        let agent = sticky.agent
        agent.token = run.token
        agent.folder = launch.folder.map { URL(fileURLWithPath: $0) }
        agent.pinned = (launch.provider, launch.model)
        run.provider = launch.provider.rawValue
        run.model = launch.model
        run.kind = launch.kind
        run.sticky = sticky
        run.launch = launch
        // Its requirement and its tools' target, bound together (and again on every re-stick, `placesFollow`).
        if launch.placed { bind(run, paper) } else { run.requiredPlace = nil; agent.place = nil }
        // Its process starts only through the gate, too.
        agent.gate = { [weak self, weak run] in
            guard let self, let run else { return .fail("This helper isn't running any more.") }
            let admission = self.admit(run)
            // Made again (after this turn is let go): the turn waits, and the rebuild withdraws it.
            if case .rebuild = admission {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.rebuild(run) } }
                return .wait("Starting over")
            }
            return admission
        }
        // A turn of it that waited (for room, or its gate at the very start) is made again when it may start.
        agent.again = { [weak self, weak run] in
            guard let self, let run, let call = run.call else { return }
            self.start(run, call)
        }
    }

    // MARK: Rule C: one admission gate

    /// Everything a helper's prompt, its process and every tool answer depend on, re-derived from what's true now:
    /// the note's current paper and notebook (and that it didn't move since the run began), each source note's
    /// notebook access, the run's own required place and document, and its exact AI being available.
    /// `landing`: asked for a finished result about to land (`landing`), not for something about to be sent.
    func admit(_ run: Run, landing: Bool = false) -> NoteHelp.Admission {
        guard runs[run.noteID] === run || run.kind.apart, run.token.admits || run.token.paused else { return .fail("This helper isn't running any more.") }
        var facts = NoteHelp.GateFacts()
        facts.landing = landing
        let paper = paper(run.noteID)
        // (A finished result whose note isn't one writable paper now is held whole, and asked about again when it's
        // applied: `applyHeld`. That isn't a refusal.)
        facts.paperFound = landing || (paper.map { !(desk?.store.readOnly($0) ?? true) } ?? false)
        facts.notebook = paper?.notebook ?? (landing ? startNotebook(run) : "")
        facts.startNotebook = startNotebook(run)
        facts.notesReady = desk?.acceptsChanges ?? false
        facts.privateBooks = store?.privateBooks ?? []
        facts.sources = run.sources.map { id in (id, self.paper(id)?.notebook) }
        facts.provider = run.provider
        facts.model = run.model
        facts.available = app.providers.filter { app.paths[$0] != nil && app.aiReady($0) }.map(\.rawValue)
        if run.provider == Provider.codex.rawValue, !app.codexModels.isEmpty { facts.models = app.codexModels.map(\.id) }
        facts.builtPrivacy = run.privacy
        facts.nowPrivacy = ClaudePanel.privacy.now
        facts.placePrivate = run.requiredPlace.map { app.assist.neverLook($0.app) } ?? false
        if run.kind.placed, let required = run.requiredPlace {
            // That it's waiting for a place (or a file), never its name (only what's shielded is ever said).
            facts.place = required.kind.rawValue
            facts.placeIsFile = ViewerFiles.namesFile(required)
            facts.placeShowing = requirementShowing(run)
        }
        return NoteHelp.admit(facts)
    }

    /// The apps kept private changed since what it was told was made: made again from its line, as a new run
    /// (through Shielded once more); one that can't be begun again fails.
    private func rebuild(_ run: Run) {
        guard runs[run.noteID] === run else { return }
        guard run.restart != nil else { return fail(run, "The apps you keep private changed while it worked. Ask again.") }
        again(run)
    }

    /// Before a tool answers a helper (Assist.handle): the gate, from what's true now. Nil: answer; else what the
    /// helper is told instead (waiting for its place or document, or why it can't go on).
    func admitTool(_ caller: String?) -> String? {
        guard let caller, let sticky = app.claude.note(withID: caller), let noteID = sticky.paper else { return nil }
        guard let run = runs[noteID], run.sticky === sticky else { return "This helper isn't running any more." }
        switch NoteHelp.toolOutcome(admit(run)) {
        case .answer: return nil
        case .fail(let reason):
            // Failed at once: the run completes as failed, its process ended.
            fail(run, reason, settings: reason.contains("isn't set up"))
            return reason
        case .park(let reason):
            // Parked: paused (resumable), going on once the gate admits again (placedNow).
            park(run, reason)
            return reason
        case .rebuild:
            rebuild(run)
            return "The apps kept private changed: this helper is starting over."
        }
    }

    /// A run parked by a tool's admission: paused where it is, its note saying what it waits for.
    private func park(_ run: Run, _ reason: String) {
        guard !run.parked, run.token.pause() else { return }
        leaveDisplay(run, after: false)
        run.parked = true
        write(run.noteID) { file in file.helper?.state = .waiting; file.helper?.step = reason }
    }

    /// The note says a helper is at work (`helper: working`).
    private func working(_ noteID: String, step: String, asked: String, who: String = NoteHelpers.petalWho) {
        let mac = self.mac
        stepWritten[noteID] = Date()
        write(noteID) { $0.helper = NoteHelp.Helper(state: .working, who: who, step: step, asked: asked, mac: mac, at: Date()) }
    }

    /// A helper's event arrived while the vault can't be read (Agent's boundary): its run fails, nothing of it shown.
    func vaultLost(_ sticky: StickyNote) {
        guard let noteID = sticky.paper, let run = runs[noteID], run.sticky === sticky else { return }
        end(run, .failed(Self.vaultWords.text))
    }

    /// A step: shown on the paper at once (its agent's activity), written into the note now and then.
    func stepped(_ sticky: StickyNote) {
        guard let noteID = sticky.paper, let run = runs[noteID], run.sticky === sticky, run.token.admits,
              Date().timeIntervalSince(stepWritten[noteID] ?? .distantPast) > 8 else { return }
        // Being written in: the paper shows the step live; nothing is written under the person's typing.
        if let key = paper(noteID)?.key, desk?.keyboard == key { return }
        stepWritten[noteID] = Date()
        let step = sticky.agent.activity.text
        write(noteID) { file in if file.helper?.state == .working { file.helper?.step = step } }
    }

    /// A helper's turn ended (ClaudePanel.finished). Its token says what that means, from the agent's explicit
    /// outcome: still asking the person, paused (kept, with Go on), stopped (nothing), failed (said, nothing
    /// advances), or succeeded: the whole answer becomes the note's ink, its steps go on the back, and only then a
    /// reviewer or a chain's next step may run.
    func finished(_ sticky: StickyNote) {
        // Only the run that launched this turn: an older run's turn ending while a new one is still being set up
        // (the same agent) is nothing to it.
        guard let noteID = sticky.paper, let run = runs[noteID], run.sticky === sticky, run.launched,
              NoteHelp.completionMatches(turn: sticky.agent.turnToken, run: run.token) else { return }
        let agent = sticky.agent
        let messages = Array(agent.messages.dropFirst(min(run.from, agent.messages.count)))
        let ending = run.token.ending(outcome: agent.outcome, asking: !agent.pendingAsk.isEmpty)
        switch ending {
        case .waitingOnPerson:
            write(noteID) { $0.helper?.state = .waiting; $0.helper?.step = "Waiting for you: Allow or Don't" }
            return
        case .paused:
            // Parked by a tool, its note already says what it waits for.
            if !run.parked { write(noteID) { $0.helper?.state = .waiting; $0.helper?.step = "Paused" } }
            return
        case .stopped:
            return stopped(run, saying: "Stopped." as Shielded)
        case .failed:
            return fail(run, agent.failure ?? messages.last { $0.kind == .error }?.text ?? "Petal AI stopped before it finished. Ask again.", settings: agent.failureOpensSettings)
        case .succeeded:
            break
        }
        let answer = messages.last { $0.kind == .claude }?.text ?? "Done."
        let steps = messages.filter { $0.kind == .step }.map(\.text)
        // Something said meanwhile, to this run: its answer so far is ink, and the run goes on with it.
        let next = followUps.next(note: noteID, current: run.token)
        for line in followUps.takeDropped() { line.again() }
        if let next {
            // A second opinion's turn goes through `opinion` like its end: added to the complete ink, never replacing it.
            turnOutput(run, Said(who: run.who, text: answer, steps: steps, form: run.reviewed == nil ? .answer : .opinion))
            run.from = agent.messages.count
            // This turn succeeded; the follow-up's line is the one held now, until its own turn succeeds.
            followUp(run, next.text, line: next.line)
            return
        }
        // As it arrived: shielded whole before anything is derived (a coding helper's proof only from its own "Proof:"
        // line, its finish line kept apart: NoteHelp.codeInk; a second opinion's objections).
        var form: Said.Form = run.reviewed == nil ? .answer : .opinion
        if case .code = run.kind { form = .code }
        let said = Said(who: run.who, text: answer, steps: steps, form: form, asked: run.asked)
        // The next answer replaces the last (a second opinion's is added to it), and what was asked meanwhile goes on.
        end(run, .succeeded(said))
    }

    /// A second opinion asked for in a follow-up: after the run at work succeeds, or now, against the note's last
    /// answer and its worktree.
    private func review(_ paper: PaperNote, _ model: NoteHelp.Model, asked: String) {
        let running = runs[paper.noteID].flatMap { $0.reviewed == nil && ($0.token.admits || $0.token.paused) ? $0 : nil }
        // The checkout it looks at is the work's own (the run at work's, else the note's saved worktree's), chosen as
        // a primary request's is: another one named is refused, plainly.
        let current = running != nil ? running?.checkout : paper.file.worktree?.checkout
        if case .refuse(let named) = NoteHelp.reviewCheckout(current: current, words: asked, home: NSHomeDirectory()) {
            let work = current.map { ($0 as NSString).abbreviatingWithTildeInPath }
            return reply(paper.noteID, giveBack: taking, [work ?? "", named]) {
                $0[0].isEmpty ? "A second opinion looks at this note's own work, not \($0[1]). Ask for it on a note about \($0[1])."
                    : "A second opinion looks at this note's own work in \($0[0]), not \($0[1]). Ask for it on a note about \($0[1])."
            }
        }
        // Joins the run at work: asked of it with its line (given back if that run doesn't succeed), run once it does.
        // A quick helper's result (a formula, a task put away) has nothing to review: refused while one works.
        if let run = running, run.kind == .quick {
            return reply(paper.noteID, giveBack: taking) { _ in "Wait for this to finish, then ask again." }
        }
        if let run = running {
            followUps.addReview(model, asked: asked, note: paper.noteID, token: run.token, line: taking)
            return
        }
        // Now, against the note's answer as it is when the reviewer's turn starts.
        secondOpinion(paper, model, asked: asked, tree: paper.file.worktree?.path)
    }

    /// "and have <model> look for holes": a run of its own, after the first succeeded, reading the cover and the note
    /// first, then the note's answer as it is when its turn starts (and in a worktree, the change), listing objections
    /// as its own ink with a count. Its result is only its own opinion, with the answer it reviewed.
    private func secondOpinion(_ paper: PaperNote, _ model: NoteHelp.Model, asked: String, tree: String?) {
        // Registered first (holding its line), so every way it can't go, its AI not set up too, ends through `end`
        // and gives its line back. Part of its primary run: its outcome (a failure too) is added to the note's ink
        // as its own opinion, the answer standing.
        let run = begin(paper, asked: asked, step: "Looking for holes", who: model.name.isEmpty ? "Second opinion" : model.name)
        run.reviewed = ""
        guard case .use(let id) = provider(for: model), let provider = Provider(rawValue: id) else {
            // Never another instead.
            return fail(run, "\(model.provider == .claude ? "Claude Code" : "Codex") isn't set up in Petal.", settings: true)
        }
        if model.name.isEmpty { run.who = provider.name }
        let reviewer = sticky(for: paper)
        reviewer.reviewer = true
        run.sticky = reviewer
        let noteID = paper.noteID
        let start = { [weak self, weak run] (tree: String?) in
            guard let self, let run else { return }
            // The answer it reviews: the note's primary ink as it is when a turn of it starts (never ink captured
            // earlier), known by its hash, which its opinion carries (`reviewed`).
            run.gather = { [weak self, weak run] _, raw in
                guard let self, let run else { return "This helper isn't running any more." }
                let primary = NoteHelp.primary(self.latestInk(noteID))
                run.reviewed = NoteHelp.inkHash(primary)
                raw.answer = primary?.text ?? ""
                raw.paths = tree.map { [$0] } ?? []
                return nil
            }
            self.setUp(run, paper, Launch(kind: .holes(folder: tree), provider: provider, model: model.id, brief: { NoteHelp.reviewBrief($0) },
                                          folder: tree, placed: tree == nil))
            self.start(run, self.turn(run, said: asked, words: { NoteHelp.reviewRequest($0, tree: $0.paths.first) }))
        }
        guard let tree else { return start(nil) }
        // In a worktree only once it's checked, as a coding follow-up's is: where this note's worktree of its saved
        // checkout belongs, that checkout's, on the branch stored.
        guard let stored = self.paper(paper.noteID)?.file.worktree, NoteHelp.standard(stored.path) == NoteHelp.standard(tree) else {
            return fail(run, "the worktree this note had isn't on it any more.")
        }
        Self.verifyTree(stored, noteID: paper.noteID, token: run.token) { checked in
            guard self.live(run) else { return }
            guard case .owned(let owned, let checkout) = checked else {
                return self.fail(run, "the worktree saved on this note isn't this note's worktree of \((stored.checkout as NSString).abbreviatingWithTildeInPath) on \(stored.branch).")
            }
            // Its verified checkout, kept like any coding run's: a follow-up naming another is never sent to it.
            run.checkout = checkout
            run.tree = owned
            start(owned)
        }
    }

    // MARK: Cards and stamps on the note

    /// An automatic approval (an Always given earlier, or Full access) for `owner`: when it's a note's helper, the
    /// grant is registered on its run's token before it goes ahead (taking the Always back cancels every run using
    /// it); a helper with no run going on is refused. Anything else is allowed as before.
    func authorized(_ owner: String?, _ grant: String) -> Bool {
        guard let owner, let sticky = app.claude.note(withID: owner), let noteID = sticky.paper else { return true }
        guard let run = runs[noteID], run.sticky === sticky, run.token.admits else { return false }
        run.token.hold(grant)
        return run.token.grants.contains(grant)
    }

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
        // The coding helper's own Allow is stamped by its run; a removal's confirmation is no permission to keep.
        guard !request.kind.hasPrefix("code:"), !request.kind.hasPrefix("remove:") else { return }
        let always = choice == .always && !request.every
        let label = (always ? "ALWAYS · " : "ALLOWED · ") + request.title.uppercased()
        // Allow once and Buy: this note's and this run's alone; only a real Always is shared.
        let grant = always ? "always:" + request.kind : NoteHelp.onceGrant(kind: request.kind, note: noteID, run: runs[noteID]?.token.id ?? "none")
        stamp(noteID, label: label, grant: grant)
        write(noteID) { file in if file.helper?.state == .waiting { file.helper?.state = .working } }
    }

    /// Claude asked to run something it may not (its denials): Allow on the note re-runs with per-part rules, held by
    /// the run.
    func allowDenials(_ noteID: String) {
        guard let run = runs[noteID], let sticky = run.sticky, run.token.admits else { return }
        let agent = sticky.agent
        let rules = agent.pendingAsk.flatMap(\.rules)
        let label = agent.pendingAsk.map(\.label).first ?? "a command"
        let grant = NoteHelp.rulesGrant(rules, note: noteID, run: run.token.id)
        grantedRules[grant] = rules
        stamp(noteID, label: "ALLOWED · " + label.uppercased(), grant: grant)
        write(noteID) { file in file.helper?.state = .working; file.helper?.step = "Allowed" }
        // Its continuation is the same run's next turn: a call like any other (`start`), kept with the run while it
        // waits (its gate, a pause), in the place among those working that the run kept while it asked.
        guard agent.takeAllow() else { return }
        start(run, turn(run, said: nil, words: { _ in Agent.approvedWords }))
    }

    func denyDenials(_ noteID: String) {
        guard let run = runs[noteID], let sticky = run.sticky else { return }
        sticky.agent.deny()
        fail(run, "Not allowed: it stopped there.")
    }

    /// A stamp keeps an opaque grant and a shielded label (its words through the vault's redaction before they're
    /// written); the run holds the grant at once.
    private func stamp(_ noteID: String, label: String, grant: String) {
        runs[noteID]?.token.hold(grant)
        let mac = self.mac
        Self.shield([label]) { shown in
            let stamp = NoteHelp.Stamp(label: shown?.first?.text ?? "ALLOWED", grant: grant, mac: mac)
            self.write(noteID) { file in if !file.stamps.contains(stamp) { file.stamps.append(stamp) } }
        }
    }

    /// Claude's command rules a run was allowed, by their stamp's opaque grant: kept in memory only (never in the note).
    @ObservationIgnored private var grantedRules: [String: [String]] = [:]

    /// Tapping a stamp takes its grant back (on the Mac it was given on) and the stamp goes; a run holding it (every
    /// run holds its note's grants) is cancelled, which ends its processes.
    func revoke(_ noteID: String, _ stamp: NoteHelp.Stamp) {
        guard stamp.mac == mac else { desk?.tell("That was allowed on another Mac: take it back there."); return }
        switch stamp.parsed {
        case .always(let kind):
            app.config.set("aiAllowed", app.config.strings("aiAllowed").filter { $0 != kind })
        case .rules(let grant):
            if let rules = grantedRules.removeValue(forKey: grant) { runSticky(noteID)?.agent.revoke(rules) }
        case .project(let id):
            AgentGrants.shared.remove(id)
        case .once:
            if let sticky = runSticky(noteID) { app.assist.computer.end(sticky.id.uuidString) }
        }
        // Every run holding it is cancelled, whichever note it's on (an Always for a checkout is shared).
        for held in tokens.revoke(stamp.grant) {
            guard let run = runs[held] else { continue }
            end(run, .stopped("Stopped: you took back what it was allowed."))
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

    /// One turn of the clock, for `Petal --helpers-check` (headless, its timer never starts).
    func clockTurn() { tick() }

    private func tick() {
        // Nothing of the clock's (a note coming back, a look, a chain, a morning note) while notes aren't ready.
        guard let desk, desk.on, desk.acceptsChanges else { return }
        adoptStanding()
        // Results a refused write left in the journal are tried again.
        applyHeld()
        let now = Date()
        for paper in desk.store.notes where paper.version == nil {
            let file = paper.file
            if let back = file.back, back <= now {
                summon(paper.noteID, open: false)
                write(paper.noteID) { $0.back = nil }
            }
            // A watcher, a chain or a morning note: only one the person set up on this Mac (`stands`), never one that
            // is only in the file.
            if let watch = file.watch, watch.mac == mac, stands(NoteHelp.Standing(watch, on: paper.noteID)), NoteHelp.due(watch, now: now) { look(paper.noteID) }
            if let chain = file.chain, stands(NoteHelp.Standing(chain, on: paper.noteID)),
               chain.ready(mac: mac, after: self.paper(chain.after)?.file.helper) { fire(paper) }
            if let morning = file.morning, morning.mac == mac, stands(NoteHelp.Standing(morning: morning.time, on: paper.noteID)),
               cover(of: paper.notebook)?.key == paper.key { leaveMorning(paper, at: morning.time, now: now) }
            if file.worktree != nil, let link = file.ink.first(where: { !$0.opinion && !$0.link.isEmpty })?.link, runs[paper.noteID] == nil,
               now.timeIntervalSince(mergeChecked[paper.noteID] ?? .distantPast) > 600 {
                mergeChecked[paper.noteID] = now
                Self.merged(link) { merged in
                    if merged, let paper = self.paper(paper.noteID), paper.file.worktree != nil, self.runs[paper.noteID] == nil {
                        self.removeWorktree(paper, why: "its pull request merged", token: RunToken()) { _ in }
                    }
                }
            }
        }
    }

    // MARK: What this Mac keeps going

    /// Whether this Mac holds that chain, watcher or morning note just as its note's file says it now.
    private func stands(_ entry: NoteHelp.Standing) -> Bool { NoteHelp.stands(entry, in: desk?.local.standing) }

    /// A Mac that kept none yet takes, once, the ones it already had going in the notes' folder (`NoteHelp.adopted`),
    /// as soon as the notes are read; before that nothing of the clock's is done for any.
    /// It waits for a read of the whole folder (a file iCloud hasn't downloaded yet is read later), for a while at
    /// most; the person setting one up here (`now`) takes them at once. Taken before the folder was read whole, the
    /// rest are added once it is (`adoptPending`, kept across launches), so none it had going is left out.
    private func adoptStanding(now: Bool = false) {
        guard let desk, desk.acceptsChanges else { return }
        let complete = desk.store.readComplete
        let found = { NoteHelp.adopted(desk.store.notes.filter { $0.version == nil }.map { (note: $0.noteID, file: $0.file) }, mac: self.mac) }
        if desk.local.standing == nil {
            if !now, !complete, adoptWaits < 20 { adoptWaits += 1; return }
            desk.local.standing = found()
            desk.local.adoptPending = complete ? nil : true
        } else if desk.local.adoptPending == true, complete {
            desk.local.standing = NoteHelp.standing(desk.local.standing, merging: found())
            desk.local.adoptPending = nil
        } else {
            return
        }
        desk.local.save(pending: desk.store.pendingIDs)
    }

    /// What setting one up here does first (`keepGoing`), for `Petal --helpers-check`.
    func adoptForCheck() { adoptStanding(now: true) }

    /// Clock turns adoption has waited for the folder to be read whole (`adoptStanding`).
    @ObservationIgnored private var adoptWaits = 0

    /// The person's own line set this up here: kept on this Mac, in its note's one place of that kind.
    private func keepGoing(_ entry: NoteHelp.Standing) {
        adoptStanding(now: true)
        guard let desk, desk.local.standing != nil else { return }
        desk.local.standing = NoteHelp.standing(desk.local.standing, adding: entry)
        desk.local.save(pending: desk.store.pendingIDs)
    }

    /// It started, or was stopped: no longer this Mac's to do.
    private func letGo(_ kind: String, on noteID: String) {
        guard let desk, let now = NoteHelp.standing(desk.local.standing, without: kind, on: noteID), now != desk.local.standing else { return }
        desk.local.standing = now
        desk.local.save(pending: desk.store.pendingIDs)
    }

    /// A chain's note is done: its run is registered first, then `fired` is written (landed, on this Mac only), then
    /// checked again (still that run, still that chain, fired by it) before the helper is asked through `ask`, like
    /// any run (a coding page gets its worktree and its project's Allow). A restart or a sync never runs it twice.
    private func fire(_ paper: PaperNote) {
        let noteID = paper.noteID
        guard paper.file.chain != nil, runs[noteID] == nil, !firing.contains(noteID) else { return }
        // Nothing starts unless the vault's redaction is settled and readable (a later tick tries again).
        firing.insert(noteID)
        Self.vaultReady { ready in
            self.firing.remove(noteID)
            guard ready, let paper = self.paper(noteID) else { return }
            self.fireNow(paper)
        }
    }

    @ObservationIgnored private var firing: Set<String> = []

    private func fireNow(_ paper: PaperNote) {
        guard var chain = paper.file.chain, runs[paper.noteID] == nil, stands(NoteHelp.Standing(chain, on: paper.noteID)) else { return }
        // Its predecessor is a source of this run: read by its id, in its notebook now, by the same rule as the gate
        // (a note private to a notebook this one isn't in, or gone, is never read): else it doesn't fire, and says so.
        guard let first = self.paper(chain.after), mayRead(first.notebook, from: paper) else {
            letGo(NoteHelp.Standing.chain, on: paper.noteID)
            write(paper.noteID) { file in file.chain = nil; if file.helper?.state == .waiting { file.helper = nil } }
            return reply(paper.noteID, giveBack: nil) { _ in "The note this one was waiting for can't be read from here now (private, or gone), so it didn't start." }
        }
        let asked = "when @" + chain.afterTitle + " is done, " + chain.ask
        let run = begin(paper, asked: asked, step: "\(chain.afterTitle) is done: starting")
        run.sources = [first.noteID]
        let fired = Date()
        chain.fired = fired
        write(paper.noteID, { $0.chain = chain }) { landed in
            guard landed, self.live(run), let now = self.paper(paper.noteID), let mine = now.file.chain,
                  mine.after == chain.after, mine.fired.map({ abs($0.timeIntervalSince(fired)) < 1 }) == true else {
                return self.stopped(run, saying: "Petal couldn't record that this chain started, so it didn't.")
            }
            // Its start is in its file now (`fired`): it never starts again, so this Mac lets it go.
            self.letGo(NoteHelp.Standing.chain, on: paper.noteID)
            // The done note's whole body goes with it, checked again (its access may have changed meanwhile): its title
            // is derived only after it's shielded (NoteHelp.brief), and the gate checks its access again before it goes.
            guard let first = self.paper(chain.after), self.mayRead(first.notebook, from: now) else {
                self.reply(paper.noteID, giveBack: nil) { _ in "The note this one was waiting for can't be read from here now (private, or gone), so it didn't start." }
                return self.stopped(run)
            }
            run.after = first.noteID
            self.ask(now, chain.ask, asked: asked, run: run)
        }
    }

    /// A notebook's morning note, once a day at its time, written by Petal (`from: petal`) and left on the Desktop
    /// showing: what its helpers did since yesterday, its watchers' numbers, what comes back today. No AI.
    private func leaveMorning(_ cover: PaperNote, at time: String, now: Date) {
        guard let clock = NoteHelp.clock(time), let due = Calendar.current.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: now),
              now >= due, now.timeIntervalSince(due) < 6 * 3600 else { return }
        let day = NoteFile.stamp(Calendar.current.startOfDay(for: now)).prefix(10)
        // One a day per notebook, by the notebook itself (its cover's id, which a rename keeps), never its name; and
        // made for it as pending work finds its notebook (its binding and the notes' folder's session, captured now).
        guard let store, let book = store.binding(cover.notebook) else { return }
        let session = store.session
        let stable = "morning-" + NoteShelf.pictureFolder(id: cover.noteID).suffix(12) + "-" + day
        guard !mornings.contains(stable), !store.notes.contains(where: { $0.noteID == stable }) else { return }
        mornings.insert(stable)
        let notes = store.notes.filter { $0.notebook == cover.notebook && $0.key != cover.key && !NoteLibrary.isCoverName($0.url.lastPathComponent) && $0.version == nil }
        let since = now.addingTimeInterval(-86400)
        // Each note's whole body and whole ink shielded first; its title and the ink's first sentence derived after.
        var sources: [String] = []
        var rows: [(body: Int, ink: Int?, watch: (last: String, was: String?)?, back: String?)] = []
        for note in notes {
            var ink: Int?
            if let helper = note.file.helper, helper.state == .done, let at = helper.at, at > since, !note.file.ink.isEmpty {
                ink = sources.count + 1
            }
            let watch = note.file.watch.flatMap { $0.last.isEmpty ? nil : (last: $0.last, was: $0.history.first) }
            let back = note.file.back.flatMap { Calendar.current.isDate($0, inSameDayAs: now) ? NoteHelp.backLine($0, now: now) : nil }
            guard ink != nil || watch != nil || back != nil else { continue }
            rows.append((sources.count, ink, watch, back))
            sources.append(note.file.body)
            if ink != nil { sources.append(note.file.ink.first?.text ?? "") }
        }
        Self.shield(sources) { shown in
            guard let shown else { self.mornings.remove(stable); return }
            var lines: [String] = []
            for row in rows {
                let title = shown[row.body].title.text
                if let ink = row.ink { lines.append("\(title): " + shown[ink].firstSentence.text + ".") }
                if let watch = row.watch { lines.append("\(title): \(watch.last)" + (watch.was.map { ", was \($0)" } ?? "") + ".") }
                if let back = row.back { lines.append("\(title) comes back at " + (back.components(separatedBy: " ").last ?? back) + ".") }
            }
            if lines.isEmpty { lines.append("Nothing needs you.") }
            var file = NoteFile(id: stable, body: lines.prefix(6).joined(separator: " "))
            file.fromPetal = true
            self.desk?.resolveDesktop { number in
                if let place = NoteShelf.desktopAnchor(number: number) { file.places = [place] }
                // Still that notes' folder, and its notebook wherever it is now (renamed meanwhile: there); not
                // surely found, nothing is made (a later tick tries again).
                guard store.session === session, case .found(let notebook) = store.resolve(book) else { self.mornings.remove(stable); return }
                store.make(file, in: notebook, then: { made in if made == nil { self.mornings.remove(stable) } })
            }
        }
    }

    /// A watcher looks once: the page fetched plainly (bounded) and shielded with its line and last value before
    /// anything reads it; its value found with no AI when it can be; the AI only when it can't, or when the line is
    /// crossed. Nothing is ever bought. What it finds is written back only into the look's own fields and only while
    /// the watcher is the one it began under (its id) and not paused; the note says a crossing only when that write
    /// newly crossed the line.
    func look(_ noteID: String) {
        guard let paper = paper(noteID), let watch = paper.file.watch, watch.mac == mac, stands(NoteHelp.Standing(watch, on: noteID)),
              !watch.paused, !looking.contains(noteID), let url = URL(string: watch.url), ["http", "https"].contains(url.scheme ?? "") else { return }
        looking.insert(noteID)
        let id = watch.id
        // The look's own token, kept with the watcher: pausing, stopping or changing it cancels the fetch and its
        // quick calls.
        let token = looks.start(noteID)
        // A run of its own (kind `look`, never in `runs`: it doesn't stop the helper at work there), ended like any.
        let run = Run(token: token, noteID: noteID, asked: paper.file.helper?.asked ?? "", who: Self.petalWho + " · " + NoteHelp.dayLabel(Date(), now: Date()))
        run.kind = .look
        run.startNotebook = paper.notebook
        run.startBook = store?.binding(paper.notebook)
        let task = Task.detached {
            guard token.admits else { return }
            let data = await Sites.get(url, .page)
            let html = data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) } ?? ""
            let text = NoteHelp.pageText(html)
            await MainActor.run {
                guard token.admits else { return self.end(run, .stopped(nil)) }
                var raw = Raw()
                raw.extra = text
                raw.line = watch.line
                raw.last = watch.last
                // Read plainly from the shielded page (no AI); what the quick AI is asked, if anything, goes through
                // `start`, made again then from the page (`text`, the look's source) and the watcher as they are then.
                Self.tell(raw) { told, _ in
                    guard token.admits else { return self.end(run, .stopped(nil)) }
                    guard let told else { return self.end(run, .failed(NoteShield.unreadable)) }
                    self.read(run, id: id, told: told, page: text)
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

    private func read(_ run: Run, id: String, told: NoteHelp.Told, page: String) {
        let noteID = run.noteID
        let token = run.token
        guard let watch = current(noteID, id), token.admits else { return end(run, .stopped(nil)) }
        let text = told.extra.text
        let line = NoteHelp.line(watch.line)
        let last = watch.amount ?? NoteHelp.amounts(watch.last, needCurrency: false).first?.value
        // The look's end: its value recorded; a hit only with an explicit yes (NoteHelp.watchVerdict), said only from
        // this write's own "newly crossed" result; unconfirmed, shown as such and never a hit.
        // The look's output is its own kind (keepWatch): its value in the corner (the newest, older ones struck), never
        // ink or the helper line. A confirmed new crossing is told by the note itself, summoned with that number; `hit`
        // is kept only once it's showing, so a crossing the person never saw is told again by the next look.
        let finish = { (value: Double?, hint: String?, verdict: NoteHelp.WatchVerdict) in
            guard self.current(noteID, id) != nil, token.admits else { return self.end(run, .stopped(nil)) }
            let shown = value.map { NoteHelp.format($0, currency: line?.currency ?? "", thousands: line?.thousands ?? false) }
            let now = Date()
            let past = value.map { NoteHelp.crossed($0, line: watch.line) } ?? false
            let newly = Flag()
            self.keepWatch(noteID) { current in
                newly.value = NoteHelp.applyLook(&current, id: id, shown: shown, amount: value, hint: hint, past: past, confirmed: verdict == .hit,
                                                 verdict: verdict, at: now) ?? false
            }
            self.end(run, .succeeded(nil))
            if newly.value, let value { self.tellHit(noteID, watchID: id, amount: value) }
        }
        // The quick AI's part of a look is a paid call like any other (`start`): its sources are the page and the
        // watcher as they are when it starts; its AI is the chat's.
        run.provider = app.chatProvider?.rawValue ?? ""
        let sources = { @MainActor (_: PaperNote, raw: inout Raw) -> String? in
            guard let now = self.current(noteID, id) else { return "This watcher changed while it looked." }
            raw.extra = page
            raw.line = now.line
            raw.last = now.last
            return nil
        }
        // A value that crossed the line (and wasn't a hit already) is confirmed first, whichever way it was read.
        // `plainly`: read from the page (what's asked about is then that range of the page as it's shielded when the
        // question is made; not found there again, nothing is asked); else the number the quick AI found.
        let decide = { (value: Double?, hint: String?, plainly: Bool) in
            guard let value, NoteHelp.crossed(value, line: watch.line), !watch.hit else { return finish(value, hint, .plain) }
            guard self.app.brain.enabled else {
                return finish(value, hint, NoteHelp.watchVerdict(crossed: true, alreadyHit: false, confirmation: nil, asked: false))
            }
            self.start(run, Call(sources: sources, words: { told in
                guard plainly else { return NoteHelp.watchConfirm(told, found: "\(value)", hint: "") }
                let text = told.extra.text
                guard let found = NoteHelp.pick(text, line: watch.line, hint: watch.hint, last: last), found.value == value else { return nil }
                let before = NoteHelp.hint(before: found, in: text)
                let range = (text as NSString).range(of: before, options: .backwards, range: NSRange(location: 0, length: found.range.location))
                return NoteHelp.watchConfirm(told, found: told.extra.substring(found.range), hint: range.location == NSNotFound ? "" : told.extra.substring(range))
            }, to: .quick(key: "watch|\(noteID)|\(id)|\(value)|\(Date().timeIntervalSince1970)", provider: nil) { reply, _ in
                finish(value, hint, NoteHelp.watchVerdict(crossed: true, alreadyHit: false, confirmation: reply, asked: true))
            }))
        }
        if !text.isEmpty, let found = NoteHelp.pick(text, line: watch.line, hint: watch.hint, last: last) {
            return decide(found.value, NoteHelp.hint(before: found, in: text), true)
        }
        guard !text.isEmpty, app.brain.enabled else { return finish(nil, nil, .plain) }
        // Couldn't tell plainly: the quick AI finds it once (and the words before it for next time); a value it finds
        // that crosses the line is confirmed like any other.
        start(run, Call(sources: sources, words: { NoteHelp.watchFind($0) },
                        to: .quick(key: "watchfind|\(noteID)|\(id)|\(Date().timeIntervalSince1970)", provider: nil) { reply, _ in
            // Its exact value told on (never rounded before a decision); the words it found before it shielded too.
            let value = (reply?["value"] as? NSNumber)?.doubleValue
            Self.shield([reply?["before"] as? String ?? ""]) { before in decide(value, before?.first?.text, false) }
        }))
    }

    private final class Flag { var value = false }

    // MARK: The reading lens

    /// The lens's call under way for each note (one at a time), and its tokens.
    @ObservationIgnored private var lensAt: [String: Run] = [:]
    @ObservationIgnored private let lenses = TokenTable()

    /// What the lens has to show beside the paragraph: the answer, or in plain words why there is none.
    enum LensAnswer {
        case said(Shielded)
        case couldnt(String)
    }

    /// A selection settled in Petal's viewer while a margin note follows it ("Follow what I select"): the quick AI is
    /// asked to do what the note says to those words, with their paragraph for context (a note with no words:
    /// explain them plainly). A paid call like any other, through `start`: the vault readable, the gate (the note
    /// still one paper in the notebook it was in, the AI set up), then its words built and shielded from the note as
    /// it is then, the selection and the paragraph (cut in the viewer only after the whole page was checked against
    /// the vault). One call at a time per note: a newer selection ends the one before, so only the newest answers.
    /// Its answer is shielded whole before it's shown beside the paragraph (`answer`); nothing is written on the
    /// note, and the note's own helper, if one is at work, is left alone.
    func lens(_ request: ViewerLensRequest, _ answer: @escaping @MainActor (LensAnswer) -> Void) {
        lensOff(request.noteID)
        guard let desk, desk.on else { return answer(.couldnt("Petal Notes is off.")) }
        guard desk.acceptsChanges else { return answer(.couldnt(NoteStore.gettingReady)) }
        guard let paper = paper(request.noteID) else { return answer(.couldnt("This note has two versions: keep one first.")) }
        guard app.brain.enabled else { return answer(.couldnt("Choose an AI in Petal's settings, under AI, and this note can answer here.")) }
        let made = Run(token: lenses.start(paper.noteID), noteID: paper.noteID, asked: "", who: Self.petalWho)
        made.kind = .lens
        made.startNotebook = paper.notebook
        made.startBook = store?.binding(paper.notebook)
        // The quick AI is the chat's (Haiku at low effort, or Codex's quick setting): the gate checks it's set up.
        made.provider = app.chatProvider?.rawValue ?? ""
        lensAt[paper.noteID] = made
        start(made, Call(sources: { _, raw in
            // The note's own words say what to do (its body, read again as the call starts). What was selected and
            // its paragraph are the viewer's. Its notebook's cover isn't part of what's asked.
            raw.line = request.selected
            raw.extra = request.paragraph
            raw.coverOf = nil
            return nil
        }, words: { NoteHelp.lensAsk($0) }, to: .quick(key: "lens|\(paper.noteID)|\(request.id.uuidString)", provider: nil) { [weak self] reply, _ in
            guard let self else { return }
            guard self.mine(made) else {
                // It ended before an answer: failed (its reason is said beside the paragraph), or stopped for a newer
                // selection (which answers instead).
                if case .failed(let reason)? = made.token.completion { answer(.couldnt(reason)) }
                return
            }
            let words = (reply?["answer"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if words.isEmpty {
                self.end(made, .failed("no answer"))
                return answer(.couldnt("Petal couldn't answer that just now. Select it again to ask again."))
            }
            // Shielded whole as it arrives, like everything a helper says.
            Self.shield([words]) { shown in
                let still = self.mine(made)
                if still, let said = shown?.first {
                    self.end(made, .succeeded(nil))
                    answer(.said(said))
                } else if still {
                    self.end(made, .failed(Self.vaultWords.text))
                    answer(.couldnt(Self.vaultWords.text))
                }
            }
        }))
    }

    /// The lens off for a note (the person stopped it, a newer selection, its viewer closed, the notes' folder
    /// switched): its call ends, and nothing of it is shown.
    func lensOff(_ noteID: String) {
        if let old = lensAt[noteID] { end(old, .stopped(nil)) }
    }

    /// A watcher's confirmed new crossing, told by the note itself: summoned, open, its corner showing the number
    /// (on the open paper as on the folded one). Only once the paper showing that very value (its watcher, its exact
    /// amount, landed) has been on the screen, on a face with the corner, is `hit` kept (through the journal, on that
    /// watcher only); a note that couldn't be shown keeps it unsaid, and the next look tells the person again.
    private func tellHit(_ noteID: String, watchID: String, amount: Double, tries: Int = 6) {
        if tries == 6 { summon(noteID, open: true) }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated {
            guard let paper = self.paper(noteID), let watch = paper.file.watch, watch.id == watchID else { return }
            guard NoteHelp.delivered(watch, amount: amount, cornerShowing: self.desk?.isShowingCorner(paper.key) == true) else {
                return self.tellHit(noteID, watchID: watchID, amount: amount, tries: tries - 1)
            }
            self.keepWatch(noteID) { watch in _ = NoteHelp.told(&watch, id: watchID) }
        } }
    }

    // MARK: Worktrees

    /// The note's worktree goes (its PR merged, or the person said it's done), and the note says so. One with changes
    /// not committed stays, and the note says that instead.
    /// Removing the note's worktree because the person said so: never by keyword alone. Its run holds the line;
    /// the worktree is checked to be this note's (`ownedTree`) and clean, then the note asks with a card, Don't the
    /// default: "Remove the worktree for <branch>? It has no changes." Only Remove removes it; anything else leaves it
    /// and the note's ink as they are (the line given back).
    private func askToRemoveWorktree(_ paper: PaperNote, asked: String) {
        guard let tree = paper.file.worktree else { return }
        if runs[paper.noteID] != nil {
            return reply(paper.noteID, giveBack: taking) { _ in "A helper is at work on this note: stop it first, then ask again." }
        }
        let run = begin(paper, asked: asked, step: "Asking to remove the worktree")
        run.kind = .quick
        let sticky = sticky(for: paper)
        run.sticky = sticky
        let noteID = paper.noteID
        let token = run.token
        let left = { (why: Shielded) in
            self.reply(noteID, giveBack: nil) { _ in why }
            self.end(run, .stopped(nil))
        }
        DispatchQueue.global(qos: .utility).async {
            let check = Self.ownedTree(tree, noteID: noteID, token: token)
            var clean: Bool?
            if case .owned(let path, _) = check, token.admits {
                clean = Self.git(path, ["status", "--porcelain"], token: token).output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard self.live(run) else { return }
                guard case .owned = check, let clean else {
                    // Not this note's any more: left as it is, and the note stops looking after it.
                    self.write(noteID) { $0.worktree = nil }
                    return left("That worktree isn't this note's any more (another branch, or saved pointing elsewhere), so Petal left it.")
                }
                guard clean else { return left("The worktree has changes not committed, so Petal left it.") }
                self.app.assist.ask("remove:" + noteID, "Remove the worktree for \(tree.branch)? It has no changes.",
                                    detail: (tree.path as NSString).abbreviatingWithTildeInPath, warn: true, allow: "Remove", owner: sticky.id.uuidString) { allowed in
                    guard self.live(run) else { return }
                    guard allowed else { return left("Kept the worktree.") }
                    self.removeWorktree(paper, why: "you said it's done", token: token) { removed in
                        guard self.live(run) else { return }
                        if removed { self.end(run, .succeeded(nil)) } else { self.end(run, .stopped(nil)) }
                    }
                }
            } }
        }
    }

    /// The one way a note's worktree is removed (after its pull request merged, or the person's Remove): only once
    /// it's checked to be this note's (`ownedTree`: where it belongs, that checkout's, on the saved branch), by its
    /// canonical paths, never with --force; anything else is left where it is.
    private func removeWorktree(_ paper: PaperNote, why: String, token: RunToken, _ done: @escaping @MainActor (Bool) -> Void) {
        guard let tree = paper.file.worktree else { return done(false) }
        let short = (tree.checkout as NSString).abbreviatingWithTildeInPath
        let noteID = paper.noteID
        DispatchQueue.global(qos: .utility).async {
            let check = Self.ownedTree(tree, noteID: noteID, token: token)
            let gone: (status: Int32, output: String)? = if case .owned(let path, let checkout) = check { Self.git(checkout, ["worktree", "remove", path], token: token) } else { nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let gone else {
                        // Not this note's any more (moved to another branch, or saved pointing elsewhere): left as it is,
                        // and the note stops looking after it.
                        if check == .notOwned { self.write(paper.noteID) { $0.worktree = nil } }
                        self.reply(paper.noteID, giveBack: nil, [tree.path, short, tree.branch]) {
                            "The worktree at \($0[0]) isn't this note's worktree of \($0[1]) on \($0[2]) any more, so Petal left it."
                        }
                        return done(false)
                    }
                    guard gone.status == 0 || !FileManager.default.fileExists(atPath: tree.path) else {
                        self.reply(paper.noteID, giveBack: nil, [short, tree.path]) { "The worktree of \($0[0]) has changes not committed, so Petal left it at \($0[1])." }
                        return done(false)
                    }
                    self.write(paper.noteID) { $0.worktree = nil }
                    self.reply(paper.noteID, giveBack: nil, [short, why, tree.branch]) { "Removed the worktree of \($0[0]): \($0[1]). The branch \($0[2]) stays." }
                    done(true)
                }
            }
        }
    }

    /// Whether a pull request merged (gh, off the main thread).
    static func merged(_ link: String, _ done: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = NoteHelp.mergedArguments(link)
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

    /// The git repository a file is really in, as AgentAccess resolves a project (`AgentAccess.repository`: the
    /// nearest one above it, a linked worktree's main checkout only when git made it one), with its remotes from its
    /// own .git/config; only one in the home folder. Off the main thread, no git run.
    static func repository(holding stick: NoteStick, mac: String, _ done: @escaping @MainActor ((path: String, remotes: [(name: String, url: String)])?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Where the place's file is now (ViewerFiles: its own file by its `fileID`, then its bookmark, then its path).
            let file = ViewerFiles.locate(stick, mac: mac, follow: ViewerLoader.follow)?.path
            let folder = file.map { (URL(fileURLWithPath: $0).resolvingSymlinksInPath().path as NSString).deletingLastPathComponent }
            var found: (path: String, remotes: [(name: String, url: String)])?
            if let folder, let repository = AgentAccess.repository(folder, files: AgentCallers.disk), NoteHelp.inHome(repository, home: NSHomeDirectory()),
               let config = try? String(contentsOf: URL(fileURLWithPath: repository).appending(path: ".git/config"), encoding: .utf8) {
                found = (NoteHelp.standard(repository), NoteHelp.remotes(config: config))
            }
            let result = found
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
                guard let verified = verified(tree, canonical: canonical, branch: branch, token: token) else { return finish(.stopped) }
                guard verified else { return finish(.failed("a worktree for this note is there but belongs to something else; Petal left it at \(tree)")) }
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

    /// Whether `tree` is a worktree of the checkout `canonical`, on `branch` (nil: stopped meanwhile).
    nonisolated static func verified(_ tree: String, canonical: String, branch: String, token: RunToken) -> Bool? {
        guard token.admits else { return nil }
        let common = git(tree, ["rev-parse", "--path-format=absolute", "--git-common-dir"], token: token)
        guard token.admits else { return nil }
        let head = git(tree, ["rev-parse", "--abbrev-ref", "HEAD"], token: token)
        guard token.admits else { return nil }
        let actual = URL(fileURLWithPath: common.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
        return common.status == 0 && head.status == 0
            && NoteHelp.reusable(expectedCommon: canonical + "/.git", actualCommon: actual, branch: branch, actualBranch: head.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What a note's saved worktree is, checked (`ownedTree`).
    enum TreeCheck: Equatable { case owned(tree: String, checkout: String), notOwned, stopped }

    /// A note's saved worktree, checked before anything works in it or removes it (a second opinion, the cleanup when
    /// its pull request merged or the person says it's done): where Petal keeps this note's worktree of its saved
    /// checkout (NoteHelp.reviewTreeOK), that checkout's, on the branch stored. Owned: its canonical paths, the only
    /// ones used after. Off the main thread.
    nonisolated static func ownedTree(_ stored: NoteHelp.Worktree, noteID: String, token: RunToken) -> TreeCheck {
        let resolved = { (path: String) in NoteHelp.standard(URL(fileURLWithPath: path).resolvingSymlinksInPath().path) }
        let canonical = resolved(stored.checkout)
        let tree = resolved(stored.path)
        let worktrees = resolved(Config.supportFolder.appending(path: "Worktrees").path)
        guard NoteHelp.reviewTreeOK(stored, resolvedTree: tree, canonicalCheckout: canonical, noteID: noteID, worktrees: worktrees),
              FileManager.default.fileExists(atPath: tree + "/.git") else { return .notOwned }
        switch verified(tree, canonical: canonical, branch: stored.branch, token: token) {
        case .none: return .stopped
        case .some(true): return .owned(tree: tree, checkout: canonical)
        case .some(false): return .notOwned
        }
    }

    static func verifyTree(_ stored: NoteHelp.Worktree, noteID: String, token: RunToken, _ done: @escaping @MainActor (TreeCheck) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ownedTree(stored, noteID: noteID, token: token)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
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
    /// The cover helpers read and write, by the same rule as privacy (NoteHelp.coverChoice): "About this
    /// notebook*.md" in the notebook's own folder, never a note that only says `cover: true`.
    func coverChoice(of notebook: String) -> NoteHelp.CoverChoice {
        guard let store, let book = store.notebooks.first(where: { $0.name == notebook }) else { return .notHere }
        let folder = book.folder.standardizedFileURL.path
        let candidates = store.notes.filter { $0.notebook == notebook }.map {
            NoteHelp.CoverCandidate(key: $0.key, name: $0.url.lastPathComponent, inFolder: $0.url.deletingLastPathComponent().standardizedFileURL.path == folder,
                                    version: $0.version != nil, readOnly: store.readOnly($0))
        }
        // (Not read yet, as the store's one reading of the folder found it: its cover file or a version of it unread.)
        return NoteHelp.coverChoice(candidates, unread: book.coverUnread || book.privacyUnknown ? 1 : 0)
    }

    /// The notebook's one cover, when there's one to read.
    func cover(of notebook: String) -> PaperNote? {
        guard case .one(let key) = coverChoice(of: notebook) else { return nil }
        return store?.paper(key)
    }

    /// The cover to change (memory, morning notes): the one cover; else nothing is written and the note says why.
    /// `none`: what's said when there's no cover, from the notebook's name (shielded).
    private func coverToChange(_ paper: PaperNote, none: @escaping @MainActor (Shielded) -> Shielded) -> PaperNote? {
        switch coverChoice(of: paper.notebook) {
        case .one(let key): if let cover = store?.paper(key) { return cover }
        case .none: reply(paper.noteID, giveBack: taking, [paper.notebook]) { none($0[0]) }; return nil
        case .conflict: reply(paper.noteID, giveBack: taking, [paper.notebook]) { "\($0[0])'s cover has two versions: keep one first, then ask again." }; return nil
        case .notHere: break
        }
        reply(paper.noteID, giveBack: taking, [paper.notebook]) { "\($0[0])'s cover isn't here yet. Ask again in a moment." }
        return nil
    }

    /// Private notebooks come from the one place that reads them (NotePrivacy over NoteStore.privateBooks: a cover
    /// that says so, or one not read yet, unknown, which counts as Private; a notebook a held note is in that the
    /// read didn't find, too). Whether a notebook counts as Private now, for anyone outside it.
    func isPrivate(_ notebook: String) -> Bool { !mayRead(notebook, from: nil) }

    /// Whether a note may read `notebook`: always its own; a Private (or unknown) one never from outside it.
    func mayRead(_ notebook: String, from paper: PaperNote?) -> Bool {
        guard let store else { return false }
        return NotePrivacy.readable(notebook: notebook, privateBooks: store.privateBooks, asker: paper?.notebook)
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
        let notes = store.notes.filter { $0.version == nil && $0.key != key && !NoteLibrary.isCoverName($0.url.lastPathComponent) && mayRead($0.notebook, from: paper) }
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
