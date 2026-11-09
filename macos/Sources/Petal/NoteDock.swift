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

    // MARK: A note dropped on an app

    /// A note dropped on an app in the dock, used there; never sent.
    func use(_ noteID: String, in bundle: String) {
        // What's typed and not saved yet goes first, so the note is used as it is now.
        if let open = store.current(noteID) { editors[open.key]?.flush() }
        guard let paper = store.current(noteID) else { return }
        // A note with two versions isn't used anywhere until one is kept: which words would go is the person's call.
        guard NoteDrop.allowed(versions: store.conflict(of: paper)?.count ?? 1) else {
            return tell("This note has two versions right now: keep one, then drop it again.")
        }
        let text = NoteDrop.plain(paper.file.body)
        let title = paper.file.title
        switch NoteDrop.action(bundle) {
        case .mail: mail(paper, title: title, text: text)
        case .calendar: calendar(title: title, text: text)
        case .clipboard: clipboard(title: title, text: text, bundle: bundle)
        }
    }

    /// A new message in Mail with the note's words and pictures, left for the person to send (or not).
    /// A new message in Mail with the note's words and pictures, left for the person to send (or not). What's typed
    /// is saved first, and the note's picture work (bytes still being saved) is waited for, a few seconds at most; a
    /// picture still not in its folder goes from the bytes Petal holds, staged in a temporary folder Petal removes
    /// later; one not available at all is said ("1 picture couldn't be attached").
    private func mail(_ paper: PaperNote, title: String, text: String, tries: Int = 15) {
        if store.picturesPending(paper.key), tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated {
                    guard let now = self.store.paper(paper.key) else { return }
                    self.mail(now, title: now.file.title, text: NoteDrop.plain(now.file.body), tries: tries - 1)
                }
            }
            return
        }
        let links = NoteBlock.blocks(paper.file.body).compactMap { block -> String? in if case .image(let path, _) = block { path } else { nil } }
        let held = Dictionary(links.compactMap { link in
            let name = (link as NSString).lastPathComponent
            return store.heldPicture(paper.noteID, name).map { (name, $0) }
        }, uniquingKeysWith: { a, _ in a })
        let folder = paper.url.deletingLastPathComponent(), root = store.root
        // Where its pictures are, found off the main thread (the disk, and iCloud may bring them down first).
        NoteStore.io.async {
            let stage = NoteDrop.stagingRoot.appending(path: UUID().uuidString)
            var files: [URL] = []
            var missing = 0
            for link in links {
                let name = (link as NSString).lastPathComponent
                let onDisk = NoteStore.pictureFile(link, noteFolder: folder, root: root).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                switch NoteDrop.attachment(onDisk: onDisk != nil, held: held[name] != nil) {
                case .file:
                    // Only pictures that are documents, as they really are (NoteTasks' rule).
                    if let onDisk, case (let url, .open) = NoteTasks.decide(onDisk) { files.append(url) } else { missing += 1 }
                case .stage:
                    if let staged = NoteDrop.stage(held[name]!, name: name, in: stage), case (let url, .open) = NoteTasks.decide(staged) { files.append(url) }
                    else { missing += 1 }
                case .missing:
                    missing += 1
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let cleanUp = { MailStaging.remove(stage) }
                    guard let service = NSSharingService(named: .composeEmail) else { cleanUp(); return self.clipboard(title: title, text: text, bundle: "com.apple.mail") }
                    service.subject = title
                    let items: [Any] = [text as NSString] + files.map { $0 as NSURL }
                    guard service.canPerform(withItems: items) else { cleanUp(); return self.clipboard(title: title, text: text, bundle: "com.apple.mail") }
                    // The staged copies go when the share finishes (once Mail has taken them in) or fails; a quit before
                    // that leaves them for the next launch's sweep (NoteDrop.sweepStaging).
                    service.delegate = MailStaging.watch(stage)
                    service.perform(withItems: items)
                    if let words = NoteDrop.missingWords(missing) { self.tell(words) }
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

// MARK: - Mail's staged pictures

/// The staging folder of each Mail draft being shared, removed when its share finishes (a moment later, so Mail has
/// taken the pictures in) or fails. Kept alive here while the share is under way (a share service's delegate is weak).
@MainActor
final class MailStaging: NSObject, NSSharingServiceDelegate {
    private static var watching: [ObjectIdentifier: MailStaging] = [:]
    private let folder: URL

    private init(_ folder: URL) { self.folder = folder }

    static func watch(_ folder: URL) -> MailStaging {
        let watcher = MailStaging(folder)
        watching[ObjectIdentifier(watcher)] = watcher
        return watcher
    }

    nonisolated static func remove(_ folder: URL, after delay: TimeInterval = 0) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { try? FileManager.default.removeItem(at: folder) }
    }

    private func done(after delay: TimeInterval) {
        Self.remove(folder, after: delay)
        Self.watching[ObjectIdentifier(self)] = nil
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.done(after: 30) } }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.done(after: 0) } }
    }
}

// MARK: - A task's parts

extension NoteTasks {
    /// Open all: each part of a task through the normal open paths: a tab (http or https only) in the person's
    /// browser, a mail (a `message:` address only) in Mail, a file in its own app only once it's resolved (aliases and
    /// symbolic links followed, off the main thread) and found to be a document (`fileAction`); anything else is shown
    /// in Finder, selected, never opened, and said. Asynchronous throughout (Launch Services never asked on the main
    /// thread to wait), never moving the pointer; nothing is sent or changed. Returns how many parts it will try.
    @MainActor @discardableResult
    static func openAll(_ items: [NoteContract.TaskItem], said: @escaping @MainActor (String) -> Void = { _ in }) -> Int {
        let urls = openable(items)
        let skipped = items.count - urls.count
        DispatchQueue.global(qos: .userInitiated).async {
            let decided = urls.map { url in url.isFileURL ? decide(url) : (url, FileAction.open) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let failed = Counter()
                    let group = DispatchGroup()
                    var revealed: [URL] = []
                    for (url, action) in decided {
                        if action == .reveal { revealed.append(url); continue }
                        group.enter()
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                            if error != nil { failed.add() }
                            group.leave()
                        }
                    }
                    if !revealed.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(revealed) }
                    group.notify(queue: .main) {
                        MainActor.assumeIsolated {
                            var words: [String] = []
                            if !revealed.isEmpty {
                                words.append(revealed.count == 1 ? "\(revealed[0].lastPathComponent) isn't a document, so Petal showed it in Finder instead of opening it."
                                                                 : "\(revealed.count) parts aren't documents, so Petal showed them in Finder instead of opening them.")
                            }
                            let missed = failed.value + skipped
                            if missed > 0 { words.append(missed == 1 ? "One part couldn't be opened." : "\(missed) parts couldn't be opened.") }
                            if !words.isEmpty { said(words.joined(separator: " ")) }
                        }
                    }
                }
            }
        }
        return urls.count
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
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
