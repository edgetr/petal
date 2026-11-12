import AppKit
import ApplicationServices
import ScreenCaptureKit

/// `Petal --browser-check`: a run's own browser (RunBrowser.swift), driven for real without showing anything.
///
/// Headless (`Headless`), on throwaway folders it makes itself (`PETAL_CONFIG_DIR`, `PETAL_SUPPORT_DIR`,
/// `PETAL_NOTES`), with a made-up vault, a made-up display (none is ever created) and no socket. The browser is the
/// headless shell Playwright keeps in the person's caches (it has no window at all), started exactly as a run's
/// browser is: Petal's child, a profile of its own under Petal's folder, the DevTools pipe. The pages come from a
/// small server the check starts on this Mac (127.0.0.1 and localhost: two sites), and one made-up https shop the
/// check answers for inside the browser itself, so nothing leaves the Mac. Everything goes through the real tools
/// (`petal_browser`, `petal_vault`, as `Petal --mcp` hands them over) and the real cards (answered by the check).
/// One line per step; exits non-zero when any fails.
///
/// `Petal --browser-check --live <folder>`: the same browser code with a real hidden display and a real installed
/// browser, for whoever is at the Mac. It changes the screens for a few seconds: never run by a check, a bench, a
/// snapshot or an agent working alone.
@MainActor
enum BrowserCheck {
    static func run(live: String?) -> Never {
        // Each line as it's known, even into a file: a step that hangs is the one after the last line.
        setvbuf(stdout, nil, _IOLBF, 0)
        if let live { BrowserLiveCheck.run(folder: live) }
        Headless.on = true
        let checker = BrowserChecker()
        exit(checker.run() == 0 ? 0 : 1)
    }

    /// The headless shell a check drives: the newest one in Playwright's cache, or nil.
    static func headlessShell() -> String? {
        let cache = NSHomeDirectory() + "/Library/Caches/ms-playwright"
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: cache)) ?? []).filter { $0.hasPrefix("chromium_headless_shell-") }.sorted().reversed()
        for folder in folders {
            for kind in ["chrome-headless-shell-mac-arm64", "chrome-headless-shell-mac-x64", "chrome-mac"] {
                for name in ["chrome-headless-shell", "headless_shell"] {
                    let path = "\(cache)/\(folder)/\(kind)/\(name)"
                    if FileManager.default.isExecutableFile(atPath: path) { return path }
                }
            }
        }
        return nil
    }
}

/// A small web server on this Mac, for the check's own pages: it answers on 127.0.0.1 only, keeps what was posted
/// to it, and ends with the check.
final class CheckServer: @unchecked Sendable {
    private var socket: Int32 = -1
    private(set) var port: Int = 0
    private let lock = NSLock()
    private var posted: [(path: String, body: String)] = []
    private var hits: [String] = []
    var pages: @Sendable (_ path: String, _ port: Int) -> (type: String, body: String, headers: [String])? = { _, _ in nil }
    /// Called with each path asked for, before it's answered (on the thread that serves it).
    var onHit: (@Sendable (_ path: String) -> Void)?

    func start() -> Bool {
        socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(socket, 16) == 0 else { return false }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        port = Int(UInt16(bigEndian: address.sin_port))
        let listening = socket
        let thread = Thread { [weak self] in
            while true {
                let client = accept(listening, nil, nil)
                guard client >= 0 else { break }
                var off: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &off, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.global(qos: .userInitiated).async { self?.serve(client) }
            }
        }
        thread.name = "petal.browser-check.server"
        thread.start()
        return port > 0
    }

    func stop() {
        if socket >= 0 { close(socket) }
        socket = -1
    }

    var posts: [(path: String, body: String)] { lock.withLock { posted } }
    func hit(_ path: String) -> Int { lock.withLock { hits.filter { $0 == path }.count } }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var head: String?
        var wanted = 0
        while true {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if head == nil, let end = data.range(of: Data("\r\n\r\n".utf8)) {
                let text = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
                head = text
                data = data.subdata(in: end.upperBound..<data.endIndex)
                for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                    wanted = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            if head != nil, data.count >= wanted { break }
        }
        guard let head, let first = head.components(separatedBy: "\r\n").first else { return }
        let words = first.split(separator: " ")
        guard words.count >= 2 else { return }
        let method = String(words[0]), path = String(words[1])
        let plain = path.components(separatedBy: "?")[0]
        lock.withLock {
            hits.append(plain)
            if method == "POST" { posted.append((plain, String(decoding: data, as: UTF8.self))) }
        }
        onHit?(plain)
        var status = "200 OK", type = "text/html; charset=utf-8", body = "", extra: [String] = []
        if let page = pages(path, port) {
            type = page.type
            body = page.body
            extra = page.headers
        } else {
            status = "404 Not Found"
            body = "<h1>Not here</h1>"
        }
        let bytes = Data(body.utf8)
        var answer = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for line in extra { answer += line + "\r\n" }
        answer += "\r\n"
        var out = Data(answer.utf8)
        out.append(bytes)
        out.withUnsafeBytes { raw in
            var at = raw.baseAddress!
            var left = raw.count
            while left > 0 {
                let wrote = write(client, at, left)
                guard wrote > 0 else { return }
                at += wrote
                left -= wrote
            }
        }
    }
}

@MainActor
private final class BrowserChecker {
    let fm = FileManager.default
    let root: URL, config: URL, support: URL, notes: URL
    let app: PetalApp
    let server = CheckServer()
    var failures = 0
    private var problems: [String] = []
    /// Every answer a tool gave, as it would go to the AI.
    private var answers: [String] = []
    /// Every card that showed: its kind, title and the word on its yes button.
    private var cards: [(kind: String, title: String, allow: String, warn: Bool, owner: String?, detail: String)] = []
    /// Cards a step keeps open on purpose (to do something while the person hasn't answered yet).
    private var held: Set<UUID> = []
    private var made: [CGDirectDisplayID] = []
    private var removed: [CGDirectDisplayID] = []
    let who = AgentAccess.Caller(agent: .petal, host: nil, project: "")
    let caller = "mcp-\(getpid())"

    // Made-up secrets in the made-up vault: none looks like a real service's.
    let password = "pw-Zx81-made-up-93Lq"
    let key = "petalcheck7Q2v9Lr4Xs8Tn"
    let cardNumber = "4242424242424242"
    let code = "737"
    var loginID = ""
    var cardID = ""

