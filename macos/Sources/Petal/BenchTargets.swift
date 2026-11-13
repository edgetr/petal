import AppKit
import SwiftUI
import WebKit

/// The windows and panels `Petal --bench-windows` times besides Settings, each with made-up content: a long
/// conversation of markdown replies, 150 kept chats, 300 logins, a stack of 60 files, notes at work.
@MainActor
enum BenchTargets {
    static func all(app: PetalApp) -> [WindowBench.Target] {
        // The chat: empty, and a long conversation of markdown-heavy replies.
        let empty = ClaudePanel()
        let long = ClaudePanel()
        let conversation = Self.conversation(60)
        long.agent.preview(conversation)
        var replies = 0
        // The kept chats, as files in a temporary folder (Chats.folder while headless).
        writeChats(150)
        let chats = ClaudePanel()
        chats.chatsOpen = true

        // A stack of 60 files in a temporary folder.
        let stackFolder = SettingsBench.scratch.appending(path: "Stack")
        try? FileManager.default.createDirectory(at: stackFolder, withIntermediateDirectories: true)
        for n in 0..<60 {
            let ext = ["pdf", "png", "txt", "zip", "mov", "md"][n % 6]
            FileManager.default.createFile(atPath: stackFolder.appending(path: "File \(n).\(ext)").path, contents: Data("x".utf8))
        }
        let entries = Stacks.entries(stackFolder.path, limit: 40)

        // Notes at work, and an app's windows, for the hover previews.
        let picture = NSImage(size: NSSize(width: 240, height: 150), flipped: false) { rect in
            NSColor(white: 0.12, alpha: 1).setFill(); rect.fill()
            NSColor(red: 0.11, green: 0.73, blue: 0.33, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 56, height: rect.height).fill()
            return true
        }
        let ids = (0..<4).map { _ in UUID() }
        let notes = ids.enumerated().map { index, id in
            NotePreviewItem(id: id, app: ["com.apple.Safari", "com.apple.Terminal", "com.apple.mail", "com.apple.Notes"][index],
                            appName: ["Safari", "T3 Code", "Mail", "Notes"][index], title: "Note \(index): find the cheapest flight",
                            line: index == 2 ? "Done" : NoteStatus.step("Typing in “Ask anything”"), working: index != 2, needsYou: index == 0,
                            hidden: false, pid: 0, window: nil, attached: true)
        }
        let me = AXUIElementCreateApplication(getpid())
        let windows = ["Liked Songs", "Radiohead – OK Computer", "Discover Weekly", ""].enumerated().map { index, title in
            AppWindow(id: "bench-\(index)", pid: getpid(), title: title, minimized: index == 3, frame: .zero, element: me)
        }

        let notesText = Self.releaseNotes

        var login = VaultItem(kind: .login, title: "GitHub", sites: ["github.com"])
        login[.username] = "ada@example.com"
        login[.password] = "sample-password-1"

        let targets: [WindowBench.Target] = [
            // The floor: a panel with one line of text, nothing else. What the bench itself costs.
            .init(name: "Control (one line of text)", view: { AnyView(Text("Petal").padding(20)) }),
            .init(name: "Chat, empty", view: { AnyView(ClaudePanelView(panel: empty)) }, actions: [
                ("typing in the chat field (a key)", { empty.draft = empty.draft.count > 30 ? "" : empty.draft + "a" }),
            ]),
            .init(name: "Chat, 60 messages", view: { AnyView(ClaudePanelView(panel: long)) }, actions: [
                ("a reply arrives", {
                    replies += 1
                    long.agent.preview(conversation + Self.conversation(replies % 2 + 1))
                }),
                ("typing in the chat field (a key)", { long.draft = long.draft.count > 30 ? "" : long.draft + "a" }),
            ], reset: { long.agent.preview(conversation); long.draft = "" }),
            .init(name: "Chats list", view: { AnyView(ClaudePanelView(panel: chats)) }),
            .init(name: "Welcome", size: CGSize(width: 640, height: WelcomeView.height), view: { AnyView(WelcomeView {}) }),
            .init(name: "What's New", size: CGSize(width: 560, height: 600),
                  view: { AnyView(ReleaseNotesView(sections: notesText)) }),
            .init(name: "Vault editor", size: CGSize(width: 640, height: 520), view: { AnyView(VaultEditor(item: login, isNew: false) {}) }),
            .init(name: "Notes preview", view: {
                app.previews.preview(notes: notes, thumbnails: [ids[0]: picture, ids[1]: picture])
                return AnyView(PreviewView(id: Previews.notes) {})
            }, reset: { app.previews.preview(notes: nil) }),
            .init(name: "Window previews", view: {
                app.previews.preview(windows: windows, pictures: true, thumbnails: ["bench-0": picture, "bench-1": picture, "bench-2": picture])
                return AnyView(PreviewView(id: "com.spotify.client") {})
            }, reset: { app.previews.preview(windows: [], pictures: false) }),
            .init(name: "Stack", view: { AnyView(StackView(contents: StackContents(folder: stackFolder.path, entries: entries)) {}) }),
            .init(name: "\"+\" search", view: { AnyView(AppSearchView(search: app.search)) }, actions: [
                ("typing a search (a key)", {
                    let words = ["s", "sa", "saf", "safa", "", "m", "ma", "mai", ""]
                    let index = (words.firstIndex(of: app.search.query) ?? -1) + 1
                    app.search.query = words[index % words.count]
                }),
            ], reset: { app.search.query = "" }),
        ]
        return targets
    }

