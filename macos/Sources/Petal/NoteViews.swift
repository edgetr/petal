import AppKit
import SwiftUI

/// Petal Notes' paper: its sizes, type and colors, as the sketch has them (notes-round2.html). A note is a square
/// of paper folded at 170 points; open it grows to 360 wide and as tall as its writing. Paper is an opaque warm
/// paper with 15% of its notebook's color and a 5-point strip of it on top; glass is macOS's own Liquid Glass.
enum PaperLook {
    static let folded: CGFloat = 170
    static let openWidth: CGFloat = 360
    static let minOpen: CGFloat = 220
    static let maxOpen: CGFloat = 560
    /// Room around the paper in its panel, for its shadow.
    static let margin: CGFloat = 16

    static func rgb(_ color: NSColor) -> NoteInk.RGB {
        let c = color.usingColorSpace(.sRGB) ?? NSColor.systemBlue
        return NoteInk.RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
    }

    static func color(_ c: NoteInk.RGB) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b) }
    static func nsColor(_ c: NoteInk.RGB) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }

    /// The words on paper: #222. On glass: the system's own.
    static let words = Color(.sRGB, red: 0x22 / 255.0, green: 0x22 / 255.0, blue: 0x22 / 255.0)
    static let footer = Color(.sRGB, red: 0x6b / 255.0, green: 0x6b / 255.0, blue: 0x70 / 255.0)
}

/// What one paper shows: folded, open, or its back.
enum PaperFace { case folded, open, back }

/// One note's paper, as it shows on the screen and in snapshots.
struct PaperView: View {
    let paper: PaperNote
    let color: NSColor
    let glass: Bool
    let face: PaperFace
    /// The letterhead: where it's stuck, its notebook, and its other place (or how many).
    let place: String
    let notebook: String
    let others: String
    /// The note's own line of what's coming (or when it was written), folded.
    let footer: String
    var keyboard = false
    var editorHeight: CGFloat = 0
    var desk: NoteDesk?
    var conflict = false
    /// Its last write failed: kept here, tried again, and said on the paper.
    var unsaved = false
    /// Pictures whose bytes couldn't be saved: said on the paper, with Try again and Remove.
    var pictureTrouble = 0
    /// Open, its width (Petal's viewer's margin is narrower than the room beside a window).
    var width: CGFloat = PaperLook.openWidth
    /// Turned over and folded by its holder when it isn't the desk (Petal's viewer's margin).
    var flipped: (() -> Void)? = nil
    var folded: (() -> Void)? = nil

    @Environment(\.snapshotting) private var snapshotting
    /// This paper's editor, as the desk knows it: only its own going away clears its registration (the same note
    /// opening in Petal's viewer as it closes here never loses the viewer's).
    @State private var editorToken = UUID()

    private var tint: NoteInk.RGB { PaperLook.rgb(color) }
    private var words: Color { glass ? .primary : PaperLook.words }

    var body: some View {
        content
            .padding(.top, face == .open ? 16 : 15).padding(.horizontal, face == .open ? 18 : 14).padding(.bottom, face == .open ? 14 : 12)
            .frame(width: face == .folded ? PaperLook.folded : width,
                   height: face == .folded ? PaperLook.folded : nil, alignment: .topLeading)
            // The strip is the paper's width, whatever room the paper is offered.
            .overlay(alignment: .top) { strip }
        .overlay(alignment: .bottomTrailing) { corner }
        .clipShape(.rect(cornerRadius: 12))
        // The shadow is the paper's alone: on the whole view SwiftUI would give every letter one too.
        .background { surface.clipShape(.rect(cornerRadius: 12)).modifier(PaperShadow(glass: glass)) }
        .modifier(PaperScheme(glass: glass))
    }

    @ViewBuilder private var surface: some View {
        if glass {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            PaperLook.color(face == .back ? NoteInk.mix(tint, 0.09, NoteInk.paper) : NoteInk.paper(tint))
        }
    }

