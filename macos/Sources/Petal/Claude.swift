import AppKit
import Observation
import SwiftUI

/// The chat (Agent.qml): the person's own Claude Code or Codex, one process per turn, resumed across turns, with
/// Petal's tools (Petal itself, `Petal --mcp`). Steps the AI takes show as one-line steps. Claude's permission
/// denials become an "Allow" card that re-runs with per-part Bash(...) rules; Codex can't ask mid-turn, so its
/// sandbox (or Full access) decides.
@MainActor @Observable
final class Agent {
    enum Kind { case user, claude, step, ask, error }
    struct Message: Identifiable, Equatable {
        let id = UUID()
        let kind: Kind
        let text: String
        var opensSettings = false   // an error that Settings › AI fixes (a key or sign-in), with a button there
        init(kind: Kind, text: String, opensSettings: Bool = false) { self.kind = kind; self.text = text; self.opensSettings = opensSettings }
    }
    struct Denial: Equatable { let tool: String; let label: String; let rules: [String] }
    enum Event {
        case session(String), text(String), step(String), denials([Denial]), error(String), finished
        /// The API refused the key or sign-in; what a turn cost (Claude Code's figure), or Codex's tokens to price.
        case authFailed, cost(Double), tokens(input: Int, cached: Int, output: Int)
    }

    private(set) var messages: [Message] = []
    private(set) var running = false
    private(set) var pendingAsk: [Denial] = []
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var sessionProvider: Provider?
    @ObservationIgnored private var allowed: [String] = []
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var errorText = ""
    @ObservationIgnored private var authFailed = false   // this run's key or sign-in was refused, already said
    @ObservationIgnored private var runID = UUID()   // a stopped run's late lines don't belong to the next chat

