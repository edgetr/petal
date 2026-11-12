import AppKit
import SwiftUI

/// `Petal --bench-notes [--json file]`: Petal Notes with many notes, timed headless. It makes 500 made-up notes in 20
/// notebooks in a throwaway folder of its own (plain ones, some with pictures, on files, on passages, on tabs and
/// windows, a few with a watcher or a task; one notebook's 100 notes laid out on a canvas; one note with 20
/// pictures), points Petal's settings, state and notes at folders beside it (never the person's, whatever the
/// environment says), uses a made-up vault, opens no socket, reads no Keychain and shows nothing: the real store,
/// desk, Petal Notes window, note tools and editor, laid out and drawn off screen as `--bench-windows` does.
///
/// What it times: the first read of the folder until notes are ready; a read after one file changed; the Petal Notes
/// window opening on the biggest notebook, switching notebooks and switching to the canvas; a search typed a
/// character at a time (the person's own, and the tools' redacted one); the grid scrolled top to bottom; the tabs
/// on the edge of a window with 30 notes; a note with 20 pictures opening; and the CPU Petal uses with the window
/// open and closed while nobody touches it. Beside each time, the longest the main thread was held during it.
@MainActor
enum NotesBench {
    struct Row: Codable {
        var name: String
        var ms: Double
        /// The longest the main thread was busy in one piece during it (a wait on the disk would show here).
        var mainHeld: Double
        var note: String
    }

    struct Steps: Codable {
        var steps: Int
        var median: Double, p95: Double, max: Double
        var over8: Int, over16: Int
    }

    struct Report: Codable {
        var notes: Int, notebooks: Int, pictures: Int
        var rows: [Row] = []
        var typing: Steps?
        var scrolling: WindowBench.ScrollStat?
        var idleOpen: Double = 0      // percent of one core, the window laid out and drawn 60 times a second (as --bench-windows measures it)
        var idleOpenQuiet: Double = 0 // the same with nothing asking it to draw
        var idleClosed: Double = 0
        var memory: Double = 0        // MB, at the end
    }

