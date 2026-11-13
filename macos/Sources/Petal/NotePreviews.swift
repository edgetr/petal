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
    /// The run works on a hidden display of its own (RunDisplays): the tile shows that display, live, with Show me.
    var display: UUID? = nil
    /// An AI session outside Petal (T3 Code, a terminal), which has no note: its display's own tile.
    var outside = false

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
                                activity: waiting ? "Waiting for another note to finish" : agent.activity.text,
                                waitingForDisplay: PetalApp.shared.displays.waits(note.id.uuidString),
                                waitingForApp: PetalApp.shared.displays.waitsForApp(note.id.uuidString))
    }

    /// The notes the preview shows, waiting for the person first.
    var previewItems: [NotePreviewItem] {
        // A helper of a note in a Private notebook never shows here.
        let helpers = PetalApp.shared.paper.helpers
        let all = notes.filter { $0.paper == nil || helpers.previewable($0) }.map { ($0, facts($0)) }
        let assist = PetalApp.shared.assist
        let displays = PetalApp.shared.displays
        // An AI session outside Petal working on a display of its own has no note: a tile of its own, after the notes.
        let outside = displays.outside.map { display in
            NotePreviewItem(id: display.id, app: "", appName: "", title: display.label.isEmpty ? "An AI session" : display.label,
                            line: "Working on a display of its own", working: true, needsYou: false, hidden: false, pid: 0, window: nil,
                            attached: false, display: display.id, outside: true)
        }
        return NoteStatus.order(all.map(\.1)).map { index in
            let (note, facts) = all[index]
            let place = note.attached ? note.place : nil
            let window = place.flatMap { $0.kind == .app ? assist.computer.maps[note.id.uuidString]?.windowID : $0.window }
            // Private by the app it was stuck to, even once that window is gone (or the chat kept it from before).
            let hidden = NotePicture.hidden(app: note.place?.app ?? note.agent.keptPlace?.app, private: assist.neverLook)
            // A helper's chat keeps no message of the person's: its tile is named by its note.
            let title = note.paper.flatMap { PetalApp.shared.paper.helpers.paper($0)?.file.title } ?? note.agent.title
            return NotePreviewItem(id: note.id, app: place?.app ?? "", appName: place?.appName ?? "", title: title,
                                   line: NoteStatus.line(facts), working: facts.running, needsYou: NoteStatus.needsYou(facts),
                                   hidden: hidden, pid: place?.pid ?? 0, window: window, attached: place != nil,
                                   appWide: place?.kind == .app, display: displays.display(for: note.id.uuidString)?.id)
        } + outside
    }

    /// Some note waits for the person (its window in front, its tab showing, an answer) and isn't open in front of
    /// them: the AI button wears a small ✦.
    var needsYou: Bool {
        notes.contains { (NoteStatus.needsYou(facts($0)) || $0.ready && $0.place == nil) && !(isOpen && current === $0) }
    }

    /// A note picked in the preview: its window (and tab) comes forward and it opens there; a chat stuck to no window
    /// (or one whose window is gone) opens as it is.
    func openFromPreview(_ id: UUID) {
        // An outside session's tile has no note to open: clicking it is Show me.
        guard let note = notes.first(where: { $0.id == id }) else { return showFromPreview(id) }
        if note.paper != nil { return PetalApp.shared.paper.helpers.show(note) }
        if notesOn, note.attached, let place = note.place { go(to: note, place: place) } else { present(note) }
    }

    /// Stop on a note in the preview: its reply ends where it is, and what it was doing in the app with it. One
    /// still waiting for room never starts: what it was to send goes back into the note, unsent.
    func stopFromPreview(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }) else { return PetalApp.shared.displays.stop(tile: id) }
        stop(note)
    }

    /// Show me, on a run with a hidden display of its own: its windows come to the person's screen, and it goes on.
    func showFromPreview(_ id: UUID) {
        let displays = PetalApp.shared.displays
        if let note = notes.first(where: { $0.id == id }) { return displays.showMe(caller: note.id.uuidString) }
        if let display = displays.display(tile: id) { displays.showMe(group: display.group) }
    }

    /// Stop, from the preview or the note's own panel.
    func stop(_ note: StickyNote) {
        // A note's helper stops through its run (NoteHelpers.stop), wherever Stop was pressed.
        if let paper = note.paper { return PetalApp.shared.paper.helpers.stop(paper) }
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
                RoundedRectangle(cornerRadius: Radius.tile).fill(.black.opacity(0.25))
                if item.display != nil {
                    // Its own display, live; before the first picture (or without Screen Recording), a plain mark.
                    if let shown = app.previews.displayThumb(item) {
                        Image(nsImage: shown).resizable().scaledToFit().padding(3)
                    } else {
                        Image(systemName: "display").font(.system(size: TextSize.large, weight: .light)).foregroundStyle(.white.opacity(0.7))
                    }
                } else if let image, item.pictured {
                    Image(nsImage: image).resizable().scaledToFit().padding(3)
                } else if item.attached {
                    VStack(spacing: 6) {
                        AppIconView(id: item.app, size: 36)
                        if item.hidden { Text("Kept private").font(.system(size: TextSize.small)).foregroundStyle(.secondary) }
                    }
                } else {
                    ProviderMark(provider: app.chatProvider).foregroundStyle(.white.opacity(0.7)).frame(width: 30, height: 30)
                }
            }
            .frame(width: 200, height: 124)
            .overlay(RoundedRectangle(cornerRadius: Radius.tile).strokeBorder(hovering ? Color(nsColor: app.accent) : .white.opacity(0.12),
                                                                    lineWidth: hovering ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if item.working { RoundButton(symbol: "stop.fill", size: 22) { app.claude.stopFromPreview(item.id) }.padding(6).help("Stop") }
            }
            .overlay(alignment: .bottomLeading) {
                if item.display != nil {
                    ShowMeButton { done(); app.claude.showFromPreview(item.id) }.padding(6)
                }
            }
            HStack(spacing: 6) {
                if item.attached { AppIconView(id: item.app, size: 14) }
                Text(item.title.isEmpty ? (item.appName.isEmpty ? "Petal AI" : item.appName) : item.title)
                    .font(.system(size: TextSize.callout, weight: .medium)).lineLimit(1).truncationMode(.tail)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if item.needsYou { Circle().fill(Color(nsColor: app.accent)).frame(width: 6, height: 6) }
                Text(item.line).font(.system(size: TextSize.small)).foregroundStyle(item.needsYou ? .primary : .secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 200, alignment: .leading)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { done(); app.claude.openFromPreview(item.id) }
    }
}

/// "Show me", on a run that works on a hidden display of its own: its window comes to the person's screen.
struct ShowMeButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Show me").font(.system(size: TextSize.small, weight: .medium))
                .padding(.horizontal, 9).frame(height: 22)
                .glassEffect(hovering ? .clear.tint(Color(nsColor: PetalApp.shared.accent)).interactive() : .clear.interactive(), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Bring its window to your screen")
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
                Text("Waiting for you: " + needs).font(.system(size: TextSize.small)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if note.attached, let place = note.place {
                    Button("Bring it forward") { panel.go(to: note, place: place) }
                        .buttonStyle(.plain).font(.system(size: TextSize.small, weight: .medium)).foregroundStyle(Color(nsColor: app.accent))
                }
            } else {
                Image(systemName: "moon.zzz").font(.system(size: TextSize.caption)).foregroundStyle(.secondary)
                Text("In the background · " + NoteStatus.step(agent.activity.text)).font(.system(size: TextSize.small)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
    }

    /// Shown while the note waits for the person, or works in its window in the background.
    static func shows(_ agent: Agent) -> Bool { agent.needs != nil || (agent.running && agent.quietly) }
}
