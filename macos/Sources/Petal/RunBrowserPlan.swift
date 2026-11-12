import CoreGraphics
import Foundation

/// A run's own browser (RunBrowser.swift): the pure side, checked by macos/checks/run.sh. How Petal talks to the
/// browser (the Chrome DevTools Protocol over a pipe: `CDP`), which browsers it may start and with what, where a
/// run's profile lives and what's left of one after a crash (`RunBrowserRules`), and how a page reads to an AI
/// (`BrowserOutline`). Nothing here starts a process or touches the screen.

// MARK: - The protocol

/// The Chrome DevTools Protocol as the browser speaks it over `--remote-debugging-pipe`: one JSON object per
/// message, each ended by a NUL byte. A request has an id; its reply carries the same id; anything without one is an
/// event. A message for one tab's session names it (`sessionId`).
enum CDP {
    /// The most a single message may be (a page read comes back as one): past it the pipe is given up.
    static let limit = 64 * 1024 * 1024

    /// A request as it goes down the pipe, NUL at its end; nil when it can't be written as JSON.
    static func frame(id: Int, method: String, params: [String: Any] = [:], session: String? = nil) -> Data? {
        var message: [String: Any] = ["id": id, "method": method]
        if !params.isEmpty { message["params"] = params }
        if let session, !session.isEmpty { message["sessionId"] = session }
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return nil }
        // JSON writes a NUL inside a string as \u0000, so the only NUL on the pipe is the one that ends a message.
        guard !data.contains(0) else { return nil }
        data.append(0)
        return data
    }

    /// What the browser wrote, cut into whole messages as it arrives in pieces.
    struct Splitter {
        private var buffer = Data()
        /// A message longer than `limit` came: nothing more is taken.
        private(set) var overflowed = false

        /// The whole messages `bytes` completes (without their NUL), in order; what's left waits for the rest.
        mutating func take(_ bytes: Data) -> [Data] {
            guard !overflowed else { return [] }
            buffer.append(bytes)
            var out: [Data] = []
            while let end = buffer.firstIndex(of: 0) {
                let message = buffer.subdata(in: buffer.startIndex..<end)
                buffer = buffer.subdata(in: buffer.index(after: end)..<buffer.endIndex)
                if !message.isEmpty { out.append(message) }
            }
            if buffer.count > CDP.limit {
                overflowed = true
                buffer = Data()
            }
            return out
        }

        /// How much of an unfinished message is waiting.
        var pending: Int { buffer.count }
    }

    enum Message {
        /// The answer to request `id`: its result, or the browser's error in its own words.
        case reply(id: Int, result: [String: Any], error: String?)
        case event(method: String, params: [String: Any], session: String?)
        /// Not a message Petal understands: passed over.
        case junk
    }

    static func parse(_ data: Data) -> Message {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .junk }
        if let id = (object["id"] as? NSNumber)?.intValue {
            if let error = object["error"] as? [String: Any] {
                return .reply(id: id, result: [:], error: error["message"] as? String ?? "The browser refused that.")
            }
            return .reply(id: id, result: object["result"] as? [String: Any] ?? [:], error: nil)
        }
        if let method = object["method"] as? String {
            return .event(method: method, params: object["params"] as? [String: Any] ?? [:], session: object["sessionId"] as? String)
        }
        return .junk
    }

    /// Replies matched to the requests waiting for them: each request gets the next id, and an id is answered once.
    struct Inbox<Waiter> {
        private var last = 0
        private var waiting: [Int: Waiter] = [:]

        mutating func add(_ waiter: Waiter) -> Int {
            last += 1
            waiting[last] = waiter
            return last
        }

        /// The request this id answers, once; nil for an id nobody waits for (answered already, given up, or made up).
        mutating func take(_ id: Int) -> Waiter? { waiting.removeValue(forKey: id) }

        /// Everyone still waiting, when the pipe closes.
        mutating func drain() -> [Waiter] {
            let all = waiting.keys.sorted().compactMap { waiting[$0] }
            waiting = [:]
            return all
        }

        var count: Int { waiting.count }
    }
}

// MARK: - Which browser, with what, and what's left of one

enum RunBrowserRules {
    /// A browser Petal may start for a run: one of the Chromium family that takes these flags, with who signs it.
    struct Known: Equatable {
        let bundle: String
        let team: String
        let name: String
    }

