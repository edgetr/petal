import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What helpers leave on a note's paper, as the sketch draws it (notes-round2.html: "A note", "Helpers at work",
/// "Your desk"): ink under the person's words, a helper at work with Stop and Pause, its cards (Allow, Don't, Buy),
/// a task's chips with Open all, a total kept by plain arithmetic, a watcher's number in the corner, and on the back
/// the steps and the stamps for what was allowed.
enum HelperLook {
    static func ink(_ tint: NoteInk.RGB) -> Color { PaperLook.color(NoteInk.ink(tint)) }
    static func rule(_ tint: NoteInk.RGB) -> Color { PaperLook.color(tint).opacity(0.4) }
    static func stamp(_ tint: NoteInk.RGB) -> Color { PaperLook.color(NoteInk.mix(tint, 0.55, NoteInk.ink)) }
    static func number(_ tint: NoteInk.RGB) -> Color { PaperLook.color(NoteInk.mix(tint, 0.65, NoteInk.black)) }
    static func chip(_ tint: NoteInk.RGB) -> Color { PaperLook.color(NoteInk.mix(tint, 0.12, NoteInk.paper)) }
    static func mention(_ tint: NoteInk.RGB) -> Color { PaperLook.color(NoteInk.mix(tint, 0.18, NoteInk.RGB(r: 1, g: 1, b: 1))) }
    static func mentionInk(_ tint: NoteInk.RGB) -> Color { PaperLook.color(NoteInk.mix(tint, 0.70, NoteInk.RGB(r: 0, g: 0, b: 0))) }
    static let grey = Color(white: 0.53)
    static let proofGreen = Color(red: 0x2a / 255.0, green: 0x8a / 255.0, blue: 0x4a / 255.0)
}

/// Everything a helper put on a note's front, under the writing.
struct HelperFront: View {
    let paper: PaperNote
    let tint: NoteInk.RGB
    let glass: Bool
    var desk: NoteDesk?

    /// How tall the ink may be on this screen (the rest scrolls); the controls are never inside it.
    var inkRoom: CGFloat = .infinity

    var body: some View {
        let file = paper.file
        VStack(alignment: .leading, spacing: 0) {
            // What a helper wrote: scrolls when it's more than the screen has room for.
            BoundedScroll(maxHeight: inkRoom) {
                VStack(alignment: .leading, spacing: 0) {
                    if !file.task.isEmpty { PaperTaskChips(paper: paper, tint: tint, desk: desk).padding(.vertical, 6) }
                    if let calc = file.calc { CalcLine(calc: calc, body: file.body, tint: tint, glass: glass) }
                    ForEach(Array(file.ink.enumerated()), id: \.offset) { index, ink in
                        // Each block of ink keeps 8 points above and below; two in a row share them (8 between, not 16).
                        InkView(ink: ink, heading: ink.heading(among: file.ink), tint: !ink.opinion ? tint : NoteInk.hex("#a550a7") ?? tint, glass: glass)
                            .padding(.top, index > 0 ? -8 : 0)
                    }
                }
            }
            // Allow, Don't, Buy, Stop and Pause: pinned outside the scroll, always on the screen.
            HelperBar(paper: paper, tint: tint, glass: glass, desk: desk)
                .background(GeometryReader { Color.clear.preference(key: HelperControlsHeight.self, value: $0.size.height) })
        }
    }
}

/// Its content as it is when it fits `maxHeight`; scrolled within that height when it doesn't.
struct BoundedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        let measured = content().fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { Color.clear.preference(key: BoundedHeight.self, value: $0.size.height) })
        Group {
            if height > maxHeight {
                ScrollView(.vertical) { measured }.frame(height: maxHeight)
            } else {
                measured
            }
        }
        .onPreferenceChange(BoundedHeight.self) { height = $0 }
    }
}

