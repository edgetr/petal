import AppKit

/// `petal_browser`: a browser of the run's own (RunBrowser.swift), for web work in a run. One tool with actions:
/// open, read, click, type, select, check, key, scroll, wait, tabs, tab, close_tab, back, forward, reload.
///
/// The first use in a reply asks the person once, as the first act on an app does (kind `browser`; Allow covers the
/// reply), on the note or over the dock, never on the hidden display. Every action checks its reply wasn't stopped
/// right before it changes anything (Stop, Pause, a new turn, using apps or hidden displays turned off). Everything
/// it tells goes through the vault's redaction, and nothing is told while the vault can't be read. Never into a
/// password, card or token field: those are the vault's (`petal_vault`, with ids from `read`). Nothing is downloaded.
extension Assist {
    private static let browserOver = ComputerUse.stoppedText + " Don't carry on using the browser in this reply: say what's left and wait for them."
    private static let browserActions: Set<String> = ["open", "read", "click", "type", "select", "check", "key", "scroll", "wait", "tabs", "tab",
                                                      "close_tab", "back", "forward", "reload"]
    /// What an action that needs no page yet (there's no browser to ask) says.
    private static let browserNone = "You have no browser open in this run. petal_browser open (with an address) starts one."

    /// `who`: who's asking (for an AI session outside Petal, the name on its display's tile). `gone`: an outside
    /// caller's hung-up flag, carried by the call's token to every change.
    func browser(_ args: [String: Any], caller: String?, who: AgentAccess.Caller?, gone: (@Sendable () -> Bool)?,
                 _ send: @escaping (Any) -> Void, _ fail: @escaping (String) -> Void) {
        guard let caller, !caller.isEmpty else { return fail(ComputerUse.oldTools) }
        guard config.bool("computerUse") else { return fail("Using apps is off in Petal's settings (computerUse); only the person can turn it on.") }
        let action = (args["action"] as? String ?? "").lowercased().replacingOccurrences(of: "-", with: "_")
        if ["picture", "screenshot"].contains(action) { return fail(RunBrowserRules.noPictures) }
        guard Self.browserActions.contains(action) else {
            return fail("action is open, read, click, type, select, check, key, scroll, wait, tabs, tab, close_tab, back, forward or reload.")
        }
        // What can be refused without a browser is, before anything starts or anyone is asked.
        var address = ""
        if action == "open" {
            switch RunBrowserRules.address(args["address"] as? String ?? args["url"] as? String ?? args["open"] as? String ?? "") {
            case .refuse(let why): return fail(why)
            case .go(let checked): address = checked
            }
        }
        var key: RunBrowserRules.Key?
        if action == "key" {
            guard let parsed = RunBrowserRules.key(args["key"] as? String ?? "") else { return fail("key is \(RunBrowserRules.keyNames). Text goes in with type.") }
            key = parsed
        }
        let id = (args["id"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if ["click", "type", "select", "check"].contains(action) {
            guard BrowserOutline.isID(id) else { return fail("Give the id of a control from petal_browser read (like b12).") }
        }
        if action == "type", (args["text"] as? String ?? "").isEmpty { return fail("Give the text to type.") }
        if action == "select", (args["choice"] as? String ?? args["text"] as? String ?? "").isEmpty { return fail("Give choice: the option to pick, by what it says.") }
        let direction = (args["direction"] as? String ?? "").lowercased()
        if action == "scroll", id.isEmpty, !["up", "down", "left", "right", "top", "bottom"].contains(direction) {
            return fail("direction is up, down, left, right, top or bottom (or id, to bring a control into view).")
        }
        let task = args["task"] as? String ?? ""
        guard let token = computer.token(caller, task: task, gone: gone) else { return fail(Self.browserOver) }
        // Without a browser there's nothing to read or press, and nobody is asked about one; nor where none can start.
        if runBrowsers.browser(for: caller) == nil {
            guard action == "open" else { return fail(Self.browserNone) }
            guard config.bool("runDisplays") else { return fail(RunBrowserRules.off) }
        }
        // The control an id names is bound now, before anyone is asked anything: whatever the page is read as while a
        // card waits, this call acts on this very element or not at all.
        var bound: RunBrowser.Bound?
        if BrowserOutline.isID(id), action != "tab", action != "close_tab", let browser = runBrowsers.browser(for: caller) {
            guard let field = browser.bind([id])?.first else {
                if case .failure(let problem) = browser.ref(id) { return fail(problem.words) }
                return fail(RunBrowserRules.stale)
            }
            bound = field
        }
        let label = who.map { $0.agent == .petal ? "" : $0.label } ?? ""
        browserAdmit(caller, token: token, send: send, fail: fail) { [weak self] in
            guard let self else { return }
            let ready: (RunBrowser) -> Void = { browser in
                self.browserRun(action, args, address: address, key: key, id: id, bound: bound, direction: direction, browser: browser, caller: caller,
                                token: token, send: send, fail: fail)
            }
            if let browser = self.runBrowsers.browser(for: caller) { return ready(browser) }
            guard action == "open" else { return fail(Self.browserNone) }
            self.runBrowsers.need(caller, label: label) { result in
                guard self.computer.live(caller, token) else { return fail(Self.browserOver) }
                switch result {
                case .failure(let problem): fail(problem.words)
                case .success(let browser): ready(browser)
                }
            }
        }
    }

    var runBrowsers: RunBrowsers { app.runBrowsers }

    /// The reply may use its own browser already, or the person is asked once (Allow covers the reply; an AI session
    /// outside Petal: its task). Don't, a Stop or the reply ending while they're asked: `go` never runs.
    func browserAdmit(_ caller: String, token: Acting.Cancel, send: @escaping (Any) -> Void, fail: @escaping (String) -> Void, go: @escaping () -> Void) {
        if computer.allowed(caller, token: token, app: RunBrowsers.kind) { return go() }
        let lasting = caller.hasPrefix("mcp-") ? "For this task" : "Until this reply is done"
        ask(RunBrowsers.kind, "Let Petal AI use a browser of its own?",
            detail: "\(lasting) it can open pages, press and type in a browser of its own, on a display you don't see. It starts fresh, signed in to nothing, and goes when the work is done. Nothing comes forward, and your pointer and keyboard stay yours. Stop it from its note or the AI button.",
            owner: caller) { [weak self] allowed in
            guard let self else { return }
            guard self.computer.live(caller, token) else { return fail(Self.browserOver) }
            guard allowed else {
                return send(["declined": "The person didn't let Petal AI use a browser of its own. Don't find another way; say what you would have done."])
            }
            guard self.config.bool("computerUse"), self.computer.allow(caller, token: token, app: RunBrowsers.kind) else { return fail(Self.browserOver) }
            go()
        }
    }

    /// One action, on the browser's own queue; its answer back on the main thread, every word of it through the
    /// vault's redaction.
    private func browserRun(_ action: String, _ args: [String: Any], address: String, key: RunBrowserRules.Key?, id: String, bound: RunBrowser.Bound?, direction: String,
                            browser: RunBrowser, caller: String, token: Acting.Cancel, send: @escaping (Any) -> Void, fail: @escaping (String) -> Void) {
        browser.queue.async {
            let outcome = BrowserActs.perform(action, args, address: address, key: key, id: id, bound: bound, direction: direction, browser: browser, cancel: token)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let line = outcome.did { self.did(line) }
                    guard self.computer.live(caller, token) else { return fail(Self.browserOver) }
                    if let error = outcome.error { return fail(error) }
                    send(outcome.reply)
                }
            }
        }
    }

