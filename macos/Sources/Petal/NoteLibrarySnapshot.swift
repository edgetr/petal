import AppKit
import SwiftUI

/// `Petal --snapshot`'s Petal Notes window, canvas and dock: made-up notebooks and notes (nothing of the person's is
/// read or written), drawn as the sketch's "Petal Notes", "Canvas" and "People & Petal AI" scenes.
extension Snapshot {
    @MainActor static func notesLibrary(app: PetalApp, folder: String) {
        let root = FileManager.default.temporaryDirectory.appending(path: "petal-snapshot-library")
        let now = Date()
        let day: TimeInterval = 86400
        let graphite = "#8c8c8c", green = "#62ba46", orange = "#f7821b", pink = "#e0567a", dark = "#555555"
        var notes: [PaperNote] = []
        var n = 0
        func note(_ book: String, _ body: String, age: TimeInterval = day, places: [NoteStick] = [], extra: [(String, [String])] = [],
                  cover: Bool = false, color: String = "") -> PaperNote {
            n += 1
            var file = NoteFile(id: "L\(n)", created: now.addingTimeInterval(-age - day), modified: now.addingTimeInterval(-age), body: body)
            file.places = places
            file.extra = extra.map { (key: $0.0, lines: $0.1) }
            file.cover = cover
            file.color = color
            let paper = PaperNote(file: file, url: root.appending(path: "\(book)/\(cover ? NoteShelf.coverName : "Note \(n).md")"), notebook: book)
            notes.append(paper)
            return paper
        }
        func tab(_ url: String) -> NoteStick { var s = NoteStick(kind: .tab); s.url = url; return s }
        func window(_ app: String, _ title: String) -> NoteStick { var s = NoteStick(kind: .window); s.appName = app; s.title = title; return s }
        func file(_ path: String) -> NoteStick { var s = NoteStick(kind: .file); s.path = path; return s }
        var desk = NoteStick(kind: .desktop)
        desk.desktop = 2
        var person = NoteStick(kind: .person)
        person.title = "Alex"

        // Garden: the notebook the window shows, its cover first.
        let gardenCover = note("Garden", """
            # About this notebook
            The vegetable beds and the balcony. Plant what grows in half shade; water before nine.
            ## Petal remembers
            - The south bed gets sun after noon
            - Tomatoes went in on the 3rd
            - Compost is ready in spring
            - Seeds are in the blue box
            """, cover: true, color: green)
        let backFriday = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 6), matchingPolicy: .nextTime) ?? now
        _ = note("Garden", "# Tulip bulbs\nPlant them before the first frost, 15 cm deep.", age: 3600, places: [tab("https://bulbs.example/autumn")],
                 extra: [("back", ["back: \(NoteFile.stamp(backFriday))"])])
        _ = note("Garden", "# Seed order\nBeans, peas, two kinds of lettuce", age: 2 * day, places: [tab("https://seeds.example/cart")])
        _ = note("Garden", "Water the balcony pots every other morning, more in July.", age: 3 * day, places: [tab("https://garden-guide.example/pots")])
        _ = note("Garden", "@Petal tell me when the hose is under 30", age: 4 * day, places: [tab("https://tools.example/hose")],
                 extra: [("watch", ["watch: { every: 1d, line: \"under 30\", last: \"34\", history: [\"36\"] }"])])
        _ = note("Garden", "# Tools list\n- [ ] gloves\n- [x] trowel\n- [ ] twine", age: 5 * day, places: [desk])
        _ = note("Garden", "Ask the neighbour about the fence", age: 6 * day, places: [window("Mail", "Fence")])
        _ = note("Garden", "Planting plan: the beds are too close on the north side", age: 7 * day, places: [file("/Users/someone/Plan.pdf")])
        _ = note("Garden", "Mulch the strawberries", age: 8 * day, places: [tab("https://garden-guide.example/berries")])
        _ = note("Garden", "Rain barrel near the shed?", age: 40 * day)
        _ = note("Garden", "Bird feeder for winter", age: 45 * day)

        _ = note("Inbox", "# About this notebook\nNotes go here unless you choose another notebook.", cover: true, color: graphite)
        for i in 0..<4 { _ = note("Inbox", "Inbox note \(i + 1)", age: Double(i + 1) * day) }
        _ = note("Work", "# About this notebook\nThe team's week.", cover: true, color: orange)
        for i in 0..<3 { _ = note("Work", "Work note \(i + 1)", age: Double(i + 2) * day) }
        _ = note("Gifts", "# About this notebook\nIdeas for people.", cover: true, color: pink)
        let alexNote = note("Gifts", "Size M. Blue, never orange. Birthday in May.", age: 2 * day, places: [person])
        _ = note("Health", "# About this notebook\nAppointments and results.", cover: true, color: dark)
        _ = note("Health", "# Checkup\nBring the list of questions", age: 2 * day)
        _ = note("Health", "Dentist in March", age: 9 * day)

        var books: [Notebook] = []
        for (name, color) in [("Inbox", graphite), ("Garden", green), ("Work", orange), ("Gifts", pink), ("Health", dark)] {
            let cover = notes.first { $0.notebook == name && $0.file.cover }
            books.append(Notebook(name: name, folder: root.appending(path: name), color: color, cover: cover?.key,
                                  count: notes.filter { $0.notebook == name && !$0.file.cover }.count, isPrivate: name == "Health"))
        }
        app.paper.store.preview(notes, notebooks: books)
        app.paper.preview(here: [:], found: [:])
        let model = app.notesWindow.model
        let rootWords = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/Petal Notes"
        let size = CGSize(width: 1220, height: 748)
        func windowShot(_ name: String, dark: Bool = false) {
            let view = NotesWindowView(model: model, now: now, rootPath: rootWords)
                .clipShape(.rect(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.25), lineWidth: 0.5) }
                .overlay(alignment: .topLeading) { TrafficLights().padding(.leading, 16).padding(.top, 15) }
                .frame(width: size.width, height: size.height)
                .padding(30)
                .background(Self.desk)
                .environment(\.colorScheme, dark ? .dark : .light)
            write(render(AnyView(view), app: app, size: nil), name: name, folder: folder)
        }
        _ = gardenCover
        model.query = ""
        model.shelf = .notebook("Garden")
        windowShot("notes-window-grid")
        windowShot("notes-window-grid-dark", dark: true)

        // The same notebook as a canvas: areas, arrows and words, where the person laid them out.
        if let index = books.firstIndex(where: { $0.name == "Garden" }) { books[index].view = .canvas }
        app.paper.store.preview(notes, notebooks: books)
        let ids = notes.filter { $0.notebook == "Garden" && !$0.file.cover }.map(\.noteID)
        var canvas = NoteCanvas()
        let spots: [(Double, Double)] = [(95, 90), (400, 110), (240, 200), (680, 90), (900, 130), (100, 470), (290, 480), (700, 440), (880, 470)]
        for (i, id) in ids.prefix(spots.count).enumerated() { canvas.notes[id] = .init(x: spots[i].0, y: spots[i].1) }
        canvas.areas = [.init(id: "a1", label: "Beds", x: 60, y: 50, w: 520, h: 330), .init(id: "a2", label: "Balcony", x: 640, y: 50, w: 500, h: 330),
                        .init(id: "a3", label: "Before spring", x: 60, y: 430, w: 400, h: 230)]
        canvas.arrows = [.init(id: "r1", from: ids[0], to: ids[1]), .init(id: "r2", from: ids[6], to: ids[3], dashed: true)]
        canvas.texts = [.init(id: "t1", text: "first thing to buy →", x: 520, y: 600)]
        model.canvas = ("Garden", canvas)
        model.sidebar = false
        windowShot("notes-window-canvas")
        model.sidebar = true
        if let index = books.firstIndex(where: { $0.name == "Garden" }) { books[index].view = .grid }
        app.paper.store.preview(notes, notebooks: books)

        // The Private notebook.
        model.shelf = .notebook("Health")
        windowShot("notes-window-private")
        model.shelf = .notebook("Garden")

        // A notebook in the dock as a stack, its papers fanned up.
        let garden = books.first { $0.name == "Garden" }!
        let stackScene = VStack(alignment: .leading, spacing: 4) {
            // Centred over the stack's icon (the sixth slot), as the popover is over its slot.
            NotebookFanView(book: garden, papers: app.paper.fanned(garden)) {}
                .padding(.leading, 12 + 5 * 60 + 25 - NoteFan.width(count: app.paper.fanned(garden).count) / 2 - 6)
            HStack(spacing: 10) {
                Image(systemName: "sparkle").font(.system(size: 22)).foregroundStyle(Color(red: 0.85, green: 0.21, blue: 0.5))
                    .frame(width: 50, height: 50).glassEffect(.clear, in: .circle)
                ForEach(["#4f8ef7", "#2fb36d", "#f2a33a", "#222222"], id: \.self) { hex in
                    RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: NSColor(hex: hex) ?? .gray)).frame(width: 50, height: 50)
                }
                NotebookPile(color: NSColor(hex: green) ?? .green, icon: 50)
                    .overlay(alignment: .bottom) { Circle().fill(Color(red: 0.85, green: 0.21, blue: 0.5)).frame(width: 4, height: 4).offset(y: 9) }
                ForEach(["#a550a7", "#ff5f57"], id: \.self) { hex in
                    RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: NSColor(hex: hex) ?? .gray)).frame(width: 50, height: 50)
                }
            }
            .padding(.horizontal, 12).frame(height: 72)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .padding(40)
        .background(Self.desk)
        .environment(\.colorScheme, .light)
        write(render(AnyView(stackScene), app: app, size: nil), name: "dock-notebook-stack", folder: folder)

        // A note on a person, beside their conversation in a made-up chat app, resting as a tab on its edge.
        let head = app.paper.letterhead(alexNote)
        let tabs = EdgeLayout.tabs([EdgeNote(id: alexNote.key, line: 90, color: pink, faded: false)], height: 520)
        let chat = ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14).fill(.white).shadow(color: .black.opacity(0.22), radius: 30, y: 22)
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.25), lineWidth: 0.5) }
                .frame(width: 560, height: 520)
            VStack(alignment: .leading, spacing: 0) {
                Text("Alex").font(.system(size: 13, weight: .semibold)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: NSColor(hex: pink) ?? .systemPink).opacity(0.2), in: .rect(cornerRadius: 8))
                Text("Sam").font(.system(size: 13)).foregroundStyle(Color(white: 0.4)).padding(8)
                Text("Robin").font(.system(size: 13)).foregroundStyle(Color(white: 0.4)).padding(8)
                Spacer()
            }
            .padding(.top, 52).padding(.horizontal, 10)
            .frame(width: 170, height: 520, alignment: .top)
            .background(Color(.sRGB, red: 0.953, green: 0.953, blue: 0.965))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14))
            TrafficLights().padding(.leading, 16).padding(.top, 15)
            Text("are we still on for the market saturday?").font(.system(size: 13.5)).padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(white: 0.92), in: .rect(cornerRadius: 16)).offset(x: 200, y: 70)
            Text("yes! I'll bring the bags").font(.system(size: 13.5)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(nsColor: NSColor(hex: pink) ?? .systemPink), in: .rect(cornerRadius: 16)).offset(x: 330, y: 120)
            Text("perfect").font(.system(size: 13.5)).padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(white: 0.92), in: .rect(cornerRadius: 16)).offset(x: 200, y: 170)
            ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                EdgeTabView(tab: tab, colors: [:], outside: false).frame(width: 300, alignment: .trailing).offset(x: 560 - 300, y: tab.y)
            }
            PaperView(paper: alexNote, color: NSColor(hex: pink) ?? .systemPink, glass: false, face: .folded,
                      place: head.place, notebook: head.notebook, others: head.others, footer: NoteDesk.when(alexNote.file.modified))
                .offset(x: 575, y: 40)
        }
        .frame(width: 575 + PaperLook.folded + 10, height: 520, alignment: .topLeading)
        .padding(40)
        .background(Self.desk)
        .environment(\.colorScheme, .light)
        write(render(AnyView(chat), app: app, size: nil), name: "note-person", folder: folder)
    }
}

/// A window's three lights, as the sketch draws them.
struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(.sRGB, red: 1, green: 0.373, blue: 0.341)).frame(width: 12, height: 12)
            Circle().fill(Color(.sRGB, red: 0.996, green: 0.737, blue: 0.18)).frame(width: 12, height: 12)
            Circle().fill(Color(.sRGB, red: 0.157, green: 0.784, blue: 0.251)).frame(width: 12, height: 12)
        }
    }
}
