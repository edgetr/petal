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
        init(kind: Kind, text: String) { self.kind = kind; self.text = text }
    }
    struct Denial: Equatable { let tool: String; let label: String; let rules: [String] }
    enum Event { case session(String), text(String), step(String), denials([Denial]), error(String), finished }

    private(set) var messages: [Message] = []
    private(set) var running = false
    private(set) var pendingAsk: [Denial] = []
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var sessionProvider: Provider?
    @ObservationIgnored private var allowed: [String] = []
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var errorText = ""
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
        if sessionProvider != provider { sessionID = nil; allowed = []; sessionProvider = provider }
        let config = app.config
        let chat = Provider.Chat(model: config.string(provider.modelSetting), effort: config.string(provider.effortSetting),
                                 fullAccess: config.string("claudeAccess") == "full", instructions: instructions(provider),
                                 tools: Bundle.main.executablePath ?? "", session: sessionID, allowed: allowed)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = provider.chatArguments(chat)
        process.environment = app.childEnvironment
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
                    if status != 0 && status != 15 && !detail.isEmpty {
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
        default: return name
        }
    }

    private func instructions(_ provider: Provider) -> String {
        var prompt = """
        You are \(provider.name), running inside Petal, the user's dock on macOS. Your replies show in a small panel above the dock: be brief and friendly, short paragraphs, no big headings. You work in the user's home folder.

        Everything about the dock is customizable through you. Use the petal MCP tools: call petal_get_state first, then petal_set_settings (appearance: dockColor, iconSize, accentColor, …; feature switches: bounce, badges, previews, …), petal_set_dock (position, auto-hide), petal_save_mode / petal_delete_mode (focus modes and their apps; apps are bundle identifiers, get them from petal_list_apps; mode icons are SF Symbol names), petal_switch_mode (puts the current Desktop in a mode), petal_export_recipe / petal_import_recipe (share a dock as a .petal file, or add one someone shared), petal_suggestions and petal_summary (from the user's private activity history). A mode's shortcut field names a Shortcut (Shortcuts app) that runs when a Desktop enters the mode, such as one that turns on a Focus; the schedule setting switches modes by the clock. Every Desktop has its own mode. Changes apply instantly. If a request can't be done with settings and Petal's source is on this Mac (path in petal_get_state), you may edit its Swift source, rebuild it with macos/build.sh, copy macos/build/Petal.app over the running app (its path is files.app in petal_get_state), and call petal_reload; mention that a Petal update could replace source edits. You can also help with anything else on the Mac: apps, files, macOS settings (defaults, AppleScript, the shell). If something needs the user's approval, say in one line what it would do; they can allow it from the panel. If something about Petal itself is broken, run `\(Bundle.main.executablePath ?? "Petal") doctor` (and `… doctor --fix`); the petal skill says more.
        """
        let notes = (try? String(contentsOf: app.config.instructionsFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !notes.isEmpty { prompt += "\n\nThe user's own instructions:\n" + notes }
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
        hosting.rootView = AnyView(content.environment(PetalApp.shared))
        showAgain()
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
        let gap = config.number("dockMargin") >= 0 ? config.number("dockMargin") : 4
        let icon = max(16, config.number("iconSize"))
        let inset = config.number("iconPadding") >= 0 ? config.number("iconPadding") : 5
        return gap + 2 + 4 + icon + inset * 2 + 4
    }

    /// Grows upward as the conversation does, keeping its bottom edge.
    func fit() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size != frame.size else { return }
        setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY, width: size.width, height: size.height).integral, display: true,
                 animate: false)
    }
}

/// The Claude panel (AskBox.qml).
@MainActor @Observable
final class ClaudePanel {
    let agent = Agent()
    var draft = ""
    var optionsOpen = false
    private(set) var isOpen = false
    @ObservationIgnored private var panel: InputPanel?

    func open(asking text: String?, send: Bool = true) {
        let app = PetalApp.shared
        Task { await app.usage.refresh() }
        // Codex's models, if they couldn't be read at launch (Codex installed or signed in since).
        if app.chatProvider == .codex && app.codexModels.isEmpty { app.loadCodexModels() }
        if panel == nil {
            let panel = InputPanel()
            panel.onClose = { [weak self] in self?.isOpen = false; self?.optionsOpen = false }
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

    static let suggestions = ["Add a Gaming mode to my dock", "Why is my Mac slow right now?", "Make my dock icons a bit bigger"]

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
            input
        }
        .padding(18)
        .frame(width: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(10)
        .onAppear { focused = true }
        .onChange(of: agent.messages.count) { _, _ in DispatchQueue.main.async { panel.fit() } }
        .onChange(of: agent.running) { _, _ in DispatchQueue.main.async { panel.fit() } }
        .onChange(of: panel.optionsOpen) { _, _ in DispatchQueue.main.async { panel.fit() } }
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
            }
            Spacer()
            Button {
                panel.optionsOpen.toggle()
            } label: {
                Text("\(modelName) · \(provider.map { app.config.string($0.effortSetting) } ?? "")  \(panel.optionsOpen ? "⌃" : "⌄")")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if !agent.messages.isEmpty {
                Button("New chat") { agent.reset() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            RoundButton(symbol: "xmark") { panel.close() }
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
                    .pickerStyle(.segmented).labelsHidden()
                }
            }
            if app.models(for: provider).count > 1 {
                OptionRow(title: "Model") {
                    if provider == .codex {
                        // Codex lists more models than fit side by side.
                        Picker("", selection: Binding(get: { app.currentModel(for: provider) }, set: { app.config.set(provider.modelSetting, $0) })) {
                            ForEach(app.models(for: provider), id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    } else {
                        Picker("", selection: Binding(get: { app.currentModel(for: provider) }, set: { app.config.set(provider.modelSetting, $0) })) {
                            ForEach(app.models(for: provider), id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                }
            }
            OptionRow(title: "Effort") {
                Picker("", selection: Binding(get: { app.config.string(provider.effortSetting) }, set: { app.config.set(provider.effortSetting, $0) })) {
                    ForEach(app.efforts(for: provider), id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
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
            Text("Ask anything. \(provider?.name ?? "It") can change your dock and modes, your Mac's settings, or your files.")
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.bottom, 6)
            ForEach(Self.suggestions, id: \.self) { suggestion in
                SuggestionRow(text: suggestion) { agent.send(suggestion) }
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

    private func submit() {
        guard !agent.running else { return }
        let text = panel.draft
        panel.draft = ""
        agent.send(text)
    }
}

struct OptionRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            content
        }
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
            Text(Self.markdown(message.text)).font(.system(size: 13.5)).lineSpacing(2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .step:
            Text("›  " + message.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        case .error:
            Text(message.text).font(.system(size: 13.5)).foregroundStyle(Color(red: 1, green: 0.42, blue: 0.54)).textSelection(.enabled)
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
