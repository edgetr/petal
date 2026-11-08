import Foundation

/// The notes for the AI as the settings window edits them (`InstructionsText`), as one state and the steps that change
/// it. Pure, so `macos/checks/run.sh` checks it. Every step runs on one serial queue, in order: reading the file,
/// typing, writing, the person's pick and the watcher's look. A write's answer carries the generation it was asked at,
/// so one older than the person's latest pick, or than an answer already taken, changes nothing.
///
/// What the editor holds (`draft`) is written as it's typed, but only over what the file held as last seen (`base`):
/// a change made elsewhere is never written over. When the file changed elsewhere while the draft wasn't written, both
/// are kept (`theirs`) until the person picks (Use theirs, Keep mine), and the draft is kept in a file beside the notes
/// (`draftFile`), so quitting loses neither.
struct NotesDisk: Equatable, Sendable {
    /// When the file was last changed.
    var stamp: Date?
    var text: String
}

struct NotesState: Equatable, Sendable {
    /// Whether the file was read once: until then the editor takes no typing.
    var loaded = false
    /// What the editor holds.
    var draft = ""
    /// What the file holds once the writes asked for are done: a write goes only over this.
    var base = ""
    /// The file's modification date as last seen: the watcher reads the file again only once it changes.
    var stamp: Date?
    /// The file's text, changed elsewhere while the draft wasn't written: nothing is written until the person picks.
    var theirs: String?
    /// Counts the person's steps (typing, picks): every write is asked at one.
    var generation = 0
    /// The generation of the person's latest pick: a write asked before it is answered for nothing.
    var picked = 0
    /// The newest write asked for, and the newest whose answer was taken: an older answer coming later is dropped,
    /// and a read while a write is on its way can't tell its change from ours, so it waits.
    var asked = 0
    var answered = 0
    /// Counts changes to `draft` the editor didn't make (the file read, a pick, a draft kept from before): the editor
    /// shows the draft again when it changes, and typing on an older count built on text it no longer holds.
    var shown = 0
    /// Counts conflicts (each new `theirs`): Keep mine answers only the one the person saw.
    var conflict = 0
    /// When the person last typed (seconds): a change from elsewhere waits until they pause.
    var typedAt = -Double.infinity

    /// What the file beside the notes holds: the draft while a conflict is unresolved, else nothing (no file).
    var draftFile: String? { theirs == nil ? nil : draft }
    /// The conflict the line under the editor shows, if any.
    var conflictShown: Int? { theirs == nil ? nil : conflict }
}

enum NotesEvent: Equatable, Sendable {
    /// The file and the draft kept beside it (from a conflict left unresolved), as first read.
    case opened(NotesDisk, saved: String?, now: Double)
    /// The file read again (the editor appearing, the watcher seeing it change).
    case read(NotesDisk, now: Double)
    /// The editor's text, typed over what it was last shown (`basedOn`: the `shown` it had).
    case typed(String, basedOn: Int, now: Double)
    /// A write's answer: whether it was written, and the file after.
    case wrote(generation: Int, ok: Bool, NotesDisk)
    /// "Keep mine", on the conflict the person saw.
    case keepMine(conflict: Int)
    /// "Use theirs", with the file as it is now.
    case useTheirs(NotesDisk)
}

/// A write asked for: `text` goes into the file only while it holds `over`.
struct NotesWrite: Equatable, Sendable {
    var text: String
    var over: String
    var generation: Int
}

enum NotesSteps {
    /// How long after a key the person counts as typing.
    static let typing: Double = 1.5

    /// One step: the state after `event`, and the write it asks for, if any (its answer is the next event).
    static func step(_ s: inout NotesState, _ event: NotesEvent) -> NotesWrite? {
        switch event {
        case let .opened(disk, saved, now):
            guard !s.loaded else { return step(&s, .read(disk, now: now)) }
            show(&s, disk)
            // A conflict left unresolved last time: the draft comes back, and the line with it.
            if let saved, saved != disk.text {
                s.draft = saved
                s.shown += 1
                setTheirs(&s, disk.text)
            }
            return nil

        case let .read(disk, now):
            guard s.loaded, s.answered >= s.asked else { return nil }
            if s.theirs != nil { settle(&s, disk); return nil }
            if disk.text == s.draft { s.base = disk.text; s.stamp = disk.stamp; return nil }
            // Changed elsewhere while the person types: read again once they pause (the stamp isn't taken). A key
            // meanwhile finds the file isn't what it builds on, and the person picks.
            guard now - s.typedAt >= typing else { return nil }
            show(&s, disk)
            return nil

        case let .typed(text, basedOn, now):
            guard s.loaded, text != s.draft else { return nil }
            s.generation += 1
            s.typedAt = now
            s.draft = text
            if let theirs = s.theirs {
                // Typing theirs exactly settles it.
                if text == theirs { s.theirs = nil; s.base = text }
                return nil
            }
            if basedOn != s.shown {
                // Typed over older text than the editor was last given (a change from elsewhere it hadn't shown
                // yet): the file isn't what this builds on, so nothing is written and the person picks.
                if text != s.base { setTheirs(&s, s.base) }
                return nil
            }
            let over = s.base
            s.base = text   // the next write builds on this one
            s.asked = s.generation
            return NotesWrite(text: text, over: over, generation: s.generation)

        case let .wrote(generation, ok, disk):
            // Older than the person's latest pick, or than an answer already taken: nothing changes.
            guard generation >= s.picked, generation > s.answered else {
                s.answered = max(s.answered, generation)
                return nil
            }
            s.answered = generation
            // The file holds just what's typed: nothing to pick, and the next write builds on it.
            if disk.text == s.draft {
                s.theirs = nil
                s.base = disk.text
                s.stamp = disk.stamp
                return nil
            }
            // Written, and newer typing's write follows.
            if ok { if s.theirs == nil { s.stamp = disk.stamp }; return nil }
            // Not written: the file changed elsewhere. What's typed since built on this, so it's unwritten too.
            settle(&s, disk)
            return nil

        case let .keepMine(conflict):
            guard let theirs = s.theirs, conflict == s.conflict else { return nil }
            s.generation += 1
            s.picked = s.generation
            s.asked = s.generation
            s.theirs = nil
            s.base = s.draft
            return NotesWrite(text: s.draft, over: theirs, generation: s.generation)

        case let .useTheirs(disk):
            guard s.theirs != nil else { return nil }
            s.generation += 1
            s.picked = s.generation
            s.theirs = nil
            show(&s, disk)
            return nil
        }
    }

    /// The file as read: the editor shows it and builds on it.
    private static func show(_ s: inout NotesState, _ disk: NotesDisk) {
        s.loaded = true
        s.base = disk.text
        s.stamp = disk.stamp
        if s.draft != disk.text { s.draft = disk.text; s.shown += 1 }
    }

    /// The file as read while the draft isn't written: the person picks, unless it now holds just the draft.
    private static func settle(_ s: inout NotesState, _ disk: NotesDisk) {
        s.base = disk.text
        s.stamp = disk.stamp
        if disk.text == s.draft { s.theirs = nil } else { setTheirs(&s, disk.text) }
    }

    private static func setTheirs(_ s: inout NotesState, _ text: String) {
        guard s.theirs != text else { return }
        s.theirs = text
        s.conflict += 1
    }
}