    // MARK: The vault in a run's browser

    /// The fields named by `ids` are a page's of the caller's own browser (ids from petal_browser read).
    func vaultPage(_ caller: String?, ids: [String]) -> VaultSurface? {
        guard !ids.isEmpty, ids.allSatisfy(BrowserOutline.isID), let browser = runBrowsers.browser(for: caller),
              let fields = browser.bind(ids) else { return nil }
        // Bound now, to these very elements: what the ids mean later (after another read) no longer matters.
        return .page(browser: browser, fields: fields)
    }

    /// Why the vault can't fill these fields now, or nil: a window petal_ui read needs Accessibility; a page of the
    /// run's own browser only that using apps is on.
    func vaultRefusal(_ caller: String?, ids: [String]) -> String? {
        guard !ids.isEmpty, ids.allSatisfy(BrowserOutline.isID), runBrowsers.browser(for: caller) != nil else { return computer.refusal() }
        return config.bool("computerUse") ? nil : "Using apps is off in Petal's settings (computerUse); only the person can turn it on."
    }

    /// Where a page's fields are and what kind each is, asked of the browser itself (its frames' addresses, the tab's
    /// page, its own record of the tab), with the vault's items; handed back on the main thread.
    func vaultPagePlaces(_ browser: RunBrowser, _ fields: [RunBrowser.Bound], fail: @escaping (String) -> Void,
                         done: @escaping @MainActor (_ places: [Vault.Place], _ targets: [Vault.Target], _ items: [VaultItem]?) -> Void) {
        browser.queue.async {
            let found = browser.places(fields)
            let items = try? VaultStore.items()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch found {
                    case .failure(let problem): fail(problem.words)
                    case .success(let read): done(read.places, read.targets, items)
                    }
                }
            }
        }
    }

    /// One field of a page filled from the vault: the checks `ComputerUse.fill` makes for a window (the reply still
    /// going, an agent's grant still there, payment info only under the Buy that covers this very page), then the
    /// fill on the browser's queue (RunBrowser.fill), where the page is asked about again right before the value goes.
    /// `allowed`: the person just said yes to this very fill on its card, which lets it type; Return after it asks to
    /// use the browser as any act does.
    func vaultPageFill(_ plan: VaultFillPlan, field: RunBrowser.Bound, browser: RunBrowser, caller: String, token: Acting.Cancel, allowed: Bool,
                       agent: (pass: AgentPass, item: String)?, send: @escaping (Any) -> Void, fail: @escaping (String) -> Void) {
        guard computer.live(caller, token) else { return fail(Self.browserOver) }
        if let agent, !AgentGrants.shared.still(agent.pass, item: agent.item) { return fail(AgentPass.revokedText) }
        guard config.bool("computerUse") else { return fail("Using apps is off in Petal's settings (computerUse); only the person can turn it on.") }
        var buy: Vault.BuyToken?
        if plan.payment {
            guard let covering = computer.checkout(caller, token: token, place: plan.place, window: browser.window, card: plan.itemID, revision: plan.revision) else {
                return fail(Acting.buyEndedText)
            }
            buy = covering
        }
        let cancel = Acting.Cancel(under: token, buy: buy, pass: agent?.pass)
        let go = {
            browser.queue.async {
                let why = browser.fill(plan, field: field, cancel: cancel)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let why {
                            if cancel.stopped, !cancel.buyEnded { return fail(agent?.pass.revoked == true ? AgentPass.revokedText : ComputerUse.stoppedText) }
                            return fail(why)
                        }
                        let what = (plan.title.isEmpty ? "" : plan.title + " ") + plan.field.words
                        self.did("Filled your \(named: what, else: "details") on \(named: plan.place.host ?? browser.spec.name, else: "a page") (a browser of its own)")
                        send(["filled": plan.field.rawValue, "app": browser.spec.name])
                    }
                }
            }
        }
        if Vault.fillAdmitted(allowed: allowed, submit: plan.submit, appAllowed: computer.allowed(caller, token: token, app: RunBrowsers.kind)) { return go() }
        browserAdmit(caller, token: token, send: send, fail: fail, go: go)
    }
}

