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
    static let notThisNote = "That note's file is another note's now (it was renamed or moved meanwhile): nothing was changed. petal_notes lists them."

    func handle(_ name: String, _ args: [String: Any], live: @escaping @Sendable () -> Bool = { true },
                _ answer: @escaping (Any) -> Void, _ refuse: @escaping (String) -> Void) {
        // Everything told goes through the vault's redaction first (NoteShield, the rule petal_ui and petal_look
        // follow), off the main thread; while the vault can't be read, nothing of the notes is told.
        let send: (Any) -> Void = { value in Self.shielded(value) { out in if let out { answer(out) } else { refuse(NoteShield.unreadable) } } }
        let fail: (String) -> Void = { text in Self.shielded(text) { out in refuse(out as? String ?? NoteShield.unreadable) } }
        guard on else { return fail("Petal Notes is off in Petal's settings (notes).") }
        switch name {
        case "petal_notes":
            let query = args["query"] as? String ?? ""
            let notebook = args["notebook"] as? String ?? ""
            let limit = min(200, max(1, (args["limit"] as? NSNumber)?.intValue ?? 30))
            let onlyHere = args["here"] as? Bool ?? false
            // Searched, filtered by notebook and counted only on what the agent may see of each note (redacted),
            // never its raw text: matching can't be used to guess a secret one character at a time.
            let papers = store.notes.filter { $0.version == nil && (!onlyHere || here[$0.key] != nil) }
            let sources = papers.map { ($0.file.body, $0.notebook) }
            let books = papers.map(\.notebook)
            Self.onShield({ index -> [Int]? in
                // Each note's text and notebook redacted whole first (its title is in its text), then searched.
                let texts = sources.map { NoteTold.searchText($0.0, notebook: $0.1) { index.redacted($0) } }
                guard let hits = NoteShield.search(query, in: texts, index: index, matches: NoteText.matches) else { return nil }
                return notebook.isEmpty ? hits : hits.filter { index.redacted(books[$0]).localizedCaseInsensitiveCompare(notebook) == .orderedSame }
            }) { (hits: [Int]??) in
                // The vault unreadable, or changing all the while: nothing searched, and said why.
                guard let hits = hits ?? nil else { return refuse(NoteShield.unreadable) }
                let found = hits.map { papers[$0] }
                send(["notes": found.prefix(limit).map(self.summary), "count": found.count,
                      "notebooks": self.store.notebooks.map { ["name": $0.name, "color": $0.color.isEmpty ? "accent" : $0.color, "notes": $0.count] },
                      "folder": self.store.root.path])
            }
        case "petal_note_read":
            resolve(args["id"] as? String ?? "", refuse, fail) { paper in
            var result = self.summary(paper)
            result["text"] = paper.file.body
            let path = paper.url.path, vouched = NoteNames.vouched(paper.noteID, paper.url.lastPathComponent)
            result["file"] = NoteShield.Derived { NoteTold.path(path, vouched: vouched, $0) }
            result["created"] = NoteFile.stamp(paper.file.created)
            if paper.file.cover { result["cover"] = true }
            if self.store.readOnly(paper) { result["note"] = "This note changed in two places at once: the person sees both papers until they keep one, and it can't be changed until then." }
            send(result)
            }
        case "petal_note_write":
            let text = args["text"] as? String ?? ""
            if let id = args["id"] as? String, !id.isEmpty {
                let append = args["append"] as? Bool ?? false
                resolve(id, refuse, fail) { paper in
                    self.persist(paper.key, live: live, send, fail, touch: true, edit: { file in
                        file.body = append ? file.body + (file.body.isEmpty || file.body.hasSuffix("\n") ? "" : "\n") + text : text
                    }) { self.written($0) }
                }
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
                        var result = self.written(made)
                        result["notebook"] = made.notebook
                        if sticking { result["stuck"] = place.map { self.told($0) as Any } ?? "nowhere (nothing in front Petal could stick it to)" }
                        send(result)
                    }
                }
                if sticking { stickHere(kind: args["to"] as? String, live: live, make) } else { make(nil) }
            }
        case "petal_note_move":
            let notebook = (args["notebook"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !notebook.isEmpty else { return fail("Which notebook? (a new name makes one)") }
            resolve(args["id"] as? String ?? "", refuse, fail) { paper in
                guard !self.store.readOnly(paper) else { return fail(Self.readOnlyWords) }
                guard live() else { return fail(Self.hungUp) }
                // The same move as the letterhead's: what's typed in it goes with it, and its panel and editor follow.
                self.move(paper.key, to: notebook, live: live) { moved in
                    if let moved {
                        let id = moved.noteID
                        send(["moved": NoteShield.Derived { NoteTold.id(id, $0) }, "notebook": moved.notebook])
                    }
                    else { fail(live() ? "Couldn't move it (or its pictures); it's where it was." : Self.hungUp) }
                }
            }
        case "petal_note_stick":
            resolve(args["id"] as? String ?? "", refuse, fail) { paper in self.stickTool(paper, args, live: live, send, fail) }
        default:
            fail("Unknown tool \(name)")
        }
    }

    /// petal_note_stick, once the note is found.
    private func stickTool(_ paper: PaperNote, _ args: [String: Any], live: @escaping @Sendable () -> Bool,
                           _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
            guard !store.readOnly(paper) else { return fail(Self.readOnlyWords) }
            if let remove = (args["remove"] as? NSNumber)?.intValue {
                guard paper.file.places.indices.contains(remove), paper.file.places.count > 1 else { return fail("A note keeps at least one place; remove is an index from places.") }
                return persist(paper.key, live: live, send, fail, touch: false, edit: { file in
                    if file.places.indices.contains(remove), file.places.count > 1 { file.places.remove(at: remove) }
                }) { ["places": $0.file.places.map(self.told)] }
            }
            let also = args["also"] as? Bool ?? false
            let ticket = Ticket(key: paper.key, noteID: paper.noteID, unique: store.notes.filter { $0.noteID == paper.noteID }.count == 1)
            stickHere(kind: args["to"] as? String, live: live) { place in
                guard let place else { return fail("Petal couldn't tell what's in front (or it changed while Petal looked): nothing was stuck.") }
                // The same note after the wait, by its id (its path may be another note's by now).
                guard let paper = self.repick(ticket) else { return fail(Self.notThisNote) }
                self.persist(paper.key, live: live, send, fail, touch: false, edit: { file in
                    file.places = also ? file.places.filter { !$0.samePlace(place) } + [place] : [place]
                }) { saved in
                    self.refresh()
                    return ["places": saved.file.places.map(self.told)]
                }
            }
    }

    /// The note an agent names, found on what it may see of ids, files and titles (NoteShield.find, redacted with a
    /// settled index); while the vault can't be read, nothing is looked up and it's told why.
    private func resolve(_ name: String, _ refuse: @escaping (String) -> Void, _ fail: @escaping (String) -> Void,
                         _ then: @escaping @MainActor (PaperNote) -> Void) {
        let papers = store.notes
        let rows = papers.map { (id: $0.noteID, key: $0.key, body: $0.file.body, version: $0.version != nil,
                                 vouched: NoteNames.vouched($0.noteID, $0.url.lastPathComponent)) }
        Self.onShield({ NoteShield.find(name, rows: rows, index: $0) }) { (lookup: NoteShield.Lookup?) in
            switch lookup {
            case .found(let at)?:
                // The very paper the lookup chose (a conflict's copy stays that copy), as the notes are now; renamed
                // meanwhile, followed by its id only when that id names one paper; its path now another note's, refused.
                let chosen = Ticket(key: papers[at].key, noteID: papers[at].noteID, unique: papers.filter { $0.noteID == papers[at].noteID }.count == 1)
                guard let paper = self.repick(chosen) else {
                    return fail("That note changed while Petal looked (renamed, or another note has its name now); petal_notes lists them.")
                }
                then(paper)
            case .none?: fail("No note with that id; petal_notes lists them.")
            case .unreadable?, nil: refuse(NoteShield.unreadable)
            }
        }
    }

    /// The paper a request is about, carried by its note's id through every wait (a lookup, a read of what's in
    /// front), never by its path alone: `unique` says whether its id named one paper when the request started.
    struct Ticket {
        let key: String
        let noteID: String
        let unique: Bool
    }

    /// The ticket's paper as the notes are now (NoteShelf.pick): its file while it's still that note; moved, by its
    /// id only when that id named one paper at the start and still does.
    func repick(_ ticket: Ticket) -> PaperNote? {
        let now = store.notes
        return NoteShelf.pick(key: ticket.key, id: ticket.noteID, now: now.map { ($0.key, $0.noteID) }, unique: ticket.unique).map { now[$0] }
    }

    /// `work` with a settled vault index, on the shield's queue; nil when the vault kept changing.
    private static func onShield<T>(_ work: @escaping (UIMap.SecretIndex) -> T, _ done: @escaping @MainActor (T?) -> Void) {
        let carried = Carry(work)
        shieldQueue.async {
            let work = carried.value as! (UIMap.SecretIndex) -> T
            let out = Carry(VaultIndex.settled { work($0) })
            DispatchQueue.main.async { MainActor.assumeIsolated { done(out.value as? T) } }
        }
    }

    private final class Carry: @unchecked Sendable {
        let value: Any?
        init(_ value: Any?) { self.value = value }
    }

    private static let shieldQueue = DispatchQueue(label: "petal.notes.shield", qos: .userInitiated)

    /// `value` with the vault's secrets taken out, on a queue of its own (the index may read the Keychain); nil
    /// when the vault can't be read (or kept changing while it was checked).
    private static func shielded(_ value: Any, _ done: @escaping @MainActor (Any?) -> Void) {
        let carried = Carry(value)
        shieldQueue.async {
            let out = Carry(VaultIndex.settled { NoteShield.shield(carried.value as Any, index: $0) } ?? nil)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(out.value) } }
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
            case .notThisNote: fail(Self.notThisNote)
            // The paper written (by its file; moved meanwhile, by its id when that names one paper).
            case .written: send(result(self.store.paper(key) ?? NoteShelf.pick(key: key, id: paper.noteID, now: self.store.notes.map { ($0.key, $0.noteID) }).map { self.store.notes[$0] } ?? paper))
            case .keptBoth(let copy):
                // The copy's name comes from the note's title (cut to fit), so it isn't told.
                _ = copy
                fail("The note changed elsewhere meanwhile, so this was kept beside it as a conflicted copy; the person picks which to keep.")
            case .failed:
                fail("Petal couldn't write the note's file. It keeps the change and tries again; nothing to do now.")
            }
        }
        if saved == nil { fail(Self.readOnlyWords) }
    }

    /// A place as the AI is told it: in words, or, in an app kept private, only what it is and the app.
    /// Its words are derived only after they're redacted (NoteShield.Derived): a passage's quote is cut to 60
    /// characters, an address to 40.
    private func told(_ stick: NoteStick) -> NoteShield.Derived {
        let place = app.assist.neverLook(stick.app) ? stick.scrubbed : stick
        return NoteShield.Derived { place.redacted($0).words }
    }

    /// A note as the tools list it: its id, title, preview and places derived from its redacted text (NoteTold).
    private func summary(_ paper: PaperNote) -> [String: Any] {
        let body = paper.file.body, id = paper.noteID
        return ["id": NoteShield.Derived { NoteTold.id(id, $0) }, "title": NoteShield.Derived { NoteTold.title(body, $0) },
                "notebook": paper.notebook, "preview": NoteShield.Derived { NoteTold.preview(body, $0) },
                "places": paper.file.places.map(told), "modified": NoteFile.stamp(paper.file.modified),
                "onScreen": here[paper.key] != nil]
    }

    /// What a write answers: the note's id, title and file, derived after redaction.
    private func written(_ paper: PaperNote) -> [String: Any] {
        let body = paper.file.body, id = paper.noteID, path = paper.url.path
        let vouched = NoteNames.vouched(id, paper.url.lastPathComponent)
        return ["written": NoteShield.Derived { NoteTold.id(id, $0) }, "title": NoteShield.Derived { NoteTold.title(body, $0) },
                "file": NoteShield.Derived { NoteTold.path(path, vouched: vouched, $0) }]
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
                case .refused where wanted == .passage, .changed: done(nil)
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
