import AppKit
import SwiftUI

/// The @ in a note's editor: what each @ and understood word bound to, drawn as a small chip after it (@Friday 9:00),
/// mentions tinted in the notebook's color, and the @ menu (Petal, then notes and notebooks by name) under the cursor.
/// Only drawing and the menu: the note's text is never changed by any of it (chips sit in room kept with kerning,
/// mentions are tinted with the layout manager's temporary attributes), so the Markdown round trip stays exact.
@MainActor
final class MentionState {
    var menu: MentionMenuPanel?
    var choices: [MentionChoice] = []
    var selected = 0
    /// Where the @ being typed is.
    var start: Int?
    /// Each chip: the character after which it's drawn, and its words.
    var chips: [(at: Int, text: String)] = []
}

/// A chip's mark in the text (with the kerning that keeps room for it): a decoration, never written to the note.
let mentionChipKey = NSAttributedString.Key("petal.mentionChip")

extension NoteTextView {
    static let chipFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    private func color(_ amount: Double, _ other: NoteInk.RGB) -> NSColor {
        let c = NoteInk.mix(tint, amount, other)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// Mentions and understood words found again (a note's text is short): tinted, and room kept for their chips.
    func decorateMentions() {
        guard let storage = textStorage, let layoutManager else { return }
        let text = storage.string as NSString
        let whole = NSRange(location: 0, length: text.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: whole)
        // The room kept for the last chips goes first.
        storage.beginEditing()
        storage.enumerateAttribute(mentionChipKey, in: whole) { value, range, _ in
            guard value != nil else { return }
            storage.removeAttribute(mentionChipKey, range: range)
            storage.removeAttribute(.kern, range: range)
        }
        mentions.chips = []
        guard text.length < 40_000, text.contains("@") || text.localizedCaseInsensitiveContains("when") else { storage.endEditing(); return }
        let names = mentionNames()
        let now = Date()
        var location = 0
        for line in (storage.string).components(separatedBy: "\n") {
            let length = (line as NSString).length
            defer { location += length + 1 }
            guard line.contains("@") else { continue }
            for binding in NoteHelp.bindings(line, notes: names.notes, notebooks: names.notebooks, now: now, place: names.place) {
                let range = NSRange(location: location + binding.range.location, length: binding.range.length)
                guard NSMaxRange(range) <= text.length else { continue }
                if binding.at {
                    layoutManager.addTemporaryAttributes([.backgroundColor: color(0.18, NoteInk.RGB(r: 1, g: 1, b: 1)),
                                                          .foregroundColor: color(0.70, NoteInk.RGB(r: 0, g: 0, b: 0))], forCharacterRange: range)
                } else {
                    layoutManager.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue],
                                                          forCharacterRange: range)
                }
                guard !binding.chip.isEmpty else { continue }
                let last = NSRange(location: NSMaxRange(range) - 1, length: 1)
                let width = ceil((binding.chip as NSString).size(withAttributes: [.font: Self.chipFont]).width) + 6
                storage.addAttributes([.kern: width, mentionChipKey: binding.chip], range: last)
                mentions.chips.append((last.location, binding.chip))
            }
        }
        storage.endEditing()
        needsDisplay = true
    }

    /// The chips, each in the room kept after its word: a little raised, in the notebook's ink.
    func drawMentionChips() {
        guard !mentions.chips.isEmpty, let layoutManager, let storage = textStorage else { return }
        let ink = color(0.70, NoteInk.RGB(r: 0, g: 0, b: 0)).withAlphaComponent(0.65)
        for chip in mentions.chips where chip.at < storage.length {
            let glyph = layoutManager.glyphIndexForCharacter(at: chip.at)
            guard glyph < layoutManager.numberOfGlyphs else { continue }
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let x = fragment.minX + layoutManager.location(forGlyphAt: glyph).x
            var plain = storage.attributes(at: chip.at, effectiveRange: nil)
            plain[.kern] = nil
            let own = (storage.attributedSubstring(from: NSRange(location: chip.at, length: 1)).string as NSString).size(withAttributes: plain).width
            let size = (chip.text as NSString).size(withAttributes: [.font: Self.chipFont])
            let origin = NSPoint(x: textContainerOrigin.x + x + own + 3, y: textContainerOrigin.y + fragment.minY + (fragment.height - size.height) / 2 - 2)
            (chip.text as NSString).draw(at: origin, withAttributes: [.font: Self.chipFont, .foregroundColor: ink])
        }
    }

    /// The line the cursor ends, when Return there asks a helper: the cursor at its very end, nothing selected.
    func helperLine() -> (words: String, line: NoteLine)? {
        let text = string as NSString
        let selection = selectedRange()
        guard selection.length == 0 else { return nil }
        let line = text.lineRange(for: NSRange(location: min(selection.location, text.length), length: 0))
        var end = NSMaxRange(line)
        if end > line.location, end <= text.length, text.character(at: end - 1) == 10 { end -= 1 }
        guard selection.location == end else { return nil }
        let words = text.substring(with: NSRange(location: line.location, length: end - line.location))
            .replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)
        // Only the line as the person wrote or edited it (its mark still runnable): an untouched line makes a new line.
        guard NoteHelp.calls(words), let runnable = runnableLine(NSRange(location: line.location, length: end - line.location)) else { return nil }
        return (words, runnable)
    }

    // MARK: The @ menu

    /// The @ being typed (right before the cursor, on this line): its menu shows, narrowed by what follows it.
    func updateMentionMenu() {
        let text = string as NSString
        let selection = selectedRange()
        guard selection.length == 0, window != nil, isEditable else { return closeMentionMenu() }
        var index = selection.location - 1
        while index >= 0, selection.location - index <= 40 {
            let character = text.character(at: index)
            if character == 64 { break }   // @
            if character == 10 { return closeMentionMenu() }
            index -= 1
        }
        guard index >= 0, text.character(at: index) == 64 else { return closeMentionMenu() }
        if index > 0, let before = Unicode.Scalar(text.character(at: index - 1)), CharacterSet.alphanumerics.contains(before) { return closeMentionMenu() }
        let typed = text.substring(with: NSRange(location: index + 1, length: selection.location - index - 1))
        guard !typed.contains("]"), !typed.contains("  "), typed.split(separator: " ").count <= 3 else { return closeMentionMenu() }
        let names = mentionNames()
        let choices = MentionChoice.choices(typed.hasPrefix("[") ? String(typed.dropFirst()) : typed, notes: names.notes, notebooks: names.notebooks)
        guard !choices.isEmpty else { return closeMentionMenu() }
        if mentions.start != index || mentions.choices != choices { mentions.selected = 0 }
        mentions.start = index
        mentions.choices = choices
        showMentionMenu()
    }

    private func showMentionMenu() {
        guard let start = mentions.start, let window else { return }
        let rect = firstRect(forCharacterRange: NSRange(location: start, length: 1), actualRange: nil)
        guard rect.width.isFinite, window.isVisible else { return }
        let menu = mentions.menu ?? MentionMenuPanel()
        mentions.menu = menu
        menu.show(MentionMenuView(choices: mentions.choices, selected: mentions.selected, accent: style.accent) { [weak self] index in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.mentions.selected = index
                _ = self.pickMention()
            }
        }, under: rect)
        if menu.parent == nil { window.addChildWindow(menu, ordered: .above) }
    }

    func closeMentionMenu() {
        mentions.start = nil
        mentions.choices = []
        guard let menu = mentions.menu else { return }
        menu.parent?.removeChildWindow(menu)
        menu.orderOut(nil)
    }

    /// Return or Tab (or a click) on the menu: the @ and what's typed after it become the choice's mention.
    @discardableResult
    func pickMention() -> Bool {
        guard mentions.menu?.isVisible == true, let start = mentions.start, mentions.choices.indices.contains(mentions.selected) else { return false }
        let choice = mentions.choices[mentions.selected]
        let end = selectedRange().location
        closeMentionMenu()
        guard end >= start else { return true }
        insertText(NoteHelp.mention(choice.name) + " ", replacementRange: NSRange(location: start, length: end - start))
        return true
    }

    func mentionCommand(_ selector: Selector) -> Bool {
        guard mentions.menu?.isVisible == true, !mentions.choices.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): mentions.selected = (mentions.selected + 1) % mentions.choices.count
        case #selector(NSResponder.moveUp(_:)): mentions.selected = (mentions.selected + mentions.choices.count - 1) % mentions.choices.count
        case #selector(NSResponder.insertTab(_:)): return pickMention()
        case #selector(NSResponder.cancelOperation(_:)): closeMentionMenu(); return true
        default: return false
        }
        showMentionMenu()
        return true
    }
}

