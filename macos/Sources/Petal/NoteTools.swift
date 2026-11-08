import AppKit

/// Petal Notes for Petal AI and the person's other agents (`petal_notes`, `petal_note_read`, `petal_note_write`,
/// `petal_note_move`, `petal_note_stick`, through Assist's socket). They read and write the person's note files
/// through the same paths the notes themselves use (each note's session, the one move); nothing is ever deleted,
/// and nothing a note says is run. A request whose asker hung up (`live` false) changes nothing more. Places in apps
/// kept private are told only as what they are and the app, never their words, addresses or files.
extension NoteDesk {
    static let tools: Set<String> = ["petal_notes", "petal_note_read", "petal_note_write", "petal_note_move", "petal_note_stick"]

    static let readOnlyWords = "This note has two versions right now (it changed in two places at once): nothing was changed. The person keeps one with Keep this one on the paper; then try again."
    static let notMade = "Petal couldn't make the note's file. It keeps the note and tries again; nothing to do now."
    static let hungUp = "The request ended before this was done: nothing was changed."

    func handle(_ name: String, _ args: [String: Any], live: @escaping @Sendable () -> Bool = { true },
                _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
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
            if store.readOnly(paper) { result["note"] = "This note changed in two places at once: the person sees both papers until they keep one, and it can't be changed until then." }
            send(result)
        case "petal_note_write":
            let text = args["text"] as? String ?? ""
            if let id = args["id"] as? String, !id.isEmpty {
                guard let paper = store.find(id) else { return fail("No note with that id; petal_notes lists them.") }
                let append = args["append"] as? Bool ?? false
                persist(paper.key, live: live, send, fail, touch: true, edit: { file in
                    file.body = append ? file.body + (file.body.isEmpty || file.body.hasSuffix("\n") ? "" : "\n") + text : text
                }) { ["written": $0.noteID, "title": $0.file.title, "file": $0.url.path] }
            } else {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fail("Nothing to write.") }
                var file = NoteFile(body: text)
                let notebook = (args["notebook"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultNotebook
                let sticking = args["stick"] as? String == "here"
                let make = { (place: NoteStick?) in
                    guard live() else { return fail(Self.hungUp) }
                    if let place { file.places = [place] }
                    self.store.make(file, in: notebook, live: live) { made in
                        guard let made else { return fail(Self.notMade) }
                        var result: [String: Any] = ["written": made.noteID, "title": made.file.title, "notebook": made.notebook, "file": made.url.path]
                        if sticking { result["stuck"] = place.map(self.told) ?? "nowhere (nothing in front Petal could stick it to)" }
                        send(result)
                    }
                }
                if sticking { stickHere(kind: args["to"] as? String, live: live, make) } else { make(nil) }
            }
        case "petal_note_move":
            guard let paper = store.find(args["id"] as? String ?? "") else { return fail("No note with that id; petal_notes lists them.") }
            let notebook = (args["notebook"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !notebook.isEmpty else { return fail("Which notebook? (a new name makes one)") }
            guard !store.readOnly(paper) else { return fail(Self.readOnlyWords) }
            guard live() else { return fail(Self.hungUp) }
            // The same move as the letterhead's: what's typed in it goes with it, and its panel and editor follow.
            move(paper.key, to: notebook, live: live) { moved in
                if let moved { send(["moved": moved.noteID, "notebook": moved.notebook]) }
                else { fail(live() ? "Couldn't move it (or its pictures); it's where it was." : Self.hungUp) }
            }
        case "petal_note_stick":
            guard let paper = store.find(args["id"] as? String ?? "") else { return fail("No note with that id; petal_notes lists them.") }
            guard !store.readOnly(paper) else { return fail(Self.readOnlyWords) }
            if let remove = (args["remove"] as? NSNumber)?.intValue {
                guard paper.file.places.indices.contains(remove), paper.file.places.count > 1 else { return fail("A note keeps at least one place; remove is an index from places.") }
                return persist(paper.key, live: live, send, fail, touch: false, edit: { file in
                    if file.places.indices.contains(remove), file.places.count > 1 { file.places.remove(at: remove) }
                }) { ["places": $0.file.places.map(self.told)] }
            }
            let also = args["also"] as? Bool ?? false
            stickHere(kind: args["to"] as? String, live: live) { place in
                guard let place else { return fail("Nothing in front Petal can stick it to.") }
                self.persist(paper.key, live: live, send, fail, touch: false, edit: { file in
                    file.places = also ? file.places.filter { !$0.samePlace(place) } + [place] : [place]
                }) { saved in
                    self.refresh()
                    return ["places": saved.file.places.map(self.told)]
                }
            }
        default:
            fail("Unknown tool \(name)")
        }
    }

    /// Changes a note for the AI through its session (the one way any note changes) and answers with what reached
    /// the disk: written; kept beside the note as a copy (it changed elsewhere meanwhile); or not saved yet (kept
    /// in Petal and tried again). A read-only paper, or a request whose asker hung up, changes nothing.
    private func persist(_ key: String, live: @escaping @Sendable () -> Bool, _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void,
                         touch: Bool, edit: (inout NoteFile) -> Void, _ result: @escaping @MainActor (PaperNote) -> [String: Any]) {
        guard live() else { return fail(Self.hungUp) }
        guard let paper = store.paper(key), !store.readOnly(paper) else { return fail(Self.readOnlyWords) }
        let saved = store.change(key, touch: touch, live: live, edit: edit) { outcome in
            switch outcome {
            case .cancelled: fail(Self.hungUp)
            case .written: send(result(self.store.notes.first { $0.noteID == paper.noteID && $0.version == nil } ?? paper))
            case .keptBoth(let copy):
                fail("The note changed elsewhere meanwhile, so this was kept beside it as “\(copy.lastPathComponent)”; the person picks which to keep.")
            case .failed:
                fail("Petal couldn't write the note's file. It keeps the change and tries again; nothing to do now.")
            }
        }
        if saved == nil { fail(Self.readOnlyWords) }
    }

    /// A place as the AI is told it: in words, or, in an app kept private, only what it is and the app.
    private func told(_ stick: NoteStick) -> String {
        Self.describe(app.assist.neverLook(stick.app) ? stick.scrubbed : stick)
    }

    private func summary(_ paper: PaperNote) -> [String: Any] {
        ["id": paper.noteID, "title": paper.file.title, "notebook": paper.notebook, "preview": String(paper.file.preview.prefix(160)),
         "places": paper.file.places.map(told), "modified": NoteFile.stamp(paper.file.modified),
         "onScreen": here[paper.key] != nil]
    }

    /// What's in front now, read off the main thread, as one place: `kind` (tab, window, app, file, desktop) or the
    /// most specific there is (a passage only with a selection). The read goes through `NoteDesk.read`, whose final
    /// privacy filter leaves an app kept private nothing but itself; its selection is never read for the AI, and a
    /// selection holding something from the vault isn't stuck to (VaultIndex, as petal_ui hides it). Nothing comes
    /// back once the asker hung up.
    private func stickHere(kind: String?, live: @escaping @Sendable () -> Bool, _ done: @escaping @MainActor (NoteStick?) -> Void) {
        let wanted = kind.flatMap(NoteStick.Kind.init(rawValue:))
        if wanted == .desktop {
            var desk = NoteStick(kind: .desktop)
            desk.desktop = app.docks.focusedDock?.desktop
            desk.mode = app.docks.focusedDock?.mode?.id ?? ""
            return done(desk)
        }
        guard let running = NSWorkspace.shared.frontmostApplication, running.processIdentifier != getpid() else { return done(nil) }
        let name = running.localizedName ?? ""
        let bundle = running.bundleIdentifier ?? ""
        let privacy = ClaudePanel.privacy.now
        let quiet = app.assist.neverLook(bundle)
        if quiet && wanted == .passage { return done(nil) }
        Self.read(running, mac: local.mac) { scene, read in
            guard live() else { return }
            let finish = { (passage: (quote: String, before: String, after: String)?) in
                guard live() else { return }
                // The final filter, as the result is used: private now (or the private apps changed), no passage and
                // nothing of its words.
                let still = ClaudePanel.privacy.current(privacy) && !self.app.assist.neverLook(bundle)
                let offers = self.places(for: scene, read: read, appName: name, passage: still ? passage : nil)
                    .map { still ? $0 : $0.privately }
                    .filter { still || $0.kind != .passage }
                done(wanted.flatMap { kind in offers.first { $0.kind == kind } } ?? (wanted == nil ? offers.first : nil))
            }
            guard !quiet, wanted == .passage || wanted == nil else { return finish(nil) }
            // The same selection read as a note's own (petal_look's rule, the scene's window and tab still in front).
            self.passage(in: scene, privacy: privacy) { selected in
                switch selected {
                case .text(let quote, let before, let after): finish((quote, before, after))
                case .refused where wanted == .passage: done(nil)
                default: finish(nil)
                }
            }
        }
    }
}

extension NoteStick {
    /// A place from an app kept private, as Petal may keep it: what identifies it on this Mac, never its words,
    /// address or file.
    var privately: NoteStick {
        var s = scrubbed
        s.mac = mac
        s.pid = pid
        s.window = window
        s.tabID = tabID
        s.tabElement = tabElement
        return s
    }
}