    /// In the order Petal prefers them when nothing else decides. Arc isn't here: its own interface isn't known to
    /// take these flags. Chromium isn't either: its builds carry no maker's signature to check.
    static let browsers: [Known] = [
        Known(bundle: "com.google.Chrome", team: "EQHXZ8M8AV", name: "Google Chrome"),
        Known(bundle: "com.microsoft.edgemac", team: "UBF8T346G9", name: "Microsoft Edge"),
        Known(bundle: "com.brave.Browser", team: "KL8N8XSYF4", name: "Brave Browser"),
        Known(bundle: "com.vivaldi.Vivaldi", team: "4XF3XNRN6Y", name: "Vivaldi"),
        Known(bundle: "net.imput.helium", team: "S4Q33XPHB4", name: "Helium"),
        Known(bundle: "com.google.Chrome.beta", team: "EQHXZ8M8AV", name: "Google Chrome Beta"),
        Known(bundle: "com.google.Chrome.dev", team: "EQHXZ8M8AV", name: "Google Chrome Dev"),
        Known(bundle: "com.google.Chrome.canary", team: "EQHXZ8M8AV", name: "Google Chrome Canary"),
    ]

    static func known(_ bundle: String) -> Known? { browsers.first { $0.bundle.caseInsensitiveCompare(bundle) == .orderedSame } }

    /// What `choose` found for a run.
    enum Choice: Equatable {
        case browser(Known)
        /// None Petal can start is installed.
        case none
        /// The one the person's links open in is the only one there is, or the one `runBrowser` names (`named`):
        /// a run never gets that one.
        case theirs(Known, named: Bool)
    }

    /// Which of the `installed` browsers a run gets. Never the one the person's links open in (`standard`: macOS's
    /// own answer for an https address, read where this is asked): macOS takes a second copy of a running app for
    /// the app itself, so while theirs is closed a link they open anywhere would open in the run's copy. `setting`
    /// (`runBrowser`): the person's choice, when it's one Petal knows and it's installed. Else, of the others, one
    /// they don't have open comes first; then the list's order.
    static func choose(installed: [String], running: Set<String>, standard: String?, setting: String) -> Choice {
        let have = browsers.filter { known in installed.contains { $0.caseInsensitiveCompare(known.bundle) == .orderedSame } }
        guard !have.isEmpty else { return .none }
        func theirs(_ known: Known) -> Bool { standard?.caseInsensitiveCompare(known.bundle) == .orderedSame }
        let wanted = setting.trimmingCharacters(in: .whitespaces)
        if !wanted.isEmpty, let chosen = have.first(where: { $0.bundle.caseInsensitiveCompare(wanted) == .orderedSame || $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return theirs(chosen) ? .theirs(chosen, named: true) : .browser(chosen)
        }
        let open = Set(running.map { $0.lowercased() })
        var best: Known?
        for known in have where !theirs(known) {
            if best == nil || (open.contains(best!.bundle.lowercased()) && !open.contains(known.bundle.lowercased())) { best = known }
        }
        if let best { return .browser(best) }
        return have.first(where: theirs).map { .theirs($0, named: false) } ?? .none
    }

    /// The browser a run gets, or nil where it gets none (`choose`).
    static func pick(installed: [String], running: Set<String>, standard: String?, setting: String) -> Known? {
        if case .browser(let known) = choose(installed: installed, running: running, standard: standard, setting: setting) { return known }
        return nil
    }

    /// What the browser is started with. A profile of its own (signed in to nothing, no extensions, no sync), no
    /// first-run screens, no sound, no questions of its own (permissions, the default browser, restoring a crash),
    /// the Mac's Keychain left alone, and the DevTools pipe: no port is opened, so nothing else on the Mac can drive
    /// it. With a window (`frame`, the window server's coordinates): no window of its own at the start; Petal makes
    /// one at `frame` over the pipe, so it's never on the person's screen.
    static func arguments(profile: String, frame: CGRect?) -> [String] {
        var list = [
            "--remote-debugging-pipe",
            "--user-data-dir=" + profile,
            "--no-first-run", "--no-default-browser-check", "--disable-search-engine-choice-screen",
            "--disable-sync", "--disable-extensions", "--disable-component-extensions-with-background-pages",
            "--disable-default-apps", "--disable-background-networking", "--no-service-autorun",
            "--password-store=basic", "--use-mock-keychain",
            "--deny-permission-prompts", "--mute-audio",
            "--disable-session-crashed-bubble", "--hide-crash-restore-bubble", "--noerrdialogs", "--disable-breakpad",
            "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding", "--disable-background-timer-throttling",
            "--disable-features=Translate,MediaRouter,AutofillServerCommunication,OptimizationHints",
            // Its pages always have their accessibility tree, so a picture of the display is checked whole (Sensitive).
            "--force-renderer-accessibility",
        ]
        if let frame {
            list += ["--no-startup-window",
                     "--window-position=\(Int(frame.minX)),\(Int(frame.minY))", "--window-size=\(Int(frame.width)),\(Int(frame.height))"]
        } else {
            list.append("about:blank")
        }
        return list
    }

    /// The folder under Petal's own that holds every run's profile.
    static let folder = "run-browsers"

    /// A run's profile folder's name: who it's for, kept to plain characters, and something made up so two are never
    /// the same ("note-1F2A…-k3x9q2").
    static func folderName(group: String, nonce: String) -> String {
        func plain(_ text: String, _ most: Int) -> String {
            String(text.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }.map(Character.init).prefix(most))
        }
        let who = plain(group, 48)
        let tail = plain(nonce, 16)
        return (who.isEmpty ? "run" : who) + "-" + (tail.isEmpty ? "x" : tail)
    }

