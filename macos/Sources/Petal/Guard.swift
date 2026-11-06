import AppKit

/// What's in front, as the focus guard sees it: an app, and for a browser its tab's site.
struct Front: Equatable {
    let bundleID: String
    let pid: pid_t
    let name: String
    /// The tab's site ("x.com"), when the browser said its address.
    let domain: String?
    /// The tab's title, without the browser's name.
    let title: String
    let isBrowser: Bool

    /// What the AI's answer is kept under: the site, else the app (a tab Petal can't read is kept by its title).
    var key: String {
        if let domain { return "site:" + domain }
        return isBrowser ? "tab:\(bundleID)|\(title.lowercased())" : "app:" + bundleID
    }

    /// The name on a card: the site, else the tab's title, else the app.
    var label: String { domain ?? (isBrowser ? title : name) }

    /// What "Keep it here" and the AI save into a mode: the site's domain, else the app.
    var entry: String? { domain ?? (isBrowser ? nil : bundleID) }
}

/// The focus guard (Dock.qml's on Omarchy), with `focusGuard` on. When the window in front changes, and for a browser
/// when the tab changes, it works out what's there and:
/// 1. it belongs to this mode (apps, allow or sites), or this mode is distracting itself: nothing;
/// 2. it belongs to a distracting mode X (with `blockDistractions`): a block card, "x.com · belongs to Social", with
///    Stay (the tab closes, or the app hides) and Go to Social (with its wait);
/// 3. it belongs to another mode Y: a move card, "figma.com · fits Design", with Keep it here and Move to Design;
/// 4. nothing knows it: the AI sorts it once ever (per site or app), the answer goes into that mode's sites or allow,
///    and 1–3 apply; when it fits this mode, a peek says so and fades.
@MainActor
final class FocusGuard {
    let brain = Brain()
    /// "Move to Design": with per-mode windows on, that feature sets this to move the window or tab to the mode.
    /// Without it, moving just switches this Desktop's mode.
    var mover: ((Front, Mode, Int) -> Void)?

    private var scheduled: DispatchWorkItem?
    private var lastTitle = ""
    private var lastOk: String?
    private var timer: Timer?
    private var asking: Set<String> = []
    private var sortingModes: [String: Date] = [:]
    private var failed: [String: Date] = [:]
    private var sorted: [String: String]

    var app: PetalApp { PetalApp.shared }
    var config: Config { app.config }

    static let sortedFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Petal/sorted.json")

