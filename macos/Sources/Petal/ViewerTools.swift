import AppKit

/// Petal's viewer for Petal AI and the person's other agents, through Assist's socket: `petal_view` opens a file
/// the agent names (checked: a regular file the person owns, never through a link out of the home folder);
/// `petal_view_versions` makes named copies in Petal's own versions folder and shows them under the document;
/// `petal_view_pick` tells the agent which one the person picked ("Use this"), only the agent that asked;
/// `petal_note_pdf_comments` writes the notes on a PDF into it as comments (a copy beside it by default; the PDF
/// itself only when asked, after the person allows it, keeping the original beside it). No note's words are told:
/// the answers name the file the agent gave and the copies Petal made.
extension Viewers {
    func handle(_ name: String, _ args: [String: Any], caller: String, live: @escaping @Sendable () -> Bool,
                _ answer: @escaping (Any) -> Void, _ refuse: @escaping (String) -> Void) {
        // Everything told goes through the vault's redaction first (NoteShield, as the note tools' answers): file
        // names, labels, copies' names and paths. While the vault can't be read, nothing is told.
        let fail: (String) -> Void = { text in Self.shielded(text) { out in if live() { refuse(out as? String ?? NoteShield.unreadable) } } }
        // The one way an answer goes out (`told`): made from the state it describes, redacted off the main thread
        // (which may wait on the vault), then that state read again right before it's delivered. Still the same,
        // it goes; changed meanwhile (the original replaced, the viewer closed, a pick held back), the answer is
        // made again from what's true now, never the earlier one. Nothing goes to an asker that hung up.
        func told(_ make: @escaping @MainActor () -> Told, attempt: Int = 0) {
            let first = make()
            guard let value = first.value else { return fail(first.refusal ?? NoteShield.unreadable) }
            Self.shielded(value) { out in
                guard live() else { return }
                guard make().mark == first.mark else {
                    // Three tries at most: a viewer that never settles is said so, not told stale.
                    return attempt < 2 ? told(make, attempt: attempt + 1) : fail("The viewer kept changing while Petal answered: ask again.")
                }
                if let out { answer(out) } else { refuse(NoteShield.unreadable) }
            }
        }
        guard app.paper.on else { return fail("Petal Notes is off in Petal's settings (notes); the viewer is part of it.") }
        // The viewer's tools that tell or use the notes (how many are on a document, a PDF's notes as comments) wait
        // for the notes to be ready, as the note tools do: never a count or comments from notes not read yet.
        if ["petal_view", "petal_note_pdf_comments"].contains(name), !app.paper.acceptsChanges { return fail(NoteStore.gettingReady) }
        let path = args["path"] as? String ?? ""
        switch name {
        case "petal_view":
            // A page counts from 1; a number that isn't one is refused before anything is worked out from it.
            let page = ViewerPages.requested(args["page"])
            if args["page"] != nil, page == nil { return fail("page counts from 1 (a whole number).") }
            open(path: path, page: page, live: live) { result in
                guard live() else { return }
                switch result {
                case .failure(let refusal): fail(refusal.description)
                case .success(let model):
                    model.whenLoaded(within: Self.loadLimit) { _ in
                        // What it shows as the answer goes out: closed meanwhile (while it was read, or while the
                        // answer was redacted), said so, never a page count or "still loading"; reloaded or replaced
                        // meanwhile, told again as it is then.
                        told {
                            guard !model.isClosed else { return Told(refusal: Self.closedText) }
                            var told = self.told(model)
                            // The page asked for is checked only against a finished document: while it loads or
                            // reloads the answer says it's loading (never the pages of the document before).
                            if let page, !model.loading, !model.live, model.pageCount > 0, ViewerPages.index(page, count: model.pageCount) == nil {
                                told["note"] = "It has \(model.pageCount) \(model.unit.word)s; \(model.unit.word) \(page) isn't one, so it shows \(model.unit.word) \(model.current + 1)."
                            }
                            return Told(told, state: model.shownState)
                        }
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

    /// How long `petal_view` waits for a document to be read (Quick Look's export and WebKit's pages, a file iCloud
    /// brings down first), under the socket's own 150 seconds.
    static let loadLimit: Double = 120
    /// What `petal_view` says when the viewer closed before the document was read.
    nonisolated static let closedText = "The viewer was closed before the document was read: nothing to tell."

    /// What `petal_view` says about a file once it's shown: its name, how it's shown, and its pages or slides; still
    /// being read at the limit, that it's still loading (never a count of pages it hasn't read yet).
    func told(_ model: ViewerModel) -> [String: Any] {
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
        result["notes"] = model.notes.count
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
            guard paper.version == nil, let index = ViewerMatch.place(paper.file.places, onFile: { onFile.contains(ViewerFiles.key($0)) }) else { return nil }
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
                    // redaction, left out while the vault can't be read.
                    let line = "Wrote \(count) note\(count == 1 ? "" : "s") into a PDF as comments"
                    Self.shielded(file.lastPathComponent) { name in
                        self.app.assist.did((name as? String).map { line + " (\($0))" } ?? line, undo: nil)
                    }
                    send(["wrote": count, "file": file.lastPathComponent,
                          "where": intoOriginal ? "into the PDF itself; the original is kept beside it" : "a copy beside the PDF"])
                }
            }
        }
        guard intoOriginal else { return write() }
        // Changing the person's own file: asked first, whoever asks.
        app.assist.ask("pdfComments", "Write \(comments.count) note\(comments.count == 1 ? "" : "s") into \(pdf.lastPathComponent) as comments?",
                       detail: "Petal keeps the PDF as it is now beside it, named “… (before notes)”.",
                       always: true, owner: caller) { allowed in
            guard allowed else { return fail("The person said Don't: nothing was written.") }
            write()
        }
    }
}
