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
    /// A payment form's card number and security code fields, by their names and autofill identifiers.
    static let paymentWords = ["card number", "cardnumber", "card-number", "card_number", "cc-number", "ccnumber", "cc-csc",
                               "security code", "securitycode", "security-code", "card verification", "cvv", "cvc", "csc"]

    /// A field whose name or identifier says it holds a password, token, secret, API key, card number or security code.
    static func looksSecret(_ node: UINode) -> Bool {
        let words = [node.title, node.label, node.placeholder, node.help, node.identifier].joined(separator: " ").lowercased()
        return secretWords.contains { words.contains($0) } || paymentWords.contains { words.contains($0) }
    }

    /// The vault's secrets as hashes (Swift's, seeded afresh in each process): a whole secret, every run of `piece`
    /// characters of a longer one, and a short one (`short` to `piece` - 1 characters, a PIN) as a word of its own
    /// inside text, so text holding a secret, or part of a long one, is caught without keeping the secrets. A card's
    /// 3-digit security code is caught wherever it isn't part of a longer number ("CVV: 737", "cvc737", not 737 in
    /// 17370). A card number is also caught across whatever separates its digits ("4242\u{00A0}4242", "4242.4242",
    /// full-width digits), and digits are digits in any script.
    struct SecretIndex {
        static let piece = 8
        static let short = 4
        /// A security code: the shortest secret looked for inside text, digits only.
        static let code = 3
        /// Text longer than this (in UTF-8 bytes, about 1 MB) isn't searched: it counts as holding a secret, and
        /// Petal doesn't move or show it.
        static let limit = 1_000_000
        /// What a check of some text found. `unreadable`: the vault couldn't be read, so nothing can be checked.
        enum Check: Equatable { case clean, secret, tooLong, unreadable }
        /// A card number's length in digits.
        static let cardDigits = 12...19
        /// At most this many characters between two digits of a card number ("4242 - 4242").
        static let cardGap = 3

        private var wholes = Set<Int>()
        /// Every `piece` characters of a longer secret, as `window` hashes them.
        private var pieces = Set<UInt64>()
        /// Short secrets by their length, as `window` hashes them.
        private var shorts: [Int: Set<UInt64>] = [:]
        /// 3-digit secrets (security codes), as `window` hashes them.
        private var numbers: [Int: Set<UInt64>] = [:]
        /// Every `piece` digits of a card number (a secret that is 12 to 19 digits and separators), as `window`
        /// hashes ASCII digits: found in text whatever separates the digits.
        private var cards = Set<UInt64>()
        /// The vault couldn't be read (Keychain locked or refusing): every text counts as possibly secret.
        private(set) var unreadable = false

        /// The index when the vault can't be read: nothing is shown or moved as if it were checked.
        static var unavailable: SecretIndex {
            var index = SecretIndex([])
            index.unreadable = true
            return index
        }

        init(_ secrets: [String]) {
            for secret in secrets where !secret.isEmpty {
                wholes.insert(secret.hashValue)
                let characters = Array(secret)
                let digitsOnly = characters.compactMap(Self.digit)
                if Self.cardDigits.contains(digitsOnly.count),
                   characters.allSatisfy({ Self.digit($0) != nil || !($0.isLetter || $0.isNumber) }) {
                    Self.roll(digitsOnly.map { Self.digitCodes[$0] }, Self.piece) { _, hash in cards.insert(hash); return true }
                }
                let codes = Self.codes(characters)
                let digits = characters.allSatisfy { $0.isASCII && $0.isNumber }
                if digits, codes.count == Self.code {
                    numbers[codes.count, default: []].insert(Self.window(codes[...]))
                } else if codes.count >= Self.short, codes.count < Self.piece {
                    shorts[codes.count, default: []].insert(Self.window(codes[...]))
                }
                guard codes.count >= Self.piece else { continue }
                Self.roll(codes, Self.piece) { _, hash in pieces.insert(hash); return true }
            }
        }

        var isEmpty: Bool { wholes.isEmpty && !unreadable }

        /// The ASCII digits' hashes, 0 to 9.
        private static let digitCodes: [UInt64] = (0...9).map { UInt64(bitPattern: Int64(Character(String($0)).hashValue)) }

        /// The digit a character shows (0 to 9) in any script ("４", "٤"), a mark on it aside; nil for anything else.
        static func digit(_ character: Character) -> Int? {
            if let ascii = character.asciiValue { return (48...57).contains(ascii) ? Int(ascii - 48) : nil }
            guard let first = character.unicodeScalars.first, first.properties.numericType == .decimal,
                  let value = first.properties.numericValue, value >= 0, value <= 9 else { return nil }
            return Int(value)
        }

        /// Each character's own hash (Swift's, seeded afresh in each process), once, so every window after the first
        /// costs a multiply and an add: a 1 MB log is searched in a few milliseconds. A digit in another script hashes
        /// as its ASCII digit.
        private static func codes(_ characters: [Character]) -> [UInt64] {
            characters.map { character in
                if !character.isASCII, let digit = digit(character) { return digitCodes[digit] }
                return UInt64(bitPattern: Int64(character.hashValue))
            }
        }

        private static let base: UInt64 = 1_099_511_628_211

        /// A run of characters' hash: the same as `roll` gives for the same run anywhere in a text.
        private static func window(_ codes: ArraySlice<UInt64>) -> UInt64 {
            codes.reduce(0) { $0 &* base &+ $1 }
        }

        /// Hands every run of `length` codes' hash to `each` (with where it starts), until `each` says stop.
        private static func roll(_ codes: [UInt64], _ length: Int, _ each: (Int, UInt64) -> Bool) {
            guard length > 0, codes.count >= length else { return }
            var top: UInt64 = 1
            for _ in 1..<length { top = top &* base }
            var hash = window(codes[0..<length])
            var start = 0
            while each(start, hash) {
                let next = start + length
                guard next < codes.count else { return }
                hash = (hash &- codes[start] &* top) &* base &+ codes[next]
                start += 1
            }
        }

        /// Every part of `characters` that holds a secret (a short one only as a word of its own), by where it starts
        /// and how long it is, to `found`, until it says stop.
        private func scan(_ characters: [Character], _ found: (Int, Int) -> Bool) {
            let codes = Self.codes(characters)
            var going = true
            for (length, hashes) in shorts where going {
                Self.roll(codes, length) { start, hash in
                    if hashes.contains(hash), Self.edge(characters, start), Self.edge(characters, start + length) { going = found(start, length) }
                    return going
                }
            }
            for (length, hashes) in numbers where going {
                Self.roll(codes, length) { start, hash in
                    if hashes.contains(hash), Self.numberEdge(characters, start), Self.numberEdge(characters, start + length) { going = found(start, length) }
                    return going
                }
            }
            if going, !pieces.isEmpty {
                Self.roll(codes, Self.piece) { start, hash in
                    if pieces.contains(hash) { going = found(start, Self.piece) }
                    return going
                }
            }
            guard going, !cards.isEmpty else { return }
            // A card number's digits with whatever is between them (spaces of any kind, dots, slashes, dashes): runs of
            // digits are joined across at most `cardGap` other characters, never across a letter.
            var digits: [UInt64] = []
            var at: [Int] = []
            var gap = 0
            func flush() {
                Self.roll(digits, Self.piece) { start, hash in
                    if cards.contains(hash) { going = found(at[start], at[start + Self.piece - 1] - at[start] + 1) }
                    return going
                }
                digits.removeAll(keepingCapacity: true)
                at.removeAll(keepingCapacity: true)
            }
            for (index, character) in characters.enumerated() {
                if let digit = Self.digit(character) {
                    digits.append(Self.digitCodes[digit])
                    at.append(index)
                    gap = 0
                } else if !digits.isEmpty {
                    gap += 1
                    if character.isLetter || gap > Self.cardGap {
                        flush()
                        gap = 0
                        guard going else { return }
                    }
                }
            }
            flush()
        }

        /// `text` is a secret, holds `piece` characters or more of one, or holds a short one whole, not run into the
        /// letters or digits around it ("Door PIN: 739251", but not 1234 in 12345); or it's too long to check. All of
        /// it is searched, however long, up to `limit`.
        func check(_ text: String) -> Check {
            guard !text.isEmpty else { return .clean }
            if unreadable { return .unreadable }
            guard !wholes.isEmpty else { return .clean }
            guard text.utf8.count <= Self.limit else { return .tooLong }
            if wholes.contains(text.hashValue) || wholes.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).hashValue) { return .secret }
            var hit = false
            scan(Array(text)) { _, _ in hit = true; return false }
            return hit ? .secret : .clean
        }

        /// `check` found a secret, the text was too long to look through, or the vault couldn't be read: either way it
        /// isn't shown or moved.
        func matches(_ text: String) -> Bool { check(text) != .clean }

        /// Between `at - 1` and `at` is the end of a word: not a letter or digit running on into another.
        static func edge(_ characters: [Character], _ at: Int) -> Bool {
            guard at > 0, at < characters.count else { return true }
            return !(characters[at - 1].isLetter || characters[at - 1].isNumber) || !(characters[at].isLetter || characters[at].isNumber)
        }

        /// Between `at - 1` and `at` is the end of a number: not two digits side by side.
        static func numberEdge(_ characters: [Character], _ at: Int) -> Bool {
            guard at > 0, at < characters.count else { return true }
            return !characters[at - 1].isNumber || !characters[at].isNumber
        }

        /// `text` with every part that `matches` would catch replaced by "(hidden)": a whole secret, every run of
        /// `piece` characters of a longer one (runs that touch join, so a long secret goes as one), and a short one
        /// as a word of its own. The rest of the text stays, so a clipboard holding a key among other lines still
        /// says what else is there. Text too long to check, or any text while the vault can't be read, is "(hidden)"
        /// whole.
        func redacted(_ text: String) -> String {
            guard !text.isEmpty else { return text }
            if unreadable { return UIMap.hidden }
            guard !wholes.isEmpty else { return text }
            guard text.utf8.count <= Self.limit else { return UIMap.hidden }
            if wholes.contains(text.hashValue) || wholes.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).hashValue) { return UIMap.hidden }
            let characters = Array(text)
            var marked = [Bool](repeating: false, count: characters.count)
            var any = false
            scan(characters) { start, length in
                for at in start..<start + length { marked[at] = true }
                any = true
                return true
            }
            guard any else { return text }
            var out = ""
            var at = 0
            while at < characters.count {
                if marked[at] {
                    out += UIMap.hidden
                    while at < characters.count, marked[at] { at += 1 }
                } else {
                    out.append(characters[at])
                    at += 1
                }
            }
            return out
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
        /// Petal could read how many rows are selected, and every one of them (up to `rowCap`), in time.
        var selectionKnown = true
        /// The control with the keyboard itself (an AXUIElement): two empty fields alike are still two fields.
        var focused: AnyObject?

        static func == (a: Fingerprint, b: Fingerprint) -> Bool {
            a.title == b.title && a.focus == b.focus && a.selection == b.selection && a.selectionKnown == b.selectionKnown
                && UIMap.same(a.focused, b.focused)
        }
    }

    /// One list's selected rows as read: how many in all (nil when that couldn't be read), and each row read in a few
    /// words (its index and texts), at most `rowCap`; `complete` false when the reading ran out of time first.
    struct Selected {
        var count: Int?
        var rows: [String] = []
        var complete = true
    }

    /// How many selected rows of a list are read for the fingerprint.
    static let rowCap = 500

    /// Which rows are selected, as the fingerprint keeps it: for each list, how many in all and a hash of every row
    /// read (so a sixth file selected while the person is asked is a change, wherever it is). Not known when a count
    /// couldn't be read, more rows are selected than `rowCap`, or the rows weren't all read in time; then only the
    /// count and the first few rows count, so a slow app's big selection isn't a change at every look.
    static func selection(_ lists: [Selected]) -> (text: String, known: Bool) {
        var known = true
        let parts = lists.map { list -> String in
            guard let count = list.count else { known = false; return "?" }
            let whole = list.complete && count <= rowCap && list.rows.count >= count
            if !whole { known = false }
            var hasher = Hasher()
            for row in whole ? list.rows : Array(list.rows.prefix(5)) { hasher.combine(truncate(tidy(row), 120)) }
            return "\(count):\(whole ? "" : "part"):\(hasher.finalize())"
        }
        return (parts.joined(separator: "\n"), known)
    }

    /// `selected`: the selected rows, in a few words each, all of one list read whole; `selection` (Reader's)
    /// instead, when given.
    static func fingerprint(title: String, focusRole: String, focusSubrole: String, focusValue: String, focusIdentifier: String = "",
                            focusFrame: CGRect = .zero, focusRange: String = "", focused: AnyObject? = nil, selected: [String] = [],
                            selection: (text: String, known: Bool)? = nil) -> Fingerprint {
        let secure = focusSubrole == "AXSecureTextField"
        let place = [focusFrame.minX, focusFrame.minY, focusFrame.width, focusFrame.height].map { String(Int($0.rounded())) }.joined(separator: ",")
        // The whole value by its hash (an edit anywhere in a long draft counts), and the caret or selection.
        var whole = Hasher()
        whole.combine(focusValue)
        let value = secure ? "" : "\(focusValue.count):\(whole.finalize())"
        let focus = focusRole.isEmpty ? "" : "\(focusRole)/\(focusSubrole)#\(focusIdentifier)@\(place)[\(focusRange)]=" + value
        let rows = selection ?? Self.selection(selected.isEmpty ? [] : [Selected(count: selected.count, rows: selected)])
        return Fingerprint(title: tidy(title), focus: focus, selection: rows.text, selectionKnown: rows.known,
                           focused: focusRole.isEmpty ? nil : focused)
    }

    /// Text as keystroke batches of up to 16 UTF-16 units, split only between whole characters: an emoji (a
    /// surrogate pair, or a family joined by ZWJ) is never cut in two. A single character longer than 16 goes alone.
    static func batches(_ text: String, size: Int = 16) -> [[UInt16]] {
        var batches: [[UInt16]] = []
        var current: [UInt16] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > size {
                batches.append(current)
                current = []
            }
            current += units
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// How soon after `petal_ui` a destructive menu item or key may go when Petal couldn't tell which rows are selected.
    static let freshLook: TimeInterval = 20

    /// Why a destructive act (Delete, Trash, Close, Quit) can't go ahead now, or nil: when Petal couldn't tell which
    /// rows are selected (then, or now), it goes only straight after a `petal_ui` (`age`: seconds since it).
    static func unsure(_ then: Fingerprint, _ now: Fingerprint, destructive: Bool, age: TimeInterval) -> String? {
        guard destructive, !then.selectionKnown || !now.selectionKnown, age > freshLook else { return nil }
        return "Petal couldn't tell what's selected in this window, so it only deletes, trashes, closes or quits right after a look. Call petal_ui again, then act straight away."
    }

    /// Words of a menu item that removes or closes something.
    static let destructiveWords: Set<String> = ["delete", "trash", "bin", "close", "quit", "erase", "remove", "discard", "empty"]

    /// The last part of a menu path ("File › Move to Trash") deletes, trashes, closes or quits.
    static func destructive(menu title: String?) -> Bool {
        guard let last = title.flatMap({ menuPath($0).last }) else { return false }
        return words(last).contains { destructiveWords.contains($0) }
    }

    /// Delete or Forward Delete (any modifiers: ⌘⌫ moves to the Trash), ⌘W, ⌘Q.
    static func destructive(key: Key) -> Bool {
        if key.code == 51 || key.code == 117 { return true }
        return key.command && ["w", "q"].contains(key.character ?? "")
    }

    // MARK: The clipboard

    /// What a menu item, key or button does with the clipboard: copy (or cut) puts something on it, paste takes it off.
    enum Clip { case copy, paste }

    /// ⌘V with any other modifiers (⌥⇧⌘V pastes and matches style) pastes; ⌘C and ⌘X copy.
    static func clip(key: Key) -> Clip? {
        guard key.command else { return nil }
        return clip(character: key.character)
    }

    /// A menu item's shortcut as Accessibility gives it (AXMenuItemCmdChar, AXMenuItemCmdModifiers; 8 is "no ⌘"):
    /// the same in every language, so it's what a menu item is known by first.
    static func clip(shortcut character: String?, modifiers: Int = 0) -> Clip? {
        guard modifiers & 8 == 0 else { return nil }
        return clip(character: character)
    }

    private static func clip(character: String?) -> Clip? {
        switch character?.lowercased() {
        case "v": return .paste
        case "c", "x": return .copy
        default: return nil
        }
    }

    /// The app's own name for it (AXIdentifier), which for AppKit's menu items and buttons is often the action's
    /// selector: "paste:", "pasteAsPlainText:", "copy:", "cut:", a web page's "paste-button".
    static func clip(identifier: String) -> Clip? {
        let parts = identifierWords(identifier)
        if parts.contains("paste") { return .paste }
        if parts.contains("copy") || parts.contains("cut") { return .copy }
        return nil
    }

    /// "pasteAsPlainText:" as ["paste", "as", "plain", "text"].
    static func identifierWords(_ identifier: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in identifier {
            guard character.isLetter else {
                if !current.isEmpty { parts.append(current); current = "" }
                continue
            }
            if character.isUppercase, current.last?.isLowercase == true { parts.append(current); current = "" }
            current.append(character)
        }
        if !current.isEmpty { parts.append(current) }
        return parts.map { $0.lowercased() }
    }

    /// The words of a Paste, Copy or Cut command in the languages macOS speaks most, for when the shortcut and the
    /// app's own name for it don't say: the first word of the title ("Paste and Match Style", "Düzen › Yapıştır").
    static let pasteWords = ["paste", "yapıştır", "einsetzen", "einfügen", "coller", "pegar", "incolla", "colar", "plakken", "plak",
                             "вставить", "вставка"]
    static let copyWords = ["copy", "cut", "kopyala", "kes", "kopieren", "ausschneiden", "copier", "couper", "copiar", "cortar", "copia",
                            "taglia", "recortar", "kopiëren", "kopieer", "knippen", "knip", "скопировать", "копировать", "вырезать"]
    /// Languages written without spaces: how the title starts.
    static let pasteStarts = ["ペースト", "貼り付け", "粘贴", "粘貼", "貼上", "붙여넣"]
    static let copyStarts = ["コピー", "カット", "拷贝", "拷貝", "复制", "剪切", "剪下", "복사", "잘라내"]
    private static let foldedPaste = Set(pasteWords.map(fold)), foldedCopy = Set(copyWords.map(fold))
    private static let foldedPasteStarts = pasteStarts.map(fold), foldedCopyStarts = copyStarts.map(fold)

    /// Lowercase, without accents, and Turkish's dotless ı as i ("YAPIŞTIR" and "Yapıştır" alike).
    static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ı", with: "i").folding(options: .diacriticInsensitive, locale: nil)
    }

    /// The last part of a menu path, or a button's title, says Paste, Copy or Cut (in any of the languages above).
    static func clip(title: String?) -> Clip? {
        guard let last = title.flatMap({ menuPath($0).last }) else { return nil }
        let folded = fold(last)
        if let first = words(folded).first {
            if foldedPaste.contains(first) { return .paste }
            if foldedCopy.contains(first) { return .copy }
        }
        if foldedPasteStarts.contains(where: folded.hasPrefix) { return .paste }
        if foldedCopyStarts.contains(where: folded.hasPrefix) { return .copy }
        return nil
    }

    /// A menu item: its shortcut first, then the app's own name for it, then its words.
    static func clip(menuItem title: String?, identifier: String = "", character: String? = nil, modifiers: Int = 0) -> Clip? {
        clip(shortcut: character, modifiers: modifiers) ?? clip(identifier: identifier) ?? clip(title: title)
    }

    /// A button or other control: the app's own name for it, then its title, description and help.
    static func clip(control node: UINode) -> Clip? {
        clip(identifier: node.identifier) ?? [node.title, node.label, node.help].lazy.compactMap { clip(title: $0) }.first
    }

    /// Any word anywhere in a control's names is a paste word ("Quick paste", "Clipboard: paste here"): refused while
    /// the clipboard holds a secret, even when `clip(control:)` can't tell.
    static func mightPaste(_ node: UINode) -> Bool {
        mentions(node, foldedPaste, foldedPasteStarts)
    }

    /// Any word anywhere in a control's names is a copy or cut word ("Click to copy API key", "Kopyalamak için
    /// tıkla"): it gets a Copy button's checks (the window read for secrets first, the clipboard watched after),
    /// even when `clip(control:)` can't tell.
    static func mightCopy(_ node: UINode) -> Bool {
        mentions(node, foldedCopy, foldedCopyStarts)
    }

    /// After a copy-like press, the clipboard is watched for a moment, from its change count `start` just before:
    /// `wait` while it hasn't moved, `look` once it moved by exactly one (the press's own copy), and `leave` for good
    /// once it moved further (someone else copied too) or the person typed or clicked: then it's theirs.
    enum CopyWatch: Equatable { case wait, look, leave }

    static func copyWatch(start: Int, now: Int, input: Bool) -> CopyWatch {
        if input { return .leave }
        if now == start { return .wait }
        return now == start &+ 1 ? .look : .leave
    }

    /// The clipboard is cleared only when what the press copied (`seen`, one step after `start`) holds a secret, it is
    /// still exactly that copy right before clearing (`now`), and the person gave no input meanwhile.
    static func clearsCopy(start: Int, seen: Int, now: Int, input: Bool, secret: Bool) -> Bool {
        secret && !input && seen == start &+ 1 && now == seen
    }

    /// One of `words` is a word of its title, description, help or the app's own name for it ("copyApiKey"), or one of
    /// `starts` (languages written without spaces) is anywhere in them.
    private static func mentions(_ node: UINode, _ words: Set<String>, _ starts: [String]) -> Bool {
        if identifierWords(node.identifier).map(fold).contains(where: words.contains) { return true }
        return [node.title, node.label, node.help, node.identifier].contains { text in
            let folded = fold(text)
            return Self.words(folded).contains(where: words.contains) || starts.contains(where: folded.contains)
        }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
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

    // MARK: Has the control changed?

    /// What a control means, as `petal_ui` saw it: what it is, what it says, and a switch's state. The same button may
    /// mean the opposite a moment later (Mute becomes Unmute when the person mutes by keyboard while asked), so this
    /// is read again right before acting, and any change refuses the act. Kept by Petal, never told to the AI.
    struct Meaning: Equatable {
        var role = ""
        var subrole = ""
        var title = ""
        var label = ""
        /// A checkbox's, radio button's, switch's or toggle's value ("1", "0", "2"); empty for every other control.
        var state = ""
    }

    /// A control that is on or off: a checkbox, radio button, switch or toggle (its value is its state).
    static func isToggle(role: String, subrole: String) -> Bool {
        ["AXCheckBox", "AXRadioButton"].contains(role) || ["AXSwitch", "AXToggle"].contains(subrole)
    }

    /// The meaning as kept: each text tidied and cut to 200 characters (as Reader cuts them), the state only for a toggle.
    static func meaning(role: String, subrole: String, title: String, label: String, value: String = "") -> Meaning {
        func clean(_ text: String) -> String { String(tidy(text).prefix(200)) }
        return Meaning(role: role, subrole: subrole, title: clean(title), label: clean(label),
                       state: isToggle(role: role, subrole: subrole) ? clean(value) : "")
    }

    /// Why an act can't go ahead on a control that meant `then` and means `now`, or nil. `secret`: a text holding one
    /// of the vault's secrets, which the reason never repeats.
    static func changed(_ then: Meaning, _ now: Meaning, secret: (String) -> Bool = { _ in false }) -> String? {
        guard then != now else { return nil }
        let look = "; look again with petal_ui."
        if then.role != now.role || then.subrole != now.subrole {
            return "That control changed (it's a \(kind(UINode(role: now.role, subrole: now.subrole))) now)" + look
        }
        if then.title != now.title || then.label != now.label {
            let said = name(UINode(role: now.role, title: now.title, label: now.label))
            if said.isEmpty { return "That control changed (it has no name now)" + look }
            return "That control changed (it now says \(secret(said) ? hidden : said))" + look
        }
        let state = now.state == "1" ? "on" : now.state == "0" ? "off" : now.state == "2" ? "mixed" : truncate(now.state, 40)
        return "That control changed (it's \(state.isEmpty ? "different" : state) now)" + look
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

// MARK: - Reading that must be whole

extension UIMap {
    /// `build`, done again while `generation` moved on under it (something it depends on changed meanwhile), at most
    /// `attempts` times: the value and the generation it holds for, or nil when it never settled. The vault's index
    /// and what's redacted with it use this, so a secret Petal starts typing while either is made is never missed.
    static func settled<T>(attempts: Int = 3, generation: () -> Int, _ build: () -> T) -> (value: T, generation: Int)? {
        for _ in 0..<max(1, attempts) {
            let before = generation()
            let value = build()
            if generation() == before { return (value, before) }
        }
        return nil
    }

    /// What asking an element for its children through Accessibility said.
    enum ChildRead: Equatable {
        case children(Int)
        /// It has none (the attribute isn't there or holds nothing).
        case none
        /// The element went away meanwhile: nothing of it shows any more.
        case gone
        /// The app didn't answer (busy, or an error): what's under it is unknown.
        case unreadable
    }

    /// An AXError's raw value (and how many children came back) as a ChildRead: 0 success, -25202 invalid element,
    /// -25205 attribute unsupported, -25212 no value, -25208 not implemented; anything else (-25204 cannot complete,
    /// -25200 failure, …) is unreadable.
    static func childRead(error: Int32, count: Int) -> ChildRead {
        switch error {
        case 0: return count > 0 ? .children(count) : .none
        case -25205, -25212, -25208: return .none
        case -25202: return .gone
        default: return .unreadable
        }
    }

    /// Whether a scan that must see a whole window (what a picture would show) saw all that's under an element: not
    /// when its children couldn't be read, nor when it has children past the deepest the scan goes.
    static func covered(_ read: ChildRead, depth: Int, maxDepth: Int) -> Bool {
        switch read {
        case .unreadable: return false
        case .children: return depth < maxDepth
        case .none, .gone: return true
        }
    }
}
