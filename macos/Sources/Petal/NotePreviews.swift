import AppKit
import ScreenCaptureKit
import SwiftUI

/// The AI button's preview: hovering it, as hovering an app shows its windows, shows each sticky note that's working,
/// waiting for the person, or done and not seen yet, with a live picture of the window it works in (refreshed once
/// a second while the preview is open), its latest step, and Stop. Clicking one brings its window (and tab) forward
/// and opens the note there. With none of those, hovering the button shows its tooltip as before.
struct NotePreviewItem: Identifiable, Equatable {
    let id: UUID
    /// Its app's bundle id ("" for a chat stuck to no window).
    let app: String
    let appName: String
    /// The chat's first words.
    let title: String
    let line: String
    let working: Bool
    let needsYou: Bool
    /// A private app (`aiNeverLook`): no picture, only its name.
    let hidden: Bool
    let pid: pid_t
    /// The window it works in, when known (an app's note: the one its AI last looked at, or its app's first).
    let window: CGWindowID?
    /// Stuck to a window that's still there: it has a picture, and clicking it brings that window forward.
    let attached: Bool
    /// Stuck to all of its app: its picture may be any of that app's windows.
    var appWide = false

    var seen: NotePicture.Seen {
        NotePicture.Seen(app: app, attached: attached, pid: pid, window: window, hidden: hidden, appWide: appWide)
    }
    /// Its picture may show: stuck to a window still there, of an app not kept private.
    var pictured: Bool { NotePicture.shows(seen) }
}

extension ClaudePanel {
    /// One note's line, from its chat and Petal AI's question waiting.
    func facts(_ note: StickyNote) -> NoteStatus.Facts {
        let agent = note.agent
        let asking = PetalApp.shared.assist.pending.flatMap { $0.owner == note.id.uuidString ? $0.title : nil }
        let waiting = !agent.running && !agent.waiting.isEmpty
        return NoteStatus.Facts(running: agent.running || waiting, ready: note.ready, asking: asking, needs: agent.needs,
                                activity: waiting ? "Waiting for another note to finish" : agent.activity)
    }

    /// The notes the preview shows, waiting for the person first.
    var previewItems: [NotePreviewItem] {
        let all = notes.map { ($0, facts($0)) }
        let assist = PetalApp.shared.assist
        return NoteStatus.order(all.map(\.1)).map { index in
            let (note, facts) = all[index]
            let place = note.attached ? note.place : nil
            let window = place.flatMap { $0.kind == .app ? assist.computer.maps[note.id.uuidString]?.windowID : $0.window }
            // Private by the app it was stuck to, even once that window is gone (or the chat kept it from before).
            let hidden = NotePicture.hidden(app: note.place?.app ?? note.agent.keptPlace?.app, private: assist.neverLook)
            return NotePreviewItem(id: note.id, app: place?.app ?? "", appName: place?.appName ?? "", title: note.agent.title,
                                   line: NoteStatus.line(facts), working: facts.running, needsYou: NoteStatus.needsYou(facts),
                                   hidden: hidden, pid: place?.pid ?? 0, window: window, attached: place != nil,
                                   appWide: place?.kind == .app)
        }
    }

    /// Some note waits for the person (its window in front, its tab showing, an answer) and isn't open in front of
    /// them: the AI button wears a small ✦.
    var needsYou: Bool {
        notes.contains { NoteStatus.needsYou(facts($0)) && !(isOpen && current === $0) }
    }

    /// A note picked in the preview: its window (and tab) comes forward and it opens there; a chat stuck to no window
    /// (or one whose window is gone) opens as it is.
    func openFromPreview(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        if notesOn, note.attached, let place = note.place { go(to: note, place: place) } else { present(note) }
    }

    /// Stop on a note in the preview: its reply ends where it is, and what it was doing in the app with it. One
    /// still waiting for room never starts: what it was to send goes back into the note, unsent.
    func stopFromPreview(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        stop(note)
    }

    /// Stop, from the preview or the note's own panel.
    func stop(_ note: StickyNote) {
        if let unsent = note.agent.withdrawWaiting() {
            note.draft = [unsent, note.draft].filter { !$0.isEmpty }.joined(separator: "\n\n")
            return
        }
        note.agent.stop()
    }
}