    @ViewBuilder private var strip: some View {
        if glass {
            Capsule().fill(Color(nsColor: color)).frame(width: 34, height: 4).frame(maxWidth: .infinity).padding(.top, 6)
        } else {
            Rectangle().fill(Color(nsColor: color)).frame(height: 5).frame(maxWidth: .infinity)
        }
    }

    /// The folded corner (flip to the back) and the faint @.
    private var corner: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Text("@").font(.system(size: 13, weight: .semibold)).foregroundStyle(glass ? Color.primary.opacity(0.22) : Color.black.opacity(0.22))
                .padding(.trailing, 8).padding(.bottom, 9)
                .help("@ for a helper, a note or a place (coming soon)")
            Button { if let flipped { flipped() } else { desk?.flip(paper.key) } } label: { FoldCorner().fill(Color.black.opacity(0.13)).frame(width: 24, height: 24).contentShape(.rect) }
                .buttonStyle(.plain)
                .help(face == .back ? "Turn it back over" : "Turn it over")
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Folded, a page is its site alone, as the sketch's folded notes say it.
            Letterhead(place: face == .folded ? NoteText.site(place) : place, notebook: notebook, others: face == .folded ? "" : others, tint: tint, glass: glass,
                       tapPlace: { desk?.placeMenu(paper.key) }, tapNotebook: { desk?.notebookMenu(paper.key) })
                .padding(.bottom, 9)
            switch face {
            case .folded: foldedBody
            case .open: openBody
            case .back: back
            }
        }
    }

    private var foldedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                let titled = NoteBlock.blocks(paper.file.body).first { !$0.words.trimmingCharacters(in: .whitespaces).isEmpty }.map { if case .heading = $0 { true } else { false } } ?? false
                let title = paper.file.title
                let preview = paper.file.preview
                // The sketch's folded note: a 14-point bold title, 3 points above 13.5-point medium words at a 1.32 line height.
                VStack(alignment: .leading, spacing: 3) {
                    if titled { Text(title).font(.system(size: 14, weight: .bold)).lineLimit(2) }
                    Text(titled ? preview : [title, preview].filter { !$0.isEmpty }.joined(separator: " "))
                        .font(.system(size: 13.5, weight: .medium))
                        .lineSpacing(13.5 * 1.32 - 16.1)
                }
                    .foregroundStyle(words)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            }
            if conflict {
                Button("Keep this one") { desk?.keep(paper.key) }.buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(PaperLook.color(NoteInk.letterhead(tint)))
                    .padding(.bottom, 4)
            }
            HStack(spacing: 6) {
                Text(unsaved ? "Not saved yet: trying again" : footer).font(.system(size: 11))
                    .foregroundStyle(unsaved ? Color(red: 0.7, green: 0.15, blue: 0.12) : glass ? .secondary : PaperLook.footer).lineLimit(1)
            }
            .padding(.trailing, 44)
        }
    }

    @ViewBuilder private var openBody: some View {
        if pictureTrouble > 0, let desk {
            HStack(spacing: 10) {
                Text(pictureTrouble == 1 ? "Picture couldn't be saved" : "\(pictureTrouble) pictures couldn't be saved")
                    .font(.system(size: 11)).foregroundStyle(Color(red: 0.7, green: 0.15, blue: 0.12))
                Spacer()
                Button("Try again") { desk.retryPictures(paper.key) }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                Button("Remove") { desk.dropPictures(paper.key) }.buttonStyle(.plain).font(.system(size: 11))
            }
            .foregroundStyle(PaperLook.color(NoteInk.letterhead(tint)))
            .padding(.bottom, 6)
        }
        if unsaved {
            Text("Not saved yet: Petal keeps it here and tries again.").font(.system(size: 11)).foregroundStyle(Color(red: 0.7, green: 0.15, blue: 0.12))
                .padding(.bottom, 6)
        }
        if conflict {
            HStack {
                Text("Changed on two Macs at once").font(.system(size: 11)).foregroundStyle(glass ? .secondary : PaperLook.footer)
                Spacer()
                Button("Keep this one") { desk?.keep(paper.key) }.buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(PaperLook.color(NoteInk.letterhead(tint)))
            }
            .padding(.bottom, 6)
        }
        // One of a conflict's papers is read only, with Keep this one: nothing typed into it could be kept.
        if snapshotting || desk == nil {
            NoteBodyView(paper: paper, tint: tint, accent: color, glass: glass).padding(.bottom, 18)
        } else if conflict {
            // Read only, in a scroll view as tall as the editor may be: a long one never runs off the screen.
            ConflictBody(paper: paper, tint: tint, accent: color, glass: glass, resized: { desk?.measured(paper.key, $0) }).padding(.bottom, 18)
        } else if let desk {
            NoteEditorView(paper: paper, style: desk.style(color, glass: glass), focus: keyboard,
                           height: { desk.measured(paper.key, $0) },
                           // Saved through the note's identity: renamed or moved meanwhile, it lands on that note.
                           save: { desk.write(paper.key, noteID: paper.noteID, instance: paper.instance, body: $0, base: $1) },
                           register: { [editorToken] in desk.editorRegistered(paper.key, $0, token: editorToken) },
                           importPictures: { desk.importPictures($0, into: paper.key) },
                           idle: { desk.store.takeDeferred(paper.key) },
                           sameNote: { desk.store.sameNote($0, instance: $1, $2) },
                           say: { desk.tell($0) },
                           acceptPictures: { desk.acceptCopiedPictures(paper.key, $0) },
                           // In a paper's own panel, Escape goes up to the panel (handled once there); in Petal's viewer's
                           // margin there's no such panel, so it folds the note there.
                           escape: folded,
                           settled: { desk.settleUnsaved(paper.key, noteID: paper.noteID, instance: paper.instance, saved: $0) })
                .frame(height: min(PaperLook.maxOpen - 70, max(PaperLook.minOpen - 70, editorHeight)))
                .padding(.bottom, 18)
        }
    }

    private var back: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The back of this note").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(words)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(paper.file.places.enumerated()), id: \.offset) { _, stick in
                    Text(NoteDesk.describe(stick)).font(.system(size: 12.5)).foregroundStyle(words).lineLimit(2)
                }
                if paper.file.places.isEmpty {
                    Text("Not stuck anywhere yet.").font(.system(size: 12.5)).foregroundStyle(glass ? .secondary : PaperLook.footer)
                }
            }
            Text("In \(notebook)").font(.system(size: 12.5)).foregroundStyle(words)
            Text("Made \(NoteDesk.when(paper.file.created)) · changed \(NoteDesk.when(paper.file.modified))")
                .font(.system(size: 11)).foregroundStyle(glass ? .secondary : Color(white: 0.53))
            if let desk {
                Button("Show the file") { desk.reveal(paper.key) }.buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(PaperLook.color(NoteInk.letterhead(tint)))
            }
            Spacer(minLength: 18)
        }
        .frame(minHeight: 180, alignment: .topLeading)
    }
}