    init() {
        let made = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "petal-browser-check-\(getpid())")
        try? FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        let real = made.path.withCString { realpath($0, nil) }.map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? made.path
        root = URL(fileURLWithPath: real)
        config = root.appending(path: "config")
        support = root.appending(path: "support")
        notes = root.appending(path: "notes")
        for folder in [config, support, notes] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        // Its own folders, before anything reads a setting or a file of Petal's.
        setenv("PETAL_CONFIG_DIR", config.path, 1)
        setenv("PETAL_SUPPORT_DIR", support.path, 1)
        setenv("PETAL_NOTES", notes.path, 1)
        guard Config.folder.path == config.path, Config.supportFolder.path == support.path else {
            print("FAIL  set up: Petal's folders were read before the check could point them at its own; nothing was run")
            exit(1)
        }
        let settings: [String: Any] = ["aiProviders": [String](), "ai": false, "notes": false, "computerUse": true, "runDisplays": true, "runDisplaysLimit": 1]
        try? JSONSerialization.data(withJSONObject: settings).write(to: config.appending(path: "settings.json"))
        var login = VaultItem(kind: .login, title: "Check shop", sites: ["127.0.0.1"])
        login[.username] = "ada@example.com"
        login[.password] = password
        var apiKey = VaultItem(kind: .apiKey, title: "Check key", sites: ["example.com"])
        apiKey[.value] = key
        var card = VaultItem(kind: .card, title: "Check card")
        card[.name] = "Ada Example"
        card[.number] = cardNumber
        card[.expiry] = "04/31"
        card[.securityCode] = code
        loginID = login.id
        cardID = card.id
        VaultStore.standIn([login, apiKey, card])
        app = PetalApp()
    }

    // MARK: Driving

    @discardableResult
    func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while true {
            if done() { return true }
            if Date() >= end { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        if !ok { problems.append(what()) }
    }

    private var steps = 0

    func step(_ title: String, _ body: () -> String) {
        steps += 1
        let number = String(steps)
        problems = []
        let began = Date()
        let detail = body() + String(format: " (%.1f s)", Date().timeIntervalSince(began))
        // Nothing is shown: no window of Petal's came on screen.
        let shown = NSApp.windows.filter(\.isVisible)
        expect(shown.isEmpty, "a window came on screen: " + shown.map { "\(Swift.type(of: $0))" }.joined(separator: ", "))
        if problems.isEmpty {
            print("ok    \(number)  \(title): \(detail)")
        } else {
            failures += 1
            print("FAIL  \(number)  \(title): " + problems.joined(separator: "; "))
        }
    }

    /// One tool call, as `Petal --mcp` hands it to the running Petal; a card that shows meanwhile is answered
    /// (`answer`: each card in turn, the last again for any more; none: Don't).
    /// `typed`: what the person types into a card that asks for it (the vault's). `asker`: who Petal read off the
    /// socket (Petal's own chat, unless the step is about an agent outside it).
    func call(_ tool: String, _ args: [String: Any], answer: [Assist.Choice] = [], typed: VaultForm.Answer? = nil, asker: AgentAccess.Caller? = nil,
              task: String = "check", timeout: Double = 40) -> [String: Any] {
        var all = args
        all["task"] = task
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: all)) ?? Data("{}".utf8), as: UTF8.self)
        var reply: String?
        var choices = answer
        var seen: Set<UUID> = []
        app.assist.handle(tool, json, note: caller, who: asker ?? who) { reply = $0 }
        let finished = wait(timeout) {
            if let pending = self.app.assist.pending, !self.held.contains(pending.id), seen.insert(pending.id).inserted {
                self.cards.append((pending.kind, pending.title, pending.allow, pending.warn, pending.owner, pending.detail))
                let choice = choices.isEmpty ? Assist.Choice.no : (choices.count > 1 ? choices.removeFirst() : choices[0])
                self.app.assist.choose(choice, typed: pending.form == nil ? nil : typed, for: pending.id)
            }
            return reply != nil
        }
        guard finished, let reply else { return ["error": "the tool never answered (\(Int(timeout)) s)"] }
        answers.append(reply)
        return (try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]) ?? ["error": "not JSON: \(reply.prefix(200))"]
    }

    /// A call begun and not waited for: its answer, once it has one.
    final class Begun {
        var reply: [String: Any]?
    }

    func begin(_ tool: String, _ args: [String: Any], asker: AgentAccess.Caller? = nil, task: String = "check") -> Begun {
        var all = args
        all["task"] = task
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: all)) ?? Data("{}".utf8), as: UTF8.self)
        let begun = Begun()
        app.assist.handle(tool, json, note: caller, who: asker ?? who) { text in
            self.answers.append(text)
            begun.reply = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? ["error": "not JSON: \(text.prefix(200))"]
        }
        return begun
    }

    /// Lets begun calls go on until `done`; a card that shows meanwhile is answered `answer`, or with none kept open
    /// (`held`) for the step to answer itself.
    @discardableResult
    func pump(_ seconds: Double, answer: Assist.Choice?, until done: @escaping () -> Bool) -> Bool {
        wait(seconds) {
            if let pending = self.app.assist.pending, !self.held.contains(pending.id) {
                self.cards.append((pending.kind, pending.title, pending.allow, pending.warn, pending.owner, pending.detail))
                if let answer { self.app.assist.choose(answer, for: pending.id) } else { self.held.insert(pending.id) }
            }
            return done()
        }
    }

    /// The processes started with a profile of a run's under this check's own folder.
    func runProcesses() -> [Int32] {
        RunBrowsers.processes().filter { RunBrowserRules.profile(inArguments: $0.arguments, root: RunBrowsers.root) != nil }.map(\.pid)
    }

    func profileFolders() -> [String] { (try? fm.contentsOfDirectory(atPath: RunBrowsers.root)) ?? [] }

    func browser(_ action: String, _ args: [String: Any] = [:], answer: [Assist.Choice] = [], task: String = "check", timeout: Double = 40) -> [String: Any] {
        var all = args
        all["action"] = action
        return call("petal_browser", all, answer: answer, task: task, timeout: timeout)
    }

    func page(_ reply: [String: Any]) -> String { reply["page"] as? String ?? "" }
    func error(_ reply: [String: Any]) -> String { reply["error"] as? String ?? "" }

    /// The id of the control whose line has `words` ("field \"Email\""), in a page as read.
    func id(_ words: String, in text: String) -> String {
        for line in text.components(separatedBy: "\n") where line.contains(words) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), let end = trimmed.firstIndex(of: "]") { return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end]) }
        }
        return ""
    }

    func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    var current: RunBrowser? { app.runBrowsers.browser(for: caller) }
    /// No press is still being watched for what its page copies (each watch ends by itself, in seconds).
    func settled() -> Bool { wait(10) { self.app.runBrowsers.copyWatches == 0 } }
    func base(_ host: String = "127.0.0.1") -> String { "http://\(host):\(server.port)" }

    // MARK: The pages

    static func pages(secret: String) -> @Sendable (String, Int) -> (type: String, body: String, headers: [String])? {
        return { path, port in
            let plain = path.components(separatedBy: "?")[0]
            func html(_ title: String, _ body: String) -> (type: String, body: String, headers: [String]) {
                ("text/html; charset=utf-8", "<!doctype html><html><head><title>\(title)</title></head><body>\(body)</body></html>", [])
            }
            switch plain {
            case "/":
                return html("Check home", """
                <h1>Petal check</h1>
                <p>A page of the check's <b>own</b>, served on this Mac.</p>
                <p id="out">Nothing pressed yet.</p>
                <button id="press" onclick="document.getElementById('out').textContent = 'Pressed once.'">Press me</button>
                <a href="/two">Second page</a>
                <a href="/two" target="_blank">Second page in a new tab</a>
                <a href="/file">Get the file</a>
                <label for="q">Search</label><input id="q" name="q" oninput="document.getElementById('echo').textContent = 'You typed: ' + this.value">
                <p id="echo"></p>
                <label for="color">Color</label>
                <select id="color" onchange="document.getElementById('picked').textContent = 'Picked ' + this.value"><option value="r">Red</option><option value="g">Green</option><option value="b">Blue</option></select>
                <p id="picked"></p>
                <label><input type="checkbox" id="agree" onchange="document.getElementById('agreed').textContent = this.checked ? 'Agreed.' : 'Not agreed.'"> I agree</label>
                <p id="agreed"></p>
                <p>The key on file is \(secret) (shown by the page).</p>
                <label for="pw">Old password</label><input id="pw" type="password" value="letmein-shown-by-page">
                <iframe src="http://localhost:\(port)/frame" width="420" height="120" title="Other site"></iframe>
                """)
            case "/frame":
                return html("Frame", "<p>Inside the frame.</p><form><label for=\"fu\">Frame user</label><input id=\"fu\" name=\"username\"><label for=\"fp\">Frame password</label><input id=\"fp\" type=\"password\" name=\"password\"></form>")
            case "/two":
                return html("Second page", "<h1>Second page</h1><p>You got here.</p><a href=\"/\">Home</a>")
            case "/file":
                return ("application/octet-stream", "not for saving", ["Content-Disposition: attachment; filename=\"check.bin\""])
            case "/keys":
                return html("Keys", "<h1>Keys</h1><form action=\"/two\" method=\"get\"><label for=\"k\">Word</label><input id=\"k\" name=\"k\" onkeydown=\"document.getElementById('log').textContent += ' ' + event.key\"></form><p id=\"log\">Keys:</p>")
            case "/alert":
                return html("Alert", "<h1>Alert</h1><button onclick=\"alert('The page says hello'); document.getElementById('after').textContent = 'After the message.'\">Say it</button><p id=\"after\"></p>")
            case "/login":
                return html("Sign in", """
                <h1>Sign in</h1>
                <form action="/session" method="post">
                <label for="user">Email</label><input id="user" name="username" autocomplete="username">
                <label for="pass">Password</label><input id="pass" name="password" type="password" autocomplete="current-password">
                <button type="submit">Sign in</button>
                </form>
                """)
            case "/session":
                return html("Signed in", "<h1>Signed in</h1><p>Welcome back.</p>")
            case "/signup":
                return html("Sign up", """
                <h1>Sign up</h1>
                <form action="/session" method="post">
                <label for="nu">Email</label><input id="nu" name="username" autocomplete="username">
                <label for="np">New password</label><input id="np" name="password" type="password" autocomplete="new-password">
                <label for="nc">Again</label><input id="nc" name="confirm" type="password" autocomplete="new-password">
                <button type="submit">Create account</button>
                </form>
                """)
            case "/sandboxed-login":
                // The saved site's own address, but a document the browser keeps apart from that site.
                return ("text/html; charset=utf-8", """
                <!doctype html><html><head><title>Sign in (sandboxed)</title></head><body><h1>Sign in</h1>
                <form action="/session" method="post"><label for="user">Email</label><input id="user" name="username">
                <label for="pass">Password</label><input id="pass" name="password" type="password"></form></body></html>
                """, ["Content-Security-Policy: sandbox allow-scripts allow-forms"])
            case "/holds-sandboxed":
                return html("Holds a sandboxed frame", "<h1>Holder</h1><iframe sandbox=\"allow-scripts allow-forms\" src=\"/login\" width=\"500\" height=\"220\"></iframe>")
            case "/holds-srcdoc":
                return html("Holds a frame with no address", "<h1>Holder</h1><iframe id=\"s\" width=\"500\" height=\"120\" srcdoc=\"<form><label for=sp>Inner password</label><input id=sp type=password></form>\"></iframe>")
            case "/swap":
                return html("Swap", """
                <h1>Swap</h1>
                <form id="f" action="/session" method="post">
                <label for="user">Email</label><input id="user" name="username">
                <label for="pass">Password</label><input id="pass" name="password" type="password">
                <label for="other">Recovery phrase</label><input id="other" name="other" type="password">
                </form>
                <script>function swapFields(){ var f = document.getElementById('f'), p = document.querySelector('label[for=pass]');
                f.insertBefore(document.querySelector('label[for=other]'), p); f.insertBefore(document.getElementById('other'), p); return 'swapped'; }</script>
                """)
            case "/framed":
                return html("Framed", "<h1>Framed</h1><iframe id=\"f\" src=\"/login\" width=\"500\" height=\"220\"></iframe>")
            case "/headings":
                var body = ""
                let long = String(repeating: "A long heading that goes on and on. ", count: 8)
                for index in 1...4000 { body += "<h2>Heading \(index): \(long)</h2>" }
                return html("Headings", "<h1>First of many</h1>" + body + "<p>The end.</p><a href=\"/two\">A link after them</a>")
            case "/pay":
                return html("Pay (not secure)", "<h1>Pay</h1><label for=\"num\">Card number</label><input id=\"num\" name=\"cardnumber\" autocomplete=\"cc-number\">")
            case "/big":
                var body = "<h1>Many links</h1>"
                for index in 1...320 { body += "<p><a href=\"/two?n=\(index)\">Link number \(index)</a></p>" }
                return html("Big", body)
            case "/clip":
                // A page that goes for the clipboard by itself, when it loads and on a press, and says what came of
                // it. The headless shell keeps a clipboard of its own, so the copy a real browser would let a page
                // make on a press (its older copy command) is stood in for: the page tells the check's server, which
                // puts it on the check's clipboard.
                return html("Clip", """
                <h1>Clip</h1>
                <p id="load">On load: waiting.</p><p id="press">On a press: nothing yet.</p><p id="state">Permission: unknown.</p>
                <button onclick="tryWrite('press', 'On a press'); fetch('/copied-secret')">Copy the password</button>
                <button onclick="fetch('/copied-words')">Copy the words</button>
                <label for="k">Hot field</label><input id="k" onkeydown="fetch('/copied-secret')">
                <script>
                function tryWrite(id, words) {
                    navigator.clipboard.writeText('written by the page').then(function () { document.getElementById(id).textContent = words + ': written.'; },
                        function () { document.getElementById(id).textContent = words + ': refused.'; });
                }
                tryWrite('load', 'On load');
                navigator.permissions.query({ name: 'clipboard-write' }).then(function (status) { document.getElementById('state').textContent = 'Permission: ' + status.state + '.'; });
                </script>
                """)
            case "/copied-secret", "/copied-words":
                return ("text/plain; charset=utf-8", "ok", [])
            case "/slow":
                return html("Slow", "<h1>Slow</h1><p id=\"late\"></p><script>setTimeout(function(){ document.getElementById('late').textContent = 'It arrived.'; }, 700)</script>")
            default:
                return nil
            }
        }
    }

    /// The made-up https shop, answered inside the browser itself (no request leaves it).
    static let shop = """
    <!doctype html><html><head><title>Checkout</title></head><body>
    <h1>Checkout</h1><p>Total: 12.00</p>
    <label for="num">Card number</label><input id="num" name="cardnumber" autocomplete="cc-number">
    <label for="exp">Expiry</label><input id="exp" name="exp" placeholder="MM/YY" autocomplete="cc-exp">
    <label for="cvc">Security code</label><input id="cvc" name="cvc" autocomplete="cc-csc">
    <button id="order" onclick="document.getElementById('placed').textContent = 'Order placed.'">Place order</button><p id="placed"></p>
    </body></html>
    """

    /// The browser answers for https://shop.example itself with the check's page: the address is a real https one to
    /// the vault's rules, and nothing goes to any network.
    /// The shop's checkout with a security code field whose own focus handler moves the page on.
    static let shopTrap = shop.replacingOccurrences(of: "<input id=\"cvc\"", with: "<input id=\"cvc\" onfocus=\"history.pushState({}, '', '/checkout/elsewhere')\"")

    func serveShop(_ browser: RunBrowser) {
        let plain = Data(Self.shop.utf8).base64EncodedString(), trap = Data(Self.shopTrap.utf8).base64EncodedString()
        let pipe = browser.pipe
        browser.onOther = { method, params, session in
            guard method == "Fetch.requestPaused", let id = params["requestId"] as? String else { return }
            let address = (params["request"] as? [String: Any])?["url"] as? String ?? ""
            var headers: [[String: String]] = [["name": "Content-Type", "value": "text/html; charset=utf-8"]]
            // The shop's own address, kept apart from the shop by the browser.
            if address.contains("/sandboxed/") { headers.append(["name": "Content-Security-Policy", "value": "sandbox allow-scripts allow-forms"]) }
            pipe.post("Fetch.fulfillRequest", ["requestId": id, "responseCode": 200, "responseHeaders": headers,
                                                "body": address.contains("/trap") ? trap : plain], session: session)
        }
        if let session = browser.checkSession {
            _ = browser.pipe.call("Fetch.enable", ["patterns": [["urlPattern": "https://shop.example/*"]]], session: session)
        }
    }

    // MARK: The steps

    func run() -> Int {
        guard let shell = BrowserCheck.headlessShell() else {
            print("FAIL  set up: no headless browser to drive (Playwright's chromium_headless_shell isn't in ~/Library/Caches/ms-playwright); nothing was run")
            return 1
        }
        server.pages = Self.pages(secret: key)
        guard server.start() else {
            print("FAIL  set up: the check's own server couldn't start; nothing was run")
            return 1
        }
        defer {
            server.stop()
            try? fm.removeItem(at: root)
        }
        // Made-up displays: nothing real is made, nothing is arranged.
        var next: CGDirectDisplayID = 9100
        app.displays.useMadeUp({ _, _, _ in
            next += 1
            let id = next
            self.made.append(id)
            return RunDisplays.Made(id: id, hiDPI: true, remove: { self.removed.append(id) })
        }, placed: { _, size in
            RunDisplays.Placing(frame: CGRect(x: -30_000, y: -30_000, width: size.width, height: size.height), tried: [])
        })
        // The headless shell stands in for the person's browser: no window, every frame of another site in a
        // process of its own (as the browsers people use do), and no maker's signature to check, so the check says
        // it's verified (only here).
        app.runBrowsers.finder = { _ in
            .success(RunBrowser.Spec(bundle: "org.chromium.headless-shell", name: "Check browser", executable: shell, headless: true,
                                     extra: ["--site-per-process", "--disable-gpu"], verify: { _ in true }))
        }
        // A clipboard of the check's own, and its own word that nobody is typing: the person's is never read or
        // changed, and what they do at the Mac meanwhile changes no step.
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        app.runBrowsers.clipboard = clipboard
        app.runBrowsers.copyHands = { false }
        let profiles = URL(fileURLWithPath: RunBrowsers.root)

        var pid: pid_t = 0
        var profile = ""
        step("open: asked once, then a browser of its own") {
            let none = browser("read")
            expect(error(none).contains("no browser open"), "read before open says there's none (\(none))")
            expect(cards.isEmpty && made.isEmpty, "and asks nobody, makes nothing")
            let refused = browser("open", ["address": "http://example.com/"])
            expect(error(refused).contains("https") && cards.isEmpty, "http elsewhere is refused before anyone is asked (\(error(refused)))")
            let file = browser("open", ["address": "file:///etc/hosts"])
            expect(!error(file).isEmpty && cards.isEmpty, "a file is refused")
            let declined = browser("open", ["address": base() + "/"], answer: [.no])
            expect(declined["declined"] != nil && made.isEmpty && current == nil, "Don't: no display, no browser (\(declined))")
            let opened = browser("open", ["address": base() + "/"], answer: [.once])
            expect(cards.count == 2 && cards.last?.kind == RunBrowsers.kind && cards.last?.owner == caller, "the card is the browser's own, owned by its asker (\(cards.map(\.title)))")
            expect(error(opened).isEmpty, "it opened (\(error(opened)))")
            expect(made.count == 1, "its display came first (\(made.count) made)")
            expect((opened["title"] as? String) == "Check home" && (opened["address"] as? String)?.hasPrefix(base()) == true, "the page's title and address (\(opened["title"] ?? "none"))")
            guard let browser = current else { expect(false, "the run has a browser"); return "" }
            pid = browser.pid
            profile = browser.profile
            expect(alive(pid) && RunBrowsers.isRun(pid), "its process runs, and is known as a run's")
            expect(profile.hasPrefix(profiles.path + "/") && fm.fileExists(atPath: profile), "its profile is a folder of its own under Petal's (\(profile))")
            let arguments = PetalProcess.arguments(of: pid) ?? []
            expect(arguments.contains("--remote-debugging-pipe") && !arguments.contains { $0.hasPrefix("--remote-debugging-port") }, "driven over the pipe: no port is open")
            expect(arguments.contains("--user-data-dir=" + profile) && arguments.contains("--mute-audio"), "started with its own profile, muted")
            let again = self.browser("read")
            expect(cards.count == 2 && error(again).isEmpty, "a second use in the reply asks nobody")
            return "Don't made nothing; Allow started pid \(pid) with a profile of its own, over the pipe"
        }

        var home = ""
        step("read: the page as text, with ids, without secrets") {
            let read = browser("read")
            home = page(read)
            expect(home.contains("# Petal check") && home.contains("A page of the check's own, served on this Mac."), "its heading and words, a line as one line")
            for words in ["button \"Press me\"", "link \"Second page\" → 127.0.0.1/two", "field \"Search\"", "select \"Color\" = \"Red\" (options: Red, Green, Blue)", "checkbox \"I agree\" (off)"] {
                expect(home.contains(words) && !id(words, in: home).isEmpty, "it lists \(words) with an id")
            }
            expect(home.contains("password field \"Old password\"") && !home.contains("letmein-shown-by-page"), "a password field is listed, its value never")
            expect(home.contains("(hidden)") && !home.contains(key), "a secret saved in the vault shows as (hidden)")
            expect(home.contains("▸ frame (http://localhost):") && home.contains("  Inside the frame."), "another site's frame is read, under its site")
            expect(!id("field \"Frame user\"", in: home).isEmpty, "with ids for its fields")
            let found = browser("read", ["find": "frame"])
            expect(page(found).contains("Frame user") && !page(found).contains("Press me"), "find gives only what has the word")
            _ = browser("open", ["address": base() + "/big"])
            let big = browser("read")
            expect((big["controls"] as? Int) == BrowserOutline.cap && (big["left"] as? String)?.contains("120 more controls") == true, "a long page is capped and says what's left out (\(big["controls"] ?? "none"), \(big["left"] ?? "nothing"))")
            _ = browser("open", ["address": base() + "/"])
            home = page(browser("read"))
            return "headings, text, \(home.components(separatedBy: "\n").filter { $0.contains("[b") }.count) controls with ids, a frame of another site; the vault's key hidden, no password value; 320 links capped at \(BrowserOutline.cap)"
        }

        step("click") {
            let pressed = browser("click", ["id": id("button \"Press me\"", in: home)])
            expect(error(pressed).isEmpty && (pressed["done"] as? String)?.contains("Press me") == true, "it pressed (\(pressed))")
            expect(page(browser("read")).contains("Pressed once."), "the page changed as its button says")
            let stale = browser("click", ["id": "b999"])
            expect(error(stale).contains("no b999"), "an id that isn't there says so")
            home = page(browser("read"))
            let went = browser("click", ["id": id("link \"Second page\" → 127.0.0.1/two", in: home)])
            expect((went["address"] as? String)?.hasSuffix("/two") == true, "a link goes to its page (\(went["address"] ?? "none"))")
            let old = browser("click", ["id": "b1"])
            expect(error(old).contains("changed since that read"), "ids from the page before are no use (\(error(old)))")
            let back = browser("back")
            expect((back["address"] as? String) == base() + "/", "back goes back (\(back["address"] ?? "none"))")
            home = page(browser("read"))
            return "a button pressed, a link followed, old ids refused, back"
        }

        step("type, select, check") {
            let typed = browser("type", ["id": id("field \"Search\"", in: home), "text": "tulips"])
            expect((typed["value"] as? String) == "tulips", "it typed, and says what the field reads (\(typed))")
            let secret = browser("type", ["id": id("password field \"Old password\"", in: home), "text": "nope"])
            expect(error(secret).contains("password field") && error(secret).contains("petal_vault"), "a password field is the vault's (\(error(secret)))")
            expect(current?.checkEvaluate("document.getElementById('pw').value") == "letmein-shown-by-page", "and wasn't touched")
            let picked = browser("select", ["id": id("select \"Color\"", in: home), "choice": "Blue"])
            expect((picked["done"] as? String)?.contains("Blue") == true, "it chose (\(picked))")
            let none = browser("select", ["id": id("select \"Color\"", in: home), "choice": "Mauve"])
            expect(error(none).contains("Red, Green, Blue"), "no such option lists the ones there are")
            let checked = browser("check", ["id": id("checkbox \"I agree\"", in: home)])
            expect((checked["done"] as? String)?.contains("is on") == true, "it checked (\(checked))")
            let after = page(browser("read"))
            for words in ["You typed: tulips", "Picked b", "Agreed.", "field \"Search\" = \"tulips\"", "checkbox \"I agree\" (on)", "select \"Color\" = \"Blue\""] {
                expect(after.contains(words), "the page shows \(words)")
            }
            // A key that would be a secret, typed by the AI itself, is hidden the moment the vault knows it.
            let echoed = browser("type", ["id": id("field \"Search\"", in: after), "text": key])
            expect((echoed["value"] as? String) == UIMap.hidden, "what a field reads is hidden when it holds a secret (\(echoed["value"] ?? "none"))")
            home = page(browser("read"))
            expect(!home.contains(key), "and so is the page that echoes it")
            return "typed, chosen and checked, each seen by the page; a password field refused"
        }

        step("key, wait") {
            _ = browser("open", ["address": base() + "/keys"])
            var read = page(browser("read"))
            let word = id("field \"Word\"", in: read)
            _ = browser("type", ["id": word, "text": "go"])
            let tab = browser("key", ["key": "down", "id": word])
            expect(error(tab).isEmpty, "a key went to the field (\(tab))")
            read = page(browser("read"))
            expect(read.contains("Keys: ArrowDown"), "the page heard it (\(read.components(separatedBy: "\n").last ?? ""))")
            let wrong = browser("key", ["key": "cmd-q"])
            expect(error(wrong).contains("enter, tab"), "only the keys a page is driven with")
            let enter = browser("key", ["key": "enter", "id": id("field \"Word\"", in: read)])
            expect((enter["address"] as? String)?.contains("/two?k=go") == true, "Enter sent the form (\(enter["address"] ?? "none"))")
            _ = browser("open", ["address": base() + "/slow"])
            let waited = browser("wait", ["text": "It arrived.", "seconds": 5])
            expect((waited["done"] as? String) == "The page shows that now.", "wait waits for words (\(waited))")
            let never = browser("wait", ["text": "It never comes", "seconds": 1])
            expect((never["done"] as? String)?.contains("didn't show") == true, "and gives up at its bound")
            return "a key into a field, Enter sending its form, wait for words with a bound"
        }

        step("tabs, a page's own message, a download") {
            _ = browser("open", ["address": base() + "/"])
            let second = browser("open", ["address": base() + "/two", "new_tab": true])
            expect((second["tab"] as? String) == "t2 of 2", "a new tab (\(second["tab"] ?? "none"))")
            let list = browser("tabs")["tabs"] as? [[String: Any]] ?? []
            expect(list.count == 2 && list.last?["current"] as? Bool == true, "tabs lists both, the new one current")
            // (The tab named as an id, as an AI may well write it.)
            let switched = browser("tab", ["id": "t1"])
            expect(error(switched).isEmpty, "tab takes the tab's name as id too (\(error(switched)))")
            home = page(browser("read"))
            expect(home.contains("# Petal check"), "tab works in the first again")
            let closed = browser("close_tab", ["tab": "t2"])
            expect((closed["tabs"] as? [[String: Any]])?.count == 1, "close_tab closed it")
            let opener = browser("click", ["id": id("link \"Second page in a new tab\"", in: home)])
            expect((opener["happened"] as? [String])?.contains { $0.contains("opened a new tab") } == true, "a tab the page opened is said, and left alone (\(opener))")
            expect((opener["address"] as? String) == base() + "/", "the tab worked in stays")
            home = page(browser("read"))
            let download = browser("click", ["id": id("link \"Get the file\"", in: home)])
            let happened = (download["happened"] as? [String] ?? []).joined(separator: " ")
            expect(happened.contains("check.bin") && happened.contains("refused"), "a download is refused and said (\(download))")
            let saved = (fm.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix("check.bin") }
            expect(saved.isEmpty, "nothing was saved")
            _ = browser("open", ["address": base() + "/alert"])
            let said = browser("click", ["id": id("button \"Say it\"", in: page(browser("read")))])
            expect((said["happened"] as? [String])?.contains { $0.contains("The page says hello") } == true, "a page's message is closed and told (\(said))")
            expect(page(browser("read")).contains("After the message."), "and the page went on")
            let picture = browser("picture")
            expect(error(picture) == RunBrowserRules.noPictures, "no pictures yet, said plainly")
            return "a second tab, switched and closed; a tab the page opened; a download refused; a message closed"
        }

        step("the vault: a login on its own site, never told") {
            _ = browser("open", ["address": base() + "/login"])
            let read = page(browser("read"))
            let user = id("field \"Email\"", in: read), pass = id("password field \"Password\"", in: read)
            let before = cards.count
            let wrongKind = call("petal_vault", ["action": "fill", "item": loginID, "fields": ["password": user]])
            expect(error(wrongKind).contains("only into a password field") && error(wrongKind).contains("petal_browser read"), "a password only into a password field (\(error(wrongKind)))")
            let filled = call("petal_vault", ["action": "fill", "fields": ["username": user, "password": pass]])
            expect((filled["filled"] as? [String]) == ["username", "password"], "it filled both, finding the login saved for the page (\(filled))")
            expect(cards.count == before, "by itself: this is the login's own site")
            expect(current?.checkEvaluate("document.getElementById('pass').value") == password, "the page's field holds the password")
            let after = page(browser("read"))
            // A field the vault filled is hidden whole, its name too (a page may echo what's in it there), as petal_ui does.
            expect(after.contains("password field \"(hidden)\" (filled by Petal)") && after.contains("field \"Email\" = \"ada@example.com\""), "read says it's filled, never with what (\(after))")
            let sent = browser("click", ["id": id("button \"Sign in\"", in: after)])
            expect((sent["title"] as? String) == "Signed in", "the form went (\(sent))")
            let body = server.posts.last { $0.path == "/session" }?.body ?? ""
            expect(body.contains("username=ada%40example.com") && body.contains("password=" + password), "the site got the login the vault holds")
            return "username and password filled without a card on 127.0.0.1, and the site got them"
        }

        step("the vault: refused where it doesn't belong") {
            _ = browser("open", ["address": base("localhost") + "/login"])
            var read = page(browser("read"))
            let before = cards.count
            let posts = server.posts.count
            let other = call("petal_vault", ["action": "fill", "item": loginID, "fields": ["username": id("field \"Email\"", in: read), "password": id("password field \"Password\"", in: read)]], answer: [.no])
            expect(other["declined"] != nil, "on another site the person is asked, and Don't fills nothing (\(other))")
            expect(cards.count == before + 1 && cards.last?.warn == true && cards.last?.title.contains("on localhost") == true, "one card, naming the page it read (\(cards.last?.title ?? "none"))")
            expect(current?.checkEvaluate("document.getElementById('pass').value + document.getElementById('user').value") == "", "the fields stayed empty")
            let unsaved = call("petal_vault", ["action": "fill", "fields": ["username": id("field \"Email\"", in: read), "password": id("password field \"Password\"", in: read)]])
            expect(error(unsaved).contains("no login saved for localhost"), "and no login is found for it by itself (\(error(unsaved)))")
            // Its own site's page, with another site's frame in it: the frame's fields are the other site's.
            _ = browser("open", ["address": base() + "/"])
            read = page(browser("read"))
            let framed = call("petal_vault", ["action": "fill", "item": loginID, "fields": ["password": id("password field \"Frame password\"", in: read)]], answer: [.no])
            expect(framed["declined"] != nil && cards.last?.title.contains("on localhost") == true, "a frame's field goes by the frame's own site (\(cards.last?.title ?? "none"))")
            let mixed = call("petal_vault", ["action": "fill", "item": loginID, "fields": ["username": id("field \"Search\"", in: read), "password": id("password field \"Frame password\"", in: read)]])
            expect(error(mixed).contains("different pages"), "one fill, one place (\(error(mixed)))")
            expect(server.posts.count == posts, "nothing was sent anywhere")
            // A card on a page that isn't https: never.
            _ = browser("open", ["address": base() + "/pay"])
            let pay = page(browser("read"))
            let insecure = call("petal_vault", ["action": "fill", "item": cardID, "fields": ["number": id("field \"Card number\"", in: pay)]])
            expect(error(insecure).contains("only on secure web pages"), "payment info never on a page that isn't https (\(error(insecure)))")
            expect(current?.checkEvaluate("document.getElementById('num').value") == "", "nothing of the card went in")
            return "another site asked and Don't filled nothing; a frame goes by its own site; no card on http"
        }

        step("the vault: a card only after Buy, on that page") {
            guard let live = current else { expect(false, "the run has a browser"); return "" }
            serveShop(live)
            let opened = browser("open", ["address": "https://shop.example/checkout"])
            expect((opened["title"] as? String) == "Checkout", "the made-up shop opened, answered inside the browser (\(opened))")
            var read = page(opened)
            let number = id("field \"Card number\"", in: read), expiry = id("field \"Expiry\"", in: read), cvc = id("field \"Security code\"", in: read)
            let before = cards.count
            let refused = call("petal_vault", ["action": "fill", "item": cardID, "fields": ["number": number, "expiry": expiry, "securityCode": cvc], "buying": "a test", "price": "12.00"], answer: [.no])
            expect(refused["declined"] != nil, "before Buy nothing of the card goes in (\(refused))")
            expect(cards.count == before + 1 && cards.last?.title == "Buy on shop.example?" && cards.last?.allow == "Buy", "one Buy card, for the shop the browser says it is (\(cards.last?.title ?? "none"))")
            expect(live.checkEvaluate("document.getElementById('num').value + document.getElementById('cvc').value") == "", "the fields stayed empty after Don't")
            let bought = call("petal_vault", ["action": "fill", "item": cardID, "fields": ["number": number, "expiry": expiry, "securityCode": cvc], "buying": "a test", "price": "12.00"], answer: [.once])
            expect((bought["filled"] as? [String])?.count == 3, "after Buy the card filled (\(bought))")
            expect(live.checkEvaluate("document.getElementById('num').value") == cardNumber && live.checkEvaluate("document.getElementById('cvc').value") == code
                   && live.checkEvaluate("document.getElementById('exp').value") == "04/31", "the page holds the card as the vault has it")
            read = page(browser("read"))
            // The number and the code are hidden whole; the expiry is no secret (the AI is told a card's expiry anyway).
            expect(read.components(separatedBy: "(filled by Petal)").count == 3 && !read.contains("4242") && !read.contains(code), "read says the number and the code are filled, never with what (\(read))")
            // The page is the same, so its fields keep their ids.
            let submit = call("petal_vault", ["action": "fill", "item": cardID, "fields": ["securityCode": cvc], "submit": true])
            expect(error(submit).contains("doesn't press Return after payment info"), "never Return after payment info")
            let more = cards.count
            let again = call("petal_vault", ["action": "fill", "item": cardID, "fields": ["securityCode": cvc]])
            expect((again["filled"] as? [String]) == ["securityCode"] && cards.count == more, "Buy covers that page for the rest of the reply")
            // Another page of the shop: the Buy is over, and it asks again.
            _ = browser("open", ["address": "https://shop.example/checkout/other"])
            read = page(browser("read"))
            let moved = call("petal_vault", ["action": "fill", "item": cardID, "fields": ["number": id("field \"Card number\"", in: read)]], answer: [.no])
            expect(moved["declined"] != nil && cards.count == more + 1 && cards.last?.allow == "Buy", "another page asks again (\(moved))")
            return "Don't filled nothing; Buy filled number, expiry and code on shop.example; another page asked again"
        }

        var newPassword = ""
        let typedPassword = "typed-Kq7-by-the-person-55"
        step("the vault: a new login, and one the person types in") {
            _ = browser("open", ["address": base() + "/signup"])
            var read = page(browser("read"))
            let user = id("field \"Email\"", in: read), fresh = id("password field \"New password\"", in: read), again = id("password field \"Again\"", in: read)
            let before = VaultStore.itemsForCheck().count
            let new = call("petal_vault", ["action": "new_login", "password_id": fresh, "confirm_id": again, "username_id": user, "username": "new@example.com", "title": "Check signup"])
            expect((new["filled"] as? [String])?.count == 3 && new["saved"] != nil, "it made a password, saved it and filled all three (\(new))")
            newPassword = current?.checkEvaluate("document.getElementById('np').value") ?? ""
            expect(newPassword.count >= 20 && current?.checkEvaluate("document.getElementById('nc').value") == newPassword, "both fields hold the same strong password")
            let saved = VaultStore.itemsForCheck().first { $0.title == "Check signup" }
            expect(VaultStore.itemsForCheck().count == before + 1 && saved?[.password] == newPassword && saved?.sites == ["127.0.0.1:\(server.port)"], "saved for the site the browser said the page is, with its port on this Mac (\(saved?.sites ?? []))")
            expect(!newPassword.isEmpty && !(answers.last ?? "").contains(newPassword), "and never told")
            // Another port of this Mac is another program's page: the login made on this one asks there.
            let elsewhere = CheckServer()
            elsewhere.pages = server.pages
            defer { elsewhere.stop() }
            if elsewhere.start() {
                _ = browser("open", ["address": "http://127.0.0.1:\(elsewhere.port)/login"])
                read = page(browser("read"))
                let asked = cards.count
                let ported = call("petal_vault", ["action": "fill", "item": saved?.id ?? "", "fields": ["password": id("password field \"Password\"", in: read)]], answer: [.no])
                expect(ported["declined"] != nil && cards.count == asked + 1 && cards.last?.warn == true, "on another port of this Mac the person is asked, and Don't fills nothing (\(ported))")
                expect(current?.checkEvaluate("document.getElementById('pass').value") == "", "the field there stayed empty")
            } else {
                expect(false, "a second server on another port of this Mac")
            }
            // On another site's page, where a login would only fill after asking: no password is made at all.
            _ = browser("open", ["address": base("localhost") + "/signup"])
            read = page(browser("read"))
            // (localhost is this Mac's own too, so a new login may be made there: saved for localhost, not 127.0.0.1.)
            let other = call("petal_vault", ["action": "new_login", "password_id": id("password field \"New password\"", in: read), "title": "Check other"])
            expect(VaultStore.itemsForCheck().first { $0.title == "Check other" }?.sites == ["localhost:\(server.port)"], "a login made on another site is that site's (\(other))")
            // What the person types into Petal's card goes into the page, and is hidden from then on.
            _ = browser("open", ["address": base("localhost") + "/login"])
            read = page(browser("read"))
            var answer = VaultForm.Answer()
            answer.values = [.username: "typed@example.com", .password: typedPassword]
            answer.save = false
            let asked = cards.count
            let requested = call("petal_vault", ["action": "request", "kind": "login", "why": "to sign in",
                                                 "fields": ["username": id("field \"Email\"", in: read), "password": id("password field \"Password\"", in: read)]],
                                 answer: [.once], typed: answer)
            expect(cards.count == asked + 1 && cards.last?.kind == "vault-new", "one card of the vault's own, for the person to type into (\(cards.last?.title ?? "none"))")
            expect(Set(requested["filled"] as? [String] ?? []) == ["username", "password"], "what they typed filled the page (\(requested))")
            expect(current?.checkEvaluate("document.getElementById('pass').value") == typedPassword, "the page holds what they typed")
            expect(!page(browser("read")).contains(typedPassword), "and it's never read back")
            return "a strong password made, saved for 127.0.0.1 and filled twice; what the person typed into Petal's card filled the page"
        }

        step("the vault: an agent outside Petal asks first; a vault that can't be read tells nothing") {
            _ = browser("open", ["address": base() + "/login"])
            let read = page(browser("read"))
            let user = id("field \"Email\"", in: read), pass = id("password field \"Password\"", in: read)
            let agent = AgentAccess.Caller(agent: .codex, host: "T3 Code", project: root.appending(path: "project").path)
            let before = cards.count
            let refused = call("petal_vault", ["action": "fill", "item": loginID, "fields": ["username": user, "password": pass]], answer: [.no], asker: agent)
            expect(cards.count == before + 1 && cards.last?.kind == "agent-vault" && cards.last?.title.contains("Codex in T3 Code") == true, "an agent outside Petal gets its own card first (\(cards.last?.title ?? "none"))")
            expect(error(refused).contains("didn't let") && current?.checkEvaluate("document.getElementById('pass').value") == "", "Don't: nothing filled (\(refused))")
            let allowed = call("petal_vault", ["action": "fill", "item": loginID, "fields": ["username": user, "password": pass]], answer: [.once], asker: agent)
            expect((allowed["filled"] as? [String])?.count == 2, "Allow once: filled, by the vault's own rules for the page (\(allowed))")
            // Full access and an Always cover the person's own Claude Code and Codex; any other program is asked every
            // time. The real Assist.ask, with nothing behind its answer.
            app.config.set("claudeAccess", "full")
            app.config.set("aiAllowed", ["trash"])
            var said: [String: Bool] = [:]
            app.assist.ask("trash", "Move “keep.txt” to the Trash", wants: "move “keep.txt” to the Trash", owner: caller) { said["agent always"] = $0 }
            app.assist.ask("quit", "Quit Mail", wants: "quit Mail", owner: caller) { said["agent full"] = $0 }
            expect(said["agent always"] == true && said["agent full"] == true && app.assist.pending == nil,
                   "Codex in T3 Code (signed by its maker) goes by an Always and by Full access, as before (\(said))")
            // The same name asking, now as a program Petal can't verify.
            let program = AgentAccess.Caller(agent: .unknown, host: nil, project: root.appending(path: "project").path, program: "python3", peerIsPetal: false, pid: 4242)
            _ = call("petal_memories", [:], asker: program)
            app.assist.ask("trash", "Move “keep.txt” to the Trash", wants: "move “keep.txt” to the Trash", owner: caller) { said["always"] = $0 }
            var shown = app.assist.pending
            expect(said["always"] == nil && shown?.title == "An unknown program (python3) wants to move “keep.txt” to the Trash" && shown?.every == true && shown?.mark == .unknown,
                   "an Always doesn't cover a program Petal can't verify: asked, by its name, with no Always (\(shown?.title ?? "no card"))")
            app.assist.choose(.no, for: shown?.id)
            expect(said["always"] == false, "Don't is Don't")
            app.assist.ask("quit", "Quit Mail", wants: "quit Mail", owner: caller) { said["full"] = $0 }
            shown = app.assist.pending
            expect(said["full"] == nil && shown?.title == "An unknown program (python3) wants to quit Mail" && shown?.every == true, "nor does Full access (\(shown?.title ?? "no card"))")
            app.assist.choose(.always, for: shown?.id)
            expect(said["full"] == true && app.config.strings("aiAllowed") == ["trash"], "and nothing it's allowed is kept for anyone else (\(app.config.strings("aiAllowed")))")
            app.assist.ask("quit", "Quit Mail", wants: "quit Mail", owner: app.claude.current.id.uuidString) { said["own"] = $0 }
            app.assist.ask("trash", "Move “keep.txt” to the Trash", wants: "move “keep.txt” to the Trash", owner: nil) { said["routine"] = $0 }
            expect(said["own"] == true && said["routine"] == true && app.assist.pending == nil, "Petal's own chat and a routine's own run aren't asked (\(said))")
            app.config.set("claudeAccess", "auto")
            app.config.set("aiAllowed", [String]())
            // The vault unreadable (a locked Keychain): nothing of a page is told, and nothing is done in it.
            VaultStore.standUnreadable = true
            VaultIndex.changed()
            let blind = browser("read")
            expect(error(blind).contains("can't be read") && blind["page"] == nil, "read tells nothing while the vault can't be read (\(blind))")
            let stuck = browser("click", ["id": id("button \"Sign in\"", in: read)])
            expect(error(stuck).contains("can't be read"), "and nothing is pressed either (\(stuck))")
            let posts = server.posts.count
            let fill = call("petal_vault", ["action": "fill", "item": loginID, "fields": ["password": pass]])
            expect(!error(fill).isEmpty && server.posts.count == posts, "nor filled (\(error(fill)))")
            VaultStore.standUnreadable = false
            VaultIndex.changed()
            expect(wait(5) { !VaultIndex.current().unreadable } && error(browser("read")).isEmpty, "readable again, it reads again")
            return "Codex in T3 Code asked on its own card, Don't and Allow once each did as said; Full access and an Always answered for it and not for a program Petal can't verify; unreadable, the page stayed untold and untouched"
        }

        let agent = AgentAccess.Caller(agent: .codex, host: "T3 Code", project: root.appending(path: "project").path)
        step("the vault: a page isolated from its site is never that site") {
            // The saved site's own address, served sandboxed: the browser keeps it apart from the site, whatever its address.
            _ = browser("open", ["address": base() + "/sandboxed-login"])
            var read = page(browser("read"))
            var before = cards.count
            let boxed = call("petal_vault", ["action": "fill", "item": loginID, "fields": ["username": id("field \"Email\"", in: read), "password": id("password field \"Password\"", in: read)]], answer: [.no])
            expect(cards.count == before + 1 && cards.last?.warn == true && cards.last?.detail.contains("isolated") == true,
                   "a sandboxed document at the login's own address asks, saying it's isolated (\(cards.count - before) cards: \(cards.last?.detail ?? ""); \(boxed))")
            expect(boxed["declined"] != nil && current?.checkEvaluate("document.getElementById('pass').value + document.getElementById('user').value") == "", "and Don't fills nothing")
            _ = browser("open", ["address": base() + "/holds-sandboxed"])
            read = page(browser("read"))
            before = cards.count
            let framed = call("petal_vault", ["action": "fill", "item": loginID, "fields": ["password": id("password field \"Password\"", in: read)]], answer: [.no])
            expect(framed["declined"] != nil && cards.count == before + 1 && cards.last?.detail.contains("isolated") == true,
                   "a sandboxed frame of the login's own site asks the same way (\(cards.last?.detail ?? ""); \(framed))")
            // A frame with no address of its own is the site that made it: by what the browser says, not its address.
            _ = browser("open", ["address": base() + "/holds-srcdoc"])
            read = page(browser("read"))
            before = cards.count
            let inherited = call("petal_vault", ["action": "fill", "item": loginID, "fields": ["password": id("password field \"Inner password\"", in: read)]])
            expect((inherited["filled"] as? [String]) == ["password"] && cards.count == before, "a frame with no address inside the login's own site is that site: filled by itself (\(inherited))")
            expect(current?.checkEvaluate("document.getElementById('s').contentDocument.getElementById('sp').value") == password, "and holds the password")
            _ = browser("open", ["address": base("localhost") + "/holds-srcdoc"])
            read = page(browser("read"))
            before = cards.count
            let foreign = call("petal_vault", ["action": "fill", "item": loginID, "fields": ["password": id("password field \"Inner password\"", in: read)]], answer: [.no])
            expect(foreign["declined"] != nil && cards.count == before + 1 && cards.last?.title.contains("on localhost") == true,
                   "the same frame inside another site is that other site (\(cards.last?.title ?? "no card"); \(foreign))")
            // Payment info never goes into an isolated page, Buy or no Buy.
            if let live = current { serveShop(live) }
            _ = browser("open", ["address": "https://shop.example/sandboxed/checkout"])
            read = page(browser("read"))
            before = cards.count
            let pay = call("petal_vault", ["action": "fill", "item": cardID, "fields": ["number": id("field \"Card number\"", in: read)]], answer: [.once])
            expect(error(pay).contains("isolated") && cards.count == before, "no payment info into an isolated page, and no Buy card for one (\(pay))")
            expect(current?.checkEvaluate("document.getElementById('num').value") == "", "nothing of the card went in")
            return "a sandboxed document and a sandboxed frame at the site's own address asked; a frame with no address went by the site that made it; no card into an isolated page"
        }

        step("the vault: a fill stays with the field it was planned for") {
            // While the person hasn't answered, the page puts another field where the planned one was, and is read again.
            _ = browser("open", ["address": base() + "/swap"])
            var read = page(browser("read"))
            let planned = id("password field \"Password\"", in: read)
            var fill = begin("petal_vault", ["action": "fill", "item": loginID, "fields": ["password": planned]], asker: agent)
            expect(pump(8, answer: nil) { self.app.assist.pending != nil } && fill.reply == nil, "the fill waits on its card")
            var card = app.assist.pending?.id
            expect(current?.checkEvaluate("swapFields()") == "swapped", "the page swapped its fields")
            read = page(browser("read"))
            expect(id("password field \"Recovery phrase\"", in: read) == planned, "read again, the id names another field now (\(planned))")
            app.assist.choose(.once, for: card)
            expect(pump(10, answer: .no) { fill.reply != nil }, "it answered")
            expect(error(fill.reply ?? [:]).contains("read again") || ((fill.reply?["error"] as? String) ?? "").contains("changed"), "allowed after that, the fill refuses: the page changed (\(fill.reply ?? [:]))")
            expect(current?.checkEvaluate("document.getElementById('other').value + '|' + document.getElementById('pass').value") == "|", "and neither field got the password")
            // The same with a frame of the same site that became another document meanwhile.
            _ = browser("open", ["address": base() + "/framed"])
            read = page(browser("read"))
            fill = begin("petal_vault", ["action": "fill", "item": loginID, "fields": ["password": id("password field \"Password\"", in: read)]], asker: agent)
            expect(pump(8, answer: nil) { self.app.assist.pending != nil } && fill.reply == nil, "the second fill waits on its card")
            card = app.assist.pending?.id
            _ = current?.checkEvaluate("document.getElementById('f').src = '/login?again=1'; 'ok'")
            _ = browser("wait", ["seconds": 2])
            read = page(browser("read"))
            expect(!id("password field \"Password\"", in: read).isEmpty, "the frame's new document has the same field")
            app.assist.choose(.once, for: card)
            expect(pump(10, answer: .no) { fill.reply != nil }, "it answered")
            expect(!error(fill.reply ?? [:]).isEmpty, "allowed after that, the fill refuses (\(fill.reply ?? [:]))")
            expect(current?.checkEvaluate("document.getElementById('f').contentDocument.getElementById('pass').value") == "", "and the new document's field got nothing")
            // An ordinary act is bound the same way when its call comes in: read again since, it does nothing.
            _ = browser("open", ["address": base() + "/swap"])
            read = page(browser("read"))
            let email = id("field \"Email\"", in: read)
            let bound = current?.bind([email])?.first
            expect(bound != nil && current?.checkEvaluate("swapFields()") == "swapped", "a control bound, then the page changed")
            _ = browser("read")
            if let live = current, let bound {
                if case .failure(let problem) = live.act(email, bound: bound, "type", ["text": "late", "replace": true, "secret": false]) {
                    expect(problem == .stale, "an act bound before the page was read again does nothing (\(problem.words))")
                } else {
                    expect(false, "an act bound before the page was read again does nothing")
                }
                expect(live.checkEvaluate("document.getElementById('user').value") == "", "and typed nothing")
            }
            return "fields swapped under a waiting card, and a frame that became another document: both fills refused, nothing written; an act bound before a re-read did nothing"
        }

        step("the vault: no page code between the last look and the write") {
            guard let live = current else { expect(false, "the run has a browser"); return "" }
            serveShop(live)
            _ = browser("open", ["address": "https://shop.example/checkout/trap"])
            let read = page(browser("read"))
            let number = id("field \"Card number\"", in: read), cvc = id("field \"Security code\"", in: read)
            let first = call("petal_vault", ["action": "fill", "item": cardID, "fields": ["number": number], "buying": "a test"], answer: [.once])
            expect((first["filled"] as? [String]) == ["number"], "Buy said, the number filled (\(first))")
            let before = cards.count
            // The security code field's own focus handler moves the page to another path, which ends the Buy.
            let trapped = call("petal_vault", ["action": "fill", "item": cardID, "fields": ["securityCode": cvc]])
            expect(live.checkEvaluate("document.getElementById('cvc').value") == "", "a field whose focus handler moves the page gets nothing (\(trapped))")
            expect(!error(trapped).isEmpty && cards.count == before, "and the fill says the page changed")
            let again = call("petal_vault", ["action": "fill", "item": cardID, "fields": ["number": number]], answer: [.no])
            expect(again["declined"] != nil && cards.count == before + 1 && cards.last?.allow == "Buy", "the Buy is over: the next fill asks again (\(again))")
            return "the field's own handler moved the page, and the code was never written; the Buy ended"
        }

        step("read: a page of long headings stays within the cap") {
            _ = browser("open", ["address": base() + "/headings"])
            let read = browser("read")
            let text = page(read)
            expect(text.count < 40_000, "the page as told is short (\(text.count) characters)")
            expect(text.contains("# First of many") && text.contains("## Heading 1:"), "it still reads from its start (\(text.prefix(80)))")
            expect((read["left"] as? String)?.isEmpty == false, "and says what was left out (\(read["left"] ?? "nothing"))")
            expect(text.contains("link \"A link after them\""), "a control past the cut is still listed")
            return "4000 long headings told in \(text.count) characters, the rest said to be left out"
        }

        step("the clipboard: no page writes it by itself, and a copied secret is cleared") {
            // What a page copies on a press, stood in for by the check's server, onto the check's own clipboard.
            nonisolated(unsafe) let board = clipboard
            let secret = password
            server.onHit = { path in
                guard path == "/copied-secret" || path == "/copied-words" else { return }
                board.clearContents()
                board.setString(path == "/copied-secret" ? secret : "only words", forType: .string)
            }
            defer { server.onHit = nil }
            expect(settled(), "no press from before is still watched")
            for host in ["127.0.0.1", "localhost"] {
                _ = browser("open", ["address": base(host) + "/clip"])
                let waited = browser("wait", ["text": "Permission: denied.", "seconds": 5])
                let read = page(browser("read"))
                expect((waited["done"] as? String) == "The page shows that now." && read.contains("On load: refused."),
                       "on \(host) a page is refused the clipboard, whatever it asks (\(read.components(separatedBy: "\n").filter { $0.contains("On load") || $0.contains("Permission") }))")
            }
            var read = page(browser("read"))
            var count = clipboard.changeCount
            let pressed = browser("click", ["id": id("button \"Copy the password\"", in: read)])
            expect(error(pressed).isEmpty, "it pressed (\(pressed))")
            expect(wait(10) { clipboard.changeCount == count + 2 } && clipboard.string(forType: .string) == nil,
                   "a saved password a page copied on a press is cleared (the clipboard moved \(clipboard.changeCount - count), holds \(clipboard.string(forType: .string) == nil ? "nothing" : "something"))")
            expect(settled(), "the watch ended")
            let told = browser("read")
            read = page(told)
            // The press's own answer when the copy came that soon, else the next one.
            let said = [pressed, told].filter { ($0["happened"] as? [String])?.contains(RunBrowserRules.copyCleared) == true }.count
            expect(said == 1, "and an answer says so, once (\(pressed["happened"] ?? "nothing"); \(told["happened"] ?? "nothing"))")
            expect(read.contains("On a press: refused."), "its own write on that press was refused too")
            expect(app.assist.history.map(\.text).contains { $0.contains("Cleared the clipboard after a page copied one of your secrets") }, "and so does What Petal AI did")
            // A key is a press too.
            count = clipboard.changeCount
            let keyed = browser("key", ["key": "down", "id": id("field \"Hot field\"", in: read)])
            expect(error(keyed).isEmpty && wait(10) { clipboard.changeCount == count + 2 } && clipboard.string(forType: .string) == nil,
                   "one copied on a key is cleared (\(error(keyed)); the clipboard moved \(clipboard.changeCount - count))")
            expect(settled(), "the watch ended")
            // Words that are nobody's secret stay.
            read = page(browser("read"))
            count = clipboard.changeCount
            _ = browser("click", ["id": id("button \"Copy the words\"", in: read)])
            expect(wait(10) { clipboard.changeCount == count + 1 } && settled() && clipboard.string(forType: .string) == "only words" && clipboard.changeCount == count + 1,
                   "a copy with no secret in it is left alone (\(clipboard.string(forType: .string) ?? "nothing"))")
            // The person typing or clicking meanwhile: a copy may be theirs, and is never cleared.
            app.runBrowsers.copyHands = { true }
            defer { app.runBrowsers.copyHands = { false } }
            read = page(browser("read"))
            count = clipboard.changeCount
            _ = browser("click", ["id": id("button \"Copy the password\"", in: read)])
            expect(wait(10) { clipboard.changeCount == count + 1 } && settled() && clipboard.string(forType: .string) == password && clipboard.changeCount == count + 1,
                   "with the person at the keyboard nothing is cleared")
            expect((browser("read")["happened"] as? [String])?.contains(RunBrowserRules.copyCleared) != true, "and nothing is said")
            clipboard.clearContents()
            return "two sites refused the clipboard on load and on a press; a password copied on a press and on a key was cleared and said; plain words, and a copy while the person types, were left"
        }

        step("no secret in any answer") {
            let all = answers.joined(separator: "\n")
            for (name, secret) in [("the password", password), ("the key", key), ("the card number", cardNumber), ("the page's own password", "letmein-shown-by-page"),
                                   ("the password Petal made", newPassword.isEmpty ? "never-made" : newPassword), ("the password the person typed", typedPassword)] {
                expect(!all.contains(secret), "\(name) is in an answer")
            }
            expect(!all.contains("\"" + code + "\"") && !all.contains(" " + code + " "), "the security code is in an answer")
            let history = app.assist.history.map(\.text).joined(separator: "\n")
            expect(!history.contains(password) && !history.contains(cardNumber) && !history.contains(key) && !history.contains(typedPassword) && (newPassword.isEmpty || !history.contains(newPassword)),
                   "a secret is in What Petal AI did")
            expect(history.contains("Filled your Check shop password on 127.0.0.1") && history.contains("Buy on shop.example"), "What Petal AI did says what was filled where (\(history.components(separatedBy: "\n").prefix(3)))")
            return "\(answers.count) answers and \(app.assist.history.count) lines of What Petal AI did hold none of them"
        }

        step("Stop ends an action, and the reply") {
            _ = browser("open", ["address": base() + "/"], answer: [.once], task: "stopping")
            let read = page(browser("read", task: "stopping"))
            let started = Date()
            var reply: [String: Any]?
            let json = "{\"action\": \"wait\", \"text\": \"It never comes\", \"seconds\": 25, \"task\": \"stopping\"}"
            app.assist.handle("petal_browser", json, note: caller, who: who) { text in
                reply = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
                self.answers.append(text)
            }
            wait(0.6) { false }
            expect(reply == nil, "the action is under way")
            app.assist.computer.stop()
            expect(wait(5) { reply != nil } && Date().timeIntervalSince(started) < 5, "Stop ended it at once (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
            expect(error(reply ?? [:]).contains("stopped"), "and says the person stopped it (\(reply ?? [:]))")
            let after = browser("type", ["id": id("field \"Search\"", in: read), "text": "after stop"], task: "stopping")
            expect(error(after).contains("stopped") && current?.checkEvaluate("document.getElementById('q').value") != "after stop", "nothing more is done in that reply (\(after))")
            let asked = cards.count
            let fresh = browser("read", answer: [.once], task: "another task")
            expect(cards.count == asked + 1 && error(fresh).isEmpty, "another task asks again, and goes on")
            return "a wait of 25 s ended in \(String(format: "%.1f", Date().timeIntervalSince(started))) s; that reply did nothing more; the next task asked again"
        }

        step("it ends with its run: no process, no profile") {
            guard alive(pid), fm.fileExists(atPath: profile) else { expect(false, "it was still there to end"); return "" }
            app.displays.ended(caller)
            expect(wait(6) { !self.alive(pid) && !self.fm.fileExists(atPath: profile) }, "the run's end ended its process and removed its profile (alive \(alive(pid)), folder \(fm.fileExists(atPath: profile)))")
            expect(removed.count == 1 && current == nil && !RunBrowsers.isRun(pid), "with its display; nothing of it is known any more")
            expect(((try? fm.contentsOfDirectory(atPath: profiles.path)) ?? []).isEmpty, "no profile folder is left")
            // Turned off while one runs: it goes too.
            let again = browser("open", ["address": base() + "/two"], answer: [.once], task: "second run")
            guard error(again).isEmpty, let second = current else { expect(false, "a second run started one (\(again))"); return "" }
            let secondPID = second.pid, secondProfile = second.profile
            expect(secondPID != pid && secondProfile != profile, "a new run gets a new browser and profile")
            app.config.set("runDisplays", false)
            expect(wait(6) { !self.alive(secondPID) && !self.fm.fileExists(atPath: secondProfile) }, "turning hidden displays off ended it")
            let off = browser("open", ["address": base() + "/"], task: "third run")
            expect(error(off) == RunBrowserRules.off, "and with them off the tool says why (\(error(off)))")
            app.config.set("runDisplays", true)
            // No browser installed: said plainly.
            app.runBrowsers.finder = { _ in .failure(.init(RunBrowserRules.none)) }
            let none = browser("open", ["address": base() + "/"], answer: [.once], task: "fourth run")
            expect(error(none) == RunBrowserRules.none, "with no browser installed it says so (\(error(none)))")
            app.displays.ended(caller)
            // Only the browser the person's links open in: the run gets none, and hears why.
            let theirs = RunBrowserRules.theirs("Google Chrome", named: false)
            app.runBrowsers.finder = { _ in .failure(.init(theirs)) }
            let only = browser("open", ["address": base() + "/"], answer: [.once], task: "fifth run")
            expect(error(only) == theirs && current == nil && runProcesses().isEmpty, "with only the person's link browser installed it starts none and says so (\(error(only)))")
            app.displays.ended(caller)
            return "the run's end and the switch each ended theirs (pids \(pid), \(secondPID)); no profile left; off, no browser and only the person's own say why"
        }

        // A browser that starts and never answers (a script that only sleeps), to hold a launch open.
        let slow = root.appending(path: "slow-browser").path
        try? Data("#!/bin/sh\nsleep 40\n".utf8).write(to: URL(fileURLWithPath: slow))
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow)
        let slowSpec: @Sendable (String) -> Result<RunBrowser.Spec, RunBrowser.Problem> = { _ in
            .success(RunBrowser.Spec(bundle: "org.chromium.headless-shell", name: "Check browser", executable: slow, headless: true, verify: { _ in true }))
        }
        let realSpec: @Sendable (String) -> Result<RunBrowser.Spec, RunBrowser.Problem> = { _ in
            .success(RunBrowser.Spec(bundle: "org.chromium.headless-shell", name: "Check browser", executable: shell, headless: true,
                                     extra: ["--site-per-process", "--disable-gpu"], verify: { _ in true }))
        }

        step("a browser still starting is already a run's, and ends with its run") {
            app.runBrowsers.finder = slowSpec
            var opening = begin("petal_browser", ["action": "open", "address": base() + "/two"], task: "starting one")
            expect(pump(8, answer: .once) { !self.runProcesses().isEmpty } && opening.reply == nil, "a launch is under way")
            guard let starting = runProcesses().first else { return "" }
            expect(RunApps.isRun(starting), "its process is a run's from the moment it exists (pid \(starting))")
            expect(!Routines.personsEvent(pid: starting), "so an app event for it is never the person's (a \"when it opens\" routine doesn't fire)")
            // Stop while it starts: the launch is ended, not left to finish.
            var began = Date()
            app.displays.ended(caller)
            expect(pump(4, answer: .no) { opening.reply != nil && !self.alive(starting) && self.profileFolders().isEmpty },
                   "the run ending ended the launch: answered \(opening.reply != nil), process gone \(!alive(starting)), profiles left \(profileFolders())")
            let stopped = Date().timeIntervalSince(began)
            expect(!error(opening.reply ?? [:]).isEmpty && current == nil, "and the tool says the run's display went (\(opening.reply ?? [:]))")
            // The setting turned off while it starts.
            opening = begin("petal_browser", ["action": "open", "address": base() + "/two"], task: "starting two")
            expect(pump(8, answer: .once) { !self.runProcesses().isEmpty } && opening.reply == nil, "a second launch is under way")
            let second = runProcesses().first ?? 0
            began = Date()
            app.config.set("runDisplays", false)
            expect(pump(4, answer: .no) { opening.reply != nil && !self.alive(second) && self.profileFolders().isEmpty },
                   "hidden displays turned off ended the launch: answered \(opening.reply != nil), process gone \(!alive(second)), profiles left \(profileFolders())")
            app.config.set("runDisplays", true)
            return String(format: "Stop ended a launch in %.1f s and the switch in %.1f s; no process, no profile", stopped, Date().timeIntervalSince(began))
        }

        step("a launch that outlives its run is thrown away") {
            // The first launch is held before its browser starts; its run ends; the same run starts again and gets a
            // browser; then the first launch is let go on.
            let hold = DispatchSemaphore(value: 0)
            let entered = DispatchSemaphore(value: 0)
            let calls = Counter()
            app.runBrowsers.finder = { setting in
                guard calls.next() == 1 else { return realSpec(setting) }
                entered.signal()
                hold.wait()
                return realSpec(setting)
            }
            let old = begin("petal_browser", ["action": "open", "address": base() + "/two"], task: "outlived")
            expect(pump(8, answer: .once) { entered.wait(timeout: .now()) == .success }, "the first launch is under way")
            app.displays.ended(caller)
            expect(pump(4, answer: .no) { old.reply != nil }, "its run ending answers it at once (\(old.reply ?? [:]))")
            let new = browser("open", ["address": base() + "/"], answer: [.once], task: "the same note again")
            expect(error(new).isEmpty && current != nil, "the same run, started again, has a browser (\(error(new)))")
            let kept = current?.pid ?? 0
            hold.signal()
            wait(3) { false }
            expect(current?.pid == kept && alive(kept), "the old launch coming back doesn't take its place")
            expect(runProcesses().filter { ($0 == kept) == false && (PetalProcess.arguments(of: $0) ?? []).contains { $0.hasPrefix("--type=") } == false } == [],
                   "and leaves no browser of its own (\(runProcesses()), kept \(kept))")
            expect(profileFolders().count == 1, "nor a profile (\(profileFolders()))")
            app.displays.ended(caller)
            expect(wait(6) { !self.alive(kept) && self.profileFolders().isEmpty }, "and the new one ends with its run")
            return "the run's own browser stayed (pid \(kept)); the old launch left no process and no profile"
        }

        step("what a crash leaves") {
            // Petal gone: the pipe closes, and the browser ends itself.
            let orphan = profiles.appending(path: RunBrowserRules.folderName(group: "mcp-1", nonce: "orphan")).path
            try? fm.createDirectory(atPath: orphan, withIntermediateDirectories: true)
            guard let pipe = BrowserPipe.start(executable: shell, arguments: RunBrowserRules.arguments(profile: orphan, frame: nil)) else {
                expect(false, "a browser started")
                return ""
            }
            expect(wait(10) { (PetalProcess.arguments(of: pipe.pid) ?? []).contains("--user-data-dir=" + orphan) }, "it runs with its profile")
            pipe.hangUp()
            expect(wait(6) { pipe.ended }, "with the pipe closed (Petal gone) the browser ended itself")
            // One that didn't (found by the profile it was started with), and folders nobody holds: swept at launch.
            let stuck = profiles.appending(path: RunBrowserRules.folderName(group: "note-ABC", nonce: "stuck")).path
            try? fm.createDirectory(atPath: stuck, withIntermediateDirectories: true)
            guard let second = BrowserPipe.start(executable: shell, arguments: RunBrowserRules.arguments(profile: stuck, frame: nil)) else {
                expect(false, "a second browser started")
                return ""
            }
            expect(wait(10) { (PetalProcess.arguments(of: second.pid) ?? []).contains("--user-data-dir=" + stuck) }, "a second runs with its profile")
            try? Data("not a profile".utf8).write(to: profiles.appending(path: "keep.txt.bak"))
            let swept = RunBrowsers.sweep(root: profiles.path, mine: [])
            expect(swept.ended.contains(second.pid), "the sweep found it by its profile folder and ended it (\(swept.ended))")
            expect(wait(6) { second.ended } && !fm.fileExists(atPath: stuck) && !fm.fileExists(atPath: orphan), "its process is gone, and both profile folders")
            expect(fm.fileExists(atPath: profiles.appending(path: "keep.txt.bak").path), "nothing that isn't a profile folder by its name is touched")
            return "the pipe closing ended one by itself; the sweep ended the other and removed both profiles"
        }

        print(failures == 0 ? "browser check: all \(steps) steps passed" : "browser check: \(failures) of \(steps) failed")
        return failures
    }
}

