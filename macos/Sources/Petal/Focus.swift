import AppKit

/// Focus cards (Dock.qml's focus guard): when the window in front belongs to another mode than its Desktop's, a card
/// says so, with Go back and Switch. A mode guards only if its focusDelay is above 0. Apps belong by the modes' apps
/// and allow lists; browser tabs by the modes' sites in the tab's title; anything else is asked of Claude Haiku.
@MainActor
final class FocusGuard {
    private var snoozed: [String: Date] = [:]
    private var lastOk: String?
    private var pending: DispatchWorkItem?
    private var lastTitle = ""
    private var timer: Timer?
    let brain = Brain()

    var app: PetalApp { PetalApp.shared }
    var config: Config { app.config }

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        // A browser's tab changing changes its window's title; macOS sends other apps no notice of it.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.config.bool("focusGuard") else { return }
                let title = Windows.frontTitle()
                if title != self.lastTitle { self.lastTitle = title; self.schedule() }
            }
        }
    }

    /// 1.2 s after the last change, as on Omarchy.
    func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func check() {
        guard config.bool("modes"), config.bool("focusGuard") else { return }
        // A suggestion or the weekly summary stays until it's answered.
        if let card = app.popups.card, card.kind != .guardCard { return }
        guard let front = NSWorkspace.shared.frontmostApplication, front.activationPolicy == .regular,
              front.bundleIdentifier != Bundle.main.bundleIdentifier, let key = front.bundleIdentifier,
              let dock = app.docks.focusedDock, let desktop = dock.desktop, let mode = config.mode(forDesktop: desktop) else { return }
        guard mode.focusDelay > 0 else { clearGuardCard(); return }

        let name = Apps.name(key)
        let browser = Self.browsers.contains(key)
        let raw = Windows.frontTitle()
        let title = browser ? Self.cleanTitle(raw, app: name) : name
        let snoozeKey = "\(key)|\(browser ? title : "")"

        func ok() {
            lastOk = key
            clearGuardCard()
        }
        if browser && title.range(of: #"^(new tab|untitled|about:blank|start page|favorites|)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return ok()
        }
        if let until = snoozed[snoozeKey], until > Date() { return }

        var owner: Mode?
        if browser {
            let lower = raw.lowercased()
            let matches = config.modes.filter { m in m.sites.contains { !$0.isEmpty && lower.contains($0.lowercased()) } }
            owner = matches.first { $0.id == mode.id } ?? matches.first
            if owner == nil && mode.sites.isEmpty && mode.apps.contains(key) { return ok() }
        } else {
            if mode.apps.contains(key) || mode.allow.contains(key) { return ok() }
            owner = config.modes.first { $0.apps.contains(key) }
        }
        if let owner {
            if owner.id == mode.id { return ok() }
            return show(FocusCard(kind: .guardCard, bundleID: key, title: title, target: owner, here: mode, desktop: desktop, snoozeKey: snoozeKey))
        }
        guard brain.enabled else { return }
        brain.classifyWindow(app: browser ? "\(name) tab" : name, title: browser ? title : "\(name) — \(raw)") { [weak self] answer in
            guard let self, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == key else { return }
            if let id = answer?["mode"] as? String, let target = self.config.modes.first(where: { $0.id == id }), id != mode.id {
                self.show(FocusCard(kind: .guardCard, bundleID: key, title: title, target: target, here: mode,
                                    reason: answer?["reason"] as? String ?? "", desktop: desktop, snoozeKey: snoozeKey))
            } else {
                self.lastOk = key
            }
        }
    }

    private func show(_ card: FocusCard) {
        if let current = app.popups.card, current.kind == .guardCard, current.bundleID == card.bundleID, current.title == card.title { return }
        app.popups.show(card)
    }

    private func clearGuardCard() {
        if app.popups.card?.kind == .guardCard { app.popups.dismissCard() }
    }

    // MARK: Card buttons

    /// ×: dismiss, and don't ask about this again for 10 minutes.
    func close(_ card: FocusCard) {
        answer(card, "close")
    }

    /// Go back: dismiss, snooze, and bring back what you were doing.
    func stay(_ card: FocusCard) {
        answer(card, "back")
        guard card.kind == .guardCard, let lastOk, lastOk != card.bundleID,
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: lastOk).first else { return }
        Windows.bringForward(running)
    }

    /// Switch: dismiss, snooze, and put the Desktop in the card's mode.
    func go(_ card: FocusCard) {
        answer(card, "switch")
        guard let target = card.target, let desktop = card.desktop ?? app.docks.focusedDock?.desktop else { return }
        app.requestMode(target.id, desktop: desktop)
    }

    /// Every answer dismisses and snoozes the card, and goes in the activity history (for the weekly summary).
    private func answer(_ card: FocusCard, _ choice: String) {
        app.popups.dismissCard()
        if !card.snoozeKey.isEmpty { snoozed[card.snoozeKey] = Date().addingTimeInterval(600) }
        if card.kind == .guardCard { app.activity.recordCard(choice, app: card.bundleID, mode: card.here?.id ?? "") }
    }

    // MARK: Browsers

    /// Every app that opens web links.
    static let browsers: Set<String> = {
        guard let url = URL(string: "https://example.com") else { return [] }
        return Set(NSWorkspace.shared.urlsForApplications(toOpen: url).compactMap { Bundle(url: $0)?.bundleIdentifier })
    }()

    /// A tab's title without the browser's name after it ("Inbox — Helium" → "Inbox").
    static func cleanTitle(_ title: String, app: String) -> String {
        var text = title
        for separator in [" - ", " — ", " – "] {
            if let range = text.range(of: separator, options: .backwards) { text = String(text[..<range.lowerBound]) }
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? app : trimmed
    }
}

