import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    /// The open editor's height for writing `writing` points tall: with an answer, a step or a card under it, only
    /// what the writing needs (the answer follows its question); with nothing under it, room to write in.
    static func editorRoom(writing: CGFloat, below: Bool) -> CGFloat { below ? max(writing, 24) : max(minOpen - 70, writing) }

    static func rgb(_ color: NSColor) -> NoteInk.RGB {
        let c = color.usingColorSpace(.sRGB) ?? NSColor.systemBlue
        return NoteInk.RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
    }

    static func color(_ c: NoteInk.RGB) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b) }
    static func nsColor(_ c: NoteInk.RGB) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }

    /// The words on paper: #222. On glass: the system's own.
    /// A paper's words keep the sketch's line pitch at any size: 1.37 of the size (13-point words every 17.8 points,
    /// 12-point ones every 16.4), as extra spacing over the font's own 1.193.
    static func lineSpacing(_ size: CGFloat) -> CGFloat { size * (1.37 - 1.193) }
    /// The open note's words: a line every 19.1 points, in the read-only body as in the editor (`NoteRich.paragraph`).
    static let openSpacing: CGFloat = 19.1 - TextSize.body * 1.193

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
    /// The helper's controls as last drawn (HelperControlsHeight).
    @State private var controlsHeight: CGFloat = 0
    /// Its last write failed: kept here, tried again, and said on the paper.
    var unsaved = false
    /// Pictures whose bytes couldn't be saved: said on the paper, with Try again and Remove.
    var pictureTrouble = 0
    /// What @ binds to where there's no desk (snapshots): notes and notebooks by name, and the place's words.
    var names: (notes: [String], notebooks: [String], place: String)? = nil

    private var bindable: (notes: [String], notebooks: [String], place: String) {
        names ?? desk?.helpers.names(for: paper.key) ?? ([], [], "")
    }
    /// Open, its width (Petal's viewer's margin is narrower than the room beside a window).
    var width: CGFloat = PaperLook.openWidth
    /// Turned over and folded by its holder when it isn't the desk (Petal's viewer's margin).
    var flipped: (() -> Void)? = nil
    var folded: (() -> Void)? = nil
    /// On the desk, what picks the paper up (PaperGrab): right under its words and controls, over its own surface.
    var grab: PaperGrab? = nil

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
            // Under the words and controls, over the paper's own surface: where it's picked up and dragged.
            .background { if let grab, !snapshotting { grab } }
            // The strip is the paper's width, whatever room the paper is offered (and part of what's picked up).
            .overlay(alignment: .top) { strip.allowsHitTesting(false) }
        .overlay(alignment: .bottomTrailing) { corner }
        .clipShape(.rect(cornerRadius: Radius.tile))
        // The shadow is the paper's alone: on the whole view SwiftUI would give every letter one too.
        .background { surface.clipShape(.rect(cornerRadius: Radius.tile)).modifier(PaperShadow(glass: glass)) }
        .modifier(PaperScheme(glass: glass))
    }

    @ViewBuilder private var surface: some View {
        if glass {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: Radius.tile))
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
            // A folded watcher's line takes the room (the sketch's watchers carry no @).
            // A button: a new "@Petal " line to write a request on (the paper opens for it first).
            Button { desk?.askPetal(paper.key) } label: {
                Text("@").font(.system(size: TextSize.body, weight: .semibold)).foregroundStyle(glass ? Color.primary.opacity(0.22) : Color.black.opacity(0.22))
                    .padding(.trailing, 8).padding(.bottom, 9).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(desk == nil || flipped != nil || conflict)
            // A conflict's paper is read only: nothing can be written on it, so no @ either.
            .opacity((face == .folded && paper.file.watch != nil) || conflict ? 0 : 1)
            .allowsHitTesting(!(face == .folded && paper.file.watch != nil) && !conflict)
            .help("Ask Petal AI: write what you want, then press Return")
            Button { if let flipped { flipped() } else { desk?.flip(paper.key) } } label: { FoldCorner().fill(Color.black.opacity(0.13)).frame(width: 24, height: 24).contentShape(.rect) }
                .buttonStyle(.plain)
                .help(face == .back ? "Turn it back over" : "Turn it over")
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Folded, a page is its site alone, as the sketch's folded notes say it.
            // Petal's own note (a morning note) says so, with the time it was left: "from Petal · 08:00".
            Letterhead(place: paper.file.fromPetal ? "from Petal · " + paper.file.created.formatted(date: .omitted, time: .shortened)
                       : face == .folded ? NoteText.site(place) : place, notebook: notebook, others: face == .folded ? "" : others, tint: tint, glass: glass,
                       menus: face == .open && (desk != nil || snapshotting), tapPlace: { desk?.placeMenu(paper.key) }, tapNotebook: { desk?.notebookMenu(paper.key) })
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
            watchCorner
            Group {
                let titled = NoteBlock.blocks(paper.file.body).first { !$0.words.trimmingCharacters(in: .whitespaces).isEmpty }.map { if case .heading = $0 { true } else { false } } ?? false
                let title = paper.file.title
                let preview = paper.file.preview
                // The sketch's folded note: a title, 3 points above medium words at the paper's line pitch.
                VStack(alignment: .leading, spacing: 3) {
                    if titled { Text(title).font(.system(size: TextSize.heading, weight: .semibold)).lineLimit(2) }
                    Text(titled ? preview : [title, preview].filter { !$0.isEmpty }.joined(separator: " "))
                        .font(.system(size: TextSize.body, weight: .medium))
                        .lineSpacing(PaperLook.lineSpacing(TextSize.body))
                }
                    .foregroundStyle(paper.file.fromPetal && !glass ? HelperLook.ink(tint) : words)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            }
            // On the desk the folded paper's words are part of what's picked up (the grab area is right under them).
            .allowsHitTesting(grab == nil)
            if conflict {
                Button("Keep this one") { desk?.keep(paper.key) }.buttonStyle(.plain)
                    .font(.system(size: TextSize.small, weight: .semibold)).foregroundStyle(PaperLook.color(NoteInk.letterhead(tint)))
                    .padding(.bottom, 4)
            }
            HStack(spacing: paper.file.watch != nil ? 4 : 6) {
                // Something coming (back at a time, a helper at work): the sketch's dot before the line.
                if !unsaved, paper.file.back != nil || paper.file.helper.map({ $0.state == .working || $0.state == .waiting }) == true {
                    PulseDot(color: Color(nsColor: color), pulsing: paper.file.helper?.state == .working)
                }
                Text(unsaved ? "Not saved yet: trying again" : footer).font(.system(size: TextSize.small))
                    .foregroundStyle(unsaved ? Color(red: 0.7, green: 0.15, blue: 0.12) : glass ? .secondary : PaperLook.footer).lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .allowsHitTesting(grab == nil)
                // A watcher's Pause (or Go on), on the folded note.
                if !unsaved, let watch = paper.file.watch {
                    Text("·").font(.system(size: TextSize.small)).foregroundStyle(glass ? .secondary : PaperLook.footer).padding(.horizontal, -2)
                    Button(watch.paused ? "Go on" : "Pause") { desk?.helpers.pause(paper.noteID) }.buttonStyle(.plain)
                        .font(.system(size: TextSize.small)).foregroundStyle(glass ? .secondary : PaperLook.footer).underline(watch.paused)
                }
            }
            .padding(.trailing, paper.file.watch != nil ? 0 : 44)
            .opacity(paper.file.fromPetal && !unsaved ? 0 : 1)
        }
    }

    /// The open paper within the screen (NoteHelp.paperHeights): the editor, then the ink (scrolling past what fits),
    /// with room always kept for the helper's controls.
    private var heights: (editor: CGFloat, ink: CGFloat) {
        let screen = Screens.main?.visibleFrame.height ?? 800
        // (The watcher's corner, when it has one, takes its room above the words.)
        let corner: CGFloat = NoteHelp.corner(paper.file.watch) == nil ? 0 : 44
        return NoteHelp.paperHeights(screen: screen, chrome: 110 + corner, editor: PaperLook.maxOpen - 70, ink: .greatestFiniteMagnitude, controls: max(controlsHeight, 40))
    }

    /// Something of a helper's under the writing: its answer, a task's chips, a sum, or its bar (a step, a card).
    private var helperShows: Bool {
        let file = paper.file
        return !file.ink.isEmpty || !file.asks.isEmpty || !file.task.isEmpty || file.calc != nil || controlsHeight > 1
    }

    /// The helper's ink and its controls, the controls measured (a form's buttons too) so the paper keeps their room.
    private var helperFront: some View {
        HelperFront(paper: paper, tint: tint, glass: glass, desk: desk, inkRoom: heights.ink).padding(.bottom, 18)
            .onPreferenceChange(HelperControlsHeight.self) { controlsHeight = $0 }
    }

    /// A watcher's newest value in the corner, the old ones struck (the sketch's .num): on the open paper as on the
    /// folded one, so a crossing it's told is seen whichever face shows.
    @ViewBuilder private var watchCorner: some View {
        if let watch = paper.file.watch, NoteHelp.corner(watch) != nil {
            WatchCorner(watch: watch, tint: tint, glass: glass).frame(maxWidth: .infinity, alignment: .trailing).padding(.top, -4).padding(.bottom, 2)
        }
    }

    @ViewBuilder private var openBody: some View {
        watchCorner
        if pictureTrouble > 0, let desk {
            HStack(spacing: 10) {
                Text(pictureTrouble == 1 ? "Picture couldn't be saved" : "\(pictureTrouble) pictures couldn't be saved")
                    .font(.system(size: TextSize.small)).foregroundStyle(Color(red: 0.7, green: 0.15, blue: 0.12))
                Spacer()
                Button("Try again") { desk.retryPictures(paper.key) }.buttonStyle(.plain).font(.system(size: TextSize.small, weight: .semibold))
                Button("Remove") { desk.dropPictures(paper.key) }.buttonStyle(.plain).font(.system(size: TextSize.small))
            }
            .foregroundStyle(PaperLook.color(NoteInk.letterhead(tint)))
            .padding(.bottom, 6)
        }
        if unsaved {
            Text("Not saved yet: Petal keeps it here and tries again.").font(.system(size: TextSize.small)).foregroundStyle(Color(red: 0.7, green: 0.15, blue: 0.12))
                .padding(.bottom, 6)
        }
        if conflict {
            HStack {
                Text("Changed on two Macs at once").font(.system(size: TextSize.small)).foregroundStyle(glass ? .secondary : PaperLook.footer)
                Spacer()
                Button("Keep this one") { desk?.keep(paper.key) }.buttonStyle(.plain)
                    .font(.system(size: TextSize.small, weight: .semibold)).foregroundStyle(PaperLook.color(NoteInk.letterhead(tint)))
            }
            .padding(.bottom, 6)
        }
        // One of a conflict's papers is read only, with Keep this one: nothing typed into it could be kept.
        if snapshotting || desk == nil {
            NoteBodyView(paper: paper, tint: tint, accent: color, glass: glass, names: bindable)
            helperFront
        } else if conflict {
            // Read only, in a scroll view as tall as the editor may be: a long one never runs off the screen.
            ConflictBody(paper: paper, tint: tint, accent: color, glass: glass, resized: { desk?.measured(paper.key, $0) })
            helperFront
        } else if let desk {
            NoteEditorView(paper: paper, style: desk.style(color, glass: glass), focus: keyboard,
                           height: { desk.measured(paper.key, $0) },
                           // Saved through the note's identity: renamed or moved meanwhile, it lands on that note.
                           save: { desk.helpers.edited(paper.noteID); return desk.write(paper.key, noteID: paper.noteID, instance: paper.instance, body: $0, base: $1) },
                           register: { [editorToken] in desk.editorRegistered(paper.key, $0, token: editorToken) },
                           importPictures: { desk.importPictures($0, into: paper.key) },
                           idle: { desk.store.takeDeferred(paper.key) },
                           sameNote: { desk.store.sameNote($0, instance: $1, $2) },
                           say: { desk.tell($0) },
                           acceptPictures: { desk.acceptCopiedPictures(paper.key, $0) },
                           // In a paper's own panel, Escape goes up to the panel (handled once there); in Petal's viewer's
                           // margin there's no such panel, so it folds the note there.
                           escape: folded,
                           settled: { desk.settleUnsaved(paper.key, noteID: paper.noteID, instance: paper.instance, saved: $0) },
                           helperReturn: { desk.helpers.returned(paper.key, line: $0, at: $1) },
                           names: { desk.helpers.names(for: paper.key) },
                           petalPicked: { desk.askHint(paper.key) },
                           accent: color, tint: tint)
                .frame(height: min(heights.editor, PaperLook.editorRoom(writing: editorHeight, below: helperShows)))
            helperFront
        }
    }

    private var back: some View {
        VStack(alignment: .leading, spacing: 10) {
            // What a helper did, and what was allowed (tap a stamp to take it back).
            HelperBack(paper: paper, tint: tint, glass: glass, desk: desk)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(paper.file.places.enumerated()), id: \.offset) { _, stick in
                    Text(NoteDesk.describe(stick)).font(.system(size: TextSize.callout)).foregroundStyle(words).lineLimit(2)
                }
                if paper.file.places.isEmpty {
                    Text("Not stuck anywhere yet.").font(.system(size: TextSize.callout)).foregroundStyle(glass ? .secondary : PaperLook.footer)
                }
            }
            // (On the desk, the back's own words are part of what's picked up, as the folded paper's are.)
            .allowsHitTesting(grab == nil)
            Text("In \(notebook)").font(.system(size: TextSize.callout)).foregroundStyle(words).allowsHitTesting(grab == nil)
            Text("Made \(NoteDesk.when(paper.file.created)) · changed \(NoteDesk.when(paper.file.modified))")
                .font(.system(size: TextSize.small)).foregroundStyle(glass ? .secondary : Color(white: 0.53)).allowsHitTesting(grab == nil)
            if let desk {
                Button("Show the file") { desk.reveal(paper.key) }.buttonStyle(.plain)
                    .font(.system(size: TextSize.small, weight: .medium)).foregroundStyle(PaperLook.color(NoteInk.letterhead(tint)))
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
    /// Each half shows it's a menu (a small chevron after it): on the open face.
    var menus = false
    var tapPlace: () -> Void = {}
    var tapNotebook: () -> Void = {}

    var body: some View {
        let ink = glass ? Color.primary.opacity(0.75) : PaperLook.color(NoteInk.letterhead(tint))
        HStack(spacing: 6) {
            Button(action: tapPlace) {
                HStack(spacing: 3) {
                    Text(place).fontWeight(.semibold)
                    if menus { chevron }
                }
            }
            .buttonStyle(.plain)
            .help("Change where it's stuck")
            Button(action: tapNotebook) {
                HStack(spacing: 3) {
                    Text("· " + notebook + (others.isEmpty ? "" : " · also on " + others)).fontWeight(.medium)
                    if menus { chevron }
                }
            }
            .buttonStyle(.plain).opacity(0.7)
            .help("Change its notebook")
        }
        .font(.system(size: TextSize.small))
        .tracking(0.1)
        .foregroundStyle(ink)
        .lineLimit(1)
    }

    private var chevron: some View { Image(systemName: "chevron.down").font(.system(size: TextSize.micro, weight: .semibold)).opacity(0.7) }
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
    var names: (notes: [String], notebooks: [String], place: String) = ([], [], "")
    @Environment(\.snapshotting) private var snapshotting

    var body: some View {
        let words: Color = glass ? .primary : PaperLook.words
        let blocks = NoteBlock.blocks(paper.file.body)
        // Drawn as the editor draws an empty note (its placeholder), for a snapshot of one.
        if snapshotting, paper.file.body.isEmpty {
            Text(NoteTextView.placeholder).font(.system(size: TextSize.body)).foregroundStyle(words.opacity(0.35))
                .frame(maxWidth: .infinity, minHeight: PaperLook.minOpen - 70, alignment: .topLeading)
        }
        // A card or a picture keeps 8 points above and below it, and two in a row share them (8 between, as the
        // sketch's margins do, never 16).
        let boxed = blocks.map { if case .link = $0 { true } else if case .image = $0 { true } else { false } }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                let above: CGFloat = index > 0 && boxed[index - 1] ? 0 : 8
                switch block {
                case .heading(let level, let text):
                    Text(text).font(.system(size: NoteRich.Style.headingSize(level), weight: .semibold)).tracking(-0.17).foregroundStyle(words)
                        .padding(.bottom, 4)
                case .check(let done, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: done ? "checkmark.square.fill" : "square").font(.system(size: TextSize.body))
                            .foregroundStyle(done ? Color(nsColor: accent) : words.opacity(0.4))
                        Text(NoteText.plain(text)).font(.system(size: TextSize.body)).foregroundStyle(words)
                    }
                    .lineSpacing(PaperLook.openSpacing)
                case .link(let url):
                    LinkCardView(url: url).padding(.top, above).padding(.bottom, 8)
                case .image(let path, let caption):
                    PictureView(link: path, folder: paper.url.deletingLastPathComponent(), caption: caption).padding(.top, above).padding(.bottom, 8)
                case .ink(let text):
                    Text(NoteText.plain(text)).font(.system(size: TextSize.body)).foregroundStyle(glass ? .primary : PaperLook.color(NoteInk.ink(tint)))
                        .padding(.leading, 9)
                        .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: accent).opacity(0.4)).frame(width: 2) }
                        .padding(.vertical, 4)
                case .bullet(let text):
                    Text("- " + NoteText.plain(text)).font(.system(size: TextSize.body)).foregroundStyle(words).lineSpacing(PaperLook.openSpacing)
                case .text(let text) where text.contains("@"):
                    Text(MentionLine.attributed(text, tint: tint, names: names)).font(.system(size: TextSize.body)).foregroundStyle(words).lineSpacing(PaperLook.openSpacing)
                case .text(let text):
                    Text(NoteText.plain(text).isEmpty ? " " : NoteText.plain(text)).font(.system(size: TextSize.body)).foregroundStyle(words).lineSpacing(PaperLook.openSpacing)
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
            .frame(width: 30, height: 30).clipShape(.rect(cornerRadius: Radius.chip))   // inside the card's corner
            VStack(alignment: .leading, spacing: 1) {
                Text(LinkPreviews.shared.title(url) ?? NoteText.shortAddress(url)).font(.system(size: TextSize.callout, weight: .medium)).lineLimit(1)
                    .foregroundStyle(Color(white: 0.13))
                Text(NoteText.host(url)).font(.system(size: TextSize.callout)).foregroundStyle(Color(white: 0.53)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7).padding(.horizontal, 9)
        .background(.white.opacity(0.75), in: .rect(cornerRadius: Radius.control))
        .overlay { RoundedRectangle(cornerRadius: Radius.control).stroke(.black.opacity(0.12), lineWidth: 0.5) }
        .onTapGesture { NoteTasks.openWeb(url) }
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
                    Image(systemName: "photo.badge.exclamationmark").font(.system(size: TextSize.subtitle)).foregroundStyle(.black.opacity(0.35))
                        .accessibilityLabel("Picture can't be shown")
                }
            } else {
                Color.black.opacity(0.06)
            }
        }
        .frame(height: 96).frame(maxWidth: .infinity).clipped()
        .clipShape(.rect(cornerRadius: Radius.control))
        // Dragged out of the note: the picture's bytes, read (when dropped) from the file NoteStore.pictureFile allows
        // (inside the notes' root, through no link), never a path.
        .onDrag { PictureView.provider(link: link, folder: folder, caption: caption) }
        .overlay { RoundedRectangle(cornerRadius: Radius.control).stroke(.black.opacity(0.15), lineWidth: 0.5) }
        .overlay(alignment: .bottomLeading) {
            if !caption.isEmpty {
                Text(caption).font(.system(size: TextSize.caption)).foregroundStyle(.white).lineLimit(1)
                    .padding(.vertical, 1).padding(.horizontal, 6).background(.black.opacity(0.38), in: .rect(cornerRadius: Radius.chip))
                    .padding(.leading, 8).padding(.bottom, 6)
            }
        }
    }
}

extension PictureView {
    static func provider(link: String, folder: URL, caption: String) -> NSItemProvider {
        let provider = NSItemProvider()
        let name = (link as NSString).lastPathComponent
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .png
        provider.suggestedName = caption.isEmpty ? (name as NSString).deletingPathExtension : caption
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { done in
            guard let file = NoteStore.pictureFile(link, noteFolder: folder), let data = try? Data(contentsOf: file) else {
                done(nil, CocoaError(.fileReadNoPermission))
                return nil
            }
            done(data, nil)
            return nil
        }
        return provider
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
        let shape = UnevenRoundedRectangle(topLeadingRadius: outside ? 0 : Radius.control, bottomLeadingRadius: outside ? 0 : Radius.control,
                                           bottomTrailingRadius: outside ? Radius.control : 0, topTrailingRadius: outside ? Radius.control : 0)
        Group {
            if hovering && !label.isEmpty {
                Text(label).font(.system(size: TextSize.callout, weight: .medium)).foregroundStyle(PaperLook.words).lineLimit(1)
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
                Text("\(tab.count)").font(.system(size: TextSize.micro, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 16, height: 16).background(Color(white: 0.114), in: .circle)
                    .offset(x: outside ? 7 : -7, y: -6)
            }
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
