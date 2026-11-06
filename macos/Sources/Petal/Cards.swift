import AppKit
import SwiftUI

/// The focus guard's cards: "x.com · belongs to Social" (block), "figma.com · fits Design" (move), and a peek at
/// what the AI just sorted, "tidepool.dev · not in any mode", which fades by itself.
struct FrontCard: View {
    @Environment(PetalApp.self) private var app
    let card: FocusCard

    var body: some View {
        let target = card.target
        let color = Color(nsColor: target?.color ?? app.accent)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                FrontIcon(card: card, size: card.kind == .peek ? 22 : 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Text(card.title).bold()) · \(headline)").font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    detail.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if card.kind != .peek {
                    Spacer(minLength: 8)
                    RoundButton(symbol: "xmark") { app.focus.dismiss(card) }
                }
            }
            if card.kind != .peek, let target {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if card.kind == .block {
                        Button("Stay") { app.focus.stay(card) }.buttonStyle(.glass)
                        Button(Self.go(target, config: app.config)) { app.focus.go(card) }.buttonStyle(.glassProminent).tint(color)
                    } else {
                        Button("Keep it here") { app.focus.keep(card) }.buttonStyle(.glass)
                        Button("Move to \(target.name)") { app.focus.move(card) }.buttonStyle(.glassProminent).tint(color)
                    }
                }
            }
        }
    }

    private var headline: String {
        switch card.kind {
        case .block: "belongs to \(card.target?.name ?? "another mode")"
        case .move: "fits \(card.target?.name ?? "another mode")"
        default: "not in any mode"
        }
    }

    private var detail: Text {
        switch card.kind {
        case .block: return Text("Stay focused, or switch?")
        case .move: return Text("Move to \(card.target?.name ?? "it")?")
        default:
            let fits = Text("✓ Fits \(card.here?.name ?? "this mode")").foregroundStyle(Color(nsColor: card.here?.color ?? app.accent))
            return card.reason.isEmpty ? fits : Text("\(fits) · ✦ \(card.reason)")
        }
    }

    /// "Go to Social (30s wait)", or "Go to Social" when it doesn't wait.
    static func go(_ mode: Mode, config: Config) -> String {
        "Go to \(mode.name)" + (config.bool("countdown") && mode.isDistracting ? " (\(Int(mode.wait))s wait)" : "")
    }
}

/// The site's icon, or the app's.
struct FrontIcon: View {
    let card: FocusCard
    let size: CGFloat

    var body: some View {
        if let domain = card.front?.domain {
            SiteIcon(id: "https://" + domain, size: size)
        } else {
            Image(nsImage: Apps.icon(card.bundleID)).resizable().frame(width: size, height: size)
        }
    }
}

/// A held notification that can't wait, popping out of its mode's button:
/// "Maya Chen · #launch · Slack · held for Social", its text, the AI's reason, and Later or Go to Social.
struct NoteCard: View {
    @Environment(PetalApp.self) private var app
    let card: FocusCard

    var body: some View {
        let note = card.note
        let target = card.target
        let color = Color(nsColor: target?.color ?? app.accent)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: Apps.icon(card.bundleID)).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Text(note?.title ?? "").bold()) · \(byline)").font(.system(size: 13)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let body = note?.body, !body.isEmpty {
                        Text(body).font(.system(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("✦ Time-sensitive" + (card.reason.isEmpty ? "" : " · \(card.reason)"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(.rect)
                .onTapGesture { if let note { app.notes.open(note) } }
                Spacer(minLength: 8)
                RoundButton(symbol: "xmark") { app.notes.later(card) }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Later") { app.notes.later(card) }.buttonStyle(.glass)
                if let target, let note {
                    Button(FrontCard.go(target, config: app.config)) { app.notes.open(note) }.buttonStyle(.glassProminent).tint(color)
                }
            }
        }
    }

    private var byline: String {
        ([card.note?.subtitle ?? "", Apps.name(card.bundleID)].filter { !$0.isEmpty } + ["held for \(card.target?.name ?? "later")"])
            .joined(separator: " · ")
    }
}

extension FocusCard {
    /// A card of each kind with sample words, for `petal testCard` and snapshots.
    @MainActor
    static func sample(_ kind: String, app: PetalApp, here: Mode? = nil, desktop: Int? = nil) -> FocusCard? {
        let config = app.config
        let here = here ?? app.docks.focusedDock?.mode ?? config.mode(forDesktop: 1)
        let desktop = desktop ?? app.docks.focusedDock?.desktop ?? 1
        let others = config.modes.filter { $0.id != here?.id }
        let browser = ["net.imput.helium", "com.apple.Safari"].first { Apps.url($0) != nil } ?? "com.apple.Safari"
        func front(_ domain: String) -> Front {
            Front(bundleID: browser, pid: 0, name: Apps.name(browser), domain: domain, title: domain, isBrowser: true)
        }
        switch kind {
        case "move":
            guard let target = others.first(where: { !$0.isDistracting }) ?? others.first else { return nil }
            return FocusCard(kind: .move, bundleID: browser, title: "figma.com", target: target, here: here, desktop: desktop, front: front("figma.com"))
        case "peek":
            return FocusCard(kind: .peek, bundleID: browser, title: "tidepool.dev", target: here, here: here,
                             reason: "API docs for an incident tool", desktop: desktop, front: front("tidepool.dev"))
        case "note":
            guard let target = others.first(where: \.isDistracting) ?? others.first else { return nil }
            let installed = Apps.installed().map(\.id)
            let slack = ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS"].first(where: installed.contains) ?? "com.tinyspeck.slackmacgap"
            let note = HeldNote(id: 0, app: slack, title: "Maya Chen", subtitle: "#launch",
                                body: "Can you look at the launch checklist before 3? Two items need your sign-off.", date: Date(),
                                mode: target.id, urgent: true, reason: "needs your answer before 3pm")
            return FocusCard(kind: .note, bundleID: slack, title: note.title, target: target, here: here, reason: note.reason,
                             desktop: desktop, note: note)
        default:
            guard let target = others.first(where: \.isDistracting) ?? others.first else { return nil }
            return FocusCard(kind: .block, bundleID: browser, title: "x.com", target: target, here: here, desktop: desktop, front: front("x.com"))
        }
    }
}