/// The letterhead, the note's only chrome: where it's stuck, then its notebook (and "also on N places").
struct Letterhead: View {
    let place: String
    let notebook: String
    let others: String
    let tint: NoteInk.RGB
    let glass: Bool
    var tapPlace: () -> Void = {}
    var tapNotebook: () -> Void = {}

    var body: some View {
        let ink = glass ? Color.primary.opacity(0.75) : PaperLook.color(NoteInk.letterhead(tint))
        HStack(spacing: 6) {
            Button(action: tapPlace) { Text(place).fontWeight(.semibold) }.buttonStyle(.plain)
                .help("Change where it's stuck")
            Button(action: tapNotebook) {
                Text("· " + notebook + (others.isEmpty ? "" : " · also on " + others)).fontWeight(.medium)
            }
            .buttonStyle(.plain).opacity(0.7)
            .help("Change its notebook")
        }
        .font(.system(size: 10.5))
        .tracking(0.1)
        .foregroundStyle(ink)
        .lineLimit(1)
    }
}

/// The note's writing, read only: in snapshots, and wherever the editor isn't.
/// One of a conflict's papers, read only: its text in a bounded scroll view, as high as its words up to the editor's
/// greatest height (the paper never grows past it, so it stays on the screen).
struct ConflictBody: View {
    let paper: PaperNote
    let tint: NoteInk.RGB
    let accent: NSColor
    let glass: Bool
    /// Its height changed: the paper fits itself to it again.
    var resized: (CGFloat) -> Void = { _ in }
    @State private var height: CGFloat = 0

