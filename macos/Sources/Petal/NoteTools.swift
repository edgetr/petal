import AppKit

/// Petal Notes for Petal AI and the person's other agents (`petal_notes`, `petal_note_read`, `petal_note_write`,
/// `petal_note_move`, `petal_note_stick`, through Assist's socket). They read and write the person's note files;
/// nothing is ever deleted, and nothing a note says is run.
extension NoteDesk {
    static let tools: Set<String> = ["petal_notes", "petal_note_read", "petal_note_write", "petal_note_move", "petal_note_stick"]

    func handle(_ name: String, _ args: [String: Any], _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        guard on else { return fail("Petal Notes is off in Petal's settings (notes).") }
        switch name {
        case "petal_notes":
            let query = args["query"] as? String ?? ""
            let notebook = args["notebook"] as? String ?? ""
            let limit = min(200, max(1, (args["limit"] as? NSNumber)?.intValue ?? 30))
            let onlyHere = args["here"] as? Bool ?? false
            let found = store.notes.filter { paper in
                paper.version == nil && (notebook.isEmpty || paper.notebook.localizedCaseInsensitiveCompare(notebook) == .orderedSame)
                    && (!onlyHere || here[paper.key] != nil)
                    && NoteText.matches(query, paper.file.title + "\n" + paper.file.body + "\n" + paper.notebook)
            }
            send(["notes": found.prefix(limit).map(summary), "count": found.count,
                  "notebooks": store.notebooks.map { ["name": $0.name, "color": $0.color.isEmpty ? "accent" : $0.color, "notes": $0.count] },
                  "folder": store.root.path])
        case "petal_note_read":
            guard let paper = store.find(args["id"] as? String ?? "") else { return fail("No note with that id; petal_notes lists them.") }
            var result = summary(paper)
            result["text"] = paper.file.body
            result["file"] = paper.url.path
            result["created"] = NoteFile.stamp(paper.file.created)
            if paper.file.cover { result["cover"] = true }
            if (store.conflicts[paper.noteID]?.count ?? 0) > 1 { result["note"] = "This note changed on two Macs at once: the person sees both papers until they keep one." }
            send(result)
        case "petal_note_write":
            let text = args["text"] as? String ?? ""
            if let id = args["id"] as? String, !id.isEmpty {
                guard var paper = store.find(id) else { return fail("No note with that id; petal_notes lists them.") }
                let append = args["append"] as? Bool ?? false
                paper.file.body = append ? paper.file.body + (paper.file.body.isEmpty || paper.file.body.hasSuffix("\n") ? "" : "\n") + text : text
                persist(paper, send, fail) { ["written": $0.noteID, "title": $0.file.title, "file": $0.url.path] }
            } else {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fail("Nothing to write.") }
                var file = NoteFile(body: text)
                let notebook = (args["notebook"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultNotebook
                if args["stick"] as? String == "here" {
                    stickHere(nil, kind: args["to"] as? String) { place in
                        if let place { file.places = [place] }
                        _ = self.store.make(file, in: notebook) { made in
                            guard let made else { return fail(Self.notMade) }
                            send(["written": made.noteID, "title": made.file.title, "notebook": made.notebook, "file": made.url.path,
                                  "stuck": place.map(Self.describe) ?? "nowhere (nothing in front Petal could stick it to)"])
                        }
                    }
                    return
                }
                _ = store.make(file, in: notebook) { made in
                    guard let made else { return fail(Self.notMade) }
                    send(["written": made.noteID, "title": made.file.title, "notebook": made.notebook, "file": made.url.path])
                }
            }
        case "petal_note_move":
            guard let paper = store.find(args["id"] as? String ?? "") else { return fail("No note with that id; petal_notes lists them.") }
            let notebook = (args["notebook"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !notebook.isEmpty else { return fail("Which notebook? (a new name makes one)") }
            guard !store.readOnly(paper) else { return fail(Self.readOnlyWords) }
            editors[paper.key]?.flush()
            store.move(paper, to: notebook) { moved in
                if let moved { send(["moved": moved.noteID, "notebook": moved.notebook]) } else { fail("Couldn't move it.") }
            }
        case "petal_note_stick":
            guard let paper = store.find(args["id"] as? String ?? "") else { return fail("No note with that id; petal_notes lists them.") }
            if let remove = (args["remove"] as? NSNumber)?.intValue {
                guard paper.file.places.indices.contains(remove), paper.file.places.count > 1 else { return fail("A note keeps at least one place; remove is an index from places.") }
                var changed = paper
                changed.file.places.remove(at: remove)
                return persist(changed, send, fail, touch: false) { ["places": $0.file.places.map(Self.describe)] }
            }
            let also = args["also"] as? Bool ?? false
            stickHere(paper, kind: args["to"] as? String) { place in
                guard let place, var changed = self.store.paper(paper.key) else { return fail("Nothing in front Petal can stick it to.") }
                changed.file.places = also ? changed.file.places.filter { !$0.samePlace(place) } + [place] : [place]
                self.persist(changed, send, fail, touch: false) { saved in
                    self.refresh()
                    return ["places": saved.file.places.map(Self.describe)]
                }
            }
        default:
            fail("Unknown tool \(name)")
        }
    }

    static let readOnlyWords = "This note has two versions right now (it changed in two places at once): nothing was changed. The person keeps one with Keep this one on the paper; then try again."
    static let notMade = "Petal couldn't make the note's file. It keeps the note and tries again; nothing to do now."

    /// Saves a change for the AI and answers with what reached the disk: written; kept beside the note as a copy
    /// (it changed elsewhere meanwhile); or not saved (kept in Petal and tried again). A read-only paper is refused.
    private func persist(_ paper: PaperNote, _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void, touch: Bool = true,
                         _ result: @escaping @MainActor (PaperNote) -> [String: Any]) {
        guard !store.readOnly(paper) else { return fail(Self.readOnlyWords) }
        let saved = store.save(paper, touch: touch) { outcome in
            switch outcome {
            case .written: send(result(self.store.paper(paper.key) ?? paper))
            case .keptBoth(let copy):
                fail("The note changed elsewhere meanwhile, so this was kept beside it as “\(copy.lastPathComponent)”; the person picks which to keep.")
            case .failed:
                fail("Petal couldn't write the note's file. It keeps the change and tries again; nothing to do now.")
            }
        }
        if saved == nil { fail(Self.readOnlyWords) }
    }

    private func summary(_ paper: PaperNote) -> [String: Any] {
        ["id": paper.noteID, "title": paper.file.title, "notebook": paper.notebook, "preview": String(paper.file.preview.prefix(160)),
         "places": paper.file.places.map(Self.describe), "modified": NoteFile.stamp(paper.file.modified),
         "onScreen": here[paper.key] != nil]
    }

    /// What's in front now, read off the main thread, as one place: `kind` (tab, window, app, file, desktop) or the
    /// most specific there is (a passage only with a selection). An app kept private (`aiNeverLook`) gives no
    /// passage and no words: its selection is never read for the AI, checked again before the answer goes. A
    /// selection holding something from the vault isn't stuck to (VaultIndex, as petal_ui hides it).
    private func stickHere(_ paper: PaperNote?, kind: String?, _ done: @escaping @MainActor (NoteStick?) -> Void) {
        let wanted = kind.flatMap(NoteStick.Kind.init(rawValue:))
        if wanted == .desktop {
            var desk = NoteStick(kind: .desktop)
            desk.desktop = app.docks.focusedDock?.desktop
            desk.mode = app.docks.focusedDock?.mode?.id ?? ""
            return done(desk)
        }
        guard let running = NSWorkspace.shared.frontmostApplication, running.processIdentifier != getpid() else { return done(nil) }
        let name = running.localizedName ?? ""
        let pid = running.processIdentifier
        let bundle = running.bundleIdentifier ?? ""
        let privacy = ClaudePanel.privacy.now
        let quiet = app.assist.neverLook(bundle)
        if quiet && wanted == .passage { return done(nil) }
        Self.read(running, mac: local.mac) { scene, read in
            Self.queue.async {
                var passage: (quote: String, before: String, after: String)?
                if !quiet, wanted == .passage || wanted == nil, let selected = Self.selection(pid: pid) {
                    // Nothing from the vault goes to the AI: a selection holding a secret isn't a place for it.
                    let clean = VaultIndex.settled { index in
                        [selected.quote, selected.before, selected.after].allSatisfy { index.redacted($0) == $0 }
                    } ?? false
                    if clean { passage = selected }
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Made private (or the private apps changed) while it was read: no passage, no words.
                        let still = ClaudePanel.privacy.current(privacy) && !self.app.assist.neverLook(bundle)
                        let offers = self.places(for: scene, read: read, appName: name, passage: still ? passage : nil)
                            .filter { still || $0.kind != .passage }
                        done(wanted.flatMap { kind in offers.first { $0.kind == kind } } ?? (wanted == nil ? offers.first : nil))
                    }
                }
            }
        }
    }
}