    /// `path` is a run's profile folder: right inside `root` (Petal's `run-browsers`), by a plain name. Only such a
    /// folder is ever removed.
    static func removable(_ path: String, root: String) -> Bool {
        let base = (root as NSString).standardizingPath, full = (path as NSString).standardizingPath
        guard !base.isEmpty, base != "/", full.hasPrefix(base + "/") else { return false }
        let name = String(full.dropFirst(base.count + 1))
        return isPlain(name)
    }

    /// A name `folderName` could have made: letters, digits and dashes only (so never ".", "..", or a path).
    static func isPlain(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 80
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    /// The profile folder a process was started with (`--user-data-dir=`), when it's one of a run's (inside `root`).
    static func profile(inArguments arguments: [String], root: String) -> String? {
        let base = (root as NSString).standardizingPath
        for argument in arguments where argument.hasPrefix("--user-data-dir=") {
            let path = (String(argument.dropFirst("--user-data-dir=".count)) as NSString).standardizingPath
            if removable(path, root: base) { return path }
        }
        return nil
    }

    /// What's left of run browsers nobody holds any more (Petal crashed, or was killed, while runs had theirs): the
    /// processes started with a profile inside `root` to end, and the profile folders to remove. `mine`: the profiles
    /// of browsers this Petal runs now, which are left alone.
    static func leftovers(processes: [(pid: Int32, arguments: [String])], folders: [String], root: String, mine: Set<String>)
        -> (end: [Int32], remove: [String]) {
        let base = (root as NSString).standardizingPath
        let kept = Set(mine.map { ($0 as NSString).standardizingPath })
        var end: [Int32] = []
        for process in processes {
            guard let profile = profile(inArguments: process.arguments, root: base), !kept.contains(profile) else { continue }
            end.append(process.pid)
        }
        var remove: [String] = []
        for name in folders.sorted() {
            let path = ((base as NSString).appendingPathComponent(name) as NSString).standardizingPath
            if removable(path, root: base), !kept.contains(path) { remove.append(path) }
        }
        return (end, remove)
    }

    // MARK: Addresses

    enum Address: Equatable {
        case go(String)
        case refuse(String)
    }

    static let addressRule = "A run's browser opens https addresses, and http ones on this Mac (localhost)."

    /// The address `open` goes to: https, or http on this Mac; a bare name gets https (http for this Mac). Anything
    /// else (a file, the browser's own pages, a script, a name and password in the address) is refused.
    static func address(_ text: String) -> Address {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else { return .refuse("Give one address to open. " + addressRule) }
        var full = trimmed
        if !trimmed.contains("://") {
            // "localhost:3000/x" reads as a scheme to a URL parser: its name decides here.
            let name = trimmed.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? trimmed
            let host = name.hasPrefix("[") ? String(name.dropFirst().prefix { $0 != "]" }) : String(name.prefix { $0 != ":" })
            guard !name.contains("@"), !host.isEmpty, !trimmed.lowercased().hasPrefix("javascript:"), !trimmed.lowercased().hasPrefix("data:"),
                  !trimmed.lowercased().hasPrefix("file:"), !trimmed.lowercased().hasPrefix("about:") else { return .refuse(addressRule) }
            full = (VaultSite.isLocal(host.lowercased()) ? "http://" : "https://") + trimmed
        }
        guard let parts = URLComponents(string: full), let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty else {
            return .refuse("That isn't an address. " + addressRule)
        }
        guard parts.user == nil, parts.password == nil else { return .refuse("Petal doesn't open an address with a name or password in it.") }
        let plain = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        switch scheme {
        case "https": return .go(full)
        case "http": return VaultSite.isLocal(plain) ? .go(full) : .refuse("\(host) isn't https. " + addressRule)
        default: return .refuse(addressRule)
        }
    }

    // MARK: Where a field is, for the vault

    /// A document as the browser reports it: its address, and its origin (whose it is). The two are different things:
    /// a document served from a site's own address may be kept apart from that site (sandboxed: an origin of its own,
    /// nobody's), and a frame with no address of its own (about:blank, srcdoc, a blob) is the site's that made it.
    struct Document: Equatable {
        var url: String
        /// As the browser's inspector gives it for the document's own script context: "https://example.com", or
        /// "://" or "null" for an origin that is nobody's. Empty: it didn't say.
        var origin: String

        init(url: String, origin: String) {
            self.url = url
            self.origin = origin
        }
    }

    /// An origin as scheme, host and port, when it names a web site (http or https); nil for an origin that is
    /// nobody's (opaque), one the browser didn't give, or anything that isn't a site.
    static func site(ofOrigin origin: String) -> (scheme: String, host: String, port: Int)? {
        let text = origin.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != "null", text != "://", let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.path.isEmpty || parts.path == "/", parts.query == nil, parts.user == nil else { return nil }
        return (scheme, host, parts.port ?? (scheme == "https" ? 443 : 80))
    }

    /// The address the vault goes by for a document, and whether the document is isolated from the site that address
    /// names. Its origin decides, never its address alone:
    /// - an origin that is nobody's (a sandboxed document or frame, a data: page), or none given: isolated;
    /// - a web address whose own scheme, host and port aren't the origin's: isolated (Petal can't say whose it is);
    /// - no web address of its own (about:blank, srcdoc, a blob) with a site's origin: that site's, at its root.
    static func effective(_ document: Document) -> (address: String, isolated: Bool) {
        guard let origin = site(ofOrigin: document.origin) else { return (document.url, true) }
        let root = origin.scheme + "://" + (origin.host.contains(":") ? "[" + origin.host + "]" : origin.host)
            + (origin.port == (origin.scheme == "https" ? 443 : 80) ? "" : ":" + String(origin.port)) + "/"
        guard let parts = URLComponents(string: document.url), let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return (root, false)
        }
        let host = (parts.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let port = parts.port ?? (scheme == "https" ? 443 : 80)
        let same = scheme == origin.scheme && host == origin.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) && port == origin.port
        return (document.url, !same)
    }