/// The helper's controls as drawn (its bar, Allow and Don't, a form with its buttons): the paper keeps their room.
struct HelperControlsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct BoundedHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One block of ink: who wrote it, its words, and a coding helper's proof. Dragged out, it's its words (as text, or
/// a Markdown file where a file is wanted); its proof's link is the pull request's address.
struct InkView: View {
    let ink: NoteHelp.Ink
    /// Who wrote it, as it reads among the note's ink (a second opinion of an earlier answer says so).
    var heading: String? = nil
    let tint: NoteInk.RGB
    let glass: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(heading ?? ink.heading).font(.system(size: TextSize.small, weight: .semibold)).opacity(0.85)
            // The whole answer is kept in the note; only the paper shortens it (dragging it out gives all of it).
            Text(ink.text).font(.system(size: TextSize.body)).lineSpacing(PaperLook.openSpacing).lineLimit(14).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(ink.text.count > 600 ? "Drag it out for the whole answer" : "")
            // The finish line the person set, apart from the evidence; no "Proof:" line, said plainly (never a badge).
            if !ink.finish.isEmpty {
                Text("Done means: " + ink.finish).font(.system(size: TextSize.small)).foregroundStyle(HelperLook.grey).padding(.top, 4)
            }
            if ink.missingProof {
                Text("No proof given").font(.system(size: TextSize.small)).foregroundStyle(HelperLook.grey).padding(.top, 2)
            }
            if ink.link == NoteHelp.settingsLink {
                NoteButton(title: "Open Settings › Petal AI") { PetalApp.shared.settings.show(.claude) }.padding(.top, 6)
            }
            if !ink.proof.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(ink.proof.enumerated()), id: \.offset) { _, item in
                        Text(item).font(.system(size: TextSize.micro, weight: .semibold)).foregroundStyle(HelperLook.proofGreen).lineLimit(2).multilineTextAlignment(.center)
                            .frame(width: 52, height: 34)
                            .background(Color(white: 0.949), in: .rect(cornerRadius: Radius.chip))
                            .overlay { RoundedRectangle(cornerRadius: Radius.chip).stroke(.black.opacity(0.15), lineWidth: 0.5) }
                            .onTapGesture { NoteTasks.openWeb(ink.link) }
                    }
                }
                .padding(.top, 6)
                .onDrag { NoteTasks.web(ink.link).map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider() }
            }
        }
        .foregroundStyle(glass ? Color.primary : HelperLook.ink(tint))
        .padding(.leading, 9)
        .overlay(alignment: .leading) { Rectangle().fill(HelperLook.rule(tint)).frame(width: 2) }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onDrag { InkView.provider(ink) }
    }

    /// The ink as something to drop: its words, and a file promise (a Markdown file written when it's dropped).
    static func provider(_ ink: NoteHelp.Ink) -> NSItemProvider {
        let words = ink.text + (ink.link.isEmpty ? "" : "\n" + ink.link)
        let provider = NSItemProvider(object: words as NSString)
        provider.suggestedName = String(ink.heading.replacingOccurrences(of: "✦ ", with: "").prefix(40))
        provider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier, fileOptions: [], visibility: .all) { done in
            let file = FileManager.default.temporaryDirectory.appending(path: "Petal ink \(UUID().uuidString.prefix(6)).md")
            do { try Data(words.utf8).write(to: file); done(file, false, nil) } catch { done(nil, false, error) }
            return nil
        }
        return provider
    }
}

/// A note that keeps a total: its formula worked out by plain arithmetic each time it's drawn.
struct CalcLine: View {
    let calc: NoteHelp.Calc
    let body_: String
    let tint: NoteInk.RGB
    let glass: Bool

    init(calc: NoteHelp.Calc, body: String, tint: NoteInk.RGB, glass: Bool) {
        self.calc = calc; self.body_ = body; self.tint = tint; self.glass = glass
    }

    var body: some View {
        let values = NoteHelp.values(body_)
        let currency = NoteHelp.amounts(body_).first?.currency ?? ""
        let result = NoteHelp.evaluate(calc.formula, values: values)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(calc.label.isEmpty ? "Total" : calc.label).font(.system(size: TextSize.small, weight: .semibold)).opacity(0.85)
            Text(result.map { NoteHelp.format($0, currency: currency, thousands: false) } ?? "can't add up").font(.system(size: TextSize.subtitle, weight: .semibold)).tracking(-0.3)
            Spacer(minLength: 0)
            Text("kept current").font(.system(size: TextSize.caption)).foregroundStyle(HelperLook.grey)
        }
        .foregroundStyle(glass ? Color.primary : HelperLook.ink(tint))
        .padding(.leading, 9)
        .overlay(alignment: .leading) { Rectangle().fill(HelperLook.rule(tint)).frame(width: 2) }
        .padding(.vertical, 6)
        .help(calc.formula)
        .onDrag { NSItemProvider(object: (result.map { NoteHelp.format($0, currency: currency, thousands: false) } ?? "") as NSString) }
    }
}

