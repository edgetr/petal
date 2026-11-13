import AppKit

/// Petal's viewer for Petal AI and the person's other agents, through Assist's socket: `petal_view` opens a file
/// the agent names (checked: a regular file the person owns, never through a link out of the home folder);
/// `petal_view_versions` makes named copies in Petal's own versions folder and shows them under the document;
/// `petal_view_pick` tells the agent which one the person picked ("Use this"), only the agent that asked;
/// `petal_note_pdf_comments` writes the notes on a PDF into it as comments (a copy beside it by default; the PDF
/// itself only when asked, after the person allows it, keeping the original beside it). No note's words are told:
/// the answers name the file the agent gave and the copies Petal made. The notes an answer counts, and the notes
/// written into a PDF for an agent, are sources like any other: only those their asker may read (a Private
/// notebook's only for a helper of a note inside it: NoteHelpers.mayRead, the note tools' rule), and a note's helper
/// is answered only through its admission gate (Assist.handle, NoteHelpers.admitTool: before the tool, and again
/// right before its answer).
extension Viewers {
    /// Whether an agent may be told of (or handed, in a PDF's comments) a note: a Private notebook's only for a
    /// helper of a note inside it. `caller` nil: the person themselves (the viewer's own button).
    func readable(_ paper: PaperNote, by caller: String?) -> Bool {
        guard let caller else { return true }
        let helpers = app.paper.helpers
        let asking = app.claude.note(withID: caller)?.paper.flatMap { helpers.paper($0) }
        return helpers.mayRead(paper.notebook, from: asking)
    }

