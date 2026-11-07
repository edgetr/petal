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
        // Typing in batches never cuts a character in two.
        for text in ["Thanks so much 😀", "Aile: 👨‍👩‍👧‍👦👨‍👩‍👧‍👦 ve 🇹🇷", String(repeating: "é😀", count: 20), "plain ascii text that is long enough"] {
            let parts = UIMap.batches(text)
            expect(parts.allSatisfy { String(utf16CodeUnits: $0, count: $0.count).utf16.count == $0.count && String(decoding: $0, as: UTF16.self).unicodeScalars.allSatisfy { $0 != "\u{FFFD}" } },
                   "no batch holds half a character", text)
            expect(parts.map { String(decoding: $0, as: UTF16.self) }.joined() == text, "the batches make the text again", text)
            expect(parts.allSatisfy { $0.count <= 16 || String(decoding: $0, as: UTF16.self).count == 1 }, "16 units at most, or one long character", text)
        }
        // A long draft: an edit past the first 200 characters, or the caret moving, is a change.
        let draft = String(repeating: "Dear team, ", count: 40)
        let before = UIMap.fingerprint(title: "Draft", focusRole: "AXTextArea", focusSubrole: "", focusValue: draft, focusRange: "10,0")
        let edited = UIMap.fingerprint(title: "Draft", focusRole: "AXTextArea", focusSubrole: "", focusValue: draft + "PS", focusRange: "10,0")
        expect(UIMap.changed(before, edited) != nil, "an edit at the end of a long draft")
        let moved = UIMap.fingerprint(title: "Draft", focusRole: "AXTextArea", focusSubrole: "", focusValue: draft, focusRange: "300,5")
        expect(UIMap.changed(before, moved) != nil, "the caret or selection moved")
        expect(UIMap.changed(before, UIMap.fingerprint(title: "Draft", focusRole: "AXTextArea", focusSubrole: "", focusValue: draft, focusRange: "10,0")) == nil,
               "the same draft, caret and all")
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

        // Every selected row counts, not only the first five; a count that can't be read isn't known.
        let fiveRows = (1...5).map { "#\($0) File \($0).pdf" }
        let five = UIMap.fingerprint(title: "Downloads", focusRole: "", focusSubrole: "", focusValue: "",
                                     selection: UIMap.selection([UIMap.Selected(count: 5, rows: fiveRows)]))
        let six = UIMap.fingerprint(title: "Downloads", focusRole: "", focusSubrole: "", focusValue: "",
                                    selection: UIMap.selection([UIMap.Selected(count: 6, rows: fiveRows + ["#6||||"])]))
        expect(UIMap.changed(five, six)?.contains("selected") == true, "a sixth row selected is a change")
        let manyRows = (1...40).map { "#\($0)" }
        var swapped = manyRows
        swapped[30] = "#99"
        let a = UIMap.selection([UIMap.Selected(count: 40, rows: manyRows)])
        let b = UIMap.selection([UIMap.Selected(count: 40, rows: swapped)])
        expect(a.text != b.text && a.known && b.known, "another row deep in a big selection is a change")
        expect(UIMap.selection([UIMap.Selected(count: 40, rows: manyRows)]).text == a.text, "the same rows, the same print")
        let unread = UIMap.selection([UIMap.Selected(count: nil)])
        expect(!unread.known, "a count that couldn't be read isn't known")
        expect(!UIMap.selection([UIMap.Selected(count: 40, rows: Array(manyRows.prefix(12)), complete: false)]).known, "out of time isn't known")
        let rowsAtCap = (1...UIMap.rowCap).map { "#\($0)" }
        expect(!UIMap.selection([UIMap.Selected(count: 600, rows: rowsAtCap)]).known, "past the cap isn't known")
        expect(UIMap.selection([UIMap.Selected(count: 600, rows: rowsAtCap)]).text == UIMap.selection([UIMap.Selected(count: 600, rows: Array(rowsAtCap.prefix(5)) + ["changed"])]).text,
               "past the cap, a change beyond the first rows can't be seen: so it isn't known")
        expect(UIMap.selection([UIMap.Selected(count: UIMap.rowCap, rows: rowsAtCap)]).known, "up to the cap, read whole, is known")
        expect(!UIMap.selection([UIMap.Selected(count: 40, rows: Array(manyRows.prefix(39)))]).known, "rows short of the count aren't known")
        expect(UIMap.unsure(UIMap.fingerprint(title: "t", focusRole: "", focusSubrole: "", focusValue: "", selection: UIMap.selection([UIMap.Selected(count: 600, rows: rowsAtCap)])),
                            UIMap.fingerprint(title: "t", focusRole: "", focusSubrole: "", focusValue: "", selection: UIMap.selection([UIMap.Selected(count: 600, rows: rowsAtCap)])),
                            destructive: true, age: 60) != nil, "Delete on 600 selected rows only straight after a look")
        expect(UIMap.selection([]).known && UIMap.selection([UIMap.Selected(count: 0)]).known, "nothing selected is known")

        // Destructive menu items and keys need a fresh look while the selection isn't known.
        expect(UIMap.destructive(menu: "File › Move to Trash") && UIMap.destructive(menu: "Edit › Delete")
               && UIMap.destructive(menu: "File › Close Window") && UIMap.destructive(menu: "Mail › Quit Mail"), "destructive menu items")
        expect(!UIMap.destructive(menu: "File › Export…") && !UIMap.destructive(menu: "Edit › Copy") && !UIMap.destructive(menu: nil),
               "other menu items aren't")
        for text in ["delete", "cmd-delete", "cmd-backspace", "forwarddelete", "cmd-w", "cmd-q", "cmd-shift-w", "cmd-option-w"] {
            expect(UIMap.parseKey(text).map(UIMap.destructive(key:)) == true, "destructive key \(text)")
        }
        for text in ["cmd-s", "return", "w", "cmd-c", "down"] {
            expect(UIMap.parseKey(text).map(UIMap.destructive(key:)) == false, "not destructive: \(text)")
        }
        let unknownNow = UIMap.fingerprint(title: "Downloads", focusRole: "", focusSubrole: "", focusValue: "", selection: unread)
        expect(UIMap.unsure(five, unknownNow, destructive: true, age: 60) != nil, "unknown selection, old look: refused")
        expect(UIMap.unsure(unknownNow, unknownNow, destructive: true, age: 3) == nil, "unknown selection, fresh look: goes")
        expect(UIMap.unsure(unknownNow, unknownNow, destructive: false, age: 60) == nil, "not destructive: goes")
        expect(UIMap.unsure(five, five, destructive: true, age: 600) == nil, "known selection: goes")

        // Copy, Cut and Paste: by key, by a menu item's shortcut (any language), by the app's own name, by words.
        func keyClip(_ text: String) -> UIMap.Clip? { UIMap.parseKey(text).flatMap(UIMap.clip(key:)) }
        expect(["cmd-c", "cmd-x", "cmd-shift-c", "⌘C"].allSatisfy { keyClip($0) == .copy }, "copy keys")
        expect(["c", "ctrl-c", "cmd-s"].allSatisfy { keyClip($0) == nil } && keyClip("cmd-v") == .paste, "not copy keys")
        expect(["cmd-v", "cmd-shift-alt-v", "⌘V"].allSatisfy { keyClip($0) == .paste }, "paste keys")
        expect(["v", "ctrl-v"].allSatisfy { keyClip($0) == nil }, "not paste keys")
        expect(UIMap.clip(shortcut: "V") == .paste && UIMap.clip(shortcut: "V", modifiers: 3) == .paste, "⌘V and ⌥⇧⌘V paste")
        expect(UIMap.clip(shortcut: "C") == .copy && UIMap.clip(shortcut: "X") == .copy, "⌘C and ⌘X copy")
        expect(UIMap.clip(shortcut: "V", modifiers: 8) == nil && UIMap.clip(shortcut: "S") == nil && UIMap.clip(shortcut: nil) == nil, "no ⌘, or another key")
        // A menu item's shortcut beats its words: Turkish, Japanese, or a title that says nothing.
        expect(UIMap.clip(menuItem: "Düzen › Yapıştır", character: "V") == .paste, "Yapıştır with ⌘V")
        expect(UIMap.clip(menuItem: "Édition › Bidule", character: "V", modifiers: 3) == .paste, "any title with ⌥⇧⌘V")
        expect(UIMap.clip(menuItem: "File › Save", character: "S") == nil, "⌘S is neither")
        expect(UIMap.clip(menuItem: "Edit › Something", identifier: "pasteAsPlainText:") == .paste, "a paste selector")
        expect(UIMap.clip(menuItem: "Edit › Something", identifier: "cut:") == .copy && UIMap.clip(identifier: "copy:") == .copy, "copy and cut selectors")
        expect(UIMap.clip(identifier: "paste-button") == .paste && UIMap.clip(identifier: "PasteButton") == .paste, "a web page's or app's paste button")
        expect(UIMap.clip(identifier: "_NS:123") == nil && UIMap.clip(identifier: "shortcutsButton") == nil && UIMap.clip(identifier: "copyright") == nil
               && UIMap.clip(identifier: "NSPasteboardHistory") == nil, "other identifiers")
        // Words, as a fallback, in the languages macOS speaks most.
        let pasteTitles = ["Edit › Paste", "Edit › Paste and Match Style", "Düzen › Yapıştır", "DÜZEN › YAPIŞTIR", "Bearbeiten › Einsetzen",
                           "Bearbeiten › Einfügen", "Édition › Coller", "Edición › Pegar", "Modifica › Incolla", "Editar › Colar",
                           "Wijzig › Plakken", "編集 › ペースト", "編集 › 貼り付け", "编辑 › 粘贴", "편집 › 붙여넣기", "Правка › Вставить",
                           "Edit › Paste…"]
        for title in pasteTitles { expect(UIMap.clip(title: title) == .paste, "paste: \(title)", "\(String(describing: UIMap.clip(title: title)))") }
        let copyTitles = ["Edit › Copy", "Edit › Cut", "Edit › Copy Link", "Düzen › Kopyala", "Düzen › Kes", "Bearbeiten › Kopieren",
                          "Bearbeiten › Ausschneiden", "Édition › Copier", "Édition › Couper", "Edición › Copiar", "Edición › Cortar",
                          "Modifica › Copia", "Modifica › Taglia", "Editar › Recortar", "Wijzig › Kopiëren", "Wijzig › Knippen",
                          "編集 › コピー", "編集 › カット", "编辑 › 拷贝", "编辑 › 复制", "编辑 › 剪切", "편집 › 복사", "편집 › 잘라내기",
                          "Правка › Скопировать", "Правка › Копировать", "Правка › Вырезать"]
        for title in copyTitles { expect(UIMap.clip(title: title) == .copy, "copy: \(title)", "\(String(describing: UIMap.clip(title: title)))") }
        for title in ["File › Duplicate", "File › Export…", "Edit › Select All", "Düzen › Tümünü Seç", "Format › Pasteboard", nil] as [String?] {
            expect(UIMap.clip(title: title) == nil, "neither: \(title ?? "nil")")
        }
        // Buttons: the app's own name, then the title, description and help.
        expect(UIMap.clip(control: UINode(role: "AXButton", label: "Yapıştır")) == .paste, "a Turkish Paste button")
        expect(UIMap.clip(control: UINode(role: "AXButton", identifier: "paste:")) == .paste, "a toolbar button by its selector")
        expect(UIMap.clip(control: UINode(role: "AXButton", help: "Copy")) == .copy, "a Copy button by its help")
        expect(UIMap.clip(control: UINode(role: "AXButton", title: "Send")) == nil, "an ordinary button")
        expect(UIMap.mightPaste(UINode(role: "AXButton", help: "Quick paste from the clipboard")), "might paste: a word anywhere")
        expect(UIMap.mightPaste(UINode(role: "AXButton", label: "クリップボードから貼り付け")), "might paste: inside Japanese text")
        expect(!UIMap.mightPaste(UINode(role: "AXButton", title: "Clipboard history")), "might paste: not every clipboard button")
        expect(UIMap.mightCopy(UINode(role: "AXButton", title: "Click to copy API key")), "might copy: a word anywhere")
        expect(UIMap.clip(control: UINode(role: "AXButton", title: "Click to copy API key")) == nil, "might copy: what clip can't tell")
        expect(UIMap.mightCopy(UINode(role: "AXButton", label: "API anahtarını kopyala")), "might copy: Turkish, last word")
        expect(UIMap.mightCopy(UINode(role: "AXButton", help: "Zum Kopieren klicken")), "might copy: German, in the help")
        expect(UIMap.mightCopy(UINode(role: "AXButton", label: "Cut selection")), "might copy: cut")
        expect(UIMap.mightCopy(UINode(role: "AXButton", identifier: "copyApiKeyButton")), "might copy: the app's own name")
        expect(UIMap.mightCopy(UINode(role: "AXButton", identifier: "btn-kopyala")), "might copy: an identifier in another language")
        expect(UIMap.mightCopy(UINode(role: "AXButton", title: "APIキーをコピーする")), "might copy: inside Japanese text")
        expect(UIMap.mightCopy(UINode(role: "AXButton", title: "Clé API (cliquer pour copier)")), "might copy: French")
        expect(!UIMap.mightCopy(UINode(role: "AXButton", title: "Shortcuts")), "might copy: not inside another word")
        expect(!UIMap.mightCopy(UINode(role: "AXButton", title: "Show API key")), "might copy: an ordinary button")
        expect(!UIMap.mightPaste(UINode(role: "AXButton", title: "Click to copy")), "a copy button doesn't paste")

        // After a copy-like press: only the press's own copy is looked at, and cleared only while it's still that copy.
        expect(UIMap.copyWatch(start: 7, now: 7, input: false) == .wait, "copy watch: unchanged waits")
        expect(UIMap.copyWatch(start: 7, now: 8, input: false) == .look, "copy watch: one step looks")
        expect(UIMap.copyWatch(start: 7, now: 9, input: false) == .leave, "copy watch: two steps leave it")
        expect(UIMap.copyWatch(start: 7, now: 6, input: false) == .leave, "copy watch: backwards leaves it")
        expect(UIMap.copyWatch(start: 7, now: 7, input: true) == .leave && UIMap.copyWatch(start: 7, now: 8, input: true) == .leave,
               "copy watch: the person's input leaves it")
        expect(UIMap.copyWatch(start: Int.max, now: Int.min, input: false) == .look, "copy watch: the count wrapping")
        expect(UIMap.clearsCopy(start: 7, seen: 8, now: 8, input: false, secret: true), "clears: the press's secret")
        expect(!UIMap.clearsCopy(start: 7, seen: 8, now: 8, input: false, secret: false), "clears: not without a secret")
        expect(!UIMap.clearsCopy(start: 7, seen: 8, now: 9, input: false, secret: true), "clears: not once copied over")
        expect(!UIMap.clearsCopy(start: 7, seen: 9, now: 9, input: false, secret: true), "clears: not two steps on")
        expect(!UIMap.clearsCopy(start: 7, seen: 8, now: 8, input: true, secret: true), "clears: not after the person's input")

        // A control whose meaning changed (Mute became Unmute while the person was asked) is never pressed.
        let mute = UIMap.meaning(role: "AXButton", subrole: "", title: "Mute", label: "")
        expect(UIMap.changed(mute, UIMap.meaning(role: "AXButton", subrole: "", title: "  Mute ", label: "")) == nil, "meaning: the same, spaces aside")
        let unmute = UIMap.changed(mute, UIMap.meaning(role: "AXButton", subrole: "", title: "Unmute", label: ""))
        expect(unmute == "That control changed (it now says Unmute); look again with petal_ui.", "meaning: Mute became Unmute", unmute ?? "nil")
        let described = UIMap.meaning(role: "AXButton", subrole: "", title: "", label: "Microphone on")
        expect(UIMap.changed(described, UIMap.meaning(role: "AXButton", subrole: "", title: "", label: "Microphone off"))?.contains("Microphone off") == true,
               "meaning: its description changed")
        let on = UIMap.meaning(role: "AXCheckBox", subrole: "AXSwitch", title: "Wi-Fi", label: "", value: "1")
        let off = UIMap.changed(on, UIMap.meaning(role: "AXCheckBox", subrole: "AXSwitch", title: "Wi-Fi", label: "", value: "0"))
        expect(off == "That control changed (it's off now); look again with petal_ui.", "meaning: a switch turned off", off ?? "nil")
        let toggle = UIMap.meaning(role: "AXButton", subrole: "AXToggle", title: "Bold", label: "", value: "0")
        expect(UIMap.changed(toggle, UIMap.meaning(role: "AXButton", subrole: "AXToggle", title: "Bold", label: "", value: "1")) != nil, "meaning: a toggle's state")
        expect(UIMap.meaning(role: "AXButton", subrole: "", title: "Send", label: "", value: "3").state.isEmpty
               && UIMap.meaning(role: "AXTextField", subrole: "", title: "", label: "To", value: "a@b.c").state.isEmpty,
               "meaning: only a toggle's value counts")
        let kind = UIMap.changed(mute, UIMap.meaning(role: "AXCheckBox", subrole: "", title: "Mute", label: ""))
        expect(kind?.contains("checkbox") == true, "meaning: its kind changed", kind ?? "nil")
        expect(UIMap.changed(mute, UIMap.meaning(role: "AXButton", subrole: "", title: "", label: ""))?.contains("no name") == true, "meaning: its name went")
        let leaked = UIMap.changed(mute, UIMap.meaning(role: "AXButton", subrole: "", title: "Copy sk-live-4f9a2b7c1d", label: ""),
                                   secret: { $0.contains("sk-live") })
        expect(leaked?.contains("sk-live") == false && leaked?.contains(UIMap.hidden) == true, "meaning: a secret is never repeated", leaked ?? "nil")

        // The clipboard, a window's title or a selection: the secrets go, the rest stays.
        expect(vault.redacted("sk-live-4f9a2b7c1d") == UIMap.hidden, "a whole secret, hidden")
        expect(vault.redacted("KEY=sk-live-4f9a2b7c1d\nNAME=petal") == "KEY=\(UIMap.hidden)\nNAME=petal", "a secret among lines",
               vault.redacted("KEY=sk-live-4f9a2b7c1d\nNAME=petal"))
        expect(vault.redacted("part 4f9a2b7c1d end") == "part \(UIMap.hidden) end", "part of a long secret")
        expect(vault.redacted("Room 1234, floor 2") == "Room \(UIMap.hidden), floor 2", "a short secret as a word")
        expect(vault.redacted("12345 and 2024") == "12345 and 2024", "not run into other digits")
        expect(pins.redacted("Door PIN: 739251") == "Door PIN: \(UIMap.hidden)", "a PIN inside text")
        expect(vault.redacted("Inbox") == "Inbox" && UIMap.SecretIndex([]).redacted("1234") == "1234", "nothing else changes")
        expect(!vault.matches(vault.redacted("a sk-live-4f9a2b7c1d b 1234 c")), "what's left never matches")

        // All of a long text is searched, not its first part: a big log with a key near its end.
        let line = "2026-11-07 12:00:01 INFO request handled in 12ms path=/api/v1/things user=abc\n"
        let log = String(repeating: line, count: 900_000 / line.count)
        expect(vault.check(log) == .clean && !vault.matches(log), "a long log without secrets")
        expect(vault.check(log + "KEY=sk-live-4f9a2b7c1d") == .secret, "a secret past 20,000 characters, at the end")
        expect(vault.check(log + "part 4f9a2b7c") == .secret, "8 characters of a secret, at the end")
        expect(vault.check(log + "PIN 1234") == .secret && vault.check(log + "PIN 12345") == .clean, "a short secret as a word, at the end")
        expect(vault.check(String(log.prefix(20_000 - 5)) + "sk-live-4f9a2b7c1d" + log) == .secret, "a secret across character 20,000")
        expect(vault.redacted(log + "KEY=sk-live-4f9a2b7c1d") == log + "KEY=\(UIMap.hidden)", "redacted at the end of a long log")
        let started = Date()
        _ = vault.check(log + "x")
        _ = vault.redacted(log + "x")
        let took = Date().timeIntervalSince(started)
        expect(took < 0.5, "a 900 KB log is searched and redacted quickly", "\(took) s")
        // Past about 1 MB nothing is searched: it counts as a secret, is too long to move, and is hidden whole.
        let huge = String(repeating: line, count: (UIMap.SecretIndex.limit / line.utf8.count) + 1)
        expect(vault.check(huge) == .tooLong && vault.matches(huge) && vault.redacted(huge) == UIMap.hidden, "too long to check")
        expect(UIMap.SecretIndex([]).check(huge) == .clean, "an empty vault has nothing to find")
        // Characters, not bytes: a secret among emoji and accents, and one with them in it.
        let wide = UIMap.SecretIndex(["clé-👩‍💻-ñandú"])
        expect(wide.check("🎉🎉 note: clé-👩‍💻-ñandú 🎉") == .secret, "a secret with emoji and accents, inside text")
        expect(wide.check("-👩‍💻-ñandú") == .secret && wide.check("clé-👩‍💻-ñan") == .secret, "8 characters of it, either end")
        expect(wide.check("clé-👩-ñandú") == .clean, "not with another character in it")
        expect(wide.redacted("x clé-👩‍💻-ñandú y") == "x \(UIMap.hidden) y", "redacted by characters")

        print("UIMap: \(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