    var app: PetalApp { PetalApp.shared }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !running else { return }
        pendingAsk = []
        messages.append(Message(kind: .user, text: prompt))
        run(prompt)
    }

    func allow() {
        guard !running, !pendingAsk.isEmpty else { return }
        for denial in pendingAsk { for rule in denial.rules where !allowed.contains(rule) { allowed.append(rule) } }
        pendingAsk = []
        messages.append(Message(kind: .step, text: "Allowed"))
        run("I approved that. Go ahead and run it, then continue.")
    }

    func deny() {
        pendingAsk = []
        messages.append(Message(kind: .step, text: "Not allowed"))
    }

    func stop() { process?.terminate() }

    /// Shows a made-up conversation, for `Petal --snapshot`.
    func preview(_ sample: [Message]) {
        messages = sample
        pendingAsk = [Denial(tool: "Bash", label: sample.last?.text ?? "", rules: [])]
    }

    func reset() {
        stop()
        runID = UUID()
        messages = []
        sessionID = nil
        allowed = []
        pendingAsk = []
    }

    private func run(_ prompt: String) {
        guard let provider = app.chatProvider else {
            messages.append(Message(kind: .error, text: "Choose an AI in Petal's settings first."))
            return
        }
        guard let path = app.paths[provider] else {
            messages.append(Message(kind: .error, text: "Petal couldn't find \(provider.appName). Set it up in Petal's settings, under AI."))
            return
        }
        // On an API key with none saved, say so rather than quietly using the subscription.
        guard app.aiReady(provider) else {
            messages.append(Message(kind: .error, text: "\(provider.name) is set to use an API key, and there isn't one yet. Add it in Settings › AI, or switch back to your subscription.", opensSettings: true))
            return
        }
        if sessionProvider != provider { sessionID = nil; allowed = []; sessionProvider = provider }
        let config = app.config
        var chat = Provider.Chat(model: config.string(provider.modelSetting), effort: config.string(provider.effortSetting),
                                 fullAccess: config.string("claudeAccess") == "full", instructions: instructions(provider),
                                 tools: Bundle.main.executablePath ?? "", session: sessionID, allowed: allowed)
        chat.api = app.usesAPIKey(provider)
        authFailed = false

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = provider.chatArguments(chat)
        process.environment = app.aiEnvironment(provider)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        errorText = ""

        let buffer = LineBuffer()
        let id = UUID()
        runID = id
        let deliver = { (lines: [String]) in
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.runID == id else { return }
                    for line in lines { for event in provider.events(line) { self.apply(event) } }
                }
            }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            deliver(buffer.lines(adding: chunk))
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.errorText += text } }
        }
        process.terminationHandler = { finished in
            // The last chunk (often the result, with any permission denials) may still be unread.
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            deliver(buffer.lines(adding: output.fileHandleForReading.readDataToEndOfFile() + Data("\n".utf8)))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.runID == id else { return }
                    self.running = false
                    self.process = nil
                    let status = finished.terminationStatus
                    let detail = self.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if status != 0 && status != 15 && !detail.isEmpty && !self.authFailed {
                        self.messages.append(Message(kind: .error, text: String(detail.suffix(300))))
                    }
                }
            }
        }
        do {
            try process.run()
            running = true
            self.process = process
            input.fileHandleForWriting.write(Data(prompt.utf8))
            try? input.fileHandleForWriting.close()
        } catch {
            messages.append(Message(kind: .error, text: "Couldn't start \(provider.appName): \(error.localizedDescription)"))
        }
    }

    private func apply(_ event: Event) {
        switch event {
        case .session(let id): sessionID = id
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { messages.append(Message(kind: .claude, text: trimmed)) }
        case .step(let text): messages.append(Message(kind: .step, text: text))
        case .denials(let denials):
            pendingAsk = denials
            messages.append(Message(kind: .ask, text: denials.map(\.label).joined(separator: "\n")))
        case .error(let text): messages.append(Message(kind: .error, text: text))
        case .finished: Task { await app.usage.refresh() }
        case .authFailed:
            guard !authFailed, let provider = sessionProvider else { return }
            authFailed = true
            stop()
            messages.append(Message(kind: .error, text: app.usesAPIKey(provider)
                ? "\(provider.keyMaker) didn't accept your API key. Check it in Settings › AI."
                : "\(provider.appName) isn't signed in anymore. Sign in again from Settings › AI.", opensSettings: true))
        case .cost(let dollars):
            if let provider = sessionProvider, app.usesAPIKey(provider) { app.usage.addSpend(dollars, for: provider) }
        case .tokens(let input, let cached, let output):
            guard let provider = sessionProvider, app.usesAPIKey(provider) else { return }
            let model = app.config.string(provider.modelSetting)
            app.usage.addSpend(APIPricing.codex(model: model.isEmpty ? (app.codexModels.first?.id ?? "") : model,
                                                input: input, cached: cached, output: output), for: provider)
        }
    }

    /// One rule per part of a shell command, so allowing `a && b` allows a and b, not anything else.
    nonisolated static func bashRules(_ command: String) -> [String] {
        var parts = [command]
        for separator in ["||", "&&", "|", ";", "\n"] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { "Bash(\($0))" }
    }

    nonisolated static func describe(_ name: String, _ input: [String: Any]) -> String {
        func home(_ path: Any?) -> String {
            let text = path as? String ?? ""
            return text.hasPrefix(NSHomeDirectory()) ? "~" + text.dropFirst(NSHomeDirectory().count) : text
        }
        switch name {
        case "Bash": return "Running  " + ((input["command"] as? String ?? "").components(separatedBy: "\n").first ?? "")
        case "Read": return "Reading  " + home(input["file_path"])
        case "Edit", "MultiEdit": return "Editing  " + home(input["file_path"])
        case "Write": return "Writing  " + home(input["file_path"])
        case "Glob", "Grep": return "Searching  " + (input["pattern"] as? String ?? "")
        case "WebSearch": return "Searching the web  " + (input["query"] as? String ?? "")
        case "WebFetch": return "Reading  " + (input["url"] as? String ?? "")
        case "TodoWrite": return "Planning"
        case "mcp__petal__petal_get_state": return "Looking at your dock"
        case "mcp__petal__petal_set_settings":
            return "Changing  " + ((input["settings"] as? [String: Any])?.keys.sorted().joined(separator: ", ") ?? "")
        case "mcp__petal__petal_reset_settings": return "Resetting settings"
        case "mcp__petal__petal_set_dock": return "Moving the dock"
        case "mcp__petal__petal_save_mode":
            let mode = input["mode"] as? [String: Any] ?? [:]
            return "Saving mode  " + (mode["name"] as? String ?? mode["id"] as? String ?? "")
        case "mcp__petal__petal_delete_mode": return "Deleting mode  " + (input["id"] as? String ?? "")
        case "mcp__petal__petal_list_apps": return "Looking up apps"
        case "mcp__petal__petal_switch_mode": return "Switching to  " + (input["id"] as? String ?? "")
        case "mcp__petal__petal_reload": return "Reloading Petal"
        case "mcp__petal__petal_look": return (input["screenshot"] as? String ?? "").isEmpty ? "Looking at what's in front" : "Looking at your screen"
        case "mcp__petal__petal_apps": return ((input["action"] as? String ?? "open").capitalized) + "  " + (input["app"] as? String ?? input["open"] as? String ?? "")
        case "mcp__petal__petal_windows": return (input["action"] as? String ?? "list") == "list" ? "Looking at your windows" : "Arranging windows"
        case "mcp__petal__petal_trash": return input["undo"] as? Bool == true ? "Putting files back" : "Moving to the Trash"
        case "mcp__petal__petal_remember": return "Remembering  " + (input["text"] as? String ?? "")
        case "mcp__petal__petal_forget": return "Forgetting"
        case "mcp__petal__petal_vault": return (input["action"] as? String) == "use" ? "Typing your “\(input["name"] as? String ?? "")”" : "Looking in your vault"
        case "mcp__petal__petal_memories": return "Looking at what I remember"
        case "mcp__petal__petal_show": return "Making a page  " + (input["title"] as? String ?? "")
        case "mcp__petal__petal_routines": return "Looking at your routines"
        case "mcp__petal__petal_routine_save": return "Saving routine  " + (input["name"] as? String ?? input["words"] as? String ?? "")
        case "mcp__petal__petal_routine_run": return input["dryRun"] as? Bool == true ? "Seeing what the routine would do" : "Running the routine"
        case "mcp__petal__petal_routine_undo": return "Putting files back"
        case "mcp__petal__petal_routine_delete": return "Deleting a routine"
        case "mcp__petal__petal_summary": return "Looking at your \((input["days"] as? Int).map { "last \($0) days" } ?? "week")"
        default: return name
        }
    }

    private func instructions(_ provider: Provider) -> String {
        var prompt = """
        You are \(provider.name), running inside Petal, the user's dock on macOS. Your replies show in a small panel above the dock: be brief and friendly, short paragraphs, no big headings. You work in the user's home folder.

        Everything about the dock is customizable through you. Use the petal MCP tools: call petal_get_state first, then petal_set_settings (appearance: dockColor, iconSize, accentColor, …; feature switches: bounce, badges, previews, …), petal_set_dock (position, auto-hide), petal_save_mode / petal_delete_mode (focus modes and their apps; apps are bundle identifiers, get them from petal_list_apps; mode icons are SF Symbol names), petal_switch_mode (puts the current Desktop in a mode), petal_export_recipe / petal_import_recipe (share a dock as a .petal file, or add one someone shared), petal_suggestions and petal_summary (from the user's private activity history). A mode's shortcut field names a Shortcut (Shortcuts app) that runs when a Desktop enters the mode, such as one that turns on a Focus; the schedule setting switches modes by the clock. Every Desktop has its own mode. Changes apply instantly. If a request can't be done with settings or modes, you may change Petal's own code, and the change is kept through updates: run `\(Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? "petal") personal init` (once; it prints where Petal's source is), edit the Swift there, then `… personal save "<what changed, in a few words>"`, which builds, installs and restarts Petal (`… personal undo` takes the last change back). Never copy anything over Petal.app yourself, and never edit the app's files. You can also help with anything else on the Mac: apps, files, macOS settings (defaults, AppleScript, the shell). If something needs the user's approval, say in one line what it would do; they can allow it from the panel. If something about Petal itself is broken, run `\(Bundle.main.executablePath ?? "Petal") doctor` (and `… doctor --fix`); the petal skill says more.

        You're also the user's helper on this Mac, through Petal's tools (Petal holds the Mac's permissions; you don't need any). petal_look shows what they're looking at: the app and window in front, a browser tab's address and title, selected text, and a screenshot when seeing helps (read the PNG path it returns). When they say this, here, or what I'm looking at, look first. A tab's address is there to research from (search the web for similar things, read the page). petal_apps and petal_windows open, quit, bring forward, minimize, close and arrange apps and windows. petal_trash moves files to the Trash: never delete files any other way (no rm). Petal asks the user before quitting, closing or trashing; if they decline, say OK and don't find another way. Files the user hands you arrive as paths: read them (PDFs too) and do what they ask; save an edited copy next to the original with a new name unless they say to replace it.

        Routines: when the user wants something to happen by itself from now on ("keep my Downloads tidy", "when a PDF lands in Downloads, file it under Receipts", "when I open Figma, switch to Design", "every evening tidy my Desktop"), make a routine with petal_routine_save: their own words, plus the trigger and actions you work out from them (Petal runs it with no AI except sorting files by what they are). It acts on new files only; when it says files are there already, show them what it would do with petal_routine_run (dryRun: true) in a line or two, and do it with petal_routine_run if they want. Routines only move files into folders, never delete; petal_routine_undo puts the last ones back, and Settings, Routines lists them all.

        Memory: below is what you remember about this user. When you learn something lasting that will help later (a preference, a habit, how they like things done, what a mode is for), save it yourself with petal_remember (learned: true; with the mode's id when it's about one mode) and say so in a word or two. When they say remember or forget something, do it with petal_remember or petal_forget. Forget what turns out wrong or out of date. Never keep passwords, secrets, or anything private they wouldn't want kept.

        Passwords and other secrets live in Petal's vault (petal_vault): list their names, use one (Petal types it into the field that has the cursor, after asking the user; you never see it), or request one you need (the user types it into Petal's card, never into the chat). Never ask the user to paste a password or key into the chat. Some apps the user keeps private: petal_look shows only their name.

        Replies show as markdown (headings, lists, tables, code). For anything longer than a few lines (a summary of their last month, a report, a comparison, a chart), make a page with petal_show: markdown, or a whole HTML page with inline SVG for charts (no outside scripts or images); it opens in Petal's own window and is kept. Never open files in other apps to show results (no `open` on a .md or .html file). Then say in one line what's on it. petal_summary covers up to their last 30 days of activity (days: 30 for a month), with time per mode and app and a day-by-day breakdown for charts.

        When the user says something in Petal is broken or odd, fix it for them without asking them to type anything: run `\(Bundle.main.executablePath ?? "Petal") doctor` and `… logs`, check petal_get_state, fix what settings can, and change Petal's code with personal (above) when it takes that. Then tell them in plain words what was wrong and what you did.
        """
        let notes = (try? String(contentsOf: app.config.instructionsFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !notes.isEmpty { prompt += "\n\nThe user's own instructions:\n" + notes }
        let remembered = app.assist.memoryBrief
        if !remembered.isEmpty { prompt += "\n\nWhat you remember about this user ([id] for petal_forget):\n" + remembered }
        return prompt
    }

}

/// Collects a process's output and hands back whole lines (the pipe's reader and the exit handler both feed it).
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func lines(adding chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let newline = data.firstIndex(of: 0x0A) {
            lines.append(String(decoding: data[data.startIndex..<newline], as: UTF8.self))
            data.removeSubrange(data.startIndex...newline)
        }
        return lines
    }

    /// The text after the last newline, taken out.
    func rest() -> String {
        lock.lock()
        defer { lock.unlock() }
        let text = String(decoding: data, as: UTF8.self)
        data.removeAll()
        return text
    }
}