    /// Where a field of a page is, from what the browser itself said of it: `frame`, the document the field is in;
    /// `top`, the tab's whole page; `tab`, the browser's own record of the tab's address; `target` and `loader`,
    /// which tab it is and which document that tab shows (another document is another page). Each document goes by
    /// its origin (`effective`): one isolated from its site makes the place isolated, which the vault never takes for
    /// that site. `trusted`: the running browser is one Petal knows, signed by its maker; anywhere else the page
    /// can't be believed about its address (unverified), exactly as a page in a browser the person runs (Vault.surface).
    static func place(frame: Document, top: Document, tab: String?, target: String, loader: String, trusted: Bool, bundle: String, name: String) -> Vault.Place {
        var place = Vault.Place(bundle: bundle, appName: name)
        switch Vault.surface(webArea: true, trusted: trusted, browser: true) {
        case .web:
            let field = effective(frame), page = effective(top)
            place.web = true
            place.frameURL = field.address
            place.topURL = page.address
            place.tabURL = tab
            place.isolated = field.isolated || page.isolated
            place.tab.id = target
            place.tab.page = (target + "/" + loader) as NSString
        default:
            place.unverified = true
            place.claimedURL = frame.url
        }
        return place
    }

    // MARK: Keys

    /// A key as the protocol's key event names it.
    struct Key: Equatable {
        var key: String
        var code: String
        var number: Int
        /// What it types, for a key that types something.
        var text: String?
        var shift = false
    }

    private static let keys: [String: Key] = [
        "enter": Key(key: "Enter", code: "Enter", number: 13, text: "\r"), "return": Key(key: "Enter", code: "Enter", number: 13, text: "\r"),
        "tab": Key(key: "Tab", code: "Tab", number: 9), "escape": Key(key: "Escape", code: "Escape", number: 27),
        "esc": Key(key: "Escape", code: "Escape", number: 27),
        "up": Key(key: "ArrowUp", code: "ArrowUp", number: 38), "down": Key(key: "ArrowDown", code: "ArrowDown", number: 40),
        "left": Key(key: "ArrowLeft", code: "ArrowLeft", number: 37), "right": Key(key: "ArrowRight", code: "ArrowRight", number: 39),
        "backspace": Key(key: "Backspace", code: "Backspace", number: 8), "delete": Key(key: "Delete", code: "Delete", number: 46),
        "space": Key(key: " ", code: "Space", number: 32, text: " "),
        "pageup": Key(key: "PageUp", code: "PageUp", number: 33), "pagedown": Key(key: "PageDown", code: "PageDown", number: 34),
        "home": Key(key: "Home", code: "Home", number: 36), "end": Key(key: "End", code: "End", number: 35),
    ]

    static let keyNames = "enter, tab, shift-tab, escape, up, down, left, right, backspace, delete, space, pageup, pagedown, home or end"