/// Where a vault call's fields are: a window `petal_ui` read (its controls, through Accessibility), or a page of the
/// run's own browser (ids from `petal_browser` read). The vault's decisions are the same for both (Vault.decide);
/// only who reads where a field is, and who puts the value in, differ.
enum VaultSurface {
    case window(map: ComputerUse.Map, entries: [ComputerUse.Entry])
    /// A page of the run's own browser: its fields bound when the call came in (RunBrowser.Bound).
    case page(browser: RunBrowser, fields: [RunBrowser.Bound])

    var isPage: Bool {
        if case .page = self { return true }
        return false
    }

    var appName: String {
        switch self {
        case .window(let map, _): return map.appName
        case .page(let browser, _): return browser.spec.name
        }
    }

    /// The window a Buy is kept for: the window server's number, or the browser's own stand-in for one.
    var windowID: CGWindowID? {
        switch self {
        case .window(let map, _): return map.windowID
        case .page(let browser, _): return browser.window
        }
    }

    var map: ComputerUse.Map? {
        if case .window(let map, _) = self { return map }
        return nil
    }

    /// Only these of its fields, in this order.
    func picking(_ indices: [Int]) -> VaultSurface {
        switch self {
        case .window(let map, let entries): return .window(map: map, entries: indices.map { entries[$0] })
        case .page(let browser, let fields): return .page(browser: browser, fields: indices.map { fields[$0] })
        }
    }
}