    func handle(_ name: String, _ args: [String: Any], caller: String, live: @escaping @Sendable () -> Bool,
                _ answer: @escaping (Any) -> Void, _ refuse: @escaping (String) -> Void) {
        // Everything told goes through the vault's redaction first (NoteShield, as the note tools' answers): file
        // names, labels, copies' names and paths. While the vault can't be read, nothing is told.
        let fail: (String) -> Void = { text in Self.shielded(text) { out in if live() { refuse(out as? String ?? NoteShield.unreadable) } } }
        // The one way an answer goes out (`told`): made from the state it describes, redacted off the main thread
        // (which may wait on the vault), then that state read again right before it's delivered. Still the same,
        // it goes; changed meanwhile (the original replaced, the viewer closed, a pick held back), the answer is
        // made again from what's true now, never the earlier one. Nothing goes to an asker that hung up.
        /// `fit`: the redacted answer made to fit (a page's words cut short only once they're redacted whole).
        func told(_ make: @escaping @MainActor () -> Told, attempt: Int = 0, fit: @escaping @MainActor (Any) -> Any = { $0 }) {
            let first = make()
            guard let value = first.value else { return fail(first.refusal ?? NoteShield.unreadable) }
            Self.shielded(value) { out in
                guard live() else { return }
                guard make().mark == first.mark else {
                    // Three tries at most: a viewer that never settles is said so, not told stale.
                    return attempt < 2 ? told(make, attempt: attempt + 1, fit: fit) : fail("The viewer kept changing while Petal answered: ask again.")
                }
                if let out { answer(fit(out)) } else { refuse(NoteShield.unreadable) }
            }
        }
        guard app.paper.on else { return fail("Petal Notes is off in Petal's settings (notes); the viewer is part of it.") }
        // The viewer's tools that tell or use the notes (how many are on a document, a PDF's notes as comments) wait
        // for the notes to be ready, as the note tools do: never a count or comments from notes not read yet.
        if ["petal_view", "petal_note_pdf_comments"].contains(name), !app.paper.acceptsChanges { return fail(NoteStore.gettingReady) }
        let path = args["path"] as? String ?? ""
        // A note's helper naming no file means its note's own document: found by the one resolver the margin uses
        // (off the main thread), then asked again with that path.
        // The run's own document, never a guess between two.
        if path.isEmpty, ["petal_view", "petal_view_versions", "petal_note_pdf_comments"].contains(name),
           let paperID = app.claude.note(withID: caller)?.paper {
            let stick: NoteStick
            switch app.paper.helpers.document(for: paperID) {
            case .one(let one): stick = one
            case .none: return fail("This note isn't on a document: pass the file's path.")
            case .several(let files):
                let names = files.map { ($0.path as NSString).lastPathComponent }.filter { !$0.isEmpty }
                return fail("This note is on \(files.count) documents (\(names.joined(separator: ", "))): pass the path of the one you mean.")
            }
            let mac = app.paper.local.mac
            nonisolated(unsafe) let args = args
            DispatchQueue.global(qos: .userInitiated).async {
                let found = ViewerFiles.locate(stick, mac: mac, follow: ViewerLoader.follow)?.path
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let found else { return fail("Petal can't find this note's document now (moved or deleted?): pass its path.") }
                        var named = args
                        named["path"] = found
                        self.handle(name, named, caller: caller, live: live, answer, refuse)
                    }
                }
            }
            return
        }
        switch name {
        case "petal_view":
            // Every page's words at once (pages: "all"), up to `allLimit`.
            if args["pages"] as? String == "all" { return viewAll(path: path, caller: caller, live: live, told: told, fail: fail) }
            // A page counts from 1; a number that isn't one is refused before anything is worked out from it.
            let page = ViewerPages.requested(args["page"])
            if args["page"] != nil, page == nil { return fail("page counts from 1 (a whole number).") }
            open(path: path, page: page, live: live) { result in
                guard live() else { return }
                switch result {
                case .failure(let refusal): fail(refusal.description)
                case .success(let model):
                    model.whenLoaded(within: Self.loadLimit) { _ in
                        // The words of the page it shows, read off the main thread from this load's own copy of the
                        // document (ViewerText), told with the rest: redacted whole with the answer, cut short after.
                        let source = model.text
                        let shown = model.current
                        let tell = { (words: String?) in
                            // What it shows as the answer goes out: closed meanwhile (while it was read, or while the
                            // answer was redacted), said so, never a page count or "still loading"; reloaded or replaced
                            // meanwhile, told again as it is then.
                            told({
                                guard !model.isClosed else { return Told(refusal: Self.closedText) }
                                var told = self.told(model, caller: caller)
                                // The page asked for is checked only against a finished document: while it loads or
                                // reloads the answer says it's loading (never the pages of the document before).
                                if let page, !model.loading, !model.live, model.pageCount > 0, ViewerPages.index(page, count: model.pageCount) == nil {
                                    told["note"] = "It has \(model.pageCount) \(model.unit.word)s; \(model.unit.word) \(page) isn't one, so it shows \(model.unit.word) \(model.current + 1)."
                                }
                                // Only the page still shown, of the load its words were read from.
                                if let words, !words.isEmpty, !model.loading, model.text === source, model.current == shown {
                                    told[model.unit.word] = shown + 1
                                    told["text"] = words
                                }
                                return Told(told, state: model.shownState)
                            }, fit: Self.fitText)
                        }
                        guard let source, !model.loading, !model.live, model.pageCount > 0 else { return tell(nil) }
                        source.read(page: shown, selected: NSRange(location: NSNotFound, length: 0), paragraph: { _ in nil }) { text, _, _ in tell(text) }
                    }
                }
            }
        case "petal_view_versions":
            let labels = (args["names"] as? [Any] ?? []).compactMap { $0 as? String }
            open(path: path, show: true, live: live) { result in
                guard live() else { return }
                switch result {
                case .failure(let refusal): fail(refusal.description)
                case .success(let model):
                    model.makeVersions(labels, asker: caller, live: live) { made in
                        switch made {
                        case .failure(let error): fail(error.description)
                        case .success(let set):
                            // Told only while these are still the versions shown in an open viewer (closed or
                            // replaced while the answer was redacted, their copies are gone: said so); the original
                            // changed meanwhile, the copies stay and that's said with them.
                            told {
                                guard !model.isClosed, !set.closed else { return Told(refusal: ViewerCopyError.cancelled.description) }
                                guard model.versions === set else { return Told(refusal: ViewerCopyError.superseded.description) }
                                let held = model.pickSuspended(set)
                                let note = "Copies in a folder of Petal's own, shown under the document with Use this. Change the copies (never the file itself); their pictures follow. petal_view_pick tells you which one the person picks. Newer versions replace these (their copies go, but a picked one; one you changed goes to the Trash), and every copy goes when the viewer closes: read the picked one while it's open."
                                return Told(["set": set.id, "file": model.name,
                                             "versions": set.versions.map { ["id": $0.id, "name": $0.label, "path": $0.url.path] },
                                             "note": held.map { $0 + " " + note } ?? note],
                                            state: model.shownState)
                            }
                        }
                    }
                }
            }
        case "petal_view_pick":
            guard let set = versionSets[args["set"] as? String ?? ""], set.asker == caller else {
                return fail("No versions by that id were made for you (petal_view_versions makes them).")
            }
            // A pick is told only while the viewer's loaded document is the very original the versions were made from,
            // unchanged (ViewerVersionSet.pickState); else why it's held back (the copies stay). Read again after
            // the redaction, right before it goes: the original changed or the viewer closed meanwhile, the answer
            // is that, never the pick.
            let answer = {
                told {
                    switch set.pickState {
                    case .picked(let picked):
                        Told(["picked": ["id": picked.id, "name": picked.label, "path": picked.url.path],
                              "note": "The original is as it was when these were made. Change it only after the person allows it, and ask petal_view_pick again right before you do: once the original changes, the pick isn't told."],
                             state: set.viewer?.shownState ?? [])
                    case .suspended(let reason): Told(["picked": NSNull(), "note": reason], state: set.viewer?.shownState ?? [])
                    case .closed:
                        Told(["picked": NSNull(), "note": set.picked == nil ? "The viewer was closed without a pick." : "The viewer was closed, and its copies went with it."])
                    case .waiting: Told(["picked": NSNull(), "note": "Not picked yet."], state: set.viewer?.shownState ?? [])
                    }
                }
            }
            let wait = min(120, max(0, (args["wait"] as? NSNumber)?.doubleValue ?? 0))
            guard wait > 0, case .waiting = set.pickState else { return answer() }
            var answered = false
            let once = { (_: ViewerVersion?) in
                guard !answered else { return }
                answered = true
                if live() { answer() }
            }
            set.waiting.append(once)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { once(nil) }
        case "petal_note_pdf_comments":
            let original = args["into_original"] as? Bool ?? false
            Self.queue.async {
                let checked = ViewerPath.check(path)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard live() else { return }
                        switch checked {
                        case .failure(let refusal): fail(refusal.description)
                        case .success(let url):
                            guard ViewerKind.of(url.path) == .pdf else { return fail("Comments go into a PDF; that file isn't one.") }
                            // What was written is a fact of its own (no viewer's state): told while its asker is there.
                            self.comments(url, opened: path, intoOriginal: original, caller: caller, live: live,
                                          { value in told { Told(value) } }, fail)
                        }
                    }
                }
            }
        default:
            fail("Unknown tool \(name)")
        }
    }

    /// An answer as it's made from the state it describes: what's told (or why it's refused), and `mark`, one value
    /// built from everything the answer states (the answer itself, so a field added to an answer later is in the
    /// mark by construction) and from the viewer's state behind it (`state`: its file's name and path, identity and
    /// stamp, loading, pages and page shown). The same mark after the redaction means the answer still holds.
    struct Told {
        var value: Any?
        var refusal: String?
        var mark: String

        init(_ value: Any, state: [String] = []) {
            self.value = value
            mark = Self.mark(of: ["answer": value, "state": state])
        }

        init(refusal: String) {
            self.refusal = refusal
            mark = Self.mark(of: ["refused": refusal])
        }

        /// A value as one word: its JSON with keys sorted (what an answer is sent as), else its description.
        static func mark(of value: Any) -> String {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "\(value)" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Petal --viewer-check only: run off the main thread just before an answer is redacted (a slow vault read).
    nonisolated(unsafe) static var shielding: (() -> Void)?

    /// `value` with the vault's secrets taken out (off the main thread); nil while the vault can't be read.
    static func shielded(_ value: Any, _ done: @escaping @MainActor (Any?) -> Void) {
        let carried = ViewerCarry(value)
        queue.async {
            shielding?()
            let out = ViewerCarry(VaultIndex.settled { $0.unreadable ? nil : NoteShield.shield(carried.value as Any, index: $0) } ?? nil)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(out.value) } }
        }
    }

    /// A page's words in `petal_view`'s answer, made to fit once the whole answer is redacted (never cut before).
    static let textLimit = 12_000
    /// The most of every page's words `pages: "all"` tells at once.
    nonisolated static let allLimit = 40_000

    /// Every page's words, in order, each under its number, read one page at a time off the main thread; told with
    /// the rest, redacted whole with the answer, then cut to `allLimit` (saying which page it reached).
    private func viewAll(path: String, caller: String, live: @escaping @Sendable () -> Bool,
                         told: @escaping (@escaping @MainActor () -> Told, Int, @escaping @MainActor (Any) -> Any) -> Void,
                         fail: @escaping (String) -> Void) {
        open(path: path, page: nil, live: live) { result in
            guard live() else { return }
            switch result {
            case .failure(let refusal): fail(refusal.description)
            case .success(let model):
                model.whenLoaded(within: Self.loadLimit) { _ in
                    guard let source = model.text, !model.loading, !model.live, model.pageCount > 0 else {
                        return told({ model.isClosed ? Told(refusal: Self.closedText) : Told(self.told(model, caller: caller), state: model.shownState) }, 0, { $0 })
                    }
                    let count = model.pageCount, word = model.unit.word
                    var pages: [String] = []
                    func next(_ index: Int) {
                        guard live() else { return }
                        guard index < count, pages.reduce(0, { $0 + $1.count }) < Self.allLimit else {
                            let reached = index
                            return told({
                                guard !model.isClosed else { return Told(refusal: Self.closedText) }
                                var answer = self.told(model, caller: caller)
                                guard !model.loading, model.text === source else { return Told(answer, state: model.shownState) }
                                answer["text"] = pages.joined(separator: "\n\n")
                                if reached < count { answer["textCut"] = "This goes to \(word) \(reached); ask with page for the rest." }
                                return Told(answer, state: model.shownState)
                            }, 0, { out in
                                guard var all = out as? [String: Any], let text = all["text"] as? String, text.count > Self.allLimit else { return out }
                                all["text"] = String(text.prefix(Self.allLimit)) + "…"
                                all["textCut"] = "This is the start of the document's words; ask with page for the rest."
                                return all
                            })
                        }
                        source.read(page: index, selected: NSRange(location: NSNotFound, length: 0), paragraph: { _ in nil }) { text, _, _ in
                            if let text, !text.isEmpty { pages.append("— \(word) \(index + 1) —\n" + text) }
                            next(index + 1)
                        }
                    }
                    next(0)
                }
            }
        }
    }
    static func fitText(_ answer: Any) -> Any {
        guard var told = answer as? [String: Any], let text = told["text"] as? String, text.count > textLimit else { return answer }
        told["text"] = String(text.prefix(textLimit)) + "…"
        told["textCut"] = "This is the start of the page; it goes on."
        return told
    }

    /// How long `petal_view` waits for a document to be read (Quick Look's export and WebKit's pages, a file iCloud
    /// brings down first), under the socket's own 150 seconds.
    static let loadLimit: Double = 120
    /// What `petal_view` says when the viewer closed before the document was read.
    nonisolated static let closedText = "The viewer was closed before the document was read: nothing to tell."

    /// What `petal_view` says about a file once it's shown: its name, how it's shown, and its pages or slides; still
    /// being read at the limit, that it's still loading (never a count of pages it hasn't read yet).
    /// `caller`: who's told (its notes are counted only as far as it may read them).
    func told(_ model: ViewerModel, caller: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["opened": model.name]
        if model.loading {
            result["loading"] = true
            result["note"] = "It's open in Petal's viewer and still being read (Quick Look or iCloud is still working on it); ask again with petal_view for its pages."
            return result
        }
        if let problem = model.problem { result["note"] = problem; return result }
        if model.live {
            result["shown"] = "through Quick Look (notes go on the file)"
        } else {
            result["shown"] = model.kind == .pdf ? "PDF" : "Quick Look's pages"
            result[model.unit == .slide ? "slides" : "pages"] = model.pageCount
        }
        result["notes"] = model.notes.filter { readable($0.paper, by: caller) }.count
        return result
    }


    /// The notes on a PDF as comments (ViewerPDFComments): into a copy beside it, or into the PDF itself once the
    /// person allows it.
    func comments(_ pdf: URL, opened: String, intoOriginal: Bool, caller: String?, live: @escaping @Sendable () -> Bool = { true },
                  _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        // The notes on this PDF by the one resolver the margin uses (ViewerFiles: each place's own file wherever it
        // went, else its bookmark's, else its path's), worked out off the main thread.
        // The PDF's incarnation is captured now, before the person is asked: what they allow is this very file, and a
        // file that replaced it meanwhile is never written (checked again inside the write).
        let places = app.paper.store.notes.flatMap { $0.file.places.filter(ViewerFiles.namesFile) }
        let mac = app.paper.local.mac
        Self.queue.async {
            let id = ViewerFileID.of(pdf.path)
            let found = id.map { ViewerFiles.on($0, places, mac: mac, follow: ViewerLoader.follow) } ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard live() else { return fail(NoteDesk.hungUp) }
                    guard let id else { return fail("Petal can't read that file now.") }
                    self.comments(pdf, file: id, onFile: found, intoOriginal: intoOriginal, caller: caller, live: live, send, fail)
                }
            }
        }
    }

    private func comments(_ pdf: URL, file: ViewerFileID, onFile: Set<String>, intoOriginal: Bool, caller: String?, live: @escaping @Sendable () -> Bool,
                          _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        let comments = app.paper.store.notes.compactMap { paper -> ViewerPDFComments.Comment? in
            // For an agent, only the notes it may read (a Private notebook's never leave it in a file an agent reads).
            guard paper.version == nil, readable(paper, by: caller),
                  let index = ViewerMatch.place(paper.file.places, onFile: { onFile.contains(ViewerFiles.key($0)) }) else { return nil }
            // The words as written: the writer redacts them whole before anything is cut.
            return ViewerPDFComments.Comment(stick: paper.file.places[index], body: paper.file.body,
                                            color: PaperLook.rgb(app.paper.store.color(of: paper.notebook)))
        }
        guard !comments.isEmpty else { return fail("No notes are on this PDF yet.") }
        let write = {
            guard live() else { return fail(NoteDesk.hungUp) }
            // Its asker hanging up stops it right up to the change (checked inside the coordinated write).
            ViewerPDFComments.write(pdf, comments: comments, intoOriginal: intoOriginal, author: NSFullUserName(), expected: file, live: live) { outcome in
                switch outcome {
                case .failed(let text): fail(text)
                case .wrote(let file, let count):
                    // What Petal AI did is kept in ai-history.json: the file's name only through the vault's settled
                    // redaction, left out while the vault can't be read (Assist.did, as every line there).
                    let notes: HistoryLine = count == 1 ? "note" : "notes"
                    self.app.assist.did("Wrote \(count) \(notes) into a PDF as comments\(named: " (" + file.lastPathComponent + ")", else: "")", undo: nil)
                    send(["wrote": count, "file": file.lastPathComponent,
                          "where": intoOriginal ? "into the PDF itself; the original is kept beside it" : "a copy beside the PDF"])
                }
            }
        }
        guard intoOriginal else { return write() }
        // Changing the person's own file: asked first, whoever asks.
        let writing = "\(comments.count) note\(comments.count == 1 ? "" : "s") into \(pdf.lastPathComponent) as comments"
        app.assist.ask("pdfComments", "Write \(writing)?", wants: "write \(writing)",
                       detail: "Petal keeps the PDF as it is now beside it, named “… (before notes)”.",
                       always: true, owner: caller) { allowed in
            guard allowed else { return fail("The person said Don't: nothing was written.") }
            write()
        }
    }
}