/// A task put away, on the note's own paper: its parts as chips, and Open all (the Petal Notes window's grid has its
/// own smaller `TaskChips`; both open through the one opener, NoteDesk.openAll).
struct PaperTaskChips: View {
    let paper: PaperNote
    let tint: NoteInk.RGB
    var desk: NoteDesk?

    var body: some View {
        let items = paper.file.task
        FlowRow(spacing: 6) {
            ForEach(Array(NoteHelp.taskChips(items).enumerated()), id: \.offset) { _, chip in
                SourceChipLabel(text: chip, tint: tint)
            }
            Button { desk?.helpers.openAll(paper.key) } label: {
                SourceChipLabel(text: "Open all \(items.count)", tint: tint, underline: true)
            }
            .buttonStyle(.plain)
            .help("Bring these back")
        }
        .onDrag {
            let words = items.map { $0.target }.joined(separator: "\n")
            return NSItemProvider(object: words as NSString)
        }
    }
}

/// A chip as the sketch's sources and task parts are: small words on paper with a hairline.
struct SourceChipLabel: View {
    let text: String
    let tint: NoteInk.RGB
    var underline = false

    var body: some View {
        Text(text).font(.system(size: TextSize.small)).underline(underline).foregroundStyle(Color(white: 0.2)).lineLimit(1)
            .padding(.vertical, 3).padding(.horizontal, 8)
            .background(HelperLook.chip(tint), in: .rect(cornerRadius: Radius.control))
            .overlay { RoundedRectangle(cornerRadius: Radius.control).stroke(.black.opacity(0.12), lineWidth: 0.5) }
    }
}

/// A helper at work (or waiting for the person): its latest step, Stop and Pause; a card it asks with, on the note.
struct HelperBar: View {
    @Environment(PetalApp.self) private var app
    let paper: PaperNote
    let tint: NoteInk.RGB
    let glass: Bool
    var desk: NoteDesk?
    @State private var actionsHeight: CGFloat = 40

    /// The card's words' room: the screen, less the paper around it and its measured buttons.
    private var formRoom: CGFloat {
        NoteHelp.formRoom(screen: Screens.main?.visibleFrame.height ?? 800, chrome: 230, actions: actionsHeight)
    }

