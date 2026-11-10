import AppKit
import Observation
import SwiftUI

/// Replies drafted for held messages (`replyDrafts`): entering a mode with messages waiting on it, the quick AI
/// (Claude Haiku, Codex's Luna) drafts an answer to each that needs one, in the person's own way of writing, and a
/// card shows them. Petal never sends anything: "Copy and open" puts the reply on the clipboard and opens the chat.
/// The replies the person edits before using are kept (the last few) and shown to the AI as their style.
@MainActor @Observable
final class Drafts {
    struct Draft: Identifiable, Equatable {
        var id: Int64 { note.id }
        let note: HeldNote
        let original: String
        var text: String
    }

    private(set) var drafts: [Draft] = []
    @ObservationIgnored private var asking = 0
    /// Each entry into a mode is its own batch: answers from an earlier one are dropped.
    @ObservationIgnored private var batch = 0

    var app: PetalApp { PetalApp.shared }

    /// Apps whose notifications are messages someone may answer.
    static let messaging: Set<String> = ["com.tinyspeck.slackmacgap", "com.apple.mobilesms", "net.whatsapp.whatsapp", "desktop.whatsapp",
                                         "ru.keepcoder.telegram", "com.hnc.discord", "com.apple.mail", "com.microsoft.teams2",
                                         "org.whispersystems.signal-desktop", "com.facebook.archon", "com.readdle.smartemail-mac"]

    private static var styleFile: URL {
        Config.supportFolder.appending(path: "writing-style.json")
    }

    /// Another mode in front: drafts still on their way for the last one are dropped.
    func modeChanged() {
        batch += 1
        if !drafts.isEmpty, app.popups.card?.kind == .reply { app.popups.dismissCard() }
        drafts = []
    }

    /// Entering `mode` with `notes` held for it: draft what needs an answer.
    func prepare(_ notes: [HeldNote], for mode: Mode) {
        guard app.config.bool("replyDrafts"), app.focus.brain.enabled else { return }
        // Never an app kept private: its messages don't go to the AI.
        let messages = notes.filter { Self.messaging.contains(Notes.appID($0.app).lowercased()) && !$0.body.isEmpty
            && !app.assist.neverLook(Notes.appID($0.app)) }.suffix(3)
        guard !messages.isEmpty else { return }
        drafts = []
        asking = messages.count
        batch += 1
        let ticket = batch
        let style = Self.style()
        let remembered = !app.config.bool("aiMemory") ? [] : app.assist.memories.filter { $0.mode.isEmpty || $0.mode == mode.id }.map(\.text).prefix(12)
        for note in messages {
            let prompt = """
            Draft a reply for the user to a message they got, in their own way of writing. Don't send anything; it's a draft they'll edit.
            Message in \(Apps.name(Notes.appID(note.app))) from "\(note.title)"\(note.subtitle.isEmpty ? "" : " (\(note.subtitle))"): "\(note.body.prefix(600))"
            \(remembered.isEmpty ? "" : "What you know about the user: " + remembered.joined(separator: "; "))
            \(style.isEmpty ? "" : "Replies they wrote before, to match their tone and length: " + style.map { "\"\($0)\"" }.joined(separator: " | "))
            If it needs no answer (a notice, an automated message), say so. Keep the reply short and natural, in the message's language, with no greeting or sign-off they wouldn't use.
            Reply with ONLY JSON: {"needsReply": true|false, "reply": "<the draft>"}
            """
            app.focus.brain.ask(prompt, key: "reply|\(note.id)") { [weak self] answer in
                guard let self, ticket == self.batch else { return }
                self.asking -= 1
                if answer?["needsReply"] as? Bool == true, let reply = (answer?["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty {
                    self.drafts.append(Draft(note: note, original: reply, text: reply))
                }
                if self.asking == 0, !self.drafts.isEmpty, self.app.docks.focusedDock?.mode?.id == mode.id {
                    self.app.popups.show(FocusCard(kind: .reply, target: mode))
                }
            }
        }
    }

    func edit(_ id: Int64, _ text: String) {
        if let index = drafts.firstIndex(where: { $0.id == id }) { drafts[index].text = text }
    }

    /// The reply on the clipboard and the chat in front; an edited reply is kept as the person's style.
    func use(_ draft: Draft) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draft.text, forType: .string)
        if draft.text != draft.original { Self.keep(draft.text) }
        app.assist.did("Drafted a reply to \(named: draft.note.title, else: "a message")")
        Notes.reveal(draft.note)
        drop(draft)
    }

    func drop(_ draft: Draft) {
        drafts.removeAll { $0.id == draft.id }
        if drafts.isEmpty, app.popups.card?.kind == .reply { app.popups.dismissCard() }
    }

    private static func style() -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(contentsOf: styleFile))) ?? []
    }

    private static func keep(_ reply: String) {
        let list = Array((style() + [reply]).suffix(6))
        try? FileManager.default.createDirectory(at: styleFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: styleFile, options: .atomic) }
    }
}

/// The drafted replies: each message, its draft to edit, Copy and open, or Skip.
struct ReplyCard: View {
    @Environment(PetalApp.self) private var app
    let card: FocusCard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(app.drafts.drafts.count == 1 ? "A reply, ready" : "\(app.drafts.drafts.count) replies, ready")
                    .font(.system(size: 13, weight: .bold))
                if let mode = card.target { Text("· \(mode.name)").font(.system(size: 13)).foregroundStyle(.secondary) }
                Spacer()
                RoundButton(symbol: "xmark") { app.popups.dismissCard() }
            }
            ForEach(app.drafts.drafts) { draft in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(nsImage: Apps.icon(Notes.appID(draft.note.app))).resizable().frame(width: 16, height: 16)
                        Text(draft.note.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    }
                    Text(draft.note.body).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    TextField("Reply", text: Binding(get: { draft.text }, set: { app.drafts.edit(draft.id, $0) }), axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...5)
                        .padding(8).background(.white.opacity(0.07), in: .rect(cornerRadius: 10))
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Skip") { app.drafts.drop(draft) }.buttonStyle(.glass).controlSize(.small)
                        Button("Copy and open") { app.drafts.use(draft) }.buttonStyle(.glassProminent).controlSize(.small)
                            .tint(Color(nsColor: app.accent))
                    }
                }
            }
        }
    }
}