    struct Height: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        ScrollView(.vertical) {
            NoteBodyView(paper: paper, tint: tint, accent: accent, glass: glass)
                .background(GeometryReader { Color.clear.preference(key: Height.self, value: $0.size.height) })
        }
        .scrollIndicators(.automatic)
        .onPreferenceChange(Height.self) { new in
            height = new
            resized(new)
        }
        .frame(height: min(PaperLook.maxOpen - 70, max(PaperLook.minOpen - 70, height)))
    }
}

struct NoteBodyView: View {
    let paper: PaperNote
    let tint: NoteInk.RGB
    let accent: NSColor
    let glass: Bool

    var body: some View {
        let words: Color = glass ? .primary : PaperLook.words
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(NoteBlock.blocks(paper.file.body).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(text).font(.system(size: level == 1 ? 17 : level == 2 ? 15 : 14, weight: .bold)).tracking(-0.17).foregroundStyle(words)
                        .padding(.bottom, 4)
                case .check(let done, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: done ? "checkmark.square.fill" : "square").font(.system(size: 13))
                            .foregroundStyle(done ? Color(nsColor: accent) : words.opacity(0.4))
                        Text(NoteText.plain(text)).font(.system(size: 13.5)).foregroundStyle(words)
                    }
                    .lineSpacing(3)
                case .link(let url):
                    LinkCardView(url: url).padding(.vertical, 8)
                case .image(let path, let caption):
                    PictureView(link: path, folder: paper.url.deletingLastPathComponent(), caption: caption).padding(.vertical, 8)
                case .ink(let text):
                    Text(NoteText.plain(text)).font(.system(size: 13.5)).foregroundStyle(glass ? .primary : PaperLook.color(NoteInk.ink(tint)))
                        .padding(.leading, 9)
                        .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: accent).opacity(0.4)).frame(width: 2) }
                        .padding(.vertical, 4)
                case .bullet(let text):
                    Text("• " + NoteText.plain(text)).font(.system(size: 13.5)).foregroundStyle(words).lineSpacing(3)
                case .text(let text):
                    Text(NoteText.plain(text).isEmpty ? " " : NoteText.plain(text)).font(.system(size: 13.5)).foregroundStyle(words).lineSpacing(3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct LinkCardView: View {
    let url: String

    var body: some View {
        HStack(spacing: 9) {
            Group {
                // Cache only: a card never fetches (NoteShelf.linkFetch decides, when the person adds a link).
                if let icon = Sites.shared.cachedIcon(url) { Image(nsImage: icon).resizable().padding(3).background(.white) } else { Color(white: 0.85) }
            }
            .frame(width: 30, height: 30).clipShape(.rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(LinkPreviews.shared.title(url) ?? NoteText.shortAddress(url)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .foregroundStyle(Color(white: 0.13))
                Text(NoteText.host(url)).font(.system(size: 12)).foregroundStyle(Color(white: 0.53)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7).padding(.horizontal, 9)
        .background(.white.opacity(0.75), in: .rect(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(.black.opacity(0.12), lineWidth: 0.5) }
        .onTapGesture { if let address = URL(string: url) { NSWorkspace.shared.open(address) } }
    }
}

struct PictureView: View {
    /// Its link as the note writes it, and the note's folder it's read from (NotePictures: inside the notes' root
    /// only, else a broken picture).
    let link: String
    let folder: URL
    let caption: String

    var body: some View {
        Group {
            if let image = NotePictures.shared.image(link, in: folder) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if NotePictures.shared.isBroken(link, in: folder) {
                Color.black.opacity(0.06).overlay {
                    Image(systemName: "photo.badge.exclamationmark").font(.system(size: 18)).foregroundStyle(.black.opacity(0.35))
                        .accessibilityLabel("Picture can't be shown")
                }
            } else {
                Color.black.opacity(0.06)
            }
        }
        .frame(height: 96).frame(maxWidth: .infinity).clipped()
        .clipShape(.rect(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(.black.opacity(0.15), lineWidth: 0.5) }
        .overlay(alignment: .bottomLeading) {
            if !caption.isEmpty {
                Text(caption).font(.system(size: 10.5)).foregroundStyle(.white).lineLimit(1)
                    .padding(.vertical, 1).padding(.horizontal, 6).background(.black.opacity(0.38), in: .rect(cornerRadius: 4))
                    .padding(.leading, 8).padding(.bottom, 6)
            }
        }
    }
}

/// The folded corner: the bottom-right triangle of a 24-point square, its top-left corner rounded.
struct FoldCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Paper is always light paper; glass follows the Mac's appearance.
struct PaperScheme: ViewModifier {
    let glass: Bool
    func body(content: Content) -> some View {
        if glass { content } else { content.environment(\.colorScheme, .light) }
    }
}

/// The sketch's two shadows under paper: a hairline one close by and a soft one below. Glass has macOS's own.
/// Drawn as one layer's shadow (compositingGroup), so what's inside never gets a shadow of its own.
struct PaperShadow: ViewModifier {
    let glass: Bool
    func body(content: Content) -> some View {
        if glass {
            content   // Liquid Glass casts its own; a group around it would flatten the glass
        } else {
            content.compositingGroup().shadow(color: .black.opacity(0.08), radius: 0.5, y: 1).shadow(color: .black.opacity(0.13), radius: 9, y: 8)
        }
    }
}

// MARK: - Edge tabs

/// One tab on a window's edge: a 13-point strip of its notebook's color at its line; hovered, a paper label with
/// the note's first line; several notes on one line, a count; faded, a faint short line.
struct EdgeTabView: View {
    let tab: EdgeTab
    let colors: [String: NSColor]
    /// Which way the tab hangs: out of the window's right edge (true), or in over it.
    let outside: Bool
    var hovering = false
    var label = ""

    var body: some View {
        let color = colors[tab.color] ?? NSColor(hex: tab.color) ?? .systemBlue
        let shape = UnevenRoundedRectangle(topLeadingRadius: outside ? 0 : 7, bottomLeadingRadius: outside ? 0 : 7,
                                           bottomTrailingRadius: outside ? 7 : 0, topTrailingRadius: outside ? 7 : 0)
        Group {
            if hovering && !label.isEmpty {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(PaperLook.words).lineLimit(1)
                    .padding(.leading, outside ? 10 : 10).padding(.trailing, 12)
                    .frame(height: 30)
                    .background(PaperLook.color(NoteInk.tabPaper(PaperLook.rgb(color))), in: shape)
                    .overlay(alignment: outside ? .trailing : .leading) { Rectangle().fill(Color(nsColor: color)).frame(width: 4) }
                    .clipShape(shape)
            } else {
                shape.fill(Color(nsColor: color)).frame(width: 13, height: tab.height)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 2, x: outside ? 1 : -1, y: 1)
        .opacity(tab.faded ? 0.45 : 1)
        .overlay(alignment: outside ? .topTrailing : .topLeading) {
            if tab.count > 1 && !(hovering && !label.isEmpty) {
                Text("\(tab.count)").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 16, height: 16).background(Color(white: 0.114), in: .circle)
                    .offset(x: outside ? 7 : -7, y: -6)
            }
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
