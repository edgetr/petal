import SwiftUI

/// Petal's sizes and its parts' colors, once. Every font size and corner radius in the app is one of these, by name,
/// so a title in Settings and a title in a popover are the same size, and nested corners agree. A new view picks the
/// nearest step; a size that fits none is a sign the view is doing something the others don't.

/// Font sizes, in points: macOS's own ladder, with one step under it for a badge's count.
enum TextSize {
    /// A badge's count, the smallest label on a control.
    static let micro: CGFloat = 9
    /// A keycap, a stamp, a label under a picture.
    static let caption: CGFloat = 10
    /// A helper line under a setting, a letterhead.
    static let small: CGFloat = 11
    /// Secondary text: a row's detail, a group's label.
    static let callout: CGFloat = 12
    /// What's read and what's pressed: a row's title, a button, a note's writing.
    static let body: CGFloat = 13
    /// A card's or a row's own title where it leads.
    static let heading: CGFloat = 15
    /// A panel's title.
    static let subtitle: CGFloat = 17
    /// A page's title.
    static let title: CGFloat = 22
    /// The one large title of a window.
    static let large: CGFloat = 26

    static let all: [CGFloat] = [micro, caption, small, callout, body, heading, subtitle, title, large]
}

/// Corner radii, in points. Nested corners are concentric: the outer one is the inner one plus the padding between
/// them (`around`), never the same radius twice.
enum Radius {
    /// A chip in a line of text, a checkbox.
    static let chip: CGFloat = 4
    /// A button, a field, a keycap, a small tile.
    static let control: CGFloat = 8
    /// A row's highlight, a picture in a card, a tile.
    static let tile: CGFloat = 12
    /// A card, a paper, a popover's inner group.
    static let card: CGFloat = 16
    /// A popover, a panel over the dock.
    static let panel: CGFloat = 20
    /// A window's own glass, the dock's largest panels.
    static let window: CGFloat = 24

    static let all: [CGFloat] = [chip, control, tile, card, panel, window]

    /// The step for a corner that wraps one of `inner` with `padding` between them.
    static func around(_ inner: CGFloat, padding: CGFloat) -> CGFloat {
        let wanted = inner + padding
        return all.min { abs($0 - wanted) < abs($1 - wanted) } ?? wanted
    }
}

/// Petal's parts, each in its own color: the notes' paper colors, the same ones the site and the video use for the
/// same part. Color goes on content (a tile, a symbol, a dot), never tinted into glass.
enum Part: String, CaseIterable {
    case dock, look, notes, ai, vault, routines, privacy, about

    var color: Color {
        switch self {
        case .dock: Color(red: 0xd9 / 255, green: 0x36 / 255, blue: 0x7f / 255)       // pink, Petal's accent
        case .look: Color(red: 0xf6 / 255, green: 0xc7 / 255, blue: 0x44 / 255)       // yellow
        case .notes: Color(red: 0xf2 / 255, green: 0x91 / 255, blue: 0x2e / 255)      // orange
        case .ai: Color(red: 0x2b / 255, green: 0x6f / 255, blue: 0xe6 / 255)         // blue
        case .vault: Color(red: 0x9a / 255, green: 0x52 / 255, blue: 0xb5 / 255)      // purple
        case .routines: Color(red: 0x2f / 255, green: 0xa8 / 255, blue: 0x68 / 255)   // green
        case .privacy, .about: Color(red: 0x8a / 255, green: 0x8c / 255, blue: 0x93 / 255)   // ink on paper: neutral
        }
    }

    /// What's drawn on the color: ink on the light ones, white on the rest.
    var onColor: Color {
        switch self {
        case .look, .notes: Color(red: 0x17 / 255, green: 0x18 / 255, blue: 0x1c / 255)
        default: .white
        }
    }
}