    static func run(_ arguments: [String]) -> Never {
        Headless.on = true
        let made = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "petal-bench-notes-\(getpid())")
        try? FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        let real = made.path.withCString { realpath($0, nil) }.map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? made.path
        let root = URL(fileURLWithPath: real)
        let config = root.appending(path: "config"), support = root.appending(path: "support"), notes = root.appending(path: "notes")
        for folder in [config, support, notes] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        // Its own folders, whatever the run was given, before anything reads a setting or a file of Petal's.
        setenv("PETAL_CONFIG_DIR", config.path, 1)
        setenv("PETAL_SUPPORT_DIR", support.path, 1)
        setenv("PETAL_NOTES", notes.path, 1)
        guard Config.folder.path == config.path, Config.supportFolder.path == support.path else {
            print("bench-notes: Petal's folders were read before the bench could point them at its own; nothing was run")
            exit(1)
        }
        try? JSONSerialization.data(withJSONObject: ["aiProviders": [String](), "notes": true] as [String: Any]).write(to: config.appending(path: "settings.json"))
        VaultStore.standIn([])
        let bench = Bench(root: root, notes: notes)
        let report = bench.run()
        bench.print(report)
        if let index = arguments.firstIndex(of: "--json"), arguments.indices.contains(index + 1) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: URL(fileURLWithPath: arguments[index + 1]))
        }
        try? FileManager.default.removeItem(at: root)
        exit(0)
    }

    /// The longest the main thread goes without taking the next thing queued on it: asked every 2 ms from another
    /// thread, the wait for each answer is how long the main thread was busy in one piece.
    final class MainHeld: @unchecked Sendable {
        private let lock = NSLock()
        private var worst: Double = 0
        private var waiting = false
        /// Moves on with every `take`: an answer asked for before it belongs to what came before, and isn't counted.
        private var span = 0
        private let timer: DispatchSourceTimer

        init() {
            timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "petal.bench.held", qos: .userInteractive))
            timer.schedule(deadline: .now(), repeating: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let busy = self.waiting
                if !busy { self.waiting = true }
                let span = self.span
                self.lock.unlock()
                guard !busy else { return }
                let asked = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async {
                    let took = Double(DispatchTime.now().uptimeNanoseconds - asked) / 1_000_000
                    self.lock.lock()
                    if span == self.span { self.worst = max(self.worst, took) }
                    self.waiting = false
                    self.lock.unlock()
                }
            }
            timer.resume()
        }

        /// Stopped for good (it wakes the main thread 500 times a second: never while idle CPU is measured).
        func stop() { timer.cancel() }

        /// The longest since the last call.
        func take() -> Double {
            lock.lock()
            defer { lock.unlock() }
            let value = worst
            worst = 0
            span += 1
            return value
        }
    }

    @MainActor
    final class Bench {
        let root: URL, notes: URL
        let fm = FileManager.default
        let held = MainHeld()
        var app: PetalApp!
        var report: Report
        /// What was made: every notebook's notes (ids), the biggest notebook, the canvas one, the note with pictures.
        var books: [(name: String, ids: [String])] = []
        let big = "Projects", board = "Board"
        var pictureNote = ""
        var pictureFiles: [URL] = []
        static let total = 500, pictureCount = 20
        /// `PETAL_BENCH_VERBOSE=1`: each keystroke's own time.
        static let verbose = ProcessInfo.processInfo.environment["PETAL_BENCH_VERBOSE"] == "1"

        init(root: URL, notes: URL) {
            self.root = root
            self.notes = notes
            report = Report(notes: Self.total, notebooks: 20, pictures: Self.pictureCount)
        }

        func wait(_ done: () -> Bool) {
            let end = Date().addingTimeInterval(120)
            while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        }

        func row(_ name: String, _ ms: Double, _ note: String = "") {
            let mainHeld = held.take()
            report.rows.append(Row(name: name, ms: ms, mainHeld: mainHeld, note: note))
        }

        // MARK: Made-up notes

        private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        private func next(_ below: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(below))
        }
        private let words = ["plan", "list", "draft", "review", "garden", "budget", "meeting", "paint", "order", "ticket", "reading", "kitchen", "window",
                             "report", "letter", "weekend", "invoice", "sketch", "recipe", "station", "library", "tomorrow", "question", "answer", "shelf",
                             "bridge", "morning", "printer", "camera", "holiday", "notebook", "margin", "garage", "ladder", "pillow", "harbour", "candle"]
        private func sentence(_ count: Int) -> String {
            var parts = (0..<count).map { _ in words[next(words.count)] }
            parts[0] = parts[0].capitalized
            return parts.joined(separator: " ") + "."
        }

        /// A PNG of `width` by `height` (bands of color, so it isn't tiny on disk).
        private func png(_ width: Int, _ height: Int, hue: CGFloat) -> Data {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return Data() }
            let bands = 40
            for band in 0..<bands {
                let color = NSColor(hue: (hue + CGFloat(band) / CGFloat(bands) * 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.5,
                                    brightness: 0.6 + 0.4 * CGFloat(band % 5) / 5, alpha: 1)
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: 0, y: band * height / bands, width: width, height: height / bands + 1))
                context.setFillColor(NSColor(white: 1, alpha: 0.25).cgColor)
                context.fillEllipse(in: CGRect(x: (band * 97) % max(1, width - 80), y: band * height / bands, width: 80, height: 40))
            }
            return rep.representation(using: .png, properties: [:]) ?? Data()
        }

        func generate() {
            let start = WindowBench.now()
            let names = ["Inbox", big, board, "Work", "Home", "Garden", "Reading", "Recipes", "Travel", "Ideas", "Journal", "Music", "Films", "Health",
                         "Budget", "House", "School", "Clients", "Research", "Letters"]
            let colors = ["accent", "#007aff", "#a550a7", "#f74f9e", "#f7821b", "#ffc600", "#62ba46", "#8c8c8c"]
            // 100 in the biggest notebook, 100 on the canvas, the rest shared among the other eighteen.
            var counts = [String: Int]()
            let others = names.filter { $0 != big && $0 != board }
            for (index, name) in others.enumerated() { counts[name] = (Self.total - 200) / others.count + (index < (Self.total - 200) % others.count ? 1 : 0) }
            counts[big] = 100
            counts[board] = 100
            let now = Date()
            let small = png(96, 64, hue: 0.55)
            let large = png(1600, 1000, hue: 0.08)
            var number = 0
            for (bookIndex, name) in names.enumerated() {
                let folder = notes.appending(path: name)
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                var cover = NoteFile(id: "COVER-\(bookIndex)", created: now.addingTimeInterval(-90 * 86400),
                                     body: "# About this notebook\n\(sentence(9))\n## Petal remembers\n- \(sentence(5))\n- \(sentence(6))")
                cover.cover = true
                cover.color = colors[bookIndex % colors.count]
                if name == board { cover.setScalar("view", "canvas") }
                try? Data(cover.serialized().utf8).write(to: folder.appending(path: NoteShelf.coverName))
                var ids: [String] = []
                var canvas = NoteCanvas()
                for index in 0..<(counts[name] ?? 0) {
                    number += 1
                    let id = "BENCH-\(number)"
                    ids.append(id)
                    let age = Double(next(60 * 24)) * 3600
                    var body = index % 3 == 0 ? "# \(sentence(3))\n" : ""
                    body += (0..<(2 + next(6))).map { _ in sentence(6 + next(8)) }.joined(separator: "\n")
                    if index % 7 == 0 { body += "\n- [ ] \(sentence(3))\n- [x] \(sentence(4))" }
                    var file = NoteFile(id: id, created: now.addingTimeInterval(-age - 86400), modified: now.addingTimeInterval(-age), body: "")
                    var stick: NoteStick?
                    switch index % 10 {
                    case 4:
                        // One small picture, in the note's own folder in Pictures.
                        let pictures = notes.appending(path: NoteShelf.pictureFolder(id: id))
                        try? fm.createDirectory(at: pictures, withIntermediateDirectories: true)
                        try? small.write(to: pictures.appending(path: "picture-1.png"))
                        body += "\n![a picture](\(NoteShelf.pictureLink(id: id, name: "picture-1.png")))"
                    case 5:
                        var place = NoteStick(kind: .file)
                        place.path = "/Users/someone/Documents/\(words[next(words.count)])-\(number).pdf"
                        place.title = (place.path as NSString).lastPathComponent
                        stick = place
                    case 6:
                        var place = NoteStick(kind: .passage)
                        place.url = "https://pages.example/\(words[next(words.count)])/\(number)"
                        place.quote = sentence(5)
                        place.before = sentence(4)
                        place.after = sentence(4)
                        stick = place
                    case 7:
                        var place = NoteStick(kind: .tab)
                        place.url = "https://site\(number % 40).example/\(words[next(words.count)])"
                        place.title = sentence(3)
                        stick = place
                    case 8:
                        var place = NoteStick(kind: .window)
                        place.appName = ["Mail", "Xcode", "Figma", "Numbers"][number % 4]
                        place.title = sentence(3)
                        stick = place
                    default: break
                    }
                    if let stick { file.places = [stick] }
                    if number % 25 == 0 {
                        file.extra.append((key: "watch", lines: ["watch: { every: 1d, line: \"under 300\", last: \"\(300 + next(90))\", history: [\"\(320 + next(60))\"] }"]))
                    } else if number % 35 == 0 {
                        file.extra.append((key: "task", lines: [#"task: [ { kind: tab, title: Page, url_or_path: "https://pages.example/task" }, { kind: file, title: List, url_or_path: "/Users/someone/List.pdf" } ]"#]))
                    }
                    if name == big && index == 0 {
                        // The one with 20 pictures (each 1600 by 1000), a line of words between them.
                        pictureNote = id
                        let pictures = notes.appending(path: NoteShelf.pictureFolder(id: id))
                        try? fm.createDirectory(at: pictures, withIntermediateDirectories: true)
                        body = "# Twenty pictures\n" + sentence(8)
                        for picture in 1...Self.pictureCount {
                            let file = pictures.appending(path: "picture-\(picture).png")
                            try? large.write(to: file)
                            pictureFiles.append(file)
                            body += "\n![picture \(picture)](\(NoteShelf.pictureLink(id: id, name: "picture-\(picture).png")))\n" + sentence(7)
                        }
                    }
                    file.body = body
                    try? Data(file.serialized().utf8).write(to: folder.appending(path: "Note \(number).md"))
                    if name == board { canvas.notes[id] = .init(x: Double(60 + (index % 10) * 190), y: Double(60 + (index / 10) * 200)) }
                }
                if name == board {
                    canvas.areas = [.init(id: "a1", label: "First", x: 30, y: 30, w: 960, h: 620), .init(id: "a2", label: "Later", x: 30, y: 1040, w: 1900, h: 1000)]
                    canvas.arrows = (0..<12).map { .init(id: "r\($0)", from: ids[$0 * 3], to: ids[$0 * 3 + 11]) }
                    try? Data(canvas.encoded().utf8).write(to: folder.appending(path: NoteStore.canvasName))
                }
                books.append((name, ids))
            }
            Swift.print("made \(number) notes in \(names.count) notebooks (\(Self.pictureCount) pictures of \(large.count / 1024) KB in one note) in \(Int(WindowBench.ms(start, WindowBench.now()))) ms")
        }

        // MARK: The steps

        func run() -> Report {
            generate()
            app = PetalApp()
            // Once to warm what a first call pays for (the vault's index, SwiftUI): not counted.
            _ = held.take()

            // 1. The first read of the folder, until notes are ready (NoteStore.switchRoot's last step).
            var ready: UInt64?
            let started = WindowBench.now()
            app.paper.startHeadless(root: notes) { ready = WindowBench.now() }
            wait { ready != nil }
            let store = app.paper.store
            row("first read until ready", WindowBench.ms(started, ready ?? started), "\(store.notes.count) papers in \(store.notebooks.count) notebooks")
            wait { !store.working }

            // What of that is reading the files (off the main thread), measured alone.
            var alone: Double?
            let notesRoot = notes
            NoteStore.io.async {
                let from = DispatchTime.now().uptimeNanoseconds
                _ = NoteStore.read(notesRoot)
                let took = Double(DispatchTime.now().uptimeNanoseconds - from) / 1_000_000
                DispatchQueue.main.async { alone = took }
            }
            wait { alone != nil }
            row("  of which the files' read alone", alone ?? 0, "off the main thread")

            // 2. A read after one file changed.
            let changed = notes.appending(path: "Work").appending(path: (try? fm.contentsOfDirectory(atPath: notes.appending(path: "Work").path))?
                .filter { $0.hasPrefix("Note ") }.sorted().first ?? "")
            if let text = try? String(contentsOf: changed, encoding: .utf8) { try? Data((text + "\nOne more line.").utf8).write(to: changed) }
            var again: UInt64?
            let reread = WindowBench.now()
            store.reload { again = WindowBench.now() }
            wait { again != nil }
            row("a read after one file changed", WindowBench.ms(reread, again ?? reread))
            wait { !store.working }

            // 3. The Petal Notes window: opening on the biggest notebook, switching notebooks, switching to the canvas.
            let window = { self.app.notesWindow.window }
            let model = app.notesWindow.model
            _ = held.take()
            let opened = WindowBench.measure(window, think: 0.3) { self.app.notesWindow.show(.notebook(self.big)) }
            row("the Petal Notes window opens on 100 notes", opened.ms, "update \(f(opened.update)), draw \(f(opened.draw)) ms")
            var switches: [Double] = []
            for name in ["Work", "Garden", big, "Reading", "Inbox", big] {
                switches.append(WindowBench.measure(window, think: 0.1) { model.shelf = .notebook(name) }.ms)
            }
            row("switching notebooks", median(switches), "median of \(switches.count); the slowest \(f(switches.max() ?? 0)) ms")
            let toCanvas = WindowBench.now()
            let first = WindowBench.measure(window, think: 0) { model.shelf = .notebook(self.board) }
            wait { model.canvas?.notebook == self.board && model.canvas?.layout != nil }
            if let shown = window() { WindowBench.frame(shown) }
            row("switching to the canvas of 100 notes", WindowBench.ms(toCanvas, WindowBench.now()), "its first frame \(f(first.ms)) ms, then the canvas read and laid out")
            if let shown = window() { WindowBench.settle(shown, seconds: 0.3) }

            // 4. A search typed a character at a time (the person's own), over every note.
            _ = WindowBench.measure(window, think: 0.1) { model.shelf = .notebook(self.big) }
            var keys: [Double] = []
            _ = held.take()
            for query in ["garden plan", "meeting", "invoice review tomorrow"] {
                for length in 1...query.count {
                    let sample = WindowBench.measure(window, think: 0.03) { model.query = String(query.prefix(length)) }
                    keys.append(sample.ms)
                    if Self.verbose { Swift.print("  “\(query.prefix(length))”: \(f(sample.ms)) ms (update \(f(sample.update)), draw \(f(sample.draw)))") }
                }
                let cleared = WindowBench.measure(window, think: 0.03) { model.query = "" }
                keys.append(cleared.ms)
                if Self.verbose { Swift.print("  cleared: \(f(cleared.ms)) ms (update \(f(cleared.update)), draw \(f(cleared.draw)))") }
            }
            report.typing = steps(keys)
            row("search, a keystroke (the person's own)", median(keys), "median of \(keys.count); p95 \(f(WindowBench.pick(keys.sorted(), 0.95))), the slowest \(f(keys.max() ?? 0)) ms")

            // The tools' search: over redacted text only (NoteShield), off the main thread.
            var tools: [Double] = []
            _ = held.take()
            for query in ["garden plan", "meeting", "invoice", "kitchen window", "tomorrow"] {
                var answered: UInt64?
                let asked = WindowBench.now()
                app.paper.handle("petal_notes", ["query": query], { _ in answered = WindowBench.now() }, { _ in answered = WindowBench.now() })
                wait { answered != nil }
                tools.append(WindowBench.ms(asked, answered ?? asked))
            }
            row("search, the tools' (redacted)", median(tools), "median of \(tools.count); the first \(f(tools.first ?? 0)) ms")

            // 5. The grid scrolled top to bottom and back, 8 points a step.
            if let shown = window() {
                _ = held.take()
                report.scrolling = WindowBench.scroll(shown)
                if let scroll = report.scrolling {
                    row("the grid scrolled, a step", scroll.median, "\(scroll.steps) steps; p95 \(f(scroll.p95)), over 8.3 ms: \(scroll.over8), over 16.7 ms: \(scroll.over16)")
                }
            }

            // 6. The tabs on the edge of a window with 30 notes on it.
            let onWindow = Array(books.first { $0.name == "Work" }!.ids.prefix(15) + books.first { $0.name == "Home" }!.ids.prefix(15))
            let keysOnWindow = onWindow.compactMap { id in store.notes.first { $0.noteID == id }?.key }
            let scene = NoteScene(mac: app.paper.local.mac, app: "com.example.editor", pid: 1, window: 7, title: "A made-up window")
            // Every tab drawn, with one commit for them all (as one turn of the display does).
            let draw = {
                for tab in self.app.paper.benchTabs {
                    tab.contentView?.layoutSubtreeIfNeeded()
                    tab.displayIfNeeded()
                }
                CATransaction.flush()
            }
            _ = held.take()
            let laid = WindowBench.now()
            app.paper.previewWindow(scene, frame: CGRect(x: 200, y: 120, width: 1100, height: 760), here: Dictionary(uniqueKeysWithValues: keysOnWindow.map { ($0, 0) }))
            app.paper.layout()
            let made = WindowBench.now()
            draw()
            row("edge tabs for a window with 30 notes", WindowBench.ms(laid, WindowBench.now()),
                "\(app.paper.benchTabs.count) tabs made in \(f(WindowBench.ms(laid, made))) ms, then drawn")
            var moves: [Double] = []
            for step in 1...20 {
                let relaid = WindowBench.now()
                app.paper.previewWindow(scene, frame: CGRect(x: 200 + step * 8, y: 120, width: 1100, height: 760), here: Dictionary(uniqueKeysWithValues: keysOnWindow.map { ($0, 0) }))
                app.paper.layout()
                draw()
                moves.append(WindowBench.ms(relaid, WindowBench.now()))
            }
            row("  laid out again as the window moves", median(moves), "median of \(moves.count) moves; the slowest \(f(moves.max() ?? 0)) ms")
            // Two windows with 15 notes each, coming forward in turn (as switching between them does): each one's tabs
            // laid out and drawn, and how many tab panels were made for them in all (each panel a window of its own).
            let firstKeys = Array(keysOnWindow.prefix(15)), secondKeys = Array(keysOnWindow.suffix(15))
            let other = NoteScene(mac: app.paper.local.mac, app: "com.example.editor", pid: 1, window: 8, title: "Another made-up window")
            // (Held here, so a panel let go can't hand its address to a new one and be counted once for two.)
            var panelsSeen: [ObjectIdentifier: NSPanel] = [:]
            for tab in app.paper.benchTabs { panelsSeen[ObjectIdentifier(tab)] = tab }
            var turns: [Double] = []
            for turn in 0..<20 {
                let keys = turn % 2 == 0 ? secondKeys : firstKeys
                let shown = WindowBench.now()
                app.paper.previewWindow(turn % 2 == 0 ? other : scene, frame: CGRect(x: 200, y: 120, width: 1100, height: 760),
                                        here: Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) }))
                app.paper.layout()
                draw()
                turns.append(WindowBench.ms(shown, WindowBench.now()))
                for tab in app.paper.benchTabs { panelsSeen[ObjectIdentifier(tab)] = tab }
            }
            row("  switching between two windows' tabs", median(turns),
                "median of \(turns.count) switches; the slowest \(f(turns.max() ?? 0)) ms; \(panelsSeen.count) tab panels made in all")
            app.paper.previewWindow(nil, frame: nil, here: [:])
            app.paper.layout()

            // 7. A note with 20 pictures opening: its first frame, then every picture in.
            if let paper = store.notes.first(where: { $0.noteID == pictureNote }) {
                _ = held.take()
                let opening = WindowBench.now()
                app.paper.openStandalone(paper.key, at: CGPoint(x: 300, y: 900))
                if let panel = app.paper.benchPanel(paper.key) { WindowBench.frame(panel) }
                row("a note with 20 pictures opens", WindowBench.ms(opening, WindowBench.now()), "its words, the pictures' room kept")
                let targets = pictureFiles.map(\.path)
                // Drawn again each turn, as a display would ask while they come in: the slowest of those frames.
                var slowest = 0.0
                _ = held.take()
                wait {
                    if let panel = self.app.paper.benchPanel(paper.key) {
                        let from = WindowBench.now()
                        WindowBench.frame(panel)
                        slowest = max(slowest, WindowBench.ms(from, WindowBench.now()))
                    }
                    return targets.allSatisfy { NotePictures.shared.cached($0) != nil }
                }
                let all = WindowBench.now()
                if let panel = app.paper.benchPanel(paper.key) {
                    for _ in 0..<12 {
                        RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
                        let from = WindowBench.now()
                        WindowBench.frame(panel)
                        slowest = max(slowest, WindowBench.ms(from, WindowBench.now()))
                    }
                }
                row("  until its 20 pictures are in", WindowBench.ms(opening, all), "read and decoded off the main thread; the slowest frame meanwhile \(f(slowest)) ms")
                app.paper.fold(paper.key)
            }

            // 8. Nobody touching anything: the window open (laid out and drawn 60 times a second, as --bench-windows
            //    measures every window; then with nothing asking it to draw), then closed. The whole process's CPU,
            //    as a share of one core.
            held.stop()
            if let shown = window() {
                WindowBench.settle(shown, seconds: 1)
                let seconds = 5.0
                report.idleOpen = WindowBench.settle(shown, seconds: seconds) / (seconds * 1000) * 100
                let quiet = WindowBench.processCPU()
                RunLoop.main.run(until: Date().addingTimeInterval(seconds))
                report.idleOpenQuiet = (WindowBench.processCPU() - quiet) / (seconds * 1000) * 100
                WindowBench.closeAsAPerson(shown)
                RunLoop.main.run(until: Date().addingTimeInterval(1))
                let from = WindowBench.processCPU()
                RunLoop.main.run(until: Date().addingTimeInterval(seconds))
                report.idleClosed = (WindowBench.processCPU() - from) / (seconds * 1000) * 100
            }
            report.memory = WindowBench.footprint().now
            return report
        }

        private func f(_ value: Double) -> String { String(format: "%.1f", value) }
        private func median(_ values: [Double]) -> Double { WindowBench.pick(values.sorted(), 0.5) }
        private func steps(_ values: [Double]) -> Steps {
            let sorted = values.sorted()
            return Steps(steps: values.count, median: WindowBench.pick(sorted, 0.5), p95: WindowBench.pick(sorted, 0.95), max: sorted.last ?? 0,
                         over8: values.filter { $0 > 8.333 }.count, over16: values.filter { $0 > 16.667 }.count)
        }

        func print(_ report: Report) {
            let wide = 46
            func line(_ name: String, _ value: String, _ held: String, _ note: String) {
                Swift.print(name.padding(toLength: wide, withPad: " ", startingAt: 0) + String(repeating: " ", count: max(0, 10 - value.count)) + value
                            + String(repeating: " ", count: max(0, 11 - held.count)) + held + (note.isEmpty ? "" : "  " + note))
            }
            Swift.print("")
            line("Petal Notes, \(report.notes) notes in \(report.notebooks) notebooks", "ms", "main held", "")
            for row in report.rows { line(row.name, f(row.ms), f(row.mainHeld), row.note) }
            line("idle CPU, the window open", String(format: "%.2f%%", report.idleOpen), "", "of one core, laid out and drawn 60 times a second (most of it is that asking)")
            line("  with nothing asking it to draw", String(format: "%.2f%%", report.idleOpenQuiet), "", "")
            line("idle CPU, the window closed", String(format: "%.2f%%", report.idleClosed), "", "")
            line("memory at the end", String(format: "%.0f MB", report.memory), "", "")
        }
    }
}