/// What each `petal_browser` action does, on the browser's own queue (never the main thread), and what it answers.
/// Every answer's words go through the vault's redaction before they leave here (`shown`); while the vault can't be
/// read nothing is done and nothing is told.
enum BrowserActs {
    struct Outcome {
        var reply: [String: Any] = [:]
        var error: String?
        var did: HistoryLine?
    }

    static let changed = "The page may have changed: call read again before using more ids."

    static func perform(_ action: String, _ args: [String: Any], address: String, key: RunBrowserRules.Key?, id: String, bound: RunBrowser.Bound?, direction: String,
                        browser: RunBrowser, cancel: Acting.Cancel) -> Outcome {
        func failed(_ why: String, did: HistoryLine? = nil) -> Outcome { Outcome(error: why, did: did) }
        guard browser.alive else { return failed(RunBrowser.Problem.closed.words) }
        // What can't be checked isn't shown, and isn't done either: an answer couldn't say what happened.
        guard !VaultIndex.current().unreadable else {
            return failed(VaultStore.unreadableText + " Petal can't check a page for your secrets, so it does nothing in the browser. Try again in a moment.")
        }
        guard !cancel.stopped else { return failed(ComputerUse.stoppedText) }
        var out = Outcome()
        let site = { host(browser) }
        switch action {
        case "open":
            if let problem = browser.go(address, newTab: args["new_tab"] as? Bool ?? false, cancel: cancel) { return failed(problem.words) }
            out.did = "Opened \(named: URLComponents(string: address)?.host ?? "", else: "a page") in a browser of its own"
            return page(browser, find: "", into: out)
        case "read":
            return page(browser, find: args["find"] as? String ?? "", into: out)
        case "tabs":
            out.reply["tabs"] = tabs(browser)
        case "tab":
            if let problem = browser.pick(tab: args["tab"] as? String ?? id) { return failed(problem.words) }
            out.reply["tabs"] = tabs(browser)
            out.reply["next"] = "read reads the tab you're in now."
        case "close_tab":
            if let problem = browser.close(tab: args["tab"] as? String ?? "") { return failed(problem.words) }
            out.reply["tabs"] = tabs(browser)
            out.reply["next"] = "read reads the tab you're in now."
        case "back", "forward", "reload":
            if let problem = browser.history(action, cancel: cancel) { return failed(problem.words) }
            out.reply["done"] = action == "reload" ? "Loaded the page again" : action == "back" ? "Went back" : "Went forward"
            out.reply["next"] = changed
            now(browser, into: &out)
        case "click":
            let name = controlName(browser, id, bound)
            let at = site()
            guard !cancel.stopped else { return failed(ComputerUse.stoppedText) }
            switch browser.act(id, bound: bound, "click", [:], gesture: true) {
            case .failure(let problem): return failed(problem.words)
            case .success(let answer):
                if answer["off"] != nil { return failed("\(id) is greyed out: it can't be pressed now.") }
            }
            usleep(120_000)
            browser.settle(8, cancel: cancel)
            out.did = "Pressed \(quoted: name, else: "a control") on \(named: at, else: "a page") (a browser of its own)"
            out.reply["done"] = "Pressed \(name.isEmpty ? id : "“\(name)”")"
            out.reply["next"] = changed
            now(browser, into: &out)
        case "type":
            let name = controlName(browser, id, bound)
            let at = site()
            let text = args["text"] as? String ?? ""
            guard !cancel.stopped else { return failed(ComputerUse.stoppedText) }
            let answer: [String: Any]
            switch browser.act(id, bound: bound, "type", ["text": text, "replace": args["replace"] as? Bool ?? true, "secret": false]) {
            case .failure(let problem): return failed(problem.words)
            case .success(let got): answer = got
            }
            if answer["secure"] != nil {
                return failed("That's a password field (or one the vault filled): petal_browser never types there. petal_vault fills a saved password (action: fill, fields {password: \"\(id)\"}), or asks the person for one (action: request).")
            }
            if answer["notext"] != nil { return failed("\(id) isn't something to type into. select picks from a menu, check sets a checkbox, click presses.") }
            if answer["off"] != nil { return failed("\(id) can't be typed into right now (it's greyed out or read-only).") }
            guard answer["ok"] != nil else { return failed("The page didn't take it.") }
            out.did = "Typed into \(quoted: name, else: "a field") on \(named: at, else: "a page") (a browser of its own)"
            out.reply["done"] = "Typed into \(name.isEmpty ? id : "“\(name)”")"
            // What the field reads now: never one named for a secret, never text holding one.
            if let value = answer["v"] as? String, let typedInto = bound?.ref.node ?? (try? browser.ref(id).get())?.ref.node {
                let node = typedInto.ui(order: 0)
                out.reply["value"] = VaultIndex.settled { index in UIMap.typedValue(value, node: node, filled: false, secret: index.matches) } ?? UIMap.hidden
            }
            if args["submit"] as? Bool == true {
                guard !cancel.stopped else { return failed("It was typed, not sent: " + ComputerUse.stoppedText, did: out.did) }
                if case .failure(let problem) = browser.act(id, bound: bound, "submit", [:], gesture: true) { return failed("It was typed, not sent: " + problem.words, did: out.did) }
                usleep(120_000)
                browser.settle(8, cancel: cancel)
                out.reply["next"] = changed
                now(browser, into: &out)
            }
        case "select":
            let name = controlName(browser, id, bound)
            let at = site()
            guard !cancel.stopped else { return failed(ComputerUse.stoppedText) }
            let answer: [String: Any]
            switch browser.act(id, bound: bound, "select", ["choice": args["choice"] as? String ?? args["text"] as? String ?? ""]) {
            case .failure(let problem): return failed(problem.words)
            case .success(let got): answer = got
            }
            if answer["noselect"] != nil { return failed("\(id) isn't a select. A menu the page draws itself is opened with click, and its option clicked.") }
            if answer["off"] != nil { return failed("\(id) is greyed out.") }
            if answer["nooption"] != nil {
                let options = (answer["opts"] as? [String] ?? []).joined(separator: ", ")
                return failed(shown("There's no such option in \(id). It has: \(options).") ?? "There's no such option in \(id).")
            }
            out.did = "Chose in \(quoted: name, else: "a menu") on \(named: at, else: "a page") (a browser of its own)"
            out.reply["done"] = "Chose “\(answer["chose"] as? String ?? "")”" + (name.isEmpty ? "" : " in “\(name)”")
            browser.settle(3, cancel: cancel)
        case "check":
            let name = controlName(browser, id, bound)
            let at = site()
            let want = args["on"] as? Bool ?? true
            guard !cancel.stopped else { return failed(ComputerUse.stoppedText) }
            let answer: [String: Any]
            switch browser.act(id, bound: bound, "check", ["on": want], gesture: true) {
            case .failure(let problem): return failed(problem.words)
            case .success(let got): answer = got
            }
            if answer["off"] != nil { return failed("\(id) is greyed out.") }
            if answer["radio"] != nil { return failed("A radio button is turned off by choosing another one.") }
            let isOn = (answer["on"] as? NSNumber)?.intValue == 1
            out.did = isOn ? "Turned on \(quoted: name, else: "a checkbox") on \(named: at, else: "a page") (a browser of its own)"
                : "Turned off \(quoted: name, else: "a checkbox") on \(named: at, else: "a page") (a browser of its own)"
            out.reply["done"] = (name.isEmpty ? id : "“\(name)”") + " is \(isOn ? "on" : "off")"
            browser.settle(3, cancel: cancel)
        case "key":
            guard let key else { return failed("key is \(RunBrowserRules.keyNames).") }
            let at = site()
            if !id.isEmpty {
                guard !cancel.stopped else { return failed(ComputerUse.stoppedText) }
                switch browser.act(id, bound: bound, "focus", [:]) {
                case .failure(let problem): return failed(problem.words)
                case .success(let answer):
                    guard (answer["focused"] as? NSNumber)?.intValue == 1 else { return failed("\(id) didn't take the cursor, so no key was pressed.") }
                }
            }
            if let problem = browser.press(key, cancel: cancel) { return failed(problem.words) }
            usleep(120_000)
            browser.settle(key.key == "Enter" ? 8 : 2, cancel: cancel)
            out.did = "Pressed \(named: key.key == " " ? "Space" : key.key, else: "a key") on \(named: at, else: "a page") (a browser of its own)"
            out.reply["done"] = "Pressed \(key.shift ? "Shift-" : "")\(key.key == " " ? "Space" : key.key)"
            out.reply["next"] = changed
            now(browser, into: &out)
        case "scroll":
            if !id.isEmpty {
                guard !cancel.stopped else { return failed(ComputerUse.stoppedText) }
                if case .failure(let problem) = browser.act(id, bound: bound, "show", [:]) { return failed(problem.words) }
                out.reply["done"] = "Brought \(id) into view"
            } else {
                switch browser.scroll(direction, cancel: cancel) {
                case .failure(let problem): return failed(problem.words)
                case .success(let place): out.reply["done"] = "Scrolled \(direction). " + place
                }
            }
            browser.settle(2, cancel: cancel)
        case "wait":
            let seconds = min(30, max(0.5, (args["seconds"] as? NSNumber)?.doubleValue ?? 5))
            let words = (args["text"] as? String ?? args["for"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch browser.wait(for: words, seconds: seconds, cancel: cancel) {
            case .failure(let problem): return failed(problem.words)
            case .success(let found):
                out.reply["done"] = words.isEmpty ? (found ? "The page has settled." : "The page is still loading after \(Int(seconds)) s.")
                    : (found ? "The page shows that now." : "The page didn't show that within \(Int(seconds)) s.")
            }
            now(browser, into: &out)
        default:
            return failed("action is open, read, click, type, select, check, key, scroll, wait, tabs, tab, close_tab, back, forward or reload.")
        }
        return finish(browser, out)
    }

    /// The tab's page, read, as the answer.
    private static func page(_ browser: RunBrowser, find: String, into outcome: Outcome) -> Outcome {
        var out = outcome
        switch browser.read(find: find) {
        case .failure(let problem):
            out.error = problem.words
            return out
        case .success(let read):
            out.reply["title"] = read.title
            out.reply["address"] = read.address
            out.reply["tab"] = read.tabs > 1 ? "\(read.tab) of \(read.tabs)" : read.tab
            out.reply["page"] = read.text.isEmpty ? "(The page shows nothing Petal can read as text.)" : read.text
            out.reply["controls"] = read.count
            if !read.left.isEmpty { out.reply["left"] = read.left }
            if read.count > 0 { out.reply["note"] = "Ids (b1…) are for click, type, select, check, key and scroll, and for petal_vault's fields; they last until the page changes or it's read again." }
        }
        return finish(browser, out)
    }

    /// What happened by itself meanwhile (a message closed, a download refused, a new tab), and every word redacted.
    private static func finish(_ browser: RunBrowser, _ outcome: Outcome) -> Outcome {
        var out = outcome
        let notes = browser.notes()
        if !notes.isEmpty { out.reply["happened"] = notes }
        guard var checked = shown(out.reply) else {
            return Outcome(error: VaultStore.unreadableText + " Petal couldn't check its answer for your secrets, so it tells nothing. Call read once the vault can be read.", did: out.did)
        }
        // Checked whole first, then kept short: an address or a title is a page's to make as long as it likes.
        for (key, most) in [("address", 2000), ("title", 300)] {
            if let text = checked[key] as? String { checked[key] = UIMap.truncate(text, most) }
        }
        if let tabs = checked["tabs"] as? [[String: Any]] {
            checked["tabs"] = tabs.prefix(40).map { tab -> [String: Any] in
                var short = tab
                if let address = tab["address"] as? String { short["address"] = UIMap.truncate(address, 500) }
                if let title = tab["title"] as? String { short["title"] = UIMap.truncate(title, 200) }
                return short
            }
        }
        out.reply = checked
        return out
    }

    /// Where the tab is now, for an answer.
    private static func now(_ browser: RunBrowser, into out: inout Outcome) {
        guard let now = browser.whereNow() else { return }
        out.reply["address"] = now.address
        if !now.title.isEmpty { out.reply["title"] = now.title }
    }

    private static func tabs(_ browser: RunBrowser) -> [[String: Any]] {
        browser.tabList().map { item in
            var tab: [String: Any] = ["tab": "t\(item.tab.number)", "address": item.tab.url, "title": item.tab.title]
            if item.current { tab["current"] = true }
            return tab
        }
    }

    private static func host(_ browser: RunBrowser) -> String {
        let url = browser.whereNow()?.address ?? browser.tabList().first(where: \.current)?.tab.url ?? ""
        return URLComponents(string: url)?.host ?? ""
    }

    /// A control's name as it was read, for an answer and the history (both redacted before they're kept or told).
    private static func controlName(_ browser: RunBrowser, _ id: String, _ bound: RunBrowser.Bound?) -> String {
        guard let node = bound?.ref.node ?? (try? browser.ref(id).get())?.ref.node else { return "" }
        guard !node.secure, !node.filled else { return node.secure ? "the password field" : "" }
        return UIMap.truncate([node.text, node.label, node.placeholder, node.hint].map(UIMap.tidy).first { !$0.isEmpty } ?? "", 80)
    }

    /// Every string of an answer through the vault's redaction, made again if the vault or what Petal typed changed
    /// meanwhile; nil while the vault can't be read.
    static func shown(_ reply: [String: Any]) -> [String: Any]? {
        let made = VaultIndex.settled { index -> [String: Any]? in
            guard !index.unreadable else { return nil }
            return redact(reply, index.redacted) as? [String: Any]
        }
        return made ?? nil
    }

    static func shown(_ text: String) -> String? {
        (VaultIndex.settled { index -> String? in index.unreadable ? nil : index.redacted(text) }) ?? nil
    }

    private static func redact(_ value: Any, _ redacted: (String) -> String) -> Any {
        if let text = value as? String { return redacted(text) }
        if let list = value as? [Any] { return list.map { redact($0, redacted) } }
        if let object = value as? [String: Any] { return object.mapValues { redact($0, redacted) } }
        return value
    }
}
