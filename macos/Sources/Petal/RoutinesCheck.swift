import AppKit

/// `Petal --routines-check [--ai]`: runs routines on throwaway folders in the temporary folder, without the rest of
/// Petal (no dock, no settings, nothing in ~/.config/petal): making one through Petal AI's tool, a dry run, tidying
/// what's there, putting it back, new files settling (a growing file, a Chrome and a Firefox download), a second,
/// pickier routine winning, the file-name patterns and times, and routines saved when the Mac had modes (kept as
/// written, never run). With --ai, sorting asks Claude Haiku (the person's own `claude`, a few quick calls); without,
/// it sorts by kind.
@MainActor
enum RoutinesCheck {
    static func run(ai: Bool) -> Never {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "petal-routines-check-\(getpid())").resolvingSymlinksInPath()
        let state = root.appending(path: "state"), inbox = root.appending(path: "Inbox")
        setenv("PETAL_ROUTINES", state.path, 1)
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "ok    " : "FAIL  ") + what)
            if !ok { failures += 1 }
        }
        @discardableResult
        func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if done() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
            return done()
        }
        func there(_ path: String) -> Bool { fm.fileExists(atPath: inbox.appending(path: path).path) }
        func write(_ name: String, _ bytes: Int) { fm.createFile(atPath: inbox.appending(path: name).path, contents: Data(repeating: 65, count: bytes)) }
        func top() -> [String] { Routines.files(in: inbox).map(\.lastPathComponent).sorted() }
        func tool(_ name: String, _ args: [String: Any], _ routines: Routines) -> [String: Any] {
            var reply: [String: Any]?
            routines.handle(name, args, { reply = ($0 as? [String: Any]) ?? ["result": $0] }, { reply = ["error": $0] })
            wait(ai ? 120 : 15) { reply != nil }
            return reply ?? ["error": "no answer"]
        }

        // Pure parts.
        check(Routines.pattern("Screenshot 2026-11-06 at 10.22.33.png") == "screenshot #-#-# at #.#.#.png", "name pattern: screenshots")
        check(Routines.pattern("invoice_ACME_1234 (1).pdf") == "invoice_acme_#.pdf", "name pattern: copies of an invoice")
        check(Routines.pattern("1234.pdf") == "1234.pdf", "name pattern: too little left keeps the name")
        check(Routines.kind(of: URL(fileURLWithPath: "/x/a.HEIC")) == "Images" && Routines.kind(of: URL(fileURLWithPath: "/x/a.dmg")) == "Installers"
              && Routines.kind(of: URL(fileURLWithPath: "/x/a.zip")) == "Archives", "kinds without AI")
        check(Routines.folderName("../Receipts/2026", among: ["receipts"]) == "Receipts 2026"
              && Routines.folderName("receipts", among: ["Receipts"]) == "Receipts" && Routines.folderName(NSNull(), among: []) == nil, "folder names made safe")
        check(!Routines.allowed(URL(fileURLWithPath: NSHomeDirectory())) && !Routines.allowed(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches"))
              && Routines.allowed(URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")) && !Routines.allowed(URL(fileURLWithPath: "/etc")), "only folders in home")
        var at = Routines.Trigger()
        at.on = "time"; at.at = "18:00"; at.days = [1, 2, 3, 4, 5]
        let monday = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 18, minute: 10))!
        check(Routines.due(at, now: monday, last: nil) && !Routines.due(at, now: monday, last: monday.addingTimeInterval(-60))
              && !Routines.due(at, now: monday.addingTimeInterval(-3600), last: nil) && !Routines.due(at, now: monday.addingTimeInterval(5 * 86400), last: nil),
              "times: due once after its time, on its days")

        // Files there before the routine.
        write("old photo.png", 300)
        write("notes.txt", 120)
        write("Invoice 2291.pdf", 500)
        let routines = Routines()
        routines.standalone = true
        if ai { routines.quickCall = quickClaude }
        var started = false
        routines.start { started = true }
        wait(5) { started }

        let saved = tool("petal_routine_save", ["words": "Keep this inbox tidy", "trigger": ["on": "file", "folder": inbox.path],
                                                "actions": [["do": "sort", "by": ai ? "ai" : "kind"]]], routines)
        let id = (saved["saved"] as? [String: Any])?["id"] as? String ?? ""
        check(!id.isEmpty && saved["filesThereNow"] as? Int == 3, "saved through the tool, sees the 3 files there: \(saved["does"] ?? saved)")
        check(tool("petal_routine_save", ["words": "x", "trigger": ["on": "file", "folder": "/"], "actions": [["do": "sort"]]], routines)["error"] != nil,
              "refuses a folder outside the home folder")

        let dry = tool("petal_routine_run", ["id": id, "dryRun": true], routines)
        check(dry["wouldMove"] as? Int == 3 && top().count == 3, "dry run moves nothing: \(dry["into"] ?? dry)")
        let ran = tool("petal_routine_run", ["id": id], routines)
        check(ran["moved"] as? Int == 3 && top().isEmpty, "tidies what's there: \(ran["into"] ?? ran)")
        if !ai { check(there("Images/old photo.png") && there("PDFs/Invoice 2291.pdf") && there("Documents/notes.txt"), "by kind: Images, PDFs, Documents") }
        var back: [String]?
        routines.undo { back = $0 }
        wait(5) { back != nil }
        check(back?.count == 3 && top().count == 3, "put back: \(top())")
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        check(top().count == 3 && routines.log.count == 1, "what's put back stays put, not sorted again")
        check(!there("Images") && !there("PDFs") && !there("Documents"), "folders it made are gone again once empty")

        // A pickier routine: PDFs with "receipt" in the name go to Receipts.
        let receipts = tool("petal_routine_save", ["words": "File receipts under Receipts", "name": "Receipts",
                                                   "trigger": ["on": "file", "folder": inbox.path, "types": ["pdf"], "named": ["receipt"]],
                                                   "actions": [["do": "move", "to": "Receipts"]]], routines)
        check(receipts["error"] == nil, "a second routine on the same folder: \(receipts["does"] ?? receipts)")
        RunLoop.main.run(until: Date().addingTimeInterval(1))   // its watcher starts

        // New files: one written in three parts, a Chrome download, a Firefox download, a receipt.
        let shot = "Screenshot 2026-11-06 at 10.00.00.png"
        fm.createFile(atPath: inbox.appending(path: shot).path, contents: Data(repeating: 1, count: 100))
        for _ in 0..<2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            if let handle = try? FileHandle(forWritingTo: inbox.appending(path: shot)) { handle.seekToEndOfFile(); handle.write(Data(repeating: 2, count: 100)); try? handle.close() }
        }
        write("movie.mp4.crdownload", 400)
        write("song.mp3", 0)
        write("song.mp3.part", 200)
        write("receipt-4411.pdf", 300)
        let shotLanded = { () -> URL? in
            let found = fm.enumerator(at: inbox, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.first { $0.lastPathComponent == shot }
            return found?.deletingLastPathComponent().lastPathComponent == "Inbox" ? nil : found
        }
        wait(ai ? 90 : 15) { shotLanded() != nil && there("Receipts/receipt-4411.pdf") }
        let landed = shotLanded()
        check(landed != nil && (try? landed!.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 300,
              "a file still being written moves once whole: \(landed.map { $0.deletingLastPathComponent().lastPathComponent } ?? "not moved")")
        check(there("Receipts/receipt-4411.pdf"), "the pickier routine takes the receipt")
        check(there("movie.mp4.crdownload") && there("song.mp3") && there("song.mp3.part"), "downloads under way stay put")
        try? fm.moveItem(at: inbox.appending(path: "movie.mp4.crdownload"), to: inbox.appending(path: "movie.mp4"))
        try? fm.removeItem(at: inbox.appending(path: "song.mp3"))
        try? fm.moveItem(at: inbox.appending(path: "song.mp3.part"), to: inbox.appending(path: "song.mp3"))
        wait(ai ? 90 : 15) { !there("movie.mp4") && !there("song.mp3") }
        check(!there("movie.mp4") && !there("song.mp3"), "finished downloads move: " + (ai ? "\(Routines.survey(inbox).map(\.name))" : "\(there("Videos/movie.mp4") && there("Audio/song.mp3"))"))

        // A file named like one sorted before goes where that one went, without asking again.
        let shot2 = "Screenshot 2026-11-07 at 09.30.12.png"
        write(shot2, 200)
        let folder = landed?.deletingLastPathComponent().lastPathComponent ?? "?"
        wait(15) { there("\(folder)/\(shot2)") }
        check(there("\(folder)/\(shot2)"), "a file named like an earlier one joins it in \(folder)")

        // Putting the latest back: it stays put, not sorted again.
        let latest = routines.log.first { $0.canUndo }
        var returned: [String]?
        routines.undo { returned = $0 }
        wait(5) { returned != nil }
        let name = latest.flatMap { $0.moves.first }.map { URL(fileURLWithPath: $0.from).lastPathComponent } ?? "?"
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        check(returned?.count == 1 && there(name), "put back “\(name)”, and it stays put")
        let listed = tool("petal_routines", [:], routines)
        check((listed["routines"] as? [Any])?.count == 2 && ((listed["history"] as? [Any])?.count ?? 0) >= 4, "lists routines and what they did")
        print(routines.log.map { "  \($0.undone ? "(put back) " : "")\($0.text)" }.joined(separator: "\n"))
        _ = tool("petal_routine_delete", ["id": id], routines)
        check(routines.list.count == 1, "deletes one")

        // With no AI, a routine in the person's own words keeps its rules: what it learned before, and the rest
        // waits where it is (never kind folders it wasn't asked for).
        if !ai {
            let words = root.appending(path: "Words")
            try? fm.createDirectory(at: words, withIntermediateDirectories: true)
            fm.createFile(atPath: words.appending(path: "invoice 77.pdf").path, contents: Data(repeating: 65, count: 100))
            fm.createFile(atPath: words.appending(path: "random.png").path, contents: Data(repeating: 65, count: 100))
            let made = tool("petal_routine_save", ["words": "File invoices under Receipts; leave the rest", "trigger": ["on": "file", "folder": words.path],
                                                  "actions": [["do": "sort", "by": "ai"]]], routines)
            let wid = (made["saved"] as? [String: Any])?["id"] as? String ?? ""
            routines.learn(wid, [Routines.pattern("invoice 77.pdf"): "Receipts"])
            let sorted = tool("petal_routine_run", ["id": wid], routines)
            let inWords = { (path: String) in fm.fileExists(atPath: words.appending(path: path).path) }
            check(inWords("Receipts/invoice 77.pdf") && inWords("random.png") && !inWords("Images") && sorted["waitingForAI"] as? Int == 1,
                  "no AI: learned answers first, the rest waits for the AI: \(sorted)")

            // A changed rule forgets what it learned: the invoice isn't sent to Receipts again without asking.
            fm.createFile(atPath: words.appending(path: "invoice 78.pdf").path, contents: Data(repeating: 65, count: 100))
            _ = tool("petal_routine_save", ["id": wid, "words": "File invoices under Taxes; leave the rest"], routines)
            let after = tool("petal_routine_run", ["id": wid], routines)
            check(inWords("invoice 78.pdf") && after["waitingForAI"] as? Int == 2, "a changed rule asks again: \(after)")

            // Each file action is planned when the run gets to it: a file that arrives after the dry run (an
            // export) is sorted too.
            let later = root.appending(path: "Later")
            try? fm.createDirectory(at: later, withIntermediateDirectories: true)
            fm.createFile(atPath: later.appending(path: "a.png").path, contents: Data(repeating: 65, count: 100))
            let byKind = tool("petal_routine_save", ["words": "Sort by kind", "trigger": ["on": "time", "at": "03:00"],
                                                    "actions": [["do": "sort", "by": "kind", "folder": later.path]]], routines)
            let kid = (byKind["saved"] as? [String: Any])?["id"] as? String ?? ""
            let shown = tool("petal_routine_run", ["id": kid, "dryRun": true], routines)
            fm.createFile(atPath: later.appending(path: "b.pdf").path, contents: Data(repeating: 65, count: 100))
            let done = tool("petal_routine_run", ["id": kid], routines)
            let inLater = { (path: String) in fm.fileExists(atPath: later.appending(path: path).path) }
            check(shown["wouldMove"] as? Int == 1 && done["moved"] as? Int == 2 && inLater("Images/a.png") && inLater("PDFs/b.pdf"),
                  "planned when it runs, not from the dry run: \(done)")
            _ = tool("petal_routine_delete", ["id": kid], routines)
            _ = tool("petal_routine_delete", ["id": wid], routines)
        }
        Routines.flush()
        check(fm.fileExists(atPath: Routines.file.path) && Routines.file.path.hasPrefix(state.path), "kept in the test's own folder")
        routines.stop()

        // Routines saved when the Mac had modes (started by one, or switching to one): listed, never run, and
        // written back as they were.
        let old = root.appending(path: "Old")
        try? fm.createDirectory(at: old, withIntermediateDirectories: true)
        let entered: [String: Any] = ["id": "m1", "name": "Tidy in Social", "words": "when I go to Social, tidy this", "on": true, "lastResult": "",
                                      "trigger": ["on": "mode", "mode": "social"], "actions": [["do": "sort", "by": "kind", "folder": old.path, "into": ""]]]
        let switches: [String: Any] = ["id": "m2", "name": "Design files", "words": "sort these and switch to Design", "on": true, "lastResult": "",
                                       "trigger": ["on": "file", "folder": old.path, "types": [String](), "named": [String]()],
                                       "actions": [["do": "mode", "mode": "design"], ["do": "sort", "by": "kind", "folder": "", "into": ""]]]
        Config.writeObject(["routines": [entered, switches]], to: Routines.file)
        let kept = Routines()
        kept.standalone = true
        var keptStarted = false
        kept.start { keptStarted = true }
        wait(5) { keptStarted }
        check(kept.list.map(\.id) == ["m1", "m2"] && kept.list.allSatisfy(\.usesModes), "routines that used modes are still listed")
        let told = (tool("petal_routines", [:], kept)["routines"] as? [[String: Any]]) ?? []
        check(told.count == 2 && told.allSatisfy { ($0["skipped"] as? String)?.contains("modes") == true }, "each says it's skipped, and why")
        fm.createFile(atPath: old.appending(path: "left alone.png").path, contents: Data(repeating: 65, count: 100))
        check(tool("petal_routine_run", ["id": "m1"], kept)["error"] != nil && tool("petal_routine_run", ["id": "m2", "dryRun": true], kept)["error"] != nil,
              "running one by hand is refused")
        RunLoop.main.run(until: Date().addingTimeInterval(6))   // long past a new file settling
        check(fm.fileExists(atPath: old.appending(path: "left alone.png").path) && kept.log.count == routines.log.count, "a file landing starts neither: nothing moved")
        check(tool("petal_routine_save", ["words": "x", "trigger": ["on": "mode", "mode": "social"], "actions": [["do": "hide", "apps": ["Mail"]]]], kept)["error"] != nil
              && tool("petal_routine_save", ["words": "x", "trigger": ["on": "time", "at": "09:00"], "actions": [["do": "mode", "mode": "design"]]], kept)["error"] != nil,
              "a new routine can't start with a mode or switch to one")
        // Another routine saved beside them writes the file again: theirs come back as they were written.
        _ = tool("petal_routine_save", ["words": "Hide Mail at nine", "trigger": ["on": "time", "at": "09:00"], "actions": [["do": "hide", "apps": ["Mail"]]]], kept)
        Routines.flush()
        let written = (Config.parse(Routines.file)?["routines"] as? [[String: Any]]) ?? []
        check(written.count == 3 && (written.first { $0["id"] as? String == "m1" }?["trigger"] as? NSDictionary) == (entered["trigger"] as? NSDictionary)
              && ((written.first { $0["id"] as? String == "m2" }?["actions"] as? [NSDictionary])?.first) == (["do": "mode", "mode": "design"] as NSDictionary),
              "and they're written back as they were")
        kept.stop()
        print(failures == 0 ? "routines: all good" : "routines: \(failures) failed")
        try? fm.removeItem(at: root)
        exit(failures == 0 ? 0 : 1)
    }

    /// Claude Haiku through the person's own `claude`, as Brain asks it.
    static func quickClaude(_ prompt: String, _ key: String, _ done: @escaping ([String: Any]?) -> Void) {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" } + [NSHomeDirectory() + "/.local/bin/claude"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return done(nil) }
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = Provider.claude.quickArguments
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            var answer: [String: Any]?
            if (try? process.run()) != nil {
                try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                try? input.fileHandleForWriting.close()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
                    answer = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
                }
            }
            print("  AI: \(answer.map { "\($0)" } ?? "no answer")")
            DispatchQueue.main.async { done(answer) }
        }
    }
}
