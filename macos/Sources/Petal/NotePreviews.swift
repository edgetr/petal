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
            return NotePreviewItem(id: note.id, app: place?.app ?? "", appName: place?.appName ?? "", title: note.agent.title,
                                   line: NoteStatus.line(facts), working: facts.running, needsYou: NoteStatus.needsYou(facts),
                                   hidden: place.map { assist.neverLook($0.app) } ?? false, pid: place?.pid ?? 0,
                                   window: window, attached: place != nil)
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

    /// Stop on a note in the preview: its reply ends where it is, and what it was doing in the app with it.
    func stopFromPreview(_ id: UUID) {
        notes.first { $0.id == id }?.agent.stop()
    }
}

extension Capture {
    /// One picture of each note's window, by its window server number (covered windows too, and windows on another
    /// Desktop), else its app's first ordinary window. Never a private app's.
    static func notes(_ targets: [(id: UUID, pid: pid_t, window: CGWindowID?)], height: CGFloat = 150) async -> [UUID: NSImage] {
        guard allowed, !targets.isEmpty, let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else { return [:] }
        var result: [UUID: NSImage] = [:]
        for target in targets {
            let byNumber = target.window.flatMap { number in content.windows.first { $0.windowID == number } }
            guard let match = byNumber ?? content.windows.first(where: {
                $0.owningApplication?.processID == target.pid && $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60
            }) else { continue }
            let configuration = SCStreamConfiguration()
            let scale = height * 2 / max(1, match.frame.height)
            configuration.width = Int(match.frame.width * scale)
            configuration.height = Int(match.frame.height * scale)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: match)
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                result[target.id] = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
            }
        }
        return result
    }
}

/// The notes over the AI button: a tile each, side by side.
struct NotesPreview: View {
    @Environment(PetalApp.self) private var app
    let done: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(app.previews.noteItems.prefix(4)) { item in
                NoteTile(item: item, image: app.previews.noteThumbs[item.id], done: done)
            }
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
                if let image, !item.hidden {
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