// MARK: - The panel

/// A glass panel that takes typing without taking focus from the app in front, and closes when you click elsewhere.
@MainActor
final class InputPanel: NSPanel {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    var onClose: () -> Void = {}

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Its size is Petal's to set (fit), never the window following its content from the wrong corner: only
        // its own size for measuring, no minimum or maximum the window would follow.
        hosting.sizingOptions = [.intrinsicContentSize]
        contentView = hosting
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override func close() {
        super.close()
        onClose()
    }

    /// Centered on the screen with the pointer, just above the dock: it comes out of the dock rather than floating
    /// over it.
    func show<Content: View>(_ content: Content) {
        load(content)
        showAgain()
    }

    /// Makes and lays out the view without showing it, so the first opening is as quick as the rest.
    func load<Content: View>(_ content: Content) {
        hosting.rootView = AnyView(content.environment(PetalApp.shared))
        hosting.layoutSubtreeIfNeeded()
    }

    /// Shows what it showed last, placed again over the dock.
    func showAgain() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        // The content's own 10-point margin around the glass, then 6 points of space over the dock.
        let above = Self.dockReach(on: screen) + 6 - 10
        setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + above, width: size.width, height: size.height).integral,
                 display: true)
        makeKeyAndOrderFront(nil)
    }

    /// How far the dock reaches up from the screen's bottom: Petal's (gap, its 2-point margin, the glass's 4-point
    /// padding around a slot), or macOS's when that one is showing. 0 for a side dock.
    static func dockReach(on screen: NSScreen) -> CGFloat {
        let config = PetalApp.shared.config
        if config.whichDock == "macos" { return max(0, screen.visibleFrame.minY - screen.frame.minY) }
        guard config.position != "left", config.position != "right" else { return 0 }
        if let reach = PetalApp.shared.docks.reach(on: screen) { return reach }
        let gap = config.number("dockMargin") >= 0 ? config.number("dockMargin") : 4
        let icon = max(16, config.number("iconSize"))
        let inset = config.number("iconPadding") >= 0 ? config.number("iconPadding") : 5
        return gap + 2 + 4 + icon + inset * 2 + 4
    }

    /// Grows upward as the conversation does, keeping its bottom edge.
    func fit() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let screen = self.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let bottom = screen.frame.minY + Self.dockReach(on: screen) + 6 - 10
        let target = NSRect(x: frame.midX - size.width / 2, y: bottom, width: size.width, height: size.height).integral
        guard target != frame else { return }
        setFrame(target, display: true, animate: false)
    }
}