    var body: some View {
        let noteID = paper.noteID
        let run = desk?.helpers.runs[noteID]
        let helper = paper.file.helper
        let working = run != nil || helper.map { $0.state == .working || $0.state == .waiting } == true
        let denials = run?.sticky?.agent.pendingAsk ?? []
        VStack(alignment: .leading, spacing: 8) {
            // What Petal did here without a run, or why it didn't.
            if let hint = desk?.helpers.hints[noteID] {
                Text(hint).font(.system(size: TextSize.small)).foregroundStyle(glass ? Color.secondary : PaperLook.footer)
            }
            if working {
                HStack(spacing: 7) {
                    PulseDot(color: PaperLook.color(tint), pulsing: run.map { !$0.paused } ?? (helper?.state == .working))
                    Text(Self.line(run: run, helper: helper, displays: app.displays)).font(.system(size: TextSize.small)).foregroundStyle(glass ? Color.secondary : PaperLook.footer).lineLimit(1)
                    Spacer(minLength: 6)
                    // It works on a hidden display of its own: its window comes to the person's screen.
                    if let caller = run?.sticky?.id.uuidString, app.displays.display(for: caller) != nil {
                        NoteButton(title: "Show me") { app.displays.showMe(caller: caller) }
                    }
                    if run != nil || helper?.state == .working {
                        NoteButton(title: run?.paused == true ? "Go on" : "Pause") { desk?.helpers.pause(noteID) }
                    }
                    NoteButton(title: "Stop") { desk?.helpers.stop(noteID) }
                }
            }
            if !denials.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Agent.Denial.heading(denials)).font(.system(size: TextSize.small, weight: .semibold)).lineLimit(3)
                    let details = Agent.Denial.details(denials)
                    if !details.isEmpty {
                        Text(details).font(.system(size: TextSize.small, design: .monospaced)).foregroundStyle(PaperLook.footer).lineLimit(4)
                    }
                    HStack(spacing: 6) {
                        Spacer()
                        NoteButton(title: "Don't", primary: true) { desk?.helpers.denyDenials(noteID) }
                        NoteButton(title: "Allow") { desk?.helpers.allowDenials(noteID) }
                    }
                }
                .foregroundStyle(PaperLook.words)
            }
            if let request = desk?.helpers.card(noteID) {
                // Its words scroll within what this screen has room for; its buttons, measured, always below them.
                AskRequestView(request: request, room: formRoom).id(request.id).padding(10)
                    .onPreferenceChange(FormActionsHeight.self) { actionsHeight = $0 }
                    .background(.white.opacity(0.6), in: .rect(cornerRadius: Radius.control))   // a card on the paper: a step under the paper's own corner
                    .overlay { RoundedRectangle(cornerRadius: Radius.control).stroke(.black.opacity(0.1), lineWidth: 0.5) }
                    .environment(\.colorScheme, .light)
            }
        }
        .padding(.top, working || !denials.isEmpty || desk?.helpers.hints[noteID] != nil ? 6 : 0)
    }

    /// The bar's line: who, and its latest step; while it waits its turn for a display or an app, that.
    @MainActor
    static func line(run: NoteHelpers.Run?, helper: NoteHelp.Helper?, displays: RunDisplays) -> String {
        if let run {
            if run.paused { return "\(run.who) · paused" }
            if displays.waits(run.sticky?.id.uuidString) { return run.who + " · " + NoteStatus.waitingForDisplay }
            if let waited = displays.waitsForApp(run.sticky?.id.uuidString) { return run.who + " · " + NoteStatus.waiting(for: waited) }
            let step = run.sticky?.agent.activity.text ?? ""
            return run.who + " · " + (step.isEmpty ? "working" : step)
        }
        guard let helper else { return "" }
        return helper.who + " · " + (helper.step.isEmpty ? (helper.state == .waiting ? "waiting" : "working") : helper.step)
    }
}

/// The sketch's small buttons: grey, the default one dark.
struct NoteButton: View {
    let title: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: TextSize.callout)).foregroundStyle(primary ? Color.white : Color(white: 0.13))
                .padding(.vertical, 4).padding(.horizontal, 12)
                .background(primary ? Color(white: 0.114) : Color.black.opacity(0.07), in: .rect(cornerRadius: Radius.control))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct PulseDot: View {
    let color: Color
    var pulsing = true
    @State private var dim = false

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .opacity(pulsing && dim ? 0.25 : 1)
            .onAppear { if pulsing { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true } } }
    }
}

/// The back's helper half: the steps it took, and a stamp for each thing allowed (tap one to take it back).
struct HelperBack: View {
    let paper: PaperNote
    let tint: NoteInk.RGB
    let glass: Bool
    var desk: NoteDesk?

    var body: some View {
        let file = paper.file
        if !file.steps.isEmpty || !file.stamps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(file.steps.suffix(12).enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("✓").font(.system(size: TextSize.small, weight: .semibold)).foregroundStyle(HelperLook.mentionInk(tint))
                            Text(step).font(.system(size: TextSize.callout)).foregroundStyle(glass ? Color.primary : PaperLook.words).lineLimit(2)
                        }
                        .frame(minHeight: 20, alignment: .leading)
                    }
                }
                if !file.stamps.isEmpty {
                    FlowRow(spacing: 6) {
                        ForEach(Array(file.stamps.enumerated()), id: \.offset) { _, stamp in
                            Button { desk?.helpers.revoke(paper.noteID, stamp) } label: { StampView(label: stamp.label, tint: tint) }
                                .buttonStyle(.plain)
                                .help("Take this back")
                        }
                    }
                }
                Text(footnote(file)).font(.system(size: TextSize.small)).foregroundStyle(glass ? Color.secondary : Color(white: 0.53))
            }
        }
    }

    private func footnote(_ file: NoteFile) -> String {
        let who = file.helper?.who ?? "Petal"
        let when = file.helper?.at.map { NoteDesk.when($0) } ?? ""
        let tail = file.stamps.isEmpty ? "" : " Tap a stamp to take it back."
        return [when, who].filter { !$0.isEmpty }.joined(separator: " · ") + "." + tail
    }
}

