import AppKit
import SwiftUI

/// `Petal --snapshot`'s Petal Notes: made-up notes in a temporary folder (nothing of the person's is read), drawn
/// over a desk like the sketch's.
extension Snapshot {
    /// The sketch's desk behind the paper.
    static let desk = Color(.sRGB, red: 0xd9 / 255.0, green: 0xdd / 255.0, blue: 0xe6 / 255.0)

    @MainActor static func paperNotes(app: PetalApp, folder: String) {
        let root = FileManager.default.temporaryDirectory.appending(path: "petal-snapshot-notes")
        let blue = "#007aff", orange = "#f7821b", pink = "#e0567a"
        let books = [Notebook(name: "Inbox", folder: root.appending(path: "Inbox"), color: blue, cover: nil, count: 3),
                     Notebook(name: "Work", folder: root.appending(path: "Work"), color: orange, cover: nil, count: 2),
                     Notebook(name: "Home", folder: root.appending(path: "Home"), color: pink, cover: nil, count: 1)]
        let day = Date().addingTimeInterval(-2 * 86400)

        var dentist = NoteFile(id: "S1", created: day, body: "# Book the dentist\nTuesday after 4 works. Bring the insurance card.")
        var clinic = NoteStick(kind: .tab)
        clinic.url = "https://clinic.example/appointments"
        dentist.places = [clinic]
        let folded = PaperNote(file: dentist, url: root.appending(path: "Inbox/Book the dentist.md"), notebook: "Inbox")

        var talk = NoteFile(id: "S2", created: day, modified: Date().addingTimeInterval(-3600), body: """
            # Talk outline
            Open with the question, then three examples. Keep it under ten minutes.
            https://github.com
            ![Crop of the slides · Monday](<Talk outline.assets/crop-1.png>)
            - [x] Draft the slides
            - [ ] Rehearse with a timer
            > The room has a clicker: ask for it at the desk.
            """)
        var page = NoteStick(kind: .tab)
        page.url = "https://developer.apple.com/design/"
        var deck = NoteStick(kind: .file)
        deck.path = "/Users/someone/Talk.key"
        talk.places = [page, deck]
        let open = PaperNote(file: talk, url: root.appending(path: "Work/Talk outline.md"), notebook: "Work")
        LinkPreviews.shared.preview("https://github.com", title: "GitHub · Build and ship software")
        let crop = NSImage(size: NSSize(width: 640, height: 240), flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.85, green: 0.80, blue: 0.71, alpha: 1), NSColor(srgbRed: 0.37, green: 0.29, blue: 0.22, alpha: 1)])?
                .draw(in: rect, angle: -70)
            NSColor(white: 1, alpha: 0.85).setFill()
            NSRect(x: 40, y: 150, width: 260, height: 26).fill()
            NSColor(white: 1, alpha: 0.55).setFill()
            for row in 0..<3 { NSRect(x: 40, y: 110 - CGFloat(row) * 22, width: CGFloat(300 - row * 40), height: 10).fill() }
            return true
        }
        if let file = open.picture("Talk outline.assets/crop-1.png") { NotePictures.shared.preview(file, crop) }

        var lunch = NoteFile(id: "S3", created: day, body: "Lunch near the venue: the place with the long table")
        lunch.places = [page]
        let other = PaperNote(file: lunch, url: root.appending(path: "Home/Lunch.md"), notebook: "Home")
        var passage = NoteStick(kind: .passage)
        passage.url = "https://guide.example/day-one"
        passage.quote = "Doors open at 8."
        var early = NoteFile(id: "S4", created: day, body: "Get there by 7:45 for a seat near the front.")
        early.places = [passage]
        let sentence = PaperNote(file: early, url: root.appending(path: "Inbox/Early.md"), notebook: "Inbox")
        app.paper.store.preview([folded, open, other, sentence], notebooks: books)
        app.paper.preview(here: [folded.key: 0, open.key: 0, other.key: 0, sentence.key: 0], found: [sentence.key: true])

        func paper(_ note: PaperNote, _ face: PaperFace, glass: Bool = false, place: String? = nil) -> some View {
            let head = app.paper.letterhead(note)
            return PaperView(paper: note, color: app.paper.store.color(of: note.notebook), glass: glass, face: face,
                             place: place ?? head.place, notebook: head.notebook, others: head.others, footer: NoteDesk.when(note.file.modified))
        }
        func scene<V: View>(_ view: V) -> AnyView { AnyView(view.padding(40).background(desk).environment(\.colorScheme, .light)) }

        let shots: [(String, AnyView)] = [
            ("note-folded", scene(paper(folded, .folded))),
            ("note-open", scene(paper(open, .open))),
            ("note-back", scene(paper(open, .back))),
            ("note-glass", scene(HStack(alignment: .top, spacing: 30) { paper(folded, .folded, glass: true); paper(open, .open, glass: true) })),
            ("note-sentence", scene(paper(sentence, .folded))),
            ("note-edge-tabs", scene(edgeScene(app: app, keys: [sentence.key, other.key, folded.key, open.key], sentence: sentence))),
        ]
        for (name, view) in shots { write(render(view, app: app, size: nil), name: name, folder: folder) }
        helpers(app: app, folder: folder, root: root, day: day, scene: { scene($0) })

        // The quick question, with Stick here.
        app.paper.previewCapture()
        let ask = ClaudePanel()
        ask.agent.preview([
            .init(kind: .user, text: "What time do the doors open on day one?"),
            .init(kind: .claude, text: "At **8:00**. The guide suggests getting there by 7:45 for a seat near the front."),
        ])
        write(render(AnyView(ClaudePanelView(panel: ask)), app: app, size: nil), name: "quick-question", folder: folder)
    }

    /// Phase 2's papers: the @ menu with its chips, ink on the front, the back with steps and stamps, a watcher, a
    /// task put away, a coding helper's result beside its back, a helper at work, and a quick question with the notes
    /// it used. Made-up notes, never the person's.
    @MainActor private static func helpers(app: PetalApp, folder: String, root: URL, day: Date, scene: (AnyView) -> AnyView) {
        let now = Date()
        let names: (notes: [String], notebooks: [String], place: String) = (["Slides", "Venue"], ["Work", "Home"], "garden.example")
        func paper(_ note: PaperNote, _ face: PaperFace, color: String = "#007aff") -> PaperView {
            PaperView(paper: note, color: NSColor(hex: color) ?? .systemBlue, glass: false, face: face, place: app.paper.letterhead(note).place,
                      notebook: note.notebook, others: app.paper.letterhead(note).others, footer: app.paper.footer(note), names: names)
        }
        var page = NoteStick(kind: .tab)
        page.url = "https://garden.example/talks"
        let friday = NoteHelp.when("Friday", now: now)?.date ?? now

        // The @ menu, its chips, and ink on the front.
        var plan = NoteFile(id: "H1", created: day, body: """
            # Garden talk
            Ask about the side room before Thursday. Bring the clicker.
            https://github.com
            @Petal bring @this back @Friday with @[Slides]
            """)
        plan.places = [page]
        plan.back = friday
        plan.ink = [NoteHelp.Ink(who: "✦ Petal", text: "This note and Slides will be in front of you \(NoteHelp.backLine(friday, now: now).dropFirst(5)).")]
        plan.helper = NoteHelp.Helper(state: .done, who: "✦ Petal", step: "", asked: "@Petal bring @this back @Friday with @[Slides]", at: now)
        let planned = PaperNote(file: plan, url: root.appending(path: "Work/Garden talk.md"), notebook: "Work")
        let menu = MentionMenuView(choices: MentionChoice.choices("", notes: ["Slides", "Venue"], notebooks: ["Work", "Home"]), selected: 0,
                                   accent: NSColor(hex: "#007aff") ?? .systemBlue, pick: { _ in })
        var draft = plan
        draft.ink = []
        draft.helper = nil
        draft.back = nil
        draft.body = "# Garden talk\nAsk about the side room before Thursday. Bring the clicker.\n@Petal bring @this back @Friday with @[Slides]\n@"
        let typing = PaperNote(file: draft, url: planned.url, notebook: "Work")
        app.paper.store.preview([planned], notebooks: [Notebook(name: "Work", folder: root.appending(path: "Work"), color: "#007aff", cover: nil, count: 1)])
        let shots1: [(String, AnyView)] = [
            ("helper-at-menu", scene(AnyView(ZStack(alignment: .topLeading) {
                paper(typing, .open)
                menu.offset(x: 240, y: 150)
            }.frame(width: 520, height: 400, alignment: .topLeading)))),
            ("helper-ink", scene(AnyView(paper(planned, .open)))),
        ]
        for (name, view) in shots1 { write(render(view, app: app, size: nil), name: name, folder: folder) }

        // A coding helper's result, and the back of that note: steps and stamps.
        var pr = NoteStick(kind: .tab)
        pr.url = "https://github.com/example/garden/pull/42"
        var fix = NoteFile(id: "H2", created: day, body: "@Petal use Opus 5.5 to fix the date picker and open a PR. Done means the tests pass. Have GPT 6.1 Sol look for holes")
        fix.places = [pr]
        fix.ink = [NoteHelp.Ink(who: "Opus 5.5", text: "Opened a PR into #42: the picker now keeps the time zone. The tests pass.",
                                proof: ["tests ✓", "diff +9 −3", "PR #43"], link: "https://github.com/example/garden/pull/43", code: true, finish: "the tests pass"),
                   NoteHelp.Ink(who: "GPT 6.1 Sol", text: "1. Does the week view use the same picker? It still shows the old time.", objections: 1)]
        fix.steps = ["New worktree of ~/garden", "Found it: the picker drops the time zone", "Fixed DatePicker.swift", "The tests pass", "Pushed, opened PR #43"]
        fix.stamps = [NoteHelp.Stamp(label: "ALLOWED · CLAUDE · ~/GARDEN", grant: "always:code:/Users/someone/garden", mac: "m"),
                      NoteHelp.Stamp(label: "ALWAYS · GIT PUSH", grant: "rules:Bash(git push)", mac: "m")]
        fix.helper = NoteHelp.Helper(state: .done, who: "Opus 5.5", step: "", at: now.addingTimeInterval(-240))
        let fixed = PaperNote(file: fix, url: root.appending(path: "Work/Date picker.md"), notebook: "Work")

        // A helper at work: its step, Pause and Stop.
        var busy = NoteFile(id: "H3", created: day, body: "Which of these three venues has step-free access?\n@Petal check this page and the other two")
        busy.places = [page]
        busy.helper = NoteHelp.Helper(state: .working, who: "✦ Petal", step: "Reading garden.example/access", at: now)
        let working = PaperNote(file: busy, url: root.appending(path: "Work/Venues.md"), notebook: "Work")

        // A watcher: its newest number in the corner, the older ones struck.
        var lamp = NoteFile(id: "H4", created: day, body: "@Petal check this every morning, tell me under $100")
        var shop = NoteStick(kind: .tab)
        shop.url = "https://lamps.example/kitchen"
        lamp.places = [shop]
        var watch = NoteHelp.Watch(every: "1d", line: "under $100", mac: app.paper.local.mac, at: "09:00", url: shop.url)
        watch.record("$139", at: day)
        watch.record("$129", at: day)
        watch.record("$118", at: now)
        lamp.watch = watch
        let watcher = PaperNote(file: lamp, url: root.appending(path: "Home/Kitchen lamp.md"), notebook: "Home")

        // A task put away.
        var task = NoteFile(id: "H5", created: day, body: "# Renew the bike lock\nTwo shops; the cheaper one ships next week.")
        task.task = [NoteHelp.TaskItem(kind: .tab, title: "Lock A", target: "https://locks.example/a"),
                     NoteHelp.TaskItem(kind: .tab, title: "Lock B", target: "https://locks.example/b"),
                     NoteHelp.TaskItem(kind: .file, title: "Receipt.pdf", target: "/Users/someone/Receipt.pdf"),
                     NoteHelp.TaskItem(kind: .mail, title: "Shop", target: "message://x")]
        task.ink = [NoteHelp.Ink(who: "✦ Petal · put away today", text: "You were comparing delivery dates. Still open: which one fits the old bracket. Next: reply to the shop.")]
        let away = PaperNote(file: task, url: root.appending(path: "Inbox/Renew the bike lock.md"), notebook: "Inbox")

        // A morning note from Petal.
        var morning = NoteFile(id: "H6", created: now, body: "The date picker PR is open and its tests pass. The lamp is $118, was $129. Nothing else needs you.")
        morning.fromPetal = true
        var desk = NoteStick(kind: .desktop)
        desk.desktop = 2
        morning.places = [desk]
        let fromPetal = PaperNote(file: morning, url: root.appending(path: "Work/Morning.md"), notebook: "Work")

        app.paper.store.preview([planned, fixed, working, watcher, away, fromPetal],
                                notebooks: [Notebook(name: "Work", folder: root.appending(path: "Work"), color: "#f7821b", cover: nil, count: 4),
                                            Notebook(name: "Home", folder: root.appending(path: "Home"), color: "#e0567a", cover: nil, count: 1),
                                            Notebook(name: "Inbox", folder: root.appending(path: "Inbox"), color: "#8c8c8c", cover: nil, count: 1)])
        let shots2: [(String, AnyView)] = [
            ("helper-back", scene(AnyView(paper(fixed, .back, color: "#f7821b")))),
            ("helper-code", scene(AnyView(HStack(alignment: .top, spacing: 30) {
                paper(fixed, .open, color: "#f7821b")
                paper(fixed, .back, color: "#f7821b").rotationEffect(.degrees(1))
            }))),
            ("helper-working", scene(AnyView(paper(working, .open, color: "#f7821b")))),
            ("helper-watcher", scene(AnyView(HStack(alignment: .top, spacing: 30) {
                paper(watcher, .folded, color: "#e0567a")
                paper(watcher, .open, color: "#e0567a")
            }))),
            ("helper-task", scene(AnyView(HStack(alignment: .top, spacing: 30) {
                paper(fromPetal, .folded, color: "#f7821b").rotationEffect(.degrees(1.5))
                paper(away, .open, color: "#8c8c8c")
            }))),
        ]
        for (name, view) in shots2 { write(render(view, app: app, size: nil), name: name, folder: folder) }

        // A quick question that used notes: a chip for each.
        let ask = ClaudePanel()
        ask.agent.preview([
            .init(kind: .user, text: "Which lamp did I want, and is it cheaper yet?"),
            .init(kind: .claude, text: "The **kitchen lamp** from lamps.example. It's $118 this morning, down from $129; you asked to hear when it's under $100."),
        ])
        ask.agent.sources = [NoteSource(noteID: "H4", title: "Kitchen lamp"), NoteSource(noteID: "H5", title: "Renew the bike lock")]
        write(render(AnyView(ClaudePanelView(panel: ask)), app: app, size: nil), name: "quick-question-sources", folder: folder)
    }

    /// A made-up window with a sentence highlighted, its notes resting as tabs on its right edge (one with a count,
    /// one hovered, one faded), and the note on the sentence open beside it. The highlight and the pin are where the
    /// sentence's words are, measured with the font they're drawn in (as the live pin uses the app's own bounds for
    /// them), and the pin runs under the tabs (as live, one level below them).
    @MainActor private static func edgeScene(app: PetalApp, keys: [String], sentence: PaperNote) -> some View {
        let width: CGFloat = 620, height: CGFloat = 520
        let tabs = EdgeLayout.tabs([
            EdgeNote(id: "a", line: 128, color: "#007aff", faded: false),
            EdgeNote(id: "b", line: 286, color: "#007aff", faded: false),
            EdgeNote(id: "c", line: 290, color: "#e0567a", faded: false),
            EdgeNote(id: "d", line: nil, color: "#f7821b", faded: false),
            EdgeNote(id: "e", line: 440, color: "#007aff", faded: true),
        ], height: height)
        let head = app.paper.letterhead(sentence)
        let color = app.paper.store.color(of: sentence.notebook)
        // The sentence: its words' place in the line, measured.
        let font = NSFont.systemFont(ofSize: 14.5)
        let before = "Registration is in the main hall. ", quote = "Doors open at 8.", after = " Talks start at 9."
        let measure = { (text: String) in ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        let left: CGFloat = 44, line: CGFloat = 132, lineHeight: CGFloat = 20
        let quoteX = left + measure(before), quoteWidth = measure(quote)
        let note = CGPoint(x: width + 26 + 120, y: 100)
        return ZStack(alignment: .topLeading) {
            // The window.
            RoundedRectangle(cornerRadius: 14).fill(.white).shadow(color: .black.opacity(0.22), radius: 30, y: 22)
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.25), lineWidth: 0.5) }
                .frame(width: width, height: height)
            Rectangle().fill(Color(white: 0.95)).frame(width: width, height: 52)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
            Text("Day one").font(.system(size: 26, weight: .bold)).foregroundStyle(Color(white: 0.07)).offset(x: left, y: 88)
            RoundedRectangle(cornerRadius: 3).fill(Color(.sRGB, red: 0, green: 0.48, blue: 1, opacity: 0.24))
                .frame(width: quoteWidth + 4, height: lineHeight).offset(x: quoteX - 2, y: line - 1)
            Text(before + quote + after).font(Font(font)).foregroundStyle(Color(white: 0.27)).fixedSize()
                .frame(height: lineHeight - 2).offset(x: left, y: line)
            ForEach(0..<3, id: \.self) { row in
                Capsule().fill(Color(white: 0.91)).frame(width: CGFloat([520, 440, 480][row]), height: 9).offset(x: left, y: 166 + CGFloat(row) * 20)
            }
            Text("Where to eat").font(.system(size: 18, weight: .bold)).foregroundStyle(Color(white: 0.07)).offset(x: left, y: 242)
            ForEach(0..<4, id: \.self) { row in
                Capsule().fill(Color(white: 0.91)).frame(width: CGFloat([500, 410, 470, 360][row]), height: 9).offset(x: left, y: 278 + CGFloat(row) * 20)
            }
            // The pin, from the end of the sentence's words to the note, under the tabs.
            PinLine(from: CGPoint(x: quoteX + quoteWidth + 2, y: line + lineHeight / 2 - 1), to: CGPoint(x: note.x, y: note.y + 28), color: Color(nsColor: color))
                .frame(width: note.x + 10, height: height)
                .allowsHitTesting(false)
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                EdgeTabView(tab: tab, colors: [:], outside: false, hovering: index == 1, label: index == 1 ? "Lunch near the venue" : "")
                    .frame(width: 300, alignment: .trailing)
                    .offset(x: width - 300, y: tab.y)
            }
            PaperView(paper: sentence, color: color, glass: false, face: .folded,
                      place: head.place, notebook: head.notebook, others: head.others, footer: NoteDesk.when(sentence.file.modified))
                .offset(x: note.x, y: note.y)
        }
        .frame(width: note.x + PaperLook.folded + 24, height: height, alignment: .topLeading)
    }
}
