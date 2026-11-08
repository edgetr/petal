import Foundation

// Checks InstructionsState.swift: the notes for the AI as the settings window edits them. Typing, changes made
// elsewhere, the person's picks and writes answered late or in any order, played through the pure steps; no file is
// read or written. Run with macos/checks/run.sh.
@main
struct InstructionsCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    /// A file and the notes' state, stepped as InstructionsStore does: each write is done against the file at once
    /// (only while it holds what the write builds on), unless `hold` keeps it to be answered later.
    struct Play {
        var state = NotesState()
        var file = ""
        var stamp = 0.0
        var held: [NotesWrite] = []
        var hold = false
        var clock = 100.0

        var disk: NotesDisk { NotesDisk(stamp: Date(timeIntervalSinceReferenceDate: stamp), text: file) }

        mutating func changeElsewhere(_ text: String) { file = text; stamp += 1 }

        mutating func step(_ event: NotesEvent) {
            var next: NotesEvent? = event
            while let event = next {
                next = nil
                guard let asked = NotesSteps.step(&state, event) else { break }
                if hold { held.append(asked) } else { next = answer(asked) }
            }
        }

        /// Does a write as the store does and gives its answer.
        mutating func answer(_ asked: NotesWrite) -> NotesEvent {
            let ok = file == asked.over
            if ok { file = asked.text; stamp += 1 }
            return .wrote(generation: asked.generation, ok: ok, disk)
        }

        mutating func open(saved: String? = nil) { step(.opened(disk, saved: saved, now: clock)) }
        mutating func type(_ text: String, basedOn: Int? = nil) {
            clock += 0.2
            step(.typed(text, basedOn: basedOn ?? state.shown, now: clock))
        }
        mutating func pause() { clock += 5 }
        mutating func look() { step(.read(disk, now: clock)) }
        mutating func keepMine() { step(.keepMine(conflict: state.conflict)) }
        mutating func useTheirs() { step(.useTheirs(disk)) }
    }

    static func main() {
        // Opening reads the file; typing writes it as it's typed.
        var p = Play()
        p.file = "be brief"
        p.open()
        expect(p.state.loaded && p.state.draft == "be brief" && p.state.draftFile == nil, "opening shows the file")
        let shownAtOpen = p.state.shown
        p.type("be brief.")
        expect(p.file == "be brief." && p.state.conflictShown == nil && p.state.shown == shownAtOpen, "typing is written, the editor isn't given its own text back")

        // A change made elsewhere while nothing is unwritten just comes in, once the person pauses.
        p.changeElsewhere("be brief. use metric")
        p.look()
        expect(p.state.draft == "be brief.", "a change elsewhere waits while the person types")
        p.pause()
        p.look()
        expect(p.state.draft == "be brief. use metric" && p.state.shown == shownAtOpen + 1 && p.state.conflictShown == nil,
               "a change elsewhere comes in once they pause")

        // Type → change elsewhere → keep mine → a late failure: the late answer is older than the pick, nothing moves.
        p = Play()
        p.file = "a"
        p.open()
        p.hold = true
        p.type("ab")            // write 1, held
        let w1 = p.held.removeFirst()
        p.changeElsewhere("THEIRS")
        p.hold = false
        p.type("abc")           // write 2 goes over "ab", but the file holds THEIRS
        expect(p.state.theirs == "THEIRS" && p.state.conflictShown != nil && p.file == "THEIRS",
               "a change elsewhere under unwritten typing: nothing written, the person picks")
        expect(p.state.draftFile == "abc", "the conflict's draft is kept beside the notes")
        p.type("abcd")
        expect(p.file == "THEIRS" && p.state.draftFile == "abcd", "typing during a conflict writes only the draft file")
        p.keepMine()
        expect(p.file == "abcd" && p.state.conflictShown == nil && p.state.draftFile == nil, "keep mine writes the draft and settles it")
        let afterPick = p.state
        p.step(.wrote(generation: w1.generation, ok: false, NotesDisk(stamp: nil, text: "THEIRS")))
        expect(p.state == afterPick, "a failure older than the pick changes nothing", "\(p.state)")
        p.type("abcde")
        expect(p.file == "abcde" && p.state.conflictShown == nil, "after keep mine, typing saves again")

        // Several writes queued: a later success settles, an earlier failure coming after it changes nothing.
        p = Play()
        p.open()
        p.hold = true
        p.type("x")
        p.type("xy")
        p.type("xyz")
        expect(p.held.map(\.over) == ["", "x", "xy"], "queued writes each build on the one before", "\(p.held.map(\.over))")
        let writes = p.held
        p.held = []
        p.hold = false
        // The store would have done them in order; answer the last first, then an earlier one late.
        p.file = "xyz"
        p.stamp += 1
        p.step(.wrote(generation: writes[2].generation, ok: true, p.disk))
        expect(p.state.conflictShown == nil && p.state.base == "xyz", "the newest write's success settles")
        p.step(.wrote(generation: writes[0].generation, ok: false, NotesDisk(stamp: nil, text: "elsewhere")))
        expect(p.state.conflictShown == nil && p.state.draft == "xyz", "an older failure after a newer answer changes nothing")
        // Done in order, as the store does them: all written, no conflict.
        p = Play()
        p.open()
        for text in ["q", "qu", "qui", "quie", "quiet"] { p.type(text) }
        expect(p.file == "quiet" && p.state.conflictShown == nil && p.state.asked == p.state.answered, "writes done in order all land")

        // A read while a write is on its way can't tell its change from ours: it waits.
        p = Play()
        p.open()
        p.hold = true
        p.type("m")
        p.pause()
        p.look()
        expect(p.state.draft == "m" && p.state.conflictShown == nil, "a read during a write on its way changes nothing")

        // Type → change elsewhere → use theirs: the file as it is now comes in, the draft file goes.
        p = Play()
        p.file = "one"
        p.open()
        p.type("one two")
        p.changeElsewhere("uno")
        p.type("one two three")
        expect(p.state.conflictShown != nil && p.state.draftFile == "one two three", "conflict before use theirs")
        p.changeElsewhere("uno dos")
        p.look()
        let shownBefore = p.state.shown
        p.useTheirs()
        expect(p.state.draft == "uno dos" && p.state.shown == shownBefore + 1 && p.state.conflictShown == nil && p.state.draftFile == nil,
               "use theirs shows the file as it is now")
        expect(p.file == "uno dos", "use theirs writes nothing")
        let late = p.state
        p.step(.wrote(generation: 1, ok: false, NotesDisk(stamp: nil, text: "zzz")))
        expect(p.state == late, "a write's failure from before use theirs changes nothing")
        p.type("uno dos tres")
        expect(p.file == "uno dos tres", "after use theirs, typing saves again")

        // Keep mine answers only the conflict the person saw; a newer change elsewhere asks again.
        p = Play()
        p.file = "base"
        p.open()
        p.changeElsewhere("theirs 1")
        p.type("base mine")
        let seen = p.state.conflict
        p.changeElsewhere("theirs 2")
        p.look()
        expect(p.state.theirs == "theirs 2" && p.state.conflict != seen, "a newer change elsewhere is a new conflict")
        p.step(.keepMine(conflict: seen))
        expect(p.file == "theirs 2" && p.state.conflictShown != nil, "keep mine on an older conflict writes nothing")
        // Changed again between the pick and its write: not written, and the person picks again.
        p.keepMine()
        expect(p.file == "base mine" && p.state.conflictShown == nil, "keep mine on the conflict shown writes")

        // Typing theirs exactly settles a conflict.
        p = Play()
        p.open()
        p.changeElsewhere("same")
        p.type("sam")
        p.type("same")
        expect(p.state.conflictShown == nil && p.state.draftFile == nil, "typing theirs exactly settles it")

        // Typing over text the editor no longer holds (a change it hadn't shown yet): kept, and the person picks.
        p = Play()
        p.file = "old"
        p.open()
        let editorSaw = p.state.shown
        p.pause()
        p.changeElsewhere("new from agent")
        p.look()
        expect(p.state.draft == "new from agent", "shown while the person paused")
        p.type("old!", basedOn: editorSaw)
        expect(p.file == "new from agent" && p.state.theirs == "new from agent" && p.state.draft == "old!",
               "typing on older text never writes over the change")

        // Quit with an unresolved conflict, then restart: the draft comes back with the line; picking removes it.
        p = Play()
        p.file = "notes"
        p.open()
        p.type("notes, mine")
        p.changeElsewhere("notes, theirs")
        p.type("notes, mine!")
        let kept = p.state.draftFile
        expect(kept == "notes, mine!", "quitting leaves the draft beside the notes")
        var restart = Play()
        restart.file = p.file
        restart.open(saved: kept)
        expect(restart.state.loaded && restart.state.draft == "notes, mine!" && restart.state.theirs == "notes, theirs"
               && restart.state.conflictShown != nil && restart.state.shown > 0,
               "after a restart the draft comes back with the line")
        restart.keepMine()
        expect(restart.file == "notes, mine!" && restart.state.draftFile == nil && restart.state.conflictShown == nil,
               "keep mine after a restart writes it and removes the draft")
        restart = Play()
        restart.file = "notes, theirs"
        restart.open(saved: kept)
        restart.useTheirs()
        expect(restart.state.draft == "notes, theirs" && restart.state.draftFile == nil, "use theirs after a restart removes the draft")
        // A draft that matches the file is nothing to pick.
        restart = Play()
        restart.file = "same"
        restart.open(saved: "same")
        expect(restart.state.conflictShown == nil && restart.state.draftFile == nil, "a draft equal to the file is dropped")
        // Opening again later reads like a look.
        restart.changeElsewhere("later")
        restart.pause()
        restart.step(.opened(restart.disk, saved: "ignored", now: restart.clock))
        expect(restart.state.draft == "later" && restart.state.conflictShown == nil, "a second open is a read")

        // Nothing is typed before the file was read.
        p = Play()
        p.type("early")
        expect(p.state.draft == "" && p.file == "", "no typing before the file was read")

        print("instructions: \(passed) passed")
        if failures > 0 { print("\(failures) failed"); exit(1) }
    }
}
