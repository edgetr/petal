import CoreGraphics
import Foundation

// Checks RunBrowserPlan.swift and RunBrowserScript.swift: how Petal talks to a run's browser (messages on the
// DevTools pipe cut out whole, replies matched to their requests), which browser a run gets and what it's started
// with, where a run's profile lives and what's swept after a crash, which addresses open, how a page reads to an AI
// (ids, caps, what's hidden), and the vault's decisions fed with what the browser says of a page's frames. Nothing is
// started: these are the plan's own decisions. Run with macos/checks/run.sh.
@main
struct RunBrowserCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static func node(_ json: [String: Any]) -> PageNode { PageNode(json)! }

    static func main() {
        protocolChecks()
        browserChecks()
        addressChecks()
        outlineChecks()
        vaultChecks()
        scriptChecks()
        if failures > 0 {
            print("RunBrowser: \(failures) failed")
            exit(1)
        }
        print("RunBrowser: \(passed) checks passed")
    }

    // MARK: The protocol

    static func protocolChecks() {
        let framed = CDP.frame(id: 7, method: "Page.navigate", params: ["url": "https://example.com/a b"], session: "S1")
        expect(framed?.last == 0 && framed?.filter { $0 == 0 }.count == 1, "a request ends with one NUL, and holds no other")
        let back = framed.flatMap { try? JSONSerialization.jsonObject(with: $0.dropLast()) as? [String: Any] }
        expect(back?["id"] as? Int == 7 && back?["method"] as? String == "Page.navigate" && back?["sessionId"] as? String == "S1"
               && (back?["params"] as? [String: Any])?["url"] as? String == "https://example.com/a b", "and reads back as it was written")
        let bare = CDP.frame(id: 1, method: "Browser.getVersion").flatMap { try? JSONSerialization.jsonObject(with: $0.dropLast()) as? [String: Any] }
        expect(bare?["sessionId"] == nil && bare?["params"] == nil, "no session and no params when there are none")
        let nul = CDP.frame(id: 2, method: "Input.insertText", params: ["text": "a\u{0}b"])
        expect(nul?.filter { $0 == 0 }.count == 1, "a NUL in what's typed is written as an escape, never as the byte that ends a message")
        expect(CDP.frame(id: 3, method: "X", params: ["bad": Date()]) == nil, "what can't be written as JSON isn't sent")

        var splitter = CDP.Splitter()
        let one = Data("{\"id\":1,\"result\":{}}".utf8), two = Data("{\"method\":\"Page.loadEventFired\",\"params\":{}}".utf8)
        var stream = one
        stream.append(0)
        stream.append(two)
        stream.append(0)
        expect(splitter.take(stream.prefix(5)) == [], "half a message is no message")
        expect(splitter.take(stream.dropFirst(5).prefix(20)) == [one], "the rest of it completes it")
        expect(splitter.pending > 0, "and what follows waits")
        expect(splitter.take(stream.dropFirst(25)) == [two], "until its own end comes")
        var both = CDP.Splitter()
        expect(both.take(stream) == [one, two], "two in one read come out as two, in order")
        var empty = CDP.Splitter()
        expect(empty.take(Data([0, 0])) == [], "an empty message is passed over")
        var huge = CDP.Splitter()
        _ = huge.take(Data(repeating: 65, count: CDP.limit + 1))
        expect(huge.overflowed && huge.take(stream) == [], "a message past the limit ends the reading")

        if case .reply(let id, let result, let error) = CDP.parse(Data("{\"id\":4,\"result\":{\"frameId\":\"F\"}}".utf8)) {
            expect(id == 4 && result["frameId"] as? String == "F" && error == nil, "a reply has its request's id and its result")
        } else { expect(false, "a reply parses") }
        if case .reply(let id, _, let error) = CDP.parse(Data("{\"id\":5,\"error\":{\"code\":-32000,\"message\":\"Cannot find context with specified id\"}}".utf8)) {
            expect(id == 5 && error == "Cannot find context with specified id", "a refusal has the browser's own words")
        } else { expect(false, "a refusal parses") }
        if case .event(let method, let params, let session) = CDP.parse(Data("{\"method\":\"Page.frameNavigated\",\"params\":{\"frame\":{\"id\":\"F\"}},\"sessionId\":\"S\"}".utf8)) {
            expect(method == "Page.frameNavigated" && session == "S" && params["frame"] != nil, "an event has its session")
        } else { expect(false, "an event parses") }
        if case .junk = CDP.parse(Data("not json".utf8)) { expect(true, "") } else { expect(false, "what isn't JSON is passed over") }
        if case .junk = CDP.parse(Data("[1,2]".utf8)) { expect(true, "") } else { expect(false, "what isn't a message is passed over") }

        var inbox = CDP.Inbox<String>()
        let a = inbox.add("first"), b = inbox.add("second"), c = inbox.add("third")
        expect(a != b && b != c && a < b && b < c, "each request gets an id of its own")
        expect(inbox.take(b) == "second" && inbox.take(b) == nil, "a reply answers its own request, once")
        expect(inbox.take(999) == nil && inbox.count == 2, "a reply nobody asked for answers nobody")
        expect(inbox.drain() == ["first", "third"] && inbox.count == 0, "when the pipe closes, everyone still waiting hears")
    }

    // MARK: Which browser, with what, and what's left

    static func browserChecks() {
        typealias R = RunBrowserRules
        let all = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser"]
        expect(R.pick(installed: [], running: [], standard: nil, setting: "") == nil, "none installed: none")
        expect(R.pick(installed: ["com.apple.Safari", "company.thebrowser.Browser", "org.chromium.Chromium"], running: [], standard: nil, setting: "") == nil,
               "Safari, Arc and Chromium aren't browsers Petal starts")
        expect(R.pick(installed: all, running: [], standard: nil, setting: "")?.bundle == "com.google.Chrome", "nothing else to go by: the list's order")
        expect(R.pick(installed: all, running: ["com.google.Chrome"], standard: nil, setting: "")?.bundle == "com.microsoft.edgemac", "one the person has open comes last")
        expect(R.pick(installed: all, running: [], standard: "com.google.Chrome", setting: "")?.bundle == "com.microsoft.edgemac", "so does the one their links open in")
        expect(R.pick(installed: all, running: ["com.microsoft.edgemac"], standard: "com.google.Chrome", setting: "")?.bundle == "com.brave.Browser", "the one that's neither")
        expect(R.pick(installed: ["com.google.Chrome"], running: ["com.google.Chrome"], standard: "com.google.Chrome", setting: "")?.bundle == "com.google.Chrome",
               "the only one there is, even open")
        expect(R.pick(installed: all, running: ["com.brave.Browser"], standard: nil, setting: "com.brave.Browser")?.bundle == "com.brave.Browser", "the person's choice wins")
        expect(R.pick(installed: all, running: [], standard: nil, setting: "Microsoft Edge")?.bundle == "com.microsoft.edgemac", "by its name too")
        expect(R.pick(installed: all, running: [], standard: nil, setting: "com.apple.Safari")?.bundle == "com.google.Chrome", "a choice Petal can't start is no choice")
        expect(R.known("COM.GOOGLE.CHROME")?.team == "EQHXZ8M8AV" && R.known("com.apple.Safari") == nil, "each with who signs it")

        let frame = CGRect(x: 1512, y: 1032, width: 1280, height: 800)
        let windowed = R.arguments(profile: "/p/run-browsers/note-1-ab", frame: frame)
        expect(windowed.contains("--remote-debugging-pipe") && !windowed.contains { $0.hasPrefix("--remote-debugging-port") }, "the pipe, never a port")
        expect(windowed.contains("--user-data-dir=/p/run-browsers/note-1-ab"), "its own profile")
        expect(windowed.contains("--no-startup-window") && windowed.contains("--window-position=1512,1032") && windowed.contains("--window-size=1280,800"),
               "no window of its own at the start, and where one goes")
        for flag in ["--no-first-run", "--no-default-browser-check", "--disable-sync", "--disable-extensions", "--use-mock-keychain", "--mute-audio", "--deny-permission-prompts"] {
            expect(windowed.contains(flag), "started with \(flag)")
        }
        let headless = R.arguments(profile: "/p/x", frame: nil)
        expect(!headless.contains("--no-startup-window") && !headless.contains { $0.hasPrefix("--window-") } && headless.last == "about:blank", "without a window, nothing is placed")

        let name = R.folderName(group: "note-1F2A/../x y", nonce: "k3:x9")
        expect(name == "note-1F2Axy-k3x9" && R.isPlain(name), "a profile folder's name is plain", name)
        expect(R.folderName(group: "", nonce: "") == "run-x", "even for nobody")
        expect(R.folderName(group: String(repeating: "a", count: 200), nonce: String(repeating: "b", count: 200)).count <= 80, "and never long")
        let root = "/Users/x/Library/Application Support/Petal/run-browsers"
        expect(R.removable(root + "/note-1-ab", root: root), "a profile folder is one right inside Petal's folder")
        expect(!R.removable(root, root: root) && !R.removable(root + "/", root: root), "never the folder itself")
        expect(!R.removable(root + "/a/b", root: root) && !R.removable(root + "/../chats", root: root) && !R.removable("/Users/x/Library/Application Support/Google/Chrome", root: root),
               "never a folder inside one, above it, or anywhere else")
        expect(!R.removable(root + "/.hidden", root: root) && !R.removable(root + "/has space", root: root), "never a name Petal wouldn't have made")
        expect(!R.removable("/note-1", root: "/") && !R.removable("x", root: ""), "never with no root")

        expect(R.profile(inArguments: ["chrome", "--user-data-dir=" + root + "/note-1-ab", "--type=renderer"], root: root) == root + "/note-1-ab", "a process's profile is read from what it was started with")
        expect(R.profile(inArguments: ["chrome", "--user-data-dir=/Users/x/Library/Application Support/Google/Chrome"], root: root) == nil, "the person's own browser is nobody's leftover")
        expect(R.profile(inArguments: ["chrome", "--remote-debugging-pipe"], root: root) == nil, "nor one started with no profile")
        let processes: [(pid: Int32, arguments: [String])] = [
            (10, ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]),
            (11, ["chrome", "--user-data-dir=" + root + "/note-1-ab"]),
            (12, ["chrome helper", "--type=renderer", "--user-data-dir=" + root + "/note-1-ab"]),
            (13, ["chrome", "--user-data-dir=" + root + "/mcp-9-cd"]),
            (14, ["chrome", "--user-data-dir=/tmp/elsewhere"]),
        ]
        let swept = R.leftovers(processes: processes, folders: ["note-1-ab", "mcp-9-cd", "old-0-zz", ".DS_Store", "has space"], root: root, mine: [root + "/mcp-9-cd"])
        expect(swept.end == [11, 12], "only what was started with a run's profile is ended, and never one this Petal runs", "\(swept.end)")
        expect(swept.remove == [root + "/note-1-ab", root + "/old-0-zz"], "the profiles nobody holds are removed, and nothing that isn't one", "\(swept.remove)")
        let fresh = R.leftovers(processes: processes, folders: ["note-1-ab", "mcp-9-cd"], root: root, mine: [])
        expect(fresh.end == [11, 12, 13] && fresh.remove.count == 2, "at launch nothing is held: all of them go")

        expect(R.key("Enter")?.text == "\r" && R.key("return")?.key == "Enter", "Enter types a return")
        expect(R.key("shift-tab")?.shift == true && R.key("tab")?.shift == false, "shift goes with tab")
        expect(R.key("esc")?.key == "Escape" && R.key("down")?.key == "ArrowDown" && R.key("page down")?.key == "PageDown", "the keys a page is driven with")
        expect(R.key("cmd-q") == nil && R.key("a") == nil && R.key("shift-enter") == nil && R.key("") == nil, "and no others")
        expect(R.downloadRefused("report.pdf", from: "https://files.example.com/a/report.pdf").contains("“report.pdf” from files.example.com"), "a refused download is named")
    }

    // MARK: Addresses

    static func addressChecks() {
        typealias R = RunBrowserRules
        func goes(_ text: String) -> String? { if case .go(let address) = R.address(text) { return address } else { return nil } }
        expect(goes("https://example.com/a?b=1#c") == "https://example.com/a?b=1#c", "https opens")
        expect(goes("  example.com/shop ") == "https://example.com/shop", "a bare name is https")
        expect(goes("localhost:3000/app") == "http://localhost:3000/app" && goes("127.0.0.1:8080") == "http://127.0.0.1:8080", "this Mac's own pages are http")
        expect(goes("http://localhost:5173/") != nil && goes("http://127.0.0.1/") != nil && goes("http://[::1]:3000/") != nil && goes("http://app.localhost/") != nil, "http on this Mac opens")
        expect(goes("http://example.com/") == nil && goes("http://192.168.1.10/") == nil, "http anywhere else doesn't")
        expect(goes("localhost.example.com") == "https://localhost.example.com", "a name that only starts like this Mac's is a site like any other")
        expect(goes("http://localhost.example.com/") == nil, "and never http")
        for bad in ["file:///etc/hosts", "javascript:alert(1)", "data:text/html,<p>x", "chrome://settings", "about:blank", "ftp://example.com/", "view-source:https://example.com"] {
            expect(goes(bad) == nil, "\(bad) doesn't open")
        }
        expect(goes("https://user:pass@example.com/") == nil && goes("user@example.com") == nil, "never a name or password in the address")
        expect(goes("") == nil && goes("two words") == nil && goes("https://") == nil, "nothing, or two things, is no address")
    }

    // MARK: A page as text

    static func outlineChecks() {
        let plain: (String) -> String = { $0 }
        let never: (String) -> Bool = { _ in false }
        let nodes = [
            node(["k": "heading", "t": "Sign in", "lv": 1, "pa": 0, "sb": 0]),
            node(["k": "text", "t": "Welcome", "pa": 2, "sb": 0, "b": 2, "ja": 1]),
            node(["k": "text", "t": "back", "pa": 3, "sb": 0, "b": 2, "ja": 1]),
            node(["k": "text", "t": ", friend.", "pa": 2, "sb": 2, "b": 2, "jb": 1]),
            node(["k": "text", "t": "Another paragraph.", "pa": 4, "sb": 0, "b": 4]),
            node(["k": "link", "t": "Forgot it?", "u": "https://example.com/reset?token=abc#x", "e": 0, "pa": 4, "sb": 1, "r": [0, 0, 80, 20]]),
            node(["k": "field", "t": "Email", "y": "email", "v": "ada@example.com", "e": 1, "pa": 5, "sb": 0, "r": [0, 30, 200, 20], "fo": 1]),
            node(["k": "field", "t": "Password", "y": "password", "s": 1, "v": "should never be here", "e": 2, "pa": 5, "sb": 1, "r": [0, 60, 200, 20]]),
            node(["k": "select", "t": "Country", "v": "Turkey", "o": ["Germany", "Turkey", "United States"], "n": 190, "e": 3, "pa": 5, "sb": 2, "r": [0, 90, 200, 20]]),
            node(["k": "checkbox", "t": "Remember me", "on": 0, "e": 4, "pa": 5, "sb": 3, "r": [0, 120, 20, 20]]),
            node(["k": "button", "t": "Sign in", "e": 5, "d": 1, "pa": 5, "sb": 4, "r": [0, 150, 80, 30]]),
        ]
        let made = BrowserOutline.make(nodes: nodes, frames: ["https://example.com/login"], redact: plain, matches: never)
        let lines = made.text.components(separatedBy: "\n")
        expect(lines.first == "# Sign in", "a heading is a heading", made.text)
        expect(lines.contains("Welcome back, friend."), "pieces of one line read as the page spaces them", made.text)
        expect(lines.contains("Another paragraph."), "another block is another line")
        expect(lines.contains("[b1] link \"Forgot it?\" → example.com/reset"), "a link says where it goes, without what follows a ?", made.text)
        expect(lines.contains("[b2] email field \"Email\" = \"ada@example.com\" (has the cursor)"), "a field says what it holds", made.text)
        expect(lines.contains("[b3] password field \"Password\"") && !made.text.contains("should never be here"), "a password field never does", made.text)
        expect(lines.contains("[b4] select \"Country\" = \"Turkey\" (options: Germany, Turkey, United States, … 187 more)"), "a select says its choice and options", made.text)
        expect(lines.contains("[b5] checkbox \"Remember me\" (off)") && lines.contains("[b6] button \"Sign in\" (disabled)"), "a checkbox and a greyed-out button")
        expect(made.count == 6 && made.refs.count == 6 && made.refs["b3"]?.handle == 2 && made.refs["b3"]?.node.secure == true, "each id stands for its control")
        expect(made.left.isEmpty && !made.hid, "nothing left out, nothing hidden")
        expect(BrowserOutline.isID("b12") && !BrowserOutline.isID("e12") && !BrowserOutline.isID("b") && !BrowserOutline.isID("b1x") && !BrowserOutline.isID(""), "an id is b and a number")
        expect(PageNode(["t": "no kind"]) == nil, "what has no kind is no node")

        // find: only what has the word.
        let found = BrowserOutline.make(nodes: nodes, frames: ["https://example.com/login"], find: "remember", redact: plain, matches: never)
        expect(found.text == "[b1] checkbox \"Remember me\" (off)" && found.refs["b1"]?.handle == 4, "find gives only what has the word", found.text)

        // Caps: the controls in view first, and it says what was left out.
        var many: [PageNode] = []
        for index in 0..<260 {
            many.append(node(["k": "link", "t": "Link \(index)", "u": "https://example.com/\(index)", "e": index, "pa": 1, "sb": index, "iv": index >= 250 ? 1 : 0, "r": [0, 0, 10, 10]]))
        }
        let capped = BrowserOutline.make(nodes: many, frames: ["https://example.com/"], redact: plain, matches: never)
        expect(capped.count == BrowserOutline.cap && capped.left.contains("60 more controls"), "controls are capped, and it says how many were left out", capped.left)
        expect(capped.text.contains("\"Link 259\"") && capped.text.contains("\"Link 0\"") && !capped.text.contains("\"Link 249\""), "the ones in view come first")
        expect(capped.refs.values.map(\.handle).sorted().first == 0 && capped.text.components(separatedBy: "\n").first?.hasPrefix("[b1] link \"Link 0\"") == true, "still in reading order")
        var long: [PageNode] = []
        for index in 0..<400 { long.append(node(["k": "text", "t": String(repeating: "word ", count: 20) + "\(index)", "pa": index, "sb": 0, "b": index])) }
        let cut = BrowserOutline.make(nodes: long, frames: ["https://example.com/"], cut: true, redact: plain, matches: never)
        expect(cut.text.count <= BrowserOutline.textCap + 400 && cut.left.contains("more lines of text") && cut.left.contains("end of a very long page"), "words are capped too", cut.left)

        // Secrets: a field named for one, one the vault filled, one saved in the vault, and one shown in pieces.
        let index = UIMap.SecretIndex(["sk-petalcheck-0123456789abcdef", "4242424242424242", "737"])
        let secrets = [
            node(["k": "text", "t": "Your key is sk-petalcheck-0123456789abcdef, keep it safe.", "pa": 1, "sb": 0, "b": 1]),
            node(["k": "field", "t": "Card number", "i": "cardnumber cc-number", "v": "5555 0000 1111 2222", "e": 0, "pa": 2, "sb": 0, "r": [0, 0, 200, 20]]),
            node(["k": "field", "t": "Name on card", "v": "Ada Example", "e": 1, "pa": 2, "sb": 1, "r": [0, 30, 200, 20]]),
            node(["k": "field", "t": "Notes", "v": "paid with 4242 4242 4242 4242 today", "e": 2, "pa": 2, "sb": 2, "r": [0, 60, 200, 20]]),
            node(["k": "field", "t": "Discount for 4242-4242-4242-4242", "f": 1, "v": "x", "e": 3, "pa": 2, "sb": 3, "r": [0, 90, 200, 20]]),
            node(["k": "field", "t": "API token", "y": "text", "v": "anything at all", "e": 4, "pa": 2, "sb": 4, "r": [0, 120, 200, 20]]),
            node(["k": "select", "t": "Saved", "v": "Visa", "o": ["Visa", "4242424242424242"], "e": 5, "pa": 2, "sb": 5, "r": [0, 150, 200, 20]]),
        ]
        let hidden = BrowserOutline.make(nodes: secrets, frames: ["https://shop.example/"], redact: index.redacted, matches: index.matches, spans: index.spans)
        expect(hidden.text.contains("Your key is (hidden), keep it safe."), "a saved secret in the page's words is hidden, the words around it kept", hidden.text)
        expect(hidden.text.contains("[b1] field \"Card number\" = \"(hidden)\""), "a field named for a card number never says what it holds", hidden.text)
        expect(hidden.text.contains("[b2] field \"Name on card\" = \"Ada Example\""), "a field that isn't secret does")
        expect(hidden.text.contains("[b3] field \"Notes\" = \"(hidden)\""), "a field holding a saved card number is hidden")
        expect(hidden.text.contains("[b4] field \"(hidden)\" (filled by Petal)"), "a field Petal filled is hidden whole, its name too", hidden.text)
        expect(hidden.text.contains("[b5] field \"API token\" = \"(hidden)\""), "a field named for a token is hidden")
        expect(hidden.text.contains("(options: Visa, (hidden))"), "an option that is a secret is hidden")
        expect(!hidden.text.contains("4242") && !hidden.text.contains("sk-petalcheck") && !hidden.text.contains("5555") && hidden.hid, "nothing of them is left", hidden.text)
        let pieces = [
            node(["k": "field", "t": "", "v": "4242", "e": 0, "pa": 1, "sb": 0, "r": [0, 0, 50, 20]]),
            node(["k": "field", "t": "", "v": "4242", "e": 1, "pa": 1, "sb": 1, "r": [60, 0, 50, 20]]),
            node(["k": "field", "t": "", "v": "4242", "e": 2, "pa": 1, "sb": 2, "r": [120, 0, 50, 20]]),
            node(["k": "field", "t": "", "v": "4242", "e": 3, "pa": 1, "sb": 3, "r": [180, 0, 50, 20]]),
            node(["k": "text", "t": "Order 4242", "pa": 9, "sb": 0, "b": 9, "r": [0, 400, 80, 20]]),
        ]
        let joined = BrowserOutline.make(nodes: pieces, frames: ["https://shop.example/"], redact: index.redacted, matches: index.matches, spans: index.spans)
        expect(!joined.text.contains("= \"4242\"") && joined.text.components(separatedBy: "(hidden)").count == 5, "a card number shown as four fields is hidden in each", joined.text)
        expect(joined.text.contains("Order 4242"), "and an order number that only looks like a piece of it isn't", joined.text)
        // The lines only make a secret together: the whole is checked once more.
        let split = [node(["k": "text", "t": "code 7", "pa": 1, "sb": 0, "b": 1, "ja": 1]), node(["k": "text", "t": "37", "pa": 2, "sb": 0, "b": 1, "jb": 1])]
        let whole = BrowserOutline.make(nodes: split, frames: ["https://shop.example/"], redact: index.redacted, matches: index.matches, spans: index.spans)
        expect(!whole.text.contains("737"), "a secret a line only makes once it's put together never goes out", whole.text)
        let unread = UIMap.SecretIndex.unavailable
        let blind = BrowserOutline.make(nodes: nodes, frames: ["https://example.com/login"], redact: unread.redacted, matches: unread.matches, spans: unread.spans)
        expect(!blind.text.contains("ada@example.com") && !blind.text.contains("Welcome"), "while the vault can't be read nothing of a page is told", blind.text)

        // Frames: under their site, a step in; the page goes on after.
        var inner = node(["k": "field", "t": "Card number", "e": 0, "pa": 1, "sb": 0, "r": [0, 0, 100, 20]])
        inner.frame = 1
        var innerText = node(["k": "text", "t": "Pay securely", "pa": 1, "sb": 1, "b": 1])
        innerText.frame = 1
        let framed = [
            node(["k": "text", "t": "Checkout", "pa": 1, "sb": 0, "b": 1]),
            node(["k": "frame", "e": 1, "pa": 1, "sb": 1]),
            inner, innerText,
            node(["k": "button", "t": "Place order", "e": 0, "pa": 1, "sb": 2, "r": [0, 0, 100, 20]]),
            node(["k": "frame", "e": 7, "pa": 1, "sb": 3]),
        ]
        let nested = BrowserOutline.make(nodes: framed, frames: ["https://shop.example/checkout", "https://pay.example/frame?session=abc"], redact: plain, matches: never)
        expect(nested.text == "Checkout\n▸ frame (pay.example):\n  [b1] field \"Card number\"\n  Pay securely\n[b2] button \"Place order\"", "a frame's content sits under its site", nested.text)
        expect(nested.refs["b1"]?.frame == 1 && nested.refs["b2"]?.frame == 0, "each id knows its frame")
        expect(BrowserOutline.place("http://localhost:3000/x") == "http://localhost" && BrowserOutline.place("about:srcdoc") == "about" && BrowserOutline.place("") == "no address", "a frame's site is said, never its whole address")

        let parsed = BrowserOutline.nodes(fromJSON: "{\"n\":[{\"k\":\"text\",\"t\":\"hi\"},{\"nope\":1},{\"k\":\"field\",\"s\":1,\"v\":\"secret\",\"e\":0}],\"more\":1,\"title\":\"T\",\"gen\":3}")
        expect(parsed?.nodes.count == 2 && parsed?.more == true && parsed?.title == "T" && parsed?.generation == 3, "the script's answer reads back")
        expect(parsed?.nodes.last?.value == "", "and a password field's value is dropped even if it were sent")
        expect(BrowserOutline.nodes(fromJSON: "not json") == nil, "what isn't its answer is nothing")
    }

    // MARK: The vault, fed with what the browser says of a page's frames

    static func vaultChecks() {
        typealias R = RunBrowserRules
        func place(frame: String, top: String? = nil, tab: String? = nil, loader: String = "L1", trusted: Bool = true) -> Vault.Place {
            R.place(frame: frame, top: top ?? frame, tab: tab ?? top ?? frame, target: "T1", loader: loader, trusted: trusted, bundle: "com.google.Chrome", name: "Google Chrome")
        }
        var login = VaultItem(kind: .login, title: "Shop", sites: ["shop.example.com"])
        login[.username] = "ada"
        login[.password] = "pw"
        let secure = Vault.Target(secure: true, text: true, popup: false), text = Vault.Target(secure: false, text: true, popup: false)

        let own = place(frame: "https://shop.example.com/login")
        expect(own.web && own.host == "shop.example.com" && own.tab.id == "T1" && own.tab.page != nil, "a page of a browser Petal verified is a web page, in a tab")
        expect(Vault.decide(login, .password, target: secure, place: own) == .fill, "a login fills by itself on its own site")
        expect(Vault.decide(login, .username, target: text, place: own) == .fill, "its username too")
        if case .refuse = Vault.decide(login, .password, target: text, place: own) { expect(true, "") } else { expect(false, "a password only into a password field") }
        func asks(_ place: Vault.Place, _ what: String) {
            if case .ask = Vault.decide(login, .password, target: secure, place: place) { expect(true, "") } else { expect(false, what, "\(Vault.decide(login, .password, target: secure, place: place))") }
        }
        asks(place(frame: "https://shop.example.net/login"), "another site asks")
        asks(place(frame: "https://shop.example.com.evil.example/login"), "a site that only starts like it asks")
        asks(place(frame: "http://shop.example.com/login"), "its own site over http asks")
        asks(place(frame: "https://evil.example/frame", top: "https://shop.example.com/login"), "a field in another site's frame goes by the frame's site, whatever page holds it")
        asks(place(frame: "about:srcdoc", top: "https://shop.example.com/login"), "a frame with no address of its own asks")
        asks(place(frame: "https://shop.example.com/login", top: "http://news.example/"), "its own site's frame in a page that isn't secure asks")
        asks(place(frame: "https://shop.example.com/login", top: "https://shop.example.com/login", tab: "https://other.example/"), "the browser's own record of the tab naming another site asks")
        expect(Vault.decide(login, .password, target: secure, place: place(frame: "https://shop.example.com/login", top: "https://partner.example/embed")) == .fill,
               "its own site's frame in another secure page fills: the frame's site is where the password goes")
        let unverified = place(frame: "https://shop.example.com/login", trusted: false)
        expect(!unverified.web && unverified.unverified && unverified.claimedURL == "https://shop.example.com/login", "in a browser Petal couldn't verify, a page's address isn't believed")
        asks(unverified, "and nothing fills there by itself")
        var local = VaultItem(kind: .login, title: "Dev", sites: ["localhost"])
        local[.password] = "pw"
        expect(Vault.decide(local, .password, target: secure, place: place(frame: "http://localhost:3000/login")) == .fill, "http on this Mac is this Mac's own")
        if case .ask = Vault.decide(local, .password, target: secure, place: place(frame: "http://127.0.0.1:3000/login")) { expect(true, "") } else { expect(false, "localhost and 127.0.0.1 are two sites") }

        var card = VaultItem(kind: .card, title: "Visa")
        card[.number] = "4242424242424242"
        card[.expiry] = "04/31"
        card[.securityCode] = "737"
        let checkout = place(frame: "https://pay.example/frame", top: "https://shop.example.com/checkout")
        expect(Vault.decide(card, .number, target: text, place: checkout) == .buy(shop: "shop.example.com"), "payment info waits for Buy, on the shop the tab's page is")
        expect(Vault.decide(card, .number, target: text, place: checkout, checkout: true) == .fill, "and fills once Buy covers it")
        for bad in [place(frame: "http://shop.example.com/checkout"), place(frame: "https://pay.example/frame", top: "http://shop.example.com/checkout"),
                    place(frame: "https://shop.example.com/checkout", tab: "https://other.example/"), unverified, place(frame: "http://localhost:3000/pay")] {
            if case .refuse = Vault.decide(card, .number, target: text, place: bad, checkout: true) { expect(true, "") } else { expect(false, "payment info only on https, in a tab the browser agrees about", "\(bad)") }
        }
        expect(Vault.mixed(.login, [own, place(frame: "https://evil.example/frame", top: "https://shop.example.com/login")]) != nil, "a login's fields in two sites' frames are two places")
        expect(Vault.mixed(.card, [checkout, place(frame: "https://shop.example.com/checkout")]) == nil, "a card's fields in the shop's page and its payment frame are one checkout")

        // A Buy covers that tab, that document, that path; a page that became another is another page.
        let bought = Vault.Checkout(place: checkout, window: 0xF000_0001, card: card.id, revision: 1, turn: "t|")
        expect(bought != nil, "a Buy can be kept for a page of the run's browser")
        if let bought {
            let same = place(frame: "https://pay.example/frame", top: "https://shop.example.com/checkout")
            expect(bought.covers(same, window: 0xF000_0001, card: card.id, revision: 1, turn: "t|"), "the same page, read again, is covered")
            expect(!bought.covers(place(frame: "https://pay.example/frame", top: "https://shop.example.com/checkout", loader: "L2"), window: 0xF000_0001, card: card.id, revision: 1, turn: "t|"),
                   "the tab showing another document isn't")
            expect(!bought.covers(place(frame: "https://pay.example/frame", top: "https://shop.example.com/checkout/done"), window: 0xF000_0001, card: card.id, revision: 1, turn: "t|"), "nor another path")
            expect(!bought.covers(same, window: 0xF000_0002, card: card.id, revision: 1, turn: "t|") && !bought.covers(same, window: 0xF000_0001, card: card.id, revision: 1, turn: "u|"),
                   "nor another run's browser, nor another reply")
            expect(Vault.Checkout.seen([bought], pages: [], window: 0xF000_0001).isEmpty, "a page that moved on ends it")
            expect(Vault.Checkout.seen([bought], pages: [], window: 77).count == 1, "another window's pages say nothing of it")
        }
        expect(Vault.moved(from: own, to: place(frame: "https://shop.example.com/login")) == nil, "the same page, read again right before the value goes, hasn't moved")
        expect(Vault.moved(from: own, to: place(frame: "https://shop.example.com/login", loader: "L2")) != nil, "another document in the tab has")
        expect(Vault.moved(from: own, to: place(frame: "https://evil.example/login")) != nil, "another site has")
        expect(Vault.moved(from: checkout, to: place(frame: "https://pay.example/frame", top: "https://shop.example.com/checkout/2"), samePage: true) != nil, "for payment info, so has another path")
        expect(Vault.moved(from: own, to: unverified) != nil, "and a browser that stopped checking out")
    }

    // MARK: What's sent into a page

    static func scriptChecks() {
        let nasty = "it's \"quoted\"\n</script>\u{2028}); alert(1); (\\"
        let call = RunBrowserScript.call("f", ["type", 3, ["text": nasty, "replace": true, "gen": 2]])
        expect(call?.hasPrefix("f(\"type\", 3, {") == true && call?.hasSuffix("})") == true, "a call is the function and its arguments", call ?? "nil")
        // Its arguments read back as the very values: nothing in a text is ever read as code.
        if let call {
            let arguments = "[" + call.dropFirst(2).dropLast() + "]"
            let back = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [Any]
            expect(back?.count == 3 && (back?[2] as? [String: Any])?["text"] as? String == nasty, "whatever is typed goes in as a value", arguments)
            expect(!call.contains("\n"), "and never breaks out of its line")
        }
        expect(RunBrowserScript.call("f", [Date()]) == nil, "what can't be written as a value isn't sent")
        expect(RunBrowserScript.collect.contains("S.secure.add(el)") && RunBrowserScript.act.contains("if ((a.secure ? true : false) !== secure) return out({changed: 1});"),
               "the page script keeps password fields apart, and a fill checks the field is still the kind it was")
        expect(RunBrowserScript.act.contains("} else if (secure || S.filled.has(el)) {") && RunBrowserScript.act.contains("return out({secure: 1});"),
               "typing never goes into a password field or one the vault filled")
    }
}