/// Quick JSON calls that sort activity into modes (Brain.qml), to the chosen AI's quick, cheap setting (Claude
/// Haiku; Codex at low effort): one at a time, answers cached.
@MainActor
final class Brain {
    private var queue: [(prompt: String, key: String, done: ([String: Any]?) -> Void)] = []
    private var busy = false
    private var cache: [String: [String: Any]] = [:]

    var enabled: Bool {
        let app = PetalApp.shared
        return app.config.bool("ai") && app.chatProvider.flatMap { app.paths[$0] } != nil
    }

    func classifyWindow(app: String, title: String, done: @escaping ([String: Any]?) -> Void) {
        let prompt = """
        You sort a user's desktop activity into focus modes.
        Modes:
        \(modesBrief)

        Focused window: app="\(app)" title="\(title)"
        Which mode does this activity belong to? Use null if none fits.
        Reply with ONLY JSON: {"mode": "<id>"|null, "reason": "<max 8 words, what it is>"}
        """
        ask(prompt, key: "w|\(app)|\(title)", done: done)
    }

    /// A name, symbol, color and about for a new mode holding `apps` (names), unlike the modes there are.
    func nameMode(apps: [String], done: @escaping ([String: Any]?) -> Void) {
        let colors = PetalApp.shared.config.modes.map(\.hex).joined(separator: ", ")
        let prompt = """
        You name focus modes for a dock. Each mode has its own apps; the user switches a Desktop into a mode.
        Modes they have:
        \(modesBrief)

        These apps are often used together: \(apps.joined(separator: ", ")).
        Name a new mode for them: 1 or 2 words, unlike the existing names. Pick an SF Symbol name for its icon, a #rrggbb color unlike these (\(colors)), and a short about: what the mode is for, used to sort new apps into it.
        Reply with ONLY JSON: {"name": "<name>", "icon": "<SF Symbol>", "color": "#rrggbb", "about": "<under 12 words>"}
        """
        ask(prompt, key: "n|" + apps.joined(separator: "|"), done: done)
    }

    private var modesBrief: String {
        PetalApp.shared.config.modes.map { m in
            "- \(m.id) (\(m.name)): \(m.about)" + (m.sites.isEmpty ? "" : "; sites: " + m.sites.joined(separator: ", "))
        }.joined(separator: "\n")
    }

    private func ask(_ prompt: String, key: String, done: @escaping ([String: Any]?) -> Void) {
        if let cached = cache[key] { return done(cached) }
        queue.append((prompt, key, done))
        next()
    }

    private func next() {
        guard !busy, !queue.isEmpty, let provider = PetalApp.shared.chatProvider, let path = PetalApp.shared.paths[provider] else { return }
        busy = true
        let job = queue.removeFirst()
        let environment = PetalApp.shared.childEnvironment
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = provider.quickArguments
            process.environment = environment
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            var answer: [String: Any]?
            if (try? process.run()) != nil {
                input.fileHandleForWriting.write(Data(job.prompt.utf8))
                try? input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = provider.quickReply(String(decoding: data, as: UTF8.self))
                if process.terminationStatus == 0, let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
                    answer = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let answer { self.cache[job.key] = answer }
                    job.done(answer)
                    self.busy = false
                    self.next()
                }
            }
        }
    }
}