/// The Claude panel (AskBox.qml).
@MainActor @Observable
final class ClaudePanel {
    let agent = Agent()
    var draft = ""
    var optionsOpen = false
    /// Files handed to the AI (dropped on its button or on the panel): sent with the next message.
    var attachments: [URL] = []
    /// Passages quoted from any app (Ask Petal AI / Add to Petal AI): sent with the next message.
    struct Quote: Identifiable, Equatable { let id = UUID(); let text: String; let source: String }
    var quotes: [Quote] = []

    func quote(_ text: String, from source: String) {
        guard !quotes.contains(where: { $0.text == text }) else { return }
        quotes.append(Quote(text: text, source: source))
        if isOpen { fit() }
    }

    /// Added without opening the chat: the AI button says so for a moment.
    func noteAdded() {
        let app = PetalApp.shared
        guard let dock = app.docks.focusedDock else { return }
        app.tooltips.show(quotes.count == 1 ? "Added to Petal AI" : "\(quotes.count) passages for Petal AI", over: "claude", in: dock)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { app.tooltips.show(nil, over: "claude", in: dock) }
    }
    private(set) var isOpen = false
    @ObservationIgnored private var panel: InputPanel?

    func open(asking text: String?, send: Bool = true, attaching files: [URL] = []) {
        let app = PetalApp.shared
        for file in files where !attachments.contains(file) { attachments.append(file) }
        Task { await app.usage.refresh() }
        // Codex's models, if they couldn't be read at launch (Codex installed or signed in since).
        if app.chatProvider == .codex && app.codexModels.isEmpty { app.loadCodexModels() }
        if panel == nil {
            let panel = InputPanel()
            panel.onClose = { [weak self] in
                self?.isOpen = false
                self?.optionsOpen = false
                // A question still waiting goes to the dock, where it can be answered.
                if PetalApp.shared.assist.pending != nil { PetalApp.shared.popups.show(FocusCard(kind: .ask)) }
            }
            self.panel = panel
        }
        isOpen = true
        if let text, send {
            agent.send(text)
            draft = ""
        } else {
            draft = text ?? ""
        }
        app.tooltips.hide()
        app.popups.closeAll()
        panel?.show(ClaudePanelView(panel: self))
    }