    /// One of the keys a page is driven with (`keyNames`); shift only with tab. Nothing that types a letter: text
    /// goes in with `type`.
    static func key(_ name: String) -> Key? {
        var word = name.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "")
        var shift = false
        for prefix in ["shift-", "shift+", "⇧"] where word.hasPrefix(prefix) {
            shift = true
            word = String(word.dropFirst(prefix.count))
        }
        guard var key = keys[word], !shift || key.key == "Tab" else { return nil }
        key.shift = shift
        return key
    }

    // MARK: Downloads

    /// A run's browser saves nothing to the Mac: every download is refused, and the AI is told which one.
    static func downloadRefused(_ name: String, from address: String) -> String {
        let what = name.isEmpty ? "a file" : "“\(name)”"
        let host = URLComponents(string: address)?.host ?? ""
        return "The page tried to download \(what)\(host.isEmpty ? "" : " from \(host)"). A run's browser saves nothing to the Mac: it was refused. Tell the person the address if they'd want the file."
    }

    // MARK: The clipboard

    /// Something a page may ask the browser for, as the browser's remote control names it (Browser.setPermission).
    struct Permission: Equatable {
        let name: String
        /// Anything at all, not only plain text and pictures the browser cleans first.
        var unsanitized = false

        var descriptor: [String: Any] {
            unsanitized ? ["name": name, "allowWithoutSanitization": true] : ["name": name]
        }
    }

    /// What a run's browser refuses every page, whatever its site, from before its first page loads: putting
    /// anything on the clipboard by itself, and reading it. The clipboard is the person's, shared with everything
    /// on the Mac, and nobody is at a run's page to mean a copy. A browser gives the first to any page it shows
    /// without asking, so it's refused in so many words.
    static let refused: [Permission] = [
        Permission(name: "clipboard-write"),
        Permission(name: "clipboard-write", unsanitized: true),
        Permission(name: "clipboard-read"),
    ]

    /// One of them, as the request that refuses it for every site (no origin is named).
    static func refusal(_ permission: Permission) -> [String: Any] {
        ["permission": permission.descriptor, "setting": "denied"]
    }

    /// How long the clipboard is watched after a press went to a page (a click, a check, a submit, a key). A page
    /// can still copy with the browser's older command while it holds a press, which is about five seconds: that
    /// long, and a moment more.
    static let copyWatch: TimeInterval = 6

    static let copyCleared = "After a press of yours a page copied a saved secret (or more text than Petal can check for one); Petal cleared the clipboard. petal_vault fills a saved one where it's needed (action: fill)."

    // MARK: Words

    static let off = "A browser of your own needs hidden displays (runDisplays in Petal's settings), which are off; only the person turns them on. Use the person's own windows the usual way (petal_look, petal_ui), or your own web tools."
    static let none = "No browser Petal can start for a run is installed on this Mac (Google Chrome, Microsoft Edge, Brave, Vivaldi or Helium). Petal installs none. Use your own web tools, or the person's own windows (petal_look, petal_ui)."

    /// Why a run gets no browser though one Petal could start is installed: it's the one the person's links open in.
    static func theirs(_ name: String, named: Bool) -> String {
        let why = "Petal never starts a copy of that one for a run: while theirs is closed, a link they open anywhere would open in the run's copy."
        let rest = " Use your own web tools, or the person's own windows (petal_look, petal_ui)."
        if named {
            return "runBrowser in Petal's settings names \(name), the browser the person's links open in. \(why) Name another one that's installed, or leave it empty for Petal to pick." + rest
        }
        return "The only browser on this Mac that Petal can start for a run is \(name), the one the person's links open in. \(why) A run gets a browser of its own once another of Google Chrome, Microsoft Edge, Brave, Vivaldi or Helium is installed; Petal installs none." + rest
    }
    static let noPictures = "Pictures of a run's browser aren't built yet: read gives the page as text. petal_look with screenshot: \"screen\" is a picture of your display, checked for secrets."
    static let stale = "The page changed since that read (or it was read again): its ids are no use now. Call petal_browser read again."
}

// MARK: - A page, as text an AI can work from

/// One thing a page shows, as Petal's own script read it in the page (RunBrowserScript.swift), before any of it is
/// told to an AI.
struct PageNode: Equatable {
    /// text, heading, link, button, field, area, editor, select, checkbox, radio, item, file, frame.
    var kind = "text"
    /// What it says: a text's words, a control's name.
    var text = ""
    var value = ""
    var label = ""
    var placeholder = ""
    var hint = ""
    /// The page's own names for a field (name, id, autocomplete): never shown, only read for what the field holds.
    var ident = ""
    /// An input's type, or a role.
    var type = ""
    /// A password field (or one that was, when Petal first saw it).
    var secure = false
    /// Petal filled it from the vault.
    var filled = false
    var on: Bool?
    var disabled = false
    var focused = false
    var level = 0
    var href = ""
    var options: [String] = []
    var optionCount = 0
    /// Its place in its frame's list of elements, for acting on it; -1 for what can't be acted on.
    var handle = -1
    /// Which of the page's frames it's in (0: the page itself).
    var frame = 0
    /// What holds it, and its place there (any numbers that stand for them), and the line of text it's part of.
    var parent = -1
    var sibling = 0
    var block = 0
    var rect = CGRect.zero
    var inView = true
    /// A text that runs on from the one before it, or into the one after, with no space between.
    var joinsBefore = false
    var joinsAfter = false