    /// Twelve releases' notes, newest first, for a long What's New.
    static let releaseNotes = (1...12).reversed().map { n in
        ReleaseNotes.Section(version: "1.\(n)", body: """
        Your dock holds **your notes** now, and a *note pad* to take a paper from.

        - Drag a paper off the note pad and let go anywhere
        - Keyboard shortcuts: ⌃⌥N for a new note
        - Magnification, and [a menu bar icon](https://github.com/edgetr/petal)

        ### Fixes
        * A note no longer covers the update notice
        * The vault fills addresses in Safari again
        """)
    }

    /// A conversation: a question, a few steps, and a markdown-heavy answer, `count` times.
    static func conversation(_ count: Int) -> [Agent.Message] {
        (0..<count).flatMap { n -> [Agent.Message] in
            [
                .init(kind: .user, text: "Can you compare these two plans and tell me which one fits a team of \(n + 3)?"),
                .init(kind: .step, text: "Looking at Safari"),
                .init(kind: .step, text: "Reading “Pricing – Linear”"),
                .init(kind: .claude, text: """
                    ## Plan \(n + 1)

                    For **\(n + 3) people**, *Standard* is the better fit: it has everything you use and costs less. Here's how they compare:

                    | Plan | Per person | Total |
                    |---|---|---|
                    | Standard | $8 | $\(8 * (n + 3)) |
                    | Plus | $14 | $\(14 * (n + 3)) |

                    - Unlimited issues and `cycles`
                    - Guest access on both
                    - [Their pricing page](https://linear.app/pricing) has the rest

                    > Plus only adds SAML and audit logs.

                    ```
                    standard = 8 * \(n + 3)
                    ```
                    """),
            ]
        }
    }

    /// Made-up logins for a big vault.
    static func logins(_ count: Int) -> [VaultItem] {
        (0..<count).map { n in
            var item = VaultItem(kind: .login, title: "Site \(n)", sites: ["site\(n).example.com"])
            item[.username] = "ada\(n)@example.com"
            item[.password] = "sample-password-\(n)"
            return item
        }
    }

    /// Made-up kept chats in Chats.folder (a temporary folder while headless).
    static func writeChats(_ count: Int) {
        try? FileManager.default.createDirectory(at: Chats.folder, withIntermediateDirectories: true)
        for n in 0..<count {
            let chat = SavedChat(id: UUID(), title: "Chat \(n): compare these two plans", provider: n % 3 == 0 ? "codex" : "claude", session: nil,
                                 updated: Date().addingTimeInterval(-Double(n) * 3600),
                                 lines: [.init(kind: "user", text: "Compare these plans"), .init(kind: "claude", text: "Standard fits.")],
                                 place: nil, pending: nil)
            if let data = try? JSONEncoder().encode(chat) { try? data.write(to: Chats.folder.appending(path: chat.id.uuidString + ".json")) }
        }
    }

    /// A page (petal_show) drawn by WebKit, from a long markdown text: the time to its loaded page, in its own window.
    static func page(runs: Int) -> WindowBench.Stat? {
        let text = (1...40).map { n in
            "## Section \(n)\n\nA paragraph with **bold** and `code` and a [link](https://example.com).\n\n| a | b |\n|---|---|\n| \(n) | \(n * 2) |\n\n- one\n- two\n"
        }.joined(separator: "\n")
        let file = SettingsBench.scratch.appending(path: "page.html")
        try? Pages.document(title: "A long page", body: Markdown.html(text)).write(to: file, atomically: true, encoding: .utf8)
        var samples: [WindowBench.Sample] = []
        for _ in 0..<runs {
            let window = PageWindow()
            let cpu = WindowBench.threadCPU()
            let start = WindowBench.now()
            window.load(file, title: "A long page", show: false)
            let until = Date().addingTimeInterval(10)
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            while window.web.isLoading && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
            let parts = WindowBench.frame(window)
            samples.append(.init(ms: WindowBench.ms(start, WindowBench.now()), update: parts.update, draw: parts.draw,
                                 cpu: WindowBench.threadCPU() - cpu, bodies: 0, settleCPU: 0))
            window.close()
        }
        return WindowBench.stat(samples)
    }
}
