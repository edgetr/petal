import AppKit
@preconcurrency import EventKit
import SwiftUI

// Petal Notes in the dock: a notebook kept in the dock is a folder stack (the dock's own `stackFolders`) drawn as a
// little pile of paper in the notebook's color, whose papers fan up when it's clicked; and a note dropped on an app
// is used there (Mail: a new message left as a draft; Calendar: a new event, asked first; any other app: the note's
// text on the clipboard, said so). Nothing is ever sent.

extension NoteDesk {
    /// The notebook a dock stack's folder is, when it's one of the notes' notebooks.
    func notebook(forStack folder: String) -> Notebook? {
        let path = Stacks.url(folder).standardizedFileURL.path
        return store.notebooks.first { $0.folder.standardizedFileURL.path == path }
    }

    /// The papers a notebook's stack fans up: its newest notes (not its cover), newest nearest the dock.
    func fanned(_ book: Notebook) -> [PaperNote] {
        Array(store.notes.filter { $0.version == nil && !$0.file.cover && NoteLibrary.same($0.notebook, book.name) }
            .sorted { $0.file.modified > $1.file.modified }.prefix(NoteFan.limit))
    }

    /// Opens (or brings forward) an app by its bundle id, Launch Services asked off the main thread.
    nonisolated static func bringUp(_ bundle: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Notes on people

    /// A note on a person linked to their vault contact, when exactly one contact has their name (never a guess
    /// between two): only the contact's id is kept, never its details. The vault read off the main thread; while it
    /// can't be read, nothing is linked.
    func linkContact(_ key: String) {
        VaultStore.load { [weak self] result in
            guard let self, case .success(let items) = result, let paper = self.store.paper(key) else { return }
            let contacts = items.filter { $0.kind == .contact }.map { (id: $0.id, name: $0.title) }
            // Only when some person on it has one contact of their name.
            guard paper.file.places.contains(where: { $0.kind == .person && $0.contact.isEmpty && PersonRead.contact($0.title, contacts: contacts) != nil })
            else { return }
            self.store.change(key, expect: paper.revision, touch: false) { file in
                for index in file.places.indices where file.places[index].kind == .person && file.places[index].contact.isEmpty {
                    if let id = PersonRead.contact(file.places[index].title, contacts: contacts) { file.places[index].contact = id }
                }
            }
        }
    }

    // MARK: A note dropped on an app

    /// A note dropped on an app in the dock, used there; never sent.
    func use(_ noteID: String, in bundle: String) {
        // What's typed and not saved yet goes first, so the note is used as it is now.
        if let open = store.current(noteID) { editors[open.key]?.flush() }
        guard let paper = store.current(noteID) else { return }
        let text = NoteDrop.plain(paper.file.body)
        let title = paper.file.title
        switch NoteDrop.action(bundle) {
        case .mail: mail(paper, title: title, text: text)
        case .calendar: calendar(title: title, text: text)
        case .clipboard: clipboard(title: title, text: text, bundle: bundle)
        }
    }

    /// A new message in Mail with the note's words and pictures, left for the person to send (or not).
    private func mail(_ paper: PaperNote, title: String, text: String) {
        let links = NoteBlock.blocks(paper.file.body).compactMap { block -> String? in if case .image(let path, _) = block { path } else { nil } }
        let folder = paper.url.deletingLastPathComponent(), root = store.root
        // Where its pictures are, found off the main thread (the disk, and iCloud may bring them down first).
        NoteStore.io.async {
            let files = links.compactMap { NoteStore.pictureFile($0, noteFolder: folder, root: root) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let service = NSSharingService(named: .composeEmail) else { return self.clipboard(title: title, text: text, bundle: "com.apple.mail") }
                    service.subject = title
                    let items: [Any] = [text as NSString] + files.map { $0 as NSURL }
                    guard service.canPerform(withItems: items) else { return self.clipboard(title: title, text: text, bundle: "com.apple.mail") }
                    service.perform(withItems: items)
                }
            }
        }
    }