    static let controls: Set<String> = ["link", "button", "field", "area", "editor", "select", "checkbox", "radio", "item", "file"]
    var isControl: Bool { Self.controls.contains(kind) }
    var takesText: Bool { ["field", "area", "editor"].contains(kind) }

    /// A node from the script's JSON (short keys, to keep a big page small).
    init?(_ json: [String: Any]) {
        guard let kind = json["k"] as? String else { return nil }
        func string(_ key: String) -> String { json[key] as? String ?? "" }
        func flag(_ key: String) -> Bool { (json[key] as? NSNumber)?.intValue == 1 }
        func number(_ key: String) -> Int? { (json[key] as? NSNumber)?.intValue }
        self.kind = kind
        text = string("t")
        value = string("v")
        label = string("l")
        placeholder = string("p")
        hint = string("h")
        ident = string("i")
        type = string("y")
        secure = flag("s")
        filled = flag("f")
        on = number("on").map { $0 == 1 }
        disabled = flag("d")
        focused = flag("fo")
        level = number("lv") ?? 0
        href = string("u")
        options = (json["o"] as? [Any] ?? []).compactMap { $0 as? String }
        optionCount = number("n") ?? options.count
        handle = number("e") ?? -1
        parent = number("pa") ?? -1
        sibling = number("sb") ?? 0
        block = number("b") ?? 0
        let r = (json["r"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        if r.count == 4 { rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }
        inView = json["iv"] == nil ? true : flag("iv")
        joinsBefore = flag("jb")
        joinsAfter = flag("ja")
        // A password field never comes with its value, whatever the script sent.
        if secure || filled { value = "" }
    }

    init(kind: String, text: String = "", value: String = "") {
        self.kind = kind
        self.text = text
        self.value = value
    }

    /// The node as Accessibility would describe it, so what an AI is told of it goes by the very rules `petal_ui`'s
    /// controls go by (UIMap.redact, UIMap.hideJoined). `order`: its place among everything read.
    func ui(order: Int) -> UINode {
        let role: String
        switch kind {
        case "text": role = "AXStaticText"
        case "heading": role = "AXHeading"
        case "link": role = "AXLink"
        case "field", "area", "editor": role = "AXTextField"
        case "select": role = "AXPopUpButton"
        case "checkbox", "radio": role = "AXCheckBox"
        case "frame": role = "AXGroup"
        default: role = "AXButton"
        }
        var node = UINode(role: role)
        if secure { node.subrole = "AXSecureTextField" }
        if kind == "text" { node.value = text } else { node.title = text }
        if kind != "text" { node.value = secure ? "" : value }
        node.label = label
        node.help = hint
        node.placeholder = placeholder
        node.identifier = ident
        node.frame = rect
        node.enabled = !disabled
        node.focused = focused
        node.web = true
        node.order = order
        // What holds it is its own frame's: two frames' numbers never meet.
        node.parent = parent < 0 ? -1 : frame * 10_000_000 + parent
        node.sibling = sibling
        return node
    }
}

/// A page as text: its content in reading order, with an id on everything that can be used (b1, b2…), in the spirit
/// of `petal_ui`. Capped, and it says what was left out. Never a password field's value; everything goes through the
/// vault's redaction as `petal_ui`'s controls do.
struct BrowserOutline {
    struct Ref: Equatable {
        var frame: Int
        var handle: Int
        var node: PageNode
    }

    var text = ""
    var refs: [String: Ref] = [:]
    /// How many controls got an id.
    var count = 0
    /// What was left out, in a sentence; empty when nothing was.
    var left = ""
    /// Something on the page was hidden as a secret.
    var hid = false

    /// The most controls given an id, the most of the page's words told (text and headings alike: one budget), and the
    /// most the controls' own lines may come to.
    static let cap = 200
    static let textCap = 14_000
    static let controlsCap = 30_000
    static let pieceCap = 600
    static let prefix = "b"

    /// A control's id ("b12"), or nil for anything else an AI might pass (a `petal_ui` id, a word).
    static func isID(_ text: String) -> Bool {
        text.hasPrefix(prefix) && text.count > 1 && text.dropFirst().allSatisfy(\.isNumber)
    }

    /// `nodes`: everything read, in reading order, each with its frame's number; `frames`: each frame's address (0:
    /// the page's). `find`: only what has this word. `cut`: the script stopped before the page's end.
    /// `redact`, `matches` and `spans` are the vault's (UIMap.SecretIndex); `going`: time's left to look for a secret
    /// shown in pieces.
    static func make(nodes: [PageNode], frames: [String], find: String = "", cut: Bool = false,
                     redact: (String) -> String, matches: (String) -> Bool, spans: ((String) -> [Range<Int>])? = nil,
                     going: () -> Bool = { true }) -> BrowserOutline {
        var outline = BrowserOutline()
        // As read, before anything is hidden: a secret several pieces show only together (a card number as four
        // fields) is found among them.
        let raw = nodes.enumerated().map { $0.element.ui(order: $0.offset) }
        let joined = UIMap.joinedHidden(raw, matches: matches, spans: spans, going: going).hidden
        var shown = nodes
        for index in nodes.indices {
            var ui = raw[index]
            if nodes[index].kind == "text" || nodes[index].kind == "heading" {
                // A page's own words: only the secret's part goes, the rest stays.
                if joined.contains(index) { UIMap.hideAll(&ui) }
                let before = nodes[index].kind == "text" ? ui.value : ui.title
                let after = before == UIMap.hidden ? before : redact(before)
                if after != before || before == UIMap.hidden { outline.hid = true }
                shown[index].text = after
                continue
            }
            let before = ui
            if joined.contains(index) || nodes[index].filled { UIMap.hideAll(&ui) }
            ui = UIMap.redact(ui, filled: nodes[index].filled, secret: matches)
            if ui != before { outline.hid = true }
            shown[index].text = ui.title
            shown[index].value = ui.value
            shown[index].label = ui.label
            shown[index].hint = ui.help
            shown[index].placeholder = ui.placeholder
            shown[index].options = nodes[index].options.map { matches($0) ? UIMap.hidden : $0 }
        }

        // Which controls get an id: all of them up to the cap; past it, the ones in view first.
        let word = UIMap.tidy(find).lowercased()
        func has(_ node: PageNode) -> Bool {
            word.isEmpty || [node.text, node.value, node.label, node.placeholder, node.hint].contains { $0.lowercased().contains(word) }
        }
        let controls = shown.indices.filter { shown[$0].isControl && shown[$0].handle >= 0 && has(shown[$0]) }
        var kept = Set(controls)
        if controls.count > cap {
            let inView = controls.filter { shown[$0].inView }
            let rest = controls.filter { !shown[$0].inView }
            kept = Set((inView + rest).prefix(cap))
        }

        var lines: [String] = []
        var told = 0
        var textLeft = 0
        var controlsTold = 0
        var controlsLeft = 0
        var run = ""
        var runOn = false
        var runKey: (frame: Int, block: Int)?
        var depth = 0
        func indent() -> String { String(repeating: "  ", count: depth) }
        func flush() {
            guard !run.isEmpty else { return }
            let line = UIMap.tidy(run)
            run = ""
            runOn = false
            runKey = nil
            guard !line.isEmpty else { return }
            if told >= textCap { textLeft += 1; return }
            told += line.count
            lines.append(indent() + line)
        }
        var frameOf = 0
        var depths: [Int: Int] = [0: 0]
        for index in shown.indices {
            let node = shown[index]
            // A frame's lines sit under its heading, a step in.
            if node.frame != frameOf {
                flush()
                frameOf = node.frame
                depth = depths[frameOf] ?? 0
            }
            switch node.kind {
            case "text":
                guard has(node) else { continue }
                if let key = runKey, key.frame != node.frame || key.block != node.block { flush() }
                runKey = (node.frame, node.block)
                // Pieces of one line, as the page spaces them: "check's" + "own" + ", served".
                if !run.isEmpty, !(runOn && node.joinsBefore) { run += " " }
                run += UIMap.truncate(node.text, pieceCap)
                runOn = node.joinsAfter
            case "heading":
                flush()
                guard has(node), !node.text.isEmpty else { continue }
                // A heading is text: the same budget, and past it it's counted as left out.
                if told >= textCap { textLeft += 1; continue }
                let heading = UIMap.truncate(UIMap.tidy(node.text), 300)
                told += heading.count
                lines.append(indent() + String(repeating: "#", count: min(max(node.level, 1), 6)) + " " + heading)
            case "frame":
                flush()
                // Its own number is its handle here: the frame it opens.
                let opened = node.handle
                guard opened > 0, opened < frames.count else { continue }
                depths[opened] = depth + 1
                lines.append(indent() + "▸ frame (\(place(frames[opened]))):")
            default:
                guard kept.contains(index) else { continue }
                flush()
                // The controls' lines have a budget of their own: past it the rest are counted as left out.
                if controlsTold >= controlsCap { controlsLeft += 1; continue }
                outline.count += 1
                let id = prefix + String(outline.count)
                outline.refs[id] = Ref(frame: node.frame, handle: node.handle, node: nodes[index])
                let said = line(id, node)
                controlsTold += said.count
                lines.append(indent() + said)
            }
        }
        flush()

        var left: [String] = []
        let more = controls.count - kept.count + controlsLeft
        if more > 0 { left.append("\(more) more controls (the ones in view came first)") }
        if textLeft > 0 { left.append("\(textLeft) more lines of text") }
        if cut { left.append("the end of a very long page") }
        if !left.isEmpty {
            outline.left = "Left out: " + left.joined(separator: ", ") + ". find: a word gives only what has it; scroll and read again for what comes into view."
        }
        // Once more over the whole: a secret the lines only make together never goes out either.
        let whole = lines.joined(separator: "\n")
        let checked = redact(whole)
        if checked != whole { outline.hid = true }
        outline.text = checked
        return outline
    }

    /// A frame's address as its heading says it: its site, never its whole address.
    static func place(_ address: String) -> String {
        guard let parts = URLComponents(string: address), let host = parts.host, !host.isEmpty else {
            return address.isEmpty ? "no address" : UIMap.truncate(address.components(separatedBy: ":").first ?? address, 20)
        }
        return (parts.scheme.map { $0 == "https" ? "" : $0 + "://" } ?? "") + host
    }

    /// Where a link goes, short: its site and path, without what follows a ? or #.
    static func target(_ address: String) -> String {
        guard !address.isEmpty, let parts = URLComponents(string: address) else { return "" }
        guard let host = parts.host, !host.isEmpty else { return UIMap.truncate(parts.scheme.map { $0 + ":" } ?? "", 20) }
        return UIMap.truncate(host + (parts.path == "/" ? "" : parts.path), 80)
    }

    /// One control's line: `[b3] field "Email" = "ada@example.com"`.
    static func line(_ id: String, _ node: PageNode) -> String {
        let name = [node.text, node.label, node.placeholder, node.hint].map(UIMap.tidy).first { !$0.isEmpty } ?? ""
        let named = name.isEmpty ? "" : " \"" + UIMap.truncate(name, 160) + "\""
        var out = "[\(id)] "
        switch node.kind {
        case "link":
            let to = target(node.href)
            out += "link" + named + (to.isEmpty ? "" : " → " + to)
        case "button": out += "button" + named
        case "item": out += (node.type.isEmpty ? "item" : node.type) + named
        case "file": out += "file chooser" + named + " (choosing a file isn't built)"
        case "field", "area", "editor":
            let what = node.secure ? "password field" : node.kind == "area" ? "text area" : node.kind == "editor" ? "editor"
                : ["", "text"].contains(node.type) ? "field" : node.type + " field"
            out += what + named
            if node.secure {
                out += node.filled ? " (filled by Petal)" : ""
            } else if node.filled {
                out += " (filled by Petal)"
            } else if !node.value.isEmpty {
                out += " = \"" + UIMap.truncate(UIMap.tidy(node.value), 200) + "\""
            } else if !name.isEmpty, !node.placeholder.isEmpty, UIMap.tidy(node.placeholder) != name {
                out += " (" + UIMap.truncate(UIMap.tidy(node.placeholder), 80) + ")"
            }
        case "select":
            out += "select" + named + (node.value.isEmpty ? "" : " = \"" + UIMap.truncate(UIMap.tidy(node.value), 120) + "\"")
            let few = node.options.prefix(12).map { UIMap.truncate(UIMap.tidy($0), 40) }
            if !few.isEmpty {
                let more = max(node.optionCount, node.options.count) - few.count
                out += " (options: " + few.joined(separator: ", ") + (more > 0 ? ", … \(more) more" : "") + ")"
            }
        case "checkbox", "radio":
            out += node.kind + named + (node.on == true ? " (on)" : " (off)")
        default: out += node.kind + named
        }
        if node.disabled { out += " (disabled)" }
        if node.focused { out += " (has the cursor)" }
        return out
    }

    /// What the script sent for one frame, as nodes: `more` when it stopped before the end.
    static func nodes(fromJSON text: String) -> (nodes: [PageNode], more: Bool, title: String, generation: Int)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let list = object["n"] as? [[String: Any]] else { return nil }
        return (list.compactMap { PageNode($0) }, (object["more"] as? NSNumber)?.intValue == 1, object["title"] as? String ?? "",
                (object["gen"] as? NSNumber)?.intValue ?? 0)
    }
}
