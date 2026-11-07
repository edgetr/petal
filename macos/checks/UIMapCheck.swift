import CoreGraphics
import Foundation

// Checks UIMap.swift: which controls Petal AI is told about, what they're called, and the keys and menu paths it
// gives. Run with macos/checks/run.sh.
@main
struct UIMapCheck {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    static func node(_ role: String, _ title: String = "", at y: CGFloat = 10, order: Int, subrole: String = "", value: String = "",
                     enabled: Bool = true, pressable: Bool = false, clip: CGRect? = nil) -> UINode {
        UINode(role: role, subrole: subrole, title: title, value: value, frame: CGRect(x: 10, y: y, width: 80, height: 20),
               enabled: enabled, pressable: pressable, order: order, clip: clip)
    }

    static func main() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)

        // Only actionable controls; a group counts only when it says it can be pressed.
        let mixed = [node("AXButton", "Export", order: 0), node("AXStaticText", "Hello", at: 40, order: 1),
                     node("AXGroup", "Card", at: 70, order: 2, pressable: true), node("AXGroup", "Box", at: 100, order: 3),
                     node("AXLink", "Docs", at: 130, order: 4)]
        let picked = UIMap.select(mixed, window: window).shown.map(\.title)
        expect(picked == ["Export", "Card", "Docs"], "actionable only", "\(picked)")

        // Visible before off-screen, enabled before greyed out, and the cap holds.
        var many: [UINode] = []
        for i in 0..<200 { many.append(node("AXButton", "B\(i)", at: CGFloat(i) * 25, order: i)) }   // past 600 is off the window
        let capped = UIMap.select(many, window: window)
        expect(capped.shown.count == 150, "capped at 150", "\(capped.shown.count)")
        expect(capped.left == 50, "says how many more", "\(capped.left)")
        expect(capped.shown.first?.title == "B0", "visible first, in order")
        let visibleCount = many.filter { UIMap.isVisible($0, window: window) }.count
        expect(capped.shown.prefix(visibleCount).allSatisfy { UIMap.isVisible($0, window: window) }, "visible ones lead")
        let small = UIMap.select([node("AXButton", "Off", order: 0, enabled: false), node("AXButton", "On", at: 40, order: 1),
                                  node("AXButton", "Far", at: 900, order: 2)], window: window, cap: 2)
        expect(small.shown.map(\.title) == ["Off", "On"], "greyed-out visible beats off-screen", "\(small.shown.map(\.title))")
        let tight = UIMap.select([node("AXButton", "Off", order: 0, enabled: false), node("AXButton", "On", at: 40, order: 1)], window: window, cap: 1)
        expect(tight.shown.map(\.title) == ["On"], "enabled beats greyed out", "\(tight.shown.map(\.title))")

        // Hidden inside a scroll area's clip.
        let clipped = node("AXButton", "Below", at: 400, order: 0, clip: CGRect(x: 0, y: 0, width: 800, height: 300))
        expect(!UIMap.isVisible(clipped, window: window), "outside its scroll area is hidden")
        expect(!UIMap.isVisible(UINode(role: "AXButton", frame: .zero), window: window), "no size is hidden")

        // A control repeating its wrapper once; find narrows.
        let twice = [node("AXCell", "Row", order: 0, pressable: true), node("AXButton", "Row", order: 1)]
        expect(UIMap.select(twice, window: window).shown.count == 1, "same place and name once")
        let found = UIMap.select(mixed, window: window, find: "doc")
        expect(found.shown.map(\.title) == ["Docs"], "find narrows", "\(found.shown.map(\.title))")

        // Never a password field's value, not even through find.
        let secret = node("AXTextField", "Password", order: 0, subrole: "AXSecureTextField", value: "hunter2")
        expect(UIMap.value(secret) == nil, "no password value")
        expect(UIMap.kind(secret) == "password field", "called a password field")
        expect(UIMap.select([secret], window: window, find: "hunter").shown.isEmpty, "find never matches a password")
        expect(UIMap.value(node("AXCheckBox", "Wrap", order: 0, value: "1")) == "on", "checkbox on")
        expect(UIMap.value(node("AXTextField", "Name", order: 0, value: String(repeating: "x", count: 300)))?.count == 120, "values truncated")
        expect(UIMap.name(UINode(role: "AXButton", label: "  Share\n  this ")) == "Share this", "label tidied")
        expect(UIMap.kind(node("AXRadioButton", order: 0, subrole: "AXTabButton")) == "tab", "tab")

        // Moved or not.
        expect(!UIMap.moved(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 2, y: 1, width: 101, height: 100)), "a point or two is the same")
        expect(UIMap.moved(CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 30, y: 0, width: 100, height: 100)), "moved")

        // Menus.
        expect(UIMap.menuPath("File > Export…") == ["File", "Export…"], "menu path")
        expect(UIMap.menuPath("View › Show Sidebar") == ["View", "Show Sidebar"], "menu path ›")
        expect(UIMap.sameTitle("Export...", "Export…"), "dots are an ellipsis")
        expect(UIMap.sameTitle("export", "Export…"), "ellipsis optional")
        expect(!UIMap.sameTitle("Export", "Export as PDF…"), "not a prefix match")

        // Keys.
        let save = UIMap.parseKey("cmd-s")
        expect(save?.code == 1 && save?.flags == .maskCommand && save?.label == "⌘S", "cmd-s", "\(String(describing: save))")
        let shifted = UIMap.parseKey("cmd+shift+z")
        expect(shifted?.code == 6 && shifted?.flags.contains(.maskShift) == true && shifted?.label == "⇧⌘Z", "cmd+shift+z")
        expect(shifted?.menuModifiers == 1, "menu modifiers: shift with ⌘")
        expect(UIMap.parseKey("⌘⇧S")?.flags == [.maskCommand, .maskShift], "symbols")
        expect(UIMap.parseKey("return")?.code == 36, "return")
        expect(UIMap.parseKey("down")?.menuModifiers == 8, "no ⌘")
        expect(UIMap.parseKey("cmd--")?.code == 27, "cmd and minus")
        expect(UIMap.parseKey("cmd-+") == nil, "plus isn't a key here")
        expect(UIMap.parseKey("hyper-k") == nil, "unknown modifier")
        expect(UIMap.parseKey("cmd-") == nil, "no key")

        expect(UIMap.caption("press", name: "Export", kind: "button") == "Pressing Export", "caption")
        expect(UIMap.caption("type", name: "", kind: "search field") == "Typing in the search field", "caption without a name")

        // Vault secrets: whole, or 8 characters or more of one, never shown; short pieces and other text are.
        let vault = UIMap.SecretIndex(["sk-live-4f9a2b7c1d", "1234"])
        expect(vault.matches("sk-live-4f9a2b7c1d"), "a whole secret")
        expect(vault.matches("Bearer sk-live-4f9a2b7c1d please"), "a secret inside text")
        expect(vault.matches("token 4f9a2b7c"), "8 characters of a secret")
        expect(!vault.matches("4f9a2b7"), "7 characters aren't enough")
        expect(vault.matches("1234") && vault.matches(" 1234\n"), "a short secret, whole")
        expect(vault.matches("Room 1234") && vault.matches("PIN: 1234.") && vault.matches("(1234)"), "a short secret, as a word inside text")
        expect(!vault.matches("12345") && !vault.matches("A1234B") && !vault.matches("01234"), "not run into other letters or digits")
        expect(!vault.matches("123") && !vault.matches("Year 2024"), "nor a part of it, nor other numbers")
        let pins = UIMap.SecretIndex(["739251", "abc"])
        expect(pins.matches("Door PIN: 739251"), "a six-digit PIN inside text")
        expect(!pins.matches("7392510") && !pins.matches("Ref 739251x"), "a PIN inside a longer number or word isn't")
        expect(pins.matches("abc") && !pins.matches("abc def"), "under 4 characters: only the whole text")
        expect(!vault.matches("Inbox"), "other text")
        expect(!UIMap.SecretIndex([]).matches("anything"), "an empty vault matches nothing")

        let filled = node("AXTextField", "Notes", order: 0, value: "use sk-live-4f9a2b7c1d here")
        let shown = UIMap.redact(filled) { vault.matches($0) }
        expect(shown.value == UIMap.hidden && UIMap.value(shown) == UIMap.hidden, "a vault secret in a field is hidden", shown.value)
        expect(shown.title == "Notes", "its name stays")
        var titled = node("AXButton", "Copy sk-live-4f9a2b7c1d", order: 0)
        titled = UIMap.redact(titled) { vault.matches($0) }
        expect(titled.title == UIMap.hidden, "a vault secret in a name is hidden")
        var token = node("AXTextField", "API token", order: 0, value: "ghp_abc")
        token = UIMap.redact(token) { _ in false }
        expect(token.value == UIMap.hidden, "a token field's value is hidden")
        var keyed = UINode(role: "AXTextField", identifier: "passwordInput", value: "hunter2")
        keyed = UIMap.redact(keyed) { _ in false }
        expect(keyed.value == UIMap.hidden, "a field whose identifier says password is hidden")
        let plain = UIMap.redact(node("AXTextField", "Subject", order: 0, value: "Lunch")) { vault.matches($0) }
        expect(plain.value == "Lunch", "an ordinary value stays")
        expect(UIMap.select([shown], window: window, find: "sk-live").shown.isEmpty, "find never matches a hidden value")

        // Has the window changed since petal_ui?
        let then = UIMap.fingerprint(title: "Inbox", focusRole: "AXTable", focusSubrole: "", focusValue: "", selected: ["#3 Lunch on Friday"])
        expect(UIMap.changed(then, then) == nil, "the same window")
        let other = UIMap.fingerprint(title: "Inbox", focusRole: "AXTable", focusSubrole: "", focusValue: "", selected: ["#4 Invoice"])
        expect(UIMap.changed(then, other)?.contains("selected") == true, "another email selected", "\(String(describing: UIMap.changed(then, other)))")
        let renamed = UIMap.fingerprint(title: "Sent", focusRole: "AXTable", focusSubrole: "", focusValue: "", selected: ["#3 Lunch on Friday"])
        expect(UIMap.changed(then, renamed)?.contains("title") == true, "another title")
        let typing = UIMap.fingerprint(title: "Inbox", focusRole: "AXTextField", focusSubrole: "", focusValue: "a", selected: ["#3 Lunch on Friday"])
        expect(UIMap.changed(then, typing)?.contains("keyboard") == true, "another control has the keyboard")
        let spaced = UIMap.fingerprint(title: "  Inbox ", focusRole: "AXTable", focusSubrole: "", focusValue: "", selected: ["#3  Lunch on\nFriday"])
        expect(UIMap.changed(then, spaced) == nil, "whitespace isn't a change")
        let secret1 = UIMap.fingerprint(title: "Log in", focusRole: "AXTextField", focusSubrole: "AXSecureTextField", focusValue: "a", selected: [])
        let secret2 = UIMap.fingerprint(title: "Log in", focusRole: "AXTextField", focusSubrole: "AXSecureTextField", focusValue: "ab", selected: [])
        expect(secret1 == secret2 && !secret1.focus.contains("a="), "a password field's value isn't kept")
        // Two empty fields alike: told apart by where they are, the app's name for them, and the element itself.
        let to = UIMap.fingerprint(title: "New Message", focusRole: "AXTextField", focusSubrole: "", focusValue: "",
                                   focusFrame: CGRect(x: 80, y: 60, width: 400, height: 22), selected: [])
        let cc = UIMap.fingerprint(title: "New Message", focusRole: "AXTextField", focusSubrole: "", focusValue: "",
                                   focusFrame: CGRect(x: 80, y: 90, width: 400, height: 22), selected: [])
        expect(UIMap.changed(to, cc)?.contains("keyboard") == true, "another empty field, elsewhere")
        let named = UIMap.fingerprint(title: "New Message", focusRole: "AXTextField", focusSubrole: "", focusValue: "", focusIdentifier: "cc",
                                      focusFrame: CGRect(x: 80, y: 60, width: 400, height: 22), selected: [])
        expect(UIMap.changed(to, named) != nil, "another empty field, named otherwise by its app")
        let first = NSObject(), second = NSObject()
        let here = UIMap.fingerprint(title: "T", focusRole: "AXTextField", focusSubrole: "", focusValue: "", focused: first, selected: [])
        let there = UIMap.fingerprint(title: "T", focusRole: "AXTextField", focusSubrole: "", focusValue: "", focused: second, selected: [])
        expect(UIMap.changed(here, there) != nil && here != there, "another element in the same place")
        expect(UIMap.changed(here, UIMap.fingerprint(title: "T", focusRole: "AXTextField", focusSubrole: "", focusValue: "", focused: first, selected: [])) == nil,
               "the same element")

        print("UIMap: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