struct StampView: View {
    let label: String
    let tint: NoteInk.RGB

    var body: some View {
        Text(label).font(.system(size: TextSize.caption, weight: .semibold)).tracking(0.4).lineLimit(1)
            .padding(.vertical, 2).padding(.horizontal, 6)
            .overlay { RoundedRectangle(cornerRadius: Radius.chip).stroke(lineWidth: 1.5) }
            .foregroundStyle(HelperLook.stamp(tint))
            .opacity(0.75)
            .rotationEffect(.degrees(-4))
            .padding(.top, 6)
    }
}

/// A watcher's newest value in the folded note's corner, the older ones struck.
struct WatchCorner: View {
    let watch: NoteHelp.Watch
    let tint: NoteInk.RGB
    let glass: Bool

    var body: some View {
        let corner = NoteHelp.corner(watch)
        VStack(alignment: .trailing, spacing: 0) {
            if let number = corner?.number {
                Text(number).font(.system(size: TextSize.title, weight: .semibold)).tracking(-0.48)
                    .foregroundStyle(glass ? Color.primary : HelperLook.number(tint)).lineLimit(1).minimumScaleFactor(0.6)
            }
            if !watch.history.isEmpty {
                Text(watch.history.prefix(2).joined(separator: " · ")).font(.system(size: TextSize.small)).strikethrough().foregroundStyle(Color(white: 0.6)).lineLimit(1)
            }
            // A crossing that couldn't be confirmed: its number, faint; the last accepted value stays above it.
            if let faint = corner?.faint {
                Text(faint).font(.system(size: TextSize.caption)).foregroundStyle(Color(white: 0.6)).lineLimit(1)
            }
        }
    }
}

/// The notes a quick question's answer used: chips under it, each opening its note.
struct SourceChips: View {
    @Environment(PetalApp.self) private var app
    let sources: [NoteSource]

    var body: some View {
        let tint = PaperLook.rgb(NSColor.controlAccentColor)
        FlowRow(spacing: 6) {
            ForEach(sources) { source in
                Button { app.paper.helpers.summon(source.noteID, open: true) } label: {
                    SourceChipLabel(text: "▢ " + source.title, tint: tint)
                }
                .buttonStyle(.plain)
                .help("Open this note")
            }
        }
        .environment(\.colorScheme, .light)
    }
}

/// Chips that wrap onto as many rows as they need.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += row + spacing; x = 0; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(width, widest), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}


/// A line with @ in it, read only (snapshots, a conflict's paper): mentions tinted as the sketch's `.mention`, each
/// with its chip of what it bound to, small and raised (`.bound`); understood words dotted.
enum MentionLine {
    static func attributed(_ line: String, tint: NoteInk.RGB, names: (notes: [String], notebooks: [String], place: String)) -> AttributedString {
        let ns = line as NSString
        var out = AttributedString()
        var at = 0
        for binding in NoteHelp.bindings(line, notes: names.notes, notebooks: names.notebooks, now: Date(), place: names.place) {
            if binding.range.location > at { out += AttributedString(ns.substring(with: NSRange(location: at, length: binding.range.location - at))) }
            var words = AttributedString(ns.substring(with: binding.range))
            if binding.at {
                words.backgroundColor = HelperLook.mention(tint)
                words.foregroundColor = HelperLook.mentionInk(tint)
                words.font = .system(size: TextSize.body, weight: .semibold)
            } else {
                words.underlineStyle = Text.LineStyle(pattern: .dot, color: HelperLook.mentionInk(tint).opacity(0.6))
            }
            out += words
            if !binding.chip.isEmpty {
                var chip = AttributedString(" " + binding.chip)
                chip.font = .system(size: TextSize.caption, weight: .medium)
                chip.baselineOffset = 2
                chip.foregroundColor = HelperLook.mentionInk(tint).opacity(0.65)
                if binding.at { chip.backgroundColor = HelperLook.mention(tint) }
                out += chip
            }
            at = NSMaxRange(binding.range)
        }
        if at < ns.length { out += AttributedString(ns.substring(from: at)) }
        return out
    }
}