    /// A new event from the note's words: its title, and the first time they name (else tomorrow at 9:00, said so),
    /// asked first; added to the default calendar only on Add.
    private func calendar(title: String, text: String) {
        let event = NoteDrop.event(title: title, found: NoteDrop.dates(in: text), now: Date())
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Add “\(event.title)” to Calendar?"
        let when = event.allDay ? event.start.formatted(date: .complete, time: .omitted) : event.start.formatted(date: .complete, time: .shortened)
        alert.informativeText = event.guessed ? "The note names no time, so Petal picked \(when). You can change it in Calendar." : when
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Don't")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        nonisolated(unsafe) let store = EKEventStore()
        store.requestWriteOnlyAccessToEvents { granted, _ in
            var added = false
            if granted, let calendar = store.defaultCalendarForNewEvents {
                let made = EKEvent(eventStore: store)
                made.title = event.title
                made.startDate = event.start
                made.endDate = event.end
                made.isAllDay = event.allDay
                made.notes = text
                made.calendar = calendar
                added = (try? store.save(made, span: .thisEvent)) != nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if added {
                        Self.bringUp("com.apple.iCal")
                        self.tell("Added to Calendar: \(event.title)")
                    } else {
                        self.tell(granted ? "Calendar didn't take the event." : "Petal may add events once you allow it in System Settings › Privacy & Security › Calendars.")
                    }
                }
            }
        }
    }

    /// Any other app: it comes forward and the note's words are on the clipboard, said so (nothing is pasted).
    private func clipboard(title: String, text: String, bundle: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        Self.bringUp(bundle)
        tell("“\(title.isEmpty ? "The note" : title)” is on the clipboard: paste it into \(Apps.cachedName(bundle) ?? "the app").")
    }
}

// MARK: - A notebook's stack

/// A notebook in the dock: a little pile of paper in its color.
struct NotebookPile: View {
    let color: NSColor
    let icon: CGFloat

    var body: some View {
        let tint = PaperLook.rgb(color)
        let side = icon * 0.86
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.16).fill(PaperLook.color(NoteInk.mix(tint, 0.30, NoteInk.paper)))
                .frame(width: side * 0.86, height: side * 0.86).rotationEffect(.degrees(-8)).offset(x: -side * 0.04, y: side * 0.02)
                .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
            RoundedRectangle(cornerRadius: side * 0.16).fill(PaperLook.color(NoteInk.mix(tint, 0.24, NoteInk.paper)))
                .frame(width: side * 0.86, height: side * 0.86).rotationEffect(.degrees(5)).offset(x: side * 0.03)
                .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
            RoundedRectangle(cornerRadius: side * 0.16).fill(PaperLook.color(NoteInk.mix(tint, 0.20, NoteInk.paper)))
                .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: color)).frame(height: max(2, side * 0.07)) }
                .clipShape(.rect(cornerRadius: side * 0.16))
                .overlay {
                    VStack(alignment: .leading, spacing: side * 0.07) {
                        ForEach(0..<3, id: \.self) { row in
                            Capsule().fill(Color.black.opacity(0.13)).frame(width: side * [0.5, 0.42, 0.3][row], height: max(1.5, side * 0.045))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, side * 0.14).padding(.top, side * 0.08)
                }
                .overlay { RoundedRectangle(cornerRadius: side * 0.16).stroke(.black.opacity(0.15), lineWidth: 0.5) }
                .frame(width: side * 0.86, height: side * 0.86)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1.5)
        }
        .frame(width: icon, height: icon)
    }
}

/// A notebook's papers fanned up from its stack: the newest nearest the dock, each turned a little; clicked, one
/// opens on its own; dragged, it can go onto an app in the dock.
struct NotebookFanView: View {
    @Environment(PetalApp.self) private var app
    let book: Notebook
    let papers: [PaperNote]
    let done: () -> Void

    var body: some View {
        let spots = NoteFan.spots(count: papers.count)
        let height = (spots.last?.y ?? 0) + NoteFan.paper + 40
        let width = NoteFan.width(count: papers.count)
        let left = (width - NoteFan.paper) / 2
        VStack(spacing: 8) {
            Button {
                done()
                app.notesWindow.show(.notebook(book.name))
            } label: {
                HStack(spacing: 6) {
                    Text(book.name).fontWeight(.semibold)
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            ZStack(alignment: .bottomLeading) {
                if papers.isEmpty {
                    Text("No notes yet").font(.system(size: 12)).foregroundStyle(.secondary).padding(12).glassEffect(.regular, in: .capsule)
                }
                ForEach(Array(papers.enumerated().reversed()), id: \.element.key) { index, paper in
                    let spot = spots[index]
                    GridPaper(paper: paper, now: Date(), opening: done)
                        .scaleEffect(NoteFan.paper / NotesGrid.cell, anchor: .bottomLeading)
                        .frame(width: NoteFan.paper, height: NoteFan.paper, alignment: .bottomLeading)
                        .rotationEffect(.degrees(spot.angle), anchor: .bottomLeading)
                        .offset(x: left + spot.x, y: -spot.y - 10)
                }
            }
            .frame(width: width, height: papers.isEmpty ? 50 : height, alignment: .bottomLeading)
        }
        .padding(6)
    }
}