    func openOptions() {
        open(asking: nil)
        optionsOpen = true
    }

    func close() { panel?.close() }

    func fit() { panel?.fit() }
}

struct ClaudePanelView: View {
    @Environment(PetalApp.self) private var app
    let panel: ClaudePanel
    @FocusState private var focused: Bool

    var agent: Agent { panel.agent }

    static let suggestions = ["Explain what I'm looking at", "Tidy up my Downloads", "Something in Petal isn't working right"]
    /// With files handed over: what people most often want done with them.
    static let fileSuggestions = ["Summarize it", "What are the key points?", "Make it shorter and clearer"]
    /// With a passage quoted from another app.
    static let quoteSuggestions = ["Explain this", "Rewrite it more clearly", "Find more on this"]

    var body: some View {
        @Bindable var panel = panel
        // The bottom (and the text box) never moves. The suggestions and the options share one minimum height, so
        // switching between them moves nothing; a conversation grows the panel upward only once it needs more room,
        // up to half the screen, then scrolls. The options open over what's below the header.
        VStack(alignment: .leading, spacing: 14) {
            header
            ZStack(alignment: .top) {
                Group { if agent.messages.isEmpty { empty } else { conversation } }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .opacity(panel.optionsOpen ? 0 : 1)
                if panel.optionsOpen { options.transition(.opacity.combined(with: .offset(y: -6))) }
            }
            .frame(minHeight: 180, alignment: .top)
            if let request = app.assist.pending {
                AskRequestView(request: request).padding(12).background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
            }
            if !panel.attachments.isEmpty || !panel.quotes.isEmpty { attachmentsRow }
            input
        }
        // Exactly this wide whatever it shows: content a little too wide for it (Claude's rows and Codex's differ)
        // stays put on the left instead of spilling out on both sides, which made switching jump sideways.
        .frame(width: 524, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(10)
        .onAppear { focused = true }
        .onChange(of: agent.messages.count) { _, _ in DispatchQueue.main.async { panel.fit() } }
        .onChange(of: agent.running) { _, _ in DispatchQueue.main.async { panel.fit() } }
        .onChange(of: panel.optionsOpen) { _, _ in DispatchQueue.main.async { panel.fit() } }
        .onChange(of: panel.attachments.count) { _, _ in DispatchQueue.main.async { panel.fit() } }
        .onChange(of: panel.quotes.count) { _, _ in DispatchQueue.main.async { panel.fit() } }
        .onChange(of: app.assist.pending?.id) { _, _ in DispatchQueue.main.async { panel.fit() } }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls where url.isFileURL && !panel.attachments.contains(url) { panel.attachments.append(url) }
            return !urls.isEmpty
        }
        .onExitCommand {
            if panel.optionsOpen { panel.optionsOpen = false } else { panel.close() }
        }
        .animation(.easeOut(duration: 0.16), value: panel.optionsOpen)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ProviderMark(provider: app.chatProvider).frame(width: 20, height: 20)
                .rotationEffect(.degrees(agent.running ? 360 : 0))
                .animation(agent.running ? .linear(duration: 2.4).repeatForever(autoreverses: false) : .default, value: agent.running)
            Text(provider?.name ?? "AI").font(.system(size: 15, weight: .semibold))
            if let worst = app.usage.worst {
                Text("\(Int(((1 - worst.percent) * 100).rounded()))% left" + (worst.resetsAt.map { " · resets in " + PetalApp.until($0) } ?? ""))
                    .font(.system(size: 12))
                    .foregroundStyle(worst.percent >= 0.9 ? Color(red: 1, green: 0.42, blue: 0.54) : .secondary)
            } else if let spent = app.usage.spentText {
                Text(spent).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            // The model and effort, on clear glass as × is; the chevron turns up while the options are open.
            Button {
                panel.optionsOpen.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text("\(modelName) · \(provider.map { app.config.string($0.effortSetting) } ?? "")").font(.system(size: 12))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(panel.optionsOpen ? 180 : 0))
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 10).padding(.trailing, 9)
                .frame(height: 22)
                .glassEffect(.clear.interactive(), in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            if !agent.messages.isEmpty {
                Button("New chat") { agent.reset() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            RoundButton(symbol: "xmark", size: 22) { panel.close() }
        }
        .frame(height: 28)
    }

    private var provider: Provider? { app.chatProvider }

    private var modelName: String {
        guard let provider else { return "" }
        let model = app.currentModel(for: provider)
        return app.models(for: provider).first { $0.0 == model }?.1 ?? (model.isEmpty ? "Default" : model)
    }

    @ViewBuilder private var options: some View {
        if let provider {
        VStack(alignment: .leading, spacing: 10) {
            if app.providers.count > 1 {
                OptionRow(title: "Chat with") {
                    Picker("", selection: Binding(get: { provider.rawValue }, set: {
                        app.config.set("chatProvider", $0)
                        agent.reset()
                        Task { await app.usage.refresh() }
                    })) {
                        ForEach(app.providers) { Text($0.name).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().frame(maxWidth: .infinity)
                }
            }
            if app.models(for: provider).count > 1 {
                OptionRow(title: "Model") {
                    // Claude's four names, or Codex's newest of each family ("6.1 Sol"): side by side either way.
                    Picker("", selection: Binding(get: { app.currentModel(for: provider) }, set: { app.config.set(provider.modelSetting, $0) })) {
                        ForEach(app.models(for: provider), id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().segments(app.models(for: provider).count)
                }
            }
            OptionRow(title: "Effort") {
                Picker("", selection: Binding(get: { app.config.string(provider.effortSetting) }, set: { app.config.set(provider.effortSetting, $0) })) {
                    ForEach(app.efforts(for: provider), id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().segments(app.efforts(for: provider).count)
            }
            OptionRow(title: "Full access") {
                let full = app.config.string("claudeAccess") == "full"
                HStack {
                    Text(full ? "Skips every permission check" : "Off: safe actions run on their own")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("", isOn: Binding(get: { full }, set: { app.config.set("claudeAccess", $0 ? "full" : "auto") }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 14))
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(!panel.quotes.isEmpty ? "What should \(provider?.name ?? "it") do with \(panel.quotes.count == 1 ? "this passage" : "these passages")?"
                 : panel.attachments.isEmpty ? "Ask anything. \(provider?.name ?? "It") sees what you're looking at, and can work with your apps, windows, files and dock. Drop a file here to hand it over."
                 : "What should \(provider?.name ?? "it") do with \(panel.attachments.count == 1 ? "it" : "them")?")
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.bottom, 6).fixedSize(horizontal: false, vertical: true)
            ForEach(!panel.quotes.isEmpty ? Self.quoteSuggestions : panel.attachments.isEmpty ? Self.suggestions : Self.fileSuggestions, id: \.self) { suggestion in
                SuggestionRow(text: suggestion) { panel.draft = suggestion; submit() }
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(agent.messages) { message in
                        MessageView(message: message, last: message.id == agent.messages.last?.id).id(message.id)
                    }
                    if agent.running { TypingDots().id("typing") }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: (NSScreen.main?.frame.height ?? 900) * 0.5)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: agent.messages.count) { _, _ in
                withAnimation {
                    if agent.running { proxy.scrollTo("typing", anchor: .bottom) } else if let last = agent.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private var input: some View {
        @Bindable var panel = panel
        return HStack(spacing: 8) {
            TextField(agent.messages.isEmpty ? "Ask \(provider?.name ?? "AI")…" : "Reply…", text: $panel.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit(submit)
            Button {
                if agent.running { agent.stop() } else { submit() }
            } label: {
                Image(systemName: agent.running ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color(nsColor: app.accent), in: .circle)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 42)
        .background(.white.opacity(0.06), in: .capsule)
        .overlay(Capsule().strokeBorder(focused ? Color(nsColor: app.accent).opacity(0.6) : .white.opacity(0.1)))
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(panel.quotes) { quote in
                    HStack(spacing: 6) {
                        Image(systemName: "text.quote").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("“" + quote.text.replacingOccurrences(of: "\n", with: " ").prefix(48) + (quote.text.count > 48 ? "…”" : "”"))
                            .font(.system(size: 12)).lineLimit(1)
                        if !quote.source.isEmpty { Text(quote.source).font(.system(size: 11)).foregroundStyle(.secondary) }
                        Button { panel.quotes.removeAll { $0 == quote } } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .glassEffect(.clear, in: .capsule)
                    .help(quote.text)
                }
                ForEach(panel.attachments, id: \.self) { url in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                        Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Button { panel.attachments.removeAll { $0 == url } } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .glassEffect(.clear, in: .capsule)
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func submit() {
        guard !agent.running else { return }
        var text = panel.draft
        if !panel.quotes.isEmpty {
            if text.trimmingCharacters(in: .whitespaces).isEmpty { text = "What about this?" }
            let quoted = panel.quotes.map { q in
                (q.source.isEmpty ? "" : "From \(q.source):\n") + q.text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            }
            text = quoted.joined(separator: "\n\n") + "\n\n" + text
            panel.quotes = []
        }
        if !panel.attachments.isEmpty {
            if text.trimmingCharacters(in: .whitespaces).isEmpty { text = "What's in \(panel.attachments.count == 1 ? "this file" : "these files")?" }
            text += "\n\nFiles I'm handing you:\n" + panel.attachments.map(\.path).joined(separator: "\n")
            panel.attachments = []
        }
        panel.draft = ""
        agent.send(text)
    }
}

extension View {
    /// A segmented picker as wide as its segments, each the same width whoever's choices they are: Claude's five
    /// efforts and Codex's six look alike, rather than stretching to the row's end.
    func segments(_ count: Int) -> some View { frame(width: CGFloat(count) * 66).frame(maxWidth: .infinity) }
}

struct OptionRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SuggestionRow: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(text).font(.system(size: 13))
                Spacer()
                Text("↗").opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(hovering ? .white.opacity(0.06) : .clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MessageView: View {
    @Environment(PetalApp.self) private var app
    let message: Agent.Message
    let last: Bool

    var body: some View {
        let accent = Color(nsColor: app.accent)
        switch message.kind {
        case .user:
            HStack {
                Spacer(minLength: 100)
                Text(message.text).font(.system(size: 13.5)).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(accent.opacity(0.22), in: .rect(cornerRadius: 14))
            }
        case .claude:
            MarkdownView(text: message.text).textSelection(.enabled)
        case .step:
            Text("›  " + message.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        case .error:
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text).font(.system(size: 13.5)).foregroundStyle(Color(red: 1, green: 0.42, blue: 0.54)).textSelection(.enabled)
                if message.opensSettings {
                    Button("Open Settings › AI") { app.settings.show(.claude) }.buttonStyle(.glass)
                }
            }
        case .ask:
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude wants to").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(message.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                if last && !app.claude.agent.pendingAsk.isEmpty {
                    HStack {
                        Button("Allow") { app.claude.agent.allow() }.buttonStyle(.glassProminent).tint(accent)
                        Button("Don't allow") { app.claude.agent.deny() }.buttonStyle(.glass)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.45)))
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(Color(nsColor: PetalApp.shared.accent)).frame(width: 6, height: 6)
                        .opacity(0.25 + 0.75 * (sin((t - Double(i) * 0.16) * .pi / 0.42) + 1) / 2)
                }
            }
        }
    }
}

// MARK: - "+": add apps and folders

@MainActor @Observable
final class AppSearch {
    var query = ""
    var selection = 0
    private(set) var mode: Mode?
    /// Counts openings, so the reused view puts the cursor back in its field.
    private(set) var opens = 0
    @ObservationIgnored private var panel: InputPanel?

    /// At launch: the panel and its view made ahead, hidden.
    func prepare() {
        guard panel == nil else { return }
        let panel = InputPanel()
        self.panel = panel
        panel.load(AppSearchView(search: self))
    }

    func open(in dock: ScreenDock?) {
        let app = PetalApp.shared
        mode = (dock ?? app.docks.focusedDock)?.mode
        query = ""
        selection = 0
        opens += 1
        app.tooltips.hide()
        // The view is made once; opening again only shows it, reset to an empty query.
        if let panel { panel.showAgain() } else {
            let panel = InputPanel()
            self.panel = panel
            panel.show(AppSearchView(search: self))
        }
    }

    func close() { panel?.close() }

    /// For `Bench`: the panel, to time how long it takes to draw.
    var window: NSWindow? { panel }

    struct Result: Identifiable, Hashable {
        let id: String
        let name: String
        let isFolder: Bool
        let path: String
    }

    /// Results for the current query, worked out once per query rather than on every hover.
    var cachedResults: [Result] {
        if cache.query != query || cache.mode != mode?.apps {
            cache = (query, mode?.apps, results)
        }
        return cache.results
    }
    @ObservationIgnored private var cache: (query: String, mode: [String]?, results: [Result]) = ("\u{0}", nil, [])

    var results: [Result] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var list: [Result] = []
        let typedPath = q.hasPrefix("/") || q.hasPrefix("~")
        // A web address typed or pasted: a website shortcut.
        if let address = Sites.address(q) {
            list.append(Result(id: address, name: Sites.domain(address) ?? address, isFolder: false, path: ""))
        }
        if !typedPath {
            list += Apps.search(q).prefix(60).map { Result(id: $0.id, name: $0.name, isFolder: false, path: "") }
        }
        if !q.isEmpty {
            let expanded = (q as NSString).expandingTildeInPath
            let base = typedPath ? (expanded.hasSuffix("/") ? expanded : (expanded as NSString).deletingLastPathComponent) : NSHomeDirectory()
            let prefix = typedPath ? (expanded.hasSuffix("/") ? "" : (expanded as NSString).lastPathComponent) : q
            let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
            let folders = names.filter { !$0.hasPrefix(".") && $0.lowercased().hasPrefix(prefix.lowercased()) }
                .filter { var isDir: ObjCBool = false; return FileManager.default.fileExists(atPath: base + "/" + $0, isDirectory: &isDir) && isDir.boolValue }
                .sorted().prefix(20)
            let home = NSHomeDirectory()
            list += folders.map { name in
                let full = (base as NSString).appendingPathComponent(name)
                let short = full.hasPrefix(home) ? "~" + full.dropFirst(home.count) : full
                return Result(id: "folder:" + short, name: short, isFolder: true, path: short)
            }
        }
        return list
    }

    func added(_ result: Result) -> Bool {
        result.isFolder ? PetalApp.shared.config.strings("stackFolders").contains(result.path) : (mode?.apps.contains(result.id) ?? false)
    }

    func toggle(_ result: Result) {
        let config = PetalApp.shared.config
        if result.isFolder {
            var folders = config.strings("stackFolders")
            if folders.contains(result.path) { folders.removeAll { $0 == result.path } } else { folders.append(result.path) }
            config.set("stackFolders", folders)
        } else if let mode {
            if mode.apps.contains(result.id) { config.removeApp(result.id, from: mode.id) } else { config.addApp(result.id, to: mode.id) }
            self.mode = config.modes.first { $0.id == mode.id }
        }
    }
}

struct AppSearchView: View {
    @Environment(PetalApp.self) private var app
    let search: AppSearch
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var search = search
        let results = search.cachedResults
        let accent = Color(nsColor: app.accent)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(search.mode.map { "Add to \($0.name)" } ?? "Add to the dock").font(.system(size: 17, weight: .bold)).foregroundStyle(accent)
                Spacer()
                RoundButton(symbol: "xmark") { search.close() }
            }
            TextField(search.mode.map { "Add an app, folder or website to \($0.name)…" } ?? "Add an app, folder or website…", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(.white.opacity(0.06), in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? accent : .white.opacity(0.12)))
                .onSubmit { if results.indices.contains(search.selection) { search.toggle(results[search.selection]) } }
                .onKeyPress(.downArrow) { search.selection = min(search.selection + 1, max(0, results.count - 1)); return .handled }
                .onKeyPress(.upArrow) { search.selection = max(search.selection - 1, 0); return .handled }
                .onChange(of: search.query) { _, _ in search.selection = 0 }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if results.isEmpty { Text("Nothing matches").foregroundStyle(.secondary).padding(.vertical, 20) }
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            SearchRow(result: result, selected: index == search.selection, added: search.added(result)) {
                                search.selection = index
                                search.toggle(result)
                            }
                            .id(index)
                            .onHover { if $0 { search.selection = index } }
                        }
                    }
                }
                .frame(height: 8 * 42)
                .scrollIndicators(.never)
                .onChange(of: search.selection) { _, new in proxy.scrollTo(new) }
            }
        }
        .padding(18)
        .frame(width: 440)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(10)
        .onAppear { focused = true }
        .onChange(of: search.opens) { _, _ in focused = true }
        .onExitCommand { search.close() }
    }
}

struct SearchRow: View {
    let result: AppSearch.Result
    let selected: Bool
    let added: Bool
    let toggle: () -> Void

    var body: some View {
        let accent = Color(nsColor: PetalApp.shared.accent)
        Button(action: toggle) {
            HStack(spacing: 10) {
                if Sites.isWeb(result.id) {
                    SiteIcon(id: result.id, size: 28)
                } else {
                    Image(nsImage: result.isFolder ? NSWorkspace.shared.icon(forFile: (result.path as NSString).expandingTildeInPath) : Apps.icon(result.id))
                        .resizable().frame(width: 28, height: 28)
                }
                Text(result.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(result.isFolder ? (added ? "Stack ✓" : "+ Stack") : (added ? "In dock ✓" : "+ Add"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(added ? accent : .secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(selected ? accent.opacity(0.22) : .clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