    init() {
        sorted = (Config.parse(Self.sortedFile) ?? [:]).compactMapValues { $0 as? String }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        // A browser's tab changing changes its window's title; macOS sends other apps no notice of it.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, PetalApp.started else { return }
                self.sortModes()
                guard self.config.bool("focusGuard") else { return }
                let title = Windows.frontTitle()
                if title != self.lastTitle { self.lastTitle = title; self.schedule() }
            }
        }
    }

    /// Shortly after the last change: a tab is blocked on sight, but not while someone flicks through tabs.
    func schedule() {
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func check() {
        guard config.bool("modes"), config.bool("focusGuard") else { return clearCards() }
        // A suggestion or the weekly summary stays until it's answered.
        if let card = app.popups.card, [.suggestion, .made, .summary].contains(card.kind) { return }
        guard let running = NSWorkspace.shared.frontmostApplication, running.activationPolicy == .regular,
              running.bundleIdentifier != Bundle.main.bundleIdentifier, let id = running.bundleIdentifier,
              let dock = app.docks.focusedDock, let desktop = dock.desktop, let mode = config.mode(forDesktop: desktop) else { return }
        let name = Apps.name(id)
        let isBrowser = Browsers.kind(id) != nil || Self.browsers.contains(id)
        let title = isBrowser ? Self.cleanTitle(Windows.frontTitle(), app: name) : name
        guard !isBrowser else {
            app.browsers.frontURL(of: running) { [weak self] url in
                guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier else { return }
                // A new tab, settings or a local page is nothing to sort.
                if let url, Sites.domain(url) == nil || !["http", "https"].contains(URL(string: url)?.scheme ?? "https") {
                    return self.ok(id)
                }
                if url == nil && (title == name || title.range(of: #"^(new tab|untitled|about:blank|start page|favorites|)$"#,
                                                               options: [.regularExpression, .caseInsensitive]) != nil) {
                    return self.ok(id)
                }
                self.evaluate(Front(bundleID: id, pid: running.processIdentifier, name: name, domain: url.flatMap(Sites.domain),
                                    title: title, isBrowser: true), mode: mode, desktop: desktop)
            }
            return
        }
        evaluate(Front(bundleID: id, pid: running.processIdentifier, name: name, domain: nil, title: title, isBrowser: false),
                 mode: mode, desktop: desktop)
    }

    /// Steps 1–4 for what's in front.
    func evaluate(_ front: Front, mode: Mode, desktop: Int, asked: Bool = false) {
        if mode.isDistracting || mode.isEverything { return ok(front.bundleID) }
        let owners = Self.owners(of: front, in: config.modes)
        if owners.contains(where: { $0.id == mode.id }) { return ok(front.bundleID) }
        if let owner = owners.first(where: \.isDistracting) ?? owners.first {
            if app.pendingMode?.mode == owner.id { return }   // no card about a mode while its countdown runs
            let block = owner.isDistracting && config.bool("blockDistractions")
            return show(FocusCard(kind: block ? .block : .move, bundleID: front.bundleID, title: front.label, target: owner,
                                  here: mode, desktop: desktop, front: front))
        }
        // Nothing knows it: the AI, once ever per site or app.
        // Sorted before, but no mode fit (or its mode has since let it go): leave it be.
        if sorted[front.key] != nil { return ok(front.bundleID) }
        guard !asked, brain.enabled, !asking.contains(front.key), (failed[front.key].map { Date().timeIntervalSince($0) > 600 } ?? true) else { return }
        asking.insert(front.key)
        let what = front.domain.map { "\(front.name) tab: \($0)" } ?? (front.isBrowser ? "\(front.name) tab" : front.name)
        let title = front.isBrowser ? front.title : "\(front.name) — \(Windows.frontTitle())"
        brain.classifyWindow(app: what, title: title, key: front.key) { [weak self] answer in
            guard let self else { return }
            self.asking.remove(front.key)
            // No answer (offline, signed out): ask again in a while, not on every look.
            guard let answer else { self.failed[front.key] = Date(); return }
            let target = (answer["mode"] as? String).flatMap { id in self.config.modes.first { $0.id == id } }
            self.remember(front, in: target)
            // Still in front, in the same mode?
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front.pid,
                  let now = self.config.modes.first(where: { $0.id == mode.id }) else { return }
            if target?.id == mode.id {
                if self.config.bool("peeks") {
                    self.show(FocusCard(kind: .peek, bundleID: front.bundleID, title: front.label, target: now, here: now,
                                        reason: answer["reason"] as? String ?? "", desktop: desktop, front: front))
                }
            } else if target != nil {
                self.evaluate(front, mode: now, desktop: desktop, asked: true)
            }
        }
    }

    /// The AI's answer, kept: a site goes into its mode's sites, an app into its mode's allow.
    private func remember(_ front: Front, in mode: Mode?) {
        sorted[front.key] = mode?.id ?? ""
        try? FileManager.default.createDirectory(at: Self.sortedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        Config.writeObject(sorted, to: Self.sortedFile)
        guard let mode else { return }
        if let domain = front.domain { config.addSite(domain, to: mode.id) } else if !front.isBrowser { config.allow(front.bundleID, in: mode.id) }
    }

    /// The modes something belongs to: an app by its modes' apps and allow lists; a tab by its modes' sites, allow
    /// lists and website shortcuts.
    nonisolated static func owners(of front: Front, in modes: [Mode]) -> [Mode] {
        modes.filter { mode in
            if front.isBrowser {
                let sites = mode.sites + mode.allow.filter { !$0.isEmpty && !Self.looksLikeApp($0) }
                if sites.contains(where: { Sites.matches($0, domain: front.domain, title: front.title) }) { return true }
                if let domain = front.domain {
                    return mode.apps.contains { Sites.isWeb($0) && Sites.domain($0).map { domain == $0 || domain.hasSuffix("." + $0) } == true }
                }
                return false
            }
            return (mode.apps + mode.allow).contains { $0.caseInsensitiveCompare(front.bundleID) == .orderedSame }
        }
    }

    /// A bundle id ("com.tinyspeck.slackmacgap") rather than a site ("x.com") in an allow list.
    nonisolated static func looksLikeApp(_ entry: String) -> Bool {
        let parts = entry.split(separator: ".")
        return parts.count >= 3 && ["com", "org", "net", "io", "app", "dev", "co", "us", "tech", "company", "ru", "de"].contains(parts[0].lowercased())
    }

    private func ok(_ bundleID: String) {
        lastOk = bundleID
        clearCards()
    }

    private func show(_ card: FocusCard) {
        if let current = app.popups.card, current.kind == card.kind, current.front == card.front, current.target?.id == card.target?.id { return }
        // A notification that can't wait isn't replaced by a card about the window in front.
        if app.popups.card?.kind == .note { return }
        app.popups.show(card)
    }

    private func clearCards() {
        if let kind = app.popups.card?.kind, [.block, .move].contains(kind) { app.popups.dismissCard() }
    }

    // MARK: Card buttons

    /// Stay (or ×, or Escape on a block card): the tab closes, or the app hides, and what you were doing comes back.
    func stay(_ card: FocusCard) {
        app.popups.dismissCard()
        app.activity.recordCard("back", app: card.bundleID, mode: card.here?.id ?? "")
        guard let front = card.front, let running = NSRunningApplication(processIdentifier: front.pid) else { return }
        if front.isBrowser {
            app.browsers.closeTab(of: running)
        } else {
            running.hide()
            if let lastOk, lastOk != front.bundleID,
               let back = NSRunningApplication.runningApplications(withBundleIdentifier: lastOk).first {
                Windows.bringForward(back)
            }
        }
    }

    /// Go to Social (30s wait): like clicking Social; once you're there, its apps and sites are fine.
    func go(_ card: FocusCard) {
        app.popups.dismissCard()
        app.activity.recordCard("switch", app: card.bundleID, mode: card.here?.id ?? "")
        guard let target = card.target, let desktop = card.desktop ?? app.docks.focusedDock?.desktop else { return }
        app.requestMode(target.id, desktop: desktop)
    }

    /// Keep it here (or ×, or Escape on a move card): it's fine in this mode from now on.
    func keep(_ card: FocusCard) {
        app.popups.dismissCard()
        app.activity.recordCard("keep", app: card.bundleID, mode: card.here?.id ?? "")
        guard let here = card.here, let entry = card.front?.entry else { return }
        config.allow(entry, in: here.id)
    }

    /// Move to Design: the window or tab goes there (per-mode windows), else the Desktop switches.
    func move(_ card: FocusCard) {
        app.popups.dismissCard()
        app.activity.recordCard("switch", app: card.bundleID, mode: card.here?.id ?? "")
        guard let target = card.target, let desktop = card.desktop ?? app.docks.focusedDock?.desktop else { return }
        if let mover, let front = card.front { mover(front, target, desktop) } else { app.requestMode(target.id, desktop: desktop) }
    }

    /// × or Escape: Stay for a block card, Keep it here for a move card.
    func dismiss(_ card: FocusCard) {
        switch card.kind {
        case .block: stay(card)
        case .move: keep(card)
        default: app.popups.dismissCard()
        }
    }

    // MARK: Distracting modes

    /// A mode that doesn't say whether it's distracting is asked about once, and the answer saved in modes.json.
    private func sortModes() {
        guard brain.enabled else { return }
        // Once per mode, and again only after 10 minutes if the AI didn't answer.
        for mode in config.modes where mode.distracting == nil && (sortingModes[mode.id].map { Date().timeIntervalSince($0) > 600 } ?? true) {
            sortingModes[mode.id] = Date()
            brain.isDistracting(mode) { [weak self] answer in
                guard let value = answer?["distracting"] as? Bool else { return }
                self?.config.setDistracting(value, for: mode.id)
            }
        }
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
            if let range = text.range(of: separator, options: .backwards), text[range.upperBound...].localizedCaseInsensitiveContains(app) {
                text = String(text[..<range.lowerBound])
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? app : trimmed
    }
}
