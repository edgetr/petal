import AppKit

/// Petal's viewer for Petal AI and the person's other agents, through Assist's socket: `petal_view` opens a file
/// the agent names (checked: a regular file the person owns, never through a link out of the home folder);
/// `petal_view_versions` makes named copies in a temporary folder and shows them under the document;
/// `petal_view_pick` tells the agent which one the person picked ("Use this"), only the agent that asked;
/// `petal_note_pdf_comments` writes the notes on a PDF into it as comments (a copy beside it by default; the PDF
/// itself only when asked, after the person allows it, keeping the original beside it). No note's words are told:
/// the answers name the file the agent gave and the copies Petal made.
extension Viewers {
    func handle(_ name: String, _ args: [String: Any], caller: String, live: @escaping @Sendable () -> Bool,
                _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        guard app.paper.on else { return fail("Petal Notes is off in Petal's settings (notes); the viewer is part of it.") }
        let path = args["path"] as? String ?? ""
        switch name {
        case "petal_view":
            let page = (args["page"] as? NSNumber)?.intValue
            open(path: path, page: page) { result in
                guard live() else { return }
                switch result {
                case .failure(let refusal): fail(refusal.description)
                case .success(let model): self.loaded(model) { send(self.told(model)) }
                }
            }
        case "petal_view_versions":
            let labels = (args["names"] as? [Any] ?? []).compactMap { $0 as? String }
            open(path: path, show: true) { result in
                guard live() else { return }
                switch result {
                case .failure(let refusal): fail(refusal.description)
                case .success(let model):
                    model.makeVersions(labels, asker: caller) { made in
                        switch made {
                        case .failure(let error): fail(error.description)
                        case .success(let set):
                            send(["set": set.id, "file": model.name,
                                  "versions": set.versions.map { ["name": $0.label, "path": $0.url.path] },
                                  "note": "Copies in a temporary folder, shown under the document with Use this. Change the copies (never the file itself); their pictures follow. petal_view_pick tells you which one the person picks."])
                        }
                    }
                }
            }
        case "petal_view_pick":
            guard let set = versionSets[args["set"] as? String ?? ""], set.asker == caller else {
                return fail("No versions by that id were made for you (petal_view_versions makes them).")
            }
            let answer = { (picked: ViewerVersion?) in
                if let picked { send(["picked": ["name": picked.label, "path": picked.url.path]]) }
                else { send(["picked": NSNull(), "note": set.closed ? "The viewer was closed without a pick." : "Not picked yet."]) }
            }
            if let label = set.picked, let version = set.versions.first(where: { $0.label == label }) { return answer(version) }
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
            let home = NSHomeDirectory()
            Self.queue.async {
                let checked = ViewerPath.check(path, home: home)
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

    /// What `petal_view` says about a file once it's shown: its name, how it's shown, and its pages or slides.
    private func told(_ model: ViewerModel) -> [String: Any] {
        var result: [String: Any] = ["opened": model.name]
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

    /// Waits (a few seconds at most) for a model to finish loading.
    private func loaded(_ model: ViewerModel, tries: Int = 0, _ done: @escaping @MainActor () -> Void) {
        if !model.loading || tries > 40 { return done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.loaded(model, tries: tries + 1, done) }
    }

    /// The notes on a PDF as comments (ViewerPDFComments): into a copy beside it, or into the PDF itself once the
    /// person allows it.
    func comments(_ pdf: URL, opened: String, intoOriginal: Bool, caller: String?, live: @escaping @Sendable () -> Bool = { true },
                  _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        let paths = [pdf.path, opened]
        let comments = app.paper.store.notes.compactMap { paper -> ViewerPDFComments.Comment? in
            guard paper.version == nil, let index = ViewerMatch.place(paper.file.places, path: pdf.path, also: paths) else { return nil }
            return ViewerPDFComments.Comment(stick: paper.file.places[index], text: ViewerComments.text(paper.file.body),
                                            color: PaperLook.rgb(app.paper.store.color(of: paper.notebook)))
        }
        guard !comments.isEmpty else { return fail("No notes are on this PDF yet.") }
        let write = {
            guard live() else { return fail(NoteDesk.hungUp) }
            ViewerPDFComments.write(pdf, comments: comments, intoOriginal: intoOriginal, author: NSFullUserName()) { outcome in
                switch outcome {
                case .failed(let text): fail(text)
                case .wrote(let file, let count):
                    self.app.assist.did("Wrote \(count) note\(count == 1 ? "" : "s") into \(pdf.lastPathComponent) as comments", undo: nil)
                    send(["wrote": count, "file": file.lastPathComponent,
                          "where": intoOriginal ? "into the PDF itself; the original is kept beside it" : "a copy beside the PDF"])
                }
            }
        }
        guard intoOriginal else { return write() }
        // Changing the person's own file: asked first, whoever asks.
        app.assist.ask("pdfComments", "Write \(comments.count) note\(comments.count == 1 ? "" : "s") into \(pdf.lastPathComponent) as comments?",
                       detail: "Petal keeps the PDF as it is now beside it, as “\(ViewerCopies.beforeNotes(original: pdf.lastPathComponent, taken: []))”.",
                       always: true, owner: caller) { allowed in
            guard allowed else { return fail("The person said Don't: nothing was written.") }
            write()
        }
    }
}