extension Capture {
    /// One picture of each note's window, by its window server number and process (covered windows too, and windows
    /// on another Desktop); only a note on all of an app falls back to that app's first ordinary window
    /// (NotePicture.pick). Each comes with the window it actually shows. Never a private app's.
    /// `excluding`: windows showing a Private notebook's note (NotePrivacy.excludedWindows): never pictured.
    static func notes(_ targets: [(id: UUID, seen: NotePicture.Seen)], height: CGFloat = 150, excluding: Set<Int> = []) async
        -> [UUID: (image: NSImage, shot: NotePicture.Shot)] {
        guard allowed, !targets.isEmpty, let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else { return [:] }
        let windows = content.windows.filter { NotePrivacy.mayCapture(window: Int($0.windowID), excluded: excluding) }.compactMap { window in
            window.owningApplication.map { (shot: NotePicture.Shot(pid: $0.processID, window: window.windowID), window: window) }
        }
        let byShot = Dictionary(windows.map { ($0.shot.window, $0.window) }, uniquingKeysWith: { first, _ in first })
        var result: [UUID: (image: NSImage, shot: NotePicture.Shot)] = [:]
        for target in targets {
            let ordinary = { (shot: NotePicture.Shot) in
                byShot[shot.window].map { $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60 } ?? false
            }
            guard let shot = NotePicture.pick(target.seen, from: windows.map(\.shot), ordinary: ordinary),
                  let match = byShot[shot.window] else { continue }
            let configuration = SCStreamConfiguration()
            let scale = height * 2 / max(1, match.frame.height)
            configuration.width = Int(match.frame.width * scale)
            configuration.height = Int(match.frame.height * scale)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: match)
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                result[target.id] = (NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2)), shot)
            }
        }
        return result
    }
}

/// The notes over the AI button: a tile each, side by side; more than fit scroll sideways, so every note at work
/// (and every one waiting for room) keeps its Stop.
struct NotesPreview: View {
    @Environment(PetalApp.self) private var app
    let done: () -> Void
    static let tile: CGFloat = 200
    static let gap: CGFloat = 12

    var body: some View {
        let items = app.previews.noteItems
        let row = HStack(alignment: .top, spacing: Self.gap) {
            ForEach(items) { item in
                NoteTile(item: item, image: app.previews.noteThumb(item), done: done)
            }
        }
        if NoteStatus.previewScrolls(items.count) {
            let fits = CGFloat(NoteStatus.tilesInView)
            ScrollView(.horizontal) { row.padding(.bottom, 10) }
                .scrollIndicators(.visible)
                .frame(width: fits * Self.tile + (fits - 1) * Self.gap)
        } else {
            row
        }
    }
}

struct NoteTile: View {
    @Environment(PetalApp.self) private var app
    let item: NotePreviewItem
    let image: NSImage?
    let done: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25))
                if let image, item.pictured {
                    Image(nsImage: image).resizable().scaledToFit().padding(3)
                } else if item.attached {
                    VStack(spacing: 6) {
                        AppIconView(id: item.app, size: 36)
                        if item.hidden { Text("Kept private").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                } else {
                    ProviderMark(provider: app.chatProvider).foregroundStyle(.white.opacity(0.7)).frame(width: 30, height: 30)
                }
            }
            .frame(width: 200, height: 124)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hovering ? Color(nsColor: app.accent) : .white.opacity(0.12),
                                                                    lineWidth: hovering ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if item.working { RoundButton(symbol: "stop.fill", size: 22) { app.claude.stopFromPreview(item.id) }.padding(6).help("Stop") }
            }
            HStack(spacing: 6) {
                if item.attached { AppIconView(id: item.app, size: 14) }
                Text(item.title.isEmpty ? (item.appName.isEmpty ? "Petal AI" : item.appName) : item.title)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if item.needsYou { Circle().fill(Color(nsColor: app.accent)).frame(width: 6, height: 6) }
                Text(item.line).font(.system(size: 11.5)).foregroundStyle(item.needsYou ? .primary : .secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 200, alignment: .leading)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { done(); app.claude.openFromPreview(item.id) }
    }
}

/// On an open note, while it waits for the person or works in the background: one quiet line saying so.
struct NoteActivityLine: View {
    @Environment(PetalApp.self) private var app
    let panel: ClaudePanel
    let note: StickyNote

    var body: some View {
        let agent = note.agent
        HStack(spacing: 6) {
            if let needs = agent.needs {
                Circle().fill(Color(nsColor: app.accent)).frame(width: 6, height: 6)
                Text("Waiting for you: " + needs).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if note.attached, let place = note.place {
                    Button("Bring it forward") { panel.go(to: note, place: place) }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color(nsColor: app.accent))
                }
            } else {
                Image(systemName: "moon.zzz").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("In the background · " + NoteStatus.step(agent.activity)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
    }

    /// Shown while the note waits for the person, or works in its window in the background.
    static func shows(_ agent: Agent) -> Bool { agent.needs != nil || (agent.running && agent.quietly) }
}
