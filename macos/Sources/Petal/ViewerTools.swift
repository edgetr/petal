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
        let send: (Any) -> Void = { value in Self.shielded(value) { out in if let out { answer(out) } else { refuse(NoteShield.unreadable) } } }
        let fail: (String) -> Void = { text in Self.shielded(text) { out in refuse(out as? String ?? NoteShield.unreadable) } }
        guard app.paper.on else { return fail("Petal Notes is off in Petal's settings (notes); the viewer is part of it.") }
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
                    model.whenLoaded(within: Self.loadLimit) { answer in
                        // Closed while it was read: said so, never a page count or "still loading".
                        if answer == .closed { return fail(Self.closedText) }
                        var told = self.told(model)
                        if let page, !model.live, model.pageCount > 0, ViewerPages.index(page, count: model.pageCount) == nil {
                            told["note"] = "It has \(model.pageCount) \(model.unit.word)s; \(model.unit.word) \(page) isn't one, so it shows \(model.unit.word) \(model.current + 1)."
                        }
                        send(told)
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
                            send(["set": set.id, "file": model.name,
                                  "versions": set.versions.map { ["id": $0.id, "name": $0.label, "path": $0.url.path] },
                                  "note": "Copies in a folder of Petal's own, shown under the document with Use this. Change the copies (never the file itself); their pictures follow. petal_view_pick tells you which one the person picks. Newer versions replace these (their copies go, but a picked one; one you changed goes to the Trash), and every copy goes when the viewer closes: read the picked one while it's open."])
                        }
                    }
                }
            }
        case "petal_view_pick":
            guard let set = versionSets[args["set"] as? String ?? ""], set.asker == caller else {
                return fail("No versions by that id were made for you (petal_view_versions makes them).")
            }
            let answer = { (picked: ViewerVersion?) in
                if let picked { send(["picked": ["id": picked.id, "name": picked.label, "path": picked.url.path]]) }
                else { send(["picked": NSNull(), "note": set.closed ? "The viewer was closed without a pick." : "Not picked yet."]) }
            }
            if let id = set.picked, let version = set.versions.first(where: { $0.id == id }) { return answer(version) }
            let wait = min(120, max(0, (args["wait"] as? NSNumber)?.doubleValue ?? 0))
            guard wait > 0, !set.closed else { return answer(nil) }
            var answered = false
            let once = { (version: ViewerVersion?) in
                guard !answered else { return }
                answered = true
                if live() { answer(version) }
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
                            self.comments(url, opened: path, intoOriginal: original, caller: caller, live: live, send, fail)
                        }
                    }
                }
            }
        default:
            fail("Unknown tool \(name)")
        }
    }

    /// `value` with the vault's secrets taken out (off the main thread); nil while the vault can't be read.
    static func shielded(_ value: Any, _ done: @escaping @MainActor (Any?) -> Void) {
        let carried = ViewerCarry(value)
        queue.async {
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