// MARK: - The @ menu

/// What the @ menu offers: Petal first, then notes and notebooks whose names start with (or hold) what's typed.
struct MentionChoice: Equatable, Identifiable {
    enum Kind { case petal, note, notebook }
    let kind: Kind
    let name: String
    var id: String { "\(kind)" + name }

    static func choices(_ typed: String, notes: [String], notebooks: [String]) -> [MentionChoice] {
        let query = typed.lowercased()
        let fits = { (name: String) in query.isEmpty || name.lowercased().hasPrefix(query) || name.lowercased().contains(" " + query) || name.lowercased().contains(query) }
        var out: [MentionChoice] = []
        if fits(NoteHelp.petal) { out.append(MentionChoice(kind: .petal, name: NoteHelp.petal)) }
        out += notes.filter(fits).prefix(6).map { MentionChoice(kind: .note, name: $0) }
        out += notebooks.filter(fits).prefix(3).map { MentionChoice(kind: .notebook, name: $0) }
        return out
    }
}

/// The @ menu, as the sketch draws it: a small light panel, Petal, a line, then notes and notebooks.
struct MentionMenuView: View {
    let choices: [MentionChoice]
    let selected: Int
    let accent: NSColor
    let pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                if index > 0, choices[index - 1].kind == .petal {
                    Rectangle().fill(.black.opacity(0.1)).frame(height: 0.5).padding(.vertical, 4).padding(.horizontal, 8)
                }
                Button { pick(index) } label: {
                    HStack(spacing: 8) {
                        Text(symbol(choice.kind)).frame(width: 14)
                        Text(choice.name).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(hint(choice.kind)).opacity(0.6)
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(index == selected ? Color.white : Color(white: 0.11))
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .background(index == selected ? Color(nsColor: accent) : .clear, in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .frame(width: 250)
        .background(Color(.sRGB, red: 250 / 255, green: 250 / 255, blue: 252 / 255, opacity: 0.97), in: .rect(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(.black.opacity(0.2), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.22), radius: 16, y: 12)
        .environment(\.colorScheme, .light)
    }

    private func symbol(_ kind: MentionChoice.Kind) -> String {
        switch kind { case .petal: "✦"; case .note: "▢"; case .notebook: "▤" }
    }

    private func hint(_ kind: MentionChoice.Kind) -> String {
        switch kind { case .petal: "does it here"; case .note: ""; case .notebook: "notebook" }
    }
}

/// The @ menu's panel, under the cursor in a note: never takes the keyboard (the note keeps typing; arrows, Return,
/// Tab and Escape reach it through the editor).
final class MentionMenuPanel: NSPanel {
    private var host: NSHostingView<AnyView>?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 270, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @MainActor func show(_ view: MentionMenuView, under rect: NSRect) {
        let content = AnyView(view.padding(EdgeInsets(top: 4, leading: 10, bottom: 24, trailing: 10)))
        if let host { host.rootView = content } else {
            let made = NSHostingView(rootView: content)
            host = made
            contentView = made
        }
        let size = host?.fittingSize ?? NSSize(width: 270, height: 100)
        let screen = Screens.all.first { $0.frame.intersects(rect) }?.visibleFrame ?? Screens.main?.visibleFrame ?? rect
        var origin = NSPoint(x: rect.minX - 10, y: rect.minY - size.height)
        if origin.y < screen.minY { origin.y = rect.maxY }
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFront(nil)
    }
}
