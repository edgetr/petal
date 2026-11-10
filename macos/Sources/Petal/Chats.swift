import AppKit
import SwiftUI

/// Every chat with Petal AI, kept so it can be read again and carried on (Claude Code and Codex resume their own
/// sessions): one file each in ~/Library/Application Support/Petal/chats, the last 200.
struct SavedChat: Codable, Identifiable, Equatable {
    struct Line: Codable, Equatable { let kind: String; let text: String }
    let id: UUID
    var title: String
    var provider: String
    var session: String?
    var updated: Date
    var lines: [Line]
    /// The window a sticky note was stuck to (nil for a chat stuck to none, and chats from before notes).
    var place: NotePlace?
    /// Messages written but not sent yet when it was kept (Petal quit while it worked): shown as still to send.
    var pending: [String]?
}

@MainActor
enum Chats {
    /// A headless run (a bench, a snapshot) keeps its chats in a temporary folder, never the person's.
    static let folder = Headless.on ? SettingsBench.scratch.appending(path: "chats")
        : Config.supportFolder.appending(path: "chats")

    /// One at a time, in order: an older save can never land after a newer one.
    nonisolated static let queue = DispatchQueue(label: "petal.chats", qos: .utility)

    static func save(_ chat: SavedChat) {
        queue.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(chat) { try? data.write(to: folder.appending(path: chat.id.uuidString + ".json"), options: .atomic) }
        }
    }

    /// Newest first, without their messages' weight on the main thread: read in the background.
    static func list(_ done: @escaping @MainActor ([SavedChat]) -> Void) {
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let chats = files.filter { $0.pathExtension == "json" }
                .compactMap { try? JSONDecoder().decode(SavedChat.self, from: Data(contentsOf: $0)) }
                .sorted { $0.updated > $1.updated }
            for old in chats.dropFirst(200) { try? FileManager.default.removeItem(at: folder.appending(path: old.id.uuidString + ".json")) }
            let kept = Array(chats.prefix(200))
            DispatchQueue.main.async { MainActor.assumeIsolated { done(kept) } }
        }
    }

    static func delete(_ chat: SavedChat) { delete(id: chat.id) }

    static func delete(id: UUID) {
        let file = folder.appending(path: id.uuidString + ".json")
        queue.async { try? FileManager.default.removeItem(at: file) }
    }

    /// Every save still under way (on quit).
    nonisolated static func flush() { queue.sync {} }
}

/// The chats list, in place of the conversation: each with its first words, its AI and when; one picked comes back.
struct ChatsList: View {
    @Environment(PetalApp.self) private var app
    let panel: ClaudePanel
    @State private var chats: [SavedChat] = []
    @State private var query = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: TextSize.small)).foregroundStyle(.secondary)
                TextField("Search your chats", text: $query).textFieldStyle(.plain).font(.system(size: TextSize.body))
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(.white.opacity(0.06), in: .capsule)
            let shown = chats.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                || $0.lines.contains { $0.text.localizedCaseInsensitiveContains(query) } }
            if loaded && shown.isEmpty {
                Text(chats.isEmpty ? "No chats yet. Every chat is kept here." : "No chat has that.")
                    .font(.system(size: TextSize.callout)).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(shown) { chat in
                        ChatRow(chat: chat, current: chat.id == app.claude.agent.chatID) {
                            panel.chatsOpen = false
                            app.claude.restore(chat)
                        } delete: {
                            app.claude.forget(chat)
                            Chats.delete(chat)
                            chats.removeAll { $0.id == chat.id }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 260)
        }
        .padding(12)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: Radius.card))
        .onAppear { Chats.list { chats = $0; loaded = true } }
    }
}

private struct ChatRow: View {
    let chat: SavedChat
    let current: Bool
    let open: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ProviderMark(provider: Provider(rawValue: chat.provider)).frame(width: 14, height: 14).opacity(0.8)
            Text(chat.title).font(.system(size: TextSize.body, weight: current ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 8)
            // A note: the app it was stuck to.
            if let place = chat.place, !place.app.isEmpty {
                AppIconView(id: place.app, size: 14).help(place.appName)
            }
            Text(chat.updated, format: .relative(presentation: .named)).font(.system(size: TextSize.small)).foregroundStyle(.secondary)
            if hovering { RoundButton(symbol: "trash", size: 20, action: delete) }
        }
        .padding(.horizontal, 8).frame(height: 30)
        .background(hovering ? .white.opacity(0.07) : .clear, in: .rect(cornerRadius: Radius.control))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
    }
}