/// Counts calls, from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// `Petal --browser-check --live <folder>`: a run's browser for real: a real hidden display, a real installed
/// browser, a page from the check's own server. Accessibility and the DevTools pipe only: no AppleScript. One line
/// per step, "ok" or "FAIL" with what was read; indented lines are what it read, never a verdict. The exit code is
/// the number of failures.
@MainActor
enum BrowserLiveCheck {
    private static var failures = 0

    private static func step(_ ok: Bool, _ what: String, _ detail: String = "") {
        print((ok ? "ok    " : "FAIL  ") + what + (detail.isEmpty ? "" : "  [" + detail + "]"))
        if !ok { failures += 1 }
    }

    private static func say(_ text: String) { print("      " + text) }

    @discardableResult
    private static func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return done()
    }

    private static func describe(_ rect: CGRect) -> String { "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))" }

    /// The app in front and its focused window's number, as the person has them.
    private static func front() -> (pid: pid_t, name: String, window: CGWindowID?) {
        let running = NSWorkspace.shared.frontmostApplication
        let pid = running?.processIdentifier ?? 0
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let window: AXUIElement? = Windows.value(app, kAXFocusedWindowAttribute)
        return (pid, running?.localizedName ?? "nothing", window.flatMap { Windows.id(of: $0) })
    }

    private final class Box<Value>: @unchecked Sendable {
        var value: Value?
    }

    /// Runs `work` off the main thread while the main run loop goes on, and gives back what it made.
    private static func off<Value>(_ seconds: Double, _ work: @escaping @Sendable () -> Value) -> Value? {
        let box = Box<Value>()
        DispatchQueue.global(qos: .userInitiated).async {
            let made = work()
            DispatchQueue.main.async { box.value = made }
        }
        wait(seconds) { box.value != nil }
        return box.value
    }

    static func run(folder path: String) -> Never {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Petal's own folders at throwaway ones: the profile is made under them, never under the person's.
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "petal-browser-live-\(getpid())")
        for name in ["config", "support", "notes"] { try? fm.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true) }
        setenv("PETAL_CONFIG_DIR", root.appending(path: "config").path, 1)
        setenv("PETAL_SUPPORT_DIR", root.appending(path: "support").path, 1)
        setenv("PETAL_NOTES", root.appending(path: "notes").path, 1)
        defer { try? fm.removeItem(at: root) }
        print("Petal browser check (live), macOS \(ProcessInfo.processInfo.operatingSystemVersionString). This makes a real display and starts a real browser for a few seconds.")

        // 1. What it needs.
        step(VirtualDisplay.available, "macOS has the classes Petal makes a display with", VirtualDisplay.available ? "" : "missing: " + VirtualDisplay.missing.joined(separator: ", "))
        let found = off(30) { RunBrowsers.find(setting: "") } ?? .failure(.init(RunBrowserRules.none))
        let spec = try? found.get()
        var why = RunBrowserRules.none
        if case .failure(let problem) = found { why = problem.words }
        step(spec != nil, "a browser Petal can start for a run is installed, signed by its maker", spec.map { "\($0.name), \($0.executable)" } ?? why)
        let trusted = AXIsProcessTrusted()
        say("Accessibility: \(trusted ? "allowed" : "not allowed (the window in front can't be named; the rest still runs)")")
        let recording = CGPreflightScreenCaptureAccess()
        say("Screen Recording: \(recording ? "allowed" : "not allowed (no picture is written; the rest still runs)")")
        guard VirtualDisplay.available, let spec else { finish() }
        let server = CheckServer()
        server.pages = { path, _ in
            guard path.components(separatedBy: "?")[0] == "/" else { return nil }
            return ("text/html; charset=utf-8", """
            <!doctype html><html><head><title>Petal live check</title></head><body style="font: 28px -apple-system; margin: 60px">
            <h1>Petal live check</h1><p id="out">Nothing pressed yet.</p>
            <button id="press" style="font: inherit" onclick="document.getElementById('out').textContent = 'Pressed once.'">Press me</button>
            <p><label for="q">Search</label> <input id="q" style="font: inherit" oninput="document.getElementById('echo').textContent = 'You typed: ' + this.value"></p><p id="echo"></p>
            </body></html>
            """, [])
        }
        step(server.start(), "the check's own page is served on this Mac", "http://127.0.0.1:\(server.port)/")
        defer { server.stop() }

        // 2. How things are before.
        let before = front()
        let personsBefore = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        say("in front before: \(before.name) (pid \(before.pid), window \(before.window.map(String.init) ?? "none"))")
        var activated: [String] = []
        let watching = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { activated.append("\(running?.localizedName ?? "?") (pid \(running?.processIdentifier ?? 0))") }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(watching) }

        // 3. The display.
        let display = VirtualDisplay.make(name: "Petal browser check", serial: UInt32(getpid()), points: RunDisplayRules.size) {}
        step(display != nil, "a display was made", display.map { "id \($0.id)" } ?? "CGVirtualDisplay refused")
        guard let display else { finish() }
        let id = display.id
        let placing = off(30) { RunDisplays.place(id, size: RunDisplayRules.size) }
        for line in placing?.tried ?? ["placing never answered (30 s)"] { say(line) }
        step(placing?.frame != nil, "macOS kept it at a corner of the person's screens", placing?.frame.map(describe) ?? "see the tries above")
        guard let frame = placing?.frame else {
            display.remove()
            finish()
        }

        // 4. The browser: Petal's child, its own profile, its window on the display from the start.
        let profile = (RunBrowsers.root as NSString).appendingPathComponent(RunBrowserRules.folderName(group: "live-check", nonce: "\(getpid())"))
        let window = RunBrowser.windowFrame(on: frame)
        let started = Date()
        let launched = off(60) { RunBrowser.launch(spec: spec, group: "live-check", profile: profile, frame: window) }
        var browser: RunBrowser?
        switch launched {
        case .success(let made)?: browser = made
        case .failure(let problem)?: say(problem.words)
        case nil: say("the browser never answered (60 s)")
        }
        step(browser != nil, "\(spec.name) started as Petal's child with a profile of its own", String(format: "%.1f s", Date().timeIntervalSince(started)))
        guard let browser else {
            display.remove()
            finish()
        }
        step(RunApps.isRun(browser.pid), "its process is known as a run's, not the person's, from the moment it started")
        let pid = browser.pid
        let arguments = PetalProcess.arguments(of: pid) ?? []
        step(getppid() != pid && arguments.contains("--remote-debugging-pipe") && !arguments.contains { $0.hasPrefix("--remote-debugging-port") },
             "it's driven over the pipe: no port is open", "pid \(pid)")
        step(arguments.contains("--user-data-dir=" + profile) && fm.fileExists(atPath: profile), "its profile is Petal's own folder", profile)
        step(browser.verified, "its running code is \(spec.name), signed by its maker (what the vault goes by)")
        let said = off(10) { browser.checkWindowBounds() } ?? nil
        step(said.map { frame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false, "the browser says its window is on the run's display", said.map(describe) ?? "it gave no bounds")
        wait(1.5) { false }
        let listed = RunDisplays.windowNumbers(pid: pid).values.map(\.frame)
        step(!listed.isEmpty && listed.allSatisfy { frame.contains(CGPoint(x: $0.midX, y: $0.midY)) }, "the window server has every window of it on the run's display",
             listed.map(describe).joined(separator: " | "))
        step(!listed.contains { window in Screens.displays.contains { CGDisplayBounds($0).intersects(window) } }, "none of it is on the person's screens")

        // 5. Driving it: open, read, click, type.
        let token = Acting.Cancel()
        let address = "http://127.0.0.1:\(server.port)/"
        let went = off(30) { browser.go(address, newTab: false, cancel: token) } ?? RunBrowser.Problem("no answer")
        step(went == nil, "it opened the check's page", went?.words ?? address)
        VaultStore.standIn([])
        let read = off(30) { browser.read(find: "") }
        var text = ""
        if case .success(let page)? = read { text = page.text }
        step(text.contains("# Petal live check") && text.contains("button \"Press me\""), "read gives the page as text with ids", text.replacingOccurrences(of: "\n", with: " ⏎ "))
        func find(_ words: String) -> String {
            for line in text.components(separatedBy: "\n") where line.contains(words) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let end = trimmed.firstIndex(of: "]") { return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end]) }
            }
            return ""
        }
        let press = find("button \"Press me\""), field = find("field \"Search\"")
        let clicked = off(15) { browser.act(press, "click", [:], gesture: true) }
        let pressed = off(10) { browser.checkEvaluate("document.getElementById('out').textContent") } ?? nil
        step(pressed == "Pressed once.", "click pressed the page's button", "\(String(describing: clicked)); the page says: \(pressed ?? "nothing")")
        _ = off(15) { browser.act(field, "type", ["text": "tulips", "replace": true, "secret": false]) }
        let typed = off(10) { browser.checkEvaluate("document.getElementById('echo').textContent") } ?? nil
        step(typed == "You typed: tulips", "type put text in the page's field", typed ?? "nothing")

        // 6. A picture of the display.
        if recording {
            let picture = Box<NSImage>()
            let done = Box<Bool>()
            Task {
                picture.value = await RunDisplays.picture(of: id, hiding: [], height: 450)
                done.value = true
            }
            wait(15) { done.value == true }
            var wrote = false
            let file = folder.appending(path: "petal-browser-check.png")
            if let image = picture.value, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                wrote = (try? png.write(to: file)) != nil
            }
            step(wrote, "a picture of the run's display was written", file.path)
        } else {
            say("no picture: this Petal may not record the screen")
        }

        // 7. The person's side: nothing changed, and nothing of the browser is theirs.
        let after = front()
        step(after.pid == before.pid && after.window == before.window, "the app and window in front didn't change",
             "now \(after.name) (pid \(after.pid), window \(after.window.map(String.init) ?? "none"))")
        let cameForward = activated.contains { $0.contains("(pid \(pid))") }
        step(!cameForward, "the run's browser never came to the front", activated.isEmpty ? "no app was activated" : "activated meanwhile: " + activated.joined(separator: ", "))
        let macOS = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
        say("macOS lists it as a running app: \(macOS.map { "\($0.localizedName ?? "?"), \($0.bundleIdentifier ?? "?"), policy \($0.activationPolicy.rawValue)" } ?? "no")")
        let persons = NSWorkspace.shared.personsApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)
        step(!persons.contains(pid) && Set(persons).subtracting(personsBefore).isEmpty, "Petal's list of the person's apps has no extra browser",
             "\(persons.count) apps, \(personsBefore.count) before")
        let dock = DockController.runningApps()[spec.bundle]
        step(dock?.processIdentifier != pid, "Petal's dock doesn't take it for \(spec.name)", dock.map { "the dock's \(spec.name) is pid \($0.processIdentifier), the person's own" } ?? "\(spec.name) isn't running for the dock")
        step(!WindowList.current().onScreenWindows.contains { $0.pid == pid }, "and its window isn't in the dock's window list")
        if cameForward, let back = NSRunningApplication(processIdentifier: before.pid) {
            back.activate()
            say("it came forward, so \(before.name) was given the front back")
        }

        // 8. The end: nothing is left.
        browser.end(wait: 4)
        step(wait(6) { kill(pid, 0) != 0 }, "the browser's process is gone", "pid \(pid)")
        step(wait(4) { !fm.fileExists(atPath: profile) }, "its profile folder is gone", profile)
        let leftover = RunBrowsers.processes().filter { RunBrowserRules.profile(inArguments: $0.arguments, root: RunBrowsers.root) != nil }.map(\.pid)
        step(leftover.isEmpty, "no process started with a run's profile is left", leftover.isEmpty ? "" : "pids \(leftover)")
        display.remove()
        step(wait(8) { !Screens.isOnline(id) }, "the display is gone from macOS's list of online displays")
        Screens.forget(id)
        let last = front()
        step(last.pid == before.pid, "and the person's app is still in front", last.name)
        finish()
    }

    private static func finish() -> Never {
        print(failures == 0 ? "browser check (live): everything passed" : "browser check (live): \(failures) failed")
        exit(Int32(min(failures, 100)))
    }
}
