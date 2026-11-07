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

        print("UIMap: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
