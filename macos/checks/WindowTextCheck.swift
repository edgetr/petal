import CoreGraphics
import Foundation

// Checks WindowText in UIMap.swift: a window's words for petal_look's text, made from made-up Accessibility trees
// (reading order, a page without its browser's toolbar, the cap and the next part, find, a secret hidden, a password
// field left out). Run with macos/checks/run.sh.
@main
struct WindowTextCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    /// A tree built in reading order: each node's order is its place, its parent given by order.
    struct Tree {
        var nodes: [UINode] = []
        @discardableResult
        mutating func add(_ role: String, parent: Int = -1, value: String = "", title: String = "", label: String = "",
                          subrole: String = "", web: Bool? = nil) -> Int {
            var node = UINode(role: role)
            node.subrole = subrole
            node.value = value
            node.title = title
            node.label = label
            node.order = nodes.count
            node.parent = parent
            node.web = web ?? (parent >= 0 && (nodes[parent].web || nodes[parent].role == "AXWebArea"))
            nodes.append(node)
            return node.order
        }
    }

    static func main() {
        // MARK: A browser's page, without its toolbar

        var page = Tree()
        let window = page.add("AXWindow")
        let toolbar = page.add("AXToolbar", parent: window)
        page.add("AXButton", parent: toolbar, title: "Back")
        page.add("AXTextField", parent: toolbar, value: "https://example.com/watch")
        let web = page.add("AXWebArea", parent: window, title: "Video")
        let h1 = page.add("AXHeading", parent: web)
        page.add("AXStaticText", parent: h1, value: "Stop Picking The Wrong Model")
        let p = page.add("AXGroup", parent: web)
        page.add("AXStaticText", parent: p, value: "Read ")
        let link = page.add("AXLink", parent: p)
        page.add("AXStaticText", parent: link, value: "the docs")
        page.add("AXStaticText", parent: p, value: " now.")
        let chapters = page.add("AXList", parent: web)
        let item1 = page.add("AXGroup", parent: chapters)
        page.add("AXStaticText", parent: item1, value: "0:00 Intro")
        let item2 = page.add("AXGroup", parent: chapters)
        page.add("AXStaticText", parent: item2, value: "4:12 Which model")
        page.add("AXButton", parent: web, title: "Show transcript")
        let subscribe = page.add("AXButton", parent: web, title: "Subscribe")
        page.add("AXStaticText", parent: subscribe, value: "Subscribe")
        page.add("AXTextField", parent: web, value: "hunter2", subrole: "AXSecureTextField")
        let lines = WindowText.lines(page.nodes)
        expect(lines == ["# Stop Picking The Wrong Model", "Read the docs now.", "0:00 Intro", "4:12 Which model", "Show transcript", "Subscribe"],
               "a page in reading order: a heading, a sentence with a link in it on one line, a list, buttons' words once", "\(lines)")
        expect(!lines.contains { $0.contains("example.com") || $0 == "Back" }, "never the browser's toolbar or address field")
        expect(!lines.contains { $0.contains("hunter2") }, "a password field gives nothing")

        // MARK: A window that isn't a page: all of its words

        var mail = Tree()
        let w = mail.add("AXWindow")
        mail.add("AXButton", parent: w, title: "Reply")
        let table = mail.add("AXTable", parent: w)
        let row = mail.add("AXRow", parent: table)
        let cell1 = mail.add("AXCell", parent: row)
        mail.add("AXStaticText", parent: cell1, value: "Ada")
        let cell2 = mail.add("AXCell", parent: row)
        mail.add("AXStaticText", parent: cell2, value: "Lunch on Friday?")
        mail.add("AXTextArea", parent: w, value: "Hi Ada,\n\nFriday works.\nSee you")
        let mailLines = WindowText.lines(mail.nodes)
        expect(mailLines == ["Reply", "Ada", "Lunch on Friday?", "Hi Ada,", "Friday works.", "See you"],
               "elsewhere every word, a document's own lines kept", "\(mailLines)")
        var cellButton = Tree()
        let cw = cellButton.add("AXWindow")
        let cell = cellButton.add("AXCell", parent: cw, title: "Row")
        cellButton.add("AXButton", parent: cell, title: "Open")
        expect(WindowText.lines(cellButton.nodes) == ["Open"], "a holder whose button says its name doesn't say its own too")

        // MARK: Joining pieces

        expect(WindowText.join("Read", "the docs") == "Read the docs" && WindowText.join("docs", ".") == "docs."
               && WindowText.join("Read ", "docs") == "Read docs" && WindowText.join("(", "a") == "(a", "pieces spaced as a page spaces them")
        expect(WindowText.tidyLine("  a \t b  ") == "a b", "a line's spaces tidied")

        // MARK: The cap and the next part

        let long = (1...3000).map { "Line \($0) of a long page" }.joined(separator: "\n")
        let parts = WindowText.parts(long, cap: WindowText.cap)
        expect(parts.count > 1 && parts.allSatisfy { $0.count <= WindowText.cap }, "a long page in parts of at most the cap", "\(parts.map(\.count))")
        expect(parts.joined(separator: "\n") == long, "the parts are the page, cut only at line ends")
        let first = WindowText.page(long, part: 1)
        expect(first.part == 1 && first.parts == parts.count && first.text == parts[0], "part 1 is the first")
        expect(first.left == parts.dropFirst().reduce(0) { $0 + $1.count }, "and says how much more there is")
        let second = WindowText.page(long, part: 2)
        expect(second.text == parts[1] && second.part == 2, "part 2 is the next")
        let past = WindowText.page(long, part: 99)
        expect(past.part == parts.count && past.left == 0, "past the end: the last part, nothing left")
        let short = WindowText.page("one line", part: 1)
        expect(short.text == "one line" && short.parts == 1 && short.left == 0, "a short page is one part")
        let oneLine = String(repeating: "x", count: 30_000)
        expect(WindowText.parts(oneLine, cap: 12_000).map(\.count) == [12_000, 12_000, 6_000], "one line longer than a part is cut")

        // MARK: find

        let found = WindowText.find("model", in: ["Intro", "Picking a Model", "Why", "Other", "x", "y", "The MODÈL again", "z"])
        expect(found.found == 2 && found.text == "Intro\nPicking a Model\nWhy\n…\ny\nThe MODÈL again\nz",
               "find gives the passages around a word, case and accents aside", found.text)
        let touching = WindowText.find("a", in: ["a1", "b", "a2"])
        expect(touching.found == 1 && touching.text == "a1\nb\na2", "passages that touch are one")
        let capped = WindowText.find("k", in: (1...2000).map { $0 % 3 == 0 ? "k\($0) " + String(repeating: "w", count: 40) : "-" }, around: 0, cap: 1000)
        expect(capped.text.count <= 1000 && capped.found == 666 && capped.left > 600, "find keeps to its cap and says how many didn't fit",
               "\(capped.text.count) \(capped.found) \(capped.left)")
        expect(WindowText.find("absent", in: ["a"]).found == 0, "nothing found: nothing told")

        // MARK: Secrets

        let index = UIMap.SecretIndex(["sk-ant-0123456789abcdef"])
        var secretPage = Tree()
        let sw = secretPage.add("AXWindow")
        secretPage.add("AXStaticText", parent: sw, value: "Your key is sk-ant-0123456789abcdef, keep it safe")
        secretPage.add("AXTextField", parent: sw, value: "sk-ant-0123456789abcdef", label: "Token")
        secretPage.add("AXTextField", parent: sw, value: "s3cret", subrole: "AXSecureTextField")
        let shown = secretPage.nodes.map { UIMap.redactWords($0, secret: index.matches, redacted: index.redacted) }
        let secretLines = WindowText.lines(shown)
        expect(secretLines == ["Your key is (hidden), keep it safe", "(hidden)"],
               "a secret in a sentence loses only the secret; a field named for a token is hidden; a password field gives nothing", "\(secretLines)")
        expect(!secretLines.joined().contains("0123456789abcdef") && !secretLines.joined().contains("s3cret"), "no secret anywhere")
        var filled = UINode(role: "AXTextField")
        filled.value = "4242 4242"
        filled.title = "Card"
        let hiddenFilled = UIMap.redactWords(filled, filled: true, secret: index.matches, redacted: index.redacted)
        expect(hiddenFilled.value == UIMap.hidden && hiddenFilled.title == UIMap.hidden, "a field Petal filled is hidden whole")
        // A secret only the pieces show together (a card number in four spans) is hidden in each, as petal_ui does.
        let card = UIMap.SecretIndex(["4242424242424242"])
        var pieces = Tree()
        let pw = pieces.add("AXWindow")
        let group = pieces.add("AXGroup", parent: pw)
        for part in ["4242", "4242", "4242", "4242"] { pieces.add("AXStaticText", parent: group, value: part) }
        let joined = UIMap.hideJoined(pieces.nodes, matches: card.matches, spans: card.spans).nodes
            .map { UIMap.redactWords($0, secret: card.matches, redacted: card.redacted) }
        expect(!WindowText.lines(joined).joined().contains("4242"), "a secret in pieces is hidden in each", "\(WindowText.lines(joined))")
        let unreadable = UIMap.SecretIndex.unavailable
        let blind = page.nodes.map { UIMap.redactWords($0, secret: unreadable.matches, redacted: unreadable.redacted) }
        expect(WindowText.lines(blind).allSatisfy { $0.replacingOccurrences(of: UIMap.hidden, with: "").allSatisfy { " #".contains($0) } },
               "the vault unreadable: nothing told as checked", "\(WindowText.lines(blind))")

        print(failures == 0 ? "ok: \(passed) checks" : "\(failures) failed, \(passed) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
