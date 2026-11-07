import CoreGraphics
import Foundation

/// One control in a window, as Accessibility describes it (ComputerUse.swift reads them; this file only decides).
struct UINode: Equatable {
    var role: String
    var subrole = ""
    var title = ""
    var label = ""           // AXDescription
    var help = ""
    var placeholder = ""
    var identifier = ""      // AXIdentifier: the app's own name for it, never shown
    var value = ""           // never read for a password field
    var frame = CGRect.zero  // top-left origin, as Accessibility counts
    var enabled = true
    var focused = false
    var pressable = false    // a group, image or text that says it can be pressed
    var web = false          // inside a web page
    var order = 0            // reading order (depth first)
    var clip: CGRect?        // what's showing of the scroll areas it's in; nil when it's in none
}

/// The pure side of Petal AI using apps: which of a window's controls the AI is told about (actionable ones, the
/// visible first, about 150 at most), what each is called, and the keys and menu paths it hands Petal. Nothing
/// here touches Accessibility, so `macos/checks/run.sh` checks it.
enum UIMap {
    static let cap = 150
    /// How long a window's map is kept for `petal_act` (until the next `petal_ui`, or this).
    static let lifetime: TimeInterval = 300

    /// Roles that do something when used.
    static let actionableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXTextField",
        "AXTextArea", "AXSearchField", "AXLink", "AXSlider", "AXIncrementor", "AXDisclosureTriangle", "AXRow",
        "AXMenuItem", "AXMenuBarItem", "AXColorWell", "AXDateField", "AXTimeField", "AXStepper", "AXTab",
        "AXSegmentedControl", "AXToolbarButton", "AXDockItem",
    ]
    /// Roles that count only when they say they can be pressed (a web page's clickable box, an image button).
    static let pressableRoles: Set<String> = ["AXGroup", "AXImage", "AXStaticText", "AXCell", "AXUnknown", "AXGenericElement"]
    /// Roles whose value is worth telling (what's typed, on or off, the choice shown).
    static let valueRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXCheckBox",
                                          "AXRadioButton", "AXSlider", "AXPopUpButton", "AXIncrementor", "AXDateField", "AXStepper"]

    static func isSecure(_ node: UINode) -> Bool { node.subrole == "AXSecureTextField" }

    static func isActionable(_ node: UINode) -> Bool {
        actionableRoles.contains(node.role) || (pressableRoles.contains(node.role) && node.pressable)
    }

    static func isText(_ node: UINode) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(node.role)
    }

    /// On the screen: it has a size, and it overlaps the window and what's showing of its scroll areas.
    static func isVisible(_ node: UINode, window: CGRect) -> Bool {
        guard node.frame.width >= 1, node.frame.height >= 1 else { return false }
        if !window.isEmpty, !node.frame.intersects(window) { return false }
        if let clip = node.clip, !node.frame.intersects(clip) { return false }
        return true
    }

    /// What a person would call it: its title, else its label, placeholder or help.
    static func name(_ node: UINode) -> String {
        for text in [node.title, node.label, node.placeholder, node.help] {
            let clean = tidy(text)
            if !clean.isEmpty { return truncate(clean, 80) }
        }
        return ""
    }

    /// Its kind in plain words.
    static func kind(_ node: UINode) -> String {
        if isSecure(node) { return "password field" }
        switch node.subrole {
        case "AXSearchField": return "search field"
        case "AXTabButton": return "tab"
        case "AXCloseButton": return "close button"
        case "AXMinimizeButton": return "minimize button"
        case "AXZoomButton", "AXFullScreenButton": return "full screen button"
        case "AXToggle", "AXSwitch": return "switch"
        default: break
        }
        switch node.role {
        case "AXButton", "AXToolbarButton": return "button"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "radio button"
        case "AXPopUpButton": return "pop-up menu"
        case "AXMenuButton": return "menu button"
        case "AXComboBox": return "combo box"
        case "AXTextField", "AXDateField", "AXTimeField": return "text field"
        case "AXSearchField": return "search field"
        case "AXTextArea": return "text area"
        case "AXLink": return "link"
        case "AXSlider": return "slider"
        case "AXIncrementor", "AXStepper": return "stepper"
        case "AXDisclosureTriangle": return "disclosure"
        case "AXRow": return "row"
        case "AXCell": return "cell"
        case "AXMenuItem": return "menu item"
        case "AXMenuBarItem": return "menu"
        case "AXColorWell": return "color well"
        case "AXTab": return "tab"
        case "AXSegmentedControl": return "segmented control"
        case "AXImage": return "image"
        case "AXStaticText": return "text"
        default: return "control"
        }
    }

    /// What it holds, in a few words: never a password field's; a checkbox's as on or off.
    static func value(_ node: UINode) -> String? {
        guard !isSecure(node), valueRoles.contains(node.role) else { return nil }
        let text = tidy(node.value)
        guard !text.isEmpty else { return nil }
        if ["AXCheckBox", "AXRadioButton"].contains(node.role) || node.subrole == "AXSwitch" || node.subrole == "AXToggle" {
            return text == "1" ? "on" : text == "0" ? "off" : text
        }
        return truncate(text, 120)
    }

    /// The controls the AI is told about, at most `cap`: actionable ones only, visible before hidden, enabled before
    /// greyed out, each in reading order; a control repeating the one around it (same place, same name) once.
    /// `find` keeps only those whose name, label or value has that text. `left` is how many more there were.
    static func select(_ nodes: [UINode], window: CGRect, find: String = "", cap: Int = cap) -> (shown: [UINode], left: Int) {
        let wanted = tidy(find).lowercased()
        var seen = Set<String>()
        var picked: [(node: UINode, visible: Bool)] = []
        for node in nodes.sorted(by: { $0.order < $1.order }) where isActionable(node) {
            if !wanted.isEmpty {
                let words = [node.title, node.label, node.placeholder, node.help, isSecure(node) ? "" : node.value].joined(separator: " ").lowercased()
                guard words.contains(wanted) else { continue }
            }
            let key = "\(Int(node.frame.minX)),\(Int(node.frame.minY)),\(Int(node.frame.width)),\(Int(node.frame.height))|\(name(node))"
            if node.frame != .zero, !name(node).isEmpty, !seen.insert(key).inserted { continue }
            picked.append((node, isVisible(node, window: window)))
        }
        func rank(_ item: (node: UINode, visible: Bool)) -> Int { (item.visible ? 0 : 2) + (item.node.enabled ? 0 : 1) }
        let kept = picked.enumerated().sorted { a, b in
            rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset
        }.prefix(max(0, cap)).map(\.element)
        // Shown visible ones first, then the rest, each in reading order.
        let shown = kept.sorted { a, b in a.visible != b.visible ? a.visible : a.node.order < b.node.order }.map(\.node)
        return (shown, picked.count - shown.count)
    }

    /// One line of text, whitespace folded.
    static func tidy(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    static func truncate(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(max(0, limit - 1))) + "…"
    }

    /// The window or a control moved or changed size by more than a few points.
    static func moved(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) > tolerance || abs(a.minY - b.minY) > tolerance
            || abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance
    }

    // MARK: Privacy

    static let hidden = "(hidden)"
    /// Words in a field's name or identifier that say it holds a secret, even when it isn't a password field.
    static let secretWords = ["password", "passwd", "passcode", "passphrase", "token", "secret", "api key", "apikey", "api_key",
                              "api-key", "access key", "private key"]

    /// A field whose name or identifier says it holds a password, token, secret or API key.
    static func looksSecret(_ node: UINode) -> Bool {
        let words = [node.title, node.label, node.placeholder, node.help, node.identifier].joined(separator: " ").lowercased()
        return secretWords.contains { words.contains($0) }
    }

    /// The vault's secrets as hashes (Swift's, seeded afresh in each process): a whole secret, every run of `piece`
    /// characters of a longer one, and a short one (`short` to `piece` - 1 characters, a PIN) as a word of its own
    /// inside text, so text holding a secret, or part of a long one, is caught without keeping the secrets.
    struct SecretIndex {
        static let piece = 8
        static let short = 4
        private var wholes = Set<Int>()
        private var pieces = Set<Int>()
        /// Short secrets by their length.
        private var shorts: [Int: Set<Int>] = [:]

        init(_ secrets: [String]) {
            for secret in secrets where !secret.isEmpty {
                wholes.insert(secret.hashValue)
                let characters = Array(secret)
                if characters.count >= Self.short, characters.count < Self.piece {
                    shorts[characters.count, default: []].insert(secret.hashValue)
                }
                guard characters.count >= Self.piece else { continue }
                for start in 0...(characters.count - Self.piece) { pieces.insert(String(characters[start..<start + Self.piece]).hashValue) }
            }
        }

        var isEmpty: Bool { wholes.isEmpty }

        /// `text` is a secret, holds `piece` characters or more of one, or holds a short one whole, not run into the
        /// letters or digits around it ("Door PIN: 739251", but not 1234 in 12345).
        func matches(_ text: String) -> Bool {
            guard !wholes.isEmpty, !text.isEmpty else { return false }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if wholes.contains(text.hashValue) || wholes.contains(trimmed.hashValue) { return true }
            let characters = Array(text)
            for (length, hashes) in shorts where characters.count >= length {
                for start in 0...(characters.count - length) where Self.edge(characters, start) && Self.edge(characters, start + length)
                    && hashes.contains(String(characters[start..<start + length]).hashValue) {
                    return true
                }
            }
            guard !pieces.isEmpty, characters.count >= Self.piece else { return false }
            for start in 0...(characters.count - Self.piece) where pieces.contains(String(characters[start..<start + Self.piece]).hashValue) {
                return true
            }
            return false
        }

        /// Between `at - 1` and `at` is the end of a word: not a letter or digit running on into another.
        static func edge(_ characters: [Character], _ at: Int) -> Bool {
            guard at > 0, at < characters.count else { return true }
            return !(characters[at - 1].isLetter || characters[at - 1].isNumber) || !(characters[at].isLetter || characters[at].isNumber)
        }
    }

    /// What the AI may be told of a control: a password field's value never, a field that looks like it holds a
    /// secret as "(hidden)", and any text holding a vault secret as "(hidden)".
    static func redact(_ node: UINode, secret: (String) -> Bool) -> UINode {
        var out = node
        if isSecure(node) { out.value = "" }
        else if looksSecret(node), !node.value.isEmpty { out.value = hidden }
        for path in [\UINode.title, \.label, \.help, \.placeholder, \.value] where out[keyPath: path] != hidden && secret(out[keyPath: path]) {
            out[keyPath: path] = hidden
        }
        return out
    }

    // MARK: Has the window changed?

    /// What a window shows that an act depends on: its title, what has the keyboard (and what's in it), and which
    /// rows are selected. If any of these changed since `petal_ui`, the same button may act on something else (another
    /// email selected while the person was asked), so the act is refused.
    struct Fingerprint: Equatable {
        var title = ""
        /// What has the keyboard: its kind, the app's name for it, where it is, and what's in it.
        var focus = ""
        var selection = ""
        /// The control with the keyboard itself (an AXUIElement): two empty fields alike are still two fields.
        var focused: AnyObject?

        static func == (a: Fingerprint, b: Fingerprint) -> Bool {
            a.title == b.title && a.focus == b.focus && a.selection == b.selection && UIMap.same(a.focused, b.focused)
        }
    }

    static func fingerprint(title: String, focusRole: String, focusSubrole: String, focusValue: String, focusIdentifier: String = "",
                            focusFrame: CGRect = .zero, focused: AnyObject? = nil, selected: [String]) -> Fingerprint {
        let secure = focusSubrole == "AXSecureTextField"
        let place = [focusFrame.minX, focusFrame.minY, focusFrame.width, focusFrame.height].map { String(Int($0.rounded())) }.joined(separator: ",")
        let focus = focusRole.isEmpty ? "" : "\(focusRole)/\(focusSubrole)#\(focusIdentifier)@\(place)=" + (secure ? "" : truncate(tidy(focusValue), 200))
        return Fingerprint(title: tidy(title), focus: focus, selection: selected.map { truncate(tidy($0), 120) }.joined(separator: "\n"),
                           focused: focusRole.isEmpty ? nil : focused)
    }

    /// The same element (CFEqual: for Accessibility, the same control of the same app), or neither.
    static func same(_ a: AnyObject?, _ b: AnyObject?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return CFEqual(x as CFTypeRef, y as CFTypeRef)
        default: return false
        }
    }

    /// Why an act can't go ahead on a window whose fingerprint is now `now`, or nil.
    static func changed(_ then: Fingerprint, _ now: Fingerprint) -> String? {
        if then.title != now.title { return "The window changed (its title is different now); look again with petal_ui." }
        if then.selection != now.selection { return "The window changed (something else is selected now); look again with petal_ui." }
        if then.focus != now.focus || !same(then.focused, now.focused) {
            return "The window changed (another control has the keyboard now); look again with petal_ui."
        }
        return nil
    }

    // MARK: Menus

    /// "File > Export…" (or ›, or →) as ["File", "Export…"].
    static func menuPath(_ text: String) -> [String] {
        var parts = [text]
        for separator in [">", "›", "→"] { parts = parts.flatMap { $0.components(separatedBy: separator) } }
        return parts.map(tidy).filter { !$0.isEmpty }
    }

    /// A menu item's title matches what was asked: case aside, "..." the same as "…", and a trailing "…" optional.
    static func sameTitle(_ a: String, _ b: String) -> Bool {
        func plain(_ s: String) -> String {
            var t = tidy(s).lowercased().replacingOccurrences(of: "...", with: "…")
            while t.hasSuffix("…") { t.removeLast() }
            return t.trimmingCharacters(in: .whitespaces)
        }
        let x = plain(a), y = plain(b)
        return !x.isEmpty && x == y
    }

    // MARK: Keys

    struct Key: Equatable {
        var code: UInt16
        var flags: CGEventFlags
        var character: String?     // what it types, for a key that types something
        var label: String          // "⌘S"

        static func == (a: Key, b: Key) -> Bool { a.code == b.code && a.flags.rawValue == b.flags.rawValue && a.character == b.character }

        var command: Bool { flags.contains(.maskCommand) }
        /// Accessibility's menu-item modifiers for this key: shift 1, option 2, control 4, and 8 for no ⌘.
        var menuModifiers: Int {
            (flags.contains(.maskShift) ? 1 : 0) | (flags.contains(.maskAlternate) ? 2 : 0)
                | (flags.contains(.maskControl) ? 4 : 0) | (command ? 0 : 8)
        }
    }

    /// Virtual key codes (ANSI layout); what a letter types is sent along, so other layouts get the right one.
    static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]
    static let named: [String: (code: UInt16, label: String)] = [
        "return": (36, "↩"), "enter": (36, "↩"), "tab": (48, "⇥"), "space": (49, " Space"), "delete": (51, "⌫"),
        "backspace": (51, "⌫"), "escape": (53, "⎋"), "esc": (53, "⎋"), "forwarddelete": (117, "⌦"), "home": (115, "↖"),
        "end": (119, "↘"), "pageup": (116, "⇞"), "pagedown": (121, "⇟"), "left": (123, "←"), "right": (124, "→"),
        "down": (125, "↓"), "up": (126, "↑"), "f1": (122, "F1"), "f2": (120, "F2"), "f3": (99, "F3"), "f4": (118, "F4"),
        "f5": (96, "F5"), "f6": (97, "F6"), "f7": (98, "F7"), "f8": (100, "F8"), "f9": (101, "F9"), "f10": (109, "F10"),
        "f11": (103, "F11"), "f12": (111, "F12"),
    ]
    static let modifiers: [String: (flag: CGEventFlags, label: String)] = [
        "cmd": (.maskCommand, "⌘"), "command": (.maskCommand, "⌘"), "⌘": (.maskCommand, "⌘"),
        "shift": (.maskShift, "⇧"), "⇧": (.maskShift, "⇧"),
        "opt": (.maskAlternate, "⌥"), "option": (.maskAlternate, "⌥"), "alt": (.maskAlternate, "⌥"), "⌥": (.maskAlternate, "⌥"),
        "ctrl": (.maskControl, "⌃"), "control": (.maskControl, "⌃"), "⌃": (.maskControl, "⌃"),
        "fn": (.maskSecondaryFn, "fn"),
    ]

    /// "cmd-shift-s", "cmd+s", "⌘S", "return", "escape": nil when it isn't one key with modifiers.
    static func parseKey(_ text: String) -> Key? {
        var rest = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !rest.isEmpty else { return nil }
        var flags: CGEventFlags = []
        var label = ""
        // Symbols run together: ⌘⇧S.
        while let first = rest.first, ["⌘", "⇧", "⌥", "⌃"].contains(first), rest.count > 1 {
            let mod = modifiers[String(first)]!
            if !flags.contains(mod.flag) { flags.insert(mod.flag) }
            rest.removeFirst()
        }
        var parts: [String]
        if rest.count == 1 { parts = [rest] }
        else {
            let separator: Character = rest.contains("+") ? "+" : "-"
            parts = rest.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
            // "cmd--" and "cmd++": the key is the separator itself.
            if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" { parts.removeLast(2); parts.append(String(separator)) }
            if parts.last == "" { return nil }
        }
        guard let key = parts.last else { return nil }
        for part in parts.dropLast() {
            guard let mod = modifiers[part.trimmingCharacters(in: .whitespaces)] else { return nil }
            flags.insert(mod.flag)
        }
        for (name, mod) in [("⌃", CGEventFlags.maskControl), ("⌥", .maskAlternate), ("⇧", .maskShift), ("⌘", .maskCommand)] where flags.contains(mod) {
            label += name
        }
        if flags.contains(.maskSecondaryFn) { label = "fn " + label }
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        if let named = named[trimmed.replacingOccurrences(of: " ", with: "")] {
            return Key(code: named.code, flags: flags, character: nil, label: label + named.label)
        }
        if let code = codes[trimmed] {
            return Key(code: code, flags: flags, character: trimmed, label: label + trimmed.uppercased())
        }
        return nil
    }

    // MARK: Words

    /// What the fake cursor's chip says while it does it: "Pressing Export", "Typing in Search".
    static func caption(_ action: String, name: String, kind: String, key: String = "") -> String {
        let thing = name.isEmpty ? "the \(kind)" : name
        switch action {
        case "press": return "Pressing \(thing)"
        case "type": return "Typing in \(thing)"
        case "focus": return "Going to \(thing)"
        case "scroll": return "Scrolling \(thing)"
        case "menu": return "Choosing \(thing)"
        case "key": return "Pressing \(key)"
        default: return action.capitalized
        }
    }
}
